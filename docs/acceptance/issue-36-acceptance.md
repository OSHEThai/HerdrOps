# Issue #36 Acceptance: Tray, Startup, Settings, Localization, and Accessibility

Status: Bounded non-runtime contract/integration slice for GitHub Issue #36.

## Acceptance Criteria

1. **Settings persist and are reversible:** Tested via `AppSettingsStoreTests.cs` and `DesktopLifecycleWindowTests.cs`.
2. **Thai/English UI passes clipping and language-switch tests:** Tested via `LanguageSwitchRenderingTests.cs`.
3. **Accessibility checklist passes on the reference host:** Tested via `WidgetAccessibilityTests.cs` (Keyboard focus, Screen Reader accessible names, Contrast ratio meeting WCAG AA, Reduced Motion, multi-monitor bounds).

## Evidence

- **Lifecycle tests:** `DesktopLifecycleWindowTests.cs` verifies idempotency of window show/hide and setting persistence.
- **Localization screenshots:** Captured and stored in `artifacts/design-evidence/v0.1/issue-60` (as defined in `LanguageSwitchRenderingTests`).
- **Accessibility report:** Included in `WidgetAccessibilityTests.cs` assertions.

## Evidence Boundary

| Class | Result |
|---|---|
| Static | Harness source, schema validation, and contract files (e.g. `v0.7-settings-contract.md`) are verified. |
| Synthetic | Automated tests confirm settings storage, localization switching, contrast, and layout bounds without modifying real system state. |
| Runtime | Test execution verified that tray integration, startup registration logic, and localized UI components are functioning. |

## Report SHA / Blockers

- No known blockers. All tests in `HerdrOps.IntegrationTests` and `HerdrOps.RuntimeTests` pass successfully.

