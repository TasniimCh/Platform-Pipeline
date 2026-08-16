"""Adapter for Semgrep JSON output (best-effort)."""
from typing import List

def normalize_json(obj, tool: str, raw_ref: str) -> List[dict]:
    items = []
    results = obj.get("results") if isinstance(obj, dict) else obj
    if results is None:
        results = [obj]
    for r in results:
        finding = {}
        finding["tool"] = "semgrep"
        finding["finding_id"] = r.get("check_id") or r.get("id") or str(hash(str(r)))
        sev = None
        extra = r.get("extra") if isinstance(r, dict) else {}
        if isinstance(extra, dict):
            sev = extra.get("severity") or extra.get("precision")
        finding["severity_raw"] = sev or "medium"
        finding["cvss_score"] = None
        finding["component"] = r.get("path") or (r.get("location") or {}).get("file")
        finding["category"] = "code_smell"
        finding["confidence"] = 0.8
        finding["affected_file"] = r.get("path") or None
        finding["recommendation"] = (extra.get("message") if isinstance(extra, dict) else None) or r.get("extra", {}).get("message")
        finding["cwe_ids"] = []
        finding["cve_ids"] = []
        finding["raw_ref"] = {"source": raw_ref, "payload": r}
        items.append(finding)
    return items
