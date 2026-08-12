#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)
PLATFORM_ROOT=$(cd "$SCRIPT_DIR/.." >/dev/null 2>&1 && pwd)

source "$PLATFORM_ROOT/lib/constants.sh"
source "$PLATFORM_ROOT/lib/logging.sh"
source "$PLATFORM_ROOT/config/config.sh"

: ${WORKSPACE:=${PWD}}
: ${CONFIG_FILE:=".devsecops/pipeline.yaml"}
: ${REPORT_DIR:=".devsecops/reports"}
: ${LOG_LEVEL:=info}

export WORKSPACE
export CONFIG_FILE
export REPORT_DIR
export LOG_LEVEL

if [ "$#" -lt 1 ]; then
  log_error "Missing scanner name argument"
  exit $PLATFORM_EXIT_FAILURE
fi

SCANNER="$1"
SCANNER_SCRIPT="$PLATFORM_ROOT/scanners/$SCANNER/run.sh"

if [ ! -f "$SCANNER_SCRIPT" ]; then
  log_error "Scanner implementation not found: $SCANNER"
  exit $PLATFORM_EXIT_FAILURE
fi

if ! is_scanner_enabled "$SCANNER" "$WORKSPACE" "$CONFIG_FILE"; then
  log_info "Scanner '$SCANNER' is disabled by platform capabilities; skipping"
  exit $PLATFORM_EXIT_SUCCESS
fi

log_info "Running scanner engine for '$SCANNER'"
mkdir -p "$WORKSPACE/$REPORT_DIR"

bash "$SCANNER_SCRIPT"
EXIT_CODE=$?

if [ "$EXIT_CODE" -eq "$PLATFORM_EXIT_SUCCESS" ]; then
  log_info "Scanner '$SCANNER' completed successfully"
else
  log_warn "Scanner '$SCANNER' exited with code $EXIT_CODE"
fi

exit "$EXIT_CODE"
