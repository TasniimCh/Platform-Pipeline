import math

def _normalize_cvss_to_0_1(v):
    try:
        v = float(v)
    except Exception:
        return None
    v = max(0.0, min(10.0, v))
    return v / 10.0

def score_assessment(findings, scoring_policy):
    # extract features
    features = {}
    # cvss_severity: use max cvss among findings
    cvss_vals = [f.get("cvss_score") for f in findings if f.get("cvss_score") is not None]
    cvss_vals = [float(v) for v in cvss_vals if _is_number(v)]
    features_present = {}
    if cvss_vals:
        features["cvss_severity"] = _normalize_cvss_to_0_1(max(cvss_vals))
        features_present["cvss_severity"] = True
    # secret_detected: boolean if any finding has category secret
    secrets = any(f.get("category") == "secret" for f in findings)
    features["secret_detected"] = 1.0 if secrets else 0.0
    features_present["secret_detected"] = True

    # test_coverage_gap: not available in this basic implementation

    # map scoring features
    policy_features = scoring_policy.get("features", {})
    computed = {}
    available_weights = 0.0
    contributions = []
    for fname, meta in policy_features.items():
        weight = float(meta.get("weight", 0.0))
        source = meta.get("source")
        # simple mapping based on feature name implemented above
        if fname in features:
            val = features[fname]
            available_weights += weight
            computed[fname] = {"value": val, "weight": weight}
        else:
            # feature missing
            computed[fname] = {"value": None, "weight": weight}

    # failure policy: if <50% of weight covered -> insufficient evidence
    total_weight = sum(float(m.get("weight",0.0)) for m in policy_features.values()) or 1.0
    covered_ratio = available_weights / total_weight
    if covered_ratio < 0.5:
        return {
            "score": 0.0,
            "category": "insufficient_evidence",
            "contributors": [],
            "_covered_ratio": covered_ratio,
            "insufficient_evidence": True
        }

    # renormalize weights among available features
    renorm_factor = 1.0 / available_weights if available_weights > 0 else 0.0
    score = 0.0
    for fname, meta in computed.items():
        val = meta["value"]
        w = float(meta["weight"])
        if val is None:
            continue
        w_adj = w * renorm_factor
        contrib = w_adj * float(val)
        score += contrib
        contributions.append({"feature": fname, "contribution": contrib * 100.0})

    # clamp 0..1 then scale to 0..100
    score = max(0.0, min(1.0, score)) * 100.0

    return {"score": round(score, 2), "category": _bucket(score), "contributors": contributions, "_covered_ratio": covered_ratio}

def _is_number(x):
    try:
        float(x)
        return True
    except Exception:
        return False

def _bucket(score):
    # simple mapping, will be overwritten by decision step but provide a default
    if score >= 80:
        return "reject"
    if score >= 60:
        return "block"
    if score >= 30:
        return "warning"
    return "low"
