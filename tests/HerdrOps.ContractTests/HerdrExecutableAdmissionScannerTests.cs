using System.IO;
using System.Security.Cryptography;
using System.Text;
using HerdrOps.Contracts;
using HerdrOps.Infrastructure.Herdr;

namespace HerdrOps.ContractTests;

[TestClass]
public sealed class HerdrExecutableAdmissionScannerTests
{
    [TestMethod]
    public void StreamingScanFindsMarkersAndSchemaAcrossReadBoundaries()
    {
        const int readBufferBytes = 81920;
        const string protocolMarker = "protocol-marker-crosses-a-read-boundary";
        var root = Path.Combine(
            Path.GetTempPath(),
            $"herdrops-admission-{Guid.NewGuid():N}");
        var releaseDirectory = Path.Combine(root, "test-release");
        Directory.CreateDirectory(releaseDirectory);
        try
        {
            var executablePath = Path.Combine(releaseDirectory, "herdr.exe");
            var executable = new byte[(readBufferBytes * 2) + 512];
            executable[0] = (byte)'M';
            executable[1] = (byte)'Z';
            var schema = Encoding.UTF8.GetBytes(
                "{\n  \"$schema\":\"https://example.test/schema\",\"value\":{\"nested\":true}}");
            var schemaOffset = readBufferBytes - 7;
            schema.CopyTo(executable, schemaOffset);
            var markerBytes = Encoding.ASCII.GetBytes(protocolMarker);
            var markerOffset = (readBufferBytes * 2) - 5;
            markerBytes.CopyTo(executable, markerOffset);
            File.WriteAllBytes(executablePath, executable);
            var policy = new HerdrProtocolSupportPolicy(
                "test-streaming-admission",
                1,
                [new HerdrBinaryIdentity(
                    "test-release",
                    Convert.ToHexString(SHA256.HashData(executable)))],
                [protocolMarker],
                [],
                []);

            var snapshot = new HerdrExecutableAdmissionScanner().Scan(
                executablePath,
                policy,
                captureBundledSchema: true);

            Assert.IsTrue(snapshot.HasMzHeader);
            Assert.AreEqual(executable.Length, snapshot.Length);
            Assert.AreEqual(
                Convert.ToHexString(SHA256.HashData(executable)),
                snapshot.Sha256);
            Assert.Contains(protocolMarker, snapshot.FoundAsciiMarkers);
            Assert.HasCount(1, snapshot.SchemaStartOffsets);
            Assert.AreEqual(schemaOffset, snapshot.SchemaStartOffsets[0]);
            Assert.AreEqual(
                HerdrBundledSchemaCaptureStatus.Complete,
                snapshot.SchemaCaptureStatus);
            CollectionAssert.AreEqual(schema, snapshot.SchemaDocumentBytes);
        }
        finally
        {
            Directory.Delete(root, recursive: true);
        }
    }

    [TestMethod]
    public void DuplicateSchemaMarkerProvenanceIsBoundedToTwoOffsets()
    {
        var root = Path.Combine(
            Path.GetTempPath(),
            $"herdrops-admission-duplicates-{Guid.NewGuid():N}");
        var releaseDirectory = Path.Combine(root, "duplicate-release");
        Directory.CreateDirectory(releaseDirectory);
        try
        {
            var executablePath = Path.Combine(releaseDirectory, "herdr.exe");
            var schema = Encoding.UTF8.GetBytes("{\n  \"$schema\":\"duplicate\"}");
            var executable = new byte[(schema.Length + 1) * 10_000 + 2];
            executable[0] = (byte)'M';
            executable[1] = (byte)'Z';
            for (var index = 0; index < 10_000; index++)
            {
                schema.CopyTo(executable, 2 + (index * (schema.Length + 1)));
            }

            File.WriteAllBytes(executablePath, executable);
            var policy = EmptyPolicy(
                "duplicate-release",
                Convert.ToHexString(SHA256.HashData(executable)));

            var snapshot = new HerdrExecutableAdmissionScanner().Scan(
                executablePath,
                policy,
                captureBundledSchema: true);

            Assert.HasCount(2, snapshot.SchemaStartOffsets);
            Assert.AreEqual(2L, snapshot.SchemaStartOffsets[0]);
            Assert.AreEqual(2L + schema.Length + 1, snapshot.SchemaStartOffsets[1]);
        }
        finally
        {
            Directory.Delete(root, recursive: true);
        }
    }

    [TestMethod]
    public void InvalidLengthFailurePreservesBoundHandleMetadata()
    {
        var root = Path.Combine(
            Path.GetTempPath(),
            $"herdrops-admission-length-{Guid.NewGuid():N}");
        var releaseDirectory = Path.Combine(root, "short-release");
        Directory.CreateDirectory(releaseDirectory);
        try
        {
            var executablePath = Path.Combine(releaseDirectory, "herdr.exe");
            File.WriteAllBytes(executablePath, [(byte)'M']);

            var exception = Assert.ThrowsExactly<HerdrExecutableAdmissionScanException>(() =>
                new HerdrExecutableAdmissionScanner().Scan(
                    executablePath,
                    EmptyPolicy("short-release", new string('0', 64)),
                    captureBundledSchema: true));

            Assert.AreEqual(
                HerdrExecutableAdmissionScanFailure.Unreadable,
                exception.Failure);
            Assert.AreEqual("short-release", exception.ReleaseId);
            Assert.AreEqual(1L, exception.Length);
            Assert.IsFalse(string.IsNullOrWhiteSpace(exception.FinalPath));
        }
        finally
        {
            Directory.Delete(root, recursive: true);
        }
    }

    private static HerdrProtocolSupportPolicy EmptyPolicy(
        string releaseId,
        string sha256) => new(
            "test-streaming-admission",
            1,
            [new HerdrBinaryIdentity(releaseId, sha256)],
            [],
            [],
            []);
}
