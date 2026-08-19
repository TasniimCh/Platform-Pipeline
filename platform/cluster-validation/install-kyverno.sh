#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)
PLATFORM_ROOT=$(cd "$SCRIPT_DIR/.." >/dev/null 2>&1 && pwd)

source "$PLATFORM_ROOT/lib/constants.sh"
source "$PLATFORM_ROOT/lib/logging.sh"

: "${WORKSPACE:=${PWD}}"
: "${REPORT_DIR:=.devsecops/reports}"

RESULT_BASE="$WORKSPACE/$REPORT_DIR/cluster-validation/admission"
mkdir -p "$RESULT_BASE"

log_info "Installing Kyverno"

helm repo add kyverno https://kyverno.github.io/kyverno/
helm repo update

helm upgrade --install kyverno kyverno/kyverno \
  --namespace kyverno \
  --create-namespace \
  --wait \
  --timeout 180s

log_info "Waiting for Kyverno admission controller"

kubectl wait \
  --namespace kyverno \
  --for=condition=Available \
  deployment/kyverno-admission-controller \
  --timeout=180s

log_info "Kyverno installed"

kubectl get pods -n kyverno

cat > "$RESULT_BASE/kyverno-install.json" <<'EOF'
{
  "engine": "kyverno",
  "status": "installed",
  "namespace": "kyverno"
}
EOF