using HerdrOps.App;
using HerdrOps.App.Live;
using HerdrOps.App.Views;
using HerdrOps.App.Widgets;
using System.Windows.Threading;

namespace HerdrOps.RuntimeTests;

[TestClass]
[DoNotParallelize]
public sealed class RuntimeEvidenceResourceLifecycleTests
{
    [TestMethod]
    public void ClosingDashboardReleasesItsVisualTreeWithoutOwningLiveState()
    {
        WpfTestHost.Run(() =>
        {
            using var state = new LiveDashboardState();
            var window = new MainWindow(state);
            window.Show();
            window.UpdateLayout();
            var shell = window.Shell;

            Assert.AreSame(state, shell.LiveDashboard);
            Assert.IsFalse(window.DashboardResourcesReleased);

            window.Close();

            Assert.IsTrue(window.DashboardResourcesReleased);
            Assert.IsFalse(window.DashboardWorkingSetCompactionAttempted);
            Assert.AreEqual(0, shell.RetainedPageCount);
            Assert.IsNull(shell.ActivePageName);
            Assert.ThrowsExactly<InvalidOperationException>(() => _ = window.Shell);
            state.RefreshLanguage();
        }, TimeSpan.FromSeconds(30));
    }

    [TestMethod]
    public void ClosingDashboardCompactsWorkingSetWhenAWidgetRemainsVisible()
    {
        WpfTestHost.Run(() =>
        {
            using var state = new LiveDashboardState();
            var widget = new WidgetWindow(
                WidgetCatalog.Get(WidgetVariant.FloatingVertical),
                state.Widgets)
            {
                ShowActivated = false,
            };
            var window = new MainWindow(state);
            widget.Show();
            window.Show();
            window.UpdateLayout();

            window.Close();
            PumpDispatcherUntil(window.WaitForDashboardCleanupAsync(CancellationToken.None));

            Assert.IsTrue(window.DashboardResourcesReleased);
            Assert.IsTrue(window.DashboardWorkingSetCompactionAttempted);
            Assert.IsTrue(window.DashboardWorkingSetCompactionSucceeded);
            Assert.IsNull(window.DashboardWorkingSetCompactionNativeErrorCode);
            Assert.IsGreaterThan(0, window.DashboardWorkingSetBeforeMegabytes);
            Assert.IsGreaterThan(0, window.DashboardWorkingSetAfterMegabytes);

            widget.Close();
        }, TimeSpan.FromSeconds(30));
    }

    [TestMethod]
    public void ShellRetainsOnlyTheSelectedCanonicalPage()
    {
        WpfTestHost.Run(() =>
        {
            using var state = new LiveDashboardState();
            var window = new MainWindow(state);
            window.Show();
            window.UpdateLayout();
            var shell = window.Shell;

            Assert.AreEqual(1, shell.RetainedPageCount);
            Assert.AreEqual("OverviewPage", shell.ActivePageName);
            Assert.IsInstanceOfType<OverviewView>(shell.FindName("OverviewPage"));
            Assert.IsNull(shell.FindName("RealtimeActivityPage"));

            Assert.IsTrue(shell.NavigateTo("realtime-activity"));
            window.UpdateLayout();
            Assert.AreEqual(1, shell.RetainedPageCount);
            Assert.AreEqual("RealtimeActivityPage", shell.ActivePageName);
            Assert.IsNull(shell.FindName("OverviewPage"));
            Assert.IsInstanceOfType<RealtimeActivityView>(
                shell.FindName("RealtimeActivityPage"));

            Assert.IsTrue(shell.NavigateTo("evaluation"));
            window.UpdateLayout();
            Assert.AreEqual(0, shell.RetainedPageCount);
            Assert.IsNull(shell.ActivePageName);
            Assert.IsNull(shell.FindName("RealtimeActivityPage"));

            window.Close();
        }, TimeSpan.FromSeconds(30));
    }

    private static void PumpDispatcherUntil(Task task)
    {
        if (task.IsCompleted)
        {
            task.GetAwaiter().GetResult();
            return;
        }

        var frame = new DispatcherFrame();
        _ = task.ContinueWith(
            _ => frame.Continue = false,
            CancellationToken.None,
            TaskContinuationOptions.ExecuteSynchronously,
            TaskScheduler.FromCurrentSynchronizationContext());
        Dispatcher.PushFrame(frame);
        task.GetAwaiter().GetResult();
    }
}
