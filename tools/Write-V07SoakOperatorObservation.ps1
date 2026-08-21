<#!
.SYNOPSIS
    Records one human operator observation for the v0.7 actual-Herdr soak.

.DESCRIPTION
    This command is an explicit operator action. It does not control Herdr or
    any product process. It writes a single immutable marker and binds the
    operator's evidence file bytes by SHA-256. The soak producer consumes the
    marker only after the scheduled observation is due.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$SoakOutputDirectory,
    [Parameter(Mandatory)][string]$ScheduleId,
    [Parameter(Mandatory)][ValidateRange(1, 28800)][int]$ScheduledOffsetSeconds,
    [Parameter(Mandatory)][string]$Kind,
    [Parameter(Mandatory)][string]$EvidencePath,
    [string]$Note = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'lib\V07SoakProducerPolicy.ps1')

$root = [IO.Path]::GetFullPath($SoakOutputDirectory)
if (-not (Test-Path -LiteralPath $root -PathType Container)) { throw "Soak output directory does not exist: $root" }
Assert-V07NotReparsePoint -Path $root -Description 'soak output directory'
$evidence = Assert-V07PathWithinRoot -Path $EvidencePath -AllowedRoots @($root) -Description 'operator evidence'
Assert-V07NotReparsePoint -Path $evidence -Description 'operator evidence'
if (-not (Test-Path -LiteralPath $evidence -PathType Leaf)) { throw "Operator evidence file does not exist: $evidence" }

$markerRoot = Join-Path $root 'operator-observations'
New-Item -ItemType Directory -Path $markerRoot -Force | Out-Null
$markerPath = Join-Path $markerRoot ($ScheduleId + '.json')
if (Test-Path -LiteralPath $markerPath) { throw "Operator observation marker already exists and is immutable: $markerPath" }
$now = [DateTimeOffset]::UtcNow
$marker = [pscustomobject][ordered]@{
    SchemaVersion = 'v0.7.0-soak-operator-observation'
    ScheduleId = $ScheduleId
    Kind = $Kind
    ScheduledOffsetSeconds = $ScheduledOffsetSeconds
    DueUtc = $now.AddSeconds(-1).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ', [Globalization.CultureInfo]::InvariantCulture)
    ObservedUtc = $now.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ', [Globalization.CultureInfo]::InvariantCulture)
    OperatorAcknowledged = $true
    EvidencePath = $evidence
    EvidenceSha256 = Get-V07Sha256Hex -Path $evidence
    Note = $Note
}
$json = $marker | ConvertTo-Json -Depth 10
[IO.File]::WriteAllText($markerPath, $json, (New-Object System.Text.UTF8Encoding($false)))
Write-Output $markerPath
Write-Output "EvidenceSha256: $($marker.EvidenceSha256)"
Write-Output 'SessionControlInvoked: false'
