def dedupe_findings(findings):
    """Deduplicate findings strictly by CVE id when present (v0.1 strict mode).

    If multiple findings share a cve_id, keep one merged record.
    """
    seen = {}
    no_cve = []
    for f in findings:
        cves = f.get("cve_ids") or []
        if cves:
            for c in cves:
                if c in seen:
                    # merge: keep max confidence and worst severity
                    existing = seen[c]
                    existing["confidence"] = max(existing.get("confidence", 0.0), f.get("confidence", 0.0))
                    # severity order
                    order = ["info", "low", "medium", "high", "critical"]
                    if order.index(f.get("severity","info")) > order.index(existing.get("severity","info")):
                        existing["severity"] = f.get("severity")
                    existing.setdefault("raw_ref", []).append(f.get("raw_ref"))
                else:
                    seen[c] = dict(f)
                    seen[c]["raw_ref"] = [f.get("raw_ref")]
        else:
            no_cve.append(f)

    # return deduped list: all unique cve entries plus others
    return list(seen.values()) + no_cve
