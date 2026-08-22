#requires -Version 5.1

[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'RendererCompatibility.Common.ps1')

$script:PositiveCases = 0
$script:NegativeCases = 0

function Pass([string]$Name) {
    $script:PositiveCases++
    Write-Host "PASS positive: $Name"
}

function Pass-Negative([string]$Name) {
    $script:NegativeCases++
    Write-Host "PASS negative: $Name"
}

function Assert-Throws([scriptblock]$Action, [string]$ExpectedPattern, [string]$Context) {
    $failed = $false
    $message = $null
    try {
        & $Action
    } catch {
        $failed = $true
        $message = [string]$_.Exception.Message
        if ([string]::IsNullOrWhiteSpace($message)) {
            $message = [string]$_
        }
    }
    if (-not $failed) {
        throw "$Context did not throw an exception."
    }
    if (-not [string]::IsNullOrWhiteSpace($ExpectedPattern)) {
        if ($message -notmatch $ExpectedPattern) {
            throw "$Context threw with message '$message', which did not match expected pattern '$ExpectedPattern'."
        }
    }
    Pass-Negative $Context
}

function New-IsolatedTestRepository([string]$Root) {
    New-Item -ItemType Directory -Path $Root -Force | Out-Null
    [IO.File]::WriteAllText((Join-Path $Root 'source.txt'), 'bound source', (New-Object Text.UTF8Encoding($false)))
    $worktree = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
    $packageDir = Join-Path $Root 'tools\packaging\v0.2'
    $libDir = Join-Path $Root 'tools\lib'
    $planDir = Join-Path $Root 'Plan\reference-hosts'
    $referenceDir = Join-Path $Root 'docs\design\reference'
    New-Item -ItemType Directory -Path $packageDir, $libDir, $planDir, $referenceDir -Force | Out-Null
    $sourcePackageDir = Join-Path $PSScriptRoot '..\packaging\v0.2'
    Copy-Item (Join-Path $sourcePackageDir 'package-identity-profile.json') $packageDir
    Copy-Item (Join-Path $sourcePackageDir 'package-identity-receipt.schema.json') $packageDir
    Copy-Item (Join-Path $worktree 'tools\lib\V02ReferenceHostProfile.ps1') $libDir
    Copy-Item (Join-Path $worktree 'Plan\reference-hosts\v0.2.json') $planDir
    Copy-Item (Join-Path $worktree 'Plan\reference-hosts\reference-host-profile.schema.json') $planDir
    Copy-Item (Join-Path $worktree 'docs\design\reference\*') $referenceDir -Recurse

    & git -C $Root init --quiet
    & git -C $Root -c core.hooksPath=NUL -c user.name=RendererHarnessFixture -c user.email=renderer-harness@example.invalid add .
    & git -C $Root -c core.hooksPath=NUL -c commit.gpgsign=false -c user.name=RendererHarnessFixture -c user.email=renderer-harness@example.invalid commit --quiet -m fixture
    if ($LASTEXITCODE -ne 0) {
        throw 'Unable to create isolated Git fixture repository.'
    }
    return [pscustomobject]@{
        Root = $Root
        Commit = (& git -C $Root rev-parse HEAD).Trim()
        Tree = (& git -C $Root rev-parse 'HEAD^{tree}').Trim()
    }
}

function New-IsolatedTestPackage([string]$Root, [string]$RepositoryRoot, [string]$Commit, [string]$Tree) {
    New-Item -ItemType Directory -Path $Root -Force | Out-Null
    $packageRoot = Join-Path $Root 'package'
    New-Item -ItemType Directory -Path $packageRoot -Force | Out-Null

    $appBytes = [Text.Encoding]::UTF8.GetBytes('App Binary Content')
    $coreBytes = [Text.Encoding]::UTF8.GetBytes('Core Binary Content')
    $appPath = Join-Path $packageRoot 'HerdrOps.App.exe'
    $corePath = Join-Path $packageRoot 'HerdrOps.Core.exe'
    [IO.File]::WriteAllBytes($appPath, $appBytes)
    [IO.File]::WriteAllBytes($corePath, $coreBytes)

    $profilePath = Join-Path $RepositoryRoot 'tools\packaging\v0.2\package-identity-profile.json'
    $profileValue = Read-RendererPackageProfile $profilePath
    $profileIdentity = Get-RendererPackageProfileIdentity $profilePath $profileValue $RepositoryRoot

    $manifest = New-RendererPackageManifest $profileValue $RepositoryRoot $packageRoot
    $manifestPath = Join-Path $packageRoot 'package-manifest.json'
    Write-RendererPackageCanonicalJson $manifest $manifestPath $RepositoryRoot
    $manifestStable = Get-RendererPackageStableIdentity $manifestPath

    $archivePath = Join-Path $Root 'HerdrOps-0.2.0-win-x64.zip'
    $null = New-RendererDeterministicPackageArchive $packageRoot $archivePath
    $archiveStable = Get-RendererPackageStableIdentity $archivePath

    $appStable = Get-RendererPackageStableIdentity $appPath
    $coreStable = Get-RendererPackageStableIdentity $corePath

    $receiptValue = [pscustomobject][ordered]@{
        schemaVersion = 1
        profileId = $script:RendererPackageProfileId
        issue = 149
        packageVersion = '0.2.0'
        runtimeIdentifier = 'win-x64'
        source = [pscustomobject][ordered]@{
            commitSha = $Commit
            treeSha = $Tree
        }
        profile = [pscustomobject][ordered]@{
            id = $profileIdentity.Id
            relativePath = $profileIdentity.RelativePath
            bytes = [long]$profileIdentity.Bytes
            fileSha256 = $profileIdentity.FileSha256
            canonicalSha256 = $profileIdentity.CanonicalSha256
        }
        archive = [pscustomobject][ordered]@{
            relativePath = 'HerdrOps-0.2.0-win-x64.zip'
            fileName = 'HerdrOps-0.2.0-win-x64.zip'
            bytes = [long]$archiveStable.Length
            sha256 = $archiveStable.Sha256
        }
        packageManifest = [pscustomobject][ordered]@{
            fileName = 'package-manifest.json'
            bytes = [long]$manifestStable.Length
            sha256 = $manifestStable.Sha256
            contentSha256 = $manifest.contentSha256
            fileCount = [int]$manifest.fileCount
            totalBytes = [long]$manifest.totalBytes
        }
        components = [pscustomobject][ordered]@{
            app = [pscustomobject][ordered]@{
                relativePath = 'HerdrOps.App.exe'
                bytes = [long]$appStable.Length
                sha256 = $appStable.Sha256
            }
            core = [pscustomobject][ordered]@{
                relativePath = 'HerdrOps.Core.exe'
                bytes = [long]$coreStable.Length
                sha256 = $coreStable.Sha256
            }
        }
        referenceHost = [pscustomobject][ordered]@{
            profileId = $script:RendererProfileId
            profileSha256 = $script:RendererProfileSha256
        }
        renderer = [pscustomobject][ordered]@{
            policy = 'software-only-process-wide'
            wpfProcessRenderMode = 'SoftwareOnly'
        }
        evidenceBoundary = [pscustomobject][ordered]@{
            evidenceClass = 'PackagedCompatibilityPreparation'
            runtimeUse = 'not-used'
            actualHerdrUsed = $false
            runtimeCredit = 'NOT CLAIMED'
            releaseCredit = 'NOT CLAIMED'
        }
    }

    $receiptPath = Join-Path $Root 'package-identity-receipt.json'
    Write-RendererPackageCanonicalJson $receiptValue $receiptPath $RepositoryRoot

    return [pscustomobject]@{
        Root = $Root
        PackageRoot = $packageRoot
        ArchivePath = $archivePath
        ReceiptPath = $receiptPath
        ProfilePath = $profilePath
        AppPath = $appPath
        CorePath = $corePath
    }
}

$temp = Join-Path ([IO.Path]::GetTempPath()) ('herdrops-capture-harness-' + [Guid]::NewGuid().ToString('N'))
try {
    New-Item -ItemType Directory -Path $temp -Force | Out-Null
    Write-Host 'INFO creating isolated repo fixture...'
    $repo = New-IsolatedTestRepository (Join-Path $temp 'repo')
    Write-Host 'INFO creating isolated package fixture...'
    $pkg = New-IsolatedTestPackage (Join-Path $temp 'pkg') $repo.Root $repo.Commit $repo.Tree
    Write-Host 'INFO invoking harness for positive baseline...'

    # 1. Positive Baseline: Full Harness Execution
    $out1 = Join-Path $temp 'evidence-out-1'
    $result1 = & (Join-Path $PSScriptRoot 'Invoke-V02LiveRendererCapture.ps1') `
        -OutputDirectory $out1 `
        -PackageRoot $pkg.PackageRoot `
        -ArchivePath $pkg.ArchivePath `
        -IdentityReceiptPath $pkg.ReceiptPath `
        -RepositoryRoot $repo.Root `
        -ProfilePath $pkg.ProfilePath `
        -SyntheticCapturesForTesting `
        -AllowElevatedForTesting `
        -AllowNonReferenceHostForTesting
    Write-Host 'INFO positive baseline execution complete.'

    if ($result1.EvidenceClassification -cne 'PackagedCompatibilityCandidate' -or
        $result1.Status -cne 'ManifestCreated' -or
        $result1.CaptureCount -ne 20 -or
        $result1.ThaiCaptures -ne 10 -or
        $result1.EnglishCaptures -ne 10 -or
        $result1.LifecycleStages -ne 8 -or
        -not $result1.SoftwareOnlyConfirmed -or
        -not $result1.PreFirstHwndProofConfirmed -or
        $result1.HumanReview -cne 'NOT_OBSERVED' -or
        $result1.ActualHerdrRuntime -cne 'NOT_OBSERVED' -or
        [bool]$result1.ReleaseCredit -or
        [bool]$result1.PackagedCompatibilityReadyForIssue149Closure) {
        throw 'Positive baseline result object classification or properties invalid.'
    }

    $manifestValidation = Test-RendererCompatibilityManifest `
        -ManifestPath $result1.ManifestPath `
        -EvidenceRoot $out1 `
        -RepositoryRoot $repo.Root `
        -ValidateBindings

    if ($manifestValidation.EvidenceClassification -cne 'PackagedCompatibilityCandidate' -or
        $manifestValidation.StructuralValidation -cne 'PASS' -or
        $manifestValidation.BindingValidation -cne 'PASS' -or
        $manifestValidation.GovernanceProfileConsistency -cne 'PASS' -or
        $manifestValidation.HumanReview -cne 'NOT_OBSERVED' -or
        $manifestValidation.ActualHerdrRuntime -cne 'NOT_OBSERVED' -or
        [bool]$manifestValidation.CreditGranted -or
        [bool]$manifestValidation.PackagedCompatibilityReadyForIssue149Closure) {
        throw 'Self-validation of positive baseline manifest failed.'
    }
    Pass 'operator-driven capture harness generates strict validated candidate evidence'

    # 2. Hostile: No-clobber target directory protection
    Assert-Throws {
        & (Join-Path $PSScriptRoot 'Invoke-V02LiveRendererCapture.ps1') `
            -OutputDirectory $out1 `
            -PackageRoot $pkg.PackageRoot `
            -ArchivePath $pkg.ArchivePath `
            -IdentityReceiptPath $pkg.ReceiptPath `
            -RepositoryRoot $repo.Root `
            -ProfilePath $pkg.ProfilePath `
            -SyntheticCapturesForTesting `
            -AllowElevatedForTesting `
            -AllowNonReferenceHostForTesting
    } 'already exists.*no-clobber' 'no-clobber existing directory protection'

    # 3. Hostile: Missing capture file (9 Thai instead of 10)
    $outMissing = Join-Path $temp 'evidence-out-missing-capture'
    Assert-Throws {
        & (Join-Path $PSScriptRoot 'Invoke-V02LiveRendererCapture.ps1') `
            -OutputDirectory $outMissing `
            -PackageRoot $pkg.PackageRoot `
            -ArchivePath $pkg.ArchivePath `
            -IdentityReceiptPath $pkg.ReceiptPath `
            -RepositoryRoot $repo.Root `
            -ProfilePath $pkg.ProfilePath `
            -SyntheticCapturesForTesting `
            -AllowElevatedForTesting `
            -AllowNonReferenceHostForTesting `
            -TestFaultStage 'MissingCapture'
    } 'requires exactly 20 captures' 'missing capture fails closed'

    if (Test-Path -LiteralPath $outMissing) {
        throw 'Failed harness execution left output directory behind.'
    }
    Pass-Negative 'failed execution cleans up staging'

    # 4. Hostile: Corrupt non-PNG capture bytes
    $outCorrupt = Join-Path $temp 'evidence-out-corrupt-png'
    Assert-Throws {
        & (Join-Path $PSScriptRoot 'Invoke-V02LiveRendererCapture.ps1') `
            -OutputDirectory $outCorrupt `
            -PackageRoot $pkg.PackageRoot `
            -ArchivePath $pkg.ArchivePath `
            -IdentityReceiptPath $pkg.ReceiptPath `
            -RepositoryRoot $repo.Root `
            -ProfilePath $pkg.ProfilePath `
            -SyntheticCapturesForTesting `
            -AllowElevatedForTesting `
            -AllowNonReferenceHostForTesting `
            -TestFaultStage 'CorruptPng'
    } 'not a complete decodable PNG' 'corrupt PNG capture fails closed'

    # 5. Hostile: Late pre-first-HWND proof
    $outLate = Join-Path $temp 'evidence-out-late-pre-first-hwnd'
    Assert-Throws {
        & (Join-Path $PSScriptRoot 'Invoke-V02LiveRendererCapture.ps1') `
            -OutputDirectory $outLate `
            -PackageRoot $pkg.PackageRoot `
            -ArchivePath $pkg.ArchivePath `
            -IdentityReceiptPath $pkg.ReceiptPath `
            -RepositoryRoot $repo.Root `
            -ProfilePath $pkg.ProfilePath `
            -SyntheticCapturesForTesting `
            -AllowElevatedForTesting `
            -AllowNonReferenceHostForTesting `
            -TestFaultStage 'LatePreFirstHwnd'
    } 'The JSON is not valid with the schema|HWND ordering is invalid|outside exact order' 'late pre-first-HWND proof fails closed'

    # 6. Hostile: Hardware mode drift during lifecycle
    $outHardware = Join-Path $temp 'evidence-out-hardware-mode'
    Assert-Throws {
        & (Join-Path $PSScriptRoot 'Invoke-V02LiveRendererCapture.ps1') `
            -OutputDirectory $outHardware `
            -PackageRoot $pkg.PackageRoot `
            -ArchivePath $pkg.ArchivePath `
            -IdentityReceiptPath $pkg.ReceiptPath `
            -RepositoryRoot $repo.Root `
            -ProfilePath $pkg.ProfilePath `
            -SyntheticCapturesForTesting `
            -AllowElevatedForTesting `
            -AllowNonReferenceHostForTesting `
            -TestFaultStage 'HardwareModeDrift'
    } 'The JSON is not valid with the schema|not native SoftwareOnly true|SoftwareOnly' 'hardware mode drift fails closed'

    # 7. Hostile: Out-of-order lifecycle stages
    $outOrder = Join-Path $temp 'evidence-out-order'
    Assert-Throws {
        & (Join-Path $PSScriptRoot 'Invoke-V02LiveRendererCapture.ps1') `
            -OutputDirectory $outOrder `
            -PackageRoot $pkg.PackageRoot `
            -ArchivePath $pkg.ArchivePath `
            -IdentityReceiptPath $pkg.ReceiptPath `
            -RepositoryRoot $repo.Root `
            -ProfilePath $pkg.ProfilePath `
            -SyntheticCapturesForTesting `
            -AllowElevatedForTesting `
            -AllowNonReferenceHostForTesting `
            -TestFaultStage 'OutOfOrderStages'
    } 'The JSON is not valid with the schema|ordered by nondecreasing UTC' 'out-of-order stages fail closed'

    # 8. Hostile: Missing lifecycle stage (7 instead of 8)
    $outMissingStage = Join-Path $temp 'evidence-out-missing-stage'
    Assert-Throws {
        & (Join-Path $PSScriptRoot 'Invoke-V02LiveRendererCapture.ps1') `
            -OutputDirectory $outMissingStage `
            -PackageRoot $pkg.PackageRoot `
            -ArchivePath $pkg.ArchivePath `
            -IdentityReceiptPath $pkg.ReceiptPath `
            -RepositoryRoot $repo.Root `
            -ProfilePath $pkg.ProfilePath `
            -SyntheticCapturesForTesting `
            -AllowElevatedForTesting `
            -AllowNonReferenceHostForTesting `
            -TestFaultStage 'MissingStage'
    } 'The JSON is not valid with the schema|requires exactly 8 lifecycle stage observations' 'missing lifecycle stage fails closed'

    # 9. Hostile: Capture timestamp outside observation window
    $outWindow = Join-Path $temp 'evidence-out-window'
    Assert-Throws {
        & (Join-Path $PSScriptRoot 'Invoke-V02LiveRendererCapture.ps1') `
            -OutputDirectory $outWindow `
            -PackageRoot $pkg.PackageRoot `
            -ArchivePath $pkg.ArchivePath `
            -IdentityReceiptPath $pkg.ReceiptPath `
            -RepositoryRoot $repo.Root `
            -ProfilePath $pkg.ProfilePath `
            -SyntheticCapturesForTesting `
            -AllowElevatedForTesting `
            -AllowNonReferenceHostForTesting `
            -TestFaultStage 'CaptureOutsideWindow'
    } 'The JSON is not valid with the schema|falls outside its renderer-observation language window' 'capture timestamp outside window fails closed'

    # 10. Hostile: Package tamper (modified App.exe in package)
    $pkgTampered = New-IsolatedTestPackage (Join-Path $temp 'pkg-tampered') $repo.Root $repo.Commit $repo.Tree
    [IO.File]::WriteAllBytes($pkgTampered.AppPath, [Text.Encoding]::UTF8.GetBytes('Tampered App Content'))
    $outTampered = Join-Path $temp 'evidence-out-tampered'
    Assert-Throws {
        & (Join-Path $PSScriptRoot 'Invoke-V02LiveRendererCapture.ps1') `
            -OutputDirectory $outTampered `
            -PackageRoot $pkgTampered.PackageRoot `
            -ArchivePath $pkgTampered.ArchivePath `
            -IdentityReceiptPath $pkgTampered.ReceiptPath `
            -RepositoryRoot $repo.Root `
            -ProfilePath $pkgTampered.ProfilePath `
            -SyntheticCapturesForTesting `
            -AllowElevatedForTesting `
            -AllowNonReferenceHostForTesting
    } 'Manifest/package-root inventories are not exact and coherent|App/Core receipt bytes/hashes do not match|App executable in payload does not match|tamper detected' 'tampered packaged App binary fails closed'

    # 11. Hostile: Reparse point in output parent directory
    $externalTarget = Join-Path $temp 'external-target'
    New-Item -ItemType Directory -Path $externalTarget -Force | Out-Null
    $junctionDir = Join-Path $temp 'junction-parent'
    New-Item -ItemType Junction -Path $junctionDir -Target $externalTarget | Out-Null
    try {
        $outJunction = Join-Path $junctionDir 'evidence'
        Assert-Throws {
            & (Join-Path $PSScriptRoot 'Invoke-V02LiveRendererCapture.ps1') `
                -OutputDirectory $outJunction `
                -PackageRoot $pkg.PackageRoot `
                -ArchivePath $pkg.ArchivePath `
                -IdentityReceiptPath $pkg.ReceiptPath `
                -RepositoryRoot $repo.Root `
                -ProfilePath $pkg.ProfilePath `
                -SyntheticCapturesForTesting `
                -AllowElevatedForTesting `
                -AllowNonReferenceHostForTesting
        } 'reparse' 'reparse junction output path fails closed'
    } finally {
        if (Test-Path -LiteralPath $junctionDir) {
            [IO.Directory]::Delete($junctionDir, $false)
        }
    }

    # 12. Hostile: Injected failure before commit
    $outPreCommit = Join-Path $temp 'evidence-out-pre-commit'
    Assert-Throws {
        & (Join-Path $PSScriptRoot 'Invoke-V02LiveRendererCapture.ps1') `
            -OutputDirectory $outPreCommit `
            -PackageRoot $pkg.PackageRoot `
            -ArchivePath $pkg.ArchivePath `
            -IdentityReceiptPath $pkg.ReceiptPath `
            -RepositoryRoot $repo.Root `
            -ProfilePath $pkg.ProfilePath `
            -SyntheticCapturesForTesting `
            -AllowElevatedForTesting `
            -AllowNonReferenceHostForTesting `
            -TestFaultStage 'PreCommit'
    } 'Injected failure before commit' 'pre-commit failure cleans up staging'

    if (Test-Path -LiteralPath $outPreCommit) {
        throw 'Pre-commit failure left output directory behind.'
    }

    [pscustomobject]@{
        EvidenceClassification = 'SyntheticVerifierSelftest'
        PositiveCases = $script:PositiveCases
        NegativeCases = $script:NegativeCases
        TotalCases = ($script:PositiveCases + $script:NegativeCases)
        BindingValidation = 'PASS'
        FinalHumanGo = 'NOT_OBSERVED'
        ActualHerdrRuntime = 'NOT_OBSERVED'
        Release = 'NOT_OBSERVED'
        CreditGranted = $false
    }
} finally {
    if (Test-Path -LiteralPath $temp) {
        Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue
    }
}
