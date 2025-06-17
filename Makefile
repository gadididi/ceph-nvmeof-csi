# Makefile for NVMe-oF CSI Driver

# Configuration
PROJECT_NAME := nvmeof-csi
VERSION ?= $(shell git describe --tags --always --dirty)
REGISTRY ?= quay.io/$(USER)
IMAGE_NAME := $(REGISTRY)/$(PROJECT_NAME)
IMAGE_TAG ?= $(VERSION)
FULL_IMAGE := $(IMAGE_NAME):$(IMAGE_TAG)

# Go configuration with dynamic detection
GO_VERSION := 1.24

# Dynamic GOOS detection
ifeq ($(origin GOOS), undefined)
  GOOS := $(shell go env GOOS)
endif

# Dynamic GOARCH detection  
ifeq ($(origin GOARCH), undefined)
  GOARCH := $(shell go env GOARCH)
endif

# Support for cross-compilation
CROSS_PLATFORMS := linux/amd64 linux/arm64 darwin/amd64 darwin/arm64

# Kubernetes configuration
NAMESPACE ?= kube-system
KUBECONFIG ?= ~/.kube/config

# Directories
BUILD_DIR := build
DEPLOY_DIR := deploy
SCRIPTS_DIR := scripts
CMD_DIR := cmd

# Colors for output
RED := \033[0;31m
GREEN := \033[0;32m
YELLOW := \033[1;33m
BLUE := \033[0;34m
NC := \033[0m # No Color

.PHONY: help
help: ## Show this help message
	@echo "NVMe-oF CSI Driver - Available targets:"
	@echo ""
	@awk 'BEGIN {FS = ":.*##"; printf "\033[36m%-20s\033[0m %s\n", "Target", "Description"} /^[a-zA-Z_-]+:.*?##/ { printf "\033[36m%-20s\033[0m %s\n", $$1, $$2 } /^##@/ { printf "\n\033[1m%s\033[0m\n", substr($$0, 5) } ' $(MAKEFILE_LIST)

##@ Development

.PHONY: deps
deps: ## Install development dependencies
	@echo -e "$(BLUE)Installing Go dependencies...$(NC)"
	go mod tidy
	go mod download
	go mod verify

.PHONY: generate
generate: ## Generate code (protobuf, mocks, etc.)
	@echo -e "$(BLUE)Generating code...$(NC)"
	go generate ./...

.PHONY: fmt
fmt: ## Format Go code
	@echo -e "$(BLUE)Formatting code...$(NC)"
	go fmt ./...
	goimports -w .

.PHONY: vet
vet: ## Run go vet
	@echo -e "$(BLUE)Running go vet...$(NC)"
	go vet ./...

.PHONY: lint
lint: ## Run golangci-lint
	@echo -e "$(BLUE)Running linter...$(NC)"
	golangci-lint run

##@ Building

.PHONY: build-binary
build-binary: ## Build the binary
	@echo -e "$(BLUE)Building binary for $(GOOS)/$(GOARCH)...$(NC)"
	@mkdir -p $(BUILD_DIR)
	CGO_ENABLED=0 GOOS=$(GOOS) GOARCH=$(GOARCH) go build \
		-ldflags="-w -s -X main.version=$(VERSION)" \
		-o $(BUILD_DIR)/$(PROJECT_NAME)-$(GOOS)-$(GOARCH) \
		./$(CMD_DIR)/

.PHONY: build-binary-all
build-binary-all: ## Build binaries for common platforms
	@echo -e "$(BLUE)Building binaries for common platforms...$(NC)"
	@mkdir -p $(BUILD_DIR)
	GOOS=linux GOARCH=amd64 $(MAKE) build-binary
	GOOS=linux GOARCH=arm64 $(MAKE) build-binary
	GOOS=darwin GOARCH=amd64 $(MAKE) build-binary
	GOOS=darwin GOARCH=arm64 $(MAKE) build-binary
	@echo -e "$(GREEN) All binaries built$(NC)"

.PHONY: build
build: ## Build Docker image for current platform
	@echo -e "$(BLUE)Building Docker image: $(FULL_IMAGE) ($(GOARCH))$(NC)"
	docker build \
		--build-arg GOARCH=$(GOARCH) \
		--build-arg GOOS=$(GOOS) \
		-t $(FULL_IMAGE) .
	@echo -e "$(GREEN) Image built: $(FULL_IMAGE)$(NC)"

.PHONY: build-latest
build-latest: ## Build and tag as latest
	$(MAKE) build IMAGE_TAG=latest
	docker tag $(IMAGE_NAME):latest $(FULL_IMAGE)

##@ Registry

.PHONY: push
push: ## Push image to registry
	@echo -e "$(BLUE)Pushing image: $(FULL_IMAGE)$(NC)"
	docker push $(FULL_IMAGE)
	@echo -e "$(GREEN) Image pushed: $(FULL_IMAGE)$(NC)"

.PHONY: push-latest
push-latest: ## Push latest tag
	$(MAKE) push IMAGE_TAG=latest

.PHONY: build-push
build-push: build push ## Build and push image

##@ Minikube

.PHONY: minikube-setup
minikube-setup: ## Set up Minikube environment
	@echo -e "$(BLUE)Setting up Minikube...$(NC)"
	$(SCRIPTS_DIR)/minikube-setup.sh up

.PHONY: minikube-clean
minikube-clean: ## Clean up Minikube
	$(SCRIPTS_DIR)/minikube-setup.sh clean

##@ Deployment

.PHONY: deploy
deploy: ## Deploy CSI driver to Kubernetes
	@echo -e "$(BLUE)Deploying CSI driver...$(NC)"
	$(SCRIPTS_DIR)/deploy.sh deploy

.PHONY: undeploy
undeploy: ## Remove CSI driver from Kubernetes
	@echo -e "$(BLUE)Removing CSI driver...$(NC)"
	$(SCRIPTS_DIR)/deploy.sh teardown

.PHONY: redeploy
redeploy: undeploy deploy ## Redeploy CSI driver

.PHONY: status
status: ## Show deployment status
	$(SCRIPTS_DIR)/deploy.sh status

.PHONY: logs
logs: ## Show CSI driver logs
	$(SCRIPTS_DIR)/deploy.sh logs

##@ Testing

.PHONY: test-unit
test-unit: ## Run unit tests
	@echo -e "$(BLUE)Running unit tests...$(NC)"
	go test -v -race -coverprofile=coverage.out ./...

.PHONY: test-integration
test-integration: ## Run integration tests
	@echo -e "$(BLUE)Running integration tests...$(NC)"
	$(SCRIPTS_DIR)/test.sh test

.PHONY: test
test: test-unit test-integration ## Run all tests

.PHONY: test-cleanup
test-cleanup: ## Clean up test resources
	$(SCRIPTS_DIR)/test.sh cleanup

##@ Development Workflows

.PHONY: dev-setup
dev-setup: minikube-setup ## Complete development setup
	@echo -e "$(GREEN) Development environment ready!$(NC)"

.PHONY: dev-deploy
dev-deploy: build push deploy ## Build, push, and deploy
	@echo -e "$(GREEN) Development deployment complete!$(NC)"

.PHONY: dev-test
dev-test: dev-deploy test-integration ## Deploy and test in development

.PHONY: dev-clean
dev-clean: undeploy minikube-clean ## Clean development environment

##@ Release

.PHONY: release-build
release-build: ## Build release artifacts
	$(MAKE) build IMAGE_TAG=$(VERSION)
	$(MAKE) build IMAGE_TAG=latest

.PHONY: release-push
release-push: ## Push release images
	$(MAKE) push IMAGE_TAG=$(VERSION)
	$(MAKE) push IMAGE_TAG=latest

.PHONY: release
release: release-build release-push ## Build and push release

##@ Cleanup

.PHONY: clean
clean: ## Clean up build artifacts
	@echo -e "$(BLUE)Cleaning up...$(NC)"
	rm -rf $(BUILD_DIR)
	go clean -cache
	docker system prune -f
	@echo -e "$(GREEN) Cleanup complete$(NC)"

.PHONY: clean-images
clean-images: ## Remove Docker images
	@echo -e "$(BLUE)Removing Docker images...$(NC)"
	docker rmi $(FULL_IMAGE) 2>/dev/null || true
	docker rmi $(IMAGE_NAME):latest 2>/dev/null || true

##@ Information

.PHONY: info
info: ## Show build information
	@echo "Project: $(PROJECT_NAME)"
	@echo "Version: $(VERSION)"
	@echo "Registry: $(REGISTRY)"
	@echo "Image: $(FULL_IMAGE)"
	@echo "Target OS/Arch: $(GOOS)/$(GOARCH)"
	@echo "Host OS/Arch: $(shell go env GOOS)/$(shell go env GOARCH)"
	@echo "Go Version: $(shell go version)"
	@echo "Docker Version: $(shell docker --version)"
	@echo "Kubectl Version: $(shell kubectl version --client --short 2>/dev/null || echo 'Not available')"

.PHONY: check-env
check-env: ## Check environment setup
	@echo -e "$(BLUE)Checking environment...$(NC)"
	@command -v go >/dev/null 2>&1 || { echo -e "$(RED) Go not installed$(NC)"; exit 1; }
	@command -v docker >/dev/null 2>&1 || { echo -e "$(RED) Docker not installed$(NC)"; exit 1; }
	@command -v kubectl >/dev/null 2>&1 || { echo -e "$(RED) kubectl not installed$(NC)"; exit 1; }
	@echo -e "$(GREEN) Environment check passed$(NC)"

# Default target
.DEFAULT_GOAL := help