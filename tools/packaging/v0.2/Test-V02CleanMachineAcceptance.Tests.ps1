#requires -Version 5.1

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'V02CleanMachine.Common.ps1')
$scriptPath = Join-Path $PSScriptRoot 'Invoke-V02CleanMachineAcceptance.ps1'

$testRoot = New-PackagingTempDirectory -Prefix 'HerdrOps-V02CleanMachineTests-'
$script:Passed = 0
$script:Failed = 0

function Get-PathSurfaceSnapshot {
    param([Parameter(Mandatory = $true)][string]$Path)
    $full = [IO.Path]::GetFullPath($Path)
    if (-not (Test-Path -LiteralPath $full)) { return "ABSENT|$full" }
    $item = Get-Item -LiteralPath $full -Force
    return "PRESENT|$full|$($item.Attributes)|$($item.LastWriteTimeUtc.Ticks)"
}

function Invoke-Case {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][scriptblock]$Action
    )

    try {
        & $Action
        $script:Passed++
        Write-Host "PASS: $Name"
    } catch {
        $script:Failed++
        Write-Host "FAIL: $Name - $($_.Exception.Message)`n$($_.ScriptStackTrace)"
    }
}

function Assert-Throws {
    param(
        [Parameter(Mandatory = $true)][scriptblock]$Action,
        [Parameter(Mandatory = $true)][string]$ExpectedPattern
    )

    $failed = $false
    $message = ''
    try {
        & $Action
    } catch {
        $failed = $true
        $message = $_.Exception.Message
    }

    if (-not $failed) {
        throw 'Action was expected to throw, but succeeded.'
    }
    if ($message -notmatch $ExpectedPattern) {
        throw "Action threw unexpected error: expected '$ExpectedPattern', observed '$message'."
    }
}

try {
    $realInstallRoot = Get-V02DefaultInstallRoot
    $realUserDataRoot = Get-V02DefaultUserDataRoot
    $realInstallBefore = Get-PathSurfaceSnapshot $realInstallRoot
    $realUserDataBefore = Get-PathSurfaceSnapshot $realUserDataRoot
    $realStartupBefore = Get-V02UserStartupState
    $worktree = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..\..'))
    $repo = Join-Path $testRoot 'repo'

    New-Item -ItemType Directory (Join-Path $repo 'Plan\reference-hosts') -Force | Out-Null
    New-Item -ItemType Directory (Join-Path $repo 'tools\lib') -Force | Out-Null
    New-Item -ItemType Directory (Join-Path $repo 'tools\packaging\v0.2') -Force | Out-Null

    Copy-Item (Join-Path $worktree 'Plan\reference-hosts\v0.2.json') (Join-Path $repo 'Plan\reference-hosts\v0.2.json')
    Copy-Item (Join-Path $worktree 'Plan\reference-hosts\reference-host-profile.schema.json') (Join-Path $repo 'Plan\reference-hosts\reference-host-profile.schema.json')
    Copy-Item (Join-Path $worktree 'tools\lib\V02ReferenceHostProfile.ps1') (Join-Path $repo 'tools\lib\V02ReferenceHostProfile.ps1')
    Copy-Item (Join-Path $PSScriptRoot 'package-identity-profile.json') (Join-Path $repo 'tools\packaging\v0.2\package-identity-profile.json')
    Copy-Item (Join-Path $PSScriptRoot 'package-identity-receipt.schema.json') (Join-Path $repo 'tools\packaging\v0.2\package-identity-receipt.schema.json')
    Copy-Item (Join-Path $PSScriptRoot 'clean-machine-report.schema.json') (Join-Path $repo 'tools\packaging\v0.2\clean-machine-report.schema.json')

    & git -C $repo init --quiet
    & git -C $repo -c user.name=HerdrOps-Test -c user.email=test@example.invalid add --all
    & git -C $repo -c user.name=HerdrOps-Test -c user.email=test@example.invalid commit --quiet -m 'fixture'
    if ($LASTEXITCODE -ne 0) { throw 'Git fixture commit failed.' }
    $global:LASTEXITCODE = 0

    $fixtureCommit = (& git -C $repo rev-parse HEAD).Trim().ToLowerInvariant()
    $fixtureTree = (& git -C $repo rev-parse 'HEAD^{tree}').Trim().ToLowerInvariant()

    $profilePath = Join-Path $repo 'tools\packaging\v0.2\package-identity-profile.json'
    $profile = Read-V02PackageIdentityProfile -Path $profilePath

    # Prepare primary candidate payload
    $fixturePayload = Join-Path $testRoot 'fixture-payload'
    New-Item -ItemType Directory -Path $fixturePayload -Force | Out-Null
    $appExe = Join-Path $fixturePayload 'HerdrOps.App.exe'
    $coreExe = Join-Path $fixturePayload 'HerdrOps.Core.exe'
    $appDll = Join-Path $fixturePayload 'HerdrOps.App.dll'
    $coreDll = Join-Path $fixturePayload 'HerdrOps.Core.dll'
    $runtimeConfig = Join-Path $fixturePayload 'HerdrOps.App.runtimeconfig.json'

    [IO.File]::WriteAllBytes($appExe, [byte[]](10, 20, 30, 40, 50, 60))
    [IO.File]::WriteAllBytes($coreExe, [byte[]](11, 21, 31, 41, 51))
    [IO.File]::WriteAllBytes($appDll, [byte[]](100, 101, 102))
    [IO.File]::WriteAllBytes($coreDll, [byte[]](200, 201, 202))
    [IO.File]::WriteAllBytes($runtimeConfig, [byte[]](123, 125))

    $manifest = New-V02PackageManifestObject -Profile $profile -RepositoryRoot $repo -PackageRoot $fixturePayload
    $manifestPath = Join-Path $fixturePayload 'package-manifest.json'
    Write-V02CanonicalJsonFile -Value $manifest -Path $manifestPath -RepositoryRoot $repo

    $archivePath = Join-Path $testRoot 'HerdrOps-0.2.0-win-x64.zip'
    $null = New-DeterministicPackageArchive -PackageRoot $fixturePayload -ArchivePath $archivePath

    $receiptObj = Build-V02PackageIdentityReceiptObject `
        -Profile $profile `
        -RepositoryRoot $repo `
        -ProfilePath $profilePath `
        -ArchivePath $archivePath `
        -PackageRoot $fixturePayload

    $receiptPath = Join-Path $testRoot 'identity.json'
    Write-V02CanonicalJsonFile -Value $receiptObj -Path $receiptPath -RepositoryRoot $repo

    # A byte-identical same-version replacement must still create and retire
    # an exact backup; byte equality is never evidence that replacement ran.
    $replacementCommit = $fixtureCommit
    $replacementTree = $fixtureTree

    # Prepare secondary candidate payload for same-version replacement.
    $replacementPayload = Join-Path $testRoot 'replacement-payload'
    New-Item -ItemType Directory -Path $replacementPayload -Force | Out-Null
    Copy-Item -Path "$fixturePayload\*" -Destination $replacementPayload -Recurse

    $replacementManifest = New-V02PackageManifestObject -Profile $profile -RepositoryRoot $repo -PackageRoot $replacementPayload
    Write-V02CanonicalJsonFile -Value $replacementManifest -Path (Join-Path $replacementPayload 'package-manifest.json') -RepositoryRoot $repo

    $replacementArchivePath = Join-Path $testRoot 'HerdrOps-0.2.0-win-x64-replacement.zip'
    $null = New-DeterministicPackageArchive -PackageRoot $replacementPayload -ArchivePath $replacementArchivePath

    $replacementReceiptObj = Build-V02PackageIdentityReceiptObject `
        -Profile $profile `
        -RepositoryRoot $repo `
        -ProfilePath $profilePath `
        -ArchivePath $replacementArchivePath `
        -PackageRoot $replacementPayload

    $replacementReceiptPath = Join-Path $testRoot 'identity-replacement.json'
    Write-V02CanonicalJsonFile -Value $replacementReceiptObj -Path $replacementReceiptPath -RepositoryRoot $repo

    $mockInstallRoot = Join-Path $testRoot 'mock-install\Programs\HerdrOps'
    $mockUserDataRoot = Join-Path $testRoot 'mock-install\HerdrOps'
    $mockRegistry = @{}

    # 1. Positive: DryRun Mode
    Invoke-Case 'DryRun mode returns passing preflight and skips execution' {
        $reportPath = Join-Path $testRoot 'dry-run-report.json'
        $report = & $scriptPath `
            -Mode 'DryRun' `
            -IdentityReceiptPath $receiptPath `
            -ArchivePath $archivePath `
            -InstallRoot $mockInstallRoot `
            -UserDataRoot $mockUserDataRoot `
            -RepositoryRoot $repo `
            -ProfilePath $profilePath `
            -ReportPath $reportPath `
            -AllowElevatedForTesting

        if ($report.status -ne 'PASS' -or $report.mode -ne 'DryRun') { throw 'DryRun report status was not PASS.' }
        if ($report.scope -ne 'InstallLifecycleOnly') { throw 'Report scope was not InstallLifecycleOnly.' }
        if ($report.lifecycle.cleanInstall.status -ne 'SKIPPED') { throw 'DryRun did not skip cleanInstall.' }
        if ($report.lifecycle.sameVersionCandidateReplacement.status -ne 'SKIPPED') { throw 'DryRun did not skip sameVersionCandidateReplacement.' }
        if (-not (Test-Path -LiteralPath $reportPath -PathType Leaf)) { throw 'DryRun report was not written.' }
        Assert-V02CleanMachineReportSchema -Report $report -RepositoryRoot $repo
    }

    # 2. Positive: Fixture Lifecycle Mode
    Invoke-Case 'Fixture mode executes complete clean install, candidate replacement, rollback and uninstall' {
        $reportPath = Join-Path $testRoot 'fixture-report.json'
        $report = & $scriptPath `
            -Mode 'Fixture' `
            -IdentityReceiptPath $receiptPath `
            -ArchivePath $archivePath `
            -ReplacementIdentityReceiptPath $replacementReceiptPath `
            -ReplacementArchivePath $replacementArchivePath `
            -InstallRoot $mockInstallRoot `
            -UserDataRoot $mockUserDataRoot `
            -RepositoryRoot $repo `
            -ProfilePath $profilePath `
            -ReportPath $reportPath `
            -ExpectedSourceCommit $fixtureCommit `
            -ExpectedSourceTree $fixtureTree `
            -ExpectedReplacementSourceCommit $replacementCommit `
            -ExpectedReplacementSourceTree $replacementTree `
            -FixtureRoot $testRoot `
            -MockRegistryHive $mockRegistry `
            -AllowElevatedForTesting

        if ($report.status -ne 'PASS' -or $report.mode -ne 'Fixture') { throw 'Fixture report status was not PASS.' }
        if ($report.scope -ne 'InstallLifecycleOnly') { throw 'Scope was not InstallLifecycleOnly.' }
        if ($report.lifecycle.cleanInstall.status -ne 'PASS' -or $report.lifecycle.cleanInstall.installedFileCount -lt 5) { throw 'Clean install step failed.' }
        if ($report.lifecycle.sameVersionCandidateReplacement.status -ne 'PASS') { throw 'Candidate replacement step failed.' }
        if (-not $report.lifecycle.sameVersionCandidateReplacement.backupCreatedAndRetired) { throw 'Byte-identical replacement did not prove exact backup creation and retirement.' }
        if ($report.bindings.initial.appSha256 -cne $report.bindings.final.appSha256 -or $report.bindings.initial.coreSha256 -cne $report.bindings.final.coreSha256 -or $report.bindings.initial.receiptSha256 -cne $report.bindings.final.receiptSha256) { throw 'Replacement fixture was not byte-identical to the initial candidate.' }
        if ($report.lifecycle.rollback.status -ne 'PASS') { throw 'Rollback step failed.' }
        if ($report.lifecycle.uninstall.status -ne 'PASS') { throw 'Uninstall step failed.' }
        if ($report.retainedData.markerStatus -ne 'PRESERVED') { throw 'Retained data marker was not preserved.' }
        if ($report.residue.orphanedStagingPresent -or $report.residue.orphanedBackupPresent -or -not $report.residue.startupRegistryCleaned) { throw 'Residue inspection detected uncleared artifacts.' }
        if ($report.evidenceBoundary.evidenceClass -ne 'Synthetic' -or $report.evidenceBoundary.creditGranted) { throw 'Evidence boundary inflated credit.' }
        Assert-V02CleanMachineReportSchema -Report $report -RepositoryRoot $repo
    }

    # 3. Hostile: synthetic roots/mocks can never earn Live CleanMachine credit.
    Invoke-Case 'Live simulation with test roots and mock registry is rejected before mutation' {
        $liveInstall = Join-Path $testRoot 'live-sim\Programs\HerdrOps'
        $liveUserData = Join-Path $testRoot 'live-sim\HerdrOps'
        $liveReportPath = Join-Path $testRoot 'live-report.json'
        $liveRegistry = @{}
        Assert-Throws { & $scriptPath `
            -Mode 'Live' `
            -IdentityReceiptPath $receiptPath `
            -ArchivePath $archivePath `
            -ReplacementIdentityReceiptPath $replacementReceiptPath `
            -ReplacementArchivePath $replacementArchivePath `
            -InstallRoot $liveInstall `
            -UserDataRoot $liveUserData `
            -RepositoryRoot $repo `
            -ProfilePath $profilePath `
            -ReportPath $liveReportPath `
            -ExpectedSourceCommit $fixtureCommit `
            -ExpectedSourceTree $fixtureTree `
            -ExpectedMachineName $env:COMPUTERNAME `
            -ExpectedMachineFingerprint (Get-V02MachineFingerprint) `
            -LiveConfirmationToken 'HERDROPS-V02-CLEAN-MACHINE' `
            -IUnderstandLiveMutation `
            -MockRegistryHive $liveRegistry `
            -AllowElevatedForTesting } 'rejects mock registry|test-only controls'
        if ((Test-Path -LiteralPath $liveInstall) -or (Test-Path -LiteralPath $liveReportPath)) { throw 'Rejected Live simulation mutated its target or report path.' }
    }

    Invoke-Case 'Live mode rejects temp roots after caller-controlled LOCALAPPDATA redirection' {
        $oldLocalAppData = $env:LOCALAPPDATA
        $redirected = Join-Path $testRoot 'redirected-live-localappdata'
        $env:LOCALAPPDATA = $redirected
        try {
            Assert-Throws { & $scriptPath `
                -Mode 'Live' `
                -IdentityReceiptPath $receiptPath `
                -ArchivePath $archivePath `
                -InstallRoot (Join-Path $redirected 'Programs\HerdrOps') `
                -UserDataRoot (Join-Path $redirected 'HerdrOps') `
                -RepositoryRoot $repo `
                -ProfilePath $profilePath `
                -ExpectedMachineName ([Environment]::MachineName) `
                -ExpectedMachineFingerprint (Get-V02MachineFingerprint) `
                -LiveConfirmationToken 'HERDROPS-V02-CLEAN-MACHINE' `
                -IUnderstandLiveMutation
            } 'exact per-user HerdrOps install and user-data roots'
            if (Test-Path -LiteralPath $redirected) { throw 'Rejected LOCALAPPDATA redirection created a Live target.' }
        } finally { $env:LOCALAPPDATA = $oldLocalAppData }
    }

    # Hostile Matrix
    Invoke-Case 'Hostile 0: Fixture defaults fail before any target or registry mutation' {
        $unsafeTarget = Join-Path $testRoot 'missing-fixture-contract\Programs\HerdrOps'
        Assert-Throws {
            & $scriptPath `
                -Mode 'Fixture' `
                -IdentityReceiptPath $receiptPath `
                -ArchivePath $archivePath `
                -InstallRoot $unsafeTarget `
                -UserDataRoot (Join-Path $testRoot 'missing-fixture-contract\HerdrOps') `
                -RepositoryRoot $repo `
                -ProfilePath $profilePath `
                -AllowElevatedForTesting
        } 'requires an explicit FixtureRoot and MockRegistryHive'
        if (Test-Path -LiteralPath $unsafeTarget) { throw 'Rejected Fixture invocation created its target.' }
    }

    # Hostile 1: Forged machine name / machine fingerprint in Live mode
    Invoke-Case 'Hostile 1: Machine name mismatch in Live mode fails closed' {
        Assert-Throws {
            & $scriptPath `
                -Mode 'Live' `
                -IdentityReceiptPath $receiptPath `
                -ArchivePath $archivePath `
                -InstallRoot (Join-Path $testRoot 'hostile-machine\Programs\HerdrOps') `
                -UserDataRoot (Join-Path $testRoot 'hostile-machine\HerdrOps') `
                -RepositoryRoot $repo `
                -ProfilePath $profilePath `
                -ExpectedMachineName 'FORGED-MACHINE-NAME' `
                -ExpectedMachineFingerprint (Get-V02MachineFingerprint) `
                -LiveConfirmationToken 'HERDROPS-V02-CLEAN-MACHINE' `
                -IUnderstandLiveMutation `
                -AllowElevatedForTesting
        } 'Machine name mismatch'
    }

    Invoke-Case 'Hostile 1b: Machine fingerprint mismatch in Live mode fails closed' {
        Assert-Throws {
            & $scriptPath `
                -Mode 'Live' `
                -IdentityReceiptPath $receiptPath `
                -ArchivePath $archivePath `
                -InstallRoot (Join-Path $testRoot 'hostile-fingerprint\Programs\HerdrOps') `
                -UserDataRoot (Join-Path $testRoot 'hostile-fingerprint\HerdrOps') `
                -RepositoryRoot $repo `
                -ProfilePath $profilePath `
                -ExpectedMachineName $env:COMPUTERNAME `
                -ExpectedMachineFingerprint ('A' * 64) `
                -LiveConfirmationToken 'HERDROPS-V02-CLEAN-MACHINE' `
                -IUnderstandLiveMutation `
                -AllowElevatedForTesting
        } 'Machine fingerprint mismatch'
    }

    # Hostile 2: Colliding operator and observer identities (case-insensitive)
    Invoke-Case 'Hostile 2: Colliding operator and observer identities rejected' {
        Assert-Throws {
            & $scriptPath `
                -Mode 'DryRun' `
                -IdentityReceiptPath $receiptPath `
                -ArchivePath $archivePath `
                -InstallRoot $mockInstallRoot `
                -UserDataRoot $mockUserDataRoot `
                -RepositoryRoot $repo `
                -ProfilePath $profilePath `
                -OperatorIdentity '@operator' `
                -ObserverIdentity '@OPERATOR' `
                -AllowElevatedForTesting
        } 'OperatorIdentity and ObserverIdentity must be distinct'
    }

    # Hostile 3: Corrupt bytes in archive
    Invoke-Case 'Hostile 3: Corrupt bytes in package archive fails closed' {
        $corruptArchive = Join-Path $testRoot 'corrupt.zip'
        Copy-Item $archivePath $corruptArchive
        [IO.File]::AppendAllText($corruptArchive, 'CORRUPT')
        Assert-Throws {
            & $scriptPath `
                -Mode 'Fixture' `
                -IdentityReceiptPath $receiptPath `
                -ArchivePath $corruptArchive `
                -ReplacementIdentityReceiptPath $replacementReceiptPath `
                -ReplacementArchivePath $replacementArchivePath `
                -InstallRoot (Join-Path $testRoot 'hostile-corrupt\Programs\HerdrOps') `
                -UserDataRoot (Join-Path $testRoot 'hostile-corrupt\HerdrOps') `
                -RepositoryRoot $repo `
                -ProfilePath $profilePath `
                -ExpectedSourceCommit $fixtureCommit `
                -ExpectedSourceTree $fixtureTree `
                -ExpectedReplacementSourceCommit $replacementCommit `
                -ExpectedReplacementSourceTree $replacementTree `
                -FixtureRoot $testRoot `
                -MockRegistryHive (@{}) `
                -AllowElevatedForTesting
        } 'Package identity verification failed|SHA-256|does not match'
    }

    # Hostile 4: Stale / mismatched source commit and tree
    Invoke-Case 'Hostile 4: Expected source commit mismatch fails closed' {
        Assert-Throws {
            & $scriptPath `
                -Mode 'DryRun' `
                -IdentityReceiptPath $receiptPath `
                -ArchivePath $archivePath `
                -InstallRoot $mockInstallRoot `
                -UserDataRoot $mockUserDataRoot `
                -RepositoryRoot $repo `
                -ProfilePath $profilePath `
                -ExpectedSourceCommit '0000000000000000000000000000000000000000' `
                -AllowElevatedForTesting
        } 'Source commit mismatch'
    }

    Invoke-Case 'Hostile 4b: Expected source tree mismatch fails closed' {
        Assert-Throws {
            & $scriptPath `
                -Mode 'DryRun' `
                -IdentityReceiptPath $receiptPath `
                -ArchivePath $archivePath `
                -InstallRoot $mockInstallRoot `
                -UserDataRoot $mockUserDataRoot `
                -RepositoryRoot $repo `
                -ProfilePath $profilePath `
                -ExpectedSourceTree '0000000000000000000000000000000000000000' `
                -AllowElevatedForTesting
        } 'Source tree mismatch'
    }

    # Hostile 5: Reparse point containment escape
    Invoke-Case 'Hostile 5: Junction reparse point on install root rejected' {
        $linkRoot = Join-Path $testRoot 'junction-hostile'
        New-Item -Path $linkRoot -ItemType Directory -Force | Out-Null
        $link = Join-Path $linkRoot 'link-install'
        $junctionCreated = $false
        try {
            New-Item -ItemType Junction -Path $link -Target $testRoot -ErrorAction Stop | Out-Null
            $junctionCreated = $true
        } catch {
            $null = & cmd /c "mklink /J `"$link`" `"$testRoot`"" 2>&1
            if ($LASTEXITCODE -eq 0) { $junctionCreated = $true }
            $global:LASTEXITCODE = 0
        }
        if ($junctionCreated) {
            try {
                Assert-Throws {
                    & $scriptPath `
                        -Mode 'Fixture' `
                        -IdentityReceiptPath $receiptPath `
                        -ArchivePath $archivePath `
                        -InstallRoot $link `
                        -UserDataRoot $mockUserDataRoot `
                        -RepositoryRoot $repo `
                        -ProfilePath $profilePath `
                        -FixtureRoot $testRoot `
                        -MockRegistryHive (@{}) `
                        -AllowElevatedForTesting
                } 'reparse'
            } finally {
                # Safely remove junction before test teardown
                try {
                    $null = & cmd /c "rmdir `"$link`"" 2>&1
                } catch { }
            }
        }
    }

    # Hostile 6: Corrupt replacement candidate archive fails closed
    Invoke-Case 'Hostile 6: Corrupt replacement candidate archive fails closed' {
        $corruptReplacement = Join-Path $testRoot 'corrupt-rep.zip'
        Copy-Item $replacementArchivePath $corruptReplacement
        [IO.File]::AppendAllText($corruptReplacement, 'CORRUPT_REP')
        Assert-Throws {
            & $scriptPath `
                -Mode 'Fixture' `
                -IdentityReceiptPath $receiptPath `
                -ArchivePath $archivePath `
                -ReplacementIdentityReceiptPath $replacementReceiptPath `
                -ReplacementArchivePath $corruptReplacement `
                -InstallRoot (Join-Path $testRoot 'rep-fail\Programs\HerdrOps') `
                -UserDataRoot (Join-Path $testRoot 'rep-fail\HerdrOps') `
                -RepositoryRoot $repo `
                -ProfilePath $profilePath `
                -ExpectedSourceCommit $fixtureCommit `
                -ExpectedSourceTree $fixtureTree `
                -ExpectedReplacementSourceCommit $replacementCommit `
                -ExpectedReplacementSourceTree $replacementTree `
                -FixtureRoot $testRoot `
                -MockRegistryHive (@{}) `
                -AllowElevatedForTesting
        } 'Package identity verification failed|SHA-256|does not match'
    }

    # Hostile 7: Leftover residue injection
    Invoke-Case 'Hostile 7: Residue detection halts acceptance and reports FAIL' {
        Assert-Throws {
            & $scriptPath `
                -Mode 'Fixture' `
                -IdentityReceiptPath $receiptPath `
                -ArchivePath $archivePath `
                -ReplacementIdentityReceiptPath $replacementReceiptPath `
                -ReplacementArchivePath $replacementArchivePath `
                -InstallRoot (Join-Path $testRoot 'residue-fail\Programs\HerdrOps') `
                -UserDataRoot (Join-Path $testRoot 'residue-fail\HerdrOps') `
                -RepositoryRoot $repo `
                -ProfilePath $profilePath `
                -ExpectedSourceCommit $fixtureCommit `
                -ExpectedSourceTree $fixtureTree `
                -ExpectedReplacementSourceCommit $replacementCommit `
                -ExpectedReplacementSourceTree $replacementTree `
                -FixtureRoot $testRoot `
                -MockRegistryHive (@{}) `
                -TestInjectResidueFailure `
                -AllowElevatedForTesting
        } 'Residue inspection failed'
    }

    # Hostile 8: Live mode without token or confirmation
    Invoke-Case 'Hostile 8: Live mode without confirmation token fails closed' {
        Assert-Throws {
            & $scriptPath `
                -Mode 'Live' `
                -IdentityReceiptPath $receiptPath `
                -ArchivePath $archivePath `
                -InstallRoot (Join-Path $testRoot 'live-notoken\Programs\HerdrOps') `
                -UserDataRoot (Join-Path $testRoot 'live-notoken\HerdrOps') `
                -RepositoryRoot $repo `
                -ProfilePath $profilePath `
                -IUnderstandLiveMutation `
                -AllowElevatedForTesting
        } 'requires -LiveConfirmationToken'
    }

    # Hostile 9: Evidence boundary inflation
    Invoke-Case 'Hostile 9: Schema rejects tampered evidence boundary claiming credit' {
        $tamperedReport = & $scriptPath `
            -Mode 'DryRun' `
            -IdentityReceiptPath $receiptPath `
            -ArchivePath $archivePath `
            -InstallRoot $mockInstallRoot `
            -UserDataRoot $mockUserDataRoot `
            -RepositoryRoot $repo `
            -ProfilePath $profilePath `
            -AllowElevatedForTesting

        $tamperedReport.evidenceBoundary.creditGranted = $true
        Assert-Throws {
            Assert-V02CleanMachineReportSchema -Report $tamperedReport -RepositoryRoot $repo
        } 'creditGranted = false'
    }

    Invoke-Case 'Hostile 10: Existing report is never overwritten and staging is retired' {
        $reportPath = Join-Path $testRoot 'no-clobber-report.json'
        $null = & $scriptPath `
            -Mode 'DryRun' `
            -IdentityReceiptPath $receiptPath `
            -ArchivePath $archivePath `
            -InstallRoot $mockInstallRoot `
            -UserDataRoot $mockUserDataRoot `
            -RepositoryRoot $repo `
            -ProfilePath $profilePath `
            -ReportPath $reportPath `
            -AllowElevatedForTesting
        $before = Get-V02StableFileIdentity $reportPath
        Assert-Throws {
            & $scriptPath `
                -Mode 'DryRun' `
                -IdentityReceiptPath $receiptPath `
                -ArchivePath $archivePath `
                -InstallRoot $mockInstallRoot `
                -UserDataRoot $mockUserDataRoot `
                -RepositoryRoot $repo `
                -ProfilePath $profilePath `
                -ReportPath $reportPath `
                -AllowElevatedForTesting
        } 'Refusing to overwrite existing report'
        $after = Get-V02StableFileIdentity $reportPath
        if ($before.Sha256 -cne $after.Sha256 -or $before.Length -ne $after.Length) { throw 'Existing report bytes changed.' }
        if (@(Get-ChildItem -LiteralPath $testRoot -Filter '.no-clobber-report.json.staging-*' -Force).Count -ne 0) { throw 'Report staging residue remained.' }
    }

    Invoke-Case 'Hostile 10b: Caller-authored clean-host authorization cannot verify' {
        $forgedAuthorization = Join-Path $testRoot 'forged-clean-host-authorization.json'
        $forgedSignature = Join-Path $testRoot 'forged-clean-host-authorization.p7s'
        [IO.File]::WriteAllText($forgedAuthorization,'{}',(New-Object Text.UTF8Encoding($false)))
        [IO.File]::WriteAllBytes($forgedSignature,[byte[]](1,2,3,4,5,6,7,8))
        Assert-Throws {
            Read-V02CleanHostAuthorization `
                -AuthorizationPath $forgedAuthorization `
                -SignaturePath $forgedSignature `
                -MachineName ([Environment]::MachineName) `
                -MachineFingerprint (Get-V02MachineFingerprint) `
                -PrincipalSid (Get-V02ExecutingPrincipalSid) `
                -InstallRoot $mockInstallRoot `
                -UserDataRoot $mockUserDataRoot `
                -InitialBinding ([pscustomobject]@{}) `
                -FinalBinding ([pscustomobject]@{})
        } 'signature is invalid or untrusted'
    }

    Invoke-Case 'Hostile 10c: Failed report cleanup keeps its original handle and never deletes a leaf-swap victim' {
        $failedReport = Join-Path $testRoot 'failed-report.json'
        $quarantinedOriginal = Join-Path $testRoot 'failed-report-original.json'
        $hostileHardlink = Join-Path $testRoot 'failed-report-hostile-link.json'
        $victim = Join-Path $testRoot 'failed-report-victim.bin'
        $victimBytes = [byte[]](91,82,73,64,55,46)
        [IO.File]::WriteAllBytes($victim,$victimBytes)
        $victimSha256 = (Get-V02StableFileIdentity $victim).Sha256

        $originalAssert = ${function:script:Assert-V02SameHandleIdentity}
        $originalDeletePendingAssert = ${function:script:Assert-V02DeletePendingReportIdentity}
        $originalOpenDeletionLease = ${function:script:Open-V02FileDeletionLease}
        $script:V02FailedReportCleanupProbe = @{
            FailureInjected = $false
            CleanupReached = $false
            MoveBlocked = $false
            SwapBlocked = $false
            HardlinkAttempted = $false
            HardlinkBlocked = $false
            LegacyPathReopenReached = $false
            FailedReport = $failedReport
            QuarantinedOriginal = $quarantinedOriginal
            HostileHardlink = $hostileHardlink
            Victim = $victim
            OriginalAssert = $originalAssert
            OriginalDeletePendingAssert = $originalDeletePendingAssert
            OriginalOpenDeletionLease = $originalOpenDeletionLease
        }
        try {
            Set-Item -LiteralPath Function:\script:Assert-V02SameHandleIdentity -Value {
                param($Handle,$Expected,[string]$ExpectedPath,[string]$Context,[switch]$RequireSingleLink)
                if ($Context -ceq 'clean-machine report' -and -not $script:V02FailedReportCleanupProbe.FailureInjected) {
                    $script:V02FailedReportCleanupProbe.FailureInjected = $true
                    throw 'INJECTED_POST_CREATE_REPORT_FAILURE'
                }
                if ($Context -ceq 'clean-machine report' -and -not $script:V02FailedReportCleanupProbe.CleanupReached) {
                    $script:V02FailedReportCleanupProbe.CleanupReached = $true
                    try { [IO.File]::Move($script:V02FailedReportCleanupProbe.FailedReport,$script:V02FailedReportCleanupProbe.QuarantinedOriginal) }
                    catch { $script:V02FailedReportCleanupProbe.MoveBlocked = $true }
                    try { [IO.File]::Move($script:V02FailedReportCleanupProbe.Victim,$script:V02FailedReportCleanupProbe.FailedReport) }
                    catch { $script:V02FailedReportCleanupProbe.SwapBlocked = $true }
                }
                & $script:V02FailedReportCleanupProbe.OriginalAssert @PSBoundParameters
            }
            Set-Item -LiteralPath Function:\script:Assert-V02DeletePendingReportIdentity -Value {
                param($Handle,$Expected,[string]$ExpectedPath)
                $result = & $script:V02FailedReportCleanupProbe.OriginalDeletePendingAssert @PSBoundParameters
                # This hook is the exact former final-guard-to-delete window.
                # Delete-pending must make the hostile hardlink impossible.
                $script:V02FailedReportCleanupProbe.HardlinkAttempted = $true
                try { New-Item -ItemType HardLink -Path $script:V02FailedReportCleanupProbe.HostileHardlink -Target $script:V02FailedReportCleanupProbe.FailedReport -ErrorAction Stop | Out-Null }
                catch { $script:V02FailedReportCleanupProbe.HardlinkBlocked = $true }
                return $result
            }
            Set-Item -LiteralPath Function:\script:Open-V02FileDeletionLease -Value {
                param([string]$Path)
                if ([StringComparer]::OrdinalIgnoreCase.Equals([IO.Path]::GetFullPath($Path),[IO.Path]::GetFullPath($script:V02FailedReportCleanupProbe.FailedReport))) {
                    $script:V02FailedReportCleanupProbe.LegacyPathReopenReached = $true
                    [IO.File]::Move($script:V02FailedReportCleanupProbe.FailedReport,$script:V02FailedReportCleanupProbe.QuarantinedOriginal)
                    [IO.File]::Move($script:V02FailedReportCleanupProbe.Victim,$script:V02FailedReportCleanupProbe.FailedReport)
                }
                & $script:V02FailedReportCleanupProbe.OriginalOpenDeletionLease -Path $Path
            }

            Assert-Throws {
                Write-V02CleanMachineReportFile -Value ([pscustomobject][ordered]@{ probe = 'failed-report-cleanup' }) -Path $failedReport -RepositoryRoot $repo
            } '^INJECTED_POST_CREATE_REPORT_FAILURE$'
        } finally {
            Set-Item -LiteralPath Function:\script:Assert-V02SameHandleIdentity -Value $originalAssert
            Set-Item -LiteralPath Function:\script:Assert-V02DeletePendingReportIdentity -Value $originalDeletePendingAssert
            Set-Item -LiteralPath Function:\script:Open-V02FileDeletionLease -Value $originalOpenDeletionLease
        }

        if (-not $script:V02FailedReportCleanupProbe.CleanupReached -or -not $script:V02FailedReportCleanupProbe.MoveBlocked -or -not $script:V02FailedReportCleanupProbe.SwapBlocked) { throw 'Hostile move/swap fixture did not reach the held-handle failed-report cleanup boundary.' }
        if (-not $script:V02FailedReportCleanupProbe.HardlinkAttempted -or -not $script:V02FailedReportCleanupProbe.HardlinkBlocked) { throw 'A hardlink was not blocked in the former final-guard-to-delete cleanup window.' }
        if ($script:V02FailedReportCleanupProbe.LegacyPathReopenReached) { throw 'Failed report cleanup reopened a reusable pathname after releasing the original handle.' }
        if ((Test-Path -LiteralPath $failedReport) -or (Test-Path -LiteralPath $quarantinedOriginal) -or (Test-Path -LiteralPath $hostileHardlink)) { throw 'Failed report bytes survived held-handle cleanup.' }
        if (-not (Test-Path -LiteralPath $victim -PathType Leaf) -or (Get-V02StableFileIdentity $victim).Sha256 -cne $victimSha256) { throw 'Failed report cleanup deleted or changed the leaf-swap victim canary.' }
        $script:V02FailedReportCleanupProbe = $null
    }

    Invoke-Case 'Hostile 10d: Pre-delete hardlink fails the post-pending guard and safely cancels deletion' {
        $failedReport = Join-Path $testRoot 'failed-report-cancel.json'
        $hostileHardlink = Join-Path $testRoot 'failed-report-cancel-link.json'
        $originalAssert = ${function:script:Assert-V02SameHandleIdentity}
        $script:V02FailedReportCancellationProbe = @{ Calls = 0; OriginalAssert = $originalAssert; FailedReport = $failedReport; HostileHardlink = $hostileHardlink }
        try {
            Set-Item -LiteralPath Function:\script:Assert-V02SameHandleIdentity -Value {
                param($Handle,$Expected,[string]$ExpectedPath,[string]$Context,[switch]$RequireSingleLink)
                if ($Context -ceq 'clean-machine report') {
                    $script:V02FailedReportCancellationProbe.Calls++
                    if ($script:V02FailedReportCancellationProbe.Calls -eq 1) {
                        New-Item -ItemType HardLink -Path $script:V02FailedReportCancellationProbe.HostileHardlink -Target $script:V02FailedReportCancellationProbe.FailedReport -ErrorAction Stop | Out-Null
                        throw 'INJECTED_FAILURE_WITH_PRE_DELETE_HARDLINK'
                    }
                }
                & $script:V02FailedReportCancellationProbe.OriginalAssert @PSBoundParameters
            }
            Assert-Throws {
                Write-V02CleanMachineReportFile -Value ([pscustomobject][ordered]@{ probe = 'failed-report-delete-cancellation' }) -Path $failedReport -RepositoryRoot $repo
            } 'must have no surviving links after delete-pending'
        } finally {
            Set-Item -LiteralPath Function:\script:Assert-V02SameHandleIdentity -Value $originalAssert
        }
        if ($script:V02FailedReportCancellationProbe.Calls -ne 2) { throw 'Post-delete-pending identity guard was not reached.' }
        if (-not (Test-Path -LiteralPath $failedReport -PathType Leaf) -or -not (Test-Path -LiteralPath $hostileHardlink -PathType Leaf)) { throw 'Delete cancellation did not preserve the guarded object after hardlink detection.' }
        if ((Get-V02StableFileIdentity $failedReport).Sha256 -cne (Get-V02StableFileIdentity $hostileHardlink).Sha256) { throw 'Delete cancellation paths no longer reference identical failed-report bytes.' }
        Remove-Item -LiteralPath $hostileHardlink -Force
        Remove-Item -LiteralPath $failedReport -Force
        $script:V02FailedReportCancellationProbe = $null
    }

    Invoke-Case 'Hostile 11: Stable copy refuses a pre-existing hardlink without clobbering it' {
        $hardlinkSource = Join-Path $testRoot 'hardlink-source.bin'
        $hardlinkVictim = Join-Path $testRoot 'hardlink-victim.bin'
        $hardlinkDestination = Join-Path $testRoot 'hardlink-destination.bin'
        [IO.File]::WriteAllBytes($hardlinkSource,[byte[]](1,2,3,4))
        [IO.File]::WriteAllBytes($hardlinkVictim,[byte[]](9,8,7,6))
        try {
            New-Item -ItemType HardLink -Path $hardlinkDestination -Target $hardlinkVictim -ErrorAction Stop | Out-Null
        } catch {
            throw "Hardlink hostile fixture could not be created: $($_.Exception.Message)"
        }
        Assert-Throws { Copy-V02StableFile -Source $hardlinkSource -Destination $hardlinkDestination } 'Refusing to overwrite stable-copy destination'
        if ((Get-V02StableFileIdentity $hardlinkVictim).Sha256 -cne (Get-V02StableFileIdentity $hardlinkDestination).Sha256) { throw 'Hardlink victim changed.' }
    }

    Invoke-Case 'Fixture suite never mutates real per-user roots or HKCU startup state' {
        if ((Get-PathSurfaceSnapshot $realInstallRoot) -cne $realInstallBefore) { throw 'Real LOCALAPPDATA install-root surface changed.' }
        if ((Get-PathSurfaceSnapshot $realUserDataRoot) -cne $realUserDataBefore) { throw 'Real LOCALAPPDATA user-data surface changed.' }
        $realStartupAfter = Get-V02UserStartupState
        if ($realStartupAfter.Exists -ne $realStartupBefore.Exists -or [string]$realStartupAfter.Value -cne [string]$realStartupBefore.Value -or [string]$realStartupAfter.Kind -cne [string]$realStartupBefore.Kind) { throw 'Real HKCU startup state changed.' }
        $productionSources = @(
            (Get-Content -LiteralPath $scriptPath -Raw)
            (Get-Content -LiteralPath (Join-Path $PSScriptRoot 'Install-HerdrOpsV02Package.ps1') -Raw)
            (Get-Content -LiteralPath (Join-Path $PSScriptRoot 'Uninstall-HerdrOpsV02Package.ps1') -Raw)
        ) -join "`n"
        if ($productionSources -match '(?im)\bStart-Process\b|&[^\r\n]*HerdrOps\.App\.exe') { throw 'Fixture production path contains a product-launch primitive.' }
    }

} finally {
    if (Test-Path -LiteralPath $testRoot) {
        Remove-PackagingTempDirectory -Path $testRoot
    }
}

Write-Host "RESULT: $script:Passed passed, $script:Failed failed"
if ($script:Failed -gt 0) {
    throw "$script:Failed v0.2 clean-machine test(s) failed."
}
$global:LASTEXITCODE = 0
