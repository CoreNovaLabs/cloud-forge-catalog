#!/usr/bin/env bash
# 从 apps/*/manifest.json 聚合生成 index/apps.json，并写入模板 sha256
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

  # 追加 checksum（需读文件）
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

jq -n \
  --arg version "1.0.0" \
  --arg base "$BASE_URL" \
  --arg generated "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" \
  --argjson apps "$apps_json" \
  '{
    catalog_version: $version,
    generated_at: $generated,
    base_url: $base,
    store: {
      name: "Cloud Forge App Store",
      description: "一键部署开源应用，基于不可变镜像"
    },
    apps: $apps
  }' > "$INDEX"

echo "Generated $INDEX ($(jq '.apps | length' "$INDEX") apps)"
