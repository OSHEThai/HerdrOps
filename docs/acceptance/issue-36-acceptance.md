# Issue #36 Acceptance: Tray, Startup, Settings, Localization, Theme, Retention, and Accessibility

Status: PENDING (bounded Static/Contract/Synthetic preparation only)

This document records the acceptance boundary. It is not a human visual
approval and it is not Runtime or Release evidence. A candidate manifest is
admitted only through `tools/Test-V07Issue36Acceptance.ps1` and
`docs/acceptance/issue-36-acceptance.schema.json`.

## Acceptance matrix

| Area | Automated preparation | Human/Runtime acceptance |
|---|---|---|
| Settings persistence and reversible migration | Required `AppSettingsStoreTests` source and exact TRX binding | PENDING; no live AppData observation |
| Light/Dark/System theme logic and WPF resource swap | Required `UiThemeIntegrationTests` and `UiThemeWpfIntegrationTests` source/TRX bindings | PENDING; tests do not prove a full reference-host visual review |
| Thai/English language switching | Required `LanguageSwitchRenderingTests` source/TRX binding | PENDING; no accepted current WPF captures |
| Keyboard, names, contrast, reduced motion, and bounds | Required `WidgetAccessibilityTests` source/TRX binding | PENDING; no screen-reader or reference-host human sign-off |
| Retention/compliance behavior | Required `CompliancePrivacyRetentionIntegrationTests` source/TRX binding | PENDING; no production retention observation |
| Tray and start-at-logon seams | Required `TrayAndStartupLifecycleTests` source/TRX binding | PENDING; no real notification-area, Registry Run, or Startup-folder observation |

The lifecycle gate's existing 12 unit and 39 integration checks remain a
bounded implementation gate. They are not, by themselves, complete Issue #36
acceptance because they do not bind every visual/theme/language/accessibility/
retention record listed above. The new Issue #36 gate requires all seven
named test records, their exact source-file SHA-256 values, and their exact
TRX SHA-256 values.

## Immutable visual reference

The manifest must bind exactly `docs/design/reference/MANIFEST.md`, including
its current SHA-256 and eleven declared immutable PNG entries. The reference
PNG files and the manifest are not modified by this preparation change.
Actual WPF captures, comparison results, DPI/multi-monitor observations, and
human design/accessibility decisions remain outside this commit.

## Fail-closed fields

The policy rejects unknown or duplicate JSON properties, missing records,
duplicate test IDs, zero or stale hashes, unsafe evidence paths, failed TRX
results, and candidate commit/tree drift. A generated gate report is always
`PENDING`; it cannot populate a signer, role, date, signature, or human
decision. Human acceptance must be supplied later by a separate independent
review with real evidence.

## Evidence boundary

| Class | Current boundary |
|---|---|
| Static | PASS for the policy, schema, template, and parser checks in this preparation commit. |
| Contract | PASS for exact manifest shape, source/tree/reference/test/TRX bindings, and withheld claims. |
| Synthetic | PASS only for the gate's selftests; product test evidence is credited only when exact TRX files are supplied and verified. |
| Human | PENDING; no visual or accessibility sign-off is created here. |
| Runtime | NOT OBSERVED; no installed Herdr instance or live OS resource was used. |
| Release | NOT OBSERVED; no package, clean-machine run, or release decision was produced. |

## Required operator checks later

```powershell
pwsh -NoProfile -File tools/Test-V07Issue36Acceptance.ps1 `
  -ManifestPath <evidence-root>\issue-36-manifest.json `
  -EvidenceRoot <evidence-root> `
  -ExpectedSourceCommit <exact-lowercase-commit> `
  -ExpectedSourceTree <exact-lowercase-tree>
```

The same command must be run with Windows PowerShell 5.1 as a parser and
policy compatibility check. This preparation commit itself does not claim
that those product tests, captures, Runtime observations, or Release gates
have been run.
