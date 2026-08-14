using HerdrOps.Contracts;

namespace HerdrOps.RuntimeTests;

[TestClass]
public sealed class RuntimeEvidenceBoundaryTests
{
    [TestMethod]
    [DataRow(EvidenceClass.Static, false)]
    [DataRow(EvidenceClass.Synthetic, false)]
    [DataRow(EvidenceClass.Contract, false)]
    [DataRow(EvidenceClass.Runtime, true)]
    [DataRow(EvidenceClass.IndependentReview, false)]
    [DataRow(EvidenceClass.Release, true)]
    public void OnlyRuntimeAndReleaseEvidenceRequireObservedSystem(
        EvidenceClass evidenceClass,
        bool expected)
    {
        Assert.AreEqual(expected, evidenceClass.RequiresObservedSystem());
    }
}
