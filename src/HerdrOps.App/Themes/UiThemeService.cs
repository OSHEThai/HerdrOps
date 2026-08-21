using System;
using System.ComponentModel;
using System.Runtime.CompilerServices;
using HerdrOps.Domain.Settings;

namespace HerdrOps.App.Themes;

public sealed class UiThemeService : INotifyPropertyChanged
{
    public static UiThemeService Shared { get; } = new();

    private AppSettingsTheme _currentTheme = AppSettingsTheme.System;

    public AppSettingsTheme CurrentTheme => _currentTheme;

    public event PropertyChangedEventHandler? PropertyChanged;

    public void SetTheme(AppSettingsTheme theme)
    {
        if (_currentTheme == theme)
        {
            return;
        }

        _currentTheme = theme;
        OnPropertyChanged(nameof(CurrentTheme));
        
        // In the future, this will swap ResourceDictionaries for light/dark mode.
    }

    private void OnPropertyChanged([CallerMemberName] string? propertyName = null)
    {
        PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(propertyName));
    }
}
