#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)
PLATFORM_ROOT=$(cd "$SCRIPT_DIR/.." >/dev/null 2>&1 && pwd)

source "$PLATFORM_ROOT/lib/constants.sh"
source "$PLATFORM_ROOT/lib/logging.sh"


validate_helm_chart() {
  local chart_path="$1"

  if [ -z "$chart_path" ]; then
    log_error "Helm chart path is required"
    return "$PLATFORM_EXIT_CONFIG"
  fi

  if [ ! -d "$chart_path" ]; then
    log_error "Helm chart directory does not exist: $chart_path"
    return "$PLATFORM_EXIT_CONFIG"
  fi

  if [ ! -f "$chart_path/Chart.yaml" ]; then
    log_error "Invalid Helm chart: Chart.yaml not found in '$chart_path'"
    return "$PLATFORM_EXIT_CONFIG"
  fi

  if ! command -v helm >/dev/null 2>&1; then
    log_error "Helm is required for Helm policy testing but is not installed"
    return "$PLATFORM_EXIT_FAILURE"
  fi
}


render_helm_chart() {
  local chart_path="$1"
  local output_dir="$2"
  local values_file="${3:-}"

  validate_helm_chart "$chart_path" || return $?

  if [ -z "$output_dir" ]; then
    log_error "Helm rendering output directory is required"
    return "$PLATFORM_EXIT_CONFIG"
  fi

  mkdir -p "$output_dir"

  local chart_name
  chart_name=$(basename "$chart_path")

  local output_file
  output_file="$output_dir/${chart_name}.yaml"

  log_info "Rendering Helm chart: $chart_path"

  # -------------------------------------------------------------------------
  # Optional values file
  # -------------------------------------------------------------------------

  if [ -n "$values_file" ]; then
    if [ ! -f "$values_file" ]; then
      log_error "Helm values file does not exist: $values_file"
      return "$PLATFORM_EXIT_CONFIG"
    fi

    log_debug "Using Helm values file: $values_file"

    if ! helm template \
        "$chart_name" \
        "$chart_path" \
        --values "$values_file" \
        > "$output_file"; then

      rm -f "$output_file"

      log_error "Helm rendering failed for chart '$chart_path'"
      return "$PLATFORM_EXIT_FAILURE"
    fi

  else

    if ! helm template \
        "$chart_name" \
        "$chart_path" \
        > "$output_file"; then

      rm -f "$output_file"

      log_error "Helm rendering failed for chart '$chart_path'"
      return "$PLATFORM_EXIT_FAILURE"
    fi
  fi

  # -------------------------------------------------------------------------
  # Validate rendered output
  # -------------------------------------------------------------------------

  if [ ! -s "$output_file" ]; then
    rm -f "$output_file"

    log_error "Helm rendering produced an empty manifest: $chart_path"
    return "$PLATFORM_EXIT_FAILURE"
  fi

  log_info "Helm chart rendered successfully: $output_file"

  printf '%s\n' "$output_file"
}


render_helm_charts() {
  local chart_list="$1"
  local output_dir="$2"

  if [ ! -f "$chart_list" ]; then
    log_error "Helm chart list does not exist: $chart_list"
    return "$PLATFORM_EXIT_CONFIG"
  fi

  mkdir -p "$output_dir"

  local rendered_count=0

  while IFS= read -r chart_path; do
    [ -z "$chart_path" ] && continue

    log_debug "Processing Helm chart: $chart_path"

    render_helm_chart \
      "$chart_path" \
      "$output_dir" \
      >/dev/null

    rendered_count=$((rendered_count + 1))
  done < "$chart_list"

  if [ "$rendered_count" -eq 0 ]; then
    log_error "No Helm charts found in chart list"
    return "$PLATFORM_EXIT_FAILURE"
  fi

  log_info "Rendered $rendered_count Helm chart(s)"
}


if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  if [ "$#" -lt 2 ]; then
    log_error "Usage: $0 <chart-path|chart-list> <output-directory> [values-file]"
    exit "$PLATFORM_EXIT_CONFIG"
  fi

  INPUT="$1"
  OUTPUT_DIR="$2"
  VALUES_FILE="${3:-}"

  if [ -f "$INPUT" ]; then
    render_helm_charts "$INPUT" "$OUTPUT_DIR"
  else
    render_helm_chart "$INPUT" "$OUTPUT_DIR" "$VALUES_FILE" >/dev/null
  fi
fi