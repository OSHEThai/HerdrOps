# Shared fail-closed producer orchestration for the v0.5 Issue #28 runtime harness.
# Compatible with PowerShell 7 and Windows PowerShell 5.1.
function Invoke-V05ComplianceReviewTraceProducer {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$CoreExecutable,

        [Parameter(Mandatory)]
        [string]$StateDatabasePath,

        [Parameter(Mandatory)]
        [string]$ReviewTracePath,

        [Parameter(Mandatory)]
        [string]$IncidentId,

        [Parameter(Mandatory)]
        [string]$EvidenceDirectory,

        [scriptblock]$CommandRunner
    )

    $producerArguments = @(
        'trace-compliance-review',
        '--database', $StateDatabasePath,
        '--report', $ReviewTracePath,
        '--incident', $IncidentId)
    $producerErrorPath = Join-Path $EvidenceDirectory 'compliance-review-trace.stderr.txt'

    if ($null -eq $CommandRunner) {
        $producerOutput = @(& $CoreExecutable @producerArguments 2> $producerErrorPath)
        $producerExitCode = $LASTEXITCODE
    }
    else {
        $runnerResult = & $CommandRunner $CoreExecutable $producerArguments $producerErrorPath
        if ($null -eq $runnerResult -or
            $runnerResult.PSObject.Properties.Name -notcontains 'ExitCode') {
            throw 'Compliance review trace command runner did not return an ExitCode.'
        }

        $producerExitCode = [int]$runnerResult.ExitCode
        $producerOutput = if ($runnerResult.PSObject.Properties.Name -contains 'Output') {
            @($runnerResult.Output)
        }
        else {
            @()
        }
    }

    if ($producerExitCode -ne 0) {
        $producerError = if (Test-Path -LiteralPath $producerErrorPath -PathType Leaf) {
            Get-Content -LiteralPath $producerErrorPath -Raw
        }
        else {
            ''
        }
        throw "Compliance review trace failed with exit $producerExitCode. $producerError"
    }

    if (-not (Test-Path -LiteralPath $ReviewTracePath -PathType Leaf)) {
        throw "Compliance review trace is missing: $ReviewTracePath"
    }

    [pscustomobject]@{
        ExitCode = $producerExitCode
        Output = $producerOutput
        StandardErrorPath = $producerErrorPath
        TracePath = $ReviewTracePath
    }
}
