#!/usr/bin/env bash
# Cloud Forge Aliyun app bootstrap — installs runtime then loads shared compose package.
set -euo pipefail

APP_ID="${1:-}"
CATALOG_ROOT="${CLOUD_FORGE_CATALOG_URL:-https://cdn.jsdelivr.net/gh/CoreNovaLabs/cloud-forge-catalog@v0.5.0}"
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
DOMAIN_NAME="${CLOUD_FORGE_DOMAIN_NAME:-}"
CADDY_EMAIL="${CLOUD_FORGE_CADDY_EMAIL:-}"

if [[ -n "$DOMAIN_NAME" && "$CADDY_TLS_MODE" == "ip-letsencrypt" ]]; then
  CADDY_TLS_MODE="auto"
fi

AUTO_IP_CERT=true
if [[ -n "$DOMAIN_NAME" ]]; then
  AUTO_IP_CERT=false
fi

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

resolve_immutable_app_image() {
  local version="${CLOUD_FORGE_APP_VERSION:-}"
  local expected_sha="${CLOUD_FORGE_APP_MANIFEST_SHA256:-}"
  local manifest_file actual_sha image

  if [[ -z "$version" || -z "$expected_sha" ]]; then
    return 0
  fi
  if [[ ! "$version" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$ ]]; then
    echo "invalid application version: ${version}" >&2
    exit 1
  fi
  if [[ ! "$expected_sha" =~ ^[a-f0-9]{64}$ ]]; then
    echo "invalid application manifest checksum" >&2
    exit 1
  fi

  manifest_file="$(mktemp)"
  if ! curl -fsSL "${CATALOG_ROOT}/apps/${APP_ID}/manifest.json" -o "$manifest_file"; then
    rm -f "$manifest_file"
    echo "could not load immutable version manifest for ${APP_ID}" >&2
    exit 1
  fi
  actual_sha="$(sha256sum "$manifest_file" | awk '{print $1}')"
  if [[ "$actual_sha" != "$expected_sha" ]]; then
    rm -f "$manifest_file"
    echo "version manifest checksum mismatch for ${APP_ID}" >&2
    exit 1
  fi
  image="$(jq -er --arg version "$version" '
    .versions.items[]
    | select(.version == $version)
    | select((if has("deployable") then .deployable else true end) == true)
    | .image
    | select(type == "string" and length > 0)
  ' "$manifest_file" 2>/dev/null || true)"
  rm -f "$manifest_file"
  if [[ ! "$image" =~ ^[a-z0-9][a-z0-9.-]*(:[0-9]+)?/[A-Za-z0-9_./-]+@sha256:[a-f0-9]{64}$ ]]; then
    echo "version ${version} is not deployable with an immutable image" >&2
    exit 1
  fi
  export CLOUD_FORGE_APP_IMAGE="$image"
}

resolve_immutable_app_image

APP_ROLE="${CLOUD_FORGE_AMI_ROLE:-web}"

if [[ "$APP_ROLE" == "db" || "$APP_ROLE" == "tcp" ]]; then
  if ! curl -fsSL "${COMPOSE_BASE}/docker-compose.yml" | sudo tee /opt/cloud-forge/docker-compose.app.yml >/dev/null; then
    echo "missing ${COMPOSE_BASE}/docker-compose.yml" >&2
    exit 1
  fi

  if [[ -n "${CLOUD_FORGE_SECRET_ENV:-}" ]]; then
    admin_password="${CLOUD_FORGE_APP_ADMIN_PASSWORD:-}"
    if [[ -z "$admin_password" ]]; then
      echo "missing required AdminPassword (pass --admin-password or --param AdminPassword=...)" >&2
      exit 1
    fi
    sudo tee /opt/cloud-forge/compose.app.env >/dev/null <<EOF
${CLOUD_FORGE_SECRET_ENV}=${admin_password}
EOF
    sudo chmod 600 /opt/cloud-forge/compose.app.env
  fi

  sudo systemctl start docker || true
  sudo env CLOUD_FORGE_APP_VERSION="${CLOUD_FORGE_APP_VERSION:-}" CLOUD_FORGE_APP_IMAGE="${CLOUD_FORGE_APP_IMAGE:-}" docker compose -f /opt/cloud-forge/docker-compose.app.yml up -d --remove-orphans
  echo "==> Cloud Forge app bootstrap complete: ${APP_ID}"
  exit 0
fi

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
CLOUD_FORGE_DOMAIN_NAME=${DOMAIN_NAME}
CLOUD_FORGE_CADDY_PUBLIC_IP=${PUBLIC_IP}
CLOUD_FORGE_CADDY_UPSTREAM=${UPSTREAM}
CLOUD_FORGE_CADDY_TLS_MODE=${CADDY_TLS_MODE}
CLOUD_FORGE_CADDY_AUTO_IP_CERT=${AUTO_IP_CERT}
CLOUD_FORGE_APP_VERSION=${CLOUD_FORGE_APP_VERSION:-}
CLOUD_FORGE_APP_IMAGE=${CLOUD_FORGE_APP_IMAGE:-}
EOF

if [[ -n "$CADDY_EMAIL" ]]; then
  sudo tee -a /etc/cloud-forge/app.env >/dev/null <<EOF
CLOUD_FORGE_CADDY_EMAIL=${CADDY_EMAIL}
EOF
fi

if [[ -n "${CLOUD_FORGE_SECRET_ENV:-}" ]]; then
  admin_password="${CLOUD_FORGE_APP_ADMIN_PASSWORD:-}"
  if [[ -z "$admin_password" ]]; then
    echo "missing required AdminPassword (pass --admin-password or --param AdminPassword=...)" >&2
    exit 1
  fi
  sudo tee /opt/cloud-forge/compose.app.env >/dev/null <<EOF
${CLOUD_FORGE_SECRET_ENV}=${admin_password}
EOF
  sudo chmod 600 /opt/cloud-forge/compose.app.env
fi

sudo env CLOUD_FORGE_APP_VERSION="${CLOUD_FORGE_APP_VERSION:-}" CLOUD_FORGE_APP_IMAGE="${CLOUD_FORGE_APP_IMAGE:-}" /opt/cloud-forge/bin/cloud-forge-apply-app
echo "==> Cloud Forge app bootstrap complete: ${APP_ID}"
