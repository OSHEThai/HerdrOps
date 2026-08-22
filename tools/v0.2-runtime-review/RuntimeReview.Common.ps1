Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# This helper is deliberately independent from the v0.2 matrix publisher.  It
# consumes already-held runtime evidence and never turns that evidence into
# Runtime, Human, or Release authority.
. (Join-Path $PSScriptRoot '..\lib\V02ReferenceHostProfile.ps1')

$script:V02RuntimeReviewMaximumFileBytes = [int64]16777216
$script:V02RuntimeReviewMaximumDirectoryBytes = [int64]67108864
$script:V02RuntimeReviewMaximumDirectoryFiles = 512
$script:V02RuntimeReviewMaximumJsonBytes = [int64]16777216
$script:V02RuntimeReviewIssueSet = @(7, 9, 10, 11, 149)
$script:V02RuntimeReviewGateFiles = @('gate-report.txt', 'app-runtime.json', 'core-runtime.json', 'app-progress.json', 'app-progress.json.history.jsonl')

function Assert-V02RuntimeReviewCondition {
    param([Parameter(Mandatory)][bool]$Condition, [Parameter(Mandatory)][string]$Message)
    if (-not $Condition) { throw $Message }
}

function Get-V02RuntimeReviewFullPath {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$Context)
    if ([string]::IsNullOrWhiteSpace($Path)) { throw "$Context must not be empty." }
    try { return [IO.Path]::GetFullPath($Path) } catch { throw "$Context is not a valid path: $Path" }
}

function Test-V02RuntimeReviewPathWithinOrEqual {
    param([Parameter(Mandatory)][string]$Child, [Parameter(Mandatory)][string]$Parent)
    $childFull = Get-V02RuntimeReviewFullPath $Child 'child path'
    $parentFull = Get-V02RuntimeReviewFullPath $Parent 'parent path'
    if ($childFull.Equals($parentFull, [StringComparison]::OrdinalIgnoreCase)) { return $true }
    $root = [IO.Path]::GetPathRoot($parentFull)
    if (-not $parentFull.Equals($root, [StringComparison]::OrdinalIgnoreCase)) { $parentFull = $parentFull.TrimEnd('\', '/') }
    return $childFull.StartsWith($parentFull + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)
}

function Assert-V02RuntimeReviewNoReparseComponents {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$Context)
    $full = Get-V02RuntimeReviewFullPath $Path $Context
    if (-not (Test-Path -LiteralPath $full)) { throw "$Context does not exist: $full" }
    $item = Get-Item -LiteralPath $full -Force -ErrorAction Stop
    while ($null -ne $item) {
        if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw "$Context contains a reparse-point component: $($item.FullName)"
        }
        $item = if ($item -is [IO.FileInfo]) { $item.Directory } else { $item.Parent }
    }
}

function Resolve-V02RuntimeReviewPath {
    param(
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Context,
        [ValidateSet('Leaf', 'Container')][string]$PathType = 'Leaf'
    )
    $rootFull = Get-V02RuntimeReviewFullPath $Root "$Context root"
    $full = Get-V02RuntimeReviewFullPath $Path $Context
    if (-not [IO.Path]::IsPathRooted($Path)) { throw "$Context must be absolute." }
    if (-not (Test-V02RuntimeReviewPathWithinOrEqual $full $rootFull)) { throw "$Context escaped its allowed root." }
    if (-not (Test-Path -LiteralPath $full -PathType $PathType)) { throw "$Context is missing or has wrong type: $full" }
    Assert-V02RuntimeReviewNoReparseComponents $full $Context
    return $full
}

function Get-V02RuntimeReviewHash {
    param([Parameter(Mandatory)][byte[]]$Bytes)
    $sha = [Security.Cryptography.SHA256]::Create()
    try { return ([BitConverter]::ToString($sha.ComputeHash($Bytes))).Replace('-', '').ToUpperInvariant() }
    finally { $sha.Dispose() }
}

function Read-V02RuntimeReviewHeldFile {
    param(
        [Parameter(Mandatory)][string]$Path,
        [int64]$MaximumBytes = $script:V02RuntimeReviewMaximumFileBytes,
        [switch]$IncludeBytes
    )
    $full = Get-V02RuntimeReviewFullPath $Path 'held file'
    Assert-V02RuntimeReviewNoReparseComponents $full 'held file'
    if ($MaximumBytes -lt 1 -or $MaximumBytes -gt $script:V02RuntimeReviewMaximumFileBytes) { throw 'Held-file byte bound is invalid.' }
    $before = Get-Item -LiteralPath $full -Force -ErrorAction Stop
    if ([int64]$before.Length -gt $MaximumBytes) { throw "Held file exceeds its bounded read: $full" }
    $stream = $null
    $memory = New-Object IO.MemoryStream
    try {
        # FileShare.Read prevents replacement/deletion while the evidence bytes
        # are being held.  All hashes are computed from this one open handle.
        $stream = [IO.File]::Open($full, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
        $heldLength = [int64]$stream.Length
        if ($heldLength -ne [int64]$before.Length -or $heldLength -gt $MaximumBytes) { throw "Held file changed before read: $full" }
        $buffer = New-Object byte[] 65536
        while ($memory.Length -lt $heldLength) {
            $remaining = $heldLength - $memory.Length
            $requested = [int][Math]::Min([int64]$buffer.Length, $remaining)
            $read = $stream.Read($buffer, 0, $requested)
            if ($read -le 0) { throw "Held file ended during bounded read: $full" }
            $memory.Write($buffer, 0, $read)
        }
        if ($memory.Length -ne $heldLength -or $stream.Position -ne $heldLength) { throw "Held file length changed during read: $full" }
        $bytes = $memory.ToArray()
        $hash = Get-V02RuntimeReviewHash $bytes
    }
    finally {
        if ($null -ne $stream) { $stream.Dispose() }
        $memory.Dispose()
    }
    $after = Get-Item -LiteralPath $full -Force -ErrorAction Stop
    if ([int64]$after.Length -ne [int64]$before.Length -or $after.LastWriteTimeUtc.Ticks -ne $before.LastWriteTimeUtc.Ticks) {
        throw "Held file identity changed during read: $full"
    }
    Assert-V02RuntimeReviewNoReparseComponents $full 'held file after read'
    $result = [pscustomobject][ordered]@{ Path = $full; Bytes = [int64]$heldLength; Sha256 = $hash }
    if ($IncludeBytes) { $result | Add-Member -NotePropertyName Content -NotePropertyValue $bytes }
    return $result
}

function ConvertFrom-V02RuntimeReviewStrictJson {
    param([Parameter(Mandatory)][byte[]]$Bytes, [Parameter(Mandatory)][string]$Context)
    if ($Bytes.Length -gt $script:V02RuntimeReviewMaximumJsonBytes) { throw "$Context exceeds the JSON byte bound." }
    if ($Bytes.Length -ge 3 -and $Bytes[0] -eq 0xEF -and $Bytes[1] -eq 0xBB -and $Bytes[2] -eq 0xBF) { throw "$Context must be UTF-8 without BOM." }
    try { $json = (New-Object Text.UTF8Encoding($false, $true)).GetString($Bytes) } catch { throw "$Context is not strict UTF-8." }
    if ($json.IndexOf([char]0xFEFF) -ge 0) { throw "$Context contains an embedded BOM." }
    Assert-V02NoDuplicateJsonProperties -Json $json -Source $Context
    try {
        $convert = Get-Command ConvertFrom-Json -CommandType Cmdlet
        if ($convert.Parameters.ContainsKey('DateKind')) { $value = $json | ConvertFrom-Json -DateKind String } else { $value = $json | ConvertFrom-Json }
    } catch { throw "$Context is invalid JSON: $($_.Exception.Message)" }
    if ($null -eq $value -or $value -isnot [pscustomobject]) { throw "$Context JSON root must be an object." }
    return [pscustomobject][ordered]@{ Value = $value; Json = $json; Bytes = $Bytes }
}

function Read-V02RuntimeReviewStrictJsonFile {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$Context)
    $held = Read-V02RuntimeReviewHeldFile -Path $Path -IncludeBytes
    $document = ConvertFrom-V02RuntimeReviewStrictJson -Bytes $held.Content -Context $Context
    return [pscustomobject][ordered]@{ Value = $document.Value; Json = $document.Json; Bytes = $held.Bytes; Sha256 = $held.Sha256; Path = $held.Path }
}

function Assert-V02RuntimeReviewExactProperties {
    param([Parameter(Mandatory)]$Object, [Parameter(Mandatory)][string[]]$Names, [Parameter(Mandatory)][string]$Context)
    if ($null -eq $Object -or $Object -isnot [pscustomobject]) { throw "$Context must be an object." }
    $actual = @($Object.PSObject.Properties.Name | Sort-Object)
    $expected = @($Names | Sort-Object)
    if (($actual -join "`n") -cne ($expected -join "`n")) { throw "$Context has unknown, missing, or duplicate-shaped properties." }
}

function Get-V02RuntimeReviewProperty {
    param([Parameter(Mandatory)]$Object, [Parameter(Mandatory)][string]$Name, [Parameter(Mandatory)][string]$Context)
    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property) { throw "$Context is missing '$Name'." }
    return $property.Value
}

function Assert-V02RuntimeReviewString {
    param($Value, [Parameter(Mandatory)][string]$Context, [string]$Expected)
    if ($Value -isnot [string] -or [string]::IsNullOrWhiteSpace([string]$Value)) { throw "$Context must be a non-empty string." }
    if ($PSBoundParameters.ContainsKey('Expected') -and [string]$Value -cne $Expected) { throw "$Context is not '$Expected'." }
    return [string]$Value
}

function Assert-V02RuntimeReviewSha256 {
    param($Value, [Parameter(Mandatory)][string]$Context)
    $text = Assert-V02RuntimeReviewString $Value $Context
    if ($text -cnotmatch '^[0-9A-F]{64}$') { throw "$Context must be an uppercase SHA-256." }
    return $text
}

function Assert-V02RuntimeReviewGitSha {
    param($Value, [Parameter(Mandatory)][string]$Context)
    $text = Assert-V02RuntimeReviewString $Value $Context
    if ($text -cnotmatch '^[0-9a-f]{40}$') { throw "$Context must be a lowercase Git object ID." }
    return $text
}

function Assert-V02RuntimeReviewTrue {
    param($Value, [Parameter(Mandatory)][string]$Context)
    if ($Value -isnot [bool] -or -not [bool]$Value) { throw "$Context must be native JSON true." }
}

function Assert-V02RuntimeReviewFalse {
    param($Value, [Parameter(Mandatory)][string]$Context)
    if ($Value -isnot [bool] -or [bool]$Value) { throw "$Context must be native JSON false." }
}

function Assert-V02RuntimeReviewInteger {
    param($Value, [Parameter(Mandatory)][string]$Context, [int64]$Minimum = 0)
    if ($null -eq $Value) { throw "$Context must be an integer." }
    $typeCode = [Type]::GetTypeCode($Value.GetType())
    $integerTypes = @([TypeCode]::Byte, [TypeCode]::SByte, [TypeCode]::UInt16, [TypeCode]::UInt32, [TypeCode]::UInt64, [TypeCode]::Int16, [TypeCode]::Int32, [TypeCode]::Int64)
    if ($integerTypes -notcontains $typeCode -or [int64]$Value -lt $Minimum) { throw "$Context must be a bounded native integer." }
    return [int64]$Value
}

function Normalize-V02RuntimeReviewIdentity {
    param([Parameter(Mandatory)][string]$Identity, [Parameter(Mandatory)][string]$Context)
    $value = $Identity.Trim()
    if ([string]::IsNullOrWhiteSpace($value) -or $value.Length -gt 128) { throw "$Context is empty or too long." }
    foreach ($character in $value.ToCharArray()) { if ([char]::IsControl($character) -or [char]::IsWhiteSpace($character)) { throw "$Context contains whitespace/control characters." } }
    return $value
}

function Assert-V02RuntimeReviewRoleDistinct {
    param([Parameter(Mandatory)][string]$BuilderIdentity, [Parameter(Mandatory)][string]$RuntimeOperatorIdentity, [Parameter(Mandatory)][string]$MatrixProducerIdentity, [Parameter(Mandatory)][string]$RuntimeReviewerIdentity)
    $builder = Normalize-V02RuntimeReviewIdentity $BuilderIdentity 'BuilderIdentity'
    $operator = Normalize-V02RuntimeReviewIdentity $RuntimeOperatorIdentity 'RuntimeOperatorIdentity'
    $producer = Normalize-V02RuntimeReviewIdentity $MatrixProducerIdentity 'MatrixProducerIdentity'
    $reviewer = Normalize-V02RuntimeReviewIdentity $RuntimeReviewerIdentity 'RuntimeReviewerIdentity'
    foreach ($other in @(@('builder', $builder), @('runtime operator', $operator), @('matrix producer', $producer))) {
        if ([StringComparer]::OrdinalIgnoreCase.Equals($reviewer, [string]$other[1])) { throw "RuntimeReviewerIdentity must be distinct from the $($other[0]) identity (case-insensitive)." }
    }
    return [pscustomobject][ordered]@{ Builder = $builder; RuntimeOperator = $operator; MatrixProducer = $producer; RuntimeReviewer = $reviewer }
}

function Assert-V02RuntimeReviewSourceExact {
    param([Parameter(Mandatory)][string]$RepositoryRoot, [Parameter(Mandatory)][string]$ExpectedSourceCommit, [Parameter(Mandatory)][string]$ExpectedSourceTree)
    $root = [IO.Path]::GetFullPath($RepositoryRoot)
    $commit = @(& git -C $root rev-parse HEAD 2>&1); $commitExit = $LASTEXITCODE; $global:LASTEXITCODE = 0
    $tree = @(& git -C $root rev-parse 'HEAD^{tree}' 2>&1); $treeExit = $LASTEXITCODE; $global:LASTEXITCODE = 0
    $status = @(& git -C $root status --porcelain=v1 --untracked-files=all 2>&1); $statusExit = $LASTEXITCODE; $global:LASTEXITCODE = 0
    if ($commitExit -ne 0 -or $treeExit -ne 0 -or $statusExit -ne 0 -or $commit.Count -ne 1 -or $tree.Count -ne 1 -or $status.Count -ne 0) { throw 'Source checkout is not a clean, uniquely observed Git state.' }
    if ([string]$commit[0] -cne $ExpectedSourceCommit -or [string]$tree[0] -cne $ExpectedSourceTree) { throw 'Source commit/tree changed during runtime-review validation.' }
}

function Get-V02RuntimeReviewGateMap {
    param([Parameter(Mandatory)][string]$Path)
    $held = Read-V02RuntimeReviewHeldFile $Path -MaximumBytes 1048576 -IncludeBytes
    try { $text = (New-Object Text.UTF8Encoding($false, $true)).GetString($held.Content) } catch { throw "Gate report is not strict UTF-8: $Path" }
    $recognized = @('ExpectedSourceCommit','ExpectedSourceTree','SourceCommit','SourceTree','PreRunSourceCommit','PreRunSourceTree','PreRunGitTreeClean','PostRunSourceCommit','PostRunSourceTree','PostRunGitTreeClean','Result','EvidenceClass','SessionControlInvoked','AcceptanceControlSession','TargetAgentLabSession','AcceptanceControlSocketPath','TargetAgentLabSocketPath','SeparateSessionSockets','AcceptanceControlServerIdentity','TargetAgentSessionReference','HerdrReleaseId','PackageIdentityPath','PackageIdentityFileSha256','PackageIdentityReceiptSha256','PackageArchivePath','PackageArchiveSha256','ExtractedPackageRoot','PackageManifestPath','PackageManifestSha256','PackageProfileId','PackageValidationEvidenceClass','AppSha256','CoreSha256','HerdrExecutableSha256','BundledSchemaSha256','HerdrProtocol','ReferenceHostProfileId','ReferenceHostProfileSha256','ReferenceHostSchemaSha256','Language','RendererPolicyId','WpfProcessRenderMode','SoftwareOnlyThroughout','SnapshotObserved','EventObserved','ReconnectObserved','CoreAcceptedEventKindCheck','SemanticCaptureBindingCheck','AppRuntimeReportSha256','CoreRuntimeReportSha256','TrxSelectionReceiptPath','TrxSelectionReceiptSha256','ProgressHistoryPath','ProgressHistorySha256','ProgressHistoryLastEntrySha256','CaptureDirectory')
    $map = @{}
    foreach ($line in ($text -split "`r?`n")) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        if ($line -notmatch '^([^:]{1,128}):[ ]?(.*)$') { continue }
        $name = [string]$matches[1]
        if ($recognized -notcontains $name) { continue }
        if ($map.ContainsKey($name)) { throw "Gate report contains duplicate field '$name'." }
        $map[$name] = [string]$matches[2]
    }
    return [pscustomobject][ordered]@{ Values = $map; Sha256 = $held.Sha256; Bytes = $held.Bytes; Path = $held.Path }
}

function Get-V02RuntimeReviewGateValue {
    param([Parameter(Mandatory)]$Gate, [Parameter(Mandatory)][string]$Name, [Parameter(Mandatory)][string]$Context)
    if (-not $Gate.Values.ContainsKey($Name) -or [string]::IsNullOrWhiteSpace([string]$Gate.Values[$Name])) { throw "$Context gate report is missing '$Name'." }
    return [string]$Gate.Values[$Name]
}

function Assert-V02RuntimeReviewGate {
    param([Parameter(Mandatory)]$Gate, [Parameter(Mandatory)][ValidateSet('Thai', 'English')][string]$Language, [Parameter(Mandatory)][string]$ExpectedSourceCommit, [Parameter(Mandatory)][string]$ExpectedSourceTree)
    $context = "$Language runtime gate"
    foreach ($name in @('ExpectedSourceCommit','SourceCommit','PreRunSourceCommit','PostRunSourceCommit')) { $null = Get-V02RuntimeReviewGateValue $Gate $name $context; Assert-V02RuntimeReviewGitSha (Get-V02RuntimeReviewGateValue $Gate $name $context) "$context $name" | Out-Null }
    foreach ($name in @('ExpectedSourceTree','SourceTree','PreRunSourceTree','PostRunSourceTree')) { $null = Get-V02RuntimeReviewGateValue $Gate $name $context; Assert-V02RuntimeReviewGitSha (Get-V02RuntimeReviewGateValue $Gate $name $context) "$context $name" | Out-Null }
    foreach ($name in @('ExpectedSourceCommit','SourceCommit','PreRunSourceCommit','PostRunSourceCommit')) { if ((Get-V02RuntimeReviewGateValue $Gate $name $context) -cne $ExpectedSourceCommit) { throw "$context $name does not bind to the expected source commit." } }
    foreach ($name in @('ExpectedSourceTree','SourceTree','PreRunSourceTree','PostRunSourceTree')) { if ((Get-V02RuntimeReviewGateValue $Gate $name $context) -cne $ExpectedSourceTree) { throw "$context $name does not bind to the expected source tree." } }
    foreach ($pair in @(@('Result', 'PASS'), @('EvidenceClass', 'Runtime'), @('PreRunGitTreeClean', 'True'), @('PostRunGitTreeClean', 'True'), @('SessionControlInvoked', 'false'), @('Language', $Language), @('RendererPolicyId', 'software-only-process-wide'), @('WpfProcessRenderMode', 'SoftwareOnly'), @('SoftwareOnlyThroughout', 'True'), @('SeparateSessionSockets', 'true'))) {
        if ((Get-V02RuntimeReviewGateValue $Gate $pair[0] $context) -cne [string]$pair[1]) { throw "$context $($pair[0]) is not the required value." }
    }
    foreach ($name in @('AcceptanceControlSession','TargetAgentLabSession','AcceptanceControlSocketPath','TargetAgentLabSocketPath','AcceptanceControlServerIdentity','TargetAgentSessionReference','HerdrReleaseId','PackageIdentityPath','PackageArchivePath','ExtractedPackageRoot','PackageManifestPath','PackageProfileId','PackageValidationEvidenceClass','TrxSelectionReceiptPath','ProgressHistoryPath','CaptureDirectory')) { Assert-V02RuntimeReviewString (Get-V02RuntimeReviewGateValue $Gate $name $context) "$context $name" | Out-Null }
    $controlSocket = Get-V02RuntimeReviewGateValue $Gate 'AcceptanceControlSocketPath' $context
    $targetSocket = Get-V02RuntimeReviewGateValue $Gate 'TargetAgentLabSocketPath' $context
    if ($controlSocket.Equals($targetSocket, [StringComparison]::OrdinalIgnoreCase)) { throw "$context control and target sockets are not distinct." }
    if ((Get-V02RuntimeReviewGateValue $Gate 'AcceptanceControlSession' $context).Equals((Get-V02RuntimeReviewGateValue $Gate 'TargetAgentLabSession' $context), [StringComparison]::OrdinalIgnoreCase)) { throw "$context control and target sessions are not distinct." }
    foreach ($name in @('PackageIdentityFileSha256','PackageIdentityReceiptSha256','PackageArchiveSha256','PackageManifestSha256','AppSha256','CoreSha256','HerdrExecutableSha256','BundledSchemaSha256','ReferenceHostProfileSha256','AppRuntimeReportSha256','CoreRuntimeReportSha256','TrxSelectionReceiptSha256','ProgressHistorySha256','ProgressHistoryLastEntrySha256')) { Assert-V02RuntimeReviewSha256 (Get-V02RuntimeReviewGateValue $Gate $name $context) "$context $name" | Out-Null }
    foreach ($name in @('SnapshotObserved','EventObserved','ReconnectObserved','CoreAcceptedEventKindCheck','SemanticCaptureBindingCheck')) {
        $value = Get-V02RuntimeReviewGateValue $Gate $name $context
        if ($name -in @('SnapshotObserved','EventObserved','ReconnectObserved')) { if ($value -cne 'True') { throw "$context $name does not prove the semantic event." } }
        elseif ($value -match '(?i)NOT[_ -]?OBSERVED|NOT[_ -]?EVALUATED|FAIL') { throw "$context $name is not an observed passing semantic check." }
    }
    return $Gate
}

function Assert-V02RuntimeReviewEvent {
    param([Parameter(Mandatory)]$Event, [Parameter(Mandatory)][string]$Context)
    if ($null -eq $Event -or $Event -isnot [pscustomobject]) { throw "$Context must be a semantic event object." }
    foreach ($name in @('AdmissionPath','CurrentStateSha256','BaselineSequence','CurrentSequence','BaselineEventCount','CurrentEventCount','Changes')) { $null = Get-V02RuntimeReviewProperty $Event $name $Context }
    Assert-V02RuntimeReviewString $Event.AdmissionPath "$Context admission path" | Out-Null
    Assert-V02RuntimeReviewSha256 $Event.CurrentStateSha256 "$Context state hash" | Out-Null
    Assert-V02RuntimeReviewInteger $Event.BaselineSequence "$Context baseline sequence" | Out-Null
    Assert-V02RuntimeReviewInteger $Event.CurrentSequence "$Context current sequence" | Out-Null
    Assert-V02RuntimeReviewInteger $Event.BaselineEventCount "$Context baseline event count" | Out-Null
    Assert-V02RuntimeReviewInteger $Event.CurrentEventCount "$Context current event count" | Out-Null
    if ([int64]$Event.CurrentSequence -le [int64]$Event.BaselineSequence -or [int64]$Event.CurrentEventCount -le [int64]$Event.BaselineEventCount) { throw "$Context does not show an event transition." }
    if (@($Event.Changes).Count -lt 1) { throw "$Context has no semantic change payload." }
}

function Assert-V02RuntimeReviewReports {
    param([Parameter(Mandatory)]$Gate, [Parameter(Mandatory)][string]$EvidenceDirectory, [Parameter(Mandatory)][ValidateSet('Thai', 'English')][string]$Language)
    $context = "$Language runtime evidence"
    $appPath = Resolve-V02RuntimeReviewPath $EvidenceDirectory (Join-Path $EvidenceDirectory 'app-runtime.json') "$context App report"
    $corePath = Resolve-V02RuntimeReviewPath $EvidenceDirectory (Join-Path $EvidenceDirectory 'core-runtime.json') "$context Core report"
    $appDoc = Read-V02RuntimeReviewStrictJsonFile $appPath "$context App report"
    $coreDoc = Read-V02RuntimeReviewStrictJsonFile $corePath "$context Core report"
    $app = $appDoc.Value; $core = $coreDoc.Value
    foreach ($pair in @(@($app, 'EvidenceClassification', 'RuntimeCandidate'), @($app, 'Language', $Language), @($app, 'FinalLanguage', $Language), @($core, 'EvidenceClassification', 'Runtime'))) {
        if ((Get-V02RuntimeReviewProperty $pair[0] $pair[1] $context) -cne $pair[2]) { throw "$context $($pair[1]) is not bound to $($pair[2])." }
    }
    foreach ($name in @('LanguageStableThroughFinish','CompositeCandidateChecksPassed','CoreStateObserved','UpdateObservedBeforeDashboardClose','DashboardClosed','UpdateObservedAfterDashboardClose','CoreConnectedAfterDashboardClose','DisconnectObservedAfterDashboardClose','ReconnectObservedAfterDashboardClose')) { Assert-V02RuntimeReviewTrue (Get-V02RuntimeReviewProperty $app $name $context) "$context App.$name" }
    Assert-V02RuntimeReviewFalse (Get-V02RuntimeReviewProperty $app 'SessionControlInvoked' $context) "$context App.SessionControlInvoked"
    $languageChanges = Assert-V02RuntimeReviewInteger (Get-V02RuntimeReviewProperty $app 'LanguageChangeCount' $context) "$context App.LanguageChangeCount"
    if ($languageChanges -ne 0) { throw "$context App language changed during the run." }
    foreach ($name in @('RuntimeObserved','SnapshotObserved','EventObserved','ReconnectObserved','CompletionSignalObserved')) { Assert-V02RuntimeReviewTrue (Get-V02RuntimeReviewProperty $core $name $context) "$context Core.$name" }
    Assert-V02RuntimeReviewFalse (Get-V02RuntimeReviewProperty $core 'SessionControlInvoked' $context) "$context Core.SessionControlInvoked"
    if ([string](Get-V02RuntimeReviewProperty $app 'ProfileId' $context) -cne (Get-V02RuntimeReviewGateValue $Gate 'ReferenceHostProfileId' $context) -or [string](Get-V02RuntimeReviewProperty $app 'ProfileSha256' $context) -cne (Get-V02RuntimeReviewGateValue $Gate 'ReferenceHostProfileSha256' $context)) { throw "$context App reference-host profile is not gate-bound." }
    $admission = Get-V02RuntimeReviewProperty $core 'Admission' $context
    foreach ($name in @('ReleaseId','ExecutableSha256','BundledSchemaSha256','Protocol')) { $null = Get-V02RuntimeReviewProperty $admission $name "$context Core.Admission" }
    Assert-V02RuntimeReviewSha256 $admission.ExecutableSha256 "$context Herdr executable" | Out-Null
    Assert-V02RuntimeReviewSha256 $admission.BundledSchemaSha256 "$context bundled schema" | Out-Null
    Assert-V02RuntimeReviewInteger $admission.Protocol "$context protocol" | Out-Null
    foreach ($pair in @(@('HerdrReleaseId', [string]$admission.ReleaseId), @('HerdrExecutableSha256', [string]$admission.ExecutableSha256), @('BundledSchemaSha256', [string]$admission.BundledSchemaSha256), @('HerdrProtocol', [string]$admission.Protocol))) { if ((Get-V02RuntimeReviewGateValue $Gate $pair[0] $context) -cne $pair[1]) { throw "$context gate $($pair[0]) is not bound to Core admission." } }
    $transitions = @((Get-V02RuntimeReviewProperty $core 'Transitions' $context))
    if ($transitions.Count -lt 4) { throw "$context Core does not contain the bounded snapshot/event/disconnect/reconnect transition set." }
    foreach ($transition in $transitions) {
        $serverIdentity = Get-V02RuntimeReviewProperty $transition 'ServerIdentity' "$context Core transition"
        foreach ($name in @('ProcessId','ProcessStartUtc','ExecutablePath','ExecutableSha256')) { $null = Get-V02RuntimeReviewProperty $serverIdentity $name "$context Core transition identity" }
        Assert-V02RuntimeReviewInteger $serverIdentity.ProcessId "$context Core transition PID" 1 | Out-Null
        Assert-V02RuntimeReviewString $serverIdentity.ProcessStartUtc "$context Core transition start" | Out-Null
        Assert-V02RuntimeReviewString $serverIdentity.ExecutablePath "$context Core transition executable" | Out-Null
        Assert-V02RuntimeReviewSha256 $serverIdentity.ExecutableSha256 "$context Core transition executable hash" | Out-Null
    }
    $null = Assert-V02RuntimeReviewEvent $app.EventA "$context App.EventA"
    $null = Assert-V02RuntimeReviewEvent $app.EventB "$context App.EventB"
    $captures = @((Get-V02RuntimeReviewProperty $app 'Captures' $context))
    if ($captures.Count -ne 8) { throw "$context must contain exactly eight runtime captures." }
    $captureHashes = @{}
    foreach ($capture in $captures) {
        $name = Assert-V02RuntimeReviewString (Get-V02RuntimeReviewProperty $capture 'Name' $context) "$context capture name"
        if ($captureHashes.ContainsKey($name)) { throw "$context contains duplicate capture '$name'." }
        if ((Get-V02RuntimeReviewProperty $capture 'Language' $context) -cne $Language) { throw "$context capture language mismatch." }
        $capturePath = Resolve-V02RuntimeReviewPath $EvidenceDirectory (Get-V02RuntimeReviewProperty $capture 'Path' $context) "$context capture '$name'"
        $declared = Assert-V02RuntimeReviewSha256 (Get-V02RuntimeReviewProperty $capture 'Sha256' $context) "$context capture '$name' hash"
        $actual = Read-V02RuntimeReviewHeldFile $capturePath
        if ($actual.Sha256 -cne $declared) { throw "$context capture '$name' bytes do not match its declared hash." }
        $captureHashes[$name] = [pscustomobject][ordered]@{ Name = $name; Path = $capturePath; Sha256 = $actual.Sha256; Bytes = $actual.Bytes }
    }
    $declaredAppHash = Assert-V02RuntimeReviewSha256 (Get-V02RuntimeReviewGateValue $Gate 'AppRuntimeReportSha256' $context) "$context gate App hash"
    $declaredCoreHash = Assert-V02RuntimeReviewSha256 (Get-V02RuntimeReviewGateValue $Gate 'CoreRuntimeReportSha256' $context) "$context gate Core hash"
    if ($declaredAppHash -cne $appDoc.Sha256 -or $declaredCoreHash -cne $coreDoc.Sha256) { throw "$context gate report hashes do not match held App/Core reports." }
    $selectionPath = Resolve-V02RuntimeReviewPath $EvidenceDirectory (Get-V02RuntimeReviewGateValue $Gate 'TrxSelectionReceiptPath' $context) "$context TRX selection receipt"
    $selection = Read-V02RuntimeReviewHeldFile $selectionPath
    if ($selection.Sha256 -cne (Get-V02RuntimeReviewGateValue $Gate 'TrxSelectionReceiptSha256' $context)) { throw "$context TRX selection receipt hash is not bound." }
    $historyPath = Resolve-V02RuntimeReviewPath $EvidenceDirectory (Get-V02RuntimeReviewGateValue $Gate 'ProgressHistoryPath' $context) "$context progress history"
    if (-not $historyPath.Equals((Join-Path $EvidenceDirectory 'app-progress.json.history.jsonl'), [StringComparison]::OrdinalIgnoreCase)) { throw "$context progress history is not the canonical held file." }
    $history = Read-V02RuntimeReviewHeldFile $historyPath
    if ($history.Sha256 -cne (Get-V02RuntimeReviewGateValue $Gate 'ProgressHistorySha256' $context)) { throw "$context progress history hash is not bound." }
    $captureDirectory = Resolve-V02RuntimeReviewPath $EvidenceDirectory (Get-V02RuntimeReviewGateValue $Gate 'CaptureDirectory' $context) "$context capture directory" 'Container'
    $firstCapturePath = [string]$captureHashes[[string]@($captureHashes.Keys)[0]].Path
    $captureRoot = Split-Path -Parent $firstCapturePath
    if (-not $captureRoot.Equals($captureDirectory, [StringComparison]::OrdinalIgnoreCase)) { throw "$context capture directory is not the real capture root." }
    return [pscustomobject][ordered]@{ Language = $Language; EvidenceDirectory = [IO.Path]::GetFullPath($EvidenceDirectory); CaptureRoot = $captureRoot; Gate = $Gate; GateReportSha256 = $Gate.Sha256; AppRuntimeReportSha256 = $appDoc.Sha256; CoreRuntimeReportSha256 = $coreDoc.Sha256; ProgressHistorySha256 = $history.Sha256; AppRuntimeReportBytes = $appDoc.Bytes; CoreRuntimeReportBytes = $coreDoc.Bytes; App = $app; Core = $core; Captures = @($captureHashes.Values | Sort-Object Name) }
}

function Get-V02RuntimeReviewDirectoryInventory {
    param([Parameter(Mandatory)][string]$EvidenceDirectory)
    $root = Resolve-V02RuntimeReviewPath $EvidenceDirectory $EvidenceDirectory 'runtime evidence directory' 'Container'
    $items = @(Get-ChildItem -LiteralPath $root -Recurse -Force -File | Sort-Object FullName)
    if ($items.Count -gt $script:V02RuntimeReviewMaximumDirectoryFiles) { throw 'Runtime evidence directory contains too many files.' }
    $entries = @(); $total = [int64]0
    foreach ($item in $items) {
        Assert-V02RuntimeReviewNoReparseComponents $item.FullName 'runtime evidence inventory item'
        $relative = $item.FullName.Substring($root.Length).TrimStart('\', '/') -replace '\\', '/'
        $allowed = $script:V02RuntimeReviewGateFiles -contains $relative -or $relative.StartsWith('captures/', [StringComparison]::OrdinalIgnoreCase) -or $relative.StartsWith('test-results/', [StringComparison]::OrdinalIgnoreCase)
        if (-not $allowed) { throw "Runtime evidence contains an unexpected file: $relative" }
        $stable = Read-V02RuntimeReviewHeldFile $item.FullName
        $total += $stable.Bytes
        if ($total -gt $script:V02RuntimeReviewMaximumDirectoryBytes) { throw 'Runtime evidence directory exceeds the aggregate byte bound.' }
        $entries += [pscustomobject][ordered]@{ Path = $relative; Bytes = $stable.Bytes; Sha256 = $stable.Sha256 }
    }
    foreach ($required in $script:V02RuntimeReviewGateFiles) { if (-not ($entries.Path -contains $required)) { throw "Runtime evidence is missing required file: $required" } }
    return @($entries)
}

function Assert-V02RuntimeReviewPackage {
    param([Parameter(Mandatory)][string]$IdentityPath, [Parameter(Mandatory)][string]$ArchivePath, [Parameter(Mandatory)][string]$ExtractedPackageRoot, [Parameter(Mandatory)][string]$ExpectedSourceCommit, [Parameter(Mandatory)][string]$ExpectedSourceTree, [string]$RepositoryRoot, [switch]$FixtureMode)
    $identityFull = Get-V02RuntimeReviewFullPath $IdentityPath 'PackageIdentityPath'
    $archiveFull = Get-V02RuntimeReviewFullPath $ArchivePath 'PackageArchivePath'
    $rootFull = Get-V02RuntimeReviewFullPath $ExtractedPackageRoot 'ExtractedPackageRoot'
    Assert-V02RuntimeReviewNoReparseComponents $identityFull 'package identity'
    Assert-V02RuntimeReviewNoReparseComponents $archiveFull 'package archive'
    Assert-V02RuntimeReviewNoReparseComponents $rootFull 'extracted package root'
    if (-not (Test-Path -LiteralPath $identityFull -PathType Leaf) -or -not (Test-Path -LiteralPath $archiveFull -PathType Leaf) -or -not (Test-Path -LiteralPath $rootFull -PathType Container)) { throw 'Package inputs are incomplete.' }
    if (-not $FixtureMode) {
        if ([string]::IsNullOrWhiteSpace($RepositoryRoot)) { throw 'RepositoryRoot is required for production package validation.' }
        $validator = Join-Path ([IO.Path]::GetFullPath($RepositoryRoot)) 'tools\packaging\v0.2\Test-V02PackageIdentity.ps1'
        $profile = Join-Path ([IO.Path]::GetFullPath($RepositoryRoot)) 'tools\packaging\v0.2\package-identity-profile.json'
        if (-not (Test-Path -LiteralPath $validator -PathType Leaf) -or -not (Test-Path -LiteralPath $profile -PathType Leaf)) { throw 'Committed package validator/profile is missing.' }
        $validation = @(& $validator -IdentityPath $identityFull -ArchivePath $archiveFull -PackageRoot $rootFull -RepositoryRoot ([IO.Path]::GetFullPath($RepositoryRoot)) -ProfilePath $profile)
        if ($validation.Count -ne 1) { throw 'Committed package validator did not return exactly one result.' }
    }
    $identityDoc = Read-V02RuntimeReviewStrictJsonFile $identityFull 'package identity receipt'
    $identity = $identityDoc.Value
    Assert-V02RuntimeReviewExactProperties $identity @('schemaVersion','profileId','issue','packageVersion','runtimeIdentifier','source','profile','archive','packageManifest','components','referenceHost','renderer','evidenceBoundary') 'package identity receipt'
    if ([int64](Assert-V02RuntimeReviewInteger $identity.schemaVersion 'package schemaVersion') -ne 1 -or [int64](Assert-V02RuntimeReviewInteger $identity.issue 'package issue') -ne 149) { throw 'Package identity schema/issue is not v0.2 Issue 149.' }
    foreach ($pair in @(@('profileId','herdrops-v0.2-package-software-only-issue-149'), @('packageVersion','0.2.0'), @('runtimeIdentifier','win-x64'))) { Assert-V02RuntimeReviewString $identity.($pair[0]) "package $($pair[0])" $pair[1] | Out-Null }
    Assert-V02RuntimeReviewGitSha $identity.source.commitSha 'package source commit' | Out-Null; Assert-V02RuntimeReviewGitSha $identity.source.treeSha 'package source tree' | Out-Null
    if ([string]$identity.source.commitSha -cne $ExpectedSourceCommit -or [string]$identity.source.treeSha -cne $ExpectedSourceTree) { throw 'Package source binding does not match the expected source.' }
    $canonical = ConvertTo-V02Jcs $identity
    $receiptSha = Get-V02RuntimeReviewHash ([Text.UTF8Encoding]::new($false).GetBytes($canonical))
    if ($receiptSha -cne $identityDoc.Sha256 -and -not $FixtureMode) { throw 'Package receipt file hash is not its canonical receipt hash.' }
    $archive = Read-V02RuntimeReviewHeldFile $archiveFull
    $manifestPath = Join-Path $rootFull 'package-manifest.json'
    $appPath = Join-Path $rootFull 'HerdrOps.App.exe'
    $corePath = Join-Path $rootFull 'HerdrOps.Core.exe'
    foreach ($path in @($manifestPath, $appPath, $corePath)) { Assert-V02RuntimeReviewNoReparseComponents $path 'package extracted file'; if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "Required extracted package file is missing: $path" } }
    $manifest = Read-V02RuntimeReviewHeldFile $manifestPath; $app = Read-V02RuntimeReviewHeldFile $appPath; $core = Read-V02RuntimeReviewHeldFile $corePath
    foreach ($pair in @(@($identity.archive, $archive, 'archive'), @($identity.packageManifest, $manifest, 'manifest'), @($identity.components.app, $app, 'App'), @($identity.components.core, $core, 'Core'))) {
        if ([int64]$pair[0].bytes -ne [int64]$pair[1].Bytes -or [string]$pair[0].sha256 -cne [string]$pair[1].Sha256) { throw "Package $($pair[2]) bytes/hash do not match the held artifact." }
    }
    return [pscustomobject][ordered]@{ IdentityPath = $identityFull; IdentityFileSha256 = $identityDoc.Sha256; ReceiptSha256 = $receiptSha; ArchivePath = $archiveFull; ArchiveSha256 = $archive.Sha256; ManifestPath = $manifestPath; ManifestSha256 = $manifest.Sha256; AppPath = $appPath; AppSha256 = $app.Sha256; CorePath = $corePath; CoreSha256 = $core.Sha256; SourceCommit = [string]$identity.source.commitSha; SourceTree = [string]$identity.source.treeSha; ProfileId = [string]$identity.profileId }
}

function Assert-V02RuntimeReviewMatrixCandidate {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)]$Thai, [Parameter(Mandatory)]$English, [Parameter(Mandatory)]$Package, [Parameter(Mandatory)][string]$ExpectedSourceCommit, [Parameter(Mandatory)][string]$ExpectedSourceTree)
    $doc = Read-V02RuntimeReviewStrictJsonFile $Path 'language-matrix candidate'
    Assert-V02RuntimeReviewExactProperties $doc.Value @('EvidenceClassification','IndependentHumanReview','ReleaseCredit','ManifestFormatVersion','ManifestHashScope','ManifestPayloadSha256','Payload') 'language-matrix candidate'
    $candidate = $doc.Value
    Assert-V02RuntimeReviewString $candidate.EvidenceClassification 'matrix classification' 'RuntimeMatrixCandidate' | Out-Null; Assert-V02RuntimeReviewString $candidate.IndependentHumanReview 'matrix human review' 'NOT_OBSERVED' | Out-Null; Assert-V02RuntimeReviewFalse $candidate.ReleaseCredit 'matrix release credit'
    if ([int64](Assert-V02RuntimeReviewInteger $candidate.ManifestFormatVersion 'matrix format') -ne 1) { throw 'Matrix manifest format is not 1.' }
    Assert-V02RuntimeReviewString $candidate.ManifestHashScope 'matrix hash scope' 'SHA256OfRFC8785JcsUtf8NoBomPayload' | Out-Null
    $payload = $candidate.Payload
    Assert-V02RuntimeReviewExactProperties $payload @('GeneratedUnixTimeMilliseconds','IndependentHumanReview','ReleaseCredit','Binding','Runs') 'matrix payload'
    Assert-V02RuntimeReviewInteger $payload.GeneratedUnixTimeMilliseconds 'matrix generated timestamp' | Out-Null
    Assert-V02RuntimeReviewString $payload.IndependentHumanReview 'matrix payload human review' 'NOT_OBSERVED' | Out-Null; Assert-V02RuntimeReviewFalse $payload.ReleaseCredit 'matrix payload release credit'
    $binding = Get-V02RuntimeReviewProperty $payload 'Binding' 'matrix payload'
    Assert-V02RuntimeReviewExactProperties $binding @('SourceCommit','SourceTree','ProfileId','ProfileSha256','ReferenceHostSchemaSha256','PackageIdentityReceiptSha256','HerdrReleaseId','HerdrExecutableSha256','AppExecutableSha256','CoreExecutableSha256','BundledSchemaSha256','HerdrProtocol') 'matrix payload binding'
    if ([string]$binding.SourceCommit -cne $ExpectedSourceCommit -or [string]$binding.SourceTree -cne $ExpectedSourceTree -or [string]$binding.PackageIdentityReceiptSha256 -cne $Package.ReceiptSha256 -or [string]$binding.AppExecutableSha256 -cne $Package.AppSha256 -or [string]$binding.CoreExecutableSha256 -cne $Package.CoreSha256) { throw 'Matrix payload binding is stale or does not match the package/source.' }
    foreach ($name in @('ProfileSha256','ReferenceHostSchemaSha256','HerdrExecutableSha256','AppExecutableSha256','CoreExecutableSha256','BundledSchemaSha256')) { Assert-V02RuntimeReviewSha256 (Get-V02RuntimeReviewProperty $binding $name 'matrix payload binding') "matrix binding $name" | Out-Null }
    $payloadCanonical = ConvertTo-V02Jcs $payload
    $payloadHash = Get-V02RuntimeReviewHash ([Text.UTF8Encoding]::new($false).GetBytes($payloadCanonical))
    if ($payloadHash -cne (Assert-V02RuntimeReviewSha256 $candidate.ManifestPayloadSha256 'matrix payload hash')) { throw 'Matrix payload hash is not bound to the held payload.' }
    $runs = @($payload.Runs); if ($runs.Count -ne 2) { throw 'Matrix candidate must contain exactly Thai and English runs.' }
    $byLanguage = @{}
    foreach ($run in $runs) { $language = Assert-V02RuntimeReviewString $run.Language 'matrix run language'; if ($byLanguage.ContainsKey($language)) { throw 'Matrix candidate contains duplicate language legs.' }; $byLanguage[$language] = $run }
    foreach ($expected in @(@('Thai', $Thai), @('English', $English))) {
        $language = [string]$expected[0]; if (-not $byLanguage.ContainsKey($language)) { throw "Matrix candidate is missing $language." }; $run = $byLanguage[$language]; $actual = $expected[1]
        foreach ($name in @('EvidenceDirectory','CaptureRoot','GateReportSha256','AppRuntimeReportSha256','CoreRuntimeReportSha256','ProgressHistorySha256','PackageIdentityReceiptSha256','SourceCommit','SourceTree','ProfileId','ProfileSha256','ReferenceHostSchemaSha256','HerdrReleaseId','HerdrExecutableSha256','AppExecutableSha256','CoreExecutableSha256','BundledSchemaSha256','HerdrProtocol','RendererPolicyId','WpfProcessRenderMode','CaptureCount','Captures')) { $null = Get-V02RuntimeReviewProperty $run $name "matrix $language run" }
        if ([string]$run.EvidenceDirectory -cne $actual.EvidenceDirectory -or [string]$run.CaptureRoot -cne $actual.CaptureRoot -or [string]$run.GateReportSha256 -cne $actual.GateReportSha256 -or [string]$run.AppRuntimeReportSha256 -cne $actual.AppRuntimeReportSha256 -or [string]$run.CoreRuntimeReportSha256 -cne $actual.CoreRuntimeReportSha256 -or [string]$run.ProgressHistorySha256 -cne $actual.ProgressHistorySha256 -or [string]$run.SourceCommit -cne $ExpectedSourceCommit -or [string]$run.SourceTree -cne $ExpectedSourceTree -or [string]$run.ProfileId -cne [string]$actual.App.ProfileId -or [string]$run.ProfileSha256 -cne [string]$actual.App.ProfileSha256) { throw "Matrix $language run is not bound to held runtime evidence/source." }
        if ([string]$run.PackageIdentityReceiptSha256 -cne $Package.ReceiptSha256) { throw "Matrix $language run is not bound to the package receipt." }
        if ([int64]$run.CaptureCount -ne 8) { throw "Matrix $language capture count is not eight." }
    }
    return [pscustomobject][ordered]@{ Path = $doc.Path; FileSha256 = $doc.Sha256; PayloadSha256 = $payloadHash; Value = $candidate }
}

function Publish-V02RuntimeReviewNoClobber {
    param([Parameter(Mandatory)][string]$AllowedRoot, [Parameter(Mandatory)][string]$OutputPath, [Parameter(Mandatory)][string]$Json)
    $root = Resolve-V02RuntimeReviewPath $AllowedRoot $AllowedRoot 'output allowed root' 'Container'
    $full = Get-V02RuntimeReviewFullPath $OutputPath 'OutputPath'
    $parent = [IO.Path]::GetDirectoryName($full)
    if ([string]::IsNullOrWhiteSpace($parent) -or -not (Test-V02RuntimeReviewPathWithinOrEqual $parent $root) -or $full.Equals($root, [StringComparison]::OrdinalIgnoreCase)) { throw 'OutputPath must be a new file below the allowed root.' }
    if (-not (Test-Path -LiteralPath $parent -PathType Container)) { throw 'Output parent does not exist.' }
    Assert-V02RuntimeReviewNoReparseComponents $parent 'output parent'
    if (Test-Path -LiteralPath $full) { throw "OutputPath already exists: $full" }
    $bytes = [Text.UTF8Encoding]::new($false).GetBytes($Json + "`n")
    if ($bytes.Length -gt $script:V02RuntimeReviewMaximumJsonBytes) { throw 'Output exceeds the bounded JSON size.' }
    $temporary = Join-Path $parent ('.' + [IO.Path]::GetFileName($full) + '.' + [Guid]::NewGuid().ToString('N') + '.tmp')
    $stream = $null
    try {
        $stream = [IO.File]::Open($temporary, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
        $stream.Write($bytes, 0, $bytes.Length); $stream.Flush($true); $stream.Dispose(); $stream = $null
        Assert-V02RuntimeReviewNoReparseComponents $parent 'output parent before publish'
        if (Test-Path -LiteralPath $full) { throw 'OutputPath appeared during atomic publication.' }
        [IO.File]::Move($temporary, $full)
    }
    catch { if ($null -ne $stream) { $stream.Dispose() }; if ([IO.File]::Exists($temporary)) { [IO.File]::Delete($temporary) }; throw }
    $published = Read-V02RuntimeReviewHeldFile $full
    return [pscustomobject][ordered]@{ Path = $full; Bytes = $published.Bytes; Sha256 = $published.Sha256 }
}

function Invoke-V02RuntimeReviewVerification {
    param(
        [Parameter(Mandatory)][string]$ThaiEvidenceDirectory,
        [Parameter(Mandatory)][string]$EnglishEvidenceDirectory,
        [Parameter(Mandatory)][string]$MatrixCandidatePath,
        [Parameter(Mandatory)][string]$PackageIdentityPath,
        [Parameter(Mandatory)][string]$PackageArchivePath,
        [Parameter(Mandatory)][string]$ExtractedPackageRoot,
        [Parameter(Mandatory)][string]$RepositoryRoot,
        [Parameter(Mandatory)][string]$ExpectedSourceCommit,
        [Parameter(Mandatory)][string]$ExpectedSourceTree,
        [Parameter(Mandatory)][string]$OutputPath,
        [Parameter(Mandatory)][string]$BuilderIdentity,
        [Parameter(Mandatory)][string]$RuntimeOperatorIdentity,
        [Parameter(Mandatory)][string]$MatrixProducerIdentity,
        [Parameter(Mandatory)][string]$RuntimeReviewerIdentity,
        [switch]$FixtureMode
    )
    Assert-V02RuntimeReviewGitSha $ExpectedSourceCommit 'ExpectedSourceCommit' | Out-Null; Assert-V02RuntimeReviewGitSha $ExpectedSourceTree 'ExpectedSourceTree' | Out-Null
    if (-not $FixtureMode) { Assert-V02RuntimeReviewSourceExact $RepositoryRoot $ExpectedSourceCommit $ExpectedSourceTree }
    $roles = Assert-V02RuntimeReviewRoleDistinct $BuilderIdentity $RuntimeOperatorIdentity $MatrixProducerIdentity $RuntimeReviewerIdentity
    $thaiRoot = Resolve-V02RuntimeReviewPath $ThaiEvidenceDirectory $ThaiEvidenceDirectory 'Thai evidence directory' 'Container'
    $englishRoot = Resolve-V02RuntimeReviewPath $EnglishEvidenceDirectory $EnglishEvidenceDirectory 'English evidence directory' 'Container'
    if ((Test-V02RuntimeReviewPathWithinOrEqual $thaiRoot $englishRoot) -or (Test-V02RuntimeReviewPathWithinOrEqual $englishRoot $thaiRoot)) { throw 'Thai and English evidence trees must be disjoint.' }
    $package = Assert-V02RuntimeReviewPackage $PackageIdentityPath $PackageArchivePath $ExtractedPackageRoot $ExpectedSourceCommit $ExpectedSourceTree $RepositoryRoot -FixtureMode:$FixtureMode
    $thaiGate = Get-V02RuntimeReviewGateMap (Join-Path $thaiRoot 'gate-report.txt'); $englishGate = Get-V02RuntimeReviewGateMap (Join-Path $englishRoot 'gate-report.txt')
    Assert-V02RuntimeReviewGate $thaiGate 'Thai' $ExpectedSourceCommit $ExpectedSourceTree | Out-Null; Assert-V02RuntimeReviewGate $englishGate 'English' $ExpectedSourceCommit $ExpectedSourceTree | Out-Null
    $thai = Assert-V02RuntimeReviewReports $thaiGate $thaiRoot 'Thai'; $english = Assert-V02RuntimeReviewReports $englishGate $englishRoot 'English'
    foreach ($pair in @(@('Thai/English package receipt', $thaiGate, $englishGate, 'PackageIdentityReceiptSha256'), @('Thai/English package archive', $thaiGate, $englishGate, 'PackageArchiveSha256'), @('Thai/English package manifest', $thaiGate, $englishGate, 'PackageManifestSha256'), @('Thai/English package App', $thaiGate, $englishGate, 'AppSha256'), @('Thai/English package Core', $thaiGate, $englishGate, 'CoreSha256'), @('Thai/English Herdr', $thaiGate, $englishGate, 'HerdrExecutableSha256'), @('Thai/English schema', $thaiGate, $englishGate, 'BundledSchemaSha256'))) { if ((Get-V02RuntimeReviewGateValue $pair[1] $pair[3] $pair[0]) -cne (Get-V02RuntimeReviewGateValue $pair[2] $pair[3] $pair[0])) { throw "$($pair[0]) is not identical." } }
    foreach ($name in @('AcceptanceControlSession','TargetAgentLabSession','AcceptanceControlSocketPath','TargetAgentLabSocketPath','TargetAgentSessionReference','AcceptanceControlServerIdentity')) { if ((Get-V02RuntimeReviewGateValue $thaiGate $name 'Thai session') -cne (Get-V02RuntimeReviewGateValue $englishGate $name 'English session')) { throw "Thai and English $name identities are not exact." } }
    foreach ($pair in @(@('PackageIdentityPath', $package.IdentityPath), @('PackageArchivePath', $package.ArchivePath), @('ExtractedPackageRoot', $ExtractedPackageRoot), @('PackageManifestPath', $package.ManifestPath))) {
        foreach ($gate in @($thaiGate, $englishGate)) { if ([IO.Path]::GetFullPath((Get-V02RuntimeReviewGateValue $gate $pair[0] 'package gate')) -cne [IO.Path]::GetFullPath([string]$pair[1])) { throw "Gate $($pair[0]) is not the real accepted package path." } }
    }
    foreach ($pair in @(@('PackageIdentityFileSha256', $package.IdentityFileSha256), @('PackageIdentityReceiptSha256', $package.ReceiptSha256), @('PackageArchiveSha256', $package.ArchiveSha256), @('PackageManifestSha256', $package.ManifestSha256), @('AppSha256', $package.AppSha256), @('CoreSha256', $package.CoreSha256))) {
        foreach ($gate in @($thaiGate, $englishGate)) { if ((Get-V02RuntimeReviewGateValue $gate $pair[0] 'package gate') -cne [string]$pair[1]) { throw "Gate $($pair[0]) is not bound to the held package bytes." } }
    }
    if ((Test-V02RuntimeReviewPathWithinOrEqual $thai.CaptureRoot $english.CaptureRoot) -or (Test-V02RuntimeReviewPathWithinOrEqual $english.CaptureRoot $thai.CaptureRoot)) { throw 'Thai and English capture roots must be disjoint.' }
    $matrix = Assert-V02RuntimeReviewMatrixCandidate $MatrixCandidatePath $thai $english $package $ExpectedSourceCommit $ExpectedSourceTree
    $thaiInventory = Get-V02RuntimeReviewDirectoryInventory $thaiRoot; $englishInventory = Get-V02RuntimeReviewDirectoryInventory $englishRoot
    $binding = [pscustomobject][ordered]@{ SourceCommit = $ExpectedSourceCommit; SourceTree = $ExpectedSourceTree; PackageIdentityReceiptSha256 = $package.ReceiptSha256; PackageIdentityFileSha256 = $package.IdentityFileSha256; PackageArchiveSha256 = $package.ArchiveSha256; PackageManifestSha256 = $package.ManifestSha256; AppSha256 = $package.AppSha256; CoreSha256 = $package.CoreSha256 }
    $payload = [ordered]@{ SchemaVersion = 1; EvidenceClassification = 'IndependentReviewCandidate'; Result = 'PASS'; Issues = @($script:V02RuntimeReviewIssueSet); Source = [ordered]@{ CommitSha = $ExpectedSourceCommit; TreeSha = $ExpectedSourceTree; GitTreeClean = $true }; Package = [ordered]@{ IdentityPath = $package.IdentityPath; IdentityFileSha256 = $package.IdentityFileSha256; ReceiptSha256 = $package.ReceiptSha256; ArchivePath = $package.ArchivePath; ArchiveSha256 = $package.ArchiveSha256; ManifestPath = $package.ManifestPath; ManifestSha256 = $package.ManifestSha256; AppPath = $package.AppPath; AppSha256 = $package.AppSha256; CorePath = $package.CorePath; CoreSha256 = $package.CoreSha256 }; Roles = [ordered]@{ BuilderIdentity = $roles.Builder; RuntimeOperatorIdentity = $roles.RuntimeOperator; MatrixProducerIdentity = $roles.MatrixProducer; RuntimeReviewerIdentity = $roles.RuntimeReviewer; ReviewerDistinctCaseInsensitive = $true }; Herdr = [ordered]@{ ReleaseId = (Get-V02RuntimeReviewGateValue $thaiGate 'HerdrReleaseId' 'Thai gate'); ExecutableSha256 = (Get-V02RuntimeReviewGateValue $thaiGate 'HerdrExecutableSha256' 'Thai gate'); BundledSchemaSha256 = (Get-V02RuntimeReviewGateValue $thaiGate 'BundledSchemaSha256' 'Thai gate'); Protocol = (Get-V02RuntimeReviewGateValue $thaiGate 'HerdrProtocol' 'Thai gate') }; Sessions = [ordered]@{ Control = [ordered]@{ Name = (Get-V02RuntimeReviewGateValue $thaiGate 'AcceptanceControlSession' 'Thai gate'); SocketPath = (Get-V02RuntimeReviewGateValue $thaiGate 'AcceptanceControlSocketPath' 'Thai gate'); ServerIdentity = (Get-V02RuntimeReviewGateValue $thaiGate 'AcceptanceControlServerIdentity' 'Thai gate') }; Target = [ordered]@{ Name = (Get-V02RuntimeReviewGateValue $thaiGate 'TargetAgentLabSession' 'Thai gate'); SocketPath = (Get-V02RuntimeReviewGateValue $thaiGate 'TargetAgentLabSocketPath' 'Thai gate'); Reference = (Get-V02RuntimeReviewGateValue $thaiGate 'TargetAgentSessionReference' 'Thai gate') } }; MatrixCandidate = [ordered]@{ Path = $matrix.Path; FileSha256 = $matrix.FileSha256; PayloadSha256 = $matrix.PayloadSha256; EvidenceClassification = 'RuntimeMatrixCandidate'; IndependentHumanReview = 'NOT_OBSERVED'; ReleaseCredit = $false }; Languages = @([ordered]@{ Language = 'Thai'; EvidenceDirectory = $thai.EvidenceDirectory; CaptureRoot = $thai.CaptureRoot; GateReportSha256 = $thai.GateReportSha256; AppRuntimeReportSha256 = $thai.AppRuntimeReportSha256; CoreRuntimeReportSha256 = $thai.CoreRuntimeReportSha256; Files = @($thaiInventory) }, [ordered]@{ Language = 'English'; EvidenceDirectory = $english.EvidenceDirectory; CaptureRoot = $english.CaptureRoot; GateReportSha256 = $english.GateReportSha256; AppRuntimeReportSha256 = $english.AppRuntimeReportSha256; CoreRuntimeReportSha256 = $english.CoreRuntimeReportSha256; Files = @($englishInventory) }); EvidenceBoundary = [ordered]@{ IndependentReview = 'NOT_OBSERVED'; ExternalReviewerAttestation = 'NOT_PROVIDED'; HumanVisualGo = 'NOT_OBSERVED'; RuntimeCredit = $false; ReleaseCredit = $false; OutputAuthority = 'IndependentReviewCandidate'; NoCallerAuthoredAuthority = $true } }
    if (-not $FixtureMode) { Assert-V02RuntimeReviewSourceExact $RepositoryRoot $ExpectedSourceCommit $ExpectedSourceTree }
    $json = ConvertTo-V02Jcs ($payload | ConvertTo-Json -Depth 50 | ConvertFrom-Json)
    $rootForOutput = [IO.Path]::GetDirectoryName($thaiRoot)
    if ((Test-V02RuntimeReviewPathWithinOrEqual $OutputPath $thaiRoot) -or (Test-V02RuntimeReviewPathWithinOrEqual $OutputPath $englishRoot)) { throw 'OutputPath must not be inside a runtime evidence tree.' }
    $published = Publish-V02RuntimeReviewNoClobber $rootForOutput $OutputPath $json
    if (-not $FixtureMode) { Assert-V02RuntimeReviewSourceExact $RepositoryRoot $ExpectedSourceCommit $ExpectedSourceTree }
    return [pscustomobject][ordered]@{ Path = $published.Path; Sha256 = $published.Sha256; Bytes = $published.Bytes; EvidenceClassification = 'IndependentReviewCandidate'; Result = 'PASS' }
}
