using HerdrOps.Core;

namespace HerdrOps.IntegrationTests;

[TestClass]
public sealed class HerdrBundledSchemaInspectionCommandTests
{
    [TestMethod]
    public void CoreRouterReturnsContractFailureForMissingExecutable()
    {
        var missingPath = Path.Combine(Path.GetTempPath(), $"herdr-missing-{Guid.NewGuid():N}.exe");
        using var output = new StringWriter();
        using var error = new StringWriter();

        var exitCode = HerdrProtocolInspectionCommand.Run(
            ["inspect-herdr-bundled-schema", "--herdr", missingPath],
            output,
            error);

        Assert.AreEqual(2, exitCode);
        StringAssert.Contains(output.ToString(), "ExecutableRejected");
        StringAssert.Contains(output.ToString(), "\"RuntimeObserved\": false");
        StringAssert.Contains(output.ToString(), "\"SessionControlInvoked\": false");
        StringAssert.Contains(error.ToString(), "Executable admission failed");
    }

    [TestMethod]
    public void MissingExecutableDoesNotCreateRequestedSchemaOutput()
    {
        var root = Path.Combine(
            Path.GetTempPath(),
            "HerdrOps.BundledSchemaCommandTests",
            Guid.NewGuid().ToString("N"));
        var schemaPath = Path.Combine(root, "schema.json");
        var reportPath = Path.Combine(root, "report.json");
        var missingPath = Path.Combine(root, "missing-herdr.exe");
        try
        {
            using var output = new StringWriter();
            using var error = new StringWriter();

            var exitCode = HerdrBundledSchemaInspectionCommand.Run(
                [
                    "inspect-herdr-bundled-schema",
                    "--herdr",
                    missingPath,
                    "--schema-output",
                    schemaPath,
                    "--report",
                    reportPath,
                ],
                output,
                error);

            Assert.AreEqual(2, exitCode);
            Assert.IsTrue(File.Exists(reportPath));
            Assert.IsFalse(File.Exists(schemaPath));
            StringAssert.Contains(File.ReadAllText(reportPath), "ExecutableRejected");
        }
        finally
        {
            DeleteFixtureRoot(root);
        }
    }

    [TestMethod]
    public void BlankSchemaOutputValueReturnsUsageFailure()
    {
        using var output = new StringWriter();
        using var error = new StringWriter();

        var exitCode = HerdrBundledSchemaInspectionCommand.Run(
            ["inspect-herdr-bundled-schema", "--schema-output", "   "],
            output,
            error);

        Assert.AreEqual(64, exitCode);
        Assert.AreEqual(string.Empty, output.ToString());
        StringAssert.Contains(error.ToString(), "requires a non-empty JSON Schema path");
        StringAssert.Contains(error.ToString(), "Usage:");
    }

    [TestMethod]
    public void ReportAndSchemaOutputMustBeDifferentFiles()
    {
        var sharedPath = Path.Combine(Path.GetTempPath(), $"herdr-schema-{Guid.NewGuid():N}.json");
        using var output = new StringWriter();
        using var error = new StringWriter();

        var exitCode = HerdrBundledSchemaInspectionCommand.Run(
            [
                "inspect-herdr-bundled-schema",
                "--report",
                sharedPath,
                "--schema-output",
                sharedPath.ToUpperInvariant(),
            ],
            output,
            error);

        Assert.AreEqual(64, exitCode);
        StringAssert.Contains(error.ToString(), "must target different files");
        Assert.IsFalse(File.Exists(sharedPath));
    }

    [TestMethod]
    public void DirectCommandRejectsWrongCommandName()
    {
        using var output = new StringWriter();
        using var error = new StringWriter();

        var exitCode = HerdrBundledSchemaInspectionCommand.Run(
            ["inspect-herdr-schema"],
            output,
            error);

        Assert.AreEqual(64, exitCode);
        StringAssert.Contains(error.ToString(), "command name is required");
    }

    private static void DeleteFixtureRoot(string root)
    {
        var resolvedRoot = Path.GetFullPath(root);
        var expectedParent = Path.GetFullPath(
            Path.Combine(Path.GetTempPath(), "HerdrOps.BundledSchemaCommandTests")) +
            Path.DirectorySeparatorChar;
        if (resolvedRoot.StartsWith(expectedParent, StringComparison.OrdinalIgnoreCase) &&
            Directory.Exists(resolvedRoot))
        {
            Directory.Delete(resolvedRoot, recursive: true);
        }
    }
}
