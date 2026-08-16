using System.Globalization;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.Json.Serialization;
using HerdrOps.Contracts.StateIpc;
using HerdrOps.Domain.Assignments;
using HerdrOps.Infrastructure.Storage.Recovery;
using Microsoft.Data.Sqlite;

namespace HerdrOps.Infrastructure.Storage;

public sealed partial class SqliteHerdrStateStore : IDisposable
{
    private const int MaximumPayloadBytes = HerdrOpsStateIpcProtocol.MaximumFrameBytes;
    private const string MigrationName = "initial-state-store";
    private const string MigrationSql = """
        CREATE TABLE schema_migrations (
            version INTEGER NOT NULL PRIMARY KEY,
            name TEXT NOT NULL,
            applied_utc TEXT NOT NULL,
            script_sha256 TEXT NOT NULL CHECK (length(script_sha256) = 64)
        ) STRICT;

        CREATE TABLE current_state (
            singleton_id INTEGER NOT NULL PRIMARY KEY CHECK (singleton_id = 1),
            sequence INTEGER NOT NULL CHECK (sequence > 0),
            connection_epoch INTEGER NOT NULL CHECK (connection_epoch > 0),
            observed_utc TEXT NOT NULL,
            ingested_utc TEXT NOT NULL,
            source TEXT NOT NULL CHECK (length(source) BETWEEN 1 AND 64),
            state_json TEXT NOT NULL,
            state_sha256 TEXT NOT NULL CHECK (length(state_sha256) = 64)
        ) STRICT;

        CREATE TABLE state_events (
            sequence INTEGER NOT NULL PRIMARY KEY CHECK (sequence > 0),
            connection_epoch INTEGER NOT NULL CHECK (connection_epoch > 0),
            observed_utc TEXT NOT NULL,
            ingested_utc TEXT NOT NULL,
            source TEXT NOT NULL CHECK (length(source) BETWEEN 1 AND 64),
            event_type TEXT NOT NULL CHECK (length(event_type) BETWEEN 1 AND 64),
            correlation_id TEXT NOT NULL CHECK (length(correlation_id) = 36),
            state_sha256 TEXT NOT NULL CHECK (length(state_sha256) = 64),
            payload_json TEXT NOT NULL,
            payload_sha256 TEXT NOT NULL CHECK (length(payload_sha256) = 64)
        ) STRICT;

        CREATE INDEX ix_state_events_observed_utc
            ON state_events(observed_utc);

        CREATE TRIGGER state_events_reject_update
        BEFORE UPDATE ON state_events
        BEGIN
            SELECT RAISE(ABORT, 'state_events is append-only');
        END;

        CREATE TRIGGER state_events_reject_delete
        BEFORE DELETE ON state_events
        BEGIN
            SELECT RAISE(ABORT, 'state_events is append-only');
        END;

        CREATE TRIGGER schema_migrations_reject_update
        BEFORE UPDATE ON schema_migrations
        BEGIN
            SELECT RAISE(ABORT, 'schema_migrations is append-only');
        END;

        CREATE TRIGGER schema_migrations_reject_delete
        BEFORE DELETE ON schema_migrations
        BEGIN
            SELECT RAISE(ABORT, 'schema_migrations is append-only');
        END;
        """;
    private const string AssignmentLifecycleMigrationName = "assignment-lifecycle-provenance";
    private const string AssignmentLifecycleMigrationSql = """
        CREATE TABLE assignment_lifecycle_events (
            sequence INTEGER NOT NULL PRIMARY KEY CHECK (sequence > 0),
            event_id TEXT NOT NULL UNIQUE CHECK (length(event_id) = 36),
            task_id TEXT NOT NULL CHECK (length(task_id) BETWEEN 1 AND 64),
            event_kind INTEGER NOT NULL CHECK (event_kind BETWEEN 1 AND 7),
            disposition INTEGER NOT NULL CHECK (disposition BETWEEN 1 AND 10),
            consumes_sequence INTEGER NOT NULL CHECK (consumes_sequence = 1),
            occurred_utc TEXT NOT NULL,
            accepted_utc TEXT NOT NULL,
            source TEXT NOT NULL CHECK (length(source) BETWEEN 1 AND 64),
            correlation_id TEXT NOT NULL CHECK (length(correlation_id) = 36),
            event_sha256 TEXT NOT NULL CHECK (length(event_sha256) = 64),
            lifecycle_event_sha256 TEXT NOT NULL CHECK (length(lifecycle_event_sha256) = 64),
            parent_event_id TEXT NULL CHECK (parent_event_id IS NULL OR length(parent_event_id) = 36),
            event_json TEXT NOT NULL,
            event_json_sha256 TEXT NOT NULL CHECK (length(event_json_sha256) = 64),
            audit_code TEXT NOT NULL CHECK (length(audit_code) BETWEEN 1 AND 64),
            audit_message TEXT NOT NULL CHECK (length(audit_message) BETWEEN 1 AND 2048),
            audit_sha256 TEXT NOT NULL CHECK (length(audit_sha256) = 64),
            prior_task_state_sha256 TEXT NULL CHECK (prior_task_state_sha256 IS NULL OR length(prior_task_state_sha256) = 64),
            result_task_state_sha256 TEXT NULL CHECK (result_task_state_sha256 IS NULL OR length(result_task_state_sha256) = 64)
        ) STRICT;

        CREATE INDEX ix_assignment_lifecycle_events_task_sequence
            ON assignment_lifecycle_events(task_id, sequence);

        CREATE INDEX ix_assignment_lifecycle_events_disposition
            ON assignment_lifecycle_events(disposition, sequence);

        CREATE INDEX ix_assignment_lifecycle_events_parent
            ON assignment_lifecycle_events(parent_event_id);

        CREATE TABLE assignment_tasks (
            task_id TEXT NOT NULL PRIMARY KEY CHECK (length(task_id) BETWEEN 1 AND 64),
            contract_version INTEGER NOT NULL CHECK (contract_version = 1),
            status INTEGER NOT NULL CHECK (status BETWEEN 1 AND 7),
            current_assignee_id TEXT NOT NULL CHECK (length(current_assignee_id) BETWEEN 1 AND 128),
            current_assignee_role TEXT NULL CHECK (current_assignee_role IS NULL OR length(current_assignee_role) BETWEEN 1 AND 128),
            progress_percent INTEGER NOT NULL CHECK (progress_percent BETWEEN 0 AND 100),
            deviation_count INTEGER NOT NULL CHECK (deviation_count >= 0),
            evidence_count INTEGER NOT NULL CHECK (evidence_count >= 0),
            handoff_count INTEGER NOT NULL CHECK (handoff_count >= 0),
            last_event_id TEXT NOT NULL UNIQUE CHECK (length(last_event_id) = 36),
            last_sequence INTEGER NOT NULL UNIQUE CHECK (last_sequence > 0),
            last_transition_utc TEXT NOT NULL,
            state_json TEXT NOT NULL,
            state_sha256 TEXT NOT NULL CHECK (length(state_sha256) = 64),
            FOREIGN KEY(last_event_id) REFERENCES assignment_lifecycle_events(event_id)
        ) STRICT;

        CREATE TABLE assignment_relationships (
            relationship_id TEXT NOT NULL PRIMARY KEY CHECK (length(relationship_id) = 36),
            relationship_kind INTEGER NOT NULL CHECK (relationship_kind BETWEEN 1 AND 3),
            task_id TEXT NOT NULL CHECK (length(task_id) BETWEEN 1 AND 64),
            from_actor_id TEXT NOT NULL CHECK (length(from_actor_id) BETWEEN 1 AND 128),
            from_actor_role TEXT NOT NULL CHECK (length(from_actor_role) BETWEEN 1 AND 128),
            to_actor_id TEXT NOT NULL CHECK (length(to_actor_id) BETWEEN 1 AND 128),
            event_id TEXT NOT NULL UNIQUE CHECK (length(event_id) = 36),
            sequence INTEGER NOT NULL UNIQUE CHECK (sequence > 0),
            occurred_utc TEXT NOT NULL,
            accepted_utc TEXT NOT NULL,
            provenance_event_sha256 TEXT NOT NULL CHECK (length(provenance_event_sha256) = 64),
            relationship_sha256 TEXT NOT NULL CHECK (length(relationship_sha256) = 64),
            FOREIGN KEY(task_id) REFERENCES assignment_tasks(task_id),
            FOREIGN KEY(event_id) REFERENCES assignment_lifecycle_events(event_id)
        ) STRICT;

        CREATE INDEX ix_assignment_relationships_task_sequence
            ON assignment_relationships(task_id, sequence);

        CREATE TABLE assignment_actor_role_history (
            event_id TEXT NOT NULL PRIMARY KEY CHECK (length(event_id) = 36),
            actor_id TEXT NOT NULL CHECK (length(actor_id) BETWEEN 1 AND 128),
            actor_role TEXT NOT NULL CHECK (length(actor_role) BETWEEN 1 AND 128),
            task_id TEXT NOT NULL CHECK (length(task_id) BETWEEN 1 AND 64),
            sequence INTEGER NOT NULL UNIQUE CHECK (sequence > 0),
            accepted_utc TEXT NOT NULL,
            provenance_event_sha256 TEXT NOT NULL CHECK (length(provenance_event_sha256) = 64),
            observation_sha256 TEXT NOT NULL CHECK (length(observation_sha256) = 64),
            FOREIGN KEY(event_id) REFERENCES assignment_lifecycle_events(event_id)
        ) STRICT;

        CREATE INDEX ix_assignment_actor_role_history_actor_sequence
            ON assignment_actor_role_history(actor_id, sequence);

        CREATE TABLE assignment_current_actor_roles (
            actor_id TEXT NOT NULL PRIMARY KEY CHECK (length(actor_id) BETWEEN 1 AND 128),
            actor_role TEXT NOT NULL CHECK (length(actor_role) BETWEEN 1 AND 128),
            task_id TEXT NOT NULL CHECK (length(task_id) BETWEEN 1 AND 64),
            event_id TEXT NOT NULL UNIQUE CHECK (length(event_id) = 36),
            sequence INTEGER NOT NULL UNIQUE CHECK (sequence > 0),
            accepted_utc TEXT NOT NULL,
            provenance_event_sha256 TEXT NOT NULL CHECK (length(provenance_event_sha256) = 64),
            state_sha256 TEXT NOT NULL CHECK (length(state_sha256) = 64),
            FOREIGN KEY(event_id) REFERENCES assignment_lifecycle_events(event_id)
        ) STRICT;

        CREATE TRIGGER assignment_lifecycle_events_reject_update
        BEFORE UPDATE ON assignment_lifecycle_events
        BEGIN
            SELECT RAISE(ABORT, 'assignment_lifecycle_events is append-only');
        END;

        CREATE TRIGGER assignment_lifecycle_events_reject_delete
        BEFORE DELETE ON assignment_lifecycle_events
        BEGIN
            SELECT RAISE(ABORT, 'assignment_lifecycle_events is append-only');
        END;

        CREATE TRIGGER assignment_relationships_reject_update
        BEFORE UPDATE ON assignment_relationships
        BEGIN
            SELECT RAISE(ABORT, 'assignment_relationships is append-only');
        END;

        CREATE TRIGGER assignment_relationships_reject_delete
        BEFORE DELETE ON assignment_relationships
        BEGIN
            SELECT RAISE(ABORT, 'assignment_relationships is append-only');
        END;

        CREATE TRIGGER assignment_actor_role_history_reject_update
        BEFORE UPDATE ON assignment_actor_role_history
        BEGIN
            SELECT RAISE(ABORT, 'assignment_actor_role_history is append-only');
        END;

        CREATE TRIGGER assignment_actor_role_history_reject_delete
        BEFORE DELETE ON assignment_actor_role_history
        BEGIN
            SELECT RAISE(ABORT, 'assignment_actor_role_history is append-only');
        END;
        """;

    private static readonly JsonSerializerOptions AssignmentSerializerOptions =
        new(JsonSerializerDefaults.Web)
        {
            AllowDuplicateProperties = false,
            AllowTrailingCommas = false,
            MaxDepth = 32,
            PropertyNameCaseInsensitive = false,
            ReadCommentHandling = JsonCommentHandling.Disallow,
            RespectRequiredConstructorParameters = true,
            UnmappedMemberHandling = JsonUnmappedMemberHandling.Disallow,
            WriteIndented = false,
        };

    private readonly object _sync = new();
    private readonly HerdrStateStoreOptions _options;
    private readonly TimeProvider _timeProvider;
    private readonly StateStoreRecoveryOptions _recoveryOptions;
    private readonly FileStream _ownershipLock;
    private readonly SqliteConnection _connection;
    private AssignmentLifecycleReducer _assignmentLifecycleReducer = new();
    private bool _disposed;

    public SqliteHerdrStateStore(
        HerdrStateStoreOptions options,
        TimeProvider? timeProvider = null)
        : this(options, timeProvider, recoveryOptions: null)
    {
    }

    internal SqliteHerdrStateStore(
        HerdrStateStoreOptions options,
        TimeProvider? timeProvider,
        StateStoreRecoveryOptions? recoveryOptions)
    {
        _options = ValidateOptions(options);
        _timeProvider = timeProvider ?? TimeProvider.System;
        _recoveryOptions = recoveryOptions ?? new StateStoreRecoveryOptions();
        StateStoreRecoveryPathPolicy.EnsureDatabaseParent(_options.DatabasePath);
        var primaryExisted = File.Exists(_options.DatabasePath);
        var shouldBackUpBeforeMigration = primaryExisted &&
            new FileInfo(_options.DatabasePath).Length > 0;
        var primaryValidationPassed = false;
        _ownershipLock = AcquireOwnershipLock(_options.DatabasePath);
        try
        {
            _connection = new SqliteConnection(CreateConnectionString(_options));
        }
        catch
        {
            _ownershipLock.Dispose();
            throw;
        }

        try
        {
            if (primaryExisted)
            {
                StateStoreRecoveryPathPolicy.ValidateExistingPrimary(_options.DatabasePath);
            }

            _connection.Open();
            ConfigureConnection();
            StateStoreRecoveryArtifacts.ValidateConnectionIdentity(
                _connection,
                _options.DatabasePath);
            var version = ReadSchemaVersion();
            if (version > HerdrStateStoreOptions.CurrentSchemaVersion)
            {
                throw new HerdrStateStoreException(
                    $"Database schema v{version} is newer than supported v{HerdrStateStoreOptions.CurrentSchemaVersion}.");
            }

            if (version > 0)
            {
                ValidateMigrationHistory(version);
            }

            if (version < HerdrStateStoreOptions.CurrentSchemaVersion)
            {
                EnsureIntegrity("before migration");
                primaryValidationPassed = true;
                if (shouldBackUpBeforeMigration)
                {
                    _recoveryOptions.EffectiveFaultInjector.OnPhase(
                        new StateStoreRecoveryPhaseContext(
                            StateStoreRecoveryPhase.BeforeBackup,
                            version,
                            HerdrStateStoreOptions.CurrentSchemaVersion,
                            null));
                    var backup = CreateBackup(version, HerdrStateStoreOptions.CurrentSchemaVersion);
                    LastBackupPath = backup.BackupPath;
                    _recoveryOptions.EffectiveFaultInjector.OnPhase(
                        new StateStoreRecoveryPhaseContext(
                            StateStoreRecoveryPhase.AfterBackup,
                            version,
                            HerdrStateStoreOptions.CurrentSchemaVersion,
                            backup.BackupPath));
                }

                ApplyMigrations(version);
            }
            else
            {
                EnsureIntegrity("before initialization");
                primaryValidationPassed = true;
            }

            EnableWalMode();
            ValidateMigrationHistory(HerdrStateStoreOptions.CurrentSchemaVersion);
            EnsureIntegrity("after initialization");
            StateStoreRecoveryArtifacts.ValidateConnectionIdentity(
                _connection,
                _options.DatabasePath);
            _assignmentLifecycleReducer = RestoreAssignmentLifecycleReducer();
            EnsureManagedVaultParentChainIsSafe();
            Directory.CreateDirectory(_options.ManagedEvidenceRootPath!);
            EnsureManagedVaultRootIsSafe();
        }
        catch (Exception exception)
        {
            _connection.Dispose();
            _ownershipLock.Dispose();
            if (exception is StateStoreCorruptionException corruption)
            {
                if (primaryExisted && !primaryValidationPassed)
                {
                    TryQuarantineCorruptedPrimary(corruption);
                }

                var publicFailure = new HerdrStateStoreException(
                    StateStoreRecoveryDiagnostics.SanitizeMessage(corruption.Message),
                    corruption);
                foreach (System.Collections.DictionaryEntry entry in corruption.Data)
                {
                    publicFailure.Data[entry.Key] = entry.Value;
                }

                throw publicFailure;
            }

            if (primaryExisted && !primaryValidationPassed && exception is SqliteException)
            {
                TryQuarantineCorruptedPrimary(
                    new StateStoreCorruptionException(
                        "SQLite rejected the existing state-store during admission.",
                        exception));
            }

            throw;
        }
    }

    private void TryQuarantineCorruptedPrimary(Exception failure)
    {
        try
        {
            var quarantinePath = StateStoreRecoveryArtifacts.Quarantine(
                _options.DatabasePath,
                failure,
                schemaVersion: null,
                phase: "initialization-validation",
                timeProvider: _timeProvider,
                recoveryOptions: _recoveryOptions);
            failure.Data["HerdrOps.QuarantinePath"] =
                StateStoreRecoveryDiagnostics.TokenizePath(quarantinePath);
        }
        catch (Exception quarantineFailure)
        {
            failure.Data["HerdrOps.QuarantineFailure"] =
                StateStoreRecoveryDiagnostics.SanitizeMessage(quarantineFailure.Message);
        }
    }

    public string DatabasePath => _options.DatabasePath;

    public string ManagedEvidenceRootPath => _options.ManagedEvidenceRootPath!;

    public string? LastBackupPath { get; }

    public HerdrStoredState? ReadCurrent()
    {
        lock (_sync)
        {
            ThrowIfDisposed();
            using var command = _connection.CreateCommand();
            command.CommandText = """
                SELECT state_json, observed_utc, ingested_utc, source, state_sha256
                FROM current_state
                WHERE singleton_id = 1;
                """;
            using var reader = command.ExecuteReader();
            if (!reader.Read())
            {
                return null;
            }

            return ReadAndValidateStoredState(reader);
        }
    }

    public HerdrStateStoreWriteResult Commit(HerdrStateStoreCommit commit)
    {
        ArgumentNullException.ThrowIfNull(commit);
        lock (_sync)
        {
            ThrowIfDisposed();
            var normalizedState = HerdrSessionStateContractReducer.NormalizeAndValidate(commit.State);
            ValidateCommit(commit, normalizedState);
            var stateJson = HerdrOpsStateIpcJson.SerializePayload(normalizedState);
            var stateSha256 = HerdrOpsStateIpcJson.ComputeSha256(normalizedState);
            var payloadSha256 = Convert.ToHexString(
                SHA256.HashData(Encoding.UTF8.GetBytes(commit.PayloadJson)));

            using var transaction = _connection.BeginTransaction(deferred: false);
            var current = ReadCurrent(transaction);
            if (current is not null)
            {
                if (normalizedState.LastIngestSequence == current.State.LastIngestSequence &&
                    string.Equals(stateSha256, current.StateSha256, StringComparison.Ordinal))
                {
                    transaction.Rollback();
                    return new HerdrStateStoreWriteResult(current, WasAlreadyPresent: true);
                }

                if (normalizedState.LastIngestSequence != current.State.LastIngestSequence + 1)
                {
                    throw new HerdrStateStoreException(
                        $"State sequence {normalizedState.LastIngestSequence} does not continue from {current.State.LastIngestSequence}.");
                }
            }
            else if (normalizedState.LastIngestSequence != 1)
            {
                throw new HerdrStateStoreException(
                    $"The first persisted state sequence must be 1, not {normalizedState.LastIngestSequence}.");
            }

            InsertEvent(
                transaction,
                commit,
                normalizedState,
                stateSha256,
                payloadSha256);
            UpsertCurrentState(
                transaction,
                commit,
                normalizedState,
                stateJson,
                stateSha256);
            transaction.Commit();

            return new HerdrStateStoreWriteResult(
                new HerdrStoredState(
                    normalizedState,
                    commit.ObservedUtc,
                    commit.IngestedUtc,
                    commit.Source,
                    stateSha256),
                WasAlreadyPresent: false);
        }
    }

    public HerdrAssignmentLifecycleWriteResult CommitAssignmentLifecycle(
        AssignmentLifecycleStep step)
    {
        ArgumentNullException.ThrowIfNull(step);
        lock (_sync)
        {
            ThrowIfDisposed();
            var validated = ValidateAssignmentLifecycleStep(step);
            using var transaction = _connection.BeginTransaction(deferred: false);
            var existingSequence = ReadAssignmentLifecycleEvent(
                transaction,
                validated.NormalizedEvent.Event.Sequence);
            if (existingSequence is not null)
            {
                if (string.Equals(
                        existingSequence.NormalizedEvent.LifecycleEventSha256,
                        validated.NormalizedEvent.LifecycleEventSha256,
                        StringComparison.Ordinal) &&
                    string.Equals(
                        existingSequence.Audit.AuditSha256,
                        validated.Audit.AuditSha256,
                        StringComparison.Ordinal))
                {
                    transaction.Rollback();
                    return new HerdrAssignmentLifecycleWriteResult(
                        existingSequence,
                        WasAlreadyPresent: true);
                }

                throw new HerdrStateStoreException(
                    $"Assignment lifecycle sequence {validated.NormalizedEvent.Event.Sequence} already contains different provenance.");
            }

            var existingEventSequence = ReadAssignmentEventSequence(
                transaction,
                validated.NormalizedEvent.Event.EventId);
            if (existingEventSequence is not null)
            {
                throw new HerdrStateStoreException(
                    $"Assignment lifecycle event {validated.NormalizedEvent.Event.EventId:D} already exists at sequence {existingEventSequence}.");
            }

            var lastSequence = ReadLastAssignmentLifecycleSequence(transaction);
            if (validated.NormalizedEvent.Event.Sequence <= lastSequence)
            {
                throw new HerdrStateStoreException(
                    $"Assignment lifecycle sequence {validated.NormalizedEvent.Event.Sequence} does not advance beyond {lastSequence}.");
            }

            if (_assignmentLifecycleReducer.LastSequence != lastSequence)
            {
                _assignmentLifecycleReducer = RestoreAssignmentLifecycleReducer(transaction);
            }

            var persistedTask = ReadAssignmentTask(
                transaction,
                validated.NormalizedEvent.Event.TaskId);
            ValidateAssignmentLifecyclePersistenceContext(validated, persistedTask);
            ValidateAndAdvanceAssignmentLifecycleReducer(transaction, validated);
            try
            {
                InsertAssignmentLifecycleEvent(transaction, validated);
                if (validated.Audit.Disposition == AssignmentLifecycleDisposition.Applied)
                {
                    UpsertAssignmentTask(transaction, validated.CurrentTask!);
                    if (validated.Relationship is not null)
                    {
                        InsertAssignmentRelationship(transaction, validated.Relationship);
                    }

                    InsertAssignmentRoleObservation(transaction, validated.RoleObservation!);
                    UpsertCurrentAssignmentRole(
                        transaction,
                        AssignmentLifecycleContract.CreateCurrentRole(validated.RoleObservation!));
                }

                transaction.Commit();
            }
            catch
            {
                try
                {
                    transaction.Rollback();
                }
                catch (InvalidOperationException)
                {
                }
                catch (SqliteException)
                {
                }

                _assignmentLifecycleReducer = RestoreAssignmentLifecycleReducer();
                throw;
            }

            return new HerdrAssignmentLifecycleWriteResult(
                new HerdrStoredAssignmentLifecycleEvent(
                    validated.NormalizedEvent,
                    validated.Audit,
                    validated.EventJsonSha256),
                WasAlreadyPresent: false);
        }
    }

    public IReadOnlyList<HerdrStoredAssignmentLifecycleEvent> ReadAssignmentLifecycleEvents(
        string? taskId = null)
    {
        lock (_sync)
        {
            ThrowIfDisposed();
            if (taskId is not null)
            {
                ValidateAssignmentIdentifier(taskId, nameof(taskId), 64);
            }

            using var command = _connection.CreateCommand();
            command.CommandText = taskId is null
                ? """
                    SELECT event_json, event_json_sha256, lifecycle_event_sha256,
                           disposition, consumes_sequence, audit_code, audit_message,
                           audit_sha256, prior_task_state_sha256, result_task_state_sha256
                    FROM assignment_lifecycle_events
                    ORDER BY sequence;
                    """
                : """
                    SELECT event_json, event_json_sha256, lifecycle_event_sha256,
                           disposition, consumes_sequence, audit_code, audit_message,
                           audit_sha256, prior_task_state_sha256, result_task_state_sha256
                    FROM assignment_lifecycle_events
                    WHERE task_id = $taskId
                    ORDER BY sequence;
                    """;
            if (taskId is not null)
            {
                command.Parameters.AddWithValue("$taskId", taskId);
            }

            using var reader = command.ExecuteReader();
            var events = new List<HerdrStoredAssignmentLifecycleEvent>();
            while (reader.Read())
            {
                events.Add(ReadAndValidateAssignmentLifecycleEvent(reader));
            }

            return events;
        }
    }

    public AssignmentTaskSnapshot? ReadAssignmentTask(string taskId)
    {
        ValidateAssignmentIdentifier(taskId, nameof(taskId), 64);
        lock (_sync)
        {
            ThrowIfDisposed();
            return ReadAssignmentTask(transaction: null, taskId);
        }
    }

    private AssignmentTaskSnapshot? ReadAssignmentTask(
        SqliteTransaction? transaction,
        string taskId)
    {
        using var command = _connection.CreateCommand();
        command.Transaction = transaction;
        command.CommandText = """
            SELECT task_id, contract_version, status, current_assignee_id,
                   current_assignee_role, progress_percent, deviation_count,
                   evidence_count, handoff_count, last_event_id, last_sequence,
                   last_transition_utc, state_json, state_sha256
            FROM assignment_tasks
            WHERE task_id = $taskId;
            """;
        command.Parameters.AddWithValue("$taskId", taskId);
        using var reader = command.ExecuteReader();
        if (!reader.Read())
        {
            return null;
        }

        var state = DeserializeAssignment<AssignmentTaskState>(
            reader.GetString(12),
            "assignment task state");
        var snapshot = new AssignmentTaskSnapshot(state, reader.GetString(13));
        try
        {
            AssignmentLifecycleContract.ValidateTaskSnapshot(snapshot);
        }
        catch (AssignmentLifecycleContractException exception)
        {
            throw new HerdrStateStoreException(
                "The persisted assignment task state failed contract validation.",
                exception);
        }

        if (!string.Equals(state.TaskId, reader.GetString(0), StringComparison.Ordinal) ||
            state.ContractVersion != reader.GetInt32(1) ||
            (int)state.Status != reader.GetInt32(2) ||
            !string.Equals(state.CurrentAssigneeId, reader.GetString(3), StringComparison.Ordinal) ||
            !NullableTextEquals(state.CurrentAssigneeRole, reader, 4) ||
            state.ProgressPercent != reader.GetInt32(5) ||
            state.DeviationCount != reader.GetInt32(6) ||
            state.EvidenceCount != reader.GetInt32(7) ||
            state.HandoffCount != reader.GetInt32(8) ||
            state.LastEventId != ParseGuid(reader.GetString(9), "last_event_id") ||
            state.LastSequence != reader.GetInt64(10) ||
            state.LastTransitionUtc != ParseUtc(reader.GetString(11)))
        {
            throw new HerdrStateStoreException(
                "The persisted assignment task scalar projection does not match its state JSON.");
        }

        return snapshot;
    }

    public IReadOnlyList<AssignmentRoleRelationship> ReadAssignmentRelationships(
        string taskId)
    {
        ValidateAssignmentIdentifier(taskId, nameof(taskId), 64);
        lock (_sync)
        {
            ThrowIfDisposed();
            using var command = _connection.CreateCommand();
            command.CommandText = """
                SELECT relationship_id, relationship_kind, task_id,
                       from_actor_id, from_actor_role, to_actor_id,
                       event_id, sequence, occurred_utc, accepted_utc,
                       provenance_event_sha256, relationship_sha256
                FROM assignment_relationships
                WHERE task_id = $taskId
                ORDER BY sequence;
                """;
            command.Parameters.AddWithValue("$taskId", taskId);
            var relationships = new List<AssignmentRoleRelationship>();
            using (var reader = command.ExecuteReader())
            {
                while (reader.Read())
                {
                    relationships.Add(new AssignmentRoleRelationship(
                        AssignmentLifecycleContract.Version,
                        ParseGuid(reader.GetString(0), "relationship_id"),
                        (AssignmentRelationshipKind)reader.GetInt32(1),
                        reader.GetString(2),
                        reader.GetString(3),
                        reader.GetString(4),
                        reader.GetString(5),
                        ParseGuid(reader.GetString(6), "event_id"),
                        reader.GetInt64(7),
                        ParseUtc(reader.GetString(8)),
                        ParseUtc(reader.GetString(9)),
                        reader.GetString(10),
                        reader.GetString(11)));
                }
            }

            ValidatePersistedRelationships(relationships);
            return relationships;
        }
    }

    public IReadOnlyList<AssignmentActorRoleObservation> ReadAssignmentRoleHistory(
        string? actorId = null)
    {
        lock (_sync)
        {
            ThrowIfDisposed();
            if (actorId is not null)
            {
                ValidateAssignmentIdentifier(actorId, nameof(actorId), 128);
            }

            using var command = _connection.CreateCommand();
            command.CommandText = actorId is null
                ? """
                    SELECT actor_id, actor_role, task_id, event_id, sequence,
                           accepted_utc, provenance_event_sha256, observation_sha256
                    FROM assignment_actor_role_history
                    ORDER BY sequence;
                    """
                : """
                    SELECT actor_id, actor_role, task_id, event_id, sequence,
                           accepted_utc, provenance_event_sha256, observation_sha256
                    FROM assignment_actor_role_history
                    WHERE actor_id = $actorId
                    ORDER BY sequence;
                    """;
            if (actorId is not null)
            {
                command.Parameters.AddWithValue("$actorId", actorId);
            }

            var history = new List<AssignmentActorRoleObservation>();
            using (var reader = command.ExecuteReader())
            {
                while (reader.Read())
                {
                    history.Add(new AssignmentActorRoleObservation(
                        AssignmentLifecycleContract.Version,
                        reader.GetString(0),
                        reader.GetString(1),
                        reader.GetString(2),
                        ParseGuid(reader.GetString(3), "event_id"),
                        reader.GetInt64(4),
                        ParseUtc(reader.GetString(5)),
                        reader.GetString(6),
                        reader.GetString(7)));
                }
            }

            ValidatePersistedRoleHistory(history);
            return history;
        }
    }

    public IReadOnlyList<AssignmentCurrentActorRole> ReadCurrentAssignmentRoles()
    {
        lock (_sync)
        {
            ThrowIfDisposed();
            using var command = _connection.CreateCommand();
            command.CommandText = """
                SELECT actor_id, actor_role, task_id, event_id, sequence,
                       accepted_utc, provenance_event_sha256, state_sha256
                FROM assignment_current_actor_roles
                ORDER BY actor_id;
                """;
            var roles = new List<AssignmentCurrentActorRole>();
            using (var reader = command.ExecuteReader())
            {
                while (reader.Read())
                {
                    roles.Add(new AssignmentCurrentActorRole(
                        AssignmentLifecycleContract.Version,
                        reader.GetString(0),
                        reader.GetString(1),
                        reader.GetString(2),
                        ParseGuid(reader.GetString(3), "event_id"),
                        reader.GetInt64(4),
                        ParseUtc(reader.GetString(5)),
                        reader.GetString(6),
                        reader.GetString(7)));
                }
            }

            foreach (var role in roles)
            {
                var observation = ReadAssignmentRoleObservationByEventId(role.EventId);
                try
                {
                    AssignmentLifecycleContract.ValidateCurrentRole(role, observation);
                }
                catch (AssignmentLifecycleContractException exception)
                {
                    throw new HerdrStateStoreException(
                        "A current assignment role failed provenance validation.",
                        exception);
                }
            }

            return roles;
        }
    }

    private static ValidatedAssignmentLifecycleCommit ValidateAssignmentLifecycleStep(
        AssignmentLifecycleStep step)
    {
        NormalizedAssignmentLifecycleEvent normalized;
        try
        {
            normalized = AssignmentLifecycleContract.NormalizeAndValidate(
                step.NormalizedEvent.Event);
            if (normalized != step.NormalizedEvent)
            {
                throw new AssignmentLifecycleContractException(
                    "The lifecycle step contains a non-canonical normalized event.");
            }

            AssignmentLifecycleContract.ValidateAuditEntry(step.Audit);
        }
        catch (AssignmentLifecycleContractException exception)
        {
            throw new HerdrStateStoreException(
                "The assignment lifecycle step failed domain contract validation.",
                exception);
        }

        var lifecycleEvent = normalized.Event;
        var audit = step.Audit;
        if (!audit.ConsumesSequence ||
            audit.EventId != lifecycleEvent.EventId ||
            audit.EventKind != lifecycleEvent.EventKind ||
            audit.Sequence != lifecycleEvent.Sequence ||
            !string.Equals(audit.TaskId, lifecycleEvent.TaskId, StringComparison.Ordinal) ||
            audit.AcceptedUtc != lifecycleEvent.AcceptedUtc ||
            !string.Equals(
                audit.LifecycleEventSha256,
                normalized.LifecycleEventSha256,
                StringComparison.Ordinal))
        {
            throw new HerdrStateStoreException(
                "Only a consumed lifecycle audit matching its normalized event can be persisted.");
        }

        if (step.CurrentTask is not null)
        {
            try
            {
                AssignmentLifecycleContract.ValidateTaskSnapshot(step.CurrentTask);
            }
            catch (AssignmentLifecycleContractException exception)
            {
                throw new HerdrStateStoreException(
                    "The lifecycle step task snapshot failed validation.",
                    exception);
            }

            if (!string.Equals(
                    step.CurrentTask.State.TaskId,
                    lifecycleEvent.TaskId,
                    StringComparison.Ordinal))
            {
                throw new HerdrStateStoreException(
                    "The lifecycle step task snapshot belongs to another task.");
            }
        }

        var applied = audit.Disposition == AssignmentLifecycleDisposition.Applied;
        if (applied)
        {
            if (step.CurrentTask is null ||
                step.RoleObservation is null ||
                step.CurrentTask.State.LastEventId != lifecycleEvent.EventId ||
                step.CurrentTask.State.LastSequence != lifecycleEvent.Sequence ||
                !string.Equals(
                    audit.ResultTaskStateSha256,
                    step.CurrentTask.StateSha256,
                    StringComparison.Ordinal))
            {
                throw new HerdrStateStoreException(
                    "An applied lifecycle step is missing its matching task or role projection.");
            }

            try
            {
                AssignmentLifecycleContract.ValidateRoleObservation(
                    step.RoleObservation,
                    normalized);
                if (step.Relationship is not null)
                {
                    AssignmentLifecycleContract.ValidateRelationship(
                        step.Relationship,
                        normalized);
                }
            }
            catch (AssignmentLifecycleContractException exception)
            {
                throw new HerdrStateStoreException(
                    "The applied lifecycle relationship or role provenance failed validation.",
                    exception);
            }

            var relationshipRequired = lifecycleEvent.EventKind is
                AssignmentLifecycleEventKind.Assignment or
                AssignmentLifecycleEventKind.Delegation or
                AssignmentLifecycleEventKind.Handoff;
            if (relationshipRequired != (step.Relationship is not null))
            {
                throw new HerdrStateStoreException(
                    "The applied lifecycle step has an invalid relationship projection cardinality.");
            }
        }
        else if (step.Relationship is not null || step.RoleObservation is not null)
        {
            throw new HerdrStateStoreException(
                "A rejected lifecycle step cannot mutate role or relationship projections.");
        }

        var eventJson = JsonSerializer.Serialize(lifecycleEvent, AssignmentSerializerOptions);
        var eventJsonSha256 = ComputeUtf8Sha256(eventJson);
        return new ValidatedAssignmentLifecycleCommit(
            normalized,
            audit,
            step.CurrentTask,
            step.Relationship,
            step.RoleObservation,
            eventJson,
            eventJsonSha256);
    }

    private static void ValidateAssignmentLifecyclePersistenceContext(
        ValidatedAssignmentLifecycleCommit commit,
        AssignmentTaskSnapshot? persistedTask)
    {
        var persistedHash = persistedTask?.StateSha256;
        if (!string.Equals(
                commit.Audit.PriorTaskStateSha256,
                persistedHash,
                StringComparison.Ordinal))
        {
            throw new HerdrStateStoreException(
                "The assignment lifecycle prior-state provenance does not match the persisted task state.");
        }

        if (commit.Audit.Disposition == AssignmentLifecycleDisposition.Applied)
        {
            var isAssignment = commit.NormalizedEvent.Event.EventKind ==
                AssignmentLifecycleEventKind.Assignment;
            if (isAssignment != (persistedTask is null))
            {
                throw new HerdrStateStoreException(
                    isAssignment
                        ? "An applied assignment cannot replace an existing task lifecycle."
                        : "An applied lifecycle transition requires an existing persisted task.");
            }

            return;
        }

        if (!string.Equals(
                commit.CurrentTask?.StateSha256,
                persistedHash,
                StringComparison.Ordinal) ||
            !string.Equals(
                commit.Audit.ResultTaskStateSha256,
                persistedHash,
                StringComparison.Ordinal))
        {
            throw new HerdrStateStoreException(
                "A rejected lifecycle event cannot change the persisted task projection.");
        }
    }

    private void ValidateAndAdvanceAssignmentLifecycleReducer(
        SqliteTransaction transaction,
        ValidatedAssignmentLifecycleCommit commit)
    {
        if (_assignmentLifecycleReducer.GetDiagnostics().ProcessedEventCount >=
            AssignmentLifecycleReplay.MaximumReplayEvents)
        {
            throw new HerdrStateStoreException(
                $"The assignment lifecycle cannot exceed {AssignmentLifecycleReplay.MaximumReplayEvents} persisted events.");
        }

        var expected = _assignmentLifecycleReducer.Process(commit.NormalizedEvent.Event);
        var proposed = new AssignmentLifecycleStep(
            commit.NormalizedEvent,
            commit.Audit,
            commit.CurrentTask,
            commit.Relationship,
            commit.RoleObservation);
        if (expected == proposed)
        {
            return;
        }

        _assignmentLifecycleReducer = RestoreAssignmentLifecycleReducer(transaction);
        throw new HerdrStateStoreException(
            "The assignment lifecycle step does not match deterministic replay of the persisted ledger.");
    }

    private AssignmentLifecycleReducer RestoreAssignmentLifecycleReducer(
        SqliteTransaction? transaction = null)
    {
        var reducer = new AssignmentLifecycleReducer();
        var persistedCount = 0;
        using (var command = _connection.CreateCommand())
        {
            command.Transaction = transaction;
            command.CommandText = """
                SELECT event_json, event_json_sha256, lifecycle_event_sha256,
                       disposition, consumes_sequence, audit_code, audit_message,
                       audit_sha256, prior_task_state_sha256, result_task_state_sha256
                FROM assignment_lifecycle_events
                ORDER BY sequence;
                """;
            using var reader = command.ExecuteReader();
            while (reader.Read())
            {
                if (persistedCount >= AssignmentLifecycleReplay.MaximumReplayEvents)
                {
                    throw new HerdrStateStoreException(
                        $"The persisted assignment lifecycle exceeds the replay bound of {AssignmentLifecycleReplay.MaximumReplayEvents} events.");
                }

                var stored = ReadAndValidateAssignmentLifecycleEvent(reader);
                var replayed = reducer.Process(stored.NormalizedEvent.Event);
                if (replayed.Audit != stored.Audit)
                {
                    throw new HerdrStateStoreException(
                        $"Persisted assignment lifecycle sequence {stored.NormalizedEvent.Event.Sequence} does not match deterministic replay semantics.");
                }

                persistedCount++;
            }
        }

        if (persistedCount > AssignmentLifecycleReplay.MaximumReplayEvents)
        {
            throw new HerdrStateStoreException(
                $"The persisted assignment lifecycle exceeds the replay bound of {AssignmentLifecycleReplay.MaximumReplayEvents} events.");
        }

        return reducer;
    }

    private HerdrStoredAssignmentLifecycleEvent? ReadAssignmentLifecycleEvent(
        SqliteTransaction transaction,
        long sequence)
    {
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
        using var reader = command.ExecuteReader();
        return reader.Read() ? ReadAndValidateAssignmentLifecycleEvent(reader) : null;
    }

    private long? ReadAssignmentEventSequence(
        SqliteTransaction transaction,
        Guid eventId)
    {
        using var command = _connection.CreateCommand();
        command.Transaction = transaction;
        command.CommandText = """
            SELECT sequence
            FROM assignment_lifecycle_events
            WHERE event_id = $eventId;
            """;
        command.Parameters.AddWithValue("$eventId", eventId.ToString("D"));
        var result = command.ExecuteScalar();
        return result is null or DBNull
            ? null
            : Convert.ToInt64(result, CultureInfo.InvariantCulture);
    }

    private long ReadLastAssignmentLifecycleSequence(SqliteTransaction transaction)
    {
        using var command = _connection.CreateCommand();
        command.Transaction = transaction;
        command.CommandText = "SELECT COALESCE(MAX(sequence), 0) FROM assignment_lifecycle_events;";
        return Convert.ToInt64(command.ExecuteScalar(), CultureInfo.InvariantCulture);
    }

    private void InsertAssignmentLifecycleEvent(
        SqliteTransaction transaction,
        ValidatedAssignmentLifecycleCommit commit)
    {
        var lifecycleEvent = commit.NormalizedEvent.Event;
        using var command = _connection.CreateCommand();
        command.Transaction = transaction;
        command.CommandText = """
            INSERT INTO assignment_lifecycle_events(
                sequence, event_id, task_id, event_kind, disposition,
                consumes_sequence, occurred_utc, accepted_utc, source,
                correlation_id, event_sha256, lifecycle_event_sha256,
                parent_event_id, event_json, event_json_sha256,
                audit_code, audit_message, audit_sha256,
                prior_task_state_sha256, result_task_state_sha256)
            VALUES (
                $sequence, $eventId, $taskId, $eventKind, $disposition,
                1, $occurredUtc, $acceptedUtc, $source,
                $correlationId, $eventSha256, $lifecycleEventSha256,
                $parentEventId, $eventJson, $eventJsonSha256,
                $auditCode, $auditMessage, $auditSha256,
                $priorTaskStateSha256, $resultTaskStateSha256);
            """;
        command.Parameters.AddWithValue("$sequence", lifecycleEvent.Sequence);
        command.Parameters.AddWithValue("$eventId", lifecycleEvent.EventId.ToString("D"));
        command.Parameters.AddWithValue("$taskId", lifecycleEvent.TaskId);
        command.Parameters.AddWithValue("$eventKind", (int)lifecycleEvent.EventKind);
        command.Parameters.AddWithValue("$disposition", (int)commit.Audit.Disposition);
        command.Parameters.AddWithValue("$occurredUtc", FormatUtc(lifecycleEvent.OccurredUtc));
        command.Parameters.AddWithValue("$acceptedUtc", FormatUtc(lifecycleEvent.AcceptedUtc));
        command.Parameters.AddWithValue("$source", lifecycleEvent.Source);
        command.Parameters.AddWithValue("$correlationId", lifecycleEvent.CorrelationId.ToString("D"));
        command.Parameters.AddWithValue("$eventSha256", lifecycleEvent.EventSha256);
        command.Parameters.AddWithValue(
            "$lifecycleEventSha256",
            commit.NormalizedEvent.LifecycleEventSha256);
        command.Parameters.AddWithValue(
            "$parentEventId",
            (object?)lifecycleEvent.ParentEventId?.ToString("D") ?? DBNull.Value);
        command.Parameters.AddWithValue("$eventJson", commit.EventJson);
        command.Parameters.AddWithValue("$eventJsonSha256", commit.EventJsonSha256);
        command.Parameters.AddWithValue("$auditCode", commit.Audit.Code);
        command.Parameters.AddWithValue("$auditMessage", commit.Audit.Message);
        command.Parameters.AddWithValue("$auditSha256", commit.Audit.AuditSha256);
        command.Parameters.AddWithValue(
            "$priorTaskStateSha256",
            (object?)commit.Audit.PriorTaskStateSha256 ?? DBNull.Value);
        command.Parameters.AddWithValue(
            "$resultTaskStateSha256",
            (object?)commit.Audit.ResultTaskStateSha256 ?? DBNull.Value);
        command.ExecuteNonQuery();
    }

    private void UpsertAssignmentTask(
        SqliteTransaction transaction,
        AssignmentTaskSnapshot snapshot)
    {
        var state = snapshot.State;
        var stateJson = JsonSerializer.Serialize(state, AssignmentSerializerOptions);
        using var command = _connection.CreateCommand();
        command.Transaction = transaction;
        command.CommandText = """
            INSERT INTO assignment_tasks(
                task_id, contract_version, status, current_assignee_id,
                current_assignee_role, progress_percent, deviation_count,
                evidence_count, handoff_count, last_event_id, last_sequence,
                last_transition_utc, state_json, state_sha256)
            VALUES (
                $taskId, $contractVersion, $status, $currentAssigneeId,
                $currentAssigneeRole, $progressPercent, $deviationCount,
                $evidenceCount, $handoffCount, $lastEventId, $lastSequence,
                $lastTransitionUtc, $stateJson, $stateSha256)
            ON CONFLICT(task_id) DO UPDATE SET
                contract_version = excluded.contract_version,
                status = excluded.status,
                current_assignee_id = excluded.current_assignee_id,
                current_assignee_role = excluded.current_assignee_role,
                progress_percent = excluded.progress_percent,
                deviation_count = excluded.deviation_count,
                evidence_count = excluded.evidence_count,
                handoff_count = excluded.handoff_count,
                last_event_id = excluded.last_event_id,
                last_sequence = excluded.last_sequence,
                last_transition_utc = excluded.last_transition_utc,
                state_json = excluded.state_json,
                state_sha256 = excluded.state_sha256
            WHERE excluded.last_sequence > assignment_tasks.last_sequence;
            """;
        command.Parameters.AddWithValue("$taskId", state.TaskId);
        command.Parameters.AddWithValue("$contractVersion", state.ContractVersion);
        command.Parameters.AddWithValue("$status", (int)state.Status);
        command.Parameters.AddWithValue("$currentAssigneeId", state.CurrentAssigneeId);
        command.Parameters.AddWithValue(
            "$currentAssigneeRole",
            (object?)state.CurrentAssigneeRole ?? DBNull.Value);
        command.Parameters.AddWithValue("$progressPercent", state.ProgressPercent);
        command.Parameters.AddWithValue("$deviationCount", state.DeviationCount);
        command.Parameters.AddWithValue("$evidenceCount", state.EvidenceCount);
        command.Parameters.AddWithValue("$handoffCount", state.HandoffCount);
        command.Parameters.AddWithValue("$lastEventId", state.LastEventId.ToString("D"));
        command.Parameters.AddWithValue("$lastSequence", state.LastSequence);
        command.Parameters.AddWithValue("$lastTransitionUtc", FormatUtc(state.LastTransitionUtc));
        command.Parameters.AddWithValue("$stateJson", stateJson);
        command.Parameters.AddWithValue("$stateSha256", snapshot.StateSha256);
        if (command.ExecuteNonQuery() != 1)
        {
            throw new HerdrStateStoreException(
                $"Assignment task '{state.TaskId}' rejected a stale current-state projection.");
        }
    }

    private void InsertAssignmentRelationship(
        SqliteTransaction transaction,
        AssignmentRoleRelationship relationship)
    {
        using var command = _connection.CreateCommand();
        command.Transaction = transaction;
        command.CommandText = """
            INSERT INTO assignment_relationships(
                relationship_id, relationship_kind, task_id,
                from_actor_id, from_actor_role, to_actor_id,
                event_id, sequence, occurred_utc, accepted_utc,
                provenance_event_sha256, relationship_sha256)
            VALUES (
                $relationshipId, $relationshipKind, $taskId,
                $fromActorId, $fromActorRole, $toActorId,
                $eventId, $sequence, $occurredUtc, $acceptedUtc,
                $provenanceEventSha256, $relationshipSha256);
            """;
        command.Parameters.AddWithValue("$relationshipId", relationship.RelationshipId.ToString("D"));
        command.Parameters.AddWithValue("$relationshipKind", (int)relationship.RelationshipKind);
        command.Parameters.AddWithValue("$taskId", relationship.TaskId);
        command.Parameters.AddWithValue("$fromActorId", relationship.FromActorId);
        command.Parameters.AddWithValue("$fromActorRole", relationship.FromActorRole);
        command.Parameters.AddWithValue("$toActorId", relationship.ToActorId);
        command.Parameters.AddWithValue("$eventId", relationship.EventId.ToString("D"));
        command.Parameters.AddWithValue("$sequence", relationship.Sequence);
        command.Parameters.AddWithValue("$occurredUtc", FormatUtc(relationship.OccurredUtc));
        command.Parameters.AddWithValue("$acceptedUtc", FormatUtc(relationship.AcceptedUtc));
        command.Parameters.AddWithValue(
            "$provenanceEventSha256",
            relationship.ProvenanceEventSha256);
        command.Parameters.AddWithValue("$relationshipSha256", relationship.RelationshipSha256);
        command.ExecuteNonQuery();
    }

    private void InsertAssignmentRoleObservation(
        SqliteTransaction transaction,
        AssignmentActorRoleObservation observation)
    {
        using var command = _connection.CreateCommand();
        command.Transaction = transaction;
        command.CommandText = """
            INSERT INTO assignment_actor_role_history(
                event_id, actor_id, actor_role, task_id, sequence,
                accepted_utc, provenance_event_sha256, observation_sha256)
            VALUES (
                $eventId, $actorId, $actorRole, $taskId, $sequence,
                $acceptedUtc, $provenanceEventSha256, $observationSha256);
            """;
        command.Parameters.AddWithValue("$eventId", observation.EventId.ToString("D"));
        command.Parameters.AddWithValue("$actorId", observation.ActorId);
        command.Parameters.AddWithValue("$actorRole", observation.ActorRole);
        command.Parameters.AddWithValue("$taskId", observation.TaskId);
        command.Parameters.AddWithValue("$sequence", observation.Sequence);
        command.Parameters.AddWithValue("$acceptedUtc", FormatUtc(observation.AcceptedUtc));
        command.Parameters.AddWithValue(
            "$provenanceEventSha256",
            observation.ProvenanceEventSha256);
        command.Parameters.AddWithValue("$observationSha256", observation.ObservationSha256);
        command.ExecuteNonQuery();
    }

    private void UpsertCurrentAssignmentRole(
        SqliteTransaction transaction,
        AssignmentCurrentActorRole currentRole)
    {
        using var command = _connection.CreateCommand();
        command.Transaction = transaction;
        command.CommandText = """
            INSERT INTO assignment_current_actor_roles(
                actor_id, actor_role, task_id, event_id, sequence,
                accepted_utc, provenance_event_sha256, state_sha256)
            VALUES (
                $actorId, $actorRole, $taskId, $eventId, $sequence,
                $acceptedUtc, $provenanceEventSha256, $stateSha256)
            ON CONFLICT(actor_id) DO UPDATE SET
                actor_role = excluded.actor_role,
                task_id = excluded.task_id,
                event_id = excluded.event_id,
                sequence = excluded.sequence,
                accepted_utc = excluded.accepted_utc,
                provenance_event_sha256 = excluded.provenance_event_sha256,
                state_sha256 = excluded.state_sha256
            WHERE excluded.sequence > assignment_current_actor_roles.sequence;
            """;
        command.Parameters.AddWithValue("$actorId", currentRole.ActorId);
        command.Parameters.AddWithValue("$actorRole", currentRole.ActorRole);
        command.Parameters.AddWithValue("$taskId", currentRole.TaskId);
        command.Parameters.AddWithValue("$eventId", currentRole.EventId.ToString("D"));
        command.Parameters.AddWithValue("$sequence", currentRole.Sequence);
        command.Parameters.AddWithValue("$acceptedUtc", FormatUtc(currentRole.AcceptedUtc));
        command.Parameters.AddWithValue(
            "$provenanceEventSha256",
            currentRole.ProvenanceEventSha256);
        command.Parameters.AddWithValue("$stateSha256", currentRole.StateSha256);
        if (command.ExecuteNonQuery() != 1)
        {
            throw new HerdrStateStoreException(
                $"Current role projection for '{currentRole.ActorId}' rejected a stale sequence.");
        }
    }

    private static HerdrStoredAssignmentLifecycleEvent ReadAndValidateAssignmentLifecycleEvent(
        SqliteDataReader reader)
    {
        var eventJson = reader.GetString(0);
        var eventJsonSha256 = reader.GetString(1);
        if (!string.Equals(
                ComputeUtf8Sha256(eventJson),
                eventJsonSha256,
                StringComparison.Ordinal))
        {
            throw new HerdrStateStoreException(
                "The persisted assignment lifecycle JSON hash does not match its bytes.");
        }

        var lifecycleEvent = DeserializeAssignment<AssignmentLifecycleEvent>(
            eventJson,
            "assignment lifecycle event");
        NormalizedAssignmentLifecycleEvent normalized;
        try
        {
            normalized = AssignmentLifecycleContract.NormalizeAndValidate(lifecycleEvent);
        }
        catch (AssignmentLifecycleContractException exception)
        {
            throw new HerdrStateStoreException(
                "The persisted assignment lifecycle event failed contract validation.",
                exception);
        }

        if (!string.Equals(
                normalized.LifecycleEventSha256,
                reader.GetString(2),
                StringComparison.Ordinal))
        {
            throw new HerdrStateStoreException(
                "The persisted assignment lifecycle canonical hash does not match its event.");
        }

        var audit = new AssignmentLifecycleAuditEntry(
            AssignmentLifecycleContract.Version,
            lifecycleEvent.EventId,
            lifecycleEvent.EventKind,
            lifecycleEvent.Sequence,
            lifecycleEvent.TaskId,
            (AssignmentLifecycleDisposition)reader.GetInt32(3),
            reader.GetInt32(4) == 1,
            reader.GetString(5),
            reader.GetString(6),
            lifecycleEvent.AcceptedUtc,
            normalized.LifecycleEventSha256,
            reader.IsDBNull(8) ? null : reader.GetString(8),
            reader.IsDBNull(9) ? null : reader.GetString(9),
            reader.GetString(7));
        try
        {
            AssignmentLifecycleContract.ValidateAuditEntry(audit);
        }
        catch (AssignmentLifecycleContractException exception)
        {
            throw new HerdrStateStoreException(
                "The persisted assignment lifecycle audit failed contract validation.",
                exception);
        }

        return new HerdrStoredAssignmentLifecycleEvent(
            normalized,
            audit,
            eventJsonSha256);
    }

    private void ValidatePersistedRelationships(
        IEnumerable<AssignmentRoleRelationship> relationships)
    {
        foreach (var relationship in relationships)
        {
            var storedEvent = ReadAssignmentLifecycleEventByEventId(relationship.EventId);
            try
            {
                AssignmentLifecycleContract.ValidateRelationship(
                    relationship,
                    storedEvent.NormalizedEvent);
            }
            catch (AssignmentLifecycleContractException exception)
            {
                throw new HerdrStateStoreException(
                    "A persisted assignment relationship failed provenance validation.",
                    exception);
            }
        }
    }

    private void ValidatePersistedRoleHistory(
        IEnumerable<AssignmentActorRoleObservation> history)
    {
        foreach (var observation in history)
        {
            var storedEvent = ReadAssignmentLifecycleEventByEventId(observation.EventId);
            try
            {
                AssignmentLifecycleContract.ValidateRoleObservation(
                    observation,
                    storedEvent.NormalizedEvent);
            }
            catch (AssignmentLifecycleContractException exception)
            {
                throw new HerdrStateStoreException(
                    "A persisted assignment role observation failed provenance validation.",
                    exception);
            }
        }
    }

    private AssignmentActorRoleObservation ReadAssignmentRoleObservationByEventId(
        Guid eventId)
    {
        using var command = _connection.CreateCommand();
        command.CommandText = """
            SELECT actor_id, actor_role, task_id, event_id, sequence,
                   accepted_utc, provenance_event_sha256, observation_sha256
            FROM assignment_actor_role_history
            WHERE event_id = $eventId;
            """;
        command.Parameters.AddWithValue("$eventId", eventId.ToString("D"));
        AssignmentActorRoleObservation observation;
        using (var reader = command.ExecuteReader())
        {
            if (!reader.Read())
            {
                throw new HerdrStateStoreException(
                    $"Current assignment role observation '{eventId:D}' is missing.");
            }

            observation = new AssignmentActorRoleObservation(
                AssignmentLifecycleContract.Version,
                reader.GetString(0),
                reader.GetString(1),
                reader.GetString(2),
                ParseGuid(reader.GetString(3), "event_id"),
                reader.GetInt64(4),
                ParseUtc(reader.GetString(5)),
                reader.GetString(6),
                reader.GetString(7));
        }

        ValidatePersistedRoleHistory([observation]);
        return observation;
    }

    private HerdrStoredAssignmentLifecycleEvent ReadAssignmentLifecycleEventByEventId(Guid eventId)
    {
        using var command = _connection.CreateCommand();
        command.CommandText = """
            SELECT event_json, event_json_sha256, lifecycle_event_sha256,
                   disposition, consumes_sequence, audit_code, audit_message,
                   audit_sha256, prior_task_state_sha256, result_task_state_sha256
            FROM assignment_lifecycle_events
            WHERE event_id = $eventId;
            """;
        command.Parameters.AddWithValue("$eventId", eventId.ToString("D"));
        using var reader = command.ExecuteReader();
        if (!reader.Read())
        {
            throw new HerdrStateStoreException(
                $"Assignment provenance event '{eventId:D}' is missing.");
        }

        return ReadAndValidateAssignmentLifecycleEvent(reader);
    }

    public HerdrStateStoreDiagnostics GetDiagnostics()
    {
        lock (_sync)
        {
            ThrowIfDisposed();
            return new HerdrStateStoreDiagnostics(
                ReadSchemaVersion(),
                ExecuteScalarString("PRAGMA journal_mode;"),
                checked((int)ExecuteScalarInt64("PRAGMA synchronous;")),
                ExecuteScalarInt64("PRAGMA foreign_keys;") == 1,
                ExecuteScalarString("PRAGMA quick_check;"),
                ExecuteScalarInt64("SELECT COUNT(*) FROM state_events;"),
                ExecuteScalarInt64("SELECT COUNT(*) FROM assignment_lifecycle_events;"),
                ExecuteScalarInt64("SELECT COUNT(*) FROM assignment_tasks;"),
                ExecuteScalarInt64("SELECT COUNT(*) FROM assignment_relationships;"),
                ExecuteScalarInt64($"SELECT COUNT(*) FROM assignment_lifecycle_events WHERE disposition IN ({(int)AssignmentLifecycleDisposition.OrphanTask}, {(int)AssignmentLifecycleDisposition.OrphanParent});"),
                ExecuteScalarInt64($"SELECT COUNT(*) FROM assignment_lifecycle_events WHERE disposition = {(int)AssignmentLifecycleDisposition.DuplicateHandoff};"),
                LastBackupPath);
        }
    }

    public void Dispose()
    {
        lock (_sync)
        {
            if (_disposed)
            {
                return;
            }

            _connection.Dispose();
            _ownershipLock.Dispose();
            _disposed = true;
        }
    }

    private static HerdrStateStoreOptions ValidateOptions(HerdrStateStoreOptions options)
    {
        ArgumentNullException.ThrowIfNull(options);
        if (string.IsNullOrWhiteSpace(options.DatabasePath) ||
            !Path.IsPathFullyQualified(options.DatabasePath))
        {
            throw new ArgumentException(
                "The SQLite database path must be absolute.",
                nameof(options));
        }

        if (options.BusyTimeoutSeconds is < 1 or > 60)
        {
            throw new ArgumentOutOfRangeException(
                nameof(options),
                "The SQLite busy timeout must be between 1 and 60 seconds.");
        }

        var databasePath = StateStoreRecoveryPathPolicy.NormalizeDatabasePath(options.DatabasePath);
        var evidenceRootPath = string.IsNullOrWhiteSpace(options.ManagedEvidenceRootPath)
            ? Path.Combine(Path.GetDirectoryName(databasePath)!, "evidence")
            : options.ManagedEvidenceRootPath;
        if (!Path.IsPathFullyQualified(evidenceRootPath))
        {
            throw new ArgumentException(
                "The managed-evidence root path must be absolute when specified.",
                nameof(options));
        }

        evidenceRootPath = Path.GetFullPath(evidenceRootPath);
        if (string.Equals(
                evidenceRootPath.TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar),
                Path.GetPathRoot(evidenceRootPath)?.TrimEnd(
                    Path.DirectorySeparatorChar,
                    Path.AltDirectorySeparatorChar),
                StringComparison.OrdinalIgnoreCase))
        {
            throw new ArgumentException(
                "The managed-evidence root cannot be a filesystem or share root.",
                nameof(options));
        }

        return options with
        {
            DatabasePath = databasePath,
            ManagedEvidenceRootPath = evidenceRootPath,
        };
    }

    private static string CreateConnectionString(HerdrStateStoreOptions options) =>
        new SqliteConnectionStringBuilder
        {
            DataSource = options.DatabasePath,
            Mode = SqliteOpenMode.ReadWriteCreate,
            Cache = SqliteCacheMode.Default,
            ForeignKeys = true,
            Pooling = false,
            DefaultTimeout = options.BusyTimeoutSeconds,
        }.ToString();

    private static FileStream AcquireOwnershipLock(string databasePath)
    {
        var lockPath = databasePath + ".core.lock";
        try
        {
            return new FileStream(
                lockPath,
                FileMode.OpenOrCreate,
                FileAccess.ReadWrite,
                FileShare.None,
                bufferSize: 1,
                FileOptions.None);
        }
        catch (IOException exception)
        {
            throw new HerdrStateStoreException(
                $"Another HerdrOps Core owns the state store lock '{lockPath}'.",
                exception);
        }
    }

    private void ConfigureConnection()
    {
        ExecuteNonQuery($"PRAGMA busy_timeout = {_options.BusyTimeoutSeconds * 1000};");
        ExecuteNonQuery("PRAGMA foreign_keys = ON;");
        ExecuteNonQuery("PRAGMA synchronous = FULL;");
    }

    private void EnableWalMode()
    {
        var journalMode = ExecuteScalarString("PRAGMA journal_mode = WAL;");
        if (!string.Equals(journalMode, "wal", StringComparison.OrdinalIgnoreCase))
        {
            throw new HerdrStateStoreException(
                $"SQLite did not enter WAL mode; reported '{journalMode}'.");
        }

        ExecuteNonQuery("PRAGMA synchronous = FULL;");
    }

    private void ApplyMigrations(int currentVersion)
    {
        if (currentVersion < 0 || currentVersion >= HerdrStateStoreOptions.CurrentSchemaVersion)
        {
            throw new HerdrStateStoreException(
                $"No forward migration is defined from schema v{currentVersion}.");
        }

        for (var targetVersion = currentVersion + 1;
             targetVersion <= HerdrStateStoreOptions.CurrentSchemaVersion;
             targetVersion++)
        {
            var definition = GetMigration(targetVersion);
            _recoveryOptions.EffectiveFaultInjector.OnPhase(
                new StateStoreRecoveryPhaseContext(
                    StateStoreRecoveryPhase.BeforeMigration,
                    currentVersion,
                    targetVersion,
                    null));
            using var transaction = _connection.BeginTransaction(deferred: false);
            using (var migration = _connection.CreateCommand())
            {
                migration.Transaction = transaction;
                migration.CommandText = definition.Sql;
                migration.ExecuteNonQuery();
            }

            using (var history = _connection.CreateCommand())
            {
                history.Transaction = transaction;
                history.CommandText = """
                    INSERT INTO schema_migrations(version, name, applied_utc, script_sha256)
                    VALUES ($version, $name, $appliedUtc, $scriptSha256);
                    """;
                history.Parameters.AddWithValue("$version", definition.Version);
                history.Parameters.AddWithValue("$name", definition.Name);
                history.Parameters.AddWithValue("$appliedUtc", FormatUtc(_timeProvider.GetUtcNow()));
                history.Parameters.AddWithValue("$scriptSha256", definition.ScriptSha256);
                history.ExecuteNonQuery();
            }

            using (var version = _connection.CreateCommand())
            {
                version.Transaction = transaction;
                version.CommandText = $"PRAGMA user_version = {definition.Version};";
                version.ExecuteNonQuery();
            }

            _recoveryOptions.EffectiveFaultInjector.OnPhase(
                new StateStoreRecoveryPhaseContext(
                    StateStoreRecoveryPhase.AfterMigrationBeforeCommit,
                    currentVersion,
                    targetVersion,
                    null));
            transaction.Commit();
            _recoveryOptions.EffectiveFaultInjector.OnPhase(
                new StateStoreRecoveryPhaseContext(
                    StateStoreRecoveryPhase.AfterMigrationCommit,
                    currentVersion,
                    targetVersion,
                    null));
            currentVersion = targetVersion;
        }
    }

    private StateStoreRecoveryBackupResult CreateBackup(int fromVersion, int toVersion) =>
        StateStoreRecoveryArtifacts.CreateBackup(
            _connection,
            _options.DatabasePath,
            fromVersion,
            toVersion,
            _timeProvider,
            _recoveryOptions);

    private void ValidateMigrationHistory(int schemaVersion)
    {
        if (schemaVersion is < 1 or > HerdrStateStoreOptions.CurrentSchemaVersion)
        {
            throw new HerdrStateStoreException(
                $"Cannot validate unsupported SQLite migration history v{schemaVersion}.");
        }

        using (var count = _connection.CreateCommand())
        {
            count.CommandText = "SELECT COUNT(*) FROM schema_migrations;";
            if (Convert.ToInt32(count.ExecuteScalar(), CultureInfo.InvariantCulture) != schemaVersion)
            {
                throw new StateStoreCorruptionException(
                    "The applied SQLite migration history cardinality does not match the schema version.");
            }
        }

        for (var version = 1; version <= schemaVersion; version++)
        {
            var definition = GetMigration(version);
            using var command = _connection.CreateCommand();
            command.CommandText = """
                SELECT name, script_sha256
                FROM schema_migrations
                WHERE version = $version;
                """;
            command.Parameters.AddWithValue("$version", version);
            using var reader = command.ExecuteReader();
            if (!reader.Read() ||
                !string.Equals(reader.GetString(0), definition.Name, StringComparison.Ordinal) ||
                !string.Equals(reader.GetString(1), definition.ScriptSha256, StringComparison.Ordinal) ||
                reader.Read())
            {
                throw new StateStoreCorruptionException(
                    $"The applied SQLite migration v{version} does not match the executable contract.");
            }
        }
    }

    private HerdrStoredState? ReadCurrent(SqliteTransaction transaction)
    {
        using var command = _connection.CreateCommand();
        command.Transaction = transaction;
        command.CommandText = """
            SELECT state_json, observed_utc, ingested_utc, source, state_sha256
            FROM current_state
            WHERE singleton_id = 1;
            """;
        using var reader = command.ExecuteReader();
        return reader.Read() ? ReadAndValidateStoredState(reader) : null;
    }

    private static HerdrStoredState ReadAndValidateStoredState(SqliteDataReader reader)
    {
        var stateJson = reader.GetString(0);
        var state = HerdrSessionStateContractReducer.NormalizeAndValidate(
            HerdrOpsStateIpcJson.DeserializePayload<HerdrSessionStateContract>(stateJson));
        var expectedHash = reader.GetString(4);
        var actualHash = HerdrOpsStateIpcJson.ComputeSha256(state);
        if (!string.Equals(expectedHash, actualHash, StringComparison.Ordinal))
        {
            throw new HerdrStateStoreException(
                "The persisted current-state hash does not match its JSON bytes.");
        }

        return new HerdrStoredState(
            state,
            ParseUtc(reader.GetString(1)),
            ParseUtc(reader.GetString(2)),
            reader.GetString(3),
            expectedHash);
    }

    private void InsertEvent(
        SqliteTransaction transaction,
        HerdrStateStoreCommit commit,
        HerdrSessionStateContract state,
        string stateSha256,
        string payloadSha256)
    {
        using var command = _connection.CreateCommand();
        command.Transaction = transaction;
        command.CommandText = """
            INSERT INTO state_events(
                sequence, connection_epoch, observed_utc, ingested_utc,
                source, event_type, correlation_id, state_sha256,
                payload_json, payload_sha256)
            VALUES (
                $sequence, $connectionEpoch, $observedUtc, $ingestedUtc,
                $source, $eventType, $correlationId, $stateSha256,
                $payloadJson, $payloadSha256);
            """;
        AddCommitParameters(command, commit, state, stateSha256);
        command.Parameters.AddWithValue("$eventType", commit.EventType);
        command.Parameters.AddWithValue("$correlationId", commit.CorrelationId.ToString("D"));
        command.Parameters.AddWithValue("$payloadJson", commit.PayloadJson);
        command.Parameters.AddWithValue("$payloadSha256", payloadSha256);
        command.ExecuteNonQuery();
    }

    private void UpsertCurrentState(
        SqliteTransaction transaction,
        HerdrStateStoreCommit commit,
        HerdrSessionStateContract state,
        string stateJson,
        string stateSha256)
    {
        using var command = _connection.CreateCommand();
        command.Transaction = transaction;
        command.CommandText = """
            INSERT INTO current_state(
                singleton_id, sequence, connection_epoch, observed_utc,
                ingested_utc, source, state_json, state_sha256)
            VALUES (
                1, $sequence, $connectionEpoch, $observedUtc,
                $ingestedUtc, $source, $stateJson, $stateSha256)
            ON CONFLICT(singleton_id) DO UPDATE SET
                sequence = excluded.sequence,
                connection_epoch = excluded.connection_epoch,
                observed_utc = excluded.observed_utc,
                ingested_utc = excluded.ingested_utc,
                source = excluded.source,
                state_json = excluded.state_json,
                state_sha256 = excluded.state_sha256;
            """;
        AddCommitParameters(command, commit, state, stateSha256);
        command.Parameters.AddWithValue("$stateJson", stateJson);
        command.ExecuteNonQuery();
    }

    private static void AddCommitParameters(
        SqliteCommand command,
        HerdrStateStoreCommit commit,
        HerdrSessionStateContract state,
        string stateSha256)
    {
        command.Parameters.AddWithValue("$sequence", state.LastIngestSequence);
        command.Parameters.AddWithValue("$connectionEpoch", state.ConnectionEpoch);
        command.Parameters.AddWithValue("$observedUtc", FormatUtc(commit.ObservedUtc));
        command.Parameters.AddWithValue("$ingestedUtc", FormatUtc(commit.IngestedUtc));
        command.Parameters.AddWithValue("$source", commit.Source);
        command.Parameters.AddWithValue("$stateSha256", stateSha256);
    }

    private static void ValidateCommit(
        HerdrStateStoreCommit commit,
        HerdrSessionStateContract state)
    {
        if (state.LastIngestSequence <= 0 || state.ConnectionEpoch <= 0)
        {
            throw new HerdrStateStoreException(
                "Only an admitted, sequenced Herdr state can be persisted.");
        }

        ValidateUtc(commit.ObservedUtc, nameof(commit.ObservedUtc));
        ValidateUtc(commit.IngestedUtc, nameof(commit.IngestedUtc));
        if (commit.IngestedUtc < commit.ObservedUtc)
        {
            throw new HerdrStateStoreException(
                "The state ingest time cannot precede its observed time.");
        }

        ValidateText(commit.Source, nameof(commit.Source));
        ValidateText(commit.EventType, nameof(commit.EventType));
        if (commit.CorrelationId == Guid.Empty)
        {
            throw new HerdrStateStoreException("The state correlation identifier cannot be empty.");
        }

        var payloadBytes = Encoding.UTF8.GetByteCount(commit.PayloadJson);
        if (payloadBytes is < 1 or > MaximumPayloadBytes)
        {
            throw new HerdrStateStoreException(
                $"The state event payload must contain 1 to {MaximumPayloadBytes} UTF-8 bytes.");
        }

        try
        {
            using var _ = JsonDocument.Parse(commit.PayloadJson, new JsonDocumentOptions
            {
                AllowTrailingCommas = false,
                CommentHandling = JsonCommentHandling.Disallow,
                MaxDepth = 64,
            });
        }
        catch (JsonException exception)
        {
            throw new HerdrStateStoreException(
                "The state event payload is not valid strict JSON.",
                exception);
        }
    }

    private static void ValidateText(string value, string name)
    {
        if (string.IsNullOrWhiteSpace(value) || value.Length > 64)
        {
            throw new HerdrStateStoreException(
                $"{name} must contain 1 to 64 characters.");
        }
    }

    private static void ValidateUtc(DateTimeOffset value, string name)
    {
        if (value.Offset != TimeSpan.Zero)
        {
            throw new HerdrStateStoreException($"{name} must be UTC.");
        }
    }

    private int ReadSchemaVersion() =>
        checked((int)ExecuteScalarInt64("PRAGMA user_version;"));

    private void EnsureIntegrity(string phase)
    {
        var quickCheck = ExecuteScalarString("PRAGMA quick_check;");
        if (!string.Equals(quickCheck, "ok", StringComparison.OrdinalIgnoreCase))
        {
            throw new StateStoreCorruptionException(
                $"SQLite quick_check failed {phase}: {quickCheck}");
        }

        var integrityCheck = ExecuteScalarString("PRAGMA integrity_check;");
        if (!string.Equals(integrityCheck, "ok", StringComparison.OrdinalIgnoreCase))
        {
            throw new StateStoreCorruptionException(
                $"SQLite integrity_check failed {phase}: {integrityCheck}");
        }
    }

    private void ExecuteNonQuery(string sql)
    {
        using var command = _connection.CreateCommand();
        command.CommandText = sql;
        command.ExecuteNonQuery();
    }

    private long ExecuteScalarInt64(string sql)
    {
        using var command = _connection.CreateCommand();
        command.CommandText = sql;
        return Convert.ToInt64(command.ExecuteScalar(), CultureInfo.InvariantCulture);
    }

    private string ExecuteScalarString(string sql)
    {
        using var command = _connection.CreateCommand();
        command.CommandText = sql;
        return Convert.ToString(command.ExecuteScalar(), CultureInfo.InvariantCulture)
            ?? throw new HerdrStateStoreException($"SQLite returned no value for '{sql}'.");
    }

    internal static (string Name, string Sql, string ScriptSha256) GetMigrationForTesting(
        int version)
    {
        var migration = GetMigration(version);
        return (migration.Name, migration.Sql, migration.ScriptSha256);
    }

    private static MigrationDefinition GetMigration(int version) => version switch
    {
        1 => new MigrationDefinition(
            1,
            MigrationName,
            MigrationSql,
            ComputeMigrationSha256(MigrationSql)),
        2 => new MigrationDefinition(
            2,
            AssignmentLifecycleMigrationName,
            AssignmentLifecycleMigrationSql,
            ComputeMigrationSha256(AssignmentLifecycleMigrationSql)),
        3 => new MigrationDefinition(
            3,
            EvidenceAuditMigrationName,
            EvidenceAuditMigrationSql,
            ComputeMigrationSha256(EvidenceAuditMigrationSql)),
        4 => new MigrationDefinition(
            4,
            ComplianceReviewMigrationName,
            ComplianceReviewMigrationSql,
            ComputeMigrationSha256(ComplianceReviewMigrationSql)),
        _ => throw new HerdrStateStoreException(
            $"No SQLite migration contract exists for v{version}."),
    };

    private static string ComputeMigrationSha256(string sql) =>
        Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(sql)));

    private static T DeserializeAssignment<T>(string json, string description)
    {
        try
        {
            return JsonSerializer.Deserialize<T>(json, AssignmentSerializerOptions)
                ?? throw new JsonException($"The {description} JSON contained null.");
        }
        catch (JsonException exception)
        {
            throw new HerdrStateStoreException(
                $"The persisted {description} is not valid strict JSON.",
                exception);
        }
    }

    private static string ComputeUtf8Sha256(string value) =>
        Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(value)));

    private static Guid ParseGuid(string value, string columnName)
    {
        if (!Guid.TryParseExact(value, "D", out var result) || result == Guid.Empty)
        {
            throw new HerdrStateStoreException(
                $"Persisted {columnName} '{value}' is not a canonical non-empty GUID.");
        }

        return result;
    }

    private static bool NullableTextEquals(
        string? expected,
        SqliteDataReader reader,
        int ordinal) => expected is null
        ? reader.IsDBNull(ordinal)
        : !reader.IsDBNull(ordinal) &&
          string.Equals(expected, reader.GetString(ordinal), StringComparison.Ordinal);

    private static void ValidateAssignmentIdentifier(
        string value,
        string name,
        int maximumLength)
    {
        if (string.IsNullOrWhiteSpace(value) ||
            value.Length > maximumLength ||
            !string.Equals(value, value.Trim(), StringComparison.Ordinal) ||
            value.Any(character =>
                !(char.IsAsciiLetterOrDigit(character) ||
                  character is '-' or '_' or '.' or ':' or '/')))
        {
            throw new HerdrStateStoreException(
                $"{name} must contain 1 to {maximumLength} characters from the identifier allowlist.");
        }
    }

    private static string FormatUtc(DateTimeOffset value) =>
        value.ToString("O", CultureInfo.InvariantCulture);

    private static DateTimeOffset ParseUtc(string value)
    {
        if (!DateTimeOffset.TryParseExact(
                value,
                "O",
                CultureInfo.InvariantCulture,
                DateTimeStyles.RoundtripKind,
                out var result) ||
            result.Offset != TimeSpan.Zero)
        {
            throw new HerdrStateStoreException(
                $"Persisted timestamp '{value}' is not a valid UTC round-trip value.");
        }

        return result;
    }

    private void ThrowIfDisposed() =>
        ObjectDisposedException.ThrowIf(_disposed, this);

    private sealed record MigrationDefinition(
        int Version,
        string Name,
        string Sql,
        string ScriptSha256);

    private sealed record ValidatedAssignmentLifecycleCommit(
        NormalizedAssignmentLifecycleEvent NormalizedEvent,
        AssignmentLifecycleAuditEntry Audit,
        AssignmentTaskSnapshot? CurrentTask,
        AssignmentRoleRelationship? Relationship,
        AssignmentActorRoleObservation? RoleObservation,
        string EventJson,
        string EventJsonSha256);
}
