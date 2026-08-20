// WPF views and UiLanguageService.Shared are process-wide dispatcher state.
// Serialize the complete RuntimeTests assembly so no other test class can
// mutate the language catalog while a view is being measured or rendered.
[assembly: DoNotParallelize]

namespace HerdrOps.RuntimeTests;

[TestClass]
public sealed class RuntimeTestAssemblyLifecycle
{
    [AssemblyInitialize]
    public static void StartWpfTestHost(TestContext _)
    {
        WpfTestHost.BeginStartup();
    }

    [AssemblyCleanup]
    public static void StopWpfTestHost()
    {
        WpfTestHost.Shutdown();
    }
}
