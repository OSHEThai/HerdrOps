#requires -Version 5.1

[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'Test-V02ReleaseGate.ps1')

$script:Failures = New-Object System.Collections.Generic.List[string]

function Write-V02ReleaseGateFixtureJson {
    param([Parameter(Mandatory = $true)][string]$Path, [Parameter(Mandatory = $true)]$Value)

    $parent = [IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($Path))
    if (-not [IO.Directory]::Exists($parent)) { [IO.Directory]::CreateDirectory($parent) | Out-Null }
    $utf8 = New-Object Text.UTF8Encoding($false)
    [IO.File]::WriteAllText($Path, (($Value | ConvertTo-Json -Depth 100) + "`n"), $utf8)
}

function New-V02ReleaseGateFixtureObject {
    param([Parameter(Mandatory = $true)]$Value)

    return (($Value | ConvertTo-Json -Depth 100) | ConvertFrom-Json)
}

function Get-V02ReleaseGateFixtureSha256 {
    param([Parameter(Mandatory = $true)][string]$Path)

    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToUpperInvariant()
}

function New-V02ReleaseGateFixtureFile {
    param([Parameter(Mandatory = $true)][string]$Path, [Parameter(Mandatory = $true)][string]$Content)

    $parent = [IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($Path))
    if (-not [IO.Directory]::Exists($parent)) { [IO.Directory]::CreateDirectory($parent) | Out-Null }
    [IO.File]::WriteAllText($Path, $Content, (New-Object Text.UTF8Encoding($false)))
    return Get-V02ReleaseGateFixtureSha256 $Path
}

function Initialize-V02ReleaseGateFixtureRepository {
    param([Parameter(Mandatory = $true)][string]$Root)

    $profilePath = Join-Path $Root 'tools\packaging\v0.2\package-identity-profile.json'
    New-V02ReleaseGateFixtureFile -Path $profilePath -Content '{"fixture":true}' | Out-Null
    & git -C $Root init --quiet
    if ($LASTEXITCODE -ne 0) { throw 'Fixture git init failed.' }
    & git -C $Root -c user.name=HerdrOps-ReleaseGateTest -c user.email=release-gate-test@example.invalid add --all
    if ($LASTEXITCODE -ne 0) { throw 'Fixture git add failed.' }
    & git -C $Root -c user.name=HerdrOps-ReleaseGateTest -c user.email=release-gate-test@example.invalid commit --quiet -m 'fixture'
    if ($LASTEXITCODE -ne 0) { throw 'Fixture git commit failed.' }
    $commit = (& git -C $Root rev-parse HEAD).Trim()
    $tree = (& git -C $Root show -s --format=%T HEAD).Trim()
    return [pscustomobject][ordered]@{
        Root = [IO.Path]::GetFullPath($Root)
        ProfilePath = $profilePath
        Commit = $commit
        Tree = $tree
    }
}

function New-V02ReleaseGateMatrixFixture {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)]$Package,
        [Parameter(Mandatory = $true)][string]$SourceCommit,
        [Parameter(Mandatory = $true)][string]$SourceTree,
        [Parameter(Mandatory = $true)][string]$ThaiDirectory,
        [Parameter(Mandatory = $true)][string]$EnglishDirectory
    )

    $allRuns = @()
    foreach ($language in @('Thai', 'English')) {
        $root = if ($language -ceq 'Thai') { $ThaiDirectory } else { $EnglishDirectory }
        $captureRoot = Join-Path $root 'captures'
        New-Item -ItemType Directory -Path $captureRoot -Force | Out-Null
        $captures = @(1..8 | ForEach-Object { [pscustomobject][ordered]@{ Name = "capture-$($_)" } })
        $allRuns += [pscustomobject][ordered]@{
            Language = $language
            Culture = if ($language -ceq 'Thai') { 'th-TH' } else { 'en-US' }
            EvidenceDirectory = [IO.Path]::GetFullPath($root)
            CaptureRoot = [IO.Path]::GetFullPath($captureRoot)
            GateReportSha256 = ('1' * 64)
            AppRuntimeReportSha256 = ('2' * 64)
            CoreRuntimeReportSha256 = ('3' * 64)
            ProgressHistorySha256 = ('4' * 64)
            ProgressHistoryLastEntrySha256 = ('5' * 64)
            PackageIdentityReceiptSha256 = $Package.ReceiptSha256
            SourceCommit = $SourceCommit
            SourceTree = $SourceTree
            ProfileId = $script:V02ReleaseGateReferenceHostProfileId
            ProfileSha256 = $script:V02ReleaseGateReferenceHostProfileSha256
            ReferenceHostSchemaSha256 = $script:V02ReleaseGateReferenceHostSchemaSha256
            HerdrReleaseId = $script:V02ReleaseGateHerdrReleaseId
            HerdrExecutableSha256 = $script:V02ReleaseGateHerdrExecutableSha256
            AppExecutableSha256 = $Package.AppSha256
            CoreExecutableSha256 = $Package.CoreSha256
            BundledSchemaSha256 = ('6' * 64)
            HerdrProtocol = 19
            RendererPolicyId = $script:V02ReleaseGateRendererPolicy
            WpfProcessRenderMode = $script:V02ReleaseGateRendererMode
            CaptureCount = 8
            Captures = $captures
        }
    }
    $payload = New-V02ReleaseGateFixtureObject ([pscustomobject][ordered]@{
            GeneratedUnixTimeMilliseconds = [int64]1
            IndependentHumanReview = 'NOT_OBSERVED'
            ReleaseCredit = $false
            Binding = [pscustomobject][ordered]@{
                SourceCommit = $SourceCommit
                SourceTree = $SourceTree
                ProfileId = $script:V02ReleaseGateReferenceHostProfileId
                ProfileSha256 = $script:V02ReleaseGateReferenceHostProfileSha256
                ReferenceHostSchemaSha256 = $script:V02ReleaseGateReferenceHostSchemaSha256
                PackageIdentityReceiptSha256 = $Package.ReceiptSha256
                HerdrReleaseId = $script:V02ReleaseGateHerdrReleaseId
                HerdrExecutableSha256 = $script:V02ReleaseGateHerdrExecutableSha256
                AppExecutableSha256 = $Package.AppSha256
                CoreExecutableSha256 = $Package.CoreSha256
                BundledSchemaSha256 = ('6' * 64)
                HerdrProtocol = 19
            }
            Runs = $allRuns
        })
    $payloadJcs = ConvertTo-V02Jcs $payload
    $payloadSha = Get-V02Sha256Hex -Bytes ([Text.UTF8Encoding]::new($false).GetBytes($payloadJcs))
    $manifest = New-V02ReleaseGateFixtureObject ([pscustomobject][ordered]@{
            EvidenceClassification = 'RuntimeMatrixCandidate'
            IndependentHumanReview = 'NOT_OBSERVED'
            ReleaseCredit = $false
            ManifestFormatVersion = 1
            ManifestHashScope = $script:V02ReleaseGateMatrixHashScope
            ManifestPayloadSha256 = $payloadSha
            Payload = $payload
        })
    Write-V02ReleaseGateFixtureJson -Path $Path -Value $manifest
    return $manifest
}

function New-V02ReleaseGateEvidenceReceipt {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][ValidateSet('Contract', 'Synthetic')][string]$Class,
        [Parameter(Mandatory = $true)][string]$SourceCommit,
        [Parameter(Mandatory = $true)][string]$SourceTree,
        [Parameter(Mandatory = $true)][string]$ArtifactDirectory
    )

    $artifact = Join-Path $ArtifactDirectory "$($Class.ToLowerInvariant())-proof.txt"
    $hash = New-V02ReleaseGateFixtureFile -Path $artifact -Content "$Class fixture proof`n"
    $receipt = [pscustomobject][ordered]@{
        SchemaVersion = 1
        EvidenceClass = $Class
        Result = 'PASS'
        SourceCommit = $SourceCommit
        SourceTree = $SourceTree
        RuntimeObserved = $false
        ActualHerdrUsed = $false
        ReleaseCredit = $false
        Checks = @([pscustomobject][ordered]@{ Name = "$Class-fixture"; Result = 'PASS'; Path = [IO.Path]::GetFileName($artifact); Sha256 = $hash })
    }
    Write-V02ReleaseGateFixtureJson -Path $Path -Value $receipt
}

function New-V02ReleaseGateGitHubSnapshot {
    param([Parameter(Mandatory = $true)][string]$Path)

    $snapshot = [pscustomobject][ordered]@{
        schemaVersion = 1
        repository = 'OSHEThai/HerdrOps'
        milestones = @([pscustomobject][ordered]@{ number = 2; title = 'v0.2.0'; state = 'closed' })
        issues = @(
            [pscustomobject][ordered]@{ number = 6; title = '[v0.2.0] Discover and validate the installed Herdr protocol schema'; state = 'closed'; milestone = [pscustomobject][ordered]@{ number = 2; title = 'v0.2.0' } },
            [pscustomobject][ordered]@{ number = 7; title = '[v0.2.0] Implement Herdr Named Pipe snapshot, subscription, and reconciliation'; state = 'closed'; milestone = [pscustomobject][ordered]@{ number = 2; title = 'v0.2.0' } },
            [pscustomobject][ordered]@{ number = 8; title = '[v0.2.0] Add SQLite WAL state storage and Core-to-App IPC'; state = 'closed'; milestone = [pscustomobject][ordered]@{ number = 2; title = 'v0.2.0' } },
            [pscustomobject][ordered]@{ number = 9; title = '[v0.2.0] Connect Overview, Live Organization, and Agent Detail to live state'; state = 'closed'; milestone = [pscustomobject][ordered]@{ number = 2; title = 'v0.2.0' } },
            [pscustomobject][ordered]@{ number = 10; title = '[v0.2.0] Connect live widgets and complete runtime acceptance'; state = 'closed'; milestone = [pscustomobject][ordered]@{ number = 2; title = 'v0.2.0' } },
            [pscustomobject][ordered]@{ number = 11; title = '[v0.2.0] Release readiness tracker'; state = 'closed'; milestone = [pscustomobject][ordered]@{ number = 2; title = 'v0.2.0' } },
            [pscustomobject][ordered]@{ number = 54; title = '[v0.2.0] Extract and validate bundled Herdr JSON Schema successor'; state = 'closed'; milestone = [pscustomobject][ordered]@{ number = 2; title = 'v0.2.0' } },
            [pscustomobject][ordered]@{ number = 63; title = '[v0.2.0] Complete Thai and English separation for live surfaces'; state = 'closed'; milestone = [pscustomobject][ordered]@{ number = 2; title = 'v0.2.0' } },
            [pscustomobject][ordered]@{ number = 149; title = 'REC-ALL v2 package and renderer authority'; state = 'closed'; milestone = $null }
        )
    }
    Write-V02ReleaseGateFixtureJson -Path $Path -Value $snapshot
}

function New-V02ReleaseGateHumanReview {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)]$Package,
        [Parameter(Mandatory = $true)]$Renderer,
        [Parameter(Mandatory = $true)]$Matrix,
        [Parameter(Mandatory = $true)][string]$GitHubSnapshotSha256,
        [Parameter(Mandatory = $true)][string]$SourceCommit,
        [Parameter(Mandatory = $true)][string]$SourceTree,
        [Parameter(Mandatory = $true)][string]$ArtifactDirectory
    )

    $reviewArtifact = Join-Path $ArtifactDirectory 'human-review-evidence.txt'
    $reviewArtifactSha = New-V02ReleaseGateFixtureFile -Path $reviewArtifact -Content 'Independent role-distinct review fixture evidence.'
    $checks = @($script:V02ReleaseGateHumanCheckIds | ForEach-Object {
            [pscustomobject][ordered]@{ Id = $_; Status = 'PASS'; Path = [IO.Path]::GetFileName($reviewArtifact); Sha256 = $reviewArtifactSha }
        })
    $review = [pscustomobject][ordered]@{
        SchemaVersion = 1
        EvidenceClass = 'Human'
        Result = 'PASS'
        Decision = 'GO'
        Reviewer = [pscustomobject][ordered]@{
            Identity = 'reviewer@example.invalid'
            Role = 'IndependentReleaseReviewer'
            BuilderIdentity = 'builder@example.invalid'
            RuntimeOperatorIdentity = 'operator@example.invalid'
            RoleDistinct = $true
            ReviewedUtc = '2026-08-22T14:00:00.0000000+00:00'
        }
        Candidate = [pscustomobject][ordered]@{
            SourceCommit = $SourceCommit
            SourceTree = $SourceTree
            PackageReceiptSha256 = $Package.ReceiptSha256
            PackageReceiptFileSha256 = $Package.ReceiptFileSha256
            PackageArchiveSha256 = $Package.ArchiveSha256
            PackageAppSha256 = $Package.AppSha256
            PackageCoreSha256 = $Package.CoreSha256
            RendererManifestSha256 = $Renderer.ManifestSha256
            RuntimeMatrixManifestSha256 = $Matrix.ManifestFileSha256
            GitHubSnapshotSha256 = $GitHubSnapshotSha256
        }
        Checks = $checks
        OpenFindings = @()
        ActualHerdrRuntime = 'NOT_OBSERVED'
        ReleaseCredit = $false
    }
    Write-V02ReleaseGateFixtureJson -Path $Path -Value $review
}

function Invoke-V02ReleaseGateFixture {
    param(
        [Parameter(Mandatory = $true)]$Fixture,
        [string]$OutputPath
    )

    $packageValidator = {
        param($Context)
        return $Fixture.PackageResult
    }
    $rendererValidator = {
        param($Context)
        return $Fixture.RendererResult
    }
    $matrixValidator = {
        param($Context)
        return $Fixture.MatrixManifest
    }
    $arguments = @{
        ExpectedSourceCommit = $Fixture.Repository.Commit
        ExpectedSourceTree = $Fixture.Repository.Tree
        PackageIdentityPath = $Fixture.Package.IdentityPath
        PackageArchivePath = $Fixture.Package.ArchivePath
        ExtractedPackageRoot = $Fixture.Package.PackageRoot
        PackageProfilePath = $Fixture.Repository.ProfilePath
        RendererManifestPath = $Fixture.RendererManifestPath
        ThaiEvidenceDirectory = $Fixture.ThaiDirectory
        EnglishEvidenceDirectory = $Fixture.EnglishDirectory
        RuntimeMatrixManifestPath = $Fixture.MatrixPath
        ContractEvidencePath = $Fixture.ContractPath
        SyntheticEvidencePath = $Fixture.SyntheticPath
        HumanReviewPath = $Fixture.HumanReviewPath
        GitHubSnapshotPath = $Fixture.GitHubPath
        RepositoryRoot = $Fixture.Repository.Root
        OutputPath = $OutputPath
        PackageValidator = $packageValidator
        RendererValidator = $rendererValidator
        RuntimeMatrixValidator = $matrixValidator
    }
    return Invoke-V02ReleaseGate @arguments
}

function New-V02ReleaseGateFixture {
    $root = Join-Path ([IO.Path]::GetTempPath()) ('herdrops-v02-release-gate-' + [Guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $root -Force | Out-Null
    $repo = Initialize-V02ReleaseGateFixtureRepository -Root (Join-Path $root 'repo')
    $artifactDirectory = Join-Path $root 'evidence'
    New-Item -ItemType Directory -Path $artifactDirectory -Force | Out-Null
    $packageRoot = Join-Path $artifactDirectory 'package'
    New-Item -ItemType Directory -Path $packageRoot -Force | Out-Null
    $identityPath = Join-Path $artifactDirectory 'package-identity.json'
    $archivePath = Join-Path $artifactDirectory 'HerdrOps-0.2.0-win-x64.zip'
    $manifestPath = Join-Path $packageRoot 'package-manifest.json'
    $appPath = Join-Path $packageRoot 'HerdrOps.App.exe'
    $corePath = Join-Path $packageRoot 'HerdrOps.Core.exe'
    New-V02ReleaseGateFixtureFile -Path $identityPath -Content '{"fixture":"identity"}' | Out-Null
    New-V02ReleaseGateFixtureFile -Path $archivePath -Content 'fixture archive bytes' | Out-Null
    New-V02ReleaseGateFixtureFile -Path $manifestPath -Content '{"fixture":"manifest"}' | Out-Null
    New-V02ReleaseGateFixtureFile -Path $appPath -Content 'fixture app bytes' | Out-Null
    New-V02ReleaseGateFixtureFile -Path $corePath -Content 'fixture core bytes' | Out-Null
    $packageReceiptSha = 'D' * 64
    $packageResult = [pscustomobject][ordered]@{
        EvidenceClass = 'Static/PackagedCompatibilityPreparation'
        Issue = 149
        ProfileId = $script:V02ReleaseGatePackageProfileId
        ReceiptSha256 = $packageReceiptSha
        SourceCommit = $repo.Commit
        SourceTree = $repo.Tree
        PreparationProfileFileSha256 = Get-V02ReleaseGateFixtureSha256 $repo.ProfilePath
        PreparationProfileCanonicalSha256 = ('C' * 64)
        ArchiveSha256 = Get-V02ReleaseGateFixtureSha256 $archivePath
        AppSha256 = Get-V02ReleaseGateFixtureSha256 $appPath
        CoreSha256 = Get-V02ReleaseGateFixtureSha256 $corePath
        ReferenceHostProfileSha256 = $script:V02ReleaseGateReferenceHostProfileSha256
        RendererPolicySha256 = $script:V02ReleaseGateRendererPolicySha256
        Runtime = 'NOT OBSERVED'
        Release = 'NOT CLAIMED'
    }
    $rendererManifestPath = Join-Path $artifactDirectory 'renderer-compatibility-manifest.json'
    $rendererResult = [pscustomobject][ordered]@{
        EvidenceClassification = 'PackagedCompatibilityCandidate'
        ManifestVersion = 1
        StructuralValidation = 'PASS'
        BindingValidation = 'PASS'
        GovernanceProfileConsistency = 'PASS'
        FinalHumanGoAuthority = 'NOT_OBSERVED'
        OwnerNumericLimits = 'APPROVED'
        HumanReview = 'NOT_OBSERVED'
        ActualHerdrRuntime = 'NOT_OBSERVED'
        Release = 'NOT_OBSERVED'
        CreditGranted = $false
        PackagedCompatibilityReadyForIssue149Closure = $false
    }
    $rendererManifest = New-V02ReleaseGateFixtureObject ([pscustomobject][ordered]@{
            '$id' = 'https://herdrops.local/schema/v0.2/renderer-compatibility-manifest.schema.json'
            manifestVersion = 1
            evidenceClassification = 'PackagedCompatibilityCandidate'
            issue = 149
            governance = [pscustomobject][ordered]@{
                decisionId = $script:V02ReleaseGateDecisionId
                approvalReference = $script:V02ReleaseGateDecisionReference
                originalApprovedUtc = '2026-08-22T13:18:21.2468994Z'
                correctedUtc = '2026-08-22T13:23:04.5923226Z'
                decisionPayloadSha256 = $script:V02ReleaseGateDecisionPayloadSha256
                supersedesDecisionId = 'herdrops-rec-all-v1'
                supersedesPayloadSha256 = 'DD8EB4D4BC896BE6A4765D409C5E34A16C4DBFB3D70F437EC915A50DF2FC1B1E'
            }
            candidate = [pscustomobject][ordered]@{
                source = [pscustomobject][ordered]@{ commitSha = $repo.Commit; treeSha = $repo.Tree }
                profile = [pscustomobject][ordered]@{ id = $packageResult.ProfileId; relativePath = 'tools/packaging/v0.2/package-identity-profile.json'; bytes = 1; fileSha256 = $packageResult.PreparationProfileFileSha256; canonicalSha256 = $packageResult.PreparationProfileCanonicalSha256 }
                receipt = [pscustomobject][ordered]@{ relativePath = 'package-identity.json'; bytes = 1; fileSha256 = Get-V02ReleaseGateFixtureSha256 $identityPath; canonicalSha256 = $packageResult.ReceiptSha256 }
                archive = [pscustomobject][ordered]@{ relativePath = 'HerdrOps-0.2.0-win-x64.zip'; fileName = 'HerdrOps-0.2.0-win-x64.zip'; bytes = 1; sha256 = $packageResult.ArchiveSha256 }
                packageRootRelativePath = 'package'
                components = [pscustomobject][ordered]@{
                    app = [pscustomobject][ordered]@{ relativePath = 'HerdrOps.App.exe'; bytes = 1; sha256 = $packageResult.AppSha256 }
                    core = [pscustomobject][ordered]@{ relativePath = 'HerdrOps.Core.exe'; bytes = 1; sha256 = $packageResult.CoreSha256 }
                }
                referenceHost = [pscustomobject][ordered]@{ profileId = $script:V02ReleaseGateReferenceHostProfileId; profileSha256 = $script:V02ReleaseGateReferenceHostProfileSha256 }
                renderer = [pscustomobject][ordered]@{ policy = $script:V02ReleaseGateRendererPolicy; wpfProcessRenderMode = $script:V02ReleaseGateRendererMode }
            }
            environment = [pscustomobject]@{}
            rendererEvidence = [pscustomobject]@{}
            captures = @()
            references = @()
            comparison = [pscustomobject]@{}
            matrices = [pscustomobject]@{}
            performanceProtocol = [pscustomobject]@{}
            review = [pscustomobject][ordered]@{ decision = 'NOT_OBSERVED' }
            evidenceBoundary = [pscustomobject][ordered]@{ packagedCompatibility = 'CANDIDATE'; humanReview = 'NOT_OBSERVED'; actualHerdrRuntime = 'NOT_OBSERVED'; release = 'NOT_OBSERVED'; creditGranted = $false }
        })
    Write-V02ReleaseGateFixtureJson -Path $rendererManifestPath -Value $rendererManifest
    $thaiDirectory = Join-Path $artifactDirectory 'Thai'
    $englishDirectory = Join-Path $artifactDirectory 'English'
    $matrixPath = Join-Path $artifactDirectory 'runtime-matrix-candidate.json'
    $packageForMatrix = [pscustomobject][ordered]@{
        ReceiptSha256 = $packageResult.ReceiptSha256
        AppSha256 = $packageResult.AppSha256
        CoreSha256 = $packageResult.CoreSha256
    }
    $matrixManifest = New-V02ReleaseGateMatrixFixture -Path $matrixPath -Package $packageForMatrix `
        -SourceCommit $repo.Commit -SourceTree $repo.Tree -ThaiDirectory $thaiDirectory -EnglishDirectory $englishDirectory
    $package = [pscustomobject][ordered]@{
        IdentityPath = $identityPath
        ReceiptFileSha256 = Get-V02ReleaseGateFixtureSha256 $identityPath
        ReceiptSha256 = $packageResult.ReceiptSha256
        ArchivePath = $archivePath
        ArchiveSha256 = $packageResult.ArchiveSha256
        PackageRoot = $packageRoot
        ManifestPath = $manifestPath
        ManifestSha256 = Get-V02ReleaseGateFixtureSha256 $manifestPath
        AppPath = $appPath
        AppSha256 = $packageResult.AppSha256
        CorePath = $corePath
        CoreSha256 = $packageResult.CoreSha256
        ProfilePath = $repo.ProfilePath
        ProfileFileSha256 = $packageResult.PreparationProfileFileSha256
        ProfileCanonicalSha256 = $packageResult.PreparationProfileCanonicalSha256
        ProfileId = $packageResult.ProfileId
        ReferenceHostProfileSha256 = $packageResult.ReferenceHostProfileSha256
        RendererPolicySha256 = $packageResult.RendererPolicySha256
        SourceCommit = $repo.Commit
        SourceTree = $repo.Tree
        EvidenceClass = $packageResult.EvidenceClass
    }
    $renderer = [pscustomobject][ordered]@{ ManifestSha256 = Get-V02ReleaseGateFixtureSha256 $rendererManifestPath; ManifestPath = $rendererManifestPath; Result = $rendererResult }
    New-V02ReleaseGateEvidenceReceipt -Path (Join-Path $artifactDirectory 'contract.json') -Class Contract -SourceCommit $repo.Commit -SourceTree $repo.Tree -ArtifactDirectory $artifactDirectory
    New-V02ReleaseGateEvidenceReceipt -Path (Join-Path $artifactDirectory 'synthetic.json') -Class Synthetic -SourceCommit $repo.Commit -SourceTree $repo.Tree -ArtifactDirectory $artifactDirectory
    $githubPath = Join-Path $artifactDirectory 'github-snapshot.json'
    New-V02ReleaseGateGitHubSnapshot -Path $githubPath
    $matrix = [pscustomobject][ordered]@{ ManifestPath = $matrixPath; ManifestFileSha256 = Get-V02ReleaseGateFixtureSha256 $matrixPath; ManifestPayloadSha256 = $matrixManifest.ManifestPayloadSha256; Candidate = $matrixManifest }
    $humanReviewPath = Join-Path $artifactDirectory 'human-review.json'
    New-V02ReleaseGateHumanReview -Path $humanReviewPath -Package $package -Renderer $renderer -Matrix $matrix `
        -GitHubSnapshotSha256 (Get-V02ReleaseGateFixtureSha256 $githubPath) -SourceCommit $repo.Commit -SourceTree $repo.Tree -ArtifactDirectory $artifactDirectory
    return [pscustomobject][ordered]@{
        Root = $root
        Repository = $repo
        Package = $package
        PackageResult = $packageResult
        Renderer = $renderer
        RendererResult = $rendererResult
        RendererManifestPath = $rendererManifestPath
        ThaiDirectory = $thaiDirectory
        EnglishDirectory = $englishDirectory
        MatrixPath = $matrixPath
        MatrixManifest = $matrixManifest
        ContractPath = Join-Path $artifactDirectory 'contract.json'
        SyntheticPath = Join-Path $artifactDirectory 'synthetic.json'
        GitHubPath = $githubPath
        HumanReviewPath = $humanReviewPath
    }
}

function Invoke-V02ReleaseGateTestCase {
    param([Parameter(Mandatory = $true)][string]$Name, [Parameter(Mandatory = $true)][scriptblock]$Body)

    try {
        & $Body
        Write-Host "PASS: $Name"
    }
    catch {
        [void]$script:Failures.Add("$Name`: $($_.Exception.Message)")
        Write-Host "FAIL: $Name" -ForegroundColor Red
    }
}

$fixture = $null
try {
    $fixture = New-V02ReleaseGateFixture
    Invoke-V02ReleaseGateTestCase 'complete fixture passes with separate evidence classes' {
        $outputDirectory = Join-Path $fixture.Root 'output-pass'
        $result = Invoke-V02ReleaseGateFixture -Fixture $fixture -OutputPath $outputDirectory
        if ($result.Result -cne 'PASS' -or -not [bool]$result.ReleaseReady) { throw 'Complete fixture did not report PASS/ReleaseReady.' }
        foreach ($class in @('Static', 'Contract', 'Synthetic', 'Runtime', 'Human', 'Release')) {
            $expectedStatus = if ($class -ceq 'Runtime') { 'CANDIDATE' } else { 'PASS' }
            if ($result.EvidenceClasses.$class.Status -cne $expectedStatus) { throw "Evidence class $class did not report $expectedStatus." }
        }
        if ($result.EvidenceClasses.Runtime.Classification -cne 'RuntimeMatrixCandidate') { throw 'Runtime classification was inflated.' }
        if (-not (Test-Path -LiteralPath (Join-Path $outputDirectory 'v0.2-release-gate.json') -PathType Leaf)) { throw 'JSON report was not written.' }
        if (-not (Test-Path -LiteralPath (Join-Path $outputDirectory 'gate-report.txt') -PathType Leaf)) { throw 'Text report was not written.' }
    }

    Invoke-V02ReleaseGateTestCase 'open required issue fails closed' {
        $snapshot = Get-Content -LiteralPath $fixture.GitHubPath -Raw | ConvertFrom-Json
        ($snapshot.issues | Where-Object number -eq 7).state = 'open'
        Write-V02ReleaseGateFixtureJson -Path $fixture.GitHubPath -Value $snapshot
        try {
            $null = Invoke-V02ReleaseGateFixture -Fixture $fixture
            throw 'Expected open issue rejection was not observed.'
        }
        catch {
            if ($_.Exception.Message -notmatch 'issue #7 state|open v0\.2\.0') { throw }
        }
        ($snapshot.issues | Where-Object number -eq 7).state = 'closed'
        New-V02ReleaseGateGitHubSnapshot -Path $fixture.GitHubPath
    }

    Invoke-V02ReleaseGateTestCase 'matrix candidate credit inflation fails closed' {
        $candidate = Get-Content -LiteralPath $fixture.MatrixPath -Raw | ConvertFrom-Json
        $candidate.ReleaseCredit = $true
        Write-V02ReleaseGateFixtureJson -Path $fixture.MatrixPath -Value $candidate
        try {
            $null = Invoke-V02ReleaseGateFixture -Fixture $fixture
            throw 'Expected matrix credit rejection was not observed.'
        }
        catch {
            if ($_.Exception.Message -notmatch 'Release credit') { throw }
        }
        New-V02ReleaseGateMatrixFixture -Path $fixture.MatrixPath -Package ([pscustomobject]@{ ReceiptSha256 = $fixture.PackageResult.ReceiptSha256; AppSha256 = $fixture.PackageResult.AppSha256; CoreSha256 = $fixture.PackageResult.CoreSha256 }) `
            -SourceCommit $fixture.Repository.Commit -SourceTree $fixture.Repository.Tree -ThaiDirectory $fixture.ThaiDirectory -EnglishDirectory $fixture.EnglishDirectory | Out-Null
    }

    Invoke-V02ReleaseGateTestCase 'role overlap fails closed' {
        $review = Get-Content -LiteralPath $fixture.HumanReviewPath -Raw | ConvertFrom-Json
        $review.Reviewer.RuntimeOperatorIdentity = $review.Reviewer.Identity
        Write-V02ReleaseGateFixtureJson -Path $fixture.HumanReviewPath -Value $review
        try {
            $null = Invoke-V02ReleaseGateFixture -Fixture $fixture
            throw 'Expected role-overlap rejection was not observed.'
        }
        catch {
            if ($_.Exception.Message -notmatch 'identities') { throw }
        }
        New-V02ReleaseGateHumanReview -Path $fixture.HumanReviewPath -Package $fixture.Package -Renderer $fixture.Renderer -Matrix ([pscustomobject]@{ ManifestFileSha256 = Get-V02ReleaseGateFixtureSha256 $fixture.MatrixPath }) `
            -GitHubSnapshotSha256 (Get-V02ReleaseGateFixtureSha256 $fixture.GitHubPath) -SourceCommit $fixture.Repository.Commit -SourceTree $fixture.Repository.Tree -ArtifactDirectory (Join-Path $fixture.Root 'evidence')
    }

    Invoke-V02ReleaseGateTestCase 'package source drift fails closed' {
        $original = $fixture.PackageResult.SourceCommit
        $fixture.PackageResult.SourceCommit = ('e' * 40)
        try {
            $null = Invoke-V02ReleaseGateFixture -Fixture $fixture
            throw 'Expected package source drift rejection was not observed.'
        }
        catch {
            if ($_.Exception.Message -notmatch 'source commit') { throw }
        }
        $fixture.PackageResult.SourceCommit = $original
    }
}
finally {
    if ($null -ne $fixture -and (Test-Path -LiteralPath $fixture.Root)) {
        Remove-Item -LiteralPath $fixture.Root -Recurse -Force
    }
}

if ($script:Failures.Count -ne 0) {
    $script:Failures | ForEach-Object { Write-Host $_ -ForegroundColor Red }
    exit 1
}

Write-Host 'All v0.2 release-gate fixture tests passed.' -ForegroundColor Green
