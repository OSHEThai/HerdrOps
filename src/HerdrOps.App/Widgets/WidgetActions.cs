using System.Windows;

namespace HerdrOps.App.Widgets;

public sealed class WidgetNotificationEventArgs(WidgetNotice notice) : EventArgs
{
    public WidgetNotice Notice { get; } = notice ?? throw new ArgumentNullException(nameof(notice));
}

public sealed class WidgetAgentEventArgs(WidgetAgent agent) : EventArgs
{
    public WidgetAgent Agent { get; } = agent ?? throw new ArgumentNullException(nameof(agent));
}

public interface IWidgetActionRouter
{
    bool OpenNotification(WidgetNotificationRoute route);

    bool OpenAgent(string terminalId);

    bool OpenNotificationHistory();
}

/// <summary>
/// Routes widget actions back to the single dashboard window and fails closed
/// when an exact event or Agent target is unavailable.
/// </summary>
public sealed class ApplicationWidgetActionRouter : IWidgetActionRouter
{
    public static ApplicationWidgetActionRouter Shared { get; } = new();

    private ApplicationWidgetActionRouter()
    {
    }

    public bool OpenNotification(WidgetNotificationRoute route)
    {
        ArgumentNullException.ThrowIfNull(route);
        var mainWindow = Application.Current?.MainWindow as MainWindow;
        if (mainWindow is null)
        {
            return false;
        }

        if (mainWindow.Shell.LiveDashboard.RealtimeActivity.TrySelectEvent(
                route.SourceEventId,
                route.CorrelationId,
                route.EventIdentitySha256))
        {
            if (!mainWindow.Shell.NavigateTo("realtime-activity"))
            {
                return false;
            }

            Activate(mainWindow);
            return true;
        }

        return route.AgentTerminalId is { Length: > 0 } terminalId &&
            OpenAgent(mainWindow, terminalId);
    }

    public bool OpenAgent(string terminalId)
    {
        if (string.IsNullOrWhiteSpace(terminalId) ||
            Application.Current?.MainWindow is not MainWindow mainWindow)
        {
            return false;
        }

        return OpenAgent(mainWindow, terminalId);
    }

    public bool OpenNotificationHistory()
    {
        if (Application.Current?.MainWindow is not MainWindow mainWindow ||
            !mainWindow.Shell.NavigateTo("realtime-activity"))
        {
            return false;
        }

        Activate(mainWindow);
        return true;
    }

    private static bool OpenAgent(MainWindow mainWindow, string terminalId)
    {
        if (!mainWindow.Shell.LiveDashboard.CurrentState.Agents.Any(agent => string.Equals(
                agent.TerminalId,
                terminalId,
                StringComparison.Ordinal)))
        {
            return false;
        }

        mainWindow.Shell.LiveDashboard.SelectAgent(terminalId);
        if (!string.Equals(
                mainWindow.Shell.LiveDashboard.SelectedTerminalId,
                terminalId,
                StringComparison.Ordinal) ||
            !mainWindow.Shell.NavigateTo("agent-detail"))
        {
            return false;
        }

        Activate(mainWindow);
        return true;
    }

    private static void Activate(MainWindow mainWindow)
    {
        mainWindow.Show();
        if (mainWindow.WindowState == WindowState.Minimized)
        {
            mainWindow.WindowState = WindowState.Normal;
        }

        mainWindow.Activate();
    }
}
