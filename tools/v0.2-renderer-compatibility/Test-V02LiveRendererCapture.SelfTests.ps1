#requires -Version 5.1

[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$previousSelfTestMarker = [Environment]::GetEnvironmentVariable('HERDROPS_RENDERER_SELFTEST', 'Process')
[Environment]::SetEnvironmentVariable('HERDROPS_RENDERER_SELFTEST', '1', 'Process')

$invokeSource = Get-Content -Raw -LiteralPath (Join-Path $PSScriptRoot 'Invoke-V02LiveRendererCapture.ps1')
if ($invokeSource -match 'AllowElevatedForTesting|AllowNonReferenceHostForTesting|\[switch\]\$Force') {
    throw 'Production renderer capture script still exposes an unguarded testing bypass.'
}

. (Join-Path $PSScriptRoot 'RendererCompatibility.Common.ps1')

$script:PositiveCases = 0
$script:NegativeCases = 0

function Pass([string]$Name) {
    $script:PositiveCases++
    Write-Host "PASS positive: $Name"
}

function Pass-Negative([string]$Name) {
    $script:NegativeCases++
    Write-Host "PASS negative: $Name"
}

function Assert-Throws([scriptblock]$Action, [string]$ExpectedPattern, [string]$Context) {
    $failed = $false
    $message = $null
    try {
        & $Action
    } catch {
        $failed = $true
        $message = [string]$_.Exception.Message
        if ([string]::IsNullOrWhiteSpace($message)) {
            $message = [string]$_
        }
    }
    if (-not $failed) {
        throw "$Context did not throw an exception."
    }
    if (-not [string]::IsNullOrWhiteSpace($ExpectedPattern)) {
        if ($message -notmatch $ExpectedPattern) {
            throw "$Context threw with message '$message', which did not match expected pattern '$ExpectedPattern'."
        }
    }
    Pass-Negative $Context
}

function New-IsolatedTestRepository([string]$Root) {
    New-Item -ItemType Directory -Path $Root -Force | Out-Null
    [IO.File]::WriteAllText((Join-Path $Root 'source.txt'), 'bound source', (New-Object Text.UTF8Encoding($false)))
    $worktree = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
    $packageDir = Join-Path $Root 'tools\packaging\v0.2'
    $libDir = Join-Path $Root 'tools\lib'
    $planDir = Join-Path $Root 'Plan\reference-hosts'
    $referenceDir = Join-Path $Root 'docs\design\reference'
    New-Item -ItemType Directory -Path $packageDir, $libDir, $planDir, $referenceDir -Force | Out-Null
    $sourcePackageDir = Join-Path $PSScriptRoot '..\packaging\v0.2'
    Copy-Item (Join-Path $sourcePackageDir 'package-identity-profile.json') $packageDir
    Copy-Item (Join-Path $sourcePackageDir 'package-identity-receipt.schema.json') $packageDir
    Copy-Item (Join-Path $worktree 'tools\lib\V02ReferenceHostProfile.ps1') $libDir
    Copy-Item (Join-Path $worktree 'Plan\reference-hosts\v0.2.json') $planDir
    Copy-Item (Join-Path $worktree 'Plan\reference-hosts\reference-host-profile.schema.json') $planDir
    Copy-Item (Join-Path $worktree 'docs\design\reference\*') $referenceDir -Recurse

    & git -C $Root init --quiet
    & git -C $Root -c core.hooksPath=NUL -c user.name=RendererHarnessFixture -c user.email=renderer-harness@example.invalid add .
    & git -C $Root -c core.hooksPath=NUL -c commit.gpgsign=false -c user.name=RendererHarnessFixture -c user.email=renderer-harness@example.invalid commit --quiet -m fixture
    if ($LASTEXITCODE -ne 0) {
        throw 'Unable to create isolated Git fixture repository.'
    }
    return [pscustomobject]@{
        Root = $Root
        Commit = (& git -C $Root rev-parse HEAD).Trim()
        Tree = (& git -C $Root rev-parse 'HEAD^{tree}').Trim()
    }
}

function New-IsolatedTestPackage([string]$Root, [string]$RepositoryRoot, [string]$Commit, [string]$Tree, [switch]$ExecutableFixture) {
    New-Item -ItemType Directory -Path $Root -Force | Out-Null
    $packageRoot = Join-Path $Root 'package'
    New-Item -ItemType Directory -Path $packageRoot -Force | Out-Null

    $appPath = Join-Path $packageRoot 'HerdrOps.App.exe'
    $corePath = Join-Path $packageRoot 'HerdrOps.Core.exe'
    if ($ExecutableFixture) {
        $powershellPath = (Get-Command powershell.exe -ErrorAction Stop).Source
        Copy-Item -LiteralPath $powershellPath -Destination $appPath -Force
        Copy-Item -LiteralPath $powershellPath -Destination $corePath -Force
    } else {
        [IO.File]::WriteAllBytes($appPath, [Text.Encoding]::UTF8.GetBytes('App Binary Content'))
        [IO.File]::WriteAllBytes($corePath, [Text.Encoding]::UTF8.GetBytes('Core Binary Content'))
    }

    $profilePath = Join-Path $RepositoryRoot 'tools\packaging\v0.2\package-identity-profile.json'
    $profileValue = Read-RendererPackageProfile $profilePath
    $profileIdentity = Get-RendererPackageProfileIdentity $profilePath $profileValue $RepositoryRoot

    $manifest = New-RendererPackageManifest $profileValue $RepositoryRoot $packageRoot
    $manifestPath = Join-Path $packageRoot 'package-manifest.json'
    Write-RendererPackageCanonicalJson $manifest $manifestPath $RepositoryRoot
    $manifestStable = Get-RendererPackageStableIdentity $manifestPath

    $archivePath = Join-Path $Root 'HerdrOps-0.2.0-win-x64.zip'
    $null = New-RendererDeterministicPackageArchive $packageRoot $archivePath
    $archiveStable = Get-RendererPackageStableIdentity $archivePath

    $appStable = Get-RendererPackageStableIdentity $appPath
    $coreStable = Get-RendererPackageStableIdentity $corePath

    $receiptValue = [pscustomobject][ordered]@{
        schemaVersion = 1
        profileId = $script:RendererPackageProfileId
        issue = 149
        packageVersion = '0.2.0'
        runtimeIdentifier = 'win-x64'
        source = [pscustomobject][ordered]@{
            commitSha = $Commit
            treeSha = $Tree
        }
        profile = [pscustomobject][ordered]@{
            id = $profileIdentity.Id
            relativePath = $profileIdentity.RelativePath
            bytes = [long]$profileIdentity.Bytes
            fileSha256 = $profileIdentity.FileSha256
            canonicalSha256 = $profileIdentity.CanonicalSha256
        }
        archive = [pscustomobject][ordered]@{
            relativePath = 'HerdrOps-0.2.0-win-x64.zip'
            fileName = 'HerdrOps-0.2.0-win-x64.zip'
            bytes = [long]$archiveStable.Length
            sha256 = $archiveStable.Sha256
        }
        packageManifest = [pscustomobject][ordered]@{
            fileName = 'package-manifest.json'
            bytes = [long]$manifestStable.Length
            sha256 = $manifestStable.Sha256
            contentSha256 = $manifest.contentSha256
            fileCount = [int]$manifest.fileCount
            totalBytes = [long]$manifest.totalBytes
        }
        components = [pscustomobject][ordered]@{
            app = [pscustomobject][ordered]@{
                relativePath = 'HerdrOps.App.exe'
                bytes = [long]$appStable.Length
                sha256 = $appStable.Sha256
            }
            core = [pscustomobject][ordered]@{
                relativePath = 'HerdrOps.Core.exe'
                bytes = [long]$coreStable.Length
                sha256 = $coreStable.Sha256
            }
        }
        referenceHost = [pscustomobject][ordered]@{
            profileId = $script:RendererProfileId
            profileSha256 = $script:RendererProfileSha256
        }
        renderer = [pscustomobject][ordered]@{
            policy = 'software-only-process-wide'
            wpfProcessRenderMode = 'SoftwareOnly'
        }
        evidenceBoundary = [pscustomobject][ordered]@{
            evidenceClass = 'PackagedCompatibilityPreparation'
            runtimeUse = 'not-used'
            actualHerdrUsed = $false
            runtimeCredit = 'NOT CLAIMED'
            releaseCredit = 'NOT CLAIMED'
        }
    }

    $receiptPath = Join-Path $Root 'package-identity-receipt.json'
    Write-RendererPackageCanonicalJson $receiptValue $receiptPath $RepositoryRoot

    return [pscustomobject]@{
        Root = $Root
        PackageRoot = $packageRoot
        ArchivePath = $archivePath
        ReceiptPath = $receiptPath
        ProfilePath = $profilePath
        AppPath = $appPath
        CorePath = $corePath
    }
}

function New-CaptureSourceDirectory([string]$Root) {
    New-Item -ItemType Directory -Path $Root -Force | Out-Null
    foreach ($language in @('Thai', 'English')) {
        $languageRoot = Join-Path $Root $language
        New-Item -ItemType Directory -Path $languageRoot -Force | Out-Null
        foreach ($name in $script:RendererCaptureNames) {
            New-RendererTestPng -Path (Join-Path $languageRoot "$name.png") -Width 64 -Height 48
        }
    }
    return $Root
}

function New-MockObservationAction {
    $state = @{ last = [DateTimeOffset]::UtcNow; first = $null }
    return {
        param([string]$Stage, [int]$Ordinal)
        $now = [DateTimeOffset]::UtcNow
        if ($now -le $state.last) { $now = $state.last.AddTicks(1) }
        $state.last = $now
        if ($Ordinal -eq 2) { $state.first = $now }
        [pscustomobject][ordered]@{
            effectiveMode = 'SoftwareOnly'
            softwareOnlyConfirmed = $true
            observedUtc = $now.ToUniversalTime().ToString('O', [Globalization.CultureInfo]::InvariantCulture)
            nativeProcessRenderMode = 'SoftwareOnly'
            nativeRenderCapabilityTier = 3
            hasAnyHwnd = ($Ordinal -ge 2)
            firstHwndCreatedUtc = if ($Ordinal -ge 2) { $state.first.ToUniversalTime().ToString('O', [Globalization.CultureInfo]::InvariantCulture) } else { $null }
        }
    }.GetNewClosure()
}

function New-LiveTargetFixtureScript([string]$Path) {
    $csharpCode = @'
using System;
using System.Runtime.InteropServices;
using System.Threading;

namespace HerdrOps.Testing {
    public static class NativeWindowFixture {
        private delegate IntPtr WndProc(IntPtr hWnd, uint msg, IntPtr wParam, IntPtr lParam);

        [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
        private struct WNDCLASSEX {
            public int cbSize;
            public int style;
            public IntPtr lpfnWndProc;
            public int cbClsExtra;
            public int cbWndExtra;
            public IntPtr hInstance;
            public IntPtr hIcon;
            public IntPtr hCursor;
            public IntPtr hbrBackground;
            public string lpszMenuName;
            public string lpszClassName;
            public IntPtr hIconSm;
        }

        [StructLayout(LayoutKind.Sequential)]
        private struct MSG {
            public IntPtr hwnd;
            public uint message;
            public IntPtr wParam;
            public IntPtr lParam;
            public uint time;
            public int pt_x;
            public int pt_y;
        }

        [DllImport("user32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
        private static extern ushort RegisterClassEx(ref WNDCLASSEX lpwcx);

        [DllImport("user32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
        private static extern IntPtr CreateWindowEx(
            int dwExStyle, string lpClassName, string lpWindowName,
            int dwStyle, int x, int y, int nWidth, int nHeight,
            IntPtr hWndParent, IntPtr hMenu, IntPtr hInstance, IntPtr lpParam);

        [DllImport("user32.dll")]
        private static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);

        [DllImport("user32.dll")]
        private static extern bool UpdateWindow(IntPtr hWnd);

        [DllImport("user32.dll")]
        private static extern sbyte GetMessage(out MSG lpMsg, IntPtr hWnd, uint wMsgFilterMin, uint wMsgFilterMax);

        [DllImport("user32.dll")]
        private static extern bool TranslateMessage(ref MSG lpMsg);

        [DllImport("user32.dll")]
        private static extern IntPtr DispatchMessage(ref MSG lpMsg);

        [DllImport("user32.dll")]
        private static extern IntPtr DefWindowProc(IntPtr hWnd, uint uMsg, IntPtr wParam, IntPtr lParam);

        [DllImport("user32.dll")]
        private static extern bool PostMessage(IntPtr hWnd, uint Msg, IntPtr wParam, IntPtr lParam);

        [DllImport("user32.dll")]
        private static extern bool DestroyWindow(IntPtr hWnd);

        [DllImport("user32.dll")]
        private static extern void PostQuitMessage(int nExitCode);

        [DllImport("kernel32.dll")]
        private static extern IntPtr GetModuleHandle(string lpModuleName);

        private const int WS_OVERLAPPEDWINDOW = 0x00CF0000;
        private const int WS_VISIBLE = 0x10000000;
        private const int SW_SHOW = 5;
        private const uint WM_DESTROY = 0x0002;
        private const uint WM_CLOSE = 0x0010;

        private static Thread _uiThread;
        private static IntPtr _hwnd = IntPtr.Zero;
        private static WndProc _wndProcDelegate;
        private static readonly object _lock = new object();

        private static IntPtr CustomWndProc(IntPtr hWnd, uint msg, IntPtr wParam, IntPtr lParam) {
            if (msg == 0x8001) {
                Thread.Sleep(30000);
                return IntPtr.Zero;
            }
            if (msg == WM_CLOSE) {
                DestroyWindow(hWnd);
                return IntPtr.Zero;
            }
            if (msg == WM_DESTROY) {
                PostQuitMessage(0);
                return IntPtr.Zero;
            }
            return DefWindowProc(hWnd, msg, wParam, lParam);
        }

        public static IntPtr StartWindow(string title, int width, int height) {
            lock (_lock) {
                if (_uiThread != null) {
                    return _hwnd;
                }
                var ready = new ManualResetEvent(false);
                _wndProcDelegate = CustomWndProc;
                _uiThread = new Thread(() => {
                    string className = "HerdrOpsFixtureWindowClass_" + Guid.NewGuid().ToString("N");
                    IntPtr hInstance = GetModuleHandle(null);
                    var wcx = new WNDCLASSEX {
                        cbSize = Marshal.SizeOf(typeof(WNDCLASSEX)),
                        style = 0,
                        lpfnWndProc = Marshal.GetFunctionPointerForDelegate(_wndProcDelegate),
                        cbClsExtra = 0,
                        cbWndExtra = 0,
                        hInstance = hInstance,
                        hIcon = IntPtr.Zero,
                        hCursor = IntPtr.Zero,
                        hbrBackground = (IntPtr)6,
                        lpszMenuName = null,
                        lpszClassName = className,
                        hIconSm = IntPtr.Zero
                    };
                    RegisterClassEx(ref wcx);
                    _hwnd = CreateWindowEx(
                        0, className, title,
                        WS_OVERLAPPEDWINDOW | WS_VISIBLE,
                        100, 100, width, height,
                        IntPtr.Zero, IntPtr.Zero, hInstance, IntPtr.Zero);

                    ShowWindow(_hwnd, SW_SHOW);
                    UpdateWindow(_hwnd);
                    ready.Set();

                    MSG msg;
                    while (GetMessage(out msg, IntPtr.Zero, 0, 0) > 0) {
                        TranslateMessage(ref msg);
                        DispatchMessage(ref msg);
                    }
                });
                _uiThread.SetApartmentState(ApartmentState.STA);
                _uiThread.IsBackground = true;
                _uiThread.Start();
                if (!ready.WaitOne(5000)) {
                    throw new TimeoutException("Live fixture window did not show within 5 seconds.");
                }
                ready.Close();
                return _hwnd;
            }
        }

        public static void HangWindow() {
            lock (_lock) {
                if (_hwnd != IntPtr.Zero) {
                    PostMessage(_hwnd, 0x8001, IntPtr.Zero, IntPtr.Zero);
                }
            }
        }

        public static IntPtr RecreateWindow(string title, int width, int height) {
            StopWindow();
            return StartWindow(title, width, height);
        }

        public static void StopWindow() {
            Thread threadToJoin = null;
            lock (_lock) {
                if (_hwnd != IntPtr.Zero) {
                    PostMessage(_hwnd, WM_CLOSE, IntPtr.Zero, IntPtr.Zero);
                }
                threadToJoin = _uiThread;
                _hwnd = IntPtr.Zero;
                _uiThread = null;
            }
            if (threadToJoin != null && threadToJoin.IsAlive) {
                if (!threadToJoin.Join(5000)) {
                    throw new TimeoutException("Live fixture STA UI thread did not terminate within 5 seconds.");
                }
            }
        }

        public static IntPtr CurrentWindowHandle {
            get { return _hwnd; }
        }
    }
}
'@

    $psScript = @'
param(
    [ValidateSet('App','Core')][string]$Role,
    [string]$PipeName,
    [string]$CaptureRoot,
    [string]$TemplateRoot,
    [int]$CorePid,
    [string]$CorePath,
    [string]$FaultStage = '')
$ErrorActionPreference = 'Stop'
if ($Role -eq 'Core') {
    while ($true) { Start-Sleep -Seconds 1 }
    exit 0
}
$csharp = @__CSHARP_CODE__@
Add-Type -TypeDefinition $csharp
$process = [Diagnostics.Process]::GetCurrentProcess()
$startUtc = $process.StartTime.ToUniversalTime().ToString('O',[Globalization.CultureInfo]::InvariantCulture)
$client = $null
while ($null -eq $client) {
    try {
        $client = New-Object IO.Pipes.NamedPipeClientStream('.', $PipeName, [IO.Pipes.PipeDirection]::InOut, [IO.Pipes.PipeOptions]::None)
        $client.Connect(1000)
    } catch {
        if ($null -ne $client) { $client.Dispose(); $client = $null }
        Start-Sleep -Milliseconds 100
    }
}
$reader = New-Object IO.StreamReader($client, (New-Object Text.UTF8Encoding($false)), $false, 65536, $true)
$writer = New-Object IO.StreamWriter($client, (New-Object Text.UTF8Encoding($false)), 65536, $true)
$writer.AutoFlush = $true
function Get-FixtureCaptures([string]$ObservedUtc, [string]$LanguageFilter) {
    $items = @()
    foreach ($language in @('Thai','English')) {
        if (-not [string]::IsNullOrWhiteSpace($LanguageFilter) -and $language -ne $LanguageFilter -and $LanguageFilter -ne 'Both') { continue }
        foreach ($name in @('dashboard-overview','dashboard-live-organization','dashboard-agent-detail','widget-compact','widget-normal','widget-floating-vertical','dashboard-overview-after-event','widget-floating-vertical-after-dashboard-close','widget-floating-vertical-offline','widget-floating-vertical-reconnected')) {
            $relative = "captures/$language/$name.png"
            $path = Join-Path $CaptureRoot $relative
            if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { continue }
            $bytes = [IO.File]::ReadAllBytes($path)
            $fileObservedUtc = ([DateTimeOffset]([IO.File]::GetLastWriteTimeUtc($path))).ToUniversalTime().ToString('O',[Globalization.CultureInfo]::InvariantCulture)
            $sha = ([BitConverter]::ToString(([Security.Cryptography.SHA256]::Create()).ComputeHash($bytes))).Replace('-','').ToUpperInvariant()
            $items += ,([ordered]@{language=$language;name=$name;relativePath=$relative;bytes=[long]$bytes.Length;sha256=$sha;widthPixels=64;heightPixels=48;observedUtc=$fileObservedUtc;producerPid=[int]$process.Id;producerStartUtc=$startUtc})
        }
    }
    return $items
}
try {
    while ($null -ne ($line = $reader.ReadLine())) {
        $request = $line | ConvertFrom-Json
        $stage = [string]$request.stage
        if ($stage -eq 'PostFirstWindowShown') {
            $null = [HerdrOps.Testing.NativeWindowFixture]::StartWindow('HerdrOps renderer fixture', 320, 200)
            $process.Refresh()
            if ($FaultStage -eq 'HungWindow') {
                [HerdrOps.Testing.NativeWindowFixture]::HangWindow()
            }
        }
        if ($stage -eq 'AfterThaiCaptures') {
            if ($FaultStage -eq 'ChangingHwnd') {
                $null = [HerdrOps.Testing.NativeWindowFixture]::RecreateWindow('HerdrOps alternate fixture', 320, 200)
                $process.Refresh()
            }
            $captureLanguageRoot = Join-Path $CaptureRoot 'captures\Thai'
            New-Item -ItemType Directory -Path $captureLanguageRoot -Force | Out-Null
            foreach ($template in Get-ChildItem -LiteralPath (Join-Path $TemplateRoot 'Thai') -Filter '*.png' -File) {
                $capturePath = Join-Path $captureLanguageRoot $template.Name
                Copy-Item -LiteralPath $template.FullName -Destination $capturePath -Force
                [IO.File]::SetLastWriteTimeUtc($capturePath, [DateTime]::UtcNow)
            }
        }
        if ($stage -eq 'AfterEnglishCaptures') {
            $captureLanguageRoot = Join-Path $CaptureRoot 'captures\English'
            New-Item -ItemType Directory -Path $captureLanguageRoot -Force | Out-Null
            foreach ($template in Get-ChildItem -LiteralPath (Join-Path $TemplateRoot 'English') -Filter '*.png' -File) {
                $capturePath = Join-Path $captureLanguageRoot $template.Name
                Copy-Item -LiteralPath $template.FullName -Destination $capturePath -Force
                [IO.File]::SetLastWriteTimeUtc($capturePath, [DateTime]::UtcNow)
            }
        }
        $process.Refresh()
        $coreProcess = Get-Process -Id $CorePid -ErrorAction Stop
        $coreProcess.Refresh()
        $coreStartUtc = $coreProcess.StartTime.ToUniversalTime().ToString('O',[Globalization.CultureInfo]::InvariantCulture)
        $coreBytes = [IO.File]::ReadAllBytes($CorePath)
        $hwnd = [Int64][HerdrOps.Testing.NativeWindowFixture]::CurrentWindowHandle
        if ($hwnd -eq 0) { $hwnd = [Int64]$process.MainWindowHandle }
        $hasWindow = $hwnd -ne 0
        $captures = if ($stage -eq 'AfterThaiCaptures') { @(Get-FixtureCaptures ([DateTimeOffset]::UtcNow.ToString('O',[Globalization.CultureInfo]::InvariantCulture)) 'Thai') } elseif ($stage -eq 'AfterEnglishCaptures' -or $stage -eq 'Final') { @(Get-FixtureCaptures ([DateTimeOffset]::UtcNow.ToString('O',[Globalization.CultureInfo]::InvariantCulture)) 'Both') } else { @() }
        $observedUtc = [DateTimeOffset]::UtcNow.ToString('O',[Globalization.CultureInfo]::InvariantCulture)
        $response = [ordered]@{
            stage = $stage
            ordinal = [int]$request.ordinal
            observedUtc = $observedUtc
            appProcess = [ordered]@{role='App';pid=[int]$process.Id;startTimeUtc=$startUtc;executablePath=[IO.Path]::GetFullPath($process.MainModule.FileName);executableFinalPath=[IO.Path]::GetFullPath($process.MainModule.FileName);bytes=[long](Get-Item -LiteralPath $process.MainModule.FileName).Length;sha256=([BitConverter]::ToString(([Security.Cryptography.SHA256]::Create()).ComputeHash([IO.File]::ReadAllBytes($process.MainModule.FileName)))).Replace('-','').ToUpperInvariant();processName=[string]$process.ProcessName}
            coreProcess = [ordered]@{role='Core';pid=[int]$coreProcess.Id;startTimeUtc=$coreStartUtc;executablePath=[IO.Path]::GetFullPath($coreProcess.MainModule.FileName);executableFinalPath=[IO.Path]::GetFullPath($coreProcess.MainModule.FileName);bytes=[long]$coreBytes.Length;sha256=([BitConverter]::ToString(([Security.Cryptography.SHA256]::Create()).ComputeHash($coreBytes))).Replace('-','').ToUpperInvariant();processName=[string]$coreProcess.ProcessName}
            window = [ordered]@{hasAnyHwnd=$hasWindow;hwnd=$hwnd;ownerPid=if($hasWindow){[int]$process.Id}else{0};ownerStartTimeUtc=if($hasWindow){$startUtc}else{$null}}
            render = [ordered]@{source='TargetProcessNativeObservation';processId=[int]$process.Id;processStartUtc=$startUtc;effectiveMode='SoftwareOnly';softwareOnlyConfirmed=$true;nativeProcessRenderMode='SoftwareOnly';nativeRenderCapabilityTier=2}
            captures = @($captures)
        }
        $writer.WriteLine(($response | ConvertTo-Json -Depth 30 -Compress))
    }
} finally {
    try { [HerdrOps.Testing.NativeWindowFixture]::StopWindow() } catch { }
    if ($null -ne $writer) { $writer.Dispose() }
    if ($null -ne $reader) { $reader.Dispose() }
    if ($null -ne $client) { $client.Dispose() }
}
'@
    $scriptContent = $psScript.Replace('@__CSHARP_CODE__@', "@'`n$csharpCode`n'@")
    [IO.File]::WriteAllText($Path, $scriptContent, (New-Object Text.UTF8Encoding($false)))
    return $Path
}

function New-LiveReferenceEnvironmentSnapshot([string]$Path, [string]$RepositoryRoot) {
    # The live fixture reads the repository reference host below.
    $reference = Get-Content -Raw -LiteralPath (Join-Path $RepositoryRoot 'Plan\reference-hosts\v0.2.json') | ConvertFrom-Json
    $hostRecord = $reference.environmentBinding.host
    $display = $reference.environmentBinding.activeDisplay
    $adapters = @($reference.environmentBinding.graphicsAdapters | ForEach-Object { [ordered]@{displayName=$_.displayName;pnpDeviceId=$_.pnpDeviceId;driverVersion=$_.driverVersion} })
    $value = [ordered]@{
        os = [ordered]@{caption=$hostRecord.operatingSystemCaption;version=$hostRecord.operatingSystemVersion;build=[int]$hostRecord.operatingSystemBuild;architecture='x64'}
        graphicsAdapters = $adapters
        display = [ordered]@{deviceName=$display.primaryDisplayDeviceName;physicalWidthPixels=[int]$display.physicalWidthPixels;physicalHeightPixels=[int]$display.physicalHeightPixels;logicalWidthPixels=[int]$display.logicalWidthPixels;logicalHeightPixels=[int]$display.logicalHeightPixels;desktopAppliedDpi=[int]$display.desktopAppliedDpi;scalePercent=[int]$display.scalePercent;refreshRateHz=[int]$display.refreshRateHz;monitorCount=[int]$display.activeMonitorCount}
        session = [ordered]@{kind='LocalConsole';name='Console';sessionId=1;transport='Physical';powerSource='AC';thermalState='Nominal';elevated=$false;userScope='SingleUser'}
        supportScope = [ordered]@{supported=@('windows11-x64-build26220','local-console','non-elevated','single-user','physical-display-matrix','ac-power','battery-power');excluded=@('rdp-runtime','vm-runtime','arm64','remote-cloud','multi-user');vmCleanInstallOnly=$true;vmRuntimeCredit=$false}
    }
    [IO.File]::WriteAllText($Path, ($value | ConvertTo-Json -Depth 20), (New-Object Text.UTF8Encoding($false)))
    return $Path
}

function New-ElevatedEnvironmentSnapshot([string]$SourcePath, [string]$Path) {
    $value = Get-Content -Raw -LiteralPath $SourcePath | ConvertFrom-Json
    $value.session.elevated = $true
    [IO.File]::WriteAllText($Path, ($value | ConvertTo-Json -Depth 20), (New-Object Text.UTF8Encoding($false)))
    return $Path
}

function Start-LiveFixtureProcess([string]$Executable,[string]$ScriptPath,[string]$Role,[string]$PipeName,[string]$CaptureRoot,[string]$TemplateRoot,[int]$CorePid=0,[string]$CorePath='',[string]$FaultStage='') {
    $psi = New-Object Diagnostics.ProcessStartInfo
    $psi.FileName = $Executable
    $psi.Arguments = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$ScriptPath`" -Role $Role -PipeName $PipeName -CaptureRoot `"$CaptureRoot`" -TemplateRoot `"$TemplateRoot`" -CorePid $CorePid -CorePath `"$CorePath`" -FaultStage `"$FaultStage`""
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.WorkingDirectory = Split-Path -Parent $Executable
    $process = [Diagnostics.Process]::Start($psi)
    if ($null -eq $process) { throw "Unable to start live fixture process '$Role'." }
    return $process
}

function Stop-OwnedFixtureProcess($Process) {
    if ($null -ne $Process) {
        try { if (-not $Process.HasExited) { [void]$Process.Kill(); [void]$Process.WaitForExit(5000) } } catch { }
        [void]$Process.Dispose()
    }
}

function Invoke-LiveTargetFixtureCase([string]$Root,[string]$RepositoryRoot,[string]$Commit,[string]$Tree,[string]$FaultStage) {
    $fixtureRoot = Join-Path $Root ('live-' + $(if ([string]::IsNullOrWhiteSpace($FaultStage)) { 'positive' } else { $FaultStage.ToLowerInvariant() }))
    $pkg = New-IsolatedTestPackage (Join-Path $fixtureRoot 'pkg') $RepositoryRoot $Commit $Tree -ExecutableFixture
    $templates = New-CaptureSourceDirectory (Join-Path $fixtureRoot 'templates')
    $runtimeRoot = Join-Path $fixtureRoot 'runtime-evidence'
    New-Item -ItemType Directory -Path $runtimeRoot -Force | Out-Null
    $environmentPath = New-LiveReferenceEnvironmentSnapshot (Join-Path $fixtureRoot 'environment.json') $RepositoryRoot
    $targetScript = New-LiveTargetFixtureScript (Join-Path $fixtureRoot 'target.ps1')
    $pipeName = 'herdrops-v02-' + [Guid]::NewGuid().ToString('N')
    $core = $null
    $app = $null
    try {
        $core = Start-LiveFixtureProcess $pkg.CorePath $targetScript 'Core' $pipeName $runtimeRoot $templates
        $app = Start-LiveFixtureProcess $pkg.AppPath $targetScript 'App' $pipeName $runtimeRoot $templates $core.Id $pkg.CorePath $FaultStage
        Start-Sleep -Milliseconds 250
        $invoke = Join-Path $PSScriptRoot 'Invoke-V02LiveRendererCapture.ps1'
        $output = Join-Path $fixtureRoot 'output'
        if ([string]::IsNullOrWhiteSpace($FaultStage)) {
            $result = & $invoke `
                -OutputDirectory $output `
                -PackageRoot $pkg.PackageRoot `
                -ArchivePath $pkg.ArchivePath `
                -IdentityReceiptPath $pkg.ReceiptPath `
                -RepositoryRoot $RepositoryRoot `
                -ProfilePath $pkg.ProfilePath `
                -RuntimeEvidenceRoot $runtimeRoot `
                -TargetAppPid $app.Id `
                -TargetCorePid $core.Id `
                -TargetObservationPipeName $pipeName `
                -TestEnvironmentSnapshotPath $environmentPath
            if ($result.CaptureMode -cne 'LiveOperator' -or $result.ActualHerdrRuntime -cne 'NOT_OBSERVED' -or [bool]$result.ReleaseCredit -or $result.CaptureCount -ne 20 -or $result.LifecycleStages -ne 8) { throw 'Positive LiveOperator fixture did not preserve exact no-credit result boundaries.' }

            # HWND stability regression: verify all post-first-HWND stages (stages 2-7) maintained the exact same responsive window HWND and App ownership
            $receiptObj = Get-Content -Raw -LiteralPath (Join-Path $output 'proofs/target-binding.json') | ConvertFrom-Json
            $postFirstObservations = @($receiptObj.observations | Where-Object { [int]$_.ordinal -ge 2 })
            if ($postFirstObservations.Count -ne 6) { throw "Expected 6 post-first-HWND observations; found $($postFirstObservations.Count)." }
            $firstObs = $postFirstObservations[0]
            $expectedHwnd = [Int64]$firstObs.window.hwnd
            if ($expectedHwnd -eq 0 -or -not [bool]$firstObs.window.hasAnyHwnd) { throw 'First post-first-HWND observation did not report a non-zero live HWND.' }
            $expectedOwnerPid = [int]$firstObs.window.ownerPid
            $expectedOwnerStartUtc = [string]$receiptObj.appProcess.startTimeUtc
            foreach ($obs in $postFirstObservations) {
                if (-not [bool]$obs.window.hasAnyHwnd -or [Int64]$obs.window.hwnd -ne $expectedHwnd -or [int]$obs.window.ownerPid -ne $expectedOwnerPid -or [string]$obs.window.ownerStartTimeUtc -cne $expectedOwnerStartUtc) {
                    throw "Post-first-HWND observation '$($obs.stage)' HWND ($($obs.window.hwnd)) or owner ($($obs.window.ownerPid)) changed from initial HWND ($expectedHwnd) / owner ($expectedOwnerPid)."
                }
            }
            return $result
        }
        $expectedPatterns = @{
            PidReuse = 'start identity|PID reuse|does not equal'
            WrongProcess = 'PID reuse|process identity|does not equal'
            WrongWindow = 'HWND ownership|window.*independently observed'
            ArbitraryPng = 'target-process PNG binding|PNG|changed between stable reads'
            TransientCaptureReplacement = 'changed between stable reads|target-process PNG binding'
            HungWindow = 'unresponsive or hung|SendMessageTimeout'
            ChangingHwnd = 'changed from initial post-first-window HWND|HWND continuity violated'
        }
        Assert-Throws {
            & $invoke `
                -OutputDirectory $output `
                -PackageRoot $pkg.PackageRoot `
                -ArchivePath $pkg.ArchivePath `
                -IdentityReceiptPath $pkg.ReceiptPath `
                -RepositoryRoot $RepositoryRoot `
                -ProfilePath $pkg.ProfilePath `
                -RuntimeEvidenceRoot $runtimeRoot `
                -TargetAppPid $app.Id `
                -TargetCorePid $core.Id `
                -TargetObservationPipeName $pipeName `
                -TestEnvironmentSnapshotPath $environmentPath `
                -TestFaultStage $FaultStage
        } $expectedPatterns[$FaultStage] "LiveOperator hostile fixture '$FaultStage'"
    } finally {
        Stop-OwnedFixtureProcess $app
        Stop-OwnedFixtureProcess $core
    }
}

$temp = Join-Path ([IO.Path]::GetTempPath()) ('herdrops-capture-harness-' + [Guid]::NewGuid().ToString('N'))
try {
    New-Item -ItemType Directory -Path $temp -Force | Out-Null
    Write-Host 'INFO creating isolated repo fixture...'
    $repo = New-IsolatedTestRepository (Join-Path $temp 'repo')
    Write-Host 'INFO creating isolated package fixture...'
    $pkg = New-IsolatedTestPackage (Join-Path $temp 'pkg') $repo.Root $repo.Commit $repo.Tree
    $fixtureEnvironmentPath = New-LiveReferenceEnvironmentSnapshot (Join-Path $temp 'fixture-environment.json') $repo.Root
    $elevatedEnvironmentPath = New-ElevatedEnvironmentSnapshot $fixtureEnvironmentPath (Join-Path $temp 'elevated-environment.json')
    Write-Host 'INFO invoking harness for positive baseline...'

    # 1. Positive Baseline: Full Harness Execution
    $out1 = Join-Path $temp 'evidence-out-1'
    $result1 = & (Join-Path $PSScriptRoot 'Invoke-V02LiveRendererCapture.ps1') `
        -OutputDirectory $out1 `
        -PackageRoot $pkg.PackageRoot `
        -ArchivePath $pkg.ArchivePath `
        -IdentityReceiptPath $pkg.ReceiptPath `
        -RepositoryRoot $repo.Root `
        -ProfilePath $pkg.ProfilePath `
        -SyntheticCapturesForTesting `
        -TestEnvironmentSnapshotPath $fixtureEnvironmentPath
    Write-Host 'INFO positive baseline execution complete.'

    if ($result1.EvidenceClassification -cne 'PackagedCompatibilityCandidate' -or
        $result1.Status -cne 'ManifestCreated' -or
        $result1.CaptureCount -ne 20 -or
        $result1.ThaiCaptures -ne 10 -or
        $result1.EnglishCaptures -ne 10 -or
        $result1.LifecycleStages -ne 8 -or
        -not $result1.SoftwareOnlyConfirmed -or
        -not $result1.PreFirstHwndProofConfirmed -or
        $result1.HumanReview -cne 'NOT_OBSERVED' -or
        $result1.ActualHerdrRuntime -cne 'NOT_OBSERVED' -or
        [bool]$result1.ReleaseCredit -or
        [bool]$result1.PackagedCompatibilityReadyForIssue149Closure) {
        throw 'Positive baseline result object classification or properties invalid.'
    }

    $manifestValidation = Test-RendererCompatibilityManifest `
        -ManifestPath $result1.ManifestPath `
        -EvidenceRoot $out1 `
        -RepositoryRoot $repo.Root `
        -ValidateBindings

    if ($manifestValidation.EvidenceClassification -cne 'PackagedCompatibilityCandidate' -or
        $manifestValidation.StructuralValidation -cne 'PASS' -or
        $manifestValidation.BindingValidation -cne 'PASS' -or
        $manifestValidation.GovernanceProfileConsistency -cne 'PASS' -or
        $manifestValidation.HumanReview -cne 'NOT_OBSERVED' -or
        $manifestValidation.ActualHerdrRuntime -cne 'NOT_OBSERVED' -or
        [bool]$manifestValidation.CreditGranted -or
        [bool]$manifestValidation.PackagedCompatibilityReadyForIssue149Closure) {
        throw 'Self-validation of positive baseline manifest failed.'
    }
    if ($result1.CaptureMode -cne 'SyntheticSelfTest' -or $manifestValidation.CaptureMode -cne 'SyntheticSelfTest') {
        throw 'Synthetic baseline did not retain its explicit SyntheticSelfTest boundary.'
    }
    Pass 'operator-driven capture harness generates strict validated synthetic candidate evidence'

    # 2. Positive real-capture input path: PNG bytes are admitted from a
    # contained source directory, but the result remains synthetic/no-credit.
    $sourceCaptures = New-CaptureSourceDirectory (Join-Path $temp 'capture-source')
    $outSource = Join-Path $temp 'evidence-out-source'
    $sourceResult = & (Join-Path $PSScriptRoot 'Invoke-V02LiveRendererCapture.ps1') `
        -OutputDirectory $outSource `
        -PackageRoot $pkg.PackageRoot `
        -ArchivePath $pkg.ArchivePath `
        -IdentityReceiptPath $pkg.ReceiptPath `
        -RepositoryRoot $repo.Root `
        -ProfilePath $pkg.ProfilePath `
        -CaptureSourceDirectory $sourceCaptures `
        -OperatorObservationAction (New-MockObservationAction) `
        -SyntheticCapturesForTesting `
        -TestEnvironmentSnapshotPath $fixtureEnvironmentPath
    $sourceManifest = Get-Content -Raw -LiteralPath $sourceResult.ManifestPath | ConvertFrom-Json
    $sourceProofPath = Join-Path $outSource $sourceManifest.rendererEvidence.throughoutObservations[0].proofReceipt.relativePath
    $sourceProof = Get-Content -Raw -LiteralPath $sourceProofPath | ConvertFrom-Json
    if ($sourceResult.CaptureCount -ne 20 -or $sourceResult.CaptureMode -cne 'SyntheticSelfTest' -or
        [int]$sourceProof.nativeRenderCapabilityTier -ne 3 -or
        $sourceResult.ActualHerdrRuntime -cne 'NOT_OBSERVED' -or [bool]$sourceResult.ReleaseCredit) {
        throw 'Contained real-capture input path or injected observation was not preserved as synthetic/no-credit.'
    }
    Pass 'contained real-capture input path and injected native observation are preserved as synthetic/no-credit'

    # Synthetic CI fixtures must declare the approved non-elevated host
    # explicitly; they must never inherit the runner token's elevation state.
    $baselineManifest = Get-Content -Raw -LiteralPath $result1.ManifestPath | ConvertFrom-Json
    if ([bool]$baselineManifest.environment.session.elevated) {
        throw 'Synthetic fixture manifest inherited elevated host state.'
    }
    Pass 'synthetic fixture injects a deterministic non-elevated host observation'

    # The production manifest verifier must still reject elevated evidence.
    $elevatedOutput = Join-Path $temp 'elevated-environment-output'
    Assert-Throws {
        & (Join-Path $PSScriptRoot 'Invoke-V02LiveRendererCapture.ps1') `
            -OutputDirectory $elevatedOutput `
            -PackageRoot $pkg.PackageRoot `
            -ArchivePath $pkg.ArchivePath `
            -IdentityReceiptPath $pkg.ReceiptPath `
            -RepositoryRoot $repo.Root `
            -ProfilePath $pkg.ProfilePath `
            -SyntheticCapturesForTesting `
            -TestEnvironmentSnapshotPath $elevatedEnvironmentPath
    } 'Elevated renderer evidence is outside the approved v0.2 scope' 'production manifest verifier rejects elevated evidence'
    if (Test-Path -LiteralPath $elevatedOutput) {
        throw 'Elevated evidence rejection left a published output directory.'
    }

    $elevatedEnvironment = Get-Content -Raw -LiteralPath $elevatedEnvironmentPath | ConvertFrom-Json
    Assert-Throws {
        Assert-RendererLiveEnvironment $elevatedEnvironment $repo.Root
    } 'local, physical, non-elevated single-user session' 'production live admission rejects elevated environment'

    # 3. Positive LiveOperator fixture: copied PowerShell processes implement
    # the target-process protocol. This reaches the same PID/start/executable,
    # HWND, render-mode, and capture-binding guards without being Herdr.
    $livePositive = Invoke-LiveTargetFixtureCase $temp $repo.Root $repo.Commit $repo.Tree ''
    if ($livePositive.EvidenceClassification -cne 'PackagedCompatibilityCandidate' -or
        $livePositive.CaptureMode -cne 'LiveOperator' -or
        $livePositive.ActualHerdrRuntime -cne 'NOT_OBSERVED' -or
        [bool]$livePositive.ReleaseCredit -or
        $livePositive.CaptureCount -ne 20 -or
        $livePositive.LifecycleStages -ne 8) {
        throw 'Positive LiveOperator target-process fixture did not retain exact evidence boundaries.'
    }
    Pass 'LiveOperator positive target-process binding reaches exact guards without Runtime/Release credit'

    foreach ($liveFault in @('PidReuse','WrongProcess','WrongWindow','ArbitraryPng','TransientCaptureReplacement','HungWindow','ChangingHwnd')) {
        Invoke-LiveTargetFixtureCase $temp $repo.Root $repo.Commit $repo.Tree $liveFault | Out-Null
    }
    Pass-Negative 'LiveOperator hostile target/process/window/capture replacement cases fail closed'

    # Hostile: Receipt verifier rejects changing HWND across post-first stages
    $livePositiveOutput = Join-Path $temp 'live-positive/output'
    $bindingRaw = [IO.File]::ReadAllText((Join-Path $livePositiveOutput 'proofs/target-binding.json'), [Text.Encoding]::UTF8)
    $manifestRaw = [IO.File]::ReadAllText((Join-Path $livePositiveOutput 'v0.2-renderer-compatibility-manifest.json'), [Text.Encoding]::UTF8)
    $receiptObjTampered = if ($PSVersionTable.PSVersion.Major -ge 7 -and (Get-Command ConvertFrom-Json).Parameters.ContainsKey('DateKind')) {
        $bindingRaw | ConvertFrom-Json -DateKind String
    } else {
        ConvertFrom-StrictHumanDesignReviewJson -Json $bindingRaw -Description 'Target binding'
    }
    $manifestObj = if ($PSVersionTable.PSVersion.Major -ge 7 -and (Get-Command ConvertFrom-Json).Parameters.ContainsKey('DateKind')) {
        $manifestRaw | ConvertFrom-Json -DateKind String
    } else {
        ConvertFrom-StrictHumanDesignReviewJson -Json $manifestRaw -Description 'Manifest'
    }
    $receiptObjTampered.observations[3].window.hwnd = [long]($receiptObjTampered.observations[3].window.hwnd + 1)
    Assert-Throws {
        Assert-RendererTargetBindingReceipt $receiptObjTampered $manifestObj
    } 'changed from initial post-first-window HWND|HWND continuity violated' 'receipt verifier rejects changing HWND across post-first stages'
    Pass-Negative 'receipt verifier rejects changing HWND across post-first stages'

    # Production invocation must not silently fall back to synthetic lifecycle
    # values or a hardcoded renderer mode.
    Assert-Throws {
        & (Join-Path $PSScriptRoot 'Invoke-V02LiveRendererCapture.ps1') -OutputDirectory (Join-Path $temp 'missing-live-observation')
    } 'requires positive target App/Core PIDs' 'live mode requires bound target processes'

    Assert-Throws {
        & (Join-Path $PSScriptRoot 'Invoke-V02LiveRendererCapture.ps1') `
            -OutputDirectory (Join-Path $temp 'opaque-live-observation') `
            -RuntimeEvidenceRoot $temp `
            -TargetAppPid 1 `
            -TargetCorePid 2 `
            -TargetObservationPipeName 'opaque-guard' `
            -OperatorObservationAction (New-MockObservationAction)
    } 'opaque observation' 'LiveOperator rejects opaque operator observations'

    # 3. Hostile: No-clobber target directory protection
    Assert-Throws {
        & (Join-Path $PSScriptRoot 'Invoke-V02LiveRendererCapture.ps1') `
            -OutputDirectory $out1 `
            -PackageRoot $pkg.PackageRoot `
            -ArchivePath $pkg.ArchivePath `
            -IdentityReceiptPath $pkg.ReceiptPath `
            -RepositoryRoot $repo.Root `
            -ProfilePath $pkg.ProfilePath `
            -SyntheticCapturesForTesting `
            -TestEnvironmentSnapshotPath $fixtureEnvironmentPath
    } 'already exists.*no-clobber' 'no-clobber existing directory protection'

    # 3b. Hostile: destination appears after validation; atomic rename must
    # fail without deleting or replacing the competing directory.
    $outRace = Join-Path $temp 'evidence-out-race'
    Assert-Throws {
        & (Join-Path $PSScriptRoot 'Invoke-V02LiveRendererCapture.ps1') `
            -OutputDirectory $outRace `
            -PackageRoot $pkg.PackageRoot `
            -ArchivePath $pkg.ArchivePath `
            -IdentityReceiptPath $pkg.ReceiptPath `
            -RepositoryRoot $repo.Root `
            -ProfilePath $pkg.ProfilePath `
            -SyntheticCapturesForTesting `
            -TestEnvironmentSnapshotPath $fixtureEnvironmentPath `
            -TestFaultStage 'OutputRace'
    } 'appeared before atomic no-clobber publish' 'publish race fails closed without clobber'
    if (-not (Test-Path -LiteralPath $outRace -PathType Container)) { throw 'Publish race did not preserve the competing destination.' }
    Pass-Negative 'publish race preserves destination'

    # Hostile: Leased directory rename fails if destination already exists
    $leaseDir = Join-Path $temp 'lease-test-src'
    $destDir = Join-Path $temp 'lease-test-dst'
    New-Item -ItemType Directory -Path $leaseDir -Force | Out-Null
    New-Item -ItemType Directory -Path $destDir -Force | Out-Null
    $testLease = Open-RendererDirectoryLease $temp $leaseDir 'Lease test source' -AllowDelete
    try {
        Assert-Throws {
            Move-RendererLeasedDirectory -Lease $testLease -Root $temp -Path $leaseDir -Destination $destDir -Context 'Lease test rename'
        } 'Held-handle directory rename failed|already exists|failed' 'leased directory rename to existing destination fails closed'
    } finally {
        $testLease.Handle.Dispose()
    }
    Pass-Negative 'leased directory rename to existing destination fails closed'

    # Hostile: Leased directory identity swap fails lease assertion
    $swapDir1 = Join-Path $temp 'lease-swap-1'
    $swapDir2 = Join-Path $temp 'lease-swap-2'
    New-Item -ItemType Directory -Path $swapDir1 -Force | Out-Null
    $swapLease = Open-RendererDirectoryLease $temp $swapDir1 'Lease swap test' -AllowDelete
    try {
        New-Item -ItemType Directory -Path $swapDir2 -Force | Out-Null
        Assert-Throws {
            Assert-RendererDirectoryLease -Lease $swapLease -Root $temp -Path $swapDir2 -Context 'Lease swap test'
        } 'identity changed|path no longer resolves' 'swapped directory fails lease verification'
    } finally {
        $swapLease.Handle.Dispose()
    }
    Pass-Negative 'swapped directory fails lease verification'

    # Hostile: Staging tree non-recursive owned cleanup removes tree safely
    $cleanDir = Join-Path $temp 'clean-test-dir'
    $subDir = Join-Path $cleanDir 'subdir'
    New-Item -ItemType Directory -Path $subDir -Force | Out-Null
    [IO.File]::WriteAllText((Join-Path $cleanDir 'rootfile.txt'), 'content')
    [IO.File]::WriteAllText((Join-Path $subDir 'subfile.txt'), 'subcontent')
    $cleanLease = Open-RendererDirectoryLease $temp $cleanDir 'Clean test lease' -AllowDelete
    try {
        Remove-RendererOwnedStagingTree -Lease $cleanLease -Root $temp -Path $cleanDir -Context 'Clean test tree'
        if (Test-Path -LiteralPath $cleanDir) { throw 'Remove-RendererOwnedStagingTree did not remove staging directory.' }
    } finally {
        if ($null -ne $cleanLease -and -not $cleanLease.Handle.IsClosed) { $cleanLease.Handle.Dispose() }
    }
    Pass-Negative 'staging tree owned nonrecursive cleanup removes tree safely'

    # 4. Hostile: Missing capture file (9 Thai instead of 10)
    $outMissing = Join-Path $temp 'evidence-out-missing-capture'
    Assert-Throws {
        & (Join-Path $PSScriptRoot 'Invoke-V02LiveRendererCapture.ps1') `
            -OutputDirectory $outMissing `
            -PackageRoot $pkg.PackageRoot `
            -ArchivePath $pkg.ArchivePath `
            -IdentityReceiptPath $pkg.ReceiptPath `
            -RepositoryRoot $repo.Root `
            -ProfilePath $pkg.ProfilePath `
            -SyntheticCapturesForTesting `
            -TestEnvironmentSnapshotPath $fixtureEnvironmentPath `
            -TestFaultStage 'MissingCapture'
    } 'requires exactly 20 captures' 'missing capture fails closed'

    if (Test-Path -LiteralPath $outMissing) {
        throw 'Failed harness execution left output directory behind.'
    }
    Pass-Negative 'failed execution cleans up staging'

    # 4. Hostile: Corrupt non-PNG capture bytes
    $outCorrupt = Join-Path $temp 'evidence-out-corrupt-png'
    Assert-Throws {
        & (Join-Path $PSScriptRoot 'Invoke-V02LiveRendererCapture.ps1') `
            -OutputDirectory $outCorrupt `
            -PackageRoot $pkg.PackageRoot `
            -ArchivePath $pkg.ArchivePath `
            -IdentityReceiptPath $pkg.ReceiptPath `
            -RepositoryRoot $repo.Root `
            -ProfilePath $pkg.ProfilePath `
            -SyntheticCapturesForTesting `
            -TestEnvironmentSnapshotPath $fixtureEnvironmentPath `
            -TestFaultStage 'CorruptPng'
    } 'not a complete decodable PNG' 'corrupt PNG capture fails closed'

    # 5. Hostile: Late pre-first-HWND proof
    $outLate = Join-Path $temp 'evidence-out-late-pre-first-hwnd'
    Assert-Throws {
        & (Join-Path $PSScriptRoot 'Invoke-V02LiveRendererCapture.ps1') `
            -OutputDirectory $outLate `
            -PackageRoot $pkg.PackageRoot `
            -ArchivePath $pkg.ArchivePath `
            -IdentityReceiptPath $pkg.ReceiptPath `
            -RepositoryRoot $repo.Root `
            -ProfilePath $pkg.ProfilePath `
            -SyntheticCapturesForTesting `
            -TestEnvironmentSnapshotPath $fixtureEnvironmentPath `
            -TestFaultStage 'LatePreFirstHwnd'
    } 'The JSON is not valid with the schema|HWND ordering is invalid|outside exact order' 'late pre-first-HWND proof fails closed'

    # 6. Hostile: Hardware mode drift during lifecycle
    $outHardware = Join-Path $temp 'evidence-out-hardware-mode'
    Assert-Throws {
        & (Join-Path $PSScriptRoot 'Invoke-V02LiveRendererCapture.ps1') `
            -OutputDirectory $outHardware `
            -PackageRoot $pkg.PackageRoot `
            -ArchivePath $pkg.ArchivePath `
            -IdentityReceiptPath $pkg.ReceiptPath `
            -RepositoryRoot $repo.Root `
            -ProfilePath $pkg.ProfilePath `
            -SyntheticCapturesForTesting `
            -TestEnvironmentSnapshotPath $fixtureEnvironmentPath `
            -TestFaultStage 'HardwareModeDrift'
    } 'The JSON is not valid with the schema|not native SoftwareOnly true|SoftwareOnly' 'hardware mode drift fails closed'

    # 7. Hostile: Out-of-order lifecycle stages
    $outOrder = Join-Path $temp 'evidence-out-order'
    Assert-Throws {
        & (Join-Path $PSScriptRoot 'Invoke-V02LiveRendererCapture.ps1') `
            -OutputDirectory $outOrder `
            -PackageRoot $pkg.PackageRoot `
            -ArchivePath $pkg.ArchivePath `
            -IdentityReceiptPath $pkg.ReceiptPath `
            -RepositoryRoot $repo.Root `
            -ProfilePath $pkg.ProfilePath `
            -SyntheticCapturesForTesting `
            -TestEnvironmentSnapshotPath $fixtureEnvironmentPath `
            -TestFaultStage 'OutOfOrderStages'
    } 'The JSON is not valid with the schema|ordered by nondecreasing UTC|window.*reversed' 'out-of-order stages fail closed'

    # 8. Hostile: Missing lifecycle stage (7 instead of 8)
    $outMissingStage = Join-Path $temp 'evidence-out-missing-stage'
    Assert-Throws {
        & (Join-Path $PSScriptRoot 'Invoke-V02LiveRendererCapture.ps1') `
            -OutputDirectory $outMissingStage `
            -PackageRoot $pkg.PackageRoot `
            -ArchivePath $pkg.ArchivePath `
            -IdentityReceiptPath $pkg.ReceiptPath `
            -RepositoryRoot $repo.Root `
            -ProfilePath $pkg.ProfilePath `
            -SyntheticCapturesForTesting `
            -TestEnvironmentSnapshotPath $fixtureEnvironmentPath `
            -TestFaultStage 'MissingStage'
    } 'The JSON is not valid with the schema|requires exactly 8 lifecycle stage observations' 'missing lifecycle stage fails closed'

    # 9. Hostile: Capture timestamp outside observation window
    $outWindow = Join-Path $temp 'evidence-out-window'
    Assert-Throws {
        & (Join-Path $PSScriptRoot 'Invoke-V02LiveRendererCapture.ps1') `
            -OutputDirectory $outWindow `
            -PackageRoot $pkg.PackageRoot `
            -ArchivePath $pkg.ArchivePath `
            -IdentityReceiptPath $pkg.ReceiptPath `
            -RepositoryRoot $repo.Root `
            -ProfilePath $pkg.ProfilePath `
            -SyntheticCapturesForTesting `
            -TestEnvironmentSnapshotPath $fixtureEnvironmentPath `
            -TestFaultStage 'CaptureOutsideWindow'
    } 'The JSON is not valid with the schema|falls outside its renderer-observation language window' 'capture timestamp outside window fails closed'

    # 10. Hostile: Package tamper (modified App.exe in package)
    $pkgTampered = New-IsolatedTestPackage (Join-Path $temp 'pkg-tampered') $repo.Root $repo.Commit $repo.Tree
    [IO.File]::WriteAllBytes($pkgTampered.AppPath, [Text.Encoding]::UTF8.GetBytes('Tampered App Content'))
    $outTampered = Join-Path $temp 'evidence-out-tampered'
    Assert-Throws {
        & (Join-Path $PSScriptRoot 'Invoke-V02LiveRendererCapture.ps1') `
            -OutputDirectory $outTampered `
            -PackageRoot $pkgTampered.PackageRoot `
            -ArchivePath $pkgTampered.ArchivePath `
            -IdentityReceiptPath $pkgTampered.ReceiptPath `
            -RepositoryRoot $repo.Root `
            -ProfilePath $pkgTampered.ProfilePath `
            -SyntheticCapturesForTesting `
            -TestEnvironmentSnapshotPath $fixtureEnvironmentPath
    } 'Manifest/package-root inventories are not exact and coherent|App/Core receipt bytes/hashes do not match|App executable in payload does not match|tamper detected' 'tampered packaged App binary fails closed'

    # 11. Hostile: Reparse point in output parent directory
    $externalTarget = Join-Path $temp 'external-target'
    New-Item -ItemType Directory -Path $externalTarget -Force | Out-Null
    $junctionDir = Join-Path $temp 'junction-parent'
    New-Item -ItemType Junction -Path $junctionDir -Target $externalTarget | Out-Null
    try {
        $outJunction = Join-Path $junctionDir 'evidence'
        Assert-Throws {
            & (Join-Path $PSScriptRoot 'Invoke-V02LiveRendererCapture.ps1') `
                -OutputDirectory $outJunction `
                -PackageRoot $pkg.PackageRoot `
                -ArchivePath $pkg.ArchivePath `
                -IdentityReceiptPath $pkg.ReceiptPath `
                -RepositoryRoot $repo.Root `
                -ProfilePath $pkg.ProfilePath `
                -SyntheticCapturesForTesting `
                -TestEnvironmentSnapshotPath $fixtureEnvironmentPath
        } 'reparse' 'reparse junction output path fails closed'
    } finally {
        if (Test-Path -LiteralPath $junctionDir) {
            [IO.Directory]::Delete($junctionDir, $false)
        }
    }

    # 12. Hostile: Injected failure before commit
    $outPreCommit = Join-Path $temp 'evidence-out-pre-commit'
    Assert-Throws {
        & (Join-Path $PSScriptRoot 'Invoke-V02LiveRendererCapture.ps1') `
            -OutputDirectory $outPreCommit `
            -PackageRoot $pkg.PackageRoot `
            -ArchivePath $pkg.ArchivePath `
            -IdentityReceiptPath $pkg.ReceiptPath `
            -RepositoryRoot $repo.Root `
            -ProfilePath $pkg.ProfilePath `
            -SyntheticCapturesForTesting `
            -TestEnvironmentSnapshotPath $fixtureEnvironmentPath `
            -TestFaultStage 'PreCommit'
    } 'Injected failure before commit' 'pre-commit failure cleans up staging'

    if (Test-Path -LiteralPath $outPreCommit) {
        throw 'Pre-commit failure left output directory behind.'
    }

    [pscustomobject]@{
        EvidenceClassification = 'SyntheticVerifierSelftest'
        PositiveCases = $script:PositiveCases
        NegativeCases = $script:NegativeCases
        TotalCases = ($script:PositiveCases + $script:NegativeCases)
        BindingValidation = 'PASS'
        FinalHumanGo = 'NOT_OBSERVED'
        ActualHerdrRuntime = 'NOT_OBSERVED'
        Release = 'NOT_OBSERVED'
        CreditGranted = $false
    }
} finally {
    if (Test-Path -LiteralPath $temp) {
        Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue
    }
    [Environment]::SetEnvironmentVariable('HERDROPS_RENDERER_SELFTEST', $previousSelfTestMarker, 'Process')
}
