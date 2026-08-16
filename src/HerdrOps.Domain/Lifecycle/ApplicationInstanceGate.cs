namespace HerdrOps.Domain.Lifecycle;

/// <summary>
/// Per-user, process-wide single-instance boundary. The implementation is
/// injected so lifecycle tests can prove second-launch and cleanup behavior
/// without creating an operating-system object.
/// </summary>
public interface IApplicationInstanceGate : IDisposable
{
    bool TryAcquire();
}
