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

For compatibility, the platform also accepts legacy scanner-specific configuration under `scanners:`.

The platform validates that client configuration contains either a `capabilities:` section or a `scanners:` section with supported entries.

## Generated Reports

The platform writes standardized reports to:

```
.devsecops/reports/<scanner>/
```

The platform emits:

- `report.json`: raw scanners findings in JSON format
- `metadata.json`: standardized metadata for platform consumption

The full report contract is:

```
.devsecops/reports/<scanner>/
  report.json
  metadata.json
```

The platform also uploads `.devsecops/reports` as a workflow artifact named `devsecops-reports`.

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