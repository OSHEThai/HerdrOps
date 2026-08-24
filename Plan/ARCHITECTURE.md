# HerdrOps Architecture Baseline

Status: Approved baseline; v0.2 implementation active
Target: Windows 11, per-user local application

## Process model

```text
Herdr Named Pipe
      │
      ▼
HerdrOps.Core.exe ─────► SQLite WAL
      │                      ▲
      │ internal pipe        │
      ▼                      │
HerdrOps.App.exe             │
  ├─ System Tray             │
  ├─ Floating Widgets        │
  └─ Dashboard               │
                             │
HerdrOps.Cli.exe ────────────┘
  Agent self-report → Core validation → event pipeline
```

## Responsibilities

### HerdrOps.Core

- Discover installed Herdr protocol/schema
- Maintain request/response and long-lived subscription connections
- Normalize, sequence, deduplicate and correlate events
- Maintain current state and persist bounded history
- Evaluate assignment/compliance policies
- Expose read/update contracts to App through a current-user Named Pipe
- Validate all CLI submissions before persistence

### HerdrOps.App

- Own System Tray, Dashboard and all Floating Widgets
- Render state deltas without direct database access
- Keep Dashboard lifecycle independent from Core collection
- Apply design tokens, localization, accessibility and window behavior

### HerdrOps.Cli

- Small command-line client for structured Agent self-report
- No direct SQLite access
- Versioned message contract and explicit non-zero failures
- Native AOT is evaluated only after compatibility and startup measurements

## Planned solution structure

```text
src/
├── HerdrOps.App/             WPF UI, tray, widgets
├── HerdrOps.Core/            Background host and pipeline
├── HerdrOps.Cli/             Agent-facing CLI
├── HerdrOps.Contracts/       Versioned IPC/event contracts
├── HerdrOps.Domain/          State, tasks, evidence, evaluation
└── HerdrOps.Infrastructure/  Herdr, SQLite, process, file and Git adapters

tests/
├── HerdrOps.UnitTests/
├── HerdrOps.ContractTests/
├── HerdrOps.IntegrationTests/
└── HerdrOps.RuntimeTests/
```

## IPC boundaries

- Herdr connection: Windows Named Pipe using Herdr's installed schema
- Core ↔ App: duplex, current-user ACL, length-prefixed JSON
- CLI → Core: request/acknowledgement with schema version and request ID
- Messages include protocol version, sequence, UTC timestamp, source and correlation IDs
- No local HTTP server in v1 local mode

## Event pipeline

```text
Ingest → Validate → Normalize → Sequence → Deduplicate → Correlate
       → Persist raw metadata → Update current state
       → Policy/Evaluation → Publish UI delta
```

High-urgency state changes publish immediately. Noisy terminal, file and process activity is bounded, debounced and summarized before UI delivery.

## Storage model

- SQLite WAL under the current user's application-data directory
- Separate current-state tables from append-only event/evidence records
- Every stored item carries source, observed time and ingest time
- Evidence stores SHA-256 and metadata; large artifacts remain outside the database unless policy requires a managed copy
- Schema migrations are forward-only and backed up before upgrade

## Reliability model

- Snapshot bootstrap before event consumption
- Sequence-gap detection and full snapshot reconciliation
- Exponential reconnect with bounded delay
- Core can continue collecting when Dashboard is closed
- UI reconnects to Core and receives a fresh state snapshot
- Idempotent event handlers and deterministic replay tests

## Security and privacy baseline

- Current-user Named Pipe ACLs
- No Administrator requirement in normal mode
- Local-only data by default
- Command lines, terminal output and files are treated as sensitive
- Bounded reads, configurable retention and redaction before persistence/export
- v1 managed evidence bytes retain for 30 days by default from `ObservedUtc`; a caller may override only with a UTC deadline from `ObservedUtc` through `ObservedUtc + 365 days`, and open linked reviews always protect the bytes
- Optional elevated telemetry, remote aggregation and cloud sync are outside v1

## Why not a Windows Service

Herdr, Agent processes, interactive desktops and widgets all run in the current user's session. A per-user Core avoids Session 0/UI isolation and unnecessary elevation. An optional elevated helper can be designed later for a narrowly defined telemetry feature.
