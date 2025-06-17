#!/bin/bash -e

# Minikube Setup Script with All Dependencies
# Usage: ./minikube-setup.sh [up|down|clean|status]

set -euo pipefail

# Configuration
KUBE_VERSION=${KUBE_VERSION:-v1.30.1}
MINIKUBE_VERSION=${MINIKUBE_VERSION:-v1.36.0}
MINIKUBE_DRIVER=${MINIKUBE_DRIVER:-none}
CRICTL_VERSION=${CRICTL_VERSION:-v1.30.0}
CRI_DOCKERD_VERSION=${CRI_DOCKERD_VERSION:-0.3.4}
CNI_PLUGINS_VERSION=${CNI_PLUGINS_VERSION:-v1.3.0}

# Detect architecture
ARCH=amd64
if [ "$(uname -m)" = "aarch64" ]; then
    ARCH=arm64
fi

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

log_info() {
    echo -e "${BLUE}ℹ️  $1${NC}"
}

log_success() {
    echo -e "${GREEN}✅ $1${NC}"
}

log_warning() {
    echo -e "${YELLOW}⚠️  $1${NC}"
}

log_error() {
    echo -e "${RED}❌ $1${NC}"
}


# Install conntrack (required for kube-proxy)
install_conntrack() {
    if command -v conntrack &>/dev/null; then
        log_success "conntrack already installed"
        return
    fi
    
    log_info "Installing conntrack..."
    if command -v apt-get &>/dev/null; then
        sudo apt-get update -qq
        sudo apt-get install -y conntrack
    elif command -v yum &>/dev/null; then
        sudo yum install -y conntrack-tools
    elif command -v dnf &>/dev/null; then
        sudo dnf install -y conntrack-tools
    else
        log_error "Cannot install conntrack: unsupported package manager"
        exit 1
    fi
    log_success "conntrack installed"
}

# Install crictl (CRI CLI tool)
install_crictl() {
    if command -v crictl &>/dev/null; then
        current_version=$(crictl --version | awk '{print $3}')
        if [[ "$current_version" == "$CRICTL_VERSION" ]]; then
            log_success "crictl $CRICTL_VERSION already installed"
            
            # Ensure crictl is available in root's PATH for minikube
            if [ ! -f "/usr/bin/crictl" ] && [ -f "/usr/local/bin/crictl" ]; then
                sudo ln -sf /usr/local/bin/crictl /usr/bin/crictl
                log_info "Created crictl symlink for root PATH"
            fi
            return
        fi
    fi
    
    log_info "Installing crictl $CRICTL_VERSION..."
    
    # Download and install crictl
    CRICTL_URL="https://github.com/kubernetes-sigs/cri-tools/releases/download/${CRICTL_VERSION}/crictl-${CRICTL_VERSION}-linux-${ARCH}.tar.gz"
    
    curl -sL "$CRICTL_URL" | sudo tar -C /usr/local/bin -xz crictl
    sudo chmod +x /usr/local/bin/crictl
    
    # Also create a symlink in /usr/bin for root's default PATH
    sudo ln -sf /usr/local/bin/crictl /usr/bin/crictl
    
    # Configure crictl
    sudo mkdir -p /etc
    sudo tee /etc/crictl.yaml > /dev/null <<EOF
runtime-endpoint: unix:///var/run/cri-dockerd.sock
image-endpoint: unix:///var/run/cri-dockerd.sock
timeout: 2
debug: false
pull-image-on-create: false
EOF
    
    log_success "crictl $CRICTL_VERSION installed"
}

# Install cri-dockerd (Docker CRI implementation)
install_cri_dockerd() {
    # Check for correct service name (cri-docker, not cri-dockerd)
    if systemctl is-active --quiet cri-docker 2>/dev/null; then
        log_success "cri-dockerd already installed and running"
        return
    fi
    
    log_info "Installing cri-dockerd $CRI_DOCKERD_VERSION..."
    
    # Clean up any failed previous installations
    cleanup_failed_cri_dockerd
    
    # Try official packages first (includes service files)
    if install_cri_dockerd_package; then
        if verify_cri_dockerd_installation; then
            return
        else
            log_warning "Package installation verification failed, trying manual installation..."
            cleanup_failed_cri_dockerd
        fi
    fi
    
    # Fallback: manual installation with official service files
    log_info "Package not available, installing manually with official service files..."
    install_cri_dockerd_manual
    verify_cri_dockerd_installation
}

# Clean up failed installations
cleanup_failed_cri_dockerd() {
    log_info "Cleaning up any failed cri-dockerd installations..."
    
    # Stop and disable services with both possible names
    sudo systemctl stop cri-docker.service cri-dockerd.service 2>/dev/null || true
    sudo systemctl stop cri-docker.socket cri-dockerd.socket 2>/dev/null || true
    sudo systemctl disable cri-docker.service cri-dockerd.service 2>/dev/null || true
    sudo systemctl disable cri-docker.socket cri-dockerd.socket 2>/dev/null || true
    
    # Remove service files with both possible names
    sudo rm -f /etc/systemd/system/cri-docker.service
    sudo rm -f /etc/systemd/system/cri-docker.socket
    sudo rm -f /etc/systemd/system/cri-dockerd.service
    sudo rm -f /etc/systemd/system/cri-dockerd.socket
    sudo rm -rf /etc/systemd/system/cri-docker.service.d
    sudo rm -rf /etc/systemd/system/cri-dockerd.service.d
    
    # Remove binaries
    sudo rm -f /usr/bin/cri-dockerd /usr/local/bin/cri-dockerd
    
    sudo systemctl daemon-reload
    log_info "Cleanup completed"
}

# Try installing via official packages with better error handling
install_cri_dockerd_package() {
    local success=false
    local package_file=""
    
    if command -v dnf &>/dev/null; then
        # RHEL/CentOS/Fedora with dnf
        package_file="cri-dockerd-${CRI_DOCKERD_VERSION}-3.el8.${ARCH}.rpm"
        
        if curl -sLO "https://github.com/Mirantis/cri-dockerd/releases/download/v${CRI_DOCKERD_VERSION}/${package_file}"; then
            log_info "Downloaded ${package_file}"
            
            # Install with verbose output to catch errors
            if sudo dnf install -y "${package_file}"; then
                success=true
                log_info "Package installed successfully via dnf"
            else
                log_warning "dnf installation failed"
            fi
            rm -f "${package_file}"
        else
            log_warning "Failed to download ${package_file}"
        fi
        
    elif command -v yum &>/dev/null; then
        # RHEL/CentOS with yum
        package_file="cri-dockerd-${CRI_DOCKERD_VERSION}-3.el8.${ARCH}.rpm"
        
        if curl -sLO "https://github.com/Mirantis/cri-dockerd/releases/download/v${CRI_DOCKERD_VERSION}/${package_file}"; then
            log_info "Downloaded ${package_file}"
            
            if sudo yum install -y "${package_file}"; then
                success=true
                log_info "Package installed successfully via yum"
            else
                log_warning "yum installation failed"
            fi
            rm -f "${package_file}"
        else
            log_warning "Failed to download ${package_file}"
        fi
        
    elif command -v apt-get &>/dev/null; then
        # Ubuntu/Debian
        package_file="cri-dockerd_${CRI_DOCKERD_VERSION}.3-0.ubuntu-jammy_${ARCH}.deb"
        
        if curl -sLO "https://github.com/Mirantis/cri-dockerd/releases/download/v${CRI_DOCKERD_VERSION}/${package_file}"; then
            log_info "Downloaded ${package_file}"
            
            if sudo dpkg -i "${package_file}"; then
                success=true
                log_info "Package installed successfully via dpkg"
            else
                log_warning "dpkg installation failed"
            fi
            rm -f "${package_file}"
        else
            log_warning "Failed to download ${package_file}"
        fi
    else
        log_warning "No supported package manager found"
        return 1
    fi
    
    if [ "$success" = true ]; then
        # Reload systemd and start services
        sudo systemctl daemon-reload
        
        # Enable and start services (use correct service names from package)
        if sudo systemctl enable cri-docker.service cri-docker.socket; then
            if sudo systemctl start cri-docker.service cri-docker.socket; then
                # Wait for services to start
                sleep 5
                log_success "cri-dockerd installed via official package"
                return 0
            else
                log_error "Failed to start cri-dockerd services"
            fi
        else
            log_error "Failed to enable cri-dockerd services"
        fi
    fi
    
    log_warning "Package installation failed or incomplete"
    return 1
}

# Manual installation with official service files
install_cri_dockerd_manual() {
    log_info "Installing cri-dockerd manually..."
    
    # Download cri-dockerd binary
    CRI_DOCKERD_URL="https://github.com/Mirantis/cri-dockerd/releases/download/v${CRI_DOCKERD_VERSION}/cri-dockerd-${CRI_DOCKERD_VERSION}.${ARCH}.tgz"
    
    if ! curl -sL "$CRI_DOCKERD_URL" | tar -xz; then
        log_error "Failed to download cri-dockerd binary"
        exit 1
    fi
    
    sudo mv cri-dockerd/cri-dockerd /usr/local/bin/
    sudo chmod +x /usr/local/bin/cri-dockerd
    rm -rf cri-dockerd
    
    log_info "Binary installed to /usr/local/bin/cri-dockerd"
    
    # Download official service files from GitHub
    if ! curl -sL https://raw.githubusercontent.com/Mirantis/cri-dockerd/master/packaging/systemd/cri-docker.service \
        | sudo tee /etc/systemd/system/cri-docker.service > /dev/null; then
        log_error "Failed to download service file"
        exit 1
    fi
    
    if ! curl -sL https://raw.githubusercontent.com/Mirantis/cri-dockerd/master/packaging/systemd/cri-docker.socket \
        | sudo tee /etc/systemd/system/cri-docker.socket > /dev/null; then
        log_error "Failed to download socket file"
        exit 1
    fi
    
    # Update binary path in service file (packages use /usr/bin, manual uses /usr/local/bin)
    sudo sed -i 's|/usr/bin/cri-dockerd|/usr/local/bin/cri-dockerd|g' /etc/systemd/system/cri-docker.service
    
    log_info "Service files installed"
    
    # Enable and start the service
    sudo systemctl daemon-reload
    
    if ! sudo systemctl enable cri-docker.service cri-docker.socket; then
        log_error "Failed to enable cri-dockerd services"
        exit 1
    fi
    
    if ! sudo systemctl start cri-docker.service cri-docker.socket; then
        log_error "Failed to start cri-dockerd services"
        sudo systemctl status cri-docker.service
        exit 1
    fi
    
    # Wait for services to start
    sleep 5
    
    log_success "cri-dockerd $CRI_DOCKERD_VERSION installed manually"
}

# Verify cri-dockerd installation
verify_cri_dockerd_installation() {
    log_info "Verifying cri-dockerd installation..."
    
    # Check if binary exists and is executable
    local binary_path=""
    if [ -x "/usr/bin/cri-dockerd" ]; then
        binary_path="/usr/bin/cri-dockerd"
    elif [ -x "/usr/local/bin/cri-dockerd" ]; then
        binary_path="/usr/local/bin/cri-dockerd"
    else
        log_error "cri-dockerd binary not found or not executable"
        return 1
    fi
    
    log_info "Found cri-dockerd binary at: $binary_path"
    
    # Check if service is running
    if ! systemctl is-active --quiet cri-docker.service; then
        log_error "cri-docker.service is not running"
        log_info "Service status:"
        sudo systemctl status cri-docker.service || true
        return 1
    fi
    
    # Check if socket is running
    if ! systemctl is-active --quiet cri-docker.socket; then
        log_error "cri-docker.socket is not running"
        log_info "Socket status:"
        sudo systemctl status cri-docker.socket || true
        return 1
    fi
    
    # Check if socket file exists
    local socket_path=""
    if [ -S "/var/run/cri-dockerd.sock" ]; then
        socket_path="/var/run/cri-dockerd.sock"
    elif [ -S "/run/cri-dockerd.sock" ]; then
        socket_path="/run/cri-dockerd.sock"
    else
        log_error "cri-dockerd socket file not found"
        log_info "Checked paths: /var/run/cri-dockerd.sock, /run/cri-dockerd.sock"
        ls -la /run/cri* /var/run/cri* 2>/dev/null || true
        return 1
    fi
    
    log_info "Found cri-dockerd socket at: $socket_path"
    log_success "cri-dockerd installation verified successfully"
    return 0
}

# Install CNI plugins
install_cni_plugins() {
    if [ -d "/opt/cni/bin" ] && [ -n "$(ls -A /opt/cni/bin/ 2>/dev/null)" ]; then
        log_success "CNI plugins already installed"
        return
    fi
    
    log_info "Installing CNI plugins $CNI_PLUGINS_VERSION..."
    
    # Create CNI directories
    sudo mkdir -p /opt/cni/bin
    sudo mkdir -p /etc/cni/net.d
    
    # Download and install CNI plugins
    CNI_URL="https://github.com/containernetworking/plugins/releases/download/${CNI_PLUGINS_VERSION}/cni-plugins-linux-${ARCH}-${CNI_PLUGINS_VERSION}.tgz"
    
    curl -sL "$CNI_URL" | sudo tar -C /opt/cni/bin -xz
    
    # Fix the CNI directory permissions and create empty config to prevent minikube warnings
    sudo chmod 755 /etc/cni/net.d
    
    log_success "CNI plugins $CNI_PLUGINS_VERSION installed"
}

# Install Docker if not present
install_docker() {
    if command -v docker &>/dev/null && systemctl is-active --quiet docker; then
        log_success "Docker already installed and running"
        return
    fi
    
    log_info "Installing Docker..."
    
    if command -v apt-get &>/dev/null; then
        # Ubuntu/Debian
        sudo apt-get update -qq
        sudo apt-get install -y apt-transport-https ca-certificates curl gnupg lsb-release
        
        # Add Docker's official GPG key
        curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /usr/share/keyrings/docker-archive-keyring.gpg
        
        # Add Docker repository
        echo "deb [arch=${ARCH} signed-by=/usr/share/keyrings/docker-archive-keyring.gpg] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
        
        sudo apt-get update -qq
        sudo apt-get install -y docker-ce docker-ce-cli containerd.io
        
    elif command -v yum &>/dev/null; then
        # CentOS/RHEL
        sudo yum install -y yum-utils
        sudo yum-config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo
        sudo yum install -y docker-ce docker-ce-cli containerd.io
        
    elif command -v dnf &>/dev/null; then
        # Fedora
        sudo dnf install -y dnf-plugins-core
        sudo dnf config-manager --add-repo https://download.docker.com/linux/fedora/docker-ce.repo
        sudo dnf install -y docker-ce docker-ce-cli containerd.io
    else
        log_error "Cannot install Docker: unsupported package manager"
        exit 1
    fi
    
    # Start and enable Docker
    sudo systemctl start docker
    sudo systemctl enable docker
    
    # Add current user to docker group
    sudo usermod -aG docker "$USER"
    
    log_success "Docker installed and started"
    log_warning "You may need to log out and back in for docker group membership to take effect"
}

# Install kubectl
install_kubectl() {
    if command -v kubectl &>/dev/null; then
        log_success "kubectl already installed"
        return
    fi
    
    log_info "Installing kubectl..."
    
    curl -sLO "https://dl.k8s.io/release/${KUBE_VERSION}/bin/linux/${ARCH}/kubectl"
    sudo install -o root -g root -m 0755 kubectl /usr/local/bin/kubectl
    rm kubectl
    
    log_success "kubectl installed"
}

# Install Minikube
install_minikube() {
    # Check if minikube exists in the expected location and has correct version
    if [ -f "/usr/local/bin/minikube" ]; then
        current_version=$(/usr/local/bin/minikube version --short 2>/dev/null | cut -d' ' -f3 || echo "unknown")
        if [[ "$current_version" == "$MINIKUBE_VERSION" ]]; then
            log_success "minikube $MINIKUBE_VERSION already installed in /usr/local/bin/"
            return
        fi
        log_warning "minikube $current_version found, but $MINIKUBE_VERSION requested - reinstalling"
    fi
    
    log_info "Installing minikube $MINIKUBE_VERSION..."
    
    # Remove any existing minikube installations
    sudo rm -f /usr/local/bin/minikube
    
    curl -sLo minikube "https://storage.googleapis.com/minikube/releases/${MINIKUBE_VERSION}/minikube-linux-${ARCH}"
    sudo install minikube /usr/local/bin/minikube
    rm minikube
    
    # Verify installation
    if /usr/local/bin/minikube version --short &>/dev/null; then
        log_success "minikube $MINIKUBE_VERSION installed successfully"
    else
        log_error "minikube installation failed"
        exit 1
    fi
}

# Cleanup network interfaces
cleanup_network() {
    log_info "Cleaning up network interfaces..."
    
    # Stop kubelet if running
    sudo systemctl stop kubelet 2>/dev/null || true
    
    # Ensure CNI directory exists before cleanup
    sudo mkdir -p /etc/cni/net.d
    
    # Remove CNI and Flannel artifacts
    sudo rm -rf /var/lib/cni /run/flannel 2>/dev/null || true
    sudo rm -f /etc/cni/net.d/*.conflist 2>/dev/null || true
    
    # Remove virtual network interfaces
    sudo ip link delete cni0 2>/dev/null || true
    sudo ip link delete flannel.1 2>/dev/null || true
    sudo ip link delete docker0 2>/dev/null || true
    
    # Restart docker to recreate docker0
    sudo systemctl restart docker 2>/dev/null || true
    
    log_success "Network cleanup completed"
}

# Setup Minikube environment
setup_minikube_env() {
    # Ensure proper permissions for minikube
    sudo mkdir -p /var/lib/minikube
    sudo chown -R "$USER:$USER" /home/"$USER"/.minikube 2>/dev/null || true
    
    # Set environment variables for none driver
    if [[ "$MINIKUBE_DRIVER" == "none" ]]; then
        export MINIKUBE_WANTUPDATENOTIFICATION=false
        export MINIKUBE_WANTREPORTERRORPROMPT=false
        export MINIKUBE_HOME="$HOME"
        export CHANGE_MINIKUBE_NONE_USER=true
    fi
}

# Start Minikube
start_minikube() {
    log_info "Starting minikube with kubernetes $KUBE_VERSION using driver=$MINIKUBE_DRIVER..."
    
    setup_minikube_env
    
    # Ensure critical binaries are in PATH for root
    if [[ "$MINIKUBE_DRIVER" == "none" ]]; then
        # Create symlinks for critical binaries that minikube needs
        [ ! -f "/usr/bin/crictl" ] && [ -f "/usr/local/bin/crictl" ] && sudo ln -sf /usr/local/bin/crictl /usr/bin/crictl
        [ ! -f "/usr/bin/kubectl" ] && [ -f "/usr/local/bin/kubectl" ] && sudo ln -sf /usr/local/bin/kubectl /usr/bin/kubectl
        
        # Verify crictl is accessible
        if ! sudo which crictl &>/dev/null; then
            log_error "crictl not found in root's PATH. Please ensure it's installed correctly."
            exit 1
        fi
        
        log_info "Using none driver - minikube will run directly on host"
        log_info "crictl location: $(sudo which crictl)"
        
        # Set explicit PATH for sudo command
        sudo env PATH="/usr/local/bin:/usr/bin:/bin:/sbin:/usr/sbin" \
            MINIKUBE_WANTUPDATENOTIFICATION=false \
            MINIKUBE_WANTREPORTERRORPROMPT=false \
            MINIKUBE_HOME="$HOME" \
            CHANGE_MINIKUBE_NONE_USER=true \
            /usr/local/bin/minikube start \
            --driver=none \
            --kubernetes-version="$KUBE_VERSION" \
            --container-runtime=docker \
            --bootstrapper=kubeadm \
            --extra-config=kubelet.container-runtime-endpoint=unix:///var/run/cri-dockerd.sock \
            --extra-config=kubelet.image-service-endpoint=unix:///var/run/cri-dockerd.sock \
            --extra-config=kubelet.cgroup-driver=systemd
    else
        # For other drivers (docker, kvm2, etc.)
        /usr/local/bin/minikube start \
            --driver="$MINIKUBE_DRIVER" \
            --kubernetes-version="$KUBE_VERSION" \
            --container-runtime=docker \
            --bootstrapper=kubeadm \
            --extra-config=kubelet.container-runtime-endpoint=unix:///var/run/cri-dockerd.sock \
            --extra-config=kubelet.image-service-endpoint=unix:///var/run/cri-dockerd.sock \
            --memory=4096 \
            --cpus=2
    fi
        
    log_success "minikube started successfully"
    
    # Fix permissions for kubectl when using none driver
    if [[ "$MINIKUBE_DRIVER" == "none" ]]; then
        sudo chown -R "$USER:$USER" "$HOME/.kube" 2>/dev/null || true
        sudo chown -R "$USER:$USER" "$HOME/.minikube" 2>/dev/null || true
    fi
    
    # Wait for cluster to be ready
    log_info "Waiting for cluster to be ready..."
    kubectl wait --for=condition=Ready nodes --all --timeout=300s
    
    log_success "Kubernetes cluster is ready!"
}

# Install Flannel CNI
install_flannel() {
    log_info "Installing Flannel CNI..."
    kubectl apply -f https://raw.githubusercontent.com/flannel-io/flannel/master/Documentation/kube-flannel.yml
    
    # Wait a moment for pods to be created
    sleep 10
    
    # Wait for Flannel to be ready (with better error handling)
    log_info "Waiting for Flannel pods to be ready..."
    if kubectl wait --for=condition=Ready -n kube-flannel pods -l app=flannel --timeout=300s 2>/dev/null; then
        log_success "Flannel CNI installed and ready"
    else
        log_warning "Flannel pods are still starting up, this is normal"
        log_info "You can check status later with: kubectl get pods -n kube-flannel"
    fi
}

# Show cluster status
show_status() {
    echo
    log_info "Cluster Status:"
    echo "==============="
    
    if command -v minikube &>/dev/null; then
        echo "Minikube Status:"
        /usr/local/bin/minikube status || true
        echo
    fi
    
    if command -v kubectl &>/dev/null; then
        echo "Cluster Info:"
        kubectl cluster-info || true
        echo
        
        echo "Nodes:"
        kubectl get nodes -o wide || true
        echo
        
        echo "System Pods:"
        kubectl get pods -n kube-system || true
    fi
}

# Main installation function
install_all() {
    log_info "Starting Minikube setup with all dependencies..."
    
    install_docker
    install_conntrack
    install_crictl
    install_cri_dockerd
    install_cni_plugins
    install_kubectl
    install_minikube
    
    cleanup_network
    start_minikube
    install_flannel
    
    show_status
    
    log_success "Minikube setup completed successfully!"
    log_info "You can now use 'kubectl' to interact with your cluster"
    log_info "Try: kubectl get pods -A"
}

# Stop Minikube
stop_minikube() {
    log_info "Stopping minikube..."
    /usr/local/bin/minikube stop
    log_success "minikube stopped"
}

# Clean up Minikube
clean_minikube() {
    log_info "Cleaning up minikube..."
    /usr/local/bin/minikube delete --all --purge 2>/dev/null || true
    cleanup_network
    log_success "minikube cleaned up"
}

# Main script logic
case "${1:-up}" in
    up)
        install_all
        ;;
    down)
        stop_minikube
        ;;
    clean)
        clean_minikube
        ;;
    status)
        show_status
        ;;
    *)
        echo "Usage: $0 [up|down|clean|status]"
        echo "  up     - Install dependencies and start minikube"
        echo "  down   - Stop minikube"
        echo "  clean  - Delete minikube cluster and cleanup"
        echo "  status - Show cluster status"
        exit 1
        ;;
esac