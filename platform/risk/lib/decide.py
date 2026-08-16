def decide_action(score, decision_policy):
    # decision_policy: thresholds with max values
    th = decision_policy.get("thresholds", {})
    # walk ordered thresholds low->warning->block->reject
    order = ["low", "warning", "block", "reject"]
    for name in order:
        node = th.get(name)
        if not node:
            continue
        maxv = float(node.get("max", 100))
        if score <= maxv:
            actions = decision_policy.get("actions", {})
            return actions.get(name, "manual_approval")
    return "manual_approval"
