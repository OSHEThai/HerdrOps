# Tools

Build, verification, GitHub roadmap, evidence capture, and packaging helpers live here. Release tools must operate on exact artifact bytes and record SHA-256 hashes.

```powershell
# Build and test using committed package locks
./tools/Invoke-Build.ps1

# Refresh package locks intentionally
./tools/Invoke-Build.ps1 -UpdateLockFiles

# Verify formatting without changing files
./tools/Invoke-Format.ps1

# Apply formatting
./tools/Invoke-Format.ps1 -Apply

# Validate the exact installed Herdr binary and bounded v0.2 protocol contract
./tools/Test-V02ProtocolContract.ps1

# Extract and validate the exact bundled Herdr JSON Schema successor contract
./tools/Test-V02BundledSchemaContract.ps1

# From an authorized live Herdr environment, capture snapshot/event/reconnect evidence
./tools/Test-V02HerdrRuntime.ps1 -DurationSeconds 120

# Verify SQLite WAL restart/migration and current-user Core-to-App IPC evidence
./tools/Test-V02StateStoreIpc.ps1
```
