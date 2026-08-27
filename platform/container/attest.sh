#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)
PLATFORM_ROOT=$(cd "$SCRIPT_DIR/.." >/dev/null 2>&1 && pwd)

source "$PLATFORM_ROOT/lib/constants.sh"
source "$PLATFORM_ROOT/lib/logging.sh"

IMAGE_REPOSITORY="${1:-}"
IMAGE_DIGEST="${2:-}"
PROVENANCE_FILE="${3:-}"

if [ -z "$IMAGE_REPOSITORY" ] \
  || [ -z "$IMAGE_DIGEST" ] \
  || [ -z "$PROVENANCE_FILE" ]; then
  log_error \
    "Usage: attest.sh <image_repository> <image_digest> <provenance_json_path>"
  exit "$PLATFORM_EXIT_CONFIG"
fi

if [[ ! "$IMAGE_DIGEST" =~ ^sha256:[a-fA-F0-9]{64}$ ]]; then
  log_error "Invalid image digest: $IMAGE_DIGEST"
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

if ! command -v jq >/dev/null 2>&1; then
  log_error "jq is required to prepare provenance attestation"
  exit "$PLATFORM_EXIT_TOOL_MISSING"
fi

IMAGE_REF="${IMAGE_REPOSITORY}@${IMAGE_DIGEST}"
PREDICATE_FILE=$(mktemp)
trap 'rm -f "$PREDICATE_FILE"' EXIT

# Cosign expects only the predicate, not the complete in-toto statement.
if jq -e '.predicate | type == "object"' \
  "$PROVENANCE_FILE" >/dev/null 2>&1; then
  jq '.predicate' "$PROVENANCE_FILE" > "$PREDICATE_FILE"
else
  cp "$PROVENANCE_FILE" "$PREDICATE_FILE"
fi

if ! jq -e '
  .builder.id
  | type == "string" and length > 0
' "$PREDICATE_FILE" >/dev/null; then
  log_error \
    "Invalid SLSA provenance predicate: required field builder.id is missing"
  exit "$PLATFORM_EXIT_CONFIG"
fi

log_info "Attesting provenance for immutable image: $IMAGE_REF"

if ! cosign attest \
  --yes \
  --predicate "$PREDICATE_FILE" \
  --type slsaprovenance \
  "$IMAGE_REF"; then
  log_error "Provenance attestation failed for $IMAGE_REF"
  exit "$PLATFORM_EXIT_EXECUTION"
fi

log_info "Provenance attestation completed successfully: $IMAGE_REF"
exit "$PLATFORM_EXIT_SUCCESS"