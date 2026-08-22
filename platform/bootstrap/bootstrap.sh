#!/usr/bin/env bash
set -euo pipefail

# Bootstrap module for platform environment preparation.
# Loads config, validates required inputs, exports environment variables,
# and prepares the report directory.

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)
PLATFORM_ROOT=$(cd "$SCRIPT_DIR/.." >/dev/null 2>&1 && pwd)

source "$PLATFORM_ROOT/lib/constants.sh"
source "$PLATFORM_ROOT/lib/logging.sh"

: ${WORKSPACE:=${PWD}}
: ${CONFIG_FILE:=".devsecops/pipeline.yaml"}
: ${REPORT_DIR:=".devsecops/reports"}
: ${LOG_LEVEL:=info}

export PLATFORM_ROOT
export WORKSPACE
export CONFIG_FILE
export REPORT_DIR
export LOG_LEVEL

validate_bootstrap() {
  log_debug "Validating bootstrap environment"

  if [ -z "$WORKSPACE" ]; then
    log_error "WORKSPACE is not set"
    exit $PLATFORM_EXIT_CONFIG
  fi

  if [ -z "$CONFIG_FILE" ]; then
    log_error "CONFIG_FILE is not set"
    exit $PLATFORM_EXIT_CONFIG
  fi

  if [ -z "$REPORT_DIR" ]; then
    log_error "REPORT_DIR is not set"
    exit $PLATFORM_EXIT_CONFIG
  fi

  if [ ! -d "$WORKSPACE" ]; then
    log_error "WORKSPACE directory '$WORKSPACE' does not exist"
    exit $PLATFORM_EXIT_CONFIG
  fi
}

prepare_report_directory() {
  log_info "Preparing report directory: $WORKSPACE/$REPORT_DIR"
  mkdir -p "$WORKSPACE/$REPORT_DIR"
}

validate_configuration() {
log_debug "Validating platform configuration"
local config_path="$WORKSPACE/$CONFIG_FILE"

if [ ! -f "$config_path" ]; then
log_info "No client configuration found at '$config_path'; using platform defaults"
return 0
fi

command -v pip3 >/dev/null 2>&1 && pip3 install --user --quiet pyyaml

if ! bash "$PLATFORM_ROOT/config/validate.sh" "$config_path"; then
log_error "Platform configuration validation failed for '$config_path'"
exit $PLATFORM_EXIT_CONFIG
fi
}

bootstrap() {
  log_info "Bootstrapping platform environment"
  validate_bootstrap
  validate_configuration
  prepare_report_directory
  log_info "Bootstrap complete"
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  bootstrap
fi