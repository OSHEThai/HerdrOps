#requires -Version 5.1

<##
.SYNOPSIS
    Validates the operator-supplied v0.7 Issue #40 release-gate input.

.DESCRIPTION
    This is preparation tooling.  It binds one clean candidate commit and tree,
    validates runtime-supplied dependency manifests for Issues #35-#39, and
    writes a report whose decision remains PENDING.  It never creates a human
    signature, an approval, a tag, a release, a session, or Runtime evidence.
#>

[CmdletBinding(DefaultParameterSetName = 'Run')]
param(
    [Parameter(Mandatory = $true, ParameterSetName = 'Run')]
    [Alias('InputPath', 'DependencyEvidencePath')]
    [string]$EvidenceInputPath,

    [Parameter(ParameterSetName = 'Run')]
    [string]$EvidenceRoot,

    [Parameter(ParameterSetName = 'Run')]
    [Alias('HumanAcceptancePath')]
    [string]$HumanUatPath,

    [Parameter(ParameterSetName = 'Run')]
    [switch]$RequireHumanUat,

    [Parameter(ParameterSetName = 'Run')]
    [string]$OutputPath,

    [Parameter(Mandatory = $true, ParameterSetName = 'SelfTest')]
    [switch]$SelfTest
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false

. (Join-Path $PSScriptRoot 'lib\V07ReleaseGatePolicy.ps1')

function Write-V07ReleaseGateSelfTestText {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Text
    )

    $parent = Split-Path -Path $Path -Parent
    if (-not (Test-Path -LiteralPath $parent -PathType Container)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }
    [IO.File]::WriteAllText($Path, $Text, [Text.UTF8Encoding]::new($false))
}

function Write-V07ReleaseGateSelfTestJson {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)]$Value
    )

    Write-V07ReleaseGateSelfTestText -Path $Path -Text (($Value | ConvertTo-Json -Depth 20) + "`n")
}

function Copy-V07ReleaseGateSelfTestJson {
    param([Parameter(Mandatory = $true)]$Value)

    $json = ($Value | ConvertTo-Json -Depth 20)
    return ConvertFrom-V07ReleaseGateStrictJson `
        -Bytes ([Text.UTF8Encoding]::new($false).GetBytes($json)) `
        -Description 'Issue #40 synthetic JSON clone'
}

function Assert-V07ReleaseGateExpectedFailure {
    param(
        [Parameter(Mandatory = $true)][string]$Description,
        [Parameter(Mandatory = $true)][scriptblock]$Action
    )

    $failure = $null
    try {
        & $Action | Out-Null
    } catch {
        $failure = $_
    }
    if ($null -eq $failure) {
        throw "SelfTest failed: expected rejection was not observed: $Description"
    }
}

function New-V07ReleaseGateSyntheticInput {
    param(
        [Parameter(Mandatory = $true)][string]$Root,
        [Parameter(Mandatory = $true)]$Candidate
    )

    $descriptors = New-Object System.Collections.ArrayList
    $manifestValues = @{}
    foreach ($issue in @(35, 36, 37, 38, 39)) {
        $issueRoot = Join-Path $Root ("issue-$issue")
        New-Item -ItemType Directory -Path $issueRoot -Force | Out-Null
        $evidencePath = Join-Path $issueRoot 'evidence.json'
        Write-V07ReleaseGateSelfTestText -Path $evidencePath -Text ("{`n  `"issue`": $issue, `"fixture`": `"runtime-created`"`n}`n")
        $evidenceRelative = "issue-$issue/evidence.json"
        $evidenceHash = ((Get-FileHash -LiteralPath $evidencePath -Algorithm SHA256).Hash).ToUpperInvariant()
        $manifestValue = [ordered]@{
            schemaVersion = 1
            reportKind = 'HerdrOps.V07DependencyManifest'
            issue = $issue
            candidate = [ordered]@{
                commit = [string]$Candidate.Commit
                tree = [string]$Candidate.Tree
                workingTree = 'CLEAN'
            }
            status = 'PENDING'
            evidenceClass = switch ($issue) {
                35 { 'IndependentReview' }
                36 { 'Static' }
                37 { 'Contract' }
                38 { 'Synthetic' }
                default { 'Runtime' }
            }
            evidenceFiles = @([ordered]@{
                    path = $evidenceRelative
                    sha256 = $evidenceHash
                })
            humanAcceptance = [ordered]@{
                status = 'PENDING'
                signer = 'PENDING'
                role = 'PENDING'
                signedAtUtc = 'PENDING'
                signature = 'PENDING'
            }
        }
        $manifestPath = Join-Path $issueRoot 'manifest.json'
        Write-V07ReleaseGateSelfTestJson -Path $manifestPath -Value $manifestValue
        $manifestHash = ((Get-FileHash -LiteralPath $manifestPath -Algorithm SHA256).Hash).ToUpperInvariant()
        [void]$descriptors.Add([ordered]@{
                issue = $issue
                manifestPath = "issue-$issue/manifest.json"
                manifestSha256 = $manifestHash
                status = 'PENDING'
            })
        $manifestValues[$issue] = $manifestValue
    }

    $inputValue = [ordered]@{
        schemaVersion = 1
        reportKind = 'HerdrOps.V07ReleaseGateInput'
        issue = 40
        candidate = [ordered]@{
            commit = [string]$Candidate.Commit
            tree = [string]$Candidate.Tree
            workingTree = 'CLEAN'
        }
        dependencies = @($descriptors.ToArray())
        historyPolicy = [ordered]@{
            rebaseAllowed = $false
            requiredFollowUp = 'HISTORY_PRESERVING_MERGE_FINAL_ISSUE_39_SUCCESSOR_REGENERATE_REVIEW'
        }
    }
    $inputPath = Join-Path $Root 'dependency-evidence.json'
    Write-V07ReleaseGateSelfTestJson -Path $inputPath -Value $inputValue
    return [pscustomobject][ordered]@{
        InputPath = $inputPath
        Input = $inputValue
        Manifests = $manifestValues
    }
}

function Invoke-V07ReleaseGateSelfTests {
    param([Parameter(Mandatory = $true)][string]$RepositoryRoot)

    $assertions = New-Object System.Collections.ArrayList
    $candidate = Get-V07ReleaseGateCurrentCandidate -RepositoryRoot $RepositoryRoot -AllowDirty
    $ownedParent = Join-Path ([IO.Path]::GetTempPath()) 'herdrops-v07-release-gate-selftests'
    $runId = [Guid]::NewGuid().ToString('N')
    $testRoot = Join-Path $ownedParent $runId
    $reparseLink = $null
    New-Item -ItemType Directory -Path $testRoot -Force | Out-Null
    try {
        $synthetic = New-V07ReleaseGateSyntheticInput -Root $testRoot -Candidate $candidate
        $validated = Test-V07ReleaseGateInput -InputPath $synthetic.InputPath -EvidenceRoot $testRoot -CurrentCandidate $candidate
        if ($validated.Dependencies.Count -ne 5 -or $validated.Candidate.Commit -cne $candidate.Commit -or
            $validated.Candidate.Tree -cne $candidate.Tree) {
            throw 'SelfTest failed: dynamic exact candidate/dependency binding did not validate.'
        }
        [void]$assertions.Add('DynamicCandidateAndDependencyHashes')

        $pendingReport = New-V07ReleaseGatePendingReport -ValidatedInput $validated -CurrentCandidate $candidate
        $reportPath = Write-V07ReleaseGateNewJsonFile -Path (Join-Path $testRoot 'pending-report.json') -Value $pendingReport -AllowedRoots @($testRoot)
        $reportText = [IO.File]::ReadAllText($reportPath)
        if ($reportText -notmatch '"status"\s*:\s*"PENDING"' -or
            $reportText -notmatch '"decision"\s*:\s*"PENDING"' -or
            $reportText -match '(?i)APPROVED' -or
            $reportText -match '"signer"\s*:\s*"(?!PENDING)[^"]+') {
            throw 'SelfTest failed: automation emitted a non-PENDING or human-looking decision.'
        }
        [void]$assertions.Add('AutomationEmitsPendingOnly')

        $badCommit = Copy-V07ReleaseGateSelfTestJson -Value $synthetic.Input
        $badCommit.candidate.commit = if ($candidate.Commit[0] -ceq '0') { '1' + $candidate.Commit.Substring(1) } else { '0' + $candidate.Commit.Substring(1) }
        $badCommitPath = Join-Path $testRoot 'bad-commit.json'
        Write-V07ReleaseGateSelfTestJson -Path $badCommitPath -Value $badCommit
        Assert-V07ReleaseGateExpectedFailure -Description 'stale candidate commit' -Action {
            Test-V07ReleaseGateInput -InputPath $badCommitPath -EvidenceRoot $testRoot -CurrentCandidate $candidate | Out-Null
        }
        [void]$assertions.Add('StaleCandidateCommitRejected')

        $badTree = Copy-V07ReleaseGateSelfTestJson -Value $synthetic.Input
        $badTree.candidate.tree = if ($candidate.Tree[0] -ceq '0') { '1' + $candidate.Tree.Substring(1) } else { '0' + $candidate.Tree.Substring(1) }
        $badTreePath = Join-Path $testRoot 'bad-tree.json'
        Write-V07ReleaseGateSelfTestJson -Path $badTreePath -Value $badTree
        Assert-V07ReleaseGateExpectedFailure -Description 'stale candidate tree' -Action {
            Test-V07ReleaseGateInput -InputPath $badTreePath -EvidenceRoot $testRoot -CurrentCandidate $candidate | Out-Null
        }
        [void]$assertions.Add('StaleCandidateTreeRejected')

        $badWorkingTree = Copy-V07ReleaseGateSelfTestJson -Value $synthetic.Input
        $badWorkingTree.candidate.workingTree = 'DIRTY'
        $badWorkingTreePath = Join-Path $testRoot 'dirty-candidate.json'
        Write-V07ReleaseGateSelfTestJson -Path $badWorkingTreePath -Value $badWorkingTree
        Assert-V07ReleaseGateExpectedFailure -Description 'dirty candidate declaration' -Action {
            Test-V07ReleaseGateInput -InputPath $badWorkingTreePath -EvidenceRoot $testRoot -CurrentCandidate $candidate | Out-Null
        }
        [void]$assertions.Add('DirtyCandidateRejected')

        $missingDependency = Copy-V07ReleaseGateSelfTestJson -Value $synthetic.Input
        $missingDependency.dependencies = @($missingDependency.dependencies | Where-Object { $_.issue -ne 39 })
        $missingDependencyPath = Join-Path $testRoot 'missing-dependency.json'
        Write-V07ReleaseGateSelfTestJson -Path $missingDependencyPath -Value $missingDependency
        Assert-V07ReleaseGateExpectedFailure -Description 'missing Issue #39 dependency' -Action {
            Test-V07ReleaseGateInput -InputPath $missingDependencyPath -EvidenceRoot $testRoot -CurrentCandidate $candidate | Out-Null
        }
        [void]$assertions.Add('MissingDependencyRejected')

        $duplicateDependency = Copy-V07ReleaseGateSelfTestJson -Value $synthetic.Input
        $duplicateDependency.dependencies[1].issue = $duplicateDependency.dependencies[0].issue
        $duplicateDependencyPath = Join-Path $testRoot 'duplicate-dependency.json'
        Write-V07ReleaseGateSelfTestJson -Path $duplicateDependencyPath -Value $duplicateDependency
        Assert-V07ReleaseGateExpectedFailure -Description 'duplicate dependency issue' -Action {
            Test-V07ReleaseGateInput -InputPath $duplicateDependencyPath -EvidenceRoot $testRoot -CurrentCandidate $candidate | Out-Null
        }
        [void]$assertions.Add('DuplicateDependencyRejected')

        $traversal = Copy-V07ReleaseGateSelfTestJson -Value $synthetic.Input
        $traversal.dependencies[0].manifestPath = '..\outside.json'
        $traversalPath = Join-Path $testRoot 'traversal.json'
        Write-V07ReleaseGateSelfTestJson -Path $traversalPath -Value $traversal
        Assert-V07ReleaseGateExpectedFailure -Description 'manifest traversal' -Action {
            Test-V07ReleaseGateInput -InputPath $traversalPath -EvidenceRoot $testRoot -CurrentCandidate $candidate | Out-Null
        }
        [void]$assertions.Add('ContainmentTraversalRejected')

        $tamperedHash = Copy-V07ReleaseGateSelfTestJson -Value $synthetic.Input
        $tamperedHash.dependencies[0].manifestSha256 = ('0' * 64)
        $tamperedHashPath = Join-Path $testRoot 'tampered-hash.json'
        Write-V07ReleaseGateSelfTestJson -Path $tamperedHashPath -Value $tamperedHash
        Assert-V07ReleaseGateExpectedFailure -Description 'manifest hash mismatch' -Action {
            Test-V07ReleaseGateInput -InputPath $tamperedHashPath -EvidenceRoot $testRoot -CurrentCandidate $candidate | Out-Null
        }
        [void]$assertions.Add('ManifestHashMismatchRejected')

        $unknown = Copy-V07ReleaseGateSelfTestJson -Value $synthetic.Input
        Add-Member -InputObject $unknown -MemberType NoteProperty -Name unknownField -Value $true | Out-Null
        $unknownPath = Join-Path $testRoot 'unknown-field.json'
        Write-V07ReleaseGateSelfTestJson -Path $unknownPath -Value $unknown
        Assert-V07ReleaseGateExpectedFailure -Description 'unknown top-level field' -Action {
            Test-V07ReleaseGateInput -InputPath $unknownPath -EvidenceRoot $testRoot -CurrentCandidate $candidate | Out-Null
        }
        [void]$assertions.Add('UnknownFieldRejected')

        $duplicateRawPath = Join-Path $testRoot 'duplicate-raw.json'
        Write-V07ReleaseGateSelfTestText -Path $duplicateRawPath -Text '{"schemaVersion":1,"schemaVersion":1}'
        Assert-V07ReleaseGateExpectedFailure -Description 'duplicate raw JSON property' -Action {
            Test-V07ReleaseGateInput -InputPath $duplicateRawPath -EvidenceRoot $testRoot -CurrentCandidate $candidate | Out-Null
        }
        [void]$assertions.Add('DuplicateJsonPropertyRejected')

        $trailingRawPath = Join-Path $testRoot 'trailing-raw.json'
        Write-V07ReleaseGateSelfTestText -Path $trailingRawPath -Text '{"schemaVersion":1} {"trailing":true}'
        Assert-V07ReleaseGateExpectedFailure -Description 'trailing JSON content' -Action {
            Test-V07ReleaseGateInput -InputPath $trailingRawPath -EvidenceRoot $testRoot -CurrentCandidate $candidate | Out-Null
        }
        [void]$assertions.Add('TrailingJsonRejected')

        $oversizedPath = Join-Path $testRoot 'oversized.json'
        Write-V07ReleaseGateSelfTestText -Path $oversizedPath -Text (('x' * ($script:V07ReleaseGateMaxInputBytes + 1)))
        Assert-V07ReleaseGateExpectedFailure -Description 'oversized JSON input' -Action {
            Read-V07ReleaseGateJsonFile -Path $oversizedPath -Description 'oversized fixture' -MaxBytes $script:V07ReleaseGateMaxInputBytes -Root $testRoot | Out-Null
        }
        [void]$assertions.Add('JsonSizeBoundRejected')

        $nestedUnknown = Copy-V07ReleaseGateSelfTestJson -Value $synthetic.Manifests[35]
        Add-Member -InputObject $nestedUnknown -MemberType NoteProperty -Name unknownField -Value 'reject' | Out-Null
        $nestedManifestPath = Join-Path $testRoot 'issue-35\manifest.json'
        Write-V07ReleaseGateSelfTestJson -Path $nestedManifestPath -Value $nestedUnknown
        $nestedInput = Copy-V07ReleaseGateSelfTestJson -Value $synthetic.Input
        $nestedInput.dependencies[0].manifestSha256 = ((Get-FileHash -LiteralPath $nestedManifestPath -Algorithm SHA256).Hash).ToUpperInvariant()
        $nestedPath = Join-Path $testRoot 'nested-unknown.json'
        Write-V07ReleaseGateSelfTestJson -Path $nestedPath -Value $nestedInput
        Assert-V07ReleaseGateExpectedFailure -Description 'unknown nested manifest field' -Action {
            Test-V07ReleaseGateInput -InputPath $nestedPath -EvidenceRoot $testRoot -CurrentCandidate $candidate | Out-Null
        }
        [void]$assertions.Add('NestedUnknownFieldRejected')

        $reparseTarget = Join-Path $testRoot 'reparse-target'
        $reparseLink = Join-Path $testRoot 'reparse-link'
        New-Item -ItemType Directory -Path $reparseTarget -Force | Out-Null
        try {
            New-Item -ItemType Junction -Path $reparseLink -Target $reparseTarget -Force | Out-Null
        } catch {
            throw "SelfTest failed: could not create the hostile reparse fixture: $($_.Exception.Message)"
        }
        Assert-V07ReleaseGateExpectedFailure -Description 'reparse component' -Action {
            Assert-V07ReleaseGateNoReparseComponents -Path (Join-Path $reparseLink 'manifest.json') -Root $testRoot
        }
        [void]$assertions.Add('ReparseComponentRejected')
        Remove-Item -LiteralPath $reparseLink -Force

        $duplicateEvidence = Copy-V07ReleaseGateSelfTestJson -Value $synthetic.Manifests[36]
        $duplicateEvidence.evidenceFiles[0].path = 'issue-35/evidence.json'
        $duplicateEvidenceManifestPath = Join-Path $testRoot 'issue-36\manifest.json'
        Write-V07ReleaseGateSelfTestJson -Path $duplicateEvidenceManifestPath -Value $duplicateEvidence
        $duplicateEvidenceInput = Copy-V07ReleaseGateSelfTestJson -Value $synthetic.Input
        $duplicateEvidenceInput.dependencies[1].manifestSha256 = ((Get-FileHash -LiteralPath $duplicateEvidenceManifestPath -Algorithm SHA256).Hash).ToUpperInvariant()
        $duplicateEvidenceInputPath = Join-Path $testRoot 'duplicate-evidence.json'
        Write-V07ReleaseGateSelfTestJson -Path $duplicateEvidenceInputPath -Value $duplicateEvidenceInput
        Assert-V07ReleaseGateExpectedFailure -Description 'duplicate evidence path across dependencies' -Action {
            Test-V07ReleaseGateInput -InputPath $duplicateEvidenceInputPath -EvidenceRoot $testRoot -CurrentCandidate $candidate | Out-Null
        }
        [void]$assertions.Add('DuplicateEvidencePathRejected')

        $humanPath = Join-Path $testRoot 'human-uat.json'
        $human = [ordered]@{
            schemaVersion = 1
            reportKind = 'HerdrOps.V07HumanUatAcceptance'
            issue = 40
            candidate = [ordered]@{ commit = $candidate.Commit; tree = $candidate.Tree }
            decision = 'ACCEPTED'
            signer = 'Synthetic Human Fixture'
            role = 'UAT Approver'
            signedAtUtc = '2026-08-22T00:00:00Z'
            signature = 'synthetic-signature-reference'
        }
        Write-V07ReleaseGateSelfTestJson -Path $humanPath -Value $human
        $humanResult = Read-V07ReleaseGateHumanUat -Path $humanPath -EvidenceRoot $testRoot -CurrentCandidate $candidate
        if ($humanResult.Data.Decision -cne 'ACCEPTED') {
            throw 'SelfTest failed: valid human UAT input did not validate.'
        }
        [void]$assertions.Add('HumanSignatureDateRoleAccepted')

        $badHuman = Copy-V07ReleaseGateSelfTestJson -Value $human
        $badHuman.role = 'PENDING'
        $badHumanPath = Join-Path $testRoot 'human-missing-role.json'
        Write-V07ReleaseGateSelfTestJson -Path $badHumanPath -Value $badHuman
        Assert-V07ReleaseGateExpectedFailure -Description 'human role missing' -Action {
            Read-V07ReleaseGateHumanUat -Path $badHumanPath -EvidenceRoot $testRoot -CurrentCandidate $candidate | Out-Null
        }
        [void]$assertions.Add('HumanRoleRequired')

        $badHumanDate = Copy-V07ReleaseGateSelfTestJson -Value $human
        $badHumanDate.signedAtUtc = 'PENDING'
        $badHumanDatePath = Join-Path $testRoot 'human-missing-date.json'
        Write-V07ReleaseGateSelfTestJson -Path $badHumanDatePath -Value $badHumanDate
        Assert-V07ReleaseGateExpectedFailure -Description 'human date missing' -Action {
            Read-V07ReleaseGateHumanUat -Path $badHumanDatePath -EvidenceRoot $testRoot -CurrentCandidate $candidate | Out-Null
        }
        [void]$assertions.Add('HumanDateRequired')

        $badHumanSignature = Copy-V07ReleaseGateSelfTestJson -Value $human
        $badHumanSignature.signature = 'PENDING'
        $badHumanSignaturePath = Join-Path $testRoot 'human-missing-signature.json'
        Write-V07ReleaseGateSelfTestJson -Path $badHumanSignaturePath -Value $badHumanSignature
        Assert-V07ReleaseGateExpectedFailure -Description 'human signature missing' -Action {
            Read-V07ReleaseGateHumanUat -Path $badHumanSignaturePath -EvidenceRoot $testRoot -CurrentCandidate $candidate | Out-Null
        }
        [void]$assertions.Add('HumanSignatureRequired')

        $fixtureRoot = Join-Path $RepositoryRoot 'tests\fixtures\v0.7\release-gate'
        foreach ($fixtureName in @('hostile-duplicate-property.json', 'hostile-unknown-field.json', 'hostile-traversal.json')) {
            $fixturePath = Join-Path $fixtureRoot $fixtureName
            if (-not (Test-Path -LiteralPath $fixturePath -PathType Leaf)) {
                throw "SelfTest failed: committed hostile fixture is missing: $fixturePath"
            }
        }
        [void]$assertions.Add('CommittedHostileFixturesPresent')

        return [pscustomobject][ordered]@{
            EvidenceClass = 'Static/Synthetic'
            Assertions = @($assertions.ToArray())
            AssertionCount = $assertions.Count
            Result = 'PASS'
            AutomationDecision = 'PENDING'
            HumanUat = 'PENDING / NOT CLAIMED'
            Runtime = 'NOT OBSERVED / NOT CLAIMED'
            Release = 'NOT OBSERVED / NOT CLAIMED'
        }
    } finally {
        if ($null -ne $reparseLink -and (Test-Path -LiteralPath $reparseLink)) {
            Remove-Item -LiteralPath $reparseLink -Force -ErrorAction SilentlyContinue
        }
        if (Test-Path -LiteralPath $testRoot) {
            Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

$repositoryRoot = Get-V07ReleaseGateRepositoryRoot
if ($SelfTest) {
    Invoke-V07ReleaseGateSelfTests -RepositoryRoot $repositoryRoot | ConvertTo-Json -Depth 10
    exit 0
}

$currentCandidate = Get-V07ReleaseGateCurrentCandidate -RepositoryRoot $repositoryRoot
if ([string]::IsNullOrWhiteSpace($EvidenceRoot)) {
    $EvidenceRoot = Join-Path $repositoryRoot 'artifacts\release-gates\v0.7.0\issue-40'
}
$EvidenceRoot = [IO.Path]::GetFullPath($EvidenceRoot)
if (-not (Test-Path -LiteralPath $EvidenceRoot -PathType Container)) {
    throw "Dependency evidence root is missing: $EvidenceRoot"
}
$EvidenceInputPath = [IO.Path]::GetFullPath($EvidenceInputPath)
$validatedInput = Test-V07ReleaseGateInput -InputPath $EvidenceInputPath -EvidenceRoot $EvidenceRoot -CurrentCandidate $currentCandidate

$humanResult = $null
if (-not [string]::IsNullOrWhiteSpace($HumanUatPath)) {
    $humanResult = Read-V07ReleaseGateHumanUat -Path ([IO.Path]::GetFullPath($HumanUatPath)) -EvidenceRoot $EvidenceRoot -CurrentCandidate $currentCandidate
} elseif ($RequireHumanUat) {
    throw '-RequireHumanUat was specified but no human UAT acceptance input was supplied.'
}

if ([string]::IsNullOrWhiteSpace($OutputPath)) {
    $runId = [DateTime]::UtcNow.ToString('yyyyMMddTHHmmssfffffffZ', [Globalization.CultureInfo]::InvariantCulture) + '-' + [Guid]::NewGuid().ToString('N').Substring(0, 8)
    $OutputPath = Join-Path $repositoryRoot ("artifacts\release-gates\v0.7.0\issue-40\$runId\gate-report.json")
}
$report = New-V07ReleaseGatePendingReport -ValidatedInput $validatedInput -CurrentCandidate $currentCandidate -HumanUatValidated ($null -ne $humanResult)
$reportPath = Write-V07ReleaseGateNewJsonFile -Path $OutputPath -Value $report -AllowedRoots @($EvidenceRoot, (Join-Path $repositoryRoot 'artifacts'))

[pscustomobject][ordered]@{
    Result = 'PASS / PREPARATION ONLY'
    Status = 'PENDING'
    Issue = 40
    SourceCommit = $currentCandidate.Commit
    SourceTree = $currentCandidate.Tree
    DependencyCount = $validatedInput.Dependencies.Count
    HumanUat = if ($null -ne $humanResult) { 'VALIDATED INPUT / PENDING' } else { 'PENDING / NOT PROVIDED' }
    Runtime = 'NOT OBSERVED / NOT CLAIMED'
    Release = 'NOT OBSERVED / NOT CLAIMED'
    GateReport = $reportPath
} | ConvertTo-Json -Depth 10
