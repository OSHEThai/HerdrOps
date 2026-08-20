Set-StrictMode -Version Latest

function Get-V03ImplementationChildGateDefinitions {
    @(
        [pscustomobject]@{
            Issue = '12'
            Name = 'ActivityPipeline'
            ScriptName = 'Test-V03ActivityPipeline.ps1'
            ImplementationOnly = $false
        }
        [pscustomobject]@{
            Issue = '13'
            Name = 'RealtimeActivity'
            ScriptName = 'Test-V03RealtimeActivity.ps1'
            ImplementationOnly = $false
        }
        [pscustomobject]@{
            Issue = '14'
            Name = 'TerminalProcess'
            ScriptName = 'Test-V03TerminalProcess.ps1'
            ImplementationOnly = $false
        }
        [pscustomobject]@{
            Issue = '15'
            Name = 'FileGitActivity'
            ScriptName = 'Test-V03FileGitActivity.ps1'
            ImplementationOnly = $true
        }
        [pscustomobject]@{
            Issue = '16'
            Name = 'NotificationDelivery'
            ScriptName = 'Test-V03NotificationRuntime.ps1'
            ImplementationOnly = $false
        }
    )
}

function Resolve-V03ImplementationReportPath {
    param(
        [Parameter(Mandatory)]
        [object[]]$Output,

        [Parameter(Mandatory)]
        [string]$ArtifactRoot
    )

    $reportLines = @($Output | ForEach-Object { [string]$_ } | Where-Object {
            $_ -match '^GateReport:\s*(?<path>.+?)\s*$'
        })
    if ($reportLines.Count -ne 1) {
        throw "Expected exactly one child gate report path; found $($reportLines.Count)."
    }

    $null = $reportLines[0] -match '^GateReport:\s*(?<path>.+?)\s*$'
    $candidate = $Matches.path.Trim()
    if (-not (Test-Path -LiteralPath $candidate -PathType Leaf)) {
        throw "Child gate report is missing: $candidate"
    }

    $resolvedPath = (Resolve-Path -LiteralPath $candidate).Path
    $root = [IO.Path]::GetFullPath($ArtifactRoot).TrimEnd([char[]]@([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar))
    $prefix = $root + [IO.Path]::DirectorySeparatorChar
    if (-not $resolvedPath.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Child gate report escaped the artifact root: $resolvedPath"
    }

    return $resolvedPath
}

function Assert-V03ImplementationChildReport {
    param(
        [Parameter(Mandatory)]
        [string]$Name,

        [Parameter(Mandatory)]
        [string]$ReportText,

        [Parameter(Mandatory)]
        [string]$SourceCommit
    )

    $sourceMatches = [Regex]::Matches($ReportText, '(?m)^SourceCommit:\s*(?<commit>[^\r\n]+)\s*$')
    if ($sourceMatches.Count -ne 1 -or
        $sourceMatches[0].Groups['commit'].Value.Trim() -cne $SourceCommit) {
        throw "Child gate $Name report is not bound to source commit $SourceCommit."
    }

    $resultMatches = [Regex]::Matches($ReportText, '(?m)^Result:\s*(?<result>[^\r\n]+)\s*$')
    if ($resultMatches.Count -ne 1 -or
        $resultMatches[0].Groups['result'].Value.Trim() -notin @('PASS', 'IMPLEMENTATION READY / PARTIAL')) {
        throw "Child gate $Name did not report a passing implementation result."
    }

    foreach ($forbiddenPattern in @(
            '(?im)^EvidenceClass:\s*Runtime\s*$',
            '(?im)^ActualHerdr[^:]*:\s*OBSERVED\s*$',
            '(?im)^RuntimeAccepted:\s*true\s*$',
            '(?im)^ReleaseReady:\s*true\s*$',
            '(?im)^VersionReleaseReady:\s*true\s*$')) {
        if ($ReportText -match $forbiddenPattern) {
            throw "Child gate $Name report contains an out-of-scope acceptance claim."
        }
    }
}

function New-V03ImplementationGateReport {
    param(
        [Parameter(Mandatory)]
        [string]$SourceCommit,

        [Parameter(Mandatory)]
        [object[]]$ChildResults,

        [Parameter(Mandatory)]
        [ValidateSet('PASS', 'FAIL')]
        [string]$Result,

        [string]$FailureCode,

        [Parameter(Mandatory)]
        [DateTime]$GeneratedUtc
    )

    $passed = @($ChildResults | Where-Object Status -eq 'PASS').Count
    $total = @($ChildResults).Count
    $lines = @(
        'HerdrOps v0.3.0 Issue #17 Implementation Gate',
        "GeneratedUtc: $($GeneratedUtc.ToUniversalTime().ToString('O'))",
        "SourceCommit: $SourceCommit",
        "Result: $Result",
        'GateKind: Implementation',
        'EvidenceClasses: Static, Contract, Synthetic',
        "ChildGates: $passed/$total PASS",
        'InstalledHerdrCommand: NOT INVOKED',
        'PackageOrMilestoneDecision: NOT PERFORMED',
        'IssueClosure: NOT PERFORMED'
    )

    if (-not [string]::IsNullOrWhiteSpace($FailureCode)) {
        $lines += "FailureCode: $FailureCode"
    }

    $lines += ''
    $lines += 'ChildGateResults:'
    foreach ($child in $ChildResults) {
        $suffix = if ([string]::IsNullOrWhiteSpace($child.ReportSha256)) {
            ''
        }
        else {
            " sha256=$($child.ReportSha256)"
        }
        $lines += "$($child.Status) Issue#$($child.Issue) $($child.Name)$suffix"
    }

    $lines += ''
    $lines += 'EvidenceBoundary:'
    $lines += 'This report is an implementation-only aggregation of the v0.3 Static, Contract, and Synthetic child checks for Issues #12 through #16.'
    $lines += 'It does not inspect an installed Herdr instance, admit live process/file observations, decide issue acceptance, close a milestone, or publish a package.'
    $lines += 'A PASS here is implementation preparation evidence only.'
    return $lines
}

Export-ModuleMember -Function @(
    'Get-V03ImplementationChildGateDefinitions',
    'Resolve-V03ImplementationReportPath',
    'Assert-V03ImplementationChildReport',
    'New-V03ImplementationGateReport'
)
