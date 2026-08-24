Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '..\lib\V02ReferenceHostProfile.ps1')
. (Join-Path $PSScriptRoot '..\lib\V02GateProvenance.ps1')

$script:I9MaximumFileBytes = [int64]16777216
$script:I9MaximumEvidenceBytes = [int64]67108864
$script:I9MaximumUiFiles = 64
$script:I9MaximumAgeMinutes = 120
$script:I9ExpectedPages = @('Overview', 'LiveOrganization', 'AgentDetail')
$script:I9ExpectedLanguages = @('Thai', 'English')

function Assert-I9 {
    param([Parameter(Mandatory)][bool]$Condition, [Parameter(Mandatory)][string]$Message)
    if (-not $Condition) { throw $Message }
}

function Get-I9FullPath {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$Context)
    if ([string]::IsNullOrWhiteSpace($Path)) { throw "$Context is empty." }
    try { return [IO.Path]::GetFullPath($Path) } catch { throw "$Context is not a valid path: $Path" }
}

function Test-I9Within {
    param([Parameter(Mandatory)][string]$Child, [Parameter(Mandatory)][string]$Parent)
    $childFull = Get-I9FullPath $Child 'child path'; $parentFull = Get-I9FullPath $Parent 'parent path'
    if ($childFull.Equals($parentFull, [StringComparison]::OrdinalIgnoreCase)) { return $true }
    $root = [IO.Path]::GetPathRoot($parentFull)
    if (-not $parentFull.Equals($root, [StringComparison]::OrdinalIgnoreCase)) { $parentFull = $parentFull.TrimEnd('\', '/') }
    return $childFull.StartsWith($parentFull + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)
}

function Assert-I9NoReparse {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$Context)
    $full = Get-I9FullPath $Path $Context
    if (-not (Test-Path -LiteralPath $full)) { throw "$Context does not exist: $full" }
    $item = Get-Item -LiteralPath $full -Force -ErrorAction Stop
    while ($null -ne $item) {
        if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw "$Context contains a reparse point: $($item.FullName)" }
        $item = if ($item -is [IO.FileInfo]) { $item.Directory } else { $item.Parent }
    }
}

function Resolve-I9Path {
    param([Parameter(Mandatory)][string]$Root, [Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$Context, [ValidateSet('Leaf','Container')][string]$PathType = 'Leaf')
    if (-not [IO.Path]::IsPathRooted($Path)) { throw "$Context must be absolute." }
    $rootFull = Get-I9FullPath $Root "$Context root"; $full = Get-I9FullPath $Path $Context
    if (-not (Test-I9Within $full $rootFull)) { throw "$Context escaped its allowed root." }
    if (-not (Test-Path -LiteralPath $full -PathType $PathType)) { throw "$Context is missing or has wrong type: $full" }
    Assert-I9NoReparse $full $Context
    return $full
}

function Get-I9Hash {
    param([Parameter(Mandatory)][byte[]]$Bytes)
    $sha = [Security.Cryptography.SHA256]::Create()
    try { return ([BitConverter]::ToString($sha.ComputeHash($Bytes))).Replace('-', '').ToUpperInvariant() } finally { $sha.Dispose() }
}

function Read-I9HeldFile {
    param([Parameter(Mandatory)][string]$Path, [int64]$MaximumBytes = $script:I9MaximumFileBytes, [switch]$IncludeBytes)
    $full = Get-I9FullPath $Path 'held file'; Assert-I9NoReparse $full 'held file'
    $before = Get-Item -LiteralPath $full -Force -ErrorAction Stop
    if ([int64]$before.Length -gt $MaximumBytes) { throw "Held file exceeds the bound: $full" }
    $stream = $null; $memory = New-Object IO.MemoryStream
    try {
        # One held read with FileShare.Read blocks replacement/deletion during
        # hashing; the post-read identity check closes the path TOCTOU window.
        $stream = [IO.File]::Open($full, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
        $identityBefore = Get-V02FileInformation -FileStream $stream
        if ([uint32]$identityBefore.NumberOfLinks -ne 1) { throw "Held file must have exactly one link; hardlink/path alias rejected: $full" }
        $length = [int64]$stream.Length
        if ($length -ne [int64]$before.Length -or $length -gt $MaximumBytes) { throw "Held file changed before reading: $full" }
        $buffer = New-Object byte[] 65536
        while ($memory.Length -lt $length) {
            $remaining = $length - $memory.Length; $requested = [int][Math]::Min([int64]$buffer.Length, $remaining)
            $read = $stream.Read($buffer, 0, $requested)
            if ($read -le 0) { throw "Held file ended during read: $full" }
            $memory.Write($buffer, 0, $read)
        }
        if ($memory.Length -ne $length) { throw "Held file length changed during read: $full" }
        $bytes = $memory.ToArray(); $hash = Get-I9Hash $bytes
        $identityAfter = Get-V02FileInformation -FileStream $stream
        Assert-V02FileIdentityContinuity -BaselineInfo $identityBefore -CurrentInfo $identityAfter -Context 'Issue #9 held file'
        if ([uint32]$identityAfter.NumberOfLinks -ne 1) { throw "Held file link count changed or is non-singular: $full" }
    } finally { if ($null -ne $stream) { $stream.Dispose() }; $memory.Dispose() }
    $after = Get-Item -LiteralPath $full -Force -ErrorAction Stop
    if ([int64]$after.Length -ne [int64]$before.Length -or $after.LastWriteTimeUtc.Ticks -ne $before.LastWriteTimeUtc.Ticks) { throw "Held file identity changed during read: $full" }
    Assert-I9NoReparse $full 'held file after read'
    $result = [pscustomobject][ordered]@{ Path = $full; Bytes = $length; Sha256 = $hash; VolumeSerialNumber = [uint32]$identityAfter.VolumeSerialNumber; FileId = [uint64]$identityAfter.FileIndex; LinkCount = [uint32]$identityAfter.NumberOfLinks }
    if ($IncludeBytes) { $result | Add-Member -NotePropertyName Content -NotePropertyValue $bytes }
    return $result
}

function Assert-I9Png {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$Context)
    $held = Read-I9HeldFile $Path -MaximumBytes $script:I9MaximumEvidenceBytes -IncludeBytes
    $signature = [byte[]](0x89,0x50,0x4E,0x47,0x0D,0x0A,0x1A,0x0A)
    if ($held.Content.Length -lt $signature.Length) { throw "$Context is not a PNG: signature is missing." }
    for ($index = 0; $index -lt $signature.Length; $index++) {
        if ($held.Content[$index] -ne $signature[$index]) { throw "$Context is not a PNG: signature mismatch." }
    }
    try {
        Add-Type -AssemblyName PresentationCore -ErrorAction Stop
        $memory = [IO.MemoryStream]::new($held.Content, $false)
        try {
            $decoder = [Windows.Media.Imaging.PngBitmapDecoder]::new(
                $memory,
                [Windows.Media.Imaging.BitmapCreateOptions]::PreservePixelFormat,
                [Windows.Media.Imaging.BitmapCacheOption]::OnLoad)
            if ($decoder.Frames.Count -ne 1) { throw "$Context must decode to exactly one PNG frame." }
            $frame = $decoder.Frames[0]
            if ($frame.PixelWidth -le 0 -or $frame.PixelHeight -le 0) { throw "$Context decoded dimensions are invalid." }
            # Force a full pixel decode so a valid header with corrupt image data is rejected.
            $stride = [Math]::Max(1, [int](($frame.PixelWidth * $frame.Format.BitsPerPixel + 7) / 8))
            $pixels = New-Object byte[] ([int]($stride * $frame.PixelHeight))
            $frame.CopyPixels($pixels, $stride, 0)
            return [pscustomobject][ordered]@{ Path=$held.Path; Bytes=$held.Bytes; Sha256=$held.Sha256; PixelWidth=[int]$frame.PixelWidth; PixelHeight=[int]$frame.PixelHeight; FileId=$held.FileId; LinkCount=$held.LinkCount }
        } finally { $memory.Dispose() }
    } catch {
        if ($_.Exception.Message -match '^.+must decode|^.+decoded dimensions') { throw }
        throw "$Context failed PNG decoding: $($_.Exception.Message)"
    }
}

function ConvertTo-I9Utc {
    param($Value, [Parameter(Mandatory)][string]$Context)
    if ($Value -isnot [string] -or [string]$Value -cnotmatch '(?:Z|\+00:00)$') { throw "$Context must be an explicit UTC timestamp ending in Z or +00:00." }
    $parsed = [DateTimeOffset]::MinValue
    if (-not [DateTimeOffset]::TryParse([string]$Value,[Globalization.CultureInfo]::InvariantCulture,[Globalization.DateTimeStyles]::RoundtripKind,[ref]$parsed) -or $parsed.Offset -ne [TimeSpan]::Zero) { throw "$Context is not a valid UTC timestamp." }
    return $parsed.ToUniversalTime()
}

function Get-I9RedactedIdentity {
    param([Parameter(Mandatory)][string]$Kind,[Parameter(Mandatory)][string]$Value)
    return Get-I9Hash ([Text.UTF8Encoding]::new($false).GetBytes($Kind + [char]0 + $Value))
}

function Read-I9Json {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$Context)
    $held = Read-I9HeldFile $Path -IncludeBytes
    if ($held.Bytes -gt $script:I9MaximumFileBytes) { throw "$Context exceeds the JSON bound." }
    if ($held.Content.Length -ge 3 -and $held.Content[0] -eq 0xEF -and $held.Content[1] -eq 0xBB -and $held.Content[2] -eq 0xBF) { throw "$Context must be UTF-8 without BOM." }
    try { $json = (New-Object Text.UTF8Encoding($false, $true)).GetString($held.Content) } catch { throw "$Context is not strict UTF-8." }
    Assert-V02NoDuplicateJsonProperties -Json $json -Source $Context
    try {
        $cmd = Get-Command ConvertFrom-Json -CommandType Cmdlet
        if ($cmd.Parameters.ContainsKey('DateKind')) { $value = $json | ConvertFrom-Json -DateKind String } else { $value = $json | ConvertFrom-Json }
    } catch { throw "$Context is invalid JSON: $($_.Exception.Message)" }
    if ($null -eq $value -or $value -isnot [pscustomobject]) { throw "$Context JSON root must be an object." }
    return [pscustomobject][ordered]@{ Value = $value; Json = $json; Bytes = $held.Bytes; Sha256 = $held.Sha256; Path = $held.Path }
}

function Assert-I9ExactProperties {
    param([Parameter(Mandatory)]$Object, [Parameter(Mandatory)][string[]]$Names, [Parameter(Mandatory)][string]$Context)
    if ($null -eq $Object -or $Object -isnot [pscustomobject]) { throw "$Context must be an object." }
    $actual = @($Object.PSObject.Properties.Name | Sort-Object); $expected = @($Names | Sort-Object)
    if (($actual -join "`n") -cne ($expected -join "`n")) { throw "$Context has unknown or missing properties." }
}

function ConvertFrom-I9NativeSessionReference {
    param([Parameter(Mandatory)][string]$Reference,[Parameter(Mandatory)][string]$Context)
    try { $native=$Reference|ConvertFrom-Json } catch { throw "$Context is not structured Herdr CLI JSON." }
    Assert-I9ExactProperties $native @('agent','kind','source','value') $Context
    foreach($name in @('agent','kind','source','value')){Assert-I9String $native.PSObject.Properties[$name].Value "$Context $name"|Out-Null}
    if([string]$native.kind-cne'id'-or[string]$native.source-cne"herdr:$([string]$native.agent)"){throw "$Context does not bind Herdr CLI native Agent metadata."}
    $canonical=[pscustomobject][ordered]@{agent=[string]$native.agent;kind=[string]$native.kind;source=[string]$native.source;value=[string]$native.value}|ConvertTo-Json -Compress
    if($Reference-cne$canonical){throw "$Context is not the exact canonical Herdr CLI metadata form."}
    return $native
}

function Get-I9Prop {
    param([Parameter(Mandatory)]$Object, [Parameter(Mandatory)][string]$Name, [Parameter(Mandatory)][string]$Context)
    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property) { throw "$Context is missing '$Name'." }
    return $property.Value
}

function Assert-I9String {
    param($Value, [Parameter(Mandatory)][string]$Context, [string]$Expected)
    if ($Value -isnot [string] -or [string]::IsNullOrWhiteSpace([string]$Value)) { throw "$Context must be non-empty text." }
    if ($PSBoundParameters.ContainsKey('Expected') -and [string]$Value -cne $Expected) { throw "$Context is not '$Expected'." }
    return [string]$Value
}

function Assert-I9Sha {
    param($Value, [Parameter(Mandatory)][string]$Context)
    $text = Assert-I9String $Value $Context
    if ($text -cnotmatch '^[0-9A-F]{64}$') { throw "$Context is not an uppercase SHA-256." }
    return $text
}

function Assert-I9GitSha {
    param($Value, [Parameter(Mandatory)][string]$Context)
    $text = Assert-I9String $Value $Context
    if ($text -cnotmatch '^[0-9a-f]{40}$') { throw "$Context is not a lowercase Git object ID." }
    return $text
}

function Assert-I9RunNonce {
    param($Value, [Parameter(Mandatory)][string]$Context)
    $text = Assert-I9String $Value $Context
    if ($text -cnotmatch '^[0-9a-f]{32}$') { throw "$Context must be a lowercase 32-hex invocation nonce." }
    return $text
}

function Assert-I9True { param($Value, [Parameter(Mandatory)][string]$Context); if ($Value -isnot [bool] -or -not [bool]$Value) { throw "$Context must be native true." } }
function Assert-I9False { param($Value, [Parameter(Mandatory)][string]$Context); if ($Value -isnot [bool] -or [bool]$Value) { throw "$Context must be native false." } }

function Get-I9GateMap {
    param([Parameter(Mandatory)][string]$Path)
    $held = Read-I9HeldFile $Path -MaximumBytes 1048576 -IncludeBytes
    try { $text = (New-Object Text.UTF8Encoding($false, $true)).GetString($held.Content) } catch { throw "Gate report is not UTF-8: $Path" }
    $known = @('RunNonce','GeneratedUtc','ExpectedSourceCommit','ExpectedSourceTree','SourceCommit','SourceTree','PreRunSourceCommit','PreRunSourceTree','PreRunGitTreeClean','PostRunSourceCommit','PostRunSourceTree','PostRunGitTreeClean','Result','EvidenceClass','SessionControlInvoked','AcceptanceControlSession','TargetAgentLabSession','AcceptanceControlSocketPath','TargetAgentLabSocketPath','SeparateSessionSockets','AcceptanceControlServerIdentity','TargetAgentSessionReference','TargetAgentSessionReferenceEvidenceSource','TargetAgentSessionReferenceObservableByGate','TargetAgentSessionReferenceBoundary','PackageIdentityPath','PackageIdentityFileSha256','PackageIdentityReceiptSha256','PackageArchivePath','PackageArchiveSha256','ExtractedPackageRoot','PackageManifestPath','PackageManifestSha256','PackageProfileId','PackageValidationEvidenceClass','AppSha256','CoreSha256','HerdrReleaseId','HerdrExecutableSha256','BundledSchemaSha256','HerdrProtocol','ReferenceHostProfileId','ReferenceHostProfileSha256','ReferenceHostSchemaSha256','Language','AppRuntimeReportSha256','CoreRuntimeReportSha256','TrxSelectionReceiptPath','TrxSelectionReceiptSha256','ProgressHistoryPath','ProgressHistorySha256','ProgressHistoryLastEntrySha256','CaptureDirectory','CoreAcceptedEventKindCheck','SemanticCaptureBindingCheck','SnapshotObserved','EventObserved','ReconnectObserved')
    $values = @{}
    foreach ($line in ($text -split "`r?`n")) {
        if ($line -notmatch '^([A-Za-z][A-Za-z0-9]*):[ ]?(.*)$') { continue }
        $name = [string]$matches[1]; if ($known -notcontains $name) { continue }
        if ($values.ContainsKey($name)) { throw "Gate report contains duplicate '$name'." }
        $values[$name] = [string]$matches[2]
    }
    return [pscustomobject][ordered]@{ Path = $held.Path; Sha256 = $held.Sha256; Values = $values }
}

function Get-I9GateValue {
    param([Parameter(Mandatory)]$Gate, [Parameter(Mandatory)][string]$Name, [Parameter(Mandatory)][string]$Context)
    if (-not $Gate.Values.ContainsKey($Name) -or [string]::IsNullOrWhiteSpace([string]$Gate.Values[$Name])) { throw "$Context gate is missing '$Name'." }
    return [string]$Gate.Values[$Name]
}

function Assert-I9Gate {
    param([Parameter(Mandatory)]$Gate, [Parameter(Mandatory)][ValidateSet('Thai','English')][string]$Language, [Parameter(Mandatory)][string]$ExpectedCommit, [Parameter(Mandatory)][string]$ExpectedTree)
    $context = "$Language runtime gate"
    $runNonce=Assert-I9RunNonce (Get-I9GateValue $Gate 'RunNonce' $context) "$context RunNonce"
    $generatedUtc = ConvertTo-I9Utc (Get-I9GateValue $Gate 'GeneratedUtc' $context) "$context GeneratedUtc"
    $now=[DateTimeOffset]::UtcNow;if($generatedUtc-gt$now-or$generatedUtc-lt$now.AddMinutes(-$script:I9MaximumAgeMinutes)){throw "$context is outside the bounded fresh review window."}
    foreach ($name in @('ExpectedSourceCommit','SourceCommit','PreRunSourceCommit','PostRunSourceCommit')) { Assert-I9GitSha (Get-I9GateValue $Gate $name $context) "$context $name" | Out-Null; if ((Get-I9GateValue $Gate $name $context) -cne $ExpectedCommit) { throw "$context $name source mismatch." } }
    foreach ($name in @('ExpectedSourceTree','SourceTree','PreRunSourceTree','PostRunSourceTree')) { Assert-I9GitSha (Get-I9GateValue $Gate $name $context) "$context $name" | Out-Null; if ((Get-I9GateValue $Gate $name $context) -cne $ExpectedTree) { throw "$context $name tree mismatch." } }
    foreach ($pair in @(@('Result','PASS'),@('EvidenceClass','Runtime'),@('PreRunGitTreeClean','True'),@('PostRunGitTreeClean','True'),@('SessionControlInvoked','false'),@('Language',$Language),@('SeparateSessionSockets','true'))) { if ((Get-I9GateValue $Gate $pair[0] $context) -cne [string]$pair[1]) { throw "$context $($pair[0]) is not required." } }
    foreach ($name in @('AcceptanceControlSession','TargetAgentLabSession','AcceptanceControlSocketPath','TargetAgentLabSocketPath','TargetAgentSessionReference','AcceptanceControlServerIdentity','PackageIdentityPath','PackageArchivePath','ExtractedPackageRoot','PackageManifestPath','PackageProfileId','PackageValidationEvidenceClass','HerdrReleaseId','ProgressHistoryPath','CaptureDirectory')) { Assert-I9String (Get-I9GateValue $Gate $name $context) "$context $name" | Out-Null }
    $null=ConvertFrom-I9NativeSessionReference (Get-I9GateValue $Gate 'TargetAgentSessionReference' $context) "$context native session"
    foreach($pair in @(@('TargetAgentSessionReferenceEvidenceSource','HerdrCliAgentMetadata'),@('TargetAgentSessionReferenceObservableByGate','true'),@('TargetAgentSessionReferenceBoundary','The gate directly observed and exact-bound the same structured native Agent session through Herdr CLI metadata before restart, at reconnect, and through completion.'))){if((Get-I9GateValue $Gate $pair[0] $context)-cne$pair[1]){throw "$context $($pair[0]) is not the required gate-observed authority."}}
    if ((Get-I9GateValue $Gate 'AcceptanceControlSession' $context) -ceq (Get-I9GateValue $Gate 'TargetAgentLabSession' $context)) { throw "$context control/target sessions are not distinct." }
    if ((Get-I9GateValue $Gate 'AcceptanceControlSocketPath' $context) -ceq (Get-I9GateValue $Gate 'TargetAgentLabSocketPath' $context)) { throw "$context control/target sockets are not distinct." }
    foreach ($name in @('PackageIdentityFileSha256','PackageIdentityReceiptSha256','PackageArchiveSha256','PackageManifestSha256','AppSha256','CoreSha256','HerdrExecutableSha256','BundledSchemaSha256','ReferenceHostProfileSha256','ReferenceHostSchemaSha256','AppRuntimeReportSha256','CoreRuntimeReportSha256','ProgressHistorySha256','ProgressHistoryLastEntrySha256')) { Assert-I9Sha (Get-I9GateValue $Gate $name $context) "$context $name" | Out-Null }
    foreach ($name in @('SnapshotObserved','EventObserved','ReconnectObserved')) { if ((Get-I9GateValue $Gate $name $context) -cne 'True') { throw "$context $name was not observed." } }
    foreach ($name in @('CoreAcceptedEventKindCheck','SemanticCaptureBindingCheck')) { if ((Get-I9GateValue $Gate $name $context) -match '(?i)NOT|FAIL') { throw "$context $name is not a passing semantic check." } }
}

function Assert-I9Package {
    param([Parameter(Mandatory)][string]$IdentityPath, [Parameter(Mandatory)][string]$ArchivePath, [Parameter(Mandatory)][string]$PackageRoot, [Parameter(Mandatory)][string]$ExpectedCommit, [Parameter(Mandatory)][string]$ExpectedTree)
    $identity = Read-I9Json $IdentityPath 'package identity'; Assert-I9ExactProperties $identity.Value @('schemaVersion','profileId','issue','packageVersion','runtimeIdentifier','source','profile','archive','packageManifest','components','referenceHost','renderer','evidenceBoundary') 'package identity'
    if ([int64]$identity.Value.issue -ne 149) { throw 'Package identity is not the accepted v0.2 package receipt.' }
    Assert-I9GitSha $identity.Value.source.commitSha 'package source commit' | Out-Null; Assert-I9GitSha $identity.Value.source.treeSha 'package source tree' | Out-Null
    if ([string]$identity.Value.source.commitSha -cne $ExpectedCommit -or [string]$identity.Value.source.treeSha -cne $ExpectedTree) { throw 'Package source binding is stale.' }
    $archive = Read-I9HeldFile $ArchivePath; $root = Get-I9FullPath $PackageRoot 'package root'; Assert-I9NoReparse $root 'package root'
    $manifestPath = Join-Path $root 'package-manifest.json'; $appPath = Join-Path $root 'HerdrOps.App.exe'; $corePath = Join-Path $root 'HerdrOps.Core.exe'
    $manifest = Read-I9HeldFile $manifestPath; $app = Read-I9HeldFile $appPath; $core = Read-I9HeldFile $corePath
    foreach ($pair in @(@($identity.Value.archive,$archive,'archive'),@($identity.Value.packageManifest,$manifest,'manifest'),@($identity.Value.components.app,$app,'App'),@($identity.Value.components.core,$core,'Core'))) { if ([int64]$pair[0].bytes -ne [int64]$pair[1].Bytes -or [string]$pair[0].sha256 -cne [string]$pair[1].Sha256) { throw "Package $($pair[2]) binding mismatch." } }
    $canonical = ConvertTo-V02Jcs $identity.Value; $receiptSha = Get-I9Hash ([Text.UTF8Encoding]::new($false).GetBytes($canonical))
    return [pscustomobject][ordered]@{ IdentityPath = $identity.Path; IdentityFileSha256 = $identity.Sha256; ReceiptSha256 = $receiptSha; ArchivePath = $archive.Path; ArchiveSha256 = $archive.Sha256; PackageRoot = $root; ManifestPath = $manifest.Path; ManifestSha256 = $manifest.Sha256; AppPath = $app.Path; AppSha256 = $app.Sha256; CorePath = $core.Path; CoreSha256 = $core.Sha256; ProfileId = [string]$identity.Value.profileId }
}

function Assert-I9RuntimeRun {
    param([Parameter(Mandatory)][string]$RuntimeRoot, [Parameter(Mandatory)][ValidateSet('Thai','English')][string]$Language, [Parameter(Mandatory)][string]$ExpectedCommit, [Parameter(Mandatory)][string]$ExpectedTree, [Parameter(Mandatory)]$Package)
    $root = Get-I9FullPath $RuntimeRoot 'runtime evidence'; Assert-I9NoReparse $root 'runtime evidence'
    $gate = Get-I9GateMap (Join-Path $root 'gate-report.txt'); Assert-I9Gate $gate $Language $ExpectedCommit $ExpectedTree
    $runNonce = Assert-I9String (Get-I9GateValue $gate 'RunNonce' "$Language gate") "$Language gate RunNonce"
    if ($runNonce -cnotmatch '^[0-9a-f]{32}$') { throw "$Language gate RunNonce is invalid." }
    $appPath = Join-Path $root 'app-runtime.json'; $corePath = Join-Path $root 'core-runtime.json'; $appDoc = Read-I9Json $appPath "$Language App report"; $coreDoc = Read-I9Json $corePath "$Language Core report"; $app = $appDoc.Value; $core = $coreDoc.Value
    Assert-I9String $app.EvidenceClassification "$Language App classification" 'RuntimeCandidate' | Out-Null; Assert-I9String $app.Language "$Language App language" $Language | Out-Null; Assert-I9String $app.FinalLanguage "$Language App final language" $Language | Out-Null; Assert-I9True $app.LanguageStableThroughFinish "$Language language stability"; Assert-I9False $app.SessionControlInvoked "$Language App session control"; if ([int64]$app.LanguageChangeCount -ne 0) { throw "$Language App language changed." }
    Assert-I9String $core.EvidenceClassification "$Language Core classification" 'Runtime' | Out-Null; foreach ($name in @('RuntimeObserved','SnapshotObserved','EventObserved','ReconnectObserved','CompletionSignalObserved')) { Assert-I9True $core.$name "$Language Core.$name" }; Assert-I9False $core.SessionControlInvoked "$Language Core session control"
    foreach ($name in @('DashboardClosed','UpdateObservedAfterDashboardClose','CoreConnectedAfterDashboardClose','DisconnectObservedAfterDashboardClose','ReconnectObservedAfterDashboardClose')) { Assert-I9True $app.$name "$Language App.$name" }
    $transitions = @($core.Transitions); if ($transitions.Count -lt 4) { throw "$Language Core transition trace is incomplete." }
    $eventA = Get-I9Prop $app 'EventA' "$Language App report"; $eventB = Get-I9Prop $app 'EventB' "$Language App report"
    foreach ($pair in @(@('EventA',$eventA),@('EventB',$eventB))) { Assert-I9Sha $pair[1].CurrentStateSha256 "$Language $($pair[0]) state" | Out-Null }
    Assert-I9Sha $app.PreCloseStateSha256 "$Language App pre-close state" | Out-Null; Assert-I9Sha $app.PostCloseStateSha256 "$Language App post-close state" | Out-Null
    if ([string]$eventA.CurrentStateSha256 -cne [string]$app.PreCloseStateSha256 -or [string]$eventB.CurrentStateSha256 -cne [string]$app.PostCloseStateSha256) { throw "$Language App Event A/B states are not bound to its lifecycle states." }
    $event = $eventB
    $eventTransitions = @($transitions | Where-Object { $_.AcceptedEventKind -eq 'pane.agent_status_changed' -and $null -ne $_.AcceptedAgentStatusEvent })
    if ($eventTransitions.Count -lt 2) { throw "$Language Core has fewer than two accepted Agent-status event transitions." }
    $accepted = $eventTransitions[$eventTransitions.Count - 1].AcceptedAgentStatusEvent
    foreach ($name in @('WorkspaceId','PaneId','AgentStatus')) { Assert-I9String $accepted.$name "$Language accepted status $name" | Out-Null }
    $reconciled = @($transitions | Where-Object { $null -ne $_.ReconciliationCount -and [int64]$_.ReconciliationCount -gt 0 })
    if ($reconciled.Count -lt 1) { throw "$Language Core has no reconciliation transition." }
    if ((Get-I9GateValue $gate 'PackageProfileId' "$Language gate") -cne [string]$Package.ProfileId) { throw "$Language gate package profile is not bound to the accepted package." }
    foreach ($pair in @(@('PackageIdentityPath',$Package.IdentityPath),@('PackageArchivePath',$Package.ArchivePath),@('ExtractedPackageRoot',$Package.PackageRoot),@('PackageManifestPath',$Package.ManifestPath))) { if ([IO.Path]::GetFullPath((Get-I9GateValue $gate $pair[0] "$Language gate")) -cne [IO.Path]::GetFullPath([string]$pair[1])) { throw "$Language gate $($pair[0]) is not the real package path." } }
    foreach ($pair in @(@('PackageIdentityFileSha256',$Package.IdentityFileSha256),@('PackageIdentityReceiptSha256',$Package.ReceiptSha256),@('PackageArchiveSha256',$Package.ArchiveSha256),@('PackageManifestSha256',$Package.ManifestSha256),@('AppSha256',$Package.AppSha256),@('CoreSha256',$Package.CoreSha256))) { if ((Get-I9GateValue $gate $pair[0] "$Language gate") -cne [string]$pair[1]) { throw "$Language gate $($pair[0]) is not package-bound." } }
    if ((Get-I9GateValue $gate 'AppRuntimeReportSha256' "$Language gate") -cne $appDoc.Sha256 -or (Get-I9GateValue $gate 'CoreRuntimeReportSha256' "$Language gate") -cne $coreDoc.Sha256) { throw "$Language gate report hashes are stale." }
    if ($null -eq $core.Admission) { throw "$Language Core report has no Herdr admission." }
    foreach ($pair in @(@('HerdrReleaseId','ReleaseId'),@('HerdrExecutableSha256','ExecutableSha256'),@('BundledSchemaSha256','BundledSchemaSha256'),@('HerdrProtocol','Protocol'))) { if ((Get-I9GateValue $gate $pair[0] "$Language gate") -cne [string]$core.Admission.($pair[1])) { throw "$Language gate/Core Herdr admission is not exactly bound." } }
    $semantic = @($app.SemanticStateCaptures)
    if ($semantic.Count -ne 3) { throw "$Language App report must contain exactly three semantic captures." }
    $eventAChanges = @($eventA.Changes); $eventBChanges = @($eventB.Changes)
    if ($eventAChanges.Count -ne 1 -or $eventBChanges.Count -ne 1) { throw "$Language App report must bind exactly one Agent change in each Event." }
    return [pscustomobject][ordered]@{ Language = $Language; EvidenceRunNonce = $runNonce; Root = $root; Gate = $gate; GateSha256 = $gate.Sha256; App = $app; AppSha256 = $appDoc.Sha256; Core = $core; CoreSha256 = $coreDoc.Sha256; AcceptedStatus = $accepted; EventAChange=$eventAChanges[0]; EventBChange=$eventBChanges[0]; InitialSemantic=$semantic[0]; EventASemantic=$semantic[1]; EventBSemantic=$semantic[2]; Reconciliation = $reconciled[$reconciled.Count - 1]; EventAStateSha256 = [string]$eventA.CurrentStateSha256; EventBStateSha256 = [string]$eventB.CurrentStateSha256; StateHashes = @($transitions | ForEach-Object { [string]$_.ContractStateSha256 }) }
}

function Assert-I9UiLeg {
    param([Parameter(Mandatory)][string]$UiRoot, [Parameter(Mandatory)][ValidateSet('Thai','English')][string]$Language, [Parameter(Mandatory)]$Runtime, [Parameter(Mandatory)]$Package, [Parameter(Mandatory)][string]$ExpectedCommit, [Parameter(Mandatory)][string]$ExpectedTree, [Parameter(Mandatory)][string]$RepositoryRoot)
    $root = Get-I9FullPath $UiRoot 'UI evidence'; Assert-I9NoReparse $root 'UI evidence'; $doc = Read-I9Json (Join-Path $root 'issue9-ui-functional.json') "$Language Issue #9 UI receipt"; $receipt = $doc.Value
    Assert-I9ExactProperties $receipt @('SchemaVersion','EvidenceClassification','Issue','Language','RunNonce','Source','Producer','IdentityMapping','Bindings','SideBySideCapture','Pages','Selection','Lifecycle','EvidenceBoundary') "$Language UI receipt"
    if ([int64]$receipt.SchemaVersion -ne 2 -or [int64]$receipt.Issue -ne 9) { throw "$Language UI receipt version/issue mismatch." }
    Assert-I9String $receipt.EvidenceClassification "$Language UI classification" 'Issue9LiveUiObservation' | Out-Null; Assert-I9String $receipt.Language "$Language UI language" $Language | Out-Null
    if ([string]$receipt.RunNonce -cne [string]$Runtime.EvidenceRunNonce) { throw "$Language UI RunNonce is replayed or cross-leg." }
    Assert-I9ExactProperties $receipt.Source @('CommitSha','TreeSha') "$Language UI source"; Assert-I9GitSha $receipt.Source.CommitSha "$Language UI source commit" | Out-Null; Assert-I9GitSha $receipt.Source.TreeSha "$Language UI source tree" | Out-Null
    Assert-I9ExactProperties $receipt.Producer @('Name','ScriptPath','ScriptSha256','AppProcessId','AppExecutableSha256','GeneratedUtc') "$Language UI producer"
    Assert-I9String $receipt.Producer.Name "$Language UI producer name" 'Test-V02LiveRuntimeAcceptance.ps1/HerdrOps.App.RuntimeEvidenceRunner' | Out-Null
    $expectedProducerPath = Join-Path ([IO.Path]::GetFullPath($RepositoryRoot)) 'tools\Test-V02LiveRuntimeAcceptance.ps1'
    $producerPath = Resolve-I9Path ([IO.Path]::GetFullPath($RepositoryRoot)) ([string]$receipt.Producer.ScriptPath) "$Language UI producer script"
    if (-not $producerPath.Equals([IO.Path]::GetFullPath($expectedProducerPath),[StringComparison]::OrdinalIgnoreCase)) { throw "$Language UI producer path is not the composite runtime producer." }
    $producerHeld = Read-I9HeldFile $producerPath -MaximumBytes 2097152
    if ([string]$receipt.Producer.ScriptSha256 -cne $producerHeld.Sha256 -or [string]$receipt.Producer.AppExecutableSha256 -cne [string]$Package.AppSha256 -or [int]$receipt.Producer.AppProcessId -ne [int]$Runtime.App.AppProcessId) { throw "$Language UI producer provenance is stale or forged." }
    $null = ConvertTo-I9Utc ([string]$receipt.Producer.GeneratedUtc) "$Language UI producer GeneratedUtc"
    Assert-I9ExactProperties $receipt.IdentityMapping @('ProjectIdSource','TaskIdSource','AgentIdSource') "$Language identity mapping"
    if ([string]$receipt.IdentityMapping.ProjectIdSource -cne 'Core.WorkspaceId' -or [string]$receipt.IdentityMapping.TaskIdSource -cne 'Core.TabId' -or [string]$receipt.IdentityMapping.AgentIdSource -cne 'Core.TerminalId') { throw "$Language UI identity mapping is not the v0.2 Core semantic mapping." }
    Assert-I9ExactProperties $receipt.Bindings @('GateReportSha256','AppRuntimeReportSha256','CoreRuntimeReportSha256','ProgressHistorySha256','PackageIdentityReceiptSha256','PackageArchiveSha256','PackageManifestSha256','AppSha256','CoreSha256','HerdrExecutableSha256','BundledSchemaSha256') "$Language UI bindings"
    if ([string]$receipt.Source.CommitSha -cne $ExpectedCommit -or [string]$receipt.Source.TreeSha -cne $ExpectedTree) { throw "$Language UI source binding mismatch." }
    foreach ($name in @('GateReportSha256','AppRuntimeReportSha256','CoreRuntimeReportSha256','ProgressHistorySha256','PackageIdentityReceiptSha256','PackageArchiveSha256','PackageManifestSha256','AppSha256','CoreSha256','HerdrExecutableSha256','BundledSchemaSha256')) { Assert-I9Sha $receipt.Bindings.$name "$Language UI binding $name" | Out-Null }
    $expectedHerdrSha = Get-I9GateValue $Runtime.Gate 'HerdrExecutableSha256' "$Language gate"; $expectedSchemaSha = Get-I9GateValue $Runtime.Gate 'BundledSchemaSha256' "$Language gate"
    if ($receipt.Bindings.GateReportSha256 -cne $Runtime.GateSha256 -or $receipt.Bindings.AppRuntimeReportSha256 -cne $Runtime.AppSha256 -or $receipt.Bindings.CoreRuntimeReportSha256 -cne $Runtime.CoreSha256 -or $receipt.Bindings.ProgressHistorySha256 -cne (Get-I9GateValue $Runtime.Gate 'ProgressHistorySha256' "$Language gate") -or $receipt.Bindings.PackageIdentityReceiptSha256 -cne $Package.ReceiptSha256 -or $receipt.Bindings.PackageArchiveSha256 -cne $Package.ArchiveSha256 -or $receipt.Bindings.PackageManifestSha256 -cne $Package.ManifestSha256 -or $receipt.Bindings.AppSha256 -cne $Package.AppSha256 -or $receipt.Bindings.CoreSha256 -cne $Package.CoreSha256 -or $receipt.Bindings.HerdrExecutableSha256 -cne $expectedHerdrSha -or $receipt.Bindings.BundledSchemaSha256 -cne $expectedSchemaSha) { throw "$Language UI receipt is not bound to the exact runtime/package/Herdr hashes." }
    $initial = $Runtime.InitialSemantic
    $initialUtc = ConvertTo-I9Utc ([string]$initial.ObservedUtc) "$Language initial semantic time"
    $eventAPhaseUtc = ConvertTo-I9Utc ([string]$Runtime.App.EventA.PhaseEnteredUtc) "$Language Event A phase time"
    $side = Get-I9Prop $receipt 'SideBySideCapture' "$Language UI receipt"; Assert-I9ExactProperties $side @('Path','Bytes','Sha256','PixelWidth','PixelHeight','ObservedUtc','Phase','Sequence','StateSha256','RunNonce','ArtifactRole') "$Language side-by-side capture"; Assert-I9String $side.ArtifactRole "$Language side-by-side role" 'ActualHerdrAndUiSideBySide' | Out-Null
    if ([string]$side.RunNonce -cne [string]$Runtime.EvidenceRunNonce) { throw "$Language side-by-side capture RunNonce is replayed or cross-leg." }
    if ([string]$side.Phase -cne 'initial' -or [long]$side.Sequence -ne [long]$initial.Sequence -or [string]$side.StateSha256 -cne [string]$initial.NormalizedStateSha256) { throw "$Language side-by-side capture is bound to the wrong semantic phase/state." }
    $sideFile = Assert-I9Png (Resolve-I9Path $root $side.Path "$Language side-by-side capture") "$Language side-by-side capture"
    if ($sideFile.PixelWidth -gt 16384 -or $sideFile.PixelHeight -gt 16384 -or ([int64]$sideFile.PixelWidth * [int64]$sideFile.PixelHeight) -gt 134217728) { throw "$Language side-by-side capture dimensions exceed the bounded capture envelope." }
    $sideUtc = ConvertTo-I9Utc ([string]$side.ObservedUtc) "$Language side-by-side capture time"
    if ($sideUtc -lt (ConvertTo-I9Utc ([string]$Runtime.App.StartedUtc) "$Language App start") -or $sideUtc -ge $eventAPhaseUtc) { throw "$Language side-by-side capture is stale or outside its semantic window." }
    if ([int64]$side.Bytes -ne $sideFile.Bytes -or [string]$side.Sha256 -cne $sideFile.Sha256 -or [int]$side.PixelWidth -ne $sideFile.PixelWidth -or [int]$side.PixelHeight -ne $sideFile.PixelHeight) { throw "$Language side-by-side capture PNG bytes/hash/dimensions mismatch." }
    $pages = @($receipt.Pages); if ($pages.Count -ne 3) { throw "$Language UI receipt must contain exactly three pages." }; $seen = @{}
    $normalizedPages = @()
    foreach ($page in $pages) {
        Assert-I9ExactProperties $page @('Name','Language','UiCapturePath','UiCaptureSha256','PixelWidth','PixelHeight','ObservedUtc','Phase','Sequence','StateSha256','WorkspaceId','ProjectId','AgentId','TaskId','AgentStatus','PaneId') "$Language page"
        $name = Assert-I9String $page.Name "$Language page name"; if ($script:I9ExpectedPages -notcontains $name -or $seen.ContainsKey($name)) { throw "$Language page set is missing/duplicated/unknown." }; $seen[$name] = $true
        Assert-I9String $page.Language "$Language page language" $Language | Out-Null; Assert-I9Sha $page.UiCaptureSha256 "$Language $name capture hash" | Out-Null; Assert-I9Sha $page.StateSha256 "$Language $name state hash" | Out-Null
        if ([string]$page.Phase -cne 'initial' -or [long]$page.Sequence -ne [long]$initial.Sequence -or [string]$page.StateSha256 -cne [string]$initial.NormalizedStateSha256) { throw "$Language $name page is bound to the wrong semantic phase/state." }
        $capture = Assert-I9Png (Resolve-I9Path $Runtime.Root $page.UiCapturePath "$Language $name UI capture") "$Language $name UI capture"
        if ($capture.PixelWidth -ne 1672 -or $capture.PixelHeight -ne 941) { throw "$Language $name UI capture must decode to exactly 1672x941." }
        $captureUtc = ConvertTo-I9Utc ([string]$page.ObservedUtc) "$Language $name capture time"
        if ($captureUtc -gt $initialUtc -or [string]$capture.Sha256 -cne [string]$page.UiCaptureSha256 -or [int]$capture.PixelWidth -ne [int]$page.PixelWidth -or [int]$capture.PixelHeight -ne [int]$page.PixelHeight) { throw "$Language $name UI capture PNG bytes/hash/dimensions/timestamp mismatch." }
        foreach ($field in @('WorkspaceId','ProjectId','AgentId','TaskId','AgentStatus','PaneId')) { Assert-I9String $page.$field "$Language $name $field" | Out-Null }
        $normalizedPages += [pscustomobject][ordered]@{ Name=[string]$page.Name; Language=[string]$page.Language; UiCapturePath=[string]$page.UiCapturePath; UiCaptureSha256=[string]$page.UiCaptureSha256; StateSha256=[string]$page.StateSha256; WorkspaceId=[string]$page.WorkspaceId; ProjectId=[string]$page.ProjectId; AgentId=[string]$page.AgentId; TaskId=[string]$page.TaskId; AgentStatus=[string]$page.AgentStatus; PaneId=[string]$page.PaneId }
    }
    $selection = $receipt.Selection; Assert-I9ExactProperties $selection @('WorkspaceId','ProjectId','AgentId','TaskId','AgentStatus','PaneId','StateSha256','Source') "$Language selection"; Assert-I9String $selection.Source "$Language selection source" 'CoreSemanticSnapshot' | Out-Null
    foreach ($page in $pages) { foreach ($field in @('WorkspaceId','ProjectId','AgentId','TaskId','AgentStatus','PaneId')) { if ([string]$page.$field -cne [string]$selection.$field) { throw "$Language page selection does not match the single Core selection." } } }
    $change = $Runtime.EventAChange
    if ([string]$selection.WorkspaceId -cne [string]$change.WorkspaceId -or [string]$selection.ProjectId -cne [string]$change.WorkspaceId -or [string]$selection.AgentId -cne [string]$change.TerminalId -or [string]$selection.TaskId -cne [string]$change.TabId -or [string]$selection.PaneId -cne [string]$change.PaneId -or [string]$selection.AgentStatus -cne [string]$change.PreviousStatus -or [string]$selection.StateSha256 -cne [string]$initial.NormalizedStateSha256) { throw "$Language selected identifiers/status/state are not the exact initial Core semantic snapshot." }
    $selectedHash = Get-I9RedactedIdentity 'agent' ([string]$selection.AgentId)
    $semanticAgents = @($initial.SourceState.Agents | Where-Object { [string]$_.AgentIdentitySha256 -ceq $selectedHash })
    if ([string]$initial.SourceState.SelectedAgentIdentitySha256 -cne $selectedHash -or $semanticAgents.Count -ne 1 -or [string]$semanticAgents[0].WorkspaceIdentitySha256 -cne (Get-I9RedactedIdentity 'workspace' ([string]$selection.WorkspaceId)) -or [string]$semanticAgents[0].TabIdentitySha256 -cne (Get-I9RedactedIdentity 'tab' ([string]$selection.TaskId)) -or [string]$semanticAgents[0].PaneIdentitySha256 -cne (Get-I9RedactedIdentity 'pane' ([string]$selection.PaneId)) -or [string]$semanticAgents[0].Status -cne [string]$selection.AgentStatus) { throw "$Language forged synchronized identifiers do not reach the exact semantic identity guard." }
    Assert-I9ExactProperties $receipt.EvidenceBoundary @('Runtime','HumanVisual','ReleaseCredit') "$Language evidence boundary"; Assert-I9False $receipt.EvidenceBoundary.ReleaseCredit "$Language UI Release boundary"; Assert-I9String $receipt.EvidenceBoundary.Runtime "$Language UI runtime boundary" 'NOT_OBSERVED' | Out-Null; Assert-I9String $receipt.EvidenceBoundary.HumanVisual "$Language UI human boundary" 'NOT_OBSERVED' | Out-Null
    $life = $receipt.Lifecycle; Assert-I9ExactProperties $life @('DashboardClosed','DashboardClosedUtc','CoreConnectedAfterDashboardClose','DisconnectObserved','DisconnectObservedUtc','ReconnectObserved','ReconnectObservedUtc','ReconciliationObserved','ReconciliationCount','EventAStateSha256','EventBStateSha256','ReconciledStateSha256','ControlServerSurvivedTargetRestart') "$Language lifecycle"; foreach ($name in @('DashboardClosed','CoreConnectedAfterDashboardClose','DisconnectObserved','ReconnectObserved','ReconciliationObserved','ControlServerSurvivedTargetRestart')) { Assert-I9True $life.$name "$Language lifecycle $name" }
    foreach ($name in @('EventAStateSha256','EventBStateSha256','ReconciledStateSha256')) { Assert-I9Sha $life.$name "$Language lifecycle $name" | Out-Null; if ($Runtime.StateHashes -notcontains [string]$life.$name) { throw "$Language lifecycle $name is not Core-bound." } }
    if ([string]$life.EventAStateSha256 -cne $Runtime.EventAStateSha256 -or [string]$life.EventBStateSha256 -cne $Runtime.EventBStateSha256 -or [string]$life.ReconciledStateSha256 -cne [string]$Runtime.Reconciliation.ContractStateSha256) { throw "$Language lifecycle states are not exact runtime-bound states." }
    $dashboardUtc=ConvertTo-I9Utc ([string]$life.DashboardClosedUtc) "$Language lifecycle DashboardClosedUtc";$disconnectUtc=ConvertTo-I9Utc ([string]$life.DisconnectObservedUtc) "$Language lifecycle DisconnectObservedUtc";$reconnectUtc=ConvertTo-I9Utc ([string]$life.ReconnectObservedUtc) "$Language lifecycle ReconnectObservedUtc"
    if ($dashboardUtc -ne (ConvertTo-I9Utc ([string]$Runtime.App.DashboardClosedUtc) "$Language App DashboardClosedUtc") -or $disconnectUtc -ne (ConvertTo-I9Utc ([string]$Runtime.App.DisconnectObservedUtc) "$Language App DisconnectObservedUtc") -or $reconnectUtc -ne (ConvertTo-I9Utc ([string]$Runtime.App.ReconnectObservedUtc) "$Language App ReconnectObservedUtc") -or -not ($initialUtc -lt $eventAPhaseUtc -and $dashboardUtc -lt $disconnectUtc -and $disconnectUtc -lt $reconnectUtc -and $reconnectUtc -lt (ConvertTo-I9Utc ([string]$Runtime.App.EventB.ObservedUtc) "$Language Event B time"))) { throw "$Language lifecycle chronology is invalid or stale." }
    $normalizedSelection=[pscustomobject][ordered]@{WorkspaceId=[string]$selection.WorkspaceId;ProjectId=[string]$selection.ProjectId;AgentId=[string]$selection.AgentId;TaskId=[string]$selection.TaskId;AgentStatus=[string]$selection.AgentStatus;PaneId=[string]$selection.PaneId;StateSha256=[string]$selection.StateSha256;Source='CoreSnapshot'}
    $normalizedLifecycle=[pscustomobject][ordered]@{DashboardClosed=[bool]$life.DashboardClosed;CoreConnectedAfterDashboardClose=[bool]$life.CoreConnectedAfterDashboardClose;DisconnectObserved=[bool]$life.DisconnectObserved;ReconnectObserved=[bool]$life.ReconnectObserved;ReconciliationObserved=[bool]$life.ReconciliationObserved;EventAStateSha256=[string]$life.EventAStateSha256;EventBStateSha256=[string]$life.EventBStateSha256;ReconciledStateSha256=[string]$life.ReconciledStateSha256;ControlServerSurvivedTargetRestart=[bool]$life.ControlServerSurvivedTargetRestart}
    return [pscustomobject][ordered]@{ Language = $Language; RunNonce=[string]$receipt.RunNonce; ReceiptPath = $doc.Path; ReceiptSha256 = $doc.Sha256; SideBySidePath = $sideFile.Path; SideBySideSha256 = $sideFile.Sha256; Pages = @($normalizedPages); Selection = $normalizedSelection; Lifecycle = $normalizedLifecycle }
}

function Assert-I9MatrixCandidate {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)]$Thai, [Parameter(Mandatory)]$English, [Parameter(Mandatory)]$Package, [Parameter(Mandatory)][string]$ExpectedCommit, [Parameter(Mandatory)][string]$ExpectedTree)
    $doc = Read-I9Json $Path 'language matrix candidate'; Assert-I9ExactProperties $doc.Value @('EvidenceClassification','IndependentHumanReview','ReleaseCredit','ManifestFormatVersion','ManifestHashScope','ManifestPayloadSha256','Payload') 'language matrix candidate'; Assert-I9String $doc.Value.EvidenceClassification 'matrix classification' 'RuntimeMatrixCandidate' | Out-Null; Assert-I9String $doc.Value.IndependentHumanReview 'matrix review' 'NOT_OBSERVED' | Out-Null; Assert-I9False $doc.Value.ReleaseCredit 'matrix release credit'
    $payload = $doc.Value.Payload; Assert-I9ExactProperties $payload @('GeneratedUnixTimeMilliseconds','RunNonce','IndependentHumanReview','ReleaseCredit','Binding','Runs') 'matrix payload'; Assert-I9String $payload.IndependentHumanReview 'matrix payload review' 'NOT_OBSERVED' | Out-Null; Assert-I9False $payload.ReleaseCredit 'matrix payload release credit';$producerRunNonce=Assert-I9RunNonce $payload.RunNonce 'matrix producer RunNonce';$generatedUtc=[DateTimeOffset]::FromUnixTimeMilliseconds([int64]$payload.GeneratedUnixTimeMilliseconds).ToUniversalTime();$now=[DateTimeOffset]::UtcNow;if($generatedUtc-gt$now-or$generatedUtc-lt$now.AddMinutes(-$script:I9MaximumAgeMinutes)){throw 'Matrix candidate is outside the bounded fresh review window.'}
    $binding = $payload.Binding; Assert-I9ExactProperties $binding @('SourceCommit','SourceTree','ProfileId','ProfileSha256','ReferenceHostSchemaSha256','PackageIdentityReceiptSha256','HerdrReleaseId','HerdrExecutableSha256','AppExecutableSha256','CoreExecutableSha256','BundledSchemaSha256','HerdrProtocol') 'matrix binding'
    Assert-I9GitSha $binding.SourceCommit 'matrix source commit' | Out-Null; Assert-I9GitSha $binding.SourceTree 'matrix source tree' | Out-Null
    foreach ($name in @('ProfileSha256','ReferenceHostSchemaSha256','PackageIdentityReceiptSha256','HerdrExecutableSha256','AppExecutableSha256','CoreExecutableSha256','BundledSchemaSha256')) { Assert-I9Sha $binding.$name "matrix binding $name" | Out-Null }
    $expectedBinding = [ordered]@{ SourceCommit = $ExpectedCommit; SourceTree = $ExpectedTree; PackageIdentityReceiptSha256 = $Package.ReceiptSha256; AppExecutableSha256 = $Package.AppSha256; CoreExecutableSha256 = $Package.CoreSha256; ProfileId = Get-I9GateValue $Thai.Gate 'PackageProfileId' 'Thai gate'; HerdrReleaseId = Get-I9GateValue $Thai.Gate 'HerdrReleaseId' 'Thai gate'; HerdrExecutableSha256 = Get-I9GateValue $Thai.Gate 'HerdrExecutableSha256' 'Thai gate'; BundledSchemaSha256 = Get-I9GateValue $Thai.Gate 'BundledSchemaSha256' 'Thai gate'; HerdrProtocol = Get-I9GateValue $Thai.Gate 'HerdrProtocol' 'Thai gate'; ProfileSha256 = Get-I9GateValue $Thai.Gate 'ReferenceHostProfileSha256' 'Thai gate'; ReferenceHostSchemaSha256 = Get-I9GateValue $Thai.Gate 'ReferenceHostSchemaSha256' 'Thai gate' }
    foreach ($name in $expectedBinding.Keys) { if ([string]$binding.$name -cne [string]$expectedBinding[$name]) { throw "Matrix binding '$name' is stale or package/session-mismatched." } }
    $canonicalPayload = ConvertTo-V02Jcs (($payload | ConvertTo-Json -Depth 50 | ConvertFrom-Json)); $computedPayloadHash = Get-I9Hash ([Text.UTF8Encoding]::new($false).GetBytes($canonicalPayload)); $payloadHash = Assert-I9Sha $doc.Value.ManifestPayloadSha256 'matrix payload hash'; if ($payloadHash -cne $computedPayloadHash) { throw 'Matrix payload hash does not match canonical payload bytes.' }
    $runs = @($payload.Runs); if ($runs.Count -ne 2) { throw 'Matrix candidate must have two language runs.' }; $byLanguage = @{}; foreach ($run in $runs) { if ($byLanguage.ContainsKey([string]$run.Language)) { throw 'Matrix candidate has duplicate language legs.' }; $byLanguage[[string]$run.Language] = $run }
    foreach ($pair in @(@('Thai',$Thai),@('English',$English))) { $lang = [string]$pair[0]; if (-not $byLanguage.ContainsKey($lang)) { throw "Matrix candidate is missing $lang." }; $run = $byLanguage[$lang]; $actual = $pair[1]; foreach ($name in @('EvidenceRunNonce','EvidenceDirectory','GateReportSha256','AppRuntimeReportSha256','CoreRuntimeReportSha256','SourceCommit','SourceTree','PackageIdentityReceiptSha256')) { $null = Get-I9Prop $run $name "matrix $lang run" };Assert-I9RunNonce $run.EvidenceRunNonce "matrix $lang evidence RunNonce"|Out-Null; if ([string]$run.EvidenceRunNonce-cne[string]$actual.EvidenceRunNonce-or[string]$run.EvidenceDirectory -cne $actual.Root -or [string]$run.GateReportSha256 -cne $actual.GateSha256 -or [string]$run.AppRuntimeReportSha256 -cne $actual.AppSha256 -or [string]$run.CoreRuntimeReportSha256 -cne $actual.CoreSha256 -or [string]$run.SourceCommit -cne $ExpectedCommit -or [string]$run.SourceTree -cne $ExpectedTree -or [string]$run.PackageIdentityReceiptSha256 -cne $Package.ReceiptSha256) { throw "Matrix $lang run is not bound to the exact runtime leg and evidence RunNonce." } };if($producerRunNonce-ceq$Thai.EvidenceRunNonce-or$producerRunNonce-ceq$English.EvidenceRunNonce){throw 'Matrix producer RunNonce must be distinct from both runtime-evidence RunNonce values.'}
    return [pscustomobject][ordered]@{ Path = $doc.Path; FileSha256 = $doc.Sha256; PayloadSha256 = $payloadHash;ProducerRunNonce=$producerRunNonce }
}

function Assert-I9DerivedMatrix {
    param([Parameter(Mandatory)][string]$RepositoryRoot, [Parameter(Mandatory)][string]$ThaiRuntimeRoot, [Parameter(Mandatory)][string]$EnglishRuntimeRoot, [Parameter(Mandatory)][string]$PackageIdentityPath, [Parameter(Mandatory)][string]$PackageArchivePath, [Parameter(Mandatory)][string]$PackageRoot, [Parameter(Mandatory)]$Thai, [Parameter(Mandatory)]$English, [switch]$FixtureMode)
    if ($FixtureMode) { return $null }
    $matrixScript = Join-Path ([IO.Path]::GetFullPath($RepositoryRoot)) 'tools\Test-V02LanguageMatrixAcceptance.ps1'; $profile = Join-Path ([IO.Path]::GetFullPath($RepositoryRoot)) 'tools\packaging\v0.2\package-identity-profile.json'; $tempRoot = Join-Path ([IO.Path]::GetTempPath()) ('herdrops-issue9-matrix-' + [Guid]::NewGuid().ToString('N')); New-Item -ItemType Directory -Path $tempRoot -Force | Out-Null; $derivedPath = Join-Path $tempRoot 'derived.json'
    try {
        $null = @(& $matrixScript -ThaiEvidenceDirectory $ThaiRuntimeRoot -EnglishEvidenceDirectory $EnglishRuntimeRoot -PackageIdentityPath $PackageIdentityPath -PackageArchivePath $PackageArchivePath -ExtractedPackageRoot $PackageRoot -RepositoryRoot $RepositoryRoot -PackageProfilePath $profile -ProducerRunNonce ([Guid]::NewGuid().ToString('N')) -OutputPath $derivedPath)
        if (-not (Test-Path -LiteralPath $derivedPath -PathType Leaf)) { throw 'Existing language-matrix verifier did not emit its independently derived candidate.' }
        $derived = Read-I9Json $derivedPath 'derived language matrix candidate'; if ([string]$derived.Value.Payload.Binding.SourceCommit -cne [string]$Thai.Gate.Values.ExpectedSourceCommit -or [string]$derived.Value.Payload.Binding.SourceTree -cne [string]$Thai.Gate.Values.ExpectedSourceTree) { throw 'Derived matrix source binding changed.' }
        return $derived
    } finally { if (Test-Path -LiteralPath $tempRoot) { Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue } }
}

function Publish-I9NoClobber {
    param([Parameter(Mandatory)][string]$AllowedRoot, [Parameter(Mandatory)][string]$OutputPath, [Parameter(Mandatory)][string]$Json)
    $root = Get-I9FullPath $AllowedRoot 'output root'; Assert-I9NoReparse $root 'output root'; $full = Get-I9FullPath $OutputPath 'OutputPath'; $parent = [IO.Path]::GetDirectoryName($full)
    if (-not (Test-I9Within $parent $root) -or $full.Equals($root, [StringComparison]::OrdinalIgnoreCase)) { throw 'OutputPath is outside the allowed common root.' }; if (-not (Test-Path -LiteralPath $parent -PathType Container)) { throw 'Output parent is missing.' }; Assert-I9NoReparse $parent 'output parent'; if (Test-Path -LiteralPath $full) { throw 'OutputPath already exists.' }
    $bytes = [Text.UTF8Encoding]::new($false).GetBytes($Json + "`n"); if ($bytes.Length -gt $script:I9MaximumFileBytes) { throw 'Output is too large.' }; $temporary = Join-Path $parent ('.' + [IO.Path]::GetFileName($full) + '.' + [Guid]::NewGuid().ToString('N') + '.tmp'); $stream = $null
    try { $stream = [IO.File]::Open($temporary, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None); $stream.Write($bytes,0,$bytes.Length); $stream.Flush($true); $stream.Dispose(); $stream = $null; Assert-I9NoReparse $parent 'output parent before move'; if (Test-Path -LiteralPath $full) { throw 'OutputPath appeared during publication.' }; [IO.File]::Move($temporary,$full) } catch { if ($null -ne $stream) { $stream.Dispose() }; if ([IO.File]::Exists($temporary)) { [IO.File]::Delete($temporary) }; throw }
    return Read-I9HeldFile $full
}

function Invoke-I9LiveUiVerification {
    param([Parameter(Mandatory)][string]$ThaiRuntimeEvidenceDirectory,[Parameter(Mandatory)][string]$EnglishRuntimeEvidenceDirectory,[Parameter(Mandatory)][string]$ThaiUiEvidenceDirectory,[Parameter(Mandatory)][string]$EnglishUiEvidenceDirectory,[Parameter(Mandatory)][string]$MatrixCandidatePath,[Parameter(Mandatory)][string]$PackageIdentityPath,[Parameter(Mandatory)][string]$PackageArchivePath,[Parameter(Mandatory)][string]$ExtractedPackageRoot,[Parameter(Mandatory)][string]$RepositoryRoot,[Parameter(Mandatory)][string]$ExpectedSourceCommit,[Parameter(Mandatory)][string]$ExpectedSourceTree,[Parameter(Mandatory)][string]$OutputPath,[switch]$FixtureMode)
    Assert-I9GitSha $ExpectedSourceCommit 'ExpectedSourceCommit' | Out-Null; Assert-I9GitSha $ExpectedSourceTree 'ExpectedSourceTree' | Out-Null
    if (-not $FixtureMode) { $root = [IO.Path]::GetFullPath($RepositoryRoot); $commit = ((@(& git -C $root rev-parse HEAD 2>&1)) -join '').Trim(); $tree = ((@(& git -C $root rev-parse 'HEAD^{tree}' 2>&1)) -join '').Trim(); $status = @(& git -C $root status --porcelain=v1 --untracked-files=all); if ($commit -cne $ExpectedSourceCommit -or $tree -cne $ExpectedSourceTree -or $status.Count -ne 0) { throw 'Production Issue #9 verification requires the exact clean source checkout.' } }
    $thaiRoot = Get-I9FullPath $ThaiRuntimeEvidenceDirectory 'Thai runtime'; $englishRoot = Get-I9FullPath $EnglishRuntimeEvidenceDirectory 'English runtime'; if ((Test-I9Within $thaiRoot $englishRoot) -or (Test-I9Within $englishRoot $thaiRoot)) { throw 'Thai and English runtime roots must be distinct.' }
    $package = Assert-I9Package $PackageIdentityPath $PackageArchivePath $ExtractedPackageRoot $ExpectedSourceCommit $ExpectedSourceTree
    $thai = Assert-I9RuntimeRun $thaiRoot 'Thai' $ExpectedSourceCommit $ExpectedSourceTree $package; $english = Assert-I9RuntimeRun $englishRoot 'English' $ExpectedSourceCommit $ExpectedSourceTree $package
    # A shared runtime nonce is the Issue #10 bilingual transaction identity.
    # The language-specific roots, receipt languages, and exact gate/report/UI
    # hashes below prevent a same-nonce leg from being replayed or transplanted.
    foreach ($name in @('AcceptanceControlSession','TargetAgentLabSession','AcceptanceControlSocketPath','TargetAgentLabSocketPath','TargetAgentSessionReference','TargetAgentSessionReferenceEvidenceSource','TargetAgentSessionReferenceObservableByGate','TargetAgentSessionReferenceBoundary','AcceptanceControlServerIdentity','HerdrReleaseId','HerdrExecutableSha256','BundledSchemaSha256','HerdrProtocol')) { if ((Get-I9GateValue $thai.Gate $name 'Thai binding') -cne (Get-I9GateValue $english.Gate $name 'English binding')) { throw "Thai/English $name identity mismatch." } }
    $matrix = Assert-I9MatrixCandidate $MatrixCandidatePath $thai $english $package $ExpectedSourceCommit $ExpectedSourceTree; $null = Assert-I9DerivedMatrix $RepositoryRoot $thaiRoot $englishRoot $PackageIdentityPath $PackageArchivePath $ExtractedPackageRoot $thai $english -FixtureMode:$FixtureMode
    $thaiUi = Assert-I9UiLeg $ThaiUiEvidenceDirectory 'Thai' $thai $package $ExpectedSourceCommit $ExpectedSourceTree $RepositoryRoot; $englishUi = Assert-I9UiLeg $EnglishUiEvidenceDirectory 'English' $english $package $ExpectedSourceCommit $ExpectedSourceTree $RepositoryRoot
    foreach ($field in @('WorkspaceId','ProjectId','AgentId','TaskId','AgentStatus','PaneId','StateSha256')) { if ([string]$thaiUi.Selection.$field -cne [string]$englishUi.Selection.$field) { throw "Thai/English UI selections are not the same exact candidate state ($field)." } }
    $payload = [ordered]@{ SchemaVersion = 1; EvidenceClassification = 'Issue9RuntimeCandidate'; Issue = 9; Result = 'PASS'; Source = [ordered]@{ CommitSha = $ExpectedSourceCommit; TreeSha = $ExpectedSourceTree; GitTreeClean = $true }; Package = [ordered]@{ IdentityPath = $package.IdentityPath; IdentityFileSha256 = $package.IdentityFileSha256; ReceiptSha256 = $package.ReceiptSha256; ArchivePath = $package.ArchivePath; ArchiveSha256 = $package.ArchiveSha256; ManifestPath = $package.ManifestPath; ManifestSha256 = $package.ManifestSha256; AppPath = $package.AppPath; AppSha256 = $package.AppSha256; CorePath = $package.CorePath; CoreSha256 = $package.CoreSha256 }; Herdr = [ordered]@{ ReleaseId = Get-I9GateValue $thai.Gate 'HerdrReleaseId' 'Thai gate'; ExecutableSha256 = Get-I9GateValue $thai.Gate 'HerdrExecutableSha256' 'Thai gate'; BundledSchemaSha256 = Get-I9GateValue $thai.Gate 'BundledSchemaSha256' 'Thai gate'; Protocol = Get-I9GateValue $thai.Gate 'HerdrProtocol' 'Thai gate' }; Sessions = [ordered]@{ Control = [ordered]@{ Name = Get-I9GateValue $thai.Gate 'AcceptanceControlSession' 'Thai gate'; SocketPath = Get-I9GateValue $thai.Gate 'AcceptanceControlSocketPath' 'Thai gate'; ServerIdentity = Get-I9GateValue $thai.Gate 'AcceptanceControlServerIdentity' 'Thai gate' }; Target = [ordered]@{ Name = Get-I9GateValue $thai.Gate 'TargetAgentLabSession' 'Thai gate'; SocketPath = Get-I9GateValue $thai.Gate 'TargetAgentLabSocketPath' 'Thai gate'; Reference = Get-I9GateValue $thai.Gate 'TargetAgentSessionReference' 'Thai gate' } }; MatrixCandidate = [ordered]@{ Path = $matrix.Path; FileSha256 = $matrix.FileSha256; PayloadSha256 = $matrix.PayloadSha256; ProducerRunNonce=$matrix.ProducerRunNonce; EvidenceClassification = 'RuntimeMatrixCandidate'; IndependentHumanReview = 'NOT_OBSERVED'; ReleaseCredit = $false }; Languages = @([ordered]@{ Language = 'Thai'; EvidenceRunNonce=$thai.EvidenceRunNonce; RuntimeEvidenceDirectory = $thai.Root; UiEvidenceDirectory = [IO.Path]::GetFullPath($ThaiUiEvidenceDirectory); UiReceiptPath = $thaiUi.ReceiptPath; UiReceiptSha256 = $thaiUi.ReceiptSha256; SideBySideCaptureSha256 = $thaiUi.SideBySideSha256; Pages = @($thaiUi.Pages); Selection = $thaiUi.Selection; Lifecycle = $thaiUi.Lifecycle },[ordered]@{ Language = 'English'; EvidenceRunNonce=$english.EvidenceRunNonce; RuntimeEvidenceDirectory = $english.Root; UiEvidenceDirectory = [IO.Path]::GetFullPath($EnglishUiEvidenceDirectory); UiReceiptPath = $englishUi.ReceiptPath; UiReceiptSha256 = $englishUi.ReceiptSha256; SideBySideCaptureSha256 = $englishUi.SideBySideSha256; Pages = @($englishUi.Pages); Selection = $englishUi.Selection; Lifecycle = $englishUi.Lifecycle }); EvidenceBoundary = [ordered]@{ Runtime = 'NOT_OBSERVED'; HumanVisual = 'NOT_OBSERVED'; ReleaseCredit = $false; OutputAuthority = 'RuntimeCandidate'; FixtureMode = [bool]$FixtureMode } }
    $nativeSession=ConvertFrom-I9NativeSessionReference (Get-I9GateValue $thai.Gate 'TargetAgentSessionReference' 'Thai gate') 'Thai gate native session'
    $payload.SchemaVersion=2
    $payload.Sessions.Target.Remove('Reference')
    $payload.Sessions.Target.Add('NativeSession',[ordered]@{agent=[string]$nativeSession.agent;kind=[string]$nativeSession.kind;source=[string]$nativeSession.source;value=[string]$nativeSession.value})
    $payload.Sessions.Target.Add('EvidenceSource','HerdrCliAgentMetadata')
    $payload.Sessions.Target.Add('ObservableByGate',$true)
    if (-not $FixtureMode) { $root = [IO.Path]::GetFullPath($RepositoryRoot); $commitAfter = ((@(& git -C $root rev-parse HEAD 2>&1)) -join '').Trim(); $treeAfter = ((@(& git -C $root rev-parse 'HEAD^{tree}' 2>&1)) -join '').Trim(); $statusAfter = @(& git -C $root status --porcelain=v1 --untracked-files=all); if ($commitAfter -cne $ExpectedSourceCommit -or $treeAfter -cne $ExpectedSourceTree -or $statusAfter.Count -ne 0) { throw 'Source changed before Issue #9 candidate publication.' } }
    $json = ConvertTo-V02Jcs ($payload | ConvertTo-Json -Depth 50 | ConvertFrom-Json); $commonRoot = [IO.Path]::GetDirectoryName($thaiRoot); if ((Test-I9Within $OutputPath $thaiRoot) -or (Test-I9Within $OutputPath $englishRoot) -or (Test-I9Within $OutputPath $ThaiUiEvidenceDirectory) -or (Test-I9Within $OutputPath $EnglishUiEvidenceDirectory)) { throw 'OutputPath must be outside all evidence trees.' }
    $published = Publish-I9NoClobber $commonRoot $OutputPath $json
    if (-not $FixtureMode) { $root = [IO.Path]::GetFullPath($RepositoryRoot); $commitAfter = ((@(& git -C $root rev-parse HEAD 2>&1)) -join '').Trim(); $treeAfter = ((@(& git -C $root rev-parse 'HEAD^{tree}' 2>&1)) -join '').Trim(); $statusAfter = @(& git -C $root status --porcelain=v1 --untracked-files=all); if ($commitAfter -cne $ExpectedSourceCommit -or $treeAfter -cne $ExpectedSourceTree -or $statusAfter.Count -ne 0) { throw 'Source changed after Issue #9 candidate publication.' } }
    return [pscustomobject][ordered]@{ Path = $published.Path; Sha256 = $published.Sha256; EvidenceClassification = 'Issue9RuntimeCandidate'; Result = 'PASS' }
}
