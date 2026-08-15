using System.Buffers.Binary;
using System.Globalization;
using System.Security.Cryptography;
using System.Text;

namespace HerdrOps.Domain.Assignments;

public sealed record AssignmentDelegationTask(
    string TaskId,
    string Summary,
    AssignmentTaskStatus Status,
    string CurrentAssigneeId,
    string? CurrentAssigneeRole,
    int ProgressPercent,
    int DeviationCount,
    int EvidenceCount,
    int HandoffCount,
    DateTimeOffset CreatedUtc,
    DateTimeOffset LastTransitionUtc,
    long LastSequence,
    string StateSha256,
    string ProvenanceEventSha256);

public sealed record AssignmentDelegationNode(
    string ActorId,
    string ActorRole,
    IReadOnlyList<string> TaskIds,
    bool IsCurrentAssignee,
    Guid LastEventId,
    long LastSequence,
    DateTimeOffset LastObservedUtc,
    string ProvenanceEventSha256);

public sealed record AssignmentDelegationEdge(
    Guid RelationshipId,
    AssignmentRelationshipKind RelationshipKind,
    string TaskId,
    string FromActorId,
    string FromActorRole,
    string ToActorId,
    Guid EventId,
    long Sequence,
    DateTimeOffset AcceptedUtc,
    string ProvenanceEventSha256,
    string RelationshipSha256);

public sealed record AssignmentDelegationTimelineEntry(
    Guid EventId,
    AssignmentLifecycleEventKind EventKind,
    AssignmentLifecycleDisposition Disposition,
    string TaskId,
    string ActorId,
    string ActorRole,
    string? TargetAgentId,
    string Summary,
    int? ProgressPercent,
    string? DeviationReason,
    string? EvidenceReference,
    string? EvidenceSha256,
    string? HandoffNote,
    long Sequence,
    DateTimeOffset OccurredUtc,
    DateTimeOffset AcceptedUtc,
    string AuditCode,
    string LifecycleEventSha256,
    string AuditSha256);

public sealed record AssignmentDelegationGraph(
    int ContractVersion,
    IReadOnlyList<AssignmentDelegationTask> Tasks,
    IReadOnlyList<AssignmentDelegationNode> Nodes,
    IReadOnlyList<AssignmentDelegationEdge> Edges,
    IReadOnlyList<AssignmentDelegationTimelineEntry> Timeline,
    AssignmentLifecycleDiagnostics Diagnostics,
    string SourceReplaySha256,
    string GraphSha256);

public static class AssignmentDelegationGraphProjector
{
    public static AssignmentDelegationGraph Create(AssignmentLifecycleReplayResult replay)
    {
        ArgumentNullException.ThrowIfNull(replay);
        if (replay.ContractVersion != AssignmentLifecycleContract.Version)
        {
            throw new AssignmentLifecycleContractException(
                $"Delegation graph contract version {replay.ContractVersion} is unsupported.");
        }

        var eventsById = ValidateReplayProvenance(replay);
        var tasks = replay.CurrentTasks
            .OrderBy(item => item.State.TaskId, StringComparer.Ordinal)
            .Select(CreateTask)
            .ToArray();
        var edges = replay.Relationships
            .OrderBy(item => item.Sequence)
            .ThenBy(item => item.RelationshipId)
            .Select(item => new AssignmentDelegationEdge(
                item.RelationshipId,
                item.RelationshipKind,
                item.TaskId,
                item.FromActorId,
                item.FromActorRole,
                item.ToActorId,
                item.EventId,
                item.Sequence,
                item.AcceptedUtc,
                item.ProvenanceEventSha256,
                item.RelationshipSha256))
            .ToArray();
        var timeline = replay.Steps
            .OrderBy(item => item.NormalizedEvent.Event.Sequence)
            .Select(CreateTimelineEntry)
            .ToArray();
        var nodes = CreateNodes(replay, eventsById, tasks);
        var graphSha256 = ComputeGraphSha256(
            replay.ContractVersion,
            tasks,
            nodes,
            edges,
            timeline,
            replay.Diagnostics,
            replay.ResultSha256);
        return new AssignmentDelegationGraph(
            replay.ContractVersion,
            tasks,
            nodes,
            edges,
            timeline,
            replay.Diagnostics,
            replay.ResultSha256,
            graphSha256);
    }

    private static IReadOnlyDictionary<Guid, NormalizedAssignmentLifecycleEvent> ValidateReplayProvenance(
        AssignmentLifecycleReplayResult replay)
    {
        var eventsById = new Dictionary<Guid, NormalizedAssignmentLifecycleEvent>();
        foreach (var step in replay.Steps)
        {
            var normalized = AssignmentLifecycleContract.NormalizeAndValidate(
                step.NormalizedEvent.Event);
            if (normalized != step.NormalizedEvent ||
                !eventsById.TryAdd(normalized.Event.EventId, normalized))
            {
                throw new AssignmentLifecycleContractException(
                    "The delegation graph replay contains duplicate or invalid event provenance.");
            }

            AssignmentLifecycleContract.ValidateAuditEntry(step.Audit);
            if (step.Audit.EventId != normalized.Event.EventId ||
                !string.Equals(
                    step.Audit.LifecycleEventSha256,
                    normalized.LifecycleEventSha256,
                    StringComparison.Ordinal))
            {
                throw new AssignmentLifecycleContractException(
                    "The delegation graph replay audit does not match its lifecycle event.");
            }
        }

        foreach (var task in replay.CurrentTasks)
        {
            AssignmentLifecycleContract.ValidateTaskSnapshot(task);
            if (!eventsById.ContainsKey(task.State.LastEventId) ||
                !eventsById.TryGetValue(task.State.Contract.AssignmentEventId, out var assignmentEvent) ||
                !string.Equals(
                    assignmentEvent.LifecycleEventSha256,
                    task.State.Contract.ProvenanceEventSha256,
                    StringComparison.Ordinal))
            {
                throw new AssignmentLifecycleContractException(
                    $"Task '{task.State.TaskId}' has missing graph provenance.");
            }
        }

        foreach (var relationship in replay.Relationships)
        {
            if (!eventsById.TryGetValue(relationship.EventId, out var normalized))
            {
                throw new AssignmentLifecycleContractException(
                    $"Relationship '{relationship.RelationshipId:D}' has no lifecycle event.");
            }

            AssignmentLifecycleContract.ValidateRelationship(relationship, normalized);
        }

        foreach (var observation in replay.RoleHistory)
        {
            if (!eventsById.TryGetValue(observation.EventId, out var normalized))
            {
                throw new AssignmentLifecycleContractException(
                    $"Role observation '{observation.EventId:D}' has no lifecycle event.");
            }

            AssignmentLifecycleContract.ValidateRoleObservation(observation, normalized);
        }

        foreach (var currentRole in replay.CurrentRoles)
        {
            var observation = replay.RoleHistory.SingleOrDefault(item =>
                item.EventId == currentRole.EventId &&
                string.Equals(item.ActorId, currentRole.ActorId, StringComparison.Ordinal));
            if (observation is null)
            {
                throw new AssignmentLifecycleContractException(
                    $"Current role for '{currentRole.ActorId}' has no provenance observation.");
            }

            AssignmentLifecycleContract.ValidateCurrentRole(currentRole, observation);
        }

        return eventsById;
    }

    private static AssignmentDelegationTask CreateTask(AssignmentTaskSnapshot snapshot)
    {
        var state = snapshot.State;
        return new AssignmentDelegationTask(
            state.TaskId,
            state.Contract.Summary,
            state.Status,
            state.CurrentAssigneeId,
            state.CurrentAssigneeRole,
            state.ProgressPercent,
            state.DeviationCount,
            state.EvidenceCount,
            state.HandoffCount,
            state.Contract.CreatedUtc,
            state.LastTransitionUtc,
            state.LastSequence,
            snapshot.StateSha256,
            state.Contract.ProvenanceEventSha256);
    }

    private static AssignmentDelegationTimelineEntry CreateTimelineEntry(
        AssignmentLifecycleStep step)
    {
        var lifecycleEvent = step.NormalizedEvent.Event;
        return new AssignmentDelegationTimelineEntry(
            lifecycleEvent.EventId,
            lifecycleEvent.EventKind,
            step.Audit.Disposition,
            lifecycleEvent.TaskId,
            lifecycleEvent.ActorId,
            lifecycleEvent.ActorRole,
            lifecycleEvent.TargetAgentId,
            lifecycleEvent.Summary,
            lifecycleEvent.ProgressPercent,
            lifecycleEvent.DeviationReason,
            lifecycleEvent.EvidenceReference,
            lifecycleEvent.EvidenceSha256,
            lifecycleEvent.HandoffNote,
            lifecycleEvent.Sequence,
            lifecycleEvent.OccurredUtc,
            lifecycleEvent.AcceptedUtc,
            step.Audit.Code,
            step.NormalizedEvent.LifecycleEventSha256,
            step.Audit.AuditSha256);
    }

    private static AssignmentDelegationNode[] CreateNodes(
        AssignmentLifecycleReplayResult replay,
        IReadOnlyDictionary<Guid, NormalizedAssignmentLifecycleEvent> eventsById,
        IReadOnlyList<AssignmentDelegationTask> tasks)
    {
        var actors = new HashSet<string>(StringComparer.Ordinal);
        foreach (var lifecycleEvent in eventsById.Values.Select(item => item.Event))
        {
            actors.Add(lifecycleEvent.ActorId);
            if (lifecycleEvent.TargetAgentId is { } target)
            {
                actors.Add(target);
            }
        }

        return actors
            .Select(actorId =>
            {
                var observations = replay.RoleHistory
                    .Where(item => string.Equals(item.ActorId, actorId, StringComparison.Ordinal))
                    .OrderBy(item => item.Sequence)
                    .ToArray();
                var actorEvents = eventsById.Values
                    .Select(item => item.Event)
                    .Where(item =>
                        string.Equals(item.ActorId, actorId, StringComparison.Ordinal) ||
                        string.Equals(item.TargetAgentId, actorId, StringComparison.Ordinal))
                    .OrderBy(item => item.Sequence)
                    .ToArray();
                var lastEvent = actorEvents[^1];
                var normalizedLastEvent = eventsById[lastEvent.EventId];
                var taskIds = actorEvents
                    .Select(item => item.TaskId)
                    .Distinct(StringComparer.Ordinal)
                    .Order(StringComparer.Ordinal)
                    .ToArray();
                var role = observations.Length == 0
                    ? "Unknown"
                    : observations[^1].ActorRole;
                var isCurrentAssignee = tasks.Any(task =>
                    string.Equals(task.CurrentAssigneeId, actorId, StringComparison.Ordinal));
                return new AssignmentDelegationNode(
                    actorId,
                    role,
                    taskIds,
                    isCurrentAssignee,
                    lastEvent.EventId,
                    lastEvent.Sequence,
                    lastEvent.AcceptedUtc,
                    normalizedLastEvent.LifecycleEventSha256);
            })
            .OrderByDescending(item => item.IsCurrentAssignee)
            .ThenBy(item => item.ActorRole, StringComparer.Ordinal)
            .ThenBy(item => item.ActorId, StringComparer.Ordinal)
            .ToArray();
    }

    private static string ComputeGraphSha256(
        int contractVersion,
        IReadOnlyList<AssignmentDelegationTask> tasks,
        IReadOnlyList<AssignmentDelegationNode> nodes,
        IReadOnlyList<AssignmentDelegationEdge> edges,
        IReadOnlyList<AssignmentDelegationTimelineEntry> timeline,
        AssignmentLifecycleDiagnostics diagnostics,
        string replaySha256)
    {
        using var writer = new GraphHashWriter();
        writer.Write("HerdrOps.AssignmentDelegationGraph.v1");
        writer.Write(contractVersion);
        writer.Write(replaySha256);
        writer.Write(tasks.Count);
        foreach (var task in tasks)
        {
            writer.Write(task.TaskId);
            writer.Write(task.Summary);
            writer.Write((int)task.Status);
            writer.Write(task.CurrentAssigneeId);
            writer.Write(task.CurrentAssigneeRole);
            writer.Write(task.ProgressPercent);
            writer.Write(task.DeviationCount);
            writer.Write(task.EvidenceCount);
            writer.Write(task.HandoffCount);
            writer.Write(task.CreatedUtc);
            writer.Write(task.LastTransitionUtc);
            writer.Write(task.LastSequence);
            writer.Write(task.StateSha256);
            writer.Write(task.ProvenanceEventSha256);
        }

        writer.Write(nodes.Count);
        foreach (var node in nodes)
        {
            writer.Write(node.ActorId);
            writer.Write(node.ActorRole);
            writer.Write(node.TaskIds.Count);
            foreach (var taskId in node.TaskIds)
            {
                writer.Write(taskId);
            }

            writer.Write(node.IsCurrentAssignee);
            writer.Write(node.LastEventId);
            writer.Write(node.LastSequence);
            writer.Write(node.LastObservedUtc);
            writer.Write(node.ProvenanceEventSha256);
        }

        writer.Write(edges.Count);
        foreach (var edge in edges)
        {
            writer.Write(edge.RelationshipId);
            writer.Write((int)edge.RelationshipKind);
            writer.Write(edge.TaskId);
            writer.Write(edge.FromActorId);
            writer.Write(edge.FromActorRole);
            writer.Write(edge.ToActorId);
            writer.Write(edge.EventId);
            writer.Write(edge.Sequence);
            writer.Write(edge.AcceptedUtc);
            writer.Write(edge.ProvenanceEventSha256);
            writer.Write(edge.RelationshipSha256);
        }

        writer.Write(timeline.Count);
        foreach (var entry in timeline)
        {
            writer.Write(entry.EventId);
            writer.Write((int)entry.EventKind);
            writer.Write((int)entry.Disposition);
            writer.Write(entry.TaskId);
            writer.Write(entry.ActorId);
            writer.Write(entry.ActorRole);
            writer.Write(entry.TargetAgentId);
            writer.Write(entry.Summary);
            writer.Write(entry.ProgressPercent ?? -1);
            writer.Write(entry.DeviationReason);
            writer.Write(entry.EvidenceReference);
            writer.Write(entry.EvidenceSha256);
            writer.Write(entry.HandoffNote);
            writer.Write(entry.Sequence);
            writer.Write(entry.OccurredUtc);
            writer.Write(entry.AcceptedUtc);
            writer.Write(entry.AuditCode);
            writer.Write(entry.LifecycleEventSha256);
            writer.Write(entry.AuditSha256);
        }

        writer.Write(diagnostics.ProcessedEventCount);
        writer.Write(diagnostics.AppliedEventCount);
        writer.Write(diagnostics.OrphanEventCount);
        writer.Write(diagnostics.DuplicateHandoffCount);
        writer.Write(diagnostics.LastSequence);
        return writer.Finish();
    }

    private sealed class GraphHashWriter : IDisposable
    {
        private readonly IncrementalHash _hash = IncrementalHash.CreateHash(HashAlgorithmName.SHA256);
        private bool _finished;

        public void Write(string? value)
        {
            if (value is null)
            {
                WriteLength(-1);
                return;
            }

            var bytes = Encoding.UTF8.GetBytes(value);
            WriteLength(bytes.Length);
            _hash.AppendData(bytes);
        }

        public void Write(int value)
        {
            Span<byte> bytes = stackalloc byte[sizeof(int)];
            BinaryPrimitives.WriteInt32LittleEndian(bytes, value);
            _hash.AppendData(bytes);
        }

        public void Write(long value)
        {
            Span<byte> bytes = stackalloc byte[sizeof(long)];
            BinaryPrimitives.WriteInt64LittleEndian(bytes, value);
            _hash.AppendData(bytes);
        }

        public void Write(bool value) => Write(value ? 1 : 0);

        public void Write(Guid value) => Write(value.ToString("D"));

        public void Write(DateTimeOffset value) =>
            Write(value.ToUniversalTime().ToString("O", CultureInfo.InvariantCulture));

        public string Finish()
        {
            ObjectDisposedException.ThrowIf(_finished, this);
            _finished = true;
            return Convert.ToHexString(_hash.GetHashAndReset());
        }

        public void Dispose()
        {
            _finished = true;
            _hash.Dispose();
        }

        private void WriteLength(int value)
        {
            Span<byte> length = stackalloc byte[sizeof(int)];
            BinaryPrimitives.WriteInt32LittleEndian(length, value);
            _hash.AppendData(length);
        }
    }
}
