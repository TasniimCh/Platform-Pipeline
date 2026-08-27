#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(
  cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1
  pwd
)
PLATFORM_ROOT=$(
  cd "$SCRIPT_DIR/.." >/dev/null 2>&1
  pwd
)

source "$PLATFORM_ROOT/lib/constants.sh"
source "$PLATFORM_ROOT/lib/logging.sh"

: "${WORKSPACE:=$PWD}"
: "${CONFIG_FILE:=.devsecops/pipeline.yaml}"
: "${REPORT_DIR:=.devsecops/reports}"
: "${LOG_LEVEL:=info}"
: "${ENABLED_CODE_SCANNERS:=[]}"

export WORKSPACE
export CONFIG_FILE
export REPORT_DIR
export LOG_LEVEL

if [ "$#" -ne 1 ]; then
  log_error "Usage: run-scanner.sh <scanner>"
  exit "$PLATFORM_EXIT_CONFIG"
fi

SCANNER="$1"
SCANNER_SCRIPT="$PLATFORM_ROOT/scanners/$SCANNER/run.sh"

case "$SCANNER" in
  gitleaks | semgrep | snyk | checkov)
    ;;
  *)
    log_error "Unsupported code scanner: $SCANNER"
    exit "$PLATFORM_EXIT_CONFIG"
    ;;
esac

if [ ! -f "$SCANNER_SCRIPT" ]; then
  log_error "Scanner implementation not found: $SCANNER_SCRIPT"
  exit "$PLATFORM_EXIT_FAILURE"
fi

if [ ! -x "$SCANNER_SCRIPT" ]; then
  log_debug \
    "Scanner script is not executable; it will be invoked through Bash"
fi

if ! ENABLED_CODE_SCANNERS="$ENABLED_CODE_SCANNERS" \
  python3 - "$SCANNER" <<'PY'
import json
import os
import sys

scanner = sys.argv[1]
raw = os.environ.get("ENABLED_CODE_SCANNERS", "[]")

try:
    enabled_scanners = json.loads(raw)
except json.JSONDecodeError as exc:
    print(
        f"Invalid ENABLED_CODE_SCANNERS JSON: {exc}",
        file=sys.stderr,
    )
    sys.exit(2)

if not isinstance(enabled_scanners, list):
    print(
        "ENABLED_CODE_SCANNERS must be a JSON array.",
        file=sys.stderr,
    )
    sys.exit(2)

sys.exit(0 if scanner in enabled_scanners else 1)
PY
then
  log_info \
    "Scanner '$SCANNER' is not enabled by the resolved capabilities; skipping"
  exit "$PLATFORM_EXIT_SUCCESS"
fi

RESULT_DIRECTORY="$WORKSPACE/$REPORT_DIR/$SCANNER"
mkdir -p "$RESULT_DIRECTORY"

log_info "Running scanner '$SCANNER'"

# Disable errexit temporarily so the wrapper can inspect and normalize
# the scanner's documented exit code.
set +e
bash "$SCANNER_SCRIPT"
SCANNER_EXIT_CODE=$?
set -e

case "$SCANNER_EXIT_CODE" in
  "$PLATFORM_EXIT_SUCCESS")
    log_info "Scanner '$SCANNER' completed without findings"
    exit "$PLATFORM_EXIT_SUCCESS"
    ;;

  "$PLATFORM_EXIT_FINDINGS")
    log_warn \
      "Scanner '$SCANNER' detected findings; reports were retained for risk assessment"

    # Findings are security evidence, not scanner-execution failures.
    # The later risk/policy stage decides whether they block promotion.
    exit "$PLATFORM_EXIT_SUCCESS"
    ;;

  "$PLATFORM_EXIT_CONFIG")
    log_error "Scanner '$SCANNER' encountered a configuration error"
    exit "$PLATFORM_EXIT_CONFIG"
    ;;

  "$PLATFORM_EXIT_TOOL_MISSING")
    log_error "Required tool for scanner '$SCANNER' is unavailable"
    exit "$PLATFORM_EXIT_TOOL_MISSING"
    ;;

  "$PLATFORM_EXIT_EXECUTION")
    log_error "Scanner '$SCANNER' encountered an execution error"
    exit "$PLATFORM_EXIT_EXECUTION"
    ;;

  *)
    log_error \
      "Scanner '$SCANNER' failed with unexpected exit code " \
      "'$SCANNER_EXIT_CODE'"
    exit "$PLATFORM_EXIT_FAILURE"
    ;;
esac