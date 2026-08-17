using System.IO;
using Microsoft.Win32;
using HerdrOps.Domain.Lifecycle;

namespace HerdrOps.App.Lifecycle;

/// <summary>
/// Windows-only current-user Run-key backend. It never opens HKLM and therefore
/// does not require administrator elevation. It is not used by hermetic tests.
/// </summary>
public sealed class WindowsCurrentUserRunBackend : ICurrentUserStartupBackend
{
    public string? Read(string valueName)
    {
        ValidateValueName(valueName);
        EnsureWindows();
        using var runKey = Registry.CurrentUser.OpenSubKey(
            StartupRegistrationContract.CurrentUserRunKeyPath,
            writable: false);
        if (runKey is null)
        {
            return null;
        }

        var value = runKey.GetValue(
            valueName,
            defaultValue: null,
            options: RegistryValueOptions.DoNotExpandEnvironmentNames);
        return value switch
        {
            null => null,
            string command => command,
            _ => throw new StartupRegistrationException(
                $"The current-user startup value '{valueName}' is not a string.",
                new InvalidDataException("The startup Registry value has an unsupported type.")),
        };
    }

    public void Write(string valueName, string command)
    {
        ValidateValueName(valueName);
        if (string.IsNullOrWhiteSpace(command))
        {
            throw new StartupRegistrationException("The startup command is required.");
        }

        EnsureWindows();
        using var runKey = Registry.CurrentUser.CreateSubKey(
            StartupRegistrationContract.CurrentUserRunKeyPath,
            writable: true);
        if (runKey is null)
        {
            throw new StartupRegistrationException("The current-user startup key could not be opened.");
        }

        runKey.SetValue(valueName, command, RegistryValueKind.String);
    }

    public void Delete(string valueName)
    {
        ValidateValueName(valueName);
        EnsureWindows();
        using var runKey = Registry.CurrentUser.OpenSubKey(
            StartupRegistrationContract.CurrentUserRunKeyPath,
            writable: true);
        runKey?.DeleteValue(valueName, throwOnMissingValue: false);
    }

    private static void ValidateValueName(string valueName)
    {
        if (string.IsNullOrWhiteSpace(valueName) ||
            valueName.IndexOf('\\') >= 0 ||
            valueName.IndexOf('/') >= 0)
        {
            throw new StartupRegistrationException("The startup Registry value name is malformed.");
        }
    }

    private static void EnsureWindows()
    {
        if (!OperatingSystem.IsWindows())
        {
            throw new PlatformNotSupportedException("The current-user Run backend requires Windows.");
        }
    }
}
