using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.Json.Serialization;
using HerdrOps.Domain.Compliance;

namespace HerdrOps.Core;

public static class ComplianceRuleCorpusCommand
{
    public const int ContractVersion = 1;

    private const int EvaluationFailureExitCode = 2;
    private const int UsageFailureExitCode = 64;
    private const int MaximumInputBytes = 8 * 1024 * 1024;
    private const int MaximumCaseCount = 64;
    private const int MaximumRepeatCount = 4;

    private static readonly JsonSerializerOptions InputSerializerOptions = CreateSerializerOptions(
        writeIndented: false,
        rejectUnknownMembers: true);

    private static readonly JsonSerializerOptions OutputSerializerOptions = CreateSerializerOptions(
        writeIndented: true,
        rejectUnknownMembers: false);

    private static readonly JsonSerializerOptions CompactSerializerOptions = CreateSerializerOptions(
        writeIndented: false,
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
                throw new ComplianceRuleCorpusCommandException(
                    "The compliance corpus input and report paths must be different files.");
            }

            var inputBytes = ReadBoundedInput(fullInputPath);
            var input = JsonSerializer.Deserialize<ComplianceRuleCorpusInputDocument>(
                inputBytes,
                InputSerializerOptions) ?? throw new ComplianceRuleCorpusCommandException(
                    "The compliance rule corpus cannot be JSON null.");
            ValidateInput(input);

            var engine = new ComplianceRuleEngine();
            var caseResults = input.Cases
                .Select(item => RunCase(engine, item))
                .OrderBy(item => item.CaseId, StringComparer.Ordinal)
                .ToArray();
            var firstRuns = caseResults.Select(item => item.Runs[0]).ToArray();
            var triggeredRuleKinds = firstRuns
                .SelectMany(item => item.Findings.Select(finding => finding.RuleKind))
                .Distinct()
                .OrderBy(item => item)
                .ToArray();
            var passedRuleKinds = firstRuns
                .SelectMany(item => item.RuleEvaluations
                    .Where(evaluation => evaluation.Outcome == ComplianceRuleOutcomeKind.Passed)
                    .Select(evaluation => evaluation.RuleKind))
                .Distinct()
                .OrderBy(item => item)
                .ToArray();
            var diagnostics = new ComplianceRuleCorpusDiagnostics(
                CaseCount: caseResults.Length,
                PassedCaseCount: caseResults.Count(item => item.Passed),
                EvaluationRunCount: caseResults.Sum(item => item.Runs.Count),
                FirstRunFindingCount: firstRuns.Sum(item => item.Findings.Count),
                ExplainabilityRecordCount: firstRuns.Sum(item => item.Findings.Count(finding =>
                    finding.SupportingFacts.Count > 0 &&
                    finding.ExplainabilitySha256.Length == 64)),
                FirstRunRuleErrorCount: firstRuns.Sum(item =>
                    item.Diagnostics.ErrorRuleCount),
                RepeatedDuplicateDetectionCount: caseResults.Sum(item =>
                    item.RepeatedDuplicateDetectionCount),
                ConfirmedFindingCount: caseResults.Sum(item =>
                    item.Runs.Sum(run => run.Diagnostics.ConfirmedFindingCount)),
                TriggeredRuleKinds: Array.AsReadOnly(triggeredRuleKinds),
                PassedRuleKinds: Array.AsReadOnly(passedRuleKinds));
            var payload = new ComplianceRuleCorpusResultPayload(
                ComplianceRuleSetContract.Version1,
                Array.AsReadOnly(caseResults),
                diagnostics);
            var corpusResultSha256 = Convert.ToHexString(SHA256.HashData(
                JsonSerializer.SerializeToUtf8Bytes(payload, CompactSerializerOptions)));
            var report = new ComplianceRuleCorpusEvidenceReport(
                ContractVersion,
                "Synthetic",
                RuntimeObserved: false,
                InputSha256: Convert.ToHexString(SHA256.HashData(inputBytes)),
                RuleSet: ComplianceRuleSetContract.Version1,
                Cases: Array.AsReadOnly(caseResults),
                Diagnostics: diagnostics,
                CorpusResultSha256: corpusResultSha256,
                EvidenceBoundary:
                    "Deterministic compliance-rule corpus only; this report does not prove immutable evidence storage, authorized review transitions, a role-distinct runtime workflow, retention, redaction, installed Herdr operation, or release readiness.");
            var reportJson = JsonSerializer.Serialize(report, OutputSerializerOptions) + "\n";
            new AtomicSchemaOutputWriter().Write(
                fullReportPath,
                new UTF8Encoding(encoderShouldEmitUTF8Identifier: false).GetBytes(reportJson));
            output.Write(reportJson);
            return 0;
        }
        catch (Exception exception) when (
            exception is ComplianceRuleContractException or
                ComplianceRuleCorpusCommandException or
                ArgumentException or
                JsonException or
                IOException or
                NotSupportedException or
                OverflowException or
                UnauthorizedAccessException)
        {
            error.WriteLine($"Compliance rule corpus failed: {exception.Message}");
            return EvaluationFailureExitCode;
        }
    }

    private static ComplianceRuleCorpusCaseResult RunCase(
        ComplianceRuleEngine engine,
        ComplianceRuleCorpusCase item)
    {
        var knownFindingIds = new HashSet<string>(StringComparer.Ordinal);
        var runs = new List<ComplianceEvaluationResult>(item.RepeatCount);
        for (var index = 0; index < item.RepeatCount; index++)
        {
            var run = engine.Evaluate(item.Request, knownFindingIds.ToArray());
            runs.Add(run);
            knownFindingIds.UnionWith(run.Findings.Select(finding => finding.FindingId));
        }

        var firstRun = runs[0];
        var firstRunFindingRuleKinds = firstRun.Findings
            .Select(finding => finding.RuleKind)
            .OrderBy(kind => kind)
            .ToArray();
        var firstRunErrorRuleKinds = firstRun.RuleEvaluations
            .Where(evaluation => evaluation.Outcome == ComplianceRuleOutcomeKind.Error)
            .Select(evaluation => evaluation.RuleKind)
            .OrderBy(kind => kind)
            .ToArray();
        var expectedFindingKinds = item.Expectation.FirstRunFindingRuleKinds
            .OrderBy(kind => kind)
            .ToArray();
        var expectedErrorKinds = item.Expectation.FirstRunErrorRuleKinds
            .OrderBy(kind => kind)
            .ToArray();
        var repeatedDuplicateCount = runs.Skip(1).Sum(run =>
            run.Diagnostics.DuplicateDetectionCount);
        if (firstRun.Findings.Count != item.Expectation.FirstRunFindingCount ||
            !firstRunFindingRuleKinds.SequenceEqual(expectedFindingKinds) ||
            !firstRunErrorRuleKinds.SequenceEqual(expectedErrorKinds) ||
            repeatedDuplicateCount != item.Expectation.RepeatedDuplicateDetectionCount ||
            firstRun.Diagnostics.ConfirmedFindingCount != 0)
        {
            throw new ComplianceRuleCorpusCommandException(
                $"Compliance corpus case '{item.CaseId}' did not match its declared expectation.");
        }

        return new ComplianceRuleCorpusCaseResult(
            item.CaseId,
            item.RepeatCount,
            Passed: true,
            Array.AsReadOnly(runs.ToArray()),
            repeatedDuplicateCount);
    }

    private static void ValidateInput(ComplianceRuleCorpusInputDocument input)
    {
        if (input.ContractVersion != ContractVersion)
        {
            throw new ComplianceRuleCorpusCommandException(
                $"Compliance corpus contract v{input.ContractVersion} is unsupported; expected v{ContractVersion}.");
        }

        if (input.Cases is null || input.Cases.Length == 0 || input.Cases.Length > MaximumCaseCount)
        {
            throw new ComplianceRuleCorpusCommandException(
                $"The compliance corpus requires 1 to {MaximumCaseCount} cases.");
        }

        var caseIds = new HashSet<string>(StringComparer.Ordinal);
        foreach (var item in input.Cases)
        {
            if (item is null ||
                string.IsNullOrWhiteSpace(item.CaseId) ||
                !string.Equals(item.CaseId, item.CaseId.Trim(), StringComparison.Ordinal) ||
                item.CaseId.Length > ComplianceEvaluationContract.MaximumIdentifierLength ||
                item.CaseId.Any(char.IsControl) ||
                !caseIds.Add(item.CaseId))
            {
                throw new ComplianceRuleCorpusCommandException(
                    "Every compliance corpus case requires one unique, unpadded, bounded case ID.");
            }

            if (item.RepeatCount is < 1 or > MaximumRepeatCount)
            {
                throw new ComplianceRuleCorpusCommandException(
                    $"Compliance corpus case '{item.CaseId}' requires a repeat count from 1 to {MaximumRepeatCount}.");
            }

            if (item.Request is null || item.Expectation is null ||
                item.Expectation.FirstRunFindingRuleKinds is null ||
                item.Expectation.FirstRunErrorRuleKinds is null ||
                item.Expectation.FirstRunFindingCount < 0 ||
                item.Expectation.RepeatedDuplicateDetectionCount < 0 ||
                item.Expectation.FirstRunFindingRuleKinds.Any(kind => !Enum.IsDefined(kind)) ||
                item.Expectation.FirstRunErrorRuleKinds.Any(kind => !Enum.IsDefined(kind)))
            {
                throw new ComplianceRuleCorpusCommandException(
                    $"Compliance corpus case '{item.CaseId}' contains an invalid expectation.");
            }
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
            !string.Equals(args[0], "compliance-rule-corpus", StringComparison.Ordinal))
        {
            error.WriteLine(args.Length == 0
                ? "Missing compliance rule corpus command."
                : $"Unknown compliance rule corpus command: {args[0]}");
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
            throw new ComplianceRuleCorpusCommandException(
                $"The compliance corpus input must contain 1 to {MaximumInputBytes} bytes; observed {stream.Length}.");
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
            "Usage: HerdrOps.Core compliance-rule-corpus --input <json-path> --report <json-path>");
}

public sealed record ComplianceRuleCorpusInputDocument(
    int ContractVersion,
    ComplianceRuleCorpusCase[] Cases);

public sealed record ComplianceRuleCorpusCase(
    string CaseId,
    int RepeatCount,
    ComplianceEvaluationRequest Request,
    ComplianceRuleCorpusExpectation Expectation);

public sealed record ComplianceRuleCorpusExpectation(
    int FirstRunFindingCount,
    ComplianceRuleKind[] FirstRunFindingRuleKinds,
    ComplianceRuleKind[] FirstRunErrorRuleKinds,
    int RepeatedDuplicateDetectionCount);

public sealed record ComplianceRuleCorpusCaseResult(
    string CaseId,
    int RepeatCount,
    bool Passed,
    IReadOnlyList<ComplianceEvaluationResult> Runs,
    int RepeatedDuplicateDetectionCount);

public sealed record ComplianceRuleCorpusDiagnostics(
    int CaseCount,
    int PassedCaseCount,
    int EvaluationRunCount,
    int FirstRunFindingCount,
    int ExplainabilityRecordCount,
    int FirstRunRuleErrorCount,
    int RepeatedDuplicateDetectionCount,
    int ConfirmedFindingCount,
    IReadOnlyList<ComplianceRuleKind> TriggeredRuleKinds,
    IReadOnlyList<ComplianceRuleKind> PassedRuleKinds);

public sealed record ComplianceRuleCorpusResultPayload(
    ComplianceRuleSet RuleSet,
    IReadOnlyList<ComplianceRuleCorpusCaseResult> Cases,
    ComplianceRuleCorpusDiagnostics Diagnostics);

public sealed record ComplianceRuleCorpusEvidenceReport(
    int ContractVersion,
    string EvidenceClass,
    bool RuntimeObserved,
    string InputSha256,
    ComplianceRuleSet RuleSet,
    IReadOnlyList<ComplianceRuleCorpusCaseResult> Cases,
    ComplianceRuleCorpusDiagnostics Diagnostics,
    string CorpusResultSha256,
    string EvidenceBoundary);

public sealed class ComplianceRuleCorpusCommandException : ArgumentException
{
    public ComplianceRuleCorpusCommandException(string message)
        : base(message)
    {
    }
}
