using System.Globalization;
using System.Security;
using System.Text.Json;
using HerdrOps.Domain.Diagnostics;
using HerdrOps.Infrastructure.Diagnostics;

namespace HerdrOps.Core;

public static class DiagnosticBundleCommand
{
    public const string CommandName = "diagnostic-bundle";
    public const int SuccessExitCode = 0;
    public const int FailureExitCode = 2;
    public const int UsageFailureExitCode = 64;

    public static int Run(string[] args, TextWriter output, TextWriter error)
    {
        ArgumentNullException.ThrowIfNull(args);
        ArgumentNullException.ThrowIfNull(output);
        ArgumentNullException.ThrowIfNull(error);

        if (args.Length == 2 && string.Equals(args[1], "--help", StringComparison.Ordinal))
        {
            WriteUsage(output);
            return SuccessExitCode;
        }

        if (!TryParseArguments(args, error, out var parsed))
        {
            return UsageFailureExitCode;
        }

        try
        {
            var request = parsed!.CreateRequest();
            var publisher = new DiagnosticBundlePublisher(
                new DiagnosticBundleBuilder(parsed.CreateRedactionOptions()));
            var published = publisher.Publish(
                request,
                new DiagnosticBundlePublishOptions(parsed.OutputRoot, parsed.BundleDirectoryName));
            output.WriteLine(JsonSerializer.Serialize(new DiagnosticBundleCommandResult(
                DiagnosticBundleSchema.BundleVersion,
                published.BundleDirectoryPath,
                published.ArtifactPaths,
                request.Entries?.Count ?? 0,
                request.Crashes?.Count ?? 0,
                published.TotalBytes,
                published.ManifestSha256)));
            return SuccessExitCode;
        }
        catch (Exception exception) when (
            exception is ArgumentException or
                IOException or
                InvalidOperationException or
                NotSupportedException or
                SecurityException or
                UnauthorizedAccessException)
        {
            error.WriteLine($"Diagnostic bundle publication failed: {exception.Message}");
            return FailureExitCode;
        }
    }

    private static bool TryParseArguments(
        string[] args,
        TextWriter error,
        out ParsedDiagnosticBundle? parsed)
    {
        parsed = null;
        if (args.Length == 0 || !string.Equals(args[0], CommandName, StringComparison.Ordinal))
        {
            error.WriteLine("The diagnostic bundle command name is required.");
            WriteUsage(error);
            return false;
        }

        string? outputRoot = null;
        string? bundleDirectoryName = null;
        string? appVersion = null;
        string? processVersion = null;
        var capturedAtUtc = DateTimeOffset.UtcNow;
        var capturedAtWasProvided = false;
        var secrets = new List<string>();
        var summaries = new List<string>();
        var crashes = new List<ParsedCrash>();

        for (var index = 1; index < args.Length; index++)
        {
            switch (args[index])
            {
                case "--output-root" when index + 1 < args.Length && outputRoot is null:
                    outputRoot = args[++index];
                    break;
                case "--bundle-name" when index + 1 < args.Length && bundleDirectoryName is null:
                    bundleDirectoryName = args[++index];
                    break;
                case "--app-version" when index + 1 < args.Length && appVersion is null:
                    appVersion = args[++index];
                    break;
                case "--process-version" when index + 1 < args.Length && processVersion is null:
                    processVersion = args[++index];
                    break;
                case "--captured-at-utc" when index + 1 < args.Length && !capturedAtWasProvided:
                    if (!TryParseUtc(args[++index], out capturedAtUtc))
                    {
                        error.WriteLine("Option --captured-at-utc must be an ISO-8601 UTC timestamp.");
                        WriteUsage(error);
                        return false;
                    }

                    capturedAtWasProvided = true;
                    break;
                case "--secret" when index + 1 < args.Length:
                    secrets.Add(args[++index]);
                    break;
                case "--summary" when index + 1 < args.Length:
                    summaries.Add(args[++index]);
                    break;
                case "--crash" when index + 5 < args.Length:
                    if (!TryParseCrash(args, ref index, error, out var crash))
                    {
                        WriteUsage(error);
                        return false;
                    }

                    crashes.Add(crash);
                    break;
                default:
                    error.WriteLine($"Invalid, duplicate, or incomplete diagnostic bundle option: {args[index]}");
                    WriteUsage(error);
                    return false;
            }
        }

        if (string.IsNullOrWhiteSpace(outputRoot) ||
            string.IsNullOrWhiteSpace(bundleDirectoryName) ||
            string.IsNullOrWhiteSpace(appVersion) ||
            string.IsNullOrWhiteSpace(processVersion))
        {
            error.WriteLine("Options --output-root, --bundle-name, --app-version, and --process-version are required.");
            WriteUsage(error);
            return false;
        }

        if (secrets.Any(string.IsNullOrEmpty) || summaries.Any(string.IsNullOrEmpty))
        {
            error.WriteLine("Options --secret and --summary require non-empty values.");
            WriteUsage(error);
            return false;
        }

        parsed = new ParsedDiagnosticBundle(
            outputRoot,
            bundleDirectoryName,
            appVersion,
            processVersion,
            capturedAtUtc,
            secrets,
            summaries,
            crashes);
        return true;
    }

    private static bool TryParseCrash(
        string[] args,
        ref int index,
        TextWriter error,
        out ParsedCrash crash)
    {
        crash = default;
        var timestampText = args[++index];
        var exceptionType = args[++index];
        var categoryText = args[++index];
        var message = args[++index];
        var stackSummary = args[++index];

        if (!TryParseUtc(timestampText, out var timestampUtc))
        {
            error.WriteLine("The --crash timestamp must be an ISO-8601 UTC timestamp.");
            return false;
        }

        if (!Enum.TryParse<DiagnosticCrashCategory>(categoryText, ignoreCase: true, out var category) ||
            !Enum.IsDefined(category) ||
            string.IsNullOrWhiteSpace(exceptionType) ||
            string.IsNullOrWhiteSpace(message) ||
            string.IsNullOrWhiteSpace(stackSummary))
        {
            error.WriteLine("The --crash values must be <utc> <exception-type> <category> <message> <stack-summary>.");
            return false;
        }

        crash = new ParsedCrash(timestampUtc, exceptionType, category, message, stackSummary);
        return true;
    }

    private static bool TryParseUtc(string value, out DateTimeOffset timestampUtc)
    {
        return DateTimeOffset.TryParse(
                   value,
                   CultureInfo.InvariantCulture,
                   DateTimeStyles.RoundtripKind,
                   out timestampUtc) &&
               timestampUtc.Offset == TimeSpan.Zero;
    }

    private static void WriteUsage(TextWriter writer) =>
        writer.WriteLine(
            "Usage: HerdrOps.Core diagnostic-bundle --output-root <existing-absolute-directory> --bundle-name <safe-name> --app-version <value> --process-version <value> [--captured-at-utc <UTC>] [--secret <value>] [--summary <text>] [--crash <UTC> <exception-type> <category> <message> <stack-summary>]...");

    private sealed record ParsedDiagnosticBundle(
        string OutputRoot,
        string BundleDirectoryName,
        string AppVersion,
        string ProcessVersion,
        DateTimeOffset CapturedAtUtc,
        IReadOnlyList<string> Secrets,
        IReadOnlyList<string> Summaries,
        IReadOnlyList<ParsedCrash> Crashes)
    {
        public DiagnosticBundleRequest CreateRequest() =>
            new(
                AppVersion,
                ProcessVersion,
                CapturedAtUtc,
                Summaries
                    .Select((summary, index) => new DiagnosticBundleEntry(
                        DiagnosticBundleEntryKind.LogExcerpt,
                        $"operator-summary-{index + 1:D2}",
                        summary))
                    .ToArray(),
                Crashes
                    .Select(crash => new CrashMetadata(
                        crash.TimestampUtc,
                        crash.ExceptionType,
                        crash.Category,
                        crash.Message,
                        crash.StackSummary,
                        AppVersion,
                        ProcessVersion))
                    .ToArray());

        public DiagnosticRedactionOptions CreateRedactionOptions() =>
            new(Secrets);
    }

    private readonly record struct ParsedCrash(
        DateTimeOffset TimestampUtc,
        string ExceptionType,
        DiagnosticCrashCategory Category,
        string Message,
        string StackSummary);
}

public sealed record DiagnosticBundleCommandResult(
    string SchemaVersion,
    string BundleDirectoryPath,
    IReadOnlyList<string> ArtifactPaths,
    int EntryCount,
    int CrashCount,
    int TotalBytes,
    string ManifestSha256);
