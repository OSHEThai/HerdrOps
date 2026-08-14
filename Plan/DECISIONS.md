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
