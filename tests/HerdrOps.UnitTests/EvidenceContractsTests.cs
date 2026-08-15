using HerdrOps.Domain.Evidence;

namespace HerdrOps.UnitTests;

[TestClass]
public sealed class EvidenceContractsTests
{
    private static readonly DateTimeOffset ObservedUtc =
        new(2026, 8, 15, 7, 0, 0, TimeSpan.Zero);

    [TestMethod]
    public void ChangedContentProducesDifferentEvidenceIdentity()
    {
        var request = CreateCaptureRequest();
        var first = EvidenceMetadataContract.Create(
            request,
            EvidenceArtifactAvailability.Present,
            5,
            new string('A', 64),
            "objects/AA/AA/first.evidence");
        var changed = EvidenceMetadataContract.Create(
            request,
            EvidenceArtifactAvailability.Present,
            5,
            new string('B', 64),
            "objects/BB/BB/second.evidence");

        Assert.AreNotEqual(first.EvidenceIdentitySha256, changed.EvidenceIdentitySha256);
        Assert.AreNotEqual(first.MetadataSha256, changed.MetadataSha256);
        Assert.AreEqual(
            first,
            EvidenceMetadataContract.NormalizeAndValidate(first));
    }

    [TestMethod]
    public void MissingArtifactHasExplicitNullContentAndExternalStorage()
    {
        var metadata = EvidenceMetadataContract.Create(
            CreateCaptureRequest(),
            EvidenceArtifactAvailability.Missing,
            contentLength: null,
            contentSha256: null,
            managedRelativePath: null);

        Assert.AreEqual(EvidenceArtifactAvailability.Missing, metadata.Availability);
        Assert.AreEqual(EvidenceArtifactStorageKind.ExternalReference, metadata.StorageKind);
        Assert.IsNull(metadata.ContentLength);
        Assert.IsNull(metadata.ContentSha256);
        Assert.IsNull(metadata.ManagedRelativePath);
    }

    [TestMethod]
    public void EvidenceMetadataRejectsTamperedCanonicalHash()
    {
        var metadata = EvidenceMetadataContract.Create(
            CreateCaptureRequest(),
            EvidenceArtifactAvailability.Present,
            5,
            new string('A', 64),
            "objects/AA/AA/first.evidence");

        Assert.Throws<EvidenceContractException>(() =>
            EvidenceMetadataContract.NormalizeAndValidate(
                metadata with { TaskId = "TASK-OTHER" }));
    }

    [TestMethod]
    public void ManagedEvidencePathRejectsControlAndReservedCharacters()
    {
        Assert.Throws<EvidenceContractException>(() =>
            EvidenceMetadataContract.Create(
                CreateCaptureRequest(),
                EvidenceArtifactAvailability.Present,
                5,
                new string('A', 64),
                "objects/AA/unsafe\nname.evidence"));
        Assert.Throws<EvidenceContractException>(() =>
            EvidenceMetadataContract.Create(
                CreateCaptureRequest(),
                EvidenceArtifactAvailability.Present,
                5,
                new string('A', 64),
                "objects/AA/unsafe?.evidence"));
    }

    [TestMethod]
    public void ReviewAuditNormalizesEvidenceOrderAndChainsHashes()
    {
        var secondEvidence = new string('B', 64);
        var firstEvidence = new string('A', 64);
        var opened = ReviewAuditContract.Create(
            CreateReviewRequest(
                Guid.Parse("11111111-1111-1111-1111-111111111111"),
                ReviewAuditActionKind.Opened,
                ReviewAuditState.Open,
                new[] { secondEvidence, firstEvidence }),
            sequence: 1,
            previousAuditSha256: null);
        var closed = ReviewAuditContract.Create(
            CreateReviewRequest(
                Guid.Parse("22222222-2222-2222-2222-222222222222"),
                ReviewAuditActionKind.Closed,
                ReviewAuditState.Closed,
                new[] { firstEvidence }),
            sequence: 2,
            previousAuditSha256: opened.AuditSha256);

        CollectionAssert.AreEqual(
            new[] { firstEvidence, secondEvidence },
            opened.EvidenceIdentitySha256s.ToArray());
        Assert.AreEqual(opened.AuditSha256, closed.PreviousAuditSha256);
        Assert.AreNotEqual(opened.AuditSha256, closed.AuditSha256);
        var validated = ReviewAuditContract.NormalizeAndValidate(closed);
        Assert.AreEqual(closed.AuditSha256, validated.AuditSha256);
        Assert.AreEqual(closed.EvidenceSetSha256, validated.EvidenceSetSha256);
        CollectionAssert.AreEqual(
            closed.EvidenceIdentitySha256s.ToArray(),
            validated.EvidenceIdentitySha256s.ToArray());
    }

    [TestMethod]
    public void ReviewAuditRejectsDuplicateEvidenceIdentity()
    {
        var identity = new string('A', 64);
        Assert.Throws<EvidenceContractException>(() =>
            ReviewAuditContract.Create(
                CreateReviewRequest(
                    Guid.Parse("33333333-3333-3333-3333-333333333333"),
                    ReviewAuditActionKind.Opened,
                    ReviewAuditState.Open,
                    new[] { identity, identity }),
                sequence: 1,
                previousAuditSha256: null));
    }

    private static EvidenceCaptureRequest CreateCaptureRequest() =>
        new(
            EvidenceMetadataContract.ContractVersion,
            "TASK-25",
            "agent-worker-01",
            "EVENT-25-01",
            "unit-test",
            "redacted://evidence/source.bin",
            ObservedUtc,
            ObservedUtc.AddMinutes(1),
            ObservedUtc.AddDays(30),
            CreateManagedCopy: true);

    private static ReviewAuditAppendRequest CreateReviewRequest(
        Guid eventId,
        ReviewAuditActionKind action,
        ReviewAuditState state,
        IReadOnlyList<string> evidenceIdentities) =>
        new(
            ReviewAuditContract.ContractVersion,
            eventId,
            "REVIEW-25",
            "reviewer-01",
            "Independent Reviewer",
            action,
            state,
            "Canonical review audit test.",
            action == ReviewAuditActionKind.Opened
                ? ObservedUtc.AddMinutes(2)
                : ObservedUtc.AddMinutes(3),
            evidenceIdentities);
}
