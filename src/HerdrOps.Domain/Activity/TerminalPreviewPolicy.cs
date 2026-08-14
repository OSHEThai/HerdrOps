using System.Security.Cryptography;
using System.Text;
using System.Text.RegularExpressions;

namespace HerdrOps.Domain.Activity;

public static class TerminalPreviewContract
{
    public const int DefaultMaximumLines = 80;
    public const int HardMaximumLines = 200;
    public const int MaximumInputUtf8Bytes = 256 * 1024;
    public const int MaximumSummaryCharacters = ActivityEventContract.MaximumSummaryLength;
    public const int MaximumSummaryUtf8Bytes = 4 * 1024;
}

public sealed record SensitiveTextRedactorOptions(
    int MaximumInputUtf8Bytes,
    int MaximumOutputCharacters,
    int MaximumOutputUtf8Bytes)
{
    public static SensitiveTextRedactorOptions Default { get; } = new(
        TerminalPreviewContract.MaximumInputUtf8Bytes,
        TerminalPreviewContract.MaximumSummaryCharacters,
        TerminalPreviewContract.MaximumSummaryUtf8Bytes);

    public void Validate()
    {
        if (MaximumInputUtf8Bytes is < 256 or > 1024 * 1024)
        {
            throw new ArgumentOutOfRangeException(
                nameof(MaximumInputUtf8Bytes),
                "The redaction input bound must be between 256 bytes and 1 MiB.");
        }

        if (MaximumOutputCharacters is < 64 or > TerminalPreviewContract.MaximumSummaryCharacters)
        {
            throw new ArgumentOutOfRangeException(
                nameof(MaximumOutputCharacters),
                $"The redacted output must contain between 64 and {TerminalPreviewContract.MaximumSummaryCharacters} characters.");
        }

        if (MaximumOutputUtf8Bytes is < 256 or > 64 * 1024)
        {
            throw new ArgumentOutOfRangeException(
                nameof(MaximumOutputUtf8Bytes),
                "The redacted output bound must be between 256 bytes and 64 KiB.");
        }
    }
}

public sealed record SensitiveTextRedactionResult(
    string RedactedText,
    string OriginalSha256,
    string RedactedSha256,
    int OriginalUtf8Bytes,
    int RedactedUtf8Bytes,
    int ReplacementCount,
    bool WasTruncated);

/// <summary>
/// Deterministically redacts common credentials before a terminal or command-line summary
/// can enter the activity pipeline. Raw input is hashed transiently and is never retained.
/// </summary>
public sealed class SensitiveTextRedactor
{
    private const string Replacement = "[REDACTED]";
    private static readonly TimeSpan RegexTimeout = TimeSpan.FromMilliseconds(100);
    private static readonly Regex AssignmentPattern = CreateRegex(
        "(?<prefix>\\b(?:[A-Z0-9_]*(?:TOKEN|SECRET|PASSWORD|PASSWD|API[_-]?KEY|PRIVATE[_-]?KEY|CONNECTION[_-]?STRING)[A-Z0-9_]*)\\s*[=:]\\s*)(?:\"[^\"\\r\\n]*\"|'[^'\\r\\n]*'|[^\\s;&\\r\\n]+)");
    private static readonly Regex AuthorizationPattern = CreateRegex(
        "(?<prefix>\\bAuthorization\\s*:\\s*(?:Bearer|Basic)\\s+)[^\\s\\r\\n]+");
    private static readonly Regex UriCredentialPattern = CreateRegex(
        "(?<prefix>://[^/\\s:@]+:)[^@\\s/]+(?<suffix>@)");
    private static readonly Regex UriUserInfoPattern = CreateRegex(
        "(?<prefix>://)[^/\\s:@]+(?<suffix>@)");
    private static readonly Regex KnownTokenPattern = CreateRegex(
        "\\b(?:github_pat_[A-Z0-9_]{20,}|ghs_[A-Z0-9_]+(?:\\.[A-Z0-9_-]{8,}){2}|gh[pousr]_[A-Z0-9_]{16,}|sk-[A-Z0-9_-]{16,})\\b");
    private static readonly Regex JwtPattern = CreateRegex(
        "\\beyJ[A-Z0-9_-]{8,}\\.[A-Z0-9_-]{8,}\\.[A-Z0-9_-]{8,}\\b");

    private readonly SensitiveTextRedactorOptions _options;

    public SensitiveTextRedactor(SensitiveTextRedactorOptions? options = null)
    {
        _options = options ?? SensitiveTextRedactorOptions.Default;
        _options.Validate();
    }

    public SensitiveTextRedactionResult Redact(string value)
    {
        ArgumentNullException.ThrowIfNull(value);
        var originalBytes = Encoding.UTF8.GetBytes(value);
        if (originalBytes.Length > _options.MaximumInputUtf8Bytes)
        {
            throw new ArgumentOutOfRangeException(
                nameof(value),
                $"Sensitive text exceeded the {_options.MaximumInputUtf8Bytes}-byte input bound.");
        }

        var normalized = NormalizeControls(value);
        var replacementCount = 0;
        normalized = ReplaceWithGroups(AssignmentPattern, normalized, ref replacementCount);
        normalized = ReplaceWithGroups(AuthorizationPattern, normalized, ref replacementCount);
        normalized = ReplaceWithGroups(UriCredentialPattern, normalized, ref replacementCount);
        normalized = ReplaceWithGroups(UriUserInfoPattern, normalized, ref replacementCount);
        normalized = ReplaceWhole(KnownTokenPattern, normalized, ref replacementCount);
        normalized = ReplaceWhole(JwtPattern, normalized, ref replacementCount);
        if (string.IsNullOrWhiteSpace(normalized))
        {
            normalized = "[EMPTY]";
        }

        var bounded = BoundUtf8(
            normalized,
            _options.MaximumOutputCharacters,
            _options.MaximumOutputUtf8Bytes,
            out var wasTruncated);
        var redactedBytes = Encoding.UTF8.GetBytes(bounded);
        return new SensitiveTextRedactionResult(
            bounded,
            Convert.ToHexString(SHA256.HashData(originalBytes)),
            Convert.ToHexString(SHA256.HashData(redactedBytes)),
            originalBytes.Length,
            redactedBytes.Length,
            replacementCount,
            wasTruncated);
    }

    private static Regex CreateRegex(string pattern) => new(
        pattern,
        RegexOptions.Compiled |
        RegexOptions.CultureInvariant |
        RegexOptions.IgnoreCase |
        RegexOptions.NonBacktracking,
        RegexTimeout);

    private static string ReplaceWithGroups(Regex pattern, string value, ref int count)
    {
        var localCount = 0;
        var result = pattern.Replace(value, match =>
        {
            localCount++;
            var prefix = match.Groups["prefix"].Success
                ? match.Groups["prefix"].Value
                : string.Empty;
            var suffix = match.Groups["suffix"].Success
                ? match.Groups["suffix"].Value
                : string.Empty;
            return prefix + Replacement + suffix;
        });
        count += localCount;
        return result;
    }

    private static string ReplaceWhole(Regex pattern, string value, ref int count)
    {
        var localCount = 0;
        var result = pattern.Replace(value, _ =>
        {
            localCount++;
            return Replacement;
        });
        count += localCount;
        return result;
    }

    private static string NormalizeControls(string value)
    {
        var normalized = value
            .Replace("\r\n", "\n", StringComparison.Ordinal)
            .Replace('\r', '\n')
            .Normalize(NormalizationForm.FormC);
        var builder = new StringBuilder(normalized.Length);
        foreach (var character in normalized)
        {
            if (!char.IsControl(character) || character is '\n' or '\t')
            {
                builder.Append(character);
            }
        }

        return builder.ToString();
    }

    private static string BoundUtf8(
        string value,
        int maximumCharacters,
        int maximumUtf8Bytes,
        out bool truncated)
    {
        const string marker = "…";
        var markerBytes = Encoding.UTF8.GetByteCount(marker);
        var builder = new StringBuilder(Math.Min(value.Length, maximumCharacters));
        var characterCount = 0;
        var utf8Bytes = 0;
        truncated = false;
        foreach (var rune in value.EnumerateRunes())
        {
            var nextCharacters = characterCount + rune.Utf16SequenceLength;
            var nextBytes = utf8Bytes + rune.Utf8SequenceLength;
            if (nextCharacters > maximumCharacters - marker.Length ||
                nextBytes > maximumUtf8Bytes - markerBytes)
            {
                truncated = true;
                break;
            }

            builder.Append(rune);
            characterCount = nextCharacters;
            utf8Bytes = nextBytes;
        }

        if (truncated)
        {
            builder.Append(marker);
        }

        return builder.ToString();
    }
}

public sealed record TerminalReadPlannerOptions(
    int MaximumLines,
    int MaximumTrackedPanes,
    TimeSpan MinimumReadInterval)
{
    public static TerminalReadPlannerOptions Default { get; } = new(
        TerminalPreviewContract.DefaultMaximumLines,
        128,
        TimeSpan.FromSeconds(2));

    public void Validate()
    {
        if (MaximumLines is < 1 or > TerminalPreviewContract.HardMaximumLines)
        {
            throw new ArgumentOutOfRangeException(
                nameof(MaximumLines),
                $"Terminal preview reads must request between 1 and {TerminalPreviewContract.HardMaximumLines} lines.");
        }

        if (MaximumTrackedPanes is < 1 or > 4096)
        {
            throw new ArgumentOutOfRangeException(
                nameof(MaximumTrackedPanes),
                "The tracked pane bound must be between 1 and 4096.");
        }

        if (MinimumReadInterval < TimeSpan.FromMilliseconds(100) ||
            MinimumReadInterval > TimeSpan.FromMinutes(5))
        {
            throw new ArgumentOutOfRangeException(
                nameof(MinimumReadInterval),
                "The pane read interval must be between 100 milliseconds and 5 minutes.");
        }
    }
}

public enum TerminalReadDecisionKind
{
    Read = 1,
    RevisionUnchanged = 2,
    RevisionRegressed = 3,
    Debounced = 4,
}

public sealed record TerminalReadDecision(
    TerminalReadDecisionKind Kind,
    string PaneId,
    ulong Revision,
    int MaximumLines,
    DateTimeOffset? EarliestNextReadUtc)
{
    public bool ShouldRead => Kind == TerminalReadDecisionKind.Read;
}

/// <summary>
/// Plans bounded reads from pane revisions. A failed read may be retried after the minimum
/// interval; a successful revision is never read again.
/// </summary>
public sealed class TerminalReadPlanner
{
    private readonly object _gate = new();
    private readonly TerminalReadPlannerOptions _options;
    private readonly Dictionary<string, PaneReadState> _panes = new(StringComparer.Ordinal);
    private long _attemptCount;
    private long _successCount;
    private long _evictionCount;

    public TerminalReadPlanner(TerminalReadPlannerOptions? options = null)
    {
        _options = options ?? TerminalReadPlannerOptions.Default;
        _options.Validate();
    }

    public long AttemptCount { get { lock (_gate) { return _attemptCount; } } }

    public long SuccessCount { get { lock (_gate) { return _successCount; } } }

    public long EvictionCount { get { lock (_gate) { return _evictionCount; } } }

    public int TrackedPaneCount { get { lock (_gate) { return _panes.Count; } } }

    public TerminalReadDecision Evaluate(
        string paneId,
        ulong revision,
        DateTimeOffset observedUtc)
    {
        ValidatePaneId(paneId);
        EnsureUtc(observedUtc, nameof(observedUtc));
        lock (_gate)
        {
            if (!_panes.TryGetValue(paneId, out var state))
            {
                EnsureCapacity();
                state = new PaneReadState(revision, null, null, observedUtc);
                _panes.Add(paneId, state);
            }
            else
            {
                if (observedUtc < state.LastObservedUtc)
                {
                    throw new ArgumentException(
                        "Pane revision observations must not move backward in time.",
                        nameof(observedUtc));
                }

                state = state with
                {
                    LatestRevision = Math.Max(state.LatestRevision, revision),
                    LastObservedUtc = observedUtc,
                };
                _panes[paneId] = state;
            }

            if (state.LastSuccessfulRevision is { } successfulRevision)
            {
                if (revision < successfulRevision)
                {
                    return new TerminalReadDecision(
                        TerminalReadDecisionKind.RevisionRegressed,
                        paneId,
                        revision,
                        _options.MaximumLines,
                        null);
                }

                if (revision == successfulRevision)
                {
                    return new TerminalReadDecision(
                        TerminalReadDecisionKind.RevisionUnchanged,
                        paneId,
                        revision,
                        _options.MaximumLines,
                        null);
                }
            }

            if (state.LastAttemptUtc is { } lastAttempt)
            {
                var nextReadUtc = lastAttempt + _options.MinimumReadInterval;
                if (observedUtc < nextReadUtc)
                {
                    return new TerminalReadDecision(
                        TerminalReadDecisionKind.Debounced,
                        paneId,
                        revision,
                        _options.MaximumLines,
                        nextReadUtc);
                }
            }

            _panes[paneId] = state with { LastAttemptUtc = observedUtc };
            _attemptCount++;
            return new TerminalReadDecision(
                TerminalReadDecisionKind.Read,
                paneId,
                revision,
                _options.MaximumLines,
                null);
        }
    }

    public void RecordSuccess(string paneId, ulong revision, DateTimeOffset observedUtc)
    {
        ValidatePaneId(paneId);
        EnsureUtc(observedUtc, nameof(observedUtc));
        lock (_gate)
        {
            if (!_panes.TryGetValue(paneId, out var state))
            {
                throw new InvalidOperationException(
                    "A terminal read cannot succeed without a preceding planner decision.");
            }

            if (state.LastAttemptUtc is null || observedUtc < state.LastAttemptUtc)
            {
                throw new InvalidOperationException(
                    "A terminal read result cannot precede its read attempt.");
            }

            _panes[paneId] = state with
            {
                LatestRevision = Math.Max(state.LatestRevision, revision),
                LastSuccessfulRevision = revision,
                LastObservedUtc = observedUtc,
            };
            _successCount++;
        }
    }

    private void EnsureCapacity()
    {
        if (_panes.Count < _options.MaximumTrackedPanes)
        {
            return;
        }

        var eviction = _panes
            .OrderBy(item => item.Value.LastObservedUtc)
            .ThenBy(item => item.Key, StringComparer.Ordinal)
            .First();
        _panes.Remove(eviction.Key);
        _evictionCount++;
    }

    private static void ValidatePaneId(string paneId)
    {
        if (string.IsNullOrWhiteSpace(paneId) ||
            paneId.Length > ActivityEventContract.MaximumIdentifierLength ||
            !string.Equals(paneId, paneId.Trim(), StringComparison.Ordinal) ||
            paneId.Any(char.IsControl))
        {
            throw new ArgumentException("The pane identifier is outside accepted bounds.", nameof(paneId));
        }
    }

    private static void EnsureUtc(DateTimeOffset value, string name)
    {
        if (value.Offset != TimeSpan.Zero)
        {
            throw new ArgumentException("Terminal read timestamps must be UTC.", name);
        }
    }

    private sealed record PaneReadState(
        ulong LatestRevision,
        ulong? LastSuccessfulRevision,
        DateTimeOffset? LastAttemptUtc,
        DateTimeOffset LastObservedUtc);
}

public sealed record TerminalPreviewPayload(
    string PaneId,
    string? AgentTerminalId,
    ulong Revision,
    bool SourceTruncated,
    string Text,
    DateTimeOffset ObservedUtc);

public sealed record TerminalPreviewObservation(
    string PaneId,
    string? AgentTerminalId,
    ulong Revision,
    bool SourceTruncated,
    DateTimeOffset ObservedUtc,
    string RedactedSummary,
    string RawPayloadSha256,
    string RedactedPayloadSha256,
    int RawUtf8Bytes,
    int RedactedUtf8Bytes,
    int RedactionCount,
    bool SummaryTruncated);

public static class TerminalPreviewSanitizer
{
    public static TerminalPreviewObservation Sanitize(
        TerminalPreviewPayload payload,
        SensitiveTextRedactor redactor)
    {
        ArgumentNullException.ThrowIfNull(payload);
        ArgumentNullException.ThrowIfNull(redactor);
        if (string.IsNullOrWhiteSpace(payload.PaneId))
        {
            throw new ArgumentException("A terminal preview requires a pane identifier.", nameof(payload));
        }

        if (payload.ObservedUtc.Offset != TimeSpan.Zero)
        {
            throw new ArgumentException("A terminal preview timestamp must be UTC.", nameof(payload));
        }

        var redaction = redactor.Redact(payload.Text);
        return new TerminalPreviewObservation(
            payload.PaneId,
            payload.AgentTerminalId,
            payload.Revision,
            payload.SourceTruncated,
            payload.ObservedUtc,
            redaction.RedactedText,
            redaction.OriginalSha256,
            redaction.RedactedSha256,
            redaction.OriginalUtf8Bytes,
            redaction.RedactedUtf8Bytes,
            redaction.ReplacementCount,
            redaction.WasTruncated);
    }
}
