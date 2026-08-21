# Issue #40 hostile fixtures

These fixtures are intentionally incomplete hostile JSON probes. They contain
no candidate commit, tree, or evidence hash. Positive dependency manifests and
their hashes are generated in `Test-V07ReleaseGate.ps1 -SelfTest` from the
current checkout and temporary evidence bytes, so stale WIP hashes cannot be
accepted from the repository.

The selftest also creates a temporary junction to exercise reparse rejection,
and creates oversized, duplicate-evidence, tampered-hash, missing-dependency,
and human-UAT-field cases at runtime.
