using System.Globalization;
using System.Text;
using System.Text.RegularExpressions;
using HerdrOps.Contracts.SelfReport;

namespace HerdrOps.ContractTests;

[TestClass]
public sealed class SelfReportContractTests
{
    [TestMethod]
    public void EverySupportedCommandCreatesOneStrictVersionedSubmission()
    {
        var parentEventId = Guid.NewGuid();
        var cases = new Dictionary<string, HerdrOpsSelfReportCommandInput>(StringComparer.Ordinal)
        {
            [HerdrOpsSelfReportProtocol.EventTypes.Assignment] =
                ValidInput() with { TargetAgentId = "backend-worker-01" },
            [HerdrOpsSelfReportProtocol.EventTypes.Acknowledgement] =
                ValidInput() with { ParentEventId = parentEventId },
            [HerdrOpsSelfReportProtocol.EventTypes.Delegation] =
                ValidInput() with
                {
                    ParentEventId = parentEventId,
                    TargetAgentId = "backend-worker-02",
                },
            [HerdrOpsSelfReportProtocol.EventTypes.Progress] =
                ValidInput() with
                {
                    ParentEventId = parentEventId,
                    ProgressPercent = 42,
                },
            [HerdrOpsSelfReportProtocol.EventTypes.Deviation] =
                ValidInput() with
                {
                    ParentEventId = parentEventId,
                    DeviationReason = "The accepted implementation boundary must change.",
                },
            [HerdrOpsSelfReportProtocol.EventTypes.Evidence] =
                ValidInput() with
                {
                    ParentEventId = parentEventId,
                    EvidenceReference = "artifacts/evidence/output.json",
                    EvidenceSha256 = new string('A', 64),
                },
            [HerdrOpsSelfReportProtocol.EventTypes.Handoff] =
                ValidInput() with
                {
                    ParentEventId = parentEventId,
                    TargetAgentId = "backend-leader",
                    HandoffNote = "Implementation complete and ready for review.",
                },
        };

        CollectionAssert.AreEquivalent(
            HerdrOpsSelfReportProtocol.EventTypes.All.ToArray(),
            cases.Keys.ToArray());
        foreach (var (eventType, commandInput) in cases)
        {
            var json = HerdrOpsSelfReportJson.Serialize(commandInput);
            var deserialized = HerdrOpsSelfReportJson.DeserializeCommandInput(
                Encoding.UTF8.GetBytes(json));
            var submission = HerdrOpsSelfReportJson.CreateSubmission(eventType, deserialized);

            Assert.AreEqual(HerdrOpsSelfReportProtocol.Version, submission.ContractVersion);
            Assert.AreEqual(eventType, submission.EventType);
            Assert.AreEqual(commandInput.EventId, submission.EventId);
        }
    }

    [TestMethod]
    public void DocumentedCommandExamplesMatchTheExecutableContracts()
    {
        var repositoryRoot = FindRepositoryRoot();
        var exampleRoot = Path.Combine(
            repositoryRoot,
            "docs",
            "protocol",
            "examples",
            "v0.4");

        foreach (var eventType in HerdrOpsSelfReportProtocol.EventTypes.All)
        {
            var examplePath = Path.Combine(exampleRoot, $"{eventType}.json");
            Assert.IsTrue(File.Exists(examplePath), $"Missing example: {examplePath}");
            var input = HerdrOpsSelfReportJson.DeserializeCommandInput(
                File.ReadAllBytes(examplePath));
            var submission = HerdrOpsSelfReportJson.CreateSubmission(eventType, input);
            Assert.AreEqual(eventType, submission.EventType);
        }

        Assert.HasCount(
            HerdrOpsSelfReportProtocol.EventTypes.All.Count,
            Directory.GetFiles(exampleRoot, "*.json", SearchOption.TopDirectoryOnly));
    }

    [TestMethod]
    public void UnknownJsonMemberFailsClosed()
    {
        var json = HerdrOpsSelfReportJson.Serialize(ValidInput());
        var withUnknownMember = $"{json[..^1]},\"unexpected\":true}}";

        Assert.Throws<HerdrOpsSelfReportProtocolException>(() =>
            HerdrOpsSelfReportJson.DeserializeCommandInput(
                Encoding.UTF8.GetBytes(withUnknownMember)));
    }

    [TestMethod]
    public void EventSpecificFieldsCannotLeakAcrossCommands()
    {
        var invalid = ValidInput() with
        {
            TargetAgentId = "backend-worker-01",
            ProgressPercent = 50,
        };

        Assert.Throws<HerdrOpsSelfReportProtocolException>(() =>
            HerdrOpsSelfReportJson.CreateSubmission(
                HerdrOpsSelfReportProtocol.EventTypes.Assignment,
                invalid));
    }

    [TestMethod]
    public void NonUtcOccurrenceAndWrongContractVersionFailClosed()
    {
        var localOffset = ValidInput() with
        {
            OccurredUtc = new DateTimeOffset(2026, 8, 15, 10, 0, 0, TimeSpan.FromHours(7)),
        };
        var wrongVersion = ValidInput() with
        {
            ContractVersion = HerdrOpsSelfReportProtocol.Version + 1,
        };

        Assert.Throws<HerdrOpsSelfReportProtocolException>(() =>
            HerdrOpsSelfReportJson.DeserializeCommandInput(
                Encoding.UTF8.GetBytes(HerdrOpsSelfReportJson.Serialize(localOffset))));
        Assert.Throws<HerdrOpsSelfReportProtocolException>(() =>
            HerdrOpsSelfReportJson.DeserializeCommandInput(
                Encoding.UTF8.GetBytes(HerdrOpsSelfReportJson.Serialize(wrongVersion))));
    }

    [TestMethod]
    public async Task FramingRejectsPayloadOverConfiguredBound()
    {
        var submission = HerdrOpsSelfReportJson.CreateSubmission(
            HerdrOpsSelfReportProtocol.EventTypes.Assignment,
            ValidInput() with
            {
                TargetAgentId = "backend-worker-01",
                Summary = new string('x', 1500),
            });
        var envelope = HerdrOpsSelfReportJson.CreateEnvelope(
            HerdrOpsSelfReportProtocol.MessageTypes.Submit,
            0,
            DateTimeOffset.UtcNow,
            HerdrOpsSelfReportProtocol.CliSource,
            Guid.NewGuid(),
            submission);
        await using var stream = new MemoryStream();

        await Assert.ThrowsAsync<HerdrOpsSelfReportProtocolException>(async () =>
            await HerdrOpsSelfReportJson.WriteFrameAsync(
                stream,
                envelope,
                CancellationToken.None,
                maximumFrameBytes: 1024));
    }

    [TestMethod]
    public void CurrentUserPipeNameIsStableVersionedAndScopeSpecific()
    {
        var first = HerdrOpsSelfReportPipeName.FromUserScope("S-1-5-21-100");
        var repeated = HerdrOpsSelfReportPipeName.FromUserScope("S-1-5-21-100");
        var other = HerdrOpsSelfReportPipeName.FromUserScope("S-1-5-21-200");

        Assert.AreEqual(first, repeated);
        Assert.AreNotEqual(first, other);
        Assert.StartsWith("herdrops-self-report-v1-", first, StringComparison.Ordinal);
        Assert.AreEqual(48, first.Length);
    }

    [TestMethod]
    public void RejectedResultCannotClaimAnAcceptanceCodeOrIdentity()
    {
        var invalid = new HerdrOpsSelfReportResult(
            false,
            HerdrOpsSelfReportProtocol.ResultCodes.Accepted,
            "Contradictory result.",
            null,
            null,
            null,
            Guid.NewGuid(),
            null,
            null,
            null,
            null);

        Assert.Throws<HerdrOpsSelfReportProtocolException>(() =>
            HerdrOpsSelfReportJson.ValidateResult(invalid));
    }

    [TestMethod]
    public void AcceptedResultAcceptedUtcCarriesExplicitUtcOffsetOnTheWire()
    {
        var result = new HerdrOpsSelfReportResult(
            true,
            HerdrOpsSelfReportProtocol.ResultCodes.Accepted,
            "The self-report event was accepted by Core.",
            Guid.NewGuid(),
            HerdrOpsSelfReportProtocol.EventTypes.Assignment,
            "TASK-115",
            Guid.NewGuid(),
            1,
            new DateTimeOffset(2026, 8, 15, 3, 0, 1, TimeSpan.Zero),
            HerdrOpsSelfReportProtocol.CoreSource,
            new string('A', 64));
        HerdrOpsSelfReportJson.ValidateResult(result);

        var json = HerdrOpsSelfReportJson.Serialize(result);
        var match = Regex.Match(json, "\"acceptedUtc\":\"([^\"]+)\"", RegexOptions.CultureInvariant);
        Assert.IsTrue(match.Success, "The accepted result must contain an acceptedUtc string member.");

        var acceptedUtc = match.Groups[1].Value;
        Assert.IsTrue(
            Regex.IsMatch(acceptedUtc, "Z$|[+-]00:00$", RegexOptions.CultureInvariant),
            $"The accepted acceptedUtc must carry an explicit UTC offset, got: {acceptedUtc}");
        Assert.AreEqual(
            TimeSpan.Zero,
            DateTimeOffset.Parse(acceptedUtc, CultureInfo.InvariantCulture, DateTimeStyles.RoundtripKind).Offset,
            "The accepted acceptedUtc must parse to a zero UTC offset on any host timezone.");
    }

    private static HerdrOpsSelfReportCommandInput ValidInput() => new(
        HerdrOpsSelfReportProtocol.Version,
        Guid.NewGuid(),
        "TASK-115",
        "project-manager",
        "Project Manager",
        new DateTimeOffset(2026, 8, 15, 3, 0, 0, TimeSpan.Zero),
        "Assign the bounded implementation task.",
        null,
        null,
        null,
        null,
        null,
        null,
        null);

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
}
