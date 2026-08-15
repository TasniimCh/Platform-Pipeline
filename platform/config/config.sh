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
import sys
import yaml

DEFAULT_PATH = sys.argv[1]
CUSTOM_PATH = sys.argv[2]
CAPABILITY_MAP_PATH = sys.argv[3]


def load_yaml(path):
    if not os.path.isfile(path):
        return {}

    with open(path, "r", encoding="utf-8") as f:
        return yaml.safe_load(f) or {}


def merge_dict(a, b):
    result = dict(a)

    for key, value in b.items():
        if isinstance(value, dict) and isinstance(result.get(key), dict):
            result[key] = merge_dict(result[key], value)
        else:
            result[key] = value

    return result


def reverse_map(capability_map):
    scanner_to_cap = {}

    for capability, scanner in capability_map.get("capabilities", {}).items():
        scanner_to_cap[str(scanner)] = capability

    return scanner_to_cap


def main():
    default = load_yaml(DEFAULT_PATH)
    custom = load_yaml(CUSTOM_PATH)
    capability_map = load_yaml(CAPABILITY_MAP_PATH)

    merged = merge_dict(default, custom)

    merged_capabilities = dict(default.get("capabilities", {}))
    merged_capabilities.update(
        merged.get("capabilities", {})
    )

    # Preserve existing scanner -> capability compatibility.
    if "scanners" in custom:
        scanner_to_cap = reverse_map(capability_map)

        for scanner, scanner_config in custom["scanners"].items():
            if not isinstance(scanner_config, dict):
                continue

            enabled = scanner_config.get("enabled")

            if enabled is None:
                continue

            capability = scanner_to_cap.get(scanner)

            if capability:
                merged_capabilities[capability] = enabled

    # Ensure every platform capability has a boolean default.
    for capability in default.get("capabilities", {}).keys():
        merged_capabilities.setdefault(capability, False)

    merged["capabilities"] = merged_capabilities

    print(json.dumps(merged))


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
  local config_json

  config_json=$(load_merged_config_json "$workspace" "$config_file")

  CONFIG_JSON="$config_json" python3 - "$capability" <<'PY'
import json
import os
import sys

raw = os.environ.get("CONFIG_JSON", "")

if not raw.strip():
    raise RuntimeError(
        "load_merged_config_json produced no JSON output"
    )

config = json.loads(raw)

capability = sys.argv[1]
value = config.get("capabilities", {}).get(
    capability,
    False
)

if value:
    sys.exit(0)

sys.exit(1)
PY
}


enabled_scanner_tools() {
  local workspace="${1:-$WORKSPACE}"
  local config_file="${2:-$CONFIG_FILE}"
  local config_json

  config_json=$(load_merged_config_json "$workspace" "$config_file")

  CONFIG_JSON="$config_json" python3 - "$CAPABILITY_MAP" <<'PY'
import json
import os
import re
import sys

raw = os.environ.get("CONFIG_JSON", "")

if not raw.strip():
    raise RuntimeError(
        "load_merged_config_json produced no JSON output"
    )

config = json.loads(raw)

capability_map_path = sys.argv[1]
capability_map = {}

with open(capability_map_path, "r", encoding="utf-8") as f:
    section = None

    for line in f:
        line = line.split("#", 1)[0].rstrip()

        if not line:
            continue

        match = re.match(
            r"^(\s*)([^:]+):\s*(.*)$",
            line
        )

        if not match:
            continue

        indent = len(match.group(1))
        key = match.group(2).strip()
        value = match.group(3).strip()

        if indent == 0:
            section = key
            continue

        if indent == 2 and section == "capabilities":
            capability_map[key] = value


enabled = []

for capability, tool in capability_map.items():
    if config.get("capabilities", {}).get(
        capability,
        False
    ):
        enabled.append(tool)

print(" ".join(enabled))
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