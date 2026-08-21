# HerdrOps v0.7 Issue #39 actual-Herdr soak producer/policy tests.
# Static/Contract/Synthetic only. Never starts Herdr, invokes session control,
# launches the live soak, or writes Runtime/Release evidence.
[CmdletBinding()]
param([string]$RepositoryRoot = '')

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false

$root = if ([string]::IsNullOrWhiteSpace($RepositoryRoot)) {
    (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')).Path
} else { (Resolve-Path -LiteralPath $RepositoryRoot).Path }

Remove-Item Env:HERDR_ENV -ErrorAction SilentlyContinue
Remove-Item Env:HERDR_SOCKET_PATH -ErrorAction SilentlyContinue
Remove-Item Env:HERDR_PANE_ID -ErrorAction SilentlyContinue

$testCount = 0
$passCount = 0
function Assert-SoakTest {
    param([Parameter(Mandatory)][string]$Name, [Parameter(Mandatory)][bool]$Condition, [string]$Detail = '')
    $script:testCount++
    if ($Condition) { $script:passCount++; Write-Host "[PASS] $Name" }
    else { throw "[FAIL] $Name $Detail" }
}

function Assert-Parse {
    param([Parameter(Mandatory)][string]$Path)
    $tokens = $null
    $errors = $null
    $text = [IO.File]::ReadAllText($Path)
    [System.Management.Automation.Language.Parser]::ParseInput($text, [ref]$tokens, [ref]$errors) | Out-Null
    Assert-SoakTest -Name "PowerShell parses $([IO.Path]::GetFileName($Path))" -Condition ($errors.Count -eq 0) -Detail (($errors | ForEach-Object Message) -join '; ')
}

$scriptPaths = @(
    (Join-Path $root 'tools\lib\V07SoakProducerPolicy.ps1'),
    (Join-Path $root 'tools\Invoke-V07ActualHerdrSoak.ps1'),
    (Join-Path $root 'tools\Write-V07SoakOperatorObservation.ps1')
)
foreach ($path in $scriptPaths) {
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "Required Issue #39 file is missing: $path" }
    Assert-Parse -Path $path
}

$producerText = [IO.File]::ReadAllText((Join-Path $root 'tools\Invoke-V07ActualHerdrSoak.ps1'))
Assert-SoakTest -Name 'live producer has no Herdr session-control command' -Condition (
    ($producerText -notmatch '(?im)^\s*(?:&\s*)?herdr(?:\.exe|\.cmd)?\s+session\b') -and
    ($producerText -notmatch '(?im)Start-Process\s+(?:-FilePath\s+)?[''\"]?herdr(?:\.exe|\.cmd)?[''\"]?.*session\b')
)
Assert-SoakTest -Name 'live producer has no Stop-Process operation' -Condition ($producerText -notmatch '(?im)\bStop-Process\b')
Assert-SoakTest -Name 'live producer retains explicit non-claim boundary' -Condition ($producerText.Contains('HumanUatDecision: NOT OBSERVED / PENDING') -and $producerText.Contains('ReleaseEvidence: NOT OBSERVED / NOT CLAIMED'))

. (Join-Path $root 'tools\lib\V07MeasurementSelfTests.ps1')
. (Join-Path $root 'tools\lib\V07SoakProducerPolicy.ps1')
$fixture = (Get-V07BoundedUtf8FileText -Path (Join-Path $root 'tests\fixtures\v0.7\performance-measurement\live-measurement-good.json') -Description 'measurement fixture') | ConvertFrom-Json
$synth = New-V07SynthesizedLiveArtifact -BaseArtifact $fixture -RepositoryRoot $root
$soak = New-V07SyntheticSoakArtifact -MeasurementArtifact $synth
$valid = Test-V07SoakArtifact -SoakArtifact $soak -MeasurementArtifact $synth -RepositoryRoot $root
Assert-SoakTest -Name 'synthetic producer provenance validates against measurement chain' -Condition $valid.Valid -Detail ($valid.Failures -join '; ')

$missingHeartbeat = ($soak | ConvertTo-Json -Depth 40) | ConvertFrom-Json
$missingHeartbeat.Provenance.MissingHeartbeatCount = 1
$rejected = Test-V07SoakArtifact -SoakArtifact $missingHeartbeat -MeasurementArtifact $synth
Assert-SoakTest -Name 'missing heartbeat provenance fails closed' -Condition (-not $rejected.Valid)

$tamperedChain = ($soak | ConvertTo-Json -Depth 40) | ConvertFrom-Json
$tamperedChain.Provenance.HeartbeatEntries[1].EntrySha256 = ('0' * 64)
$rejected = Test-V07SoakArtifact -SoakArtifact $tamperedChain -MeasurementArtifact $synth
Assert-SoakTest -Name 'tampered heartbeat chain fails closed' -Condition (-not $rejected.Valid)

$unsafeManifest = ($soak | ConvertTo-Json -Depth 40) | ConvertFrom-Json
$unsafeManifest.Artifacts[0].RelativePath = '..\escape.jsonl'
$rejected = Test-V07SoakArtifact -SoakArtifact $unsafeManifest -MeasurementArtifact $synth
Assert-SoakTest -Name 'out-of-root artifact path fails closed' -Condition (-not $rejected.Valid)

$schedule = Get-V07SoakDefaultSchedule -DurationHours 8.0
$scheduleCheck = Test-V07SoakSchedule -Schedule $schedule -DurationHours 8.0
Assert-SoakTest -Name 'default schedule contains three bounded operator observations' -Condition ($scheduleCheck.Valid -and $schedule.Count -eq 3)

Write-Host "Issue #39 soak producer tests: $passCount passed of $testCount."
