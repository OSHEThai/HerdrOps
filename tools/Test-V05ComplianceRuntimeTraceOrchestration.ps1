[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$helperPath = Join-Path $PSScriptRoot 'lib\V05ComplianceRuntimeTraceOrchestration.ps1'
$harnessPath = Join-Path $PSScriptRoot 'Invoke-V05ComplianceRuntimeAcceptance.ps1'

if (-not (Test-Path -LiteralPath $helperPath -PathType Leaf)) {
    throw "Runtime trace orchestration helper is missing: $helperPath"
}
if (-not (Test-Path -LiteralPath $harnessPath -PathType Leaf)) {
    throw "Runtime acceptance harness is missing: $harnessPath"
}

. $helperPath

function Assert-Test {
    param(
        [Parameter(Mandatory)]
        [string]$Name,

        [Parameter(Mandatory)]
        [bool]$Condition
    )

    if (-not $Condition) {
        throw "FAILED: $Name"
    }
    Write-Output "PASS: $Name"
}

function New-RunnerResult {
    param(
        [int]$ExitCode = 0,
        [bool]$TimedOut = $false,
        [long]$StdoutByteCount = 0,
        [long]$StderrByteCount = 0,
        [bool]$StdoutExceeded = $false,
        [bool]$StderrExceeded = $false,
        [string]$UntrustedOutput = ''
    )

    [pscustomobject]@{
        ExitCode = $ExitCode
        TimedOut = $TimedOut
        StdoutByteCount = $StdoutByteCount
        StderrByteCount = $StderrByteCount
        StdoutExceeded = $StdoutExceeded
        StderrExceeded = $StderrExceeded
        UntrustedOutput = $UntrustedOutput
    }
}

$harnessSource = Get-Content -LiteralPath $harnessPath -Raw
$producerCallMatches = [regex]::Matches(
    $harnessSource,
    '(?m)^\s*\$reviewTraceResult\s*=\s*Invoke-V05ComplianceReviewTraceProducer\s+`\s*$')
$confirmIndex = $harnessSource.IndexOf('PM Confirm failed with exit', [StringComparison]::Ordinal)
$producerIndex = $harnessSource.IndexOf(
    '$reviewTraceResult = Invoke-V05ComplianceReviewTraceProducer',
    [StringComparison]::Ordinal)
$stateCompletionIndex = $harnessSource.IndexOf(
    '$stateProcess.WaitForExit($waitMilliseconds)',
    [StringComparison]::Ordinal)
$compositeIndex = $harnessSource.IndexOf("'compliance-review-acceptance'", [StringComparison]::Ordinal)

Assert-Test -Name 'production source invokes the producer exactly once' -Condition (
    $producerCallMatches.Count -eq 1)
Assert-Test -Name 'production order is PM confirmation then producer then state completion then composite' -Condition (
    $confirmIndex -ge 0 -and
    $producerIndex -gt $confirmIndex -and
    $stateCompletionIndex -gt $producerIndex -and
    $compositeIndex -gt $stateCompletionIndex)

$scratchRoot = Join-Path ([IO.Path]::GetTempPath()) ("herdrops-v05-trace-orchestration-" + [Guid]::NewGuid().ToString('N'))
[IO.Directory]::CreateDirectory($scratchRoot) | Out-Null
$sensitiveToken = 'ghp_issue28_DO_NOT_DISCLOSE_0123456789'

try {
    $successDirectory = Join-Path $scratchRoot 'success'
    [IO.Directory]::CreateDirectory($successDirectory) | Out-Null
    $successDatabase = Join-Path $successDirectory 'state.db'
    $successTrace = Join-Path $successDirectory 'trace.json'
    $expectedArguments = @(
        'trace-compliance-review',
        '--database', $successDatabase,
        '--report', $successTrace,
        '--incident', 'INC-ORDER')
    $events = New-Object System.Collections.Generic.List[string]
    $script:observedArguments = $null
    [void]$events.Add('pm-confirmation')

    $successRunner = {
        param($Executable, $Arguments, $MaximumBytesPerStream, $TimeoutMilliseconds)
        [void]$events.Add('trace-producer')
        $script:observedArguments = @($Arguments)
        [IO.File]::WriteAllText($successTrace, "{}`n", (New-Object Text.UTF8Encoding($false)))
        New-RunnerResult
    }
    $successResult = Invoke-V05ComplianceReviewTraceProducer `
        -CoreExecutable 'fake-core.exe' `
        -StateDatabasePath $successDatabase `
        -ReviewTracePath $successTrace `
        -IncidentId 'INC-ORDER' `
        -CommandRunner $successRunner
    [void]$events.Add('state-service-completion')
    [void]$events.Add('composite')

    $argumentMatch = $observedArguments.Count -eq $expectedArguments.Count
    if ($argumentMatch) {
        for ($index = 0; $index -lt $expectedArguments.Count; $index++) {
            if ($observedArguments[$index] -cne $expectedArguments[$index]) {
                $argumentMatch = $false
                break
            }
        }
    }
    Assert-Test -Name 'producer receives exact command and database report incident arguments' -Condition (
        $successResult.ExitCode -eq 0 -and
        $successResult.TracePath -ceq $successTrace -and
        $argumentMatch)
    Assert-Test -Name 'deterministic success order reaches composite only after producer and state completion' -Condition (
        (($events.ToArray() -join '|') -ceq 'pm-confirmation|trace-producer|state-service-completion|composite'))

    $nonzeroDirectory = Join-Path $scratchRoot 'nonzero'
    [IO.Directory]::CreateDirectory($nonzeroDirectory) | Out-Null
    $nonzeroCompositeInvoked = $false
    $nonzeroMessage = ''
    try {
        Invoke-V05ComplianceReviewTraceProducer `
            -CoreExecutable 'fake-core.exe' `
            -StateDatabasePath (Join-Path $nonzeroDirectory 'state.db') `
            -ReviewTracePath (Join-Path $nonzeroDirectory 'trace.json') `
            -IncidentId 'INC-NONZERO' `
            -CommandRunner {
                param($Executable, $Arguments, $MaximumBytesPerStream, $TimeoutMilliseconds)
                New-RunnerResult -ExitCode 23 -StderrByteCount 41 -UntrustedOutput $sensitiveToken
            } | Out-Null
        $nonzeroCompositeInvoked = $true
    }
    catch {
        $nonzeroMessage = $_.Exception.Message
    }
    Assert-Test -Name 'producer nonzero is redacted and suppresses composite' -Condition (
        $nonzeroMessage -match 'exit 23' -and
        $nonzeroMessage -match 'No process output was retained' -and
        $nonzeroMessage -notmatch [regex]::Escape($sensitiveToken) -and
        -not $nonzeroCompositeInvoked)

    $missingDirectory = Join-Path $scratchRoot 'missing'
    [IO.Directory]::CreateDirectory($missingDirectory) | Out-Null
    $missingTracePath = Join-Path $missingDirectory 'trace.json'
    $missingCompositeInvoked = $false
    $missingMessage = ''
    try {
        Invoke-V05ComplianceReviewTraceProducer `
            -CoreExecutable 'fake-core.exe' `
            -StateDatabasePath (Join-Path $missingDirectory 'state.db') `
            -ReviewTracePath $missingTracePath `
            -IncidentId 'INC-MISSING' `
            -CommandRunner { New-RunnerResult } | Out-Null
        $missingCompositeInvoked = $true
    }
    catch {
        $missingMessage = $_.Exception.Message
    }
    Assert-Test -Name 'producer success without trace fails closed before composite' -Condition (
        $missingMessage -ceq "Compliance review trace is missing: $missingTracePath" -and
        -not $missingCompositeInvoked)

    $childScript = Join-Path $scratchRoot 'emit-hostile-output.ps1'
    [IO.File]::WriteAllText(
        $childScript,
        @'
param([string]$Stream, [string]$Token)
$payload = $Token + ('X' * 8192)
if ($Stream -ceq 'stdout') {
    [Console]::Out.Write($payload)
}
else {
    [Console]::Error.Write($payload)
}
exit 29
'@,
        (New-Object Text.UTF8Encoding($false)))
    $hostExecutable = (Get-Process -Id $PID).Path

    $nativeStdout = Invoke-V05BoundedProcess `
        -FilePath $hostExecutable `
        -ArgumentList @('-NoLogo', '-NoProfile', '-File', $childScript, 'stdout', $sensitiveToken) `
        -MaximumBytesPerStream 1024 `
        -TimeoutMilliseconds 30000
    Assert-Test -Name 'native oversized stdout is drained without retaining content' -Condition (
        $nativeStdout.ExitCode -eq 29 -and
        $nativeStdout.StdoutExceeded -and
        $nativeStdout.StdoutByteCount -gt 1024 -and
        $nativeStdout.PSObject.Properties.Name -notcontains 'Stdout' -and
        $nativeStdout.PSObject.Properties.Name -notcontains 'Output')

    $nativeStderr = Invoke-V05BoundedProcess `
        -FilePath $hostExecutable `
        -ArgumentList @('-NoLogo', '-NoProfile', '-File', $childScript, 'stderr', $sensitiveToken) `
        -MaximumBytesPerStream 1024 `
        -TimeoutMilliseconds 30000
    Assert-Test -Name 'native oversized stderr is drained without retaining content' -Condition (
        $nativeStderr.ExitCode -eq 29 -and
        $nativeStderr.StderrExceeded -and
        $nativeStderr.StderrByteCount -gt 1024 -and
        $nativeStderr.PSObject.Properties.Name -notcontains 'Stderr' -and
        $nativeStderr.PSObject.Properties.Name -notcontains 'Error')

    foreach ($streamName in @('stdout', 'stderr')) {
        $oversizedDirectory = Join-Path $scratchRoot ("oversized-" + $streamName)
        [IO.Directory]::CreateDirectory($oversizedDirectory) | Out-Null
        $oversizedCompositeInvoked = $false
        $oversizedMessage = ''
        $isStdout = $streamName -ceq 'stdout'
        $oversizedRunner = {
            param($Executable, $Arguments, $MaximumBytesPerStream, $TimeoutMilliseconds)
            if ($isStdout) {
                New-RunnerResult -ExitCode 29 -StdoutByteCount 8192 -StdoutExceeded $true -UntrustedOutput $sensitiveToken
            }
            else {
                New-RunnerResult -ExitCode 29 -StderrByteCount 8192 -StderrExceeded $true -UntrustedOutput $sensitiveToken
            }
        }
        try {
            Invoke-V05ComplianceReviewTraceProducer `
                -CoreExecutable 'fake-core.exe' `
                -StateDatabasePath (Join-Path $oversizedDirectory 'state.db') `
                -ReviewTracePath (Join-Path $oversizedDirectory 'trace.json') `
                -IncidentId ("INC-OVERSIZED-" + $streamName.ToUpperInvariant()) `
                -MaximumBytesPerStream 1024 `
                -CommandRunner $oversizedRunner | Out-Null
            $oversizedCompositeInvoked = $true
        }
        catch {
            $oversizedMessage = $_.Exception.Message
        }
        Assert-Test -Name ("oversized {0} is redacted and suppresses composite" -f $streamName) -Condition (
            $oversizedMessage -match 'output exceeded' -and
            $oversizedMessage -match 'No process output was retained' -and
            $oversizedMessage -notmatch [regex]::Escape($sensitiveToken) -and
            -not $oversizedCompositeInvoked)
    }
}
finally {
    if (Test-Path -LiteralPath $scratchRoot) {
        Remove-Item -LiteralPath $scratchRoot -Recurse -Force
    }
}

Write-Output 'EvidenceClass: Static plus deterministic Synthetic orchestration selftest'
Write-Output 'ActualHerdrRuntime: NOT OBSERVED / NOT CLAIMED'
Write-Output 'Release: NOT OBSERVED / NOT CLAIMED'
Write-Output 'v0.5 Issue #28 compliance runtime trace orchestration selftest passed: 10/10 checks.'
