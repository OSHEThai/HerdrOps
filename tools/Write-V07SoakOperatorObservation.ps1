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
$contextPath = Join-Path $root 'soak-context.json'
if (-not (Test-Path -LiteralPath $contextPath -PathType Leaf)) { throw "The immutable soak context is missing: $contextPath" }
$contextJson = Get-V07BoundedUtf8FileText -Path $contextPath -MaxBytes 65536 -Description 'soak context'
Assert-V07StrictJsonText -JsonText $contextJson -SourceDescription 'soak context'
$context = $contextJson | ConvertFrom-Json
if ([string]$context.SchemaVersion -cne 'v0.7.0-soak-context' -or
    [string]$context.ArtifactKind -cne 'SoakContext' -or
    -not (Test-V07UtcTimestampText -Text ([string]$context.StartedUtc))) {
    throw 'The soak context schema or start timestamp is invalid.'
}
$matchingSchedule = @($context.Schedule | Where-Object { [string]$_.Id -ceq $ScheduleId })
if ($matchingSchedule.Count -ne 1) { throw "ScheduleId '$ScheduleId' is not present exactly once in the immutable soak context." }
$scheduled = $matchingSchedule[0]
if ([int]$scheduled.OffsetSeconds -ne $ScheduledOffsetSeconds -or [string]$scheduled.Kind -cne $Kind) {
    throw "ScheduleId '$ScheduleId' kind/offset does not match the immutable soak context."
}
$dueUtc = ([DateTimeOffset]$context.StartedUtc).AddSeconds($ScheduledOffsetSeconds)
$now = [DateTimeOffset]::UtcNow
if ($now -lt $dueUtc) { throw "ScheduleId '$ScheduleId' is not due yet; ObservedUtc must be at or after $($dueUtc.ToUniversalTime().ToString('O'))." }
$evidence = Assert-V07PathWithinRoot -Path $EvidencePath -AllowedRoots @($root) -Description 'operator evidence'
Assert-V07NotReparsePoint -Path $evidence -Description 'operator evidence'
if (-not (Test-Path -LiteralPath $evidence -PathType Leaf)) { throw "Operator evidence file does not exist: $evidence" }

$markerRoot = Join-Path $root 'operator-observations'
New-Item -ItemType Directory -Path $markerRoot -Force | Out-Null
Assert-V07NotReparsePoint -Path $markerRoot -Description 'operator observation directory'
$markerPath = Join-Path $markerRoot ($ScheduleId + '.json')
if (Test-Path -LiteralPath $markerPath) { throw "Operator observation marker already exists and is immutable: $markerPath" }
$marker = [pscustomobject][ordered]@{
    SchemaVersion = 'v0.7.0-soak-operator-observation'
    ScheduleId = $ScheduleId
    Kind = $Kind
    ScheduledOffsetSeconds = $ScheduledOffsetSeconds
    DueUtc = $dueUtc.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ', [Globalization.CultureInfo]::InvariantCulture)
    ObservedUtc = $now.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ', [Globalization.CultureInfo]::InvariantCulture)
    OperatorAcknowledged = $true
    EvidencePath = $evidence
    EvidenceSha256 = Get-V07Sha256Hex -Path $evidence
    Note = $Note
    ScheduleContextSha256 = Get-V07Sha256Hex -Path $contextPath
}
$json = $marker | ConvertTo-Json -Depth 10
$stream = [IO.File]::Open($markerPath, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::Read)
try {
    $utf8 = New-Object System.Text.UTF8Encoding($false)
    $bytes = $utf8.GetBytes($json)
    $stream.Write($bytes, 0, $bytes.Length)
} finally {
    $stream.Dispose()
}
Write-Output $markerPath
Write-Output "EvidenceSha256: $($marker.EvidenceSha256)"
Write-Output 'SessionControlInvoked: false'
