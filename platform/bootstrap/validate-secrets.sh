#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(
  cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1
  pwd
)
PLATFORM_ROOT=$(
  cd "$SCRIPT_DIR/.." >/dev/null 2>&1
  pwd
)

source "$PLATFORM_ROOT/lib/constants.sh"
source "$PLATFORM_ROOT/lib/logging.sh"

: "${CAPABILITIES_JSON:=}"

if [ -z "$CAPABILITIES_JSON" ]; then
  log_error "CAPABILITIES_JSON is empty"
  exit "$PLATFORM_EXIT_CONFIG"
fi

if ! command -v python3 >/dev/null 2>&1; then
  log_error "Python 3 is required to validate platform credentials"
  exit "$PLATFORM_EXIT_TOOL_MISSING"
fi

set +e
CAPABILITIES_JSON="$CAPABILITIES_JSON" python3 <<'PY'
import json
import os
import sys

raw_capabilities = os.environ.get("CAPABILITIES_JSON", "")

try:
    capabilities = json.loads(raw_capabilities)
except json.JSONDecodeError as exc:
    print(
        f"ERROR: CAPABILITIES_JSON is invalid: {exc}",
        file=sys.stderr,
    )
    sys.exit(2)

if not isinstance(capabilities, dict):
    print(
        "ERROR: CAPABILITIES_JSON must contain a JSON object.",
        file=sys.stderr,
    )
    sys.exit(2)

missing = []


def require_secret(capability, secret_name):
    if capabilities.get(capability) is not True:
        return

    if not os.environ.get(secret_name, "").strip():
        missing.append((capability, secret_name))


# Snyk authentication
require_secret(
    "dependency_analysis",
    "SNYK_TOKEN",
)

# GitOps repository authentication
require_secret(
    "gitops_update",
    "GITOPS_TOKEN",
)

# Docker Hub authentication is currently required only when publishing.
require_secret(
    "image_publish",
    "DOCKERHUB_USERNAME",
)
require_secret(
    "image_publish",
    "DOCKERHUB_TOKEN",
)

if missing:
    print(
        "ERROR: Required GitHub Actions secrets are missing:",
        file=sys.stderr,
    )

    for capability, secret_name in missing:
        print(
            f"  - {secret_name} "
            f"(required by capability '{capability}')",
            file=sys.stderr,
        )

    print(
        "\nAdd the missing secrets to the client repository or "
        "disable the corresponding capabilities.",
        file=sys.stderr,
    )
    sys.exit(2)

print("Required GitHub Actions secrets are available.")
sys.exit(0)
PY
VALIDATION_EXIT_CODE=$?
set -e

case "$VALIDATION_EXIT_CODE" in
  "$PLATFORM_EXIT_SUCCESS")
    log_info "Credential preflight validation completed successfully"
    ;;

  "$PLATFORM_EXIT_CONFIG")
    log_error "Credential preflight validation failed"
    ;;

  *)
    log_error \
      "Credential validation encountered an execution error: " \
      "$VALIDATION_EXIT_CODE"
    VALIDATION_EXIT_CODE="$PLATFORM_EXIT_EXECUTION"
    ;;
esac

exit "$VALIDATION_EXIT_CODE"