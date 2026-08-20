using HerdrOps.Core;
using HerdrOps.Contracts.ReviewIpc;
using HerdrOps.Domain.Activity;

namespace HerdrOps.UnitTests;

[TestClass]
public sealed class ComplianceReviewRuntimeTraceTests
{
    [TestMethod]
    public void MissingCommandNameFailsWithUsageCode()
    {
        using var output = new StringWriter();
        using var error = new StringWriter();

        var exitCode = ComplianceReviewRuntimeTraceCommand.Run([], output, error);

        Assert.AreEqual(ComplianceReviewRuntimeTraceCommand.UsageFailureExitCode, exitCode);
        StringAssert.Contains(error.ToString(), "command name is required");
    }

    [TestMethod]
    public void HelpFlagReturnsSuccessExitCodeAndPrintsUsage()
    {
        using var output = new StringWriter();
        using var error = new StringWriter();

        var exitCode = ComplianceReviewRuntimeTraceCommand.Run(["trace-compliance-review", "--help"], output, error);

        Assert.AreEqual(ComplianceReviewRuntimeTraceCommand.SuccessExitCode, exitCode);
        StringAssert.Contains(output.ToString(), "Usage: HerdrOps.Core trace-compliance-review");
    }

    [TestMethod]
    public void MissingRequiredOptionsFailWithUsageCode()
    {
        using var output = new StringWriter();
        using var error = new StringWriter();

        var exitCode = ComplianceReviewRuntimeTraceCommand.Run(["trace-compliance-review", "--database", "db.sqlite"], output, error);

        Assert.AreEqual(ComplianceReviewRuntimeTraceCommand.UsageFailureExitCode, exitCode);
        StringAssert.Contains(error.ToString(), "Both --database and --report are required");
    }

    [TestMethod]
    public void NonExistentDatabasePathFailsWithUsageCode()
    {
        using var output = new StringWriter();
        using var error = new StringWriter();

        var exitCode = ComplianceReviewRuntimeTraceCommand.Run(
            ["trace-compliance-review", "--database", "non_existent_file.db", "--report", "report.json"],
            output,
            error);

        Assert.AreEqual(ComplianceReviewRuntimeTraceCommand.UsageFailureExitCode, exitCode);
        StringAssert.Contains(error.ToString(), "does not exist");
    }

    [TestMethod]
    public void IdenticalDatabaseAndReportPathFailsWithUsageCode()
    {
        using var tempFile = new TempFile();
        using var output = new StringWriter();
        using var error = new StringWriter();

        var exitCode = ComplianceReviewRuntimeTraceCommand.Run(
            ["trace-compliance-review", "--database", tempFile.Path, "--report", tempFile.Path],
            output,
            error);

        Assert.AreEqual(ComplianceReviewRuntimeTraceCommand.UsageFailureExitCode, exitCode);
        StringAssert.Contains(error.ToString(), "must be different files");
    }

    [TestMethod]
    public void SensitiveTextRedactorRedactsSecretsFromReason()
    {
        var redactor = new SensitiveTextRedactor();
        var reasonWithToken = "Incident review confirmed: ghp_123456789012345678901234567890123456 was leaked in repo.";
        var redacted = redactor.Redact(reasonWithToken);

        Assert.IsFalse(redacted.RedactedText.Contains(
            "ghp_123456789012345678901234567890123456",
            StringComparison.Ordinal));
        StringAssert.Contains(redacted.RedactedText, "[REDACTED]");
    }

    [TestMethod]
    public void RuntimeEvidenceClassificationFailsClosedBeforeReadingInput()
    {
        using var output = new StringWriter();
        using var error = new StringWriter();

        var exitCode = ComplianceReviewRuntimeTraceCommand.Run(
            [
                "trace-compliance-review",
                "--database", "missing.db",
                "--report", "trace.json",
                "--evidence-classification", ComplianceReviewRuntimeTraceContract.ActualRuntimeEvidence,
            ],
            output,
            error);

        Assert.AreEqual(ComplianceReviewRuntimeTraceCommand.UsageFailureExitCode, exitCode);
        StringAssert.Contains(error.ToString(), "not an allowlisted non-runtime value");
    }

    [TestMethod]
    public void RuntimeObservationFlagsAreNotAcceptedBySyntheticProducer()
    {
        using var output = new StringWriter();
        using var error = new StringWriter();

        var exitCode = ComplianceReviewRuntimeTraceCommand.Run(
            [
                "trace-compliance-review",
                "--database", "missing.db",
                "--report", "trace.json",
                "--restart-observed",
            ],
            output,
            error);

        Assert.AreEqual(ComplianceReviewRuntimeTraceCommand.UsageFailureExitCode, exitCode);
        StringAssert.Contains(error.ToString(), "Invalid, duplicate, or incomplete option");
    }

    private sealed class TempFile : IDisposable
    {
        public string Path { get; } = System.IO.Path.GetTempFileName();

        public void Dispose()
        {
            try
            {
                if (File.Exists(Path))
                {
                    File.Delete(Path);
                }
            }
            catch
            {
            }
        }
    }
}
