using System.Text.Json;
using System.Text.Json.Serialization;
using HerdrOps.Infrastructure.Herdr;

namespace HerdrOps.Core;

public static class HerdrBundledSchemaInspectionCommand
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

        if (args.Length == 0 ||
            !string.Equals(args[0], "inspect-herdr-bundled-schema", StringComparison.Ordinal))
        {
            error.WriteLine("The bundled-schema command name is required.");
            WriteUsage(error);
            return UsageFailureExitCode;
        }

        string? executablePath = null;
        string? reportPath = null;
        string? schemaOutputPath = null;
        for (var index = 1; index < args.Length; index++)
        {
            switch (args[index])
            {
                case "--herdr" when index + 1 < args.Length:
                    executablePath = args[++index];
                    if (IsInvalidValue(executablePath))
                    {
                        error.WriteLine("Option --herdr requires a non-empty executable path.");
                        WriteUsage(error);
                        return UsageFailureExitCode;
                    }
                    break;
                case "--report" when index + 1 < args.Length:
                    reportPath = args[++index];
                    if (IsInvalidValue(reportPath))
                    {
                        error.WriteLine("Option --report requires a non-empty JSON path.");
                        WriteUsage(error);
                        return UsageFailureExitCode;
                    }
                    break;
                case "--schema-output" when index + 1 < args.Length:
                    schemaOutputPath = args[++index];
                    if (IsInvalidValue(schemaOutputPath))
                    {
                        error.WriteLine("Option --schema-output requires a non-empty JSON Schema path.");
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

        if (PathsAreEqual(reportPath, schemaOutputPath))
        {
            error.WriteLine("Options --report and --schema-output must target different files.");
            WriteUsage(error);
            return UsageFailureExitCode;
        }

        executablePath = HerdrInstallationLocator.FindExecutable(executablePath);
        if (string.IsNullOrWhiteSpace(executablePath))
        {
            error.WriteLine(
                "Herdr executable was not discovered. Pass --herdr <path> or install Herdr in the current-user location.");
            return CompatibilityFailureExitCode;
        }

        HerdrBundledSchemaExtraction extraction;
        try
        {
            extraction = new HerdrBundledSchemaExtractor().Extract(executablePath);
        }
        catch (Exception exception) when (
            exception is ArgumentException or
                NotSupportedException or
                IOException or
                UnauthorizedAccessException)
        {
            error.WriteLine($"Herdr bundled-schema inspection could not start: {exception.Message}");
            return CompatibilityFailureExitCode;
        }

        var json = JsonSerializer.Serialize(extraction.Inspection, SerializerOptions);
        output.WriteLine(json);

        if (!string.IsNullOrWhiteSpace(reportPath) &&
            !TryWriteText(reportPath, json + Environment.NewLine, error))
        {
            return CompatibilityFailureExitCode;
        }

        if (!extraction.IsCompatible || extraction.SchemaDocumentBytes is null)
        {
            error.WriteLine(extraction.Inspection.Message);
            return CompatibilityFailureExitCode;
        }

        if (!string.IsNullOrWhiteSpace(schemaOutputPath) &&
            !TryWriteBytes(schemaOutputPath, extraction.SchemaDocumentBytes, error))
        {
            return CompatibilityFailureExitCode;
        }

        return 0;
    }

    private static bool IsInvalidValue(string value) =>
        string.IsNullOrWhiteSpace(value) || value.StartsWith("--", StringComparison.Ordinal);

    private static bool PathsAreEqual(string? first, string? second)
    {
        if (string.IsNullOrWhiteSpace(first) || string.IsNullOrWhiteSpace(second))
        {
            return false;
        }

        try
        {
            return string.Equals(
                Path.GetFullPath(first),
                Path.GetFullPath(second),
                StringComparison.OrdinalIgnoreCase);
        }
        catch (Exception exception) when (exception is ArgumentException or NotSupportedException)
        {
            return false;
        }
    }

    private static bool TryWriteText(string path, string contents, TextWriter error)
    {
        try
        {
            var fullPath = PrepareOutputPath(path);
            File.WriteAllText(fullPath, contents);
            return true;
        }
        catch (Exception exception) when (
            exception is ArgumentException or
                NotSupportedException or
                IOException or
                UnauthorizedAccessException)
        {
            error.WriteLine($"Bundled-schema inspection report could not be written: {exception.Message}");
            return false;
        }
    }

    private static bool TryWriteBytes(string path, byte[] contents, TextWriter error)
    {
        try
        {
            var fullPath = PrepareOutputPath(path);
            File.WriteAllBytes(fullPath, contents);
            return true;
        }
        catch (Exception exception) when (
            exception is ArgumentException or
                NotSupportedException or
                IOException or
                UnauthorizedAccessException)
        {
            error.WriteLine($"Bundled JSON Schema could not be written: {exception.Message}");
            return false;
        }
    }

    private static string PrepareOutputPath(string path)
    {
        var fullPath = Path.GetFullPath(path);
        var directory = Path.GetDirectoryName(fullPath);
        if (!string.IsNullOrWhiteSpace(directory))
        {
            Directory.CreateDirectory(directory);
        }

        return fullPath;
    }

    private static void WriteUsage(TextWriter writer) =>
        writer.WriteLine(
            "Usage: HerdrOps.Core inspect-herdr-bundled-schema [--herdr <path>] [--schema-output <json-schema-path>] [--report <json-path>]");
}
