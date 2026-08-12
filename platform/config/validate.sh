#!/usr/bin/env bash
set -euo pipefail

CONFIG_PATH="${1:-}" 

if [ -z "$CONFIG_PATH" ]; then
  printf 'Configuration validation failed: missing config file path\n' >&2
  exit 2
fi

if [ ! -f "$CONFIG_PATH" ]; then
  if [ "$CONFIG_PATH" = "$PWD/.devsecops/pipeline.yaml" ] || [ "$CONFIG_PATH" = ".devsecops/pipeline.yaml" ]; then
    exit 0
  fi
  printf 'Configuration validation failed: file not found: %s\n' "$CONFIG_PATH" >&2
  exit 2
fi

if ! grep -E '^[[:space:]]*scanners:|^[[:space:]]*capabilities:' "$CONFIG_PATH" >/dev/null 2>&1; then
  printf 'Configuration validation failed: missing top-level "scanners" or "capabilities" section\n' >&2
  exit 2
fi

if grep -E '^[[:space:]]*capabilities:' "$CONFIG_PATH" >/dev/null 2>&1; then
  if ! grep -E '^[[:space:]]{2}(secret_detection|static_analysis|dependency_analysis|infrastructure_analysis):' "$CONFIG_PATH" >/dev/null 2>&1; then
    printf 'Configuration validation failed: "capabilities" section must contain at least one supported capability\n' >&2
    exit 2
  fi
fi

exit 0

exit 0