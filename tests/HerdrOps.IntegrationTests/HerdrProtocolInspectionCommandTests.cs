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
}
