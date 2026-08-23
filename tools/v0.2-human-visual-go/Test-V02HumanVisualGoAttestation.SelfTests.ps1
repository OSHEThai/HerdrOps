#requires -Version 5.1

[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'HumanVisualGo.Common.ps1')

$script:PositiveCases = 0
$script:NegativeCases = 0

function Pass([string]$Name) {
    $script:PositiveCases++
    "PASS positive: $Name"
}

function Pass-Negative([string]$Name) {
    $script:NegativeCases++
    "PASS negative: $Name"
}

function Copy-HumanTestValue($Value) {
    $json = $Value | ConvertTo-Json -Depth 100
    if ($PSVersionTable.PSVersion.Major -ge 7) { return ($json | ConvertFrom-Json -DateKind String) }
    return ($json | ConvertFrom-Json)
}

function Write-HumanCanonicalJson {
    param([Parameter(Mandatory = $true)]$Value, [Parameter(Mandatory = $true)][string]$Path, [Parameter(Mandatory = $true)][string]$RepositoryRoot)
    $canonical = Get-HumanVisualGoCanonicalText -Value $Value -RepositoryRoot $RepositoryRoot
    [IO.File]::WriteAllText($Path, $canonical + "`n", [Text.UTF8Encoding]::new($false))
}

function Expect-HumanFailure {
    param([Parameter(Mandatory = $true)][string]$Name, [Parameter(Mandatory = $true)][scriptblock]$Action)
    $failed = $false
    try { & $Action | Out-Null } catch { $failed = $true }
    if (-not $failed) { throw "Hostile case '$Name' did not fail closed." }
    Pass-Negative $Name
}

# Reuse the renderer self-test's deterministic package/manifest fixture builders
# without executing its main test body. The fixture is a clean temporary Git
# repository, so the production renderer verifier remains in its normal exact-
# candidate mode.
$rendererSelfTestPath = Join-Path $PSScriptRoot '..\v0.2-renderer-compatibility\Test-V02RendererCompatibilityManifest.SelfTests.ps1'
$script:HumanTestToolRoot = $PSScriptRoot
$rendererFixtureDefinitions = ((Get-Content -LiteralPath $rendererSelfTestPath)[10..43] -join [Environment]::NewLine).Replace('$PSScriptRoot', '$script:HumanTestToolRoot')
Invoke-Expression $rendererFixtureDefinitions

function New-HumanMatrixReceipt {
    param([Parameter(Mandatory = $true)][string]$CaseId, [Parameter(Mandatory = $true)][string]$Timestamp)
    return [pscustomobject][ordered]@{
        caseId = $CaseId
        observations = @([pscustomobject][ordered]@{ ordinal = 0; observedUtc = $Timestamp; outcome = 'PASS'; notes = 'synthetic raw observation' })
        aggregateStatus = 'PASS'
    }
}

function Complete-HumanFixture {
    param([Parameter(Mandatory = $true)]$Fixture)

    $manifest = Copy-HumanTestValue $Fixture.Manifest
    $captureIndex = 0
    foreach ($capture in @($manifest.captures)) {
        $referencePath = Join-Path $Fixture.RepositoryRoot ([string]$manifest.comparison.results[$captureIndex].referenceRelativePath)
        $capturePath = Join-Path $Fixture.Root ([string]$capture.relativePath)
        Copy-Item -LiteralPath $referencePath -Destination $capturePath -Force
        $png = Get-RendererPngIdentity -Root $Fixture.Root -Path $capturePath -Context "fixture capture $captureIndex"
        $capture.widthPixels = $png.Width
        $capture.heightPixels = $png.Height
        $capture.bytes = [long]$png.Bytes
        $capture.sha256 = [string]$png.Sha256
        $result = $manifest.comparison.results[$captureIndex]
        $result.status = 'PASS'
        $result.differentPixels = 0
        $result.differentPixelPercent = 0
        $result.maximumChannelDelta = 0
        $result.nonmaskedDifferenceCount = 0
        $result.disposition = 'exact held-byte equality; no visual difference'
        $captureIndex++
    }

    $producer = (Read-RendererEvidenceReceipt $manifest.rendererEvidence.producerReport 'fixture producer' $Fixture.Root $Fixture.RepositoryRoot).Value
    for ($index = 0; $index -lt @($producer.captures).Count; $index++) {
        $producer.captures[$index].sha256 = [string]$manifest.captures[$index].sha256
        $producer.captures[$index].observedUtc = [string]$manifest.captures[$index].observedUtc
    }
    $manifest.rendererEvidence.producerReport = New-EvidenceBinding $Fixture.Root 'producer/complete-renderer-report.json' $producer $Fixture.RepositoryRoot

    foreach ($group in @('displayCases', 'mixedDpiTransitions', 'accessibilityCases', 'supportedEnvironmentCases')) {
        $caseIndex = 0
        foreach ($case in @($manifest.matrices.$group)) {
            $timestamp = '2026-08-22T13:{0:00}:{1:00}.0000000+00:00' -f $caseIndex, 1
            $receipt = New-HumanMatrixReceipt -CaseId ([string]$case.id) -Timestamp $timestamp
            $case.status = 'PASS'
            $case.notes = 'synthetic complete matrix receipt'
            $case.evidenceReceipt = New-EvidenceBinding $Fixture.Root ("matrix/{0}/{1}.json" -f $group, $caseIndex) $receipt $Fixture.RepositoryRoot
            $caseIndex++
        }
    }

    $orders = @()
    foreach ($orderName in @('AB', 'BA')) {
        $warmupSample = [pscustomobject][ordered]@{
            cpuBasisPoints = 50
            workingSetMaximumBytes = 104857600
            latencyMicroseconds = @(1..20 | ForEach-Object { 100000 })
            uiStallMicroseconds = @(1..20 | ForEach-Object { 10000 })
        }
        $warmup = [pscustomobject][ordered]@{ ordinal = 0; observedUtc = '2026-08-22T13:40:00.0000000Z'; a = $warmupSample; b = (Copy-HumanTestValue $warmupSample) }
        $repetitions = @()
        for ($index = 0; $index -lt 5; $index++) {
            $sampleA = [pscustomobject][ordered]@{
                cpuBasisPoints = 50
                workingSetMaximumBytes = 104857600
                latencyMicroseconds = @(1..20 | ForEach-Object { 100000 })
                uiStallMicroseconds = @(1..20 | ForEach-Object { 10000 })
            }
            $sampleB = Copy-HumanTestValue $sampleA
            $second = $index + 1
            if ($orderName -ceq 'BA') { $second += 10 }
            $repetitions += [pscustomobject][ordered]@{
                ordinal = $index
                observedUtc = ('2026-08-22T13:4{0}:{1:00}.0000000Z' -f $(if ($orderName -ceq 'BA') { 1 } else { 0 }), $second)
                a = $sampleA
                b = $sampleB
            }
        }
        $orders += [pscustomobject][ordered]@{ order = $orderName; warmup = @($warmup); repetitions = $repetitions }
    }
    $soakBins = @()
    for ($index = 0; $index -lt 24; $index++) {
        $power = if ($index -lt 12) { 'AC' } else { 'Battery' }
        $ordinal = $index % 12
        $soakBins += [pscustomobject][ordered]@{
            powerSource = $power
            ordinal = $ordinal
            durationMinutes = 5
            observedUtc = ('2026-08-22T14:{0:00}:00.0000000Z' -f $index)
            workingSetStartBytes = 104857600
            workingSetEndBytes = 104857600
            rendererStable = $true
        }
    }
    $rawMeasurements = [pscustomobject][ordered]@{ orders = $orders; soakBins = $soakBins }
    $rawBinding = [pscustomobject](New-EvidenceBinding $Fixture.Root 'performance/complete-raw-observations.json' $rawMeasurements $Fixture.RepositoryRoot)
    $performanceReceipt = [pscustomobject][ordered]@{
        provenance = New-RendererPerformanceProvenance $manifest.candidate $manifest.environment.session
        rawSource = $rawBinding
        orders = $orders
        soakBins = $soakBins
        aggregateStatus = 'PASS'
    }
    $manifest.performanceProtocol.samplesStatus = 'PASS'
    $manifest.performanceProtocol.evidenceReceipt = New-EvidenceBinding $Fixture.Root 'performance/complete-receipt.json' $performanceReceipt $Fixture.RepositoryRoot

    $manifest.review.defects = @([pscustomobject][ordered]@{
        id = 'VIS-FIXTURE-001'
        severity = 'P2'
        summary = 'Synthetic fixture has a closed visual disposition.'
        status = 'Resolved'
        disposition = 'Resolved in the synthetic fixture before candidate hand-off.'
    })
    $manifest.review.decision = 'NOT_OBSERVED'
    $manifest.evidenceBoundary.humanReview = 'NOT_OBSERVED'
    $completePath = Join-Path $Fixture.Root 'renderer-compatibility-complete.json'
    Write-TestJson $manifest $completePath
    $manifestRawSha = (Get-FileHash -LiteralPath $completePath -Algorithm SHA256).Hash
    $reviewEvidence = [pscustomobject][ordered]@{
        '$id' = 'https://herdrops.local/schema/v0.2/human-visual-review-evidence.schema.json'
        schemaVersion = 1
        evidenceClassification = 'HumanVisualReviewEvidence'
        issue = 11
        compatibilityIssue = 149
        candidate = [pscustomobject][ordered]@{
            sourceCommitSha = [string]$manifest.candidate.source.commitSha
            sourceTreeSha = [string]$manifest.candidate.source.treeSha
            rendererManifestSha256 = [string]$manifestRawSha
        }
        comparisons = @($manifest.comparison.results | ForEach-Object {
            [pscustomobject][ordered]@{ key = "$($_.language)|$($_.captureName)"; status = [string]$_.status; referenceRelativePath = [string]$_.referenceRelativePath; disposition = [string]$_.disposition }
        })
        checks = @($script:RendererVisualChecks | ForEach-Object {
            [pscustomobject][ordered]@{ id = [string]$_; status = 'PASS'; notes = 'Synthetic governed visual checklist evidence; final Human authority remains external.' }
        })
        defects = @(Copy-HumanTestValue $manifest.review.defects)
        evidenceBoundary = [pscustomobject][ordered]@{ humanReview = 'NOT_OBSERVED'; actualHerdrRuntime = 'NOT_OBSERVED'; release = 'NOT_OBSERVED'; creditGranted = $false }
    }
    $reviewPath = Join-Path $Fixture.Root 'human-review/visual-review-evidence.json'
    New-Item -ItemType Directory -Path (Split-Path -Parent $reviewPath) -Force | Out-Null
    Write-HumanCanonicalJson -Value $reviewEvidence -Path $reviewPath -RepositoryRoot $Fixture.RepositoryRoot
    return [pscustomobject]@{ Root = $Fixture.Root; RepositoryRoot = $Fixture.RepositoryRoot; Path = $completePath; ReviewPath = $reviewPath; Manifest = $manifest; ReviewEvidence = $reviewEvidence }
}

function New-HumanExternalAttestation {
    param(
        [Parameter(Mandatory = $true)]$Candidate,
        [Parameter(Mandatory = $true)][string]$CandidatePath,
        [Parameter(Mandatory = $true)][string]$RepositoryRoot,
        [ValidateSet('GO', 'NO_GO')][string]$Decision = 'GO'
    )
    $candidateCanonical = Get-HumanVisualGoCanonicalText -Value $Candidate -RepositoryRoot $RepositoryRoot
    $candidateBytes = [IO.File]::ReadAllBytes($CandidatePath)
    return [pscustomobject][ordered]@{
        '$id' = $script:HumanVisualGoAttestationSchemaId
        schemaVersion = 1
        evidenceClassification = 'ExternalHumanVisualGoAttestation'
        issue = 11
        compatibilityIssue = 149
        attestationId = 'external-human-visual-go-fixture-001'
        decision = $Decision
        decisionRationale = if ($Decision -ceq 'GO') { 'All governed visual, matrix, performance, soak, and defect checks pass.' } else { 'Synthetic reviewer deliberately records NO_GO for the hostile decision case.' }
        reviewedUtc = '2026-08-23T04:05:06.1234567Z'
        candidate = [pscustomobject][ordered]@{
            sourceCommitSha = [string]$Candidate.source.commitSha
            sourceTreeSha = [string]$Candidate.source.treeSha
            candidateFileSha256 = Get-HumanVisualGoSha256ForBytes -Bytes $candidateBytes
            candidateCanonicalSha256 = Get-HumanVisualGoSha256ForBytes -Bytes ([Text.UTF8Encoding]::new($false).GetBytes($candidateCanonical))
            rendererManifestSha256 = [string]$Candidate.rendererManifest.sha256
            packageArchiveSha256 = [string]$Candidate.package.archive.sha256
            packageAppSha256 = [string]$Candidate.package.app.sha256
            packageCoreSha256 = [string]$Candidate.package.core.sha256
            herdrExecutableSha256 = [string]$Candidate.herdr.executableSha256
            herdrBindingSha256 = [string]$Candidate.herdr.bindingSha256
            sessionBindingSha256 = [string]$Candidate.session.bindingSha256
            evidenceSetSha256 = [string]$Candidate.evidenceSetSha256
        }
        reviewer = [pscustomobject][ordered]@{
            identity = '@yutthaphon'
            role = 'HumanReviewer'
            authorityRole = 'ProductOwner'
            builderIdentity = [string]$Candidate.roles.builderIdentity
            runtimeOperatorIdentity = [string]$Candidate.roles.runtimeOperatorIdentity
            independentValidatorIdentity = [string]$Candidate.roles.independentValidatorIdentity
            identityDistinct = $true
        }
        authority = [pscustomobject][ordered]@{
            reference = 'https://external.example.invalid/herdrops/v0.2/human-attestation/fixture-001'
            authenticationMethod = $script:HumanVisualGoAttestationMethod
            authenticated = $true
            proofSha256 = ('A' * 64)
        }
        visualDispositions = @(Copy-HumanTestValue $Candidate.visualReview.comparisons)
        visualChecks = @(Copy-HumanTestValue $Candidate.visualReview.checks)
        defects = @(Copy-HumanTestValue $Candidate.defects)
        evidenceBindings = @(Copy-HumanTestValue $Candidate.evidenceBindings)
        evidenceSetSha256 = [string]$Candidate.evidenceSetSha256
        evidenceBoundary = [pscustomobject][ordered]@{ humanReview = $Decision; actualHerdrRuntime = 'NOT_OBSERVED'; release = 'NOT_OBSERVED'; creditGranted = $false }
    }
}

$temp = Join-Path ([IO.Path]::GetTempPath()) ('herdrops-human-visual-go-' + [Guid]::NewGuid().ToString('N'))
try {
    New-Item -ItemType Directory -Path $temp -Force | Out-Null
    $repo = New-TestRepository -Root (Join-Path $temp 'repo')
    $fixture = New-Fixture -Root (Join-Path $temp 'evidence') -RepositoryRoot $repo.Root -Commit $repo.Commit -Tree $repo.Tree
    $fixture = Complete-HumanFixture -Fixture $fixture
    $external = Join-Path $temp 'external'
    New-Item -ItemType Directory -Path $external -Force | Out-Null
    $candidatePath = Join-Path $external 'HumanReviewCandidate.json'
    $attestationPath = Join-Path $external 'HumanVisualGoAttestation.json'
    $candidate = New-V02HumanVisualGoCandidateCore -RendererManifestPath $fixture.Path -HumanReviewEvidencePath $fixture.ReviewPath -EvidenceRoot $fixture.Root -RepositoryRoot $fixture.RepositoryRoot -BuilderIdentity 'builder-fixture' -RuntimeOperatorIdentity 'runtime-operator-fixture' -IndependentValidatorIdentity 'independent-validator-fixture'
    $candidateReceipt = Write-V02HumanVisualGoCandidate -Candidate $candidate -OutputPath $candidatePath -RepositoryRoot $fixture.RepositoryRoot -EvidenceRoot $fixture.Root
    Pass 'builder emits only a HumanReviewCandidate with NOT_OBSERVED boundary'

    $candidateOnly = Test-V02HumanVisualGoAttestationCore -CandidatePath $candidatePath -EvidenceRoot $fixture.Root -RepositoryRoot $fixture.RepositoryRoot
    if ($candidateOnly.HumanReview -cne 'NOT_OBSERVED' -or $candidateOnly.Release -cne 'NOT_OBSERVED' -or $candidateOnly.ActualHerdrRuntime -cne 'NOT_OBSERVED' -or [bool]$candidateOnly.CreditGranted) { throw 'Candidate-only output crossed the Human/Runtime/Release boundary.' }
    Pass 'candidate-only verifier remains NOT_OBSERVED and no-credit'

    $attestation = New-HumanExternalAttestation -Candidate $candidate -CandidatePath $candidatePath -RepositoryRoot $fixture.RepositoryRoot -Decision GO
    Write-HumanCanonicalJson -Value $attestation -Path $attestationPath -RepositoryRoot $fixture.RepositoryRoot
    $go = Test-V02HumanVisualGoAttestationCore -CandidatePath $candidatePath -AttestationPath $attestationPath -EvidenceRoot $fixture.Root -RepositoryRoot $fixture.RepositoryRoot
    if ($go.HumanReview -cne 'GO' -or $go.Release -cne 'NOT_OBSERVED' -or $go.ActualHerdrRuntime -cne 'NOT_OBSERVED' -or [bool]$go.CreditGranted -or [bool]$go.ReleaseReady) { throw 'Valid external GO result crossed the Release/Runtime boundary.' }
    Pass 'valid external candidate-specific GO is accepted without Release credit'

    $noGoPath = Join-Path $external 'HumanVisualGo-NoGo.json'
    $noGo = New-HumanExternalAttestation -Candidate $candidate -CandidatePath $candidatePath -RepositoryRoot $fixture.RepositoryRoot -Decision NO_GO
    Write-HumanCanonicalJson -Value $noGo -Path $noGoPath -RepositoryRoot $fixture.RepositoryRoot
    $noGoResult = Test-V02HumanVisualGoAttestationCore -CandidatePath $candidatePath -AttestationPath $noGoPath -EvidenceRoot $fixture.Root -RepositoryRoot $fixture.RepositoryRoot
    if ($noGoResult.HumanReview -cne 'NO_GO' -or $noGoResult.Release -cne 'NOT_OBSERVED') { throw 'Valid external NO_GO was not preserved.' }
    Pass 'valid external NO_GO remains a non-release decision'

    $copiedCandidate = Join-Path $fixture.Root 'copied-candidate.json'
    Copy-Item -LiteralPath $candidatePath -Destination $copiedCandidate
    Expect-HumanFailure 'copied candidate under evidence root is rejected' { Test-V02HumanVisualGoAttestationCore -CandidatePath $copiedCandidate -AttestationPath $attestationPath -EvidenceRoot $fixture.Root -RepositoryRoot $fixture.RepositoryRoot }

    $staleAttestation = Copy-HumanTestValue $attestation
    $staleAttestation.candidate.candidateCanonicalSha256 = 'B' * 64
    $stalePath = Join-Path $external 'stale-attestation.json'
    Write-HumanCanonicalJson -Value $staleAttestation -Path $stalePath -RepositoryRoot $fixture.RepositoryRoot
    Expect-HumanFailure 'stale candidate canonical receipt' { Assert-HumanVisualGoAttestationAgainstCandidate -Candidate $candidate -Attestation $staleAttestation -CandidateFileSha256 $candidateReceipt.FileSha256 -CandidateCanonicalSha256 $candidateReceipt.CanonicalSha256 -RepositoryRoot $fixture.RepositoryRoot }

    $forgedAttestation = Copy-HumanTestValue $attestation
    $forgedAttestation.reviewer.identity = '@forged-reviewer'
    $forgedPath = Join-Path $external 'forged-attestation.json'
    Write-HumanCanonicalJson -Value $forgedAttestation -Path $forgedPath -RepositoryRoot $fixture.RepositoryRoot
    Expect-HumanFailure 'forged reviewer identity' { Assert-HumanVisualGoAttestationAgainstCandidate -Candidate $candidate -Attestation $forgedAttestation -CandidateFileSha256 $candidateReceipt.FileSha256 -CandidateCanonicalSha256 $candidateReceipt.CanonicalSha256 -RepositoryRoot $fixture.RepositoryRoot }

    $roleCollision = Copy-HumanTestValue $attestation
    $roleCollision.reviewer.builderIdentity = '@yutthaphon'
    $rolePath = Join-Path $external 'role-collision-attestation.json'
    Write-HumanCanonicalJson -Value $roleCollision -Path $rolePath -RepositoryRoot $fixture.RepositoryRoot
    Expect-HumanFailure 'reviewer identity collides with builder role' { Assert-HumanVisualGoAttestationAgainstCandidate -Candidate $candidate -Attestation $roleCollision -CandidateFileSha256 $candidateReceipt.FileSha256 -CandidateCanonicalSha256 $candidateReceipt.CanonicalSha256 -RepositoryRoot $fixture.RepositoryRoot }

    $mixedAttestation = Copy-HumanTestValue $attestation
    $mixedAttestation.candidate.sourceTreeSha = 'a' * 40
    $mixedPath = Join-Path $external 'mixed-candidate-attestation.json'
    Write-HumanCanonicalJson -Value $mixedAttestation -Path $mixedPath -RepositoryRoot $fixture.RepositoryRoot
    Expect-HumanFailure 'mixed candidate source tree' { Assert-HumanVisualGoAttestationAgainstCandidate -Candidate $candidate -Attestation $mixedAttestation -CandidateFileSha256 $candidateReceipt.FileSha256 -CandidateCanonicalSha256 $candidateReceipt.CanonicalSha256 -RepositoryRoot $fixture.RepositoryRoot }

    $missingDefect = Copy-HumanTestValue $attestation
    $missingDefect.defects = @()
    $missingDefectPath = Join-Path $external 'missing-defect-attestation.json'
    Write-HumanCanonicalJson -Value $missingDefect -Path $missingDefectPath -RepositoryRoot $fixture.RepositoryRoot
    Expect-HumanFailure 'missing defect disposition' { Assert-HumanVisualGoAttestationAgainstCandidate -Candidate $candidate -Attestation $missingDefect -CandidateFileSha256 $candidateReceipt.FileSha256 -CandidateCanonicalSha256 $candidateReceipt.CanonicalSha256 -RepositoryRoot $fixture.RepositoryRoot }

    $localAuthority = Copy-HumanTestValue $attestation
    $localAuthority.authority.reference = 'Plan/DECISIONS.md#human-go'
    $localAuthorityPath = Join-Path $external 'repository-authority-attestation.json'
    Write-HumanCanonicalJson -Value $localAuthority -Path $localAuthorityPath -RepositoryRoot $fixture.RepositoryRoot
    Expect-HumanFailure 'repository-pinned Human authority' { Assert-HumanVisualGoAttestationAgainstCandidate -Candidate $candidate -Attestation $localAuthority -CandidateFileSha256 $candidateReceipt.FileSha256 -CandidateCanonicalSha256 $candidateReceipt.CanonicalSha256 -RepositoryRoot $fixture.RepositoryRoot }

    $inflated = Copy-HumanTestValue $attestation
    $inflated.evidenceBoundary.release = 'OBSERVED'
    $inflatedPath = Join-Path $external 'inflated-attestation.json'
    Write-HumanCanonicalJson -Value $inflated -Path $inflatedPath -RepositoryRoot $fixture.RepositoryRoot
    Expect-HumanFailure 'Release inflation from Human attestation' { Assert-HumanVisualGoAttestationAgainstCandidate -Candidate $candidate -Attestation $inflated -CandidateFileSha256 $candidateReceipt.FileSha256 -CandidateCanonicalSha256 $candidateReceipt.CanonicalSha256 -RepositoryRoot $fixture.RepositoryRoot }

    $missingCapturePath = Join-Path $fixture.Root ([string]$fixture.Manifest.captures[0].relativePath)
    $missingCaptureBytes = [IO.File]::ReadAllBytes($missingCapturePath)
    Remove-Item -LiteralPath $missingCapturePath -Force
    try {
        Expect-HumanFailure 'missing governed capture' { Test-V02HumanVisualGoAttestationCore -CandidatePath $candidatePath -AttestationPath $attestationPath -EvidenceRoot $fixture.Root -RepositoryRoot $fixture.RepositoryRoot }
    }
    finally {
        [IO.File]::WriteAllBytes($missingCapturePath, $missingCaptureBytes)
    }

    $existingOutput = Join-Path $external 'existing-output.json'
    [IO.File]::WriteAllText($existingOutput, 'occupied', [Text.UTF8Encoding]::new($false))
    Expect-HumanFailure 'concurrent/no-clobber candidate output' { Write-V02HumanVisualGoCandidate -Candidate $candidate -OutputPath $existingOutput -RepositoryRoot $fixture.RepositoryRoot -EvidenceRoot $fixture.Root }

    $heldPath = Join-Path $external 'held-swap.txt'
    $heldReplacement = Join-Path $external 'held-swap-replacement.txt'
    [IO.File]::WriteAllText($heldPath, 'original-held-bytes', [Text.UTF8Encoding]::new($false))
    [IO.File]::WriteAllText($heldReplacement, 'replacement-bytes', [Text.UTF8Encoding]::new($false))
    $holdContext = New-HumanVisualGoHoldContext
    try {
        Open-HumanVisualGoRootHandle -Context $holdContext -Root $external -ContextName 'swap fixture root'
        $held = Open-HumanVisualGoAbsoluteHeldFile -Context $holdContext -Path $heldPath -ContextName 'swap fixture file' -Root ([IO.Path]::GetPathRoot($heldPath)) -RootKind External
        $heldHash = $held.Sha256
        Expect-HumanFailure 'held same-handle path swap' { Move-Item -LiteralPath $heldReplacement -Destination $heldPath -Force }
        if ($held.Sha256 -cne $heldHash -or [Text.Encoding]::UTF8.GetString($held.Content) -cne 'original-held-bytes') { throw 'Held bytes changed after blocked path swap.' }
    }
    finally {
        Close-HumanVisualGoHoldContext -Context $holdContext
    }

    $hardlinkSource = Join-Path $external 'hardlink-source.txt'
    $hardlinkAlias = Join-Path $external 'hardlink-alias.txt'
    [IO.File]::WriteAllText($hardlinkSource, 'hardlink-source', [Text.UTF8Encoding]::new($false))
    New-Item -ItemType HardLink -Path $hardlinkAlias -Target $hardlinkSource | Out-Null
    $aliasContext = New-HumanVisualGoHoldContext
    try {
        Open-HumanVisualGoRootHandle -Context $aliasContext -Root $external -ContextName 'hardlink fixture root'
        [void](Open-HumanVisualGoAbsoluteHeldFile -Context $aliasContext -Path $hardlinkSource -ContextName 'hardlink source' -Root ([IO.Path]::GetPathRoot($hardlinkSource)) -RootKind External)
        Expect-HumanFailure 'hardlink/file-identity alias' { Open-HumanVisualGoAbsoluteHeldFile -Context $aliasContext -Path $hardlinkAlias -ContextName 'hardlink alias' -Root ([IO.Path]::GetPathRoot($hardlinkAlias)) -RootKind External }
    }
    finally {
        Close-HumanVisualGoHoldContext -Context $aliasContext
    }

    $escapeContext = New-HumanVisualGoHoldContext
    try {
        Expect-HumanFailure 'relative path escape/reparse guard' { Resolve-HumanVisualGoContainedPath -Root $fixture.Root -RelativePath '..\outside.json' -Context 'hostile escape' }
    }
    finally {
        Close-HumanVisualGoHoldContext -Context $escapeContext
    }

    $reparseLink = Join-Path $external 'reparse-link'
    try {
        New-Item -ItemType SymbolicLink -Path $reparseLink -Target $fixture.Root -ErrorAction Stop | Out-Null
        Expect-HumanFailure 'reparse directory path' { Resolve-HumanVisualGoContainedPath -Root $external -RelativePath 'reparse-link\renderer-compatibility-complete.json' -Context 'hostile reparse' }
    }
    catch {
        # A locked-down runner may not grant symlink creation. The path-escape
        # guard above still exercises the mandatory fail-closed path boundary.
        Pass 'reparse fixture unavailable; path boundary remained fail-closed'
    }

    [pscustomobject][ordered]@{
        EvidenceClassification = 'SyntheticVerifierSelftest'
        PositiveCases = $script:PositiveCases
        NegativeCases = $script:NegativeCases
        BindingValidation = 'PASS'
        HumanReview = 'NOT_OBSERVED'
        ActualHerdrRuntime = 'NOT_OBSERVED'
        Release = 'NOT_OBSERVED'
        CreditGranted = $false
    }
}
finally {
    if (Test-Path -LiteralPath $temp) { Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue }
}
