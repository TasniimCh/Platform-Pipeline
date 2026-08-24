#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)
PLATFORM_ROOT=$(cd "$SCRIPT_DIR/.." >/dev/null 2>&1 && pwd)

source "$PLATFORM_ROOT/lib/constants.sh"
source "$PLATFORM_ROOT/lib/logging.sh"
source "$PLATFORM_ROOT/config/config.sh"

: "${WORKSPACE:=${PWD}}"
: "${CONFIG_FILE:=.devsecops/pipeline.yaml}"
: "${REPORT_DIR:=.devsecops/reports}"
: "${LOG_LEVEL:=info}"
: "${DOCKERHUB_USERNAME:=}"
: "${DOCKERHUB_TOKEN:=}"

export WORKSPACE
export CONFIG_FILE
export REPORT_DIR
export LOG_LEVEL

RESULT_BASE="$WORKSPACE/$REPORT_DIR/container"

log_info "Starting container image publication"
log_info "Workspace: $WORKSPACE"
log_info "Configuration: $WORKSPACE/$CONFIG_FILE"

if ! command -v docker >/dev/null 2>&1; then
  log_error "Docker is required for image publication but was not found in PATH"
  exit "$PLATFORM_EXIT_TOOL_MISSING"
fi

config_json=$(load_merged_config_json "$WORKSPACE" "$CONFIG_FILE") || {
  log_error "Failed to load merged platform configuration"
  exit "$PLATFORM_EXIT_CONFIG"
}

publish_enabled=$(CONFIG_JSON="$config_json" python3 - <<'PY'
import json
import os

config = json.loads(os.environ.get("CONFIG_JSON", "{}"))
caps = config.get("capabilities", {})

print("true" if caps.get("image_publish", False) else "false")
PY
)

if [ "$publish_enabled" != "true" ]; then
  log_info "Image publication capability is disabled; skipping registry publication"
  exit "$PLATFORM_EXIT_SUCCESS"
fi

if [ -z "${DOCKERHUB_USERNAME// }" ]; then
  log_error "Image publication is enabled but DOCKERHUB_USERNAME is missing"
  log_error "Provide DOCKERHUB_USERNAME as a GitHub Actions secret"
  exit "$PLATFORM_EXIT_CONFIG"
fi

if [ -z "${DOCKERHUB_TOKEN// }" ]; then
  log_error "Image publication is enabled but DOCKERHUB_TOKEN is missing"
  log_error "Provide DOCKERHUB_TOKEN as a GitHub Actions secret"
  exit "$PLATFORM_EXIT_CONFIG"
fi

if [ ! -d "$RESULT_BASE" ]; then
  log_error "Container report directory does not exist: $RESULT_BASE"
  log_error "Image publication requires container/run.sh to build a local image first"
  exit "$PLATFORM_EXIT_EXECUTION"
fi

metadata_file=$(
  find "$RESULT_BASE" -type f -name metadata.json 2>/dev/null \
    | sort \
    | tail -n 1
)

if [ -z "$metadata_file" ]; then
  log_error "No container metadata.json was found under $RESULT_BASE"
  log_error "Image publication requires a local image produced by container/run.sh"
  exit "$PLATFORM_EXIT_EXECUTION"
fi

log_info "Using container metadata: $metadata_file"

publication_values=$(
  CONFIG_JSON="$config_json" python3 - "$metadata_file" <<'PY'
import json
import os
import sys

config = json.loads(os.environ.get("CONFIG_JSON", "{}"))
metadata_path = sys.argv[1]

with open(metadata_path, "r", encoding="utf-8") as handle:
    metadata = json.load(handle)

container_cfg = config.get("container", {}) or {}
registry_cfg = container_cfg.get("registry", {}) or {}

registry_type = str(registry_cfg.get("type") or "").strip().lower()
registry_repository = str(registry_cfg.get("repository") or "").strip()

local_image = str(metadata.get("image") or "").strip()
image_tag = str(metadata.get("image_tag") or "").strip()
image_id = str(metadata.get("image_id") or "").strip()

if registry_type != "dockerhub":
    raise SystemExit(
        f"Unsupported registry type for image publication: '{registry_type or 'unset'}'"
    )

if not local_image:
    raise SystemExit(
        "Container metadata is missing the local image reference"
    )

if not image_id:
    raise SystemExit(
        "Container metadata is missing the local Docker image ID"
    )

if not image_tag:
    if ":" not in local_image:
        raise SystemExit(
            "Container metadata is missing image_tag and the local image reference has no tag"
        )

    image_tag = local_image.rsplit(":", 1)[1]

if not registry_repository:
    raise SystemExit(
        "image_publish is enabled but container.registry.repository is missing"
    )

print(local_image)
print(image_tag)
print(registry_repository)
PY
) || {
  log_error "Unable to resolve publication metadata"
  exit "$PLATFORM_EXIT_CONFIG"
}

local_image=$(printf '%s\n' "$publication_values" | sed -n '1p')
image_tag=$(printf '%s\n' "$publication_values" | sed -n '2p')
registry_repository=$(printf '%s\n' "$publication_values" | sed -n '3p')

if [ -z "$local_image" ] || [ -z "$image_tag" ] || [ -z "$registry_repository" ]; then
  log_error "Resolved publication metadata is incomplete"
  exit "$PLATFORM_EXIT_CONFIG"
fi

remote_ref="${registry_repository}:${image_tag}"

log_info "Local image selected for publication: $local_image"
log_info "Registry repository: $registry_repository"
log_info "Temporary publication tag: $remote_ref"
log_info "The tag is used only for registry push; GitOps will deploy by immutable digest"

log_info "Authenticating to Docker Hub"

if ! printf '%s' "$DOCKERHUB_TOKEN" \
  | docker login \
      --username "$DOCKERHUB_USERNAME" \
      --password-stdin >/dev/null
then
  log_error "Docker Hub authentication failed"
  log_error "Verify DOCKERHUB_USERNAME and DOCKERHUB_TOKEN"
  exit "$PLATFORM_EXIT_EXECUTION"
fi

log_info "Docker Hub authentication succeeded"

if ! docker tag "$local_image" "$remote_ref"; then
  log_error "Failed to tag local image for publication"
  log_error "Local image: $local_image"
  log_error "Registry reference: $remote_ref"
  exit "$PLATFORM_EXIT_EXECUTION"
fi

log_info "Publishing image to registry: $remote_ref"

push_output_file=$(mktemp)

if ! docker push "$remote_ref" >"$push_output_file" 2>&1; then
  log_error "Registry push failed for $remote_ref"
  log_error "Docker push output follows:"
  cat "$push_output_file" >&2
  rm -f "$push_output_file"
  exit "$PLATFORM_EXIT_EXECUTION"
fi

log_info "Registry push completed successfully"
log_info "Resolving immutable registry digest"

image_digest=$(
  python3 - "$push_output_file" <<'PY'
import re
import sys

path = sys.argv[1]

with open(path, "r", encoding="utf-8", errors="replace") as handle:
    content = handle.read()

matches = re.findall(
    r"digest:\s*(sha256:[a-fA-F0-9]{64})",
    content,
)

if not matches:
    raise SystemExit(
        "Unable to resolve an immutable registry digest from docker push output"
    )

print(matches[-1])
PY
) || {
  log_error "Image was pushed, but the registry digest could not be resolved"
  log_error "A registry digest is mandatory for signing, attestation, and GitOps deployment"
  cat "$push_output_file" >&2
  rm -f "$push_output_file"
  exit "$PLATFORM_EXIT_EXECUTION"
}

rm -f "$push_output_file"

if [[ ! "$image_digest" =~ ^sha256:[a-fA-F0-9]{64}$ ]]; then
  log_error "Resolved registry digest is invalid: $image_digest"
  exit "$PLATFORM_EXIT_EXECUTION"
fi

log_info "Resolved immutable registry digest: $image_digest"
log_info "Published image identity: ${registry_repository}@${image_digest}"

python3 - \
  "$metadata_file" \
  "$registry_repository" \
  "$image_digest" \
  "$remote_ref" <<'PY'
import json
import sys

metadata_path = sys.argv[1]
repository = sys.argv[2]
digest = sys.argv[3]
published_ref = sys.argv[4]

with open(metadata_path, "r", encoding="utf-8") as handle:
    metadata = json.load(handle)

metadata["published"] = True
metadata["registry_repository"] = repository
metadata["image_digest"] = digest
metadata["published_image"] = published_ref

with open(metadata_path, "w", encoding="utf-8") as handle:
    json.dump(metadata, handle, indent=2)
    handle.write("\n")
PY

log_info "Container metadata updated with immutable registry identity"
log_info "Publication source: platform"
log_info "Deployable image: ${registry_repository}@${image_digest}"
log_info "Image publication completed successfully"

exit "$PLATFORM_EXIT_SUCCESS"