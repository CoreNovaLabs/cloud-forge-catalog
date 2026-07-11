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
  remote_checksum="$(aws s3api head-object --bucket "$BUCKET" --key "$key" --region "$REGION" --query 'Metadata.sha256' --output text 2>/dev/null || true)"
  if [[ -n "$remote_checksum" && "$remote_checksum" != "None" ]]; then
    if [[ "$remote_checksum" != "$checksum" ]]; then
      echo "refusing to overwrite immutable object s3://${BUCKET}/${key}" >&2
      exit 1
    fi
    skipped=$((skipped + 1))
    continue
  fi
  aws s3api put-object \
    --bucket "$BUCKET" \
    --key "$key" \
    --body "$template" \
    --content-type application/yaml \
    --metadata "sha256=${checksum}" \
    --region "$REGION" >/dev/null
  published=$((published + 1))
done < <(find "$ROOT/apps" -path '*/templates/aws.yaml' -type f | sort)

echo "Published ${published} templates; skipped ${skipped} identical immutable objects for catalog ${CATALOG_VERSION}"
