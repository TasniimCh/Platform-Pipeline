"""Adapter for Snyk JSON output (best-effort)."""
from typing import List

def normalize_json(obj, tool: str, raw_ref: str) -> List[dict]:
    items = []
    vulns = obj.get("vulnerabilities") if isinstance(obj, dict) else obj
    if vulns is None:
        vulns = [obj]
    for r in vulns:
        finding = {}
        finding["tool"] = "snyk"
        finding["finding_id"] = r.get("id") or r.get("title") or str(hash(str(r)))
        finding["severity_raw"] = r.get("severity") or "medium"
        finding["cvss_score"] = r.get("cvssScore") or r.get("cvss")
        finding["component"] = r.get("packageName") or r.get("moduleName")
        finding["category"] = "cve"
        finding["confidence"] = 1.0
        finding["affected_file"] = None
        finding["recommendation"] = r.get("fix") or r.get("recommendation")
        finding["cwe_ids"] = r.get("cwe") and [r.get("cwe")] or []
        finding["cve_ids"] = [r.get("id")] if r.get("id") and str(r.get("id")).upper().startswith("CVE") else (r.get("identifiers") and r.get("identifiers").get("CVE") or [])
        finding["raw_ref"] = {"source": raw_ref, "payload": r}
        items.append(finding)
    return items
