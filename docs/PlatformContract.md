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
```

The `uses:` reference should point to the platform repository and the branch, tag, or ref to execute.

## Required GitHub Secrets

This platform currently does not require secrets for the static analysis scan.
Future scanners or integrations may require secrets, and those will be documented
here when added.

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

## Compatibility Guarantees

- The platform runs as a reusable GitHub Actions workflow.
- Client repositories only need `.devsecops/pipeline.yaml` to opt in.
- The platform bootstraps the environment and standardizes scanner execution.
- Scanner implementations remain independent modules.