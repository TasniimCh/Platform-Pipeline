# AI-Driven DevSecOps Pipeline with Intelligent Risk Scoring

This repository contains the implementation of an **intelligent DevSecOps pipeline** designed to secure the lifecycle of **MEAN stack** (MongoDB, Express, Angular, Node.js) modules. Developed as part of a Research and Development initiative at **Smart Automation Technologies**, this platform integrates automated security controls with an **AI-driven decision engine** to evaluate security risks before deployment.

## Overview

The core objective of this project is to transform fragmented security tool outputs into a unified, explicable risk score. Unlike traditional pipelines that may be easily bypassed or act as "black boxes," this system follows the principle that **AI is consultative, never sovereign**; it calculates a risk score that informs deterministic, versioned rules for deployment decisions.

## Architecture & Pipeline Phases

The pipeline is structured into 7 sequential phases, shifting security "to the left" to detect vulnerabilities as early as possible.

### Phase 1: CI Static Analysis (Parallel)
Executes four security controls in parallel to reduce pipeline time.
*   **Secret Scanning**: Fail-fast check using Gitleaks or TruffleHog.
*   **SAST**: Application code analysis via Semgrep or SonarQube.
*   **SCA**: Dependency vulnerability scanning using Snyk or npm audit.
*   **IaC Scan**: Infrastructure manifest validation with Checkov or Terrascan.

### Phase 2: Build & Supply Chain Security
*   **Build**: Containerized testing environment (Mongo/Express).
*   **Container Scan**: Image vulnerability detection with Trivy.
*   **Supply Chain**: Generates a **SBOM** (Syft), attests provenance (SLSA/in-toto), and signs images (Cosign) to ensure integrity.

### Phase 3: Policy Testing (Preventative)
*   Tests Helm manifests against cluster policies using **Conftest** and **OPA** before merging. This prevents deployment-time rejections by catching policy violations in the CI phase.

### Phase 4: Decision (AI Risk Advisor)
*   **AI Risk Advisor**: Aggregates results from previous phases, de-duplicates findings, and produces a risk score with **feature attribution** for explainability.
*   **Deterministic Rules**: A Git-versioned policy translates the AI score into a decision: **Reject**, **Manual Approval**, or **Promote**.

### Phase 5: CD / GitOps
*   **Orchestration**: Managed via **ArgoCD** with declarative sync.
*   **Secret Management**: Uses **Sealed Secrets** or SOPS, integrated with **HashiCorp Vault** via External Secrets Operator.

### Phase 6: Cluster & Runtime Validation
*   **Admission Control**: Kyverno or OPA Gatekeeper enforces policies (image signatures, provenance) at the cluster level.
*   **DAST**: Dynamic analysis and NoSQL injection testing using **OWASP ZAP** in the staging environment.

### Phase 7: Post-Deployment Observability
*   **Runtime Monitoring**: Uses Falco for syscall anomalies and Prometheus/Grafana for metrics.
*   **AI Runtime Analysis**: Calculates confidence scores on detected anomalies to trigger alerts or "Circuit Breakers" (e.g., pod quarantine) with human confirmation.

## Key Features

*   **Intelligent Scoring**: Aggregates SAST, SCA, Secrets, and Image scan results into a single metric.
*   **Explainability**: Every rejection includes the specific rule triggered and the evidence from the AI advisor.
*   **Closed Loop Learning**: A **Knowledge Base** historizes incidents, which are periodically reviewed by a security committee to improve CI rules.
*   **Interactive Dashboard**: Provides a visual history of runs, module security status, and automatic notifications.

## Tech Stack Summary

| Category | Tools |
| :--- | :--- |
| **Languages/Frameworks** | MEAN Stack (MongoDB, Express, Angular, Node.js) |
| **CI/CD** | GitHub Actions / Jenkins, ArgoCD |
| **Security (Static)** | Semgrep, Snyk, Gitleaks, Checkov, Trivy |
| **Security (Dynamic/Runtime)** | OWASP ZAP, Falco, Kyverno |
| **Infrastructure** | Kubernetes, Helm, Terraform |
| **Observability** | Prometheus, Grafana, Loki, OpenTelemetry |

## Platform Usage

This repository exposes a reusable static analysis workflow at `.github/workflows/ci-static-analysis.yml`.
A client repository can invoke it with:

```yaml
jobs:
  security:
    uses: TasniimCh/Platform-Pipeline/.github/workflows/pipeline.yml@master
```

The platform bootstraps the environment, loads default capability configuration, optionally merges a client `.devsecops/pipeline.yaml`, installs required scanner CLI tools, runs enabled scanners in parallel, publishes standardized `.devsecops/reports/`, and uploads those reports as workflow artifacts.

## Contract Document

The platform contract is defined in `docs/PlatformContract.md`.
It specifies repository structure, workflow inputs, pipeline schema, generated reports, compatibility guarantees, and versioning policy.

---

# Repository Structure

```
devsecops-platform/

.github/
├── workflows/        # Reusable workflow orchestration
└── actions/          # Composite Actions exposing platform capabilities

platform/
├── bootstrap/        # Environment preparation
├── scanners/         # Scanner implementations
├── lib/              # Shared reusable libraries
├── config/           # Configuration schema and validation
├── templates/        # Report and configuration templates
└── scripts/          # Shared platform utilities

docs/                 # Architecture and platform documentation
```