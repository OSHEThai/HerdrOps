using HerdrOps.App.RuntimeEvidence;
using HerdrOps.App.Localization;
using System.IO;

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
    public void TryParsePreservesExactIssue10ProducerBindings()
    {
        var arguments = CompleteArguments()
            .Concat(Issue10ProducerArguments())
            .ToArray();

        var parsed = RuntimeEvidenceOptions.TryParse(arguments, out var options, out var error);

        Assert.IsTrue(parsed, error);
        Assert.IsNotNull(options);
        Assert.AreEqual(
            Path.GetFullPath("issue10-widget.json"),
            options.Issue10WidgetReportPath);
        Assert.AreEqual(
            Path.GetFullPath("issue10-binding.json"),
            options.Issue10BindingManifestPath);
        Assert.AreEqual(new string('c', 32), options.Issue10RunNonce);
        Assert.AreEqual(new string('a', 40), options.Issue10SourceCommit);
        Assert.AreEqual(new string('b', 40), options.Issue10SourceTree);
    }

    [TestMethod]
    public void TryParseRejectsPartialIssue10ProducerBinding()
    {
        var parsed = RuntimeEvidenceOptions.TryParse(
            CompleteArguments()
                .Concat(
                [
                    "--issue10-widget-report", "issue10-widget.json",
                    "--issue10-binding-manifest", "issue10-binding.json",
                    "--issue10-run-nonce", new string('c', 32),
                ])
                .ToArray(),
            out var options,
            out var error);

        Assert.IsFalse(parsed);
        Assert.IsNull(options);
        StringAssert.Contains(error, "requires --issue10-widget-report");
    }

    [TestMethod]
    public void TryParseRejectsNonCanonicalIssue10InvocationIdentity()
    {
        var arguments = CompleteArguments()
            .Concat(Issue10ProducerArguments())
            .ToArray();
        arguments[^5] = new string('C', 32);

        var parsed = RuntimeEvidenceOptions.TryParse(arguments, out var options, out var error);

        Assert.IsFalse(parsed);
        Assert.IsNull(options);
        StringAssert.Contains(error, "lowercase hexadecimal");
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

    private static string[] Issue10ProducerArguments() =>
    [
        "--issue10-widget-report", "issue10-widget.json",
        "--issue10-binding-manifest", "issue10-binding.json",
        "--issue10-run-nonce", new string('c', 32),
        "--issue10-source-commit", new string('a', 40),
        "--issue10-source-tree", new string('b', 40),
    ];
}
