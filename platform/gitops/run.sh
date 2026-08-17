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

export WORKSPACE
export CONFIG_FILE
export LOG_LEVEL

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
    or config.get("gitops", {}).get("decision")
    or "promote"
).strip().lower()

if decision not in {"promote", "approved"}:
    raise SystemExit(
        "Configuration validation failed: 'gitops.decision' must be 'promote' or 'approved' before updating GitOps state"
    )

repo_path = gitops.get("repo_path")
values_file = gitops.get("values_file")
image_cfg = gitops.get("image", {})
commit_cfg = gitops.get("commit", {})

if not isinstance(repo_path, str) or not repo_path.strip():
    raise SystemExit("Configuration validation failed: 'gitops.repo_path' is required")

if not isinstance(values_file, str) or not values_file.strip():
    raise SystemExit("Configuration validation failed: 'gitops.values_file' is required")

if not isinstance(image_cfg, dict):
    raise SystemExit("Configuration validation failed: 'gitops.image' must be a mapping")

if not isinstance(commit_cfg, dict):
    raise SystemExit("Configuration validation failed: 'gitops.commit' must be a mapping")

if not isinstance(image_cfg.get("digest"), str) or not image_cfg["digest"].strip():
    raise SystemExit("Configuration validation failed: 'gitops.image.digest' is required")

if not isinstance(image_cfg.get("repository"), str) or not image_cfg["repository"].strip():
    raise SystemExit("Configuration validation failed: 'gitops.image.repository' is required")

if not isinstance(commit_cfg.get("author_name"), str) or not commit_cfg["author_name"].strip():
    commit_cfg["author_name"] = "Platform Bot"

if not isinstance(commit_cfg.get("author_email"), str) or not commit_cfg["author_email"].strip():
    commit_cfg["author_email"] = "platform@example.com"

print(json.dumps({
    "decision": decision,
    "repo_path": repo_path,
    "values_file": values_file,
    "image_repository": image_cfg["repository"],
    "image_digest": image_cfg["digest"],
    "commit_author_name": commit_cfg["author_name"],
    "commit_author_email": commit_cfg["author_email"],
}))
PY

if [ "$?" -ne 0 ]; then
  log_error "Invalid GitOps configuration"
  exit "$PLATFORM_EXIT_CONFIG"
fi

python3 - "$config_json" "$WORKSPACE" <<'PY'
import json
import os
import sys
from pathlib import Path
import yaml

config = json.loads(sys.argv[1])
workspace = Path(sys.argv[2]).resolve()

gitops = config.get("gitops", {})
repo_path = Path(gitops["repo_path"]).expanduser()
if not repo_path.is_absolute():
    repo_path = (workspace / repo_path).resolve()

values_file = Path(gitops["values_file"]).expanduser()
if not values_file.is_absolute():
    values_file = (repo_path / values_file).resolve()

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

image["repository"] = gitops["image"]["repository"]
image["digest"] = gitops["image"]["digest"]

updated_text = yaml.safe_dump(document, sort_keys=False)
if original_text != updated_text:
    with open(values_file, "w", encoding="utf-8") as handle:
        handle.write(updated_text)

print(str(values_file))
PY

updated_values_file=$(
  CONFIG_JSON="$config_json" python3 - "$WORKSPACE" <<'PY'
import json
import os
import sys
from pathlib import Path

config = json.loads(os.environ.get("CONFIG_JSON", "{}"))
workspace = Path(sys.argv[1]).resolve()
gitops = config.get("gitops", {})
repo_path = Path(gitops["repo_path"]).expanduser()
if not repo_path.is_absolute():
    repo_path = (workspace / repo_path).resolve()
values_file = Path(gitops["values_file"]).expanduser()
if not values_file.is_absolute():
    values_file = (repo_path / values_file).resolve()
print(str(values_file))
PY
)

git_repo_root=$(git -C "$(dirname "$updated_values_file")" rev-parse --show-toplevel 2>/dev/null || true)
if [ -n "$git_repo_root" ]; then
  rel_values_path=$(python3 - "$updated_values_file" "$git_repo_root" <<'PY'
import os, sys
from pathlib import Path
value_path = Path(sys.argv[1]).resolve()
repo_root = Path(sys.argv[2]).resolve()
print(os.path.relpath(value_path, repo_root))
PY
)

  if ! git -C "$git_repo_root" diff --quiet -- "$rel_values_path"; then
    set +e
    git -C "$git_repo_root" add -- "$rel_values_path"
    set -e

    if ! git -C "$git_repo_root" diff --cached --quiet; then
      decision=$(CONFIG_JSON="$config_json" python3 - <<'PY'
import json, os
config = json.loads(os.environ.get("CONFIG_JSON", "{}"))
print(str(config.get("gitops", {}).get("decision") or os.environ.get("GITOPS_DECISION") or "promote").strip())
PY
)
      app_name=$(CONFIG_JSON="$config_json" python3 - <<'PY'
import json, os
config = json.loads(os.environ.get("CONFIG_JSON", "{}"))
image_repo = config.get("gitops", {}).get("image", {}).get("repository", "application")
print(image_repo.split("/")[-1])
PY
)
      image_digest=$(CONFIG_JSON="$config_json" python3 - <<'PY'
import json, os
config = json.loads(os.environ.get("CONFIG_JSON", "{}"))
print(config.get("gitops", {}).get("image", {}).get("digest", "unknown"))
PY
)
      source_commit=$(printf '%s' "${GITHUB_SHA:-${GIT_COMMIT:-unknown}}")
      ci_run=$(printf '%s' "${GITHUB_RUN_ID:-${CI_RUN_ID:-unknown}}")
      author_name=$(CONFIG_JSON="$config_json" python3 - <<'PY'
import json, os
config = json.loads(os.environ.get("CONFIG_JSON", "{}"))
commit_cfg = config.get("gitops", {}).get("commit", {})
print(commit_cfg.get("author_name") or "Platform Bot")
PY
)
      author_email=$(CONFIG_JSON="$config_json" python3 - <<'PY'
import json, os
config = json.loads(os.environ.get("CONFIG_JSON", "{}"))
commit_cfg = config.get("gitops", {}).get("commit", {})
print(commit_cfg.get("author_email") or "platform@example.com")
PY
)
      commit_title="gitops update: ${app_name} ${image_digest}"
      commit_body=$(cat <<EOF
Application: ${app_name}
Image Digest: ${image_digest}
Source Commit: ${source_commit}
CI Run: ${ci_run}
Risk Assessment: ${decision}
EOF
)

      git -C "$git_repo_root" -c user.name="$author_name" -c user.email="$author_email" commit -m "$commit_title" -m "$commit_body"
      log_info "GitOps deployment state updated in $git_repo_root"
    else
      log_info "No GitOps changes required"
    fi
  else
    log_info "No GitOps changes required"
  fi
else
  log_info "No GitOps repository detected; skipping GitOps update"
fi

log_info "GitOps update completed successfully"
