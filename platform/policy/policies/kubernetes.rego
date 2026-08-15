package main


#
# Kubernetes containers must not run as root.
#

deny contains {
    "policy_id": "kubernetes/container-non-root",
    "severity": "high",
    "msg": "Container must explicitly set securityContext.runAsNonRoot to true",
} if {
    input.kind == "Deployment"

    container := input.spec.template.spec.containers[_]

    not container.securityContext.runAsNonRoot
}


#
# Kubernetes containers should define resource requests and limits.
#

warn contains {
    "policy_id": "kubernetes/container-resources",
    "severity": "medium",
    "msg": "Container should define CPU and memory requests and limits",
} if {
    input.kind == "Deployment"

    container := input.spec.template.spec.containers[_]

    not container.resources.requests
}

warn contains {
    "policy_id": "kubernetes/container-resources",
    "severity": "medium",
    "msg": "Container should define CPU and memory requests and limits",
} if {
    input.kind == "Deployment"

    container := input.spec.template.spec.containers[_]

    not container.resources.limits
}


#
# Container images should not use the mutable "latest" tag.
#

warn contains {
    "policy_id": "kubernetes/container-image-tag",
    "severity": "medium",
    "msg": "Container image should use an explicit version instead of the latest tag",
} if {
    input.kind == "Deployment"

    container := input.spec.template.spec.containers[_]

    endswith(container.image, ":latest")
}


#
# NodePort services should not be exposed by default.
#

warn contains {
    "policy_id": "kubernetes/service-nodeport",
    "severity": "medium",
    "msg": "Service should not use NodePort unless explicitly required",
} if {
    input.kind == "Service"

    input.spec.type == "NodePort"
}