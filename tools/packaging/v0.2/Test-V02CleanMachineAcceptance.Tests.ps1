#requires -Version 5.1

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'V02CleanMachine.Common.ps1')
$scriptPath = Join-Path $PSScriptRoot 'Invoke-V02CleanMachineAcceptance.ps1'

$testRoot = New-PackagingTempDirectory -Prefix 'HerdrOps-V02CleanMachineTests-'
$script:Passed = 0
$script:Failed = 0

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

    # Prepare secondary candidate payload for same-version replacement
    $replacementPayload = Join-Path $testRoot 'replacement-payload'
    New-Item -ItemType Directory -Path $replacementPayload -Force | Out-Null
    Copy-Item -Path "$fixturePayload\*" -Destination $replacementPayload -Recurse
    [IO.File]::WriteAllBytes((Join-Path $replacementPayload 'HerdrOps.App.dll'), [byte[]](100, 101, 102, 103))

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
            -MockRegistryHive $mockRegistry `
            -AllowElevatedForTesting

        if ($report.status -ne 'PASS' -or $report.mode -ne 'Fixture') { throw 'Fixture report status was not PASS.' }
        if ($report.scope -ne 'InstallLifecycleOnly') { throw 'Scope was not InstallLifecycleOnly.' }
        if ($report.lifecycle.cleanInstall.status -ne 'PASS' -or $report.lifecycle.cleanInstall.installedFileCount -lt 5) { throw 'Clean install step failed.' }
        if ($report.lifecycle.sameVersionCandidateReplacement.status -ne 'PASS') { throw 'Candidate replacement step failed.' }
        if ($report.lifecycle.rollback.status -ne 'PASS') { throw 'Rollback step failed.' }
        if ($report.lifecycle.uninstall.status -ne 'PASS') { throw 'Uninstall step failed.' }
        if ($report.retainedData.markerStatus -ne 'PRESERVED') { throw 'Retained data marker was not preserved.' }
        if ($report.residue.orphanedStagingPresent -or $report.residue.orphanedBackupPresent -or -not $report.residue.startupRegistryCleaned) { throw 'Residue inspection detected uncleared artifacts.' }
        if ($report.evidenceBoundary.evidenceClass -ne 'Synthetic' -or $report.evidenceBoundary.creditGranted) { throw 'Evidence boundary inflated credit.' }
        Assert-V02CleanMachineReportSchema -Report $report -RepositoryRoot $repo
    }

    # 3. Positive: Live simulation mode with verified tokens
    Invoke-Case 'Live simulation mode earns CleanMachine with strict token' {
        $liveInstall = Join-Path $testRoot 'live-sim\Programs\HerdrOps'
        $liveUserData = Join-Path $testRoot 'live-sim\HerdrOps'
        $liveReportPath = Join-Path $testRoot 'live-report.json'
        $liveRegistry = @{}
        $report = & $scriptPath `
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
            -AllowElevatedForTesting

        if ($report.status -ne 'PASS' -or $report.mode -ne 'Live') { throw 'Live report status was not PASS.' }
        if ($report.scope -ne 'InstallLifecycleOnly') { throw 'Scope was not InstallLifecycleOnly.' }
        if ($report.actualHerdrStarted -ne $false -or $report.herdrOpsStarted -ne $false -or $report.networkContacted -ne $false) { throw 'Execution flag was not false.' }
        if ($report.evidenceBoundary.evidenceClass -ne 'CleanMachine') { throw 'Live mode did not record CleanMachine evidence class.' }
        if ($report.evidenceBoundary.creditGranted -ne $true) { throw 'Live clean-machine report did not grant install lifecycle credit.' }
        if ($report.evidenceBoundary.actualHerdrRuntime -ne 'NOT_OBSERVED' -or $report.evidenceBoundary.independentReview -ne 'NOT_OBSERVED' -or $report.evidenceBoundary.humanGo -ne 'NOT_OBSERVED' -or $report.evidenceBoundary.releaseCredit -ne 'NOT_OBSERVED') { throw 'Live clean-machine report claimed unearned runtime/independent/human/release credit.' }
        Assert-V02CleanMachineReportSchema -Report $report -RepositoryRoot $repo
    }

    # Hostile Matrix
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
                -InstallRoot (Join-Path $testRoot 'hostile-corrupt\Programs\HerdrOps') `
                -UserDataRoot (Join-Path $testRoot 'hostile-corrupt\HerdrOps') `
                -RepositoryRoot $repo `
                -ProfilePath $profilePath `
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
                -InstallRoot (Join-Path $testRoot 'residue-fail\Programs\HerdrOps') `
                -UserDataRoot (Join-Path $testRoot 'residue-fail\HerdrOps') `
                -RepositoryRoot $repo `
                -ProfilePath $profilePath `
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
