"""Adapter for Checkov JSON output (best-effort)."""
from typing import List

def normalize_json(obj, tool: str, raw_ref: str) -> List[dict]:
    items = []
    # checkov JSON often contains results.failed_checks
    failed = None
    if isinstance(obj, dict):
        failed = obj.get("results", {}).get("failed_checks") or obj.get("failed_checks")
    if failed is None:
        failed = [obj]
    for r in failed:
        finding = {}
        finding["tool"] = "checkov"
        finding["finding_id"] = r.get("check_id") or r.get("id") or str(hash(str(r)))
        finding["severity_raw"] = r.get("severity") or "medium"
        finding["cvss_score"] = None
        finding["component"] = (r.get("resource") or r.get("file_path"))
        finding["category"] = "misconfig"
        finding["confidence"] = 1.0
        finding["affected_file"] = r.get("file_path") or None
        finding["recommendation"] = r.get("guideline") or r.get("message")
        finding["cwe_ids"] = []
        finding["cve_ids"] = []
        finding["raw_ref"] = {"source": raw_ref, "payload": r}
        items.append(finding)
    return items
