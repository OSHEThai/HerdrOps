using HerdrOps.App.Themes;
using HerdrOps.Domain.Settings;
using Microsoft.VisualStudio.TestTools.UnitTesting;

namespace HerdrOps.IntegrationTests;

[TestClass]
public sealed class UiThemeIntegrationTests
{
    [TestMethod]
    public void UiThemeService_UpdatesCurrentTheme_WhenSetThemeIsCalled()
    {
        var service = new UiThemeService();
        Assert.AreEqual(AppSettingsTheme.System, service.CurrentTheme);

        var propertyChangedFired = false;
        service.PropertyChanged += (sender, args) =>
        {
            if (args.PropertyName == nameof(UiThemeService.CurrentTheme))
            {
                propertyChangedFired = true;
            }
        };

        service.SetTheme(AppSettingsTheme.Dark);

        Assert.AreEqual(AppSettingsTheme.Dark, service.CurrentTheme);
        Assert.IsTrue(propertyChangedFired);
    }

    [TestMethod]
    public void UiThemeService_DoesNotFirePropertyChanged_WhenThemeIsSame()
    {
        var service = new UiThemeService();
        service.SetTheme(AppSettingsTheme.Dark);

        var propertyChangedFired = false;
        service.PropertyChanged += (sender, args) =>
        {
            if (args.PropertyName == nameof(UiThemeService.CurrentTheme))
            {
                propertyChangedFired = true;
            }
        };

        service.SetTheme(AppSettingsTheme.Dark);

        Assert.IsFalse(propertyChangedFired);
    }
}
