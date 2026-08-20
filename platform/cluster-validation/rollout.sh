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

RESULT_BASE="$WORKSPACE/$REPORT_DIR/cluster-validation/rollout"
mkdir -p "$RESULT_BASE"

if ! is_capability_enabled "cluster_validation" "$WORKSPACE" "$CONFIG_FILE"; then
    log_error "Cluster validation capability is disabled"
    exit "$PLATFORM_EXIT_FAILURE"
fi

if ! command -v kubectl >/dev/null 2>&1; then
    log_error "kubectl is required for rollout validation"
    exit "$PLATFORM_EXIT_EXECUTION"
fi

config_json=$(load_merged_config_json "$WORKSPACE" "$CONFIG_FILE") || {
    log_error "Failed to load merged platform configuration"
    exit "$PLATFORM_EXIT_CONFIG"
}

ROLLOUT_OUTPUT=$(
    CONFIG_JSON="$config_json" python3 - <<'PY'
import json
import os
import sys

cfg = json.loads(os.environ.get("CONFIG_JSON", "{}"))

validation = cfg.get("cluster_validation") or {}
rollout = validation.get("rollout") or {}

namespace = str(validation.get("namespace") or "dev").strip()
deployment = str(rollout.get("deployment") or "").strip()
timeout = str(rollout.get("timeout") or "180").strip()

if not deployment:
    print(
        "Missing cluster_validation.rollout.deployment",
        file=sys.stderr
    )
    sys.exit(1)

print(namespace)
print(deployment)
print(timeout)
PY
) || {
    log_error "Failed to resolve rollout configuration"
    exit "$PLATFORM_EXIT_CONFIG"
}

readarray -t ROLLOUT_CONFIG <<< "$ROLLOUT_OUTPUT"

if [ "${#ROLLOUT_CONFIG[@]}" -ne 3 ]; then
    log_error "Invalid rollout configuration: expected namespace, deployment and timeout"
    exit "$PLATFORM_EXIT_CONFIG"
fi

NAMESPACE="${ROLLOUT_CONFIG[0]}"
DEPLOYMENT="${ROLLOUT_CONFIG[1]}"
TIMEOUT="${ROLLOUT_CONFIG[2]}"

log_info "Validating deployment: $DEPLOYMENT"
log_info "Namespace: $NAMESPACE"

if ! kubectl rollout status \
    "deployment/${DEPLOYMENT}" \
    -n "$NAMESPACE" \
    --timeout="${TIMEOUT}s"; then

    log_error "Deployment rollout failed"

    kubectl get deployment "$DEPLOYMENT" \
        -n "$NAMESPACE" \
        -o wide || true

    kubectl get pods \
        -n "$NAMESPACE" \
        -o wide || true

    exit "$PLATFORM_EXIT_FAILURE"
fi

DESIRED="$(kubectl get deployment "$DEPLOYMENT" \
    -n "$NAMESPACE" \
    -o jsonpath='{.spec.replicas}')"

READY="$(kubectl get deployment "$DEPLOYMENT" \
    -n "$NAMESPACE" \
    -o jsonpath='{.status.readyReplicas}')"

AVAILABLE="$(kubectl get deployment "$DEPLOYMENT" \
    -n "$NAMESPACE" \
    -o jsonpath='{.status.availableReplicas}')"

READY="${READY:-0}"
AVAILABLE="${AVAILABLE:-0}"

log_info "Desired replicas: $DESIRED"
log_info "Ready replicas: $READY"
log_info "Available replicas: $AVAILABLE"

if [ "$READY" -ne "$DESIRED" ]; then
    log_error "Not all replicas are ready"
    exit "$PLATFORM_EXIT_FAILURE"
fi

if [ "$AVAILABLE" -ne "$DESIRED" ]; then
    log_error "Not all replicas are available"
    exit "$PLATFORM_EXIT_FAILURE"
fi

if kubectl get pods -n "$NAMESPACE" -o json | \
    python3 -c '
import json
import sys

data = json.load(sys.stdin)

bad = []

for item in data.get("items", []):
    name = item["metadata"]["name"]

    for container in item.get("status", {}).get("containerStatuses", []):
        state = container.get("state", {})

        waiting = state.get("waiting")
        if waiting and waiting.get("reason") in {
            "CrashLoopBackOff",
            "ImagePullBackOff",
            "ErrImagePull"
        }:
            bad.append(
                f"{name}: {waiting.get(\"reason\")}"
            )

if bad:
    print("\n".join(bad))
    sys.exit(1)
'; then
    :
else
    log_error "Detected unhealthy pod/container state"
    kubectl get pods -n "$NAMESPACE" -o wide
    exit "$PLATFORM_EXIT_FAILURE"
fi

cat > "$RESULT_BASE/metadata.json" <<EOF
{
  "capability": "cluster_validation",
  "status": "passed",
  "phase": "rollout",
  "namespace": "${NAMESPACE}",
  "deployment": "${DEPLOYMENT}",
  "desired_replicas": ${DESIRED},
  "ready_replicas": ${READY},
  "available_replicas": ${AVAILABLE}
}
EOF

log_info "Rollout validation passed"