#requires -Version 5.1
[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)]
    [string]$DestinationPath,

    [Parameter(Mandatory=$true)]
    [string]$OperatorIdentity,

    [Parameter(Mandatory=$true)]
    [string]$ReviewerIdentity,

    [Parameter(Mandatory=$true)]
    [ValidateSet('Static','Synthetic','Contract','Runtime','Release')]
    [string]$EvidenceBoundary,

    [Parameter(Mandatory=$true)]
    [hashtable]$Outcomes,

    [Parameter(Mandatory=$false)]
    [string]$RepositoryRoot
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'RendererCompatibility.Common.ps1')

if ([string]::IsNullOrWhiteSpace($RepositoryRoot)) {
    $RepositoryRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
}

$cases = @(
    '1920x1080-100', '1920x1080-125', '1920x1080-150',
    '1366x768-100', '1366x768-125', '1366x768-150',
    'mixed-dpi-100-to-150-primary-switch-unplug', 'mixed-dpi-150-to-100-primary-switch-unplug',
    'mixed-dpi-125-to-150-primary-switch-unplug', 'mixed-dpi-150-to-125-primary-switch-unplug',
    'keyboard-uia', 'narrator', 'high-contrast', 'text-scale-100',
    'text-scale-150', 'text-scale-200', 'reduced-motion-on', 'reduced-motion-off'
)

if (-not (Test-Path -LiteralPath $DestinationPath)) {
    New-Item -Path $DestinationPath -ItemType Directory | Out-Null
}

$now = [datetime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ')
$generated = @()
$receiptsCreated = 0

try {
    foreach ($case in $cases) {
        $outcome = $Outcomes[$case]
        if ([string]::IsNullOrWhiteSpace($outcome)) {
            $outcome = 'FAIL'
        }
        
        if ($outcome -cnotin @('PASS', 'FAIL')) {
            throw "Outcome for case '$case' must be PASS or FAIL. Got: $outcome"
        }
        
        $notesObj = [pscustomobject][ordered]@{
            OperatorIdentity = $OperatorIdentity
            ReviewerIdentity = $ReviewerIdentity
            EvidenceBoundary = $EvidenceBoundary
        }
        $notes = ConvertTo-Json -InputObject $notesObj -Compress
        
        $obs = [pscustomobject][ordered]@{
            ordinal = 0
            observedUtc = $now
            outcome = $outcome
            notes = $notes
        }
        
        $obj = [pscustomobject][ordered]@{
            caseId = $case
            observations = @($obs)
            aggregateStatus = $outcome
        }
        
        $outPath = Join-Path $DestinationPath "matrix-evidence-$case.json"
        Write-RendererPackageCanonicalJson -Value $obj -Path $outPath -RepositoryRoot $RepositoryRoot
        $generated += $outPath
        $receiptsCreated++
    }

    if ($receiptsCreated -ne 18) {
        throw "Failed to atomically create exactly 18 receipts."
    }
} catch {
    foreach ($f in $generated) {
        if (Test-Path -LiteralPath $f) { Remove-Item -LiteralPath $f -Force }
    }
    throw
}

return $generated
