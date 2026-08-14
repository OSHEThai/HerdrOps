using System.Globalization;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using HerdrOps.Contracts.StateIpc;
using Microsoft.Data.Sqlite;

namespace HerdrOps.Infrastructure.Storage;

public sealed class SqliteHerdrStateStore : IDisposable
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

    private readonly object _sync = new();
    private readonly HerdrStateStoreOptions _options;
    private readonly TimeProvider _timeProvider;
    private readonly FileStream _ownershipLock;
    private readonly SqliteConnection _connection;
    private bool _disposed;

    public SqliteHerdrStateStore(
        HerdrStateStoreOptions options,
        TimeProvider? timeProvider = null)
    {
        _options = ValidateOptions(options);
        _timeProvider = timeProvider ?? TimeProvider.System;
        Directory.CreateDirectory(Path.GetDirectoryName(_options.DatabasePath)!);
        var shouldBackUpBeforeMigration = File.Exists(_options.DatabasePath) &&
            new FileInfo(_options.DatabasePath).Length > 0;
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
            _connection.Open();
            ConfigureConnection();
            var version = ReadSchemaVersion();
            if (version > HerdrStateStoreOptions.CurrentSchemaVersion)
            {
                throw new HerdrStateStoreException(
                    $"Database schema v{version} is newer than supported v{HerdrStateStoreOptions.CurrentSchemaVersion}.");
            }

            if (version < HerdrStateStoreOptions.CurrentSchemaVersion)
            {
                EnsureIntegrity("before migration");
                if (shouldBackUpBeforeMigration)
                {
                    LastBackupPath = CreateBackup(version, HerdrStateStoreOptions.CurrentSchemaVersion);
                }

                ApplyMigrations(version);
            }

            EnableWalMode();
            ValidateMigrationHistory();
            EnsureIntegrity("after initialization");
        }
        catch
        {
            _connection.Dispose();
            _ownershipLock.Dispose();
            throw;
        }
    }

    public string DatabasePath => _options.DatabasePath;

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

        return options with { DatabasePath = Path.GetFullPath(options.DatabasePath) };
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
        if (currentVersion != 0)
        {
            throw new HerdrStateStoreException(
                $"No forward migration is defined from schema v{currentVersion}.");
        }

        using var transaction = _connection.BeginTransaction(deferred: false);
        using (var migration = _connection.CreateCommand())
        {
            migration.Transaction = transaction;
            migration.CommandText = MigrationSql;
            migration.ExecuteNonQuery();
        }

        using (var history = _connection.CreateCommand())
        {
            history.Transaction = transaction;
            history.CommandText = """
                INSERT INTO schema_migrations(version, name, applied_utc, script_sha256)
                VALUES ($version, $name, $appliedUtc, $scriptSha256);
                """;
            history.Parameters.AddWithValue("$version", HerdrStateStoreOptions.CurrentSchemaVersion);
            history.Parameters.AddWithValue("$name", MigrationName);
            history.Parameters.AddWithValue("$appliedUtc", FormatUtc(_timeProvider.GetUtcNow()));
            history.Parameters.AddWithValue("$scriptSha256", ComputeMigrationSha256());
            history.ExecuteNonQuery();
        }

        using (var version = _connection.CreateCommand())
        {
            version.Transaction = transaction;
            version.CommandText = $"PRAGMA user_version = {HerdrStateStoreOptions.CurrentSchemaVersion};";
            version.ExecuteNonQuery();
        }

        transaction.Commit();
    }

    private string CreateBackup(int fromVersion, int toVersion)
    {
        var backupDirectory = Path.Combine(
            Path.GetDirectoryName(_options.DatabasePath)!,
            "backups");
        Directory.CreateDirectory(backupDirectory);
        var timestamp = _timeProvider.GetUtcNow().ToString(
            "yyyyMMddTHHmmssfff'Z'",
            CultureInfo.InvariantCulture);
        var backupPath = Path.Combine(
            backupDirectory,
            $"{Path.GetFileName(_options.DatabasePath)}.v{fromVersion}.pre-v{toVersion}.{timestamp}.{Guid.NewGuid():N}.bak");
        using var destination = new SqliteConnection(new SqliteConnectionStringBuilder
        {
            DataSource = backupPath,
            Mode = SqliteOpenMode.ReadWriteCreate,
            Cache = SqliteCacheMode.Default,
            Pooling = false,
        }.ToString());
        destination.Open();
        _connection.BackupDatabase(destination);
        return backupPath;
    }

    private void ValidateMigrationHistory()
    {
        using var command = _connection.CreateCommand();
        command.CommandText = """
            SELECT name, script_sha256
            FROM schema_migrations
            WHERE version = $version;
            """;
        command.Parameters.AddWithValue("$version", HerdrStateStoreOptions.CurrentSchemaVersion);
        using var reader = command.ExecuteReader();
        if (!reader.Read() ||
            !string.Equals(reader.GetString(0), MigrationName, StringComparison.Ordinal) ||
            !string.Equals(reader.GetString(1), ComputeMigrationSha256(), StringComparison.Ordinal) ||
            reader.Read())
        {
            throw new HerdrStateStoreException(
                "The applied SQLite migration history does not match the executable contract.");
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
        var result = ExecuteScalarString("PRAGMA quick_check;");
        if (!string.Equals(result, "ok", StringComparison.OrdinalIgnoreCase))
        {
            throw new HerdrStateStoreException(
                $"SQLite integrity check failed {phase}: {result}");
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

    private static string ComputeMigrationSha256() =>
        Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(MigrationSql)));

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
}
