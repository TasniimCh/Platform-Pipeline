#!/usr/bin/env python3
import os
import sys
import json
import hashlib
from pathlib import Path

ROOT = Path(__file__).resolve().parent
ADAPTERS = ROOT / "adapters"

def collect_input_files(report_dir: Path):
    files = []
    for p in report_dir.rglob("*.json"):
        files.append(p)
    return files

def load_yaml(path):
    try:
        import yaml
    except Exception:
        raise RuntimeError("PyYAML is required: pip install pyyaml")
    with open(path, "r") as f:
        return yaml.safe_load(f)

def sha256_hex(s: str) -> str:
    return hashlib.sha256(s.encode("utf-8")).hexdigest()

def main():
    report_dir = Path(os.environ.get("REPORT_DIR", ".devsecops/reports"))
    out_dir = report_dir / "risk"
    out_dir.mkdir(parents=True, exist_ok=True)

    files = collect_input_files(report_dir)

    findings = []
    sources = set()
    for f in files:
        try:
            j = json.loads(f.read_text())
        except Exception:
            continue
        tool = f.parts[-2] if len(f.parts) >= 2 else f.stem
        sources.add(tool)
        # try tool-specific adapter, fall back to generic
        adapter_fn = None
        try:
            mod = __import__(f"platform.risk.lib.adapters.{tool}", fromlist=["normalize_json"])  # type: ignore
            adapter_fn = getattr(mod, "normalize_json", None)
        except Exception:
            try:
                # try package-relative import
                mod = __import__(f"adapters.{tool}", fromlist=["normalize_json"])  # type: ignore
                adapter_fn = getattr(mod, "normalize_json", None)
            except Exception:
                adapter_fn = None

        if not adapter_fn:
            from adapters.generic import normalize_json as adapter_fn

        items = adapter_fn(j, tool, str(f))
        findings.extend(items)

    # dedupe
    from dedupe import dedupe_findings
    deduped = dedupe_findings(findings)

    # scoring
    policies_dir = Path(__file__).resolve().parent.parent / "policies" / "v0"
    scoring = load_yaml(policies_dir / "scoring.yaml")
    decision = load_yaml(policies_dir / "decision.yaml")

    from score import score_assessment
    scored = score_assessment(deduped, scoring)

    from explain import explain_assessment
    explanation = explain_assessment(scored)

    from decide import decide_action
    # If insufficient evidence, force manual_approval minimum
    if scored.get("insufficient_evidence"):
        action = "manual_approval"
    else:
        action = decide_action(scored.get("score", 0.0), decision)

    # ensure category is explicit
    category = scored.get("category", "low")


    assessment = {
        "input_evidence": {
            "sources_available": sorted(list(sources)),
            "sources_missing": [],
            "findings_count_raw": len(findings),
            "findings_count_deduplicated": len(deduped),
            "input_evidence_hash": "sha256:" + sha256_hex(json.dumps([f.get('finding_id') for f in deduped]))
        },
        "risk_assessment": {
            "score": scored.get("score", 0.0),
            "category": category,
            "contributors": scored.get("contributors", [])
        },
        "explanation": explanation,
        "decision_reference": {
            "decision_policy_version": decision.get("version", "unknown"),
            "action": action,
            "insufficient_evidence": bool(scored.get("insufficient_evidence", False))
        },
        "audit": {
            "scoring_policy_version": scoring.get("version", "unknown")
        }
    }

    out_file = out_dir / "assessment.json"
    out_file.write_text(json.dumps(assessment, indent=2))
    print(f"Wrote assessment to {out_file}")

if __name__ == "__main__":
    main()
