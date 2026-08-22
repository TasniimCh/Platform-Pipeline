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

export WORKSPACE CONFIG_FILE REPORT_DIR LOG_LEVEL

RESULT_BASE="$WORKSPACE/$REPORT_DIR/container"
mkdir -p "$RESULT_BASE"

log_info "Starting image publication provider"

config_json=$(load_merged_config_json "$WORKSPACE" "$CONFIG_FILE")

CONFIG_JSON="$config_json" python3 - "$WORKSPACE" "$RESULT_BASE" <<'PY'
import json
import os
import subprocess
import sys
from datetime import datetime, timezone
from pathlib import Path


config = json.loads(os.environ["CONFIG_JSON"])
workspace = Path(sys.argv[1])
result_base = Path(sys.argv[2])

caps = config.get("capabilities", {}) or {}

if not caps.get("image_publish", False):
    print("image_publish disabled; skipping")
    sys.exit(0)


container_cfg = config.get("container", {}) or {}
registry_cfg = container_cfg.get("registry", {}) or {}
image_cfg = container_cfg.get("image", {}) or {}

registry_type = (registry_cfg.get("type") or "").lower()
registry_repository = (registry_cfg.get("repository") or "").strip()

image_name = image_cfg.get("name", "application")
image_tag = image_cfg.get("tag")

if not image_tag:
    image_tag = os.environ.get("GITHUB_SHA", "")[:7]

if not image_tag:
    image_tag = "latest"


def required_env(name):
    value = os.environ.get(name, "").strip()

    if not value:
        raise RuntimeError(
            f"{name} is required because image_publish is enabled"
        )

    return value


if registry_type == "dockerhub":
    username = required_env("DOCKERHUB_USERNAME")
    token = required_env("DOCKERHUB_TOKEN")

    if not registry_repository:
        registry_repository = image_name

    # Docker Hub repositories are normally:
    # username/repository
    if "/" not in registry_repository:
        registry_repository = f"{username}/{registry_repository}"

    remote_ref = f"{registry_repository}:{image_tag}"

elif registry_type == "ghcr":
    token = required_env("GHCR_TOKEN")
    username = os.environ.get("GHCR_USERNAME", "").strip()

    if not username:
        username = os.environ.get("GITHUB_ACTOR", "").strip()

    if not username:
        raise RuntimeError(
            "GHCR_USERNAME or GITHUB_ACTOR is required for GHCR publication"
        )

    if not registry_repository:
        registry_repository = (
            f"ghcr.io/{os.environ.get('GITHUB_REPOSITORY', '')}"
        )

    remote_ref = f"{registry_repository}:{image_tag}"

else:
    raise RuntimeError(
        f"Unsupported registry type: {registry_type or 'undefined'}"
    )


# Find the image built by container/run.sh
local_ref = f"{image_name}:{image_tag}"

print(f"Local image:  {local_ref}")
print(f"Remote image: {remote_ref}")


# Verify local image exists
try:
    subprocess.run(
        ["docker", "image", "inspect", local_ref],
        check=True,
        stdout=subprocess.DEVNULL,
    )
except subprocess.CalledProcessError:
    raise RuntimeError(
        f"Local image '{local_ref}' does not exist. "
        "container/run.sh must run before publish.sh."
    )


# Registry login
if registry_type == "dockerhub":

    subprocess.run(
        [
            "docker",
            "login",
            "--username",
            username,
            "--password-stdin",
        ],
        input=token,
        text=True,
        check=True,
    )

elif registry_type == "ghcr":

    subprocess.run(
        [
            "docker",
            "login",
            "ghcr.io",
            "--username",
            username,
            "--password-stdin",
        ],
        input=token,
        text=True,
        check=True,
    )


# Tag
subprocess.run(
    ["docker", "tag", local_ref, remote_ref],
    check=True,
)


# Push
print(f"Pushing {remote_ref}")

push = subprocess.run(
    ["docker", "push", remote_ref],
    check=True,
    capture_output=True,
    text=True,
)

push_output = push.stdout + push.stderr

print(push_output)


# Resolve digest from registry
inspect = subprocess.run(
    [
        "docker",
        "buildx",
        "imagetools",
        "inspect",
        remote_ref,
        "--format",
        "{{.Manifest.Digest}}",
    ],
    check=True,
    capture_output=True,
    text=True,
)

image_digest = inspect.stdout.strip()

if not image_digest.startswith("sha256:"):
    raise RuntimeError(
        f"Unable to resolve immutable registry digest for {remote_ref}"
    )


timestamp = datetime.now(timezone.utc).isoformat()

metadata = {
    "capability": "image_publish",
    "status": "success",
    "registry": registry_type,
    "registry_repository": registry_repository,
    "image": remote_ref,
    "image_tag": image_tag,
    "image_digest": image_digest,
    "published_at": timestamp,
}


result_dir = result_base / "publication"
result_dir.mkdir(parents=True, exist_ok=True)

with open(result_dir / "publication.json", "w", encoding="utf-8") as f:
    json.dump(metadata, f, indent=2)

print(f"Published image: {remote_ref}")
print(f"Immutable digest: {image_digest}")
print(f"Publication evidence: {result_dir}")

PY