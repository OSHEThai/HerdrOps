using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using HerdrOps.Contracts;

namespace HerdrOps.Infrastructure.Herdr;

public sealed class HerdrBundledSchemaExtractor
{
    private const long MaximumExecutableBytes = 128L * 1024 * 1024;
    private const int MaximumSchemaBytes = 4 * 1024 * 1024;
    private const int MaximumJsonDepth = 256;
    private static readonly UTF8Encoding StrictUtf8 = new(false, true);
    private static readonly byte[][] SchemaStartMarkers =
    [
        Encoding.ASCII.GetBytes("{\n  \"$schema\":"),
        Encoding.ASCII.GetBytes("{\r\n  \"$schema\":"),
    ];

    private readonly HerdrProtocolInspector _binaryInspector;
    private readonly HerdrBundledSchemaSupportPolicy _schemaPolicy;
    private readonly IHerdrExecutableSnapshotReader _snapshotReader;

    public HerdrBundledSchemaExtractor(
        HerdrProtocolSupportPolicy? binaryPolicy = null,
        HerdrBundledSchemaSupportPolicy? schemaPolicy = null,
        IHerdrExecutableSnapshotReader? snapshotReader = null)
    {
        _binaryInspector = new HerdrProtocolInspector(binaryPolicy);
        _schemaPolicy = schemaPolicy ?? HerdrBundledSchemaContractV19.Policy;
        _snapshotReader = snapshotReader ?? new HerdrExecutableSnapshotReader();
    }

    public HerdrBundledSchemaExtraction Extract(string executablePath)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(executablePath);

        var binaryInspection = _binaryInspector.Inspect(executablePath);
        if (!binaryInspection.IsCompatible || string.IsNullOrWhiteSpace(binaryInspection.ResolvedExecutablePath))
        {
            return Failure(
                HerdrBundledSchemaStatus.ExecutableRejected,
                binaryInspection,
                $"Executable admission failed with {binaryInspection.Status}: {binaryInspection.Message}");
        }

        HerdrExecutableSnapshot snapshot;
        try
        {
            snapshot = _snapshotReader.Read(
                binaryInspection.RequestedExecutablePath,
                MaximumExecutableBytes);
        }
        catch (Exception exception) when (exception is IOException or UnauthorizedAccessException)
        {
            return Failure(
                HerdrBundledSchemaStatus.ExecutableRejected,
                binaryInspection,
                $"Admitted executable could not be read for schema extraction: {exception.Message}");
        }

        if (!string.Equals(
                Path.GetFullPath(snapshot.FinalPath),
                Path.GetFullPath(binaryInspection.ResolvedExecutablePath),
                StringComparison.OrdinalIgnoreCase))
        {
            return Failure(
                HerdrBundledSchemaStatus.ExecutableRejected,
                binaryInspection,
                $"Herdr executable target changed between binary admission and schema extraction: '{snapshot.FinalPath}'.");
        }

        var executableBytes = snapshot.Bytes;
        var currentExecutableSha256 = Convert.ToHexString(SHA256.HashData(executableBytes));
        if (!string.Equals(
                currentExecutableSha256,
                binaryInspection.ExecutableSha256,
                StringComparison.OrdinalIgnoreCase))
        {
            return Failure(
                HerdrBundledSchemaStatus.ExecutableRejected,
                binaryInspection,
                "Herdr executable bytes changed between binary admission and schema extraction.");
        }

        var schemaStarts = FindSchemaStarts(executableBytes);
        if (schemaStarts.Count == 0)
        {
            return Failure(
                HerdrBundledSchemaStatus.SchemaStartNotFound,
                binaryInspection,
                "The bundled JSON Schema start marker was not found in the admitted executable.");
        }

        if (schemaStarts.Count > 1)
        {
            return Failure(
                HerdrBundledSchemaStatus.DuplicateSchemaStart,
                binaryInspection,
                $"Expected one bundled JSON Schema start marker but found {schemaStarts.Count}.");
        }

        var schemaStart = schemaStarts[0];
        var extraction = ExtractBalancedObject(executableBytes, schemaStart);
        if (extraction.Status is not null)
        {
            return Failure(
                extraction.Status.Value,
                binaryInspection,
                extraction.Message,
                schemaStart);
        }

        var schemaBytes = extraction.Bytes!;
        string schemaText;
        try
        {
            schemaText = StrictUtf8.GetString(schemaBytes);
        }
        catch (DecoderFallbackException exception)
        {
            return Failure(
                HerdrBundledSchemaStatus.InvalidUtf8,
                binaryInspection,
                $"Bundled schema is not valid UTF-8: {exception.Message}",
                schemaStart,
                schemaBytes);
        }

        JsonDocument document;
        try
        {
            document = JsonDocument.Parse(
                schemaText,
                new JsonDocumentOptions
                {
                    AllowTrailingCommas = false,
                    CommentHandling = JsonCommentHandling.Disallow,
                    MaxDepth = MaximumJsonDepth,
                });
        }
        catch (JsonException exception)
        {
            return Failure(
                HerdrBundledSchemaStatus.MalformedJson,
                binaryInspection,
                $"Bundled schema JSON is malformed: {exception.Message}",
                schemaStart,
                schemaBytes);
        }

        using (document)
        {
            return ValidateDocument(binaryInspection, schemaStart, schemaBytes, document.RootElement);
        }
    }

    private HerdrBundledSchemaExtraction ValidateDocument(
        HerdrProtocolInspection binaryInspection,
        int schemaStart,
        byte[] schemaBytes,
        JsonElement root)
    {
        if (root.ValueKind != JsonValueKind.Object)
        {
            return Failure(
                HerdrBundledSchemaStatus.MalformedJson,
                binaryInspection,
                "Bundled schema root must be a JSON object.",
                schemaStart,
                schemaBytes);
        }

        var draft = GetString(root, "$schema");
        var protocol = GetInt32(root, "protocol");
        var schemaVersion = GetInt32(root, "schema_version");
        if (!string.Equals(draft, _schemaPolicy.JsonSchemaDraft, StringComparison.Ordinal))
        {
            return Failure(
                HerdrBundledSchemaStatus.UnsupportedDraft,
                binaryInspection,
                $"Bundled schema draft '{draft ?? "<missing>"}' is not admitted.",
                schemaStart,
                schemaBytes,
                draft,
                protocol,
                schemaVersion);
        }

        if (protocol != _schemaPolicy.Protocol)
        {
            return Failure(
                HerdrBundledSchemaStatus.UnsupportedProtocol,
                binaryInspection,
                $"Bundled schema protocol '{protocol?.ToString() ?? "<missing>"}' is not admitted.",
                schemaStart,
                schemaBytes,
                draft,
                protocol,
                schemaVersion);
        }

        if (schemaVersion != _schemaPolicy.SchemaVersion)
        {
            return Failure(
                HerdrBundledSchemaStatus.UnsupportedSchemaVersion,
                binaryInspection,
                $"Bundled schema version '{schemaVersion?.ToString() ?? "<missing>"}' is not admitted.",
                schemaStart,
                schemaBytes,
                draft,
                protocol,
                schemaVersion);
        }

        var groupSummaries = new List<HerdrBundledSchemaGroupSummary>();
        var missingGroups = new List<string>();
        var missingDefinitions = new List<string>();
        var countMismatches = new List<string>();
        var schemas = TryGetObject(root, "schemas");
        foreach (var requirement in _schemaPolicy.RequiredGroups)
        {
            var group = schemas is null ? null : TryGetObject(schemas.Value, requirement.Name);
            if (group is null)
            {
                missingGroups.Add(requirement.Name);
                continue;
            }

            var definitions = TryGetObject(group.Value, "$defs");
            var definitionCount = definitions?.EnumerateObject().Count() ?? 0;
            groupSummaries.Add(new HerdrBundledSchemaGroupSummary(requirement.Name, definitionCount));
            if (definitionCount != requirement.ExpectedDefinitionCount)
            {
                countMismatches.Add(
                    $"{requirement.Name}: expected {requirement.ExpectedDefinitionCount}, observed {definitionCount}");
            }

            foreach (var definition in requirement.RequiredDefinitions)
            {
                if (definitions is null || !definitions.Value.TryGetProperty(definition, out _))
                {
                    missingDefinitions.Add($"{requirement.Name}.$defs.{definition}");
                }
            }
        }

        if (missingGroups.Count > 0)
        {
            return StructuralFailure(
                HerdrBundledSchemaStatus.MissingSchemaGroup,
                "One or more required schema groups are missing.");
        }

        if (missingDefinitions.Count > 0)
        {
            return StructuralFailure(
                HerdrBundledSchemaStatus.MissingSchemaDefinition,
                "One or more required schema definitions are missing.");
        }

        if (countMismatches.Count > 0)
        {
            return StructuralFailure(
                HerdrBundledSchemaStatus.UnexpectedDefinitionCount,
                "One or more schema groups have an unexpected definition count.");
        }

        var requestMethods = CollectStringValues(
            schemas!.Value,
            "request",
            "oneOf",
            "properties",
            "method",
            "const");
        var missingRequestMethods = MissingValues(_schemaPolicy.RequiredRequestMethods, requestMethods);
        if (missingRequestMethods.Count > 0)
        {
            return StructuralFailure(
                HerdrBundledSchemaStatus.MissingRequestMethod,
                "One or more required request methods are missing.",
                missingRequestMethods: missingRequestMethods);
        }

        var responseTypes = CollectStringValues(
            schemas.Value,
            "success_response",
            "$defs",
            "ResponseResult",
            "oneOf",
            "properties",
            "type",
            "const");
        var missingResponseTypes = MissingValues(_schemaPolicy.RequiredResponseTypes, responseTypes);
        if (missingResponseTypes.Count > 0)
        {
            return StructuralFailure(
                HerdrBundledSchemaStatus.MissingResponseType,
                "One or more required success-response types are missing.",
                missingResponseTypes: missingResponseTypes);
        }

        var subscriptionKinds = CollectStringValues(
            schemas.Value,
            "subscription_event",
            "$defs",
            "SubscriptionEventKind",
            "enum");
        var missingSubscriptionKinds = MissingValues(
            _schemaPolicy.RequiredSubscriptionEventKinds,
            subscriptionKinds);
        if (missingSubscriptionKinds.Count > 0)
        {
            return StructuralFailure(
                HerdrBundledSchemaStatus.MissingSubscriptionEventKind,
                "One or more required subscription-event kinds are missing.",
                missingSubscriptionEventKinds: missingSubscriptionKinds);
        }

        var schemaSha256 = Convert.ToHexString(SHA256.HashData(schemaBytes));
        if (schemaBytes.Length != _schemaPolicy.ExpectedDocumentLength)
        {
            return StructuralFailure(
                HerdrBundledSchemaStatus.UnexpectedSchemaLength,
                $"Bundled schema length {schemaBytes.Length} does not match expected length {_schemaPolicy.ExpectedDocumentLength}.",
                schemaSha256: schemaSha256);
        }

        if (!string.Equals(
                schemaSha256,
                _schemaPolicy.ExpectedDocumentSha256,
                StringComparison.OrdinalIgnoreCase))
        {
            return StructuralFailure(
                HerdrBundledSchemaStatus.UnexpectedSchemaHash,
                "Bundled schema SHA-256 is not admitted and requires a successor contract review.",
                schemaSha256: schemaSha256);
        }

        var inspection = CreateInspection(
            HerdrBundledSchemaStatus.Compatible,
            binaryInspection,
            schemaStart,
            schemaBytes.Length,
            schemaSha256,
            draft,
            protocol,
            schemaVersion,
            groupSummaries,
            Array.Empty<string>(),
            Array.Empty<string>(),
            Array.Empty<string>(),
            Array.Empty<string>(),
            Array.Empty<string>(),
            Array.Empty<string>(),
            "The admitted Herdr executable contains the exact supported bundled JSON Schema. Runtime communication was not observed.");
        return new HerdrBundledSchemaExtraction(inspection, schemaBytes);

        HerdrBundledSchemaExtraction StructuralFailure(
            HerdrBundledSchemaStatus status,
            string message,
            IReadOnlyList<string>? missingRequestMethods = null,
            IReadOnlyList<string>? missingResponseTypes = null,
            IReadOnlyList<string>? missingSubscriptionEventKinds = null,
            string? schemaSha256 = null)
        {
            var inspection = CreateInspection(
                status,
                binaryInspection,
                schemaStart,
                schemaBytes.Length,
                schemaSha256 ?? Convert.ToHexString(SHA256.HashData(schemaBytes)),
                draft,
                protocol,
                schemaVersion,
                groupSummaries,
                missingGroups,
                missingDefinitions,
                countMismatches,
                missingRequestMethods ?? Array.Empty<string>(),
                missingResponseTypes ?? Array.Empty<string>(),
                missingSubscriptionEventKinds ?? Array.Empty<string>(),
                message);
            return new HerdrBundledSchemaExtraction(inspection, null);
        }
    }

    private HerdrBundledSchemaExtraction Failure(
        HerdrBundledSchemaStatus status,
        HerdrProtocolInspection binaryInspection,
        string message,
        long? schemaStart = null,
        byte[]? schemaBytes = null,
        string? draft = null,
        int? protocol = null,
        int? schemaVersion = null)
    {
        var inspection = CreateInspection(
            status,
            binaryInspection,
            schemaStart,
            schemaBytes?.Length,
            schemaBytes is null ? null : Convert.ToHexString(SHA256.HashData(schemaBytes)),
            draft,
            protocol,
            schemaVersion,
            Array.Empty<HerdrBundledSchemaGroupSummary>(),
            Array.Empty<string>(),
            Array.Empty<string>(),
            Array.Empty<string>(),
            Array.Empty<string>(),
            Array.Empty<string>(),
            Array.Empty<string>(),
            message);
        return new HerdrBundledSchemaExtraction(inspection, null);
    }

    private HerdrBundledSchemaInspection CreateInspection(
        HerdrBundledSchemaStatus status,
        HerdrProtocolInspection binaryInspection,
        long? schemaStart,
        int? schemaLength,
        string? schemaSha256,
        string? draft,
        int? protocol,
        int? schemaVersion,
        IReadOnlyList<HerdrBundledSchemaGroupSummary> groups,
        IReadOnlyList<string> missingGroups,
        IReadOnlyList<string> missingDefinitions,
        IReadOnlyList<string> countMismatches,
        IReadOnlyList<string> missingRequestMethods,
        IReadOnlyList<string> missingResponseTypes,
        IReadOnlyList<string> missingSubscriptionEventKinds,
        string message) =>
        new(
            status,
            EvidenceClass.Contract,
            RuntimeObserved: false,
            SessionControlInvoked: false,
            _schemaPolicy.ContractId,
            _schemaPolicy.Revision,
            binaryInspection.RequestedExecutablePath,
            binaryInspection.ResolvedExecutablePath,
            binaryInspection.ReleaseId,
            binaryInspection.ExecutableSha256,
            schemaStart,
            schemaLength,
            schemaSha256,
            draft,
            protocol,
            schemaVersion,
            groups,
            missingGroups,
            missingDefinitions,
            countMismatches,
            missingRequestMethods,
            missingResponseTypes,
            missingSubscriptionEventKinds,
            message);

    private static IReadOnlyList<int> FindSchemaStarts(byte[] executableBytes)
    {
        var starts = new SortedSet<int>();
        foreach (var marker in SchemaStartMarkers)
        {
            var offset = 0;
            while (offset <= executableBytes.Length - marker.Length)
            {
                var relativeIndex = executableBytes.AsSpan(offset).IndexOf(marker);
                if (relativeIndex < 0)
                {
                    break;
                }

                var absoluteIndex = offset + relativeIndex;
                starts.Add(absoluteIndex);
                offset = absoluteIndex + 1;
            }
        }

        return starts.ToArray();
    }

    private static BalancedExtraction ExtractBalancedObject(byte[] executableBytes, int start)
    {
        var depth = 0;
        var inString = false;
        var escaped = false;
        var maximumEnd = Math.Min(executableBytes.Length, start + MaximumSchemaBytes);
        for (var index = start; index < maximumEnd; index++)
        {
            var current = executableBytes[index];
            if (inString)
            {
                if (escaped)
                {
                    escaped = false;
                }
                else if (current == (byte)'\\')
                {
                    escaped = true;
                }
                else if (current == (byte)'\"')
                {
                    inString = false;
                }

                continue;
            }

            if (current == (byte)'\"')
            {
                inString = true;
            }
            else if (current == (byte)'{')
            {
                depth++;
            }
            else if (current == (byte)'}')
            {
                depth--;
                if (depth == 0)
                {
                    return new BalancedExtraction(
                        executableBytes.AsSpan(start, index - start + 1).ToArray(),
                        Status: null,
                        Message: string.Empty);
                }

                if (depth < 0)
                {
                    return new BalancedExtraction(
                        Bytes: null,
                        HerdrBundledSchemaStatus.MalformedJson,
                        "Bundled schema closed before its root object was balanced.");
                }
            }
        }

        var status = maximumEnd < executableBytes.Length
            ? HerdrBundledSchemaStatus.SchemaTooLarge
            : HerdrBundledSchemaStatus.SchemaTruncated;
        var message = status == HerdrBundledSchemaStatus.SchemaTooLarge
            ? $"Bundled schema exceeds the {MaximumSchemaBytes}-byte extraction limit."
            : "Bundled schema ended before its root JSON object was balanced.";
        return new BalancedExtraction(Bytes: null, status, message);
    }

    private static JsonElement? TryGetObject(JsonElement parent, string propertyName) =>
        parent.ValueKind == JsonValueKind.Object &&
        parent.TryGetProperty(propertyName, out var value) &&
        value.ValueKind == JsonValueKind.Object
            ? value
            : null;

    private static string? GetString(JsonElement parent, string propertyName) =>
        parent.TryGetProperty(propertyName, out var value) && value.ValueKind == JsonValueKind.String
            ? value.GetString()
            : null;

    private static int? GetInt32(JsonElement parent, string propertyName) =>
        parent.TryGetProperty(propertyName, out var value) &&
        value.ValueKind == JsonValueKind.Number &&
        value.TryGetInt32(out var result)
            ? result
            : null;

    private static IReadOnlySet<string> CollectStringValues(JsonElement root, params string[] path)
    {
        var values = new HashSet<string>(StringComparer.Ordinal);
        Collect(root, path, 0, values);
        return values;

        static void Collect(
            JsonElement current,
            IReadOnlyList<string> segments,
            int segmentIndex,
            ISet<string> output)
        {
            if (current.ValueKind == JsonValueKind.Array)
            {
                foreach (var item in current.EnumerateArray())
                {
                    Collect(item, segments, segmentIndex, output);
                }

                return;
            }

            if (segmentIndex == segments.Count)
            {
                if (current.ValueKind == JsonValueKind.String && current.GetString() is { } value)
                {
                    output.Add(value);
                }

                return;
            }

            if (current.ValueKind == JsonValueKind.Object &&
                current.TryGetProperty(segments[segmentIndex], out var next))
            {
                Collect(next, segments, segmentIndex + 1, output);
            }
        }
    }

    private static IReadOnlyList<string> MissingValues(
        IEnumerable<string> required,
        IReadOnlySet<string> observed) =>
        required.Where(value => !observed.Contains(value)).ToArray();

    private sealed record BalancedExtraction(
        byte[]? Bytes,
        HerdrBundledSchemaStatus? Status,
        string Message);
}
