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
- the exact accepted source commit plus the exact initial and upgrade archive SHA-256 values from that binding;
- `-Mode Live`, `-IUnderstandLiveMutation`, and the exact token `HERDROPS-ISSUE-44-LIVE-FILESYSTEM`;
- a standard, non-elevated Windows PowerShell process.

The binding must name the exact expanded package roots, their archive and hash-record sidecars, an exact source commit for each artifact, report destination, canonical `%LOCALAPPDATA%\Programs\HerdrOps` install path, canonical `%LOCALAPPDATA%\HerdrOps` retained-data path, and a retained-data marker policy. The upgrade artifact source commit must equal both the top-level accepted source commit and the independently supplied `-ExpectedSourceCommit`. The initial artifact may bind a different exact commit. This is operator-supplied provenance bound to exact manifest/archive/content hashes; it is not a claim that the current package format embeds Git provenance. The upgrade package must be version `1.0.0`; the initial package must be an explicitly named lower accepted version.

Before any target effect, the harness strictly parses the binding JSON, rejects duplicate properties or trailing content, compares the sidecar records and package manifest, then opens the ZIP without extracting it. Every ZIP file path, length, and SHA-256 must exactly equal the expanded package root, including `package-manifest.json`; traversal, rooted, directory, ambiguous, and duplicate Windows paths are rejected.

The live command shape is:

```powershell
./tools/acceptance/Invoke-HerdrOpsInstallAcceptance.ps1 `
    -Mode Live `
    -BindingPath 'D:\HerdrOps-Evidence\issue-44-live-binding.json' `
    -ExpectedMachineName 'DESIGNATED-CLEAN-HOST' `
    -ExpectedMachineFingerprint 'UPPERCASE-64-CHARACTER-MACHINE-FINGERPRINT' `
    -ExpectedSourceCommit 'lowercase-40-character-accepted-commit' `
    -ExpectedInitialArtifactSha256 'UPPERCASE-64-CHARACTER-ARCHIVE-HASH' `
    -ExpectedUpgradeArtifactSha256 'UPPERCASE-64-CHARACTER-ARCHIVE-HASH' `
    -IUnderstandLiveMutation `
    -LiveConfirmationToken 'HERDROPS-ISSUE-44-LIVE-FILESYSTEM'
```

Do not run that command from this preparation task. A successful live report is CleanMachine filesystem-lifecycle evidence only. It does not start HerdrOps or Herdr and therefore is not Runtime evidence; it also does not prove release, signing, human approval, or the v1.0.0 release gate.

## Effects and safety invariants

All paths are canonicalized before use. Existing ancestors and package trees must contain no reparse points. Broad roots, wildcards, and non-owned transient names are rejected. Artifact, report, install, retained-data, stage, and backup paths are compared in both ancestor/descendant directions so no copy or destructive target can contain its source or be contained by it. Reports are new files and are atomically staged; existing reports are never overwritten.

The package transition is a staged directory move:

1. copy the exact expanded package into an owned stage sibling;
2. move an existing install directory to an owned backup sibling;
3. move the stage into the exact install directory;
4. validate every installed file against the artifact manifest;
5. retire the backup only after validation succeeds.

If a transition is cancelled or fails before validation, the old directory is restored when possible. Once the replacement bytes validate, a later backup-retirement failure never deletes the valid new install or restores a possibly damaged backup; the valid install and any residual backup are preserved and the acceptance fails explicitly. Failed clean-install cleanup removes a target only when this run actually committed it, so a target appearing concurrently is left untouched.

Uninstall is also failure-atomic: the validated install is first moved to an owned backup, target absence and retained-data SHA-256 are checked, and only then is the backup retired. A pre-validation failure restores the intact backup. A post-validation retirement failure keeps uninstall committed, preserves any residual backup, and fails the acceptance rather than restoring damaged bytes. A marker created by the harness is removed during final cleanup only when the binding explicitly selected `create-test-marker`; pre-existing retained data is left intact.

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
| `evidenceClass` | `Static`, `Synthetic`, or `CleanMachine` |
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

Every lifecycle step is updated in place, so cancellation and failure reports retain completed `PASS` steps, the active `CANCELLED`/`FAIL` step, and later `NOT_RUN` steps. Each step records the expected/observed package version, exact installed-file hash list, whether the install root remains, retained-data status/hash, and details. Unobserved artifact records are JSON `null`, never empty objects. Every emitted pass, failure, and cancellation report is checked against the production shape validator and, when `Test-Json` is available, the Draft-07 schema before it is returned or written.

## Evidence boundary for this commit

| Class | Result |
|---|---|
| Static | Harness source, strict binding/report JSON, source-commit contract, archive/root identity, bidirectional path safety, PS5.1/PS7 parse, and schema validation |
| Synthetic | Fixture clean install, upgrade, rollback, atomic uninstall, installed hashes, retained-data assertion, every cancellation point, failure reports, concurrent-target preservation, and partial-backup-retirement probes |
| Contract | NOT OBSERVED; no installed-Herdr or named-pipe compatibility work |
| CleanMachine | NOT OBSERVED |
| Runtime | NOT OBSERVED; HerdrOps and Herdr were not started |
| Independent review | NOT OBSERVED |
| Release | NOT OBSERVED; no package publication, signing, release, or human go/no-go |
