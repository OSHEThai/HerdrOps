using HerdrOps.Contracts;
using HerdrOps.Core;
using HerdrOps.Infrastructure.Herdr;

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
    public void RejectedInspectionLeavesPreexistingSchemaOutputUntouched()
    {
        var root = Path.Combine(
            Path.GetTempPath(),
            "HerdrOps.BundledSchemaCommandTests",
            Guid.NewGuid().ToString("N"));
        var schemaPath = Path.Combine(root, "existing-schema.json");
        var reportPath = Path.Combine(root, "rejection-report.json");
        var sentinel = new byte[] { 0x53, 0x54, 0x41, 0x4C, 0x45 };
        try
        {
            Directory.CreateDirectory(root);
            File.WriteAllBytes(schemaPath, sentinel);
            using var output = new StringWriter();
            using var error = new StringWriter();

            var exitCode = HerdrBundledSchemaInspectionCommand.Run(
                [
                    "inspect-herdr-bundled-schema",
                    "--herdr",
                    Path.Combine(root, "missing-herdr.exe"),
                    "--schema-output",
                    schemaPath,
                    "--report",
                    reportPath,
                ],
                output,
                error);

            Assert.AreEqual(2, exitCode);
            CollectionAssert.AreEqual(sentinel, File.ReadAllBytes(schemaPath));
            Assert.IsEmpty(Directory.GetFiles(root, "*.tmp"));
        }
        finally
        {
            DeleteFixtureRoot(root);
        }
    }

    [TestMethod]
    public void AtomicSchemaWriteFailurePreservesDestinationAndReturnsNonZero()
    {
        var root = Path.Combine(
            Path.GetTempPath(),
            "HerdrOps.BundledSchemaCommandTests",
            Guid.NewGuid().ToString("N"));
        var schemaPath = Path.Combine(root, "locked-schema.json");
        var executablePath = Path.Combine(root, "fixture-herdr.exe");
        var sentinel = new byte[] { 0x53, 0x41, 0x46, 0x45 };
        var acceptedSchema = new byte[] { (byte)'{', (byte)'}' };
        try
        {
            Directory.CreateDirectory(root);
            File.WriteAllBytes(schemaPath, sentinel);
            File.WriteAllBytes(executablePath, new byte[] { (byte)'M', (byte)'Z' });
            using var output = new StringWriter();
            using var error = new StringWriter();
            var extraction = CreateCompatibleExtraction(executablePath, acceptedSchema);

            int exitCode;
            using (new FileStream(
                       schemaPath,
                       FileMode.Open,
                       FileAccess.Read,
                       FileShare.Read))
            {
                exitCode = HerdrBundledSchemaInspectionCommand.Run(
                    [
                        "inspect-herdr-bundled-schema",
                        "--herdr",
                        executablePath,
                        "--schema-output",
                        schemaPath,
                    ],
                    output,
                    error,
                    new StubExtractor(extraction),
                    new AtomicSchemaOutputWriter());
            }

            Assert.AreEqual(2, exitCode);
            CollectionAssert.AreEqual(sentinel, File.ReadAllBytes(schemaPath));
            Assert.IsEmpty(Directory.GetFiles(root, "*.tmp"));
            StringAssert.Contains(error.ToString(), "could not be written");
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

    private static HerdrBundledSchemaExtraction CreateCompatibleExtraction(
        string executablePath,
        byte[] schemaBytes)
    {
        var inspection = new HerdrBundledSchemaInspection(
            HerdrBundledSchemaStatus.Compatible,
            EvidenceClass.Contract,
            RuntimeObserved: false,
            SessionControlInvoked: false,
            "fixture-schema-contract",
            1,
            executablePath,
            executablePath,
            "fixture-release",
            new string('A', 64),
            SchemaStartOffset: 0,
            schemaBytes.Length,
            new string('B', 64),
            HerdrBundledSchemaContractV19.JsonSchemaDraft,
            Protocol: 19,
            SchemaVersion: 1,
            Array.Empty<HerdrBundledSchemaGroupSummary>(),
            Array.Empty<string>(),
            Array.Empty<string>(),
            Array.Empty<string>(),
            Array.Empty<string>(),
            Array.Empty<string>(),
            Array.Empty<string>(),
            "Fixture schema is compatible.");
        return new HerdrBundledSchemaExtraction(inspection, schemaBytes);
    }

    private sealed class StubExtractor : IHerdrBundledSchemaExtractor
    {
        private readonly HerdrBundledSchemaExtraction _extraction;

        public StubExtractor(HerdrBundledSchemaExtraction extraction)
        {
            _extraction = extraction;
        }

        public HerdrBundledSchemaExtraction Extract(string executablePath) => _extraction;
    }
}
