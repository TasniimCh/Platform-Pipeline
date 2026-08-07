#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)
PLATFORM_ROOT=$(cd "$SCRIPT_DIR/.." >/dev/null 2>&1 && pwd)

source "$PLATFORM_ROOT/lib/constants.sh"
source "$PLATFORM_ROOT/lib/logging.sh"

DEFAULT_CONFIG="$PLATFORM_ROOT/config/default.yaml"
CAPABILITY_MAP="$PLATFORM_ROOT/config/capabilities.yaml"

load_merged_config_json() {
  local workspace="${1:-$WORKSPACE}"
  local config_file="${2:-$CONFIG_FILE}"
  local custom_config

  if [ -z "$config_file" ]; then
    custom_config="$workspace/.devsecops/pipeline.yaml"
  elif [ "${config_file#/}" != "$config_file" ]; then
    custom_config="$config_file"
  else
    custom_config="$workspace/$config_file"
  fi

  python3 - "$DEFAULT_CONFIG" "$custom_config" "$CAPABILITY_MAP" <<'PY'
import json
import os
import re
import sys
import yaml

DEFAULT_PATH = sys.argv[1]
CUSTOM_PATH = sys.argv[2]
CAPABILITY_MAP_PATH = sys.argv[3]


def parse_value(raw):
    if isinstance(raw, str):
        text = raw.strip()
        if text.lower() in ('true', 'yes', '1'):
            return True
        if text.lower() in ('false', 'no', '0'):
            return False
        if text == '[]':
            return []
        return text
    return raw



def load_yaml(path):
    if not os.path.isfile(path):
        return {}

    with open(path, "r", encoding="utf-8") as f:
        return yaml.safe_load(f) or {}


def reverse_map(capability_map):
    scanner_to_cap = {}
    for capability, scanner in capability_map.get('capabilities', {}).items():
        scanner_to_cap[str(scanner)] = capability
    return scanner_to_cap


def main():
    default = load_yaml(DEFAULT_PATH)
    custom = load_yaml(CUSTOM_PATH)
    capability_map = load_yaml(CAPABILITY_MAP_PATH)
    scanner_to_cap = reverse_map(capability_map)

    capabilities = dict(default.get('capabilities', {}))

    if 'scanners' in custom:
        for scanner, scanner_config in custom['scanners'].items():
            if not isinstance(scanner_config, dict):
                continue
            enabled = scanner_config.get('enabled')
            if enabled is None:
                continue
            capability = scanner_to_cap.get(scanner)
            if capability:
                capabilities[capability] = enabled

    if 'capabilities' in custom:
        for capability, value in custom['capabilities'].items():
            capabilities[capability] = value

    for capability in default.get('capabilities', {}).keys():
        capabilities.setdefault(capability, False)

    print(json.dumps({'capabilities': capabilities}))


if __name__ == "__main__":
    try:
        main()
    except Exception:
        import traceback
        traceback.print_exc()
        raise
PY
}

is_capability_enabled() {
  local capability="$1"
  local workspace="${2:-$WORKSPACE}"
  local config_file="${3:-$CONFIG_FILE}"

  load_merged_config_json "$workspace" "$config_file" | python3 - "$capability" <<'PY'
import json
import sys

raw = sys.stdin.read()

if not raw.strip():
    raise RuntimeError("load_merged_config_json produced no JSON output")

config = json.loads(raw)

capability = sys.argv[1]
value = config.get('capabilities', {}).get(capability, False)
if value:
    sys.exit(0)
sys.exit(1)
PY
}

enabled_scanner_tools() {
  local workspace="${1:-$WORKSPACE}"
  local config_file="${2:-$CONFIG_FILE}"

  load_merged_config_json "$workspace" "$config_file" | python3 - "$CAPABILITY_MAP" <<'PY'
import json
import os
import re
import sys

raw = sys.stdin.read()

if not raw.strip():
    raise RuntimeError("load_merged_config_json produced no JSON output")

config = json.loads(raw)
capability_map_path = sys.argv[1]
capability_map = {}
with open(capability_map_path, 'r', encoding='utf-8') as f:
    section = None
    for line in f:
        line = line.split('#', 1)[0].rstrip()
        if not line:
            continue
        m = re.match(r'^(\s*)([^:]+):\s*(.*)$', line)
        if not m:
            continue
        indent = len(m.group(1))
        key = m.group(2).strip()
        value = m.group(3).strip()
        if indent == 0:
            section = key
            continue
        elif indent == 2 and section == 'capabilities':
            capability_map[key] = value

enabled = []
for capability, tool in capability_map.items():
    if config.get('capabilities', {}).get(capability, False):
        enabled.append(tool)
print(' '.join(enabled))
PY
}

is_scanner_enabled() {
  local scanner="$1"
  local workspace="${2:-$WORKSPACE}"
  local config_file="${3:-$CONFIG_FILE}"

  local scanners
  scanners=$(enabled_scanner_tools "$workspace" "$config_file")

  for item in $scanners; do
    if [ "$item" = "$scanner" ]; then
      return 0
    fi
  done
  return 1
}
