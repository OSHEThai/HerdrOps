using System;
using System.ComponentModel;
using System.Linq;
using System.Runtime.CompilerServices;
using System.Windows;
using Microsoft.Win32;
using HerdrOps.Domain.Settings;

namespace HerdrOps.App.Themes;

public sealed class UiThemeService : INotifyPropertyChanged, IDisposable
{
    public static UiThemeService Shared { get; } = new();

    private AppSettingsTheme _currentTheme = AppSettingsTheme.System;
    private bool _hasAppliedTheme;
    private readonly Func<bool> _isWindowsDarkTheme;

    public AppSettingsTheme CurrentTheme => _currentTheme;

    public event PropertyChangedEventHandler? PropertyChanged;

    public UiThemeService(Func<bool>? isWindowsDarkTheme = null)
    {
        _isWindowsDarkTheme = isWindowsDarkTheme ?? DefaultIsWindowsDarkTheme;
        SystemEvents.UserPreferenceChanged += OnUserPreferenceChanged;
    }

    public void SetTheme(AppSettingsTheme theme)
    {
        if (_currentTheme == theme && _hasAppliedTheme)
        {
            return;
        }

        _currentTheme = theme;
        _hasAppliedTheme = true;
        OnPropertyChanged(nameof(CurrentTheme));
        ApplyTheme();
    }

    public void ApplyTheme()
    {
        if (Application.Current == null)
            return; // For tests

        var isDark = _currentTheme switch
        {
            AppSettingsTheme.Dark => true,
            AppSettingsTheme.Light => false,
            AppSettingsTheme.System => _isWindowsDarkTheme(),
            _ => true,
        };

        var dictionaryName = isDark ? "Tokens.Semantic.Dark.xaml" : "Tokens.Semantic.Light.xaml";
        var uri = new Uri($"pack://application:,,,/HerdrOps.App;component/Themes/{dictionaryName}", UriKind.Absolute);

        var existingDictionary = Application.Current.Resources.MergedDictionaries
            .FirstOrDefault(d => d.Source != null && d.Source.OriginalString.Contains("Tokens.Semantic"));

        if (existingDictionary != null && existingDictionary.Source == uri)
            return; // Already applied

        var newDictionary = new ResourceDictionary { Source = uri };

        if (existingDictionary != null)
        {
            var index = Application.Current.Resources.MergedDictionaries.IndexOf(existingDictionary);
            Application.Current.Resources.MergedDictionaries.Remove(existingDictionary);
            Application.Current.Resources.MergedDictionaries.Insert(index, newDictionary);
        }
        else
        {
            Application.Current.Resources.MergedDictionaries.Add(newDictionary);
        }
    }

    internal void OnUserPreferenceChanged(object sender, UserPreferenceChangedEventArgs e)
    {
        if (e.Category == UserPreferenceCategory.General && _currentTheme == AppSettingsTheme.System)
        {
            // The user changed a general setting (like light/dark mode) in Windows
            Application.Current?.Dispatcher.Invoke(ApplyTheme);
        }
    }

    private static bool DefaultIsWindowsDarkTheme()
    {
        try
        {
            using var key = Registry.CurrentUser.OpenSubKey(@"Software\Microsoft\Windows\CurrentVersion\Themes\Personalize");
            var appsUseLightTheme = key?.GetValue("AppsUseLightTheme");
            if (appsUseLightTheme is int value)
            {
                return value == 0;
            }
        }
        catch
        {
            // Ignored
        }

        return true; // Default to dark
    }

    private void OnPropertyChanged([CallerMemberName] string? propertyName = null)
    {
        PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(propertyName));
    }

    public void Dispose()
    {
        SystemEvents.UserPreferenceChanged -= OnUserPreferenceChanged;
    }
}
