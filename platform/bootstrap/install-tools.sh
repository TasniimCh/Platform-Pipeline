#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)
PLATFORM_ROOT=$(cd "$SCRIPT_DIR/.." >/dev/null 2>&1 && pwd)

source "$PLATFORM_ROOT/lib/constants.sh"
source "$PLATFORM_ROOT/lib/logging.sh"
source "$PLATFORM_ROOT/config/config.sh"

GITLEAKS_VERSION="v8.19.0"
INSTALL_DIR="/usr/local/bin"
PIP_USER_BIN="${HOME}/.local/bin"

resolve_download_tool() {
  if command -v curl >/dev/null 2>&1; then
    echo curl
  elif command -v wget >/dev/null 2>&1; then
    echo wget
  else
    return 1
  fi
}

install_python_package() {
  local package="$1"

  if command -v "$package" >/dev/null 2>&1; then
    log_info "$package is already installed"
    return 0
  fi

  if ! command -v pip3 >/dev/null 2>&1; then
    log_error "pip3 is required to install $package"
    return 1
  fi

  log_info "Installing $package via pip3"
  if pip3 install --user "$package" >/dev/null 2>&1; then
    mkdir -p "$PIP_USER_BIN"
    export PATH="$PIP_USER_BIN:$PATH"
    if [ -n "${GITHUB_ENV:-}" ]; then
      printf 'PATH=%s\n' "$PIP_USER_BIN:$PATH" >> "$GITHUB_ENV"
    fi
    log_info "Installed $package to $PIP_USER_BIN"
    return 0
  fi

  return 1
}

install_npm_package() {
  local package="$1"

  if command -v "$package" >/dev/null 2>&1; then
    log_info "$package is already installed"
    return 0
  fi

  if ! command -v npm >/dev/null 2>&1; then
    log_error "npm is required to install $package"
    return 1
  fi

  log_info "Installing $package via npm"
  if npm install -g "$package" >/dev/null 2>&1; then
    log_info "Installed $package globally"
    return 0
  fi

  log_info "Global npm install failed, falling back to local user install"
  if npm install --prefix "$HOME/.local" "$package" >/dev/null 2>&1; then
    mkdir -p "$PIP_USER_BIN"
    export PATH="$PIP_USER_BIN:$PATH"
    if [ -n "${GITHUB_ENV:-}" ]; then
      printf 'PATH=%s\n' "$PIP_USER_BIN:$PATH" >> "$GITHUB_ENV"
    fi
    log_info "Installed $package to $HOME/.local/bin"
    return 0
  fi

  return 1
}

download_file() {
  local url="$1"
  local destination="$2"
  local downloader

  downloader=$(resolve_download_tool) || {
    log_error "No download tool available. Install curl or wget."
    exit $PLATFORM_EXIT_FAILURE
  }

  if [ "$downloader" = curl ]; then
    curl -fsSL "$url" -o "$destination"
  else
    wget -qO "$destination" "$url"
  fi
}

install_gitleaks() {
  if command -v gitleaks >/dev/null 2>&1; then
    log_info "gitleaks is already installed"
    return 0
  fi

  local tmpdir
  tmpdir=$(mktemp -d)
  trap 'rm -rf "$tmpdir"' RETURN

  local version
  version="${GITLEAKS_VERSION#v}"
  local archive
  archive="gitleaks_${version}_linux_x64.tar.gz"
  local url
  url="https://github.com/zricethezav/gitleaks/releases/download/${GITLEAKS_VERSION}/${archive}"

  log_info "Installing gitleaks from $url"
  download_file "$url" "$tmpdir/$archive"
  tar -xzf "$tmpdir/$archive" -C "$tmpdir"

  if install -m 0755 "$tmpdir/gitleaks" "$INSTALL_DIR/gitleaks" 2>/dev/null; then
    log_info "Installed gitleaks to $INSTALL_DIR/gitleaks"
  else
    INSTALL_DIR="${HOME}/.local/bin"
    mkdir -p "$INSTALL_DIR"
    install -m 0755 "$tmpdir/gitleaks" "$INSTALL_DIR/gitleaks"
    log_info "Installed gitleaks to $INSTALL_DIR/gitleaks"
    export PATH="$INSTALL_DIR:$PATH"
    if [ -n "${GITHUB_ENV:-}" ]; then
      printf 'PATH=%s\n' "$INSTALL_DIR:$PATH" >> "$GITHUB_ENV"
    fi
  fi
}

install_required_tools() {
  local config_path="$1"
  local workspace="$PWD"

  if [ -z "$config_path" ] || [ ! -f "$config_path" ]; then
    if [ "$config_path" = "$workspace/.devsecops/pipeline.yaml" ] || [ "$config_path" = ".devsecops/pipeline.yaml" ]; then
      log_warn "No client configuration found at '$config_path'; using platform defaults"
    else
      log_error "Configuration file '$config_path' does not exist"
      exit "$PLATFORM_EXIT_CONFIG"
    fi
  fi

  local scanners
  scanners=$(enabled_scanner_tools "$workspace" "$config_path")

  if [ -z "$scanners" ]; then
    log_warn "No enabled scanners determined from capabilities; nothing to install"
    return 0
  fi

  for scanner in $scanners; do
    case "$scanner" in
      gitleaks)
        install_gitleaks
        ;;
      semgrep)
        install_python_package semgrep
        ;;
      snyk)
        install_npm_package snyk
        ;;
      checkov)
        install_python_package checkov
        ;;
      *)
        log_warn "No installer implemented for scanner '$scanner'"
        ;;
    esac
  done
}

main() {
  if [ "$#" -lt 1 ]; then
    log_error "Missing configuration file path"
    exit $PLATFORM_EXIT_CONFIG
  fi

  install_required_tools "$1"
}

main "$@"
