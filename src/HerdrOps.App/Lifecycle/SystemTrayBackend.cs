using System.IO;
using System.Windows;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using Drawing = System.Drawing;
using Forms = System.Windows.Forms;
using System.Runtime.InteropServices;
using HerdrOps.Domain.Lifecycle;

namespace HerdrOps.App.Lifecycle;

/// <summary>
/// Built-in Windows notification-area adapter. Tests use ITrayBackend fakes and
/// therefore never create this OS resource.
/// </summary>
public sealed class SystemTrayBackend : ITrayBackend
{
    private Forms.NotifyIcon? _notifyIcon;
    private Forms.ContextMenuStrip? _contextMenu;
    private Drawing.Icon? _icon;
    private Action<TrayCommand>? _commandHandler;
    private bool _disposed;

    public void Show(TrayMenuModel menu, Action<TrayCommand> commandHandler)
    {
        ThrowIfDisposed();
        ArgumentNullException.ThrowIfNull(menu);
        _commandHandler = commandHandler ?? throw new ArgumentNullException(nameof(commandHandler));

        _notifyIcon ??= CreateNotifyIcon();
        Update(menu);
        _notifyIcon.Visible = true;
    }

    public void Update(TrayMenuModel menu)
    {
        ThrowIfDisposed();
        ArgumentNullException.ThrowIfNull(menu);
        if (_notifyIcon is null)
        {
            throw new InvalidOperationException("The tray icon must be shown before it can be updated.");
        }

        var nextContextMenu = new Forms.ContextMenuStrip();
        foreach (var item in menu.Items)
        {
            var menuItem = new Forms.ToolStripMenuItem(item.Label)
            {
                Checked = item.IsChecked,
                Enabled = item.IsEnabled,
                CheckOnClick = false,
                Tag = item.Command,
            };
            menuItem.Click += OnMenuItemClick;
            nextContextMenu.Items.Add(menuItem);
        }

        var previousContextMenu = _contextMenu;
        _contextMenu = nextContextMenu;
        _notifyIcon.ContextMenuStrip = nextContextMenu;
        _notifyIcon.Text = menu.ToolTipText.Length <= 63
            ? menu.ToolTipText
            : menu.ToolTipText[..63];
        previousContextMenu?.Dispose();
    }

    public void Hide()
    {
        if (_notifyIcon is not null)
        {
            _notifyIcon.Visible = false;
        }
    }

    public void Dispose()
    {
        if (_disposed)
        {
            return;
        }

        var failures = new List<ShutdownCleanupFailure>();
        if (_notifyIcon is not null)
        {
            try
            {
                _notifyIcon.DoubleClick -= OnNotifyIconDoubleClick;
                _notifyIcon.Visible = false;
                _notifyIcon.ContextMenuStrip = null;
                _notifyIcon.Dispose();
                _notifyIcon = null;
            }
            catch (Exception exception)
            {
                failures.Add(new ShutdownCleanupFailure("tray-notify-icon", exception));
            }
        }

        if (_contextMenu is not null)
        {
            try
            {
                _contextMenu.Dispose();
                _contextMenu = null;
            }
            catch (Exception exception)
            {
                failures.Add(new ShutdownCleanupFailure("tray-context-menu", exception));
            }
        }

        if (_icon is not null)
        {
            try
            {
                _icon.Dispose();
                _icon = null;
            }
            catch (Exception exception)
            {
                failures.Add(new ShutdownCleanupFailure("tray-icon", exception));
            }
        }

        if (failures.Count > 0)
        {
            throw new ShutdownCleanupException(failures);
        }

        _commandHandler = null;
        _disposed = true;
    }

    private Forms.NotifyIcon CreateNotifyIcon()
    {
        _icon = CreateApprovedBrandIcon(
            TrayIconContract.PixelSizeForDpi(GetSystemDpiScale()));
        var notifyIcon = new Forms.NotifyIcon
        {
            Icon = _icon,
            Visible = false,
        };
        notifyIcon.DoubleClick += OnNotifyIconDoubleClick;
        return notifyIcon;
    }

    private static Drawing.Icon CreateApprovedBrandIcon(int pixelSize)
    {
        var source = new BitmapImage();
        source.BeginInit();
        source.CacheOption = BitmapCacheOption.OnLoad;
        source.UriSource = new Uri(
            "pack://application:,,,/HerdrOps.App;component/Assets/Brand/ApprovedOverviewReference.png",
            UriKind.Absolute);
        source.EndInit();

        var cropped = new CroppedBitmap(
            source,
            new Int32Rect(
                TrayIconContract.ReferenceCropLeft,
                TrayIconContract.ReferenceCropTop,
                TrayIconContract.ReferenceCropSize,
                TrayIconContract.ReferenceCropSize));
        var bgra = new FormatConvertedBitmap(cropped, PixelFormats.Bgra32, null, 0);
        var pixels = new byte[bgra.PixelWidth * bgra.PixelHeight * 4];
        bgra.CopyPixels(pixels, bgra.PixelWidth * 4, 0);
        var transparentPixels = TrayIconContract.ToTransparentPbgra32(
            pixels,
            bgra.PixelWidth,
            bgra.PixelHeight);
        var transparentSource = BitmapSource.Create(
            bgra.PixelWidth,
            bgra.PixelHeight,
            96,
            96,
            PixelFormats.Pbgra32,
            null,
            transparentPixels,
            bgra.PixelWidth * 4);
        transparentSource.Freeze();
        var scaledSource = pixelSize == TrayIconContract.ReferenceCropSize
            ? transparentSource
            : new TransformedBitmap(
                transparentSource,
                new ScaleTransform(
                    (double)pixelSize / TrayIconContract.ReferenceCropSize,
                    (double)pixelSize / TrayIconContract.ReferenceCropSize));
        scaledSource.Freeze();

        var encoder = new PngBitmapEncoder();
        encoder.Frames.Add(BitmapFrame.Create(scaledSource));
        using var stream = new MemoryStream();
        encoder.Save(stream);
        stream.Position = 0;
        using var bitmap = new Drawing.Bitmap(stream);

        var iconHandle = bitmap.GetHicon();
        try
        {
            using var icon = Drawing.Icon.FromHandle(iconHandle);
            return (Drawing.Icon)icon.Clone();
        }
        finally
        {
            _ = DestroyIcon(iconHandle);
        }
    }

    private static double GetSystemDpiScale()
    {
        var dpi = GetDpiForSystem();
        return dpi == 0 ? 1.0 : dpi / 96.0;
    }

    private void OnMenuItemClick(object? sender, EventArgs e)
    {
        if (sender is Forms.ToolStripMenuItem { Tag: TrayCommand command })
        {
            _commandHandler?.Invoke(command);
        }
    }

    private void OnNotifyIconDoubleClick(object? sender, EventArgs e) =>
        _commandHandler?.Invoke(TrayCommand.ShowDashboard);

    private void ThrowIfDisposed()
    {
        ObjectDisposedException.ThrowIf(_disposed, this);
    }

    [DllImport("user32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool DestroyIcon(IntPtr iconHandle);

    [DllImport("user32.dll")]
    private static extern uint GetDpiForSystem();
}
