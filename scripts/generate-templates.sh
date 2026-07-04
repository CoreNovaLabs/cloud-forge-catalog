#!/usr/bin/env bash
# Generate aws.yaml and aliyun.json from apps/_template using manifest params.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
exec python3 "$ROOT/scripts/generate_templates.py" --root "$ROOT" "$@"
