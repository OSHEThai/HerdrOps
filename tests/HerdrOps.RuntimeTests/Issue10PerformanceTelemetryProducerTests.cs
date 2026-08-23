using System.IO;
using System.Diagnostics;
using System.Security.Cryptography;
using System.Text.Json;
using HerdrOps.App.RuntimeEvidence;
using HerdrOps.App.Widgets;

namespace HerdrOps.RuntimeTests;

[TestClass]
public sealed class Issue10PerformanceTelemetryProducerTests
{
    [TestMethod]
    public void FreshLatencySelectionRejectsFrozenAndReplayedStateSequences()
    {
        var historical = Enumerable.Range(1, 20).Select(Sample).ToArray();
        var baseline = Issue10PerformanceTelemetryProducer.CaptureLatencyBaseline(
            new WidgetLatencySnapshot(historical.Length, null, null, historical));
        Assert.AreEqual(20L, baseline);

        var frozen = Issue10PerformanceTelemetryProducer.SelectFreshLatencySamples(
            new WidgetLatencySnapshot(historical.Length, null, null, historical), baseline);
        Assert.IsEmpty(frozen, "A frozen dashboard must not replay historical latency samples.");

        var fresh = historical.Concat(Enumerable.Range(21, 20).Select(Sample)).ToArray();
        var selected = Issue10PerformanceTelemetryProducer.SelectFreshLatencySamples(
            new WidgetLatencySnapshot(fresh.Length, null, null, fresh), baseline);
        CollectionAssert.AreEqual(Enumerable.Range(21, 20).Select(value => (long)value).ToArray(),
            selected.Select(sample => sample.StateSequence).ToArray());

        var replay = historical.Concat(new[] { Sample(21), Sample(22), Sample(21) }).ToArray();
        var exception = Assert.ThrowsExactly<InvalidDataException>(() =>
            Issue10PerformanceTelemetryProducer.SelectFreshLatencySamples(
                new WidgetLatencySnapshot(replay.Length, null, null, replay), baseline));
        StringAssert.Contains(exception.Message, "replayed or reordered");

        var rollingFrozen = Issue10PerformanceTelemetryProducer.SelectRollingSoakLatencySamples(
            new WidgetLatencySnapshot(historical.Length, null, null, historical), baseline);
        Assert.IsEmpty(rollingFrozen, "A frozen soak request must not replay its prior rolling window.");
        var oneNew = historical.Concat(new[] { Sample(21) }).ToArray();
        var rolling = Issue10PerformanceTelemetryProducer.SelectRollingSoakLatencySamples(
            new WidgetLatencySnapshot(oneNew.Length, null, null, oneNew), baseline);
        Assert.HasCount(20, rolling, "One fresh state per governed interval must advance a complete rolling latency window.");
        Assert.AreEqual(2L, rolling[0].StateSequence);
        Assert.AreEqual(21L, rolling[^1].StateSequence);
    }

    [TestMethod]
    public void ProductionRequestParserRejectsNonceSequenceSemanticAndCorePidTransplants()
    {
        const string nonce = "0123456789abcdef0123456789abcdef";
        var valid = JsonSerializer.Serialize(new
        {
            schemaVersion = 1,
            kind = "issue10-performance-sample-request",
            runNonce = nonce,
            sequenceNumber = 0,
            order = "AB",
            isWarmup = true,
            repetitionOrdinal = 0,
            semanticMode = "a",
            coreProcessId = 4321,
            coreStartUtc = "2026-08-24T00:00:00.0000000+00:00",
        });
        var parsed = Issue10PerformanceTelemetryProducer.ParseRequest(valid, "Hardware", nonce, 1234);
        Assert.AreEqual(4321, parsed.CoreProcessId);

        AssertRejected(valid.Replace(nonce, new string('f', 32), StringComparison.Ordinal), "Hardware", nonce, 1234);
        AssertRejected(valid.Replace("\"sequenceNumber\":0", "\"sequenceNumber\":24", StringComparison.Ordinal), "Hardware", nonce, 1234);
        AssertRejected(valid.Replace("\"sequenceNumber\":0", "\"sequenceNumber\":2", StringComparison.Ordinal), "Hardware", nonce, 1234);
        AssertRejected(valid.Replace("\"semanticMode\":\"a\"", "\"semanticMode\":\"b\"", StringComparison.Ordinal), "Hardware", nonce, 1234);
        AssertRejected(valid.Replace("\"coreProcessId\":4321", "\"coreProcessId\":1234", StringComparison.Ordinal), "Hardware", nonce, 1234);
        AssertRejected(valid.Replace("2026-08-24T00:00:00.0000000\\u002B00:00", "2026-08-24T07:00:00.0000000\\u002B07:00", StringComparison.Ordinal), "Hardware", nonce, 1234);
        AssertRejected(valid.Replace(",\"coreStartUtc\":\"2026-08-24T00:00:00.0000000\\u002B00:00\"", string.Empty, StringComparison.Ordinal), "Hardware", nonce, 1234);
        AssertRejected(valid.Replace("\"coreStartUtc\"", "\"unknownCoreStartUtc\"", StringComparison.Ordinal), "Hardware", nonce, 1234);
        AssertRejected(valid.Replace("\"sequenceNumber\":0", "\"sequenceNumber\":0,\"sequenceNumber\":0", StringComparison.Ordinal), "Hardware", nonce, 1234);
    }

    private static void AssertRejected(string json, string mode, string nonce, int appPid) =>
        Assert.ThrowsExactly<InvalidDataException>(() =>
            Issue10PerformanceTelemetryProducer.ParseRequest(json, mode, nonce, appPid));

    [TestMethod]
    public void ProductionProcessIdentityGuardRejectsStaleStartAndExecutableTransplant()
    {
        using var process = Process.GetCurrentProcess();
        var path = process.MainModule!.FileName!;
        var sha = Convert.ToHexString(SHA256.HashData(File.ReadAllBytes(path)));
        var start = new DateTimeOffset(process.StartTime.ToUniversalTime(), TimeSpan.Zero);
        _ = Issue10PerformanceTelemetryProducer.ValidateProcessIdentity(process, start, path, sha, "test server");
        Assert.ThrowsExactly<UnauthorizedAccessException>(() =>
            Issue10PerformanceTelemetryProducer.ValidateProcessIdentity(process, start.AddTicks(-1), path, sha, "test server"));
        Assert.ThrowsExactly<UnauthorizedAccessException>(() =>
            Issue10PerformanceTelemetryProducer.ValidateProcessIdentity(process, start, path, new string('A', 64), "test server"));
    }

    private static WidgetUpdateLatencySample Sample(int sequence)
    {
        var accepted = DateTimeOffset.UnixEpoch.AddSeconds(sequence);
        return new WidgetUpdateLatencySample(
            sequence, sequence, sequence, Guid.NewGuid(), new string('A', 64), "Delta",
            accepted, accepted.AddMilliseconds(1), accepted.AddMilliseconds(2));
    }
}
