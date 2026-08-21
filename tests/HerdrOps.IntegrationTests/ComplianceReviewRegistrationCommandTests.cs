using System.Text.Json;
using HerdrOps.Core;
using HerdrOps.Domain.Compliance;
using HerdrOps.Domain.Evidence;
using HerdrOps.Infrastructure.Storage;

namespace HerdrOps.IntegrationTests;

[TestClass]
public sealed class ComplianceReviewRegistrationCommandTests
{
    private static readonly string ValidRegistrationJson =
        """
        {
          "contractVersion": 1,
          "commandId": "22222222-2222-2222-2222-222222222222",
          "incidentId": "INC-28-G1",
          "taskId": "TASK-28-G1",
          "subjectActorId": "worker-terminal",
          "registeredUtc": "2026-08-20T12:00:00Z",
          "evidenceIdentitySha256s": ["AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"]
        }
        """;

    [TestMethod]
    public void UsageAndArgumentValidationFailClosed()
    {
        var output = new StringWriter();
        var error = new StringWriter();

        var code1 = ComplianceReviewRegistrationCommand.Run(
            Array.Empty<string>(),
            new StringReader(string.Empty),
            output,
            error);
        Assert.AreEqual(64, code1);

        var code2 = ComplianceReviewRegistrationCommand.Run(
            new[] { "compliance-register-incident", "--unknown-opt", "val" },
            new StringReader(string.Empty),
            output,
            error);
        Assert.AreEqual(64, code2);

        var code3 = ComplianceReviewRegistrationCommand.Run(
            new[] { "compliance-register-incident", "--database", "Z:\\x.db" },
            new StringReader(string.Empty),
            output,
            error);
        Assert.AreEqual(64, code3);
    }

    [TestMethod]
    public void InvalidStrictJsonReturnsExitCodeTwo()
    {
        using var directory = new TemporaryDirectory();
        var dbPath = Path.Combine(directory.Path, "store.db");

        var cases = new (string Name, string Payload)[]
        {
            ("trailing-comma", """{"contractVersion":1,"incidentId":"INC-X",}"""),
            ("duplicate-property", """{"contractVersion":1,"contractVersion":1,"incidentId":"INC-X","commandId":"22222222-2222-2222-2222-222222222222","taskId":"T","subjectActorId":"S","registeredUtc":"2026-08-20T12:00:00Z","evidenceIdentitySha256s":[]}"""),
            ("unmapped-property", """{"contractVersion":1,"incidentId":"INC-X","hackerInjected":true,"commandId":"22222222-2222-2222-2222-222222222222","taskId":"T","subjectActorId":"S","registeredUtc":"2026-08-20T12:00:00Z","evidenceIdentitySha256s":[]}"""),
            ("malformed", """{not json}"""),
        };

        foreach (var testCase in cases)
        {
            var inputPath = Path.Combine(directory.Path, $"{testCase.Name}.json");
            File.WriteAllText(inputPath, testCase.Payload);
            var output = new StringWriter();
            var error = new StringWriter();
            var code = ComplianceReviewRegistrationCommand.Run(
                new[]
                {
                    "compliance-register-incident",
                    "--database", dbPath,
                    "--input", inputPath,
                },
                new StringReader(string.Empty),
                output,
                error);
            Assert.AreEqual(2, code, $"case {testCase.Name} expected exit 2");
        }
    }

    [TestMethod]
    public void OversizeOrReparseInputReturnsExitCodeTwo()
    {
        using var directory = new TemporaryDirectory();
        var dbPath = Path.Combine(directory.Path, "store.db");
        var output = new StringWriter();
        var error = new StringWriter();

        var oversizePath = Path.Combine(directory.Path, "oversize.json");
        File.WriteAllText(oversizePath, "[" + new string(' ', 64 * 1024) + "]");
        var codeOversize = ComplianceReviewRegistrationCommand.Run(
            new[]
            {
                "compliance-register-incident",
                "--database", dbPath,
                "--input", oversizePath,
            },
            new StringReader(string.Empty),
            output,
            error);
        Assert.AreEqual(2, codeOversize);

        var realPath = Path.Combine(directory.Path, "real.json");
        File.WriteAllText(realPath, ValidRegistrationJson);
        var reparsePath = Path.Combine(directory.Path, "link.json");
        var symlinkCreated = false;
        try
        {
            File.CreateSymbolicLink(reparsePath, realPath);
            symlinkCreated = true;
        }
        catch (Exception exception) when (
            exception is IOException or UnauthorizedAccessException or PlatformNotSupportedException)
        {
            symlinkCreated = false;
        }

        if (symlinkCreated)
        {
            var codeReparse = ComplianceReviewRegistrationCommand.Run(
                new[]
                {
                    "compliance-register-incident",
                    "--database", dbPath,
                    "--input", reparsePath,
                },
                new StringReader(string.Empty),
                output,
                error);
            Assert.AreEqual(2, codeReparse);
        }
    }

    [TestMethod]
    public void ValidStdinRegistrationPersistsToSqliteAndReturnsExitCodeZero()
    {
        using var directory = new TemporaryDirectory();
        var dbPath = Path.Combine(directory.Path, "store.db");
        var evidencePath = Path.Combine(directory.Path, "evidence.txt");
        var evidenceBytes = new byte[] { 1, 2, 3, 4, 5 };
        File.WriteAllBytes(evidencePath, evidenceBytes);

        var evidenceUtc = new DateTimeOffset(2026, 8, 20, 12, 0, 0, TimeSpan.Zero);
        EvidenceMetadata evidenceMetadata;
        using (var captureStore = new SqliteHerdrStateStore(new HerdrStateStoreOptions(dbPath)))
        {
            var writeResult = captureStore.CaptureEvidence(
                new EvidenceCaptureRequest(
                    ContractVersion: 1,
                    TaskId: "TASK-28-G1",
                    ActorId: "evidence-capture-actor",
                    SourceEventId: Guid.NewGuid().ToString("D"),
                    Source: "compliance-registration-test",
                    SourceReference: "evidence.txt",
                    ObservedUtc: evidenceUtc,
                    IngestedUtc: evidenceUtc,
                    RetainUntilUtc: null,
                    CreateManagedCopy: false),
                evidencePath);
            evidenceMetadata = writeResult.StoredEvidence.Metadata;
        }

        var evidenceIdentity = evidenceMetadata.EvidenceIdentitySha256;
        var registrationJson = $$"""
            {
              "contractVersion": 1,
              "commandId": "22222222-2222-2222-2222-222222222222",
              "incidentId": "INC-28-G1",
              "taskId": "TASK-28-G1",
              "subjectActorId": "worker-terminal",
              "registeredUtc": "2026-08-20T12:00:00Z",
              "evidenceIdentitySha256s": ["{{evidenceIdentity}}"]
            }
            """;

        var output = new StringWriter();
        var error = new StringWriter();
        var code = ComplianceReviewRegistrationCommand.Run(
            new[]
            {
                "compliance-register-incident",
                "--database", dbPath,
                "--input", "-",
            },
            new StringReader(registrationJson),
            output,
            error);
        Assert.AreEqual(0, code, error.ToString());
        Assert.AreEqual(string.Empty, error.ToString());

        using var document = JsonDocument.Parse(output.ToString());
        var root = document.RootElement;
        Assert.IsTrue(root.GetProperty("registered").GetBoolean());
        Assert.IsFalse(root.GetProperty("wasAlreadyPresent").GetBoolean());
        Assert.AreEqual("INC-28-G1", root.GetProperty("incidentId").GetString());
        Assert.AreNotEqual(string.Empty, root.GetProperty("registrationSha256").GetString());
        Assert.AreEqual(1, root.GetProperty("state").GetInt32());
        Assert.AreEqual(0L, root.GetProperty("sequence").GetInt64());

        using var store = new SqliteHerdrStateStore(new HerdrStateStoreOptions(dbPath));
        var snapshot = store.ReadComplianceReviewRuntimeTraceSnapshot(
            taskIdFilter: null,
            incidentIdFilter: new[] { "INC-28-G1" });
        Assert.HasCount(1, snapshot.Incidents);
        Assert.AreEqual("INC-28-G1", snapshot.Incidents[0].IncidentId);
        Assert.AreEqual(ComplianceReviewState.Suspected, snapshot.Incidents[0].State);
        Assert.AreEqual(0L, snapshot.Incidents[0].Sequence);
    }
}