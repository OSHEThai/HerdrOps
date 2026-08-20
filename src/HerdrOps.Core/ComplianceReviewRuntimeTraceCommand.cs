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
/// Produces a fail-closed, bounded compliance review runtime trace report from a durable SQLite state store database.
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

        var startedUtc = DateTimeOffset.UtcNow;
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
            var databaseBytes = File.ReadAllBytes(databasePath);
            var databaseSha256 = Convert.ToHexString(SHA256.HashData(databaseBytes));
            var productAssemblySha256 = ComputeProductAssemblySha256();

            // Validate SQLite schema version and tables fail-closed before reading
            var schemaVersion = ValidateDatabaseSchema(databasePath);
            if (schemaVersion < 4)
            {
                error.WriteLine($"Database schema version {schemaVersion} is unsupported; expected schema version 4+ with compliance review tables.");
                return RuntimeFailureExitCode;
            }

            var storeOptions = new HerdrStateStoreOptions(databasePath);
            using var store = new SqliteHerdrStateStore(storeOptions);

            var rawIncidents = store.ReadAllComplianceReviewIncidents(
                taskIdFilter,
                incidentFilters.Count > 0 ? incidentFilters : null);

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

                var rawAuditEvents = store.ReadComplianceReviewAudit(incident.IncidentId);
                foreach (var auditEvent in rawAuditEvents)
                {
                    foreach (var evidenceId in auditEvent.EvidenceIdentitySha256s)
                    {
                        allEvidenceIdentities.Add(evidenceId);
                    }

                    allAuditEvents.Add(MapAuditEvent(auditEvent, redactor));
                }
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

            var retentionObservations = store.ReadComplianceReviewRetentionObservations(
                allEvidenceIdentities.OrderBy(id => id, StringComparer.Ordinal).ToArray());

            var mappedIncidents = rawIncidents.Select(MapIncident).ToArray();
            var finishedUtc = DateTimeOffset.UtcNow;

            var report = new ComplianceReviewRuntimeTraceReport(
                ContractVersion: ComplianceReviewRuntimeTraceContract.Version,
                EvidenceClassification: classification,
                RuntimeObserved: false,
                SessionControlInvoked: false,
                RestartObserved: false,
                ReconnectObserved: false,
                DatabasePath: CreatePathToken(databasePath),
                DatabaseFileSha256: databaseSha256,
                DatabaseFileSizeBytes: databaseInfo.Length,
                SchemaVersion: schemaVersion,
                ProductAssemblySha256: productAssemblySha256,
                HostName: ComplianceReviewRuntimeTraceContract.RedactedMachineValue,
                OperatingSystem: ComplianceReviewRuntimeTraceContract.RedactedMachineValue,
                ProcessId: Environment.ProcessId,
                StartedUtc: startedUtc,
                FinishedUtc: finishedUtc,
                IncidentCount: mappedIncidents.Length,
                AuditEventCount: allAuditEvents.Count,
                EvidenceLinkCount: allEvidenceIdentities.Count,
                Incidents: mappedIncidents,
                AuditEvents: allAuditEvents,
                RetentionObservations: retentionObservations,
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

    private static int ValidateDatabaseSchema(string databasePath)
    {
        using var connection = new SqliteConnection(new SqliteConnectionStringBuilder
        {
            DataSource = databasePath,
            Mode = SqliteOpenMode.ReadOnly,
            Pooling = false,
        }.ToString());
        connection.Open();

        using var versionCommand = connection.CreateCommand();
        versionCommand.CommandText = "PRAGMA user_version;";
        var versionScalar = versionCommand.ExecuteScalar();
        if (versionScalar is null || versionScalar is DBNull)
        {
            throw new HerdrStateStoreException("Could not read database user_version PRAGMA.");
        }

        var schemaVersion = Convert.ToInt32(versionScalar, System.Globalization.CultureInfo.InvariantCulture);
        if (schemaVersion < 4)
        {
            return schemaVersion;
        }

        using var tableCommand = connection.CreateCommand();
        tableCommand.CommandText = """
            SELECT name
            FROM sqlite_master
            WHERE type = 'table'
              AND name IN (
                  'compliance_review_incidents',
                  'compliance_review_incident_evidence',
                  'compliance_review_events',
                  'compliance_review_event_evidence');
            """;
        var tableNames = new HashSet<string>(StringComparer.Ordinal);
        using (var reader = tableCommand.ExecuteReader())
        {
            while (reader.Read())
            {
                tableNames.Add(reader.GetString(0));
            }
        }

        if (tableNames.Count < 4)
        {
            throw new HerdrStateStoreException(
                $"Database is missing required compliance review tables; found {tableNames.Count}/4.");
        }

        return schemaVersion;
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

    private static string ComputeProductAssemblySha256()
    {
        var location = typeof(ComplianceReviewRuntimeTraceCommand).Assembly.Location;
        if (!string.IsNullOrWhiteSpace(location) && File.Exists(location))
        {
            return Convert.ToHexString(SHA256.HashData(File.ReadAllBytes(location)));
        }

        return new string('0', 64);
    }

    private static string CreatePathToken(string path) =>
        "path-sha256:" + Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(path)));

    private static void WriteUsage(TextWriter writer)
    {
        writer.WriteLine(
            "Usage: HerdrOps.Core trace-compliance-review --database <sqlite-db-path> --report <output-json-path> [--task-id <task-id>] [--incident <incident-id> ...] [--evidence-classification BuiltProcessIntegration|Synthetic]");
    }
}
