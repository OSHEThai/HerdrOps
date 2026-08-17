using System.Windows;
using HerdrOps.App;
using HerdrOps.App.Lifecycle;
using HerdrOps.App.Live;
using HerdrOps.App.Localization;
using HerdrOps.App.Widgets;
using HerdrOps.Domain.Settings;

namespace HerdrOps.RuntimeTests;

[TestClass]
[DoNotParallelize]
public sealed class DesktopLifecycleWindowTests
{
    [TestMethod]
    public void DashboardHideRestoreAndClosedWindowRecreationAreIdempotent()
    {
        WpfTestHost.Run(() =>
        {
            using var state = new LiveDashboardState();
            using var manager = new DashboardWindowManager(() => new MainWindow(state));

            manager.Show();
            var first = manager.Current;
            Assert.IsNotNull(first);
            Assert.IsTrue(first!.IsVisible);

            manager.Hide();
            manager.Hide();
            Assert.IsFalse(first.IsVisible);

            manager.Show();
            Assert.AreSame(first, manager.Current);
            Assert.IsTrue(first.IsVisible);

            first.CloseToTrayOnUserClose = false;
            first.Close();
            Assert.IsNull(manager.Current);

            manager.Show();
            var recreated = manager.Current;
            Assert.IsNotNull(recreated);
            Assert.AreNotSame(first, recreated);
            Assert.IsTrue(recreated!.IsVisible);
        });
    }

    [TestMethod]
    public void UserCloseUsesHideToTrayAndDoesNotRetainAClosedDashboard()
    {
        WpfTestHost.Run(() =>
        {
            using var state = new LiveDashboardState();
            using var manager = new DashboardWindowManager(() => new MainWindow(state));
            manager.Show();
            var dashboard = manager.Current;
            Assert.IsNotNull(dashboard);

            dashboard!.Close();

            Assert.IsFalse(dashboard.IsClosed);
            Assert.IsFalse(dashboard.IsVisible);
            Assert.AreSame(dashboard, manager.Current);
        });
    }

    [TestMethod]
    public void WidgetLauncherReusesOneWindowPerVariantAndRecreatesAfterClose()
    {
        WpfTestHost.Run(() =>
        {
            using var launcher = new WidgetWindowLauncher(SyntheticWidgetState.Create());

            launcher.Open(WidgetVariant.Normal);
            var first = launcher.OpenWindows.Single();
            launcher.Open(WidgetVariant.Normal);

            Assert.AreEqual(1, launcher.OpenWindowCount);
            Assert.AreSame(first, launcher.OpenWindows.Single());

            first.Close();
            Assert.AreEqual(0, launcher.OpenWindowCount);

            launcher.Open(WidgetVariant.Normal);
            var recreated = launcher.OpenWindows.Single();
            Assert.AreNotSame(first, recreated);
            Assert.AreEqual(1, launcher.OpenWindowCount);
        });
    }

    [TestMethod]
    public void WidgetSettingsCallbackEnablesDisablesAndSwitchesConfiguredWindow()
    {
        WpfTestHost.Run(() =>
        {
            using var launcher = new WidgetWindowLauncher(SyntheticWidgetState.Create());

            launcher.ApplySettings(AppSettings.Defaults);
            Assert.AreEqual(1, launcher.OpenWindowCount);

            launcher.ApplySettings(AppSettings.Defaults with
            {
                WidgetVariant = AppSettingsWidgetVariant.Expanded,
            });
            Assert.AreEqual(1, launcher.OpenWindowCount);
            Assert.AreEqual(
                WidgetVariant.Expanded,
                launcher.OpenWindows.Single().Descriptor.Variant);

            launcher.ApplySettings(AppSettings.Defaults with { WidgetEnabled = false });
            Assert.AreEqual(0, launcher.OpenWindowCount);
        });
    }

    [TestMethod]
    public void DashboardLanguageAndWidgetGalleryUseInjectedLifecycleCallers()
    {
        WpfTestHost.Run(() =>
        {
            using var state = new LiveDashboardState();
            var selectedLanguages = new List<UiLanguage>();
            var selectedWidgets = new List<AppSettingsWidgetVariant>();
            var enabledValues = new List<bool>();
            var openedVariants = new List<WidgetVariant>();
            var shell = new HerdrOps.App.Views.ShellView(
                state,
                selectedLanguages.Add,
                selectedWidgets.Add,
                enabledValues.Add,
                widgetLauncher: new RecordingWidgetLauncher(openedVariants));

            shell.SetLanguage(UiLanguage.English);
            var gallery = new WidgetGalleryView(
                SyntheticWidgetState.Create(),
                new RecordingWidgetLauncher(openedVariants),
                selectedWidgets.Add,
                enabledValues.Add);
            gallery.OpenVariant(WidgetVariant.Expanded);

            CollectionAssert.AreEqual(new[] { UiLanguage.English }, selectedLanguages);
            CollectionAssert.AreEqual(new[] { AppSettingsWidgetVariant.Expanded }, selectedWidgets);
            CollectionAssert.AreEqual(new[] { true }, enabledValues);
            CollectionAssert.AreEqual(new[] { WidgetVariant.Expanded }, openedVariants);
        });
    }

    private sealed class RecordingWidgetLauncher(ICollection<WidgetVariant> openedVariants) : IWidgetWindowLauncher
    {
        public void Open(WidgetVariant variant) => openedVariants.Add(variant);
    }
}
