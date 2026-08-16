#!/usr/bin/env bash
set -euo pipefail

# Entrypoint for risk assessment. Mirrors other platform providers' contract.
# Expects environment variables: WORKSPACE, CONFIG_FILE, REPORT_DIR, LOG_LEVEL

: ${REPORT_DIR:=.devsecops/reports}
PYTHON=${PYTHON:-python3}

mkdir -p "$REPORT_DIR/risk"

export REPORT_DIR

exec "$PYTHON" "$(dirname "$0")/lib/run.py" "$@"
