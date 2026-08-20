using HerdrOps.Infrastructure.ReviewIpc;

namespace HerdrOps.Core;

public sealed class HerdrOpsCoreStateService
{
    private readonly HerdrRuntimeMonitor _monitor;
    private readonly HerdrStateProjectionCoordinator _coordinator;
    private readonly HerdrOpsReviewCommandPipeServer? _reviewCommandServer;

    public HerdrOpsCoreStateService(
        HerdrRuntimeMonitor monitor,
        HerdrStateProjectionCoordinator coordinator,
        HerdrOpsReviewCommandPipeServer? reviewCommandServer = null)
    {
        _monitor = monitor ?? throw new ArgumentNullException(nameof(monitor));
        _coordinator = coordinator ?? throw new ArgumentNullException(nameof(coordinator));
        _reviewCommandServer = reviewCommandServer;
    }

    public async Task RunAsync(CancellationToken cancellationToken)
    {
        using var projection = new HerdrRuntimeStateProjection(_monitor, _coordinator);
        using var serviceCancellation = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
        var monitorTask = _monitor.RunAsync(serviceCancellation.Token);
        var pipeTask = _coordinator.PipeServer.RunAsync(serviceCancellation.Token);
        var reviewCommandTask = _reviewCommandServer?.RunAsync(serviceCancellation.Token) ??
            Task.Delay(Timeout.InfiniteTimeSpan, serviceCancellation.Token);
        try
        {
            var completed = await Task.WhenAny(
                    monitorTask,
                    pipeTask,
                    reviewCommandTask,
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
                    $"The Core state projection failed closed: {fault.Message}",
                    fault);
            }

            await completed.ConfigureAwait(false);
            throw new HerdrOpsCoreStateServiceException(
                completed == monitorTask
                    ? "The Herdr runtime monitor stopped unexpectedly."
                    : completed == pipeTask
                        ? "The Core-to-App state IPC server stopped unexpectedly."
                        : "The Core review-command IPC server stopped unexpectedly.");
        }
        finally
        {
            serviceCancellation.Cancel();
            await ObserveShutdownAsync(monitorTask).ConfigureAwait(false);
            await ObserveShutdownAsync(pipeTask).ConfigureAwait(false);
            await ObserveShutdownAsync(reviewCommandTask).ConfigureAwait(false);
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
