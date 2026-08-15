using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using HerdrOps.Domain.Herdr;
using HerdrOps.Infrastructure.Herdr;

namespace HerdrOps.ContractTests;

[TestClass]
public sealed class HerdrProtocolJsonCodecContractTests
{
    [TestMethod]
    public void SnapshotRequestUsesExactMethodEmptyParamsAndCallerId()
    {
        var bytes = HerdrProtocolJsonCodec.CreateSnapshotRequest("request-1");
        using var document = JsonDocument.Parse(bytes);
        var root = document.RootElement;

        Assert.AreEqual("request-1", root.GetProperty("id").GetString());
        Assert.AreEqual("session.snapshot", root.GetProperty("method").GetString());
        Assert.AreEqual(0, root.GetProperty("params").EnumerateObject().Count());
        Assert.IsFalse(Encoding.UTF8.GetString(bytes).Contains('\n', StringComparison.Ordinal));
    }

    [TestMethod]
    public void SubscriptionRequestContainsGeneralEventsAndOneFilteredStatusPerUniquePane()
    {
        var bytes = HerdrProtocolJsonCodec.CreateSubscriptionRequest(
            "request-2",
            ["pane-b", "pane-a", "pane-a"]);
        using var document = JsonDocument.Parse(bytes);
        var subscriptions = document.RootElement
            .GetProperty("params")
            .GetProperty("subscriptions")
            .EnumerateArray()
            .ToArray();

        Assert.AreEqual("events.subscribe", document.RootElement.GetProperty("method").GetString());
        Assert.HasCount(26, subscriptions);
        Assert.IsTrue(subscriptions.Any(item => item.GetProperty("type").GetString() == "workspace.created"));
        Assert.IsTrue(subscriptions.Any(item => item.GetProperty("type").GetString() == "pane.updated"));
        Assert.IsTrue(subscriptions.Any(item => item.GetProperty("type").GetString() == "layout.updated"));
        var filtered = subscriptions
            .Where(item => item.GetProperty("type").GetString() == "pane.agent_status_changed")
            .Select(item => item.GetProperty("pane_id").GetString())
            .ToArray();
        CollectionAssert.AreEqual(new[] { "pane-a", "pane-b" }, filtered);
    }

    [TestMethod]
    public void SnapshotResponseParsesAllFourRequiredEntityCollections()
    {
        var snapshot = HerdrProtocolJsonCodec.ParseSnapshotResponse(
            CreateSnapshotResponse("request-3", revision: 4),
            "request-3");

        Assert.AreEqual("0.8.0-preview", snapshot.Version);
        Assert.AreEqual(19, snapshot.Protocol);
        Assert.HasCount(1, snapshot.Workspaces);
        Assert.HasCount(1, snapshot.Tabs);
        Assert.HasCount(1, snapshot.Panes);
        Assert.HasCount(1, snapshot.Agents);
        Assert.AreEqual((ulong)4, snapshot.Panes[0].Revision);
        Assert.AreEqual((ulong)4, snapshot.Agents[0].Revision);
        Assert.AreEqual(HerdrAgentStatus.Working, snapshot.Agents[0].AgentStatus);
    }

    [TestMethod]
    public void ResponseCorrelationMismatchFailsClosed()
    {
        var exception = Assert.ThrowsExactly<HerdrProtocolException>(() =>
            HerdrProtocolJsonCodec.ParseSnapshotResponse(
                CreateSnapshotResponse("other-request", revision: 1),
                "expected-request"));

        StringAssert.Contains(exception.Message, "did not match request id");
    }

    [TestMethod]
    public void SnapshotWithDifferentProtocolFailsClosed()
    {
        var response = CreateSnapshotResponse("request-protocol", revision: 1)
            .Replace("\"protocol\": 19", "\"protocol\": 20", StringComparison.Ordinal);

        var exception = Assert.ThrowsExactly<HerdrProtocolException>(() =>
            HerdrProtocolJsonCodec.ParseSnapshotResponse(response, "request-protocol"));

        StringAssert.Contains(exception.Message, "is not the admitted protocol 19");
    }

    [TestMethod]
    public void SnapshotMissingRequiredLayoutsArrayFailsClosed()
    {
        var responseNode = JsonNode.Parse(CreateSnapshotResponse("request-layouts", revision: 1))!;
        var snapshotNode = responseNode["result"]!["snapshot"]!.AsObject();
        Assert.IsTrue(snapshotNode.Remove("layouts"));

        var exception = Assert.ThrowsExactly<HerdrProtocolException>(() =>
            HerdrProtocolJsonCodec.ParseSnapshotResponse(responseNode.ToJsonString(), "request-layouts"));

        StringAssert.Contains(exception.Message, "missing required property 'layouts'");
    }

    [TestMethod]
    public void ApiErrorIsNotAcceptedAsSnapshot()
    {
        var exception = Assert.ThrowsExactly<HerdrApiErrorException>(() =>
            HerdrProtocolJsonCodec.ParseSnapshotResponse(
                """
                {"id":"request-4","error":{"code":"invalid_request","message":"bad request"}}
                """,
                "request-4"));

        Assert.AreEqual("invalid_request", exception.Code);
        StringAssert.Contains(exception.Message, "bad request");
    }

    [TestMethod]
    public void RegularAndFilteredStatusEventsMapToTheSameTypedStateChange()
    {
        var regular = HerdrProtocolJsonCodec.ParseEvent(
            """
            {"event":"pane_agent_status_changed","data":{"type":"pane_agent_status_changed","pane_id":"pane-1","workspace_id":"workspace-1","agent_status":"blocked","agent":"codex","display_agent":"Codex","title":"Waiting"}}
            """);
        var filtered = HerdrProtocolJsonCodec.ParseEvent(
            """
            {"event":"pane.agent_status_changed","data":{"pane_id":"pane-1","workspace_id":"workspace-1","agent_status":"blocked","agent":"codex","display_agent":"Codex","title":"Waiting"}}
            """);

        Assert.IsInstanceOfType<HerdrPaneAgentStatusChangedEvent>(regular);
        Assert.IsInstanceOfType<HerdrPaneAgentStatusChangedEvent>(filtered);
        Assert.AreEqual(
            HerdrAgentStatus.Blocked,
            ((HerdrPaneAgentStatusChangedEvent)filtered).AgentStatus);
    }

    [TestMethod]
    public void AgentDetectionEventRetainsIdentityReleaseAndFinalStatus()
    {
        var stateEvent = HerdrProtocolJsonCodec.ParseEvent(
            """
            {"event":"pane_agent_detected","data":{"type":"pane_agent_detected","pane_id":"pane-1","workspace_id":"workspace-1","agent":"codex","final_status":"done","released":true}}
            """);

        var detected = Assert.IsInstanceOfType<HerdrPaneAgentDetectedEvent>(stateEvent);
        Assert.AreEqual("workspace-1", detected.WorkspaceId);
        Assert.AreEqual("pane-1", detected.PaneId);
        Assert.AreEqual("codex", detected.Agent);
        Assert.AreEqual(HerdrAgentStatus.Done, detected.FinalStatus);
        Assert.IsTrue(detected.Released);
    }

    [TestMethod]
    public void MinimalAgentFreeReplayFramesRemainTypedWithoutInventingIdentity()
    {
        var status = HerdrProtocolJsonCodec.ParseEvent(
            """
            {"event":"pane.agent_status_changed","data":{"pane_id":"pane-shell","workspace_id":"workspace-1","agent_status":"unknown"}}
            """);
        var detection = HerdrProtocolJsonCodec.ParseEvent(
            """
            {"event":"pane_agent_detected","data":{"type":"pane_agent_detected","pane_id":"pane-shell","workspace_id":"workspace-1"}}
            """);

        var statusChanged = Assert.IsInstanceOfType<HerdrPaneAgentStatusChangedEvent>(status);
        Assert.AreEqual(HerdrAgentStatus.Unknown, statusChanged.AgentStatus);
        Assert.IsNull(statusChanged.Agent);
        Assert.IsNull(statusChanged.DisplayAgent);
        Assert.IsNull(statusChanged.Title);
        var detected = Assert.IsInstanceOfType<HerdrPaneAgentDetectedEvent>(detection);
        Assert.IsNull(detected.Agent);
        Assert.IsNull(detected.FinalStatus);
        Assert.IsNull(detected.Released);
    }

    [TestMethod]
    public void EventEnvelopeAndEmbeddedTypeMustAgree()
    {
        var exception = Assert.ThrowsExactly<HerdrProtocolException>(() =>
            HerdrProtocolJsonCodec.ParseEvent(
                """
                {"event":"pane_updated","data":{"type":"pane_created"}}
                """));

        StringAssert.Contains(exception.Message, "disagrees with data type");
    }

    [TestMethod]
    public void GeneralEventMissingRequiredEmbeddedTypeFailsClosed()
    {
        var exception = Assert.ThrowsExactly<HerdrProtocolException>(() =>
            HerdrProtocolJsonCodec.ParseEvent(
                """
                {"event":"workspace_created","data":{"workspace":{}}}
                """));

        StringAssert.Contains(exception.Message, "missing required data.type");
    }

    [TestMethod]
    public void UnknownEventRequestsFreshSnapshotRatherThanSilentContinuation()
    {
        var stateEvent = HerdrProtocolJsonCodec.ParseEvent(
            """
            {"event":"future_event","data":{"type":"future_event"}}
            """);

        Assert.IsInstanceOfType<HerdrReconciliationRequestedEvent>(stateEvent);
        StringAssert.Contains(
            ((HerdrReconciliationRequestedEvent)stateEvent).Reason,
            "fresh snapshot");
    }

    [TestMethod]
    public void PaneReadRequestIsAlwaysBoundedRecentUnwrappedPlainText()
    {
        var bytes = HerdrProtocolJsonCodec.CreateBoundedPaneReadRequest(
            "request-pane-read",
            "pane-1",
            maximumLines: 80);
        using var document = JsonDocument.Parse(bytes);
        var root = document.RootElement;
        var parameters = root.GetProperty("params");

        Assert.AreEqual("request-pane-read", root.GetProperty("id").GetString());
        Assert.AreEqual("pane.read", root.GetProperty("method").GetString());
        Assert.AreEqual("pane-1", parameters.GetProperty("pane_id").GetString());
        Assert.AreEqual("recent_unwrapped", parameters.GetProperty("source").GetString());
        Assert.AreEqual("text", parameters.GetProperty("format").GetString());
        Assert.AreEqual(80, parameters.GetProperty("lines").GetInt32());
        Assert.IsTrue(parameters.GetProperty("strip_ansi").GetBoolean());
        Assert.HasCount(5, parameters.EnumerateObject().ToArray());
    }

    [TestMethod]
    public void PaneReadRequestRejectsEveryUnboundedLineValue()
    {
        _ = Assert.ThrowsExactly<ArgumentOutOfRangeException>(() =>
            HerdrProtocolJsonCodec.CreateBoundedPaneReadRequest("request-low", "pane-1", 0));
        _ = Assert.ThrowsExactly<ArgumentOutOfRangeException>(() =>
            HerdrProtocolJsonCodec.CreateBoundedPaneReadRequest("request-high", "pane-1", 201));
    }

    [TestMethod]
    public void PaneReadResponseRequiresMatchingPaneSourceAndFormat()
    {
        const string response =
            """
            {"id":"request-pane-response","result":{"type":"pane_read","read":{"pane_id":"pane-1","workspace_id":"workspace-1","tab_id":"tab-1","source":"recent_unwrapped","format":"text","text":"build complete","revision":42,"truncated":false}}}
            """;

        var read = HerdrProtocolJsonCodec.ParseBoundedPaneReadResponse(
            response,
            "request-pane-response",
            "pane-1");

        Assert.AreEqual("pane-1", read.PaneId);
        Assert.AreEqual("recent_unwrapped", read.Source);
        Assert.AreEqual("text", read.Format);
        Assert.AreEqual("build complete", read.Text);
        Assert.AreEqual((ulong)42, read.Revision);
        Assert.IsFalse(read.Truncated);

        var wrongSource = response.Replace("recent_unwrapped", "visible", StringComparison.Ordinal);
        var exception = Assert.ThrowsExactly<HerdrProtocolException>(() =>
            HerdrProtocolJsonCodec.ParseBoundedPaneReadResponse(
                wrongSource,
                "request-pane-response",
                "pane-1"));
        StringAssert.Contains(exception.Message, "expected 'recent_unwrapped'");
    }

    [TestMethod]
    public void PaneProcessInfoPreservesReportedPidSourceMetadata()
    {
        const string response =
            """
            {"id":"request-process","result":{"type":"pane_process_info","process_info":{"pane_id":"pane-1","shell_pid":900,"foreground_process_group_id":901,"tty":null,"foreground_processes":[{"pid":901,"name":"dotnet","argv0":"dotnet","argv":["dotnet","build"],"cmdline":"dotnet build","cwd":"Z:\\HerdrOps"}]}}}
            """;

        var info = HerdrProtocolJsonCodec.ParsePaneProcessInfoResponse(
            response,
            "request-process",
            "pane-1");

        Assert.AreEqual("pane-1", info.PaneId);
        Assert.AreEqual((uint)900, info.ShellProcessId);
        Assert.AreEqual((uint)901, info.ForegroundProcessGroupId);
        Assert.HasCount(1, info.ForegroundProcesses);
        Assert.AreEqual((uint)901, info.ForegroundProcesses[0].ProcessId);
        Assert.AreEqual("dotnet build", info.ForegroundProcesses[0].CommandLine);
        CollectionAssert.AreEqual(
            new[] { "dotnet", "build" },
            info.ForegroundProcesses[0].Arguments!.ToArray());
    }

    internal static string CreateSnapshotResponse(string requestId, ulong revision) => $$"""
        {
          "id": "{{requestId}}",
          "result": {
            "type": "session_snapshot",
            "snapshot": {
              "version": "0.8.0-preview",
              "protocol": 19,
              "workspaces": [
                {
                  "workspace_id": "workspace-1",
                  "number": 1,
                  "label": "HerdrOps",
                  "focused": true,
                  "pane_count": 1,
                  "tab_count": 1,
                  "active_tab_id": "tab-1",
                  "agent_status": "working"
                }
              ],
              "tabs": [
                {
                  "tab_id": "tab-1",
                  "workspace_id": "workspace-1",
                  "number": 1,
                  "label": "Core",
                  "focused": true,
                  "pane_count": 1,
                  "agent_status": "working"
                }
              ],
              "panes": [
                {
                  "pane_id": "pane-1",
                  "terminal_id": "terminal-1",
                  "workspace_id": "workspace-1",
                  "tab_id": "tab-1",
                  "focused": true,
                  "agent_status": "working",
                  "revision": {{revision}},
                  "agent": "codex",
                  "display_agent": "Codex",
                  "title": "Worker",
                  "cwd": "Z:\\HerdrOps",
                  "foreground_cwd": "Z:\\HerdrOps",
                  "terminal_title": "Codex"
                }
              ],
              "layouts": [],
              "agents": [
                {
                  "terminal_id": "terminal-1",
                  "workspace_id": "workspace-1",
                  "tab_id": "tab-1",
                  "pane_id": "pane-1",
                  "focused": true,
                  "agent_status": "working",
                  "revision": {{revision}},
                  "state_change_seq": 3,
                  "agent": "codex",
                  "display_agent": "Codex",
                  "name": "Worker 01",
                  "title": "Worker",
                  "cwd": "Z:\\HerdrOps",
                  "foreground_cwd": "Z:\\HerdrOps",
                  "terminal_title": "Codex",
                  "interactive_ready": true,
                  "launch_pending": false,
                  "screen_detection_skipped": false
                }
              ],
              "focused_workspace_id": "workspace-1",
              "focused_tab_id": "tab-1",
              "focused_pane_id": "pane-1"
            }
          }
        }
        """;
}
