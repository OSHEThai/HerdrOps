# v0.2 Package Identity Preparation

This folder supplies the Issue #149 `herdrops-rec-all-v2` package-identity preparation guard. It does
not build, publish, install, launch, or grant Runtime/Release credit.

The later capture harness must write `identity.json` as RFC 8785 JCS UTF-8 without BOM plus one LF,
then invoke:

```powershell
./tools/packaging/v0.2/Test-V02PackageIdentity.ps1 `
  -IdentityPath <identity.json> `
  -ArchivePath <HerdrOps-0.2.0-win-x64.zip> `
  -PackageRoot <exact-extracted-package-root> `
  -RepositoryRoot <clean-exact-source-worktree>
```

The receipt SHA-256 returned by the command is the canonical atomic handoff identity. Consumers must
match it together with `ProfileId`, source commit/tree, preparation-profile raw/canonical hashes,
archive/App/Core hashes, governed reference-host profile hash, and renderer-policy hash.

Production validation requires a completely clean source repository, including no untracked files,
both before and after validation. Self-tests use an isolated clean temporary Git fixture; their ZIP is
Synthetic test data and is not a product package. PowerShell 7 additionally applies the pinned Draft
2020-12 receipt schema. Windows PowerShell 5.1 uses the same pinned canonical schema hash and complete
manual exact-shape/type validation.

## Automated live install lifecycle

`Invoke-V02CleanMachineAcceptance.ps1 -Mode Live` remains the compatibility
entrypoint name, but D-027 changes its authoritative output to report schema v2,
`HerdrOps.V02AutomatedLiveLifecycleReport`. It runs as the real non-elevated
principal through install, same-version replacement, rollback and uninstall,
then verifies retained data and zero product residue. A passing report is
classified `AutomatedLiveLifecycle`; it is not CleanMachine, Human, Runtime or
Release evidence.

The producer accepts no observer, certificate, preauthorization or post-run
receipt input. `Test-V02ReleaseGate.ps1` holds and revalidates the report and
exact package bindings in its isolated verifier. Candidate approval remains a
separate authenticated receipt from a role-distinct `IndependentAgentReviewer`.
