using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.Json.Serialization;
using HerdrOps.Contracts;
using HerdrOps.Contracts.StateIpc;
using HerdrOps.Domain.Assignments;
using HerdrOps.Infrastructure.StateIpc;

namespace HerdrOps.Core;

public sealed record AssignmentLifecycleCompositeRuntimeReport(
    string EvidenceClassification,
    bool RuntimeAccepted,
    bool SessionControlInvoked,
    DateTimeOffset GeneratedUtc,
    string TaskId,
    string LifecycleTraceSha256,
    string HerdrRuntimeReportSha256,
    string FinalHerdrStateSha256,
    DateTimeOffset OverlapStartedUtc,
    DateTimeOffset OverlapFinishedUtc,
    AssignmentLifecycleRuntimeAcceptanceResult Acceptance,
    string EvidenceBoundary);

public static class AssignmentLifecycleRuntimeAcceptanceCommand
{
    private const int RuntimeFailureExitCode = 2;
    private const int UsageFailureExitCode = 64;
    private const int MaximumInputBytes = 8 * 1024 * 1024;

    private static readonly JsonSerializerOptions SerializerOptions = new()
    {
        AllowTrailingCommas = false,
        MaxDepth = 128,
        PropertyNameCaseInsensitive = true,
        ReadCommentHandling = JsonCommentHandling.Disallow,
        UnmappedMemberHandling = JsonUnmappedMemberHandling.Disallow,
        WriteIndented = true,
        Converters = { new JsonStringEnumConverter() },
    };

    public static int Run(string[] args, TextWriter output, TextWriter error)
    {
        ArgumentNullException.ThrowIfNull(args);
        ArgumentNullException.ThrowIfNull(output);
        ArgumentNullException.ThrowIfNull(error);
        if (args.Length == 0 ||
            !string.Equals(
                args[0],
                "assignment-lifecycle-acceptance",
                StringComparison.Ordinal))
        {
            error.WriteLine("The assignment lifecycle acceptance command name is required.");
            WriteUsage(error);
            return UsageFailureExitCode;
        }

        string? lifecycleTracePath = null;
        string? herdrRuntimeReportPath = null;
        string? taskId = null;
        string? reportPath = null;
        var seen = new HashSet<string>(StringComparer.Ordinal);
        for (var index = 1; index < args.Length; index++)
        {
            var option = args[index];
            if (!seen.Add(option) ||
                index + 1 >= args.Length ||
                string.IsNullOrWhiteSpace(args[index + 1]))
            {
                error.WriteLine($"Invalid, duplicate, or incomplete option: {option}");
                WriteUsage(error);
                return UsageFailureExitCode;
            }

            var value = args[++index];
            switch (option)
            {
                case "--lifecycle-trace":
                    lifecycleTracePath = value;
                    break;
                case "--herdr-runtime-report":
                    herdrRuntimeReportPath = value;
                    break;
                case "--task-id":
                    taskId = value;
                    break;
                case "--report":
                    reportPath = value;
                    break;
                default:
                    error.WriteLine($"Unknown option: {option}");
                    WriteUsage(error);
                    return UsageFailureExitCode;
            }
        }

        if (lifecycleTracePath is null ||
            herdrRuntimeReportPath is null ||
            taskId is null ||
            reportPath is null)
        {
            error.WriteLine("Every assignment lifecycle acceptance option is required.");
            WriteUsage(error);
            return UsageFailureExitCode;
        }

        try
        {
            lifecycleTracePath = Path.GetFullPath(lifecycleTracePath);
            herdrRuntimeReportPath = Path.GetFullPath(herdrRuntimeReportPath);
            reportPath = Path.GetFullPath(reportPath);
            var lifecycleBytes = ReadBounded(lifecycleTracePath);
            var runtimeBytes = ReadBounded(herdrRuntimeReportPath);
            var lifecycleTrace = Deserialize<HerdrOpsSelfReportAcceptanceTrace>(
                lifecycleBytes,
                "lifecycle trace");
            var herdrRuntime = Deserialize<HerdrCoreRuntimeEvidenceReport>(
                runtimeBytes,
                "Herdr runtime report");
            if (!lifecycleTrace.DurableLifecycleEnabled ||
                lifecycleTrace.LifecycleReplay is null ||
                lifecycleTrace.LifecycleGraphSha256 is null ||
                lifecycleTrace.StoreDiagnostics is null ||
                lifecycleTrace.AcceptedEvents is null)
            {
                throw new InvalidDataException(
                    "The self-report trace has no durable lifecycle projection.");
            }

            var acceptedReplay = AssignmentLifecycleReplay.Run(
                lifecycleTrace.AcceptedEvents
                    .Select(HerdrOpsAssignmentLifecycleMapper.Map)
                    .ToArray());
            if (!string.Equals(
                    acceptedReplay.ResultSha256,
                    lifecycleTrace.LifecycleReplay.ResultSha256,
                    StringComparison.Ordinal))
            {
                throw new InvalidDataException(
                    "The accepted self-report ledger does not reproduce the lifecycle replay.");
            }

            var projectedGraph = AssignmentDelegationGraphProjector.Create(
                lifecycleTrace.LifecycleReplay);
            if (!string.Equals(
                    projectedGraph.GraphSha256,
                    lifecycleTrace.LifecycleGraphSha256,
                    StringComparison.Ordinal))
            {
                throw new InvalidDataException(
                    "The lifecycle trace graph hash does not match deterministic projection.");
            }

            if (herdrRuntime.Admission is null ||
                herdrRuntime.FinalMonitorState is null ||
                herdrRuntime.FinalProjectedState is null ||
                herdrRuntime.StartedUtc > herdrRuntime.FinishedUtc ||
                herdrRuntime.SessionControlInvoked ||
                herdrRuntime.SnapshotObserved != herdrRuntime.RuntimeObserved ||
                (herdrRuntime.RuntimeObserved &&
                 (herdrRuntime.FinalMonitorState.BootstrapCount <= 0 ||
                  herdrRuntime.FinalMonitorState.ServerIdentity is null ||
                  !string.Equals(
                      herdrRuntime.FinalMonitorState.ServerIdentity.ExecutableSha256,
                      herdrRuntime.Admission.ExecutableSha256,
                      StringComparison.Ordinal))))
            {
                throw new InvalidDataException(
                    "The Herdr runtime report is internally inconsistent or invoked session control.");
            }

            var normalizedState = HerdrSessionStateContractReducer.NormalizeAndValidate(
                herdrRuntime.FinalProjectedState);
            var stateSha256 = HerdrOpsStateIpcJson.ComputeSha256(normalizedState);
            if (!string.Equals(
                    stateSha256,
                    herdrRuntime.FinalProjectedStateSha256,
                    StringComparison.Ordinal))
            {
                throw new InvalidDataException(
                    "The Herdr runtime report state hash does not match its final state.");
            }

            var agents = normalizedState.Agents
                .Where(agent => !string.IsNullOrWhiteSpace(agent.Title))
                .Select(agent => new AssignmentRuntimeAgentIdentity(
                    agent.TerminalId,
                    agent.Title!))
                .ToArray();
            var acceptance = AssignmentLifecycleRuntimeAcceptance.Analyze(
                lifecycleTrace.LifecycleReplay,
                agents,
                taskId);
            var overlapStartedUtc = lifecycleTrace.StartedUtc > herdrRuntime.StartedUtc
                ? lifecycleTrace.StartedUtc
                : herdrRuntime.StartedUtc;
            var overlapFinishedUtc = lifecycleTrace.FinishedUtc < herdrRuntime.FinishedUtc
                ? lifecycleTrace.FinishedUtc
                : herdrRuntime.FinishedUtc;
            var supportingIds = acceptance.Checks
                .SelectMany(item => item.SupportingEventIds)
                .Distinct()
                .ToHashSet();
            var supportingAcceptedEvents = lifecycleTrace.AcceptedEvents
                .Where(item => supportingIds.Contains(item.Submission.EventId))
                .ToArray();
            var timeCoherent = overlapStartedUtc <= overlapFinishedUtc &&
                               supportingAcceptedEvents.Length == supportingIds.Count &&
                               supportingAcceptedEvents.All(item =>
                                   item.AcceptedUtc >= overlapStartedUtc &&
                                   item.AcceptedUtc <= overlapFinishedUtc);
            var runtimeAccepted = acceptance.Passed &&
                                  timeCoherent &&
                                  string.Equals(
                                      lifecycleTrace.EvidenceClassification,
                                      HerdrOpsSelfReportAcceptanceTrace.BuiltProcessIntegrationEvidence,
                                      StringComparison.Ordinal) &&
                                  herdrRuntime.RuntimeObserved &&
                                  string.Equals(
                                      herdrRuntime.EvidenceClassification,
                                      EvidenceClass.Runtime.ToString(),
                                      StringComparison.Ordinal);
            var report = new AssignmentLifecycleCompositeRuntimeReport(
                runtimeAccepted ? EvidenceClass.Runtime.ToString() : "NoRuntimeCredit",
                runtimeAccepted,
                herdrRuntime.SessionControlInvoked,
                DateTimeOffset.UtcNow,
                taskId,
                Hash(lifecycleBytes),
                Hash(runtimeBytes),
                stateSha256,
                overlapStartedUtc,
                overlapFinishedUtc,
                acceptance,
                runtimeAccepted
                    ? "This report binds a durable Core lifecycle to exact role-distinct Agent identities observed in an overlapping exact-Herdr runtime. Current-user Named Pipe authorization does not authenticate which same-user process submitted each event."
                    : "The lifecycle and Herdr reports did not satisfy every complete-chain, exact-Agent, orphan, mismatch, hash, and overlapping-runtime requirement; no Runtime credit is awarded.");
            var json = JsonSerializer.Serialize(report, SerializerOptions) + Environment.NewLine;
            new AtomicSchemaOutputWriter().Write(reportPath, Encoding.UTF8.GetBytes(json));
            output.Write(json);
            return runtimeAccepted ? 0 : RuntimeFailureExitCode;
        }
        catch (Exception exception) when (
            exception is IOException or
                InvalidDataException or
                JsonException or
                ArgumentException or
                InvalidOperationException)
        {
            error.WriteLine($"Assignment lifecycle runtime acceptance failed: {exception.Message}");
            return RuntimeFailureExitCode;
        }
    }

    private static byte[] ReadBounded(string path)
    {
        var info = new FileInfo(path);
        if (!info.Exists || info.Length is <= 0 or > MaximumInputBytes)
        {
            throw new InvalidDataException(
                $"Acceptance input must contain 1 through {MaximumInputBytes} bytes: {path}");
        }

        return File.ReadAllBytes(path);
    }

    private static T Deserialize<T>(byte[] bytes, string name)
    {
        using var document = JsonDocument.Parse(bytes, new JsonDocumentOptions
        {
            AllowTrailingCommas = false,
            CommentHandling = JsonCommentHandling.Disallow,
            MaxDepth = 128,
        });
        EnsureUniqueProperties(document.RootElement, name);
        return JsonSerializer.Deserialize<T>(bytes, SerializerOptions)
            ?? throw new InvalidDataException($"The {name} was null.");
    }

    private static void EnsureUniqueProperties(JsonElement element, string name)
    {
        if (element.ValueKind == JsonValueKind.Object)
        {
            var names = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
            foreach (var property in element.EnumerateObject())
            {
                if (!names.Add(property.Name))
                {
                    throw new InvalidDataException(
                        $"The {name} contains duplicate property '{property.Name}'.");
                }

                EnsureUniqueProperties(property.Value, name);
            }
        }
        else if (element.ValueKind == JsonValueKind.Array)
        {
            foreach (var item in element.EnumerateArray())
            {
                EnsureUniqueProperties(item, name);
            }
        }
    }

    private static string Hash(byte[] bytes) => Convert.ToHexString(SHA256.HashData(bytes));

    private static void WriteUsage(TextWriter writer) => writer.WriteLine(
        "Usage: HerdrOps.Core assignment-lifecycle-acceptance --lifecycle-trace <json-path> --herdr-runtime-report <json-path> --task-id <task-id> --report <json-path>");
}
