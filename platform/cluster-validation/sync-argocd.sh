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
: "${GITOPS_TOKEN:=}"

RESULT_BASE="$WORKSPACE/$REPORT_DIR/cluster-validation/argocd"
mkdir -p "$RESULT_BASE"

if [ -z "${GITOPS_TOKEN:-}" ]; then
    log_error "GITOPS_TOKEN is required by Argo CD"
    exit "$PLATFORM_EXIT_EXECUTION"
fi

config_json=$(load_merged_config_json "$WORKSPACE" "$CONFIG_FILE") || {
    log_error "Failed to load merged platform configuration"
    exit "$PLATFORM_EXIT_CONFIG"
}

readarray -t ARGO_CONFIG < <(
    CONFIG_JSON="$config_json" python3 - <<'PY'
import json
import os
import sys

cfg = json.loads(os.environ.get("CONFIG_JSON", "{}"))

gitops = cfg.get("gitops", {})
argocd = gitops.get("argocd", {})

repository = str(gitops.get("repository", "")).strip()
revision = str(gitops.get("ref", "main")).strip()

application = str(
    argocd.get("application_name", "")
).strip()

path = str(
    argocd.get("path", "")
).strip()

namespace = str(
    argocd.get("namespace", "dev")
).strip()

project = str(
    argocd.get("project", "default")
).strip()

if not repository:
    print("Missing gitops.repository", file=sys.stderr)
    sys.exit(1)

if not application:
    print("Missing gitops.argocd.application_name", file=sys.stderr)
    sys.exit(1)

if not path:
    print("Missing gitops.argocd.path", file=sys.stderr)
    sys.exit(1)

print(repository)
print(revision)
print(application)
print(path)
print(namespace)
print(project)
PY
)

GITOPS_REPOSITORY="${ARGO_CONFIG[0]}"
GITOPS_REVISION="${ARGO_CONFIG[1]}"
ARGO_APP="${ARGO_CONFIG[2]}"
ARGO_PATH="${ARGO_CONFIG[3]}"
TARGET_NAMESPACE="${ARGO_CONFIG[4]}"
ARGO_PROJECT="${ARGO_CONFIG[5]}"

GITOPS_URL="https://github.com/${GITOPS_REPOSITORY}.git"

log_info "GitOps repository: $GITOPS_URL"
log_info "GitOps revision: $GITOPS_REVISION"
log_info "Argo CD application: $ARGO_APP"
log_info "Argo CD path: $ARGO_PATH"
log_info "Target namespace: $TARGET_NAMESPACE"

kubectl create namespace "$TARGET_NAMESPACE" \
    --dry-run=client \
    -o yaml | kubectl apply -f -


log_info "Retrieving Argo CD admin credentials"

ARGO_PASSWORD="$(
    kubectl -n argocd get secret argocd-initial-admin-secret \
        -o jsonpath='{.data.password}' | base64 -d
)"

kubectl -n argocd port-forward svc/argocd-server 8080:443 \
    >/tmp/argocd-port-forward.log 2>&1 &

ARGO_PORT_FORWARD_PID=$!

cleanup() {
    kill "$ARGO_PORT_FORWARD_PID" >/dev/null 2>&1 || true
}

trap cleanup EXIT

sleep 5

log_info "Logging into Argo CD"

argocd login localhost:8080 \
    --username admin \
    --password "$ARGO_PASSWORD" \
    --insecure

log_info "Configuring private GitOps repository in Argo CD"

argocd repo add "$GITOPS_URL" \
    --username x-access-token \
    --password "$GITOPS_TOKEN" \
    --insecure-skip-server-verification

log_info "Creating Argo CD Application"

cat > /tmp/argocd-application.yaml <<EOF
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: ${ARGO_APP}
  namespace: argocd
spec:
  project: ${ARGO_PROJECT}
  source:
    repoURL: ${GITOPS_URL}
    targetRevision: ${GITOPS_REVISION}
    path: ${ARGO_PATH}
  destination:
    server: https://kubernetes.default.svc
    namespace: ${TARGET_NAMESPACE}
  syncPolicy: {}
EOF

kubectl apply -f /tmp/argocd-application.yaml

log_info "Argo CD Application created"

log_info "Starting explicit Argo CD synchronization"

argocd app sync "$ARGO_APP" \
    --timeout 180

log_info "Waiting for Argo CD application to become healthy"

if ! argocd app wait "$ARGO_APP" \
    --sync \
    --health \
    --timeout 180; then

    log_error "Argo CD application failed to become healthy"

    log_info "=== Argo CD Application ==="
    argocd app get "$ARGO_APP"

    log_info "=== Deployments ==="
    kubectl get deployments -n "$TARGET_NAMESPACE" -o wide

    log_info "=== Pods ==="
    kubectl get pods -n "$TARGET_NAMESPACE" -o wide

    log_info "=== Services ==="
    kubectl get services -n "$TARGET_NAMESPACE" -o wide

    log_info "=== Deployment description ==="
    kubectl describe deployment "$ARGO_APP" -n "$TARGET_NAMESPACE" || true

    log_info "=== Pod descriptions ==="
    kubectl describe pods -n "$TARGET_NAMESPACE" || true

    log_info "=== Pod logs ==="
    kubectl logs \
        -n "$TARGET_NAMESPACE" \
        -l "app.kubernetes.io/name=$ARGO_APP" \
        --all-containers \
        --tail=200 || true

    exit "$PLATFORM_EXIT_FAILURE"
fi

SYNC_STATUS="$(argocd app get "$ARGO_APP" -o json | python3 -c '
import json
import sys

data = json.load(sys.stdin)
status = data.get("status", {})

print(status.get("sync", {}).get("status", "Unknown"))
')"

HEALTH_STATUS="$(argocd app get "$ARGO_APP" -o json | python3 -c '
import json
import sys

data = json.load(sys.stdin)
status = data.get("status", {})

print(status.get("health", {}).get("status", "Unknown"))
')"

log_info "Argo CD sync status: $SYNC_STATUS"
log_info "Argo CD health status: $HEALTH_STATUS"

if [ "$SYNC_STATUS" != "Synced" ]; then
    log_error "Argo CD application is not Synced"
    exit "$PLATFORM_EXIT_FAILURE"
fi

if [ "$HEALTH_STATUS" != "Healthy" ]; then
    log_error "Argo CD application is not Healthy"
    exit "$PLATFORM_EXIT_FAILURE"
fi

cat > "$RESULT_BASE/sync.json" <<EOF
{
  "application": "${ARGO_APP}",
  "repository": "${GITOPS_REPOSITORY}",
  "revision": "${GITOPS_REVISION}",
  "path": "${ARGO_PATH}",
  "namespace": "${TARGET_NAMESPACE}",
  "sync_status": "${SYNC_STATUS}",
  "health_status": "${HEALTH_STATUS}",
  "status": "passed"
}
EOF

log_info "Argo CD deployment completed successfully"