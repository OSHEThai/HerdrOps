using System.IO;
using HerdrOps.App.Localization;
using HerdrOps.Domain.Lifecycle;
using HerdrOps.Domain.Settings;
using HerdrOps.Infrastructure.Settings;

namespace HerdrOps.App.Lifecycle;

/// <summary>
/// Production-only composition for the current user's local settings and Run
/// registration. Tests must construct AppLifecycleController with injected
/// fakes instead of calling this factory.
/// </summary>
public static class AppLifecycleComposition
{
    public static AppLifecycleController CreateForCurrentUser(
        UiLanguageService? languageService = null,
        Action<AppSettings>? settingsApplier = null)
    {
        var localAppData = Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData);
        if (string.IsNullOrWhiteSpace(localAppData))
        {
            throw new InvalidOperationException(
                "The current user's local application-data directory is unavailable.");
        }

        var productRoot = Path.Combine(localAppData, "HerdrOps");
        var settingsPath = Path.Combine(productRoot, "settings", "appsettings.json");
        var store = new JsonAppSettingsStore(
            settingsPath,
            allowedRootDirectory: productRoot);

        var executablePath = Environment.ProcessPath;
        if (string.IsNullOrWhiteSpace(executablePath))
        {
            throw new InvalidOperationException("The HerdrOps executable path is unavailable.");
        }

        var startAtLogon = new StartAtLogonService(
            new WindowsCurrentUserRunBackend(),
            executablePath);
        var text = languageService ?? UiLanguageService.Shared;
        return new AppLifecycleController(
            store,
            startAtLogon,
            settingsApplier ?? (settings => text.SetLanguage(
                AppSettingsLifecycleMapping.ToUiLanguage(settings.Language))));
    }
}
