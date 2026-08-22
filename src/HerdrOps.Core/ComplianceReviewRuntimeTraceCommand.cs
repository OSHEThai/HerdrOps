using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.Json.Serialization;
using HerdrOps.Contracts.ReviewIpc;
using HerdrOps.Domain.Activity;
using HerdrOps.Domain.Compliance;
using HerdrOps.Infrastructure.Storage;
using Microsoft.Data.Sqlite;

namespace HerdrOps.Core;

/// <summary>
/// Produces a fail-closed, bounded compliance-review trace report from durable SQLite state.
/// The producer always emits RuntimeObserved=false; actual Herdr runtime acceptance is a separate gate.
/// </summary>
public static class ComplianceReviewRuntimeTraceCommand
{
    public const string CommandName = "trace-compliance-review";
    public const string AlternateCommandName = "compliance-review-trace";
    public const int SuccessExitCode = 0;
    public const int RuntimeFailureExitCode = 2;
    public const int UsageFailureExitCode = 64;
    public const int MaximumInputBytes = 512 * 1024 * 1024; // 512 MB SQLite DB bound

    private static readonly JsonSerializerOptions SerializerOptions = new(JsonSerializerDefaults.Web)
    {
        AllowTrailingCommas = false,
        MaxDepth = 64,
        PropertyNameCaseInsensitive = false,
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
            (!string.Equals(args[0], CommandName, StringComparison.Ordinal) &&
             !string.Equals(args[0], AlternateCommandName, StringComparison.Ordinal)))
        {
            error.WriteLine("The trace-compliance-review command name is required.");
            WriteUsage(error);
            return UsageFailureExitCode;
        }

        if (args.Length == 2 && string.Equals(args[1], "--help", StringComparison.Ordinal))
        {
            WriteUsage(output);
            return SuccessExitCode;
        }

        string? databasePath = null;
        string? reportPath = null;
        string? taskIdFilter = null;
        var incidentFilters = new List<string>();
        var classification = ComplianceReviewRuntimeTraceContract.BuiltProcessIntegrationEvidence;
        var seenOptions = new HashSet<string>(StringComparer.Ordinal);
        for (var index = 1; index < args.Length; index++)
        {
            var option = args[index];
            switch (option)
            {
                case "--database" when index + 1 < args.Length && seenOptions.Add(option):
                    databasePath = args[++index];
                    break;
                case "--report" when index + 1 < args.Length && seenOptions.Add(option):
                    reportPath = args[++index];
                    break;
                case "--task-id" when index + 1 < args.Length && seenOptions.Add(option):
                    taskIdFilter = args[++index];
                    break;
                case "--incident" when index + 1 < args.Length:
                    incidentFilters.Add(args[++index]);
                    break;
                case "--evidence-classification" when index + 1 < args.Length && seenOptions.Add(option):
                    classification = args[++index];
                    break;
                default:
                    error.WriteLine($"Invalid, duplicate, or incomplete option: {option}");
                    WriteUsage(error);
                    return UsageFailureExitCode;
            }
        }

        if (string.IsNullOrWhiteSpace(databasePath) || string.IsNullOrWhiteSpace(reportPath))
        {
            error.WriteLine("Both --database and --report are required.");
            WriteUsage(error);
            return UsageFailureExitCode;
        }

        if (!string.Equals(classification, ComplianceReviewRuntimeTraceContract.BuiltProcessIntegrationEvidence, StringComparison.Ordinal) &&
            !string.Equals(classification, ComplianceReviewRuntimeTraceContract.SyntheticEvidence, StringComparison.Ordinal))
        {
            error.WriteLine("Evidence classification is not an allowlisted non-runtime value.");
            return UsageFailureExitCode;
        }

        databasePath = Path.GetFullPath(databasePath);
        reportPath = Path.GetFullPath(reportPath);

        if (string.Equals(databasePath, reportPath, StringComparison.OrdinalIgnoreCase))
        {
            error.WriteLine("The database path and report path must be different files.");
            return UsageFailureExitCode;
        }

        if (!File.Exists(databasePath))
        {
            error.WriteLine($"Database file does not exist: {databasePath}");
            return UsageFailureExitCode;
        }

        if (Directory.Exists(databasePath))
        {
            error.WriteLine($"Database path is a directory, expected a file: {databasePath}");
            return UsageFailureExitCode;
        }

        var databaseInfo = new FileInfo(databasePath);
        if (databaseInfo.Length == 0)
        {
            error.WriteLine($"Database file is empty: {databasePath}");
            return RuntimeFailureExitCode;
        }

        if (databaseInfo.Length > MaximumInputBytes)
        {
            error.WriteLine($"Database file exceeds maximum size of {MaximumInputBytes} bytes: {databasePath}");
            return RuntimeFailureExitCode;
        }

        try
        {
            var productAssemblySha256 = ComputeProductAssemblySha256();

            var storeOptions = new HerdrStateStoreOptions(databasePath);
            using var store = new SqliteHerdrStateStore(storeOptions);
            var snapshot = store.ReadComplianceReviewRuntimeTraceSnapshot(
                taskIdFilter,
                incidentFilters.Count > 0 ? incidentFilters : null);

            if (snapshot.SchemaVersion < 4)
            {
                error.WriteLine($"Database schema version {snapshot.SchemaVersion} is unsupported; expected schema version 4+ with compliance review tables.");
                return RuntimeFailureExitCode;
            }

            if (snapshot.DatabaseFileSizeBytes <= 0 ||
                snapshot.DatabaseFileSizeBytes > MaximumInputBytes)
            {
                error.WriteLine($"SQLite snapshot size {snapshot.DatabaseFileSizeBytes} is outside the supported range.");
                return RuntimeFailureExitCode;
            }

            var rawIncidents = snapshot.Incidents;

            var startedUtc = ComputeEarliestObservedUtc(
                rawIncidents,
                snapshot.AuditEvents) ?? DateTimeOffset.UtcNow;

            if (incidentFilters.Count > 0)
            {
                var foundIds = new HashSet<string>(rawIncidents.Select(i => i.IncidentId), StringComparer.Ordinal);
                foreach (var expectedId in incidentFilters)
                {
                    if (!foundIds.Contains(expectedId))
                    {
                        error.WriteLine($"Compliance review incident '{expectedId}' was not found in the database.");
                        return RuntimeFailureExitCode;
                    }
                }
            }

            if (rawIncidents.Count > ComplianceReviewRuntimeTraceContract.MaximumIncidents)
            {
                error.WriteLine($"Incident count {rawIncidents.Count} exceeds maximum bound of {ComplianceReviewRuntimeTraceContract.MaximumIncidents}.");
                return RuntimeFailureExitCode;
            }

            var redactor = new SensitiveTextRedactor();
            var allAuditEvents = new List<HerdrOpsComplianceReviewAuditEvent>();
            var allEvidenceIdentities = new HashSet<string>(StringComparer.Ordinal);

            foreach (var incident in rawIncidents)
            {
                foreach (var evidenceId in incident.InitialEvidenceIdentitySha256s)
                {
                    allEvidenceIdentities.Add(evidenceId);
                }

            }

            foreach (var auditEvent in snapshot.AuditEvents)
            {
                foreach (var evidenceId in auditEvent.EvidenceIdentitySha256s)
                {
                    allEvidenceIdentities.Add(evidenceId);
                }

                allAuditEvents.Add(MapAuditEvent(auditEvent, redactor));
            }

            if (allAuditEvents.Count > ComplianceReviewRuntimeTraceContract.MaximumAuditEvents)
            {
                error.WriteLine($"Audit event count {allAuditEvents.Count} exceeds maximum bound of {ComplianceReviewRuntimeTraceContract.MaximumAuditEvents}.");
                return RuntimeFailureExitCode;
            }

            if (allEvidenceIdentities.Count > ComplianceReviewRuntimeTraceContract.MaximumEvidenceLinks)
            {
                error.WriteLine($"Evidence identity count {allEvidenceIdentities.Count} exceeds maximum bound of {ComplianceReviewRuntimeTraceContract.MaximumEvidenceLinks}.");
                return RuntimeFailureExitCode;
            }

            var mappedIncidents = rawIncidents.Select(MapIncident).ToArray();
            var durableReviewEnabled = snapshot.SchemaVersion >= 4;
            var retentionProtectedObserved = snapshot.RetentionObservations
                .Any(observation => observation.IsProtectedFromPurge && observation.HasOpenIncident);
            var restartConsistencyObserved = durableReviewEnabled &&
                DetermineRestartConsistency(rawIncidents, snapshot.AuditEvents);
            var finishedUtc = DateTimeOffset.UtcNow;

            var report = new ComplianceReviewRuntimeTraceReport(
                ContractVersion: ComplianceReviewRuntimeTraceContract.Version,
                EvidenceClassification: classification,
                RuntimeObserved: false,
                SessionControlInvoked: false,
                RestartObserved: false,
                ReconnectObserved: false,
                DurableReviewEnabled: durableReviewEnabled,
                RetentionProtectedObserved: retentionProtectedObserved,
                RestartConsistencyObserved: restartConsistencyObserved,
                DatabasePath: CreatePathToken(databasePath),
                DatabaseFileSha256: snapshot.DatabaseFileSha256,
                DatabaseFileSizeBytes: snapshot.DatabaseFileSizeBytes,
                SchemaVersion: snapshot.SchemaVersion,
                ProductAssemblySha256: productAssemblySha256,
                HostName: ComplianceReviewRuntimeTraceContract.RedactedMachineValue,
                OperatingSystem: ComplianceReviewRuntimeTraceContract.RedactedMachineValue,
                ProducerProcessId: Environment.ProcessId,
                StartedUtc: startedUtc,
                FinishedUtc: finishedUtc,
                IncidentCount: mappedIncidents.Length,
                AuditEventCount: allAuditEvents.Count,
                EvidenceLinkCount: allEvidenceIdentities.Count,
                Incidents: mappedIncidents,
                AuditEvents: allAuditEvents,
                RetentionObservations: snapshot.RetentionObservations,
                EvidenceBoundary: ComplianceReviewRuntimeTraceContract.EvidenceBoundaryText);

            var json = JsonSerializer.Serialize(report, SerializerOptions) + Environment.NewLine;
            var jsonBytes = Encoding.UTF8.GetBytes(json);
            if (jsonBytes.Length > ComplianceReviewRuntimeTraceContract.MaximumReportBytes)
            {
                error.WriteLine($"Serialized trace report exceeds maximum bound of {ComplianceReviewRuntimeTraceContract.MaximumReportBytes} bytes.");
                return RuntimeFailureExitCode;
            }

            new AtomicSchemaOutputWriter().Write(
                reportPath,
                jsonBytes);
            output.Write(json);
            return SuccessExitCode;
        }
        catch (Exception exception) when (
            exception is SqliteException or
                HerdrStateStoreException or
                ComplianceReviewContractException or
                IOException or
                ArgumentException or
                InvalidOperationException or
                UnauthorizedAccessException)
        {
            error.WriteLine($"Compliance review runtime trace failed: {exception.Message}");
            return RuntimeFailureExitCode;
        }
    }

    private static HerdrOpsComplianceReviewIncident MapIncident(ComplianceReviewIncident incident) =>
        new(
            incident.ContractVersion,
            incident.IncidentId,
            incident.TaskId,
            incident.SubjectActorId,
            incident.RegisteredUtc,
            incident.InitialEvidenceIdentitySha256s,
            incident.RegistrationSha256,
            (int)incident.State,
            incident.Sequence,
            incident.UpdatedUtc,
            incident.LastAuditEventId,
            incident.LastAuditSha256);

    private static HerdrOpsComplianceReviewAuditEvent MapAuditEvent(
        ComplianceReviewAuditEvent auditEvent,
        SensitiveTextRedactor redactor)
    {
        var redactedReason = redactor.Redact(auditEvent.Reason).RedactedText;
        return new HerdrOpsComplianceReviewAuditEvent(
            auditEvent.ContractVersion,
            auditEvent.AuditEventId,
            auditEvent.IncidentId,
            auditEvent.TaskId,
            auditEvent.SubjectActorId,
            auditEvent.Sequence,
            auditEvent.ReviewerActorId,
            (int)auditEvent.ReviewerRole,
            auditEvent.AuthorityProvenanceEventId,
            auditEvent.AuthorityProvenanceSequence,
            auditEvent.AuthorityProvenanceSha256,
            (int)auditEvent.DecisionKind,
            (int)auditEvent.PreviousState,
            (int)auditEvent.ResultState,
            redactedReason,
            auditEvent.OccurredUtc,
            auditEvent.EvidenceIdentitySha256s,
            auditEvent.EvidenceSetSha256,
            auditEvent.PreviousAuditSha256,
            auditEvent.AuditSha256);
    }

    private static DateTimeOffset? ComputeEarliestObservedUtc(
        IReadOnlyList<ComplianceReviewIncident> incidents,
        IReadOnlyList<ComplianceReviewAuditEvent> auditEvents)
    {
        var observedAny = false;
        var earliest = DateTimeOffset.MaxValue;
        foreach (var incident in incidents)
        {
            observedAny = true;
            if (incident.RegisteredUtc < earliest)
            {
                earliest = incident.RegisteredUtc;
            }
        }

        foreach (var auditEvent in auditEvents)
        {
            observedAny = true;
            if (auditEvent.OccurredUtc < earliest)
            {
                earliest = auditEvent.OccurredUtc;
            }
        }

        return observedAny ? earliest : null;
    }

    private static bool DetermineRestartConsistency(
        IReadOnlyList<ComplianceReviewIncident> incidents,
        IReadOnlyList<ComplianceReviewAuditEvent> auditEvents)
    {
        var byIncidentId = auditEvents
            .GroupBy(auditEvent => auditEvent.IncidentId, StringComparer.Ordinal)
            .ToDictionary(group => group.Key, group => group.ToList(), StringComparer.Ordinal);

        foreach (var incident in incidents)
        {
            if (incident.LastAuditSha256 is null)
            {
                if (HasStrayChainState(incident, byIncidentId))
                {
                    return false;
                }

                continue;
            }

            if (!byIncidentId.TryGetValue(incident.IncidentId, out var chain))
            {
                return false;
            }

            var ordered = chain.OrderBy(auditEvent => auditEvent.Sequence).ToArray();
            if (ordered.Length != chain.Count ||
                ordered.Length != incident.Sequence ||
                ordered[0].Sequence != 1)
            {
                return false;
            }

            for (var index = 0; index < ordered.Length; index++)
            {
                if (ordered[index].Sequence != index + 1)
                {
                    return false;
                }

                if (index > 0 &&
                    !string.Equals(
                        ordered[index].PreviousAuditSha256,
                        ordered[index - 1].AuditSha256,
                        StringComparison.Ordinal))
                {
                    return false;
                }
            }

            if (!string.Equals(
                    ordered[^1].AuditSha256,
                    incident.LastAuditSha256,
                    StringComparison.Ordinal))
            {
                return false;
            }
        }

        return true;
    }

    private static bool HasStrayChainState(
        ComplianceReviewIncident incident,
        IReadOnlyDictionary<string, List<ComplianceReviewAuditEvent>> byIncidentId) =>
        incident.Sequence != 0 ||
        byIncidentId.ContainsKey(incident.IncidentId) ||
        incident.State != ComplianceReviewState.Suspected;

    private static string ComputeProductAssemblySha256()
    {
        var location = typeof(ComplianceReviewRuntimeTraceCommand).Assembly.Location;
        return ComputeProductAssemblySha256ForLocation(
            location,
            File.ReadAllBytes,
            bytes => SHA256.HashData(bytes));
    }

    // Internal deterministic seam for hostile identity tests. Production always
    // supplies the real Assembly.Location and File.ReadAllBytes.
    internal static string ComputeProductAssemblySha256ForTesting(
        string? location,
        Func<string, byte[]>? readAllBytes = null,
        Func<byte[], byte[]>? computeHash = null) =>
        ComputeProductAssemblySha256ForLocation(
            location,
            readAllBytes ?? File.ReadAllBytes,
            computeHash ?? (bytes => SHA256.HashData(bytes)));

    private static string ComputeProductAssemblySha256ForLocation(
        string? location,
        Func<string, byte[]> readAllBytes,
        Func<byte[], byte[]> computeHash)
    {
        ArgumentNullException.ThrowIfNull(readAllBytes);
        ArgumentNullException.ThrowIfNull(computeHash);
        if (string.IsNullOrWhiteSpace(location))
        {
            throw new InvalidOperationException(
                "Product assembly identity cannot be established because Assembly.Location is blank.");
        }

        if (!Path.IsPathFullyQualified(location))
        {
            throw new InvalidOperationException(
                "Product assembly identity cannot be established because Assembly.Location is not absolute.");
        }

        try
        {
            var attributes = File.GetAttributes(location);
            if (attributes.HasFlag(FileAttributes.Directory) ||
                attributes.HasFlag(FileAttributes.ReparsePoint))
            {
                throw new InvalidOperationException(
                    "Product assembly identity cannot be established because Assembly.Location is not a regular file.");
            }

            var beforeRead = new FileInfo(location);
            if (!beforeRead.Exists || beforeRead.Length <= 0)
            {
                throw new InvalidOperationException(
                    "Product assembly identity cannot be established because Assembly.Location is not a readable regular file.");
            }

            var bytes = readAllBytes(location);
            if (bytes is null || bytes.Length == 0)
            {
                throw new InvalidOperationException(
                    "Product assembly identity cannot be established because the assembly file is empty.");
            }

            var afterRead = new FileInfo(location);
            if (!afterRead.Exists ||
                afterRead.Length != bytes.LongLength ||
                afterRead.LastWriteTimeUtc != beforeRead.LastWriteTimeUtc ||
                afterRead.Attributes.HasFlag(FileAttributes.Directory) ||
                afterRead.Attributes.HasFlag(FileAttributes.ReparsePoint))
            {
                throw new InvalidOperationException(
                    "Product assembly identity cannot be established because the assembly file changed while hashing.");
            }

            var hash = computeHash(bytes);
            if (hash is null || hash.Length != SHA256.HashSizeInBytes || hash.All(value => value == 0))
            {
                throw new InvalidOperationException(
                    "Product assembly identity hashing returned an invalid hash.");
            }

            return Convert.ToHexString(hash);
        }
        catch (Exception exception) when (
            exception is IOException or
                UnauthorizedAccessException or
                ArgumentException or
                NotSupportedException or
                System.Security.SecurityException or
                CryptographicException)
        {
            throw new InvalidOperationException(
                "Product assembly identity could not be read or hashed; the trace must fail closed.",
                exception);
        }
    }

    private static string CreatePathToken(string path) =>
        "path-sha256:" + Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(path)));

    private static void WriteUsage(TextWriter writer)
    {
        writer.WriteLine(
            "Usage: HerdrOps.Core trace-compliance-review --database <sqlite-db-path> --report <output-json-path> [--task-id <task-id>] [--incident <incident-id> ...] [--evidence-classification BuiltProcessIntegration|Synthetic]");
    }
}
