using System.Diagnostics;
using System.Windows;
using HerdrOps.App;
using HerdrOps.App.Live;
using HerdrOps.App.RuntimeEvidence;
using HerdrOps.App.Views;
using HerdrOps.App.Widgets;

namespace HerdrOps.RuntimeTests;

[TestClass]
[DoNotParallelize]
public sealed class RuntimeEvidenceResourceLifecycleTests
{
    [TestMethod]
    public void ResourceStageDiagnosticsRemainExactAndOrdered()
    {
        CollectionAssert.AreEqual(
            new[]
            {
                "pre-capture",
                "post-initial-captures",
                "post-dashboard-close",
                "post-final-widget-capture",
                "post-cleanup",
            },
            RuntimeEvidenceRunner.RequiredResourceStageNames.ToArray());
    }

    [TestMethod]
    public void ResourceStageCheckpointBindsCurrentProcessAndMemoryCounters()
    {
        using var app = Process.GetCurrentProcess();
        var observedBeforeUtc = DateTimeOffset.UtcNow;

        var checkpoint = RuntimeEvidenceRunner.ObserveResourceStageCheckpoint(
            "pre-capture",
            app);

        var observedAfterUtc = DateTimeOffset.UtcNow;
        Assert.AreEqual("pre-capture", checkpoint.Stage);
        Assert.IsTrue(checkpoint.ObservedUtc >= observedBeforeUtc);
        Assert.IsTrue(checkpoint.ObservedUtc <= observedAfterUtc);
        Assert.AreEqual(app.Id, checkpoint.AppProcessId);
        Assert.AreEqual(
            new DateTimeOffset(app.StartTime.ToUniversalTime()),
            checkpoint.AppProcessStartUtc);
        Assert.IsGreaterThan(0d, checkpoint.AppWorkingSetMegabytes);
        Assert.IsGreaterThan(0d, checkpoint.AppPrivateMemoryMegabytes);
        Assert.IsGreaterThanOrEqualTo(0d, checkpoint.AppPagedMemoryMegabytes);
        Assert.IsGreaterThan(0d, checkpoint.ManagedHeapMegabytes);
    }

    [TestMethod]
    public void ResourceStageCheckpointRejectsBlankStage()
    {
        using var app = Process.GetCurrentProcess();

        Assert.ThrowsExactly<ArgumentException>(() =>
            RuntimeEvidenceRunner.ObserveResourceStageCheckpoint(" ", app));
    }

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
            Assert.AreEqual(0, shell.RetainedPageCount);
            Assert.IsNull(shell.ActivePageName);
            Assert.ThrowsExactly<InvalidOperationException>(() => _ = window.Shell);
            state.RefreshLanguage();
        }, TimeSpan.FromSeconds(30));
    }

    [TestMethod]
    public void ClosingDashboardReleasesItsTreeWhileAWidgetRemainsVisible()
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

            Assert.IsTrue(window.DashboardResourcesReleased);
            Assert.IsTrue(widget.IsVisible);
            Assert.IsFalse(widget.ResourcesReleased);

            widget.Close();
            Assert.IsTrue(widget.ResourcesReleased);
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
            Assert.AreEqual(1, shell.RetainedPageCount);
            Assert.AreEqual("EvaluationPage", shell.ActivePageName);
            Assert.IsNull(shell.FindName("RealtimeActivityPage"));
            Assert.IsInstanceOfType<EvaluationView>(shell.FindName("EvaluationPage"));

            Assert.IsTrue(shell.NavigateTo("daily-summary"));
            window.UpdateLayout();
            Assert.AreEqual(1, shell.RetainedPageCount);
            Assert.AreEqual("DailySummaryPage", shell.ActivePageName);
            Assert.IsNull(shell.FindName("EvaluationPage"));
            Assert.IsInstanceOfType<DailySummaryView>(shell.FindName("DailySummaryPage"));

            window.Close();
        }, TimeSpan.FromSeconds(30));
    }

    [TestMethod]
    public void SyntheticPreviewShellFallsBackToPlaceholderForGuardedDestinations()
    {
        WpfTestHost.Run(() =>
        {
            var shell = ShellView.CreateSyntheticPreview();
            var window = new Window { Content = shell, Width = 1366, Height = 768 };
            window.Show();
            window.UpdateLayout();

            Assert.AreEqual(1, shell.RetainedPageCount);
            Assert.AreEqual("OverviewPage", shell.ActivePageName);

            Assert.IsTrue(shell.NavigateTo("evaluation"));
            window.UpdateLayout();
            Assert.AreEqual(1, shell.RetainedPageCount);
            Assert.AreEqual("EvaluationPage", shell.ActivePageName);
            Assert.IsInstanceOfType<EvaluationView>(shell.FindName("EvaluationPage"));

            Assert.IsTrue(shell.NavigateTo("daily-summary"));
            window.UpdateLayout();
            Assert.AreEqual(1, shell.RetainedPageCount);
            Assert.AreEqual("DailySummaryPage", shell.ActivePageName);
            Assert.IsNull(shell.FindName("EvaluationPage"));
            Assert.IsInstanceOfType<DailySummaryView>(shell.FindName("DailySummaryPage"));

            Assert.IsTrue(shell.NavigateTo("live-organization"));
            window.UpdateLayout();
            Assert.AreEqual(0, shell.RetainedPageCount);
            Assert.IsNull(shell.ActivePageName);
            Assert.IsNull(shell.FindName("OverviewPage"));

            window.Close();
        }, TimeSpan.FromSeconds(30));
    }

    [TestMethod]
    public void QueuedGalleryLanguageCallbackIsIgnoredAfterResourcesAreReleased()
    {
        WpfTestHost.Run(() =>
        {
            var view = new WidgetGalleryView();
            var callback = typeof(WidgetGalleryView).GetMethod(
                "ApplyLanguageChange",
                System.Reflection.BindingFlags.Instance |
                System.Reflection.BindingFlags.NonPublic) ??
                throw new InvalidOperationException("Gallery language callback was not found.");

            view.ReleaseResources();
            callback.Invoke(view, [0]);

            Assert.IsTrue(view.ResourcesReleased);
        }, TimeSpan.FromSeconds(30));
    }

    [TestMethod]
    public void QueuedGalleryTitleCallbackIsIgnoredAfterWindowIsClosed()
    {
        WpfTestHost.Run(() =>
        {
            var window = new WidgetGalleryWindow();
            var callback = typeof(WidgetGalleryWindow).GetMethod(
                "RefreshTitle",
                System.Reflection.BindingFlags.Instance |
                System.Reflection.BindingFlags.NonPublic) ??
                throw new InvalidOperationException("Gallery title callback was not found.");
            window.Show();

            window.Close();
            callback.Invoke(window, [0]);

            Assert.IsTrue(window.ResourcesReleased);
            Assert.IsTrue(window.GalleryView.ResourcesReleased);
        }, TimeSpan.FromSeconds(30));
    }
}
