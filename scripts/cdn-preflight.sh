#!/usr/bin/env bash
# Verify catalog compose packages are reachable on CDN before cloud deploy.
# ECS/EC2 bootstrap pulls apps/<id>/compose/* from jsDelivr, not from local file://.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CDN_REPO="${CLOUD_FORGE_CDN_REPO:-CoreNovaLabs/cloud-forge-catalog}"
CDN_REF="${CLOUD_FORGE_CDN_REF:-main}"
CDN_BASE="https://cdn.jsdelivr.net/gh/${CDN_REPO}@${CDN_REF}"
RETRIES="${CLOUD_FORGE_CDN_PREFLIGHT_RETRIES:-3}"
RETRY_DELAY="${CLOUD_FORGE_CDN_PREFLIGHT_RETRY_DELAY:-30}"
TIER_FILTER=""
MODE=""
APP_ID=""

usage() {
  echo "usage: $0 <app-id>" >&2
  echo "       $0 --all [--tier certified|community|experimental]" >&2
  echo "       $0 --ref <git-ref> <app-id>   # pin CDN to commit tag/sha" >&2
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
    --ref)
      CDN_REF="${2:-}"
      CDN_BASE="https://cdn.jsdelivr.net/gh/${CDN_REPO}@${CDN_REF}"
      shift 2
      ;;
    --ref=*)
      CDN_REF="${1#--ref=}"
      CDN_BASE="https://cdn.jsdelivr.net/gh/${CDN_REPO}@${CDN_REF}"
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

if ! command -v curl >/dev/null 2>&1; then
  echo "error: curl is required" >&2
  exit 1
fi
if ! command -v jq >/dev/null 2>&1; then
  echo "error: jq is required" >&2
  exit 1
fi

fetch_ok() {
  local url="$1"
  local attempt=1
  while (( attempt <= RETRIES )); do
    if curl -fsSL --connect-timeout 15 --max-time 60 "$url" >/dev/null 2>&1; then
      return 0
    fi
    if (( attempt < RETRIES )); then
      echo "  retry ${attempt}/${RETRIES} for ${url} (wait ${RETRY_DELAY}s)" >&2
      sleep "$RETRY_DELAY"
    fi
    attempt=$((attempt + 1))
  done
  return 1
}

read_manifest_field() {
  local app="$1"
  local filter="$2"
  jq -r "$filter" "$ROOT/apps/$app/manifest.json"
}

check_index_entry() {
  local app="$1"
  local index_url="${CDN_BASE}/index/apps.json"
  local body
  if ! body="$(curl -fsSL --connect-timeout 15 --max-time 60 "$index_url")"; then
    echo "  FAIL index/apps.json unreachable" >&2
    return 1
  fi
  if ! echo "$body" | jq -e --arg id "$app" '.apps[] | select(.id == $id)' >/dev/null 2>&1; then
    echo "  FAIL index/apps.json missing app id ${app}" >&2
    return 1
  fi
  echo "  OK   index/apps.json contains ${app}"
  return 0
}

preflight_one() {
  local app="$1"
  local manifest="$ROOT/apps/$app/manifest.json"
  local ok=1

  if [[ ! -f "$manifest" ]]; then
    echo "SKIP $app (missing manifest)" >&2
    return 1
  fi

  local tier
  tier="$(read_manifest_field "$app" '.tier // "community"')"
  if [[ -n "$TIER_FILTER" && "$tier" != "$TIER_FILTER" ]]; then
    echo "SKIP $app (tier=$tier)"
    return 0
  fi

  echo "==> cdn-preflight $app (tier=$tier, ref=${CDN_REF})"

  local path url
  for path in \
    "apps/${app}/compose/app.env" \
    "apps/${app}/compose/docker-compose.yml" \
    "scripts/aliyun/bootstrap-app.sh"; do
    url="${CDN_BASE}/${path}"
    if fetch_ok "$url"; then
      echo "  OK   ${path}"
    else
      echo "  FAIL ${path} (${url})" >&2
      ok=0
    fi
  done

  if ! check_index_entry "$app"; then
    ok=0
  fi

  if [[ "$ok" -eq 1 ]]; then
    echo "PASS $app"
    return 0
  fi

  echo "FAIL $app: CDN preflight (push catalog and wait for jsDelivr sync, or pass --ref <commit>)" >&2
  return 1
}

echo "CDN base: ${CDN_BASE}"

if [[ "$MODE" == "all" ]]; then
  failed=0
  for manifest in "$ROOT"/apps/*/manifest.json; do
    app="$(basename "$(dirname "$manifest")")"
    [[ "$app" == "_template" ]] && continue
    preflight_one "$app" || failed=1
  done
  exit "$failed"
fi

preflight_one "$APP_ID"
