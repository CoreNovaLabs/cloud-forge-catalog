#!/usr/bin/env bash
# Generate a catalog app from apps.seed.yaml.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
exec python3 "$ROOT/scripts/generate_app.py" --root "$ROOT" "$@"
