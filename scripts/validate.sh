#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"

if ! command -v jq >/dev/null 2>&1; then
  echo "error: jq is required" >&2
  exit 1
fi

echo "==> Validating manifests..."
python3 "$ROOT/scripts/validate_catalog.py" --root "$ROOT"

echo "==> Validating template file presence..."
for manifest in "$ROOT"/apps/*/manifest.json; do
  [ -f "$manifest" ] || continue
  app_id="$(jq -r '.id' "$manifest")"
  dir_id="$(basename "$(dirname "$manifest")")"
  if [ "$dir_id" = "_template" ]; then
    continue
  fi
  if [ "$app_id" != "$dir_id" ]; then
    echo "FAIL: $manifest id=$app_id != dir=$dir_id" >&2
    exit 1
  fi

  for cloud in aws aliyun; do
    path="$(jq -r ".templates.${cloud}.path // empty" "$manifest")"
    if [ -n "$path" ]; then
      if [ ! -f "$ROOT/$path" ]; then
        echo "FAIL: missing template $path for $app_id ($cloud)" >&2
        exit 1
      fi
    fi
  done
  echo "  OK $app_id"
done

echo "==> Validating index/apps.json..."
if [ ! -f "$ROOT/index/apps.json" ]; then
  echo "WARN: index/apps.json not found, run make index first" >&2
  exit 1
fi

jq -e '.catalog_version and .apps and (.apps | length > 0)' "$ROOT/index/apps.json" >/dev/null
echo "  OK index ($(jq '.apps | length' "$ROOT/index/apps.json") apps)"

echo "All validations passed."
