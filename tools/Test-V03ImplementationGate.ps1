[CmdletBinding()]
param(
    [ValidateSet('Debug', 'Release')]
    [string]$Configuration = 'Release',

    [switch]$SkipBuild,

    # Test seam for deterministic child-failure tests. Production callers use
    # the committed child gates in this tools directory.
    [string]$ChildGateRoot
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false

function Get-V03Sha256 {
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return ''
    }

    try {
        return ((Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash).ToUpperInvariant()
    }
    catch {
        return ''
    }
}

function New-V03EmptyDiagnosticFile {
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )

    $parent = Split-Path -Parent $Path
    New-Item -ItemType Directory -Path $parent -Force | Out-Null
    [IO.File]::WriteAllText($Path, [string]::Empty, [Text.UTF8Encoding]::new($false))
}

function Add-V03DiagnosticException {
    param(
        [Parameter(Mandatory)]
        [string]$Path,

        [Parameter(Mandatory)]
        [object]$ErrorRecord
    )

    try {
        if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
            New-V03EmptyDiagnosticFile -Path $Path
        }

        $message = if ($null -ne $ErrorRecord.Exception) {
            $ErrorRecord.Exception.ToString()
        }
        else {
            [string]$ErrorRecord
        }
        Add-Content -LiteralPath $Path -Value $message -Encoding utf8
    }
    catch {
        # The stable parent FailureCode remains authoritative if a secondary
        # diagnostic write cannot be completed.
    }
}

$repositoryRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$artifactRoot = Join-Path $repositoryRoot 'artifacts'
$implementationArtifactRoot = Join-Path $artifactRoot 'release-gates\v0.3.0\issue-17'
$sourceCommit = 'UNRESOLVED'
$initialStatus = @()
$finalStatus = @()
$childDefinitions = @()
$childResults = @()
$result = 'FAIL'
$failureCode = 'ImplementationGateFailed'
$report = @()
$reportPath = Join-Path $implementationArtifactRoot 'unwritten-gate-report.txt'
$reportWriteSucceeded = $false
$runDirectory = ''
$diagnosticDirectory = ''

$runId = "$([DateTime]::UtcNow.ToString('yyyyMMddTHHmmssfffffffZ', [Globalization.CultureInfo]::InvariantCulture))-$([Guid]::NewGuid().ToString('N').Substring(0, 8))"
$runDirectory = Join-Path $implementationArtifactRoot $runId
$diagnosticDirectory = Join-Path $runDirectory 'child-gates'
$reportPath = Join-Path $runDirectory 'gate-report.txt'

try {
    Import-Module (Join-Path $PSScriptRoot 'V03ImplementationGate.psm1') -Force
    $childDefinitions = @(Get-V03ImplementationChildGateDefinitions)

    New-Item -ItemType Directory -Path $diagnosticDirectory -Force | Out-Null
    foreach ($definition in $childDefinitions) {
        $stdoutPath = Join-Path $diagnosticDirectory "issue-$($definition.Issue).stdout.txt"
        $stderrPath = Join-Path $diagnosticDirectory "issue-$($definition.Issue).stderr.txt"
        New-V03EmptyDiagnosticFile -Path $stdoutPath
        New-V03EmptyDiagnosticFile -Path $stderrPath
        $childResults += [pscustomobject]@{
            Issue = $definition.Issue
            Name = $definition.Name
            Status = 'NOT_RUN'
            Attempted = $false
            ReportArtifact = ''
            ReportSha256 = ''
            StdoutArtifact = "child-gates/issue-$($definition.Issue).stdout.txt"
            StdoutSha256 = ''
            StderrArtifact = "child-gates/issue-$($definition.Issue).stderr.txt"
            StderrSha256 = ''
            FailureCode = ''
            StdoutPath = $stdoutPath
            StderrPath = $stderrPath
        }
    }

    $sourceCommitOutput = @(& git -C $repositoryRoot rev-parse --verify 'HEAD^{commit}')
    $sourceCommit = ($sourceCommitOutput -join '').Trim()
    if ($LASTEXITCODE -ne 0 -or $sourceCommit -notmatch '^[0-9a-f]{40}$') {
        $sourceCommit = 'UNRESOLVED'
        $failureCode = 'SourceCommitResolutionFailed'
        throw [InvalidOperationException]::new($failureCode)
    }

    $initialStatus = @(& git -C $repositoryRoot status --porcelain=v1 --untracked-files=all)
    if ($LASTEXITCODE -ne 0) {
        $failureCode = 'WorkingTreeInspectionFailed'
        throw [InvalidOperationException]::new($failureCode)
    }

    if ([string]::IsNullOrWhiteSpace($ChildGateRoot)) {
        $ChildGateRoot = $PSScriptRoot
    }

    try {
        $resolvedChildGateRoot = (Resolve-Path -LiteralPath $ChildGateRoot -ErrorAction Stop).Path
    }
    catch {
        $failureCode = 'ChildRootResolutionFailed'
        throw [InvalidOperationException]::new($failureCode)
    }

    $normalizedToolsRoot = [IO.Path]::GetFullPath($PSScriptRoot).TrimEnd([char[]]@([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar))
    $normalizedFixtureRoot = [IO.Path]::GetFullPath((Join-Path $artifactRoot 'implementation-gate-test-fixtures')).TrimEnd([char[]]@([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar))
    $childRootIsAllowed = $resolvedChildGateRoot.Equals($normalizedToolsRoot, [StringComparison]::OrdinalIgnoreCase) -or
        $resolvedChildGateRoot.StartsWith($normalizedFixtureRoot + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)
    if (-not $childRootIsAllowed) {
        $failureCode = 'ChildRootNotAllowed'
        throw [InvalidOperationException]::new($failureCode)
    }

    if ($env:HERDR_ENV -eq '1' -or -not [string]::IsNullOrWhiteSpace($env:HERDR_SOCKET_PATH)) {
        $failureCode = 'AuthorizedHerdrEnvironment'
        throw [InvalidOperationException]::new($failureCode)
    }

    if ($initialStatus.Count -ne 0) {
        $failureCode = 'WorkingTreeDirty'
        throw [InvalidOperationException]::new($failureCode)
    }

    if (-not $SkipBuild) {
        try {
            # The parent gate performs only the deterministic build/format
            # preflight. Its child gates own their scoped Contract/Synthetic
            # checks; invoking the full solution suite here reintroduces the
            # unrelated shared WPF Application shutdown contamination.
            & (Join-Path $PSScriptRoot 'Invoke-Build.ps1') `
                -Configuration $Configuration `
                -SkipTests `
                -VerifyFormat | Out-Host
            if ($LASTEXITCODE -ne 0) {
                throw [InvalidOperationException]::new('BuildFailed')
            }
        }
        catch {
            $failureCode = 'BuildFailed'
            throw [InvalidOperationException]::new($failureCode)
        }
    }

    try {
        $pwshPath = (Get-Command pwsh -ErrorAction Stop).Source
        if ([string]::IsNullOrWhiteSpace($pwshPath)) {
            throw [InvalidOperationException]::new('PwshUnavailable')
        }
    }
    catch {
        $failureCode = 'PwshUnavailable'
        throw [InvalidOperationException]::new($failureCode)
    }

    foreach ($child in $childResults) {
        $definition = $childDefinitions | Where-Object { $_.Issue -eq $child.Issue } | Select-Object -First 1
        $scriptPath = Join-Path $resolvedChildGateRoot $definition.ScriptName
        $stdoutPath = [string]$child.StdoutPath
        $stderrPath = [string]$child.StderrPath

        if (-not (Test-Path -LiteralPath $scriptPath -PathType Leaf)) {
            $child.Status = 'FAIL'
            $child.FailureCode = "ChildGateMissing:$($child.Issue)"
            Set-Content -LiteralPath $stderrPath -Value $child.FailureCode -Encoding utf8
            $child.StdoutSha256 = Get-V03Sha256 -Path $stdoutPath
            $child.StderrSha256 = Get-V03Sha256 -Path $stderrPath
            continue
        }

        $child.Attempted = $true
        $childArguments = @(
            '-NoProfile',
            '-File',
            $scriptPath,
            '-Configuration',
            $Configuration,
            '-SkipBuild'
        )
        if ($definition.ImplementationOnly) {
            $childArguments += '-ImplementationOnly'
        }

        $childSucceeded = $false
        try {
            & $pwshPath @childArguments 1> $stdoutPath 2> $stderrPath
            $childSucceeded = ($LASTEXITCODE -eq 0)
        }
        catch {
            $childSucceeded = $false
            Add-V03DiagnosticException -Path $stderrPath -ErrorRecord $_
        }

        if (-not $childSucceeded) {
            $child.Status = 'FAIL'
            $child.FailureCode = "ChildGateFailed:$($child.Issue)"
            if ((Get-Item -LiteralPath $stderrPath).Length -eq 0) {
                Set-Content -LiteralPath $stderrPath -Value $child.FailureCode -Encoding utf8
            }
            $child.StdoutSha256 = Get-V03Sha256 -Path $stdoutPath
            $child.StderrSha256 = Get-V03Sha256 -Path $stderrPath
            continue
        }

        try {
            $childOutput = @(Get-Content -LiteralPath $stdoutPath -ErrorAction Stop)
            $reportCandidate = Resolve-V03ImplementationReportPath `
                -Output $childOutput `
                -ArtifactRoot $artifactRoot
            $reportText = Get-Content -LiteralPath $reportCandidate -Raw -ErrorAction Stop
            $childResultValue = Assert-V03ImplementationChildReport `
                -Name $definition.Name `
                -ReportText $reportText `
                -SourceCommit $sourceCommit

            $reportArtifactPath = Join-Path $diagnosticDirectory "issue-$($child.Issue).gate-report.txt"
            Copy-Item -LiteralPath $reportCandidate -Destination $reportArtifactPath -Force
            if (-not (Test-Path -LiteralPath $reportArtifactPath -PathType Leaf)) {
                throw [InvalidOperationException]::new('ChildReportCopyFailed')
            }

            $child.ReportArtifact = "child-gates/issue-$($child.Issue).gate-report.txt"
            $child.ReportSha256 = Get-V03Sha256 -Path $reportArtifactPath
            if ($childResultValue -eq 'PASS') {
                $child.Status = 'PASS'
            }
            else {
                $child.Status = 'PARTIAL'
            }
        }
        catch {
            $child.Status = 'FAIL'
            $child.FailureCode = "ChildReportInvalid:$($child.Issue)"
            Add-V03DiagnosticException -Path $stderrPath -ErrorRecord $_
        }

        $child.StdoutSha256 = Get-V03Sha256 -Path $stdoutPath
        $child.StderrSha256 = Get-V03Sha256 -Path $stderrPath
    }

    $incompleteChildren = @($childResults | Where-Object { $_.Status -notin @('PASS', 'PARTIAL') })
    if ($childResults.Count -ne $childDefinitions.Count -or $incompleteChildren.Count -ne 0) {
        $result = 'FAIL'
        $firstIncomplete = $incompleteChildren | Select-Object -First 1
        $failureCode = if ($null -ne $firstIncomplete -and -not [string]::IsNullOrWhiteSpace($firstIncomplete.FailureCode)) {
            [string]$firstIncomplete.FailureCode
        }
        else {
            'ChildGateIncomplete'
        }
    }
    else {
        # PARTIAL is an admitted child implementation status, not a PASS
        # child status. The aggregate itself remains an Implementation gate
        # and never upgrades this to Runtime or Release acceptance.
        $result = 'PASS'
        $failureCode = ''
    }
}
catch {
    $result = 'FAIL'
}
finally {
    if ($sourceCommit -match '^[0-9a-f]{40}$' -and $initialStatus.Count -eq 0) {
        try {
            $finalCommitOutput = @(& git -C $repositoryRoot rev-parse --verify 'HEAD^{commit}')
            $finalCommit = ($finalCommitOutput -join '').Trim()
            $finalStatus = @(& git -C $repositoryRoot status --porcelain=v1 --untracked-files=all)
            if ($LASTEXITCODE -ne 0) {
                $result = 'FAIL'
                $failureCode = 'SourceIntegrityCheckFailed'
            }
            elseif ($finalCommit -ne $sourceCommit -or $finalStatus.Count -ne 0) {
                $result = 'FAIL'
                $failureCode = 'SourceChangedDuringGate'
            }
        }
        catch {
            $result = 'FAIL'
            $failureCode = 'SourceIntegrityCheckFailed'
        }
    }

    try {
        New-Item -ItemType Directory -Path $runDirectory -Force | Out-Null
        $report = @(New-V03ImplementationGateReport `
            -SourceCommit $sourceCommit `
            -ChildResults $childResults `
            -Result $result `
            -FailureCode $failureCode `
            -GeneratedUtc ([DateTime]::UtcNow) `
            -ExpectedChildGateCount $childDefinitions.Count)
        $report | Set-Content -LiteralPath $reportPath -Encoding utf8
        $reportWriteSucceeded = Test-Path -LiteralPath $reportPath -PathType Leaf
    }
    catch {
        $result = 'FAIL'
        $failureCode = 'ReportWriteFailed'
        $report = @(
            'HerdrOps v0.3.0 Issue #17 Implementation Gate',
            "SourceCommit: $sourceCommit",
            'Result: FAIL',
            'GateKind: Implementation',
            'EvidenceClasses: Static, Contract, Synthetic',
            "FailureCode: $failureCode",
            'InstalledHerdrCommand: NOT INVOKED',
            'PackageOrMilestoneDecision: NOT PERFORMED',
            'IssueClosure: NOT PERFORMED',
            '',
            'EvidenceBoundary:',
            'This report is an implementation-only aggregation of the v0.3 Static, Contract, and Synthetic child checks for Issues #12 through #16.',
            'Contract-backed WPF rendering and other Contract/Synthetic observations remain admitted only within each child report boundary.',
            'This aggregate provides no installed-Herdr evidence, no live File/Git evidence, and no release evidence.',
            'It does not decide issue acceptance, close a milestone, or publish a package.',
            'A PASS here is implementation preparation evidence only.'
        )
        try {
            New-Item -ItemType Directory -Path $runDirectory -Force | Out-Null
            $report | Set-Content -LiteralPath $reportPath -Encoding utf8
            $reportWriteSucceeded = Test-Path -LiteralPath $reportPath -PathType Leaf
        }
        catch {
            $reportWriteSucceeded = $false
        }
    }
}

if ($reportWriteSucceeded) {
    $report | ForEach-Object { Write-Output $_ }
    Write-Output "ImplementationGateReport: $reportPath"
}
else {
    Write-Error 'The v0.3 implementation gate failed: ReportWriteFailed' -ErrorAction Continue
    exit 1
}

if ($result -ne 'PASS') {
    Write-Error "The v0.3 implementation gate failed: $failureCode" -ErrorAction Continue
    exit 1
}
