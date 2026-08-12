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
# ---------------------------------------------------------------------------

python3 \
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


# ===========================================================================
# Arguments
# ===========================================================================

config = json.loads(sys.argv[1])

workspace = sys.argv[2]
build_dir = sys.argv[3]
unit_dir = sys.argv[4]
integration_dir = sys.argv[5]


# ===========================================================================
# Capability resolution
# ===========================================================================

caps = config.get("capabilities", {})

build_enabled = bool(caps.get("build", False))
unit_enabled = bool(caps.get("unit_testing", False))
integration_enabled = bool(caps.get("integration_testing", False))

# If the entire feature is disabled, nothing needs to be executed.
if not any([
    build_enabled,
    unit_enabled,
    integration_enabled,
]):
    print("Build & Test capabilities disabled; skipping")
    sys.exit(0)


# ===========================================================================
# Configuration
# ===========================================================================

build_cfg = config.get("build", {})
testing_cfg = config.get("testing", {})

unit_cfg = testing_cfg.get("unit", {})
integration_cfg = testing_cfg.get("integration", {})


# ---------------------------------------------------------------------------
# Working directories
#
# Build has its own working directory.
# Tests may explicitly override it through testing.working_directory.
#
# If no test working directory is specified, the build working directory
# is used. This keeps the default behavior simple for a single Node project.
# ---------------------------------------------------------------------------

build_working_directory = os.path.join(
    workspace,
    build_cfg.get("working_directory", ".")
)

test_working_directory = os.path.join(
    workspace,
    testing_cfg.get(
        "working_directory",
        build_cfg.get("working_directory", ".")
    )
)


if not os.path.isdir(build_working_directory):
    fail(
        f"Build working directory not found: "
        f"{build_working_directory}",
        2,
    )


if not os.path.isdir(test_working_directory):
    fail(
        f"Test working directory not found: "
        f"{test_working_directory}",
        2,
    )


# ===========================================================================
# Node.js project detection
# ===========================================================================

# MEAN/Node.js is the initial supported provider.
#
# package.json is therefore the primary project marker.
package_json_path = os.path.join(
    build_working_directory,
    "package.json",
)

if not os.path.isfile(package_json_path):
    fail(
        "Missing package.json in the build working directory; "
        "cannot resolve the Node.js project.",
        2,
    )


try:
    with open(package_json_path, "r", encoding="utf-8") as f:
        package_data = json.load(f)
except (json.JSONDecodeError, OSError) as exc:
    fail(
        f"Unable to read package.json: {exc}",
        2,
    )


scripts = package_data.get("scripts", {})

if not isinstance(scripts, dict):
    fail(
        "package.json contains an invalid 'scripts' section.",
        2,
    )


# ===========================================================================
# Runtime validation
# ===========================================================================

runtime = build_cfg.get("runtime", {})

language = runtime.get("language", "node")
required_version = str(runtime.get("version", "")).strip()

if language != "node":
    fail(
        f"Unsupported runtime language: {language}. "
        "The current provider supports Node.js.",
        2,
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
        3,
    )


# ---------------------------------------------------------------------------
# Current MVP version policy:
#
#   version: "22"
#
# means Node.js major version 22.
#
# The provider intentionally does not implement a full semver constraint
# engine yet.
# ---------------------------------------------------------------------------

if required_version:
    actual_version_without_prefix = node_version.lstrip("v")
    actual_major = actual_version_without_prefix.split(".", 1)[0]

    if actual_major != required_version:
        fail(
            f"Required Node.js major version {required_version} is "
            f"unavailable; found {node_version}.",
            2,
        )


# ===========================================================================
# Package manager resolution
# ===========================================================================

lockfiles = {
    "npm": "package-lock.json",
    "yarn": "yarn.lock",
    "pnpm": "pnpm-lock.yaml",
}

package_manager = runtime.get("package_manager")

# Detect supported lockfiles.
lockfile_matches = []

for manager, filename in lockfiles.items():
    if os.path.isfile(
        os.path.join(build_working_directory, filename)
    ):
        lockfile_matches.append(manager)


# ---------------------------------------------------------------------------
# Resolution rule:
#
# Explicit configuration
#        >
# Reliable lockfile detection
#        >
# Platform default
#
# There is intentionally no generic fallback when no lockfile exists.
# Reproducible dependency installation requires an explicit package manager
# or a supported lockfile.
# ---------------------------------------------------------------------------

if not package_manager:

    if len(lockfile_matches) == 1:
        package_manager = lockfile_matches[0]

    elif len(lockfile_matches) > 1:
        fail(
            "Multiple supported package-manager lockfiles detected: "
            f"{', '.join(lockfile_matches)}. "
            "Specify build.runtime.package_manager explicitly.",
            2,
        )

    else:
        fail(
            "No supported package-manager lockfile found. "
            "Specify build.runtime.package_manager explicitly.",
            2,
        )


if package_manager not in lockfiles:
    fail(
        f"Unsupported package manager: {package_manager}",
        2,
    )


# ===========================================================================
# Dependency installation strategy
# ===========================================================================

# Reproducible installation commands.
#
# npm:
#   package-lock.json -> npm ci
#
# yarn:
#   yarn.lock -> yarn install --immutable
#
# pnpm:
#   pnpm-lock.yaml -> pnpm install --frozen-lockfile
#
# IMPORTANT:
# Dependencies are installed ONCE and reused by all subsequent commands.
# ---------------------------------------------------------------------------

if package_manager == "npm":
    install_cmd = "npm ci"

elif package_manager == "yarn":
    install_cmd = "yarn install --immutable"

elif package_manager == "pnpm":
    install_cmd = "pnpm install --frozen-lockfile"

else:
    fail(
        f"Unsupported package manager: {package_manager}",
        2,
    )


# Verify that the selected package-manager executable exists.
if subprocess.run(
    [
        "bash",
        "-lc",
        f"command -v {package_manager}",
    ],
    stdout=subprocess.PIPE,
    stderr=subprocess.PIPE,
    check=False,
).returncode != 0:

    fail(
        f"Required package-manager executable is not available: "
        f"{package_manager}",
        3,
    )


# ===========================================================================
# Command resolution
# ===========================================================================

build_explicit = build_cfg.get("command")
unit_explicit = unit_cfg.get("command")
integration_explicit = integration_cfg.get("command")


# ---------------------------------------------------------------------------
# Node.js project conventions:
#
# Build:
#   explicit build.command
#       >
#   package.json scripts.build
#
# Unit:
#   explicit testing.unit.command
#       >
#   package.json scripts.test
#
# Integration:
#   explicit testing.integration.command
#       >
#   package.json scripts.integration
#
# The platform does NOT invent commands such as:
#
#   ng build
#   ng test
#   npm test
#   npx playwright test
#
# unless they are explicitly provided by the client or represented by the
# project's package.json scripts.
# ---------------------------------------------------------------------------

build_script = "build" if "build" in scripts else None
unit_script = "test" if "test" in scripts else None
integration_script = (
    "integration"
    if "integration" in scripts
    else None
)


def resolve_command(explicit, script_name, package_manager):
    """
    Resolve a client command.

    Explicit command always wins.

    Otherwise, invoke the package.json script using the detected package
    manager.
    """

    if explicit:
        return explicit

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
# ===========================================================================

if build_enabled and not build_command:
    fail(
        "Build capability is enabled but no build command could be "
        "resolved. Specify build.command or define scripts.build "
        "in package.json.",
        2,
    )


if unit_enabled and not unit_command:
    fail(
        "Unit testing capability is enabled but no unit-test command "
        "could be resolved. Specify testing.unit.command or define "
        "scripts.test in package.json.",
        2,
    )


if integration_enabled and not integration_command:
    fail(
        "Integration testing capability is enabled but no integration "
        "test command could be resolved. Specify "
        "testing.integration.command or define scripts.integration "
        "in package.json.",
        2,
    )


# ===========================================================================
# Suite definitions
# ===========================================================================

commands = []

if build_enabled:
    commands.append(
        (
            "build",
            build_command,
            build_working_directory,
            build_dir,
        )
    )


if unit_enabled:
    commands.append(
        (
            "unit",
            unit_command,
            test_working_directory,
            unit_dir,
        )
    )


if integration_enabled:
    commands.append(
        (
            "integration",
            integration_command,
            test_working_directory,
            integration_dir,
        )
    )


# ===========================================================================
# Execution state
# ===========================================================================

start_time = utc_now()

results = []


# ===========================================================================
# Phase 1 — Install dependencies ONCE
# ===========================================================================

if commands:

    print(
        f"Installing dependencies with {package_manager}",
        file=sys.stdout,
    )

    try:
        subprocess.run(
            [
                "bash",
                "-lc",
                f'cd "{build_working_directory}" && {install_cmd}',
            ],
            check=True,
            stdout=sys.stdout,
            stderr=sys.stderr,
        )

    except subprocess.CalledProcessError:
        fail(
            "Dependency installation failed.",
            5,
        )


# ===========================================================================
# Suite execution helpers
# ===========================================================================

def start_suite(suite, command, working_directory, output_dir):
    """
    Start a suite without waiting.

    This is used to run independent Build and Unit Test operations
    concurrently.
    """

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
        "suite": suite,
        "command": command,
        "working_directory": working_directory,
        "output_dir": output_dir,
        "process": process,
        "start_time": suite_start,
    }


def collect_suite_result(job):
    """
    Wait for a previously started suite and generate its machine-readable
    result and metadata.

    Exit code is the authoritative generic execution result.

    Framework-specific test counts remain null unless a dedicated parser
    is implemented.
    """

    suite = job["suite"]
    command = job["command"]
    working_directory = job["working_directory"]
    output_dir = job["output_dir"]
    process = job["process"]
    suite_start = job["start_time"]

    exit_code = process.wait()

    status = "passed" if exit_code == 0 else "failed"

    duration = (
        utc_now() - suite_start
    ).total_seconds()

    suite_metadata = {
        "capability": suite,
        "status": status,
        "command": command,
        "working_directory": working_directory,
        "framework": "node_scripts",

        # Generic command execution does not provide reliable test counts.
        # A future provider/report parser can populate these fields.
        "total_tests": None,
        "passed": None,
        "failed": None,
        "skipped": None,

        "duration_seconds": duration,
    }

    # Generic execution report.
    write_json(
        os.path.join(output_dir, "report.json"),
        {
            "suite": suite,
            "status": status,
            "command": command,
            "exit_code": exit_code,
            "duration_seconds": duration,
        },
    )

    # Standardized platform metadata.
    write_json(
        os.path.join(output_dir, "metadata.json"),
        suite_metadata,
    )

    return suite_metadata


# ===========================================================================
# Phase 2 — Build + Unit Tests in parallel
# ===========================================================================

parallel_jobs = []

for suite, command, working_directory, output_dir in commands:

    if suite in ("build", "unit"):

        parallel_jobs.append(
            start_suite(
                suite,
                command,
                working_directory,
                output_dir,
            )
        )


# ---------------------------------------------------------------------------
# IMPORTANT:
#
# Both operations have already been started before waiting for either one.
#
# Therefore:
#
#   Build ────────────────┐
#                         ├──> results
#   Unit  ────────────────┘
#
# This preserves the performance requirement.
#
# If Build fails, an already-running Unit Test is NOT forcefully terminated.
# Once both finish, the failure prevents Integration Tests from running.
# ---------------------------------------------------------------------------

for job in parallel_jobs:

    result = collect_suite_result(job)

    results.append(result)


# ---------------------------------------------------------------------------
# Mandatory phase gate.
#
# Build and Unit Test failures prevent Integration Tests from running.
# ---------------------------------------------------------------------------

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
        if item[0] == "integration"
    ),
    None,
)


if integration_job and not parallel_failed:

    suite, command, working_directory, output_dir = integration_job

    job = start_suite(
        suite,
        command,
        working_directory,
        output_dir,
    )

    result = collect_suite_result(job)

    results.append(result)


# ===========================================================================
# Final status
# ===========================================================================

final_status = (
    "passed"
    if all(result["status"] == "passed" for result in results)
    else "failed"
)


# ===========================================================================
# Final metadata
# ===========================================================================

end_time = utc_now()

duration_seconds = (
    end_time - start_time
).total_seconds()


# ---------------------------------------------------------------------------
# Build metadata
#
# Build metadata is specifically about the Build capability.
# Test results are NOT embedded here because they have their own
# standardized metadata locations.
# ---------------------------------------------------------------------------

build_result = next(
    (
        result
        for result in results
        if result["capability"] == "build"
    ),
    None,
)


build_metadata = {
    "capability": "build",
    "status": (
        build_result["status"]
        if build_enabled and build_result
        else "skipped"
    ),

    "technology": language,

    "runtime": required_version or None,
    "runtime_actual": node_version,

    "package_manager": package_manager,

    "working_directory": build_cfg.get(
        "working_directory",
        ".",
    ),

    "command": (
        build_command
        if build_enabled
        else None
    ),

    "start_time": start_time.isoformat(),
    "end_time": end_time.isoformat(),
    "duration_seconds": duration_seconds,

    "artifacts": [],
}


write_json(
    os.path.join(build_dir, "metadata.json"),
    build_metadata,
)


# Build report contains ONLY the Build result.
write_json(
    os.path.join(build_dir, "report.json"),
    {
        "suite": "build",
        "result": build_result,
    },
)


# ===========================================================================
# Provider exit status
#
# 0 -> success
# 5 -> execution/application failure
#
# Configuration/tool errors have already exited earlier with their
# corresponding platform exit codes.
# ===========================================================================

sys.exit(
    0
    if final_status == "passed"
    else 5
)

PY

# ---------------------------------------------------------------------------
# Shell-level result handling
# ---------------------------------------------------------------------------

EXIT_CODE=$?

if [ "$EXIT_CODE" -eq 0 ]; then

    log_info "Build & Test provider completed successfully"

else

    if [ "$EXIT_CODE" -eq "$PLATFORM_EXIT_CONFIG" ]; then

        log_error \
            "Build & Test provider failed due to configuration error"

    elif [ "$EXIT_CODE" -eq "$PLATFORM_EXIT_TOOL_MISSING" ]; then

        log_error \
            "Build & Test provider failed because a required " \
            "runtime/tool is missing"

    else

        log_error \
            "Build & Test provider failed with exit code $EXIT_CODE"

    fi

fi

exit "$EXIT_CODE"