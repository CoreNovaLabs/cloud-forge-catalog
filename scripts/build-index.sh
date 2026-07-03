#!/usr/bin/env bash
# Build index/apps.json from apps/*/manifest.json and template sha256 checksums.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
INDEX="$ROOT/index/apps.json"
BASE_URL="${CATALOG_BASE_URL:-https://raw.githubusercontent.com/CoreNovaLabs/cloud-forge-catalog/main}"

sha256_file() {
  local f="$1"
  if command -v shasum >/dev/null 2>&1; then
    echo "sha256:$(shasum -a 256 "$f" | awk '{print $1}')"
  else
    echo "sha256:$(sha256sum "$f" | awk '{print $1}')"
  fi
}

apps_json="["
first=true

for manifest in "$ROOT"/apps/*/manifest.json; do
  [ -f "$manifest" ] || continue
  app_dir="$(dirname "$manifest")"
  app_id="$(basename "$app_dir")"

  if ! command -v jq >/dev/null 2>&1; then
    echo "error: jq is required to run build-index.sh" >&2
    exit 1
  fi

  entry="$(jq -c \
    --arg base "$BASE_URL" \
    --arg id "$app_id" \
    '
    . as $m
    | ($m.templates // {}) as $tpl
    | $m
    | .templates = (
        ($tpl.aws.path // "") as $aws
        | ($tpl.aliyun.path // "") as $ali
        | {}
        | if $aws != "" then .aws = {path: $aws, url: ($base + "/" + $aws)} else . end
        | if $ali != "" then .aliyun = {path: $ali, url: ($base + "/" + $ali)} else . end
      )
    ' "$manifest")"

  # Append checksums from template files.
  for cloud in aws aliyun; do
    path="$(jq -r ".templates.${cloud}.path // empty" "$manifest")"
    if [ -n "$path" ] && [ -f "$ROOT/$path" ]; then
      sum="$(sha256_file "$ROOT/$path")"
      entry="$(echo "$entry" | jq -c --arg cloud "$cloud" --arg sum "$sum" \
        '.templates[$cloud].checksum = $sum')"
    fi
  done

  if [ "$first" = true ]; then
    first=false
  else
    apps_json+=","
  fi
  apps_json+="$entry"
done

apps_json+="]"

mkdir -p "$(dirname "$INDEX")"

generated="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
new_fingerprint="$(jq -nc \
  --arg version "0.2.0" \
  --arg base "$BASE_URL" \
  --argjson apps "$apps_json" \
  '{
    catalog_version: $version,
    base_url: $base,
    store: {
      name: "Cloud Forge App Store",
      description: "One-command open-source app deployment powered by immutable images"
    },
    apps: $apps
  }')"

if [ -f "$INDEX" ]; then
  existing_fingerprint="$(jq -c '{catalog_version, base_url, store, apps}' "$INDEX" 2>/dev/null || true)"
  if [ "$existing_fingerprint" = "$new_fingerprint" ]; then
    existing_generated="$(jq -r '.generated_at // empty' "$INDEX" 2>/dev/null || true)"
    if [ -n "$existing_generated" ]; then
      generated="$existing_generated"
    fi
  fi
fi

jq -n \
  --arg version "0.2.0" \
  --arg base "$BASE_URL" \
  --arg generated "$generated" \
  --argjson apps "$apps_json" \
  '{
    catalog_version: $version,
    generated_at: $generated,
    base_url: $base,
    store: {
      name: "Cloud Forge App Store",
      description: "One-command open-source app deployment powered by immutable images"
    },
    apps: $apps
  }' > "$INDEX"

echo "Generated $INDEX ($(jq '.apps | length' "$INDEX") apps)"
