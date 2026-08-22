#requires -Version 5.1

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'Test-V02ReleaseGate.ps1')

$script:Failures = New-Object System.Collections.Generic.List[string]

function Invoke-V02ReleaseGateTestCase {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][scriptblock]$Body
    )

    try {
        & $Body
        Write-Host "PASS: $Name"
    }
    catch {
        [void]$script:Failures.Add("$Name`: $($_.Exception.Message)")
        Write-Host "FAIL: $Name" -ForegroundColor Red
    }
}

function Assert-V02ReleaseGateTestThrows {
    param(
        [Parameter(Mandatory = $true)][scriptblock]$Body,
        [string]$Pattern
    )

    $threw = $false
    try { & $Body }
    catch {
        $threw = $true
        if (-not [string]::IsNullOrWhiteSpace($Pattern) -and $_.Exception.Message -notmatch $Pattern) {
            throw "Expected error matching '$Pattern'; observed '$($_.Exception.Message)'."
        }
    }
    if (-not $threw) { throw 'Expected a fail-closed rejection.' }
}

function New-V02ReleaseGateTestDirectory {
    param([Parameter(Mandatory = $true)][string]$Path)
    New-Item -ItemType Directory -Path $Path -Force | Out-Null
}

function Write-V02ReleaseGateTestBytes {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][byte[]]$Bytes
    )
    $parent = [IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($Path))
    if (-not [IO.Directory]::Exists($parent)) { [IO.Directory]::CreateDirectory($parent) | Out-Null }
    [IO.File]::WriteAllBytes($Path, $Bytes)
    return Get-V02ReleaseGateFileSha256 -Path $Path
}

function Write-V02ReleaseGateTestText {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Text
    )
    return Write-V02ReleaseGateTestBytes -Path $Path -Bytes ([Text.UTF8Encoding]::new($false).GetBytes($Text))
}

function Write-V02ReleaseGateTestJson {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)]$Value
    )
    return Write-V02ReleaseGateTestText -Path $Path -Text ($Value | ConvertTo-Json -Depth 100)
}

function Get-V02ReleaseGateTestRepositoryIdentity {
    param([Parameter(Mandatory = $true)][string]$RepositoryRoot)
    return Get-V02ReleaseGateGitIdentity -RepositoryRoot $RepositoryRoot
}

function New-V02ReleaseGateTestCleanRepository {
    $root = Join-Path ([IO.Path]::GetTempPath()) ('herdrops-v02-gate-clean-' + [Guid]::NewGuid().ToString('N'))
    New-V02ReleaseGateTestDirectory -Path $root
    New-V02ReleaseGateTestDirectory -Path (Join-Path $root 'Plan')
    New-V02ReleaseGateTestDirectory -Path (Join-Path $root 'tools\packaging\v0.2')
    Copy-Item -LiteralPath (Join-Path $script:GateRepositoryRoot 'Plan\DECISIONS.md') -Destination (Join-Path $root 'Plan\DECISIONS.md')
    Copy-Item -LiteralPath (Join-Path $script:GateRepositoryRoot 'Plan\v0.2-release-gate-independent-receipt.json') -Destination (Join-Path $root 'Plan\v0.2-release-gate-independent-receipt.json')
    Copy-Item -LiteralPath (Join-Path $script:GateRepositoryRoot 'tools\packaging\v0.2\package-identity-profile.json') -Destination (Join-Path $root 'tools\packaging\v0.2\package-identity-profile.json')
    & git -C $root init --quiet
    & git -C $root -c user.name=HerdrOps-Gate-Test -c user.email=test@example.invalid add --all
    & git -C $root -c user.name=HerdrOps-Gate-Test -c user.email=test@example.invalid commit --quiet -m fixture
    if ($LASTEXITCODE -ne 0) { throw 'Clean authority fixture repository could not be committed.' }
    return $root
}

function New-V02ReleaseGateTestCandidateLock {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)]$Identity,
        [Parameter(Mandatory = $true)][string]$ProfileFileSha256,
        [Parameter(Mandatory = $true)][string]$ProfileCanonicalSha256,
        [Parameter(Mandatory = $true)]$Authority,
        [string]$PackageReceiptSha256 = ('1' * 64),
        [string]$PackageReceiptFileSha256 = ('2' * 64),
        [string]$PackageArchiveSha256 = ('3' * 64),
        [string]$PackageManifestSha256 = ('4' * 64),
        [string]$PackageAppSha256 = ('5' * 64),
        [string]$PackageCoreSha256 = ('6' * 64),
        [string]$RendererManifestSha256 = ('7' * 64),
        [string]$RuntimeMatrixManifestSha256 = ('8' * 64)
    )
    $lock = [pscustomobject][ordered]@{
        SchemaVersion = 1
        EvidenceClass = 'ApprovedCandidateLock'
        Result = 'APPROVED'
        Immutable = $true
        SourceCommit = $Identity.Commit
        SourceTree = $Identity.Tree
        ProfileId = $script:V02ReleaseGatePackageProfileId
        ProfileFileSha256 = $ProfileFileSha256
        ProfileCanonicalSha256 = $ProfileCanonicalSha256
        PackageReceiptSha256 = $PackageReceiptSha256
        PackageReceiptFileSha256 = $PackageReceiptFileSha256
        PackageArchiveSha256 = $PackageArchiveSha256
        PackageManifestSha256 = $PackageManifestSha256
        PackageAppSha256 = $PackageAppSha256
        PackageCoreSha256 = $PackageCoreSha256
        RendererManifestSha256 = $RendererManifestSha256
        RuntimeMatrixManifestSha256 = $RuntimeMatrixManifestSha256
        Authority = [pscustomobject][ordered]@{
            DecisionId = $Authority.DecisionId
            ApprovalReference = $Authority.ApprovalReference
            PayloadSha256 = $Authority.PayloadSha256
            Reference = $Authority.RelativeReference
            ReferenceSha256 = $Authority.FileSha256
            OwnerIdentity = $Authority.OwnerIdentity
            OwnerRole = $Authority.OwnerRole
            Authentication = $Authority.Authentication
            IndependentReceiptPath = $Authority.IndependentReceipt.RelativePath
            IndependentReceiptSha256 = $Authority.IndependentReceipt.FileSha256
            IndependentReceiptIdentity = $Authority.IndependentReceipt.ReviewerIdentity
            IndependentReceiptRole = $Authority.IndependentReceipt.ReviewerRole
            IndependentReceiptAuthentication = $Authority.IndependentReceipt.Authentication
        }
        Runtime = 'NOT_OBSERVED'
        Human = 'NOT_OBSERVED'
        Release = 'NOT_OBSERVED'
    }
    Write-V02ReleaseGateTestJson -Path $Path -Value $lock | Out-Null
    return $lock
}

function New-V02ReleaseGateTestGitHubSnapshot {
    param([Parameter(Mandatory = $true)][string]$Path)
    $milestone = [pscustomobject][ordered]@{ number = 2; title = 'v0.2.0' }
    $issues = @(
        [pscustomobject][ordered]@{ number = 6; title = 'issue 6'; state = 'closed'; milestone = $milestone }
        [pscustomobject][ordered]@{ number = 7; title = 'issue 7'; state = 'closed'; milestone = $milestone }
        [pscustomobject][ordered]@{ number = 8; title = 'issue 8'; state = 'closed'; milestone = $milestone }
        [pscustomobject][ordered]@{ number = 9; title = 'issue 9'; state = 'closed'; milestone = $milestone }
        [pscustomobject][ordered]@{ number = 10; title = 'issue 10'; state = 'closed'; milestone = $milestone }
        [pscustomobject][ordered]@{ number = 11; title = '[v0.2.0] Release readiness tracker'; state = 'closed'; milestone = $milestone }
        [pscustomobject][ordered]@{ number = 54; title = 'issue 54'; state = 'closed'; milestone = $milestone }
        [pscustomobject][ordered]@{ number = 63; title = 'issue 63'; state = 'closed'; milestone = $milestone }
        [pscustomobject][ordered]@{ number = 149; title = 'issue 149'; state = 'closed'; milestone = $null }
    )
    $snapshot = [pscustomobject][ordered]@{
        schemaVersion = 1
        repository = 'OSHEThai/HerdrOps'
        milestones = @([pscustomobject][ordered]@{ number = 2; title = 'v0.2.0'; state = 'closed' })
        issues = $issues
    }
    Write-V02ReleaseGateTestJson -Path $Path -Value $snapshot | Out-Null
    return $snapshot
}

function New-V02ReleaseGateTestHumanReview {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$EvidenceRoot,
        [Parameter(Mandatory = $true)]$Package,
        [Parameter(Mandatory = $true)]$Renderer,
        [Parameter(Mandatory = $true)]$Matrix,
        [Parameter(Mandatory = $true)][string]$GitHubPath,
        [Parameter(Mandatory = $true)][string]$GitHubSha,
        [Parameter(Mandatory = $true)]$Identity
    )
    $ids = @($script:V02ReleaseGateHumanCheckIds)
    $artifactPaths = @{}
    foreach ($id in $ids) {
        $safe = $id -replace '[^A-Za-z0-9-]', '-'
        $artifactPaths[$id] = Join-Path $EvidenceRoot "review-$safe.txt"
        Write-V02ReleaseGateTestText -Path $artifactPaths[$id] -Text "independent review evidence for $id`n" | Out-Null
    }
    $artifactPaths['package-receipt'] = $Package.IdentityPath
    $artifactPaths['renderer-compatibility'] = $Renderer.ManifestPath
    $artifactPaths['runtime-matrix-thai'] = $Matrix.ManifestPath
    $artifactPaths['runtime-matrix-english'] = $Matrix.ManifestPath
    $artifactPaths['tracker-11-readiness'] = $GitHubPath
    $checks = @($ids | ForEach-Object {
            $checkArtifactPath = $artifactPaths[$_]
            [pscustomobject][ordered]@{
                Id = $_
                Status = 'PASS'
                Path = $checkArtifactPath
                Sha256 = Get-V02ReleaseGateFileSha256 -Path $checkArtifactPath
                Binding = "HumanCheck:$_"
            }
        })
    $review = [pscustomobject][ordered]@{
        SchemaVersion = 1
        EvidenceClass = 'Human'
        Result = 'PASS'
        Decision = 'GO'
        Reviewer = [pscustomobject][ordered]@{
            Identity = '@independent-reviewer'
            Role = 'IndependentReleaseReviewer'
            BuilderIdentity = '@builder'
            RuntimeOperatorIdentity = '@runtime-operator'
            RoleDistinct = $true
            ReviewedUtc = '2026-08-22T14:00:00.0000000+00:00'
        }
        Candidate = [pscustomobject][ordered]@{
            SourceCommit = $Identity.Commit
            SourceTree = $Identity.Tree
            PackageReceiptSha256 = $Package.ReceiptSha256
            PackageReceiptFileSha256 = $Package.ReceiptFileSha256
            PackageArchiveSha256 = $Package.ArchiveSha256
            PackageAppSha256 = $Package.AppSha256
            PackageCoreSha256 = $Package.CoreSha256
            RendererManifestSha256 = $Renderer.ManifestSha256
            RuntimeMatrixManifestSha256 = $Matrix.ManifestFileSha256
            GitHubSnapshotSha256 = $GitHubSha
        }
        Checks = $checks
        OpenFindings = @()
        ActualHerdrRuntime = 'NOT_OBSERVED'
        ReleaseCredit = $false
    }
    Write-V02ReleaseGateTestJson -Path $Path -Value $review | Out-Null
    return $review
}

$script:GateRepositoryRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$script:GateIdentity = Get-V02ReleaseGateTestRepositoryIdentity -RepositoryRoot $script:GateRepositoryRoot
$script:GateProfilePath = Join-Path $script:GateRepositoryRoot 'tools\packaging\v0.2\package-identity-profile.json'
$script:GateProfileSha = Get-V02ReleaseGateFileSha256 -Path $script:GateProfilePath
$script:GateProfileDocument = Read-V02ReleaseGateJsonFile -Path $script:GateProfilePath -Context 'test package profile'
$script:GateProfileCanonical = ConvertTo-V02Jcs $script:GateProfileDocument.Value
$script:GateProfileCanonicalSha = (Get-V02Sha256Hex -Bytes ([Text.UTF8Encoding]::new($false).GetBytes($script:GateProfileCanonical))).ToUpperInvariant()
$script:TestRoot = Join-Path ([IO.Path]::GetTempPath()) ('herdrops-v02-gate-tests-' + [Guid]::NewGuid().ToString('N'))
New-V02ReleaseGateTestDirectory -Path $script:TestRoot

try {
    Invoke-V02ReleaseGateTestCase 'approved candidate lock binds exact source/profile/authority' {
        $evidenceRoot = Join-Path $script:TestRoot 'lock'
        New-V02ReleaseGateTestDirectory -Path $evidenceRoot
        $authority = Read-V02ReleaseGateAuthorityReference -RepositoryRoot $script:GateRepositoryRoot `
            -AuthorityReferencePath (Join-Path $script:GateRepositoryRoot 'Plan\DECISIONS.md')
        $lockPath = Join-Path $evidenceRoot 'candidate-lock.json'
        New-V02ReleaseGateTestCandidateLock -Path $lockPath -Identity $script:GateIdentity `
            -ProfileFileSha256 $script:GateProfileSha -ProfileCanonicalSha256 $script:GateProfileCanonicalSha -Authority $authority | Out-Null
        $lock = Read-V02ReleaseGateCandidateLock -Path $lockPath -EvidenceRoot $evidenceRoot `
            -ExpectedSourceCommit $script:GateIdentity.Commit -ExpectedSourceTree $script:GateIdentity.Tree `
            -PackageProfilePath $script:GateProfilePath -RepositoryRoot $script:GateRepositoryRoot `
            -AuthorityReferencePath (Join-Path $script:GateRepositoryRoot 'Plan\DECISIONS.md')
        if ($lock.Result -cne 'APPROVED_CANDIDATE_ONLY' -or $lock.Authentication -cne 'TRUSTED_COMMITTED_PLAN_AND_INDEPENDENT_RECEIPT') {
            throw 'Candidate lock did not remain candidate-only and owner/independent-receipt bound.'
        }
    }

    Invoke-V02ReleaseGateTestCase 'copied Plan JSON cannot self-authorize a candidate lock' {
        $evidenceRoot = Join-Path $script:TestRoot 'copied-plan-authority'
        New-V02ReleaseGateTestDirectory -Path $evidenceRoot
        $authority = Read-V02ReleaseGateAuthorityReference -RepositoryRoot $script:GateRepositoryRoot `
            -AuthorityReferencePath (Join-Path $script:GateRepositoryRoot 'Plan\DECISIONS.md')
        $lockPath = Join-Path $evidenceRoot 'candidate-lock.json'
        New-V02ReleaseGateTestCandidateLock -Path $lockPath -Identity $script:GateIdentity `
            -ProfileFileSha256 $script:GateProfileSha -ProfileCanonicalSha256 $script:GateProfileCanonicalSha -Authority $authority | Out-Null
        $copiedPlanOnly = Get-Content -LiteralPath $lockPath -Raw | ConvertFrom-Json
        foreach ($name in @('IndependentReceiptPath', 'IndependentReceiptSha256', 'IndependentReceiptIdentity', 'IndependentReceiptRole', 'IndependentReceiptAuthentication')) {
            $copiedPlanOnly.Authority.PSObject.Properties.Remove($name)
        }
        Write-V02ReleaseGateTestJson -Path $lockPath -Value $copiedPlanOnly | Out-Null
        Assert-V02ReleaseGateTestThrows {
            Read-V02ReleaseGateCandidateLock -Path $lockPath -EvidenceRoot $evidenceRoot `
                -ExpectedSourceCommit $script:GateIdentity.Commit -ExpectedSourceTree $script:GateIdentity.Tree `
                -PackageProfilePath $script:GateProfilePath -RepositoryRoot $script:GateRepositoryRoot `
                -AuthorityReferencePath (Join-Path $script:GateRepositoryRoot 'Plan\DECISIONS.md')
        } 'exactly'
    }

    Invoke-V02ReleaseGateTestCase 'forged candidate provenance fails closed' {
        $evidenceRoot = Join-Path $script:TestRoot 'forged-lock'
        New-V02ReleaseGateTestDirectory -Path $evidenceRoot
        $authority = Read-V02ReleaseGateAuthorityReference -RepositoryRoot $script:GateRepositoryRoot `
            -AuthorityReferencePath (Join-Path $script:GateRepositoryRoot 'Plan\DECISIONS.md')
        $lockPath = Join-Path $evidenceRoot 'candidate-lock.json'
        New-V02ReleaseGateTestCandidateLock -Path $lockPath -Identity $script:GateIdentity `
            -ProfileFileSha256 $script:GateProfileSha -ProfileCanonicalSha256 $script:GateProfileCanonicalSha -Authority $authority | Out-Null
        $forged = Get-Content -LiteralPath $lockPath -Raw | ConvertFrom-Json
        $forged.Authority.Reference = 'Plan/forged-authority.json'
        Write-V02ReleaseGateTestJson -Path $lockPath -Value $forged | Out-Null
        Assert-V02ReleaseGateTestThrows {
            Read-V02ReleaseGateCandidateLock -Path $lockPath -EvidenceRoot $evidenceRoot `
                -ExpectedSourceCommit $script:GateIdentity.Commit -ExpectedSourceTree $script:GateIdentity.Tree `
                -PackageProfilePath $script:GateProfilePath -RepositoryRoot $script:GateRepositoryRoot `
                -AuthorityReferencePath (Join-Path $script:GateRepositoryRoot 'Plan\DECISIONS.md')
        } 'authority source'
    }

    Invoke-V02ReleaseGateTestCase 'candidate source/tree/profile drift fails closed' {
        $evidenceRoot = Join-Path $script:TestRoot 'drift-lock'
        New-V02ReleaseGateTestDirectory -Path $evidenceRoot
        $authority = Read-V02ReleaseGateAuthorityReference -RepositoryRoot $script:GateRepositoryRoot `
            -AuthorityReferencePath (Join-Path $script:GateRepositoryRoot 'Plan\DECISIONS.md')
        $lockPath = Join-Path $evidenceRoot 'candidate-lock.json'
        New-V02ReleaseGateTestCandidateLock -Path $lockPath -Identity $script:GateIdentity `
            -ProfileFileSha256 $script:GateProfileSha -ProfileCanonicalSha256 $script:GateProfileCanonicalSha -Authority $authority | Out-Null
        $drifted = Get-Content -LiteralPath $lockPath -Raw | ConvertFrom-Json
        $drifted.SourceTree = ('a' * 40)
        Write-V02ReleaseGateTestJson -Path $lockPath -Value $drifted | Out-Null
        Assert-V02ReleaseGateTestThrows {
            Read-V02ReleaseGateCandidateLock -Path $lockPath -EvidenceRoot $evidenceRoot `
                -ExpectedSourceCommit $script:GateIdentity.Commit -ExpectedSourceTree $script:GateIdentity.Tree `
                -PackageProfilePath $script:GateProfilePath -RepositoryRoot $script:GateRepositoryRoot `
                -AuthorityReferencePath (Join-Path $script:GateRepositoryRoot 'Plan\DECISIONS.md')
        } 'source tree'
        New-V02ReleaseGateTestCandidateLock -Path $lockPath -Identity $script:GateIdentity `
            -ProfileFileSha256 $script:GateProfileSha -ProfileCanonicalSha256 $script:GateProfileCanonicalSha -Authority $authority | Out-Null
        $drifted = Get-Content -LiteralPath $lockPath -Raw | ConvertFrom-Json
        $drifted.ProfileFileSha256 = ('a' * 64)
        Write-V02ReleaseGateTestJson -Path $lockPath -Value $drifted | Out-Null
        Assert-V02ReleaseGateTestThrows {
            Read-V02ReleaseGateCandidateLock -Path $lockPath -EvidenceRoot $evidenceRoot `
                -ExpectedSourceCommit $script:GateIdentity.Commit -ExpectedSourceTree $script:GateIdentity.Tree `
                -PackageProfilePath $script:GateProfilePath -RepositoryRoot $script:GateRepositoryRoot `
                -AuthorityReferencePath (Join-Path $script:GateRepositoryRoot 'Plan\DECISIONS.md')
        } 'profile bytes'
    }

    Invoke-V02ReleaseGateTestCase 'local GitHub snapshot cannot authenticate release state' {
        $path = Join-Path $script:TestRoot 'github.json'
        $snapshot = New-V02ReleaseGateTestGitHubSnapshot -Path $path
        $assessment = Assert-V02ReleaseGateGitHubSnapshot -Snapshot ((Read-V02ReleaseGateJsonFile -Path $path -Context 'test GitHub snapshot').Value)
        if ($assessment.Authenticated -or $assessment.Status -cne 'UNAUTHENTICATED_LOCAL_SNAPSHOT') {
            throw 'Local GitHub JSON was treated as authenticated authority.'
        }
        $forged = $snapshot | ConvertTo-Json -Depth 20 | ConvertFrom-Json
        $forged | Add-Member -MemberType NoteProperty -Name Authenticated -Value $true
        Assert-V02ReleaseGateTestThrows { Assert-V02ReleaseGateGitHubSnapshot -Snapshot $forged } 'exactly'
    }

    Invoke-V02ReleaseGateTestCase 'local Human GO is role/check-bound but remains NOT_OBSERVED' {
        $evidenceRoot = Join-Path $script:TestRoot 'human'
        New-V02ReleaseGateTestDirectory -Path $evidenceRoot
        $package = [pscustomobject][ordered]@{
            IdentityPath = Join-Path $evidenceRoot 'package-identity.json'
            ReceiptSha256 = ('A' * 64)
            ReceiptFileSha256 = ('B' * 64)
            ArchivePath = Join-Path $evidenceRoot 'archive.zip'
            ArchiveSha256 = ('C' * 64)
            AppPath = Join-Path $evidenceRoot 'app.exe'
            AppSha256 = ('D' * 64)
            CorePath = Join-Path $evidenceRoot 'core.exe'
            CoreSha256 = ('E' * 64)
        }
        Write-V02ReleaseGateTestText -Path $package.IdentityPath -Text 'receipt' | Out-Null
        $package.ReceiptFileSha256 = Get-V02ReleaseGateFileSha256 -Path $package.IdentityPath
        $package.ArchivePath = Join-Path $evidenceRoot 'archive.zip'; Write-V02ReleaseGateTestText -Path $package.ArchivePath -Text 'archive' | Out-Null
        $package.AppPath = Join-Path $evidenceRoot 'app.exe'; Write-V02ReleaseGateTestText -Path $package.AppPath -Text 'app' | Out-Null
        $package.CorePath = Join-Path $evidenceRoot 'core.exe'; Write-V02ReleaseGateTestText -Path $package.CorePath -Text 'core' | Out-Null
        $rendererPath = Join-Path $evidenceRoot 'renderer.json'; Write-V02ReleaseGateTestText -Path $rendererPath -Text 'renderer' | Out-Null
        $matrixPath = Join-Path $evidenceRoot 'matrix.json'; Write-V02ReleaseGateTestText -Path $matrixPath -Text 'matrix' | Out-Null
        $githubPath = Join-Path $evidenceRoot 'github.json'; New-V02ReleaseGateTestGitHubSnapshot -Path $githubPath | Out-Null
        $renderer = [pscustomobject][ordered]@{ ManifestPath = $rendererPath; ManifestSha256 = Get-V02ReleaseGateFileSha256 -Path $rendererPath }
        $matrix = [pscustomobject][ordered]@{ ManifestPath = $matrixPath; ManifestFileSha256 = Get-V02ReleaseGateFileSha256 -Path $matrixPath }
        $reviewPath = Join-Path $evidenceRoot 'human-review.json'
        New-V02ReleaseGateTestHumanReview -Path $reviewPath -EvidenceRoot $evidenceRoot -Package $package `
            -Renderer $renderer -Matrix $matrix -GitHubPath $githubPath -GitHubSha (Get-V02ReleaseGateFileSha256 -Path $githubPath) `
            -Identity $script:GateIdentity | Out-Null
        $review = Read-V02ReleaseGateJsonFile -Path $reviewPath -Context 'test Human review'
        $disposition = Assert-V02ReleaseGateHumanReview -Review $review.Value -ReviewPath $review.Path `
            -ExpectedSourceCommit $script:GateIdentity.Commit -ExpectedSourceTree $script:GateIdentity.Tree `
            -Package $package -Renderer $renderer -Matrix $matrix -GitHubSnapshotPath $githubPath `
            -GitHubSnapshotSha256 (Get-V02ReleaseGateFileSha256 -Path $githubPath) -EvidenceRoot $evidenceRoot
        if ($disposition.Status -cne 'NOT_OBSERVED' -or $disposition.Authenticated) { throw 'Local Human GO was credited.' }
        $tampered = $review.Value
        $tampered.Checks[0].Binding = 'HumanCheck:renderer-compatibility'
        Assert-V02ReleaseGateTestThrows {
            Assert-V02ReleaseGateHumanReview -Review $tampered -ReviewPath $review.Path `
                -ExpectedSourceCommit $script:GateIdentity.Commit -ExpectedSourceTree $script:GateIdentity.Tree `
                -Package $package -Renderer $renderer -Matrix $matrix -GitHubSnapshotPath $githubPath `
                -GitHubSnapshotSha256 (Get-V02ReleaseGateFileSha256 -Path $githubPath) -EvidenceRoot $evidenceRoot
        } 'binding'
        $pathTampered = $review.Value | ConvertTo-Json -Depth 100 | ConvertFrom-Json
        $pathTampered.Reviewer.ReviewedUtc = [string]$review.Value.Reviewer.ReviewedUtc
        $pathTamperedCheck = $pathTampered.Checks | Where-Object { $_.Id -ceq 'package-receipt' }
        $pathTamperedCheck.Binding = 'HumanCheck:package-receipt'
        $pathTamperedCheck.Path = $renderer.ManifestPath
        $pathTamperedCheck.Sha256 = $renderer.ManifestSha256
        Assert-V02ReleaseGateTestThrows {
            Assert-V02ReleaseGateHumanReview -Review $pathTampered -ReviewPath $review.Path `
                -ExpectedSourceCommit $script:GateIdentity.Commit -ExpectedSourceTree $script:GateIdentity.Tree `
                -Package $package -Renderer $renderer -Matrix $matrix -GitHubSnapshotPath $githubPath `
                -GitHubSnapshotSha256 (Get-V02ReleaseGateFileSha256 -Path $githubPath) -EvidenceRoot $evidenceRoot
        } 'semantic path'
    }

    Invoke-V02ReleaseGateTestCase 'same-held-byte snapshot rejects post-validation drift' {
        $path = Join-Path $script:TestRoot 'toctou.txt'
        Write-V02ReleaseGateTestText -Path $path -Text 'before' | Out-Null
        $snapshot = Get-V02ReleaseGateStableFileSnapshot -Path $path -Context 'TOCTOU fixture'
        Write-V02ReleaseGateTestText -Path $path -Text 'after' | Out-Null
        Assert-V02ReleaseGateTestThrows {
            Assert-V02ReleaseGateSnapshotUnchanged -Snapshot $snapshot -Context 'TOCTOU post-validation'
        } 'length|bytes'
    }

    Invoke-V02ReleaseGateTestCase 'candidate lock binds receipt archive App Core renderer and matrix bytes' {
        $lock = [pscustomobject][ordered]@{
            PackageReceiptSha256 = ('A' * 64)
            PackageReceiptFileSha256 = ('B' * 64)
            PackageArchiveSha256 = ('C' * 64)
            PackageManifestSha256 = ('D' * 64)
            PackageAppSha256 = ('E' * 64)
            PackageCoreSha256 = ('F' * 64)
            RendererManifestSha256 = ('1' * 64)
            RuntimeMatrixManifestSha256 = ('2' * 64)
        }
        $package = [pscustomobject][ordered]@{
            ReceiptSha256 = $lock.PackageReceiptSha256
            ReceiptFileSha256 = $lock.PackageReceiptFileSha256
            ArchiveSha256 = $lock.PackageArchiveSha256
            ManifestSha256 = $lock.PackageManifestSha256
            AppSha256 = $lock.PackageAppSha256
            CoreSha256 = $lock.PackageCoreSha256
        }
        $renderer = [pscustomobject][ordered]@{ ManifestSha256 = $lock.RendererManifestSha256 }
        $matrix = [pscustomobject][ordered]@{ ManifestFileSha256 = $lock.RuntimeMatrixManifestSha256 }
        Assert-V02ReleaseGateCandidateByteBinding -CandidateLock $lock -Package $package -Renderer $renderer -Matrix $matrix
        $package.ArchiveSha256 = ('9' * 64)
        Assert-V02ReleaseGateTestThrows {
            Assert-V02ReleaseGateCandidateByteBinding -CandidateLock $lock -Package $package -Renderer $renderer -Matrix $matrix
        } 'PackageArchiveSha256'
    }

    Invoke-V02ReleaseGateTestCase 'path escape and reparse-style aliases fail closed' {
        $root = Join-Path $script:TestRoot 'contained'
        $outside = Join-Path $script:TestRoot 'outside.txt'
        New-V02ReleaseGateTestDirectory -Path $root
        Write-V02ReleaseGateTestText -Path $outside -Text 'outside' | Out-Null
        Assert-V02ReleaseGateTestThrows {
            Assert-V02ReleaseGatePathWithinRoot -Path $outside -Root $root -Context 'path escape'
        } 'escapes'
        $inside = Join-Path $root 'inside.txt'
        Write-V02ReleaseGateTestText -Path $inside -Text 'inside' | Out-Null
        Assert-V02ReleaseGatePathWithinRoot -Path $inside -Root $root -Context 'contained path' | Out-Null

        $outsideDirectory = Join-Path $script:TestRoot 'outside-directory'
        New-V02ReleaseGateTestDirectory -Path $outsideDirectory
        $outsideDirectoryFile = Join-Path $outsideDirectory 'parent-target.txt'
        Write-V02ReleaseGateTestText -Path $outsideDirectoryFile -Text 'parent target' | Out-Null
        $leafAlias = Join-Path $root 'leaf-reparse-alias'
        # A directory junction is usable in both PS7 and Windows PowerShell
        # 5.1 without the Developer-Mode privilege required by file symlinks.
        # The junction itself is the final (leaf) reparse component here.
        New-Item -ItemType Junction -Path $leafAlias -Target $outsideDirectory | Out-Null
        Assert-V02ReleaseGateTestThrows {
            Resolve-V02ReleaseGateExistingPath -Path $leafAlias -Type Container -Context 'leaf reparse swap fixture' | Out-Null
        } 'reparse|final path'
        $parentAlias = Join-Path $root 'parent-reparse-alias'
        New-Item -ItemType Junction -Path $parentAlias -Target $outsideDirectory | Out-Null
        Assert-V02ReleaseGateTestThrows {
            Get-V02ReleaseGateStableFileSnapshot -Path (Join-Path $parentAlias 'parent-target.txt') -Context 'parent reparse swap fixture' | Out-Null
        } 'reparse|final path'
    }

    Invoke-V02ReleaseGateTestCase 'snapshot size bound rejects oversized evidence' {
        $path = Join-Path $script:TestRoot 'oversized-evidence.bin'
        $bytes = New-Object byte[] ([int32]($script:V02ReleaseGateMaximumSnapshotBytes + 1))
        [IO.File]::WriteAllBytes($path, $bytes)
        Assert-V02ReleaseGateTestThrows {
            Get-V02ReleaseGateStableFileSnapshot -Path $path -Context 'oversized snapshot fixture' | Out-Null
        } 'bounded snapshot size'
    }

    Invoke-V02ReleaseGateTestCase 'NTFS hardlink file identity aliases are rejected' {
        $original = Join-Path $script:TestRoot 'identity-original.txt'
        $alias = Join-Path $script:TestRoot 'identity-hardlink.txt'
        Write-V02ReleaseGateTestText -Path $original -Text 'same held bytes' | Out-Null
        New-Item -ItemType HardLink -Path $alias -Target $original | Out-Null
        Assert-V02ReleaseGateTestThrows {
            $first = Get-V02ReleaseGateStableFileSnapshot -Path $original -Context 'hardlink original fixture'
            $second = Get-V02ReleaseGateStableFileSnapshot -Path $alias -Context 'hardlink alias fixture'
            Assert-V02ReleaseGateDistinctFileIdentities -Snapshots @($first, $second) -Context 'hardlink alias fixture'
        } 'hardlink|identity|alias|final path'
    }

    Invoke-V02ReleaseGateTestCase 'validator and helper snapshots stay bound for the entire run' {
        $snapshots = @(Get-V02ReleaseGateValidatorSnapshots -RepositoryRoot $script:GateRepositoryRoot)
        if ($snapshots.Count -ne $script:V02ReleaseGateValidatorRelativePaths.Count) {
            throw "Expected $($script:V02ReleaseGateValidatorRelativePaths.Count) validator/helper snapshots; observed $($snapshots.Count)."
        }
        Assert-V02ReleaseGateBoundSnapshots -Snapshots $snapshots -Phase 'validator/helper stability fixture'
        $copy = Join-Path $script:TestRoot 'validator-copy.ps1'
        Copy-Item -LiteralPath $snapshots[1].Path -Destination $copy
        try {
            $copySnapshot = Get-V02ReleaseGateStableFileSnapshot -Path $copy -Context 'validator copy fixture'
            $original = [IO.File]::ReadAllBytes($copy)
            $mutated = [byte[]]::new([int]($original.Length + 1))
            [Array]::Copy($original, 0, $mutated, 0, $original.Length)
            $mutated[$original.Length] = 0x0A
            [IO.File]::WriteAllBytes($copy, $mutated)
            Assert-V02ReleaseGateTestThrows {
                Assert-V02ReleaseGateSnapshotUnchanged -Snapshot $copySnapshot -Context 'validator/helper drift fixture' | Out-Null
            } 'length|bytes'
        }
        finally {
            if (Test-Path -LiteralPath $copy) { Remove-Item -LiteralPath $copy -Force }
        }
    }

    Invoke-V02ReleaseGateTestCase 'production gate exposes no injectable validators' {
        $parameters = @((Get-Command Invoke-V02ReleaseGate -CommandType Function).Parameters.Keys)
        foreach ($name in @('PackageValidator', 'RendererValidator', 'RuntimeMatrixValidator')) {
            if ($parameters -contains $name) { throw "Production gate still exposes $name." }
        }
        Assert-V02ReleaseGateTestThrows {
            Invoke-V02ReleaseGate -PackageValidator ([scriptblock]::Create('return $null'))
        } 'parameter'
    }

    Invoke-V02ReleaseGateTestCase 'missing authority returns NOT_READY and no Runtime/Human/Release observation' {
        $fixtureRepo = New-V02ReleaseGateTestCleanRepository
        try {
            $identity = Get-V02ReleaseGateTestRepositoryIdentity -RepositoryRoot $fixtureRepo
            $root = Join-Path $script:TestRoot 'not-ready-inputs'
            $packageRoot = Join-Path $root 'package'
            New-V02ReleaseGateTestDirectory -Path $packageRoot
            New-V02ReleaseGateTestDirectory -Path (Join-Path $root 'Thai')
            New-V02ReleaseGateTestDirectory -Path (Join-Path $root 'English')
            foreach ($file in @('package-identity.json', 'archive.zip', 'renderer.json', 'matrix.json', 'contract.json', 'synthetic.json', 'human.json', 'github.json')) {
                Write-V02ReleaseGateTestText -Path (Join-Path $root $file) -Text '{}' | Out-Null
            }
            foreach ($file in @('package-manifest.json', 'HerdrOps.App.exe', 'HerdrOps.Core.exe')) {
                Write-V02ReleaseGateTestText -Path (Join-Path $packageRoot $file) -Text 'fixture' | Out-Null
            }
            $args = @{
                ExpectedSourceCommit = $identity.Commit
                ExpectedSourceTree = $identity.Tree
                PackageIdentityPath = Join-Path $root 'package-identity.json'
                PackageArchivePath = Join-Path $root 'archive.zip'
                ExtractedPackageRoot = $packageRoot
                PackageProfilePath = Join-Path $fixtureRepo 'tools\packaging\v0.2\package-identity-profile.json'
                RendererManifestPath = Join-Path $root 'renderer.json'
                ThaiEvidenceDirectory = Join-Path $root 'Thai'
                EnglishEvidenceDirectory = Join-Path $root 'English'
                RuntimeMatrixManifestPath = Join-Path $root 'matrix.json'
                ContractEvidencePath = Join-Path $root 'contract.json'
                SyntheticEvidencePath = Join-Path $root 'synthetic.json'
                HumanReviewPath = Join-Path $root 'human.json'
                GitHubSnapshotPath = Join-Path $root 'github.json'
                EvidenceRoot = $root
                RepositoryRoot = $fixtureRepo
            }
            $result = Invoke-V02ReleaseGate @args
            if ($result.Result -cne 'NOT_READY' -or [bool]$result.ReleaseReady) { throw 'Missing authority did not fail closed.' }
            foreach ($name in @('Runtime', 'Human', 'Release')) {
                if ($result.EvidenceClasses.$name.Status -cne 'NOT_OBSERVED') { throw "$name was not NOT_OBSERVED." }
            }
        }
        finally {
            if (Test-Path -LiteralPath $fixtureRepo) { Remove-Item -LiteralPath $fixtureRepo -Recurse -Force }
        }
    }
}
finally {
    if (Test-Path -LiteralPath $script:TestRoot) { Remove-Item -LiteralPath $script:TestRoot -Recurse -Force }
}

if ($script:Failures.Count -ne 0) {
    $script:Failures | ForEach-Object { Write-Host $_ -ForegroundColor Red }
    throw "$($script:Failures.Count) v0.2 release-gate test(s) failed."
}
Write-Host 'All v0.2 release-gate hostile tests passed.' -ForegroundColor Green
