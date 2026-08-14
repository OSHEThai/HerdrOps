# HerdrOps Decision Log

## D-001 — Repository location

- Decision: Use the authorized project root and independent Git repository at `Z:\HerdrOps`.
- Constraint: Work must remain within the project root supplied by the Codex workspace context.
- Consequence: The earlier interpretation of `C:\OSHE\HerdOps` is invalid and no HerdrOps files remain there.
- Status: Applied for repository initialization.

## D-002 — Windows architecture baseline

- Decision: Plan around .NET 10 LTS, WPF, a per-user Core process, SQLite WAL and Windows Named Pipes.
- Reason: Windows-native UI, low background overhead, reliable tray/floating-window behavior and no local web server requirement.
- Status: Baseline; implementation starts only when authorized.

## D-003 — Design authority

- Decision: The 11 user-provided images are the visual Source of Truth.
- Consequence: Preserve the circular blue logo, shared shell, information density and canonical page/widget structure. Language presentation follows D-011 and never stacks Thai and English translations in one selected mode.
- Status: Applied; exact hashes are in the reference manifest.

## D-004 — Local-first v1

- Decision: v1 stores and processes data locally under the current user.
- Deferred: Remote aggregation, team access, cloud sync and elevated telemetry.
- Status: Planned.

## D-005 — Exact Herdr protocol admission

- Decision: Admit an installed Herdr protocol only when release ID, PE header, executable SHA-256, required RPC methods, serialized-shape markers and Windows transport markers all match a reviewed contract.
- Reason: The preview binary has no Windows file-version metadata and can change protocol surface between builds carrying similar version labels.
- Consequence: Any changed Herdr executable fails closed and requires a successor contract; fixture tests remain Contract evidence and never become runtime credit.
- Current admitted binary: `0.8.0-preview.2026-08-04-d78e3d3b5126-x86_64-pc-windows-msvc`, SHA-256 `6F470DA358D6713B6BEBAB922FFB1F5FE1D3D288CC6F374C7DCA1B4A9837A542`.
- Status: Implemented for v0.2 Issue #6; actual session/runtime acceptance remains pending.

## D-006 — Exact bundled Herdr JSON Schema admission

- Decision: Extract one uniquely located balanced JSON object only after the Issue #6 binary identity passes, then admit the raw document by exact length, SHA-256, JSON Schema draft, protocol, schema version, group counts and required monitoring variants.
- Exact schema: offset `16,342,610`, length `261,498`, SHA-256 `9449368D54BBECD4D4D0696EFFB9E9C002ECD63A5B8A48BBD901A305AF842982`, protocol `19`, schema version `1`.
- Reason: Document-level validation gives Issue #7 a parsed source contract while preserving the distinction between the Issue #6 canonical fingerprint and actual embedded schema bytes.
- Consequence: Duplicate, truncated, malformed, changed or incomplete schemas fail closed and cannot be exported; static extraction remains Contract evidence with no runtime credit.
- Status: Implemented as the v0.2 Issue #54 successor; actual session/runtime acceptance remains pending.

## D-007 — Revision-aware Herdr runtime reconciliation

- Decision: Use bounded newline-delimited strict UTF-8 over the Windows Named Pipe, correlate every response ID, subscribe before taking the authoritative bootstrap snapshot, and replace complete state after every disconnect or ambiguity.
- Protocol limit: Herdr protocol 19 has no global event sequence field. HerdrOps records a local connection epoch and ingest sequence, but detects server-side gaps only where Herdr supplies pane revisions.
- Consequence: A pane revision jump, same-revision conflict, incomplete/unknown state event, malformed frame, stream end, or pane-filter change forces a fresh snapshot. Events without a Herdr revision never receive invented gap-free semantics.
- State invariants: A pane event older than the authoritative revision is discarded as stale; focus events update workspace/tab/pane/Agent mirrors atomically; every accepted bootstrap binds all three pipe connections to one PID/start/path/hash tuple.
- Reliability: Exponential reconnect starts at 100 ms with bounded jitter and never exceeds 2 seconds; the version gate still requires an actual Herdr reconnect/reconcile trace.
- Status: Client, reducer, synthetic Named Pipe tests, and fail-closed runtime evidence command implemented for v0.2 Issue #7; role-distinct implementation review accepted with no P0/P1/P2 findings. Actual Herdr runtime evidence and its independent acceptance remain pending.

## D-008 — Core-owned durable state and current-user IPC

- Decision: Keep SQLite exclusively in `HerdrOps.Infrastructure` and expose state to App through the versioned Core-to-App Named Pipe. App and CLI never open the database. Protocol v1 established durable state delivery; D-012 advances the active wire contract to protocol v2 so runtime health travels with that state.
- SQLite contract: `Microsoft.Data.Sqlite` 10.0.11 with the patched `SQLitePCLRaw.bundle_e_sqlite3` 2.1.12 override; WAL mode, `synchronous=FULL`, foreign keys, private/default cache, a single non-pooled Core connection, an exclusive per-database Core ownership lock and a bounded busy timeout. Vulnerability warnings remain errors and are not suppressed.
- Schema contract: v1 stores one normalized current-state row and append-only state-event metadata. Migration history contains the exact script SHA-256, schema movement is forward-only, a non-empty pre-migration database is backed up first and a newer unknown schema fails closed.
- Restart contract: the persisted connection epoch and ingest sequence seed the next Herdr monitor. A write must be sequence 1 for a new store or exactly current + 1 thereafter; an exact same-sequence/same-hash write is idempotent and every mismatch fails closed.
- Pipe authorization: production server and client both require `.NET PipeOptions.CurrentUserOnly`; the pipe name is scoped by a non-reversible hash of the Windows user SID. The first message must use the active protocol version, sequence zero and the authorized App role.
- Wire contract: four-byte little-endian length prefix, strict JSON, UTC timestamp, non-empty correlation ID and a 4 MiB maximum. Every connection receives a hash-bound full snapshot followed by contiguous hash-bound entity deltas; each client queue is bounded and a lagging client must reconnect for a fresh snapshot.
- Evidence boundary: migration/restart tests and real same-user Windows Named Pipe tests are Integration evidence; frame, sequence, hash and authorization-role tests are Contract evidence. `CurrentUserOnly` cross-account isolation is supplied by the Windows/.NET platform contract and has not yet received a separate multi-account runtime acceptance run.
- Status: Accepted through PR #57 at main commit `b9424dfbbae4cbd0d25dfcc682c14538729d0634`; GitHub CI passed 129/129 tests. Independent review, cross-account isolation, actual Herdr runtime, install and release evidence remain separate and unclaimed.

## D-009 — One Core snapshot drives the initial live Dashboard pages

- Decision: `Overview`, `Live Organization` and `Agent Detail` consume one normalized state stream from the per-user Core-to-App pipe. App owns presentation adapters only; it does not open SQLite, start Core or terminate Core when Dashboard closes.
- Freshness contract: protocol v2 distinguishes the Core pipe from the upstream Herdr connection. `Core connected` means the App can communicate with Core; `Live` means Core reports an exact admitted Herdr connection. Starting, reconnecting or stopped Herdr states immediately render Agent status as offline while retaining last-known identity/topology for diagnosis. A disconnected Core remains a separate failure state. Last-known values are never presented as current success.
- Unknown-data contract: the v0.2 Herdr state supplies topology, identity, runtime metadata, status and revisions. Assignment, evidence, scores and tasks are rendered as `Unknown` with their missing-source explanation instead of synthetic values or inferred success.
- Organization contract: hierarchy follows observed Workspace → Tab → Agent relationships. A Pane without Agent metadata is shown as unknown/unassigned; HerdrOps does not invent roles, vacancies, managers or delegation relationships.
- Selection contract: selecting an observed Agent in Live Organization updates Agent Detail from the exact same normalized snapshot and sequence.
- Evidence boundary: state-adapter tests, same-user pipe lifecycle tests and contract-backed WPF captures are Integration/Synthetic UI evidence. They do not satisfy Issue #9's required side-by-side actual-Herdr snapshot, runtime screen capture or Dashboard lifecycle trace.
- Status: Implementation-ready for v0.2 Issue #9. Actual Herdr runtime acceptance remains pending, so the issue must stay open.

## D-010 — One App subscription drives Dashboard and live Widgets

- Decision: The WPF App owns one Core-to-App subscription for its complete process lifetime. Dashboard and every Widget consume one `LiveDashboardState`; opening additional Widget windows never creates duplicate Core clients.
- Required v0.2 variants: Compact, Normal and Floating Vertical use `LiveWidgetState`. The Normal and Floating Vertical lists expose every admitted Agent through scrolling, while Compact summarizes Working, Blocked and Done plus priority attention.
- Lifecycle contract: Closing the Dashboard window does not stop the App subscription while Widget windows keep the App alive. App shutdown disposes only the App-side read subscription and never owns or terminates Core.
- Consistency contract: Dashboard and Widgets share the same normalized snapshot, runtime health, sequence and selected Agent. A connected Core with no currently admitted Herdr connection renders counts as unknown rather than zero-agent success. A Core or Herdr disconnect immediately makes counts unknown, removes stale status notices and makes current Agent statuses offline while retaining last-known identity for diagnosis.
- Attention contract: Blocked and Done remain semantically distinct by status, glyph and brush. Assignment, score, activity history and other unavailable fields remain `Unknown`; the UI never invents them.
- Telemetry contract: Widget update-latency samples are bounded to the latest 512 accepted state sequences and report p95. Protocol v2 measures from the Core timestamp captured immediately after an actual Herdr snapshot/event frame is received through WPF state application; synthetic adapter timing remains separate and cannot earn runtime credit.
- Evidence boundary: Contract-backed WPF captures, same-user pipe tests and in-process measurements are Integration/Synthetic evidence. They do not satisfy Issue #10's actual live-widget capture, reference-host end-to-end latency, Core-plus-App resource budget or version-local runtime gate.
- Status: Implementation-ready for v0.2 Issue #10. Actual Herdr/reference-host runtime acceptance remains pending, so the issue must stay open.

## D-011 — Thai and English are separate presentation modes

- Decision: Thai is the default UI language and English is selectable from the shared shell. Every implemented surface renders one selected language at a time; paired `ThaiTitle`/`EnglishTitle` presentation fields and stacked translation headings are prohibited.
- Dynamic-state contract: Live copy is regenerated from raw Core contract state whenever the language changes. Status, empty, offline, freshness and unsupported-field explanations are localized without changing protocol values or turning unknown data into success.
- Literal-data boundary: Product names, Agent names, workspace/tab/pane labels supplied by Herdr, identifiers, paths and protocol values remain literal source data rather than receiving invented translations.
- Lifetime contract: Shell and Widget language listeners use weak subscriptions and marshal updates to their owning WPF dispatcher, preventing stale windows from retaining the application language service or receiving cross-thread UI writes.
- Evidence boundary: Catalog parity, state-rebuild tests, XAML literal checks and contract-backed WPF captures are Integration/Synthetic UI evidence. They do not prove an actual Herdr session or satisfy the v0.2 runtime release gate.
- Status: Implemented for v0.2 Issue #63 with a passing contract-backed language-mode gate; actual Herdr runtime acceptance remains pending for the v0.2 release.

## D-012 — Hash-bound Herdr runtime health over Core-to-App IPC

- Decision: Advance the Core-to-App wire contract to protocol v2 and publish `runtime-health` messages independently from state deltas. Every snapshot and delta carries the current runtime-health record; a pure health transition does not invent or advance a Herdr state sequence.
- Binding contract: Every standalone runtime-health message includes the SHA-256 of the normalized state it describes; snapshots and deltas bind health inside the same hash-validated payload. App rejects unknown status values, invalid UTC timestamps, negative counters, a connected status without bootstrap/accepted timestamps, and any state-hash mismatch.
- Freshness contract: Core reports `Starting`, `Connected`, `Reconnecting` or `Stopped`. App exposes Core connectivity separately and treats only `Connected` as live Herdr data. During an upstream interruption, the Dashboard and Widgets retain last-known identity/topology but fail Agent counts and statuses closed to unknown/offline.
- Lifecycle contract: A health-only update reaches all subscribed App surfaces without advancing the state sequence. A newly connected App receives one coherent snapshot containing both state and current health before later updates.
- Runtime-evidence contract: Core evidence transitions include the normalized contract-state SHA-256. Production WPF evidence records the exact state hashes it rendered before and after Dashboard closure. The composite gate accepts those captures only when all rendered hashes occur in the exact-Herdr Core trace.
- Evidence boundary: Contract, Integration and Synthetic WPF tests prove protocol behavior and fail-closed presentation. They do not prove the installed Herdr process, actual events, reconnect behavior, reference-host latency/resources or independent acceptance.
- Status: Implemented on the v0.2 runtime-acceptance branch for Issues #7, #9 and #10; actual Herdr composite runtime evidence remains pending.
