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

# Generic execution context.
# CI adapters may populate these without coupling the provider to GitHub.
: "${SOURCE_REPOSITORY:=}"
: "${SOURCE_COMMIT:=}"
: "${CI_WORKFLOW_REF:=}"
: "${CI_RUN_ID:=}"
: "${BUILDER_ID:=}"

export WORKSPACE
export CONFIG_FILE
export REPORT_DIR
export LOG_LEVEL

export SOURCE_REPOSITORY
export SOURCE_COMMIT
export CI_WORKFLOW_REF
export CI_RUN_ID
export BUILDER_ID

RESULT_BASE="$WORKSPACE/$REPORT_DIR/container"
mkdir -p "$RESULT_BASE"

log_info "Starting Container & Supply-Chain provider"
log_info "Workspace: $WORKSPACE"
log_info "Configuration: $WORKSPACE/$CONFIG_FILE"
log_info "Reports: $RESULT_BASE"

config_json=$(load_merged_config_json "$WORKSPACE" "$CONFIG_FILE") || {
  log_error "Failed to load merged platform configuration"
  exit "$PLATFORM_EXIT_CONFIG"
}

# Run Python inside an if statement so set -e does not prevent exit-code
# classification below.
if python3 - "$config_json" "$WORKSPACE" "$RESULT_BASE" <<'PYTHON'
import json
import os
import re
import subprocess
import sys
import time
from datetime import datetime, timezone


EXIT_SUCCESS = 0
EXIT_CONFIG = 2
EXIT_TOOL_MISSING = 3
EXIT_EXECUTION = 5


def utc_now():
    return datetime.now(timezone.utc)


def write_json(path, value):
    directory = os.path.dirname(path)

    if directory:
        os.makedirs(directory, exist_ok=True)

    with open(path, "w", encoding="utf-8") as handle:
        json.dump(value, handle, indent=2)
        handle.write("\n")


def fail(message, code):
    print(message, file=sys.stderr)
    sys.exit(code)


def executable_exists(name):
    return subprocess.run(
        ["bash", "-lc", f"command -v {name}"],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        check=False,
    ).returncode == 0


config = json.loads(sys.argv[1])
workspace = os.path.abspath(sys.argv[2])
result_base = os.path.abspath(sys.argv[3])

caps = config.get("capabilities", {}) or {}

container_build_enabled = bool(caps.get("container_build", False))
container_scan_enabled = bool(caps.get("container_scan", False))
sbom_enabled = bool(caps.get("sbom", False))
provenance_enabled = bool(caps.get("provenance", False))
image_publish_enabled = bool(caps.get("image_publish", False))
image_signing_enabled = bool(caps.get("image_signing", False))


# ===========================================================================
# Local image requirement
#
# container_build may be explicitly enabled, but dependent supply-chain
# capabilities implicitly require a local image and therefore trigger the
# build even when container_build itself is false.
# ===========================================================================

requires_local_image = any([
    container_build_enabled,
    container_scan_enabled,
    sbom_enabled,
    provenance_enabled,
    image_publish_enabled,
    image_signing_enabled,
])

if not requires_local_image:
    print(
        "No enabled supply-chain capability requires a local image; "
        "skipping Container & Supply-Chain provider"
    )
    sys.exit(EXIT_SUCCESS)


# ===========================================================================
# Configuration
# ===========================================================================

container_cfg = config.get("container", {}) or {}
image_cfg = container_cfg.get("image", {}) or {}

dockerfile = str(
    container_cfg.get("dockerfile") or "./Dockerfile"
).strip()

context = str(
    container_cfg.get("context") or "."
).strip()

image_name = str(
    image_cfg.get("name") or "application"
).strip()

image_tag = str(
    image_cfg.get("tag") or ""
).strip()


if not image_name:
    fail(
        "container.image.name cannot be empty.",
        EXIT_CONFIG,
    )


# Prefer generic source commit supplied by the CI adapter.
# Fall back to a local deterministic-enough build identifier only when
# source context is unavailable.
if not image_tag:
    source_commit = os.environ.get("SOURCE_COMMIT", "").strip()

    if source_commit:
        image_tag = source_commit[:12]
    else:
        image_tag = str(int(time.time()))


full_tag = f"{image_name}:{image_tag}"


# ===========================================================================
# Dockerfile / context resolution
# ===========================================================================

dockerfile_path = os.path.abspath(
    os.path.join(workspace, dockerfile)
)

context_path = os.path.abspath(
    os.path.join(workspace, context)
)


if not os.path.isdir(context_path):
    fail(
        f"Container build context does not exist: {context_path}",
        EXIT_CONFIG,
    )


if not os.path.isfile(dockerfile_path):
    fail(
        f"Dockerfile not found: {dockerfile_path}",
        EXIT_CONFIG,
    )


if not executable_exists("docker"):
    fail(
        "Docker is required by the enabled container capabilities "
        "but was not found in PATH.",
        EXIT_TOOL_MISSING,
    )


# ===========================================================================
# Provider execution state
# ===========================================================================

provider_start = utc_now()


# ===========================================================================
# Build local image
# ===========================================================================

print(
    "Local container image is required by the enabled "
    "supply-chain capabilities"
)

print(f"Building local image: {full_tag}")
print(f"Dockerfile: {dockerfile_path}")
print(f"Build context: {context_path}")


build_start = utc_now()

try:
    subprocess.run(
        [
            "docker",
            "build",
            "-f",
            dockerfile_path,
            "-t",
            full_tag,
            context_path,
        ],
        check=True,
    )
except subprocess.CalledProcessError:
    fail(
        "Image build failed.",
        EXIT_EXECUTION,
    )


build_end = utc_now()


# ===========================================================================
# Resolve immutable LOCAL image identity
#
# This is local Docker build identity only.
#
# It MUST NOT be presented as the deployable registry digest.
# publish.sh resolves the registry digest after a successful push.
# ===========================================================================

try:
    image_id = subprocess.check_output(
        [
            "docker",
            "image",
            "inspect",
            "--format",
            "{{.Id}}",
            full_tag,
        ],
        text=True,
    ).strip()

except subprocess.CalledProcessError:
    fail(
        f"Failed to inspect locally built image: {full_tag}",
        EXIT_EXECUTION,
    )


if not re.fullmatch(r"sha256:[a-fA-F0-9]{64}", image_id):
    fail(
        f"Docker returned an invalid local image ID: {image_id!r}",
        EXIT_EXECUTION,
    )


print(f"Local image built successfully: {full_tag}")
print(f"Local Docker image ID: {image_id}")
print(
    "Local image ID is build evidence only; "
    "a deployable registry digest exists only after publication."
)


# ===========================================================================
# Result directory
# ===========================================================================

result_key = image_id.replace(":", "-")
result_dir = os.path.join(result_base, result_key)

build_dir = os.path.join(result_dir, "build")
scan_dir = os.path.join(result_dir, "scan")
sbom_dir = os.path.join(result_dir, "sbom")
provenance_dir = os.path.join(result_dir, "provenance")

for directory in (
    result_dir,
    build_dir,
    scan_dir,
    sbom_dir,
    provenance_dir,
):
    os.makedirs(directory, exist_ok=True)


# ===========================================================================
# Canonical top-level metadata
# ===========================================================================

metadata = {
    "capability": "container_supply_chain",
    "status": "passed",

    "image": {
        "local_reference": full_tag,
        "tag": image_tag,

        "local_identity": {
            "type": "docker_image_id",
            "digest": image_id,
        },

        # Filled later by publish.sh when image_publish is enabled.
        "registry_identity": None,
    },

    # Retain compatibility with existing downstream scripts.
    "image_tag": image_tag,
    "image_id": image_id,
    "published": False,

    "capabilities": {
        "container_build": {
            "requested": container_build_enabled,
            "executed": True,
            "implicit": not container_build_enabled,
            "status": "passed",
        },
        "container_scan": {
            "requested": container_scan_enabled,
            "status": (
                "pending"
                if container_scan_enabled
                else "skipped"
            ),
        },
        "sbom": {
            "requested": sbom_enabled,
            "status": (
                "pending"
                if sbom_enabled
                else "skipped"
            ),
        },
        "provenance": {
            "requested": provenance_enabled,
            "status": (
                "pending"
                if provenance_enabled
                else "skipped"
            ),
        },
        "image_publish": {
            "requested": image_publish_enabled,
            "status": (
                "pending"
                if image_publish_enabled
                else "skipped"
            ),
        },
        "image_signing": {
            "requested": image_signing_enabled,
            "status": (
                "pending"
                if image_signing_enabled
                else "skipped"
            ),
        },
    },

    "start_time": provider_start.isoformat(),
    "end_time": None,
    "duration_seconds": None,
    "reports": {},
}


# ===========================================================================
# Build metadata
# ===========================================================================

build_metadata = {
    "capability": "container_build",
    "status": "passed",
    "requested": container_build_enabled,
    "implicit": not container_build_enabled,
    "dockerfile": dockerfile,
    "context": context,
    "image": full_tag,
    "image_id": image_id,
    "start_time": build_start.isoformat(),
    "end_time": build_end.isoformat(),
    "duration_seconds": (
        build_end - build_start
    ).total_seconds(),
}


write_json(
    os.path.join(build_dir, "metadata.json"),
    build_metadata,
)


# ===========================================================================
# Trivy vulnerability scan
#
# Findings do NOT cause the provider to fail here.
# Scanner execution failure does.
#
# Policy/Risk Assessment determines the meaning of findings downstream.
# ===========================================================================

if container_scan_enabled:

    if not executable_exists("trivy"):
        fail(
            "container_scan is enabled but Trivy is unavailable.",
            EXIT_TOOL_MISSING,
        )

    scan_start = utc_now()

    trivy_report = os.path.join(
        scan_dir,
        "trivy-report.json",
    )

    print("Running Trivy container vulnerability scan...")

    try:
        subprocess.run(
            [
                "trivy",
                "image",
                "--quiet",
                "--format",
                "json",
                "--exit-code",
                "0",
                "--output",
                trivy_report,
                full_tag,
            ],
            check=True,
        )

    except subprocess.CalledProcessError:
        fail(
            "Trivy execution failed.",
            EXIT_EXECUTION,
        )


    scan_end = utc_now()

    try:
        with open(
            trivy_report,
            "r",
            encoding="utf-8",
        ) as handle:
            trivy_data = json.load(handle)
    except (OSError, json.JSONDecodeError) as exc:
        fail(
            f"Trivy report could not be read: {exc}",
            EXIT_EXECUTION,
        )


    vulnerability_count = 0

    for result in trivy_data.get("Results", []) or []:
        vulnerability_count += len(
            result.get("Vulnerabilities", []) or []
        )


    scan_metadata = {
        "capability": "container_scan",
        "status": "passed",
        "scanner": "trivy",
        "image": full_tag,
        "image_identity": {
            "type": "docker_image_id",
            "digest": image_id,
        },
        "vulnerabilities_detected": vulnerability_count,
        "findings_policy": "downstream",
        "start_time": scan_start.isoformat(),
        "end_time": scan_end.isoformat(),
        "duration_seconds": (
            scan_end - scan_start
        ).total_seconds(),
        "report": trivy_report,
    }


    write_json(
        os.path.join(scan_dir, "metadata.json"),
        scan_metadata,
    )

    metadata["capabilities"]["container_scan"]["status"] = "passed"
    metadata["reports"]["trivy"] = trivy_report


# ===========================================================================
# SBOM
# ===========================================================================

if sbom_enabled:

    if not executable_exists("syft"):
        fail(
            "sbom is enabled but Syft is unavailable.",
            EXIT_TOOL_MISSING,
        )

    sbom_start = utc_now()

    sbom_file = os.path.join(
        sbom_dir,
        "sbom-cyclonedx.json",
    )

    print("Generating CycloneDX SBOM via Syft...")

    try:
        with open(
            sbom_file,
            "w",
            encoding="utf-8",
        ) as output:

            subprocess.run(
                [
                    "syft",
                    full_tag,
                    "-o",
                    "cyclonedx-json",
                ],
                stdout=output,
                check=True,
            )

    except subprocess.CalledProcessError:
        fail(
            "Syft execution failed.",
            EXIT_EXECUTION,
        )


    sbom_end = utc_now()


    sbom_metadata = {
        "capability": "sbom",
        "status": "passed",
        "generator": "syft",
        "format": "CycloneDX JSON",
        "image": full_tag,
        "image_identity": {
            "type": "docker_image_id",
            "digest": image_id,
        },
        "start_time": sbom_start.isoformat(),
        "end_time": sbom_end.isoformat(),
        "duration_seconds": (
            sbom_end - sbom_start
        ).total_seconds(),
        "report": sbom_file,
    }


    write_json(
        os.path.join(sbom_dir, "metadata.json"),
        sbom_metadata,
    )

    metadata["capabilities"]["sbom"]["status"] = "passed"
    metadata["reports"]["sbom"] = sbom_file


# ===========================================================================
# Provenance
#
# This is generated for the LOCAL build artifact.
#
# When the image is later published, publish.sh records the registry digest.
# attest.sh subsequently binds provenance to the published immutable image
# identity using Cosign.
# ===========================================================================

if provenance_enabled:

    provenance_start = utc_now()

    provenance_file = os.path.join(
        provenance_dir,
        "provenance.json",
    )

    print("Generating SLSA provenance evidence...")

    source_repository = os.environ.get(
        "SOURCE_REPOSITORY",
        "",
    )

    source_commit = os.environ.get(
        "SOURCE_COMMIT",
        "",
    )

    workflow_ref = os.environ.get(
        "CI_WORKFLOW_REF",
        "",
    )

    run_id = os.environ.get(
        "CI_RUN_ID",
        "",
    )

    builder_id = os.environ.get(
        "BUILDER_ID",
        "",
    ) or "devsecops-platform-container-provider"


    # Docker image ID is a sha256 digest.
    local_sha256 = image_id.split(":", 1)[1]


    provenance = {
        "_type": (
            "https://in-toto.io/Statement/v1"
        ),

        "subject": [
            {
                "name": full_tag,
                "digest": {
                    "sha256": local_sha256,
                },
            }
        ],

        "predicateType": (
            "https://slsa.dev/provenance/v1"
        ),

        "predicate": {
            "buildDefinition": {
                "buildType": (
                    "https://devsecops-platform/"
                    "container-build/v1"
                ),

                "externalParameters": {
                    "dockerfile": dockerfile,
                    "context": context,
                    "image_name": image_name,
                    "image_tag": image_tag,
                },

                "internalParameters": {},

                "resolvedDependencies": (
                    [
                        {
                            "uri": source_repository,
                            "digest": {
                                "gitCommit": source_commit,
                            },
                        }
                    ]
                    if source_repository or source_commit
                    else []
                ),
            },

            "runDetails": {
                "builder": {
                    "id": builder_id,
                },

                "metadata": {
                    "invocationId": run_id or None,
                    "startedOn": build_start.isoformat(),
                    "finishedOn": build_end.isoformat(),
                },

                "byproducts": (
                    [
                        {
                            "name": "workflow",
                            "content": workflow_ref,
                        }
                    ]
                    if workflow_ref
                    else []
                ),
            },
        },
    }


    write_json(
        provenance_file,
        provenance,
    )


    provenance_end = utc_now()


    provenance_metadata = {
        "capability": "provenance",
        "status": "passed",
        "framework": "SLSA",
        "predicate_type": (
            "https://slsa.dev/provenance/v1"
        ),
        "image": full_tag,
        "image_identity": {
            "type": "docker_image_id",
            "digest": image_id,
        },
        "source_repository": source_repository or None,
        "source_commit": source_commit or None,
        "workflow": workflow_ref or None,
        "start_time": provenance_start.isoformat(),
        "end_time": provenance_end.isoformat(),
        "duration_seconds": (
            provenance_end - provenance_start
        ).total_seconds(),
        "report": provenance_file,
    }


    write_json(
        os.path.join(
            provenance_dir,
            "metadata.json",
        ),
        provenance_metadata,
    )

    metadata["capabilities"]["provenance"]["status"] = "passed"
    metadata["reports"]["provenance"] = provenance_file


# ===========================================================================
# Final metadata
# ===========================================================================

provider_end = utc_now()

metadata["status"] = "passed"
metadata["end_time"] = provider_end.isoformat()
metadata["duration_seconds"] = (
    provider_end - provider_start
).total_seconds()


metadata_file = os.path.join(
    result_dir,
    "metadata.json",
)

write_json(
    metadata_file,
    metadata,
)


print(
    "Container supply-chain evidence generated at",
    result_dir,
)

sys.exit(EXIT_SUCCESS)

PYTHON
then
  EXIT_CODE=0
else
  EXIT_CODE=$?
fi

if [ "$EXIT_CODE" -eq 0 ]; then

  log_info \
    "Container & Supply-Chain provider completed successfully"

elif [ "$EXIT_CODE" -eq "$PLATFORM_EXIT_CONFIG" ]; then

  log_error \
    "Container & Supply-Chain provider failed due to configuration error"

elif [ "$EXIT_CODE" -eq "$PLATFORM_EXIT_TOOL_MISSING" ]; then

  log_error \
    "Container & Supply-Chain provider failed because a required tool is missing"

else

  log_error \
    "Container & Supply-Chain provider failed with exit code $EXIT_CODE"

fi

exit "$EXIT_CODE"