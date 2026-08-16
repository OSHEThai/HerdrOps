using HerdrOps.Core;
using HerdrOps.Domain.Herdr;
using HerdrOps.Infrastructure.Herdr;
using HerdrOps.Infrastructure.ReviewIpc;

namespace HerdrOps.IntegrationTests;

[TestClass]
public sealed class HerdrReviewClientProcessAuthorizerTests
{
    private const string PaneId = "w5:p2E";
    private static readonly HerdrPipeEndpoint Endpoint =
        HerdrPipeEndpoint.FromSocketPath(@"\\.\pipe\herdr-test");

    [TestMethod]
    public async Task ExactPaneAcceptsClientProcessThatIsTheAdmittedShellProcess()
    {
        var paneClient = new DeterministicPaneInspectionClient(CreateProcessInfo(PaneId));
        var processAncestry = new DeterministicProcessAncestryReader(
            (processId, admittedRoots) =>
                processId == 700 && admittedRoots.Contains(700u));
        var authorizer = CreateAuthorizer(paneClient, processAncestry);

        var authorized = await authorizer.AuthorizeAsync(
            PaneId,
            clientProcessId: 700,
            CancellationToken.None);

        Assert.IsTrue(authorized);
        Assert.AreEqual(Endpoint, paneClient.LastEndpoint);
        Assert.AreEqual(PaneId, paneClient.LastPaneId);
        Assert.AreEqual(700u, processAncestry.LastProcessId);
        CollectionAssert.AreEquivalent(
            new uint[] { 700, 701 },
            processAncestry.LastAdmittedRoots);
    }

    [TestMethod]
    public async Task ExactPaneAcceptsClientProcessThatIsAnAdmittedDescendant()
    {
        var paneClient = new DeterministicPaneInspectionClient(CreateProcessInfo(PaneId));
        var processAncestry = new DeterministicProcessAncestryReader(
            (processId, admittedRoots) =>
                processId == 702 && admittedRoots.Contains(700u));
        var authorizer = CreateAuthorizer(paneClient, processAncestry);

        var authorized = await authorizer.AuthorizeAsync(
            PaneId,
            clientProcessId: 702,
            CancellationToken.None);

        Assert.IsTrue(authorized);
        Assert.AreEqual(702u, processAncestry.LastProcessId);
        CollectionAssert.AreEquivalent(
            new uint[] { 700, 701 },
            processAncestry.LastAdmittedRoots);
    }

    [TestMethod]
    public async Task MismatchedReturnedPaneIsRejectedBeforeProcessAncestryIsChecked()
    {
        var paneClient = new DeterministicPaneInspectionClient(
            CreateProcessInfo("w5:other"));
        var processAncestry = new DeterministicProcessAncestryReader(
            (_, _) => true);
        var authorizer = CreateAuthorizer(paneClient, processAncestry);

        var authorized = await authorizer.AuthorizeAsync(
            PaneId,
            clientProcessId: 702,
            CancellationToken.None);

        Assert.IsFalse(authorized);
        Assert.AreEqual(0, processAncestry.CallCount);
    }

    [TestMethod]
    public async Task ProcessAncestryRejectionReturnsFalse()
    {
        var paneClient = new DeterministicPaneInspectionClient(CreateProcessInfo(PaneId));
        var processAncestry = new DeterministicProcessAncestryReader(
            (_, _) => false);
        var authorizer = CreateAuthorizer(paneClient, processAncestry);

        var authorized = await authorizer.AuthorizeAsync(
            PaneId,
            clientProcessId: 702,
            CancellationToken.None);

        Assert.IsFalse(authorized);
        Assert.AreEqual(1, processAncestry.CallCount);
    }

    [TestMethod]
    public async Task PaneInspectionIOExceptionReturnsFalse()
    {
        var paneClient = new DeterministicPaneInspectionClient(
            new IOException("Herdr pane inspection failed."));
        var processAncestry = new DeterministicProcessAncestryReader(
            (_, _) => true);
        var authorizer = CreateAuthorizer(paneClient, processAncestry);

        var authorized = await authorizer.AuthorizeAsync(
            PaneId,
            clientProcessId: 702,
            CancellationToken.None);

        Assert.IsFalse(authorized);
        Assert.AreEqual(0, processAncestry.CallCount);
    }

    [TestMethod]
    public async Task PaneInspectionCancellationPropagates()
    {
        using var cancellation = new CancellationTokenSource();
        cancellation.Cancel();
        var paneClient = new DeterministicPaneInspectionClient(
            new OperationCanceledException(cancellation.Token));
        var processAncestry = new DeterministicProcessAncestryReader(
            (_, _) => true);
        var authorizer = CreateAuthorizer(paneClient, processAncestry);

        var exception = await Assert.ThrowsExactlyAsync<OperationCanceledException>(
            async () => await authorizer.AuthorizeAsync(
                PaneId,
                clientProcessId: 702,
                cancellation.Token));

        Assert.AreEqual(cancellation.Token, exception.CancellationToken);
        Assert.AreEqual(0, processAncestry.CallCount);
    }

    [TestMethod]
    public async Task CancellationRequestedAfterPaneInspectionIsObservedBeforeProcessAncestry()
    {
        using var cancellation = new CancellationTokenSource();
        var paneClient = new DeterministicPaneInspectionClient(
            CreateProcessInfo(PaneId),
            cancellation.Cancel);
        var processAncestry = new DeterministicProcessAncestryReader(
            (_, _) => true);
        var authorizer = CreateAuthorizer(paneClient, processAncestry);

        var exception = await Assert.ThrowsExactlyAsync<OperationCanceledException>(
            async () => await authorizer.AuthorizeAsync(
                PaneId,
                clientProcessId: 702,
                cancellation.Token));

        Assert.AreEqual(cancellation.Token, exception.CancellationToken);
        Assert.AreEqual(0, processAncestry.CallCount);
    }

    [TestMethod]
    public void ExactAdmittedProcessRequiresAStableHeldIdentity()
    {
        var snapshotFactory = new DeterministicProcessIdentitySnapshotFactory(
            new Dictionary<uint, IReadOnlyList<WindowsProcessIdentity>>
            {
                [700] = [CreateIdentity(700, 100, 200)],
            });
        var reader = new WindowsProcessAncestryReader(snapshotFactory);

        var admitted = reader.IsSameOrDescendant(700, [700]);

        Assert.IsTrue(admitted);
        CollectionAssert.AreEquivalent(
            new uint[] { 700 },
            snapshotFactory.LastProcessIdsToHold);
        CollectionAssert.AreEquivalent(
            new uint[] { 700 },
            snapshotFactory.LastSnapshot!.LastRefreshProcessIds);
        Assert.AreEqual(1, snapshotFactory.LastSnapshot!.DisposeCount);
    }

    [TestMethod]
    public void DescendantWithMonotonicCreationTimesIsAccepted()
    {
        var snapshotFactory = new DeterministicProcessIdentitySnapshotFactory(
            new Dictionary<uint, IReadOnlyList<WindowsProcessIdentity>>
            {
                [700] = [CreateIdentity(700, 100, 100)],
                [701] = [CreateIdentity(701, 700, 200)],
                [702] = [CreateIdentity(702, 701, 300)],
            });
        var reader = new WindowsProcessAncestryReader(snapshotFactory);

        var admitted = reader.IsSameOrDescendant(702, [700]);

        Assert.IsTrue(admitted);
        CollectionAssert.AreEquivalent(
            new uint[] { 700, 702 },
            snapshotFactory.LastProcessIdsToHold);
        CollectionAssert.AreEquivalent(
            new uint[] { 700, 701, 702 },
            snapshotFactory.LastSnapshot!.HeldProcessIds);
        CollectionAssert.AreEquivalent(
            new uint[] { 700, 701, 702 },
            snapshotFactory.LastSnapshot!.LastRefreshProcessIds);
        Assert.AreEqual(1, snapshotFactory.LastSnapshot!.DisposeCount);
    }

    [TestMethod]
    public void IntermediatePidReuseAfterInitialParentSnapshotIsRejected()
    {
        var snapshotFactory = new DeterministicProcessIdentitySnapshotFactory(
            new Dictionary<uint, IReadOnlyList<WindowsProcessIdentity>>
            {
                [700] = [CreateIdentity(700, 100, 100)],
                [701] = [CreateIdentity(701, 700, 200)],
                [702] = [CreateIdentity(702, 701, 300)],
            },
            new Dictionary<uint, IReadOnlyList<WindowsProcessIdentity>>
            {
                [700] = [CreateIdentity(700, 100, 100)],
                [701] = [CreateIdentity(701, 700, 400)],
                [702] = [CreateIdentity(702, 701, 300)],
            });
        var reader = new WindowsProcessAncestryReader(snapshotFactory);

        var admitted = reader.IsSameOrDescendant(702, [700]);

        Assert.IsFalse(admitted);
        CollectionAssert.AreEquivalent(
            new uint[] { 700, 701, 702 },
            snapshotFactory.LastSnapshot!.LastRefreshProcessIds);
        Assert.AreEqual(1, snapshotFactory.LastSnapshot.DisposeCount);
    }

    [TestMethod]
    public void ChangedIntermediateParentageAfterInitialParentSnapshotIsRejected()
    {
        var snapshotFactory = new DeterministicProcessIdentitySnapshotFactory(
            new Dictionary<uint, IReadOnlyList<WindowsProcessIdentity>>
            {
                [700] = [CreateIdentity(700, 100, 100)],
                [701] = [CreateIdentity(701, 700, 200)],
                [702] = [CreateIdentity(702, 701, 300)],
            },
            new Dictionary<uint, IReadOnlyList<WindowsProcessIdentity>>
            {
                [700] = [CreateIdentity(700, 100, 100)],
                [701] = [CreateIdentity(701, 999, 200)],
                [702] = [CreateIdentity(702, 701, 300)],
            });
        var reader = new WindowsProcessAncestryReader(snapshotFactory);

        var admitted = reader.IsSameOrDescendant(702, [700]);

        Assert.IsFalse(admitted);
        Assert.AreEqual(1, snapshotFactory.LastSnapshot!.DisposeCount);
    }

    [TestMethod]
    public void CycleClosingThroughAdmittedRootIsRejected()
    {
        var snapshotFactory = new DeterministicProcessIdentitySnapshotFactory(
            new Dictionary<uint, IReadOnlyList<WindowsProcessIdentity>>
            {
                [700] = [CreateIdentity(700, 702, 100)],
                [701] = [CreateIdentity(701, 700, 200)],
                [702] = [CreateIdentity(702, 701, 300)],
            });
        var reader = new WindowsProcessAncestryReader(snapshotFactory);

        var admitted = reader.IsSameOrDescendant(702, [700]);

        Assert.IsFalse(admitted);
        Assert.AreEqual(1, snapshotFactory.LastSnapshot!.DisposeCount);
    }

    [TestMethod]
    public void CreationTimeInversionNearAdmittedRootRejectsPidReuseSimulation()
    {
        var snapshotFactory = new DeterministicProcessIdentitySnapshotFactory(
            new Dictionary<uint, IReadOnlyList<WindowsProcessIdentity>>
            {
                [700] = [CreateIdentity(700, 100, 250)],
                [701] = [CreateIdentity(701, 700, 200)],
                [702] = [CreateIdentity(702, 701, 300)],
                [703] = [CreateIdentity(703, 702, 400)],
            });
        var reader = new WindowsProcessAncestryReader(snapshotFactory);

        var admitted = reader.IsSameOrDescendant(703, [700]);

        Assert.IsFalse(admitted);
        Assert.AreEqual(1, snapshotFactory.LastSnapshot!.DisposeCount);
    }

    [TestMethod]
    public void EqualCreationTimesAcrossAncestryEdgeAreRejected()
    {
        var snapshotFactory = new DeterministicProcessIdentitySnapshotFactory(
            new Dictionary<uint, IReadOnlyList<WindowsProcessIdentity>>
            {
                [700] = [CreateIdentity(700, 100, 200)],
                [701] = [CreateIdentity(701, 700, 200)],
                [702] = [CreateIdentity(702, 701, 300)],
            });
        var reader = new WindowsProcessAncestryReader(snapshotFactory);

        var admitted = reader.IsSameOrDescendant(702, [700]);

        Assert.IsFalse(admitted);
        Assert.AreEqual(1, snapshotFactory.LastSnapshot!.DisposeCount);
    }

    [TestMethod]
    public void IdentityChangeDuringAuthorizationRejectsPidReuseSimulation()
    {
        var snapshotFactory = new DeterministicProcessIdentitySnapshotFactory(
            new Dictionary<uint, IReadOnlyList<WindowsProcessIdentity>>
            {
                [700] =
                [
                    CreateIdentity(700, 100, 200),
                    CreateIdentity(700, 100, 201),
                ],
            });
        var reader = new WindowsProcessAncestryReader(snapshotFactory);

        var admitted = reader.IsSameOrDescendant(700, [700]);

        Assert.IsFalse(admitted);
        Assert.AreEqual(1, snapshotFactory.LastSnapshot!.DisposeCount);
    }

    [TestMethod]
    public void InaccessibleOrExitedAncestorIsRejectedAndHeldIdentitiesAreDisposed()
    {
        var snapshotFactory = new DeterministicProcessIdentitySnapshotFactory(
            new Dictionary<uint, IReadOnlyList<WindowsProcessIdentity>>
            {
                [700] = [CreateIdentity(700, 100, 100)],
                [702] = [CreateIdentity(702, 701, 300)],
            });
        var reader = new WindowsProcessAncestryReader(snapshotFactory);

        var admitted = reader.IsSameOrDescendant(702, [700]);

        Assert.IsFalse(admitted);
        Assert.AreEqual(1, snapshotFactory.LastSnapshot!.DisposeCount);
    }

    [TestMethod]
    public void ParentRecaptureFailureRejectsAndDisposesEveryHeldIdentity()
    {
        var snapshotFactory = new DeterministicProcessIdentitySnapshotFactory(
            new Dictionary<uint, IReadOnlyList<WindowsProcessIdentity>>
            {
                [700] = [CreateIdentity(700, 100, 100)],
                [701] = [CreateIdentity(701, 700, 200)],
                [702] = [CreateIdentity(702, 701, 300)],
            },
            refreshSucceeds: false);
        var reader = new WindowsProcessAncestryReader(snapshotFactory);

        var admitted = reader.IsSameOrDescendant(702, [700]);

        Assert.IsFalse(admitted);
        CollectionAssert.AreEquivalent(
            new uint[] { 700, 701, 702 },
            snapshotFactory.LastSnapshot!.HeldProcessIds);
        Assert.AreEqual(1, snapshotFactory.LastSnapshot.DisposeCount);
    }

    [TestMethod]
    public void MalformedRecapturedSnapshotRejectsAndDisposesEveryHeldIdentity()
    {
        var snapshotFactory = new DeterministicProcessIdentitySnapshotFactory(
            new Dictionary<uint, IReadOnlyList<WindowsProcessIdentity>>
            {
                [700] = [CreateIdentity(700, 100, 100)],
                [701] = [CreateIdentity(701, 700, 200)],
                [702] = [CreateIdentity(702, 701, 300)],
            },
            new Dictionary<uint, IReadOnlyList<WindowsProcessIdentity>>
            {
                [700] = [CreateIdentity(700, 100, 100)],
                [702] = [CreateIdentity(702, 701, 300)],
            });
        var reader = new WindowsProcessAncestryReader(snapshotFactory);

        var admitted = reader.IsSameOrDescendant(702, [700]);

        Assert.IsFalse(admitted);
        CollectionAssert.AreEquivalent(
            new uint[] { 700, 701, 702 },
            snapshotFactory.LastSnapshot!.HeldProcessIds);
        Assert.AreEqual(1, snapshotFactory.LastSnapshot.DisposeCount);
    }

    private static HerdrReviewClientProcessAuthorizer CreateAuthorizer(
        IHerdrPaneInspectionClient paneClient,
        IWindowsProcessAncestryReader processAncestry) =>
        new(paneClient, Endpoint, processAncestry);

    private static HerdrPaneProcessInfo CreateProcessInfo(string paneId) =>
        new(
            paneId,
            ShellProcessId: 700,
            ForegroundProcessGroupId: 701,
            Tty: null,
            [
                new HerdrPaneProcess(
                    701,
                    "pwsh",
                    "pwsh",
                    Arguments: null,
                    CommandLine: "pwsh -NoLogo",
                    CurrentDirectory: @"Z:\HerdrOps"),
            ]);

    private static WindowsProcessIdentity CreateIdentity(
        uint processId,
        uint parentProcessId,
        ulong creationTimeUtcFileTime) =>
        new(processId, parentProcessId, creationTimeUtcFileTime);

    private sealed class DeterministicPaneInspectionClient : IHerdrPaneInspectionClient
    {
        private readonly HerdrPaneProcessInfo? _processInfo;
        private readonly Exception? _exception;
        private readonly Action? _afterProcessInfo;

        public DeterministicPaneInspectionClient(
            HerdrPaneProcessInfo processInfo,
            Action? afterProcessInfo = null)
        {
            _processInfo = processInfo;
            _afterProcessInfo = afterProcessInfo;
        }

        public DeterministicPaneInspectionClient(Exception exception)
        {
            _exception = exception;
        }

        public HerdrServerProcessIdentity? LastVerifiedServerIdentity => null;

        public HerdrPipeEndpoint? LastEndpoint { get; private set; }

        public string? LastPaneId { get; private set; }

        public Task<HerdrPaneReadResult> ReadRecentUnwrappedAsync(
            HerdrPipeEndpoint endpoint,
            string paneId,
            int maximumLines,
            CancellationToken cancellationToken) =>
            Task.FromException<HerdrPaneReadResult>(
                new NotSupportedException("Pane text reads are not part of this test fake."));

        public Task<HerdrPaneProcessInfo> GetPaneProcessInfoAsync(
            HerdrPipeEndpoint endpoint,
            string paneId,
            CancellationToken cancellationToken)
        {
            LastEndpoint = endpoint;
            LastPaneId = paneId;
            if (_exception is not null)
            {
                return Task.FromException<HerdrPaneProcessInfo>(_exception);
            }

            _afterProcessInfo?.Invoke();
            return Task.FromResult(_processInfo!);
        }
    }

    private sealed class DeterministicProcessAncestryReader(
        Func<uint, IReadOnlyCollection<uint>, bool> decision) : IWindowsProcessAncestryReader
    {
        public int CallCount { get; private set; }

        public uint LastProcessId { get; private set; }

        public uint[] LastAdmittedRoots { get; private set; } = [];

        public bool IsSameOrDescendant(
            uint processId,
            IReadOnlyCollection<uint> admittedRootProcessIds)
        {
            CallCount++;
            LastProcessId = processId;
            LastAdmittedRoots = [.. admittedRootProcessIds];
            return decision(processId, admittedRootProcessIds);
        }
    }

    private sealed class DeterministicProcessIdentitySnapshotFactory(
        IReadOnlyDictionary<uint, IReadOnlyList<WindowsProcessIdentity>> identities,
        IReadOnlyDictionary<uint, IReadOnlyList<WindowsProcessIdentity>>? refreshedIdentities = null,
        bool refreshSucceeds = true)
        : IWindowsProcessIdentitySnapshotFactory
    {
        public uint[] LastProcessIdsToHold { get; private set; } = [];

        public DeterministicProcessIdentitySnapshot? LastSnapshot { get; private set; }

        public IWindowsProcessIdentitySnapshot Capture(
            IReadOnlyCollection<uint> processIdsToHold)
        {
            LastProcessIdsToHold = [.. processIdsToHold];
            LastSnapshot = new DeterministicProcessIdentitySnapshot(
                identities,
                refreshedIdentities ?? identities,
                refreshSucceeds);
            return LastSnapshot;
        }
    }

    private sealed class DeterministicProcessIdentitySnapshot(
        IReadOnlyDictionary<uint, IReadOnlyList<WindowsProcessIdentity>> initialIdentities,
        IReadOnlyDictionary<uint, IReadOnlyList<WindowsProcessIdentity>> refreshedIdentities,
        bool refreshSucceeds)
        : IWindowsProcessIdentitySnapshot
    {
        private readonly Dictionary<uint, int> _readCountByProcess = [];
        private readonly HashSet<uint> _heldProcessIds = [];
        private bool _disposed;
        private bool _usingRefreshedIdentities;

        public int DisposeCount { get; private set; }

        public uint[] HeldProcessIds => [.. _heldProcessIds];

        public uint[] LastRefreshProcessIds { get; private set; } = [];

        public bool TryGetIdentity(
            uint processId,
            out WindowsProcessIdentity identity)
        {
            ObjectDisposedException.ThrowIf(_disposed, this);
            identity = default;
            var identities = _usingRefreshedIdentities
                ? refreshedIdentities
                : initialIdentities;
            if (!identities.TryGetValue(processId, out var sequence) ||
                sequence.Count == 0)
            {
                return false;
            }

            var readCount = _readCountByProcess.GetValueOrDefault(processId);
            identity = sequence[Math.Min(readCount, sequence.Count - 1)];
            _readCountByProcess[processId] = readCount + 1;
            _heldProcessIds.Add(processId);
            return true;
        }

        public bool TryRefreshParentRelationships(
            IReadOnlyCollection<uint> processIdsToHold)
        {
            ObjectDisposedException.ThrowIf(_disposed, this);
            LastRefreshProcessIds = [.. processIdsToHold];
            if (!refreshSucceeds ||
                processIdsToHold.Count == 0 ||
                processIdsToHold.Any(item => item == 0) ||
                processIdsToHold.Distinct().Count() != processIdsToHold.Count ||
                processIdsToHold.Any(item => !_heldProcessIds.Contains(item)) ||
                processIdsToHold.Any(item =>
                    !refreshedIdentities.TryGetValue(item, out var sequence) ||
                    sequence.Count == 0 ||
                    sequence[0].ProcessId != item ||
                    sequence[0].CreationTimeUtcFileTime == 0))
            {
                return false;
            }

            _usingRefreshedIdentities = true;
            return true;
        }

        public void Dispose()
        {
            if (_disposed)
            {
                return;
            }

            _disposed = true;
            DisposeCount++;
        }
    }
}
