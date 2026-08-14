namespace HerdrOps.Domain.Activity;

public enum FileActivityOperation
{
    Read = 1,
    Modified = 2,
    Created = 3,
    Deleted = 4,
    Renamed = 5,
    ScopeBlocked = 6,
    WatcherFailure = 7,
}

/// <summary>
/// A bounded, already-scoped file or Git observation. Absolute paths are deliberately
/// excluded so an activity record cannot disclose a path outside the authorized repository.
/// </summary>
public sealed record FileActivityObservation(
    long SourceSequence,
    DateTimeOffset ObservedUtc,
    FileActivityOperation Operation,
    string RelativePath,
    string? PreviousRelativePath,
    ActivitySourceKind SourceKind,
    string SourceInstanceId,
    ActivityConfidence Confidence,
    bool IsAuthorized,
    string ScopeDecision,
    string? AgentTerminalId = null,
    string? TaskId = null,
    string? CorrelationEvidenceSource = null,
    DateTimeOffset? CorrelationObservedUtc = null);

public static class FileActivityContract
{
    public const int MaximumRelativePathLength = 2048;
    public const int MaximumScopeDecisionLength = 128;

    public static FileActivityObservation NormalizeAndValidate(FileActivityObservation observation)
    {
        ArgumentNullException.ThrowIfNull(observation);
        if (observation.SourceSequence <= 0)
        {
            throw new ArgumentOutOfRangeException(
                nameof(observation),
                "A file activity source sequence must be positive.");
        }

        if (observation.ObservedUtc.Offset != TimeSpan.Zero)
        {
            throw new ArgumentException(
                "A file activity timestamp must be expressed in UTC.",
                nameof(observation));
        }

        if (!Enum.IsDefined(observation.Operation) ||
            !Enum.IsDefined(observation.Confidence) ||
            observation.SourceKind is not (ActivitySourceKind.FileSystem or ActivitySourceKind.Git))
        {
            throw new ArgumentException(
                "A file activity observation contains an unsupported enum value.",
                nameof(observation));
        }

        var relativePath = NormalizeText(
            observation.RelativePath,
            nameof(observation.RelativePath),
            MaximumRelativePathLength);
        var previousRelativePath = observation.PreviousRelativePath is null
            ? null
            : NormalizeText(
                observation.PreviousRelativePath,
                nameof(observation.PreviousRelativePath),
                MaximumRelativePathLength);
        var sourceInstanceId = NormalizeText(
            observation.SourceInstanceId,
            nameof(observation.SourceInstanceId),
            ActivityEventContract.MaximumIdentifierLength);
        var scopeDecision = NormalizeText(
            observation.ScopeDecision,
            nameof(observation.ScopeDecision),
            MaximumScopeDecisionLength);
        var agentTerminalId = NormalizeOptionalIdentifier(
            observation.AgentTerminalId,
            nameof(observation.AgentTerminalId));
        var taskId = NormalizeOptionalIdentifier(observation.TaskId, nameof(observation.TaskId));
        var correlationEvidenceSource = NormalizeOptionalIdentifier(
            observation.CorrelationEvidenceSource,
            nameof(observation.CorrelationEvidenceSource));
        var correlationObservedUtc = observation.CorrelationObservedUtc;
        if (correlationObservedUtc is { } correlationTime &&
            correlationTime.Offset != TimeSpan.Zero)
        {
            throw new ArgumentException(
                "A file correlation evidence timestamp must be expressed in UTC.",
                nameof(observation));
        }

        if (observation.IsAuthorized)
        {
            if (observation.Operation is FileActivityOperation.ScopeBlocked or
                FileActivityOperation.WatcherFailure)
            {
                throw new ArgumentException(
                    "An authorized file activity observation cannot use a failure operation.",
                    nameof(observation));
            }

            EnsureRepositoryRelativePath(relativePath, nameof(observation.RelativePath));
            if (previousRelativePath is not null)
            {
                EnsureRepositoryRelativePath(previousRelativePath, nameof(observation.PreviousRelativePath));
            }
        }
        else if (relativePath != "[blocked]" || previousRelativePath is not null)
        {
            throw new ArgumentException(
                "A blocked file activity observation cannot retain a rejected path.",
                nameof(observation));
        }
        else if (observation.Operation is not (FileActivityOperation.ScopeBlocked or
                     FileActivityOperation.WatcherFailure) ||
                 agentTerminalId is not null ||
                 taskId is not null ||
                 correlationEvidenceSource is not null ||
                 correlationObservedUtc is not null ||
                 observation.Confidence == ActivityConfidence.Correlated)
        {
            throw new ArgumentException(
                "A blocked file activity observation cannot claim an authorized operation or correlation.",
                nameof(observation));
        }

        if (taskId is not null && agentTerminalId is null)
        {
            throw new ArgumentException(
                "A file activity Task identifier requires an Agent terminal identifier.",
                nameof(observation));
        }

        if (observation.Confidence == ActivityConfidence.Correlated &&
            (agentTerminalId is null ||
             correlationEvidenceSource is null ||
             correlationObservedUtc is null ||
             correlationObservedUtc > observation.ObservedUtc))
        {
            throw new ArgumentException(
                "Correlated file activity requires an Agent, a bounded evidence source, and a non-future UTC evidence timestamp.",
                nameof(observation));
        }

        if (observation.Confidence != ActivityConfidence.Correlated &&
            (agentTerminalId is not null ||
             taskId is not null ||
             correlationEvidenceSource is not null ||
             correlationObservedUtc is not null))
        {
            throw new ArgumentException(
                "Uncorrelated file activity cannot claim Agent, Task, or correlation provenance.",
                nameof(observation));
        }

        return observation with
        {
            RelativePath = relativePath.Replace('\\', '/'),
            PreviousRelativePath = previousRelativePath?.Replace('\\', '/'),
            SourceInstanceId = sourceInstanceId,
            ScopeDecision = scopeDecision,
            AgentTerminalId = agentTerminalId,
            TaskId = taskId,
            CorrelationEvidenceSource = correlationEvidenceSource,
            CorrelationObservedUtc = correlationObservedUtc,
        };
    }

    private static string NormalizeText(string value, string name, int maximumLength)
    {
        if (string.IsNullOrWhiteSpace(value) ||
            !string.Equals(value, value.Trim(), StringComparison.Ordinal) ||
            value.Length > maximumLength ||
            value.Any(char.IsControl))
        {
            throw new ArgumentException(
                $"{name} must be non-blank, unpadded, bounded, and free of control characters.",
                name);
        }

        return value.Normalize();
    }

    private static void EnsureRepositoryRelativePath(string value, string name)
    {
        var portable = value.Replace('\\', '/');
        if (Path.IsPathRooted(value) ||
            portable.StartsWith("/", StringComparison.Ordinal) ||
            portable.Split('/', StringSplitOptions.RemoveEmptyEntries)
                .Any(segment => segment is "." or ".."))
        {
            throw new ArgumentException(
                "Authorized file activity paths must remain repository-relative.",
                name);
        }
    }

    private static string? NormalizeOptionalIdentifier(string? value, string name) =>
        value is null
            ? null
            : NormalizeText(value, name, ActivityEventContract.MaximumIdentifierLength);
}

public sealed record FileActivityCorrelationContext(
    string AgentTerminalId,
    string? TaskId,
    string WorkingDirectoryRelativePath,
    DateTimeOffset ObservedUtc,
    string EvidenceSource);

public sealed record FileActivityCorrelationOptions(TimeSpan MaximumAge)
{
    public static FileActivityCorrelationOptions Default { get; } = new(TimeSpan.FromSeconds(10));

    public void Validate()
    {
        if (MaximumAge < TimeSpan.FromMilliseconds(100) || MaximumAge > TimeSpan.FromMinutes(5))
        {
            throw new ArgumentOutOfRangeException(
                nameof(MaximumAge),
                "File activity correlation age must be between 100 milliseconds and 5 minutes.");
        }
    }
}

/// <summary>
/// Correlates an observed path only when exactly one recent Agent/Task context owns the
/// separator-aware working-directory prefix. Ambiguity leaves the observation uncorrelated.
/// </summary>
public sealed class FileActivityCorrelator
{
    private readonly FileActivityCorrelationOptions _options;

    public FileActivityCorrelator(FileActivityCorrelationOptions? options = null)
    {
        _options = options ?? FileActivityCorrelationOptions.Default;
        _options.Validate();
    }

    public FileActivityObservation Correlate(
        FileActivityObservation observation,
        IEnumerable<FileActivityCorrelationContext> contexts)
    {
        var normalized = FileActivityContract.NormalizeAndValidate(observation);
        ArgumentNullException.ThrowIfNull(contexts);
        if (!normalized.IsAuthorized)
        {
            return normalized;
        }

        var candidates = contexts
            .Select(NormalizeContext)
            .Where(context =>
                context.ObservedUtc <= normalized.ObservedUtc &&
                normalized.ObservedUtc - context.ObservedUtc <= _options.MaximumAge &&
                IsWithinWorkingDirectory(context.WorkingDirectoryRelativePath, normalized.RelativePath))
            .ToArray();
        var identities = candidates
            .Select(context => (context.AgentTerminalId, context.TaskId))
            .Distinct()
            .ToArray();
        if (identities.Length != 1)
        {
            return normalized;
        }

        var evidence = candidates
            .OrderByDescending(context => context.ObservedUtc)
            .ThenBy(context => context.EvidenceSource, StringComparer.Ordinal)
            .First();

        return FileActivityContract.NormalizeAndValidate(normalized with
        {
            AgentTerminalId = identities[0].AgentTerminalId,
            TaskId = identities[0].TaskId,
            Confidence = ActivityConfidence.Correlated,
            CorrelationEvidenceSource = evidence.EvidenceSource,
            CorrelationObservedUtc = evidence.ObservedUtc,
        });
    }

    private static FileActivityCorrelationContext NormalizeContext(
        FileActivityCorrelationContext context)
    {
        ArgumentNullException.ThrowIfNull(context);
        if (context.ObservedUtc.Offset != TimeSpan.Zero)
        {
            throw new ArgumentException("A file correlation context timestamp must be UTC.", nameof(context));
        }

        var probe = FileActivityContract.NormalizeAndValidate(new FileActivityObservation(
            1,
            context.ObservedUtc,
            FileActivityOperation.Read,
            context.WorkingDirectoryRelativePath == "."
                ? "correlation-probe"
                : $"{context.WorkingDirectoryRelativePath.TrimEnd('/', '\\')}/correlation-probe",
            null,
            ActivitySourceKind.FileSystem,
            "correlation:validation",
            ActivityConfidence.Correlated,
            true,
            "authorized",
            context.AgentTerminalId,
            context.TaskId,
            context.EvidenceSource,
            context.ObservedUtc));

        var directory = Path.GetDirectoryName(probe.RelativePath.Replace('/', Path.DirectorySeparatorChar))
            ?.Replace('\\', '/') ?? ".";
        return context with
        {
            AgentTerminalId = probe.AgentTerminalId!,
            TaskId = probe.TaskId,
            WorkingDirectoryRelativePath = string.IsNullOrEmpty(directory) ? "." : directory,
            EvidenceSource = probe.CorrelationEvidenceSource!,
        };
    }

    private static bool IsWithinWorkingDirectory(string workingDirectory, string relativePath)
    {
        if (workingDirectory == ".")
        {
            return true;
        }

        var normalizedDirectory = workingDirectory.TrimEnd('/', '\\').Replace('\\', '/');
        var normalizedPath = relativePath.Replace('\\', '/');
        return normalizedPath.StartsWith(normalizedDirectory + "/", StringComparison.OrdinalIgnoreCase);
    }
}
