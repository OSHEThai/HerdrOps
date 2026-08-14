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
- Consequence: Preserve the circular blue logo, shared shell, bilingual density and canonical page/widget structure.
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

- Decision: Keep SQLite exclusively in `HerdrOps.Infrastructure` and expose state to App through protocol v1 of the Core-to-App Named Pipe. App and CLI never open the database.
- SQLite contract: `Microsoft.Data.Sqlite` 10.0.11 with the patched `SQLitePCLRaw.bundle_e_sqlite3` 2.1.12 override; WAL mode, `synchronous=FULL`, foreign keys, private/default cache, a single non-pooled Core connection, an exclusive per-database Core ownership lock and a bounded busy timeout. Vulnerability warnings remain errors and are not suppressed.
- Schema contract: v1 stores one normalized current-state row and append-only state-event metadata. Migration history contains the exact script SHA-256, schema movement is forward-only, a non-empty pre-migration database is backed up first and a newer unknown schema fails closed.
- Restart contract: the persisted connection epoch and ingest sequence seed the next Herdr monitor. A write must be sequence 1 for a new store or exactly current + 1 thereafter; an exact same-sequence/same-hash write is idempotent and every mismatch fails closed.
- Pipe authorization: production server and client both require `.NET PipeOptions.CurrentUserOnly`; the pipe name is scoped by a non-reversible hash of the Windows user SID. The first message must be a protocol-v1, sequence-zero App hello with the authorized role.
- Wire contract: four-byte little-endian length prefix, strict JSON, UTC timestamp, non-empty correlation ID and a 4 MiB maximum. Every connection receives a hash-bound full snapshot followed by contiguous hash-bound entity deltas; each client queue is bounded and a lagging client must reconnect for a fresh snapshot.
- Evidence boundary: migration/restart tests and real same-user Windows Named Pipe tests are Integration evidence; frame, sequence, hash and authorization-role tests are Contract evidence. `CurrentUserOnly` cross-account isolation is supplied by the Windows/.NET platform contract and has not yet received a separate multi-account runtime acceptance run.
- Status: Implementation and local gates complete for v0.2 Issue #8; GitHub CI/PR acceptance remains pending. Independent implementation review is a separate evidence class and is not claimed.
