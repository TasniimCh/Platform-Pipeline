#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)
PLATFORM_ROOT=$(cd "$SCRIPT_DIR/.." >/dev/null 2>&1 && pwd)

source "$PLATFORM_ROOT/lib/constants.sh"
source "$PLATFORM_ROOT/lib/logging.sh"
source "$PLATFORM_ROOT/config/config.sh"

echo "DEBUG SCRIPT_DIR=$SCRIPT_DIR"
echo "DEBUG PLATFORM_ROOT=$PLATFORM_ROOT"
echo "DEBUG RESOLVE_SCRIPT=$SCRIPT_DIR/resolve.sh"
echo "DEBUG RESOLVE_EXISTS=$(test -f "$SCRIPT_DIR/resolve.sh" && echo yes || echo no)"

resolve_manifests() {
  local workspace="${1:-$WORKSPACE}"
  local config_file="${2:-$CONFIG_FILE}"
  local destination="${3:-}"

  if [ -z "$destination" ]; then
    log_error "Manifest resolver requires a destination directory"
    return "$PLATFORM_EXIT_CONFIG"
  fi

  mkdir -p "$destination"

  local config_json
  config_json=$(load_merged_config_json "$workspace" "$config_file") || {
    log_error "Failed to load merged configuration"
    return "$PLATFORM_EXIT_CONFIG"
  }

  local paths_json
  paths_json=$(CONFIG_JSON="$config_json" python3 - <<'PY'
import json
import os

config = json.loads(os.environ.get("CONFIG_JSON", "{}"))

paths = config.get("policy", {}).get("paths", [])

if paths is None:
    paths = []

if not isinstance(paths, list):
    raise SystemExit(
        'Configuration error: "policy.paths" must be a list'
    )

print(json.dumps(paths))
PY
  ) || {
    log_error "Invalid policy.paths configuration"
    return "$PLATFORM_EXIT_CONFIG"
  }

  if [ "$paths_json" = "[]" ]; then
    log_error "No policy input paths configured"
    return "$PLATFORM_EXIT_CONFIG"
  fi

  local manifest_count=0
  local path_index=0

  while IFS= read -r configured_path; do
    [ -z "$configured_path" ] && continue

    path_index=$((path_index + 1))

    # -----------------------------------------------------------------------
    # Validate configured path
    # -----------------------------------------------------------------------

    if [[ "$configured_path" = /* ]]; then
      log_error "Policy input path must be relative to workspace: $configured_path"
      return "$PLATFORM_EXIT_CONFIG"
    fi

    if [[ "$configured_path" == *".."* ]]; then
      log_error "Policy input path traversal is not allowed: $configured_path"
      return "$PLATFORM_EXIT_CONFIG"
    fi

    local input_path="$workspace/$configured_path"

    if [ ! -e "$input_path" ]; then
      log_error "Policy input path does not exist: $configured_path"
      return "$PLATFORM_EXIT_CONFIG"
    fi

    # Resolve the canonical path and make sure it remains inside workspace.
    local canonical_workspace
    local canonical_input

    canonical_workspace=$(cd "$workspace" && pwd)
    
    if [ -d "$input_path" ]; then
      canonical_input=$(cd "$input_path" && pwd)
    else
      canonical_input=$(cd "$(dirname "$input_path")" && pwd)/$(basename "$input_path")
    fi

    case "$canonical_input" in
      "$canonical_workspace"/*)
        ;;
      *)
        log_error "Policy input path escapes workspace: $configured_path"
        return "$PLATFORM_EXIT_CONFIG"
        ;;
    esac

    # -----------------------------------------------------------------------
    # Single YAML manifest
    # -----------------------------------------------------------------------

    if [ -f "$input_path" ]; then
      case "$input_path" in
        *.yaml|*.yml)
          local output_file
          output_file="$destination/input-${path_index}.yaml"

          cp "$input_path" "$output_file"

          log_debug "Resolved manifest: $configured_path"

          manifest_count=$((manifest_count + 1))
          ;;

        *)
          log_error "Unsupported policy input file: $configured_path"
          return "$PLATFORM_EXIT_CONFIG"
          ;;
      esac

      continue
    fi

    # -----------------------------------------------------------------------
    # Directory
    # -----------------------------------------------------------------------

    if [ -d "$input_path" ]; then

      # Detect Helm chart.
      if [ -f "$input_path/Chart.yaml" ]; then
        log_info "Detected Helm chart: $configured_path"

        # Do not render here.
        # render-helm.sh is responsible for Helm rendering.
        printf '%s\n' "$input_path" >> "$destination/helm-charts.txt"

        continue
      fi

      # Existing Kubernetes manifests.
      while IFS= read -r manifest; do
        local relative_name
        relative_name=$(realpath --relative-to="$workspace" "$manifest")

        local output_file
        output_file="$destination/manifest-${manifest_count}.yaml"

        cp "$manifest" "$output_file"

        log_debug "Resolved manifest: $relative_name"

        manifest_count=$((manifest_count + 1))
      done < <(
        find "$input_path" \
          -type f \
          \( -name "*.yaml" -o -name "*.yml" \) \
          -print
      )

      continue
    fi

    log_error "Unsupported policy input: $configured_path"
    return "$PLATFORM_EXIT_CONFIG"

  done < <(
    PATHS_JSON="$paths_json" python3 - <<'PY'
import json
import os

paths = json.loads(os.environ["PATHS_JSON"])

for path in paths:
    if not isinstance(path, str):
        raise SystemExit(
            'Configuration error: every value in "policy.paths" must be a string'
        )

    print(path)
PY
  )

  # -------------------------------------------------------------------------
  # Result
  # -------------------------------------------------------------------------

  local helm_count=0

  if [ -f "$destination/helm-charts.txt" ]; then
    helm_count=$(wc -l < "$destination/helm-charts.txt")
  fi

  if [ "$manifest_count" -eq 0 ] && [ "$helm_count" -eq 0 ]; then
    log_error "No Kubernetes manifests or Helm charts found in configured policy paths"
    return "$PLATFORM_EXIT_FAILURE"
  fi

  log_info "Manifest resolution complete: $manifest_count manifest(s), $helm_count Helm chart(s)"

  return 0
}


if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  resolve_manifests "$@"
fi