using HerdrOps.App.Localization;
using HerdrOps.App.RuntimeEvidence;

namespace HerdrOps.IntegrationTests;

[TestClass]
public sealed class RuntimeEvidenceOptionsTests
{
    [TestMethod]
    public void RuntimeEvidenceOptionsRequireExplicitOutputsAndCoreProcess()
    {
        using var directory = new TemporaryDirectory();
        var report = Path.Combine(directory.Path, "app-runtime.json");
        var captures = Path.Combine(directory.Path, "captures");

        var parsed = RuntimeEvidenceOptions.TryParse(
            [
                "--runtime-evidence-report", report,
                "--capture-directory", captures,
                "--core-pid", "1234",
                "--language", "en",
                "--timeout-seconds", "240",
                "--idle-seconds", "15",
            ],
            out var options,
            out var error);

        Assert.IsTrue(parsed, error);
        Assert.IsNotNull(options);
        Assert.AreEqual(Path.GetFullPath(report), options.ReportPath);
        Assert.AreEqual(Path.GetFullPath(captures), options.CaptureDirectory);
        Assert.AreEqual(1234, options.CoreProcessId);
        Assert.AreEqual(240, options.TimeoutSeconds);
        Assert.AreEqual(15, options.IdleSeconds);
        Assert.AreEqual(UiLanguage.English, options.Language);
        Assert.IsTrue(RuntimeEvidenceOptions.IsRequested(
            ["--runtime-evidence-report", report]));
    }

    [TestMethod]
    public void RuntimeEvidenceOptionsRejectUnknownOrUnsafeValues()
    {
        Assert.IsFalse(RuntimeEvidenceOptions.TryParse(
            ["--runtime-evidence-report", "report.json"],
            out _,
            out var missingError));
        StringAssert.Contains(missingError, "requires", StringComparison.OrdinalIgnoreCase);

        Assert.IsFalse(RuntimeEvidenceOptions.TryParse(
            [
                "--runtime-evidence-report", "report.json",
                "--capture-directory", "captures",
                "--core-pid", "0",
            ],
            out _,
            out var processError));
        StringAssert.Contains(processError, "positive", StringComparison.OrdinalIgnoreCase);

        Assert.IsFalse(RuntimeEvidenceOptions.TryParse(
            ["--unsupported", "value"],
            out _,
            out var unknownError));
        StringAssert.Contains(unknownError, "Unknown", StringComparison.Ordinal);
    }
}
