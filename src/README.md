# Source

The v0.1 foundation contains these production assemblies:

- `HerdrOps.App` — WPF Dashboard, tray, and widgets
- `HerdrOps.Core` — per-user collector and state pipeline
- `HerdrOps.Cli` — agent-facing command client
- `HerdrOps.Contracts` — versioned IPC and evidence contracts
- `HerdrOps.Domain` — state and business rules
- `HerdrOps.Infrastructure` — Herdr, storage, process, file, and Git adapters

Project boundaries are defined in `../Plan/ARCHITECTURE.md` and enforced by foundation tests.
