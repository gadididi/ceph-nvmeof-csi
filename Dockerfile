# syntax=docker/dockerfile:1.4
# -------- Build Stage --------
FROM golang:1.24 as builder

# Set Go environment
ENV CGO_ENABLED=0 \
    GO111MODULE=on \
    GOPROXY=https://proxy.golang.org

WORKDIR /app

# Copy go.mod/go.sum and download dependencies
COPY go.mod go.sum ./
RUN go mod download && go mod verify

# Copy source code
COPY . .

# Generate gRPC/protobuf code if needed
# (optional if already generated)
# RUN go generate ./...

# Build the binary
RUN go build -o ceph-nvmeof-csi ./cmd/

# -------- Runtime Stage --------
FROM almalinux:9

# Install nvme-cli
RUN dnf update -y && \
    dnf install -y nvme-cli && \
    dnf clean all && \
    rm -rf /var/cache/dnf

WORKDIR /

# Copy binary from builder  
COPY --from=builder /app/ceph-nvmeof-csi /usr/local/bin/ceph-nvmeof-csi
RUN chmod +x /usr/local/bin/ceph-nvmeof-csi

# Run the CSI driver
ENTRYPOINT ["/usr/local/bin/ceph-nvmeof-csi"]