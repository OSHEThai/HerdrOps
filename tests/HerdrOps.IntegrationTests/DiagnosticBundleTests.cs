using System.Text;
using System.Text.Json;
using HerdrOps.Domain.Diagnostics;
using HerdrOps.Infrastructure.Diagnostics;

namespace HerdrOps.IntegrationTests;

[TestClass]
[DoNotParallelize]
public sealed class DiagnosticBundleTests
{
    [TestMethod]
    public void BuildRedactsConfiguredCommonAndNestedCredentialFormsFromEveryArtifact()
    {
        const string configuredSecret = "RawSecret/42?";
        const string overlappingShortSecret = "Overlap";
        const string overlappingLongSecret = "OverlapSecret";
        var percentSecret = Uri.EscapeDataString(configuredSecret);
        var base64Secret = Convert.ToBase64String(Encoding.UTF8.GetBytes(configuredSecret));
        const string githubToken = "ghp_1234567890ABCDEFGHIJKLMNOPQRSTUVWXYZ";
        var metadata = new Dictionary<string, object?>(StringComparer.Ordinal)
        {
            ["nested"] = new Dictionary<string, object?>(StringComparer.Ordinal)
            {
                ["apiKey"] = configuredSecret,
                ["values"] = new object?[] { percentSecret, base64Secret, githubToken },
            },
            ["Authorization"] = "Bearer should-not-survive",
        };
        var request = new DiagnosticBundleRequest(
            "0.7.0",
            "HerdrOps.Core/0.7.0",
            Utc(12, 34, 56),
            [
                new(
                    DiagnosticBundleEntryKind.LogExcerpt,
                    "application-log",
                    $"API_KEY={configuredSecret}; password=\"{overlappingLongSecret}\"; token={overlappingShortSecret}; github={githubToken}"),
                new(
                    DiagnosticBundleEntryKind.EnvironmentExcerpt,
                    "selected-environment",
                    $"HERDR_SOCKET_PATH=C:\\Users\\Alice\\AppData\\Roaming\\herdr\\herdr.sock; SECRET={percentSecret}"),
                new(
                    DiagnosticBundleEntryKind.CommandLine,
                    "core-command",
                    $"HerdrOps.Core.exe --token {configuredSecret} --password=pass-value --socket-path C:\\temp\\herdr.sock"),
                new(
                    DiagnosticBundleEntryKind.Url,
                    "endpoint",
                    $"https://user:password@example.test/api?access_token={base64Secret}&next=1"),
                new(
                    DiagnosticBundleEntryKind.Headers,
                    "request-headers",
                    $"Authorization: Bearer {configuredSecret}\nCookie: session={githubToken}\nX-Api-Key: {percentSecret}"),
                new(DiagnosticBundleEntryKind.Metadata, "structured-metadata", Metadata: metadata),
            ],
            [
                new(
                    Utc(12, 35, 1),
                    "System.InvalidOperationException",
                    DiagnosticCrashCategory.Background,
                    $"crash secret={configuredSecret} and token={githubToken}",
                    $"at HerdrOps.Core.Run() password={overlappingLongSecret}\nC:\\Users\\Alice\\source.cs:42",
                    "0.7.0",
                    "HerdrOps.Core/0.7.0"),
            ]);

        var builder = new DiagnosticBundleBuilder(
            new DiagnosticRedactionOptions(
                [configuredSecret, overlappingShortSecret, overlappingLongSecret, "should-not-survive"]));
        var package = builder.Build(request);

        Assert.HasCount(3, package.Artifacts);
        Assert.AreEqual(6, package.EntryCount);
        Assert.AreEqual(1, package.CrashCount);
        Assert.IsGreaterThan(0, package.ManifestSha256.Length);
        foreach (var artifact in package.Artifacts)
        {
            var text = Encoding.UTF8.GetString(artifact.Content);
            Assert.IsFalse(text.Contains(configuredSecret, StringComparison.Ordinal), artifact.FileName);
            Assert.IsFalse(text.Contains(percentSecret, StringComparison.Ordinal), artifact.FileName);
            Assert.IsFalse(text.Contains(base64Secret, StringComparison.Ordinal), artifact.FileName);
            Assert.IsFalse(text.Contains(overlappingShortSecret, StringComparison.Ordinal), artifact.FileName);
            Assert.IsFalse(text.Contains(overlappingLongSecret, StringComparison.Ordinal), artifact.FileName);
            Assert.IsFalse(text.Contains(githubToken, StringComparison.Ordinal), artifact.FileName);
            Assert.IsFalse(text.Contains("C:\\Users\\Alice", StringComparison.Ordinal), artifact.FileName);
            Assert.IsFalse(text.Contains("herdr.sock", StringComparison.Ordinal), artifact.FileName);
        }

        var payload = Parse(package, DiagnosticBundleSchema.PayloadFileName);
        CollectionAssert.AreEquivalent(
            new[] { "schemaVersion", "capturedAtUtc", "appVersion", "processVersion", "entries", "crashCount" },
            payload.RootElement.EnumerateObject().Select(property => property.Name).ToArray());
        Assert.AreEqual(1, payload.RootElement.GetProperty("crashCount").GetInt32());
        StringAssert.Contains(
            Encoding.UTF8.GetString(GetArtifact(package, DiagnosticBundleSchema.PayloadFileName).Content),
            DiagnosticTextRedactor.Replacement);

        var crashes = Parse(package, DiagnosticBundleSchema.CrashMetadataFileName);
        CollectionAssert.AreEquivalent(
            new[] { "schemaVersion", "crashes" },
            crashes.RootElement.EnumerateObject().Select(property => property.Name).ToArray());
        CollectionAssert.AreEquivalent(
            new[] { "timestampUtc", "exceptionType", "category", "message", "stackSummary", "appVersion", "processVersion" },
            crashes.RootElement.GetProperty("crashes")[0]
                .EnumerateObject()
                .Select(property => property.Name)
                .ToArray());
        Assert.AreEqual("background", crashes.RootElement.GetProperty("crashes")[0].GetProperty("category").GetString());
    }

    [TestMethod]
    public void ConfiguredPercentAndBase64VariantsRedactOverlappingSecretsDeterministically()
    {
        const string shortSecret = "abc123";
        const string longSecret = "abc123-long-value";
        const string punctuationSecret = "a+b/c?d";
        var base64 = Convert.ToBase64String(Encoding.UTF8.GetBytes(punctuationSecret));
        var percent = Uri.EscapeDataString(punctuationSecret);
        var redactor = new DiagnosticTextRedactor(
            new DiagnosticRedactionOptions([shortSecret, longSecret, punctuationSecret]));

        var result = redactor.Redact(
            $"short={shortSecret}; long={longSecret}; encoded={percent}; base64={base64}; repeat={longSecret}");

        Assert.IsGreaterThanOrEqualTo(5, result.ReplacementCount);
        Assert.IsFalse(result.Text.Contains(shortSecret, StringComparison.Ordinal));
        Assert.IsFalse(result.Text.Contains(longSecret, StringComparison.Ordinal));
        Assert.IsFalse(result.Text.Contains(percent, StringComparison.Ordinal));
        Assert.IsFalse(result.Text.Contains(base64, StringComparison.Ordinal));
        Assert.IsFalse(result.Text.Contains(punctuationSecret, StringComparison.Ordinal));
    }

    [TestMethod]
    public void RedactorClosesProseHeaderBearerJwtAndPemSecretsWithoutPartialLeaks()
    {
        const string apiSecret = "api-prose-secret";
        const string password = "password-prose-secret";
        const string bearer = "bearer-prose-secret";
        const string configuredPath = @"C:\Temp\Diagnostic Secrets\private key.pem";
        const string jwt = "eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.signature-value";
        const string pem = "-----BEGIN PRIVATE KEY-----\nprivate-key-material\n-----END PRIVATE KEY-----";
        var redactor = new DiagnosticTextRedactor(
            new DiagnosticRedactionOptions([apiSecret, password, bearer, configuredPath]));

        var result = redactor.Redact(
            $"API key is {apiSecret}; password is {password}; Authorization: Bearer {bearer}; " +
            $"Bearer {bearer}; JWT={jwt}; PEM={pem}; configured-path={configuredPath}; " +
            "path=C:\\Temp\\diagnostic-secret.txt");

        Assert.IsFalse(result.Text.Contains(apiSecret, StringComparison.Ordinal));
        Assert.IsFalse(result.Text.Contains(password, StringComparison.Ordinal));
        Assert.IsFalse(result.Text.Contains(bearer, StringComparison.Ordinal));
        Assert.IsFalse(result.Text.Contains(jwt, StringComparison.Ordinal));
        Assert.IsFalse(result.Text.Contains("private-key-material", StringComparison.Ordinal));
        Assert.IsFalse(result.Text.Contains("BEGIN PRIVATE KEY", StringComparison.Ordinal));
        Assert.IsFalse(result.Text.Contains("private key.pem", StringComparison.Ordinal));
        Assert.IsFalse(result.Text.Contains("C:\\Temp\\diagnostic-secret.txt", StringComparison.Ordinal));
        StringAssert.Contains(result.Text, DiagnosticTextRedactor.Replacement);
    }

    [TestMethod]
    public void RedactorClosesAdversarialCredentialLabelsAndSpacedWindowsPathsWithoutFragments()
    {
        const string secret = "api-secret";
        const string userPath = @"C:\Users\Alice Smith\source.cs:42";
        const string quotedPath = @"C:\Program Files\HerdrOps\build output\app.dll:7:11";
        var redactor = new DiagnosticTextRedactor(new DiagnosticRedactionOptions([secret]));

        var result = redactor.Redact(
            $"API key: {secret}; API   key = '{secret}'; api-key {secret}; " +
            $"user={userPath}; quoted=\"{quotedPath}\"");

        foreach (var fragment in new[]
        {
            secret,
            "API key: api-secret",
            "Alice Smith",
            "source.cs:42",
            "Program Files",
            "build output",
            "app.dll:7:11",
        })
        {
            Assert.IsFalse(result.Text.Contains(fragment, StringComparison.Ordinal), fragment);
        }

        Assert.IsGreaterThanOrEqualTo(5, result.ReplacementCount);
        StringAssert.Contains(result.Text, DiagnosticTextRedactor.Replacement);
    }

    [TestMethod]
    public void RedactorClosesPunctuatedUncAndExtendedWindowsPathsWithoutResidualFragments()
    {
        var paths = new[]
        {
            @"C:\Users\O'Brien,; Smith\source file.cs:42:17",
            @"\\server\share\O'Brien,; Smith\source file.cs:42",
            @"//server/share/O'Brien,; Smith/source file.cs:42",
            @"\\?\C:\Program Files\O'Brien,; Smith\source file.cs:42:17",
            @"\\?\UNC\server\share\O'Brien,; Smith\source file.cs:42",
        };
        var redactor = new DiagnosticTextRedactor();

        foreach (var path in paths)
        {
            var result = redactor.Redact($"diagnostic-path=\"{path}\"");

            Assert.IsFalse(result.Text.Contains(path, StringComparison.Ordinal), path);
            Assert.IsFalse(result.Text.Contains("O'Brien", StringComparison.Ordinal), path);
            Assert.IsFalse(result.Text.Contains("source file.cs", StringComparison.Ordinal), path);
            Assert.IsFalse(result.Text.Contains("42:17", StringComparison.Ordinal), path);
            Assert.IsFalse(result.Text.Contains("\\?\\", StringComparison.Ordinal), path);
            Assert.IsGreaterThan(0, result.ReplacementCount, path);

            var unquoted = redactor.Redact($"diagnostic-path={path}\n");
            Assert.IsFalse(unquoted.Text.Contains(path, StringComparison.Ordinal), path);
            Assert.IsFalse(unquoted.Text.Contains("O'Brien", StringComparison.Ordinal), path);
            Assert.IsFalse(unquoted.Text.Contains("source file.cs", StringComparison.Ordinal), path);
        }

        var singleQuoted = redactor.Redact(
            @"diagnostic-path='\\?\UNC\server\share\Program Files\output,; file.dll:7:11'");
        Assert.IsFalse(singleQuoted.Text.Contains("Program Files", StringComparison.Ordinal));
        Assert.IsFalse(singleQuoted.Text.Contains("output,; file.dll:7:11", StringComparison.Ordinal));
    }

    [TestMethod]
    public void RedactorClosesSingleQuotedWindowsPathsWithoutSwallowingNearbyQuotedProse()
    {
        var paths = new[]
        {
            @"C:\Users\O'Brien,; Smith\source file.cs:42:17",
            @"\\server\share\O'Brien,; Smith\source file.cs:42",
            @"\\?\C:\Program Files\O'Brien,; Smith\source file.cs:42:17",
            @"\\?\UNC\server\share\O'Brien,; Smith\source file.cs:42",
        };
        var redactor = new DiagnosticTextRedactor();

        foreach (var path in paths)
        {
            var input =
                $"before='unrelated quoted prose' diagnostic-path='{path}' after='keep this unrelated prose'";
            var result = redactor.Redact(input);

            Assert.IsFalse(result.Text.Contains(path, StringComparison.Ordinal), path);
            Assert.IsFalse(result.Text.Contains("O'Brien", StringComparison.Ordinal), path);
            Assert.IsFalse(result.Text.Contains("source file.cs", StringComparison.Ordinal), path);
            Assert.IsFalse(result.Text.Contains("42:17", StringComparison.Ordinal), path);
            Assert.IsTrue(result.Text.Contains("before='unrelated quoted prose'", StringComparison.Ordinal), path);
            Assert.IsTrue(result.Text.Contains("after='keep this unrelated prose'", StringComparison.Ordinal), path);
            Assert.AreEqual(1, result.ReplacementCount, path);

            var doubleQuoted = redactor.Redact(
                $"diagnostic-path=\"{path}\" after=\"keep this unrelated prose\"");
            Assert.IsFalse(doubleQuoted.Text.Contains(path, StringComparison.Ordinal), path);
            Assert.IsTrue(doubleQuoted.Text.Contains("after=\"keep this unrelated prose\"", StringComparison.Ordinal), path);

            var unquoted = redactor.Redact(
                $"diagnostic-path={path}\nquote='keep this unrelated prose'");
            Assert.IsFalse(unquoted.Text.Contains(path, StringComparison.Ordinal), path);
            Assert.IsTrue(unquoted.Text.Contains("quote='keep this unrelated prose'", StringComparison.Ordinal), path);
        }
    }

    [TestMethod]
    public void RedactorWindowsPathScannerHandlesRepeatedAdversarialLinesWithinBound()
    {
        const string path = @"\\?\UNC\server\share\O'Brien,; folder with spaces\source file.cs:12:34";
        var input = string.Join(
            "\n",
            Enumerable.Range(0, 384).Select(index => $"line={index:D3}; path=\"{path}\""));
        var redactor = new DiagnosticTextRedactor();

        var result = redactor.Redact(input);

        Assert.AreEqual(384, result.ReplacementCount);
        Assert.IsFalse(result.Text.Contains("O'Brien", StringComparison.Ordinal));
        Assert.IsFalse(result.Text.Contains("source file.cs:12:34", StringComparison.Ordinal));
        Assert.IsFalse(result.Text.Contains("\\?\\UNC", StringComparison.Ordinal));
        Assert.IsTrue(result.WasTruncated);
    }

    [TestMethod]
    public void ConfiguredSecretRedactionUsesOneBoundedPassForRepeatedInput()
    {
        const string secret = "repeated-configured-secret-42";
        var redactor = new DiagnosticTextRedactor(new DiagnosticRedactionOptions([secret]));
        var input = string.Join('|', Enumerable.Repeat(secret, 400));

        var result = redactor.Redact(input);

        Assert.AreEqual(400, result.ReplacementCount);
        Assert.IsFalse(result.Text.Contains(secret, StringComparison.Ordinal));
        Assert.IsFalse(result.WasTruncated);
    }

    [TestMethod]
    public void ConfiguredSecretPatternWorkBoundFailsBeforeProcessingInput()
    {
        var secrets = Enumerable.Range(0, 64)
            .Select(index => $"{index:D2}-" + new string((char)('A' + index % 26), 4093))
            .ToArray();

        Assert.ThrowsExactly<ArgumentOutOfRangeException>(() =>
            new DiagnosticTextRedactor(new DiagnosticRedactionOptions(secrets)));
    }

    [TestMethod]
    public void CanonicalBytesAndHashesDoNotDependOnInputOrderOrDictionaryInsertionOrder()
    {
        var first = CreateDeterminismRequest(reverse: false);
        var second = CreateDeterminismRequest(reverse: true);
        var builder = new DiagnosticBundleBuilder();

        var firstPackage = builder.Build(first);
        var secondPackage = builder.Build(second);

        Assert.AreEqual(firstPackage.ManifestSha256, secondPackage.ManifestSha256);
        Assert.AreEqual(firstPackage.TotalBytes, secondPackage.TotalBytes);
        foreach (var firstArtifact in firstPackage.Artifacts)
        {
            var secondArtifact = secondPackage.Artifacts.Single(artifact => artifact.FileName == firstArtifact.FileName);
            Assert.AreEqual(firstArtifact.Sha256, secondArtifact.Sha256, firstArtifact.FileName);
            Assert.IsTrue(firstArtifact.Content.AsSpan().SequenceEqual(secondArtifact.Content), firstArtifact.FileName);
        }
    }

    [TestMethod]
    public void BoundsRejectEntryCountMetadataDepthAndOversizedCanonicalArtifacts()
    {
        var request = new DiagnosticBundleRequest(
            "0.7.0",
            "0.7.0",
            Utc(1, 2, 3),
            [
                new(DiagnosticBundleEntryKind.Metadata, "one", Metadata: new Dictionary<string, object?>()),
                new(DiagnosticBundleEntryKind.Metadata, "two", Metadata: new Dictionary<string, object?>()),
            ]);
        var countLimitedBuilder = new DiagnosticBundleBuilder(
            limits: new DiagnosticBundleLimits { MaximumEntries = 1 });
        Assert.ThrowsExactly<ArgumentOutOfRangeException>(() => countLimitedBuilder.Build(request));

        var deepMetadata = new Dictionary<string, object?>(StringComparer.Ordinal)
        {
            ["level1"] = new Dictionary<string, object?>(StringComparer.Ordinal)
            {
                ["level2"] = new Dictionary<string, object?>(StringComparer.Ordinal)
                {
                    ["level3"] = "value",
                },
            },
        };
        var depthLimitedBuilder = new DiagnosticBundleBuilder(
            limits: new DiagnosticBundleLimits { MaximumMetadataDepth = 1 });
        Assert.ThrowsExactly<ArgumentOutOfRangeException>(() => depthLimitedBuilder.Build(
            request with
            {
                Entries = [new(DiagnosticBundleEntryKind.Metadata, "deep", Metadata: deepMetadata)],
            }));

        Assert.ThrowsExactly<ArgumentException>(() => new DiagnosticBundleBuilder().Build(
            request with
            {
                Entries =
                [
                    new(
                        DiagnosticBundleEntryKind.Metadata,
                        "prohibited",
                        Metadata: new Dictionary<string, object?>
                        {
                            ["rawEnvironment"] = "must not be serialized",
                        }),
                ],
            }));

        var sizeLimitedBuilder = new DiagnosticBundleBuilder(
            new DiagnosticRedactionOptions { MaximumInputUtf8Bytes = 4096, MaximumStringUtf8Bytes = 4096 },
            new DiagnosticBundleLimits
            {
                MaximumPayloadBytes = 2048,
                MaximumCrashMetadataBytes = 1024,
                MaximumBundleBytes = 4096,
            });
        Assert.ThrowsExactly<InvalidOperationException>(() => sizeLimitedBuilder.Build(
            request with
            {
                Entries = [new(DiagnosticBundleEntryKind.LogExcerpt, "large", new string('x', 3000))],
            }));
    }

    [TestMethod]
    public void PublisherUsesSafePathAtomicNoOverwriteAndOnlyContractArtifacts()
    {
        using var fixture = TemporaryDirectory.Create();
        var outputRoot = Directory.CreateDirectory(Path.Combine(fixture.Path, "diagnostics"));
        var request = CreateDeterminismRequest(reverse: false);
        var builder = new DiagnosticBundleBuilder();
        var publisher = new DiagnosticBundlePublisher(builder);

        Assert.ThrowsExactly<ArgumentException>(() => publisher.Publish(
            request,
            new DiagnosticBundlePublishOptions(outputRoot.FullName, "../escape")));
        Assert.ThrowsExactly<ArgumentException>(() => publisher.Publish(
            request,
            new DiagnosticBundlePublishOptions("relative-output", "bundle-000")));
        Assert.ThrowsExactly<ArgumentException>(() => publisher.Publish(
            request,
            new DiagnosticBundlePublishOptions(outputRoot.FullName, "nested\\escape")));

        var package = builder.Build(request);
        var published = publisher.Publish(
            request,
            new DiagnosticBundlePublishOptions(outputRoot.FullName, "bundle-001"));
        Assert.IsTrue(Directory.Exists(published.BundleDirectoryPath));
        CollectionAssert.AreEquivalent(
            new[] { "manifest.json", "payload.json", "crash-metadata.json" },
            Directory.GetFiles(published.BundleDirectoryPath).Select(Path.GetFileName).ToArray());
        foreach (var artifact in package.Artifacts)
        {
            var path = Path.Combine(published.BundleDirectoryPath, artifact.FileName);
            Assert.IsTrue(File.ReadAllBytes(path).AsSpan().SequenceEqual(artifact.Content), artifact.FileName);
        }

        Assert.ThrowsExactly<IOException>(() => publisher.Publish(
            request,
            new DiagnosticBundlePublishOptions(outputRoot.FullName, "bundle-001")));
    }

    [TestMethod]
    public void PublisherRejectsReparsePointOutputRoot()
    {
        if (!OperatingSystem.IsWindows())
        {
            Assert.Inconclusive("The release target is Windows.");
        }

        using var fixture = TemporaryDirectory.Create();
        var realRoot = Directory.CreateDirectory(Path.Combine(fixture.Path, "real-root"));
        var linkedRoot = Path.Combine(fixture.Path, "linked-root");
        try
        {
            _ = Directory.CreateSymbolicLink(linkedRoot, realRoot.FullName);
        }
        catch (Exception exception) when (exception is UnauthorizedAccessException or IOException)
        {
            Assert.Inconclusive($"Symbolic-link creation is unavailable on this Windows host: {exception.GetType().Name}");
        }

        var publisher = new DiagnosticBundlePublisher();
        Assert.ThrowsExactly<UnauthorizedAccessException>(() => publisher.Publish(
            CreateDeterminismRequest(reverse: false),
            new DiagnosticBundlePublishOptions(linkedRoot, "bundle-002")));
        Assert.IsFalse(Directory.Exists(Path.Combine(realRoot.FullName, "bundle-002")));
    }

    private static DiagnosticBundleRequest CreateDeterminismRequest(bool reverse)
    {
        var firstMetadata = new Dictionary<string, object?>(StringComparer.Ordinal)
        {
            ["zeta"] = "last",
            ["alpha"] = 1,
            ["nested"] = new Dictionary<string, object?>(StringComparer.Ordinal)
            {
                ["second"] = true,
                ["first"] = "value",
            },
        };
        var secondMetadata = new Dictionary<string, object?>(StringComparer.Ordinal)
        {
            ["nested"] = new Dictionary<string, object?>(StringComparer.Ordinal)
            {
                ["first"] = "value",
                ["second"] = true,
            },
            ["alpha"] = 1,
            ["zeta"] = "last",
        };
        var entries = new[]
        {
            new DiagnosticBundleEntry(DiagnosticBundleEntryKind.Metadata, "b", Metadata: firstMetadata),
            new DiagnosticBundleEntry(DiagnosticBundleEntryKind.LogExcerpt, "a", "same text"),
            new DiagnosticBundleEntry(DiagnosticBundleEntryKind.Metadata, "a", Metadata: secondMetadata),
        };
        var crashes = new[]
        {
            new CrashMetadata(Utc(4, 5, 6), "System.Exception", DiagnosticCrashCategory.Unhandled, "message", "stack", "0.7", "core"),
            new CrashMetadata(Utc(3, 5, 6), "System.Exception", DiagnosticCrashCategory.Background, "message2", "stack2", "0.7", "core"),
        };
        return new DiagnosticBundleRequest(
            "0.7.0",
            "HerdrOps.Core/0.7.0",
            Utc(2, 3, 4),
            reverse ? entries.Reverse().ToArray() : entries,
            reverse ? crashes.Reverse().ToArray() : crashes);
    }

    private static JsonDocument Parse(DiagnosticBundlePackage package, string fileName) =>
        JsonDocument.Parse(GetArtifact(package, fileName).Content);

    private static DiagnosticBundleArtifact GetArtifact(DiagnosticBundlePackage package, string fileName) =>
        package.Artifacts.Single(artifact => artifact.FileName == fileName);

    private static DateTimeOffset Utc(int hour, int minute, int second) =>
        new(2026, 8, 17, hour, minute, second, TimeSpan.Zero);

    private sealed class TemporaryDirectory : IDisposable
    {
        private TemporaryDirectory(string path)
        {
            Path = path;
        }

        public string Path { get; }

        public static TemporaryDirectory Create()
        {
            var path = System.IO.Path.Combine(
                System.IO.Path.GetTempPath(),
                "HerdrOps-Issue37",
                Guid.NewGuid().ToString("N"));
            Directory.CreateDirectory(path);
            return new TemporaryDirectory(path);
        }

        public void Dispose()
        {
            if (Directory.Exists(Path))
            {
                Directory.Delete(Path, recursive: true);
            }
        }
    }
}
