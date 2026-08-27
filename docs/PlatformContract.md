# DevSecOps Platform --- Client User Guide

## 1. Purpose

The DevSecOps Platform provides client repositories with a reusable
software delivery pipeline that integrates security, quality,
supply-chain protection, risk-based deployment control, and DEV
deployment validation.

As a client, you mainly decide **which capabilities your application
needs** and provide the small amount of application-specific
configuration required by those capabilities.

You do not need to configure the underlying security tools or platform
implementation.

------------------------------------------------------------------------

# 2. What the Platform Provides

The platform can protect and validate an application throughout its
delivery lifecycle:

``` text
Source Code
    │
    ▼
Security Checks
    │
    ▼
Build & Tests
    │
    ▼
Container & Supply-Chain Security
    │
    ▼
Deployment Policy Enforcement
    │
    ▼
Risk Assessment
    │
    ▼
Deployment Decision
    │
    ▼
GitOps Deployment
    │
    ▼
DEV Validation
```

Each capability can be enabled or disabled according to the needs of the
repository.

------------------------------------------------------------------------

# 3. Main Benefits

Using the platform gives a client repository:

-   automated security checks on every pipeline run;
-   early detection of leaked secrets;
-   source-code security analysis;
-   dependency vulnerability analysis;
-   infrastructure configuration checks;
-   repeatable application builds and tests;
-   container vulnerability analysis;
-   Software Bill of Materials generation;
-   software provenance evidence;
-   immutable container image publication;
-   deployment policy enforcement;
-   centralized risk assessment;
-   controlled deployment authorization;
-   traceable GitOps deployment updates;
-   DEV deployment health validation;
-   standardized security and deployment evidence.

The objective is to detect problems as early as possible and prevent
unsafe artifacts from progressing silently toward deployment.

------------------------------------------------------------------------

# 4. Getting Started

A client repository needs a GitHub Actions workflow that calls the
platform.

A `.devsecops/pipeline.yaml` file can be added when the client wants to
customize platform behavior.

Typical structure:

``` text
repository/
├── .github/
│   └── workflows/
│       └── devsecops.yml
│
├── .devsecops/
│   └── pipeline.yaml
│
├── src/
├── package.json
└── Dockerfile
```

Only files relevant to the capabilities you enable are required.

------------------------------------------------------------------------

# 5. Calling the Platform

Example client workflow:

``` yaml
name: DevSecOps Pipeline

on:
  push:
    branches:
      - main
  pull_request:

jobs:
  devsecops:
    uses: TasniimCh/Platform-Pipeline/.github/workflows/pipeline.yml@<platform-ref>
    with:
      config-file: .devsecops/pipeline.yaml
      report-directory: .devsecops/reports
      log-level: info
    secrets: inherit
```

Replace `<platform-ref>` with the platform version or reference provided
by the platform team.

------------------------------------------------------------------------

# 6. Workflow Options

The client can customize the following workflow options:

  ----------------------------------------------------------------------------
  Option                  Default                      Purpose
  ----------------------- ---------------------------- -----------------------
  `config-file`           `.devsecops/pipeline.yaml`   Location of the client
                                                       configuration

  `report-directory`      `.devsecops/reports`         Location where
                                                       generated evidence is
                                                       stored

  `log-level`             `info`                       Pipeline logging level
  ----------------------------------------------------------------------------

For most repositories, the defaults are sufficient.

------------------------------------------------------------------------

# 7. Configuring Capabilities

The main configuration section is:

``` yaml
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
  image_publish: false
  image_signing: false

  policy_enforcement: false

  gitops_update: false

  admission_control: false
  cluster_validation: false
```

A capability set to `true` is requested for the repository.

A capability set to `false` is not requested unless it is required
automatically as a prerequisite of another enabled feature.

------------------------------------------------------------------------

# 8. Source-Code Security

## Secret Detection

``` yaml
capabilities:
  secret_detection: true
```

Secret detection checks the repository for accidentally committed
credentials or sensitive values.

This helps prevent exposure of items such as:

-   API tokens;
-   passwords;
-   private keys;
-   access credentials;
-   authentication secrets.

Secret detection runs early because exposed credentials represent a high
security risk.

### Recommended

Keep this capability enabled for all repositories.

------------------------------------------------------------------------

## Static Analysis

``` yaml
capabilities:
  static_analysis: true
```

Static analysis examines source code for potentially unsafe coding
patterns and security weaknesses.

It can identify security issues before the application is packaged or
deployed.

### Advantages

-   security feedback during development;
-   earlier remediation;
-   reduced risk of vulnerable code reaching deployment;
-   automated evidence for risk assessment.

### Recommended

Keep enabled for application repositories.

------------------------------------------------------------------------

## Dependency Analysis

``` yaml
capabilities:
  dependency_analysis: true
```

Dependency analysis checks third-party packages used by the application
for known vulnerabilities.

This is important because an application may contain secure custom code
while still depending on vulnerable external libraries.

### Advantages

-   identifies vulnerable dependencies;
-   exposes known security issues in the software supply chain;
-   contributes vulnerability severity information to the final risk
    assessment.

This capability requires the client repository to provide the required
dependency-analysis credential through GitHub Actions secrets.

------------------------------------------------------------------------

## Infrastructure Analysis

``` yaml
capabilities:
  infrastructure_analysis: true
```

Infrastructure analysis checks infrastructure and deployment
configuration for insecure settings.

It is useful when the repository contains infrastructure-as-code or
deployment configuration.

### Advantages

-   catches configuration mistakes before deployment;
-   reduces insecure infrastructure defaults;
-   provides infrastructure-security evidence for risk assessment.

------------------------------------------------------------------------

# 9. Build & Test

The platform can validate that the application builds and that its
automated tests pass.

``` yaml
capabilities:
  build: true
  unit_testing: true
  integration_testing: false
```

------------------------------------------------------------------------

## Build

``` yaml
capabilities:
  build: true
```

Build validation confirms that the application can be successfully
prepared for delivery.

Example configuration:

``` yaml
build:
  working_directory: .
  runtime:
    language: node
    version: "22"
    package_manager: null
  command: null
```

### Configuration

  -----------------------------------------------------------------------
  Field                               Purpose
  ----------------------------------- -----------------------------------
  `working_directory`                 Application directory containing
                                      the build project

  `runtime.language`                  Application runtime

  `runtime.version`                   Runtime version

  `runtime.package_manager`           Package manager when explicitly
                                      required

  `command`                           Explicit build command when
                                      automatic resolution is not
                                      appropriate
  -----------------------------------------------------------------------

For the current V0 release, Node.js applications are supported.

When `command` is `null`, the platform attempts to resolve an
appropriate project build command.

If the application requires a custom command, provide it explicitly.

Example:

``` yaml
build:
  command: npm run build:production
```

------------------------------------------------------------------------

# 10. Unit Testing

Enable:

``` yaml
capabilities:
  unit_testing: true
```

Configure when necessary:

``` yaml
testing:
  working_directory: .
  unit:
    command: null
```

Unit tests validate individual application components before deployment.

### Advantages

-   catches regressions early;
-   verifies expected application behavior;
-   prevents broken changes from progressing further through delivery.

For a custom test command:

``` yaml
testing:
  unit:
    command: npm run test:unit
```

------------------------------------------------------------------------

# 11. Integration Testing

Enable:

``` yaml
capabilities:
  integration_testing: true
```

Configuration:

``` yaml
testing:
  integration:
    command: npm run test:integration
```

Integration tests validate interactions between application components
or services.

### Advantages

-   catches problems that unit tests cannot detect;
-   validates component integration before deployment;
-   increases confidence in the deployable application.

------------------------------------------------------------------------

# 12. Automatic Build Requirements

You do not always need to enable `build` manually.

Some capabilities require a successfully built application.

When an enabled capability requires the build, the platform can
automatically include the necessary build stage.

For example:

``` yaml
capabilities:
  build: false
  container_build: true
```

The application build required by the container workflow can still be
performed as part of the effective pipeline.

If:

``` yaml
build: false
```

and no enabled feature requires a build, the build is skipped.

This keeps client configuration concise while still satisfying feature
dependencies.

------------------------------------------------------------------------

# 13. Container Build

Enable:

``` yaml
capabilities:
  container_build: true
```

Example configuration:

``` yaml
container:
  dockerfile: ./Dockerfile
  context: .
  image:
    name: my-app
    tag: null
  registry:
    type: dockerhub
    repository: username/my-app
```

Container build packages the application into the image that can later
be secured, published, and deployed.

### Advantages

-   reproducible application packaging;
-   consistent artifact used throughout later security checks;
-   foundation for immutable deployment.

------------------------------------------------------------------------

# 14. Container Vulnerability Scanning

Enable:

``` yaml
capabilities:
  container_scan: true
```

Container scanning checks the packaged application image for known
vulnerabilities.

This complements source and dependency analysis because the final image
may contain operating-system packages and runtime components that are
not visible from application source code alone.

### Advantages

-   scans what will actually be deployed;
-   detects vulnerable image components;
-   provides additional evidence before deployment authorization.

------------------------------------------------------------------------

# 15. Software Bill of Materials

Enable:

``` yaml
capabilities:
  sbom: true
```

The platform generates a Software Bill of Materials for the application
image.

An SBOM provides an inventory of software components contained in the
artifact.

### Advantages

-   software-component transparency;
-   easier vulnerability investigation;
-   improved auditability;
-   better supply-chain visibility.

------------------------------------------------------------------------

# 16. Provenance

Enable:

``` yaml
capabilities:
  provenance: true
```

Provenance provides evidence about the origin and creation of the
software artifact.

Conceptually:

``` text
Source
   │
   ▼
Build
   │
   ▼
Container Image
   │
   ├── SBOM       → What is inside?
   │
   └── Provenance → Where did it come from?
```

### Advantages

-   stronger artifact traceability;
-   evidence linking source and build output;
-   improved software supply-chain assurance.

------------------------------------------------------------------------

# 17. Image Publication

Enable:

``` yaml
capabilities:
  image_publish: true
```

Example:

``` yaml
container:
  registry:
    type: dockerhub
    repository: username/my-app
```

The platform publishes the built image and obtains its immutable image
digest.

The resulting deployment identity follows the form:

``` text
username/my-app@sha256:...
```

### Why immutable digests matter

Tags can change.

An immutable digest identifies one exact image.

This allows the deployment record to answer:

> Exactly which artifact was approved and deployed?

### Required client secrets

When image publication is enabled, configure:

``` text
DOCKERHUB_USERNAME
DOCKERHUB_TOKEN
```

as GitHub Actions secrets.

Never place these values in `pipeline.yaml`.

------------------------------------------------------------------------

# 18. Image Signing

Enable:

``` yaml
capabilities:
  image_signing: true
```

Image signing provides authenticity evidence for the published software
artifact.

Together, the supply-chain capabilities provide:

``` text
Immutable Image
      │
      ├── SBOM
      │     └── contents
      │
      ├── Provenance
      │     └── origin
      │
      └── Signature
            └── authenticity
```

This increases confidence that the artifact being promoted is the
artifact produced by the trusted delivery process.

------------------------------------------------------------------------

# 19. Policy Enforcement

Enable:

``` yaml
capabilities:
  policy_enforcement: true
```

Example:

``` yaml
policy:
  paths:
    - helm/
```

The platform validates deployment configuration against security
requirements before promotion.

Supported inputs include Kubernetes manifests and Helm deployment
configuration.

### Advantages

Policy enforcement helps prevent insecure deployment configurations such
as:

-   containers running with excessive privileges;
-   missing resource controls;
-   unsafe image references;
-   deployment configurations that violate the organization's security
    baseline.

### Custom repository policies

When supported by your project:

``` yaml
policy:
  paths:
    - helm/

  policy_paths:
    - .devsecops/policies/
```

This allows repository-specific requirements to complement the platform
security baseline.

------------------------------------------------------------------------

# 20. Risk Assessment

Security controls produce different kinds of evidence.

The platform combines that evidence into a final risk assessment.

Examples of evidence that may influence the assessment include:

-   detected vulnerabilities;
-   vulnerability severity;
-   leaked secrets;
-   infrastructure weaknesses;
-   policy violations;
-   available security evidence.

The resulting assessment provides:

-   a risk score;
-   a risk category;
-   the main contributors to that risk;
-   an explanation;
-   a deployment decision.

### Advantage

Clients do not need to manually interpret several independent security
reports to determine whether an artifact should proceed toward
deployment.

------------------------------------------------------------------------

# 21. Deployment Decisions

The platform can produce four deployment decisions:

  Decision            Meaning
  ------------------- -----------------------------------------------------
  `promote`           Risk is acceptable for automated promotion
  `manual_approval`   Human authorization is required
  `block`             Deployment must not proceed
  `reject`            Deployment is rejected because risk is unacceptable

The decision is separate from whether individual security checks
successfully executed.

For example, every security check may execute correctly while the final
risk remains too high for deployment.

------------------------------------------------------------------------

# 22. Manual Approval

When the decision is:

``` text
manual_approval
```

the intended behavior is:

``` text
Risk Assessment
      │
      ▼
Manual Approval Required
      │
   ┌──┴───┐
   ▼      ▼
Approve  Reject
   │      │
   ▼      ▼
Deploy   Stop
```

The application must not be automatically promoted simply because the
security checks completed successfully.

------------------------------------------------------------------------

# 23. GitOps Deployment

Enable:

``` yaml
capabilities:
  gitops_update: true
```

Example configuration:

``` yaml
gitops:
  repository: username/my-app-gitops
  ref: main
  values_file: helm/values.yaml

  argocd:
    application_name: my-app
    path: helm
    namespace: dev
    project: default
```

GitOps deployment keeps deployment configuration separate from
application source code.

The GitOps repository records the desired deployment state.

### Advantages

-   traceable deployment history;
-   clear separation between application source and deployment state;
-   immutable image promotion;
-   auditable deployment changes;
-   safer deployment control.

------------------------------------------------------------------------

# 24. GitOps Configuration Fields

  -----------------------------------------------------------------------
  Field                               Purpose
  ----------------------------------- -----------------------------------
  `repository`                        GitOps repository containing
                                      deployment configuration

  `ref`                               Branch/revision used for deployment
                                      configuration

  `values_file`                       Helm values file containing the
                                      application image reference

  `argocd.application_name`           Application identifier used for DEV
                                      deployment

  `argocd.path`                       Location of the deployment
                                      configuration inside the GitOps
                                      repository

  `argocd.namespace`                  Kubernetes namespace

  `argocd.project`                    Deployment project
  -----------------------------------------------------------------------

Example:

``` yaml
gitops:
  repository: username/my-app-gitops
  ref: main
  values_file: helm/values.yaml

  argocd:
    application_name: my-app
    path: helm
    namespace: dev
    project: default
```

------------------------------------------------------------------------

# 25. Deploying an Image Built by the Pipeline

When the same pipeline builds and publishes the application image,
GitOps uses the published immutable image identity.

The client normally enables:

``` yaml
capabilities:
  container_build: true
  image_publish: true
  gitops_update: true
```

The deployment then references the exact published image digest.

------------------------------------------------------------------------

# 26. Deploying an Existing External Image

The platform can also deploy an already-published immutable image.

Provide both:

``` text
IMAGE_REPOSITORY
IMAGE_DIGEST
```

Example:

``` text
IMAGE_REPOSITORY=username/my-app
IMAGE_DIGEST=sha256:<digest>
```

Both values are required together.

The repository identifies the image location.

The digest identifies the exact immutable image version.

------------------------------------------------------------------------

# 27. DEV Deployment Validation

Enable:

``` yaml
capabilities:
  cluster_validation: true
```

Example:

``` yaml
cluster_validation:
  environment: dev
  namespace: dev

  rollout:
    deployment: my-app
    timeout_seconds: 180

  smoke_tests:
    enabled: true
    timeout_seconds: 120
    command: null
```

The current platform release validates deployment in the **DEV
environment**.

------------------------------------------------------------------------

# 28. Rollout Validation

Rollout validation verifies that the deployed application successfully
becomes available.

The platform checks that:

-   the deployment completes;
-   expected replicas become ready;
-   expected replicas become available;
-   containers do not enter common unhealthy states.

### Advantages

A successful deployment update alone does not prove that the application
can actually start.

Rollout validation detects failures such as:

-   application startup failures;
-   image retrieval failures;
-   repeated container crashes;
-   deployments that never become ready.

------------------------------------------------------------------------

# 29. Smoke Tests

Smoke tests perform lightweight validation against the deployed DEV
application.

Example:

``` yaml
cluster_validation:
  smoke_tests:
    enabled: true
    timeout_seconds: 120
    command: null
```

A custom application-specific command can be provided when required:

``` yaml
cluster_validation:
  smoke_tests:
    enabled: true
    command: ./scripts/smoke-test.sh
```

### Advantages

Smoke tests answer a different question from build/unit tests:

``` text
Build & Tests
    │
    └── Does the application work before deployment?

Smoke Tests
    │
    └── Does the deployed application respond correctly?
```

------------------------------------------------------------------------

# 30. Admission Control

Configuration:

``` yaml
capabilities:
  admission_control: true
```

Admission control is intended to add another security boundary when
workloads enter the Kubernetes environment.

Potential enforcement includes deployment security requirements and
artifact integrity requirements.

### V0 status

Full admission enforcement is **not yet part of the completed V0 client
capability**.

Clients should not rely on this option as proof that all planned
deployment admission controls are actively enforced.

It is reserved for the evolving cluster-security capability.

------------------------------------------------------------------------

# 31. Required GitHub Secrets

Secrets depend on enabled features.

  Secret                 Required when
  ---------------------- --------------------------------------
  `SNYK_TOKEN`           Dependency analysis is enabled
  `DOCKERHUB_USERNAME`   Image publication is enabled
  `DOCKERHUB_TOKEN`      Image publication is enabled
  `GITOPS_TOKEN`         GitOps repository access is required

A client does not need credentials for disabled capabilities.

For example:

``` text
dependency_analysis: false
→ SNYK_TOKEN is not required

image_publish: false
→ Docker Hub credentials are not required

gitops_update: false
→ GitOps update credentials are not required for that feature
```

------------------------------------------------------------------------

# 32. Secret Management Rules

Never store credentials directly in:

``` text
.devsecops/pipeline.yaml
application source code
Dockerfile
Helm values
GitOps configuration
```

Store pipeline credentials using GitHub Actions secrets.

Deployment/application secrets should also remain outside plaintext Git
configuration.

------------------------------------------------------------------------

# 33. Reports and Evidence

By default, generated evidence is stored under:

``` text
.devsecops/reports/
```

Evidence can include:

-   security findings;
-   build/test results;
-   policy results;
-   container security results;
-   SBOM;
-   provenance;
-   image publication evidence;
-   risk assessment;
-   GitOps update evidence;
-   DEV deployment validation evidence.

GitHub Actions also exposes relevant reports as workflow artifacts.

This allows clients to inspect why a pipeline succeeded, failed, or
prevented deployment.

------------------------------------------------------------------------

# 34. Understanding Pipeline Results

There are three important concepts:

## Successful check

The security or validation operation completed successfully.

## Finding

The operation completed, but identified a security problem.

## Failure

The operation itself could not complete correctly.

These are not equivalent.

Example:

``` text
Security check successfully detects vulnerability
              │
              ▼
           FINDING
```

versus:

``` text
Security check cannot execute
              │
              ▼
           FAILURE
```

This distinction ensures that missing evidence is not mistaken for clean
evidence.

------------------------------------------------------------------------

# 35. Why a Successful Pipeline Stage May Still Not Deploy

Deployment is controlled by the final risk decision.

For example:

``` text
Security Checks
      │
      ▼
Completed Successfully
      │
      ▼
High Risk Detected
      │
      ▼
Decision = block
      │
      ▼
NO DEPLOYMENT
```

This is expected behavior.

The platform distinguishes:

> "The security controls executed correctly."

from:

> "The application is safe enough to deploy."

------------------------------------------------------------------------

# 36. Recommended Security Configuration

For most application repositories:

``` yaml
capabilities:
  secret_detection: true
  static_analysis: true
  dependency_analysis: true
  infrastructure_analysis: true
```

This provides broad security coverage for:

``` text
Credentials
    +
Application Code
    +
Dependencies
    +
Infrastructure Configuration
```

------------------------------------------------------------------------

# 37. Example --- Security + Build & Unit Tests

``` yaml
capabilities:
  secret_detection: true
  static_analysis: true
  dependency_analysis: true
  infrastructure_analysis: true

  build: true
  unit_testing: true
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
    command: null
```

This configuration provides source security checks plus application
build and unit-test validation.

------------------------------------------------------------------------

# 38. Example --- Secure Container Delivery

``` yaml
capabilities:
  secret_detection: true
  static_analysis: true
  dependency_analysis: true
  infrastructure_analysis: true

  container_build: true
  container_scan: true
  sbom: true
  provenance: true
  image_publish: true
  image_signing: true

container:
  dockerfile: ./Dockerfile
  context: .
  image:
    name: my-app
    tag: null
  registry:
    type: dockerhub
    repository: username/my-app
```

This adds supply-chain security to the standard application security
checks.

------------------------------------------------------------------------

# 39. Example --- Policy Enforcement

``` yaml
capabilities:
  policy_enforcement: true

policy:
  paths:
    - helm/
```

With optional repository-specific policies:

``` yaml
policy:
  paths:
    - helm/

  policy_paths:
    - .devsecops/policies/
```

------------------------------------------------------------------------

# 40. Example --- Complete DEV Delivery

``` yaml
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
    command: null


container:
  dockerfile: ./Dockerfile
  context: .
  image:
    name: my-app
    tag: null
  registry:
    type: dockerhub
    repository: username/my-app


policy:
  paths:
    - helm/


gitops:
  repository: username/my-app-gitops
  ref: main
  values_file: helm/values.yaml

  argocd:
    application_name: my-app
    path: helm
    namespace: dev
    project: default


cluster_validation:
  environment: dev
  namespace: dev

  rollout:
    deployment: my-app
    timeout_seconds: 180

  smoke_tests:
    enabled: true
    timeout_seconds: 120
    command: null
```

------------------------------------------------------------------------

# 41. Current V0 Scope

The current client-facing release focuses on securing and validating
delivery into DEV.

## Available in V0

-   secret detection;
-   static analysis;
-   dependency analysis;
-   infrastructure analysis;
-   Node.js build;
-   unit tests;
-   integration tests;
-   container build;
-   container vulnerability scanning;
-   SBOM generation;
-   provenance evidence;
-   image publication;
-   image signing;
-   CI policy enforcement;
-   risk assessment;
-   deployment decisions;
-   GitOps image promotion;
-   immutable image deployment;
-   DEV deployment synchronization;
-   rollout validation;
-   smoke-test validation.

## Planned for later versions

The following are part of the broader platform roadmap rather than the
completed V0 client contract:

-   STAGING promotion;
-   PROD deployment;
-   controlled PROD approvals;
-   automatic environment-to-environment promotion;
-   complete admission-control enforcement;
-   external secret-management integration;
-   automated rollback;
-   runtime observability and runtime security feedback;
-   runtime risk feedback and AI-assisted runtime decisions.

------------------------------------------------------------------------

# 42. Client Configuration Checklist

When onboarding a repository:

-   add the reusable workflow;
-   enable only the capabilities required by the application;
-   configure build/test commands when automatic resolution is
    insufficient;
-   provide a Dockerfile when container capabilities are enabled;
-   configure the registry when image publication is enabled;
-   provide deployment manifests or Helm configuration when policy
    enforcement is enabled;
-   configure the GitOps repository when deployment is enabled;
-   configure the DEV rollout Deployment name when cluster validation is
    enabled;
-   configure application-specific smoke tests when needed;
-   add only the GitHub Actions secrets required by enabled
    capabilities;
-   never place credentials in repository configuration.

------------------------------------------------------------------------

# 43. Quick Capability Reference

  -----------------------------------------------------------------------
  Capability                          Why enable it?
  ----------------------------------- -----------------------------------
  `secret_detection`                  Prevent accidentally committed
                                      credentials

  `static_analysis`                   Detect security weaknesses in
                                      application code

  `dependency_analysis`               Detect vulnerable third-party
                                      packages

  `infrastructure_analysis`           Detect insecure
                                      infrastructure/deployment
                                      configuration

  `build`                             Verify the application can be built

  `unit_testing`                      Catch component-level regressions

  `integration_testing`               Validate interactions between
                                      application components

  `container_build`                   Produce the deployable application
                                      image

  `container_scan`                    Find vulnerabilities in the final
                                      image

  `sbom`                              Inventory the software contained in
                                      the artifact

  `provenance`                        Establish artifact origin and build
                                      traceability

  `image_publish`                     Publish an immutable deployable
                                      image

  `image_signing`                     Provide artifact authenticity
                                      evidence

  `policy_enforcement`                Prevent insecure deployment
                                      configuration from progressing

  `gitops_update`                     Promote an approved immutable image
                                      through GitOps

  `cluster_validation`                Verify that the DEV deployment
                                      actually becomes healthy

  `admission_control`                 Reserved for expanded cluster
                                      enforcement; incomplete in V0
  -----------------------------------------------------------------------

------------------------------------------------------------------------

# 44. Summary

The client contract is intentionally simple:

``` text
Choose Capabilities
        │
        ▼
Provide Application Configuration
        │
        ▼
Provide Required Secrets
        │
        ▼
Run Platform Pipeline
        │
        ▼
Review Security / Quality Evidence
        │
        ▼
Risk-Based Deployment Decision
        │
        ▼
Approved Artifact
        │
        ▼
DEV Deployment & Validation
```

The platform gives client teams a consistent way to add security
enforcement, software quality validation, supply-chain protection,
risk-based deployment control, and DEV deployment validation without
requiring every application team to design its own DevSecOps pipeline.