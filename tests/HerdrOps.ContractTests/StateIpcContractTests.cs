using System.Buffers.Binary;
using System.Text;
using System.Text.Json;
using HerdrOps.Contracts.StateIpc;

namespace HerdrOps.ContractTests;

[TestClass]
public sealed class StateIpcContractTests
{
    [TestMethod]
    public async Task LengthPrefixedEnvelopeRoundTripsWithStrictHeader()
    {
        var correlationId = Guid.NewGuid();
        var envelope = HerdrOpsStateIpcJson.CreateEnvelope(
            HerdrOpsStateIpcProtocol.MessageTypes.Hello,
            0,
            new DateTimeOffset(2026, 8, 14, 10, 0, 0, TimeSpan.Zero),
            HerdrOpsStateIpcProtocol.AppSource,
            correlationId,
            new HerdrOpsStateIpcHello("app", "contract-test"));
        await using var stream = new MemoryStream();

        await HerdrOpsStateIpcJson.WriteFrameAsync(stream, envelope, CancellationToken.None);
        stream.Position = 0;
        var restored = await HerdrOpsStateIpcJson.ReadFrameAsync(stream, CancellationToken.None);

        Assert.AreEqual(HerdrOpsStateIpcProtocol.Version, restored.ProtocolVersion);
        Assert.AreEqual(HerdrOpsStateIpcProtocol.MessageTypes.Hello, restored.MessageType);
        Assert.AreEqual(correlationId, restored.CorrelationId);
        var hello = HerdrOpsStateIpcJson.DeserializePayload<HerdrOpsStateIpcHello>(restored);
        Assert.AreEqual("contract-test", hello.ClientInstanceId);
    }

    [TestMethod]
    public async Task FrameReaderRejectsZeroOversizedAndTruncatedLengths()
    {
        await AssertFrameRejectedAsync(0, []);
        await AssertFrameRejectedAsync(2048, new byte[1], maximumFrameBytes: 1024);
        await AssertFrameRejectedAsync(10, new byte[3]);
    }

    [TestMethod]
    public void StrictJsonRejectsUnmappedEnvelopeAndPayloadMembers()
    {
        var envelope = HerdrOpsStateIpcJson.CreateEnvelope(
            HerdrOpsStateIpcProtocol.MessageTypes.Hello,
            0,
            new DateTimeOffset(2026, 8, 14, 10, 0, 0, TimeSpan.Zero),
            HerdrOpsStateIpcProtocol.AppSource,
            Guid.NewGuid(),
            new HerdrOpsStateIpcHello("app", "contract-test"));
        var serializedEnvelope = Encoding.UTF8.GetString(
            HerdrOpsStateIpcJson.SerializeEnvelope(envelope));
        var envelopeWithUnknownMember = serializedEnvelope.Insert(
            serializedEnvelope.Length - 1,
            ",\"unexpected\":true");

        Assert.Throws<HerdrOpsStateIpcProtocolException>(() =>
            HerdrOpsStateIpcJson.DeserializeEnvelope(
                Encoding.UTF8.GetBytes(envelopeWithUnknownMember)));

        using var payloadDocument = JsonDocument.Parse(
            """{"clientRole":"app","clientInstanceId":"contract-test","unexpected":true}""");
        var envelopeWithUnknownPayloadMember = envelope with
        {
            Payload = payloadDocument.RootElement.Clone(),
        };
        Assert.Throws<HerdrOpsStateIpcProtocolException>(() =>
            HerdrOpsStateIpcJson.DeserializePayload<HerdrOpsStateIpcHello>(
                envelopeWithUnknownPayloadMember));
    }

    [TestMethod]
    public void StrictJsonRejectsDuplicateEnvelopeAndPayloadMembers()
    {
        var envelope = HerdrOpsStateIpcJson.CreateEnvelope(
            HerdrOpsStateIpcProtocol.MessageTypes.Hello,
            0,
            new DateTimeOffset(2026, 8, 14, 10, 0, 0, TimeSpan.Zero),
            HerdrOpsStateIpcProtocol.AppSource,
            Guid.NewGuid(),
            new HerdrOpsStateIpcHello("app", "contract-test"));
        var serializedEnvelope = Encoding.UTF8.GetString(
            HerdrOpsStateIpcJson.SerializeEnvelope(envelope));
        var duplicateEnvelopeMember =
            $"{serializedEnvelope[..^1]},\"messageType\":\"{HerdrOpsStateIpcProtocol.MessageTypes.Hello}\"}}";

        Assert.Throws<HerdrOpsStateIpcProtocolException>(() =>
            HerdrOpsStateIpcJson.DeserializeEnvelope(
                Encoding.UTF8.GetBytes(duplicateEnvelopeMember)));

        using var duplicatePayloadDocument = JsonDocument.Parse(
            "{\"clientRole\":\"app\",\"clientInstanceId\":\"first\",\"clientInstanceId\":\"second\"}");
        var envelopeWithDuplicatePayloadMember = envelope with
        {
            Payload = duplicatePayloadDocument.RootElement.Clone(),
        };

        Assert.Throws<HerdrOpsStateIpcProtocolException>(() =>
            HerdrOpsStateIpcJson.DeserializePayload<HerdrOpsStateIpcHello>(
                envelopeWithDuplicatePayloadMember));
    }

    [TestMethod]
    public void AgentEvidenceFingerprintsSeparateTopologyStatusAndPresentationChanges()
    {
        var baseline = CreateState(sequence: 1, status: "Idle", revision: 1);
        var presentationOnly = baseline with
        {
            LastIngestSequence = 2,
            FocusedWorkspaceId = null,
            FocusedTabId = null,
            FocusedPaneId = null,
        };
        var statusChanged = CreateState(sequence: 2, status: "Working", revision: 2);
        var topologyChanged = baseline with
        {
            Agents = [baseline.Agents[0] with { TerminalId = "terminal-2" }],
        };

        Assert.AreEqual(
            HerdrOpsStateIpcJson.ComputeAgentTopologySha256(baseline),
            HerdrOpsStateIpcJson.ComputeAgentTopologySha256(presentationOnly));
        Assert.AreEqual(
            HerdrOpsStateIpcJson.ComputeAgentStatusStateSha256(baseline),
            HerdrOpsStateIpcJson.ComputeAgentStatusStateSha256(presentationOnly));
        Assert.AreEqual(
            HerdrOpsStateIpcJson.ComputeAgentTopologySha256(baseline),
            HerdrOpsStateIpcJson.ComputeAgentTopologySha256(statusChanged));
        Assert.AreNotEqual(
            HerdrOpsStateIpcJson.ComputeAgentStatusStateSha256(baseline),
            HerdrOpsStateIpcJson.ComputeAgentStatusStateSha256(statusChanged));
        Assert.AreNotEqual(
            HerdrOpsStateIpcJson.ComputeAgentTopologySha256(baseline),
            HerdrOpsStateIpcJson.ComputeAgentTopologySha256(topologyChanged));
    }

    [TestMethod]
    public void DeltaReducerAppliesOnlyContiguousHashBoundState()
    {
        var current = CreateState(sequence: 1, status: "Working", revision: 1);
        var next = CreateState(sequence: 2, status: "Idle", revision: 2);
        var delta = new HerdrSessionStateDeltaContract(
            1,
            2,
            next.Version,
            next.Protocol,
            next.ConnectionEpoch,
            next.Workspaces,
            [],
            next.Tabs,
            [],
            next.Panes,
            [],
            next.Agents,
            [],
            next.FocusedWorkspaceId,
            next.FocusedTabId,
            next.FocusedPaneId);
        var payload = new HerdrOpsStateDeltaPayload(
            delta,
            HerdrOpsStateIpcJson.ComputeSha256(next),
            new HerdrRuntimeHealthContract(
                "Connected",
                new DateTimeOffset(2026, 8, 14, 10, 0, 2, TimeSpan.Zero),
                new DateTimeOffset(2026, 8, 14, 10, 0, 2, TimeSpan.Zero),
                1,
                1,
                0,
                0));

        var result = HerdrSessionStateContractReducer.ApplyAndValidateDeltaPayload(current, payload);

        Assert.AreEqual(2, result.LastIngestSequence);
        Assert.AreEqual("Idle", result.Agents[0].AgentStatus);
        Assert.Throws<HerdrOpsStateIpcProtocolException>(() =>
            HerdrSessionStateContractReducer.ApplyAndValidateDeltaPayload(result, payload));
        Assert.Throws<HerdrOpsStateIpcProtocolException>(() =>
            HerdrSessionStateContractReducer.ApplyAndValidateDeltaPayload(
                current,
                payload with { ResultStateSha256 = new string('0', 64) }));
        Assert.Throws<HerdrOpsStateIpcProtocolException>(() =>
            HerdrSessionStateContractReducer.Apply(
                current,
                delta with { ToSequence = 3 }));
    }

    [TestMethod]
    public void UserScopedPipeNameIsStableAndDoesNotExposeIdentity()
    {
        var first = HerdrOpsStatePipeName.FromUserScope("S-1-5-21-contract-a");
        var same = HerdrOpsStatePipeName.FromUserScope("S-1-5-21-contract-a");
        var other = HerdrOpsStatePipeName.FromUserScope("S-1-5-21-contract-b");

        Assert.AreEqual(first, same);
        Assert.AreNotEqual(first, other);
        Assert.DoesNotContain("S-1-5-21", first, StringComparison.Ordinal);
        Assert.StartsWith("herdrops-state-v2-", first, StringComparison.Ordinal);
    }

    [TestMethod]
    public void RuntimeHealthRejectsInvalidStatusClockAndConnectedWithoutBootstrap()
    {
        var utc = new DateTimeOffset(2026, 8, 14, 10, 0, 0, TimeSpan.Zero);
        var valid = new HerdrRuntimeHealthContract(
            "Connected",
            utc,
            utc,
            1,
            0,
            0,
            0);

        HerdrSessionStateContractReducer.ValidateRuntimeHealth(valid);
        Assert.Throws<HerdrOpsStateIpcProtocolException>(() =>
            HerdrSessionStateContractReducer.ValidateRuntimeHealth(
                valid with { Status = "Healthy" }));
        Assert.Throws<HerdrOpsStateIpcProtocolException>(() =>
            HerdrSessionStateContractReducer.ValidateRuntimeHealth(
                valid with { LastTransitionUtc = utc.ToOffset(TimeSpan.FromHours(7)) }));
        Assert.Throws<HerdrOpsStateIpcProtocolException>(() =>
            HerdrSessionStateContractReducer.ValidateRuntimeHealth(
                valid with { LastAcceptedStateUtc = utc.AddSeconds(1) }));
        Assert.Throws<HerdrOpsStateIpcProtocolException>(() =>
            HerdrSessionStateContractReducer.ValidateRuntimeHealth(
                valid with { BootstrapCount = 0 }));
    }

    private static async Task AssertFrameRejectedAsync(
        int declaredLength,
        byte[] payload,
        int maximumFrameBytes = HerdrOpsStateIpcProtocol.MaximumFrameBytes)
    {
        var prefix = new byte[sizeof(int)];
        BinaryPrimitives.WriteInt32LittleEndian(prefix, declaredLength);
        await using var stream = new MemoryStream();
        await stream.WriteAsync(prefix);
        await stream.WriteAsync(payload);
        stream.Position = 0;

        await Assert.ThrowsAsync<IOException>(async () =>
            await HerdrOpsStateIpcJson.ReadFrameAsync(
                stream,
                CancellationToken.None,
                maximumFrameBytes));
    }

    private static HerdrSessionStateContract CreateState(
        long sequence,
        string status,
        ulong revision) =>
        HerdrSessionStateContractReducer.NormalizeAndValidate(new HerdrSessionStateContract(
            "0.8.0-preview",
            19,
            1,
            sequence,
            [new("workspace-1", 1, "Test", true, 1, 1, "tab-1", status)],
            [new("tab-1", "workspace-1", 1, "Test", true, 1, status)],
            [new("pane-1", "terminal-1", "workspace-1", "tab-1", true, status, revision, null, null, null, null, null, null)],
            [new("terminal-1", "workspace-1", "tab-1", "pane-1", true, status, revision, revision, null, null, null, null, null, null, null, null, null, null)],
            "workspace-1",
            "tab-1",
            "pane-1"));
}
