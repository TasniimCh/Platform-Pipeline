#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)
PLATFORM_ROOT=$(cd "$SCRIPT_DIR/.." >/dev/null 2>&1 && pwd)

source "$PLATFORM_ROOT/lib/constants.sh"
source "$PLATFORM_ROOT/lib/logging.sh"

: "${WORKSPACE:=${PWD}}"
: "${REPORT_DIR:=.devsecops/reports}"
: "${IMAGE_REPOSITORY:=}"
: "${IMAGE_DIGEST:=}"

validate_digest() {
    local digest="$1"

    [[ "$digest" =~ ^sha256:[a-fA-F0-9]{64}$ ]]
}

validate_repository() {
    local repository="$1"

    [ -n "$repository" ] &&
    [[ "$repository" != *:* ]] &&
    [[ "$repository" != *@* ]]
}

# ------------------------------------------------------------------
# Source B — externally published image.
#
# External inputs always have priority over pipeline-generated image
# metadata.
# ------------------------------------------------------------------

if [ -n "${IMAGE_REPOSITORY// }" ] || [ -n "${IMAGE_DIGEST// }" ]; then

    if [ -z "${IMAGE_REPOSITORY// }" ] || [ -z "${IMAGE_DIGEST// }" ]; then
        log_error \
          "External image source requires both image-repository and image-digest"
        exit "$PLATFORM_EXIT_CONFIG"
    fi

    if ! validate_repository "$IMAGE_REPOSITORY"; then
        log_error \
          "Invalid external image repository: $IMAGE_REPOSITORY"
        exit "$PLATFORM_EXIT_CONFIG"
    fi

    if ! validate_digest "$IMAGE_DIGEST"; then
        log_error \
          "Invalid external image digest: $IMAGE_DIGEST"
        exit "$PLATFORM_EXIT_CONFIG"
    fi

    log_info "Using externally published image"
    log_info "Image repository: $IMAGE_REPOSITORY"
    log_info "Image digest: $IMAGE_DIGEST"

    printf '%s@%s\n' "$IMAGE_REPOSITORY" "$IMAGE_DIGEST"
    exit 0
fi


# ------------------------------------------------------------------
# Source A — image published by this pipeline.
#
# Only metadata with published=true and a registry digest is valid.
# ------------------------------------------------------------------

metadata_candidates=()

while IFS= read -r metadata; do
    metadata_candidates+=("$metadata")
done < <(
    find \
      "$WORKSPACE/$REPORT_DIR/container" \
      -type f \
      -name metadata.json \
      2>/dev/null | sort
)

if [ "${#metadata_candidates[@]}" -eq 0 ]; then
    log_error "No container metadata found"
    log_error \
      "gitops_update requires either image_publish=true in this pipeline " \
      "or image-repository/image-digest supplied as workflow inputs"
    exit "$PLATFORM_EXIT_EXECUTION"
fi

metadata="${metadata_candidates[-1]}"

python3 - "$metadata" <<'PY'
import json
import re
import sys

path = sys.argv[1]

with open(path, "r", encoding="utf-8") as handle:
    metadata = json.load(handle)

if metadata.get("published") is not True:
    raise SystemExit(
        "Container metadata does not represent a published image"
    )

repository = str(
    metadata.get("registry_repository") or ""
).strip()

digest = str(
    metadata.get("image_digest") or ""
).strip()

if not repository:
    raise SystemExit(
        "Published container metadata is missing registry_repository"
    )

if not re.fullmatch(r"sha256:[a-fA-F0-9]{64}", digest):
    raise SystemExit(
        "Published container metadata is missing a valid registry digest"
    )

if ":" in repository.split("/")[-1]:
    raise SystemExit(
        f"Registry repository must not contain a tag: {repository}"
    )

print(f"{repository}@{digest}")
PY