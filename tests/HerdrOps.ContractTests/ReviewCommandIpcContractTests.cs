using System.Buffers.Binary;
using System.Text;
using HerdrOps.Contracts.ReviewIpc;

namespace HerdrOps.ContractTests;

[TestClass]
public sealed class ReviewCommandIpcContractTests
{
    private static readonly DateTimeOffset BaseUtc =
        new(2026, 8, 16, 4, 0, 0, TimeSpan.Zero);

    [TestMethod]
    public void ExecuteEnvelopeRoundTripsWithExactCommandIdentity()
    {
        var request = Request();
        var envelope = HerdrOpsReviewCommandJson.CreateEnvelope(
            HerdrOpsReviewCommandProtocol.MessageTypes.Execute,
            BaseUtc,
            HerdrOpsReviewCommandProtocol.AppSource,
            request.CommandId,
            request);

        var bytes = HerdrOpsReviewCommandJson.SerializeEnvelope(envelope);
        var restoredEnvelope = HerdrOpsReviewCommandJson.DeserializeEnvelope(bytes);
        var restored = HerdrOpsReviewCommandJson
            .DeserializePayload<HerdrOpsReviewCommandRequest>(restoredEnvelope);

        Assert.AreEqual(HerdrOpsReviewCommandProtocol.Version, restoredEnvelope.ProtocolVersion);
        Assert.AreEqual(request.CommandId, restoredEnvelope.CorrelationId);
        Assert.AreEqual(request.CommandId, restored.CommandId);
        Assert.AreEqual(request.IncidentId, restored.IncidentId);
        Assert.AreEqual(request.ExpectedState, restored.ExpectedState);
        Assert.AreEqual(request.DecisionKind, restored.DecisionKind);
        CollectionAssert.AreEqual(
            request.EvidenceIdentitySha256s.ToArray(),
            restored.EvidenceIdentitySha256s.ToArray());
    }

    [TestMethod]
    public void CapabilitiesEnvelopeRoundTripsWithoutCallerSuppliedRole()
    {
        var request = new HerdrOpsReviewCapabilitiesRequest(
            "w5:p2E",
            "INC-27",
            BaseUtc);
        var correlationId = Guid.Parse("22222222-2222-2222-2222-222222222222");
        var envelope = HerdrOpsReviewCommandJson.CreateEnvelope(
            HerdrOpsReviewCommandProtocol.MessageTypes.Capabilities,
            BaseUtc,
            HerdrOpsReviewCommandProtocol.AppSource,
            correlationId,
            request);

        var bytes = HerdrOpsReviewCommandJson.SerializeEnvelope(envelope);
        var restoredEnvelope = HerdrOpsReviewCommandJson.DeserializeEnvelope(bytes);
        var restored = HerdrOpsReviewCommandJson
            .DeserializePayload<HerdrOpsReviewCapabilitiesRequest>(restoredEnvelope);

        Assert.AreEqual(correlationId, restoredEnvelope.CorrelationId);
        Assert.AreEqual(
            HerdrOpsReviewCommandProtocol.MessageTypes.Capabilities,
            restoredEnvelope.MessageType);
        Assert.AreEqual(request.ReviewerActorId, restored.ReviewerActorId);
        Assert.AreEqual(request.IncidentId, restored.IncidentId);
        Assert.AreEqual(request.ObservedUtc, restored.ObservedUtc);
        var json = Encoding.UTF8.GetString(bytes);
        Assert.IsFalse(json.Contains("reviewerRole", StringComparison.Ordinal));
        Assert.IsFalse(json.Contains("allowedDecisionKinds", StringComparison.Ordinal));
    }

    [TestMethod]
    public async Task LengthPrefixedFrameRoundTripsAndRejectsOversizePrefix()
    {
        var request = Request();
        var envelope = HerdrOpsReviewCommandJson.CreateEnvelope(
            HerdrOpsReviewCommandProtocol.MessageTypes.Execute,
            BaseUtc,
            HerdrOpsReviewCommandProtocol.AppSource,
            request.CommandId,
            request);
        await using var stream = new MemoryStream();

        await HerdrOpsReviewCommandJson.WriteFrameAsync(
            stream,
            envelope,
            CancellationToken.None);
        stream.Position = 0;
        var restored = await HerdrOpsReviewCommandJson.ReadFrameAsync(
            stream,
            CancellationToken.None);
        Assert.AreEqual(envelope.CorrelationId, restored.CorrelationId);

        var prefix = new byte[sizeof(int)];
        BinaryPrimitives.WriteInt32LittleEndian(
            prefix,
            HerdrOpsReviewCommandProtocol.MaximumFrameBytes + 1);
        await using var oversize = new MemoryStream(prefix);
        await Assert.ThrowsAsync<HerdrOpsReviewCommandProtocolException>(async () =>
            await HerdrOpsReviewCommandJson.ReadFrameAsync(
                oversize,
                CancellationToken.None));
    }

    [TestMethod]
    public void StrictJsonRejectsUnknownDuplicateAndNonUtcEnvelopeFields()
    {
        const string unknown =
            """
            {"protocolVersion":1,"messageType":"hello","sentUtc":"2026-08-16T04:00:00+00:00","source":"HerdrOps.App","correlationId":"11111111-1111-1111-1111-111111111111","payload":{},"unknown":1}
            """;
        const string duplicate =
            """
            {"protocolVersion":1,"protocolVersion":1,"messageType":"hello","sentUtc":"2026-08-16T04:00:00+00:00","source":"HerdrOps.App","correlationId":"11111111-1111-1111-1111-111111111111","payload":{}}
            """;
        var nonUtc = HerdrOpsReviewCommandJson.CreateEnvelope(
            HerdrOpsReviewCommandProtocol.MessageTypes.Hello,
            BaseUtc,
            HerdrOpsReviewCommandProtocol.AppSource,
            Guid.Parse("11111111-1111-1111-1111-111111111111"),
            new HerdrOpsReviewCommandHello(
                HerdrOpsReviewCommandProtocol.AppClientRole,
                "contract-test")) with
        {
            SentUtc = BaseUtc.ToOffset(TimeSpan.FromHours(7)),
        };

        Assert.Throws<HerdrOpsReviewCommandProtocolException>(() =>
            HerdrOpsReviewCommandJson.DeserializeEnvelope(Encoding.UTF8.GetBytes(unknown)));
        Assert.Throws<HerdrOpsReviewCommandProtocolException>(() =>
            HerdrOpsReviewCommandJson.DeserializeEnvelope(Encoding.UTF8.GetBytes(duplicate)));
        Assert.Throws<HerdrOpsReviewCommandProtocolException>(() =>
            HerdrOpsReviewCommandJson.SerializeEnvelope(nonUtc));
    }

    [TestMethod]
    public void PipeNameIsStablePerUserAndSeparateFromStatePipe()
    {
        var first = HerdrOpsReviewCommandPipeName.FromUserScope("S-1-5-21-test");
        var second = HerdrOpsReviewCommandPipeName.FromUserScope("S-1-5-21-test");
        var other = HerdrOpsReviewCommandPipeName.FromUserScope("S-1-5-21-other");

        Assert.AreEqual(first, second);
        Assert.AreNotEqual(first, other);
        StringAssert.StartsWith(first, "herdrops-review-v1-");
        Assert.IsFalse(first.Contains('\\', StringComparison.Ordinal));
        Assert.IsFalse(first.Contains('/', StringComparison.Ordinal));
    }

    [TestMethod]
    public void CliInputIsStrictAndCannotClaimAReviewerIdentity()
    {
        var input = new HerdrOpsReviewCliCommandInput(
            ContractVersion: 1,
            Guid.Parse("33333333-3333-3333-3333-333333333333"),
            "INC-27",
            ExpectedState: 1,
            ExpectedSequence: 0,
            DecisionKind: 2,
            "Send this incident to the assigned Leader.",
            [new string('B', 64)]);
        var json = HerdrOpsReviewCommandJson.Serialize(input);

        var restored = HerdrOpsReviewCommandJson.DeserializeCliCommandInput(
            Encoding.UTF8.GetBytes(json));

        Assert.AreEqual(input.CommandId, restored.CommandId);
        Assert.AreEqual(input.IncidentId, restored.IncidentId);
        Assert.IsFalse(json.Contains("reviewerActorId", StringComparison.Ordinal));
        var spoofed = json[..^1] + ",\"reviewerActorId\":\"spoofed\"}";
        Assert.Throws<HerdrOpsReviewCommandProtocolException>(() =>
            HerdrOpsReviewCommandJson.DeserializeCliCommandInput(
                Encoding.UTF8.GetBytes(spoofed)));
    }

    private static HerdrOpsReviewCommandRequest Request() =>
        new(
            ContractVersion: 1,
            Guid.Parse("11111111-1111-1111-1111-111111111111"),
            "INC-27",
            ExpectedState: 1,
            ExpectedSequence: 0,
            "project-manager",
            DecisionKind: 2,
            "Send this incident to the assigned Leader.",
            [new string('A', 64)]);
}
