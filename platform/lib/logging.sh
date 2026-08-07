#!/usr/bin/env bash
set -euo pipefail

# Logging utilities for platform components.
# Supports structured logging and log-level filtering.

: ${LOG_LEVEL:=info}

log_level_value() {
  case "$1" in
    debug) echo 10 ;;
    info) echo 20 ;;
    warn) echo 30 ;;
    error) echo 40 ;;
    *) echo 20 ;;
  esac
}

log() {
  local level="$1" ; shift
  local msg="$*"
  local timestamp
  timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
  local level_value
  level_value=$(log_level_value "$level")
  local current_value
  current_value=$(log_level_value "$LOG_LEVEL")

  if [ "$level_value" -lt "$current_value" ]; then
    return 0
  fi

  printf '%s [%s] %s\n' "$timestamp" "${level^^}" "$msg"
}

log_debug() { log debug "$*"; }
log_info() { log info "$*"; }
log_warn() { log warn "$*"; }
log_error() { log error "$*"; }
