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
Assert-SoakTest -Name 'live observer wait is bounded and cancellable' -Condition (
    ($producerText -notmatch '(?im)Start-Process[^\r\n]*-Wait') -and
    $producerText.Contains('$process.HasExited') -and
    $producerText.Contains('$process.Kill()') -and
    $producerText.Contains('V07SoakObserverGraceSeconds')
)
Assert-SoakTest -Name 'live producer hard-ceils DurationHours at exactly eight hours' -Condition ($producerText.Contains('$DurationHours -ne 8.0') -and $producerText.Contains('hard ceiling'))

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

$shortHeartbeat = ($soak | ConvertTo-Json -Depth 40) | ConvertFrom-Json
$shortHeartbeat.Provenance.HeartbeatEntries = @($shortHeartbeat.Provenance.HeartbeatEntries | Select-Object -First 2)
$shortHeartbeat.Provenance.ExpectedHeartbeatCount = 2
$shortHeartbeat.Provenance.FirstHeartbeatUtc = [string]$shortHeartbeat.Provenance.HeartbeatEntries[0].ObservedUtc
$shortHeartbeat.Provenance.LastHeartbeatUtc = [string]$shortHeartbeat.Provenance.HeartbeatEntries[-1].ObservedUtc
$shortHeartbeat.Provenance.HeartbeatChainHeadSha256 = [string]$shortHeartbeat.Provenance.HeartbeatEntries[-1].EntrySha256
$rejected = Test-V07SoakArtifact -SoakArtifact $shortHeartbeat -MeasurementArtifact $synth
Assert-SoakTest -Name 'two early heartbeat entries cannot satisfy an eight-hour soak' -Condition (-not $rejected.Valid)

$identityTampered = ($soak | ConvertTo-Json -Depth 40) | ConvertFrom-Json
$identityTampered.Provenance.HeartbeatEntries[3].HerdrProcessId = 99999
$rejected = Test-V07SoakArtifact -SoakArtifact $identityTampered -MeasurementArtifact $synth
Assert-SoakTest -Name 'heartbeat PID tampering fails against the admitted Herdr identity' -Condition (-not $rejected.Valid)

$observerTampered = ($soak | ConvertTo-Json -Depth 40) | ConvertFrom-Json
$observerTampered.Producer.ObserverExecutableSha256 = ('0' * 64)
$rejected = Test-V07SoakArtifact -SoakArtifact $observerTampered -MeasurementArtifact $synth
Assert-SoakTest -Name 'observer executable SHA tampering fails candidate binding' -Condition (-not $rejected.Valid)

$scheduleTampered = ($soak | ConvertTo-Json -Depth 40) | ConvertFrom-Json
$scheduleTampered.Producer.FaultSchedule[0].Kind = 'ForgedKind'
$rejected = Test-V07SoakArtifact -SoakArtifact $scheduleTampered -MeasurementArtifact $synth
Assert-SoakTest -Name 'fault kind tampering fails immutable schedule binding' -Condition (-not $rejected.Valid)

$earlyFault = ($soak | ConvertTo-Json -Depth 40) | ConvertFrom-Json
$earlyFault.Provenance.FaultObservations[0].ObservedUtc = '2020-01-01T01:59:59Z'
$rejected = Test-V07SoakArtifact -SoakArtifact $earlyFault -MeasurementArtifact $synth
Assert-SoakTest -Name 'early operator fault observation fails closed' -Condition (-not $rejected.Valid)

$markerRoot = Join-Path $root ('artifacts\runtime-evidence\v0.7\issue-39\selftest-marker-' + [Guid]::NewGuid().ToString('N'))
try {
    $operatorRoot = Join-Path $markerRoot 'operator-observations'
    New-Item -ItemType Directory -Path $operatorRoot -Force | Out-Null
    $context = [pscustomobject][ordered]@{
        SchemaVersion = 'v0.7.0-soak-context'; ArtifactKind = 'SoakContext'; RunId = 'selftest'
        StartedUtc = '2020-01-01T00:00:00Z'; DurationHours = 8.0; CandidateSourceCommit = [string]$synth.Candidate.SourceCommit; CandidateSourceTree = [string]$synth.Candidate.SourceTree
        Schedule = @([pscustomobject][ordered]@{ Id = 'FAULT-01'; Kind = 'TargetHerdrRestartObservation'; OffsetSeconds = 7200; Instruction = 'selftest'; DueUtc = '2020-01-01T02:00:00Z' })
    }
    [IO.File]::WriteAllText((Join-Path $markerRoot 'soak-context.json'), ($context | ConvertTo-Json -Depth 20), (New-Object System.Text.UTF8Encoding($false)))
    $evidencePath = Join-Path $markerRoot 'operator-evidence.json'
    [IO.File]::WriteAllText($evidencePath, 'original', (New-Object System.Text.UTF8Encoding($false)))
    $contextSha = Get-V07Sha256Hex -Path (Join-Path $markerRoot 'soak-context.json')
    $marker = [pscustomobject][ordered]@{
        SchemaVersion = 'v0.7.0-soak-operator-observation'; ScheduleId = 'FAULT-01'; Kind = 'TargetHerdrRestartObservation'; ScheduledOffsetSeconds = 7200
        DueUtc = '2020-01-01T02:00:00Z'; ObservedUtc = '2020-01-01T01:59:59Z'; OperatorAcknowledged = $true; EvidencePath = $evidencePath
        EvidenceSha256 = Get-V07Sha256Hex -Path $evidencePath; Note = 'selftest'; ScheduleContextSha256 = $contextSha
    }
    $markerPath = Join-Path $operatorRoot 'FAULT-01.json'
    [IO.File]::WriteAllText($markerPath, ($marker | ConvertTo-Json -Depth 10), (New-Object System.Text.UTF8Encoding($false)))
    $scheduleEntry = $context.Schedule[0]
    $markerRejected = $false
    try { Read-V07SoakOperatorObservation -ObservationPath $markerPath -ExpectedId 'FAULT-01' -EvidenceRoot $markerRoot -ExpectedSchedule $scheduleEntry -SoakStartedUtc ([DateTimeOffset]::Parse('2020-01-01T00:00:00Z')) | Out-Null } catch { $markerRejected = $true }
    Assert-SoakTest -Name 'operator marker rejects ObservedUtc before DueUtc' -Condition $markerRejected

    $marker.ObservedUtc = '2020-01-01T02:00:01Z'
    [IO.File]::WriteAllText($markerPath, ($marker | ConvertTo-Json -Depth 10), (New-Object System.Text.UTF8Encoding($false)))
    [IO.File]::WriteAllText($evidencePath, 'tampered', (New-Object System.Text.UTF8Encoding($false)))
    $markerRejected = $false
    try { Read-V07SoakOperatorObservation -ObservationPath $markerPath -ExpectedId 'FAULT-01' -EvidenceRoot $markerRoot -ExpectedSchedule $scheduleEntry -SoakStartedUtc ([DateTimeOffset]::Parse('2020-01-01T00:00:00Z')) | Out-Null } catch { $markerRejected = $true }
    Assert-SoakTest -Name 'operator marker rehash rejects tampered referenced evidence' -Condition $markerRejected
} finally {
    if (Test-Path -LiteralPath $markerRoot) { [IO.Directory]::Delete($markerRoot, $true) }
}

Write-Host "Issue #39 soak producer tests: $passCount passed of $testCount."
