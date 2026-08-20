using HerdrOps.Domain.Compliance;
using HerdrOps.Infrastructure.Herdr;
using HerdrOps.Infrastructure.ReviewIpc;

namespace HerdrOps.Core;

public sealed class HerdrReviewClientProcessAuthorizer
{
    private readonly IHerdrPaneInspectionClient _paneInspectionClient;
    private readonly HerdrPipeEndpoint _endpoint;
    private readonly IWindowsProcessAncestryReader _processAncestry;

    public HerdrReviewClientProcessAuthorizer(
        IHerdrPaneInspectionClient paneInspectionClient,
        HerdrPipeEndpoint endpoint,
        IWindowsProcessAncestryReader? processAncestry = null)
    {
        _paneInspectionClient = paneInspectionClient ??
            throw new ArgumentNullException(nameof(paneInspectionClient));
        _endpoint = endpoint ?? throw new ArgumentNullException(nameof(endpoint));
        _processAncestry = processAncestry ?? new WindowsProcessAncestryReader();
    }

    public async ValueTask<bool> AuthorizeAsync(
        string reviewerActorId,
        uint clientProcessId,
        CancellationToken cancellationToken)
    {
        if (clientProcessId == 0)
        {
            return false;
        }

        try
        {
            reviewerActorId = ComplianceReviewWorkflowContract.NormalizeActorId(
                reviewerActorId);
            var processInfo = await _paneInspectionClient
                .GetPaneProcessInfoAsync(
                    _endpoint,
                    reviewerActorId,
                    cancellationToken)
                .ConfigureAwait(false);
            if (!string.Equals(
                    processInfo.PaneId,
                    reviewerActorId,
                    StringComparison.Ordinal))
            {
                return false;
            }

            cancellationToken.ThrowIfCancellationRequested();
            var admittedRoots = processInfo.ForegroundProcesses
                .Select(item => item.ProcessId)
                .Concat(processInfo.ShellProcessId is uint shellProcessId
                    ? [shellProcessId]
                    : Array.Empty<uint>())
                .Distinct()
                .ToArray();
            cancellationToken.ThrowIfCancellationRequested();
            var isAuthorized = _processAncestry.IsSameOrDescendant(
                clientProcessId,
                admittedRoots);
            cancellationToken.ThrowIfCancellationRequested();
            return isAuthorized;
        }
        catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested)
        {
            throw;
        }
        catch (Exception exception) when (
            exception is IOException or ArgumentException or UnauthorizedAccessException or InvalidOperationException)
        {
            return false;
        }
    }
}
