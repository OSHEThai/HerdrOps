# Issue #36 Acceptance: Tray, Startup, Settings, Localization, and Accessibility

Status: FAIL-CLOSED (Incomplete runtime evidence)

## Assessment of Missing Scope
Based on GitHub Issue #36 and `Plan/ROADMAP.md` (v0.7.0):
- **Theme settings**: Implemented and tested via `UiThemeIntegrationTests` and `AppSettingsStoreTests`.
- **Retention settings**: Missing from acceptance report criteria (though integration tests exist in `CompliancePrivacyRetentionIntegrationTests.cs`).
- **Startup (Start-at-logon)**: Missing from acceptance report criteria (though unit tests exist in `TrayAndStartupLifecycleTests.cs`).

## Acceptance Criteria Status

1. [x] **Settings persist and are reversible:** Tested via `AppSettingsStoreTests.cs` and `DesktopLifecycleWindowTests.cs`.
2. [x] **Thai/English UI passes clipping and language-switch tests:** Tested via `LanguageSwitchRenderingTests.cs`.
3. [x] **Accessibility checklist passes on the reference host:** Tested via `WidgetAccessibilityTests.cs` (Keyboard focus, Screen Reader accessible names, Contrast ratio meeting WCAG AA, Reduced Motion, multi-monitor bounds).
4. [x] **Theme settings implemented:** Basic Light/Dark/System ResourceDictionary swapping, System theme sync, and backward-compatible settings migration implemented. Tray selector added. Full visual restyling coverage across all views is not guaranteed.
5. [ ] **Retention settings verified:** FAILED (Not reported in acceptance).
6. [ ] **Startup (start-at-logon) integration verified:** FAILED (Not reported in acceptance).

## Evidence

- **Lifecycle tests:** `DesktopLifecycleWindowTests.cs` verifies idempotency of window show/hide and setting persistence.
- **Localization screenshots:** Captured and stored in `artifacts/design-evidence/v0.1/issue-60` (as defined in `LanguageSwitchRenderingTests`).
- **Accessibility report:** Included in `WidgetAccessibilityTests.cs` assertions.
- **Theme settings tests:** `UiThemeIntegrationTests.cs` verifies runtime resource swapping and synchronization logic, and `AppSettingsStoreTests.cs` verifies backward-compatible config migration.

## Evidence Boundary

| Class | Result |
|---|---|
| Static | Harness source, schema validation, and contract files (e.g. `v0.7-settings-contract.md`) are verified. |
| Synthetic | Automated tests confirm settings storage, localization switching, contrast, layout bounds, tray integration, startup registration logic, and theme apply without modifying real system state. (Note: `HerdrOps.RuntimeTests` only contains Synthetic evidence as it does not test an actual installed Herdr instance). |
| Contract | Verified via `HerdrOps.ContractTests`. |
| Runtime | FAILED (No actual installed Herdr runtime tests provided. Evidence previously claimed under Runtime is actually Synthetic/Contract). |

## Report SHA / Blockers

- **Command executed**: `dotnet test HerdrOps.sln`
- **Result**: UNVERIFIED/FAILED DUE TO TEST ARTIFACT LOCK (1 failed in HerdrOps.RuntimeTests due to IOException file lock on live-organization-compact.png). This is distinct from product defects and runtime blockers.
- **Blocker 1**: Theme settings are now implemented but Runtime evidence is still missing.
- **Blocker 2**: Retention and Startup features are not properly documented in the acceptance criteria, even though tests exist.
- **Blocker 3**: Runtime evidence is incorrectly claimed. Tests in `RuntimeTests` do not use an actual installed Herdr, so they must be classified as Static/Synthetic/Contract. Real Runtime evidence is missing.
