# DevSecOps Platform Contract

## Purpose

This document defines the reusable platform contract for client repositories.
It is the single source of truth for configuration, workflow inputs, generated
reports, compatibility guarantees, and repository structure.

## Supported Repository Structure

Client repositories must contain:

```
repository/
  .github/
  src/
  package.json
```

Client repositories may also include a platform configuration file:

```
.devsecops/pipeline.yaml
```

If `.devsecops/pipeline.yaml` is absent, the platform uses internal defaults for capability-based scanning.

Client repositories also need a GitHub Actions workflow that calls the platform's reusable pipeline.

## Workflow Inputs

The reusable workflow exposes these inputs:

- `workspace` (optional): Path to the client repository root. Defaults to `${{ github.workspace }}`.
- `config-file` (optional): Path to the platform configuration file relative to the workspace. Defaults to `.devsecops/pipeline.yaml`.
- `report-directory` (optional): Path to the reports directory relative to the workspace. Defaults to `.devsecops/reports`.
- `log-level` (optional): Logging verbosity. Defaults to `info`.

## Reusable Workflow Invocation

Client repositories must invoke the reusable workflow from the platform repository using `workflow_call`.
A minimal example looks like:

```yaml
name: DevSecOps Pipeline

on:
  push:
    branches:
      - main
  pull_request:

jobs:
  security:
    uses: TasniimCh/Platform-Pipeline/.github/workflows/pipeline.yml@master
    with:
      workspace: ${{ github.workspace }}
      config-file: .devsecops/pipeline.yaml
      report-directory: .devsecops/reports
      log-level: info
    secrets: inherit
```

The `uses:` reference should point to the platform repository and the branch, tag, or ref to execute.

secrets: inherit allows the reusable workflow to access the client repository's GitHub Actions secrets.

## Required GitHub Secrets

The platform currently requires the following secret:

| Secret | Required | Used by | Description |
|---|---|---|---|
| `SNYK_TOKEN` | Yes* | Snyk | Snyk API authentication token |

\* `SNYK_TOKEN` is required by the current reusable workflow contract. It must be configured in the client repository under **Settings → Secrets and variables → Actions**.

The token must not be committed to the repository or stored in `.devsecops/pipeline.yaml`.

## Pipeline capabilities

The public contract is capability-based. The same platform behavior can be implemented with different vendor tools behind the same capability boundary; client repositories only configure capabilities, not vendor implementations.

| Capability | Default | Prerequisites | Primary effect |
|---|---|---|---|
| `secret_detection` | `true` | None | Runs Gitleaks |
| `static_analysis` | `true` | None | Runs Semgrep |
| `dependency_analysis` | `true` | `SNYK_TOKEN` secret | Runs Snyk |
| `infrastructure_analysis` | `true` | None | Runs Checkov |
| `build` | `false` | A resolvable build command for the repository | Builds the application |
| `unit_testing` | `false` | Unit test command or package script | Executes unit tests |
| `integration_testing` | `false` | Integration test command or package script | Executes integration tests |
| `container_build` | `false` | Dockerfile and registry configuration | Produces the OCI image |
| `container_scan` | `false` | `container_build: true` | Runs image scanning with Trivy |
| `sbom` | `false` | `container_build: true` | Produces an SBOM |
| `provenance` | `false` | `container_build: true` | Produces a provenance predicate |
| `image_signing` | `false` | `container_build: true`, OIDC token permission, registry support for OCI referrers | Signs the image and its provenance attestation |
| `policy_enforcement` | `false` | Policy files or chart manifests | Runs policy validation before deployment |
| `gitops_update` | `false` | GitOps repo write access and a valid promotion decision | Updates the image digest in the GitOps repo |
| `admission_control` | `false` | Platform-side Kyverno installed and policy bundle applied | Enforces admission-time policy on the cluster |
| `cluster_validation` | `false` | `gitops_update: true`, cluster access, and an ArgoCD application for the repo | Waits for rollout and executes smoke tests |
| `risk_assessment` | platform-managed | Upstream evidence available | Produces the weighted risk assessment and `promote`/`manual_approval`/`block`/`reject` decision |

`scoring.yaml`, `decision.yaml`, and Kyverno policy bundles are platform-managed artifacts and are versioned outside client configuration. Client compatibility is preserved as long as the `.devsecops/pipeline.yaml` schema remains stable.

## `pipeline.yaml` Schema

Client repositories may provide a YAML configuration file at `.devsecops/pipeline.yaml`.
If the file is absent, the platform loads default capabilities internally.

The preferred public contract is capability-based configuration:

```yaml
capabilities:
  secret_detection: true
  static_analysis: true
  dependency_analysis: true
  infrastructure_analysis: true
  build: false
  unit_testing: false
  integration_testing: false
  container_build: false
  container_scan: false
  sbom: false
  provenance: false
  policy_enforcement: false
  gitops_update: false
  image_signing: false
  admission_control: false
  cluster_validation: false

build:
  working_directory: .
  runtime:
    language: node
    version: "22"
    package_manager: null
  command: null

testing:
  working_directory: .
  unit:
    enabled: true
    command: null
  integration:
    enabled: false
    command: null

container:
  dockerfile: ./Dockerfile
  context: .
  image:
    name: application
    tag: null
  registry:
    type: dockerhub
    repository: null

cluster_validation:
  environment: dev
  rollout:
    timeout_seconds: 180
    poll_interval_seconds: 5
  smoke_tests:
    enabled: true
    timeout_seconds: 120
    command: null

policy:
  paths: []
  policy_paths: []
```

For compatibility, the platform also accepts legacy scanner-specific configuration under `scanners:`.

The platform validates that client configuration contains either a `capabilities:` section or a `scanners:` section with supported entries.

## Generated Reports

The platform writes standardized reports to:

```
.devsecops/reports/<stage>/
```

The following report locations are part of the public contract:

```
.devsecops/reports/build/
.devsecops/reports/tests/
.devsecops/reports/policy/
.devsecops/reports/container/
.devsecops/reports/risk/assessment.json
.devsecops/reports/gitops/
.devsecops/reports/cluster-validation/
```

The platform emits:

- `report.json`: raw scanner findings in JSON format
- `metadata.json`: standardized metadata for platform consumption
- `assessment.json`: risk assessment artifact with score, category, contributors, explanation, and decision reference
- `summary.json` and per-phase metadata for cluster validation when the capability is enabled

The full phase report contract is:

```
.devsecops/reports/<stage>/
  report.json
  metadata.json
```

Risk assessment output is a structured artifact as defined by the Risk Advisor specification:

```json
{
  "decision_reference": {
    "action": "promote",
    "insufficient_evidence": false
  },
  "risk_assessment": {
    "score": 0,
    "category": "low",
    "contributors": []
  }
}
```

Cluster validation output conforms to the runtime evidence model:

```json
{
  "capability": "cluster_validation",
  "status": "passed",
  "environment": "dev",
  "phases": ["admission", "rollout", "smoke_tests"]
}
```

The platform also uploads `.devsecops/reports` as workflow artifacts at the relevant stage boundaries.

## Exit Code Contract

Scanner modules use standardized platform exit codes:

| Code | Constant | Meaning |
|---:|---|---|
| 0 | `PLATFORM_EXIT_SUCCESS` | Scan completed successfully with no findings |
| 1 | `PLATFORM_EXIT_FAILURE` | Generic platform failure |
| 2 | `PLATFORM_EXIT_CONFIG` | Configuration error |
| 3 | `PLATFORM_EXIT_TOOL_MISSING` | Required scanner tool is unavailable |
| 4 | `PLATFORM_EXIT_FINDINGS` | Security findings detected |
| 5 | `PLATFORM_EXIT_EXECUTION` | Scanner execution failed |

Scanner-specific native exit codes must be translated into these platform-level exit codes before being returned by the scanner module.

## Compatibility Guarantees

- The platform runs as a reusable GitHub Actions workflow.
- Client repositories only need `.devsecops/pipeline.yaml` to opt in.
- The platform bootstraps the environment and standardizes scanner execution.
- Scanner implementations remain independent modules.