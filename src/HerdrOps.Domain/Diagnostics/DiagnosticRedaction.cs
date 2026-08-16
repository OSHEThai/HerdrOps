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
    public const string PathReplacement = "[PATH]";

    private static readonly TimeSpan RegexTimeout = TimeSpan.FromSeconds(1);
    private static readonly Regex ProseAssignmentPattern = CreateRegex(
        "(?<prefix>\\b(?:api[ \\t_-]*key|password|passwd|token|secret|private[ \\t_-]*key|client[ \\t_-]*secret|access[ \\t_-]*key|authorization|credential|connection[ \\t_-]*string)\\b[ \\t]*(?:(?:is|equals?)[ \\t]+|[:=][ \\t]*|[ \\t]+))(?:\"[^\"\\r\\n]*\"|'[^'\\r\\n]*'|[^\\s,;&\\r\\n]+)");
    private static readonly Regex AssignmentPattern = CreateRegex(
        "(?<prefix>\\b[A-Z0-9][A-Z0-9_.-]*(?:TOKEN|SECRET|PASSWORD|PASSWD|API[_-]?KEY|PRIVATE[_-]?KEY|CLIENT[_-]?SECRET|ACCESS[_-]?KEY|AUTH(?:ORIZATION)?|CREDENTIAL|CONNECTION(?:[_-]?STRING)?|SOCKET(?:[_-]?PATH)?|COOKIE)[A-Z0-9_.-]*\\s*[:=]\\s*)(?:\"[^\"\\r\\n]*\"|'[^'\\r\\n]*'|[^\\s,;&\\r\\n]+)");
    private static readonly Regex CommandAssignmentPattern = CreateRegex(
        "(?<prefix>--?(?:token|secret|password|passwd|api[_-]?key|private[_-]?key|client[_-]?secret|access[_-]?key|authorization|credential|connection(?:[_-]?string)?|socket(?:[_-]?path)?|cookie)(?:\\s+|=))(?:\"[^\"\\r\\n]*\"|'[^'\\r\\n]*'|[^\\s,;&\\r\\n]+)");
    private static readonly Regex JsonKeyPattern = CreateRegex(
        "(?<prefix>\"?(?:token|secret|password|passwd|api[_-]?key|private[_-]?key|client[_-]?secret|access[_-]?key|authorization|credential|connection(?:[_-]?string)?|socket(?:[_-]?path)?|cookie)\"?\\s*:\\s*)(?:\"[^\"\\r\\n]*\"|'[^'\\r\\n]*'|[^\\s,}\\r\\n]+)");
    private static readonly Regex HeaderPattern = CreateRegex(
        "(?<prefix>\\b(?:authorization|proxy-authorization|cookie|set-cookie|x-api-key|x-auth-token|api-key)\\s*:\\s*)(?:(?:bearer|basic)\\s+[^\\s,;\\r\\n]+|\"[^\"\\r\\n]*\"|'[^'\\r\\n]*'|[^\\s,;\\r\\n]+)");
    private static readonly Regex BearerPattern = CreateRegex(
        "(?<prefix>\\b(?:bearer|basic)\\s+)[^\\s\\r\\n,;]+",
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
    private static readonly Regex UserProfileVariablePattern = CreateRegex(
        "(?:\"(?:%USERPROFILE%|\\$env:USERPROFILE|\\$USERPROFILE)[\\\\/][^\\r\\n\"'<>|:*?;,]+(?::\\d+(?::\\d+)?)?\"(?::\\d+(?::\\d+)?)?|(?:%USERPROFILE%|\\$env:USERPROFILE|\\$USERPROFILE)[\\\\/][^\\r\\n\"'<>|:*?;,]+(?::\\d+(?::\\d+)?)?)");
    private static readonly Regex UnixUserProfilePathPattern = CreateRegex(
        "(?:\"/(?:users|home)/[^\\r\\n\"]+\"(?::\\d+(?::\\d+)?)?|/(?:users|home)/[^\\r\\n\"]+(?::\\d+(?::\\d+)?)?)");
    private static readonly Regex UnixSocketPathPattern = CreateRegex(
        "/[^\\r\\n\"]*\\bherdr\\.sock\\b");

    private readonly DiagnosticRedactionOptions _options;
    private readonly Regex? _configuredPattern;

    public DiagnosticTextRedactor(DiagnosticRedactionOptions? options = null)
    {
        _options = options ?? new DiagnosticRedactionOptions();
        _options.Validate();
        _configuredPattern = BuildConfiguredPattern(_options.ConfiguredSecrets);
    }

    public DiagnosticRedactionResult Redact(string value, int? maximumOutputUtf8Bytes = null)
    {
        ArgumentNullException.ThrowIfNull(value);
        var originalUtf8Bytes = Encoding.UTF8.GetByteCount(value);
        if (originalUtf8Bytes > _options.MaximumInputUtf8Bytes)
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
        normalized = ReplaceWhole(PrivateKeyPattern, normalized, ref replacementCount);
        normalized = ReplaceWithGroups(HeaderPattern, normalized, ref replacementCount);
        normalized = ReplaceWithGroups(ProseAssignmentPattern, normalized, ref replacementCount);
        normalized = ReplaceWithGroups(AssignmentPattern, normalized, ref replacementCount);
        normalized = ReplaceWithGroups(CommandAssignmentPattern, normalized, ref replacementCount);
        normalized = ReplaceWithGroups(JsonKeyPattern, normalized, ref replacementCount);
        normalized = ReplaceWhole(BearerPattern, normalized, ref replacementCount);
        normalized = ReplaceWithGroups(UriCredentialPattern, normalized, ref replacementCount);
        normalized = ReplaceWithGroups(QueryCredentialPattern, normalized, ref replacementCount);
        normalized = ReplaceWhole(KnownTokenPattern, normalized, ref replacementCount);
        normalized = ReplaceWhole(JwtPattern, normalized, ref replacementCount);
        normalized = ReplaceWhole(UserProfileVariablePattern, normalized, ref replacementCount, UserProfileReplacement);
        normalized = ReplaceWhole(UnixUserProfilePathPattern, normalized, ref replacementCount, UserProfileReplacement);
        normalized = ReplaceWhole(UnixSocketPathPattern, normalized, ref replacementCount, SocketReplacement);
        normalized = ReplaceWindowsPaths(normalized, ref replacementCount);
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
            originalUtf8Bytes,
            redactedBytes.Length);
    }

    private static Regex? BuildConfiguredPattern(IReadOnlyList<string> secrets)
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

        var orderedVariants = variants
            .Where(value => value.Length > 0)
            .OrderByDescending(value => value.Length)
            .ThenBy(value => value, StringComparer.Ordinal)
            .ToArray();
        if (orderedVariants.Length == 0)
        {
            return null;
        }

        const int maximumPatternCharacters = 512 * 1024;
        var patternCharacters = orderedVariants.Sum(value => value.Length + 1);
        if (patternCharacters > maximumPatternCharacters)
        {
            throw new ArgumentOutOfRangeException(
                nameof(secrets),
                $"Configured diagnostic redaction patterns exceed the {maximumPatternCharacters}-character work bound.");
        }

        var pattern = "(?:" + string.Join('|', orderedVariants.Select(Regex.Escape)) + ")";
        return CreateRegex(pattern);
    }

    private string ReplaceConfiguredValues(string value, ref int count)
    {
        if (_configuredPattern is null)
        {
            return value;
        }

        var localCount = 0;
        var result = _configuredPattern.Replace(value, _ =>
        {
            localCount++;
            return Replacement;
        });
        count += localCount;
        return result;
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

    private static string ReplaceWindowsPaths(string value, ref int count)
    {
        StringBuilder? builder = null;
        var copyStart = 0;
        var index = 0;
        while (index < value.Length)
        {
            if (!TryFindWindowsPath(value, index, out var end, out var replacement))
            {
                index++;
                continue;
            }

            builder ??= new StringBuilder(value.Length);
            builder.Append(value, copyStart, index - copyStart);
            builder.Append(replacement);
            copyStart = end;
            index = end;
            count++;
        }

        if (builder is null)
        {
            return value;
        }

        builder.Append(value, copyStart, value.Length - copyStart);
        return builder.ToString();
    }

    private static bool TryFindWindowsPath(
        string value,
        int start,
        out int end,
        out string replacement)
    {
        end = start;
        replacement = string.Empty;
        var pathStart = start;
        var quoted = false;
        var quote = '\0';
        if (value[start] is '"' or '\'' &&
            TryGetWindowsPathKind(value, start + 1, out _))
        {
            quoted = true;
            quote = value[start];
            pathStart++;
        }

        if (!TryGetWindowsPathKind(value, pathStart, out var kind) ||
            !HasPathBoundaryBefore(value, start, quoted))
        {
            return false;
        }

        var bodyStart = GetWindowsPathBodyStart(pathStart, kind);
        var cursor = bodyStart;
        var pathEnd = cursor;
        var hasClosingQuote = false;
        if (quoted)
        {
            pathEnd = FindQuotedWindowsPathEnd(value, bodyStart, quote, kind, out hasClosingQuote);
            if (!HasValidWindowsPathBody(value, bodyStart, pathEnd, kind))
            {
                return false;
            }

            end = hasClosingQuote
                ? ConsumeLineColumnSuffix(value, pathEnd + 1)
                : pathEnd;
        }
        else
        {
            while (cursor < value.Length)
            {
                var character = value[cursor];
                if (character is '\r' or '\n' or '\t' || char.IsControl(character))
                {
                    break;
                }

                if (character == '"' ||
                    (character is ',' or ';' && IsFieldDelimiter(value, cursor)))
                {
                    break;
                }

                cursor++;
            }

            pathEnd = cursor;
            if (pathEnd <= bodyStart || !HasValidWindowsPathBody(value, bodyStart, pathEnd, kind))
            {
                return false;
            }

            end = ConsumeLineColumnSuffix(value, pathEnd);
        }

        var candidate = value.Substring(pathStart, pathEnd - pathStart);
        replacement = ClassifyWindowsPath(candidate);
        return true;
    }

    private static int FindQuotedWindowsPathEnd(
        string value,
        int bodyStart,
        char quote,
        WindowsPathKind kind,
        out bool hasClosingQuote)
    {
        var cursor = bodyStart;
        while (cursor < value.Length)
        {
            if (value[cursor] is '\r' or '\n' || char.IsControl(value[cursor]))
            {
                break;
            }

            if (value[cursor] == quote &&
                HasValidWindowsPathBody(value, bodyStart, cursor, kind) &&
                IsSafeQuotedWindowsPathClose(value, cursor))
            {
                hasClosingQuote = true;
                return cursor;
            }

            cursor++;
        }

        hasClosingQuote = false;
        return cursor;
    }

    private static bool IsSafeQuotedWindowsPathClose(string value, int quoteIndex)
    {
        var suffixEnd = ConsumeLineColumnSuffix(value, quoteIndex + 1);
        return IsSafeQuotedWindowsPathBoundary(value, suffixEnd);
    }

    private static bool IsSafeQuotedWindowsPathBoundary(string value, int start)
    {
        if (start >= value.Length || value[start] is '\r' or '\n')
        {
            return true;
        }

        var character = value[start];
        if (character is ' ' or '\t')
        {
            var cursor = start;
            while (cursor < value.Length && value[cursor] is ' ' or '\t')
            {
                cursor++;
            }

            if (cursor >= value.Length || value[cursor] is '\r' or '\n')
            {
                return true;
            }

            if (value[cursor] is ')' or ']' or '}' or '>' or '&' or '|' or '"' or '\'' ||
                StartsWithAssignment(value, cursor))
            {
                return true;
            }

            return !LooksLikeWindowsPathContinuation(value, cursor);
        }

        if (character is ',' or ';')
        {
            return IsFieldDelimiter(value, start) ||
                !LooksLikeWindowsPathContinuation(value, start + 1);
        }

        return character is ')' or ']' or '}' or '>' or '&' or '|' or '"' or '\'';
    }

    private static bool StartsWithAssignment(string value, int start)
    {
        var cursor = start;
        while (cursor < value.Length &&
               (char.IsLetterOrDigit(value[cursor]) || value[cursor] is '_' or '-' or '.'))
        {
            cursor++;
        }

        return cursor > start && cursor < value.Length && value[cursor] == '=';
    }

    private static bool LooksLikeWindowsPathContinuation(string value, int start)
    {
        for (var cursor = start; cursor < value.Length; cursor++)
        {
            var character = value[cursor];
            if (character is '\r' or '\n' || char.IsControl(character) || character is '"' or '\'' || character == '=')
            {
                return false;
            }

            if (IsWindowsSeparator(character))
            {
                return true;
            }
        }

        return false;
    }

    private static bool TryGetWindowsPathKind(
        string value,
        int start,
        out WindowsPathKind kind)
    {
        kind = default;
        if (start < 0 || start >= value.Length)
        {
            return false;
        }

        if (start + 2 < value.Length &&
            IsAsciiLetter(value[start]) &&
            value[start + 1] == ':' &&
            IsWindowsSeparator(value[start + 2]))
        {
            kind = WindowsPathKind.Drive;
            return true;
        }

        if (start + 3 < value.Length &&
            value[start] == '\\' &&
            value[start + 1] == '\\' &&
            value[start + 2] == '?' &&
            IsWindowsSeparator(value[start + 3]))
        {
            if (StartsWith(value, start + 4, "UNC") &&
                start + 7 < value.Length &&
                IsWindowsSeparator(value[start + 7]))
            {
                kind = WindowsPathKind.ExtendedUnc;
            }
            else if (start + 6 < value.Length &&
                     IsAsciiLetter(value[start + 4]) &&
                     value[start + 5] == ':' &&
                     IsWindowsSeparator(value[start + 6]))
            {
                kind = WindowsPathKind.ExtendedDrive;
            }
            else
            {
                kind = WindowsPathKind.Extended;
            }

            return true;
        }

        if (start + 1 < value.Length &&
            (value[start] == '\\' || value[start] == '/') &&
            value[start + 1] == value[start])
        {
            kind = WindowsPathKind.Unc;
            return true;
        }

        return false;
    }

    private static int GetWindowsPathBodyStart(
        int pathStart,
        WindowsPathKind kind) =>
        kind switch
        {
            WindowsPathKind.Drive => pathStart + 3,
            WindowsPathKind.ExtendedDrive => pathStart + 7,
            WindowsPathKind.ExtendedUnc => pathStart + 8,
            WindowsPathKind.Extended => pathStart + 4,
            _ => pathStart + 2,
        };

    private static bool HasValidWindowsPathBody(
        string value,
        int bodyStart,
        int end,
        WindowsPathKind kind)
    {
        if (end < bodyStart)
        {
            return false;
        }

        if (kind is WindowsPathKind.Unc or WindowsPathKind.ExtendedUnc)
        {
            var separatorCount = 0;
            var componentLength = 0;
            for (var index = bodyStart; index < end; index++)
            {
                if (IsWindowsSeparator(value[index]))
                {
                    if (componentLength == 0)
                    {
                        return false;
                    }

                    separatorCount++;
                    componentLength = 0;
                }
                else
                {
                    componentLength++;
                }
            }

            return separatorCount >= 1 && componentLength > 0;
        }

        return kind is WindowsPathKind.Extended || end > bodyStart || end == bodyStart;
    }

    private static bool HasPathBoundaryBefore(string value, int start, bool quoted) =>
        quoted ||
        start == 0 ||
        !(char.IsLetterOrDigit(value[start - 1]) || value[start - 1] is '_' or '$');

    private static bool IsFieldDelimiter(string value, int index)
    {
        var cursor = index + 1;
        if (cursor < value.Length &&
            value[cursor] is not ' ' and not '\t' and not '"' and not '\'')
        {
            return false;
        }

        while (cursor < value.Length && (value[cursor] == ' ' || value[cursor] == '\t'))
        {
            cursor++;
        }

        if (cursor >= value.Length || value[cursor] is '\r' or '\n')
        {
            return true;
        }

        if (value[cursor] == '"')
        {
            return true;
        }

        var identifierStart = cursor;
        while (cursor < value.Length &&
               (char.IsLetterOrDigit(value[cursor]) || value[cursor] is '_' or '-' or '.'))
        {
            cursor++;
        }

        if (cursor <= identifierStart || cursor >= value.Length || value[cursor] != '=')
        {
            return false;
        }

        cursor++;
        while (cursor < value.Length && (value[cursor] == ' ' || value[cursor] == '\t'))
        {
            cursor++;
        }

        return cursor >= value.Length || value[cursor] is '"' or '\'';
    }

    private static int ConsumeLineColumnSuffix(string value, int start)
    {
        var cursor = start;
        if (cursor >= value.Length || value[cursor] != ':')
        {
            return start;
        }

        cursor++;
        var firstDigits = cursor;
        while (cursor < value.Length && char.IsAsciiDigit(value[cursor]))
        {
            cursor++;
        }

        if (cursor == firstDigits)
        {
            return start;
        }

        if (cursor < value.Length && value[cursor] == ':')
        {
            var secondDigits = ++cursor;
            while (cursor < value.Length && char.IsAsciiDigit(value[cursor]))
            {
                cursor++;
            }

            if (cursor == secondDigits)
            {
                return start;
            }
        }

        return cursor;
    }

    private static string ClassifyWindowsPath(string candidate)
    {
        if (candidate.Contains("herdr.sock", StringComparison.OrdinalIgnoreCase) ||
            candidate.Contains("\\pipe\\", StringComparison.OrdinalIgnoreCase) ||
            candidate.Contains("/pipe/", StringComparison.OrdinalIgnoreCase) ||
            candidate.Contains("\\socket\\", StringComparison.OrdinalIgnoreCase) ||
            candidate.Contains("/socket/", StringComparison.OrdinalIgnoreCase))
        {
            return SocketReplacement;
        }

        var path = candidate.Trim('"', '\'');
        if (ContainsProfileComponent(path))
        {
            return UserProfileReplacement;
        }

        return PathReplacement;
    }

    private static bool ContainsProfileComponent(string path)
    {
        var normalized = path.Replace('/', '\\');
        if (normalized.StartsWith("\\\\?\\", StringComparison.Ordinal))
        {
            normalized = normalized[4..];
            if (normalized.StartsWith("UNC\\", StringComparison.OrdinalIgnoreCase))
            {
                normalized = normalized[4..];
            }
        }

        return normalized.Contains("\\Users\\", StringComparison.OrdinalIgnoreCase) ||
            normalized.Contains("\\Home\\", StringComparison.OrdinalIgnoreCase) ||
            normalized.StartsWith("Users\\", StringComparison.OrdinalIgnoreCase) ||
            normalized.StartsWith("Home\\", StringComparison.OrdinalIgnoreCase);
    }

    private static bool StartsWith(string value, int start, string expected) =>
        start >= 0 &&
        start + expected.Length <= value.Length &&
        value.AsSpan(start, expected.Length).Equals(expected, StringComparison.OrdinalIgnoreCase);

    private static bool IsWindowsSeparator(char value) => value is '\\' or '/';

    private static bool IsAsciiLetter(char value) =>
        value is >= 'A' and <= 'Z' or >= 'a' and <= 'z';

    private enum WindowsPathKind
    {
        Drive,
        Unc,
        ExtendedDrive,
        ExtendedUnc,
        Extended,
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
