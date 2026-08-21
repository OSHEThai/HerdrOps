[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repositoryRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')).Path
$artifactRoot = Join-Path $repositoryRoot 'artifacts'
$aggregateScript = Join-Path $PSScriptRoot 'Test-V03ImplementationGate.ps1'
Import-Module (Join-Path $PSScriptRoot 'V03ImplementationGate.psm1') -Force

function Assert-Equal {
    param(
        [Parameter(Mandatory)]$Expected,
        [Parameter(Mandatory)]$Actual,
        [Parameter(Mandatory)][string]$Message
    )

    if ($Expected -ne $Actual) {
        throw "$Message Expected='$Expected' Actual='$Actual'"
    }
}

function Assert-True {
    param(
        [Parameter(Mandatory)][bool]$Condition,
        [Parameter(Mandatory)][string]$Message
    )

    if (-not $Condition) {
        throw $Message
    }
}

function Assert-Throws {
    param(
        [Parameter(Mandatory)][scriptblock]$Action,
        [Parameter(Mandatory)][string]$Message
    )

    $thrown = $false
    try {
        & $Action
    }
    catch {
        $thrown = $true
    }
    Assert-True -Condition $thrown -Message $Message
}

function ConvertTo-WindowsProcessArgument {
    param(
        [AllowEmptyString()]
        [string]$Argument
    )

    if ($null -eq $Argument) {
        $Argument = ''
    }

    # ProcessStartInfo.Arguments is a single Windows command-line string on
    # both Windows PowerShell 5.1 and PowerShell 7. Quote every argument using
    # the CommandLineToArgvW rules so paths containing spaces, quotes, or
    # trailing backslashes remain one argument in the child process.
    $builder = New-Object System.Text.StringBuilder
    $null = $builder.Append('"')
    $backslashCount = 0
    foreach ($character in $Argument.ToCharArray()) {
        if ($character -eq [char]92) {
            $backslashCount++
            continue
        }

        if ($character -eq [char]34) {
            $null = $builder.Append((('\' * (($backslashCount * 2) + 1)) -join ''))
            $null = $builder.Append('"')
            $backslashCount = 0
            continue
        }

        if ($backslashCount -gt 0) {
            $null = $builder.Append((('\' * $backslashCount) -join ''))
            $backslashCount = 0
        }
        $null = $builder.Append([string]$character)
    }

    if ($backslashCount -gt 0) {
        $null = $builder.Append((('\' * ($backslashCount * 2)) -join ''))
    }
    $null = $builder.Append('"')
    return $builder.ToString()
}

function Invoke-PwshWithCapturedOutput {
    param(
        [Parameter(Mandatory)][string]$FilePath,
        [Parameter(Mandatory)][string[]]$ArgumentList
    )

    $startInfo = New-Object System.Diagnostics.ProcessStartInfo
    $startInfo.FileName = $FilePath
    $quotedArguments = @($ArgumentList | ForEach-Object {
            ConvertTo-WindowsProcessArgument -Argument ([string]$_)
        })
    $startInfo.Arguments = [string]::Join(' ', [string[]]$quotedArguments)
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true

    $process = New-Object System.Diagnostics.Process
    try {
        $process.StartInfo = $startInfo
        $started = $process.Start()
        if (-not $started) {
            throw [InvalidOperationException]::new('PwshProcessStartFailed')
        }

        # Start both async reads before waiting so a verbose child cannot
        # deadlock on a full stdout or stderr pipe.
        $stdoutTask = $process.StandardOutput.ReadToEndAsync()
        $stderrTask = $process.StandardError.ReadToEndAsync()
        $process.WaitForExit()
        $stdout = $stdoutTask.GetAwaiter().GetResult()
        $stderr = $stderrTask.GetAwaiter().GetResult()

        return [pscustomobject]@{
            ExitCode = [int]$process.ExitCode
            Stdout = [string]$stdout
            Stderr = [string]$stderr
        }
    }
    finally {
        if ($null -ne $process) {
            $process.Dispose()
        }
    }
}

function ConvertTo-ProcessOutputLines {
    param(
        [AllowEmptyString()][string]$Stdout,
        [AllowEmptyString()][string]$Stderr
    )

    $lines = @()
    if (-not [string]::IsNullOrEmpty($Stdout)) {
        $lines += [Regex]::Split($Stdout, "\r\n|\n|\r")
    }
    if (-not [string]::IsNullOrEmpty($Stderr)) {
        $lines += [Regex]::Split($Stderr, "\r\n|\n|\r")
    }
    return $lines
}

function Remove-OwnedFixturePath {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$OwnerRoot
    )

    $separatorChars = [char[]]@([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
    $ownerFull = [IO.Path]::GetFullPath($OwnerRoot).TrimEnd($separatorChars)
    $targetFull = [IO.Path]::GetFullPath($Path).TrimEnd($separatorChars)
    $ownerPrefix = $ownerFull + [IO.Path]::DirectorySeparatorChar

    # Never permit an owner root itself (or any unrelated path) to become a
    # recursive deletion target. Every cleanup target must be a child of the
    # exact fixture root assigned to that target.
    if (-not $targetFull.StartsWith($ownerPrefix, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Refusing to remove fixture path outside owner root: $targetFull"
    }

    if (Test-Path -LiteralPath $targetFull) {
        $resolvedTarget = (Resolve-Path -LiteralPath $targetFull -ErrorAction Stop).Path
        if (-not $resolvedTarget.StartsWith($ownerPrefix, [StringComparison]::OrdinalIgnoreCase)) {
            throw "Refusing to remove fixture path whose resolved target escaped owner root: $resolvedTarget"
        }
        if (-not (Test-Path -LiteralPath $targetFull -PathType Container)) {
            throw "Refusing to remove non-directory fixture target: $targetFull"
        }

        Remove-Item -LiteralPath $targetFull -Recurse -Force -ErrorAction Stop
    }

    if (Test-Path -LiteralPath $targetFull) {
        throw "Owned fixture path was not removed: $targetFull"
    }
}

function Get-AggregateReportPath {
    param(
        [Parameter(Mandatory)][object[]]$Output
    )

    $line = @($Output | ForEach-Object { [string]$_ } | Where-Object {
            $_ -match '^ImplementationGateReport:\s*(?<path>.+?)\s*$'
        })
    Assert-Equal -Expected 1 -Actual $line.Count -Message 'Aggregate report path count was not deterministic.'
    $null = $line[0] -match '^ImplementationGateReport:\s*(?<path>.+?)\s*$'
    return $Matches.path.Trim()
}

function Invoke-AggregateWithCleanTestGit {
    param(
        [Parameter(Mandatory)][string]$AggregateScript,
        [Parameter(Mandatory)][string]$ChildRoot,
        [Parameter(Mandatory)][string]$HelperRoot,
        [switch]$EmitStartupStderr
    )

    $helperPath = Join-Path $HelperRoot 'aggregate-clean-git-helper.ps1'
    $realGitPath = (Get-Command git.exe -ErrorAction Stop).Source.Replace("'", "''")
    $startupStderrLine = if ($EmitStartupStderr) {
        "[Console]::Error.WriteLine('synthetic helper startup stderr')"
    }
    else {
        ''
    }
    $helperText = @"
[CmdletBinding()]
param([string]`$AggregateScript, [string]`$ChildRoot)
function git {
    param([Parameter(ValueFromRemainingArguments=`$true)][string[]]`$Arguments)
    if (`$Arguments -contains 'status') {
        `$global:LASTEXITCODE = 0
        return
    }

    & '$realGitPath' @Arguments
    `$global:LASTEXITCODE = `$LASTEXITCODE
}

# This stub helper spawns its own child process to isolate the fixture run
# from whatever real Herdr session happens to be hosting this test suite.
# The production gate script's own fail-closed check (below) is untouched:
# it still reads these variables directly whenever it runs for real.
Remove-Item Env:\HERDR_ENV -ErrorAction SilentlyContinue
Remove-Item Env:\HERDR_SOCKET_PATH -ErrorAction SilentlyContinue
$startupStderrLine

& `$AggregateScript -Configuration Debug -SkipBuild -ChildGateRoot `$ChildRoot
exit `$LASTEXITCODE
"@
    Set-Content -LiteralPath $helperPath -Value $helperText -Encoding utf8
    $pwshPath = (Get-Command pwsh -ErrorAction Stop).Source
    $capture = Invoke-PwshWithCapturedOutput -FilePath $pwshPath -ArgumentList @(
        '-NoProfile',
        '-File',
        $helperPath,
        '-AggregateScript',
        $AggregateScript,
        '-ChildRoot',
        $ChildRoot
    )
    return [pscustomobject]@{
        ExitCode = [int]$capture.ExitCode
        Output = @(ConvertTo-ProcessOutputLines -Stdout $capture.Stdout -Stderr $capture.Stderr)
    }
}

function New-StubChildGates {
    param(
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][string]$SourceCommit,
        [string]$FailIssue,
        [string]$PartialIssue
    )

    $definitions = @(Get-V03ImplementationChildGateDefinitions)
    $reportRoot = Join-Path $Root 'reports'
    New-Item -ItemType Directory -Path $reportRoot -Force | Out-Null
    foreach ($definition in $definitions) {
        $scriptPath = Join-Path $Root $definition.ScriptName
        $reportPath = Join-Path $reportRoot "issue-$($definition.Issue)-gate-report.txt"
        if ($definition.Issue -eq $FailIssue) {
            $scriptText = @"
[CmdletBinding()]
param([string]`$Configuration, [switch]`$SkipBuild, [switch]`$ImplementationOnly)
throw 'synthetic child failure'
"@
        }
        else {
            $resultValue = if ($definition.Issue -eq $PartialIssue) {
                'IMPLEMENTATION READY / PARTIAL'
            }
            else {
                'PASS'
            }
            $scriptText = @"
[CmdletBinding()]
param([string]`$Configuration, [switch]`$SkipBuild, [switch]`$ImplementationOnly)
@(
    'HerdrOps v0.3 Issue #$($definition.Issue) Implementation Gate',
    'SourceCommit: $SourceCommit',
    'Result: $resultValue',
    'EvidenceClass: Contract plus Synthetic'
) | Set-Content -LiteralPath '$reportPath' -Encoding utf8
Write-Output 'GateReport: $reportPath'
"@
        }
        Set-Content -LiteralPath $scriptPath -Value $scriptText -Encoding utf8
    }
}

function Invoke-AggregateDirectlyWithForcedHerdrEnvironment {
    param(
        [Parameter(Mandatory)][string]$AggregateScript,
        [Parameter(Mandatory)][string]$HelperRoot,
        [switch]$SocketPathOnly
    )

    $helperPath = Join-Path $HelperRoot 'aggregate-forced-herdr-helper.ps1'
    $envAssignments = @()
    if (-not $SocketPathOnly) {
        $envAssignments += "`$env:HERDR_ENV = '1'"
    }
    $envAssignments += "`$env:HERDR_SOCKET_PATH = 'X:\forced-production-check\herdr.sock'"
    $envAssignmentBlock = ($envAssignments -join "`n")
    $helperText = @"
[CmdletBinding()]
param([string]`$AggregateScript)
# Clear any ambient Herdr session so the socket-path-only variant proves its
# branch independently of HERDR_ENV.
Remove-Item Env:\HERDR_ENV -ErrorAction SilentlyContinue
Remove-Item Env:\HERDR_SOCKET_PATH -ErrorAction SilentlyContinue
$envAssignmentBlock
& `$AggregateScript -SkipBuild
exit `$LASTEXITCODE
"@
    Set-Content -LiteralPath $helperPath -Value $helperText -Encoding utf8
    $pwshPath = (Get-Command pwsh -ErrorAction Stop).Source
    $capture = Invoke-PwshWithCapturedOutput -FilePath $pwshPath -ArgumentList @(
        '-NoProfile',
        '-File',
        $helperPath,
        '-AggregateScript',
        $AggregateScript
    )
    return [pscustomobject]@{
        ExitCode = [int]$capture.ExitCode
        Output = @(ConvertTo-ProcessOutputLines -Stdout $capture.Stdout -Stderr $capture.Stderr)
    }
}

$sourceCommit = (& git -C $repositoryRoot rev-parse --verify 'HEAD^{commit}').Trim()
$definitions = @(Get-V03ImplementationChildGateDefinitions)
$aggregateSource = Get-Content -LiteralPath $aggregateScript -Raw
Assert-Equal -Expected '12,13,14,15,16' -Actual (($definitions | ForEach-Object Issue) -join ',') -Message 'Child issue order drifted.'
Assert-Equal -Expected 'Test-V03FileGitActivity.ps1' -Actual $definitions[3].ScriptName -Message 'Issue #15 child script drifted.'
Assert-True -Condition $definitions[3].ImplementationOnly -Message 'Issue #15 must use the implementation-only child mode.'
Assert-True -Condition ($aggregateSource -match '(?s)Invoke-Build\.ps1.*?-SkipTests') -Message 'Default aggregate build path must not invoke the full WPF test suite.'

$fixtureBaseRoot = Join-Path $artifactRoot 'implementation-gate-test-fixtures'
$implementationRunRoot = Join-Path $artifactRoot 'release-gates\v0.3.0\issue-17'
$testRoot = Join-Path $fixtureBaseRoot "run-$([Guid]::NewGuid().ToString('N'))"
$passingReportPath = ''
$failingReportPath = ''
$herdrIsolationRoot = ''
$isolationReportPath = ''
$forcedHerdrReportPath = ''
$socketPathOnlyReportPath = ''
$originalHerdrEnv = $env:HERDR_ENV
$originalHerdrSocketPath = $env:HERDR_SOCKET_PATH
try {
    $reportsRoot = Join-Path $testRoot 'reports'
    New-Item -ItemType Directory -Path $reportsRoot -Force | Out-Null
    $validReportPath = Join-Path $reportsRoot 'valid.txt'
    $validReport = @(
        'HerdrOps v0.3 Issue #12 Implementation Gate',
        "SourceCommit: $sourceCommit",
        'Result: PASS',
        'EvidenceClass: Contract plus Synthetic'
    )
    $validReport | Set-Content -LiteralPath $validReportPath -Encoding utf8

    $resolved = Resolve-V03ImplementationReportPath `
        -Output @("GateReport: $validReportPath") `
        -ArtifactRoot $artifactRoot
    Assert-Equal -Expected (Resolve-Path -LiteralPath $validReportPath).Path -Actual $resolved -Message 'Child report path resolution changed.'
    $validResult = Assert-V03ImplementationChildReport -Name 'Valid' -ReportText (Get-Content -LiteralPath $resolved -Raw) -SourceCommit $sourceCommit
    Assert-Equal -Expected 'PASS' -Actual $validResult -Message 'PASS child result was not returned by the validator.'
    $partialResult = Assert-V03ImplementationChildReport -Name 'Partial' -ReportText "SourceCommit: $sourceCommit`nResult: IMPLEMENTATION READY / PARTIAL`nEvidenceClass: Contract plus Synthetic" -SourceCommit $sourceCommit
    Assert-Equal -Expected 'IMPLEMENTATION READY / PARTIAL' -Actual $partialResult -Message 'Partial child result was not returned by the validator.'
    Assert-Throws -Action { Resolve-V03ImplementationReportPath -Output @('GateReport: one', 'GateReport: two') -ArtifactRoot $artifactRoot } -Message 'Duplicate child report paths were accepted.'
    Assert-Throws -Action { Assert-V03ImplementationChildReport -Name 'Unsafe' -ReportText "SourceCommit: $sourceCommit`nResult: PASS`nEvidenceClass: Runtime" -SourceCommit $sourceCommit } -Message 'Runtime evidence was accepted by the implementation report validator.'

    $fixedTime = [DateTime]::new(2026, 8, 20, 0, 0, 0, [DateTimeKind]::Utc)
    $sampleResults = @(
        [pscustomobject]@{ Issue = '12'; Name = 'ActivityPipeline'; Status = 'PASS'; Attempted = $true; ReportSha256 = 'A' },
        [pscustomobject]@{ Issue = '13'; Name = 'RealtimeActivity'; Status = 'PARTIAL'; Attempted = $true; ReportSha256 = 'B' },
        [pscustomobject]@{ Issue = '14'; Name = 'TerminalProcess'; Status = 'NOT_RUN'; Attempted = $false; ReportSha256 = '' }
    )
    $firstReport = @(New-V03ImplementationGateReport -SourceCommit $sourceCommit -ChildResults $sampleResults -Result PASS -GeneratedUtc $fixedTime -ExpectedChildGateCount 5) -join "`n"
    $secondReport = @(New-V03ImplementationGateReport -SourceCommit $sourceCommit -ChildResults $sampleResults -Result PASS -GeneratedUtc $fixedTime -ExpectedChildGateCount 5) -join "`n"
    Assert-Equal -Expected $firstReport -Actual $secondReport -Message 'Aggregate report bytes were not deterministic.'
    Assert-True -Condition ($firstReport -match 'GateKind: Implementation') -Message 'Aggregate report omitted the implementation scope.'
    Assert-True -Condition ($firstReport -match 'EvidenceClasses: Static, Contract, Synthetic') -Message 'Aggregate report omitted evidence classes.'
    Assert-True -Condition ($firstReport -match '(?m)^ChildGates: 1/5 PASS\r?$') -Message 'Aggregate report masked partial/not-run children as PASS.'
    Assert-True -Condition ($firstReport -match '(?m)^ChildGatesPartial: 1/5 PARTIAL\r?$') -Message 'Aggregate report omitted the partial child count.'
    Assert-True -Condition ($firstReport -match '(?m)^ChildGatesNotRun: 1/5 NOT_RUN\r?$') -Message 'Aggregate report omitted the not-run child count.'
    Assert-True -Condition ($firstReport -match '(?m)^ChildGatesAttempted: 2/5\r?$') -Message 'Aggregate report omitted the attempted child count.'
    Assert-True -Condition ($firstReport -match 'Contract-backed WPF rendering') -Message 'Aggregate report rejected admitted contract-backed WPF observations.'
    Assert-True -Condition ($firstReport -match 'no installed-Herdr evidence') -Message 'Aggregate report omitted the installed-Herdr boundary.'
    Assert-True -Condition ($firstReport -match 'no live File/Git evidence') -Message 'Aggregate report omitted the live File/Git boundary.'
    Assert-True -Condition ($firstReport -match 'no release evidence') -Message 'Aggregate report omitted the release boundary.'
    Assert-True -Condition ($firstReport -notmatch '(?im)^RuntimeAccepted:\s*true\s*$|^ReleaseReady:\s*true\s*$') -Message 'Aggregate report contains a positive acceptance claim.'

    $passingRoot = Join-Path $testRoot 'passing-children'
    New-Item -ItemType Directory -Path $passingRoot -Force | Out-Null
    New-StubChildGates -Root $passingRoot -SourceCommit $sourceCommit -PartialIssue '13'
    $passingResult = Invoke-AggregateWithCleanTestGit -AggregateScript $aggregateScript -ChildRoot $passingRoot -HelperRoot $testRoot -EmitStartupStderr
    $passingOutput = $passingResult.Output
    $passingExitCode = $passingResult.ExitCode
    $passingOutputText = @($passingOutput | ForEach-Object { [string]$_ }) -join ' | '
    Assert-Equal -Expected 0 -Actual $passingExitCode -Message "Aggregate did not propagate all-child success. Output=$passingOutputText"
    Assert-True -Condition ($passingOutputText -match 'synthetic helper startup stderr') -Message 'Process capture lost helper startup stderr.'
    $passingReportPath = Get-AggregateReportPath -Output $passingOutput
    $passingReportText = Get-Content -LiteralPath $passingReportPath -Raw
    Assert-True -Condition ($passingReportText -match '(?m)^Result: PASS\r?$') -Message 'Passing aggregate report did not say PASS.'
    Assert-True -Condition ($passingReportText -match '(?m)^ChildGates: 4/5 PASS\r?$') -Message 'Passing aggregate masked a partial child as PASS.'
    Assert-True -Condition ($passingReportText -match '(?m)^ChildGatesPartial: 1/5 PARTIAL\r?$') -Message 'Passing aggregate did not preserve the partial child status.'
    Assert-True -Condition ($passingReportText -match '(?m)^ChildGatesFailed: 0/5 FAIL\r?$') -Message 'Passing aggregate reported an unexpected child failure.'
    Assert-True -Condition ($passingReportText -match '(?m)^ChildGatesAttempted: 5/5\r?$') -Message 'Passing aggregate did not attempt every child gate.'
    Assert-True -Condition ($passingReportText -match 'StdoutArtifact: child-gates/issue-12\.stdout\.txt') -Message 'Passing aggregate omitted the stdout artifact reference.'
    Assert-True -Condition ($passingReportText -match 'StderrArtifact: child-gates/issue-12\.stderr\.txt') -Message 'Passing aggregate omitted the stderr artifact reference.'
    $passingRunDirectory = Split-Path -Parent $passingReportPath
    $passingDiagnosticDirectory = Join-Path $passingRunDirectory 'child-gates'
    Assert-True -Condition (Test-Path -LiteralPath $passingDiagnosticDirectory -PathType Container) -Message 'Passing aggregate did not create its child diagnostic directory.'
    foreach ($definition in $definitions) {
        Assert-True -Condition (Test-Path -LiteralPath (Join-Path $passingDiagnosticDirectory "issue-$($definition.Issue).stdout.txt") -PathType Leaf) -Message "Missing stdout diagnostic for Issue #$($definition.Issue)."
        Assert-True -Condition (Test-Path -LiteralPath (Join-Path $passingDiagnosticDirectory "issue-$($definition.Issue).stderr.txt") -PathType Leaf) -Message "Missing stderr diagnostic for Issue #$($definition.Issue)."
        Assert-True -Condition (Test-Path -LiteralPath (Join-Path $passingDiagnosticDirectory "issue-$($definition.Issue).gate-report.txt") -PathType Leaf) -Message "Missing copied child report for Issue #$($definition.Issue)."
    }

    $failingRoot = Join-Path $testRoot 'failing-children'
    New-Item -ItemType Directory -Path $failingRoot -Force | Out-Null
    New-StubChildGates -Root $failingRoot -SourceCommit $sourceCommit -FailIssue '14' -PartialIssue '13'
    $failingResult = Invoke-AggregateWithCleanTestGit -AggregateScript $aggregateScript -ChildRoot $failingRoot -HelperRoot $testRoot
    $failingOutput = $failingResult.Output
    $failingExitCode = $failingResult.ExitCode
    Assert-True -Condition ($failingExitCode -ne 0) -Message 'Aggregate swallowed a child-gate failure.'
    $failingReportPath = Get-AggregateReportPath -Output $failingOutput
    $failingReportText = Get-Content -LiteralPath $failingReportPath -Raw
    Assert-True -Condition ($failingReportText -match '(?m)^FailureCode: ChildGateFailed:14\r?$') -Message 'Failed aggregate did not preserve the deterministic child failure code.'
    Assert-True -Condition ($failingReportText -match '(?m)^ChildGates: 3/5 PASS\r?$') -Message 'Failed aggregate did not preserve successful child count.'
    Assert-True -Condition ($failingReportText -match '(?m)^ChildGatesPartial: 1/5 PARTIAL\r?$') -Message 'Failed aggregate did not preserve partial child count.'
    Assert-True -Condition ($failingReportText -match '(?m)^ChildGatesFailed: 1/5 FAIL\r?$') -Message 'Failed aggregate did not preserve failed child count.'
    Assert-True -Condition ($failingReportText -match '(?m)^ChildGatesAttempted: 5/5\r?$') -Message 'Failed aggregate did not attempt children after one failure.'
    $failingRunDirectory = Split-Path -Parent $failingReportPath
    $failingDiagnosticDirectory = Join-Path $failingRunDirectory 'child-gates'
    $failingStderr = Join-Path $failingDiagnosticDirectory 'issue-14.stderr.txt'
    Assert-True -Condition (Test-Path -LiteralPath $failingStderr -PathType Leaf) -Message 'Failed aggregate did not create the failing child stderr artifact.'
    Assert-True -Condition ((Get-Content -LiteralPath $failingStderr -Raw) -match 'synthetic child failure') -Message 'Failed aggregate lost the raw child failure diagnostic.'
    Assert-True -Condition ($failingReportText -notmatch 'synthetic child failure') -Message 'Failed aggregate exposed an unstable raw child error as a FailureCode.'

    # An ambient Herdr session (HERDR_ENV / HERDR_SOCKET_PATH set in this very
    # process, e.g. because the suite is being run from inside Herdr) must not
    # leak into the stub fixture run below and make it non-deterministic.
    $env:HERDR_ENV = '1'
    $env:HERDR_SOCKET_PATH = 'X:\ambient-session\herdr.sock'
    $herdrIsolationRoot = Join-Path $testRoot 'herdr-isolation-children'
    New-Item -ItemType Directory -Path $herdrIsolationRoot -Force | Out-Null
    New-StubChildGates -Root $herdrIsolationRoot -SourceCommit $sourceCommit
    $isolationResult = Invoke-AggregateWithCleanTestGit -AggregateScript $aggregateScript -ChildRoot $herdrIsolationRoot -HelperRoot $testRoot
    $isolationOutput = $isolationResult.Output
    $isolationExitCode = $isolationResult.ExitCode
    $isolationOutputText = @($isolationOutput | ForEach-Object { [string]$_ }) -join ' | '
    Assert-Equal -Expected 0 -Actual $isolationExitCode -Message "Stub fixture suite must stay deterministic under an ambient Herdr session. Output=$isolationOutputText"
    $isolationReportPath = Get-AggregateReportPath -Output $isolationOutput
    $isolationReportText = Get-Content -LiteralPath $isolationReportPath -Raw
    Assert-True -Condition ($isolationReportText -match '(?m)^Result: PASS\r?$') -Message 'Ambient Herdr session leaked into the stub fixture aggregate result.'
    $env:HERDR_ENV = $originalHerdrEnv
    $env:HERDR_SOCKET_PATH = $originalHerdrSocketPath

    # Outside the stub isolation above, the production gate must still refuse
    # to run for real under a real Herdr environment (fail-closed). The report
    # path is captured before any assertion so a failing assertion still lets
    # the finally block remove the forced-Herdr report directory.
    $forcedHerdrResult = Invoke-AggregateDirectlyWithForcedHerdrEnvironment -AggregateScript $aggregateScript -HelperRoot $testRoot
    $forcedHerdrOutput = $forcedHerdrResult.Output
    $forcedHerdrExitCode = $forcedHerdrResult.ExitCode
    $forcedHerdrOutputText = @($forcedHerdrOutput | ForEach-Object { [string]$_ }) -join ' | '
    $forcedHerdrReportPath = Get-AggregateReportPath -Output $forcedHerdrOutput
    $forcedHerdrReportText = Get-Content -LiteralPath $forcedHerdrReportPath -Raw
    Assert-True -Condition ($forcedHerdrExitCode -ne 0) -Message "The production gate must still refuse to run under a real Herdr environment. Output=$forcedHerdrOutputText"
    Assert-True -Condition ($forcedHerdrReportText -match '(?m)^FailureCode: AuthorizedHerdrEnvironment\r?$') -Message 'The production gate did not fail closed with AuthorizedHerdrEnvironment under a real Herdr session.'

    # HERDR_SOCKET_PATH alone must independently trigger the same fail-closed
    # refusal, proving the socket-path branch does not depend on HERDR_ENV.
    $socketPathOnlyResult = Invoke-AggregateDirectlyWithForcedHerdrEnvironment -AggregateScript $aggregateScript -HelperRoot $testRoot -SocketPathOnly
    $socketPathOnlyOutput = $socketPathOnlyResult.Output
    $socketPathOnlyExitCode = $socketPathOnlyResult.ExitCode
    $socketPathOnlyOutputText = @($socketPathOnlyOutput | ForEach-Object { [string]$_ }) -join ' | '
    $socketPathOnlyReportPath = Get-AggregateReportPath -Output $socketPathOnlyOutput
    $socketPathOnlyReportText = Get-Content -LiteralPath $socketPathOnlyReportPath -Raw
    Assert-True -Condition ($socketPathOnlyExitCode -ne 0) -Message "The production gate must refuse to run when only HERDR_SOCKET_PATH is set. Output=$socketPathOnlyOutputText"
    Assert-True -Condition ($socketPathOnlyReportText -match '(?m)^FailureCode: AuthorizedHerdrEnvironment\r?$') -Message 'The production gate did not fail closed with AuthorizedHerdrEnvironment when only HERDR_SOCKET_PATH was set.'

    # Directly exercise the ProcessStartInfo seam with a path containing
    # spaces. The child emits stderr and exits nonzero; both channels and the
    # exact exit code must survive without PS5 treating stderr as an exception.
    $startupStderrRoot = Join-Path $testRoot 'process capture path with spaces'
    New-Item -ItemType Directory -Path $startupStderrRoot -Force | Out-Null
    $startupStderrScript = Join-Path $startupStderrRoot 'startup stderr exit.ps1'
    @(
        "[Console]::Out.WriteLine('synthetic startup stdout')",
        "[Console]::Error.WriteLine('synthetic startup stderr')",
        'exit 23'
    ) | Set-Content -LiteralPath $startupStderrScript -Encoding utf8
    $pwshPath = (Get-Command pwsh -ErrorAction Stop).Source
    $startupCapture = Invoke-PwshWithCapturedOutput -FilePath $pwshPath -ArgumentList @(
        '-NoProfile',
        '-File',
        $startupStderrScript
    )
    Assert-Equal -Expected 23 -Actual $startupCapture.ExitCode -Message 'Process capture did not preserve a nonzero child exit code.'
    Assert-True -Condition ($startupCapture.Stdout -match 'synthetic startup stdout') -Message 'Process capture lost child stdout.'
    Assert-True -Condition ($startupCapture.Stderr -match 'synthetic startup stderr') -Message 'Process capture lost startup stderr.'

    # Regression: running a PowerShell test script that executes negative child
    # processes must still deterministically exit 0 on clean completion under
    # both normal invocation and dot-sourcing (-Command ". 'script.ps1'").
    $cleanExitScript = Join-Path $testRoot 'clean-exit-regression.ps1'
    @(
        '$ErrorActionPreference = "Stop"',
        "& '$pwshPath' -NoProfile -Command 'exit 42'",
        '$global:LASTEXITCODE = 0',
        "Write-Output 'RegressionSubscript: PASS'"
    ) | Set-Content -LiteralPath $cleanExitScript -Encoding utf8

    $dotSourceCapture = Invoke-PwshWithCapturedOutput -FilePath $pwshPath -ArgumentList @(
        '-NoProfile',
        '-Command',
        ". '$cleanExitScript'; exit `$LASTEXITCODE"
    )
    Assert-Equal -Expected 0 -Actual $dotSourceCapture.ExitCode -Message 'Dot-sourced PowerShell script leaked nonzero LASTEXITCODE on success.'
    Assert-True -Condition ($dotSourceCapture.Stdout -match 'RegressionSubscript: PASS') -Message 'Dot-sourced regression subscript output lost.'

    $ps5Command = Get-Command powershell.exe -ErrorAction SilentlyContinue
    if ($null -ne $ps5Command -and -not [string]::IsNullOrWhiteSpace($ps5Command.Source)) {
        $ps5DotSourceCapture = Invoke-PwshWithCapturedOutput -FilePath $ps5Command.Source -ArgumentList @(
            '-NoProfile',
            '-ExecutionPolicy',
            'Bypass',
            '-Command',
            ". '$cleanExitScript'; exit `$LASTEXITCODE"
        )
        Assert-Equal -Expected 0 -Actual $ps5DotSourceCapture.ExitCode -Message 'PS5 dot-sourced PowerShell script leaked nonzero LASTEXITCODE on success.'
        Assert-True -Condition ($ps5DotSourceCapture.Stdout -match 'RegressionSubscript: PASS') -Message 'PS5 dot-sourced regression subscript output lost.'
    }

    # Regression (PR #141 / Issues #15, #16): Test-V03RuntimeCaptureProvenanceTests.ps1
    # executes negative git fixtures but must deterministically exit 0 under direct invocation
    # and CI runner dot-sourcing in both PowerShell 7 and Windows PowerShell 5.1 without leaking LASTEXITCODE.
    $provenanceTestScript = Join-Path $PSScriptRoot 'Test-V03RuntimeCaptureProvenanceTests.ps1'
    $pwshProvenanceCapture = Invoke-PwshWithCapturedOutput -FilePath $pwshPath -ArgumentList @(
        '-NoProfile',
        '-File',
        $provenanceTestScript
    )
    Assert-Equal -Expected 0 -Actual $pwshProvenanceCapture.ExitCode -Message 'Test-V03RuntimeCaptureProvenanceTests.ps1 failed under pwsh direct invocation.'
    Assert-True -Condition ($pwshProvenanceCapture.Stdout -match 'All v0.3 runtime-capture provenance hostile selftests passed') -Message 'Test-V03RuntimeCaptureProvenanceTests.ps1 pwsh output missing pass banner.'

    $pwshProvenanceCiCapture = Invoke-PwshWithCapturedOutput -FilePath $pwshPath -ArgumentList @(
        '-NoProfile',
        '-Command',
        ". '$provenanceTestScript'; if ((Test-Path -LiteralPath variable:\LASTEXITCODE)) { exit `$LASTEXITCODE }"
    )
    Assert-Equal -Expected 0 -Actual $pwshProvenanceCiCapture.ExitCode -Message 'Test-V03RuntimeCaptureProvenanceTests.ps1 leaked nonzero LASTEXITCODE under pwsh CI runner pattern.'

    if ($null -ne $ps5Command -and -not [string]::IsNullOrWhiteSpace($ps5Command.Source)) {
        $ps5ProvenanceCapture = Invoke-PwshWithCapturedOutput -FilePath $ps5Command.Source -ArgumentList @(
            '-NoProfile',
            '-ExecutionPolicy',
            'Bypass',
            '-File',
            $provenanceTestScript
        )
        Assert-Equal -Expected 0 -Actual $ps5ProvenanceCapture.ExitCode -Message 'Test-V03RuntimeCaptureProvenanceTests.ps1 failed under PS5 direct invocation.'
        Assert-True -Condition ($ps5ProvenanceCapture.Stdout -match 'All v0.3 runtime-capture provenance hostile selftests passed') -Message 'Test-V03RuntimeCaptureProvenanceTests.ps1 PS5 output missing pass banner.'

        $ps5ProvenanceCiCapture = Invoke-PwshWithCapturedOutput -FilePath $ps5Command.Source -ArgumentList @(
            '-NoProfile',
            '-ExecutionPolicy',
            'Bypass',
            '-Command',
            ". '$provenanceTestScript'; if ((Test-Path -LiteralPath variable:\LASTEXITCODE)) { exit `$LASTEXITCODE }"
        )
        Assert-Equal -Expected 0 -Actual $ps5ProvenanceCiCapture.ExitCode -Message 'Test-V03RuntimeCaptureProvenanceTests.ps1 leaked nonzero LASTEXITCODE under PS5 CI runner pattern.'
    }
}
finally {
    $cleanupFailures = @()
    try {
        $env:HERDR_ENV = $originalHerdrEnv
        $env:HERDR_SOCKET_PATH = $originalHerdrSocketPath
    }
    catch {
        $cleanupFailures += $_
    }

    foreach ($cleanupTarget in @(
            [pscustomobject]@{ Path = if ([string]::IsNullOrWhiteSpace($passingReportPath)) { '' } else { Split-Path -Parent $passingReportPath }; OwnerRoot = $implementationRunRoot },
            [pscustomobject]@{ Path = if ([string]::IsNullOrWhiteSpace($failingReportPath)) { '' } else { Split-Path -Parent $failingReportPath }; OwnerRoot = $implementationRunRoot },
            [pscustomobject]@{ Path = if ([string]::IsNullOrWhiteSpace($isolationReportPath)) { '' } else { Split-Path -Parent $isolationReportPath }; OwnerRoot = $implementationRunRoot },
            [pscustomobject]@{ Path = if ([string]::IsNullOrWhiteSpace($forcedHerdrReportPath)) { '' } else { Split-Path -Parent $forcedHerdrReportPath }; OwnerRoot = $implementationRunRoot },
            [pscustomobject]@{ Path = if ([string]::IsNullOrWhiteSpace($socketPathOnlyReportPath)) { '' } else { Split-Path -Parent $socketPathOnlyReportPath }; OwnerRoot = $implementationRunRoot },
            [pscustomobject]@{ Path = $testRoot; OwnerRoot = $fixtureBaseRoot })) {
        if (-not [string]::IsNullOrWhiteSpace($cleanupTarget.Path)) {
            try {
                Remove-OwnedFixturePath -Path $cleanupTarget.Path -OwnerRoot $cleanupTarget.OwnerRoot
            }
            catch {
                $cleanupFailures += $_
            }
        }
    }

    if ($cleanupFailures.Count -gt 0) {
        $cleanupMessage = @($cleanupFailures | ForEach-Object { $_.Exception.Message }) -join '; '
        throw "Fixture cleanup failed closed: $cleanupMessage"
    }

    $global:LASTEXITCODE = 0
}

$global:LASTEXITCODE = 0
Write-Output 'Test-V03ImplementationGateTests: PASS'
exit 0
