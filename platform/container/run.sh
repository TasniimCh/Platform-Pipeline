#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)
PLATFORM_ROOT=$(cd "$SCRIPT_DIR/.." >/dev/null 2>&1 && pwd)

source "$PLATFORM_ROOT/lib/constants.sh"
source "$PLATFORM_ROOT/lib/logging.sh"
source "$PLATFORM_ROOT/config/config.sh"

: ${WORKSPACE:=${PWD}}
: ${CONFIG_FILE:=".devsecops/pipeline.yaml"}
: ${REPORT_DIR:=".devsecops/reports"}
: ${LOG_LEVEL:=info}

export WORKSPACE
export CONFIG_FILE
export REPORT_DIR
export LOG_LEVEL

RESULT_BASE="$WORKSPACE/$REPORT_DIR/container"
mkdir -p "$RESULT_BASE"

log_info "Starting Container & Supply-Chain provider"

config_json=$(load_merged_config_json "$WORKSPACE" "$CONFIG_FILE")

python3 - "$config_json" "$WORKSPACE" "$RESULT_BASE" <<'PY'
import json, os, subprocess, sys, time
from datetime import datetime

config = json.loads(sys.argv[1])
workspace = sys.argv[2]
result_base = sys.argv[3]

caps = config.get('capabilities', {})
if not caps.get('container_build') and not caps.get('container_scan') and not caps.get('sbom') and not caps.get('provenance'):
    print('Container capabilities disabled; skipping')
    sys.exit(0)

container_cfg = config.get('container', {})
dockerfile = container_cfg.get('dockerfile', './Dockerfile')
context = container_cfg.get('context', '.')
image_name = container_cfg.get('image', {}).get('name', 'application')
image_tag = container_cfg.get('image', {}).get('tag')
if not image_tag:
    # use commit-based tag if available via env
    image_tag = os.environ.get('GITHUB_SHA', '')[:7] or str(int(time.time()))
full_tag = f"{image_name}:{image_tag}"

# Validate dockerfile exists
dockerfile_path = os.path.join(workspace, dockerfile)
if not os.path.isfile(dockerfile_path):
    print(f'Dockerfile not found: {dockerfile_path}', file=sys.stderr)
    sys.exit(2)

# Build image
print(f'Building image {full_tag} from {dockerfile_path} (context: {context})')
try:
    subprocess.run(['bash','-lc', f'cd "{workspace}/{context}" && docker build -f "{dockerfile_path}" -t "{full_tag}" .'], check=True)
except subprocess.CalledProcessError as e:
    print('Image build failed', file=sys.stderr)
    sys.exit(5)

# Resolve image identity (use image ID)
try:
    image_id = subprocess.check_output(['docker','image','inspect','--format','{{.Id}}', full_tag], text=True).strip()
except Exception:
    print('Failed to inspect built image', file=sys.stderr)
    sys.exit(5)

# Prepare result dir per image id (sanitize)
digest = image_id.replace(':','-')
result_dir = os.path.join(result_base, digest)
os.makedirs(result_dir, exist_ok=True)

metadata = {
    'capability': 'container_supply_chain',
    'status': 'unknown',
    'image': full_tag,
    'image_id': image_id,
    'start_time': datetime.utcnow().isoformat() + 'Z',
    'end_time': None,
    'duration_seconds': None,
    'reports': {},
}

# Run Trivy if enabled
if caps.get('container_scan'):
    trivy_report = os.path.join(result_dir, 'trivy-report.json')
    print('Running Trivy scan...')
    try:
        subprocess.run(['bash','-lc', f'trivy image --quiet --format json --output "{trivy_report}" "{full_tag}"'], check=True)
        metadata['reports']['trivy'] = trivy_report
    except subprocess.CalledProcessError:
        print('Trivy execution failed', file=sys.stderr)
        sys.exit(5)

# Run Syft to produce SBOM if enabled
if caps.get('sbom'):
    sbom_file = os.path.join(result_dir, 'sbom-cyclonedx.json')
    print('Generating SBOM via Syft...')
    try:
        subprocess.run(['bash','-lc', f'syft "{full_tag}" -o cyclonedx-json > "{sbom_file}"'], check=True)
        metadata['reports']['sbom'] = sbom_file
    except subprocess.CalledProcessError:
        print('Syft execution failed', file=sys.stderr)
        sys.exit(5)

# Placeholder: generate provenance if requested
if caps.get('provenance'):
    prov_file = os.path.join(result_dir, 'provenance.json')
    print('Generating provenance metadata (placeholder)...')
    prov = {
        'source': os.environ.get('GITHUB_REPOSITORY', ''),
        'commit': os.environ.get('GITHUB_SHA', ''),
        'build_time': datetime.utcnow().isoformat() + 'Z',
        'image': full_tag,
        'image_id': image_id,
    }
    with open(prov_file, 'w', encoding='utf-8') as f:
        json.dump(prov, f, indent=2)
    metadata['reports']['provenance'] = prov_file

metadata['end_time'] = datetime.utcnow().isoformat() + 'Z'
# duration calculation omitted for simplicity
with open(os.path.join(result_dir, 'metadata.json'), 'w', encoding='utf-8') as f:
    json.dump(metadata, f, indent=2)

print('Container supply-chain evidence generated at', result_dir)
sys.exit(0)
PY

EXIT_CODE=$?
if [ "$EXIT_CODE" -eq 0 ]; then
  log_info "Container & Supply-Chain provider completed successfully"
else
  log_error "Container & Supply-Chain provider failed with exit code $EXIT_CODE"
fi
exit "$EXIT_CODE"
