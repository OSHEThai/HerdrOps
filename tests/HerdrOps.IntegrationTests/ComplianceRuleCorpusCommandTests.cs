using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using HerdrOps.Core;

namespace HerdrOps.IntegrationTests;

[TestClass]
public sealed class ComplianceRuleCorpusCommandTests
{
    private const string ExpectedInputSha256 =
        "338C0F80C48E92D585AA3CA66CDB0BA6399ED1442C10A25C7E61F2069C1DB83A";

    private const string ExpectedRuleSetSha256 =
        "4EB8A183215D223296DBA64743EF24877F960556A723BDC4506F273183A972E4";

    private const string ExpectedCorpusResultSha256 =
        "2E4B53B8B80908726C431EC5637B6A92B0F82C99E14BAE36E8EBF3BE3DCA0F11";

    private const string ExpectedReportSha256 =
        "042361CFBE8764A6FC2E65FA4B4E78174A792A988ECC7FAD46D7974CFD57BF8E";

    [TestMethod]
    public void CommittedComplianceCorpusProducesByteIdenticalReportsAndExpectedHashes()
    {
        var temporaryDirectory = CreateTemporaryDirectory();
        try
        {
            var fixturePath = FindFixturePath();
            var firstReportPath = Path.Combine(temporaryDirectory, "first.json");
            var secondReportPath = Path.Combine(temporaryDirectory, "second.json");

            var first = Run(fixturePath, firstReportPath);
            var second = Run(fixturePath, secondReportPath);

            Assert.AreEqual(0, first.ExitCode);
            Assert.AreEqual(0, second.ExitCode);
            Assert.AreEqual(string.Empty, first.Error);
            Assert.AreEqual(string.Empty, second.Error);
            CollectionAssert.AreEqual(
                File.ReadAllBytes(firstReportPath),
                File.ReadAllBytes(secondReportPath));
            Assert.AreEqual(first.Output, second.Output);
            Assert.AreEqual(
                ExpectedInputSha256,
                Convert.ToHexString(SHA256.HashData(File.ReadAllBytes(fixturePath))));
            Assert.AreEqual(
                ExpectedReportSha256,
                Convert.ToHexString(SHA256.HashData(File.ReadAllBytes(firstReportPath))));

            using var document = JsonDocument.Parse(File.ReadAllBytes(firstReportPath));
            var root = document.RootElement;
            Assert.AreEqual("Synthetic", root.GetProperty("evidenceClass").GetString());
            Assert.IsFalse(root.GetProperty("runtimeObserved").GetBoolean());
            Assert.AreEqual(ExpectedInputSha256, root.GetProperty("inputSha256").GetString());
            Assert.AreEqual(
                ExpectedRuleSetSha256,
                root.GetProperty("ruleSet").GetProperty("ruleSetSha256").GetString());
            Assert.AreEqual(
                ExpectedCorpusResultSha256,
                root.GetProperty("corpusResultSha256").GetString());
            var diagnostics = root.GetProperty("diagnostics");
            Assert.AreEqual(5, diagnostics.GetProperty("caseCount").GetInt32());
            Assert.AreEqual(5, diagnostics.GetProperty("passedCaseCount").GetInt32());
            Assert.AreEqual(6, diagnostics.GetProperty("evaluationRunCount").GetInt32());
            Assert.AreEqual(4, diagnostics.GetProperty("firstRunFindingCount").GetInt32());
            Assert.AreEqual(4, diagnostics.GetProperty("explainabilityRecordCount").GetInt32());
            Assert.AreEqual(1, diagnostics.GetProperty("firstRunRuleErrorCount").GetInt32());
            Assert.AreEqual(
                2,
                diagnostics.GetProperty("repeatedDuplicateDetectionCount").GetInt32());
            Assert.AreEqual(0, diagnostics.GetProperty("confirmedFindingCount").GetInt32());
            Assert.AreEqual(
                4,
                diagnostics.GetProperty("triggeredRuleKinds").GetArrayLength());
            Assert.AreEqual(
                4,
                diagnostics.GetProperty("passedRuleKinds").GetArrayLength());
        }
        finally
        {
            Directory.Delete(temporaryDirectory, recursive: true);
        }
    }

    [TestMethod]
    public void UnknownCorpusMemberFailsClosedWithoutReplacingReport()
    {
        var temporaryDirectory = CreateTemporaryDirectory();
        try
        {
            var inputPath = Path.Combine(temporaryDirectory, "unknown-member.json");
            var reportPath = Path.Combine(temporaryDirectory, "report.json");
            var fixture = File.ReadAllText(FindFixturePath(), Encoding.UTF8);
            File.WriteAllText(
                inputPath,
                fixture.Replace(
                    "\"contractVersion\": 1,",
                    "\"contractVersion\": 1,\n  \"unexpectedRuntimeClaim\": true,",
                    StringComparison.Ordinal),
                new UTF8Encoding(encoderShouldEmitUTF8Identifier: false));
            var sentinel = Encoding.UTF8.GetBytes("existing-report");
            File.WriteAllBytes(reportPath, sentinel);

            var result = Run(inputPath, reportPath);

            Assert.AreEqual(2, result.ExitCode);
            Assert.AreEqual(string.Empty, result.Output);
            StringAssert.Contains(result.Error, "could not be mapped");
            CollectionAssert.AreEqual(sentinel, File.ReadAllBytes(reportPath));
        }
        finally
        {
            Directory.Delete(temporaryDirectory, recursive: true);
        }
    }

    [TestMethod]
    public void DuplicateCorpusPropertyFailsClosedWithoutReport()
    {
        var temporaryDirectory = CreateTemporaryDirectory();
        try
        {
            var inputPath = Path.Combine(temporaryDirectory, "duplicate-property.json");
            var reportPath = Path.Combine(temporaryDirectory, "report.json");
            File.WriteAllText(
                inputPath,
                """
                {
                  "contractVersion": 1,
                  "contractVersion": 1,
                  "cases": []
                }
                """,
                new UTF8Encoding(encoderShouldEmitUTF8Identifier: false));

            var result = Run(inputPath, reportPath);

            Assert.AreEqual(2, result.ExitCode);
            Assert.AreEqual(string.Empty, result.Output);
            StringAssert.Contains(result.Error, "Duplicate property");
            Assert.IsFalse(File.Exists(reportPath));
        }
        finally
        {
            Directory.Delete(temporaryDirectory, recursive: true);
        }
    }

    [TestMethod]
    public void MismatchedExpectationFailsClosedWithoutReplacingReport()
    {
        var temporaryDirectory = CreateTemporaryDirectory();
        try
        {
            var inputPath = Path.Combine(temporaryDirectory, "mismatched-expectation.json");
            var reportPath = Path.Combine(temporaryDirectory, "report.json");
            var fixture = File.ReadAllText(FindFixturePath(), Encoding.UTF8);
            File.WriteAllText(
                inputPath,
                fixture.Replace(
                    "\"firstRunFindingCount\": 0,",
                    "\"firstRunFindingCount\": 1,",
                    StringComparison.Ordinal),
                new UTF8Encoding(encoderShouldEmitUTF8Identifier: false));
            var sentinel = Encoding.UTF8.GetBytes("existing-report");
            File.WriteAllBytes(reportPath, sentinel);

            var result = Run(inputPath, reportPath);

            Assert.AreEqual(2, result.ExitCode);
            Assert.AreEqual(string.Empty, result.Output);
            StringAssert.Contains(result.Error, "did not match its declared expectation");
            CollectionAssert.AreEqual(sentinel, File.ReadAllBytes(reportPath));
        }
        finally
        {
            Directory.Delete(temporaryDirectory, recursive: true);
        }
    }

    [TestMethod]
    public void NumericRuleEnumFailsClosedWithoutReport()
    {
        var temporaryDirectory = CreateTemporaryDirectory();
        try
        {
            var inputPath = Path.Combine(temporaryDirectory, "numeric-enum.json");
            var reportPath = Path.Combine(temporaryDirectory, "report.json");
            var fixture = File.ReadAllText(FindFixturePath(), Encoding.UTF8);
            File.WriteAllText(
                inputPath,
                fixture.Replace(
                    "\"ScopeViolation\"",
                    "1",
                    StringComparison.Ordinal),
                new UTF8Encoding(encoderShouldEmitUTF8Identifier: false));

            var result = Run(inputPath, reportPath);

            Assert.AreEqual(2, result.ExitCode);
            Assert.AreEqual(string.Empty, result.Output);
            Assert.IsFalse(File.Exists(reportPath));
        }
        finally
        {
            Directory.Delete(temporaryDirectory, recursive: true);
        }
    }

    [TestMethod]
    public void MissingRequiredCorpusReportOptionReturnsUsageFailure()
    {
        using var output = new StringWriter();
        using var error = new StringWriter();

        var exitCode = ComplianceRuleCorpusCommand.Run(
            ["compliance-rule-corpus", "--input", "fixture.json"],
            output,
            error);

        Assert.AreEqual(64, exitCode);
        Assert.AreEqual(string.Empty, output.ToString());
        StringAssert.Contains(error.ToString(), "Both --input and --report are required");
        StringAssert.Contains(error.ToString(), "Usage:");
    }

    [TestMethod]
    public void CorpusInputCannotBeOverwrittenByReport()
    {
        var fixturePath = FindFixturePath();

        var result = Run(fixturePath, fixturePath);

        Assert.AreEqual(2, result.ExitCode);
        Assert.AreEqual(string.Empty, result.Output);
        StringAssert.Contains(result.Error, "must be different files");
        Assert.AreEqual(
            ExpectedInputSha256,
            Convert.ToHexString(SHA256.HashData(File.ReadAllBytes(fixturePath))));
    }

    private static CommandResult Run(string inputPath, string reportPath)
    {
        using var output = new StringWriter();
        using var error = new StringWriter();
        var exitCode = ComplianceRuleCorpusCommand.Run(
            [
                "compliance-rule-corpus",
                "--input",
                inputPath,
                "--report",
                reportPath,
            ],
            output,
            error);
        return new CommandResult(exitCode, output.ToString(), error.ToString());
    }

    private static string FindFixturePath() => Path.Combine(
        FindRepositoryRoot(),
        "tests",
        "fixtures",
        "v0.5",
        "compliance-rule-corpus.json");

    private static string CreateTemporaryDirectory()
    {
        var path = Path.Combine(
            Path.GetTempPath(),
            $"herdrops-compliance-corpus-{Guid.NewGuid():N}");
        Directory.CreateDirectory(path);
        return path;
    }

    private static string FindRepositoryRoot()
    {
        var directory = new DirectoryInfo(AppContext.BaseDirectory);
        while (directory is not null)
        {
            if (File.Exists(Path.Combine(directory.FullName, "HerdrOps.sln")))
            {
                return directory.FullName;
            }

            directory = directory.Parent;
        }

        Assert.Fail("Could not locate HerdrOps.sln from the test output directory.");
        return string.Empty;
    }

    private sealed record CommandResult(int ExitCode, string Output, string Error);
}
