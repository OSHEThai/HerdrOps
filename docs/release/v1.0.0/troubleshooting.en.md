# HerdrOps v1.0.0 troubleshooting

## The interface opens but is not live

Check the bottom connection bar. Core connectivity and Herdr connectivity are separate. Confirm that `HerdrOps.Core.exe serve-herdr-state` is running under the same Windows user and that the intended Herdr session is open. Reconnecting or offline state must not be interpreted as current Agent status.

## Core does not start

Run Core from a standard PowerShell window in the install directory and read the first reported error. Verify that all files came from one archive and that the archive SHA-256 matches `package-hashes.txt`. Do not run as Administrator to bypass a current-user path or pipe failure.

## A second App window does not open

HerdrOps uses a per-user single-instance gate. Show the existing window from the tray. If no tray icon exists, confirm the first process has exited before starting it again.

## The wrong language appears

Select Thai or English from the top bar. Only one selected interface language should be visible. If labels from both languages are stacked in one view, capture the page and report it as a defect.

## A Widget is missing

Open the tray menu, confirm the selected Widget type and enabled state, then show it again. Check multi-monitor edges if its last position is no longer visible.

## Settings or state appear damaged

Stop App and Core. Preserve `%LOCALAPPDATA%\HerdrOps` before attempting recovery. Use the diagnostic and recovery commands documented for the installed version. Do not delete or replace the live SQLite files while a HerdrOps process is running.

## An upgrade failed

Do not copy selected binaries over the failed installation. Stop all processes and follow the complete-directory rollback procedure in `upgrade-rollback.en.md`. Retain the failed package and state copy for diagnosis.

## Reporting a problem

Include the HerdrOps version, Windows version, whether the process was elevated, the visible Core/Herdr connection states, the exact time, the page or Widget, and a redacted diagnostic bundle. Do not include API keys, tokens, secrets, unrelated terminal text, or private file contents.
