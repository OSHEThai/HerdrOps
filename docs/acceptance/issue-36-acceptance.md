# Issue #36 Acceptance: Tray, Startup, Settings, Localization, and Accessibility

Status: FAIL-CLOSED (Incomplete implementation and missing runtime evidence)

## Assessment of Missing Scope
Based on GitHub Issue #36 and `Plan/ROADMAP.md` (v0.7.0):
- **Theme settings**: Missing. Not implemented in `AppSettings` or tested.
- **Retention settings**: Missing from acceptance report criteria (though integration tests exist in `CompliancePrivacyRetentionIntegrationTests.cs`).
- **Startup (Start-at-logon)**: Missing from acceptance report criteria (though unit tests exist in `TrayAndStartupLifecycleTests.cs`).

## Acceptance Criteria Status

1. [x] **Settings persist and are reversible:** Tested via `AppSettingsStoreTests.cs` and `DesktopLifecycleWindowTests.cs`.
2. [x] **Thai/English UI passes clipping and language-switch tests:** Tested via `LanguageSwitchRenderingTests.cs`.
3. [x] **Accessibility checklist passes on the reference host:** Tested via `WidgetAccessibilityTests.cs` (Keyboard focus, Screen Reader accessible names, Contrast ratio meeting WCAG AA, Reduced Motion, multi-monitor bounds).
4. [ ] **Theme settings implemented:** FAILED (Missing implementation).
5. [ ] **Retention settings verified:** FAILED (Not reported in acceptance).
6. [ ] **Startup (start-at-logon) integration verified:** FAILED (Not reported in acceptance).

## Evidence

- **Lifecycle tests:** `DesktopLifecycleWindowTests.cs` verifies idempotency of window show/hide and setting persistence.
- **Localization screenshots:** Captured and stored in `artifacts/design-evidence/v0.1/issue-60` (as defined in `LanguageSwitchRenderingTests`).
- **Accessibility report:** Included in `WidgetAccessibilityTests.cs` assertions.

## Evidence Boundary

| Class | Result |
|---|---|
| Static | Harness source, schema validation, and contract files (e.g. `v0.7-settings-contract.md`) are verified. |
| Synthetic | Automated tests confirm settings storage, localization switching, contrast, layout bounds, tray integration, and startup registration logic without modifying real system state. (Note: `HerdrOps.RuntimeTests` only contains Synthetic evidence as it does not test an actual installed Herdr instance). |
| Contract | Verified via `HerdrOps.ContractTests`. |
| Runtime | FAILED (No actual installed Herdr runtime tests provided. Evidence previously claimed under Runtime is actually Synthetic/Contract). |

## Report SHA / Blockers

- **Command executed**: `dotnet test HerdrOps.sln`
- **Result**: Tests pass, but acceptance fails due to missing features and missing evidence.
- **Blocker 1**: Theme settings are completely missing from implementation and tests.
- **Blocker 2**: Retention and Startup features are not properly documented in the acceptance criteria, even though tests exist.
- **Blocker 3**: Runtime evidence is incorrectly claimed. Tests in `RuntimeTests` do not use an actual installed Herdr, so they must be classified as Static/Synthetic/Contract. Real Runtime evidence is missing.
