using System.Buffers.Binary;
using System.Globalization;
using System.Security.Cryptography;
using System.Text;

namespace HerdrOps.Domain.Compliance;

public enum ComplianceRuleKind
{
    ScopeViolation = 1,
    MissingEvidence = 2,
    UnapprovedDeviation = 3,
    ReviewOrder = 4,
}

public enum ComplianceSeverity
{
    Low = 1,
    Medium = 2,
    High = 3,
    Critical = 4,
}

public enum ComplianceRuleOutcomeKind
{
    Passed = 1,
    Suspected = 2,
    DuplicateSuppressed = 3,
    Error = 4,
}

public enum ComplianceFindingState
{
    Suspected = 1,
}

public enum ComplianceDeviationDecisionKind
{
    Pending = 1,
    Approved = 2,
    Rejected = 3,
}

public enum ComplianceReviewActionKind
{
    SendToLeader = 1,
    LeaderDecision = 2,
    EscalateToProjectManager = 3,
    ProjectManagerDecision = 4,
}

public enum ComplianceSupportingFactKind
{
    ScopeBoundary = 1,
    ActionObservation = 2,
    DeviationDecision = 3,
    EvidenceRequirement = 4,
    EvidenceSubmission = 5,
    ReviewObservation = 6,
}

public sealed record ComplianceRuleDefinition(
    string RuleId,
    int RuleVersion,
    ComplianceRuleKind RuleKind,
    ComplianceSeverity Severity);

public sealed record ComplianceRuleSet(
    int ContractVersion,
    string RuleSetId,
    int RuleSetVersion,
    IReadOnlyList<ComplianceRuleDefinition> Rules,
    string RuleSetSha256);

public sealed record ComplianceScopeBoundary(
    string InputId,
    string PathPrefix);

public sealed record ComplianceActionObservation(
    string InputId,
    string TargetPath,
    DateTimeOffset OccurredUtc,
    string? DeviationId);

public sealed record ComplianceDeviationDecision(
    string InputId,
    string DeviationId,
    string PathPrefix,
    ComplianceDeviationDecisionKind DecisionKind,
    DateTimeOffset RequestedUtc,
    DateTimeOffset? DecidedUtc);

public sealed record ComplianceEvidenceRequirement(
    string InputId,
    string RequirementId,
    string EvidenceType);

public sealed record ComplianceEvidenceSubmission(
    string InputId,
    string SubmissionId,
    string RequirementId,
    bool IsAdmitted);

public sealed record ComplianceReviewObservation(
    string InputId,
    long Sequence,
    ComplianceReviewActionKind ActionKind,
    string ReviewerActorId,
    DateTimeOffset OccurredUtc);

public sealed record ComplianceEvaluationRequest(
    int ContractVersion,
    string TaskId,
    string ActorId,
    IReadOnlyList<ComplianceScopeBoundary> ScopeBoundaries,
    IReadOnlyList<ComplianceActionObservation> Actions,
    IReadOnlyList<ComplianceDeviationDecision> Deviations,
    IReadOnlyList<ComplianceEvidenceRequirement> EvidenceRequirements,
    IReadOnlyList<ComplianceEvidenceSubmission> EvidenceSubmissions,
    IReadOnlyList<ComplianceReviewObservation> ReviewObservations);

public sealed record ComplianceSupportingFact(
    string InputId,
    ComplianceSupportingFactKind FactKind,
    string Subject,
    string Detail,
    DateTimeOffset? OccurredUtc);

public sealed record ComplianceFinding(
    string FindingId,
    ComplianceFindingState State,
    string RuleId,
    int RuleVersion,
    ComplianceRuleKind RuleKind,
    ComplianceSeverity Severity,
    string TaskId,
    string ActorId,
    string Subject,
    IReadOnlyList<ComplianceSupportingFact> SupportingFacts,
    string ExplainabilitySha256);

public sealed record ComplianceRuleEvaluation(
    string RuleId,
    int RuleVersion,
    ComplianceRuleKind RuleKind,
    ComplianceSeverity Severity,
    ComplianceRuleOutcomeKind Outcome,
    IReadOnlyList<string> ProducedFindingIds,
    IReadOnlyList<string> SuppressedFindingIds,
    IReadOnlyList<string> SupportingInputIds,
    string? ErrorCode,
    string? ErrorMessage);

public sealed record ComplianceEvaluationDiagnostics(
    int RuleCount,
    int PassedRuleCount,
    int SuspectedRuleCount,
    int DuplicateSuppressedRuleCount,
    int ErrorRuleCount,
    int ProducedFindingCount,
    int DuplicateDetectionCount,
    int KnownFindingCount,
    int ConfirmedFindingCount);

public sealed record ComplianceEvaluationResult(
    int ContractVersion,
    string TaskId,
    string ActorId,
    string RuleSetSha256,
    string RequestSha256,
    string KnownFindingSetSha256,
    IReadOnlyList<ComplianceRuleEvaluation> RuleEvaluations,
    IReadOnlyList<ComplianceFinding> Findings,
    ComplianceEvaluationDiagnostics Diagnostics,
    string ResultSha256);

public static class ComplianceRuleSetContract
{
    public const int ContractVersion = 1;
    public const int RuleSetVersion = 1;
    public const int RuleVersion = 1;
    public const string RuleSetId = "HERDROPS-COMPLIANCE-V1";

    private static readonly IReadOnlyDictionary<ComplianceRuleKind, ComplianceRuleDefinition>
        ExpectedDefinitions = new Dictionary<ComplianceRuleKind, ComplianceRuleDefinition>
        {
            [ComplianceRuleKind.ScopeViolation] = new(
                "HDO-CMP-SCOPE-001",
                RuleVersion,
                ComplianceRuleKind.ScopeViolation,
                ComplianceSeverity.Critical),
            [ComplianceRuleKind.MissingEvidence] = new(
                "HDO-CMP-EVIDENCE-001",
                RuleVersion,
                ComplianceRuleKind.MissingEvidence,
                ComplianceSeverity.High),
            [ComplianceRuleKind.UnapprovedDeviation] = new(
                "HDO-CMP-DEVIATION-001",
                RuleVersion,
                ComplianceRuleKind.UnapprovedDeviation,
                ComplianceSeverity.Medium),
            [ComplianceRuleKind.ReviewOrder] = new(
                "HDO-CMP-REVIEW-001",
                RuleVersion,
                ComplianceRuleKind.ReviewOrder,
                ComplianceSeverity.High),
        };

    public static ComplianceRuleSet Version1 { get; } = CreateVersion1();

    public static ComplianceRuleSet NormalizeAndValidate(ComplianceRuleSet ruleSet)
    {
        ArgumentNullException.ThrowIfNull(ruleSet);
        if (ruleSet.ContractVersion != ContractVersion ||
            ruleSet.RuleSetVersion != RuleSetVersion ||
            !string.Equals(ruleSet.RuleSetId, RuleSetId, StringComparison.Ordinal))
        {
            throw new ComplianceRuleContractException(
                $"Unsupported compliance rule set; expected {RuleSetId} contract v{ContractVersion} policy v{RuleSetVersion}.");
        }

        if (ruleSet.Rules is null || ruleSet.Rules.Count != ExpectedDefinitions.Count)
        {
            throw new ComplianceRuleContractException(
                $"Compliance rule set {RuleSetId} requires exactly {ExpectedDefinitions.Count} rule definitions.");
        }

        var normalizedRules = ruleSet.Rules
            .Select(NormalizeDefinition)
            .OrderBy(item => item.RuleKind)
            .ToArray();
        if (normalizedRules.Select(item => item.RuleKind).Distinct().Count() != normalizedRules.Length)
        {
            throw new ComplianceRuleContractException(
                "The compliance rule set contains a duplicate rule kind.");
        }

        foreach (var definition in normalizedRules)
        {
            if (!ExpectedDefinitions.TryGetValue(definition.RuleKind, out var expected) ||
                definition != expected)
            {
                throw new ComplianceRuleContractException(
                    $"Compliance rule definition for {definition.RuleKind} does not match versioned policy {RuleSetId} v{RuleSetVersion}.");
            }
        }

        var normalized = ruleSet with
        {
            Rules = Array.AsReadOnly(normalizedRules),
            RuleSetSha256 = string.Empty,
        };
        var expectedHash = ComputeSha256(normalized);
        var suppliedHash = ComplianceEvaluationContract.NormalizeSha256(
            ruleSet.RuleSetSha256,
            nameof(ruleSet.RuleSetSha256));
        if (!string.Equals(suppliedHash, expectedHash, StringComparison.Ordinal))
        {
            throw new ComplianceRuleContractException(
                "The compliance rule-set SHA-256 does not match its canonical definitions.");
        }

        return normalized with { RuleSetSha256 = expectedHash };
    }

    private static ComplianceRuleSet CreateVersion1()
    {
        var candidate = new ComplianceRuleSet(
            ContractVersion,
            RuleSetId,
            RuleSetVersion,
            Array.AsReadOnly(ExpectedDefinitions.Values.OrderBy(item => item.RuleKind).ToArray()),
            string.Empty);
        return candidate with { RuleSetSha256 = ComputeSha256(candidate) };
    }

    private static ComplianceRuleDefinition NormalizeDefinition(
        ComplianceRuleDefinition definition)
    {
        ArgumentNullException.ThrowIfNull(definition);
        if (!Enum.IsDefined(definition.RuleKind) || !Enum.IsDefined(definition.Severity))
        {
            throw new ComplianceRuleContractException(
                "A compliance rule definition contains an unsupported kind or severity.");
        }

        return definition with
        {
            RuleId = ComplianceEvaluationContract.NormalizeIdentifier(
                definition.RuleId,
                nameof(definition.RuleId)),
        };
    }

    private static string ComputeSha256(ComplianceRuleSet ruleSet)
    {
        using var writer = new ComplianceCanonicalHashWriter(
            "HerdrOps.ComplianceRuleSet.v1");
        writer.Write(ruleSet.ContractVersion);
        writer.Write(ruleSet.RuleSetId);
        writer.Write(ruleSet.RuleSetVersion);
        writer.Write(ruleSet.Rules.Count);
        foreach (var rule in ruleSet.Rules.OrderBy(item => item.RuleKind))
        {
            writer.Write(rule.RuleId);
            writer.Write(rule.RuleVersion);
            writer.Write((int)rule.RuleKind);
            writer.Write((int)rule.Severity);
        }

        return writer.Finish();
    }
}

public static class ComplianceEvaluationContract
{
    public const int ContractVersion = 1;
    public const int MaximumItemCount = 256;
    public const int MaximumIdentifierLength = 128;
    public const int MaximumPathLength = 1024;
    public const int MaximumDetailLength = 2048;

    public static ComplianceEvaluationRequest NormalizeAndValidate(
        ComplianceEvaluationRequest request)
    {
        ArgumentNullException.ThrowIfNull(request);
        if (request.ContractVersion != ContractVersion)
        {
            throw new ComplianceRuleContractException(
                $"Compliance evaluation contract v{request.ContractVersion} is unsupported; expected v{ContractVersion}.");
        }

        EnsureCollection(request.ScopeBoundaries, nameof(request.ScopeBoundaries));
        EnsureCollection(request.Actions, nameof(request.Actions));
        EnsureCollection(request.Deviations, nameof(request.Deviations));
        EnsureCollection(request.EvidenceRequirements, nameof(request.EvidenceRequirements));
        EnsureCollection(request.EvidenceSubmissions, nameof(request.EvidenceSubmissions));
        EnsureCollection(request.ReviewObservations, nameof(request.ReviewObservations));

        var normalized = request with
        {
            TaskId = NormalizeIdentifier(request.TaskId, nameof(request.TaskId)),
            ActorId = NormalizeIdentifier(request.ActorId, nameof(request.ActorId)),
            ScopeBoundaries = Array.AsReadOnly(request.ScopeBoundaries
                .Select(item => new ComplianceScopeBoundary(
                    NormalizeIdentifier(item.InputId, nameof(item.InputId)),
                    NormalizePath(item.PathPrefix, nameof(item.PathPrefix))))
                .OrderBy(item => item.InputId, StringComparer.Ordinal)
                .ToArray()),
            Actions = Array.AsReadOnly(request.Actions
                .Select(item => new ComplianceActionObservation(
                    NormalizeIdentifier(item.InputId, nameof(item.InputId)),
                    NormalizePath(item.TargetPath, nameof(item.TargetPath)),
                    EnsureUtc(item.OccurredUtc, nameof(item.OccurredUtc)),
                    NormalizeOptionalIdentifier(item.DeviationId, nameof(item.DeviationId))))
                .OrderBy(item => item.InputId, StringComparer.Ordinal)
                .ToArray()),
            Deviations = Array.AsReadOnly(request.Deviations
                .Select(NormalizeDeviation)
                .OrderBy(item => item.InputId, StringComparer.Ordinal)
                .ToArray()),
            EvidenceRequirements = Array.AsReadOnly(request.EvidenceRequirements
                .Select(item => new ComplianceEvidenceRequirement(
                    NormalizeIdentifier(item.InputId, nameof(item.InputId)),
                    NormalizeIdentifier(item.RequirementId, nameof(item.RequirementId)),
                    NormalizeDetail(item.EvidenceType, nameof(item.EvidenceType))))
                .OrderBy(item => item.InputId, StringComparer.Ordinal)
                .ToArray()),
            EvidenceSubmissions = Array.AsReadOnly(request.EvidenceSubmissions
                .Select(item => new ComplianceEvidenceSubmission(
                    NormalizeIdentifier(item.InputId, nameof(item.InputId)),
                    NormalizeIdentifier(item.SubmissionId, nameof(item.SubmissionId)),
                    NormalizeIdentifier(item.RequirementId, nameof(item.RequirementId)),
                    item.IsAdmitted))
                .OrderBy(item => item.InputId, StringComparer.Ordinal)
                .ToArray()),
            ReviewObservations = Array.AsReadOnly(request.ReviewObservations
                .Select(NormalizeReview)
                .OrderBy(item => item.Sequence)
                .ThenBy(item => item.InputId, StringComparer.Ordinal)
                .ToArray()),
        };

        EnsureUnique(normalized.ScopeBoundaries.Select(item => item.InputId), "scope input ID");
        EnsureUnique(normalized.Actions.Select(item => item.InputId), "action input ID");
        EnsureUnique(normalized.Deviations.Select(item => item.InputId), "deviation input ID");
        EnsureUnique(normalized.Deviations.Select(item => item.DeviationId), "deviation ID");
        EnsureUnique(normalized.EvidenceRequirements.Select(item => item.InputId), "evidence-requirement input ID");
        EnsureUnique(normalized.EvidenceRequirements.Select(item => item.RequirementId), "evidence requirement ID");
        EnsureUnique(normalized.EvidenceSubmissions.Select(item => item.InputId), "evidence-submission input ID");
        EnsureUnique(normalized.EvidenceSubmissions.Select(item => item.SubmissionId), "evidence submission ID");
        EnsureUnique(normalized.ReviewObservations.Select(item => item.InputId), "review input ID");
        EnsureUnique(
            normalized.ScopeBoundaries.Select(item => item.InputId)
                .Concat(normalized.Actions.Select(item => item.InputId))
                .Concat(normalized.Deviations.Select(item => item.InputId))
                .Concat(normalized.EvidenceRequirements.Select(item => item.InputId))
                .Concat(normalized.EvidenceSubmissions.Select(item => item.InputId))
                .Concat(normalized.ReviewObservations.Select(item => item.InputId)),
            "global supporting-fact input ID");
        return normalized;
    }

    public static string ComputeRequestSha256(ComplianceEvaluationRequest request)
    {
        var normalized = NormalizeAndValidate(request);
        using var writer = new ComplianceCanonicalHashWriter(
            "HerdrOps.ComplianceEvaluationRequest.v1");
        writer.Write(normalized.ContractVersion);
        writer.Write(normalized.TaskId);
        writer.Write(normalized.ActorId);
        writer.Write(normalized.ScopeBoundaries.Count);
        foreach (var item in normalized.ScopeBoundaries)
        {
            writer.Write(item.InputId);
            writer.Write(item.PathPrefix);
        }

        writer.Write(normalized.Actions.Count);
        foreach (var item in normalized.Actions)
        {
            writer.Write(item.InputId);
            writer.Write(item.TargetPath);
            writer.Write(item.OccurredUtc);
            writer.Write(item.DeviationId);
        }

        writer.Write(normalized.Deviations.Count);
        foreach (var item in normalized.Deviations)
        {
            writer.Write(item.InputId);
            writer.Write(item.DeviationId);
            writer.Write(item.PathPrefix);
            writer.Write((int)item.DecisionKind);
            writer.Write(item.RequestedUtc);
            writer.Write(item.DecidedUtc);
        }

        writer.Write(normalized.EvidenceRequirements.Count);
        foreach (var item in normalized.EvidenceRequirements)
        {
            writer.Write(item.InputId);
            writer.Write(item.RequirementId);
            writer.Write(item.EvidenceType);
        }

        writer.Write(normalized.EvidenceSubmissions.Count);
        foreach (var item in normalized.EvidenceSubmissions)
        {
            writer.Write(item.InputId);
            writer.Write(item.SubmissionId);
            writer.Write(item.RequirementId);
            writer.Write(item.IsAdmitted);
        }

        writer.Write(normalized.ReviewObservations.Count);
        foreach (var item in normalized.ReviewObservations)
        {
            writer.Write(item.InputId);
            writer.Write(item.Sequence);
            writer.Write((int)item.ActionKind);
            writer.Write(item.ReviewerActorId);
            writer.Write(item.OccurredUtc);
        }

        return writer.Finish();
    }

    internal static string NormalizeIdentifier(string value, string name)
    {
        if (string.IsNullOrWhiteSpace(value))
        {
            throw new ComplianceRuleContractException(
                $"Compliance field {name} must be a non-blank identifier.");
        }

        var normalized = value.Normalize(NormalizationForm.FormC);
        if (!string.Equals(normalized, normalized.Trim(), StringComparison.Ordinal) ||
            normalized.Length > MaximumIdentifierLength ||
            normalized.Any(char.IsControl))
        {
            throw new ComplianceRuleContractException(
                $"Compliance field {name} must be unpadded, at most {MaximumIdentifierLength} characters, and contain no control characters.");
        }

        return normalized;
    }

    internal static string NormalizeSha256(string value, string name)
    {
        if (value is null || value.Length != 64 || !value.All(IsHexCharacter))
        {
            throw new ComplianceRuleContractException(
                $"Compliance field {name} must contain exactly 64 hexadecimal characters.");
        }

        return value.ToUpperInvariant();
    }

    internal static string NormalizeDetail(string value, string name)
    {
        if (string.IsNullOrWhiteSpace(value))
        {
            throw new ComplianceRuleContractException(
                $"Compliance field {name} cannot be blank.");
        }

        var normalized = value
            .Replace("\r\n", "\n", StringComparison.Ordinal)
            .Replace('\r', '\n')
            .Normalize(NormalizationForm.FormC);
        if (normalized.Length > MaximumDetailLength ||
            normalized.Any(character =>
                char.IsControl(character) && character is not ('\n' or '\t')))
        {
            throw new ComplianceRuleContractException(
                $"Compliance field {name} must be at most {MaximumDetailLength} characters and contain no unsupported control characters.");
        }

        return normalized;
    }

    internal static string NormalizePath(string value, string name)
    {
        if (string.IsNullOrWhiteSpace(value))
        {
            throw new ComplianceRuleContractException(
                $"Compliance path {name} cannot be blank.");
        }

        var normalized = value.Normalize(NormalizationForm.FormC);
        if (normalized.Any(char.IsControl))
        {
            throw new ComplianceRuleContractException(
                $"Compliance path {name} must not contain control characters.");
        }

        normalized = normalized.Replace('\\', '/');
        if (normalized.Length > MaximumPathLength ||
            normalized.StartsWith("/", StringComparison.Ordinal) ||
            normalized.EndsWith("/", StringComparison.Ordinal) ||
            normalized.Contains(':', StringComparison.Ordinal))
        {
            throw new ComplianceRuleContractException(
                $"Compliance path {name} must be a relative Windows project path of at most {MaximumPathLength} characters.");
        }

        var segments = normalized.Split('/', StringSplitOptions.None);
        if (segments.Any(segment =>
                string.IsNullOrWhiteSpace(segment) ||
                segment is "." or ".." ||
                segment.EndsWith(".", StringComparison.Ordinal) ||
                segment.EndsWith(" ", StringComparison.Ordinal)))
        {
            throw new ComplianceRuleContractException(
                $"Compliance path {name} cannot contain empty, current-directory, parent-directory, or trailing-dot/space segments.");
        }

        return string.Join('/', segments);
    }

    private static ComplianceDeviationDecision NormalizeDeviation(
        ComplianceDeviationDecision item)
    {
        if (!Enum.IsDefined(item.DecisionKind))
        {
            throw new ComplianceRuleContractException(
                "A deviation contains an unsupported decision kind.");
        }

        var requestedUtc = EnsureUtc(item.RequestedUtc, nameof(item.RequestedUtc));
        DateTimeOffset? decidedUtc = item.DecidedUtc is null
            ? null
            : EnsureUtc(item.DecidedUtc.Value, nameof(item.DecidedUtc));
        if (item.DecisionKind == ComplianceDeviationDecisionKind.Pending && decidedUtc is not null)
        {
            throw new ComplianceRuleContractException(
                "A pending deviation cannot have a decision time.");
        }

        if (item.DecisionKind != ComplianceDeviationDecisionKind.Pending && decidedUtc is null)
        {
            throw new ComplianceRuleContractException(
                "An approved or rejected deviation requires a decision time.");
        }

        if (decidedUtc < requestedUtc)
        {
            throw new ComplianceRuleContractException(
                "A deviation decision cannot precede its request.");
        }

        return item with
        {
            InputId = NormalizeIdentifier(item.InputId, nameof(item.InputId)),
            DeviationId = NormalizeIdentifier(item.DeviationId, nameof(item.DeviationId)),
            PathPrefix = NormalizePath(item.PathPrefix, nameof(item.PathPrefix)),
            RequestedUtc = requestedUtc,
            DecidedUtc = decidedUtc,
        };
    }

    private static ComplianceReviewObservation NormalizeReview(
        ComplianceReviewObservation item)
    {
        if (item.Sequence <= 0)
        {
            throw new ComplianceRuleContractException(
                "A compliance review sequence must be positive.");
        }

        if (!Enum.IsDefined(item.ActionKind))
        {
            throw new ComplianceRuleContractException(
                "A review observation contains an unsupported action kind.");
        }

        return item with
        {
            InputId = NormalizeIdentifier(item.InputId, nameof(item.InputId)),
            ReviewerActorId = NormalizeIdentifier(
                item.ReviewerActorId,
                nameof(item.ReviewerActorId)),
            OccurredUtc = EnsureUtc(item.OccurredUtc, nameof(item.OccurredUtc)),
        };
    }

    private static string? NormalizeOptionalIdentifier(string? value, string name) =>
        value is null ? null : NormalizeIdentifier(value, name);

    private static DateTimeOffset EnsureUtc(DateTimeOffset value, string name)
    {
        if (value.Offset != TimeSpan.Zero)
        {
            throw new ComplianceRuleContractException(
                $"Compliance field {name} must be UTC.");
        }

        return value;
    }

    private static void EnsureCollection<T>(IReadOnlyList<T>? collection, string name)
    {
        if (collection is null || collection.Count > MaximumItemCount || collection.Any(item => item is null))
        {
            throw new ComplianceRuleContractException(
                $"Compliance collection {name} must be present, contain no null items, and contain at most {MaximumItemCount} items.");
        }
    }

    private static void EnsureUnique(IEnumerable<string> values, string description)
    {
        var observed = new HashSet<string>(StringComparer.Ordinal);
        foreach (var value in values)
        {
            if (!observed.Add(value))
            {
                throw new ComplianceRuleContractException(
                    $"The compliance request contains duplicate {description} '{value}'.");
            }
        }
    }

    private static bool IsHexCharacter(char value) =>
        value is >= '0' and <= '9' or >= 'A' and <= 'F' or >= 'a' and <= 'f';
}

internal sealed class ComplianceCanonicalHashWriter : IDisposable
{
    private readonly IncrementalHash _hash = IncrementalHash.CreateHash(HashAlgorithmName.SHA256);
    private bool _finished;

    public ComplianceCanonicalHashWriter(string domain)
    {
        Write(domain);
    }

    public void Write(string? value)
    {
        if (value is null)
        {
            WriteLength(-1);
            return;
        }

        var bytes = Encoding.UTF8.GetBytes(value);
        WriteLength(bytes.Length);
        _hash.AppendData(bytes);
    }

    public void Write(int value)
    {
        Span<byte> bytes = stackalloc byte[sizeof(int)];
        BinaryPrimitives.WriteInt32LittleEndian(bytes, value);
        _hash.AppendData(bytes);
    }

    public void Write(long value)
    {
        Span<byte> bytes = stackalloc byte[sizeof(long)];
        BinaryPrimitives.WriteInt64LittleEndian(bytes, value);
        _hash.AppendData(bytes);
    }

    public void Write(bool value) => Write(value ? 1 : 0);

    public void Write(DateTimeOffset value) =>
        Write(value.ToString("O", CultureInfo.InvariantCulture));

    public void Write(DateTimeOffset? value)
    {
        Write(value.HasValue);
        if (value.HasValue)
        {
            Write(value.Value);
        }
    }

    public string Finish()
    {
        ObjectDisposedException.ThrowIf(_finished, this);
        _finished = true;
        return Convert.ToHexString(_hash.GetHashAndReset());
    }

    public void Dispose()
    {
        _hash.Dispose();
        _finished = true;
    }

    private void WriteLength(int value)
    {
        Span<byte> bytes = stackalloc byte[sizeof(int)];
        BinaryPrimitives.WriteInt32LittleEndian(bytes, value);
        _hash.AppendData(bytes);
    }
}

public sealed class ComplianceRuleContractException : ArgumentException
{
    public ComplianceRuleContractException(string message)
        : base(message)
    {
    }
}
