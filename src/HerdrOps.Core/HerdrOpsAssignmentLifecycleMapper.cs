using HerdrOps.Contracts.SelfReport;
using HerdrOps.Domain.Assignments;

namespace HerdrOps.Core;

public static class HerdrOpsAssignmentLifecycleMapper
{
    public static AssignmentLifecycleEvent Map(HerdrOpsAcceptedSelfReport accepted)
    {
        ArgumentNullException.ThrowIfNull(accepted);
        HerdrOpsSelfReportJson.ValidateSubmission(accepted.Submission);
        var submission = accepted.Submission;
        var expectedSubmissionSha256 = HerdrOpsSelfReportJson.ComputeSha256(submission);
        if (!string.Equals(
                accepted.EventSha256,
                expectedSubmissionSha256,
                StringComparison.Ordinal))
        {
            throw new AssignmentLifecycleContractException(
                "The accepted self-report hash does not match its submission content.");
        }

        var eventKind = submission.EventType switch
        {
            HerdrOpsSelfReportProtocol.EventTypes.Assignment =>
                AssignmentLifecycleEventKind.Assignment,
            HerdrOpsSelfReportProtocol.EventTypes.Acknowledgement =>
                AssignmentLifecycleEventKind.Acknowledgement,
            HerdrOpsSelfReportProtocol.EventTypes.Delegation =>
                AssignmentLifecycleEventKind.Delegation,
            HerdrOpsSelfReportProtocol.EventTypes.Progress =>
                AssignmentLifecycleEventKind.Progress,
            HerdrOpsSelfReportProtocol.EventTypes.Deviation =>
                AssignmentLifecycleEventKind.Deviation,
            HerdrOpsSelfReportProtocol.EventTypes.Evidence =>
                AssignmentLifecycleEventKind.Evidence,
            HerdrOpsSelfReportProtocol.EventTypes.Handoff =>
                AssignmentLifecycleEventKind.Handoff,
            _ => throw new AssignmentLifecycleContractException(
                $"Unsupported self-report event type '{submission.EventType}'."),
        };

        return AssignmentLifecycleContract.NormalizeAndValidate(new AssignmentLifecycleEvent(
            submission.ContractVersion,
            submission.EventId,
            eventKind,
            accepted.Sequence,
            submission.OccurredUtc,
            accepted.AcceptedUtc,
            accepted.Source,
            accepted.CorrelationId,
            accepted.EventSha256,
            submission.TaskId,
            submission.ActorId,
            submission.ActorRole,
            submission.Summary,
            submission.ParentEventId,
            submission.TargetAgentId,
            submission.ProgressPercent,
            submission.DeviationReason,
            submission.EvidenceReference,
            submission.EvidenceSha256,
            submission.HandoffNote)).Event;
    }

    public static HerdrOpsAcceptedSelfReport RestoreAccepted(
        AssignmentLifecycleEvent lifecycleEvent)
    {
        lifecycleEvent = AssignmentLifecycleContract.NormalizeAndValidate(lifecycleEvent).Event;
        var submission = new HerdrOpsSelfReportSubmission(
            lifecycleEvent.ContractVersion,
            lifecycleEvent.EventId,
            EventType(lifecycleEvent.EventKind),
            lifecycleEvent.TaskId,
            lifecycleEvent.ActorId,
            lifecycleEvent.ActorRole,
            lifecycleEvent.OccurredUtc,
            lifecycleEvent.Summary,
            lifecycleEvent.ParentEventId,
            lifecycleEvent.TargetAgentId,
            lifecycleEvent.ProgressPercent,
            lifecycleEvent.DeviationReason,
            lifecycleEvent.EvidenceReference,
            lifecycleEvent.EvidenceSha256,
            lifecycleEvent.HandoffNote);
        HerdrOpsSelfReportJson.ValidateSubmission(submission);
        var submissionSha256 = HerdrOpsSelfReportJson.ComputeSha256(submission);
        if (!string.Equals(
                lifecycleEvent.EventSha256,
                submissionSha256,
                StringComparison.Ordinal))
        {
            throw new AssignmentLifecycleContractException(
                "The persisted lifecycle event does not bind the original self-report submission.");
        }

        return new HerdrOpsAcceptedSelfReport(
            lifecycleEvent.Sequence,
            lifecycleEvent.AcceptedUtc,
            lifecycleEvent.Source,
            lifecycleEvent.CorrelationId,
            lifecycleEvent.EventSha256,
            submission);
    }

    private static string EventType(AssignmentLifecycleEventKind eventKind) => eventKind switch
    {
        AssignmentLifecycleEventKind.Assignment =>
            HerdrOpsSelfReportProtocol.EventTypes.Assignment,
        AssignmentLifecycleEventKind.Acknowledgement =>
            HerdrOpsSelfReportProtocol.EventTypes.Acknowledgement,
        AssignmentLifecycleEventKind.Delegation =>
            HerdrOpsSelfReportProtocol.EventTypes.Delegation,
        AssignmentLifecycleEventKind.Progress =>
            HerdrOpsSelfReportProtocol.EventTypes.Progress,
        AssignmentLifecycleEventKind.Deviation =>
            HerdrOpsSelfReportProtocol.EventTypes.Deviation,
        AssignmentLifecycleEventKind.Evidence =>
            HerdrOpsSelfReportProtocol.EventTypes.Evidence,
        AssignmentLifecycleEventKind.Handoff =>
            HerdrOpsSelfReportProtocol.EventTypes.Handoff,
        _ => throw new AssignmentLifecycleContractException(
            $"Unsupported lifecycle event kind '{eventKind}'."),
    };
}
