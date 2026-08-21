#requires -Version 5.1

Set-StrictMode -Version Latest

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

    Assert-NoReparsePath -Path $destFullPath
    if (-not (Test-Path -LiteralPath $destFullPath)) {
        New-Item -ItemType Directory -Path $destFullPath -Force | Out-Null
    }

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

        # Pre-scan for validation
        foreach ($entry in $archive.Entries) {
            $entryName = [string]$entry.FullName
            if ([string]::IsNullOrWhiteSpace($entryName) -or
                $entryName.Contains('\') -or
                $entryName.StartsWith('/', [StringComparison]::Ordinal) -or
                $entryName.Contains('//') -or
                $entryName -match '(^|/)\.\.?(/|$)' -or
                $entryName -match '[\x00-\x1F<>:"|?*]' -or
                [IO.Path]::IsPathRooted($entryName)) {
                throw "Archive contains an unsafe entry (zip-slip): '$entryName'."
            }

            if ((($entry.ExternalAttributes -shr 16) -band 0xF000) -eq 0xA000 -or ($entry.ExternalAttributes -band 0x400) -eq 0x400) {
                throw "Archive contains unsupported symlink or reparse point: '$entryName'."
            }

            $destinationEntryPath = Get-SafeInstallerPath -Path (Join-Path $destFullPath $entryName.Replace('/', '\'))
            if (-not $destinationEntryPath.StartsWith($destWithSeparator, [StringComparison]::OrdinalIgnoreCase) -and $destinationEntryPath -ne $destFullPath) {
                throw "Archive entry attempts to extract outside destination (zip-slip): '$entryName'."
            }

            $isDir = $entryName.EndsWith('/', [StringComparison]::Ordinal)
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
                if ([string]::IsNullOrWhiteSpace($parent) -or $parent.Equals($current, [StringComparison]::OrdinalIgnoreCase) -or (-not $parent.StartsWith($destWithSeparator, [StringComparison]::OrdinalIgnoreCase) -and $parent -ne $destFullPath)) {
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

        # Actual extraction
        foreach ($entry in $archive.Entries) {
            $entryName = [string]$entry.FullName
            $destinationEntryPath = Get-SafeInstallerPath -Path (Join-Path $destFullPath $entryName.Replace('/', '\'))

            if ($entryName.EndsWith('/', [StringComparison]::Ordinal)) {
                if (-not (Test-Path -LiteralPath $destinationEntryPath)) {
                    New-Item -ItemType Directory -Path $destinationEntryPath -Force | Out-Null
                }
            } else {
                $entryParent = Split-Path -Path $destinationEntryPath -Parent
                if (-not (Test-Path -LiteralPath $entryParent)) {
                    New-Item -ItemType Directory -Path $entryParent -Force | Out-Null
                }
                [IO.Compression.ZipFileExtensions]::ExtractToFile($entry, $destinationEntryPath, $true)
            }
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
    $item = Get-Item -LiteralPath $fullPath -Force
    if (-not $item.PSIsContainer) {
        throw "$Context target must be a directory: $fullPath"
    }
    Remove-Item -LiteralPath $fullPath -Recurse -Force
}

function Invoke-AtomicInstallTransition {
    param(
        [Parameter(Mandatory = $true)][string]$ArchivePath,
        [Parameter(Mandatory = $true)][string]$InstallRoot,
        [Parameter(Mandatory = $true)][string]$RunId
    )

    $target = Get-SafeInstallerPath -Path $InstallRoot
    $parent = Split-Path -Path $target -Parent
    $lockPath = Join-Path $parent "$([IO.Path]::GetFileName($target)).lock"
    $stage = Join-Path $parent "HerdrOps.stage-$RunId"
    $backup = Join-Path $parent "HerdrOps.backup-$RunId"
    
    $oldPresent = Test-Path -LiteralPath $target
    $oldMoved = $false
    $committed = $false
    $preserveTransient = $false
    $lockAcquired = $false

    try {
        if (-not (Test-Path -LiteralPath $parent)) {
            New-Item -ItemType Directory -Path $parent -Force | Out-Null
        }
        Assert-NoReparsePath -Path $parent
        
        $retryCount = 0
        while (-not $lockAcquired -and $retryCount -lt 10) {
            try {
                New-Item -ItemType Directory -Path $lockPath -ErrorAction Stop | Out-Null
                $lockAcquired = $true
            } catch {
                $retryCount++
                Start-Sleep -Seconds 1
            }
        }
        if (-not $lockAcquired) {
            throw "Failed to acquire installer lock for target: $target"
        }

        if (Test-Path -LiteralPath $stage) {
            Remove-DirectoryTreeSafe -Path $stage -Context "Pre-existing stage cleanup"
        }
        New-Item -ItemType Directory -Path $stage -Force | Out-Null
        Assert-NoReparsePath -Path $stage

        Expand-HerdrOpsArchiveSafe -ArchivePath $ArchivePath -DestinationPath $stage

        if ($oldPresent) {
            Assert-NoReparsePath -Path $target
            if (Test-Path -LiteralPath $backup) {
                Remove-DirectoryTreeSafe -Path $backup -Context "Pre-existing backup cleanup"
            }
            Move-Item -LiteralPath $target -Destination $backup
            $oldMoved = $true
        }

        Move-Item -LiteralPath $stage -Destination $target
        $stage = $null
        $committed = $true

        if ($null -ne $backup -and (Test-Path -LiteralPath $backup)) {
            try {
                Remove-DirectoryTreeSafe -Path $backup -Context "Backup retirement"
                $backup = $null
            } catch {
                $preserveTransient = $true
                Write-Warning "Installed successfully but backup retirement failed: $($_.Exception.Message)"
            }
        }
    } catch {
        $primaryException = $_.Exception
        if ($committed) {
            $preserveTransient = $true
            throw $primaryException
        }
        
        try {
            if ($null -ne $stage -and (Test-Path -LiteralPath $stage)) {
                Remove-DirectoryTreeSafe -Path $stage -Context "Stage rollback"
                $stage = $null
            }
            if ($oldMoved -and $null -ne $backup -and (Test-Path -LiteralPath $backup)) {
                if (Test-Path -LiteralPath $target) {
                    Remove-DirectoryTreeSafe -Path $target -Context "Target cleanup before rollback"
                }
                Move-Item -LiteralPath $backup -Destination $target
                $backup = $null
            } elseif ($null -ne $backup -and (Test-Path -LiteralPath $backup)) {
                Remove-DirectoryTreeSafe -Path $backup -Context "Backup rollback cleanup"
                $backup = $null
            }
        } catch {
            $preserveTransient = $true
            throw (New-Object System.Exception -ArgumentList @(
                ("$($primaryException.Message) Rollback also failed: $($_.Exception.Message)"),
                $primaryException))
        }
        throw $primaryException
    } finally {
        if (-not $preserveTransient -and $null -ne $stage -and (Test-Path -LiteralPath $stage)) {
            Remove-DirectoryTreeSafe -Path $stage -Context "Final stage cleanup"
        }
        if (-not $preserveTransient -and $null -ne $backup -and (Test-Path -LiteralPath $backup)) {
            Remove-DirectoryTreeSafe -Path $backup -Context "Final backup cleanup"
        }
        if ($lockAcquired -and (Test-Path -LiteralPath $lockPath)) {
            Remove-DirectoryTreeSafe -Path $lockPath -Context "Lock cleanup"
        }
    }
}

function Invoke-AtomicUninstallTransition {
    param(
        [Parameter(Mandatory = $true)][string]$InstallRoot,
        [Parameter(Mandatory = $true)][string]$RunId
    )

    $target = Get-SafeInstallerPath -Path $InstallRoot
    $parent = Split-Path -Path $target -Parent
    $lockPath = Join-Path $parent "$([IO.Path]::GetFileName($target)).lock"
    $backup = Join-Path $parent "HerdrOps.backup-$RunId"
    
    $oldMoved = $false
    $committed = $false
    $preserveTransient = $false
    $lockAcquired = $false

    if (-not (Test-Path -LiteralPath $target)) {
        return # Already uninstalled
    }

    try {
        $retryCount = 0
        while (-not $lockAcquired -and $retryCount -lt 10) {
            try {
                New-Item -ItemType Directory -Path $lockPath -ErrorAction Stop | Out-Null
                $lockAcquired = $true
            } catch {
                $retryCount++
                Start-Sleep -Seconds 1
            }
        }
        if (-not $lockAcquired) {
            throw "Failed to acquire installer lock for target: $target"
        }

        Assert-NoReparsePath -Path $target
        
        if (Test-Path -LiteralPath $backup) {
            Remove-DirectoryTreeSafe -Path $backup -Context "Pre-existing backup cleanup"
        }
        
        Move-Item -LiteralPath $target -Destination $backup
        $oldMoved = $true
        
        if (Test-Path -LiteralPath $target) {
            throw 'Uninstall target remained after the atomic directory move.'
        }
        
        $committed = $true

        try {
            Remove-DirectoryTreeSafe -Path $backup -Context "Backup retirement"
            $backup = $null
        } catch {
            $preserveTransient = $true
            Write-Warning "Uninstalled successfully but backup retirement failed: $($_.Exception.Message)"
        }
    } catch {
        $primaryException = $_.Exception
        if ($committed) {
            $preserveTransient = $true
            throw $primaryException
        }
        
        try {
            if ($oldMoved -and $null -ne $backup -and (Test-Path -LiteralPath $backup)) {
                if (Test-Path -LiteralPath $target) {
                    throw 'Uninstall rollback target was not empty before backup restore.'
                }
                Move-Item -LiteralPath $backup -Destination $target
                $backup = $null
            } elseif ($null -ne $backup -and (Test-Path -LiteralPath $backup)) {
                Remove-DirectoryTreeSafe -Path $backup -Context "Backup rollback cleanup"
                $backup = $null
            }
        } catch {
            $preserveTransient = $true
            throw (New-Object System.Exception -ArgumentList @(
                ("$($primaryException.Message) Rollback also failed: $($_.Exception.Message)"),
                $primaryException))
        }
        throw $primaryException
    } finally {
        if (-not $preserveTransient -and $null -ne $backup -and (Test-Path -LiteralPath $backup)) {
            Remove-DirectoryTreeSafe -Path $backup -Context "Final backup cleanup"
        }
        if ($lockAcquired -and (Test-Path -LiteralPath $lockPath)) {
            Remove-DirectoryTreeSafe -Path $lockPath -Context "Lock cleanup"
        }
    }
}
