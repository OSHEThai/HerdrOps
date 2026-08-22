using HerdrOps.App.RuntimeEvidence;
using HerdrOps.App.Localization;

namespace HerdrOps.RuntimeTests;

[TestClass]
public sealed class RuntimeEvidenceOptionsTests
{
    [TestMethod]
    public void TryParseRequiresAndPreservesReferenceHostProfileBinding()
    {
        var parsed = RuntimeEvidenceOptions.TryParse(
            CompleteArguments(),
            out var options,
            out var error);

        Assert.IsTrue(parsed, error);
        Assert.IsNotNull(options);
        Assert.AreEqual(RuntimeEvidenceOptions.ApprovedProfileId, options.ProfileId);
        Assert.AreEqual(RuntimeEvidenceOptions.ApprovedProfileSha256, options.ProfileSha256);
        Assert.AreEqual(RuntimeEvidenceOptions.ApprovedIdleSeconds, options.IdleSeconds);
    }

    [TestMethod]
    public void TryParseFailsClosedWhenReferenceHostProfileBindingIsMissing()
    {
        var arguments = CompleteArguments()
            .Where(argument =>
                !string.Equals(argument, "--reference-host-profile-id", StringComparison.Ordinal) &&
                !string.Equals(argument, RuntimeEvidenceOptions.ApprovedProfileId, StringComparison.Ordinal))
            .ToArray();

        var parsed = RuntimeEvidenceOptions.TryParse(arguments, out var options, out var error);

        Assert.IsFalse(parsed);
        Assert.IsNull(options);
        StringAssert.Contains(error, "--reference-host-profile-id");
    }

    [TestMethod]
    public void TryParseRejectsNonCanonicalLowercaseProfileDigest()
    {
        var arguments = CompleteArguments();
        arguments[^1] = RuntimeEvidenceOptions.ApprovedProfileSha256.ToLowerInvariant();

        var parsed = RuntimeEvidenceOptions.TryParse(arguments, out var options, out var error);

        Assert.IsFalse(parsed);
        Assert.IsNull(options);
        StringAssert.Contains(error, "uppercase hexadecimal");
    }

    [TestMethod]
    public void TryParseRejectsUnapprovedWellFormedProfileBinding()
    {
        var arguments = CompleteArguments();
        arguments[^3] = "herdrops-v0.2-unapproved-host";

        var parsed = RuntimeEvidenceOptions.TryParse(arguments, out var options, out var error);

        Assert.IsFalse(parsed);
        Assert.IsNull(options);
        StringAssert.Contains(error, "approved profile ID");
    }

    [TestMethod]
    public void TryParseRejectsUnapprovedWellFormedProfileDigest()
    {
        var arguments = CompleteArguments();
        arguments[^1] = new string('A', 64);

        var parsed = RuntimeEvidenceOptions.TryParse(arguments, out var options, out var error);

        Assert.IsFalse(parsed);
        Assert.IsNull(options);
        StringAssert.Contains(error, "approved canonical profile SHA-256");
    }

    [TestMethod]
    [DataRow("19")]
    [DataRow("21")]
    public void TryParseRejectsUnapprovedIdleDuration(string idleSeconds)
    {
        var arguments = CompleteArguments()
            .Concat(new[] { "--idle-seconds", idleSeconds })
            .ToArray();

        var parsed = RuntimeEvidenceOptions.TryParse(arguments, out var options, out var error);

        Assert.IsFalse(parsed);
        Assert.IsNull(options);
        StringAssert.Contains(error, "exactly the approved 20-second");
    }

    [TestMethod]
    [DataRow("Thai", UiLanguage.Thai)]
    [DataRow("English", UiLanguage.English)]
    public void TryParsePreservesEachRequiredLanguage(string requested, UiLanguage expected)
    {
        var arguments = CompleteArguments()
            .Concat(new[] { "--language", requested })
            .ToArray();

        var parsed = RuntimeEvidenceOptions.TryParse(arguments, out var options, out var error);

        Assert.IsTrue(parsed, error);
        Assert.IsNotNull(options);
        Assert.AreEqual(expected, options.Language);
        Assert.AreEqual(requested, options.Language.ToString());
    }

    private static string[] CompleteArguments() =>
    [
        "--runtime-evidence-report", "runtime-report.json",
        "--capture-directory", "captures",
        "--core-pid", Environment.ProcessId.ToString(),
        "--reference-host-profile-id", RuntimeEvidenceOptions.ApprovedProfileId,
        "--reference-host-profile-sha256", RuntimeEvidenceOptions.ApprovedProfileSha256,
    ];
}
