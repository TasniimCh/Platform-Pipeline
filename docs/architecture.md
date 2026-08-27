# Global Architecture — DevSecOps Platform V0

## 1. Purpose

This document describes the global architecture of the reusable DevSecOps platform and the end-to-end V0 software delivery lifecycle.

The platform is designed around six implemented delivery/security phases plus a future runtime-observability extension.

The key architectural principles are:

- capabilities decide **whether** a platform function runs;
- provider configuration decides **how** an enabled capability runs;
- independent phases execute in parallel where possible;
- artifacts and findings are normalized into machine-readable evidence;
- container and deployment identity use immutable image digests;
- the Risk Advisor assesses risk;
- the Decision Engine converts risk into a deployment action;
- GitOps stores desired deployment state;
- Argo CD reconciles that state with Kubernetes;
- cluster/runtime validation determines whether the deployed workload actually became healthy;
- security and deployment decisions remain traceable and reproducible.

---

# 2. End-to-End V0 Software Lifecycle

```text
┌──────────────────────────────────────────────────────────────────────────────┐
│                        DEVSECOPS SOFTWARE LIFECYCLE                          │
└──────────────────────────────────────────────────────────────────────────────┘

                               Source Repository
                                      │
                                      │ commit
                                      ▼
                         ┌────────────────────────┐
                         │      Bootstrap         │
                         │ config + capabilities  │
                         └───────────┬────────────┘
                                     │
                                     ▼
                         ┌────────────────────────┐
                         │ Credential Validation  │
                         │ capability-aware only  │
                         └───────────┬────────────┘
                                     │
               ┌─────────────────────┼─────────────────────┐
               │                     │                     │
               ▼                     ▼                     ▼
       ┌───────────────┐     ┌───────────────┐     ┌──────────────────┐
       │ Code Security │     │ Build & Test  │     │ Policy           │
       │ Analysis      │     │               │     │ Enforcement      │
       │               │     │ Build         │     │                  │
       │ Semgrep       │     │ Unit Tests    │     │ Helm/K8s        │
       │ Snyk          │     │ Integration   │     │ Conftest / OPA  │
       │ Checkov       │     │               │     │                  │
       │ Gitleaks(*)   │     └───────┬───────┘     └─────────┬────────┘
       └───────┬───────┘             │                       │
               │                     │                       │
               └──────────────┬──────┴──────────────┬────────┘
                              │                     │
                              ▼                     │
                  ┌────────────────────────┐        │
                  │ Container / Supply     │        │
                  │ Chain                  │        │
                  │                        │        │
                  │ Build image once       │        │
                  │ Trivy                  │        │
                  │ SBOM / Syft            │        │
                  │ Provenance             │        │
                  │ Publish                │        │
                  │ Digest                 │        │
                  │ Sign / Attest          │        │
                  └───────────┬────────────┘        │
                              │                     │
                              └─────────────┬───────┘
                                            ▼
                                ┌──────────────────────┐
                                │ AI Risk Advisor      │
                                │                      │
                                │ Collect              │
                                │ Normalize            │
                                │ Deduplicate          │
                                │ Score                │
                                │ Explain              │
                                └───────────┬──────────┘
                                            │
                                            ▼
                                ┌──────────────────────┐
                                │ Decision Engine      │
                                │ versioned thresholds │
                                └───────────┬──────────┘
                                            │
                   ┌────────────────────────┼────────────────────────┐
                   │                        │                        │
                   ▼                        ▼                        ▼
               promote              manual_approval          block / reject
                   │                        │                        │
                   │                  human gate                     │
                   │                        │                        │
                   └───────────────┬────────┘                        │
                                   │                                 │
                                   ▼                                 │
                           ┌──────────────────┐                       │
                           │ GitOps Update    │                       │
                           │                  │                       │
                           │ image.repository │                       │
                           │ image.digest     │                       │
                           │ commit + push    │                       │
                           └────────┬─────────┘                       │
                                    │                                 │
                                    ▼                                 │
                           ┌──────────────────┐                       │
                           │ GitOps Repo      │                       │
                           │ Source of Truth  │                       │
                           └────────┬─────────┘                       │
                                    │                                 │
                                    ▼                                 │
                           ┌──────────────────┐                       │
                           │ Argo CD          │                       │
                           │ DEV sync         │                       │
                           └────────┬─────────┘                       │
                                    │                                 │
                                    ▼                                 │
                           ┌──────────────────┐                       │
                           │ DEV Kubernetes   │                       │
                           └────────┬─────────┘                       │
                                    │                                 │
                                    ▼                                 │
                           ┌──────────────────┐                       │
                           │ Cluster &        │                       │
                           │ Runtime          │                       │
                           │ Validation       │                       │
                           │                  │                       │
                           │ Admission(*)     │                       │
                           │ Rollout          │                       │
                           │ Smoke Tests      │                       │
                           └────────┬─────────┘                       │
                                    │                                 │
                                    ▼                                 │
                              DEV Validated                           │
                                                                      │
                                    future                            │
                                      │                               │
                                      ▼                               │
                          Runtime Observability                       │
                                      │                               │
                                      ▼                               │
                              Runtime Evidence                        │
                                      │                               │
                                      ▼                               │
                          Future Runtime AI / KB                       │
                                                                      │
                                                                      └── STOP

(*) Capability / implementation details are described in the relevant sections.
```

---

# 3. Pipeline Stage Model

The reusable workflow is organized around capability-gated stages rather than a fully sequential chain.

```text
Bootstrap
   │
   ▼
Credential Validation
   │
   ├───────────────────────────────┐
   │                               │
   ▼                               ▼
Code Scans                    Build & Test
   │                               │
   │                               ├──────────────┐
   │                               │              │
   │                               ▼              ▼
   │                            Build          Unit Tests
   │                               │              │
   │                               └──────┬───────┘
   │                                      ▼
   │                              Integration Tests
   │
   ├─────────────────────────────────────────────┐
   │                                             │
   ▼                                             ▼
Policy Enforcement                         Supply Chain
   │                                             │
   └──────────────────────┬──────────────────────┘
                          ▼
                    Risk Assessment
                          │
                          ▼
                    Decision Engine
                          │
                          ▼
                       GitOps
                          │
                          ▼
                 Cluster Validation
```

Independent phases should execute in parallel whenever their prerequisites allow.

---

# 4. Capability Model

Capabilities are the public platform contract.

Example:

```yaml
capabilities:
  secret_detection: true
  static_analysis: true
  dependency_analysis: true
  infrastructure_analysis: true

  build: true
  unit_testing: true
  integration_testing: false

  container_build: true
  container_scan: true
  sbom: true
  provenance: true
  image_publish: true
  image_signing: true

  policy_enforcement: true

  gitops_update: true

  admission_control: false
  cluster_validation: true
```

The design rule is:

```text
Capabilities
   └── decide WHETHER something runs

Configuration
   └── decides HOW an enabled capability runs
```

The platform should not maintain duplicated enablement fields such as:

```text
capability = true
+
provider.enabled = true
```

for the same function.

---

# 5. Configuration Resolution

All features consume centrally resolved effective configuration.

```text
Platform Defaults
       │
       ▼
Technology Defaults
       │
       ▼
Client Configuration
       │
       ▼
Explicit Workflow Inputs
       │
       ▼
Effective Configuration
```

Resolution must occur before provider execution.

The configuration layer is responsible for:

- merging defaults and client configuration;
- resolving capability booleans;
- exposing enabled scanner/provider mappings;
- validating ambiguous configuration;
- avoiding duplicated resolution logic across workflow jobs.

---

# 6. Static Security Analysis

The static-analysis layer produces security evidence from source and infrastructure configuration.

```text
Source Repository
      │
      ├── Secrets
      │     └── Gitleaks
      │
      ├── Static Analysis
      │     └── Semgrep
      │
      ├── Dependency Analysis
      │     └── Snyk
      │
      └── Infrastructure Analysis
            └── Checkov
```

Each scanner is capability-gated.

Provider/tool mappings remain implementation details.

Typical report layout:

```text
.devsecops/reports/
├── gitleaks/
├── semgrep/
├── snyk/
└── checkov/
```

Finding detection and tool execution failure are distinct states.

---

# 7. Build & Test Architecture

Build and Test share one dependency-preparation environment in the current Node.js provider.

```text
Resolve Config
     │
     ▼
Detect Node Project
     │
     ▼
Resolve Package Manager
     │
     ▼
Resolve Commands
     │
     ▼
Install Dependencies ONCE
     │
     ├───────────────┐
     │               │
     ▼               ▼
   Build         Unit Tests
     │               │
     └───────┬───────┘
             ▼
       Integration Tests
```

Command resolution follows:

```text
explicit client command
        >
reliable project detection
        >
deterministic provider default
```

The platform does not invent application-specific commands.

Evidence:

```text
.devsecops/reports/
├── build/
└── tests/
    ├── unit/
    └── integration/
```

---

# 8. CI Policy Enforcement

Policy Enforcement validates Kubernetes or Helm deployment definitions before deployment.

```text
Helm / Kubernetes Inputs
           │
           ▼
   Resolve / Render
           │
           ▼
Platform Policies
       +
Repository Policies
           │
           ▼
     Conftest / OPA
           │
      ┌────┴────┐
      ▼         ▼
    Pass     Findings
```

The public capability is:

```yaml
capabilities:
  policy_enforcement: true
```

The engine is currently Conftest/OPA but is not part of the client-facing contract.

Current platform baseline policies include:

```text
non-root container
resource requests/limits
no :latest image
no NodePort by default
```

CI Policy Enforcement is separate from cluster admission enforcement.

---

# 9. Container & Supply-Chain Architecture

The supply-chain phase builds the image once and derives security and provenance evidence from the same artifact.

```text
                    Source Repository
                           │
                           ▼
                    Container Build
                           │
                           ▼
                  Local Docker Image
                           │
                           ▼
                   Local Image ID
                           │
            ┌──────────────┼──────────────┐
            ▼              ▼              ▼
         Trivy           Syft        Provenance
            │              │              │
            ▼              ▼              ▼
    Vulnerability        SBOM        Build Evidence
       Report         CycloneDX
            │              │              │
            └──────────────┼──────────────┘
                           │
                           ▼
                 Local Supply-Chain Evidence
                           │
                  image_publish = true
                           │
                           ▼
                    Registry Push
                           │
                           ▼
                   Registry Digest
                           │
                           ▼
                 repository@sha256
                           │
                   image_signing = true
                           │
                   ┌───────┴────────┐
                   ▼                ▼
              Cosign Sign      Cosign Attest
```

---

# 10. Trusted Artifact Identity

Before publication:

```text
Local image identity
sha256:<docker-image-id>
```

After publication:

```text
Deployable registry identity
repository@sha256:<registry-digest>
```

These identities must not be confused.

The registry digest is the deployment identity.

```text
                    IMAGE
                      │
             repository@sha256:ABC
                      │
        ┌─────────────┼─────────────┐
        │             │             │
        ▼             ▼             ▼
      SBOM        Provenance     Signature
        │             │             │
        ▼             ▼             ▼
    Contents        Origin      Authenticity
```

The trusted artifact chain is:

```text
Source Commit
      │
      ▼
Container Build
      │
      ▼
Registry Digest
      │
      ├── Vulnerability Report
      ├── SBOM
      ├── Provenance
      ├── Signature
      └── Attestation
```

---

# 11. Image Identity Across the Platform

The same immutable registry digest should travel through all deployment-related phases.

```text
Source Commit
      │
      ▼
Container Build
      │
      ▼
Registry Digest
sha256:ABC123
      │
      ├────────► Trivy
      ├────────► SBOM
      ├────────► Provenance
      ├────────► Signature
      │
      ▼
Risk Assessment
      │
      ▼
GitOps
      │
      ▼
Helm Values
image.repository
image.digest = sha256:ABC123
      │
      ▼
Argo CD
      │
      ▼
DEV Deployment
      │
      ▼
Future Admission Verification
```

The platform must avoid:

```text
scanned:   my-app@sha256:ABC
deployed:  my-app:latest
```

The target is always:

```text
scanned   = sha256:ABC
approved  = sha256:ABC
deployed  = sha256:ABC
```

---

# 12. AI Risk Advisor

The Risk Advisor consumes existing machine-readable evidence.

```text
Pipeline Reports
      │
      ▼
Collect
      │
      ▼
Normalize
      │
      ▼
Canonical Findings
      │
      ▼
Deduplicate
      │
      ▼
Deterministic Scoring
      │
      ▼
Explanation
      │
      ▼
Risk Assessment
```

Current V0 is deterministic.

No ML is required for risk calculation.

Canonical findings provide a stable cross-tool schema.

```json
{
  "finding_id": "...",
  "tool": "snyk",
  "severity": "high",
  "cvss_score": 7.5,
  "component": "openssl",
  "category": "cve",
  "confidence": 1.0,
  "cwe_ids": [],
  "cve_ids": ["CVE-..."]
}
```

---

# 13. Deterministic Risk Scoring

Current scoring policy is versioned.

Conceptually:

```text
Risk Score = Σ(weight × normalized feature)
```

Feature examples:

```text
CVSS severity
secret detection
Kubernetes privilege risk
internet exposure
dependency exploitability
historical incidents
coverage gap
policy violations
```

The Risk Advisor produces:

```text
score
category
contributors
explanation
evidence status
```

The score is not itself the deployment decision.

---

# 14. Decision Engine

The Decision Engine translates risk into deployment action.

```text
Risk Assessment
      │
      ▼
Versioned Threshold Policy
      │
      ▼
Deployment Action
```

Current policy model:

```text
0–30      → promote
31–60     → manual_approval
61–80     → block
81–100    → reject
```

Conceptual decision flow:

```text
Risk Score
    │
    ├── low      ─────► promote
    ├── warning  ─────► manual_approval
    ├── block    ─────► block
    └── reject   ─────► reject
```

Insufficient evidence must never silently produce automatic promotion.

```text
insufficient evidence
        │
        ▼
manual_approval minimum
```

---

# 15. Risk / Decision Separation

This separation is architectural.

```text
┌────────────────────────┐
│ Risk Advisor           │
│                        │
│ What is the risk?      │
│                        │
│ score                  │
│ category               │
│ contributors           │
│ explanation            │
└────────────┬───────────┘
             │
             ▼
┌────────────────────────┐
│ Decision Engine        │
│                        │
│ What should happen?    │
│                        │
│ promote                │
│ manual_approval        │
│ block                  │
│ reject                 │
└────────────────────────┘
```

Scoring weights and deployment thresholds can evolve independently.

---

# 16. CD / GitOps Architecture

The CI pipeline does not directly deploy application manifests to Kubernetes.

Its deployment responsibility is to update desired state in Git.

```text
Risk Decision
      │
      ├── block / reject ─────────────► STOP
      │
      ├── manual_approval ────────────► Human Gate
      │                                  │
      └── promote ───────────────────────┘
                                         │
                                         ▼
                              Resolve Immutable Image
                                         │
                          repository@sha256:digest
                                         │
                                         ▼
                                  GitOps Update
                                         │
                            image.repository
                            image.digest
                                         │
                                         ▼
                                  Commit + Push
                                         │
                                         ▼
                                   GitOps Repo
                                   Source of Truth
```

---

# 17. Image Resolution for GitOps

Image resolution is centralized.

```text
platform/platform/gitops/resolve-image.sh
```

Exactly two valid sources exist.

```text
Source A
Pipeline-published image
    │
    ▼
container metadata
    │
    ▼
published == true
    │
    ▼
registry_repository + image_digest
```

```text
Source B
Externally supplied image
    │
    ▼
IMAGE_REPOSITORY + IMAGE_DIGEST
    │
    ▼
validate immutable identity
```

External inputs have priority.

If neither source provides a valid immutable image, GitOps promotion fails.

---

# 18. GitOps Desired State

The GitOps repository is the deployment source of truth.

```text
GitOps Repository
      │
      ├── Helm Chart
      ├── Values
      └── Future Secret References
```

The platform modifies only the semantic deployment image identity:

```yaml
image:
  repository: username/my-app
  digest: sha256:...
```

Git history becomes part of the deployment audit trail.

Typical commit metadata connects:

```text
Application
Image Digest
Source Commit
CI Run
Risk Decision
```

---

# 19. Secret Management Boundary

The target architecture must never commit plaintext application secrets to Git.

Planned model:

```text
GitOps Repository
       │
       │ ExternalSecret reference
       ▼
External Secrets
       │
       ▼
HashiCorp Vault
       │
       ▼
Kubernetes Secret
       │
       ▼
Application
```

This is planned architecture and is not yet a complete V0 implementation.

---

# 20. Argo CD and Kubernetes

The GitOps repository defines desired state.

Argo CD reconciles that state into Kubernetes.

Current V0 implementation uses explicit synchronization:

```text
GitOps Repository
      │
      ▼
Argo CD Application
      │
      ▼
argocd app sync
      │
      ▼
argocd app wait
      │
      ▼
Synced + Healthy
```

The generated Argo CD Application currently uses:

```yaml
syncPolicy: {}
```

Therefore V0 is currently **explicit CI-triggered DEV synchronization**, not native Argo CD auto-sync.

Continuous auto-sync may be introduced later.

---

# 21. Cluster & Runtime Validation

After Argo CD synchronization:

```text
DEV Kubernetes
      │
      ▼
Cluster Validation
      │
      ├── Admission Control
      ├── Rollout Validation
      └── Smoke Tests
      │
      ▼
DEV Validated
```

The provider answers:

```text
Did the workload actually become healthy?
```

This is different from static security scanning.

---

# 22. Admission-Control Architecture

Admission control is the future authoritative cluster security boundary.

```text
Git
 ↓
Argo CD
 ↓
Kubernetes API Server
 ↓
Admission Controller
 ↓
ALLOW / DENY
 ↓
Workload
```

Target admission checks include:

```text
immutable image digest
approved registry
image signature
provenance
Pod Security
privileged containers
root execution
host networking
service account controls
resource policies
```

Current `admission.sh` is still a validation stub, so these controls are architectural targets rather than completed V0 guarantees.

---

# 23. Defense in Depth

The platform uses two policy enforcement points.

```text
                    Policy Definition
                          │
             ┌────────────┴────────────┐
             │                         │
             ▼                         ▼
      CI Policy Enforcement      Cluster Admission
        Conftest / OPA             Kyverno
             │                         │
             ▼                         ▼
        Shift Left                Last Boundary
```

This provides:

```text
preventive validation
        +
runtime enforcement
```

rather than relying on one control plane.

---

# 24. Rollout Validation

After synchronization:

```text
Deployment
     │
     ▼
kubectl rollout status
     │
     ▼
Desired replicas
Ready replicas
Available replicas
     │
     ▼
Container-state inspection
     │
     ▼
PASS / FAIL
```

Current unhealthy states include:

```text
CrashLoopBackOff
ImagePullBackOff
ErrImagePull
```

A deployment passes only when expected replica state is reached.

---

# 25. Smoke Tests

Smoke tests target the deployed DEV application.

```text
Incorrect
Source Repository
     │
     ▼
npm test
     │
     ▼
"deployment healthy"
```

Correct:

```text
Built Artifact
     │
     ▼
DEV Deployment
     │
     ▼
Application Endpoint
     │
     ▼
Smoke Tests
     │
     ▼
Runtime Validation
```

The platform orchestrates smoke testing.

The application owns application-specific smoke-test logic.

---

# 26. V0 Environment Model

Current environment support:

```text
DEV
 ├── GitOps update
 ├── Argo CD synchronization
 ├── rollout validation
 └── smoke tests
```

Planned later:

```text
DEV
 │
 ▼
STAGING
 ├── admission
 ├── rollout
 ├── smoke
 ├── DAST
 ├── security testing
 └── performance testing
 │
 ▼
PROD
 ├── controlled promotion
 ├── admission
 └── explicit approval
```

The same immutable image should be promoted between environments.

```text
Build Once
    │
    ▼
sha256:ABC
    │
    ├── DEV
    ├── STAGING
    └── PROD
```

No rebuild per environment.

---

# 27. Future Runtime Observability

The next architectural extension begins after successful DEV validation.

```text
Validated DEV Workload
       │
       ▼
Runtime Observability
       │
       ├── metrics
       ├── logs
       ├── runtime security events
       └── incident evidence
       │
       ▼
Runtime Evidence
       │
       ▼
Future Runtime AI
       │
       ▼
Knowledge Base
       │
       ▼
Feedback into future risk models
```

Potential technologies may include:

```text
Prometheus
Falco
runtime telemetry
incident history
```

These are not part of the current V0 delivery implementation.

---

# 28. Evidence Architecture

Each phase produces machine-readable evidence.

```text
.devsecops/reports/
│
├── gitleaks/
├── semgrep/
├── snyk/
├── checkov/
│
├── build/
├── tests/
│
├── policy/
│
├── container/
│
├── risk/
│
├── gitops/
│
└── cluster-validation/
```

The pipeline is therefore an evidence chain:

```text
SOURCE
  │
  ▼
Static Evidence
  │
  ▼
Build/Test Evidence
  │
  ▼
Supply-Chain Evidence
  │
  ▼
Policy Evidence
  │
  ▼
Risk Assessment
  │
  ▼
Deployment Decision
  │
  ▼
Desired Deployment State
  │
  ▼
Cluster / Runtime Evidence
```

---

# 29. Artifact / Evidence Relationship

```text
                         Source Commit
                              │
                              ▼
                         Build Result
                              │
                              ▼
                       Container Image
                              │
                              ▼
                       Registry Digest
                              │
        ┌─────────────────────┼─────────────────────┐
        │                     │                     │
        ▼                     ▼                     ▼
      SBOM                Provenance          Vulnerabilities
        │                     │                     │
        └─────────────────────┼─────────────────────┘
                              │
                              ▼
                         Risk Assessment
                              │
                              ▼
                       Deployment Decision
                              │
                              ▼
                           GitOps
                              │
                              ▼
                       Runtime Validation
```

The immutable digest is the primary artifact identity connecting supply-chain and deployment evidence.

---

# 30. Platform Failure Model

Platform scripts use a common exit-code contract.

| Code | Meaning | Example |
| ---: | --- | --- |
| `0` | `SUCCESS` | Provider executed successfully |
| `1` | `FAILURE` | Unexpected/general platform failure |
| `2` | `CONFIGURATION_ERROR` | Invalid or missing configuration |
| `3` | `DEPENDENCY_ERROR` | Required tool/runtime unavailable |
| `4` | `FINDINGS_DETECTED` | Security/policy findings detected |
| `5` | `EXECUTION_ERROR` | Tool/provider runtime execution error |

Key rule:

```text
findings detected
      ≠
tool execution failure
```

For example:

```text
Trivy runs successfully and finds CVEs
      → evidence / risk input

Trivy crashes or cannot execute
      → execution failure
```

---

# 31. Fail-Safe Deployment Principle

The platform must never silently promote because a security or decision component failed.

```text
No assessment
      ≠
low risk

No decision
      ≠
promote

Insufficient evidence
      ≠
promote

Missing immutable image
      ≠
deploy

Failed rollout
      ≠
successful deployment
```

The safe default is explicit failure, blocking, or manual review.

---

# 32. GitHub Actions Responsibility

GitHub Actions is the orchestration adapter.

It is responsible for:

```text
checkout
job scheduling
capability gates
secret injection
tool installation
artifact upload/download
provider invocation
```

Provider code is responsible for domain logic.

```text
.github/workflows/pipeline.yml
        │
        ▼
Platform Providers
        │
        ├── scanners/
        ├── build-test/
        ├── policy/
        ├── container/
        ├── risk/
        ├── gitops/
        └── cluster-validation/
```

GitHub-specific context should not leak unnecessarily into provider implementations.

---

# 33. Secret Exposure Model

Secrets should only be available where needed.

```text
SNYK_TOKEN
    → Snyk only

DOCKERHUB_USERNAME
DOCKERHUB_TOKEN
    → image publication only

GITOPS_TOKEN
    → GitOps / private Argo CD repository access only
```

Disabled capabilities must not require unrelated secrets.

---

# 34. Tool Installation Model

Tools should be capability-gated.

```text
Semgrep capability       → Semgrep
Dependency analysis      → Snyk
IaC analysis             → Checkov
Secret detection         → Gitleaks

Policy enforcement       → Conftest

Container scan           → Trivy
SBOM                     → Syft
Image signing            → Cosign

Admission control        → Kyverno
```

A disabled capability should not cause its tool to be installed unnecessarily.

---

# 35. V0 vs Future Architecture

```text
┌──────────────────────────── V0 ──────────────────────────────┐
│                                                              │
│ Source                                                       │
│   ↓                                                          │
│ Static Security                                              │
│   ↓                                                          │
│ Build / Test                                                 │
│   ↓                                                          │
│ Policy Enforcement                                           │
│   ↓                                                          │
│ Container / Supply Chain                                     │
│   ↓                                                          │
│ Risk Advisor                                                 │
│   ↓                                                          │
│ Decision Engine                                              │
│   ↓                                                          │
│ GitOps                                                       │
│   ↓                                                          │
│ Argo CD                                                      │
│   ↓                                                          │
│ DEV Rollout + Smoke                                          │
│                                                              │
└──────────────────────────────────────────────────────────────┘

                           │
                           │ future
                           ▼

┌────────────────────── Future Extensions ─────────────────────┐
│                                                              │
│ Full admission enforcement                                   │
│ Signature/provenance verification at admission               │
│ External Secrets + Vault                                     │
│ STAGING                                                      │
│ DAST                                                         │
│ Performance/security testing                                 │
│ PROD approval                                                │
│ Progressive delivery                                         │
│ Automated rollback                                           │
│ Runtime observability                                        │
│ Runtime AI                                                   │
│ ML-assisted risk scoring                                     │
│ Knowledge/feedback loop                                      │
│                                                              │
└──────────────────────────────────────────────────────────────┘
```

---

# 36. Global Trust Chain

The complete platform trust chain is:

```text
Developer
    │
    ▼
Source Commit
    │
    ▼
Static Security Evidence
    │
    ▼
Build/Test Evidence
    │
    ▼
Container Artifact
    │
    ▼
Immutable Registry Digest
    │
    ├── Vulnerability Evidence
    ├── SBOM
    ├── Provenance
    ├── Signature
    └── Attestation
    │
    ▼
Risk Assessment
    │
    ▼
Decision Policy
    │
    ▼
Deployment Authorization
    │
    ▼
GitOps Desired State
    │
    ▼
Argo CD Synchronization
    │
    ▼
Kubernetes Runtime State
    │
    ▼
Cluster Validation Evidence
```

---

# 37. Global Architecture View

```text
                         ┌─────────────────────┐
                         │ Developer / Source  │
                         └──────────┬──────────┘
                                    │
                                    ▼
┌──────────────────────────────────────────────────────────────────────┐
│                       DEVSECOPS CI PLATFORM                          │
│                                                                      │
│  Bootstrap + Config Resolution                                      │
│             │                                                        │
│             ▼                                                        │
│  Credential Validation                                              │
│             │                                                        │
│     ┌───────┼───────────────────┐                                   │
│     ▼       ▼                   ▼                                   │
│ Code Scans  Build/Test      Policy Enforcement                      │
│     │       │                   │                                   │
│     └───────┼───────────┬───────┘                                   │
│             │           │                                           │
│             ▼           ▼                                           │
│        Supply Chain Evidence                                        │
│             │                                                       │
│             ▼                                                       │
│        AI Risk Advisor                                              │
│             │                                                       │
│             ▼                                                       │
│        Decision Engine                                              │
└─────────────┬────────────────────────────────────────────────────────┘
              │
              │ promote / approved
              ▼
┌──────────────────────────────────────────────────────────────────────┐
│                         GITOPS PROVIDER                              │
│                                                                      │
│  Resolve immutable image                                             │
│          │                                                           │
│          ▼                                                           │
│  Update Helm image.repository + image.digest                         │
│          │                                                           │
│          ▼                                                           │
│  Commit deployment audit metadata                                    │
│          │                                                           │
│          ▼                                                           │
│  Push desired state                                                   │
└─────────────┬────────────────────────────────────────────────────────┘
              │
              ▼
       ┌──────────────────────┐
       │ GitOps Repository    │
       │ Source of Truth      │
       └──────────┬───────────┘
                  │
                  ▼
       ┌──────────────────────┐
       │ Argo CD              │
       │ DEV Synchronization  │
       └──────────┬───────────┘
                  │
                  ▼
┌──────────────────────────────────────────────────────────────────────┐
│                           DEV KUBERNETES                             │
│                                                                      │
│  Kubernetes API                                                      │
│        │                                                             │
│        ▼                                                             │
│  Admission Control (*)                                               │
│        │                                                             │
│        ▼                                                             │
│  Deployment / Pods                                                   │
│        │                                                             │
│        ├───────────────┐                                             │
│        ▼               ▼                                             │
│  Rollout Status    Smoke Tests                                       │
│        │               │                                             │
│        └───────┬───────┘                                             │
│                ▼                                                     │
│          DEV Validation                                              │
└────────────────┬─────────────────────────────────────────────────────┘
                 │
                 ▼
         Cluster Runtime Evidence
                 │
                 │ future
                 ▼
      Observability / Runtime AI

(*) Full blocking admission enforcement is a future extension; the current
    admission provider remains incomplete/stubbed.
```

---

# 38. Core Architectural Invariants

The V0 platform should preserve these rules:

```text
Resolve configuration once.

Gate every capability explicitly.

Do not install tools for disabled capabilities.

Do not require secrets for disabled capabilities.

Install application dependencies once.

Build the application once.

Build the container once.

Analyze the same artifact.

Publish once.

Deploy by immutable registry digest.

Keep findings separate from execution failures.

Keep Risk Advisor separate from Decision Engine.

Never auto-promote insufficient evidence.

Git is the deployment source of truth.

CI does not directly deploy application manifests.

Argo CD reconciles deployment state.

Cluster validation determines actual deployment health.

Machine-readable evidence is authoritative.

Console logs are diagnostic.

Future ML must not break the deterministic V0 contract.
```

---

# 39. Repository-Level Platform Structure

Conceptually:

```text
platform/
│
├── bootstrap/
│   ├── bootstrap.sh
│   ├── install-tools.sh
│   └── validate-secrets.sh
│
├── config/
│   └── config.sh
│
├── scanners/
│   └── run-scanner.sh
│
├── build-test/
│   └── run.sh
│
├── policy/
│   ├── run.sh
│   ├── resolve.sh
│   ├── render-helm.sh
│   └── policies/
│
├── container/
│   ├── run.sh
│   ├── publish.sh
│   ├── sign.sh
│   └── attest.sh
│
├── risk/
│   ├── run.sh
│   ├── lib/
│   ├── schemas/
│   ├── policies/
│   └── tests/
│
├── gitops/
│   ├── run.sh
│   └── resolve-image.sh
│
└── cluster-validation/
    ├── run.sh
    ├── install-argocd.sh
    ├── install-kyverno.sh
    ├── sync-argocd.sh
    ├── admission.sh
    ├── rollout.sh
    └── smoke-tests.sh
```

---

# 40. Final V0 System Contract

Given:

```text
a source repository
+
client capability/configuration
+
required credentials
+
an available CI execution environment
```

the platform can produce:

```text
1. Static security evidence

2. Build and test evidence

3. Policy-enforcement evidence

4. A container artifact

5. Vulnerability, SBOM, provenance, signing and publication evidence

6. A deterministic risk assessment

7. A deterministic deployment action

8. An immutable GitOps deployment update

9. DEV Argo CD synchronization

10. DEV rollout/runtime validation evidence
```

The resulting end-to-end chain is:

```text
SOURCE
  │
  ▼
SECURITY EVIDENCE
  │
  ▼
BUILD EVIDENCE
  │
  ▼
TRUSTED ARTIFACT
  │
  ▼
RISK ASSESSMENT
  │
  ▼
DEPLOYMENT DECISION
  │
  ▼
GITOPS DESIRED STATE
  │
  ▼
DEV RUNTIME STATE
  │
  ▼
VALIDATED DEV WORKLOAD
```