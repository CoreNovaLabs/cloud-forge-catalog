#!/usr/bin/env bash
# Cloud Forge Aliyun app bootstrap — installs runtime then loads shared compose package.
set -euo pipefail

APP_ID="${1:-}"
CATALOG_ROOT="${CLOUD_FORGE_CATALOG_URL:-https://cdn.jsdelivr.net/gh/CoreNovaLabs/cloud-forge-catalog@main}"
CATALOG_SCRIPTS="${CATALOG_ROOT}/scripts/aliyun"
COMPOSE_BASE="${CATALOG_ROOT}/apps/${APP_ID}/compose"
CLOUD_SETUP="${CATALOG_ROOT}/apps/${APP_ID}/aliyun/setup.sh"

if [[ -z "$APP_ID" ]]; then
  echo "usage: bootstrap-app.sh <app-id>" >&2
  exit 2
fi

if [[ ! "$APP_ID" =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?$ ]]; then
  echo "invalid app id: ${APP_ID}" >&2
  exit 2
fi

echo "==> Cloud Forge app bootstrap: ${APP_ID}"

curl -fsSL "${CATALOG_SCRIPTS}/bootstrap-runtime.sh" | sudo bash

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

run_optional_script() {
  local url="$1"
  local tmp
  tmp="$(mktemp)"
  if curl -fsSL "$url" -o "$tmp" 2>/dev/null; then
    sudo CLOUD_FORGE_CATALOG_URL="${CATALOG_ROOT}" bash "$tmp"
  fi
  rm -f "$tmp"
}

run_optional_script "${CLOUD_SETUP}"

catalog_app_env="$(mktemp)"
if ! curl -fsSL "${COMPOSE_BASE}/app.env" -o "$catalog_app_env"; then
  rm -f "$catalog_app_env"
  echo "missing compose package for ${APP_ID} (expected ${COMPOSE_BASE}/app.env)" >&2
  exit 1
fi
# shellcheck disable=SC1090
source "$catalog_app_env"
rm -f "$catalog_app_env"

UPSTREAM="${CLOUD_FORGE_CADDY_UPSTREAM:-}"
if [[ -z "$UPSTREAM" ]]; then
  echo "missing CLOUD_FORGE_CADDY_UPSTREAM in ${COMPOSE_BASE}/app.env" >&2
  exit 1
fi

if ! curl -fsSL "${COMPOSE_BASE}/docker-compose.yml" | sudo tee /opt/cloud-forge/docker-compose.app.yml >/dev/null; then
  echo "missing ${COMPOSE_BASE}/docker-compose.yml" >&2
  exit 1
fi

sudo tee /etc/cloud-forge/app.env >/dev/null <<EOF
CLOUD_FORGE_CADDY_PUBLIC_IP=${PUBLIC_IP}
CLOUD_FORGE_CADDY_UPSTREAM=${UPSTREAM}
CLOUD_FORGE_CADDY_TLS_MODE=${CADDY_TLS_MODE}
CLOUD_FORGE_CADDY_AUTO_IP_CERT=true
EOF

sudo /opt/cloud-forge/bin/cloud-forge-apply-app
echo "==> Cloud Forge app bootstrap complete: ${APP_ID}"
