using System.Globalization;
using System.Net;
using System.Security.Cryptography;
using System.Text;
using System.Text.RegularExpressions;

namespace HerdrOps.Domain.Diagnostics;

public sealed record DiagnosticRedactionResult(
    string Text,
    int ReplacementCount,
    bool WasTruncated,
    int OriginalUtf8Bytes,
    int RedactedUtf8Bytes);

/// <summary>
/// Redacts configured values and common credential forms from caller-selected diagnostic
/// excerpts. It never reads environment variables, files, terminals, processes, or sockets.
/// </summary>
public sealed class DiagnosticTextRedactor
{
    public const string Replacement = "[REDACTED]";
    public const string UserProfileReplacement = "[USER_PROFILE_PATH]";
    public const string SocketReplacement = "[SOCKET_PATH]";

    private static readonly TimeSpan RegexTimeout = TimeSpan.FromSeconds(1);
    private static readonly Regex AssignmentPattern = CreateRegex(
        "(?<prefix>\\b[A-Z0-9][A-Z0-9_.-]*(?:TOKEN|SECRET|PASSWORD|PASSWD|API[_-]?KEY|PRIVATE[_-]?KEY|CLIENT[_-]?SECRET|ACCESS[_-]?KEY|AUTH(?:ORIZATION)?|CREDENTIAL|CONNECTION(?:[_-]?STRING)?|SOCKET(?:[_-]?PATH)?|COOKIE)[A-Z0-9_.-]*\\s*[:=]\\s*)(?:\"[^\"\\r\\n]*\"|'[^'\\r\\n]*'|[^\\s,;&\\r\\n]+)");
    private static readonly Regex CommandAssignmentPattern = CreateRegex(
        "(?<prefix>--?(?:token|secret|password|passwd|api[_-]?key|private[_-]?key|client[_-]?secret|access[_-]?key|authorization|credential|connection(?:[_-]?string)?|socket(?:[_-]?path)?|cookie)(?:\\s+|=))(?:\"[^\"\\r\\n]*\"|'[^'\\r\\n]*'|[^\\s,;&\\r\\n]+)");
    private static readonly Regex JsonKeyPattern = CreateRegex(
        "(?<prefix>\"?(?:token|secret|password|passwd|api[_-]?key|private[_-]?key|client[_-]?secret|access[_-]?key|authorization|credential|connection(?:[_-]?string)?|socket(?:[_-]?path)?|cookie)\"?\\s*:\\s*)(?:\"[^\"\\r\\n]*\"|'[^'\\r\\n]*'|[^\\s,}\\r\\n]+)");
    private static readonly Regex HeaderPattern = CreateRegex(
        "(?<prefix>\\b(?:authorization|proxy-authorization|cookie|set-cookie|x-api-key|x-auth-token|api-key)\\s*:\\s*)(?:\"[^\"\\r\\n]*\"|'[^'\\r\\n]*'|[^\\s,;\\r\\n]+)");
    private static readonly Regex BearerPattern = CreateRegex(
        "\\b(?:bearer|basic)\\s+[^\\s\\r\\n,;]+",
        RegexOptions.IgnoreCase | RegexOptions.CultureInvariant | RegexOptions.NonBacktracking);
    private static readonly Regex UriCredentialPattern = CreateRegex(
        "(?<prefix>://)[^/@\\s:]+(?::[^/@\\s]*)?(?<suffix>@)");
    private static readonly Regex QueryCredentialPattern = CreateRegex(
        "(?<prefix>[?&](?:token|access[_-]?token|api[_-]?key|key|secret|password|sig|signature)=)[^&#\\s]+(?<suffix>[&#\\s]|$)");
    private static readonly Regex PrivateKeyPattern = CreateBacktrackingRegex(
        "-----BEGIN [A-Z0-9 ]*PRIVATE KEY-----.*?-----END [A-Z0-9 ]*PRIVATE KEY-----",
        RegexOptions.Singleline);
    private static readonly Regex KnownTokenPattern = CreateRegex(
        "\\b(?:github_pat_[A-Z0-9_]{20,}|gh[pousr]_[A-Z0-9_]{16,}|ghs_[A-Z0-9_]+(?:\\.[A-Z0-9_-]{8,}){2}|sk-[A-Z0-9_-]{16,}|xox[baprs]-[A-Z0-9-]{16,}|npm_[A-Z0-9]{20,}|pypi-[A-Z0-9_-]{16,}|AKIA[0-9A-Z]{16}|ASIA[0-9A-Z]{16})\\b");
    private static readonly Regex JwtPattern = CreateRegex(
        "\\beyJ[A-Z0-9_-]{8,}\\.[A-Z0-9_-]{8,}\\.[A-Z0-9_-]{8,}\\b");
    private static readonly Regex UserProfilePathPattern = CreateRegex(
        "(?:[A-Z]:[\\\\/]|/)(?:users|home)[\\\\/][^\\\\/\\s:*?\"<>|]+(?:[\\\\/][^\\\\/\\s:*?\"<>|]+)*",
        RegexOptions.IgnoreCase | RegexOptions.CultureInvariant | RegexOptions.NonBacktracking);
    private static readonly Regex UserProfileVariablePattern = CreateRegex(
        "(?:%USERPROFILE%|\\$env:USERPROFILE|\\$USERPROFILE)(?:[\\\\/][^\\\\/\\s:*?\"<>|]+)*",
        RegexOptions.IgnoreCase | RegexOptions.CultureInvariant | RegexOptions.NonBacktracking);
    private static readonly Regex SocketPathPattern = CreateRegex(
        "(?:[A-Z]:[\\\\/][^\\s\"']*\\bherdr\\.sock\\b|/[^\\s\"']*/herdr\\.sock\\b|\\\\\\\\[^\\s\"']+\\\\(?:pipe|socket)[^\\s\"']*)",
        RegexOptions.IgnoreCase | RegexOptions.CultureInvariant | RegexOptions.NonBacktracking);

    private readonly DiagnosticRedactionOptions _options;
    private readonly IReadOnlyList<string> _configuredVariants;

    public DiagnosticTextRedactor(DiagnosticRedactionOptions? options = null)
    {
        _options = options ?? new DiagnosticRedactionOptions();
        _options.Validate();
        _configuredVariants = BuildConfiguredVariants(_options.ConfiguredSecrets);
    }

    public DiagnosticRedactionResult Redact(string value, int? maximumOutputUtf8Bytes = null)
    {
        ArgumentNullException.ThrowIfNull(value);
        var originalBytes = Encoding.UTF8.GetBytes(value);
        if (originalBytes.Length > _options.MaximumInputUtf8Bytes)
        {
            throw new ArgumentOutOfRangeException(
                nameof(value),
                $"Diagnostic input exceeded the {_options.MaximumInputUtf8Bytes}-byte bound.");
        }

        var outputLimit = maximumOutputUtf8Bytes ?? _options.MaximumStringUtf8Bytes;
        if (outputLimit < 128 || outputLimit > _options.MaximumStringUtf8Bytes)
        {
            throw new ArgumentOutOfRangeException(
                nameof(maximumOutputUtf8Bytes),
                "The requested diagnostic output bound is outside the configured range.");
        }

        var normalized = NormalizeControls(value);
        var replacementCount = 0;
        normalized = ReplaceConfiguredValues(normalized, ref replacementCount);
        normalized = ReplaceWithGroups(AssignmentPattern, normalized, ref replacementCount);
        normalized = ReplaceWithGroups(CommandAssignmentPattern, normalized, ref replacementCount);
        normalized = ReplaceWithGroups(JsonKeyPattern, normalized, ref replacementCount);
        normalized = ReplaceWithGroups(HeaderPattern, normalized, ref replacementCount);
        normalized = ReplaceWhole(BearerPattern, normalized, ref replacementCount);
        normalized = ReplaceWithGroups(UriCredentialPattern, normalized, ref replacementCount);
        normalized = ReplaceWithGroups(QueryCredentialPattern, normalized, ref replacementCount);
        normalized = ReplaceWhole(PrivateKeyPattern, normalized, ref replacementCount);
        normalized = ReplaceWhole(KnownTokenPattern, normalized, ref replacementCount);
        normalized = ReplaceWhole(JwtPattern, normalized, ref replacementCount);
        normalized = ReplaceWhole(UserProfileVariablePattern, normalized, ref replacementCount, UserProfileReplacement);
        normalized = ReplaceWhole(UserProfilePathPattern, normalized, ref replacementCount, UserProfileReplacement);
        normalized = ReplaceWhole(SocketPathPattern, normalized, ref replacementCount, SocketReplacement);
        if (string.IsNullOrWhiteSpace(normalized))
        {
            normalized = "[EMPTY]";
        }

        var bounded = BoundUtf8(normalized, outputLimit, out var wasTruncated);
        var redactedBytes = Encoding.UTF8.GetBytes(bounded);
        return new DiagnosticRedactionResult(
            bounded,
            replacementCount,
            wasTruncated,
            originalBytes.Length,
            redactedBytes.Length);
    }

    private static IReadOnlyList<string> BuildConfiguredVariants(IReadOnlyList<string> secrets)
    {
        var variants = new HashSet<string>(StringComparer.Ordinal);
        foreach (var secret in secrets)
        {
            variants.Add(secret);
            var urlEncoded = Uri.EscapeDataString(secret);
            variants.Add(urlEncoded);
            variants.Add(urlEncoded.ToLowerInvariant());

            var base64 = Convert.ToBase64String(Encoding.UTF8.GetBytes(secret));
            variants.Add(base64);
            variants.Add(base64.TrimEnd('='));
            variants.Add(base64.Replace('+', '-').Replace('/', '_').TrimEnd('='));
            variants.Add(WebUtility.UrlEncode(base64));
        }

        return variants
            .Where(value => value.Length > 0)
            .OrderByDescending(value => value.Length)
            .ThenBy(value => value, StringComparer.Ordinal)
            .ToArray();
    }

    private string ReplaceConfiguredValues(string value, ref int count)
    {
        foreach (var secret in _configuredVariants)
        {
            var index = 0;
            while ((index = value.IndexOf(secret, index, StringComparison.Ordinal)) >= 0)
            {
                value = value.Remove(index, secret.Length).Insert(index, Replacement);
                index += Replacement.Length;
                count++;
            }
        }

        return value;
    }

    private static Regex CreateRegex(string pattern, RegexOptions additionalOptions = RegexOptions.None) => new(
        pattern,
        RegexOptions.Compiled |
        RegexOptions.CultureInvariant |
        RegexOptions.IgnoreCase |
        RegexOptions.NonBacktracking |
        additionalOptions,
        RegexTimeout);

    private static Regex CreateBacktrackingRegex(string pattern, RegexOptions additionalOptions = RegexOptions.None) => new(
        pattern,
        RegexOptions.Compiled |
        RegexOptions.CultureInvariant |
        RegexOptions.IgnoreCase |
        additionalOptions,
        RegexTimeout);

    private static string ReplaceWithGroups(
        Regex pattern,
        string value,
        ref int count,
        string replacement = Replacement)
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
            return prefix + replacement + suffix;
        });
        count += localCount;
        return result;
    }

    private static string ReplaceWhole(
        Regex pattern,
        string value,
        ref int count,
        string replacement = Replacement)
    {
        var localCount = 0;
        var result = pattern.Replace(value, _ =>
        {
            localCount++;
            return replacement;
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

    private static string BoundUtf8(string value, int maximumUtf8Bytes, out bool truncated)
    {
        const string marker = "…";
        var markerBytes = Encoding.UTF8.GetByteCount(marker);
        var builder = new StringBuilder(Math.Min(value.Length, maximumUtf8Bytes));
        var utf8Bytes = 0;
        truncated = false;
        foreach (var rune in value.EnumerateRunes())
        {
            if (utf8Bytes + rune.Utf8SequenceLength > maximumUtf8Bytes - markerBytes)
            {
                truncated = true;
                break;
            }

            builder.Append(rune);
            utf8Bytes += rune.Utf8SequenceLength;
        }

        if (truncated)
        {
            builder.Append(marker);
        }

        return builder.ToString();
    }
}
