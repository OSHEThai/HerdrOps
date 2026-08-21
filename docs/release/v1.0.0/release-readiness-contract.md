# HerdrOps v1.0.0 release-readiness contract

Status: Issue #45 preparation only. No tag, GitHub Release, package publication, Human approval, CleanMachine acceptance, or actual-Herdr Runtime observation is produced by this work.

## Candidate construction

`tools/release/New-V10ReleaseCandidate.ps1` is the only v1 candidate builder in this slice. It requires an exact clean checkout commit before any output is created. It validates the effective MSBuild identity and complete in-repository import ancestry of these three executables. Property evaluation uses a fresh owned project-extensions directory, so ignored `obj` imports from an earlier build cannot become input; the temporary directory is removed after evaluation, while any unverified committed-repository or non-SDK import still fails closed.

- `HerdrOps.App.exe`
- `HerdrOps.Core.exe`
- `HerdrOps.Cli.exe`

Each component is published as self-contained `win-x64`, Release, version `1.0.0`, and locked restore. All six source package-lock files are hashed before publishing and must remain unchanged. Components share one flat runtime so the documented executable names remain at the package root. Duplicate Windows paths must have exact spelling and bytes, except the App-owned Windows Desktop implementations of `Microsoft.VisualBasic.dll`, `System.Drawing.dll`, and `WindowsBase.dll`. Those three overlays are admitted only when App is the first canonical component, Core and Cli contain identical console variants, all three assemblies have the expected strong-name identity and SDK file version, the App assembly version is not older, and no other byte conflict exists. Any case ambiguity, missing overlay, changed conflict set, or unapproved byte conflict fails before the package is committed.

The merged package receives the existing canonical package manifest, deterministic ZIP archive, integrity record, generation metadata, and commit marker. `release-candidate.json` then binds:

- the exact lowercase source commit and clean checkout;
- the release profile bytes;
- archive, manifest, content, integrity-record, metadata, and marker SHA-256 values;
- the DLL and EXE bytes for App, Core, and Cli;
- all eight language-separated user documents.

The builder does not install or start the package. Its result is Static evidence only. Rebuilding creates different candidate bytes and invalidates artifact-bound acceptance even when the source commit is unchanged.

## Authorization input

`release-authorization.example.json` is deliberately incomplete and must fail the verifier. A release operator creates a new authorization file only after real evidence exists. The file must bind exactly:

| Issue | Required evidence | Required report condition |
|---|---|---|
| #41 | ReleaseAudit | GitHub-backed dependency audit is `READY` and records the accepted commit |
| #42 | Runtime | At least 24 hours against actual Herdr, exact archive, zero unhandled crashes, zero unreconciled states |
| #43 | IndependentReview | Role-distinct final verdict `PASS`, exact archive, zero unresolved high findings |
| #44 | CleanMachine | `Live` non-elevated install, upgrade, rollback, and uninstall all `PASS` for the exact archive |

Every report path is repository-relative. The verifier rejects traversal, reparse points, missing files, duplicate JSON properties, trailing JSON content, stale commits, wrong archive hashes, and report-byte hash mismatches.

The go/no-go object is admitted only with `decision: GO`, a concrete approver, an ISO-8601 UTC timestamp, the exact accepted commit and archive SHA-256, and this literal statement:

```text
I approve publishing the exact HerdrOps v1.0.0 candidate identified by this authorization.
```

No assistant, fixture, builder, reviewer, or CI job may create this Human decision on behalf of the product owner. The fixture test uses temporary synthetic names and deletes the fixture before returning; it receives no Human credit.

## Readiness verification

From the exact clean accepted checkout:

```powershell
./tools/release/Invoke-V10ReleaseReadiness.ps1 `
    -AuthorizationPath artifacts/release-authorization/v1.0.0/authorization.json
```

The command performs read-only validation of candidate and evidence bytes, then writes one new report below `artifacts/release-readiness/v1.0.0/`. It never builds, installs, runs Herdr, creates a tag, pushes Git, or calls the GitHub Release API. `READY_TO_PUBLISH` means the named inputs passed this verifier; it is not proof that publication happened.

## Publication boundary

Publication remains a separate operator action after readiness succeeds. The operator must create tag `v1.0.0` at the exact accepted commit and upload the already accepted archive plus its existing `package-hashes.txt` without rebuilding. A post-publication check must download the visible assets, recompute hashes, and record the GitHub Release URL before Issue #45 can close.

## Evidence classes for this preparation

| Class | Result |
|---|---|
| Static | Profile, source identity, three-component bundle policy, exact-byte candidate chain, strict authorization parser, language-document bindings |
| Synthetic | Temporary merge, tamper, malformed authorization, and complete-binding fixtures |
| Contract | NOT OBSERVED |
| CleanMachine | NOT OBSERVED |
| Runtime | NOT OBSERVED |
| Independent review | NOT OBSERVED |
| Human | NOT OBSERVED |
| Release | NOT OBSERVED |
