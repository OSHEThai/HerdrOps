# Source

The v0.1 foundation contains these production assemblies:

- `HerdrOps.App` — WPF Dashboard, tray, widgets, three-layer design tokens, and the shared ten-page shell
- `HerdrOps.Core` — per-user collector and state pipeline
- `HerdrOps.Cli` — agent-facing command client
- `HerdrOps.Contracts` — versioned IPC and evidence contracts
- `HerdrOps.Domain` — state and business rules
- `HerdrOps.Infrastructure` — Herdr, storage, process, file, and Git adapters

Project boundaries are defined in `../Plan/ARCHITECTURE.md` and enforced by foundation tests. `HerdrOps.Domain` now includes the versioned v0.5 compliance-rule engine; its committed corpus is Synthetic evidence and cannot confirm incidents. The current App shell and deterministic page fixtures do not by themselves prove live Herdr data.
