#requires -Version 5.1

Set-StrictMode -Version Latest

. (Join-Path $PSScriptRoot '..\human-design-review\HumanDesignReview.Common.ps1')
$rendererPackageCommonPath=Join-Path $PSScriptRoot '..\packaging\v0.2\V02PackageIdentity.Common.ps1'
$script:RendererPackageModule=New-Module -Name RendererPackageIdentity -ArgumentList $rendererPackageCommonPath -ScriptBlock { param($CommonPath);. $CommonPath }
Add-Type -AssemblyName PresentationCore

function Invoke-RendererPackageModule { param([scriptblock]$Action,[object[]]$Arguments=@());& $script:RendererPackageModule $Action @Arguments }
function Read-RendererPackageProfile { param([string]$Path);Invoke-RendererPackageModule {param($p)Read-V02PackageIdentityProfile $p} @($Path) }
function Get-RendererPackageProfileIdentity { param([string]$Path,$Profile,[string]$RepositoryRoot);Invoke-RendererPackageModule {param($p,$v,$r)Get-V02PreparationProfileIdentity $p $v $r} @($Path,$Profile,$RepositoryRoot) }
function Read-RendererCanonicalPackageReceipt { param([string]$Path,[string]$RepositoryRoot);Invoke-RendererPackageModule {param($p,$r)Read-V02CanonicalIdentityReceipt $p $r} @($Path,$RepositoryRoot) }
function Assert-RendererCommittedPackageIdentity { param($Identity,$Profile,[string]$RepositoryRoot,[string]$ArchivePath,[string]$PackageRoot,[string]$ProfilePath,[string]$ReceiptSha256,[string]$CanonicalReceiptJson);Invoke-RendererPackageModule {param($i,$p,$r,$a,$root,$pp,$sha,$json)Assert-V02PackageIdentity $i $p $r $a $root $pp $sha $json} @($Identity,$Profile,$RepositoryRoot,$ArchivePath,$PackageRoot,$ProfilePath,$ReceiptSha256,$CanonicalReceiptJson) }
function New-RendererPackageManifest { param($Profile,[string]$RepositoryRoot,[string]$PackageRoot);Invoke-RendererPackageModule {param($p,$r,$root)New-V02PackageManifestObject $p $r $root} @($Profile,$RepositoryRoot,$PackageRoot) }
function Write-RendererPackageCanonicalJson { param($Value,[string]$Path,[string]$RepositoryRoot);Invoke-RendererPackageModule {param($v,$p,$r)Write-V02CanonicalJsonFile $v $p $r} @($Value,$Path,$RepositoryRoot) }
function New-RendererDeterministicPackageArchive { param([string]$PackageRoot,[string]$ArchivePath);Invoke-RendererPackageModule {param($r,$a)New-DeterministicPackageArchive -PackageRoot $r -ArchivePath $a} @($PackageRoot,$ArchivePath) }
function Get-RendererPackageStableIdentity { param([string]$Path);Invoke-RendererPackageModule {param($p)Get-V02StableFileIdentity $p} @($Path) }
function ConvertTo-RendererCanonicalJson { param($Value,[string]$RepositoryRoot);Invoke-RendererPackageModule {param($v,$r)ConvertTo-V02CanonicalJson $v $r} @($Value,$RepositoryRoot) }

if ($null -eq ('RendererCompatibility.NativePath' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Collections.Generic;
using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Text;
using Microsoft.Win32.SafeHandles;
namespace RendererCompatibility {
    public sealed class NativeFileSnapshot {
        public string FileIdentity { get; internal set; }
        public uint LinkCount { get; internal set; }
        public long Length { get; internal set; }
        public long LastWriteTimeUtcFileTime { get; internal set; }
    }

    public static class NativePath {
        [StructLayout(LayoutKind.Sequential)]
        private struct ByHandleFileInformation {
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
        private static extern bool GetFileInformationByHandle(SafeFileHandle hFile, out ByHandleFileInformation lpFileInformation);

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool SetFileInformationByHandle(SafeFileHandle hFile, int FileInformationClass, IntPtr lpFileInformation, uint dwBufferSize);

        [StructLayout(LayoutKind.Sequential)]
        private struct IoStatusBlock { public IntPtr Status; public UIntPtr Information; }

        [DllImport("ntdll.dll")]
        private static extern int NtSetInformationFile(SafeFileHandle fileHandle, out IoStatusBlock ioStatusBlock, IntPtr fileInformation, uint length, int fileInformationClass);

        [DllImport("ntdll.dll")]
        private static extern uint RtlNtStatusToDosError(int status);

        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        private static extern SafeFileHandle CreateFile(
            string lpFileName,
            uint dwDesiredAccess,
            uint dwShareMode,
            IntPtr lpSecurityAttributes,
            uint dwCreationDisposition,
            uint dwFlagsAndAttributes,
            IntPtr hTemplateFile);

        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        private static extern uint GetFinalPathNameByHandle(SafeFileHandle handle, StringBuilder path, uint length, uint flags);
        public static string GetFinalPath(SafeFileHandle handle) {
            var buffer = new StringBuilder(32768);
            uint written = GetFinalPathNameByHandle(handle, buffer, (uint)buffer.Capacity, 0);
            if (written == 0 || written >= buffer.Capacity) throw new Win32Exception(Marshal.GetLastWin32Error(), "GetFinalPathNameByHandle failed");
            string value = buffer.ToString();
            if (value.StartsWith(@"\\?\UNC\", StringComparison.OrdinalIgnoreCase)) return @"\\" + value.Substring(8);
            if (value.StartsWith(@"\\?\", StringComparison.OrdinalIgnoreCase)) return value.Substring(4);
            return value;
        }

        public static string GetIdentity(SafeFileHandle handle) {
            ByHandleFileInformation value;
            if (!GetFileInformationByHandle(handle, out value)) throw new Win32Exception(Marshal.GetLastWin32Error(), "GetFileInformationByHandle failed");
            return value.VolumeSerialNumber.ToString("X8") + ":" + value.FileIndexHigh.ToString("X8") + value.FileIndexLow.ToString("X8");
        }

        public static uint GetLinkCount(SafeFileHandle handle) {
            ByHandleFileInformation value;
            if (!GetFileInformationByHandle(handle, out value)) throw new Win32Exception(Marshal.GetLastWin32Error(), "GetFileInformationByHandle failed");
            return value.NumberOfLinks;
        }

        public static NativeFileSnapshot GetSnapshot(SafeFileHandle handle) {
            ByHandleFileInformation value;
            if (!GetFileInformationByHandle(handle, out value)) throw new Win32Exception(Marshal.GetLastWin32Error(), "GetFileInformationByHandle failed");
            return new NativeFileSnapshot {
                FileIdentity = value.VolumeSerialNumber.ToString("X8") + ":" + value.FileIndexHigh.ToString("X8") + value.FileIndexLow.ToString("X8"),
                LinkCount = value.NumberOfLinks,
                Length = ((long)value.FileSizeHigh << 32) | value.FileSizeLow,
                LastWriteTimeUtcFileTime = ((long)value.LastWriteTime.dwHighDateTime << 32) | (uint)value.LastWriteTime.dwLowDateTime
            };
        }

        public static SafeFileHandle OpenDirectory(string path, bool allowDelete) {
            const uint DeleteAccess = 0x00010000, ShareRead = 1, ShareWrite = 2, OpenExisting = 3;
            const uint BackupSemantics = 0x02000000, OpenReparsePoint = 0x00200000;
            SafeFileHandle result = CreateFile(path, allowDelete ? DeleteAccess : 0, ShareRead | ShareWrite, IntPtr.Zero, OpenExisting, BackupSemantics | OpenReparsePoint, IntPtr.Zero);
            if (result.IsInvalid) { int error = Marshal.GetLastWin32Error(); result.Dispose(); throw new Win32Exception(error, "CreateFile directory lease failed for " + path); }
            return result;
        }

        public static void RenameDirectory(SafeFileHandle handle, SafeFileHandle destinationParentHandle, string destinationLeafName) {
            if (destinationLeafName.IndexOfAny(new[] { '\\', '/' }) >= 0 || destinationLeafName == "." || destinationLeafName == "..")
                throw new ArgumentException("Held-handle directory rename requires one destination leaf name.", "destinationLeafName");
            byte[] name = Encoding.Unicode.GetBytes(destinationLeafName);
            int rootOffset = IntPtr.Size == 8 ? 8 : 4;
            int lengthOffset = IntPtr.Size == 8 ? 16 : 8;
            int nameOffset = IntPtr.Size == 8 ? 20 : 12;
            int size = nameOffset + name.Length + 2;
            IntPtr buffer = Marshal.AllocHGlobal(size);
            try {
                for (int i = 0; i < size; i++) Marshal.WriteByte(buffer, i, 0);
                Marshal.WriteIntPtr(buffer, rootOffset, destinationParentHandle.DangerousGetHandle());
                Marshal.WriteInt32(buffer, lengthOffset, name.Length);
                Marshal.Copy(name, 0, IntPtr.Add(buffer, nameOffset), name.Length);
                IoStatusBlock statusBlock;
                int status = NtSetInformationFile(handle, out statusBlock, buffer, (uint)size, 10);
                if (status != 0) throw new Win32Exception((int)RtlNtStatusToDosError(status), "Held-handle root-relative directory rename failed");
            } finally { Marshal.FreeHGlobal(buffer); }
        }

        public static void DeleteDirectory(SafeFileHandle handle) {
            IntPtr buffer = Marshal.AllocHGlobal(4);
            try {
                Marshal.WriteInt32(buffer, 1);
                if (!SetFileInformationByHandle(handle, 4, buffer, 4)) throw new Win32Exception(Marshal.GetLastWin32Error(), "Held-handle directory deletion failed");
            } finally { Marshal.FreeHGlobal(buffer); }
        }

        [DllImport("user32.dll", SetLastError = true)]
        private static extern bool IsWindow(IntPtr hWnd);

        [DllImport("user32.dll", SetLastError = true)]
        private static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint processId);

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool GetNamedPipeClientProcessId(IntPtr pipe, out uint processId);

        private delegate bool EnumWindowsProc(IntPtr hWnd, IntPtr lParam);

        [DllImport("user32.dll")]
        private static extern bool EnumWindows(EnumWindowsProc lpEnumFunc, IntPtr lParam);

        [DllImport("user32.dll")]
        private static extern bool EnumThreadWindows(uint threadId, EnumWindowsProc lpEnumFunc, IntPtr lParam);

        public static long[] GetProcessWindowHandles(int processId) {
            var handles = new HashSet<long>();
            EnumWindowsProc collect = delegate(IntPtr hwnd, IntPtr ignored) {
                uint owner;
                GetWindowThreadProcessId(hwnd, out owner);
                if (owner == (uint)processId) handles.Add(hwnd.ToInt64());
                return true;
            };
            EnumWindows(collect, IntPtr.Zero);
            using (Process process = Process.GetProcessById(processId)) {
                foreach (ProcessThread thread in process.Threads) EnumThreadWindows((uint)thread.Id, collect, IntPtr.Zero);
            }
            var result = new long[handles.Count];
            handles.CopyTo(result);
            return result;
        }

        [DllImport("user32.dll")]
        private static extern bool IsWindowVisible(IntPtr hWnd);

        [DllImport("user32.dll")]
        private static extern IntPtr GetWindow(IntPtr hWnd, uint uCmd);

        [DllImport("user32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
        private static extern int GetClassName(IntPtr hWnd, StringBuilder lpClassName, int nMaxCount);

        [DllImport("user32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
        private static extern int GetWindowText(IntPtr hWnd, StringBuilder lpString, int nMaxCount);

        [DllImport("user32.dll")]
        private static extern int GetWindowLong(IntPtr hWnd, int nIndex);

        [StructLayout(LayoutKind.Sequential)]
        private struct RECT {
            public int Left;
            public int Top;
            public int Right;
            public int Bottom;
        }

        [DllImport("user32.dll", SetLastError = true)]
        private static extern bool GetWindowRect(IntPtr hWnd, out RECT lpRect);

        [DllImport("user32.dll", SetLastError = true)]
        private static extern IntPtr SendMessageTimeout(
            IntPtr hWnd,
            uint Msg,
            IntPtr wParam,
            IntPtr lParam,
            uint fuFlags,
            uint uTimeout,
            out IntPtr lpdwResult);

        private const uint GW_OWNER = 4;
        private const int GWL_STYLE = -16;
        private const int GWL_EXSTYLE = -20;
        private const int WS_VISIBLE = 0x10000000;
        private const int WS_CHILD = 0x40000000;
        private const int WS_CAPTION = 0x00C00000;
        private const int WS_EX_TOOLWINDOW = 0x00000080;
        private const uint WM_NULL = 0x0000;
        private const uint SMTO_ABORTIFHUNG = 0x0002;
        private const uint SMTO_BLOCK = 0x0001;

        public static bool IsLiveWindow(IntPtr hWnd) {
            return hWnd != IntPtr.Zero && IsWindow(hWnd);
        }

        public static bool IsWindowResponsive(IntPtr hWnd, uint timeoutMs = 2000) {
            if (!IsLiveWindow(hWnd)) return false;
            IntPtr result;
            IntPtr res = SendMessageTimeout(hWnd, WM_NULL, IntPtr.Zero, IntPtr.Zero, SMTO_ABORTIFHUNG | SMTO_BLOCK, timeoutMs, out result);
            return res != IntPtr.Zero;
        }

        public static int GetWindowOwnerProcessId(IntPtr hWnd) {
            uint processId;
            if (!IsLiveWindow(hWnd) || GetWindowThreadProcessId(hWnd, out processId) == 0 || processId == 0) {
                throw new InvalidOperationException("The HWND is not live or has no owning process.");
            }
            return checked((int)processId);
        }

        public static int GetPipeClientProcessId(IntPtr pipeHandle) {
            uint processId;
            if (pipeHandle == IntPtr.Zero || !GetNamedPipeClientProcessId(pipeHandle, out processId) || processId == 0) {
                throw new InvalidOperationException("The target observation pipe has no identifiable client process.");
            }
            return checked((int)processId);
        }

        public static IntPtr GetProcessMainWindow(int processId) {
            if (processId <= 0) return IntPtr.Zero;
            IntPtr candidate = IntPtr.Zero;
            EnumWindows((hWnd, lParam) => {
                uint pid;
                if (GetWindowThreadProcessId(hWnd, out pid) != 0 && pid == (uint)processId) {
                    if (IsWindowVisible(hWnd) && GetWindow(hWnd, GW_OWNER) == IntPtr.Zero) {
                        int style = GetWindowLong(hWnd, GWL_STYLE);
                        int exStyle = GetWindowLong(hWnd, GWL_EXSTYLE);
                        if ((style & WS_CHILD) == 0 && (exStyle & WS_EX_TOOLWINDOW) == 0) {
                            RECT rect;
                            if (GetWindowRect(hWnd, out rect)) {
                                int width = rect.Right - rect.Left;
                                int height = rect.Bottom - rect.Top;
                                if (width > 0 && height > 0) {
                                    var sbText = new StringBuilder(256);
                                    GetWindowText(hWnd, sbText, 256);
                                    bool hasCaption = (style & WS_CAPTION) == WS_CAPTION;
                                    bool hasTitle = sbText.Length > 0;
                                    if (hasCaption || hasTitle) {
                                        candidate = hWnd;
                                        return false;
                                    }
                                }
                            }
                        }
                    }
                }
                return true;
            }, IntPtr.Zero);
            return candidate;
        }
    }
}
'@
}

$script:RendererSchemaId = 'https://herdrops.local/schema/v0.2/renderer-compatibility-manifest.schema.json'
$script:RendererProfileId = 'herdrops-v0.2-submark-nb-software-only-20260822'
$script:RendererProfileSha256 = '96D01ED15A536F2DF50B59B43CFDEB3683DCE8667AE2E7BF6A96124182FE13A3'
$script:RendererPackageProfileId = 'herdrops-v0.2-package-software-only-issue-149'
$script:RendererPolicySha256 = '1D37C9C39449556EB30F9AB5B734F0C5411CF4203321AF0B238993D017229E92'
$script:RendererCaptureNames = @(
    'dashboard-overview', 'dashboard-live-organization', 'dashboard-agent-detail',
    'widget-compact', 'widget-normal', 'widget-floating-vertical',
    'dashboard-overview-after-event', 'widget-floating-vertical-after-dashboard-close',
    'widget-floating-vertical-offline', 'widget-floating-vertical-reconnected')
$script:RendererObservationStages = @(
    'Startup', 'PreFirstWindow', 'PostFirstWindowShown', 'BeforeThaiCaptures',
    'AfterThaiCaptures', 'BeforeEnglishCaptures', 'AfterEnglishCaptures', 'Final')
$script:RendererCaptureModes = @('AutomatedInstalledRuntime', 'DeterministicPackaged')
$script:RendererDisplayCases = @(
    '1920x1080-100', '1920x1080-125', '1920x1080-150',
    '1366x768-100', '1366x768-125', '1366x768-150')
$script:RendererAccessibilityCases = @(
    'keyboard-uia', 'high-contrast', 'text-scale-100',
    'text-scale-150', 'text-scale-200', 'reduced-motion-on', 'reduced-motion-off')
$script:RendererMixedDpiCases = @()
$script:RendererEnvironmentCases = @(
    'windows11-x64-build26220-packaged-non-elevated-single-user')
$script:RendererMaximumManifestBytes = 2MB
$script:RendererAuthorizedApprovalReference = 'https://github.com/OSHEThai/HerdrOps/issues/149#issuecomment-5380637664'
$script:RendererV3ScopeApprovalReference = 'https://github.com/OSHEThai/HerdrOps/issues/149#issuecomment-5395776783'
$script:RendererV4ApprovalReference = 'https://github.com/OSHEThai/HerdrOps/issues/149#issuecomment-5396694185'
$script:RendererDecisionId = 'herdrops-v0.2-release-first-v4'
$script:RendererDecisionApprovedUtc = '2026-08-24T14:31:14Z'
$script:RendererDecisionCorrectedUtc = '2026-08-24T14:31:14Z'
$script:RendererDecisionPayloadSha256 = '4958E318AF4960C5BEC8B12BA69AED384236C91570BB86F872057066939ED904'
$script:RendererSupersedesDecisionId = 'herdrops-v0.2-compat-v3'
$script:RendererSupersedesPayloadSha256 = 'DF5717849F206D817DB6BEF324CF74CEA1C5BFC1E91956EC5436A60727DFFB98'
$script:RendererPackageDecisionId = 'herdrops-rec-all-v2'
$script:RendererPackageApprovalReference = 'https://github.com/OSHEThai/HerdrOps/issues/149#issuecomment-5380637664'
$script:RendererPackageDecisionApprovedUtc = '2026-08-22T13:18:21.2468994Z'
$script:RendererPackageDecisionPayloadSha256 = '48474610D2A20EE2F7CA2DAC0A3CCF45F919440C9C5D81EF5BA93AD7E524F62D'
$script:RendererRecAllReferenceHostSha256 = '96D01ED15A536F2DF50B59B43CFDEB3683DCE8667AE2E7BF6A96124182FE13A3'

function Assert-RendererExactProperties {
    param([Parameter(Mandatory=$true)]$Value,[Parameter(Mandatory=$true)][string[]]$Names,[Parameter(Mandatory=$true)][string]$Context)
    if ($null -eq $Value) { throw "$Context is missing." }
    $actual = @($Value.PSObject.Properties.Name)
    if ($actual.Count -ne $Names.Count) { throw "$Context must contain exactly: $($Names -join ', ')." }
    foreach ($name in $Names) { if (-not ($actual -ccontains $name)) { throw "$Context omitted '$name'." } }
}

function Assert-RendererString { param($Value,[string]$Context)
    if ($Value -isnot [string] -or [string]::IsNullOrWhiteSpace([string]$Value)) { throw "$Context must be a nonempty string." }
}
function Assert-RendererSha { param($Value,[string]$Context)
    if ($Value -isnot [string] -or [string]$Value -cnotmatch '^[0-9A-F]{64}$' -or [string]$Value -ceq ('0'*64)) { throw "$Context must be a nonzero uppercase SHA-256." }
}
function Assert-RendererUtc { param($Value,[string]$Context)
    Assert-RendererString $Value $Context
    $parsed=[DateTimeOffset]::MinValue
    if (-not [DateTimeOffset]::TryParseExact([string]$Value,'O',[Globalization.CultureInfo]::InvariantCulture,[Globalization.DateTimeStyles]::RoundtripKind,[ref]$parsed) -or $parsed.Offset -ne [TimeSpan]::Zero) { throw "$Context must be canonical round-trip UTC with zero offset." }
}
function Assert-RendererNullableUtc { param($Value,[string]$Context)
    if ($null -ne $Value) { Assert-RendererUtc $Value $Context }
}
function Assert-RendererBoolean { param($Value,[string]$Context)
    if ($Value -isnot [bool]) { throw "$Context must be a native boolean." }
}
function Assert-RendererPositiveInteger { param($Value,[string]$Context)
    if ($Value -isnot [int] -and $Value -isnot [long]) { throw "$Context must be a native integer." }
    if ([long]$Value -le 0) { throw "$Context must be positive." }
}
function Assert-RendererNonnegativeInteger { param($Value,[string]$Context)
    if ($Value -isnot [int] -and $Value -isnot [long]) { throw "$Context must be a native integer." }
    if ([long]$Value -lt 0) { throw "$Context must be nonnegative." }
}
function Assert-RendererFiniteNumber { param($Value,[string]$Context,[double]$Minimum,[double]$Maximum,[switch]$ExclusiveMinimum)
    if ($Value -isnot [byte] -and $Value -isnot [sbyte] -and $Value -isnot [int16] -and
        $Value -isnot [uint16] -and $Value -isnot [int] -and $Value -isnot [uint32] -and
        $Value -isnot [long] -and $Value -isnot [uint64] -and $Value -isnot [single] -and
        $Value -isnot [double] -and $Value -isnot [decimal]) {
        throw "$Context must be a native JSON number."
    }
    $number = [double]$Value
    if ([double]::IsNaN($number) -or [double]::IsInfinity($number)) { throw "$Context must be finite." }
    if (($ExclusiveMinimum -and $number -le $Minimum) -or (-not $ExclusiveMinimum -and $number -lt $Minimum) -or $number -gt $Maximum) {
        throw "$Context is outside its approved bounds."
    }
}
function Assert-RendererRelativePath { param($Value,[string]$Context)
    Assert-RendererString $Value $Context
    $path=[string]$Value
    if ([IO.Path]::IsPathRooted($path) -or $path -match '(^|[\\/])\.\.([\\/]|$)') { throw "$Context must be a contained relative path." }
}
function Assert-RendererSet { param([object[]]$Items,[string[]]$Expected,[string]$Context)
    $values=@($Items|ForEach-Object{[string]$_})
    if ($values.Count -ne $Expected.Count -or (@($values|Select-Object -Unique)).Count -ne $values.Count) { throw "$Context count or uniqueness is invalid." }
    foreach($name in $Expected){if(-not($values -ccontains $name)){throw "$Context omitted '$name'."}}
}
function Get-RendererSemanticPhase { param([string]$Name)
    switch($Name){
        'dashboard-overview-after-event' {'EventA'}
        'widget-floating-vertical-after-dashboard-close' {'DashboardClosedPostEventB'}
        'widget-floating-vertical-offline' {'Offline'}
        'widget-floating-vertical-reconnected' {'Reconnected'}
        default {'InitialLive'}
    }
}
function Get-RendererCategory { param([string]$Name)
    if($Name -in @('widget-floating-vertical-offline','widget-floating-vertical-reconnected')){'RendererCompatibility'}else{'BudgetProvenance'}
}
function Get-RendererReferencePath { param([string]$Name)
    switch ($Name) {
        'dashboard-overview' { 'docs/design/reference/01-overview.png' }
        'dashboard-overview-after-event' { 'docs/design/reference/01-overview.png' }
        'dashboard-live-organization' { 'docs/design/reference/02-live-organization.png' }
        'dashboard-agent-detail' { 'docs/design/reference/05-agent-detail.png' }
        default { 'docs/design/reference/11-widget-concepts.png' }
    }
}
function Resolve-RendererBoundPath { param([string]$Root,[string]$Relative,[string]$Context)
    Assert-RendererRelativePath $Relative $Context
    $rootFull=[IO.Path]::GetFullPath($Root).TrimEnd('\','/')
    $full=[IO.Path]::GetFullPath((Join-Path $rootFull $Relative))
    if(-not $full.StartsWith($rootFull+[IO.Path]::DirectorySeparatorChar,[StringComparison]::OrdinalIgnoreCase)){throw "$Context escaped the evidence root."}
    Assert-RendererNonReparsePath -Root $rootFull -Path $full -Context $Context
    return $full
}
function Assert-RendererNonReparsePath { param([string]$Root,[string]$Path,[string]$Context)
    $rootFull=[IO.Path]::GetFullPath($Root).TrimEnd('\','/');$pathFull=[IO.Path]::GetFullPath($Path)
    if($pathFull-cne$rootFull-and-not$pathFull.StartsWith($rootFull+[IO.Path]::DirectorySeparatorChar,[StringComparison]::OrdinalIgnoreCase)){throw "$Context escaped the evidence root."}
    $volume=[IO.Path]::GetPathRoot($pathFull);$probe=$volume
    foreach($part in @($pathFull.Substring($volume.Length)-split'[\\/]'|Where-Object{$_-ne''})){$probe=Join-Path $probe $part;if(Test-Path -LiteralPath $probe){$item=Get-Item -LiteralPath $probe -Force -ErrorAction Stop;if(($item.Attributes-band[IO.FileAttributes]::ReparsePoint)-ne0){throw "$Context contains a reparse point: $probe"}}}
}
function Open-RendererDirectoryLease {
    param([string]$Root,[string]$Path,[string]$Context,[switch]$AllowDelete)
    $rootFull=[IO.Path]::GetFullPath($Root).TrimEnd('\','/')
    $pathFull=[IO.Path]::GetFullPath($Path).TrimEnd('\','/')
    Assert-RendererNonReparsePath $rootFull $pathFull $Context
    $handle=[RendererCompatibility.NativePath]::OpenDirectory($pathFull,[bool]$AllowDelete)
    try {
        $final=[IO.Path]::GetFullPath([RendererCompatibility.NativePath]::GetFinalPath($handle)).TrimEnd('\','/')
        if($final-cne$pathFull){throw "$Context final opened path '$final' does not equal '$pathFull'."}
        if($final-cne$rootFull-and-not$final.StartsWith($rootFull+[IO.Path]::DirectorySeparatorChar,[StringComparison]::OrdinalIgnoreCase)){throw "$Context final opened path escaped the evidence root."}
        return [pscustomobject]@{Handle=$handle;Path=$pathFull;FinalPath=$final;Identity=[RendererCompatibility.NativePath]::GetIdentity($handle);DeleteAccess=[bool]$AllowDelete;DeletePending=$false}
    } catch {
        $handle.Dispose()
        throw
    }
}
function Assert-RendererDirectoryLease {
    param($Lease,[string]$Root,[string]$Path,[string]$Context)
    if($null-eq$Lease-or$null-eq$Lease.Handle-or$Lease.Handle.IsClosed-or$Lease.Handle.IsInvalid){throw "$Context directory lease is not held."}
    $expected=[IO.Path]::GetFullPath($Path).TrimEnd('\','/')
    $heldFinal=[IO.Path]::GetFullPath([RendererCompatibility.NativePath]::GetFinalPath($Lease.Handle)).TrimEnd('\','/')
    $heldIdentity=[RendererCompatibility.NativePath]::GetIdentity($Lease.Handle)
    if($heldFinal-cne$Lease.FinalPath-or$heldIdentity-cne$Lease.Identity){throw "$Context held directory identity changed."}
    if($Lease.DeleteAccess){
        if($heldFinal-cne$expected){throw "$Context held delete-protected directory no longer has the expected path."}
        return
    }
    $probe=Open-RendererDirectoryLease $Root $expected "$Context current path"
    try {
        if($probe.Identity-cne$Lease.Identity-or$probe.FinalPath-cne$Lease.FinalPath){throw "$Context path no longer resolves to the held directory identity."}
    } finally {$probe.Handle.Dispose()}
}
function Move-RendererLeasedDirectory {
    param($Lease,[string]$Root,[string]$Path,[string]$Destination,[string]$Context)
    if(-not$Lease.DeleteAccess){throw "$Context directory lease lacks held-handle rename access."}
    Assert-RendererDirectoryLease $Lease $Root $Path "$Context before held-handle rename"
    $destinationFull=[IO.Path]::GetFullPath($Destination).TrimEnd('\','/')
    $destinationParent=[IO.Path]::GetDirectoryName($destinationFull)
    $destinationLeaf=[IO.Path]::GetFileName($destinationFull)
    if([string]::IsNullOrWhiteSpace($destinationLeaf)){throw "$Context destination leaf is invalid."}
    $parentLease=Open-RendererDirectoryLease $Root $destinationParent "$Context destination parent"
    try{[RendererCompatibility.NativePath]::RenameDirectory($Lease.Handle,$parentLease.Handle,$destinationLeaf)}finally{$parentLease.Handle.Dispose()}
    $movedFinal=[IO.Path]::GetFullPath([RendererCompatibility.NativePath]::GetFinalPath($Lease.Handle)).TrimEnd('\','/')
    $movedIdentity=[RendererCompatibility.NativePath]::GetIdentity($Lease.Handle)
    if($movedFinal-cne$destinationFull-or$movedIdentity-cne$Lease.Identity){throw "$Context held-handle rename did not retain the exact destination/FileId identity. Expected path '$destinationFull' identity '$($Lease.Identity)'; observed path '$movedFinal' identity '$movedIdentity'."}
    $Lease.FinalPath=$movedFinal
    $Lease.Path=$movedFinal
}
function Remove-RendererLeasedDirectory {
    param($Lease,[string]$Root,[string]$Path,[string]$Context)
    if(-not$Lease.DeleteAccess){throw "$Context directory lease lacks held-handle deletion access."}
    Assert-RendererDirectoryLease $Lease $Root $Path "$Context before content deletion"
    foreach($child in @(Get-ChildItem -LiteralPath $Lease.FinalPath -Force -ErrorAction Stop)){
        if($child.PSIsContainer-and($child.Attributes-band[IO.FileAttributes]::ReparsePoint)-eq0){throw "$Context contains an unexpected child directory; refusing recursive traversal."}
        if($child.PSIsContainer){[IO.Directory]::Delete($child.FullName,$false)}else{[IO.File]::Delete($child.FullName)}
    }
    if(@(Get-ChildItem -LiteralPath $Lease.FinalPath -Force -ErrorAction Stop).Count-ne0){throw "$Context acquired new children during deletion; refusing to delete the directory."}
    Assert-RendererDirectoryLease $Lease $Root $Path "$Context before held-handle delete"
    [RendererCompatibility.NativePath]::DeleteDirectory($Lease.Handle)
    $Lease.DeletePending=$true
    $Lease.Handle.Dispose()
}
function Remove-RendererOwnedStagingTree {
    param($Lease,[string]$Root,[string]$Path,[string]$Context)
    if(-not$Lease.DeleteAccess){throw "$Context directory lease lacks held-handle deletion access."}
    Assert-RendererDirectoryLease $Lease $Root $Path "$Context before staging tree deletion"
    $targetDir = $Lease.FinalPath
    # Non-recursive owned cleanup: collect subdirectories depth-first and delete leaf files
    $allDirs = @(Get-ChildItem -LiteralPath $targetDir -Directory -Recurse -Force -ErrorAction Stop | Sort-Object { $_.FullName.Length } -Descending)
    foreach ($sub in $allDirs) {
        Assert-RendererNonReparsePath $targetDir $sub.FullName "$Context child directory"
        foreach ($file in @(Get-ChildItem -LiteralPath $sub.FullName -File -Force -ErrorAction Stop)) {
            Assert-RendererNonReparsePath $targetDir $file.FullName "$Context child file"
            [IO.File]::Delete($file.FullName)
        }
        [IO.Directory]::Delete($sub.FullName, $false)
    }
    foreach ($file in @(Get-ChildItem -LiteralPath $targetDir -File -Force -ErrorAction Stop)) {
        Assert-RendererNonReparsePath $targetDir $file.FullName "$Context root child file"
        [IO.File]::Delete($file.FullName)
    }
    if(@(Get-ChildItem -LiteralPath $targetDir -Force -ErrorAction Stop).Count -ne 0) {
        throw "$Context acquired new items during cleanup; refusing deletion."
    }
    Assert-RendererDirectoryLease $Lease $Root $Path "$Context before held-handle delete"
    [RendererCompatibility.NativePath]::DeleteDirectory($Lease.Handle)
    $Lease.DeletePending = $true
    $Lease.Handle.Dispose()
}
function Get-RendererEnvironmentSnapshot {
    [CmdletBinding()]
    param()

    $os = Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction Stop
    $architecture = if ([Environment]::Is64BitOperatingSystem) { 'x64' } else { 'x86' }
    $adapters = @(
        Get-CimInstance -ClassName Win32_VideoController -ErrorAction Stop |
            Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_.PNPDeviceID) } |
            Sort-Object PNPDeviceID |
            ForEach-Object {
                if ([string]::IsNullOrWhiteSpace([string]$_.Name) -or
                    [string]::IsNullOrWhiteSpace([string]$_.DriverVersion)) {
                    throw 'A graphics adapter did not expose a name and driver version.'
                }
                [pscustomobject][ordered]@{
                    displayName = [string]$_.Name
                    pnpDeviceId = [string]$_.PNPDeviceID
                    driverVersion = [string]$_.DriverVersion
                }
            })
    if ($adapters.Count -lt 1) { throw 'No graphics adapter with a PNP identity was observed.' }

    $sessionId = [Diagnostics.Process]::GetCurrentProcess().SessionId
    $sessionName = [string]$env:SESSIONNAME
    $isRemote = (-not [string]::IsNullOrWhiteSpace($sessionName) -and $sessionName -match '^(RDP|ICA)')
    $kind = if ($isRemote) { 'Rdp' } elseif ($sessionId -gt 0) { 'LocalConsole' } else { 'Unknown' }
    $transport = if ($isRemote) { 'Rdp' } elseif ($kind -eq 'LocalConsole') { 'Physical' } else { 'Unknown' }
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $elevated = $false
    if ($null -ne $identity) {
        $principal = New-Object Security.Principal.WindowsPrincipal($identity)
        $elevated = [bool]$principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    }
    $userScope = if (-not [string]::IsNullOrWhiteSpace([string]$env:USERNAME)) { 'SingleUser' } else { 'Unknown' }
    $powerSource = 'Unknown'
    $batteryCandidates = @(Get-CimInstance -ClassName Win32_Battery -ErrorAction SilentlyContinue)
    $battery = if ($batteryCandidates.Count -gt 0) { $batteryCandidates[0] } else { $null }
    if ($null -eq $battery) {
        $powerSource = 'AC'
    } elseif ([int]$battery.BatteryStatus -eq 2) {
        $powerSource = 'AC'
    } else {
        $powerSource = 'Battery'
    }
    $thermalState = 'Unknown'
    $thermal = @(Get-CimInstance -Namespace root/wmi -ClassName MSAcpi_ThermalZoneTemperature -ErrorAction SilentlyContinue)
    if ($thermal.Count -gt 0) {
        $maxCelsius = ($thermal | ForEach-Object { ([double]$_.CurrentTemperature / 10.0) - 273.15 } | Measure-Object -Maximum).Maximum
        $thermalState = if ($maxCelsius -ge 85) { 'Throttled' } elseif ($maxCelsius -ge 70) { 'Warm' } else { 'Nominal' }
    }

    [pscustomobject][ordered]@{
        os = [ordered]@{
            caption = [string]$os.Caption
            version = [string]$os.Version
            build = [int]$os.BuildNumber
            architecture = $architecture
        }
        graphicsAdapters = @($adapters)
        session = [ordered]@{
            kind = $kind
            name = if ([string]::IsNullOrWhiteSpace($sessionName)) { "Session-$sessionId" } else { $sessionName }
            sessionId = [int]$sessionId
            transport = $transport
            powerSource = $powerSource
            thermalState = $thermalState
            elevated = $elevated
            userScope = $userScope
        }
        supportScope = [ordered]@{
            supported = @('windows11-x64-build26220','automated-packaged-rendering','non-elevated','single-user')
            excluded = @('rdp-runtime','vm-runtime','arm64','remote-cloud','multi-user')
            vmCleanInstallOnly = $true
            vmRuntimeCredit = $false
        }
    }
}
function Assert-RendererEnvironmentSnapshot {
    param($Environment,[string]$Context='Environment')
    Assert-RendererExactProperties $Environment @('os','graphicsAdapters','session','supportScope') $Context
    Assert-RendererExactProperties $Environment.os @('caption','version','build','architecture') "$Context OS"
    Assert-RendererString $Environment.os.caption "$Context OS caption"
    Assert-RendererString $Environment.os.version "$Context OS version"
    Assert-RendererPositiveInteger $Environment.os.build "$Context OS build"
    if ([string]$Environment.os.architecture -cnotin @('x64','x86','arm64')) { throw "$Context OS architecture is invalid." }
    $adapters = @($Environment.graphicsAdapters)
    if ($adapters.Count -lt 1 -or $adapters.Count -gt 16) { throw "$Context graphics adapter count is outside the bounded range." }
    $adapterIds = @()
    foreach ($adapter in $adapters) {
        Assert-RendererExactProperties $adapter @('displayName','pnpDeviceId','driverVersion') "$Context graphics adapter"
        Assert-RendererString $adapter.displayName "$Context graphics adapter name"
        Assert-RendererString $adapter.pnpDeviceId "$Context graphics adapter PNP ID"
        Assert-RendererString $adapter.driverVersion "$Context graphics adapter driver"
        $adapterIds += [string]$adapter.pnpDeviceId
    }
    if ((@($adapterIds | Select-Object -Unique)).Count -ne $adapterIds.Count) { throw "$Context graphics adapter PNP IDs must be unique." }
    Assert-RendererExactProperties $Environment.session @('kind','name','sessionId','transport','powerSource','thermalState','elevated','userScope') "$Context session"
    if ([string]$Environment.session.kind -cnotin @('LocalConsole','Rdp','Unknown')) { throw "$Context session kind is invalid." }
    if ([string]$Environment.session.transport -cnotin @('Physical','Rdp','Unknown')) { throw "$Context session transport is invalid." }
    Assert-RendererString $Environment.session.name "$Context session name"
    Assert-RendererNonnegativeInteger $Environment.session.sessionId "$Context session ID"
    Assert-RendererBoolean $Environment.session.elevated "$Context session elevated"
    if ([string]$Environment.session.powerSource -cnotin @('AC','Battery','Unknown')) { throw "$Context power source is invalid." }
    if ([string]$Environment.session.thermalState -cnotin @('Nominal','Warm','Throttled','Unknown')) { throw "$Context thermal state is invalid." }
    if ([string]$Environment.session.userScope -cnotin @('SingleUser','Unknown')) { throw "$Context user scope is invalid." }
    $support = $Environment.supportScope
    Assert-RendererExactProperties $support @('supported','excluded','vmCleanInstallOnly','vmRuntimeCredit') "$Context support scope"
    Assert-RendererBoolean $support.vmCleanInstallOnly "$Context VM clean-install scope"
    Assert-RendererBoolean $support.vmRuntimeCredit "$Context VM Runtime scope"
    if (-not $support.vmCleanInstallOnly -or $support.vmRuntimeCredit) { throw "$Context VM evidence boundary is invalid." }
    Assert-RendererSet @($support.supported) @('windows11-x64-build26220','automated-packaged-rendering','non-elevated','single-user') "$Context supported scope"
    Assert-RendererSet @($support.excluded) @('rdp-runtime','vm-runtime','arm64','remote-cloud','multi-user') "$Context excluded scope"
}
function Assert-RendererLiveEnvironment {
    param($Environment,[string]$RepositoryRoot)
    Assert-RendererEnvironmentSnapshot $Environment 'Live environment'
    if ($Environment.os.architecture -ne 'x64' -or [int]$Environment.os.build -ne 26220 -or
        [string]$Environment.os.caption -notmatch '^Microsoft Windows 11') {
        throw 'Live renderer capture requires the approved Windows 11 x64 build 26220 cohort.'
    }
    if ($Environment.session.kind -ne 'LocalConsole' -or $Environment.session.transport -ne 'Physical' -or
        [bool]$Environment.session.elevated -or $Environment.session.userScope -ne 'SingleUser') {
        throw 'Live renderer capture requires a local, physical, non-elevated single-user session.'
    }
    $referencePath = Join-Path $RepositoryRoot 'Plan\reference-hosts\v0.2.json'
    if (-not (Test-Path -LiteralPath $referencePath -PathType Leaf)) { throw 'Reference-host profile is missing for live environment binding.' }
    $referenceJson = [IO.File]::ReadAllText($referencePath)
    $reference = if ($PSVersionTable.PSVersion.Major -ge 7 -and (Get-Command ConvertFrom-Json).Parameters.ContainsKey('DateKind')) { $referenceJson | ConvertFrom-Json -DateKind String } else { $referenceJson | ConvertFrom-Json }
    $referenceHost = $reference.environmentBinding.host
    if ([string]$Environment.os.caption -cne [string]$referenceHost.operatingSystemCaption -or
        [string]$Environment.os.version -cne [string]$referenceHost.operatingSystemVersion -or
        [int]$Environment.os.build -ne [int]$referenceHost.operatingSystemBuild -or
        [string]$Environment.os.architecture -cne [string]$referenceHost.architecture) { throw 'Observed live OS does not match the approved reference-host profile.' }
    # D-026 omits physical-display and desktop-DPI observations from admission.
    # Power-source and thermal observations remain diagnostic-only. The six
    # governed configurations are collected as off-screen packaged-rendering cases.
    $expectedAdapters = @($reference.environmentBinding.graphicsAdapters | Sort-Object pnpDeviceId)
    $actualAdapters = @($Environment.graphicsAdapters | Sort-Object pnpDeviceId)
    if ($actualAdapters.Count -ne $expectedAdapters.Count) { throw 'Observed live graphics adapter count does not match the approved reference-host profile.' }
    for ($i = 0; $i -lt $actualAdapters.Count; $i++) {
        foreach ($name in @('displayName','pnpDeviceId','driverVersion')) {
            if ([string]$actualAdapters[$i].$name -cne [string]$expectedAdapters[$i].$name) { throw "Observed live graphics adapter '$name' does not match the approved reference-host profile." }
        }
    }
}
function Get-RendererStableFileIdentity { param([string]$Root,[string]$Path,[string]$Context,[switch]$IncludeBytes,[switch]$KeepOpen)
    $rootFull=[IO.Path]::GetFullPath($Root).TrimEnd('\','/');$pathFull=[IO.Path]::GetFullPath($Path);Assert-RendererNonReparsePath $rootFull $pathFull $Context
    $stream=New-Object IO.FileStream($pathFull,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read)
    $streamOwnershipTransferred=$false
    try{
        $final=[IO.Path]::GetFullPath([RendererCompatibility.NativePath]::GetFinalPath($stream.SafeFileHandle));if($final-cne$pathFull){throw "$Context final opened path changed."};if($final-cne$rootFull-and-not$final.StartsWith($rootFull+[IO.Path]::DirectorySeparatorChar,[StringComparison]::OrdinalIgnoreCase)){throw "$Context final opened path escaped the evidence root."}
        $snapshot=[RendererCompatibility.NativePath]::GetSnapshot($stream.SafeFileHandle);$fileIdentity=[string]$snapshot.FileIdentity;$linkCount=[long]$snapshot.LinkCount;if($linkCount-ne1){throw "$Context must have exactly one hard link."};if([long]$snapshot.Length-ne[long]$stream.Length){throw "$Context by-handle length differs from stream length."}
        $before=$stream.Length;$algorithm=[Security.Cryptography.SHA256]::Create();try{$hash=([BitConverter]::ToString($algorithm.ComputeHash($stream))).Replace('-','').ToUpperInvariant()}finally{$algorithm.Dispose()};$after=$stream.Length;if($before-ne$after-or$stream.Position-ne$after){throw "$Context changed during the same-handle read."}
        $bytes=$null;if($IncludeBytes){if($after-gt$script:RendererMaximumManifestBytes){throw "$Context exceeds the bounded read."};$stream.Position=0;$bytes=New-Object byte[] ([int]$after);$offset=0;while($offset-lt$bytes.Length){$read=$stream.Read($bytes,$offset,$bytes.Length-$offset);if($read-le0){throw "$Context ended during the same-handle read."};$offset+=$read};$rereadAlgorithm=[Security.Cryptography.SHA256]::Create();try{$rereadHash=([BitConverter]::ToString($rereadAlgorithm.ComputeHash($bytes))).Replace('-','').ToUpperInvariant()}finally{$rereadAlgorithm.Dispose()};if($rereadHash-cne$hash){throw "$Context bytes changed between the same-handle hash and reread."}}
        $finalAfter=[IO.Path]::GetFullPath([RendererCompatibility.NativePath]::GetFinalPath($stream.SafeFileHandle));$snapshotAfter=[RendererCompatibility.NativePath]::GetSnapshot($stream.SafeFileHandle);if($finalAfter-cne$final-or[string]$snapshotAfter.FileIdentity-cne$fileIdentity-or[long]$snapshotAfter.LinkCount-ne1-or[long]$snapshotAfter.Length-ne[long]$snapshot.Length-or[long]$snapshotAfter.LastWriteTimeUtcFileTime-ne[long]$snapshot.LastWriteTimeUtcFileTime-or[long]$stream.Length-ne[long]$snapshot.Length){throw "$Context FinalPath/FileId/link-count/by-handle length/LastWriteTime changed during the same-handle read."}
        $result=[pscustomobject]@{Bytes=[long]$after;Sha256=$hash;Content=$bytes;FinalPath=$final;FileIdentity=$fileIdentity;LinkCount=$linkCount;LastWriteTimeUtc=[DateTime]::FromFileTimeUtc([long]$snapshot.LastWriteTimeUtcFileTime);Stream=if($KeepOpen){$stream}else{$null}}
        if($KeepOpen){$streamOwnershipTransferred=$true}
        return $result
    }finally{if(-not$streamOwnershipTransferred){$stream.Dispose()}}
}
function Assert-RendererRequiredProperties { param($Value,[string[]]$Names,[string]$Context)
    if ($null -eq $Value) { throw "$Context is missing." }
    foreach ($name in $Names) { if (-not (@($Value.PSObject.Properties.Name) -ccontains $name)) { throw "$Context omitted '$name'." } }
}
function Get-RendererProcessIdentity { param([int]$ProcessId,[string]$ExpectedPath,[string]$Context)
    if ($ProcessId -le 0) { throw "$Context PID must be positive." }
    $expectedFull=[IO.Path]::GetFullPath($ExpectedPath)
    if (-not (Test-Path -LiteralPath $expectedFull -PathType Leaf)) { throw "$Context expected executable is missing: $expectedFull" }
    try { $process=Get-Process -Id $ProcessId -ErrorAction Stop; $process.Refresh(); $modulePath=[IO.Path]::GetFullPath([string]$process.MainModule.FileName); $start=$process.StartTime.ToUniversalTime() } catch { throw "$Context process identity could not be observed: $($_.Exception.Message)" }
    if (-not [string]::Equals($modulePath,$expectedFull,[StringComparison]::OrdinalIgnoreCase)) { throw "$Context executable path does not equal the bound package component." }
    $stable=Get-RendererStableFileIdentity (Split-Path $expectedFull -Parent) $expectedFull "$Context executable"
    if (-not [string]::Equals($stable.FinalPath,$expectedFull,[StringComparison]::OrdinalIgnoreCase)) { throw "$Context executable final path changed during observation." }
    [pscustomobject][ordered]@{role=$Context;pid=[int]$process.Id;startTimeUtc=$start.ToUniversalTime().ToString('O',[Globalization.CultureInfo]::InvariantCulture);executablePath=$modulePath;executableFinalPath=$stable.FinalPath;bytes=[long]$stable.Bytes;sha256=[string]$stable.Sha256;processName=[string]$process.ProcessName}
}
function Assert-RendererProcessIdentityEqual { param($Actual,$Expected,[string]$Context)
    foreach($name in @('role','pid','startTimeUtc','executablePath','executableFinalPath','bytes','sha256','processName')) { if ($Actual.$name -cne $Expected.$name) { throw "$Context '$name' changed; PID reuse or executable replacement detected." } }
}
function Get-RendererWindowObservation { param([int]$TargetAppPid,[string]$TargetAppStartTimeUtc,[string]$Context,[long]$ExpectedHwnd)
    try {
        $process = Get-Process -Id $TargetAppPid -ErrorAction Stop
        $process.Refresh()
        $handles = @([RendererCompatibility.NativePath]::GetProcessWindowHandles($TargetAppPid))
    } catch {
        throw "$Context target App window could not be observed: $($_.Exception.Message)"
    }
    if ($ExpectedHwnd -eq 0) {
        if ($handles.Count -ne 0) { throw "$Context independently observed a process-owned native HWND before the governed boundary." }
        return [pscustomobject][ordered]@{hasAnyHwnd=$false;hwnd=[long]0;ownerPid=[int]0;ownerStartTimeUtc=$null}
    }
    if ($handles -notcontains $ExpectedHwnd) { throw "$Context expected HWND is not among the process-owned native HWNDs." }
    $hwnd = $ExpectedHwnd
    if (-not [RendererCompatibility.NativePath]::IsLiveWindow([IntPtr]$hwnd)) { throw "$Context reported an HWND that is no longer live." }
    if (-not [RendererCompatibility.NativePath]::IsWindowResponsive([IntPtr]$hwnd, 2000)) { throw "$Context target App window HWND is unresponsive or hung (SendMessageTimeout timed out)." }
    $ownerPid = [RendererCompatibility.NativePath]::GetWindowOwnerProcessId([IntPtr]$hwnd)
    if ($ownerPid -ne $TargetAppPid) { throw "$Context HWND owner PID does not equal the target App PID." }
    $owner = Get-RendererProcessIdentity $ownerPid $process.MainModule.FileName "$Context HWND owner"
    if ($owner.startTimeUtc -cne $TargetAppStartTimeUtc) { throw "$Context HWND owner start time does not equal the target App start time." }
    [pscustomobject][ordered]@{hasAnyHwnd=$true;hwnd=[long]$hwnd;ownerPid=[int]$ownerPid;ownerStartTimeUtc=[string]$owner.startTimeUtc}
}
function Assert-RendererPipeName { param([string]$Name)
    if ([string]::IsNullOrWhiteSpace($Name) -or $Name -notmatch '^[A-Za-z0-9_.-]{1,200}$') { throw 'Target observation pipe name is invalid.' }
}
function New-RendererTargetObservationPipe { param([string]$Name)
    Assert-RendererPipeName $Name
    $options = [IO.Pipes.PipeOptions]::Asynchronous
    if ([Enum]::GetNames([IO.Pipes.PipeOptions]) -contains 'CurrentUserOnly') {
        $currentUserOnly = [IO.Pipes.PipeOptions]([Enum]::Parse([IO.Pipes.PipeOptions], 'CurrentUserOnly'))
        return New-Object IO.Pipes.NamedPipeServerStream($Name,[IO.Pipes.PipeDirection]::InOut,1,[IO.Pipes.PipeTransmissionMode]::Byte,($options -bor $currentUserOnly))
    }
    $security = New-Object IO.Pipes.PipeSecurity
    $security.SetAccessRuleProtection($true, $false)
    $sid = [Security.Principal.WindowsIdentity]::GetCurrent().User
    $rule = New-Object IO.Pipes.PipeAccessRule($sid,[IO.Pipes.PipeAccessRights]::FullControl,[Security.AccessControl.AccessControlType]::Allow)
    $security.AddAccessRule($rule)
    New-Object IO.Pipes.NamedPipeServerStream($Name,[IO.Pipes.PipeDirection]::InOut,1,[IO.Pipes.PipeTransmissionMode]::Byte,$options,0,0,$security)
}
function Wait-RendererTargetObservationPipe { param($Pipe,[int]$TimeoutSeconds=30)
    $async=$Pipe.BeginWaitForConnection($null,$null)
    if (-not $async.AsyncWaitHandle.WaitOne($TimeoutSeconds*1000)) { throw "Target observation pipe did not connect within $TimeoutSeconds seconds." }
    $Pipe.EndWaitForConnection($async)
    [RendererCompatibility.NativePath]::GetPipeClientProcessId($Pipe.SafePipeHandle.DangerousGetHandle())
}
function Assert-RendererPipeClientProcessId { param([int]$ActualClientPid,[int]$ExpectedProcessId,[string]$Context)
    if($ActualClientPid-le0-or$ExpectedProcessId-le0-or$ActualClientPid-ne$ExpectedProcessId){throw "$Context pipe was not connected by the launched packaged App PID."}
}
function Read-RendererTargetPipeLine { param([IO.StreamReader]$Reader,[int]$TimeoutSeconds=30)
    $task=$Reader.ReadLineAsync()
    if (-not $task.Wait($TimeoutSeconds*1000)) {
        # A pending StreamReader ReadLineAsync can otherwise make later Reader
        # disposal wait forever. Tear down the failed transport before throwing;
        # callers cannot safely reuse a pipe after a response deadline anyway.
        try { $Reader.BaseStream.Dispose() } catch {}
        throw "Target observation pipe response timed out after $TimeoutSeconds seconds."
    }
    $line=$task.GetAwaiter().GetResult()
    if ([string]::IsNullOrWhiteSpace($line)) { throw 'Target observation pipe closed without a response.' }
    $line
}
function ConvertFrom-RendererTransportJson { param([string]$Json,[string]$Context='Renderer transport JSON')
    $value=ConvertFrom-StrictHumanDesignReviewJson -Json $Json -Description $Context
    if($PSVersionTable.PSVersion.Major-ge7-and(Get-Command ConvertFrom-Json).Parameters.ContainsKey('DateKind')){return ($Json|ConvertFrom-Json -DateKind String)}
    return $value
}
function Close-RendererTargetPipeSession {
    param($Writer,$Reader,$Pipe,$AppProcess,[DateTime]$AppStartTimeUtc=[DateTime]::MinValue,[int]$GracefulWaitMilliseconds=10000,[int]$KillWaitMilliseconds=5000)
    $writerAttempted=$false;$readerAttempted=$false;$pipeAttempted=$false;$appAttempted=$false;$terminationAttempted=$false
    if($null-ne$Writer){$writerAttempted=$true;try{$Writer.Dispose()}catch{}}
    if($null-ne$Reader){$readerAttempted=$true;try{$Reader.Dispose()}catch{}}
    if($null-ne$Pipe){$pipeAttempted=$true;try{$Pipe.Dispose()}catch{}}
    if($null-ne$AppProcess){
        $appAttempted=$true
        try{
            if(-not$AppProcess.HasExited){$AppProcess.WaitForExit($GracefulWaitMilliseconds)|Out-Null}
            if(-not$AppProcess.HasExited-and($AppStartTimeUtc-eq[DateTime]::MinValue-or$AppProcess.StartTime.ToUniversalTime()-eq$AppStartTimeUtc)){$terminationAttempted=$true;$AppProcess.Kill();$AppProcess.WaitForExit($KillWaitMilliseconds)|Out-Null}
        }catch{}finally{try{$AppProcess.Dispose()}catch{}}
    }
    [pscustomobject][ordered]@{WriterCleanupAttempted=$writerAttempted;ReaderCleanupAttempted=$readerAttempted;PipeCleanupAttempted=$pipeAttempted;AppCleanupAttempted=$appAttempted;AppTerminationAttempted=$terminationAttempted}
}
function Write-RendererTargetPipeLine { param([IO.StreamWriter]$Writer,[string]$Line)
    $Writer.WriteLine($Line);$Writer.Flush()
}
function Assert-RendererTargetBindingReceipt { param($Receipt,$Manifest)
    Assert-RendererExactProperties $Receipt @('receiptType','protocolVersion','appProcess','coreProcess','pipeClientPid','observations','captureBindings') 'Target binding receipt'
    if ($Receipt.receiptType -cne 'V02RendererTargetBinding' -or [int]$Receipt.protocolVersion -ne 1) { throw 'Target binding receipt identity is invalid.' }
    foreach($pair in @(@('App',$Receipt.appProcess),@('Core',$Receipt.coreProcess))) {
        $role=[string]$pair[0];$process=$pair[1];Assert-RendererExactProperties $process @('role','pid','startTimeUtc','executablePath','executableFinalPath','bytes','sha256','processName') "Target $role process";if($process.role-cne$role){throw "Target $role process role is invalid."};Assert-RendererPositiveInteger $process.pid "Target $role PID";Assert-RendererUtc $process.startTimeUtc "Target $role start time";Assert-RendererString $process.executablePath "Target $role executable path";Assert-RendererString $process.executableFinalPath "Target $role executable final path";Assert-RendererPositiveInteger $process.bytes "Target $role executable bytes";Assert-RendererSha $process.sha256 "Target $role executable SHA-256";Assert-RendererString $process.processName "Target $role process name"
    }
    if ([int]$Receipt.pipeClientPid -ne [int]$Receipt.appProcess.pid) { throw 'Target observation pipe client is not the bound App PID.' }
    $observations=@($Receipt.observations);if($observations.Count-ne$script:RendererObservationStages.Count){throw 'Target binding receipt must contain exactly 8 observations.'}
    $manifestObservations=@($Manifest.rendererEvidence.throughoutObservations);$previous=$null
    $firstPostFirstHwnd=$null
    for($i=0;$i-lt$script:RendererObservationStages.Count;$i++){
        $observation=$observations[$i];Assert-RendererExactProperties $observation @('stage','ordinal','observedUtc','appProcess','coreProcess','window','render','captures') "Target observation $i";if($observation.stage-cne$script:RendererObservationStages[$i]-or[int]$observation.ordinal-ne$i){throw "Target observation $i stage/ordinal is invalid."};Assert-RendererUtc $observation.observedUtc "Target observation $i UTC";if($null-ne$previous-and[DateTimeOffset]$observation.observedUtc-lt$previous){throw 'Target observations are not ordered by UTC.'};$previous=[DateTimeOffset]$observation.observedUtc;Assert-RendererProcessIdentityEqual $observation.appProcess $Receipt.appProcess "Target observation $i App";Assert-RendererProcessIdentityEqual $observation.coreProcess $Receipt.coreProcess "Target observation $i Core"
        $window=$observation.window;Assert-RendererExactProperties $window @('hasAnyHwnd','hwnd','ownerPid','ownerStartTimeUtc') "Target observation $i window";Assert-RendererBoolean $window.hasAnyHwnd "Target observation $i HWND state";Assert-RendererNonnegativeInteger $window.hwnd "Target observation $i HWND";Assert-RendererNonnegativeInteger $window.ownerPid "Target observation $i HWND owner PID";Assert-RendererNullableUtc $window.ownerStartTimeUtc "Target observation $i HWND owner start";if($i-lt2-and[bool]$window.hasAnyHwnd){throw 'Target observation reported an HWND before PreFirstWindow.'};if($i-ge2-and-not[bool]$window.hasAnyHwnd){throw 'Target observation omitted the HWND after first-window boundary.'};if(-not[bool]$window.hasAnyHwnd-and([long]$window.hwnd-ne0-or[int]$window.ownerPid-ne0-or$null-ne$window.ownerStartTimeUtc)){throw 'Target no-HWND observation contains ownership data.'};if([bool]$window.hasAnyHwnd-and([long]$window.hwnd-le0-or[int]$window.ownerPid-ne[int]$Receipt.appProcess.pid-or[string]$window.ownerStartTimeUtc-cne[string]$Receipt.appProcess.startTimeUtc)){throw 'Target HWND ownership is not bound to the App PID/start identity.'}
        if($i-eq2){if(-not[bool]$window.hasAnyHwnd-or[long]$window.hwnd-le0){throw 'Target observation 2 did not expose a non-zero live HWND.'};$firstPostFirstHwnd=[long]$window.hwnd}
        if($i-ge2){if([long]$window.hwnd-ne$firstPostFirstHwnd){throw "Target observation $i HWND ($($window.hwnd)) changed from initial post-first-window HWND ($firstPostFirstHwnd); HWND continuity violated."}}
        $render=$observation.render;Assert-RendererExactProperties $render @('source','processId','processStartUtc','effectiveMode','softwareOnlyConfirmed','nativeProcessRenderMode','nativeRenderCapabilityTier') "Target observation $i render";if($render.source-cne'TargetProcessNativeObservation'-or[int]$render.processId-ne[int]$Receipt.appProcess.pid-or[string]$render.processStartUtc-cne[string]$Receipt.appProcess.startTimeUtc-or$render.effectiveMode-cne'SoftwareOnly'-or-not[bool]$render.softwareOnlyConfirmed-or$render.nativeProcessRenderMode-cne'SoftwareOnly'){throw "Target observation $i render-mode provenance is invalid."};Assert-RendererUtc $render.processStartUtc "Target observation $i render process start";Assert-RendererNonnegativeInteger $render.nativeRenderCapabilityTier "Target observation $i render tier"
        $manifestObservation=$manifestObservations[$i];if($observation.stage-cne$manifestObservation.stage-or$observation.observedUtc-cne$manifestObservation.observedUtc-or$observation.render.effectiveMode-cne$manifestObservation.effectiveMode-or$observation.render.softwareOnlyConfirmed-cne$manifestObservation.softwareOnlyConfirmed){throw "Target observation $i does not equal the manifest renderer observation."}
    }
    $captureBindings=@($Receipt.captureBindings);if($captureBindings.Count-ne$Manifest.captures.Count){throw 'Target binding receipt capture count does not equal manifest capture count.'};$expectedKeys=@($Manifest.captures|ForEach-Object{"$($_.language)|$($_.name)"});$actualKeys=@()
    $runnerTokens=@();$fileIdentities=@();for($i=0;$i-lt$captureBindings.Count;$i++){$capture=$captureBindings[$i];Assert-RendererExactProperties $capture @('language','name','relativePath','bytes','sha256','widthPixels','heightPixels','observedUtc','producerPid','producerStartUtc','runnerTokenSha256','fileIdentity','linkCount') "Target capture $i";$actualKeys+="$($capture.language)|$($capture.name)";Assert-RendererRelativePath $capture.relativePath "Target capture $i path";Assert-RendererPositiveInteger $capture.bytes "Target capture $i bytes";Assert-RendererSha $capture.sha256 "Target capture $i SHA-256";Assert-RendererSha $capture.runnerTokenSha256 "Target capture $i runner token";$runnerTokens+=[string]$capture.runnerTokenSha256;Assert-RendererString $capture.fileIdentity "Target capture $i FileId";$fileIdentities+=[string]$capture.fileIdentity;if([long]$capture.linkCount-ne1){throw "Target capture $i must have exactly one hard link."};Assert-RendererPositiveInteger $capture.widthPixels "Target capture $i width";Assert-RendererPositiveInteger $capture.heightPixels "Target capture $i height";Assert-RendererUtc $capture.observedUtc "Target capture $i UTC";Assert-RendererPositiveInteger $capture.producerPid "Target capture $i producer PID";Assert-RendererUtc $capture.producerStartUtc "Target capture $i producer start";if($capture.producerPid-ne$Receipt.appProcess.pid-or$capture.producerStartUtc-cne$Receipt.appProcess.startTimeUtc){throw "Target capture $i producer identity does not equal the App PID/start identity."};$manifestCapture=$Manifest.captures[$i];foreach($name in @('language','name','relativePath','bytes','sha256','widthPixels','heightPixels','observedUtc')){if($capture.$name-cne$manifestCapture.$name){throw "Target capture $i does not equal manifest capture '$name'."}}};if(@($runnerTokens|Select-Object -Unique).Count-ne$captureBindings.Count){throw 'Target capture runner tokens are not unique per capture.'};if(@($fileIdentities|Select-Object -Unique).Count-ne$captureBindings.Count){throw 'Target captures must have distinct file identities.'}
    for($i=0;$i-lt$expectedKeys.Count;$i++){if($actualKeys[$i]-cne$expectedKeys[$i]){throw "Target capture index $i is not '$($expectedKeys[$i])'."}}
}
function Get-RendererPngIdentity { param([string]$Root,[string]$Path,[string]$Context)
    $identity=Get-RendererStableFileIdentity $Root $Path $Context -IncludeBytes;$stream=New-Object IO.MemoryStream(,$identity.Content);try{$decoder=New-Object Windows.Media.Imaging.PngBitmapDecoder($stream,[Windows.Media.Imaging.BitmapCreateOptions]::PreservePixelFormat,[Windows.Media.Imaging.BitmapCacheOption]::OnLoad);if($decoder.Frames.Count-ne1){throw "$Context must decode as exactly one PNG frame."};$frame=$decoder.Frames[0];if($frame.PixelWidth-le0-or$frame.PixelHeight-le0){throw "$Context decoded PNG dimensions are invalid."};return [pscustomobject]@{Width=[int]$frame.PixelWidth;Height=[int]$frame.PixelHeight;Bytes=$identity.Bytes;Sha256=$identity.Sha256;Content=$identity.Content;Frame=$frame;FinalPath=$identity.FinalPath;FileIdentity=$identity.FileIdentity;LinkCount=$identity.LinkCount;LastWriteTimeUtc=$identity.LastWriteTimeUtc}}catch{throw "$Context is not a complete decodable PNG: $($_.Exception.Message)"}finally{$stream.Dispose()}
}
function Test-RendererMatrixPngContent { param($Frame,[string]$Context)
    $decoded=Get-RendererBgraPixels $Frame;$pixels=$decoded.Pixels;$total=[long]$decoded.Width*$decoded.Height
    if($total-le0-or$pixels.Length-ne$total*4){throw "$Context decoded pixel inventory is invalid."}
    $background=@([int]$pixels[0],[int]$pixels[1],[int]$pixels[2]);[long]$opaque=0;[long]$content=0;$minimum=255;$maximum=0
    for($offset=0;$offset-lt$pixels.Length;$offset+=4){
        if([int]$pixels[$offset+3]-ge250){$opaque++}
        $delta=[Math]::Max([Math]::Abs([int]$pixels[$offset]-$background[0]),[Math]::Max([Math]::Abs([int]$pixels[$offset+1]-$background[1]),[Math]::Abs([int]$pixels[$offset+2]-$background[2])))
        if([int]$pixels[$offset+3]-gt0-and$delta-gt8){$content++}
        foreach($channel in 0,1,2){$value=[int]$pixels[$offset+$channel];if($value-lt$minimum){$minimum=$value};if($value-gt$maximum){$maximum=$value}}
    }
    $opaqueRatio=[double]$opaque/$total;$contentRatio=[double]$content/$total;$range=$maximum-$minimum
    [pscustomobject]@{Pass=($opaqueRatio-ge0.95-and$contentRatio-ge0.005-and$contentRatio-le0.95-and$range-ge32);OpaqueRatio=$opaqueRatio;ContentRatio=$contentRatio;ChannelRange=$range}
}
function Assert-RendererFileBinding { param($Binding,[string]$Context,[string]$Root,[switch]$ValidateBindings)
    Assert-RendererExactProperties $Binding @('relativePath','bytes','sha256') $Context
    Assert-RendererRelativePath $Binding.relativePath "$Context relativePath"; Assert-RendererPositiveInteger $Binding.bytes "$Context bytes"; Assert-RendererSha $Binding.sha256 "$Context sha256"
    if($ValidateBindings){$full=Resolve-RendererBoundPath $Root $Binding.relativePath "$Context relativePath";if(-not(Test-Path -LiteralPath $full -PathType Leaf)){throw "$Context file is missing."};$identity=Get-RendererStableFileIdentity $Root $full $Context;if($identity.Bytes-ne[long]$Binding.bytes){throw "$Context byte count mismatch."};if($identity.Sha256-cne[string]$Binding.sha256){throw "$Context SHA-256 mismatch."}}
}
function Read-RendererEvidenceReceipt { param($Binding,[string]$Context,[string]$Root,[string]$RepositoryRoot,[switch]$KeepOpen)
    Assert-RendererExactProperties $Binding @('relativePath','bytes','fileSha256','canonicalSha256') "$Context binding";Assert-RendererRelativePath $Binding.relativePath "$Context path";Assert-RendererPositiveInteger $Binding.bytes "$Context bytes";Assert-RendererSha $Binding.fileSha256 "$Context raw hash";Assert-RendererSha $Binding.canonicalSha256 "$Context canonical hash";$path=Resolve-RendererBoundPath $Root $Binding.relativePath "$Context path";$stable=Get-RendererStableFileIdentity $Root $path $Context -IncludeBytes -KeepOpen:$KeepOpen;if($stable.Bytes-ne[long]$Binding.bytes-or$stable.Sha256-cne$Binding.fileSha256){if($null-ne$stable.Stream){$stable.Stream.Dispose()};throw "$Context raw binding failed."};try{$json=(New-Object Text.UTF8Encoding($false,$true)).GetString($stable.Content);$value=ConvertFrom-StrictHumanDesignReviewJson -Json $json -Description $Context;if($PSVersionTable.PSVersion.Major-ge7-and(Get-Command ConvertFrom-Json).Parameters.ContainsKey('DateKind')){$value=$json|ConvertFrom-Json -DateKind String};$canonical=ConvertTo-RendererCanonicalJson $value $RepositoryRoot;$canonicalSha=Get-HumanDesignReviewSha256ForText $canonical;if($json-cne($canonical+"`n")-or$canonicalSha-cne$Binding.canonicalSha256){throw "$Context must be exact canonical JSON plus one LF with matching canonical SHA-256."};[pscustomobject]@{Value=$value;Stable=$stable;CanonicalSha256=$canonicalSha}}catch{if($null-ne$stable.Stream){$stable.Stream.Dispose()};throw}
}
function Assert-RendererBindingEqual { param($A,$B,[string]$Context)
    foreach($name in @('relativePath','bytes','fileSha256','canonicalSha256')){if($A.$name-cne$B.$name){throw "$Context binding field '$name' mismatch."}}
}
function Get-RendererGitIdentity { param([string]$RepositoryRoot)
    $repo=[IO.Path]::GetFullPath($RepositoryRoot);Assert-RendererNonReparsePath $repo $repo 'Repository root';$commit=@(& git -C $repo rev-parse HEAD 2>&1);$commitExit=$LASTEXITCODE;$global:LASTEXITCODE=0;$tree=@(& git -C $repo rev-parse 'HEAD^{tree}' 2>&1);$treeExit=$LASTEXITCODE;$global:LASTEXITCODE=0;$status=@(& git -C $repo status --porcelain=v1 --untracked-files=all 2>&1);$statusExit=$LASTEXITCODE;$global:LASTEXITCODE=0;if($commitExit-ne0-or$treeExit-ne0-or$statusExit-ne0-or$commit.Count-ne1-or$tree.Count-ne1-or$status.Count-ne0-or[string]$commit[0]-cnotmatch'^[0-9a-f]{40}$'-or[string]$tree[0]-cnotmatch'^[0-9a-f]{40}$'){throw 'Unable to bind an exact clean repository commit/tree.'};return [pscustomobject]@{CommitSha=[string]$commit[0];TreeSha=[string]$tree[0]}
}
function Assert-RendererPackageProfile { param($Profile)
    Assert-RendererExactProperties $Profile @('schemaVersion','profileId','issue','packageVersion','runtimeIdentifier','archiveFileName','packageManifestFileName','sourcePolicy','approval','components','referenceHost','renderer','evidenceBoundary') 'Package profile';Assert-RendererNonnegativeInteger $Profile.schemaVersion 'Package profile schemaVersion';Assert-RendererNonnegativeInteger $Profile.issue 'Package profile issue';if([long]$Profile.schemaVersion-ne1-or[long]$Profile.issue-ne149){throw 'Package profile version/issue is invalid.'};if($Profile.profileId-cne$script:RendererPackageProfileId-or$Profile.packageVersion-cne'0.2.0'-or$Profile.runtimeIdentifier-cne'win-x64'-or$Profile.archiveFileName-cne'HerdrOps-0.2.0-win-x64.zip'-or$Profile.packageManifestFileName-cne'package-manifest.json'){throw 'Package profile identity is invalid.'}
    Assert-RendererExactProperties $Profile.sourcePolicy @('cleanRequired') 'Package profile sourcePolicy';Assert-RendererBoolean $Profile.sourcePolicy.cleanRequired 'Package profile cleanRequired';if(-not$Profile.sourcePolicy.cleanRequired){throw 'Package profile must require clean source.'}
    Assert-RendererExactProperties $Profile.approval @('decisionId','approvalReference','approvedUtc','payloadSha256') 'Package profile approval';if($Profile.approval.decisionId-cne$script:RendererPackageDecisionId-or$Profile.approval.approvalReference-cne$script:RendererPackageApprovalReference-or$Profile.approval.approvedUtc-cne$script:RendererPackageDecisionApprovedUtc-or$Profile.approval.payloadSha256-cne$script:RendererPackageDecisionPayloadSha256){throw 'Package profile approval does not equal REC-ALL v2.'}
    Assert-RendererExactProperties $Profile.components @('appRelativePath','coreRelativePath') 'Package profile components';if($Profile.components.appRelativePath-cne'HerdrOps.App.exe'-or$Profile.components.coreRelativePath-cne'HerdrOps.Core.exe'){throw 'Package profile component paths are invalid.'}
    Assert-RendererExactProperties $Profile.referenceHost @('profileId','profileSha256') 'Package profile referenceHost';if($Profile.referenceHost.profileId-cne$script:RendererProfileId-or$Profile.referenceHost.profileSha256-cne$script:RendererProfileSha256){throw 'Package profile reference-host binding is invalid.'}
    Assert-RendererExactProperties $Profile.renderer @('policy','wpfProcessRenderMode','policySha256') 'Package profile renderer';if($Profile.renderer.policy-cne'software-only-process-wide'-or$Profile.renderer.wpfProcessRenderMode-cne'SoftwareOnly'-or$Profile.renderer.policySha256-cne$script:RendererPolicySha256){throw 'Package profile renderer binding is invalid.'}
    Assert-RendererExactProperties $Profile.evidenceBoundary @('evidenceClass','runtimeUse','actualHerdrUsed','runtimeCredit','releaseCredit') 'Package profile evidenceBoundary';Assert-RendererBoolean $Profile.evidenceBoundary.actualHerdrUsed 'Package profile actualHerdrUsed';if($Profile.evidenceBoundary.evidenceClass-cne'PackagedCompatibilityPreparation'-or$Profile.evidenceBoundary.runtimeUse-cne'not-used'-or$Profile.evidenceBoundary.actualHerdrUsed-or$Profile.evidenceBoundary.runtimeCredit-cne'NOT CLAIMED'-or$Profile.evidenceBoundary.releaseCredit-cne'NOT CLAIMED'){throw 'Package profile evidence boundary is invalid.'}
}
function Assert-RendererPackageReceipt { param($Receipt,$Candidate)
    Assert-RendererExactProperties $Receipt @('schemaVersion','profileId','issue','packageVersion','runtimeIdentifier','source','profile','archive','packageManifest','components','referenceHost','renderer','evidenceBoundary') 'Package receipt';Assert-RendererNonnegativeInteger $Receipt.schemaVersion 'Package receipt schemaVersion';Assert-RendererNonnegativeInteger $Receipt.issue 'Package receipt issue';if([long]$Receipt.schemaVersion-ne1-or[long]$Receipt.issue-ne149-or$Receipt.profileId-cne$script:RendererPackageProfileId-or$Receipt.packageVersion-cne'0.2.0'-or$Receipt.runtimeIdentifier-cne'win-x64'){throw 'Package receipt identity is invalid.'}
    Assert-RendererExactProperties $Receipt.source @('commitSha','treeSha') 'Package receipt source';if($Receipt.source.commitSha-cnotmatch'^[0-9a-f]{40}$'-or$Receipt.source.treeSha-cnotmatch'^[0-9a-f]{40}$'-or$Receipt.source.commitSha-cne$Candidate.source.commitSha-or$Receipt.source.treeSha-cne$Candidate.source.treeSha){throw 'Package receipt source does not equal the renderer candidate.'}
    Assert-RendererExactProperties $Receipt.profile @('id','relativePath','bytes','fileSha256','canonicalSha256') 'Package receipt profile';foreach($name in @('id','relativePath','bytes','fileSha256','canonicalSha256')){if($Receipt.profile.$name-cne$Candidate.profile.$name){throw "Package receipt profile field '$name' does not equal the renderer candidate."}}
    Assert-RendererExactProperties $Receipt.archive @('relativePath','fileName','bytes','sha256') 'Package receipt archive';Assert-RendererPositiveInteger $Receipt.archive.bytes 'Package receipt archive bytes';Assert-RendererSha $Receipt.archive.sha256 'Package receipt archive sha256';foreach($name in @('relativePath','fileName','bytes','sha256')){if($Receipt.archive.$name-cne$Candidate.archive.$name){throw "Package receipt archive field '$name' does not equal the renderer candidate."}}
    Assert-RendererExactProperties $Receipt.packageManifest @('fileName','bytes','sha256','contentSha256','fileCount','totalBytes') 'Package receipt packageManifest';Assert-RendererString $Receipt.packageManifest.fileName 'Package receipt manifest fileName';foreach($n in @('bytes','fileCount','totalBytes')){Assert-RendererPositiveInteger $Receipt.packageManifest.$n "Package receipt manifest $n"};Assert-RendererSha $Receipt.packageManifest.sha256 'Package receipt manifest sha256';Assert-RendererSha $Receipt.packageManifest.contentSha256 'Package receipt manifest contentSha256'
    Assert-RendererExactProperties $Receipt.components @('app','core') 'Package receipt components';foreach($name in @('app','core')){Assert-RendererExactProperties $Receipt.components.$name @('relativePath','bytes','sha256') "Package receipt component $name";foreach($field in @('relativePath','bytes','sha256')){if($Receipt.components.$name.$field-cne$Candidate.components.$name.$field){throw "Package receipt component '$name' field '$field' does not equal the renderer candidate."}}}
    Assert-RendererExactProperties $Receipt.referenceHost @('profileId','profileSha256') 'Package receipt referenceHost';if($Receipt.referenceHost.profileId-cne$Candidate.referenceHost.profileId-or$Receipt.referenceHost.profileSha256-cne$Candidate.referenceHost.profileSha256){throw 'Package receipt referenceHost does not equal the renderer candidate.'}
    Assert-RendererExactProperties $Receipt.renderer @('policy','wpfProcessRenderMode') 'Package receipt renderer';if($Receipt.renderer.policy-cne$Candidate.renderer.policy-or$Receipt.renderer.wpfProcessRenderMode-cne$Candidate.renderer.wpfProcessRenderMode){throw 'Package receipt renderer does not equal the renderer candidate.'}
    Assert-RendererExactProperties $Receipt.evidenceBoundary @('evidenceClass','runtimeUse','actualHerdrUsed','runtimeCredit','releaseCredit') 'Package receipt evidenceBoundary';Assert-RendererBoolean $Receipt.evidenceBoundary.actualHerdrUsed 'Package receipt actualHerdrUsed';if($Receipt.evidenceBoundary.evidenceClass-cne'PackagedCompatibilityPreparation'-or$Receipt.evidenceBoundary.runtimeUse-cne'not-used'-or$Receipt.evidenceBoundary.actualHerdrUsed-or$Receipt.evidenceBoundary.runtimeCredit-cne'NOT CLAIMED'-or$Receipt.evidenceBoundary.releaseCredit-cne'NOT CLAIMED'){throw 'Package receipt inflates evidence.'}
}
function Assert-RendererMatrixCases { param([object[]]$Cases,[string[]]$Expected,[string]$Context,[string]$Root,[string]$RepositoryRoot,[switch]$ValidateBindings,[ref]$CommonRunFingerprint,$ExpectedCandidate)
    if([string]::IsNullOrWhiteSpace($Root)){$Root=$script:RendererCurrentEvidenceRoot}
    if([string]::IsNullOrWhiteSpace($RepositoryRoot)){$RepositoryRoot=$script:RendererCurrentRepositoryRoot}
    if($script:RendererCurrentValidateBindings){$ValidateBindings=$true}
    Assert-RendererSet @($Cases|ForEach-Object{$_.id}) $Expected "$Context IDs"
    $matrixRunFingerprint=$null
    foreach($case in $Cases){
        Assert-RendererExactProperties $case @('id','status','evidenceReceipt','notes') "$Context '$($case.id)'"
        Assert-RendererString $case.id "$Context id"
        if([string]$case.status-cnotin@('PASS','FAIL','NOT_OBSERVED')){throw "$Context '$($case.id)' status is invalid."}
        if($case.status-ceq'NOT_OBSERVED'){
            if($null-ne$case.evidenceReceipt-or$null-ne$case.notes){throw "$Context '$($case.id)' NOT_OBSERVED must not claim evidence."}
            continue
        }
        Assert-RendererString $case.notes "$Context '$($case.id)' notes"
        if(-not$ValidateBindings){throw "$Context '$($case.id)' observed status requires production binding validation."}
        $receipt=(Read-RendererEvidenceReceipt $case.evidenceReceipt "$Context '$($case.id)' receipt" $Root $RepositoryRoot).Value
        Assert-RendererExactProperties $receipt @('schemaVersion','caseId','observedUtc','outcome','operator','observer','evidenceBoundary','rawEvidence') "$Context receipt"
        Assert-RendererNonnegativeInteger $receipt.schemaVersion "$Context receipt schemaVersion"
        if([long]$receipt.schemaVersion-ne1-or$receipt.caseId-cne$case.id){throw "$Context '$($case.id)' receipt identity is invalid."}
        Assert-RendererUtc $receipt.observedUtc "$Context '$($case.id)' observedUtc"
        if($receipt.outcome-cnotin@('PASS','FAIL')){throw "$Context '$($case.id)' receipt outcome is invalid."}
        foreach($role in @(@{Value=$receipt.operator;Name='operator';Expected='EvidenceOperator'},@{Value=$receipt.observer;Name='observer';Expected='IndependentAgentReviewer'})){
            Assert-RendererExactProperties $role.Value @('identity','role') "$Context '$($case.id)' $($role.Name)"
            Assert-RendererString $role.Value.identity "$Context '$($case.id)' $($role.Name) identity"
            if($role.Value.role-cne$role.Expected){throw "$Context '$($case.id)' $($role.Name) role is invalid."}
        }
        if($receipt.operator.identity.Trim().Equals($receipt.observer.identity.Trim(),[StringComparison]::OrdinalIgnoreCase)){throw "$Context '$($case.id)' operator and observer identities must be distinct."}
        Assert-RendererExactProperties $receipt.evidenceBoundary @('evidenceClass','release','creditGranted') "$Context '$($case.id)' evidenceBoundary"
        if($receipt.evidenceBoundary.evidenceClass-cnotin@('Static','Synthetic','Contract','AutomatedPackagedRendering')-or$receipt.evidenceBoundary.release-cne'NOT_OBSERVED'){throw "$Context '$($case.id)' receipt inflated its evidence boundary."}
        Assert-RendererBoolean $receipt.evidenceBoundary.creditGranted "$Context '$($case.id)' creditGranted"
        if($receipt.evidenceBoundary.creditGranted){throw "$Context '$($case.id)' receipt cannot grant final credit."}
        Assert-RendererFileBinding $receipt.rawEvidence "$Context '$($case.id)' rawEvidence" $Root -ValidateBindings
        $rawPath=Resolve-RendererBoundPath $Root $receipt.rawEvidence.relativePath "$Context '$($case.id)' rawEvidence"
        $rawStable=Get-RendererStableFileIdentity $Root $rawPath "$Context '$($case.id)' rawEvidence" -IncludeBytes
        $rawJson=(New-Object Text.UTF8Encoding($false,$true)).GetString($rawStable.Content)
        $rawPayload=ConvertFrom-StrictHumanDesignReviewJson -Json $rawJson -Description "$Context '$($case.id)' raw evidence payload"
        if ($PSVersionTable.PSVersion.Major -ge 7 -and (Get-Command ConvertFrom-Json).Parameters.ContainsKey('DateKind')) {
            $rawPayload = $rawJson | ConvertFrom-Json -DateKind String
        }
        $validatedRaw = Assert-RendererMatrixRawPayload -Payload $rawPayload -ExpectedCaseId $case.id -Context "$Context '$($case.id)' raw evidence payload" -RepositoryRoot $RepositoryRoot -EvidenceRoot $Root
        if($validatedRaw.EvidenceClass-ceq'AutomatedPackagedRendering'-and$null-ne$ExpectedCandidate){if($validatedRaw.CandidateCommitSha-cne$ExpectedCandidate.source.commitSha-or$validatedRaw.CandidateTreeSha-cne$ExpectedCandidate.source.treeSha-or$validatedRaw.PackageReceiptCanonicalSha256-cne$ExpectedCandidate.receipt.canonicalSha256-or$validatedRaw.AppExecutableSha256-cne$ExpectedCandidate.components.app.sha256){throw "$Context '$($case.id)' automated collector candidate/package/App binding does not equal the manifest candidate."}}
        if($null-ne$CommonRunFingerprint){
            if($null-eq$CommonRunFingerprint.Value){$CommonRunFingerprint.Value=$validatedRaw.RunFingerprint}elseif([string]$CommonRunFingerprint.Value-cne$validatedRaw.RunFingerprint){throw "$Context '$($case.id)' does not share the exact global 14-case run/session/candidate/package identity."}
        }elseif($null-eq$matrixRunFingerprint){$matrixRunFingerprint=$validatedRaw.RunFingerprint}elseif($matrixRunFingerprint-cne$validatedRaw.RunFingerprint){throw "$Context '$($case.id)' does not share the exact run/session/candidate/package identity."}
        if ($receipt.observedUtc -cne $validatedRaw.ObservedUtc) {
            throw "$Context '$($case.id)' receipt observedUtc '$($receipt.observedUtc)' does not match raw evidence observedUtc '$($validatedRaw.ObservedUtc)'."
        }
        if ($receipt.outcome -cne $validatedRaw.Outcome) {
            throw "$Context '$($case.id)' receipt outcome '$($receipt.outcome)' contradicts raw evidence outcome '$($validatedRaw.Outcome)'."
        }
        if ($receipt.evidenceBoundary.evidenceClass -cne $validatedRaw.EvidenceClass) {
            throw "$Context '$($case.id)' receipt evidenceClass '$($receipt.evidenceBoundary.evidenceClass)' contradicts raw evidence evidenceClass '$($validatedRaw.EvidenceClass)'."
        }
        if($validatedRaw.EvidenceClass-ceq'AutomatedPackagedRendering'-and
            ($receipt.operator.identity-cne$validatedRaw.OperatorIdentity-or$receipt.observer.identity-cne$validatedRaw.ObserverIdentity)){
            throw "$Context '$($case.id)' receipt operator/reviewer identities do not equal the governed automated rendering provenance."
        }
        if($case.status-cne$receipt.outcome){throw "$Context '$($case.id)' status is not recomputed from the bound receipt outcome."}
    }
}
function Get-RendererP95Microseconds { param($Values,[string]$Context)
    $items=@($Values);if($items.Count-ne20){throw "$Context must contain exactly 20 raw observations; missing or extra samples fail closed."};foreach($value in $items){Assert-RendererNonnegativeInteger $value "$Context observation"};$sorted=@($items|Sort-Object {[long]$_});return [long]$sorted[[Math]::Ceiling(0.95*$sorted.Count)-1]
}
function Resolve-RendererHistoricalPackageRoot { param($Value,[string]$Context)
    Assert-RendererString $Value $Context;if(-not[IO.Path]::IsPathRooted([string]$Value)){throw "$Context must be an absolute normalized path."};$normalized=[IO.Path]::GetFullPath([string]$Value).TrimEnd('\','/');if([string]$Value-cne$normalized){throw "$Context must be an absolute normalized path."};if(Test-Path -LiteralPath $normalized){if(-not(Test-Path -LiteralPath $normalized -PathType Container)){throw "$Context must identify a package directory."};Assert-RendererNonReparsePath $normalized $normalized $Context};$normalized
}
function Assert-RendererPerformanceReceipt {
    param($Binding,[string]$Root,[string]$RepositoryRoot,$Limits,$ExpectedProvenance,$ExpectedCandidate,$ExpectedSession,$ExpectedPackageReceipt,[string]$ExpectedAcquisitionPackageRoot,[string]$TestAfterReceiptOpenSignalPath)
    $hasExpectedCandidate = $null -ne $ExpectedCandidate
    $hasExpectedSession = $null -ne $ExpectedSession
    if ($hasExpectedCandidate -ne $hasExpectedSession) { throw 'Performance receipt validation requires both expected candidate and session bindings.' }
    if ($null -ne $ExpectedProvenance -and $hasExpectedCandidate) { throw 'Performance receipt validation accepts either exact expected provenance or expected candidate/session bindings, not both.' }
    $receiptRead=Read-RendererEvidenceReceipt $Binding 'Performance evidence receipt' $Root $RepositoryRoot -KeepOpen
    $rawSourceRead=$null
    $telemetryRead=$null
    $commitRead=$null
    try {
    if (-not [string]::IsNullOrWhiteSpace($TestAfterReceiptOpenSignalPath)) {
        if (Test-Path -LiteralPath $TestAfterReceiptOpenSignalPath) { throw 'Performance receipt test synchronization signal path already exists.' }
        New-Item -ItemType File -Path $TestAfterReceiptOpenSignalPath | Out-Null
        while (Test-Path -LiteralPath $TestAfterReceiptOpenSignalPath) { Start-Sleep -Milliseconds 10 }
    }
    $receipt=$receiptRead.Value
    Assert-RendererExactProperties $receipt @('schemaVersion','provenance','rawSource','orders','aggregateStatus') 'Performance receipt'
    Assert-RendererNonnegativeInteger $receipt.schemaVersion 'Performance receipt schemaVersion'
    if([long]$receipt.schemaVersion-ne4){throw 'Only performance receipt schemaVersion 4 can satisfy the v0.2 release-first contract.'}
    Assert-RendererPerformanceProvenance $receipt.provenance 'Performance receipt provenance'
    Assert-RendererPerformanceJsonBinding $receipt.rawSource 'Performance raw-source binding'
    if ($receipt.rawSource.relativePath -ceq $Binding.relativePath) { throw 'Performance raw-source binding must not point to the receipt itself.' }
    $rawSourceRead=Read-RendererEvidenceReceipt $receipt.rawSource 'Performance raw-source evidence' $Root $RepositoryRoot -KeepOpen
    $rawSource=$rawSourceRead.Value
    Assert-RendererExactProperties $rawSource @('orders') 'Performance raw-source document'
    if ($hasExpectedCandidate) {
        $ExpectedProvenance = New-RendererPerformanceProvenance $ExpectedCandidate $ExpectedSession $receipt.provenance.runNonce $receipt.provenance.performanceTelemetryBinding $receipt.provenance.performanceTransactionCommit
    }
    if ($null -eq $ExpectedProvenance) { throw 'Performance receipt validation requires expected candidate provenance.' }
    Assert-RendererPerformanceProvenance $ExpectedProvenance 'Expected performance provenance'
    $expectedProvenanceJson=ConvertTo-RendererCanonicalJson $ExpectedProvenance $RepositoryRoot
    $actualProvenanceJson=ConvertTo-RendererCanonicalJson $receipt.provenance $RepositoryRoot
    if ($actualProvenanceJson -cne $expectedProvenanceJson) { throw 'Performance receipt provenance does not equal the exact candidate binding.' }

    if($null-eq$ExpectedPackageReceipt){throw 'Performance receipt validation requires the independently held package receipt.'}
    Assert-RendererExactProperties $ExpectedPackageReceipt.packageManifest @('fileName','bytes','sha256','contentSha256','fileCount','totalBytes') 'Expected package receipt manifest'
    Assert-RendererSha $ExpectedPackageReceipt.packageManifest.sha256 'Expected package receipt manifest sha256'
    $telemetryRead=Read-RendererEvidenceReceipt $receipt.provenance.performanceTelemetryBinding 'Performance telemetry sidecar' $Root $RepositoryRoot -KeepOpen
    $commitRead=Read-RendererEvidenceReceipt $receipt.provenance.performanceTransactionCommit 'Performance transaction commit' $Root $RepositoryRoot -KeepOpen
    $commit=$commitRead.Value
    Assert-RendererExactProperties $commit @('schemaVersion','kind','runNonce','raw','binding','creditGranted') 'Performance transaction commit'
    Assert-RendererExactProperties $commit.raw @('fileName','bytes','sha256') 'Performance transaction commit raw'
    Assert-RendererExactProperties $commit.binding @('fileName','bytes','sha256') 'Performance transaction commit sidecar'
    Assert-RendererBoolean $commit.creditGranted 'Performance transaction commit creditGranted'
    foreach($item in @(@($commit.raw,'raw'),@($commit.binding,'sidecar'))){Assert-RendererString $item[0].fileName "Performance transaction commit $($item[1]) fileName";Assert-RendererPositiveInteger $item[0].bytes "Performance transaction commit $($item[1]) bytes";Assert-RendererSha $item[0].sha256 "Performance transaction commit $($item[1]) sha256"}
    $rawPath=Resolve-RendererBoundPath $Root $receipt.rawSource.relativePath 'Performance raw-source path'
    $telemetryPath=Resolve-RendererBoundPath $Root $receipt.provenance.performanceTelemetryBinding.relativePath 'Performance telemetry sidecar path'
    if([long]$commit.schemaVersion-ne1-or[string]$commit.kind-cne'issue10-performance-transaction-commit'-or[string]$commit.runNonce-cne[string]$receipt.provenance.runNonce-or[bool]$commit.creditGranted-or[string]$commit.raw.fileName-cne[IO.Path]::GetFileName($rawPath)-or[long]$commit.raw.bytes-ne[long]$rawSourceRead.Stable.Bytes-or[string]$commit.raw.sha256-cne[string]$rawSourceRead.Stable.Sha256-or[string]$commit.binding.fileName-cne[IO.Path]::GetFileName($telemetryPath)-or[long]$commit.binding.bytes-ne[long]$telemetryRead.Stable.Bytes-or[string]$commit.binding.sha256-cne[string]$telemetryRead.Stable.Sha256){throw 'Performance transaction commit does not bind the held raw and telemetry sidecar.'}

    $sidecar=$telemetryRead.Value
    Assert-RendererExactProperties $sidecar @('schemaVersion','evidenceClassification','runNonce','source','session','package','rawSource','acquisitions','evidenceBoundary') 'Performance telemetry sidecar'
    Assert-RendererExactProperties $sidecar.source @('commitSha','treeSha') 'Performance telemetry sidecar source'
    Assert-RendererExactProperties $sidecar.session @('kind','name','sessionId','transport','elevated','userScope') 'Performance telemetry sidecar session'
    Assert-RendererNonnegativeInteger $sidecar.session.sessionId 'Performance telemetry sidecar sessionId'
    Assert-RendererBoolean $sidecar.session.elevated 'Performance telemetry sidecar elevated'
    Assert-RendererExactProperties $sidecar.package @('identitySha256','identityFileSha256','profileFileSha256','archiveSha256','manifestSha256','appSha256','coreSha256') 'Performance telemetry sidecar package'
    Assert-RendererPerformanceJsonBinding $sidecar.rawSource 'Performance telemetry sidecar rawSource'
    Assert-RendererExactProperties $sidecar.evidenceBoundary @('actualHerdrRuntime','release','creditGranted') 'Performance telemetry sidecar evidenceBoundary'
    Assert-RendererBoolean $sidecar.evidenceBoundary.creditGranted 'Performance telemetry sidecar creditGranted'
    foreach($name in @('identitySha256','identityFileSha256','profileFileSha256','archiveSha256','manifestSha256','appSha256','coreSha256')){Assert-RendererSha $sidecar.package.$name "Performance telemetry sidecar package $name"}
    $expectedManifestSha=[string]$ExpectedPackageReceipt.packageManifest.sha256
    if([long]$sidecar.schemaVersion-ne3-or[string]$sidecar.evidenceClassification-cne'PackagedCompatibilityPerformanceTelemetryBinding-NoRuntimeCredit'-or[string]$sidecar.runNonce-cne[string]$receipt.provenance.runNonce-or[string]$sidecar.source.commitSha-cne[string]$receipt.provenance.candidate.commitSha-or[string]$sidecar.source.treeSha-cne[string]$receipt.provenance.candidate.treeSha-or[string]$sidecar.session.kind-cne'LocalConsole'-or[string]::IsNullOrWhiteSpace([string]$sidecar.session.name)-or[string]$sidecar.session.transport-cne'Physical'-or[bool]$sidecar.session.elevated-or[string]$sidecar.session.userScope-cne'SingleUser'-or[string]$sidecar.package.identitySha256-cne[string]$receipt.provenance.package.receipt.canonicalSha256-or[string]$sidecar.package.identityFileSha256-cne[string]$receipt.provenance.package.receipt.fileSha256-or[string]$sidecar.package.profileFileSha256-cne[string]$receipt.provenance.profile.fileSha256-or[string]$sidecar.package.archiveSha256-cne[string]$receipt.provenance.package.archive.sha256-or[string]$sidecar.package.manifestSha256-cne$expectedManifestSha-or[string]$sidecar.package.appSha256-cne[string]$receipt.provenance.package.components.app.sha256-or[string]$sidecar.package.coreSha256-cne[string]$receipt.provenance.package.components.core.sha256-or[string]$sidecar.rawSource.relativePath-cne[string]$receipt.rawSource.relativePath-or[long]$sidecar.rawSource.bytes-ne[long]$rawSourceRead.Stable.Bytes-or[string]$sidecar.rawSource.fileSha256-cne[string]$rawSourceRead.Stable.Sha256-or[string]$sidecar.rawSource.canonicalSha256-cne[string]$receipt.rawSource.canonicalSha256-or[string]$sidecar.evidenceBoundary.actualHerdrRuntime-cne'NOT_OBSERVED'-or[string]$sidecar.evidenceBoundary.release-cne'NOT_OBSERVED'-or[bool]$sidecar.evidenceBoundary.creditGranted){throw 'Performance telemetry sidecar source/package/session/raw binding is not exact.'}
    $acquisitions=@($sidecar.acquisitions)
    if($acquisitions.Count-ne24){throw 'Performance telemetry sidecar must contain exactly 24 acquisitions.'}
    $packageRootRelative=[string]$receipt.provenance.package.packageRootRelativePath
    $componentPaths=@{}
    foreach($componentName in @('app','core')){$componentRelative=[string]$receipt.provenance.package.components.$componentName.relativePath;$packagePrefix=$packageRootRelative.TrimEnd('/','\')+'/';$hasPrefix=$componentRelative.Replace('\','/').StartsWith($packagePrefix,[StringComparison]::OrdinalIgnoreCase);if([string]::IsNullOrWhiteSpace($ExpectedAcquisitionPackageRoot)){$combinedRelative=if($hasPrefix){$componentRelative}else{Join-Path $packageRootRelative $componentRelative};$componentPaths[$componentName]=Resolve-RendererBoundPath $Root $combinedRelative "Performance telemetry $componentName package path"}else{$historicalRoot=Resolve-RendererHistoricalPackageRoot $ExpectedAcquisitionPackageRoot 'Historical performance acquisition package root';$leafRelative=if($hasPrefix){$componentRelative.Replace('\','/').Substring($packagePrefix.Length)}else{$componentRelative};$componentPaths[$componentName]=[IO.Path]::GetFullPath((Join-Path $historicalRoot $leafRelative))}}
    $appIdentities=@{};$coreIdentity=$null;$serverIdentity=$null;$lastAcquisitionUtc=$null
    for($acquisitionIndex=0;$acquisitionIndex-lt24;$acquisitionIndex++){
        $item=$acquisitions[$acquisitionIndex]
        Assert-RendererExactProperties $item @('sequenceNumber','order','isWarmup','repetitionOrdinal','semanticMode','requestedMode','appProcessId','appStartUtc','appPath','appSha256','coreProcessId','coreStartUtc','corePath','coreSha256','serverProcessId','serverStartUtc','serverPath','serverSha256','nativeProcessRenderMode','nativeTier','preFirstHwndProof','observedUtc','boundary') "Performance telemetry acquisition $acquisitionIndex"
        foreach($pidName in @('appProcessId','coreProcessId','serverProcessId')){Assert-RendererPositiveInteger $item.$pidName "Performance telemetry acquisition $acquisitionIndex $pidName"}
        Assert-RendererNonnegativeInteger $item.nativeTier "Performance telemetry acquisition $acquisitionIndex nativeTier"
        foreach($shaName in @('appSha256','coreSha256','serverSha256')){Assert-RendererSha $item.$shaName "Performance telemetry acquisition $acquisitionIndex $shaName"}
        foreach($pathName in @('appPath','corePath','serverPath')){Assert-RendererString $item.$pathName "Performance telemetry acquisition $acquisitionIndex $pathName"}
        Assert-RendererBoolean $item.isWarmup "Performance telemetry acquisition $acquisitionIndex isWarmup";Assert-RendererBoolean $item.preFirstHwndProof "Performance telemetry acquisition $acquisitionIndex preFirstHwndProof"
        foreach($timeName in @('appStartUtc','coreStartUtc','serverStartUtc','observedUtc')){Assert-RendererUtc $item.$timeName "Performance telemetry acquisition $acquisitionIndex $timeName"}
        $appStart=[DateTimeOffset]$item.appStartUtc;$coreStart=[DateTimeOffset]$item.coreStartUtc;$serverStart=[DateTimeOffset]$item.serverStartUtc;$observed=[DateTimeOffset]$item.observedUtc
        if($appStart-ge$observed-or$coreStart-ge$observed-or$serverStart-ge$observed-or($null-ne$lastAcquisitionUtc-and$observed-le$lastAcquisitionUtc)){throw "Performance telemetry acquisition $acquisitionIndex process/observation chronology is invalid."};$lastAcquisitionUtc=$observed
        $order=if($acquisitionIndex-lt12){'AB'}else{'BA'};$within=$acquisitionIndex%12;$warmup=$within-lt2;$repetition=if($warmup){0}else{[int][Math]::Floor(($within-2)/2)};$mode=if($order-ceq'AB'){if($within%2-eq0){'a'}else{'b'}}else{if($within%2-eq0){'b'}else{'a'}};$requested=if($mode-ceq'a'){'Hardware'}else{'SoftwareOnly'};$native=if($mode-ceq'a'){'Default'}else{'SoftwareOnly'}
        if([int]$item.sequenceNumber-ne$acquisitionIndex-or[string]$item.order-cne$order-or[bool]$item.isWarmup-ne$warmup-or[int]$item.repetitionOrdinal-ne$repetition-or[string]$item.semanticMode-cne$mode-or[string]$item.requestedMode-cne$requested-or[string]$item.nativeProcessRenderMode-cne$native-or($mode-ceq'a'-and[int]$item.nativeTier-le0)-or($mode-ceq'b'-and[int]$item.nativeTier-ne0)-or-not[bool]$item.preFirstHwndProof-or-not[IO.Path]::GetFullPath([string]$item.appPath).Equals([string]$componentPaths.app,[StringComparison]::OrdinalIgnoreCase)-or-not[IO.Path]::GetFullPath([string]$item.corePath).Equals([string]$componentPaths.core,[StringComparison]::OrdinalIgnoreCase)-or[string]$item.appSha256-cne[string]$receipt.provenance.package.components.app.sha256-or[string]$item.coreSha256-cne[string]$receipt.provenance.package.components.core.sha256-or[string]$item.boundary-cne'PackagedCompatibilityPerformance-NativeTierComparator-NoPerFrameGpuOrRuntimeCredit'){throw "Performance telemetry acquisition $acquisitionIndex is not the governed comparator sequence."}
        $appKey=([string][int]$item.appProcessId)+'|'+$appStart.ToString('O');if($appIdentities.ContainsKey($appKey)){throw "Performance telemetry acquisition $acquisitionIndex reused an App PID/start identity."};$appIdentities[$appKey]=$true
        $thisCore=([string][int]$item.coreProcessId)+'|'+$coreStart.ToString('O')+'|'+[IO.Path]::GetFullPath([string]$item.corePath)+'|'+[string]$item.coreSha256;if($null-eq$coreIdentity){$coreIdentity=$thisCore}elseif($coreIdentity-cne$thisCore){throw 'Performance telemetry Core identity changed.'}
        $thisServer=([string][int]$item.serverProcessId)+'|'+$serverStart.ToString('O')+'|'+[IO.Path]::GetFullPath([string]$item.serverPath)+'|'+[string]$item.serverSha256;if($null-eq$serverIdentity){$serverIdentity=$thisServer}elseif($serverIdentity-cne$thisServer){throw 'Performance telemetry server identity changed.'}
    }
    $measurementObject=[pscustomobject][ordered]@{orders=$receipt.orders}
    if ((ConvertTo-RendererCanonicalJson $rawSource $RepositoryRoot) -cne (ConvertTo-RendererCanonicalJson $measurementObject $RepositoryRoot)) {
        throw 'Performance receipt raw measurements do not equal the held raw-source document.'
    }

    $passed=$true
    $orders=@($receipt.orders)
    if ($orders.Count -ne 2) { throw 'Performance receipt must contain exact AB and BA orders.' }
    for ($oi=0; $oi -lt 2; $oi++) {
        $order=$orders[$oi]
        Assert-RendererExactProperties $order @('order','warmup','repetitions') "Performance order $oi"
        $expectedOrder=@('AB','BA')[$oi]
        if ($order.order -cne $expectedOrder) { throw "Performance order $oi is not $expectedOrder." }
        $warmups=@($order.warmup)
        if ($warmups.Count -ne 1) { throw "Performance order $expectedOrder must contain exactly one warmup repetition." }
        Assert-RendererPerformanceRepetitionProperties $warmups[0] 0 "Performance $expectedOrder warmup" -Warmup
        $reps=@($order.repetitions)
        if ($reps.Count -ne 5) { throw "Performance order $expectedOrder must contain five measured raw repetitions." }
        for ($ri=0; $ri -lt 5; $ri++) {
            $rep=$reps[$ri]
            Assert-RendererPerformanceRepetitionProperties $rep $ri "Performance $expectedOrder repetition $ri"
            $derived=@{}
            foreach ($modeName in @('a','b')) {
                $sample=$rep.$modeName
                $latencyP95=Get-RendererP95Microseconds $sample.latencyMicroseconds "Performance $expectedOrder $modeName latency"
                $stallP95=Get-RendererP95Microseconds $sample.uiStallMicroseconds "Performance $expectedOrder $modeName UI stall"
                $stallMaximum=[long](@($sample.uiStallMicroseconds|Sort-Object {[long]$_})[-1])
                $derived[$modeName]=[pscustomobject]@{
                    Cpu=[double]$sample.cpuBasisPoints/100
                    WorkingSet=[long]$sample.workingSetMaximumBytes
                    LatencyP95=[double]$latencyP95/1000
                    StallP95=[double]$stallP95/1000
                    StallMaximum=[double]$stallMaximum/1000
                }
                if ($derived[$modeName].Cpu -gt [double]$Limits.cpuMaximumPercent -or $derived[$modeName].WorkingSet -gt [long]$Limits.workingSetMaximumBytes) { $passed=$false }
            }
            $a=$derived.a;$b=$derived.b
            $cpuDelta=$b.Cpu-$a.Cpu
            $cpuPercent=if($a.Cpu -gt 0){100*$cpuDelta/$a.Cpu}elseif($b.Cpu -eq 0){0}else{[double]::PositiveInfinity}
            $latencyPercent=if($a.LatencyP95 -gt 0){100*($b.LatencyP95-$a.LatencyP95)/$a.LatencyP95}elseif($b.LatencyP95 -eq 0){0}else{[double]::PositiveInfinity}
            if ($cpuDelta -gt [double]$Limits.cpuRegressionMaximumPercentagePoints -or $cpuPercent -gt [double]$Limits.cpuRegressionMaximumPercent -or $b.LatencyP95 -gt [double]$Limits.eventToWpfP95Milliseconds -or $latencyPercent -gt [double]$Limits.latencyRegressionMaximumPercent -or $b.StallP95 -gt [double]$Limits.uiStallP95Milliseconds -or $b.StallMaximum -gt [double]$Limits.uiStallMaximumMilliseconds) { $passed=$false }
        }
    }

    $computed=if($passed){'PASS'}else{'FAIL'}
    if ($receipt.aggregateStatus -cne $computed) { throw 'Performance receipt aggregateStatus is not recomputed from the raw AB/BA samples.' }
    foreach($heldEntry in @(@((Resolve-RendererBoundPath $Root $Binding.relativePath 'Performance receipt path'),$receiptRead.Stable,'Performance evidence receipt'),@($rawPath,$rawSourceRead.Stable,'Performance raw-source evidence'),@($telemetryPath,$telemetryRead.Stable,'Performance telemetry sidecar'),@((Resolve-RendererBoundPath $Root $receipt.provenance.performanceTransactionCommit.relativePath 'Performance transaction commit path'),$commitRead.Stable,'Performance transaction commit'))){Assert-RendererStableFileLease $heldEntry[1] $Root $heldEntry[0] $heldEntry[2]}
    return $computed
    } finally {
        if($null-ne$commitRead-and$null-ne$commitRead.Stable.Stream){$commitRead.Stable.Stream.Dispose()}
        if($null-ne$telemetryRead-and$null-ne$telemetryRead.Stable.Stream){$telemetryRead.Stable.Stream.Dispose()}
        if($null-ne$rawSourceRead-and$null-ne$rawSourceRead.Stable.Stream){$rawSourceRead.Stable.Stream.Dispose()}
        if($null-ne$receiptRead-and$null-ne$receiptRead.Stable.Stream){$receiptRead.Stable.Stream.Dispose()}
    }
}
function Assert-RendererPerformancePipelineCommit {
    param($Binding,[string]$Root,[string]$RepositoryRoot,$PerformanceReceiptBinding,$Candidate,$Limits,$ExpectedSession,$ExpectedPackageReceipt)
    $commitRead=$null;$receiptRead=$null;$leafReads=@()
    try {
        $commitRead=Read-RendererEvidenceReceipt $Binding 'Performance pipeline transaction commit' $Root $RepositoryRoot -KeepOpen
        $receiptRead=Read-RendererEvidenceReceipt $PerformanceReceiptBinding 'Pipeline-selected performance receipt' $Root $RepositoryRoot -KeepOpen
        $commit=$commitRead.Value;$receipt=$receiptRead.Value
        Assert-RendererExactProperties $commit @('schemaVersion','kind','runNonce','capturePackageRootPath','source','files','evidenceBoundary') 'Performance pipeline transaction commit'
        Assert-RendererNonnegativeInteger $commit.schemaVersion 'Performance pipeline schemaVersion'
        Assert-RendererExactProperties $commit.source @('commitSha','treeSha') 'Performance pipeline source'
        Assert-RendererExactProperties $commit.files @('raw','binding','performanceCommit','performanceReceipt') 'Performance pipeline files'
        Assert-RendererExactProperties $commit.evidenceBoundary @('actualHerdrRuntime','release','creditGranted') 'Performance pipeline evidenceBoundary'
        Assert-RendererBoolean $commit.evidenceBoundary.creditGranted 'Performance pipeline creditGranted'
        $actualPackageRoot=Resolve-RendererHistoricalPackageRoot $commit.capturePackageRootPath 'Performance pipeline capture package root'
        if([long]$commit.schemaVersion-ne4-or$commit.kind-cne'issue149-performance-pipeline-commit'-or$commit.runNonce-cnotmatch'^[0-9a-f]{32}$'-or$commit.runNonce-cne$receipt.provenance.runNonce-or$commit.source.commitSha-cne$Candidate.source.commitSha-or$commit.source.treeSha-cne$Candidate.source.treeSha-or$commit.evidenceBoundary.actualHerdrRuntime-cne'NOT_OBSERVED'-or$commit.evidenceBoundary.release-cne'NOT_OBSERVED'-or[bool]$commit.evidenceBoundary.creditGranted){throw 'Performance pipeline commit does not bind the exact candidate/source/package/run or preserve no-credit boundaries.'}
        $computed=Assert-RendererPerformanceReceipt $PerformanceReceiptBinding $Root $RepositoryRoot $Limits -ExpectedCandidate $Candidate -ExpectedSession $ExpectedSession -ExpectedPackageReceipt $ExpectedPackageReceipt -ExpectedAcquisitionPackageRoot $actualPackageRoot
        $expected=[ordered]@{raw=$receipt.rawSource;binding=$receipt.provenance.performanceTelemetryBinding;performanceCommit=$receipt.provenance.performanceTransactionCommit;performanceReceipt=$PerformanceReceiptBinding}
        $paths=@([string]$Binding.relativePath)
        foreach($name in $expected.Keys){
            $actual=$commit.files.$name;$bound=$expected[$name]
            Assert-RendererExactProperties $actual @('relativePath','bytes','sha256') "Performance pipeline $name"
            Assert-RendererRelativePath $actual.relativePath "Performance pipeline $name path";Assert-RendererPositiveInteger $actual.bytes "Performance pipeline $name bytes";Assert-RendererSha $actual.sha256 "Performance pipeline $name SHA"
            if($actual.relativePath-cne$bound.relativePath-or[long]$actual.bytes-ne[long]$bound.bytes-or$actual.sha256-cne$bound.fileSha256){throw "Performance pipeline '$name' does not bind the exact selected receipt transaction leaf."}
            $leafPath=Resolve-RendererBoundPath $Root $actual.relativePath "Performance pipeline $name leaf"
            $leaf=Get-RendererStableFileIdentity $Root $leafPath "Performance pipeline $name leaf" -IncludeBytes -KeepOpen
            $leafReads+=,[pscustomobject]@{Path=$leafPath;Stable=$leaf}
            if($leaf.Bytes-ne[long]$actual.bytes-or$leaf.Sha256-cne$actual.sha256){throw "Performance pipeline '$name' held leaf changed."}
            $paths+=[string]$actual.relativePath
        }
        if(@($paths|Select-Object -Unique).Count-ne5){throw 'Performance pipeline commit and four transaction leaves must use distinct paths.'}
        foreach($leaf in $leafReads){Assert-RendererStableFileLease $leaf.Stable $Root $leaf.Path 'Performance pipeline held leaf'}
        Assert-RendererStableFileLease $receiptRead.Stable $Root (Resolve-RendererBoundPath $Root $PerformanceReceiptBinding.relativePath 'Pipeline-selected performance receipt path') 'Pipeline-selected performance receipt'
        Assert-RendererStableFileLease $commitRead.Stable $Root (Resolve-RendererBoundPath $Root $Binding.relativePath 'Performance pipeline commit path') 'Performance pipeline transaction commit'
        $computed
    } finally {
        foreach($leaf in $leafReads){if($null-ne$leaf.Stable.Stream){$leaf.Stable.Stream.Dispose()}}
        if($null-ne$receiptRead-and$null-ne$receiptRead.Stable.Stream){$receiptRead.Stable.Stream.Dispose()}
        if($null-ne$commitRead-and$null-ne$commitRead.Stable.Stream){$commitRead.Stable.Stream.Dispose()}
    }
}
function Get-RendererBgraPixels { param($Frame)
    $converted=New-Object Windows.Media.Imaging.FormatConvertedBitmap($Frame,[Windows.Media.PixelFormats]::Bgra32,$null,0);$stride=$converted.PixelWidth*4;$pixels=New-Object byte[] ($stride*$converted.PixelHeight);$converted.CopyPixels($pixels,$stride,0);[pscustomobject]@{Width=$converted.PixelWidth;Height=$converted.PixelHeight;Pixels=$pixels}
}
function Compare-RendererPixels { param($Capture,$Reference,[object[]]$Masks,[string]$CaptureKey)
    $a=Get-RendererBgraPixels $Capture.Frame;$b=Get-RendererBgraPixels $Reference.Frame;if($a.Width-ne$b.Width-or$a.Height-ne$b.Height){throw "Comparison '$CaptureKey' capture/reference dimensions differ."};$applicableMasks=@($Masks|Where-Object{$_.captureKeys-ccontains$CaptureKey});if($Capture.Sha256-ceq$Reference.Sha256-and$applicableMasks.Count-eq0){return [pscustomobject]@{DifferentPixels=[long]0;DifferentPixelPercent=[double]0;MaximumChannelDelta=[int]0;NonmaskedDifferenceCount=[long]0}};$masked=New-Object bool[] ($a.Width*$a.Height);foreach($mask in $applicableMasks){$m=Get-RendererBgraPixels $mask.Frame;if($m.Width-ne$a.Width-or$m.Height-ne$a.Height){throw "Comparison '$CaptureKey' mask dimensions differ."};for($p=0;$p-lt$masked.Length;$p++){if($m.Pixels[$p*4+3]-gt0-or$m.Pixels[$p*4]-gt0-or$m.Pixels[$p*4+1]-gt0-or$m.Pixels[$p*4+2]-gt0){$masked[$p]=$true}}};$maskCount=@($masked|Where-Object{$_}).Count;if($maskCount-ge$masked.Length){throw "Comparison '$CaptureKey' mask cannot cover the full frame."};for($y=0;$y-lt$a.Height-1;$y++){for($x=0;$x-lt$a.Width-1;$x++){$p=$y*$a.Width+$x;if($masked[$p]-and$masked[$p+1]-and$masked[$p+$a.Width]-and$masked[$p+$a.Width+1]){throw "Comparison '$CaptureKey' mask exceeds the approved one-pixel anti-aliasing geometry."}}};$different=0;$nonmasked=0;$maximum=0;$actualDifferences=New-Object bool[] $masked.Length;for($p=0;$p-lt$masked.Length;$p++){$delta=0;for($c=0;$c-lt4;$c++){$d=[Math]::Abs([int]$a.Pixels[$p*4+$c]-[int]$b.Pixels[$p*4+$c]);if($d-gt$delta){$delta=$d}};if($delta-gt0){$different++;$actualDifferences[$p]=$true;if($delta-gt$maximum){$maximum=$delta}};if(-not$masked[$p]-and$delta-gt0){$nonmasked++}};for($p=0;$p-lt$masked.Length;$p++){if(-not$masked[$p]){continue};$x=$p%$a.Width;$y=[Math]::Floor($p/$a.Width);$near=$false;for($dy=-1;$dy-le1-and-not$near;$dy++){for($dx=-1;$dx-le1;$dx++){$nx=$x+$dx;$ny=$y+$dy;if($nx-ge0-and$ny-ge0-and$nx-lt$a.Width-and$ny-lt$a.Height-and$actualDifferences[$ny*$a.Width+$nx]){$near=$true;break}}};if(-not$near){throw "Comparison '$CaptureKey' mask pixel is outside the approved one-pixel difference neighborhood."}};[pscustomobject]@{DifferentPixels=[long]$different;DifferentPixelPercent=([double]$different*100/$masked.Length);MaximumChannelDelta=[int]$maximum;NonmaskedDifferenceCount=[long]$nonmasked}
}

function Test-RendererCandidateBindings { param($Candidate,[string]$Root,[string]$RepositoryRoot)
    $git=Get-RendererGitIdentity $RepositoryRoot;if($git.CommitSha-cne$Candidate.source.commitSha-or$git.TreeSha-cne$Candidate.source.treeSha){throw 'Candidate source does not equal the exact repository HEAD commit/tree.'}
    $repoRoot=[IO.Path]::GetFullPath($RepositoryRoot);$repoProfilePath=Join-Path $repoRoot 'tools\packaging\v0.2\package-identity-profile.json';$repoProfile=Read-RendererPackageProfile $repoProfilePath;$repoProfileIdentity=Get-RendererPackageProfileIdentity $repoProfilePath $repoProfile $repoRoot;if($Candidate.profile.relativePath-cne$repoProfileIdentity.RelativePath-or$repoProfileIdentity.Bytes-ne[long]$Candidate.profile.bytes-or$repoProfileIdentity.FileSha256-cne$Candidate.profile.fileSha256-or$repoProfileIdentity.CanonicalSha256-cne$Candidate.profile.canonicalSha256){throw 'Candidate package profile does not equal the exact profile in the bound repository.'};Assert-RendererPackageProfile $repoProfile
    $receiptPath=Resolve-RendererBoundPath $Root $Candidate.receipt.relativePath 'Candidate package receipt path';$receiptRaw=Get-RendererStableFileIdentity $Root $receiptPath 'Candidate package receipt' -IncludeBytes;if($receiptRaw.Bytes-ne[long]$Candidate.receipt.bytes-or$receiptRaw.Sha256-cne$Candidate.receipt.fileSha256){throw 'Candidate package receipt raw file binding failed.'};$receipt=Read-RendererCanonicalPackageReceipt $receiptPath $repoRoot;if($receipt.ReceiptSha256-cne$Candidate.receipt.canonicalSha256){throw 'Candidate package receipt canonical SHA-256 mismatch.'};Assert-RendererPackageReceipt $receipt.Identity $Candidate
    $archivePath=Resolve-RendererBoundPath $Root $Candidate.archive.relativePath 'Candidate archive path';$packageRoot=Resolve-RendererBoundPath $Root $Candidate.packageRootRelativePath 'Candidate package root';if(-not(Test-Path -LiteralPath $packageRoot -PathType Container)){throw 'Candidate package root is missing.'}
    $validated=Assert-RendererCommittedPackageIdentity $receipt.Identity $repoProfile $repoRoot $archivePath $packageRoot $repoProfilePath $receipt.ReceiptSha256 $receipt.CanonicalJson
    $expected=[ordered]@{ReceiptSha256=$Candidate.receipt.canonicalSha256;SourceCommit=$Candidate.source.commitSha;SourceTree=$Candidate.source.treeSha;PreparationProfileFileSha256=$Candidate.profile.fileSha256;PreparationProfileCanonicalSha256=$Candidate.profile.canonicalSha256;ArchiveSha256=$Candidate.archive.sha256;AppSha256=$Candidate.components.app.sha256;CoreSha256=$Candidate.components.core.sha256;ReferenceHostProfileSha256=$Candidate.referenceHost.profileSha256;RendererPolicySha256=$script:RendererPolicySha256};foreach($name in $expected.Keys){if($validated.$name-cne$expected[$name]){throw "Committed package validator output '$name' does not equal the renderer candidate."}};if($validated.ProfileId-cne$Candidate.profile.id-or$validated.EvidenceClass-cne'Static/PackagedCompatibilityPreparation'-or$validated.Runtime-cne'NOT OBSERVED'-or$validated.Release-cne'NOT CLAIMED'){throw 'Committed package validator output classification/identity is invalid.'}
    return [pscustomobject][ordered]@{CommitSha=$git.CommitSha;TreeSha=$git.TreeSha;PackageReceipt=$receipt.Identity}
}

function Test-RendererCompatibilityManifest {
    [CmdletBinding()]param([Parameter(Mandatory=$true)][string]$ManifestPath,[string]$EvidenceRoot,[string]$RepositoryRoot,[switch]$ValidateBindings)
    $full=[IO.Path]::GetFullPath($ManifestPath)
    if (-not (Test-Path -LiteralPath $full -PathType Leaf)) { throw "Renderer compatibility manifest was not found: $full" }
    if([string]::IsNullOrWhiteSpace($EvidenceRoot)){$EvidenceRoot=Split-Path -Parent $full};$root=[IO.Path]::GetFullPath($EvidenceRoot)
    $script:RendererCurrentEvidenceRoot=$root;$script:RendererCurrentRepositoryRoot=$RepositoryRoot;$script:RendererCurrentValidateBindings=[bool]$ValidateBindings
    Assert-RendererNonReparsePath $root $full 'Renderer compatibility manifest'
    $manifestIdentity=Get-RendererStableFileIdentity $root $full 'Renderer compatibility manifest' -IncludeBytes
    $manifestBytes=$manifestIdentity.Content
    if ($manifestBytes.Length -eq 0 -or $manifestBytes.Length -gt $script:RendererMaximumManifestBytes) { throw "Renderer compatibility manifest must contain 1..$script:RendererMaximumManifestBytes UTF-8 bytes." }
    if ($manifestBytes.Length -ge 3 -and $manifestBytes[0] -eq 0xEF -and $manifestBytes[1] -eq 0xBB -and $manifestBytes[2] -eq 0xBF) { throw 'Renderer compatibility manifest must be UTF-8 without a BOM.' }
    $json=(New-Object Text.UTF8Encoding($false,$true)).GetString($manifestBytes)
    $manifest=ConvertFrom-StrictHumanDesignReviewJson -Json $json -Description "Renderer compatibility manifest '$full'"
    if ($PSVersionTable.PSVersion.Major -ge 7 -and (Get-Command ConvertFrom-Json).Parameters.ContainsKey('DateKind')) {
        $manifest = $json | ConvertFrom-Json -DateKind String
    }
    if($PSVersionTable.PSVersion.Major-ge 7){$schema=Join-Path $PSScriptRoot 'renderer-compatibility-manifest.schema.json';if(-not($json|Test-Json -SchemaFile $schema)){throw 'Renderer compatibility manifest failed Draft 2020-12 schema validation.'}}
    Assert-RendererExactProperties $manifest @('$id','manifestVersion','evidenceClassification','issue','governance','candidate','environment','rendererEvidence','captures','references','comparison','matrices','performanceProtocol','review','evidenceBoundary') 'Manifest';Assert-RendererNonnegativeInteger $manifest.manifestVersion 'Manifest version';Assert-RendererNonnegativeInteger $manifest.issue 'Manifest issue'
    if([long]$manifest.manifestVersion-ne4-or[long]$manifest.issue-ne149-or$manifest.'$id'-cne$script:RendererSchemaId-or$manifest.evidenceClassification-cne'AutomatedPackagedCompatibilityCandidate'){throw 'Only manifest v4 can satisfy the current v0.2 release-first contract; v1-v3 are superseded and non-closable.'}
    Assert-RendererExactProperties $manifest.governance @('decisionId','approvalReference','approvedUtc','decisionPayloadSha256','supersedesDecisionId','supersedesPayloadSha256') 'Governance';if($manifest.governance.decisionId-cne$script:RendererDecisionId-or$manifest.governance.approvalReference-cne$script:RendererV4ApprovalReference-or$manifest.governance.approvedUtc-cne$script:RendererDecisionApprovedUtc-or$manifest.governance.decisionPayloadSha256-cne$script:RendererDecisionPayloadSha256-or$manifest.governance.supersedesDecisionId-cne$script:RendererSupersedesDecisionId-or$manifest.governance.supersedesPayloadSha256-cne$script:RendererSupersedesPayloadSha256){throw 'Governance does not equal the exact v0.2 release-first v4 successor authority.'}

    $candidate=$manifest.candidate;Assert-RendererExactProperties $candidate @('source','profile','receipt','archive','packageRootRelativePath','components','referenceHost','renderer') 'Candidate'
    Assert-RendererExactProperties $candidate.source @('commitSha','treeSha') 'Candidate source';foreach($n in @('commitSha','treeSha')){if($candidate.source.$n-isnot[string]-or$candidate.source.$n-cnotmatch'^[0-9a-f]{40}$'){throw "Candidate source $n must be lowercase 40-hex."}}
    Assert-RendererExactProperties $candidate.profile @('id','relativePath','bytes','fileSha256','canonicalSha256') 'Candidate package profile';if($candidate.profile.id-cne$script:RendererPackageProfileId){throw 'Candidate package profile ID is invalid.'};foreach($n in @('bytes')){Assert-RendererPositiveInteger $candidate.profile.$n "Candidate package profile $n"};foreach($n in @('fileSha256','canonicalSha256')){Assert-RendererSha $candidate.profile.$n "Candidate package profile $n"};Assert-RendererRelativePath $candidate.profile.relativePath 'Candidate package profile path'
    Assert-RendererExactProperties $candidate.receipt @('relativePath','bytes','fileSha256','canonicalSha256') 'Candidate package receipt';Assert-RendererPositiveInteger $candidate.receipt.bytes 'Candidate package receipt bytes';foreach($n in @('fileSha256','canonicalSha256')){Assert-RendererSha $candidate.receipt.$n "Candidate package receipt $n"};Assert-RendererRelativePath $candidate.receipt.relativePath 'Candidate package receipt path'
    Assert-RendererExactProperties $candidate.archive @('relativePath','fileName','bytes','sha256') 'Candidate archive';if($candidate.archive.fileName-cne'HerdrOps-0.2.0-win-x64.zip'-or[IO.Path]::GetFileName([string]$candidate.archive.relativePath)-cne$candidate.archive.fileName){throw 'Candidate archive name/path is invalid.'};Assert-RendererPositiveInteger $candidate.archive.bytes 'Candidate archive bytes';Assert-RendererSha $candidate.archive.sha256 'Candidate archive sha256'
    Assert-RendererRelativePath $candidate.packageRootRelativePath 'Candidate package root';Assert-RendererExactProperties $candidate.components @('app','core') 'Candidate components';foreach($name in @('app','core')){Assert-RendererFileBinding $candidate.components.$name "Candidate component $name" $root}
    Assert-RendererExactProperties $candidate.referenceHost @('profileId','profileSha256') 'Candidate referenceHost';if($candidate.referenceHost.profileId-cne$script:RendererProfileId-or$candidate.referenceHost.profileSha256-cne$script:RendererProfileSha256){throw 'Candidate referenceHost is invalid.'}
    Assert-RendererExactProperties $candidate.renderer @('policy','wpfProcessRenderMode') 'Candidate renderer';if($candidate.renderer.policy-cne'software-only-process-wide'-or$candidate.renderer.wpfProcessRenderMode-cne'SoftwareOnly'){throw 'Candidate renderer is invalid.'}
    $boundGit=$null;if($ValidateBindings){if([string]::IsNullOrWhiteSpace($RepositoryRoot)){throw 'RepositoryRoot is required for production binding validation.'};$boundGit=Test-RendererCandidateBindings $candidate $root $RepositoryRoot}

    $renderer=$manifest.rendererEvidence
    $environment=$manifest.environment;Assert-RendererEnvironmentSnapshot $environment
    $captureMode=[string]$manifest.evidenceBoundary.captureMode
    if ($environment.os.architecture -eq 'arm64') { throw 'ARM64 renderer evidence is outside the approved v0.2 scope.' }
    if ($environment.session.kind -eq 'Rdp' -or $environment.session.transport -eq 'Rdp') { throw 'RDP renderer evidence is outside the approved v0.2 scope.' }
    if ([bool]$environment.session.elevated) { throw 'Elevated renderer evidence is outside the approved v0.2 scope.' }
    if ($captureMode -eq 'AutomatedInstalledRuntime') { Assert-RendererLiveEnvironment $environment $RepositoryRoot; if ($null -eq $renderer.targetBindingReceipt) { throw 'AutomatedInstalledRuntime renderer evidence requires a bound target-process receipt.' }; $targetReceipt=(Read-RendererEvidenceReceipt $renderer.targetBindingReceipt 'Target binding receipt' $root $RepositoryRoot).Value; Assert-RendererTargetBindingReceipt $targetReceipt $manifest } elseif ($null -ne $renderer.targetBindingReceipt) { throw 'Deterministic packaged renderer evidence cannot contain a target-process receipt.' }

    $renderer=$manifest.rendererEvidence;Assert-RendererExactProperties $renderer @('policyId','trigger','fallback','producerReport','targetBindingReceipt','preFirstHwnd','throughoutObservations') 'Renderer evidence';if($renderer.policyId-cne'software-only-process-wide'-or$renderer.trigger-cne'ApprovedV02CandidatePolicy'-or$renderer.fallback-cne'None'){throw 'Renderer policy/trigger/fallback is invalid.'};Assert-RendererExactProperties $renderer.producerReport @('relativePath','bytes','fileSha256','canonicalSha256') 'Producer report binding'
    Assert-RendererExactProperties $renderer.preFirstHwnd @('hasAnyHwnd','observation','firstHwndCreatedUtc') 'Pre-first-HWND proof';Assert-RendererBoolean $renderer.preFirstHwnd.hasAnyHwnd 'Pre-first-HWND hasAnyHwnd';if([bool]$renderer.preFirstHwnd.hasAnyHwnd){throw 'Pre-first-HWND proof must report native false.'};Assert-RendererUtc $renderer.preFirstHwnd.firstHwndCreatedUtc 'First HWND UTC'
    $throughout=@($renderer.throughoutObservations);Assert-RendererSet @($throughout|ForEach-Object{$_.stage}) $script:RendererObservationStages 'Renderer observation stages'
    for($i=0;$i-lt$script:RendererObservationStages.Count;$i++){if([string]$throughout[$i].stage-cne$script:RendererObservationStages[$i]){throw "Renderer observation index $i must be '$($script:RendererObservationStages[$i])'."}}
    $allObservations=@($renderer.preFirstHwnd.observation)+$throughout
    foreach($observation in $allObservations){Assert-RendererExactProperties $observation @('stage','effectiveMode','softwareOnlyConfirmed','observedUtc','proofReceipt') "Renderer observation '$($observation.stage)'";Assert-RendererBoolean $observation.softwareOnlyConfirmed "Renderer observation '$($observation.stage)' softwareOnlyConfirmed";if($observation.effectiveMode-cne'SoftwareOnly'-or-not[bool]$observation.softwareOnlyConfirmed){throw "Renderer observation '$($observation.stage)' is not an observed native SoftwareOnly result."};Assert-RendererUtc $observation.observedUtc "Renderer observation '$($observation.stage)' UTC";if(-not$ValidateBindings){throw 'Renderer proof receipts require production binding validation.'};$proof=(Read-RendererEvidenceReceipt $observation.proofReceipt "Renderer observation '$($observation.stage)' proof" $root $RepositoryRoot).Value;Assert-RendererExactProperties $proof @('stage','effectiveMode','softwareOnlyConfirmed','observedUtc','nativeProcessRenderMode','nativeRenderCapabilityTier') "Renderer proof '$($observation.stage)'";Assert-RendererBoolean $proof.softwareOnlyConfirmed 'Renderer proof confirmation';Assert-RendererNonnegativeInteger $proof.nativeRenderCapabilityTier 'Renderer proof capability tier';if($proof.stage-cne$observation.stage-or$proof.effectiveMode-cne$observation.effectiveMode-or$proof.softwareOnlyConfirmed-cne$observation.softwareOnlyConfirmed-or$proof.observedUtc-cne$observation.observedUtc-or$proof.nativeProcessRenderMode-cne$observation.effectiveMode){throw "Renderer observation '$($observation.stage)' proof receipt does not bind its canonical raw native observation."}}
    $previousUtc=$null;foreach($observation in $throughout){if($null-ne$previousUtc-and[DateTimeOffset]$observation.observedUtc-lt$previousUtc){throw 'Renderer observations must be ordered by nondecreasing UTC.'};$previousUtc=[DateTimeOffset]$observation.observedUtc}
    if($renderer.preFirstHwnd.observation.stage-cne'PreFirstWindow'){throw 'Pre-first-HWND observation stage must be PreFirstWindow.'}
    $boundPreFirst=$throughout[1];foreach($name in @('stage','effectiveMode','softwareOnlyConfirmed','observedUtc')){if($renderer.preFirstHwnd.observation.$name-cne$boundPreFirst.$name){throw "Pre-first-HWND observation must exactly equal throughoutObservations[1] field '$name'."}};Assert-RendererBindingEqual $renderer.preFirstHwnd.observation.proofReceipt $boundPreFirst.proofReceipt 'Pre-first-HWND proof receipt'
    $firstHwnd=[DateTimeOffset]$renderer.preFirstHwnd.firstHwndCreatedUtc;if([DateTimeOffset]$renderer.preFirstHwnd.observation.observedUtc-ge$firstHwnd-or[DateTimeOffset]$throughout[0].observedUtc-ge$firstHwnd-or[DateTimeOffset]$throughout[2].observedUtc-lt$firstHwnd){throw 'Renderer observation/HWND ordering is invalid.'}

    $captureKeys=@();$capturePaths=@();foreach($capture in @($manifest.captures)){Assert-RendererExactProperties $capture @('language','name','category','semanticPhase','relativePath','widthPixels','heightPixels','bytes','sha256','observedUtc') "Capture";if($capture.language-cnotin@('Thai','English')){throw 'Capture language is invalid.'};$key="$($capture.language)|$($capture.name)";$captureKeys+=$key;$capturePaths+=[string]$capture.relativePath;if($capture.category-cne(Get-RendererCategory $capture.name)-or$capture.semanticPhase-cne(Get-RendererSemanticPhase $capture.name)){throw "Capture '$key' category or semantic phase is invalid."};$expectedPath="captures/$($capture.language)/$($capture.name).png";if([string]$capture.relativePath-cne$expectedPath){throw "Capture '$key' must use exact isolated path '$expectedPath'."};foreach($n in @('widthPixels','heightPixels','bytes')){Assert-RendererPositiveInteger $capture.$n "Capture $n"};Assert-RendererSha $capture.sha256 'Capture hash';Assert-RendererUtc $capture.observedUtc 'Capture UTC';if($ValidateBindings){$capturePath=Resolve-RendererBoundPath $root $capture.relativePath 'Capture path';$png=Get-RendererPngIdentity $root $capturePath "Capture '$key'";if($png.Bytes-ne[long]$capture.bytes-or$png.Sha256-cne$capture.sha256-or$png.Width-ne[long]$capture.widthPixels-or$png.Height-ne[long]$capture.heightPixels){throw "Capture '$key' held-byte PNG/hash/dimensions binding failed."}}}
    $expectedCaptureKeys=@();foreach($language in @('Thai','English')){foreach($name in $script:RendererCaptureNames){$expectedCaptureKeys+="$language|$name"}};Assert-RendererSet $captureKeys $expectedCaptureKeys 'Capture catalog';for($i=0;$i-lt$expectedCaptureKeys.Count;$i++){if($captureKeys[$i]-cne$expectedCaptureKeys[$i]){throw "Capture index $i must be '$($expectedCaptureKeys[$i])'."}};if((@($capturePaths|Select-Object -Unique)).Count-ne$capturePaths.Count){throw 'Capture paths must be unique.'}
    $thaiStart=[DateTimeOffset]$throughout[3].observedUtc;$thaiEnd=[DateTimeOffset]$throughout[4].observedUtc;$englishStart=[DateTimeOffset]$throughout[5].observedUtc;$englishEnd=[DateTimeOffset]$throughout[6].observedUtc;foreach($capture in @($manifest.captures)){$captureUtc=[DateTimeOffset]$capture.observedUtc;if(($capture.language-ceq'Thai'-and($captureUtc-lt$thaiStart-or$captureUtc-gt$thaiEnd))-or($capture.language-ceq'English'-and($captureUtc-lt$englishStart-or$captureUtc-gt$englishEnd))){throw "Capture '$($capture.language)|$($capture.name)' falls outside its renderer-observation language window."}}
    if($ValidateBindings){$producer=(Read-RendererEvidenceReceipt $renderer.producerReport 'Producer App report' $root $RepositoryRoot).Value;Assert-RendererExactProperties $producer @('reportType','profileId','profileSha256','source','packageReceiptSha256','rendererPolicy','observations','captures') 'Producer App report';if($producer.reportType-cne'V02RendererCompatibilityAppReport'-or$producer.profileId-cne$candidate.referenceHost.profileId-or$producer.profileSha256-cne$candidate.referenceHost.profileSha256-or$producer.packageReceiptSha256-cne$candidate.receipt.canonicalSha256-or$producer.rendererPolicy-cne$candidate.renderer.policy){throw 'Producer App report identity/profile/package/renderer binding failed.'};Assert-RendererExactProperties $producer.source @('commitSha','treeSha') 'Producer App report source';if($producer.source.commitSha-cne$candidate.source.commitSha-or$producer.source.treeSha-cne$candidate.source.treeSha){throw 'Producer App report source binding failed.'};$producerObservations=@($producer.observations);if($producerObservations.Count-ne$throughout.Count){throw 'Producer App report renderer observation count mismatch.'};for($i=0;$i-lt$throughout.Count;$i++){Assert-RendererExactProperties $producerObservations[$i] @('stage','effectiveMode','softwareOnlyConfirmed','observedUtc','proofReceipt') "Producer observation $i";foreach($name in @('stage','effectiveMode','softwareOnlyConfirmed','observedUtc')){if($producerObservations[$i].$name-cne$throughout[$i].$name){throw "Producer observation $i field '$name' does not equal manifest renderer evidence."}};Assert-RendererBindingEqual $producerObservations[$i].proofReceipt $throughout[$i].proofReceipt "Producer observation $i proof receipt"};$producerCaptures=@($producer.captures);if($producerCaptures.Count-ne$manifest.captures.Count){throw 'Producer App report capture count mismatch.'};for($i=0;$i-lt$manifest.captures.Count;$i++){Assert-RendererExactProperties $producerCaptures[$i] @('language','name','sha256','observedUtc') "Producer capture $i";foreach($name in @('language','name','sha256','observedUtc')){if($producerCaptures[$i].$name-cne$manifest.captures[$i].$name){throw "Producer capture $i field '$name' does not equal manifest capture evidence."}}}}

    $referenceManifest=Read-HumanDesignReviewReferenceManifest;$referenceNames=@();foreach($reference in @($manifest.references)){Assert-RendererExactProperties $reference @('relativePath','widthPixels','heightPixels','bytes','sha256') 'Reference';$leaf=[IO.Path]::GetFileName([string]$reference.relativePath);$referenceNames+=$leaf;if(-not$referenceManifest.ContainsKey($leaf)){throw "Reference '$leaf' is not immutable."};if([string]$reference.relativePath-cne"docs/design/reference/$leaf"){throw "Reference '$leaf' must use its exact immutable repository path."};$expected=$referenceManifest[$leaf];Assert-RendererPositiveInteger $reference.widthPixels "Reference '$leaf' width";Assert-RendererPositiveInteger $reference.heightPixels "Reference '$leaf' height";Assert-RendererPositiveInteger $reference.bytes "Reference '$leaf' bytes";if([int]$reference.widthPixels-ne$expected.Width-or[int]$reference.heightPixels-ne$expected.Height-or[long]$reference.bytes-ne$expected.Bytes-or[string]$reference.sha256-cne$expected.Sha256){throw "Reference '$leaf' metadata/hash mismatch."};Assert-HumanDesignReviewReferenceBinding $reference.relativePath -ValidateBindings:$ValidateBindings};$expectedReferenceNames=@($referenceManifest.Keys|Sort-Object);Assert-RendererSet $referenceNames $expectedReferenceNames 'Reference catalog';for($i=0;$i-lt$expectedReferenceNames.Count;$i++){if($referenceNames[$i]-cne$expectedReferenceNames[$i]){throw "Reference index $i must be '$($expectedReferenceNames[$i])'."}}

    $comparison=$manifest.comparison;Assert-RendererExactProperties $comparison @('algorithm','tolerance','maskSetReceipt','masks','results') 'Comparison';Assert-RendererExactProperties $comparison.algorithm @('name','version','colorSpace','alphaMode') 'Comparison algorithm';Assert-RendererString $comparison.algorithm.name 'Algorithm name';Assert-RendererString $comparison.algorithm.version 'Algorithm version';if($comparison.algorithm.colorSpace-cne'sRGB'-or$comparison.algorithm.alphaMode-cne'Straight'){throw 'Comparison color/alpha semantics are invalid.'}
    $tol=$comparison.tolerance;Assert-RendererExactProperties $tol @('approvalStatus','approvalReference','perChannelDelta','maximumDifferentPixelPercent','maximumNonmaskedDifferences') 'Comparison tolerance';if($tol.approvalStatus-cnotin@('NOT_OBSERVED','APPROVED')){throw 'Tolerance approval status is invalid.'};if($tol.approvalStatus-ceq'NOT_OBSERVED'){foreach($n in @('approvalReference','perChannelDelta','maximumDifferentPixelPercent','maximumNonmaskedDifferences')){if($null-ne$tol.$n){throw 'Unapproved comparison tolerance must keep limits/reference null.'}}}else{if($tol.approvalReference-cne$script:RendererAuthorizedApprovalReference){throw 'Comparison approval does not bind REC-ALL v2.'};Assert-RendererFiniteNumber $tol.perChannelDelta 'Tolerance perChannelDelta' 0 255;Assert-RendererFiniteNumber $tol.maximumDifferentPixelPercent 'Tolerance maximumDifferentPixelPercent' 0 100;Assert-RendererNonnegativeInteger $tol.maximumNonmaskedDifferences 'Tolerance maximumNonmaskedDifferences';if([decimal]$tol.perChannelDelta-ne8-or[decimal]$tol.maximumDifferentPixelPercent-ne0.1-or[long]$tol.maximumNonmaskedDifferences-ne0){throw 'Comparison tolerance does not equal REC-ALL v2.'}}
    $maskIds=@();$maskPaths=@();$decodedMasks=@();foreach($mask in @($comparison.masks)){Assert-RendererExactProperties $mask @('id','relativePath','sha256','maximumRadiusPixels','rationale','approvalReference','captureKeys') 'Mask';$maskIds+=[string]$mask.id;$maskPaths+=[string]$mask.relativePath;Assert-RendererString $mask.id 'Mask id';Assert-RendererString $mask.rationale 'Mask rationale';Assert-RendererSet @($mask.captureKeys) @($mask.captureKeys) "Mask '$($mask.id)' capture associations";foreach($key in @($mask.captureKeys)){if($expectedCaptureKeys-cnotcontains$key){throw "Mask '$($mask.id)' has an unknown capture association."}};if($mask.approvalReference-cne$script:RendererAuthorizedApprovalReference-or$mask.maximumRadiusPixels-isnot[int]-or$mask.maximumRadiusPixels-ne1){throw 'Mask is not predeclared under the exact REC-ALL v2 one-pixel rule.'};Assert-RendererRelativePath $mask.relativePath 'Mask path';Assert-RendererSha $mask.sha256 'Mask hash';if($ValidateBindings){$path=Resolve-RendererBoundPath $root $mask.relativePath 'Mask path';$png=Get-RendererPngIdentity $root $path "Mask '$($mask.id)'";if($png.Sha256-cne[string]$mask.sha256){throw "Mask '$($mask.id)' binding failed."};$png|Add-Member captureKeys @($mask.captureKeys);$decodedMasks+=,$png}};if((@($maskIds|Select-Object -Unique)).Count-ne$maskIds.Count-or(@($maskPaths|Select-Object -Unique)).Count-ne$maskPaths.Count){throw 'Mask IDs and paths must be unique.'};if($tol.approvalStatus-ceq'NOT_OBSERVED'-and$maskIds.Count-ne0){throw 'Unapproved comparison policy cannot declare masks.'};if($maskIds.Count-eq0){if($null-ne$comparison.maskSetReceipt){throw 'Empty mask set cannot claim a receipt.'}}else{if(-not$ValidateBindings-or$null-eq$comparison.maskSetReceipt){throw 'Declared masks require a bound pre-capture mask-set receipt.'};$maskReceipt=(Read-RendererEvidenceReceipt $comparison.maskSetReceipt 'Mask-set receipt' $root $RepositoryRoot).Value;Assert-RendererExactProperties $maskReceipt @('ownerApprovalReference','declaredUtc','masks') 'Mask-set receipt';if($maskReceipt.ownerApprovalReference-cne$script:RendererAuthorizedApprovalReference){throw 'Mask-set owner authority is invalid.'};Assert-RendererUtc $maskReceipt.declaredUtc 'Mask-set declared UTC';$earliest=@($manifest.captures|ForEach-Object{[DateTimeOffset]$_.observedUtc}|Sort-Object)[0];if([DateTimeOffset]$maskReceipt.declaredUtc-ge$earliest){throw 'Mask-set receipt was not predeclared before capture start.'};$receiptMasks=@($maskReceipt.masks);if($receiptMasks.Count-ne$comparison.masks.Count){throw 'Mask-set receipt count mismatch.'};for($i=0;$i-lt$receiptMasks.Count;$i++){Assert-RendererExactProperties $receiptMasks[$i] @('id','relativePath','sha256','captureKeys') "Mask-set receipt entry $i";foreach($name in @('id','relativePath','sha256')){if($receiptMasks[$i].$name-cne$comparison.masks[$i].$name){throw "Mask-set receipt entry $i field '$name' mismatch."}};if((@($receiptMasks[$i].captureKeys)-join'|')-cne(@($comparison.masks[$i].captureKeys)-join'|')){throw "Mask-set receipt entry $i associations mismatch."}}}
    $resultKeys=@();$visualComplete=$tol.approvalStatus-ceq'APPROVED';foreach($result in @($comparison.results)){Assert-RendererExactProperties $result @('language','captureName','referenceRelativePath','status','differentPixels','differentPixelPercent','maximumChannelDelta','nonmaskedDifferenceCount','disposition') 'Comparison result';$key="$($result.language)|$($result.captureName)";$resultKeys+=$key;if([string]$result.referenceRelativePath-cne(Get-RendererReferencePath $result.captureName)){throw "Comparison '$key' is not bound to the exact immutable reference."};if($result.status-cnotin@('PASS','FAIL','NOT_OBSERVED')){throw "Comparison '$key' status is invalid."};if($result.status-ceq'NOT_OBSERVED'){foreach($n in @('differentPixels','differentPixelPercent','maximumChannelDelta','nonmaskedDifferenceCount','disposition')){if($null-ne$result.$n){throw "Comparison '$key' NOT_OBSERVED must keep metrics/disposition null."}};$visualComplete=$false}else{if($tol.approvalStatus-cne'APPROVED'){throw "Comparison '$key' cannot claim observed results before tolerance approval."};Assert-RendererNonnegativeInteger $result.differentPixels "Comparison '$key' differentPixels";Assert-RendererFiniteNumber $result.differentPixelPercent "Comparison '$key' differentPixelPercent" 0 100;Assert-RendererFiniteNumber $result.maximumChannelDelta "Comparison '$key' maximumChannelDelta" 0 255;Assert-RendererNonnegativeInteger $result.nonmaskedDifferenceCount "Comparison '$key' nonmaskedDifferenceCount";if([long]$result.nonmaskedDifferenceCount-gt[long]$result.differentPixels){throw "Comparison '$key' nonmasked differences exceed total differences."};Assert-RendererString $result.disposition "Comparison '$key' disposition";$within=([double]$result.differentPixelPercent-le[double]$tol.maximumDifferentPixelPercent-and[double]$result.maximumChannelDelta-le[double]$tol.perChannelDelta-and[long]$result.nonmaskedDifferenceCount-le[long]$tol.maximumNonmaskedDifferences);if(($result.status-ceq'PASS')-ne$within){throw "Comparison '$key' status contradicts the approved fail rule."};if($result.status-cne'PASS'){$visualComplete=$false}}};Assert-RendererSet $resultKeys $expectedCaptureKeys 'Comparison result catalog';for($i=0;$i-lt$expectedCaptureKeys.Count;$i++){if($resultKeys[$i]-cne$expectedCaptureKeys[$i]){throw "Comparison result index $i must be '$($expectedCaptureKeys[$i])'."}}
    if($ValidateBindings){foreach($result in @($comparison.results|Where-Object{$_.status-cne'NOT_OBSERVED'})){$key="$($result.language)|$($result.captureName)";$capture=@($manifest.captures|Where-Object{"$($_.language)|$($_.name)"-ceq$key})[0];$capturePng=Get-RendererPngIdentity $root (Resolve-RendererBoundPath $root $capture.relativePath 'Observed comparison capture') "Comparison '$key' capture";$referencePng=Get-RendererPngIdentity $RepositoryRoot (Join-Path $RepositoryRoot $result.referenceRelativePath) "Comparison '$key' reference";$actual=Compare-RendererPixels $capturePng $referencePng $decodedMasks $key;if([long]$result.differentPixels-ne$actual.DifferentPixels-or[Math]::Abs([double]$result.differentPixelPercent-$actual.DifferentPixelPercent)-gt0.000000001-or[double]$result.maximumChannelDelta-ne$actual.MaximumChannelDelta-or[long]$result.nonmaskedDifferenceCount-ne$actual.NonmaskedDifferenceCount){throw "Comparison '$key' metrics are not independently recomputed from held decoded pixels/masks."};$actualPass=$actual.DifferentPixelPercent-le[double]$tol.maximumDifferentPixelPercent-and$actual.MaximumChannelDelta-le[double]$tol.perChannelDelta-and$actual.NonmaskedDifferenceCount-le[long]$tol.maximumNonmaskedDifferences;if(($result.status-ceq'PASS')-ne$actualPass){throw "Comparison '$key' status is not recomputed from held decoded pixels/masks."}}}elseif(@($comparison.results|Where-Object{$_.status-cne'NOT_OBSERVED'}).Count){throw 'Observed comparisons require production binding validation.'}

    $globalMatrixRunFingerprint = $null
    $matrices=$manifest.matrices;Assert-RendererExactProperties $matrices @('displayCases','mixedDpiTransitions','accessibilityCases','supportedEnvironmentCases') 'Matrices';Assert-RendererMatrixCases @($matrices.displayCases) $script:RendererDisplayCases 'Display matrix' $root $RepositoryRoot -ValidateBindings:$ValidateBindings -CommonRunFingerprint ([ref]$globalMatrixRunFingerprint) -ExpectedCandidate $candidate;Assert-RendererMatrixCases @($matrices.mixedDpiTransitions) $script:RendererMixedDpiCases 'Mixed-DPI matrix' $root $RepositoryRoot -ValidateBindings:$ValidateBindings -CommonRunFingerprint ([ref]$globalMatrixRunFingerprint) -ExpectedCandidate $candidate;Assert-RendererMatrixCases @($matrices.accessibilityCases) $script:RendererAccessibilityCases 'Accessibility matrix' $root $RepositoryRoot -ValidateBindings:$ValidateBindings -CommonRunFingerprint ([ref]$globalMatrixRunFingerprint) -ExpectedCandidate $candidate;Assert-RendererMatrixCases @($matrices.supportedEnvironmentCases) $script:RendererEnvironmentCases 'Supported-environment matrix' $root $RepositoryRoot -ValidateBindings:$ValidateBindings -CommonRunFingerprint ([ref]$globalMatrixRunFingerprint) -ExpectedCandidate $candidate
    if($ValidateBindings){$previousMatrixUtc=$null;foreach($matrixCase in @($matrices.displayCases+$matrices.mixedDpiTransitions+$matrices.accessibilityCases+$matrices.supportedEnvironmentCases)){if($matrixCase.status-cne'NOT_OBSERVED'){$chronologyReceipt=(Read-RendererEvidenceReceipt $matrixCase.evidenceReceipt "Matrix chronology '$($matrixCase.id)'" $root $RepositoryRoot).Value;$currentMatrixUtc=[DateTimeOffset]::Parse($chronologyReceipt.observedUtc);if($null-ne$previousMatrixUtc-and$currentMatrixUtc-le$previousMatrixUtc){throw "Observed matrix receipt chronology must be strictly increasing and unique in governed case order at '$($matrixCase.id)'."};$previousMatrixUtc=$currentMatrixUtc}}}
    $matrixComplete=@($matrices.displayCases+$matrices.mixedDpiTransitions+$matrices.accessibilityCases+$matrices.supportedEnvironmentCases|Where-Object{$_.status-cne'PASS'}).Count-eq0
    $automatedMatrixEvidenceComplete=$true
    foreach($automatedCase in @($matrices.displayCases)+@($matrices.accessibilityCases)+@($matrices.supportedEnvironmentCases)){
        if($automatedCase.status-cne'PASS'-or$null-eq$automatedCase.evidenceReceipt){$automatedMatrixEvidenceComplete=$false;continue}
        $automatedReceipt=(Read-RendererEvidenceReceipt $automatedCase.evidenceReceipt "Automated matrix '$($automatedCase.id)'" $root $RepositoryRoot).Value
        if($automatedReceipt.evidenceBoundary.evidenceClass-cne'AutomatedPackagedRendering'){$automatedMatrixEvidenceComplete=$false}
    }

    $performance=$manifest.performanceProtocol
    $performanceNames=@('sameCandidateContentWorkloadHostSession','onlyRendererPolicyVaries','modeA','modeB','orders','warmupIterations','repetitionsPerOrder','statistic','ownerNumericLimits','samplesStatus','evidenceReceipt','pipelineCommit')
    Assert-RendererExactProperties $performance $performanceNames 'Performance protocol';Assert-RendererBoolean $performance.sameCandidateContentWorkloadHostSession 'Performance same binding';Assert-RendererBoolean $performance.onlyRendererPolicyVaries 'Performance only renderer varies';if(-not[bool]$performance.sameCandidateContentWorkloadHostSession-or-not[bool]$performance.onlyRendererPolicyVaries-or$performance.modeA-cne'Hardware'-or$performance.modeB-cne'SoftwareOnly'){throw 'Performance protocol must compare Hardware A with SoftwareOnly B on the same binding.'};Assert-RendererSet @($performance.orders) @('AB','BA') 'Performance order';for($i=0;$i-lt2;$i++){if($performance.orders[$i]-cne@('AB','BA')[$i]){throw 'Performance order must be exact AB, BA.'}};Assert-RendererPositiveInteger $performance.warmupIterations 'Warm-up iterations';Assert-RendererPositiveInteger $performance.repetitionsPerOrder 'Repetitions';Assert-RendererString $performance.statistic 'Performance statistic'
    $limitNames=@('cpuMaximumPercent','eventToWpfP95Milliseconds','cpuRegressionMaximumPercent','cpuRegressionMaximumPercentagePoints','latencyRegressionMaximumPercent','uiStallP95Milliseconds','uiStallMaximumMilliseconds','workingSetMaximumBytes');$limits=$performance.ownerNumericLimits;Assert-RendererExactProperties $limits (@('status','approvalReference')+$limitNames) 'Owner numeric limits';if($limits.status-cnotin@('NOT_OBSERVED','APPROVED')){throw 'Owner numeric-limit status is invalid.'};if($limits.status-ceq'NOT_OBSERVED'){foreach($n in @('approvalReference')+$limitNames){if($null-ne$limits.$n){throw 'Unapproved owner numeric limits must remain null.'}}}else{if($limits.approvalReference-cne$script:RendererAuthorizedApprovalReference){throw 'Owner numeric limits do not bind unchanged REC-ALL v2 limits.'};$expectedLimits=[ordered]@{cpuMaximumPercent=1;eventToWpfP95Milliseconds=250;cpuRegressionMaximumPercent=10;cpuRegressionMaximumPercentagePoints=0.5;latencyRegressionMaximumPercent=10;uiStallP95Milliseconds=50;uiStallMaximumMilliseconds=100;workingSetMaximumBytes=267386880};foreach($n in $limitNames){Assert-RendererFiniteNumber $limits.$n "Owner numeric limit $n" 0 ([double]::MaxValue) -ExclusiveMinimum;if([decimal]$limits.$n-ne[decimal]($expectedLimits[$n])){throw "Owner numeric limit $n does not equal the v0.2 release-first authority."}};Assert-RendererPositiveInteger $limits.workingSetMaximumBytes 'Owner numeric limit workingSetMaximumBytes'};if($performance.warmupIterations-ne1-or$performance.repetitionsPerOrder-ne5-or$performance.statistic-cne'p95-and-maximum-missing-sample-fails'){throw 'Performance repetitions/statistic do not equal the v0.2 release-first authority.'};if($performance.samplesStatus-cnotin@('PASS','FAIL','NOT_OBSERVED')){throw 'Performance samples status is invalid.'};$finalizedPerformanceComplete=$false;if($performance.samplesStatus-ceq'NOT_OBSERVED'){if($null-ne$performance.evidenceReceipt-or$null-ne$performance.pipelineCommit){throw 'Unobserved performance samples cannot claim performance or pipeline receipts.'}}else{if($limits.status-cne'APPROVED'-or-not$ValidateBindings-or$null-eq$performance.evidenceReceipt-or$null-eq$performance.pipelineCommit){throw 'Performance samples require approved limits and exact production performance plus pipeline bindings.'};$computedPerformance=Assert-RendererPerformancePipelineCommit $performance.pipelineCommit $root $RepositoryRoot $performance.evidenceReceipt $candidate $limits $manifest.environment.session $boundGit.PackageReceipt;if($performance.samplesStatus-cne$computedPerformance){throw 'Performance samplesStatus does not equal independently recomputed no-soak pipeline evidence.'};$finalizedPerformanceComplete=$true}

    $review=$manifest.review;Assert-RendererExactProperties $review @('decision','builderIdentity','reviewerIdentity','reviewerRole','reviewedUtc','defects') 'Agent review';if($review.decision-cnotin@('APPROVED','REJECTED','NOT_OBSERVED')){throw 'Agent review decision is invalid.'};if($review.decision-ceq'NOT_OBSERVED'){if($null-ne$review.builderIdentity-or$null-ne$review.reviewerIdentity-or$null-ne$review.reviewerRole-or$null-ne$review.reviewedUtc){throw 'Unobserved Agent review cannot claim identities, role, or time.'}}else{Assert-RendererString $review.builderIdentity 'Agent review builder identity';Assert-RendererString $review.reviewerIdentity 'Agent review reviewer identity';if($review.builderIdentity.Trim().Equals($review.reviewerIdentity.Trim(),[StringComparison]::OrdinalIgnoreCase)-or$review.reviewerRole-cne'IndependentAgentReviewer'){throw 'Agent review requires a role-distinct IndependentAgentReviewer.'};Assert-RendererUtc $review.reviewedUtc 'Agent review UTC'};$defectIds=@();$defectsComplete=$true;foreach($defect in @($review.defects)){Assert-RendererExactProperties $defect @('id','severity','summary','status','disposition') 'Defect';$defectIds+=[string]$defect.id;Assert-RendererString $defect.id 'Defect id';if($defect.severity-cnotin@('P0','P1','P2','P3')-or$defect.status-cnotin@('Open','Resolved','Accepted')){throw "Defect '$($defect.id)' enum is invalid."};Assert-RendererString $defect.summary 'Defect summary';Assert-RendererString $defect.disposition 'Defect disposition';if($defect.status-ceq'Open'-and$defect.severity-cin@('P0','P1')){$defectsComplete=$false}};if((@($defectIds|Select-Object -Unique)).Count-ne$defectIds.Count){throw 'Defect IDs must be unique.'};if($review.decision-ceq'APPROVED'-and-not$defectsComplete){throw 'Agent approval cannot retain an open High/Critical defect.'}
    $boundary=$manifest.evidenceBoundary;Assert-RendererExactProperties $boundary @('packagedCompatibility','captureMode','agentReview','actualHerdrRuntime','release','creditGranted') 'Evidence boundary';if($boundary.captureMode-cnotin$script:RendererCaptureModes){throw 'Evidence boundary captureMode is invalid.'};if($boundary.packagedCompatibility-cne'AUTOMATED_CANDIDATE'-or$boundary.agentReview-cne$review.decision-or$boundary.actualHerdrRuntime-cne'NOT_OBSERVED'-or$boundary.release-cne'NOT_OBSERVED'-or$boundary.creditGranted-isnot[bool]-or[bool]$boundary.creditGranted){throw 'Evidence boundary inflates or contradicts the automated candidate classification.'}
    if($ValidateBindings){$finalGit=Test-RendererCandidateBindings $candidate $root $RepositoryRoot;if($finalGit.CommitSha-cne$boundGit.CommitSha-or$finalGit.TreeSha-cne$boundGit.TreeSha){throw 'Candidate repository identity changed during validation.'}}
    $authorityProfileConsistent=$script:RendererRecAllReferenceHostSha256-ceq$script:RendererProfileSha256
    $ready=[bool]$ValidateBindings-and$authorityProfileConsistent-and$visualComplete-and$matrixComplete-and$automatedMatrixEvidenceComplete-and$limits.status-ceq'APPROVED'-and$performance.samplesStatus-ceq'PASS'-and$finalizedPerformanceComplete-and$review.decision-ceq'APPROVED'-and$defectsComplete
    [pscustomobject][ordered]@{EvidenceClassification='AutomatedPackagedCompatibilityCandidate';CaptureMode=[string]$boundary.captureMode;ManifestVersion=[int]$manifest.manifestVersion;StructuralValidation='PASS';BindingValidation=if($ValidateBindings){'PASS'}else{'NOT_REQUESTED'};GovernanceProfileConsistency=if($authorityProfileConsistent){'PASS'}else{'FAIL'};AutomatedMatrixEvidence=if($automatedMatrixEvidenceComplete){'PASS'}else{'NOT_OBSERVED'};OwnerNumericLimits=$limits.status;AgentReview=$review.decision;ActualHerdrRuntime='NOT_OBSERVED';Release='NOT_OBSERVED';CreditGranted=$false;PackagedCompatibilityReadyForIssue149Closure=$ready}
}

function Copy-RendererValue {
    param([Parameter(Mandatory=$true)]$Value)
    $json = $Value | ConvertTo-Json -Depth 80
    if ($PSVersionTable.PSVersion.Major -ge 7) {
        return ($json | ConvertFrom-Json -DateKind String)
    } else {
        return ($json | ConvertFrom-Json)
    }
}

function New-RendererTestPng {
    param(
        [Parameter(Mandatory=$true)][string]$Path,
        [Parameter(Mandatory=$true)][int]$Width,
        [Parameter(Mandatory=$true)][int]$Height
    )
    $stride = $Width * 4
    $pixels = New-Object byte[] ($stride * $Height)
    for ($i = 0; $i -lt $pixels.Length; $i += 4) {
        $pixels[$i] = 20
        $pixels[$i + 1] = 40
        $pixels[$i + 2] = 60
        $pixels[$i + 3] = 255
    }
    $bitmap = [Windows.Media.Imaging.BitmapSource]::Create($Width, $Height, 96, 96, [Windows.Media.PixelFormats]::Bgra32, $null, $pixels, $stride)
    $encoder = New-Object Windows.Media.Imaging.PngBitmapEncoder
    $encoder.Frames.Add([Windows.Media.Imaging.BitmapFrame]::Create($bitmap))
    $parent = Split-Path -Parent $Path
    if (-not [string]::IsNullOrWhiteSpace($parent) -and -not (Test-Path -LiteralPath $parent)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }
    $stream = [IO.File]::Open($Path, [IO.FileMode]::Create, [IO.FileAccess]::Write, [IO.FileShare]::None)
    try {
        $encoder.Save($stream)
    } finally {
        $stream.Dispose()
    }
}

function New-RendererMatrixCases {
    param([Parameter(Mandatory=$true)][AllowEmptyCollection()][string[]]$Ids)
    return @($Ids | ForEach-Object {
        [pscustomobject][ordered]@{
            id = $_
            status = 'NOT_OBSERVED'
            evidenceReceipt = $null
            notes = $null
        }
    })
}

function Assert-RendererPerformanceSampleProperties {
    param($Sample,[string]$Context)
    Assert-RendererExactProperties $Sample @('cpuBasisPoints','workingSetMaximumBytes','latencyMicroseconds','uiStallMicroseconds') $Context
    Assert-RendererNonnegativeInteger $Sample.cpuBasisPoints "$Context cpuBasisPoints"
    Assert-RendererNonnegativeInteger $Sample.workingSetMaximumBytes "$Context workingSetMaximumBytes"
    foreach ($name in @('latencyMicroseconds','uiStallMicroseconds')) {
        $values = @($Sample.$name)
        if ($values.Count -ne 20) { throw "$Context $name must contain exactly 20 raw observations; found $($values.Count)." }
        foreach ($value in $values) { Assert-RendererNonnegativeInteger $value "$Context $name observation" }
    }
}

function Get-RendererMatrixCaseContract {
    param([string]$CaseId)
    if($script:RendererDisplayCases-ccontains$CaseId){return [pscustomobject]@{Kind='Display';Checks=@('offscreen-viewport-configured','packaged-render-completed','visual-integrity','single-language')}}
    if($script:RendererMixedDpiCases-ccontains$CaseId){return [pscustomobject]@{Kind='MixedDpi';Checks=@('initial-dpi-confirmed','primary-switch-observed','monitor-unplug-observed','final-dpi-confirmed')}}
    if($script:RendererAccessibilityCases-ccontains$CaseId){
        $checks=switch -CaseSensitive($CaseId){
            'keyboard-uia'{@('keyboard-navigation','uia-tree')};'high-contrast'{@('high-contrast-visible')}
            {$_-in@('text-scale-100','text-scale-150','text-scale-200')}{@('text-scale-applied','no-clipping-overlap')}
            {$_-in@('reduced-motion-on','reduced-motion-off')}{@('motion-policy-applied')}
        }
        return [pscustomobject]@{Kind='Accessibility';Checks=@($checks)}
    }
    if($script:RendererEnvironmentCases-ccontains$CaseId){
        $checks=switch -CaseSensitive($CaseId){
            'windows11-x64-build26220-packaged-non-elevated-single-user'{@('os-build-matched','packaged-session','non-elevated','single-user')}
        }
        return [pscustomobject]@{Kind='Environment';Checks=@($checks)}
    }
    throw "Unknown governed renderer matrix case '$CaseId'."
}

function Assert-RendererPerformanceRepetitionProperties {
    param($Repetition,[int]$ExpectedOrdinal,[string]$Context,[switch]$Warmup)
    Assert-RendererExactProperties $Repetition @('ordinal','observedUtc','a','b') $Context
    Assert-RendererNonnegativeInteger $Repetition.ordinal "$Context ordinal"
    if ([long]$Repetition.ordinal -ne $ExpectedOrdinal) { throw "$Context ordinal must equal $ExpectedOrdinal; found $($Repetition.ordinal)." }
    Assert-RendererUtc $Repetition.observedUtc "$Context observedUtc"
    Assert-RendererPerformanceSampleProperties $Repetition.a "$Context mode A sample"
    Assert-RendererPerformanceSampleProperties $Repetition.b "$Context mode B sample"
}

function New-RendererPerformanceProvenance {
    param(
        [Parameter(Mandatory=$true)]$Candidate,
        [Parameter(Mandatory=$true)]$Session,
        [Parameter(Mandatory=$true)][string]$RunNonce,
        [Parameter(Mandatory=$true)]$PerformanceTelemetryBinding,
        [Parameter(Mandatory=$true)]$PerformanceTransactionCommit
    )
    [pscustomobject][ordered]@{
        runNonce = $RunNonce
        candidate = [pscustomobject][ordered]@{
            commitSha = [string]$Candidate.source.commitSha
            treeSha = [string]$Candidate.source.treeSha
        }
        package = [pscustomobject][ordered]@{
            profileId = [string]$Candidate.profile.id
            receipt = [pscustomobject][ordered]@{
                relativePath = [string]$Candidate.receipt.relativePath
                bytes = [long]$Candidate.receipt.bytes
                fileSha256 = [string]$Candidate.receipt.fileSha256
                canonicalSha256 = [string]$Candidate.receipt.canonicalSha256
            }
            archive = [pscustomobject][ordered]@{
                relativePath = [string]$Candidate.archive.relativePath
                fileName = [string]$Candidate.archive.fileName
                bytes = [long]$Candidate.archive.bytes
                sha256 = [string]$Candidate.archive.sha256
            }
            packageRootRelativePath = [string]$Candidate.packageRootRelativePath
            components = [pscustomobject][ordered]@{
                app = [pscustomobject][ordered]@{
                    relativePath = [string]$Candidate.components.app.relativePath
                    bytes = [long]$Candidate.components.app.bytes
                    sha256 = [string]$Candidate.components.app.sha256
                }
                core = [pscustomobject][ordered]@{
                    relativePath = [string]$Candidate.components.core.relativePath
                    bytes = [long]$Candidate.components.core.bytes
                    sha256 = [string]$Candidate.components.core.sha256
                }
            }
        }
        profile = [pscustomobject][ordered]@{
            id = [string]$Candidate.profile.id
            relativePath = [string]$Candidate.profile.relativePath
            bytes = [long]$Candidate.profile.bytes
            fileSha256 = [string]$Candidate.profile.fileSha256
            canonicalSha256 = [string]$Candidate.profile.canonicalSha256
        }
        referenceHost = [pscustomobject][ordered]@{
            profileId = [string]$Candidate.referenceHost.profileId
            profileSha256 = [string]$Candidate.referenceHost.profileSha256
        }
        renderer = [pscustomobject][ordered]@{
            policy = [string]$Candidate.renderer.policy
            wpfProcessRenderMode = [string]$Candidate.renderer.wpfProcessRenderMode
            policySha256 = [string]$script:RendererPolicySha256
        }
        session = [pscustomobject][ordered]@{
            kind = [string]$Session.kind
            name = [string]$Session.name
            sessionId = [long]$Session.sessionId
            transport = [string]$Session.transport
            elevated = [bool]$Session.elevated
            userScope = [string]$Session.userScope
        }
        performanceTelemetryBinding = [pscustomobject][ordered]@{
            relativePath = [string]$PerformanceTelemetryBinding.relativePath
            bytes = [long]$PerformanceTelemetryBinding.bytes
            fileSha256 = [string]$PerformanceTelemetryBinding.fileSha256
            canonicalSha256 = [string]$PerformanceTelemetryBinding.canonicalSha256
        }
        performanceTransactionCommit = [pscustomobject][ordered]@{
            relativePath = [string]$PerformanceTransactionCommit.relativePath
            bytes = [long]$PerformanceTransactionCommit.bytes
            fileSha256 = [string]$PerformanceTransactionCommit.fileSha256
            canonicalSha256 = [string]$PerformanceTransactionCommit.canonicalSha256
        }
    }
}

function Get-RendererMatrixExpectedCheckValue {
    param([string]$Name)
    switch -CaseSensitive($Name){
        'os-build-matched'{return '26220'};'local-console'{return 'LocalConsole'};'non-elevated'{return 'false'};'single-user'{return 'SingleUser'}
        'ac-power-confirmed'{return 'AC'};'physical-monitor-count-one'{return '1'};'duration-60-minutes'{return '60'}
        default{return 'PASS'}
    }
}

function Assert-RendererPerformanceProvenance {
    param($Value,[string]$Context='Performance provenance')
    Assert-RendererExactProperties $Value @('runNonce','candidate','package','profile','referenceHost','renderer','session','performanceTelemetryBinding','performanceTransactionCommit') $Context
    if ($Value.runNonce -isnot [string] -or [string]$Value.runNonce -cnotmatch '^[0-9a-f]{32}$') { throw "$Context runNonce must be lowercase 32-hex." }
    Assert-RendererPerformanceJsonBinding $Value.performanceTelemetryBinding "$Context performance telemetry binding"
    Assert-RendererPerformanceJsonBinding $Value.performanceTransactionCommit "$Context performance transaction commit"

    Assert-RendererExactProperties $Value.candidate @('commitSha','treeSha') "$Context candidate"
    foreach ($name in @('commitSha','treeSha')) {
        if ($Value.candidate.$name -isnot [string] -or [string]$Value.candidate.$name -cnotmatch '^[0-9a-f]{40}$') {
            throw "$Context candidate $name must be lowercase 40-hex."
        }
    }

    Assert-RendererExactProperties $Value.package @('profileId','receipt','archive','packageRootRelativePath','components') "$Context package"
    Assert-RendererString $Value.package.profileId "$Context package profileId"
    if ($Value.package.profileId -cne $script:RendererPackageProfileId) { throw "$Context package profileId does not bind the approved v0.2 issue-149 package profile." }
    Assert-RendererPerformanceJsonBinding $Value.package.receipt "$Context package receipt"
    Assert-RendererExactProperties $Value.package.archive @('relativePath','fileName','bytes','sha256') "$Context package archive"
    Assert-RendererRelativePath $Value.package.archive.relativePath "$Context package archive relativePath"
    Assert-RendererString $Value.package.archive.fileName "$Context package archive fileName"
    Assert-RendererPositiveInteger $Value.package.archive.bytes "$Context package archive bytes"
    Assert-RendererSha $Value.package.archive.sha256 "$Context package archive sha256"
    Assert-RendererRelativePath $Value.package.packageRootRelativePath "$Context package root"
    Assert-RendererExactProperties $Value.package.components @('app','core') "$Context package components"
    foreach ($name in @('app','core')) {
        Assert-RendererExactProperties $Value.package.components.$name @('relativePath','bytes','sha256') "$Context package component $name"
        Assert-RendererRelativePath $Value.package.components.$name.relativePath "$Context package component $name relativePath"
        Assert-RendererPositiveInteger $Value.package.components.$name.bytes "$Context package component $name bytes"
        Assert-RendererSha $Value.package.components.$name.sha256 "$Context package component $name sha256"
    }

    Assert-RendererExactProperties $Value.profile @('id','relativePath','bytes','fileSha256','canonicalSha256') "$Context profile"
    Assert-RendererString $Value.profile.id "$Context profile id"
    if ($Value.profile.id -cne $script:RendererPackageProfileId) { throw "$Context profile id does not bind the approved v0.2 issue-149 package profile." }
    Assert-RendererRelativePath $Value.profile.relativePath "$Context profile relativePath"
    Assert-RendererPositiveInteger $Value.profile.bytes "$Context profile bytes"
    Assert-RendererSha $Value.profile.fileSha256 "$Context profile fileSha256"
    Assert-RendererSha $Value.profile.canonicalSha256 "$Context profile canonicalSha256"

    Assert-RendererExactProperties $Value.referenceHost @('profileId','profileSha256') "$Context referenceHost"
    Assert-RendererString $Value.referenceHost.profileId "$Context referenceHost profileId"
    Assert-RendererSha $Value.referenceHost.profileSha256 "$Context referenceHost profileSha256"
    if ($Value.referenceHost.profileId -cne $script:RendererProfileId -or $Value.referenceHost.profileSha256 -cne $script:RendererProfileSha256) { throw "$Context referenceHost does not bind the approved reference host profile." }

    Assert-RendererExactProperties $Value.renderer @('policy','wpfProcessRenderMode','policySha256') "$Context renderer"
    Assert-RendererString $Value.renderer.policy "$Context renderer policy"
    Assert-RendererString $Value.renderer.wpfProcessRenderMode "$Context renderer wpfProcessRenderMode"
    Assert-RendererSha $Value.renderer.policySha256 "$Context renderer policySha256"
    if ($Value.renderer.policy -cne 'software-only-process-wide' -or $Value.renderer.wpfProcessRenderMode -cne 'SoftwareOnly' -or $Value.renderer.policySha256 -cne $script:RendererPolicySha256) { throw "$Context renderer policy does not bind the approved SoftwareOnly policy." }

    Assert-RendererExactProperties $Value.session @('kind','name','sessionId','transport','elevated','userScope') "$Context session"
    foreach ($name in @('kind','name','transport','userScope')) {
        Assert-RendererString $Value.session.$name "$Context session $name"
    }
    Assert-RendererNonnegativeInteger $Value.session.sessionId "$Context session sessionId"
    Assert-RendererBoolean $Value.session.elevated "$Context session elevated"
}

function Assert-V02TrustedTelemetryPacket {
    param(
        [Parameter(Mandatory = $true)]
        $Packet,

        [Parameter(Mandatory = $true)]
        [string]$ExpectedNonce,

        [Parameter(Mandatory = $true)]
        [int]$ExpectedSequenceNumber,

        [Parameter(Mandatory = $true)]
        [int]$ExpectedBinIndex,

        [Parameter(Mandatory = $true)]
        [int]$ExpectedSampleIndex,

        [Parameter(Mandatory = $true)]
        [int]$ExpectedAppProcessId,

        [Parameter(Mandatory = $true)]
        [int]$ExpectedCoreProcessId,

        [Parameter(Mandatory = $true)]
        [DateTime]$ExpectedAppStartTimeUtc,

        [Parameter(Mandatory = $true)]
        [DateTime]$ExpectedCoreStartTimeUtc,

        [Parameter(Mandatory = $true)]
        [string]$ExpectedAppExecutablePath,

        [Parameter(Mandatory = $true)]
        [string]$ExpectedCoreExecutablePath,

        [Parameter(Mandatory = $true)]
        [string]$ExpectedAppExecutableSha256,

        [Parameter(Mandatory = $true)]
        [string]$ExpectedCoreExecutableSha256,

        [Parameter(Mandatory = $true)]
        [ref]$PreviousTimestampRef,

        [Parameter(Mandatory = $true)]
        [ref]$LatencyBaselineRef,

        [Parameter(Mandatory = $true)]
        [ref]$PreviousLatencyWatermarkRef,

        [Parameter(Mandatory = $true)]
        [ref]$LatencyBaselineRecordCountRef,

        [Parameter(Mandatory = $true)]
        [ref]$PreviousLatencyRecordCountRef,

        [Parameter(Mandatory = $false)]
        [string]$RepositoryRoot
    )

    Assert-RendererExactProperties $Packet @(
        'schemaVersion', 'nonce', 'sequenceNumber', 'observedUtc',
        'binIndex', 'sampleIndex', 'producer', 'metrics', 'packetSha256'
    ) 'Telemetry packet'
    Assert-RendererPositiveInteger $Packet.schemaVersion 'Telemetry packet schemaVersion'
    Assert-RendererNonnegativeInteger $Packet.sequenceNumber 'Telemetry packet sequenceNumber'
    Assert-RendererNonnegativeInteger $Packet.binIndex 'Telemetry packet binIndex'
    Assert-RendererNonnegativeInteger $Packet.sampleIndex 'Telemetry packet sampleIndex'

    if ($Packet.schemaVersion -ne 2) {
        throw "Telemetry packet schemaVersion must be 2; found $($Packet.schemaVersion)."
    }
    if ([string]$Packet.nonce -cne $ExpectedNonce) {
        throw "Telemetry packet nonce mismatch: expected '$ExpectedNonce', found '$($Packet.nonce)'."
    }
    if ([long]$Packet.sequenceNumber -ne [long]$ExpectedSequenceNumber) {
        throw "Telemetry packet sequenceNumber mismatch: expected $ExpectedSequenceNumber, found $($Packet.sequenceNumber)."
    }
    if ([int]$Packet.binIndex -ne $ExpectedBinIndex) {
        throw "Telemetry packet binIndex mismatch: expected $ExpectedBinIndex, found $($Packet.binIndex)."
    }
    if ([int]$Packet.sampleIndex -ne $ExpectedSampleIndex) {
        throw "Telemetry packet sampleIndex mismatch: expected $ExpectedSampleIndex, found $($Packet.sampleIndex)."
    }

    # Verify Producer binding
    $prod = $Packet.producer
    Assert-RendererExactProperties $prod @(
        'appProcessId', 'coreProcessId', 'appStartTimeUtc', 'coreStartTimeUtc',
        'appExecutablePath', 'coreExecutablePath', 'appExecutableSha256', 'coreExecutableSha256'
    ) 'Telemetry packet producer'
    Assert-RendererPositiveInteger $prod.appProcessId 'Telemetry packet producer appProcessId'
    Assert-RendererPositiveInteger $prod.coreProcessId 'Telemetry packet producer coreProcessId'
    Assert-RendererUtc $prod.appStartTimeUtc 'Telemetry packet producer appStartTimeUtc'
    Assert-RendererUtc $prod.coreStartTimeUtc 'Telemetry packet producer coreStartTimeUtc'

    if ([int]$prod.appProcessId -ne $ExpectedAppProcessId) {
        throw "Telemetry packet producer appProcessId mismatch: expected $ExpectedAppProcessId, found $($prod.appProcessId)."
    }
    if ([int]$prod.coreProcessId -ne $ExpectedCoreProcessId) {
        throw "Telemetry packet producer coreProcessId mismatch: expected $ExpectedCoreProcessId, found $($prod.coreProcessId)."
    }

    $pAppStart = [DateTimeOffset]::Parse([string]$prod.appStartTimeUtc, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::AssumeUniversal).UtcDateTime
    $pCoreStart = [DateTimeOffset]::Parse([string]$prod.coreStartTimeUtc, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::AssumeUniversal).UtcDateTime
    if ($pAppStart -ne $ExpectedAppStartTimeUtc.ToUniversalTime()) {
        throw "Telemetry packet producer appStartTimeUtc mismatch: expected '$($ExpectedAppStartTimeUtc.ToUniversalTime().ToString('o', [Globalization.CultureInfo]::InvariantCulture))', found '$($pAppStart.ToString('o', [Globalization.CultureInfo]::InvariantCulture))'."
    }
    if ($pCoreStart -ne $ExpectedCoreStartTimeUtc.ToUniversalTime()) {
        throw "Telemetry packet producer coreStartTimeUtc mismatch: expected '$($ExpectedCoreStartTimeUtc.ToUniversalTime().ToString('o', [Globalization.CultureInfo]::InvariantCulture))', found '$($pCoreStart.ToString('o', [Globalization.CultureInfo]::InvariantCulture))'."
    }

    if ([string]$prod.appExecutablePath -cne $ExpectedAppExecutablePath) {
        throw "Telemetry packet producer appExecutablePath mismatch."
    }
    if ([string]$prod.coreExecutablePath -cne $ExpectedCoreExecutablePath) {
        throw "Telemetry packet producer coreExecutablePath mismatch."
    }
    if ([string]$prod.appExecutableSha256 -cne $ExpectedAppExecutableSha256) {
        throw "Telemetry packet producer appExecutableSha256 mismatch."
    }
    if ([string]$prod.coreExecutableSha256 -cne $ExpectedCoreExecutableSha256) {
        throw "Telemetry packet producer coreExecutableSha256 mismatch."
    }

    # Verify Timestamps & Monotonicity
    Assert-RendererUtc $Packet.observedUtc 'Telemetry packet observedUtc'
    $sampleTime = [DateTimeOffset]::Parse([string]$Packet.observedUtc, [Globalization.CultureInfo]::InvariantCulture).UtcDateTime
    if ($PreviousTimestampRef.Value -ne [DateTime]::MinValue -and $sampleTime -le $PreviousTimestampRef.Value) {
        throw "Telemetry packet observedUtc is not strictly monotonic increasing ($($Packet.observedUtc) <= $($PreviousTimestampRef.Value.ToString('o', [Globalization.CultureInfo]::InvariantCulture)))."
    }
    # Verify Metrics
    $m = $Packet.metrics
    Assert-RendererExactProperties $m @('latency', 'uiStallMicroseconds', 'rendererStable') 'Telemetry packet metrics'
    Assert-RendererBoolean $m.rendererStable 'Telemetry packet rendererStable'

    $latency = $m.latency
    Assert-RendererExactProperties $latency @('baselineStateSequence','afterStateSequence','watermarkStateSequence','baselineRecordCount','afterRecordCount','recordCount','updates') 'Telemetry packet latency'
    foreach ($name in @('baselineStateSequence','afterStateSequence','watermarkStateSequence')) {
        if ($latency.$name -isnot [sbyte] -and $latency.$name -isnot [byte] -and
            $latency.$name -isnot [int16] -and $latency.$name -isnot [uint16] -and
            $latency.$name -isnot [int32] -and $latency.$name -isnot [uint32] -and
            $latency.$name -isnot [int64]) { throw "Telemetry packet latency $name must be an integer." }
        if ([long]$latency.$name -lt -1) { throw "Telemetry packet latency $name must be at least -1." }
    }
    $baseline = [long]$latency.baselineStateSequence
    $after = [long]$latency.afterStateSequence
    $watermark = [long]$latency.watermarkStateSequence
    foreach($name in @('baselineRecordCount','afterRecordCount','recordCount')){Assert-RendererNonnegativeInteger $latency.$name "Telemetry packet latency $name"}
    $baselineRecordCount=[long]$latency.baselineRecordCount;$afterRecordCount=[long]$latency.afterRecordCount;$recordCount=[long]$latency.recordCount
    if ($LatencyBaselineRef.Value -ne [long]::MinValue -and $baseline -ne [long]$LatencyBaselineRef.Value) {
        throw 'Telemetry packet latency admission baseline changed during the soak.'
    }
    $expectedAfter = if ($PreviousLatencyWatermarkRef.Value -eq [long]::MinValue) { $baseline } else { [long]$PreviousLatencyWatermarkRef.Value }
    if ($after -ne $expectedAfter -or $watermark -lt $after) {
        throw "Telemetry packet latency watermark continuity is invalid ($after -> $watermark, expected after $expectedAfter)."
    }
    if($LatencyBaselineRecordCountRef.Value-ne[long]::MinValue-and$baselineRecordCount-ne[long]$LatencyBaselineRecordCountRef.Value){throw 'Telemetry packet latency admission record count changed during the soak.'}
    $expectedAfterRecordCount=if($PreviousLatencyRecordCountRef.Value-eq[long]::MinValue){$baselineRecordCount}else{[long]$PreviousLatencyRecordCountRef.Value}
    if($afterRecordCount-ne$expectedAfterRecordCount-or$recordCount-lt$afterRecordCount){throw 'Telemetry packet latency record-count continuity is invalid.'}
    $updates = @($latency.updates)
    $canonicalUpdates = @()
    $seenSequences = @{}
    $seenCorrelations = @{}
    $lastUpdateSequence = $after
    foreach ($update in $updates) {
        Assert-RendererExactProperties $update @('stateSequence','eventCount','envelopeSequence','envelopeCorrelationId','stateSha256','updateKind','coreAcceptedStateUtc','ipcSentUtc','wpfAppliedUtc','latencyMicroseconds') 'Telemetry packet latency update'
        foreach ($name in @('stateSequence','eventCount','envelopeSequence','latencyMicroseconds')) { Assert-RendererNonnegativeInteger $update.$name "Telemetry packet latency update $name" }
        $stateSequence = [long]$update.stateSequence
        if ($stateSequence -le $baseline -or $stateSequence -le $lastUpdateSequence -or [long]$update.envelopeSequence -ne $stateSequence) { throw 'Telemetry packet latency updates are historical, replayed, reordered, or envelope-mismatched.' }
        if ([string]$update.updateKind -cnotin @('Snapshot','Delta')) { throw 'Telemetry packet latency update kind must be Snapshot or Delta.' }
        Assert-RendererSha $update.stateSha256 'Telemetry packet latency update stateSha256'
        $correlation = [Guid]::Empty
        if (-not [Guid]::TryParseExact([string]$update.envelopeCorrelationId, 'D', [ref]$correlation) -or $correlation -eq [Guid]::Empty) { throw 'Telemetry packet latency update correlation ID is invalid.' }
        if ($seenSequences.ContainsKey([string]$stateSequence) -or $seenCorrelations.ContainsKey($correlation.ToString('D'))) { throw 'Telemetry packet latency update identity is duplicated.' }
        $seenSequences[[string]$stateSequence]=$true;$seenCorrelations[$correlation.ToString('D')]=$true
        foreach ($name in @('coreAcceptedStateUtc','ipcSentUtc','wpfAppliedUtc')) { Assert-RendererUtc $update.$name "Telemetry packet latency update $name" }
        $accepted=[DateTimeOffset]::Parse([string]$update.coreAcceptedStateUtc,[Globalization.CultureInfo]::InvariantCulture)
        $sent=[DateTimeOffset]::Parse([string]$update.ipcSentUtc,[Globalization.CultureInfo]::InvariantCulture)
        $applied=[DateTimeOffset]::Parse([string]$update.wpfAppliedUtc,[Globalization.CultureInfo]::InvariantCulture)
        $derived=[long][Math]::Round(($applied-$accepted).TotalMilliseconds*1000.0)
        if ($sent -lt $accepted -or $applied -lt $sent -or $applied.UtcDateTime -gt $sampleTime -or [long]$update.latencyMicroseconds -ne $derived) { throw 'Telemetry packet latency update chronology or derived latency is invalid.' }
        $canonicalUpdates += [pscustomobject][ordered]@{stateSequence=$stateSequence;eventCount=[long]$update.eventCount;envelopeSequence=[long]$update.envelopeSequence;envelopeCorrelationId=$correlation.ToString('D');stateSha256=[string]$update.stateSha256;updateKind=[string]$update.updateKind;coreAcceptedStateUtc=[string]$update.coreAcceptedStateUtc;ipcSentUtc=[string]$update.ipcSentUtc;wpfAppliedUtc=[string]$update.wpfAppliedUtc;latencyMicroseconds=[long]$update.latencyMicroseconds}
        $lastUpdateSequence = $stateSequence
    }
    if (($updates.Count -eq 0 -and $watermark -ne $after) -or ($updates.Count -gt 0 -and $watermark -ne $lastUpdateSequence)) { throw 'Telemetry packet latency watermark does not equal its emitted update boundary.' }
    if([long]$updates.Count-ne($recordCount-$afterRecordCount)){throw 'Telemetry packet latency record count proves an omitted or extra update.'}
    $stalls = @($m.uiStallMicroseconds)
    if ($stalls.Count -lt 20) {
        throw "Telemetry packet requires at least 20 UI-stall observations; found $($stalls.Count)."
    }
    foreach ($stl in $stalls) {
        Assert-RendererNonnegativeInteger $stl 'Telemetry packet UI-stall sample'
    }

    # Verify packetSha256 integrity
    $rawPacketWithoutHash = [pscustomobject][ordered]@{
        schemaVersion = [int]$Packet.schemaVersion
        nonce = [string]$Packet.nonce
        sequenceNumber = [long]$Packet.sequenceNumber
        observedUtc = [string]$Packet.observedUtc
        binIndex = [int]$Packet.binIndex
        sampleIndex = [int]$Packet.sampleIndex
        producer = [pscustomobject][ordered]@{
            appProcessId = [int]$prod.appProcessId
            coreProcessId = [int]$prod.coreProcessId
            appStartTimeUtc = if ($prod.appStartTimeUtc -is [DateTime]) { $prod.appStartTimeUtc.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ss.fffffffZ', [Globalization.CultureInfo]::InvariantCulture) } else { [string]$prod.appStartTimeUtc }
            coreStartTimeUtc = if ($prod.coreStartTimeUtc -is [DateTime]) { $prod.coreStartTimeUtc.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ss.fffffffZ', [Globalization.CultureInfo]::InvariantCulture) } else { [string]$prod.coreStartTimeUtc }
            appExecutablePath = [string]$prod.appExecutablePath
            coreExecutablePath = [string]$prod.coreExecutablePath
            appExecutableSha256 = [string]$prod.appExecutableSha256
            coreExecutableSha256 = [string]$prod.coreExecutableSha256
        }
        metrics = [pscustomobject][ordered]@{
            latency = [pscustomobject][ordered]@{baselineStateSequence=$baseline;afterStateSequence=$after;watermarkStateSequence=$watermark;baselineRecordCount=$baselineRecordCount;afterRecordCount=$afterRecordCount;recordCount=$recordCount;updates=$canonicalUpdates}
            uiStallMicroseconds = @($stalls | ForEach-Object { [long]$_ })
            rendererStable = [bool]$m.rendererStable
        }
    }
    $canonicalBody = ConvertTo-RendererCanonicalJson $rawPacketWithoutHash $RepositoryRoot
    $expectedHash = Get-HumanDesignReviewSha256ForText $canonicalBody
    if ([string]$Packet.packetSha256 -cne $expectedHash) {
        throw "Telemetry packet SHA-256 hash mismatch: expected '$expectedHash', found '$($Packet.packetSha256)'."
    }
    if ($LatencyBaselineRef.Value -eq [long]::MinValue) { $LatencyBaselineRef.Value = $baseline }
    if ($LatencyBaselineRecordCountRef.Value -eq [long]::MinValue) { $LatencyBaselineRecordCountRef.Value = $baselineRecordCount }
    $PreviousLatencyWatermarkRef.Value = $watermark
    $PreviousLatencyRecordCountRef.Value = $recordCount
    $PreviousTimestampRef.Value = $sampleTime
}

function Get-V02LiveProcessIdentity {
    param(
        [Parameter(Mandatory = $true)]
        [System.Diagnostics.Process]$Process,

        [Parameter(Mandatory = $true)]
        [int]$ExpectedProcessId,

        [Parameter(Mandatory = $true)]
        [DateTime]$ExpectedStartTimeUtc,

        [Parameter(Mandatory = $true)]
        [ValidateSet('App', 'Core')]
        [string]$Role,

        [Parameter(Mandatory = $false)]
        [int]$BinIndex = 0,

        [Parameter(Mandatory = $false)]
        [int]$SampleIndex = 0
    )

    $hasExited = $false
    $observedProcessId = $ExpectedProcessId
    $observedStartTimeUtc = $null
    try {
        $Process.Refresh()
        $hasExited = [bool]$Process.HasExited
        if (-not $hasExited) {
            $observedProcessId = [int]$Process.Id
            $observedStartTimeUtc = $Process.StartTime.ToUniversalTime()
        }
    } catch {
        throw "$Role process identity observation failed during soak bin $BinIndex sample ${SampleIndex}: $($_.Exception.Message)"
    }

    if ($hasExited) {
        throw "$Role process ($ExpectedProcessId) terminated unexpectedly during soak bin $BinIndex sample $SampleIndex."
    }

    if ($observedProcessId -ne $ExpectedProcessId) {
        throw "$Role process PID continuity failed: expected PID $ExpectedProcessId, observed PID $observedProcessId during soak bin $BinIndex sample $SampleIndex."
    }

    if ($null -eq $observedStartTimeUtc -or $observedStartTimeUtc -ne $ExpectedStartTimeUtc) {
        throw "$Role process PID ($ExpectedProcessId) was recycled during soak bin $BinIndex sample $SampleIndex."
    }

    return [pscustomobject][ordered]@{
        ProcessId = [int]$observedProcessId
        HasExited = [bool]$hasExited
        StartTimeUtc = $observedStartTimeUtc
    }
}

function Get-RendererGovernedMatrixCases {
    return @(
        $script:RendererDisplayCases +
        $script:RendererMixedDpiCases +
        $script:RendererAccessibilityCases +
        $script:RendererEnvironmentCases
    )
}

function Assert-RendererLegacyMatrixRawPayload {
    param(
        [Parameter(Mandatory=$true)]$Payload,
        [Parameter(Mandatory=$true)][string]$ExpectedCaseId,
        [Parameter(Mandatory=$true)][string]$Context
    )
    throw "$Context legacy caller-authored outcome/evidenceClass matrix payloads are prohibited; schemaVersion 2 typed observations are required."
    if ($null -eq $Payload -or $Payload -isnot [pscustomobject]) { throw "$Context must be a JSON object." }

    $propNames = @($Payload.PSObject.Properties.Name)
    $requiredBase = @('schemaVersion','caseId','observedUtc','evidenceClass','outcome','details')
    foreach ($req in $requiredBase) {
        if (-not ($propNames -ccontains $req)) { throw "$Context omitted '$req'." }
    }

    Assert-RendererNonnegativeInteger $Payload.schemaVersion "$Context schemaVersion"
    if ([long]$Payload.schemaVersion -ne 1) { throw "$Context schemaVersion must be 1." }

    Assert-RendererString $Payload.caseId "$Context caseId"
    if ($Payload.caseId -cne $ExpectedCaseId) { throw "$Context caseId '$($Payload.caseId)' does not match expected caseId '$ExpectedCaseId'." }

    Assert-RendererUtc $Payload.observedUtc "$Context observedUtc"

    Assert-RendererString $Payload.evidenceClass "$Context evidenceClass"
    if ($Payload.evidenceClass -cnotin @('Static','Synthetic','Contract','Runtime')) {
        throw "$Context evidenceClass '$($Payload.evidenceClass)' is invalid or inflates release authority."
    }

    Assert-RendererString $Payload.outcome "$Context outcome"
    if ($Payload.outcome -cnotin @('PASS','FAIL')) {
        throw "$Context outcome '$($Payload.outcome)' must be exact PASS or FAIL."
    }

    Assert-RendererString $Payload.details "$Context details"

    $allowedProps = [System.Collections.Generic.List[string]]::new([string[]]$requiredBase)
    $allowedProps.Add('checksPassed')
    $allowedProps.Add('errorCount')

    if ($Payload.evidenceClass -ceq 'Runtime') {
        $allowedProps.Add('actualHerdrObserved')
        $allowedProps.Add('sessionKind')
        $allowedProps.Add('elevated')
        $allowedProps.Add('userScope')
        $allowedProps.Add('isSynthetic')

        foreach ($runtimeReq in @('actualHerdrObserved','sessionKind','elevated','userScope')) {
            if (-not ($propNames -ccontains $runtimeReq)) {
                throw "$Context claims unearned Runtime: omitted '$runtimeReq'."
            }
        }

        Assert-RendererBoolean $Payload.actualHerdrObserved "$Context actualHerdrObserved"
        if (-not [bool]$Payload.actualHerdrObserved) {
            throw "$Context claims unearned Runtime: actualHerdrObserved is false."
        }

        Assert-RendererString $Payload.sessionKind "$Context sessionKind"
        if ($Payload.sessionKind -cne 'LocalConsole') {
            throw "$Context claims unearned Runtime: sessionKind '$($Payload.sessionKind)' is not LocalConsole."
        }

        Assert-RendererBoolean $Payload.elevated "$Context elevated"
        if ([bool]$Payload.elevated) {
            throw "$Context claims unearned Runtime: session is elevated."
        }

        Assert-RendererString $Payload.userScope "$Context userScope"
        if ($Payload.userScope -cne 'SingleUser') {
            throw "$Context claims unearned Runtime: userScope '$($Payload.userScope)' is not SingleUser."
        }

        if ($propNames -ccontains 'isSynthetic') {
            Assert-RendererBoolean $Payload.isSynthetic "$Context isSynthetic"
            if ([bool]$Payload.isSynthetic) {
                throw "$Context claims unearned Runtime: isSynthetic is true."
            }
        }
    } else {
        if ($propNames -ccontains 'actualHerdrObserved') {
            Assert-RendererBoolean $Payload.actualHerdrObserved "$Context actualHerdrObserved"
            if ([bool]$Payload.actualHerdrObserved) {
                throw "$Context non-Runtime evidenceClass '$($Payload.evidenceClass)' contradicts actualHerdrObserved=true."
            }
            $allowedProps.Add('actualHerdrObserved')
        }
        if ($propNames -ccontains 'sessionKind') {
            Assert-RendererString $Payload.sessionKind "$Context sessionKind"
            $allowedProps.Add('sessionKind')
        }
        if ($propNames -ccontains 'elevated') {
            Assert-RendererBoolean $Payload.elevated "$Context elevated"
            $allowedProps.Add('elevated')
        }
        if ($propNames -ccontains 'userScope') {
            Assert-RendererString $Payload.userScope "$Context userScope"
            $allowedProps.Add('userScope')
        }
        if ($propNames -ccontains 'isSynthetic') {
            Assert-RendererBoolean $Payload.isSynthetic "$Context isSynthetic"
            $allowedProps.Add('isSynthetic')
        }
    }

    foreach ($name in $propNames) {
        if (-not $allowedProps.Contains($name)) {
            throw "$Context contains unexpected property '$name'."
        }
    }

    if ($propNames -ccontains 'checksPassed') {
        Assert-RendererBoolean $Payload.checksPassed "$Context checksPassed"
        if ($Payload.outcome -ceq 'PASS' -and -not [bool]$Payload.checksPassed) {
            throw "$Context forged PASS: outcome is PASS but checksPassed is false."
        }
    }

    if ($propNames -ccontains 'errorCount') {
        Assert-RendererNonnegativeInteger $Payload.errorCount "$Context errorCount"
        if ($Payload.outcome -ceq 'PASS' -and [long]$Payload.errorCount -gt 0) {
            throw "$Context forged PASS: outcome is PASS but errorCount is nonzero."
        }
    }

    return [pscustomobject][ordered]@{
        CaseId = [string]$Payload.caseId
        ObservedUtc = [string]$Payload.observedUtc
        EvidenceClass = [string]$Payload.evidenceClass
        Outcome = [string]$Payload.outcome
        Details = [string]$Payload.details
    }
}

function Assert-RendererMatrixRawPayload {
    param($Payload,[string]$ExpectedCaseId,[string]$Context,[string]$RepositoryRoot,[string]$EvidenceRoot)
    Assert-RendererNonnegativeInteger $Payload.schemaVersion "$Context schemaVersion";$rawSchema=[long]$Payload.schemaVersion;if($rawSchema-cnotin@(3,4)){throw "$Context schemaVersion must be 3 or 4."}
    $rawProperties=if($rawSchema-eq4){@('schemaVersion','caseId','observedUtc','run','observation','provenance','artifacts','details')}else{@('schemaVersion','caseId','observedUtc','run','observation','provenance','details')}
    Assert-RendererExactProperties $Payload $rawProperties $Context
    Assert-RendererString $Payload.caseId "$Context caseId";if($Payload.caseId-cne$ExpectedCaseId){throw "$Context caseId '$($Payload.caseId)' does not match expected caseId '$ExpectedCaseId'."}
    Assert-RendererUtc $Payload.observedUtc "$Context observedUtc";Assert-RendererString $Payload.details "$Context details"
    $run=$Payload.run;Assert-RendererExactProperties $run @('runId','startedUtc','endedUtc','sessionId','candidateCommitSha','candidateTreeSha','packageReceiptCanonicalSha256') "$Context run"
    foreach($name in @('runId','sessionId')){Assert-RendererString $run.$name "$Context run $name"};if($run.runId-cnotmatch'^[0-9A-Za-z][0-9A-Za-z._-]{7,127}$'-or$run.sessionId-cnotmatch'^[0-9A-Za-z][0-9A-Za-z._-]{7,127}$'){throw "$Context run/session identity is invalid."}
    Assert-RendererUtc $run.startedUtc "$Context run startedUtc";Assert-RendererUtc $run.endedUtc "$Context run endedUtc";foreach($name in @('candidateCommitSha','candidateTreeSha')){if([string]$run.$name-cnotmatch'^[0-9a-f]{40}$'-or[string]$run.$name-ceq('0'*40)){throw "$Context run $name must be a nonzero lowercase Git SHA."}};Assert-RendererSha $run.packageReceiptCanonicalSha256 "$Context run packageReceiptCanonicalSha256"
    $started=[DateTimeOffset]::Parse($run.startedUtc);$ended=[DateTimeOffset]::Parse($run.endedUtc);$observed=[DateTimeOffset]::Parse($Payload.observedUtc);if($ended-le$started-or($ended-$started).TotalHours-gt4-or$observed-lt$started-or$observed-gt$ended){throw "$Context observedUtc is outside the bounded common run window."}
    $contract=Get-RendererMatrixCaseContract $ExpectedCaseId
    Assert-RendererExactProperties $Payload.observation @('kind','target','checks') "$Context observation"
    if($Payload.observation.kind-cne$contract.Kind-or$Payload.observation.target-cne$ExpectedCaseId){throw "$Context observation type/target does not match the governed case contract."}
    $allPassed=$true;$checks=@($Payload.observation.checks)
    if($checks.Count-ne$contract.Checks.Count){throw "$Context observation checks do not match the governed case contract."}
    for($i=0;$i-lt$contract.Checks.Count;$i++){$check=$checks[$i];Assert-RendererExactProperties $check @('name','observedValue') "$Context observation check $i";if($check.name-cne$contract.Checks[$i]){throw "$Context observation check $i must be '$($contract.Checks[$i])'."};Assert-RendererString $check.observedValue "$Context observation check '$($check.name)' observedValue";if($check.observedValue-cne(Get-RendererMatrixExpectedCheckValue $check.name)){$allPassed=$false}}
    $artifacts=@();if($rawSchema-eq4){$artifacts=@($Payload.artifacts)}
    if($rawSchema-eq4-and$contract.Kind-ceq'Display'){
        if($artifacts.Count-ne1){throw "$Context display observation must bind exactly one off-screen PNG artifact."}
        $artifact=$artifacts[0];Assert-RendererExactProperties $artifact @('kind','relativePath','bytes','sha256','widthPixels','heightPixels') "$Context display artifact"
        if($artifact.kind-cne'OffscreenPng'){throw "$Context display artifact kind must be OffscreenPng."};Assert-RendererRelativePath $artifact.relativePath "$Context display artifact path";Assert-RendererPositiveInteger $artifact.bytes "$Context display artifact bytes";Assert-RendererSha $artifact.sha256 "$Context display artifact SHA-256";Assert-RendererPositiveInteger $artifact.widthPixels "$Context display artifact width";Assert-RendererPositiveInteger $artifact.heightPixels "$Context display artifact height"
        $dimensions=$ExpectedCaseId.Split('-')[0].Split('x');if([long]$artifact.widthPixels-ne[long]$dimensions[0]-or[long]$artifact.heightPixels-ne[long]$dimensions[1]){throw "$Context display artifact dimensions do not equal the governed viewport."}
        $artifactPath=Resolve-RendererBoundPath $EvidenceRoot ([string]$artifact.relativePath) "$Context display artifact";$artifactIdentity=Get-RendererStableFileIdentity $EvidenceRoot $artifactPath "$Context display artifact";if($artifactIdentity.Bytes-ne[long]$artifact.bytes-or$artifactIdentity.Sha256-cne[string]$artifact.sha256){throw "$Context display artifact byte/hash binding failed."};$png=Get-RendererPngIdentity $EvidenceRoot $artifactPath "$Context display artifact";$content=Test-RendererMatrixPngContent $png.Frame "$Context display artifact";if(-not$content.Pass){throw "$Context display artifact is blank, transparent, uniform, or lacks bounded rendered content."}
    }elseif($rawSchema-eq4-and$artifacts.Count-ne0){throw "$Context non-display observation cannot claim display artifacts."}
    $p=$Payload.provenance;Assert-RendererString $p.kind "$Context provenance kind";$evidenceClass=$null
    if($p.kind-cin@('StaticInspection','SyntheticFixture','ContractHarness')){
        Assert-RendererExactProperties $p @('kind','collector','actualHerdrObserved') "$Context provenance";Assert-RendererBoolean $p.actualHerdrObserved "$Context provenance actualHerdrObserved";if([bool]$p.actualHerdrObserved){throw "$Context non-Runtime provenance contradicts actualHerdrObserved=true."}
        $collector=switch -CaseSensitive($p.kind){'StaticInspection'{'RendererMatrixStaticInspector'};'SyntheticFixture'{'RendererMatrixSyntheticFixture'};'ContractHarness'{'RendererMatrixContractHarness'}};if($p.collector-cne$collector){throw "$Context provenance collector does not match kind '$($p.kind)'."}
        $evidenceClass=switch -CaseSensitive($p.kind){'StaticInspection'{'Static'};'SyntheticFixture'{'Synthetic'};'ContractHarness'{'Contract'}}
    }elseif($p.kind-ceq'AutomatedPackagedRendering'){
        if($rawSchema-ne4){throw "$Context automated packaged rendering requires schemaVersion 4 with bound pixel artifacts."}
        Assert-RendererExactProperties $p @('kind','collector','actualHerdrObserved','candidate','session','operator','observer') "$Context provenance"
        Assert-RendererBoolean $p.actualHerdrObserved "$Context provenance actualHerdrObserved"
        if([bool]$p.actualHerdrObserved-or$p.collector-cne'RendererMatrixAutomatedPackagedCollector'){throw "$Context automated packaged rendering must not claim ActualHerdr Runtime."}
        Assert-RendererExactProperties $p.candidate @('commitSha','treeSha','packageReceiptCanonicalSha256') "$Context provenance candidate"
        if($p.candidate.commitSha-cne$run.candidateCommitSha-or$p.candidate.treeSha-cne$run.candidateTreeSha-or$p.candidate.packageReceiptCanonicalSha256-cne$run.packageReceiptCanonicalSha256){throw "$Context automated rendering candidate/package binding does not equal the common run."}
        Assert-RendererExactProperties $p.session @('sessionId','kind','elevated','userScope','processId','processStartUtc','executableRelativePath','executableSha256') "$Context provenance session"
        Assert-RendererBoolean $p.session.elevated "$Context provenance session elevated"
        if($p.session.sessionId-cne$run.sessionId-or$p.session.kind-cne'AutomatedPackaged'-or[bool]$p.session.elevated-or$p.session.userScope-cne'SingleUser'){throw "$Context automated packaged rendering requires the exact non-elevated single-user packaged session."}
        Assert-RendererPositiveInteger $p.session.processId "$Context provenance session processId";Assert-RendererUtc $p.session.processStartUtc "$Context provenance session processStartUtc";Assert-RendererRelativePath $p.session.executableRelativePath "$Context provenance session executable path";Assert-RendererSha $p.session.executableSha256 "$Context provenance session executable SHA-256";$executablePath=Resolve-RendererBoundPath $EvidenceRoot ([string]$p.session.executableRelativePath) "$Context provenance session executable";$executableIdentity=Get-RendererStableFileIdentity $EvidenceRoot $executablePath "$Context provenance session executable";if($executableIdentity.Sha256-cne[string]$p.session.executableSha256){throw "$Context automated collector executable hash binding failed."}
        foreach($role in @(@{Value=$p.operator;Name='operator';Expected='EvidenceOperator'},@{Value=$p.observer;Name='observer';Expected='IndependentAgentReviewer'})){
            Assert-RendererExactProperties $role.Value @('identity','role') "$Context provenance $($role.Name)";Assert-RendererString $role.Value.identity "$Context provenance $($role.Name) identity";if($role.Value.role-cne$role.Expected){throw "$Context provenance $($role.Name) role is invalid."}
        }
        if($p.operator.identity.Trim().Equals($p.observer.identity.Trim(),[StringComparison]::OrdinalIgnoreCase)){throw "$Context automated rendering operator and independent Agent reviewer must be distinct."}
        $evidenceClass='AutomatedPackagedRendering'
    }elseif($p.kind-ceq'ActualHerdrRuntime'){
        throw "$Context claims unearned Runtime: caller-authored matrix payloads cannot establish independently observed Herdr/App/Core/session/semantic provenance; a trusted production runtime collector receipt is required."
    }else{throw "$Context provenance kind '$($p.kind)' is not governed."}
    $runFingerprint=@($run.runId,$run.startedUtc,$run.endedUtc,$run.sessionId,$run.candidateCommitSha,$run.candidateTreeSha,$run.packageReceiptCanonicalSha256)-join'|'
    return [pscustomobject][ordered]@{CaseId=[string]$Payload.caseId;ObservedUtc=[string]$Payload.observedUtc;EvidenceClass=$evidenceClass;Outcome=if($allPassed){'PASS'}else{'FAIL'};Details=[string]$Payload.details;RunFingerprint=$runFingerprint;RunStartedUtc=[string]$run.startedUtc;RunEndedUtc=[string]$run.endedUtc;CandidateCommitSha=[string]$run.candidateCommitSha;CandidateTreeSha=[string]$run.candidateTreeSha;PackageReceiptCanonicalSha256=[string]$run.packageReceiptCanonicalSha256;AppExecutableSha256=if($evidenceClass-ceq'AutomatedPackagedRendering'){[string]$p.session.executableSha256}else{$null};OperatorIdentity=if($evidenceClass-ceq'AutomatedPackagedRendering'){[string]$p.operator.identity}else{$null};ObserverIdentity=if($evidenceClass-ceq'AutomatedPackagedRendering'){[string]$p.observer.identity}else{$null}}
}

function Assert-RendererStableFileLease { param($Lease,[string]$Root,[string]$Path,[string]$Context)
    if($null-eq$Lease.Stream-or$Lease.Stream.SafeFileHandle.IsClosed-or$Lease.Stream.SafeFileHandle.IsInvalid){throw "$Context raw evidence lease is not held."}
    $heldFinal=[IO.Path]::GetFullPath([RendererCompatibility.NativePath]::GetFinalPath($Lease.Stream.SafeFileHandle));$heldId=[RendererCompatibility.NativePath]::GetIdentity($Lease.Stream.SafeFileHandle);$heldLinks=[long][RendererCompatibility.NativePath]::GetLinkCount($Lease.Stream.SafeFileHandle)
    if($heldFinal-cne$Lease.FinalPath-or$heldId-cne$Lease.FileIdentity-or$heldLinks-ne1){throw "$Context held raw evidence FinalPath/FileId/link-count changed."}
    $probe=Get-RendererStableFileIdentity $Root $Path "$Context current path"
    if($probe.FinalPath-cne$Lease.FinalPath-or$probe.FileIdentity-cne$Lease.FileIdentity-or$probe.LinkCount-ne1-or$probe.Bytes-ne$Lease.Bytes-or$probe.Sha256-cne$Lease.Sha256){throw "$Context path no longer resolves to the held raw evidence identity."}
}

function Assert-RendererPerformanceJsonBinding {
    param($Value,[string]$Context)
    Assert-RendererExactProperties $Value @('relativePath','bytes','fileSha256','canonicalSha256') $Context
    Assert-RendererRelativePath $Value.relativePath "$Context relativePath"
    Assert-RendererPositiveInteger $Value.bytes "$Context bytes"
    Assert-RendererSha $Value.fileSha256 "$Context fileSha256"
    Assert-RendererSha $Value.canonicalSha256 "$Context canonicalSha256"
}
