# Headlamp Docker Image

A reusable Docker image for running [Headlamp](https://github.com/kubernetes-sigs/headlamp), a fully-featured, user-friendly, and extensible Kubernetes web UI.

## Features

- **Multi-stage build** for optimized image size
- **Linux-optimized** for amd64 and arm64 platforms
- **Flexible deployment** supporting both in-cluster and local/desktop usage
- **Plugin support** with optional plugin directory mounting
- **Non-root user** for enhanced security
- **Version pinning** via build arguments
- **AWS EKS support** with included `kubectl`, AWS CLI, and `aws-vault` for cluster authentication
- **Multi-cluster support** - works with kubeconfig files containing multiple clusters/contexts

## Quick Start

### Using Pre-built Images

If using CI/CD, images are automatically built and published to GitHub Container Registry:

```bash
docker pull ghcr.io/platformfuzz/headlamp-image:latest
```

### Build the Image Locally

```bash
# Build with default settings (latest main branch)
docker build -t headlamp:latest .

# Build with specific Headlamp version
docker build --build-arg HEADLAMP_VERSION=v0.39.0 -t headlamp:v0.39.0 .
```

### Run with aws-vault (Recommended for EKS)

**For aws-vault keyring users (secret-service/keychain) - REQUIRED:**

```bash
aws-vault exec <profile> -- docker compose up -d
# Or with the helper script
aws-vault exec <profile> -- ./docker-run.sh --force
```

**For aws-vault file backend users:**

```bash
# Option 1: Use aws-vault exec (recommended)
aws-vault exec <profile> -- docker compose up -d
# Or with the helper script
aws-vault exec <profile> -- ./docker-run.sh --force

# Option 2: Mount vault storage
docker compose up -d
# (with vault mounts uncommented in docker-compose.yml)
```

### Run Locally (Basic)

```bash
# Using Docker
docker run -d \
  --name headlamp \
  -p 3010:4466 \
  -v ${HOME}/.kube/config:/app/.kube/config:ro \
  headlamp:latest

# Using Docker Compose
docker compose up -d
```

Access Headlamp at `http://localhost:3010`

### Replace Existing Container (Quick Start)

To always replace an existing container (useful for updates):

```bash
# Using Docker
docker rm -f headlamp 2>/dev/null || true
docker run -d \
  --name headlamp \
  -p 3010:4466 \
  -v ${HOME}/.kube/config:/app/.kube/config:ro \
  headlamp:latest

# Using Docker Compose
docker compose down
docker compose up -d

# Or use the helper script with --force flag
./docker-run.sh --force

# With aws-vault (for EKS authentication)
aws-vault exec <profile> -- ./docker-run.sh --force
```

## Build Arguments

| Argument | Default | Description |
| -------- | ------- | ----------- |
| `HEADLAMP_VERSION` | `main` | Headlamp version/tag/branch to build |
| `NODE_VERSION` | `22.9.0` | Node.js version for build stage |
| `GO_VERSION` | `1.23.5` | Go version for build stage |

## Environment Variables

| Variable | Default | Description |
| -------- | ------- | ----------- |
| `HEADLAMP_PLUGIN_DIR` | `/app/plugins` | Directory for Headlamp plugins |
| `KUBECONFIG` | `/app/.kube/config` | Path to kubeconfig file |
| `AWS_CONFIG_FILE` | `/home/headlamp/.aws/config` | AWS config file path |
| `AWS_SHARED_CREDENTIALS_FILE` | `/home/headlamp/.aws/credentials` | AWS credentials file path |

## Volume Mounts

### Required

- **Kubeconfig**: Mount your kubeconfig file

  ```bash
  -v ${HOME}/.kube/config:/app/.kube/config:ro
  ```

### Optional

- **AWS Credentials** (for EKS with file backend only):

  ```bash
  -v ${HOME}/.aws:/home/headlamp/.aws:ro
  ```

- **aws-vault Storage** (for file backend only):

  ```bash
  -v ${HOME}/.awsvault:/home/headlamp/.awsvault:ro
  -v ${HOME}/.awsvaultk:/home/headlamp/.awsvaultk:ro
  ```

- **Plugins**:

  ```bash
  -v ./plugins:/app/plugins:ro
  ```

## Usage Examples

### With aws-vault (Keyring Backend - Recommended)

If you use aws-vault with keyring backend (secret-service/keychain), you **must** use `aws-vault exec`:

```bash
aws-vault exec <profile> -- docker compose up -d
# Or with the helper script
aws-vault exec <profile> -- ./docker-run.sh --force
```

This passes temporary AWS credentials as environment variables. The container automatically receives:

- `AWS_ACCESS_KEY_ID`
- `AWS_SECRET_ACCESS_KEY`
- `AWS_SESSION_TOKEN`
- `AWS_DEFAULT_REGION`

**Why this approach?**

- ✅ Works with any aws-vault backend (keyring, file, etc.)
- ✅ No need to mount vault storage
- ✅ Credentials are temporary and automatically rotated
- ✅ Required for keyring backends (can't mount keyring credentials)

### With aws-vault (File Backend)

If using file backend, you have two options:

#### Option 1: Use aws-vault exec (recommended)

```bash
aws-vault exec <profile> -- docker compose up -d
# Or with the helper script
aws-vault exec <profile> -- ./docker-run.sh --force
```

#### Option 2: Mount vault storage

```bash
# Uncomment vault mounts in docker-compose.yml, then:
docker compose up -d
```

### Custom Port

```bash
docker run -d \
  --name headlamp \
  -p 8080:4466 \
  -v ${HOME}/.kube/config:/app/.kube/config:ro \
  headlamp:latest
```

### Custom Plugins

```bash
docker run -d \
  --name headlamp \
  -p 3010:4466 \
  -v ${HOME}/.kube/config:/app/.kube/config:ro \
  -v ./my-plugins:/app/plugins:ro \
  headlamp:latest
```

## Troubleshooting

### Accessing Container Shell

```bash
# Access running container
docker exec -it headlamp sh

# Test AWS credentials
docker exec headlamp env | grep AWS

# Test kubectl
docker exec headlamp sh -c 'export KUBECONFIG=/tmp/.kube/config && kubectl get nodes'
```

### Cannot Connect to Cluster (502 Bad Gateway)

1. **Verify AWS credentials are in container:**

   ```bash
   docker exec headlamp env | grep AWS_ACCESS_KEY_ID
   ```

2. **Test exec command:**

   ```bash
   docker exec headlamp sh -c 'aws eks get-token --cluster-name <name> --region <region>'
   ```

3. **If using aws-vault keyring:** You **must** use `aws-vault exec` to run the container:

   ```bash
   aws-vault exec <profile> -- docker compose up -d
   ```

### Replace Existing Container (Troubleshooting)

```bash
# Stop and remove
docker compose down
# Or
docker rm -f headlamp

# Start fresh
docker compose up -d
```

### Permission Denied Errors

The container runs as non-root user (UID 1000). The entrypoint script automatically handles kubeconfig permissions by copying to `/tmp/.kube/config` if needed.

## Kubernetes Deployment

For in-cluster deployment, see [kubernetes-deployment.yaml](kubernetes-deployment.yaml). Headlamp uses Kubernetes Service Account tokens for authentication - no kubeconfig mount needed.

## Security Considerations

- Image runs as non-root user (`headlamp:headlamp`, UID 1000)
- Minimal Alpine Linux base image
- Read-only volume mounts where possible
- AWS credentials passed as temporary environment variables (when using aws-vault exec)

## CI/CD

This repository includes GitHub Actions workflows for automated builds and quality checks:

- **Build and Release** (`build-and-release.yml`): Builds and publishes images on push to main and version tags
- **CI** (`ci.yml`): Builds and tests images on pull requests
- **Markdown Lint** (`markdown-lint.yml`): Lints markdown files in PRs
- **Commit Message Conformance** (`commitmsg-conform.yml`): Validates commit message format
- **Auto-merge** (`auto-merge.yml`): Automatically merges Dependabot PRs

Features:

- **Automated builds** on push to main and version tags
- **Automatic publishing** to GitHub Container Registry (GHCR)
- **Automatic releases** when version tags are pushed
- **Build caching** for faster builds
- **Quality checks** for code and documentation

Images are published to: `ghcr.io/platformfuzz/headlamp-image`

To use the pre-built images:

```bash
docker pull ghcr.io/platformfuzz/headlamp-image:latest
```

## License

Apache 2.0

## References

- [Headlamp Project](https://github.com/kubernetes-sigs/headlamp)
- [Headlamp Documentation](https://headlamp.dev/docs/latest/)
