#!/usr/bin/env bash
# Cloud Forge Aliyun app bootstrap — installs runtime then configures the catalog app.
set -euo pipefail

APP_ID="${1:-}"
CATALOG_ROOT="${CLOUD_FORGE_CATALOG_URL:-https://cdn.jsdelivr.net/gh/CoreNovaLabs/cloud-forge-catalog@main}"
CATALOG_BASE="${CATALOG_ROOT}/scripts/aliyun"

if [[ -z "$APP_ID" ]]; then
  echo "usage: bootstrap-app.sh <app-id>" >&2
  exit 2
fi

echo "==> Cloud Forge app bootstrap: ${APP_ID}"

curl -fsSL "${CATALOG_BASE}/bootstrap-runtime.sh" | sudo bash

fetch_public_ipv4() {
  local ip=""
  for path in eipv4 public-ipv4; do
    ip="$(curl -fsS --connect-timeout 3 --max-time 5 "http://100.100.100.200/latest/meta-data/${path}" 2>/dev/null || true)"
    if [[ -n "$ip" ]]; then
      printf '%s' "$ip"
      return 0
    fi
  done
  return 1
}

PUBLIC_IP="${CLOUD_FORGE_CADDY_PUBLIC_IP:-}"
if [[ -z "$PUBLIC_IP" ]]; then
  PUBLIC_IP="$(fetch_public_ipv4 || true)"
fi
if [[ -z "$PUBLIC_IP" ]]; then
  echo "warning: could not detect public IPv4; HTTPS ip-letsencrypt may fail" >&2
fi

CADDY_TLS_MODE="${CLOUD_FORGE_CADDY_TLS_MODE:-ip-letsencrypt}"
UPSTREAM=""
COMPOSE_FILE=""

case "$APP_ID" in
  hello-nginx)
    sudo install -d -m 0755 /opt/cloud-forge/data/hello-nginx/html
    sudo tee /opt/cloud-forge/data/hello-nginx/html/index.html >/dev/null <<'HTML'
<!doctype html>
<html lang="en">
<head><meta charset="utf-8"><title>Cloud Forge</title></head>
<body><h1>Hello from Cloud Forge</h1><p>NGINX is running on Aliyun.</p></body>
</html>
HTML
    COMPOSE_FILE="services:
  nginx:
    image: nginx:1.27-alpine
    restart: unless-stopped
    volumes:
      - /opt/cloud-forge/data/hello-nginx/html:/usr/share/nginx/html:ro
    networks:
      - cloud-forge"
    UPSTREAM="http://nginx:80"
    ;;
  n8n)
    sudo install -d -m 0755 /opt/cloud-forge/data/n8n
    sudo chown -R 1000:1000 /opt/cloud-forge/data/n8n
    COMPOSE_FILE="services:
  n8n:
    image: n8nio/n8n:1.76.1
    restart: unless-stopped
    environment:
      - N8N_PORT=5678
      - N8N_PROTOCOL=http
    volumes:
      - /opt/cloud-forge/data/n8n:/home/node/.n8n
    networks:
      - cloud-forge"
    UPSTREAM="http://n8n:5678"
    ;;
  gitea)
    sudo install -d -m 0755 /opt/cloud-forge/data/gitea
    COMPOSE_FILE="services:
  gitea:
    image: gitea/gitea:1.22
    restart: unless-stopped
    volumes:
      - /opt/cloud-forge/data/gitea:/data
    networks:
      - cloud-forge"
    UPSTREAM="http://gitea:3000"
    ;;
  uptime-kuma)
    sudo install -d -m 0755 /opt/cloud-forge/data/uptime-kuma
    COMPOSE_FILE="services:
  uptime-kuma:
    image: louislam/uptime-kuma:1
    restart: unless-stopped
    volumes:
      - /opt/cloud-forge/data/uptime-kuma:/app/data
    networks:
      - cloud-forge"
    UPSTREAM="http://uptime-kuma:3001"
    ;;
  *)
    echo "unsupported app id: ${APP_ID}" >&2
    exit 1
    ;;
esac

sudo tee /opt/cloud-forge/docker-compose.app.yml >/dev/null <<EOF
${COMPOSE_FILE}
EOF

sudo tee /etc/cloud-forge/app.env >/dev/null <<EOF
CLOUD_FORGE_CADDY_PUBLIC_IP=${PUBLIC_IP}
CLOUD_FORGE_CADDY_UPSTREAM=${UPSTREAM}
CLOUD_FORGE_CADDY_TLS_MODE=${CADDY_TLS_MODE}
CLOUD_FORGE_CADDY_AUTO_IP_CERT=true
EOF

sudo /opt/cloud-forge/bin/cloud-forge-apply-app
echo "==> Cloud Forge app bootstrap complete: ${APP_ID}"
