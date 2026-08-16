using HerdrOps.App;
using HerdrOps.App.Live;

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

            Assert.AreSame(state, window.Shell.LiveDashboard);
            Assert.IsFalse(window.DashboardResourcesReleased);

            window.Close();

            Assert.IsTrue(window.DashboardResourcesReleased);
            Assert.ThrowsExactly<InvalidOperationException>(() => _ = window.Shell);
            state.RefreshLanguage();
        }, TimeSpan.FromSeconds(30));
    }
}
