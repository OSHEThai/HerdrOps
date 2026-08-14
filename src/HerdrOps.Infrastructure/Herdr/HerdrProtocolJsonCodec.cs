using System.Buffers;
using System.Text.Json;
using HerdrOps.Contracts;
using HerdrOps.Domain.Herdr;

namespace HerdrOps.Infrastructure.Herdr;

public static class HerdrProtocolJsonCodec
{
    private static readonly string[] GeneralSubscriptionTypes =
    [
        "workspace.created",
        "workspace.updated",
        "workspace.metadata_updated",
        "workspace.renamed",
        "workspace.moved",
        "workspace.reordered",
        "workspace.closed",
        "workspace.focused",
        "worktree.created",
        "worktree.opened",
        "worktree.removed",
        "tab.created",
        "tab.closed",
        "tab.focused",
        "tab.renamed",
        "tab.moved",
        "pane.created",
        "pane.closed",
        "pane.updated",
        "pane.focused",
        "pane.moved",
        "pane.exited",
        "pane.agent_detected",
        "layout.updated",
    ];

    private static readonly JsonDocumentOptions DocumentOptions = new()
    {
        AllowTrailingCommas = false,
        CommentHandling = JsonCommentHandling.Disallow,
        MaxDepth = 64,
    };

    public static byte[] CreateSnapshotRequest(string requestId)
    {
        ValidateRequestId(requestId);
        var buffer = new ArrayBufferWriter<byte>();
        using var writer = new Utf8JsonWriter(buffer);
        writer.WriteStartObject();
        writer.WriteString("id", requestId);
        writer.WriteString("method", "session.snapshot");
        writer.WriteStartObject("params");
        writer.WriteEndObject();
        writer.WriteEndObject();
        writer.Flush();
        return buffer.WrittenSpan.ToArray();
    }

    public static byte[] CreateSubscriptionRequest(
        string requestId,
        IReadOnlyCollection<string> paneIds)
    {
        ValidateRequestId(requestId);
        ArgumentNullException.ThrowIfNull(paneIds);
        var normalizedPaneIds = paneIds
            .Select(ValidateEntityId)
            .Distinct(StringComparer.Ordinal)
            .Order(StringComparer.Ordinal)
            .ToArray();

        var buffer = new ArrayBufferWriter<byte>();
        using var writer = new Utf8JsonWriter(buffer);
        writer.WriteStartObject();
        writer.WriteString("id", requestId);
        writer.WriteString("method", "events.subscribe");
        writer.WriteStartObject("params");
        writer.WriteStartArray("subscriptions");
        foreach (var subscriptionType in GeneralSubscriptionTypes)
        {
            writer.WriteStartObject();
            writer.WriteString("type", subscriptionType);
            writer.WriteEndObject();
        }

        foreach (var paneId in normalizedPaneIds)
        {
            writer.WriteStartObject();
            writer.WriteString("type", "pane.agent_status_changed");
            writer.WriteString("pane_id", paneId);
            writer.WriteEndObject();
        }

        writer.WriteEndArray();
        writer.WriteEndObject();
        writer.WriteEndObject();
        writer.Flush();
        return buffer.WrittenSpan.ToArray();
    }

    public static HerdrSessionSnapshot ParseSnapshotResponse(string json, string expectedRequestId)
    {
        ValidateRequestId(expectedRequestId);
        using var document = ParseDocument(json);
        var root = RequireObject(document.RootElement, "response");
        ValidateResponseEnvelope(root, expectedRequestId);
        var result = RequireObject(GetRequiredProperty(root, "result"), "result");
        RequireExactString(result, "type", "session_snapshot");
        return ParseSnapshot(RequireObject(GetRequiredProperty(result, "snapshot"), "snapshot"));
    }

    public static void ValidateSubscriptionStarted(string json, string expectedRequestId)
    {
        ValidateRequestId(expectedRequestId);
        using var document = ParseDocument(json);
        var root = RequireObject(document.RootElement, "response");
        ValidateResponseEnvelope(root, expectedRequestId);
        var result = RequireObject(GetRequiredProperty(root, "result"), "result");
        RequireExactString(result, "type", "subscription_started");
    }

    public static HerdrStateEvent ParseEvent(string json)
    {
        using var document = ParseDocument(json);
        var root = RequireObject(document.RootElement, "event envelope");
        var eventName = GetRequiredString(root, "event", allowEmpty: false);
        var data = RequireObject(GetRequiredProperty(root, "data"), "event data");
        var isFilteredSubscriptionEvent = eventName.Contains('.', StringComparison.Ordinal);
        if (!data.TryGetProperty("type", out var dataType))
        {
            if (!isFilteredSubscriptionEvent)
            {
                throw new HerdrProtocolException(
                    $"General Herdr event '{eventName}' is missing required data.type.");
            }
        }
        else
        {
            var embeddedEventName = GetString(dataType, "event data type", allowEmpty: false);
            if (!string.Equals(embeddedEventName, eventName, StringComparison.Ordinal))
            {
                throw new HerdrProtocolException(
                    $"Event envelope '{eventName}' disagrees with data type '{embeddedEventName}'.");
            }
        }

        return eventName switch
        {
            "workspace_created" or "workspace_updated" or "workspace_metadata_updated" =>
                new HerdrWorkspaceChangedEvent(
                    eventName,
                    ParseWorkspace(RequireObject(GetRequiredProperty(data, "workspace"), "workspace"))),
            "workspace_closed" => new HerdrWorkspaceRemovedEvent(
                eventName,
                GetRequiredString(data, "workspace_id", allowEmpty: false)),
            "workspace_renamed" => new HerdrWorkspaceRenamedEvent(
                eventName,
                GetRequiredString(data, "workspace_id", allowEmpty: false),
                GetRequiredString(data, "label", allowEmpty: true)),
            "workspace_moved" or "workspace_reordered" => new HerdrWorkspaceCollectionChangedEvent(
                eventName,
                ParseArray(data, "workspaces", ParseWorkspace)),
            "workspace_focused" => new HerdrWorkspaceFocusedEvent(
                eventName,
                GetRequiredString(data, "workspace_id", allowEmpty: false)),
            "worktree_created" or "worktree_opened" => new HerdrWorkspaceChangedEvent(
                eventName,
                ParseWorkspace(RequireObject(GetRequiredProperty(data, "workspace"), "workspace"))),
            "worktree_removed" => ParseWorktreeRemoved(eventName, data),
            "tab_created" => new HerdrTabChangedEvent(
                eventName,
                ParseTab(RequireObject(GetRequiredProperty(data, "tab"), "tab"))),
            "tab_closed" => new HerdrTabRemovedEvent(
                eventName,
                GetRequiredString(data, "workspace_id", allowEmpty: false),
                GetRequiredString(data, "tab_id", allowEmpty: false)),
            "tab_renamed" => new HerdrTabRenamedEvent(
                eventName,
                GetRequiredString(data, "workspace_id", allowEmpty: false),
                GetRequiredString(data, "tab_id", allowEmpty: false),
                GetRequiredString(data, "label", allowEmpty: true)),
            "tab_moved" => new HerdrTabCollectionChangedEvent(
                eventName,
                ParseArray(data, "tabs", ParseTab)),
            "tab_focused" => new HerdrTabFocusedEvent(
                eventName,
                GetRequiredString(data, "workspace_id", allowEmpty: false),
                GetRequiredString(data, "tab_id", allowEmpty: false)),
            "pane_created" or "pane_updated" or "pane_moved" => new HerdrPaneChangedEvent(
                eventName,
                ParsePane(RequireObject(GetRequiredProperty(data, "pane"), "pane"))),
            "pane_closed" => new HerdrPaneRemovedEvent(
                eventName,
                GetRequiredString(data, "workspace_id", allowEmpty: false),
                GetRequiredString(data, "pane_id", allowEmpty: false)),
            "pane_focused" => new HerdrPaneFocusedEvent(
                eventName,
                GetRequiredString(data, "workspace_id", allowEmpty: false),
                GetRequiredString(data, "pane_id", allowEmpty: false)),
            "pane_output_changed" => new HerdrPaneRevisionChangedEvent(
                eventName,
                GetRequiredString(data, "workspace_id", allowEmpty: false),
                GetRequiredString(data, "pane_id", allowEmpty: false),
                GetRequiredUInt64(data, "revision")),
            "pane_agent_status_changed" or "pane.agent_status_changed" =>
                ParsePaneAgentStatusChanged(eventName, data),
            "pane_exited" or "pane_agent_detected" => new HerdrReconciliationRequestedEvent(
                eventName,
                $"Event '{eventName}' does not carry a complete pane and agent state."),
            "layout_updated" or "pane.output_matched" or "pane.scroll_changed" =>
                new HerdrNoStateChangeEvent(eventName),
            _ => new HerdrReconciliationRequestedEvent(
                eventName,
                $"Unrecognized Herdr event '{eventName}' requires a fresh snapshot."),
        };
    }

    private static HerdrStateEvent ParseWorktreeRemoved(string eventName, JsonElement data)
    {
        if (!data.TryGetProperty("workspace", out var workspace) || workspace.ValueKind == JsonValueKind.Null)
        {
            return new HerdrNoStateChangeEvent(eventName);
        }

        return new HerdrWorkspaceChangedEvent(
            eventName,
            ParseWorkspace(RequireObject(workspace, "workspace")));
    }

    private static HerdrPaneAgentStatusChangedEvent ParsePaneAgentStatusChanged(
        string eventName,
        JsonElement data) => new(
            eventName,
            GetRequiredString(data, "workspace_id", allowEmpty: false),
            GetRequiredString(data, "pane_id", allowEmpty: false),
            ParseAgentStatus(GetRequiredProperty(data, "agent_status"), "agent_status"),
            GetOptionalString(data, "agent"),
            GetOptionalString(data, "display_agent"),
            GetOptionalString(data, "title"));

    private static HerdrSessionSnapshot ParseSnapshot(JsonElement snapshot)
    {
        var protocol = GetRequiredInt32(snapshot, "protocol");
        if (protocol != HerdrBundledSchemaContractV19.Protocol)
        {
            throw new HerdrProtocolException(
                $"Herdr snapshot protocol {protocol} is not the admitted protocol {HerdrBundledSchemaContractV19.Protocol}.");
        }

        RequireArray(snapshot, "layouts");

        return new HerdrSessionSnapshot(
            GetRequiredString(snapshot, "version", allowEmpty: false),
            protocol,
            ParseArray(snapshot, "workspaces", ParseWorkspace),
            ParseArray(snapshot, "tabs", ParseTab),
            ParseArray(snapshot, "panes", ParsePane),
            ParseArray(snapshot, "agents", ParseAgent),
            GetOptionalString(snapshot, "focused_workspace_id"),
            GetOptionalString(snapshot, "focused_tab_id"),
            GetOptionalString(snapshot, "focused_pane_id"));
    }

    private static HerdrWorkspaceSnapshot ParseWorkspace(JsonElement value) => new(
        GetRequiredString(value, "workspace_id", allowEmpty: false),
        GetRequiredInt32(value, "number"),
        GetRequiredString(value, "label", allowEmpty: true),
        GetRequiredBoolean(value, "focused"),
        GetRequiredInt32(value, "pane_count"),
        GetRequiredInt32(value, "tab_count"),
        GetRequiredString(value, "active_tab_id", allowEmpty: true),
        ParseAgentStatus(GetRequiredProperty(value, "agent_status"), "agent_status"));

    private static HerdrTabSnapshot ParseTab(JsonElement value) => new(
        GetRequiredString(value, "tab_id", allowEmpty: false),
        GetRequiredString(value, "workspace_id", allowEmpty: false),
        GetRequiredInt32(value, "number"),
        GetRequiredString(value, "label", allowEmpty: true),
        GetRequiredBoolean(value, "focused"),
        GetRequiredInt32(value, "pane_count"),
        ParseAgentStatus(GetRequiredProperty(value, "agent_status"), "agent_status"));

    private static HerdrPaneSnapshot ParsePane(JsonElement value) => new(
        GetRequiredString(value, "pane_id", allowEmpty: false),
        GetRequiredString(value, "terminal_id", allowEmpty: false),
        GetRequiredString(value, "workspace_id", allowEmpty: false),
        GetRequiredString(value, "tab_id", allowEmpty: false),
        GetRequiredBoolean(value, "focused"),
        ParseAgentStatus(GetRequiredProperty(value, "agent_status"), "agent_status"),
        GetRequiredUInt64(value, "revision"),
        GetOptionalString(value, "agent"),
        GetOptionalString(value, "display_agent"),
        GetOptionalString(value, "title"),
        GetOptionalString(value, "cwd"),
        GetOptionalString(value, "foreground_cwd"),
        GetOptionalString(value, "terminal_title"));

    private static HerdrAgentSnapshot ParseAgent(JsonElement value) => new(
        GetRequiredString(value, "terminal_id", allowEmpty: false),
        GetRequiredString(value, "workspace_id", allowEmpty: false),
        GetRequiredString(value, "tab_id", allowEmpty: false),
        GetRequiredString(value, "pane_id", allowEmpty: false),
        GetRequiredBoolean(value, "focused"),
        ParseAgentStatus(GetRequiredProperty(value, "agent_status"), "agent_status"),
        GetRequiredUInt64(value, "revision"),
        GetOptionalUInt64(value, "state_change_seq") ?? 0,
        GetOptionalString(value, "agent"),
        GetOptionalString(value, "display_agent"),
        GetOptionalString(value, "name"),
        GetOptionalString(value, "title"),
        GetOptionalString(value, "cwd"),
        GetOptionalString(value, "foreground_cwd"),
        GetOptionalString(value, "terminal_title"),
        GetOptionalBoolean(value, "interactive_ready"),
        GetOptionalBoolean(value, "launch_pending"),
        GetOptionalBoolean(value, "screen_detection_skipped"));

    private static void ValidateResponseEnvelope(JsonElement root, string expectedRequestId)
    {
        var actualRequestId = GetRequiredString(root, "id", allowEmpty: false);
        if (!string.Equals(actualRequestId, expectedRequestId, StringComparison.Ordinal))
        {
            throw new HerdrProtocolException(
                $"Herdr response id '{actualRequestId}' did not match request id '{expectedRequestId}'.");
        }

        if (!root.TryGetProperty("error", out var error))
        {
            return;
        }

        var errorObject = RequireObject(error, "error");
        throw new HerdrApiErrorException(
            GetRequiredString(errorObject, "code", allowEmpty: false),
            GetRequiredString(errorObject, "message", allowEmpty: true));
    }

    private static JsonDocument ParseDocument(string json)
    {
        if (string.IsNullOrWhiteSpace(json))
        {
            throw new HerdrProtocolException("Herdr returned an empty JSON document.");
        }

        try
        {
            return JsonDocument.Parse(json, DocumentOptions);
        }
        catch (JsonException exception)
        {
            throw new HerdrProtocolException("Herdr returned malformed JSON.", exception);
        }
    }

    private static JsonElement RequireObject(JsonElement value, string description)
    {
        if (value.ValueKind != JsonValueKind.Object)
        {
            throw new HerdrProtocolException($"Herdr {description} must be a JSON object.");
        }

        return value;
    }

    private static JsonElement GetRequiredProperty(JsonElement value, string propertyName)
    {
        if (!value.TryGetProperty(propertyName, out var property))
        {
            throw new HerdrProtocolException($"Herdr JSON is missing required property '{propertyName}'.");
        }

        return property;
    }

    private static string GetRequiredString(
        JsonElement value,
        string propertyName,
        bool allowEmpty) =>
        GetString(GetRequiredProperty(value, propertyName), propertyName, allowEmpty);

    private static string GetString(JsonElement value, string description, bool allowEmpty)
    {
        if (value.ValueKind != JsonValueKind.String)
        {
            throw new HerdrProtocolException($"Herdr property '{description}' must be a string.");
        }

        var result = value.GetString()!;
        if (!allowEmpty && string.IsNullOrWhiteSpace(result))
        {
            throw new HerdrProtocolException($"Herdr property '{description}' must not be empty.");
        }

        return result;
    }

    private static string? GetOptionalString(JsonElement value, string propertyName)
    {
        if (!value.TryGetProperty(propertyName, out var property) || property.ValueKind == JsonValueKind.Null)
        {
            return null;
        }

        return GetString(property, propertyName, allowEmpty: true);
    }

    private static int GetRequiredInt32(JsonElement value, string propertyName)
    {
        var property = GetRequiredProperty(value, propertyName);
        if (property.ValueKind != JsonValueKind.Number || !property.TryGetInt32(out var result))
        {
            throw new HerdrProtocolException($"Herdr property '{propertyName}' must be a 32-bit integer.");
        }

        return result;
    }

    private static ulong GetRequiredUInt64(JsonElement value, string propertyName)
    {
        var property = GetRequiredProperty(value, propertyName);
        if (property.ValueKind != JsonValueKind.Number || !property.TryGetUInt64(out var result))
        {
            throw new HerdrProtocolException($"Herdr property '{propertyName}' must be an unsigned integer.");
        }

        return result;
    }

    private static ulong? GetOptionalUInt64(JsonElement value, string propertyName)
    {
        if (!value.TryGetProperty(propertyName, out var property) || property.ValueKind == JsonValueKind.Null)
        {
            return null;
        }

        if (property.ValueKind != JsonValueKind.Number || !property.TryGetUInt64(out var result))
        {
            throw new HerdrProtocolException($"Herdr property '{propertyName}' must be an unsigned integer.");
        }

        return result;
    }

    private static bool GetRequiredBoolean(JsonElement value, string propertyName)
    {
        var property = GetRequiredProperty(value, propertyName);
        return property.ValueKind switch
        {
            JsonValueKind.True => true,
            JsonValueKind.False => false,
            _ => throw new HerdrProtocolException($"Herdr property '{propertyName}' must be boolean."),
        };
    }

    private static bool? GetOptionalBoolean(JsonElement value, string propertyName)
    {
        if (!value.TryGetProperty(propertyName, out var property) || property.ValueKind == JsonValueKind.Null)
        {
            return null;
        }

        return property.ValueKind switch
        {
            JsonValueKind.True => true,
            JsonValueKind.False => false,
            _ => throw new HerdrProtocolException($"Herdr property '{propertyName}' must be boolean."),
        };
    }

    private static HerdrAgentStatus ParseAgentStatus(JsonElement value, string description)
    {
        var status = GetString(value, description, allowEmpty: false);
        return status switch
        {
            "unknown" => HerdrAgentStatus.Unknown,
            "idle" => HerdrAgentStatus.Idle,
            "working" => HerdrAgentStatus.Working,
            "blocked" => HerdrAgentStatus.Blocked,
            "done" => HerdrAgentStatus.Done,
            _ => throw new HerdrProtocolException($"Unknown Herdr agent status '{status}'."),
        };
    }

    private static IReadOnlyList<T> ParseArray<T>(
        JsonElement value,
        string propertyName,
        Func<JsonElement, T> parser)
    {
        var property = GetRequiredProperty(value, propertyName);
        if (property.ValueKind != JsonValueKind.Array)
        {
            throw new HerdrProtocolException($"Herdr property '{propertyName}' must be an array.");
        }

        var result = new List<T>(property.GetArrayLength());
        foreach (var item in property.EnumerateArray())
        {
            result.Add(parser(RequireObject(item, $"{propertyName} item")));
        }

        return result.AsReadOnly();
    }

    private static JsonElement RequireArray(JsonElement value, string propertyName)
    {
        var property = GetRequiredProperty(value, propertyName);
        if (property.ValueKind != JsonValueKind.Array)
        {
            throw new HerdrProtocolException($"Herdr property '{propertyName}' must be an array.");
        }

        return property;
    }

    private static void RequireExactString(JsonElement value, string propertyName, string expected)
    {
        var actual = GetRequiredString(value, propertyName, allowEmpty: false);
        if (!string.Equals(actual, expected, StringComparison.Ordinal))
        {
            throw new HerdrProtocolException(
                $"Herdr property '{propertyName}' was '{actual}', expected '{expected}'.");
        }
    }

    private static void ValidateRequestId(string requestId)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(requestId);
        if (requestId.Length > 128 || requestId.IndexOfAny(['\r', '\n', '\0']) >= 0)
        {
            throw new ArgumentException("The Herdr request id is outside accepted bounds.", nameof(requestId));
        }
    }

    private static string ValidateEntityId(string entityId)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(entityId);
        if (entityId.Length > 1024 || entityId.IndexOf('\0') >= 0)
        {
            throw new ArgumentException("A Herdr entity id is outside accepted bounds.", nameof(entityId));
        }

        return entityId;
    }
}
