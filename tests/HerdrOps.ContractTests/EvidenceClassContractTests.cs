using HerdrOps.Contracts;

namespace HerdrOps.ContractTests;

[TestClass]
public sealed class EvidenceClassContractTests
{
    [TestMethod]
    public void EvidenceClassesRemainDistinctAndOrdered()
    {
        var names = Enum.GetNames<EvidenceClass>();

        CollectionAssert.AreEqual(
            new[] { "Static", "Synthetic", "Contract", "Runtime", "IndependentReview", "Release" },
            names);
    }
}
