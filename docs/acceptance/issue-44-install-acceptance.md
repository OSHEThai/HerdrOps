# Issue #44 install acceptance harness

Status: preparation and harness only. This document does not close Issue #44 or provide clean-machine, runtime, independent-review, or release evidence.

Issue #44 requires the exact v1 candidate to be exercised on a designated clean Windows host through clean install, upgrade, rollback, and uninstall. The harness records the product identity, package version, manifest/archive/content SHA-256 values, installed-file hashes, retained-data result, cancellation/cleanup result, and the evidence boundary in a versioned report.

## Safe modes

`tools/acceptance/Invoke-HerdrOpsInstallAcceptance.ps1` supports three modes:

```powershell
# Static orchestration plan. No package or target directory is created.
./tools/acceptance/Invoke-HerdrOpsInstallAcceptance.ps1 -Mode DryRun

# Synthetic lifecycle against committed v0.7 fixture bytes in a generated temp child.
./tools/acceptance/Invoke-HerdrOpsInstallAcceptance.ps1 -Mode Fixture

# Focused parser/static/synthetic test, including cancellation cleanup.
./tools/acceptance/Test-HerdrOpsInstallAcceptance.ps1
```

Fixture mode performs directory copies only below an owned `[IO.Path]::GetTempPath()` child. It creates a deterministic retained-data marker, performs staged clean-install/upgrade/rollback transitions, verifies installed-file hashes after each transition, removes only the simulated package directory, verifies the marker, and removes the owned simulation root. It never starts HerdrOps, reads or writes the Registry, registers a service or startup entry, elevates, contacts Herdr, publishes anything, or modifies the repository.

DryRun mode performs artifact/manifest/hash preflight and emits the same report shape, but every lifecycle action is `SKIPPED` and no simulated target is created. Both non-live modes intentionally use the current #38 v0.7 fixture bytes; the report marks the v1 target-version check `NOT_APPLICABLE` and must not be treated as v1 artifact evidence.

## Live-mode boundary

Live mode is deliberately hard to invoke. It is not run by this preparation slice. A later operator must provide all of the following:

- an exact JSON binding based on [`issue-44-live-binding.example.json`](issue-44-live-binding.example.json);
- the exact current machine name and harness machine fingerprint;
- the exact initial and upgrade archive SHA-256 values from that binding;
- `-Mode Live`, `-IUnderstandLiveMutation`, and the exact token `HERDROPS-ISSUE-44-LIVE-FILESYSTEM`;
- a standard, non-elevated Windows PowerShell process.

The binding must name the exact expanded package roots, their archive and hash-record sidecars, source-commit binding, report destination, canonical `%LOCALAPPDATA%\Programs\HerdrOps` install path, canonical `%LOCALAPPDATA%\HerdrOps` retained-data path, and a retained-data marker policy. The upgrade package must be version `1.0.0`; the initial package must be an explicitly named lower accepted version. The harness compares both artifact sidecar hashes and the package manifest bytes before any target effect.

The live command shape is:

```powershell
./tools/acceptance/Invoke-HerdrOpsInstallAcceptance.ps1 `
    -Mode Live `
    -BindingPath 'D:\HerdrOps-Evidence\issue-44-live-binding.json' `
    -ExpectedMachineName 'DESIGNATED-CLEAN-HOST' `
    -ExpectedMachineFingerprint 'UPPERCASE-64-CHARACTER-MACHINE-FINGERPRINT' `
    -ExpectedInitialArtifactSha256 'UPPERCASE-64-CHARACTER-ARCHIVE-HASH' `
    -ExpectedUpgradeArtifactSha256 'UPPERCASE-64-CHARACTER-ARCHIVE-HASH' `
    -IUnderstandLiveMutation `
    -LiveConfirmationToken 'HERDROPS-ISSUE-44-LIVE-FILESYSTEM'
```

Do not run that command from this preparation task. A live report is Runtime evidence for the filesystem lifecycle only; it does not by itself prove actual Herdr runtime, release, signing, human approval, or the v1.0.0 release gate.

## Effects and safety invariants

All paths are canonicalized before use. Existing ancestors and package trees must contain no reparse points. Broad roots, wildcards, paths inside the package root, paths inside the install/data roots, and non-owned transient names are rejected. Reports are new files and are atomically staged; existing reports are never overwritten.

The package transition is a staged directory move:

1. copy the exact expanded package into an owned stage sibling;
2. move an existing install directory to an owned backup sibling;
3. move the stage into the exact install directory;
4. validate every installed file against the artifact manifest;
5. remove the backup only after validation succeeds.

If a transition is cancelled or fails before validation, the old directory is restored when possible. If cleanup itself fails, the harness preserves the owned stage/backup path and reports it as a residual instead of deleting an uncertain path. A completed live lifecycle removes only the exact package directory. Retained data is checked by SHA-256 and is never removed by uninstall. A marker created by the harness is removed during final cleanup only when the binding explicitly selected `create-test-marker`; pre-existing retained data is left intact.

There is no installer, application launch, Registry, service, startup, elevation, named-pipe, Herdr runtime, network, signing, or publication path in this slice.

## Exact report schema

The machine-readable schema is [`issue-44-install-acceptance-report.schema.json`](issue-44-install-acceptance-report.schema.json). Every report has exactly these top-level members:

| Member | Meaning |
|---|---|
| `schemaVersion` | Report schema integer, currently `1` |
| `reportKind` | `HerdrOps.InstallAcceptanceReport` |
| `issue` | `44` |
| `acceptanceVersion` | `v1.0.0` |
| `status` | `PASS`, `FAIL`, or `CANCELLED` |
| `mode` | `DryRun`, `Fixture`, or `Live` |
| `evidenceClass` | `Static`, `Synthetic`, or `Runtime` |
| `startedAtUtc`, `completedAtUtc` | ISO-8601 UTC timestamps |
| `runId` | 32 lowercase hexadecimal run identifier |
| `machine` | Actual/expected machine name, fingerprint, and elevation state |
| `artifacts` | Initial and upgrade identity, version, path, archive/manifest/content hashes, and installed-file hashes |
| `targets` | Exact install/data/report paths and canonical path policy |
| `preflight` | Ordered identity, version, hash, path, reparse, report, and retained-data checks |
| `lifecycle` | `cleanInstall`, `upgrade`, `rollback`, and `uninstall` step records |
| `cleanup` | Owned transient cleanup, retained-data handling, and residual paths |
| `failureDetails` | Empty on pass; concise failure/cancellation text otherwise |
| `transcript` | Ordered action records with `sequence`, `phase`, `action`, `status`, `effect`, `details`, and `pathBinding` |
| `boundaries` | Separate Static/Synthetic/Contract/CleanMachine/Runtime/IndependentReview/Release statements |

Every lifecycle step records the expected/observed package version, exact installed-file hash list, whether the install root remains, retained-data status/hash, and details. `NOT_RUN` and `NOT_APPLICABLE` are explicit states; absence is not interpreted as success.

## Evidence boundary for this commit

| Class | Result |
|---|---|
| Static | Harness source, PS5.1/PS7 parse, safety-marker scan, and schema shape |
| Synthetic | Fixture clean install, upgrade, rollback, uninstall, installed hashes, retained-data assertion, and cancellation cleanup |
| Contract | NOT OBSERVED; no installed-Herdr or named-pipe compatibility work |
| CleanMachine | NOT OBSERVED |
| Runtime | NOT OBSERVED; Live mode was not executed |
| Independent review | NOT OBSERVED |
| Release | NOT OBSERVED; no package publication, signing, release, or human go/no-go |
