#!/usr/bin/env bash
# Local Docker smoke test for a catalog app compose package.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
NETWORK="${CLOUD_FORGE_SMOKE_NETWORK:-cloud-forge}"
WAIT_SECONDS="${CLOUD_FORGE_SMOKE_WAIT:-90}"
POLL_INTERVAL="${CLOUD_FORGE_SMOKE_POLL_INTERVAL:-3}"
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

wait_for_http() {
  local project="$1"
  local svc="$2"
  local port="$3"
  local path="$4"
  local url="http://127.0.0.1:${port}${path}"
  local deadline=$((SECONDS + WAIT_SECONDS))

  while (( SECONDS < deadline )); do
    if docker compose -p "$project" exec -T "$svc" sh -c \
      "command -v wget >/dev/null && wget -qO- '$url' || curl -sf '$url'" >/dev/null 2>&1; then
      echo "  OK ${svc}:${port}${path}"
      return 0
    fi
    sleep "$POLL_INTERVAL"
  done

  echo "  FAIL ${svc}:${port}${path} (timeout ${WAIT_SECONDS}s)" >&2
  return 1
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

  parse_upstream "$app"
  svc="$UPSTREAM_HOST"

  ensure_network
  docker compose -f "$compose" -p "$project" down -v --remove-orphans >/dev/null 2>&1 || true

  if ! docker compose -f "$compose" -p "$project" up -d --wait; then
    echo "FAIL $app: docker compose up failed" >&2
    docker compose -f "$compose" -p "$project" logs >&2 || true
    docker compose -f "$compose" -p "$project" down -v --remove-orphans >/dev/null 2>&1 || true
    return 1
  fi

  while IFS= read -r path; do
    [[ -z "$path" ]] && continue
    if wait_for_http "$project" "$svc" "$UPSTREAM_PORT" "$path"; then
      ok=1
      break
    fi
  done < <(probe_paths "$app")

  docker compose -f "$compose" -p "$project" down -v --remove-orphans >/dev/null 2>&1 || true

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
