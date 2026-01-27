#!/bin/bash
# Helper script to run Headlamp Docker container locally

set -e

# Default values
IMAGE_NAME="${HEADLAMP_IMAGE:-headlamp:latest}"
CONTAINER_NAME="${HEADLAMP_CONTAINER:-headlamp}"
PORT="${HEADLAMP_PORT:-3010}"
KUBECONFIG_PATH="${KUBECONFIG:-${HOME}/.kube/config}"
PLUGINS_DIR="${HEADLAMP_PLUGINS_DIR:-}"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Function to print colored output
print_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

print_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Check if Docker is running
if ! docker info > /dev/null 2>&1; then
    print_error "Docker is not running. Please start Docker and try again."
    exit 1
fi

# Check if kubeconfig exists
if [ ! -f "$KUBECONFIG_PATH" ]; then
    print_warn "Kubeconfig not found at $KUBECONFIG_PATH"
    print_warn "Headlamp will start but may not be able to connect to your cluster."
    KUBECONFIG_MOUNT=""
else
    print_info "Using kubeconfig: $KUBECONFIG_PATH"
    KUBECONFIG_MOUNT="-v ${KUBECONFIG_PATH}:/app/.kube/config:ro"
fi

# Check for --force flag
FORCE_REPLACE=false
if [[ "$1" == "--force" ]] || [[ "$1" == "-f" ]]; then
    FORCE_REPLACE=true
    shift
fi

# Check if container already exists
if docker ps -a --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}$"; then
    if [ "$FORCE_REPLACE" = true ]; then
        print_info "Force replacing existing container..."
        docker stop "${CONTAINER_NAME}" > /dev/null 2>&1 || true
        docker rm "${CONTAINER_NAME}" > /dev/null 2>&1 || true
    else
        print_warn "Container '${CONTAINER_NAME}' already exists."
        read -p "Do you want to remove it and create a new one? (y/N): " -n 1 -r
        echo
        if [[ $REPLY =~ ^[Yy]$ ]]; then
            print_info "Stopping and removing existing container..."
            docker stop "${CONTAINER_NAME}" > /dev/null 2>&1 || true
            docker rm "${CONTAINER_NAME}" > /dev/null 2>&1 || true
        else
            print_info "Starting existing container..."
            docker start "${CONTAINER_NAME}"
            print_info "Headlamp is running at http://localhost:${PORT}"
            exit 0
        fi
    fi
fi

# Build volume mount for plugins if specified
PLUGINS_MOUNT=""
if [ -n "$PLUGINS_DIR" ] && [ -d "$PLUGINS_DIR" ]; then
    print_info "Mounting plugins from: $PLUGINS_DIR"
    PLUGINS_MOUNT="-v ${PLUGINS_DIR}:/app/plugins:ro"
fi

# Collect AWS environment variables to pass to container
AWS_ENV_VARS=""
for var in AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN AWS_DEFAULT_REGION AWS_REGION AWS_PROFILE AWS_CONFIG_FILE AWS_SHARED_CREDENTIALS_FILE AWS_VAULT_BACKEND; do
    if [ -n "${!var}" ]; then
        AWS_ENV_VARS+=" -e ${var}=${!var}"
    fi
done

# Set default AWS config paths if not provided
if [ -z "$AWS_CONFIG_FILE" ]; then
    AWS_ENV_VARS+=" -e AWS_CONFIG_FILE=/home/headlamp/.aws/config"
fi
if [ -z "$AWS_SHARED_CREDENTIALS_FILE" ]; then
    AWS_ENV_VARS+=" -e AWS_SHARED_CREDENTIALS_FILE=/home/headlamp/.aws/credentials"
fi

# Run the container
print_info "Starting Headlamp container..."
print_info "Image: ${IMAGE_NAME}"
print_info "Port: ${PORT}"
if [ -n "$AWS_ENV_VARS" ]; then
    print_info "AWS credentials: ${AWS_ACCESS_KEY_ID:+present}"
fi

docker run -d \
    --name "${CONTAINER_NAME}" \
    -p "${PORT}:4466" \
    ${KUBECONFIG_MOUNT} \
    ${PLUGINS_MOUNT} \
    -e HEADLAMP_PLUGIN_DIR=/app/plugins \
    -e KUBECONFIG=/app/.kube/config \
    ${AWS_ENV_VARS} \
    --restart unless-stopped \
    "${IMAGE_NAME}"

# Wait a moment for container to start
sleep 2

# Check if container is running
if docker ps --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}$"; then
    print_info "Headlamp container started successfully!"
    print_info "Access Headlamp at: http://localhost:${PORT}"
    print_info ""
    print_info "Useful commands:"
    print_info "  View logs:    docker logs -f ${CONTAINER_NAME}"
    print_info "  Stop:         docker stop ${CONTAINER_NAME}"
    print_info "  Remove:       docker rm -f ${CONTAINER_NAME}"
else
    print_error "Failed to start container. Check logs with: docker logs ${CONTAINER_NAME}"
    exit 1
fi
