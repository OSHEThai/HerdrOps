using System.Diagnostics;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using HerdrOps.Contracts;
using HerdrOps.Infrastructure.Herdr;

namespace HerdrOps.ContractTests;

[TestClass]
public sealed class HerdrBundledSchemaExtractorContractTests
{
    [TestMethod]
    public void ExactFixtureExtractsParseableContractDocumentWithoutRuntimeClaim()
    {
        var schema = SchemaDocument.Create();
        using var fixture = BundledSchemaFixture.Create(schema);

        var extraction = fixture.CreateExtractor().Extract(fixture.ExecutablePath);

        Assert.AreEqual(HerdrBundledSchemaStatus.Compatible, extraction.Inspection.Status);
        Assert.IsTrue(extraction.IsCompatible);
        Assert.AreEqual(EvidenceClass.Contract, extraction.Inspection.EvidenceClass);
        Assert.IsFalse(extraction.Inspection.RuntimeObserved);
        Assert.IsFalse(extraction.Inspection.SessionControlInvoked);
        Assert.AreEqual(schema.Length, extraction.Inspection.SchemaDocumentLength);
        Assert.AreEqual(Sha256(schema), extraction.Inspection.SchemaDocumentSha256);
        Assert.AreEqual(19, extraction.Inspection.Protocol);
        Assert.AreEqual(1, extraction.Inspection.SchemaVersion);
        Assert.IsNotNull(extraction.SchemaDocumentBytes);
        CollectionAssert.AreEqual(schema, extraction.SchemaDocumentBytes);
        Assert.HasCount(5, extraction.Inspection.SchemaGroups);
        Assert.IsEmpty(extraction.Inspection.MissingRequestMethods);
        Assert.IsEmpty(extraction.Inspection.MissingResponseTypes);
        Assert.IsEmpty(extraction.Inspection.MissingSubscriptionEventKinds);
    }

    [TestMethod]
    public void BalancedExtractionIgnoresBracesAndQuoteEscapesInsideStrings()
    {
        var title = "braces { } and quote \"" +
            " one-slash-quote " + "\\" + "\"" +
            " two-slashes-quote " + "\\\\" + "\"" +
            " ends-two-slashes " + "\\\\";
        var schema = SchemaDocument.Create(title: title);
        using var fixture = BundledSchemaFixture.Create(schema);

        var extraction = fixture.CreateExtractor().Extract(fixture.ExecutablePath);

        Assert.AreEqual(HerdrBundledSchemaStatus.Compatible, extraction.Inspection.Status);
        Assert.IsNotNull(extraction.SchemaDocumentBytes);
        CollectionAssert.AreEqual(schema, extraction.SchemaDocumentBytes);
    }

    [TestMethod]
    public void SchemaSizeBoundaryAcceptsExactLimitAndRejectsOverLimit()
    {
        const int maximumSchemaBytes = 4 * 1024 * 1024;
        var exactLimitSchema = SchemaDocument.CreateAtLength(maximumSchemaBytes);
        using (var fixture = BundledSchemaFixture.Create(exactLimitSchema))
        {
            var exactLimit = fixture.CreateExtractor().Extract(fixture.ExecutablePath);

            Assert.AreEqual(HerdrBundledSchemaStatus.Compatible, exactLimit.Inspection.Status);
            Assert.AreEqual(maximumSchemaBytes, exactLimit.Inspection.SchemaDocumentLength);
            Assert.IsNotNull(exactLimit.SchemaDocumentBytes);
        }

        AssertStatus(
            SchemaDocument.CreateAtLength(maximumSchemaBytes + 1),
            HerdrBundledSchemaStatus.SchemaTooLarge);
    }

    [TestMethod]
    public void DuplicateSchemaDocumentsFailClosedBeforeParsing()
    {
        var schema = SchemaDocument.Create();
        using var fixture = BundledSchemaFixture.Create(schema, schema);

        var extraction = fixture.CreateExtractor().Extract(fixture.ExecutablePath);

        Assert.AreEqual(HerdrBundledSchemaStatus.DuplicateSchemaStart, extraction.Inspection.Status);
        StringAssert.Contains(extraction.Inspection.Message, "found 2");
        Assert.IsFalse(extraction.Inspection.RuntimeObserved);
        Assert.IsNull(extraction.SchemaDocumentBytes);
    }

    [TestMethod]
    public void TruncatedSchemaFailsClosedBeforeJsonParsing()
    {
        var schema = SchemaDocument.Create();
        var truncated = schema[..^1];
        using var fixture = BundledSchemaFixture.Create(truncated);

        var extraction = fixture.CreateExtractor().Extract(fixture.ExecutablePath);

        Assert.AreEqual(HerdrBundledSchemaStatus.SchemaTruncated, extraction.Inspection.Status);
        StringAssert.Contains(extraction.Inspection.Message, "before its root JSON object was balanced");
        Assert.IsFalse(extraction.Inspection.RuntimeObserved);
        Assert.IsNull(extraction.SchemaDocumentBytes);
    }

    [TestMethod]
    public void BalancedMalformedJsonFailsClosed()
    {
        var validText = Encoding.UTF8.GetString(SchemaDocument.Create());
        var malformedText = validText.Replace(
            "\"title\": \"Fixture Herdr schema\"",
            "\"title\": invalid",
            StringComparison.Ordinal);
        var malformed = Encoding.UTF8.GetBytes(malformedText);
        using var fixture = BundledSchemaFixture.Create(malformed);

        var extraction = fixture.CreateExtractor().Extract(fixture.ExecutablePath);

        Assert.AreEqual(HerdrBundledSchemaStatus.MalformedJson, extraction.Inspection.Status);
        StringAssert.Contains(extraction.Inspection.Message, "malformed");
        Assert.IsFalse(extraction.Inspection.RuntimeObserved);
        Assert.IsNull(extraction.SchemaDocumentBytes);
    }

    [TestMethod]
    public void MissingStartMarkerAndInvalidUtf8HaveDistinctStatuses()
    {
        AssertStatus(
            Encoding.UTF8.GetBytes("{}"),
            HerdrBundledSchemaStatus.SchemaStartNotFound);

        var invalidUtf8 = SchemaDocument.Create();
        var titleBytes = Encoding.UTF8.GetBytes("Fixture Herdr schema");
        var titleOffset = invalidUtf8.AsSpan().IndexOf(titleBytes);
        Assert.IsGreaterThanOrEqualTo(0, titleOffset);
        invalidUtf8[titleOffset] = 0xFF;
        AssertStatus(invalidUtf8, HerdrBundledSchemaStatus.InvalidUtf8);
    }

    [TestMethod]
    public void UnsupportedDraftProtocolAndVersionHaveDistinctActionableStatuses()
    {
        AssertStatus(
            SchemaDocument.Create(draft: "https://json-schema.org/draft/2019-09/schema"),
            HerdrBundledSchemaStatus.UnsupportedDraft);
        AssertStatus(
            SchemaDocument.Create(protocol: 20),
            HerdrBundledSchemaStatus.UnsupportedProtocol);
        AssertStatus(
            SchemaDocument.Create(schemaVersion: 2),
            HerdrBundledSchemaStatus.UnsupportedSchemaVersion);
    }

    [TestMethod]
    public void MissingGroupDefinitionAndUnexpectedCountFailClosed()
    {
        AssertStatus(
            SchemaDocument.Create(includeEventGroup: false),
            HerdrBundledSchemaStatus.MissingSchemaGroup);
        AssertStatus(
            SchemaDocument.Create(includeSessionSnapshot: false),
            HerdrBundledSchemaStatus.MissingSchemaDefinition);
        AssertStatus(
            SchemaDocument.Create(addUnexpectedRequestDefinition: true),
            HerdrBundledSchemaStatus.UnexpectedDefinitionCount);
    }

    [TestMethod]
    public void MissingRuntimeSurfaceVariantsHaveDistinctStatuses()
    {
        AssertStatus(
            SchemaDocument.Create(includeSnapshotMethod: false),
            HerdrBundledSchemaStatus.MissingRequestMethod);
        AssertStatus(
            SchemaDocument.Create(includeSubscriptionStartedResponse: false),
            HerdrBundledSchemaStatus.MissingResponseType);
        AssertStatus(
            SchemaDocument.Create(includeAgentStatusSubscriptionKind: false),
            HerdrBundledSchemaStatus.MissingSubscriptionEventKind);
    }

    [TestMethod]
    public void UnexpectedLengthAndHashFailClosedAfterSemanticValidation()
    {
        var schema = SchemaDocument.Create();
        using var fixture = BundledSchemaFixture.Create(schema);

        var wrongLengthPolicy = fixture.SchemaPolicy with
        {
            ExpectedDocumentLength = fixture.SchemaPolicy.ExpectedDocumentLength + 1,
        };
        var wrongLength = new HerdrBundledSchemaExtractor(
            fixture.BinaryPolicy,
            wrongLengthPolicy).Extract(fixture.ExecutablePath);
        Assert.AreEqual(HerdrBundledSchemaStatus.UnexpectedSchemaLength, wrongLength.Inspection.Status);

        var wrongHashPolicy = fixture.SchemaPolicy with
        {
            ExpectedDocumentSha256 = new string('0', 64),
        };
        var wrongHash = new HerdrBundledSchemaExtractor(
            fixture.BinaryPolicy,
            wrongHashPolicy).Extract(fixture.ExecutablePath);
        Assert.AreEqual(HerdrBundledSchemaStatus.UnexpectedSchemaHash, wrongHash.Inspection.Status);
        StringAssert.Contains(wrongHash.Inspection.Message, "successor contract review");
    }

    [TestMethod]
    public void BinaryIdentityFailureStopsBeforeSchemaExtraction()
    {
        var schema = SchemaDocument.Create();
        using var fixture = BundledSchemaFixture.Create(schema);
        var rejectedBinaryPolicy = fixture.BinaryPolicy with
        {
            CompatibleBinaries = Array.AsReadOnly(
            [
                new HerdrBinaryIdentity(fixture.ReleaseId, new string('0', 64)),
            ]),
        };

        var extraction = new HerdrBundledSchemaExtractor(
            rejectedBinaryPolicy,
            fixture.SchemaPolicy).Extract(fixture.ExecutablePath);

        Assert.AreEqual(HerdrBundledSchemaStatus.ExecutableRejected, extraction.Inspection.Status);
        StringAssert.Contains(extraction.Inspection.Message, "UnsupportedBinaryHash");
        Assert.IsNull(extraction.Inspection.SchemaStartOffset);
        Assert.IsNull(extraction.SchemaDocumentBytes);
    }

    [TestMethod]
    public void RequestedPathRetargetBetweenReadsFailsClosed()
    {
        var schema = SchemaDocument.Create();
        using var fixture = BundledSchemaFixture.Create(schema);
        var secondReleasePath = Path.Combine(fixture.RootPath, "retargeted-release");
        Directory.CreateDirectory(secondReleasePath);
        File.Copy(
            fixture.ExecutablePath,
            Path.Combine(secondReleasePath, "herdr.exe"));
        var junctionPath = Path.Combine(fixture.RootPath, "bin");
        CreateDirectoryJunction(junctionPath, Path.GetDirectoryName(fixture.ExecutablePath)!);
        try
        {
            var requestedPath = Path.Combine(junctionPath, "herdr.exe");
            var snapshotReader = new CallbackSnapshotReader(
                () =>
                {
                    RemoveDirectoryJunction(junctionPath);
                    CreateDirectoryJunction(junctionPath, secondReleasePath);
                });

            var extraction = fixture.CreateExtractor(snapshotReader).Extract(requestedPath);

            Assert.AreEqual(HerdrBundledSchemaStatus.ExecutableRejected, extraction.Inspection.Status);
            StringAssert.Contains(extraction.Inspection.Message, "target changed");
            Assert.IsNull(extraction.SchemaDocumentBytes);
        }
        finally
        {
            RemoveDirectoryJunction(junctionPath);
        }
    }

    [TestMethod]
    public void ExecutableContentMutationBetweenReadsFailsClosed()
    {
        var schema = SchemaDocument.Create();
        using var fixture = BundledSchemaFixture.Create(schema);
        var snapshotReader = new CallbackSnapshotReader(
            () => File.AppendAllText(fixture.ExecutablePath, "changed-after-admission"));

        var extraction = fixture.CreateExtractor(snapshotReader).Extract(fixture.ExecutablePath);

        Assert.AreEqual(HerdrBundledSchemaStatus.ExecutableRejected, extraction.Inspection.Status);
        StringAssert.Contains(extraction.Inspection.Message, "bytes changed");
        Assert.IsNull(extraction.SchemaDocumentBytes);
    }

    [TestMethod]
    public void ProductionPolicyPinsExactInstalledDocumentAndRequiredSurface()
    {
        var policy = HerdrBundledSchemaContractV19.Policy;

        Assert.AreEqual("herdr-0.8.0-preview-bundled-schema-v1", policy.ContractId);
        Assert.AreEqual(1, policy.Revision);
        Assert.AreEqual("https://json-schema.org/draft/2020-12/schema", policy.JsonSchemaDraft);
        Assert.AreEqual(19, policy.Protocol);
        Assert.AreEqual(1, policy.SchemaVersion);
        Assert.AreEqual(261_498, policy.ExpectedDocumentLength);
        Assert.AreEqual(
            "9449368D54BBECD4D4D0696EFFB9E9C002ECD63A5B8A48BBD901A305AF842982",
            policy.ExpectedDocumentSha256);
        CollectionAssert.AreEqual(
            new[]
            {
                "error_response:1",
                "event:16",
                "request:105",
                "subscription_event:10",
                "success_response:67",
            },
            policy.RequiredGroups
                .Select(group => $"{group.Name}:{group.ExpectedDefinitionCount}")
                .ToArray());
        CollectionAssert.AreEqual(
            new[] { "session.snapshot", "events.subscribe" },
            policy.RequiredRequestMethods.ToArray());
        CollectionAssert.AreEqual(
            new[] { "session_snapshot", "subscription_started" },
            policy.RequiredResponseTypes.ToArray());
        CollectionAssert.AreEqual(
            new[] { "pane.agent_status_changed" },
            policy.RequiredSubscriptionEventKinds.ToArray());
    }

    private static void AssertStatus(byte[] schema, HerdrBundledSchemaStatus expected)
    {
        using var fixture = BundledSchemaFixture.Create(schema);

        var extraction = fixture.CreateExtractor().Extract(fixture.ExecutablePath);

        Assert.AreEqual(expected, extraction.Inspection.Status);
        Assert.AreEqual(EvidenceClass.Contract, extraction.Inspection.EvidenceClass);
        Assert.IsFalse(extraction.Inspection.RuntimeObserved);
        Assert.IsFalse(extraction.Inspection.SessionControlInvoked);
        Assert.IsNull(extraction.SchemaDocumentBytes);
    }

    private static string Sha256(byte[] bytes) =>
        Convert.ToHexString(SHA256.HashData(bytes));

    private static class SchemaDocument
    {
        private static readonly JsonSerializerOptions SerializerOptions = new()
        {
            WriteIndented = true,
        };

        public static byte[] Create(
            string draft = HerdrBundledSchemaContractV19.JsonSchemaDraft,
            int protocol = 19,
            int schemaVersion = 1,
            bool includeEventGroup = true,
            bool includeSessionSnapshot = true,
            bool addUnexpectedRequestDefinition = false,
            bool includeSnapshotMethod = true,
            bool includeSubscriptionStartedResponse = true,
            bool includeAgentStatusSubscriptionKind = true,
            string title = "Fixture Herdr schema",
            int paddingLength = 0)
        {
            var requestDefinitions = new JsonObject
            {
                ["EventsSubscribeParams"] = new JsonObject(),
                ["Subscription"] = new JsonObject(),
            };
            if (addUnexpectedRequestDefinition)
            {
                requestDefinitions["Unexpected"] = new JsonObject();
            }

            var requestVariants = new JsonArray();
            if (includeSnapshotMethod)
            {
                requestVariants.Add(MethodVariant("session.snapshot"));
            }

            requestVariants.Add(MethodVariant("events.subscribe"));

            var responseVariants = new JsonArray
            {
                ResponseVariant("session_snapshot"),
            };
            if (includeSubscriptionStartedResponse)
            {
                responseVariants.Add(ResponseVariant("subscription_started"));
            }

            var successDefinitions = new JsonObject
            {
                ["ResponseResult"] = new JsonObject { ["oneOf"] = responseVariants },
            };
            if (includeSessionSnapshot)
            {
                successDefinitions["SessionSnapshot"] = new JsonObject();
            }

            var subscriptionKinds = new JsonArray();
            if (includeAgentStatusSubscriptionKind)
            {
                subscriptionKinds.Add("pane.agent_status_changed");
            }

            subscriptionKinds.Add("pane.output_matched");

            var schemas = new JsonObject
            {
                ["error_response"] = Group(
                    new JsonObject { ["ErrorBody"] = new JsonObject() }),
                ["request"] = new JsonObject
                {
                    ["$defs"] = requestDefinitions,
                    ["oneOf"] = requestVariants,
                },
                ["subscription_event"] = Group(
                    new JsonObject
                    {
                        ["PaneAgentStatusChangedEvent"] = new JsonObject(),
                        ["SubscriptionEventData"] = new JsonObject(),
                        ["SubscriptionEventKind"] = new JsonObject { ["enum"] = subscriptionKinds },
                    }),
                ["success_response"] = Group(successDefinitions),
            };
            if (includeEventGroup)
            {
                schemas.Insert(
                    1,
                    "event",
                    Group(
                        new JsonObject
                        {
                            ["EventData"] = new JsonObject(),
                            ["EventKind"] = new JsonObject(),
                        }));
            }

            var root = new JsonObject
            {
                ["$schema"] = draft,
                ["protocol"] = protocol,
                ["schema_version"] = schemaVersion,
                ["schemas"] = schemas,
                ["title"] = title,
            };
            if (paddingLength > 0)
            {
                root["padding"] = new string('x', paddingLength);
            }

            return Encoding.UTF8.GetBytes(root.ToJsonString(SerializerOptions));
        }

        public static byte[] CreateAtLength(int targetLength)
        {
            var oneBytePadding = Create(paddingLength: 1);
            var fixedLength = oneBytePadding.Length - 1;
            var paddingLength = targetLength - fixedLength;
            if (paddingLength <= 0)
            {
                throw new ArgumentOutOfRangeException(nameof(targetLength));
            }

            var document = Create(paddingLength: paddingLength);
            if (document.Length != targetLength)
            {
                throw new InvalidOperationException(
                    $"Expected schema fixture length {targetLength}, observed {document.Length}.");
            }

            return document;
        }

        private static JsonObject Group(JsonObject definitions) =>
            new() { ["$defs"] = definitions };

        private static JsonObject MethodVariant(string method) =>
            new()
            {
                ["properties"] = new JsonObject
                {
                    ["method"] = new JsonObject { ["const"] = method },
                },
            };

        private static JsonObject ResponseVariant(string type) =>
            new()
            {
                ["properties"] = new JsonObject
                {
                    ["type"] = new JsonObject { ["const"] = type },
                },
            };
    }

    private sealed class BundledSchemaFixture : IDisposable
    {
        private BundledSchemaFixture(
            string rootPath,
            string releaseId,
            string executablePath,
            HerdrProtocolSupportPolicy binaryPolicy,
            HerdrBundledSchemaSupportPolicy schemaPolicy)
        {
            RootPath = rootPath;
            ReleaseId = releaseId;
            ExecutablePath = executablePath;
            BinaryPolicy = binaryPolicy;
            SchemaPolicy = schemaPolicy;
        }

        public string RootPath { get; }

        public string ReleaseId { get; }

        public string ExecutablePath { get; }

        public HerdrProtocolSupportPolicy BinaryPolicy { get; }

        public HerdrBundledSchemaSupportPolicy SchemaPolicy { get; }

        public HerdrBundledSchemaExtractor CreateExtractor(
            IHerdrExecutableSnapshotReader? snapshotReader = null) =>
            new(BinaryPolicy, SchemaPolicy, snapshotReader);

        public static BundledSchemaFixture Create(params byte[][] schemaDocuments)
        {
            Assert.IsNotEmpty(schemaDocuments);
            var releaseId = "fixture-herdr-schema-v19-x86_64-pc-windows-msvc";
            var rootPath = Path.Combine(
                Path.GetTempPath(),
                "HerdrOps.BundledSchemaContractTests",
                Guid.NewGuid().ToString("N"));
            var releasePath = Path.Combine(rootPath, releaseId);
            Directory.CreateDirectory(releasePath);
            var executablePath = Path.Combine(releasePath, "herdr.exe");

            using var stream = new MemoryStream();
            stream.Write(Encoding.ASCII.GetBytes("MZ\0"));
            var sourceBinaryPolicy = HerdrProtocolContractV080Preview.Policy;
            var binaryMarkers = sourceBinaryPolicy.RequiredRpcMethods
                .Concat(sourceBinaryPolicy.RequiredShapes.Select(shape => shape.BinaryMarker))
                .Concat(sourceBinaryPolicy.RequiredTransportMarkers);
            foreach (var marker in binaryMarkers)
            {
                stream.Write(Encoding.UTF8.GetBytes(marker));
                stream.WriteByte(0);
            }

            foreach (var schemaDocument in schemaDocuments)
            {
                stream.Write(schemaDocument);
                stream.WriteByte(0);
            }

            var executableBytes = stream.ToArray();
            File.WriteAllBytes(executablePath, executableBytes);
            var binaryPolicy = sourceBinaryPolicy with
            {
                CompatibleBinaries = Array.AsReadOnly(
                [
                    new HerdrBinaryIdentity(releaseId, Sha256(executableBytes)),
                ]),
            };
            var schema = schemaDocuments[0];
            var schemaPolicy = new HerdrBundledSchemaSupportPolicy(
                "fixture-herdr-bundled-schema-v1",
                1,
                HerdrBundledSchemaContractV19.JsonSchemaDraft,
                19,
                1,
                schema.Length,
                Sha256(schema),
                Array.AsReadOnly(
                [
                    new HerdrBundledSchemaGroupRequirement(
                        "error_response",
                        1,
                        Array.AsReadOnly(["ErrorBody"])),
                    new HerdrBundledSchemaGroupRequirement(
                        "event",
                        2,
                        Array.AsReadOnly(["EventData", "EventKind"])),
                    new HerdrBundledSchemaGroupRequirement(
                        "request",
                        2,
                        Array.AsReadOnly(["EventsSubscribeParams", "Subscription"])),
                    new HerdrBundledSchemaGroupRequirement(
                        "subscription_event",
                        3,
                        Array.AsReadOnly(
                        [
                            "PaneAgentStatusChangedEvent",
                            "SubscriptionEventData",
                            "SubscriptionEventKind",
                        ])),
                    new HerdrBundledSchemaGroupRequirement(
                        "success_response",
                        2,
                        Array.AsReadOnly(["ResponseResult", "SessionSnapshot"])),
                ]),
                Array.AsReadOnly(["session.snapshot", "events.subscribe"]),
                Array.AsReadOnly(["session_snapshot", "subscription_started"]),
                Array.AsReadOnly(["pane.agent_status_changed"]));

            return new BundledSchemaFixture(
                rootPath,
                releaseId,
                executablePath,
                binaryPolicy,
                schemaPolicy);
        }

        public void Dispose()
        {
            var resolvedRoot = Path.GetFullPath(RootPath);
            var expectedParent = Path.GetFullPath(
                Path.Combine(Path.GetTempPath(), "HerdrOps.BundledSchemaContractTests")) +
                Path.DirectorySeparatorChar;
            if (resolvedRoot.StartsWith(expectedParent, StringComparison.OrdinalIgnoreCase) &&
                Directory.Exists(resolvedRoot))
            {
                Directory.Delete(resolvedRoot, recursive: true);
            }
        }
    }

    private sealed class CallbackSnapshotReader : IHerdrExecutableSnapshotReader
    {
        private readonly Action _beforeRead;
        private readonly HerdrExecutableSnapshotReader _inner = new();

        public CallbackSnapshotReader(Action beforeRead)
        {
            _beforeRead = beforeRead;
        }

        public HerdrExecutableSnapshot Read(string requestedPath, long maximumBytes)
        {
            _beforeRead();
            return _inner.Read(requestedPath, maximumBytes);
        }
    }

    private static void CreateDirectoryJunction(string junctionPath, string targetPath)
    {
        var startInfo = new ProcessStartInfo
        {
            FileName = Environment.GetEnvironmentVariable("ComSpec") ??
                Path.Combine(Environment.SystemDirectory, "cmd.exe"),
            CreateNoWindow = true,
            RedirectStandardError = true,
            RedirectStandardOutput = true,
            UseShellExecute = false,
        };
        startInfo.ArgumentList.Add("/d");
        startInfo.ArgumentList.Add("/c");
        startInfo.ArgumentList.Add("mklink");
        startInfo.ArgumentList.Add("/J");
        startInfo.ArgumentList.Add(junctionPath);
        startInfo.ArgumentList.Add(targetPath);
        using var process = Process.Start(startInfo) ??
            throw new InvalidOperationException("Could not start mklink for the junction fixture.");
        var standardOutput = process.StandardOutput.ReadToEnd();
        var standardError = process.StandardError.ReadToEnd();
        process.WaitForExit();
        if (process.ExitCode != 0)
        {
            throw new InvalidOperationException(
                $"Could not create junction fixture: {standardOutput} {standardError}");
        }
    }

    private static void RemoveDirectoryJunction(string junctionPath)
    {
        if (Directory.Exists(junctionPath))
        {
            Directory.Delete(junctionPath, recursive: false);
        }
    }
}
