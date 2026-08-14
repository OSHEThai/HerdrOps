using HerdrOps.Core;

namespace HerdrOps.IntegrationTests;

[TestClass]
public sealed class HerdrProtocolInspectionCommandTests
{
    [TestMethod]
    public void MissingExecutableReturnsNonZeroAndActionableMessage()
    {
        var missingPath = Path.Combine(Path.GetTempPath(), $"herdr-missing-{Guid.NewGuid():N}.exe");
        using var output = new StringWriter();
        using var error = new StringWriter();

        var exitCode = HerdrProtocolInspectionCommand.Run(
            ["inspect-herdr-schema", "--herdr", missingPath],
            output,
            error);

        Assert.AreEqual(2, exitCode);
        StringAssert.Contains(output.ToString(), "ExecutableNotFound");
        StringAssert.Contains(error.ToString(), "was not found");
    }

    [TestMethod]
    public void UnknownCommandReturnsUsageFailure()
    {
        using var output = new StringWriter();
        using var error = new StringWriter();

        var exitCode = HerdrProtocolInspectionCommand.Run(["unknown"], output, error);

        Assert.AreEqual(64, exitCode);
        StringAssert.Contains(error.ToString(), "Usage:");
    }

    [TestMethod]
    public void BlankExplicitHerdrPathReturnsUsageFailureWithoutAutoDiscovery()
    {
        using var output = new StringWriter();
        using var error = new StringWriter();

        var exitCode = HerdrProtocolInspectionCommand.Run(
            ["inspect-herdr-schema", "--herdr", "   "],
            output,
            error);

        Assert.AreEqual(64, exitCode);
        Assert.AreEqual(string.Empty, output.ToString());
        StringAssert.Contains(error.ToString(), "requires a non-empty executable path");
    }

    [TestMethod]
    public void UnwritableReportTargetReturnsDeterministicNonZeroInsteadOfThrowing()
    {
        var parentFile = Path.GetTempFileName();
        try
        {
            var missingExecutable = Path.Combine(Path.GetTempPath(), $"herdr-missing-{Guid.NewGuid():N}.exe");
            var impossibleReportPath = Path.Combine(parentFile, "report.json");
            using var output = new StringWriter();
            using var error = new StringWriter();

            var exitCode = HerdrProtocolInspectionCommand.Run(
                [
                    "inspect-herdr-schema",
                    "--herdr",
                    missingExecutable,
                    "--report",
                    impossibleReportPath,
                ],
                output,
                error);

            Assert.AreEqual(2, exitCode);
            StringAssert.Contains(output.ToString(), "ExecutableNotFound");
            StringAssert.Contains(error.ToString(), "report could not be written");
        }
        finally
        {
            if (File.Exists(parentFile))
            {
                File.Delete(parentFile);
            }
        }
    }
}
