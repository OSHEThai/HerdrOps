using System.Text.Json;
using HerdrOps.Domain.Assignments;
using HerdrOps.Domain.Compliance;
using Microsoft.Data.Sqlite;
using SQLitePCL;

namespace HerdrOps.Infrastructure.Storage;

public sealed partial class SqliteHerdrStateStore
{
    private const int ComplianceReviewBusyTimeoutCeilingSeconds = 1;
    private const int ComplianceReviewBusySliceMilliseconds = 50;
    private const int SqliteLockedSharedCache = 262;
    private const int SqliteBusySnapshot = 517;
    private const string ComplianceReviewWriteLockSliceSql = """
        INSERT OR IGNORE INTO compliance_review_incidents(
            incident_id,
            contract_version,
            task_id,
            subject_actor_id,
            registered_utc,
            registration_sha256,
            registration_json,
            state,
            sequence,
            updated_utc,
            last_audit_event_id,
            last_audit_sha256)
        SELECT incident_id,
               contract_version,
               task_id,
               subject_actor_id,
               registered_utc,
               registration_sha256,
               registration_json,
               state,
               sequence,
               updated_utc,
               last_audit_event_id,
               last_audit_sha256
        FROM compliance_review_incidents
        WHERE incident_id = $incidentId;
        """;
    private bool _complianceReviewSqlFunctionsRegistered;

    // Internal diagnostic hook (InternalsVisibleTo: HerdrOps.IntegrationTests).
    // Raised only after the write-lock slice statement actually entered the
    // SQLite step and returned BUSY/LOCKED, and the failed slice was rolled
    // back, so tests can prove real SQLite contention and cancel
    // deterministically without reflection, sleeps, or timing probes.
    internal event Action? ComplianceReviewBusySliceObserved;

    public HerdrComplianceReviewRegistrationResult RegisterComplianceReviewIncident(
        ComplianceReviewIncidentRegistration registration)
    {
        var candidate = ComplianceReviewWorkflowContract.CreateIncident(registration);
        lock (_sync)
        {
            ThrowIfDisposed();
            EnsureComplianceReviewSqlFunctions();
            using var transaction = _connection.BeginTransaction(deferred: false);
            var existing = ReadComplianceReviewIncidentCore(
                candidate.IncidentId,
                transaction);
            if (existing is not null)
            {
                EnsureSameRegistration(candidate, existing);
                ValidateComplianceReviewHistory(existing, transaction);
                transaction.Commit();
                return new HerdrComplianceReviewRegistrationResult(
                    existing,
                    WasAlreadyPresent: true);
            }

            EnsureEvidenceLinksExist(
                candidate.InitialEvidenceIdentitySha256s,
                transaction);
            using (var command = _connection.CreateCommand())
            {
                command.Transaction = transaction;
                command.CommandText = """
                    INSERT INTO compliance_review_incidents(
                        incident_id,
                        contract_version,
                        task_id,
                        subject_actor_id,
                        registered_utc,
                        registration_sha256,
                        registration_json,
                        state,
                        sequence,
                        updated_utc,
                        last_audit_event_id,
                        last_audit_sha256)
                    VALUES (
                        $incidentId,
                        $contractVersion,
                        $taskId,
                        $subjectActorId,
                        $registeredUtc,
                        $registrationSha256,
                        $registrationJson,
                        $state,
                        0,
                        $updatedUtc,
                        NULL,
                        NULL);
                    """;
                command.Parameters.AddWithValue("$incidentId", candidate.IncidentId);
                command.Parameters.AddWithValue("$contractVersion", candidate.ContractVersion);
                command.Parameters.AddWithValue("$taskId", candidate.TaskId);
                command.Parameters.AddWithValue("$subjectActorId", candidate.SubjectActorId);
                command.Parameters.AddWithValue("$registeredUtc", FormatUtc(candidate.RegisteredUtc));
                command.Parameters.AddWithValue("$registrationSha256", candidate.RegistrationSha256);
                command.Parameters.AddWithValue(
                    "$registrationJson",
                    SerializeComplianceReviewRegistration(candidate));
                command.Parameters.AddWithValue("$state", (int)candidate.State);
                command.Parameters.AddWithValue("$updatedUtc", FormatUtc(candidate.UpdatedUtc));
                command.ExecuteNonQuery();
            }

            InsertComplianceReviewEvidenceLinks(
                "compliance_review_incident_evidence",
                "incident_id",
                candidate.IncidentId,
                candidate.InitialEvidenceIdentitySha256s,
                transaction);
            transaction.Commit();
            return new HerdrComplianceReviewRegistrationResult(
                candidate,
                WasAlreadyPresent: false);
        }
    }

    public ComplianceReviewIncident? ReadComplianceReviewIncident(
        string incidentId,
        CancellationToken cancellationToken = default)
    {
        cancellationToken.ThrowIfCancellationRequested();
        incidentId = NormalizeComplianceReviewIdentifier(incidentId, nameof(incidentId));
        EnterComplianceReviewLock(cancellationToken);
        try
        {
            ThrowIfDisposed();
            cancellationToken.ThrowIfCancellationRequested();
            using var transaction = _connection.BeginTransaction();
            var incident = ReadComplianceReviewIncidentCore(
                incidentId,
                transaction,
                cancellationToken);
            if (incident is not null)
            {
                ValidateComplianceReviewHistory(
                    incident,
                    transaction,
                    cancellationToken);
            }

            cancellationToken.ThrowIfCancellationRequested();
            transaction.Commit();
            return incident;
        }
        finally
        {
            Monitor.Exit(_sync);
        }
    }

    public IReadOnlyList<ComplianceReviewAuditEvent> ReadComplianceReviewAudit(
        string incidentId)
    {
        incidentId = NormalizeComplianceReviewIdentifier(incidentId, nameof(incidentId));
        lock (_sync)
        {
            ThrowIfDisposed();
            using var transaction = _connection.BeginTransaction();
            var incident = ReadComplianceReviewIncidentCore(incidentId, transaction)
                ?? throw new HerdrStateStoreException(
                    $"Compliance review incident '{incidentId}' does not exist.");
            var events = ReadComplianceReviewAuditCore(incidentId, transaction);
            ValidateComplianceReviewHistory(incident, events);
            transaction.Commit();
            return events;
        }
    }

    public HerdrComplianceReviewCapabilities ReadComplianceReviewCapabilities(
        string reviewerActorId,
        string incidentId,
        DateTimeOffset observedUtc,
        Func<AssignmentCurrentActorRole?, ComplianceReviewAuthority?> authorityResolver,
        CancellationToken cancellationToken = default)
    {
        cancellationToken.ThrowIfCancellationRequested();
        ArgumentNullException.ThrowIfNull(authorityResolver);
        reviewerActorId = ComplianceReviewWorkflowContract.NormalizeActorId(reviewerActorId);
        incidentId = ComplianceReviewWorkflowContract.NormalizeIncidentId(incidentId);
        if (observedUtc.Offset != TimeSpan.Zero)
        {
            throw new ArgumentException(
                "The review-capability observation time must be UTC.",
                nameof(observedUtc));
        }

        EnterComplianceReviewLock(cancellationToken);
        try
        {
            ThrowIfDisposed();
            cancellationToken.ThrowIfCancellationRequested();
            using var transaction = _connection.BeginTransaction();
            var incident = ReadComplianceReviewIncidentCore(
                incidentId,
                transaction,
                cancellationToken);
            if (incident is null)
            {
                cancellationToken.ThrowIfCancellationRequested();
                transaction.Commit();
                return new HerdrComplianceReviewCapabilities(
                    Incident: null,
                    ReviewerRole: null,
                    AllowedDecisions: []);
            }

            ValidateComplianceReviewHistory(
                incident,
                transaction,
                cancellationToken);
            var currentRole = ReadCurrentAssignmentRoleCore(
                reviewerActorId,
                transaction,
                cancellationToken);
            cancellationToken.ThrowIfCancellationRequested();
            var authority = authorityResolver(currentRole);
            if (authority is null)
            {
                transaction.Commit();
                return new HerdrComplianceReviewCapabilities(
                    incident,
                    ReviewerRole: null,
                    AllowedDecisions: []);
            }

            var normalizedAuthority = ComplianceReviewWorkflowContract.NormalizeAuthority(
                authority);
            var allowed = Enum.GetValues<ComplianceReviewDecisionKind>()
                .Where(decision =>
                {
                    cancellationToken.ThrowIfCancellationRequested();
                    return ComplianceReviewWorkflowContract.Authorize(
                        incident,
                        new ComplianceReviewCommand(
                            ComplianceReviewWorkflowContract.ContractVersion,
                            CapabilityCommandId(decision),
                            incident.IncidentId,
                            incident.State,
                            incident.Sequence,
                            reviewerActorId,
                            decision,
                            "Capability evaluation.",
                            observedUtc,
                            []),
                        normalizedAuthority).IsAuthorized;
                })
                .ToArray();
            cancellationToken.ThrowIfCancellationRequested();
            transaction.Commit();
            return new HerdrComplianceReviewCapabilities(
                incident,
                normalizedAuthority.Role,
                allowed);
        }
        finally
        {
            Monitor.Exit(_sync);
        }
    }

    internal HerdrComplianceReviewWriteResult ApplyComplianceReviewCommand(
        ComplianceReviewCommand command,
        ComplianceReviewAuthority authority,
        CancellationToken cancellationToken = default)
    {
        cancellationToken.ThrowIfCancellationRequested();
        var normalizedCommand = ComplianceReviewWorkflowContract.NormalizeCommand(command);
        var normalizedAuthority = ComplianceReviewWorkflowContract.NormalizeAuthority(authority);
        EnterComplianceReviewLock(cancellationToken);
        try
        {
            ThrowIfDisposed();
            cancellationToken.ThrowIfCancellationRequested();
            EnsureComplianceReviewSqlFunctions();
            using var transaction = BeginComplianceReviewWriteTransaction(
                normalizedCommand.IncidentId,
                cancellationToken);
            var existingEvent = ReadComplianceReviewAuditEventById(
                normalizedCommand.CommandId,
                transaction,
                cancellationToken);
            if (existingEvent is not null)
            {
                EnsureSameComplianceReviewCommand(
                    normalizedCommand,
                    normalizedAuthority,
                    existingEvent);
                var currentIncident = ReadComplianceReviewIncidentCore(
                    existingEvent.IncidentId,
                    transaction,
                    cancellationToken)
                    ?? throw new HerdrStateStoreException(
                        $"Compliance review incident '{existingEvent.IncidentId}' disappeared during an idempotent command read.");
                ValidateComplianceReviewHistory(
                    currentIncident,
                    transaction,
                    cancellationToken);
                cancellationToken.ThrowIfCancellationRequested();
                transaction.Commit();
                return new HerdrComplianceReviewWriteResult(
                    currentIncident,
                    existingEvent,
                    WasAlreadyPresent: true);
            }

            var result = AppendComplianceReviewCommand(
                normalizedCommand,
                normalizedAuthority,
                transaction,
                cancellationToken);
            cancellationToken.ThrowIfCancellationRequested();
            transaction.Commit();
            return result;
        }
        finally
        {
            Monitor.Exit(_sync);
        }
    }

    public HerdrComplianceReviewWriteResult ApplyComplianceReviewCommandWithCurrentAuthority(
        ComplianceReviewCommand command,
        Func<AssignmentCurrentActorRole?, ComplianceReviewAuthority?> authorityResolver,
        CancellationToken cancellationToken = default)
    {
        cancellationToken.ThrowIfCancellationRequested();
        ArgumentNullException.ThrowIfNull(authorityResolver);
        var normalizedCommand = ComplianceReviewWorkflowContract.NormalizeCommand(command);
        EnterComplianceReviewLock(cancellationToken);
        try
        {
            ThrowIfDisposed();
            cancellationToken.ThrowIfCancellationRequested();
            EnsureComplianceReviewSqlFunctions();
            using var transaction = BeginComplianceReviewWriteTransaction(
                normalizedCommand.IncidentId,
                cancellationToken);
            var existingEvent = ReadComplianceReviewAuditEventById(
                normalizedCommand.CommandId,
                transaction,
                cancellationToken);
            if (existingEvent is not null)
            {
                EnsureSameComplianceReviewCommandPayload(
                    normalizedCommand,
                    existingEvent,
                    compareOccurredUtc: false);
                var currentIncident = ReadComplianceReviewIncidentCore(
                    existingEvent.IncidentId,
                    transaction,
                    cancellationToken)
                    ?? throw new HerdrStateStoreException(
                        $"Compliance review incident '{existingEvent.IncidentId}' disappeared during an idempotent command read.");
                ValidateComplianceReviewHistory(
                    currentIncident,
                    transaction,
                    cancellationToken);
                cancellationToken.ThrowIfCancellationRequested();
                transaction.Commit();
                return new HerdrComplianceReviewWriteResult(
                    currentIncident,
                    existingEvent,
                    WasAlreadyPresent: true);
            }

            var currentRole = ReadCurrentAssignmentRoleCore(
                normalizedCommand.ReviewerActorId,
                transaction,
                cancellationToken);
            cancellationToken.ThrowIfCancellationRequested();
            var authority = authorityResolver(currentRole);
            if (authority is null)
            {
                throw new ComplianceReviewRejectedException(
                    ComplianceReviewRejectionCode.UnknownAuthority,
                    "The reviewer has no current admitted Project Manager or Leader role provenance.");
            }

            var result = AppendComplianceReviewCommand(
                normalizedCommand,
                ComplianceReviewWorkflowContract.NormalizeAuthority(authority),
                transaction,
                cancellationToken);
            cancellationToken.ThrowIfCancellationRequested();
            transaction.Commit();
            return result;
        }
        finally
        {
            Monitor.Exit(_sync);
        }
    }

    private HerdrComplianceReviewWriteResult AppendComplianceReviewCommand(
        ComplianceReviewCommand command,
        ComplianceReviewAuthority authority,
        SqliteTransaction transaction,
        CancellationToken cancellationToken = default)
    {
        cancellationToken.ThrowIfCancellationRequested();
        var incident = ReadComplianceReviewIncidentCore(
                command.IncidentId,
                transaction,
                cancellationToken)
            ?? throw new HerdrStateStoreException(
                $"Compliance review incident '{command.IncidentId}' does not exist.");
        ValidateComplianceReviewHistory(
            incident,
            transaction,
            cancellationToken);
        cancellationToken.ThrowIfCancellationRequested();
        var auditEvent = ComplianceReviewWorkflowContract.CreateAuditEvent(
            incident,
            command,
            authority);
        cancellationToken.ThrowIfCancellationRequested();
        EnsureEvidenceLinksExist(auditEvent.EvidenceIdentitySha256s, transaction);
        cancellationToken.ThrowIfCancellationRequested();
        InsertComplianceReviewAuditEvent(auditEvent, transaction, cancellationToken);
        InsertComplianceReviewEvidenceLinks(
            "compliance_review_event_evidence",
            "audit_event_id",
            auditEvent.AuditEventId.ToString("D"),
            auditEvent.EvidenceIdentitySha256s,
            transaction,
            cancellationToken);

        var updated = ReadComplianceReviewIncidentCore(
            incident.IncidentId,
            transaction,
            cancellationToken)
            ?? throw new HerdrStateStoreException(
                $"Compliance review incident '{incident.IncidentId}' disappeared after an accepted decision.");
        var expected = ComplianceReviewWorkflowContract.Apply(incident, auditEvent);
        EnsureSameCurrentIncident(expected, updated);
        return new HerdrComplianceReviewWriteResult(
            updated,
            auditEvent,
            WasAlreadyPresent: false);
    }

    private AssignmentCurrentActorRole? ReadCurrentAssignmentRoleCore(
        string actorId,
        SqliteTransaction transaction,
        CancellationToken cancellationToken = default)
    {
        cancellationToken.ThrowIfCancellationRequested();
        using var command = _connection.CreateCommand();
        command.Transaction = transaction;
        command.CommandText = """
            SELECT actor_id, actor_role, task_id, event_id, sequence,
                   accepted_utc, provenance_event_sha256, state_sha256
            FROM assignment_current_actor_roles
            WHERE actor_id = $actorId;
            """;
        command.Parameters.AddWithValue("$actorId", actorId);
        AssignmentCurrentActorRole? role = null;
        ConfigureComplianceReviewCommand(command, cancellationToken);
        using (var reader = command.ExecuteReader())
        {
            if (reader.Read())
            {
                role = new AssignmentCurrentActorRole(
                    AssignmentLifecycleContract.Version,
                    reader.GetString(0),
                    reader.GetString(1),
                    reader.GetString(2),
                    ParseGuid(reader.GetString(3), "event_id"),
                    reader.GetInt64(4),
                    ParseUtc(reader.GetString(5)),
                    reader.GetString(6),
                    reader.GetString(7));
                if (reader.Read())
                {
                    throw new HerdrStateStoreException(
                        $"Actor '{actorId}' has duplicate current assignment roles.");
                }
            }
        }

        cancellationToken.ThrowIfCancellationRequested();

        if (role is null)
        {
            return null;
        }

        var storedEvent = ReadComplianceReviewAssignmentLifecycleEvent(
                transaction,
                role.Sequence,
                cancellationToken)
            ?? throw new HerdrStateStoreException(
                $"Current assignment role for '{actorId}' has no provenance event.");
        var observation = AssignmentLifecycleContract.CreateRoleObservation(
            storedEvent.NormalizedEvent);
        try
        {
            AssignmentLifecycleContract.ValidateCurrentRole(role, observation);
        }
        catch (AssignmentLifecycleContractException exception)
        {
            throw new HerdrStateStoreException(
                $"Current assignment role for '{actorId}' failed provenance validation.",
                exception);
        }

        using var latest = _connection.CreateCommand();
        latest.Transaction = transaction;
        latest.CommandText = """
            SELECT MAX(sequence)
            FROM assignment_actor_role_history
            WHERE actor_id = $actorId;
            """;
        latest.Parameters.AddWithValue("$actorId", actorId);
        ConfigureComplianceReviewCommand(latest, cancellationToken);
        var latestSequence = latest.ExecuteScalar();
        cancellationToken.ThrowIfCancellationRequested();
        if (latestSequence is null or DBNull ||
            Convert.ToInt64(latestSequence, System.Globalization.CultureInfo.InvariantCulture) != role.Sequence)
        {
            throw new HerdrStateStoreException(
                $"Current assignment role for '{actorId}' is not the latest immutable role observation.");
        }

        return role;
    }

    private ComplianceReviewIncident? ReadComplianceReviewIncidentCore(
        string incidentId,
        SqliteTransaction transaction,
        CancellationToken cancellationToken = default)
    {
        cancellationToken.ThrowIfCancellationRequested();
        using var command = _connection.CreateCommand();
        command.Transaction = transaction;
        command.CommandText = """
            SELECT contract_version,
                   incident_id,
                   task_id,
                   subject_actor_id,
                   registered_utc,
                   registration_sha256,
                   registration_json,
                   state,
                   sequence,
                   updated_utc,
                   last_audit_event_id,
                   last_audit_sha256
            FROM compliance_review_incidents
            WHERE incident_id = $incidentId;
            """;
        command.Parameters.AddWithValue("$incidentId", incidentId);
        ConfigureComplianceReviewCommand(command, cancellationToken);
        using var reader = command.ExecuteReader();
        if (!reader.Read())
        {
            return null;
        }

        var row = new ComplianceReviewIncident(
            reader.GetInt32(0),
            reader.GetString(1),
            reader.GetString(2),
            reader.GetString(3),
            ParseUtc(reader.GetString(4)),
            Array.Empty<string>(),
            reader.GetString(5),
            (ComplianceReviewState)reader.GetInt32(7),
            reader.GetInt64(8),
            ParseUtc(reader.GetString(9)),
            reader.IsDBNull(10) ? null : ParseGuid(reader.GetString(10), "last_audit_event_id"),
            reader.IsDBNull(11) ? null : reader.GetString(11));
        var registrationJson = reader.GetString(6);
        if (reader.Read())
        {
            throw new HerdrStateStoreException(
                $"Compliance review incident '{incidentId}' has duplicate current rows.");
        }

        var evidence = ReadComplianceReviewEvidenceLinks(
            "compliance_review_incident_evidence",
            "incident_id",
            incidentId,
            transaction,
            cancellationToken);
        cancellationToken.ThrowIfCancellationRequested();
        try
        {
            var normalized = ComplianceReviewWorkflowContract.NormalizeAndValidateIncident(
                row with { InitialEvidenceIdentitySha256s = evidence });
            if (!string.Equals(
                    registrationJson,
                    SerializeComplianceReviewRegistration(normalized),
                    StringComparison.Ordinal))
            {
                throw new HerdrStateStoreException(
                    $"Compliance review incident '{incidentId}' registration JSON, columns, or evidence links disagree.");
            }

            return normalized;
        }
        catch (ComplianceReviewContractException exception)
        {
            throw new HerdrStateStoreException(
                $"Compliance review incident '{incidentId}' failed domain validation.",
                exception);
        }
    }

    private IReadOnlyList<ComplianceReviewAuditEvent> ReadComplianceReviewAuditCore(
        string incidentId,
        SqliteTransaction transaction,
        CancellationToken cancellationToken = default)
    {
        cancellationToken.ThrowIfCancellationRequested();
        using var command = _connection.CreateCommand();
        command.Transaction = transaction;
        command.CommandText = """
            SELECT audit_event_id
            FROM compliance_review_events
            WHERE incident_id = $incidentId
            ORDER BY sequence;
            """;
        command.Parameters.AddWithValue("$incidentId", incidentId);
        ConfigureComplianceReviewCommand(command, cancellationToken);
        var ids = new List<Guid>();
        using (var reader = command.ExecuteReader())
        {
            while (reader.Read())
            {
                cancellationToken.ThrowIfCancellationRequested();
                ids.Add(ParseGuid(reader.GetString(0), "audit_event_id"));
            }
        }

        return ids
            .Select(id => ReadComplianceReviewAuditEventById(id, transaction, cancellationToken)
                ?? throw new HerdrStateStoreException(
                    $"Compliance review audit event '{id:D}' disappeared during a locked read."))
            .ToArray();
    }

    private ComplianceReviewAuditEvent? ReadComplianceReviewAuditEventById(
        Guid auditEventId,
        SqliteTransaction transaction,
        CancellationToken cancellationToken = default)
    {
        cancellationToken.ThrowIfCancellationRequested();
        using var command = _connection.CreateCommand();
        command.Transaction = transaction;
        command.CommandText = """
            SELECT contract_version,
                   audit_event_id,
                   incident_id,
                   task_id,
                   subject_actor_id,
                   sequence,
                   reviewer_actor_id,
                   reviewer_role,
                   authority_provenance_event_id,
                   authority_provenance_sequence,
                   authority_provenance_sha256,
                   decision_kind,
                   previous_state,
                   result_state,
                   reason,
                   occurred_utc,
                   evidence_set_sha256,
                   previous_audit_sha256,
                   audit_sha256,
                   audit_json,
                   audit_json_sha256
            FROM compliance_review_events
            WHERE audit_event_id = $auditEventId;
            """;
        command.Parameters.AddWithValue("$auditEventId", auditEventId.ToString("D"));
        ConfigureComplianceReviewCommand(command, cancellationToken);
        StoredComplianceReviewAuditRow row;
        using (var reader = command.ExecuteReader())
        {
            if (!reader.Read())
            {
                return null;
            }

            row = new StoredComplianceReviewAuditRow(
                reader.GetInt32(0),
                ParseGuid(reader.GetString(1), "audit_event_id"),
                reader.GetString(2),
                reader.GetString(3),
                reader.GetString(4),
                reader.GetInt64(5),
                reader.GetString(6),
                (ComplianceReviewerRole)reader.GetInt32(7),
                ParseGuid(reader.GetString(8), "authority_provenance_event_id"),
                reader.GetInt64(9),
                reader.GetString(10),
                (ComplianceReviewDecisionKind)reader.GetInt32(11),
                (ComplianceReviewState)reader.GetInt32(12),
                (ComplianceReviewState)reader.GetInt32(13),
                reader.GetString(14),
                ParseUtc(reader.GetString(15)),
                reader.GetString(16),
                reader.IsDBNull(17) ? null : reader.GetString(17),
                reader.GetString(18),
                reader.GetString(19),
                reader.GetString(20));
            if (reader.Read())
            {
                throw new HerdrStateStoreException(
                    $"Compliance review audit event '{auditEventId:D}' has duplicate rows.");
            }
        }

        if (!string.Equals(
                ComputeUtf8Sha256(row.AuditJson),
                row.AuditJsonSha256,
                StringComparison.Ordinal))
        {
            throw new HerdrStateStoreException(
                $"Compliance review audit event '{auditEventId:D}' JSON hash is invalid.");
        }

        var persisted = DeserializeEvidence<ComplianceReviewAuditEvent>(
            row.AuditJson,
            "compliance review audit event");
        ComplianceReviewAuditEvent normalized;
        try
        {
            normalized = ComplianceReviewWorkflowContract.NormalizeAndValidateAuditEvent(
                persisted);
        }
        catch (ComplianceReviewContractException exception)
        {
            throw new HerdrStateStoreException(
                $"Compliance review audit event '{auditEventId:D}' failed domain validation.",
                exception);
        }

        var evidence = ReadComplianceReviewEvidenceLinks(
            "compliance_review_event_evidence",
            "audit_event_id",
            auditEventId.ToString("D"),
            transaction,
            cancellationToken);
        cancellationToken.ThrowIfCancellationRequested();
        if (!normalized.EvidenceIdentitySha256s.SequenceEqual(evidence, StringComparer.Ordinal) ||
            !row.Matches(normalized))
        {
            throw new HerdrStateStoreException(
                $"Compliance review audit event '{auditEventId:D}' columns, JSON, or evidence links disagree.");
        }

        ValidateComplianceReviewAuthorityProvenance(
            normalized,
            transaction,
            cancellationToken);

        return normalized;
    }

    private void ValidateComplianceReviewAuthorityProvenance(
        ComplianceReviewAuditEvent auditEvent,
        SqliteTransaction transaction,
        CancellationToken cancellationToken = default)
    {
        cancellationToken.ThrowIfCancellationRequested();
        var storedEvent = ReadComplianceReviewAssignmentLifecycleEvent(
            transaction,
            auditEvent.AuthorityProvenanceSequence,
            cancellationToken)
            ?? throw new HerdrStateStoreException(
                $"Compliance review audit event '{auditEvent.AuditEventId:D}' has no assignment authority provenance event.");
        var lifecycleEvent = storedEvent.NormalizedEvent.Event;
        var observation = AssignmentLifecycleContract.CreateRoleObservation(
            storedEvent.NormalizedEvent);
        cancellationToken.ThrowIfCancellationRequested();
        if (lifecycleEvent.EventId != auditEvent.AuthorityProvenanceEventId ||
            !string.Equals(
                lifecycleEvent.ActorId,
                auditEvent.ReviewerActorId,
                StringComparison.Ordinal) ||
            !string.Equals(
                observation.ProvenanceEventSha256,
                auditEvent.AuthorityProvenanceSha256,
                StringComparison.Ordinal) ||
            observation.AcceptedUtc > auditEvent.OccurredUtc ||
            !ComplianceReviewWorkflowContract.TryMapAssignmentRole(
                lifecycleEvent.ActorRole,
                out var reviewerRole) ||
            reviewerRole != auditEvent.ReviewerRole)
        {
            throw new HerdrStateStoreException(
                $"Compliance review audit event '{auditEvent.AuditEventId:D}' does not match its immutable assignment authority provenance.");
        }
    }

    private void InsertComplianceReviewAuditEvent(
        ComplianceReviewAuditEvent auditEvent,
        SqliteTransaction transaction,
        CancellationToken cancellationToken = default)
    {
        cancellationToken.ThrowIfCancellationRequested();
        var auditJson = JsonSerializer.Serialize(auditEvent, EvidenceSerializerOptions);
        using var command = _connection.CreateCommand();
        command.Transaction = transaction;
        command.CommandText = """
            INSERT INTO compliance_review_events(
                audit_event_id,
                contract_version,
                incident_id,
                task_id,
                subject_actor_id,
                sequence,
                reviewer_actor_id,
                reviewer_role,
                authority_provenance_event_id,
                authority_provenance_sequence,
                authority_provenance_sha256,
                decision_kind,
                previous_state,
                result_state,
                reason,
                occurred_utc,
                evidence_set_sha256,
                previous_audit_sha256,
                audit_sha256,
                audit_json,
                audit_json_sha256)
            VALUES (
                $auditEventId,
                $contractVersion,
                $incidentId,
                $taskId,
                $subjectActorId,
                $sequence,
                $reviewerActorId,
                $reviewerRole,
                $authorityProvenanceEventId,
                $authorityProvenanceSequence,
                $authorityProvenanceSha256,
                $decisionKind,
                $previousState,
                $resultState,
                $reason,
                $occurredUtc,
                $evidenceSetSha256,
                $previousAuditSha256,
                $auditSha256,
                $auditJson,
                $auditJsonSha256);
            """;
        command.Parameters.AddWithValue("$auditEventId", auditEvent.AuditEventId.ToString("D"));
        command.Parameters.AddWithValue("$contractVersion", auditEvent.ContractVersion);
        command.Parameters.AddWithValue("$incidentId", auditEvent.IncidentId);
        command.Parameters.AddWithValue("$taskId", auditEvent.TaskId);
        command.Parameters.AddWithValue("$subjectActorId", auditEvent.SubjectActorId);
        command.Parameters.AddWithValue("$sequence", auditEvent.Sequence);
        command.Parameters.AddWithValue("$reviewerActorId", auditEvent.ReviewerActorId);
        command.Parameters.AddWithValue("$reviewerRole", (int)auditEvent.ReviewerRole);
        command.Parameters.AddWithValue(
            "$authorityProvenanceEventId",
            auditEvent.AuthorityProvenanceEventId.ToString("D"));
        command.Parameters.AddWithValue(
            "$authorityProvenanceSequence",
            auditEvent.AuthorityProvenanceSequence);
        command.Parameters.AddWithValue(
            "$authorityProvenanceSha256",
            auditEvent.AuthorityProvenanceSha256);
        command.Parameters.AddWithValue("$decisionKind", (int)auditEvent.DecisionKind);
        command.Parameters.AddWithValue("$previousState", (int)auditEvent.PreviousState);
        command.Parameters.AddWithValue("$resultState", (int)auditEvent.ResultState);
        command.Parameters.AddWithValue("$reason", auditEvent.Reason);
        command.Parameters.AddWithValue("$occurredUtc", FormatUtc(auditEvent.OccurredUtc));
        command.Parameters.AddWithValue("$evidenceSetSha256", auditEvent.EvidenceSetSha256);
        command.Parameters.AddWithValue(
            "$previousAuditSha256",
            (object?)auditEvent.PreviousAuditSha256 ?? DBNull.Value);
        command.Parameters.AddWithValue("$auditSha256", auditEvent.AuditSha256);
        command.Parameters.AddWithValue("$auditJson", auditJson);
        command.Parameters.AddWithValue("$auditJsonSha256", ComputeUtf8Sha256(auditJson));
        ConfigureComplianceReviewCommand(command, cancellationToken);
        command.ExecuteNonQuery();
        cancellationToken.ThrowIfCancellationRequested();
    }

    private static string SerializeComplianceReviewRegistration(
        ComplianceReviewIncident incident) =>
        JsonSerializer.Serialize(
            new
            {
                contractVersion = incident.ContractVersion,
                incidentId = incident.IncidentId,
                taskId = incident.TaskId,
                subjectActorId = incident.SubjectActorId,
                registeredUtc = FormatUtc(incident.RegisteredUtc),
                initialEvidenceIdentitySha256s = incident.InitialEvidenceIdentitySha256s,
            },
            EvidenceSerializerOptions);

    private void InsertComplianceReviewEvidenceLinks(
        string tableName,
        string ownerColumn,
        string ownerId,
        IReadOnlyList<string> evidence,
        SqliteTransaction transaction,
        CancellationToken cancellationToken = default)
    {
        if ((tableName, ownerColumn) is not
            ("compliance_review_incident_evidence", "incident_id") and not
            ("compliance_review_event_evidence", "audit_event_id"))
        {
            throw new HerdrStateStoreException(
                "Unsupported compliance review evidence-link table.");
        }

        foreach (var identity in evidence)
        {
            cancellationToken.ThrowIfCancellationRequested();
            using var command = _connection.CreateCommand();
            command.Transaction = transaction;
            command.CommandText = $"""
                INSERT INTO {tableName}({ownerColumn}, evidence_identity_sha256)
                VALUES ($ownerId, $identity);
                """;
            command.Parameters.AddWithValue("$ownerId", ownerId);
            command.Parameters.AddWithValue("$identity", identity);
            ConfigureComplianceReviewCommand(command, cancellationToken);
            command.ExecuteNonQuery();
        }
    }

    private IReadOnlyList<string> ReadComplianceReviewEvidenceLinks(
        string tableName,
        string ownerColumn,
        string ownerId,
        SqliteTransaction transaction,
        CancellationToken cancellationToken = default)
    {
        if ((tableName, ownerColumn) is not
            ("compliance_review_incident_evidence", "incident_id") and not
            ("compliance_review_event_evidence", "audit_event_id"))
        {
            throw new HerdrStateStoreException(
                "Unsupported compliance review evidence-link table.");
        }

        cancellationToken.ThrowIfCancellationRequested();
        using var command = _connection.CreateCommand();
        command.Transaction = transaction;
        command.CommandText = $"""
            SELECT evidence_identity_sha256
            FROM {tableName}
            WHERE {ownerColumn} = $ownerId
            ORDER BY evidence_identity_sha256;
            """;
        command.Parameters.AddWithValue("$ownerId", ownerId);
        ConfigureComplianceReviewCommand(command, cancellationToken);
        var evidence = new List<string>();
        using var reader = command.ExecuteReader();
        while (reader.Read())
        {
            cancellationToken.ThrowIfCancellationRequested();
            evidence.Add(reader.GetString(0));
        }

        return evidence;
    }

    private void ValidateComplianceReviewHistory(
        ComplianceReviewIncident current,
        SqliteTransaction transaction,
        CancellationToken cancellationToken = default) =>
        ValidateComplianceReviewHistory(
            current,
            ReadComplianceReviewAuditCore(
                current.IncidentId,
                transaction,
                cancellationToken),
            cancellationToken);

    private static void ValidateComplianceReviewHistory(
        ComplianceReviewIncident current,
        IReadOnlyList<ComplianceReviewAuditEvent> events,
        CancellationToken cancellationToken = default)
    {
        var replay = ComplianceReviewWorkflowContract.CreateIncident(
            new ComplianceReviewIncidentRegistration(
                current.ContractVersion,
                current.IncidentId,
                current.TaskId,
                current.SubjectActorId,
                current.RegisteredUtc,
                current.InitialEvidenceIdentitySha256s));
        foreach (var auditEvent in events)
        {
            cancellationToken.ThrowIfCancellationRequested();
            replay = ComplianceReviewWorkflowContract.Apply(replay, auditEvent);
        }

        EnsureSameCurrentIncident(replay, current);
    }

    private static void EnsureSameRegistration(
        ComplianceReviewIncident expected,
        ComplianceReviewIncident actual)
    {
        if (!string.Equals(expected.IncidentId, actual.IncidentId, StringComparison.Ordinal) ||
            !string.Equals(expected.TaskId, actual.TaskId, StringComparison.Ordinal) ||
            !string.Equals(expected.SubjectActorId, actual.SubjectActorId, StringComparison.Ordinal) ||
            expected.RegisteredUtc != actual.RegisteredUtc ||
            !expected.InitialEvidenceIdentitySha256s.SequenceEqual(
                actual.InitialEvidenceIdentitySha256s,
                StringComparer.Ordinal) ||
            !string.Equals(
                expected.RegistrationSha256,
                actual.RegistrationSha256,
                StringComparison.Ordinal))
        {
            throw new HerdrStateStoreException(
                $"Compliance review incident '{expected.IncidentId}' already exists with different immutable registration content.");
        }
    }

    private static void EnsureSameCurrentIncident(
        ComplianceReviewIncident expected,
        ComplianceReviewIncident actual)
    {
        EnsureSameRegistration(expected, actual);
        if (expected.State != actual.State ||
            expected.Sequence != actual.Sequence ||
            expected.UpdatedUtc != actual.UpdatedUtc ||
            expected.LastAuditEventId != actual.LastAuditEventId ||
            !string.Equals(expected.LastAuditSha256, actual.LastAuditSha256, StringComparison.Ordinal))
        {
            throw new HerdrStateStoreException(
                $"Compliance review incident '{expected.IncidentId}' does not match its immutable audit replay.");
        }
    }

    private static void EnsureSameComplianceReviewCommand(
        ComplianceReviewCommand command,
        ComplianceReviewAuthority authority,
        ComplianceReviewAuditEvent auditEvent)
    {
        EnsureSameComplianceReviewCommandPayload(command, auditEvent);
        if (!string.Equals(authority.ActorId, auditEvent.ReviewerActorId, StringComparison.Ordinal) ||
            authority.Role != auditEvent.ReviewerRole ||
            authority.ProvenanceEventId != auditEvent.AuthorityProvenanceEventId ||
            authority.ProvenanceSequence != auditEvent.AuthorityProvenanceSequence ||
            !string.Equals(
                authority.ProvenanceSha256,
                auditEvent.AuthorityProvenanceSha256,
                StringComparison.Ordinal))
        {
            throw new HerdrStateStoreException(
                $"Compliance review command '{command.CommandId:D}' already exists with different immutable content or authority.");
        }
    }

    private static void EnsureSameComplianceReviewCommandPayload(
        ComplianceReviewCommand command,
        ComplianceReviewAuditEvent auditEvent,
        bool compareOccurredUtc = true)
    {
        if (command.CommandId != auditEvent.AuditEventId ||
            !string.Equals(command.IncidentId, auditEvent.IncidentId, StringComparison.Ordinal) ||
            command.ExpectedState != auditEvent.PreviousState ||
            command.ExpectedSequence != auditEvent.Sequence - 1 ||
            !string.Equals(command.ReviewerActorId, auditEvent.ReviewerActorId, StringComparison.Ordinal) ||
            command.DecisionKind != auditEvent.DecisionKind ||
            !string.Equals(command.Reason, auditEvent.Reason, StringComparison.Ordinal) ||
            (compareOccurredUtc && command.OccurredUtc != auditEvent.OccurredUtc) ||
            !command.EvidenceIdentitySha256s.SequenceEqual(
                auditEvent.EvidenceIdentitySha256s,
                StringComparer.Ordinal))
        {
            throw new HerdrStateStoreException(
                $"Compliance review command '{command.CommandId:D}' already exists with different immutable content.");
        }
    }

    private static string NormalizeComplianceReviewIdentifier(string value, string name)
    {
        try
        {
            _ = name;
            return ComplianceReviewWorkflowContract.NormalizeIncidentId(value);
        }
        catch (ComplianceRuleContractException exception)
        {
            throw new HerdrStateStoreException(
                $"Compliance review identifier {name} is invalid.",
                exception);
        }
    }

    private void ConfigureComplianceReviewCommand(
        SqliteCommand command,
        CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(command);
        cancellationToken.ThrowIfCancellationRequested();
        // Backstop for commands that run inside an already-acquired review
        // transaction. The write-lock acquisition itself is bounded by the
        // cooperative busy-slice loop in BeginComplianceReviewWriteTransaction.
        command.CommandTimeout = Math.Min(
            _options.BusyTimeoutSeconds,
            ComplianceReviewBusyTimeoutCeilingSeconds);
    }

    private SqliteTransaction BeginComplianceReviewWriteTransaction(
        string incidentId,
        CancellationToken cancellationToken)
    {
        incidentId = ComplianceReviewWorkflowContract.NormalizeIncidentId(incidentId);
        cancellationToken.ThrowIfCancellationRequested();
        var totalContentionBoundSeconds = Math.Min(
            _options.BusyTimeoutSeconds,
            ComplianceReviewBusyTimeoutCeilingSeconds);
        var contentionDeadline = _timeProvider
            .GetUtcNow()
            .AddSeconds(totalContentionBoundSeconds);
        try
        {
            while (true)
            {
                cancellationToken.ThrowIfCancellationRequested();
                SqliteTransaction? transaction = null;
                try
                {
                    transaction = _connection.BeginTransaction(deferred: true);
                    // Re-inserting the already-registered incident under OR IGNORE
                    // is a real write statement that acquires the same reservation
                    // needed by the review mutation without changing any row or
                    // firing an update. Each attempt is stepped directly through
                    // the raw SQLite API with one short native busy slice, so a
                    // BUSY/LOCKED slice returns promptly and can be rolled back
                    // and retried with a fresh CancellationToken check.
                    ExecuteComplianceReviewWriteLockSlice(
                        incidentId,
                        cancellationToken);
                    cancellationToken.ThrowIfCancellationRequested();
                    return transaction;
                }
                catch (ComplianceReviewWriteLockBusyException busy)
                {
                    // The short slice hit real SQLite contention. Roll the failed
                    // attempt back cleanly, signal the diagnostic hook, then
                    // recheck the token and the total bound before the next slice.
                    transaction?.Dispose();
                    OnComplianceReviewBusySliceObserved();
                    cancellationToken.ThrowIfCancellationRequested();
                    if (_timeProvider.GetUtcNow() >= contentionDeadline)
                    {
                        throw new HerdrStateStoreException(
                            "The compliance-review write-lock acquisition exceeded the configured "
                                + $"{totalContentionBoundSeconds}-second contention bound.",
                            busy);
                    }
                }
                catch (SqliteException exception) when (
                    cancellationToken.IsCancellationRequested)
                {
                    transaction?.Dispose();
                    throw new OperationCanceledException(
                        "The compliance-review write-lock acquisition was canceled.",
                        exception,
                        cancellationToken);
                }
                catch
                {
                    transaction?.Dispose();
                    throw;
                }
            }
        }
        finally
        {
            // Restore the configured connection busy deadline for later commands.
            SQLitePCL.raw.sqlite3_busy_timeout(
                _connection.Handle,
                checked(_options.BusyTimeoutSeconds * 1000));
        }
    }

    private void ExecuteComplianceReviewWriteLockSlice(
        string incidentId,
        CancellationToken cancellationToken)
    {
        cancellationToken.ThrowIfCancellationRequested();
        var handle = _connection.Handle!;
        var rc = SQLitePCL.raw.sqlite3_busy_timeout(
            handle,
            ComplianceReviewBusySliceMilliseconds);
        if (rc != SQLitePCL.raw.SQLITE_OK)
        {
            throw new HerdrStateStoreException(
                "The compliance-review write-lock slice could not set its native busy deadline.");
        }

        SQLitePCL.sqlite3_stmt? statement = null;
        try
        {
            rc = SQLitePCL.raw.sqlite3_prepare_v2(
                handle,
                ComplianceReviewWriteLockSliceSql,
                out statement);
            if (IsComplianceReviewBusyOrLocked(rc))
            {
                throw new ComplianceReviewWriteLockBusyException(rc);
            }

            if (rc != SQLitePCL.raw.SQLITE_OK)
            {
                throw CreateComplianceReviewRawSqliteException(
                    handle,
                    rc,
                    "prepare");
            }

            rc = SQLitePCL.raw.sqlite3_bind_text(statement!, 1, incidentId);
            if (rc != SQLitePCL.raw.SQLITE_OK)
            {
                throw CreateComplianceReviewRawSqliteException(
                    handle,
                    rc,
                    "parameter bind");
            }

            rc = SQLitePCL.raw.sqlite3_step(statement!);
            if (rc is SQLitePCL.raw.SQLITE_ROW or SQLitePCL.raw.SQLITE_DONE)
            {
                return;
            }

            if (IsComplianceReviewBusyOrLocked(rc))
            {
                throw new ComplianceReviewWriteLockBusyException(rc);
            }

            if (rc == SQLitePCL.raw.SQLITE_INTERRUPT)
            {
                throw new SqliteException(
                    "The compliance-review write-lock slice was interrupted.",
                    SQLitePCL.raw.SQLITE_INTERRUPT,
                    SQLitePCL.raw.SQLITE_INTERRUPT);
            }

            throw CreateComplianceReviewRawSqliteException(handle, rc, "step");
        }
        finally
        {
            if (statement is not null)
            {
                SQLitePCL.raw.sqlite3_finalize(statement);
            }
        }
    }

    private static bool IsComplianceReviewBusyOrLocked(int sqliteErrorCode) =>
        sqliteErrorCode is SQLitePCL.raw.SQLITE_BUSY or
            SQLitePCL.raw.SQLITE_LOCKED or
            SqliteLockedSharedCache or
            SqliteBusySnapshot;

    private static SqliteException CreateComplianceReviewRawSqliteException(
        SQLitePCL.sqlite3 handle,
        int errorCode,
        string operation)
    {
        var message = SQLitePCL.raw.sqlite3_errmsg(handle).utf8_to_string();
        return new SqliteException(
            $"The compliance-review write-lock {operation} failed with SQLite error {errorCode}: {message}",
            errorCode,
            errorCode);
    }

    private void OnComplianceReviewBusySliceObserved() =>
        ComplianceReviewBusySliceObserved?.Invoke();

    private sealed class ComplianceReviewWriteLockBusyException : Exception
    {
        public ComplianceReviewWriteLockBusyException(int sqliteErrorCode)
            : base(
                $"SQLite reported busy/locked error code {sqliteErrorCode} while "
                    + "acquiring the compliance-review write lock.")
        {
            SqliteErrorCode = sqliteErrorCode;
        }

        public int SqliteErrorCode { get; }
    }

    private HerdrStoredAssignmentLifecycleEvent? ReadComplianceReviewAssignmentLifecycleEvent(
        SqliteTransaction transaction,
        long sequence,
        CancellationToken cancellationToken)
    {
        cancellationToken.ThrowIfCancellationRequested();
        using var command = _connection.CreateCommand();
        command.Transaction = transaction;
        command.CommandText = """
            SELECT event_json, event_json_sha256, lifecycle_event_sha256,
                   disposition, consumes_sequence, audit_code, audit_message,
                   audit_sha256, prior_task_state_sha256, result_task_state_sha256
            FROM assignment_lifecycle_events
            WHERE sequence = $sequence;
            """;
        command.Parameters.AddWithValue("$sequence", sequence);
        ConfigureComplianceReviewCommand(command, cancellationToken);
        using var reader = command.ExecuteReader();
        var result = reader.Read()
            ? ReadAndValidateAssignmentLifecycleEvent(reader)
            : null;
        cancellationToken.ThrowIfCancellationRequested();
        return result;
    }

    private void EnterComplianceReviewLock(CancellationToken cancellationToken)
    {
        while (!Monitor.TryEnter(_sync, TimeSpan.FromMilliseconds(25)))
        {
            cancellationToken.ThrowIfCancellationRequested();
        }
    }

    private void EnsureComplianceReviewSqlFunctions()
    {
        if (_complianceReviewSqlFunctionsRegistered)
        {
            return;
        }

        _connection.CreateFunction<int>(
            "herdrops_review_audit_valid",
            arguments => ValidateComplianceReviewAuditSqlArguments(arguments),
            isDeterministic: true);
        _complianceReviewSqlFunctionsRegistered = true;
    }

    private static int ValidateComplianceReviewAuditSqlArguments(object?[] arguments)
    {
        try
        {
            if (arguments.Length != 21)
            {
                return 0;
            }

            var auditJson = SqlText(arguments[19]);
            if (!string.Equals(
                    ComputeUtf8Sha256(auditJson),
                    SqlText(arguments[20]),
                    StringComparison.Ordinal))
            {
                return 0;
            }

            var auditEvent = ComplianceReviewWorkflowContract.NormalizeAndValidateAuditEvent(
                DeserializeEvidence<ComplianceReviewAuditEvent>(
                    auditJson,
                    "compliance review audit event"));
            var previousAuditSha256 = arguments[17] is null or DBNull
                ? null
                : SqlText(arguments[17]);
            return SqlInt64(arguments[0]) == auditEvent.ContractVersion &&
                   string.Equals(SqlText(arguments[1]), auditEvent.AuditEventId.ToString("D"), StringComparison.Ordinal) &&
                   string.Equals(SqlText(arguments[2]), auditEvent.IncidentId, StringComparison.Ordinal) &&
                   string.Equals(SqlText(arguments[3]), auditEvent.TaskId, StringComparison.Ordinal) &&
                   string.Equals(SqlText(arguments[4]), auditEvent.SubjectActorId, StringComparison.Ordinal) &&
                   SqlInt64(arguments[5]) == auditEvent.Sequence &&
                   string.Equals(SqlText(arguments[6]), auditEvent.ReviewerActorId, StringComparison.Ordinal) &&
                   SqlInt64(arguments[7]) == (int)auditEvent.ReviewerRole &&
                   string.Equals(SqlText(arguments[8]), auditEvent.AuthorityProvenanceEventId.ToString("D"), StringComparison.Ordinal) &&
                   SqlInt64(arguments[9]) == auditEvent.AuthorityProvenanceSequence &&
                   string.Equals(SqlText(arguments[10]), auditEvent.AuthorityProvenanceSha256, StringComparison.Ordinal) &&
                   SqlInt64(arguments[11]) == (int)auditEvent.DecisionKind &&
                   SqlInt64(arguments[12]) == (int)auditEvent.PreviousState &&
                   SqlInt64(arguments[13]) == (int)auditEvent.ResultState &&
                   string.Equals(SqlText(arguments[14]), auditEvent.Reason, StringComparison.Ordinal) &&
                   string.Equals(SqlText(arguments[15]), FormatUtc(auditEvent.OccurredUtc), StringComparison.Ordinal) &&
                   string.Equals(SqlText(arguments[16]), auditEvent.EvidenceSetSha256, StringComparison.Ordinal) &&
                   string.Equals(previousAuditSha256, auditEvent.PreviousAuditSha256, StringComparison.Ordinal) &&
                   string.Equals(SqlText(arguments[18]), auditEvent.AuditSha256, StringComparison.Ordinal)
                ? 1
                : 0;
        }
        catch (Exception exception) when (
            exception is ArgumentException or IOException or InvalidOperationException or JsonException)
        {
            return 0;
        }
    }

    private static string SqlText(object? value) =>
        value as string ?? throw new InvalidOperationException(
            "The compliance review SQL audit validator expected text.");

    private static long SqlInt64(object? value) =>
        Convert.ToInt64(value, System.Globalization.CultureInfo.InvariantCulture);

    private static Guid CapabilityCommandId(ComplianceReviewDecisionKind decision) =>
        decision switch
        {
            ComplianceReviewDecisionKind.Confirm =>
                Guid.Parse("11111111-1111-1111-1111-111111111111"),
            ComplianceReviewDecisionKind.SendToLeader =>
                Guid.Parse("22222222-2222-2222-2222-222222222222"),
            ComplianceReviewDecisionKind.EscalateToProjectManager =>
                Guid.Parse("33333333-3333-3333-3333-333333333333"),
            ComplianceReviewDecisionKind.Dismiss =>
                Guid.Parse("44444444-4444-4444-4444-444444444444"),
            _ => throw new ArgumentOutOfRangeException(
                nameof(decision),
                decision,
                "Unsupported compliance review decision."),
        };

    private sealed record StoredComplianceReviewAuditRow(
        int ContractVersion,
        Guid AuditEventId,
        string IncidentId,
        string TaskId,
        string SubjectActorId,
        long Sequence,
        string ReviewerActorId,
        ComplianceReviewerRole ReviewerRole,
        Guid AuthorityProvenanceEventId,
        long AuthorityProvenanceSequence,
        string AuthorityProvenanceSha256,
        ComplianceReviewDecisionKind DecisionKind,
        ComplianceReviewState PreviousState,
        ComplianceReviewState ResultState,
        string Reason,
        DateTimeOffset OccurredUtc,
        string EvidenceSetSha256,
        string? PreviousAuditSha256,
        string AuditSha256,
        string AuditJson,
        string AuditJsonSha256)
    {
        public bool Matches(ComplianceReviewAuditEvent auditEvent) =>
            ContractVersion == auditEvent.ContractVersion &&
            AuditEventId == auditEvent.AuditEventId &&
            string.Equals(IncidentId, auditEvent.IncidentId, StringComparison.Ordinal) &&
            string.Equals(TaskId, auditEvent.TaskId, StringComparison.Ordinal) &&
            string.Equals(SubjectActorId, auditEvent.SubjectActorId, StringComparison.Ordinal) &&
            Sequence == auditEvent.Sequence &&
            string.Equals(ReviewerActorId, auditEvent.ReviewerActorId, StringComparison.Ordinal) &&
            ReviewerRole == auditEvent.ReviewerRole &&
            AuthorityProvenanceEventId == auditEvent.AuthorityProvenanceEventId &&
            AuthorityProvenanceSequence == auditEvent.AuthorityProvenanceSequence &&
            string.Equals(AuthorityProvenanceSha256, auditEvent.AuthorityProvenanceSha256, StringComparison.Ordinal) &&
            DecisionKind == auditEvent.DecisionKind &&
            PreviousState == auditEvent.PreviousState &&
            ResultState == auditEvent.ResultState &&
            string.Equals(Reason, auditEvent.Reason, StringComparison.Ordinal) &&
            OccurredUtc == auditEvent.OccurredUtc &&
            string.Equals(EvidenceSetSha256, auditEvent.EvidenceSetSha256, StringComparison.Ordinal) &&
            string.Equals(PreviousAuditSha256, auditEvent.PreviousAuditSha256, StringComparison.Ordinal) &&
            string.Equals(AuditSha256, auditEvent.AuditSha256, StringComparison.Ordinal);
    }
}
