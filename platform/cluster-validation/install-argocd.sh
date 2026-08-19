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

RESULT_BASE="$WORKSPACE/$REPORT_DIR/cluster-validation/argocd"
mkdir -p "$RESULT_BASE"

log_info "Installing Argo CD"

if ! command -v kubectl >/dev/null 2>&1; then
    log_error "kubectl is required"
    exit "$PLATFORM_EXIT_EXECUTION"
fi

if ! command -v argocd >/dev/null 2>&1; then
    log_info "Installing Argo CD CLI"

    curl -sSL -o /tmp/argocd \
      https://github.com/argoproj/argo-cd/releases/latest/download/argocd-linux-amd64

    install -m 0755 /tmp/argocd /usr/local/bin/argocd
fi

log_info "Installing Argo CD server"

kubectl create namespace argocd \
    --dry-run=client \
    -o yaml | kubectl apply -f -

kubectl apply -n argocd \
    -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml

log_info "Waiting for Argo CD components"

kubectl wait \
    --namespace argocd \
    --for=condition=Available \
    deployment/argocd-server \
    --timeout=180s

kubectl wait \
    --namespace argocd \
    --for=condition=Available \
    deployment/argocd-repo-server \
    --timeout=180s

kubectl wait \
    --namespace argocd \
    --for=condition=Available \
    deployment/argocd-server \
    --timeout=180s

log_info "Argo CD installed successfully"

kubectl get pods -n argocd

cat > "$RESULT_BASE/metadata.json" <<EOF
{
  "component": "argocd",
  "status": "installed",
  "namespace": "argocd"
}
EOF