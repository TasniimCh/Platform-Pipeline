#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)
PLATFORM_ROOT=$(cd "$SCRIPT_DIR/../.." >/dev/null 2>&1 && pwd)

source "$PLATFORM_ROOT/lib/constants.sh"
source "$PLATFORM_ROOT/lib/logging.sh"

: ${WORKSPACE:=${PWD}}
: ${REPORT_DIR:=".devsecops/reports"}
: ${LOG_LEVEL:=info}
: ${CONFIG_FILE:=".devsecops/pipeline.yaml"}

export LOG_LEVEL

RESULT_DIR="$WORKSPACE/$REPORT_DIR/gitleaks"
METADATA_FILE="$RESULT_DIR/metadata.json"
REPORT_FILE="$RESULT_DIR/report.json"
EXIT_CODE=$PLATFORM_EXIT_SUCCESS

mkdir -p "$RESULT_DIR"

log_info "Starting Gitleaks scan"
log_debug "Workspace=$WORKSPACE, ResultDir=$RESULT_DIR, ConfigFile=$CONFIG_FILE"

if ! command -v gitleaks >/dev/null 2>&1; then
  log_error "gitleaks is not installed or not available in PATH"
  echo '{"scanner":"gitleaks","status":"tool_missing","findings":0}' > "$METADATA_FILE"
  exit $PLATFORM_EXIT_TOOL_MISSING
fi

if [ ! -d "$WORKSPACE" ]; then
  log_error "Workspace directory '$WORKSPACE' does not exist"
  exit $PLATFORM_EXIT_CONFIG
fi

pushd "$WORKSPACE" >/dev/null

set +e

gitleaks detect \
  --report-format json \
  --report-path "$REPORT_FILE"

GITLEAKS_EXIT_CODE=$?

set -e

case "$GITLEAKS_EXIT_CODE" in
  0)
    EXIT_CODE=$PLATFORM_EXIT_SUCCESS
    log_info "Gitleaks completed with no findings"
    ;;

  1)
    EXIT_CODE=$PLATFORM_EXIT_FINDINGS
    log_warn "Gitleaks completed with findings"
    ;;

  *)
    EXIT_CODE=$PLATFORM_EXIT_EXECUTION
    log_error "Gitleaks execution failed with exit code $GITLEAKS_EXIT_CODE"
    ;;
esac

popd >/dev/null

findings=0
if [ -f "$REPORT_FILE" ]; then
  if command -v python3 >/dev/null 2>&1; then
    findings=$(python3 - <<'PYTHON'
import json
import sys
try:
    data = json.load(sys.stdin)
    print(len(data) if isinstance(data, list) else 1)
except Exception:
    print(0)
PYTHON
 < "$REPORT_FILE")
  else
    findings=$(grep -c '^{' "$REPORT_FILE" || true)
  fi
fi

SARIF_FILE="$RESULT_DIR/report.sarif"
if command -v python3 >/dev/null 2>&1 && [ -f "$REPORT_FILE" ]; then
  python3 - <<'PYTHON'
import json
from pathlib import Path
report_path = Path("$REPORT_FILE")
output_path = Path("$SARIF_FILE")
try:
    findings = json.loads(report_path.read_text())
    runs = []
    if isinstance(findings, list):
        rules = []
        results = []
        for index, item in enumerate(findings):
            rule_id = item.get('rule_id', f'gitleaks-{index}')
            results.append({
                'ruleId': rule_id,
                'level': 'warning',
                'message': {'text': item.get('description', rule_id)},
                'locations': [{
                    'physicalLocation': {
                        'artifactLocation': {'uri': item.get('file', '<unknown>')},
                        'region': {
                            'startLine': item.get('start_line', 1),
                            'startColumn': item.get('start_column', 1)
                        }
                    }
                }]
            })
            rules.append({'id': rule_id, 'name': rule_id})
        runs.append({
            'tool': {'driver': {'name': 'Gitleaks', 'rules': rules}},
            'results': results
        })
    else:
        runs.append({'tool': {'driver': {'name': 'Gitleaks'}}, 'results': []})
    sarif = {
        'version': '2.1.0',
        '$schema': 'https://schemastore.azurewebsites.net/schemas/json/sarif-2.1.0.json',
        'runs': runs
    }
    output_path.write_text(json.dumps(sarif, indent=2))
except Exception:
    pass
PYTHON
fi

cat > "$METADATA_FILE" <<EOF
{
  "scanner": "gitleaks",
  "status": "completed",
  "findings": $findings,
  "report": "$REPORT_FILE",
  "sarif": "$SARIF_FILE"
}
EOF

if [ "$EXIT_CODE" -eq "$PLATFORM_EXIT_SUCCESS" ]; then
  log_info "Gitleaks finished successfully"
else
  log_warn "Gitleaks exited with code $EXIT_CODE"
fi

exit $EXIT_CODE
