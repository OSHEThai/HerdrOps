using System.Globalization;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using HerdrOps.Domain.Evidence;

namespace HerdrOps.Domain.Compliance;

/// <summary>
/// The compliance diagnostic export is a deliberately smaller contract than the
/// compliance storage model.  It cannot represent actors, tasks, reasons, source
/// references, paths, terminal text, or arbitrary metadata.
/// </summary>
public static class ComplianceDiagnosticExportSchema
{
    public const string InputSchemaVersion = "v0.5.compliance-diagnostic-input.v1";
    public const string ExportSchemaVersion = "v0.5.compliance-diagnostic-export.v1";
    public const int MaximumRecords = 256;
    public const int MaximumIdentifierLength = 128;
    public const int MaximumEvidencePerRecord = 256;
    public const int MaximumTotalEvidence = 4096;
    public const int MaximumInputBytes = 512 * 1024;
    public const int MaximumOutputBytes = 256 * 1024;
}

public sealed record ComplianceDiagnosticReview(
    string ReviewId,
    ReviewAuditState State,
    DateTimeOffset UpdatedUtc,
    string AuditSha256);

public sealed record ComplianceDiagnosticEvidence(
    string EvidenceId,
    EvidenceArtifactAvailability State,
    DateTimeOffset ObservedUtc,
    string MetadataSha256,
    string? ContentSha256);

public sealed record ComplianceDiagnosticRecord(
    string IncidentId,
    ComplianceReviewState IncidentState,
    DateTimeOffset RegisteredUtc,
    DateTimeOffset UpdatedUtc,
    string RegistrationSha256,
    ComplianceDiagnosticReview? Review,
    IReadOnlyList<ComplianceDiagnosticEvidence> Evidence);

public sealed record ComplianceDiagnosticExportInput(
    string SchemaVersion,
    DateTimeOffset GeneratedUtc,
    IReadOnlyList<ComplianceDiagnosticRecord> Records);

public sealed record ComplianceDiagnosticExportArtifact(
    byte[] Content,
    string Sha256,
    int RecordCount)
{
    public int ByteCount => Content.Length;
}

public sealed class ComplianceDiagnosticExportException : ArgumentException
{
    public ComplianceDiagnosticExportException(string message)
        : base(message)
    {
    }

    public ComplianceDiagnosticExportException(string message, Exception innerException)
        : base(message, innerException)
    {
    }
}

public static class ComplianceDiagnosticExportBuilder
{
    private const string TimestampFormat = "yyyy-MM-dd'T'HH:mm:ss.fffffff'Z'";

    private static readonly JsonDocumentOptions InputDocumentOptions = new()
    {
        AllowTrailingCommas = false,
        CommentHandling = JsonCommentHandling.Disallow,
        MaxDepth = 12,
    };

    public static ComplianceDiagnosticExportArtifact Build(ReadOnlySpan<byte> inputUtf8)
    {
        if (inputUtf8.Length is < 1 or > ComplianceDiagnosticExportSchema.MaximumInputBytes)
        {
            throw new ComplianceDiagnosticExportException(
                $"The compliance diagnostic input must contain from 1 through {ComplianceDiagnosticExportSchema.MaximumInputBytes} bytes.");
        }

        try
        {
            using var document = JsonDocument.Parse(inputUtf8.ToArray(), InputDocumentOptions);
            var input = ParseInput(document.RootElement);
            return Build(input);
        }
        catch (ComplianceDiagnosticExportException)
        {
            throw;
        }
        catch (JsonException exception)
        {
            throw new ComplianceDiagnosticExportException(
                "The compliance diagnostic input is malformed JSON.",
                exception);
        }
        catch (ArgumentException exception) when (exception is not ComplianceDiagnosticExportException)
        {
            throw new ComplianceDiagnosticExportException(
                "The compliance diagnostic input is invalid.",
                exception);
        }
    }

    public static ComplianceDiagnosticExportArtifact Build(
        ComplianceDiagnosticExportInput input)
    {
        ArgumentNullException.ThrowIfNull(input);
        if (!string.Equals(
                input.SchemaVersion,
                ComplianceDiagnosticExportSchema.InputSchemaVersion,
                StringComparison.Ordinal))
        {
            throw new ComplianceDiagnosticExportException(
                "The compliance diagnostic input schema version is unsupported.");
        }

        EnsureUtc(input.GeneratedUtc, "generatedUtc");
        if (input.Records is null ||
            input.Records.Count is < 1 or > ComplianceDiagnosticExportSchema.MaximumRecords)
        {
            throw new ComplianceDiagnosticExportException(
                $"The compliance diagnostic input requires 1 through {ComplianceDiagnosticExportSchema.MaximumRecords} records.");
        }

        var incidentIds = new HashSet<string>(StringComparer.Ordinal);
        var reviewIds = new HashSet<string>(StringComparer.Ordinal);
        var evidenceIds = new HashSet<string>(StringComparer.Ordinal);
        var totalEvidence = 0;
        var records = new List<ComplianceDiagnosticRecord>(input.Records.Count);
        foreach (var record in input.Records)
        {
            var normalized = NormalizeRecord(record);
            if (!incidentIds.Add(normalized.IncidentId))
            {
                throw new ComplianceDiagnosticExportException(
                    "The compliance diagnostic input contains a duplicate incident ID.");
            }

            if (normalized.Review is not null &&
                !reviewIds.Add(normalized.Review.ReviewId))
            {
                throw new ComplianceDiagnosticExportException(
                    "The compliance diagnostic input contains a duplicate review ID.");
            }

            totalEvidence += normalized.Evidence.Count;
            if (totalEvidence > ComplianceDiagnosticExportSchema.MaximumTotalEvidence)
            {
                throw new ComplianceDiagnosticExportException(
                    $"The compliance diagnostic input contains more than {ComplianceDiagnosticExportSchema.MaximumTotalEvidence} evidence records.");
            }

            foreach (var evidence in normalized.Evidence)
            {
                if (!evidenceIds.Add(evidence.EvidenceId))
                {
                    throw new ComplianceDiagnosticExportException(
                        "The compliance diagnostic input contains a duplicate evidence ID.");
                }
            }

            records.Add(normalized);
        }

        records.Sort((left, right) => StringComparer.Ordinal.Compare(
            left.IncidentId,
            right.IncidentId));
        var content = Serialize(
            new ComplianceDiagnosticExportInput(
                ComplianceDiagnosticExportSchema.InputSchemaVersion,
                input.GeneratedUtc,
                records));
        if (content.Length > ComplianceDiagnosticExportSchema.MaximumOutputBytes)
        {
            throw new ComplianceDiagnosticExportException(
                $"The compliance diagnostic export exceeds the {ComplianceDiagnosticExportSchema.MaximumOutputBytes}-byte output bound.");
        }

        return new ComplianceDiagnosticExportArtifact(
            content,
            Convert.ToHexString(SHA256.HashData(content)),
            records.Count);
    }

    public static string FormatUtc(DateTimeOffset value)
    {
        EnsureUtc(value, nameof(value));
        return value.ToUniversalTime().ToString(TimestampFormat, CultureInfo.InvariantCulture);
    }

    private static ComplianceDiagnosticExportInput ParseInput(JsonElement root)
    {
        EnsureObject(root, "input");
        EnsureExactProperties(root, "schemaVersion", "generatedUtc", "records");
        return new ComplianceDiagnosticExportInput(
            ReadStringProperty(root, "schemaVersion"),
            ReadUtcProperty(root, "generatedUtc"),
            ReadRecords(root.GetProperty("records")));
    }

    private static IReadOnlyList<ComplianceDiagnosticRecord> ReadRecords(JsonElement value)
    {
        EnsureArray(value, "records");
        if (value.GetArrayLength() is < 1 or > ComplianceDiagnosticExportSchema.MaximumRecords)
        {
            throw new ComplianceDiagnosticExportException(
                $"The compliance diagnostic input requires 1 through {ComplianceDiagnosticExportSchema.MaximumRecords} records.");
        }

        var records = new List<ComplianceDiagnosticRecord>(value.GetArrayLength());
        foreach (var item in value.EnumerateArray())
        {
            EnsureObject(item, "record");
            EnsureExactProperties(
                item,
                "incidentId",
                "incidentState",
                "registeredUtc",
                "updatedUtc",
                "registrationSha256",
                "review",
                "evidence");
            records.Add(new ComplianceDiagnosticRecord(
                ReadCanonicalIdentifier(item, "incidentId"),
                ReadEnum<ComplianceReviewState>(item, "incidentState"),
                ReadUtcProperty(item, "registeredUtc"),
                ReadUtcProperty(item, "updatedUtc"),
                ReadHash(item, "registrationSha256"),
                ReadReview(item.GetProperty("review")),
                ReadEvidence(item.GetProperty("evidence"))));
        }

        return records;
    }

    private static ComplianceDiagnosticReview? ReadReview(JsonElement value)
    {
        if (value.ValueKind == JsonValueKind.Null)
        {
            return null;
        }

        EnsureObject(value, "review");
        EnsureExactProperties(value, "reviewId", "state", "updatedUtc", "auditSha256");
        return new ComplianceDiagnosticReview(
            ReadCanonicalIdentifier(value, "reviewId"),
            ReadEnum<ReviewAuditState>(value, "state"),
            ReadUtcProperty(value, "updatedUtc"),
            ReadHash(value, "auditSha256"));
    }

    private static IReadOnlyList<ComplianceDiagnosticEvidence> ReadEvidence(JsonElement value)
    {
        EnsureArray(value, "evidence");
        if (value.GetArrayLength() > ComplianceDiagnosticExportSchema.MaximumEvidencePerRecord)
        {
            throw new ComplianceDiagnosticExportException(
                $"A compliance diagnostic record can contain at most {ComplianceDiagnosticExportSchema.MaximumEvidencePerRecord} evidence records.");
        }

        var evidence = new List<ComplianceDiagnosticEvidence>(value.GetArrayLength());
        foreach (var item in value.EnumerateArray())
        {
            EnsureObject(item, "evidence");
            EnsureExactProperties(
                item,
                "evidenceId",
                "state",
                "observedUtc",
                "metadataSha256",
                "contentSha256");
            var content = item.GetProperty("contentSha256");
            evidence.Add(new ComplianceDiagnosticEvidence(
                ReadHash(item, "evidenceId"),
                ReadEnum<EvidenceArtifactAvailability>(item, "state"),
                ReadUtcProperty(item, "observedUtc"),
                ReadHash(item, "metadataSha256"),
                content.ValueKind == JsonValueKind.Null
                    ? null
                    : ReadHashValue(content, "contentSha256")));
        }

        return evidence;
    }

    private static ComplianceDiagnosticRecord NormalizeRecord(
        ComplianceDiagnosticRecord record)
    {
        ArgumentNullException.ThrowIfNull(record);
        var incidentId = NormalizeCanonicalIdentifier(record.IncidentId, "incidentId");
        EnsureUtc(record.RegisteredUtc, "registeredUtc");
        EnsureUtc(record.UpdatedUtc, "updatedUtc");
        if (record.UpdatedUtc < record.RegisteredUtc)
        {
            throw new ComplianceDiagnosticExportException(
                "A compliance diagnostic incident cannot be updated before registration.");
        }

        if (!Enum.IsDefined(record.IncidentState))
        {
            throw new ComplianceDiagnosticExportException(
                "A compliance diagnostic incident contains an unsupported state.");
        }

        var review = record.Review is null
            ? null
            : NormalizeReview(record.Review, record.RegisteredUtc);
        if (record.Evidence is null)
        {
            throw new ComplianceDiagnosticExportException(
                "A compliance diagnostic record requires an evidence collection.");
        }

        if (record.Evidence.Count > ComplianceDiagnosticExportSchema.MaximumEvidencePerRecord)
        {
            throw new ComplianceDiagnosticExportException(
                $"A compliance diagnostic record can contain at most {ComplianceDiagnosticExportSchema.MaximumEvidencePerRecord} evidence records.");
        }

        var evidence = record.Evidence
            .Select(item => NormalizeEvidence(item, record.UpdatedUtc))
            .OrderBy(item => item.EvidenceId, StringComparer.Ordinal)
            .ToArray();

        return new ComplianceDiagnosticRecord(
            incidentId,
            record.IncidentState,
            record.RegisteredUtc,
            record.UpdatedUtc,
            ComplianceEvaluationContract.NormalizeSha256(
                record.RegistrationSha256,
                "registrationSha256"),
            review,
            Array.AsReadOnly(evidence));
    }

    private static ComplianceDiagnosticReview NormalizeReview(
        ComplianceDiagnosticReview review,
        DateTimeOffset registeredUtc)
    {
        if (!Enum.IsDefined(review.State))
        {
            throw new ComplianceDiagnosticExportException(
                "A compliance diagnostic review contains an unsupported ID or state.");
        }

        EnsureUtc(review.UpdatedUtc, "review.updatedUtc");
        if (review.UpdatedUtc < registeredUtc)
        {
            throw new ComplianceDiagnosticExportException(
                "A compliance diagnostic review cannot be updated before incident registration.");
        }

        return review with
        {
            ReviewId = NormalizeCanonicalIdentifier(review.ReviewId, "reviewId"),
            AuditSha256 = ComplianceEvaluationContract.NormalizeSha256(
                review.AuditSha256,
                "review.auditSha256"),
        };
    }

    private static ComplianceDiagnosticEvidence NormalizeEvidence(
        ComplianceDiagnosticEvidence evidence,
        DateTimeOffset incidentUpdatedUtc)
    {
        ArgumentNullException.ThrowIfNull(evidence);
        if (!Enum.IsDefined(evidence.State))
        {
            throw new ComplianceDiagnosticExportException(
                "A compliance diagnostic evidence record contains an unsupported state.");
        }

        EnsureUtc(evidence.ObservedUtc, "evidence.observedUtc");
        if (evidence.ObservedUtc > incidentUpdatedUtc)
        {
            throw new ComplianceDiagnosticExportException(
                "A compliance diagnostic evidence timestamp cannot be after the incident update.");
        }

        var contentHash = evidence.ContentSha256 is null
            ? null
            : ComplianceEvaluationContract.NormalizeSha256(
                evidence.ContentSha256,
                "evidence.contentSha256");
        if ((evidence.State == EvidenceArtifactAvailability.Missing) != (contentHash is null))
        {
            throw new ComplianceDiagnosticExportException(
                "Missing evidence must omit contentSha256 and present evidence must include it.");
        }

        return evidence with
        {
            EvidenceId = ComplianceEvaluationContract.NormalizeSha256(
                evidence.EvidenceId,
                "evidenceId"),
            MetadataSha256 = ComplianceEvaluationContract.NormalizeSha256(
                evidence.MetadataSha256,
                "evidence.metadataSha256"),
            ContentSha256 = contentHash,
        };
    }

    private static byte[] Serialize(ComplianceDiagnosticExportInput input)
    {
        using var stream = new MemoryStream();
        using (var writer = new Utf8JsonWriter(stream, new JsonWriterOptions
        {
            Indented = false,
        }))
        {
            writer.WriteStartObject();
            writer.WriteString("schemaVersion", ComplianceDiagnosticExportSchema.ExportSchemaVersion);
            writer.WriteString("generatedUtc", FormatUtc(input.GeneratedUtc));
            writer.WriteNumber("recordCount", input.Records.Count);
            writer.WriteStartArray("records");
            foreach (var record in input.Records.OrderBy(item => item.IncidentId, StringComparer.Ordinal))
            {
                writer.WriteStartObject();
                writer.WriteString("incidentId", record.IncidentId);
                writer.WriteString("incidentState", record.IncidentState.ToString());
                writer.WriteString("registeredUtc", FormatUtc(record.RegisteredUtc));
                writer.WriteString("updatedUtc", FormatUtc(record.UpdatedUtc));
                writer.WriteString("registrationSha256", record.RegistrationSha256);
                if (record.Review is null)
                {
                    writer.WriteNull("review");
                }
                else
                {
                    writer.WriteStartObject("review");
                    writer.WriteString("reviewId", record.Review.ReviewId);
                    writer.WriteString("state", record.Review.State.ToString());
                    writer.WriteString("updatedUtc", FormatUtc(record.Review.UpdatedUtc));
                    writer.WriteString("auditSha256", record.Review.AuditSha256);
                    writer.WriteEndObject();
                }

                writer.WriteStartArray("evidence");
                foreach (var evidence in record.Evidence.OrderBy(item => item.EvidenceId, StringComparer.Ordinal))
                {
                    writer.WriteStartObject();
                    writer.WriteString("evidenceId", evidence.EvidenceId);
                    writer.WriteString("state", evidence.State.ToString());
                    writer.WriteString("observedUtc", FormatUtc(evidence.ObservedUtc));
                    writer.WriteString("metadataSha256", evidence.MetadataSha256);
                    if (evidence.ContentSha256 is null)
                    {
                        writer.WriteNull("contentSha256");
                    }
                    else
                    {
                        writer.WriteString("contentSha256", evidence.ContentSha256);
                    }

                    writer.WriteEndObject();
                }

                writer.WriteEndArray();
                writer.WriteEndObject();
            }

            writer.WriteEndArray();
            writer.WriteEndObject();
        }

        return stream.ToArray();
    }

    private static string ReadCanonicalIdentifier(JsonElement parent, string propertyName) =>
        NormalizeCanonicalIdentifier(ReadStringProperty(parent, propertyName), propertyName);

    private static string ReadHash(JsonElement parent, string propertyName) =>
        ReadHashValue(parent.GetProperty(propertyName), propertyName);

    private static string ReadHashValue(JsonElement value, string propertyName) =>
        ComplianceEvaluationContract.NormalizeSha256(
            ReadStringValue(value, propertyName),
            propertyName);

    private static TEnum ReadEnum<TEnum>(JsonElement parent, string propertyName)
        where TEnum : struct, Enum
    {
        var value = ReadStringProperty(parent, propertyName);
        if (!Enum.GetNames<TEnum>().Contains(value, StringComparer.Ordinal) ||
            !Enum.TryParse<TEnum>(value, ignoreCase: false, out var result))
        {
            throw new ComplianceDiagnosticExportException(
                $"The compliance diagnostic field {propertyName} contains an unsupported state.");
        }

        return result;
    }

    private static DateTimeOffset ReadUtcProperty(JsonElement parent, string propertyName) =>
        ReadUtcValue(parent.GetProperty(propertyName), propertyName);

    private static DateTimeOffset ReadUtcValue(JsonElement value, string propertyName)
    {
        var text = ReadStringValue(value, propertyName);
        if (!DateTimeOffset.TryParseExact(
                text,
                TimestampFormat,
                CultureInfo.InvariantCulture,
                DateTimeStyles.AssumeUniversal | DateTimeStyles.AdjustToUniversal,
                out var parsed) ||
            !string.Equals(FormatUtc(parsed), text, StringComparison.Ordinal))
        {
            throw new ComplianceDiagnosticExportException(
                $"The compliance diagnostic field {propertyName} must be a canonical UTC timestamp.");
        }

        return parsed;
    }

    private static string ReadStringProperty(JsonElement parent, string propertyName) =>
        ReadStringValue(parent.GetProperty(propertyName), propertyName);

    private static string ReadStringValue(JsonElement value, string propertyName)
    {
        if (value.ValueKind != JsonValueKind.String || value.GetString() is not { } text)
        {
            throw new ComplianceDiagnosticExportException(
                $"The compliance diagnostic field {propertyName} must be a string.");
        }

        return text;
    }

    private static void EnsureExactProperties(JsonElement value, params string[] expected)
    {
        var expectedSet = expected.ToHashSet(StringComparer.Ordinal);
        var observed = new HashSet<string>(StringComparer.Ordinal);
        foreach (var property in value.EnumerateObject())
        {
            if (!observed.Add(property.Name))
            {
                throw new ComplianceDiagnosticExportException(
                    "The compliance diagnostic input contains a duplicate property.");
            }

            if (!expectedSet.Contains(property.Name))
            {
                throw new ComplianceDiagnosticExportException(
                    "The compliance diagnostic property is not allowlisted.");
            }
        }

        foreach (var propertyName in expected)
        {
            if (!observed.Contains(propertyName))
            {
                throw new ComplianceDiagnosticExportException(
                    "The compliance diagnostic property is required.");
            }
        }
    }

    private static string NormalizeCanonicalIdentifier(string value, string propertyName)
    {
        if (string.IsNullOrWhiteSpace(value) ||
            value.Length > ComplianceDiagnosticExportSchema.MaximumIdentifierLength ||
            value != value.Trim() ||
            !char.IsLetterOrDigit(value[0]) ||
            value.Any(character =>
                !(char.IsLetterOrDigit(character) ||
                  character is '-' or '_' or '.' or ':')))
        {
            throw new ComplianceDiagnosticExportException(
                $"The compliance diagnostic field {propertyName} must be a bounded canonical identifier.");
        }

        return value.Normalize(NormalizationForm.FormC);
    }

    private static void EnsureObject(JsonElement value, string label)
    {
        if (value.ValueKind != JsonValueKind.Object)
        {
            throw new ComplianceDiagnosticExportException(
                $"The compliance diagnostic {label} must be a JSON object.");
        }
    }

    private static void EnsureArray(JsonElement value, string label)
    {
        if (value.ValueKind != JsonValueKind.Array)
        {
            throw new ComplianceDiagnosticExportException(
                $"The compliance diagnostic {label} must be a JSON array.");
        }
    }

    private static void EnsureUtc(DateTimeOffset value, string propertyName)
    {
        if (value.Offset != TimeSpan.Zero)
        {
            throw new ComplianceDiagnosticExportException(
                $"The compliance diagnostic field {propertyName} must be UTC.");
        }
    }
}
