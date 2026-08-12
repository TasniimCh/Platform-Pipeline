# Gitleaks Scanner Action

This composite action runs the platform Gitleaks scanner and writes standardized report artifacts.

## Inputs

- `workspace`: Consumer workspace root directory.
- `config-file`: Path to the platform configuration file, relative to workspace.
- `report-directory`: Report directory relative to workspace.
- `log-level`: Log level for scanner execution.

## Outputs

- `report-directory`: Report directory relative to workspace.

## Example

uses: ./.github/actions/gitleaks
with:
  workspace: ${{ github.workspace }}
  config-file: .devsecops/pipeline.yaml
  report-directory: .devsecops/reports
  log-level: info
