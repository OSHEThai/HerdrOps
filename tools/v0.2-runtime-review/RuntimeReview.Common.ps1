Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# This helper is deliberately independent from the v0.2 matrix publisher.  It
# consumes already-held runtime evidence and never turns that evidence into
# Runtime, Human, or Release authority.
. (Join-Path $PSScriptRoot '..\lib\V02ReferenceHostProfile.ps1')

if ($null -eq ('HerdrOps.RuntimeReview.HeldPath' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;
using Microsoft.Win32.SafeHandles;
namespace HerdrOps.RuntimeReview {
 public sealed class HeldPath : IDisposable {
  [StructLayout(LayoutKind.Sequential)] private struct Info { public uint Attr; public System.Runtime.InteropServices.ComTypes.FILETIME C,A,W; public uint Volume,SizeHigh,SizeLow,Links,IndexHigh,IndexLow; }
  [StructLayout(LayoutKind.Sequential)] private struct FileId128 { [MarshalAs(UnmanagedType.ByValArray,SizeConst=16)] public byte[] Value; }
  [StructLayout(LayoutKind.Sequential)] private struct FileIdInfo { public UInt64 Volume; public FileId128 Id; }
  [DllImport("kernel32.dll",CharSet=CharSet.Unicode,SetLastError=true)] static extern SafeFileHandle CreateFileW(string n,uint a,uint s,IntPtr sec,uint c,uint f,IntPtr t);
  [DllImport("kernel32.dll",SetLastError=true)] static extern bool GetFileInformationByHandle(SafeFileHandle h,out Info i);
  [DllImport("kernel32.dll",SetLastError=true)] static extern bool GetFileInformationByHandleEx(SafeFileHandle h,int c,out FileIdInfo i,uint n);
  [DllImport("kernel32.dll",CharSet=CharSet.Unicode,SetLastError=true)] static extern uint GetFinalPathNameByHandle(SafeFileHandle h,StringBuilder b,uint n,uint f);
  readonly SafeFileHandle handle; readonly bool directory;
  public string RequestedPath{get;private set;} public string FinalPath{get;private set;} public UInt64 VolumeSerialNumber{get;private set;} public string FileId{get;private set;} public UInt32 LinkCount{get;private set;}
  HeldPath(string p,bool d,bool deleteShare){RequestedPath=Path.GetFullPath(p);directory=d;uint share=d?3u:1u;if(deleteShare)share|=4u;handle=CreateFileW(RequestedPath,0x80000000u,share,IntPtr.Zero,3u,d?0x02000000u:0x08000000u,IntPtr.Zero);if(handle.IsInvalid)throw new Win32Exception(Marshal.GetLastWin32Error(),"Unable to hold path: "+RequestedPath);Capture(true);}
  public static HeldPath OpenFile(string p){return new HeldPath(p,false,false);} public static HeldPath OpenStagingFile(string p){return new HeldPath(p,false,true);} public static HeldPath OpenDirectory(string p){return new HeldPath(p,true,false);}
  static string Normalize(string v){if(v.StartsWith(@"\\?\UNC\",StringComparison.OrdinalIgnoreCase))return @"\\"+v.Substring(8);if(v.StartsWith(@"\\?\",StringComparison.OrdinalIgnoreCase))return v.Substring(4);return v;}
  void Capture(bool first){Info i;if(!GetFileInformationByHandle(handle,out i))throw new Win32Exception(Marshal.GetLastWin32Error(),"Unable to query held identity");FileIdInfo fi;if(!GetFileInformationByHandleEx(handle,18,out fi,(uint)Marshal.SizeOf(typeof(FileIdInfo))))throw new Win32Exception(Marshal.GetLastWin32Error(),"Unable to query held FileId");var b=new StringBuilder(32768);uint n=GetFinalPathNameByHandle(handle,b,(uint)b.Capacity,0);if(n==0||n>=b.Capacity)throw new Win32Exception(Marshal.GetLastWin32Error(),"Unable to query held final path");string final=Path.GetFullPath(Normalize(b.ToString()));string id=BitConverter.ToString(fi.Id.Value).Replace("-","");if(first){FinalPath=final;VolumeSerialNumber=fi.Volume;FileId=id;LinkCount=i.Links;}else if(!String.Equals(final,FinalPath,StringComparison.OrdinalIgnoreCase)||VolumeSerialNumber!=fi.Volume||!String.Equals(FileId,id,StringComparison.Ordinal)||LinkCount!=i.Links)throw new IOException("Held path identity changed");if(!directory&&i.Links!=1)throw new IOException("Held evidence leaf must have link-count=1");}
  public void AssertUnchanged(){Capture(false);} public void AssertMovedTo(string path){string old=FinalPath;FinalPath=Path.GetFullPath(path);try{Capture(false);}catch{FinalPath=old;throw;}} public byte[] ReadAllBytes(long max){if(directory)throw new InvalidOperationException();using(var alias=new SafeFileHandle(handle.DangerousGetHandle(),false))using(var s=new FileStream(alias,FileAccess.Read,65536,false)){if(s.Length<0||s.Length>max||s.Length>Int32.MaxValue)throw new IOException("Held file exceeds its bounded read");byte[] v=new byte[(int)s.Length];int o=0;while(o<v.Length){int r=s.Read(v,o,v.Length-o);if(r<=0)throw new EndOfStreamException();o+=r;}if(s.Position!=s.Length)throw new IOException("Held file length changed during read");Capture(false);return v;}}
  public void Dispose(){if(handle!=null)handle.Dispose();}
 }
}
'@
}

$script:V02RuntimeReviewMaximumFileBytes = [int64]16777216
$script:V02RuntimeReviewMaximumDirectoryBytes = [int64]67108864
$script:V02RuntimeReviewMaximumDirectoryFiles = 512
$script:V02RuntimeReviewMaximumJsonBytes = [int64]16777216
$script:V02RuntimeReviewIssueSet = @(7, 9, 10, 11, 149)
$script:V02RuntimeReviewGateFiles = @('gate-report.txt', 'app-runtime.json', 'core-runtime.json', 'app-progress.json', 'app-progress.json.history.jsonl')
$script:V02RuntimeReviewRequiredCaptureNames = @('dashboard-overview','dashboard-live-organization','dashboard-agent-detail','widget-compact','widget-normal','widget-floating-vertical','dashboard-overview-after-event','widget-floating-vertical-after-dashboard-close')
$script:V02RuntimeReviewMaximumAgeMinutes = 120
$script:V02RuntimeReviewHeldPaths = $null
$script:V02RuntimeReviewFixtureModeActive = $false
$script:V02RuntimeReviewFixtureReadHook = $null
$script:V02RuntimeReviewFixtureBeforeOpenHook = $null
$script:V02RuntimeReviewFixturePublishHook = $null
$script:V02RuntimeReviewGateFields = @(
    'AcceptanceControlPaneEnvironmentId','AcceptanceControlPaneObservedId','AcceptanceControlServerIdentity','AcceptanceControlSession','AcceptanceControlSocketPath','AdministratorRequired','AppAverageCpuPercent','AppAveragePrivateMemoryMB','AppAverageWorkingSetMB','AppMaximumWorkingSetMB','AppPrivateMemoryPreparationMB','AppResourceProcess','AppRuntimeReportSha256','AppSha256','AppWorkingSetPreparationMB','AutomatedTests','BootstrapCount','BundledSchemaSha256','CaptureDirectory','CombinedAverageWorkingSetMB','CombinedIdleCpuPercent','CombinedMaximumWorkingSetMB','CompletionSignalObserved','CompletionSignalSemantics','CoreAcceptedEventKindCheck','CoreAverageCpuPercent','CoreAveragePrivateMemoryMB','CoreAverageWorkingSetMB','CoreMaximumWorkingSetMB','CoreResourceProcess','CoreRuntimeReportSha256','CoreSha256','DashboardClosed','DashboardClosedUtc','DashboardResourcesReleased','DisconnectCount','DisconnectObservedUtc','EventAAgentStatusTransition','EventAIntegrity','EventATransition','EventBAgentStatusTransition','EventBBaselineEventCount','EventBIncrementTransition','EventBIntegrity','EventBTransition','EventObserved','EvidenceClass','EvidenceWindowsDuringIdle','ExpectedSourceCommit','ExpectedSourceTree','ExtractedPackageRoot','GeneratedUtc','HerdrExecutableSha256','HerdrOpsAppExecutableSha256AfterRun','HerdrOpsAppExecutableSha256BeforeLaunch','HerdrOpsAppExecutableSha256BoundToReports','HerdrOpsCoreExecutableSha256AfterRun','HerdrOpsCoreExecutableSha256BeforeLaunch','HerdrOpsCoreExecutableSha256BoundToReports','HerdrProtocol','HerdrReleaseId','IdleCpuTargetPercent','IdleEventCount','IdleQuiescenceSeconds','IdleQuiescenceState','IdleQuiescenceWindow','IdleStateSequence','IdleWorkingSetStatistic','IdleWorkingSetTargetBytes','IdleWorkingSetTargetMB','InitialEventCount','InitialTargetTransition','Language','ManagedCaptureCleanup','ManagedHeapPreparationMB','PackageArchivePath','PackageArchiveSha256','PackageIdentityFileSha256','PackageIdentityPath','PackageIdentityReceiptSha256','PackageManifestPath','PackageManifestSha256','PackageProfileCanonicalSha256','PackageProfileFileSha256','PackageProfileId','PackageValidationEvidenceClass','PackageValidatorPath','PostCloseEventCount','PostRunGitTreeClean','PostRunSourceCommit','PostRunSourceTree','PreCloseEventCount','PreRestartBootstrapCount','PreRestartConnectionEpoch','PreRestartDisconnectCount','PreRunGitTreeClean','PreRunSourceCommit','PreRunSourceTree','ProgressHistoryEntries','ProgressHistoryLastEntrySha256','ProgressHistoryPath','ProgressHistorySha256','ReconnectedBootstrapCount','ReconnectedConnectionEpoch','ReconnectedDisconnectCount','ReconnectObserved','ReconnectObservedUtc','ReferenceHostProfileId','ReferenceHostProfileSha256','ReferenceHostSchemaSha256','RendererPolicyId','ResourceSampleCount','ResourceSampleIntervalMs','ResourceStagePreparationToleranceMB','Result','RunNonce','RuntimeFingerprintFinish','RuntimeFingerprintStable','RuntimeFingerprintStart','RuntimeWpfCaptures','SemanticCaptureBindingCheck','SeparateSessionSockets','SessionControlInvoked','SnapshotObserved','SoftwareOnlyThroughout','SourceCommit','SourceTree','TargetAgentLabSession','TargetAgentLabSocketPath','TargetAgentSessionReference','TargetAgentSessionReferenceBoundary','TargetAgentSessionReferenceEvidenceSource','TargetAgentSessionReferenceObservableByGate','TargetDisconnectTransition','TargetReconnectTransition','TcpListenersOwnedByCoreOrApp','TrxEvidenceDirectory','TrxSelectionReceiptPath','TrxSelectionReceiptSha256','UpdateAfterDashboardClose','WidgetLatencyBaselineSequence','WidgetLatencyMeasurement','WidgetLatencyMinimumSamples','WidgetLatencyP95Ms','WidgetLatencySamples','WidgetLatencyTargetMs','WidgetLatencyUnsupportedSamplesExcluded','WidgetLatencyWarmupSamplesExcluded','WpfProcessRenderMode'
)

function Start-V02RuntimeReviewHoldScope { $script:V02RuntimeReviewHeldPaths = New-Object Collections.Generic.List[IDisposable] }
function Add-V02RuntimeReviewHold { param([Parameter(Mandatory)]$Hold); if ($null -ne $script:V02RuntimeReviewHeldPaths) { $script:V02RuntimeReviewHeldPaths.Add($Hold); return $true }; return $false }
function Stop-V02RuntimeReviewHoldScope { if ($null -ne $script:V02RuntimeReviewHeldPaths) { for ($i=$script:V02RuntimeReviewHeldPaths.Count-1; $i-ge 0; $i--) { $script:V02RuntimeReviewHeldPaths[$i].Dispose() }; $script:V02RuntimeReviewHeldPaths=$null } }
function Assert-V02RuntimeReviewHoldScope { if($null-ne$script:V02RuntimeReviewHeldPaths){foreach($hold in $script:V02RuntimeReviewHeldPaths){$hold.AssertUnchanged()}} }

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
    $snapshot = [HerdrOps.RuntimeReview.HeldPath]::OpenFile($full)
    try { $snapshotVolume=$snapshot.VolumeSerialNumber;$snapshotFileId=$snapshot.FileId;$snapshotFinal=$snapshot.FinalPath } finally { $snapshot.Dispose() }
    if($script:V02RuntimeReviewFixtureModeActive-and$null-ne$script:V02RuntimeReviewFixtureBeforeOpenHook){& $script:V02RuntimeReviewFixtureBeforeOpenHook $full}
    $parentHold = [HerdrOps.RuntimeReview.HeldPath]::OpenDirectory([IO.Path]::GetDirectoryName($full))
    if(-not$parentHold.FinalPath.Equals([IO.Path]::GetDirectoryName($full),[StringComparison]::OrdinalIgnoreCase)){$parentHold.Dispose();throw "Held parent final path differs from its requested path: $full"}
    $fileHold = $null
    try {
        $fileHold = [HerdrOps.RuntimeReview.HeldPath]::OpenFile($full)
        if (-not $fileHold.FinalPath.Equals($full,[StringComparison]::OrdinalIgnoreCase)) { throw "Held file final path differs from its requested path: $full" }
        if($fileHold.VolumeSerialNumber-ne$snapshotVolume-or$fileHold.FileId-cne$snapshotFileId-or-not$fileHold.FinalPath.Equals($snapshotFinal,[StringComparison]::OrdinalIgnoreCase)){throw "Held file identity changed before open: $full"}
        if($script:V02RuntimeReviewFixtureModeActive-and$null-ne$script:V02RuntimeReviewFixtureReadHook){& $script:V02RuntimeReviewFixtureReadHook $full}
        $bytes = $fileHold.ReadAllBytes($MaximumBytes); $heldLength=[int64]$bytes.Length
        $hash = Get-V02RuntimeReviewHash $bytes
        $fileHold.AssertUnchanged(); $parentHold.AssertUnchanged(); Assert-V02RuntimeReviewNoReparseComponents $full 'held file after read'
    } catch { if ($null-ne$fileHold){$fileHold.Dispose()};$parentHold.Dispose();throw }
    if (-not(Add-V02RuntimeReviewHold $parentHold)){$parentHold.Dispose()};if(-not(Add-V02RuntimeReviewHold $fileHold)){$fileHold.Dispose()}
    $result = [pscustomobject][ordered]@{ Path=$full;Bytes=$heldLength;Sha256=$hash;VolumeSerialNumber=$fileHold.VolumeSerialNumber;FileId=$fileHold.FileId;LinkCount=$fileHold.LinkCount }
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

function Assert-V02RuntimeReviewNoAuthorityProperties {
    param($Value,[Parameter(Mandatory)][string]$Context)
    if($null-eq$Value-or$Value-is[string]-or$Value-is[ValueType]){return}
    if($Value-is[pscustomobject]){
        foreach($property in $Value.PSObject.Properties){
            if($property.Name-match'(?i)^(IndependentReview|ExternalReviewerAttestation|HumanVisualGo|RuntimeCredit|ReleaseCredit|Verdict|ReviewerAttestation|OutputAuthority)$'){throw "$Context contains caller-authored authority property '$($property.Name)'."}
            Assert-V02RuntimeReviewNoAuthorityProperties $property.Value "$Context.$($property.Name)"
        }
        return
    }
    if($Value-is[Collections.IEnumerable]){foreach($item in $Value){Assert-V02RuntimeReviewNoAuthorityProperties $item $Context}}
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

function Assert-V02RuntimeReviewRunNonce {
    param($Value, [Parameter(Mandatory)][string]$Context)
    $text = Assert-V02RuntimeReviewString $Value $Context
    if ($text -cnotmatch '^[0-9a-f]{32}$') { throw "$Context must be a lowercase 32-hex invocation nonce." }
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
    $recognized = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($field in $script:V02RuntimeReviewGateFields) { if (-not $recognized.Add($field)) { throw "Runtime-review gate contract duplicates '$field'." } }
    $canonicalText = @(
        'HerdrOps v0.2 Composite Actual Herdr Runtime Acceptance',
        'ResourceStageCheckpoints:', 'StateHashChain:', 'WidgetLatencyIncludedSamples:',
        'CaptureHashes:', 'EvidenceBoundary:',
        'This gate proves exact-hash-bound actual Herdr snapshot/Agent-status-event/reconnect behavior, separate Acceptance-control and Agent-Lab target sessions, Core-to-App runtime-health propagation, live production WPF page and Widget rendering, Dashboard-close continuity, state-hash correspondence, measured latency/resources, no owned TCP listener, and non-elevated operation for this host and run.',
        'It launches the App and Core from the package root whose receipt, ZIP, manifest, source, and component bytes passed the committed package validator. This is runtime use of validated package bytes, not clean-machine installation or Release evidence.',
        'The native target Agent/session reference is operator attestation because the gate cannot independently observe that client-owned session identity.',
        'It does not prove clean-machine installation, later-version features, independent human review, or future Herdr releases.'
    )
    $map = [Collections.Generic.Dictionary[string,string]]::new([StringComparer]::Ordinal)
    foreach ($line in ($text -split "`r?`n")) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        if ($line -match '^\s*#') { continue }
        if ($canonicalText -ccontains $line -or
            $line -match '^stage=[^\r\n]+ observed=[^\r\n]+ pid=[0-9]+ start=[^\r\n]+ workingSetMB=[^\r\n]+ privateMB=[^\r\n]+ pagedMB=[^\r\n]+ managedHeapMB=[^\r\n]+$' -or
            $line -match '^(Initial|BeforeDashboardClose|AfterDashboardClose): [0-9]+ [0-9A-F]{64}$' -or
            $line -match '^sequence=[0-9]+ event=[0-9]+ envelope=[0-9]+ correlation=[0-9a-fA-F-]{36} stateSha256=[0-9A-F]{64} kind=[^ ]+ accepted=[^ ]+ sent=[^ ]+ applied=[^ ]+ milliseconds=[^ ]+$' -or
            $line -match '^SHA256 [0-9A-F]{64} [a-z0-9-]+$') { continue }
        if ($line -notmatch '^([A-Za-z][A-Za-z0-9]{0,127}): (.+)$') { throw "Gate report contains a noncanonical line: '$line'." }
        $name = [string]$matches[1]
        if (-not $recognized.Contains($name)) { throw "Gate report contains unknown field '$name'." }
        if ($map.ContainsKey($name)) { throw "Gate report contains duplicate field '$name'." }
        $map[$name] = [string]$matches[2]
    }
    if($map.Count-ne$recognized.Count){$missing=@($recognized|Where-Object{-not$map.ContainsKey($_)});throw "Gate report has missing fields: $($missing -join ', ')."}
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
    $runNonce=Assert-V02RuntimeReviewRunNonce (Get-V02RuntimeReviewGateValue $Gate 'RunNonce' $context) "$context RunNonce"
    $generatedUtc=[DateTimeOffset]::MinValue
    if(-not[DateTimeOffset]::TryParse((Get-V02RuntimeReviewGateValue $Gate 'GeneratedUtc' $context),[Globalization.CultureInfo]::InvariantCulture,[Globalization.DateTimeStyles]::RoundtripKind,[ref]$generatedUtc)){throw "$context GeneratedUtc is not a round-trip timestamp."}
    $validationUtc=[DateTimeOffset]::UtcNow;$generatedUtc=$generatedUtc.ToUniversalTime()
    if($generatedUtc-gt$validationUtc-or$generatedUtc-lt$validationUtc.AddMinutes(-$script:V02RuntimeReviewMaximumAgeMinutes)){throw "$context is outside the bounded fresh review window."}
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
    return [pscustomobject][ordered]@{ Gate=$Gate;RunNonce=$runNonce;GeneratedUtc=$generatedUtc }
}

function Assert-V02RuntimeReviewEvent {
    param([Parameter(Mandatory)]$Event, [Parameter(Mandatory)][string]$Context)
    if ($null -eq $Event -or $Event -isnot [pscustomobject]) { throw "$Context must be a semantic event object." }
    $eventNames=@('PhaseEnteredUtc','ObservedUtc','AcceptedEventKind','AdmissionPath','BaselineConnectionEpoch','CurrentIsCoreConnected','CurrentIsLive','CurrentRuntimeStatus','BaselineSequence','CurrentSequence','BaselineEventCount','CurrentEventCount','BaselineBootstrapCount','CurrentBootstrapCount','BaselineDisconnectCount','CurrentDisconnectCount','BaselineReconciliationCount','CurrentReconciliationCount','BaselineStateSha256','CurrentStateSha256','BaselineAgentTopologySha256','CurrentAgentTopologySha256','BaselineAgentStatusStateSha256','CurrentAgentStatusStateSha256','ConnectionEpoch','Changes','ChangeCount','BaselineAllAgentsHaveLiveIdentity','CurrentAllAgentsHaveLiveIdentity')
    Assert-V02RuntimeReviewExactProperties $Event $eventNames $Context
    foreach ($name in $eventNames) { $null = Get-V02RuntimeReviewProperty $Event $name $Context }
    Assert-V02RuntimeReviewString $Event.AdmissionPath "$Context admission path" | Out-Null
    Assert-V02RuntimeReviewString $Event.AcceptedEventKind "$Context event kind" 'pane.agent_status_changed' | Out-Null
    Assert-V02RuntimeReviewSha256 $Event.CurrentStateSha256 "$Context state hash" | Out-Null
    Assert-V02RuntimeReviewInteger $Event.BaselineSequence "$Context baseline sequence" | Out-Null
    Assert-V02RuntimeReviewInteger $Event.CurrentSequence "$Context current sequence" | Out-Null
    Assert-V02RuntimeReviewInteger $Event.BaselineEventCount "$Context baseline event count" | Out-Null
    Assert-V02RuntimeReviewInteger $Event.CurrentEventCount "$Context current event count" | Out-Null
    if ([int64]$Event.CurrentSequence -le [int64]$Event.BaselineSequence -or [int64]$Event.CurrentEventCount -le [int64]$Event.BaselineEventCount) { throw "$Context does not show an event transition." }
    if (@($Event.Changes).Count -ne 1) { throw "$Context must contain exactly one semantic Agent change." }
    $phase=[DateTimeOffset]::MinValue;$observed=[DateTimeOffset]::MinValue
    if (-not [DateTimeOffset]::TryParse([string]$Event.PhaseEnteredUtc,[Globalization.CultureInfo]::InvariantCulture,[Globalization.DateTimeStyles]::RoundtripKind,[ref]$phase) -or -not [DateTimeOffset]::TryParse([string]$Event.ObservedUtc,[Globalization.CultureInfo]::InvariantCulture,[Globalization.DateTimeStyles]::RoundtripKind,[ref]$observed) -or $phase -gt $observed) { throw "$Context timestamps are invalid or reversed." }
    if([int64]$Event.ChangeCount-ne1-or-not[bool]$Event.BaselineAllAgentsHaveLiveIdentity-or-not[bool]$Event.CurrentAllAgentsHaveLiveIdentity){throw "$Context Agent identity/change metadata is not exact."}
    $change=@($Event.Changes)[0];$changeNames=@('TerminalId','WorkspaceId','TabId','PaneId','PreviousStatus','CurrentStatus','PreviousRevision','CurrentRevision','PreviousStateChangeSequence','CurrentStateChangeSequence','PreviousAgentKind','CurrentAgentKind','PreviousAgentName','CurrentAgentName');Assert-V02RuntimeReviewExactProperties $change $changeNames "$Context change";foreach($name in @('TerminalId','WorkspaceId','TabId','PaneId','PreviousStatus','CurrentStatus')){Assert-V02RuntimeReviewString (Get-V02RuntimeReviewProperty $change $name "$Context change") "$Context change $name"|Out-Null}
    if([string]$change.PreviousStatus-ceq[string]$change.CurrentStatus){throw "$Context did not change Agent status."}
    return [pscustomobject]@{PhaseEnteredUtc=$phase.ToUniversalTime();ObservedUtc=$observed.ToUniversalTime();Change=$change;Value=$Event}
}

function Assert-V02RuntimeReviewStateMappings {
    param([Parameter(Mandatory)]$Mappings,[Parameter(Mandatory)][string]$Context)
    $expected=@('Working','Idle','Blocked','Done','Unknown','Offline');$actual=@($Mappings)
    if($actual.Count-ne$expected.Count){throw "$Context must contain exactly six canonical state mappings."}
    for($i=0;$i-lt$expected.Count;$i++){Assert-V02RuntimeReviewExactProperties $actual[$i] @('SourceState','PresentationState') "$Context[$i]";if([string]$actual[$i].SourceState-cne$expected[$i]-or[string]$actual[$i].PresentationState-cne$expected[$i].ToLowerInvariant()){throw "$Context[$i] is not the exact canonical state mapping."}}
}

function Get-V02RuntimeReviewProgressCanonicalPayload {
    param([Parameter(Mandatory)]$Entry)
    $culture=[Globalization.CultureInfo]::InvariantCulture
    $accepted=if($null-eq$Entry.LastAcceptedStateUtc){''}else{([DateTimeOffset]$Entry.LastAcceptedStateUtc).ToUniversalTime().ToString('O',$culture)}
    return @(([int]$Entry.Ordinal).ToString($culture),[string]$Entry.Phase,([DateTimeOffset]$Entry.ObservedUtc).ToUniversalTime().ToString('O',$culture),([long]$Entry.Sequence).ToString($culture),$(if([bool]$Entry.IsCoreConnected){'True'}else{'False'}),$(if([bool]$Entry.IsLive){'True'}else{'False'}),[string]$Entry.RuntimeStatus,([DateTimeOffset]$Entry.LastTransitionUtc).ToUniversalTime().ToString('O',$culture),$accepted,([long]$Entry.ConnectionEpoch).ToString($culture),([long]$Entry.BootstrapCount).ToString($culture),([long]$Entry.EventCount).ToString($culture),([long]$Entry.DisconnectCount).ToString($culture),([long]$Entry.ReconciliationCount).ToString($culture),[string]$Entry.StateSha256,[string]$Entry.PreviousEntrySha256)-join'|'
}

function Assert-V02RuntimeReviewProgressEntry {
    param([Parameter(Mandatory)]$Entry,[int]$Ordinal,[string]$Previous,[string]$Context)
    $names=@('Ordinal','Phase','ObservedUtc','Sequence','IsCoreConnected','IsLive','RuntimeStatus','LastTransitionUtc','LastAcceptedStateUtc','ConnectionEpoch','BootstrapCount','EventCount','DisconnectCount','ReconciliationCount','StateSha256','PreviousEntrySha256','CanonicalPayload','EntrySha256')
    Assert-V02RuntimeReviewExactProperties $Entry $names $Context
    if((Assert-V02RuntimeReviewInteger $Entry.Ordinal "$Context ordinal" 1)-ne$Ordinal){throw "$Context ordinal is not exact."}
    foreach($name in @('Sequence','ConnectionEpoch','BootstrapCount','EventCount','DisconnectCount','ReconciliationCount')){$null=Assert-V02RuntimeReviewInteger $Entry.$name "$Context $name"}
    foreach($name in @('IsCoreConnected','IsLive')){if($Entry.$name-isnot[bool]){throw "$Context $name must be a native boolean."}}
    $observed=[DateTimeOffset]::MinValue;$transition=[DateTimeOffset]::MinValue;if(-not[DateTimeOffset]::TryParse([string]$Entry.ObservedUtc,[Globalization.CultureInfo]::InvariantCulture,[Globalization.DateTimeStyles]::RoundtripKind,[ref]$observed)-or-not[DateTimeOffset]::TryParse([string]$Entry.LastTransitionUtc,[Globalization.CultureInfo]::InvariantCulture,[Globalization.DateTimeStyles]::RoundtripKind,[ref]$transition)){throw "$Context timestamps are invalid."}
    $state=Assert-V02RuntimeReviewSha256 $Entry.StateSha256 "$Context state hash";$prior=Assert-V02RuntimeReviewSha256 $Entry.PreviousEntrySha256 "$Context previous hash";if($prior-cne$Previous){throw "$Context hash chain is broken."}
    $canonical=Get-V02RuntimeReviewProgressCanonicalPayload $Entry;if([string]$Entry.CanonicalPayload-cne$canonical){throw "$Context canonical payload is not exact."};$entryHash=Get-V02RuntimeReviewHash ([Text.UTF8Encoding]::new($false).GetBytes($canonical));if((Assert-V02RuntimeReviewSha256 $Entry.EntrySha256 "$Context entry hash")-cne$entryHash){throw "$Context entry hash is invalid."}
    return [pscustomobject]@{Value=$Entry;ObservedUtc=$observed.ToUniversalTime();StateSha256=$state;EntrySha256=$entryHash}
}

function Assert-V02RuntimeReviewProgress {
    param([string]$EvidenceDirectory,$Gate,$App,[string]$Context)
    $historyPath=Resolve-V02RuntimeReviewPath $EvidenceDirectory (Get-V02RuntimeReviewGateValue $Gate 'ProgressHistoryPath' $Context) "$Context progress history";if(-not$historyPath.Equals((Join-Path $EvidenceDirectory 'app-progress.json.history.jsonl'),[StringComparison]::OrdinalIgnoreCase)){throw "$Context progress history path is not canonical."}
    $historyHeld=Read-V02RuntimeReviewHeldFile $historyPath -IncludeBytes;if($historyHeld.Sha256-cne(Get-V02RuntimeReviewGateValue $Gate 'ProgressHistorySha256' $Context)){throw "$Context progress history hash is not exact."}
    try{$historyText=(New-Object Text.UTF8Encoding($false,$true)).GetString($historyHeld.Content)}catch{throw "$Context progress history is not strict UTF-8."};$lines=@($historyText -split "`r?`n"|Where-Object{$_-cne''})
    $phases=@('waiting-for-live-state','capturing-live-dashboard-and-widgets','waiting-for-pre-close-update','dashboard-closed-waiting-for-herdr-disconnect','herdr-disconnected-waiting-for-reconnect','herdr-reconnected-waiting-for-post-reconnect-update','waiting-for-idle-stability','measuring-idle-resources','complete');if($lines.Count-ne9-or[int](Get-V02RuntimeReviewGateValue $Gate 'ProgressHistoryEntries' $Context)-ne9){throw "$Context progress history must contain exactly nine records."}
    $entries=@();$previous='0'*64;$previousUtc=[DateTimeOffset]::MinValue;$previousEntry=$null;for($i=0;$i-lt9;$i++){try{$raw=(New-Object Text.UTF8Encoding($false)).GetBytes($lines[$i]);$entry=(ConvertFrom-V02RuntimeReviewStrictJson -Bytes $raw -Context "$Context progress entry $($i+1)").Value}catch{throw};$checked=Assert-V02RuntimeReviewProgressEntry $entry ($i+1) $previous "$Context progress entry $($i+1)";if([string]$entry.Phase-cne$phases[$i]-or($i-gt0-and$checked.ObservedUtc-le$previousUtc)){throw "$Context progress chronology/phase is invalid."};if($null-ne$previousEntry){foreach($name in @('Sequence','ConnectionEpoch','BootstrapCount','EventCount','DisconnectCount','ReconciliationCount')){if([long]$entry.$name-lt[long]$previousEntry.$name){throw "$Context progress counter $name moved backward."}}};$previousEntry=$entry;$previousUtc=$checked.ObservedUtc;$previous=$checked.EntrySha256;$entries+=$entry}
    if(-not[bool]$entries[3].IsCoreConnected-or[string]$entries[3].RuntimeStatus-cne'Connected'-or[bool]$entries[4].IsCoreConnected-or[string]$entries[4].RuntimeStatus-cne'Reconnecting'-or-not[bool]$entries[5].IsCoreConnected-or[string]$entries[5].RuntimeStatus-cne'Connected'){throw "$Context progress disconnect/reconnect semantics are invalid."}
    if((Get-V02RuntimeReviewGateValue $Gate 'ProgressHistoryLastEntrySha256' $Context)-cne$previous){throw "$Context progress final-entry hash is not derived."}
    $progressPath=Join-Path $EvidenceDirectory 'app-progress.json';$progress=(Read-V02RuntimeReviewStrictJsonFile $progressPath "$Context progress report").Value;$progressNames=@($entries[8].PSObject.Properties.Name)+@('ProgressHistoryPath','History');Assert-V02RuntimeReviewExactProperties $progress $progressNames "$Context progress report";if(-not([IO.Path]::GetFullPath([string]$progress.ProgressHistoryPath)).Equals($historyPath,[StringComparison]::OrdinalIgnoreCase)-or@($progress.History).Count-ne9){throw "$Context progress mirror is incomplete."}
    for($i=0;$i-lt9;$i++){Assert-V02RuntimeReviewExactProperties $progress.History[$i] $entries[$i].PSObject.Properties.Name "$Context progress mirror[$i]";if((ConvertTo-V02Jcs $progress.History[$i])-cne(ConvertTo-V02Jcs $entries[$i])){throw "$Context progress mirror differs from history."}}
    if([string]$progress.EntrySha256-cne$previous-or[string]$progress.StateSha256-cne[string]$App.EventB.CurrentStateSha256-or[long]$progress.Sequence-ne[long]$App.EventB.CurrentSequence){throw "$Context final progress is not EventB-bound."}
    return [pscustomobject]@{HistorySha256=$historyHeld.Sha256;LastEntrySha256=$previous;Entries=$entries;FirstUtc=([DateTimeOffset]$entries[0].ObservedUtc).ToUniversalTime();LastUtc=$previousUtc}
}

function Assert-V02RuntimeReviewSelectionReceipt {
    param([string]$EvidenceDirectory,$Gate,[string]$Context)
    $path=Resolve-V02RuntimeReviewPath $EvidenceDirectory (Get-V02RuntimeReviewGateValue $Gate 'TrxSelectionReceiptPath' $Context) "$Context selection receipt";if(-not$path.Equals((Join-Path $EvidenceDirectory 'test-results\selection-receipt.json'),[StringComparison]::OrdinalIgnoreCase)){throw "$Context selection receipt path is not canonical."};$doc=Read-V02RuntimeReviewStrictJsonFile $path "$Context selection receipt";if($doc.Sha256-cne(Get-V02RuntimeReviewGateValue $Gate 'TrxSelectionReceiptSha256' $Context)){throw "$Context selection receipt hash is not exact."}
    $r=$doc.Value;Assert-V02RuntimeReviewExactProperties $r @('SchemaVersion','InvocationStartedUtc','SelectionUpperBoundUtc','FileCount','Total','Passed','Failed','NotExecuted','Skipped','Files') "$Context selection receipt";if([int64]$r.SchemaVersion-ne2-or[int64]$r.FileCount-ne4-or[int64]$r.Total-ne913-or[int64]$r.Passed-ne913-or[int64]$r.Failed-ne0-or[int64]$r.NotExecuted-ne0-or[int64]$r.Skipped-ne0-or@($r.Files).Count-ne4){throw "$Context selection receipt counters are not governed and all-passing."};$started=[DateTimeOffset]$r.InvocationStartedUtc;$upper=[DateTimeOffset]$r.SelectionUpperBoundUtc;if($started-ge$upper){throw "$Context selection receipt chronology is invalid."}
    $names=@('HerdrOps.UnitTests.trx','HerdrOps.ContractTests.trx','HerdrOps.IntegrationTests.trx','HerdrOps.RuntimeTests.trx');$governedNames=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal);foreach($governedName in $names){$null=$governedNames.Add($governedName)};$seen=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal);$runIds=@{};$sum=0
    foreach($entry in @($r.Files)){
        Assert-V02RuntimeReviewExactProperties $entry @('Name','SourceName','Bytes','Sha256','LastWriteUtc','TestRunId','RunStartedUtc','RunFinishedUtc','TestAssemblyFileName','Total','Passed','Failed','NotExecuted','Skipped') "$Context selection entry"
        $name=[string]$entry.Name;$assembly=[IO.Path]::ChangeExtension($name,'.dll')
        if(-not$governedNames.Contains($name)-or$seen.Contains($name)-or[string]$entry.SourceName-cne$name-or[string]$entry.TestAssemblyFileName-cne$assembly){throw "$Context selection names/source/assembly identities are not exact and derivable."}
        $file=Resolve-V02RuntimeReviewPath ([IO.Path]::GetDirectoryName($path)) (Join-Path ([IO.Path]::GetDirectoryName($path)) $name) "$Context selected TRX"
        $held=Read-V02RuntimeReviewHeldFile $file -IncludeBytes
        if($held.Bytes-ne[int64]$entry.Bytes-or$held.Sha256-cne[string]$entry.Sha256){throw "$Context selected TRX bytes are not exact."}
        $settings=New-Object Xml.XmlReaderSettings;$settings.DtdProcessing=[Xml.DtdProcessing]::Prohibit;$settings.XmlResolver=$null
        $stream=$null;$reader=$null;try{$stream=New-Object IO.MemoryStream(,$held.Content);$reader=[Xml.XmlReader]::Create($stream,$settings);$xml=New-Object Xml.XmlDocument;$xml.XmlResolver=$null;$xml.Load($reader)}catch{throw "$Context selected TRX XML is invalid: $name"}finally{if($null-ne$reader){$reader.Dispose()};if($null-ne$stream){$stream.Dispose()}}
        $root=$xml.DocumentElement;if($null-eq$root-or$root.LocalName-cne'TestRun'){throw "$Context selected TRX root is not TestRun: $name"}
        $runId=[guid]::Empty;if(-not[guid]::TryParse($root.GetAttribute('id'),[ref]$runId)-or$runId-eq[guid]::Empty-or$runIds.ContainsKey($runId.ToString('D'))-or[string]$entry.TestRunId-cne$runId.ToString('D')){throw "$Context selected TRX run identity is not exact and unique."}
        $times=$root.SelectSingleNode("./*[local-name()='Times']");$runStart=[DateTimeOffset]::MinValue;$runFinish=[DateTimeOffset]::MinValue;if($null-eq$times-or-not[DateTimeOffset]::TryParse($times.GetAttribute('start'),[Globalization.CultureInfo]::InvariantCulture,[Globalization.DateTimeStyles]::RoundtripKind,[ref]$runStart)-or-not[DateTimeOffset]::TryParse($times.GetAttribute('finish'),[Globalization.CultureInfo]::InvariantCulture,[Globalization.DateTimeStyles]::RoundtripKind,[ref]$runFinish)-or$runStart-ge$runFinish-or$runStart-lt$started-or$runFinish-gt$upper-or[string]$entry.RunStartedUtc-cne$runStart.ToUniversalTime().ToString('O')-or[string]$entry.RunFinishedUtc-cne$runFinish.ToUniversalTime().ToString('O')){throw "$Context selected TRX chronology is not independently derived."}
        $assemblies=@($root.SelectNodes(".//*[local-name()='UnitTest']")|ForEach-Object{[IO.Path]::GetFileName($_.GetAttribute('storage'))}|Where-Object{-not[string]::IsNullOrWhiteSpace($_)}|Sort-Object -Unique);if($assemblies.Count-ne1-or[string]$assemblies[0]-cne$assembly){throw "$Context selected TRX assembly is not governed."}
        $counters=$root.SelectSingleNode("./*[local-name()='ResultSummary']/*[local-name()='Counters']");if($null-eq$counters){throw "$Context selected TRX counters are missing."};$derived=@{};foreach($counter in @('total','passed','failed','notExecuted','skipped')){$value=0;$text=$counters.GetAttribute($counter);if([string]::IsNullOrEmpty($text)){if($counter-in@('notExecuted','skipped')){$value=0}else{throw "$Context selected TRX counter $counter is missing."}}elseif(-not[int]::TryParse($text,[Globalization.NumberStyles]::None,[Globalization.CultureInfo]::InvariantCulture,[ref]$value)-or$value-lt0){throw "$Context selected TRX counter $counter is invalid."};$derived[$counter]=$value}
        if([int64]$entry.Total-ne$derived.total-or[int64]$entry.Passed-ne$derived.passed-or[int64]$entry.Failed-ne$derived.failed-or[int64]$entry.NotExecuted-ne$derived.notExecuted-or[int64]$entry.Skipped-ne$derived.skipped-or$derived.total-ne$derived.passed-or$derived.failed-ne0-or$derived.notExecuted-ne0-or$derived.skipped-ne0){throw "$Context selected TRX counters are not independently derived and all-passing."}
        $lastWrite=[DateTimeOffset]::MinValue;if(-not[DateTimeOffset]::TryParse([string]$entry.LastWriteUtc,[Globalization.CultureInfo]::InvariantCulture,[Globalization.DateTimeStyles]::RoundtripKind,[ref]$lastWrite)-or$lastWrite-lt$started-or$lastWrite-gt$upper){throw "$Context selected TRX file chronology is out of bounds."}
        $null=$seen.Add($name);$runIds[$runId.ToString('D')]=$true;$sum+=$derived.total
    }
    if($seen.Count-ne4-or$sum-ne913){throw "$Context selected TRX aggregate is not the exact four-file 913/913 set."}
}

function Assert-V02RuntimeReviewReports {
    param([Parameter(Mandatory)]$Gate, [Parameter(Mandatory)][string]$EvidenceDirectory, [Parameter(Mandatory)][ValidateSet('Thai', 'English')][string]$Language)
    $context = "$Language runtime evidence"
    $appPath = Resolve-V02RuntimeReviewPath $EvidenceDirectory (Join-Path $EvidenceDirectory 'app-runtime.json') "$context App report"
    $corePath = Resolve-V02RuntimeReviewPath $EvidenceDirectory (Join-Path $EvidenceDirectory 'core-runtime.json') "$context Core report"
    $appDoc = Read-V02RuntimeReviewStrictJsonFile $appPath "$context App report"
    $coreDoc = Read-V02RuntimeReviewStrictJsonFile $corePath "$context Core report"
    $app = $appDoc.Value; $core = $coreDoc.Value
    $appNames=@('EvidenceClassification','CoreStateObserved','SessionControlInvoked','StartedUtc','FinishedUtc','HostName','OperatingSystem','ProfileId','ProfileSha256','ObservedHost','RendererEvidence','AppProcessId','CoreProcessId','Language','LanguageCultureName','FinalLanguage','FinalLanguageCultureName','LanguageStableThroughFinish','LanguageChangeCount','TimeToInitialLiveState','InitialSequence','InitialStateSha256','PreCloseSequence','PreCloseStateSha256','PostCloseSequence','PostCloseStateSha256','UpdateObservedBeforeDashboardClose','DashboardClosed','UpdateObservedAfterDashboardClose','CoreConnectedAfterDashboardClose','DashboardClosedUtc','DisconnectObservedUtc','ReconnectObservedUtc','InitialEventCount','PreCloseEventCount','PostCloseEventCount','PreRestartConnectionEpoch','ReconnectedConnectionEpoch','PreRestartBootstrapCount','ReconnectedBootstrapCount','PreRestartDisconnectCount','ReconnectedDisconnectCount','DisconnectObservedAfterDashboardClose','ReconnectObservedAfterDashboardClose','EventBBaselineSequence','EventBBaselineEventCount','EventA','EventB','WidgetLatencyBaselineSequence','WidgetLatencyWarmupSamplesExcluded','WidgetLatencyWarmupExcludedSamples','WidgetLatencySamples','WidgetLatencyMinimumSamples','WidgetLatencyMeasurement','WidgetLatencyTargetMilliseconds','WidgetLatencyP95Milliseconds','WidgetLatencyTargetPassed','WidgetLatencyIncludedSamples','WidgetLatencyUnsupportedSamplesExcluded','WidgetLatencyUnsupportedExcludedSamples','IdleQuiescence','ResourceMeasurement','SemanticStateCaptures','Captures','FinalRuntimeHealth','FinalState','FailedCandidateChecks','CompositeCandidateChecksPassed','Message')
    $coreNames=@('EvidenceClassification','RuntimeObserved','SessionControlInvoked','SnapshotObserved','EventObserved','ReconnectObserved','StartedUtc','FinishedUtc','RequestedDurationSeconds','HostName','OperatingSystem','Admission','FinalMonitorState','FinalProjectedState','FinalProjectedStateSha256','Transitions','Message','CompletionSignalObserved','CompletionSignalSemantics')
    Assert-V02RuntimeReviewExactProperties $app $appNames "$context App report"
    Assert-V02RuntimeReviewExactProperties $core $coreNames "$context Core report"
    Assert-V02RuntimeReviewNoAuthorityProperties $app "$context App report";Assert-V02RuntimeReviewNoAuthorityProperties $core "$context Core report"
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
    Assert-V02RuntimeReviewExactProperties $admission @('ExecutablePath','ReleaseId','ExecutableSha256','ProtocolContractId','ProtocolContractRevision','BundledSchemaContractId','BundledSchemaContractRevision','BundledSchemaSha256','Protocol','Endpoint') "$context Core.Admission"
    Assert-V02RuntimeReviewExactProperties $admission.Endpoint @('SocketPath','PipeName') "$context Core.Admission.Endpoint"
    foreach ($name in @('ReleaseId','ExecutableSha256','BundledSchemaSha256','Protocol')) { $null = Get-V02RuntimeReviewProperty $admission $name "$context Core.Admission" }
    Assert-V02RuntimeReviewSha256 $admission.ExecutableSha256 "$context Herdr executable" | Out-Null
    Assert-V02RuntimeReviewSha256 $admission.BundledSchemaSha256 "$context bundled schema" | Out-Null
    Assert-V02RuntimeReviewInteger $admission.Protocol "$context protocol" | Out-Null
    foreach ($pair in @(@('HerdrReleaseId', [string]$admission.ReleaseId), @('HerdrExecutableSha256', [string]$admission.ExecutableSha256), @('BundledSchemaSha256', [string]$admission.BundledSchemaSha256), @('HerdrProtocol', [string]$admission.Protocol))) { if ((Get-V02RuntimeReviewGateValue $Gate $pair[0] $context) -cne $pair[1]) { throw "$context gate $($pair[0]) is not bound to Core admission." } }
    foreach($name in @('InitialStateSha256','PreCloseStateSha256','PostCloseStateSha256')){Assert-V02RuntimeReviewSha256 (Get-V02RuntimeReviewProperty $app $name $context) "$context App.$name"|Out-Null}
    $eventA=Assert-V02RuntimeReviewEvent $app.EventA "$context App.EventA";$eventB=Assert-V02RuntimeReviewEvent $app.EventB "$context App.EventB"
    $progress=Assert-V02RuntimeReviewProgress $EvidenceDirectory $Gate $app $context
    $transitions = @((Get-V02RuntimeReviewProperty $core 'Transitions' $context));if($transitions.Count-lt5){throw "$context Core transition trace is incomplete."}
    $previousUtc=[DateTimeOffset]::MinValue
    for($i=0;$i-lt$transitions.Count;$i++){$transition=$transitions[$i]
        Assert-V02RuntimeReviewExactProperties $transition @('ObservedUtc','Status','ConnectionEpoch','BootstrapCount','EventCount','DisconnectCount','ReconciliationCount','IngestSequence','WorkspaceCount','TabCount','PaneCount','AgentCount','StateFingerprintSha256','ContractStateSha256','AgentTopologySha256','AgentStatusStateSha256','ServerIdentity','AcceptedEventKind','Reason','AcceptedAgentStatusEvent','AllAgentsHaveLiveIdentity') "$context Core transition[$i]"
        Assert-V02RuntimeReviewSha256 $transition.ContractStateSha256 "$context Core transition[$i] hash"|Out-Null
        $utc=[DateTimeOffset]::MinValue;if(-not[DateTimeOffset]::TryParse([string]$transition.ObservedUtc,[Globalization.CultureInfo]::InvariantCulture,[Globalization.DateTimeStyles]::RoundtripKind,[ref]$utc)-or$utc.ToUniversalTime()-le$previousUtc){throw "$context Core transition timestamps must be unique and strictly increasing."};$previousUtc=$utc.ToUniversalTime()
        if($null-ne$transition.ServerIdentity){Assert-V02RuntimeReviewExactProperties $transition.ServerIdentity @('ProcessId','ProcessStartUtc','ExecutablePath','ExecutableSha256') "$context Core transition identity"}
        if($null-ne$transition.AcceptedAgentStatusEvent){Assert-V02RuntimeReviewExactProperties $transition.AcceptedAgentStatusEvent @('WorkspaceId','PaneId','AgentStatus','Agent','DisplayAgent','Title','TabId','AgentName') "$context Core accepted Agent event"}
    }
    function Find-ExactTransition([long]$Sequence,[string]$Hash,[string]$Name){$matches=@($transitions|Where-Object{[long]$_.IngestSequence-eq$Sequence-and[string]$_.ContractStateSha256-cne''-and[string]$_.ContractStateSha256-ceq$Hash});if($matches.Count-ne1){throw "$context $Name transition binding is not exact."};return $matches[0]}
    $initial=Find-ExactTransition ([long]$app.InitialSequence) ([string]$app.InitialStateSha256) 'initial';$eventATransition=Find-ExactTransition ([long]$app.PreCloseSequence) ([string]$app.PreCloseStateSha256) 'Event A';$eventBTransition=Find-ExactTransition ([long]$app.PostCloseSequence) ([string]$app.PostCloseStateSha256) 'Event B'
    $disconnectMatches=@($transitions|Where-Object{[long]$_.DisconnectCount-gt[long]$app.PreRestartDisconnectCount-and([DateTimeOffset]$_.ObservedUtc)-gt([DateTimeOffset]$app.DashboardClosedUtc)});if($disconnectMatches.Count-lt1){throw "$context disconnect transition is missing."};$disconnect=$disconnectMatches[0]
    $reconnectMatches=@($transitions|Where-Object{[string]$_.Status-ceq'Connected'-and[long]$_.ConnectionEpoch-eq[long]$app.ReconnectedConnectionEpoch-and[long]$_.BootstrapCount-eq[long]$app.ReconnectedBootstrapCount-and([DateTimeOffset]$_.ObservedUtc)-ge([DateTimeOffset]$app.ReconnectObservedUtc)});if($reconnectMatches.Count-lt1){throw "$context replacement reconnect transition is missing."};$reconnect=$reconnectMatches[0]
    $initialIndex=[Array]::IndexOf([object[]]$transitions,[object]$initial);$eventAIndex=[Array]::IndexOf([object[]]$transitions,[object]$eventATransition);$disconnectIndex=[Array]::IndexOf([object[]]$transitions,[object]$disconnect);$reconnectIndex=[Array]::IndexOf([object[]]$transitions,[object]$reconnect);$eventBIndex=[Array]::IndexOf([object[]]$transitions,[object]$eventBTransition)
    if($initialIndex-lt0-or$initialIndex-ge$eventAIndex-or$eventAIndex-ge$disconnectIndex-or$disconnectIndex-ge$reconnectIndex-or$reconnectIndex-ge$eventBIndex){throw "$context lifecycle transition order is not initial, Event A, disconnect, replacement reconnect, Event B."}
    if([long]$eventATransition.EventCount-le[long]$initial.EventCount-or[long]$eventATransition.ConnectionEpoch-ne[long]$app.PreRestartConnectionEpoch-or[long]$eventATransition.BootstrapCount-ne[long]$app.PreRestartBootstrapCount-or[long]$eventATransition.DisconnectCount-ne[long]$app.PreRestartDisconnectCount-or[long]$disconnect.DisconnectCount-le[long]$eventATransition.DisconnectCount-or[long]$reconnect.ConnectionEpoch-le[long]$app.PreRestartConnectionEpoch-or[long]$reconnect.BootstrapCount-le[long]$app.PreRestartBootstrapCount-or[long]$reconnect.DisconnectCount-le[long]$app.PreRestartDisconnectCount-or[long]$eventBTransition.EventCount-le[long]$app.EventBBaselineEventCount){throw "$context lifecycle counters do not prove Event A, disconnect, replacement reconnect, and Event B."}
    foreach($named in @(@($initial,'initial'),@($eventATransition,'Event A'),@($reconnect,'reconnect'),@($eventBTransition,'Event B'))){if($null-eq$named[0].ServerIdentity){throw "$context $($named[1]) has no target server identity."}}
    function Get-ServerKey($identity){@($identity.ProcessId,$identity.ProcessStartUtc,$identity.ExecutablePath,$identity.ExecutableSha256)-join'|'}
    $initialServerKey=Get-ServerKey $initial.ServerIdentity;$eventAServerKey=Get-ServerKey $eventATransition.ServerIdentity;$successorServerKey=Get-ServerKey $reconnect.ServerIdentity;$eventBServerKey=Get-ServerKey $eventBTransition.ServerIdentity
    if($initialServerKey-cne$eventAServerKey-or$successorServerKey-cne$eventBServerKey-or$initialServerKey-ceq$successorServerKey){throw "$context target server predecessor/successor identity is not exact."}
    $herdrPath=Get-V02RuntimeReviewFullPath ([string]$reconnect.ServerIdentity.ExecutablePath) "$context held Herdr executable";$herdrHeld=Read-V02RuntimeReviewHeldFile $herdrPath;if($herdrHeld.Sha256-cne[string]$reconnect.ServerIdentity.ExecutableSha256-or$herdrHeld.Sha256-cne[string]$admission.ExecutableSha256-or$herdrHeld.Sha256-cne(Get-V02RuntimeReviewGateValue $Gate 'HerdrExecutableSha256' $context)){throw "$context held Herdr executable bytes are not exact across Core admission/transitions/gate."}
    $controlIdentity=Get-V02RuntimeReviewGateValue $Gate 'AcceptanceControlServerIdentity' $context;if($controlIdentity-cnotmatch'^pid=([0-9]+) start=([^ ]+) path=(.+) sha256=([0-9A-F]{64})$'-or[IO.Path]::GetFullPath([string]$matches[3])-cne$herdrPath-or[string]$matches[4]-cne$herdrHeld.Sha256){throw "$context control-session server identity is not exactly bound to the held Herdr executable."};$controlServerKey=@($matches[1],$matches[2],[IO.Path]::GetFullPath([string]$matches[3]),$matches[4])-join'|';if($controlServerKey-ceq$initialServerKey-or$controlServerKey-ceq$successorServerKey){throw "$context control and target server process identities are not distinct."}
    $initialUtc=([DateTimeOffset]$initial.ObservedUtc).ToUniversalTime();$eventATransitionUtc=([DateTimeOffset]$eventATransition.ObservedUtc).ToUniversalTime();$disconnectUtc=([DateTimeOffset]$disconnect.ObservedUtc).ToUniversalTime();$reconnectUtc=([DateTimeOffset]$reconnect.ObservedUtc).ToUniversalTime()
    if($initialUtc-ge$eventA.PhaseEnteredUtc-or$eventA.PhaseEnteredUtc-gt$eventA.ObservedUtc-or$eventA.ObservedUtc-gt$eventATransitionUtc-or$disconnectUtc-ge$reconnectUtc-or$reconnectUtc-ge$eventB.PhaseEnteredUtc-or$eventB.PhaseEnteredUtc-gt$eventB.ObservedUtc){throw "$context lifecycle/event chronology is not strictly increasing: initial=$initialUtc eventAPhase=$($eventA.PhaseEnteredUtc) eventA=$($eventA.ObservedUtc) eventATransition=$eventATransitionUtc disconnect=$disconnectUtc reconnect=$reconnectUtc eventBPhase=$($eventB.PhaseEnteredUtc) eventB=$($eventB.ObservedUtc)."}
    $canonicalStates=@('Working','Idle','Blocked','Done','Unknown','Offline');foreach($change in @($eventA.Change,$eventB.Change)){if($canonicalStates-notcontains[string]$change.PreviousStatus-or$canonicalStates-notcontains[string]$change.CurrentStatus){throw "$context Event state mapping is not canonical."}}
    $agentKey=@($eventA.Change.TerminalId,$eventA.Change.WorkspaceId,$eventA.Change.TabId,$eventA.Change.PaneId)-join'|';if((@($eventB.Change.TerminalId,$eventB.Change.WorkspaceId,$eventB.Change.TabId,$eventB.Change.PaneId)-join'|')-cne$agentKey){throw "$context intended Agent identity changed across reconnect."}
    $captureDirectory = Resolve-V02RuntimeReviewPath $EvidenceDirectory (Get-V02RuntimeReviewGateValue $Gate 'CaptureDirectory' $context) "$context capture directory" 'Container'
    $captures = @((Get-V02RuntimeReviewProperty $app 'Captures' $context))
    if ($captures.Count -ne 8) { throw "$context must contain exactly eight runtime captures." }
    $captureHashes = @{}
    foreach ($capture in $captures) {
        Assert-V02RuntimeReviewExactProperties $capture @('Name','Path','Sha256','PixelWidth','PixelHeight','StateSequence','StateSha256','Language','LanguageCultureName','ObservedUtc') "$context capture"
        $name = Assert-V02RuntimeReviewString (Get-V02RuntimeReviewProperty $capture 'Name' $context) "$context capture name"
        if ($captureHashes.ContainsKey($name)) { throw "$context contains duplicate capture '$name'." }
        if ((Get-V02RuntimeReviewProperty $capture 'Language' $context) -cne $Language) { throw "$context capture language mismatch." }
        $capturePath = Resolve-V02RuntimeReviewPath $EvidenceDirectory (Get-V02RuntimeReviewProperty $capture 'Path' $context) "$context capture '$name'"
        if(-not([IO.Path]::GetDirectoryName($capturePath)).Equals($captureDirectory,[StringComparison]::OrdinalIgnoreCase)){throw "$context capture '$name' is outside the declared capture directory."}
        $declared = Assert-V02RuntimeReviewSha256 (Get-V02RuntimeReviewProperty $capture 'Sha256' $context) "$context capture '$name' hash"
        $actual = Read-V02RuntimeReviewHeldFile $capturePath
        if ($actual.Sha256 -cne $declared) { throw "$context capture '$name' bytes do not match its declared hash." }
        $captureHashes[$name] = [pscustomobject][ordered]@{ Name = $name; Path = $capturePath; Sha256 = $actual.Sha256; Bytes = $actual.Bytes }
    }
    $actualCaptureNames=@($captureHashes.Keys|Sort-Object);$expectedCaptureNames=@($script:V02RuntimeReviewRequiredCaptureNames|Sort-Object);if(($actualCaptureNames-join'|')-cne($expectedCaptureNames-join'|')){throw "$context capture catalog is not the exact required named catalog."}
    $declaredAppHash = Assert-V02RuntimeReviewSha256 (Get-V02RuntimeReviewGateValue $Gate 'AppRuntimeReportSha256' $context) "$context gate App hash"
    $declaredCoreHash = Assert-V02RuntimeReviewSha256 (Get-V02RuntimeReviewGateValue $Gate 'CoreRuntimeReportSha256' $context) "$context gate Core hash"
    if ($declaredAppHash -cne $appDoc.Sha256 -or $declaredCoreHash -cne $coreDoc.Sha256) { throw "$context gate report hashes do not match held App/Core reports." }
    Assert-V02RuntimeReviewSelectionReceipt $EvidenceDirectory $Gate $context
    if([string]$progress.Entries[1].StateSha256-cne[string]$initial.ContractStateSha256-or[string]$progress.Entries[3].StateSha256-cne[string]$eventATransition.ContractStateSha256-or[string]$progress.Entries[4].StateSha256-cne[string]$disconnect.ContractStateSha256-or[string]$progress.Entries[5].StateSha256-cne[string]$reconnect.ContractStateSha256-or[string]$progress.Entries[8].StateSha256-cne[string]$eventBTransition.ContractStateSha256){throw "$context progress lifecycle hashes are not transition-bound."}
    if([long]$progress.Entries[2].Sequence-ne[long]$eventA.Value.BaselineSequence-or[string]$progress.Entries[2].StateSha256-cne[string]$eventA.Value.BaselineStateSha256-or[long]$progress.Entries[3].Sequence-ne[long]$eventA.Value.CurrentSequence-or[long]$progress.Entries[5].Sequence-ne[long]$eventB.Value.BaselineSequence-or[string]$progress.Entries[5].StateSha256-cne[string]$eventB.Value.BaselineStateSha256-or[long]$progress.Entries[5].ConnectionEpoch-ne[long]$app.ReconnectedConnectionEpoch-or[long]$progress.Entries[5].BootstrapCount-ne[long]$app.ReconnectedBootstrapCount-or[long]$progress.Entries[5].DisconnectCount-ne[long]$app.ReconnectedDisconnectCount){throw "$context progress lifecycle counters/baselines are not App-bound."}
    $lastObserved=if($progress.LastUtc-gt$previousUtc){$progress.LastUtc}else{$previousUtc}
    return [pscustomobject][ordered]@{ Language=$Language;EvidenceDirectory=[IO.Path]::GetFullPath($EvidenceDirectory);CaptureRoot=$captureDirectory;Gate=$Gate;GateReportSha256=$Gate.Sha256;AppRuntimeReportSha256=$appDoc.Sha256;CoreRuntimeReportSha256=$coreDoc.Sha256;ProgressHistorySha256=$progress.HistorySha256;ProgressHistoryLastEntrySha256=$progress.LastEntrySha256;FirstObservedUtc=([DateTimeOffset]$initial.ObservedUtc).ToUniversalTime();LastObservedUtc=$lastObserved;InitialServerKey=$initialServerKey;SuccessorServerKey=$successorServerKey;AgentKey=$agentKey;AppRuntimeReportBytes=$appDoc.Bytes;CoreRuntimeReportBytes=$coreDoc.Bytes;App=$app;Core=$core;Captures=@($captureHashes.Values|Sort-Object Name) }
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
    Assert-V02RuntimeReviewExactProperties $payload @('GeneratedUnixTimeMilliseconds','RunNonce','IndependentHumanReview','ReleaseCredit','Binding','Runs') 'matrix payload'
    $generatedMilliseconds=Assert-V02RuntimeReviewInteger $payload.GeneratedUnixTimeMilliseconds 'matrix generated timestamp'
    try{$generatedUtc=[DateTimeOffset]::FromUnixTimeMilliseconds($generatedMilliseconds).ToUniversalTime()}catch{throw 'Matrix generated timestamp is outside the native UTC range.'}
    $validationUtc=[DateTimeOffset]::UtcNow;if($generatedUtc-gt$validationUtc-or$generatedUtc-lt$validationUtc.AddMinutes(-$script:V02RuntimeReviewMaximumAgeMinutes)){throw 'Matrix candidate is outside the bounded fresh review window.'}
    Assert-V02RuntimeReviewString $payload.IndependentHumanReview 'matrix payload human review' 'NOT_OBSERVED' | Out-Null; Assert-V02RuntimeReviewFalse $payload.ReleaseCredit 'matrix payload release credit'
    $producerRunNonce=Assert-V02RuntimeReviewRunNonce $payload.RunNonce 'matrix producer RunNonce'
    $binding = Get-V02RuntimeReviewProperty $payload 'Binding' 'matrix payload'
    Assert-V02RuntimeReviewExactProperties $binding @('SourceCommit','SourceTree','ProfileId','ProfileSha256','ReferenceHostSchemaSha256','PackageIdentityReceiptSha256','HerdrReleaseId','HerdrExecutableSha256','AppExecutableSha256','CoreExecutableSha256','BundledSchemaSha256','HerdrProtocol') 'matrix payload binding'
    if ([string]$binding.SourceCommit-cne$ExpectedSourceCommit-or[string]$binding.SourceTree-cne$ExpectedSourceTree-or[string]$binding.PackageIdentityReceiptSha256-cne$Package.ReceiptSha256-or[string]$binding.AppExecutableSha256-cne$Package.AppSha256-or[string]$binding.CoreExecutableSha256-cne$Package.CoreSha256) { throw 'Matrix payload binding is stale or does not match the package/source.' }
    foreach ($name in @('ProfileSha256','ReferenceHostSchemaSha256','HerdrExecutableSha256','AppExecutableSha256','CoreExecutableSha256','BundledSchemaSha256')) { Assert-V02RuntimeReviewSha256 (Get-V02RuntimeReviewProperty $binding $name 'matrix payload binding') "matrix binding $name" | Out-Null }
    $payloadCanonical = ConvertTo-V02Jcs $payload
    $payloadHash = Get-V02RuntimeReviewHash ([Text.UTF8Encoding]::new($false).GetBytes($payloadCanonical))
    if ($payloadHash -cne (Assert-V02RuntimeReviewSha256 $candidate.ManifestPayloadSha256 'matrix payload hash')) { throw 'Matrix payload hash is not bound to the held payload.' }
    $runs = @($payload.Runs); if ($runs.Count -ne 2) { throw 'Matrix candidate must contain exactly Thai and English runs.' }
    $byLanguage = @{}
    foreach ($run in $runs) { $language = Assert-V02RuntimeReviewString $run.Language 'matrix run language'; if ($byLanguage.ContainsKey($language)) { throw 'Matrix candidate contains duplicate language legs.' }; $byLanguage[$language] = $run }
    foreach ($expected in @(@('Thai', $Thai), @('English', $English))) {
        $language = [string]$expected[0]; if (-not $byLanguage.ContainsKey($language)) { throw "Matrix candidate is missing $language." }; $run = $byLanguage[$language]; $actual = $expected[1]
        $runNames=@('Language','EvidenceRunNonce','Culture','EvidenceDirectory','CaptureRoot','GateReportSha256','AppRuntimeReportSha256','CoreRuntimeReportSha256','ProgressHistorySha256','ProgressHistoryLastEntrySha256','PackageIdentityReceiptSha256','SourceCommit','SourceTree','ProfileId','ProfileSha256','ReferenceHostSchemaSha256','HerdrReleaseId','HerdrExecutableSha256','AppExecutableSha256','CoreExecutableSha256','BundledSchemaSha256','HerdrProtocol','RendererPolicyId','WpfProcessRenderMode','CaptureCount','Captures');Assert-V02RuntimeReviewExactProperties $run $runNames "matrix $language run"
        $gate=$actual.Gate
        $exact=@{
          EvidenceRunNonce=(Get-V02RuntimeReviewGateValue $gate 'RunNonce' "matrix $language");Culture=$(if($language-ceq'Thai'){'th-TH'}else{'en-US'});EvidenceDirectory=$actual.EvidenceDirectory;CaptureRoot=$actual.CaptureRoot;GateReportSha256=$actual.GateReportSha256;AppRuntimeReportSha256=$actual.AppRuntimeReportSha256;CoreRuntimeReportSha256=$actual.CoreRuntimeReportSha256;ProgressHistorySha256=$actual.ProgressHistorySha256;ProgressHistoryLastEntrySha256=$actual.ProgressHistoryLastEntrySha256;SourceCommit=$ExpectedSourceCommit;SourceTree=$ExpectedSourceTree;ProfileId=[string]$actual.App.ProfileId;ProfileSha256=[string]$actual.App.ProfileSha256;ReferenceHostSchemaSha256=(Get-V02RuntimeReviewGateValue $gate 'ReferenceHostSchemaSha256' "matrix $language");HerdrReleaseId=(Get-V02RuntimeReviewGateValue $gate 'HerdrReleaseId' "matrix $language");HerdrExecutableSha256=(Get-V02RuntimeReviewGateValue $gate 'HerdrExecutableSha256' "matrix $language");AppExecutableSha256=$Package.AppSha256;CoreExecutableSha256=$Package.CoreSha256;BundledSchemaSha256=(Get-V02RuntimeReviewGateValue $gate 'BundledSchemaSha256' "matrix $language");HerdrProtocol=(Get-V02RuntimeReviewGateValue $gate 'HerdrProtocol' "matrix $language");RendererPolicyId=(Get-V02RuntimeReviewGateValue $gate 'RendererPolicyId' "matrix $language");WpfProcessRenderMode=(Get-V02RuntimeReviewGateValue $gate 'WpfProcessRenderMode' "matrix $language")}
        foreach($name in $exact.Keys){if([string]$run.$name-cne[string]$exact[$name]){throw "Matrix $language $name is not exactly bound to held runtime evidence."}}
        if ([string]$run.PackageIdentityReceiptSha256 -cne $Package.ReceiptSha256) { throw "Matrix $language run is not bound to the package receipt." }
        if ([int64]$run.CaptureCount -ne 8) { throw "Matrix $language capture count is not eight." }
        $declared=@($run.Captures);if($declared.Count-ne$actual.Captures.Count){throw "Matrix $language capture inventory count differs from held evidence."};for($i=0;$i-lt$declared.Count;$i++){$candidate=$declared[$i];Assert-V02RuntimeReviewExactProperties $candidate @('Name','Path','Sha256') "matrix $language capture[$i]";$expectedCapture=$actual.Captures[$i];if([string]$candidate.Name-cne[string]$expectedCapture.Name-or[string]$candidate.Path-cne[string]$expectedCapture.Path-or[string]$candidate.Sha256-cne[string]$expectedCapture.Sha256){throw "Matrix $language capture inventory[$i] is not exactly ordered and held-byte bound: declared=$($candidate.Name)|$($candidate.Path)|$($candidate.Sha256) actual=$($expectedCapture.Name)|$($expectedCapture.Path)|$($expectedCapture.Sha256)."}}
        if($actual.LastObservedUtc-ge$generatedUtc){throw "Matrix $language chronology is stale or reversed."}
    }
    foreach($name in @('ProfileId','ProfileSha256','ReferenceHostSchemaSha256','HerdrReleaseId','HerdrExecutableSha256','AppExecutableSha256','CoreExecutableSha256','BundledSchemaSha256','HerdrProtocol')){if([string]$binding.$name-cne[string]$runs[0].$name-or[string]$binding.$name-cne[string]$runs[1].$name){throw "Matrix payload binding $name is not exact across both language legs."}}
    return [pscustomobject][ordered]@{ Path = $doc.Path; FileSha256 = $doc.Sha256; PayloadSha256 = $payloadHash; ProducerRunNonce=$producerRunNonce; Value = $candidate }
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
    $stream = $null; $parentHold=$null; $stagingHold=$null
    try {
        $parentHold=[HerdrOps.RuntimeReview.HeldPath]::OpenDirectory($parent)
        if(-not$parentHold.FinalPath.Equals($parent,[StringComparison]::OrdinalIgnoreCase)){throw 'Output parent final path differs from its requested path.'}
        if($script:V02RuntimeReviewFixtureModeActive-and$null-ne$script:V02RuntimeReviewFixturePublishHook){& $script:V02RuntimeReviewFixturePublishHook 'ParentHeld' $parent $temporary $full}
        $stream = [IO.File]::Open($temporary, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
        $stream.Write($bytes, 0, $bytes.Length); $stream.Flush($true); $stream.Dispose(); $stream = $null
        $stagingHold=[HerdrOps.RuntimeReview.HeldPath]::OpenStagingFile($temporary)
        if($script:V02RuntimeReviewFixtureModeActive-and$null-ne$script:V02RuntimeReviewFixturePublishHook){& $script:V02RuntimeReviewFixturePublishHook 'StagingHeld' $parent $temporary $full}
        if(-not$stagingHold.FinalPath.Equals($temporary,[StringComparison]::OrdinalIgnoreCase)-or$stagingHold.LinkCount-ne1){throw 'Staging identity is not the exact unique temporary file.'}
        Assert-V02RuntimeReviewNoReparseComponents $parent 'output parent before publish'
        $parentHold.AssertUnchanged();$stagingHold.AssertUnchanged()
        if (Test-Path -LiteralPath $full) { throw 'OutputPath appeared during atomic publication.' }
        [IO.File]::Move($temporary, $full)
        if($script:V02RuntimeReviewFixtureModeActive-and$null-ne$script:V02RuntimeReviewFixturePublishHook){& $script:V02RuntimeReviewFixturePublishHook 'Moved' $parent $temporary $full}
        $stagingHold.AssertMovedTo($full);$parentHold.AssertUnchanged()
    }
    catch { if ($null -ne $stream) { $stream.Dispose() };if($null-ne$stagingHold){$stagingHold.Dispose()};if($null-ne$parentHold){$parentHold.Dispose()}; if ([IO.File]::Exists($temporary)) { [IO.File]::Delete($temporary) }; throw }
    $published = Read-V02RuntimeReviewHeldFile $full
    $stagingHold.AssertMovedTo($full);$parentHold.AssertUnchanged();$stagingHold.Dispose();$parentHold.Dispose()
    return [pscustomobject][ordered]@{ Path = $full; Bytes = $published.Bytes; Sha256 = $published.Sha256 }
}

function Invoke-V02RuntimeReviewVerificationCore {
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
        [Parameter(Mandatory)][string]$ReviewRunNonce,
        [switch]$FixtureMode
    )
    Assert-V02RuntimeReviewGitSha $ExpectedSourceCommit 'ExpectedSourceCommit' | Out-Null; Assert-V02RuntimeReviewGitSha $ExpectedSourceTree 'ExpectedSourceTree' | Out-Null
    if (-not $FixtureMode) { Assert-V02RuntimeReviewSourceExact $RepositoryRoot $ExpectedSourceCommit $ExpectedSourceTree }
    $roles = Assert-V02RuntimeReviewRoleDistinct $BuilderIdentity $RuntimeOperatorIdentity $MatrixProducerIdentity $RuntimeReviewerIdentity
    $reviewRunNonce=Assert-V02RuntimeReviewRunNonce $ReviewRunNonce 'Independent reviewer RunNonce'
    $thaiRoot = Resolve-V02RuntimeReviewPath $ThaiEvidenceDirectory $ThaiEvidenceDirectory 'Thai evidence directory' 'Container'
    $englishRoot = Resolve-V02RuntimeReviewPath $EnglishEvidenceDirectory $EnglishEvidenceDirectory 'English evidence directory' 'Container'
    if ((Test-V02RuntimeReviewPathWithinOrEqual $thaiRoot $englishRoot) -or (Test-V02RuntimeReviewPathWithinOrEqual $englishRoot $thaiRoot)) { throw 'Thai and English evidence trees must be disjoint.' }
    $package = Assert-V02RuntimeReviewPackage $PackageIdentityPath $PackageArchivePath $ExtractedPackageRoot $ExpectedSourceCommit $ExpectedSourceTree $RepositoryRoot -FixtureMode:$FixtureMode
    $thaiGate = Get-V02RuntimeReviewGateMap (Join-Path $thaiRoot 'gate-report.txt'); $englishGate = Get-V02RuntimeReviewGateMap (Join-Path $englishRoot 'gate-report.txt')
    $thaiGateIdentity=Assert-V02RuntimeReviewGate $thaiGate 'Thai' $ExpectedSourceCommit $ExpectedSourceTree;$englishGateIdentity=Assert-V02RuntimeReviewGate $englishGate 'English' $ExpectedSourceCommit $ExpectedSourceTree
    if($thaiGateIdentity.RunNonce-ceq$englishGateIdentity.RunNonce){throw 'Thai and English runtime legs replay the same RunNonce.'}
    if($reviewRunNonce-ceq$thaiGateIdentity.RunNonce-or$reviewRunNonce-ceq$englishGateIdentity.RunNonce){throw 'Independent reviewer RunNonce must be distinct from both runtime-evidence RunNonce values.'}
    $thai = Assert-V02RuntimeReviewReports $thaiGate $thaiRoot 'Thai'; $english = Assert-V02RuntimeReviewReports $englishGate $englishRoot 'English'
    if([string]$thai.Core.Admission.ExecutablePath-cne[string]$english.Core.Admission.ExecutablePath){throw 'Thai and English held Herdr executable paths are not exact.'}
    if($thai.LastObservedUtc-ge$english.FirstObservedUtc){throw 'Thai and English runtime legs must have disjoint strictly ordered chronology.'}
    if($thai.AgentKey-cne$english.AgentKey){throw 'Thai and English runtime legs do not bind the same intended target Agent identity.'}
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
    if($reviewRunNonce-ceq$matrix.ProducerRunNonce){throw 'Independent reviewer RunNonce must be distinct from the matrix-producer RunNonce.'}
    if($matrix.ProducerRunNonce-ceq$thaiGateIdentity.RunNonce-or$matrix.ProducerRunNonce-ceq$englishGateIdentity.RunNonce){throw 'Matrix-producer RunNonce must be distinct from both runtime-evidence RunNonce values.'}
    $thaiInventory = Get-V02RuntimeReviewDirectoryInventory $thaiRoot; $englishInventory = Get-V02RuntimeReviewDirectoryInventory $englishRoot
    $binding = [pscustomobject][ordered]@{ SourceCommit = $ExpectedSourceCommit; SourceTree = $ExpectedSourceTree; PackageIdentityReceiptSha256 = $package.ReceiptSha256; PackageIdentityFileSha256 = $package.IdentityFileSha256; PackageArchiveSha256 = $package.ArchiveSha256; PackageManifestSha256 = $package.ManifestSha256; AppSha256 = $package.AppSha256; CoreSha256 = $package.CoreSha256 }
    $payload = [ordered]@{ SchemaVersion = 1; EvidenceClassification = 'IndependentReviewCandidate'; Result = 'PASS'; Issues = @($script:V02RuntimeReviewIssueSet); RunNonces=[ordered]@{MatrixProducer=$matrix.ProducerRunNonce;IndependentReviewer=$reviewRunNonce}; Source = [ordered]@{ CommitSha = $ExpectedSourceCommit; TreeSha = $ExpectedSourceTree; GitTreeClean = $true }; Package = [ordered]@{ IdentityPath = $package.IdentityPath; IdentityFileSha256 = $package.IdentityFileSha256; ReceiptSha256 = $package.ReceiptSha256; ArchivePath = $package.ArchivePath; ArchiveSha256 = $package.ArchiveSha256; ManifestPath = $package.ManifestPath; ManifestSha256 = $package.ManifestSha256; AppPath = $package.AppPath; AppSha256 = $package.AppSha256; CorePath = $package.CorePath; CoreSha256 = $package.CoreSha256 }; Roles = [ordered]@{ BuilderIdentity = $roles.Builder; RuntimeOperatorIdentity = $roles.RuntimeOperator; MatrixProducerIdentity = $roles.MatrixProducer; RuntimeReviewerIdentity = $roles.RuntimeReviewer; ReviewerDistinctCaseInsensitive = $true }; Herdr = [ordered]@{ ReleaseId = (Get-V02RuntimeReviewGateValue $thaiGate 'HerdrReleaseId' 'Thai gate'); ExecutablePath = [string]$thai.Core.Admission.ExecutablePath; ExecutableSha256 = (Get-V02RuntimeReviewGateValue $thaiGate 'HerdrExecutableSha256' 'Thai gate'); BundledSchemaSha256 = (Get-V02RuntimeReviewGateValue $thaiGate 'BundledSchemaSha256' 'Thai gate'); Protocol = (Get-V02RuntimeReviewGateValue $thaiGate 'HerdrProtocol' 'Thai gate') }; Sessions = [ordered]@{ Control = [ordered]@{ Name = (Get-V02RuntimeReviewGateValue $thaiGate 'AcceptanceControlSession' 'Thai gate'); SocketPath = (Get-V02RuntimeReviewGateValue $thaiGate 'AcceptanceControlSocketPath' 'Thai gate'); ServerIdentity = (Get-V02RuntimeReviewGateValue $thaiGate 'AcceptanceControlServerIdentity' 'Thai gate') }; Target = [ordered]@{ Name = (Get-V02RuntimeReviewGateValue $thaiGate 'TargetAgentLabSession' 'Thai gate'); SocketPath = (Get-V02RuntimeReviewGateValue $thaiGate 'TargetAgentLabSocketPath' 'Thai gate'); Reference = (Get-V02RuntimeReviewGateValue $thaiGate 'TargetAgentSessionReference' 'Thai gate') } }; MatrixCandidate = [ordered]@{ Path = $matrix.Path; FileSha256 = $matrix.FileSha256; PayloadSha256 = $matrix.PayloadSha256; ProducerRunNonce=$matrix.ProducerRunNonce; EvidenceClassification = 'RuntimeMatrixCandidate'; IndependentHumanReview = 'NOT_OBSERVED'; ReleaseCredit = $false }; Languages = @([ordered]@{ Language = 'Thai'; EvidenceRunNonce=$thaiGateIdentity.RunNonce; EvidenceDirectory = $thai.EvidenceDirectory; CaptureRoot = $thai.CaptureRoot; GateReportSha256 = $thai.GateReportSha256; AppRuntimeReportSha256 = $thai.AppRuntimeReportSha256; CoreRuntimeReportSha256 = $thai.CoreRuntimeReportSha256; Files = @($thaiInventory) }, [ordered]@{ Language = 'English'; EvidenceRunNonce=$englishGateIdentity.RunNonce; EvidenceDirectory = $english.EvidenceDirectory; CaptureRoot = $english.CaptureRoot; GateReportSha256 = $english.GateReportSha256; AppRuntimeReportSha256 = $english.AppRuntimeReportSha256; CoreRuntimeReportSha256 = $english.CoreRuntimeReportSha256; Files = @($englishInventory) }); EvidenceBoundary = [ordered]@{ IndependentReview = 'NOT_OBSERVED'; ExternalReviewerAttestation = 'NOT_PROVIDED'; HumanVisualGo = 'NOT_OBSERVED'; RuntimeCredit = $false; ReleaseCredit = $false; OutputAuthority = 'IndependentReviewCandidate'; NoCallerAuthoredAuthority = $true } }
    if (-not $FixtureMode) { Assert-V02RuntimeReviewSourceExact $RepositoryRoot $ExpectedSourceCommit $ExpectedSourceTree }
    $json = ConvertTo-V02Jcs ($payload | ConvertTo-Json -Depth 50 | ConvertFrom-Json)
    $rootForOutput = [IO.Path]::GetDirectoryName($thaiRoot)
    if ((Test-V02RuntimeReviewPathWithinOrEqual $OutputPath $thaiRoot) -or (Test-V02RuntimeReviewPathWithinOrEqual $OutputPath $englishRoot)) { throw 'OutputPath must not be inside a runtime evidence tree.' }
    $thaiInventoryFinal=Get-V02RuntimeReviewDirectoryInventory $thaiRoot;$englishInventoryFinal=Get-V02RuntimeReviewDirectoryInventory $englishRoot
    if(($thaiInventory|ConvertTo-Json -Depth 10 -Compress)-cne($thaiInventoryFinal|ConvertTo-Json -Depth 10 -Compress)-or($englishInventory|ConvertTo-Json -Depth 10 -Compress)-cne($englishInventoryFinal|ConvertTo-Json -Depth 10 -Compress)){throw 'Runtime evidence directory inventory changed before publication.'}
    Assert-V02RuntimeReviewHoldScope
    $published = Publish-V02RuntimeReviewNoClobber $rootForOutput $OutputPath $json
    Assert-V02RuntimeReviewHoldScope
    if (-not $FixtureMode) { Assert-V02RuntimeReviewSourceExact $RepositoryRoot $ExpectedSourceCommit $ExpectedSourceTree }
    return [pscustomobject][ordered]@{ Path = $published.Path; Sha256 = $published.Sha256; Bytes = $published.Bytes; EvidenceClassification = 'IndependentReviewCandidate'; Result = 'PASS' }
}

function Invoke-V02RuntimeReviewVerification {
    param([Parameter(Mandatory)][string]$ThaiEvidenceDirectory,[Parameter(Mandatory)][string]$EnglishEvidenceDirectory,[Parameter(Mandatory)][string]$MatrixCandidatePath,[Parameter(Mandatory)][string]$PackageIdentityPath,[Parameter(Mandatory)][string]$PackageArchivePath,[Parameter(Mandatory)][string]$ExtractedPackageRoot,[Parameter(Mandatory)][string]$RepositoryRoot,[Parameter(Mandatory)][string]$ExpectedSourceCommit,[Parameter(Mandatory)][string]$ExpectedSourceTree,[Parameter(Mandatory)][string]$OutputPath,[Parameter(Mandatory)][string]$BuilderIdentity,[Parameter(Mandatory)][string]$RuntimeOperatorIdentity,[Parameter(Mandatory)][string]$MatrixProducerIdentity,[Parameter(Mandatory)][string]$RuntimeReviewerIdentity,[Parameter(Mandatory)][string]$ReviewRunNonce,[switch]$FixtureMode)
    Start-V02RuntimeReviewHoldScope;$script:V02RuntimeReviewFixtureModeActive=[bool]$FixtureMode
    try{return Invoke-V02RuntimeReviewVerificationCore @PSBoundParameters}finally{$script:V02RuntimeReviewFixtureModeActive=$false;Stop-V02RuntimeReviewHoldScope}
}
