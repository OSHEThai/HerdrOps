using System.IO;
using System.Text;
using System.Text.Json;
using HerdrOps.App.RuntimeEvidence;

namespace HerdrOps.RuntimeTests;

[TestClass]
public sealed class RuntimeEvidenceFailureTests
{
    private const string KnownCanonicalPayload =
        "7|herdr-reconnected-waiting-for-post-reconnect-update|2026-08-16T03:04:05.6789012+00:00|42|True|True|Connected|2026-08-16T03:04:04.0000000+00:00|2026-08-16T03:04:04.1000000+00:00|2|2|5|1|4|AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA|BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB";
    private const string KnownEntrySha256 =
        "611438DAE5CDE605590DF7DA1FB2B48F78F9EE3675F62588E34D849E46E9B564";

    [TestMethod]
    public void ProgressCanonicalPayloadMatchesPowerShell51KnownVector()
    {
        var progress = CreateKnownProgress();

        var canonicalPayload =
            RuntimeEvidenceRunner.BuildProgressCanonicalPayload(progress);

        Assert.AreEqual(KnownCanonicalPayload, canonicalPayload);
        Assert.AreEqual(
            KnownEntrySha256,
            RuntimeEvidenceRunner.ComputeProgressEntrySha256(canonicalPayload));
    }

    [TestMethod]
    public void ProgressCanonicalPayloadRejectsVisibleFieldTampering()
    {
        var original = CreateKnownProgress() with
        {
            CanonicalPayload = KnownCanonicalPayload,
            EntrySha256 = KnownEntrySha256,
        };
        var tampered = original with { EventCount = original.EventCount + 1 };

        var reconstructed =
            RuntimeEvidenceRunner.BuildProgressCanonicalPayload(tampered);

        Assert.AreNotEqual(tampered.CanonicalPayload, reconstructed);
        Assert.AreNotEqual(
            tampered.EntrySha256,
            RuntimeEvidenceRunner.ComputeProgressEntrySha256(reconstructed));
    }

    [TestMethod]
    public void AgentStatusEventEvidenceAcceptsOneExactBoundEvent()
    {
        Assert.IsTrue(RuntimeEvidenceRunner.IsExactAgentStatusEvent(
            CreateAgentStatusEvidence()));
    }

    [TestMethod]
    [DataRow(1L)]
    [DataRow(2L)]
    public void AgentStatusEventEvidenceAcceptsOneSnapshotBeforeBoundEvent(
        long reconciliationDelta)
    {
        var evidence = CreateAgentStatusEvidence() with
        {
            AdmissionPath = RuntimeEvidenceRunner.SnapshotBeforeEventAdmissionPath,
            CurrentSequence = 12,
            CurrentReconciliationCount = 4 + reconciliationDelta,
        };

        Assert.IsTrue(RuntimeEvidenceRunner.IsExactAgentStatusEvent(evidence));
    }

    [TestMethod]
    public void AgentStatusEventEvidenceRejectsAnInterveningSequence()
    {
        var evidence = CreateAgentStatusEvidence() with
        {
            CurrentSequence = 12,
        };

        Assert.IsFalse(RuntimeEvidenceRunner.IsExactAgentStatusEvent(evidence));
    }

    [TestMethod]
    [DataRow("direct-event", 12L, 5L)]
    [DataRow("snapshot-before-event", 11L, 5L)]
    [DataRow("snapshot-before-event", 13L, 6L)]
    [DataRow("snapshot-before-event", 12L, 4L)]
    [DataRow("snapshot-before-event", 12L, 7L)]
    [DataRow("unknown", 11L, 5L)]
    public void AgentStatusEventEvidenceRejectsAdmissionPathDrift(
        string admissionPath,
        long currentSequence,
        long currentReconciliationCount)
    {
        var evidence = CreateAgentStatusEvidence() with
        {
            AdmissionPath = admissionPath,
            CurrentSequence = currentSequence,
            CurrentReconciliationCount = currentReconciliationCount,
        };

        Assert.IsFalse(RuntimeEvidenceRunner.IsExactAgentStatusEvent(evidence));
    }

    [TestMethod]
    public void AgentStatusEventEvidenceRejectsMultipleAgentChanges()
    {
        var original = CreateAgentStatusEvidence();
        var evidence = original with
        {
            Changes =
            [
                original.Changes[0],
                original.Changes[0] with
                {
                    TerminalId = "term-2",
                    PaneId = "p2",
                },
            ],
        };

        Assert.IsFalse(RuntimeEvidenceRunner.IsExactAgentStatusEvent(evidence));
    }

    [TestMethod]
    public void AgentStatusEventEvidenceRejectsCollapsedStatusChanges()
    {
        var original = CreateAgentStatusEvidence();
        var evidence = original with
        {
            Changes =
            [
                original.Changes[0] with { CurrentStateChangeSequence = 12 },
            ],
        };

        Assert.IsFalse(RuntimeEvidenceRunner.IsExactAgentStatusEvent(evidence));
    }

    [TestMethod]
    public void AgentStatusEventEvidenceRejectsAgentTopologyDrift()
    {
        var evidence = CreateAgentStatusEvidence() with
        {
            CurrentAgentTopologySha256 = new string('B', 64),
        };

        Assert.IsFalse(RuntimeEvidenceRunner.IsExactAgentStatusEvent(evidence));
    }

    [TestMethod]
    public void AgentStatusEventEvidenceRejectsUnchangedAgentStatusState()
    {
        var original = CreateAgentStatusEvidence();
        var evidence = original with
        {
            CurrentAgentStatusStateSha256 = original.BaselineAgentStatusStateSha256,
        };

        Assert.IsFalse(RuntimeEvidenceRunner.IsExactAgentStatusEvent(evidence));
    }

    [TestMethod]
    public void AgentStatusEventEvidenceRejectsDisconnectedOrEpochDrift()
    {
        var evidence = CreateAgentStatusEvidence();

        Assert.IsFalse(RuntimeEvidenceRunner.IsExactAgentStatusEvent(
            evidence with { BaselineConnectionEpoch = 1 }));
        Assert.IsFalse(RuntimeEvidenceRunner.IsExactAgentStatusEvent(
            evidence with { CurrentIsCoreConnected = false }));
        Assert.IsFalse(RuntimeEvidenceRunner.IsExactAgentStatusEvent(
            evidence with { CurrentIsLive = false }));
        Assert.IsFalse(RuntimeEvidenceRunner.IsExactAgentStatusEvent(
            evidence with { CurrentRuntimeStatus = "Reconnecting" }));
    }

    [TestMethod]
    [DataRow("topology.changed", 6L, 2L, 1L, 5L)]
    [DataRow("pane.agent_status_changed", 7L, 2L, 1L, 5L)]
    [DataRow("pane.agent_status_changed", 6L, 3L, 1L, 5L)]
    [DataRow("pane.agent_status_changed", 6L, 2L, 2L, 5L)]
    [DataRow("pane.agent_status_changed", 6L, 2L, 1L, 6L)]
    public void AgentStatusEventEvidenceRejectsUnboundCounters(
        string eventKind,
        long currentEventCount,
        long currentBootstrapCount,
        long currentDisconnectCount,
        long currentReconciliationCount)
    {
        var evidence = CreateAgentStatusEvidence() with
        {
            AcceptedEventKind = eventKind,
            CurrentEventCount = currentEventCount,
            CurrentBootstrapCount = currentBootstrapCount,
            CurrentDisconnectCount = currentDisconnectCount,
            CurrentReconciliationCount = currentReconciliationCount,
        };

        Assert.IsFalse(RuntimeEvidenceRunner.IsExactAgentStatusEvent(evidence));
    }

    [TestMethod]
    public void FailureReportPreservesPartialProgressHashesAndLastRecord()
    {
        var root = Path.Combine(
            Path.GetTempPath(),
            $"herdrops-runtime-failure-{Guid.NewGuid():N}");
        Directory.CreateDirectory(root);
        try
        {
            var progressPath = Path.Combine(root, "app-progress.json");
            var historyPath = progressPath + ".history.jsonl";
            var reportPath = Path.Combine(root, "app-runtime.json");
            File.WriteAllText(
                progressPath,
                """
                {
                  "Phase": "measuring-idle-resources",
                  "History": [
                    { "IsCoreConnected": false },
                    { "IsCoreConnected": true }
                  ]
                }
                """,
                new UTF8Encoding(encoderShouldEmitUTF8Identifier: false));
            File.WriteAllLines(
                historyPath,
                ["{\"Ordinal\":1}", "{\"Ordinal\":2}"],
                new UTF8Encoding(encoderShouldEmitUTF8Identifier: false));

            RuntimeEvidenceRunner.WriteFailure(
                reportPath,
                DateTimeOffset.Parse("2026-08-16T10:00:00Z"),
                new InvalidOperationException("candidate failed"),
                progressPath);

            using var report = JsonDocument.Parse(File.ReadAllText(reportPath));
            var rootElement = report.RootElement;
            Assert.AreEqual(
                "NoRuntimeCredit",
                rootElement.GetProperty("EvidenceClassification").GetString());
            Assert.IsTrue(rootElement.GetProperty("CoreStateObserved").GetBoolean());
            var partial = rootElement.GetProperty("PartialProgress");
            Assert.IsTrue(partial.GetProperty("ProgressReportPresent").GetBoolean());
            Assert.IsTrue(partial.GetProperty("ProgressHistoryPresent").GetBoolean());
            Assert.AreEqual(
                64,
                partial.GetProperty("ProgressReportSha256").GetString()!.Length);
            Assert.AreEqual(
                64,
                partial.GetProperty("ProgressHistorySha256").GetString()!.Length);
            Assert.AreEqual(
                2,
                partial.GetProperty("ProgressHistoryEntryCount").GetInt32());
            Assert.AreEqual(
                "measuring-idle-resources",
                partial.GetProperty("LastProgress").GetProperty("Phase").GetString());
            Assert.AreEqual(
                JsonValueKind.Null,
                partial.GetProperty("ProgressReadError").ValueKind);
        }
        finally
        {
            Directory.Delete(root, recursive: true);
        }
    }

    private static RuntimeEvidenceProgress CreateKnownProgress() => new(
        Ordinal: 7,
        Phase: "herdr-reconnected-waiting-for-post-reconnect-update",
        ObservedUtc: DateTimeOffset.Parse("2026-08-16T03:04:05.6789012Z"),
        Sequence: 42,
        IsCoreConnected: true,
        IsLive: true,
        RuntimeStatus: "Connected",
        LastTransitionUtc: DateTimeOffset.Parse("2026-08-16T03:04:04Z"),
        LastAcceptedStateUtc: DateTimeOffset.Parse("2026-08-16T03:04:04.1Z"),
        ConnectionEpoch: 2,
        BootstrapCount: 2,
        EventCount: 5,
        DisconnectCount: 1,
        ReconciliationCount: 4,
        StateSha256: new string('A', 64),
        PreviousEntrySha256: new string('B', 64),
        CanonicalPayload: string.Empty,
        EntrySha256: string.Empty);

    private static RuntimeAgentStatusTransitionEvidence CreateAgentStatusEvidence() => new(
        PhaseEnteredUtc: DateTimeOffset.Parse("2026-08-16T03:04:00Z"),
        ObservedUtc: DateTimeOffset.Parse("2026-08-16T03:04:01Z"),
        AcceptedEventKind: "pane.agent_status_changed",
        AdmissionPath: RuntimeEvidenceRunner.DirectEventAdmissionPath,
        BaselineConnectionEpoch: 2,
        CurrentIsCoreConnected: true,
        CurrentIsLive: true,
        CurrentRuntimeStatus: "Connected",
        BaselineSequence: 10,
        CurrentSequence: 11,
        BaselineEventCount: 5,
        CurrentEventCount: 6,
        BaselineBootstrapCount: 2,
        CurrentBootstrapCount: 2,
        BaselineDisconnectCount: 1,
        CurrentDisconnectCount: 1,
        BaselineReconciliationCount: 4,
        CurrentReconciliationCount: 5,
        BaselineStateSha256: new string('C', 64),
        CurrentStateSha256: new string('D', 64),
        BaselineAgentTopologySha256: new string('E', 64),
        CurrentAgentTopologySha256: new string('E', 64),
        BaselineAgentStatusStateSha256: new string('F', 64),
        CurrentAgentStatusStateSha256: new string('A', 64),
        ConnectionEpoch: 2,
        Changes:
        [
            new RuntimeAgentStatusChange(
                TerminalId: "term-1",
                WorkspaceId: "w1",
                TabId: "t1",
                PaneId: "p1",
                PreviousStatus: "working",
                CurrentStatus: "idle",
                PreviousRevision: 1,
                CurrentRevision: 2,
                PreviousStateChangeSequence: 10,
                CurrentStateChangeSequence: 11),
        ]);
}
