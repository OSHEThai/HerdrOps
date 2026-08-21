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
            ContractSelfTestScriptName = 'Test-V03Issue14RuntimeAcceptance.Tests.ps1'
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
        [ValidatePattern('^[0-9a-f]{40}$')]
        [string]$ExpectedSourceCommit,

        [Parameter(Mandatory)]
        [ValidatePattern('^[0-9a-f]{40}$')]
        [string]$ExpectedSourceTree
    )

    $sourceMatches = [Regex]::Matches($ReportText, '(?m)^SourceCommit:\s*(?<commit>[^\r\n]+)\s*$')
    if ($sourceMatches.Count -ne 1 -or
        $sourceMatches[0].Groups['commit'].Value.Trim() -cne $ExpectedSourceCommit) {
        throw "Child gate $Name report is not bound to source commit $ExpectedSourceCommit."
    }

    $treeMatches = [Regex]::Matches($ReportText, '(?m)^SourceTree:\s*(?<tree>[^\r\n]+)\s*$')
    if ($treeMatches.Count -ne 1 -or
        $treeMatches[0].Groups['tree'].Value.Trim() -cne $ExpectedSourceTree) {
        throw "Child gate $Name report is not bound to source tree $ExpectedSourceTree."
    }

    $resultMatches = [Regex]::Matches($ReportText, '(?m)^Result:\s*(?<result>[^\r\n]+)\s*$')
    if ($resultMatches.Count -ne 1 -or
        $resultMatches[0].Groups['result'].Value.Trim() -notin @('PASS', 'IMPLEMENTATION READY / PARTIAL')) {
        throw "Child gate $Name did not report a passing implementation result."
    }

    $resultValue = $resultMatches[0].Groups['result'].Value.Trim()

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

    return $resultValue
}

function Get-V03ChildResultValue {
    param(
        [Parameter(Mandatory)]
        [object]$Child,

        [Parameter(Mandatory)]
        [string]$Name
    )

    $property = $Child.PSObject.Properties[$Name]
    if ($null -eq $property -or $null -eq $property.Value) {
        return ''
    }

    return [string]$property.Value
}

function New-V03ImplementationGateReport {
    param(
        [Parameter(Mandatory)]
        [ValidatePattern('^[0-9a-f]{40}$')]
        [string]$SourceCommit,

        [Parameter(Mandatory)]
        [ValidatePattern('^[0-9a-f]{40}$')]
        [string]$SourceTree,

        [Parameter(Mandatory)]
        [ValidatePattern('^[0-9a-f]{40}$')]
        [string]$ExpectedSourceCommit,

        [Parameter(Mandatory)]
        [ValidatePattern('^[0-9a-f]{40}$')]
        [string]$ExpectedSourceTree,

        [AllowEmptyCollection()]
        [Parameter(Mandatory)]
        [object[]]$ChildResults,

        [Parameter(Mandatory)]
        [ValidateSet('PASS', 'FAIL')]
        [string]$Result,

        [string]$FailureCode,

        [Parameter(Mandatory)]
        [DateTime]$GeneratedUtc,

        [int]$ExpectedChildGateCount = 0
    )

    if ($SourceCommit -cne $ExpectedSourceCommit -or $SourceTree -cne $ExpectedSourceTree) {
        throw 'Aggregate report source identity does not match the expected source identity.'
    }

    $passed = @($ChildResults | Where-Object { (Get-V03ChildResultValue -Child $_ -Name 'Status') -eq 'PASS' }).Count
    $partial = @($ChildResults | Where-Object { (Get-V03ChildResultValue -Child $_ -Name 'Status') -eq 'PARTIAL' }).Count
    $failed = @($ChildResults | Where-Object { (Get-V03ChildResultValue -Child $_ -Name 'Status') -eq 'FAIL' }).Count
    $notRun = @($ChildResults | Where-Object { (Get-V03ChildResultValue -Child $_ -Name 'Status') -eq 'NOT_RUN' }).Count
    $attempted = @($ChildResults | Where-Object {
            (Get-V03ChildResultValue -Child $_ -Name 'Attempted') -eq 'True'
        }).Count
    $total = if ($ExpectedChildGateCount -gt 0) { $ExpectedChildGateCount } else { $attempted }
    $lines = @(
        'HerdrOps v0.3.0 Issue #17 Implementation Gate',
        "GeneratedUtc: $($GeneratedUtc.ToUniversalTime().ToString('O'))",
        "SourceCommit: $SourceCommit",
        "SourceTree: $SourceTree",
        "ExpectedSourceCommit: $ExpectedSourceCommit",
        "ExpectedSourceTree: $ExpectedSourceTree",
        "Result: $Result",
        'GateKind: Implementation',
        'EvidenceClasses: Static, Contract, Synthetic',
        "ChildGates: $passed/$total PASS",
        "ChildGatesPartial: $partial/$total PARTIAL",
        "ChildGatesFailed: $failed/$total FAIL",
        "ChildGatesNotRun: $notRun/$total NOT_RUN",
        "ChildGatesAttempted: $attempted/$total",
        'ChildDiagnosticArtifacts: child-gates/',
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
        $reportSha256 = Get-V03ChildResultValue -Child $child -Name 'ReportSha256'
        $suffix = if ([string]::IsNullOrWhiteSpace($reportSha256)) {
            ''
        }
        else {
            " sha256=$reportSha256"
        }
        $status = Get-V03ChildResultValue -Child $child -Name 'Status'
        if ([string]::IsNullOrWhiteSpace($status)) {
            $status = 'NOT_RUN'
        }
        $lines += "$status Issue#$($child.Issue) $($child.Name)$suffix"

        foreach ($artifact in @(
                @{ Label = 'GateReportArtifact'; Name = 'ReportArtifact' },
                @{ Label = 'StdoutArtifact'; Name = 'StdoutArtifact' },
                @{ Label = 'StdoutSha256'; Name = 'StdoutSha256' },
                @{ Label = 'StderrArtifact'; Name = 'StderrArtifact' },
                @{ Label = 'StderrSha256'; Name = 'StderrSha256' },
                @{ Label = 'ContractSelfTestScript'; Name = 'ContractSelfTestScript' },
                @{ Label = 'ContractSelfTestStatus'; Name = 'ContractSelfTestStatus' },
                @{ Label = 'ContractSelfTestStdoutArtifact'; Name = 'ContractSelfTestStdoutArtifact' },
                @{ Label = 'ContractSelfTestStdoutSha256'; Name = 'ContractSelfTestStdoutSha256' },
                @{ Label = 'ContractSelfTestStderrArtifact'; Name = 'ContractSelfTestStderrArtifact' },
                @{ Label = 'ContractSelfTestStderrSha256'; Name = 'ContractSelfTestStderrSha256' },
                @{ Label = 'FailureCode'; Name = 'FailureCode' })) {
            $value = Get-V03ChildResultValue -Child $child -Name $artifact.Name
            if (-not [string]::IsNullOrWhiteSpace($value)) {
                $lines += ('  {0}: {1}' -f $artifact.Label, $value)
            }
        }
    }

    $lines += ''
    $lines += 'EvidenceBoundary:'
    $lines += 'This report is an implementation-only aggregation of the v0.3 Static, Contract, and Synthetic child checks for Issues #12 through #16.'
    $lines += 'Contract-backed WPF rendering and other Contract/Synthetic observations remain admitted only within each child report boundary.'
    $lines += 'This aggregate provides no installed-Herdr evidence, no live File/Git evidence, and no release evidence.'
    $lines += 'It does not decide issue acceptance, close a milestone, or publish a package.'
    $lines += 'A PASS here is implementation preparation evidence only.'
    return $lines
}

Export-ModuleMember -Function @(
    'Get-V03ImplementationChildGateDefinitions',
    'Resolve-V03ImplementationReportPath',
    'Assert-V03ImplementationChildReport',
    'New-V03ImplementationGateReport'
)
