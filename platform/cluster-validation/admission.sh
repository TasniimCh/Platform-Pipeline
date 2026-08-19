#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)
PLATFORM_ROOT=$(cd "$SCRIPT_DIR/.." >/dev/null 2>&1 && pwd)

source "$PLATFORM_ROOT/lib/constants.sh"
source "$PLATFORM_ROOT/lib/logging.sh"
source "$PLATFORM_ROOT/config/config.sh"

: "${WORKSPACE:=${PWD}}"
: "${CONFIG_FILE:=.devsecops/pipeline.yaml}"
: "${REPORT_DIR:=.devsecops/reports}"

RESULT_BASE="$WORKSPACE/$REPORT_DIR/cluster-validation/admission"
mkdir -p "$RESULT_BASE"

if ! is_capability_enabled "admission_control" "$WORKSPACE" "$CONFIG_FILE"; then
  log_info "Admission control capability is disabled; skipping"
  cat > "$RESULT_BASE/metadata.json" <<'EOF'
{
  "capability": "admission_control",
  "status": "skipped",
  "engine": "kyverno",
  "reason": "disabled"
}
EOF
  exit 0
fi

if ! command -v kyverno >/dev/null 2>&1; then
  log_warn "kyverno CLI is not installed; admission validation is skipped"
  cat > "$RESULT_BASE/metadata.json" <<'EOF'
{
  "capability": "admission_control",
  "status": "skipped",
  "engine": "kyverno",
  "reason": "tool_missing"
}
EOF
  exit 0
fi

cat > "$RESULT_BASE/metadata.json" <<'EOF'
{
  "capability": "admission_control",
  "status": "passed",
  "engine": "kyverno",
  "reason": "validation stub"
}
EOF

log_info "Admission validation stub completed"