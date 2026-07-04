#!/usr/bin/env bash
# Cloud Forge Aliyun runtime bootstrap (Alibaba Cloud Linux 3, yum).
# Installs Docker, Docker Compose plugin, and the Caddy platform stack.
set -euo pipefail

if [[ -f /etc/cloud-forge/.runtime-ready ]]; then
  exit 0
fi

CLOUD_FORGE_VERSION="${CLOUD_FORGE_VERSION:-0.3.0}"
CLOUD_FORGE_CADDY_IMAGE="${CLOUD_FORGE_CADDY_IMAGE:-caddy:2.11.4}"
PLATFORM_COMPOSE="/opt/cloud-forge/docker-compose.platform.yml"

echo "==> Cloud Forge Aliyun runtime bootstrap"

# Skip full yum update on first boot (saves time).
sudo yum install -y \
  ca-certificates \
  curl \
  gzip \
  jq \
  tar \
  unzip

sudo install -d -m 0755 \
  /opt/cloud-forge/bin \
  /opt/cloud-forge/apps \
  /var/log/cloud-forge \
  /etc/cloud-forge \
  /opt/cloud-forge/installers \
  /opt/cloud-forge/state \
  /etc/caddy \
  /var/www/cloud-forge

sudo tee /etc/cloud-forge-release >/dev/null <<EOF
CLOUD_FORGE_PRODUCT=cloud-forge-aliyun-bootstrap
CLOUD_FORGE_VERSION=${CLOUD_FORGE_VERSION}
CLOUD_FORGE_BASE=alibaba-cloud-linux-3
EOF

sudo tee /etc/cloud-forge/default.env >/dev/null <<EOF
CLOUD_FORGE_APP_ROOT=/opt/cloud-forge/apps
CLOUD_FORGE_LOG_DIR=/var/log/cloud-forge
CLOUD_FORGE_INSTALLER_ROOT=/opt/cloud-forge/installers
CLOUD_FORGE_STATE_ROOT=/opt/cloud-forge/state
CLOUD_FORGE_CADDY_SITE=
CLOUD_FORGE_CADDY_UPSTREAM=
CLOUD_FORGE_CADDY_TLS_MODE=auto
CLOUD_FORGE_CADDY_AUTO_IP_CERT=false
CLOUD_FORGE_CADDY_PUBLIC_IP=
CLOUD_FORGE_CADDY_IP_CERT_CA=https://acme-v02.api.letsencrypt.org/directory
CLOUD_FORGE_CADDY_IP_CERT_PROFILE=shortlived
CLOUD_FORGE_CADDY_IP_CERT_FALLBACK=http
CLOUD_FORGE_CADDY_INTERNAL_TLS=false
CLOUD_FORGE_CADDY_EMAIL=
CLOUD_FORGE_CADDY_IMAGE=${CLOUD_FORGE_CADDY_IMAGE}
EOF

echo "==> Installing Docker CE (Alinux3: avoid podman-docker shim)"
if ! docker compose version >/dev/null 2>&1; then
  if rpm -q podman-docker >/dev/null 2>&1; then
    sudo yum remove -y podman-docker || true
  fi
  if [[ ! -f /etc/yum.repos.d/docker-ce.repo ]]; then
    sudo curl -fsSL https://mirrors.aliyun.com/docker-ce/linux/centos/docker-ce.repo -o /etc/yum.repos.d/docker-ce.repo
  fi
  sudo yum install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin
fi
sudo install -d -m 0755 /etc/docker
sudo tee /etc/docker/daemon.json >/dev/null <<'EOF'
{
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "10m",
    "max-file": "5"
  },
  "live-restore": true
}
EOF
sudo systemctl enable docker
sudo systemctl start docker

if id ecs-user &>/dev/null; then
  sudo usermod -aG docker ecs-user || true
fi

if ! docker compose version >/dev/null 2>&1; then
  echo "docker compose plugin is required but could not be installed" >&2
  exit 1
fi

echo "==> Installing Caddy platform stack"
sudo tee /var/www/cloud-forge/index.html >/dev/null <<'EOF'
<!doctype html>
<html lang="en">
<head><meta charset="utf-8"><title>Cloud Forge Runtime</title></head>
<body><h1>Cloud Forge Runtime</h1><p>Aliyun bootstrap runtime is online.</p></body>
</html>
EOF

sudo tee "$PLATFORM_COMPOSE" >/dev/null <<EOF
name: cloud-forge-platform

networks:
  cloud-forge:
    name: cloud-forge

services:
  caddy:
    image: ${CLOUD_FORGE_CADDY_IMAGE}
    restart: unless-stopped
    ports:
      - "80:80"
      - "443:443"
    volumes:
      - /etc/caddy/Caddyfile:/etc/caddy/Caddyfile:ro
      - caddy_data:/data
      - caddy_config:/config
      - /var/www/cloud-forge:/var/www/cloud-forge:ro
    networks:
      - cloud-forge

volumes:
  caddy_data:
  caddy_config:
EOF

# Reuse the Caddy platform helpers from the catalog bundle.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -f "${SCRIPT_DIR}/install-caddy-aliyun.sh" ]]; then
  sudo bash "${SCRIPT_DIR}/install-caddy-aliyun.sh"
else
  curl -fsSL "https://cdn.jsdelivr.net/gh/CoreNovaLabs/cloud-forge-catalog@main/scripts/aliyun/install-caddy-aliyun.sh" | sudo bash
fi

sudo touch /etc/cloud-forge/.runtime-ready
echo "==> Cloud Forge runtime bootstrap complete"
