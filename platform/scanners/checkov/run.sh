#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)
PLATFORM_ROOT=$(cd "$SCRIPT_DIR/../.." >/dev/null 2>&1 && pwd)

source "$PLATFORM_ROOT/lib/constants.sh"
source "$PLATFORM_ROOT/lib/logging.sh"
source "$PLATFORM_ROOT/scanners/common.sh"

: ${WORKSPACE:=${PWD}}
: ${CONFIG_FILE:=".devsecops/pipeline.yaml"}
: ${REPORT_DIR:=".devsecops/reports"}
: ${LOG_LEVEL:=info}

RESULT_DIR="$WORKSPACE/$REPORT_DIR/checkov"
REPORT_FILE="$RESULT_DIR/report.json"
SARIF_FILE="$RESULT_DIR/report.sarif"

mkdir -p "$RESULT_DIR"
log_info "Starting Checkov scan"
log_debug "Workspace=$WORKSPACE, ResultDir=$RESULT_DIR, ConfigFile=$CONFIG_FILE"

if ! command -v checkov >/dev/null 2>&1; then
  log_error "checkov is not installed or not available in PATH"
  write_metadata "checkov" "tool_missing" 0 "$REPORT_FILE" "$SARIF_FILE"
  exit $PLATFORM_EXIT_TOOL_MISSING
fi

if [ ! -d "$WORKSPACE" ]; then
  log_error "Workspace directory '$WORKSPACE' does not exist"
  exit $PLATFORM_EXIT_CONFIG
fi

pushd "$WORKSPACE" >/dev/null

if ! checkov -o json --output-file-path "$REPORT_FILE" .; then
  EXIT_CODE=$PLATFORM_EXIT_FINDINGS
  log_warn "Checkov completed with findings"
else
  EXIT_CODE=$PLATFORM_EXIT_SUCCESS
  log_info "Checkov completed with no findings"
fi

popd >/dev/null

findings=$(count_json_findings "$REPORT_FILE")
write_metadata "checkov" "completed" "$findings" "$REPORT_FILE" "$SARIF_FILE"

if [ "$EXIT_CODE" -eq "$PLATFORM_EXIT_SUCCESS" ]; then
  log_info "Checkov finished successfully"
else
  log_warn "Checkov exited with code $EXIT_CODE"
fi

exit $EXIT_CODE
