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

# From an authorized live Herdr environment, capture snapshot/event/reconnect evidence
./tools/Test-V02HerdrRuntime.ps1 -DurationSeconds 120

# From a standard non-elevated authorized Herdr pane, run the composite v0.2
# actual-runtime gate for Issues #7, #9, and #10. Follow its event/restart prompts.
./tools/Test-V02LiveRuntimeAcceptance.ps1

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

# Verify the fixed bounded pane.read path, terminal redaction, PID/source
# correlation, PID-reuse protection, CPU/memory telemetry, and expiry.
# This remains partial until the authorized Herdr runtime trace is captured.
./tools/Test-V03TerminalProcess.ps1

# Verify bounded notification grouping, exact deduplication, acknowledgement,
# fail-closed event/Agent routes, and separate Thai/English WPF rendering.
# This remains partial until actual Herdr notification delivery is captured.
./tools/Test-V03NotificationRuntime.ps1

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

# From an authorized Herdr pane, capture actual bounded pane-read and
# Herdr-PID-to-Windows-process evidence without controlling the session.
dotnet artifacts/bin/HerdrOps.Core/release/HerdrOps.Core.dll trace-herdr-terminal-process `
  --report artifacts/runtime-evidence/v0.3.0/issue-14/terminal-process.json `
  --seconds 120 --interval-ms 500 --lines 80
```

The composite gate binds production WPF captures to exact state hashes from the admitted Herdr Core trace, verifies Dashboard-close Widget continuity, and measures Widget latency plus combined Core/App idle resources. It fails closed outside an authorized Herdr pane and does not control the Herdr session itself.

The v0.3 activity-pipeline gate is Contract plus Synthetic evidence only. It does not claim a live Herdr trace, process telemetry, file collection, bounded `pane.read`, redaction against actual data, or v0.3 release readiness.

The v0.3 Realtime Activity gate is Contract plus actual WPF rendering backed by deterministic synthetic state. It does not close Issue #13 or claim an actual live event capture.

The v0.3 terminal/process implementation gate is Contract plus Synthetic plus one local Windows-process sample. It does not close Issue #14 or claim that an actual Herdr pane returned terminal bytes or a live Herdr PID correlation.

The v0.3 notification implementation gate includes actual WPF rendering and interaction from deterministic contract-backed input. It does not close Issue #16 or claim actual Herdr notification delivery, live Agent/Task correlation, restart persistence, or end-to-end runtime latency.

The v0.4 Delegation Graph gate includes deterministic lifecycle projection, provenance validation, actual WPF rendering, interaction tests, and an accessible equivalent. It does not close Issue #20 without independent review or claim actual Herdr/Core lifecycle delivery.

The v0.4 Expanded Widget implementation gate includes contract, synthetic, local SQLite, and actual WPF rendering evidence. Runtime credit exists only after the authorized harness binds four exact running Agent IDs and roles to an overlapping durable lifecycle. Current-user Named Pipe isolation does not prove which same-user process submitted each event.
