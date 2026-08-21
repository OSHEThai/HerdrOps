using System.Collections.Concurrent;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.Json.Serialization;
using HerdrOps.Contracts;
using HerdrOps.Domain.Activity;
using HerdrOps.Infrastructure.Activity;
using HerdrOps.Infrastructure.Herdr;

namespace HerdrOps.Core;

public sealed record HerdrFileGitActivityRuntimeTraceReport(
    int ContractVersion,
    string EvidenceClassification,
    bool RuntimeObserved,
    bool FileSystemWatcherObserved,
    bool GitStatusObserved,
    bool HerdrAgentCorrelationObserved,
    bool RepositoryMutationInvoked,
    bool SessionControlInvoked,
    string RepositoryIdentity,
    string ProductAssemblySha256,
    int RetainedEventLimit,
    DateTimeOffset StartedUtc,
    DateTimeOffset FinishedUtc,
    int RequestedDurationSeconds,
    HerdrRuntimeAdmission? Admission,
    HerdrServerProcessIdentity? MonitorServerIdentity,
    HerdrRuntimeMonitorSnapshot FinalMonitorState,
    int CorrelationContextCount,
    int CorrelatedObservationCount,
    IReadOnlyList<FileActivityObservation> FileSystemEvents,
    IReadOnlyList<FileActivityObservation> InitialGitStatus,
    IReadOnlyList<FileActivityObservation> FinalGitStatus,
    string Message,
    string EvidenceBoundary);

/// <summary>
/// Captures an actual, read-only local FileSystemWatcher/Git trace for one explicitly
/// authorized repository and correlates it against a live admitted Herdr pane's reported
/// working directory. Collection never mutates Git or source content and this command never
/// issues a Herdr session-control request.
/// </summary>
public static class HerdrFileGitActivityRuntimeTraceCommand
{
    private const int RuntimeFailureExitCode = 2;
    private const int EnvironmentGateExitCode = 3;
    private const int UsageFailureExitCode = 64;
    private const int MaximumRetainedEvents = 4096;
    private const int MaximumRetainedContexts = 4096;

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
        CancellationToken cancellationToken = default,
        Func<string, string?>? environmentVariableReader = null)
    {
        ArgumentNullException.ThrowIfNull(args);
        ArgumentNullException.ThrowIfNull(output);
        ArgumentNullException.ThrowIfNull(error);
        if (!TryParseArguments(
                args,
                error,
                out var repositoryRoot,
                out var reportPath,
                out var seconds,
                out var executablePath,
                out var socketPath))
        {
            return UsageFailureExitCode;
        }

        var readEnvironmentVariable = environmentVariableReader ?? Environment.GetEnvironmentVariable;
        if (!string.Equals(readEnvironmentVariable("HERDR_ENV"), "1", StringComparison.Ordinal))
        {
            error.WriteLine(
                "File/Git activity runtime trace is gated: run it from an authorized Herdr environment with HERDR_ENV=1.");
            return EnvironmentGateExitCode;
        }

        HerdrAdmittedRuntimeMonitor admitted;
        try
        {
            admitted = new HerdrRuntimeMonitorFactory().Create(executablePath, socketPath);
        }
        catch (Exception exception) when (
            exception is IOException or ArgumentException or InvalidOperationException or UnauthorizedAccessException)
        {
            error.WriteLine($"Runtime admission failed: {exception.Message}");
            return RuntimeFailureExitCode;
        }

        AuthorizedRepositoryScope scope;
        GitRepositoryActivityReader git;
        try
        {
            scope = new AuthorizedRepositoryScope(repositoryRoot!);
            git = new GitRepositoryActivityReader(scope);
        }
        catch (Exception exception) when (
            exception is ArgumentException or IOException or InvalidOperationException or UnauthorizedAccessException)
        {
            error.WriteLine($"Repository scope failed: {exception.Message}");
            return RuntimeFailureExitCode;
        }

        var initialGitStatus = await git.ReadStatusAsync(cancellationToken).ConfigureAwait(false);
        var startedUtc = DateTimeOffset.UtcNow;
        var events = new ConcurrentQueue<FileActivityObservation>();
        var contexts = new ConcurrentQueue<FileActivityCorrelationContext>();
        var correlator = new FileActivityCorrelator();

        await using var fileSystem = new ScopedFileSystemActivityCollector(scope);
        using var duration = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
        duration.CancelAfter(TimeSpan.FromSeconds(seconds));
        fileSystem.Start();
        var readerTask = CollectEventsAsync(fileSystem, events, duration.Token);

        Exception? monitorFailure = null;
        var monitorTask = admitted.Monitor.RunAsync(duration.Token);
        try
        {
            while (!duration.IsCancellationRequested)
            {
                if (monitorTask.IsCompleted)
                {
                    await monitorTask.ConfigureAwait(false);
                    break;
                }

                CapturePaneContexts(admitted.Monitor.Current, scope, contexts);
                try
                {
                    await Task.Delay(TimeSpan.FromMilliseconds(500), duration.Token).ConfigureAwait(false);
                }
                catch (OperationCanceledException) when (duration.IsCancellationRequested)
                {
                    break;
                }
            }
        }
        catch (OperationCanceledException) when (duration.IsCancellationRequested)
        {
        }
        catch (Exception exception)
        {
            monitorFailure = exception;
        }
        finally
        {
            duration.Cancel();
            try
            {
                await monitorTask.ConfigureAwait(false);
            }
            catch (OperationCanceledException) when (duration.IsCancellationRequested)
            {
            }
            catch (Exception exception)
            {
                monitorFailure ??= exception;
            }
        }

        await readerTask.ConfigureAwait(false);
        var finalGitStatus = await git.ReadStatusAsync(cancellationToken).ConfigureAwait(false);

        var retainedContexts = contexts.ToArray();
        var correlatedEvents = new List<FileActivityObservation>();
        var correlatedCount = 0;
        foreach (var observation in events)
        {
            var correlated = correlator.Correlate(observation, retainedContexts);
            if (correlated.Confidence == ActivityConfidence.Correlated)
            {
                correlatedCount++;
            }

            correlatedEvents.Add(correlated);
        }

        var final = admitted.Monitor.Current;
        var monitorIdentity = final.ServerIdentity;
        var runtimeObserved = monitorFailure is null &&
                              final.BootstrapCount > 0 &&
                              IsAdmittedIdentity(monitorIdentity, admitted.Admission);
        var fileSystemWatcherObserved = correlatedEvents.Any(item => item.IsAuthorized);
        var gitStatusObserved = initialGitStatus.Count > 0 || finalGitStatus.Count > 0;
        var herdrAgentCorrelationObserved = correlatedCount > 0;
        var completeRuntimeEvidence = runtimeObserved && fileSystemWatcherObserved &&
            gitStatusObserved && herdrAgentCorrelationObserved;

        var message = completeRuntimeEvidence
            ? "Actual FileSystemWatcher observations were correlated against a live Herdr pane's reported working directory. No session control was invoked."
            : runtimeObserved
                ? "The admitted Herdr runtime was observed, but complete File/Git runtime evidence (watcher, Git status, and Agent correlation) was not achieved in this run."
                : "No exact-hash-bound Herdr runtime was observed; this report receives no runtime credit.";
        if (monitorFailure is not null)
        {
            message += $" Monitor failed with {monitorFailure.GetType().Name}.";
        }

        var report = new HerdrFileGitActivityRuntimeTraceReport(
            ContractVersion: 1,
            completeRuntimeEvidence ? EvidenceClass.Runtime.ToString() : "NoRuntimeCredit",
            runtimeObserved,
            fileSystemWatcherObserved,
            gitStatusObserved,
            herdrAgentCorrelationObserved,
            RepositoryMutationInvoked: false,
            SessionControlInvoked: false,
            scope.RootIdentity,
            ComputeFileSha256(typeof(HerdrFileGitActivityRuntimeTraceCommand).Assembly.Location),
            MaximumRetainedEvents,
            startedUtc,
            DateTimeOffset.UtcNow,
            seconds,
            admitted.Admission,
            monitorIdentity,
            final,
            retainedContexts.Length,
            correlatedCount,
            correlatedEvents,
            initialGitStatus,
            finalGitStatus,
            message,
            "This is actual local FileSystemWatcher and read-only Git metadata evidence for one authorized repository, with FileSystemWatcher observations correlated against a live admitted Herdr pane's reported working directory. RepositoryMutationInvoked=false means the collector and Git reader invoked no repository mutation; SessionControlInvoked=false means this command issued no Herdr session-control request. This does not prove file-read interception, Task correlation, or v0.3 release readiness.");

        var json = JsonSerializer.Serialize(report, SerializerOptions) + "\n";
        try
        {
            new AtomicSchemaOutputWriter().Write(
                Path.GetFullPath(reportPath!),
                new UTF8Encoding(encoderShouldEmitUTF8Identifier: false).GetBytes(json));
        }
        catch (Exception exception) when (
            exception is IOException or ArgumentException or NotSupportedException or UnauthorizedAccessException)
        {
            error.WriteLine($"File/Git activity runtime trace report could not be written: {exception.Message}");
            return RuntimeFailureExitCode;
        }

        output.Write(json);
        if (!completeRuntimeEvidence)
        {
            error.WriteLine(message);
            return RuntimeFailureExitCode;
        }

        return 0;
    }

    private static async Task CollectEventsAsync(
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

    private static void CapturePaneContexts(
        HerdrRuntimeMonitorSnapshot snapshot,
        AuthorizedRepositoryScope scope,
        ConcurrentQueue<FileActivityCorrelationContext> contexts)
    {
        var observedUtc = DateTimeOffset.UtcNow;
        foreach (var pane in snapshot.State.Panes.Values)
        {
            if (string.IsNullOrWhiteSpace(pane.TerminalId))
            {
                continue;
            }

            var relative = TryGetRepositoryRelativeDirectory(scope.CanonicalRoot, pane.CurrentDirectory) ??
                TryGetRepositoryRelativeDirectory(scope.CanonicalRoot, pane.ForegroundCurrentDirectory);
            if (relative is null)
            {
                continue;
            }

            contexts.Enqueue(new FileActivityCorrelationContext(
                pane.TerminalId,
                null,
                relative,
                observedUtc,
                "herdr-pane-current-directory"));
            while (contexts.Count > MaximumRetainedContexts && contexts.TryDequeue(out _))
            {
            }
        }
    }

    private static string? TryGetRepositoryRelativeDirectory(
        string repositoryRootFullPath,
        string? candidateAbsolutePath)
    {
        if (string.IsNullOrWhiteSpace(candidateAbsolutePath))
        {
            return null;
        }

        string full;
        try
        {
            full = Path.GetFullPath(candidateAbsolutePath);
        }
        catch (Exception exception) when (
            exception is ArgumentException or NotSupportedException or PathTooLongException)
        {
            return null;
        }

        var trimmedRoot = repositoryRootFullPath.TrimEnd(
            Path.DirectorySeparatorChar,
            Path.AltDirectorySeparatorChar);
        if (string.Equals(full, trimmedRoot, StringComparison.OrdinalIgnoreCase))
        {
            return ".";
        }

        var rootWithSeparator = trimmedRoot + Path.DirectorySeparatorChar;
        if (!full.StartsWith(rootWithSeparator, StringComparison.OrdinalIgnoreCase))
        {
            return null;
        }

        return full[rootWithSeparator.Length..].Replace('\\', '/');
    }

    private static bool IsAdmittedIdentity(
        HerdrServerProcessIdentity? identity,
        HerdrRuntimeAdmission admission) =>
        identity is not null &&
        string.Equals(identity.ExecutablePath, admission.ExecutablePath, StringComparison.OrdinalIgnoreCase) &&
        string.Equals(identity.ExecutableSha256, admission.ExecutableSha256, StringComparison.Ordinal);

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
        out int seconds,
        out string? executablePath,
        out string? socketPath)
    {
        repositoryRoot = null;
        reportPath = null;
        seconds = 30;
        executablePath = null;
        socketPath = null;
        if (args.Length == 0 ||
            !string.Equals(args[0], "trace-herdr-file-git-activity", StringComparison.Ordinal))
        {
            error.WriteLine("The Herdr file/Git activity runtime trace command name is required.");
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
                case "--herdr" when index + 1 < args.Length && executablePath is null:
                    executablePath = args[++index];
                    break;
                case "--socket-path" when index + 1 < args.Length && socketPath is null:
                    socketPath = args[++index];
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
            "Usage: HerdrOps.Core trace-herdr-file-git-activity --repo-root <absolute-path> --report <absolute-json-path> [--seconds <1-300>] [--herdr <path>] [--socket-path <path>]");
}
