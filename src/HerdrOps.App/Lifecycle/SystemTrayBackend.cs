using System.IO;
using System.Windows;
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

        _disposed = true;
        if (_notifyIcon is not null)
        {
            _notifyIcon.DoubleClick -= OnNotifyIconDoubleClick;
            _notifyIcon.Visible = false;
            _notifyIcon.ContextMenuStrip = null;
            _notifyIcon.Dispose();
        }

        _contextMenu?.Dispose();
        _icon?.Dispose();
        _notifyIcon = null;
        _contextMenu = null;
        _icon = null;
        _commandHandler = null;
    }

    private Forms.NotifyIcon CreateNotifyIcon()
    {
        _icon = CreateApprovedBrandIcon();
        var notifyIcon = new Forms.NotifyIcon
        {
            Icon = _icon,
            Visible = false,
        };
        notifyIcon.DoubleClick += OnNotifyIconDoubleClick;
        return notifyIcon;
    }

    private static Drawing.Icon CreateApprovedBrandIcon()
    {
        var source = new BitmapImage();
        source.BeginInit();
        source.CacheOption = BitmapCacheOption.OnLoad;
        source.UriSource = new Uri(
            "pack://application:,,,/HerdrOps.App;component/Assets/Brand/ApprovedOverviewReference.png",
            UriKind.Absolute);
        source.EndInit();
        var cropped = new CroppedBitmap(source, new Int32Rect(16, 8, 48, 48));
        var encoder = new PngBitmapEncoder();
        encoder.Frames.Add(BitmapFrame.Create(cropped));
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
}
