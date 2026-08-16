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

export WORKSPACE
export CONFIG_FILE
export REPORT_DIR

RESULT_BASE="$WORKSPACE/$REPORT_DIR/cluster-validation"
mkdir -p "$RESULT_BASE"

log_info "Starting Cluster & Runtime Validation provider"
log_info "Workspace: $WORKSPACE"
log_info "Configuration: $WORKSPACE/$CONFIG_FILE"
log_info "Reports: $RESULT_BASE"

if ! is_capability_enabled "cluster_validation" "$WORKSPACE" "$CONFIG_FILE"; then
  log_info "Cluster validation capability is disabled; skipping"
  cat > "$RESULT_BASE/metadata.json" <<'EOF'
{
  "capability": "cluster_validation",
  "status": "skipped",
  "reason": "disabled"
}
EOF
  exit 0
fi

if ! is_capability_enabled "admission_control" "$WORKSPACE" "$CONFIG_FILE"; then
  log_info "Admission control not enabled; cluster validation still runs with deployment smoke checks only"
fi

"$SCRIPT_DIR/admission.sh"
"$SCRIPT_DIR/rollout.sh"
"$SCRIPT_DIR/smoke-tests.sh"

cat > "$RESULT_BASE/summary.json" <<'EOF'
{
  "capability": "cluster_validation",
  "status": "passed",
  "environment": "dev",
  "phases": [
    "admission",
    "rollout",
    "smoke_tests"
  ]
}
EOF

log_info "Cluster & Runtime Validation provider completed successfully"
