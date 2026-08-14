using System.IO;
using HerdrOps.App.Localization;

namespace HerdrOps.App.RuntimeEvidence;

public sealed record RuntimeEvidenceOptions(
    string ReportPath,
    string CaptureDirectory,
    string ProgressPath,
    int CoreProcessId,
    int TimeoutSeconds,
    int IdleSeconds,
    UiLanguage Language)
{
    public const int MinimumTimeoutSeconds = 30;
    public const int MaximumTimeoutSeconds = 900;
    public const int MinimumIdleSeconds = 5;
    public const int MaximumIdleSeconds = 120;

    public static bool IsRequested(IReadOnlyList<string> args) =>
        args.Any(argument => string.Equals(
            argument,
            "--runtime-evidence-report",
            StringComparison.Ordinal));

    public static bool TryParse(
        IReadOnlyList<string> args,
        out RuntimeEvidenceOptions? options,
        out string? error)
    {
        ArgumentNullException.ThrowIfNull(args);
        options = null;
        error = null;
        string? reportPath = null;
        string? captureDirectory = null;
        string? progressPath = null;
        var coreProcessId = 0;
        var timeoutSeconds = 180;
        var idleSeconds = 20;
        var language = UiLanguage.Thai;

        for (var index = 0; index < args.Count; index++)
        {
            var argument = args[index];
            if (index + 1 >= args.Count)
            {
                error = $"Runtime evidence option '{argument}' is missing its value.";
                return false;
            }

            var value = args[++index];
            switch (argument)
            {
                case "--runtime-evidence-report":
                    reportPath = value;
                    break;
                case "--capture-directory":
                    captureDirectory = value;
                    break;
                case "--progress-report":
                    progressPath = value;
                    break;
                case "--core-pid":
                    if (!int.TryParse(value, out coreProcessId) || coreProcessId <= 0)
                    {
                        error = "Option --core-pid requires a positive process identifier.";
                        return false;
                    }

                    break;
                case "--timeout-seconds":
                    if (!int.TryParse(value, out timeoutSeconds) ||
                        timeoutSeconds is < MinimumTimeoutSeconds or > MaximumTimeoutSeconds)
                    {
                        error = $"Option --timeout-seconds must be from {MinimumTimeoutSeconds} through {MaximumTimeoutSeconds}.";
                        return false;
                    }

                    break;
                case "--idle-seconds":
                    if (!int.TryParse(value, out idleSeconds) ||
                        idleSeconds is < MinimumIdleSeconds or > MaximumIdleSeconds)
                    {
                        error = $"Option --idle-seconds must be from {MinimumIdleSeconds} through {MaximumIdleSeconds}.";
                        return false;
                    }

                    break;
                case "--language":
                    if (string.Equals(value, "thai", StringComparison.OrdinalIgnoreCase) ||
                        string.Equals(value, "th", StringComparison.OrdinalIgnoreCase))
                    {
                        language = UiLanguage.Thai;
                    }
                    else if (string.Equals(value, "english", StringComparison.OrdinalIgnoreCase) ||
                             string.Equals(value, "en", StringComparison.OrdinalIgnoreCase))
                    {
                        language = UiLanguage.English;
                    }
                    else
                    {
                        error = "Option --language must be Thai/th or English/en.";
                        return false;
                    }

                    break;
                default:
                    error = $"Unknown runtime evidence option '{argument}'.";
                    return false;
            }
        }

        if (string.IsNullOrWhiteSpace(reportPath) ||
            string.IsNullOrWhiteSpace(captureDirectory) ||
            coreProcessId <= 0)
        {
            error = "Runtime evidence mode requires --runtime-evidence-report, --capture-directory, and --core-pid.";
            return false;
        }

        try
        {
            reportPath = Path.GetFullPath(reportPath);
            captureDirectory = Path.GetFullPath(captureDirectory);
            progressPath = string.IsNullOrWhiteSpace(progressPath)
                ? Path.Combine(Path.GetDirectoryName(reportPath)!, "app-progress.json")
                : Path.GetFullPath(progressPath);
        }
        catch (Exception exception) when (
            exception is ArgumentException or NotSupportedException or PathTooLongException)
        {
            error = $"Runtime evidence paths are invalid: {exception.Message}";
            return false;
        }

        options = new RuntimeEvidenceOptions(
            reportPath,
            captureDirectory,
            progressPath,
            coreProcessId,
            timeoutSeconds,
            idleSeconds,
            language);
        return true;
    }
}
