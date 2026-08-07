#!/usr/bin/env bash
set -euo pipefail

is_scanner_enabled() {
  local scanner="$1"
  local config_path="$WORKSPACE/$CONFIG_FILE"

  if [ ! -f "$config_path" ]; then
    return 1
  fi

  if ! command -v python3 >/dev/null 2>&1; then
    return 1
  fi

  python3 - "$config_path" "$scanner" <<'PY'
import re
import sys

config_path = sys.argv[1]
scanner = sys.argv[2]

in_scanners = False
current_scanner = None

with open(config_path, 'r', encoding='utf-8') as f:
    for line in f:
        if re.match(r'^\s*scanners\s*:\s*$', line):
            in_scanners = True
            continue
        if not in_scanners:
            continue
        section = re.match(r'^\s{2}([A-Za-z0-9_-]+)\s*:\s*$', line)
        if section:
            current_scanner = section.group(1)
            continue
        if current_scanner == scanner:
            enabled = re.match(r'^\s{4}enabled\s*:\s*(.+)$', line)
            if enabled:
                value = enabled.group(1).strip().lower()
                print(value in ('true', 'yes', '1'))
                sys.exit(0)
            if re.match(r'^\s{2}[A-Za-z0-9_-]+\s*:\s*$', line):
                break
print('False')
PY
}

count_json_findings() {
  local report_file="$1"

  if [ ! -f "$report_file" ]; then
    echo 0
    return
  fi

  if ! command -v python3 >/dev/null 2>&1; then
    grep -c '"id"' "$report_file" || true
    return
  fi

  python3 - "$report_file" <<'PY'
import json
import sys

path = sys.argv[1]
try:
    data = json.loads(open(path, 'r', encoding='utf-8').read())
except Exception:
    print(0)
    sys.exit(0)

if isinstance(data, list):
    print(len(data))
    sys.exit(0)

if isinstance(data, dict):
    if 'results' in data and isinstance(data['results'], list):
        print(len(data['results']))
        sys.exit(0)
    if 'vulnerabilities' in data and isinstance(data['vulnerabilities'], list):
        print(len(data['vulnerabilities']))
        sys.exit(0)
    if 'failed_checks' in data and isinstance(data['failed_checks'], list):
        print(len(data['failed_checks']))
        sys.exit(0)
    if 'issues' in data and isinstance(data['issues'], list):
        print(len(data['issues']))
        sys.exit(0)
    if 'results' in data and isinstance(data['results'], dict):
        failed = data['results'].get('failed_checks')
        if isinstance(failed, list):
            print(len(failed))
            sys.exit(0)
print(0)
PY
}

write_metadata() {
  local scanner="$1"
  local status="$2"
  local findings="$3"
  local report_path="$4"
  local sarif_path="${5:-}"

  cat > "$RESULT_DIR/metadata.json" <<EOF
{
  "scanner": "$scanner",
  "status": "$status",
  "findings": $findings,
  "report": "$report_path",
  "sarif": "$sarif_path"
}
EOF
}