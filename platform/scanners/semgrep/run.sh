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

RESULT_DIR="$WORKSPACE/$REPORT_DIR/semgrep"
REPORT_FILE="$RESULT_DIR/report.json"
SARIF_FILE="$RESULT_DIR/report.sarif"

mkdir -p "$RESULT_DIR"
log_info "Starting Semgrep scan"
log_debug "Workspace=$WORKSPACE, ResultDir=$RESULT_DIR, ConfigFile=$CONFIG_FILE"

if ! command -v semgrep >/dev/null 2>&1; then
  log_error "semgrep is not installed or not available in PATH"
  write_metadata "semgrep" "tool_missing" 0 "$REPORT_FILE" "$SARIF_FILE"
  exit $PLATFORM_EXIT_TOOL_MISSING
fi

if [ ! -d "$WORKSPACE" ]; then
  log_error "Workspace directory '$WORKSPACE' does not exist"
  exit $PLATFORM_EXIT_CONFIG
fi

pushd "$WORKSPACE" >/dev/null

set +e

semgrep \
  --config auto \
  --json \
  --output "$REPORT_FILE" \
  .

SEMGREP_EXIT_CODE=$?

set -e

case "$SEMGREP_EXIT_CODE" in
  0)
    EXIT_CODE=$PLATFORM_EXIT_SUCCESS
    log_info "Semgrep completed with no findings"
    ;;

  1)
    EXIT_CODE=$PLATFORM_EXIT_FINDINGS
    log_warn "Semgrep completed with findings"
    ;;

  *)
    EXIT_CODE=$PLATFORM_EXIT_EXECUTION
    log_error "Semgrep execution failed with exit code $SEMGREP_EXIT_CODE"
    ;;
esac

popd >/dev/null

findings=$(count_json_findings "$REPORT_FILE")
write_metadata "semgrep" "completed" "$findings" "$EXIT_CODE" "$REPORT_FILE" "$SARIF_FILE"

if [ "$EXIT_CODE" -eq "$PLATFORM_EXIT_SUCCESS" ]; then
  log_info "Semgrep finished successfully"
else
  log_warn "Semgrep exited with code $EXIT_CODE"
fi

exit $EXIT_CODE
