#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
export SAM_CLI_TELEMETRY="${SAM_CLI_TELEMETRY:-0}"

if ! command -v sam >/dev/null 2>&1; then
  cat >&2 <<'EOF'
error: AWS SAM CLI is required for AWS template validation.

Install it locally, then retry:
  brew tap aws/tap
  brew install aws-sam-cli

This validation only runs local template linting. It does not create a
CloudFormation stack, launch EC2, allocate EIP, or incur EC2 runtime charges.
EOF
  exit 1
fi

if ! command -v cfn-lint >/dev/null 2>&1; then
  cat >&2 <<'EOF'
error: cfn-lint is required by `sam validate --lint`.

Install it locally, then retry:
  python3 -m pip install cfn-lint

EOF
  exit 1
fi

echo "==> Validating AWS templates with SAM CLI..."
found=false
for template in "$ROOT"/apps/*/templates/aws.yaml "$ROOT"/apps/*/templates/aws.yml; do
  [ -f "$template" ] || continue
  found=true
  rel="${template#"$ROOT"/}"
  echo "  SAM $rel"
  sam validate --lint --template-file "$template"
done

if [ "$found" = false ]; then
  echo "error: no AWS templates found under apps/*/templates/aws.yaml" >&2
  exit 1
fi

echo "AWS SAM validation passed."
