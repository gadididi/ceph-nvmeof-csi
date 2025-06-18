# NVMe-oF CSI Driver

A Container Storage Interface (CSI) driver for NVMe over Fabrics (NVMe-oF) that enables Kubernetes to provision and manage high-performance storage volumes backed by Ceph storage clusters.

[![License](https://img.shields.io/badge/License-Apache%202.0-blue.svg)](LICENSE)


## Features


## Quick Start

### Prerequisites
- Ceph cluster with NVMe-oF gateway configured

### Installation

1. **Start your Kubernetes cluster** (e.g., via Minikube):

   ```bash
   cd scripts
   sudo ./minikube.sh up
   ```

2. **Deploy CSI services**:

   ```bash
   cd deploy/kubernetes
   ./deploy.sh
   kubectl get pods -A
   ```

3. **Create a test volume:**
   ```bash
    cd examples
    kubectl apply -f testpod.yaml

    # Verify PersistentVolumes and Claims
    kubectl get pv
    kubectl get pvc

    # Verify the test pod
    kubectl get pods
   ```
   

4. **Verify the volume is mounted:**
   ```bash
   kubectl exec -it dummy-nvme-pod -- /bin/sh
   echo "hello nvme" | dd of=/dev/nvme-test bs=1M
   ```

### Teardown

Clean up the test resources and cluster:

```bash
# Delete test workload
cd examples
kubectl delete -f testpod.yaml

# Tear down CSI services
cd deploy/kubernetes
./deploy.sh teardown

# Clean up Kubernetes cluster
cd scripts
sudo ./minikube.sh clean
```

---

## Contributing
