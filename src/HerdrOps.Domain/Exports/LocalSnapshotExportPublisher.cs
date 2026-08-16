using System.Security.Cryptography;
using System.Text;

namespace HerdrOps.Domain.Exports;

public enum SnapshotExportPublicationPhase
{
    StagingDirectoryCreated = 1,
    FilesWritten = 2,
    BeforeCommit = 3,
}

public sealed record LocalSnapshotExportPublication(
    string DirectoryPath,
    string JsonPath,
    string MarkdownPath,
    string CsvPath,
    string ManifestPath,
    SnapshotExportManifest Manifest);

public sealed class LocalSnapshotExportPublisher
{
    private readonly Action<SnapshotExportPublicationPhase>? _phaseObserver;

    public LocalSnapshotExportPublisher(
        Action<SnapshotExportPublicationPhase>? phaseObserver = null)
    {
        _phaseObserver = phaseObserver;
    }

    public LocalSnapshotExportPublication Publish(
        DeterministicSnapshotExport export,
        string destinationDirectory)
    {
        ArgumentNullException.ThrowIfNull(export);
        if (string.IsNullOrWhiteSpace(destinationDirectory))
        {
            throw new SnapshotExportException("The local export destination is required.");
        }

        ValidateExport(export);
        string destination;
        try
        {
            destination = Path.GetFullPath(destinationDirectory);
            Directory.CreateDirectory(destination);
        }
        catch (Exception exception) when (exception is ArgumentException or IOException or UnauthorizedAccessException)
        {
            throw new SnapshotExportException(
                "The local export destination could not be prepared.",
                exception);
        }

        var directoryName = $"herdops-{export.Kind.ToString().ToLowerInvariant()}-{export.ExportId}";
        var finalDirectory = Path.Combine(destination, directoryName);
        if (Directory.Exists(finalDirectory) || File.Exists(finalDirectory))
        {
            throw new SnapshotExportException(
                "The local export already exists and will not be overwritten.");
        }

        var stagingDirectory = Path.Combine(
            destination,
            $".{directoryName}.staging-{Guid.NewGuid():N}");
        var committed = false;
        try
        {
            Directory.CreateDirectory(stagingDirectory);
            _phaseObserver?.Invoke(SnapshotExportPublicationPhase.StagingDirectoryCreated);

            var jsonPath = Path.Combine(stagingDirectory, "snapshot.json");
            var markdownPath = Path.Combine(stagingDirectory, "snapshot.md");
            var csvPath = Path.Combine(stagingDirectory, "snapshot.csv");
            var manifestPath = Path.Combine(stagingDirectory, "manifest.json");
            WriteUtf8(jsonPath, export.Json, expectCrLf: false);
            WriteUtf8(markdownPath, export.Markdown, expectCrLf: false);
            WriteUtf8(csvPath, export.Csv, expectCrLf: true);
            WriteUtf8(
                manifestPath,
                DeterministicSnapshotExporter.SerializeManifest(export.Manifest),
                expectCrLf: false);
            ValidateStagedFiles(export, jsonPath, markdownPath, csvPath, manifestPath);
            _phaseObserver?.Invoke(SnapshotExportPublicationPhase.FilesWritten);
            _phaseObserver?.Invoke(SnapshotExportPublicationPhase.BeforeCommit);

            Directory.Move(stagingDirectory, finalDirectory);
            committed = true;
            return new LocalSnapshotExportPublication(
                finalDirectory,
                Path.Combine(finalDirectory, "snapshot.json"),
                Path.Combine(finalDirectory, "snapshot.md"),
                Path.Combine(finalDirectory, "snapshot.csv"),
                Path.Combine(finalDirectory, "manifest.json"),
                export.Manifest);
        }
        catch (SnapshotExportException)
        {
            throw;
        }
        catch (Exception exception)
        {
            throw new SnapshotExportException(
                "The local export publication failed before atomic commit.",
                exception);
        }
        finally
        {
            if (!committed && Directory.Exists(stagingDirectory))
            {
                try
                {
                    Directory.Delete(stagingDirectory, recursive: true);
                }
                catch
                {
                    // Preserve the original failure; the staging path is never published.
                }
            }
        }
    }

    private static void ValidateExport(DeterministicSnapshotExport export)
    {
        if (export.Manifest is null ||
            !string.Equals(export.Manifest.ExportId, export.ExportId, StringComparison.Ordinal) ||
            !string.Equals(
                export.Manifest.SourceSnapshotSha256,
                export.SourceSnapshotSha256,
                StringComparison.Ordinal) ||
            !string.Equals(export.Manifest.JsonSha256, export.JsonSha256, StringComparison.Ordinal) ||
            !string.Equals(export.Manifest.MarkdownSha256, export.MarkdownSha256, StringComparison.Ordinal) ||
            !string.Equals(export.Manifest.CsvSha256, export.CsvSha256, StringComparison.Ordinal) ||
            !IsSha256(export.ExportId) ||
            !IsSha256(export.SourceSnapshotSha256))
        {
            throw new SnapshotExportException("The local export manifest identity is inconsistent.");
        }

        var jsonBytes = Encoding.UTF8.GetBytes(export.Json);
        var markdownBytes = Encoding.UTF8.GetBytes(export.Markdown);
        var csvBytes = Encoding.UTF8.GetBytes(export.Csv);
        var totalBytes = (long)jsonBytes.Length + markdownBytes.Length + csvBytes.Length;
        if (jsonBytes.Length != export.Manifest.JsonByteLength ||
            markdownBytes.Length != export.Manifest.MarkdownByteLength ||
            csvBytes.Length != export.Manifest.CsvByteLength ||
            totalBytes != export.Manifest.TotalByteLength ||
            totalBytes > DeterministicSnapshotExporter.MaximumTotalOutputBytes ||
            !string.Equals(Sha256(jsonBytes), export.JsonSha256, StringComparison.Ordinal) ||
            !string.Equals(Sha256(markdownBytes), export.MarkdownSha256, StringComparison.Ordinal) ||
            !string.Equals(Sha256(csvBytes), export.CsvSha256, StringComparison.Ordinal))
        {
            throw new SnapshotExportException("The local export bytes do not reconcile to their manifest.");
        }

        if (jsonBytes.Length >= 3 &&
            jsonBytes[..3].SequenceEqual(new byte[] { 0xEF, 0xBB, 0xBF }) ||
            markdownBytes.Length >= 3 &&
            markdownBytes[..3].SequenceEqual(new byte[] { 0xEF, 0xBB, 0xBF }) ||
            csvBytes.Length >= 3 &&
            csvBytes[..3].SequenceEqual(new byte[] { 0xEF, 0xBB, 0xBF }) ||
            export.Json.Contains('\r') ||
            export.Markdown.Contains('\r') ||
            !export.Csv.EndsWith("\r\n", StringComparison.Ordinal))
        {
            throw new SnapshotExportException("The local export encoding or newline contract is invalid.");
        }
    }

    private static void WriteUtf8(string path, string content, bool expectCrLf)
    {
        var bytes = new UTF8Encoding(encoderShouldEmitUTF8Identifier: false).GetBytes(content);
        if ((!expectCrLf && content.Contains('\r')) ||
            (expectCrLf && !content.EndsWith("\r\n", StringComparison.Ordinal)))
        {
            throw new SnapshotExportException("The local export contains an invalid newline sequence.");
        }

        using var stream = new FileStream(
            path,
            FileMode.CreateNew,
            FileAccess.Write,
            FileShare.None,
            bufferSize: 64 * 1024,
            FileOptions.SequentialScan | FileOptions.WriteThrough);
        stream.Write(bytes);
        stream.Flush(flushToDisk: true);
    }

    private static void ValidateStagedFiles(
        DeterministicSnapshotExport export,
        string jsonPath,
        string markdownPath,
        string csvPath,
        string manifestPath)
    {
        var jsonBytes = File.ReadAllBytes(jsonPath);
        var markdownBytes = File.ReadAllBytes(markdownPath);
        var csvBytes = File.ReadAllBytes(csvPath);
        var manifestJson = File.ReadAllText(manifestPath, new UTF8Encoding(false));
        var expectedManifestJson = DeterministicSnapshotExporter.SerializeManifest(export.Manifest);
        if (!string.Equals(manifestJson, expectedManifestJson, StringComparison.Ordinal) ||
            !string.Equals(Sha256(jsonBytes), export.JsonSha256, StringComparison.Ordinal) ||
            !string.Equals(Sha256(markdownBytes), export.MarkdownSha256, StringComparison.Ordinal) ||
            !string.Equals(Sha256(csvBytes), export.CsvSha256, StringComparison.Ordinal))
        {
            throw new SnapshotExportException(
                "The staged local export failed reread and hash validation.");
        }
    }

    private static bool IsSha256(string? value) =>
        value is { Length: 64 } && value.All(Uri.IsHexDigit);

    private static string Sha256(byte[] bytes) =>
        Convert.ToHexString(SHA256.HashData(bytes));
}
