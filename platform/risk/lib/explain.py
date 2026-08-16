def explain_assessment(scored):
    # produce structured explanation per spec
    top = []
    for c in scored.get("contributors", [])[:5]:
        top.append({
            "feature": c.get("feature"),
            "contribution": round(c.get("contribution", 0.0), 2)
        })

    return {
        "top_contributors": top,
        "summary_structured": {
            "covered_ratio": scored.get("_covered_ratio")
        }
    }
