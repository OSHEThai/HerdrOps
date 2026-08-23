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
                    fixture.RegisterLanguage("Thai");
                    await fixture.Producer.WaitForEnglishCapturePermissionAsync(CancellationToken.None);
                    fixture.RegisterLanguage("English");
                    await fixture.Producer.Completion;
                    await server;
                });
                PumpDispatcherUntil(orchestration, TimeSpan.FromSeconds(30));
                Assert.IsTrue(fixture.Producer.PendingWaitersForTesting.All(task => task.IsCompletedSuccessfully));
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
            fixture.Producer.Start();
            PumpDispatcherUntil(fixture.Producer.Completion, TimeSpan.FromSeconds(10), expectFailure: true);
            try { server.GetAwaiter().GetResult(); }
            catch (InvalidOperationException) when (failAfterOrdinal is not null) { }
            Assert.IsTrue(fixture.Producer.PendingWaitersForTesting.All(task => task.IsCompleted),
                $"{scenario} left a producer waiter pending.");
            Assert.IsTrue(fixture.Producer.PendingWaitersForTesting.All(task => task.IsFaulted),
                $"{scenario} did not propagate the terminal exception to every waiter.");
            try { fixture.Producer.DisposeAsync().AsTask().GetAwaiter().GetResult(); }
            catch { /* The expected terminal protocol failure remains observable on Completion. */ }
        }, TimeSpan.FromSeconds(20));
    }

    [TestMethod]
    public void StablePngRejectsHardlinkedLeaf()
    {
        var directory = Path.Combine(Path.GetTempPath(), $"renderer-hardlink-{Guid.NewGuid():N}");
        Directory.CreateDirectory(directory);
        var path = Path.Combine(directory, "capture.png");
        var alias = Path.Combine(directory, "capture-alias.png");
        try
        {
            File.WriteAllBytes(path, OnePixelPng);
            Assert.IsTrue(CreateHardLink(alias, path, IntPtr.Zero));
            Assert.ThrowsExactly<UnauthorizedAccessException>(() =>
                RendererTargetObservationProducer.ReadStablePng(path));
        }
        finally
        {
            Directory.Delete(directory, recursive: true);
        }
    }

    [TestMethod]
    public void StablePngRejectsJunctionAncestorFromVolumeRoot()
    {
        var directory = Path.Combine(Path.GetTempPath(), $"renderer-junction-{Guid.NewGuid():N}");
        var outside = Path.Combine(Path.GetTempPath(), $"renderer-junction-outside-{Guid.NewGuid():N}");
        var junction = Path.Combine(directory, "bound-root");
        Directory.CreateDirectory(directory);
        Directory.CreateDirectory(outside);
        File.WriteAllBytes(Path.Combine(outside, "capture.png"), OnePixelPng);
        try
        {
            using var mklink = Process.Start(new ProcessStartInfo(
                "cmd.exe", $"/d /c mklink /J \"{junction}\" \"{outside}\"")
            { CreateNoWindow = true, UseShellExecute = false })!;
            mklink.WaitForExit();
            Assert.AreEqual(0, mklink.ExitCode, "The hostile junction fixture was not created.");
            Assert.ThrowsExactly<UnauthorizedAccessException>(() =>
                RendererTargetObservationProducer.ReadStablePng(Path.Combine(junction, "capture.png")));
        }
        finally
        {
            if (Directory.Exists(junction)) Directory.Delete(junction);
            Directory.Delete(directory, recursive: true);
            Directory.Delete(outside, recursive: true);
        }
    }

    [TestMethod]
    public void StablePngBlocksFileIdPathSwapWhileExactHandleIsHeld()
    {
        var directory = Path.Combine(Path.GetTempPath(), $"renderer-swap-{Guid.NewGuid():N}");
        Directory.CreateDirectory(directory);
        var path = Path.Combine(directory, "capture.png");
        var replacement = Path.Combine(directory, "replacement.png");
        File.WriteAllBytes(path, OnePixelPng);
        File.WriteAllBytes(replacement, OnePixelPng);
        var blocked = false;
        try
        {
            _ = RendererTargetObservationProducer.ReadStablePng(path, () =>
            {
                try { File.Move(replacement, path, overwrite: true); }
                catch (Exception exception) when (exception is IOException or UnauthorizedAccessException) { blocked = true; }
            });
            Assert.IsTrue(blocked, "The capture pathname/FileId was replaceable while its exact handle was held.");
        }
        finally
        {
            Directory.Delete(directory, recursive: true);
        }
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

        public ProducerFixture()
        {
            Root = Path.Combine(Path.GetTempPath(), $"renderer-protocol-{Guid.NewGuid():N}");
            Directory.CreateDirectory(Path.Combine(Root, "captures", "Thai"));
            Directory.CreateDirectory(Path.Combine(Root, "captures", "English"));
            var pipeName = $"herdrops-renderer-protocol-{Guid.NewGuid():N}";
            _server = new NamedPipeServerStream(pipeName, PipeDirection.InOut, 1,
                PipeTransmissionMode.Byte, PipeOptions.Asynchronous | PipeOptions.CurrentUserOnly);
            _core = Process.Start(new ProcessStartInfo("ping.exe", "-n 60 127.0.0.1")
            {
                CreateNoWindow = true,
                UseShellExecute = false,
            })!;
            _core.Refresh();
            var appPath = Path.GetFullPath(Environment.ProcessPath!);
            var corePath = Path.GetFullPath(_core.MainModule!.FileName);
            var appSha = Convert.ToHexString(SHA256.HashData(File.ReadAllBytes(appPath)));
            var coreSha = Convert.ToHexString(SHA256.HashData(File.ReadAllBytes(corePath)));
            var identityPath = Path.Combine(Root, "identity.json");
            var canonical = JsonSerializer.Serialize(new
            {
                source = new { commitSha = new string('b', 40), treeSha = new string('c', 40) },
                components = new { app = new { sha256 = appSha }, core = new { sha256 = coreSha } },
            });
            File.WriteAllText(identityPath, canonical + "\n", new UTF8Encoding(false));
            Producer = new RendererTargetObservationProducer(new RendererTargetObservationOptions(
                pipeName, Root, Path.Combine(Root, "captures", "Thai"), new string('a', 32),
                identityPath, Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(canonical))),
                new string('b', 40), new string('c', 40), _core.Id, UiLanguage.Thai, Challenge,
                Environment.ProcessId, appPath, appSha), static _ => []);
        }

        public string Root { get; }
        public RendererTargetObservationProducer Producer { get; }

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
                    _server.Disconnect();
                    return;
                }
                var stage = invalidOrdinal == ordinal ? "InvalidStage" : Stages[ordinal];
                await writer.WriteLineAsync(
                    $"{{\"protocol\":\"V02RendererTargetObservation\",\"version\":1,\"issue\":149,\"stage\":\"{stage}\",\"ordinal\":{ordinal},\"challenge\":\"{Challenge}\"}}");
                if (invalidOrdinal == ordinal) return;
                if (string.IsNullOrWhiteSpace(await reader.ReadLineAsync()))
                    throw new IOException("Producer closed without a response.");
            }
        }

        public void RegisterLanguage(string language)
        {
            var directory = Path.Combine(Root, "captures", language);
            for (var index = 0; index < CaptureNames.Length; index++)
            {
                var path = Path.Combine(directory, CaptureNames[index] + ".png");
                File.WriteAllBytes(path, OnePixelPng);
                File.SetLastWriteTimeUtc(path, DateTime.UtcNow);
                Producer.RegisterRunnerCapture(language, CaptureNames[index], path,
                    Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(
                        $"{language}|{index}|{Guid.NewGuid():N}"))));
            }
        }

        public void Dispose()
        {
            _server.Dispose();
            if (!_core.HasExited) _core.Kill(entireProcessTree: true);
            _core.Dispose();
            if (Directory.Exists(Root)) Directory.Delete(Root, recursive: true);
        }
    }

    [System.Runtime.InteropServices.DllImport("kernel32.dll", CharSet = System.Runtime.InteropServices.CharSet.Unicode, SetLastError = true)]
    [return: System.Runtime.InteropServices.MarshalAs(System.Runtime.InteropServices.UnmanagedType.Bool)]
    private static extern bool CreateHardLink(string newFileName, string existingFileName, IntPtr securityAttributes);
}
