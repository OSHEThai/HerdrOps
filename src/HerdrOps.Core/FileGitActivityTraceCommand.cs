using System.Collections.Concurrent;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.Json.Serialization;
using HerdrOps.Domain.Activity;
using HerdrOps.Infrastructure.Activity;

namespace HerdrOps.Core;

public sealed record FileGitActivityTraceReport(
    int ContractVersion,
    string EvidenceClassification,
    bool RuntimeObserved,
    bool FileSystemWatcherObserved,
    bool GitStatusObserved,
    bool HerdrAgentCorrelationObserved,
    bool RepositoryMutationInvoked,
    string RepositoryIdentity,
    string ProductAssemblySha256,
    int RetainedEventLimit,
    DateTimeOffset StartedUtc,
    DateTimeOffset FinishedUtc,
    int RequestedDurationSeconds,
    IReadOnlyList<FileActivityObservation> FileSystemEvents,
    IReadOnlyList<FileActivityObservation> InitialGitStatus,
    IReadOnlyList<FileActivityObservation> FinalGitStatus,
    string EvidenceBoundary);

/// <summary>
/// Captures an actual, read-only local FileSystemWatcher/Git trace for one explicitly
/// authorized repository. Collection never mutates Git or source content; the command writes
/// only the caller-selected report output and never controls Herdr.
/// </summary>
public static class FileGitActivityTraceCommand
{
    private const int RuntimeFailureExitCode = 2;
    private const int UsageFailureExitCode = 64;
    private const int MaximumRetainedEvents = 4096;

    private static readonly JsonSerializerOptions SerializerOptions = new()
    {
        PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
        WriteIndented = true,
        Converters = { new JsonStringEnumConverter(allowIntegerValues: false) },
    };

    public static async Task<int> RunAsync(
        string[] args,
        TextWriter output,
        TextWriter error,
        CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(args);
        ArgumentNullException.ThrowIfNull(output);
        ArgumentNullException.ThrowIfNull(error);
        if (!TryParseArguments(args, error, out var repositoryRoot, out var reportPath, out var seconds))
        {
            return UsageFailureExitCode;
        }

        try
        {
            var scope = new AuthorizedRepositoryScope(repositoryRoot!);
            var git = new GitRepositoryActivityReader(scope);
            var initialGitStatus = await git.ReadStatusAsync(cancellationToken).ConfigureAwait(false);
            var startedUtc = DateTimeOffset.UtcNow;
            var events = new ConcurrentQueue<FileActivityObservation>();
            await using var fileSystem = new ScopedFileSystemActivityCollector(scope);
            using var duration = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
            duration.CancelAfter(TimeSpan.FromSeconds(seconds));
            fileSystem.Start();
            var readerTask = CollectAsync(fileSystem, events, duration.Token);
            try
            {
                await Task.Delay(TimeSpan.FromSeconds(seconds), duration.Token).ConfigureAwait(false);
            }
            catch (OperationCanceledException) when (duration.IsCancellationRequested)
            {
            }
            finally
            {
                duration.Cancel();
            }

            await readerTask.ConfigureAwait(false);
            var finalGitStatus = await git.ReadStatusAsync(cancellationToken).ConfigureAwait(false);
            var retainedEvents = events.ToArray();
            var report = new FileGitActivityTraceReport(
                ContractVersion: 1,
                EvidenceClassification: "Actual local Windows FileSystemWatcher plus read-only Git metadata",
                RuntimeObserved: retainedEvents.Length > 0 || initialGitStatus.Count > 0 || finalGitStatus.Count > 0,
                FileSystemWatcherObserved: retainedEvents.Any(item => item.IsAuthorized),
                GitStatusObserved: initialGitStatus.Count > 0 || finalGitStatus.Count > 0,
                HerdrAgentCorrelationObserved: false,
                RepositoryMutationInvoked: false,
                RepositoryIdentity: scope.RootIdentity,
                ProductAssemblySha256: ComputeFileSha256(
                    typeof(FileGitActivityTraceCommand).Assembly.Location),
                RetainedEventLimit: MaximumRetainedEvents,
                StartedUtc: startedUtc,
                FinishedUtc: DateTimeOffset.UtcNow,
                RequestedDurationSeconds: seconds,
                FileSystemEvents: retainedEvents,
                InitialGitStatus: initialGitStatus,
                FinalGitStatus: finalGitStatus,
                EvidenceBoundary:
                    "This is actual local FileSystemWatcher and read-only Git metadata evidence for one authorized repository. RepositoryMutationInvoked=false means the collector and Git reader invoked no repository mutation; the caller-selected report file is the command's only output. This does not prove file-read interception, Herdr Agent/Task correlation, installed-Herdr runtime behavior, or v0.3 release readiness.");
            var json = JsonSerializer.Serialize(report, SerializerOptions) + "\n";
            new AtomicSchemaOutputWriter().Write(
                Path.GetFullPath(reportPath!),
                new UTF8Encoding(encoderShouldEmitUTF8Identifier: false).GetBytes(json));
            output.Write(json);
            return report.RuntimeObserved && report.FileSystemWatcherObserved && report.GitStatusObserved
                ? 0
                : RuntimeFailureExitCode;
        }
        catch (Exception exception) when (
            exception is ArgumentException or
                IOException or
                InvalidOperationException or
                NotSupportedException or
                UnauthorizedAccessException)
        {
            error.WriteLine($"File/Git activity trace failed: {exception.Message}");
            return RuntimeFailureExitCode;
        }
    }

    private static async Task CollectAsync(
        ScopedFileSystemActivityCollector collector,
        ConcurrentQueue<FileActivityObservation> events,
        CancellationToken cancellationToken)
    {
        try
        {
            await foreach (var observation in collector.ReadAllAsync(cancellationToken).ConfigureAwait(false))
            {
                events.Enqueue(observation);
                while (events.Count > MaximumRetainedEvents && events.TryDequeue(out _))
                {
                }
            }
        }
        catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested)
        {
        }
    }

    private static string ComputeFileSha256(string path)
    {
        using var input = new FileStream(
            path,
            FileMode.Open,
            FileAccess.Read,
            FileShare.Read,
            bufferSize: 81920,
            FileOptions.SequentialScan);
        return Convert.ToHexString(SHA256.HashData(input));
    }

    private static bool TryParseArguments(
        string[] args,
        TextWriter error,
        out string? repositoryRoot,
        out string? reportPath,
        out int seconds)
    {
        repositoryRoot = null;
        reportPath = null;
        seconds = 10;
        if (args.Length == 0 ||
            !string.Equals(args[0], "trace-file-git-activity", StringComparison.Ordinal))
        {
            error.WriteLine("The file/Git activity trace command name is required.");
            WriteUsage(error);
            return false;
        }

        for (var index = 1; index < args.Length; index++)
        {
            switch (args[index])
            {
                case "--repo-root" when index + 1 < args.Length && repositoryRoot is null:
                    repositoryRoot = args[++index];
                    break;
                case "--report" when index + 1 < args.Length && reportPath is null:
                    reportPath = args[++index];
                    break;
                case "--seconds" when index + 1 < args.Length &&
                    int.TryParse(args[++index], out seconds) &&
                    seconds is >= 1 and <= 300:
                    break;
                default:
                    error.WriteLine($"Invalid, duplicate, or incomplete option: {args[index]}");
                    WriteUsage(error);
                    return false;
            }
        }

        if (string.IsNullOrWhiteSpace(repositoryRoot) ||
            string.IsNullOrWhiteSpace(reportPath) ||
            !Path.IsPathFullyQualified(repositoryRoot) ||
            !Path.IsPathFullyQualified(reportPath))
        {
            error.WriteLine("Both --repo-root and --report require absolute paths.");
            WriteUsage(error);
            return false;
        }

        return true;
    }

    private static void WriteUsage(TextWriter writer) =>
        writer.WriteLine(
            "Usage: HerdrOps.Core trace-file-git-activity --repo-root <absolute-path> --report <absolute-json-path> [--seconds <1-300>]");
}
