# HerdrOps Release Gates

Status: Planned acceptance framework

## Evidence classes

| Class | Proves | Does not prove |
|---|---|---|
| Static | Source, schema, parse, lint and design-token consistency | Runtime behavior |
| Synthetic | Deterministic behavior against fixtures or replay data | Compatibility with installed Herdr |
| Contract | Message/schema compatibility and error handling | End-to-end product operation |
| Runtime | Observed behavior with actual Herdr and Windows processes | Install/upgrade/release readiness |
| Independent review | Role-distinct design, compliance or release judgement | Runtime unless the reviewer observed it |
| Release | Exact packaged bytes passed install, runtime and human gates | Future versions |

## Version gate matrix

| Version | Required evidence |
|---|---|
| v0.1 | Build, unit tests, actual WPF screenshots, design review |
| v0.2 | Contract tests plus actual Herdr snapshot/event/reconnect trace |
| v0.3 | Replay determinism, live activity trace, bounded-read and redaction tests |
| v0.4 | Complete assignment/delegation lifecycle trace with provenance |
| v0.5 | Rule corpus plus role-distinct runtime review workflow |
| v0.6 | Reproducible scoring and traceable Daily Summary |
| v0.7 | Clean-machine package tests, 8-hour soak, UAT and design review |
| v1.0 | Exact-artifact 24-hour soak, upgrade/rollback, security/privacy and go/no-go |

## Non-functional target budgets

Targets are gates to validate, not current achievements.

| Metric | Initial target |
|---|---:|
| Core + App idle CPU | ≤ 1% average on reference host |
| Core + App idle working set | ≤ 180 MB combined |
| Widget state-delta latency | p95 ≤ 250 ms after Core receives event |
| Dashboard cold launch | p95 ≤ 2.0 s on reference host |
| Herdr reconnect and reconcile | ≤ 5 s after endpoint becomes available |
| Unbounded terminal reads | 0 |
| Unhandled crash during v0.7 soak | 0 in 8 hours |
| Unhandled crash during v1.0 soak | 0 in 24 hours |
| Normal-mode Administrator requirement | None |

If a target cannot be met, the release requires a recorded measurement, cause, impact and explicit waiver. Changing a target does not retroactively turn a failed run into a pass.

## Release artifact rules

- Build artifacts are produced in a clean output directory
- The exact installer and binaries receive SHA-256 hashes
- Acceptance runs record version, commit, host, Herdr version and artifact hashes
- A rebuilt artifact requires a new acceptance run even when source commit is unchanged
- A Beta label requires v0.7 gates; a Stable label requires v1.0 gates
- No remote publication, signing claim or automatic update claim without direct evidence

