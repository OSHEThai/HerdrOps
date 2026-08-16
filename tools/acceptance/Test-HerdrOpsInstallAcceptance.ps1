#requires -Version 5.1

[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'HerdrOps.InstallAcceptance.Common.ps1')

$harnessPath = Join-Path $PSScriptRoot 'Invoke-HerdrOpsInstallAcceptance.ps1'
$implementationPaths = @(
    (Join-Path $PSScriptRoot 'HerdrOps.InstallAcceptance.Common.ps1'),
    $harnessPath)
$reportSchemaPath = Join-Path $PSScriptRoot '..\..\docs\acceptance\issue-44-install-acceptance-report.schema.json'

function Assert-TestCondition {
    param(
        [Parameter(Mandatory = $true)][bool]$Condition,
        [Parameter(Mandatory = $true)][string]$Message
    )

    if (-not $Condition) {
        throw $Message
    }
}

function Assert-TestExactProperties {
    param(
        [Parameter(Mandatory = $true)]$Object,
        [Parameter(Mandatory = $true)][string[]]$Names,
        [Parameter(Mandatory = $true)][string]$Context
    )

    Assert-AcceptanceExactProperties -Object $Object -Names $Names -Context $Context
}

function Assert-TestReportShape {
    param(
        [Parameter(Mandatory = $true)]$Report,
        [Parameter(Mandatory = $true)][ValidateSet('Static', 'Synthetic')][string]$EvidenceClass,
        [Parameter(Mandatory = $true)][ValidateSet('DryRun', 'Fixture')][string]$Mode
    )

    Assert-TestExactProperties -Object $Report -Names @(
        'schemaVersion', 'reportKind', 'issue', 'acceptanceVersion', 'status',
        'mode', 'evidenceClass', 'startedAtUtc', 'completedAtUtc', 'runId',
        'machine', 'artifacts', 'targets', 'preflight', 'lifecycle', 'cleanup',
        'failureDetails', 'transcript', 'boundaries') -Context 'acceptance report'
    Assert-TestCondition -Condition ([int]$Report.schemaVersion -eq 1) -Message 'Report schemaVersion drifted.'
    Assert-TestCondition -Condition ([string]$Report.reportKind -ceq 'HerdrOps.InstallAcceptanceReport') -Message 'Report kind drifted.'
    Assert-TestCondition -Condition ([int]$Report.issue -eq 44) -Message 'Report issue binding drifted.'
    Assert-TestCondition -Condition ([string]$Report.acceptanceVersion -ceq 'v1.0.0') -Message 'Report acceptance target drifted.'
    Assert-TestCondition -Condition ([string]$Report.status -ceq 'PASS') -Message "Expected PASS report, got $($Report.status)."
    Assert-TestCondition -Condition ([string]$Report.mode -ceq $Mode) -Message 'Report mode drifted.'
    Assert-TestCondition -Condition ([string]$Report.evidenceClass -ceq $EvidenceClass) -Message 'Report evidence class drifted.'

    Assert-TestExactProperties -Object $Report.preflight -Names @('status', 'checks') -Context 'report preflight'
    Assert-TestCondition -Condition ([string]$Report.preflight.status -ceq 'PASS') -Message 'Preflight did not pass.'
    Assert-TestCondition -Condition (@($Report.preflight.checks).Count -ge 5) -Message 'Preflight report is missing focused checks.'

    Assert-TestExactProperties -Object $Report.lifecycle -Names @('cleanInstall', 'upgrade', 'rollback', 'uninstall') -Context 'report lifecycle'
    foreach ($stepName in @('cleanInstall', 'upgrade', 'rollback', 'uninstall')) {
        Assert-TestExactProperties -Object $Report.lifecycle.$stepName -Names @(
            'status', 'expectedVersion', 'installedFileHashes', 'installRootPresent',
            'packageVersionObserved', 'retainedDataStatus', 'retainedDataSha256',
            'details') -Context "report lifecycle $stepName"
    }

    Assert-TestExactProperties -Object $Report.cleanup -Names @(
        'status', 'attempted', 'simulationRoot', 'simulationRootRemoved',
        'ownedStageRemoved', 'ownedBackupRemoved', 'harnessSeededDataMarkerRemoved',
        'retainedDataLeftIntact', 'residuals', 'details') -Context 'report cleanup'
    Assert-TestCondition -Condition ([string]$Report.cleanup.status -ceq 'PASS') -Message 'Synthetic cleanup did not pass.'
    Assert-TestCondition -Condition ([bool]$Report.cleanup.simulationRootRemoved) -Message 'Synthetic simulation root was not removed.'
    Assert-TestCondition -Condition (@($Report.cleanup.residuals).Count -eq 0) -Message 'Synthetic run left residuals.'
    Assert-TestCondition -Condition (-not (Test-Path -LiteralPath ([string]$Report.cleanup.simulationRoot))) -Message 'Synthetic simulation root still exists.'

    Assert-TestExactProperties -Object $Report.boundaries -Names @(
        'static', 'synthetic', 'contract', 'cleanMachine', 'runtime',
        'independentReview', 'release') -Context 'report boundaries'
    Assert-TestCondition -Condition ([string]$Report.boundaries.contract -like 'NOT OBSERVED*') -Message 'Contract boundary was not withheld.'
    Assert-TestCondition -Condition ([string]$Report.boundaries.cleanMachine -like 'NOT OBSERVED*') -Message 'Clean-machine boundary was not withheld.'
    Assert-TestCondition -Condition ([string]$Report.boundaries.runtime -like 'NOT OBSERVED*') -Message 'Runtime boundary was not withheld.'
}

foreach ($implementationPath in $implementationPaths) {
    $text = Get-Content -LiteralPath $implementationPath -Raw
    foreach ($forbiddenMarker in @(
            'New-ItemProperty', 'Set-ItemProperty', 'Remove-ItemProperty',
            'Registry::', 'reg.exe', 'Start-Process', 'sc.exe',
            'HERDR_SOCKET_PATH', 'herdr.exe', 'Invoke-WebRequest',
            'Invoke-RestMethod', 'dotnet')) {
        Assert-TestCondition `
            -Condition ($text.IndexOf($forbiddenMarker, [StringComparison]::OrdinalIgnoreCase) -lt 0) `
            -Message "Issue #44 acceptance implementation contains a forbidden runtime/publish marker: $forbiddenMarker"
    }
}

$reportSchema = Get-Content -LiteralPath $reportSchemaPath -Raw | ConvertFrom-Json
Assert-TestCondition -Condition ([string]$reportSchema.'$schema' -like '*draft-07*') -Message 'Report JSON schema is not draft-07.'
Assert-TestCondition -Condition ($null -ne $reportSchema.definitions) -Message 'Report JSON schema definitions are missing.'
Assert-TestCondition -Condition ([string]$reportSchema.title -like '*Issue 44*') -Message 'Report JSON schema title drifted.'
Assert-TestCondition -Condition (@($reportSchema.required).Count -eq 19) -Message 'Report JSON schema top-level required set drifted.'

$testRoot = New-PackagingTempDirectory -Prefix 'HerdrOps-I44-Test-'
try {
    $broadRootRejected = $false
    try {
        Assert-AcceptanceNotBroadPath -Path ([IO.Path]::GetPathRoot((Get-Location).Path)) -Context 'focused broad-root guard' | Out-Null
    } catch {
        $broadRootRejected = ($_.Exception.Message -like '*broad filesystem root*')
    }
    Assert-TestCondition -Condition $broadRootRejected -Message 'Broad filesystem root was not rejected.'

    $fixtureOutput = @(& $harnessPath -Mode Fixture)
    Assert-TestCondition -Condition ($fixtureOutput.Count -eq 1) -Message 'Fixture harness did not return exactly one report.'
    $fixtureReport = $fixtureOutput[0]
    Assert-TestReportShape -Report $fixtureReport -EvidenceClass 'Synthetic' -Mode 'Fixture'
    foreach ($stepName in @('cleanInstall', 'upgrade', 'rollback', 'uninstall')) {
        Assert-TestCondition -Condition ([string]$fixtureReport.lifecycle.$stepName.status -ceq 'PASS') -Message "Fixture lifecycle step did not pass: $stepName"
    }
    Assert-TestCondition -Condition (@($fixtureReport.lifecycle.cleanInstall.installedFileHashes).Count -gt 0) -Message 'Clean-install hashes were not recorded.'
    Assert-TestCondition -Condition (@($fixtureReport.lifecycle.upgrade.installedFileHashes).Count -gt 0) -Message 'Upgrade hashes were not recorded.'
    Assert-TestCondition -Condition ([string]$fixtureReport.lifecycle.uninstall.retainedDataStatus -ceq 'PASS') -Message 'Retained-data assertion did not pass.'
    Assert-TestCondition -Condition ([string]$fixtureReport.targets.installPathPolicy -ceq '%LOCALAPPDATA%\Programs\HerdrOps') -Message 'Install path policy drifted.'
    Assert-TestCondition -Condition ([string]$fixtureReport.targets.userDataPathPolicy -ceq '%LOCALAPPDATA%\HerdrOps') -Message 'User-data path policy drifted.'
    Assert-TestCondition -Condition ([string]$fixtureReport.boundaries.synthetic -like 'PASS*') -Message 'Fixture synthetic boundary did not pass.'

    $dryRunOutput = @(& $harnessPath -Mode DryRun)
    Assert-TestCondition -Condition ($dryRunOutput.Count -eq 1) -Message 'Dry-run harness did not return exactly one report.'
    $dryRunReport = $dryRunOutput[0]
    Assert-TestReportShape -Report $dryRunReport -EvidenceClass 'Static' -Mode 'DryRun'
    foreach ($stepName in @('cleanInstall', 'upgrade', 'rollback', 'uninstall')) {
        Assert-TestCondition -Condition ([string]$dryRunReport.lifecycle.$stepName.status -ceq 'NOT_RUN') -Message "Dry-run unexpectedly executed lifecycle step: $stepName"
    }
    Assert-TestCondition -Condition (@($dryRunReport.transcript | Where-Object { $_.effect -ceq 'LiveFilesystem' }).Count -eq 0) -Message 'Dry-run transcript contains a live filesystem effect.'

    $cancellationReportPath = Join-Path $testRoot 'cancellation-report.json'
    $cancellationCaught = $false
    try {
        & $harnessPath -Mode Fixture -TestCancelPoint AfterUpgradeBackup -ReportPath $cancellationReportPath | Out-Null
    } catch {
        $cancellationCaught = $true
        Assert-TestCondition -Condition ($_.Exception.Message -like '*CANCELLED*') -Message 'Cancellation did not fail closed with CANCELLED status.'
    }
    Assert-TestCondition -Condition $cancellationCaught -Message 'Injected cancellation unexpectedly completed.'
    Assert-TestCondition -Condition (Test-Path -LiteralPath $cancellationReportPath -PathType Leaf) -Message 'Cancellation report was not written.'
    $cancellationReport = Get-Content -LiteralPath $cancellationReportPath -Raw | ConvertFrom-Json
    Assert-TestExactProperties -Object $cancellationReport -Names @(
        'schemaVersion', 'reportKind', 'issue', 'acceptanceVersion', 'status',
        'mode', 'evidenceClass', 'startedAtUtc', 'completedAtUtc', 'runId',
        'machine', 'artifacts', 'targets', 'preflight', 'lifecycle', 'cleanup',
        'failureDetails', 'transcript', 'boundaries') -Context 'cancellation report'
    Assert-TestCondition -Condition ([string]$cancellationReport.status -ceq 'CANCELLED') -Message 'Cancellation report status drifted.'
    Assert-TestCondition -Condition ([string]$cancellationReport.cleanup.status -ceq 'PASS') -Message 'Cancellation cleanup did not pass.'
    Assert-TestCondition -Condition ([bool]$cancellationReport.cleanup.simulationRootRemoved) -Message 'Cancellation simulation root was not removed.'
    Assert-TestCondition -Condition (@($cancellationReport.cleanup.residuals).Count -eq 0) -Message 'Cancellation left residuals.'

    $liveText = Get-Content -LiteralPath $harnessPath -Raw
    foreach ($requiredLiveMarker in @(
            "[ValidateSet('DryRun', 'Fixture', 'Live')]",
            'IUnderstandLiveMutation',
            'HERDROPS-ISSUE-44-LIVE-FILESYSTEM',
            'ExpectedMachineFingerprint',
            'ExpectedInitialArtifactSha256',
            'ExpectedUpgradeArtifactSha256',
            'Test-AcceptanceIsElevated',
            'canonical per-user HerdrOps paths',
            'Assert-AcceptanceNotBroadPath',
            'Assert-AcceptanceNoReparsePath',
            'Assert-AcceptanceTreeNoReparse',
            'Remove-AcceptanceOwnedSiblingDirectory')) {
        Assert-TestCondition -Condition ($liveText.IndexOf($requiredLiveMarker, [StringComparison]::Ordinal) -ge 0) -Message "Live fail-closed marker is missing: $requiredLiveMarker"
    }

    [pscustomobject][ordered]@{
        EvidenceClass = 'Static/Synthetic'
        Issue = 44
        ImplementationSafetyMarkers = 'PASS'
        ExactReportShape = 'PASS'
        FixtureLifecycle = 'PASS'
        DryRunNoLifecycleEffects = 'PASS'
        CancellationCleanup = 'PASS'
        LiveModeNotExecuted = 'PASS'
        CleanMachine = 'NOT OBSERVED'
        Runtime = 'NOT OBSERVED'
        Release = 'NOT OBSERVED'
    }
} finally {
    if (Test-Path -LiteralPath $testRoot) {
        Remove-PackagingTempDirectory -Path $testRoot
    }
}
