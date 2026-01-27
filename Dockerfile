# Multi-stage Dockerfile for Headlamp
# Builds Headlamp from source for Linux (amd64/arm64)

ARG HEADLAMP_VERSION=main
ARG NODE_VERSION=22.9.0
ARG GO_VERSION=1.25.6

# Stage 1: Builder - Clone and build Headlamp
FROM node:${NODE_VERSION}-alpine AS builder

# Install build dependencies
RUN apk add --no-cache \
    git \
    make \
    gcc \
    musl-dev \
    python3 \
    curl \
    tar

# Install Go from official binaries
ARG GO_VERSION
RUN GO_ARCH=$(uname -m | sed 's/x86_64/amd64/;s/aarch64/arm64/') && \
    curl -fsSL "https://go.dev/dl/go${GO_VERSION}.linux-${GO_ARCH}.tar.gz" -o /tmp/go.tar.gz && \
    tar -C /usr/local -xzf /tmp/go.tar.gz && \
    rm /tmp/go.tar.gz

# Add Go to PATH
ENV PATH="/usr/local/go/bin:${PATH}"
ENV GOPATH="/go"
ENV PATH="${GOPATH}/bin:${PATH}"

# Set working directory
WORKDIR /build

# Clone Headlamp repository
ARG HEADLAMP_VERSION
RUN git clone --depth 1 --branch ${HEADLAMP_VERSION} https://github.com/kubernetes-sigs/headlamp.git . || \
    git clone --depth 1 https://github.com/kubernetes-sigs/headlamp.git . && \
    if [ "${HEADLAMP_VERSION}" != "main" ]; then git checkout ${HEADLAMP_VERSION}; fi

# Install root dependencies first
RUN npm install

# Install frontend dependencies explicitly
WORKDIR /build/frontend
RUN npm install

# Install backend dependencies explicitly  
WORKDIR /build/backend
RUN npm install

# Return to root and build
WORKDIR /build
RUN npm run frontend:build && npm run backend:build


# Copy the headlamp-server binary (built by backend build)
RUN if [ -f backend/headlamp-server ]; then \
        cp backend/headlamp-server /tmp/headlamp && \
        chmod +x /tmp/headlamp && \
        echo "Binary copied from backend/headlamp-server"; \
    else \
        echo "Error: backend/headlamp-server not found" && \
        find backend -type f -executable 2>/dev/null && \
        exit 1; \
    fi

# Stage 2: Runtime - Minimal Alpine image
FROM alpine:3.20.6

# Install runtime dependencies including su-exec, kubectl, and AWS CLI for EKS/auth support
RUN apk add --no-cache \
    ca-certificates \
    tzdata \
    wget \
    curl \
    unzip \
    su-exec \
    python3 \
    py3-pip \
    && update-ca-certificates

# Install kubectl
RUN KUBECTL_VERSION=$(wget -qO- https://dl.k8s.io/release/stable.txt) && \
    ARCH=$(uname -m | sed 's/x86_64/amd64/;s/aarch64/arm64/') && \
    wget -q "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/${ARCH}/kubectl" -O /usr/local/bin/kubectl && \
    chmod +x /usr/local/bin/kubectl && \
    kubectl version --client

# Install AWS CLI via pip (more reliable on Alpine than v2 installer)
# Using --break-system-packages is safe in containers as we control the environment
RUN pip3 install --no-cache-dir --break-system-packages awscli && \
    # Find where aws was installed and ensure it's in /usr/local/bin for reliable access
    AWS_PATH=$(which aws || command -v aws || find /usr -name "aws" -type f -executable 2>/dev/null | head -1) && \
    if [ -n "$AWS_PATH" ] && [ "$AWS_PATH" != "/usr/local/bin/aws" ]; then \
        cp "$AWS_PATH" /usr/local/bin/aws 2>/dev/null || ln -sf "$AWS_PATH" /usr/local/bin/aws; \
        chmod +x /usr/local/bin/aws; \
    fi && \
    # Verify aws is accessible from /usr/local/bin
    /usr/local/bin/aws --version

# Install aws-vault
RUN AWS_VAULT_VERSION=7.2.0 && \
    ARCH=$(uname -m | sed 's/x86_64/amd64/;s/aarch64/arm64/') && \
    wget -q "https://github.com/99designs/aws-vault/releases/download/v${AWS_VAULT_VERSION}/aws-vault-linux-${ARCH}" -O /usr/local/bin/aws-vault && \
    chmod +x /usr/local/bin/aws-vault && \
    /usr/local/bin/aws-vault --version

# Create non-root user
RUN addgroup -g 1000 headlamp && \
    adduser -D -u 1000 -G headlamp headlamp

# Set working directory
WORKDIR /app

# Copy built binaries and assets from builder
COPY --from=builder --chown=headlamp:headlamp /tmp/headlamp /app/headlamp

# Copy frontend build
COPY --from=builder --chown=headlamp:headlamp /build/frontend/build /app/frontend/build

# Create directories for kubeconfig, plugins, and aws-vault storage
RUN mkdir -p /app/.kube /app/plugins /home/headlamp/.aws /home/headlamp/.awsvault /home/headlamp/.awsvaultk && \
    chown -R headlamp:headlamp /app/.kube /app/plugins /home/headlamp/.aws /home/headlamp/.awsvault /home/headlamp/.awsvaultk

# Create entrypoint script to handle kubeconfig permissions and AWS credentials
# This script runs as root, fixes permissions, then switches to headlamp user
# IMPORTANT: Never modifies the host kubeconfig file - only copies to container tmp if needed
RUN echo '#!/bin/sh' > /app/entrypoint.sh && \
    echo 'set -e' >> /app/entrypoint.sh && \
    echo '' >> /app/entrypoint.sh && \
    echo '# Handle kubeconfig permissions without modifying host file' >> /app/entrypoint.sh && \
    echo 'KUBECONFIG_PATH="/app/.kube/config"' >> /app/entrypoint.sh && \
    echo 'if [ -f "$KUBECONFIG_PATH" ]; then' >> /app/entrypoint.sh && \
    echo '  # Check if file is readable by headlamp user' >> /app/entrypoint.sh && \
    echo '  if ! su-exec headlamp:headlamp test -r "$KUBECONFIG_PATH" 2>/dev/null; then' >> /app/entrypoint.sh && \
    echo '    # File is not readable - copy to container tmp with correct ownership' >> /app/entrypoint.sh && \
    echo '    # This does NOT affect the host file (which is read-only mounted)' >> /app/entrypoint.sh && \
    echo '    echo "Copying kubeconfig to container tmp for proper permissions..."' >> /app/entrypoint.sh && \
    echo '    mkdir -p /tmp/.kube' >> /app/entrypoint.sh && \
    echo '    cp "$KUBECONFIG_PATH" /tmp/.kube/config' >> /app/entrypoint.sh && \
    echo '    chown headlamp:headlamp /tmp/.kube/config' >> /app/entrypoint.sh && \
    echo '    chmod 600 /tmp/.kube/config' >> /app/entrypoint.sh && \
    echo '    KUBECONFIG_TMP="/tmp/.kube/config"' >> /app/entrypoint.sh && \
    echo '  else' >> /app/entrypoint.sh && \
    echo '    # File is readable, copy to tmp to modify if needed' >> /app/entrypoint.sh && \
    echo '    mkdir -p /tmp/.kube' >> /app/entrypoint.sh && \
    echo '    cp "$KUBECONFIG_PATH" /tmp/.kube/config' >> /app/entrypoint.sh && \
    echo '    chown headlamp:headlamp /tmp/.kube/config' >> /app/entrypoint.sh && \
    echo '    chmod 600 /tmp/.kube/config' >> /app/entrypoint.sh && \
    echo '    KUBECONFIG_TMP="/tmp/.kube/config"' >> /app/entrypoint.sh && \
    echo '  fi' >> /app/entrypoint.sh && \
    echo '  # Remove AWS_PROFILE from exec commands when using env var credentials' >> /app/entrypoint.sh && \
    echo '  if [ -n "$AWS_ACCESS_KEY_ID" ] && [ -f "$KUBECONFIG_TMP" ]; then' >> /app/entrypoint.sh && \
    echo '    sed -i "/- name: AWS_PROFILE/,+1 d" "$KUBECONFIG_TMP" 2>/dev/null || true' >> /app/entrypoint.sh && \
    echo '  fi' >> /app/entrypoint.sh && \
    echo '  export KUBECONFIG="$KUBECONFIG_TMP"' >> /app/entrypoint.sh && \
    echo 'fi' >> /app/entrypoint.sh && \
    echo '' >> /app/entrypoint.sh && \
    echo '# Prepare environment for headlamp user' >> /app/entrypoint.sh && \
    echo '# Set HOME so aws-vault and AWS CLI can find credentials' >> /app/entrypoint.sh && \
    echo 'export HOME=/home/headlamp' >> /app/entrypoint.sh && \
    echo '' >> /app/entrypoint.sh && \
    echo '# Set AWS configuration paths explicitly' >> /app/entrypoint.sh && \
    echo 'export AWS_CONFIG_FILE="${AWS_CONFIG_FILE:-/home/headlamp/.aws/config}"' >> /app/entrypoint.sh && \
    echo 'export AWS_SHARED_CREDENTIALS_FILE="${AWS_SHARED_CREDENTIALS_FILE:-/home/headlamp/.aws/credentials}"' >> /app/entrypoint.sh && \
    echo '[ -z "$AWS_VAULT_BACKEND" ] && export AWS_VAULT_BACKEND="${AWS_VAULT_BACKEND:-file}" || true' >> /app/entrypoint.sh && \
    echo '# Unset AWS_PROFILE when credentials provided via env vars' >> /app/entrypoint.sh && \
    echo '[ -n "$AWS_ACCESS_KEY_ID" ] && unset AWS_PROFILE || true' >> /app/entrypoint.sh && \
    echo '' >> /app/entrypoint.sh && \
    echo '# Switch to headlamp user and execute command with proper environment' >> /app/entrypoint.sh && \
    echo '# Pass through all necessary environment variables for AWS/eks exec commands' >> /app/entrypoint.sh && \
    echo '# Ensure PATH includes standard binary directories for aws, kubectl, etc.' >> /app/entrypoint.sh && \
    echo 'export PATH="/usr/local/bin:/usr/bin:/bin:$PATH"' >> /app/entrypoint.sh && \
    echo 'exec su-exec headlamp:headlamp env \' >> /app/entrypoint.sh && \
    echo '  PATH="/usr/local/bin:/usr/bin:/bin:$PATH" \' >> /app/entrypoint.sh && \
    echo '  HOME=/home/headlamp \' >> /app/entrypoint.sh && \
    echo '  KUBECONFIG="${KUBECONFIG:-/app/.kube/config}" \' >> /app/entrypoint.sh && \
    echo '  AWS_CONFIG_FILE="${AWS_CONFIG_FILE:-/home/headlamp/.aws/config}" \' >> /app/entrypoint.sh && \
    echo '  AWS_SHARED_CREDENTIALS_FILE="${AWS_SHARED_CREDENTIALS_FILE:-/home/headlamp/.aws/credentials}" \' >> /app/entrypoint.sh && \
    echo '  ${AWS_VAULT_BACKEND:+AWS_VAULT_BACKEND="$AWS_VAULT_BACKEND"} \' >> /app/entrypoint.sh && \
    echo '  ${AWS_ACCESS_KEY_ID:+AWS_ACCESS_KEY_ID="$AWS_ACCESS_KEY_ID"} \' >> /app/entrypoint.sh && \
    echo '  ${AWS_SECRET_ACCESS_KEY:+AWS_SECRET_ACCESS_KEY="$AWS_SECRET_ACCESS_KEY"} \' >> /app/entrypoint.sh && \
    echo '  ${AWS_SESSION_TOKEN:+AWS_SESSION_TOKEN="$AWS_SESSION_TOKEN"} \' >> /app/entrypoint.sh && \
    echo '  ${AWS_DEFAULT_REGION:+AWS_DEFAULT_REGION="$AWS_DEFAULT_REGION"} \' >> /app/entrypoint.sh && \
    echo '  ${AWS_REGION:+AWS_REGION="$AWS_REGION"} \' >> /app/entrypoint.sh && \
    echo '  ${AWS_PROFILE:+AWS_PROFILE="$AWS_PROFILE"} \' >> /app/entrypoint.sh && \
    echo '  "$@"' >> /app/entrypoint.sh && \
    chmod +x /app/entrypoint.sh

# Expose default Headlamp port (4466 is Headlamp's default, map to 3010 externally)
EXPOSE 4466

# Environment variables  
ENV HEADLAMP_PLUGIN_DIR=/app/plugins
ENV KUBECONFIG=/app/.kube/config

# Health check
HEALTHCHECK --interval=30s --timeout=3s --start-period=5s --retries=3 \
    CMD wget --no-verbose --tries=1 --spider http://localhost:4466/ || exit 1

# Entrypoint
# Using Headlamp's default port 4466 to avoid port parsing issues
# Map to desired port externally: docker run -p 3010:4466 ...
ENTRYPOINT ["/app/entrypoint.sh"]
CMD ["/app/headlamp", "-html-static-dir", "/app/frontend/build"]
