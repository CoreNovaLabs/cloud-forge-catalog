#!/usr/bin/env bash
# Local Docker smoke test for a catalog app compose package.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
NETWORK="${CLOUD_FORGE_SMOKE_NETWORK:-cloud-forge}"
WAIT_SECONDS="${CLOUD_FORGE_SMOKE_WAIT:-90}"
POLL_INTERVAL="${CLOUD_FORGE_SMOKE_POLL_INTERVAL:-3}"
# Local smoke only: pull via registry mirror (default 毫秒镜像). Production compose keeps official image names.
SMOKE_REGISTRY_MIRROR="${CLOUD_FORGE_SMOKE_REGISTRY_MIRROR:-docker.1ms.run}"
SMOKE_PROBE_IMAGE="${CLOUD_FORGE_SMOKE_PROBE_IMAGE:-curlimages/curl:8.5.0}"
# Remove app images after each smoke run (default on) to avoid filling disk during batch onboard.
SMOKE_CLEAN_IMAGES="${CLOUD_FORGE_SMOKE_CLEAN_IMAGES:-1}"
PROBE_IMAGE_READY=0
TIER_FILTER=""
MODE=""
APP_ID=""

usage() {
  echo "usage: $0 <app-id>" >&2
  echo "       $0 --all [--tier certified|community|experimental]" >&2
  exit 2
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --all)
      MODE=all
      shift
      ;;
    --tier)
      TIER_FILTER="${2:-}"
      shift 2
      ;;
    --tier=*)
      TIER_FILTER="${1#--tier=}"
      shift
      ;;
    -h|--help)
      usage
      ;;
    *)
      if [[ -n "$APP_ID" ]]; then
        usage
      fi
      APP_ID="$1"
      shift
      ;;
  esac
done

if [[ -z "$MODE" && -z "$APP_ID" ]]; then
  usage
fi

if ! command -v docker >/dev/null 2>&1; then
  echo "error: docker is required" >&2
  exit 1
fi

if ! command -v jq >/dev/null 2>&1; then
  echo "error: jq is required" >&2
  exit 1
fi

ensure_network() {
  docker network inspect "$NETWORK" >/dev/null 2>&1 || docker network create "$NETWORK" >/dev/null
}

mirror_host() {
  local mirror="${1:-}"
  mirror="${mirror#https://}"
  mirror="${mirror#http://}"
  mirror="${mirror%/}"
  echo "$mirror"
}

pull_compose_images_via_mirror() {
  local compose_file="$1"
  local mirror host image smoke_tag img_id
  mirror="$(mirror_host "$SMOKE_REGISTRY_MIRROR")"
  if [[ -z "$mirror" ]]; then
    return 0
  fi

  host="$mirror"
  echo "  pulling via mirror ${host} (local smoke only)"

  while IFS= read -r image; do
    [[ -z "$image" ]] && continue

    if [[ "$image" == *@* ]]; then
      smoke_tag="${image%%@*}:cloud-forge-smoke"
      if docker image inspect "$smoke_tag" >/dev/null 2>&1; then
        echo "  cached ${smoke_tag}"
      elif docker pull "${host}/${image}"; then
        img_id="$(docker image inspect "${host}/${image}" --format '{{.Id}}')"
        docker tag "$img_id" "$smoke_tag"
        echo "  pulled ${smoke_tag} (from digest pin)"
      else
        echo "  mirror pull failed for ${image}, trying docker hub..." >&2
        docker pull "$image"
        smoke_tag="$image"
      fi
      if [[ "$(uname -s)" == "Darwin" ]]; then
        sed -i '' "s|image: ${image}|image: ${smoke_tag}|g" "$compose_file"
      else
        sed -i "s|image: ${image}|image: ${smoke_tag}|g" "$compose_file"
      fi
      continue
    fi

    if docker image inspect "$image" >/dev/null 2>&1; then
      echo "  cached ${image}"
      continue
    fi
    if docker pull "${host}/${image}"; then
      docker tag "${host}/${image}" "${image}"
      echo "  pulled ${image}"
      continue
    fi
    echo "  mirror pull failed for ${image}, trying docker hub..." >&2
    docker pull "$image"
  done < <(docker compose -f "$compose_file" config --images 2>/dev/null || true)
}

cleanup_smoke_images() {
  local compose_file="$1"
  if [[ "$SMOKE_CLEAN_IMAGES" != "1" ]]; then
    return 0
  fi

  local mirror host image
  mirror="$(mirror_host "$SMOKE_REGISTRY_MIRROR")"
  host="$mirror"

  echo "  removing smoke images (set CLOUD_FORGE_SMOKE_CLEAN_IMAGES=0 to keep)"
  while IFS= read -r image; do
    [[ -z "$image" ]] && continue
    docker rmi -f "$image" >/dev/null 2>&1 || true
    if [[ -n "$host" && "$image" != *@* ]]; then
      docker rmi -f "${host}/${image}" >/dev/null 2>&1 || true
    fi
  done < <(docker compose -f "$compose_file" config --images 2>/dev/null || true)
}

read_manifest_field() {
  local app="$1"
  local filter="$2"
  jq -r "$filter" "$ROOT/apps/$app/manifest.json"
}

parse_upstream() {
  local app="$1"
  local upstream
  upstream="$(grep '^CLOUD_FORGE_CADDY_UPSTREAM=' "$ROOT/apps/$app/compose/app.env" | cut -d= -f2-)"
  upstream="${upstream#*://}"
  UPSTREAM_HOST="${upstream%%:*}"
  UPSTREAM_PORT="${upstream##*:}"
}

probe_paths() {
  local app="$1"
  read_manifest_field "$app" '.smoke.health_paths // ["/", "/health"]' | jq -r '.[]'
}

ensure_probe_image() {
  if [[ "$PROBE_IMAGE_READY" -eq 1 ]]; then
    return 0
  fi
  local mirror host probe="$SMOKE_PROBE_IMAGE"
  mirror="$(mirror_host "$SMOKE_REGISTRY_MIRROR")"
  if [[ -z "$mirror" ]]; then
    probe="curlimages/curl:8.5.0"
    docker pull "$probe" >/dev/null 2>&1 || true
    SMOKE_PROBE_IMAGE="$probe"
  elif docker pull "${mirror}/${probe}" >/dev/null 2>&1; then
    SMOKE_PROBE_IMAGE="${mirror}/${probe}"
  else
    SMOKE_PROBE_IMAGE="curlimages/curl:8.5.0"
    docker pull "$SMOKE_PROBE_IMAGE" >/dev/null 2>&1 || true
  fi
  PROBE_IMAGE_READY=1
}

wait_for_http() {
  local project="$1"
  local svc="$2"
  local port="$3"
  local path="$4"
  local url="http://${svc}:${port}${path}"
  local deadline=$((SECONDS + WAIT_SECONDS))

  ensure_probe_image

  while (( SECONDS < deadline )); do
    if docker compose -p "$project" exec -T "$svc" sh -c \
      "command -v wget >/dev/null && wget -qO- '$url' >/dev/null 2>&1 || { command -v curl >/dev/null && curl -sf '$url' >/dev/null; }" 2>/dev/null; then
      echo "  OK ${url} (in-container)"
      return 0
    fi
    if docker run --rm --network "$NETWORK" "$SMOKE_PROBE_IMAGE" -fsSL "$url" >/dev/null 2>&1; then
      echo "  OK ${url}"
      return 0
    fi
    sleep "$POLL_INTERVAL"
  done

  echo "  FAIL ${url} (timeout ${WAIT_SECONDS}s)" >&2
  return 1
}

prepare_smoke_compose() {
  local app="$1"
  local src="$2"
  local smoke_dir="$ROOT/.local-smoke/$app"
  local smoke_compose="$smoke_dir/docker-compose.yml"
  mkdir -p "$smoke_dir/data"
  # Mac Docker Desktop cannot bind-mount /opt/cloud-forge; rewrite paths for local smoke only.
  sed "s|/opt/cloud-forge/data|${smoke_dir}/data|g" "$src" > "$smoke_compose"

  if grep -q '/opt/cloud-forge/compose.app.env' "$smoke_compose"; then
    local secret_env password
    secret_env="$(grep '^CLOUD_FORGE_SECRET_ENV=' "$ROOT/apps/$app/compose/app.env" | cut -d= -f2- || true)"
    password="${CLOUD_FORGE_SMOKE_ADMIN_PASSWORD:-}"
    if [[ -z "$password" ]]; then
      password="$(python3 - <<'PY'
import secrets
print(secrets.token_urlsafe(18))
PY
)"
      echo "  generated smoke AdminPassword (set CLOUD_FORGE_SMOKE_ADMIN_PASSWORD to pin)"
    fi
    if [[ -z "$secret_env" ]]; then
      echo "FAIL $app: compose requires secrets but app.env missing CLOUD_FORGE_SECRET_ENV" >&2
      return 1
    fi
    printf '%s=%s\n' "$secret_env" "$password" > "$smoke_dir/compose.app.env"
    if [[ "$(uname -s)" == "Darwin" ]]; then
      sed -i '' "s|/opt/cloud-forge/compose.app.env|${smoke_dir}/compose.app.env|g" "$smoke_compose"
    else
      sed -i "s|/opt/cloud-forge/compose.app.env|${smoke_dir}/compose.app.env|g" "$smoke_compose"
    fi
  fi

  echo "$smoke_compose"
}

smoke_one() {
  local app="$1"
  local manifest="$ROOT/apps/$app/manifest.json"
  local compose="$ROOT/apps/$app/compose/docker-compose.yml"

  if [[ ! -f "$manifest" || ! -f "$compose" ]]; then
    echo "SKIP $app (missing manifest or compose)" >&2
    return 1
  fi

  local tier
  tier="$(read_manifest_field "$app" '.tier // "community"')"
  if [[ -n "$TIER_FILTER" && "$tier" != "$TIER_FILTER" ]]; then
    echo "SKIP $app (tier=$tier)"
    return 0
  fi

  echo "==> local-smoke $app (tier=$tier)"

  local project="cf-smoke-${app//[^a-z0-9]/}"
  local svc ok=0 path
  local smoke_compose

  parse_upstream "$app"
  svc="$UPSTREAM_HOST"

  smoke_compose="$(prepare_smoke_compose "$app" "$compose")"

  ensure_network
  docker compose -f "$smoke_compose" -p "$project" down -v --remove-orphans >/dev/null 2>&1 || true

  manifest_wait="$(read_manifest_field "$app" '.smoke.wait_seconds // empty')"
  if [[ -n "$manifest_wait" && "$manifest_wait" != "null" ]]; then
    WAIT_SECONDS="$manifest_wait"
  elif [[ -n "${CLOUD_FORGE_SMOKE_WAIT:-}" ]]; then
    WAIT_SECONDS="${CLOUD_FORGE_SMOKE_WAIT}"
  fi

  pull_compose_images_via_mirror "$smoke_compose"

  if ! docker compose -f "$smoke_compose" -p "$project" up -d --wait; then
    echo "FAIL $app: docker compose up failed" >&2
    docker compose -f "$smoke_compose" -p "$project" logs >&2 || true
    docker compose -f "$smoke_compose" -p "$project" down -v --remove-orphans >/dev/null 2>&1 || true
    cleanup_smoke_images "$smoke_compose"
    return 1
  fi

  while IFS= read -r path; do
    [[ -z "$path" ]] && continue
    if wait_for_http "$project" "$svc" "$UPSTREAM_PORT" "$path"; then
      ok=1
      break
    fi
  done < <(probe_paths "$app")

  docker compose -f "$smoke_compose" -p "$project" down -v --remove-orphans >/dev/null 2>&1 || true
  cleanup_smoke_images "$smoke_compose"

  if [[ "$ok" -eq 1 ]]; then
    echo "PASS $app"
    return 0
  fi

  echo "FAIL $app: no health path responded" >&2
  return 1
}

if [[ "$MODE" == "all" ]]; then
  failed=0
  for manifest in "$ROOT"/apps/*/manifest.json; do
    app="$(basename "$(dirname "$manifest")")"
    [[ "$app" == "_template" ]] && continue
    smoke_one "$app" || failed=1
  done
  exit "$failed"
fi

smoke_one "$APP_ID"
