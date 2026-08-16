"""Generic adapter: best-effort normalization for different scanner JSONs.

This adapter produces a list of canonical findings with fields required by
the pipeline. It is intentionally conservative and preserves raw input via
`raw_ref`.
"""
import json
import hashlib
from typing import List


def _make_id(obj: dict) -> str:
    s = json.dumps(obj, sort_keys=True)
    return hashlib.sha256(s.encode("utf-8")).hexdigest()


def normalize_json(obj, tool: str, raw_ref: str) -> List[dict]:
    items = []
    # Heuristics for common shapes
    if isinstance(obj, dict) and "findings" in obj and isinstance(obj["findings"], list):
        raw_items = obj["findings"]
    elif isinstance(obj, dict) and "results" in obj and isinstance(obj["results"], list):
        raw_items = obj["results"]
    elif isinstance(obj, list):
        raw_items = obj
    else:
        # fallback to wrapping the whole object
        raw_items = [obj]

    for r in raw_items:
        c = {}
        c["tool"] = tool
        # best-effort fields
        c["finding_id"] = _make_id(r)
        c["severity_raw"] = r.get("severity") if isinstance(r, dict) else None
        c["cvss_score"] = r.get("cvss") or r.get("cvssScore") or r.get("cvss_score") if isinstance(r, dict) else None
        c["component"] = r.get("component") if isinstance(r, dict) else None
        # category heuristics
        try:
            blob = json.dumps(r).lower()
        except Exception:
            blob = ""
        if "secret" in blob or (isinstance(r, dict) and "secret" in (r.get("title", "") + r.get("message", "")).lower()):
            c["category"] = "secret"
        elif isinstance(r, dict) and (r.get("type") in ("vuln", "vulnerability") or r.get("cve") or r.get("cve_id")):
            c["category"] = "cve"
        else:
            c["category"] = "code_smell"

        c["severity"] = _map_severity(c["severity_raw"]) if c["severity_raw"] else "info"
        c["confidence"] = _map_confidence(r)
        c["affected_file"] = r.get("file") or r.get("path") if isinstance(r, dict) else None
        c["recommendation"] = r.get("recommendation") if isinstance(r, dict) else None
        c["cwe_ids"] = r.get("cwe") and [r.get("cwe")] or r.get("cwe_ids") or [] if isinstance(r, dict) else []
        c["cve_ids"] = []
        if isinstance(r, dict):
            if r.get("cve"):
                c["cve_ids"].append(r.get("cve"))
            if r.get("cve_id"):
                c["cve_ids"].append(r.get("cve_id"))
        c["raw_ref"] = {"source": raw_ref, "payload": r}

        items.append(c)

    return items


def _map_severity(raw):
    if raw is None:
        return "info"
    s = str(raw).lower()
    if s in ("critical", "crit", "sev0"):
        return "critical"
    if s in ("high", "sev1"):
        return "high"
    if s in ("medium", "med", "sev2"):
        return "medium"
    if s in ("low", "sev3"):
        return "low"
    return "info"


def _map_confidence(r):
    if not isinstance(r, dict):
        return 0.5
    if "confidence" in r:
        try:
            v = float(r["confidence"])
            return max(0.0, min(1.0, v))
        except Exception:
            pass
    return 0.5
