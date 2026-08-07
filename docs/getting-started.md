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
```

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

## Review Generated Reports

After a workflow run, the platform writes standardized reports into:

```
.devsecops/reports/<scanner>/
```

The workflow uploads the entire `.devsecops/reports` directory as an artifact named `devsecops-reports`.

## Platform Contract

The platform contract is documented in `docs/PlatformContract.md`.
It defines:

- required repository structure
- supported workflow inputs
- configuration schema
- generated report formats
- compatibility guarantees
- deprecation and versioning expectations