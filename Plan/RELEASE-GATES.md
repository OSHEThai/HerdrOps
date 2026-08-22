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

### REC-ALL v2 authority and v0.2 compatibility gates

The authoritative owner record is `herdrops-rec-all-v2`, canonical payload SHA-256
`48474610D2A20EE2F7CA2DAC0A3CCF45F919440C9C5D81EF5BA93AD7E524F62D`, in
[Issue #149 comment 5380637664](https://github.com/OSHEThai/HerdrOps/issues/149#issuecomment-5380637664).
It supersedes `herdrops-rec-all-v1` and payload SHA-256
`DD8EB4D4BC896BE6A4765D409C5E34A16C4DBFB3D70F437EC915A50DF2FC1B1E` for validator binding.
Only the v2 record and exact reference-host profile SHA-256
`96D01ED15A536F2DF50B59B43CFDEB3683DCE8667AE2E7BF6A96124182FE13A3` may be admitted.

Before v0.2 packaged-compatibility review, all of the following must pass against one exact candidate:

- Atomic package identity validation binds clean source commit/tree, canonical preparation profile, exact ZIP bytes, extracted package manifest, App/Core bytes, governed reference-host profile, and process-wide `SoftwareOnly` renderer policy. A rebuilt or changed byte set requires fresh evidence.
- Renderer compatibility validation consumes that package receipt and validates the same held evidence bytes, pre-first-HWND and throughout-renderer observations, Thai/English capture bindings, immutable reference hashes, predeclared mask receipt, exact outside-mask pixels, bounded inside-mask differences, complete display/mixed-DPI/accessibility/environment matrices, AB/BA performance samples, and AC/battery soak samples.
- Performance requires CPU <=1%, event-to-WPF p95 <=250 ms, renderer CPU regression <=10% and <=0.50 percentage point, latency regression <=10%, UI-stall p95 <=50 ms and maximum <=100 ms, one warm-up and five measured repetitions in each AB and BA order, and no missing sample.
- Soak requires 60 minutes on AC and 60 minutes on battery, five-minute bins, combined working-set maximum <=255 MiB, resource slope <=1 MiB per ten minutes, and no missing bin or sample.
- Display coverage is 1920x1080 and 1366x768 at 100/125/150 percent, plus mixed-DPI 100<->150 and 125<->150 in both directions with primary switch and unplug. Narrator and every declared accessibility check are mandatory.
- The only supported Runtime cohort is Windows 11 x64 build 26220, local non-elevated single-user, governed hardware/profile, physical display, AC/battery. RDP, VM Runtime, ARM64, remote/cloud, and multi-user are excluded. VM evidence is clean-install-only and receives no Runtime credit.
- Every visual difference is dispositioned; no High/Critical security finding remains open. Critical invariants are not waivable. A later Plan-authorized performance waiver is exact-candidate-specific and never retroactive.

CI runs the package and renderer verifier self-tests in PowerShell 7 and Windows PowerShell 5.1.
Those self-tests are Static/Contract/Synthetic verifier evidence only: they do not build or validate a
real distributable, observe actual Herdr Runtime, perform clean install, supply Human GO, or grant
Release/publication credit.

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
- v0.2 format is a self-contained `win-x64` ZIP plus PowerShell per-user installer; startup is opt-in, uninstall retains user data, and there is no auto-update
- An unsigned local package plus SHA-256 is permitted only for the bounded local distribution; code signing requires a later controlled-certificate decision and fresh exact-artifact evidence
