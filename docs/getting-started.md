# DevSecOps Platform --- Quick Start Guide

## What is it?

The DevSecOps Platform adds reusable security and delivery controls to
your repository through one GitHub Actions workflow.

It can help you detect security issues early, verify that the
application builds and tests correctly, protect container artifacts,
enforce deployment policies, assess deployment risk, and validate a DEV
deployment.

You only enable the capabilities your project needs.

## 1. Add the workflow

Create:

`.github/workflows/devsecops.yml`

``` yaml
name: DevSecOps Pipeline

on:
  push:
    branches:
      - main
  pull_request:

jobs:
  devsecops:
    uses: TasniimCh/Platform-Pipeline/.github/workflows/pipeline.yml@main
    with:
      config-file: .devsecops/pipeline.yaml
      report-directory: .devsecops/reports
      log-level: info
    secrets: inherit
```

> Client repositories should use the platform's `main` branch.

## 2. Add a simple configuration

Create:

`.devsecops/pipeline.yaml`

A good starting configuration is:

``` yaml
capabilities:
  secret_detection: true
  static_analysis: true
  dependency_analysis: true
  infrastructure_analysis: true

  build: true
  unit_testing: true

build:
  working_directory: .
  runtime:
    language: node
    version: "22"
  command: null

testing:
  working_directory: .
  unit:
    command: null
```

This gives you the core security checks plus build and unit-test
validation without requiring container publication, GitOps, Kubernetes,
or deployment configuration.

When a build or test command can be reliably detected from the project,
`command: null` is sufficient. Otherwise, provide the application's
command explicitly.

## 3. Add only the secrets you need

Secrets are configured in:

**Repository Settings → Secrets and variables → Actions**

For the configuration above, dependency analysis requires:

``` text
SNYK_TOKEN
```

Additional credentials are only needed when you later enable features
that require them, such as image publication or GitOps deployment.

Never place credentials in `pipeline.yaml`.

## 4. Choose additional capabilities when needed

  -----------------------------------------------------------------------
  Capability                          Benefit
  ----------------------------------- -----------------------------------
  `secret_detection`                  Detect accidentally committed
                                      credentials

  `static_analysis`                   Detect security weaknesses in
                                      source code

  `dependency_analysis`               Detect vulnerable dependencies

  `infrastructure_analysis`           Detect insecure infrastructure
                                      configuration

  `build`                             Verify the application builds
                                      successfully

  `unit_testing`                      Catch regressions before delivery

  `integration_testing`               Validate interactions between
                                      application components

  `container_build`                   Produce the deployable container
                                      image

  `container_scan`                    Detect vulnerabilities in the final
                                      image

  `sbom`                              Generate an inventory of software
                                      components

  `provenance`                        Provide artifact origin and build
                                      traceability

  `image_publish`                     Publish an immutable deployable
                                      image

  `image_signing`                     Add artifact authenticity evidence

  `policy_enforcement`                Prevent insecure deployment
                                      configuration from progressing

  `gitops_update`                     Promote an approved image through
                                      GitOps

  `cluster_validation`                Verify that the DEV deployment
                                      becomes healthy
  -----------------------------------------------------------------------

You do not need to enable everything. Start with the controls relevant
to your repository and extend the configuration as the application
delivery requirements grow.

## 5. Example: add container security later

When the project is ready for container delivery, extend the
configuration:

``` yaml
capabilities:
  container_build: true
  container_scan: true
  sbom: true
  provenance: true

container:
  dockerfile: ./Dockerfile
  context: .
  image:
    name: my-app
    tag: null
```

If you also enable `image_publish`, add the registry configuration and
the required registry credentials.

## 6. Understand the result

The platform distinguishes between:

-   **Passed** --- the requested validation completed successfully.
-   **Finding** --- the check ran correctly but discovered a security
    issue.
-   **Failed** --- the requested operation could not complete.
-   **Blocked / rejected** --- security evidence was evaluated and
    deployment was not authorized.
-   **Manual approval** --- human authorization is required before
    promotion.

A successful security check therefore does not automatically mean that
an application is approved for deployment.

## 7. Reports

Generated evidence is available under:

``` text
.devsecops/reports/
```

and through the workflow artifacts produced during the run.

Use these reports when you need to understand a finding, failure, risk
decision, or deployment result.

## Recommended onboarding path

``` text
Start
  │
  ▼
Core Security
  │
  ├── Secret Detection
  ├── Static Analysis
  ├── Dependency Analysis
  └── Infrastructure Analysis
  │
  ▼
Build + Tests
  │
  ▼
Add Container Security when needed
  │
  ▼
Add Policy / GitOps / DEV Validation when ready
```

Start small. The platform is capability-based, so the repository
configuration can grow with the application's delivery and security
requirements.