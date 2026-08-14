namespace HerdrOps.Core;

public sealed class HerdrOpsCoreStateService
{
    private readonly HerdrRuntimeMonitor _monitor;
    private readonly HerdrStateProjectionCoordinator _coordinator;

    public HerdrOpsCoreStateService(
        HerdrRuntimeMonitor monitor,
        HerdrStateProjectionCoordinator coordinator)
    {
        _monitor = monitor ?? throw new ArgumentNullException(nameof(monitor));
        _coordinator = coordinator ?? throw new ArgumentNullException(nameof(coordinator));
    }

    public async Task RunAsync(CancellationToken cancellationToken)
    {
        using var projection = new HerdrRuntimeStateProjection(_monitor, _coordinator);
        using var serviceCancellation = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
        var monitorTask = _monitor.RunAsync(serviceCancellation.Token);
        var pipeTask = _coordinator.PipeServer.RunAsync(serviceCancellation.Token);
        try
        {
            var completed = await Task.WhenAny(
                    monitorTask,
                    pipeTask,
                    projection.Faulted)
                .ConfigureAwait(false);
            if (cancellationToken.IsCancellationRequested)
            {
                return;
            }

            if (completed == projection.Faulted)
            {
                var fault = await projection.Faulted.ConfigureAwait(false);
                throw new HerdrOpsCoreStateServiceException(
                    "The Core state projection failed closed.",
                    fault);
            }

            await completed.ConfigureAwait(false);
            throw new HerdrOpsCoreStateServiceException(
                completed == monitorTask
                    ? "The Herdr runtime monitor stopped unexpectedly."
                    : "The Core-to-App state IPC server stopped unexpectedly.");
        }
        finally
        {
            serviceCancellation.Cancel();
            await ObserveShutdownAsync(monitorTask).ConfigureAwait(false);
            await ObserveShutdownAsync(pipeTask).ConfigureAwait(false);
        }
    }

    private static async Task ObserveShutdownAsync(Task task)
    {
        try
        {
            await task.ConfigureAwait(false);
        }
        catch (OperationCanceledException)
        {
        }
        catch
        {
            // The primary service failure is propagated by RunAsync.
        }
    }
}

public sealed class HerdrOpsCoreStateServiceException : IOException
{
    public HerdrOpsCoreStateServiceException(string message)
        : base(message)
    {
    }

    public HerdrOpsCoreStateServiceException(string message, Exception innerException)
        : base(message, innerException)
    {
    }
}
