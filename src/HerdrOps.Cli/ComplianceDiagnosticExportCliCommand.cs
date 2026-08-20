using System.Text;
using HerdrOps.Contracts.ComplianceDiagnosticExport;

namespace HerdrOps.Cli;

public static class ComplianceDiagnosticExportCliCommand
{
    public const string CommandName = "compliance-diagnostic-export";
    public const int MaximumInputBytes = ComplianceDiagnosticExportProtocol.MaximumInputBytes;

    public static Task<int> RunAsync(
        string[] args,
        TextReader input,
        TextWriter output,
        TextWriter error,
        CancellationToken cancellationToken = default,
        ComplianceDiagnosticExportPipeClient? exportClient = null) =>
        RunAsync(
            args,
            input,
            output,
            error,
            cancellationToken,
            exportClient,
            exportOperation: null);

    internal static async Task<int> RunAsync(
        string[] args,
        TextReader input,
        TextWriter output,
        TextWriter error,
        CancellationToken cancellationToken,
        ComplianceDiagnosticExportPipeClient? exportClient,
        Func<Task<ComplianceDiagnosticExportResponse>>? exportOperation)
    {
        ArgumentNullException.ThrowIfNull(args);
        ArgumentNullException.ThrowIfNull(input);
        ArgumentNullException.ThrowIfNull(output);
        ArgumentNullException.ThrowIfNull(error);
        if (!TryParseArguments(args, error, out var inputPath, out var outputPath, out var pipeName, out var timeoutMilliseconds))
        {
            return HerdrOpsCliCommand.UsageFailureExitCode;
        }

        try
        {
            ComplianceDiagnosticExportResponse response;
            if (exportOperation is not null)
            {
                response = await exportOperation().ConfigureAwait(false);
            }
            else
            {
                var inputBytes = await ReadInputAsync(inputPath!, input, cancellationToken)
                    .ConfigureAwait(false);
                var client = exportClient ?? new ComplianceDiagnosticExportPipeClient(
                    pipeName is null
                        ? ComplianceDiagnosticExportPipeClientOptions.ForCurrentUser(timeoutMilliseconds)
                        : new ComplianceDiagnosticExportPipeClientOptions(pipeName, timeoutMilliseconds));
                response = await client.ExportAsync(
                        inputBytes,
                        outputPath!,
                        Guid.NewGuid(),
                        cancellationToken)
                    .ConfigureAwait(false);
            }

            output.WriteLine(ComplianceDiagnosticExportJson.Serialize(response));
            return response.Accepted
                ? HerdrOpsCliCommand.SuccessExitCode
                : HerdrOpsCliCommand.CoreRejectedExitCode;
        }
        catch (ComplianceDiagnosticExportProtocolException exception)
        {
            WriteError(error, "invalid-compliance-diagnostic", exception.Message);
            return HerdrOpsCliCommand.InvalidSchemaExitCode;
        }
        catch (OperationCanceledException) when (!cancellationToken.IsCancellationRequested)
        {
            WriteError(error, "core-unavailable", $"HerdrOps Core did not respond within {timeoutMilliseconds} milliseconds.");
            return HerdrOpsCliCommand.CoreUnavailableExitCode;
        }
        catch (Exception exception) when (
            exception is IOException or
                UnauthorizedAccessException or
                InvalidOperationException)
        {
            WriteError(error, "core-unavailable", "HerdrOps Core is unavailable for compliance diagnostic export.");
            return HerdrOpsCliCommand.CoreUnavailableExitCode;
        }
        catch (ArgumentException)
        {
            WriteError(error, "invalid-arguments", "The compliance diagnostic export arguments are invalid.");
            return HerdrOpsCliCommand.UsageFailureExitCode;
        }
    }

    private static async Task<byte[]> ReadInputAsync(
        string inputPath,
        TextReader input,
        CancellationToken cancellationToken)
    {
        if (string.Equals(inputPath, "-", StringComparison.Ordinal))
        {
            var buffer = new char[4096];
            var builder = new StringBuilder();
            while (true)
            {
                var count = await input.ReadAsync(buffer.AsMemory(), cancellationToken)
                    .ConfigureAwait(false);
                if (count == 0)
                {
                    break;
                }

                if (builder.Length + count > MaximumInputBytes)
                {
                    throw new IOException(
                        $"The compliance diagnostic input must contain from 1 through {MaximumInputBytes} bytes.");
                }

                builder.Append(buffer, 0, count);
            }

            var bytes = new UTF8Encoding(
                    encoderShouldEmitUTF8Identifier: false,
                    throwOnInvalidBytes: true)
                .GetBytes(builder.ToString());
            EnsureInputSize(bytes.Length);
            return bytes;
        }

        try
        {
            var fullPath = Path.GetFullPath(inputPath);
            var file = new FileInfo(fullPath);
            if (!file.Exists)
            {
                throw new FileNotFoundException("The compliance diagnostic input file does not exist.");
            }

            EnsureInputSize(file.Length);
            var bytes = await File.ReadAllBytesAsync(fullPath, cancellationToken).ConfigureAwait(false);
            EnsureInputSize(bytes.Length);
            return bytes;
        }
        catch (IOException)
        {
            throw;
        }
        catch (Exception exception) when (exception is ArgumentException or UnauthorizedAccessException)
        {
            throw new IOException("The compliance diagnostic input file could not be safely read.", exception);
        }
    }

    private static void EnsureInputSize(long length)
    {
        if (length is < 1 or > MaximumInputBytes)
        {
            throw new IOException(
                $"The compliance diagnostic input must contain from 1 through {MaximumInputBytes} bytes.");
        }
    }

    private static bool TryParseArguments(
        string[] args,
        TextWriter error,
        out string? inputPath,
        out string? outputPath,
        out string? pipeName,
        out int timeoutMilliseconds)
    {
        inputPath = null;
        outputPath = null;
        pipeName = null;
        timeoutMilliseconds = 5000;
        var timeoutOptionSeen = false;
        if (args.Length == 0 || !string.Equals(args[0], CommandName, StringComparison.Ordinal))
        {
            WriteError(error, "invalid-arguments", "The compliance diagnostic export command name is required.");
            WriteUsage(error);
            return false;
        }

        for (var index = 1; index < args.Length; index++)
        {
            switch (args[index])
            {
                case "--input" when index + 1 < args.Length && inputPath is null:
                    inputPath = args[++index];
                    break;
                case "--output" when index + 1 < args.Length && outputPath is null:
                    outputPath = args[++index];
                    break;
                case "--pipe-name" when index + 1 < args.Length && pipeName is null:
                    pipeName = args[++index];
                    break;
                case "--timeout-ms" when index + 1 < args.Length && !timeoutOptionSeen:
                    if (!int.TryParse(args[++index], out timeoutMilliseconds) ||
                        timeoutMilliseconds is < 100 or > 60_000)
                    {
                        WriteError(error, "invalid-arguments", "Option --timeout-ms must be an integer from 100 through 60000.");
                        return false;
                    }

                    timeoutOptionSeen = true;
                    break;
                default:
                    WriteError(error, "invalid-arguments", "Invalid, duplicate, or incomplete compliance diagnostic export option.");
                    WriteUsage(error);
                    return false;
            }
        }

        if (string.IsNullOrWhiteSpace(inputPath) || string.IsNullOrWhiteSpace(outputPath) ||
            (pipeName is not null && string.IsNullOrWhiteSpace(pipeName)))
        {
            WriteError(error, "invalid-arguments", "Both --input and --output are required; explicit values cannot be blank.");
            WriteUsage(error);
            return false;
        }

        return true;
    }

    private static void WriteError(TextWriter error, string code, string message) =>
        error.WriteLine(ComplianceDiagnosticExportJson.Serialize(
            new ComplianceDiagnosticExportCliError(code, message)));

    private static void WriteUsage(TextWriter writer) =>
        writer.WriteLine(
            "Usage: HerdrOps.Cli compliance-diagnostic-export --input <json-path|-> --output <absolute-json-path> [--pipe-name <name>] [--timeout-ms <100-60000>]");
}

public sealed record ComplianceDiagnosticExportCliError(string Code, string Message);
