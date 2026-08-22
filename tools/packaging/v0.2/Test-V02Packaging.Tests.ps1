#requires -Version 5.1

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'V02Packaging.Common.ps1')

$script:Passed = 0
$script:Failed = 0

function Invoke-Case {
    param([string]$Name, [scriptblock]$Action)
    try {
        & $Action
        $script:Passed++
        Write-Host "PASS: $Name"
    } catch {
        $script:Failed++
        Write-Host "FAIL: $Name -- $($_.Exception.Message)"
    }
}

function Assert-Throws {
    param([scriptblock]$Action, [string]$Pattern = '')
    $threw = $false
    try {
        & $Action
    } catch {
        $threw = $true
        if ($Pattern -and $_.Exception.Message -notmatch $Pattern) {
            throw "Expected pattern '$Pattern', got: $($_.Exception.Message)"
        }
    }
    if (-not $threw) {
        throw 'Expected a fail-closed rejection, but operation succeeded.'
    }
}

function Clone-Object {
    param($Value)
    return (ConvertFrom-V02StrictJsonText -Json ($Value | ConvertTo-Json -Depth 30 -Compress) -Description 'test clone')
}

function Put-Bytes {
    param([string]$Path, [byte[]]$Bytes)
    $parent = Split-Path -Path $Path -Parent
    if (-not (Test-Path -LiteralPath $parent -PathType Container)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }
    [IO.File]::WriteAllBytes($Path, $Bytes)
}

function Write-TestZip {
    param([string]$Path, [object[]]$Entries)
    if (Test-Path -LiteralPath $Path) {
        Remove-Item -LiteralPath $Path -Force
    }
    Add-Type -AssemblyName System.IO.Compression
    $stream = [IO.File]::Open($Path, [IO.FileMode]::CreateNew, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
    try {
        $zip = New-Object IO.Compression.ZipArchive($stream, [IO.Compression.ZipArchiveMode]::Create, $true)
        try {
            foreach ($item in $Entries) {
                $entry = $zip.CreateEntry([string]$item.Name)
                $target = $entry.Open()
                try {
                    $bytes = [byte[]]$item.Bytes
                    $target.Write($bytes, 0, $bytes.Length)
                } finally {
                    $target.Dispose()
                }
            }
        } finally {
            $zip.Dispose()
        }
    } finally {
        $stream.Dispose()
    }
}

$worktree = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..\..'))
$testRoot = New-PackagingTempDirectory -Prefix 'HerdrOps-V02PkgTest-'

$repo = Join-Path $testRoot 'source'
$packageSource = Join-Path $testRoot 'package-source'
$archivePath = Join-Path $testRoot 'HerdrOps-0.2.0-win-x64.zip'
$receiptPath = Join-Path $testRoot 'identity.json'
$installRoot = Join-Path $testRoot 'localappdata-programs-herdrops'
$userDataRoot = Join-Path $testRoot 'localappdata-herdrops'
$junctionDir = Join-Path $testRoot 'junction-dir'

# Setup clean fixture repo
New-Item -ItemType Directory (Join-Path $repo 'Plan\reference-hosts') -Force | Out-Null
New-Item -ItemType Directory (Join-Path $repo 'tools\lib') -Force | Out-Null
New-Item -ItemType Directory (Join-Path $repo 'tools\packaging\v0.2') -Force | Out-Null
New-Item -ItemType Directory (Join-Path $repo 'src\HerdrOps.App') -Force | Out-Null
New-Item -ItemType Directory (Join-Path $repo 'src\HerdrOps.Contracts') -Force | Out-Null
New-Item -ItemType Directory (Join-Path $repo 'src\HerdrOps.Domain') -Force | Out-Null

Copy-Item (Join-Path $worktree 'Plan\reference-hosts\v0.2.json') (Join-Path $repo 'Plan\reference-hosts\v0.2.json')
Copy-Item (Join-Path $worktree 'Plan\reference-hosts\reference-host-profile.schema.json') (Join-Path $repo 'Plan\reference-hosts\reference-host-profile.schema.json')
Copy-Item (Join-Path $worktree 'tools\lib\V02ReferenceHostProfile.ps1') (Join-Path $repo 'tools\lib\V02ReferenceHostProfile.ps1')
Copy-Item (Join-Path $PSScriptRoot 'package-identity-profile.json') (Join-Path $repo 'tools\packaging\v0.2\package-identity-profile.json')
Copy-Item (Join-Path $PSScriptRoot 'package-identity-receipt.schema.json') (Join-Path $repo 'tools\packaging\v0.2\package-identity-receipt.schema.json')

Put-Bytes (Join-Path $repo 'src\HerdrOps.App\packages.lock.json') ([byte[]](1, 2, 3, 4))
Put-Bytes (Join-Path $repo 'src\HerdrOps.Contracts\packages.lock.json') ([byte[]](5, 6, 7, 8))
Put-Bytes (Join-Path $repo 'src\HerdrOps.Domain\packages.lock.json') ([byte[]](9, 10, 11, 12))

& git -C $repo init --quiet
& git -C $repo -c user.name=HerdrOps-Test -c user.email=test@example.invalid add --all
& git -C $repo -c user.name=HerdrOps-Test -c user.email=test@example.invalid commit --quiet -m 'fixture'
if ($LASTEXITCODE -ne 0) { throw 'Git fixture commit failed.' }
$global:LASTEXITCODE = 0

$profilePath = Join-Path $repo 'tools\packaging\v0.2\package-identity-profile.json'
$profile = Read-V02PackageIdentityProfile $profilePath

# Build valid package payload
New-Item -ItemType Directory $packageSource -Force | Out-Null
$appExe = Join-Path $packageSource 'HerdrOps.App.exe'
$coreExe = Join-Path $packageSource 'HerdrOps.Core.exe'
$appDll = Join-Path $packageSource 'HerdrOps.App.dll'
$coreDll = Join-Path $packageSource 'HerdrOps.Core.dll'
$runtimeConfig = Join-Path $packageSource 'HerdrOps.App.runtimeconfig.json'

Put-Bytes $appExe ([byte[]](100, 101, 102, 103, 104, 105))
Put-Bytes $coreExe ([byte[]](200, 201, 202, 203, 204))
Put-Bytes $appDll ([byte[]](110, 111, 112))
Put-Bytes $coreDll ([byte[]](210, 211, 212))
Put-Bytes $runtimeConfig ([byte[]](123, 125))

$manifest = New-V02PackageManifestObject -Profile $profile -RepositoryRoot $repo -PackageRoot $packageSource
$manifestPath = Join-Path $packageSource 'package-manifest.json'
Write-V02CanonicalJsonFile -Value $manifest -Path $manifestPath -RepositoryRoot $repo

$null = New-DeterministicPackageArchive -PackageRoot $packageSource -ArchivePath $archivePath
$receiptObj = Build-V02PackageIdentityReceiptObject `
    -Profile $profile `
    -RepositoryRoot $repo `
    -ProfilePath $profilePath `
    -ArchivePath $archivePath `
    -PackageRoot $packageSource

Write-V02CanonicalJsonFile -Value $receiptObj -Path $receiptPath -RepositoryRoot $repo
$receiptParsed = Read-V02CanonicalIdentityReceipt -Path $receiptPath -RepositoryRoot $repo

$appOriginal = [IO.File]::ReadAllBytes($appExe)
$coreOriginal = [IO.File]::ReadAllBytes($coreExe)
$manifestOriginal = [IO.File]::ReadAllBytes($manifestPath)
$archiveOriginal = [IO.File]::ReadAllBytes($archivePath)
$receiptOriginal = [IO.File]::ReadAllBytes($receiptPath)

try {
    # 1. Schema & receipt parity
    Invoke-Case 'package identity receipt valid against schema' {
        $hash = Assert-V02ReceiptSchema -Identity $receiptParsed.Identity -CanonicalJson $receiptParsed.CanonicalJson -RepositoryRoot $repo
        if ($hash -cne '8C7EF64ED06C94C6589D73C0AB47EB60B7EEF7BFE337F126D8D9D3F0CC0F4C4B') {
            throw "Schema hash drifted: $hash"
        }
    }

    # 2. Installer: Clean per-user install (unsigned local SHA policy)
    Invoke-Case 'clean per-user install succeeds with unsigned SHA policy' {
        $mockRegistry = @{}
        $result = & (Join-Path $PSScriptRoot 'Install-HerdrOpsV02Package.ps1') `
            -IdentityReceiptPath $receiptPath `
            -ArchivePath $archivePath `
            -InstallRoot $installRoot `
            -UserDataRoot $userDataRoot `
            -RepositoryRoot $repo `
            -ProfilePath $profilePath `
            -MockRegistryHive $mockRegistry `
            -AllowElevatedForTesting

        if ($result.Status -ne 'Installed' -or $result.PackageVersion -ne '0.2.0') {
            throw "Unexpected install result: $($result | ConvertTo-Json)"
        }
        if (-not (Test-Path -LiteralPath (Join-Path $installRoot 'HerdrOps.App.exe') -PathType Leaf)) {
            throw 'Installed App.exe missing.'
        }
        if (-not (Test-Path -LiteralPath (Join-Path $installRoot 'HerdrOps.Core.exe') -PathType Leaf)) {
            throw 'Installed Core.exe missing.'
        }
        if (-not (Test-Path -LiteralPath (Join-Path $installRoot 'identity.json') -PathType Leaf)) {
            throw 'Installed identity.json missing.'
        }
        if (-not (Test-Path -LiteralPath (Join-Path $installRoot 'install-state.json') -PathType Leaf)) {
            throw 'Installed install-state.json missing.'
        }
        if ($mockRegistry.Count -ne 0) {
            throw 'Default install must NOT register startup.'
        }
    }

    # 3. Installer: Startup opt-in policy
    Invoke-Case 'installer startup opt-in registers per-user startup' {
        $mockRegistry = @{}
        $result = & (Join-Path $PSScriptRoot 'Install-HerdrOpsV02Package.ps1') `
            -IdentityReceiptPath $receiptPath `
            -ArchivePath $archivePath `
            -InstallRoot $installRoot `
            -UserDataRoot $userDataRoot `
            -RepositoryRoot $repo `
            -ProfilePath $profilePath `
            -RegisterStartup `
            -MockRegistryHive $mockRegistry `
            -AllowElevatedForTesting

        if (-not $result.StartupRegistered) {
            throw 'StartupRegistered should be true.'
        }
        if (-not $mockRegistry.ContainsKey('HerdrOps')) {
            throw 'Mock registry missing HerdrOps startup entry.'
        }
        $expectedExe = '"' + (Join-Path $installRoot 'HerdrOps.App.exe') + '"'
        if ($mockRegistry['HerdrOps'] -ne $expectedExe) {
            throw "Expected startup command $expectedExe, got $($mockRegistry['HerdrOps'])"
        }
    }

    # 4. In-place upgrade simulation
    Invoke-Case 'in-place upgrade over existing installation succeeds' {
        $mockRegistry = @{ 'HerdrOps' = 'old' }
        $result = & (Join-Path $PSScriptRoot 'Install-HerdrOpsV02Package.ps1') `
            -IdentityReceiptPath $receiptPath `
            -PackageRoot $packageSource `
            -InstallRoot $installRoot `
            -UserDataRoot $userDataRoot `
            -RepositoryRoot $repo `
            -ProfilePath $profilePath `
            -RegisterStartup `
            -MockRegistryHive $mockRegistry `
            -AllowElevatedForTesting

        if ($result.Status -ne 'Installed') {
            throw "Upgrade failed: $($result.Status)"
        }
    }

    # 5. Tamper detection: Modified payload byte fails closed
    Invoke-Case 'tampered App.exe in package payload fails closed' {
        Put-Bytes $appExe ([byte[]](9, 9, 9))
        try {
            Assert-Throws {
                & (Join-Path $PSScriptRoot 'Install-HerdrOpsV02Package.ps1') `
                    -IdentityReceiptPath $receiptPath `
                    -PackageRoot $packageSource `
                    -InstallRoot $installRoot `
                    -UserDataRoot $userDataRoot `
                    -RepositoryRoot $repo `
                    -ProfilePath $profilePath `
                    -AllowElevatedForTesting
            } 'tamper|match|inventories are not exact'
        } finally {
            Put-Bytes $appExe $appOriginal
        }
    }

    # 6. Tamper detection: Missing component fails closed
    Invoke-Case 'missing Core.exe in payload fails closed' {
        Remove-Item -LiteralPath $coreExe -Force
        try {
            Assert-Throws {
                & (Join-Path $PSScriptRoot 'Install-HerdrOpsV02Package.ps1') `
                    -IdentityReceiptPath $receiptPath `
                    -PackageRoot $packageSource `
                    -InstallRoot $installRoot `
                    -UserDataRoot $userDataRoot `
                    -RepositoryRoot $repo `
                    -ProfilePath $profilePath `
                    -AllowElevatedForTesting
            } 'Manifest/package-root|Payload and manifest|tamper|not found'
        } finally {
            Put-Bytes $coreExe $coreOriginal
        }
    }

    # 7. Tamper detection: Extra unexpected file fails closed
    Invoke-Case 'unexpected extraneous file in payload fails closed' {
        $extraFile = Join-Path $packageSource 'malicious.dll'
        Put-Bytes $extraFile ([byte[]](1, 2, 3))
        try {
            Assert-Throws {
                & (Join-Path $PSScriptRoot 'Install-HerdrOpsV02Package.ps1') `
                    -IdentityReceiptPath $receiptPath `
                    -PackageRoot $packageSource `
                    -InstallRoot $installRoot `
                    -UserDataRoot $userDataRoot `
                    -RepositoryRoot $repo `
                    -ProfilePath $profilePath `
                    -AllowElevatedForTesting
            } 'Manifest/package-root|Payload and manifest|tamper'
        } finally {
            if (Test-Path -LiteralPath $extraFile) {
                Remove-Item -LiteralPath $extraFile -Force
            }
        }
    }

    # 8. Tamper detection: Corrupted archive fails closed
    Invoke-Case 'tampered archive bytes fails closed' {
        Put-Bytes $archivePath ([byte[]](1, 2, 3, 4, 5))
        try {
            Assert-Throws {
                & (Join-Path $PSScriptRoot 'Install-HerdrOpsV02Package.ps1') `
                    -IdentityReceiptPath $receiptPath `
                    -ArchivePath $archivePath `
                    -InstallRoot $installRoot `
                    -UserDataRoot $userDataRoot `
                    -RepositoryRoot $repo `
                    -ProfilePath $profilePath `
                    -AllowElevatedForTesting
            } 'archive SHA-256|tamper|Central Directory|corrupt'
        } finally {
            Put-Bytes $archivePath $archiveOriginal
        }
    }

    # 9. Reparse point fences: Reparse InstallRoot rejected
    Invoke-Case 'reparse junction InstallRoot fails closed' {
        $reparseTarget = Join-Path $testRoot 'reparse-install-target'
        New-Item -ItemType Directory -Path $reparseTarget -Force | Out-Null
        New-Item -ItemType Junction -Path $junctionDir -Target $reparseTarget | Out-Null
        try {
            Assert-Throws {
                & (Join-Path $PSScriptRoot 'Install-HerdrOpsV02Package.ps1') `
                    -IdentityReceiptPath $receiptPath `
                    -ArchivePath $archivePath `
                    -InstallRoot $junctionDir `
                    -UserDataRoot $userDataRoot `
                    -RepositoryRoot $repo `
                    -ProfilePath $profilePath `
                    -AllowElevatedForTesting
            } 'reparse'
        } finally {
            if (Test-Path -LiteralPath $junctionDir) {
                [IO.Directory]::Delete($junctionDir, $false)
            }
            if (Test-Path -LiteralPath $reparseTarget) {
                Remove-Item -LiteralPath $reparseTarget -Recurse -Force
            }
        }
    }

    # 10. Path overlap protection: InstallRoot inside UserDataRoot rejected
    Invoke-Case 'overlapping InstallRoot and UserDataRoot fails closed' {
        $overlapInstall = Join-Path $userDataRoot 'Programs\HerdrOps'
        Assert-Throws {
            & (Join-Path $PSScriptRoot 'Install-HerdrOpsV02Package.ps1') `
                -IdentityReceiptPath $receiptPath `
                -ArchivePath $archivePath `
                -InstallRoot $overlapInstall `
                -UserDataRoot $userDataRoot `
                -RepositoryRoot $repo `
                -ProfilePath $profilePath `
                -AllowElevatedForTesting
        } 'overlap|nested'
    }

    Invoke-Case 'protected system-directory descendants fail closed' {
        $protectedChild = Join-Path $env:ProgramFiles 'HerdrOps-Hostile-Test'
        Assert-Throws { Assert-V02NotSystemDirectory -Path $protectedChild } 'protected system directory tree'
    }

    Invoke-Case 'package source with reparse descendant fails closed and preserves target' {
        $target = Join-Path $testRoot 'descendant-target'; New-Item -ItemType Directory $target -Force | Out-Null
        $targetFile = Join-Path $target 'sentinel.keep'; Put-Bytes $targetFile ([byte[]](31,32,33))
        $childJunction = Join-Path $packageSource 'hostile-link'; New-Item -ItemType Junction -Path $childJunction -Target $target | Out-Null
        try {
            Assert-Throws { & (Join-Path $PSScriptRoot 'Install-HerdrOpsV02Package.ps1') -IdentityReceiptPath $receiptPath -PackageRoot $packageSource -InstallRoot $installRoot -UserDataRoot $userDataRoot -RepositoryRoot $repo -ProfilePath $profilePath -AllowElevatedForTesting } 'reparse'
            if (-not (Test-Path -LiteralPath $targetFile)) { throw 'Reparse target sentinel was removed.' }
        } finally {
            if (Test-Path -LiteralPath $childJunction) { [IO.Directory]::Delete($childJunction,$false) }
            if (Test-Path -LiteralPath $target) { Remove-Item -LiteralPath $target -Recurse -Force }
        }
    }

    # 11. Uninstaller: User data retention guarantee
    Invoke-Case 'uninstall removes install root and strictly retains %LOCALAPPDATA%\HerdrOps user data' {
        # Setup simulated user data
        New-Item -ItemType Directory -Path $userDataRoot -Force | Out-Null
        $dbFile = Join-Path $userDataRoot 'herdrops.db'
        $settingsFile = Join-Path $userDataRoot 'settings.json'
        $evidenceFile = Join-Path $userDataRoot 'evidence.log'

        Put-Bytes $dbFile ([byte[]](1, 1, 2, 3, 5, 8, 13))
        Put-Bytes $settingsFile ([byte[]](100, 102, 104))
        Put-Bytes $evidenceFile ([byte[]](200, 201, 202, 203))

        $dbHash = (Get-FileHash -LiteralPath $dbFile -Algorithm SHA256).Hash
        $settingsHash = (Get-FileHash -LiteralPath $settingsFile -Algorithm SHA256).Hash
        $evidenceHash = (Get-FileHash -LiteralPath $evidenceFile -Algorithm SHA256).Hash

        $mockRegistry = @{ 'HerdrOps' = '"' + (Join-Path $installRoot 'HerdrOps.App.exe') + '"' }

        $uninstallResult = & (Join-Path $PSScriptRoot 'Uninstall-HerdrOpsV02Package.ps1') `
            -InstallRoot $installRoot `
            -UserDataRoot $userDataRoot `
            -RepositoryRoot $repo `
            -ProfilePath $profilePath `
            -MockRegistryHive $mockRegistry `
            -AllowElevatedForTesting

        if ($uninstallResult.Status -ne 'Uninstalled') {
            throw "Unexpected uninstall status: $($uninstallResult.Status)"
        }
        if (-not $uninstallResult.UserDataRetained) {
            throw 'UserDataRetained should be true.'
        }
        if (Test-Path -LiteralPath $installRoot) {
            throw "Install root was not deleted: $installRoot"
        }
        if ($mockRegistry.ContainsKey('HerdrOps')) {
            throw 'Startup registration was not cleaned by uninstaller.'
        }

        # Verify user data is 100% intact
        if (-not (Test-Path -LiteralPath $dbFile -PathType Leaf) -or
            -not (Test-Path -LiteralPath $settingsFile -PathType Leaf) -or
            -not (Test-Path -LiteralPath $evidenceFile -PathType Leaf)) {
            throw 'User data files were deleted during uninstall!'
        }

        if ((Get-FileHash -LiteralPath $dbFile -Algorithm SHA256).Hash -ne $dbHash -or
            (Get-FileHash -LiteralPath $settingsFile -Algorithm SHA256).Hash -ne $settingsHash -or
            (Get-FileHash -LiteralPath $evidenceFile -Algorithm SHA256).Hash -ne $evidenceHash) {
            throw 'User data file contents were altered during uninstall!'
        }
    }

    # 12. Uninstaller on non-installed folder fails closed
    Invoke-Case 'uninstaller rejects non-HerdrOps arbitrary folder' {
        $arbitraryDir = Join-Path $testRoot 'arbitrary-folder'
        New-Item -ItemType Directory -Path $arbitraryDir -Force | Out-Null
        Put-Bytes (Join-Path $arbitraryDir 'somefile.txt') ([byte[]](1, 2, 3))
        try {
            Assert-Throws {
                & (Join-Path $PSScriptRoot 'Uninstall-HerdrOpsV02Package.ps1') `
                    -InstallRoot $arbitraryDir `
                    -UserDataRoot $userDataRoot `
                    -RepositoryRoot $repo `
                    -ProfilePath $profilePath `
                    -AllowElevatedForTesting
            } 'identity-bound|missing'
        } finally {
            if (Test-Path -LiteralPath $arbitraryDir) {
                Remove-Item -LiteralPath $arbitraryDir -Recurse -Force
            }
        }
    }

    # 13. Publish wrapper: Pinning to v0.2.0
    Invoke-Case 'publish wrapper rejects non-0.2.0 package version' {
        Assert-Throws {
            & (Join-Path $PSScriptRoot 'Publish-HerdrOpsV02Package.ps1') `
                -OutputRoot (Join-Path $testRoot 'out-v07') `
                -PackageVersion '0.7.0' `
                -RepositoryRoot $repo `
                -ProfilePath $profilePath
        } 'pinned to version 0.2.0'
    }

    # 14. Publish wrapper: Injected failure rollback
    Invoke-Case 'publish wrapper cleans staging on injected failure' {
        $failedOut = Join-Path $testRoot 'failed-out'
        Assert-Throws {
            & (Join-Path $PSScriptRoot 'Publish-HerdrOpsV02Package.ps1') `
                -OutputRoot $failedOut `
                -PackageVersion '0.2.0' `
                -RepositoryRoot $repo `
                -ProfilePath $profilePath `
                -TestInjectPrimaryFailure
        } 'Injected packaging primary operation failure'

        if (Test-Path -LiteralPath $failedOut) {
            throw 'Failed publish output should not exist.'
        }
    }

    # 15. Installer atomic rollback on injected replace failure
    Invoke-Case 'installer rolls back existing installation on replace failure' {
        # First do a good install
        $null = & (Join-Path $PSScriptRoot 'Install-HerdrOpsV02Package.ps1') `
            -IdentityReceiptPath $receiptPath `
            -ArchivePath $archivePath `
            -InstallRoot $installRoot `
            -UserDataRoot $userDataRoot `
            -RepositoryRoot $repo `
            -ProfilePath $profilePath `
            -AllowElevatedForTesting

        $markerBefore = [IO.File]::ReadAllText((Join-Path $installRoot 'install-state.json'))

        Assert-Throws {
            & (Join-Path $PSScriptRoot 'Install-HerdrOpsV02Package.ps1') `
                -IdentityReceiptPath $receiptPath `
                -ArchivePath $archivePath `
                -InstallRoot $installRoot `
                -UserDataRoot $userDataRoot `
                -RepositoryRoot $repo `
                -ProfilePath $profilePath `
                -TestFaultInjectionStage 'AfterReplace' `
                -AllowElevatedForTesting
        } 'Injected install failure after directory replace'

        if (-not (Test-Path -LiteralPath (Join-Path $installRoot 'install-state.json') -PathType Leaf)) {
            throw 'Rollback failed to restore original install state file.'
        }
        $markerAfter = [IO.File]::ReadAllText((Join-Path $installRoot 'install-state.json'))
        if ($markerBefore -ne $markerAfter) {
            throw 'Original installation was not restored on rollback.'
        }
    }

    Invoke-Case 'all five production lock files bind win-x64' {
        foreach ($relative in @('src\HerdrOps.App\packages.lock.json','src\HerdrOps.Core\packages.lock.json','src\HerdrOps.Infrastructure\packages.lock.json','src\HerdrOps.Contracts\packages.lock.json','src\HerdrOps.Domain\packages.lock.json')) {
            $lock = Get-Content -LiteralPath (Join-Path $worktree $relative) -Raw | ConvertFrom-Json
            if (@($lock.dependencies.PSObject.Properties.Name | Where-Object { $_ -cmatch '/win-x64$' }).Count -ne 1) {
                throw "Lock file lacks exact win-x64 target: $relative"
            }
        }
    }

    Invoke-Case 'existing arbitrary nonempty install root is never clobbered' {
        $arbitrary = Join-Path $testRoot 'arbitrary-existing-install'
        New-Item -ItemType Directory $arbitrary -Force | Out-Null
        $sentinel = Join-Path $arbitrary 'do-not-delete.txt'; Put-Bytes $sentinel ([byte[]](71,72,73))
        Assert-Throws {
            & (Join-Path $PSScriptRoot 'Install-HerdrOpsV02Package.ps1') -IdentityReceiptPath $receiptPath -ArchivePath $archivePath -InstallRoot $arbitrary -UserDataRoot $userDataRoot -RepositoryRoot $repo -ProfilePath $profilePath -AllowElevatedForTesting
        } 'identity-bound|missing'
        if (-not (Test-Path -LiteralPath $sentinel -PathType Leaf) -or (Get-FileHash $sentinel -Algorithm SHA256).Hash -cne (Get-Sha256ForBytes ([byte[]](71,72,73)))) { throw 'Arbitrary install sentinel was changed.' }
    }

    Invoke-Case 'held package snapshot is immune to post-snapshot source mutation' {
        try {
            $result = & (Join-Path $PSScriptRoot 'Install-HerdrOpsV02Package.ps1') -IdentityReceiptPath $receiptPath -PackageRoot $packageSource -InstallRoot $installRoot -UserDataRoot $userDataRoot -RepositoryRoot $repo -ProfilePath $profilePath -TestFaultInjectionStage AfterSourceSnapshot -TestMutationPath $appExe -AllowElevatedForTesting
            if ($result.Status -cne 'Installed') { throw 'Held-snapshot install did not complete.' }
        } finally { Put-Bytes $appExe $appOriginal }
    }

    Invoke-Case 'staging mutation fails closed and restores exact prior install' {
        $before = (Get-FileHash -LiteralPath (Join-Path $installRoot 'install-state.json') -Algorithm SHA256).Hash
        Assert-Throws {
            & (Join-Path $PSScriptRoot 'Install-HerdrOpsV02Package.ps1') -IdentityReceiptPath $receiptPath -ArchivePath $archivePath -InstallRoot $installRoot -UserDataRoot $userDataRoot -RepositoryRoot $repo -ProfilePath $profilePath -TestFaultInjectionStage StageMutation -AllowElevatedForTesting
        } 'Manifest/package-root|receipt|inventory'
        $after = (Get-FileHash -LiteralPath (Join-Path $installRoot 'install-state.json') -Algorithm SHA256).Hash
        if ($before -cne $after) { throw 'Existing installation changed after staged mutation rejection.' }
    }

    Invoke-Case 'startup mutation rolls back with directory transaction' {
        $registry = @{HerdrOps='old-startup-command'}
        $before = (Get-FileHash -LiteralPath (Join-Path $installRoot 'install-state.json') -Algorithm SHA256).Hash
        Assert-Throws {
            & (Join-Path $PSScriptRoot 'Install-HerdrOpsV02Package.ps1') -IdentityReceiptPath $receiptPath -ArchivePath $archivePath -InstallRoot $installRoot -UserDataRoot $userDataRoot -RepositoryRoot $repo -ProfilePath $profilePath -RegisterStartup -MockRegistryHive $registry -TestFaultInjectionStage AfterStartup -AllowElevatedForTesting
        } 'after startup mutation'
        if ($registry.HerdrOps -cne 'old-startup-command' -or (Get-FileHash -LiteralPath (Join-Path $installRoot 'install-state.json') -Algorithm SHA256).Hash -cne $before) { throw 'Startup or install directory rollback was incomplete.' }
    }

    Invoke-Case 'uninstaller rejects partial lookalike installation and preserves sentinel' {
        $lookalike = Join-Path $testRoot 'lookalike'; New-Item -ItemType Directory $lookalike -Force | Out-Null
        foreach ($name in @('HerdrOps.App.exe','package-manifest.json','identity.json','install-state.json','sentinel.keep')) { Put-Bytes (Join-Path $lookalike $name) ([byte[]](1,2,3)) }
        Assert-Throws { & (Join-Path $PSScriptRoot 'Uninstall-HerdrOpsV02Package.ps1') -InstallRoot $lookalike -UserDataRoot $userDataRoot -RepositoryRoot $repo -ProfilePath $profilePath -AllowElevatedForTesting } 'JSON|identity|receipt|UTF-8'
        if (-not (Test-Path -LiteralPath (Join-Path $lookalike 'sentinel.keep'))) { throw 'Lookalike sentinel was removed.' }
    }

    Invoke-Case 'publisher rejects nonempty output and preserves sentinel' {
        $nonempty = Join-Path $testRoot 'nonempty-output'; New-Item -ItemType Directory $nonempty -Force | Out-Null
        $sentinel = Join-Path $nonempty 'sentinel.keep'; Put-Bytes $sentinel ([byte[]](4,5,6))
        Assert-Throws { & (Join-Path $PSScriptRoot 'Publish-HerdrOpsV02Package.ps1') -OutputRoot $nonempty -RepositoryRoot $repo -ProfilePath $profilePath -TestInjectPrimaryFailure } 'missing or empty|overwrite'
        if (-not (Test-Path -LiteralPath $sentinel)) { throw 'Nonempty output sentinel was removed.' }
    }

    Invoke-Case 'uninstall after-move fault restores install and startup' {
        $registry = @{HerdrOps='bound-startup'}
        Assert-Throws { & (Join-Path $PSScriptRoot 'Uninstall-HerdrOpsV02Package.ps1') -InstallRoot $installRoot -UserDataRoot $userDataRoot -RepositoryRoot $repo -ProfilePath $profilePath -MockRegistryHive $registry -TestFaultInjectionStage AfterUninstallMove -AllowElevatedForTesting } 'after directory move'
        if (-not (Test-Path -LiteralPath (Join-Path $installRoot 'identity.json')) -or $registry.HerdrOps -cne 'bound-startup') { throw 'Uninstall transaction rollback was incomplete.' }
    }
} finally {
    if (Test-Path -LiteralPath $testRoot) {
        Remove-PackagingTempDirectory -Path $testRoot
    }
}

Write-Host "RESULT: $script:Passed passed, $script:Failed failed"
if ($script:Failed -gt 0) {
    throw "$script:Failed v0.2 packaging test(s) failed."
}
$global:LASTEXITCODE = 0
