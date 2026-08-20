using System.Security.Cryptography;
using System.Text;
using HerdrOps.Contracts;
using HerdrOps.Infrastructure.Herdr;

namespace HerdrOps.ContractTests;

[TestClass]
public sealed class HerdrProtocolInspectorContractTests
{
    [TestMethod]
    public void KnownCompatibleFixtureProducesContractEvidenceWithoutRuntimeClaim()
    {
        using var fixture = ProtocolFixture.Create();

        var inspection = new HerdrProtocolInspector(fixture.Policy).Inspect(fixture.ExecutablePath);

        Assert.AreEqual(HerdrProtocolCompatibilityStatus.Compatible, inspection.Status);
        Assert.IsTrue(inspection.IsCompatible);
        Assert.AreEqual(EvidenceClass.Contract, inspection.EvidenceClass);
        Assert.IsFalse(inspection.RuntimeObserved);
        Assert.AreEqual(fixture.ReleaseId, inspection.ReleaseId);
        Assert.AreEqual(fixture.BinarySha256, inspection.ExecutableSha256);
        Assert.IsNotNull(inspection.ContractSchemaFingerprintSha256);
        Assert.HasCount(64, inspection.ContractSchemaFingerprintSha256);
        Assert.IsEmpty(inspection.MissingRpcMethods);
        Assert.IsEmpty(inspection.MissingProtocolShapes);
        Assert.IsEmpty(inspection.MissingTransportMarkers);
    }

    [TestMethod]
    public void MatchingIdentityWithMissingShapeFailsClosedAndNamesTheGap()
    {
        var missingMarker = HerdrProtocolContractV082Preview.Policy.RequiredShapes[0].BinaryMarker;
        using var fixture = ProtocolFixture.Create(missingMarker);

        var inspection = new HerdrProtocolInspector(fixture.Policy).Inspect(fixture.ExecutablePath);

        Assert.AreEqual(HerdrProtocolCompatibilityStatus.MissingProtocolMarkers, inspection.Status);
        Assert.IsFalse(inspection.IsCompatible);
        Assert.IsFalse(inspection.RuntimeObserved);
        CollectionAssert.Contains(inspection.MissingProtocolShapes.ToArray(), missingMarker);
        Assert.IsNull(inspection.ContractSchemaFingerprintSha256);
    }

    [TestMethod]
    public void UnknownBinaryHashFailsClosedWithActionableStatus()
    {
        using var fixture = ProtocolFixture.Create();
        var rejectedPolicy = fixture.Policy with
        {
            CompatibleBinaries = Array.AsReadOnly(
            [
                new HerdrBinaryIdentity(fixture.ReleaseId, new string('0', 64)),
            ]),
        };

        var inspection = new HerdrProtocolInspector(rejectedPolicy).Inspect(fixture.ExecutablePath);

        Assert.AreEqual(HerdrProtocolCompatibilityStatus.UnsupportedBinaryHash, inspection.Status);
        StringAssert.Contains(inspection.Message, "successor contract review");
        Assert.IsFalse(inspection.RuntimeObserved);
    }

    [TestMethod]
    public void MalformedPortableExecutableFailsBeforeProtocolAdmission()
    {
        using var fixture = ProtocolFixture.Create(portableExecutableHeader: false);

        var inspection = new HerdrProtocolInspector(fixture.Policy).Inspect(fixture.ExecutablePath);

        Assert.AreEqual(HerdrProtocolCompatibilityStatus.InvalidPortableExecutable, inspection.Status);
        StringAssert.Contains(inspection.Message, "MZ header");
        Assert.IsFalse(inspection.RuntimeObserved);
    }

    [TestMethod]
    public void MissingExecutableReturnsActionableNonCompatibleResult()
    {
        var missingPath = Path.Combine(Path.GetTempPath(), $"herdr-missing-{Guid.NewGuid():N}.exe");

        var inspection = new HerdrProtocolInspector().Inspect(missingPath);

        Assert.AreEqual(HerdrProtocolCompatibilityStatus.ExecutableNotFound, inspection.Status);
        StringAssert.Contains(inspection.Message, missingPath);
        Assert.IsFalse(inspection.RuntimeObserved);
    }

    [TestMethod]
    public void ProductionPolicyPinsExactIdentitySurfaceAndFingerprint()
    {
        var policy = HerdrProtocolContractV082Preview.Policy;

        Assert.AreEqual(HerdrProtocolContractV082Preview.ContractId, policy.ContractId);
        Assert.AreEqual(HerdrProtocolContractV082Preview.Revision, policy.Revision);
        Assert.HasCount(1, policy.CompatibleBinaries);
        Assert.AreEqual(
            HerdrProtocolContractV082Preview.SupportedReleaseId,
            policy.CompatibleBinaries[0].ReleaseId);
        Assert.AreEqual(
            HerdrProtocolContractV082Preview.SupportedBinarySha256,
            policy.CompatibleBinaries[0].Sha256);
        CollectionAssert.AreEqual(
            new[]
            {
                "session.snapshot",
                "workspace.list",
                "tab.list",
                "pane.list",
                "agent.list",
                "agent.get",
                "pane.process_info",
                "pane.read",
                "events.subscribe",
            },
            policy.RequiredRpcMethods.ToArray());
        CollectionAssert.AreEqual(
            new[]
            {
                "SessionSnapshot:10",
                "WorkspaceInfo:10",
                "TabInfo:7",
                "PaneInfo:19",
                "AgentInfo:22",
                "PaneProcessInfo:5",
                "PaneReadParams:5",
                "PaneReadResult:8",
                "EventsSubscribeParams:1",
                "Subscription.PaneAgentStatusChanged:2",
                "PaneAgentStatusChangedEvent:7",
                "SubscriptionEventEnvelope:2",
            },
            policy.RequiredShapes.Select(shape => $"{shape.Name}:{shape.ElementCount}").ToArray());
        CollectionAssert.AreEqual(
            new[]
            {
                "HERDR_ENV",
                "HERDR_SOCKET_PATH",
                "HERDR_PANE_ID",
                "process.platform === \"win32\"",
            },
            policy.RequiredTransportMarkers.ToArray());
        Assert.AreEqual(
            "3533FDC87F0008323B3DCB798ECD7E68B104F7E1323551ECF41CD4434D9892DE",
            HerdrProtocolContractFingerprint.Compute(
                policy,
                HerdrProtocolContractV082Preview.SupportedReleaseId));
    }

    [TestMethod]
    public void UnreviewedReleaseFailsClosedEvenWhenBytesMatchKnownFixture()
    {
        using var fixture = ProtocolFixture.Create();
        var unreviewedReleasePath = Path.Combine(fixture.RootPath, "unreviewed-release");
        Directory.CreateDirectory(unreviewedReleasePath);
        var unreviewedExecutable = Path.Combine(unreviewedReleasePath, "herdr.exe");
        File.Copy(fixture.ExecutablePath, unreviewedExecutable);

        var inspection = new HerdrProtocolInspector(fixture.Policy).Inspect(unreviewedExecutable);

        Assert.AreEqual(HerdrProtocolCompatibilityStatus.UnsupportedRelease, inspection.Status);
        StringAssert.Contains(inspection.Message, "not admitted");
        Assert.IsFalse(inspection.RuntimeObserved);
    }

    private sealed class ProtocolFixture : IDisposable
    {
        private ProtocolFixture(
            string rootPath,
            string releaseId,
            string executablePath,
            string binarySha256,
            HerdrProtocolSupportPolicy policy)
        {
            RootPath = rootPath;
            ReleaseId = releaseId;
            ExecutablePath = executablePath;
            BinarySha256 = binarySha256;
            Policy = policy;
        }

        public string RootPath { get; }

        public string ReleaseId { get; }

        public string ExecutablePath { get; }

        public string BinarySha256 { get; }

        public HerdrProtocolSupportPolicy Policy { get; }

        public static ProtocolFixture Create(
            string? omittedMarker = null,
            bool portableExecutableHeader = true)
        {
            var releaseId = "fixture-herdr-0.8.0-x86_64-pc-windows-msvc";
            var rootPath = Path.Combine(
                Path.GetTempPath(),
                "HerdrOps.ContractTests",
                Guid.NewGuid().ToString("N"));
            var releasePath = Path.Combine(rootPath, releaseId);
            Directory.CreateDirectory(releasePath);
            var executablePath = Path.Combine(releasePath, "herdr.exe");

            var sourcePolicy = HerdrProtocolContractV082Preview.Policy;
            var markers = sourcePolicy.RequiredRpcMethods
                .Concat(sourcePolicy.RequiredShapes.Select(shape => shape.BinaryMarker))
                .Concat(sourcePolicy.RequiredTransportMarkers)
                .Where(marker => !string.Equals(marker, omittedMarker, StringComparison.Ordinal));
            var prefix = portableExecutableHeader ? "MZ" : "NO";
            var fixtureBytes = Encoding.ASCII.GetBytes(prefix + "\0" + string.Join("\0", markers));
            File.WriteAllBytes(executablePath, fixtureBytes);
            var binarySha256 = Convert.ToHexString(SHA256.HashData(fixtureBytes));
            var policy = sourcePolicy with
            {
                CompatibleBinaries = Array.AsReadOnly(
                [
                    new HerdrBinaryIdentity(releaseId, binarySha256),
                ]),
            };

            return new ProtocolFixture(rootPath, releaseId, executablePath, binarySha256, policy);
        }

        public void Dispose()
        {
            var resolvedRoot = Path.GetFullPath(RootPath);
            var expectedParent = Path.GetFullPath(
                Path.Combine(Path.GetTempPath(), "HerdrOps.ContractTests")) +
                Path.DirectorySeparatorChar;
            if (resolvedRoot.StartsWith(expectedParent, StringComparison.OrdinalIgnoreCase) &&
                Directory.Exists(resolvedRoot))
            {
                Directory.Delete(resolvedRoot, recursive: true);
            }
        }
    }
}
