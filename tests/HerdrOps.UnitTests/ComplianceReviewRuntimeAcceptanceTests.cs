using HerdrOps.Domain.Compliance;

namespace HerdrOps.UnitTests;

[TestClass]
public sealed class ComplianceReviewRuntimeAcceptanceTests
{
    private static readonly DateTimeOffset BaseTime = new(2026, 8, 16, 12, 0, 0, TimeSpan.Zero);

    [TestMethod]
    public void FullLifecycleWithRoleDistinctAgentsPassesAcceptance()
    {
        const string incidentId = "INC-28-001";
        const string taskId = "TASK-28";
        const string subjectId = "worker-pane-1";
        const string pmId = "pm-pane-1";
        const string leaderId = "leader-pane-1";

        var incident = CreateIncident(incidentId, taskId, subjectId);
        var (ev1, inc1) = CreateTransition(
            incident,
            pmId,
            ComplianceReviewerRole.ProjectManager,
            ComplianceReviewDecisionKind.SendToLeader,
            ComplianceReviewState.PendingLeader,
            "Send to Leader for technical review.",
            BaseTime.AddSeconds(1));

        var (ev2, inc2) = CreateTransition(
            inc1,
            leaderId,
            ComplianceReviewerRole.Leader,
            ComplianceReviewDecisionKind.EscalateToProjectManager,
            ComplianceReviewState.PendingProjectManager,
            "Reviewed by Leader; escalated to PM for confirmation.",
            BaseTime.AddSeconds(2));

        var (ev3, inc3) = CreateTransition(
            inc2,
            pmId,
            ComplianceReviewerRole.ProjectManager,
            ComplianceReviewDecisionKind.Confirm,
            ComplianceReviewState.Confirmed,
            "Confirmed by Project Manager with full evidence audit.",
            BaseTime.AddSeconds(3));

        var agents = new[]
        {
            new ComplianceReviewRuntimeAgentIdentity(pmId, "Project Manager"),
            new ComplianceReviewRuntimeAgentIdentity(leaderId, "Backend Leader"),
            new ComplianceReviewRuntimeAgentIdentity(subjectId, "Worker"),
        };

        var result = ComplianceReviewRuntimeAcceptance.Analyze(
            new[] { ev1, ev2, ev3 },
            new[] { inc3 },
            agents,
            incidentId,
            retentionProtectedObserved: true,
            restartConsistencyObserved: true);

        Assert.IsTrue(result.Passed);
        Assert.IsTrue(result.CompleteLifecyclePassed);
        Assert.IsTrue(result.RoleDistinctReviewersPassed);
        Assert.IsTrue(result.RetentionProtectionPassed);
        Assert.IsTrue(result.RedactionCompliancePassed);
        Assert.IsTrue(result.RestartConsistencyPassed);
        Assert.IsFalse(string.IsNullOrEmpty(result.ReviewAuditSha256));
    }

    [TestMethod]
    [DataRow("Security Leader")]
    [DataRow("Test Leader")]
    [DataRow("DevOps Leader")]
    [DataRow("Data Leader")]
    [DataRow("Documentation Leader")]
    public void CanonicalLeaderRolesPassAcceptance(string leaderRole)
    {
        const string incidentId = "INC-28-LEADERS";
        const string taskId = "TASK-28";
        const string subjectId = "worker-sub";
        const string pmId = "pm-sub";
        const string leaderId = "leader-sub";

        var incident = CreateIncident(incidentId, taskId, subjectId);
        var (ev1, inc1) = CreateTransition(
            incident,
            pmId,
            ComplianceReviewerRole.ProjectManager,
            ComplianceReviewDecisionKind.SendToLeader,
            ComplianceReviewState.PendingLeader,
            "Route to Leader.",
            BaseTime.AddSeconds(1));

        var (ev2, inc2) = CreateTransition(
            inc1,
            leaderId,
            ComplianceReviewerRole.Leader,
            ComplianceReviewDecisionKind.EscalateToProjectManager,
            ComplianceReviewState.PendingProjectManager,
            "Escalate to PM.",
            BaseTime.AddSeconds(2));

        var (ev3, inc3) = CreateTransition(
            inc2,
            pmId,
            ComplianceReviewerRole.ProjectManager,
            ComplianceReviewDecisionKind.Confirm,
            ComplianceReviewState.Confirmed,
            "Confirmed.",
            BaseTime.AddSeconds(3));

        var agents = new[]
        {
            new ComplianceReviewRuntimeAgentIdentity(pmId, "Project Manager"),
            new ComplianceReviewRuntimeAgentIdentity(leaderId, leaderRole),
            new ComplianceReviewRuntimeAgentIdentity(subjectId, "Worker"),
        };

        var result = ComplianceReviewRuntimeAcceptance.Analyze(
            new[] { ev1, ev2, ev3 },
            new[] { inc3 },
            agents,
            incidentId,
            retentionProtectedObserved: true,
            restartConsistencyObserved: true);

        Assert.IsTrue(result.Passed);
        Assert.IsTrue(result.RoleDistinctReviewersPassed);
    }

    [TestMethod]
    public void NonCanonicalRoleFailsRoleDistinctCheck()
    {
        const string incidentId = "INC-28-INVALID-ROLE";
        const string taskId = "TASK-28";
        const string subjectId = "worker-sub";
        const string pmId = "pm-sub";

        var incident = CreateIncident(incidentId, taskId, subjectId);
        var (ev1, inc1) = CreateTransition(
            incident,
            pmId,
            ComplianceReviewerRole.ProjectManager,
            ComplianceReviewDecisionKind.Confirm,
            ComplianceReviewState.Confirmed,
            "Confirmed.",
            BaseTime.AddSeconds(1));

        var agents = new[]
        {
            new ComplianceReviewRuntimeAgentIdentity(pmId, "Unauthorized Developer"),
            new ComplianceReviewRuntimeAgentIdentity(subjectId, "Worker"),
        };

        var result = ComplianceReviewRuntimeAcceptance.Analyze(
            new[] { ev1 },
            new[] { inc1 },
            agents,
            incidentId,
            retentionProtectedObserved: true,
            restartConsistencyObserved: true);

        Assert.IsFalse(result.Passed);
        Assert.IsFalse(result.RoleDistinctReviewersPassed);
    }

    [TestMethod]
    public void DirectProjectManagerDismissLifecyclePassesAcceptance()
    {
        const string incidentId = "INC-28-002";
        const string taskId = "TASK-28";
        const string subjectId = "worker-pane-2";
        const string pmId = "pm-pane-2";

        var incident = CreateIncident(incidentId, taskId, subjectId);
        var (ev1, inc1) = CreateTransition(
            incident,
            pmId,
            ComplianceReviewerRole.ProjectManager,
            ComplianceReviewDecisionKind.Dismiss,
            ComplianceReviewState.Dismissed,
            "Dismissed by Project Manager; false positive.",
            BaseTime.AddSeconds(1));

        var agents = new[]
        {
            new ComplianceReviewRuntimeAgentIdentity(pmId, "Project Manager"),
            new ComplianceReviewRuntimeAgentIdentity(subjectId, "Worker"),
        };

        var result = ComplianceReviewRuntimeAcceptance.Analyze(
            new[] { ev1 },
            new[] { inc1 },
            agents,
            incidentId,
            retentionProtectedObserved: true,
            restartConsistencyObserved: true);

        Assert.IsTrue(result.Passed);
        Assert.IsTrue(result.CompleteLifecyclePassed);
        Assert.IsTrue(result.RoleDistinctReviewersPassed);
    }

    [TestMethod]
    public void SelfReviewFailsRoleDistinctCheck()
    {
        const string incidentId = "INC-28-003";
        const string taskId = "TASK-28";
        const string subjectId = "pm-worker-same";

        var incident = CreateIncident(incidentId, taskId, subjectId);
        var audit = new ComplianceReviewAuditEvent(
            ComplianceReviewWorkflowContract.ContractVersion,
            Guid.NewGuid(),
            incidentId,
            taskId,
            subjectId,
            1,
            subjectId,
            ComplianceReviewerRole.ProjectManager,
            Guid.NewGuid(),
            1,
            new string('A', 64),
            ComplianceReviewDecisionKind.Confirm,
            ComplianceReviewState.Suspected,
            ComplianceReviewState.Confirmed,
            "Self-confirm reason.",
            BaseTime.AddSeconds(1),
            Array.Empty<string>(),
            new string('B', 64),
            null,
            new string('C', 64));

        var agents = new[]
        {
            new ComplianceReviewRuntimeAgentIdentity(subjectId, "Project Manager"),
        };

        var result = ComplianceReviewRuntimeAcceptance.Analyze(
            new[] { audit },
            new[] { incident },
            agents,
            incidentId,
            retentionProtectedObserved: true,
            restartConsistencyObserved: true);

        Assert.IsFalse(result.Passed);
        Assert.IsFalse(result.RoleDistinctReviewersPassed);
    }

    [TestMethod]
    public void MissingRetentionOrRestartConsistencyFailsAcceptance()
    {
        const string incidentId = "INC-28-004";
        const string taskId = "TASK-28";
        const string subjectId = "worker-pane-4";
        const string pmId = "pm-pane-4";

        var incident = CreateIncident(incidentId, taskId, subjectId);
        var (ev1, inc1) = CreateTransition(
            incident,
            pmId,
            ComplianceReviewerRole.ProjectManager,
            ComplianceReviewDecisionKind.Confirm,
            ComplianceReviewState.Confirmed,
            "Confirmed.",
            BaseTime.AddSeconds(1));

        var agents = new[]
        {
            new ComplianceReviewRuntimeAgentIdentity(pmId, "Project Manager"),
            new ComplianceReviewRuntimeAgentIdentity(subjectId, "Worker"),
        };

        var retentionFailed = ComplianceReviewRuntimeAcceptance.Analyze(
            new[] { ev1 },
            new[] { inc1 },
            agents,
            incidentId,
            retentionProtectedObserved: false,
            restartConsistencyObserved: true);
        Assert.IsFalse(retentionFailed.Passed);
        Assert.IsFalse(retentionFailed.RetentionProtectionPassed);

        var restartFailed = ComplianceReviewRuntimeAcceptance.Analyze(
            new[] { ev1 },
            new[] { inc1 },
            agents,
            incidentId,
            retentionProtectedObserved: true,
            restartConsistencyObserved: false);
        Assert.IsFalse(restartFailed.Passed);
        Assert.IsFalse(restartFailed.RestartConsistencyPassed);
    }

    [TestMethod]
    public void MissingIncidentFailsAnalysis()
    {
        var result = ComplianceReviewRuntimeAcceptance.Analyze(
            Array.Empty<ComplianceReviewAuditEvent>(),
            Array.Empty<ComplianceReviewIncident>(),
            new[] { new ComplianceReviewRuntimeAgentIdentity("pm", "Project Manager") },
            "NON-EXISTENT",
            retentionProtectedObserved: true,
            restartConsistencyObserved: true);

        Assert.IsFalse(result.Passed);
        Assert.IsFalse(result.CompleteLifecyclePassed);
    }

    private static ComplianceReviewIncident CreateIncident(
        string incidentId,
        string taskId,
        string subjectActorId)
    {
        return ComplianceReviewWorkflowContract.CreateIncident(
            new ComplianceReviewIncidentRegistration(
                ComplianceReviewWorkflowContract.ContractVersion,
                incidentId,
                taskId,
                subjectActorId,
                BaseTime,
                Array.Empty<string>()));
    }

    private static (ComplianceReviewAuditEvent Event, ComplianceReviewIncident Result) CreateTransition(
        ComplianceReviewIncident current,
        string reviewerId,
        ComplianceReviewerRole role,
        ComplianceReviewDecisionKind decision,
        ComplianceReviewState expectedResultState,
        string reason,
        DateTimeOffset occurredUtc)
    {
        var command = new ComplianceReviewCommand(
            ComplianceReviewWorkflowContract.ContractVersion,
            Guid.NewGuid(),
            current.IncidentId,
            current.State,
            current.Sequence,
            reviewerId,
            decision,
            reason,
            occurredUtc,
            Array.Empty<string>());

        var authority = new ComplianceReviewAuthority(
            reviewerId,
            role,
            Guid.NewGuid(),
            1,
            BaseTime,
            new string('F', 64));

        var auditEvent = ComplianceReviewWorkflowContract.CreateAuditEvent(
            current,
            command,
            authority);

        var resultIncident = ComplianceReviewWorkflowContract.Apply(
            current,
            auditEvent);

        return (auditEvent, resultIncident);
    }
}
