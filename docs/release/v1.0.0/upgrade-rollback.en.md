# HerdrOps v1.0.0 upgrade and rollback

## Safety rules

- Use only an accepted archive and its matching integrity record.
- Close `HerdrOps.App`, `HerdrOps.Core`, and `HerdrOps.Cli` before changing application files.
- Back up `%LOCALAPPDATA%\HerdrOps` before an upgrade.
- Never mix files from two package versions.
- A rollback package must be the exact previously accepted package, not a rebuild from the same commit.

## Upgrade from an accepted Beta

1. Verify the v1.0.0 archive SHA-256.
2. Stop all HerdrOps processes.
3. Copy the current `%LOCALAPPDATA%\Programs\HerdrOps` directory to a uniquely named backup beside it.
4. Extract v1.0.0 into a new staging directory beside the install directory.
5. Verify every staged file against `package-manifest.json`.
6. Rename the current install directory to a backup name, then rename the staged directory to `HerdrOps`.
7. Start Core and App, confirm the expected version, connection states, language, settings, and retained data.
8. Keep the previous package backup until acceptance is complete.

Do not repair a failed upgrade by copying individual DLL files. Restore the complete previous directory instead.

## Rollback

1. Stop all HerdrOps processes.
2. Preserve a copy of the current user-state directory for diagnosis.
3. Verify the exact previous package backup and its integrity record.
4. Move the current application directory aside; do not merge it with the backup.
5. Restore the complete previous application directory atomically when possible.
6. Start Core and App and verify the previous version and data behavior.

Database migration is forward-only. Restore state only through the versioned recovery command and an exact pre-upgrade backup. Do not replace a live database manually.

## Uninstall retention

Removing `%LOCALAPPDATA%\Programs\HerdrOps` uninstalls application files. `%LOCALAPPDATA%\HerdrOps` is retained. Deleting retained data is a separate, deliberate user action and cannot be undone without a backup.
