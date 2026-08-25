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
| Release | Exact packaged bytes passed all version-local install, runtime and review gates | Future versions |

## Version gate matrix

| Version | Required evidence |
|---|---|
| v0.1 | Build, unit tests, actual WPF screenshots, design review |
| v0.2 | Contract tests, actual Herdr snapshot/event/reconnect trace, atomic packaged compatibility, automated reference-host rendering/accessibility coverage, no-soak performance checks, and role-distinct Agent review |
| v0.3 | Replay determinism, live activity trace, bounded-read and redaction tests |
| v0.4 | Complete assignment/delegation lifecycle trace with provenance |
| v0.5 | Rule corpus plus role-distinct runtime review workflow |
| v0.6 | Reproducible scoring and traceable Daily Summary |
| v0.7 | Automated clean-machine package tests, 8-hour soak, visual/language/UIA accessibility checks, and role-distinct Agent review |
| v1.0 | Exact-artifact 24-hour soak, automated upgrade/rollback, security/privacy gates, and role-distinct Agent review |

Human-only UAT, subjective design/manual-perception review, physical-device exercises unavailable to automation, and human go/no-go are tracked only in [Issue #161](https://github.com/OSHEThai/HerdrOps/issues/161). They are supplemental and cannot block any version gate, issue, milestone, package, tag, or release readiness. Explicit authorization required for an external publication is action authority, not validation evidence.

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

### Historical v0.2 compatibility v3 authority (superseded)

D-025 is retained for audit history only. It cannot close the current milestone.

### v0.2 release-first v4 authority and gates

The current record is `herdrops-v0.2-release-first-v4`, approved UTC `2026-08-24T14:31:14Z`, payload SHA-256 `4958E318AF4960C5BEC8B12BA69AED384236C91570BB86F872057066939ED904`, in [Issue #149 comment 5396694185](https://github.com/OSHEThai/HerdrOps/issues/149#issuecomment-5396694185). It supersedes v3 for all v0.2 renderer/release acceptance. Only manifest v4 is closable; v1-v3 are historical.

- Bind the exact clean source commit/tree, canonical package receipt, ZIP, extracted inventory, App/Core bytes, governed profile, and process-wide `SoftwareOnly` state before the first HWND and throughout automated capture.
- Produce Thai and English captures through deterministic packaged rendering or automated installed-runtime capture. Exercise six off-screen viewport configurations: 1920x1080 and 1366x768 at 100/125/150%. Do not require physical display changes.
- Pass exact pixel/security checks, automated language and accessibility assertions, and automated no-soak AB/BA performance/resource checks: CPU <=1%, event-to-WPF p95 <=250 ms, UI-stall p95 <=50 ms and maximum <=100 ms, and Hardware-versus-SoftwareOnly regression <=10%. Require a role-distinct independent Agent review with no open High/Critical defect.
- Do not require or admit soak fields, receipts, bins, durations, power-source/current, resource-slope soak evidence, Narrator/manual perception, ProductOwner UI/UAT, Human visual attestation, Human trust root, Human freshness, or Human replay-ledger input for v0.2 closure.
- Preserve automated actual-installed-Herdr Runtime, clean install/upgrade/uninstall, no-listener/non-elevated/security checks, exact-head CI, issue mapping, and version-local release integrity. No automated verifier may self-grant Runtime or Release without its separately bound gate evidence.

Historical/manual HumanVisual tooling is optional and non-authoritative for v0.2. Its absence or NO_GO cannot block v4; its presence cannot grant v0.2 closure or Release credit.

### v0.2 automated lifecycle v5 authority

The current install-lifecycle record is `herdrops-v0.2-automated-lifecycle-v5`, approved UTC `2026-08-24T16:25:24Z`, payload SHA-256 `C7E5D74621D67D5ADD82BF8BE369B192AA64B5E337727FA986DB09A1F8540C7B`, in [Issue #149 comment 5398171130](https://github.com/OSHEThai/HerdrOps/issues/149#issuecomment-5398171130). It supersedes D-026 only for v0.2 lifecycle authorization.

- Require a real standard-user, non-elevated live run of clean install, startup registration, same-version replacement, rollback restoration, uninstall with retained data and final residue inspection.
- Bind the machine fingerprint, executing principal SID, canonical per-user roots and exact source/package/App/Core hashes in report schema v2. The gate must hold the report and verifier inputs across validation and fail on path, file identity, hash, schema, chronology, lifecycle or residue drift.
- Classify a passing report as `AutomatedLiveLifecycle`. It is not `CleanMachine`, actual-Herdr Runtime, Human or Release evidence and grants only lifecycle credit.
- Do not require clean-host preauthorization, certificate pinning, detached CMS signatures, an observer receipt, ProductOwner/manual action or Human attestation.
- Require the separately authenticated candidate-specific `IndependentAgentReviewer` receipt already used by the v0.2 release gate; builder and reviewer identities must be role-distinct. Report schema v1 is historical and cannot close v0.2.

### v0.2 automated release-artifact production and closure phases

- Publish Contract/Synthetic schema-v2 receipts only by running the exact governed command sets from a clean candidate. Bind every transcript path and SHA-256; schema v1 and arbitrary PASS lists cannot close v0.2.
- Acquire schema-v3 GitHub state live through authenticated `api.github.com`, then require the final gate to repeat the live acquisition. Local snapshots alone are never authenticated authority.
- Require a canonical structured external Agent-review result that binds the exact candidate, role-distinct builder/reviewer identities and tasks, decision, findings/severities/statuses and zero open High/Critical defects. Derive roles from that held result rather than caller strings, then require an owner-authenticated Issue #149 comment posted by automation that binds the validated result SHA-256 and values. Re-fetch its exact comment ID/body through GitHub at gate time and reject edits. Opaque review files, self-contained RSA keys, arbitrary HTTPS references and schema-v3 review receipts are non-closable.
- Run `Preclosure` with exactly #11 and #149 open and milestone #2 open. It may authorize the automated GitHub closure step but remains `ReleaseReady=false`. After those two issues and milestone #2 close, acquire `FinalClosure` bound to the preclosure hash and rerun the unchanged candidate. Neither phase publishes a tag, package or release.

### v0.2 reference-host working-set authority

Product owner `@yutthaphon` approved Issue #149 options M-A and R-A in the dated
[approval comment](https://github.com/OSHEThai/HerdrOps/issues/149#issuecomment-5379418145).
The provisional 255 MiB ceiling applies only to a future exact v0.2 candidate that independently
re-observes the admission-critical host, OS, graphics-adapter, and installed-Herdr leaves, pins/recomputes the applicable `candidatePolicy` leaves,
and binds the canonical SHA-256 of `Plan/reference-hosts/v0.2.json`. It uses process-wide WPF
`SoftwareOnly` before the first window and throughout the measurement, and passes the complete updated
producer and independent-validator contract. The exact candidate commit, tree and binary hashes must be
recorded before the run. No candidate is effective under this policy without passing the complete atomic producer and independent-validator contract.

The approved profile's RFC 8785 canonical SHA-256 is
`96D01ED15A536F2DF50B59B43CFDEB3683DCE8667AE2E7BF6A96124182FE13A3`; the canonical schema SHA-256 is
`98AC6A2D823D88960A79299B7B20424FF60E9C5299D458A30AB9A42BE4FC0FB3`. Its Thai/English language matrix
requires two separately bound complete runtime reports and disjoint capture roots. An atomic matrix
manifest must prove the same commit/tree, profile/schema, Herdr release/binary, App/Core binaries and
protocol identity, while each observed report language equals its CLI request, its final language/culture
remains unchanged, and its event-backed native `LanguageChangeCount` is zero. Automated pairing remains
a `RuntimeMatrixCandidate` pending the authenticated role-distinct Agent review required by D-026/D-028;
no Human or ProductOwner test action is required.

The v0.2 profile is not a waiver and is not a cross-host target. A host, OS, graphics-adapter/driver,
installed-Herdr, sampling, language or renderer mismatch fails closed rather than falling back to
255 MiB. All earlier runs remain failed and receive no retroactive Runtime credit. The default target,
including the independently enforced v0.7 budget, remains 180 MiB.
Under D-026, physical-monitor identity, adapter mode, desktop `AppliedDPI`, and window display metrics remain diagnostic provenance only; they are not v0.2 admission or closure comparisons.

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
