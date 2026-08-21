using System.Text.RegularExpressions;
using HerdrOps.App.Lifecycle;
using HerdrOps.App.Localization;
using HerdrOps.Domain.Lifecycle;
using HerdrOps.Domain.Settings;

namespace HerdrOps.IntegrationTests;

[TestClass]
[DoNotParallelize]
public sealed class TrayLifecycleIntegrationTests
{
    [TestCleanup]
    public void RestoreThaiLanguage() => UiLanguageService.Shared.SetLanguage(UiLanguage.Thai);

    [TestMethod]
    public void TrayMenuBuilderProjectsConfiguredWidgetAndOneSelectedLanguage()
    {
        var settings = AppSettings.Defaults with
        {
            WidgetVariant = AppSettingsWidgetVariant.FloatingVertical,
        };
        var language = UiLanguageService.Shared;
        var builder = new TrayMenuBuilder(() => settings, language);

        language.SetLanguage(UiLanguage.Thai);
        var thai = builder.Build();
        AssertLanguageSelection(thai, TrayCommand.SelectThaiLanguage);
        Assert.IsTrue(thai.Items.Any(item => item.Label.Contains("วิดเจ็ต", StringComparison.Ordinal)));
        Assert.AreEqual(
            TrayCommand.ToggleWidgetEnabled,
            thai.Items.Single(item => item.Command == TrayCommand.ToggleWidgetEnabled).Command);
        Assert.IsFalse(thai.Items.Any(item => item.Label.Contains("Show Dashboard", StringComparison.Ordinal)));
        Assert.IsFalse(thai.Items.Any(item => item.Label.Contains("Exit HerdrOps", StringComparison.Ordinal)));

        language.SetLanguage(UiLanguage.English);
        var english = builder.Build();
        AssertLanguageSelection(english, TrayCommand.SelectEnglishLanguage);
        Assert.IsTrue(english.Items.Any(item => item.Label.Contains("widget", StringComparison.OrdinalIgnoreCase)));
        Assert.IsTrue(english.Items.All(item => !Regex.IsMatch(item.Label, "[ก-๙]")));
        Assert.AreNotEqual(
            thai.Items.Single(item => item.Command == TrayCommand.ShowConfiguredWidget).Label,
            english.Items.Single(item => item.Command == TrayCommand.ShowConfiguredWidget).Label);
    }

    [TestMethod]
    public void SyntheticTrayBackendExercisesControllerLifecycleWithoutAnOsResource()
    {
        var backend = new InMemoryTrayBackend();
        var target = new RecordingTrayTarget();
        var menu = new TrayMenuModel(
            "HerdrOps",
            [
                new TrayMenuItem(TrayCommand.ShowDashboard, "Dashboard"),
                new TrayMenuItem(TrayCommand.ShowConfiguredWidget, "Widget"),
                new TrayMenuItem(TrayCommand.SelectThaiLanguage, "ไทย", isChecked: true),
                new TrayMenuItem(TrayCommand.SelectEnglishLanguage, "English"),
                new TrayMenuItem(TrayCommand.Exit, "Exit"),
            ]);
        var controller = new TrayLifecycleController(backend, () => menu, target);

        controller.Start();
        controller.Start();
        backend.Invoke(TrayCommand.ShowDashboard);
        controller.Refresh();
        controller.Stop();
        controller.Stop();
        controller.Dispose();
        controller.Dispose();

        Assert.AreEqual(1, backend.ShowCount);
        Assert.AreEqual(1, backend.UpdateCount);
        Assert.AreEqual(1, backend.HideCount);
        Assert.AreEqual(1, backend.DisposeCount);
        CollectionAssert.AreEqual(new[] { TrayCommand.ShowDashboard }, target.Commands);
    }

    private static void AssertLanguageSelection(TrayMenuModel menu, TrayCommand selectedCommand)
    {
        var languageItems = menu.Items
            .Where(item => item.Command is
                TrayCommand.SelectThaiLanguage or TrayCommand.SelectEnglishLanguage)
            .ToArray();
        Assert.HasCount(2, languageItems);
        Assert.AreEqual(1, languageItems.Count(item => item.IsChecked));
        Assert.IsTrue(languageItems.Single(item => item.Command == selectedCommand).IsChecked);
    }

    private sealed class InMemoryTrayBackend : ITrayBackend
    {
        private Action<TrayCommand>? _handler;

        public int ShowCount { get; private set; }

        public int UpdateCount { get; private set; }

        public int HideCount { get; private set; }

        public int DisposeCount { get; private set; }

        public void Show(TrayMenuModel menu, Action<TrayCommand> commandHandler)
        {
            ShowCount++;
            _handler = commandHandler;
        }

        public void Update(TrayMenuModel menu) => UpdateCount++;

        public void Hide() => HideCount++;

        public void Invoke(TrayCommand command) => _handler?.Invoke(command);

        public void Dispose() => DisposeCount++;
    }

    private sealed class RecordingTrayTarget : ITrayCommandTarget
    {
        public List<TrayCommand> Commands { get; } = [];

        public void ShowDashboard() => Commands.Add(TrayCommand.ShowDashboard);

        public void HideDashboard() => Commands.Add(TrayCommand.HideDashboard);

        public void ShowConfiguredWidget() => Commands.Add(TrayCommand.ShowConfiguredWidget);

        public void ToggleWidgetEnabled() => Commands.Add(TrayCommand.ToggleWidgetEnabled);

        public void SelectLanguage(AppSettingsLanguage language) =>
            Commands.Add(language == AppSettingsLanguage.Thai
                ? TrayCommand.SelectThaiLanguage
                : TrayCommand.SelectEnglishLanguage);

        public void SelectTheme(AppSettingsTheme theme) =>
            Commands.Add(theme switch
            {
                AppSettingsTheme.System => TrayCommand.SelectSystemTheme,
                AppSettingsTheme.Light => TrayCommand.SelectLightTheme,
                AppSettingsTheme.Dark => TrayCommand.SelectDarkTheme,
                _ => TrayCommand.SelectSystemTheme,
            });

        public void Exit() => Commands.Add(TrayCommand.Exit);
    }
}
