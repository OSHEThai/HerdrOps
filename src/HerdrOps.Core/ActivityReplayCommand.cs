using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.Json.Serialization;
using HerdrOps.Domain.Activity;

namespace HerdrOps.Core;

public static class ActivityReplayCommand
{
    private const int ReplayFailureExitCode = 2;
    private const int UsageFailureExitCode = 64;
    private const int MaximumInputBytes = 16 * 1024 * 1024;

    private static readonly JsonSerializerOptions InputSerializerOptions = CreateSerializerOptions(
        writeIndented: false,
        rejectUnknownMembers: true);

    private static readonly JsonSerializerOptions OutputSerializerOptions = CreateSerializerOptions(
        writeIndented: true,
        rejectUnknownMembers: false);

    public static int Run(string[] args, TextWriter output, TextWriter error)
    {
        ArgumentNullException.ThrowIfNull(args);
        ArgumentNullException.ThrowIfNull(output);
        ArgumentNullException.ThrowIfNull(error);

        if (!TryParseArguments(args, error, out var inputPath, out var reportPath))
        {
            return UsageFailureExitCode;
        }

        try
        {
            var fullInputPath = Path.GetFullPath(inputPath!);
            var fullReportPath = Path.GetFullPath(reportPath!);
            if (string.Equals(fullInputPath, fullReportPath, StringComparison.OrdinalIgnoreCase))
            {
                throw new ActivityReplayCommandException(
                    "The replay input and report paths must be different files.");
            }

            var inputBytes = ReadBoundedInput(fullInputPath);
            var input = JsonSerializer.Deserialize<ActivityReplayInputDocument>(
                inputBytes,
                InputSerializerOptions) ?? throw new ActivityReplayCommandException(
                    "The activity replay input document cannot be JSON null.");
            if (input.ContractVersion != ActivityReplay.ContractVersion)
            {
                throw new ActivityReplayCommandException(
                    $"Activity replay input contract v{input.ContractVersion} is unsupported; expected v{ActivityReplay.ContractVersion}.");
            }

            if (input.Events is null)
            {
                throw new ActivityReplayCommandException(
                    "The activity replay input document requires an events array.");
            }

            var options = input.Options?.ToDomainOptions() ?? ActivityPipelineOptions.Default;
            var replay = ActivityReplay.Run(input.Events, options);
            var report = new ActivityReplayEvidenceReport(
                ContractVersion: ActivityReplay.ContractVersion,
                EvidenceClass: "Synthetic",
                RuntimeObserved: false,
                InputSha256: Convert.ToHexString(SHA256.HashData(inputBytes)),
                Replay: replay,
                EvidenceBoundary:
                    "Deterministic fixture replay only; this report does not prove an installed Herdr session, Windows process telemetry, file collection, product latency, or release readiness.");
            var reportJson = JsonSerializer.Serialize(report, OutputSerializerOptions) + "\n";
            new AtomicSchemaOutputWriter().Write(
                fullReportPath,
                new UTF8Encoding(encoderShouldEmitUTF8Identifier: false).GetBytes(reportJson));
            output.Write(reportJson);
            return 0;
        }
        catch (Exception exception) when (
            exception is ActivityEventContractException or
                ActivityReplayException or
                ActivityReplayCommandException or
                ArgumentException or
                JsonException or
                IOException or
                NotSupportedException or
                OverflowException or
                UnauthorizedAccessException)
        {
            error.WriteLine($"Activity replay failed: {exception.Message}");
            return ReplayFailureExitCode;
        }
    }

    private static bool TryParseArguments(
        string[] args,
        TextWriter error,
        out string? inputPath,
        out string? reportPath)
    {
        inputPath = null;
        reportPath = null;
        if (args.Length == 0 ||
            !string.Equals(args[0], "activity-replay", StringComparison.Ordinal))
        {
            error.WriteLine(args.Length == 0
                ? "Missing activity replay command."
                : $"Unknown activity replay command: {args[0]}");
            WriteUsage(error);
            return false;
        }

        for (var index = 1; index < args.Length; index++)
        {
            switch (args[index])
            {
                case "--input" when index + 1 < args.Length && inputPath is null:
                    inputPath = args[++index];
                    if (!IsValidPathArgument(inputPath))
                    {
                        error.WriteLine("Option --input requires a non-empty JSON path.");
                        WriteUsage(error);
                        return false;
                    }

                    break;
                case "--report" when index + 1 < args.Length && reportPath is null:
                    reportPath = args[++index];
                    if (!IsValidPathArgument(reportPath))
                    {
                        error.WriteLine("Option --report requires a non-empty JSON path.");
                        WriteUsage(error);
                        return false;
                    }

                    break;
                default:
                    error.WriteLine($"Invalid, duplicate, or incomplete option: {args[index]}");
                    WriteUsage(error);
                    return false;
            }
        }

        if (inputPath is null || reportPath is null)
        {
            error.WriteLine("Both --input and --report are required.");
            WriteUsage(error);
            return false;
        }

        return true;
    }

    private static byte[] ReadBoundedInput(string path)
    {
        using var stream = new FileStream(
            path,
            FileMode.Open,
            FileAccess.Read,
            FileShare.Read,
            bufferSize: 81920,
            FileOptions.SequentialScan);
        if (stream.Length <= 0 || stream.Length > MaximumInputBytes)
        {
            throw new ActivityReplayCommandException(
                $"The activity replay input must contain 1 to {MaximumInputBytes} bytes; observed {stream.Length}.");
        }

        var bytes = new byte[stream.Length];
        stream.ReadExactly(bytes);
        return bytes;
    }

    private static bool IsValidPathArgument(string value) =>
        !string.IsNullOrWhiteSpace(value) &&
        !value.StartsWith("--", StringComparison.Ordinal);

    private static JsonSerializerOptions CreateSerializerOptions(
        bool writeIndented,
        bool rejectUnknownMembers)
    {
        var options = new JsonSerializerOptions
        {
            AllowDuplicateProperties = false,
            PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
            PropertyNameCaseInsensitive = false,
            RespectRequiredConstructorParameters = true,
            UnmappedMemberHandling = rejectUnknownMembers
                ? JsonUnmappedMemberHandling.Disallow
                : JsonUnmappedMemberHandling.Skip,
            WriteIndented = writeIndented,
        };
        options.Converters.Add(new JsonStringEnumConverter(allowIntegerValues: false));
        return options;
    }

    private static void WriteUsage(TextWriter writer) =>
        writer.WriteLine(
            "Usage: HerdrOps.Core activity-replay --input <json-path> --report <json-path>");

    private sealed record ActivityReplayEvidenceReport(
        int ContractVersion,
        string EvidenceClass,
        bool RuntimeObserved,
        string InputSha256,
        ActivityReplayResult Replay,
        string EvidenceBoundary);
}

public sealed record ActivityReplayInputDocument(
    int ContractVersion,
    ActivityReplayInputOptions? Options,
    ActivityEventEnvelope[] Events);

public sealed record ActivityReplayInputOptions(
    int DebounceWindowMilliseconds,
    int MaximumOpenDebounceBuckets,
    int MaximumDeduplicationEntries,
    int MaximumTrackedSourceStreams,
    int MaximumReplayEvents)
{
    public ActivityPipelineOptions ToDomainOptions() => new(
        TimeSpan.FromMilliseconds(DebounceWindowMilliseconds),
        MaximumOpenDebounceBuckets,
        MaximumDeduplicationEntries,
        MaximumTrackedSourceStreams,
        MaximumReplayEvents);
}

public sealed class ActivityReplayCommandException : ArgumentException
{
    public ActivityReplayCommandException(string message)
        : base(message)
    {
    }
}
