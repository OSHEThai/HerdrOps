using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using HerdrOps.App.Shell;

namespace HerdrOps.App.Views;

/// <summary>
/// Shared application chrome and navigation for all canonical pages.
/// </summary>
public partial class ShellView : UserControl
{
    private const double CompactSidebarBreakpoint = 1200;
    private const double CompactVerticalBreakpoint = 800;
    private const double ProjectSelectorBreakpoint = 1080;
    private const double StatusLegendBreakpoint = 1280;

    public ShellView()
    {
        Navigation = new ShellNavigationController();
        InitializeComponent();
        DataContext = Navigation;
    }

    public ShellNavigationController Navigation { get; }

    public bool TryNavigateByKey(Key key, ModifierKeys modifiers)
    {
        var handled = Navigation.TryHandleKey(key, modifiers);
        if (handled)
        {
            NavigationList.ScrollIntoView(Navigation.SelectedDestination);
        }

        return handled;
    }

    private void OnPreviewKeyDown(object sender, KeyEventArgs e)
    {
        if (TryNavigateByKey(e.Key, Keyboard.Modifiers))
        {
            e.Handled = true;
        }
    }

    private void OnShellSizeChanged(object sender, SizeChangedEventArgs e)
    {
        StatusLegend.Visibility = e.NewSize.Width < StatusLegendBreakpoint
            ? Visibility.Collapsed
            : Visibility.Visible;
        ProjectSelector.Visibility = e.NewSize.Width < ProjectSelectorBreakpoint
            ? Visibility.Collapsed
            : Visibility.Visible;

        ApplySidebarMode(e.NewSize.Width < CompactSidebarBreakpoint);
        ApplyVerticalDensity(e.NewSize.Height < CompactVerticalBreakpoint);
    }

    private void OnToggleSidebarClick(object sender, RoutedEventArgs e)
    {
        ApplySidebarMode(!Navigation.IsCompactSidebar);
    }

    private void ApplySidebarMode(bool compact)
    {
        Navigation.IsCompactSidebar = compact;
        var width = compact ? 72 : 248;
        SidebarColumn.Width = new GridLength(width);
        BrandColumn.Width = new GridLength(width);
        WideBrandMark.Visibility = compact ? Visibility.Collapsed : Visibility.Visible;
        CompactBrandMark.Visibility = compact ? Visibility.Visible : Visibility.Collapsed;
        ProfileText.Visibility = compact ? Visibility.Collapsed : Visibility.Visible;
        ProfileChevron.Visibility = compact ? Visibility.Collapsed : Visibility.Visible;
    }

    private void ApplyVerticalDensity(bool compact)
    {
        ProfileRow.Height = compact ? new GridLength(0) : new GridLength(132);
        ProfilePanel.Visibility = compact ? Visibility.Collapsed : Visibility.Visible;
        NavigationList.Margin = compact ? new Thickness(0, 4, 0, 4) : new Thickness(0, 12, 0, 8);
        NavigationList.ItemContainerStyle = (Style)FindResource(
            compact
                ? "HerdrOps.Style.NavItem.CompactVertical"
                : "HerdrOps.Style.NavItem");
    }

    private void OnMinimizeClick(object sender, RoutedEventArgs e)
    {
        if (Window.GetWindow(this) is { } window)
        {
            window.WindowState = WindowState.Minimized;
        }
    }

    private void OnMaximizeClick(object sender, RoutedEventArgs e)
    {
        if (Window.GetWindow(this) is { } window)
        {
            window.WindowState = window.WindowState == WindowState.Maximized
                ? WindowState.Normal
                : WindowState.Maximized;
        }
    }

    private void OnCloseClick(object sender, RoutedEventArgs e)
    {
        Window.GetWindow(this)?.Close();
    }
}
