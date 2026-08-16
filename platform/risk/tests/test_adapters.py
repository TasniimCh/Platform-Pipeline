import json
import sys
from pathlib import Path


LIB_DIR = str(Path(__file__).resolve().parents[1] / "lib")
sys.path.insert(0, LIB_DIR)


def load_fixture(name):
    p = Path(__file__).resolve().parents[1] / "tests" / "fixtures" / name
    # adjust path because tests dir is inside platform/risk
    if not p.exists():
        p = Path(__file__).resolve().parents[1] / "fixtures" / name
    with open(p, "r") as f:
        return json.load(f)


def test_gitleaks_adapter():
    obj = load_fixture("gitleaks.json")
    from adapters.gitleaks import normalize_json

    items = normalize_json(obj, "gitleaks", "fixtures/gitleaks.json")
    assert isinstance(items, list)
    assert items[0]["tool"] == "gitleaks"
    assert items[0]["category"] == "secret"


def test_semgrep_adapter():
    obj = load_fixture("semgrep.json")
    from adapters.semgrep import normalize_json

    items = normalize_json(obj, "semgrep", "fixtures/semgrep.json")
    assert isinstance(items, list)
    assert items[0]["tool"] == "semgrep"
    assert items[0]["category"] == "code_smell"


def test_snyk_adapter():
    obj = load_fixture("snyk.json")
    from adapters.snyk import normalize_json

    items = normalize_json(obj, "snyk", "fixtures/snyk.json")
    assert isinstance(items, list)
    assert items[0]["tool"] == "snyk"
    assert items[0]["category"] == "cve"


def test_checkov_adapter():
    obj = load_fixture("checkov.json")
    from adapters.checkov import normalize_json

    items = normalize_json(obj, "checkov", "fixtures/checkov.json")
    assert isinstance(items, list)
    assert items[0]["tool"] == "checkov"
    assert items[0]["category"] == "misconfig"
