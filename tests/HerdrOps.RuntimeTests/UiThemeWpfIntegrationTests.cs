using System.Linq;
using System.Windows;
using HerdrOps.App.Themes;
using HerdrOps.Domain.Settings;
using Microsoft.VisualStudio.TestTools.UnitTesting;
using Microsoft.Win32;

namespace HerdrOps.RuntimeTests;

[TestClass]
public sealed class UiThemeWpfIntegrationTests
{
    [TestMethod]
    public void UiThemeService_SwapsMergedDictionaries_OnThemeChangeAndSystemChange()
    {
        WpfTestHost.Run(() =>
        {
            var application = Application.Current;
            Assert.IsNotNull(application);

            var isSystemDark = false;
            var service = new UiThemeService(() => isSystemDark);

            // 1. Initially SetTheme(System) should apply the theme
            service.SetTheme(AppSettingsTheme.System);
            
            var lightDict = application.Resources.MergedDictionaries.FirstOrDefault(d => d.Source?.OriginalString.Contains("Tokens.Semantic.Light.xaml") == true);
            Assert.IsNotNull(lightDict, "Light theme dictionary should be present initially (System is light).");

            // 2. Change system theme to dark and simulate event
            isSystemDark = true;
            service.OnUserPreferenceChanged(this, new UserPreferenceChangedEventArgs(UserPreferenceCategory.General));
            
            // Need to let the dispatcher run since OnUserPreferenceChanged uses Invoke
            var darkDict = application.Resources.MergedDictionaries.FirstOrDefault(d => d.Source?.OriginalString.Contains("Tokens.Semantic.Dark.xaml") == true);
            Assert.IsNotNull(darkDict, "Dark theme dictionary should be present after System theme changes to dark.");

            // 3. Explicitly change to Light theme
            service.SetTheme(AppSettingsTheme.Light);
            
            var lightDictAfter = application.Resources.MergedDictionaries.FirstOrDefault(d => d.Source?.OriginalString.Contains("Tokens.Semantic.Light.xaml") == true);
            Assert.IsNotNull(lightDictAfter, "Light theme dictionary should be present after explicit Light theme.");
            
            // Token assertions
            Assert.IsTrue(lightDictAfter.Contains("HerdrOps.Brush.TopBar"), "TopBar token should exist in light theme.");
            Assert.IsTrue(lightDictAfter.Contains("HerdrOps.Brush.Surface"), "Surface token should exist in light theme.");
            
            var darkDictAfter = application.Resources.MergedDictionaries.FirstOrDefault(d => d.Source?.OriginalString.Contains("Tokens.Semantic.Dark.xaml") == true);
            Assert.IsNull(darkDictAfter, "Dark theme dictionary should be removed after explicit Light theme.");

            // Clean up
            service.Dispose();
        });
    }
}
