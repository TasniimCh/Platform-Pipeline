# Getting Started with the DevSecOps Platform

This document helps client repositories adopt the reusable DevSecOps Platform pipeline.

## Prerequisites

- The client repository uses GitHub Actions.
- The client repository has a workflow that invokes the platform's reusable workflow.
- A `.devsecops/pipeline.yaml` file is optional; it is only required for customization.

## Repository Structure

Client repositories should include:

```
.github/workflows/
.devsecops/
  pipeline.yaml
src/
```

The platform only requires `.devsecops/pipeline.yaml` in the client repository.

## Add the Platform Workflow

Create a GitHub Actions workflow in the client repository, for example:

`.github/workflows/security-pipeline.yml`

```yaml
name: DevSecOps Security Pipeline

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

## Configure the Snyk Token

The platform uses Snyk for dependency analysis.

If Snyk is enabled, the client repository must provide a SNYK_TOKEN GitHub Actions secret.

1. Get the Snyk token

Create or retrieve an API token from your Snyk account under:

Account Settings → API Token

If Snyk is already authenticated locally, the token can also be retrieved with:

snyk config get api
2. Store the token in GitHub

In the client repository:

Settings → Secrets and variables → Actions → New repository secret

Create:

Name: SNYK_TOKEN
Value: <your Snyk API token>

## Optional `.devsecops/pipeline.yaml`

The platform can run with defaults and does not require `.devsecops/pipeline.yaml`.
Use the file only when you want to customize capability selection.

Preferred capability-based configuration:

```yaml
capabilities:
  secret_detection: true
  static_analysis: true
  dependency_analysis: true
  infrastructure_analysis: true
  build: false
  unit_testing: false
  integration_testing: false
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
```

Legacy scanner-specific configuration is still supported for compatibility:

```yaml
scanners:
  gitleaks:
    enabled: true
    args: []
  semgrep:
    enabled: true
    args: []
  snyk:
    enabled: true
    args: []
  checkov:
    enabled: true
    args: []
```

## Pipeline Capabilities

Each capability below can be toggled independently in `.devsecops/pipeline.yaml`.
Enabling a capability with missing prerequisites causes the corresponding job to fail with a configuration error. The platform never fails silently.

| Capability | Default | Prerequisites | What it does |
|---|---|---|---|
| `secret_detection` | `true` | None | Runs Gitleaks |
| `static_analysis` | `true` | None | Runs Semgrep |
| `dependency_analysis` | `true` | `SNYK_TOKEN` secret | Runs Snyk |
| `infrastructure_analysis` | `true` | None | Runs Checkov |
| `build` | `false` | `package.json` with a resolvable build command | Runs the build step |
| `unit_testing` | `false` | `package.json` with `scripts.test` or an explicit unit-test command | Runs unit tests |
| `integration_testing` | `false` | `package.json` with `scripts.integration` or an explicit integration-test command | Runs integration tests |
| `container_build` | `false` | Dockerfile at the configured path | Builds the container image |
| `container_scan` | `false` | `container_build: true` | Runs Trivy on the built image |
| `sbom` | `false` | `container_build: true` | Generates a CycloneDX SBOM via Syft |
| `provenance` | `false` | `container_build: true` | Generates a SLSA provenance predicate |
| `image_publish` | `false` | `container_build: true`; `DOCKERHUB_USERNAME` and `DOCKERHUB_TOKEN` available in the client repo | Logs into Docker Hub, pushes the commit-tagged image, and resolves the registry digest for downstream supply-chain evidence |
| `image_signing` | `false` | `container_build: true`; `id-token: write` permission on the calling workflow; registry must support OCI referrers for keyless mode | Signs the image and provenance attestation with Cosign |
| `policy_enforcement` | `false` | Kubernetes manifests or Helm chart present in the repo | Runs Conftest against the configured policy paths |
| `gitops_update` | `false` | GitOps repository write access; risk decision must be `promote` | Updates the image digest in the GitOps repository and triggers ArgoCD sync |
| `admission_control` | `false` | Platform-side: Kyverno installed on the target cluster and ClusterPolicies applied | Enforces cluster admission policies for deployment integrity |
| `cluster_validation` | `false` | `gitops_update: true`; CI job has cluster access credentials; ArgoCD application exists for the client | Waits for rollout health and runs application-owned smoke tests on the DEV deployment |
| `risk_assessment` | platform-managed | At least one upstream capability enabled; partial evidence is tolerated | Aggregates evidence into a weighted risk score and a `promote`/`manual_approval`/`block`/`reject` decision |

### Additional secrets required, by capability

| Secret | Required when |
|---|---|
| `SNYK_TOKEN` | `dependency_analysis: true` |
| `DOCKERHUB_USERNAME` / `DOCKERHUB_TOKEN` | `image_publish: true` or `container_build: true` when the flow includes a registry push |
| GitOps repo credential (TBD, for example `GITOPS_DEPLOY_TOKEN`) | `gitops_update: true` |
| Cluster access credential (TBD, for example `CLUSTER_ACCESS_TOKEN` or OIDC role ARN) | `cluster_validation: true` |

### One-time platform-side setup

The following are configured once by the platform team, not by each client repository:

- Kyverno and ArgoCD installed on the target cluster.
- An ArgoCD `AppProject` and `Application` registered for the client namespace.
- Vault paths and Kubernetes auth roles scoped to the client's namespace if secrets are used.
- CI-to-cluster access configured with least-privilege RBAC; never `cluster-admin`.

Contact the platform team before enabling `gitops_update`, `admission_control`, or `cluster_validation`.

## Understanding pipeline outcomes

The pipeline can finish without a deployment even when the scanner stage is green. This happens when the Risk Advisor decides to `block`, `reject`, or require `manual_approval`.

That outcome is expected and is not a scan failure. It represents the final deployment gate for the promotion decision, which is why the pipeline can be green from a static-analysis perspective while still refusing deployment for policy or risk reasons.

## Review Generated Reports

After a workflow run, the platform writes standardized reports into the `.devsecops/reports` tree.

Risk assessment evidence is written under:

```
.devsecops/reports/risk/assessment.json
```

GitOps update evidence is written under:

```
.devsecops/reports/gitops/
```

Cluster validation evidence is written under:

```
.devsecops/reports/cluster-validation/
```

The workflow uploads the relevant artifacts by stage. Scanner outputs remain scoped per tool under:

```
.devsecops/reports/<tool>/
```

Container and supply-chain evidence is written under:

```
.devsecops/reports/container/<image-id-or-digest>/
```

Each image-specific folder contains `report.json` and `metadata.json`, plus tool-native outputs such as Trivy or SBOM files.

## Platform Contract

The platform contract is documented in `docs/PlatformContract.md`.
It defines:

- required repository structure
- supported workflow inputs
- configuration schema
- generated report formats
- compatibility guarantees
- deprecation and versioning expectations