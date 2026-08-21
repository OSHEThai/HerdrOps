[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$CompositeRuntimeReport,

    [Parameter(Mandatory)]
    [string]$RuntimeGateReport,

    [ValidateSet('Debug', 'Release')]
    [string]$Configuration = 'Release',

    [switch]$SkipBuild
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false

$repositoryRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')).Path
$artifactRoot = Join-Path $repositoryRoot 'artifacts'
$sourceCommit = (& git -C $repositoryRoot rev-parse HEAD).Trim()
if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($sourceCommit)) {
    throw 'Could not resolve the source commit for the v0.4 release gate.'
}
$workingTreeStatus = @(& git -C $repositoryRoot status --porcelain=v1 --untracked-files=all)
if ($LASTEXITCODE -ne 0) {
    throw 'Could not inspect the source working tree for the v0.4 release gate.'
}
if ($workingTreeStatus.Count -ne 0) {
    throw "The v0.4 release gate requires a clean committed checkout. Pending paths: $($workingTreeStatus -join ', ')"
}

foreach ($path in @($CompositeRuntimeReport, $RuntimeGateReport)) {
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        throw "Required v0.4 runtime evidence is missing: $path"
    }
}
$resolvedCompositePath = (Resolve-Path -LiteralPath $CompositeRuntimeReport).Path
$resolvedRuntimeGatePath = (Resolve-Path -LiteralPath $RuntimeGateReport).Path
$composite = Get-Content -LiteralPath $resolvedCompositePath -Raw | ConvertFrom-Json
if ($composite.EvidenceClassification -ne 'Runtime' -or
    -not [bool]$composite.RuntimeAccepted -or
    [bool]$composite.SessionControlInvoked -or
    -not [bool]$composite.Acceptance.Passed) {
    throw 'The supplied composite report is not passing role-distinct runtime evidence.'
}
$compositeSha256 = (Get-FileHash -LiteralPath $resolvedCompositePath -Algorithm SHA256).Hash
$runtimeGateText = Get-Content -LiteralPath $resolvedRuntimeGatePath -Raw
foreach ($requiredLine in @(
        'Result: PASS',
        "SourceCommit: $sourceCommit",
        "CompositeRuntimeReportSha256: $compositeSha256")) {
    if ($runtimeGateText -notmatch "(?m)^$([Regex]::Escape($requiredLine))\s*$") {
        throw "The runtime gate report is not bound to this release source and composite report: $requiredLine"
    }
}

$reviewRecords = 18..22 | ForEach-Object {
    Join-Path $repositoryRoot "docs\reviews\v0.4-issue-$($_)-independent-review.md"
}

$scopedReviewBindings = @(
    [pscustomobject]@{
        Issue = 20
        Path = $reviewRecords[2]
        RequiredPaths = @(
            'docs/design/reference/04-delegation-graph.png',
            'docs/design/implementation/v0.4-issue-20-delegation-graph.md',
            'src/HerdrOps.Domain/Assignments/AssignmentDelegationGraph.cs',
            'src/HerdrOps.App/Delegation/DelegationGraphState.cs',
            'src/HerdrOps.App/Views/DelegationGraphView.xaml',
            'src/HerdrOps.App/Views/DelegationGraphView.xaml.cs',
            'src/HerdrOps.App/Views/ShellView.xaml',
            'src/HerdrOps.App/Views/ShellView.xaml.cs',
            'src/HerdrOps.App/Live/LiveDashboardState.cs',
            'src/HerdrOps.App/Localization/UiLanguageService.cs',
            'tests/HerdrOps.UnitTests/AssignmentDelegationGraphTests.cs',
            'tests/HerdrOps.IntegrationTests/DelegationGraphStateTests.cs',
            'tests/HerdrOps.RuntimeTests/DelegationGraphRenderingTests.cs',
            'tools/Test-V04DelegationGraph.ps1')
    },
    [pscustomobject]@{
        Issue = 22
        Path = $reviewRecords[4]
        RequiredPaths = @(
            'docs/design/reference/11-widget-concepts.png',
            'docs/design/implementation/v0.4-issue-22-expanded-widget-runtime.md',
            'docs/protocol/v0.4-runtime-lifecycle-acceptance.md',
            'docs/protocol/examples/v0.4/assignment.json',
            'tools/Invoke-V04LifecycleRuntimeAcceptance.ps1',
            'tools/Test-V04ExpandedWidget.ps1',
            'tools/Test-V04ReleaseGate.ps1',
            'src/HerdrOps.App/Widgets/WidgetAssignmentProjection.cs',
            'src/HerdrOps.App/Widgets/LiveWidgetState.cs',
            'src/HerdrOps.Core/AssignmentLifecycleIngestionCoordinator.cs',
            'tests/HerdrOps.IntegrationTests/WidgetAssignmentProjectionTests.cs',
            'tests/HerdrOps.IntegrationTests/AssignmentLifecycleIngestionCoordinatorTests.cs',
            'tests/HerdrOps.IntegrationTests/UiLanguageCatalogTests.cs',
            'tests/HerdrOps.RuntimeTests/LiveWidgetRenderingTests.cs')
    })
foreach ($bindingRequest in $scopedReviewBindings) {
    $binding = & (Join-Path $repositoryRoot 'tools\lib\Assert-V04ReviewBinding.ps1') `
        -ReviewRecordPath $bindingRequest.Path `
        -RepositoryRoot $repositoryRoot `
        -CurrentHead $sourceCommit `
        -RequiredReviewedPaths $bindingRequest.RequiredPaths
    if ($binding.LocalIndependentReviewBinding -cne 'PASS') {
        throw "Issue #$($bindingRequest.Issue) independent review is not bound to the current source: $($binding.LocalIndependentReviewBinding)"
    }
}

foreach ($reviewRecord in $reviewRecords) {
    if (-not (Test-Path -LiteralPath $reviewRecord -PathType Leaf)) {
        throw "Independent v0.4 review record is missing: $reviewRecord"
    }
    $reviewText = Get-Content -LiteralPath $reviewRecord -Raw
    if ($reviewText -notmatch '(?m)^Verdict:\s*PASS\s*$') {
        throw "Independent v0.4 review is not PASS: $reviewRecord"
    }
}

if (-not $SkipBuild) {
    & (Join-Path $PSScriptRoot 'Invoke-Build.ps1') -Configuration $Configuration -VerifyFormat
    if ($LASTEXITCODE -ne 0) {
        throw 'The v0.4 release build and test suite failed.'
    }
}

# Run Stop-CoreProcessBounded behavioral selftests under both PowerShell engines.
# The shared lib (tools/lib/V04ProcessCleanup.ps1) and selftest
# (tools/Test-V04ProcessCleanupSelfTests.ps1) are load-bearing gate files in the
# v0.4 manifest. Both engines must pass; failure throws before any implementation
# gate runs.
$selfTestPath = Join-Path $PSScriptRoot 'Test-V04ProcessCleanupSelfTests.ps1'

# PS7 (pwsh) — required; pwsh must be on PATH in the CI environment.
$ps7Exe = (Get-Command pwsh -ErrorAction SilentlyContinue)
if ($null -eq $ps7Exe) {
    throw 'pwsh (PowerShell 7) is not on PATH; behavioral selftest cannot be enforced under PS7.'
}
& $ps7Exe.Source -NoProfile -File $selfTestPath | Out-Host
if ($LASTEXITCODE -ne 0) {
    throw 'Stop-CoreProcessBounded behavioral selftests FAILED under PowerShell 7.'
}

# PS5.1 (powershell.exe) — required on Windows; powershell.exe must be on PATH.
$ps5Exe = (Get-Command powershell.exe -ErrorAction SilentlyContinue)
if ($null -eq $ps5Exe) {
    throw 'powershell.exe (Windows PowerShell 5.1) is not on PATH; behavioral selftest cannot be enforced under PS5.1.'
}
& $ps5Exe.Source -NoProfile -File $selfTestPath | Out-Host
if ($LASTEXITCODE -ne 0) {
    throw 'Stop-CoreProcessBounded behavioral selftests FAILED under Windows PowerShell 5.1.'
}

$implementationGates = @(
    'Test-V04SelfReportCli.ps1',
    'Test-V04AssignmentLifecycle.ps1',
    'Test-V04DelegationGraph.ps1',
    'Test-V04TaskAlignment.ps1',
    'Test-V04ExpandedWidget.ps1')
foreach ($implementationGate in $implementationGates) {
    & (Join-Path $PSScriptRoot $implementationGate) `
        -Configuration $Configuration `
        -SkipBuild | Out-Host
    if ($LASTEXITCODE -ne 0) {
        throw "The v0.4 implementation gate failed: $implementationGate"
    }
}

$finalSourceCommit = (& git -C $repositoryRoot rev-parse HEAD).Trim()
$finalWorkingTreeStatus = @(& git -C $repositoryRoot status --porcelain=v1 --untracked-files=all)
if ($LASTEXITCODE -ne 0 -or
    $finalSourceCommit -ne $sourceCommit -or
    $finalWorkingTreeStatus.Count -ne 0) {
    throw 'The source commit or clean-checkout state changed while the v0.4 release gate ran.'
}

$runId = "$([DateTime]::UtcNow.ToString('yyyyMMddTHHmmssfffffffZ', [Globalization.CultureInfo]::InvariantCulture))-$([Guid]::NewGuid().ToString('N').Substring(0, 8))"
$gateDirectory = Join-Path $artifactRoot "release-gates\v0.4.0\release\$runId"
New-Item -ItemType Directory -Path $gateDirectory -Force | Out-Null
$runtimeGateSha256 = (Get-FileHash -LiteralPath $resolvedRuntimeGatePath -Algorithm SHA256).Hash
$reviewHashes = $reviewRecords | ForEach-Object {
    "SHA256 $((Get-FileHash -LiteralPath $_ -Algorithm SHA256).Hash) $([IO.Path]::GetFileName($_))"
}
$gateReportPath = Join-Path $gateDirectory 'gate-report.txt'
$gateReport = @(
    'HerdrOps v0.4.0 Release Gate',
    "GeneratedUtc: $([DateTime]::UtcNow.ToString('O'))",
    "SourceCommit: $sourceCommit",
    'Result: PASS',
    'ReleaseReady: true',
    'ProcessCleanupSelfTests: PS7+PS5.1 PASS',
    'ImplementationGates: 5/5 PASS',
    'IndependentReviews: 5/5 PASS',
    'RoleDistinctRuntimeAcceptance: PASS',
    'SessionControlInvoked: false',
    "CompositeRuntimeReportSha256: $compositeSha256",
    "RuntimeGateReportSha256: $runtimeGateSha256",
    '',
    'IndependentReviewHashes:'
) + $reviewHashes + @(
    '',
    'EvidenceBoundary:',
    'This gate requires all five v0.4 implementation gates, five explicit independent PASS records, and one exact-source role-distinct composite Herdr runtime report.',
    'A passing local report is release-gate evidence for the bound source commit. GitHub issue closure, tag creation, package publication, and release publication remain separate actions.'
)
$gateReport | Set-Content -LiteralPath $gateReportPath -Encoding utf8
$gateReport | Write-Output
Write-Output "GateReport: $gateReportPath"
