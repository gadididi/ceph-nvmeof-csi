#!/bin/bash -e

# Complete cri-dockerd Removal Script
# This will remove all traces of cri-dockerd installation

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

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

remove_cri_dockerd() {
    log_info "Removing cri-dockerd completely..."
    
    # 1. Stop and disable services
    log_info "Stopping cri-dockerd services..."
    sudo systemctl stop cri-docker.service 2>/dev/null || true
    sudo systemctl stop cri-docker.socket 2>/dev/null || true
    sudo systemctl disable cri-docker.service 2>/dev/null || true
    sudo systemctl disable cri-docker.socket 2>/dev/null || true
    log_success "Services stopped and disabled"
    
    # 2. Remove systemd service files
    log_info "Removing systemd service files..."
    sudo rm -f /etc/systemd/system/cri-docker.service
    sudo rm -f /etc/systemd/system/cri-docker.socket
    sudo systemctl daemon-reload
    log_success "Systemd service files removed"
    
    # 3. Remove binary from manual installation locations
    log_info "Removing cri-dockerd binaries..."
    sudo rm -f /usr/local/bin/cri-dockerd
    sudo rm -f /usr/bin/cri-dockerd
    log_success "Binaries removed"
    
    # 4. Try to remove via package managers (if installed as package)
    log_info "Attempting to remove via package managers..."
    
    # Try apt (Ubuntu/Debian)
    if command -v apt-get &>/dev/null; then
        if dpkg -l | grep -q cri-dockerd; then
            sudo apt-get remove -y cri-dockerd 2>/dev/null || true
            sudo apt-get purge -y cri-dockerd 2>/dev/null || true
            log_success "Removed via apt"
        fi
    fi
    
    # Try dnf/yum (RHEL/CentOS/Fedora)
    if command -v dnf &>/dev/null; then
        if rpm -qa | grep -q cri-dockerd; then
            sudo dnf remove -y cri-dockerd 2>/dev/null || true
            log_success "Removed via dnf"
        fi
    elif command -v yum &>/dev/null; then
        if rpm -qa | grep -q cri-dockerd; then
            sudo yum remove -y cri-dockerd 2>/dev/null || true
            log_success "Removed via yum"
        fi
    fi
    
    # 5. Remove configuration files
    log_info "Removing configuration files..."
    sudo rm -rf /etc/cri-dockerd 2>/dev/null || true
    sudo rm -f /etc/crictl.yaml 2>/dev/null || true
    log_success "Configuration files removed"
    
    # 6. Remove any leftover sockets
    log_info "Cleaning up sockets..."
    sudo rm -f /run/cri-dockerd.sock 2>/dev/null || true
    sudo rm -f /var/run/cri-dockerd.sock 2>/dev/null || true
    log_success "Sockets cleaned up"
    
    # 7. Reset systemd
    sudo systemctl daemon-reload
    sudo systemctl reset-failed 2>/dev/null || true
    
    log_success "🎉 cri-dockerd completely removed!"
    
    # 8. Verification
    log_info "Verification:"
    if command -v cri-dockerd &>/dev/null; then
        log_warning "cri-dockerd binary still found in PATH"
    else
        log_success "No cri-dockerd binary found"
    fi
    
    if systemctl list-unit-files | grep -q cri-docker; then
        log_warning "cri-docker systemd files still exist"
    else
        log_success "No cri-docker systemd files found"
    fi
    
    if systemctl is-active --quiet cri-docker 2>/dev/null; then
        log_error "cri-docker service is still running!"
    else
        log_success "cri-docker service is not running"
    fi
}

# Also remove other components if you want to test the full script
remove_all_components() {
    log_info "Removing all minikube-related components for clean testing..."
    
    # Stop minikube first
    /usr/local/bin/minikube delete --all --purge 2>/dev/null || true
    
    # Remove cri-dockerd (main focus)
    remove_cri_dockerd
    
    # Remove crictl
    log_info "Removing crictl..."
    sudo rm -f /usr/local/bin/crictl
    sudo rm -f /usr/bin/crictl
    sudo rm -f /bin/crictl
    sudo rm -f /etc/crictl.yaml
    log_success "crictl removed"
    
    # Remove CNI plugins (optional - these don't interfere with testing)
    log_info "Removing CNI plugins..."
    sudo rm -rf /opt/cni/bin/* 2>/dev/null || true
    log_success "CNI plugins removed"
    
    # Remove kubectl (optional)
    log_info "Removing kubectl..."
    sudo rm -f /usr/local/bin/kubectl
    sudo rm -f /usr/bin/kubectl
    log_success "kubectl removed"
    
    # Remove minikube
    log_info "Removing minikube..."
    sudo rm -f /usr/local/bin/minikube
    sudo rm -rf ~/.minikube 2>/dev/null || true
    sudo rm -rf /root/.minikube 2>/dev/null || true
    log_success "minikube removed"
    
    log_success "🎉 All components removed! Ready for clean testing."
}

# Show current status
show_status() {
    log_info "Current Installation Status:"
    echo "================================"
    
    echo "cri-dockerd binary:"
    if command -v cri-dockerd &>/dev/null; then
        echo "  ✅ Found: $(which cri-dockerd)"
    else
        echo "  ❌ Not found"
    fi
    
    echo "cri-docker service:"
    if systemctl list-unit-files | grep -q cri-docker.service; then
        echo "  ✅ Service file exists"
        if systemctl is-active --quiet cri-docker; then
            echo "  ✅ Service is running"
        else
            echo "  ❌ Service is not running"
        fi
    else
        echo "  ❌ Service file not found"
    fi
    
    echo "Other components:"
    command -v crictl &>/dev/null && echo "  ✅ crictl: $(which crictl)" || echo "  ❌ crictl not found"
    command -v kubectl &>/dev/null && echo "  ✅ kubectl: $(which kubectl)" || echo "  ❌ kubectl not found"
    command -v minikube &>/dev/null && echo "  ✅ minikube: $(which minikube)" || echo "  ❌ minikube not found"
    [ -d "/opt/cni/bin" ] && [ -n "$(ls -A /opt/cni/bin/ 2>/dev/null)" ] && echo "  ✅ CNI plugins installed" || echo "  ❌ CNI plugins not found"
}

# Main script
case "${1:-status}" in
    cri-dockerd)
        remove_cri_dockerd
        ;;
    all)
        remove_all_components
        ;;
    status)
        show_status
        ;;
    *)
        echo "Usage: $0 [cri-dockerd|all|status]"
        echo "  cri-dockerd  - Remove only cri-dockerd"
        echo "  all          - Remove all components (cri-dockerd, crictl, kubectl, minikube, etc.)"
        echo "  status       - Show current installation status"
        echo ""
        echo "Examples:"
        echo "  $0 status           # Check what's installed"
        echo "  $0 cri-dockerd      # Remove only cri-dockerd to test its installation"
        echo "  $0 all              # Remove everything for complete clean testing"
        exit 1
        ;;
esac