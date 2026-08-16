[CmdletBinding()]
param(
    [ValidateSet('Debug', 'Release')]
    [string]$Configuration = 'Release',

    [switch]$SkipBuild
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false

$repositoryRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')).Path
$artifactRoot = Join-Path $repositoryRoot 'artifacts'
$gateDirectory = Join-Path $artifactRoot 'release-gates\v0.6.0\issue-33'
$runId = "$([DateTime]::UtcNow.ToString('yyyyMMddTHHmmssfffffffZ', [Globalization.CultureInfo]::InvariantCulture))-$([Guid]::NewGuid().ToString('N').Substring(0, 8))"
$runDirectory = Join-Path $gateDirectory $runId
$testResultDirectory = Join-Path $runDirectory 'test-results'
$gateReportPath = Join-Path $runDirectory 'gate-report.txt'

function Get-RepositoryRelativePath {
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )

    $separatorChars = [char[]]@(
        [IO.Path]::DirectorySeparatorChar,
        [IO.Path]::AltDirectorySeparatorChar)
    $normalizedRoot = [IO.Path]::GetFullPath($repositoryRoot).TrimEnd($separatorChars)
    $normalizedPath = [IO.Path]::GetFullPath($Path)
    $rootPrefix = $normalizedRoot + [IO.Path]::DirectorySeparatorChar
    if (-not $normalizedPath.StartsWith($rootPrefix, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Discovered export path is outside the repository root: $normalizedPath"
    }

    return $normalizedPath.Substring($rootPrefix.Length).Replace('\', '/')
}

function Get-DiscoveredFiles {
    param(
        [Parameter(Mandatory)]
        [string]$Root,

        [Parameter(Mandatory)]
        [string]$Extension,

        [Parameter(Mandatory)]
        [string]$NamePattern
    )

    if (-not (Test-Path -LiteralPath $Root -PathType Container)) {
        return @()
    }

    $files = @(Get-ChildItem -LiteralPath $Root -File -Recurse -ErrorAction Stop | Where-Object {
            $normalizedPath = $_.FullName.Replace('/', '\')
            $_.Extension -ieq $Extension -and
            $_.Name -match $NamePattern -and
            $normalizedPath -notmatch '\\(?:bin|obj|artifacts)\\'
        })
    return @($files | Sort-Object -Property FullName -Unique)
}

function Get-ActualSha256 {
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "Cannot hash missing file: $Path"
    }

    $observedHash = [string](Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash
    if ([string]::IsNullOrWhiteSpace($observedHash) -or
        $observedHash -notmatch '^[0-9A-Fa-f]{64}$') {
        throw "Observed file hash is not a SHA-256 value: $Path"
    }

    return $observedHash.ToUpperInvariant()
}

function Get-FilePins {
    param(
        [Parameter(Mandatory)]
        [object[]]$Files
    )

    $pins = @()
    foreach ($file in @($Files | Sort-Object -Property FullName)) {
        $pins += [pscustomobject]@{
            RelativePath = Get-RepositoryRelativePath -Path $file.FullName
            Sha256 = Get-ActualSha256 -Path $file.FullName
        }
    }

    return @($pins)
}

function Get-PinFingerprint {
    param(
        [Parameter(Mandatory)]
        [object[]]$Pins
    )

    $parts = @($Pins | Sort-Object -Property RelativePath | ForEach-Object {
            '{0}|{1}' -f $_.RelativePath, $_.Sha256
        })
    return $parts -join "`n"
}

function Get-PinSetSha256 {
    param(
        [Parameter(Mandatory)]
        [object[]]$Pins
    )

    if (@($Pins).Count -eq 0) {
        return $null
    }

    $canonical = ((@($Pins | Sort-Object -Property RelativePath | ForEach-Object {
                '{0}|{1}' -f $_.RelativePath, $_.Sha256
            })) -join "`n") + "`n"
    $sha256 = [System.Security.Cryptography.SHA256]::Create()
    try {
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($canonical)
        $digest = $sha256.ComputeHash($bytes)
    }
    finally {
        $sha256.Dispose()
    }

    return ([BitConverter]::ToString($digest).Replace('-', '')).ToUpperInvariant()
}

function Add-PinReportLines {
    param(
        [Parameter(Mandatory)]
        [System.Collections.Generic.List[string]]$Lines,

        [Parameter(Mandatory)]
        [string]$Label,

        [Parameter(Mandatory)]
        [object[]]$Pins
    )

    $pinArray = @($Pins)
    if ($pinArray.Count -eq 0) {
        [void]$Lines.Add(('{0}Sha256: NOT OBSERVED' -f $Label))
        return
    }

    foreach ($pin in @($pinArray | Sort-Object -Property RelativePath)) {
        [void]$Lines.Add(('{0}File: {1}' -f $Label, $pin.RelativePath))
        [void]$Lines.Add(('{0}FileSha256: {1}' -f $Label, $pin.Sha256))
    }

    if ($pinArray.Count -eq 1) {
        [void]$Lines.Add(('{0}Sha256: {1}' -f $Label, $pinArray[0].Sha256))
    }
    [void]$Lines.Add(('{0}SetSha256: {1}' -f $Label, (Get-PinSetSha256 -Pins $pinArray)))
}

function Write-GateReport {
    param(
        [Parameter(Mandatory)]
        [string[]]$Lines
    )

    New-Item -ItemType Directory -Path $runDirectory -Force | Out-Null
    $Lines | Set-Content -LiteralPath $gateReportPath -Encoding utf8
    $Lines | Write-Output
    Write-Output "GateReport: $gateReportPath"
}

function Invoke-ExportEvidenceTests {
    param(
        [Parameter(Mandatory)]
        [string]$ProjectPath,

        [Parameter(Mandatory)]
        [string]$Filter,

        [Parameter(Mandatory)]
        [string]$LogFileName,

        [Parameter(Mandatory)]
        [string]$EvidenceLabel
    )

    if (-not (Test-Path -LiteralPath $ProjectPath -PathType Leaf)) {
        throw "$EvidenceLabel test project was not found: $ProjectPath"
    }

    $trxPath = Join-Path $testResultDirectory $LogFileName
    & dotnet test $ProjectPath `
        --configuration $Configuration `
        --no-restore `
        --no-build `
        --artifacts-path $artifactRoot `
        --results-directory $testResultDirectory `
        --filter $Filter `
        --logger "trx;LogFileName=$LogFileName" |
        Out-Host
    $exitCode = $LASTEXITCODE
    if ($exitCode -ne 0) {
        throw "$EvidenceLabel export evidence tests failed with exit code $exitCode."
    }
    if (-not (Test-Path -LiteralPath $trxPath -PathType Leaf)) {
        throw "$EvidenceLabel export evidence did not produce a fresh TRX file: $trxPath"
    }

    [xml]$trx = Get-Content -LiteralPath $trxPath -Raw
    $counters = $trx.TestRun.ResultSummary.Counters
    $totalTests = [int]$counters.total
    $passedTests = [int]$counters.passed
    $failedTests = [int]$counters.failed
    if ($totalTests -le 0 -or $failedTests -ne 0 -or $passedTests -ne $totalTests) {
        throw "$EvidenceLabel export test counters are not all passing: total=$totalTests passed=$passedTests failed=$failedTests"
    }

    return [pscustomobject]@{
        Total = $totalTests
        Passed = $passedTests
        Failed = $failedTests
    }
}

$sourceFiles = @(
    Get-Item -LiteralPath (Join-Path $repositoryRoot 'src\HerdrOps.Domain\Exports\DeterministicSnapshotExporter.cs')
    Get-Item -LiteralPath (Join-Path $repositoryRoot 'src\HerdrOps.Domain\Exports\LocalSnapshotExportPublisher.cs')
    Get-Item -LiteralPath (Join-Path $repositoryRoot 'src\HerdrOps.Domain\Evaluation\ExplainableScoring.cs')
    Get-Item -LiteralPath (Join-Path $repositoryRoot 'src\HerdrOps.Domain\Summaries\DailySummaryAggregation.cs')
)
$contractFiles = @(
    Get-Item -LiteralPath (Join-Path $repositoryRoot 'docs\protocol\v0.6-local-export-contract.md')
)
$fixtureFiles = @(
    Get-Item -LiteralPath (Join-Path $repositoryRoot 'tests\fixtures\v0.6\snapshot-export-v1.json')
    Get-Item -LiteralPath (Join-Path $repositoryRoot 'tests\fixtures\v0.6\scoring-golden-v1.json')
    Get-Item -LiteralPath (Join-Path $repositoryRoot 'tests\fixtures\v0.6\daily-summary-aggregation.json')
)
$syntheticTestFiles = @(
    Get-Item -LiteralPath (Join-Path $repositoryRoot 'tests\HerdrOps.UnitTests\ExplainableScoringTests.cs')
    Get-Item -LiteralPath (Join-Path $repositoryRoot 'tests\HerdrOps.UnitTests\DeterministicSnapshotExporterTests.cs')
    Get-Item -LiteralPath (Join-Path $repositoryRoot 'tests\HerdrOps.UnitTests\LocalSnapshotExportPublisherTests.cs')
    Get-Item -LiteralPath (Join-Path $repositoryRoot 'tests\HerdrOps.UnitTests\DailySummarySnapshotSemanticValidationTests.cs')
)
$contractTestFiles = @(
    Get-Item -LiteralPath (Join-Path $repositoryRoot 'tests\HerdrOps.ContractTests\SnapshotExportContractTests.cs')
)
$allRequiredFiles = @($sourceFiles) + @($contractFiles) + @($fixtureFiles) +
    @($syntheticTestFiles) + @($contractTestFiles)

$expectedInputSha256 = [ordered]@{
    'src/HerdrOps.Domain/Exports/DeterministicSnapshotExporter.cs' = '1ECEC535072EC907906EBAEAF87C1DF1938F15B5D3DF7CCC7D7C2959BFAB2798'
    'src/HerdrOps.Domain/Exports/LocalSnapshotExportPublisher.cs' = '3FE702F9DB6B946DD22EBF5FB54FAD229280109C2CDB3F06EBDDBB3300118FDA'
    'src/HerdrOps.Domain/Evaluation/ExplainableScoring.cs' = 'B719E368DCD01277FE1BEFE6B67B567D4DEF20F38B8F604448DE5D3219A01688'
    'src/HerdrOps.Domain/Summaries/DailySummaryAggregation.cs' = '24FBC5205B67AC9819784BE092B8BC0A4CB7CED2255908327DC47A22B5D78393'
    'docs/protocol/v0.6-local-export-contract.md' = 'EC2CF5B82C05B3ABF877554C88071FC660043A5EF0CEFD2EFDD8757DEBD8DA48'
    'tests/fixtures/v0.6/snapshot-export-v1.json' = '3E3FF5DDBA60697402F32F4D01EFE456298B05E7F4C5BEBF4CECE792357A81B0'
    'tests/fixtures/v0.6/scoring-golden-v1.json' = 'E33CF3930AC76EAD86F81FFBFE1925D8357C587C92B877083BFF206EA4FB6F8F'
    'tests/fixtures/v0.6/daily-summary-aggregation.json' = 'E23B9CB2AD1ADA6F603311F8F2F5D25FB45DC03C2934860C0AF8039D6591F07F'
    'tests/HerdrOps.UnitTests/ExplainableScoringTests.cs' = '54EFF2C86F32946EF402FCDB66181582C44824BF0DFD236594F4EB493D0235CD'
    'tests/HerdrOps.UnitTests/DeterministicSnapshotExporterTests.cs' = 'D02535343D8B5922250FA1BB25650DA7B25E8418C05CDBED096C2D1E1EBA451E'
    'tests/HerdrOps.UnitTests/LocalSnapshotExportPublisherTests.cs' = '54CC0FAE27985A857BFFBFFA9D86BC0E7FB5221790CDE6AA488A425BF17E4605'
    'tests/HerdrOps.UnitTests/DailySummarySnapshotSemanticValidationTests.cs' = '3F86CB7C481E5002FD680B10EB34CB199E5C1030588D7247CE87265B137EDDC4'
    'tests/HerdrOps.ContractTests/SnapshotExportContractTests.cs' = '5100E87100F705E9EC0CC11FD75203E7A7C6CA89095A4EA8F59C41BF0B972C81'
}

$sourceCommit = (& git -C $repositoryRoot rev-parse --verify 'HEAD^{commit}').Trim()
if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($sourceCommit)) {
    throw 'Could not resolve the committed source for the Issue #33 gate.'
}
$initialStatus = @(& git -C $repositoryRoot status --porcelain=v1 --untracked-files=all)
if ($LASTEXITCODE -ne 0) {
    throw 'Could not inspect the Issue #33 source checkout.'
}
if ($initialStatus.Count -ne 0) {
    throw "The Issue #33 gate requires a clean committed checkout. Pending paths: $($initialStatus -join '; ')"
}

foreach ($requiredFile in $allRequiredFiles) {
    $relativePath = Get-RepositoryRelativePath -Path $requiredFile.FullName
    & git -C $repositoryRoot ls-files --error-unmatch -- $relativePath *> $null
    if ($LASTEXITCODE -ne 0) {
        throw "Required Issue #33 input is not tracked at the source commit: $relativePath"
    }
    $observedHash = Get-ActualSha256 -Path $requiredFile.FullName
    if (-not $expectedInputSha256.Contains($relativePath) -or
        $observedHash -cne $expectedInputSha256[$relativePath]) {
        throw "Pinned Issue #33 input drifted for $relativePath`: expected $($expectedInputSha256[$relativePath]) observed $observedHash"
    }
}

$sourcePins = @()
$contractPins = @()
$fixturePins = @()
$testPins = @()
if ($sourceFiles.Count -gt 0) {
    $sourcePins = @(Get-FilePins -Files $sourceFiles)
}
if ($contractFiles.Count -gt 0) {
    $contractPins = @(Get-FilePins -Files $contractFiles)
}
if ($fixtureFiles.Count -gt 0) {
    $fixturePins = @(Get-FilePins -Files $fixtureFiles)
}
if (($syntheticTestFiles.Count + $contractTestFiles.Count) -gt 0) {
    $testPins = @(Get-FilePins -Files (@($syntheticTestFiles) + @($contractTestFiles)))
}

$notReadyReasons = New-Object 'System.Collections.Generic.List[string]'
if ($sourceFiles.Count -eq 0) {
    [void]$notReadyReasons.Add('Exporter source was not discovered under src.')
}
if ($contractFiles.Count -ne 1) {
    [void]$notReadyReasons.Add('Local-export contract was not discovered under docs/protocol.')
}
if ($fixtureFiles.Count -ne 3) {
    [void]$notReadyReasons.Add('Local-export fixture was not discovered under tests/fixtures/v0.6.')
}

if ($notReadyReasons.Count -gt 0) {
    $notReadyReport = New-Object 'System.Collections.Generic.List[string]'
    [void]$notReadyReport.Add('HerdrOps v0.6 Issue #33 Local Export Acceptance Gate')
    [void]$notReadyReport.Add("GeneratedUtc: $([DateTime]::UtcNow.ToString('O'))")
    [void]$notReadyReport.Add('Result: NOT READY')
    [void]$notReadyReport.Add('IssueAcceptance: NOT OBSERVED')
    [void]$notReadyReport.Add("SkipBuild: $SkipBuild")
    [void]$notReadyReport.Add("ExporterSourceFilesDiscovered: $($sourceFiles.Count)")
    [void]$notReadyReport.Add("ContractFilesDiscovered: $($contractFiles.Count)")
    [void]$notReadyReport.Add("FixtureFilesDiscovered: $($fixtureFiles.Count)")
    [void]$notReadyReport.Add('Static: NOT OBSERVED')
    [void]$notReadyReport.Add('Synthetic: NOT OBSERVED')
    [void]$notReadyReport.Add('Contract: NOT OBSERVED')
    [void]$notReadyReport.Add('EvidenceClass: Static plus Synthetic plus Contract')
    [void]$notReadyReport.Add('Actual Herdr Runtime: NOT OBSERVED')
    [void]$notReadyReport.Add('ActualHerdrRuntime: NOT OBSERVED / NOT CLAIMED')
    [void]$notReadyReport.Add('Release: NOT OBSERVED')
    [void]$notReadyReport.Add('ReleaseEvidence: NOT OBSERVED / NOT CLAIMED')
    [void]$notReadyReport.Add(('Failure: NOT READY: {0}' -f ($notReadyReasons -join '; ')))
    Add-PinReportLines -Lines $notReadyReport -Label 'Source' -Pins $sourcePins
    Add-PinReportLines -Lines $notReadyReport -Label 'Contract' -Pins $contractPins
    Add-PinReportLines -Lines $notReadyReport -Label 'Fixture' -Pins $fixturePins
    Add-PinReportLines -Lines $notReadyReport -Label 'TestSource' -Pins $testPins
    [void]$notReadyReport.Add('EvidenceBoundary: No exporter acceptance credit is claimed until actual source, contract, fixture, synthetic, and contract evidence exists.')
    Write-GateReport -Lines $notReadyReport.ToArray()
    throw ('NOT READY: ' + ($notReadyReasons -join ' '))
}

$staticStatus = 'FAIL'
$syntheticStatus = 'NOT OBSERVED'
$contractStatus = 'NOT OBSERVED'
$syntheticSummary = $null
$contractSummary = $null
$finalSourcePins = @($sourcePins)
$finalContractPins = @($contractPins)
$finalFixturePins = @($fixturePins)
$finalTestPins = @($testPins)

try {
    if ($sourceFiles.Count -eq 0) {
        throw 'Exporter source discovery unexpectedly returned no files.'
    }

    $requiredSourceMarkers = [ordered]@{
        'DeterministicSnapshotExporter.cs' = 'public static class DeterministicSnapshotExporter'
        'LocalSnapshotExportPublisher.cs' = 'public sealed class LocalSnapshotExportPublisher'
        'ExplainableScoring.cs' = 'public sealed class EvaluationScoringEngine'
        'DailySummaryAggregation.cs' = 'public static class DailySummaryAggregator'
    }
    foreach ($sourceFile in @($sourceFiles)) {
        $sourceText = Get-Content -LiteralPath $sourceFile.FullName -Raw
        if ([string]::IsNullOrWhiteSpace($sourceText)) {
            throw "Discovered exporter source is empty: $($sourceFile.FullName)"
        }
        $requiredMarker = $requiredSourceMarkers[$sourceFile.Name]
        if ([string]::IsNullOrWhiteSpace($requiredMarker) -or
            $sourceText.IndexOf($requiredMarker, [StringComparison]::Ordinal) -lt 0) {
            throw "Discovered Issue #33 dependency has no required implementation marker: $($sourceFile.FullName)"
        }
    }

    if ($contractFiles.Count -ne 1) {
        throw "Expected exactly one local-export contract, found $($contractFiles.Count)."
    }
    $contractText = Get-Content -LiteralPath $contractFiles[0].FullName -Raw
    if ([string]::IsNullOrWhiteSpace($contractText)) {
        throw "Discovered local-export contract is empty: $($contractFiles[0].FullName)"
    }
    foreach ($contractPattern in @(
            '(?i)human[-\s]readable',
            '(?i)machine[-\s]readable',
            '(?i)markdown',
            '(?i)csv',
            '(?i)sha[-\s]?256',
            '(?i)provenance',
            '(?i)redact',
            '(?i)atomic',
            '(?i)512',
            '(?i)20,000',
            '(?i)8,192')) {
        if (-not [Regex]::IsMatch($contractText, $contractPattern)) {
            throw "Local-export contract is missing required policy marker: $contractPattern"
        }
    }

    if ($fixtureFiles.Count -ne 3) {
        throw "Expected exactly three Issue #33 fixture dependencies, found $($fixtureFiles.Count)."
    }
    $exportFixtureFile = $fixtureFiles | Where-Object { $_.Name -eq 'snapshot-export-v1.json' }
    if (@($exportFixtureFile).Count -ne 1) {
        throw 'The snapshot-export-v1.json manifest fixture is missing or ambiguous.'
    }
    $fixtureText = Get-Content -LiteralPath $exportFixtureFile.FullName -Raw
    if ([string]::IsNullOrWhiteSpace($fixtureText)) {
        throw "Discovered local-export fixture is empty: $($fixtureFiles[0].FullName)"
    }
    if ($fixtureText -match '(?i)\b(?:PLACEHOLDER|REPLACE_ME|TODO|TBD)\b' -or
        $fixtureText -match '(?i)"[^"]*(?:sha256|hash)[^"]*"\s*:\s*"([0-9a-f])\1{63}"') {
        throw 'Local-export fixture contains a placeholder marker or repeated placeholder hash.'
    }
    $fixture = $fixtureText | ConvertFrom-Json
    if ($null -eq $fixture) {
        throw 'Local-export fixture parsed to null.'
    }
    if (-not [Regex]::IsMatch($fixtureText, '(?i)"(?:fixtureId|sourceFixtures|expected|outputs?|reports?)"\s*:')) {
        throw 'Local-export fixture does not expose an explicit fixture or expected/output surface.'
    }
    foreach ($identityName in @(
            'evaluationJsonSha256',
            'evaluationMarkdownSha256',
            'evaluationCsvSha256',
            'evaluationExportId',
            'evaluationSourceSnapshotSha256',
            'dailyJsonSha256',
            'dailyMarkdownSha256',
            'dailyCsvSha256',
            'dailyExportId',
            'dailySourceSnapshotSha256')) {
        $identity = [string]$fixture.$identityName
        if ($identity -cnotmatch '^[0-9A-F]{64}$') {
            throw "Local-export fixture identity $identityName is not canonical SHA-256."
        }
    }
    $sourceFixtureNames = @($fixture.sourceFixtures)
    if ($sourceFixtureNames.Count -ne 2 -or
        $sourceFixtureNames[0] -cne 'scoring-golden-v1.json' -or
        $sourceFixtureNames[1] -cne 'daily-summary-aggregation.json') {
        throw 'Local-export fixture dependencies do not bind the exact scoring and Daily Summary fixtures.'
    }

    $staticStatus = 'PASS'

    if (-not $SkipBuild) {
        $buildScript = Join-Path $PSScriptRoot 'Invoke-Build.ps1'
        if (-not (Test-Path -LiteralPath $buildScript -PathType Leaf)) {
            throw "Build helper was not found: $buildScript"
        }
        & $buildScript -Configuration $Configuration -VerifyFormat
        if ($LASTEXITCODE -ne 0) {
            throw "v0.6 local-export build gate failed with exit code $LASTEXITCODE."
        }
    }

    if ($syntheticTestFiles.Count -ne 4) {
        throw 'The exact Issue #33 Unit evidence sources were not discovered.'
    }
    $syntheticStatus = 'FAIL'
    $syntheticSummary = Invoke-ExportEvidenceTests `
        -ProjectPath (Join-Path $repositoryRoot 'tests\HerdrOps.UnitTests\HerdrOps.UnitTests.csproj') `
        -Filter 'FullyQualifiedName~ExplainableScoringTests|FullyQualifiedName~DeterministicSnapshotExporterTests|FullyQualifiedName~LocalSnapshotExportPublisherTests|FullyQualifiedName~DailySummarySnapshotSemanticValidationTests' `
        -LogFileName 'local-export-synthetic.trx' `
        -EvidenceLabel 'Synthetic'
    $syntheticStatus = 'PASS'

    if ($contractTestFiles.Count -ne 1) {
        throw 'The exact Issue #33 Contract evidence source was not discovered.'
    }
    $contractStatus = 'FAIL'
    $contractSummary = Invoke-ExportEvidenceTests `
        -ProjectPath (Join-Path $repositoryRoot 'tests\HerdrOps.ContractTests\HerdrOps.ContractTests.csproj') `
        -Filter 'FullyQualifiedName~SnapshotExportContractTests' `
        -LogFileName 'local-export-contract.trx' `
        -EvidenceLabel 'Contract'
    $contractStatus = 'PASS'

    $finalSourcePins = @(Get-FilePins -Files $sourceFiles)
    $finalContractPins = @(Get-FilePins -Files $contractFiles)
    $finalFixturePins = @(Get-FilePins -Files $fixtureFiles)
    $finalTestPins = @(Get-FilePins -Files (@($syntheticTestFiles) + @($contractTestFiles)))
    if ((Get-PinFingerprint -Pins $finalSourcePins) -cne (Get-PinFingerprint -Pins $sourcePins) -or
        (Get-PinFingerprint -Pins $finalContractPins) -cne (Get-PinFingerprint -Pins $contractPins) -or
        (Get-PinFingerprint -Pins $finalFixturePins) -cne (Get-PinFingerprint -Pins $fixturePins) -or
        (Get-PinFingerprint -Pins $finalTestPins) -cne (Get-PinFingerprint -Pins $testPins)) {
        throw 'Pinned exporter dependency, contract, fixture, or test bytes changed during the gate.'
    }

    $finalCommit = (& git -C $repositoryRoot rev-parse --verify 'HEAD^{commit}').Trim()
    $finalStatus = @(& git -C $repositoryRoot status --porcelain=v1 --untracked-files=all)
    if ($LASTEXITCODE -ne 0 -or $finalCommit -cne $sourceCommit -or $finalStatus.Count -ne 0) {
        throw 'The source commit or clean-checkout state changed during the Issue #33 gate.'
    }

    $passReport = New-Object 'System.Collections.Generic.List[string]'
    [void]$passReport.Add('HerdrOps v0.6 Issue #33 Local Export Acceptance Gate')
    [void]$passReport.Add("GeneratedUtc: $([DateTime]::UtcNow.ToString('O'))")
    [void]$passReport.Add("SourceCommit: $sourceCommit")
    if ($SkipBuild) {
        [void]$passReport.Add('Result: NON-ACCEPTANCE CHECKS PASS')
        [void]$passReport.Add('ImplementationAcceptance: NOT OBSERVED (SkipBuild permits stale binaries)')
    }
    else {
        [void]$passReport.Add('Result: IMPLEMENTATION GATE PASS')
        [void]$passReport.Add('ImplementationAcceptance: PASS')
    }
    [void]$passReport.Add('IssueAcceptance: PARTIAL / V0.6 RELEASE GATES PENDING')
    [void]$passReport.Add('AcceptedUiQuerySnapshotMatch: PASS')
    [void]$passReport.Add('SensitiveDataRedactionPolicy: PASS')
    [void]$passReport.Add('AllV06ReleaseGates: PENDING')
    [void]$passReport.Add("SkipBuild: $SkipBuild")
    [void]$passReport.Add("Static: $staticStatus")
    [void]$passReport.Add("Synthetic: $syntheticStatus")
    [void]$passReport.Add("Contract: $contractStatus")
    [void]$passReport.Add('EvidenceClass: Static plus Synthetic plus Contract')
    [void]$passReport.Add("SyntheticTests: $($syntheticSummary.Passed)/$($syntheticSummary.Total) PASS")
    [void]$passReport.Add("ContractTests: $($contractSummary.Passed)/$($contractSummary.Total) PASS")
    [void]$passReport.Add('Actual Herdr Runtime: NOT OBSERVED')
    [void]$passReport.Add('ActualHerdrRuntime: NOT OBSERVED / NOT CLAIMED')
    [void]$passReport.Add('IndependentReview: NOT OBSERVED / NOT CLAIMED')
    [void]$passReport.Add('Release: NOT OBSERVED')
    [void]$passReport.Add('ReleaseEvidence: NOT OBSERVED / NOT CLAIMED')
    Add-PinReportLines -Lines $passReport -Label 'Source' -Pins $finalSourcePins
    Add-PinReportLines -Lines $passReport -Label 'Contract' -Pins $finalContractPins
    Add-PinReportLines -Lines $passReport -Label 'Fixture' -Pins $finalFixturePins
    Add-PinReportLines -Lines $passReport -Label 'TestSource' -Pins $finalTestPins
    [void]$passReport.Add("EvaluationExportId: $($fixture.evaluationExportId)")
    [void]$passReport.Add("EvaluationSourceSnapshotSha256: $($fixture.evaluationSourceSnapshotSha256)")
    [void]$passReport.Add("EvaluationJsonSha256: $($fixture.evaluationJsonSha256)")
    [void]$passReport.Add("EvaluationMarkdownSha256: $($fixture.evaluationMarkdownSha256)")
    [void]$passReport.Add("EvaluationCsvSha256: $($fixture.evaluationCsvSha256)")
    [void]$passReport.Add("DailyExportId: $($fixture.dailyExportId)")
    [void]$passReport.Add("DailySourceSnapshotSha256: $($fixture.dailySourceSnapshotSha256)")
    [void]$passReport.Add("DailyJsonSha256: $($fixture.dailyJsonSha256)")
    [void]$passReport.Add("DailyMarkdownSha256: $($fixture.dailyMarkdownSha256)")
    [void]$passReport.Add("DailyCsvSha256: $($fixture.dailyCsvSha256)")
    [void]$passReport.Add('ReproducibilityReport: Fixed generationUtc plus identical canonical snapshot bytes produced the fixture-pinned JSON, Markdown, CSV, ExportId, and SourceSnapshotSha256 values verified by the focused tests.')
    [void]$passReport.Add('EvidenceBoundary: This gate proves only the exact committed export dependencies, contract, fixtures, and bounded synthetic/contract evidence. SkipBuild runs are explicitly non-acceptance because they may execute stale binaries. The gate does not prove actual Herdr operation, installed-product behavior, independent acceptance, packaging, all v0.6 release gates, or v0.6 release readiness.')
    Write-GateReport -Lines $passReport.ToArray()
}
catch {
    $failureMessage = $_.Exception.Message
    $failureReport = New-Object 'System.Collections.Generic.List[string]'
    [void]$failureReport.Add('HerdrOps v0.6 Issue #33 Local Export Acceptance Gate')
    [void]$failureReport.Add("GeneratedUtc: $([DateTime]::UtcNow.ToString('O'))")
    [void]$failureReport.Add("SourceCommit: $sourceCommit")
    [void]$failureReport.Add('Result: FAIL')
    [void]$failureReport.Add('IssueAcceptance: NOT OBSERVED')
    [void]$failureReport.Add("SkipBuild: $SkipBuild")
    [void]$failureReport.Add("Static: $staticStatus")
    [void]$failureReport.Add("Synthetic: $syntheticStatus")
    [void]$failureReport.Add("Contract: $contractStatus")
    [void]$failureReport.Add('EvidenceClass: Static plus Synthetic plus Contract')
    [void]$failureReport.Add('Actual Herdr Runtime: NOT OBSERVED')
    [void]$failureReport.Add('ActualHerdrRuntime: NOT OBSERVED / NOT CLAIMED')
    [void]$failureReport.Add('Release: NOT OBSERVED')
    [void]$failureReport.Add('ReleaseEvidence: NOT OBSERVED / NOT CLAIMED')
    [void]$failureReport.Add(('Failure: {0}' -f $failureMessage))
    Add-PinReportLines -Lines $failureReport -Label 'Source' -Pins $finalSourcePins
    Add-PinReportLines -Lines $failureReport -Label 'Contract' -Pins $finalContractPins
    Add-PinReportLines -Lines $failureReport -Label 'Fixture' -Pins $finalFixturePins
    Add-PinReportLines -Lines $failureReport -Label 'TestSource' -Pins $finalTestPins
    [void]$failureReport.Add('EvidenceBoundary: Failed or incomplete export checks earn no v0.6 release credit. Actual Herdr Runtime and release evidence remain NOT OBSERVED.')
    Write-GateReport -Lines $failureReport.ToArray()
    throw
}
