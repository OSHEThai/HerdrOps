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
```
