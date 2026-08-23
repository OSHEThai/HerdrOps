using System.IO;
using System.IO.Pipes;
using System.Diagnostics;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Windows;
using System.Windows.Interop;
using System.Windows.Threading;
using HerdrOps.App.RuntimeEvidence;
using HerdrOps.App.Localization;

namespace HerdrOps.RuntimeTests;

[TestClass]
public sealed class RendererTargetObservationProducerTests
{
    private const string Challenge = "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA";
    private static readonly string[] Stages =
    [
        "Startup", "PreFirstWindow", "PostFirstWindowShown", "BeforeThaiCaptures",
        "AfterThaiCaptures", "BeforeEnglishCaptures", "AfterEnglishCaptures", "Final",
    ];
    private static readonly string[] CaptureNames =
    [
        "dashboard-overview", "dashboard-live-organization", "dashboard-agent-detail",
        "widget-compact", "widget-normal", "widget-floating-vertical",
        "dashboard-overview-after-event", "widget-floating-vertical-after-dashboard-close",
        "widget-floating-vertical-offline", "widget-floating-vertical-reconnected",
    ];
    private static readonly byte[] OnePixelPng = Convert.FromBase64String(
        "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAusB9Y9Z7pAAAAAASUVORK5CYII=");
    [TestMethod]
    public void ParseRequestAcceptsOnlyExactGovernedFirstRequest()
    {
        var request = RendererTargetObservationProducer.ParseRequest(
            $"{{\"protocol\":\"V02RendererTargetObservation\",\"version\":1,\"issue\":149,\"stage\":\"Startup\",\"ordinal\":0,\"challenge\":\"{Challenge}\"}}",
            0,
            Challenge);

        Assert.AreEqual("Startup", request.Stage);
        Assert.AreEqual(0, request.Ordinal);
    }

    [TestMethod]
    [DataRow("{\"protocol\":\"V02RendererTargetObservation\",\"protocol\":\"V02RendererTargetObservation\",\"version\":1,\"issue\":149,\"stage\":\"Startup\",\"ordinal\":0}")]
    [DataRow("{\"version\":1,\"protocol\":\"V02RendererTargetObservation\",\"issue\":149,\"stage\":\"Startup\",\"ordinal\":0}")]
    [DataRow("{\"protocol\":\"V02RendererTargetObservation\",\"version\":1,\"issue\":149,\"stage\":\"PreFirstWindow\",\"ordinal\":0}")]
    [DataRow("{\"protocol\":\"V02RendererTargetObservation\",\"version\":1,\"issue\":149,\"stage\":\"Startup\",\"ordinal\":1}")]
    [DataRow("{\"protocol\":\"wrong\",\"version\":1,\"issue\":149,\"stage\":\"Startup\",\"ordinal\":0}")]
    public void ParseRequestRejectsDuplicateReorderedOrCrossStageClaims(string json)
    {
        Assert.ThrowsExactly<InvalidDataException>(
            () => RendererTargetObservationProducer.ParseRequest(json, 0, Challenge));
    }

    [TestMethod]
    public void ParseRequestRejectsWrongMutualAdmissionChallenge()
    {
        var json = $"{{\"protocol\":\"V02RendererTargetObservation\",\"version\":1,\"issue\":149,\"stage\":\"Startup\",\"ordinal\":0,\"challenge\":\"{new string('B', 64)}\"}}";
        Assert.ThrowsExactly<InvalidDataException>(() =>
            RendererTargetObservationProducer.ParseRequest(json, 0, Challenge));
    }

    [TestMethod]
    public void StablePngReadBindsSameHandleBytesAndDimensions()
    {
        var path = Path.Combine(Path.GetTempPath(), $"renderer-png-{Guid.NewGuid():N}.png");
        try
        {
            File.WriteAllBytes(path, Convert.FromBase64String(
                "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAusB9Y9Z7pAAAAAASUVORK5CYII="));

            var observed = RendererTargetObservationProducer.ReadStablePng(path);

            Assert.AreEqual(1, observed.Width);
            Assert.AreEqual(1, observed.Height);
            Assert.AreEqual(new FileInfo(path).Length, observed.Bytes);
            StringAssert.Matches(observed.Sha256, new System.Text.RegularExpressions.Regex("^[0-9A-F]{64}$"));
        }
        finally
        {
            File.Delete(path);
        }
    }

    [TestMethod]
    public void StablePngReadRejectsHeaderOnlyForgery()
    {
        var path = Path.Combine(Path.GetTempPath(), $"renderer-forged-{Guid.NewGuid():N}.png");
        try
        {
            File.WriteAllBytes(path, new byte[24]);
            Assert.ThrowsExactly<InvalidDataException>(
                () => RendererTargetObservationProducer.ReadStablePng(path));
        }
        finally
        {
            File.Delete(path);
        }
    }

    [TestMethod]
    public async Task CurrentUserPipeExposesExactServerPidToClient()
    {
        var name = $"herdrops-renderer-admission-{Guid.NewGuid():N}";
        await using var server = new NamedPipeServerStream(
            name,
            PipeDirection.InOut,
            1,
            PipeTransmissionMode.Byte,
            PipeOptions.Asynchronous | PipeOptions.CurrentUserOnly);
        await using var client = new NamedPipeClientStream(
            ".", name, PipeDirection.InOut,
            PipeOptions.Asynchronous | PipeOptions.CurrentUserOnly);
        var wait = server.WaitForConnectionAsync();
        await client.ConnectAsync(10_000);
        await wait;
        Assert.IsTrue(RendererTargetNativeMethods.GetNamedPipeServerProcessId(
            client.SafePipeHandle,
            out var pid));
        Assert.AreEqual((uint)Environment.ProcessId, pid);
    }

    [TestMethod]
    public void NativePreWindowGuardSeesHiddenProcessOwnedHwnd()
    {
        WpfTestHost.Run(() =>
        {
            var window = new Window { Width = 32, Height = 32, ShowInTaskbar = false };
            try
            {
                window.Show();
                var hwnd = new WindowInteropHelper(window).Handle;
                window.Hide();
                CollectionAssert.Contains(
                    RendererTargetNativeMethods.EnumerateProcessWindowHandles(Environment.ProcessId).ToArray(),
                    hwnd);
            }
            finally
            {
                window.Close();
            }
        }, TimeSpan.FromSeconds(30));
    }

    [TestMethod]
    public void RunnerCaptureRegistrationRejectsDuplicateTokenizedCapture()
    {
        var root = Path.Combine(Path.GetTempPath(), $"renderer-registration-{Guid.NewGuid():N}");
        var captures = Path.Combine(root, "captures", "Thai");
        Directory.CreateDirectory(captures);
        var path = Path.Combine(captures, "dashboard-overview.png");
        File.WriteAllBytes(path, Convert.FromBase64String(
            "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAusB9Y9Z7pAAAAAASUVORK5CYII="));
        var executable = Environment.ProcessPath!;
        var options = new RendererTargetObservationOptions(
            $"herdrops-v02-renderer-{new string('a', 32)}",
            root,
            captures,
            new string('a', 32),
            path,
            new string('A', 64),
            new string('b', 40),
            new string('c', 40),
            Environment.ProcessId == 1 ? 2 : 1,
            UiLanguage.Thai,
            Challenge,
            Environment.ProcessId == 2 ? 3 : 2,
            executable,
            Convert.ToHexString(SHA256.HashData(File.ReadAllBytes(executable))));
        var producer = new RendererTargetObservationProducer(options);
        try
        {
            var token = new string('D', 64);
            File.SetLastWriteTimeUtc(path, new DateTime(2000, 1, 1, 0, 0, 0, DateTimeKind.Utc));
            Assert.ThrowsExactly<InvalidDataException>(() =>
                producer.RegisterRunnerCapture("Thai", "dashboard-overview", path, token));
            File.SetLastWriteTimeUtc(path, DateTime.UtcNow);
            producer.RegisterRunnerCapture("Thai", "dashboard-overview", path, token);
            Assert.ThrowsExactly<InvalidOperationException>(() =>
                producer.RegisterRunnerCapture("Thai", "dashboard-overview", path, token));
        }
        finally
        {
            Directory.Delete(root, recursive: true);
        }
    }

    [TestMethod]
    public void ProductionProtocolCompletesAllEightOrderedStages()
    {
        WpfTestHost.Run(() =>
        {
            using var fixture = new ProducerFixture(attemptCaptureSwap: true);
            Window? window = null;
            try
            {
                var server = fixture.RunServerAsync(null, null);
                fixture.Producer.Start();
                var orchestration = Task.Run(async () =>
                {
                    await fixture.Producer.WaitForFirstWindowPermissionAsync(CancellationToken.None);
                    await Application.Current.Dispatcher.InvokeAsync(() =>
                    {
                        window = new Window { Width = 32, Height = 32, ShowInTaskbar = false };
                        window.Show();
                        fixture.Producer.AttachFirstWindow(window);
                    });
                    await fixture.Producer.WaitForThaiCapturePermissionAsync(CancellationToken.None);
                    fixture.RegisterLanguage("Thai");
                    await fixture.Producer.WaitForEnglishCapturePermissionAsync(CancellationToken.None);
                    fixture.RegisterLanguage("English");
                    await fixture.Producer.Completion;
                    await server;
                });
                PumpDispatcherUntil(orchestration, TimeSpan.FromSeconds(30));
                Assert.IsTrue(fixture.Producer.PendingWaitersForTesting.All(task => task.IsCompletedSuccessfully));
                Assert.IsTrue(fixture.CaptureSwapBlocked,
                    "The production ReadBoundPng handle did not block the hostile FileId/path swap.");
            }
            finally
            {
                window?.Close();
                fixture.Producer.DisposeAsync().AsTask().GetAwaiter().GetResult();
            }
        }, TimeSpan.FromSeconds(45));
    }

    [TestMethod]
    [DataRow(1, null, "mid-protocol EOF")]
    [DataRow(null, 1, "invalid stage")]
    public void TerminalProtocolFailureFaultsEveryPendingWaiterPromptly(
        int? failAfterOrdinal,
        int? invalidOrdinal,
        string scenario)
    {
        WpfTestHost.Run(() =>
        {
            using var fixture = new ProducerFixture();
            var server = fixture.RunServerAsync(failAfterOrdinal, invalidOrdinal);
            Assert.IsTrue(fixture.CoreExecutableReady,
                "The fixture did not establish the exact Core executable identity before Producer.Start().");
            Assert.AreEqual("ping.exe", Path.GetFileName(fixture.CoreExecutablePath), true);
            Assert.IsGreaterThan(0, fixture.CoreProcessId);
            Assert.IsGreaterThan(DateTime.UnixEpoch, fixture.CoreStartTimeUtc);
            fixture.Producer.Start();
            // RunServerAsync captures this STA dispatcher. Waiting only for the
            // producer and then synchronously observing the server can deadlock
            // when its final WriteLineAsync continuation is still queued here.
            // Keep pumping until both protocol peers have terminated.
            var protocol = Task.WhenAll(fixture.Producer.Completion, server);
            PumpDispatcherUntil(protocol, TimeSpan.FromSeconds(10), expectFailure: true);
            Assert.IsTrue(server.IsCompleted, $"{scenario} left the protocol server pending.");
            try { server.GetAwaiter().GetResult(); }
            catch (InvalidOperationException) when (failAfterOrdinal is not null) { }
            Assert.IsTrue(fixture.Producer.PendingWaitersForTesting.All(task => task.IsCompleted),
                $"{scenario} left a producer waiter pending.");
            Assert.IsTrue(fixture.Producer.PendingWaitersForTesting.All(task => task.IsFaulted),
                $"{scenario} did not propagate the terminal exception to every waiter.");
            if (failAfterOrdinal is not null)
            {
                Assert.AreEqual(failAfterOrdinal.Value, fixture.TerminalDisconnectOrdinal,
                    "The hostile server did not inject EOF at the intended protocol ordinal.");
                Assert.AreEqual(failAfterOrdinal.Value - 1, fixture.LastAcknowledgedOrdinal,
                    "The producer did not complete the preceding stage before hostile EOF injection.");
                Assert.AreEqual(-1, fixture.InvalidStageOrdinal);
            }
            else
            {
                Assert.AreEqual(invalidOrdinal!.Value, fixture.InvalidStageOrdinal,
                    "The hostile server did not send the intended invalid stage.");
                Assert.AreEqual(invalidOrdinal.Value - 1, fixture.LastAcknowledgedOrdinal,
                    "The producer did not complete the preceding stage before the invalid request.");
                Assert.AreEqual(-1, fixture.TerminalDisconnectOrdinal);
            }
            var terminal = fixture.Producer.Completion.Exception!.InnerExceptions.Single();
            if (failAfterOrdinal is not null)
            {
                if (terminal is InvalidDataException)
                {
                    Assert.AreEqual("Renderer target observation request is empty or oversized.", terminal.Message);
                }
                else
                {
                    // Windows named-pipe disconnect can surface either as a clean
                    // EOF (parsed above) or as the exact transport IOException.
                    Assert.IsInstanceOfType<IOException>(terminal);
                }
            }
            else
            {
                Assert.IsInstanceOfType<InvalidDataException>(terminal);
                Assert.AreEqual("Renderer target observation request binding is invalid.", terminal.Message);
            }
            Assert.IsTrue(fixture.Producer.PendingWaitersForTesting.All(task =>
                    ReferenceEquals(terminal, task.Exception!.InnerExceptions.Single())),
                $"{scenario} did not propagate the exact terminal protocol exception to every waiter.");
            try { fixture.Producer.DisposeAsync().AsTask().GetAwaiter().GetResult(); }
            catch { /* The expected terminal protocol failure remains observable on Completion. */ }
        }, TimeSpan.FromSeconds(20));
    }

    [TestMethod]
    [DataRow("hardlink", "exactly one hard link")]
    [DataRow("junction", "reparse point")]
    public void ProductionProtocolRegistrationReachesExactHostileCaptureGuard(
        string hostile,
        string expectedMessage)
    {
        WpfTestHost.Run(() =>
        {
            using var fixture = new ProducerFixture();
            Window? window = null;
            try
            {
                var server = fixture.RunServerAsync(null, null);
                fixture.Producer.Start();
                var orchestration = Task.Run(async () =>
                {
                    await fixture.Producer.WaitForFirstWindowPermissionAsync(CancellationToken.None);
                    await Application.Current.Dispatcher.InvokeAsync(() =>
                    {
                        window = new Window { Width = 32, Height = 32, ShowInTaskbar = false };
                        window.Show();
                        fixture.Producer.AttachFirstWindow(window);
                    });
                    await fixture.Producer.WaitForThaiCapturePermissionAsync(CancellationToken.None);
                    var error = Assert.ThrowsExactly<UnauthorizedAccessException>(() =>
                        fixture.RegisterHostileThaiCapture(hostile));
                    StringAssert.Contains(error.Message, expectedMessage, StringComparison.OrdinalIgnoreCase);
                    try { await fixture.Producer.DisposeAsync(); } catch { }
                    try { await server; } catch { }
                });
                PumpDispatcherUntil(orchestration, TimeSpan.FromSeconds(20));
            }
            finally
            {
                window?.Close();
            }
        }, TimeSpan.FromSeconds(30));
    }

    private static void PumpDispatcherUntil(Task task, TimeSpan timeout, bool expectFailure = false)
    {
        var deadline = DateTime.UtcNow + timeout;
        while (!task.IsCompleted && DateTime.UtcNow < deadline)
        {
            var frame = new DispatcherFrame();
            Dispatcher.CurrentDispatcher.BeginInvoke(
                DispatcherPriority.Background,
                new Action(() => frame.Continue = false));
            Dispatcher.PushFrame(frame);
        }
        if (!task.IsCompleted) throw new TimeoutException("Renderer protocol did not terminate promptly.");
        if (expectFailure)
        {
            Assert.IsTrue(task.IsFaulted, "Renderer protocol unexpectedly succeeded.");
            return;
        }
        task.GetAwaiter().GetResult();
    }

    private sealed class ProducerFixture : IDisposable
    {
        private readonly NamedPipeServerStream _server;
        private readonly Process _core;
        private readonly bool _attemptCaptureSwap;
        private int _captureSwapAttempted;
        private string? _swapTarget;
        private string? _swapReplacement;
        private string? _junction;
        private string? _junctionOutside;

        public ProducerFixture(bool attemptCaptureSwap = false)
        {
            _attemptCaptureSwap = attemptCaptureSwap;
            Root = Path.Combine(Path.GetTempPath(), $"renderer-protocol-{Guid.NewGuid():N}");
            Directory.CreateDirectory(Path.Combine(Root, "captures", "Thai"));
            Directory.CreateDirectory(Path.Combine(Root, "captures", "English"));
            var pipeName = $"herdrops-renderer-protocol-{Guid.NewGuid():N}";
            _server = new NamedPipeServerStream(pipeName, PipeDirection.InOut, 1,
                PipeTransmissionMode.Byte, PipeOptions.Asynchronous | PipeOptions.CurrentUserOnly);
            var corePath = Path.GetFullPath(Path.Combine(Environment.SystemDirectory, "ping.exe"));
            _core = Process.Start(new ProcessStartInfo(corePath, "-n 60 127.0.0.1")
            {
                CreateNoWindow = true,
                UseShellExecute = false,
            })!;
            (string Sha256, DateTime StartTimeUtc) coreIdentity;
            try
            {
                coreIdentity = WaitForCoreExecutableReady(_core, corePath);
            }
            catch
            {
                if (!_core.HasExited) _core.Kill(entireProcessTree: true);
                _core.Dispose();
                _server.Dispose();
                if (Directory.Exists(Root)) Directory.Delete(Root, recursive: true);
                throw;
            }
            CoreExecutableReady = true;
            CoreExecutablePath = corePath;
            CoreProcessId = _core.Id;
            CoreStartTimeUtc = coreIdentity.StartTimeUtc;
            var appPath = Path.GetFullPath(Environment.ProcessPath!);
            var appSha = Convert.ToHexString(SHA256.HashData(File.ReadAllBytes(appPath)));
            var coreSha = coreIdentity.Sha256;
            var identityPath = Path.Combine(Root, "identity.json");
            var canonical = JsonSerializer.Serialize(new
            {
                source = new { commitSha = new string('b', 40), treeSha = new string('c', 40) },
                components = new { app = new { sha256 = appSha }, core = new { sha256 = coreSha } },
            });
            File.WriteAllText(identityPath, canonical + "\n", new UTF8Encoding(false));
            Action? captureHook = attemptCaptureSwap ? AttemptCaptureSwap : null;
            Producer = new RendererTargetObservationProducer(new RendererTargetObservationOptions(
                pipeName, Root, Path.Combine(Root, "captures", "Thai"), new string('a', 32),
                identityPath, Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(canonical))),
                new string('b', 40), new string('c', 40), _core.Id, UiLanguage.Thai, Challenge,
                Environment.ProcessId, appPath, appSha), static _ => [], captureHook);
        }

        public string Root { get; }
        public RendererTargetObservationProducer Producer { get; }
        public bool CaptureSwapBlocked { get; private set; }
        public bool CoreExecutableReady { get; }
        public string CoreExecutablePath { get; }
        public int CoreProcessId { get; }
        public DateTime CoreStartTimeUtc { get; }
        public int LastAcknowledgedOrdinal { get; private set; } = -1;
        public int TerminalDisconnectOrdinal { get; private set; } = -1;
        public int InvalidStageOrdinal { get; private set; } = -1;

        public async Task RunServerAsync(int? failAfterOrdinal, int? invalidOrdinal)
        {
            await _server.WaitForConnectionAsync();
            using var reader = new StreamReader(_server, new UTF8Encoding(false, true), false, 65_536, true);
            using var writer = new StreamWriter(_server, new UTF8Encoding(false), 65_536, true)
            { AutoFlush = true, NewLine = "\n" };
            for (var ordinal = 0; ordinal < Stages.Length; ordinal++)
            {
                if (failAfterOrdinal == ordinal)
                {
                    TerminalDisconnectOrdinal = ordinal;
                    _server.Disconnect();
                    return;
                }
                var stage = invalidOrdinal == ordinal ? "InvalidStage" : Stages[ordinal];
                if (invalidOrdinal == ordinal) InvalidStageOrdinal = ordinal;
                await writer.WriteLineAsync(
                    $"{{\"protocol\":\"V02RendererTargetObservation\",\"version\":1,\"issue\":149,\"stage\":\"{stage}\",\"ordinal\":{ordinal},\"challenge\":\"{Challenge}\"}}");
                if (invalidOrdinal == ordinal) return;
                if (string.IsNullOrWhiteSpace(await reader.ReadLineAsync()))
                    throw new IOException("Producer closed without a response.");
                LastAcknowledgedOrdinal = ordinal;
            }
        }

        private static (string Sha256, DateTime StartTimeUtc) WaitForCoreExecutableReady(
            Process core,
            string expectedPath)
        {
            var deadline = Stopwatch.StartNew();
            string? lastMismatch = null;
            while (deadline.Elapsed < TimeSpan.FromSeconds(5))
            {
                core.Refresh();
                if (core.HasExited)
                {
                    throw new InvalidOperationException("Renderer fixture Core process exited before identity readiness.");
                }

                var expectedStartTimeUtc = core.StartTime.ToUniversalTime();
                using var observed = Process.GetProcessById(core.Id);
                observed.Refresh();
                var modulePath = observed.MainModule?.FileName;
                if (modulePath is null)
                {
                    Thread.Sleep(10);
                    continue;
                }

                modulePath = Path.GetFullPath(modulePath);
                if (!string.Equals(modulePath, expectedPath, StringComparison.OrdinalIgnoreCase) ||
                    observed.StartTime.ToUniversalTime() != expectedStartTimeUtc)
                {
                    lastMismatch =
                        $"expectedPath={expectedPath}; observedPath={modulePath}; " +
                        $"expectedStart={expectedStartTimeUtc:O}; observedStart={observed.StartTime.ToUniversalTime():O}";
                    Thread.Sleep(10);
                    continue;
                }

                using var stream = new FileStream(modulePath, FileMode.Open, FileAccess.Read, FileShare.Read);
                var length = stream.Length;
                var finalPath = RendererTargetNativeMethods.GetFinalPath(stream.SafeFileHandle);
                var sha256 = Convert.ToHexString(SHA256.HashData(stream));
                if (!string.Equals(finalPath, expectedPath, StringComparison.OrdinalIgnoreCase) ||
                    stream.Length != length)
                {
                    lastMismatch =
                        $"expectedFinalPath={expectedPath}; observedFinalPath={finalPath}; " +
                        $"expectedLength={length}; observedLength={stream.Length}";
                    Thread.Sleep(10);
                    continue;
                }

                observed.Refresh();
                if (observed.HasExited || observed.Id != core.Id ||
                    observed.StartTime.ToUniversalTime() != expectedStartTimeUtc)
                {
                    lastMismatch = "Renderer fixture Core PID/start identity changed during executable verification.";
                    Thread.Sleep(10);
                    continue;
                }

                return (sha256, expectedStartTimeUtc);
            }

            throw new InvalidOperationException(
                "Renderer fixture Core executable identity was not ready within the bounded fixture setup period. " +
                lastMismatch);
        }

        public void RegisterLanguage(string language)
        {
            var directory = Path.Combine(Root, "captures", language);
            for (var index = 0; index < CaptureNames.Length; index++)
            {
                var path = Path.Combine(directory, CaptureNames[index] + ".png");
                File.WriteAllBytes(path, OnePixelPng);
                File.SetLastWriteTimeUtc(path, DateTime.UtcNow);
                if (_attemptCaptureSwap && language == "Thai" && index == 0)
                {
                    _swapTarget = path;
                    _swapReplacement = Path.Combine(directory, "hostile-replacement.png");
                    File.WriteAllBytes(_swapReplacement, OnePixelPng);
                }
                Producer.RegisterRunnerCapture(language, CaptureNames[index], path,
                    Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(
                        $"{language}|{index}|{Guid.NewGuid():N}"))));
            }
        }

        public void RegisterHostileThaiCapture(string hostile)
        {
            var thai = Path.Combine(Root, "captures", "Thai");
            var path = Path.Combine(thai, "dashboard-overview.png");
            if (hostile == "hardlink")
            {
                File.WriteAllBytes(path, OnePixelPng);
                Assert.IsTrue(CreateHardLink(Path.Combine(thai, "dashboard-overview-alias.png"), path, IntPtr.Zero));
            }
            else
            {
                _junctionOutside = Path.Combine(Path.GetTempPath(), $"renderer-outside-{Guid.NewGuid():N}");
                Directory.CreateDirectory(_junctionOutside);
                File.WriteAllBytes(Path.Combine(_junctionOutside, "dashboard-overview.png"), OnePixelPng);
                _junction = Path.Combine(thai, "hostile-junction");
                using var mklink = Process.Start(new ProcessStartInfo(
                    "cmd.exe", $"/d /c mklink /J \"{_junction}\" \"{_junctionOutside}\"")
                { CreateNoWindow = true, UseShellExecute = false })!;
                mklink.WaitForExit();
                Assert.AreEqual(0, mklink.ExitCode);
                path = Path.Combine(_junction, "dashboard-overview.png");
            }
            Producer.RegisterRunnerCapture("Thai", "dashboard-overview", path, new string('D', 64));
        }

        private void AttemptCaptureSwap()
        {
            if (Interlocked.Exchange(ref _captureSwapAttempted, 1) != 0 ||
                _swapTarget is null || _swapReplacement is null) return;
            try { File.Move(_swapReplacement, _swapTarget, overwrite: true); }
            catch (Exception exception) when (exception is IOException or UnauthorizedAccessException)
            {
                CaptureSwapBlocked = true;
            }
        }

        public void Dispose()
        {
            _server.Dispose();
            if (!_core.HasExited) _core.Kill(entireProcessTree: true);
            _core.Dispose();
            if (_junction is not null && Directory.Exists(_junction)) Directory.Delete(_junction);
            if (_junctionOutside is not null && Directory.Exists(_junctionOutside))
                Directory.Delete(_junctionOutside, recursive: true);
            if (Directory.Exists(Root)) Directory.Delete(Root, recursive: true);
        }
    }

    [System.Runtime.InteropServices.DllImport("kernel32.dll", CharSet = System.Runtime.InteropServices.CharSet.Unicode, SetLastError = true)]
    [return: System.Runtime.InteropServices.MarshalAs(System.Runtime.InteropServices.UnmanagedType.Bool)]
    private static extern bool CreateHardLink(string newFileName, string existingFileName, IntPtr securityAttributes);
}
