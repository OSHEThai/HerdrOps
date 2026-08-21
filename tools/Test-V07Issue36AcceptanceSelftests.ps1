#requires -Version 5.1

[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'lib\V07Issue36AcceptancePolicy.ps1')

function Assert-V07Issue36Selftest {
    param(
        [Parameter(Mandatory = $true)][bool]$Condition,
        [Parameter(Mandatory = $true)][string]$Message
    )
    if (-not $Condition) {
        throw "Issue #36 selftest failed: $Message"
    }
}

function Assert-V07Issue36ExpectedFailure {
    param(
        [Parameter(Mandatory = $true)][string]$Description,
        [Parameter(Mandatory = $true)][scriptblock]$Action
    )
    $failed = $false
    try {
        & $Action
    } catch {
        $failed = $true
    }
    Assert-V07Issue36Selftest -Condition $failed -Message "$Description was accepted."
}

function Write-V07Issue36SelftestJson {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)]$Value
    )
    $json = ($Value | ConvertTo-Json -Depth 50) + "`n"
    [IO.File]::WriteAllText($Path, $json, (New-Object System.Text.UTF8Encoding($false)))
}

function Write-V07Issue36SelftestText {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Text
    )
    [IO.File]::WriteAllText($Path, $Text, (New-Object System.Text.UTF8Encoding($false)))
}

function Copy-V07Issue36SelftestObject {
    param([Parameter(Mandatory = $true)]$Value)
    return (($Value | ConvertTo-Json -Depth 50) | ConvertFrom-Json)
}

function Get-V07Issue36SelftestHash {
    param([Parameter(Mandatory = $true)][string]$Path)
    return (Get-V07ReleaseGateFileSnapshot -Path $Path -Description 'Issue #36 selftest file' -MaxBytes $script:V07Issue36EvidenceMaxBytes).Sha256
}

function New-V07Issue36SelftestFixture {
    param(
        [Parameter(Mandatory = $true)][string]$Root,
        [Parameter(Mandatory = $true)][string]$RepositoryRoot,
        [Parameter(Mandatory = $true)]$CurrentCandidate
    )

    $evidenceRoot = Join-Path $Root 'evidence'
    $trxRoot = Join-Path $evidenceRoot 'trx'
    New-Item -ItemType Directory -Path $trxRoot -Force | Out-Null

    $referenceFull = Join-Path $RepositoryRoot (Get-V07Issue36ReferencePath)
    $referenceSnapshot = Get-V07ReleaseGateFileSnapshot -Path $referenceFull -Description 'Issue #36 selftest reference' -MaxBytes (1024 * 1024) -Root $RepositoryRoot
    $records = New-Object System.Collections.ArrayList
    foreach ($definition in @(Get-V07Issue36RequiredTestDefinitions)) {
        $trxRelative = 'trx/' + $definition.Id + '.trx'
        $trxFull = Join-Path $evidenceRoot ($trxRelative -replace '/', [IO.Path]::DirectorySeparatorChar.ToString())
        $testName = $definition.TestClass + '.SyntheticProof'
        $trx = '<?xml version="1.0" encoding="utf-8"?><TestRun><Results><UnitTestResult testName="' + $testName + '" outcome="Passed" /></Results></TestRun>'
        Write-V07Issue36SelftestText -Path $trxFull -Text $trx
        $trxSnapshot = Get-V07ReleaseGateFileSnapshot -Path $trxFull -Description 'Issue #36 selftest TRX' -MaxBytes $script:V07Issue36EvidenceMaxBytes -Root $evidenceRoot
        $sourceFull = Join-Path $RepositoryRoot ($definition.SourcePath -replace '/', [IO.Path]::DirectorySeparatorChar.ToString())
        $sourceSnapshot = Get-V07ReleaseGateFileSnapshot -Path $sourceFull -Description 'Issue #36 selftest source' -MaxBytes $script:V07Issue36SourceMaxBytes -Root $RepositoryRoot
        [void]$records.Add([ordered]@{
                id = $definition.Id
                testClass = $definition.TestClass
                projectPath = $definition.ProjectPath
                testSourcePath = $definition.SourcePath
                testSourceSha256 = $sourceSnapshot.Sha256
                trxPath = $trxRelative
                trxSha256 = $trxSnapshot.Sha256
                testCaseCount = 1
                result = 'PASS'
                evidenceClass = 'Synthetic'
                command = 'dotnet test ' + $definition.ProjectPath + ' --filter FullyQualifiedName~' + $definition.TestClass + ' --logger trx'
            })
    }

    $manifest = [ordered]@{
        '$id' = 'https://herdrops.local/schema/v0.7/issue-36-acceptance.schema.json'
        schemaVersion = 1
        reportKind = 'HerdrOps.V07Issue36Acceptance'
        issue = 36
        status = 'PENDING'
        evidenceClass = 'Static/Contract/Synthetic'
        candidate = [ordered]@{
            commit = [string]$CurrentCandidate.Commit
            tree = [string]$CurrentCandidate.Tree
            workingTree = [string]$CurrentCandidate.WorkingTree
        }
        reference = [ordered]@{
            manifestPath = 'docs/design/reference/MANIFEST.md'
            manifestSha256 = $referenceSnapshot.Sha256
            hashAlgorithm = 'SHA-256'
            entryCount = 11
        }
        automatedEvidence = [ordered]@{
            status = 'PASS'
            tests = @($records.ToArray())
        }
        visualReview = [ordered]@{
            status = 'PENDING'
            captureManifestPath = 'PENDING'
            captureManifestSha256 = 'PENDING'
        }
        humanAcceptance = [ordered]@{
            status = 'PENDING'
            signer = 'PENDING'
            role = 'PENDING'
            signedAtUtc = 'PENDING'
            signature = 'PENDING'
            evidencePath = 'PENDING'
            evidenceSha256 = 'PENDING'
        }
        boundaries = [ordered]@{
            static = 'PASS'
            contract = 'PASS'
            synthetic = 'PASS'
            human = 'PENDING'
            runtime = 'NOT OBSERVED'
            release = 'NOT OBSERVED'
        }
    }
    $manifestPath = Join-Path $evidenceRoot 'issue-36-manifest.json'
    Write-V07Issue36SelftestJson -Path $manifestPath -Value $manifest
    return [pscustomobject][ordered]@{
        EvidenceRoot = $evidenceRoot
        ManifestPath = $manifestPath
        Manifest = $manifest
    }
}

function Assert-V07Issue36PowerShellParses {
    param([Parameter(Mandatory = $true)][string]$RepositoryRoot)

    $paths = @(
        (Join-Path $RepositoryRoot 'tools\lib\V07Issue36AcceptancePolicy.ps1'),
        (Join-Path $RepositoryRoot 'tools\Test-V07Issue36Acceptance.ps1'),
        (Join-Path $RepositoryRoot 'tools\Test-V07Issue36AcceptanceSelftests.ps1')
    )
    foreach ($path in $paths) {
        $tokens = $null
        $errors = $null
        [System.Management.Automation.Language.Parser]::ParseFile($path, [ref]$tokens, [ref]$errors) | Out-Null
        if ($null -ne $errors -and @($errors).Count -ne 0) {
            throw "PowerShell parser found errors in ${path}: $($errors -join '; ')"
        }
    }
}

$repositoryRoot = Get-V07Issue36RepositoryRoot
Assert-V07Issue36PowerShellParses -RepositoryRoot $repositoryRoot

$schemaPath = Join-Path $repositoryRoot 'docs\acceptance\issue-36-acceptance.schema.json'
$templatePath = Join-Path $repositoryRoot 'docs\acceptance\issue-36-acceptance.template.json'
$schemaFile = Read-V07ReleaseGateJsonFile -Path $schemaPath -Description 'Issue #36 schema selftest' -MaxBytes $script:V07Issue36ManifestMaxBytes
$templateFile = Read-V07ReleaseGateJsonFile -Path $templatePath -Description 'Issue #36 template selftest' -MaxBytes $script:V07Issue36ManifestMaxBytes
Assert-V07Issue36Selftest -Condition ([string]$schemaFile.Value.'$id' -ceq 'https://herdrops.local/schema/v0.7/issue-36-acceptance.schema.json') -Message 'schema $id is not bound to Issue #36.'
Assert-V07Issue36Selftest -Condition ([bool]$schemaFile.Value.additionalProperties -eq $false) -Message 'schema root is not closed.'
Assert-V07Issue36Selftest -Condition ([string]$templateFile.Value.status -ceq 'PENDING') -Message 'template does not remain PENDING.'
Assert-V07Issue36Selftest -Condition ([string]$templateFile.Value.humanAcceptance.status -ceq 'PENDING') -Message 'template human status is not PENDING.'
Assert-V07Issue36Selftest -Condition ([string]$templateFile.Value.boundaries.runtime -ceq 'NOT OBSERVED') -Message 'template Runtime boundary is not withheld.'
Assert-V07Issue36Selftest -Condition ([string]$templateFile.Value.boundaries.release -ceq 'NOT OBSERVED') -Message 'template Release boundary is not withheld.'

$currentCandidate = Get-V07ReleaseGateCurrentCandidate -RepositoryRoot $repositoryRoot -AllowDirty
$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('HerdrOps-V07-Issue36-Selftest-' + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $testRoot -Force | Out-Null
try {
    $fixture = New-V07Issue36SelftestFixture -Root $testRoot -RepositoryRoot $repositoryRoot -CurrentCandidate $currentCandidate
    $positive = Test-V07Issue36AcceptanceManifest -ManifestPath $fixture.ManifestPath -EvidenceRoot $fixture.EvidenceRoot -RepositoryRoot $repositoryRoot -CurrentCandidate $currentCandidate -AllowDirtyCandidate
    Assert-V07Issue36Selftest -Condition ([bool]$positive.Valid) -Message 'positive exact-bound fixture did not validate.'
    $report = New-V07Issue36PendingGateReport -Validation $positive
    Assert-V07Issue36Selftest -Condition ([string]$report.status -ceq 'PENDING') -Message 'gate report forged a non-PENDING status.'
    Assert-V07Issue36Selftest -Condition ([string]$report.human -ceq 'PENDING' -and [string]$report.runtime -ceq 'NOT OBSERVED' -and [string]$report.release -ceq 'NOT OBSERVED') -Message 'gate report overclaimed Human/Runtime/Release.'

    $unknown = Copy-V07Issue36SelftestObject -Value $fixture.Manifest
    $unknown | Add-Member -NotePropertyName unexpected -NotePropertyValue 'reject-me'
    $unknownPath = Join-Path $fixture.EvidenceRoot 'unknown.json'
    Write-V07Issue36SelftestJson -Path $unknownPath -Value $unknown
    Assert-V07Issue36ExpectedFailure -Description 'unknown manifest field' -Action {
        Test-V07Issue36AcceptanceManifest -ManifestPath $unknownPath -EvidenceRoot $fixture.EvidenceRoot -RepositoryRoot $repositoryRoot -CurrentCandidate $currentCandidate -AllowDirtyCandidate | Out-Null
    }

    $missing = Copy-V07Issue36SelftestObject -Value $fixture.Manifest
    $missing.reference.PSObject.Properties.Remove('entryCount')
    $missingPath = Join-Path $fixture.EvidenceRoot 'missing.json'
    Write-V07Issue36SelftestJson -Path $missingPath -Value $missing
    Assert-V07Issue36ExpectedFailure -Description 'missing manifest field' -Action {
        Test-V07Issue36AcceptanceManifest -ManifestPath $missingPath -EvidenceRoot $fixture.EvidenceRoot -RepositoryRoot $repositoryRoot -CurrentCandidate $currentCandidate -AllowDirtyCandidate | Out-Null
    }

    $duplicateJsonPath = Join-Path $fixture.EvidenceRoot 'duplicate-json.json'
    Write-V07Issue36SelftestText -Path $duplicateJsonPath -Text '{"schemaVersion":1,"schemaVersion":1}'
    Assert-V07Issue36ExpectedFailure -Description 'duplicate JSON property' -Action {
        Read-V07ReleaseGateJsonFile -Path $duplicateJsonPath -Description 'duplicate JSON selftest' -MaxBytes $script:V07Issue36ManifestMaxBytes -Root $fixture.EvidenceRoot | Out-Null
    }

    $zeroHash = Copy-V07Issue36SelftestObject -Value $fixture.Manifest
    $zeroHash.automatedEvidence.tests[0].testSourceSha256 = '0' * 64
    $zeroHashPath = Join-Path $fixture.EvidenceRoot 'zero-hash.json'
    Write-V07Issue36SelftestJson -Path $zeroHashPath -Value $zeroHash
    Assert-V07Issue36ExpectedFailure -Description 'zero test hash' -Action {
        Test-V07Issue36AcceptanceManifest -ManifestPath $zeroHashPath -EvidenceRoot $fixture.EvidenceRoot -RepositoryRoot $repositoryRoot -CurrentCandidate $currentCandidate -AllowDirtyCandidate | Out-Null
    }

    $stale = Copy-V07Issue36SelftestObject -Value $fixture.Manifest
    $stale.candidate.commit = '1' * 40
    $stalePath = Join-Path $fixture.EvidenceRoot 'stale-source.json'
    Write-V07Issue36SelftestJson -Path $stalePath -Value $stale
    Assert-V07Issue36ExpectedFailure -Description 'stale source commit' -Action {
        Test-V07Issue36AcceptanceManifest -ManifestPath $stalePath -EvidenceRoot $fixture.EvidenceRoot -RepositoryRoot $repositoryRoot -CurrentCandidate $currentCandidate -AllowDirtyCandidate | Out-Null
    }

    $staleReference = Copy-V07Issue36SelftestObject -Value $fixture.Manifest
    $staleReference.reference.manifestSha256 = '1' * 64
    $staleReferencePath = Join-Path $fixture.EvidenceRoot 'stale-reference.json'
    Write-V07Issue36SelftestJson -Path $staleReferencePath -Value $staleReference
    Assert-V07Issue36ExpectedFailure -Description 'stale reference MANIFEST hash' -Action {
        Test-V07Issue36AcceptanceManifest -ManifestPath $staleReferencePath -EvidenceRoot $fixture.EvidenceRoot -RepositoryRoot $repositoryRoot -CurrentCandidate $currentCandidate -AllowDirtyCandidate | Out-Null
    }

    $staleTrx = Copy-V07Issue36SelftestObject -Value $fixture.Manifest
    $staleTrx.automatedEvidence.tests[0].trxSha256 = '1' * 64
    $staleTrxPath = Join-Path $fixture.EvidenceRoot 'stale-trx.json'
    Write-V07Issue36SelftestJson -Path $staleTrxPath -Value $staleTrx
    Assert-V07Issue36ExpectedFailure -Description 'stale TRX hash' -Action {
        Test-V07Issue36AcceptanceManifest -ManifestPath $staleTrxPath -EvidenceRoot $fixture.EvidenceRoot -RepositoryRoot $repositoryRoot -CurrentCandidate $currentCandidate -AllowDirtyCandidate | Out-Null
    }

    $duplicateTest = Copy-V07Issue36SelftestObject -Value $fixture.Manifest
    $duplicateTest.automatedEvidence.tests = @($duplicateTest.automatedEvidence.tests) + @($duplicateTest.automatedEvidence.tests[0])
    $duplicateTestPath = Join-Path $fixture.EvidenceRoot 'duplicate-test.json'
    Write-V07Issue36SelftestJson -Path $duplicateTestPath -Value $duplicateTest
    Assert-V07Issue36ExpectedFailure -Description 'duplicate test record' -Action {
        Test-V07Issue36AcceptanceManifest -ManifestPath $duplicateTestPath -EvidenceRoot $fixture.EvidenceRoot -RepositoryRoot $repositoryRoot -CurrentCandidate $currentCandidate -AllowDirtyCandidate | Out-Null
    }

    $traversal = Copy-V07Issue36SelftestObject -Value $fixture.Manifest
    $traversal.automatedEvidence.tests[0].trxPath = '../outside.trx'
    $traversalPath = Join-Path $fixture.EvidenceRoot 'traversal.json'
    Write-V07Issue36SelftestJson -Path $traversalPath -Value $traversal
    Assert-V07Issue36ExpectedFailure -Description 'TRX path traversal' -Action {
        Test-V07Issue36AcceptanceManifest -ManifestPath $traversalPath -EvidenceRoot $fixture.EvidenceRoot -RepositoryRoot $repositoryRoot -CurrentCandidate $currentCandidate -AllowDirtyCandidate | Out-Null
    }

    $forgedHuman = Copy-V07Issue36SelftestObject -Value $fixture.Manifest
    $forgedHuman.humanAcceptance.status = 'ACCEPTED'
    $forgedHuman.humanAcceptance.signer = 'automation'
    $forgedHuman.humanAcceptance.role = 'ci'
    $forgedHuman.humanAcceptance.signedAtUtc = '2026-08-22T00:00:00Z'
    $forgedHuman.humanAcceptance.signature = 'automation-output'
    $forgedHuman.humanAcceptance.evidencePath = 'human/review.json'
    $forgedHuman.humanAcceptance.evidenceSha256 = '1' * 64
    $forgedHuman.boundaries.human = 'ACCEPTED'
    $forgedHumanPath = Join-Path $fixture.EvidenceRoot 'forged-human.json'
    Write-V07Issue36SelftestJson -Path $forgedHumanPath -Value $forgedHuman
    Assert-V07Issue36ExpectedFailure -Description 'forged human acceptance' -Action {
        Test-V07Issue36AcceptanceManifest -ManifestPath $forgedHumanPath -EvidenceRoot $fixture.EvidenceRoot -RepositoryRoot $repositoryRoot -CurrentCandidate $currentCandidate -AllowDirtyCandidate | Out-Null
    }

    $failedTrx = Join-Path $fixture.EvidenceRoot 'trx\settings-persistence.trx'
    $failedText = '<?xml version="1.0" encoding="utf-8"?><TestRun><Results><UnitTestResult testName="failed" outcome="Failed" /></Results></TestRun>'
    Write-V07Issue36SelftestText -Path $failedTrx -Text $failedText
    $failed = Copy-V07Issue36SelftestObject -Value $fixture.Manifest
    $failed.automatedEvidence.tests[0].trxSha256 = Get-V07Issue36SelftestHash -Path $failedTrx
    $failedPath = Join-Path $fixture.EvidenceRoot 'failed-trx.json'
    Write-V07Issue36SelftestJson -Path $failedPath -Value $failed
    Assert-V07Issue36ExpectedFailure -Description 'failed TRX result' -Action {
        Test-V07Issue36AcceptanceManifest -ManifestPath $failedPath -EvidenceRoot $fixture.EvidenceRoot -RepositoryRoot $repositoryRoot -CurrentCandidate $currentCandidate -AllowDirtyCandidate | Out-Null
    }
} finally {
    Remove-Item -LiteralPath $testRoot -Recurse -Force
}

[pscustomobject][ordered]@{
    EvidenceClass = 'Static/Contract/Synthetic'
    Issue = 36
    PowerShellEdition = [string]$PSVersionTable.PSEdition
    PowerShellVersion = [string]$PSVersionTable.PSVersion
    Parser = 'PASS'
    SchemaStrictJson = 'PASS'
    TemplatePending = 'PASS'
    PositiveExactBinding = 'PASS'
    UnknownFieldFailClosed = 'PASS'
    DuplicateJsonFailClosed = 'PASS'
    MissingFieldFailClosed = 'PASS'
    ZeroHashFailClosed = 'PASS'
    StaleSourceFailClosed = 'PASS'
    StaleReferenceFailClosed = 'PASS'
    StaleTrxFailClosed = 'PASS'
    DuplicateTestFailClosed = 'PASS'
    PathTraversalFailClosed = 'PASS'
    ForgedHumanFailClosed = 'PASS'
    FailedTrxFailClosed = 'PASS'
    Human = 'NOT OBSERVED'
    Runtime = 'NOT OBSERVED'
    Release = 'NOT OBSERVED'
}
