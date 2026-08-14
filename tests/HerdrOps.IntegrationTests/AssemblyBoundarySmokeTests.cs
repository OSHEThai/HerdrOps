using HerdrOps.App;
using HerdrOps.Core;
using HerdrOps.Infrastructure;

namespace HerdrOps.IntegrationTests;

[TestClass]
public sealed class AssemblyBoundarySmokeTests
{
    [TestMethod]
    public void WindowsAssembliesLoadTogether()
    {
        var assemblyNames = new[]
        {
            typeof(AppAssemblyMarker).Assembly.GetName().Name,
            typeof(CoreAssemblyMarker).Assembly.GetName().Name,
            typeof(InfrastructureAssemblyMarker).Assembly.GetName().Name,
        };

        CollectionAssert.AreEquivalent(
            new[] { "HerdrOps.App", "HerdrOps.Core", "HerdrOps.Infrastructure" },
            assemblyNames);
    }
}
