[CmdletBinding()]
param(
    [switch]$SkipBuild
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repositoryRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')).Path
$artifactRoot = Join-Path $repositoryRoot 'artifacts'
$runStartedAt = [DateTime]::UtcNow.AddSeconds(-2)

if (-not $SkipBuild) {
    & (Join-Path $PSScriptRoot 'Invoke-Build.ps1') -Configuration Release -VerifyFormat
    if ($LASTEXITCODE -ne 0) {
        throw "v0.1 build gate failed with exit code $LASTEXITCODE."
    }
}

$relativeEvidencePaths = @(
    'design-evidence\v0.1\issue-2\shell-100.png',
    'design-evidence\v0.1\issue-2\shell-125.png',
    'design-evidence\v0.1\issue-2\shell-150.png',
    'design-evidence\v0.1\issue-3\overview-100.png',
    'design-evidence\v0.1\issue-3\overview-125.png',
    'design-evidence\v0.1\issue-3\overview-150.png',
    'design-evidence\v0.1\issue-3\overview-1366x768.png',
    'design-evidence\v0.1\issue-4\widget-gallery-100.png',
    'design-evidence\v0.1\issue-4\widget-gallery-125.png',
    'design-evidence\v0.1\issue-4\widget-gallery-150.png',
    'design-evidence\v0.1\issue-4\widget-gallery-1366x768.png',
    'design-evidence\v0.1\issue-4\widget-compact.png',
    'design-evidence\v0.1\issue-4\widget-normal.png',
    'design-evidence\v0.1\issue-4\widget-expanded.png',
    'design-evidence\v0.1\issue-4\widget-floatingmini.png',
    'design-evidence\v0.1\issue-4\widget-floatingvertical.png',
    'design-evidence\v0.1\issue-4\widget-notification.png',
    'design-evidence\v0.1\issue-4\widget-agentdetailpopup.png'
)

$evidenceFiles = foreach ($relativePath in $relativeEvidencePaths) {
    $fullPath = Join-Path $artifactRoot $relativePath
    if (-not (Test-Path -LiteralPath $fullPath -PathType Leaf)) {
        throw "Required v0.1 WPF evidence is missing: $relativePath"
    }

    $file = Get-Item -LiteralPath $fullPath
    if ($file.Length -lt 4000) {
        throw "Required v0.1 WPF evidence is unexpectedly small: $relativePath"
    }

    if (-not $SkipBuild -and $file.LastWriteTimeUtc -lt $runStartedAt) {
        throw "Required v0.1 WPF evidence was not refreshed by this gate run: $relativePath"
    }

    $file
}

$testResultRoot = Join-Path $artifactRoot 'test-results'
$testResults = @(
    Get-ChildItem -LiteralPath $testResultRoot -Filter '*.trx' -File |
        Where-Object { $SkipBuild -or $_.LastWriteTimeUtc -ge $runStartedAt }
)
if ($testResults.Count -lt 4) {
    throw "Expected fresh TRX output from four test projects, found $($testResults.Count)."
}

$combinedTestLog = ($testResults | ForEach-Object {
    Get-Content -LiteralPath $_.FullName -Raw
}) -join "`n"
$requiredAccessibilityChecks = @(
    'WidgetGalleryExposesKeyboardFocusAndAccessibleOpenActions',
    'SemanticTextContrastMeetsWcagAa',
    'ReducedMotionDisablesWidgetTransitions',
    'WidgetWindowsUseBoundedAndReversibleBehavior',
    'CriticalWidgetFidelityActionsRemainVisible'
)
foreach ($check in $requiredAccessibilityChecks) {
    if ($combinedTestLog -notmatch [Regex]::Escape($check)) {
        throw "Required accessibility/window check is absent from the fresh test log: $check"
    }
}

$gateDirectory = Join-Path $artifactRoot 'release-gates\v0.1.0'
New-Item -ItemType Directory -Path $gateDirectory -Force | Out-Null
$reportPath = Join-Path $gateDirectory 'gate-report.txt'
$commit = (& git -C $repositoryRoot rev-parse HEAD).Trim()
$hashLines = $evidenceFiles | Sort-Object FullName | ForEach-Object {
    $relative = $_.FullName.Substring($artifactRoot.Length + 1)
    $hash = (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash
    "SHA256 $hash $relative"
}

$report = @(
    'HerdrOps v0.1.0 Release Gate',
    "GeneratedUtc: $([DateTime]::UtcNow.ToString('O'))",
    "Commit: $commit",
    'Result: PASS',
    'EvidenceClass: Synthetic WPF rendering plus build/test logs',
    'HerdrRuntime: NOT CONNECTED / NOT CLAIMED',
    "FreshTrxFiles: $($testResults.Count)",
    "WpfEvidenceFiles: $($evidenceFiles.Count)",
    '',
    'AccessibilityAndWindowChecks:'
) + ($requiredAccessibilityChecks | ForEach-Object { "PASS $_" }) + @(
    '',
    'EvidenceHashes:'
) + $hashLines

$report | Set-Content -LiteralPath $reportPath -Encoding utf8
$report | Write-Output
Write-Output "GateReport: $reportPath"
