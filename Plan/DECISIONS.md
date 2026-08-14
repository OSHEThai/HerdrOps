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
