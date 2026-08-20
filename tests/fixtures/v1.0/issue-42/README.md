# Issue #42 soak contract fixtures

Deterministic Static/Synthetic/Contract fixtures for the fail-closed 24-hour soak and
fault-injection preparation gate (`tools/Test-V10Issue42SoakContract.ps1`).

- `soak-alert-consistency.json` — a committed, consistent event/alert set used to verify
  the alert-consistency rules (unique ids, every alert bound to exactly one existing
  event, matching `agentId`, and a consistent `acknowledged`/`acknowledgementTime`
  pairing). The gate rejects any committed fixture that fails its own consistency check.

## Schema

- Event identity is immutable: `id` and `agentId` never change and participate in the
  consistency binding. Event `sequence` is mutable current state and is not part of the
  alert identity or the SHA-256 provenance chain.
- Alert identity and binding are immutable: `id`, `eventId`, `agentId`, and `severity`.
  Alert `acknowledged` and `acknowledgementTime` are mutable current state.
- An unacknowledged alert normalizes both `null` and empty-string `acknowledgementTime`
  to the same "no acknowledgement" value; an acknowledged alert must carry a non-empty
  `acknowledgementTime`.

These fixtures never contact Herdr, Core, App, or a live database. They do not provide
Runtime or Release evidence and cannot close Issue #42.
