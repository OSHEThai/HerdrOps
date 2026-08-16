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
        --logger "trx;LogFileName=$LogFileName"
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

$sourceFiles = @(Get-DiscoveredFiles `
    -Root (Join-Path $repositoryRoot 'src') `
    -Extension '.cs' `
    -NamePattern '(?i)export')
$contractFiles = @(Get-DiscoveredFiles `
    -Root (Join-Path $repositoryRoot 'docs\protocol') `
    -Extension '.md' `
    -NamePattern '(?i)export')
$fixtureFiles = @(Get-DiscoveredFiles `
    -Root (Join-Path $repositoryRoot 'tests\fixtures\v0.6') `
    -Extension '.json' `
    -NamePattern '(?i)export')

$sourcePins = @()
$contractPins = @()
$fixturePins = @()
if ($sourceFiles.Count -gt 0) {
    $sourcePins = @(Get-FilePins -Files $sourceFiles)
}
if ($contractFiles.Count -gt 0) {
    $contractPins = @(Get-FilePins -Files $contractFiles)
}
if ($fixtureFiles.Count -gt 0) {
    $fixturePins = @(Get-FilePins -Files $fixtureFiles)
}

$notReadyReasons = New-Object 'System.Collections.Generic.List[string]'
if ($sourceFiles.Count -eq 0) {
    [void]$notReadyReasons.Add('Exporter source was not discovered under src.')
}
if ($contractFiles.Count -eq 0) {
    [void]$notReadyReasons.Add('Local-export contract was not discovered under docs/protocol.')
}
elseif ($contractFiles.Count -gt 1) {
    [void]$notReadyReasons.Add("Local-export contract discovery is ambiguous: found $($contractFiles.Count) files.")
}
if ($fixtureFiles.Count -eq 0) {
    [void]$notReadyReasons.Add('Local-export fixture was not discovered under tests/fixtures/v0.6.')
}
elseif ($fixtureFiles.Count -gt 1) {
    [void]$notReadyReasons.Add("Local-export fixture discovery is ambiguous: found $($fixtureFiles.Count) files.")
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

try {
    if ($sourceFiles.Count -eq 0) {
        throw 'Exporter source discovery unexpectedly returned no files.'
    }

    foreach ($sourceFile in @($sourceFiles)) {
        $sourceText = Get-Content -LiteralPath $sourceFile.FullName -Raw
        if ([string]::IsNullOrWhiteSpace($sourceText)) {
            throw "Discovered exporter source is empty: $($sourceFile.FullName)"
        }
        if (-not [Regex]::IsMatch($sourceText, '(?i)\bexport\w*\b')) {
            throw "Discovered exporter source has no export implementation marker: $($sourceFile.FullName)"
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
            '(?i)sha[-\s]?256',
            '(?i)provenance',
            '(?i)redact')) {
        if (-not [Regex]::IsMatch($contractText, $contractPattern)) {
            throw "Local-export contract is missing required policy marker: $contractPattern"
        }
    }

    if ($fixtureFiles.Count -ne 1) {
        throw "Expected exactly one local-export fixture, found $($fixtureFiles.Count)."
    }
    $fixtureText = Get-Content -LiteralPath $fixtureFiles[0].FullName -Raw
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

    $syntheticTestFiles = @(Get-DiscoveredFiles `
        -Root (Join-Path $repositoryRoot 'tests\HerdrOps.UnitTests') `
        -Extension '.cs' `
        -NamePattern '(?i)export')
    if ($syntheticTestFiles.Count -eq 0) {
        throw 'Synthetic export evidence tests were not discovered under tests/HerdrOps.UnitTests.'
    }
    $syntheticStatus = 'FAIL'
    $syntheticSummary = Invoke-ExportEvidenceTests `
        -ProjectPath (Join-Path $repositoryRoot 'tests\HerdrOps.UnitTests\HerdrOps.UnitTests.csproj') `
        -Filter 'FullyQualifiedName~Export' `
        -LogFileName 'local-export-synthetic.trx' `
        -EvidenceLabel 'Synthetic'
    $syntheticStatus = 'PASS'

    $contractTestFiles = @(Get-DiscoveredFiles `
        -Root (Join-Path $repositoryRoot 'tests\HerdrOps.ContractTests') `
        -Extension '.cs' `
        -NamePattern '(?i)export')
    if ($contractTestFiles.Count -eq 0) {
        throw 'Contract export evidence tests were not discovered under tests/HerdrOps.ContractTests.'
    }
    $contractStatus = 'FAIL'
    $contractSummary = Invoke-ExportEvidenceTests `
        -ProjectPath (Join-Path $repositoryRoot 'tests\HerdrOps.ContractTests\HerdrOps.ContractTests.csproj') `
        -Filter 'FullyQualifiedName~Export' `
        -LogFileName 'local-export-contract.trx' `
        -EvidenceLabel 'Contract'
    $contractStatus = 'PASS'

    $finalSourcePins = @(Get-FilePins -Files $sourceFiles)
    $finalContractPins = @(Get-FilePins -Files $contractFiles)
    $finalFixturePins = @(Get-FilePins -Files $fixtureFiles)
    if ((Get-PinFingerprint -Pins $finalSourcePins) -cne (Get-PinFingerprint -Pins $sourcePins) -or
        (Get-PinFingerprint -Pins $finalContractPins) -cne (Get-PinFingerprint -Pins $contractPins) -or
        (Get-PinFingerprint -Pins $finalFixturePins) -cne (Get-PinFingerprint -Pins $fixturePins)) {
        throw 'Pinned exporter, contract, or fixture bytes changed during the gate.'
    }

    $passReport = New-Object 'System.Collections.Generic.List[string]'
    [void]$passReport.Add('HerdrOps v0.6 Issue #33 Local Export Acceptance Gate')
    [void]$passReport.Add("GeneratedUtc: $([DateTime]::UtcNow.ToString('O'))")
    [void]$passReport.Add('Result: PASS')
    [void]$passReport.Add('IssueAcceptance: PASS')
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
    [void]$passReport.Add('EvidenceBoundary: This gate proves only the discovered export source/contract/fixture bytes plus bounded synthetic and contract evidence. It does not prove actual Herdr operation, installed-product behavior, independent acceptance, packaging, or v0.6 release readiness.')
    Write-GateReport -Lines $passReport.ToArray()
}
catch {
    $failureMessage = $_.Exception.Message
    $failureReport = New-Object 'System.Collections.Generic.List[string]'
    [void]$failureReport.Add('HerdrOps v0.6 Issue #33 Local Export Acceptance Gate')
    [void]$failureReport.Add("GeneratedUtc: $([DateTime]::UtcNow.ToString('O'))")
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
    [void]$failureReport.Add('EvidenceBoundary: Failed or incomplete export checks earn no v0.6 release credit. Actual Herdr Runtime and release evidence remain NOT OBSERVED.')
    Write-GateReport -Lines $failureReport.ToArray()
    throw
}
