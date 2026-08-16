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

RESULT_BASE="$WORKSPACE/$REPORT_DIR/cluster-validation/smoke-tests"
mkdir -p "$RESULT_BASE"

if ! is_capability_enabled "cluster_validation" "$WORKSPACE" "$CONFIG_FILE"; then
  log_info "Cluster validation capability is disabled; skipping smoke tests"
  cat > "$RESULT_BASE/metadata.json" <<'EOF'
{
  "capability": "cluster_validation",
  "status": "skipped",
  "phase": "smoke_tests",
  "reason": "disabled"
}
EOF
  exit 0
fi

config_json=$(load_merged_config_json "$WORKSPACE" "$CONFIG_FILE") || {
  log_error "Failed to load merged platform configuration"
  exit "$PLATFORM_EXIT_CONFIG"
}

command_to_run=$(CONFIG_JSON="$config_json" python3 - <<'PY'
import json
import os

cfg = json.loads(os.environ.get('CONFIG_JSON', '{}'))
smoke = cfg.get('cluster_validation', {}).get('smoke_tests', {})
print(smoke.get('command') or '')
PY
)

if [ -z "$command_to_run" ]; then
  log_info "No smoke test command configured; skipping"
  cat > "$RESULT_BASE/metadata.json" <<'EOF'
{
  "capability": "cluster_validation",
  "status": "skipped",
  "phase": "smoke_tests",
  "reason": "no_command"
}
EOF
  exit 0
fi

if ! bash -lc "$command_to_run" >/dev/null 2>&1; then
  log_error "Smoke test command failed: $command_to_run"
  cat > "$RESULT_BASE/metadata.json" <<EOF
{
  "capability": "cluster_validation",
  "status": "failed",
  "phase": "smoke_tests",
  "command": "$command_to_run"
}
EOF
  exit "$PLATFORM_EXIT_FAILURE"
fi

cat > "$RESULT_BASE/metadata.json" <<EOF
{
  "capability": "cluster_validation",
  "status": "passed",
  "phase": "smoke_tests",
  "command": "$command_to_run"
}
EOF

log_info "Smoke tests passed"
