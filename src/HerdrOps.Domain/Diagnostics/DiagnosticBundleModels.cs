using System.Collections.ObjectModel;

namespace HerdrOps.Domain.Diagnostics;

public static class DiagnosticBundleSchema
{
    public const string BundleVersion = "v0.7.diagnostic-bundle.v1";
    public const string ManifestVersion = "v0.7.diagnostic-manifest.v1";
    public const string CrashMetadataVersion = "v0.7.crash-metadata.v1";

    public const string PayloadFileName = "payload.json";
    public const string CrashMetadataFileName = "crash-metadata.json";
    public const string ManifestFileName = "manifest.json";
}

public enum DiagnosticBundleEntryKind
{
    ApplicationState = 1,
    LogExcerpt = 2,
    EnvironmentExcerpt = 3,
    CommandLine = 4,
    Url = 5,
    Headers = 6,
    Metadata = 7,
}

public enum DiagnosticCrashCategory
{
    Unknown = 0,
    Startup = 1,
    Dispatcher = 2,
    Background = 3,
    Unhandled = 4,
}

public sealed record DiagnosticRedactionOptions
{
    public DiagnosticRedactionOptions(IEnumerable<string>? configuredSecrets = null)
    {
        var values = (configuredSecrets ?? []).ToArray();
        if (values.Length > 64)
        {
            throw new ArgumentOutOfRangeException(
                nameof(configuredSecrets),
                "A diagnostic bundle accepts at most 64 configured secret values.");
        }

        foreach (var value in values)
        {
            if (string.IsNullOrEmpty(value) || value.Length > 4096 || value.Any(char.IsControl))
            {
                throw new ArgumentException(
                    "Configured diagnostic secrets must be non-empty, bounded, and free of control characters.",
                    nameof(configuredSecrets));
            }
        }

        ConfiguredSecrets = new ReadOnlyCollection<string>(
            values
                .Distinct(StringComparer.Ordinal)
                .OrderByDescending(value => value.Length)
                .ThenBy(value => value, StringComparer.Ordinal)
                .ToArray());
    }

    public IReadOnlyList<string> ConfiguredSecrets { get; }

    public int MaximumInputUtf8Bytes { get; init; } = 64 * 1024;

    public int MaximumStringUtf8Bytes { get; init; } = 8 * 1024;

    public int MaximumCrashMessageUtf8Bytes { get; init; } = 2 * 1024;

    public int MaximumCrashStackUtf8Bytes { get; init; } = 4 * 1024;

    public void Validate()
    {
        if (MaximumInputUtf8Bytes is < 1024 or > 1024 * 1024)
        {
            throw new ArgumentOutOfRangeException(
                nameof(MaximumInputUtf8Bytes),
                "The diagnostic redaction input bound must be between 1 KiB and 1 MiB.");
        }

        if (MaximumStringUtf8Bytes < 128 || MaximumStringUtf8Bytes > MaximumInputUtf8Bytes)
        {
            throw new ArgumentOutOfRangeException(
                nameof(MaximumStringUtf8Bytes),
                "The diagnostic string bound must be at least 128 bytes and no greater than the input bound.");
        }

        if (MaximumCrashMessageUtf8Bytes < 128 || MaximumCrashMessageUtf8Bytes > MaximumStringUtf8Bytes)
        {
            throw new ArgumentOutOfRangeException(
                nameof(MaximumCrashMessageUtf8Bytes),
                "The crash message bound must be between 128 bytes and the diagnostic string bound.");
        }

        if (MaximumCrashStackUtf8Bytes < 128 || MaximumCrashStackUtf8Bytes > MaximumStringUtf8Bytes)
        {
            throw new ArgumentOutOfRangeException(
                nameof(MaximumCrashStackUtf8Bytes),
                "The crash stack bound must be between 128 bytes and the diagnostic string bound.");
        }
    }
}

public sealed record DiagnosticBundleLimits
{
    public int MaximumEntries { get; init; } = 64;

    public int MaximumCrashRecords { get; init; } = 8;

    public int MaximumMetadataDepth { get; init; } = 6;

    public int MaximumMetadataNodes { get; init; } = 256;

    public int MaximumMetadataPropertiesPerObject { get; init; } = 32;

    public int MaximumMetadataItemsPerArray { get; init; } = 32;

    public int MaximumPayloadBytes { get; init; } = 128 * 1024;

    public int MaximumCrashMetadataBytes { get; init; } = 64 * 1024;

    public int MaximumBundleBytes { get; init; } = 256 * 1024;

    public void Validate()
    {
        if (MaximumEntries is < 1 or > 256)
        {
            throw new ArgumentOutOfRangeException(nameof(MaximumEntries));
        }

        if (MaximumCrashRecords is < 0 or > 32)
        {
            throw new ArgumentOutOfRangeException(nameof(MaximumCrashRecords));
        }

        if (MaximumMetadataDepth is < 1 or > 12)
        {
            throw new ArgumentOutOfRangeException(nameof(MaximumMetadataDepth));
        }

        if (MaximumMetadataNodes is < 1 or > 4096)
        {
            throw new ArgumentOutOfRangeException(nameof(MaximumMetadataNodes));
        }

        if (MaximumMetadataPropertiesPerObject is < 1 or > 256)
        {
            throw new ArgumentOutOfRangeException(nameof(MaximumMetadataPropertiesPerObject));
        }

        if (MaximumMetadataItemsPerArray is < 1 or > 256)
        {
            throw new ArgumentOutOfRangeException(nameof(MaximumMetadataItemsPerArray));
        }

        if (MaximumPayloadBytes is < 1024 or > 4 * 1024 * 1024)
        {
            throw new ArgumentOutOfRangeException(nameof(MaximumPayloadBytes));
        }

        if (MaximumCrashMetadataBytes < 512 || MaximumCrashMetadataBytes > MaximumPayloadBytes)
        {
            throw new ArgumentOutOfRangeException(nameof(MaximumCrashMetadataBytes));
        }

        if (MaximumBundleBytes < MaximumPayloadBytes || MaximumBundleBytes > 8 * 1024 * 1024)
        {
            throw new ArgumentOutOfRangeException(nameof(MaximumBundleBytes));
        }
    }
}

/// <summary>
/// Caller-supplied, already-selected diagnostic data. The contract intentionally has no
/// environment reader, file reader, terminal reader, socket reader, or dump collector.
/// </summary>
public sealed record DiagnosticBundleRequest(
    string AppVersion,
    string ProcessVersion,
    DateTimeOffset CapturedAtUtc,
    IReadOnlyList<DiagnosticBundleEntry>? Entries = null,
    IReadOnlyList<CrashMetadata>? Crashes = null);

public sealed record DiagnosticBundleEntry(
    DiagnosticBundleEntryKind Kind,
    string Name,
    string? Text = null,
    IReadOnlyDictionary<string, object?>? Metadata = null);

/// <summary>
/// Crash metadata is deliberately a summary only. No dump, exception object, raw process
/// environment, or terminal content can be represented by this contract.
/// </summary>
public sealed record CrashMetadata(
    DateTimeOffset TimestampUtc,
    string ExceptionType,
    DiagnosticCrashCategory Category,
    string Message,
    string StackSummary,
    string AppVersion,
    string ProcessVersion);

public sealed record DiagnosticBundleArtifact(
    string FileName,
    byte[] Content,
    string Sha256)
{
    public int ByteCount => Content.Length;
}

public sealed class DiagnosticBundlePackage
{
    public DiagnosticBundlePackage(
        IReadOnlyList<DiagnosticBundleArtifact> artifacts,
        int entryCount,
        int crashCount,
        int totalBytes,
        string manifestSha256)
    {
        Artifacts = artifacts;
        EntryCount = entryCount;
        CrashCount = crashCount;
        TotalBytes = totalBytes;
        ManifestSha256 = manifestSha256;
    }

    public IReadOnlyList<DiagnosticBundleArtifact> Artifacts { get; }

    public int EntryCount { get; }

    public int CrashCount { get; }

    public int TotalBytes { get; }

    public string ManifestSha256 { get; }
}

public sealed record DiagnosticBundlePublishOptions(
    string OutputRoot,
    string BundleDirectoryName);

public sealed record DiagnosticBundlePublishResult(
    string BundleDirectoryPath,
    IReadOnlyList<string> ArtifactPaths,
    string ManifestSha256,
    int TotalBytes);
