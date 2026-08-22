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
    foreach ($rel in $script:V02ReleaseGateTransitiveGovernanceRelativePaths) {
        $src = Join-Path $script:GateRepositoryRoot ($rel -replace '/', '\')
        $dst = Join-Path $root ($rel -replace '/', '\')
        $dstDir = [IO.Path]::GetDirectoryName($dst)
        if (-not (Test-Path -LiteralPath $dstDir -PathType Container)) {
            New-V02ReleaseGateTestDirectory -Path $dstDir
        }
        Copy-Item -LiteralPath $src -Destination $dst -Force
    }
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
        [Parameter(Mandatory = $true)]$IndependentReceipt,
        [string]$PackageReceiptSha256 = ('1' * 64),
        [string]$PackageReceiptFileSha256 = ('2' * 64),
        [string]$PackageArchiveSha256 = ('3' * 64),
        [string]$PackageManifestSha256 = ('4' * 64),
        [string]$PackageAppSha256 = ('5' * 64),
        [string]$PackageCoreSha256 = ('6' * 64),
        [string]$RendererManifestSha256 = ('7' * 64),
        [string]$RuntimeMatrixManifestSha256 = ('8' * 64),
        [string]$Issue9CandidateSha256 = ('9' * 64)
    )
    $lock = [pscustomobject][ordered]@{
        SchemaVersion = 2
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
        Issue9CandidateSha256 = $Issue9CandidateSha256
        Authority = [pscustomobject][ordered]@{
            DecisionId = $Authority.DecisionId
            ApprovalReference = $Authority.ApprovalReference
            PayloadSha256 = $Authority.PayloadSha256
            Reference = $Authority.RelativeReference
            ReferenceSha256 = $Authority.FileSha256
            OwnerIdentity = $Authority.OwnerIdentity
            OwnerRole = $Authority.OwnerRole
            Authentication = 'TRUSTED_OWNER_PLUS_EXTERNAL_RSA_AUTHENTICATED_RECEIPT'
            IndependentReceiptPath = $IndependentReceipt.Path
            IndependentReceiptSha256 = $IndependentReceipt.FileSha256
            IndependentReceiptIdentity = $IndependentReceipt.ReviewerIdentity
            IndependentReceiptRole = $IndependentReceipt.ReviewerRole
            IndependentReceiptAuthentication = $IndependentReceipt.Authentication
            IndependentReceiptTrustAnchorFingerprint = $IndependentReceipt.TrustAnchorFingerprint
            IndependentReceiptSignedPayloadSha256 = $IndependentReceipt.SignedPayloadSha256
        }
        Runtime = 'NOT_OBSERVED'
        Human = 'NOT_OBSERVED'
        Release = 'NOT_OBSERVED'
    }
    Write-V02ReleaseGateTestJson -Path $Path -Value $lock | Out-Null
    return $lock
}

function New-V02ReleaseGateTestExternalIndependentReceipt {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)]$Identity,
        [Parameter(Mandatory = $true)][string]$ProfileFileSha256,
        [Parameter(Mandatory = $true)][string]$ProfileCanonicalSha256,
        [string]$PackageReceiptSha256 = ('1' * 64),
        [string]$PackageReceiptFileSha256 = ('2' * 64),
        [string]$PackageArchiveSha256 = ('3' * 64),
        [string]$PackageManifestSha256 = ('4' * 64),
        [string]$PackageAppSha256 = ('5' * 64),
        [string]$PackageCoreSha256 = ('6' * 64),
        [string]$RendererManifestSha256 = ('7' * 64),
        [string]$RuntimeMatrixManifestSha256 = ('8' * 64),
        [string]$Issue9CandidateSha256 = ('9' * 64),
        [string]$ReviewerIdentity = '@independent-reviewer',
        [System.Security.Cryptography.RSA]$RsaKey = $null
    )
    $rsa = $RsaKey
    if ($null -eq $rsa) {
        $rsa = [System.Security.Cryptography.RSA]::Create(2048)
    }
    $pubParams = $rsa.ExportParameters($false)
    $trustAnchor = [pscustomobject][ordered]@{
        KeyType = 'RSA-2048'
        Modulus = [Convert]::ToBase64String($pubParams.Modulus)
        Exponent = [Convert]::ToBase64String($pubParams.Exponent)
    }
    $signedPayload = [pscustomobject][ordered]@{
        DecisionId = 'herdrops-rec-all-v2'
        ApprovalReference = 'https://github.com/OSHEThai/HerdrOps/issues/149#issuecomment-5380637664'
        AuthorityReference = 'Plan/DECISIONS.md#D-024'
        AuthorityReferenceSha256 = 'BFADC29EA34BAA13FF5D3F43013795C0258CF691369E5E150774D3F646F4F730'
        Candidate = [pscustomobject][ordered]@{
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
            Issue9CandidateSha256 = $Issue9CandidateSha256
        }
        Owner = [pscustomobject][ordered]@{ Identity = '@yutthaphon'; Role = 'ProductOwner' }
        IndependentReviewer = [pscustomobject][ordered]@{ Identity = $ReviewerIdentity; Role = 'IndependentGateReviewer' }
    }
    $canonicalJson = ConvertTo-V02Jcs $signedPayload
    $canonicalBytes = [Text.UTF8Encoding]::new($false, $true).GetBytes($canonicalJson)
    $sigBytes = $rsa.SignData($canonicalBytes, [System.Security.Cryptography.HashAlgorithmName]::SHA256, [System.Security.Cryptography.RSASignaturePadding]::Pkcs1)
    $sigB64 = [Convert]::ToBase64String($sigBytes)
    $payloadSha256 = (Get-V02Sha256Hex -Bytes $canonicalBytes).ToUpperInvariant()
    $modulusFingerprint = (Get-V02Sha256Hex -Bytes $pubParams.Modulus).ToUpperInvariant()

    $receipt = [pscustomobject][ordered]@{
        SchemaVersion = 3
        EvidenceClass = 'ExternalIndependentCandidateReceipt'
        Result = 'APPROVED_CANDIDATE_ONLY'
        DecisionId = 'herdrops-rec-all-v2'
        ApprovalReference = 'https://github.com/OSHEThai/HerdrOps/issues/149#issuecomment-5380637664'
        AuthorityReference = 'Plan/DECISIONS.md#D-024'
        AuthorityReferenceSha256 = 'BFADC29EA34BAA13FF5D3F43013795C0258CF691369E5E150774D3F646F4F730'
        Candidate = $signedPayload.Candidate
        Owner = $signedPayload.Owner
        IndependentReviewer = $signedPayload.IndependentReviewer
        Authentication = [pscustomobject][ordered]@{
            Method = 'EXTERNAL_RSA_SHA256_AUTHENTICATED_REVIEW'
            Reference = 'https://external-review.invalid/herdrops/v0.2/candidate'
            VerifiedBy = $ReviewerIdentity
            VerifiedRole = 'IndependentGateReviewer'
            TrustAnchor = $trustAnchor
            Signature = $sigB64
            SignatureAlgorithm = 'RSASSA-PKCS1-v1_5-SHA256'
            Authenticated = $true
        }
        RoleDistinct = $true
        Runtime = 'NOT_OBSERVED'
        Human = 'NOT_OBSERVED'
        Release = 'NOT_OBSERVED'
        CreditGranted = $false
    }
    $hash = Write-V02ReleaseGateTestJson -Path $Path -Value $receipt
    return [pscustomobject][ordered]@{
        Path = [IO.Path]::GetFullPath($Path)
        FileSha256 = $hash
        ReviewerIdentity = $ReviewerIdentity
        ReviewerRole = 'IndependentGateReviewer'
        Authentication = 'EXTERNAL_RSA_SHA256_AUTHENTICATED_REVIEW'
        TrustAnchor = $trustAnchor
        TrustAnchorFingerprint = $modulusFingerprint
        Signature = $sigB64
        SignedPayloadSha256 = $payloadSha256
        Candidate = $receipt.Candidate
        Value = $receipt
        PrivateKey = $rsa
    }
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
        [Parameter(Mandatory = $true)]$Issue9,
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
    $artifactPaths['issue-9-acceptance'] = $Issue9.CandidatePath
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
        SchemaVersion = 2
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
            Issue9CandidateSha256 = $Issue9.CandidateSha256
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

function New-V02ReleaseGateTestIssue9Candidate {
    param(
        [Parameter(Mandatory = $true)][string]$Root,
        [Parameter(Mandatory = $true)]$Identity
    )
    $packageRoot = Join-Path $Root 'package'
    New-V02ReleaseGateTestDirectory $packageRoot
    $package = [pscustomobject][ordered]@{
        IdentityPath = Join-Path $Root 'identity.json'; ReceiptFileSha256 = ('1' * 64); ReceiptSha256 = ('2' * 64)
        ArchivePath = Join-Path $Root 'archive.zip'; ArchiveSha256 = ('3' * 64)
        ManifestPath = Join-Path $packageRoot 'package-manifest.json'; ManifestSha256 = ('4' * 64)
        AppPath = Join-Path $packageRoot 'HerdrOps.App.exe'; AppSha256 = ('5' * 64)
        CorePath = Join-Path $packageRoot 'HerdrOps.Core.exe'; CoreSha256 = ('6' * 64)
    }
    foreach ($path in @($package.IdentityPath, $package.ArchivePath, $package.ManifestPath, $package.AppPath, $package.CorePath)) {
        Write-V02ReleaseGateTestText -Path $path -Text 'fixture' | Out-Null
    }
    $matrixPath = Join-Path $Root 'matrix.json'; Write-V02ReleaseGateTestText $matrixPath 'matrix' | Out-Null
    $matrix = [pscustomobject][ordered]@{
        ManifestPath = $matrixPath
        ManifestFileSha256 = Get-V02ReleaseGateFileSha256 $matrixPath
        ManifestPayloadSha256 = ('7' * 64)
        Candidate = [pscustomobject][ordered]@{ Payload = [pscustomobject][ordered]@{ Binding = [pscustomobject][ordered]@{
            HerdrReleaseId = $script:V02ReleaseGateHerdrReleaseId
            HerdrExecutableSha256 = $script:V02ReleaseGateHerdrExecutableSha256
            BundledSchemaSha256 = ('8' * 64)
            HerdrProtocol = 20
        } } }
    }
    $runtimeRoots = @(); $uiRoots = @(); $legs = @()
    foreach ($language in @('Thai', 'English')) {
        $runtimeRoot = Join-Path $Root "$language-runtime"; New-V02ReleaseGateTestDirectory $runtimeRoot; $runtimeRoots += $runtimeRoot
        $uiRoot = Join-Path $Root "$language-ui"; New-V02ReleaseGateTestDirectory $uiRoot; $uiRoots += $uiRoot
        $receiptPath = Join-Path $uiRoot 'issue9-ui-receipt.json'; Write-V02ReleaseGateTestText $receiptPath '{}' | Out-Null
        $pages = @(); foreach ($pageName in @('Overview', 'LiveOrganization', 'AgentDetail')) {
            $capturePath = Join-Path $uiRoot "$pageName.png"
            Write-V02ReleaseGateTestText $capturePath "$language $pageName capture" | Out-Null
            $pages += [pscustomobject][ordered]@{ Name = $pageName; Language = $language; UiCapturePath = $capturePath; UiCaptureSha256 = Get-V02ReleaseGateFileSha256 $capturePath; StateSha256 = ('B' * 64); WorkspaceId = 'workspace'; ProjectId = 'project'; AgentId = 'agent'; TaskId = 'task'; AgentStatus = 'Working'; PaneId = 'pane' }
        }
        $legs += [pscustomobject][ordered]@{
            Language = $language; RuntimeEvidenceDirectory = $runtimeRoot; UiEvidenceDirectory = $uiRoot; UiReceiptPath = $receiptPath
            UiReceiptSha256 = Get-V02ReleaseGateFileSha256 $receiptPath; SideBySideCaptureSha256 = ('C' * 64); Pages = $pages
            Selection = [pscustomobject][ordered]@{ WorkspaceId = 'workspace'; ProjectId = 'project'; AgentId = 'agent'; TaskId = 'task'; AgentStatus = 'Working'; PaneId = 'pane'; StateSha256 = ('B' * 64); Source = 'CoreSnapshot' }
            Lifecycle = [pscustomobject][ordered]@{ DashboardClosed = $true; CoreConnectedAfterDashboardClose = $true; DisconnectObserved = $true; ReconnectObserved = $true; ReconciliationObserved = $true; EventAStateSha256 = ('D' * 64); EventBStateSha256 = ('E' * 64); ReconciledStateSha256 = ('F' * 64); ControlServerSurvivedTargetRestart = $true }
        }
    }
    $candidate = [pscustomobject][ordered]@{
        SchemaVersion = 1; EvidenceClassification = 'Issue9RuntimeCandidate'; Issue = 9; Result = 'PASS'
        Source = [pscustomobject][ordered]@{ CommitSha = $Identity.Commit; TreeSha = $Identity.Tree; GitTreeClean = $true }
        Package = [pscustomobject][ordered]@{ IdentityPath = $package.IdentityPath; IdentityFileSha256 = $package.ReceiptFileSha256; ReceiptSha256 = $package.ReceiptSha256; ArchivePath = $package.ArchivePath; ArchiveSha256 = $package.ArchiveSha256; ManifestPath = $package.ManifestPath; ManifestSha256 = $package.ManifestSha256; AppPath = $package.AppPath; AppSha256 = $package.AppSha256; CorePath = $package.CorePath; CoreSha256 = $package.CoreSha256 }
        Herdr = [pscustomobject][ordered]@{ ReleaseId = $script:V02ReleaseGateHerdrReleaseId; ExecutableSha256 = $script:V02ReleaseGateHerdrExecutableSha256; BundledSchemaSha256 = ('8' * 64); Protocol = '20' }
        Sessions = [pscustomobject][ordered]@{ Control = [pscustomobject][ordered]@{ Name = 'acceptance'; SocketPath = 'C:\fixture\control.sock'; ServerIdentity = 'control-server' }; Target = [pscustomobject][ordered]@{ Name = 'agent-lab'; SocketPath = 'C:\fixture\target.sock'; Reference = 'target-agent' } }
        MatrixCandidate = [pscustomobject][ordered]@{ Path = $matrixPath; FileSha256 = $matrix.ManifestFileSha256; PayloadSha256 = $matrix.ManifestPayloadSha256; EvidenceClassification = 'RuntimeMatrixCandidate'; IndependentHumanReview = 'NOT_OBSERVED'; ReleaseCredit = $false }
        Languages = $legs
        EvidenceBoundary = [pscustomobject][ordered]@{ Runtime = 'NOT_OBSERVED'; HumanVisual = 'NOT_OBSERVED'; ReleaseCredit = $false; OutputAuthority = 'RuntimeCandidate'; FixtureMode = $false }
    }
    return [pscustomobject][ordered]@{
        Candidate = $candidate; Package = $package; Matrix = $matrix
        Context = [pscustomobject][ordered]@{ ThaiEvidenceDirectory = $runtimeRoots[0]; EnglishEvidenceDirectory = $runtimeRoots[1]; ReleaseEvidenceRoot = $Root }
    }
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
    Invoke-V02ReleaseGateTestCase 'approved candidate lock binds exact source/profile/authority and cryptographically verified external receipt' {
        $evidenceRoot = Join-Path $script:TestRoot 'lock'
        New-V02ReleaseGateTestDirectory -Path $evidenceRoot
        $authority = Read-V02ReleaseGateAuthorityReference -RepositoryRoot $script:GateRepositoryRoot `
            -AuthorityReferencePath (Join-Path $script:GateRepositoryRoot 'Plan\DECISIONS.md')
        $receipt = New-V02ReleaseGateTestExternalIndependentReceipt -Path (Join-Path $script:TestRoot 'external-lock\receipt.json') `
            -Identity $script:GateIdentity -ProfileFileSha256 $script:GateProfileSha -ProfileCanonicalSha256 $script:GateProfileCanonicalSha
        $lockPath = Join-Path $evidenceRoot 'candidate-lock.json'
        New-V02ReleaseGateTestCandidateLock -Path $lockPath -Identity $script:GateIdentity `
            -ProfileFileSha256 $script:GateProfileSha -ProfileCanonicalSha256 $script:GateProfileCanonicalSha -Authority $authority -IndependentReceipt $receipt | Out-Null
        $lock = Read-V02ReleaseGateCandidateLock -Path $lockPath -EvidenceRoot $evidenceRoot `
            -ExpectedSourceCommit $script:GateIdentity.Commit -ExpectedSourceTree $script:GateIdentity.Tree `
            -PackageProfilePath $script:GateProfilePath -RepositoryRoot $script:GateRepositoryRoot `
            -AuthorityReferencePath (Join-Path $script:GateRepositoryRoot 'Plan\DECISIONS.md') -IndependentCandidateReceiptPath $receipt.Path
        if ($lock.Result -cne 'APPROVED_CANDIDATE_ONLY' -or $lock.Authentication -cne 'TRUSTED_OWNER_PLUS_EXTERNAL_RSA_AUTHENTICATED_RECEIPT') {
            throw 'Candidate lock did not remain candidate-only and owner/independent-receipt bound.'
        }
    }

    Invoke-V02ReleaseGateTestCase 'builder-authored committed receipt is not an authority source' {
        $committedReceiptPath = Join-Path $script:GateRepositoryRoot 'Plan\v0.2-release-gate-independent-receipt.json'
        if (Test-Path -LiteralPath $committedReceiptPath) {
            throw 'A builder-authored committed independent receipt still exists.'
        }
        Assert-V02ReleaseGateTestThrows {
            Read-V02ReleaseGateExternalIndependentCandidateReceipt -Path $committedReceiptPath `
                -RepositoryRoot $script:GateRepositoryRoot -EvidenceRoot (Join-Path $script:TestRoot 'receipt-authority') `
                -ExpectedSourceCommit $script:GateIdentity.Commit -ExpectedSourceTree $script:GateIdentity.Tree
        } 'missing'
    }

    Invoke-V02ReleaseGateTestCase 'builder-authored trust anchor inside repo is rejected' {
        $insideRepoReceipt = Join-Path $script:GateRepositoryRoot 'tools\packaging\v0.2\fake-receipt.json'
        Assert-V02ReleaseGateTestThrows {
            Read-V02ReleaseGateExternalIndependentCandidateReceipt -Path $insideRepoReceipt `
                -RepositoryRoot $script:GateRepositoryRoot -EvidenceRoot (Join-Path $script:TestRoot 'inside-repo-evidence') `
                -ExpectedSourceCommit $script:GateIdentity.Commit -ExpectedSourceTree $script:GateIdentity.Tree
        } 'missing|must be externally supplied outside'
    }

    Invoke-V02ReleaseGateTestCase 'forged external receipt cryptographic signature fails closed' {
        $receipt = New-V02ReleaseGateTestExternalIndependentReceipt -Path (Join-Path $script:TestRoot 'external-forged-sig\receipt.json') `
            -Identity $script:GateIdentity -ProfileFileSha256 $script:GateProfileSha -ProfileCanonicalSha256 $script:GateProfileCanonicalSha
        $forged = $receipt.Value | ConvertTo-Json -Depth 100 | ConvertFrom-Json
        # Corrupt the RSA signature bytes
        $sigBytes = [Convert]::FromBase64String($forged.Authentication.Signature)
        $sigBytes[0] = [byte]($sigBytes[0] -bxor 0xFF)
        $forged.Authentication.Signature = [Convert]::ToBase64String($sigBytes)
        Write-V02ReleaseGateTestJson -Path $receipt.Path -Value $forged | Out-Null
        Assert-V02ReleaseGateTestThrows {
            Read-V02ReleaseGateExternalIndependentCandidateReceipt -Path $receipt.Path `
                -RepositoryRoot $script:GateRepositoryRoot -EvidenceRoot (Join-Path $script:TestRoot 'forged-sig-evidence') `
                -ExpectedSourceCommit $script:GateIdentity.Commit -ExpectedSourceTree $script:GateIdentity.Tree
        } 'cryptographic signature verification failed'
    }

    Invoke-V02ReleaseGateTestCase 'tampered candidate payload under valid RSA signature fails closed' {
        $receipt = New-V02ReleaseGateTestExternalIndependentReceipt -Path (Join-Path $script:TestRoot 'external-tampered-payload\receipt.json') `
            -Identity $script:GateIdentity -ProfileFileSha256 $script:GateProfileSha -ProfileCanonicalSha256 $script:GateProfileCanonicalSha
        $tampered = $receipt.Value | ConvertTo-Json -Depth 100 | ConvertFrom-Json
        # Tamper the package archive hash under original valid signature
        $tampered.Candidate.PackageArchiveSha256 = ('9' * 64)
        Write-V02ReleaseGateTestJson -Path $receipt.Path -Value $tampered | Out-Null
        Assert-V02ReleaseGateTestThrows {
            Read-V02ReleaseGateExternalIndependentCandidateReceipt -Path $receipt.Path `
                -RepositoryRoot $script:GateRepositoryRoot -EvidenceRoot (Join-Path $script:TestRoot 'tampered-payload-evidence') `
                -ExpectedSourceCommit $script:GateIdentity.Commit -ExpectedSourceTree $script:GateIdentity.Tree
        } 'cryptographic signature verification failed'
    }

    Invoke-V02ReleaseGateTestCase 'signed receipt Issue9 field is mandatory closed and signature-bound' {
        $receipt = New-V02ReleaseGateTestExternalIndependentReceipt -Path (Join-Path $script:TestRoot 'external-issue9-schema\receipt.json') `
            -Identity $script:GateIdentity -ProfileFileSha256 $script:GateProfileSha -ProfileCanonicalSha256 $script:GateProfileCanonicalSha
        $missing = $receipt.Value | ConvertTo-Json -Depth 100 | ConvertFrom-Json
        $missing.Candidate.PSObject.Properties.Remove('Issue9CandidateSha256')
        Write-V02ReleaseGateTestJson -Path $receipt.Path -Value $missing | Out-Null
        Assert-V02ReleaseGateTestThrows {
            Read-V02ReleaseGateExternalIndependentCandidateReceipt -Path $receipt.Path `
                -RepositoryRoot $script:GateRepositoryRoot -EvidenceRoot (Join-Path $script:TestRoot 'external-issue9-missing') `
                -ExpectedSourceCommit $script:GateIdentity.Commit -ExpectedSourceTree $script:GateIdentity.Tree
        } 'exactly'

        $receipt = New-V02ReleaseGateTestExternalIndependentReceipt -Path $receipt.Path `
            -Identity $script:GateIdentity -ProfileFileSha256 $script:GateProfileSha -ProfileCanonicalSha256 $script:GateProfileCanonicalSha
        $extra = $receipt.Value | ConvertTo-Json -Depth 100 | ConvertFrom-Json
        $extra.Candidate | Add-Member -MemberType NoteProperty -Name Issue9Authority -Value 'caller-authored'
        Write-V02ReleaseGateTestJson -Path $receipt.Path -Value $extra | Out-Null
        Assert-V02ReleaseGateTestThrows {
            Read-V02ReleaseGateExternalIndependentCandidateReceipt -Path $receipt.Path `
                -RepositoryRoot $script:GateRepositoryRoot -EvidenceRoot (Join-Path $script:TestRoot 'external-issue9-extra') `
                -ExpectedSourceCommit $script:GateIdentity.Commit -ExpectedSourceTree $script:GateIdentity.Tree
        } 'exactly'

        $receipt = New-V02ReleaseGateTestExternalIndependentReceipt -Path $receipt.Path `
            -Identity $script:GateIdentity -ProfileFileSha256 $script:GateProfileSha -ProfileCanonicalSha256 $script:GateProfileCanonicalSha
        $stale = $receipt.Value | ConvertTo-Json -Depth 100 | ConvertFrom-Json
        $stale.Candidate.Issue9CandidateSha256 = ('A' * 64)
        Write-V02ReleaseGateTestJson -Path $receipt.Path -Value $stale | Out-Null
        Assert-V02ReleaseGateTestThrows {
            Read-V02ReleaseGateExternalIndependentCandidateReceipt -Path $receipt.Path `
                -RepositoryRoot $script:GateRepositoryRoot -EvidenceRoot (Join-Path $script:TestRoot 'external-issue9-stale') `
                -ExpectedSourceCommit $script:GateIdentity.Commit -ExpectedSourceTree $script:GateIdentity.Tree
        } 'cryptographic signature verification failed'
    }

    Invoke-V02ReleaseGateTestCase 'candidate lock Issue9 field is mandatory closed and externally bound' {
        $evidenceRoot = Join-Path $script:TestRoot 'issue9-lock-schema'
        New-V02ReleaseGateTestDirectory -Path $evidenceRoot
        $authority = Read-V02ReleaseGateAuthorityReference -RepositoryRoot $script:GateRepositoryRoot `
            -AuthorityReferencePath (Join-Path $script:GateRepositoryRoot 'Plan\DECISIONS.md')
        $receipt = New-V02ReleaseGateTestExternalIndependentReceipt -Path (Join-Path $script:TestRoot 'external-issue9-lock\receipt.json') `
            -Identity $script:GateIdentity -ProfileFileSha256 $script:GateProfileSha -ProfileCanonicalSha256 $script:GateProfileCanonicalSha
        $lockPath = Join-Path $evidenceRoot 'candidate-lock.json'
        New-V02ReleaseGateTestCandidateLock -Path $lockPath -Identity $script:GateIdentity `
            -ProfileFileSha256 $script:GateProfileSha -ProfileCanonicalSha256 $script:GateProfileCanonicalSha -Authority $authority -IndependentReceipt $receipt | Out-Null
        $missing = Get-Content -LiteralPath $lockPath -Raw | ConvertFrom-Json
        $missing.PSObject.Properties.Remove('Issue9CandidateSha256')
        Write-V02ReleaseGateTestJson -Path $lockPath -Value $missing | Out-Null
        Assert-V02ReleaseGateTestThrows {
            Read-V02ReleaseGateCandidateLock -Path $lockPath -EvidenceRoot $evidenceRoot `
                -ExpectedSourceCommit $script:GateIdentity.Commit -ExpectedSourceTree $script:GateIdentity.Tree `
                -PackageProfilePath $script:GateProfilePath -RepositoryRoot $script:GateRepositoryRoot `
                -AuthorityReferencePath (Join-Path $script:GateRepositoryRoot 'Plan\DECISIONS.md') -IndependentCandidateReceiptPath $receipt.Path
        } 'exactly'
        New-V02ReleaseGateTestCandidateLock -Path $lockPath -Identity $script:GateIdentity `
            -ProfileFileSha256 $script:GateProfileSha -ProfileCanonicalSha256 $script:GateProfileCanonicalSha -Authority $authority -IndependentReceipt $receipt -Issue9CandidateSha256 ('A' * 64) | Out-Null
        Assert-V02ReleaseGateTestThrows {
            Read-V02ReleaseGateCandidateLock -Path $lockPath -EvidenceRoot $evidenceRoot `
                -ExpectedSourceCommit $script:GateIdentity.Commit -ExpectedSourceTree $script:GateIdentity.Tree `
                -PackageProfilePath $script:GateProfilePath -RepositoryRoot $script:GateRepositoryRoot `
                -AuthorityReferencePath (Join-Path $script:GateRepositoryRoot 'Plan\DECISIONS.md') -IndependentCandidateReceiptPath $receipt.Path
        } 'Issue9CandidateSha256'
    }

    Invoke-V02ReleaseGateTestCase 'weak RSA key (<2048 bits) in external receipt fails closed' {
        $weakRsa = [System.Security.Cryptography.RSA]::Create(1024)
        $receipt = New-V02ReleaseGateTestExternalIndependentReceipt -Path (Join-Path $script:TestRoot 'external-weak-key\receipt.json') `
            -Identity $script:GateIdentity -ProfileFileSha256 $script:GateProfileSha -ProfileCanonicalSha256 $script:GateProfileCanonicalSha `
            -RsaKey $weakRsa
        Assert-V02ReleaseGateTestThrows {
            Read-V02ReleaseGateExternalIndependentCandidateReceipt -Path $receipt.Path `
                -RepositoryRoot $script:GateRepositoryRoot -EvidenceRoot (Join-Path $script:TestRoot 'weak-key-evidence') `
                -ExpectedSourceCommit $script:GateIdentity.Commit -ExpectedSourceTree $script:GateIdentity.Tree
        } 'at least 2048 bits'
    }

    Invoke-V02ReleaseGateTestCase 'malformed Base64 in RSA trust anchor or signature fails closed' {
        $receipt = New-V02ReleaseGateTestExternalIndependentReceipt -Path (Join-Path $script:TestRoot 'external-bad-b64\receipt.json') `
            -Identity $script:GateIdentity -ProfileFileSha256 $script:GateProfileSha -ProfileCanonicalSha256 $script:GateProfileCanonicalSha
        $badB64 = $receipt.Value | ConvertTo-Json -Depth 100 | ConvertFrom-Json
        $badB64.Authentication.TrustAnchor.Modulus = 'not-valid-base64-!!!'
        Write-V02ReleaseGateTestJson -Path $receipt.Path -Value $badB64 | Out-Null
        Assert-V02ReleaseGateTestThrows {
            Read-V02ReleaseGateExternalIndependentCandidateReceipt -Path $receipt.Path `
                -RepositoryRoot $script:GateRepositoryRoot -EvidenceRoot (Join-Path $script:TestRoot 'bad-b64-evidence') `
                -ExpectedSourceCommit $script:GateIdentity.Commit -ExpectedSourceTree $script:GateIdentity.Tree
        } 'valid Base64'
    }

    Invoke-V02ReleaseGateTestCase 'forged external receipt unauthenticated or missing fields fails closed' {
        $receipt = New-V02ReleaseGateTestExternalIndependentReceipt -Path (Join-Path $script:TestRoot 'external-forged-receipt\receipt.json') `
            -Identity $script:GateIdentity -ProfileFileSha256 $script:GateProfileSha -ProfileCanonicalSha256 $script:GateProfileCanonicalSha
        $forged = $receipt.Value | ConvertTo-Json -Depth 100 | ConvertFrom-Json
        $forged.Authentication.Authenticated = $false
        $forged.Authentication.Reference = (Join-Path $script:TestRoot 'local-proof.json')
        Write-V02ReleaseGateTestJson -Path $receipt.Path -Value $forged | Out-Null
        Assert-V02ReleaseGateTestThrows {
            Read-V02ReleaseGateExternalIndependentCandidateReceipt -Path $receipt.Path `
                -RepositoryRoot $script:GateRepositoryRoot -EvidenceRoot (Join-Path $script:TestRoot 'external-forged-evidence') `
                -ExpectedSourceCommit $script:GateIdentity.Commit -ExpectedSourceTree $script:GateIdentity.Tree
        } 'external HTTPS|authenticated'
    }

    Invoke-V02ReleaseGateTestCase 'copied Plan JSON cannot self-authorize a candidate lock' {
        $evidenceRoot = Join-Path $script:TestRoot 'copied-plan-authority'
        New-V02ReleaseGateTestDirectory -Path $evidenceRoot
        $authority = Read-V02ReleaseGateAuthorityReference -RepositoryRoot $script:GateRepositoryRoot `
            -AuthorityReferencePath (Join-Path $script:GateRepositoryRoot 'Plan\DECISIONS.md')
        $receipt = New-V02ReleaseGateTestExternalIndependentReceipt -Path (Join-Path $script:TestRoot 'external-copied-plan\receipt.json') `
            -Identity $script:GateIdentity -ProfileFileSha256 $script:GateProfileSha -ProfileCanonicalSha256 $script:GateProfileCanonicalSha
        $lockPath = Join-Path $evidenceRoot 'candidate-lock.json'
        New-V02ReleaseGateTestCandidateLock -Path $lockPath -Identity $script:GateIdentity `
            -ProfileFileSha256 $script:GateProfileSha -ProfileCanonicalSha256 $script:GateProfileCanonicalSha -Authority $authority -IndependentReceipt $receipt | Out-Null
        $copiedPlanOnly = Get-Content -LiteralPath $lockPath -Raw | ConvertFrom-Json
        foreach ($name in @('IndependentReceiptPath', 'IndependentReceiptSha256', 'IndependentReceiptIdentity', 'IndependentReceiptRole', 'IndependentReceiptAuthentication', 'IndependentReceiptTrustAnchorFingerprint', 'IndependentReceiptSignedPayloadSha256')) {
            $copiedPlanOnly.Authority.PSObject.Properties.Remove($name)
        }
        Write-V02ReleaseGateTestJson -Path $lockPath -Value $copiedPlanOnly | Out-Null
        Assert-V02ReleaseGateTestThrows {
            Read-V02ReleaseGateCandidateLock -Path $lockPath -EvidenceRoot $evidenceRoot `
                -ExpectedSourceCommit $script:GateIdentity.Commit -ExpectedSourceTree $script:GateIdentity.Tree `
                -PackageProfilePath $script:GateProfilePath -RepositoryRoot $script:GateRepositoryRoot `
                -AuthorityReferencePath (Join-Path $script:GateRepositoryRoot 'Plan\DECISIONS.md') -IndependentCandidateReceiptPath $receipt.Path
        } 'exactly'
    }

    Invoke-V02ReleaseGateTestCase 'forged candidate provenance fails closed' {
        $evidenceRoot = Join-Path $script:TestRoot 'forged-lock'
        New-V02ReleaseGateTestDirectory -Path $evidenceRoot
        $authority = Read-V02ReleaseGateAuthorityReference -RepositoryRoot $script:GateRepositoryRoot `
            -AuthorityReferencePath (Join-Path $script:GateRepositoryRoot 'Plan\DECISIONS.md')
        $receipt = New-V02ReleaseGateTestExternalIndependentReceipt -Path (Join-Path $script:TestRoot 'external-forged-lock\receipt.json') `
            -Identity $script:GateIdentity -ProfileFileSha256 $script:GateProfileSha -ProfileCanonicalSha256 $script:GateProfileCanonicalSha
        $lockPath = Join-Path $evidenceRoot 'candidate-lock.json'
        New-V02ReleaseGateTestCandidateLock -Path $lockPath -Identity $script:GateIdentity `
            -ProfileFileSha256 $script:GateProfileSha -ProfileCanonicalSha256 $script:GateProfileCanonicalSha -Authority $authority -IndependentReceipt $receipt | Out-Null
        $forged = Get-Content -LiteralPath $lockPath -Raw | ConvertFrom-Json
        $forged.Authority.Reference = 'Plan/forged-authority.json'
        Write-V02ReleaseGateTestJson -Path $lockPath -Value $forged | Out-Null
        Assert-V02ReleaseGateTestThrows {
            Read-V02ReleaseGateCandidateLock -Path $lockPath -EvidenceRoot $evidenceRoot `
                -ExpectedSourceCommit $script:GateIdentity.Commit -ExpectedSourceTree $script:GateIdentity.Tree `
                -PackageProfilePath $script:GateProfilePath -RepositoryRoot $script:GateRepositoryRoot `
                -AuthorityReferencePath (Join-Path $script:GateRepositoryRoot 'Plan\DECISIONS.md') -IndependentCandidateReceiptPath $receipt.Path
        } 'authority source'
    }

    Invoke-V02ReleaseGateTestCase 'candidate source/tree/profile drift fails closed' {
        $evidenceRoot = Join-Path $script:TestRoot 'drift-lock'
        New-V02ReleaseGateTestDirectory -Path $evidenceRoot
        $authority = Read-V02ReleaseGateAuthorityReference -RepositoryRoot $script:GateRepositoryRoot `
            -AuthorityReferencePath (Join-Path $script:GateRepositoryRoot 'Plan\DECISIONS.md')
        $receipt = New-V02ReleaseGateTestExternalIndependentReceipt -Path (Join-Path $script:TestRoot 'external-drift-lock\receipt.json') `
            -Identity $script:GateIdentity -ProfileFileSha256 $script:GateProfileSha -ProfileCanonicalSha256 $script:GateProfileCanonicalSha
        $lockPath = Join-Path $evidenceRoot 'candidate-lock.json'
        New-V02ReleaseGateTestCandidateLock -Path $lockPath -Identity $script:GateIdentity `
            -ProfileFileSha256 $script:GateProfileSha -ProfileCanonicalSha256 $script:GateProfileCanonicalSha -Authority $authority -IndependentReceipt $receipt | Out-Null
        $drifted = Get-Content -LiteralPath $lockPath -Raw | ConvertFrom-Json
        $drifted.SourceTree = ('a' * 40)
        Write-V02ReleaseGateTestJson -Path $lockPath -Value $drifted | Out-Null
        Assert-V02ReleaseGateTestThrows {
            Read-V02ReleaseGateCandidateLock -Path $lockPath -EvidenceRoot $evidenceRoot `
                -ExpectedSourceCommit $script:GateIdentity.Commit -ExpectedSourceTree $script:GateIdentity.Tree `
                -PackageProfilePath $script:GateProfilePath -RepositoryRoot $script:GateRepositoryRoot `
                -AuthorityReferencePath (Join-Path $script:GateRepositoryRoot 'Plan\DECISIONS.md') -IndependentCandidateReceiptPath $receipt.Path
        } 'source tree'
        New-V02ReleaseGateTestCandidateLock -Path $lockPath -Identity $script:GateIdentity `
            -ProfileFileSha256 $script:GateProfileSha -ProfileCanonicalSha256 $script:GateProfileCanonicalSha -Authority $authority -IndependentReceipt $receipt | Out-Null
        $drifted = Get-Content -LiteralPath $lockPath -Raw | ConvertFrom-Json
        $drifted.ProfileFileSha256 = ('a' * 64)
        Write-V02ReleaseGateTestJson -Path $lockPath -Value $drifted | Out-Null
        Assert-V02ReleaseGateTestThrows {
            Read-V02ReleaseGateCandidateLock -Path $lockPath -EvidenceRoot $evidenceRoot `
                -ExpectedSourceCommit $script:GateIdentity.Commit -ExpectedSourceTree $script:GateIdentity.Tree `
                -PackageProfilePath $script:GateProfilePath -RepositoryRoot $script:GateRepositoryRoot `
                -AuthorityReferencePath (Join-Path $script:GateRepositoryRoot 'Plan\DECISIONS.md') -IndependentCandidateReceiptPath $receipt.Path
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
        $issue9Path = Join-Path $evidenceRoot 'issue9.json'; Write-V02ReleaseGateTestText -Path $issue9Path -Text 'issue9' | Out-Null
        $githubPath = Join-Path $evidenceRoot 'github.json'; New-V02ReleaseGateTestGitHubSnapshot -Path $githubPath | Out-Null
        $renderer = [pscustomobject][ordered]@{ ManifestPath = $rendererPath; ManifestSha256 = Get-V02ReleaseGateFileSha256 -Path $rendererPath }
        $matrix = [pscustomobject][ordered]@{ ManifestPath = $matrixPath; ManifestFileSha256 = Get-V02ReleaseGateFileSha256 -Path $matrixPath }
        $issue9 = [pscustomobject][ordered]@{ CandidatePath = $issue9Path; CandidateSha256 = Get-V02ReleaseGateFileSha256 -Path $issue9Path }
        $reviewPath = Join-Path $evidenceRoot 'human-review.json'
        New-V02ReleaseGateTestHumanReview -Path $reviewPath -EvidenceRoot $evidenceRoot -Package $package `
            -Renderer $renderer -Matrix $matrix -Issue9 $issue9 -GitHubPath $githubPath -GitHubSha (Get-V02ReleaseGateFileSha256 -Path $githubPath) `
            -Identity $script:GateIdentity | Out-Null
        $review = Read-V02ReleaseGateJsonFile -Path $reviewPath -Context 'test Human review'
        $disposition = Assert-V02ReleaseGateHumanReview -Review $review.Value -ReviewPath $review.Path `
            -ExpectedSourceCommit $script:GateIdentity.Commit -ExpectedSourceTree $script:GateIdentity.Tree `
            -Package $package -Renderer $renderer -Matrix $matrix -Issue9 $issue9 -GitHubSnapshotPath $githubPath `
            -GitHubSnapshotSha256 (Get-V02ReleaseGateFileSha256 -Path $githubPath) -EvidenceRoot $evidenceRoot
        if ($disposition.Status -cne 'NOT_OBSERVED' -or $disposition.Authenticated) { throw 'Local Human GO was credited.' }
        if ($script:V02ReleaseGateHumanArtifactCheckIds -notcontains 'issue-9-acceptance') {
            throw 'Issue #9 acceptance is missing from the canonical Human artifact check inventory.'
        }
        $missingIssue9 = $review.Value | ConvertTo-Json -Depth 100 | ConvertFrom-Json
        $missingIssue9.Reviewer.ReviewedUtc = [string]$review.Value.Reviewer.ReviewedUtc
        $missingIssue9.Checks = @($missingIssue9.Checks | Where-Object { $_.Id -cne 'issue-9-acceptance' })
        Assert-V02ReleaseGateTestThrows {
            Assert-V02ReleaseGateHumanReview -Review $missingIssue9 -ReviewPath $review.Path `
                -ExpectedSourceCommit $script:GateIdentity.Commit -ExpectedSourceTree $script:GateIdentity.Tree `
                -Package $package -Renderer $renderer -Matrix $matrix -Issue9 $issue9 -GitHubSnapshotPath $githubPath `
                -GitHubSnapshotSha256 (Get-V02ReleaseGateFileSha256 -Path $githubPath) -EvidenceRoot $evidenceRoot
        } 'exactly'
        $extraIssue9 = $review.Value | ConvertTo-Json -Depth 100 | ConvertFrom-Json
        $extraIssue9.Reviewer.ReviewedUtc = [string]$review.Value.Reviewer.ReviewedUtc
        $extraIssue9.Checks = @($extraIssue9.Checks) + @($extraIssue9.Checks | Where-Object { $_.Id -ceq 'issue-9-acceptance' } | Select-Object -First 1)
        Assert-V02ReleaseGateTestThrows {
            Assert-V02ReleaseGateHumanReview -Review $extraIssue9 -ReviewPath $review.Path `
                -ExpectedSourceCommit $script:GateIdentity.Commit -ExpectedSourceTree $script:GateIdentity.Tree `
                -Package $package -Renderer $renderer -Matrix $matrix -Issue9 $issue9 -GitHubSnapshotPath $githubPath `
                -GitHubSnapshotSha256 (Get-V02ReleaseGateFileSha256 -Path $githubPath) -EvidenceRoot $evidenceRoot
        } 'exactly'
        $mismatchedIssue9 = $review.Value | ConvertTo-Json -Depth 100 | ConvertFrom-Json
        $mismatchedIssue9.Reviewer.ReviewedUtc = [string]$review.Value.Reviewer.ReviewedUtc
        $mismatchedIssue9.Candidate.Issue9CandidateSha256 = ('9' * 64)
        $issue9Mismatch = [pscustomobject][ordered]@{ CandidatePath = $issue9.CandidatePath; CandidateSha256 = ('9' * 64) }
        Assert-V02ReleaseGateTestThrows {
            Assert-V02ReleaseGateHumanReview -Review $mismatchedIssue9 -ReviewPath $review.Path `
                -ExpectedSourceCommit $script:GateIdentity.Commit -ExpectedSourceTree $script:GateIdentity.Tree `
                -Package $package -Renderer $renderer -Matrix $matrix -Issue9 $issue9Mismatch -GitHubSnapshotPath $githubPath `
                -GitHubSnapshotSha256 (Get-V02ReleaseGateFileSha256 -Path $githubPath) -EvidenceRoot $evidenceRoot
        } 'Issue #9 candidate artifact binding'
        $tampered = $review.Value
        $tampered.Checks[0].Binding = 'HumanCheck:renderer-compatibility'
        Assert-V02ReleaseGateTestThrows {
            Assert-V02ReleaseGateHumanReview -Review $tampered -ReviewPath $review.Path `
                -ExpectedSourceCommit $script:GateIdentity.Commit -ExpectedSourceTree $script:GateIdentity.Tree `
                -Package $package -Renderer $renderer -Matrix $matrix -Issue9 $issue9 -GitHubSnapshotPath $githubPath `
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
                -Package $package -Renderer $renderer -Matrix $matrix -Issue9 $issue9 -GitHubSnapshotPath $githubPath `
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
            Issue9CandidateSha256 = ('3' * 64)
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
        $issue9 = [pscustomobject][ordered]@{ CandidateSha256 = $lock.Issue9CandidateSha256 }
        Assert-V02ReleaseGateCandidateByteBinding -CandidateLock $lock -Package $package -Renderer $renderer -Matrix $matrix -Issue9 $issue9
        $package.ArchiveSha256 = ('9' * 64)
        Assert-V02ReleaseGateTestThrows {
            Assert-V02ReleaseGateCandidateByteBinding -CandidateLock $lock -Package $package -Renderer $renderer -Matrix $matrix -Issue9 $issue9
        } 'PackageArchiveSha256'
        $package.ArchiveSha256 = $lock.PackageArchiveSha256
        $issue9.CandidateSha256 = ('4' * 64)
        Assert-V02ReleaseGateTestThrows {
            Assert-V02ReleaseGateCandidateByteBinding -CandidateLock $lock -Package $package -Renderer $renderer -Matrix $matrix -Issue9 $issue9
        } 'Issue9CandidateSha256'
    }

    Invoke-V02ReleaseGateTestCase 'typed Issue9 candidate rejects missing extra stale unbound and fixture authority' {
        $fixture = New-V02ReleaseGateTestIssue9Candidate -Root (Join-Path $script:TestRoot 'issue9-typed') -Identity $script:GateIdentity
        Assert-V02ReleaseGateIssue9CandidateBinding -Candidate $fixture.Candidate -Context $fixture.Context -Package $fixture.Package -Matrix $fixture.Matrix `
            -ExpectedSourceCommit $script:GateIdentity.Commit -ExpectedSourceTree $script:GateIdentity.Tree

        $extra = $fixture.Candidate | ConvertTo-Json -Depth 100 | ConvertFrom-Json
        $extra | Add-Member -MemberType NoteProperty -Name HumanAuthority -Value 'caller-authored'
        Assert-V02ReleaseGateTestThrows {
            Assert-V02ReleaseGateIssue9CandidateBinding -Candidate $extra -Context $fixture.Context -Package $fixture.Package -Matrix $fixture.Matrix `
                -ExpectedSourceCommit $script:GateIdentity.Commit -ExpectedSourceTree $script:GateIdentity.Tree
        } 'exactly'
        $missing = $fixture.Candidate | ConvertTo-Json -Depth 100 | ConvertFrom-Json
        $missing.Languages[0].PSObject.Properties.Remove('Lifecycle')
        Assert-V02ReleaseGateTestThrows {
            Assert-V02ReleaseGateIssue9CandidateBinding -Candidate $missing -Context $fixture.Context -Package $fixture.Package -Matrix $fixture.Matrix `
                -ExpectedSourceCommit $script:GateIdentity.Commit -ExpectedSourceTree $script:GateIdentity.Tree
        } 'exactly'
        $stale = $fixture.Candidate | ConvertTo-Json -Depth 100 | ConvertFrom-Json
        $stale.Source.TreeSha = ('a' * 40)
        Assert-V02ReleaseGateTestThrows {
            Assert-V02ReleaseGateIssue9CandidateBinding -Candidate $stale -Context $fixture.Context -Package $fixture.Package -Matrix $fixture.Matrix `
                -ExpectedSourceCommit $script:GateIdentity.Commit -ExpectedSourceTree $script:GateIdentity.Tree
        } 'source tree'
        $unbound = $fixture.Candidate | ConvertTo-Json -Depth 100 | ConvertFrom-Json
        $unbound.Package.ArchiveSha256 = ('0' * 64)
        Assert-V02ReleaseGateTestThrows {
            Assert-V02ReleaseGateIssue9CandidateBinding -Candidate $unbound -Context $fixture.Context -Package $fixture.Package -Matrix $fixture.Matrix `
                -ExpectedSourceCommit $script:GateIdentity.Commit -ExpectedSourceTree $script:GateIdentity.Tree
        } 'ArchiveSha256'
        $fixtureAuthority = $fixture.Candidate | ConvertTo-Json -Depth 100 | ConvertFrom-Json
        $fixtureAuthority.EvidenceBoundary.FixtureMode = $true
        Assert-V02ReleaseGateTestThrows {
            Assert-V02ReleaseGateIssue9CandidateBinding -Candidate $fixtureAuthority -Context $fixture.Context -Package $fixture.Package -Matrix $fixture.Matrix `
                -ExpectedSourceCommit $script:GateIdentity.Commit -ExpectedSourceTree $script:GateIdentity.Tree
        } 'fixture mode'

        $outsideCapture = Join-Path $script:TestRoot 'issue9-outside-capture.png'
        Write-V02ReleaseGateTestText $outsideCapture 'outside UI root' | Out-Null
        $escapedCapture = $fixture.Candidate | ConvertTo-Json -Depth 100 | ConvertFrom-Json
        $escapedCapture.Languages[0].Pages[0].UiCapturePath = $outsideCapture
        $escapedCapture.Languages[0].Pages[0].UiCaptureSha256 = Get-V02ReleaseGateFileSha256 $outsideCapture
        Assert-V02ReleaseGateTestThrows {
            Assert-V02ReleaseGateIssue9CandidateBinding -Candidate $escapedCapture -Context $fixture.Context -Package $fixture.Package -Matrix $fixture.Matrix `
                -ExpectedSourceCommit $script:GateIdentity.Commit -ExpectedSourceTree $script:GateIdentity.Tree
        } 'escapes its evidence root'

        $thaiUiRoot = [string]$fixture.Candidate.Languages[0].UiEvidenceDirectory
        $aliasDirectory = Join-Path $thaiUiRoot 'canonical-alias-segment'
        New-V02ReleaseGateTestDirectory $aliasDirectory
        $nonCanonical = $fixture.Candidate | ConvertTo-Json -Depth 100 | ConvertFrom-Json
        $nonCanonical.Languages[0].Pages[0].UiCapturePath = Join-Path $aliasDirectory '..\Overview.png'
        Assert-V02ReleaseGateTestThrows {
            Assert-V02ReleaseGateIssue9CandidateBinding -Candidate $nonCanonical -Context $fixture.Context -Package $fixture.Package -Matrix $fixture.Matrix `
                -ExpectedSourceCommit $script:GateIdentity.Commit -ExpectedSourceTree $script:GateIdentity.Tree
        } 'not canonical'

        $outsideDirectory = Join-Path $script:TestRoot 'issue9-capture-reparse-target'
        New-V02ReleaseGateTestDirectory $outsideDirectory
        $reparseTarget = Join-Path $outsideDirectory 'capture.png'
        Write-V02ReleaseGateTestText $reparseTarget 'reparse target' | Out-Null
        $captureJunction = Join-Path $thaiUiRoot 'capture-reparse-alias'
        New-Item -ItemType Junction -Path $captureJunction -Target $outsideDirectory | Out-Null
        $reparseCapture = $fixture.Candidate | ConvertTo-Json -Depth 100 | ConvertFrom-Json
        $reparseCapture.Languages[0].Pages[0].UiCapturePath = Join-Path $captureJunction 'capture.png'
        $reparseCapture.Languages[0].Pages[0].UiCaptureSha256 = Get-V02ReleaseGateFileSha256 $reparseTarget
        Assert-V02ReleaseGateTestThrows {
            Assert-V02ReleaseGateIssue9CandidateBinding -Candidate $reparseCapture -Context $fixture.Context -Package $fixture.Package -Matrix $fixture.Matrix `
                -ExpectedSourceCommit $script:GateIdentity.Commit -ExpectedSourceTree $script:GateIdentity.Tree
        } 'reparse'

        $hardlinkSource = Join-Path $script:TestRoot 'issue9-capture-hardlink-source.png'
        Write-V02ReleaseGateTestText $hardlinkSource 'hardlink source' | Out-Null
        $hardlinkAlias = Join-Path $thaiUiRoot 'hardlink-alias.png'
        New-Item -ItemType HardLink -Path $hardlinkAlias -Target $hardlinkSource | Out-Null
        $hardlinkedCapture = $fixture.Candidate | ConvertTo-Json -Depth 100 | ConvertFrom-Json
        $hardlinkedCapture.Languages[0].Pages[0].UiCapturePath = $hardlinkAlias
        $hardlinkedCapture.Languages[0].Pages[0].UiCaptureSha256 = Get-V02ReleaseGateFileSha256 $hardlinkAlias
        Assert-V02ReleaseGateTestThrows {
            Assert-V02ReleaseGateIssue9CandidateBinding -Candidate $hardlinkedCapture -Context $fixture.Context -Package $fixture.Package -Matrix $fixture.Matrix `
                -ExpectedSourceCommit $script:GateIdentity.Commit -ExpectedSourceTree $script:GateIdentity.Tree
        } 'hardlink|path alias'
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

    Invoke-V02ReleaseGateTestCase 'transitive governance set of 37 files is fully snapshot and held' {
        $snapshots = @(Get-V02ReleaseGateValidatorSnapshots -RepositoryRoot $script:GateRepositoryRoot)
        try {
            if ($snapshots.Count -ne $script:V02ReleaseGateTransitiveGovernanceRelativePaths.Count) {
                throw "Expected $($script:V02ReleaseGateTransitiveGovernanceRelativePaths.Count) governance snapshots; observed $($snapshots.Count)."
            }
            if ($snapshots.Count -ne 37) {
                throw "Expected exactly 37 governance snapshots; observed $($snapshots.Count)."
            }
            Assert-V02ReleaseGateBoundSnapshots -Snapshots $snapshots -Phase 'transitive governance stability fixture'
            foreach ($snapshot in $snapshots) {
                if ($null -eq $snapshot.HeldStream -or $snapshot.HeldStream.SafeFileHandle.IsClosed) {
                    throw "Governance file was not held open: $($snapshot.Path)"
                }
            }
        }
        finally {
            Close-V02ReleaseGateHeldSnapshots -Snapshots $snapshots
        }
    }

    Invoke-V02ReleaseGateTestCase 'Issue9 CI performance receipt soak and harness governance cannot mutate delete or disappear' {
        $required = @(
            '.github/workflows/ci.yml',
            'tools/v0.2-issue9-live-ui/Test-V02Issue9LiveUiAcceptance.ps1',
            'tools/v0.2-issue9-live-ui/Issue9LiveUi.Common.ps1',
            'tools/v0.2-issue9-live-ui/issue9-live-ui-candidate.schema.json',
            'tools/v0.2-renderer-compatibility/Invoke-V02PerformanceMeasurement.ps1',
            'tools/v0.2-renderer-compatibility/New-V02PerformanceEvidenceReceipt.ps1',
            'tools/v0.2-renderer-compatibility/Invoke-V02SoakMeasurement.ps1',
            'tools/v0.2-renderer-compatibility/lib/V02PerformanceTestHarness.ps1',
            'tools/v0.2-renderer-compatibility/lib/V02SoakTestHarness.ps1'
        )
        foreach ($path in $required) {
            if ($script:V02ReleaseGateTransitiveGovernanceRelativePaths -cnotcontains $path) { throw "Missing governed production path: $path" }
        }
        $fixtureRepo = New-V02ReleaseGateTestCleanRepository
        try {
            $snapshots = @(Get-V02ReleaseGateValidatorSnapshots -RepositoryRoot $fixtureRepo)
            try {
                foreach ($relative in @($required[1], $required[4], $required[0])) {
                    $target = Join-Path $fixtureRepo ($relative -replace '/', '\')
                    $mutationSucceeded = $false
                    try { [IO.File]::WriteAllText($target, 'mutated'); $mutationSucceeded = $true } catch { $mutationSucceeded = $false }
                    if ($mutationSucceeded) { throw "Governed mutation unexpectedly succeeded: $relative" }
                    $deletionSucceeded = $false
                    try { Remove-Item -LiteralPath $target -Force; $deletionSucceeded = $true } catch { $deletionSucceeded = $false }
                    if ($deletionSucceeded) { throw "Governed deletion unexpectedly succeeded: $relative" }
                }
                Assert-V02ReleaseGateBoundSnapshots -Snapshots $snapshots -Phase 'Issue9/performance/CI hostile stability'
            }
            finally { Close-V02ReleaseGateHeldSnapshots -Snapshots $snapshots }

            $missingPath = Join-Path $fixtureRepo ($required[2] -replace '/', '\')
            Remove-Item -LiteralPath $missingPath -Force
            Assert-V02ReleaseGateTestThrows {
                $unexpected = @(Get-V02ReleaseGateValidatorSnapshots -RepositoryRoot $fixtureRepo)
                Close-V02ReleaseGateHeldSnapshots -Snapshots $unexpected
            } 'missing'
        }
        finally {
            if (Test-Path -LiteralPath $fixtureRepo) { Remove-Item -LiteralPath $fixtureRepo -Recurse -Force }
        }
    }

    Invoke-V02ReleaseGateTestCase 'tampering with reference PNGs or schemas fails closed' {
        $pngPath = Join-Path $script:GateRepositoryRoot 'docs\design\reference\01-overview.png'
        $copy = Join-Path $script:TestRoot 'png-copy.png'
        Copy-Item -LiteralPath $pngPath -Destination $copy
        try {
            $copySnapshot = Get-V02ReleaseGateStableFileSnapshot -Path $copy -Context 'PNG copy fixture'
            $original = [IO.File]::ReadAllBytes($copy)
            $mutated = [byte[]]::new([int]($original.Length + 1))
            [Array]::Copy($original, 0, $mutated, 0, $original.Length)
            $mutated[$original.Length] = 0xFF
            [IO.File]::WriteAllBytes($copy, $mutated)
            Assert-V02ReleaseGateTestThrows {
                Assert-V02ReleaseGateSnapshotUnchanged -Snapshot $copySnapshot -Context 'PNG drift fixture' | Out-Null
            } 'length|bytes'
        }
        finally {
            if (Test-Path -LiteralPath $copy) { Remove-Item -LiteralPath $copy -Force }
        }
    }

    Invoke-V02ReleaseGateTestCase 'production-path Invoke-V02ReleaseGate held swap-execute-restore prevents file mutation and preflight drift fails closed' {
        $fixtureRepo = New-V02ReleaseGateTestCleanRepository
        try {
            $identity = Get-V02ReleaseGateTestRepositoryIdentity -RepositoryRoot $fixtureRepo
            $target = Join-Path $fixtureRepo 'Plan\DECISIONS.md'
            $originalBytes = [IO.File]::ReadAllBytes($target)

            # Preflight drift fails closed
            Write-V02ReleaseGateTestText -Path $target -Text 'tampered authority decision' | Out-Null
            Assert-V02ReleaseGateTestThrows {
                $driftIdentity = Get-V02ReleaseGateTestRepositoryIdentity -RepositoryRoot $fixtureRepo
                Assert-V02ReleaseGateGitIdentity $driftIdentity $identity.Commit $identity.Tree 'Preflight drift fixture'
            } 'clean|Pending paths'
            [IO.File]::WriteAllBytes($target, $originalBytes)

            # While a governance snapshot is held with -KeepOpen, attempts to overwrite must fail
            $snapshot = Get-V02ReleaseGateStableFileSnapshot -Path $target -Context 'production-path held fixture' -KeepOpen
            $writeSucceededWhileHeld = $false
            try {
                [IO.File]::WriteAllBytes($target, [byte[]]@(0x01, 0x02))
                $writeSucceededWhileHeld = $true
            }
            catch {
                $writeSucceededWhileHeld = $false
            }
            finally {
                Close-V02ReleaseGateHeldSnapshots -Snapshots @($snapshot)
            }
            if ($writeSucceededWhileHeld) {
                throw 'Write unexpectedly succeeded on a held governance snapshot.'
            }
            $restored = Get-V02ReleaseGateStableFileSnapshot -Path $target -Context 'restored fixture'
            if ($restored.Sha256 -cne $snapshot.Sha256) {
                throw 'Governance file bytes were corrupted during held test.'
            }
        }
        finally {
            if (Test-Path -LiteralPath $fixtureRepo) { Remove-Item -LiteralPath $fixtureRepo -Recurse -Force }
        }
    }

    Invoke-V02ReleaseGateTestCase 'all bound artifact file streams remain held open and locked through execution' {
        $root = Join-Path $script:TestRoot 'bound-stream-test'
        New-V02ReleaseGateTestDirectory -Path $root
        $testFile = Join-Path $root 'bound-artifact.json'
        Write-V02ReleaseGateTestText -Path $testFile -Text '{"test":true}' | Out-Null
        $snapshot = Get-V02ReleaseGateStableFileSnapshot -Path $testFile -Context 'bound stream fixture' -KeepOpen
        $streamHandle = $snapshot.HeldStream.SafeFileHandle
        $parentHandle = $snapshot.HeldParentHandle
        try {
            if ($null -eq $snapshot.HeldStream -or $streamHandle.IsClosed) {
                throw 'Held stream was not kept open.'
            }
            if ($null -eq $parentHandle -or $parentHandle.IsClosed) {
                throw 'Held parent handle was not kept open.'
            }
            $streamWriteSucceeded = $false
            try {
                [IO.File]::WriteAllBytes($testFile, [byte[]]@(0x00))
                $streamWriteSucceeded = $true
            }
            catch {
                $streamWriteSucceeded = $false
            }
            if ($streamWriteSucceeded) {
                throw 'Write unexpectedly succeeded on held bound artifact stream.'
            }
        }
        finally {
            Close-V02ReleaseGateHeldSnapshots -Snapshots @($snapshot)
        }
        if (-not $streamHandle.IsClosed) {
            throw 'Held stream handle was not closed by Close-V02ReleaseGateHeldSnapshots.'
        }
        if (-not $parentHandle.IsClosed) {
            throw 'Held parent directory handle was not closed by Close-V02ReleaseGateHeldSnapshots.'
        }
    }

    Invoke-V02ReleaseGateTestCase 'production gate exposes no injectable validators' {
        $parameters = @((Get-Command Invoke-V02ReleaseGate -CommandType Function).Parameters.Keys)
        foreach ($name in @('PackageValidator', 'RendererValidator', 'RuntimeMatrixValidator', 'Issue9Validator')) {
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
            foreach ($file in @('package-identity.json', 'archive.zip', 'renderer.json', 'matrix.json', 'issue9.json', 'contract.json', 'synthetic.json', 'human.json', 'github.json')) {
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
                Issue9CandidatePath = Join-Path $root 'issue9.json'
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
