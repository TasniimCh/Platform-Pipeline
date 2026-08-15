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

export WORKSPACE
export CONFIG_FILE
export REPORT_DIR
export LOG_LEVEL

RESOLVE_SCRIPT="$SCRIPT_DIR/resolve.sh"
RENDER_HELM_SCRIPT="$SCRIPT_DIR/render-helm.sh"
DEFAULT_POLICY_DIR="$SCRIPT_DIR/policies"

RESULT_BASE="$WORKSPACE/$REPORT_DIR/policy"
REPORT_FILE="$RESULT_BASE/report.json"
METADATA_FILE="$RESULT_BASE/metadata.json"
RAW_REPORT="$RESULT_BASE/conftest.json"

mkdir -p "$RESULT_BASE"


log_info "Starting CI Policy Testing provider"
log_info "Workspace: $WORKSPACE"
log_info "Configuration: $WORKSPACE/$CONFIG_FILE"
log_info "Reports: $RESULT_BASE"


# -----------------------------------------------------------------------------
# Capability check
# -----------------------------------------------------------------------------

if ! is_capability_enabled \
    "policy_enforcement" \
    "$WORKSPACE" \
    "$CONFIG_FILE"; then

  log_info "CI Policy Testing capability is disabled; skipping"

  cat > "$REPORT_FILE" <<EOF
{
  "capability": "policy_enforcement",
  "status": "skipped",
  "resources_evaluated": 0,
  "violations": [],
  "summary": {
    "total": 0,
    "high": 0,
    "medium": 0,
    "low": 0
  }
}
EOF

  cat > "$METADATA_FILE" <<EOF
{
  "capability": "policy_enforcement",
  "status": "skipped",
  "engine": "conftest",
  "engine_version": null,
  "reports": {
    "report": "$REPORT_FILE",
    "raw": null
  }
}
EOF

  exit 0
fi


# -----------------------------------------------------------------------------
# Validate required tools
# -----------------------------------------------------------------------------

if ! command -v conftest >/dev/null 2>&1; then
  log_error "Conftest is not installed"

  cat > "$REPORT_FILE" <<EOF
{
  "capability": "policy_enforcement",
  "status": "tool_error",
  "resources_evaluated": 0,
  "violations": [],
  "summary": {
    "total": 0,
    "high": 0,
    "medium": 0,
    "low": 0
  },
  "error": "Conftest is not installed"
}
EOF

  exit "$PLATFORM_EXIT_FAILURE"
fi

if ! command -v python3 >/dev/null 2>&1; then
  log_error "python3 is required for policy result processing"
  exit "$PLATFORM_EXIT_FAILURE"
fi


# -----------------------------------------------------------------------------
# Load configuration
# -----------------------------------------------------------------------------

config_json=$(load_merged_config_json "$WORKSPACE" "$CONFIG_FILE") || {
  log_error "Failed to load merged platform configuration"
  exit "$PLATFORM_EXIT_CONFIG"
}


# -----------------------------------------------------------------------------
# Validate policy configuration
# -----------------------------------------------------------------------------

CONFIG_JSON="$config_json" python3 - <<'PY'
import json
import os
import sys

config = json.loads(os.environ.get("CONFIG_JSON", "{}"))

policy = config.get("policy", {})

paths = policy.get("paths", [])
policy_paths = policy.get("policy_paths", [])

if paths is None:
    paths = []

if policy_paths is None:
    policy_paths = []

if not isinstance(paths, list):
    print('"policy.paths" must be a list', file=sys.stderr)
    sys.exit(1)

if not isinstance(policy_paths, list):
    print('"policy.policy_paths" must be a list', file=sys.stderr)
    sys.exit(1)

for path in paths:
    if not isinstance(path, str) or not path.strip():
        print('"policy.paths must contain non-empty strings', file=sys.stderr)
        sys.exit(1)

for path in policy_paths:
    if not isinstance(path, str) or not path.strip():
        print(
            '"policy.policy_paths" must contain non-empty strings',
            file=sys.stderr,
        )
        sys.exit(1)
PY

if [ "$?" -ne 0 ]; then
  log_error "Invalid policy configuration"
  exit "$PLATFORM_EXIT_CONFIG"
fi


# -----------------------------------------------------------------------------
# Temporary isolated workspace
# -----------------------------------------------------------------------------

TEMP_DIR=$(mktemp -d)

cleanup() {
  rm -rf "$TEMP_DIR"
}

trap cleanup EXIT


RESOLVED_DIR="$TEMP_DIR/resolved"
MANIFEST_DIR="$TEMP_DIR/manifests"
RENDERED_DIR="$TEMP_DIR/rendered"
POLICY_DIR="$TEMP_DIR/policies"

mkdir -p \
  "$RESOLVED_DIR" \
  "$MANIFEST_DIR" \
  "$RENDERED_DIR" \
  "$POLICY_DIR"


log_debug "Temporary policy workspace: $TEMP_DIR"


# -----------------------------------------------------------------------------
# Resolve Kubernetes manifests / Helm charts
# -----------------------------------------------------------------------------

log_info "Resolving policy inputs"

if ! "$RESOLVE_SCRIPT" \
    "$WORKSPACE" \
    "$CONFIG_FILE" \
    "$RESOLVED_DIR"; then

  log_error "Manifest resolution failed"

  cat > "$REPORT_FILE" <<EOF
{
  "capability": "policy_enforcement",
  "status": "configuration_error",
  "resources_evaluated": 0,
  "violations": [],
  "summary": {
    "total": 0,
    "high": 0,
    "medium": 0,
    "low": 0
  },
  "error": "Manifest resolution failed"
}
EOF

  exit "$PLATFORM_EXIT_CONFIG"
fi


# -----------------------------------------------------------------------------
# Collect already-resolved Kubernetes manifests
# -----------------------------------------------------------------------------

manifest_count=0

while IFS= read -r manifest; do
  [ -z "$manifest" ] && continue

  output_file="$MANIFEST_DIR/manifest-${manifest_count}.yaml"

  cp "$manifest" "$output_file"

  manifest_count=$((manifest_count + 1))
done < <(
  find "$RESOLVED_DIR" \
    -maxdepth 1 \
    -type f \
    -name 'manifest-*.yaml' \
    -print
)


# -----------------------------------------------------------------------------
# Render Helm charts
# -----------------------------------------------------------------------------

helm_count=0

if [ -f "$RESOLVED_DIR/helm-charts.txt" ]; then

  log_info "Rendering Helm charts"

  while IFS= read -r chart_path; do
    [ -z "$chart_path" ] && continue

    rendered_file=$(
      "$RENDER_HELM_SCRIPT" \
        "$chart_path" \
        "$RENDERED_DIR"
    )

    cp "$rendered_file" \
      "$MANIFEST_DIR/helm-${helm_count}.yaml"

    helm_count=$((helm_count + 1))

  done < "$RESOLVED_DIR/helm-charts.txt"

fi


# -----------------------------------------------------------------------------
# Verify resolved input
# -----------------------------------------------------------------------------

total_resources=$((manifest_count + helm_count))

if [ "$total_resources" -eq 0 ]; then
  log_error "No Kubernetes manifests were resolved"

  cat > "$REPORT_FILE" <<EOF
{
  "capability": "policy_enforcement",
  "status": "execution_error",
  "resources_evaluated": 0,
  "violations": [],
  "summary": {
    "total": 0,
    "high": 0,
    "medium": 0,
    "low": 0
  },
  "error": "No Kubernetes manifests were resolved"
}
EOF

  exit "$PLATFORM_EXIT_FAILURE"
fi

log_info "Resolved $manifest_count Kubernetes manifest(s)"
log_info "Rendered $helm_count Helm chart(s)"


# -----------------------------------------------------------------------------
# Load platform default policies
# -----------------------------------------------------------------------------

if [ ! -d "$DEFAULT_POLICY_DIR" ]; then
  log_error "Platform default policy directory not found: $DEFAULT_POLICY_DIR"
  exit "$PLATFORM_EXIT_FAILURE"
fi

log_info "Loading platform default policies"

default_policy_count=0

while IFS= read -r policy_file; do
  [ -z "$policy_file" ] && continue

  cp "$policy_file" "$POLICY_DIR/"

  default_policy_count=$((default_policy_count + 1))
done < <(
  find "$DEFAULT_POLICY_DIR" \
    -type f \
    -name '*.rego' \
    -print
)


# -----------------------------------------------------------------------------
# Load repository policies
# -----------------------------------------------------------------------------

repository_policy_count=0

policy_paths_json=$(CONFIG_JSON="$config_json" python3 - <<'PY'
import json
import os

config = json.loads(os.environ["CONFIG_JSON"])

paths = config.get("policy", {}).get("policy_paths", [])

print(json.dumps(paths))
PY
)


while IFS= read -r configured_path; do
  [ -z "$configured_path" ] && continue

  # ---------------------------------------------------------------------------
  # Path safety
  # ---------------------------------------------------------------------------

  if [[ "$configured_path" = /* ]]; then
    log_error "Repository policy path must be relative: $configured_path"
    exit "$PLATFORM_EXIT_CONFIG"
  fi

  if [[ "$configured_path" == *".."* ]]; then
    log_error "Repository policy path traversal is not allowed: $configured_path"
    exit "$PLATFORM_EXIT_CONFIG"
  fi

  policy_source="$WORKSPACE/$configured_path"

  if [ ! -e "$policy_source" ]; then
    log_error "Repository policy path does not exist: $configured_path"
    exit "$PLATFORM_EXIT_CONFIG"
  fi

  canonical_workspace=$(cd "$WORKSPACE" && pwd)

  if [ -d "$policy_source" ]; then
    canonical_policy_source=$(cd "$policy_source" && pwd)
  else
    canonical_policy_source=$(
      cd "$(dirname "$policy_source")" && pwd
    )/$(basename "$policy_source")
  fi

  case "$canonical_policy_source" in
    "$canonical_workspace"/*)
      ;;
    *)
      log_error "Repository policy path escapes workspace: $configured_path"
      exit "$PLATFORM_EXIT_CONFIG"
      ;;
  esac

  # ---------------------------------------------------------------------------
  # Copy policy files
  # ---------------------------------------------------------------------------

  if [ -f "$policy_source" ]; then

    case "$policy_source" in
      *.rego)
        cp "$policy_source" "$POLICY_DIR/"
        repository_policy_count=$((repository_policy_count + 1))
        ;;
      *)
        log_error "Unsupported repository policy file: $configured_path"
        exit "$PLATFORM_EXIT_CONFIG"
        ;;
    esac

  elif [ -d "$policy_source" ]; then

    while IFS= read -r policy_file; do
      cp "$policy_file" "$POLICY_DIR/"
      repository_policy_count=$((repository_policy_count + 1))
    done < <(
      find "$policy_source" \
        -type f \
        -name '*.rego' \
        -print
    )

  fi

done < <(
  POLICY_PATHS_JSON="$policy_paths_json" python3 - <<'PY'
import json
import os

paths = json.loads(os.environ["POLICY_PATHS_JSON"])

for path in paths:
    if not isinstance(path, str):
        raise SystemExit(
            "policy.policy_paths must contain strings"
        )

    print(path)
PY
)


total_policy_count=$(
  find "$POLICY_DIR" \
    -type f \
    -name '*.rego' \
    | wc -l
)

if [ "$total_policy_count" -eq 0 ]; then
  log_error "No Rego policies available for evaluation"
  exit "$PLATFORM_EXIT_FAILURE"
fi

log_info "Loaded $default_policy_count platform policy file(s)"
log_info "Loaded $repository_policy_count repository policy file(s)"


# -----------------------------------------------------------------------------
# Validate policies before evaluation
# -----------------------------------------------------------------------------

log_info "Validating policy bundle"

if ! conftest verify \
    --policy "$POLICY_DIR" \
    >/dev/null; then

  log_error "Policy validation failed"

  cat > "$REPORT_FILE" <<EOF
{
  "capability": "policy_enforcement",
  "status": "execution_error",
  "resources_evaluated": 0,
  "violations": [],
  "summary": {
    "total": 0,
    "high": 0,
    "medium": 0,
    "low": 0
  },
  "error": "Policy validation failed"
}
EOF

  exit "$PLATFORM_EXIT_FAILURE"
fi


# -----------------------------------------------------------------------------
# Evaluate policies
# -----------------------------------------------------------------------------

log_info "Evaluating Kubernetes manifests with Conftest"

conftest_status=0

set +e

conftest test \
  --policy "$POLICY_DIR" \
  --output json \
  "$MANIFEST_DIR" \
  > "$RAW_REPORT" 2>&1

conftest_status=$?

set -e


# -----------------------------------------------------------------------------
# Normalize Conftest output
# -----------------------------------------------------------------------------

if [ ! -s "$RAW_REPORT" ]; then

  log_error "Conftest produced no result"

  cat > "$REPORT_FILE" <<EOF
{
  "capability": "policy_enforcement",
  "status": "tool_error",
  "resources_evaluated": $total_resources,
  "violations": [],
  "summary": {
    "total": 0,
    "high": 0,
    "medium": 0,
    "low": 0
  },
  "error": "Conftest produced no result"
}
EOF

  exit "$PLATFORM_EXIT_FAILURE"
fi


CONFIG_JSON="$config_json" \
RAW_REPORT="$RAW_REPORT" \
REPORT_FILE="$REPORT_FILE" \
METADATA_FILE="$METADATA_FILE" \
WORKSPACE="$WORKSPACE" \
RESULT_BASE="$RESULT_BASE" \
CONFTEST_STATUS="$conftest_status" \
MANIFEST_COUNT="$total_resources" \
DEFAULT_POLICY_COUNT="$default_policy_count" \
REPOSITORY_POLICY_COUNT="$repository_policy_count" \
python3 - <<'PY'
import json
import os
from datetime import datetime, timezone
from pathlib import Path


raw_path = Path(os.environ["RAW_REPORT"])
report_path = Path(os.environ["REPORT_FILE"])
metadata_path = Path(os.environ["METADATA_FILE"])

conftest_status = int(os.environ["CONFTEST_STATUS"])
manifest_count = int(os.environ["MANIFEST_COUNT"])
default_policy_count = int(os.environ["DEFAULT_POLICY_COUNT"])
repository_policy_count = int(os.environ["REPOSITORY_POLICY_COUNT"])


def now():
    return datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")


# ---------------------------------------------------------------------------
# Load Conftest JSON
# ---------------------------------------------------------------------------

try:
    raw_text = raw_path.read_text(encoding="utf-8")
    raw = json.loads(raw_text)
except Exception as exc:
    report = {
        "capability": "policy_enforcement",
        "status": "tool_error",
        "resources_evaluated": manifest_count,
        "violations": [],
        "summary": {
            "total": 0,
            "high": 0,
            "medium": 0,
            "low": 0,
        },
        "error": f"Unable to parse Conftest output: {exc}",
    }

    report_path.write_text(
        json.dumps(report, indent=2),
        encoding="utf-8",
    )

    raise SystemExit(1)


# ---------------------------------------------------------------------------
# Normalize results
# ---------------------------------------------------------------------------

violations = []
resources_evaluated = 0


def normalize_finding(finding, filename, severity):
    policy_id = (
        finding.get("rule")
        or finding.get("policy")
        or finding.get("id")
        or "unknown"
    )

    message = (
        finding.get("msg")
        or finding.get("message")
        or ""
    )

    return {
        "policy_id": policy_id,
        "severity": severity,
        "message": message,
        "file": filename,
    }


if isinstance(raw, list):

    for result in raw:

        if not isinstance(result, dict):
            continue

        filename = result.get("filename")

        # A Conftest result represents one evaluated input.
        resources_evaluated += 1

        for failure in result.get("failures", []) or []:
            if isinstance(failure, dict):
                violations.append(
                    normalize_finding(
                        failure,
                        filename,
                        "high",
                    )
                )

        for warning in result.get("warnings", []) or []:
            if isinstance(warning, dict):
                violations.append(
                    normalize_finding(
                        warning,
                        filename,
                        "medium",
                    )
                )


# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------

summary = {
    "total": len(violations),
    "high": sum(
        1
        for finding in violations
        if finding["severity"] == "high"
    ),
    "medium": sum(
        1
        for finding in violations
        if finding["severity"] == "medium"
    ),
    "low": sum(
        1
        for finding in violations
        if finding["severity"] == "low"
    ),
}


# ---------------------------------------------------------------------------
# Determine platform status
# ---------------------------------------------------------------------------

if conftest_status == 0:
    status = "success"
elif violations:
    status = "findings"
else:
    status = "execution_error"


# ---------------------------------------------------------------------------
# Platform report
# ---------------------------------------------------------------------------

report = {
    "capability": "policy_enforcement",
    "status": status,
    "engine": "conftest",
    "resources_evaluated": (
        resources_evaluated
        if resources_evaluated > 0
        else manifest_count
    ),
    "violations": violations,
    "summary": summary,
}


report_path.write_text(
    json.dumps(report, indent=2),
    encoding="utf-8",
)


# ---------------------------------------------------------------------------
# Metadata
# ---------------------------------------------------------------------------

try:
    import subprocess

    version = subprocess.check_output(
        ["conftest", "--version"],
        text=True,
        stderr=subprocess.STDOUT,
    ).strip()
except Exception:
    version = None


metadata = {
    "capability": "policy_enforcement",
    "engine": "conftest",
    "engine_version": version,
    "status": status,
    "evaluation_status": (
        "completed"
        if conftest_status in (0, 1, 2)
        else "failed"
    ),
    "resources_evaluated": (
        resources_evaluated
        if resources_evaluated > 0
        else manifest_count
    ),
    "policies": {
        "platform": default_policy_count,
        "repository": repository_policy_count,
        "total": default_policy_count + repository_policy_count,
    },
    "violations": summary,
    "reports": {
        "report": str(report_path),
        "raw": str(raw_path),
    },
    "generated_at": now(),
}


metadata_path.write_text(
    json.dumps(metadata, indent=2),
    encoding="utf-8",
)

print(json.dumps(report, indent=2))
PY


# -----------------------------------------------------------------------------
# Final CI result
# -----------------------------------------------------------------------------

case "$conftest_status" in

  0)
    log_info "CI Policy Testing completed successfully"
    log_info "No policy violations detected"
    exit 0
    ;;

  *)
    # A non-zero Conftest result can mean actual findings.
    # The normalized report determines whether this was a finding
    # or an execution/tool error.

    final_status=$(
      python3 -c 'import json, sys; print(json.load(open(sys.argv[1], encoding="utf-8")).get("status", "execution_error"))' \
        "$REPORT_FILE"
    )

    case "$final_status" in
      findings)
        log_error "CI Policy Testing detected policy violations"
        log_info "Report: $REPORT_FILE"
        exit "$PLATFORM_EXIT_FAILURE"
        ;;

      tool_error|execution_error)
        log_error "CI Policy Testing failed during policy evaluation"
        log_info "Report: $REPORT_FILE"
        exit "$PLATFORM_EXIT_FAILURE"
        ;;

      *)
        log_error "CI Policy Testing failed with unknown status: $final_status"
        exit "$PLATFORM_EXIT_FAILURE"
        ;;
    esac
    ;;
esac