Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:I10ApprovedLimits = [ordered]@{
    CpuMaximumPercent = 1
    WidgetLatencyP95Milliseconds = 250
    UiStallP95Milliseconds = 50
    UiStallMaximumMilliseconds = 100
    WorkingSetMaximumBytes = 267386880L
    WorkingSetMaximumMegabytes = 255
    ResourceSlopeMaximumBytesPerTenMinutes = 1048576L
    SoakAcMinutes = 60
    SoakBatteryMinutes = 60
    SoakBinMinutes = 5
}

$i10ProfilePath = Join-Path $PSScriptRoot '..\lib\V02ReferenceHostProfile.ps1'
if (Test-Path -LiteralPath $i10ProfilePath -PathType Leaf) {
    . $i10ProfilePath
}

if ($null -eq ('I10.NativeFileIdentity' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;

namespace I10
{
    public static class NativeFileIdentity
    {
        [StructLayout(LayoutKind.Sequential)]
        private struct BY_HANDLE_FILE_INFORMATION
        {
            public uint FileAttributes;
            public System.Runtime.InteropServices.ComTypes.FILETIME CreationTime;
            public System.Runtime.InteropServices.ComTypes.FILETIME LastAccessTime;
            public System.Runtime.InteropServices.ComTypes.FILETIME LastWriteTime;
            public uint VolumeSerialNumber;
            public uint FileSizeHigh;
            public uint FileSizeLow;
            public uint NumberOfLinks;
            public uint FileIndexHigh;
            public uint FileIndexLow;
        }

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool GetFileInformationByHandle(
            IntPtr hFile,
            out BY_HANDLE_FILE_INFORMATION lpFileInformation);

        public static string Read(SafeFileHandle handle, out uint numberOfLinks)
        {
            BY_HANDLE_FILE_INFORMATION info;
            if (!GetFileInformationByHandle(handle.DangerousGetHandle(), out info))
            {
                throw new Win32Exception(Marshal.GetLastWin32Error());
            }
            numberOfLinks = info.NumberOfLinks;
            ulong fileIndex = ((ulong)info.FileIndexHigh << 32) | info.FileIndexLow;
            return info.VolumeSerialNumber.ToString("X8") + ":" + fileIndex.ToString("X16");
        }
    }
}
'@ -Language CSharp
}

function Assert-I10ExactProperties {
    param(
        [Parameter(Mandatory = $true)]$Value,
        [Parameter(Mandatory = $true)][string[]]$Names,
        [Parameter(Mandatory = $true)][string]$Context
    )
    if ($null -eq $Value -or $Value -isnot [psobject]) {
        throw "$Context must be a JSON object."
    }
    $actual = @($Value.PSObject.Properties.Name)
    $expected = @($Names)
    $actualJoined = (@($actual | Sort-Object) -join "`n")
    $expectedJoined = (@($expected | Sort-Object) -join "`n")
    if ($actualJoined -cne $expectedJoined) {
        throw "$Context has unknown, missing, or duplicate fields. Expected=$($expected -join ',') Observed=$($actual -join ',')"
    }
}

function Assert-I10String {
    param([Parameter(Mandatory = $true)]$Value,[Parameter(Mandatory = $true)][string]$Context)
    if ($Value -isnot [string] -or [string]::IsNullOrWhiteSpace([string]$Value)) {
        throw "$Context must be a non-empty string."
    }
}

function Assert-I10Sha256 {
    param([Parameter(Mandatory = $true)]$Value,[Parameter(Mandatory = $true)][string]$Context)
    if ($Value -isnot [string] -or [string]$Value -notmatch '^[0-9A-Fa-f]{64}$') {
        throw "$Context must be a SHA-256 hex string."
    }
}

function Assert-I10Commit {
    param([Parameter(Mandatory = $true)][string]$Value,[Parameter(Mandatory = $true)][string]$Context)
    if ($Value -notmatch '^[0-9a-f]{40}$') { throw "$Context must be lowercase 40-hex." }
}

function Assert-I10Boolean {
    param([Parameter(Mandatory = $true)]$Value,[Parameter(Mandatory = $true)][string]$Context)
    if ($Value -isnot [bool]) { throw "$Context must be a native JSON boolean." }
}

function Assert-I10Integer {
    param([Parameter(Mandatory = $true)]$Value,[Parameter(Mandatory = $true)][string]$Context,[switch]$AllowZero)
    $codes = @([TypeCode]::Byte,[TypeCode]::SByte,[TypeCode]::UInt16,[TypeCode]::UInt32,[TypeCode]::UInt64,[TypeCode]::Int16,[TypeCode]::Int32,[TypeCode]::Int64)
    if ($null -eq $Value -or $codes -notcontains [Type]::GetTypeCode($Value.GetType())) { throw "$Context must be a native JSON integer." }
    if ($AllowZero) {
        if ([int64]$Value -lt 0) { throw "$Context must be non-negative." }
    } elseif ([int64]$Value -le 0) {
        throw "$Context must be positive."
    }
}

function Assert-I10Utc {
    param([Parameter(Mandatory = $true)]$Value,[Parameter(Mandatory = $true)][string]$Context)
    if ($Value -isnot [string]) { throw "$Context must be an ISO-8601 string." }
    try { $parsed = [DateTimeOffset]::Parse([string]$Value, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind) }
    catch { throw "$Context is not a valid ISO-8601 timestamp." }
    if ($parsed.Offset -eq [TimeSpan]::Zero -and [string]$Value -notmatch '(Z|[+-][0-9]{2}:[0-9]{2})$') { throw "$Context must carry an explicit UTC offset." }
    return $parsed.ToUniversalTime()
}

function Get-I10Sha256Bytes {
    param([Parameter(Mandatory = $true)][byte[]]$Bytes)
    $sha = [Security.Cryptography.SHA256]::Create()
    try { return ([BitConverter]::ToString($sha.ComputeHash($Bytes))).Replace('-', '').ToUpperInvariant() }
    finally { $sha.Dispose() }
}

function Get-I10Sha256Text {
    param([Parameter(Mandatory = $true)][string]$Text)
    return Get-I10Sha256Bytes -Bytes ([Text.UTF8Encoding]::new($false, $true).GetBytes($Text))
}

function Assert-I10NoReparsePath {
    param([Parameter(Mandatory = $true)][string]$Root,[Parameter(Mandatory = $true)][string]$Path,[Parameter(Mandatory = $true)][string]$Context)
    $fullRoot = [IO.Path]::GetFullPath($Root).TrimEnd('\','/')
    $fullPath = [IO.Path]::GetFullPath($Path)
    if (-not [StringComparer]::OrdinalIgnoreCase.Equals($fullPath, $fullRoot) -and -not $fullPath.StartsWith($fullRoot + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) {
        throw "$Context escaped its allowed root."
    }
    $cursor = if (Test-Path -LiteralPath $fullPath) { $fullPath } else { Split-Path -Parent $fullPath }
    while (-not [string]::IsNullOrWhiteSpace($cursor)) {
        if (Test-Path -LiteralPath $cursor) {
            $item = Get-Item -LiteralPath $cursor -Force
            if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw "$Context contains a reparse-point component: $cursor" }
        }
        if ([StringComparer]::OrdinalIgnoreCase.Equals($cursor.TrimEnd('\','/'), $fullRoot)) { break }
        $next = Split-Path -Parent $cursor
        if ([string]::IsNullOrWhiteSpace($next) -or $next -ceq $cursor) { break }
        $cursor = $next
    }
}

function Resolve-I10ContainedPath {
    param([Parameter(Mandatory = $true)][string]$Root,[Parameter(Mandatory = $true)][string]$RelativePath,[Parameter(Mandatory = $true)][string]$Context)
    if ([IO.Path]::IsPathRooted($RelativePath) -or $RelativePath -match '(^|[\\/])\.\.([\\/]|$)' -or [string]::IsNullOrWhiteSpace($RelativePath)) {
        throw "$Context must be a non-rooted relative path without parent traversal."
    }
    $fullRoot = [IO.Path]::GetFullPath($Root).TrimEnd('\','/')
    $full = [IO.Path]::GetFullPath((Join-Path $fullRoot ($RelativePath.Replace('/', '\'))))
    Assert-I10NoReparsePath -Root $fullRoot -Path $full -Context $Context
    return $full
}

function Read-I10HeldFile {
    param([Parameter(Mandatory = $true)][string]$Path,[Parameter(Mandatory = $true)][long]$MaximumBytes,[Parameter(Mandatory = $true)][string]$Context)
    $full = [IO.Path]::GetFullPath($Path)
    if (-not (Test-Path -LiteralPath $full -PathType Leaf)) { throw "$Context is missing: $full" }
    $stream = New-Object IO.FileStream($full, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
    try {
        if ($stream.Length -gt $MaximumBytes) { throw "$Context exceeds its bounded size of $MaximumBytes bytes." }
        $length = [int]$stream.Length
        $bytes = New-Object byte[] $length
        $offset = 0
        while ($offset -lt $length) {
            $read = $stream.Read($bytes, $offset, $length - $offset)
            if ($read -le 0) { throw "$Context ended before its held byte count was read." }
            $offset += $read
        }
        [uint32]$links = 0
        $fileId = [I10.NativeFileIdentity]::Read($stream.SafeFileHandle, [ref]$links)
        return [pscustomobject][ordered]@{
            Path = $full
            Bytes = $bytes
            Length = [long]$length
            Sha256 = Get-I10Sha256Bytes -Bytes $bytes
            FileId = [string]$fileId
            LinkCount = [uint32]$links
        }
    }
    finally { $stream.Dispose() }
}

function Read-I10StrictJson {
    param([Parameter(Mandatory = $true)][string]$Path,[Parameter(Mandatory = $true)][string]$Context,[long]$MaximumBytes = 16777216)
    $held = Read-I10HeldFile -Path $Path -MaximumBytes $MaximumBytes -Context $Context
    if ($held.Bytes.Length -ge 3 -and $held.Bytes[0] -eq 0xEF -and $held.Bytes[1] -eq 0xBB -and $held.Bytes[2] -eq 0xBF) { throw "$Context must be UTF-8 without a BOM." }
    try { $json = [Text.UTF8Encoding]::new($false, $true).GetString($held.Bytes) }
    catch { throw "$Context contains malformed UTF-8." }
    if ($json.IndexOf([char]0xFEFF) -ge 0) { throw "$Context contains an unexpected BOM." }
    if (Get-Command Assert-V02NoDuplicateJsonProperties -ErrorAction SilentlyContinue) { Assert-V02NoDuplicateJsonProperties -Json $json -Source $Path }
    try {
        if ($PSVersionTable.PSVersion.Major -ge 7 -and (Get-Command ConvertFrom-Json).Parameters.ContainsKey('DateKind')) {
            $value = $json | ConvertFrom-Json -DateKind String
        } else {
            $value = $json | ConvertFrom-Json
        }
    }
    catch { throw "$Context is malformed JSON: $($_.Exception.Message)" }
    if ($null -eq $value -or $value -isnot [pscustomobject]) { throw "$Context root must be an object." }
    return [pscustomobject][ordered]@{ Value = $value; Json = $json; Held = $held }
}

function Get-I10CanonicalSha256 {
    param([Parameter(Mandatory = $true)]$Value)
    if (Get-Command ConvertTo-V02Jcs -ErrorAction SilentlyContinue) {
        return Get-I10Sha256Text -Text (ConvertTo-V02Jcs $Value)
    }
    return Get-I10Sha256Text -Text (($Value | ConvertTo-Json -Depth 100 -Compress))
}

function Get-I10Lines {
    param([Parameter(Mandatory = $true)][string]$Path)
    $held = Read-I10HeldFile -Path $Path -MaximumBytes 16777216 -Context 'Issue #10 gate report'
    try { $text = [Text.UTF8Encoding]::new($false, $true).GetString($held.Bytes) }
    catch { throw 'Issue #10 gate report is not valid UTF-8.' }
    $map = [ordered]@{}
    foreach ($line in ($text -split "`r?`n")) {
        if ($line -match '^([^:]+):[ ]?(.*)$') {
            $key = [string]$matches[1]
            if ($map.Contains($key)) { throw "Issue #10 gate report contains duplicate field '$key'." }
            $map[$key] = [string]$matches[2]
        }
    }
    return [pscustomobject][ordered]@{ Hash = $held.Sha256; Text = $text; Fields = [pscustomobject]$map; GeneratedUtc = $null }
}

function Get-I10Field {
    param([Parameter(Mandatory = $true)]$Fields,[Parameter(Mandatory = $true)][string[]]$Names,[Parameter(Mandatory = $true)][string]$Context)
    foreach ($name in $Names) {
        $prop = $Fields.PSObject.Properties | Where-Object { $_.Name -ceq $name }
        if ($null -ne $prop) { return [string]$prop.Value }
    }
    throw "$Context is missing one of: $($Names -join ', ')."
}

function Assert-I10FieldEqual {
    param([Parameter(Mandatory = $true)]$Fields,[Parameter(Mandatory = $true)][string[]]$Names,[Parameter(Mandatory = $true)][string]$Expected,[Parameter(Mandatory = $true)][string]$Context)
    $observed = Get-I10Field -Fields $Fields -Names $Names -Context $Context
    if ($observed -cne $Expected) { throw "$Context mismatch. Expected='$Expected' Observed='$observed'." }
}

function Get-I10StateHashes {
    param([Parameter(Mandatory = $true)]$Value,[int]$Depth = 0)
    if ($null -eq $Value -or $Depth -gt 10) { return @() }
    $result = @()
    if ($Value -is [psobject] -and $Value.PSObject.Properties.Name) {
        foreach ($property in $Value.PSObject.Properties) {
            if ($property.Name -match 'StateSha256$' -and $property.Value -is [string] -and $property.Value -match '^[0-9A-Fa-f]{64}$') { $result += [string]$property.Value }
            $result += @(Get-I10StateHashes -Value $property.Value -Depth ($Depth + 1))
        }
    } elseif ($Value -is [System.Collections.IEnumerable] -and $Value -isnot [string]) {
        foreach ($item in $Value) { $result += @(Get-I10StateHashes -Value $item -Depth ($Depth + 1)) }
    }
    return @($result | Sort-Object -Unique)
}

function Get-I10GateReport {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$ExpectedLanguage,
        [Parameter(Mandatory = $true)][string]$ExpectedSourceCommit,
        [Parameter(Mandatory = $true)][string]$ExpectedSourceTree,
        [Parameter(Mandatory = $true)]$Package,
        [Parameter(Mandatory = $true)][string]$PerformanceSha256,
        [Parameter(Mandatory = $true)][string]$SoakSha256
    )
    $gate = Get-I10Lines -Path $Path
    $fields = $gate.Fields
    Assert-I10FieldEqual $fields @('Result') 'PASS' 'Runtime gate result'
    Assert-I10FieldEqual $fields @('EvidenceClass') 'Runtime' 'Runtime gate evidence class'
    Assert-I10FieldEqual $fields @('SessionControlInvoked') 'false' 'Runtime gate session-control boundary'
    Assert-I10FieldEqual $fields @('SeparateSessionSockets') 'true' 'Runtime gate separate-session boundary'
    foreach ($name in @('ExpectedSourceCommit','SourceCommit','PreRunSourceCommit','PostRunSourceCommit')) { Assert-I10FieldEqual $fields @($name) $ExpectedSourceCommit "$name" }
    foreach ($name in @('ExpectedSourceTree','SourceTree','PreRunSourceTree','PostRunSourceTree')) { Assert-I10FieldEqual $fields @($name) $ExpectedSourceTree "$name" }
    Assert-I10FieldEqual $fields @('PreRunGitTreeClean') 'True' 'Runtime gate pre-run clean state'
    Assert-I10FieldEqual $fields @('PostRunGitTreeClean') 'True' 'Runtime gate post-run clean state'
    Assert-I10FieldEqual $fields @('Language') $ExpectedLanguage 'Runtime gate language'
    foreach ($pair in @(
        @('PackageIdentityReceiptSha256', [string]$Package.ReceiptSha256),
        @('PackageArchiveSha256', [string]$Package.ArchiveSha256),
        @('PackageManifestSha256', [string]$Package.ManifestSha256),
        @('AppSha256', [string]$Package.AppSha256),
        @('CoreSha256', [string]$Package.CoreSha256)
    )) { Assert-I10FieldEqual $fields @([string]$pair[0]) ([string]$pair[1]) "Runtime package binding $($pair[0])" }
    $herdrHash = Get-I10Field -Fields $fields -Names @('HerdrExecutableSha256') -Context 'Runtime Herdr executable hash'
    Assert-I10Sha256 $herdrHash 'Runtime Herdr executable hash'
    foreach ($name in @('TargetAgentSessionReference','AcceptanceControlSession','TargetAgentLabSession')) {
        $value = Get-I10Field -Fields $fields -Names @($name) -Context "Runtime $name"
        if ([string]::IsNullOrWhiteSpace($value) -or $value -match '^(NOT_OBSERVED|NOT CLAIMED)$') { throw "Runtime $name is not bound to an observed/attested identity." }
    }
    foreach ($name in @('SnapshotObserved','EventObserved','ReconnectObserved','DashboardClosed','UpdateAfterDashboardClose')) { Assert-I10FieldEqual $fields @($name) 'True' "Runtime semantic flag $name" }
    Assert-I10FieldEqual $fields @('CoreAcceptedEventKindCheck') 'PASS' 'Runtime event-kind check'
    Assert-I10FieldEqual $fields @('SemanticCaptureBindingCheck') 'PASS' 'Runtime semantic capture check'
    $latency = [double](Get-I10Field -Fields $fields -Names @('WidgetLatencyP95Ms','WidgetLatencyP95Milliseconds') -Context 'Runtime Widget latency p95')
    if ($latency -gt $script:I10ApprovedLimits.WidgetLatencyP95Milliseconds) { throw 'Runtime Widget latency p95 exceeds the governed 250 ms limit.' }
    $cpu = [double](Get-I10Field -Fields $fields -Names @('CombinedIdleCpuPercent') -Context 'Runtime combined CPU')
    if ($cpu -gt $script:I10ApprovedLimits.CpuMaximumPercent) { throw 'Runtime combined CPU exceeds the governed 1% limit.' }
    $workingSet = [double](Get-I10Field -Fields $fields -Names @('CombinedMaximumWorkingSetMB') -Context 'Runtime maximum working set')
    if ($workingSet -gt $script:I10ApprovedLimits.WorkingSetMaximumMegabytes) { throw 'Runtime combined maximum working set exceeds 255 MiB.' }
    $targetBytes = [long](Get-I10Field -Fields $fields -Names @('IdleWorkingSetTargetBytes') -Context 'Runtime working-set target')
    if ($targetBytes -ne $script:I10ApprovedLimits.WorkingSetMaximumBytes) { throw 'Runtime working-set target is not the governed 255 MiB byte value.' }
    $generated = Get-I10Field -Fields $fields -Names @('GeneratedUtc') -Context 'Runtime gate timestamp'
    $generatedUtc = Assert-I10Utc $generated 'Runtime gate GeneratedUtc'
    $appPathValue = Get-I10Field -Fields $fields -Names @('AppRuntimeReportPath','AppRuntimeReport') -Context 'Runtime App report path'
    $corePathValue = Get-I10Field -Fields $fields -Names @('CoreRuntimeReportPath','CoreRuntimeReport') -Context 'Runtime Core report path'
    $gateDirectory = Split-Path -Parent ([IO.Path]::GetFullPath($Path))
    $appPath = if ([IO.Path]::IsPathRooted($appPathValue)) { [IO.Path]::GetFullPath($appPathValue) } else { [IO.Path]::GetFullPath((Join-Path $gateDirectory $appPathValue)) }
    $corePath = if ([IO.Path]::IsPathRooted($corePathValue)) { [IO.Path]::GetFullPath($corePathValue) } else { [IO.Path]::GetFullPath((Join-Path $gateDirectory $corePathValue)) }
    $appHeld = Read-I10StrictJson -Path $appPath -Context 'Runtime App report'
    $coreHeld = Read-I10StrictJson -Path $corePath -Context 'Runtime Core report'
    $appReportedSha = Get-I10Field -Fields $fields -Names @('AppRuntimeReportSha256') -Context 'Runtime App report hash'
    $coreReportedSha = Get-I10Field -Fields $fields -Names @('CoreRuntimeReportSha256') -Context 'Runtime Core report hash'
    if ($appHeld.Held.Sha256 -cne $appReportedSha.ToUpperInvariant() -or $coreHeld.Held.Sha256 -cne $coreReportedSha.ToUpperInvariant()) { throw 'Runtime App/Core report hash does not match the held report bytes.' }
    $app = $appHeld.Value
    $core = $coreHeld.Value
    Assert-I10FieldEqual ([pscustomobject]@{ EvidenceClassification = [string]$app.EvidenceClassification }) @('EvidenceClassification') 'RuntimeCandidate' 'App report evidence class'
    if ([string]$core.EvidenceClassification -cne 'Runtime' -or -not [bool]$core.RuntimeObserved -or -not [bool]$core.SnapshotObserved -or -not [bool]$core.EventObserved -or -not [bool]$core.ReconnectObserved -or [bool]$core.SessionControlInvoked) { throw 'Core report did not prove the required actual-Herdr runtime flags.' }
    foreach ($flag in @('CoreStateObserved','DashboardClosed','UpdateObservedAfterDashboardClose','CoreConnectedAfterDashboardClose','DisconnectObservedAfterDashboardClose','ReconnectObservedAfterDashboardClose','LanguageStableThroughFinish')) { if (-not [bool]$app.$flag) { throw "App report semantic flag '$flag' is not true." } }
    if ([string]$app.Language -cne $ExpectedLanguage -or [string]$app.FinalLanguage -cne $ExpectedLanguage -or [int]$app.LanguageChangeCount -ne 0 -or [bool]$app.SessionControlInvoked) { throw 'App report language or session binding is invalid.' }
    if ($null -ne $app.WidgetLatencyP95Milliseconds -and [double]$app.WidgetLatencyP95Milliseconds -gt $script:I10ApprovedLimits.WidgetLatencyP95Milliseconds) { throw 'App report Widget latency p95 exceeds 250 ms.' }
    if ($null -ne $app.ResourceMeasurement) {
        if ([double]$app.ResourceMeasurement.CpuTargetPercent -ne 1 -or [long]$app.ResourceMeasurement.WorkingSetTargetBytes -ne $script:I10ApprovedLimits.WorkingSetMaximumBytes -or [double]$app.ResourceMeasurement.CombinedMaximumWorkingSetMegabytes -gt 255 -or [double]$app.ResourceMeasurement.CombinedAverageCpuPercent -gt 1 -or -not [bool]$app.ResourceMeasurement.CpuTargetPassed -or -not [bool]$app.ResourceMeasurement.WorkingSetTargetPassed) { throw 'App resource evidence does not satisfy governed 1% CPU / 255 MiB limits.' }
    }
    $stateHashes = @(Get-I10StateHashes -Value $app) + @(Get-I10StateHashes -Value $core) | Sort-Object -Unique
    if (@($stateHashes).Count -lt 3) { throw 'Runtime reports did not expose at least three exact state hashes for widget matching.' }
    [pscustomobject][ordered]@{
        Path = [IO.Path]::GetFullPath($Path)
        Hash = $gate.Hash
        GeneratedUtc = $generatedUtc
        AppPath = $appPath
        AppHash = $appHeld.Held.Sha256
        CorePath = $corePath
        CoreHash = $coreHeld.Held.Sha256
        HerdrExecutableSha256 = $herdrHash.ToUpperInvariant()
        ControlSession = Get-I10Field -Fields $fields -Names @('AcceptanceControlSession') -Context 'Runtime control session'
        TargetSession = Get-I10Field -Fields $fields -Names @('TargetAgentLabSession') -Context 'Runtime target session'
        StateHashes = @($stateHashes)
        SourceCommit = $ExpectedSourceCommit
        SourceTree = $ExpectedSourceTree
        PerformanceSha256 = $PerformanceSha256
        SoakSha256 = $SoakSha256
        App = $app
        Core = $core
    }
}

function Assert-I10ReceiptProvenance {
    param([Parameter(Mandatory = $true)]$Provenance,[Parameter(Mandatory = $true)][string]$ExpectedSourceCommit,[Parameter(Mandatory = $true)][string]$ExpectedSourceTree,[Parameter(Mandatory = $true)]$Package,[Parameter(Mandatory = $true)][string]$Context)
    if ($null -eq $Provenance -or $Provenance -isnot [psobject]) { throw "$Context must be a JSON object." }
    $commit = $null; $tree = $null; $archive = $null; $app = $null; $core = $null
    if ($Provenance.PSObject.Properties.Name -contains 'sourceCommit') {
        $commit = [string]$Provenance.sourceCommit; $tree = [string]$Provenance.sourceTree; $receipt = [string]$Provenance.packageIdentityReceiptSha256; $archive = [string]$Provenance.packageArchiveSha256; $app = [string]$Provenance.appSha256; $core = [string]$Provenance.coreSha256
        if ($commit -cne $ExpectedSourceCommit -or $tree -cne $ExpectedSourceTree) { throw "$Context source commit/tree is not bound to the requested candidate." }
        Assert-I10Sha256 $receipt "$Context package identity receipt"
        if ($receipt.ToUpperInvariant() -cne [string]$Package.ReceiptSha256.ToUpperInvariant() -and
            $receipt.ToUpperInvariant() -cne [string]$Package.IdentityFileSha256.ToUpperInvariant()) {
            throw "$Context package identity receipt hash is not bound to the package."
        }
        foreach ($pair in @(@('package archive',$archive,[string]$Package.ArchiveSha256),@('App',$app,[string]$Package.AppSha256),@('Core',$core,[string]$Package.CoreSha256))) { Assert-I10Sha256 $pair[1] "$Context $($pair[0])"; if ($pair[1].ToUpperInvariant() -cne $pair[2].ToUpperInvariant()) { throw "$Context $($pair[0]) hash is not bound to the package." } }
    } elseif ($Provenance.PSObject.Properties.Name -contains 'candidate' -and $Provenance.PSObject.Properties.Name -contains 'package') {
        $commit = [string]$Provenance.candidate.commitSha; $tree = [string]$Provenance.candidate.treeSha
        if ($commit -cne $ExpectedSourceCommit -or $tree -cne $ExpectedSourceTree) { throw "$Context source commit/tree is not bound to the requested candidate." }
        $archive = [string]$Provenance.package.archive.sha256; $app = [string]$Provenance.package.components.app.sha256; $core = [string]$Provenance.package.components.core.sha256
        foreach ($pair in @(@('package archive',$archive,[string]$Package.ArchiveSha256),@('App',$app,[string]$Package.AppSha256),@('Core',$core,[string]$Package.CoreSha256))) { Assert-I10Sha256 $pair[1] "$Context $($pair[0])"; if ($pair[1].ToUpperInvariant() -cne $pair[2].ToUpperInvariant()) { throw "$Context $($pair[0]) hash is not bound to the package." } }
        $pkgReceipt = $Provenance.package.receipt
        if ($null -eq $pkgReceipt -or $pkgReceipt -isnot [psobject]) { throw "$Context package receipt binding is missing." }
        $hasFileSha = ($null -ne $pkgReceipt.PSObject.Properties['fileSha256'] -and -not [string]::IsNullOrWhiteSpace([string]$pkgReceipt.fileSha256))
        $hasCanonicalSha = ($null -ne $pkgReceipt.PSObject.Properties['canonicalSha256'] -and -not [string]::IsNullOrWhiteSpace([string]$pkgReceipt.canonicalSha256))
        if (-not $hasFileSha -and -not $hasCanonicalSha) { throw "$Context package receipt must specify fileSha256 or canonicalSha256." }
        if ($hasFileSha) {
            Assert-I10Sha256 $pkgReceipt.fileSha256 "$Context package identity receipt fileSha256"
            if ($pkgReceipt.fileSha256.ToUpperInvariant() -cne [string]$Package.IdentityFileSha256.ToUpperInvariant() -and
                $pkgReceipt.fileSha256.ToUpperInvariant() -cne [string]$Package.ReceiptSha256.ToUpperInvariant()) {
                throw "$Context package identity receipt fileSha256 is not bound to the package."
            }
        }
        if ($hasCanonicalSha) {
            Assert-I10Sha256 $pkgReceipt.canonicalSha256 "$Context package identity receipt canonicalSha256"
            if ($pkgReceipt.canonicalSha256.ToUpperInvariant() -cne [string]$Package.ReceiptSha256.ToUpperInvariant() -and
                $pkgReceipt.canonicalSha256.ToUpperInvariant() -cne [string]$Package.IdentityCanonicalSha256.ToUpperInvariant()) {
                throw "$Context package identity receipt canonicalSha256 is not bound to the package."
            }
        }
    } else { throw "$Context has no supported governed provenance shape." }
}

function Assert-I10PerformanceReceipt {
    param([Parameter(Mandatory = $true)][string]$Path,[Parameter(Mandatory = $true)][string]$EvidenceRoot,[Parameter(Mandatory = $true)][string]$ExpectedSourceCommit,[Parameter(Mandatory = $true)][string]$ExpectedSourceTree,[Parameter(Mandatory = $true)]$Package)
    $read = Read-I10StrictJson -Path $Path -Context 'Issue #10 raw AB/BA performance receipt'
    $value = $read.Value
    Assert-I10ExactProperties $value @('provenance','rawSource','orders','soakBins','aggregateStatus') 'Issue #10 performance receipt'
    if ([string]$value.aggregateStatus -cne 'PASS') { throw 'Performance receipt aggregateStatus is not PASS.' }
    Assert-I10ReceiptProvenance -Provenance $value.provenance -ExpectedSourceCommit $ExpectedSourceCommit -ExpectedSourceTree $ExpectedSourceTree -Package $Package -Context 'Performance receipt provenance'
    Assert-I10ExactProperties $value.rawSource @('relativePath','bytes','fileSha256','canonicalSha256') 'Performance rawSource binding'
    Assert-I10String $value.rawSource.relativePath 'Performance rawSource relativePath'; Assert-I10Integer $value.rawSource.bytes 'Performance rawSource bytes'; Assert-I10Sha256 $value.rawSource.fileSha256 'Performance rawSource fileSha256'; Assert-I10Sha256 $value.rawSource.canonicalSha256 'Performance rawSource canonicalSha256'
    $rawPath = Resolve-I10ContainedPath -Root $EvidenceRoot -RelativePath ([string]$value.rawSource.relativePath) -Context 'Performance rawSource path'
    $raw = Read-I10StrictJson -Path $rawPath -Context 'Performance raw observations'
    if ($raw.Held.Length -ne [long]$value.rawSource.bytes -or $raw.Held.Sha256 -cne [string]$value.rawSource.fileSha256.ToUpperInvariant()) { throw 'Performance rawSource binding does not match held bytes.' }
    if ((Get-I10CanonicalSha256 -Value $raw.Value) -cne [string]$value.rawSource.canonicalSha256.ToUpperInvariant()) { throw 'Performance rawSource canonical hash does not match its parsed object.' }
    if ((Get-I10CanonicalSha256 -Value $raw.Value.orders) -ne (Get-I10CanonicalSha256 -Value $value.orders) -or
        (Get-I10CanonicalSha256 -Value $raw.Value.soakBins) -ne (Get-I10CanonicalSha256 -Value $value.soakBins)) { throw 'Performance receipt aggregate fields are not byte-bound to the held raw observations.' }
    $orders = @($value.orders); if ($orders.Count -ne 2) { throw 'Performance receipt must contain exactly AB then BA orders.' }
    foreach ($index in 0..1) {
        $order = $orders[$index]; $expected = @('AB','BA')[$index]
        Assert-I10ExactProperties $order @('order','warmup','repetitions') "Performance order $expected"
        if ([string]$order.order -cne $expected -or @($order.warmup).Count -ne 1 -or @($order.repetitions).Count -ne 5) { throw "Performance order $expected has invalid warmup/repetition counts." }
        $samples = @($order.warmup) + @($order.repetitions)
        foreach ($rep in $samples) {
            foreach ($mode in @('a','b')) {
                $sample = $rep.$mode; Assert-I10ExactProperties $sample @('cpuBasisPoints','workingSetMaximumBytes','latencyMicroseconds','uiStallMicroseconds') "Performance $expected $mode sample"
                Assert-I10Integer $sample.cpuBasisPoints "Performance $expected $mode CPU" -AllowZero; Assert-I10Integer $sample.workingSetMaximumBytes "Performance $expected $mode working set" -AllowZero
                if ([long]$sample.cpuBasisPoints -gt 100 -or [long]$sample.workingSetMaximumBytes -gt $script:I10ApprovedLimits.WorkingSetMaximumBytes) { throw "Performance $expected $mode breached CPU or working-set limit." }
                foreach ($metric in @(@('latencyMicroseconds',250000),@('uiStallMicroseconds',100000))) {
                    $observations = @($sample.($metric[0])); if ($observations.Count -ne 20) { throw "Performance $expected $mode $($metric[0]) must contain exactly 20 raw observations." }
                    foreach ($observation in $observations) { Assert-I10Integer $observation "Performance $expected $mode $($metric[0]) observation" -AllowZero; if ([long]$observation -gt [long]$metric[1]) { throw "Performance $expected $mode $($metric[0]) exceeded its absolute bound." } }
                    $sorted = @($observations | Sort-Object { [long]$_ }); $p95 = [long]$sorted[[Math]::Ceiling($sorted.Count * 0.95) - 1]
                    if ($metric[0] -ceq 'latencyMicroseconds' -and $p95 -gt 250000) { throw 'Performance latency p95 exceeded 250 ms.' }
                    if ($metric[0] -ceq 'uiStallMicroseconds' -and $p95 -gt 50000) { throw 'Performance UI-stall p95 exceeded 50 ms.' }
                }
            }
        }
    }
    [pscustomobject][ordered]@{ Path = [IO.Path]::GetFullPath($Path); Hash = $read.Held.Sha256; RawSourcePath = $rawPath; RawSourceHash = $raw.Held.Sha256 }
}

function Assert-I10SoakReceipt {
    param([Parameter(Mandatory = $true)][string]$Path,[Parameter(Mandatory = $true)][string]$ExpectedSourceCommit,[Parameter(Mandatory = $true)][string]$ExpectedSourceTree,[Parameter(Mandatory = $true)]$Package)
    $read = Read-I10StrictJson -Path $Path -Context 'Issue #10 AC/Battery soak receipt'; $value = $read.Value
    Assert-I10ExactProperties $value @('provenance','soakBins','aggregateStatus') 'Issue #10 soak receipt'
    if ([string]$value.aggregateStatus -cne 'PASS') { throw 'Soak receipt aggregateStatus is not PASS.' }
    Assert-I10ReceiptProvenance -Provenance $value.provenance -ExpectedSourceCommit $ExpectedSourceCommit -ExpectedSourceTree $ExpectedSourceTree -Package $Package -Context 'Soak receipt provenance'
    $bins = @($value.soakBins); if ($bins.Count -ne 24) { throw 'Soak receipt must contain exactly 24 bins.' }
    foreach ($index in 0..23) {
        $bin = $bins[$index]; Assert-I10ExactProperties $bin @('powerSource','ordinal','durationMinutes','observedUtc','workingSetStartBytes','workingSetEndBytes','rendererStable') "Soak bin $index"
        $power = if ($index -lt 12) { 'AC' } else { 'Battery' }; $ordinal = $index % 12
        if ([string]$bin.powerSource -cne $power -or [int]$bin.ordinal -ne $ordinal -or [int]$bin.durationMinutes -ne 5 -or -not [bool]$bin.rendererStable) { throw "Soak bin $index is not the governed $power/5-minute PASS bin." }
        Assert-I10Utc $bin.observedUtc "Soak bin $index observedUtc" | Out-Null
        Assert-I10Integer $bin.workingSetStartBytes "Soak bin $index start working set" -AllowZero; Assert-I10Integer $bin.workingSetEndBytes "Soak bin $index end working set" -AllowZero
        if ([long]$bin.workingSetStartBytes -gt $script:I10ApprovedLimits.WorkingSetMaximumBytes -or [long]$bin.workingSetEndBytes -gt $script:I10ApprovedLimits.WorkingSetMaximumBytes) { throw "Soak bin $index exceeded 255 MiB." }
        if ([math]::Abs([double]$bin.workingSetEndBytes - [double]$bin.workingSetStartBytes) * 2 -gt $script:I10ApprovedLimits.ResourceSlopeMaximumBytesPerTenMinutes) { throw "Soak bin $index exceeded the governed resource slope." }
    }
    [pscustomobject][ordered]@{ Path = [IO.Path]::GetFullPath($Path); Hash = $read.Held.Sha256; AcMinutes = 60; BatteryMinutes = 60 }
}

function Assert-I10Capture {
    param([Parameter(Mandatory = $true)][string]$Root,[Parameter(Mandatory = $true)][string]$RelativePath,[Parameter(Mandatory = $true)][long]$ExpectedBytes,[Parameter(Mandatory = $true)][string]$ExpectedSha256,[Parameter(Mandatory = $true)][string]$Context)
    Assert-I10Integer $ExpectedBytes "$Context declared bytes"
    $path = Resolve-I10ContainedPath -Root $Root -RelativePath $RelativePath -Context "$Context path"
    $held = Read-I10HeldFile -Path $path -MaximumBytes 134217728 -Context $Context
    if ($held.Length -ne $ExpectedBytes -or $held.Sha256 -cne $ExpectedSha256.ToUpperInvariant()) { throw "$Context capture bytes/hash do not match the held file." }
    if ([IO.Path]::GetExtension($path) -ine '.png') { throw "$Context capture must be a PNG path." }
    return [pscustomobject][ordered]@{ Path = $path; Bytes = $held.Length; Sha256 = $held.Sha256; FileId = $held.FileId; LinkCount = $held.LinkCount }
}

function Assert-I10WidgetReport {
    param([Parameter(Mandatory = $true)][string]$Path,[Parameter(Mandatory = $true)][string]$ExpectedLanguage,[Parameter(Mandatory = $true)][string]$ExpectedSourceCommit,[Parameter(Mandatory = $true)][string]$ExpectedSourceTree,[Parameter(Mandatory = $true)]$Runtime,[Parameter(Mandatory = $true)]$Performance,[Parameter(Mandatory = $true)]$Soak,[Parameter(Mandatory = $true)]$Package)
    $read = Read-I10StrictJson -Path $Path -Context "Issue #10 $ExpectedLanguage widget evidence"; $value = $read.Value
    Assert-I10ExactProperties $value @('SchemaVersion','EvidenceClassification','Issue','Language','Source','Bindings','Chronology','Dashboard','Widgets','AttentionStates','UnknownPolicy') "Issue #10 $ExpectedLanguage widget evidence"
    if ([int]$value.SchemaVersion -ne 1 -or [string]$value.EvidenceClassification -cne 'Issue10WidgetObservation' -or [int]$value.Issue -ne 10 -or [string]$value.Language -cne $ExpectedLanguage) { throw "Issue #10 $ExpectedLanguage widget evidence identity is invalid." }
    Assert-I10ExactProperties $value.Source @('CommitSha','TreeSha') "Issue #10 $ExpectedLanguage source"; if ([string]$value.Source.CommitSha -cne $ExpectedSourceCommit -or [string]$value.Source.TreeSha -cne $ExpectedSourceTree) { throw "Issue #10 $ExpectedLanguage widget source is not exact." }
    Assert-I10ExactProperties $value.Bindings @('GateReportSha256','AppRuntimeReportSha256','CoreRuntimeReportSha256','PackageIdentityReceiptSha256','PackageArchiveSha256','PackageManifestSha256','AppSha256','CoreSha256','HerdrExecutableSha256','PerformanceReceiptSha256','SoakReceiptSha256','ControlSessionIdentity','TargetSessionIdentity') "Issue #10 $ExpectedLanguage bindings"
    foreach ($name in @('GateReportSha256','AppRuntimeReportSha256','CoreRuntimeReportSha256','PackageIdentityReceiptSha256','PackageArchiveSha256','PackageManifestSha256','AppSha256','CoreSha256','HerdrExecutableSha256','PerformanceReceiptSha256','SoakReceiptSha256')) { Assert-I10Sha256 $value.Bindings.$name "Issue #10 $ExpectedLanguage binding $name" }
    $expectedBindings = [ordered]@{ GateReportSha256 = $Runtime.Hash; AppRuntimeReportSha256 = $Runtime.AppHash; CoreRuntimeReportSha256 = $Runtime.CoreHash; PackageIdentityReceiptSha256 = $Package.ReceiptSha256; PackageArchiveSha256 = $Package.ArchiveSha256; PackageManifestSha256 = $Package.ManifestSha256; AppSha256 = $Package.AppSha256; CoreSha256 = $Package.CoreSha256; HerdrExecutableSha256 = $Runtime.HerdrExecutableSha256; PerformanceReceiptSha256 = $Performance.Hash; SoakReceiptSha256 = $Soak.Hash }
    foreach ($name in $expectedBindings.Keys) { if ([string]$value.Bindings.$name -cne [string]$expectedBindings[$name]) { throw "Issue #10 $ExpectedLanguage binding $name is not cross-bound." } }
    if ([string]$value.Bindings.ControlSessionIdentity -cne [string]$Runtime.ControlSession -or [string]$value.Bindings.TargetSessionIdentity -cne [string]$Runtime.TargetSession) { throw "Issue #10 $ExpectedLanguage control/target session binding is not exact." }
    Assert-I10ExactProperties $value.Chronology @('RuntimeStartUtc','DashboardObservedUtc','WidgetObservedUtc','CapturedUtc','StateSequence') "Issue #10 $ExpectedLanguage chronology"
    $times = @(); foreach ($name in @('RuntimeStartUtc','DashboardObservedUtc','WidgetObservedUtc','CapturedUtc')) { $times += ,(Assert-I10Utc $value.Chronology.$name "Issue #10 $ExpectedLanguage $name") }; for ($i = 1; $i -lt $times.Count; $i++) { if ($times[$i] -lt $times[$i - 1]) { throw "Issue #10 $ExpectedLanguage chronology moved backward." } }
    Assert-I10Integer $value.Chronology.StateSequence 'Issue #10 widget StateSequence'; if ([long]$value.Chronology.StateSequence -le 0) { throw 'Issue #10 widget StateSequence must be positive.' }
    $widgetRoot = Split-Path -Parent ([IO.Path]::GetFullPath($Path))
    Assert-I10ExactProperties $value.Dashboard @('StateSha256','CapturePath','CaptureBytes','CaptureSha256') "Issue #10 $ExpectedLanguage Dashboard"
    Assert-I10Sha256 $value.Dashboard.StateSha256 "Issue #10 $ExpectedLanguage Dashboard state"; if (@($Runtime.StateHashes) -notcontains [string]$value.Dashboard.StateSha256) { throw "Issue #10 $ExpectedLanguage Dashboard state is not in the runtime state hash set." }
    $dashboardCapture = Assert-I10Capture -Root $widgetRoot -RelativePath ([string]$value.Dashboard.CapturePath) -ExpectedBytes ([long]$value.Dashboard.CaptureBytes) -ExpectedSha256 ([string]$value.Dashboard.CaptureSha256) -Context "Issue #10 $ExpectedLanguage Dashboard capture"
    $widgets = @($value.Widgets); if ($widgets.Count -ne 3) { throw "Issue #10 $ExpectedLanguage must have exactly three widget captures." }
    $seen = @{}
    foreach ($widget in $widgets) {
        Assert-I10ExactProperties $widget @('Name','StateSha256','SourceStateSha256','CapturePath','CaptureBytes','CaptureSha256') "Issue #10 $ExpectedLanguage widget"
        if ($widget.Name -notin @('Compact','Normal','FloatingVertical') -or $seen.ContainsKey([string]$widget.Name)) { throw "Issue #10 $ExpectedLanguage has an unknown or duplicate widget name." }
        $seen[[string]$widget.Name] = $true; Assert-I10Sha256 $widget.StateSha256 "Issue #10 $ExpectedLanguage widget state"; Assert-I10Sha256 $widget.SourceStateSha256 "Issue #10 $ExpectedLanguage widget source state"
        if ([string]$widget.StateSha256 -cne [string]$value.Dashboard.StateSha256 -or [string]$widget.SourceStateSha256 -cne [string]$value.Dashboard.StateSha256) { throw "Issue #10 $ExpectedLanguage widget state does not equal Dashboard state." }
        if (@($Runtime.StateHashes) -notcontains [string]$widget.StateSha256) { throw "Issue #10 $ExpectedLanguage widget state is not runtime-bound." }
        Assert-I10Capture -Root $widgetRoot -RelativePath ([string]$widget.CapturePath) -ExpectedBytes ([long]$widget.CaptureBytes) -ExpectedSha256 ([string]$widget.CaptureSha256) -Context "Issue #10 $ExpectedLanguage $($widget.Name) capture" | Out-Null
    }
    $attention = @($value.AttentionStates); if ($attention.Count -ne 2) { throw "Issue #10 $ExpectedLanguage must have exactly Blocked and Done attention states." }
    $fingerprints = @{}; $statuses = @{}
    foreach ($item in $attention) {
        Assert-I10ExactProperties $item @('Name','Status','SemanticFingerprint','CapturePath','CaptureBytes','CaptureSha256') "Issue #10 $ExpectedLanguage attention state"
        if ($item.Name -notin @('Blocked','Done') -or $item.Status -notin @('Blocked','Done') -or $item.Name -cne $item.Status -or $statuses.ContainsKey([string]$item.Status)) { throw 'Issue #10 attention states are missing, duplicate, or mislabeled.' }
        Assert-I10Sha256 $item.SemanticFingerprint 'Issue #10 attention semantic fingerprint'; if ($fingerprints.ContainsKey([string]$item.SemanticFingerprint)) { throw 'Blocked and Done attention states collapse to one semantic fingerprint.' }
        $fingerprints[[string]$item.SemanticFingerprint] = $true; $statuses[[string]$item.Status] = $true
        Assert-I10Capture -Root $widgetRoot -RelativePath ([string]$item.CapturePath) -ExpectedBytes ([long]$item.CaptureBytes) -ExpectedSha256 ([string]$item.CaptureSha256) -Context "Issue #10 $($item.Status) attention capture" | Out-Null
    }
    Assert-I10ExactProperties $value.UnknownPolicy @('UnknownDataRendersUnknown','OfflineDataRendersUnknown','UnknownState','OfflineState','NoSyntheticSuccess','SyntheticFieldsCount') 'Issue #10 unknown-data policy'
    foreach ($name in @('UnknownDataRendersUnknown','OfflineDataRendersUnknown','NoSyntheticSuccess')) { Assert-I10Boolean $value.UnknownPolicy.$name "Issue #10 unknown policy $name"; if (-not [bool]$value.UnknownPolicy.$name) { throw "Issue #10 unknown policy $name must be true." } }
    foreach ($name in @('UnknownState','OfflineState')) { if ([string]::IsNullOrWhiteSpace([string]$value.UnknownPolicy.$name) -or [string]$value.UnknownPolicy.$name -in @('PASS','Success','Done')) { throw "Issue #10 unknown policy $name is unsafe." } }
    Assert-I10Integer $value.UnknownPolicy.SyntheticFieldsCount 'Issue #10 unknown policy synthetic field count' -AllowZero; if ([int]$value.UnknownPolicy.SyntheticFieldsCount -ne 0) { throw 'Issue #10 widget evidence contains synthetic success fields.' }
    [pscustomobject][ordered]@{ Path = [IO.Path]::GetFullPath($Path); Hash = $read.Held.Sha256; Language = $ExpectedLanguage; StateSha256 = [string]$value.Dashboard.StateSha256; WidgetStateSha256 = [string]$value.Widgets[0].StateSha256; Value = $value }
}

function Assert-I10PackageBinding {
    param([Parameter(Mandatory = $true)]$Package,[Parameter(Mandatory = $true)][string]$ExpectedSourceCommit,[Parameter(Mandatory = $true)][string]$ExpectedSourceTree)
    foreach ($name in @('IdentityPath','ArchivePath','PackageRoot','ManifestPath','AppPath','CorePath','ReceiptSha256','ArchiveSha256','ManifestSha256','AppSha256','CoreSha256')) { if ($null -eq $Package.PSObject.Properties[$name]) { throw "Package binding omitted '$name'." } }
    Assert-I10Sha256 $Package.ReceiptSha256 'Package receipt SHA-256'; Assert-I10Sha256 $Package.ArchiveSha256 'Package archive SHA-256'; Assert-I10Sha256 $Package.ManifestSha256 'Package manifest SHA-256'; Assert-I10Sha256 $Package.AppSha256 'Package App SHA-256'; Assert-I10Sha256 $Package.CoreSha256 'Package Core SHA-256'
    if ($null -ne $Package.SourceCommit -and [string]$Package.SourceCommit -cne $ExpectedSourceCommit) { throw 'Package source commit is not exact.' }; if ($null -ne $Package.SourceTree -and [string]$Package.SourceTree -cne $ExpectedSourceTree) { throw 'Package source tree is not exact.' }
    $root = [IO.Path]::GetFullPath([string]$Package.PackageRoot); Assert-I10NoReparsePath -Root $root -Path $root -Context 'Package root'
    foreach ($pair in @(@('manifest',$Package.ManifestPath),@('App',$Package.AppPath),@('Core',$Package.CorePath))) { Assert-I10NoReparsePath -Root $root -Path ([string]$pair[1]) -Context "Package $($pair[0]) path" }

    $identity = Read-I10HeldFile -Path ([string]$Package.IdentityPath) -MaximumBytes 16777216 -Context 'Package identity receipt'
    $archive = Read-I10HeldFile -Path ([string]$Package.ArchivePath) -MaximumBytes 1073741824 -Context 'Package archive'
    $manifest = Read-I10HeldFile -Path ([string]$Package.ManifestPath) -MaximumBytes 67108864 -Context 'Package manifest'
    $app = Read-I10HeldFile -Path ([string]$Package.AppPath) -MaximumBytes 1073741824 -Context 'Package App'
    $core = Read-I10HeldFile -Path ([string]$Package.CorePath) -MaximumBytes 1073741824 -Context 'Package Core'

    if ($identity.Bytes.Length -ge 3 -and $identity.Bytes[0] -eq 0xEF -and $identity.Bytes[1] -eq 0xBB -and $identity.Bytes[2] -eq 0xBF) { throw 'Package identity receipt must be UTF-8 without a BOM.' }
    try { $identityJson = [Text.UTF8Encoding]::new($false, $true).GetString($identity.Bytes) }
    catch { throw 'Package identity receipt contains malformed UTF-8.' }
    if ($identityJson.IndexOf([char]0xFEFF) -ge 0) { throw 'Package identity receipt contains an unexpected BOM.' }
    if (Get-Command Assert-V02NoDuplicateJsonProperties -ErrorAction SilentlyContinue) { Assert-V02NoDuplicateJsonProperties -Json $identityJson -Source ([string]$Package.IdentityPath) }
    try {
        if ($PSVersionTable.PSVersion.Major -ge 7 -and (Get-Command ConvertFrom-Json).Parameters.ContainsKey('DateKind')) {
            $identityValue = $identityJson | ConvertFrom-Json -DateKind String
        } else {
            $identityValue = $identityJson | ConvertFrom-Json
        }
    } catch { throw "Package identity receipt is malformed JSON: $($_.Exception.Message)" }
    if ($null -eq $identityValue -or $identityValue -isnot [pscustomobject]) { throw 'Package identity receipt root must be an object.' }

    $identityCanonicalSha256 = Get-I10CanonicalSha256 -Value $identityValue
    $identityFileSha256 = $identity.Sha256

    if ($null -ne $identityValue.PSObject.Properties['source'] -and $null -ne $identityValue.source) {
        if ($null -ne $identityValue.source.PSObject.Properties['commitSha'] -and [string]$identityValue.source.commitSha -cne $ExpectedSourceCommit) { throw 'Package identity receipt source commit is not exact.' }
        if ($null -ne $identityValue.source.PSObject.Properties['treeSha'] -and [string]$identityValue.source.treeSha -cne $ExpectedSourceTree) { throw 'Package identity receipt source tree is not exact.' }
    }
    if ($null -ne $identityValue.PSObject.Properties['evidenceBoundary'] -and $null -ne $identityValue.evidenceBoundary) {
        if ($identityValue.evidenceBoundary.PSObject.Properties.Name -contains 'runtimeCredit' -and [string]$identityValue.evidenceBoundary.runtimeCredit -cne 'NOT CLAIMED') { throw 'Package identity receipt evidence boundary claims runtime credit.' }
        if ($identityValue.evidenceBoundary.PSObject.Properties.Name -contains 'releaseCredit' -and [string]$identityValue.evidenceBoundary.releaseCredit -cne 'NOT CLAIMED') { throw 'Package identity receipt evidence boundary claims release credit.' }
        if ($identityValue.evidenceBoundary.PSObject.Properties.Name -contains 'actualHerdrUsed' -and [bool]$identityValue.evidenceBoundary.actualHerdrUsed) { throw 'Package identity receipt evidence boundary claims actual Herdr use.' }
    }
    if ($null -ne $identityValue.PSObject.Properties['archive'] -and $null -ne $identityValue.archive -and $identityValue.archive.PSObject.Properties.Name -contains 'sha256') {
        if ([string]$identityValue.archive.sha256.ToUpperInvariant() -cne $archive.Sha256) { throw 'Package identity receipt archive SHA-256 does not match held archive.' }
    }
    if ($null -ne $identityValue.PSObject.Properties['components'] -and $null -ne $identityValue.components) {
        if ($identityValue.components.PSObject.Properties.Name -contains 'app' -and $identityValue.components.app.PSObject.Properties.Name -contains 'sha256') {
            if ([string]$identityValue.components.app.sha256.ToUpperInvariant() -cne $app.Sha256) { throw 'Package identity receipt App SHA-256 does not match held App.' }
        }
        if ($identityValue.components.PSObject.Properties.Name -contains 'core' -and $identityValue.components.core.PSObject.Properties.Name -contains 'sha256') {
            if ([string]$identityValue.components.core.sha256.ToUpperInvariant() -cne $core.Sha256) { throw 'Package identity receipt Core SHA-256 does not match held Core.' }
        }
    }

    $hasExplicitFileHash = ($null -ne $Package.PSObject.Properties['IdentityFileSha256'] -and -not [string]::IsNullOrWhiteSpace([string]$Package.IdentityFileSha256))
    $boundReceiptSha256 = $null
    $boundIdentityFileSha256 = $null

    if ($hasExplicitFileHash) {
        Assert-I10Sha256 $Package.IdentityFileSha256 'Package IdentityFileSha256'
        if ($identityFileSha256 -cne [string]$Package.IdentityFileSha256.ToUpperInvariant()) { throw 'Package identity receipt held file bytes hash does not match IdentityFileSha256.' }
        $boundIdentityFileSha256 = $identityFileSha256
        if ($identityCanonicalSha256 -cne [string]$Package.ReceiptSha256.ToUpperInvariant()) { throw 'Package identity receipt held canonical hash does not match ReceiptSha256.' }
        $boundReceiptSha256 = $identityCanonicalSha256
    } else {
        $callerReceipt = [string]$Package.ReceiptSha256.ToUpperInvariant()
        if ($callerReceipt -ceq $identityCanonicalSha256) {
            $boundReceiptSha256 = $identityCanonicalSha256
            $boundIdentityFileSha256 = $identityFileSha256
        } elseif ($callerReceipt -ceq $identityFileSha256) {
            $boundReceiptSha256 = $identityFileSha256
            $boundIdentityFileSha256 = $identityFileSha256
        } else {
            throw 'Package identity receipt held bytes/canonical hash do not match ReceiptSha256.'
        }
    }

    if ($null -ne $Package.PSObject.Properties['IdentityReceiptSha256'] -and -not [string]::IsNullOrWhiteSpace([string]$Package.IdentityReceiptSha256)) {
        Assert-I10Sha256 $Package.IdentityReceiptSha256 'Package IdentityReceiptSha256'
        if ([string]$Package.IdentityReceiptSha256.ToUpperInvariant() -cne $boundReceiptSha256 -and
            [string]$Package.IdentityReceiptSha256.ToUpperInvariant() -cne $boundIdentityFileSha256) {
            throw 'Package IdentityReceiptSha256 does not match the bound receipt hash.'
        }
    }

    if ($archive.Sha256 -cne [string]$Package.ArchiveSha256.ToUpperInvariant() -or
        $manifest.Sha256 -cne [string]$Package.ManifestSha256.ToUpperInvariant() -or
        $app.Sha256 -cne [string]$Package.AppSha256.ToUpperInvariant() -or
        $core.Sha256 -cne [string]$Package.CoreSha256.ToUpperInvariant()) {
        throw 'Package bytes changed or do not match the bound hashes.'
    }

    return [pscustomobject][ordered]@{
        Identity = $identity
        Archive = $archive
        Manifest = $manifest
        App = $app
        Core = $core
        ReceiptSha256 = $boundReceiptSha256
        IdentityFileSha256 = $boundIdentityFileSha256
        IdentityCanonicalSha256 = $identityCanonicalSha256
        ArchiveSha256 = $archive.Sha256
        ManifestSha256 = $manifest.Sha256
        AppSha256 = $app.Sha256
        CoreSha256 = $core.Sha256
        IdentityValue = $identityValue
    }
}

function Invoke-I10Issue10Acceptance {
    param(
        [Parameter(Mandatory = $true)][string]$EvidenceRoot,
        [Parameter(Mandatory = $true)][string]$ThaiWidgetReportPath,
        [Parameter(Mandatory = $true)][string]$EnglishWidgetReportPath,
        [Parameter(Mandatory = $true)][string]$ThaiRuntimeGatePath,
        [Parameter(Mandatory = $true)][string]$EnglishRuntimeGatePath,
        [Parameter(Mandatory = $true)][string]$PerformanceReceiptPath,
        [Parameter(Mandatory = $true)][string]$SoakReceiptPath,
        [Parameter(Mandatory = $true)][string]$ExpectedSourceCommit,
        [Parameter(Mandatory = $true)][string]$ExpectedSourceTree,
        [Parameter(Mandatory = $true)]$PackageBinding,
        [Parameter(Mandatory = $true)][string]$OutputPath,
        [switch]$FixtureMode
    )
    Assert-I10Commit $ExpectedSourceCommit 'ExpectedSourceCommit'; Assert-I10Commit $ExpectedSourceTree 'ExpectedSourceTree'
    Assert-I10NoReparsePath -Root ([IO.Path]::GetFullPath($EvidenceRoot)) -Path ([IO.Path]::GetFullPath($EvidenceRoot)) -Context 'Issue #10 evidence root'
    foreach ($inputPath in @($ThaiWidgetReportPath,$EnglishWidgetReportPath,$ThaiRuntimeGatePath,$EnglishRuntimeGatePath,$PerformanceReceiptPath,$SoakReceiptPath,$PackageBinding.IdentityPath,$PackageBinding.ArchivePath,$PackageBinding.PackageRoot,$OutputPath)) {
        Assert-I10NoReparsePath -Root ([IO.Path]::GetFullPath($EvidenceRoot)) -Path ([IO.Path]::GetFullPath($inputPath)) -Context 'Issue #10 evidence input'
    }
    $package = Assert-I10PackageBinding -Package $PackageBinding -ExpectedSourceCommit $ExpectedSourceCommit -ExpectedSourceTree $ExpectedSourceTree
    $performance = Assert-I10PerformanceReceipt -Path $PerformanceReceiptPath -EvidenceRoot $EvidenceRoot -ExpectedSourceCommit $ExpectedSourceCommit -ExpectedSourceTree $ExpectedSourceTree -Package $package
    $soak = Assert-I10SoakReceipt -Path $SoakReceiptPath -ExpectedSourceCommit $ExpectedSourceCommit -ExpectedSourceTree $ExpectedSourceTree -Package $package
    $thaiRuntime = Get-I10GateReport -Path $ThaiRuntimeGatePath -ExpectedLanguage 'Thai' -ExpectedSourceCommit $ExpectedSourceCommit -ExpectedSourceTree $ExpectedSourceTree -Package $package -PerformanceSha256 $performance.Hash -SoakSha256 $soak.Hash
    $englishRuntime = Get-I10GateReport -Path $EnglishRuntimeGatePath -ExpectedLanguage 'English' -ExpectedSourceCommit $ExpectedSourceCommit -ExpectedSourceTree $ExpectedSourceTree -Package $package -PerformanceSha256 $performance.Hash -SoakSha256 $soak.Hash
    foreach ($name in @('HerdrExecutableSha256','ControlSession','TargetSession')) { if ([string]$thaiRuntime.$name -cne [string]$englishRuntime.$name) { throw "Thai and English runtime $name bindings differ." } }
    $thaiWidget = Assert-I10WidgetReport -Path $ThaiWidgetReportPath -ExpectedLanguage 'Thai' -ExpectedSourceCommit $ExpectedSourceCommit -ExpectedSourceTree $ExpectedSourceTree -Runtime $thaiRuntime -Performance $performance -Soak $soak -Package $package
    $englishWidget = Assert-I10WidgetReport -Path $EnglishWidgetReportPath -ExpectedLanguage 'English' -ExpectedSourceCommit $ExpectedSourceCommit -ExpectedSourceTree $ExpectedSourceTree -Runtime $englishRuntime -Performance $performance -Soak $soak -Package $package
    if ([string]$thaiWidget.StateSha256 -cne [string]$englishWidget.StateSha256 -or [string]$thaiWidget.WidgetStateSha256 -cne [string]$englishWidget.WidgetStateSha256) { throw 'Thai and English widget candidates do not match the same Dashboard state.' }
    $runtimeInput = 'OBSERVED_AND_BOUND'
    if ($FixtureMode) { $runtimeInput = 'SYNTHETIC_FIXTURE_BOUND' }
    $candidate = [pscustomobject][ordered]@{
        SchemaVersion = 1
        EvidenceClassification = 'Issue10RuntimeCandidate'
        Issue = 10
        Result = 'PASS'
        Source = [pscustomobject][ordered]@{ CommitSha = $ExpectedSourceCommit; TreeSha = $ExpectedSourceTree }
        Package = [pscustomobject][ordered]@{ IdentityReceiptSha256 = $package.ReceiptSha256; ArchiveSha256 = $package.ArchiveSha256; ManifestSha256 = $package.ManifestSha256; AppSha256 = $package.AppSha256; CoreSha256 = $package.CoreSha256 }
        Runtime = [pscustomobject][ordered]@{ ThaiGateSha256 = $thaiRuntime.Hash; EnglishGateSha256 = $englishRuntime.Hash; AppReportSha256 = [string]$thaiRuntime.AppHash; CoreReportSha256 = [string]$thaiRuntime.CoreHash; HerdrExecutableSha256 = $thaiRuntime.HerdrExecutableSha256; ControlSession = $thaiRuntime.ControlSession; TargetSession = $thaiRuntime.TargetSession; StateHashes = @($thaiRuntime.StateHashes) }
        Performance = [pscustomobject][ordered]@{ ReceiptPath = $performance.Path; ReceiptSha256 = $performance.Hash; RawSourcePath = $performance.RawSourcePath; RawSourceSha256 = $performance.RawSourceHash; Limits = [pscustomobject]$script:I10ApprovedLimits }
        Soak = [pscustomobject][ordered]@{ ReceiptPath = $soak.Path; ReceiptSha256 = $soak.Hash; AcMinutes = 60; BatteryMinutes = 60 }
        Languages = @([pscustomobject][ordered]@{ Language = 'Thai'; WidgetReportPath = $thaiWidget.Path; WidgetReportSha256 = $thaiWidget.Hash; DashboardStateSha256 = $thaiWidget.StateSha256 },[pscustomobject][ordered]@{ Language = 'English'; WidgetReportPath = $englishWidget.Path; WidgetReportSha256 = $englishWidget.Hash; DashboardStateSha256 = $englishWidget.StateSha256 })
        EvidenceBoundary = [pscustomobject][ordered]@{ RuntimeInput = $runtimeInput; Runtime = 'NOT_OBSERVED'; Human = 'NOT_OBSERVED'; Release = 'NOT_OBSERVED'; CreditGranted = $false; FixtureMode = [bool]$FixtureMode }
    }
    $json = ConvertTo-V02Jcs $candidate
    $published = Publish-I10NoClobber -Root $EvidenceRoot -Path $OutputPath -Text ($json + "`n") -Context 'Issue #10 candidate'
    return [pscustomobject][ordered]@{ Candidate = $candidate; CandidatePath = $published.Path; CandidateSha256 = $published.Sha256; CandidateFileId = $published.FileId; CandidateLinkCount = $published.LinkCount }
}

function Publish-I10NoClobber {
    param([Parameter(Mandatory = $true)][string]$Root,[Parameter(Mandatory = $true)][string]$Path,[Parameter(Mandatory = $true)][string]$Text,[Parameter(Mandatory = $true)][string]$Context)
    $fullRoot = [IO.Path]::GetFullPath($Root); $fullPath = [IO.Path]::GetFullPath($Path); Assert-I10NoReparsePath -Root $fullRoot -Path $fullPath -Context "$Context destination"
    if (Test-Path -LiteralPath $fullPath) { throw "$Context refuses to clobber an existing destination." }
    $parent = Split-Path -Parent $fullPath; if (-not (Test-Path -LiteralPath $parent -PathType Container)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }; Assert-I10NoReparsePath -Root $fullRoot -Path $parent -Context "$Context parent"
    $stage = Join-Path $parent ('.issue10-stage-' + [Guid]::NewGuid().ToString('N') + '.json'); $bytes = [Text.UTF8Encoding]::new($false, $true).GetBytes($Text); $stageHeld = $null
    try {
        $stream = New-Object IO.FileStream($stage, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::Read)
        try { $stream.Write($bytes, 0, $bytes.Length); $stream.Flush($true) } finally { $stream.Dispose() }
        $stageHeld = Read-I10HeldFile -Path $stage -MaximumBytes 67108864 -Context "$Context staging file"; if ($stageHeld.Sha256 -cne (Get-I10Sha256Bytes -Bytes $bytes)) { throw "$Context staging bytes changed before publication." }
        [IO.File]::Move($stage, $fullPath)
        $published = Read-I10HeldFile -Path $fullPath -MaximumBytes 67108864 -Context "$Context published file"
        if ($published.Sha256 -cne $stageHeld.Sha256 -or $published.Length -ne $stageHeld.Length -or $published.FileId -cne $stageHeld.FileId -or $published.LinkCount -ne $stageHeld.LinkCount) { throw "$Context changed file identity/bytes during no-clobber publication." }
        return $published
    }
    finally { if (Test-Path -LiteralPath $stage -PathType Leaf) { Remove-Item -LiteralPath $stage -Force -ErrorAction SilentlyContinue } }
}
