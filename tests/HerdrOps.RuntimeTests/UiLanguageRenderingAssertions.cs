using HerdrOps.App.Localization;

namespace HerdrOps.RuntimeTests;

internal static class UiLanguageRenderingAssertions
{
    private static readonly IReadOnlySet<string> AllowedLiteralValues = new HashSet<string>(StringComparer.Ordinal)
    {
        "HerdrOps",
        "HerdrOps Core",
        "Herdr",
        "Core",
        "Codex",
        "Claude",
        "Project Manager",
        "PM Secretary",
        "Backend Leader",
        "Frontend Leader",
        "Test Leader",
        "DevOps Leader",
        "Backend Worker 01",
        "Frontend Worker 01",
        "Test Worker",
        "DevOps Worker",
        "Reviewer",
        "Reviewer 01",
        "MyAwesomeProject",
        "Project Management",
        "Started Auth Service work",
        "Login review found a missing test",
        "Unit test report submitted",
        "Review API latency",
        "API latency review requested",
        "Review",
        "Task",
        "Evidence",
        "Failed",
        "TaskStarted",
        "ReviewRequested",
        "EvidenceSubmitted",
    };

    public static void AssertOppositeUiTranslationsAbsent(
        IEnumerable<string> visibleText,
        UiLanguage selectedLanguage,
        string context)
    {
        var visible = visibleText
            .Where(value => !string.IsNullOrWhiteSpace(value))
            .Select(value => value.Trim())
            .ToArray();
        var oppositeLanguage = selectedLanguage == UiLanguage.Thai
            ? UiLanguage.English
            : UiLanguage.Thai;
        var oppositeValues = UiLanguageService.Shared
            .Keys(oppositeLanguage)
            .Select(key =>
            {
                var oppositeValue = UiLanguageService.Shared.Text(oppositeLanguage, key).Trim();
                var selectedValue = UiLanguageService.Shared.Text(selectedLanguage, key).Trim();
                return (oppositeValue, selectedValue);
            })
            .Where(values => !string.Equals(values.oppositeValue, values.selectedValue, StringComparison.Ordinal))
            .Select(values => values.oppositeValue)
            .Where(value => value.Length >= 2)
            .Where(value => !value.Contains('{', StringComparison.Ordinal))
            .Distinct(StringComparer.Ordinal)
            .ToArray();
        var leakedValues = visible
            .Where(value => !IsAllowedLiteral(value))
            .SelectMany(value => oppositeValues
                .Where(opposite => ContainsUiValue(value, opposite))
                .Select(opposite => $"{opposite} in '{value}'"))
            .Distinct(StringComparer.Ordinal)
            .ToArray();

        Assert.IsEmpty(
            leakedValues,
            $"{selectedLanguage} mode contains opposite-language UI copy at {context}: {string.Join(" | ", leakedValues)}");
    }

    private static bool ContainsUiValue(string visible, string candidate) =>
        string.Equals(visible, candidate, StringComparison.Ordinal);

    private static bool IsAllowedLiteral(string value)
    {
        if (AllowedLiteralValues.Contains(value))
        {
            return true;
        }

        if (value.Any(character => character is >= '\u0E00' and <= '\u0E7F') &&
            AllowedLiteralValues.Any(literal => value.Contains(literal, StringComparison.Ordinal)))
        {
            return true;
        }

        if (value.Contains(" Worker", StringComparison.Ordinal) ||
            value.Contains(" Leader", StringComparison.Ordinal) ||
            value.StartsWith("Worker ", StringComparison.Ordinal))
        {
            return true;
        }

        if (value.EndsWith('%') && value[..^1].All(char.IsDigit))
        {
            return true;
        }

        if (value.Contains(';') || (value.Contains('(') && value.Contains(')')))
        {
            return true;
        }

        return value.Contains('\\') ||
               value.Contains("://", StringComparison.Ordinal) ||
               value.Contains("synthetic-", StringComparison.OrdinalIgnoreCase) ||
               value.StartsWith("TASK-", StringComparison.Ordinal) ||
               value.StartsWith("EVT-", StringComparison.Ordinal) ||
               value.StartsWith("FILE-", StringComparison.Ordinal) ||
               value.StartsWith("AUD-", StringComparison.Ordinal) ||
               value.StartsWith("ACK-", StringComparison.Ordinal) ||
               value.StartsWith("RULE-", StringComparison.Ordinal);
    }
}
