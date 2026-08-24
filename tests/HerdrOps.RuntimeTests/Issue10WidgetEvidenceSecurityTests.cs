using System.IO;
using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Text;
using HerdrOps.App.RuntimeEvidence;

namespace HerdrOps.RuntimeTests;

[TestClass]
public sealed class Issue10WidgetEvidenceSecurityTests
{
    [TestMethod]
    public void ProductionHeldJsonSuccessReturnsExactHeldByteHash()
    {
        using var fixture = new TemporaryDirectory();
        var path = Path.Combine(fixture.Path, "app-report.json");
        var bytes = Encoding.UTF8.GetBytes("{\"EvidenceClassification\":\"RuntimeCandidate\"}\n");
        File.WriteAllBytes(path, bytes);

        var actual = Issue10WidgetEvidenceProducer.HoldAndParseJsonForTesting(path);

        Assert.AreEqual(Convert.ToHexString(SHA256.HashData(bytes)), actual);
    }

    [TestMethod]
    public void PostOpenLeafSwapIsBlockedWhileProductionBytesRemainHeld()
    {
        using var fixture = new TemporaryDirectory();
        var path = Path.Combine(fixture.Path, "app-report.json");
        var replacement = Path.Combine(fixture.Path, "replacement.json");
        File.WriteAllText(path, "{\"run\":1}\n");
        File.WriteAllText(replacement, "{\"run\":2}\n");
        var swapBlocked = false;

        var hash = Issue10WidgetEvidenceProducer.HoldAndParseJsonForTesting(path, () =>
        {
            try
            {
                File.Move(replacement, path, overwrite: true);
            }
            catch (Exception exception) when (exception is IOException or UnauthorizedAccessException)
            {
                swapBlocked = true;
            }
        });

        Assert.IsTrue(swapBlocked, "The App-report pathname was replaceable after the production held-byte read.");
        Assert.AreEqual(Convert.ToHexString(SHA256.HashData(File.ReadAllBytes(path))), hash);
    }

    [TestMethod]
    public void PostPublicationReplacementFailsAndPreservesCallerReplacement()
    {
        using var fixture = new TemporaryDirectory();
        var path = Path.Combine(fixture.Path, "widget.json");
        var replacement = Path.Combine(fixture.Path, "replacement.json");
        File.WriteAllText(replacement, "{\"Issue\":999}\r\n");
        Exception? failure = null;
        try
        {
            Issue10WidgetEvidenceProducer.PublishOwnedJsonForTesting(path, () =>
            {
                File.Move(replacement, path, overwrite: true);
            });
        }
        catch (Exception exception)
        {
            failure = exception;
        }
        Assert.IsNotNull(failure, "A replacement during the publication post-check was accepted.");

        Assert.IsFalse(File.Exists(path), "Failed publication retained its owned output pathname.");
        Assert.AreEqual("{\"Issue\":999}\r\n", File.ReadAllText(replacement),
            "Exact-identity cleanup deleted or changed the caller replacement.");
    }

    [TestMethod]
    public void PostPublicationHardLinkFailureDeletesEveryOwnedAlias()
    {
        using var fixture = new TemporaryDirectory();
        var path = Path.Combine(fixture.Path, "widget.json");
        var alias = Path.Combine(fixture.Path, "widget-alias.json");

        Assert.ThrowsExactly<InvalidOperationException>(() =>
            Issue10WidgetEvidenceProducer.PublishOwnedJsonForTesting(path, () =>
            {
                Assert.IsTrue(CreateHardLink(alias, path, IntPtr.Zero),
                    $"CreateHardLink failed: {Marshal.GetLastWin32Error()}");
            }));

        Assert.IsFalse(File.Exists(path), "Failed publication retained its owned output pathname.");
        Assert.IsFalse(File.Exists(alias), "Failed publication retained a hard-link alias to owned bytes.");
    }

    [TestMethod]
    public void PreexistingWidgetOutputIsNeverClobberedOrDeleted()
    {
        using var fixture = new TemporaryDirectory();
        var path = Path.Combine(fixture.Path, "widget.json");
        File.WriteAllText(path, "caller-owned");

        Assert.ThrowsExactly<InvalidOperationException>(() =>
            Issue10WidgetEvidenceProducer.PublishOwnedJsonForTesting(path));

        Assert.AreEqual("caller-owned", File.ReadAllText(path));
    }

    [TestMethod]
    public void HardlinkedAuthorityArtifactFailsTheExactSingleLinkGuard()
    {
        using var fixture = new TemporaryDirectory();
        var path = Path.Combine(fixture.Path, "authority.json");
        var alias = Path.Combine(fixture.Path, "authority-alias.json");
        File.WriteAllText(path, "{}\n");
        Assert.IsTrue(CreateHardLink(alias, path, IntPtr.Zero), $"CreateHardLink failed: {Marshal.GetLastWin32Error()}");

        var error = Assert.ThrowsExactly<InvalidOperationException>(() =>
            Issue10WidgetEvidenceProducer.HoldContainedArtifactForTesting(fixture.Path, path));

        StringAssert.Contains(error.Message, "exactly one hard link", StringComparison.Ordinal);
    }

    [TestMethod]
    public void JunctionComponentFailsBeforeContainedArtifactAdmission()
    {
        using var fixture = new TemporaryDirectory();
        using var outside = new TemporaryDirectory();
        File.WriteAllText(Path.Combine(outside.Path, "authority.json"), "{}\n");
        var junction = Path.Combine(fixture.Path, "junction");
        try
        {
            Directory.CreateSymbolicLink(junction, outside.Path);
        }
        catch (UnauthorizedAccessException)
        {
            Assert.Inconclusive("The test host cannot create a directory reparse point.");
        }

        var error = Assert.ThrowsExactly<InvalidOperationException>(() =>
            Issue10WidgetEvidenceProducer.HoldContainedArtifactForTesting(
                fixture.Path,
                Path.Combine(junction, "authority.json")));

        StringAssert.Contains(error.Message, "reparse-point component", StringComparison.Ordinal);
    }

    private sealed class TemporaryDirectory : IDisposable
    {
        public TemporaryDirectory()
        {
            Path = System.IO.Path.Combine(System.IO.Path.GetTempPath(), $"HerdrOps-Issue10-{Guid.NewGuid():N}");
            Directory.CreateDirectory(Path);
        }

        public string Path { get; }

        public void Dispose()
        {
            if (Directory.Exists(Path))
            {
                Directory.Delete(Path, recursive: true);
            }
        }
    }

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool CreateHardLink(string newFileName, string existingFileName, IntPtr securityAttributes);
}
