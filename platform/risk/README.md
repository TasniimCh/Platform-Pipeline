# Risk Advisor (v0) — Minimal implementation

This folder contains a minimal deterministic implementation of the Risk Advisor v0 as described in the feature spec.

Run the assessor from the repository root (example):

```bash
python3 platform/risk/lib/run.py
```

The script expects `.devsecops/reports/` to contain scanner JSON outputs. It writes `assessment.json` to `.devsecops/reports/risk/`.

Install dependencies:

```bash
pip install -r platform/risk/requirements.txt
```

Public contract
 - **Entrypoint**: `platform/risk/run.sh` (same provider contract as other `platform/*` providers)
 - **Environment variables**: `WORKSPACE`, `CONFIG_FILE`, `REPORT_DIR` (defaults to `.devsecops/reports`), `LOG_LEVEL`.
 - **Input**: expects scanner outputs under `.devsecops/reports/<tool>/` as JSON files.
 - **Output**: writes assessment artifact to `.devsecops/reports/risk/assessment.json` (audit fields included).
 - **Policies**: scoring and decision policies are versioned under `platform/risk/policies/v0/`.
 - **Exit semantics**: tool errors or invalid/missing policy files must fail the job; a missing source is non-blocking but may produce `insufficient_evidence`.

Testing
 - Unit tests and fixtures live under `platform/risk/tests/`. Run them with `pytest -q platform/risk/tests` after installing requirements.

