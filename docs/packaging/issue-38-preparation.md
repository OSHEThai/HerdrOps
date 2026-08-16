# Issue #38 packaging preparation

Status: non-runtime preparation only. This document maps to v0.7.0 / V070-04 and does not close the v0.7 release gate.

## Chosen Windows approach

The practical approach for the WPF/.NET 10 application is a self-contained `win-x64` directory package, distributed locally as a deterministic ZIP plus its expanded payload. A future per-user installer can extract that payload to:

```text
%LOCALAPPDATA%\Programs\HerdrOps
```

This deployment model does not need Administrator rights. It keeps binaries separate from user state, supports an in-place upgrade by replacing only the package directory, and does not need a machine-wide registry key or a startup registration to prepare the package. MSIX/MSI integration, signing, shortcuts, startup behavior, and automatic updates are intentionally outside this slice.

The package identity is defined by [`package-profile.json`](../../tools/packaging/package-profile.json): product `HerdrOps`, package version `0.7.0`, target framework `net10.0-windows`, runtime `win-x64`, Release configuration, and self-contained publish mode. Before invoking `dotnet`, `Publish-HerdrOpsPackage.ps1` rejects every reparse-point component or leaf in `sourceProject`, requires effective `AssemblyName`, `RootNamespace`, and explicit `TargetName` values to be exactly `HerdrOps.App` (an omitted value may default only from the exact `HerdrOps.App.csproj` filename), and then validates the published assembly and file versions before any package output is copied.

The source checkout currently has a development `0.1.0-dev` default in `Directory.Build.props`. This slice does not edit that shared project metadata. Packaging is fail-closed unless the profile version is explicitly passed to publish, so a development default cannot silently become a v0.7 package identity.

## Local commands

From the repository root:

```powershell
.\tools\packaging\Publish-HerdrOpsPackage.ps1 `
    -OutputRoot .\artifacts\packaging\v0.7.0\win-x64
```

The command performs a local self-contained `dotnet publish`, creates `package\package-manifest.json`, creates a deterministic stored ZIP (no runtime-specific deflate stream) with sorted `/`-separated entries and a fixed ZIP timestamp, and writes `package-hashes.txt`. Restore is directed to an isolated temp lock path with lock-file writing disabled, and the three source lock-file hashes are checked before and after publish; the packaging command therefore fails rather than changing project dependency locks. The expanded directory package remains the primary local payload; the stored ZIP favors exact cross-host bytes over compression ratio. The output root must be a missing or empty child of the repository or a generated temp directory. Existing non-empty destinations are rejected. Package files are written beside their destinations, flushed, hash-verified, and atomically committed; overwrite copies use an atomic replacement backup and restore the original on write, verification, replacement, or cleanup failure. The final package directory is one atomically renamed generation, and readers verify archive/hash coherence inside that generation.

For a pre-existing local payload directory, manifest generation is separate; `New-PackageArchive.ps1` publishes the archive and hash record as one retry-safe pair and fails closed on existing output files:

```powershell
.\tools\packaging\New-PackageManifest.ps1 -PackageRoot .\artifacts\packaging\payload
.\tools\packaging\New-PackageArchive.ps1 -PackageRoot .\artifacts\packaging\payload
```

The manifest records every payload path, exact byte length, SHA-256, file count, total bytes, and a canonical content hash. The hash record separately records the exact manifest and ZIP byte hashes, and its content is checked against independently computed archive bytes before publication. Standalone archive/hash publication uses a single atomically renamed commit marker as the only committed-generation signal; readers must require that marker and verify both files against it. Two independent file moves are not treated as atomic. Neither record includes a clock value, so repeated generation from identical bytes is byte-comparable.

All profile and manifest JSON is scanned from raw text before `ConvertFrom-Json`. At every JSON-object depth, property names must be unique using ordinal case-insensitive comparison; this includes nested objects and every `files` entry. Exact duplicates and case variants such as `name`/`Name` are rejected before the PowerShell parser can collapse them. This is the only duplicate-property strictness claim made by this preparation slice; array ordering and the canonical manifest property order remain separately validated.

## Retained-user-data policy

The intended future install layout is:

```text
%LOCALAPPDATA%\Programs\HerdrOps   # replaceable package files
%LOCALAPPDATA%\HerdrOps            # retained user data, including state
```

Uninstall removes only the package directory and retains `%LOCALAPPDATA%\HerdrOps`. This is the explicit privacy and recovery choice for the preparation slice. A later data-reset operation must be a separate, explicit user action; uninstall must not silently delete state, evidence, settings, or backups. The current tooling does not perform that real uninstall.

## Synthetic lifecycle harness

```powershell
.\tools\packaging\Invoke-SyntheticPackagingLifecycle.ps1
.\tools\packaging\Test-HerdrOpsPackaging.ps1
```

The harness creates a uniquely named directory directly under `[IO.Path]::GetTempPath()`, copies non-executable fixture bytes into simulated package directories, generates manifests, performs simulated clean install and in-place upgrade, then removes only the simulated install directory. Simulated user data remains and its exact hash is checked. The harness does not launch an executable, call `dotnet run`, inspect or modify the registry, use startup folders, resolve a real install location, read or write real AppData, contact Herdr, open a pipe, or mutate a live installation. Unless `-KeepSimulationRoot` is supplied, its only destructive operation is cleanup of its own generated temp child.

The packaging test script checks that path guards reject repository roots, machine installation roots, real user-data roots, Windows roots, reparse points, non-temp lifecycle destinations, and every bidirectional source/output/staging overlap. It proves malicious `AssemblyName` and reparse-component probes fail before a dotnet probe is reached. It checks raw duplicate-property rejection at root and nested file-entry depth, including case variants. It also checks that `New-PackageArchive.ps1` validates both final destinations before creating an archive parent, stages the archive/hash pair, independently verifies archive/hash coherence, requires one commit marker for readers, and removes final files and all staging files after injected failure. Durable overwrite tests inject write, verify, replace, post-replace, and backup-delete faults and verify original restoration; cleanup tests preserve primary plus cleanup context. These are bounded static/synthetic checks; they do not establish a live install or product runtime.

Run `Test-HerdrOpsPackaging.ps1` once under Windows PowerShell 5.1 and once under PowerShell 7; each invocation reports the host version and executes the same bounded checks. The supported fault stages exercised by the test are standalone writer `MidWrite`/`BeforeCommit`, durable-copy `Write`, `Verify`, `Replace`, `AfterReplace`, and `Delete`, publication `AfterPackage`, `AfterArchive`, `AfterHash`, and `BeforeCommit`, and archive-pair `Archive`, `Hash`, `AfterArchive`, `AfterHash`, `Verify`, `BeforeCommit`, `AfterArchiveMove`, `AfterHashMove`, and `CommitMarker`. The compatibility aliases `AfterArchiveCommit` and `AfterHashCommit` remain accepted for bounded callers but describe moves before the marker, not atomic pair commits. The documented entry points are exercised through manifest generation, archive/hash generation, publish preflight/failure cleanup, synthetic lifecycle, and this test script. The `TestInject*`, `TestFaultInjectionStage`, and `TestDotnetCommandPath` parameters are test-only controls; they do not perform a live install or invoke Herdr.

## Evidence boundary

| Evidence class | Result of this slice |
|---|---|
| Static | The packaging test reports PASS for profile/project identity and pre-dotnet path checks, raw duplicate-property rejection, exact file hashes, manifest shape, independent archive/hash coherence, and deterministic archive generation |
| Synthetic | The packaging test reports PASS for fixture-backed manifest repeatability and temp-only install/upgrade/uninstall with retained synthetic user data |
| Contract | NOT OBSERVED; no named-pipe or installed-Herdr compatibility work is performed |
| CleanMachine | NOT OBSERVED |
| Runtime | NOT OBSERVED; actual Herdr Runtime is explicitly skipped |
| Human | NOT OBSERVED |
| Release | NOT OBSERVED; no signing, external publication, clean-machine acceptance, or release approval |

Remaining v0.7 blockers include a real non-elevated Windows install/upgrade/uninstall acceptance run, startup and shortcut decisions, actual WPF launch/runtime acceptance, migration and recovery integration, clean-machine evidence, human UAT/design review, signing/release policy, and the v0.7 milestone/release gate. No GitHub API operation, package publication, or release action is part of this slice.
