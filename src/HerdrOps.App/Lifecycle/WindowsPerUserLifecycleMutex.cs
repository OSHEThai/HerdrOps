using System.Security.Principal;
using HerdrOps.Domain.Lifecycle;

namespace HerdrOps.App.Lifecycle;

/// <summary>
/// Windows production implementation of the per-user lifecycle mutexes. The
/// SID is part of the object name so users cannot block one another; the
/// Global namespace keeps the boundary process-wide across interactive
/// sessions for that same user.
/// </summary>
public sealed class WindowsPerUserApplicationInstanceGate : IApplicationInstanceGate
{
    private readonly Mutex _mutex;
    private bool _ownsMutex;
    private bool _disposed;

    public WindowsPerUserApplicationInstanceGate(string productName = "HerdrOps")
    {
        _mutex = new Mutex(initiallyOwned: false, CreateName(productName, "SingleInstance"));
    }

    public bool TryAcquire()
    {
        ThrowIfDisposed();
        if (_ownsMutex)
        {
            return true;
        }

        try
        {
            _ownsMutex = _mutex.WaitOne(millisecondsTimeout: 0);
            return _ownsMutex;
        }
        catch (AbandonedMutexException)
        {
            _ownsMutex = true;
            return true;
        }
    }

    public void Dispose()
    {
        if (_disposed)
        {
            return;
        }

        Exception? releaseFailure = null;
        try
        {
            if (_ownsMutex)
            {
                _mutex.ReleaseMutex();
                _ownsMutex = false;
            }
        }
        catch (Exception exception)
        {
            releaseFailure = exception;
        }
        finally
        {
            _mutex.Dispose();
            _disposed = true;
        }

        if (releaseFailure is not null)
        {
            throw releaseFailure;
        }
    }

    private static string CreateName(string productName, string suffix)
    {
        if (!OperatingSystem.IsWindows())
        {
            throw new PlatformNotSupportedException(
                "The Windows per-user lifecycle mutex requires Windows.");
        }

        if (string.IsNullOrWhiteSpace(productName)
            || productName.Any(character => char.IsControl(character) || character is '\\' or '/'))
        {
            throw new ArgumentException("The product name is not a valid mutex component.", nameof(productName));
        }

        var userSid = WindowsIdentity.GetCurrent().User?.Value;
        if (string.IsNullOrWhiteSpace(userSid))
        {
            throw new InvalidOperationException("The current Windows user SID is unavailable.");
        }

        return $"Global\\{productName}.{userSid}.{suffix}";
    }

    private void ThrowIfDisposed() => ObjectDisposedException.ThrowIf(_disposed, this);
}

/// <summary>
/// Cross-process coordinator for cooperating current-user Run-key writers.
/// This intentionally does not claim to control foreign writers that ignore
/// the named mutex; StartAtLogonService still performs a post-write recheck.
/// </summary>
public sealed class WindowsPerUserStartupRegistrationCoordinator : IStartupRegistrationCoordinator
{
    private readonly string _mutexName;

    public WindowsPerUserStartupRegistrationCoordinator(string productName = "HerdrOps")
    {
        _mutexName = CreateName(productName, "StartupRegistration");
    }

    public IDisposable Enter()
    {
        var mutex = new Mutex(initiallyOwned: false, _mutexName);
        try
        {
            var ownsMutex = false;
            try
            {
                mutex.WaitOne();
                ownsMutex = true;
            }
            catch (AbandonedMutexException)
            {
                ownsMutex = true;
            }

            return new MutexLease(mutex, ownsMutex);
        }
        catch
        {
            mutex.Dispose();
            throw;
        }
    }

    private static string CreateName(string productName, string suffix)
    {
        if (!OperatingSystem.IsWindows())
        {
            throw new PlatformNotSupportedException(
                "The Windows per-user startup coordinator requires Windows.");
        }

        if (string.IsNullOrWhiteSpace(productName)
            || productName.Any(character => char.IsControl(character) || character is '\\' or '/'))
        {
            throw new ArgumentException("The product name is not a valid mutex component.", nameof(productName));
        }

        var userSid = WindowsIdentity.GetCurrent().User?.Value;
        if (string.IsNullOrWhiteSpace(userSid))
        {
            throw new InvalidOperationException("The current Windows user SID is unavailable.");
        }

        return $"Global\\{productName}.{userSid}.{suffix}";
    }

    private sealed class MutexLease(Mutex mutex, bool ownsMutex) : IDisposable
    {
        private bool _disposed;

        public void Dispose()
        {
            if (_disposed)
            {
                return;
            }

            _disposed = true;
            Exception? releaseFailure = null;
            try
            {
                if (ownsMutex)
                {
                    mutex.ReleaseMutex();
                }
            }
            catch (Exception exception)
            {
                releaseFailure = exception;
            }
            finally
            {
                mutex.Dispose();
            }

            if (releaseFailure is not null)
            {
                throw releaseFailure;
            }
        }
    }
}
