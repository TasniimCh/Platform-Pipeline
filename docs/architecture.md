                 ┌──────────────┐
                 │ Source Repo  │
                 └──────┬───────┘
                        │
                     Commit
                        │
                        ▼
                 ┌──────────────┐
                 │ CI Build     │
                 └──────┬───────┘
                        │
                        ▼
                 Image Digest
                sha256:ABC123
                        │
        ┌───────────────┼───────────────┐
        ▼               ▼               ▼
      SBOM            Trivy        Provenance
        │               │               │
        └───────────────┼───────────────┘
                        ▼
                    Signature
                    (Cosign)
                        │
                        ▼
                 Trusted Artifact

             IMAGE
               │
        sha256:ABC123
               │
       ┌───────┼────────┐
       │       │        │
      SBOM   Provenance Signature
       │       │        │
       ▼       ▼        ▼
    Contents  Origin   Authenticity


V0 
┌─────────────────────────────────────────────────────────────┐
│                     SOFTWARE LIFECYCLE                      │
└─────────────────────────────────────────────────────────────┘

 Source
   │
   ▼
┌──────────┐
│ Phase 1  │  Static Security
└────┬─────┘
     ▼
┌──────────┐
│ Phase 2  │  Build + Supply Chain
└────┬─────┘
     ▼
┌──────────┐
│ Phase 3  │  Policy Testing
└────┬─────┘
     ▼
┌──────────────────┐
│ Phase 4          │
│ Risk Assessment  │
│ + Decision Policy│
└────┬─────────────┘
     │
     │ PROMOTE
     ▼
┌──────────┐
│ Phase 5  │  GitOps
└────┬─────┘
     ▼
┌──────────┐
│ Phase 6  │  DEV Enforcement
│          │  + Smoke Tests
└────┬─────┘
     ▼
┌──────────┐
│ Phase 7  │  Runtime Observability
└────┬─────┘
     │
     ▼
 Runtime Evidence
     │
     ▼
 Future Runtime AI
     │
     ▼
 Knowledge / Feedback Loop