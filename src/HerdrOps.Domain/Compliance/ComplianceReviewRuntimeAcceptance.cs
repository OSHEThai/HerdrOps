using System.Security.Cryptography;
using System.Text;

namespace HerdrOps.Domain.Compliance;

public sealed record ComplianceReviewRuntimeAgentIdentity(
    string AgentId,
    string AgentRole);

public sealed record ComplianceReviewRuntimeAcceptanceCheck(
    string CheckId,
    bool Passed,
    string Detail,
    IReadOnlyList<Guid> SupportingEventIds);

public sealed record ComplianceReviewRuntimeTrace(
    int ContractVersion,
    DateTimeOffset StartedUtc,
    DateTimeOffset FinishedUtc,
    string EvidenceClassification,
    bool DurableReviewEnabled,
    IReadOnlyList<ComplianceReviewAuditEvent> AuditEvents,
    IReadOnlyList<ComplianceReviewIncident> Incidents,
    bool RetentionProtectedObserved,
    bool RestartConsistencyObserved);

public sealed record ComplianceReviewRuntimeAcceptanceResult(
    int ContractVersion,
    string IncidentId,
    bool CompleteLifecyclePassed,
    bool RoleDistinctReviewersPassed,
    bool RetentionProtectionPassed,
    bool RedactionCompliancePassed,
    bool RestartConsistencyPassed,
    IReadOnlyList<ComplianceReviewRuntimeAcceptanceCheck> Checks,
    string ReviewAuditSha256)
{
    public bool Passed => CompleteLifecyclePassed &&
                          RoleDistinctReviewersPassed &&
                          RetentionProtectionPassed &&
                          RedactionCompliancePassed &&
                          RestartConsistencyPassed;
}

public static class ComplianceReviewRuntimeAcceptance
{
    public const int ContractVersion = 1;

    public static ComplianceReviewRuntimeAcceptanceResult Analyze(
        IReadOnlyList<ComplianceReviewAuditEvent> auditEvents,
        IReadOnlyList<ComplianceReviewIncident> incidents,
        IReadOnlyList<ComplianceReviewRuntimeAgentIdentity> runningAgents,
        string incidentId,
        bool retentionProtectedObserved,
        bool restartConsistencyObserved)
    {
        ArgumentNullException.ThrowIfNull(auditEvents);
        ArgumentNullException.ThrowIfNull(incidents);
        ArgumentNullException.ThrowIfNull(runningAgents);
        ArgumentException.ThrowIfNullOrWhiteSpace(incidentId);

        var normalizedIncidentId = ComplianceReviewWorkflowContract.NormalizeIncidentId(incidentId);
        var agents = ValidateAgents(runningAgents);
        var checks = new List<ComplianceReviewRuntimeAcceptanceCheck>();

        var matchingIncident = incidents.FirstOrDefault(item =>
            string.Equals(
                item.IncidentId,
                normalizedIncidentId,
                StringComparison.Ordinal));

        if (matchingIncident is null)
        {
            checks.Add(new ComplianceReviewRuntimeAcceptanceCheck(
                "incident-registered",
                Passed: false,
                $"The target incident '{normalizedIncidentId}' was not found in the review trace.",
                Array.Empty<Guid>()));

            return new ComplianceReviewRuntimeAcceptanceResult(
                ContractVersion,
                normalizedIncidentId,
                CompleteLifecyclePassed: false,
                RoleDistinctReviewersPassed: false,
                RetentionProtectionPassed: false,
                RedactionCompliancePassed: false,
                RestartConsistencyPassed: false,
                checks,
                string.Empty);
        }

        checks.Add(new ComplianceReviewRuntimeAcceptanceCheck(
            "incident-registered",
            Passed: true,
            $"Target incident '{normalizedIncidentId}' registered for task '{matchingIncident.TaskId}' with subject '{matchingIncident.SubjectActorId}'.",
            Array.Empty<Guid>()));

        var events = auditEvents
            .Where(item => string.Equals(
                item.IncidentId,
                normalizedIncidentId,
                StringComparison.Ordinal))
            .OrderBy(item => item.Sequence)
            .ToArray();

        var supportingIds = events.Select(item => item.AuditEventId).ToArray();

        // 1. Complete Lifecycle Check
        var completeLifecyclePassed = ValidateCompleteLifecycle(
            matchingIncident,
            events,
            checks);

        // 2. Role-Distinct Reviewers Check
        var roleDistinctPassed = ValidateRoleDistinctReviewers(
            matchingIncident,
            events,
            agents,
            checks);

        // 3. Retention Protection Check
        var retentionPassed = ValidateRetentionProtection(
            matchingIncident,
            events,
            retentionProtectedObserved,
            checks);

        // 4. Redaction Compliance Check
        var redactionPassed = ValidateRedactionCompliance(
            matchingIncident,
            events,
            checks);

        // 5. Restart / Reconnect Consistency Check
        var restartPassed = ValidateRestartConsistency(
            matchingIncident,
            events,
            restartConsistencyObserved,
            checks);

        var reviewAuditSha256 = ComputeReviewAuditSha256(events);

        return new ComplianceReviewRuntimeAcceptanceResult(
            ContractVersion,
            normalizedIncidentId,
            completeLifecyclePassed,
            roleDistinctPassed,
            retentionPassed,
            redactionPassed,
            restartPassed,
            checks,
            reviewAuditSha256);
    }

    private static bool ValidateCompleteLifecycle(
        ComplianceReviewIncident incident,
        IReadOnlyList<ComplianceReviewAuditEvent> events,
        List<ComplianceReviewRuntimeAcceptanceCheck> checks)
    {
        if (events.Count == 0)
        {
            checks.Add(new ComplianceReviewRuntimeAcceptanceCheck(
                "lifecycle-events-present",
                Passed: false,
                "No review audit events observed for the incident.",
                Array.Empty<Guid>()));
            return false;
        }

        var sequenceValid = true;
        string? previousHash = null;
        var currentState = ComplianceReviewState.Suspected;

        for (var index = 0; index < events.Count; index++)
        {
            var audit = events[index];
            var expectedSeq = index + 1;
            if (audit.Sequence != expectedSeq ||
                audit.PreviousState != currentState ||
                !string.Equals(audit.PreviousAuditSha256, previousHash, StringComparison.Ordinal))
            {
                sequenceValid = false;
                break;
            }

            try
            {
                var validated = ComplianceReviewWorkflowContract.NormalizeAndValidateAuditEvent(audit);
                currentState = validated.ResultState;
                previousHash = validated.AuditSha256;
            }
            catch
            {
                sequenceValid = false;
                break;
            }
        }

        var terminalStateReached = currentState is ComplianceReviewState.Confirmed or ComplianceReviewState.Dismissed;
        var lifecyclePassed = sequenceValid && terminalStateReached;

        checks.Add(new ComplianceReviewRuntimeAcceptanceCheck(
            "lifecycle-complete",
            Passed: lifecyclePassed,
            lifecyclePassed
                ? $"The incident advanced through {events.Count} valid sequence(s) to terminal state '{currentState}'."
                : $"Lifecycle validation failed: sequenceValid={sequenceValid}, terminalState={terminalStateReached} (final state: '{currentState}').",
            events.Select(e => e.AuditEventId).ToArray()));

        return lifecyclePassed;
    }

    private static bool ValidateRoleDistinctReviewers(
        ComplianceReviewIncident incident,
        IReadOnlyList<ComplianceReviewAuditEvent> events,
        IReadOnlyDictionary<string, string> agents,
        List<ComplianceReviewRuntimeAcceptanceCheck> checks)
    {
        var subjectId = incident.SubjectActorId;
        var reviewers = events.Select(e => e.ReviewerActorId).Distinct().ToHashSet(StringComparer.Ordinal);

        // Subject cannot review their own incident
        if (reviewers.Contains(subjectId))
        {
            checks.Add(new ComplianceReviewRuntimeAcceptanceCheck(
                "subject-reviewer-separation",
                Passed: false,
                $"Subject actor '{subjectId}' performed a review action on their own incident.",
                events.Where(e => string.Equals(e.ReviewerActorId, subjectId, StringComparison.Ordinal))
                      .Select(e => e.AuditEventId)
                      .ToArray()));
            return false;
        }

        checks.Add(new ComplianceReviewRuntimeAcceptanceCheck(
            "subject-reviewer-separation",
            Passed: true,
            $"Incident subject '{subjectId}' is distinct from all reviewers ({string.Join(", ", reviewers)}).",
            events.Select(e => e.AuditEventId).ToArray()));

        var pmReviewEvents = events
            .Where(e => e.ReviewerRole == ComplianceReviewerRole.ProjectManager)
            .ToArray();
        var leaderReviewEvents = events
            .Where(e => e.ReviewerRole == ComplianceReviewerRole.Leader)
            .ToArray();

        var pmDistinct = true;
        foreach (var pmEvent in pmReviewEvents)
        {
            if (!agents.TryGetValue(pmEvent.ReviewerActorId, out var role) ||
                !ComplianceReviewWorkflowContract.TryMapAssignmentRole(role, out var reviewerRole) ||
                reviewerRole != ComplianceReviewerRole.ProjectManager)
            {
                pmDistinct = false;
                break;
            }
        }

        var leaderDistinct = true;
        foreach (var leaderEvent in leaderReviewEvents)
        {
            if (!agents.TryGetValue(leaderEvent.ReviewerActorId, out var role) ||
                !ComplianceReviewWorkflowContract.TryMapAssignmentRole(role, out var reviewerRole) ||
                reviewerRole != ComplianceReviewerRole.Leader)
            {
                leaderDistinct = false;
                break;
            }
        }

        var pmIds = pmReviewEvents.Select(e => e.ReviewerActorId).ToHashSet(StringComparer.Ordinal);
        var leaderIds = leaderReviewEvents.Select(e => e.ReviewerActorId).ToHashSet(StringComparer.Ordinal);
        var overlappingReviewers = pmIds.Intersect(leaderIds).ToArray();

        var rolesAttributable = pmDistinct && (leaderReviewEvents.Length == 0 || leaderDistinct) && overlappingReviewers.Length == 0;

        checks.Add(new ComplianceReviewRuntimeAcceptanceCheck(
            "role-distinct-reviewers",
            Passed: rolesAttributable,
            rolesAttributable
                ? $"PM and Leader reviewer identities ({string.Join(", ", reviewers)}) match distinct running Agent roles."
                : $"Reviewer role attribution failed: pmDistinct={pmDistinct}, leaderDistinct={leaderDistinct}, overlap={string.Join(", ", overlappingReviewers)}.",
            events.Select(e => e.AuditEventId).ToArray()));

        return rolesAttributable;
    }

    private static bool ValidateRetentionProtection(
        ComplianceReviewIncident incident,
        IReadOnlyList<ComplianceReviewAuditEvent> events,
        bool retentionProtectedObserved,
        List<ComplianceReviewRuntimeAcceptanceCheck> checks)
    {
        var passed = retentionProtectedObserved;
        checks.Add(new ComplianceReviewRuntimeAcceptanceCheck(
            "retention-protection",
            Passed: passed,
            passed
                ? "Retention protection against unclosed review cases was observed."
                : "Retention protection was not observed during runtime review.",
            events.Select(e => e.AuditEventId).ToArray()));

        return passed;
    }

    private static bool ValidateRedactionCompliance(
        ComplianceReviewIncident incident,
        IReadOnlyList<ComplianceReviewAuditEvent> events,
        List<ComplianceReviewRuntimeAcceptanceCheck> checks)
    {
        var allRedacted = true;
        foreach (var e in events)
        {
            if (string.IsNullOrWhiteSpace(e.Reason) ||
                e.Reason.Length > ComplianceReviewWorkflowContract.MaximumReasonLength ||
                e.EvidenceIdentitySha256s.Any(h => string.IsNullOrWhiteSpace(h) || h.Length != 64))
            {
                allRedacted = false;
                break;
            }
        }

        checks.Add(new ComplianceReviewRuntimeAcceptanceCheck(
            "redaction-compliance",
            Passed: allRedacted,
            allRedacted
                ? "All audit event reasons and evidence hashes adhere to redaction and length policies."
                : "One or more audit events violate reason or evidence hash redaction policy.",
            events.Select(e => e.AuditEventId).ToArray()));

        return allRedacted;
    }

    private static bool ValidateRestartConsistency(
        ComplianceReviewIncident incident,
        IReadOnlyList<ComplianceReviewAuditEvent> events,
        bool restartConsistencyObserved,
        List<ComplianceReviewRuntimeAcceptanceCheck> checks)
    {
        var passed = restartConsistencyObserved;
        checks.Add(new ComplianceReviewRuntimeAcceptanceCheck(
            "restart-reconnect-consistency",
            Passed: passed,
            passed
                ? "Review queue and audit state remained consistent across service restart/reconnect."
                : "Service restart/reconnect consistency was not observed or failed verification.",
            events.Select(e => e.AuditEventId).ToArray()));

        return passed;
    }

    private static IReadOnlyDictionary<string, string> ValidateAgents(
        IReadOnlyList<ComplianceReviewRuntimeAgentIdentity> runningAgents)
    {
        var result = new Dictionary<string, string>(StringComparer.Ordinal);
        foreach (var agent in runningAgents)
        {
            ArgumentNullException.ThrowIfNull(agent);
            var id = ComplianceReviewWorkflowContract.NormalizeActorId(agent.AgentId);
            if (string.IsNullOrWhiteSpace(agent.AgentRole))
            {
                throw new ArgumentException("Agent role cannot be blank.", nameof(runningAgents));
            }

            result[id] = agent.AgentRole.Trim();
        }

        return result;
    }

    private static string ComputeReviewAuditSha256(IReadOnlyList<ComplianceReviewAuditEvent> events)
    {
        if (events.Count == 0)
        {
            return string.Empty;
        }

        using var sha256 = SHA256.Create();
        var buffer = new StringBuilder();
        foreach (var audit in events)
        {
            buffer.Append(audit.Sequence)
                  .Append(':')
                  .Append(audit.AuditSha256)
                  .Append(';');
        }

        var hashBytes = sha256.ComputeHash(Encoding.UTF8.GetBytes(buffer.ToString()));
        return Convert.ToHexString(hashBytes);
    }
}
