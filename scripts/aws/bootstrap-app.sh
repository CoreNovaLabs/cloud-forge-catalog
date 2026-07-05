#!/usr/bin/env bash
# Cloud Forge AWS app bootstrap — loads shared compose package on a pre-baked AMI.
set -euo pipefail

APP_ID="${1:-}"
CATALOG_ROOT="${CLOUD_FORGE_CATALOG_URL:-https://cdn.jsdelivr.net/gh/CoreNovaLabs/cloud-forge-catalog@main}"
COMPOSE_BASE="${CATALOG_ROOT}/apps/${APP_ID}/compose"
CLOUD_SETUP="${CATALOG_ROOT}/apps/${APP_ID}/aws/setup.sh"

if [[ -z "$APP_ID" ]]; then
  echo "usage: bootstrap-app.sh <app-id>" >&2
  exit 2
fi

if [[ ! "$APP_ID" =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?$ ]]; then
  echo "invalid app id: ${APP_ID}" >&2
  exit 2
fi

if [[ -z "${CLOUD_FORGE_CADDY_PUBLIC_IP:-}" ]]; then
  echo "missing CLOUD_FORGE_CADDY_PUBLIC_IP (set from CloudFormation UserData)" >&2
  exit 1
fi

echo "==> Cloud Forge AWS app bootstrap: ${APP_ID}"

run_as_root() {
  if [[ "$(id -u)" -eq 0 ]]; then
    "$@"
  else
    sudo "$@"
  fi
}

run_optional_script() {
  local url="$1"
  local tmp
  tmp="$(mktemp)"
  if curl -fsSL "$url" -o "$tmp" 2>/dev/null; then
    # Prefix env assignment must not go through run_as_root "$@" — as root that tries to exec the var name as a command.
    if [[ "$(id -u)" -eq 0 ]]; then
      umask 022
      CLOUD_FORGE_CATALOG_URL="${CATALOG_ROOT}" bash "$tmp"
    else
      sudo bash -c 'umask 022; CLOUD_FORGE_CATALOG_URL="'"${CATALOG_ROOT}"'" bash "$1"' _ "$tmp"
    fi
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

CADDY_TLS_MODE="${CLOUD_FORGE_CADDY_TLS_MODE:-ip-letsencrypt}"

ensure_cloud_forge_network() {
  run_as_root systemctl start docker || true
  if run_as_root docker network inspect cloud-forge >/dev/null 2>&1; then
    return 0
  fi
  echo "==> cloud-forge network missing; starting platform stack"
  if [[ -f /opt/cloud-forge/docker-compose.platform.yml ]]; then
    if [[ -x /opt/cloud-forge/bin/cloud-forge-caddy-config ]]; then
      run_as_root /opt/cloud-forge/bin/cloud-forge-caddy-config || true
    fi
    run_as_root docker compose --project-name cloud-forge-platform \
      -f /opt/cloud-forge/docker-compose.platform.yml up -d --remove-orphans || true
  fi
  if ! run_as_root docker network inspect cloud-forge >/dev/null 2>&1; then
    run_as_root docker network create cloud-forge
  fi
}

if ! curl -fsSL "${COMPOSE_BASE}/docker-compose.yml" | run_as_root tee /opt/cloud-forge/docker-compose.app.yml >/dev/null; then
  echo "missing ${COMPOSE_BASE}/docker-compose.yml" >&2
  exit 1
fi

run_as_root tee /etc/cloud-forge/app.env >/dev/null <<EOF
CLOUD_FORGE_CADDY_PUBLIC_IP=${CLOUD_FORGE_CADDY_PUBLIC_IP}
CLOUD_FORGE_CADDY_UPSTREAM=${UPSTREAM}
CLOUD_FORGE_CADDY_TLS_MODE=${CADDY_TLS_MODE}
CLOUD_FORGE_CADDY_AUTO_IP_CERT=true
EOF

if [[ -n "${CLOUD_FORGE_SECRET_ENV:-}" ]]; then
  admin_password="${CLOUD_FORGE_APP_ADMIN_PASSWORD:-}"
  if [[ -z "$admin_password" ]]; then
    echo "missing required AdminPassword (pass --admin-password or --param AdminPassword=...)" >&2
    exit 1
  fi
  run_as_root tee /opt/cloud-forge/compose.app.env >/dev/null <<EOF
${CLOUD_FORGE_SECRET_ENV}=${admin_password}
EOF
  run_as_root chmod 600 /opt/cloud-forge/compose.app.env
fi

ensure_cloud_forge_network
run_as_root /opt/cloud-forge/bin/cloud-forge-apply-app
echo "==> Cloud Forge AWS app bootstrap complete: ${APP_ID}"
