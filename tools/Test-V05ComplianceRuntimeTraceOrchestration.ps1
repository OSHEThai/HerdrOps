[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repositoryRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')).Path
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
    $observedArguments = $null
    [void]$events.Add('pm-confirmation')

    $successRunner = {
        param($Executable, $Arguments, $StandardErrorPath)
        [void]$events.Add('trace-producer')
        $script:observedArguments = @($Arguments)
        [IO.File]::WriteAllText($successTrace, "{}`n", [Text.UTF8Encoding]::new($false))
        [pscustomobject]@{ ExitCode = 0; Output = @('trace-produced') }
    }
    $successResult = Invoke-V05ComplianceReviewTraceProducer `
        -CoreExecutable 'fake-core.exe' `
        -StateDatabasePath $successDatabase `
        -ReviewTracePath $successTrace `
        -IncidentId 'INC-ORDER' `
        -EvidenceDirectory $successDirectory `
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
    $nonzeroThrew = $false
    try {
        Invoke-V05ComplianceReviewTraceProducer `
            -CoreExecutable 'fake-core.exe' `
            -StateDatabasePath (Join-Path $nonzeroDirectory 'state.db') `
            -ReviewTracePath (Join-Path $nonzeroDirectory 'trace.json') `
            -IncidentId 'INC-NONZERO' `
            -EvidenceDirectory $nonzeroDirectory `
            -CommandRunner {
                param($Executable, $Arguments, $StandardErrorPath)
                [IO.File]::WriteAllText($StandardErrorPath, 'producer rejected input', [Text.UTF8Encoding]::new($false))
                [pscustomobject]@{ ExitCode = 23; Output = @() }
            } | Out-Null
        $nonzeroCompositeInvoked = $true
    }
    catch {
        $nonzeroThrew = $_.Exception.Message -match 'exit 23' -and
            $_.Exception.Message -match 'producer rejected input'
    }
    Assert-Test -Name 'producer nonzero fails closed before composite' -Condition (
        $nonzeroThrew -and -not $nonzeroCompositeInvoked)

    $missingDirectory = Join-Path $scratchRoot 'missing'
    [IO.Directory]::CreateDirectory($missingDirectory) | Out-Null
    $missingTracePath = Join-Path $missingDirectory 'trace.json'
    $missingCompositeInvoked = $false
    $missingThrew = $false
    try {
        Invoke-V05ComplianceReviewTraceProducer `
            -CoreExecutable 'fake-core.exe' `
            -StateDatabasePath (Join-Path $missingDirectory 'state.db') `
            -ReviewTracePath $missingTracePath `
            -IncidentId 'INC-MISSING' `
            -EvidenceDirectory $missingDirectory `
            -CommandRunner {
                param($Executable, $Arguments, $StandardErrorPath)
                [pscustomobject]@{ ExitCode = 0; Output = @('no file written') }
            } | Out-Null
        $missingCompositeInvoked = $true
    }
    catch {
        $missingThrew = $_.Exception.Message -ceq "Compliance review trace is missing: $missingTracePath"
    }
    Assert-Test -Name 'producer success without trace fails closed before composite' -Condition (
        $missingThrew -and -not $missingCompositeInvoked)
}
finally {
    if (Test-Path -LiteralPath $scratchRoot) {
        Remove-Item -LiteralPath $scratchRoot -Recurse -Force
    }
}

Write-Output 'EvidenceClass: Static plus deterministic Synthetic orchestration selftest'
Write-Output 'ActualHerdrRuntime: NOT OBSERVED / NOT CLAIMED'
Write-Output 'Release: NOT OBSERVED / NOT CLAIMED'
Write-Output 'v0.5 Issue #28 compliance runtime trace orchestration selftest passed: 6/6 checks.'
