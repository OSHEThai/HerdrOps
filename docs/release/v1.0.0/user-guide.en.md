# HerdrOps v1.0.0 user guide

## Requirements

- Windows 11 x64.
- A standard, non-elevated Windows account.
- Herdr installed and a local Herdr session available.
- The accepted `HerdrOps-1.0.0-win-x64.zip` and its matching `package-hashes.txt` from the same GitHub Release.

## Verify the download

Keep the archive and integrity record together. Compare the archive SHA-256 with `ArchiveSha256` in `package-hashes.txt` before extracting it:

```powershell
Get-FileHash .\HerdrOps-1.0.0-win-x64.zip -Algorithm SHA256
Get-Content .\package-hashes.txt
```

Do not continue when the file name, byte length, or SHA-256 differs.

## Install

1. Close any running HerdrOps processes.
2. Create `%LOCALAPPDATA%\Programs\HerdrOps` for the current user.
3. Extract the verified archive into that directory without flattening or renaming files.
4. Confirm that `HerdrOps.App.exe`, `HerdrOps.Core.exe`, and `HerdrOps.Cli.exe` are present.

The package does not require Administrator rights and does not install a Windows service.

## Start

1. Start Herdr and open the local workspace that HerdrOps should observe.
2. Start the local state service from the install directory:

   ```powershell
   .\HerdrOps.Core.exe serve-herdr-state
   ```

3. Start the desktop interface:

   ```powershell
   .\HerdrOps.App.exe
   ```

4. Wait for the bottom connection bar to distinguish Core connectivity from live Herdr connectivity. Do not treat last-known Agent values as current while the interface reports reconnecting or offline.

## Language and Widget

Use the language control in the top bar to select Thai or English. The whole visible interface switches to that language; product names, Agent names, identifiers, paths, and protocol values remain literal. Use the tray menu or settings to choose and show a Widget.

## Stop and uninstall

Exit the desktop interface from its tray menu, then stop the Core console with `Ctrl+C`. To uninstall, remove `%LOCALAPPDATA%\Programs\HerdrOps`. User state remains under `%LOCALAPPDATA%\HerdrOps` by policy. Back up that directory before deleting it deliberately.

## Evidence interpretation

Herdr status, locally observed activity, inferred correlation, and Agent self-report are different sources. Use the source, confidence, freshness, and review status shown in the interface before acting on an alert or score.
