using System.Buffers;
using System.Collections;
using System.Globalization;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.Encodings.Web;

namespace HerdrOps.Domain.Diagnostics;

public sealed class DiagnosticBundleBuilder
{
    private static readonly JsonWriterOptions JsonWriterOptions = new()
    {
        Encoder = JavaScriptEncoder.UnsafeRelaxedJsonEscaping,
        Indented = false,
        SkipValidation = false,
    };

    private readonly DiagnosticTextRedactor _redactor;
    private readonly DiagnosticRedactionOptions _redactionOptions;
    private readonly DiagnosticBundleLimits _limits;

    public DiagnosticBundleBuilder(
        DiagnosticRedactionOptions? redactionOptions = null,
        DiagnosticBundleLimits? limits = null)
    {
        _redactionOptions = redactionOptions ?? new DiagnosticRedactionOptions();
        _redactor = new DiagnosticTextRedactor(_redactionOptions);
        _limits = limits ?? new DiagnosticBundleLimits();
        _limits.Validate();
    }

    public DiagnosticBundlePackage Build(DiagnosticBundleRequest request)
    {
        ArgumentNullException.ThrowIfNull(request);
        EnsureUtc(request.CapturedAtUtc, nameof(request.CapturedAtUtc));

        var entries = request.Entries ?? [];
        var crashes = request.Crashes ?? [];
        if (entries.Count > _limits.MaximumEntries)
        {
            throw new ArgumentOutOfRangeException(
                nameof(request),
                $"A diagnostic bundle accepts at most {_limits.MaximumEntries} entries.");
        }

        if (crashes.Count > _limits.MaximumCrashRecords)
        {
            throw new ArgumentOutOfRangeException(
                nameof(request),
                $"A diagnostic bundle accepts at most {_limits.MaximumCrashRecords} crash records.");
        }

        if (entries.Count + crashes.Count > _limits.MaximumEntries)
        {
            throw new ArgumentOutOfRangeException(
                nameof(request),
                "The combined diagnostic entry and crash record count exceeds the bundle bound.");
        }

        var appVersion = RedactRequired(request.AppVersion, _redactor, "appVersion");
        var processVersion = RedactRequired(request.ProcessVersion, _redactor, "processVersion");
        var canonicalEntries = entries
            .Select((entry, index) => NormalizeEntry(entry, index))
            .OrderBy(entry => entry.KindWire, StringComparer.Ordinal)
            .ThenBy(entry => entry.Name, StringComparer.Ordinal)
            .ThenBy(entry => entry.Text ?? string.Empty, StringComparer.Ordinal)
            .ThenBy(entry => entry.MetadataCanonical, StringComparer.Ordinal)
            .ToArray();
        var canonicalCrashes = crashes
            .Select((crash, index) => NormalizeCrash(crash, index))
            .OrderBy(crash => crash.TimestampUtc, StringComparer.Ordinal)
            .ThenBy(crash => crash.ExceptionType, StringComparer.Ordinal)
            .ThenBy(crash => crash.CategoryWire, StringComparer.Ordinal)
            .ThenBy(crash => crash.Message, StringComparer.Ordinal)
            .ThenBy(crash => crash.StackSummary, StringComparer.Ordinal)
            .ToArray();

        var payloadBytes = WriteJson(writer =>
        {
            writer.WriteStartObject();
            writer.WriteString("schemaVersion", DiagnosticBundleSchema.BundleVersion);
            writer.WriteString("capturedAtUtc", UtcText(request.CapturedAtUtc));
            writer.WriteString("appVersion", appVersion);
            writer.WriteString("processVersion", processVersion);
            writer.WriteStartArray("entries");
            foreach (var entry in canonicalEntries)
            {
                entry.Write(writer);
            }

            writer.WriteEndArray();
            writer.WriteNumber("crashCount", canonicalCrashes.Length);
            writer.WriteEndObject();
        });

        var crashBytes = WriteJson(writer =>
        {
            writer.WriteStartObject();
            writer.WriteString("schemaVersion", DiagnosticBundleSchema.CrashMetadataVersion);
            writer.WriteStartArray("crashes");
            foreach (var crash in canonicalCrashes)
            {
                crash.Write(writer);
            }

            writer.WriteEndArray();
            writer.WriteEndObject();
        });

        EnsureSize(payloadBytes, _limits.MaximumPayloadBytes, "payload.json");
        EnsureSize(crashBytes, _limits.MaximumCrashMetadataBytes, "crash-metadata.json");

        var payloadArtifact = CreateArtifact(DiagnosticBundleSchema.PayloadFileName, payloadBytes);
        var crashArtifact = CreateArtifact(DiagnosticBundleSchema.CrashMetadataFileName, crashBytes);
        var contentArtifacts = new[] { payloadArtifact, crashArtifact }
            .OrderBy(artifact => artifact.FileName, StringComparer.Ordinal)
            .ToArray();
        var manifestBytes = WriteJson(writer =>
        {
            writer.WriteStartObject();
            writer.WriteString("schemaVersion", DiagnosticBundleSchema.ManifestVersion);
            writer.WriteNumber("artifactCount", contentArtifacts.Length);
            writer.WriteNumber("contentBytes", contentArtifacts.Sum(artifact => artifact.ByteCount));
            writer.WriteStartArray("artifacts");
            foreach (var artifact in contentArtifacts)
            {
                writer.WriteStartObject();
                writer.WriteString("fileName", artifact.FileName);
                writer.WriteNumber("byteCount", artifact.ByteCount);
                writer.WriteString("sha256", artifact.Sha256);
                writer.WriteEndObject();
            }

            writer.WriteEndArray();
            writer.WriteEndObject();
        });
        EnsureSize(manifestBytes, _limits.MaximumPayloadBytes, "manifest.json");

        var manifestArtifact = CreateArtifact(DiagnosticBundleSchema.ManifestFileName, manifestBytes);
        var artifacts = new[] { manifestArtifact, payloadArtifact, crashArtifact }
            .OrderBy(artifact => artifact.FileName, StringComparer.Ordinal)
            .ToArray();
        var totalBytes = artifacts.Sum(artifact => artifact.ByteCount);
        if (totalBytes > _limits.MaximumBundleBytes)
        {
            throw new InvalidOperationException(
                $"The diagnostic bundle is {totalBytes} bytes, above the {_limits.MaximumBundleBytes}-byte bound.");
        }

        return new DiagnosticBundlePackage(
            artifacts,
            canonicalEntries.Length,
            canonicalCrashes.Length,
            totalBytes,
            manifestArtifact.Sha256);
    }

    private CanonicalEntry NormalizeEntry(DiagnosticBundleEntry entry, int index)
    {
        ArgumentNullException.ThrowIfNull(entry);
        if (!Enum.IsDefined(entry.Kind))
        {
            throw new ArgumentOutOfRangeException(nameof(entry), "The diagnostic entry kind is not allowlisted.");
        }

        var name = NormalizeName(entry.Name, $"entries[{index}].name");
        var text = entry.Text is null
            ? null
            : _redactor.Redact(entry.Text).Text;
        var metadata = NormalizeMetadata(entry.Metadata, $"entries[{index}].metadata");
        return new CanonicalEntry(
            WireName(entry.Kind),
            name,
            text,
            metadata,
            CanonicalJson(metadata));
    }

    private CanonicalCrash NormalizeCrash(CrashMetadata crash, int index)
    {
        ArgumentNullException.ThrowIfNull(crash);
        EnsureUtc(crash.TimestampUtc, $"crashes[{index}].timestampUtc");
        if (!Enum.IsDefined(crash.Category))
        {
            throw new ArgumentOutOfRangeException(nameof(crash), "The crash category is not allowlisted.");
        }

        return new CanonicalCrash(
            UtcText(crash.TimestampUtc),
            RedactRequired(crash.ExceptionType, _redactor, $"crashes[{index}].exceptionType"),
            WireName(crash.Category),
            _redactor.Redact(crash.Message, _redactionOptions.MaximumCrashMessageUtf8Bytes).Text,
            _redactor.Redact(crash.StackSummary, _redactionOptions.MaximumCrashStackUtf8Bytes).Text,
            RedactRequired(crash.AppVersion, _redactor, $"crashes[{index}].appVersion"),
            RedactRequired(crash.ProcessVersion, _redactor, $"crashes[{index}].processVersion"));
    }

    private CanonicalJsonValue NormalizeMetadata(
        IReadOnlyDictionary<string, object?>? metadata,
        string path)
    {
        var nodeCount = 0;
        return NormalizeValue(metadata ?? EmptyMetadata, path, 0, ref nodeCount);
    }

    private CanonicalJsonValue NormalizeValue(
        object? value,
        string path,
        int depth,
        ref int nodeCount)
    {
        if (depth > _limits.MaximumMetadataDepth)
        {
            throw new ArgumentOutOfRangeException(nameof(value), $"Metadata depth exceeded at {path}.");
        }

        nodeCount++;
        if (nodeCount > _limits.MaximumMetadataNodes)
        {
            throw new ArgumentOutOfRangeException(nameof(value), $"Metadata node count exceeded at {path}.");
        }

        switch (value)
        {
            case null:
                return CanonicalJsonValue.Null;
            case string text:
                return CanonicalJsonValue.String(_redactor.Redact(text).Text);
            case bool boolean:
                return CanonicalJsonValue.Boolean(boolean);
            case byte number:
                return CanonicalJsonValue.Number(number);
            case sbyte number:
                return CanonicalJsonValue.Number(number);
            case short number:
                return CanonicalJsonValue.Number(number);
            case ushort number:
                return CanonicalJsonValue.Number(number);
            case int number:
                return CanonicalJsonValue.Number(number);
            case uint number:
                return CanonicalJsonValue.Number(number);
            case long number:
                return CanonicalJsonValue.Number(number);
            case ulong number:
                if (number > long.MaxValue)
                {
                    return CanonicalJsonValue.Decimal(number.ToString(CultureInfo.InvariantCulture));
                }

                return CanonicalJsonValue.Number((long)number);
            case decimal number:
                return CanonicalJsonValue.Decimal(number.ToString(CultureInfo.InvariantCulture));
            case double number when double.IsFinite(number):
                return CanonicalJsonValue.Decimal(number.ToString("R", CultureInfo.InvariantCulture));
            case float number when float.IsFinite(number):
                return CanonicalJsonValue.Decimal(number.ToString("R", CultureInfo.InvariantCulture));
            case DateTimeOffset timestamp:
                EnsureUtc(timestamp, path);
                return CanonicalJsonValue.String(UtcText(timestamp));
            case JsonElement element:
                return NormalizeJsonElement(element, path, depth, ref nodeCount);
            case IReadOnlyDictionary<string, object?> readOnlyDictionary:
                return NormalizeReadOnlyDictionary(readOnlyDictionary, path, depth, ref nodeCount);
            case IDictionary dictionary:
                return NormalizeDictionary(dictionary, path, depth, ref nodeCount);
            case IEnumerable sequence when value is not byte[]:
                return NormalizeArray(sequence, path, depth, ref nodeCount);
            default:
                throw new ArgumentException(
                    $"Metadata value at {path} has unsupported type '{value.GetType().FullName}'.",
                    nameof(value));
        }
    }

    private CanonicalJsonValue NormalizeJsonElement(
        JsonElement element,
        string path,
        int depth,
        ref int nodeCount)
    {
        return element.ValueKind switch
        {
            JsonValueKind.Null => CanonicalJsonValue.Null,
            JsonValueKind.True => CanonicalJsonValue.Boolean(true),
            JsonValueKind.False => CanonicalJsonValue.Boolean(false),
            JsonValueKind.String => CanonicalJsonValue.String(_redactor.Redact(element.GetString() ?? string.Empty).Text),
            JsonValueKind.Number when element.TryGetInt64(out var integer) => CanonicalJsonValue.Number(integer),
            JsonValueKind.Number when element.TryGetDecimal(out var decimalValue) => CanonicalJsonValue.Decimal(decimalValue.ToString(CultureInfo.InvariantCulture)),
            JsonValueKind.Number => throw new ArgumentException($"Metadata number at {path} is outside the supported range."),
            JsonValueKind.Object => NormalizeJsonObject(element, path, depth, ref nodeCount),
            JsonValueKind.Array => NormalizeJsonArray(element, path, depth, ref nodeCount),
            _ => throw new ArgumentException($"Metadata value at {path} is not allowlisted."),
        };
    }

    private CanonicalJsonValue NormalizeJsonObject(
        JsonElement element,
        string path,
        int depth,
        ref int nodeCount)
    {
        var dictionary = new Dictionary<string, object?>(StringComparer.Ordinal);
        foreach (var property in element.EnumerateObject())
        {
            dictionary.Add(property.Name, property.Value);
        }

        return NormalizeDictionary(dictionary, path, depth, ref nodeCount);
    }

    private CanonicalJsonValue NormalizeJsonArray(
        JsonElement element,
        string path,
        int depth,
        ref int nodeCount)
    {
        var values = new List<CanonicalJsonValue>();
        foreach (var item in element.EnumerateArray())
        {
            if (values.Count >= _limits.MaximumMetadataItemsPerArray)
            {
                throw new ArgumentOutOfRangeException(nameof(element), $"Metadata array item count exceeded at {path}.");
            }

            values.Add(NormalizeValue(item, $"{path}[{values.Count}]", depth + 1, ref nodeCount));
        }

        return CanonicalJsonValue.Array(values);
    }

    private CanonicalJsonValue NormalizeDictionary(
        IDictionary dictionary,
        string path,
        int depth,
        ref int nodeCount)
    {
        if (dictionary.Count > _limits.MaximumMetadataPropertiesPerObject)
        {
            throw new ArgumentOutOfRangeException(nameof(dictionary), $"Metadata property count exceeded at {path}.");
        }

        var properties = new SortedDictionary<string, CanonicalJsonValue>(StringComparer.Ordinal);
        foreach (DictionaryEntry item in dictionary)
        {
            if (item.Key is not string key)
            {
                throw new ArgumentException($"Metadata key at {path} is not a string.", nameof(dictionary));
            }

            var normalizedKey = NormalizeMetadataKey(key, path);
            if (!properties.TryAdd(
                    normalizedKey,
                    IsSensitiveFieldName(key)
                        ? CanonicalJsonValue.String(DiagnosticTextRedactor.Replacement)
                        : NormalizeValue(item.Value, $"{path}.{key}", depth + 1, ref nodeCount)))
            {
                throw new ArgumentException($"Metadata contains duplicate key '{normalizedKey}' at {path}.");
            }
        }

        return CanonicalJsonValue.Object(properties);
    }

    private CanonicalJsonValue NormalizeReadOnlyDictionary(
        IReadOnlyDictionary<string, object?> dictionary,
        string path,
        int depth,
        ref int nodeCount)
    {
        if (dictionary.Count > _limits.MaximumMetadataPropertiesPerObject)
        {
            throw new ArgumentOutOfRangeException(nameof(dictionary), $"Metadata property count exceeded at {path}.");
        }

        var properties = new SortedDictionary<string, CanonicalJsonValue>(StringComparer.Ordinal);
        foreach (var item in dictionary)
        {
            var normalizedKey = NormalizeMetadataKey(item.Key, path);
            if (!properties.TryAdd(
                    normalizedKey,
                    IsSensitiveFieldName(item.Key)
                        ? CanonicalJsonValue.String(DiagnosticTextRedactor.Replacement)
                        : NormalizeValue(item.Value, $"{path}.{item.Key}", depth + 1, ref nodeCount)))
            {
                throw new ArgumentException($"Metadata contains duplicate key '{normalizedKey}' at {path}.");
            }
        }

        return CanonicalJsonValue.Object(properties);
    }

    private CanonicalJsonValue NormalizeArray(
        IEnumerable sequence,
        string path,
        int depth,
        ref int nodeCount)
    {
        var values = new List<CanonicalJsonValue>();
        foreach (var item in sequence)
        {
            if (values.Count >= _limits.MaximumMetadataItemsPerArray)
            {
                throw new ArgumentOutOfRangeException(nameof(sequence), $"Metadata array item count exceeded at {path}.");
            }

            values.Add(NormalizeValue(item, $"{path}[{values.Count}]", depth + 1, ref nodeCount));
        }

        return CanonicalJsonValue.Array(values);
    }

    private string NormalizeName(string value, string path)
    {
        if (string.IsNullOrWhiteSpace(value) ||
            value.Length > 96 ||
            value != value.Trim() ||
            value is "." or ".." ||
            value.Any(char.IsControl) ||
            value.Any(character => character is '/' or '\\' or ':' or '*' or '?' or '"' or '<' or '>' or '|'))
        {
            throw new ArgumentException($"Diagnostic name at {path} is outside the allowlist.", nameof(value));
        }

        var normalized = _redactor.Redact(value).Text;
        if (IsProhibitedFieldName(normalized))
        {
            throw new ArgumentException($"Diagnostic name at {path} is prohibited by the contract.", nameof(value));
        }

        return normalized;
    }

    private string NormalizeMetadataKey(string value, string path)
    {
        if (string.IsNullOrWhiteSpace(value) ||
            value.Length > 64 ||
            value != value.Trim() ||
            value.Any(char.IsControl) ||
            value.Any(character => character is '/' or '\\' or ':' or '*' or '?' or '"' or '<' or '>' or '|'))
        {
            throw new ArgumentException($"Metadata key at {path} is outside the allowlist.", nameof(value));
        }

        var normalized = _redactor.Redact(value, 512).Text;
        if (IsProhibitedFieldName(normalized))
        {
            throw new ArgumentException($"Metadata key at {path} is prohibited by the contract.", nameof(value));
        }

        return normalized;
    }

    private static string RedactRequired(string value, DiagnosticTextRedactor redactor, string fieldName)
    {
        if (string.IsNullOrWhiteSpace(value))
        {
            throw new ArgumentException($"The diagnostic field '{fieldName}' is required.", nameof(value));
        }

        return redactor.Redact(value).Text;
    }

    private static bool IsSensitiveFieldName(string value)
    {
        var normalized = NormalizeFieldName(value);
        return normalized.Contains("token", StringComparison.Ordinal) ||
            normalized.Contains("secret", StringComparison.Ordinal) ||
            normalized.Contains("password", StringComparison.Ordinal) ||
            normalized.Contains("passwd", StringComparison.Ordinal) ||
            normalized.Contains("apikey", StringComparison.Ordinal) ||
            normalized.Contains("privatekey", StringComparison.Ordinal) ||
            normalized.Contains("credential", StringComparison.Ordinal) ||
            normalized.Contains("authorization", StringComparison.Ordinal) ||
            normalized.Contains("cookie", StringComparison.Ordinal) ||
            normalized.Contains("socketpath", StringComparison.Ordinal) ||
            normalized.Contains("connectionstring", StringComparison.Ordinal);
    }

    private static bool IsProhibitedFieldName(string value)
    {
        var normalized = NormalizeFieldName(value);
        return normalized.Contains("rawenvironment", StringComparison.Ordinal) ||
            normalized.Contains("environmentvariables", StringComparison.Ordinal) ||
            normalized.Contains("fullterminal", StringComparison.Ordinal) ||
            normalized.Contains("terminalcontent", StringComparison.Ordinal) ||
            normalized.Contains("minidump", StringComparison.Ordinal) ||
            normalized.EndsWith("dump", StringComparison.Ordinal) ||
            normalized.Contains("sockettoken", StringComparison.Ordinal) ||
            normalized.Contains("userprofile", StringComparison.Ordinal);
    }

    private static string NormalizeFieldName(string value) => new(
        value
            .Where(char.IsLetterOrDigit)
            .Select(char.ToLowerInvariant)
            .ToArray());

    private static void EnsureUtc(DateTimeOffset value, string fieldName)
    {
        if (value.Offset != TimeSpan.Zero)
        {
            throw new ArgumentException($"The diagnostic timestamp '{fieldName}' must be UTC.", fieldName);
        }
    }

    private static string UtcText(DateTimeOffset value) =>
        value.UtcDateTime.ToString("O", CultureInfo.InvariantCulture);

    private static void EnsureSize(byte[] bytes, int maximum, string artifactName)
    {
        if (bytes.Length > maximum)
        {
            throw new InvalidOperationException(
                $"The diagnostic artifact '{artifactName}' is {bytes.Length} bytes, above the {maximum}-byte bound.");
        }
    }

    private static DiagnosticBundleArtifact CreateArtifact(string fileName, byte[] bytes) =>
        new(fileName, bytes, Convert.ToHexString(SHA256.HashData(bytes)));

    private static byte[] WriteJson(Action<Utf8JsonWriter> write)
    {
        var buffer = new ArrayBufferWriter<byte>();
        using (var writer = new Utf8JsonWriter(buffer, JsonWriterOptions))
        {
            write(writer);
            writer.Flush();
        }

        return buffer.WrittenSpan.ToArray();
    }

    private static string CanonicalJson(CanonicalJsonValue value) =>
        Encoding.UTF8.GetString(WriteJson(writer => value.Write(writer)));

    private static string WireName(DiagnosticBundleEntryKind kind) => kind switch
    {
        DiagnosticBundleEntryKind.ApplicationState => "application-state",
        DiagnosticBundleEntryKind.LogExcerpt => "log-excerpt",
        DiagnosticBundleEntryKind.EnvironmentExcerpt => "environment-excerpt",
        DiagnosticBundleEntryKind.CommandLine => "command-line",
        DiagnosticBundleEntryKind.Url => "url",
        DiagnosticBundleEntryKind.Headers => "headers",
        DiagnosticBundleEntryKind.Metadata => "metadata",
        _ => throw new ArgumentOutOfRangeException(nameof(kind)),
    };

    private static string WireName(DiagnosticCrashCategory category) => category switch
    {
        DiagnosticCrashCategory.Unknown => "unknown",
        DiagnosticCrashCategory.Startup => "startup",
        DiagnosticCrashCategory.Dispatcher => "dispatcher",
        DiagnosticCrashCategory.Background => "background",
        DiagnosticCrashCategory.Unhandled => "unhandled",
        _ => throw new ArgumentOutOfRangeException(nameof(category)),
    };

    private static readonly IReadOnlyDictionary<string, object?> EmptyMetadata =
        new Dictionary<string, object?>(StringComparer.Ordinal);

    private sealed record CanonicalEntry(
        string KindWire,
        string Name,
        string? Text,
        CanonicalJsonValue Metadata,
        string MetadataCanonical)
    {
        public void Write(Utf8JsonWriter writer)
        {
            writer.WriteStartObject();
            writer.WriteString("kind", KindWire);
            writer.WriteString("name", Name);
            if (Text is null)
            {
                writer.WriteNull("text");
            }
            else
            {
                writer.WriteString("text", Text);
            }

            writer.WritePropertyName("metadata");
            Metadata.Write(writer);
            writer.WriteEndObject();
        }
    }

    private sealed record CanonicalCrash(
        string TimestampUtc,
        string ExceptionType,
        string CategoryWire,
        string Message,
        string StackSummary,
        string AppVersion,
        string ProcessVersion)
    {
        public void Write(Utf8JsonWriter writer)
        {
            writer.WriteStartObject();
            writer.WriteString("timestampUtc", TimestampUtc);
            writer.WriteString("exceptionType", ExceptionType);
            writer.WriteString("category", CategoryWire);
            writer.WriteString("message", Message);
            writer.WriteString("stackSummary", StackSummary);
            writer.WriteString("appVersion", AppVersion);
            writer.WriteString("processVersion", ProcessVersion);
            writer.WriteEndObject();
        }
    }

    private sealed class CanonicalJsonValue
    {
        private enum ValueKind
        {
            Null,
            String,
            Boolean,
            Number,
            Decimal,
            Object,
            Array,
        }

        private CanonicalJsonValue(ValueKind kind, object? value)
        {
            Kind = kind;
            Value = value;
        }

        public static CanonicalJsonValue Null { get; } = new(ValueKind.Null, null);

        private ValueKind Kind { get; }

        private object? Value { get; }

        public static CanonicalJsonValue String(string value) => new(ValueKind.String, value);

        public static CanonicalJsonValue Boolean(bool value) => new(ValueKind.Boolean, value);

        public static CanonicalJsonValue Number(long value) => new(ValueKind.Number, value);

        public static CanonicalJsonValue Decimal(string value) => new(ValueKind.Decimal, value);

        public static CanonicalJsonValue Object(SortedDictionary<string, CanonicalJsonValue> value) =>
            new(ValueKind.Object, value);

        public static CanonicalJsonValue Array(List<CanonicalJsonValue> value) => new(ValueKind.Array, value);

        public void Write(Utf8JsonWriter writer)
        {
            switch (Kind)
            {
                case ValueKind.Null:
                    writer.WriteNullValue();
                    break;
                case ValueKind.String:
                    writer.WriteStringValue((string)Value!);
                    break;
                case ValueKind.Boolean:
                    writer.WriteBooleanValue((bool)Value!);
                    break;
                case ValueKind.Number:
                    writer.WriteNumberValue((long)Value!);
                    break;
                case ValueKind.Decimal:
                    writer.WriteRawValue((string)Value!, skipInputValidation: false);
                    break;
                case ValueKind.Object:
                    writer.WriteStartObject();
                    foreach (var property in (SortedDictionary<string, CanonicalJsonValue>)Value!)
                    {
                        writer.WritePropertyName(property.Key);
                        property.Value.Write(writer);
                    }

                    writer.WriteEndObject();
                    break;
                case ValueKind.Array:
                    writer.WriteStartArray();
                    foreach (var item in (List<CanonicalJsonValue>)Value!)
                    {
                        item.Write(writer);
                    }

                    writer.WriteEndArray();
                    break;
                default:
                    throw new InvalidOperationException("Unknown canonical JSON value kind.");
            }
        }
    }
}
