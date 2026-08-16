"""Adapter for Gitleaks JSON output (best-effort)."""
from typing import List

def normalize_json(obj, tool: str, raw_ref: str) -> List[dict]:
    items = []
    # gitleaks often outputs a list of findings
    raw_items = obj if isinstance(obj, list) else obj.get("findings") or obj.get("results") or [obj]
    for r in raw_items:
        finding = {}
        finding["tool"] = "gitleaks"
        finding["finding_id"] = r.get("rule_id") or r.get("id") or r.get("title") or str(hash(str(r)))
        finding["severity_raw"] = r.get("severity") or "medium"
        finding["cvss_score"] = None
        finding["component"] = r.get("repo") or r.get("component")
        finding["category"] = "secret"
        finding["confidence"] = 1.0
        finding["affected_file"] = r.get("file") or r.get("path")
        finding["recommendation"] = r.get("metadata", {}).get("description") if isinstance(r.get("metadata"), dict) else r.get("description")
        finding["cwe_ids"] = []
        finding["cve_ids"] = []
        finding["raw_ref"] = {"source": raw_ref, "payload": r}
        items.append(finding)
    return items
