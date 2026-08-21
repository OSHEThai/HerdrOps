#requires -Version 5.1

Set-StrictMode -Version Latest

$script:MaxInstallerArchiveEntries = [long]4096
$script:MaxInstallerArchiveExpandedBytes = ([long]512 * 1024 * 1024)
$script:InstallerLockWaitMilliseconds = 10000

function Get-DefaultHerdrOpsInstallRoot {
    if (-not [string]::IsNullOrWhiteSpace($env:LOCALAPPDATA)) {
        return (Join-Path $env:LOCALAPPDATA 'Programs\HerdrOps')
    }
    if (-not [string]::IsNullOrWhiteSpace($env:USERPROFILE)) {
        return (Join-Path $env:USERPROFILE 'AppData\Local\Programs\HerdrOps')
    }
    $localAppData = [Environment]::GetFolderPath([Environment+SpecialFolder]::LocalApplicationData)
    if (-not [string]::IsNullOrWhiteSpace($localAppData)) {
        return (Join-Path $localAppData 'Programs\HerdrOps')
    }
    $userProfile = [Environment]::GetFolderPath([Environment+SpecialFolder]::UserProfile)
    return (Join-Path $userProfile 'AppData\Local\Programs\HerdrOps')
}

function Get-DefaultHerdrOpsUserDataRoot {
    if (-not [string]::IsNullOrWhiteSpace($env:LOCALAPPDATA)) {
        return (Join-Path $env:LOCALAPPDATA 'HerdrOps')
    }
    if (-not [string]::IsNullOrWhiteSpace($env:USERPROFILE)) {
        return (Join-Path $env:USERPROFILE 'AppData\Local\HerdrOps')
    }
    $localAppData = [Environment]::GetFolderPath([Environment+SpecialFolder]::LocalApplicationData)
    if (-not [string]::IsNullOrWhiteSpace($localAppData)) {
        return (Join-Path $localAppData 'HerdrOps')
    }
    $userProfile = [Environment]::GetFolderPath([Environment+SpecialFolder]::UserProfile)
    return (Join-Path $userProfile 'AppData\Local\HerdrOps')
}

function Get-SafeInstallerPath {
    param([Parameter(Mandatory = $true)][string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path) -or $Path.IndexOfAny([char[]]@('*', '?')) -ge 0) {
        throw "Installer path must be a non-empty literal path without wildcards: $Path"
    }

    try {
        $fullPath = [System.IO.Path]::GetFullPath($Path)
        return $fullPath
    } catch {
        throw "Installer path is invalid: $Path. $($_.Exception.Message)"
    }
}

function Assert-NoReparsePath {
    param([Parameter(Mandatory = $true)][string]$Path)

    $current = Get-SafeInstallerPath -Path $Path
    while (-not [string]::IsNullOrWhiteSpace($current)) {
        if (Test-Path -LiteralPath $current) {
            $item = Get-Item -LiteralPath $current -Force
            if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                throw "Reparse points are not allowed in installer paths: $current"
            }
        }

        $parent = Split-Path -Path $current -Parent
        if ([string]::IsNullOrWhiteSpace($parent) -or
            $parent.Equals($current, [StringComparison]::OrdinalIgnoreCase)) {
            break
        }
        $current = Get-SafeInstallerPath -Path $parent
    }
}

function Assert-NoReparseDescendants {
    param([Parameter(Mandatory = $true)][string]$Path)

    $fullPath = Get-SafeInstallerPath -Path $Path
    if (-not (Test-Path -LiteralPath $fullPath)) {
        return
    }

    Assert-NoReparsePath -Path $fullPath
    $items = @(Get-ChildItem -LiteralPath $fullPath -Force -Recurse -ErrorAction Stop)
    foreach ($item in $items) {
        if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw "Reparse points are not allowed below installer path: $($item.FullName)"
        }
    }
    Assert-NoReparsePath -Path $fullPath
}

function Test-IsReservedWindowsDeviceComponent {
    param([Parameter(Mandatory = $true)][string]$Component)

    if ($Component.Length -eq 0) {
        return $true
    }
    $lastCharacter = $Component[$Component.Length - 1]
    if ($lastCharacter -eq '.' -or $lastCharacter -eq ' ') {
        return $true
    }

    $trimmed = $Component.TrimEnd([char[]]@('.', ' '))
    $stem = $trimmed.Split('.')[0].ToUpperInvariant()
    if ($stem -in @('CON', 'PRN', 'AUX', 'NUL', 'CONIN$', 'CONOUT$')) {
        return $true
    }
    if ($stem -match '^COM[1-9]$' -or $stem -match '^LPT[1-9]$') {
        return $true
    }
    return $false
}

function Assert-SafeArchiveEntryName {
    param([Parameter(Mandatory = $true)][string]$EntryName)

    if ([string]::IsNullOrWhiteSpace($EntryName) -or
        $EntryName.Contains('\') -or
        $EntryName.StartsWith('/', [StringComparison]::Ordinal) -or
        $EntryName.Contains('//') -or
        $EntryName -match '(^|/)\.\.?(/|$)' -or
        $EntryName -match '[\x00-\x1F<>:"|?*]' -or
        [IO.Path]::IsPathRooted($EntryName)) {
        throw "Archive contains an unsafe entry (zip-slip or invalid path): '$EntryName'."
    }

    $isDirectory = $EntryName.EndsWith('/', [StringComparison]::Ordinal)
    $components = @($EntryName.Split('/'))
    if ($isDirectory) {
        $components = @($components | Select-Object -SkipLast 1)
    }
    foreach ($component in $components) {
        if ([string]::IsNullOrWhiteSpace($component) -or
            $component -eq '.' -or $component -eq '..') {
            throw "Archive contains an unsafe entry (zip-slip or invalid path): '$EntryName'."
        }
        if (Test-IsReservedWindowsDeviceComponent -Component $component) {
            throw "Archive contains a Windows device-name entry: '$EntryName'."
        }
    }

    return $isDirectory
}

function Expand-HerdrOpsArchiveSafe {
    param(
        [Parameter(Mandatory = $true)][string]$ArchivePath,
        [Parameter(Mandatory = $true)][string]$DestinationPath
    )

    $archiveFullPath = Get-SafeInstallerPath -Path $ArchivePath
    $destFullPath = Get-SafeInstallerPath -Path $DestinationPath

    if (-not (Test-Path -LiteralPath $archiveFullPath -PathType Leaf)) {
        throw "Archive not found: $archiveFullPath"
    }

    Assert-NoReparsePath -Path $archiveFullPath
    Assert-NoReparsePath -Path $destFullPath

    try {
        Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction Stop
    } catch {
        if ($null -eq ('System.IO.Compression.ZipFile' -as [type])) {
            throw "Could not load ZIP support: $($_.Exception.Message)"
        }
    }

    $archive = $null
    try {
        $archive = [IO.Compression.ZipFile]::OpenRead($archiveFullPath)
        $destWithSeparator = if ($destFullPath.EndsWith('\')) { $destFullPath } else { $destFullPath + '\' }
        $extractedPaths = @{}
        $entryCount = [long]0
        $expandedBytes = [long]0

        # Validate every entry before creating or modifying the destination.
        foreach ($entry in $archive.Entries) {
            $entryCount++
            if ($entryCount -gt $script:MaxInstallerArchiveEntries) {
                throw "Archive contains too many entries: $entryCount exceeds $script:MaxInstallerArchiveEntries."
            }

            $entryName = [string]$entry.FullName
            $isDir = Assert-SafeArchiveEntryName -EntryName $entryName
            $entryLength = [long]$entry.Length
            if ($entryLength -lt 0 -or
                $entryLength -gt ($script:MaxInstallerArchiveExpandedBytes - $expandedBytes)) {
                throw "Archive expanded bytes exceed the installer limit of $script:MaxInstallerArchiveExpandedBytes."
            }
            $expandedBytes += $entryLength

            if ((($entry.ExternalAttributes -shr 16) -band 0xF000) -eq 0xA000 -or ($entry.ExternalAttributes -band 0x400) -eq 0x400) {
                throw "Archive contains unsupported symlink or reparse point: '$entryName'."
            }

            $destinationEntryPath = Get-SafeInstallerPath -Path (Join-Path $destFullPath $entryName.Replace('/', '\'))
            if (-not $destinationEntryPath.StartsWith($destWithSeparator, [StringComparison]::OrdinalIgnoreCase) -and
                $destinationEntryPath -ne $destFullPath) {
                throw "Archive entry attempts to extract outside destination (zip-slip): '$entryName'."
            }

            $normalizedPath = $destinationEntryPath.ToLowerInvariant()
            if ($extractedPaths.ContainsKey($normalizedPath)) {
                if ($extractedPaths[$normalizedPath] -ne $isDir) {
                    throw "Archive contains case-insensitive file-vs-directory collision: '$entryName'."
                }
                throw "Archive contains case-insensitive duplicate entry: '$entryName'."
            }
            $extractedPaths[$normalizedPath] = $isDir

            $current = $destinationEntryPath
            while ($true) {
                $parent = Split-Path -Path $current -Parent
                if ([string]::IsNullOrWhiteSpace($parent) -or
                    $parent.Equals($current, [StringComparison]::OrdinalIgnoreCase) -or
                    ((-not $parent.StartsWith($destWithSeparator, [StringComparison]::OrdinalIgnoreCase)) -and
                        $parent -ne $destFullPath)) {
                    break
                }
                $normalizedParent = $parent.ToLowerInvariant()
                if ($extractedPaths.ContainsKey($normalizedParent) -and -not $extractedPaths[$normalizedParent]) {
                    throw "Archive entry collides with a file in parent path: '$entryName'."
                }
                $extractedPaths[$normalizedParent] = $true
                $current = $parent
            }
        }

        Assert-NoReparsePath -Path $destFullPath
        if (Test-Path -LiteralPath $destFullPath) {
            $destinationItem = Get-Item -LiteralPath $destFullPath -Force -ErrorAction Stop
            if (-not $destinationItem.PSIsContainer) {
                throw "Archive destination is not a directory: $destFullPath"
            }
        } else {
            $null = [IO.Directory]::CreateDirectory($destFullPath)
        }
        Assert-NoReparsePath -Path $destFullPath

        # Revalidate the destination and each parent immediately before every write.
        foreach ($entry in $archive.Entries) {
            Assert-NoReparsePath -Path $destFullPath
            $entryName = [string]$entry.FullName
            $isDir = $entryName.EndsWith('/', [StringComparison]::Ordinal)
            $destinationEntryPath = Get-SafeInstallerPath -Path (Join-Path $destFullPath $entryName.Replace('/', '\'))
            $entryParent = Split-Path -Path $destinationEntryPath -Parent
            Assert-NoReparsePath -Path $entryParent

            if ($isDir) {
                if (Test-Path -LiteralPath $destinationEntryPath) {
                    $existingDirectory = Get-Item -LiteralPath $destinationEntryPath -Force -ErrorAction Stop
                    if (-not $existingDirectory.PSIsContainer) {
                        throw "Archive destination path is not a directory: $destinationEntryPath"
                    }
                    Assert-NoReparsePath -Path $destinationEntryPath
                } else {
                    $null = [IO.Directory]::CreateDirectory($destinationEntryPath)
                    Assert-NoReparsePath -Path $destinationEntryPath
                }
                continue
            }

            if (-not (Test-Path -LiteralPath $entryParent)) {
                $null = [IO.Directory]::CreateDirectory($entryParent)
            }
            Assert-NoReparsePath -Path $entryParent
            if (Test-Path -LiteralPath $destinationEntryPath) {
                $existingFile = Get-Item -LiteralPath $destinationEntryPath -Force -ErrorAction Stop
                if ($existingFile.PSIsContainer) {
                    throw "Archive destination path is a directory: $destinationEntryPath"
                }
                Assert-NoReparsePath -Path $destinationEntryPath
            }
            [IO.Compression.ZipFileExtensions]::ExtractToFile($entry, $destinationEntryPath, $true)
            Assert-NoReparsePath -Path $destinationEntryPath
        }
    } finally {
        if ($null -ne $archive) {
            $archive.Dispose()
        }
    }
}

function Remove-DirectoryTreeSafe {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Context
    )

    $fullPath = Get-SafeInstallerPath -Path $Path
    if (-not (Test-Path -LiteralPath $fullPath)) {
        return
    }
    Assert-NoReparsePath -Path $fullPath
    $item = Get-Item -LiteralPath $fullPath -Force -ErrorAction Stop
    if (-not $item.PSIsContainer) {
        throw "$Context target must be a directory: $fullPath"
    }
    Assert-NoReparseDescendants -Path $fullPath
    Assert-NoReparsePath -Path $fullPath
    Remove-Item -LiteralPath $fullPath -Recurse -Force -ErrorAction Stop
}

function Assert-InstallerRunId {
    param([Parameter(Mandatory = $true)][string]$RunId)

    if ($RunId -notmatch '^[0-9a-fA-F]{32}$') {
        throw "Installer run ID is invalid: $RunId"
    }
    return $RunId.ToLowerInvariant()
}

function Get-InstallerLockName {
    param([Parameter(Mandatory = $true)][string]$InstallRoot)

    $target = Get-SafeInstallerPath -Path $InstallRoot
    $bytes = [Text.Encoding]::UTF8.GetBytes($target.ToUpperInvariant())
    $sha = $null
    try {
        $sha = [Security.Cryptography.SHA256]::Create()
        $digest = $sha.ComputeHash($bytes)
    } finally {
        if ($null -ne $sha) {
            $sha.Dispose()
        }
    }
    $hex = [BitConverter]::ToString($digest).Replace('-', '')
    return "Local\HerdrOps.Installer.$hex"
}

function Enter-InstallerLock {
    param([Parameter(Mandatory = $true)][string]$InstallRoot)

    $target = Get-SafeInstallerPath -Path $InstallRoot
    $parent = Split-Path -Path $target -Parent
    Assert-NoReparsePath -Path $parent
    if (-not (Test-Path -LiteralPath $parent)) {
        $null = [IO.Directory]::CreateDirectory($parent)
    }
    Assert-NoReparsePath -Path $parent

    $mutex = $null
    $acquired = $false
    try {
        $mutex = [Threading.Mutex]::new($false, (Get-InstallerLockName -InstallRoot $target))
        try {
            $acquired = $mutex.WaitOne($script:InstallerLockWaitMilliseconds)
        } catch [Threading.AbandonedMutexException] {
            $acquired = $true
        }
        if (-not $acquired) {
            throw "Failed to acquire installer lock for target: $target"
        }

        Assert-NoReparsePath -Path $parent
        return [pscustomobject]@{
            Mutex       = $mutex
            Acquired    = $true
            InstallRoot = $target
        }
    } catch {
        if ($null -ne $mutex) {
            if ($acquired) {
                try { $mutex.ReleaseMutex() } catch { }
            }
            try { $mutex.Dispose() } catch { }
        }
        throw
    }
}

function Exit-InstallerLock {
    param([Parameter(Mandatory = $true)][psobject]$Lock)

    $releaseException = $null
    try {
        if ($Lock.Acquired) {
            $Lock.Mutex.ReleaseMutex()
            $Lock.Acquired = $false
        }
    } catch {
        $releaseException = $_.Exception
    }

    try {
        $Lock.Mutex.Dispose()
    } catch {
        if ($null -eq $releaseException) {
            $releaseException = $_.Exception
        }
    }

    if ($null -ne $releaseException) {
        throw $releaseException
    }
}

function New-InstallerAggregateException {
    param(
        [Parameter(Mandatory = $true)][System.Exception]$PrimaryException,
        [Parameter(Mandatory = $true)][string[]]$AdditionalContexts
    )

    $messages = @($PrimaryException.Message)
    foreach ($context in $AdditionalContexts) {
        if (-not [string]::IsNullOrWhiteSpace($context)) {
            $messages += $context
        }
    }
    return (New-Object System.Exception -ArgumentList @($messages -join ' ', $PrimaryException))
}

function Invoke-WithInstallerLock {
    param(
        [Parameter(Mandatory = $true)][string]$InstallRoot,
        [Parameter(Mandatory = $true)][scriptblock]$Action
    )

    $lock = Enter-InstallerLock -InstallRoot $InstallRoot
    $primaryException = $null
    $actionOutput = @()
    try {
        $actionOutput = @(& $Action)
    } catch {
        $primaryException = $_.Exception
    }

    $releaseException = $null
    try {
        Exit-InstallerLock -Lock $lock
    } catch {
        $releaseException = $_.Exception
    }

    if ($null -ne $primaryException) {
        if ($null -ne $releaseException) {
            throw (New-InstallerAggregateException -PrimaryException $primaryException -AdditionalContexts @(
                "Lock release also failed: $($releaseException.Message)"
            ))
        }
        throw $primaryException
    }
    if ($null -ne $releaseException) {
        throw $releaseException
    }
    return $actionOutput
}

function Get-InstallerTransientDirectories {
    param([Parameter(Mandatory = $true)][string]$Parent)

    $fullParent = Get-SafeInstallerPath -Path $Parent
    if (-not (Test-Path -LiteralPath $fullParent -PathType Container)) {
        return @()
    }
    Assert-NoReparsePath -Path $fullParent
    $items = @(Get-ChildItem -LiteralPath $fullParent -Directory -Force -ErrorAction Stop |
        Where-Object { $_.Name -match '^HerdrOps\.(stage|backup)-[0-9a-fA-F]{32}$' })
    foreach ($item in $items) {
        Assert-NoReparsePath -Path $item.FullName
    }
    return $items
}

function Recover-HerdrOpsTransitionState {
    param(
        [Parameter(Mandatory = $true)][string]$InstallRoot,
        [Parameter(Mandatory = $true)][ValidateSet('Install', 'Uninstall')][string]$Operation
    )

    $target = Get-SafeInstallerPath -Path $InstallRoot
    $parent = Split-Path -Path $target -Parent
    if (-not (Test-Path -LiteralPath $parent -PathType Container)) {
        return
    }
    Assert-NoReparsePath -Path $parent

    $transients = @(Get-InstallerTransientDirectories -Parent $parent)
    $stages = @($transients | Where-Object { $_.Name.StartsWith('HerdrOps.stage-', [StringComparison]::Ordinal) })
    $backups = @($transients | Where-Object { $_.Name.StartsWith('HerdrOps.backup-', [StringComparison]::Ordinal) })

    foreach ($stage in $stages) {
        Remove-DirectoryTreeSafe -Path $stage.FullName -Context 'Interrupted installer stage cleanup'
    }

    $targetExists = Test-Path -LiteralPath $target
    if ($targetExists) {
        $targetItem = Get-Item -LiteralPath $target -Force -ErrorAction Stop
        if (-not $targetItem.PSIsContainer) {
            throw "Installer target is not a directory: $target"
        }
        Assert-NoReparseDescendants -Path $target
    }

    if ($backups.Count -gt 1) {
        throw "Multiple interrupted installer backups require manual review under: $parent"
    }
    if ($backups.Count -eq 1) {
        $backupPath = $backups[0].FullName
        if ($targetExists) {
            Remove-DirectoryTreeSafe -Path $backupPath -Context 'Completed installer backup cleanup'
        } elseif ($Operation -eq 'Install') {
            Assert-NoReparsePath -Path $parent
            [IO.Directory]::Move($backupPath, $target)
            Assert-NoReparseDescendants -Path $target
        } else {
            Remove-DirectoryTreeSafe -Path $backupPath -Context 'Interrupted uninstall backup cleanup'
        }
    }
}

function Ensure-RetainedUserDataRoot {
    param([Parameter(Mandatory = $true)][string]$UserDataRoot)

    $fullUserDataRoot = Get-SafeInstallerPath -Path $UserDataRoot
    Assert-NoReparsePath -Path $fullUserDataRoot
    if (Test-Path -LiteralPath $fullUserDataRoot) {
        $userDataItem = Get-Item -LiteralPath $fullUserDataRoot -Force -ErrorAction Stop
        if (-not $userDataItem.PSIsContainer) {
            throw "User data root is not a directory: $fullUserDataRoot"
        }
    } else {
        $null = [IO.Directory]::CreateDirectory($fullUserDataRoot)
    }
    Assert-NoReparsePath -Path $fullUserDataRoot

    $markerPath = Join-Path $fullUserDataRoot '.herdrops-retained-data'
    Assert-NoReparsePath -Path $markerPath
    if (Test-Path -LiteralPath $markerPath) {
        $markerItem = Get-Item -LiteralPath $markerPath -Force -ErrorAction Stop
        if ($markerItem.PSIsContainer) {
            throw "Retained-data marker is a directory: $markerPath"
        }
    } else {
        $utf8 = [Text.UTF8Encoding]::new($false)
        [IO.File]::WriteAllText($markerPath, 'HerdrOps Retained User Data Policy Marker', $utf8)
    }
    Assert-NoReparsePath -Path $fullUserDataRoot
    Assert-NoReparsePath -Path $markerPath
}

function Invoke-AtomicInstallTransition {
    param(
        [Parameter(Mandatory = $true)][string]$ArchivePath,
        [Parameter(Mandatory = $true)][string]$InstallRoot,
        [Parameter(Mandatory = $true)][string]$RunId,
        [Parameter(Mandatory = $false)][string]$UserDataRoot
    )

    $normalizedRunId = Assert-InstallerRunId -RunId $RunId
    Invoke-WithInstallerLock -InstallRoot $InstallRoot -Action {
        $target = Get-SafeInstallerPath -Path $InstallRoot
        $parent = Split-Path -Path $target -Parent
        Assert-NoReparsePath -Path $parent
        Recover-HerdrOpsTransitionState -InstallRoot $target -Operation Install

        if (-not [string]::IsNullOrWhiteSpace($UserDataRoot)) {
            Ensure-RetainedUserDataRoot -UserDataRoot $UserDataRoot
        }

        $targetExists = Test-Path -LiteralPath $target
        if ($targetExists) {
            $targetItem = Get-Item -LiteralPath $target -Force -ErrorAction Stop
            if (-not $targetItem.PSIsContainer) {
                throw "Installer target is not a directory: $target"
            }
            Assert-NoReparseDescendants -Path $target
        }

        $stage = Join-Path $parent "HerdrOps.stage-$normalizedRunId"
        $backup = Join-Path $parent "HerdrOps.backup-$normalizedRunId"
        $oldMoved = $false
        $committed = $false
        $preserveTransient = $false
        $primaryException = $null
        $cleanupContexts = @()
        $postCommitWarning = $null

        try {
            Assert-NoReparsePath -Path $parent
            if (Test-Path -LiteralPath $stage) {
                Remove-DirectoryTreeSafe -Path $stage -Context 'Pre-existing stage cleanup'
            }
            $null = [IO.Directory]::CreateDirectory($stage)
            Assert-NoReparsePath -Path $stage

            Expand-HerdrOpsArchiveSafe -ArchivePath $ArchivePath -DestinationPath $stage
            Assert-NoReparseDescendants -Path $stage

            if ($targetExists) {
                if (Test-Path -LiteralPath $backup) {
                    Remove-DirectoryTreeSafe -Path $backup -Context 'Pre-existing backup cleanup'
                }
                Assert-NoReparsePath -Path $parent
                [IO.Directory]::Move($target, $backup)
                $oldMoved = $true
            }

            Assert-NoReparsePath -Path $parent
            [IO.Directory]::Move($stage, $target)
            $stage = $null
            $committed = $true
            Assert-NoReparseDescendants -Path $target

            if (Test-Path -LiteralPath $backup) {
                try {
                    Remove-DirectoryTreeSafe -Path $backup -Context 'Backup retirement'
                    $backup = $null
                } catch {
                    $preserveTransient = $true
                    $postCommitWarning = "Installed successfully but backup retirement failed: $($_.Exception.Message)"
                }
            }
        } catch {
            $primaryException = $_.Exception
            if (-not $committed) {
                try {
                    if ($null -ne $stage -and (Test-Path -LiteralPath $stage)) {
                        Remove-DirectoryTreeSafe -Path $stage -Context 'Stage rollback'
                        $stage = $null
                    }
                    if ($oldMoved -and (Test-Path -LiteralPath $backup)) {
                        if (Test-Path -LiteralPath $target) {
                            throw 'Rollback refused to remove an unexpected target directory.'
                        }
                        [IO.Directory]::Move($backup, $target)
                        $backup = $null
                    } elseif (Test-Path -LiteralPath $backup) {
                        Remove-DirectoryTreeSafe -Path $backup -Context 'Backup rollback cleanup'
                        $backup = $null
                    }
                } catch {
                    $preserveTransient = $true
                    $cleanupContexts += "Rollback also failed: $($_.Exception.Message)"
                }
            } else {
                $preserveTransient = $true
            }
        }

        if (-not $preserveTransient -and $null -ne $stage -and (Test-Path -LiteralPath $stage)) {
            try {
                Remove-DirectoryTreeSafe -Path $stage -Context 'Final stage cleanup'
                $stage = $null
            } catch {
                $cleanupContexts += "Cleanup also failed: $($_.Exception.Message)"
            }
        }
        if (-not $preserveTransient -and $null -ne $backup -and (Test-Path -LiteralPath $backup)) {
            try {
                Remove-DirectoryTreeSafe -Path $backup -Context 'Final backup cleanup'
                $backup = $null
            } catch {
                $cleanupContexts += "Cleanup also failed: $($_.Exception.Message)"
            }
        }

        if ($null -ne $postCommitWarning) {
            Write-Warning $postCommitWarning
        }
        if ($null -ne $primaryException) {
            if ($cleanupContexts.Count -gt 0) {
                throw (New-InstallerAggregateException -PrimaryException $primaryException -AdditionalContexts $cleanupContexts)
            }
            throw $primaryException
        }
        if ($cleanupContexts.Count -gt 0) {
            throw (New-Object System.Exception -ArgumentList @($cleanupContexts -join ' '))
        }
    } | Out-Null
}

function Invoke-AtomicUninstallTransition {
    param(
        [Parameter(Mandatory = $true)][string]$InstallRoot,
        [Parameter(Mandatory = $true)][string]$RunId,
        [Parameter(Mandatory = $false)][string]$UserDataRoot,
        [Parameter(Mandatory = $false)][switch]$RemoveUserData
    )

    $normalizedRunId = Assert-InstallerRunId -RunId $RunId
    Invoke-WithInstallerLock -InstallRoot $InstallRoot -Action {
        $target = Get-SafeInstallerPath -Path $InstallRoot
        $parent = Split-Path -Path $target -Parent
        Assert-NoReparsePath -Path $parent
        Recover-HerdrOpsTransitionState -InstallRoot $target -Operation Uninstall

        $oldMoved = $false
        $committed = $false
        $preserveTransient = $false
        $primaryException = $null
        $cleanupContexts = @()
        $postCommitWarning = $null
        $backup = Join-Path $parent "HerdrOps.backup-$normalizedRunId"

        try {
            if (Test-Path -LiteralPath $target) {
                $targetItem = Get-Item -LiteralPath $target -Force -ErrorAction Stop
                if (-not $targetItem.PSIsContainer) {
                    throw "Installer target is not a directory: $target"
                }
                Assert-NoReparseDescendants -Path $target
                if (Test-Path -LiteralPath $backup) {
                    Remove-DirectoryTreeSafe -Path $backup -Context 'Pre-existing backup cleanup'
                }
                Assert-NoReparsePath -Path $parent
                [IO.Directory]::Move($target, $backup)
                $oldMoved = $true
                if (Test-Path -LiteralPath $target) {
                    throw 'Uninstall target remained after the atomic directory move.'
                }
                $committed = $true

                try {
                    Remove-DirectoryTreeSafe -Path $backup -Context 'Backup retirement'
                    $backup = $null
                } catch {
                    $preserveTransient = $true
                    $postCommitWarning = "Uninstalled successfully but backup retirement failed: $($_.Exception.Message)"
                }
            }

            if ($RemoveUserData -and -not [string]::IsNullOrWhiteSpace($UserDataRoot)) {
                $fullUserDataRoot = Get-SafeInstallerPath -Path $UserDataRoot
                if (Test-Path -LiteralPath $fullUserDataRoot) {
                    Remove-DirectoryTreeSafe -Path $fullUserDataRoot -Context 'User data removal'
                }
            }
        } catch {
            $primaryException = $_.Exception
            if (-not $committed) {
                try {
                    if ($oldMoved -and (Test-Path -LiteralPath $backup)) {
                        if (Test-Path -LiteralPath $target) {
                            throw 'Uninstall rollback refused to remove an unexpected target directory.'
                        }
                        [IO.Directory]::Move($backup, $target)
                        $backup = $null
                    } elseif (Test-Path -LiteralPath $backup) {
                        Remove-DirectoryTreeSafe -Path $backup -Context 'Backup rollback cleanup'
                        $backup = $null
                    }
                } catch {
                    $preserveTransient = $true
                    $cleanupContexts += "Rollback also failed: $($_.Exception.Message)"
                }
            } else {
                $preserveTransient = $true
            }
        }

        if (-not $preserveTransient -and $null -ne $backup -and (Test-Path -LiteralPath $backup)) {
            try {
                Remove-DirectoryTreeSafe -Path $backup -Context 'Final backup cleanup'
                $backup = $null
            } catch {
                $cleanupContexts += "Cleanup also failed: $($_.Exception.Message)"
            }
        }

        if ($null -ne $postCommitWarning) {
            Write-Warning $postCommitWarning
        }
        if ($null -ne $primaryException) {
            if ($cleanupContexts.Count -gt 0) {
                throw (New-InstallerAggregateException -PrimaryException $primaryException -AdditionalContexts $cleanupContexts)
            }
            throw $primaryException
        }
        if ($cleanupContexts.Count -gt 0) {
            throw (New-Object System.Exception -ArgumentList @($cleanupContexts -join ' '))
        }
    } | Out-Null
}
