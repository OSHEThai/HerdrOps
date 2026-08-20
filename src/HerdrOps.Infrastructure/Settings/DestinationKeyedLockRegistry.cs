using System.Collections.Generic;

namespace HerdrOps.Infrastructure.Settings;

/// <summary>
/// Provides process-local keyed asynchronous locks whose entries are retained
/// only while an owner or waiter still references them.
/// </summary>
internal sealed class DestinationKeyedLockRegistry
{
    private readonly object _sync = new();
    private readonly Dictionary<string, Entry> _entries;

    public DestinationKeyedLockRegistry(StringComparer comparer)
    {
        _entries = new Dictionary<string, Entry>(comparer);
    }

    public int EntryCount
    {
        get
        {
            lock (_sync)
            {
                return _entries.Count;
            }
        }
    }

    public int GetReferenceCount(string key)
    {
        lock (_sync)
        {
            return _entries.TryGetValue(key, out var entry)
                ? entry.ReferenceCount
                : 0;
        }
    }

    public async ValueTask<Lease> AcquireAsync(
        string key,
        CancellationToken cancellationToken = default)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(key);

        Entry entry;
        lock (_sync)
        {
            if (!_entries.TryGetValue(key, out entry!))
            {
                entry = new Entry();
                _entries.Add(key, entry);
            }

            // The reference is acquired before waiting. Therefore an entry
            // cannot be evicted or disposed while this waiter is registered.
            entry.ReferenceCount++;
        }

        try
        {
            await entry.Gate.WaitAsync(cancellationToken).ConfigureAwait(false);
            return new Lease(this, key, entry);
        }
        catch
        {
            ReleaseReference(key, entry);
            throw;
        }
    }

    private void Release(Lease lease)
    {
        try
        {
            lease.Entry.Gate.Release();
        }
        finally
        {
            ReleaseReference(lease.Key, lease.Entry);
        }
    }

    private void ReleaseReference(string key, Entry entry)
    {
        var dispose = false;
        lock (_sync)
        {
            if (entry.ReferenceCount <= 0)
            {
                throw new InvalidOperationException("The destination lock reference count is already zero.");
            }

            entry.ReferenceCount--;
            if (entry.ReferenceCount == 0)
            {
                if (!_entries.TryGetValue(key, out var current)
                    || !ReferenceEquals(current, entry))
                {
                    throw new InvalidOperationException("The destination lock registry entry changed unexpectedly.");
                }

                _entries.Remove(key);
                dispose = true;
            }
        }

        // No owner or waiter can still reference the gate after the zero
        // transition above. Dispose outside the registry monitor so a slow
        // framework cleanup cannot block unrelated keys.
        if (dispose)
        {
            entry.Gate.Dispose();
        }
    }

    internal sealed class Entry
    {
        public SemaphoreSlim Gate { get; } = new(1, 1);

        public int ReferenceCount { get; set; }
    }

    internal sealed class Lease : IDisposable, IAsyncDisposable
    {
        private readonly DestinationKeyedLockRegistry _registry;
        private int _disposed;

        internal Lease(DestinationKeyedLockRegistry registry, string key, Entry entry)
        {
            _registry = registry;
            Key = key;
            Entry = entry;
        }

        internal string Key { get; }

        internal Entry Entry { get; }

        public void Dispose()
        {
            if (Interlocked.Exchange(ref _disposed, 1) != 0)
            {
                return;
            }

            _registry.Release(this);
        }

        public ValueTask DisposeAsync()
        {
            Dispose();
            return ValueTask.CompletedTask;
        }
    }
}
