using System.Text.Json;
using HerdrOps.App.Live;
using HerdrOps.App.RuntimeEvidence;
using HerdrOps.App.StateIpc;
using HerdrOps.Contracts.StateIpc;

namespace HerdrOps.RuntimeTests;

[TestClass]
public sealed class RuntimeSemanticEvidenceTests
{
    [TestMethod]
    public void SemanticCaptureProjectsLiveViewsWithoutLeakingSourceValues()
    {
        WpfTestHost.Run(() =>
        {
            using var dashboard = new LiveDashboardState();
            var state = CreateState(sequence: 10, primaryStatus: "Blocked");
            ApplySnapshot(dashboard, state);

            var capture = RuntimeEvidenceRunner.BuildSemanticStateCapture(
                1,
                "initial",
                "InitialLiveState",
                [
                    "dashboard-overview.png",
                    "dashboard-live-organization.png",
                    "dashboard-agent-detail.png",
                    "widget-compact.png",
                    "widget-normal.png",
                    "widget-floating-vertical.png",
                ],
                DateTimeOffset.Parse("2026-08-22T14:00:00Z"),
                dashboard);

            Assert.AreEqual(2, capture.Overview.TotalAgents);
            Assert.AreEqual(1, capture.Overview.StatusCounts.Single(item =>
                item.Status == "Blocked").Count);
            Assert.AreEqual(1, capture.Overview.StatusCounts.Single(item =>
                item.Status == "Unknown").Count);
            Assert.AreEqual(1, capture.LiveOrganization.WorkspaceCount);
            Assert.AreEqual(3, capture.LiveOrganization.PaneCount);
            Assert.AreEqual(2, capture.LiveOrganization.AgentCount);
            Assert.AreEqual(1, capture.LiveOrganization.UnassignedPaneCount);
            Assert.AreEqual(5, capture.LiveOrganization.ProjectedNodeCount);
            Assert.IsTrue(capture.AgentDetail.AgentSelected);
            Assert.AreEqual("Blocked", capture.AgentDetail.Status);
            Assert.AreEqual(RuntimeEvidenceRunner.MissingSemanticSource, capture.AgentDetail.Assignment);
            Assert.AreEqual(RuntimeEvidenceRunner.MissingSemanticSource, capture.AgentDetail.Tasks);
            Assert.AreEqual(RuntimeEvidenceRunner.MissingSemanticSource, capture.AgentDetail.Evidence);
            Assert.AreEqual(
                capture.CaptureStateSha256,
                RuntimeEvidenceRunner.ComputeSemanticCaptureSha256(capture));

            var json = JsonSerializer.Serialize(capture);
            foreach (var sensitiveValue in new[]
                     {
                         "terminal-sensitive-1",
                         "Agent Sensitive Name",
                         "Z:\\Sensitive\\Customer",
                         "Workspace Sensitive",
                         "Tab Sensitive",
                     })
            {
                Assert.IsFalse(
                    json.Contains(sensitiveValue, StringComparison.Ordinal),
                    $"Semantic capture leaked source value: {sensitiveValue}");
            }
        });
    }

    [TestMethod]
    public void SemanticCaptureMatrixBindingRejectsFieldTampering()
    {
        WpfTestHost.Run(() =>
        {
            using var dashboard = new LiveDashboardState();
            var initial = CreateState(sequence: 10, primaryStatus: "Blocked");
            ApplySnapshot(dashboard, initial);
            var first = RuntimeEvidenceRunner.BuildSemanticStateCapture(
                1,
                "initial",
                "InitialLiveState",
                [
                    "dashboard-overview.png",
                    "dashboard-live-organization.png",
                    "dashboard-agent-detail.png",
                    "widget-compact.png",
                    "widget-normal.png",
                    "widget-floating-vertical.png",
                ],
                DateTimeOffset.Parse("2026-08-22T14:00:00Z"),
                dashboard);

            var preClose = CreateState(sequence: 11, primaryStatus: "Idle");
            ApplySnapshot(dashboard, preClose);
            var second = RuntimeEvidenceRunner.BuildSemanticStateCapture(
                2,
                "event-a-pre-close",
                "EventA",
                ["dashboard-overview-after-event.png"],
                DateTimeOffset.Parse("2026-08-22T14:00:01Z"),
                dashboard);

            var postClose = CreateState(sequence: 12, primaryStatus: "Working");
            ApplySnapshot(dashboard, postClose);
            var third = RuntimeEvidenceRunner.BuildSemanticStateCapture(
                3,
                "post-close-final",
                "EventB",
                ["widget-floating-vertical-after-dashboard-close.png"],
                DateTimeOffset.Parse("2026-08-22T14:00:02Z"),
                dashboard);
            var captures = new[] { first, second, third };
            var eventA = CreateEventEvidence(second.Sequence, second.NormalizedStateSha256);
            var eventB = CreateEventEvidence(third.Sequence, third.NormalizedStateSha256);

            Assert.HasCount(3, captures.Select(item => item.CaptureStateSha256)
                .Distinct(StringComparer.Ordinal));
            Assert.IsTrue(RuntimeEvidenceRunner.AreSemanticStateCapturesBound(
                captures,
                first.Sequence,
                first.NormalizedStateSha256,
                eventA,
                second.Sequence,
                second.NormalizedStateSha256,
                eventB,
                third.Sequence,
                third.NormalizedStateSha256));

            var tampered = captures.ToArray();
            tampered[1] = tampered[1] with
            {
                Overview = tampered[1].Overview with
                {
                    TotalAgents = tampered[1].Overview.TotalAgents + 1,
                },
            };
            Assert.IsFalse(RuntimeEvidenceRunner.AreSemanticStateCapturesBound(
                tampered,
                first.Sequence,
                first.NormalizedStateSha256,
                eventA,
                second.Sequence,
                second.NormalizedStateSha256,
                eventB,
                third.Sequence,
                third.NormalizedStateSha256));
        });
    }

    private static HerdrSessionStateContract CreateState(long sequence, string primaryStatus) =>
        HerdrSessionStateContractReducer.NormalizeAndValidate(new HerdrSessionStateContract(
            "0.8.2-preview",
            19,
            2,
            sequence,
            [new("workspace-sensitive", 1, "Workspace Sensitive", true, 3, 1, "tab-sensitive", primaryStatus)],
            [new("tab-sensitive", "workspace-sensitive", 1, "Tab Sensitive", true, 3, primaryStatus)],
            [
                new("pane-sensitive-1", "terminal-sensitive-1", "workspace-sensitive", "tab-sensitive", true, primaryStatus, 8, "codex", "Codex", "Sensitive title", "Z:\\Sensitive\\Customer", "Z:\\Sensitive\\Customer", "Sensitive terminal title"),
                new("pane-sensitive-2", "terminal-sensitive-2", "workspace-sensitive", "tab-sensitive", false, "Unknown", 3, "claude", "Claude", "Reviewer", "Z:\\Sensitive\\Customer", null, "Claude"),
                new("pane-unassigned", "terminal-unassigned", "workspace-sensitive", "tab-sensitive", false, "Unknown", 1, null, null, null, null, null, null),
            ],
            [
                new("terminal-sensitive-1", "workspace-sensitive", "tab-sensitive", "pane-sensitive-1", true, primaryStatus, 8, 8, "codex", "Codex", "Agent Sensitive Name", "Sensitive title", "Z:\\Sensitive\\Customer", "Z:\\Sensitive\\Customer", "Sensitive terminal title", true, false, false),
                new("terminal-sensitive-2", "workspace-sensitive", "tab-sensitive", "pane-sensitive-2", false, "Unknown", 3, 3, "claude", "Claude", "Reviewer Sensitive", "Reviewer", "Z:\\Sensitive\\Customer", null, "Claude", null, null, null),
            ],
            "workspace-sensitive",
            "tab-sensitive",
            "pane-sensitive-1"));

    private static void ApplySnapshot(
        LiveDashboardState dashboard,
        HerdrSessionStateContract state)
    {
        var acceptedUtc = DateTimeOffset.Parse("2026-08-22T13:59:59Z")
            .AddSeconds(state.LastIngestSequence);
        var health = new HerdrRuntimeHealthContract(
            "Connected",
            acceptedUtc,
            acceptedUtc,
            BootstrapCount: 1,
            EventCount: state.LastIngestSequence,
            DisconnectCount: 0,
            ReconciliationCount: 0);
        var payload = new HerdrOpsStateSnapshotPayload(
            state,
            HerdrOpsStateIpcJson.ComputeSha256(state),
            health);
        var envelope = HerdrOpsStateIpcJson.CreateEnvelope(
            HerdrOpsStateIpcProtocol.MessageTypes.Snapshot,
            state.LastIngestSequence,
            acceptedUtc,
            HerdrOpsStateIpcProtocol.CoreSource,
            Guid.NewGuid(),
            payload);
        dashboard.ApplyUpdate(
            new HerdrOpsStateUpdate(
                HerdrOpsStateUpdateKind.Snapshot,
                state,
                envelope,
                payload,
                null,
                health),
            acceptedUtc.AddMilliseconds(5));
    }

    private static RuntimeAgentStatusTransitionEvidence CreateEventEvidence(
        long sequence,
        string stateSha256) =>
        new(
            DateTimeOffset.Parse("2026-08-22T14:00:00Z"),
            DateTimeOffset.Parse("2026-08-22T14:00:01Z"),
            "pane.agent_status_changed",
            RuntimeEvidenceRunner.DirectEventAdmissionPath,
            2,
            true,
            true,
            "Connected",
            sequence - 1,
            sequence,
            sequence - 1,
            sequence,
            1,
            1,
            0,
            0,
            0,
            1,
            new string('A', 64),
            stateSha256,
            new string('B', 64),
            new string('B', 64),
            new string('C', 64),
            new string('D', 64),
            2,
            []);
}
