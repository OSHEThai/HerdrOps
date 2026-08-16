# Issue #38 packaging preparation

Status: non-runtime preparation only. This document maps to v0.7.0 / V070-04 and does not close the v0.7 release gate.

## Chosen Windows approach

The practical approach for the WPF/.NET 10 application is a self-contained `win-x64` directory package, distributed locally as a deterministic ZIP plus its expanded payload. A future per-user installer can extract that payload to:

```text
%LOCALAPPDATA%\Programs\HerdrOps
```

This deployment model does not need Administrator rights. It keeps binaries separate from user state, supports an in-place upgrade by replacing only the package directory, and does not need a machine-wide registry key or a startup registration to prepare the package. MSIX/MSI integration, signing, shortcuts, startup behavior, and automatic updates are intentionally outside this slice.

The package identity is defined by [`package-profile.json`](../../tools/packaging/package-profile.json): product `HerdrOps`, package version `0.7.0`, target framework `net10.0-windows`, runtime `win-x64`, Release configuration, and self-contained publish mode. `Publish-HerdrOpsPackage.ps1` passes that identity explicitly to MSBuild and validates the published assembly and file versions before any package output is copied.

The source checkout currently has a development `0.1.0-dev` default in `Directory.Build.props`. This slice does not edit that shared project metadata. Packaging is fail-closed unless the profile version is explicitly passed to publish, so a development default cannot silently become a v0.7 package identity.

## Local commands

From the repository root:

```powershell
.	ools\packaging\Publish-HerdrOpsPackage.ps1 `
    -OutputRoot .\artifacts\packaging\v0.7.0\win-x64
```

The command performs a local self-contained `dotnet publish`, creates `package\package-manifest.json`, creates a deterministic stored ZIP (no runtime-specific deflate stream) with sorted `/`-separated entries and a fixed ZIP timestamp, and writes `package-hashes.txt`. Restore is directed to an isolated temp lock path with lock-file writing disabled, and the three source lock-file hashes are checked before and after publish; the packaging command therefore fails rather than changing project dependency locks. The expanded directory package remains the primary local payload; the stored ZIP favors exact cross-host bytes over compression ratio. The output root must be a missing or empty child of the repository or a generated temp directory. Existing non-empty destinations are rejected. Package, archive, and hash record are copied into a sibling staging directory and committed by one same-volume directory rename, so an injected or ordinary pre-commit failure is cleaned up without leaving a partial destination and the output can be retried.

For a pre-existing local payload directory, manifest and archive generation are separate and fail closed on existing output files:

```powershell
.	ools\packaging\New-PackageManifest.ps1 -PackageRoot .\artifacts\packaging\payload
.	ools\packaging\New-PackageArchive.ps1 -PackageRoot .\artifacts\packaging\payload
```

The manifest records every payload path, exact byte length, SHA-256, file count, total bytes, and a canonical content hash. The hash record separately records the exact manifest and ZIP byte hashes. Neither record includes a clock value, so repeated generation from identical bytes is byte-comparable.

## Retained-user-data policy

The intended future install layout is:

```text
%LOCALAPPDATA%\Programs\HerdrOps   # replaceable package files
%LOCALAPPDATA%\HerdrOps            # retained user data, including state
```

Uninstall removes only the package directory and retains `%LOCALAPPDATA%\HerdrOps`. This is the explicit privacy and recovery choice for the preparation slice. A later data-reset operation must be a separate, explicit user action; uninstall must not silently delete state, evidence, settings, or backups. The current tooling does not perform that real uninstall.

## Synthetic lifecycle harness

```powershell
.	ools\packaging\Invoke-SyntheticPackagingLifecycle.ps1
.	ools\packaging\Test-HerdrOpsPackaging.ps1
```

The harness creates a uniquely named directory directly under `[IO.Path]::GetTempPath()`, copies non-executable fixture bytes into simulated package directories, generates manifests, performs simulated clean install and in-place upgrade, then removes only the simulated install directory. Simulated user data remains and its exact hash is checked. The harness does not launch an executable, call `dotnet run`, inspect or modify the registry, use startup folders, resolve a real install location, read or write real AppData, contact Herdr, open a pipe, or mutate a live installation. Unless `-KeepSimulationRoot` is supplied, its only destructive operation is cleanup of its own generated temp child.

The path guards reject repository roots, machine installation roots, real user-data roots, Windows roots, reparse points, and non-temp lifecycle destinations. The `New-PackageArchive.ps1` entry point validates both archive and hash-record destinations, including existing-destination and package-root separation, before it can create an archive parent or file. Manifest, archive, and hash-record writers stage beside their authorized destination, flush the complete bytes, and atomically move the staged file into place. Manifest validation is fail-closed for the full profile-bound metadata set, including schema version, issue, framework, deployment model, user-data policy, content hash algorithm, evidence class, file count, and total bytes. Operation cleanup preserves the primary failure and appends cleanup context when cleanup also fails. The scripts contain no registry mutation or process-launch path. A package output is never treated as an installed product.

The packaging test script runs the same static/synthetic checks under Windows PowerShell 5.1 and PowerShell 7. Its fault-injection cases cover outside-path side effects, early archive/hash validation, mid-write rollback and retry for each standalone file writer, primary-versus-cleanup error ordering in standalone writers, publish and synthetic lifecycle scripts, atomic partial-publication cleanup, and a successful retry. The `TestInject*` and `TestFaultInjectionStage` parameters are test-only controls; they do not perform a live install or invoke Herdr.

## Evidence boundary

| Evidence class | Result of this slice |
|---|---|
| Static | PASS for profile/project identity checks, fail-closed path checks, exact file hashes, manifest shape, and deterministic archive generation |
| Synthetic | PASS for fixture-backed manifest repeatability and temp-only install/upgrade/uninstall with retained synthetic user data |
| Contract | NOT OBSERVED; no named-pipe or installed-Herdr compatibility work is performed |
| CleanMachine | NOT OBSERVED |
| Runtime | NOT OBSERVED; actual Herdr Runtime is explicitly skipped |
| Human | NOT OBSERVED |
| Release | NOT OBSERVED; no signing, external publication, clean-machine acceptance, or release approval |

Remaining v0.7 blockers include a real non-elevated Windows install/upgrade/uninstall acceptance run, startup and shortcut decisions, actual WPF launch/runtime acceptance, migration and recovery integration, clean-machine evidence, human UAT/design review, signing/release policy, and the v0.7 milestone/release gate. No GitHub API operation, commit, package publication, or release action is part of this slice.
