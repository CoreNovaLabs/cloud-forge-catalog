#!/usr/bin/env bash
# List catalog app ids for cloud verification based on tier filters.
#
# Environment:
#   CLOUD_FORGE_VERIFY_TIERS     comma-separated tiers (default: certified)
#   CLOUD_FORGE_VERIFY_SAMPLE    0.0-1.0 random sample rate for community tier
#
# Examples:
#   ./scripts/list-verify-apps.sh
#   CLOUD_FORGE_VERIFY_TIERS=certified,community CLOUD_FORGE_VERIFY_SAMPLE=0.1 ./scripts/list-verify-apps.sh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TIERS="${CLOUD_FORGE_VERIFY_TIERS:-certified}"
SAMPLE="${CLOUD_FORGE_VERIFY_SAMPLE:-0}"

if ! command -v jq >/dev/null 2>&1; then
  echo "error: jq is required" >&2
  exit 1
fi

python3 - <<'PY' "$ROOT" "$TIERS" "$SAMPLE"
import json
import random
import sys
from pathlib import Path

root = Path(sys.argv[1])
tiers = {part.strip() for part in sys.argv[2].split(",") if part.strip()}
sample = float(sys.argv[3]) if sys.argv[3] else 0.0

selected = []
community_pool = []

for manifest in sorted(root.glob("apps/*/manifest.json")):
    if manifest.parent.name == "_template":
        continue
    data = json.loads(manifest.read_text(encoding="utf-8"))
    tier = data.get("tier", "community")
    app_id = data.get("id") or manifest.parent.name
    if tier in tiers:
        if tier == "community" and 0 < sample < 1.0:
            community_pool.append(app_id)
        else:
            selected.append(app_id)

if "community" in tiers and sample > 0 and community_pool:
    random.shuffle(community_pool)
    count = max(1, int(len(community_pool) * sample + 0.999999)) if sample < 1 else len(community_pool)
    selected.extend(sorted(community_pool[:count]))

for app_id in sorted(set(selected)):
    print(app_id)
PY
