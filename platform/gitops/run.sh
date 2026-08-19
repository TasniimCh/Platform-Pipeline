#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)
PLATFORM_ROOT=$(cd "$SCRIPT_DIR/.." >/dev/null 2>&1 && pwd)

source "$PLATFORM_ROOT/lib/constants.sh"
source "$PLATFORM_ROOT/lib/logging.sh"
source "$PLATFORM_ROOT/config/config.sh"

: "${WORKSPACE:=${PWD}}"
: "${CONFIG_FILE:=.devsecops/pipeline.yaml}"
: "${LOG_LEVEL:=info}"
: "${GITOPS_REPO_PATH:=}"
: "${GITOPS_VALUES_FILE:=}"
: "${GITOPS_DECISION:=}"
: "${IMAGE_REPOSITORY:=}"
: "${IMAGE_DIGEST:=}"
: "${GITOPS_REF:=main}"

export WORKSPACE
export CONFIG_FILE
export LOG_LEVEL
export GITOPS_REPO_PATH
export GITOPS_VALUES_FILE
export GITOPS_DECISION
export IMAGE_REPOSITORY
export IMAGE_DIGEST
export GITOPS_REF

log_info "Starting GitOps update provider"
log_info "Workspace: $WORKSPACE"
log_info "Configuration: $WORKSPACE/$CONFIG_FILE"

config_json=$(load_merged_config_json "$WORKSPACE" "$CONFIG_FILE") || {
  log_error "Failed to load merged platform configuration"
  exit "$PLATFORM_EXIT_CONFIG"
}

CONFIG_JSON="$config_json" python3 - <<'PY'
import json
import os
import sys

config = json.loads(os.environ.get("CONFIG_JSON", "{}"))
capabilities = config.get("capabilities", {})

if not capabilities.get("gitops_update", False):
    print("GitOps update capability is disabled; skipping")
    sys.exit(0)

gitops = config.get("gitops", {})
if not isinstance(gitops, dict):
    raise SystemExit("Configuration validation failed: 'gitops' must be a mapping")

decision = str(
    os.environ.get("GITOPS_DECISION")
    or gitops.get("decision")
    or "promote"
).strip().lower()

if decision not in ("promote", "manual_approval"):
     raise SystemExit(
        f"GitOps update requires a valid decision; received '{decision}'."
    )

repo_path = str(os.environ.get("GITOPS_REPO_PATH") or gitops.get("repo_path") or "").strip()
values_file = str(os.environ.get("GITOPS_VALUES_FILE") or gitops.get("values_file") or "").strip()
image_repository = str(os.environ.get("IMAGE_REPOSITORY") or gitops.get("image", {}).get("repository") or "").strip()
image_digest = str(os.environ.get("IMAGE_DIGEST") or gitops.get("image", {}).get("digest") or "").strip()
commit_cfg = gitops.get("commit", {})
if not isinstance(commit_cfg, dict):
    raise SystemExit("Configuration validation failed: 'gitops.commit' must be a mapping")

if not repo_path:
    raise SystemExit("Environment validation failed: GITOPS_REPO_PATH is required")
if not values_file:
    raise SystemExit("Environment validation failed: GITOPS_VALUES_FILE is required")
if not image_repository:
    raise SystemExit("Environment validation failed: IMAGE_REPOSITORY is required")
if not image_digest:
    raise SystemExit("Environment validation failed: IMAGE_DIGEST is required")

commit_cfg.setdefault("author_name", "Platform Bot")
commit_cfg.setdefault("author_email", "platform@example.com")

print(json.dumps({
    "decision": decision,
    "repo_path": repo_path,
    "values_file": values_file,
    "image_repository": image_repository,
    "image_digest": image_digest,
    "commit_author_name": commit_cfg.get("author_name"),
    "commit_author_email": commit_cfg.get("author_email"),
}))
PY

if [ "$?" -ne 0 ]; then
  log_error "Invalid GitOps configuration"
  exit "$PLATFORM_EXIT_CONFIG"
fi

python3 - "$WORKSPACE" "$config_json" <<'PY'
import json
import os
import sys
from pathlib import Path
import yaml

workspace = Path(sys.argv[1]).resolve()
config = json.loads(sys.argv[2])

gitops = config.get("gitops", {})
repo_path = Path(str(os.environ.get("GITOPS_REPO_PATH") or gitops.get("repo_path") or "").strip()).expanduser()
if not repo_path.is_absolute():
    repo_path = (workspace / repo_path).resolve()

values_file = Path(str(os.environ.get("GITOPS_VALUES_FILE") or gitops.get("values_file") or "").strip()).expanduser()
if not values_file.is_absolute():
    values_file = (repo_path / values_file).resolve()

image_repository = str(os.environ.get("IMAGE_REPOSITORY") or gitops.get("image", {}).get("repository") or "").strip()
image_digest = str(os.environ.get("IMAGE_DIGEST") or gitops.get("image", {}).get("digest") or "").strip()

if not repo_path.exists():
    raise SystemExit(f"GitOps repository does not exist: {repo_path}")
if not values_file.exists():
    raise SystemExit(f"GitOps values file does not exist: {values_file}")

with open(values_file, "r", encoding="utf-8") as handle:
    original_text = handle.read()
    document = yaml.safe_load(original_text) or {}

if not isinstance(document, dict):
    raise SystemExit(f"GitOps values file must contain a YAML mapping: {values_file}")

image = document.setdefault("image", {})
if not isinstance(image, dict):
    raise SystemExit(f"'image' section in '{values_file}' must be a mapping")

image["repository"] = image_repository
image["digest"] = image_digest

updated_text = yaml.safe_dump(document, sort_keys=False)
if original_text != updated_text:
    with open(values_file, "w", encoding="utf-8") as handle:
        handle.write(updated_text)

print(str(values_file))
PY

repo_root=$(git -C "${GITOPS_REPO_PATH}" rev-parse --show-toplevel 2>/dev/null || true)
if [ -z "$repo_root" ]; then
  log_error "GitOps repository path is not a Git repository: ${GITOPS_REPO_PATH}"
  exit "$PLATFORM_EXIT_EXECUTION"
fi

values_path="$(python3 - "$GITOPS_REPO_PATH" "$GITOPS_VALUES_FILE" <<'PY'
import os
import sys
from pathlib import Path
repo_root = Path(sys.argv[1]).expanduser().resolve()
values_arg = sys.argv[2].strip()
values_path = Path(values_arg).expanduser()
if not values_path.is_absolute():
    values_path = (repo_root / values_path).resolve()
print(str(values_path))
PY
)"

rel_values_path=$(python3 - "$values_path" "$repo_root" <<'PY'
import os
import sys
from pathlib import Path
value_path = Path(sys.argv[1]).resolve()
repo_root = Path(sys.argv[2]).resolve()
print(os.path.relpath(value_path, repo_root))
PY
)

if ! git -C "$repo_root" diff --quiet -- "$rel_values_path"; then
  set +e
  git -C "$repo_root" add -- "$rel_values_path"
  set -e

  if ! git -C "$repo_root" diff --cached --quiet; then
    decision=$(printf '%s' "${GITOPS_DECISION:-promote}" | tr '[:upper:]' '[:lower:]')
    app_name=$(printf '%s' "${IMAGE_REPOSITORY:-application}" | sed 's#^.*\/##')
    image_digest_value="${IMAGE_DIGEST:-unknown}"
    source_commit=$(printf '%s' "${GITHUB_SHA:-${GIT_COMMIT:-unknown}}")
    ci_run=$(printf '%s' "${GITHUB_RUN_ID:-${CI_RUN_ID:-unknown}}")
    author_name=$(python3 - <<'PY'
import json, os
config = json.loads(os.environ.get("CONFIG_JSON", "{}"))
commit_cfg = config.get("gitops", {}).get("commit", {})
if not isinstance(commit_cfg, dict):
    commit_cfg = {}
print((commit_cfg.get("author_name") or os.environ.get("GIT_AUTHOR_NAME") or "Platform Bot").strip())
PY
)
    author_email=$(python3 - <<'PY'
import json, os
config = json.loads(os.environ.get("CONFIG_JSON", "{}"))
commit_cfg = config.get("gitops", {}).get("commit", {})
if not isinstance(commit_cfg, dict):
    commit_cfg = {}
print((commit_cfg.get("author_email") or os.environ.get("GIT_AUTHOR_EMAIL") or "platform@example.com").strip())
PY
)

    commit_title="gitops update: ${app_name} ${image_digest_value}"
    commit_body=$(cat <<EOF
Application: ${app_name}
Image Digest: ${image_digest_value}
Source Commit: ${source_commit}
CI Run: ${ci_run}
Risk Assessment: ${decision}
EOF
)

    git -C "$repo_root" -c user.name="$author_name" -c user.email="$author_email" commit -m "$commit_title" -m "$commit_body"
    if git -C "$repo_root" remote get-url origin >/dev/null 2>&1; then

        if [ -z "${GITOPS_TOKEN:-}" ]; then
            log_error "GITOPS_TOKEN is required for GitOps push"
            exit "$PLATFORM_EXIT_EXECUTION"
        fi

        remote_url="$(git -C "$repo_root" remote get-url origin)"

        if [[ "$remote_url" =~ github.com/([^/]+/[^/.]+)(\.git)?$ ]]; then
            gitops_repo="${BASH_REMATCH[1]}"
        else
            log_error "Unable to determine GitHub repository from origin URL"
            exit "$PLATFORM_EXIT_EXECUTION"
        fi

        git -C "$repo_root" remote set-url origin \
            "https://x-access-token:${GITOPS_TOKEN}@github.com/${gitops_repo}.git"

        git -C "$repo_root" push origin "HEAD:${GITOPS_REF:-main}"

        log_info "GitOps deployment state updated in $repo_root"
    else
      log_info "GitOps repository has no configured origin; local commit created at $repo_root"
    fi
  else
    log_info "No GitOps changes required"
  fi
else
  log_info "No GitOps changes required"
fi

log_info "GitOps update completed successfully"
