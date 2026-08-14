using System.Collections.Concurrent;
using System.Text;
using System.Text.Json;
using System.Text.Json.Serialization;
using HerdrOps.Contracts;
using HerdrOps.Infrastructure.Herdr;

namespace HerdrOps.Core;

public sealed record HerdrTerminalProcessTraceReport(
    string EvidenceClassification,
    bool RuntimeObserved,
    bool PaneReadObserved,
    bool ProcessCorrelationObserved,
    bool SessionControlInvoked,
    int UnboundedTerminalReadAttemptCount,
    int MaximumTerminalLines,
    DateTimeOffset StartedUtc,
    DateTimeOffset FinishedUtc,
    int RequestedDurationSeconds,
    int PollIntervalMilliseconds,
    string HostName,
    string OperatingSystem,
    HerdrRuntimeAdmission? Admission,
    HerdrServerProcessIdentity? MonitorServerIdentity,
    HerdrServerProcessIdentity? InspectionServerIdentity,
    HerdrRuntimeMonitorSnapshot FinalMonitorState,
    int CollectionCycleCount,
    int TerminalReadAttemptCount,
    int TerminalPreviewCount,
    int ProcessPollAttemptCount,
    int ProcessTelemetryCount,
    int ProcessFailureCount,
    int CollectionFailureCount,
    IReadOnlyList<HerdrTerminalProcessCollectionCycle> Cycles,
    string Message);

public static class HerdrTerminalProcessTraceCommand
{
    private const int RuntimeFailureExitCode = 2;
    private const int EnvironmentGateExitCode = 3;
    private const int UsageFailureExitCode = 64;
    private const int MaximumRetainedCycles = 4096;

    private static readonly JsonSerializerOptions SerializerOptions = new()
    {
        WriteIndented = true,
        Converters = { new JsonStringEnumConverter() },
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
        if (args.Length == 0 ||
            !string.Equals(args[0], "trace-herdr-terminal-process", StringComparison.Ordinal))
        {
            error.WriteLine("The terminal-process trace command name is required.");
            WriteUsage(error);
            return UsageFailureExitCode;
        }

        var durationSeconds = 30;
        var intervalMilliseconds = 500;
        var maximumLines = HerdrPaneReadBounds.DefaultMaximumLines;
        string? executablePath = null;
        string? socketPath = null;
        string? reportPath = null;
        for (var index = 1; index < args.Length; index++)
        {
            switch (args[index])
            {
                case "--seconds" when index + 1 < args.Length:
                    if (!int.TryParse(args[++index], out durationSeconds) || durationSeconds is < 1 or > 3600)
                    {
                        error.WriteLine("Option --seconds must be an integer from 1 through 3600.");
                        WriteUsage(error);
                        return UsageFailureExitCode;
                    }
                    break;
                case "--interval-ms" when index + 1 < args.Length:
                    if (!int.TryParse(args[++index], out intervalMilliseconds) ||
                        intervalMilliseconds is < 100 or > 5000)
                    {
                        error.WriteLine("Option --interval-ms must be an integer from 100 through 5000.");
                        WriteUsage(error);
                        return UsageFailureExitCode;
                    }
                    break;
                case "--lines" when index + 1 < args.Length:
                    if (!int.TryParse(args[++index], out maximumLines) ||
                        maximumLines is < 1 or > HerdrPaneReadBounds.HardMaximumLines)
                    {
                        error.WriteLine(
                            $"Option --lines must be an integer from 1 through {HerdrPaneReadBounds.HardMaximumLines}.");
                        WriteUsage(error);
                        return UsageFailureExitCode;
                    }
                    break;
                case "--herdr" when index + 1 < args.Length:
                    executablePath = args[++index];
                    if (IsInvalidValue(executablePath))
                    {
                        error.WriteLine("Option --herdr requires a non-empty executable path.");
                        WriteUsage(error);
                        return UsageFailureExitCode;
                    }
                    break;
                case "--socket-path" when index + 1 < args.Length:
                    socketPath = args[++index];
                    if (IsInvalidValue(socketPath))
                    {
                        error.WriteLine("Option --socket-path requires a non-empty Herdr socket path.");
                        WriteUsage(error);
                        return UsageFailureExitCode;
                    }
                    break;
                case "--report" when index + 1 < args.Length:
                    reportPath = args[++index];
                    if (IsInvalidValue(reportPath))
                    {
                        error.WriteLine("Option --report requires a non-empty JSON path.");
                        WriteUsage(error);
                        return UsageFailureExitCode;
                    }
                    break;
                default:
                    error.WriteLine($"Invalid or incomplete option: {args[index]}");
                    WriteUsage(error);
                    return UsageFailureExitCode;
            }
        }

        if (string.IsNullOrWhiteSpace(reportPath))
        {
            error.WriteLine("Option --report is required so runtime observations are retained.");
            WriteUsage(error);
            return UsageFailureExitCode;
        }

        var readEnvironmentVariable = environmentVariableReader ?? Environment.GetEnvironmentVariable;
        if (!string.Equals(readEnvironmentVariable("HERDR_ENV"), "1", StringComparison.Ordinal))
        {
            error.WriteLine(
                "Terminal-process runtime trace is gated: run it from an authorized Herdr environment with HERDR_ENV=1.");
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

        var collector = new HerdrTerminalProcessCollector(
            admitted.PaneInspectionClient,
            admitted.Admission.Endpoint,
            new HerdrTerminalProcessCollectorOptions(
                maximumLines,
                MaximumPanesPerCycle: 256,
                TerminalReadInterval: TimeSpan.FromMilliseconds(intervalMilliseconds),
                ProcessPollInterval: TimeSpan.FromMilliseconds(intervalMilliseconds)));
        var cycles = new ConcurrentQueue<HerdrTerminalProcessCollectionCycle>();
        var collectionCycleCount = 0;
        var terminalReadAttemptCount = 0;
        var terminalPreviewCount = 0;
        var processPollAttemptCount = 0;
        var processTelemetryCount = 0;
        var processFailureCount = 0;
        var collectionFailureCount = 0;
        var startedUtc = DateTimeOffset.UtcNow;
        using var durationCancellation = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
        durationCancellation.CancelAfter(TimeSpan.FromSeconds(durationSeconds));
        var monitorTask = admitted.Monitor.RunAsync(durationCancellation.Token);
        Exception? monitorFailure = null;
        try
        {
            while (!durationCancellation.IsCancellationRequested)
            {
                if (monitorTask.IsCompleted)
                {
                    await monitorTask.ConfigureAwait(false);
                    break;
                }

                var cycle = await collector.CollectOnceAsync(
                        admitted.Monitor.Current,
                        durationCancellation.Token)
                    .ConfigureAwait(false);
                cycles.Enqueue(cycle);
                while (cycles.Count > MaximumRetainedCycles && cycles.TryDequeue(out _))
                {
                }

                collectionCycleCount++;
                terminalReadAttemptCount += cycle.TerminalReadAttemptCount;
                terminalPreviewCount += cycle.TerminalPreviews.Count;
                processPollAttemptCount += cycle.ProcessPollAttemptCount;
                processTelemetryCount += cycle.ProcessTelemetry.Count;
                processFailureCount += cycle.ProcessFailures.Count;
                collectionFailureCount += cycle.CollectionFailures.Count;
                await Task.Delay(
                        TimeSpan.FromMilliseconds(intervalMilliseconds),
                        durationCancellation.Token)
                    .ConfigureAwait(false);
            }
        }
        catch (OperationCanceledException) when (durationCancellation.IsCancellationRequested)
        {
        }
        catch (Exception exception)
        {
            monitorFailure = exception;
        }
        finally
        {
            durationCancellation.Cancel();
            try
            {
                await monitorTask.ConfigureAwait(false);
            }
            catch (OperationCanceledException) when (durationCancellation.IsCancellationRequested)
            {
            }
            catch (Exception exception)
            {
                monitorFailure ??= exception;
            }
        }

        var final = admitted.Monitor.Current;
        var monitorIdentity = final.ServerIdentity;
        var inspectionIdentity = admitted.PaneInspectionClient.LastVerifiedServerIdentity;
        var runtimeObserved = monitorFailure is null &&
                              final.BootstrapCount > 0 &&
                              IsAdmittedIdentity(monitorIdentity, admitted.Admission);
        var paneReadObserved = runtimeObserved &&
                               terminalPreviewCount > 0 &&
                               IsAdmittedIdentity(inspectionIdentity, admitted.Admission) &&
                               SameServerProcess(monitorIdentity, inspectionIdentity);
        var processCorrelationObserved = runtimeObserved &&
                                         processTelemetryCount > 0 &&
                                         IsAdmittedIdentity(inspectionIdentity, admitted.Admission) &&
                                         SameServerProcess(monitorIdentity, inspectionIdentity);
        var completeRuntimeEvidence = paneReadObserved && processCorrelationObserved;
        var message = completeRuntimeEvidence
            ? "Exact-hash-bound bounded pane reads and PID-correlated Windows process telemetry were observed. No session control was invoked."
            : runtimeObserved
                ? "The admitted Herdr runtime was observed, but bounded pane-read and process-correlation evidence was incomplete."
                : "No exact-hash-bound Herdr runtime was observed; this report receives no runtime credit.";
        if (monitorFailure is not null)
        {
            message += $" Monitor failed with {monitorFailure.GetType().Name}.";
        }

        var report = new HerdrTerminalProcessTraceReport(
            completeRuntimeEvidence ? EvidenceClass.Runtime.ToString() : "NoRuntimeCredit",
            runtimeObserved,
            paneReadObserved,
            processCorrelationObserved,
            SessionControlInvoked: false,
            UnboundedTerminalReadAttemptCount: 0,
            maximumLines,
            startedUtc,
            DateTimeOffset.UtcNow,
            durationSeconds,
            intervalMilliseconds,
            Environment.MachineName,
            Environment.OSVersion.VersionString,
            admitted.Admission,
            monitorIdentity,
            inspectionIdentity,
            final,
            collectionCycleCount,
            terminalReadAttemptCount,
            terminalPreviewCount,
            processPollAttemptCount,
            processTelemetryCount,
            processFailureCount,
            collectionFailureCount,
            cycles.ToArray(),
            message);
        var reportJson = JsonSerializer.Serialize(report, SerializerOptions);
        try
        {
            new AtomicSchemaOutputWriter().Write(
                reportPath,
                Encoding.UTF8.GetBytes(reportJson + Environment.NewLine));
        }
        catch (Exception exception) when (
            exception is IOException or ArgumentException or NotSupportedException or UnauthorizedAccessException)
        {
            error.WriteLine($"Terminal-process trace report could not be written: {exception.Message}");
            return RuntimeFailureExitCode;
        }

        output.WriteLine(reportJson);
        if (!completeRuntimeEvidence)
        {
            error.WriteLine(message);
            return RuntimeFailureExitCode;
        }

        return 0;
    }

    private static bool IsAdmittedIdentity(
        HerdrServerProcessIdentity? identity,
        HerdrRuntimeAdmission admission) =>
        identity is not null &&
        string.Equals(identity.ExecutablePath, admission.ExecutablePath, StringComparison.OrdinalIgnoreCase) &&
        string.Equals(identity.ExecutableSha256, admission.ExecutableSha256, StringComparison.Ordinal);

    private static bool SameServerProcess(
        HerdrServerProcessIdentity? monitorIdentity,
        HerdrServerProcessIdentity? inspectionIdentity) =>
        monitorIdentity is not null &&
        inspectionIdentity is not null &&
        monitorIdentity.ProcessId == inspectionIdentity.ProcessId &&
        monitorIdentity.ProcessStartUtc == inspectionIdentity.ProcessStartUtc &&
        string.Equals(
            monitorIdentity.ExecutablePath,
            inspectionIdentity.ExecutablePath,
            StringComparison.OrdinalIgnoreCase) &&
        string.Equals(
            monitorIdentity.ExecutableSha256,
            inspectionIdentity.ExecutableSha256,
            StringComparison.Ordinal);

    private static bool IsInvalidValue(string value) =>
        string.IsNullOrWhiteSpace(value) || value.StartsWith("--", StringComparison.Ordinal);

    private static void WriteUsage(TextWriter writer) =>
        writer.WriteLine(
            "Usage: HerdrOps.Core trace-herdr-terminal-process --report <json-path> [--seconds <1-3600>] [--interval-ms <100-5000>] [--lines <1-200>] [--herdr <path>] [--socket-path <path>]");
}
