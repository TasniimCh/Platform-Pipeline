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

config_json=$(load_merged_config_json "$WORKSPACE" "$CONFIG_FILE") || {
  log_error "Failed to load merged platform configuration"
  exit "$PLATFORM_EXIT_CONFIG"
}

publish_enabled=$(
  CONFIG_JSON="$config_json" python3 - <<'PY'
import json
import os

config = json.loads(
    os.environ.get("CONFIG_JSON", "{}")
)

caps = config.get("capabilities", {}) or {}

print(
    "true"
    if caps.get("image_publish", False)
    else "false"
)
PY
)

if [ "$publish_enabled" != "true" ]; then
  log_info \
    "Image publication capability is disabled; skipping registry publication"

  exit "$PLATFORM_EXIT_SUCCESS"
fi


# Docker and credentials are required only after publication has been confirmed
# as enabled.

if ! command -v docker >/dev/null 2>&1; then
  log_error \
    "Docker is required for image publication but was not found in PATH"

  exit "$PLATFORM_EXIT_TOOL_MISSING"
fi


if [ -z "${DOCKERHUB_USERNAME// }" ]; then
  log_error \
    "Image publication is enabled but DOCKERHUB_USERNAME is missing"

  exit "$PLATFORM_EXIT_CONFIG"
fi


if [ -z "${DOCKERHUB_TOKEN// }" ]; then
  log_error \
    "Image publication is enabled but DOCKERHUB_TOKEN is missing"

  exit "$PLATFORM_EXIT_CONFIG"
fi


if [ ! -d "$RESULT_BASE" ]; then
  log_error \
    "Container report directory does not exist: $RESULT_BASE"

  log_error \
    "Image publication requires a local image produced by container/run.sh"

  exit "$PLATFORM_EXIT_EXECUTION"
fi


metadata_file=$(
  find "$RESULT_BASE" \
    -mindepth 2 \
    -maxdepth 2 \
    -type f \
    -name metadata.json \
    -printf '%T@ %p\n' 2>/dev/null \
    | sort -n \
    | tail -n 1 \
    | cut -d' ' -f2-
)


if [ -z "$metadata_file" ]; then
  log_error \
    "No container metadata.json was found under $RESULT_BASE"

  exit "$PLATFORM_EXIT_EXECUTION"
fi


log_info "Using container metadata: $metadata_file"


publication_values=$(
  CONFIG_JSON="$config_json" \
  python3 - "$metadata_file" <<'PY'

import json
import os
import sys

config = json.loads(
    os.environ.get("CONFIG_JSON", "{}")
)

metadata_path = sys.argv[1]

with open(
    metadata_path,
    "r",
    encoding="utf-8",
) as handle:
    metadata = json.load(handle)


container_cfg = config.get("container", {}) or {}
registry_cfg = container_cfg.get("registry", {}) or {}

registry_type = str(
    registry_cfg.get("type") or ""
).strip().lower()

registry_repository = str(
    registry_cfg.get("repository") or ""
).strip()


image = metadata.get("image")

if isinstance(image, dict):
    local_image = str(
        image.get("local_reference") or ""
    ).strip()
else:
    # Backward compatibility with older container metadata.
    local_image = str(
        metadata.get("image") or ""
    ).strip()


image_tag = str(
    metadata.get("image_tag") or ""
).strip()

image_id = str(
    metadata.get("image_id") or ""
).strip()


if registry_type != "dockerhub":
    raise SystemExit(
        "Unsupported registry type for image publication: "
        f"'{registry_type or 'unset'}'"
    )


if not registry_repository:
    raise SystemExit(
        "image_publish is enabled but "
        "container.registry.repository is missing"
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
            "Container metadata is missing image_tag"
        )

    image_tag = local_image.rsplit(":", 1)[1]


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


remote_ref="${registry_repository}:${image_tag}"


log_info "Local image selected for publication: $local_image"
log_info "Registry repository: $registry_repository"
log_info "Publication tag: $remote_ref"
log_info \
  "The mutable tag is publication transport only; deployment uses the immutable digest"


log_info "Authenticating to Docker Hub"


if ! printf '%s' "$DOCKERHUB_TOKEN" \
  | docker login \
      --username "$DOCKERHUB_USERNAME" \
      --password-stdin >/dev/null
then
  log_error "Docker Hub authentication failed"
  exit "$PLATFORM_EXIT_EXECUTION"
fi


log_info "Docker Hub authentication succeeded"


if ! docker tag \
    "$local_image" \
    "$remote_ref"
then
  log_error \
    "Failed to tag local image for publication"

  exit "$PLATFORM_EXIT_EXECUTION"
fi


log_info "Publishing image: $remote_ref"


push_output_file=$(mktemp)

cleanup() {
  rm -f "$push_output_file"
}

trap cleanup EXIT


if ! docker push \
    "$remote_ref" \
    >"$push_output_file" 2>&1
then
  log_error \
    "Registry push failed for $remote_ref"

  cat "$push_output_file" >&2

  exit "$PLATFORM_EXIT_EXECUTION"
fi


log_info "Registry push completed successfully"


# Resolve the remote digest.
#
# First use Docker's RepoDigests metadata after push.
# Fall back to docker push output only when RepoDigests is unavailable.

image_digest=$(
  docker image inspect \
    "$remote_ref" \
    --format '{{range .RepoDigests}}{{println .}}{{end}}' \
    2>/dev/null \
  | python3 - "$registry_repository" <<'PY'

import re
import sys

repository = sys.argv[1]

for line in sys.stdin:
    line = line.strip()

    match = re.fullmatch(
        re.escape(repository)
        + r"@(sha256:[a-fA-F0-9]{64})",
        line,
    )

    if match:
        print(match.group(1))
        raise SystemExit(0)

raise SystemExit(1)

PY
) || true


if [ -z "$image_digest" ]; then

  image_digest=$(
    python3 - "$push_output_file" <<'PY'

import re
import sys

with open(
    sys.argv[1],
    "r",
    encoding="utf-8",
    errors="replace",
) as handle:
    content = handle.read()

matches = re.findall(
    r"digest:\s*(sha256:[a-fA-F0-9]{64})",
    content,
)

if not matches:
    raise SystemExit(1)

print(matches[-1])

PY
  ) || true

fi


if [[ ! "$image_digest" =~ ^sha256:[a-fA-F0-9]{64}$ ]]; then

  log_error \
    "Image was pushed, but an immutable registry digest could not be resolved"

  cat "$push_output_file" >&2

  exit "$PLATFORM_EXIT_EXECUTION"
fi


published_identity="${registry_repository}@${image_digest}"

log_info \
  "Resolved immutable registry digest: $image_digest"

log_info \
  "Published image identity: $published_identity"


python3 - \
  "$metadata_file" \
  "$registry_repository" \
  "$image_digest" \
  "$remote_ref" <<'PY'

import json
import os
import sys
from datetime import datetime, timezone

metadata_path = sys.argv[1]
repository = sys.argv[2]
digest = sys.argv[3]
published_ref = sys.argv[4]


with open(
    metadata_path,
    "r",
    encoding="utf-8",
) as handle:
    metadata = json.load(handle)


metadata["published"] = True
metadata["registry_repository"] = repository
metadata["image_digest"] = digest
metadata["published_image"] = published_ref


image = metadata.get("image")

if isinstance(image, dict):
    image["registry_identity"] = {
        "type": "oci_registry_digest",
        "repository": repository,
        "digest": digest,
        "reference": f"{repository}@{digest}",
    }


capabilities = metadata.setdefault(
    "capabilities",
    {},
)

publication = capabilities.setdefault(
    "image_publish",
    {},
)

publication["requested"] = True
publication["status"] = "passed"


publication_dir = os.path.join(
    os.path.dirname(metadata_path),
    "publication",
)

os.makedirs(
    publication_dir,
    exist_ok=True,
)


publication_metadata = {
    "capability": "image_publish",
    "status": "passed",
    "registry": "dockerhub",
    "repository": repository,
    "published_tag": published_ref,
    "digest": digest,
    "immutable_reference": (
        f"{repository}@{digest}"
    ),
    "timestamp": (
        datetime.now(timezone.utc).isoformat()
    ),
}


with open(
    os.path.join(
        publication_dir,
        "metadata.json",
    ),
    "w",
    encoding="utf-8",
) as handle:

    json.dump(
        publication_metadata,
        handle,
        indent=2,
    )

    handle.write("\n")


with open(
    metadata_path,
    "w",
    encoding="utf-8",
) as handle:

    json.dump(
        metadata,
        handle,
        indent=2,
    )

    handle.write("\n")

PY


log_info \
  "Container metadata updated with immutable registry identity"

log_info \
  "Deployable image: ${registry_repository}@${image_digest}"

log_info \
  "Image publication completed successfully"

exit "$PLATFORM_EXIT_SUCCESS"