# Tools

Build, verification, GitHub roadmap, evidence capture, and packaging helpers live here. Release tools must operate on exact artifact bytes and record SHA-256 hashes.

```powershell
# Build and test using committed package locks
./tools/Invoke-Build.ps1

# Refresh package locks intentionally
./tools/Invoke-Build.ps1 -UpdateLockFiles

# Verify formatting without changing files
./tools/Invoke-Format.ps1

# Apply formatting
./tools/Invoke-Format.ps1 -Apply

# Validate the exact installed Herdr binary and bounded v0.2 protocol contract
./tools/Test-V02ProtocolContract.ps1

# Extract and validate the exact bundled Herdr JSON Schema successor contract
./tools/Test-V02BundledSchemaContract.ps1

# From a fresh, unmoved pane in the authorized Acceptance control session,
# capture target Agent Lab
# snapshot/Agent-status-event/reconnect evidence. The two sockets must differ.
$targetAgentLabSocket = Join-Path $env:APPDATA 'herdr\herdr.sock'
./tools/Test-V02HerdrRuntime.ps1 `
    -TargetHerdrSocketPath $targetAgentLabSocket `
    -DurationSeconds 120

# From a standard non-elevated pane in the separate Acceptance control session,
# run the composite v0.2 actual-runtime gate for Issues #7, #9, and #10.
# Restart only the target Agent Lab session when the gate prompts for it.
./tools/Test-V02LiveRuntimeAcceptance.ps1 `
    -TargetHerdrSocketPath $targetAgentLabSocket `
    -Language Thai `
    -DurationSeconds 600

# Verify SQLite WAL restart/migration and current-user Core-to-App IPC evidence
./tools/Test-V02StateStoreIpc.ps1

# Verify contract-backed live Overview, Organization, Agent Detail, and lifecycle evidence
# (implementation-only; Issue #9 remains open pending actual Herdr runtime evidence)
./tools/Test-V02LivePages.ps1

# Verify shared-state Compact, Normal, and Floating Vertical Widget evidence
# (implementation-only; Issue #10 remains open pending actual Herdr/reference-host evidence)
./tools/Test-V02LiveWidgets.ps1

# From a clean committed checkout, verify the deterministic v0.3 activity-event
# envelope, bounded pipeline, replay fixture, exact hashes, and fail-closed command.
./tools/Test-V03ActivityPipeline.ps1

# Verify the v0.3 Realtime Activity layout, five deterministic filters,
# bounded paging, language separation, and synchronized detail/evidence panels.
# This remains implementation-only until actual live collector evidence exists.
./tools/Test-V03RealtimeActivity.ps1

# From an authorized Herdr pane, capture an actual Agent-status transition through
# the v0.3 ActivityEventPipeline for Issue #13. This never creates a transition
# or invokes Herdr session control and fails closed without Runtime evidence.
./tools/Invoke-V03Issue13RealtimeActivityRuntimeAcceptance.ps1

# Verify the fixed bounded pane.read path, terminal redaction, PID/source
# correlation, PID-reuse protection, CPU/memory telemetry, and expiry.
# This remains partial until the authorized Herdr runtime trace is captured.
./tools/Test-V03TerminalProcess.ps1

# Verify bounded notification grouping, exact deduplication, acknowledgement,
# fail-closed event/Agent routes, and separate Thai/English WPF rendering.
# This remains partial until actual Herdr notification delivery is captured.
./tools/Test-V03NotificationRuntime.ps1

# Verify the v0.3 Issue #17 implementation-only aggregation and its
# deterministic child-gate failure propagation. These checks cover only
# Static, Contract, and Synthetic evidence and do not make a version decision.
./tools/Test-V03ImplementationGateTests.ps1
./tools/Test-V03ImplementationGate.ps1 -Configuration Release

# Verify v0.4 assignment lifecycle transitions, Core-acceptance mapping,
# SQLite migration and append-only provenance, restart replay, orphan and
# duplicate-handoff visibility, and exact committed synthetic replay hashes.
./tools/Test-V04AssignmentLifecycle.ps1

# Verify strict agent-facing CLI contracts, current-user Named Pipe transport,
# Core-owned acceptance identity, and one built CLI-to-Core process exchange.
./tools/Test-V04SelfReportCli.ps1

# Verify deterministic Delegation Graph projection, task/node/detail/timeline
# synchronization, pan/zoom/fit interaction, accessible equivalence, separate
# Thai/English presentation, and actual WPF rendering at reference sizes.
./tools/Test-V04DelegationGraph.ps1

# Verify deterministic Task Alignment findings, missing-data fail-closed behavior,
# synchronized evidence regions, language separation, and actual WPF rendering.
./tools/Test-V04TaskAlignment.ps1

# Verify the shared Expanded Widget Agent/Task projection, exact identity and
# provenance binding, durable lifecycle restart, accessible deep links, and
# separate Thai/English WPF captures. This does not claim actual Herdr runtime.
./tools/Test-V04ExpandedWidget.ps1

# From an authorized Herdr pane with four already-running role-distinct Agents,
# bind a durable ten-event CLI lifecycle to the exact overlapping Herdr runtime.
./tools/Invoke-V04LifecycleRuntimeAcceptance.ps1 `
  -ProjectManagerTerminalId '<terminal-id>' `
  -LeaderTerminalId '<terminal-id>' `
  -WorkerTerminalId '<terminal-id>' `
  -ReviewerTerminalId '<terminal-id>' `
  -EvidencePath '<verified-evidence-file>'

# After five independent PASS records and a passing composite runtime report,
# run the fail-closed v0.4 aggregate release gate.
./tools/Test-V04ReleaseGate.ps1 `
  -CompositeRuntimeReport '<composite-runtime-acceptance.json>' `
  -RuntimeGateReport '<runtime-gate-report.txt>'

# From a clean committed checkout, verify the fixed v0.5 rule definitions,
# positive/negative corpus, explainability hashes, visible rule errors,
# duplicate suppression, and deterministic product report.
./tools/Test-V05ComplianceRuleEngine.ps1

# From a clean committed checkout, verify evidence SHA-256 identity, explicit
# missing artifacts, the SQLite schema v3 evidence foundation under the current
# forward schema, immutable review history, managed-byte separation,
# open-review retention protection, and terminal retention audit.
./tools/Test-V05EvidenceAuditStorage.ps1

# From a clean committed checkout, verify the approved Compliance Queue hierarchy,
# deterministic state/filter/selection behavior, Thai and English isolation,
# actual WPF captures, and disabled role-action accessibility.
./tools/Test-V05ComplianceQueue.ps1

# From a clean committed checkout, verify the versioned six-dimension formula,
# source-distinct inputs, golden hashes, missing/invalid behavior, provenance,
# tamper rejection, and historical recalculation for v0.6 Issue #30.
./tools/Test-V06ScoringEngine.ps1

# From a clean committed checkout, verify the v0.6 Daily Summary contract,
# immutable reference, deterministic fixture, synthetic state/WPF projection,
# and separate Static/Synthetic/Contract evidence for Issue #32.
./tools/Test-V06DailySummaryPage.ps1

# Discover and verify the Issue #33 local-export source, contract, fixture,
# synthetic evidence, contract evidence, and actual-byte SHA-256 pins.
./tools/Test-V06LocalExport.ps1 -SkipBuild

# From a clean committed checkout, verify Core-owned Project Manager/Leader
# authorization, atomic ExpectedState+ExpectedSequence concurrency, Core-assigned
# TimeProvider audit timestamps, immutable latest-role observations and guarded
# projections, Core-connection audit JSON/domain/scalar validation, evidence-link
# declaration for immutable registration/event JSON via json_each plus complete-history
# validation on registration retry and before append, complete held Windows process
# chains with GetProcessTimes, parent recapture, and strict creation-time ordering,
# one operation-read-to-response server deadline, bounded detached delegates and
# shutdown drain, App/CLI validator budgets, cooperative lock waits, a one-second
# compliance-review provider/PRAGMA lock-wait ceiling plus a cancellation request,
# fresh client phase deadlines and timeout classification, strict CLI dispatch/identity,
# exact result/evidence binding, same-incident generation and single-flight guards,
# isolated nonfatal StateHub subscriber-failure delivery,
# post-commit App publication, the shared Widget incident route, and schema v4
# migration.
./tools/Test-V05RoleDistinctReview.ps1

# Static/Synthetic orchestration only; does not invoke Herdr or claim
# Runtime/Release evidence. Verifies that the Issue #28 runtime acceptance
# harness produces the compliance review trace before the composite
# acceptance and bounds/drains child-process output without retaining
# oversized or sensitive content.
./tools/Test-V05ComplianceRuntimeTraceOrchestration.ps1

# From an authorized Herdr pane with three distinct role panes already running,
# exercise the Issue #27/#28 role-distinct compliance review workflow
# (self-review must fail closed, PM sends to Leader, Leader escalates to PM,
# PM confirms) against the observed Herdr runtime and emit the composite
# runtime acceptance report and runtime gate report.
./tools/Invoke-V05ComplianceRuntimeAcceptance.ps1 `
  -ProjectManagerTerminalId '<terminal-id>' `
  -LeaderTerminalId '<terminal-id>' `
  -SubjectTerminalId '<terminal-id>' `
  -EvidencePath '<verified-evidence-file>'

# From an authorized Herdr pane, capture actual bounded pane-read and
# Herdr-PID-to-Windows-process evidence without controlling the session.
dotnet artifacts/bin/HerdrOps.Core/release/HerdrOps.Core.dll trace-herdr-terminal-process `
  --report artifacts/runtime-evidence/v0.3.0/issue-14/terminal-process.json `
  --seconds 120 --interval-ms 500 --lines 80

# From a clean committed checkout, run the deterministic v0.7 performance budget
# self-test suite (positive passing/waived boundaries and negative violations).
./tools/Test-V07PerformanceBudgets.ps1 -SelfTest

# Negative control: the committed passing-budget-report fixture intentionally carries
# stale source/binary bindings and must fail closed against a different current build.
# This command does not provide live Herdr runtime or release credit.
./tools/Test-V07PerformanceBudgets.ps1 `
  -ReportPath tests/fixtures/v0.7/budgets/passing-budget-report.json `
  -SkipBuild

# Run the comprehensive unit and regression suite for v0.7 performance budget policy.
./tools/Test-V07PerformanceBudgets.Tests.ps1
```

# Verify the fail-closed v1.0 Issue #42 24-hour soak/fault-injection contract and
# harness without running a soak or controlling Herdr/Core/App. Reports PENDING and
# refuses PASS in synthetic/preparation mode.
$expectedBranch = (git branch --show-current).Trim()
./tools/Test-V10Issue42SoakContract.ps1 -ExpectedBranch $expectedBranch

# Optionally validate exact packaged candidate bytes (still refuses a soak/PASS).
./tools/Test-V10Issue42SoakContract.ps1 `
  -ExpectedBranch $expectedBranch `
  -CandidateArchivePath '<candidate-archive>' `
  -CandidateArchiveSha256 '<64-hex>' `
  -CandidateArchiveBytes <bytes>

The composite gate binds production WPF captures to exact state hashes from the admitted Herdr Core trace and requires each Event phase to contain exactly one Core-labelled `pane.agent_status_changed` transition with matching accepted workspace/pane/status and App Agent evidence. It admits either a direct Event sequence or exactly one unlabelled connected snapshot reconciliation immediately before that Event; extra sequences, Events, topology changes or unrelated panes fail closed. It verifies Dashboard-close Widget continuity, waits for five seconds of an unchanged complete runtime fingerprint with SHA-256-chained append-only phase provenance, and then measures Widget latency plus combined Core/App idle resources. Dashboard and capture resources are released before managed large-object-heap cleanup, and weak references must show every tracked capture bitmap was collected; no native working-set trim is used and the 180 MB target is unchanged. The gate also compares prelaunch and post-run App/Core executable hashes, emits a `NoRuntimeCredit` report on every terminating failure, fails closed outside an authorized Herdr pane, and does not control the Herdr session itself.

The v0.3 activity-pipeline gate is Contract plus Synthetic evidence only. It does not claim a live Herdr trace, process telemetry, file collection, bounded `pane.read`, redaction against actual data, or v0.3 release readiness.

The v0.3 Realtime Activity gate is Contract plus actual WPF rendering backed by deterministic synthetic state. It does not close Issue #13 or claim an actual live event capture.

The v0.3 terminal/process implementation gate is Contract plus Synthetic plus one local Windows-process sample. It does not close Issue #14 or claim that an actual Herdr pane returned terminal bytes or a live Herdr PID correlation.

The v0.3 notification implementation gate includes actual WPF rendering and interaction from deterministic contract-backed input. It does not close Issue #16 or claim actual Herdr notification delivery, live Agent/Task correlation, restart persistence, or end-to-end runtime latency.

The v0.4 Delegation Graph gate includes deterministic lifecycle projection, provenance validation, actual WPF rendering, interaction tests, and an accessible equivalent. It does not close Issue #20 without independent review or claim actual Herdr/Core lifecycle delivery.

The v0.4 Expanded Widget implementation gate includes contract, synthetic, local SQLite, and actual WPF rendering evidence. Runtime credit exists only after the authorized harness binds four exact running Agent IDs and roles to an overlapping durable lifecycle. Current-user Named Pipe isolation does not prove which same-user process submitted each event.

The v0.5 compliance-rule implementation gate is Contract plus Synthetic evidence. It verifies only suspected finding generation and cannot substitute for immutable evidence storage, role-authorized review actions, the Compliance Queue, retention/redaction, actual runtime review, or v0.5 release evidence.

The v0.5 evidence/audit storage implementation gate is Contract plus local SQLite Integration evidence. It proves deterministic hashes, immutable ledgers and synthetic retention behavior, but not reviewer authorization, Compliance Queue rendering, real-data redaction, installed-product retention, actual Herdr operation, independent acceptance, or v0.5 release readiness.

The v0.5 Compliance Queue implementation gate reports Contract evidence for the presentation contract and source markers, Integration evidence for deterministic filtering/selection and language-catalog behavior, and Synthetic UI evidence for synchronized WPF rendering in separate Thai and English modes, including primary, compact, and explicit Missing-evidence captures. Its disabled role-labelled actions do not authorize or execute transitions and cannot substitute for Issue #27, actual Herdr runtime, privacy/retention acceptance, independent review, or the v0.5 release gate. Actual Herdr Runtime, Independent Review, and Release evidence remain NOT OBSERVED until their separate gates pass.

The v0.6 explainable-scoring gate reports Static, Contract, Synthetic, and Unit evidence. It proves the committed formula and golden result are reproducible, all three source classes remain distinct, golden evidence identities revalidate through the evidence-metadata contract, malformed/duplicate/absent/invalid inputs remain visible and fail closed, retained provenance rejects tampering, and historical results recalculate from their retained formula. It does not claim production evidence-byte admission, production score ingestion, reviewer authority, Evaluation or Daily Summary rendering, actual Herdr Runtime, independent acceptance, or v0.6 release readiness.

# Verify the v0.6 Evaluation page implementation gate from a built or clean
# checkout. `-SkipBuild` skips only the build; contract, integration and
# synthetic WPF tests still run and fresh screenshots are required.
./tools/Test-V06EvaluationPage.ps1 -Configuration Release
./tools/Test-V06EvaluationPage.ps1 -Configuration Release -SkipBuild

The v0.6 Evaluation page gate reports Static, Contract and Synthetic evidence
separately, pins the immutable `09-evaluation.png` identity, source/test hashes,
TRX hashes and Thai/English reference-size, compact and missing-score PNG
hashes. Actual Herdr Runtime is explicitly NOT OBSERVED / NOT CLAIMED, and the
gate does not prove independent review, production ingestion or v0.6 release
readiness.

# Run the four v0.6 version-local technical gates from one clean commit. This
# performs one full build/test/format run, then executes the focused child gates
# against the same unchanged checkout.
./tools/Test-V06TechnicalGate.ps1 -Configuration Release

The v0.6 technical gate consolidates only Static, Synthetic, and Contract
evidence and always performs the full build/test/format run; the parent gate
does not expose a `-SkipBuild` acceptance path. Child gates may skip their own
duplicate build only after the parent has completed that full run at the same
unchanged commit. It deliberately reports actual Herdr Runtime,
predecessor runtime gates, independent-review consolidation, GitHub milestone
closure, package installation, and release publication as not observed or
pending.

The v0.6 Daily Summary gate reports Static, Synthetic, and Contract evidence separately. It pins the immutable `10-daily-summary.png` reference, the committed Daily Summary source/fixture/contract hashes, deterministic aggregation/state/rendering checks, and the design-reference contract test. It explicitly reports Actual Herdr Runtime, Independent Review, and Release Evidence as NOT OBSERVED; it does not claim live events, production ingestion, reviewer authority, export, or v0.6 release readiness.

The v0.5 role-distinct review implementation gate is Contract plus BuiltProcess Integration plus local SQLite Integration evidence. It verifies the built CLI rejects public pipe override, Core-owned authority, same-transaction mutation, immutable role attribution, current-authority SQL guards, strict App/CLI IPC, complete held Windows process chains with parent recapture and strict creation-time ordering, operational client-process-to-Herdr-pane correlation, incident and event evidence-link declaration through `json_each`, registration-retry and pre-append complete-history validation, live Core-capability-gated Queue actions, one operation-frame-read-to-response server deadline, a bounded four-slot detached-delegate budget with shutdown drain, cooperative workflow/store lock waits, a one-second compliance-review command/provider/PRAGMA lock-wait ceiling plus an operation-token cancellation request, structured SQLite provider failures, fresh App/CLI connect-validation-handshake-operation deadlines with internal `TimeoutException` versus caller `OperationCanceledException`, process-wide App/CLI validator budgets of four and two, exact accepted command/result/reason/evidence binding, rejection without snapshots, accepted-only shared-state publication, same-incident generation and single-flight guards, isolated StateHub subscriber delivery, and shared Queue/Widget projection. The production App and CLI clients additionally bind the connected server to the OS-reported Core PID and validate its executable metadata, hash, start, and file stability before the handshake; no hello is sent before validation succeeds. Synchronous server delegates and client validators cannot be force-cancelled; their bounded permits and cancellation sources or pipe references remain retained until actual completion, and late faults are observed. A cancellation request to `SqliteCommand.Cancel` is cooperative and does not guarantee immediate interruption of a provider busy wait. Transaction acquisition or a mutation already executing synchronously cannot be promised immediate cancellation or rollback. Review commands use `ExpectedState` and `ExpectedSequence` together; clients do not supply `OccurredUtc`, because Core assigns it with `TimeProvider`. The Core connection validates the audit JSON hash, Domain event, and persisted scalar projection before insert. App publication after an accepted authoritative response is not suppressed by caller cancellation, while cancellation before a response still cancels transport. Process and executable checks establish operational identity continuity/correlation only; they are not cryptographic publisher authentication, signing, or provenance proof. A sufficiently privileged same-user process may forge parentage with `PROC_THREAD_ATTRIBUTE_PARENT_PROCESS`, and Herdr protocol 19 does not bind pane root PIDs to creation identities, so pre-snapshot PID recycling remains a residual. A deliberate same-user SQLite writer can register or spoof its own validation function and remains a trust-boundary residual.

The gate reports `NoRuntimeCredit`. No actual Herdr runtime credit exists until this behavior is captured from a standard, non-elevated Herdr pane and the exact pane/process observations, role observations, Core responses, and immutable database audit hashes are bound in one fresh runtime record. The gate cannot close Issue #27, provide independent acceptance, or pass the v0.5 release gate.

## v1.0.0 release-candidate preparation

Run the bounded Static/Synthetic validator on both supported PowerShell hosts:

```powershell
./tools/release/Test-V10ReleaseReadiness.ps1
& "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" `
  -NoProfile -NonInteractive -ExecutionPolicy Bypass `
  -File .\tools\release\Test-V10ReleaseReadiness.ps1
```

After all candidate source changes are committed, create a three-component v1
candidate from that exact clean commit. This creates a local ignored artifact;
it does not install, tag, push, or publish anything:

```powershell
$commit = git rev-parse HEAD
./tools/release/New-V10ReleaseCandidate.ps1 `
  -ExpectedSourceCommit $commit `
  -OutputRoot .\artifacts\release-candidate\v1.0.0
```

The output binds the exact commit, locked dependencies, the App/Core/Cli
self-contained files, deterministic archive, package manifest, hashes, and the
separate English/Thai release documents. Any unapproved byte conflict, stale
source identity, changed lockfile, path escape, or reparse point fails closed.

The committed authorization example is intentionally `PENDING` and must fail.
Only after real reports for Issues #41 through #44 and an explicit product-owner
`GO` exist may an operator create a new authorization file and run:

```powershell
./tools/release/Invoke-V10ReleaseReadiness.ps1 `
  -AuthorizationPath .\artifacts\release-authorization\v1.0.0\authorization.json
```

`READY_TO_PUBLISH` is Static verification of exact bound input bytes. It does
not create tag `v1.0.0`, call GitHub, rebuild the candidate, or establish Release
evidence. Publication and post-publication download/hash verification remain
separate required actions. See
`docs/release/v1.0.0/release-readiness-contract.md`.

The v0.7 performance budget gate reports Static, Synthetic, and Contract evidence for non-runtime preparation (Issue #39). It enforces strict schema v0.7.0, source commit binding, candidate executable SHA-256 binding, reparse point and path traversal protections, p95 sample distribution recalculation, PID+StartUtc binding and PID reuse detection, no-native-trim waiver rules, and fault/unreconciled-state fail-closed behavior. Actual Herdr Runtime, 8-hour sustained soak execution, Human UAT decisions, and Release Evidence remain explicitly NOT OBSERVED / NOT CLAIMED in this preparation slice.

# Run the v0.7 lifecycle implementation gate deterministic self-test
./tools/Test-V07Lifecycle.ps1 -SelfTest

# Run the full v0.7 lifecycle implementation gate from a clean committed checkout
./tools/Test-V07Lifecycle.ps1 -Configuration Release

The v0.7 lifecycle implementation gate verifies exact committed source and contract invariants, executes locked build and formatting checks, and validates 12/12 unit tests and 39/39 integration tests (51/51 total). Runs with `-SkipBuild` are non-acceptance unless verified same-commit binary provenance proves assemblies match the current commit; the marker verifier requires the exact unique five-assembly path set with canonical casing and the current SHA-256 for every path, rejecting duplicate, unexpected, missing, case-ambiguous, malformed, or mismatched entries. Unverified `-SkipBuild` runs fail closed with a distinct non-zero exit code. Actual Herdr Runtime, installed tray visibility, Windows logon startup registry entries, physical DPI/accessibility verification, and Release evidence are explicitly NOT OBSERVED / NOT CLAIMED.

# Run the v1.0 Issue #45 release-readiness preparation gate (Static/Synthetic only).
# This is the CI entry point; it never builds, installs, runs Herdr, creates a
# tag, pushes Git, or calls the GitHub Release API. It reports Static/Synthetic
# PASS and keeps Runtime/Human/Release NOT OBSERVED.
./tools/release/Test-V10ReleaseReadiness.ps1

# Reconcile the newly committed v1.0 release tooling/docs onto the current tree
# and confirm it emits the exact static-preparation boundary (no GO/APPROVED,
# no Release) below artifacts/release-readiness/v1.0.0/<runId>/readiness.json.
# -AuthorizationPath must name a release authorization whose four Issue #41-#44
# gate reports and concrete human approver all validate against the current
# accepted commit before the verifier will assert any preparation status.
./tools/release/Invoke-V10ReleaseReadiness.ps1 -AuthorizationPath '<authorization.json>'

The v1.0 Issue #45 release-readiness tooling reports Static and Synthetic evidence only for preparation. It validates exact committed release documents, the v1.0 package profile, deterministic candidate records and archives, and the fail-closed authorization boundary. `Invoke-V10ReleaseReadiness.ps1` will fail closed (no GO/READY_TO_PUBLISH, no Release) unless an externally prepared authorization for the current accepted commit passes all four Issue #41-#44 gate report bindings and a concrete non-placeholder human approver. `Test-V10ReleaseReadiness.ps1` is the only tool CI invokes; `New-V10ReleaseCandidate.ps1` and the readiness invoker are never run automatically. Actual Herdr Runtime, independent review, clean-machine acceptance, human approval, and Release publication remain NOT OBSERVED by these preparation tools.
