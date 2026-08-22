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

# This is the complete scalar-key vocabulary emitted by the version-local
# composite gate.  Get-I10Lines rejects every other key or free-form line;
# authority/credit claims therefore cannot be silently ignored by the
# consumer.  Section records are validated by their section-specific grammar.
$script:I10GateAllowedKeys = @(
    'RunNonce','GeneratedUtc','ExpectedSourceCommit','ExpectedSourceTree','SourceCommit','SourceTree','PreRunSourceCommit','PreRunSourceTree','PreRunGitTreeClean','PostRunSourceCommit','PostRunSourceTree','PostRunGitTreeClean','Result','EvidenceClass','SessionControlInvoked','AcceptanceControlPaneEnvironmentId','AcceptanceControlPaneObservedId','AcceptanceControlSession','TargetAgentLabSession','AcceptanceControlSocketPath','AcceptanceControlServerIdentity','TargetAgentLabSocketPath','SeparateSessionSockets','InitialTargetTransition','EventATransition','TargetDisconnectTransition','TargetReconnectTransition','EventBIncrementTransition','EventBTransition','CoreAcceptedEventKindCheck','SemanticCaptureBindingCheck','EventAIntegrity','EventBIntegrity','EventAAgentStatusTransition','EventBAgentStatusTransition','AutomatedTests','TrxEvidenceDirectory','TrxSelectionReceiptPath','TrxSelectionReceiptSha256','PackageValidatorPath','PackageIdentityPath','PackageIdentityFileSha256','PackageIdentityReceiptSha256','PackageArchivePath','PackageArchiveSha256','ExtractedPackageRoot','PackageManifestPath','PackageManifestSha256','AppSha256','CoreSha256','PackageProfileId','PackageProfileFileSha256','PackageProfileCanonicalSha256','PackageValidationEvidenceClass','TargetAgentSessionReference','TargetAgentSessionReferenceEvidenceSource','TargetAgentSessionReferenceObservableByGate','TargetAgentSessionReferenceBoundary','HerdrReleaseId','HerdrExecutableSha256','HerdrOpsCoreExecutableSha256BeforeLaunch','HerdrOpsCoreExecutableSha256AfterRun','HerdrOpsAppExecutableSha256BeforeLaunch','HerdrOpsAppExecutableSha256AfterRun','HerdrOpsCoreExecutableSha256BoundToReports','HerdrOpsAppExecutableSha256BoundToReports','CoreRuntimeReportPath','CoreRuntimeReportSha256','AppRuntimeReportPath','AppRuntimeReportSha256','ProgressHistoryPath','ProgressHistorySha256','ProgressHistoryEntries','ProgressHistoryLastEntrySha256','BundledSchemaSha256','HerdrProtocol','ReferenceHostProfileId','ReferenceHostProfileSha256','ReferenceHostSchemaSha256','Language','CaptureDirectory','RendererPolicyId','WpfProcessRenderMode','SoftwareOnlyThroughout','SnapshotObserved','EventObserved','ReconnectObserved','CompletionSignalObserved','CompletionSignalSemantics','DisconnectCount','BootstrapCount','DashboardClosed','DashboardClosedUtc','DisconnectObservedUtc','ReconnectObservedUtc','UpdateAfterDashboardClose','InitialEventCount','PreCloseEventCount','EventBBaselineEventCount','PostCloseEventCount','PreRestartConnectionEpoch','ReconnectedConnectionEpoch','PreRestartBootstrapCount','ReconnectedBootstrapCount','PreRestartDisconnectCount','ReconnectedDisconnectCount','WidgetLatencyBaselineSequence','WidgetLatencyWarmupSamplesExcluded','WidgetLatencyUnsupportedSamplesExcluded','WidgetLatencySamples','WidgetLatencyMinimumSamples','WidgetLatencyMeasurement','WidgetLatencyTargetMs','WidgetLatencyP95Ms','IdleQuiescenceSeconds','IdleQuiescenceWindow','IdleQuiescenceState','IdleCpuTargetPercent','IdleWorkingSetTargetMB','IdleWorkingSetTargetBytes','IdleWorkingSetStatistic','ResourceSampleIntervalMs','ResourceSampleCount','CombinedIdleCpuPercent','CombinedAverageWorkingSetMB','CombinedMaximumWorkingSetMB','AppAverageCpuPercent','AppAverageWorkingSetMB','AppMaximumWorkingSetMB','AppAveragePrivateMemoryMB','AppResourceProcess','CoreAverageCpuPercent','CoreAverageWorkingSetMB','CoreMaximumWorkingSetMB','CoreAveragePrivateMemoryMB','CoreResourceProcess','DashboardResourcesReleased','EvidenceWindowsDuringIdle','ManagedCaptureCleanup','RuntimeFingerprintStable','RuntimeFingerprintStart','RuntimeFingerprintFinish','AppWorkingSetPreparationMB','AppPrivateMemoryPreparationMB','ManagedHeapPreparationMB','ResourceStagePreparationToleranceMB','IdleStateSequence','IdleEventCount','RuntimeWpfCaptures','TcpListenersOwnedByCoreOrApp','AdministratorRequired','FailureType','OriginalAppExitCode','OriginalCoreExitCode','Failure'
)

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

        public sealed class FileIdentity
        {
            public string VolumeSerialNumber { get; internal set; }
            public string FileId { get; internal set; }
            public uint NumberOfLinks { get; internal set; }
            public uint FileAttributes { get; internal set; }
            public bool IsReparsePoint { get; internal set; }
        }

        public static FileIdentity Read(SafeFileHandle handle)
        {
            BY_HANDLE_FILE_INFORMATION info;
            if (!GetFileInformationByHandle(handle.DangerousGetHandle(), out info))
            {
                throw new Win32Exception(Marshal.GetLastWin32Error());
            }
            ulong fileIndex = ((ulong)info.FileIndexHigh << 32) | info.FileIndexLow;
            return new FileIdentity
            {
                VolumeSerialNumber = info.VolumeSerialNumber.ToString("X8"),
                FileId = fileIndex.ToString("X16"),
                NumberOfLinks = info.NumberOfLinks,
                FileAttributes = info.FileAttributes,
                IsReparsePoint = (info.FileAttributes & 0x400u) != 0
            };
        }
    }
}
'@ -Language CSharp
}

if (-not (Get-Variable -Scope Script -Name I10TestHook -ErrorAction SilentlyContinue)) { $script:I10TestHook = $null }

function Set-I10TestHook {
    param([AllowNull()][scriptblock]$Hook)
    $script:I10TestHook = $Hook
}

function Invoke-I10TestHook {
    param([Parameter(Mandatory = $true)][string]$Name,[AllowNull()]$Transaction,[AllowNull()]$Data)
    if ($null -ne $script:I10TestHook) { & $script:I10TestHook $Name $Transaction $Data }
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
    param([Parameter(Mandatory = $true)][AllowNull()]$Value,[Parameter(Mandatory = $true)][string]$Context)
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

function Assert-I10RunNonce {
    param([Parameter(Mandatory = $true)][string]$Value,[Parameter(Mandatory = $true)][string]$Context)
    if ($Value -notmatch '^[0-9a-f]{32}$') { throw "$Context must be a lowercase 32-hex invocation nonce." }
    return $Value
}

function Assert-I10FreshUtc {
    param([Parameter(Mandatory = $true)][string]$Value,[Parameter(Mandatory = $true)][DateTimeOffset]$EvidenceStartedUtc,[Parameter(Mandatory = $true)][DateTimeOffset]$TrustedNowUtc,[Parameter(Mandatory = $true)][string]$Context)
    $parsed = Assert-I10Utc -Value $Value -Context $Context
    $futureSkew = $TrustedNowUtc.AddSeconds(30)
    if ($parsed -lt $EvidenceStartedUtc -or $parsed -gt $futureSkew) {
        throw "$Context is outside the trusted invocation window. Start=$($EvidenceStartedUtc.ToString('O')) Now=$($TrustedNowUtc.ToString('O')) Observed=$($parsed.ToString('O'))."
    }
    return $parsed
}

function Open-I10RunNonceClaim {
    param([Parameter(Mandatory = $true)]$Transaction)
    $claimPath = Join-Path $Transaction.Root ('.issue10-run-' + $Transaction.RunNonce + '.claim')
    Assert-I10NoReparsePath -Root $Transaction.Root -Path $claimPath -Context 'Issue #10 run nonce claim'
    $claimText = ('nonce={0}`n evidenceStartedUtc={1}`n acceptedUtc={2}`n' -f $Transaction.RunNonce,$Transaction.EvidenceStartedUtc.ToString('O'),$Transaction.TrustedNowUtc.ToString('O'))
    $claimBytes = [Text.UTF8Encoding]::new($false, $true).GetBytes($claimText)
    $stream = $null
    try {
        # CreateNew is the replay guard.  The held stream keeps the claim
        # immutable for the rest of the acceptance transaction.
        $stream = [IO.File]::Open($claimPath, [IO.FileMode]::CreateNew, [IO.FileAccess]::ReadWrite, [IO.FileShare]::Read)
        $stream.Write($claimBytes, 0, $claimBytes.Length)
        $stream.Flush($true)
        $identity = [I10.NativeFileIdentity]::Read($stream.SafeFileHandle)
        $held = [pscustomobject][ordered]@{
            Path = [IO.Path]::GetFullPath($claimPath)
            Stream = $stream
            Bytes = $claimBytes
            Length = [long]$claimBytes.Length
            MaximumBytes = 4096L
            Sha256 = Get-I10Sha256Bytes -Bytes $claimBytes
            Identity = $identity
            VolumeSerialNumber = [string]$identity.VolumeSerialNumber
            FileId = [string]$identity.FileId
            LinkCount = [uint32]$identity.NumberOfLinks
            FileAttributes = [uint32]$identity.FileAttributes
            IsReparsePoint = [bool]$identity.IsReparsePoint
            NonceClaim = $true
        }
        $Transaction.Claim = Register-I10HeldFile -Transaction $Transaction -Held $held
    }
    catch {
        if ($null -ne $stream) { $stream.Dispose() }
        if ($_.Exception -is [IO.IOException] -or $_.Exception.InnerException -is [IO.IOException] -or [string]$_.Exception.Message -match 'already exists|used by another process') { throw "Issue #10 run nonce replay rejected: $($Transaction.RunNonce)." }
        throw
    }
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

function Get-I10IdentityKey {
    param([Parameter(Mandatory = $true)]$Identity)
    return ('{0}:{1}:{2}:{3}:{4}' -f [string]$Identity.VolumeSerialNumber,[string]$Identity.FileId,[uint32]$Identity.NumberOfLinks,[uint32]$Identity.FileAttributes,[bool]$Identity.IsReparsePoint)
}

function Assert-I10IdentityEqual {
    param([Parameter(Mandatory = $true)]$Expected,[Parameter(Mandatory = $true)]$Observed,[Parameter(Mandatory = $true)][string]$Context)
    foreach ($name in @('VolumeSerialNumber','FileId','NumberOfLinks','FileAttributes','IsReparsePoint')) {
        if ([string]$Expected.$name -cne [string]$Observed.$name) {
            throw "$Context $name changed. Expected='$($Expected.$name)' Observed='$($Observed.$name)'."
        }
    }
}

function Close-I10HeldFile {
    param([AllowNull()]$Held)
    if ($null -ne $Held -and $null -ne $Held.Stream -and $Held.Stream.CanRead) { $Held.Stream.Dispose() }
}

function Open-I10HeldFile {
    param([Parameter(Mandatory = $true)][string]$Path,[Parameter(Mandatory = $true)][long]$MaximumBytes,[Parameter(Mandatory = $true)][string]$Context)
    $full = [IO.Path]::GetFullPath($Path)
    if (-not (Test-Path -LiteralPath $full -PathType Leaf)) { throw "$Context is missing: $full" }
    $stream = $null
    try {
        # FileShare.Read deliberately denies writers, deletes, and rename/replace
        # while this evidence is admitted to the transaction.
        $stream = [IO.File]::Open($full, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
        if ($stream.Length -gt $MaximumBytes) { throw "$Context exceeds its bounded size of $MaximumBytes bytes." }
        $beforeIdentity = [I10.NativeFileIdentity]::Read($stream.SafeFileHandle)
        $length = [int]$stream.Length
        $bytes = New-Object byte[] $length
        $offset = 0
        while ($offset -lt $length) {
            $read = $stream.Read($bytes, $offset, $length - $offset)
            if ($read -le 0) { throw "$Context ended before its held byte count was read." }
            $offset += $read
        }
        $afterIdentity = [I10.NativeFileIdentity]::Read($stream.SafeFileHandle)
        Assert-I10IdentityEqual -Expected $beforeIdentity -Observed $afterIdentity -Context "$Context changed while being read"
        return [pscustomobject][ordered]@{
            Path = $full
            Stream = $stream
            Bytes = $bytes
            Length = [long]$length
            MaximumBytes = $MaximumBytes
            Sha256 = Get-I10Sha256Bytes -Bytes $bytes
            Identity = $afterIdentity
            VolumeSerialNumber = [string]$afterIdentity.VolumeSerialNumber
            FileId = [string]$afterIdentity.FileId
            LinkCount = [uint32]$afterIdentity.NumberOfLinks
            FileAttributes = [uint32]$afterIdentity.FileAttributes
            IsReparsePoint = [bool]$afterIdentity.IsReparsePoint
        }
    }
    catch {
        if ($null -ne $stream) { $stream.Dispose() }
        throw
    }
}

function Read-I10HeldFile {
    param([Parameter(Mandatory = $true)][string]$Path,[Parameter(Mandatory = $true)][long]$MaximumBytes,[Parameter(Mandatory = $true)][string]$Context)
    $held = Open-I10HeldFile -Path $Path -MaximumBytes $MaximumBytes -Context $Context
    try { return $held }
    finally { Close-I10HeldFile -Held $held }
}

function New-I10AcceptanceTransaction {
    param([Parameter(Mandatory = $true)][string]$Root,[Parameter(Mandatory = $true)][string]$RunNonce,[Parameter(Mandatory = $true)][DateTimeOffset]$EvidenceStartedUtc,[Parameter(Mandatory = $true)][DateTimeOffset]$TrustedNowUtc)
    [pscustomobject][ordered]@{
        Root = [IO.Path]::GetFullPath($Root)
        RunNonce = $RunNonce
        EvidenceStartedUtc = $EvidenceStartedUtc.ToUniversalTime()
        TrustedNowUtc = $TrustedNowUtc.ToUniversalTime()
        HeldFiles = [Collections.ArrayList]::new()
        ByPath = @{}
        Closed = $false
        Claim = $null
    }
}

function Register-I10HeldFile {
    param([Parameter(Mandatory = $true)]$Transaction,[Parameter(Mandatory = $true)]$Held)
    if ($Transaction.Closed) { throw 'Issue #10 acceptance transaction is already closed.' }
    $key = [IO.Path]::GetFullPath([string]$Held.Path)
    if ($Transaction.ByPath.ContainsKey($key)) { throw "Issue #10 transaction attempted to register duplicate held path '$key'." }
    $Transaction.ByPath[$key] = $Held
    $null = $Transaction.HeldFiles.Add($Held)
    return $Held
}

function Get-I10TransactionFile {
    param([Parameter(Mandatory = $true)]$Transaction,[Parameter(Mandatory = $true)][string]$Path,[Parameter(Mandatory = $true)][long]$MaximumBytes,[Parameter(Mandatory = $true)][string]$Context)
    $full = [IO.Path]::GetFullPath($Path)
    if ($Transaction.ByPath.ContainsKey($full)) {
        $held = $Transaction.ByPath[$full]
        if ([long]$held.Length -gt $MaximumBytes) { throw "$Context exceeds its bounded size of $MaximumBytes bytes." }
        return $held
    }
    return Register-I10HeldFile -Transaction $Transaction -Held (Open-I10HeldFile -Path $full -MaximumBytes $MaximumBytes -Context $Context)
}

function Get-I10PathIdentityProbe {
    param([Parameter(Mandatory = $true)][string]$Path,[Parameter(Mandatory = $true)][string]$Context)
    $full = [IO.Path]::GetFullPath($Path)
    $stream = $null
    try {
        $stream = [IO.File]::Open($full, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
        return [pscustomobject][ordered]@{ Path = $full; Length = [long]$stream.Length; Identity = [I10.NativeFileIdentity]::Read($stream.SafeFileHandle) }
    }
    catch { throw "$Context could not re-open the bound path: $($_.Exception.Message)" }
    finally { if ($null -ne $stream) { $stream.Dispose() } }
}

function Assert-I10HeldFileStable {
    param([Parameter(Mandatory = $true)]$Held,[Parameter(Mandatory = $true)][string]$Root,[Parameter(Mandatory = $true)][string]$Context)
    if ($null -eq $Held.Stream -or -not $Held.Stream.CanRead) { throw "$Context held handle was closed before final publication." }
    Assert-I10NoReparsePath -Root $Root -Path $Held.Path -Context "$Context path"
    $currentIdentity = [I10.NativeFileIdentity]::Read($Held.Stream.SafeFileHandle)
    Assert-I10IdentityEqual -Expected $Held.Identity -Observed $currentIdentity -Context "$Context held identity"
    if ([long]$Held.Stream.Length -ne [long]$Held.Length) { throw "$Context held length changed." }
    $isNonceClaim = ($null -ne $Held.PSObject.Properties['NonceClaim'] -and [bool]$Held.NonceClaim)
    if (-not $isNonceClaim) {
        $probe = Get-I10PathIdentityProbe -Path $Held.Path -Context $Context
        if ([long]$probe.Length -ne [long]$Held.Length) { throw "$Context path length changed." }
        Assert-I10IdentityEqual -Expected $Held.Identity -Observed $probe.Identity -Context "$Context path identity"
    }
}

function Assert-I10TransactionStable {
    param([Parameter(Mandatory = $true)]$Transaction,[Parameter(Mandatory = $true)][string]$Context)
    if ($Transaction.Closed) { throw "$Context cannot validate a closed transaction." }
    foreach ($held in @($Transaction.HeldFiles)) { Assert-I10HeldFileStable -Held $held -Root $Transaction.Root -Context "$Context '$($held.Path)'" }
}

function Close-I10AcceptanceTransaction {
    param([Parameter(Mandatory = $true)]$Transaction)
    if ($Transaction.Closed) { return }
    for ($index = $Transaction.HeldFiles.Count - 1; $index -ge 0; $index--) { Close-I10HeldFile -Held $Transaction.HeldFiles[$index] }
    $Transaction.Closed = $true
}

function Read-I10StrictJson {
    param([Parameter(Mandatory = $true)][string]$Path,[Parameter(Mandatory = $true)][string]$Context,[long]$MaximumBytes = 16777216,[AllowNull()]$Transaction,[AllowNull()]$HeldFile)
    $owned = $false
    if ($null -ne $HeldFile) { $held = $HeldFile }
    elseif ($null -ne $Transaction) { $held = Get-I10TransactionFile -Transaction $Transaction -Path $Path -MaximumBytes $MaximumBytes -Context $Context }
    else { $held = Read-I10HeldFile -Path $Path -MaximumBytes $MaximumBytes -Context $Context; $owned = $true }
    try {
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
    finally { if ($owned) { Close-I10HeldFile -Held $held } }
}

function Get-I10CanonicalSha256 {
    param([Parameter(Mandatory = $true)]$Value)
    if (Get-Command ConvertTo-V02Jcs -ErrorAction SilentlyContinue) {
        return Get-I10Sha256Text -Text (ConvertTo-V02Jcs $Value)
    }
    return Get-I10Sha256Text -Text (($Value | ConvertTo-Json -Depth 100 -Compress))
}

function Get-I10Lines {
    param([Parameter(Mandatory = $true)][string]$Path,[AllowNull()]$Transaction,[AllowNull()]$HeldFile)
    $owned = $false
    if ($null -ne $HeldFile) { $held = $HeldFile }
    elseif ($null -ne $Transaction) { $held = Get-I10TransactionFile -Transaction $Transaction -Path $Path -MaximumBytes 16777216 -Context 'Issue #10 gate report' }
    else { $held = Read-I10HeldFile -Path $Path -MaximumBytes 16777216 -Context 'Issue #10 gate report'; $owned = $true }
    try {
        try { $text = [Text.UTF8Encoding]::new($false, $true).GetString($held.Bytes) }
        catch { throw 'Issue #10 gate report is not valid UTF-8.' }
        $map = [ordered]@{}
        $allowed = @($script:I10GateAllowedKeys)
        $section = $null
        $lineNumber = 0
        foreach ($line in ($text -split "`r?`n")) {
            $lineNumber++
            if ([string]::IsNullOrEmpty($line)) {
                if ($null -ne $section -and $section -ne 'EvidenceBoundary') { $section = $null }
                continue
            }
            if ($lineNumber -eq 1) {
                if ($line -cne 'HerdrOps v0.2 Composite Actual Herdr Runtime Acceptance') { throw "Issue #10 gate report has an invalid header at line $lineNumber." }
                continue
            }
            if ($line -in @('ResourceStageCheckpoints:','StateHashChain:','WidgetLatencyIncludedSamples:','CaptureHashes:','EvidenceBoundary:')) {
                $section = $line.TrimEnd(':')
                continue
            }
            if ($null -eq $section -and $line -match '^([^:]+):[ ]?(.*)$') {
                $key = [string]$matches[1]
                if ($allowed -notcontains $key) { throw "Issue #10 gate report contains unknown field '$key' at line $lineNumber." }
                if ($map.Contains($key)) { throw "Issue #10 gate report contains duplicate field '$key'." }
                $map[$key] = [string]$matches[2]
                continue
            }
            if ($section -eq 'ResourceStageCheckpoints' -and $line -match '^stage=[^ ]+ observed=[^ ]+ pid=[0-9]+ start=[^ ]+ workingSetMB=[^ ]+ privateMB=[^ ]+ pagedMB=[^ ]+ managedHeapMB=[^ ]+$') { continue }
            if ($section -eq 'StateHashChain' -and $line -match '^(Initial|BeforeDashboardClose|AfterDashboardClose): [0-9]+ [0-9A-Fa-f]{64}$') { continue }
            if ($section -eq 'WidgetLatencyIncludedSamples' -and $line -match '^sequence=[0-9]+ event=[0-9]+ envelope=[0-9]+ correlation=[^ ]+ stateSha256=[0-9A-Fa-f]{64} kind=[^ ]+ accepted=[^ ]+ sent=[^ ]+ applied=[^ ]+ milliseconds=[^ ]+$') { continue }
            if ($section -eq 'CaptureHashes' -and $line -match '^SHA256 [0-9A-Fa-f]{64} [^ ]+$') { continue }
            if ($section -eq 'EvidenceBoundary' -and $line -in @(
                'This gate proves exact-hash-bound actual Herdr snapshot/Agent-status-event/reconnect behavior, separate Acceptance-control and Agent-Lab target sessions, Core-to-App runtime-health propagation, live production WPF page and Widget rendering, Dashboard-close continuity, state-hash correspondence, measured latency/resources, no owned TCP listener, and non-elevated operation for this host and run.',
                'It launches the App and Core from the package root whose receipt, ZIP, manifest, source, and component bytes passed the committed package validator. This is runtime use of validated package bytes, not clean-machine installation or Release evidence.',
                'The native target Agent/session reference is operator attestation because the gate cannot independently observe that client-owned session identity.',
                'It does not prove clean-machine installation, later-version features, independent human review, or future Herdr releases.'
            )) { continue }
            throw "Issue #10 gate report has malformed or ignored content at line ${lineNumber}: '$line'."
        }
        if ($lineNumber -eq 0) { throw 'Issue #10 gate report is missing its exact header.' }
        return [pscustomobject][ordered]@{ Hash = $held.Sha256; Text = $text; Fields = [pscustomobject]$map; Held = $held; GeneratedUtc = $null }
    }
    finally { if ($owned) { Close-I10HeldFile -Held $held } }
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
        [Parameter(Mandatory = $true)][string]$SoakSha256,
        [Parameter(Mandatory = $true)][string]$ExpectedRunNonce,
        [Parameter(Mandatory = $true)][DateTimeOffset]$EvidenceStartedUtc,
        [Parameter(Mandatory = $true)][DateTimeOffset]$TrustedNowUtc,
        [AllowNull()]$Transaction
    )
    $gate = Get-I10Lines -Path $Path -Transaction $Transaction
    $fields = $gate.Fields
    Assert-I10FieldEqual $fields @('RunNonce') $ExpectedRunNonce 'Runtime gate invocation nonce'
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
        @('PackageIdentityFileSha256', [string]$Package.IdentityFileSha256),
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
    $attestationSource = Get-I10Field -Fields $fields -Names @('TargetAgentSessionReferenceEvidenceSource') -Context 'Runtime target-session attestation source'
    if ($attestationSource -cne 'OperatorAttestation') { throw 'Runtime target-session authority is not explicitly bounded to operator attestation.' }
    $observableByGate = Get-I10Field -Fields $fields -Names @('TargetAgentSessionReferenceObservableByGate') -Context 'Runtime target-session observability boundary'
    if ($observableByGate -notin @('false','False')) { throw 'Runtime target-session reference must remain non-observable by the gate.' }
    Assert-I10FieldEqual $fields @('TargetAgentSessionReferenceBoundary') 'The gate records this native Agent/session reference but cannot independently observe or prove restoration of the native Agent session.' 'Runtime target-session authority boundary'
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
    $generatedUtc = Assert-I10FreshUtc -Value $generated -EvidenceStartedUtc $EvidenceStartedUtc -TrustedNowUtc $TrustedNowUtc -Context 'Runtime gate GeneratedUtc'
    $appPathValue = Get-I10Field -Fields $fields -Names @('AppRuntimeReportPath','AppRuntimeReport') -Context 'Runtime App report path'
    $corePathValue = Get-I10Field -Fields $fields -Names @('CoreRuntimeReportPath','CoreRuntimeReport') -Context 'Runtime Core report path'
    $gateDirectory = Split-Path -Parent ([IO.Path]::GetFullPath($Path))
    $appPath = if ([IO.Path]::IsPathRooted($appPathValue)) { [IO.Path]::GetFullPath($appPathValue) } else { [IO.Path]::GetFullPath((Join-Path $gateDirectory $appPathValue)) }
    $corePath = if ([IO.Path]::IsPathRooted($corePathValue)) { [IO.Path]::GetFullPath($corePathValue) } else { [IO.Path]::GetFullPath((Join-Path $gateDirectory $corePathValue)) }
    $appHeld = Read-I10StrictJson -Path $appPath -Context 'Runtime App report' -Transaction $Transaction
    $coreHeld = Read-I10StrictJson -Path $corePath -Context 'Runtime Core report' -Transaction $Transaction
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
    param([Parameter(Mandatory = $true)]$Provenance,[Parameter(Mandatory = $true)][string]$ExpectedSourceCommit,[Parameter(Mandatory = $true)][string]$ExpectedSourceTree,[Parameter(Mandatory = $true)]$Package,[Parameter(Mandatory = $true)][string]$ExpectedRunNonce,[Parameter(Mandatory = $true)][string]$Context)
    Assert-I10ExactProperties $Provenance @('runNonce','candidate','package') $Context
    Assert-I10RunNonce -Value ([string]$Provenance.runNonce) -Context "$Context runNonce" | Out-Null
    if ([string]$Provenance.runNonce -cne $ExpectedRunNonce) { throw "$Context runNonce is not bound to this acceptance invocation." }
    Assert-I10ExactProperties $Provenance.candidate @('commitSha','treeSha') "$Context candidate"
    $commit = [string]$Provenance.candidate.commitSha; $tree = [string]$Provenance.candidate.treeSha
    if ($commit -cne $ExpectedSourceCommit -or $tree -cne $ExpectedSourceTree) { throw "$Context source commit/tree is not bound to the requested candidate." }
    Assert-I10ExactProperties $Provenance.package @('profileId','receipt','archive','packageRootRelativePath','components') "$Context package"
    if ($null -ne $Package.ProfileId -and [string]$Provenance.package.profileId -cne [string]$Package.ProfileId) { throw "$Context package profile is not bound to the validated package." }
    Assert-I10String $Provenance.package.packageRootRelativePath "$Context package root relative path"
    if ([IO.Path]::IsPathRooted([string]$Provenance.package.packageRootRelativePath) -or [string]$Provenance.package.packageRootRelativePath -match '(^|[\\/])\.\.([\\/]|$)') { throw "$Context package root relative path is not safely relative." }
    $pkgReceipt = $Provenance.package.receipt
    Assert-I10ExactProperties $pkgReceipt @('relativePath','bytes','fileSha256','canonicalSha256') "$Context package receipt"
    Assert-I10String $pkgReceipt.relativePath "$Context package receipt relativePath"
    if ([IO.Path]::IsPathRooted([string]$pkgReceipt.relativePath) -or [string]$pkgReceipt.relativePath -match '(^|[\\/])\.\.([\\/]|$)') { throw "$Context package receipt relativePath is not safely relative." }
    Assert-I10Integer $pkgReceipt.bytes "$Context package receipt bytes"
    if ([long]$pkgReceipt.bytes -ne [long]$Package.IdentityLength) { throw "$Context package receipt byte count is not bound to the held identity file." }
    Assert-I10Sha256 $pkgReceipt.fileSha256 "$Context package identity receipt fileSha256"
    Assert-I10Sha256 $pkgReceipt.canonicalSha256 "$Context package identity receipt canonicalSha256"
    if ([string]$pkgReceipt.fileSha256.ToUpperInvariant() -cne [string]$Package.IdentityFileSha256.ToUpperInvariant()) { throw "$Context package identity receipt fileSha256 is not bound to the held raw bytes." }
    if ([string]$pkgReceipt.canonicalSha256.ToUpperInvariant() -cne [string]$Package.IdentityCanonicalSha256.ToUpperInvariant()) { throw "$Context package identity receipt canonicalSha256 is not bound to the held canonical object." }
    Assert-I10ExactProperties $Provenance.package.archive @('relativePath','fileName','bytes','sha256') "$Context package archive"
    Assert-I10String $Provenance.package.archive.relativePath "$Context package archive relativePath"; Assert-I10String $Provenance.package.archive.fileName "$Context package archive fileName"; Assert-I10Integer $Provenance.package.archive.bytes "$Context package archive bytes"; Assert-I10Sha256 $Provenance.package.archive.sha256 "$Context package archive sha256"
    if ([long]$Provenance.package.archive.bytes -ne [long]$Package.ArchiveLength -or [string]$Provenance.package.archive.sha256.ToUpperInvariant() -cne [string]$Package.ArchiveSha256.ToUpperInvariant()) { throw "$Context package archive binding is not exact." }
    foreach ($pair in @(@('app',$Provenance.package.components.app,$Package.AppLength,$Package.AppSha256),@('core',$Provenance.package.components.core,$Package.CoreLength,$Package.CoreSha256))) {
        Assert-I10ExactProperties $pair[1] @('relativePath','bytes','sha256') "$Context package component $($pair[0])"; Assert-I10String $pair[1].relativePath "$Context package component $($pair[0]) relativePath"; Assert-I10Integer $pair[1].bytes "$Context package component $($pair[0]) bytes"; Assert-I10Sha256 $pair[1].sha256 "$Context package component $($pair[0]) sha256"
        if ([long]$pair[1].bytes -ne [long]$pair[2] -or [string]$pair[1].sha256.ToUpperInvariant() -cne [string]$pair[3].ToUpperInvariant()) { throw "$Context package component $($pair[0]) binding is not exact." }
    }
}

function Assert-I10PerformanceReceipt {
    param([Parameter(Mandatory = $true)][string]$Path,[Parameter(Mandatory = $true)][string]$EvidenceRoot,[Parameter(Mandatory = $true)][string]$ExpectedSourceCommit,[Parameter(Mandatory = $true)][string]$ExpectedSourceTree,[Parameter(Mandatory = $true)]$Package,[Parameter(Mandatory = $true)][string]$ExpectedRunNonce,[Parameter(Mandatory = $true)][DateTimeOffset]$EvidenceStartedUtc,[Parameter(Mandatory = $true)][DateTimeOffset]$TrustedNowUtc,[AllowNull()]$Transaction)
    $read = Read-I10StrictJson -Path $Path -Context 'Issue #10 raw AB/BA performance receipt' -Transaction $Transaction
    $value = $read.Value
    Assert-I10ExactProperties $value @('provenance','rawSource','orders','soakBins','aggregateStatus') 'Issue #10 performance receipt'
    if ([string]$value.aggregateStatus -cne 'PASS') { throw 'Performance receipt aggregateStatus is not PASS.' }
    Assert-I10ReceiptProvenance -Provenance $value.provenance -ExpectedSourceCommit $ExpectedSourceCommit -ExpectedSourceTree $ExpectedSourceTree -Package $Package -ExpectedRunNonce $ExpectedRunNonce -Context 'Performance receipt provenance'
    Assert-I10ExactProperties $value.rawSource @('relativePath','bytes','fileSha256','canonicalSha256') 'Performance rawSource binding'
    Assert-I10String $value.rawSource.relativePath 'Performance rawSource relativePath'; Assert-I10Integer $value.rawSource.bytes 'Performance rawSource bytes'; Assert-I10Sha256 $value.rawSource.fileSha256 'Performance rawSource fileSha256'; Assert-I10Sha256 $value.rawSource.canonicalSha256 'Performance rawSource canonicalSha256'
    $rawPath = Resolve-I10ContainedPath -Root $EvidenceRoot -RelativePath ([string]$value.rawSource.relativePath) -Context 'Performance rawSource path'
    $raw = Read-I10StrictJson -Path $rawPath -Context 'Performance raw observations' -Transaction $Transaction
    if ($raw.Held.Length -ne [long]$value.rawSource.bytes -or $raw.Held.Sha256 -cne [string]$value.rawSource.fileSha256.ToUpperInvariant()) { throw 'Performance rawSource binding does not match held bytes.' }
    if ((Get-I10CanonicalSha256 -Value $raw.Value) -cne [string]$value.rawSource.canonicalSha256.ToUpperInvariant()) { throw 'Performance rawSource canonical hash does not match its parsed object.' }
    Assert-I10ExactProperties $raw.Value @('orders','soakBins') 'Performance raw observations'
    if ((Get-I10CanonicalSha256 -Value $raw.Value.orders) -ne (Get-I10CanonicalSha256 -Value $value.orders) -or
        (Get-I10CanonicalSha256 -Value $raw.Value.soakBins) -ne (Get-I10CanonicalSha256 -Value $value.soakBins)) { throw 'Performance receipt aggregate fields are not byte-bound to the held raw observations.' }
    $orders = @($value.orders); if ($orders.Count -ne 2) { throw 'Performance receipt must contain exactly AB then BA orders.' }
    $lastObservedUtc = $EvidenceStartedUtc
    foreach ($index in 0..1) {
        $order = $orders[$index]; $expected = @('AB','BA')[$index]
        Assert-I10ExactProperties $order @('order','warmup','repetitions') "Performance order $expected"
        if ([string]$order.order -cne $expected -or @($order.warmup).Count -ne 1 -or @($order.repetitions).Count -ne 5) { throw "Performance order $expected has invalid warmup/repetition counts." }
        $samples = @($order.warmup) + @($order.repetitions)
        for ($sampleIndex = 0; $sampleIndex -lt $samples.Count; $sampleIndex++) {
            $rep = $samples[$sampleIndex]
            Assert-I10ExactProperties $rep @('ordinal','observedUtc','a','b') "Performance $expected sample $sampleIndex"
            $expectedOrdinal = if ($sampleIndex -eq 0) { 0 } else { $sampleIndex - 1 }
            if ([int]$rep.ordinal -ne $expectedOrdinal) { throw "Performance $expected sample ordinal is not exact." }
            $observedUtc = Assert-I10FreshUtc -Value ([string]$rep.observedUtc) -EvidenceStartedUtc $EvidenceStartedUtc -TrustedNowUtc $TrustedNowUtc -Context "Performance $expected sample $sampleIndex observedUtc"
            if ($observedUtc -lt $lastObservedUtc) { throw "Performance $expected sample chronology moved backward." }
            $lastObservedUtc = $observedUtc
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
            if ($sampleIndex -gt 0) {
                $a = $rep.a; $b = $rep.b
                $aCpu = [double]$a.cpuBasisPoints / 100.0; $bCpu = [double]$b.cpuBasisPoints / 100.0
                $cpuDelta = $bCpu - $aCpu
                $cpuPercent = if ($aCpu -gt 0) { 100.0 * $cpuDelta / $aCpu } elseif ($bCpu -eq 0) { 0.0 } else { [double]::PositiveInfinity }
                $aLatency = [double](@($a.latencyMicroseconds | Sort-Object { [long]$_ })[[Math]::Ceiling(20 * 0.95) - 1])
                $bLatency = [double](@($b.latencyMicroseconds | Sort-Object { [long]$_ })[[Math]::Ceiling(20 * 0.95) - 1])
                $latencyPercent = if ($aLatency -gt 0) { 100.0 * ($bLatency - $aLatency) / $aLatency } elseif ($bLatency -eq 0) { 0.0 } else { [double]::PositiveInfinity }
                $bStall = @($b.uiStallMicroseconds | Sort-Object { [long]$_ })
                if ($cpuDelta -gt 0.5 -or $cpuPercent -gt 10.0 -or $latencyPercent -gt 10.0 -or [long]$bStall[[Math]::Ceiling(20 * 0.95) - 1] -gt 50000 -or [long]$bStall[-1] -gt 100000) { throw "Performance $expected sample $sampleIndex breached the mode-B regression/absolute guard." }
            }
        }
    }
    [pscustomobject][ordered]@{ Path = [IO.Path]::GetFullPath($Path); Hash = $read.Held.Sha256; RawSourcePath = $rawPath; RawSourceHash = $raw.Held.Sha256 }
}

function Assert-I10SoakReceipt {
    param([Parameter(Mandatory = $true)][string]$Path,[Parameter(Mandatory = $true)][string]$ExpectedSourceCommit,[Parameter(Mandatory = $true)][string]$ExpectedSourceTree,[Parameter(Mandatory = $true)]$Package,[Parameter(Mandatory = $true)][string]$ExpectedRunNonce,[Parameter(Mandatory = $true)][DateTimeOffset]$EvidenceStartedUtc,[Parameter(Mandatory = $true)][DateTimeOffset]$TrustedNowUtc,[AllowNull()]$Transaction)
    $read = Read-I10StrictJson -Path $Path -Context 'Issue #10 AC/Battery soak receipt' -Transaction $Transaction; $value = $read.Value
    Assert-I10ExactProperties $value @('provenance','soakBins','aggregateStatus') 'Issue #10 soak receipt'
    if ([string]$value.aggregateStatus -cne 'PASS') { throw 'Soak receipt aggregateStatus is not PASS.' }
    Assert-I10ReceiptProvenance -Provenance $value.provenance -ExpectedSourceCommit $ExpectedSourceCommit -ExpectedSourceTree $ExpectedSourceTree -Package $Package -ExpectedRunNonce $ExpectedRunNonce -Context 'Soak receipt provenance'
    $bins = @($value.soakBins); if ($bins.Count -ne 24) { throw 'Soak receipt must contain exactly 24 bins.' }
    foreach ($index in 0..23) {
        $bin = $bins[$index]; Assert-I10ExactProperties $bin @('powerSource','ordinal','durationMinutes','observedUtc','workingSetStartBytes','workingSetEndBytes','rendererStable') "Soak bin $index"
        $power = if ($index -lt 12) { 'AC' } else { 'Battery' }; $ordinal = $index % 12
        if ([string]$bin.powerSource -cne $power -or [int]$bin.ordinal -ne $ordinal -or [int]$bin.durationMinutes -ne 5 -or -not [bool]$bin.rendererStable) { throw "Soak bin $index is not the governed $power/5-minute PASS bin." }
        Assert-I10FreshUtc -Value ([string]$bin.observedUtc) -EvidenceStartedUtc $EvidenceStartedUtc -TrustedNowUtc $TrustedNowUtc -Context "Soak bin $index observedUtc" | Out-Null
        Assert-I10Integer $bin.workingSetStartBytes "Soak bin $index start working set" -AllowZero; Assert-I10Integer $bin.workingSetEndBytes "Soak bin $index end working set" -AllowZero
        if ([long]$bin.workingSetStartBytes -gt $script:I10ApprovedLimits.WorkingSetMaximumBytes -or [long]$bin.workingSetEndBytes -gt $script:I10ApprovedLimits.WorkingSetMaximumBytes) { throw "Soak bin $index exceeded 255 MiB." }
        if ([math]::Abs([double]$bin.workingSetEndBytes - [double]$bin.workingSetStartBytes) * 2 -gt $script:I10ApprovedLimits.ResourceSlopeMaximumBytesPerTenMinutes) { throw "Soak bin $index exceeded the governed resource slope." }
    }
    [pscustomobject][ordered]@{ Path = [IO.Path]::GetFullPath($Path); Hash = $read.Held.Sha256; AcMinutes = 60; BatteryMinutes = 60 }
}

function Assert-I10Capture {
    param([Parameter(Mandatory = $true)][string]$Root,[Parameter(Mandatory = $true)][string]$RelativePath,[Parameter(Mandatory = $true)][long]$ExpectedBytes,[Parameter(Mandatory = $true)][string]$ExpectedSha256,[Parameter(Mandatory = $true)][string]$Context,[AllowNull()]$Transaction)
    Assert-I10Integer $ExpectedBytes "$Context declared bytes"
    $path = Resolve-I10ContainedPath -Root $Root -RelativePath $RelativePath -Context "$Context path"
    $held = if ($null -ne $Transaction) { Get-I10TransactionFile -Transaction $Transaction -Path $path -MaximumBytes 134217728 -Context $Context } else { Read-I10HeldFile -Path $path -MaximumBytes 134217728 -Context $Context }
    if ($held.Length -ne $ExpectedBytes -or $held.Sha256 -cne $ExpectedSha256.ToUpperInvariant()) { throw "$Context capture bytes/hash do not match the held file." }
    if ([IO.Path]::GetExtension($path) -ine '.png') { throw "$Context capture must be a PNG path." }
    $pngSignature = [byte[]]@(137,80,78,71,13,10,26,10)
    if ($held.Bytes.Length -lt $pngSignature.Length) { throw "$Context capture is not a complete PNG." }
    for ($index = 0; $index -lt $pngSignature.Length; $index++) { if ($held.Bytes[$index] -ne $pngSignature[$index]) { throw "$Context capture PNG signature is invalid." } }
    return [pscustomobject][ordered]@{ Path = $path; Bytes = $held.Length; Sha256 = $held.Sha256; FileId = $held.FileId; LinkCount = $held.LinkCount }
}

function Assert-I10WidgetReport {
    param([Parameter(Mandatory = $true)][string]$Path,[Parameter(Mandatory = $true)][string]$ExpectedLanguage,[Parameter(Mandatory = $true)][string]$ExpectedSourceCommit,[Parameter(Mandatory = $true)][string]$ExpectedSourceTree,[Parameter(Mandatory = $true)]$Runtime,[Parameter(Mandatory = $true)]$Performance,[Parameter(Mandatory = $true)]$Soak,[Parameter(Mandatory = $true)]$Package,[Parameter(Mandatory = $true)][string]$ExpectedRunNonce,[Parameter(Mandatory = $true)][DateTimeOffset]$EvidenceStartedUtc,[Parameter(Mandatory = $true)][DateTimeOffset]$TrustedNowUtc,[AllowNull()]$Transaction)
    $read = Read-I10StrictJson -Path $Path -Context "Issue #10 $ExpectedLanguage widget evidence" -Transaction $Transaction; $value = $read.Value
    Assert-I10ExactProperties $value @('SchemaVersion','EvidenceClassification','Issue','Language','RunNonce','Source','Bindings','Chronology','Dashboard','Widgets','AttentionStates','UnknownPolicy') "Issue #10 $ExpectedLanguage widget evidence"
    if ([int]$value.SchemaVersion -ne 1 -or [string]$value.EvidenceClassification -cne 'Issue10WidgetObservation' -or [int]$value.Issue -ne 10 -or [string]$value.Language -cne $ExpectedLanguage) { throw "Issue #10 $ExpectedLanguage widget evidence identity is invalid." }
    Assert-I10RunNonce -Value ([string]$value.RunNonce) -Context "Issue #10 $ExpectedLanguage widget runNonce" | Out-Null
    if ([string]$value.RunNonce -cne $ExpectedRunNonce) { throw "Issue #10 $ExpectedLanguage widget runNonce is not bound to this acceptance invocation." }
    Assert-I10ExactProperties $value.Source @('CommitSha','TreeSha') "Issue #10 $ExpectedLanguage source"; if ([string]$value.Source.CommitSha -cne $ExpectedSourceCommit -or [string]$value.Source.TreeSha -cne $ExpectedSourceTree) { throw "Issue #10 $ExpectedLanguage widget source is not exact." }
    Assert-I10ExactProperties $value.Bindings @('GateReportSha256','AppRuntimeReportSha256','CoreRuntimeReportSha256','PackageIdentityFileSha256','PackageIdentityReceiptSha256','PackageArchiveSha256','PackageManifestSha256','AppSha256','CoreSha256','HerdrExecutableSha256','PerformanceReceiptSha256','SoakReceiptSha256','ControlSessionIdentity','TargetSessionIdentity') "Issue #10 $ExpectedLanguage bindings"
    foreach ($name in @('GateReportSha256','AppRuntimeReportSha256','CoreRuntimeReportSha256','PackageIdentityFileSha256','PackageIdentityReceiptSha256','PackageArchiveSha256','PackageManifestSha256','AppSha256','CoreSha256','HerdrExecutableSha256','PerformanceReceiptSha256','SoakReceiptSha256')) { Assert-I10Sha256 $value.Bindings.$name "Issue #10 $ExpectedLanguage binding $name" }
    $expectedBindings = [ordered]@{ GateReportSha256 = $Runtime.Hash; AppRuntimeReportSha256 = $Runtime.AppHash; CoreRuntimeReportSha256 = $Runtime.CoreHash; PackageIdentityFileSha256 = $Package.IdentityFileSha256; PackageIdentityReceiptSha256 = $Package.ReceiptSha256; PackageArchiveSha256 = $Package.ArchiveSha256; PackageManifestSha256 = $Package.ManifestSha256; AppSha256 = $Package.AppSha256; CoreSha256 = $Package.CoreSha256; HerdrExecutableSha256 = $Runtime.HerdrExecutableSha256; PerformanceReceiptSha256 = $Performance.Hash; SoakReceiptSha256 = $Soak.Hash }
    foreach ($name in $expectedBindings.Keys) { if ([string]$value.Bindings.$name -cne [string]$expectedBindings[$name]) { throw "Issue #10 $ExpectedLanguage binding $name is not cross-bound." } }
    if ([string]$value.Bindings.ControlSessionIdentity -cne [string]$Runtime.ControlSession -or [string]$value.Bindings.TargetSessionIdentity -cne [string]$Runtime.TargetSession) { throw "Issue #10 $ExpectedLanguage control/target session binding is not exact." }
    Assert-I10ExactProperties $value.Chronology @('RuntimeStartUtc','DashboardObservedUtc','WidgetObservedUtc','CapturedUtc','StateSequence') "Issue #10 $ExpectedLanguage chronology"
    $times = @(); foreach ($name in @('RuntimeStartUtc','DashboardObservedUtc','WidgetObservedUtc','CapturedUtc')) { $times += ,(Assert-I10FreshUtc -Value ([string]$value.Chronology.$name) -EvidenceStartedUtc $EvidenceStartedUtc -TrustedNowUtc $TrustedNowUtc -Context "Issue #10 $ExpectedLanguage $name") }; for ($i = 1; $i -lt $times.Count; $i++) { if ($times[$i] -lt $times[$i - 1]) { throw "Issue #10 $ExpectedLanguage chronology moved backward." } }
    Assert-I10Integer $value.Chronology.StateSequence 'Issue #10 widget StateSequence'; if ([long]$value.Chronology.StateSequence -le 0) { throw 'Issue #10 widget StateSequence must be positive.' }
    $widgetRoot = Split-Path -Parent ([IO.Path]::GetFullPath($Path))
    Assert-I10ExactProperties $value.Dashboard @('StateSha256','CapturePath','CaptureBytes','CaptureSha256') "Issue #10 $ExpectedLanguage Dashboard"
    Assert-I10Sha256 $value.Dashboard.StateSha256 "Issue #10 $ExpectedLanguage Dashboard state"; if (@($Runtime.StateHashes) -notcontains [string]$value.Dashboard.StateSha256) { throw "Issue #10 $ExpectedLanguage Dashboard state is not in the runtime state hash set." }
    $dashboardCapture = Assert-I10Capture -Root $widgetRoot -RelativePath ([string]$value.Dashboard.CapturePath) -ExpectedBytes ([long]$value.Dashboard.CaptureBytes) -ExpectedSha256 ([string]$value.Dashboard.CaptureSha256) -Context "Issue #10 $ExpectedLanguage Dashboard capture" -Transaction $Transaction
    $widgets = @($value.Widgets); if ($widgets.Count -ne 3) { throw "Issue #10 $ExpectedLanguage must have exactly three widget captures." }
    $seen = @{}
    foreach ($widget in $widgets) {
        Assert-I10ExactProperties $widget @('Name','StateSha256','SourceStateSha256','CapturePath','CaptureBytes','CaptureSha256') "Issue #10 $ExpectedLanguage widget"
        if ($widget.Name -notin @('Compact','Normal','FloatingVertical') -or $seen.ContainsKey([string]$widget.Name)) { throw "Issue #10 $ExpectedLanguage has an unknown or duplicate widget name." }
        $seen[[string]$widget.Name] = $true; Assert-I10Sha256 $widget.StateSha256 "Issue #10 $ExpectedLanguage widget state"; Assert-I10Sha256 $widget.SourceStateSha256 "Issue #10 $ExpectedLanguage widget source state"
        if ([string]$widget.StateSha256 -cne [string]$value.Dashboard.StateSha256 -or [string]$widget.SourceStateSha256 -cne [string]$value.Dashboard.StateSha256) { throw "Issue #10 $ExpectedLanguage widget state does not equal Dashboard state." }
        if (@($Runtime.StateHashes) -notcontains [string]$widget.StateSha256) { throw "Issue #10 $ExpectedLanguage widget state is not runtime-bound." }
        Assert-I10Capture -Root $widgetRoot -RelativePath ([string]$widget.CapturePath) -ExpectedBytes ([long]$widget.CaptureBytes) -ExpectedSha256 ([string]$widget.CaptureSha256) -Context "Issue #10 $ExpectedLanguage $($widget.Name) capture" -Transaction $Transaction | Out-Null
    }
    $attention = @($value.AttentionStates); if ($attention.Count -ne 2) { throw "Issue #10 $ExpectedLanguage must have exactly Blocked and Done attention states." }
    $fingerprints = @{}; $statuses = @{}
    foreach ($item in $attention) {
        Assert-I10ExactProperties $item @('Name','Status','SemanticFingerprint','CapturePath','CaptureBytes','CaptureSha256') "Issue #10 $ExpectedLanguage attention state"
        if ($item.Name -notin @('Blocked','Done') -or $item.Status -notin @('Blocked','Done') -or $item.Name -cne $item.Status -or $statuses.ContainsKey([string]$item.Status)) { throw 'Issue #10 attention states are missing, duplicate, or mislabeled.' }
        Assert-I10Sha256 $item.SemanticFingerprint 'Issue #10 attention semantic fingerprint'; if ($fingerprints.ContainsKey([string]$item.SemanticFingerprint)) { throw 'Blocked and Done attention states collapse to one semantic fingerprint.' }
        $fingerprints[[string]$item.SemanticFingerprint] = $true; $statuses[[string]$item.Status] = $true
        Assert-I10Capture -Root $widgetRoot -RelativePath ([string]$item.CapturePath) -ExpectedBytes ([long]$item.CaptureBytes) -ExpectedSha256 ([string]$item.CaptureSha256) -Context "Issue #10 $($item.Status) attention capture" -Transaction $Transaction | Out-Null
    }
    Assert-I10ExactProperties $value.UnknownPolicy @('UnknownDataRendersUnknown','OfflineDataRendersUnknown','UnknownState','OfflineState','NoSyntheticSuccess','SyntheticFieldsCount') 'Issue #10 unknown-data policy'
    foreach ($name in @('UnknownDataRendersUnknown','OfflineDataRendersUnknown','NoSyntheticSuccess')) { Assert-I10Boolean $value.UnknownPolicy.$name "Issue #10 unknown policy $name"; if (-not [bool]$value.UnknownPolicy.$name) { throw "Issue #10 unknown policy $name must be true." } }
    foreach ($name in @('UnknownState','OfflineState')) { if ([string]::IsNullOrWhiteSpace([string]$value.UnknownPolicy.$name) -or [string]$value.UnknownPolicy.$name -in @('PASS','Success','Done')) { throw "Issue #10 unknown policy $name is unsafe." } }
    Assert-I10Integer $value.UnknownPolicy.SyntheticFieldsCount 'Issue #10 unknown policy synthetic field count' -AllowZero; if ([int]$value.UnknownPolicy.SyntheticFieldsCount -ne 0) { throw 'Issue #10 widget evidence contains synthetic success fields.' }
    [pscustomobject][ordered]@{ Path = [IO.Path]::GetFullPath($Path); Hash = $read.Held.Sha256; Language = $ExpectedLanguage; StateSha256 = [string]$value.Dashboard.StateSha256; WidgetStateSha256 = [string]$value.Widgets[0].StateSha256; Value = $value }
}

function Assert-I10PackageIdentityShape {
    param([Parameter(Mandatory = $true)]$Identity,[Parameter(Mandatory = $true)][string]$ExpectedSourceCommit,[Parameter(Mandatory = $true)][string]$ExpectedSourceTree,[Parameter(Mandatory = $true)]$Archive,[Parameter(Mandatory = $true)]$Manifest,[Parameter(Mandatory = $true)]$App,[Parameter(Mandatory = $true)]$Core)
    Assert-I10ExactProperties $Identity @('schemaVersion','profileId','issue','packageVersion','runtimeIdentifier','source','profile','archive','packageManifest','components','referenceHost','renderer','evidenceBoundary') 'Package identity receipt'
    if ([int]$Identity.schemaVersion -ne 1 -or [string]$Identity.profileId -cne 'herdrops-v0.2-package-software-only-issue-149' -or [int]$Identity.issue -ne 149 -or [string]$Identity.packageVersion -cne '0.2.0' -or [string]$Identity.runtimeIdentifier -cne 'win-x64') { throw 'Package identity receipt has an invalid fixed identity.' }
    Assert-I10ExactProperties $Identity.source @('commitSha','treeSha') 'Package identity source'; Assert-I10Commit ([string]$Identity.source.commitSha) 'Package identity source commit'; Assert-I10Commit ([string]$Identity.source.treeSha) 'Package identity source tree'; if ([string]$Identity.source.commitSha -cne $ExpectedSourceCommit -or [string]$Identity.source.treeSha -cne $ExpectedSourceTree) { throw 'Package identity receipt source is not exact.' }
    Assert-I10ExactProperties $Identity.profile @('id','relativePath','bytes','fileSha256','canonicalSha256') 'Package identity profile'; if ([string]$Identity.profile.id -cne 'herdrops-v0.2-package-software-only-issue-149' -or [string]$Identity.profile.relativePath -cne 'tools/packaging/v0.2/package-identity-profile.json') { throw 'Package identity profile authority is not the governed profile.' }; Assert-I10Integer $Identity.profile.bytes 'Package identity profile bytes'; Assert-I10Sha256 $Identity.profile.fileSha256 'Package identity profile fileSha256'; Assert-I10Sha256 $Identity.profile.canonicalSha256 'Package identity profile canonicalSha256'
    Assert-I10ExactProperties $Identity.archive @('relativePath','fileName','bytes','sha256') 'Package identity archive'; if ([string]$Identity.archive.relativePath -cne 'HerdrOps-0.2.0-win-x64.zip' -or [string]$Identity.archive.fileName -cne 'HerdrOps-0.2.0-win-x64.zip') { throw 'Package identity archive name/path is not governed.' }; Assert-I10Integer $Identity.archive.bytes 'Package identity archive bytes'; Assert-I10Sha256 $Identity.archive.sha256 'Package identity archive sha256'; if ([long]$Identity.archive.bytes -ne $Archive.Length -or [string]$Identity.archive.sha256.ToUpperInvariant() -cne [string]$Archive.Sha256.ToUpperInvariant()) { throw 'Package identity archive leaf does not match the held archive.' }
    Assert-I10ExactProperties $Identity.packageManifest @('fileName','bytes','sha256','contentSha256','fileCount','totalBytes') 'Package identity packageManifest'; if ([string]$Identity.packageManifest.fileName -cne 'package-manifest.json') { throw 'Package identity manifest name is not governed.' }; Assert-I10Integer $Identity.packageManifest.bytes 'Package identity manifest bytes'; Assert-I10Sha256 $Identity.packageManifest.sha256 'Package identity manifest sha256'; Assert-I10Sha256 $Identity.packageManifest.contentSha256 'Package identity manifest contentSha256'; Assert-I10Integer $Identity.packageManifest.fileCount 'Package identity manifest fileCount'; Assert-I10Integer $Identity.packageManifest.totalBytes 'Package identity manifest totalBytes'; if ([long]$Identity.packageManifest.bytes -ne $Manifest.Length -or [string]$Identity.packageManifest.sha256.ToUpperInvariant() -cne [string]$Manifest.Sha256.ToUpperInvariant()) { throw 'Package identity manifest leaf does not match the held manifest.' }
    Assert-I10ExactProperties $Identity.components @('app','core') 'Package identity components'; foreach ($pair in @(@('app',$Identity.components.app,$App,'HerdrOps.App.exe'),@('core',$Identity.components.core,$Core,'HerdrOps.Core.exe'))) { Assert-I10ExactProperties $pair[1] @('relativePath','bytes','sha256') "Package identity $($pair[0])"; if ([string]$pair[1].relativePath -cne $pair[3]) { throw "Package identity $($pair[0]) path is not governed." }; Assert-I10Integer $pair[1].bytes "Package identity $($pair[0]) bytes"; Assert-I10Sha256 $pair[1].sha256 "Package identity $($pair[0]) sha256"; if ([long]$pair[1].bytes -ne $pair[2].Length -or [string]$pair[1].sha256.ToUpperInvariant() -cne [string]$pair[2].Sha256.ToUpperInvariant()) { throw "Package identity $($pair[0]) leaf does not match the held bytes." } }
    Assert-I10ExactProperties $Identity.referenceHost @('profileId','profileSha256') 'Package identity referenceHost'; if ([string]$Identity.referenceHost.profileId -cne 'herdrops-v0.2-submark-nb-software-only-20260822') { throw 'Package identity reference-host profile is not governed.' }; Assert-I10Sha256 $Identity.referenceHost.profileSha256 'Package identity reference-host profileSha256'; if ([string]$Identity.referenceHost.profileSha256 -cne '96D01ED15A536F2DF50B59B43CFDEB3683DCE8667AE2E7BF6A96124182FE13A3') { throw 'Package identity reference-host authority hash is not exact.' }
    Assert-I10ExactProperties $Identity.renderer @('policy','wpfProcessRenderMode') 'Package identity renderer'; if ([string]$Identity.renderer.policy -cne 'software-only-process-wide' -or [string]$Identity.renderer.wpfProcessRenderMode -cne 'SoftwareOnly') { throw 'Package identity renderer policy is not governed.' }
    Assert-I10ExactProperties $Identity.evidenceBoundary @('evidenceClass','runtimeUse','actualHerdrUsed','runtimeCredit','releaseCredit') 'Package identity evidenceBoundary'; if ([string]$Identity.evidenceBoundary.evidenceClass -cne 'PackagedCompatibilityPreparation' -or [string]$Identity.evidenceBoundary.runtimeUse -cne 'not-used' -or [bool]$Identity.evidenceBoundary.actualHerdrUsed -or [string]$Identity.evidenceBoundary.runtimeCredit -cne 'NOT CLAIMED' -or [string]$Identity.evidenceBoundary.releaseCredit -cne 'NOT CLAIMED') { throw 'Package identity receipt claims forbidden runtime or release authority.' }
}

function Assert-I10PackageBinding {
    param([Parameter(Mandatory = $true)]$Package,[Parameter(Mandatory = $true)][string]$ExpectedSourceCommit,[Parameter(Mandatory = $true)][string]$ExpectedSourceTree,[Parameter(Mandatory = $true)]$Transaction)
    foreach ($name in @('IdentityPath','ArchivePath','PackageRoot','ManifestPath','AppPath','CorePath','IdentityFileSha256','ReceiptSha256','ArchiveSha256','ManifestSha256','AppSha256','CoreSha256')) { if ($null -eq $Package.PSObject.Properties[$name]) { throw "Package binding omitted '$name'." } }
    if ($null -ne $Package.PSObject.Properties['IdentityReceiptSha256']) { throw 'Legacy IdentityReceiptSha256 is not accepted; supply separate raw IdentityFileSha256 and canonical ReceiptSha256.' }
    Assert-I10Sha256 $Package.IdentityFileSha256 'Package identity raw-byte SHA-256'; Assert-I10Sha256 $Package.ReceiptSha256 'Package identity canonical SHA-256'; Assert-I10Sha256 $Package.ArchiveSha256 'Package archive SHA-256'; Assert-I10Sha256 $Package.ManifestSha256 'Package manifest SHA-256'; Assert-I10Sha256 $Package.AppSha256 'Package App SHA-256'; Assert-I10Sha256 $Package.CoreSha256 'Package Core SHA-256'
    Assert-I10Sha256 $Package.ReceiptSha256 'Package receipt SHA-256'; Assert-I10Sha256 $Package.ArchiveSha256 'Package archive SHA-256'; Assert-I10Sha256 $Package.ManifestSha256 'Package manifest SHA-256'; Assert-I10Sha256 $Package.AppSha256 'Package App SHA-256'; Assert-I10Sha256 $Package.CoreSha256 'Package Core SHA-256'
    if ($null -ne $Package.SourceCommit -and [string]$Package.SourceCommit -cne $ExpectedSourceCommit) { throw 'Package source commit is not exact.' }; if ($null -ne $Package.SourceTree -and [string]$Package.SourceTree -cne $ExpectedSourceTree) { throw 'Package source tree is not exact.' }
    $root = [IO.Path]::GetFullPath([string]$Package.PackageRoot); Assert-I10NoReparsePath -Root $root -Path $root -Context 'Package root'
    foreach ($pair in @(@('manifest',$Package.ManifestPath),@('App',$Package.AppPath),@('Core',$Package.CorePath))) { Assert-I10NoReparsePath -Root $root -Path ([string]$pair[1]) -Context "Package $($pair[0]) path" }

    $identity = Get-I10TransactionFile -Transaction $Transaction -Path ([string]$Package.IdentityPath) -MaximumBytes 16777216 -Context 'Package identity receipt'
    $archive = Get-I10TransactionFile -Transaction $Transaction -Path ([string]$Package.ArchivePath) -MaximumBytes 1073741824 -Context 'Package archive'
    $manifest = Get-I10TransactionFile -Transaction $Transaction -Path ([string]$Package.ManifestPath) -MaximumBytes 67108864 -Context 'Package manifest'
    $app = Get-I10TransactionFile -Transaction $Transaction -Path ([string]$Package.AppPath) -MaximumBytes 1073741824 -Context 'Package App'
    $core = Get-I10TransactionFile -Transaction $Transaction -Path ([string]$Package.CorePath) -MaximumBytes 1073741824 -Context 'Package Core'

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

    Assert-I10PackageIdentityShape -Identity $identityValue -ExpectedSourceCommit $ExpectedSourceCommit -ExpectedSourceTree $ExpectedSourceTree -Archive $archive -Manifest $manifest -App $app -Core $core
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

    if ($identityFileSha256 -cne [string]$Package.IdentityFileSha256.ToUpperInvariant()) { throw 'Package identity receipt held file bytes hash does not match IdentityFileSha256.' }
    if ($identityCanonicalSha256 -cne [string]$Package.ReceiptSha256.ToUpperInvariant()) { throw 'Package identity receipt held canonical hash does not match ReceiptSha256.' }

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
        ReceiptSha256 = $identityCanonicalSha256
        IdentityFileSha256 = $identityFileSha256
        IdentityCanonicalSha256 = $identityCanonicalSha256
        IdentityLength = $identity.Length
        ArchiveSha256 = $archive.Sha256
        ArchiveLength = $archive.Length
        ManifestSha256 = $manifest.Sha256
        ManifestLength = $manifest.Length
        AppSha256 = $app.Sha256
        AppLength = $app.Length
        CoreSha256 = $core.Sha256
        CoreLength = $core.Length
        ProfileId = if ($null -ne $identityValue.profileId) { [string]$identityValue.profileId } else { $null }
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
        [Parameter(Mandatory = $true)][ValidatePattern('^[0-9a-f]{32}$')][string]$RunNonce,
        [Parameter(Mandatory = $true)][DateTimeOffset]$EvidenceStartedUtc,
        [switch]$FixtureMode
    )
    Assert-I10Commit $ExpectedSourceCommit 'ExpectedSourceCommit'; Assert-I10Commit $ExpectedSourceTree 'ExpectedSourceTree'; Assert-I10RunNonce -Value $RunNonce -Context 'Issue #10 RunNonce' | Out-Null
    $trustedNowUtc = [DateTimeOffset]::UtcNow
    $evidenceStartUtc = $EvidenceStartedUtc.ToUniversalTime()
    if ($evidenceStartUtc -gt $trustedNowUtc.AddSeconds(30) -or $evidenceStartUtc -lt $trustedNowUtc.AddHours(-6)) { throw "Issue #10 EvidenceStartedUtc is outside the trusted six-hour invocation window. Start=$($evidenceStartUtc.ToString('O')) Now=$($trustedNowUtc.ToString('O'))." }
    $rootFull = [IO.Path]::GetFullPath($EvidenceRoot)
    Assert-I10NoReparsePath -Root $rootFull -Path $rootFull -Context 'Issue #10 evidence root'
    $transaction = New-I10AcceptanceTransaction -Root $rootFull -RunNonce $RunNonce -EvidenceStartedUtc $evidenceStartUtc -TrustedNowUtc $trustedNowUtc
    try {
        Open-I10RunNonceClaim -Transaction $transaction
        foreach ($inputPath in @($ThaiWidgetReportPath,$EnglishWidgetReportPath,$ThaiRuntimeGatePath,$EnglishRuntimeGatePath,$PerformanceReceiptPath,$SoakReceiptPath,$PackageBinding.IdentityPath,$PackageBinding.ArchivePath,$PackageBinding.PackageRoot,$OutputPath)) {
            Assert-I10NoReparsePath -Root $rootFull -Path ([IO.Path]::GetFullPath($inputPath)) -Context 'Issue #10 evidence input'
        }
        $package = Assert-I10PackageBinding -Package $PackageBinding -ExpectedSourceCommit $ExpectedSourceCommit -ExpectedSourceTree $ExpectedSourceTree -Transaction $transaction
        Invoke-I10TestHook -Name 'AfterPackageBinding' -Transaction $transaction -Data $package
        $performance = Assert-I10PerformanceReceipt -Path $PerformanceReceiptPath -EvidenceRoot $EvidenceRoot -ExpectedSourceCommit $ExpectedSourceCommit -ExpectedSourceTree $ExpectedSourceTree -Package $package -ExpectedRunNonce $RunNonce -EvidenceStartedUtc $evidenceStartUtc -TrustedNowUtc $trustedNowUtc -Transaction $transaction
        $soak = Assert-I10SoakReceipt -Path $SoakReceiptPath -ExpectedSourceCommit $ExpectedSourceCommit -ExpectedSourceTree $ExpectedSourceTree -Package $package -ExpectedRunNonce $RunNonce -EvidenceStartedUtc $evidenceStartUtc -TrustedNowUtc $trustedNowUtc -Transaction $transaction
        $thaiRuntime = Get-I10GateReport -Path $ThaiRuntimeGatePath -ExpectedLanguage 'Thai' -ExpectedSourceCommit $ExpectedSourceCommit -ExpectedSourceTree $ExpectedSourceTree -Package $package -PerformanceSha256 $performance.Hash -SoakSha256 $soak.Hash -ExpectedRunNonce $RunNonce -EvidenceStartedUtc $evidenceStartUtc -TrustedNowUtc $trustedNowUtc -Transaction $transaction
        $englishRuntime = Get-I10GateReport -Path $EnglishRuntimeGatePath -ExpectedLanguage 'English' -ExpectedSourceCommit $ExpectedSourceCommit -ExpectedSourceTree $ExpectedSourceTree -Package $package -PerformanceSha256 $performance.Hash -SoakSha256 $soak.Hash -ExpectedRunNonce $RunNonce -EvidenceStartedUtc $evidenceStartUtc -TrustedNowUtc $trustedNowUtc -Transaction $transaction
        foreach ($name in @('HerdrExecutableSha256','ControlSession','TargetSession')) { if ([string]$thaiRuntime.$name -cne [string]$englishRuntime.$name) { throw "Thai and English runtime $name bindings differ." } }
        $thaiWidget = Assert-I10WidgetReport -Path $ThaiWidgetReportPath -ExpectedLanguage 'Thai' -ExpectedSourceCommit $ExpectedSourceCommit -ExpectedSourceTree $ExpectedSourceTree -Runtime $thaiRuntime -Performance $performance -Soak $soak -Package $package -ExpectedRunNonce $RunNonce -EvidenceStartedUtc $evidenceStartUtc -TrustedNowUtc $trustedNowUtc -Transaction $transaction
        $englishWidget = Assert-I10WidgetReport -Path $EnglishWidgetReportPath -ExpectedLanguage 'English' -ExpectedSourceCommit $ExpectedSourceCommit -ExpectedSourceTree $ExpectedSourceTree -Runtime $englishRuntime -Performance $performance -Soak $soak -Package $package -ExpectedRunNonce $RunNonce -EvidenceStartedUtc $evidenceStartUtc -TrustedNowUtc $trustedNowUtc -Transaction $transaction
        if ([string]$thaiWidget.StateSha256 -cne [string]$englishWidget.StateSha256 -or [string]$thaiWidget.WidgetStateSha256 -cne [string]$englishWidget.WidgetStateSha256) { throw 'Thai and English widget candidates do not match the same Dashboard state.' }
        Invoke-I10TestHook -Name 'AfterEvidenceValidation' -Transaction $transaction -Data $null
        Assert-I10TransactionStable -Transaction $transaction -Context 'Issue #10 pre-publication transaction'
        $runtimeInput = 'OBSERVED_AND_BOUND'
        if ($FixtureMode) { $runtimeInput = 'SYNTHETIC_FIXTURE_BOUND' }
        $candidate = [pscustomobject][ordered]@{
            SchemaVersion = 1
            EvidenceClassification = 'Issue10RuntimeCandidate'
            Issue = 10
            Result = 'PASS'
            RunNonce = $RunNonce
            EvidenceStartedUtc = $evidenceStartUtc.ToString('O')
            Source = [pscustomobject][ordered]@{ CommitSha = $ExpectedSourceCommit; TreeSha = $ExpectedSourceTree }
            Package = [pscustomobject][ordered]@{ IdentityFileSha256 = $package.IdentityFileSha256; IdentityReceiptSha256 = $package.ReceiptSha256; ArchiveSha256 = $package.ArchiveSha256; ManifestSha256 = $package.ManifestSha256; AppSha256 = $package.AppSha256; CoreSha256 = $package.CoreSha256 }
            Runtime = [pscustomobject][ordered]@{ ThaiGateSha256 = $thaiRuntime.Hash; EnglishGateSha256 = $englishRuntime.Hash; AppReportSha256 = [string]$thaiRuntime.AppHash; CoreReportSha256 = [string]$thaiRuntime.CoreHash; HerdrExecutableSha256 = $thaiRuntime.HerdrExecutableSha256; ControlSession = $thaiRuntime.ControlSession; TargetSession = $thaiRuntime.TargetSession; StateHashes = @($thaiRuntime.StateHashes) }
            Performance = [pscustomobject][ordered]@{ ReceiptPath = $performance.Path; ReceiptSha256 = $performance.Hash; RawSourcePath = $performance.RawSourcePath; RawSourceSha256 = $performance.RawSourceHash; Limits = [pscustomobject]$script:I10ApprovedLimits }
            Soak = [pscustomobject][ordered]@{ ReceiptPath = $soak.Path; ReceiptSha256 = $soak.Hash; AcMinutes = 60; BatteryMinutes = 60 }
            Languages = @([pscustomobject][ordered]@{ Language = 'Thai'; WidgetReportPath = $thaiWidget.Path; WidgetReportSha256 = $thaiWidget.Hash; DashboardStateSha256 = $thaiWidget.StateSha256 },[pscustomobject][ordered]@{ Language = 'English'; WidgetReportPath = $englishWidget.Path; WidgetReportSha256 = $englishWidget.Hash; DashboardStateSha256 = $englishWidget.StateSha256 })
            EvidenceBoundary = [pscustomobject][ordered]@{ RuntimeInput = $runtimeInput; Runtime = 'NOT_OBSERVED'; Human = 'NOT_OBSERVED'; Release = 'NOT_OBSERVED'; CreditGranted = $false; FixtureMode = [bool]$FixtureMode }
        }
        Assert-I10ExactProperties $candidate @('SchemaVersion','EvidenceClassification','Issue','Result','RunNonce','EvidenceStartedUtc','Source','Package','Runtime','Performance','Soak','Languages','EvidenceBoundary') 'Issue #10 candidate schema'
        Assert-I10ExactProperties $candidate.Package @('IdentityFileSha256','IdentityReceiptSha256','ArchiveSha256','ManifestSha256','AppSha256','CoreSha256') 'Issue #10 candidate package schema'
        $json = ConvertTo-V02Jcs $candidate
        $published = Publish-I10NoClobber -Root $EvidenceRoot -Path $OutputPath -Text ($json + "`n") -Context 'Issue #10 candidate' -Transaction $transaction
        return [pscustomobject][ordered]@{ Candidate = $candidate; CandidatePath = $published.Path; CandidateSha256 = $published.Sha256; CandidateFileId = $published.FileId; CandidateLinkCount = $published.LinkCount }
    }
    finally { Close-I10AcceptanceTransaction -Transaction $transaction }
}

function Publish-I10NoClobber {
    param([Parameter(Mandatory = $true)][string]$Root,[Parameter(Mandatory = $true)][string]$Path,[Parameter(Mandatory = $true)][string]$Text,[Parameter(Mandatory = $true)][string]$Context,[AllowNull()]$Transaction)
    $fullRoot = [IO.Path]::GetFullPath($Root); $fullPath = [IO.Path]::GetFullPath($Path); Assert-I10NoReparsePath -Root $fullRoot -Path $fullPath -Context "$Context destination"
    if ($null -ne $Transaction) { Assert-I10TransactionStable -Transaction $Transaction -Context "$Context transaction before destination reservation" }
    if (Test-Path -LiteralPath $fullPath) { throw "$Context refuses to clobber an existing destination." }
    $parent = Split-Path -Parent $fullPath; if (-not (Test-Path -LiteralPath $parent -PathType Container)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }; Assert-I10NoReparsePath -Root $fullRoot -Path $parent -Context "$Context parent"
    $stage = Join-Path $parent ('.issue10-stage-' + [Guid]::NewGuid().ToString('N') + '.json'); $bytes = [Text.UTF8Encoding]::new($false, $true).GetBytes($Text); $stageHeld = $null
    try {
        $stream = New-Object IO.FileStream($stage, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::Read)
        try { $stream.Write($bytes, 0, $bytes.Length); $stream.Flush($true) } finally { $stream.Dispose() }
        $stageHeld = Read-I10HeldFile -Path $stage -MaximumBytes 67108864 -Context "$Context staging file"; if ($stageHeld.Sha256 -cne (Get-I10Sha256Bytes -Bytes $bytes)) { throw "$Context staging bytes changed before publication." }
        Invoke-I10TestHook -Name 'AfterDestinationCheck' -Transaction $Transaction -Data $fullPath
        if ($null -ne $Transaction) { Assert-I10TransactionStable -Transaction $Transaction -Context "$Context transaction before no-clobber move" }
        [IO.File]::Move($stage, $fullPath)
        $published = Read-I10HeldFile -Path $fullPath -MaximumBytes 67108864 -Context "$Context published file"
        if ($published.Sha256 -cne $stageHeld.Sha256 -or $published.Length -ne $stageHeld.Length -or $published.FileId -cne $stageHeld.FileId -or $published.LinkCount -ne $stageHeld.LinkCount) { throw "$Context changed file identity/bytes during no-clobber publication." }
        return $published
    }
    finally { if (Test-Path -LiteralPath $stage -PathType Leaf) { Remove-Item -LiteralPath $stage -Force -ErrorAction SilentlyContinue } }
}
