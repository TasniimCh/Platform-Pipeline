import os
import subprocess
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[2]
GITOPS_SCRIPT = REPO_ROOT / "platform" / "gitops" / "run.sh"


def test_gitops_update_updates_digest_and_commits(tmp_path):
    project_root = tmp_path / "project"
    project_root.mkdir()

    gitops_repo = tmp_path / "gitops-repo"
    gitops_repo.mkdir()

    subprocess.run(
        ["git", "init", "-b", "main"],
        cwd=str(gitops_repo),
        check=True,
        capture_output=True,
        text=True,
    )
    subprocess.run(
        ["git", "config", "user.name", "Platform Bot"],
        cwd=str(gitops_repo),
        check=True,
    )
    subprocess.run(
        ["git", "config", "user.email", "platform@example.com"],
        cwd=str(gitops_repo),
        check=True,
    )

    values_file = gitops_repo / "helm" / "values.yaml"
    values_file.parent.mkdir(parents=True, exist_ok=True)
    values_file.write_text(
        "image:\n"
        "  repository: registry.example.com/my-app\n"
        "  digest: sha256:old\n",
        encoding="utf-8",
    )

    subprocess.run(["git", "add", "."], cwd=str(gitops_repo), check=True)
    subprocess.run(
        ["git", "commit", "-m", "initial values"],
        cwd=str(gitops_repo),
        check=True,
        capture_output=True,
        text=True,
    )

    config_file = project_root / ".devsecops" / "pipeline.yaml"
    config_file.parent.mkdir(parents=True, exist_ok=True)
    config_file.write_text(
        "capabilities:\n"
        "  gitops_update: true\n"
        "gitops:\n"
        "  decision: promote\n"
        "  repo_path: \"" + str(gitops_repo) + "\"\n"
        "  values_file: \"helm/values.yaml\"\n"
        "  image:\n"
        "    repository: \"registry.example.com/my-app\"\n"
        "    digest: \"sha256:newdigest\"\n"
        "  commit:\n"
        "    author_name: \"Platform Bot\"\n"
        "    author_email: \"platform@example.com\"\n",
        encoding="utf-8",
    )

    env = os.environ.copy()
    env["WORKSPACE"] = str(project_root)
    env["CONFIG_FILE"] = ".devsecops/pipeline.yaml"

    result = subprocess.run(
        ["bash", str(GITOPS_SCRIPT)],
        cwd=str(project_root),
        env=env,
        capture_output=True,
        text=True,
    )

    assert result.returncode == 0, result.stderr

    updated_values = values_file.read_text(encoding="utf-8")
    assert "sha256:newdigest" in updated_values

    commit_message = subprocess.run(
        ["git", "log", "-1", "--pretty=%B"],
        cwd=str(gitops_repo),
        check=True,
        capture_output=True,
        text=True,
    ).stdout

    assert "gitops update" in commit_message.lower()
    assert "sha256:newdigest" in commit_message
