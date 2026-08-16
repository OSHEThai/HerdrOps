using System.ComponentModel;
using System.Runtime.CompilerServices;
using System.Windows;
using System.Windows.Controls;
using HerdrOps.App.Localization;
using HerdrOps.App.Views;

namespace HerdrOps.App.Widgets;

/// <summary>
/// Opens all approved widget variants and presents a deterministic visual comparison board.
/// </summary>
public partial class WidgetGalleryView : UserControl, INotifyPropertyChanged
{
    private const double AdaptiveWidthBreakpoint = 1536;
    private const double AdaptiveHeightBreakpoint = 900;
    private IWidgetWindowLauncher? _launcher;
    private IWidgetState? _state;
    private IReadOnlyList<WidgetGalleryItem> _adaptiveItems;
    private readonly bool _usesDefaultLauncher;
    private bool _resourcesReleased;

    public WidgetGalleryView()
        : this(SyntheticWidgetState.Create(), launcher: null)
    {
    }

    public WidgetGalleryView(
        IWidgetState state,
        IWidgetWindowLauncher? launcher)
    {
        ArgumentNullException.ThrowIfNull(state);
        _state = state;
        _usesDefaultLauncher = launcher is null;
        _launcher = launcher ?? new WidgetWindowLauncher(state);
        _adaptiveItems = WidgetCatalog.CreateAdaptiveGalleryItems();

        InitializeComponent();
        DashboardPreviewHost.Content = ShellView.CreateSyntheticPreview();
        foreach (var preview in GetPreviews())
        {
            preview.SetState(state);
        }

        WeakEventManager<UiLanguageService, EventArgs>.AddHandler(
            UiLanguageService.Shared,
            nameof(UiLanguageService.LanguageChanged),
            OnLanguageChanged);
        Unloaded += OnUnloaded;
    }

    public event PropertyChangedEventHandler? PropertyChanged;

    public bool ResourcesReleased => _resourcesReleased;

    public IReadOnlyList<WidgetVariantDescriptor> Variants => WidgetCatalog.All;

    public IReadOnlyList<WidgetGalleryItem> AdaptiveItems
    {
        get => _adaptiveItems;
        private set
        {
            _adaptiveItems = value;
            OnPropertyChanged();
        }
    }

    public IWidgetState SharedState
    {
        get => _state ?? throw new InvalidOperationException(
            "The widget gallery resources have already been released.");
        private set
        {
            _state = value;
            OnPropertyChanged();
        }
    }

    public void OpenVariant(WidgetVariant variant)
    {
        if (!_resourcesReleased)
        {
            _launcher?.Open(variant);
        }
    }

    private IEnumerable<WidgetSurface> GetPreviews()
    {
        yield return CompactPreview;
        yield return NormalPreview;
        yield return ExpandedPreview;
        yield return MiniPreview;
        yield return VerticalPreview;
        yield return NotificationPreview;
        yield return AgentDetailPreview;
    }

    private void OnOpenWidgetClick(object sender, RoutedEventArgs e)
    {
        if (sender is not Button { Tag: var tag })
        {
            return;
        }

        if (string.Equals(tag?.ToString(), "Dashboard", StringComparison.Ordinal))
        {
            ActivateDashboard();
            return;
        }

        if (Enum.TryParse<WidgetVariant>(tag?.ToString(), ignoreCase: false, out var variant))
        {
            OpenVariant(variant);
        }
    }

    private void OnOpenDashboardClick(object sender, RoutedEventArgs e)
    {
        ActivateDashboard();
    }

    private static void ActivateDashboard()
    {
        if (Application.Current.MainWindow is { } mainWindow)
        {
            mainWindow.Show();
            mainWindow.Activate();
        }
    }

    private void OnGallerySizeChanged(object sender, SizeChangedEventArgs e)
    {
        var useAdaptiveLayout =
            e.NewSize.Width < AdaptiveWidthBreakpoint ||
            e.NewSize.Height < AdaptiveHeightBreakpoint;
        FullGallery.Visibility = useAdaptiveLayout ? Visibility.Collapsed : Visibility.Visible;
        AdaptiveGallery.Visibility = useAdaptiveLayout ? Visibility.Visible : Visibility.Collapsed;
    }

    private void OnLanguageChanged(object? sender, EventArgs e)
    {
        if (!Dispatcher.CheckAccess())
        {
            if (!Dispatcher.HasShutdownStarted && !Dispatcher.HasShutdownFinished)
            {
                _ = Dispatcher.InvokeAsync(ApplyLanguageChange);
            }

            return;
        }

        ApplyLanguageChange();
    }

    private void ApplyLanguageChange()
    {
        if (SharedState.EvidenceClass == HerdrOps.Contracts.EvidenceClass.Synthetic)
        {
            SharedState = SyntheticWidgetState.Create();
            if (_usesDefaultLauncher)
            {
                _launcher = new WidgetWindowLauncher(SharedState);
            }

            foreach (var preview in GetPreviews())
            {
                preview.SetState(SharedState);
            }
        }

        AdaptiveItems = WidgetCatalog.CreateAdaptiveGalleryItems();
    }

    private void OnUnloaded(object sender, RoutedEventArgs e)
    {
        ReleaseResources();
    }

    public void ReleaseResources()
    {
        if (_resourcesReleased)
        {
            return;
        }

        _resourcesReleased = true;
        WeakEventManager<UiLanguageService, EventArgs>.RemoveHandler(
            UiLanguageService.Shared,
            nameof(UiLanguageService.LanguageChanged),
            OnLanguageChanged);
        Unloaded -= OnUnloaded;

        foreach (var preview in GetPreviews())
        {
            preview.ReleaseResources();
        }

        if (DashboardPreviewHost.Content is ShellView shell)
        {
            shell.ReleaseResources();
        }

        DashboardPreviewHost.Content = null;
        AdaptiveGalleryItems.ItemsSource = null;
        DataContext = null;
        _adaptiveItems = Array.Empty<WidgetGalleryItem>();
        _launcher = null;
        _state = null;
    }

    private void OnPropertyChanged([CallerMemberName] string? propertyName = null) =>
        PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(propertyName));
}
