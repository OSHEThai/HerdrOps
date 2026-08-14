using System.Text.Json;
using System.Text.Json.Serialization;
using HerdrOps.Infrastructure.Herdr;

namespace HerdrOps.Core;

public static class HerdrProtocolInspectionCommand
{
    private const int CompatibilityFailureExitCode = 2;
    private const int UsageFailureExitCode = 64;

    private static readonly JsonSerializerOptions SerializerOptions = new()
    {
        WriteIndented = true,
        Converters = { new JsonStringEnumConverter() },
    };

    public static int Run(string[] args, TextWriter output, TextWriter error)
    {
        ArgumentNullException.ThrowIfNull(args);
        ArgumentNullException.ThrowIfNull(output);
        ArgumentNullException.ThrowIfNull(error);

        if (args.Length == 0)
        {
            output.WriteLine(
                "HerdrOps.Core v0.2 foundation. Use 'inspect-herdr-schema' for the bounded binary contract");
            output.WriteLine(
                "or 'inspect-herdr-bundled-schema' for the exact embedded JSON Schema document.");
            output.WriteLine("Live Herdr connectivity is not started by this command.");
            return 0;
        }

        if (string.Equals(args[0], "inspect-herdr-bundled-schema", StringComparison.Ordinal))
        {
            return HerdrBundledSchemaInspectionCommand.Run(args, output, error);
        }

        if (!string.Equals(args[0], "inspect-herdr-schema", StringComparison.Ordinal))
        {
            error.WriteLine($"Unknown command: {args[0]}");
            WriteUsage(error);
            return UsageFailureExitCode;
        }

        string? executablePath = null;
        string? reportPath = null;
        for (var index = 1; index < args.Length; index++)
        {
            switch (args[index])
            {
                case "--herdr" when index + 1 < args.Length:
                    executablePath = args[++index];
                    if (string.IsNullOrWhiteSpace(executablePath) || executablePath.StartsWith("--", StringComparison.Ordinal))
                    {
                        error.WriteLine("Option --herdr requires a non-empty executable path.");
                        WriteUsage(error);
                        return UsageFailureExitCode;
                    }
                    break;
                case "--report" when index + 1 < args.Length:
                    reportPath = args[++index];
                    if (string.IsNullOrWhiteSpace(reportPath) || reportPath.StartsWith("--", StringComparison.Ordinal))
                    {
                        error.WriteLine("Option --report requires a non-empty JSON path.");
                        WriteUsage(error);
                        return UsageFailureExitCode;
                    }
                    break;
                default:
                    error.WriteLine($"Invalid or incomplete option: {args[index]}");
                    WriteUsage(error);
                    return UsageFailureExitCode;
            }
        }

        executablePath = HerdrInstallationLocator.FindExecutable(executablePath);
        if (string.IsNullOrWhiteSpace(executablePath))
        {
            error.WriteLine(
                "Herdr executable was not discovered. Pass --herdr <path> or install Herdr in the current-user location.");
            return CompatibilityFailureExitCode;
        }

        HerdrProtocolInspection inspection;
        try
        {
            inspection = new HerdrProtocolInspector().Inspect(executablePath);
        }
        catch (Exception exception) when (
            exception is ArgumentException or
                NotSupportedException or
                IOException or
                UnauthorizedAccessException)
        {
            error.WriteLine($"Herdr protocol inspection could not start: {exception.Message}");
            return CompatibilityFailureExitCode;
        }

        var json = JsonSerializer.Serialize(inspection, SerializerOptions);
        output.WriteLine(json);

        if (!string.IsNullOrWhiteSpace(reportPath))
        {
            try
            {
                var fullReportPath = Path.GetFullPath(reportPath);
                var reportDirectory = Path.GetDirectoryName(fullReportPath);
                if (!string.IsNullOrWhiteSpace(reportDirectory))
                {
                    Directory.CreateDirectory(reportDirectory);
                }

                File.WriteAllText(fullReportPath, json + Environment.NewLine);
            }
            catch (Exception exception) when (
                exception is ArgumentException or
                    NotSupportedException or
                    IOException or
                    UnauthorizedAccessException)
            {
                error.WriteLine($"Protocol inspection report could not be written: {exception.Message}");
                return CompatibilityFailureExitCode;
            }
        }

        if (!inspection.IsCompatible)
        {
            error.WriteLine(inspection.Message);
            return CompatibilityFailureExitCode;
        }

        return 0;
    }

    private static void WriteUsage(TextWriter writer) =>
        writer.WriteLine(
            "Usage: HerdrOps.Core inspect-herdr-schema [--herdr <path>] [--report <json-path>]");
}
