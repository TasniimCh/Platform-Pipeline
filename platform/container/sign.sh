#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)
PLATFORM_ROOT=$(cd "$SCRIPT_DIR/.." >/dev/null 2>&1 && pwd)

source "$PLATFORM_ROOT/lib/constants.sh"
source "$PLATFORM_ROOT/lib/logging.sh"

IMAGE_REPOSITORY="${1:-}"
IMAGE_DIGEST="${2:-}"

if [ -z "$IMAGE_REPOSITORY" ] || [ -z "$IMAGE_DIGEST" ]; then
  log_error "Usage: sign.sh <image_repository> <image_digest>"
  exit "$PLATFORM_EXIT_CONFIG"
fi

if ! command -v cosign >/dev/null 2>&1; then
  log_error "cosign is required for image signing"
  exit "$PLATFORM_EXIT_TOOL_MISSING"
fi

if ! cosign sign --yes "${IMAGE_REPOSITORY}@${IMAGE_DIGEST}"; then
  log_error "Image signing failed for ${IMAGE_REPOSITORY}@${IMAGE_DIGEST}"
  exit "$PLATFORM_EXIT_FAILURE"
fi

log_info "Image signed: ${IMAGE_REPOSITORY}@${IMAGE_DIGEST}"
