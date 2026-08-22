using System.IO;
using System.Text.RegularExpressions;
using HerdrOps.App.Localization;

namespace HerdrOps.App.RuntimeEvidence;

public sealed record RuntimeEvidenceOptions(
    string ReportPath,
    string CaptureDirectory,
    string ProgressPath,
    int CoreProcessId,
    int TimeoutSeconds,
    int IdleSeconds,
    UiLanguage Language,
    string ProfileId,
    string ProfileSha256)
{
    public const string ApprovedProfileId = "herdrops-v0.2-submark-nb-software-only-20260822";
    public const string ApprovedProfileSha256 = "96D01ED15A536F2DF50B59B43CFDEB3683DCE8667AE2E7BF6A96124182FE13A3";
    public const int ApprovedIdleSeconds = 20;
    public const int MinimumTimeoutSeconds = 30;
    public const int MaximumTimeoutSeconds = 900;
    private static readonly Regex ProfileIdPattern = new(
        "^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$",
        RegexOptions.CultureInvariant);
    private static readonly Regex UpperSha256Pattern = new(
        "^[0-9A-F]{64}$",
        RegexOptions.CultureInvariant);

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
        var idleSeconds = ApprovedIdleSeconds;
        var language = UiLanguage.Thai;
        string? profileId = null;
        string? profileSha256 = null;

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
                        idleSeconds != ApprovedIdleSeconds)
                    {
                        error = $"Option --idle-seconds must be exactly the approved {ApprovedIdleSeconds}-second reference-host duration.";
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
                case "--reference-host-profile-id":
                    profileId = value;
                    break;
                case "--reference-host-profile-sha256":
                    profileSha256 = value;
                    break;
                default:
                    error = $"Unknown runtime evidence option '{argument}'.";
                    return false;
            }
        }

        if (string.IsNullOrWhiteSpace(reportPath) ||
            string.IsNullOrWhiteSpace(captureDirectory) ||
            coreProcessId <= 0 ||
            string.IsNullOrWhiteSpace(profileId) ||
            string.IsNullOrWhiteSpace(profileSha256))
        {
            error = "Runtime evidence mode requires --runtime-evidence-report, --capture-directory, --core-pid, --reference-host-profile-id, and --reference-host-profile-sha256.";
            return false;
        }

        if (!ProfileIdPattern.IsMatch(profileId))
        {
            error = "Option --reference-host-profile-id must be a stable 1-128 character identifier using letters, digits, '.', '_', ':', or '-'.";
            return false;
        }

        if (!UpperSha256Pattern.IsMatch(profileSha256))
        {
            error = "Option --reference-host-profile-sha256 must be exactly 64 uppercase hexadecimal characters.";
            return false;
        }

        if (!string.Equals(profileId, ApprovedProfileId, StringComparison.Ordinal))
        {
            error = $"Option --reference-host-profile-id must equal the approved profile ID '{ApprovedProfileId}'.";
            return false;
        }

        if (!string.Equals(profileSha256, ApprovedProfileSha256, StringComparison.Ordinal))
        {
            error = "Option --reference-host-profile-sha256 does not equal the approved canonical profile SHA-256.";
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
            language,
            profileId,
            profileSha256);
        return true;
    }
}
