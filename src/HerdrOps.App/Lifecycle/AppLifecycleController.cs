using HerdrOps.Domain.Lifecycle;
using HerdrOps.Domain.Settings;

namespace HerdrOps.App.Lifecycle;

/// <summary>
/// Coordinates the reversible, user-owned settings and current-user startup
/// registration without knowing whether either dependency is backed by an OS
/// resource. The composition root supplies the settings applier and both
/// dependencies are injectable for hermetic tests.
/// </summary>
public sealed class AppLifecycleController
{
    private readonly IAppSettingsStore _settingsStore;
    private readonly StartAtLogonService _startAtLogon;
    private readonly Action<AppSettings> _settingsApplier;
    private AppSettingsSnapshot? _snapshot;
    private StartupRegistrationStatus? _startAtLogonStatus;

    public AppLifecycleController(
        IAppSettingsStore settingsStore,
        StartAtLogonService startAtLogon,
        Action<AppSettings> settingsApplier)
    {
        _settingsStore = settingsStore ?? throw new ArgumentNullException(nameof(settingsStore));
        _startAtLogon = startAtLogon ?? throw new ArgumentNullException(nameof(startAtLogon));
        _settingsApplier = settingsApplier ?? throw new ArgumentNullException(nameof(settingsApplier));
    }

    public bool IsInitialized => _snapshot is not null;

    public AppSettings Settings => RequireSnapshot().Settings;

    public AppSettingsSnapshot Snapshot => RequireSnapshot();

    public StartupRegistrationStatus StartAtLogonStatus =>
        _startAtLogonStatus ?? throw new InvalidOperationException(
            "The application lifecycle has not been initialized.");

    public async Task InitializeAsync(CancellationToken cancellationToken = default)
    {
        if (IsInitialized)
        {
            return;
        }

        var snapshot = await _settingsStore.LoadAsync(cancellationToken);
        snapshot ??= await _settingsStore.SaveAsync(AppSettings.Defaults, cancellationToken);
        _settingsApplier(snapshot.Settings);
        _startAtLogonStatus = _startAtLogon.GetStatus();
        _snapshot = snapshot;
    }

    public AppSettingsSnapshot SelectLanguage(AppSettingsLanguage language) =>
        UpdateSettings(settings => settings with { Language = language });

    public AppSettingsSnapshot SelectTheme(AppSettingsTheme theme) =>
        UpdateSettings(settings => settings with { Theme = theme });

    public AppSettingsSnapshot SelectWidget(AppSettingsWidgetVariant widgetVariant) =>
        UpdateSettings(settings => settings with { WidgetVariant = widgetVariant });

    public AppSettingsSnapshot SetWidgetEnabled(bool enabled) =>
        UpdateSettings(settings => settings with { WidgetEnabled = enabled });

    public AppSettingsSnapshot RestoreSettings(AppSettingsSnapshot snapshot)
    {
        EnsureInitialized();
        ArgumentNullException.ThrowIfNull(snapshot);
        var restored = _settingsStore.RestoreAsync(snapshot)
            .ConfigureAwait(false)
            .GetAwaiter()
            .GetResult();
        ApplySnapshot(restored);
        return restored;
    }

    public AppSettingsSnapshot ResetSettings()
    {
        EnsureInitialized();
        var reset = _settingsStore.ResetToDefaultsAsync()
            .ConfigureAwait(false)
            .GetAwaiter()
            .GetResult();
        ApplySnapshot(reset);
        return reset;
    }

    public void ToggleStartAtLogon()
    {
        EnsureInitialized();
        if (StartAtLogonStatus.IsConflicting)
        {
            // A foreign command owns the deterministic value name. Keep the
            // status visible and make a tray click a safe no-op.
            _startAtLogonStatus = _startAtLogon.GetStatus();
            return;
        }

        if (StartAtLogonStatus.State == StartupRegistrationState.Enabled)
        {
            _startAtLogonStatus = _startAtLogon.Disable();
        }
        else
        {
            _startAtLogonStatus = _startAtLogon.Enable();
        }
    }

    private AppSettingsSnapshot UpdateSettings(Func<AppSettings, AppSettings> update)
    {
        EnsureInitialized();
        ArgumentNullException.ThrowIfNull(update);
        var candidate = update(Settings) ?? throw new InvalidOperationException(
            "The settings update returned null.");
        var saved = _settingsStore.SaveAsync(candidate)
            .ConfigureAwait(false)
            .GetAwaiter()
            .GetResult();
        ApplySnapshot(saved);
        return saved;
    }

    private void ApplySnapshot(AppSettingsSnapshot snapshot)
    {
        ArgumentNullException.ThrowIfNull(snapshot);
        _settingsApplier(snapshot.Settings);
        _snapshot = snapshot;
    }

    private AppSettingsSnapshot RequireSnapshot() => _snapshot ?? throw new InvalidOperationException(
        "The application lifecycle has not been initialized.");

    private void EnsureInitialized()
    {
        _ = RequireSnapshot();
    }
}
