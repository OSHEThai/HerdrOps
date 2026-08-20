# Issue #42 soak contract fixtures

Deterministic Static/Synthetic/Contract fixtures for the fail-closed 24-hour soak and
fault-injection preparation gate (`tools/Test-V10Issue42SoakContract.ps1`).

- `soak-alert-consistency.json` — a committed, consistent event/alert set used to verify
  the alert-consistency rules (unique ids, every alert bound to exactly one existing
  event, matching `agentId`, and a consistent `acknowledged`/`acknowledgementTime`
  pairing). The gate rejects any committed fixture that fails its own consistency check.

These fixtures never contact Herdr, Core, App, or a live database. They do not provide
Runtime or Release evidence and cannot close Issue #42.
