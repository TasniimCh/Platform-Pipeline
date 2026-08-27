#!/usr/bin/env bash
set -euo pipefail

# ---------------------------------------------------------------------------
# Build & Test Provider
#
# Responsibilities:
#   1. Resolve the effective Build & Test configuration.
#   2. Detect and validate the Node.js project.
#   3. Resolve the package manager from configuration/lockfiles.
#   4. Resolve build/test commands.
#   5. Install dependencies exactly once.
#   6. Run independent Build + Unit Test operations in parallel.
#   7. Run Integration Tests after Build + Unit Tests complete successfully.
#   8. Generate machine-readable reports and metadata.
#
# Capability flags control WHETHER a phase runs.
# Build/testing configuration controls HOW the enabled phase runs.
#
# The provider is intentionally independent from GitHub Actions.
# ---------------------------------------------------------------------------

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)
PLATFORM_ROOT=$(cd "$SCRIPT_DIR/.." >/dev/null 2>&1 && pwd)

source "$PLATFORM_ROOT/lib/constants.sh"
source "$PLATFORM_ROOT/lib/logging.sh"
source "$PLATFORM_ROOT/config/config.sh"

# ---------------------------------------------------------------------------
# Environment defaults
# ---------------------------------------------------------------------------

: "${WORKSPACE:=${PWD}}"
: "${CONFIG_FILE:=.devsecops/pipeline.yaml}"
: "${REPORT_DIR:=.devsecops/reports}"
: "${LOG_LEVEL:=info}"

export WORKSPACE
export CONFIG_FILE
export REPORT_DIR
export LOG_LEVEL

# Optional generic CI/source context.
#
# These variables intentionally do not use GitHub-specific names.
# The workflow adapter may populate them when available.
: "${SOURCE_COMMIT:=}"
: "${CI_RUN_ID:=}"
: "${CI_RUN_URL:=}"

export SOURCE_COMMIT
export CI_RUN_ID
export CI_RUN_URL

# ---------------------------------------------------------------------------
# Report directories
# ---------------------------------------------------------------------------

BUILD_DIR="$WORKSPACE/$REPORT_DIR/build"
UNIT_DIR="$WORKSPACE/$REPORT_DIR/tests/unit"
INTEGRATION_DIR="$WORKSPACE/$REPORT_DIR/tests/integration"

mkdir -p \
    "$BUILD_DIR" \
    "$UNIT_DIR" \
    "$INTEGRATION_DIR"

log_info "Starting Build & Test provider"

# ---------------------------------------------------------------------------
# Resolve effective configuration using the platform configuration layer.
# ---------------------------------------------------------------------------

config_json=$(load_merged_config_json "$WORKSPACE" "$CONFIG_FILE")

# ---------------------------------------------------------------------------
# Provider implementation
#
# IMPORTANT:
# Run inside an `if` statement so `set -e` does not terminate the shell before
# we capture and classify the provider exit status.
# ---------------------------------------------------------------------------

if python3 \
    - "$config_json" \
    "$WORKSPACE" \
    "$BUILD_DIR" \
    "$UNIT_DIR" \
    "$INTEGRATION_DIR" \
<<'PY'
import json
import os
import subprocess
import sys
from datetime import datetime, timezone


# ===========================================================================
# Platform exit codes
# ===========================================================================

EXIT_SUCCESS = 0
EXIT_CONFIG = 2
EXIT_TOOL_MISSING = 3
EXIT_EXECUTION = 5


# ===========================================================================
# Helpers
# ===========================================================================

def utc_now():
    """Return a timezone-aware UTC timestamp."""
    return datetime.now(timezone.utc)


def write_json(path, data):
    """Write machine-readable JSON output."""
    directory = os.path.dirname(path)

    if directory:
        os.makedirs(directory, exist_ok=True)

    with open(path, "w", encoding="utf-8") as f:
        json.dump(data, f, indent=2)


def fail(message, exit_code):
    """Print a provider error and terminate with the platform exit code."""
    print(message, file=sys.stderr)
    sys.exit(exit_code)


def normalize_path(workspace, configured_path):
    """Resolve a configured working directory under the workspace."""
    return os.path.abspath(
        os.path.join(workspace, configured_path or ".")
    )


def command_exists(command):
    """Check whether an executable is available in PATH."""
    return subprocess.run(
        [
            "bash",
            "-lc",
            f"command -v {command}",
        ],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=False,
    ).returncode == 0


# ===========================================================================
# Arguments
# ===========================================================================

config = json.loads(sys.argv[1])

workspace = os.path.abspath(sys.argv[2])
build_dir = sys.argv[3]
unit_dir = sys.argv[4]
integration_dir = sys.argv[5]


# ===========================================================================
# Generic source / CI execution context
# ===========================================================================

source_commit = os.environ.get("SOURCE_COMMIT") or None
ci_run_id = os.environ.get("CI_RUN_ID") or None
ci_run_url = os.environ.get("CI_RUN_URL") or None


# ===========================================================================
# Capability resolution
#
# Capabilities are the authoritative enablement mechanism.
#
# Configuration sections describe HOW enabled capabilities execute.
# ===========================================================================

caps = config.get("capabilities", {})

build_enabled = bool(caps.get("build", False))
unit_enabled = bool(caps.get("unit_testing", False))
integration_enabled = bool(caps.get("integration_testing", False))

if not any([
    build_enabled,
    unit_enabled,
    integration_enabled,
]):
    print("Build & Test capabilities disabled; skipping")
    sys.exit(EXIT_SUCCESS)


# ===========================================================================
# Configuration
# ===========================================================================

build_cfg = config.get("build", {})
testing_cfg = config.get("testing", {})

unit_cfg = testing_cfg.get("unit", {})
integration_cfg = testing_cfg.get("integration", {})


# ===========================================================================
# Working-directory resolution
# ===========================================================================

build_working_directory = normalize_path(
    workspace,
    build_cfg.get("working_directory", "."),
)

test_working_directory = normalize_path(
    workspace,
    testing_cfg.get(
        "working_directory",
        build_cfg.get("working_directory", "."),
    ),
)


# Only validate directories used by enabled capabilities.

if build_enabled and not os.path.isdir(build_working_directory):
    fail(
        f"Build working directory not found: "
        f"{build_working_directory}",
        EXIT_CONFIG,
    )


if (
    (unit_enabled or integration_enabled)
    and not os.path.isdir(test_working_directory)
):
    fail(
        f"Test working directory not found: "
        f"{test_working_directory}",
        EXIT_CONFIG,
    )


# ---------------------------------------------------------------------------
# Current Node provider supports one dependency installation for one Node
# project. Therefore, when Build and Tests are enabled together they must
# operate on the same project directory.
#
# Multi-project dependency preparation belongs to a future provider extension.
# ---------------------------------------------------------------------------

if (
    build_enabled
    and (unit_enabled or integration_enabled)
    and build_working_directory != test_working_directory
):
    fail(
        "Build and test working directories differ. "
        "The current Node provider requires enabled Build/Test capabilities "
        "to operate on the same Node project so dependencies can be installed "
        "exactly once.",
        EXIT_CONFIG,
    )


# Select the Node project directory according to enabled capabilities.

if build_enabled:
    project_working_directory = build_working_directory
else:
    project_working_directory = test_working_directory


# ===========================================================================
# Node.js project detection
# ===========================================================================

package_json_path = os.path.join(
    project_working_directory,
    "package.json",
)

if not os.path.isfile(package_json_path):
    fail(
        "Missing package.json in the resolved project working directory; "
        "cannot resolve the Node.js provider.",
        EXIT_CONFIG,
    )


try:
    with open(package_json_path, "r", encoding="utf-8") as f:
        package_data = json.load(f)
except (json.JSONDecodeError, OSError) as exc:
    fail(
        f"Unable to read package.json: {exc}",
        EXIT_CONFIG,
    )


scripts = package_data.get("scripts", {})

if not isinstance(scripts, dict):
    fail(
        "package.json contains an invalid 'scripts' section.",
        EXIT_CONFIG,
    )


# ===========================================================================
# Runtime validation
# ===========================================================================

runtime = build_cfg.get("runtime", {})

language = str(runtime.get("language", "node")).strip().lower()
required_version = str(runtime.get("version", "")).strip()

if language != "node":
    fail(
        f"Unsupported runtime language: {language}. "
        "The current provider supports Node.js.",
        EXIT_CONFIG,
    )


try:
    node_version = subprocess.check_output(
        ["node", "--version"],
        stderr=subprocess.STDOUT,
        text=True,
    ).strip()
except FileNotFoundError:
    fail(
        "Node.js is not available in the execution environment.",
        EXIT_TOOL_MISSING,
    )
except subprocess.CalledProcessError as exc:
    fail(
        f"Unable to determine Node.js version: {exc}",
        EXIT_TOOL_MISSING,
    )


# ---------------------------------------------------------------------------
# MVP runtime-version policy:
#
# version: "22"
#
# means Node.js major version 22.
#
# Full semantic-version constraints are intentionally outside the current
# provider scope.
# ---------------------------------------------------------------------------

if required_version:
    actual_version_without_prefix = node_version.lstrip("v")
    actual_major = actual_version_without_prefix.split(".", 1)[0]

    if actual_major != required_version:
        fail(
            f"Required Node.js major version {required_version} is "
            f"unavailable; found {node_version}.",
            EXIT_CONFIG,
        )


# ===========================================================================
# Package-manager resolution
# ===========================================================================

lockfiles = {
    "npm": "package-lock.json",
    "yarn": "yarn.lock",
    "pnpm": "pnpm-lock.yaml",
}

package_manager = runtime.get("package_manager")

if package_manager is not None:
    package_manager = str(package_manager).strip().lower()


lockfile_matches = []

for manager, filename in lockfiles.items():
    if os.path.isfile(
        os.path.join(project_working_directory, filename)
    ):
        lockfile_matches.append(manager)


# ---------------------------------------------------------------------------
# Resolution:
#
# Explicit configuration
#        >
# Reliable lockfile detection
#
# No package-manager default is assumed when detection is ambiguous or absent.
# ---------------------------------------------------------------------------

if not package_manager:

    if len(lockfile_matches) == 1:
        package_manager = lockfile_matches[0]

    elif len(lockfile_matches) > 1:
        fail(
            "Multiple supported package-manager lockfiles detected: "
            f"{', '.join(lockfile_matches)}. "
            "Specify build.runtime.package_manager explicitly.",
            EXIT_CONFIG,
        )

    else:
        fail(
            "No supported package-manager lockfile found. "
            "Specify build.runtime.package_manager explicitly.",
            EXIT_CONFIG,
        )


if package_manager not in lockfiles:
    fail(
        f"Unsupported package manager: {package_manager}",
        EXIT_CONFIG,
    )


# ===========================================================================
# Dependency installation strategy
# ===========================================================================

if package_manager == "npm":
    install_cmd = "npm ci"

elif package_manager == "yarn":
    install_cmd = "yarn install --immutable"

elif package_manager == "pnpm":
    install_cmd = "pnpm install --frozen-lockfile"

else:
    fail(
        f"Unsupported package manager: {package_manager}",
        EXIT_CONFIG,
    )


if not command_exists(package_manager):
    fail(
        f"Required package-manager executable is not available: "
        f"{package_manager}",
        EXIT_TOOL_MISSING,
    )


# ===========================================================================
# Command resolution
# ===========================================================================

build_explicit = build_cfg.get("command")
unit_explicit = unit_cfg.get("command")
integration_explicit = integration_cfg.get("command")


# ---------------------------------------------------------------------------
# Node provider command resolution:
#
# Build:
#   build.command
#       >
#   package.json scripts.build
#
# Unit:
#   testing.unit.command
#       >
#   package.json scripts.test
#
# Integration:
#   testing.integration.command
#       >
#   package.json scripts.integration
#
# scripts.integration is the deterministic integration-test convention
# supported by the current Node provider.
#
# The provider does not invent application-specific commands.
# ---------------------------------------------------------------------------

build_script = "build" if "build" in scripts else None
unit_script = "test" if "test" in scripts else None
integration_script = (
    "integration"
    if "integration" in scripts
    else None
)


def resolve_command(explicit, script_name, package_manager):
    """Resolve explicit command first, then deterministic Node script."""

    if explicit:
        return str(explicit).strip()

    if not script_name:
        return None

    if package_manager == "npm":
        return f"npm run {script_name}"

    if package_manager == "yarn":
        return f"yarn {script_name}"

    if package_manager == "pnpm":
        return f"pnpm run {script_name}"

    raise RuntimeError(
        f"Unsupported package manager: {package_manager}"
    )


build_command = resolve_command(
    build_explicit,
    build_script,
    package_manager,
)

unit_command = resolve_command(
    unit_explicit,
    unit_script,
    package_manager,
)

integration_command = resolve_command(
    integration_explicit,
    integration_script,
    package_manager,
)


# ===========================================================================
# Validate requested capabilities
#
# Resolution happens before provider execution.
# ===========================================================================

if build_enabled and not build_command:
    fail(
        "Build capability is enabled but no build command could be "
        "resolved. Specify build.command or define scripts.build "
        "in package.json.",
        EXIT_CONFIG,
    )


if unit_enabled and not unit_command:
    fail(
        "Unit testing capability is enabled but no unit-test command "
        "could be resolved. Specify testing.unit.command or define "
        "scripts.test in package.json.",
        EXIT_CONFIG,
    )


if integration_enabled and not integration_command:
    fail(
        "Integration testing capability is enabled but no integration-test "
        "command could be resolved. Specify testing.integration.command "
        "or define scripts.integration in package.json.",
        EXIT_CONFIG,
    )


# ===========================================================================
# Suite definitions
# ===========================================================================

commands = []

if build_enabled:
    commands.append(
        (
            "build",
            "build",
            build_command,
            build_working_directory,
            build_dir,
        )
    )


if unit_enabled:
    commands.append(
        (
            "unit_testing",
            "unit",
            unit_command,
            test_working_directory,
            unit_dir,
        )
    )


if integration_enabled:
    commands.append(
        (
            "integration_testing",
            "integration",
            integration_command,
            test_working_directory,
            integration_dir,
        )
    )


# ===========================================================================
# Execution state
# ===========================================================================

provider_start = utc_now()
results = []


# ===========================================================================
# Metadata helpers
# ===========================================================================

def base_context():
    return {
        "technology": language,
        "runtime": required_version or None,
        "runtime_actual": node_version,
        "package_manager": package_manager,
        "commit": source_commit,
        "workflow_run": {
            "id": ci_run_id,
            "url": ci_run_url,
        },
    }


def write_skipped_test_metadata(
    capability,
    suite,
    output_dir,
    command,
    working_directory,
    reason,
):
    metadata = {
        "capability": capability,
        "suite": suite,
        "status": "skipped",
        "reason": reason,
        "framework": None,
        "command": command,
        "working_directory": os.path.relpath(
            working_directory,
            workspace,
        ),
        "total_tests": None,
        "passed": None,
        "failed": None,
        "skipped": None,
        "start_time": None,
        "end_time": None,
        "duration_seconds": None,
        **base_context(),
    }

    write_json(
        os.path.join(output_dir, "metadata.json"),
        metadata,
    )

    write_json(
        os.path.join(output_dir, "report.json"),
        {
            "capability": capability,
            "suite": suite,
            "status": "skipped",
            "reason": reason,
        },
    )

    return metadata


# ===========================================================================
# Write disabled-capability evidence
# ===========================================================================

if not unit_enabled:
    write_skipped_test_metadata(
        "unit_testing",
        "unit",
        unit_dir,
        None,
        test_working_directory,
        "capability_disabled",
    )


if not integration_enabled:
    write_skipped_test_metadata(
        "integration_testing",
        "integration",
        integration_dir,
        None,
        test_working_directory,
        "capability_disabled",
    )


# ===========================================================================
# Phase 1 — Install dependencies ONCE
# ===========================================================================

print(
    f"Installing dependencies with {package_manager}",
    file=sys.stdout,
)

try:
    subprocess.run(
        [
            "bash",
            "-lc",
            f'cd "{project_working_directory}" && {install_cmd}',
        ],
        check=True,
        stdout=sys.stdout,
        stderr=sys.stderr,
    )

except subprocess.CalledProcessError:
    fail(
        "Dependency installation failed.",
        EXIT_EXECUTION,
    )


# ===========================================================================
# Suite execution helpers
# ===========================================================================

def start_suite(
    capability,
    suite,
    command,
    working_directory,
    output_dir,
):
    """Start an enabled operation without waiting."""

    print(
        f"Executing {suite} command: {command}",
        file=sys.stdout,
    )

    suite_start = utc_now()

    process = subprocess.Popen(
        [
            "bash",
            "-lc",
            f'cd "{working_directory}" && {command}',
        ],
        stdout=sys.stdout,
        stderr=sys.stderr,
    )

    return {
        "capability": capability,
        "suite": suite,
        "command": command,
        "working_directory": working_directory,
        "output_dir": output_dir,
        "process": process,
        "start_time": suite_start,
    }


def collect_suite_result(job):
    """Collect execution result and produce canonical metadata."""

    capability = job["capability"]
    suite = job["suite"]
    command = job["command"]
    working_directory = job["working_directory"]
    output_dir = job["output_dir"]
    process = job["process"]
    suite_start = job["start_time"]

    exit_code = process.wait()

    suite_end = utc_now()

    status = "passed" if exit_code == 0 else "failed"

    duration = (
        suite_end - suite_start
    ).total_seconds()

    metadata = {
        "capability": capability,
        "status": status,
        "command": command,
        "working_directory": os.path.relpath(
            working_directory,
            workspace,
        ),
        "start_time": suite_start.isoformat(),
        "end_time": suite_end.isoformat(),
        "duration_seconds": duration,
        **base_context(),
    }

    if suite != "build":
        metadata.update({
            "suite": suite,

            # No framework-specific report parser exists yet.
            "framework": None,

            # Generic command execution cannot determine reliable counts.
            "total_tests": None,
            "passed": None,
            "failed": None,
            "skipped": None,
        })

    write_json(
        os.path.join(output_dir, "report.json"),
        {
            "capability": capability,
            "suite": suite,
            "status": status,
            "command": command,
            "exit_code": exit_code,
            "start_time": suite_start.isoformat(),
            "end_time": suite_end.isoformat(),
            "duration_seconds": duration,
        },
    )

    write_json(
        os.path.join(output_dir, "metadata.json"),
        metadata,
    )

    return metadata


# ===========================================================================
# Phase 2 — Build + Unit Tests in parallel
# ===========================================================================

parallel_jobs = []

for (
    capability,
    suite,
    command,
    working_directory,
    output_dir,
) in commands:

    if suite in ("build", "unit"):

        parallel_jobs.append(
            start_suite(
                capability,
                suite,
                command,
                working_directory,
                output_dir,
            )
        )


# Both processes are started before either process is awaited.

for job in parallel_jobs:
    result = collect_suite_result(job)
    results.append(result)


parallel_failed = any(
    result["status"] == "failed"
    for result in results
)


# ===========================================================================
# Phase 3 — Integration Tests
# ===========================================================================

integration_job = next(
    (
        item
        for item in commands
        if item[1] == "integration"
    ),
    None,
)


if integration_job:

    (
        capability,
        suite,
        command,
        working_directory,
        output_dir,
    ) = integration_job

    if parallel_failed:

        result = write_skipped_test_metadata(
            capability,
            suite,
            output_dir,
            command,
            working_directory,
            "upstream_failure",
        )

        results.append(result)

    else:

        job = start_suite(
            capability,
            suite,
            command,
            working_directory,
            output_dir,
        )

        result = collect_suite_result(job)

        results.append(result)


# ===========================================================================
# Build skipped metadata
# ===========================================================================

if not build_enabled:

    build_metadata = {
        "capability": "build",
        "status": "skipped",
        "reason": "capability_disabled",
        "technology": language,
        "runtime": required_version or None,
        "runtime_actual": node_version,
        "package_manager": package_manager,
        "working_directory": build_cfg.get(
            "working_directory",
            ".",
        ),
        "command": None,
        "commit": source_commit,
        "workflow_run": {
            "id": ci_run_id,
            "url": ci_run_url,
        },
        "start_time": None,
        "end_time": None,
        "duration_seconds": None,
        "artifacts": [],
    }

    write_json(
        os.path.join(build_dir, "metadata.json"),
        build_metadata,
    )

    write_json(
        os.path.join(build_dir, "report.json"),
        {
            "capability": "build",
            "suite": "build",
            "status": "skipped",
            "reason": "capability_disabled",
        },
    )


# ===========================================================================
# Final provider status
#
# Only actual failures make the provider fail.
# Disabled/skipped capabilities do not.
# ===========================================================================

failed_results = [
    result
    for result in results
    if result.get("status") == "failed"
]

provider_end = utc_now()

print(
    "Build & Test provider duration: "
    f"{(provider_end - provider_start).total_seconds():.3f}s"
)


if failed_results:
    sys.exit(EXIT_EXECUTION)

sys.exit(EXIT_SUCCESS)

PY
then
    EXIT_CODE=0
else
    EXIT_CODE=$?
fi


# ---------------------------------------------------------------------------
# Shell-level result handling
# ---------------------------------------------------------------------------

if [ "$EXIT_CODE" -eq 0 ]; then

    log_info "Build & Test provider completed successfully"

elif [ "$EXIT_CODE" -eq "$PLATFORM_EXIT_CONFIG" ]; then

    log_error \
        "Build & Test provider failed due to configuration error"

elif [ "$EXIT_CODE" -eq "$PLATFORM_EXIT_TOOL_MISSING" ]; then

    log_error \
        "Build & Test provider failed because a required runtime/tool is missing"

else

    log_error \
        "Build & Test provider failed with exit code $EXIT_CODE"

fi

exit "$EXIT_CODE"