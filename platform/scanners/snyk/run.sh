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

RESULT_DIR="$WORKSPACE/$REPORT_DIR/snyk"
REPORT_FILE="$RESULT_DIR/report.json"
SARIF_FILE="$RESULT_DIR/report.sarif"

mkdir -p "$RESULT_DIR"
log_info "Starting Snyk Open Source scan"
log_debug "Workspace=$WORKSPACE, ResultDir=$RESULT_DIR, ConfigFile=$CONFIG_FILE"

if ! command -v snyk >/dev/null 2>&1; then
  log_error "snyk is not installed or not available in PATH"
  write_metadata "snyk" "tool_missing" 0 "$REPORT_FILE" "$SARIF_FILE"
  exit $PLATFORM_EXIT_TOOL_MISSING
fi

if [ ! -d "$WORKSPACE" ]; then
  log_error "Workspace directory '$WORKSPACE' does not exist"
  exit $PLATFORM_EXIT_CONFIG
fi

pushd "$WORKSPACE" >/dev/null

set +e

snyk test --json \
  > "$REPORT_FILE" \
  2> "$RESULT_DIR/error.log"

SNYK_EXIT_CODE=$?

set -e

case "$SNYK_EXIT_CODE" in
  0)
    EXIT_CODE=$PLATFORM_EXIT_SUCCESS
    log_info "Snyk completed with no findings"
    ;;

  1)
    EXIT_CODE=$PLATFORM_EXIT_FINDINGS
    log_warn "Snyk completed with findings"
    ;;

  *)
  EXIT_CODE=$PLATFORM_EXIT_EXECUTION
  log_error "Snyk execution failed with exit code $SNYK_EXIT_CODE"

  if [ -f "$RESULT_DIR/error.log" ]; then
    cat "$RESULT_DIR/error.log" >&2
  fi
  ;;
esac

popd >/dev/null

findings=$(count_json_findings "$REPORT_FILE")
write_metadata "snyk" "completed" "$findings" "$EXIT_CODE" "$REPORT_FILE" "$SARIF_FILE"

if [ "$EXIT_CODE" -eq "$PLATFORM_EXIT_SUCCESS" ]; then
  log_info "Snyk finished successfully"
else
  log_warn "Snyk exited with code $EXIT_CODE"
fi

exit $EXIT_CODE
