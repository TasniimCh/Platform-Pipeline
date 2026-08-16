#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)
PLATFORM_ROOT=$(cd "$SCRIPT_DIR/.." >/dev/null 2>&1 && pwd)

source "$PLATFORM_ROOT/lib/constants.sh"
source "$PLATFORM_ROOT/lib/logging.sh"
source "$PLATFORM_ROOT/config/config.sh"

GITLEAKS_VERSION="v8.24.2"
CONFTEST_VERSION="v0.64.0"
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

install_trivy() {
  if command -v trivy >/dev/null 2>&1; then
    log_info "trivy is already installed"
    return 0
  fi
  log_info "Installing trivy"
  if curl -sfL https://raw.githubusercontent.com/aquasecurity/trivy/main/contrib/install.sh | sh -s -- -b "$INSTALL_DIR" ; then
    log_info "Installed trivy to $INSTALL_DIR"
    return 0
  fi
  log_warn "Automatic trivy install failed"
  return 1
}

install_syft() {
  if command -v syft >/dev/null 2>&1; then
    log_info "syft is already installed"
    return 0
  fi
  log_info "Installing syft"
  if curl -sSfL https://raw.githubusercontent.com/anchore/syft/main/install.sh | sh -s -- -b "$INSTALL_DIR" ; then
    log_info "Installed syft to $INSTALL_DIR"
    return 0
  fi
  log_warn "Automatic syft install failed"
  return 1
}

install_node_package_manager() {
  local manager="$1"
  case "$manager" in
    yarn|pnpm)
      install_npm_package "$manager"
      ;;
    *)
      log_warn "Unsupported package manager for installation: $manager"
      return 1
      ;;
  esac
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

  rm -rf "$tmpdir"
}

install_conftest() {
  if command -v conftest >/dev/null 2>&1; then
    log_info "conftest is already installed"
    return 0
  fi

  local tmpdir
  tmpdir=$(mktemp -d)

  local version
  version="${CONFTEST_VERSION#v}"

  local archive
  archive="conftest_${version}_Linux_x86_64.tar.gz"

  local url
  url="https://github.com/open-policy-agent/conftest/releases/download/${CONFTEST_VERSION}/${archive}"

  log_info "Installing conftest ${CONFTEST_VERSION} from $url"

  if ! download_file "$url" "$tmpdir/$archive"; then
    rm -rf "$tmpdir"
    log_error "Failed to download conftest ${CONFTEST_VERSION}"
    return 1
  fi

  if ! tar -xzf "$tmpdir/$archive" -C "$tmpdir"; then
    rm -rf "$tmpdir"
    log_error "Failed to extract conftest ${CONFTEST_VERSION}"
    return 1
  fi

  if install -m 0755 "$tmpdir/conftest" "$INSTALL_DIR/conftest" 2>/dev/null; then
    log_info "Installed conftest to $INSTALL_DIR/conftest"
  else
    local user_install_dir="${HOME}/.local/bin"

    mkdir -p "$user_install_dir"
    install -m 0755 "$tmpdir/conftest" "$user_install_dir/conftest"

    export PATH="$user_install_dir:$PATH"

    if [ -n "${GITHUB_ENV:-}" ]; then
      printf 'PATH=%s\n' "$user_install_dir:$PATH" >> "$GITHUB_ENV"
    fi

    log_info "Installed conftest to $user_install_dir/conftest"
  fi

  rm -rf "$tmpdir"

  if ! command -v conftest >/dev/null 2>&1; then
    log_error "Conftest installation completed but executable is not available"
    return 1
  fi

  log_info "Conftest version: $(conftest --version)"

  return 0
}

install_cosign() {
  if command -v cosign >/dev/null 2>&1; then
    log_info "cosign is already installed"
    return 0
  fi

  local version="v2.4.1"
  local url="https://github.com/sigstore/cosign/releases/download/${version}/cosign-linux-amd64"
  local user_install_dir="${HOME}/.local/bin"

  log_info "Installing cosign ${version} from $url"
  mkdir -p "$user_install_dir"

  if ! download_file "$url" "$user_install_dir/cosign"; then
    log_error "Failed to download cosign ${version}"
    return 1
  fi

  chmod 0755 "$user_install_dir/cosign"
  export PATH="$user_install_dir:$PATH"

  if [ -n "${GITHUB_ENV:-}" ]; then
    printf 'PATH=%s\n' "$user_install_dir:$PATH" >> "$GITHUB_ENV"
  fi

  if ! command -v cosign >/dev/null 2>&1; then
    log_error "Cosign installation completed but executable is not available"
    return 1
  fi

  log_info "Cosign version: $(cosign version)"
  return 0
}

install_kyverno_cli() {
  if command -v kyverno >/dev/null 2>&1; then
    log_info "kyverno CLI is already installed"
    return 0
  fi

  local version="v1.13.0"
  local archive="kyverno-cli_${version}_linux_x86_64.tar.gz"
  local url="https://github.com/kyverno/kyverno/releases/download/${version}/${archive}"
  local user_install_dir="${HOME}/.local/bin"
  local tmpdir

  tmpdir=$(mktemp -d)
  log_info "Installing kyverno CLI ${version} from $url"
  mkdir -p "$user_install_dir"

  if ! download_file "$url" "$tmpdir/$archive"; then
    rm -rf "$tmpdir"
    log_error "Failed to download kyverno CLI ${version}"
    return 1
  fi

  if ! tar -xzf "$tmpdir/$archive" -C "$tmpdir"; then
    rm -rf "$tmpdir"
    log_error "Failed to extract kyverno CLI ${version}"
    return 1
  fi

  install -m 0755 "$tmpdir/kyverno" "$user_install_dir/kyverno" || {
    rm -rf "$tmpdir"
    log_error "Failed to install kyverno CLI"
    return 1
  }

  export PATH="$user_install_dir:$PATH"
  if [ -n "${GITHUB_ENV:-}" ]; then
    printf 'PATH=%s\n' "$user_install_dir:$PATH" >> "$GITHUB_ENV"
  fi

  rm -rf "$tmpdir"
  log_info "Kyverno CLI version: $(kyverno version)"
  return 0
}

install_required_tools() {
  local config_path="$1"
  local workspace="${WORKSPACE:-$PWD}"

  if [ -z "$config_path" ] || [ ! -f "$config_path" ]; then
    if [ "$config_path" = "$workspace/.devsecops/pipeline.yaml" ] || \
       [ "$config_path" = ".devsecops/pipeline.yaml" ]; then
      log_warn "No client configuration found at '$config_path'; using platform defaults"
    else
      log_error "Configuration file '$config_path' does not exist"
      exit "$PLATFORM_EXIT_CONFIG"
    fi
  fi

  install_python_package pyyaml

  local scanners
  scanners=$(enabled_scanner_tools "$workspace" "$config_path")

  if [ -n "$scanners" ]; then
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
        cosign)
          install_cosign
          ;;
        kyverno)
          install_kyverno_cli
          ;;
        *)
          log_warn "No installer implemented for scanner '$scanner'"
          ;;
      esac
    done
  else
    log_warn "No enabled scanners determined from capabilities; nothing to install"
  fi

  # Load normalized platform configuration once.
  local merged
  merged=$(load_merged_config_json "$workspace" "$config_path") || {
    log_error "Failed to load merged platform configuration"
    exit "$PLATFORM_EXIT_CONFIG"
  }

  # Install Conftest when policy enforcement is enabled.
local policy_enabled
policy_enabled=$(CONFIG_JSON="$merged" python3 - <<'PY'
import json
import os

config = json.loads(os.environ.get("CONFIG_JSON", "{}"))

enabled = config.get("capabilities", {}).get(
    "policy_enforcement",
    False
)

print("yes" if enabled else "")
PY
)

if [ "$policy_enabled" = "yes" ]; then
  log_info "Policy enforcement enabled; installing conftest"

  install_conftest || {
    log_error "Conftest installation failed"
    exit "$PLATFORM_EXIT_FAILURE"
  }
fi

  # Install container/supply-chain tools if enabled.
  local has_container
  has_container=$(CONFIG_JSON="$merged" python3 -c "
import os
import json

cfg = json.loads(os.environ.get('CONFIG_JSON', '{}'))
caps = cfg.get('capabilities', {})

print(
    'yes'
    if (
        caps.get('container_build')
        or caps.get('container_scan')
        or caps.get('sbom')
        or caps.get('provenance')
    )
    else ''
)
")

  if [ "$has_container" = "yes" ]; then
    install_trivy || log_warn "trivy install failed"
    install_syft || log_warn "syft install failed"
  fi
}

main() {
  echo "DEFAULT_CONFIG=$DEFAULT_CONFIG"
  echo "CAPABILITY_MAP=$CAPABILITY_MAP"

  if [ "$#" -lt 1 ]; then
    log_error "Missing configuration file path"
    exit $PLATFORM_EXIT_CONFIG
  fi

  install_required_tools "$1"
}

main "$@"
