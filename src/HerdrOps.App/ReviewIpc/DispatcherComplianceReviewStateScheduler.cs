using System.Windows.Threading;

namespace HerdrOps.App.ReviewIpc;

public sealed class DispatcherComplianceReviewStateScheduler(Dispatcher dispatcher)
    : IComplianceReviewStateScheduler
{
    private readonly Dispatcher _dispatcher = dispatcher ??
        throw new ArgumentNullException(nameof(dispatcher));

    public async ValueTask InvokeAsync(
        Action action,
        CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(action);
        if (_dispatcher.CheckAccess())
        {
            cancellationToken.ThrowIfCancellationRequested();
            action();
            return;
        }

        await _dispatcher
            .InvokeAsync(action, DispatcherPriority.DataBind, cancellationToken)
            .Task
            .ConfigureAwait(false);
    }
}
