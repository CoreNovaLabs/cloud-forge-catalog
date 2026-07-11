#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
BUCKET="${AWS_TEMPLATE_BUCKET:?AWS_TEMPLATE_BUCKET is required}"
REGION="${AWS_TEMPLATE_REGION:-us-east-1}"
CATALOG_VERSION="${CATALOG_VERSION:-$(jq -r '.catalog_version' "$ROOT/index/apps.json")}"

if [[ -z "$CATALOG_VERSION" || "$CATALOG_VERSION" == "null" ]]; then
  echo "catalog version is missing" >&2
  exit 1
fi

published=0
skipped=0
while IFS= read -r template; do
  relative="${template#"$ROOT/"}"
  key="releases/${CATALOG_VERSION}/${relative}"
  checksum="$(shasum -a 256 "$template" | awk '{print $1}')"
  if head_output="$(aws s3api head-object --bucket "$BUCKET" --key "$key" --region "$REGION" --output json 2>&1)"; then
    remote_checksum="$(jq -r '.Metadata.sha256 // empty' <<<"$head_output")"
    if [[ -z "$remote_checksum" ]]; then
      echo "refusing to replace existing object without sha256 metadata: s3://${BUCKET}/${key}" >&2
      exit 1
    fi
    if [[ "$remote_checksum" != "$checksum" ]]; then
      echo "refusing to overwrite immutable object s3://${BUCKET}/${key}" >&2
      exit 1
    fi
    skipped=$((skipped + 1))
    continue
  elif ! grep -Eq '\(404\)|Not Found|NoSuchKey' <<<"$head_output"; then
    echo "failed to inspect s3://${BUCKET}/${key}: ${head_output}" >&2
    exit 1
  fi
  aws s3api put-object \
    --bucket "$BUCKET" \
    --key "$key" \
    --body "$template" \
    --content-type application/yaml \
    --cache-control 'public, max-age=31536000, immutable' \
    --if-none-match '*' \
    --metadata "sha256=${checksum}" \
    --region "$REGION" >/dev/null
  published=$((published + 1))
done < <(find "$ROOT/apps" -path '*/templates/aws.yaml' -type f | sort)

echo "Published ${published} templates; skipped ${skipped} identical immutable objects for catalog ${CATALOG_VERSION}"
