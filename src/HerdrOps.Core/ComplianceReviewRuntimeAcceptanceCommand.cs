using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.Json.Serialization;
using HerdrOps.Contracts;
using HerdrOps.Contracts.ReviewIpc;
using HerdrOps.Contracts.StateIpc;
using HerdrOps.Domain.Compliance;
using HerdrOps.Infrastructure.StateIpc;

namespace HerdrOps.Core;

public sealed record ComplianceReviewCompositeRuntimeReport(
    string EvidenceClassification,
    bool RuntimeAccepted,
    bool SessionControlInvoked,
    DateTimeOffset GeneratedUtc,
    string IncidentId,
    string ReviewTracePath,
    string ReviewTraceSha256,
    string HerdrRuntimeReportPath,
    string HerdrRuntimeReportSha256,
    string FinalHerdrStateSha256,
    DateTimeOffset OverlapStartedUtc,
    DateTimeOffset OverlapFinishedUtc,
    ComplianceReviewRuntimeAcceptanceResult Acceptance,
    string EvidenceBoundary);

public static class ComplianceReviewRuntimeAcceptanceCommand
{
    private const int RuntimeFailureExitCode = 2;
    private const int UsageFailureExitCode = 64;
    private const int MaximumInputBytes = 8 * 1024 * 1024;

    private static readonly JsonSerializerOptions SerializerOptions = new()
    {
        AllowTrailingCommas = false,
        MaxDepth = 128,
        PropertyNameCaseInsensitive = true,
        ReadCommentHandling = JsonCommentHandling.Disallow,
        UnmappedMemberHandling = JsonUnmappedMemberHandling.Disallow,
        WriteIndented = true,
        Converters = { new JsonStringEnumConverter() },
    };

    public static int Run(string[] args, TextWriter output, TextWriter error)
    {
        ArgumentNullException.ThrowIfNull(args);
        ArgumentNullException.ThrowIfNull(output);
        ArgumentNullException.ThrowIfNull(error);
        if (args.Length == 0 ||
            !string.Equals(
                args[0],
                "compliance-review-acceptance",
                StringComparison.Ordinal))
        {
            error.WriteLine("The compliance review acceptance command name is required.");
            WriteUsage(error);
            return UsageFailureExitCode;
        }

        string? reviewTracePath = null;
        string? herdrRuntimeReportPath = null;
        string? incidentId = null;
        string? reportPath = null;
        var seen = new HashSet<string>(StringComparer.Ordinal);
        for (var index = 1; index < args.Length; index++)
        {
            var option = args[index];
            if (!seen.Add(option) ||
                index + 1 >= args.Length ||
                string.IsNullOrWhiteSpace(args[index + 1]))
            {
                error.WriteLine($"Invalid, duplicate, or incomplete option: {option}");
                WriteUsage(error);
                return UsageFailureExitCode;
            }

            var value = args[++index];
            switch (option)
            {
                case "--review-trace":
                    reviewTracePath = value;
                    break;
                case "--herdr-runtime-report":
                    herdrRuntimeReportPath = value;
                    break;
                case "--incident-id":
                    incidentId = value;
                    break;
                case "--report":
                    reportPath = value;
                    break;
                default:
                    error.WriteLine($"Unknown option: {option}");
                    WriteUsage(error);
                    return UsageFailureExitCode;
            }
        }

        if (reviewTracePath is null ||
            herdrRuntimeReportPath is null ||
            incidentId is null ||
            reportPath is null)
        {
            error.WriteLine("Every compliance review acceptance option is required.");
            WriteUsage(error);
            return UsageFailureExitCode;
        }

        try
        {
            reviewTracePath = Path.GetFullPath(reviewTracePath);
            herdrRuntimeReportPath = Path.GetFullPath(herdrRuntimeReportPath);
            reportPath = Path.GetFullPath(reportPath);
            var reviewBytes = ReadBounded(reviewTracePath);
            var runtimeBytes = ReadBounded(herdrRuntimeReportPath);
            var reviewReport = Deserialize<ComplianceReviewRuntimeTraceReport>(
                reviewBytes,
                "compliance review trace");
            var reviewTrace = MapToDomainTrace(reviewReport);
            var herdrRuntime = Deserialize<HerdrCoreRuntimeEvidenceReport>(
                runtimeBytes,
                "Herdr runtime report");

            if (!reviewTrace.DurableReviewEnabled ||
                reviewTrace.AuditEvents is null ||
                reviewTrace.Incidents is null)
            {
                throw new InvalidDataException(
                    "The compliance review trace has no durable review projection.");
            }

            if (herdrRuntime.Admission is null ||
                herdrRuntime.FinalMonitorState is null ||
                herdrRuntime.FinalProjectedState is null ||
                herdrRuntime.StartedUtc > herdrRuntime.FinishedUtc ||
                herdrRuntime.SessionControlInvoked ||
                herdrRuntime.SnapshotObserved != herdrRuntime.RuntimeObserved ||
                (herdrRuntime.RuntimeObserved &&
                 (herdrRuntime.FinalMonitorState.BootstrapCount <= 0 ||
                  herdrRuntime.FinalMonitorState.ServerIdentity is null ||
                  !string.Equals(
                      herdrRuntime.FinalMonitorState.ServerIdentity.ExecutableSha256,
                      herdrRuntime.Admission.ExecutableSha256,
                      StringComparison.Ordinal))))
            {
                throw new InvalidDataException(
                    "The Herdr runtime report is internally inconsistent or invoked session control.");
            }

            var normalizedState = HerdrSessionStateContractReducer.NormalizeAndValidate(
                herdrRuntime.FinalProjectedState);
            var stateSha256 = HerdrOpsStateIpcJson.ComputeSha256(normalizedState);
            if (!string.Equals(
                    stateSha256,
                    herdrRuntime.FinalProjectedStateSha256,
                    StringComparison.Ordinal))
            {
                throw new InvalidDataException(
                    "The Herdr runtime report state hash does not match its final state.");
            }

            var agents = normalizedState.Agents
                .Where(agent => !string.IsNullOrWhiteSpace(agent.Title))
                .Select(agent => new ComplianceReviewRuntimeAgentIdentity(
                    agent.TerminalId,
                    agent.Title!))
                .ToArray();

            var acceptance = ComplianceReviewRuntimeAcceptance.Analyze(
                reviewTrace.AuditEvents,
                reviewTrace.Incidents,
                agents,
                incidentId,
                reviewTrace.RetentionProtectedObserved,
                reviewTrace.RestartConsistencyObserved);

            var overlapStartedUtc = reviewTrace.StartedUtc > herdrRuntime.StartedUtc
                ? reviewTrace.StartedUtc
                : herdrRuntime.StartedUtc;
            var overlapFinishedUtc = reviewTrace.FinishedUtc < herdrRuntime.FinishedUtc
                ? reviewTrace.FinishedUtc
                : herdrRuntime.FinishedUtc;

            var matchingEvents = reviewTrace.AuditEvents
                .Where(e => string.Equals(e.IncidentId, incidentId, StringComparison.Ordinal))
                .ToArray();

            var timeCoherent = overlapStartedUtc <= overlapFinishedUtc &&
                               matchingEvents.Length > 0 &&
                               matchingEvents.All(item =>
                                   item.OccurredUtc >= overlapStartedUtc &&
                                   item.OccurredUtc <= overlapFinishedUtc);

            var runtimeAccepted = acceptance.Passed &&
                                  timeCoherent &&
                                  string.Equals(
                                      reviewTrace.EvidenceClassification,
                                      "BuiltProcessIntegration",
                                      StringComparison.Ordinal) &&
                                  herdrRuntime.RuntimeObserved &&
                                  string.Equals(
                                      herdrRuntime.EvidenceClassification,
                                      EvidenceClass.Runtime.ToString(),
                                      StringComparison.Ordinal);

            var report = new ComplianceReviewCompositeRuntimeReport(
                runtimeAccepted ? EvidenceClass.Runtime.ToString() : "NoRuntimeCredit",
                runtimeAccepted,
                herdrRuntime.SessionControlInvoked,
                DateTimeOffset.UtcNow,
                incidentId,
                reviewTracePath,
                Hash(reviewBytes),
                herdrRuntimeReportPath,
                Hash(runtimeBytes),
                stateSha256,
                overlapStartedUtc,
                overlapFinishedUtc,
                acceptance,
                runtimeAccepted
                    ? "This report binds a durable Core compliance review workflow to exact role-distinct Agent identities and observed Herdr runtime state. Current-user Named Pipe authorization does not authenticate which same-user process submitted each review event."
                    : "The review trace and Herdr reports did not satisfy every role-distinct, lifecycle, retention-protection, redaction, restart-consistency, hash, and overlapping-runtime requirement; no Runtime credit is awarded.");

            var json = JsonSerializer.Serialize(report, SerializerOptions) + Environment.NewLine;
            new AtomicSchemaOutputWriter().Write(reportPath, Encoding.UTF8.GetBytes(json));
            output.Write(json);
            return runtimeAccepted ? 0 : RuntimeFailureExitCode;
        }
        catch (Exception exception) when (
            exception is IOException or
                UnauthorizedAccessException or
                System.Security.SecurityException or
                NotSupportedException or
                InvalidDataException or
                JsonException or
                ArgumentException or
                InvalidOperationException)
        {
            error.WriteLine($"Compliance review runtime acceptance failed: {exception.Message}");
            return RuntimeFailureExitCode;
        }
    }

    private static ComplianceReviewRuntimeTrace MapToDomainTrace(
        ComplianceReviewRuntimeTraceReport report)
    {
        ArgumentNullException.ThrowIfNull(report);
        if (report.AuditEvents is null || report.Incidents is null)
        {
            throw new InvalidDataException(
                "The compliance review trace has no audit events or incidents.");
        }

        return new ComplianceReviewRuntimeTrace(
            report.ContractVersion,
            report.StartedUtc,
            report.FinishedUtc,
            report.EvidenceClassification,
            report.DurableReviewEnabled,
            report.AuditEvents.Select(MapAuditEvent).ToArray(),
            report.Incidents.Select(MapIncident).ToArray(),
            report.RetentionProtectedObserved,
            report.RestartConsistencyObserved);
    }

    private static ComplianceReviewIncident MapIncident(
        HerdrOpsComplianceReviewIncident incident) =>
        new(
            incident.ContractVersion,
            incident.IncidentId,
            incident.TaskId,
            incident.SubjectActorId,
            incident.RegisteredUtc,
            incident.InitialEvidenceIdentitySha256s,
            incident.RegistrationSha256,
            (ComplianceReviewState)incident.State,
            incident.Sequence,
            incident.UpdatedUtc,
            incident.LastAuditEventId,
            incident.LastAuditSha256);

    private static ComplianceReviewAuditEvent MapAuditEvent(
        HerdrOpsComplianceReviewAuditEvent auditEvent) =>
        new(
            auditEvent.ContractVersion,
            auditEvent.AuditEventId,
            auditEvent.IncidentId,
            auditEvent.TaskId,
            auditEvent.SubjectActorId,
            auditEvent.Sequence,
            auditEvent.ReviewerActorId,
            (ComplianceReviewerRole)auditEvent.ReviewerRole,
            auditEvent.AuthorityProvenanceEventId,
            auditEvent.AuthorityProvenanceSequence,
            auditEvent.AuthorityProvenanceSha256,
            (ComplianceReviewDecisionKind)auditEvent.DecisionKind,
            (ComplianceReviewState)auditEvent.PreviousState,
            (ComplianceReviewState)auditEvent.ResultState,
            auditEvent.Reason,
            auditEvent.OccurredUtc,
            auditEvent.EvidenceIdentitySha256s,
            auditEvent.EvidenceSetSha256,
            auditEvent.PreviousAuditSha256,
            auditEvent.AuditSha256);

    private static byte[] ReadBounded(string path)
    {
        var info = new FileInfo(path);
        if (!info.Exists || info.Length is <= 0 or > MaximumInputBytes)
        {
            throw new InvalidDataException(
                $"Acceptance input must contain 1 through {MaximumInputBytes} bytes: {path}");
        }

        if (info.Attributes.HasFlag(FileAttributes.ReparsePoint) || info.LinkTarget is not null)
        {
            throw new InvalidDataException($"Reparse point or symbolic link rejected: {path}");
        }

        return File.ReadAllBytes(path);
    }

    private static T Deserialize<T>(byte[] bytes, string name)
    {
        using var document = JsonDocument.Parse(bytes, new JsonDocumentOptions
        {
            AllowTrailingCommas = false,
            CommentHandling = JsonCommentHandling.Disallow,
            MaxDepth = 128,
        });
        EnsureUniqueProperties(document.RootElement, name);
        return JsonSerializer.Deserialize<T>(bytes, SerializerOptions)
            ?? throw new InvalidDataException($"The {name} was null.");
    }

    private static void EnsureUniqueProperties(JsonElement element, string name)
    {
        if (element.ValueKind == JsonValueKind.Object)
        {
            var names = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
            foreach (var property in element.EnumerateObject())
            {
                if (!names.Add(property.Name))
                {
                    throw new InvalidDataException(
                        $"The {name} contains duplicate property '{property.Name}'.");
                }

                EnsureUniqueProperties(property.Value, name);
            }
        }
        else if (element.ValueKind == JsonValueKind.Array)
        {
            foreach (var item in element.EnumerateArray())
            {
                EnsureUniqueProperties(item, name);
            }
        }
    }

    private static string Hash(byte[] bytes) => Convert.ToHexString(SHA256.HashData(bytes));

    private static void WriteUsage(TextWriter writer) => writer.WriteLine(
        "Usage: HerdrOps.Core compliance-review-acceptance --review-trace <json-path> --herdr-runtime-report <json-path> --incident-id <incident-id> --report <json-path>");
}
