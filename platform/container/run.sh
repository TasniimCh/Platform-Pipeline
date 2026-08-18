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
log_info "Workspace: $WORKSPACE"
log_info "Configuration: $WORKSPACE/$CONFIG_FILE"
log_info "Reports: $RESULT_BASE"

config_json=$(load_merged_config_json "$WORKSPACE" "$CONFIG_FILE")

python3 - "$config_json" "$WORKSPACE" "$RESULT_BASE" <<'PYTHON'
import json, os, subprocess, sys, time
from datetime import datetime

config = json.loads(sys.argv[1])
workspace = sys.argv[2]
result_base = sys.argv[3]

caps = config.get('capabilities', {})
if not caps.get('container_build') and not caps.get('container_scan') and not caps.get('sbom') and not caps.get('provenance') and not caps.get('image_publish'):
    print('Container capabilities disabled; skipping')
    sys.exit(0)

container_cfg = config.get('container', {})
registry_cfg = container_cfg.get('registry', {})
dockerfile = container_cfg.get('dockerfile', './Dockerfile')
context = container_cfg.get('context', '.')
image_name = container_cfg.get('image', {}).get('name', 'application')
image_tag = container_cfg.get('image', {}).get('tag')
if not image_tag:
    # use commit-based tag if available via env
    image_tag = os.environ.get('GITHUB_SHA', '')[:7] or str(int(time.time()))
full_tag = f"{image_name}:{image_tag}"
registry_repo = (registry_cfg.get('repository') or '').strip()
if (registry_cfg.get('type') or '').lower() == 'dockerhub' and not registry_repo:
    registry_repo = image_name

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

if caps.get('image_publish'):
    dockerhub_user = (os.environ.get('DOCKERHUB_USERNAME') or '').strip()
    dockerhub_token = (os.environ.get('DOCKERHUB_TOKEN') or '').strip()
    if not dockerhub_user or not dockerhub_token:
        print('DOCKERHUB_USERNAME and DOCKERHUB_TOKEN are required when image_publish is true', file=sys.stderr)
        sys.exit(3)

    remote_ref = f"{registry_repo}:{image_tag}"
    print(f'Logging into Docker Hub for {registry_repo} and pushing {remote_ref}')
    try:
        subprocess.run(['bash', '-lc', f"echo '{dockerhub_token}' | docker login -u '{dockerhub_user}' --password-stdin"], check=True)
        subprocess.run(['docker', 'tag', full_tag, remote_ref], check=True)
        subprocess.run(['docker', 'push', remote_ref], check=True)
        repo_digests_raw = subprocess.check_output(['docker', 'image', 'inspect', '--format', '{{json .RepoDigests}}', remote_ref], text=True).strip()
        repo_digests = json.loads(repo_digests_raw or '[]')
        digest = None
        if isinstance(repo_digests, list) and repo_digests:
            first = repo_digests[0]
            if '@' in first:
                digest = first.split('@', 1)[1]
            else:
                digest = first
        if not digest:
            raise ValueError('No remote digest found after push')
        metadata['image'] = remote_ref
        metadata['image_digest'] = digest
        metadata['registry_repository'] = registry_repo
        metadata['published'] = True
    except Exception as exc:
        print(f'Image publication failed: {exc}', file=sys.stderr)
        sys.exit(5)
else:
    metadata['published'] = False

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
PYTHON

EXIT_CODE=$?
if [ "$EXIT_CODE" -eq 0 ]; then
  log_info "Container & Supply-Chain provider completed successfully"
else
  log_error "Container & Supply-Chain provider failed with exit code $EXIT_CODE"
fi
exit "$EXIT_CODE"
