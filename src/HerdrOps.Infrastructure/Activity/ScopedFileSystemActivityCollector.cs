using System.Threading.Channels;
using HerdrOps.Domain.Activity;

namespace HerdrOps.Infrastructure.Activity;

public sealed record ScopedFileSystemCollectorOptions(
    int QueueCapacity,
    bool IncludeSubdirectories,
    TimeSpan? DebounceWindow = null,
    IReadOnlySet<string>? ExcludedDirectoryNames = null)
{
    public static ScopedFileSystemCollectorOptions Default { get; } = new(
        QueueCapacity: 4096,
        IncludeSubdirectories: true,
        DebounceWindow: TimeSpan.FromMilliseconds(100),
        ExcludedDirectoryNames: new HashSet<string>(StringComparer.OrdinalIgnoreCase)
        {
            ".git",
            ".vs",
            "artifacts",
            "bin",
            "obj",
        });

    public void Validate()
    {
        if (QueueCapacity is < 16 or > 65_536)
        {
            throw new ArgumentOutOfRangeException(
                nameof(QueueCapacity),
                "The file activity queue must contain between 16 and 65,536 entries.");
        }

        var debounce = DebounceWindow ?? TimeSpan.FromMilliseconds(100);
        if (debounce < TimeSpan.Zero || debounce > TimeSpan.FromSeconds(5))
        {
            throw new ArgumentOutOfRangeException(
                nameof(DebounceWindow),
                "The file event debounce window must be between zero and five seconds.");
        }
    }
}

/// <summary>
/// A bounded FileSystemWatcher adapter. Event callbacks never read file contents and every
/// path is re-authorized before it can enter the queue.
/// </summary>
public sealed class ScopedFileSystemActivityCollector : IAsyncDisposable
{
    private readonly AuthorizedRepositoryScope _scope;
    private readonly TimeProvider _timeProvider;
    private readonly FileSystemWatcher _watcher;
    private readonly Channel<FileActivityObservation> _queue;
    private readonly TimeSpan _debounceWindow;
    private readonly IReadOnlySet<string> _excludedDirectoryNames;
    private readonly int _maximumDebounceEntries;
    private readonly object _debounceGate = new();
    private readonly Dictionary<string, DateTimeOffset> _recentEvents =
        new(StringComparer.OrdinalIgnoreCase);
    private readonly Queue<(string Key, DateTimeOffset ObservedUtc)> _recentEventOrder = new();
    private long _sourceSequence;
    private bool _disposed;

    public ScopedFileSystemActivityCollector(
        AuthorizedRepositoryScope scope,
        ScopedFileSystemCollectorOptions? options = null,
        TimeProvider? timeProvider = null)
    {
        _scope = scope ?? throw new ArgumentNullException(nameof(scope));
        var effectiveOptions = options ?? ScopedFileSystemCollectorOptions.Default;
        effectiveOptions.Validate();
        _timeProvider = timeProvider ?? TimeProvider.System;
        _debounceWindow = effectiveOptions.DebounceWindow ?? TimeSpan.FromMilliseconds(100);
        _excludedDirectoryNames = effectiveOptions.ExcludedDirectoryNames ??
            ScopedFileSystemCollectorOptions.Default.ExcludedDirectoryNames!;
        _maximumDebounceEntries = effectiveOptions.QueueCapacity * 2;
        _queue = Channel.CreateBounded<FileActivityObservation>(
            new BoundedChannelOptions(effectiveOptions.QueueCapacity)
            {
                FullMode = BoundedChannelFullMode.DropOldest,
                SingleReader = false,
                SingleWriter = false,
                AllowSynchronousContinuations = false,
            });
        _watcher = new FileSystemWatcher(_scope.DeclaredRoot)
        {
            IncludeSubdirectories = effectiveOptions.IncludeSubdirectories,
            InternalBufferSize = 16 * 1024,
            NotifyFilter = NotifyFilters.FileName |
                NotifyFilters.LastWrite |
                NotifyFilters.Size,
            EnableRaisingEvents = false,
        };
        _watcher.Changed += OnChanged;
        _watcher.Created += OnCreated;
        _watcher.Deleted += OnDeleted;
        _watcher.Renamed += OnRenamed;
        _watcher.Error += OnError;
    }

    public string SourceInstanceId => $"filesystem:{_scope.RootIdentity}";

    internal int TrackedDebounceEntryCount
    {
        get
        {
            lock (_debounceGate)
            {
                return _recentEvents.Count;
            }
        }
    }

    internal int MaximumTrackedDebounceEntries => _maximumDebounceEntries;

    public void Start()
    {
        ObjectDisposedException.ThrowIf(_disposed, this);
        _watcher.EnableRaisingEvents = true;
    }

    public IAsyncEnumerable<FileActivityObservation> ReadAllAsync(
        CancellationToken cancellationToken = default) =>
        _queue.Reader.ReadAllAsync(cancellationToken);

    public bool TryProjectCandidate(
        FileActivityOperation operation,
        string candidatePath,
        string? previousCandidatePath,
        out FileActivityObservation observation)
    {
        var decision = _scope.Evaluate(candidatePath);
        RepositoryPathDecision? previousDecision = previousCandidatePath is null
            ? null
            : _scope.Evaluate(previousCandidatePath);
        var authorized = decision.IsAuthorized &&
            (previousDecision is null || previousDecision.IsAuthorized);
        var reason = !decision.IsAuthorized
            ? decision.Reason
            : previousDecision is { IsAuthorized: false }
                ? $"previous-{previousDecision.Reason}"
                : "authorized";
        observation = FileActivityContract.NormalizeAndValidate(new FileActivityObservation(
            Interlocked.Increment(ref _sourceSequence),
            _timeProvider.GetUtcNow(),
            authorized ? operation : FileActivityOperation.ScopeBlocked,
            authorized ? decision.RelativePath! : "[blocked]",
            authorized ? previousDecision?.RelativePath : null,
            ActivitySourceKind.FileSystem,
            SourceInstanceId,
            ActivityConfidence.Observed,
            authorized,
            reason));
        return authorized;
    }

    public async ValueTask DisposeAsync()
    {
        if (_disposed)
        {
            return;
        }

        _disposed = true;
        _watcher.EnableRaisingEvents = false;
        _watcher.Changed -= OnChanged;
        _watcher.Created -= OnCreated;
        _watcher.Deleted -= OnDeleted;
        _watcher.Renamed -= OnRenamed;
        _watcher.Error -= OnError;
        _watcher.Dispose();
        _queue.Writer.TryComplete();
        await Task.CompletedTask.ConfigureAwait(false);
    }

    private void OnChanged(object sender, FileSystemEventArgs eventArgs) =>
        ProjectAndEnqueue(FileActivityOperation.Modified, eventArgs.FullPath, null);

    private void OnCreated(object sender, FileSystemEventArgs eventArgs) =>
        ProjectAndEnqueue(FileActivityOperation.Created, eventArgs.FullPath, null);

    private void OnDeleted(object sender, FileSystemEventArgs eventArgs) =>
        ProjectAndEnqueue(FileActivityOperation.Deleted, eventArgs.FullPath, null);

    private void OnRenamed(object sender, RenamedEventArgs eventArgs) =>
        ProjectAndEnqueue(FileActivityOperation.Renamed, eventArgs.FullPath, eventArgs.OldFullPath);

    private void OnError(object sender, ErrorEventArgs eventArgs)
    {
        var observation = FileActivityContract.NormalizeAndValidate(new FileActivityObservation(
            Interlocked.Increment(ref _sourceSequence),
            _timeProvider.GetUtcNow(),
            FileActivityOperation.WatcherFailure,
            "[blocked]",
            null,
            ActivitySourceKind.FileSystem,
            SourceInstanceId,
            ActivityConfidence.Observed,
            false,
            "watcher-buffer-or-io-failure"));
        _queue.Writer.TryWrite(observation);
    }

    private void ProjectAndEnqueue(
        FileActivityOperation operation,
        string candidatePath,
        string? previousCandidatePath)
    {
        _ = TryProjectCandidate(operation, candidatePath, previousCandidatePath, out var observation);
        if (observation.IsAuthorized &&
            (ShouldExclude(observation.RelativePath) ||
             (observation.PreviousRelativePath is not null && ShouldExclude(observation.PreviousRelativePath))))
        {
            return;
        }

        if (Directory.Exists(candidatePath) || ShouldDebounce(observation))
        {
            return;
        }

        _queue.Writer.TryWrite(observation);
    }

    internal bool ShouldExclude(string relativePath)
    {
        var segments = relativePath.Split(
            ['/', '\\'],
            StringSplitOptions.RemoveEmptyEntries);
        return segments.Any(_excludedDirectoryNames.Contains);
    }

    private bool ShouldDebounce(FileActivityObservation observation)
    {
        if (_debounceWindow == TimeSpan.Zero || !observation.IsAuthorized)
        {
            return false;
        }

        var key = $"{observation.Operation}:{observation.RelativePath}";
        lock (_debounceGate)
        {
            RemoveExpiredOrStaleDebounceEntries(observation.ObservedUtc);
            if (_recentEvents.TryGetValue(key, out var previous) &&
                observation.ObservedUtc >= previous &&
                observation.ObservedUtc - previous < _debounceWindow)
            {
                return true;
            }

            _recentEvents[key] = observation.ObservedUtc;
            _recentEventOrder.Enqueue((key, observation.ObservedUtc));
            while (_recentEvents.Count > _maximumDebounceEntries &&
                   _recentEventOrder.TryDequeue(out var oldest))
            {
                if (_recentEvents.TryGetValue(oldest.Key, out var current) &&
                    current == oldest.ObservedUtc)
                {
                    _recentEvents.Remove(oldest.Key);
                }
            }

            return false;
        }
    }

    private void RemoveExpiredOrStaleDebounceEntries(DateTimeOffset observedUtc)
    {
        while (_recentEventOrder.TryPeek(out var oldest))
        {
            if (!_recentEvents.TryGetValue(oldest.Key, out var current) ||
                current != oldest.ObservedUtc)
            {
                _recentEventOrder.Dequeue();
                continue;
            }

            var age = observedUtc - oldest.ObservedUtc;
            if (age >= TimeSpan.Zero && age < _debounceWindow)
            {
                break;
            }

            _recentEventOrder.Dequeue();
            _recentEvents.Remove(oldest.Key);
        }
    }
}
