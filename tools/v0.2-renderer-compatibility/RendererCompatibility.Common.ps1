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
using System.Runtime.InteropServices;
using System.Text;
using Microsoft.Win32.SafeHandles;
namespace RendererCompatibility {
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

        public static SafeFileHandle OpenDirectory(string path, bool allowDelete) {
            const uint DeleteAccess = 0x00010000, ShareRead = 1, ShareWrite = 2, OpenExisting = 3;
            const uint BackupSemantics = 0x02000000, OpenReparsePoint = 0x00200000;
            SafeFileHandle result = CreateFile(path, allowDelete ? DeleteAccess : 0, ShareRead | ShareWrite, IntPtr.Zero, OpenExisting, BackupSemantics | OpenReparsePoint, IntPtr.Zero);
            if (result.IsInvalid) { int error = Marshal.GetLastWin32Error(); result.Dispose(); throw new Win32Exception(error, "CreateFile directory lease failed for " + path); }
            return result;
        }

        public static void RenameDirectory(SafeFileHandle handle, string destinationPath) {
            byte[] name = Encoding.Unicode.GetBytes(destinationPath);
            int rootOffset = IntPtr.Size == 8 ? 8 : 4;
            int lengthOffset = IntPtr.Size == 8 ? 16 : 8;
            int nameOffset = IntPtr.Size == 8 ? 20 : 12;
            int size = nameOffset + name.Length + 2;
            IntPtr buffer = Marshal.AllocHGlobal(size);
            try {
                for (int i = 0; i < size; i++) Marshal.WriteByte(buffer, i, 0);
                Marshal.WriteIntPtr(buffer, rootOffset, IntPtr.Zero);
                Marshal.WriteInt32(buffer, lengthOffset, name.Length);
                Marshal.Copy(name, 0, IntPtr.Add(buffer, nameOffset), name.Length);
                if (!SetFileInformationByHandle(handle, 3, buffer, (uint)size)) throw new Win32Exception(Marshal.GetLastWin32Error(), "Held-handle directory rename failed");
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
$script:RendererCaptureModes = @('LiveOperator', 'SyntheticSelfTest')
$script:RendererDisplayCases = @(
    '1920x1080-100', '1920x1080-125', '1920x1080-150',
    '1366x768-100', '1366x768-125', '1366x768-150')
$script:RendererAccessibilityCases = @(
    'keyboard-uia', 'narrator', 'high-contrast', 'text-scale-100',
    'text-scale-150', 'text-scale-200', 'reduced-motion-on', 'reduced-motion-off')
$script:RendererMixedDpiCases = @(
    'mixed-dpi-100-to-150-primary-switch-unplug', 'mixed-dpi-150-to-100-primary-switch-unplug',
    'mixed-dpi-125-to-150-primary-switch-unplug', 'mixed-dpi-150-to-125-primary-switch-unplug')
$script:RendererEnvironmentCases = @(
    'windows11-x64-build26220-local-console-non-elevated-single-user',
    'physical-mixed-dpi-primary-switch-unplug', 'ac-power', 'battery-power',
    'soak-ac-60-minutes', 'soak-battery-60-minutes', 'thermal-observation')
$script:RendererVisualChecks = @(
    'no-blank-black-transparent-surface', 'no-missing-glyph', 'no-clipping-overlap',
    'status-meaning-preserved', 'brand-hierarchy-preserved',
    'single-selected-language', 'literal-identifiers-unchanged')
$script:RendererMaximumManifestBytes = 2MB
$script:RendererAuthorizedApprovalReference = 'https://github.com/OSHEThai/HerdrOps/issues/149#issuecomment-5380637664'
$script:RendererDecisionId = 'herdrops-rec-all-v2'
$script:RendererDecisionApprovedUtc = '2026-08-22T13:18:21.2468994Z'
$script:RendererDecisionCorrectedUtc = '2026-08-22T13:23:04.5923226Z'
$script:RendererDecisionPayloadSha256 = '48474610D2A20EE2F7CA2DAC0A3CCF45F919440C9C5D81EF5BA93AD7E524F62D'
$script:RendererSupersedesDecisionId = 'herdrops-rec-all-v1'
$script:RendererSupersedesPayloadSha256 = 'DD8EB4D4BC896BE6A4765D409C5E34A16C4DBFB3D70F437EC915A50DF2FC1B1E'
$script:RendererAuthorizedReviewerIdentity = '@yutthaphon'
$script:RendererAuthorizedReviewerRole = 'HumanReviewer'
$script:RendererAuthorizedFinalHumanGoReference = $null
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
    $rootItem=Get-Item -LiteralPath $rootFull -Force -ErrorAction Stop;if(($rootItem.Attributes-band[IO.FileAttributes]::ReparsePoint)-ne0){throw "$Context evidence root is a reparse point."}
    $relative=$pathFull.Substring($rootFull.Length).TrimStart('\','/');$probe=$rootFull
    foreach($part in @($relative-split'[\\/]'|Where-Object{$_-ne''})){$probe=Join-Path $probe $part;if(Test-Path -LiteralPath $probe){$item=Get-Item -LiteralPath $probe -Force -ErrorAction Stop;if(($item.Attributes-band[IO.FileAttributes]::ReparsePoint)-ne0){throw "$Context contains a reparse point: $probe"}}}
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
    $probe=Open-RendererDirectoryLease $Root $expected "$Context current path"
    try {
        if($probe.Identity-cne$Lease.Identity-or$probe.FinalPath-cne$Lease.FinalPath){throw "$Context path no longer resolves to the held directory identity."}
    } finally {$probe.Handle.Dispose()}
}
function Move-RendererLeasedDirectory {
    param($Lease,[string]$Root,[string]$Path,[string]$Destination,[string]$Context)
    if(-not$Lease.DeleteAccess){throw "$Context directory lease lacks held-handle rename access."}
    Assert-RendererDirectoryLease $Lease $Root $Path "$Context before held-handle rename"
    [RendererCompatibility.NativePath]::RenameDirectory($Lease.Handle,[IO.Path]::GetFullPath($Destination))
    $movedFinal=[IO.Path]::GetFullPath([RendererCompatibility.NativePath]::GetFinalPath($Lease.Handle)).TrimEnd('\','/')
    $destinationFull=[IO.Path]::GetFullPath($Destination).TrimEnd('\','/')
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

    Add-Type -AssemblyName System.Windows.Forms -ErrorAction Stop
    $screens = @([System.Windows.Forms.Screen]::AllScreens)
    if ($screens.Count -lt 1) { throw 'No physical display was observed.' }
    $primaryCandidates = @($screens | Where-Object { $_.Primary })
    $primary = if ($primaryCandidates.Count -gt 0) { $primaryCandidates[0] } else { $screens[0] }

    $controllers = @(
        Get-CimInstance -ClassName Win32_VideoController -ErrorAction Stop |
            Where-Object {
                $_.CurrentHorizontalResolution -gt 0 -and
                $_.CurrentVerticalResolution -gt 0 -and
                $_.CurrentRefreshRate -gt 0
            } |
            Sort-Object PNPDeviceID)
    $displayCandidates = @($controllers | Where-Object {
        [int]$_.CurrentHorizontalResolution -eq [int]$primary.Bounds.Width -or
        [int]$_.CurrentVerticalResolution -eq [int]$primary.Bounds.Height
    })
    $displayController = if ($displayCandidates.Count -gt 0) { $displayCandidates[0] } elseif ($controllers.Count -gt 0) { $controllers[0] } else { $null }
    if ($null -eq $displayController) {
        throw 'The active display did not expose physical resolution and refresh rate.'
    }
    $physicalWidth = [int]$displayController.CurrentHorizontalResolution
    $physicalHeight = [int]$displayController.CurrentVerticalResolution
    $logicalWidth = [int]$primary.Bounds.Width
    $logicalHeight = [int]$primary.Bounds.Height
    if ($physicalWidth -le 0 -or $physicalHeight -le 0 -or $logicalWidth -le 0 -or $logicalHeight -le 0) {
        throw 'The active display exposed invalid dimensions.'
    }
    $desktopDpi = [int][Math]::Round(96.0 * $physicalWidth / $logicalWidth)
    $scalePercent = [int][Math]::Round(100.0 * $desktopDpi / 96.0)

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
        display = [ordered]@{
            deviceName = [string]$primary.DeviceName
            physicalWidthPixels = $physicalWidth
            physicalHeightPixels = $physicalHeight
            logicalWidthPixels = $logicalWidth
            logicalHeightPixels = $logicalHeight
            desktopAppliedDpi = $desktopDpi
            scalePercent = $scalePercent
            refreshRateHz = [int]$displayController.CurrentRefreshRate
            monitorCount = [int]$screens.Count
        }
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
            supported = @('windows11-x64-build26220','local-console','non-elevated','single-user','physical-display-matrix','ac-power','battery-power')
            excluded = @('rdp-runtime','vm-runtime','arm64','remote-cloud','multi-user')
            vmCleanInstallOnly = $true
            vmRuntimeCredit = $false
        }
    }
}
function Assert-RendererEnvironmentSnapshot {
    param($Environment,[string]$Context='Environment')
    Assert-RendererExactProperties $Environment @('os','graphicsAdapters','display','session','supportScope') $Context
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
    Assert-RendererExactProperties $Environment.display @('deviceName','physicalWidthPixels','physicalHeightPixels','logicalWidthPixels','logicalHeightPixels','desktopAppliedDpi','scalePercent','refreshRateHz','monitorCount') "$Context display"
    Assert-RendererString $Environment.display.deviceName "$Context display deviceName"
    foreach ($name in @('physicalWidthPixels','physicalHeightPixels','logicalWidthPixels','logicalHeightPixels','desktopAppliedDpi','scalePercent','refreshRateHz','monitorCount')) { Assert-RendererPositiveInteger $Environment.display.$name "$Context display $name" }
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
    Assert-RendererSet @($support.supported) @('windows11-x64-build26220','local-console','non-elevated','single-user','physical-display-matrix','ac-power','battery-power') "$Context supported scope"
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
    $display = $reference.environmentBinding.activeDisplay
    if ([string]$Environment.os.caption -cne [string]$referenceHost.operatingSystemCaption -or
        [string]$Environment.os.version -cne [string]$referenceHost.operatingSystemVersion -or
        [int]$Environment.os.build -ne [int]$referenceHost.operatingSystemBuild -or
        [string]$Environment.os.architecture -cne [string]$referenceHost.architecture) { throw 'Observed live OS does not match the approved reference-host profile.' }
    if ([string]$Environment.display.deviceName -cne [string]$display.primaryDisplayDeviceName -or
        [int]$Environment.display.physicalWidthPixels -ne [int]$display.physicalWidthPixels -or
        [int]$Environment.display.physicalHeightPixels -ne [int]$display.physicalHeightPixels -or
        [int]$Environment.display.logicalWidthPixels -ne [int]$display.logicalWidthPixels -or
        [int]$Environment.display.logicalHeightPixels -ne [int]$display.logicalHeightPixels -or
        [int]$Environment.display.desktopAppliedDpi -ne [int]$display.desktopAppliedDpi -or
        [int]$Environment.display.scalePercent -ne [int]$display.scalePercent -or
        [int]$Environment.display.refreshRateHz -ne [int]$display.refreshRateHz -or
        [int]$Environment.display.monitorCount -ne [int]$display.activeMonitorCount) { throw 'Observed live display does not match the approved reference-host profile.' }
    $expectedAdapters = @($reference.environmentBinding.graphicsAdapters | Sort-Object pnpDeviceId)
    $actualAdapters = @($Environment.graphicsAdapters | Sort-Object pnpDeviceId)
    if ($actualAdapters.Count -ne $expectedAdapters.Count) { throw 'Observed live graphics adapter count does not match the approved reference-host profile.' }
    for ($i = 0; $i -lt $actualAdapters.Count; $i++) {
        foreach ($name in @('displayName','pnpDeviceId','driverVersion')) {
            if ([string]$actualAdapters[$i].$name -cne [string]$expectedAdapters[$i].$name) { throw "Observed live graphics adapter '$name' does not match the approved reference-host profile." }
        }
    }
}
function Get-RendererStableFileIdentity { param([string]$Root,[string]$Path,[string]$Context,[switch]$IncludeBytes)
    $rootFull=[IO.Path]::GetFullPath($Root).TrimEnd('\','/');$pathFull=[IO.Path]::GetFullPath($Path);Assert-RendererNonReparsePath $rootFull $pathFull $Context
    $stream=New-Object IO.FileStream($pathFull,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read)
    try{
        $final=[IO.Path]::GetFullPath([RendererCompatibility.NativePath]::GetFinalPath($stream.SafeFileHandle));if($final-cne$rootFull-and-not$final.StartsWith($rootFull+[IO.Path]::DirectorySeparatorChar,[StringComparison]::OrdinalIgnoreCase)){throw "$Context final opened path escaped the evidence root."}
        $before=$stream.Length;$algorithm=[Security.Cryptography.SHA256]::Create();try{$hash=([BitConverter]::ToString($algorithm.ComputeHash($stream))).Replace('-','').ToUpperInvariant()}finally{$algorithm.Dispose()};$after=$stream.Length;if($before-ne$after-or$stream.Position-ne$after){throw "$Context changed during the same-handle read."}
        $bytes=$null;if($IncludeBytes){if($after-gt$script:RendererMaximumManifestBytes){throw "$Context exceeds the bounded read."};$stream.Position=0;$bytes=New-Object byte[] ([int]$after);$offset=0;while($offset-lt$bytes.Length){$read=$stream.Read($bytes,$offset,$bytes.Length-$offset);if($read-le0){throw "$Context ended during the same-handle read."};$offset+=$read}}
        return [pscustomobject]@{Bytes=[long]$after;Sha256=$hash;Content=$bytes;FinalPath=$final}
    }finally{$stream.Dispose()}
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
function Get-RendererWindowObservation { param([int]$TargetAppPid,[string]$TargetAppStartTimeUtc,[string]$Context)
    try {
        $process = Get-Process -Id $TargetAppPid -ErrorAction Stop
        $process.Refresh()
        $hwnd = [Int64][RendererCompatibility.NativePath]::GetProcessMainWindow($TargetAppPid)
        if ($hwnd -eq 0) { $hwnd = [Int64]$process.MainWindowHandle }
    } catch {
        throw "$Context target App window could not be observed: $($_.Exception.Message)"
    }
    if ($hwnd -eq 0) { return [pscustomobject][ordered]@{hasAnyHwnd=$false;hwnd=[long]0;ownerPid=[int]0;ownerStartTimeUtc=$null} }
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
    New-Object IO.Pipes.NamedPipeServerStream($Name,[IO.Pipes.PipeDirection]::InOut,1,[IO.Pipes.PipeTransmissionMode]::Byte,[IO.Pipes.PipeOptions]::Asynchronous)
}
function Wait-RendererTargetObservationPipe { param($Pipe,[int]$TimeoutSeconds=30)
    $async=$Pipe.BeginWaitForConnection($null,$null)
    if (-not $async.AsyncWaitHandle.WaitOne($TimeoutSeconds*1000)) { throw "Target observation pipe did not connect within $TimeoutSeconds seconds." }
    $Pipe.EndWaitForConnection($async)
    [RendererCompatibility.NativePath]::GetPipeClientProcessId($Pipe.SafePipeHandle.DangerousGetHandle())
}
function Read-RendererTargetPipeLine { param([IO.StreamReader]$Reader,[int]$TimeoutSeconds=30)
    $task=$Reader.ReadLineAsync()
    if (-not $task.Wait($TimeoutSeconds*1000)) { throw "Target observation pipe response timed out after $TimeoutSeconds seconds." }
    $line=$task.GetAwaiter().GetResult()
    if ([string]::IsNullOrWhiteSpace($line)) { throw 'Target observation pipe closed without a response.' }
    $line
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
    for($i=0;$i-lt$captureBindings.Count;$i++){$capture=$captureBindings[$i];Assert-RendererExactProperties $capture @('language','name','relativePath','bytes','sha256','widthPixels','heightPixels','observedUtc','producerPid','producerStartUtc') "Target capture $i";$actualKeys+="$($capture.language)|$($capture.name)";Assert-RendererRelativePath $capture.relativePath "Target capture $i path";Assert-RendererPositiveInteger $capture.bytes "Target capture $i bytes";Assert-RendererSha $capture.sha256 "Target capture $i SHA-256";Assert-RendererPositiveInteger $capture.widthPixels "Target capture $i width";Assert-RendererPositiveInteger $capture.heightPixels "Target capture $i height";Assert-RendererUtc $capture.observedUtc "Target capture $i UTC";Assert-RendererPositiveInteger $capture.producerPid "Target capture $i producer PID";Assert-RendererUtc $capture.producerStartUtc "Target capture $i producer start";if($capture.producerPid-ne$Receipt.appProcess.pid-or$capture.producerStartUtc-cne$Receipt.appProcess.startTimeUtc){throw "Target capture $i producer identity does not equal the App PID/start identity."};$manifestCapture=$Manifest.captures[$i];foreach($name in @('language','name','relativePath','bytes','sha256','widthPixels','heightPixels','observedUtc')){if($capture.$name-cne$manifestCapture.$name){throw "Target capture $i does not equal manifest capture '$name'."}}}
    for($i=0;$i-lt$expectedKeys.Count;$i++){if($actualKeys[$i]-cne$expectedKeys[$i]){throw "Target capture index $i is not '$($expectedKeys[$i])'."}}
}
function Get-RendererPngIdentity { param([string]$Root,[string]$Path,[string]$Context)
    $identity=Get-RendererStableFileIdentity $Root $Path $Context -IncludeBytes;$stream=New-Object IO.MemoryStream(,$identity.Content);try{$decoder=New-Object Windows.Media.Imaging.PngBitmapDecoder($stream,[Windows.Media.Imaging.BitmapCreateOptions]::PreservePixelFormat,[Windows.Media.Imaging.BitmapCacheOption]::OnLoad);if($decoder.Frames.Count-ne1){throw "$Context must decode as exactly one PNG frame."};$frame=$decoder.Frames[0];if($frame.PixelWidth-le0-or$frame.PixelHeight-le0){throw "$Context decoded PNG dimensions are invalid."};return [pscustomobject]@{Width=[int]$frame.PixelWidth;Height=[int]$frame.PixelHeight;Bytes=$identity.Bytes;Sha256=$identity.Sha256;Content=$identity.Content;Frame=$frame}}catch{throw "$Context is not a complete decodable PNG: $($_.Exception.Message)"}finally{$stream.Dispose()}
}
function Assert-RendererFileBinding { param($Binding,[string]$Context,[string]$Root,[switch]$ValidateBindings)
    Assert-RendererExactProperties $Binding @('relativePath','bytes','sha256') $Context
    Assert-RendererRelativePath $Binding.relativePath "$Context relativePath"; Assert-RendererPositiveInteger $Binding.bytes "$Context bytes"; Assert-RendererSha $Binding.sha256 "$Context sha256"
    if($ValidateBindings){$full=Resolve-RendererBoundPath $Root $Binding.relativePath "$Context relativePath";if(-not(Test-Path -LiteralPath $full -PathType Leaf)){throw "$Context file is missing."};$identity=Get-RendererStableFileIdentity $Root $full $Context;if($identity.Bytes-ne[long]$Binding.bytes){throw "$Context byte count mismatch."};if($identity.Sha256-cne[string]$Binding.sha256){throw "$Context SHA-256 mismatch."}}
}
function Read-RendererEvidenceReceipt { param($Binding,[string]$Context,[string]$Root,[string]$RepositoryRoot)
    Assert-RendererExactProperties $Binding @('relativePath','bytes','fileSha256','canonicalSha256') "$Context binding";Assert-RendererRelativePath $Binding.relativePath "$Context path";Assert-RendererPositiveInteger $Binding.bytes "$Context bytes";Assert-RendererSha $Binding.fileSha256 "$Context raw hash";Assert-RendererSha $Binding.canonicalSha256 "$Context canonical hash";$path=Resolve-RendererBoundPath $Root $Binding.relativePath "$Context path";$stable=Get-RendererStableFileIdentity $Root $path $Context -IncludeBytes;if($stable.Bytes-ne[long]$Binding.bytes-or$stable.Sha256-cne$Binding.fileSha256){throw "$Context raw binding failed."};$json=(New-Object Text.UTF8Encoding($false,$true)).GetString($stable.Content);$value=ConvertFrom-StrictHumanDesignReviewJson -Json $json -Description $Context;if($PSVersionTable.PSVersion.Major-ge7-and(Get-Command ConvertFrom-Json).Parameters.ContainsKey('DateKind')){$value=$json|ConvertFrom-Json -DateKind String};$canonical=ConvertTo-RendererCanonicalJson $value $RepositoryRoot;$canonicalSha=Get-HumanDesignReviewSha256ForText $canonical;if($json-cne($canonical+"`n")-or$canonicalSha-cne$Binding.canonicalSha256){throw "$Context must be exact canonical JSON plus one LF with matching canonical SHA-256."};[pscustomobject]@{Value=$value;Stable=$stable;CanonicalSha256=$canonicalSha}
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
    Assert-RendererExactProperties $Profile.approval @('decisionId','approvalReference','approvedUtc','payloadSha256') 'Package profile approval';if($Profile.approval.decisionId-cne$script:RendererDecisionId-or$Profile.approval.approvalReference-cne$script:RendererAuthorizedApprovalReference-or$Profile.approval.approvedUtc-cne$script:RendererDecisionApprovedUtc-or$Profile.approval.payloadSha256-cne$script:RendererDecisionPayloadSha256){throw 'Package profile approval does not equal REC-ALL v2.'}
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
function Assert-RendererMatrixCases { param([object[]]$Cases,[string[]]$Expected,[string]$Context,[string]$Root,[string]$RepositoryRoot,[switch]$ValidateBindings)
    if([string]::IsNullOrWhiteSpace($Root)){$Root=$script:RendererCurrentEvidenceRoot};if([string]::IsNullOrWhiteSpace($RepositoryRoot)){$RepositoryRoot=$script:RendererCurrentRepositoryRoot};if($script:RendererCurrentValidateBindings){$ValidateBindings=$true}
    Assert-RendererSet @($Cases|ForEach-Object{$_.id}) $Expected "$Context IDs"
    foreach($case in $Cases){Assert-RendererExactProperties $case @('id','status','evidenceReceipt','notes') "$Context '$($case.id)'";Assert-RendererString $case.id "$Context id";if([string]$case.status -cnotin @('PASS','FAIL','NOT_OBSERVED')){throw "$Context '$($case.id)' status is invalid."};if($case.status-ceq'NOT_OBSERVED'){if($null-ne$case.evidenceReceipt-or$null-ne$case.notes){throw "$Context '$($case.id)' NOT_OBSERVED must not claim evidence."}}else{Assert-RendererString $case.notes "$Context '$($case.id)' notes";if(-not$ValidateBindings){throw "$Context '$($case.id)' observed status requires production binding validation."};$receipt=(Read-RendererEvidenceReceipt $case.evidenceReceipt "$Context '$($case.id)' receipt" $Root $RepositoryRoot).Value;Assert-RendererExactProperties $receipt @('caseId','observations','aggregateStatus') "$Context receipt";if($receipt.caseId-cne$case.id-or$receipt.aggregateStatus-cnotin@('PASS','FAIL')){throw "$Context '$($case.id)' receipt identity/status is invalid."};$observations=@($receipt.observations);if($observations.Count-lt1){throw "$Context '$($case.id)' receipt omitted raw observations."};$allPass=$true;for($i=0;$i-lt$observations.Count;$i++){$o=$observations[$i];Assert-RendererExactProperties $o @('ordinal','observedUtc','outcome','notes') "$Context '$($case.id)' observation $i";Assert-RendererNonnegativeInteger $o.ordinal 'Matrix observation ordinal';if([long]$o.ordinal-ne$i){throw "$Context '$($case.id)' observation ordering is invalid."};Assert-RendererUtc $o.observedUtc 'Matrix observation UTC';if($o.outcome-cnotin@('PASS','FAIL')){throw "$Context '$($case.id)' observation outcome is invalid."};Assert-RendererString $o.notes 'Matrix observation notes';if($o.outcome-cne'PASS'){$allPass=$false}};$computed=if($allPass){'PASS'}else{'FAIL'};if($receipt.aggregateStatus-cne$computed-or$case.status-cne$computed){throw "$Context '$($case.id)' status is not recomputed from raw observations."}}}
}
function Get-RendererP95Microseconds { param($Values,[string]$Context)
    $items=@($Values);if($items.Count-ne20){throw "$Context must contain exactly 20 raw observations; missing or extra samples fail closed."};foreach($value in $items){Assert-RendererNonnegativeInteger $value "$Context observation"};$sorted=@($items|Sort-Object {[long]$_});return [long]$sorted[[Math]::Ceiling(0.95*$sorted.Count)-1]
}
function Assert-RendererPerformanceReceipt { param($Binding,[string]$Root,[string]$RepositoryRoot,$Limits)
    $receipt=(Read-RendererEvidenceReceipt $Binding 'Performance/soak evidence receipt' $Root $RepositoryRoot).Value;Assert-RendererExactProperties $receipt @('orders','soakBins','aggregateStatus') 'Performance receipt';$passed=$true;$orders=@($receipt.orders);if($orders.Count-ne2){throw 'Performance receipt must contain exact AB and BA orders.'};for($oi=0;$oi-lt2;$oi++){$order=$orders[$oi];Assert-RendererExactProperties $order @('order','repetitions') "Performance order $oi";$expectedOrder=@('AB','BA')[$oi];if($order.order-cne$expectedOrder){throw "Performance order $oi is not $expectedOrder."};$reps=@($order.repetitions);if($reps.Count-ne5){throw "Performance order $expectedOrder must contain five raw repetitions."};for($ri=0;$ri-lt5;$ri++){$rep=$reps[$ri];Assert-RendererExactProperties $rep @('ordinal','observedUtc','a','b') "Performance $expectedOrder repetition $ri";Assert-RendererNonnegativeInteger $rep.ordinal 'Performance ordinal';if([long]$rep.ordinal-ne$ri){throw 'Performance repetition ordinal is invalid.'};Assert-RendererUtc $rep.observedUtc 'Performance repetition UTC';$derived=@{};foreach($modeName in @('a','b')){$sample=$rep.$modeName;Assert-RendererExactProperties $sample @('cpuBasisPoints','workingSetMaximumBytes','latencyMicroseconds','uiStallMicroseconds') "Performance $modeName sample";Assert-RendererNonnegativeInteger $sample.cpuBasisPoints "Performance $modeName CPU";Assert-RendererNonnegativeInteger $sample.workingSetMaximumBytes "Performance $modeName working set";$latencyP95=Get-RendererP95Microseconds $sample.latencyMicroseconds "Performance $modeName latency";$stallP95=Get-RendererP95Microseconds $sample.uiStallMicroseconds "Performance $modeName UI stall";$stallMaximum=[long](@($sample.uiStallMicroseconds|Sort-Object {[long]$_})[-1]);$derived[$modeName]=[pscustomobject]@{Cpu=[double]$sample.cpuBasisPoints/100;WorkingSet=[long]$sample.workingSetMaximumBytes;LatencyP95=[double]$latencyP95/1000;StallP95=[double]$stallP95/1000;StallMaximum=[double]$stallMaximum/1000}};$a=$derived.a;$b=$derived.b;$cpuDelta=$b.Cpu-$a.Cpu;$cpuPercent=if($a.Cpu-gt0){100*$cpuDelta/$a.Cpu}else{[double]::PositiveInfinity};$latencyPercent=if($a.LatencyP95-gt0){100*($b.LatencyP95-$a.LatencyP95)/$a.LatencyP95}else{[double]::PositiveInfinity};if($b.Cpu-gt[double]$Limits.cpuMaximumPercent-or$cpuDelta-gt[double]$Limits.cpuRegressionMaximumPercentagePoints-or$cpuPercent-gt[double]$Limits.cpuRegressionMaximumPercent-or$b.LatencyP95-gt[double]$Limits.eventToWpfP95Milliseconds-or$latencyPercent-gt[double]$Limits.latencyRegressionMaximumPercent-or$b.StallP95-gt[double]$Limits.uiStallP95Milliseconds-or$b.StallMaximum-gt[double]$Limits.uiStallMaximumMilliseconds-or$b.WorkingSet-gt[long]$Limits.workingSetMaximumBytes){$passed=$false}}}
    $bins=@($receipt.soakBins);if($bins.Count-ne24){throw 'Performance receipt must contain exact 24 five-minute soak bins.'};for($i=0;$i-lt24;$i++){$bin=$bins[$i];Assert-RendererExactProperties $bin @('powerSource','ordinal','durationMinutes','observedUtc','workingSetStartBytes','workingSetEndBytes','rendererStable') "Soak bin $i";$expectedPower=if($i-lt12){'AC'}else{'Battery'};$expectedOrdinal=$i%12;if($bin.powerSource-cne$expectedPower){throw "Soak bin $i power source is invalid."};Assert-RendererNonnegativeInteger $bin.ordinal 'Soak ordinal';Assert-RendererPositiveInteger $bin.durationMinutes 'Soak duration';Assert-RendererNonnegativeInteger $bin.workingSetStartBytes 'Soak start working set';Assert-RendererNonnegativeInteger $bin.workingSetEndBytes 'Soak end working set';Assert-RendererBoolean $bin.rendererStable 'Soak renderer stability';Assert-RendererUtc $bin.observedUtc 'Soak observed UTC';if([long]$bin.ordinal-ne$expectedOrdinal-or[long]$bin.durationMinutes-ne5-or-not[bool]$bin.rendererStable){$passed=$false};$slope=[Math]::Abs([double]$bin.workingSetEndBytes-[double]$bin.workingSetStartBytes)*2;if([long]$bin.workingSetStartBytes-gt[long]$Limits.workingSetMaximumBytes-or[long]$bin.workingSetEndBytes-gt[long]$Limits.workingSetMaximumBytes-or$slope-gt[double]$Limits.resourceSlopeMaximumBytesPerTenMinutes){$passed=$false}}
    $computed=if($passed){'PASS'}else{'FAIL'};if($receipt.aggregateStatus-cne$computed){throw 'Performance receipt aggregateStatus is not recomputed from raw AB/BA samples and soak bins.'};return $computed
}
function Get-RendererBgraPixels { param($Frame)
    $converted=New-Object Windows.Media.Imaging.FormatConvertedBitmap($Frame,[Windows.Media.PixelFormats]::Bgra32,$null,0);$stride=$converted.PixelWidth*4;$pixels=New-Object byte[] ($stride*$converted.PixelHeight);$converted.CopyPixels($pixels,$stride,0);[pscustomobject]@{Width=$converted.PixelWidth;Height=$converted.PixelHeight;Pixels=$pixels}
}
function Compare-RendererPixels { param($Capture,$Reference,[object[]]$Masks,[string]$CaptureKey)
    $a=Get-RendererBgraPixels $Capture.Frame;$b=Get-RendererBgraPixels $Reference.Frame;if($a.Width-ne$b.Width-or$a.Height-ne$b.Height){throw "Comparison '$CaptureKey' capture/reference dimensions differ."};$masked=New-Object bool[] ($a.Width*$a.Height);foreach($mask in @($Masks|Where-Object{$_.captureKeys-ccontains$CaptureKey})){$m=Get-RendererBgraPixels $mask.Frame;if($m.Width-ne$a.Width-or$m.Height-ne$a.Height){throw "Comparison '$CaptureKey' mask dimensions differ."};for($p=0;$p-lt$masked.Length;$p++){if($m.Pixels[$p*4+3]-gt0-or$m.Pixels[$p*4]-gt0-or$m.Pixels[$p*4+1]-gt0-or$m.Pixels[$p*4+2]-gt0){$masked[$p]=$true}}};$maskCount=@($masked|Where-Object{$_}).Count;if($maskCount-ge$masked.Length){throw "Comparison '$CaptureKey' mask cannot cover the full frame."};for($y=0;$y-lt$a.Height-1;$y++){for($x=0;$x-lt$a.Width-1;$x++){$p=$y*$a.Width+$x;if($masked[$p]-and$masked[$p+1]-and$masked[$p+$a.Width]-and$masked[$p+$a.Width+1]){throw "Comparison '$CaptureKey' mask exceeds the approved one-pixel anti-aliasing geometry."}}};$different=0;$nonmasked=0;$maximum=0;$actualDifferences=New-Object bool[] $masked.Length;for($p=0;$p-lt$masked.Length;$p++){$delta=0;for($c=0;$c-lt4;$c++){$d=[Math]::Abs([int]$a.Pixels[$p*4+$c]-[int]$b.Pixels[$p*4+$c]);if($d-gt$delta){$delta=$d}};if($delta-gt0){$different++;$actualDifferences[$p]=$true;if($delta-gt$maximum){$maximum=$delta}};if(-not$masked[$p]-and$delta-gt0){$nonmasked++}};for($p=0;$p-lt$masked.Length;$p++){if(-not$masked[$p]){continue};$x=$p%$a.Width;$y=[Math]::Floor($p/$a.Width);$near=$false;for($dy=-1;$dy-le1-and-not$near;$dy++){for($dx=-1;$dx-le1;$dx++){$nx=$x+$dx;$ny=$y+$dy;if($nx-ge0-and$ny-ge0-and$nx-lt$a.Width-and$ny-lt$a.Height-and$actualDifferences[$ny*$a.Width+$nx]){$near=$true;break}}};if(-not$near){throw "Comparison '$CaptureKey' mask pixel is outside the approved one-pixel difference neighborhood."}};[pscustomobject]@{DifferentPixels=[long]$different;DifferentPixelPercent=([double]$different*100/$masked.Length);MaximumChannelDelta=[int]$maximum;NonmaskedDifferenceCount=[long]$nonmasked}
}

function Test-RendererCandidateBindings { param($Candidate,[string]$Root,[string]$RepositoryRoot)
    $git=Get-RendererGitIdentity $RepositoryRoot;if($git.CommitSha-cne$Candidate.source.commitSha-or$git.TreeSha-cne$Candidate.source.treeSha){throw 'Candidate source does not equal the exact repository HEAD commit/tree.'}
    $repoRoot=[IO.Path]::GetFullPath($RepositoryRoot);$repoProfilePath=Join-Path $repoRoot 'tools\packaging\v0.2\package-identity-profile.json';$repoProfile=Read-RendererPackageProfile $repoProfilePath;$repoProfileIdentity=Get-RendererPackageProfileIdentity $repoProfilePath $repoProfile $repoRoot;if($Candidate.profile.relativePath-cne$repoProfileIdentity.RelativePath-or$repoProfileIdentity.Bytes-ne[long]$Candidate.profile.bytes-or$repoProfileIdentity.FileSha256-cne$Candidate.profile.fileSha256-or$repoProfileIdentity.CanonicalSha256-cne$Candidate.profile.canonicalSha256){throw 'Candidate package profile does not equal the exact profile in the bound repository.'};Assert-RendererPackageProfile $repoProfile
    $receiptPath=Resolve-RendererBoundPath $Root $Candidate.receipt.relativePath 'Candidate package receipt path';$receiptRaw=Get-RendererStableFileIdentity $Root $receiptPath 'Candidate package receipt' -IncludeBytes;if($receiptRaw.Bytes-ne[long]$Candidate.receipt.bytes-or$receiptRaw.Sha256-cne$Candidate.receipt.fileSha256){throw 'Candidate package receipt raw file binding failed.'};$receipt=Read-RendererCanonicalPackageReceipt $receiptPath $repoRoot;if($receipt.ReceiptSha256-cne$Candidate.receipt.canonicalSha256){throw 'Candidate package receipt canonical SHA-256 mismatch.'};Assert-RendererPackageReceipt $receipt.Identity $Candidate
    $archivePath=Resolve-RendererBoundPath $Root $Candidate.archive.relativePath 'Candidate archive path';$packageRoot=Resolve-RendererBoundPath $Root $Candidate.packageRootRelativePath 'Candidate package root';if(-not(Test-Path -LiteralPath $packageRoot -PathType Container)){throw 'Candidate package root is missing.'}
    $validated=Assert-RendererCommittedPackageIdentity $receipt.Identity $repoProfile $repoRoot $archivePath $packageRoot $repoProfilePath $receipt.ReceiptSha256 $receipt.CanonicalJson
    $expected=[ordered]@{ReceiptSha256=$Candidate.receipt.canonicalSha256;SourceCommit=$Candidate.source.commitSha;SourceTree=$Candidate.source.treeSha;PreparationProfileFileSha256=$Candidate.profile.fileSha256;PreparationProfileCanonicalSha256=$Candidate.profile.canonicalSha256;ArchiveSha256=$Candidate.archive.sha256;AppSha256=$Candidate.components.app.sha256;CoreSha256=$Candidate.components.core.sha256;ReferenceHostProfileSha256=$Candidate.referenceHost.profileSha256;RendererPolicySha256=$script:RendererPolicySha256};foreach($name in $expected.Keys){if($validated.$name-cne$expected[$name]){throw "Committed package validator output '$name' does not equal the renderer candidate."}};if($validated.ProfileId-cne$Candidate.profile.id-or$validated.EvidenceClass-cne'Static/PackagedCompatibilityPreparation'-or$validated.Runtime-cne'NOT OBSERVED'-or$validated.Release-cne'NOT CLAIMED'){throw 'Committed package validator output classification/identity is invalid.'}
    return $git
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
    if([long]$manifest.manifestVersion-ne1-or[long]$manifest.issue-ne149-or$manifest.'$id'-cne$script:RendererSchemaId-or$manifest.evidenceClassification-cne'PackagedCompatibilityCandidate'){throw 'Manifest identity or evidence classification is invalid.'}
    Assert-RendererExactProperties $manifest.governance @('decisionId','approvalReference','originalApprovedUtc','correctedUtc','decisionPayloadSha256','supersedesDecisionId','supersedesPayloadSha256') 'Governance';if($manifest.governance.decisionId-cne$script:RendererDecisionId-or$manifest.governance.approvalReference-cne$script:RendererAuthorizedApprovalReference-or$manifest.governance.originalApprovedUtc-cne$script:RendererDecisionApprovedUtc-or$manifest.governance.correctedUtc-cne$script:RendererDecisionCorrectedUtc-or$manifest.governance.decisionPayloadSha256-cne$script:RendererDecisionPayloadSha256-or$manifest.governance.supersedesDecisionId-cne$script:RendererSupersedesDecisionId-or$manifest.governance.supersedesPayloadSha256-cne$script:RendererSupersedesPayloadSha256){throw 'Governance does not equal the exact REC-ALL v2 authority record.'}

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
    if ($captureMode -eq 'LiveOperator') { Assert-RendererLiveEnvironment $environment $RepositoryRoot; if ($null -eq $renderer.targetBindingReceipt) { throw 'LiveOperator renderer evidence requires a bound target-process receipt.' }; $targetReceipt=(Read-RendererEvidenceReceipt $renderer.targetBindingReceipt 'Target binding receipt' $root $RepositoryRoot).Value; Assert-RendererTargetBindingReceipt $targetReceipt $manifest } elseif ($null -ne $renderer.targetBindingReceipt) { throw 'Synthetic renderer evidence cannot contain a target-process receipt.' }

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

    $matrices=$manifest.matrices;Assert-RendererExactProperties $matrices @('displayCases','mixedDpiTransitions','accessibilityCases','supportedEnvironmentCases') 'Matrices';Assert-RendererMatrixCases @($matrices.displayCases) $script:RendererDisplayCases 'Display matrix' $root $RepositoryRoot -ValidateBindings:$ValidateBindings;Assert-RendererMatrixCases @($matrices.mixedDpiTransitions) $script:RendererMixedDpiCases 'Mixed-DPI matrix' $root $RepositoryRoot -ValidateBindings:$ValidateBindings;Assert-RendererMatrixCases @($matrices.accessibilityCases) $script:RendererAccessibilityCases 'Accessibility matrix' $root $RepositoryRoot -ValidateBindings:$ValidateBindings;Assert-RendererMatrixCases @($matrices.supportedEnvironmentCases) $script:RendererEnvironmentCases 'Supported-environment matrix' $root $RepositoryRoot -ValidateBindings:$ValidateBindings
    $matrixComplete=@($matrices.displayCases+$matrices.mixedDpiTransitions+$matrices.accessibilityCases+$matrices.supportedEnvironmentCases|Where-Object{$_.status-cne'PASS'}).Count-eq0

    $performance=$manifest.performanceProtocol;Assert-RendererExactProperties $performance @('sameCandidateContentWorkloadHostSession','onlyRendererPolicyVaries','modeA','modeB','orders','warmupIterations','repetitionsPerOrder','statistic','ownerNumericLimits','samplesStatus','evidenceReceipt') 'Performance protocol';Assert-RendererBoolean $performance.sameCandidateContentWorkloadHostSession 'Performance same binding';Assert-RendererBoolean $performance.onlyRendererPolicyVaries 'Performance only renderer varies';if(-not[bool]$performance.sameCandidateContentWorkloadHostSession-or-not[bool]$performance.onlyRendererPolicyVaries-or$performance.modeA-cne'Hardware'-or$performance.modeB-cne'SoftwareOnly'){throw 'Performance protocol must compare Hardware A with SoftwareOnly B on the same binding.'};Assert-RendererSet @($performance.orders) @('AB','BA') 'Performance order';for($i=0;$i-lt2;$i++){if($performance.orders[$i]-cne@('AB','BA')[$i]){throw 'Performance order must be exact AB, BA.'}};Assert-RendererPositiveInteger $performance.warmupIterations 'Warm-up iterations';Assert-RendererPositiveInteger $performance.repetitionsPerOrder 'Repetitions';Assert-RendererString $performance.statistic 'Performance statistic'
    $limitNames=@('cpuMaximumPercent','eventToWpfP95Milliseconds','cpuRegressionMaximumPercent','cpuRegressionMaximumPercentagePoints','latencyRegressionMaximumPercent','uiStallP95Milliseconds','uiStallMaximumMilliseconds','soakAcDurationMinutes','soakBatteryDurationMinutes','soakBinMinutes','workingSetMaximumBytes','resourceSlopeMaximumBytesPerTenMinutes');$limits=$performance.ownerNumericLimits;Assert-RendererExactProperties $limits (@('status','approvalReference')+$limitNames) 'Owner numeric limits';if($limits.status-cnotin@('NOT_OBSERVED','APPROVED')){throw 'Owner numeric-limit status is invalid.'};if($limits.status-ceq'NOT_OBSERVED'){foreach($n in @('approvalReference')+$limitNames){if($null-ne$limits.$n){throw 'Unapproved owner numeric limits must remain null.'}}}else{if($limits.approvalReference-cne$script:RendererAuthorizedApprovalReference){throw 'Owner numeric limits do not bind REC-ALL v2.'};$expectedLimits=[ordered]@{cpuMaximumPercent=1;eventToWpfP95Milliseconds=250;cpuRegressionMaximumPercent=10;cpuRegressionMaximumPercentagePoints=0.5;latencyRegressionMaximumPercent=10;uiStallP95Milliseconds=50;uiStallMaximumMilliseconds=100;soakAcDurationMinutes=60;soakBatteryDurationMinutes=60;soakBinMinutes=5;workingSetMaximumBytes=267386880;resourceSlopeMaximumBytesPerTenMinutes=1048576};foreach($n in $limitNames){Assert-RendererFiniteNumber $limits.$n "Owner numeric limit $n" 0 ([double]::MaxValue) -ExclusiveMinimum;if([decimal]$limits.$n-ne[decimal]($expectedLimits[$n])){throw "Owner numeric limit $n does not equal REC-ALL v2."}};foreach($n in @('workingSetMaximumBytes','resourceSlopeMaximumBytesPerTenMinutes')){Assert-RendererPositiveInteger $limits.$n "Owner numeric limit $n"}};if($performance.warmupIterations-ne1-or$performance.repetitionsPerOrder-ne5-or$performance.statistic-cne'p95-and-maximum-missing-sample-fails'){throw 'Performance repetitions/statistic do not equal REC-ALL v2.'};if($performance.samplesStatus-cnotin@('PASS','FAIL','NOT_OBSERVED')){throw 'Performance samples status is invalid.'};if($performance.samplesStatus-ceq'NOT_OBSERVED'){if($null-ne$performance.evidenceReceipt){throw 'Unobserved performance samples cannot claim a receipt.'}}else{if($limits.status-cne'APPROVED'-or-not$ValidateBindings){throw 'Performance samples require approved limits and production binding validation.'};$computedPerformance=Assert-RendererPerformanceReceipt $performance.evidenceReceipt $root $RepositoryRoot $limits;if($performance.samplesStatus-cne$computedPerformance){throw 'Performance samplesStatus does not equal independently recomputed raw evidence.'}}

    $review=$manifest.review;Assert-RendererExactProperties $review @('decision','approvalReference','reviewerIdentity','reviewerRole','reviewedUtc','visualChecks','defects') 'Review';if($review.decision-cnotin@('GO','NO_GO','NOT_OBSERVED')){throw 'Review decision is invalid.'};Assert-RendererMatrixCases @($review.visualChecks) $script:RendererVisualChecks 'Human visual review';$visualReviewComplete=@($review.visualChecks|Where-Object{$_.status-cne'PASS'}).Count-eq0;if($review.decision-ceq'NOT_OBSERVED'){if($null-ne$review.approvalReference-or$null-ne$review.reviewerIdentity-or$null-ne$review.reviewerRole-or$null-ne$review.reviewedUtc-or@($review.visualChecks|Where-Object{$_.status-cne'NOT_OBSERVED'}).Count-ne0){throw 'Unobserved review cannot claim approval/reviewer/time/checks.'}}else{if([string]::IsNullOrWhiteSpace($script:RendererAuthorizedFinalHumanGoReference)-or$review.approvalReference-cne$script:RendererAuthorizedFinalHumanGoReference){throw 'Final Human packaged-compatibility review remains NOT_OBSERVED and is not authorized by REC-ALL.'};if($review.reviewerIdentity-cne$script:RendererAuthorizedReviewerIdentity-or$review.reviewerRole-cne$script:RendererAuthorizedReviewerRole){throw 'Human review identity/role does not equal the hard-pinned REC-ALL authority.'};Assert-RendererUtc $review.reviewedUtc 'Review UTC';if(($review.decision-ceq'GO')-ne$visualReviewComplete){throw 'Human review decision contradicts the exact visual checks.'}};$defectIds=@();$defectsComplete=$true;foreach($defect in @($review.defects)){Assert-RendererExactProperties $defect @('id','severity','summary','status','disposition') 'Defect';$defectIds+=[string]$defect.id;Assert-RendererString $defect.id 'Defect id';if($defect.severity-cnotin@('P0','P1','P2','P3')-or$defect.status-cnotin@('Open','Resolved','Accepted')){throw "Defect '$($defect.id)' enum is invalid."};Assert-RendererString $defect.summary 'Defect summary';Assert-RendererString $defect.disposition 'Defect disposition';if($defect.status-ceq'Open'){$defectsComplete=$false}};if((@($defectIds|Select-Object -Unique)).Count-ne$defectIds.Count){throw 'Defect IDs must be unique.'};if($review.decision-ceq'GO'-and-not$defectsComplete){throw 'Human GO cannot retain an open defect.'}
    $boundary=$manifest.evidenceBoundary;Assert-RendererExactProperties $boundary @('packagedCompatibility','captureMode','humanReview','actualHerdrRuntime','release','creditGranted') 'Evidence boundary';if($boundary.captureMode-cnotin$script:RendererCaptureModes){throw 'Evidence boundary captureMode is invalid.'};if($boundary.packagedCompatibility-cne'CANDIDATE'-or$boundary.humanReview-cne$review.decision-or$boundary.actualHerdrRuntime-cne'NOT_OBSERVED'-or$boundary.release-cne'NOT_OBSERVED'-or$boundary.creditGranted-isnot[bool]-or[bool]$boundary.creditGranted){throw 'Evidence boundary inflates or contradicts the candidate classification.'}
    if($ValidateBindings){$finalGit=Test-RendererCandidateBindings $candidate $root $RepositoryRoot;if($finalGit.CommitSha-cne$boundGit.CommitSha-or$finalGit.TreeSha-cne$boundGit.TreeSha){throw 'Candidate repository identity changed during validation.'}}
    $authorityProfileConsistent=$script:RendererRecAllReferenceHostSha256-ceq$script:RendererProfileSha256
    $finalHumanAuthorityConfigured=-not[string]::IsNullOrWhiteSpace($script:RendererAuthorizedFinalHumanGoReference)
    $ready=[bool]$ValidateBindings-and$authorityProfileConsistent-and$finalHumanAuthorityConfigured-and$visualComplete-and$matrixComplete-and$limits.status-ceq'APPROVED'-and$performance.samplesStatus-ceq'PASS'-and$review.decision-ceq'GO'-and$visualReviewComplete-and$defectsComplete
    [pscustomobject][ordered]@{EvidenceClassification='PackagedCompatibilityCandidate';CaptureMode=[string]$boundary.captureMode;ManifestVersion=1;StructuralValidation='PASS';BindingValidation=if($ValidateBindings){'PASS'}else{'NOT_REQUESTED'};GovernanceProfileConsistency=if($authorityProfileConsistent){'PASS'}else{'FAIL'};FinalHumanGoAuthority=if($finalHumanAuthorityConfigured){'CONFIGURED'}else{'NOT_OBSERVED'};OwnerNumericLimits=$limits.status;HumanReview=$review.decision;ActualHerdrRuntime='NOT_OBSERVED';Release='NOT_OBSERVED';CreditGranted=$false;PackagedCompatibilityReadyForIssue149Closure=$ready}
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
    param([Parameter(Mandatory=$true)][string[]]$Ids)
    return @($Ids | ForEach-Object {
        [pscustomobject][ordered]@{
            id = $_
            status = 'NOT_OBSERVED'
            evidenceReceipt = $null
            notes = $null
        }
    })
}
