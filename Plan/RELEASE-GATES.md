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
| Core + App idle working set (default, including v0.7) | ≤ 180 MiB combined |
| Core + App idle working set (v0.2 approved reference-host profile only) | ≤ 255 MiB (`267,386,880` bytes) combined maximum |
| Widget state-delta latency | p95 ≤ 250 ms after Core receives event |
| Dashboard cold launch | p95 ≤ 2.0 s on reference host |
| Herdr reconnect and reconcile | ≤ 5 s after endpoint becomes available |
| Unbounded terminal reads | 0 |
| Unhandled crash during v0.7 soak | 0 in 8 hours |
| Unhandled crash during v1.0 soak | 0 in 24 hours |
| Normal-mode Administrator requirement | None |

If a target cannot be met, the release requires a recorded measurement, cause, impact and explicit waiver. Changing a target does not retroactively turn a failed run into a pass.

### v0.2 reference-host working-set authority

Product owner `@yutthaphon` approved Issue #149 options M-A and R-A in the dated
[approval comment](https://github.com/OSHEThai/HerdrOps/issues/149#issuecomment-5379418145).
The provisional 255 MiB ceiling applies only to a future exact v0.2 candidate that independently
re-observes every `environmentBinding` leaf, pins/recomputes the applicable `candidatePolicy` leaves,
and binds the canonical SHA-256 of `Plan/reference-hosts/v0.2.json`. It uses process-wide WPF
`SoftwareOnly` before the first window and throughout the measurement, and passes the complete updated
producer and independent-validator contract. The exact candidate commit, tree and binary hashes must be
recorded before the run. Until the atomic producer/validator implementation lands, no candidate is
effective under this policy.

The approved profile's RFC 8785 canonical SHA-256 is
`96D01ED15A536F2DF50B59B43CFDEB3683DCE8667AE2E7BF6A96124182FE13A3`; the canonical schema SHA-256 is
`98AC6A2D823D88960A79299B7B20424FF60E9C5299D458A30AB9A42BE4FC0FB3`. Its Thai/English language matrix
requires two separately bound complete runtime reports and disjoint capture roots. An atomic matrix
manifest must prove the same commit/tree, profile/schema, Herdr release/binary, App/Core binaries and
protocol identity, while each observed report language equals its CLI request, its final language/culture
remains unchanged, and its event-backed native `LanguageChangeCount` is zero. Automated pairing remains
a `RuntimeMatrixCandidate` pending role-distinct human review.

The v0.2 profile is not a waiver and is not a cross-host target. A host, driver, sole active-monitor/primary-Screen identity, adapter mode,
desktop `AppliedDPI` scaling,
installed-Herdr, sampling, language or renderer mismatch fails closed rather than falling back to
255 MiB. All earlier runs remain failed and receive no retroactive Runtime credit. The default target,
including the independently enforced v0.7 budget, remains 180 MiB.

### v0.7 performance waiver authority

The repository-local authority identity for an Issue #39 performance waiver is
`@yutthaphon`. A waiver report must carry `ApprovalReference:
Plan/RELEASE-GATES.md#v07-performance-waiver-authority`; any other identity or
reference fails closed. This binds the report to the Plan-defined authority
record and does not by itself constitute human approval, Runtime evidence, or
Release evidence.

## Release artifact rules

- Build artifacts are produced in a clean output directory
- The exact installer and binaries receive SHA-256 hashes
- Acceptance runs record version, commit, host, Herdr version and artifact hashes
- A rebuilt artifact requires a new acceptance run even when source commit is unchanged
- A Beta label requires v0.7 gates; a Stable label requires v1.0 gates
- No remote publication, signing claim or automatic update claim without direct evidence
