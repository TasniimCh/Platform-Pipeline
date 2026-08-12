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

BUILD_DIR="$WORKSPACE/$REPORT_DIR/build"
UNIT_DIR="$WORKSPACE/$REPORT_DIR/tests/unit"
INTEGRATION_DIR="$WORKSPACE/$REPORT_DIR/tests/integration"
mkdir -p "$BUILD_DIR" "$UNIT_DIR" "$INTEGRATION_DIR"

log_info "Starting Build & Test provider"

config_json=$(load_merged_config_json "$WORKSPACE" "$CONFIG_FILE")

python3 - "$config_json" "$WORKSPACE" "$BUILD_DIR" "$UNIT_DIR" "$INTEGRATION_DIR" <<'PY'
import json
import os
import subprocess
import sys
from datetime import datetime

config = json.loads(sys.argv[1])
workspace = sys.argv[2]
build_dir = sys.argv[3]
unit_dir = sys.argv[4]
integration_dir = sys.argv[5]

caps = config.get('capabilities', {})
if not any([
    caps.get('build', False),
    caps.get('unit_testing', False),
    caps.get('integration_testing', False),
]):
    print('Build & Test capabilities disabled; skipping')
    sys.exit(0)

build_cfg = config.get('build', {})
testing_cfg = config.get('testing', {})

working_directory = os.path.join(workspace, build_cfg.get('working_directory', '.'))
if not os.path.isdir(working_directory):
    print(f'Working directory not found: {working_directory}', file=sys.stderr)
    sys.exit(2)

package_json_path = os.path.join(working_directory, 'package.json')
if not os.path.isfile(package_json_path):
    print('Missing package.json in working directory; cannot resolve Node.js project', file=sys.stderr)
    sys.exit(2)

with open(package_json_path, 'r', encoding='utf-8') as f:
    package_data = json.load(f)
scripts = package_data.get('scripts', {})

runtime = build_cfg.get('runtime', {})
language = runtime.get('language', 'node')
version = str(runtime.get('version', ''))
package_manager = runtime.get('package_manager')

if language != 'node':
    print(f'Unsupported runtime language: {language}', file=sys.stderr)
    sys.exit(2)

try:
    node_version = subprocess.check_output(['node', '--version'], stderr=subprocess.STDOUT, text=True).strip()
except FileNotFoundError:
    print('Node.js is not available in the environment', file=sys.stderr)
    sys.exit(3)

if version:
    if not node_version.startswith('v' + version):
        print(f'Required Node.js version {version} is unavailable; found {node_version}', file=sys.stderr)
        sys.exit(2)

lockfiles = {
    'npm': 'package-lock.json',
    'yarn': 'yarn.lock',
    'pnpm': 'pnpm-lock.yaml',
}
lockfile_matches = []
for manager, filename in lockfiles.items():
    if os.path.isfile(os.path.join(working_directory, filename)):
        lockfile_matches.append(manager)

if not package_manager:
    if len(lockfile_matches) == 1:
        package_manager = lockfile_matches[0]
    elif len(lockfile_matches) > 1:
        print('Multiple supported lockfiles detected; explicit package_manager is required', file=sys.stderr)
        sys.exit(2)
    else:
        print('No supported package manager lockfile found; explicit package_manager is required', file=sys.stderr)
        sys.exit(2)

if package_manager not in lockfiles:
    print(f'Unsupported package manager: {package_manager}', file=sys.stderr)
    sys.exit(2)

pm_executable = package_manager
if package_manager == 'npm':
    install_cmd = 'npm install'
elif package_manager == 'yarn':
    install_cmd = 'yarn install'
elif package_manager == 'pnpm':
    install_cmd = 'pnpm install'
else:
    install_cmd = None

if install_cmd:
    if subprocess.run(['bash', '-lc', f'command -v {pm_executable}'], check=False, stdout=subprocess.PIPE, stderr=subprocess.PIPE).returncode != 0:
        print(f'Required package manager executable not found: {pm_executable}', file=sys.stderr)
        sys.exit(3)

build_enabled = caps.get('build', False)
unit_enabled = caps.get('unit_testing', False)
integration_enabled = caps.get('integration_testing', False)

build_command = build_cfg.get('command') or scripts.get('build')
unit_command = testing_cfg.get('unit', {}).get('command') or scripts.get('test')
integration_command = testing_cfg.get('integration', {}).get('command') or scripts.get('integration')

if build_enabled and not build_command:
    print('Build enabled but no build command resolved', file=sys.stderr)
    sys.exit(2)
if unit_enabled and not unit_command:
    print('Unit testing enabled but no test command resolved', file=sys.stderr)
    sys.exit(2)
if integration_enabled and not integration_command:
    print('Integration testing enabled but no integration command resolved', file=sys.stderr)
    sys.exit(2)

commands = []
if build_enabled:
    commands.append(('build', build_command, build_dir, {'report': os.path.join('build', 'report.json')}))
if unit_enabled:
    commands.append(('unit', unit_command, unit_dir, {'report': os.path.join('tests', 'unit', 'report.json')}))
if integration_enabled:
    commands.append(('integration', integration_command, integration_dir, {'report': os.path.join('tests', 'integration', 'report.json')}))

start_time = datetime.utcnow()

def write_json(path, data):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, 'w', encoding='utf-8') as f:
        json.dump(data, f, indent=2)

results = []

# Install dependencies once if any provider action is requested.
if commands:
    print(f'Installing dependencies with {package_manager}', file=sys.stdout)
    try:
        subprocess.run(['bash', '-lc', f'cd "{working_directory}" && {install_cmd}'], check=True, stdout=sys.stdout, stderr=sys.stderr)
    except subprocess.CalledProcessError as exc:
        print('Dependency installation failed', file=sys.stderr)
        sys.exit(5)

for suite, command, output_dir, report in commands:
    print(f'Executing {suite} command: {command}', file=sys.stdout)
    suite_start = datetime.utcnow()
    try:
        subprocess.run(['bash', '-lc', f'cd "{working_directory}" && {command}'], check=True, stdout=sys.stdout, stderr=sys.stderr)
        status = 'passed'
        exit_code = 0
    except subprocess.CalledProcessError as exc:
        status = 'failed'
        exit_code = exc.returncode

    duration = (datetime.utcnow() - suite_start).total_seconds()
    suite_metadata = {
        'capability': suite,
        'status': status,
        'command': command,
        'framework': 'node_scripts',
        'total_tests': None,
        'passed': None,
        'failed': None,
        'skipped': None,
        'duration_seconds': duration,
        'report': report['report'] if report else None,
    }
    write_json(os.path.join(output_dir, 'report.json'), {
        'suite': suite,
        'status': status,
        'command': command,
        'duration_seconds': duration,
    })
    write_json(os.path.join(output_dir, 'metadata.json'), suite_metadata)
    results.append(suite_metadata)
    if exit_code != 0:
        print(f'{suite.capitalize()} suite failed', file=sys.stderr)
        final_status = 'failed'
        break
else:
    final_status = 'passed'

end_time = datetime.utcnow()
duration_seconds = (end_time - start_time).total_seconds()

build_metadata = {
    'capability': 'build',
    'status': final_status if build_enabled else 'skipped',
    'technology': language,
    'runtime': version,
    'runtime_actual': node_version,
    'package_manager': package_manager,
    'working_directory': build_cfg.get('working_directory', '.'),
    'command': build_command if build_enabled else None,
    'start_time': start_time.isoformat() + 'Z',
    'end_time': end_time.isoformat() + 'Z',
    'duration_seconds': duration_seconds,
    'artifacts': [],
    'results': [r for r in results if r['capability'] == 'build'],
}
write_json(os.path.join(build_dir, 'metadata.json'), build_metadata)
write_json(os.path.join(build_dir, 'report.json'), {'results': results})

sys.exit(0 if final_status == 'passed' else 5)
PY

EXIT_CODE=$?
if [ "$EXIT_CODE" -eq 0 ]; then
  log_info "Build & Test provider completed successfully"
else
  if [ "$EXIT_CODE" -eq "$PLATFORM_EXIT_CONFIG" ]; then
    log_error "Build & Test provider failed due to configuration error"
  elif [ "$EXIT_CODE" -eq "$PLATFORM_EXIT_TOOL_MISSING" ]; then
    log_error "Build & Test provider failed because a required runtime/tool is missing"
  else
    log_error "Build & Test provider failed with exit code $EXIT_CODE"
  fi
fi
exit "$EXIT_CODE"