using System.Text;
using HerdrOps.Contracts.ComplianceDiagnosticExport;

namespace HerdrOps.ContractTests;

[TestClass]
public sealed class ComplianceDiagnosticExportContractTests
{
    [TestMethod]
    public void RequestAndResponseUseExactVersionedFields()
    {
        var request = new ComplianceDiagnosticExportRequest(
            ComplianceDiagnosticExportProtocol.Version,
            ComplianceDiagnosticExportProtocol.MessageTypes.Export,
            DateTimeOffset.Parse("2026-08-21T01:02:03.0000000Z"),
            ComplianceDiagnosticExportProtocol.CliSource,
            Guid.Parse("00000000-0000-0000-0000-000000000001"),
            "C:\\temp\\diagnostic.json",
            Convert.ToBase64String(Encoding.UTF8.GetBytes("{}")));
        var requestJson = Encoding.UTF8.GetString(
            ComplianceDiagnosticExportJson.SerializeRequest(request));
        StringAssert.Contains(requestJson, "\"ProtocolVersion\":1");
        StringAssert.Contains(requestJson, "\"MessageType\":\"compliance-diagnostic-export\"");
        Assert.AreEqual(request, ComplianceDiagnosticExportJson.DeserializeRequest(
            Encoding.UTF8.GetBytes(requestJson)));

        var response = new ComplianceDiagnosticExportResponse(
            ComplianceDiagnosticExportProtocol.Version,
            ComplianceDiagnosticExportProtocol.MessageTypes.Accepted,
            DateTimeOffset.Parse("2026-08-21T01:02:04.0000000Z"),
            ComplianceDiagnosticExportProtocol.CoreSource,
            request.CorrelationId,
            Accepted: true,
            ComplianceDiagnosticExportProtocol.ResultCodes.Accepted,
            "The compliance diagnostic export was written.",
            1,
            128,
            new string('A', 64));
        var responseJson = Encoding.UTF8.GetString(
            ComplianceDiagnosticExportJson.SerializeResponse(response));
        Assert.IsFalse(responseJson.Contains("OutputPath", StringComparison.Ordinal));
        Assert.AreEqual(response, ComplianceDiagnosticExportJson.DeserializeResponse(
            Encoding.UTF8.GetBytes(responseJson)));
    }

    [TestMethod]
    public void DuplicateUnknownAndOversizedFramesFailClosed()
    {
        const string duplicate = """
        {
          "ProtocolVersion": 1,
          "ProtocolVersion": 1,
          "MessageType": "compliance-diagnostic-export",
          "SentUtc": "2026-08-21T01:02:03Z",
          "Source": "HerdrOps.Cli",
          "CorrelationId": "00000000-0000-0000-0000-000000000001",
          "OutputPath": "C:\\temp\\diagnostic.json",
          "InputBase64": "e30="
        }
        """;
        Assert.ThrowsExactly<ComplianceDiagnosticExportProtocolException>(() =>
            ComplianceDiagnosticExportJson.DeserializeRequest(Encoding.UTF8.GetBytes(duplicate)));

        var unknown = duplicate.Replace(
            "\"ProtocolVersion\": 1,\n          \"ProtocolVersion\": 1,",
            "\"ProtocolVersion\": 1,\n          \"UnexpectedPassword\": \"do-not-return\",",
            StringComparison.Ordinal);
        Assert.ThrowsExactly<ComplianceDiagnosticExportProtocolException>(() =>
            ComplianceDiagnosticExportJson.DeserializeRequest(Encoding.UTF8.GetBytes(unknown)));

        Assert.ThrowsExactly<ComplianceDiagnosticExportProtocolException>(() =>
            ComplianceDiagnosticExportJson.WriteFrameAsync(
                new MemoryStream(),
                new byte[ComplianceDiagnosticExportProtocol.MaximumFrameBytes],
                CancellationToken.None)
            .GetAwaiter()
            .GetResult());
    }

    [TestMethod]
    public void ResponseValidationRejectsPathLeakAndMaskedAcceptance()
    {
        var response = new ComplianceDiagnosticExportResponse(
            ComplianceDiagnosticExportProtocol.Version,
            ComplianceDiagnosticExportProtocol.MessageTypes.Accepted,
            DateTimeOffset.UtcNow,
            ComplianceDiagnosticExportProtocol.CoreSource,
            Guid.NewGuid(),
            Accepted: true,
            ComplianceDiagnosticExportProtocol.ResultCodes.Accepted,
            "C:\\Users\\Alice\\private.txt",
            1,
            1,
            new string('A', 64));
        Assert.ThrowsExactly<ComplianceDiagnosticExportProtocolException>(() =>
            ComplianceDiagnosticExportJson.ValidateResponse(response));

        var masked = response with
        {
            Message = "ok",
            RecordCount = null,
            ByteCount = null,
            OutputSha256 = null,
        };
        Assert.ThrowsExactly<ComplianceDiagnosticExportProtocolException>(() =>
            ComplianceDiagnosticExportJson.ValidateResponse(masked));
    }

    [TestMethod]
    public void PipeNameIsCurrentUserScopedAndPathFree()
    {
        var first = ComplianceDiagnosticExportPipeName.FromUserScope("S-1-5-21-test");
        var second = ComplianceDiagnosticExportPipeName.FromUserScope("S-1-5-21-test");

        Assert.AreEqual(first, second);
        StringAssert.StartsWith(first, "herdrops-compliance-diagnostic-v1-");
        Assert.DoesNotContain('\\', first);
        Assert.DoesNotContain('/', first);
        Assert.AreEqual(58, first.Length);
    }
}
