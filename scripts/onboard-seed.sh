#!/usr/bin/env bash
# Generate catalog apps from apps.seed.yaml and optionally run local smoke tests.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SEED="${ROOT}/apps.seed.yaml"
SMOKE=0
FORCE=0
APP_FILTER=""

usage() {
  echo "usage: $0 [--smoke] [--force] [app-id ...]" >&2
  echo "  --smoke   run local-smoke.sh after each generated app" >&2
  echo "  --force   overwrite existing app directories" >&2
  exit 2
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --smoke) SMOKE=1; shift ;;
    --force) FORCE=1; shift ;;
    -h|--help) usage ;;
    *)
      APP_FILTER="$1"
      shift
      ;;
  esac
done

if ! python3 -c "import yaml" 2>/dev/null; then
  if [[ -x "$ROOT/.venv/bin/python" ]]; then
    PYTHON="$ROOT/.venv/bin/python"
  else
    echo "error: PyYAML required. Run: python3 -m venv .venv && .venv/bin/pip install pyyaml" >&2
    exit 1
  fi
else
  PYTHON="python3"
fi

app_ids=()
if [[ -n "$APP_FILTER" ]]; then
  app_ids=("$APP_FILTER")
else
  while IFS= read -r line; do
    app_ids+=("$line")
  done < <("$PYTHON" - <<'PY' "$SEED"
import sys, yaml
data = yaml.safe_load(open(sys.argv[1], encoding="utf-8"))
for app in data.get("apps") or []:
    print(app["id"])
PY
)
fi

failed=0
for app_id in "${app_ids[@]}"; do
  echo "======== onboard $app_id ========"
  args=(--seed "$SEED" "$app_id")
  if [[ "$FORCE" -eq 1 ]]; then
    args+=(--force)
  fi
  if [[ -d "$ROOT/apps/$app_id" && "$FORCE" -ne 1 ]]; then
    echo "SKIP generate $app_id (already exists, use --force)"
  else
    "$PYTHON" "$ROOT/scripts/generate_app.py" "${args[@]}"
  fi

  if [[ "$SMOKE" -eq 1 ]]; then
    if ! "$ROOT/scripts/local-smoke.sh" "$app_id"; then
      echo "FAIL smoke $app_id" >&2
      failed=1
    fi
  fi
done

echo "======== make generate-all ========"
make -C "$ROOT" generate-all

exit "$failed"
