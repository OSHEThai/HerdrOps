namespace HerdrOps.Contracts;

/// <summary>
/// Identifies what a piece of evidence can honestly prove.
/// </summary>
public enum EvidenceClass
{
    Static,
    Synthetic,
    Contract,
    Runtime,
    IndependentReview,
    Release,
}

public static class EvidenceClassExtensions
{
    /// <summary>
    /// Returns whether the evidence class requires observation of the running or packaged system.
    /// </summary>
    public static bool RequiresObservedSystem(this EvidenceClass evidenceClass) =>
        evidenceClass is EvidenceClass.Runtime or EvidenceClass.Release;
}
