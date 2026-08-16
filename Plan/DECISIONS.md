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

- Decision: Use bounded newline-delimited strict UTF-8 over the Windows Named Pipe, correlate every response ID, subscribe only to pane-filtered live Agent-status events, take an authoritative snapshot after subscription, and refresh authoritative state every second without counting a poll as an Event.
- Replay boundary: The admitted Herdr `d78e3d3b5126` event hub retains at most 512 general events, starts each general subscription cursor at zero, and omits the server sequence from emitted envelopes. A time-based quiet window cannot prove where retained history ends and live traffic begins. HerdrOps therefore does not request general-event subscriptions. Each pane-filtered `pane.agent_status_changed` subscription starts at the server's current sequence and supplies the only live Event evidence for this monitor. HerdrOps also omits the optional `agent_status` selector because the admitted server creates an initial matching frame only when that selector is present.
- Refresh contract: Every observed live status frame triggers a following authoritative snapshot before changed status/topology content is published. The consumed frame advances local sequence and Event count exactly once; if its snapshot fails, HerdrOps retains the last authoritative content, publishes Reconnecting, and preserves that Event evidence. A separate one-second authoritative poll captures topology and metadata changes. Before polling, HerdrOps cancels and awaits the active read: a frame that wins that race is processed first, while a cancelled read consumes nothing and leaves no read active during the poll/reconnect decision. An unchanged poll does not advance local sequence or counters; a changed poll increments reconciliation only, never Event count. A changed pane set replaces complete state and starts a new filtered subscription epoch.
- Protocol limit: Herdr protocol 19 has no global event sequence field. HerdrOps records a local connection epoch and ingest sequence, but detects server-side gaps only where Herdr supplies pane revisions.
- Consequence: Only an exact dotted `pane.agent_status_changed` frame from the admitted filtered subscription can increment Event count. A malformed frame, stream end, server-identity change, invalid snapshot, any other event name, or pane-filter change forces fresh authoritative state without Event credit. Events without a Herdr revision never receive invented gap-free semantics.
- State invariants: Snapshot validation updates workspace/tab/pane/Agent mirrors atomically; every accepted bootstrap binds discovery, subscription, and authoritative snapshot connections to one PID/start/path/hash tuple, and every connected refresh must retain that tuple.
- Reliability: Exponential reconnect starts at 100 ms with bounded jitter and never exceeds 2 seconds; the version gate still requires an actual Herdr reconnect/reconcile trace.
- Status: Replay-loop remediation is implemented; focused Contract/Integration regressions and the full 406-test Release suite pass, and independent concurrency/evidence reviews found no remaining P0-P2 issues. This is not Runtime evidence. A fresh actual-Herdr runtime gate and independent runtime acceptance remain pending for v0.2 Issue #7.

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
- Operator topology: The non-elevated gate runs in a fresh, unmoved, authorized Acceptance control pane whose Herdr server process remains alive while Core monitors a different Agent Lab target socket and server identity. The user-controlled stop/restart applies only to the target session. Matching control/target sockets or server PID/start tuples fail closed because a full Herdr server stop terminates the pane processes in that session, including the gate itself. Accepted evidence is phase-ordered: Event A, target transport disconnect, replacement target PID/start identity and fresh connected snapshot, then Event B; a reconnect to the same process or a restart outside that interval receives no Runtime credit.
- Evidence boundary: Contract, Integration and Synthetic WPF tests prove protocol behavior and fail-closed presentation. They do not prove the installed Herdr process, actual events, reconnect behavior, reference-host latency/resources or independent acceptance.
- Status: Implemented on the v0.2 runtime-acceptance branch for Issues #7, #9 and #10; actual Herdr composite runtime evidence remains pending.

## D-013 — Canonical bounded activity events and deterministic replay

- Decision: Normalize every v0.3 activity input into one versioned Domain envelope before sequencing, deduplication, correlation, debounce or publication. The envelope carries explicit source, source instance and epoch, nullable source sequence, confidence, urgency, delivery mode, UTC source/observation times, correlation ID, already-redacted summary and payload SHA-256.
- Identity contract: Exact source identity is `source kind + source instance + source epoch + source event ID`. The canonical identity and complete normalized envelope use length-prefixed UTF-8 plus fixed little-endian numeric fields, so hashes do not depend on JSON property order, platform culture or process state. Reusing one identity with changed content is rejected and observed as a conflict.
- Sequence contract: A supplied positive source sequence establishes and advances a per-source-stream baseline. Jumps emit a gap observation; distinct events claiming the same sequence and regressions are observed and rejected. Sources without a sequence remain valid, but HerdrOps never invents server-side gap-free semantics for them.
- Delivery contract: High and Critical events publish immediately even if a producer requested debounce. Normal noisy events use a required debounce key and a fixed window measured from the first observation, so continuing noise cannot postpone publication indefinitely. A debounce group also binds source, event type, correlation, confidence and Agent/pane/task/process context. Deduplication entries, source streams and open debounce buckets all have deterministic hard bounds and deterministic eviction or pressure-flush behavior.
- Data-minimization contract: The Domain envelope does not retain raw payload bytes. It accepts only an already-redacted bounded summary and exact payload hash. Actual collector read bounds, path policy and secret redaction remain separate work in Issues #14, #15 and #16.
- Replay contract: `HerdrOps.Core activity-replay` accepts strict, bounded, versioned JSON and atomically writes a deterministic report. The committed fixture must produce byte-identical reports and the exact same replay-result SHA-256 on repeated runs.
- Evidence boundary: Issue #12 replay and command results are Contract plus Synthetic evidence. They do not prove an installed Herdr session, live event latency, Windows process telemetry, bounded `pane.read`, scoped file/Git collection, real-data redaction or v0.3 release readiness.
- Status: Implemented for v0.3 Issue #12; independent read-only review returned no actionable P0-P3 findings. The clean-checkout gate remains pending.

## D-014 — Explainable compliance findings remain suspected until authorized review

- Decision: Evaluate v0.5 scope, evidence, deviation and review-order policy through the exact `HERDROPS-COMPLIANCE-V1` rule set. Each definition has a fixed Rule ID, Rule Version and Severity, and the canonical definition set is hash-bound.
- Input contract: The engine accepts bounded normalized Task, actor, project-relative path, deviation, evidence-requirement/submission and sequenced review facts. Structural ambiguity fails the request; a rule-local semantic inconsistency becomes that rule's observable `Error` outcome while other rules continue.
- Incident authority: Rule evaluation can emit only `Suspected` findings. It cannot confirm, dismiss or change review state. Role-authorized transitions and immutable audit records remain separate Issue #27 work.
- Explainability contract: Every finding carries sorted supporting facts and a distinct explainability SHA-256. Its stable identity binds rule ID/version/kind, Task, actor and case-insensitive subject.
- Duplicate contract: Callers provide the bounded active finding-identity set. Repeated detections return `DuplicateSuppressed`; the engine does not silently evict, rewrite or confirm an existing incident.
- Replay contract: `HerdrOps.Core compliance-rule-corpus` validates a strict bounded positive/negative corpus, declared outcomes, error visibility and repeated suppression, then atomically writes a deterministic Synthetic report.
- Evidence boundary: Unit tests, strict product-command tests and byte-identical corpus reports are Contract plus Synthetic evidence. They do not prove evidence storage, authorized role transitions, Compliance Queue UI, retention/redaction, actual Herdr runtime or v0.5 release readiness.
- Status: Implemented for v0.5 Issue #24; independent review and the clean-checkout implementation gate remain pending.

## D-015 — Evidence bytes, immutable metadata, review history, and retention are separate ledgers

- Decision: Store contract-v1 evidence metadata and canonical hashes in the Core-owned SQLite database while keeping optional managed artifact bytes in a bounded content vault outside SQLite.
- Identity contract: The evidence identity binds Task, actor, source event, source, already-redacted reference, explicit availability, content length and content SHA-256. Changed bytes create a new identity. Observation, ingestion, retention, storage mode and managed path are bound by a separate metadata SHA-256.
- Missing contract: An unavailable artifact becomes explicit `Missing` metadata with null content and managed-path fields. HerdrOps does not infer bytes or silently discard the capture.
- Review contract: Every review event is append-only, caller-ID idempotent, sequence-bound, evidence-set-bound and hash-chained per review case. Cases open once, cannot regress time or reopen through ordinary appends, and close only through an explicit terminal event.
- Retention contract: Open linked reviews protect managed bytes. Once unprotected and due, verified bytes are purged and a terminal hash-bound event is appended; metadata, links and audit history remain. Already-absent bytes are recorded explicitly.
- Schema contract: Forward-only SQLite schema v3 creates separate evidence, review-link, review-event and retention-event ledgers. Ordinary updates and deletes are rejected by triggers, and migration keeps the existing integrity-check and pre-upgrade backup policy.
- Authority boundary: Issue #25 does not authorize Leader or Project Manager actions, confirm incidents, enforce real-data redaction, render the Compliance Queue, or prove actual Herdr/runtime retention. Those remain Issues #26–#28.
- Evidence boundary: Domain tests and local SQLite integration tests are Contract plus Integration evidence. They are not independent review, actual Herdr runtime, installed-product retention or v0.5 release evidence.
- Status: Implemented for v0.5 Issue #25; independent review and the clean-checkout implementation gate remain pending.

## D-016 — Compliance Queue presentation is synchronized but non-authoritative

- Decision: Issue #26 renders the approved Compliance Queue hierarchy from one deterministic presentation state: summary cards, exact filters and sort, selected incident, evidence provenance, and role-labeled review actions.
- State contract: `Suspected`, `Confirmed`, `PendingLeader`, `PendingProjectManager`, and `Dismissed` remain distinct presentation states. Severity and workflow state use separate semantic tokens and visible labels.
- Selection contract: the selected visible incident is the only source for the detail, evidence, and action panels. Filtering a selected row out selects the first remaining row or clears all dependent panels. Unknown filter and sort values fail closed.
- Authority contract: every Issue #26 review action is disabled and explains its required role and unavailable reason. Project Manager, Leader, and Observer applicability is presentation metadata only. The page has no transition command, storage write, or audit append; Issue #27 owns role authorization and mutation.
- Language and accessibility contract: Thai and English are complete separate modes. Real WPF filters, selection, buttons, focus visuals, labels beyond color, readable disabled controls, disabled tooltips, distinct localized pagination automation names/help text, and a localized exact range/total/page footer are required at both reference and compact desktop sizes; review actions remain in the compact viewport while detail/evidence can scroll.
- Evidence boundary: presentation-contract checks are Contract evidence; deterministic state and language-catalog tests are Integration evidence; actual WPF captures rendered from synthetic read-only state, including the primary, compact, and Missing-evidence variants, are Synthetic UI evidence. Actual Herdr Runtime, Independent Review, and Release evidence are NOT OBSERVED. These checks do not prove reviewer authority, incident mutation, actual Herdr operation, privacy/retention acceptance, or v0.5 release readiness.
- Status: In implementation for v0.5 Issue #26.

## D-017 — Evaluation formula v1 is complete-input, source-distinct, and replayable

- Decision: Formula `HERDROPS-EVALUATION-V1` scores Goal Alignment, Acceptance Criteria, and Technical Quality at 20% each; Scope Compliance and Evidence at 15% each; and Communication at 10%. Within every dimension, Leader and Project Manager inputs carry 30% each and objective evidence carries 40%. All weights are stored as integer basis points.
- Input contract: Every source score is an integer from 0 through 100 and carries its own provenance identity plus an evidence-identity SHA-256. The input snapshot hash binds those fields to the evaluation, task, Agent, dimension, source slot, and score. A complete result requires all three sources for all six dimensions. Missing input produces an explicit Incomplete result; invalid range/evidence identity, malformed records, or duplicate dimensions produce an explicit Invalid result; malformed and duplicate records remain observable; and every non-complete result leaves the total score null rather than converting absence into a pass.
- Arithmetic contract: Source-weighted dimension values and dimension contributions use decimal arithmetic and round to four places away from zero. A complete total rounds to two places away from zero. Input order is normalized before hashing.
- Recalculation contract: Every result embeds the normalized formula definition and normalized input snapshot, plus separate formula, input, and result SHA-256 values. Historical recalculation uses the embedded formula rather than the current catalog, so later formula changes cannot rewrite earlier scores.
- Evidence boundary: Golden fixtures, deterministic tests, evidence-metadata identity tests, malformed/missing/invalid tests, and recalculation tests are Static, Contract, Synthetic, and Unit evidence for Issue #30 only. They do not prove production evidence-byte admission, reviewer authority, production ingestion, Evaluation UI, actual Herdr Runtime, or v0.6 release readiness.

## D-018 — Evaluation presentation is snapshot-bound and non-runtime

- Decision: Issue #31 presents the approved `09-evaluation.png` hierarchy from one immutable Evaluation snapshot: five summary cards, score distribution, seven-day trend, six dimension rows, selected task/Agent source comparison, and top/low Agent rankings.
- Reconciliation contract: Every card, chart, dimension row, comparison value, and ranking derives from the same retained scoring result and input snapshot. Missing, malformed, invalid, and unavailable values remain explicit and fail closed; they are never converted to zero or a passing score. Equal scores use stable identities as tie-breakers and expose tied status.
- Language and accessibility contract: Thai and English are separate selected modes. Technical identities remain literal, while every selected-language label, chart textual equivalent, status, automation name, and evidence-boundary marker is localized without bilingual stacking. Color is never the only meaning.
- Authority boundary: The Evaluation page is read-only presentation metadata. It does not authorize review actions, mutate records, ingest evidence, or infer live Herdr state.
- Evidence boundary: Reference identity, source/test hashes, contract checks, deterministic state checks, and WPF captures are reported as Static, Contract, and Synthetic evidence for Issue #31. Actual Herdr Runtime, Independent Review, and Release evidence remain NOT OBSERVED / NOT CLAIMED and cannot be inferred from screenshots or local tests.
- Status: In implementation for v0.6 Issue #31; not release-ready.

## D-019 — Daily Summary uses one deterministic accepted-source set

- Decision: Issue #32 aggregates only accepted `ActivityEvent` and `Evidence` records whose UTC timestamps convert into the requested local day through an explicit timezone. The fixed source set drives every count and projection; rejected, out-of-day, duplicate, malformed, or invalid records never become summary data.
- Empty and missing contract: An empty accepted set is valid and emits the complete fixed metric schema with zero values, empty source links, empty projections, and deterministic hashes. Missing optional Agent, Task, issue, or action fields remain null. Missing upstream records or evidence bytes are not converted into synthetic zeros and remain the responsibility of their source/availability contract.
- Determinism contract: Inputs are normalized with invariant rules; ordinal source/workstream/key ordering, explicit local-day conversion, UTC/SourceId timeline ordering, repeated-issue threshold, and length-prefixed canonical hashing produce byte-identical `SourceSetSha256` and `ResultSha256` for equivalent input sets.
- Provenance contract: Each accepted source retains `SourceId`, `Kind`, and its upstream `SourceHashSha256`; every metric and projection retains source IDs. The aggregator does not collect or recompute artifact bytes, and digest-shaped synthetic fixture values are not production evidence.
- Evidence boundary: Contract text, validation, deterministic fixture aggregation, timezone/empty behavior, and hash repeatability are Static, Contract, and Synthetic evidence. Actual Herdr Runtime NOT OBSERVED; production ingestion, live correlation, WPF rendering, independent acceptance, packaging, and v0.6 release evidence remain separate.
- Status: Implemented for v0.6 Issue #32 aggregation support; Daily Summary UI, gate execution, actual Herdr Runtime, independent review, and release readiness remain pending.
