using System.Text;
using HerdrOps.Contracts.SelfReport;
using HerdrOps.Infrastructure.StateIpc;

namespace HerdrOps.Core;

public static class HerdrOpsSelfReportServiceCommand
{
    private const int RuntimeFailureExitCode = 2;
    private const int UsageFailureExitCode = 64;

    public static async Task<int> RunAsync(
        string[] args,
        TextWriter output,
        TextWriter error,
        CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(args);
        ArgumentNullException.ThrowIfNull(output);
        ArgumentNullException.ThrowIfNull(error);
        if (args.Length == 0 ||
            !string.Equals(args[0], "serve-self-reports", StringComparison.Ordinal))
        {
            error.WriteLine("The Core self-report service command name is required.");
            WriteUsage(error);
            return UsageFailureExitCode;
        }

        var knownTasks = new List<string>();
        string? pipeName = null;
        string? tracePath = null;
        int? durationSeconds = null;
        var pipeOptionSeen = false;
        var traceOptionSeen = false;
        var durationOptionSeen = false;
        for (var index = 1; index < args.Length; index++)
        {
            switch (args[index])
            {
                case "--known-task" when index + 1 < args.Length:
                    knownTasks.Add(args[++index]);
                    break;
                case "--pipe-name" when index + 1 < args.Length && !pipeOptionSeen:
                    pipeName = args[++index];
                    pipeOptionSeen = true;
                    break;
                case "--trace" when index + 1 < args.Length && !traceOptionSeen:
                    tracePath = args[++index];
                    traceOptionSeen = true;
                    break;
                case "--seconds" when index + 1 < args.Length && !durationOptionSeen:
                    if (!int.TryParse(args[++index], out var parsedDuration) ||
                        parsedDuration is < 1 or > 3600)
                    {
                        error.WriteLine("Option --seconds must be an integer from 1 through 3600.");
                        WriteUsage(error);
                        return UsageFailureExitCode;
                    }

                    durationSeconds = parsedDuration;
                    durationOptionSeen = true;
                    break;
                default:
                    error.WriteLine($"Invalid, duplicate, or incomplete option: {args[index]}");
                    WriteUsage(error);
                    return UsageFailureExitCode;
            }
        }

        if (knownTasks.Count == 0 ||
            knownTasks.Any(string.IsNullOrWhiteSpace) ||
            (pipeName is not null && string.IsNullOrWhiteSpace(pipeName)) ||
            (tracePath is not null && string.IsNullOrWhiteSpace(tracePath)) ||
            ((tracePath is null) != (durationSeconds is null)))
        {
            error.WriteLine(
                "At least one non-blank --known-task is required; --trace and --seconds must be supplied together; explicit values cannot be blank.");
            WriteUsage(error);
            return UsageFailureExitCode;
        }

        try
        {
            var registry = new InMemoryHerdrOpsTaskRegistry(knownTasks);
            var acceptance = new HerdrOpsSelfReportAcceptanceService(registry);
            var serverOptions = pipeName is null
                ? HerdrOpsSelfReportPipeServerOptions.ForCurrentUser()
                : new HerdrOpsSelfReportPipeServerOptions(pipeName);
            var server = new HerdrOpsSelfReportPipeServer(
                serverOptions,
                (submission, correlationId, _cancellationToken) =>
                    ValueTask.FromResult(acceptance.Accept(submission, correlationId)));
            using var durationCancellation = durationSeconds is null
                ? null
                : CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
            durationCancellation?.CancelAfter(TimeSpan.FromSeconds(durationSeconds!.Value));
            var effectiveCancellationToken = durationCancellation?.Token ?? cancellationToken;
            var startedUtc = DateTimeOffset.UtcNow;
            var serverTask = server.RunAsync(effectiveCancellationToken);
            await server.Ready.WaitAsync(effectiveCancellationToken).ConfigureAwait(false);
            output.WriteLine(
                $"HerdrOps Core self-report service ready: protocol={HerdrOpsSelfReportProtocol.Version}, pipe={serverOptions.PipeName}, knownTasks={knownTasks.Distinct(StringComparer.Ordinal).Count()}.");
            output.Flush();
            await serverTask.ConfigureAwait(false);
            var finishedUtc = DateTimeOffset.UtcNow;
            output.WriteLine(
                $"HerdrOps Core self-report service stopped: accepted={acceptance.AcceptedEvents.Count}, sequence={acceptance.LastSequence}.");

            if (tracePath is not null)
            {
                var acceptedEvents = acceptance.AcceptedEvents;
                var report = new HerdrOpsSelfReportAcceptanceTrace(
                    acceptedEvents.Count > 0 ? "Runtime" : "NoRuntimeCredit",
                    HerdrOpsSelfReportProtocol.Version,
                    HerdrOpsSelfReportProtocol.AuthorizationScope,
                    serverOptions.PipeName,
                    startedUtc,
                    finishedUtc,
                    knownTasks.Distinct(StringComparer.Ordinal).Order(StringComparer.Ordinal).ToArray(),
                    acceptedEvents,
                    acceptance.LastSequence,
                    "This trace proves only the local current-user CLI-to-Core self-report transport and Core acceptance identity. It does not prove Herdr session activity, task lifecycle persistence, UI rendering, independent review, or release readiness.");
                var json = HerdrOpsSelfReportJson.Serialize(report) + Environment.NewLine;
                new AtomicSchemaOutputWriter().Write(
                    tracePath,
                    Encoding.UTF8.GetBytes(json));
                output.WriteLine(json.TrimEnd());
            }

            return 0;
        }
        catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested)
        {
            output.WriteLine("HerdrOps Core self-report service stopped.");
            return 0;
        }
        catch (Exception exception) when (
            exception is IOException or ArgumentException or InvalidOperationException or UnauthorizedAccessException)
        {
            error.WriteLine($"Core self-report service failed: {exception.Message}");
            return RuntimeFailureExitCode;
        }
    }

    private static void WriteUsage(TextWriter writer) =>
        writer.WriteLine(
            "Usage: HerdrOps.Core serve-self-reports --known-task <task-id> [--known-task <task-id> ...] [--pipe-name <name>] [--seconds <1-3600> --trace <json-path>]");
}

public sealed record HerdrOpsSelfReportAcceptanceTrace(
    string EvidenceClassification,
    int ProtocolVersion,
    string AuthorizationScope,
    string PipeName,
    DateTimeOffset StartedUtc,
    DateTimeOffset FinishedUtc,
    IReadOnlyList<string> KnownTasks,
    IReadOnlyList<HerdrOpsAcceptedSelfReport> AcceptedEvents,
    long LastSequence,
    string EvidenceBoundary);
