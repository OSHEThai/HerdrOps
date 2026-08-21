# Issue #44 live install-acceptance runbook

Status: fail-closed operator runbook for a future clean-host run. Nothing in this
document is evidence. Executing this runbook requires explicit human opt-in on a
designated clean Windows host and does not close Issue #44 by itself; the final
report must still receive independent review and the v1.0.0 release gate.

This runbook is deliberately restrictive. Every precondition below is mandatory;
the harness fails closed when any of them is missing or mismatched. Do not weaken
a check to "make the run pass".

## 1. What this runbook can and cannot prove

| Claim | Verdict |
|---|---|
| Exact v1 candidate filesystem clean install / upgrade / rollback / uninstall on one designated clean Windows host | Can prove (CleanMachine filesystem-lifecycle evidence) |
| Retained-user-data preservation across the lifecycle | Can prove (hash-bound marker) |
| The package bytes equal the exact accepted initial/upgrade archives | Can prove only as far as the operator-supplied binding hashes are exact and honest |
| HerdrOps or Herdr application runtime behavior | CANNOT prove — the harness never starts either process |
| Named-pipe / installed-Herdr contract compatibility | CANNOT prove |
| Signing, publication, release, human go/no-go | CANNOT prove |
| The whole v1.0.0 release gate | CANNOT prove |

If you need Runtime or Release evidence, stop here; this runbook is the wrong tool.

## 2. Mandatory preconditions (all must hold)

1. A designated clean Windows host that you are allowed to mutate under
   `%LOCALAPPDATA%\Programs\HerdrOps` and `%LOCALAPPDATA%\HerdrOps`.
2. A standard, non-elevated Windows PowerShell process. The harness rejects
   elevated processes and non-Windows hosts.
3. The exact accepted source commit for the v1.0.0 upgrade artifact, recorded as
   a 40-character lowercase SHA-1, and the exact lower accepted version for the
   initial artifact (0.7.0 by the current fixture contract).
4. The exact initial and upgrade expanded package roots, ZIP archives, and
   `package-hashes.txt` sidecars, with the exact archive/manifest/content
   SHA-256 values recorded in the binding.
5. The exact machine name and 64-character uppercase machine fingerprint that
   `Get-AcceptanceMachineFingerprint` reports on that host.
6. A copy of this branch's `tools/acceptance` sources and the exact binding JSON
   filled from [`issue-44-live-binding.example.json`](issue-44-live-binding.example.json).
7. The exact live token `HERDROPS-ISSUE-44-LIVE-FILESYSTEM` supplied by the
   release owner, and `-IUnderstandLiveMutation`.

## 3. Binding file contract (fail-closed)

The binding is parsed strictly: duplicate properties, trailing commas, trailing
content, wildcards, rooted/ambiguous paths, reserved device names, and reparse
points are rejected before any target effect. Required exact values:

- `schemaVersion: 1`, `issue: 44`, `acceptanceVersion: "v1.0.0"`, `mode: "Live"`,
  `machineRole: "clean-windows-test-machine"`.
- `machineName` and `machineFingerprint` must exactly match the current host.
- `sourceCommit` (top level) == `-ExpectedSourceCommit` ==
  `upgradeArtifact.sourceCommit`; the initial artifact may bind a different
  exact commit.
- `upgradeArtifact.packageVersion` must be exactly `1.0.0` and strictly greater
  than `initialArtifact.packageVersion`.
- `installRoot` must resolve to the canonical
  `%LOCALAPPDATA%\Programs\HerdrOps` and `userDataRoot` to the canonical
  `%LOCALAPPDATA%\HerdrOps`; they must be distinct and non-overlapping.
- `retainedDataRelativePath` must be an ordinary strict descendant file path of
  `userDataRoot`; `retainedDataSha256` must be the exact uppercase SHA-256 of the
  marker or preseeded file; `retainedDataMode` is `preseeded` or
  `create-test-marker`.
- `reportPath` must be a new file outside the install/data roots.

## 4. Command shape (do not run from this preparation slice)

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

For `retainedDataMode: create-test-marker`, additionally pass
`-AllowLiveRetainedDataSeed`. For `preseeded`, pre-create the exact marker file
with the exact bound bytes and do not pass that switch.

## 5. Expected report contract

- `status` `PASS`, `mode` `Live`, `evidenceClass` `CleanMachine`, `issue` `44`,
  `acceptanceVersion` `v1.0.0`.
- `preflight.status` `PASS` including `v1-target-version` `PASS`.
- Every lifecycle step (`cleanInstall`, `upgrade`, `rollback`, `uninstall`)
  `PASS` with expected/observed versions and installed-file hashes.
- `uninstall` leaves the install root absent and the retained-data marker
  byte-identical.
- `cleanup.status` `PASS` with zero residuals; a preserved backup is an explicit
  residual that fails the report by design.
- `boundaries.cleanMachine` `PASS...`, `contract`/`runtime`/`independentReview`/
  `release` `NOT OBSERVED...`.

## 6. Failure behavior

The harness fails closed: any preflight mismatch, cancelled transition, or
post-validation retirement failure produces a `FAIL`/`CANCELLED` report, throws,
and never deletes a concurrently appearing target or a possibly damaged backup.
Do not manually delete preserved `HerdrOps.issue-44.backup-*` directories from a
failed run; record them as residuals and preserve them for review.

## 7. After the run

- Archive the report JSON, the exact binding JSON, and the harness source commit
  together; the report records run identity and timestamps.
- Attach the report to Issue #44 as CleanMachine filesystem-lifecycle evidence.
- Record explicitly what remains NOT OBSERVED: Runtime, Contract,
  IndependentReview, Human approval, Release.
- Do not close Issue #44 or the v1.0.0 release tracker until the remaining
  evidence exists and the milestone verifier passes.
