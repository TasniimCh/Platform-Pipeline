#!/usr/bin/env bash
set -euo pipefail

CONFIG_PATH="${1:-}"

if [ -z "$CONFIG_PATH" ]; then
  printf 'Configuration validation failed: missing config file path\n' >&2
  exit 2
fi

if [ ! -f "$CONFIG_PATH" ]; then
  if [ "$CONFIG_PATH" = "$PWD/.devsecops/pipeline.yaml" ] || \
     [ "$CONFIG_PATH" = ".devsecops/pipeline.yaml" ]; then
    exit 0
  fi

  printf 'Configuration validation failed: file not found: %s\n' "$CONFIG_PATH" >&2
  exit 2
fi


# ---------------------------------------------------------------------------
# Top-level sections
# ---------------------------------------------------------------------------

if ! grep -E '^[[:space:]]*scanners:|^[[:space:]]*capabilities:' "$CONFIG_PATH" >/dev/null 2>&1; then
  printf 'Configuration validation failed: missing top-level "scanners" or "capabilities" section\n' >&2
  exit 2
fi


# ---------------------------------------------------------------------------
# Capabilities
# ---------------------------------------------------------------------------

if grep -E '^[[:space:]]*capabilities:' "$CONFIG_PATH" >/dev/null 2>&1; then

  if ! grep -E \
    '^[[:space:]]{2}(secret_detection|static_analysis|dependency_analysis|infrastructure_analysis|build|unit_testing|integration_testing|container_build|container_scan|sbom|provenance|policy_enforcement):' \
    "$CONFIG_PATH" >/dev/null 2>&1; then

    printf 'Configuration validation failed: "capabilities" section must contain at least one supported capability\n' >&2
    exit 2
  fi

fi


# ---------------------------------------------------------------------------
# Policy configuration
# ---------------------------------------------------------------------------

if grep -E '^[[:space:]]*policy:' "$CONFIG_PATH" >/dev/null 2>&1; then

  if ! grep -E \
    '^[[:space:]]{2}(paths|policy_paths):' \
    "$CONFIG_PATH" >/dev/null 2>&1; then

    printf 'Configuration validation failed: "policy" section must contain "paths" or "policy_paths"\n' >&2
    exit 2
  fi

fi


# ---------------------------------------------------------------------------
# Policy path security
# ---------------------------------------------------------------------------

validate_policy_paths() {
  local section="$1"

  python3 - "$CONFIG_PATH" "$section" <<'PY'
import sys
import yaml

config_path = sys.argv[1]
section = sys.argv[2]

with open(config_path, "r", encoding="utf-8") as f:
    config = yaml.safe_load(f) or {}

policy = config.get("policy", {})

if not isinstance(policy, dict):
    raise SystemExit(
        'Configuration validation failed: "policy" must be a mapping'
    )

paths = policy.get(section, [])

if paths is None:
    paths = []

if not isinstance(paths, list):
    raise SystemExit(
        f'Configuration validation failed: "policy.{section}" must be a list'
    )

for path in paths:
    if not isinstance(path, str) or not path.strip():
        raise SystemExit(
            f'Configuration validation failed: "policy.{section}" contains an invalid path'
        )

    path = path.strip()

    # Reject absolute paths.
    if path.startswith("/"):
        raise SystemExit(
            f'Configuration validation failed: absolute path is not allowed: {path}'
        )

    # Reject Windows absolute paths / drive paths.
    if len(path) >= 2 and path[1] == ":":
        raise SystemExit(
            f'Configuration validation failed: absolute path is not allowed: {path}'
        )

    # Reject path traversal.
    parts = path.replace("\\", "/").split("/")

    if ".." in parts:
        raise SystemExit(
            f'Configuration validation failed: path traversal is not allowed: {path}'
        )
PY
}


validate_policy_paths "paths"
validate_policy_paths "policy_paths"


exit 0