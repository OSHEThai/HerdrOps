using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using HerdrOps.Domain.Compliance;
using HerdrOps.Domain.Evidence;

namespace HerdrOps.UnitTests;

[TestClass]
public sealed class ComplianceDiagnosticExportTests
{
    [TestMethod]
    public void ExportIsDeterministicUtf8AndContainsOnlyTheAllowlist()
    {
        var first = ComplianceDiagnosticExportBuilder.Build(
            Encoding.UTF8.GetBytes(CreateInput(reverse: false)));
        var second = ComplianceDiagnosticExportBuilder.Build(
            Encoding.UTF8.GetBytes(CreateInput(reverse: true)));

        CollectionAssert.AreEqual(first.Content, second.Content);
        Assert.AreEqual(first.Sha256, second.Sha256);
        Assert.AreEqual(2, first.RecordCount);
        Assert.AreNotEqual('\uFEFF', Encoding.UTF8.GetString(first.Content)[0]);
        Assert.AreNotEqual((byte)'\n', first.Content[^1]);

        using var document = JsonDocument.Parse(first.Content);
        var root = document.RootElement;
        CollectionAssert.AreEqual(
            new[] { "schemaVersion", "generatedUtc", "recordCount", "records" },
            root.EnumerateObject().Select(item => item.Name).ToArray());
        Assert.AreEqual(
            ComplianceDiagnosticExportSchema.ExportSchemaVersion,
            root.GetProperty("schemaVersion").GetString());
        Assert.AreEqual(2, root.GetProperty("recordCount").GetInt32());
        Assert.AreEqual(
            "INC-001",
            root.GetProperty("records")[0].GetProperty("incidentId").GetString());
        Assert.AreEqual(
            "INC-002",
            root.GetProperty("records")[1].GetProperty("incidentId").GetString());
        var output = Encoding.UTF8.GetString(first.Content);
        Assert.IsFalse(output.Contains("password", StringComparison.Ordinal));
        Assert.IsFalse(output.Contains("token", StringComparison.Ordinal));
        Assert.IsFalse(output.Contains("C:\\Users\\Alice", StringComparison.Ordinal));
        Assert.IsFalse(output.Contains("prose secret", StringComparison.Ordinal));
    }

    [TestMethod]
    public void UnknownSecretPathAndFreeTextMembersFailClosedWithoutEchoingValues()
    {
        const string secret = "super-secret-token-value";
        const string path = "C:/Users/Alice/private.txt";
        const string prose = "password is hidden prose secret";
        var input = CreateInput(reverse: false).Replace(
            "\"schemaVersion\": \"v0.5.compliance-diagnostic-input.v1\",",
            $"\"schemaVersion\": \"v0.5.compliance-diagnostic-input.v1\",\n  \"password\": \"{secret}\",\n  \"path\": \"{path}\",\n  \"notes\": \"{prose}\",",
            StringComparison.Ordinal);

        var exception = Assert.ThrowsExactly<ComplianceDiagnosticExportException>(() =>
            ComplianceDiagnosticExportBuilder.Build(Encoding.UTF8.GetBytes(input)));

        StringAssert.Contains(exception.Message, "not allowlisted");
        Assert.IsFalse(exception.Message.Contains(secret, StringComparison.Ordinal));
        Assert.IsFalse(exception.Message.Contains(path, StringComparison.Ordinal));
        Assert.IsFalse(exception.Message.Contains(prose, StringComparison.Ordinal));
    }

    [TestMethod]
    public void DuplicateAndMalformedDataFailsClosed()
    {
        const string duplicate = """
        {
          "schemaVersion": "v0.5.compliance-diagnostic-input.v1",
          "schemaVersion": "v0.5.compliance-diagnostic-input.v1",
          "generatedUtc": "2026-08-21T01:02:03.0000000Z",
          "records": []
        }
        """;
        var duplicateException = Assert.ThrowsExactly<ComplianceDiagnosticExportException>(() =>
            ComplianceDiagnosticExportBuilder.Build(Encoding.UTF8.GetBytes(duplicate)));
        StringAssert.Contains(duplicateException.Message, "duplicate property");

        var malformed = CreateInput(reverse: false).Replace(
            "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA",
            "not-a-hash",
            StringComparison.Ordinal);
        Assert.ThrowsExactly<ComplianceDiagnosticExportException>(() =>
            ComplianceDiagnosticExportBuilder.Build(Encoding.UTF8.GetBytes(malformed)));

        var numericState = CreateInput(reverse: false).Replace(
            "\"incidentState\": \"Suspected\"",
            "\"incidentState\": 1",
            StringComparison.Ordinal);
        Assert.ThrowsExactly<ComplianceDiagnosticExportException>(() =>
            ComplianceDiagnosticExportBuilder.Build(Encoding.UTF8.GetBytes(numericState)));

        var duplicateIncident = CreateInput(reverse: false).Replace(
            "\"incidentId\": \"INC-002\"",
            "\"incidentId\": \"INC-001\"",
            StringComparison.Ordinal);
        Assert.ThrowsExactly<ComplianceDiagnosticExportException>(() =>
            ComplianceDiagnosticExportBuilder.Build(Encoding.UTF8.GetBytes(duplicateIncident)));
    }

    [TestMethod]
    public void InputAndOutputBoundsFailClosed()
    {
        Assert.ThrowsExactly<ComplianceDiagnosticExportException>(() =>
            ComplianceDiagnosticExportBuilder.Build(
                new byte[ComplianceDiagnosticExportSchema.MaximumInputBytes + 1]));

        var records = new List<ComplianceDiagnosticRecord>();
        for (var recordIndex = 0; recordIndex < ComplianceDiagnosticExportSchema.MaximumRecords; recordIndex++)
        {
            var evidence = Enumerable.Range(0, 16)
                .Select(evidenceIndex => new ComplianceDiagnosticEvidence(
                    Hash($"evidence-{recordIndex}-{evidenceIndex}"),
                    EvidenceArtifactAvailability.Present,
                    DateTimeOffset.Parse("2026-08-21T01:02:03.0000000Z"),
                    Hash($"metadata-{recordIndex}-{evidenceIndex}"),
                    Hash($"content-{recordIndex}-{evidenceIndex}")))
                .ToArray();
            records.Add(new ComplianceDiagnosticRecord(
                $"INC-{recordIndex:D3}",
                ComplianceReviewState.Suspected,
                DateTimeOffset.Parse("2026-08-21T01:02:03.0000000Z"),
                DateTimeOffset.Parse("2026-08-21T01:02:04.0000000Z"),
                Hash($"registration-{recordIndex}"),
                null,
                evidence));
        }

        var exception = Assert.ThrowsExactly<ComplianceDiagnosticExportException>(() =>
            ComplianceDiagnosticExportBuilder.Build(new ComplianceDiagnosticExportInput(
                ComplianceDiagnosticExportSchema.InputSchemaVersion,
                DateTimeOffset.Parse("2026-08-21T01:02:03.0000000Z"),
                records)));
        StringAssert.Contains(exception.Message, "output bound");
    }

    private static string CreateInput(bool reverse)
    {
        const string firstRecord = """
        {
          "incidentId": "INC-002",
          "incidentState": "Confirmed",
          "registeredUtc": "2026-08-21T01:02:03.0000000Z",
          "updatedUtc": "2026-08-21T01:02:05.0000000Z",
          "registrationSha256": "1111111111111111111111111111111111111111111111111111111111111111",
          "review": {
            "reviewId": "00000000-0000-0000-0000-000000000002",
            "state": "Closed",
            "updatedUtc": "2026-08-21T01:02:05.0000000Z",
            "auditSha256": "2222222222222222222222222222222222222222222222222222222222222222"
          },
          "evidence": [
            {
              "evidenceId": "BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB",
              "state": "Missing",
              "observedUtc": "2026-08-21T01:02:04.0000000Z",
              "metadataSha256": "DDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDD",
              "contentSha256": null
            }
          ]
        }
        """;
        const string secondRecord = """
        {
          "incidentId": "INC-001",
          "incidentState": "Suspected",
          "registeredUtc": "2026-08-21T01:02:03.0000000Z",
          "updatedUtc": "2026-08-21T01:02:04.0000000Z",
          "registrationSha256": "3333333333333333333333333333333333333333333333333333333333333333",
          "review": null,
          "evidence": [
            {
              "evidenceId": "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA",
              "state": "Present",
              "observedUtc": "2026-08-21T01:02:03.0000000Z",
              "metadataSha256": "CCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCC",
              "contentSha256": "EEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEE"
            }
          ]
        }
        """;
        var records = reverse
            ? $"{secondRecord},\n{firstRecord}"
            : $"{firstRecord},\n{secondRecord}";
        return $$"""
        {
          "schemaVersion": "{{ComplianceDiagnosticExportSchema.InputSchemaVersion}}",
          "generatedUtc": "2026-08-21T01:02:03.0000000Z",
          "records": [{{records}}]
        }
        """;
    }

    private static string Hash(string value) =>
        Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(value)));
}
