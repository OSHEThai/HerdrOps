using System.Security.Cryptography;
using System.Text;
using HerdrOps.Contracts;

namespace HerdrOps.Infrastructure.Herdr;

public enum HerdrBundledSchemaCaptureStatus
{
    NotRequested,
    Complete,
    NotFound,
    Truncated,
    TooLarge,
    Malformed,
}

public enum HerdrExecutableAdmissionScanFailure
{
    NotFound,
    Unreadable,
}

public sealed class HerdrExecutableAdmissionScanException : IOException
{
    public HerdrExecutableAdmissionScanException(
        HerdrExecutableAdmissionScanFailure failure,
        string requestedPath,
        string? finalPath,
        string? releaseId,
        long? length,
        string message,
        Exception? innerException = null)
        : base(message, innerException)
    {
        Failure = failure;
        RequestedPath = requestedPath;
        FinalPath = finalPath;
        ReleaseId = releaseId;
        Length = length;
    }

    public HerdrExecutableAdmissionScanFailure Failure { get; }

    public string RequestedPath { get; }

    public string? FinalPath { get; }

    public string? ReleaseId { get; }

    public long? Length { get; }
}

/// <summary>
/// One final-path-bound streaming observation used by runtime binary and
/// bundled-schema admission. Only the bounded schema document is retained.
/// </summary>
public sealed record HerdrExecutableAdmissionSnapshot(
    string RequestedPath,
    string FinalPath,
    string ReleaseId,
    long Length,
    string Sha256,
    bool HasMzHeader,
    IReadOnlySet<string> FoundAsciiMarkers,
    IReadOnlyList<long> SchemaStartOffsets,
    byte[]? SchemaDocumentBytes,
    HerdrBundledSchemaCaptureStatus SchemaCaptureStatus,
    string SchemaCaptureMessage);

public interface IHerdrExecutableAdmissionScanner
{
    HerdrExecutableAdmissionSnapshot Scan(
        string executablePath,
        HerdrProtocolSupportPolicy policy,
        bool captureBundledSchema);
}

public sealed class HerdrExecutableAdmissionScanner : IHerdrExecutableAdmissionScanner
{
    public const long MaximumExecutableBytes = 128L * 1024 * 1024;
    public const int MaximumSchemaBytes = 4 * 1024 * 1024;
    private const int ReadBufferBytes = 81920;
    private static readonly byte[][] SchemaStartMarkers =
    [
        Encoding.ASCII.GetBytes("{\n  \"$schema\":"),
        Encoding.ASCII.GetBytes("{\r\n  \"$schema\":"),
    ];

    public HerdrExecutableAdmissionSnapshot Scan(
        string executablePath,
        HerdrProtocolSupportPolicy policy,
        bool captureBundledSchema)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(executablePath);
        ArgumentNullException.ThrowIfNull(policy);

        var requestedPath = Path.GetFullPath(executablePath);
        if (!File.Exists(requestedPath))
        {
            throw new HerdrExecutableAdmissionScanException(
                HerdrExecutableAdmissionScanFailure.NotFound,
                requestedPath,
                finalPath: null,
                releaseId: null,
                length: null,
                $"Herdr executable was not found: {requestedPath}");
        }
        var requiredMarkers = policy.RequiredRpcMethods
            .Concat(policy.RequiredShapes.Select(shape => shape.BinaryMarker))
            .Concat(policy.RequiredTransportMarkers)
            .Distinct(StringComparer.Ordinal)
            .ToDictionary(
                marker => marker,
                Encoding.ASCII.GetBytes,
                StringComparer.Ordinal);
        if (requiredMarkers.Any(marker => marker.Value.Length == 0))
        {
            throw new ArgumentException(
                "Herdr protocol markers cannot be empty.",
                nameof(policy));
        }

        var maximumPatternLength = requiredMarkers.Values
            .Select(marker => marker.Length)
            .Concat(captureBundledSchema
                ? SchemaStartMarkers.Select(marker => marker.Length)
                : [])
            .DefaultIfEmpty(1)
            .Max();
        var overlapCapacity = maximumPatternLength - 1;
        var buffer = new byte[checked(ReadBufferBytes + overlapCapacity)];
        var foundMarkers = new HashSet<string>(StringComparer.Ordinal);
        var schemaStarts = new List<long>(capacity: 2);
        SchemaCapture? schemaCapture = null;
        long totalRead = 0;
        var carry = 0;
        byte? firstByte = null;
        byte? secondByte = null;
        string? failureFinalPath = null;
        string? failureReleaseId = null;
        long? failureLength = null;

        try
        {
            using var stream = new FileStream(
                requestedPath,
                FileMode.Open,
                FileAccess.Read,
                FileShare.Read,
                ReadBufferBytes,
                FileOptions.SequentialScan);
            var length = stream.Length;
            failureLength = length;
            var finalPath = HerdrExecutableSnapshotReader.GetFinalDosPath(stream.SafeFileHandle);
            failureFinalPath = finalPath;
            var releaseId = new FileInfo(finalPath).Directory?.Name ?? string.Empty;
            failureReleaseId = releaseId;
            if (length is < 2 or > MaximumExecutableBytes)
            {
                throw new HerdrExecutableAdmissionScanException(
                    HerdrExecutableAdmissionScanFailure.Unreadable,
                    requestedPath,
                    finalPath,
                    releaseId,
                    length,
                    $"Herdr executable length {length} is outside the accepted admission bounds.");
            }

            using var hash = IncrementalHash.CreateHash(HashAlgorithmName.SHA256);
            while (true)
            {
                var read = stream.Read(buffer, carry, ReadBufferBytes);
                if (read == 0)
                {
                    break;
                }

                var newBytes = buffer.AsSpan(carry, read);
                hash.AppendData(newBytes);
                if (firstByte is null && newBytes.Length > 0)
                {
                    firstByte = newBytes[0];
                    if (newBytes.Length > 1)
                    {
                        secondByte = newBytes[1];
                    }
                }
                else if (secondByte is null && newBytes.Length > 0)
                {
                    secondByte = newBytes[0];
                }

                var segmentLength = carry + read;
                var segment = buffer.AsSpan(0, segmentLength);
                var segmentStartOffset = totalRead - carry;
                foreach (var marker in requiredMarkers)
                {
                    if (!foundMarkers.Contains(marker.Key) &&
                        segment.IndexOf(marker.Value) >= 0)
                    {
                        foundMarkers.Add(marker.Key);
                    }
                }

                if (captureBundledSchema)
                {
                    if (schemaStarts.Count < 2)
                    {
                        foreach (var marker in SchemaStartMarkers)
                        {
                            AddSchemaStartOffsets(
                                segment,
                                marker,
                                segmentStartOffset,
                                schemaStarts);
                            if (schemaStarts.Count >= 2)
                            {
                                break;
                            }
                        }
                    }

                    if (schemaCapture is null && schemaStarts.Count > 0)
                    {
                        var firstStart = schemaStarts.Min();
                        var relativeStart = checked((int)(firstStart - segmentStartOffset));
                        if (relativeStart >= 0 && relativeStart < segmentLength)
                        {
                            schemaCapture = new SchemaCapture(MaximumSchemaBytes);
                            schemaCapture.Append(segment[relativeStart..]);
                        }
                    }
                    else if (schemaCapture is { IsTerminal: false })
                    {
                        schemaCapture.Append(buffer.AsSpan(carry, read));
                    }
                }

                totalRead += read;
                carry = Math.Min(overlapCapacity, segmentLength);
                if (carry > 0)
                {
                    buffer.AsSpan(segmentLength - carry, carry).CopyTo(buffer);
                }
            }

            if (totalRead != length || stream.Position != length || stream.Length != length)
            {
                throw new IOException(
                    "Herdr executable length changed while the admission handle was open.");
            }

            var schemaResult = CompleteSchemaCapture(
                captureBundledSchema,
                length,
                schemaStarts,
                schemaCapture);
            return new HerdrExecutableAdmissionSnapshot(
                requestedPath,
                finalPath,
                releaseId,
                length,
                Convert.ToHexString(hash.GetHashAndReset()),
                firstByte == (byte)'M' && secondByte == (byte)'Z',
                foundMarkers,
                schemaStarts.Order().ToArray(),
                schemaResult.Bytes,
                schemaResult.Status,
                schemaResult.Message);
        }
        catch (HerdrExecutableAdmissionScanException)
        {
            throw;
        }
        catch (FileNotFoundException exception)
        {
            throw new HerdrExecutableAdmissionScanException(
                HerdrExecutableAdmissionScanFailure.NotFound,
                requestedPath,
                failureFinalPath,
                failureReleaseId,
                failureLength,
                $"Herdr executable was not found: {requestedPath}",
                exception);
        }
        catch (Exception exception) when (
            exception is IOException or UnauthorizedAccessException)
        {
            throw new HerdrExecutableAdmissionScanException(
                HerdrExecutableAdmissionScanFailure.Unreadable,
                requestedPath,
                failureFinalPath,
                failureReleaseId,
                failureLength,
                $"Herdr executable could not be read: {exception.Message}",
                exception);
        }
    }

    private static void AddSchemaStartOffsets(
        ReadOnlySpan<byte> segment,
        ReadOnlySpan<byte> marker,
        long segmentStartOffset,
        IList<long> offsets)
    {
        var searchOffset = 0;
        while (searchOffset <= segment.Length - marker.Length)
        {
            var relative = segment[searchOffset..].IndexOf(marker);
            if (relative < 0)
            {
                return;
            }

            var index = searchOffset + relative;
            var absoluteOffset = segmentStartOffset + index;
            if (!offsets.Contains(absoluteOffset) && offsets.Count < 2)
            {
                offsets.Add(absoluteOffset);
                if (offsets.Count >= 2)
                {
                    return;
                }
            }
            searchOffset = index + 1;
        }
    }

    private static SchemaCaptureResult CompleteSchemaCapture(
        bool requested,
        long executableLength,
        IReadOnlyCollection<long> schemaStarts,
        SchemaCapture? capture)
    {
        if (!requested)
        {
            return new SchemaCaptureResult(
                HerdrBundledSchemaCaptureStatus.NotRequested,
                null,
                "Bundled schema capture was not requested.");
        }

        if (schemaStarts.Count == 0 || capture is null)
        {
            return new SchemaCaptureResult(
                HerdrBundledSchemaCaptureStatus.NotFound,
                null,
                "The bundled JSON Schema start marker was not found in the admitted executable.");
        }

        if (capture.Malformed)
        {
            return new SchemaCaptureResult(
                HerdrBundledSchemaCaptureStatus.Malformed,
                null,
                "Bundled schema closed before its root object was balanced.");
        }

        if (capture.Complete)
        {
            return new SchemaCaptureResult(
                HerdrBundledSchemaCaptureStatus.Complete,
                capture.ToArray(),
                string.Empty);
        }

        var status = schemaStarts.Min() + MaximumSchemaBytes < executableLength
            ? HerdrBundledSchemaCaptureStatus.TooLarge
            : HerdrBundledSchemaCaptureStatus.Truncated;
        return status == HerdrBundledSchemaCaptureStatus.TooLarge
            ? new SchemaCaptureResult(
                status,
                null,
                $"Bundled schema exceeds the {MaximumSchemaBytes}-byte extraction limit.")
            : new SchemaCaptureResult(
                status,
                null,
                "Bundled schema ended before its root JSON object was balanced.");
    }

    private sealed class SchemaCapture(int maximumBytes)
    {
        private readonly MemoryStream _bytes = new(capacity: Math.Min(maximumBytes, 512 * 1024));
        private int _depth;
        private bool _inString;
        private bool _escaped;

        public bool Complete { get; private set; }

        public bool Malformed { get; private set; }

        public bool IsTerminal => Complete || Malformed || _bytes.Length >= maximumBytes;

        public void Append(ReadOnlySpan<byte> source)
        {
            foreach (var current in source)
            {
                if (IsTerminal)
                {
                    return;
                }

                _bytes.WriteByte(current);
                if (_inString)
                {
                    if (_escaped)
                    {
                        _escaped = false;
                    }
                    else if (current == (byte)'\\')
                    {
                        _escaped = true;
                    }
                    else if (current == (byte)'"')
                    {
                        _inString = false;
                    }

                    continue;
                }

                if (current == (byte)'"')
                {
                    _inString = true;
                }
                else if (current == (byte)'{')
                {
                    _depth++;
                }
                else if (current == (byte)'}')
                {
                    _depth--;
                    if (_depth == 0)
                    {
                        Complete = true;
                    }
                    else if (_depth < 0)
                    {
                        Malformed = true;
                    }
                }
            }
        }

        public byte[] ToArray() => _bytes.ToArray();
    }

    private sealed record SchemaCaptureResult(
        HerdrBundledSchemaCaptureStatus Status,
        byte[]? Bytes,
        string Message);
}
