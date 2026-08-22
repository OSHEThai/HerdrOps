#requires -Version 5.1

Set-StrictMode -Version Latest

. (Join-Path $PSScriptRoot 'V02PackageIdentity.Common.ps1')

function Get-V02DefaultInstallRoot {
    return (Join-Path $env:LOCALAPPDATA 'Programs\HerdrOps')
}

function Get-V02DefaultUserDataRoot {
    return (Join-Path $env:LOCALAPPDATA 'HerdrOps')
}

function Test-V02IsElevated {
    try {
        $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
        $principal = New-Object Security.Principal.WindowsPrincipal($identity)
        return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    } catch {
        return $false
    }
}

function Assert-V02NonElevated {
    param([switch]$AllowElevatedForTesting)

    if ($AllowElevatedForTesting) {
        return
    }

    if (Test-V02IsElevated) {
        throw 'HerdrOps per-user installation must run non-elevated without Administrator rights.'
    }
}

function Assert-V02NotSystemDirectory {
    param([Parameter(Mandatory = $true)][string]$Path)

    $normalized = [IO.Path]::GetFullPath($Path).TrimEnd('\', '/')
    $prohibited = @(
        $env:SystemDrive,
        [IO.Path]::GetPathRoot($normalized),
        $env:windir,
        $env:SystemRoot,
        $env:ProgramFiles,
        ${env:ProgramFiles(x86)},
        $env:ProgramData,
        $env:USERPROFILE,
        $env:APPDATA,
        $env:LOCALAPPDATA
    ) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | ForEach-Object { [IO.Path]::GetFullPath($_).TrimEnd('\', '/') }

    foreach ($bad in $prohibited) {
        if ([StringComparer]::OrdinalIgnoreCase.Equals($normalized, $bad)) {
            throw "Refusing to operate on broad or protected system/profile root directory: $normalized"
        }
    }

    foreach ($protectedTree in @($env:windir,$env:SystemRoot,$env:ProgramFiles,${env:ProgramFiles(x86)},$env:ProgramData) |
        Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
        ForEach-Object { [IO.Path]::GetFullPath($_).TrimEnd('\','/') } |
        Select-Object -Unique) {
        if ($normalized.StartsWith($protectedTree + '\', [StringComparison]::OrdinalIgnoreCase)) {
            throw "Refusing to operate inside a protected system directory tree: $normalized"
        }
    }
}

function Assert-V02PackagingPathsDoNotOverlap {
    param(
        [Parameter(Mandatory = $true)][array]$Paths
    )

    for ($i = 0; $i -lt $Paths.Count; $i++) {
        $first = $Paths[$i]
        $firstNormalized = [IO.Path]::GetFullPath($first.Path).TrimEnd('\', '/')
        for ($j = $i + 1; $j -lt $Paths.Count; $j++) {
            $second = $Paths[$j]
            $secondNormalized = [IO.Path]::GetFullPath($second.Path).TrimEnd('\', '/')

            if ([StringComparer]::OrdinalIgnoreCase.Equals($firstNormalized, $secondNormalized)) {
                throw "$($first.Name) and $($second.Name) must not be identical: $firstNormalized"
            }

            $firstWithSlash = $firstNormalized + '\'
            $secondWithSlash = $secondNormalized + '\'

            if ($firstNormalized.StartsWith($secondWithSlash, [StringComparison]::OrdinalIgnoreCase)) {
                throw "$($first.Name) ($firstNormalized) must not be nested inside $($second.Name) ($secondNormalized)."
            }
            if ($secondNormalized.StartsWith($firstWithSlash, [StringComparison]::OrdinalIgnoreCase)) {
                throw "$($second.Name) ($secondNormalized) must not be nested inside $($first.Name) ($firstNormalized)."
            }
        }
    }
}

function Assert-V02PathNoReparse {
    param([Parameter(Mandatory = $true)][string]$Path)

    $fullPath = [IO.Path]::GetFullPath($Path)
    Assert-NoReparsePath -Path $fullPath
}

function Assert-V02TreeNoReparse {
    param([Parameter(Mandatory = $true)][string]$Path)

    $fullPath = [IO.Path]::GetFullPath($Path)
    Assert-NoReparsePath -Path $fullPath
    if (Test-Path -LiteralPath $fullPath -PathType Container) {
        Assert-NoReparseDescendants -Path $fullPath
    }
}

function Get-V02StartupRegistryKeyPath {
    return 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
}

function Register-V02UserStartup {
    param(
        [Parameter(Mandatory = $true)][string]$ExecutablePath,
        [string]$ValueName = 'HerdrOps',
        [hashtable]$MockRegistryHive = $null
    )

    $fullExe = [IO.Path]::GetFullPath($ExecutablePath)
    if (-not (Test-Path -LiteralPath $fullExe -PathType Leaf)) {
        throw "Executable was not found for startup registration: $fullExe"
    }
    Assert-V02PathNoReparse -Path $fullExe

    $commandValue = '"' + $fullExe + '"'

    if ($null -ne $MockRegistryHive) {
        $MockRegistryHive[$ValueName] = $commandValue
        return
    }

    $keyPath = Get-V02StartupRegistryKeyPath
    if (-not (Test-Path -LiteralPath $keyPath)) {
        New-Item -Path $keyPath -Force | Out-Null
    }
    Set-ItemProperty -Path $keyPath -Name $ValueName -Value $commandValue -Type String | Out-Null
}

function Unregister-V02UserStartup {
    param(
        [string]$ValueName = 'HerdrOps',
        [hashtable]$MockRegistryHive = $null
    )

    if ($null -ne $MockRegistryHive) {
        if ($MockRegistryHive.ContainsKey($ValueName)) {
            $MockRegistryHive.Remove($ValueName)
        }
        return
    }

    $keyPath = Get-V02StartupRegistryKeyPath
    if (Test-Path -LiteralPath $keyPath) {
        $existing = Get-ItemProperty -Path $keyPath -Name $ValueName -ErrorAction SilentlyContinue
        if ($null -ne $existing -and $null -ne $existing.$ValueName) {
            Remove-ItemProperty -Path $keyPath -Name $ValueName -ErrorAction SilentlyContinue | Out-Null
        }
    }
}

function Test-V02UserStartupRegistered {
    param(
        [string]$ValueName = 'HerdrOps',
        [hashtable]$MockRegistryHive = $null
    )

    if ($null -ne $MockRegistryHive) {
        return ($MockRegistryHive.ContainsKey($ValueName) -and -not [string]::IsNullOrWhiteSpace($MockRegistryHive[$ValueName]))
    }

    $keyPath = Get-V02StartupRegistryKeyPath
    if (Test-Path -LiteralPath $keyPath) {
        $existing = Get-ItemProperty -Path $keyPath -Name $ValueName -ErrorAction SilentlyContinue
        if ($null -ne $existing -and -not [string]::IsNullOrWhiteSpace($existing.$ValueName)) {
            return $true
        }
    }
    return $false
}

function Build-V02PackageIdentityReceiptObject {
    param(
        [Parameter(Mandatory = $true)]$Profile,
        [Parameter(Mandatory = $true)][string]$RepositoryRoot,
        [Parameter(Mandatory = $true)][string]$ProfilePath,
        [Parameter(Mandatory = $true)][string]$ArchivePath,
        [Parameter(Mandatory = $true)][string]$PackageRoot
    )

    $repo = [IO.Path]::GetFullPath($RepositoryRoot)
    $profileFullPath = [IO.Path]::GetFullPath($ProfilePath)
    $archiveFullPath = [IO.Path]::GetFullPath($ArchivePath)
    $packageRootFullPath = [IO.Path]::GetFullPath($PackageRoot)

    $gitId = Get-V02GitIdentity -RepositoryRoot $repo -RequireClean
    $profileId = Get-V02PreparationProfileIdentity -Path $profileFullPath -ExpectedProfile $Profile -RepositoryRoot $repo
    $archiveStable = Get-V02StableFileIdentity -Path $archiveFullPath

    $manifestPath = Join-Path $packageRootFullPath $Profile.packageManifestFileName
    $manifestResult = Read-V02PackageManifest -Path $manifestPath -Profile $Profile -RepositoryRoot $repo
    $manifest = $manifestResult.Manifest
    $manifestStable = $manifestResult.Stable

    $inventory = Get-V02PackageRootInventory -PackageRoot $packageRootFullPath -ExcludeRelativePath @([string]$Profile.packageManifestFileName)
    $appEntry = @($inventory.Entries | Where-Object { $_.Path -ceq [string]$Profile.components.appRelativePath })
    $coreEntry = @($inventory.Entries | Where-Object { $_.Path -ceq [string]$Profile.components.coreRelativePath })

    if ($appEntry.Count -ne 1) {
        throw "Package root is missing component '$($Profile.components.appRelativePath)'."
    }
    if ($coreEntry.Count -ne 1) {
        throw "Package root is missing component '$($Profile.components.coreRelativePath)'."
    }

    return [pscustomobject][ordered]@{
        schemaVersion = 1
        profileId = [string]$Profile.profileId
        issue = 149
        packageVersion = '0.2.0'
        runtimeIdentifier = 'win-x64'
        source = [pscustomobject][ordered]@{
            commitSha = [string]$gitId.CommitSha
            treeSha = [string]$gitId.TreeSha
        }
        profile = [pscustomobject][ordered]@{
            id = [string]$profileId.Id
            relativePath = [string]$profileId.RelativePath
            bytes = [int64]$profileId.Bytes
            fileSha256 = [string]$profileId.FileSha256
            canonicalSha256 = [string]$profileId.CanonicalSha256
        }
        archive = [pscustomobject][ordered]@{
            relativePath = [string]$Profile.archiveFileName
            fileName = [string]$Profile.archiveFileName
            bytes = [int64]$archiveStable.Length
            sha256 = [string]$archiveStable.Sha256
        }
        packageManifest = [pscustomobject][ordered]@{
            fileName = [string]$Profile.packageManifestFileName
            bytes = [int64]$manifestStable.Length
            sha256 = [string]$manifestStable.Sha256
            contentSha256 = [string]$manifest.contentSha256
            fileCount = [int]$manifest.fileCount
            totalBytes = [int64]$manifest.totalBytes
        }
        components = [pscustomobject][ordered]@{
            app = [pscustomobject][ordered]@{
                relativePath = [string]$Profile.components.appRelativePath
                bytes = [int64]$appEntry[0].Length
                sha256 = [string]$appEntry[0].Sha256
            }
            core = [pscustomobject][ordered]@{
                relativePath = [string]$Profile.components.coreRelativePath
                bytes = [int64]$coreEntry[0].Length
                sha256 = [string]$coreEntry[0].Sha256
            }
        }
        referenceHost = [pscustomobject][ordered]@{
            profileId = [string]$Profile.referenceHost.profileId
            profileSha256 = [string]$Profile.referenceHost.profileSha256
        }
        renderer = [pscustomobject][ordered]@{
            policy = [string]$Profile.renderer.policy
            wpfProcessRenderMode = [string]$Profile.renderer.wpfProcessRenderMode
        }
        evidenceBoundary = [pscustomobject][ordered]@{
            evidenceClass = 'PackagedCompatibilityPreparation'
            runtimeUse = 'not-used'
            actualHerdrUsed = $false
            runtimeCredit = 'NOT CLAIMED'
            releaseCredit = 'NOT CLAIMED'
        }
    }
}

function Extract-V02PackageArchive {
    param(
        [Parameter(Mandatory = $true)][string]$ArchivePath,
        [Parameter(Mandatory = $true)][string]$DestinationPath
    )

    $archiveFullPath = [IO.Path]::GetFullPath($ArchivePath)
    $destinationFullPath = [IO.Path]::GetFullPath($DestinationPath)

    if (-not (Test-Path -LiteralPath $archiveFullPath -PathType Leaf)) {
        throw "Package archive was not found: $archiveFullPath"
    }
    Assert-V02PathNoReparse -Path $archiveFullPath

    if (-not (Test-Path -LiteralPath $destinationFullPath -PathType Container)) {
        New-Item -ItemType Directory -Path $destinationFullPath -Force | Out-Null
    }
    Assert-V02TreeNoReparse -Path $destinationFullPath

    Add-Type -AssemblyName System.IO.Compression
    $stream = $null
    $zip = $null
    try {
        $stream = [IO.File]::Open($archiveFullPath, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
        $zip = New-Object IO.Compression.ZipArchive($stream, [IO.Compression.ZipArchiveMode]::Read, $false)
        foreach ($entry in $zip.Entries) {
            $name = [string]$entry.FullName
            if ([string]::IsNullOrWhiteSpace($name) -or $name -match '(^/|\\|(^|/)\.\.(/|$)|/$)') {
                throw "Archive contains an unsafe entry path: $name"
            }
            $targetPath = [IO.Path]::Combine($destinationFullPath, $name.Replace('/', '\'))
            $targetParent = [IO.Path]::GetDirectoryName($targetPath)
            if (-not (Test-Path -LiteralPath $targetParent -PathType Container)) {
                New-Item -ItemType Directory -Path $targetParent -Force | Out-Null
            }
            Assert-V02PathNoReparse -Path $targetParent

            $entryStream = $null
            $outStream = $null
            try {
                $entryStream = $entry.Open()
                $outStream = [IO.File]::Open($targetPath, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
                $entryStream.CopyTo($outStream)
            } finally {
                if ($null -ne $outStream) { $outStream.Dispose() }
                if ($null -ne $entryStream) { $entryStream.Dispose() }
            }
            Assert-V02PathNoReparse -Path $targetPath
        }
    } finally {
        if ($null -ne $zip) { $zip.Dispose() }
        if ($null -ne $stream) { $stream.Dispose() }
    }
}

function Assert-V02UnsignedLocalShaPolicy {
    param(
        [Parameter(Mandatory = $true)][string]$PackageRoot,
        [Parameter(Mandatory = $true)]$Identity,
        [Parameter(Mandatory = $true)]$Profile,
        [Parameter(Mandatory = $true)][string]$RepositoryRoot
    )

    $root = [IO.Path]::GetFullPath($PackageRoot)
    Assert-V02TreeNoReparse -Path $root

    $manifestPath = Join-Path $root $Profile.packageManifestFileName
    if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
        throw "Package manifest was not found in payload: $manifestPath"
    }

    $manifestResult = Read-V02PackageManifest -Path $manifestPath -Profile $Profile -RepositoryRoot $RepositoryRoot
    $manifest = $manifestResult.Manifest
    $manifestStable = $manifestResult.Stable

    if ($manifestStable.Sha256 -cne $Identity.packageManifest.sha256 -or
        $manifestStable.Length -ne [int64]$Identity.packageManifest.bytes -or
        $manifest.contentSha256 -cne $Identity.packageManifest.contentSha256 -or
        [int64]$manifest.fileCount -ne [int64]$Identity.packageManifest.fileCount -or
        [int64]$manifest.totalBytes -ne [int64]$Identity.packageManifest.totalBytes) {
        throw 'Package manifest does not match the package identity receipt (tamper detected).'
    }

    $inventory = Get-V02PackageRootInventory -PackageRoot $root -ExcludeRelativePath @([string]$Profile.packageManifestFileName)
    Assert-V02InventoryEqual -Expected $manifestResult.Entries -Actual $inventory.Entries -Description 'Payload and manifest'

    $appEntry = @($inventory.Entries | Where-Object { $_.Path -ceq [string]$Profile.components.appRelativePath })
    $coreEntry = @($inventory.Entries | Where-Object { $_.Path -ceq [string]$Profile.components.coreRelativePath })

    if ($appEntry.Count -ne 1 -or
        $appEntry[0].Sha256 -cne $Identity.components.app.sha256 -or
        $appEntry[0].Length -ne [int64]$Identity.components.app.bytes) {
        throw 'App executable in payload does not match the package identity receipt (tamper detected).'
    }

    if ($coreEntry.Count -ne 1 -or
        $coreEntry[0].Sha256 -cne $Identity.components.core.sha256 -or
        $coreEntry[0].Length -ne [int64]$Identity.components.core.bytes) {
        throw 'Core executable in payload does not match the package identity receipt (tamper detected).'
    }

    return $inventory
}

function Get-V02DirectoryHashes {
    param(
        [Parameter(Mandatory = $true)][string]$Path
    )

    $fullPath = [IO.Path]::GetFullPath($Path)
    if (-not (Test-Path -LiteralPath $fullPath -PathType Container)) {
        return @{}
    }
    Assert-V02TreeNoReparse -Path $fullPath

    $hashes = @{}
    foreach ($item in @(Get-ChildItem -LiteralPath $fullPath -Recurse -Force -File | Sort-Object FullName)) {
        if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw "Directory contains a reparse point: $($item.FullName)"
        }
        $rel = Get-SafeRelativePath -RootPath $fullPath -Path $item.FullName
        $stable = Get-V02StableFileIdentity -Path $item.FullName
        $hashes[$rel] = $stable.Sha256
    }
    return $hashes
}

function Assert-V02UserDataRetained {
    param(
        [Parameter(Mandatory = $true)][string]$UserDataRoot,
        [Parameter(Mandatory = $true)][hashtable]$ExpectedHashes
    )

    $fullPath = [IO.Path]::GetFullPath($UserDataRoot)
    if ($ExpectedHashes.Count -eq 0) {
        return
    }

    if (-not (Test-Path -LiteralPath $fullPath -PathType Container)) {
        throw "User data root was expected to be retained, but was missing: $fullPath"
    }
    Assert-V02TreeNoReparse -Path $fullPath

    $actualHashes = Get-V02DirectoryHashes -Path $fullPath
    if ($actualHashes.Count -ne $ExpectedHashes.Count) {
        throw "User data file count changed! Expected $($ExpectedHashes.Count), got $($actualHashes.Count)."
    }

    foreach ($key in $ExpectedHashes.Keys) {
        if (-not $actualHashes.ContainsKey($key)) {
            throw "User data file was deleted: $key"
        }
        if ($actualHashes[$key] -cne $ExpectedHashes[$key]) {
            throw "User data file was modified or corrupted: $key (expected $($ExpectedHashes[$key]), got $($actualHashes[$key]))"
        }
    }
}

function Copy-V02StableFile {
    param(
        [Parameter(Mandatory = $true)][string]$Source,
        [Parameter(Mandatory = $true)][string]$Destination
    )

    $sourceIdentity = Get-V02StableFileIdentity -Path $Source -IncludeBytes
    $destinationFullPath = [IO.Path]::GetFullPath($Destination)
    $parent = Split-Path -Path $destinationFullPath -Parent
    if (-not (Test-Path -LiteralPath $parent -PathType Container)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }
    Assert-V02PathNoReparse -Path $parent
    if (Test-Path -LiteralPath $destinationFullPath) {
        throw "Refusing to overwrite stable-copy destination: $destinationFullPath"
    }
    [IO.File]::WriteAllBytes($destinationFullPath, $sourceIdentity.Bytes)
    $destinationIdentity = Get-V02StableFileIdentity -Path $destinationFullPath
    if ($destinationIdentity.Length -ne $sourceIdentity.Length -or
        $destinationIdentity.Sha256 -cne $sourceIdentity.Sha256) {
        throw "Stable copy did not preserve source bytes: $Source"
    }
    return $destinationIdentity
}

function Merge-V02PublishedTrees {
    param(
        [Parameter(Mandatory = $true)][string[]]$SourceRoots,
        [Parameter(Mandatory = $true)][string]$DestinationRoot
    )

    New-Item -ItemType Directory -Path $DestinationRoot -Force | Out-Null
    foreach ($sourceRoot in $SourceRoots) {
        Assert-V02TreeNoReparse -Path $sourceRoot
        foreach ($item in @(Get-ChildItem -LiteralPath $sourceRoot -Recurse -Force -File | Sort-Object FullName)) {
            $relative = Get-SafeRelativePath -RootPath $sourceRoot -Path $item.FullName
            $destination = Join-Path $DestinationRoot $relative
            $parent = Split-Path -Path $destination -Parent
            if (-not (Test-Path -LiteralPath $parent -PathType Container)) {
                New-Item -ItemType Directory -Path $parent -Force | Out-Null
            }
            if (Test-Path -LiteralPath $destination -PathType Leaf) {
                $sourceId = Get-V02StableFileIdentity -Path $item.FullName
                $destinationId = Get-V02StableFileIdentity -Path $destination
                if ($sourceId.Length -ne $destinationId.Length -or $sourceId.Sha256 -cne $destinationId.Sha256) {
                    throw "App/Core publish outputs collide with different bytes at '$relative'."
                }
                continue
            }
            $null = Copy-V02StableFile -Source $item.FullName -Destination $destination
        }
    }
    Assert-V02TreeNoReparse -Path $DestinationRoot
}

function Assert-V02CompleteInstalledBinding {
    param(
        [Parameter(Mandatory = $true)][string]$InstallRoot,
        [Parameter(Mandatory = $true)]$Profile,
        [Parameter(Mandatory = $true)][string]$ProfilePath,
        [Parameter(Mandatory = $true)][string]$RepositoryRoot,
        [Parameter(Mandatory = $true)][string]$WorkRoot
    )

    $root = [IO.Path]::GetFullPath($InstallRoot)
    Assert-V02TreeNoReparse -Path $root
    $receiptPath = Join-Path $root 'identity.json'
    $statePath = Join-Path $root 'install-state.json'
    foreach ($required in @($receiptPath, $statePath, (Join-Path $root $Profile.packageManifestFileName))) {
        if (-not (Test-Path -LiteralPath $required -PathType Leaf)) {
            throw "Existing installation is not completely identity-bound; missing: $required"
        }
    }
    $parsed = Read-V02CanonicalIdentityReceipt -Path $receiptPath -RepositoryRoot $RepositoryRoot
    $stateStable = Get-V02StableFileIdentity -Path $statePath -IncludeBytes
    $stateDoc = ConvertFrom-V02StrictBytes -Bytes $stateStable.Bytes -Description 'v0.2 install state'
    $state = $stateDoc.Value
    foreach ($name in @('productId','packageVersion','runtimeIdentifier','receiptSha256','installRoot','userDataRoot','startupRegistered','autoUpdate')) {
        if (-not ($state.PSObject.Properties.Name -ccontains $name)) { throw "Install state is missing '$name'." }
    }
    if ([string]$state.productId -cne 'HerdrOps' -or [string]$state.packageVersion -cne '0.2.0' -or
        [string]$state.runtimeIdentifier -cne 'win-x64' -or [string]$state.receiptSha256 -cne $parsed.ReceiptSha256 -or
        -not [StringComparer]::OrdinalIgnoreCase.Equals([IO.Path]::GetFullPath([string]$state.installRoot), $root)) {
        throw 'Existing installation state does not exactly bind this HerdrOps install root and receipt.'
    }

    $payload = Join-Path $WorkRoot ('bound-payload-' + [Guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $payload -Force | Out-Null
    foreach ($item in @(Get-ChildItem -LiteralPath $root -Recurse -Force -File | Sort-Object FullName)) {
        $relative = Get-SafeRelativePath -RootPath $root -Path $item.FullName
        if ($relative -ceq 'identity.json' -or $relative -ceq 'install-state.json') { continue }
        $null = Copy-V02StableFile -Source $item.FullName -Destination (Join-Path $payload $relative)
    }
    $archive = Join-Path $WorkRoot ([string]$Profile.archiveFileName)
    if (Test-Path -LiteralPath $archive) { throw "Binding archive destination already exists: $archive" }
    $null = New-DeterministicPackageArchive -PackageRoot $payload -ArchivePath $archive
    return Assert-V02PackageIdentity -Identity $parsed.Identity -Profile $Profile -RepositoryRoot $RepositoryRoot `
        -ArchivePath $archive -PackageRoot $payload -ProfilePath $ProfilePath `
        -ReceiptSha256 $parsed.ReceiptSha256 -CanonicalReceiptJson $parsed.CanonicalJson
}

function Remove-V02TransactionDirectory {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$ExpectedParent
    )
    $target = [IO.Path]::GetFullPath($Path).TrimEnd('\','/')
    $parent = [IO.Path]::GetFullPath($ExpectedParent).TrimEnd('\','/')
    if (-not [StringComparer]::OrdinalIgnoreCase.Equals((Split-Path -Path $target -Parent).TrimEnd('\','/'), $parent)) {
        throw "Transaction directory is outside its exact expected parent: $target"
    }
    if (-not (Test-Path -LiteralPath $target)) { return }
    if (-not (Test-Path -LiteralPath $target -PathType Container)) { throw "Transaction path is not a directory: $target" }
    Assert-V02TreeNoReparse -Path $target
    [IO.Directory]::Delete($target, $true)
}
