#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)
PLATFORM_ROOT=$(cd "$SCRIPT_DIR/.." >/dev/null 2>&1 && pwd)

source "$PLATFORM_ROOT/lib/constants.sh"
source "$PLATFORM_ROOT/lib/logging.sh"
source "$PLATFORM_ROOT/config/config.sh"

WORKSPACE="${WORKSPACE:-$PWD}"
CONFIG_FILE="${CONFIG_FILE:-.devsecops/pipeline.yaml}"

config_json=$(load_merged_config_json "$WORKSPACE" "$CONFIG_FILE") || {
    log_error "Failed to load merged platform configuration"
    exit "$PLATFORM_EXIT_CONFIG"
}

CONFIG_JSON="$config_json" python3 <<'PY'
import json
import os
import sys

config = json.loads(os.environ["CONFIG_JSON"])
capabilities = config.get("capabilities", {})

missing = []


def require_secret(capability, secret_name):
    if not capabilities.get(capability, False):
        return

    value = os.environ.get(secret_name, "")

    if not value:
        missing.append(
            f"{secret_name} (required by capability '{capability}')"
        )


# Dependency/SCA analysis
require_secret(
    "dependency_analysis",
    "SNYK_TOKEN",
)

# GitOps update
require_secret(
    "gitops_update",
    "GITOPS_TOKEN",
)


# Container registry operations.
#
# These should be required only for capabilities that actually
# authenticate against Docker Hub.
require_secret(
    "image_publish",
    "DOCKERHUB_USERNAME",
)

require_secret(
    "image_publish",
    "DOCKERHUB_TOKEN",
)


if missing:
    print("ERROR: Required GitHub Actions secrets are missing:", file=sys.stderr)

    for item in missing:
        print(f"  - {item}", file=sys.stderr)

    print(
        "\nThe pipeline cannot continue because an enabled capability "
        "requires credentials that were not supplied by the client.",
        file=sys.stderr,
    )

    sys.exit(2)


print("Required GitHub Actions secrets are available.")
PY