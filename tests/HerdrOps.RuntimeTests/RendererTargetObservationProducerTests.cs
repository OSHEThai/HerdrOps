using System.IO;
using System.IO.Pipes;
using System.Diagnostics;
using System.Security.Cryptography;
using System.Windows;
using System.Windows.Interop;
using HerdrOps.App.RuntimeEvidence;
using HerdrOps.App.Localization;

namespace HerdrOps.RuntimeTests;

[TestClass]
public sealed class RendererTargetObservationProducerTests
{
    private const string Challenge = "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA";
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
}
