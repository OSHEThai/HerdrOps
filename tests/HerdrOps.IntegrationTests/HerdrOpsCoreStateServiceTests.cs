using System.Diagnostics;
using System.Text.Json;
using HerdrOps.Core;
using HerdrOps.Domain.Herdr;
using HerdrOps.Infrastructure.Herdr;
using HerdrOps.Infrastructure.StateIpc;
using HerdrOps.Infrastructure.Storage;

namespace HerdrOps.IntegrationTests;

[TestClass]
public sealed class HerdrOpsCoreStateServiceTests
{
    [TestMethod]
    public async Task ServiceKeepsPipeAliveUntilCoreCancellation()
    {
        using var directory = new TemporaryDirectory();
        using var store = new SqliteHerdrStateStore(new HerdrStateStoreOptions(
            Path.Combine(directory.Path, "herdrops.db")));
        var coordinator = new HerdrStateProjectionCoordinator(
            store,
            new HerdrOpsStatePipeServerOptions($"herdrops-service-{Guid.NewGuid():N}"));
        var monitor = new HerdrRuntimeMonitor(
            new BlockingApiClient(),
            HerdrPipeEndpoint.FromSocketPath("herdrops-service-test"),
            reconnectDelay: new HerdrExponentialReconnectDelay());
        var service = new HerdrOpsCoreStateService(monitor, coordinator);
        using var cancellation = new CancellationTokenSource();
        var serviceTask = service.RunAsync(cancellation.Token);

        await coordinator.PipeServer.Ready.WaitAsync(TimeSpan.FromSeconds(5));
        Assert.IsFalse(serviceTask.IsCompleted);
        cancellation.Cancel();
        await serviceTask.WaitAsync(TimeSpan.FromSeconds(5));

        Assert.AreEqual(HerdrRuntimeMonitorStatus.Stopped, monitor.Current.Status);
        Assert.IsNull(store.ReadCurrent());
    }

    [TestMethod]
    public async Task ServiceCommandRejectsMissingHerdrWithNonZeroResult()
    {
        using var directory = new TemporaryDirectory();
        var output = new StringWriter();
        var error = new StringWriter();
        var exitCode = await HerdrOpsCoreStateServiceCommand.RunAsync(
            [
                "serve-herdr-state",
                "--database",
                Path.Combine(directory.Path, "herdrops.db"),
                "--herdr",
                Path.Combine(directory.Path, "missing-herdr.exe"),
                "--socket-path",
                "must-not-connect",
            ],
            output,
            error);

        Assert.AreEqual(2, exitCode);
        StringAssert.Contains(error.ToString(), "Core state service failed", StringComparison.Ordinal);
        StringAssert.Contains(error.ToString(), "not found", StringComparison.OrdinalIgnoreCase);
    }

    [TestMethod]
    public async Task ServiceCommandRejectsIncompleteOptionBeforeRuntimeWork()
    {
        var output = new StringWriter();
        var error = new StringWriter();

        var exitCode = await HerdrOpsCoreStateServiceCommand.RunAsync(
            ["serve-herdr-state", "--database"],
            output,
            error);

        Assert.AreEqual(64, exitCode);
        StringAssert.Contains(error.ToString(), "Invalid or incomplete option", StringComparison.Ordinal);
    }

    [TestMethod]
    public async Task ServiceCommandRequiresCompleteRuntimeEvidenceOptions()
    {
        var output = new StringWriter();
        var error = new StringWriter();

        var exitCode = await HerdrOpsCoreStateServiceCommand.RunAsync(
            ["serve-herdr-state", "--seconds", "120"],
            output,
            error,
            environmentVariableReader: _ => null);

        Assert.AreEqual(64, exitCode);
        StringAssert.Contains(error.ToString(), "requires --report", StringComparison.Ordinal);
    }

    [TestMethod]
    public async Task ServiceCommandRuntimeEvidenceRequiresAuthorizedHerdrEnvironment()
    {
        using var directory = new TemporaryDirectory();
        var output = new StringWriter();
        var error = new StringWriter();

        var exitCode = await HerdrOpsCoreStateServiceCommand.RunAsync(
            [
                "serve-herdr-state",
                "--database", Path.Combine(directory.Path, "runtime.db"),
                "--herdr", Path.Combine(directory.Path, "herdr.exe"),
                "--socket-path", "herdr-runtime-test",
                "--seconds", "120",
                "--report", Path.Combine(directory.Path, "runtime.json"),
            ],
            output,
            error,
            environmentVariableReader: _ => null);

        Assert.AreEqual(3, exitCode);
        StringAssert.Contains(error.ToString(), "authorized Herdr environment", StringComparison.Ordinal);
    }

    [TestMethod]
    public async Task CompletionSignalRequiresCompleteRuntimeEvidenceOptions()
    {
        using var directory = new TemporaryDirectory();
        var output = new StringWriter();
        var error = new StringWriter();

        var exitCode = await HerdrOpsCoreStateServiceCommand.RunAsync(
            [
                "serve-herdr-state",
                "--completion-signal", Path.Combine(directory.Path, "complete.signal"),
            ],
            output,
            error,
            environmentVariableReader: _ => "1");

        Assert.AreEqual(64, exitCode);
        StringAssert.Contains(error.ToString(), "requires --report", StringComparison.Ordinal);
    }

    [TestMethod]
    public async Task CompletionSignalRejectsRelativePath()
    {
        using var directory = new TemporaryDirectory();
        var output = new StringWriter();
        var error = new StringWriter();

        var exitCode = await HerdrOpsCoreStateServiceCommand.RunAsync(
            CreateEvidenceArguments(directory, "relative.signal"),
            output,
            error,
            environmentVariableReader: _ => "1");

        Assert.AreEqual(64, exitCode);
        StringAssert.Contains(error.ToString(), "absolute path", StringComparison.Ordinal);
    }

    [TestMethod]
    public async Task CompletionSignalRejectsBlankPath()
    {
        using var directory = new TemporaryDirectory();
        var output = new StringWriter();
        var error = new StringWriter();

        var exitCode = await HerdrOpsCoreStateServiceCommand.RunAsync(
            CreateEvidenceArguments(directory, string.Empty),
            output,
            error,
            environmentVariableReader: _ => "1");

        Assert.AreEqual(64, exitCode);
        StringAssert.Contains(error.ToString(), "cannot be blank", StringComparison.Ordinal);
    }

    [TestMethod]
    public async Task CompletionSignalRejectsExistingAndAliasedPath()
    {
        using var directory = new TemporaryDirectory();
        var existingSignalPath = Path.Combine(directory.Path, "existing.signal");
        File.WriteAllText(existingSignalPath, "already here");
        var existingOutput = new StringWriter();
        var existingError = new StringWriter();

        var existingExitCode = await HerdrOpsCoreStateServiceCommand.RunAsync(
            CreateEvidenceArguments(directory, existingSignalPath),
            existingOutput,
            existingError,
            environmentVariableReader: _ => "1");

        Assert.AreEqual(64, existingExitCode);
        StringAssert.Contains(existingError.ToString(), "does not already exist", StringComparison.Ordinal);

        var reportPath = Path.Combine(directory.Path, "aliased.json");
        var aliasedOutput = new StringWriter();
        var aliasedError = new StringWriter();
        var aliasedExitCode = await HerdrOpsCoreStateServiceCommand.RunAsync(
            CreateEvidenceArguments(directory, reportPath, reportPath),
            aliasedOutput,
            aliasedError,
            environmentVariableReader: _ => "1");

        Assert.AreEqual(64, aliasedExitCode);
        StringAssert.Contains(aliasedError.ToString(), "must not alias", StringComparison.Ordinal);
    }

    [TestMethod]
    public async Task CompletionSignalCancelsBlockingEvidenceServiceAndWritesReport()
    {
        using var directory = new TemporaryDirectory();
        var reportPath = Path.Combine(directory.Path, "runtime.json");
        var signalPath = Path.Combine(directory.Path, "complete.signal");
        var fixture = new BlockingRuntimeFixture();
        var output = new StringWriter();
        var error = new StringWriter();
        var stopwatch = Stopwatch.StartNew();

        var serviceTask = HerdrOpsCoreStateServiceCommand.RunAsync(
            CreateEvidenceArguments(directory, signalPath, reportPath),
            output,
            error,
            environmentVariableReader: _ => "1",
            admittedMonitorFactory: fixture.Create);

        await fixture.AuthoritativeSnapshotReady.Task.WaitAsync(TimeSpan.FromSeconds(5));
        File.WriteAllBytes(signalPath, []);
        var exitCode = await serviceTask.WaitAsync(TimeSpan.FromSeconds(5));
        stopwatch.Stop();

        Assert.AreEqual(0, exitCode);
        Assert.IsTrue(stopwatch.Elapsed < TimeSpan.FromSeconds(5));
        Assert.IsTrue(File.Exists(reportPath));
        Assert.IsTrue(fixture.SubscriptionDisposed);

        using var report = JsonDocument.Parse(File.ReadAllText(reportPath));
        var root = report.RootElement;
        Assert.IsTrue(root.GetProperty("CompletionSignalObserved").GetBoolean());
        Assert.AreEqual(
            "UniquePrevalidatedAbsolutePathContainingAnEmptyFileAfterAppExit",
            root.GetProperty("CompletionSignalSemantics").GetString());
        Assert.IsTrue(root.GetProperty("RuntimeObserved").GetBoolean());
        Assert.IsFalse(root.GetProperty("EventObserved").GetBoolean());
        Assert.IsFalse(root.GetProperty("ReconnectObserved").GetBoolean());
    }

    [TestMethod]
    public async Task CompletionSignalRejectsNonEmptyMarkerAndStopsService()
    {
        using var directory = new TemporaryDirectory();
        var reportPath = Path.Combine(directory.Path, "runtime.json");
        var signalPath = Path.Combine(directory.Path, "complete.signal");
        var fixture = new BlockingRuntimeFixture();
        var output = new StringWriter();
        var error = new StringWriter();

        var serviceTask = HerdrOpsCoreStateServiceCommand.RunAsync(
            CreateEvidenceArguments(directory, signalPath, reportPath),
            output,
            error,
            environmentVariableReader: _ => "1",
            admittedMonitorFactory: fixture.Create);

        await fixture.AuthoritativeSnapshotReady.Task.WaitAsync(TimeSpan.FromSeconds(5));
        File.WriteAllText(signalPath, "not-an-empty-marker");
        var exitCode = await serviceTask.WaitAsync(TimeSpan.FromSeconds(5));

        Assert.AreEqual(2, exitCode);
        Assert.IsFalse(File.Exists(reportPath));
        Assert.IsTrue(fixture.SubscriptionDisposed);
        StringAssert.Contains(error.ToString(), "empty marker file", StringComparison.Ordinal);
    }

    private static string[] CreateEvidenceArguments(
        TemporaryDirectory directory,
        string completionSignalPath,
        string? reportPath = null)
    {
        reportPath ??= Path.Combine(directory.Path, "runtime.json");
        return
        [
            "serve-herdr-state",
            "--database", Path.Combine(directory.Path, "runtime.db"),
            "--herdr", Path.Combine(directory.Path, "herdr.exe"),
            "--socket-path", "blocking-runtime-test",
            "--seconds", "10",
            "--report", reportPath,
            "--completion-signal", completionSignalPath,
        ];
    }

    private sealed class BlockingApiClient : IHerdrApiClient
    {
        public HerdrServerProcessIdentity? LastVerifiedServerIdentity => null;

        public async Task<HerdrSessionSnapshot> GetSnapshotAsync(
            HerdrPipeEndpoint endpoint,
            CancellationToken cancellationToken)
        {
            await Task.Delay(Timeout.InfiniteTimeSpan, cancellationToken);
            throw new InvalidOperationException("The cancellation-only test unexpectedly resumed.");
        }

        public Task<IHerdrEventSubscription> SubscribeAsync(
            HerdrPipeEndpoint endpoint,
            IReadOnlyCollection<string> paneIds,
            CancellationToken cancellationToken) =>
            throw new InvalidOperationException("The cancellation-only test must not subscribe.");
    }

    private sealed class BlockingRuntimeFixture
    {
        private readonly HerdrServerProcessIdentity _identity = new(
            1234,
            DateTimeOffset.UtcNow,
            "C:\\Synthetic\\herdr.exe",
            new string('A', 64));

        public TaskCompletionSource<bool> AuthoritativeSnapshotReady { get; } = new(
            TaskCreationOptions.RunContinuationsAsynchronously);

        public bool SubscriptionDisposed { get; private set; }

        public HerdrAdmittedRuntimeMonitor Create(
            string? _,
            string? __,
            HerdrSessionState? initialState)
        {
            var apiClient = new EvidenceBlockingApiClient(
                CreateEmptySnapshot(),
                _identity,
                AuthoritativeSnapshotReady);
            var monitor = new HerdrRuntimeMonitor(
                apiClient,
                HerdrPipeEndpoint.FromSocketPath("blocking-runtime-test"),
                reconnectDelay: new HerdrExponentialReconnectDelay(),
                initialState: initialState,
                options: HerdrRuntimeMonitorOptions.EventOnlyForTests);
            apiClient.SubscriptionCreated = subscription =>
            {
                subscription.Disposed += () => SubscriptionDisposed = true;
            };

            var admission = new HerdrRuntimeAdmission(
                _identity.ExecutablePath,
                "synthetic-runtime",
                _identity.ExecutableSha256,
                "synthetic-protocol",
                1,
                "synthetic-schema",
                1,
                new string('B', 64),
                19,
                HerdrPipeEndpoint.FromSocketPath("blocking-runtime-test"));
            var paneClient = new HerdrNamedPipeApiClient(
                serverIdentityVerifier: AllowUnboundHerdrServerIdentityForSyntheticTests.Instance);
            return new HerdrAdmittedRuntimeMonitor(monitor, admission, paneClient);
        }

        private static HerdrSessionSnapshot CreateEmptySnapshot() => new(
            "synthetic-runtime",
            19,
            [],
            [],
            [],
            [],
            null,
            null,
            null);
    }

    private sealed class EvidenceBlockingApiClient : IHerdrApiClient
    {
        private readonly HerdrSessionSnapshot _snapshot;
        private readonly HerdrServerProcessIdentity _identity;
        private readonly TaskCompletionSource<bool> _authoritativeSnapshotReady;
        private int _snapshotCount;

        public EvidenceBlockingApiClient(
            HerdrSessionSnapshot snapshot,
            HerdrServerProcessIdentity identity,
            TaskCompletionSource<bool> authoritativeSnapshotReady)
        {
            _snapshot = snapshot;
            _identity = identity;
            _authoritativeSnapshotReady = authoritativeSnapshotReady;
        }

        public Action<CancellationBlockingSubscription>? SubscriptionCreated { get; set; }

        public HerdrServerProcessIdentity? LastVerifiedServerIdentity => _identity;

        public Task<HerdrSessionSnapshot> GetSnapshotAsync(
            HerdrPipeEndpoint endpoint,
            CancellationToken cancellationToken)
        {
            cancellationToken.ThrowIfCancellationRequested();
            if (Interlocked.Increment(ref _snapshotCount) == 2)
            {
                _authoritativeSnapshotReady.TrySetResult(true);
            }

            return Task.FromResult(_snapshot);
        }

        public Task<IHerdrEventSubscription> SubscribeAsync(
            HerdrPipeEndpoint endpoint,
            IReadOnlyCollection<string> paneIds,
            CancellationToken cancellationToken)
        {
            cancellationToken.ThrowIfCancellationRequested();
            var subscription = new CancellationBlockingSubscription();
            SubscriptionCreated?.Invoke(subscription);
            return Task.FromResult<IHerdrEventSubscription>(subscription);
        }
    }

    private sealed class CancellationBlockingSubscription : IHerdrEventSubscription
    {
        public event Action? Disposed;

        public async ValueTask<HerdrStateEvent> ReadNextAsync(CancellationToken cancellationToken)
        {
            await Task.Delay(Timeout.InfiniteTimeSpan, cancellationToken);
            throw new InvalidOperationException("The blocking evidence subscription unexpectedly resumed.");
        }

        public ValueTask DisposeAsync()
        {
            Disposed?.Invoke();
            return ValueTask.CompletedTask;
        }
    }
}
