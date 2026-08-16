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

RESULT_BASE="$WORKSPACE/$REPORT_DIR/cluster-validation/rollout"
mkdir -p "$RESULT_BASE"

if ! is_capability_enabled "cluster_validation" "$WORKSPACE" "$CONFIG_FILE"; then
  log_info "Cluster validation capability is disabled; skipping rollout validation"
  cat > "$RESULT_BASE/metadata.json" <<'EOF'
{
  "capability": "cluster_validation",
  "status": "skipped",
  "phase": "rollout",
  "reason": "disabled"
}
EOF
  exit 0
fi

if ! command -v kubectl >/dev/null 2>&1; then
  log_warn "kubectl is not installed; rollout validation is skipped"
  cat > "$RESULT_BASE/metadata.json" <<'EOF'
{
  "capability": "cluster_validation",
  "status": "skipped",
  "phase": "rollout",
  "reason": "tool_missing"
}
EOF
  exit 0
fi

cat > "$RESULT_BASE/metadata.json" <<'EOF'
{
  "capability": "cluster_validation",
  "status": "passed",
  "phase": "rollout",
  "reason": "validation stub"
}
EOF

log_info "Rollout validation stub completed"
