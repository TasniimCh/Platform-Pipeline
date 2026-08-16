#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)
PLATFORM_ROOT=$(cd "$SCRIPT_DIR/.." >/dev/null 2>&1 && pwd)

source "$PLATFORM_ROOT/lib/constants.sh"
source "$PLATFORM_ROOT/lib/logging.sh"

IMAGE_REPOSITORY="${1:-}"
IMAGE_DIGEST="${2:-}"
PROVENANCE_FILE="${3:-}"

if [ -z "$IMAGE_REPOSITORY" ] || [ -z "$IMAGE_DIGEST" ] || [ -z "$PROVENANCE_FILE" ]; then
  log_error "Usage: attest.sh <image_repository> <image_digest> <provenance_json_path>"
  exit "$PLATFORM_EXIT_CONFIG"
fi

if [ ! -f "$PROVENANCE_FILE" ]; then
  log_error "Provenance file not found: $PROVENANCE_FILE"
  exit "$PLATFORM_EXIT_CONFIG"
fi

if ! command -v cosign >/dev/null 2>&1; then
  log_error "cosign is required for provenance attestation"
  exit "$PLATFORM_EXIT_TOOL_MISSING"
fi

if ! cosign attest --yes --predicate "$PROVENANCE_FILE" --type slsaprovenance "${IMAGE_REPOSITORY}@${IMAGE_DIGEST}"; then
  log_error "Attestation signing failed for ${IMAGE_REPOSITORY}@${IMAGE_DIGEST}"
  exit "$PLATFORM_EXIT_FAILURE"
fi

log_info "Attestation signed: ${IMAGE_REPOSITORY}@${IMAGE_DIGEST}"
