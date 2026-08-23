[CmdletBinding()]
param(
    [ValidateSet('Debug', 'Release')]
    [string]$Configuration = 'Release',

    [switch]$SkipBuild
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repositoryRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')).Path
$artifactRoot = Join-Path $repositoryRoot 'artifacts'
$approvedReferenceSha256 = '7721C24EE49887286854D07132BBFE12C52B028AAE50CE7EB8062F0877C2B23D'

function Assert-InRepository {
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )

    $separatorChars = [char[]]@([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
    $normalizedRoot = [IO.Path]::GetFullPath($repositoryRoot).TrimEnd($separatorChars)
    $normalizedPath = [IO.Path]::GetFullPath($Path)
    $rootPrefix = $normalizedRoot + [IO.Path]::DirectorySeparatorChar
    if ($normalizedPath -ne $normalizedRoot -and
        -not $normalizedPath.StartsWith($rootPrefix, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Resolved path is outside the repository root: $normalizedPath"
    }

    return $normalizedPath
}

function Get-RepositoryPath {
    param(
        [Parameter(Mandatory)]
        [string]$RelativePath
    )

    if ([string]::IsNullOrWhiteSpace($RelativePath) -or [IO.Path]::IsPathRooted($RelativePath)) {
        throw "Repository path must be a non-empty relative path: $RelativePath"
    }

    return Assert-InRepository -Path ([IO.Path]::GetFullPath((Join-Path $repositoryRoot $RelativePath)))
}

function Get-RepositoryRelativePath {
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )

    $normalizedPath = Assert-InRepository -Path $Path
    $separatorChars = [char[]]@([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
    $normalizedRoot = [IO.Path]::GetFullPath($repositoryRoot).TrimEnd($separatorChars)
    if ($normalizedPath -eq $normalizedRoot) {
        return ''
    }

    return $normalizedPath.Substring(($normalizedRoot + [IO.Path]::DirectorySeparatorChar).Length).Replace('\', '/')
}

function Assert-RequiredFile {
    param(
        [Parameter(Mandatory)]
        [string]$Path,

        [Parameter(Mandatory)]
        [string]$Description
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "Required Issue #31 $Description is missing: $Path"
    }

    $resolvedPath = (Resolve-Path -LiteralPath $Path).Path
    [void](Assert-InRepository -Path $resolvedPath)
    return $resolvedPath
}

function Assert-ContainsText {
    param(
        [Parameter(Mandatory)]
        [string]$Path,

        [Parameter(Mandatory)]
        [string[]]$RequiredText,

        [Parameter(Mandatory)]
        [string]$Description
    )

    $content = Get-Content -LiteralPath $Path -Raw
    foreach ($text in $RequiredText) {
        if ($content.IndexOf($text, [StringComparison]::Ordinal) -lt 0) {
            throw "Issue #31 $Description is missing required marker '$text': $Path"
        }
    }
}

function Get-PngUInt32 {
    param(
        [Parameter(Mandatory)]
        [byte[]]$Bytes,

        [Parameter(Mandatory)]
        [int]$Offset
    )

    return [uint32](([uint64]$Bytes[$Offset] -shl 24) -bor
        ([uint64]$Bytes[$Offset + 1] -shl 16) -bor
        ([uint64]$Bytes[$Offset + 2] -shl 8) -bor
        [uint64]$Bytes[$Offset + 3])
}

function Get-PngMetadata {
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )

    $bytes = [IO.File]::ReadAllBytes($Path)
    if ($bytes.Length -lt 33) {
        throw "PNG is truncated or too small: $Path"
    }

    $signature = [byte[]](137, 80, 78, 71, 13, 10, 26, 10)
    for ($index = 0; $index -lt $signature.Length; $index++) {
        if ($bytes[$index] -ne $signature[$index]) {
            throw "Required evidence is not a PNG: $Path"
        }
    }

    $offset = 8
    $hasIhdr = $false
    $hasIend = $false
    $width = 0
    $height = 0
    while ($offset -lt $bytes.Length) {
        if ($bytes.Length - $offset -lt 12) {
            throw "PNG has an incomplete chunk: $Path"
        }

        $chunkLength = [uint64](Get-PngUInt32 -Bytes $bytes -Offset $offset)
        $chunkEnd = [uint64]$offset + 12 + $chunkLength
        if ($chunkEnd -gt [uint64]$bytes.Length) {
            throw "PNG chunk extends beyond the file: $Path"
        }

        $chunkType = [Text.Encoding]::ASCII.GetString($bytes, $offset + 4, 4)
        if (-not $hasIhdr -and $chunkType -ne 'IHDR') {
            throw "PNG does not begin with IHDR: $Path"
        }

        if ($chunkType -eq 'IHDR') {
            if ($hasIhdr -or $offset -ne 8 -or $chunkLength -ne 13) {
                throw "PNG has an invalid IHDR chunk: $Path"
            }

            $width = [int](Get-PngUInt32 -Bytes $bytes -Offset ($offset + 8))
            $height = [int](Get-PngUInt32 -Bytes $bytes -Offset ($offset + 12))
            if ($width -le 0 -or $height -le 0) {
                throw "PNG has invalid dimensions: $Path"
            }

            $hasIhdr = $true
        }

        if ($chunkType -eq 'IEND') {
            if ($chunkLength -ne 0) {
                throw "PNG has an invalid IEND chunk: $Path"
            }

            $hasIend = $true
            $offset = [int]$chunkEnd
            break
        }

        $offset = [int]$chunkEnd
    }

    if (-not $hasIhdr -or -not $hasIend -or $offset -ne $bytes.Length) {
        throw "PNG is missing a complete IHDR/IEND structure: $Path"
    }

    return [pscustomobject]@{
        Width = $width
        Height = $height
        Length = [int64]$bytes.Length
    }
}

function Invoke-GitCapture {
    param(
        [Parameter(Mandatory)]
        [string[]]$Arguments
    )

    $output = @(& git -C $repositoryRoot @Arguments 2>&1)
    if ($LASTEXITCODE -ne 0) {
        throw "Git command failed: git -C $repositoryRoot $($Arguments -join ' ')"
    }

    return @($output | ForEach-Object { [string]$_ })
}

function Get-TestMethodNames {
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )

    $content = Get-Content -LiteralPath $Path -Raw
    $pattern = '(?ms)\[TestMethod\](?:\s*\[[^\]]+\])*\s*public\s+(?:static\s+)?(?:[\w<>\[\],?]+\s+)+(?<Name>[A-Za-z_][A-Za-z0-9_]*)\s*\('
    $names = @([regex]::Matches($content, $pattern) | ForEach-Object { $_.Groups['Name'].Value })
    $names = @($names | Sort-Object -Unique)
    if ($names.Count -eq 0) {
        throw "Issue #31 test source has no [TestMethod] names: $Path"
    }

    return $names
}

function Get-TrxCounter {
    param(
        [Parameter(Mandatory)]
        [System.Xml.XmlElement]$Counters,

        [Parameter(Mandatory)]
        [string]$Name
    )

    if (-not $Counters.HasAttribute($Name)) {
        throw "Fresh TRX result is missing counter '$Name'."
    }

    $rawValue = $Counters.GetAttribute($Name)
    if ([string]::IsNullOrWhiteSpace($rawValue) -or $rawValue -notmatch '^(0|[1-9][0-9]*)$') {
        throw "Fresh TRX counter '$Name' is malformed: '$rawValue'."
    }

    try {
        return [int64]$rawValue
    }
    catch {
        throw "Fresh TRX counter '$Name' is outside the supported range: '$rawValue'."
    }
}

function Assert-AllPassingCounters {
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary]$Counters,

        [Parameter(Mandatory)]
        [string]$Name
    )

    if ($Counters['total'] -le 0 -or
        $Counters['executed'] -ne $Counters['total'] -or
        $Counters['passed'] -ne $Counters['total'] -or
        $Counters['failed'] -ne 0 -or
        $Counters['error'] -ne 0 -or
        $Counters['timeout'] -ne 0 -or
        $Counters['aborted'] -ne 0 -or
        $Counters['inconclusive'] -ne 0 -or
        $Counters['notExecuted'] -ne 0 -or
        $Counters['completed'] -ne 0 -or
        $Counters['notRunnable'] -ne 0 -or
        $Counters['disconnected'] -ne 0 -or
        $Counters['warning'] -ne 0) {
        throw "Issue #31 $Name TRX counters are not an exact all-pass result: $($Counters | Out-String)"
    }
}

function Get-StatusLabel {
    param(
        [Parameter(Mandatory)]
        [string[]]$Status
    )

    if ($Status.Count -eq 0) {
        return 'CLEAN'
    }

    return 'DIRTY'
}

$referencePath = Get-RepositoryPath -RelativePath 'docs\design\reference\09-evaluation.png'
$referencePath = Assert-RequiredFile -Path $referencePath -Description 'immutable Evaluation reference PNG'
$referencePng = Get-PngMetadata -Path $referencePath
if ($referencePng.Width -ne 1672 -or $referencePng.Height -ne 941) {
    throw "Approved Evaluation reference dimensions drifted: expected 1672x941, observed $($referencePng.Width)x$($referencePng.Height)"
}
$referenceSha256 = (Get-FileHash -LiteralPath $referencePath -Algorithm SHA256).Hash.ToUpperInvariant()
if ($referenceSha256 -ne $approvedReferenceSha256) {
    throw "Approved Evaluation reference SHA-256 drifted: expected $approvedReferenceSha256 observed $referenceSha256"
}

$requiredFiles = @(
    [ordered]@{ Name = 'EvaluationState'; RelativePath = 'src\HerdrOps.App\Evaluation\EvaluationState.cs'; Description = 'EvaluationState.cs' }
    [ordered]@{ Name = 'EvaluationView'; RelativePath = 'src\HerdrOps.App\Views\EvaluationView.xaml'; Description = 'EvaluationView.xaml' }
    [ordered]@{ Name = 'EvaluationViewCodeBehind'; RelativePath = 'src\HerdrOps.App\Views\EvaluationView.xaml.cs'; Description = 'EvaluationView.xaml.cs' }
    [ordered]@{ Name = 'EvaluationRenderingTests'; RelativePath = 'tests\HerdrOps.RuntimeTests\EvaluationRenderingTests.cs'; Description = 'EvaluationRenderingTests.cs' }
    [ordered]@{ Name = 'EvaluationStateTests'; RelativePath = 'tests\HerdrOps.IntegrationTests\EvaluationStateTests.cs'; Description = 'EvaluationStateTests.cs' }
    [ordered]@{ Name = 'EvaluationPresentationContractTests'; RelativePath = 'tests\HerdrOps.ContractTests\EvaluationPresentationContractTests.cs'; Description = 'EvaluationPresentationContractTests.cs' }
    [ordered]@{ Name = 'UiLanguageCatalogTests'; RelativePath = 'tests\HerdrOps.IntegrationTests\UiLanguageCatalogTests.cs'; Description = 'UiLanguageCatalogTests.cs' }
)
$requiredFileByName = @{}
foreach ($entry in $requiredFiles) {
    $entry['Path'] = Assert-RequiredFile `
        -Path (Get-RepositoryPath -RelativePath ([string]$entry['RelativePath'])) `
        -Description ([string]$entry['Description'])
    $entry['Sha256'] = (Get-FileHash -LiteralPath $entry['Path'] -Algorithm SHA256).Hash.ToUpperInvariant()
    if ([string]$entry['Sha256'] -notmatch '^[0-9A-F]{64}$') {
        throw "Required Issue #31 file produced an invalid SHA-256: $($entry['Path'])"
    }

    $requiredFileByName[[string]$entry['Name']] = $entry
}

Assert-ContainsText `
    -Path $requiredFileByName['EvaluationRenderingTests']['Path'] `
    -Description 'synthetic rendering test source' `
    -RequiredText @('RenderTargetBitmap', '1672', '941', '1366', '768', 'issue-31', 'evaluation')

$testDefinitions = @(
    [ordered]@{
        Name = 'Contract'
        ProjectRelativePath = 'tests\HerdrOps.ContractTests\HerdrOps.ContractTests.csproj'
        Filter = 'FullyQualifiedName~EvaluationPresentationContractTests'
        Log = 'evaluation-contract.trx'
        SourceNames = @('EvaluationPresentationContractTests')
    }
    [ordered]@{
        Name = 'Integration'
        ProjectRelativePath = 'tests\HerdrOps.IntegrationTests\HerdrOps.IntegrationTests.csproj'
        Filter = 'FullyQualifiedName~EvaluationStateTests|FullyQualifiedName~UiLanguageCatalogTests'
        Log = 'evaluation-integration.trx'
        SourceNames = @('EvaluationStateTests', 'UiLanguageCatalogTests')
    }
    [ordered]@{
        Name = 'Synthetic rendering'
        ProjectRelativePath = 'tests\HerdrOps.RuntimeTests\HerdrOps.RuntimeTests.csproj'
        Filter = 'FullyQualifiedName~EvaluationRenderingTests'
        Log = 'evaluation-rendering.trx'
        SourceNames = @('EvaluationRenderingTests')
    }
)

foreach ($definition in $testDefinitions) {
    $definition['Project'] = Assert-RequiredFile `
        -Path (Get-RepositoryPath -RelativePath ([string]$definition['ProjectRelativePath'])) `
        -Description "$($definition['Name']) test project"
    $definition['TestNames'] = @()
    foreach ($sourceName in @($definition['SourceNames'])) {
        $sourceEntry = $requiredFileByName[[string]$sourceName]
        $sourceContent = Get-Content -LiteralPath $sourceEntry['Path'] -Raw
        if (-not [regex]::IsMatch($sourceContent, '(?m)\bclass\s+' + [regex]::Escape([string]$sourceName) + '\b')) {
            throw "Issue #31 test source does not declare the expected class ${sourceName}: $($sourceEntry['Path'])"
        }

        $definition['TestNames'] += @(Get-TestMethodNames -Path $sourceEntry['Path'])
    }

    $definition['TestNames'] = @($definition['TestNames'] | Sort-Object -Unique)
    if ($definition['TestNames'].Count -eq 0) {
        throw "Issue #31 $($definition['Name']) run has no required test names."
    }
}

$sourceCommitOutput = @(Invoke-GitCapture -Arguments @('rev-parse', '--verify', 'HEAD^{commit}'))
$sourceCommit = ($sourceCommitOutput -join '').Trim()
if ([string]::IsNullOrWhiteSpace($sourceCommit) -or $sourceCommit -notmatch '^[0-9a-fA-F]{40}$') {
    throw 'Could not resolve a committed source HEAD for the Issue #31 gate.'
}
$initialWorkingTreeStatus = @(Invoke-GitCapture -Arguments @('status', '--porcelain=v1', '--untracked-files=all'))

$artifactRoot = Get-RepositoryPath -RelativePath 'artifacts'
$runId = "$([DateTime]::UtcNow.ToString('yyyyMMddTHHmmssfffffffZ', [Globalization.CultureInfo]::InvariantCulture))-$([Guid]::NewGuid().ToString('N').Substring(0, 8))"
$gateDirectory = Join-Path $artifactRoot "release-gates\v0.6.0\issue-31\$runId"
[void](Assert-InRepository -Path $gateDirectory)
if (Test-Path -LiteralPath $gateDirectory) {
    throw "Generated Issue #31 gate directory already exists: $gateDirectory"
}
$testResultDirectory = Join-Path $gateDirectory 'test-results'
New-Item -ItemType Directory -Path $testResultDirectory -Force | Out-Null

$buildResult = 'SKIPPED'
if (-not $SkipBuild) {
    $buildScript = Assert-RequiredFile `
        -Path (Get-RepositoryPath -RelativePath 'tools\Invoke-Build.ps1') `
        -Description 'Issue #31 build helper'
    & $buildScript -Configuration $Configuration -SkipTests -VerifyFormat
    if ($LASTEXITCODE -ne 0) {
        throw "Issue #31 build gate failed with exit code $LASTEXITCODE."
    }

    $buildResult = 'PASS'
}

$capturePattern = '(?i)(?<FileName>evaluation-[a-z0-9-]+-(?<Width>[0-9]+)x(?<Height>[0-9]+)\.png)'
$renderingSource = Get-Content -LiteralPath $requiredFileByName['EvaluationRenderingTests']['Path'] -Raw
$captureRequirementsByName = [ordered]@{}
foreach ($match in [regex]::Matches($renderingSource, $capturePattern)) {
    $fileName = $match.Groups['FileName'].Value
    $captureRequirementsByName[$fileName] = [ordered]@{
        FileName = $fileName
        Width = [int]$match.Groups['Width'].Value
        Height = [int]$match.Groups['Height'].Value
    }
}

foreach ($requiredCaptureName in @('evaluation-th-1672x941.png', 'evaluation-en-1672x941.png')) {
    if (-not $captureRequirementsByName.Contains($requiredCaptureName)) {
        throw "Synthetic rendering test does not name the required reference capture: $requiredCaptureName"
    }
}
if (@($captureRequirementsByName.Values | Where-Object { $_['Width'] -eq 1366 -and $_['Height'] -eq 768 }).Count -eq 0) {
    throw 'Synthetic rendering test does not name a required 1366x768 compact capture.'
}

$evidenceDirectory = Get-RepositoryPath -RelativePath 'artifacts\design-evidence\v0.6.0\issue-31\evaluation'
$testResultEvidence = @()
$evidenceStartedUtc = $null
$counterNames = @('total', 'executed', 'passed', 'failed', 'error', 'timeout', 'aborted', 'inconclusive', 'notExecuted', 'completed', 'notRunnable', 'disconnected', 'warning')
foreach ($definition in $testDefinitions) {
    if ([string]$definition['Name'] -eq 'Synthetic rendering') {
        $evidenceStartedUtc = [DateTime]::UtcNow
    }

    $logPath = Join-Path $testResultDirectory ([string]$definition['Log'])
    $existingTrx = @(Get-ChildItem -LiteralPath $testResultDirectory -Recurse -Filter '*.trx' -File)
    if ($existingTrx.Count -ne $testResultEvidence.Count) {
        throw "Issue #31 test result directory was not fresh before $($definition['Name']) tests."
    }

    $testStartedUtc = [DateTime]::UtcNow
    & dotnet test $definition['Project'] `
        --configuration $Configuration `
        --no-restore `
        --no-build `
        --artifacts-path $artifactRoot `
        --results-directory $testResultDirectory `
        --filter $definition['Filter'] `
        --logger "trx;LogFileName=$($definition['Log'])"
    if ($LASTEXITCODE -ne 0) {
        throw "Issue #31 $($definition['Name']) tests failed with exit code $LASTEXITCODE."
    }

    $trxCandidates = @(Get-ChildItem -LiteralPath $testResultDirectory -Recurse -Filter ([string]$definition['Log']) -File)
    if ($trxCandidates.Count -ne 1) {
        throw "Expected exactly one fresh Issue #31 $($definition['Name']) TRX named $($definition['Log']), found $($trxCandidates.Count)."
    }

    $trxPath = $trxCandidates[0].FullName
    $trxItem = Get-Item -LiteralPath $trxPath
    if ($trxItem.LastWriteTimeUtc -lt $testStartedUtc.AddSeconds(-2) -or $trxItem.Length -le 0) {
        throw "Issue #31 $($definition['Name']) TRX is stale or empty: $trxPath"
    }

    $trxLog = Get-Content -LiteralPath $trxPath -Raw
    [xml]$trx = $trxLog
    $counters = $trx.TestRun.ResultSummary.Counters
    if ($null -eq $counters) {
        throw "Issue #31 $($definition['Name']) TRX has no ResultSummary.Counters element: $trxPath"
    }

    $counterEvidence = [ordered]@{}
    foreach ($counterName in $counterNames) {
        $counterEvidence[$counterName] = Get-TrxCounter -Counters $counters -Name $counterName
    }
    Assert-AllPassingCounters -Counters $counterEvidence -Name ([string]$definition['Name'])
    foreach ($testName in @($definition['TestNames'])) {
        if ($trxLog -notmatch [regex]::Escape([string]$testName)) {
            throw "Required Issue #31 test name is absent from fresh $($definition['Name']) TRX: $testName"
        }
    }

    $testResultEvidence += [pscustomobject]@{
        Name = [string]$definition['Name']
        Path = $trxPath
        Log = [string]$definition['Log']
        Counters = $counterEvidence
        Sha256 = (Get-FileHash -LiteralPath $trxPath -Algorithm SHA256).Hash.ToUpperInvariant()
    }
}

if ($null -eq $evidenceStartedUtc) {
    throw 'Issue #31 synthetic rendering evidence start time was not recorded.'
}

$allTrx = @(Get-ChildItem -LiteralPath $testResultDirectory -Recurse -Filter '*.trx' -File)
if ($allTrx.Count -ne $testDefinitions.Count) {
    throw "Expected exactly $($testDefinitions.Count) fresh Issue #31 TRX files, found $($allTrx.Count)."
}

if (-not (Test-Path -LiteralPath $evidenceDirectory -PathType Container)) {
    throw "Issue #31 synthetic evidence directory is missing: $evidenceDirectory"
}

$captureEvidence = @()
$captureByName = @{}
foreach ($captureRequirement in @($captureRequirementsByName.Values)) {
    $capturePath = Join-Path $evidenceDirectory ([string]$captureRequirement['FileName'])
    $capturePath = Assert-RequiredFile -Path $capturePath -Description "$($captureRequirement['FileName']) synthetic PNG evidence"
    $captureItem = Get-Item -LiteralPath $capturePath
    if ($captureItem.Length -le 10000) {
        throw "Issue #31 PNG evidence is unexpectedly small: $capturePath"
    }
    if ($captureItem.LastWriteTimeUtc -lt $evidenceStartedUtc.AddSeconds(-2)) {
        throw "Issue #31 PNG evidence is stale and was not freshly rendered: $capturePath"
    }

    $png = Get-PngMetadata -Path $capturePath
    if ($png.Width -ne [int]$captureRequirement['Width'] -or
        $png.Height -ne [int]$captureRequirement['Height']) {
        throw "Issue #31 PNG dimensions drifted for $capturePath`: expected $($captureRequirement['Width'])x$($captureRequirement['Height']), observed $($png.Width)x$($png.Height)"
    }

    $captureRecord = [pscustomobject]@{
        FileName = [string]$captureRequirement['FileName']
        Path = $capturePath
        Width = $png.Width
        Height = $png.Height
        Length = $png.Length
        Sha256 = (Get-FileHash -LiteralPath $capturePath -Algorithm SHA256).Hash.ToUpperInvariant()
    }
    $captureEvidence += $captureRecord
    $captureByName[$captureRecord.FileName] = $captureRecord
}

if ($captureByName['evaluation-th-1672x941.png'].Sha256 -eq $captureByName['evaluation-en-1672x941.png'].Sha256) {
    throw 'Thai and English Issue #31 reference captures have identical bytes.'
}
foreach ($capture in @($captureEvidence | Where-Object { $_.FileName -match '(?i)missing|score' })) {
    if ($capture.Width -eq 1672 -and $capture.Height -eq 941 -and
        $capture.Sha256 -eq $captureByName['evaluation-th-1672x941.png'].Sha256) {
        throw "Missing-score Issue #31 evidence is byte-identical to the complete Thai capture: $($capture.FileName)"
    }
}

foreach ($entry in $requiredFiles) {
    $observedSha256 = (Get-FileHash -LiteralPath $entry['Path'] -Algorithm SHA256).Hash.ToUpperInvariant()
    if ($observedSha256 -ne [string]$entry['Sha256']) {
        throw "Issue #31 required file changed during the gate: $($entry['Path'])"
    }
}
$finalReferenceSha256 = (Get-FileHash -LiteralPath $referencePath -Algorithm SHA256).Hash.ToUpperInvariant()
if ($finalReferenceSha256 -ne $approvedReferenceSha256) {
    throw "Approved Evaluation reference changed during the gate: $referencePath"
}

$finalSourceCommitOutput = @(Invoke-GitCapture -Arguments @('rev-parse', '--verify', 'HEAD^{commit}'))
$finalSourceCommit = ($finalSourceCommitOutput -join '').Trim()
$finalWorkingTreeStatus = @(Invoke-GitCapture -Arguments @('status', '--porcelain=v1', '--untracked-files=all'))
if ($finalSourceCommit -ne $sourceCommit) {
    throw "Source commit changed while the Issue #31 gate ran: $sourceCommit -> $finalSourceCommit"
}

$sourceHashReport = @()
foreach ($entry in $requiredFiles) {
    $sourceHashReport += "SHA256 $($entry['Sha256']) SourceTest $($entry['Name']) $(Get-RepositoryRelativePath -Path $entry['Path'])"
}
$testCounterReport = @()
foreach ($testResult in $testResultEvidence) {
    $counters = $testResult.Counters
    $testCounterReport += "TRX $($testResult.Name) total=$($counters['total']) executed=$($counters['executed']) passed=$($counters['passed']) failed=$($counters['failed']) error=$($counters['error']) timeout=$($counters['timeout']) aborted=$($counters['aborted']) inconclusive=$($counters['inconclusive']) notExecuted=$($counters['notExecuted']) completed=$($counters['completed']) notRunnable=$($counters['notRunnable']) disconnected=$($counters['disconnected']) warning=$($counters['warning']) sha256=$($testResult.Sha256)"
}
$testNameReport = @()
foreach ($definition in $testDefinitions) {
    foreach ($testName in @($definition['TestNames'])) {
        $testNameReport += "PASS $($definition['Name']) $testName"
    }
}
$captureReport = @()
foreach ($capture in $captureEvidence) {
    $captureReport += "PNG $($capture.FileName) $($capture.Width)x$($capture.Height) bytes=$($capture.Length) sha256=$($capture.Sha256)"
}
$initialStatusLabel = Get-StatusLabel -Status $initialWorkingTreeStatus
$finalStatusLabel = Get-StatusLabel -Status $finalWorkingTreeStatus

$gateReportPath = Join-Path $gateDirectory 'gate-report.txt'
$gateReport = @(
    'HerdrOps v0.6 Issue #31 Evaluation Page Implementation Gate',
    "GeneratedUtc: $([DateTime]::UtcNow.ToString('O'))",
    "SourceCommit: $sourceCommit",
    "WorkingTreeStatus: $finalStatusLabel",
    "WorkingTreeStatusAtStart: $initialStatusLabel",
    "WorkingTreeStatusAtEnd: $finalStatusLabel",
    "Build: $buildResult",
    'Result: PASS',
    'ImplementationGate: PASS',
    'IssueAcceptance: PENDING INDEPENDENT REVIEW',
    'VersionReleaseGate: PENDING',
    'StaticEvidence: OBSERVED',
    'ContractEvidence: OBSERVED',
    'SyntheticEvidence: OBSERVED AGAINST SYNTHETIC PREVIEW DATA',
    'ActualHerdrRuntime: NOT OBSERVED / NOT CLAIMED',
    'IndependentReview: NOT OBSERVED / NOT CLAIMED',
    'ReleaseEvidence: NOT OBSERVED / NOT CLAIMED',
    "ApprovedReference: $(Get-RepositoryRelativePath -Path $referencePath)",
    "ApprovedReferenceSha256: $referenceSha256",
    "ApprovedReferenceDimensions: $($referencePng.Width)x$($referencePng.Height)",
    '',
    'RequiredSourceAndTestFileSha256:'
) + $sourceHashReport + @(
    '',
    'FreshTrxCountersAndSha256:'
) + $testCounterReport + @(
    '',
    'RequiredTestNames:'
) + $testNameReport + @(
    '',
    'FreshPngEvidence:'
) + $captureReport + @(
    '',
    'WorkingTreeStatusEntriesAtStart:'
) + @($initialWorkingTreeStatus | ForEach-Object { "STATUS $_" }) + @(
    '',
    'WorkingTreeStatusEntriesAtEnd:'
) + @($finalWorkingTreeStatus | ForEach-Object { "STATUS $_" }) + @(
    '',
    'EvidenceBoundary:',
    'Static evidence covers the pinned immutable reference, required source/test presence, stable source/test hashes, and PNG structure/dimensions.',
    'Contract evidence covers the fresh Evaluation presentation contract test result. Integration evidence covers Evaluation state and selected-language catalog tests. Synthetic evidence covers WPF rendering from synthetic preview data and fresh Thai/English captures.',
    'This gate does not prove an installed Herdr instance, actual Herdr runtime behavior, role authorization, independent acceptance, package installation, or v0.6 release readiness.'
)
$gateReport | Set-Content -LiteralPath $gateReportPath -Encoding UTF8
$gateReport | Write-Output
Write-Output "GateReport: $gateReportPath"
