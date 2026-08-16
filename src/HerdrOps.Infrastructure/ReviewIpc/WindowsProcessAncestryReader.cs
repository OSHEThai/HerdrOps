using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;

namespace HerdrOps.Infrastructure.ReviewIpc;

public interface IWindowsProcessAncestryReader
{
    bool IsSameOrDescendant(
        uint processId,
        IReadOnlyCollection<uint> admittedRootProcessIds);
}

internal readonly record struct WindowsProcessIdentity(
    uint ProcessId,
    uint ParentProcessId,
    ulong CreationTimeUtcFileTime);

internal interface IWindowsProcessIdentitySnapshot : IDisposable
{
    bool TryGetIdentity(uint processId, out WindowsProcessIdentity identity);

    bool TryRefreshParentRelationships(
        IReadOnlyCollection<uint> processIdsToHold);
}

internal interface IWindowsProcessIdentitySnapshotFactory
{
    IWindowsProcessIdentitySnapshot Capture(
        IReadOnlyCollection<uint> processIdsToHold);
}

public sealed class WindowsProcessAncestryReader : IWindowsProcessAncestryReader
{
    private const uint SnapshotProcesses = 0x00000002;
    private const uint ProcessQueryLimitedInformation = 0x00001000;
    private const uint Synchronize = 0x00100000;
    private const uint WaitTimeout = 0x00000102;
    private const int MaximumAncestryDepth = 256;
    private const int MaximumHeldProcessCount = MaximumAncestryDepth + 1;
    private const int ErrorNoMoreFiles = 18;

    private readonly IWindowsProcessIdentitySnapshotFactory _snapshotFactory;

    public WindowsProcessAncestryReader()
        : this(new NativeWindowsProcessIdentitySnapshotFactory())
    {
    }

    internal WindowsProcessAncestryReader(
        IWindowsProcessIdentitySnapshotFactory snapshotFactory)
    {
        _snapshotFactory = snapshotFactory ??
            throw new ArgumentNullException(nameof(snapshotFactory));
    }

    public bool IsSameOrDescendant(
        uint processId,
        IReadOnlyCollection<uint> admittedRootProcessIds)
    {
        ArgumentNullException.ThrowIfNull(admittedRootProcessIds);
        if (processId == 0 || admittedRootProcessIds.Count == 0)
        {
            return false;
        }

        var admittedRoots = admittedRootProcessIds
            .Where(item => item != 0)
            .ToHashSet();
        if (admittedRoots.Count == 0)
        {
            return false;
        }

        var processIdsToHold = admittedRoots
            .Append(processId)
            .Distinct()
            .ToArray();
        if (processIdsToHold.Length > MaximumHeldProcessCount)
        {
            return false;
        }

        try
        {
            using var snapshot = _snapshotFactory.Capture(processIdsToHold);
            if (!TryGetValidIdentity(snapshot, processId, out var current))
            {
                return false;
            }

            var heldChain = new List<WindowsProcessIdentity> { current };
            if (admittedRoots.Contains(processId))
            {
                return IsHeldChainAccepted(snapshot, heldChain);
            }

            var visited = new HashSet<uint>();
            for (var depth = 0; depth < MaximumAncestryDepth; depth++)
            {
                if (!visited.Add(current.ProcessId) ||
                    current.ParentProcessId == 0 ||
                    current.ParentProcessId == current.ProcessId ||
                    !TryGetValidIdentity(
                        snapshot,
                        current.ParentProcessId,
                        out var parent) ||
                    parent.CreationTimeUtcFileTime >=
                        current.CreationTimeUtcFileTime)
                {
                    return false;
                }

                heldChain.Add(parent);
                if (heldChain.Count > MaximumHeldProcessCount)
                {
                    return false;
                }

                if (admittedRoots.Contains(parent.ProcessId))
                {
                    return IsHeldChainAccepted(snapshot, heldChain);
                }

                current = parent;
            }

            return false;
        }
        catch (Exception exception) when (
            exception is IOException or
            UnauthorizedAccessException or
            InvalidOperationException or
            ArgumentException or
            OverflowException)
        {
            return false;
        }
    }

    private static bool TryGetValidIdentity(
        IWindowsProcessIdentitySnapshot snapshot,
        uint processId,
        out WindowsProcessIdentity identity)
    {
        if (snapshot.TryGetIdentity(processId, out identity) &&
            identity.ProcessId == processId &&
            identity.CreationTimeUtcFileTime > 0)
        {
            return true;
        }

        identity = default;
        return false;
    }

    private static bool IsHeldChainAccepted(
        IWindowsProcessIdentitySnapshot snapshot,
        IReadOnlyList<WindowsProcessIdentity> heldChain)
    {
        if (heldChain.Count == 0 ||
            heldChain.Count > MaximumHeldProcessCount ||
            heldChain.Select(item => item.ProcessId).Distinct().Count() !=
                heldChain.Count ||
            !snapshot.TryRefreshParentRelationships(
                heldChain.Select(item => item.ProcessId).ToArray()))
        {
            return false;
        }

        return IsHeldChainStillValid(snapshot, heldChain);
    }

    private static bool IsHeldChainStillValid(
        IWindowsProcessIdentitySnapshot snapshot,
        IReadOnlyList<WindowsProcessIdentity> heldChain)
    {
        var chainProcessIds = heldChain
            .Select(item => item.ProcessId)
            .ToHashSet();
        for (var index = 0; index < heldChain.Count; index++)
        {
            var expected = heldChain[index];
            if (!TryGetValidIdentity(snapshot, expected.ProcessId, out var current) ||
                current != expected ||
                current.ParentProcessId == current.ProcessId ||
                (index < heldChain.Count - 1 &&
                    current.ParentProcessId != heldChain[index + 1].ProcessId) ||
                (index < heldChain.Count - 1 &&
                    heldChain[index + 1].CreationTimeUtcFileTime >=
                        current.CreationTimeUtcFileTime) ||
                (index == heldChain.Count - 1 &&
                    chainProcessIds.Contains(current.ParentProcessId)))
            {
                return false;
            }
        }

        return true;
    }

    private static IReadOnlyDictionary<uint, uint> ReadProcessParents()
    {
        using var snapshot = CreateToolhelp32Snapshot(SnapshotProcesses, 0);
        if (snapshot.IsInvalid)
        {
            throw new IOException(
                "Windows could not create a process snapshot for Herdr pane attestation.");
        }

        var parents = new Dictionary<uint, uint>();
        var expectedEntrySize = checked((uint)Marshal.SizeOf<ProcessEntry32>());
        var entry = new ProcessEntry32
        {
            Size = expectedEntrySize,
        };
        if (!Process32First(snapshot, ref entry))
        {
            throw new IOException(
                "Windows returned no process entries for Herdr pane attestation.");
        }

        while (true)
        {
            if (entry.Size != expectedEntrySize ||
                !parents.TryAdd(entry.ProcessId, entry.ParentProcessId))
            {
                throw new IOException(
                    "Windows returned a malformed process snapshot for Herdr pane attestation.");
            }

            entry = new ProcessEntry32
            {
                Size = expectedEntrySize,
            };
            if (Process32Next(snapshot, ref entry))
            {
                continue;
            }

            var error = Marshal.GetLastWin32Error();
            if (error != ErrorNoMoreFiles)
            {
                throw new IOException(
                    "Windows could not finish the process snapshot for Herdr pane attestation.");
            }

            break;
        }

        return parents;
    }

    private static HeldProcessIdentity? TryOpenHeldProcess(uint processId)
    {
        var handle = OpenProcess(
            ProcessQueryLimitedInformation | Synchronize,
            inheritHandle: false,
            processId);
        if (handle.IsInvalid)
        {
            handle.Dispose();
            return null;
        }

        if (!IsProcessRunning(handle) ||
            !GetProcessTimes(
                handle,
                out var creationTime,
                out _,
                out _,
                out _) ||
            !IsProcessRunning(handle))
        {
            handle.Dispose();
            return null;
        }

        var creationTimeUtcFileTime = creationTime.ToUInt64();
        if (creationTimeUtcFileTime == 0)
        {
            handle.Dispose();
            return null;
        }

        return new HeldProcessIdentity(handle, creationTimeUtcFileTime);
    }

    private static bool TryReadHeldProcessCreationTime(
        HeldProcessIdentity heldProcess,
        out ulong creationTimeUtcFileTime)
    {
        creationTimeUtcFileTime = 0;
        if (!IsProcessRunning(heldProcess.Handle) ||
            !GetProcessTimes(
                heldProcess.Handle,
                out var creationTime,
                out _,
                out _,
                out _) ||
            !IsProcessRunning(heldProcess.Handle))
        {
            return false;
        }

        creationTimeUtcFileTime = creationTime.ToUInt64();
        return creationTimeUtcFileTime > 0 &&
            creationTimeUtcFileTime == heldProcess.CreationTimeUtcFileTime;
    }

    private static bool IsProcessRunning(SafeProcessHandle handle) =>
        WaitForSingleObject(handle, milliseconds: 0) == WaitTimeout;

    private sealed class NativeWindowsProcessIdentitySnapshotFactory
        : IWindowsProcessIdentitySnapshotFactory
    {
        public IWindowsProcessIdentitySnapshot Capture(
            IReadOnlyCollection<uint> processIdsToHold)
        {
            ArgumentNullException.ThrowIfNull(processIdsToHold);
            var requiredProcessIds = processIdsToHold
                .Where(item => item != 0)
                .ToHashSet();
            if (requiredProcessIds.Count == 0 ||
                requiredProcessIds.Count > MaximumHeldProcessCount)
            {
                throw new ArgumentException(
                    "The process identity snapshot exceeded its handle bound.",
                    nameof(processIdsToHold));
            }

            var heldProcesses = new Dictionary<uint, HeldProcessIdentity>();
            try
            {
                foreach (var processId in requiredProcessIds)
                {
                    var heldProcess = TryOpenHeldProcess(processId);
                    if (heldProcess is not null)
                    {
                        heldProcesses.Add(processId, heldProcess);
                    }
                }

                return new NativeWindowsProcessIdentitySnapshot(
                    ReadProcessParents(),
                    requiredProcessIds,
                    heldProcesses);
            }
            catch
            {
                foreach (var heldProcess in heldProcesses.Values)
                {
                    heldProcess.Handle.Dispose();
                }

                throw;
            }
        }
    }

    private sealed class NativeWindowsProcessIdentitySnapshot(
        IReadOnlyDictionary<uint, uint> parentByProcess,
        IReadOnlySet<uint> requiredProcessIds,
        Dictionary<uint, HeldProcessIdentity> heldProcesses)
        : IWindowsProcessIdentitySnapshot
    {
        private IReadOnlyDictionary<uint, uint> _parentByProcess =
            parentByProcess;
        private readonly IReadOnlySet<uint> _requiredProcessIds =
            requiredProcessIds;
        private readonly Dictionary<uint, HeldProcessIdentity> _heldProcesses =
            heldProcesses;
        private bool _disposed;

        public bool TryGetIdentity(
            uint processId,
            out WindowsProcessIdentity identity)
        {
            ObjectDisposedException.ThrowIf(_disposed, this);
            identity = default;
            if (processId == 0 ||
                !_parentByProcess.TryGetValue(processId, out var parentProcessId))
            {
                return false;
            }

            if (!_heldProcesses.TryGetValue(processId, out var heldProcess))
            {
                if (_requiredProcessIds.Contains(processId))
                {
                    return false;
                }

                if (_heldProcesses.Count >= MaximumHeldProcessCount)
                {
                    return false;
                }

                heldProcess = TryOpenHeldProcess(processId);
                if (heldProcess is null)
                {
                    return false;
                }

                _heldProcesses.Add(processId, heldProcess);
            }

            if (!TryReadHeldProcessCreationTime(
                    heldProcess,
                    out var creationTimeUtcFileTime))
            {
                return false;
            }

            identity = new WindowsProcessIdentity(
                processId,
                parentProcessId,
                creationTimeUtcFileTime);
            return true;
        }

        public bool TryRefreshParentRelationships(
            IReadOnlyCollection<uint> processIdsToHold)
        {
            ObjectDisposedException.ThrowIf(_disposed, this);
            ArgumentNullException.ThrowIfNull(processIdsToHold);

            var processIds = processIdsToHold.ToArray();
            if (processIds.Length == 0 ||
                processIds.Length > MaximumHeldProcessCount ||
                processIds.Any(item => item == 0) ||
                processIds.Distinct().Count() != processIds.Length)
            {
                return false;
            }

            foreach (var processId in processIds)
            {
                if (!_heldProcesses.TryGetValue(processId, out var heldProcess) ||
                    !TryReadHeldProcessCreationTime(
                        heldProcess,
                        out _))
                {
                    return false;
                }
            }

            IReadOnlyDictionary<uint, uint> refreshedParents;
            try
            {
                refreshedParents = ReadProcessParents();
            }
            catch (Exception exception) when (
                exception is IOException or
                UnauthorizedAccessException or
                InvalidOperationException or
                ArgumentException or
                OverflowException)
            {
                return false;
            }

            if (processIds.Any(item => !refreshedParents.ContainsKey(item)))
            {
                return false;
            }

            _parentByProcess = refreshedParents;
            return true;
        }

        public void Dispose()
        {
            if (_disposed)
            {
                return;
            }

            foreach (var heldProcess in _heldProcesses.Values)
            {
                heldProcess.Handle.Dispose();
            }

            _heldProcesses.Clear();
            _disposed = true;
        }
    }

    private sealed record HeldProcessIdentity(
        SafeProcessHandle Handle,
        ulong CreationTimeUtcFileTime);

    [StructLayout(LayoutKind.Sequential)]
    private readonly struct NativeFileTime
    {
        public readonly uint LowDateTime;
        public readonly uint HighDateTime;

        public ulong ToUInt64() =>
            ((ulong)HighDateTime << 32) | LowDateTime;
    }

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    private struct ProcessEntry32
    {
        public uint Size;
        public uint Usage;
        public uint ProcessId;
        public nint DefaultHeapId;
        public uint ModuleId;
        public uint ThreadCount;
        public uint ParentProcessId;
        public int BasePriority;
        public uint Flags;

        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 260)]
        public string ExecutableFile;
    }

    private sealed class ToolhelpSnapshotHandle : SafeHandleZeroOrMinusOneIsInvalid
    {
        private ToolhelpSnapshotHandle()
            : base(ownsHandle: true)
        {
        }

        protected override bool ReleaseHandle() => CloseHandle(handle);
    }

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern SafeProcessHandle OpenProcess(
        uint desiredAccess,
        [MarshalAs(UnmanagedType.Bool)] bool inheritHandle,
        uint processId);

    [DllImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool GetProcessTimes(
        SafeProcessHandle processHandle,
        out NativeFileTime creationTime,
        out NativeFileTime exitTime,
        out NativeFileTime kernelTime,
        out NativeFileTime userTime);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern uint WaitForSingleObject(
        SafeProcessHandle processHandle,
        uint milliseconds);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern ToolhelpSnapshotHandle CreateToolhelp32Snapshot(
        uint flags,
        uint processId);

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool Process32First(
        ToolhelpSnapshotHandle snapshot,
        ref ProcessEntry32 entry);

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool Process32Next(
        ToolhelpSnapshotHandle snapshot,
        ref ProcessEntry32 entry);

    [DllImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool CloseHandle(nint handle);
}
