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
            new WidgetLatencySnapshot(historical.Length, historical.Length, null, null, historical));
        Assert.AreEqual(20L, baseline);

        var frozen = Issue10PerformanceTelemetryProducer.SelectFreshLatencySamples(
            new WidgetLatencySnapshot(historical.Length, historical.Length, null, null, historical), baseline);
        Assert.IsEmpty(frozen, "A frozen dashboard must not replay historical latency samples.");

        var fresh = historical.Concat(Enumerable.Range(21, 20).Select(Sample)).ToArray();
        var selected = Issue10PerformanceTelemetryProducer.SelectFreshLatencySamples(
            new WidgetLatencySnapshot(fresh.Length, fresh.Length, null, null, fresh), baseline);
        CollectionAssert.AreEqual(Enumerable.Range(21, 20).Select(value => (long)value).ToArray(),
            selected.Select(sample => sample.StateSequence).ToArray());

        var replay = historical.Concat(new[] { Sample(21), Sample(22), Sample(21) }).ToArray();
        var exception = Assert.ThrowsExactly<InvalidDataException>(() =>
            Issue10PerformanceTelemetryProducer.SelectFreshLatencySamples(
                new WidgetLatencySnapshot(replay.Length, replay.Length, null, null, replay), baseline));
        StringAssert.Contains(exception.Message, "replayed or reordered");

        var rollingFrozen = Issue10PerformanceTelemetryProducer.SelectNewSoakLatencySamples(
            new WidgetLatencySnapshot(historical.Length, historical.Length, null, null, historical), baseline, baseline, historical.Length, historical.Length);
        Assert.IsEmpty(rollingFrozen, "A frozen soak request must not replay history from before admission.");
        var oneNew = historical.Concat(new[] { Sample(21) }).ToArray();
        var rolling = Issue10PerformanceTelemetryProducer.SelectNewSoakLatencySamples(
            new WidgetLatencySnapshot(oneNew.Length, oneNew.Length, null, null, oneNew), baseline, baseline, historical.Length, historical.Length);
        Assert.HasCount(1, rolling, "A genuine post-admission update is emitted without replaying history.");
        Assert.AreEqual(21L, rolling[0].StateSequence);
        var emittedOnce = Issue10PerformanceTelemetryProducer.SelectNewSoakLatencySamples(
            new WidgetLatencySnapshot(oneNew.Length, oneNew.Length, null, null, oneNew), baseline, 21, historical.Length, oneNew.Length);
        Assert.IsEmpty(emittedOnce, "An emitted update must not be replayed by the next soak packet.");
        Assert.ThrowsExactly<InvalidDataException>(() =>
            Issue10PerformanceTelemetryProducer.SelectNewSoakLatencySamples(
                new WidgetLatencySnapshot(oneNew.Length, oneNew.Length, null, null, oneNew), baseline, baseline - 1, historical.Length, historical.Length));

        var overflowWindow = Enumerable.Range(22, 512).Select(Sample).ToArray();
        var overflow = Assert.ThrowsExactly<InvalidDataException>(() =>
            Issue10PerformanceTelemetryProducer.SelectNewSoakLatencySamples(
                new WidgetLatencySnapshot(512, 534, null, null, overflowWindow), baseline, 21, historical.Length, oneNew.Length));
        StringAssert.Contains(overflow.Message, "lost or reset");

        var telemetry = new WidgetUpdateTelemetry();
        foreach (var sample in historical) telemetry.Record(sample);
        telemetry.Reset();
        foreach (var sample in Enumerable.Range(1, 40).Select(Sample)) telemetry.Record(sample);
        var resetCatchUp = Assert.ThrowsExactly<InvalidDataException>(() =>
            Issue10PerformanceTelemetryProducer.SelectNewSoakLatencySamples(
                telemetry.Snapshot(), baseline, baseline, historical.Length, historical.Length));
        StringAssert.Contains(resetCatchUp.Message, "lost or reset");

        Issue10PerformanceTelemetryProducer.RequireNextSoakSequence(0, 0);
        Assert.ThrowsExactly<InvalidDataException>(() => Issue10PerformanceTelemetryProducer.RequireNextSoakSequence(0, 1));
        Assert.ThrowsExactly<InvalidDataException>(() => Issue10PerformanceTelemetryProducer.RequireNextSoakSequence(2, 1));
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

    [TestMethod]
    public void SoakPacketCanonicalHashMatchesCrossLanguageZeroUpdateGolden()
    {
        const string json = """{"schemaVersion":2,"nonce":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","sequenceNumber":0,"observedUtc":"2026-08-24T00:00:01.0000000+00:00","binIndex":0,"sampleIndex":0,"producer":{"appProcessId":101,"coreProcessId":202,"appStartTimeUtc":"2026-08-24T00:00:00.0000000Z","coreStartTimeUtc":"2026-08-24T00:00:00.0000000Z","appExecutablePath":"C:\\Program Files\\HerdrOps\\HerdrOps.App.exe","coreExecutablePath":"C:\\Program Files\\HerdrOps\\HerdrOps.Core.exe","appExecutableSha256":"AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA","coreExecutableSha256":"BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB"},"metrics":{"latency":{"baselineStateSequence":10,"afterStateSequence":10,"watermarkStateSequence":10,"baselineRecordCount":20,"afterRecordCount":20,"recordCount":20,"updates":[]},"uiStallMicroseconds":[10000,10000,10000,10000,10000,10000,10000,10000,10000,10000,10000,10000,10000,10000,10000,10000,10000,10000,10000,10000],"rendererStable":true}}""";
        using var document = JsonDocument.Parse(json);
        var canonical = Issue10PackageValidator.Canonicalize(document.RootElement);
        var hash = Convert.ToHexString(SHA256.HashData(System.Text.Encoding.UTF8.GetBytes(canonical)));
        Assert.AreEqual("A8BD43DE995F7C62959B65F99827E55ED644918113A1E01B1032750A1F7B84D1", hash);
    }

    private static WidgetUpdateLatencySample Sample(int sequence)
    {
        var accepted = DateTimeOffset.UnixEpoch.AddSeconds(sequence);
        return new WidgetUpdateLatencySample(
            sequence, sequence, sequence, Guid.NewGuid(), new string('A', 64), "Delta",
            accepted, accepted.AddMilliseconds(1), accepted.AddMilliseconds(2));
    }
}
