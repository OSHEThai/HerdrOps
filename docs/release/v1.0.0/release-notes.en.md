# HerdrOps v1.0.0 release notes

## Publication condition

These notes describe the intended stable local release. They are publishable only with the exact candidate named by the v1.0.0 authorization record after Issues #41 through #44 pass, the product owner records `GO`, and the published archive matches the accepted SHA-256. This document alone is not Release evidence.

## Highlights

- A Windows desktop shell with the approved HerdrOps mark, shared navigation, project/status bar, workspace, and connection bar.
- Ten dashboard areas covering overview, live organization, realtime activity, delegation, Agent detail, task alignment, file activity, compliance, evaluation, and daily summaries.
- Compact, normal, expanded, notification, mini, and vertical Widget experiences.
- One selected interface language at a time. Thai and English are never stacked in the same view.
- Local Herdr monitoring with snapshot, event, reconnect, and freshness handling.
- Assignment, delegation, evidence, compliance review, explainable scoring, daily summary, local export, settings, diagnostics, and recovery foundations.
- A self-contained `win-x64` bundle containing `HerdrOps.App`, `HerdrOps.Core`, and `HerdrOps.Cli`.

## Deployment and data

- Supported target: Windows 11 x64.
- Deployment model: per-user directory under `%LOCALAPPDATA%\Programs\HerdrOps`.
- User state: `%LOCALAPPDATA%\HerdrOps`.
- Uninstall policy: application files are removed while user state is retained unless the user deliberately removes it.
- Normal operation must use a standard, non-elevated account.

## Known limitations

- HerdrOps is a local companion for an installed Herdr session; it is not a remote team server.
- The package is a self-contained directory bundle. MSI, MSIX, automatic update, and machine-wide installation are not claimed.
- Authenticode signing is not claimed unless signature evidence is attached to the published Release.
- Some observations are derived from local process, file, Git, or self-report evidence. The interface identifies source and freshness; inferred data must not be treated as direct Herdr truth.
- A rebuilt archive is a new candidate even when its source commit is unchanged and must repeat every artifact-bound acceptance gate.

## Evidence boundary

Builds, fixture runs, contract checks, actual-Herdr Runtime observation, independent review, clean-machine acceptance, human approval, and Release publication are separate evidence classes. The GitHub Release is valid only when its archive and integrity record match the accepted bytes exactly.
