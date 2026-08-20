using System.Security;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using HerdrOps.Contracts.ComplianceDiagnosticExport;
using HerdrOps.Domain.Compliance;
using HerdrOps.Infrastructure.ComplianceDiagnosticExport;

namespace HerdrOps.Core;

public static class ComplianceDiagnosticExportCommand
{
    public const string CommandName = "compliance-diagnostic-export";
    public const string ServiceCommandName = "serve-compliance-diagnostic-export";
    public const int SuccessExitCode = 0;
    public const int ExportFailureExitCode = 2;
    public const int UsageFailureExitCode = 64;

    public static int Run(string[] args, TextWriter output, TextWriter error)
    {
        ArgumentNullException.ThrowIfNull(args);
        ArgumentNullException.ThrowIfNull(output);
        ArgumentNullException.ThrowIfNull(error);
        if (!TryParseDirectArguments(args, error, out var inputPath, out var outputPath))
        {
            return UsageFailureExitCode;
        }

        try
        {
            var fullInputPath = Path.GetFullPath(inputPath!);
            var fullOutputPath = ValidateOutputPath(outputPath!);
            if (string.Equals(fullInputPath, fullOutputPath, StringComparison.OrdinalIgnoreCase))
            {
                throw new ComplianceDiagnosticExportException(
                    "The compliance diagnostic input and output must be different files.");
            }

            var inputBytes = ReadBoundedInput(fullInputPath);
            var artifact = ExportToPath(fullOutputPath, inputBytes);
            var result = new ComplianceDiagnosticExportCommandResult(
                ComplianceDiagnosticExportSchema.ExportSchemaVersion,
                artifact.RecordCount,
                artifact.ByteCount,
                artifact.Sha256);
            var resultJson = ComplianceDiagnosticExportJson.Serialize(result);
            output.WriteLine(resultJson);
            return SuccessExitCode;
        }
        catch (ComplianceDiagnosticExportException exception)
        {
            error.WriteLine($"Compliance diagnostic export failed: {exception.Message}");
            return ExportFailureExitCode;
        }
        catch (Exception exception) when (
            exception is ArgumentException or
                IOException or
                NotSupportedException or
                SecurityException or
                UnauthorizedAccessException or
                JsonException)
        {
            error.WriteLine("Compliance diagnostic export failed: the input or output could not be safely processed.");
            return ExportFailureExitCode;
        }
    }

    public static ComplianceDiagnosticExportArtifact ExportToPath(
        string outputPath,
        ReadOnlySpan<byte> inputBytes)
    {
        var fullOutputPath = ValidateOutputPath(outputPath);
        var artifact = ComplianceDiagnosticExportBuilder.Build(inputBytes);
        PublishNoOverwrite(fullOutputPath, artifact.Content);
        return artifact;
    }

    public static Task<int> RunServiceAsync(
        string[] args,
        TextWriter output,
        TextWriter error,
        CancellationToken cancellationToken = default) =>
        RunServiceAsync(args, output, error, cancellationToken, serverOperation: null);

    internal static async Task<int> RunServiceAsync(
        string[] args,
        TextWriter output,
        TextWriter error,
        CancellationToken cancellationToken,
        Func<Task<int>>? serverOperation)
    {
        ArgumentNullException.ThrowIfNull(args);
        ArgumentNullException.ThrowIfNull(output);
        ArgumentNullException.ThrowIfNull(error);
        if (!TryParseServiceArguments(args, error, out var pipeName, out var seconds))
        {
            return UsageFailureExitCode;
        }

        try
        {
            if (serverOperation is not null)
            {
                return await serverOperation().ConfigureAwait(false);
            }

            var options = pipeName is null
                ? ComplianceDiagnosticExportPipeServerOptions.ForCurrentUser()
                : new ComplianceDiagnosticExportPipeServerOptions(pipeName);
            var server = new ComplianceDiagnosticExportPipeServer(
                options,
                HandleRequest);
            using var duration = seconds is null
                ? null
                : CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
            if (seconds is not null)
            {
                duration!.CancelAfter(TimeSpan.FromSeconds(seconds.Value));
            }
            var effectiveToken = duration?.Token ?? cancellationToken;
            var serverTask = server.RunAsync(effectiveToken);
            await server.Ready.WaitAsync(effectiveToken).ConfigureAwait(false);
            output.WriteLine(
                $"HerdrOps Core compliance diagnostic export service ready: protocol={ComplianceDiagnosticExportProtocol.Version}, pipe={options.PipeName}.");
            output.Flush();
            await serverTask.ConfigureAwait(false);
            output.WriteLine("HerdrOps Core compliance diagnostic export service stopped.");
            return SuccessExitCode;
        }
        catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested)
        {
            output.WriteLine("HerdrOps Core compliance diagnostic export service stopped.");
            return SuccessExitCode;
        }
        catch (Exception exception) when (
            exception is ArgumentException or
                IOException or
                InvalidOperationException or
                UnauthorizedAccessException)
        {
            error.WriteLine("Core compliance diagnostic export service failed: the service could not be started.");
            return ExportFailureExitCode;
        }
    }

    private static ValueTask<ComplianceDiagnosticExportResponse> HandleRequest(
        ComplianceDiagnosticExportRequest request,
        CancellationToken cancellationToken)
    {
        cancellationToken.ThrowIfCancellationRequested();
        try
        {
            var inputBytes = ComplianceDiagnosticExportJson.GetInputBytes(request);
            var artifact = ExportToPath(request.OutputPath, inputBytes);
            return ValueTask.FromResult(new ComplianceDiagnosticExportResponse(
                ComplianceDiagnosticExportProtocol.Version,
                ComplianceDiagnosticExportProtocol.MessageTypes.Accepted,
                DateTimeOffset.UtcNow,
                ComplianceDiagnosticExportProtocol.CoreSource,
                request.CorrelationId,
                Accepted: true,
                ComplianceDiagnosticExportProtocol.ResultCodes.Accepted,
                ComplianceDiagnosticExportProtocol.Messages.Accepted,
                artifact.RecordCount,
                artifact.ByteCount,
                artifact.Sha256));
        }
        catch (ComplianceDiagnosticExportException)
        {
            return ValueTask.FromResult(Rejected(
                request.CorrelationId,
                ComplianceDiagnosticExportProtocol.Messages.RejectedInput));
        }
        catch (Exception exception) when (
            exception is ArgumentException or
                IOException or
                NotSupportedException or
                SecurityException or
                UnauthorizedAccessException)
        {
            return ValueTask.FromResult(Rejected(
                request.CorrelationId,
                ComplianceDiagnosticExportProtocol.Messages.RejectedPublication));
        }
    }

    private static ComplianceDiagnosticExportResponse Rejected(
        Guid correlationId,
        string message) =>
        new(
            ComplianceDiagnosticExportProtocol.Version,
            ComplianceDiagnosticExportProtocol.MessageTypes.Rejected,
            DateTimeOffset.UtcNow,
            ComplianceDiagnosticExportProtocol.CoreSource,
            correlationId,
            Accepted: false,
            ComplianceDiagnosticExportProtocol.ResultCodes.ExportFailed,
            message,
            RecordCount: null,
            ByteCount: null,
            OutputSha256: null);

    private static byte[] ReadBoundedInput(string path)
    {
        try
        {
            using var stream = new FileStream(
                path,
                FileMode.Open,
                FileAccess.Read,
                FileShare.Read,
                bufferSize: 81920,
                FileOptions.SequentialScan);
            if (stream.Length is < 1 or > ComplianceDiagnosticExportSchema.MaximumInputBytes)
            {
                throw new ComplianceDiagnosticExportException(
                    $"The compliance diagnostic input must contain from 1 through {ComplianceDiagnosticExportSchema.MaximumInputBytes} bytes.");
            }

            var bytes = new byte[stream.Length];
            stream.ReadExactly(bytes);
            return bytes;
        }
        catch (ComplianceDiagnosticExportException)
        {
            throw;
        }
        catch (Exception exception) when (
            exception is IOException or
                UnauthorizedAccessException or
                ArgumentException or
                NotSupportedException)
        {
            throw new ComplianceDiagnosticExportException(
                "The compliance diagnostic input file could not be safely read.",
                exception);
        }
    }

    private static string ValidateOutputPath(string path)
    {
        if (string.IsNullOrWhiteSpace(path) ||
            !Path.IsPathFullyQualified(path) ||
            path.Length > ComplianceDiagnosticExportProtocol.MaximumOutputPathLength ||
            HasDotSegment(path) ||
            !string.Equals(Path.GetExtension(path), ".json", StringComparison.OrdinalIgnoreCase))
        {
            throw new ComplianceDiagnosticExportException(
                "The compliance diagnostic output must be an absolute .json path without traversal.");
        }

        string fullPath;
        try
        {
            fullPath = Path.GetFullPath(path);
        }
        catch (Exception exception) when (exception is ArgumentException or NotSupportedException)
        {
            throw new ComplianceDiagnosticExportException(
                "The compliance diagnostic output path is invalid.",
                exception);
        }

        if (File.Exists(fullPath) || Directory.Exists(fullPath))
        {
            throw new ComplianceDiagnosticExportException(
                "The compliance diagnostic output already exists and cannot be overwritten.");
        }

        var parentPath = Path.GetDirectoryName(fullPath);
        if (string.IsNullOrWhiteSpace(parentPath))
        {
            throw new ComplianceDiagnosticExportException(
                "The compliance diagnostic output must have an existing parent directory.");
        }

        ValidateDirectoryChain(parentPath);
        return fullPath;
    }

    private static void ValidateDirectoryChain(string parentPath)
    {
        var current = new DirectoryInfo(parentPath);
        while (current is not null)
        {
            try
            {
                if (!current.Exists ||
                    (current.Attributes & FileAttributes.ReparsePoint) != 0)
                {
                    throw new ComplianceDiagnosticExportException(
                        "The compliance diagnostic output parent must be an existing non-reparse directory.");
                }
            }
            catch (ComplianceDiagnosticExportException)
            {
                throw;
            }
            catch (Exception exception) when (
                exception is IOException or
                    UnauthorizedAccessException or
                    SecurityException)
            {
                throw new ComplianceDiagnosticExportException(
                    "The compliance diagnostic output parent could not be safely inspected.",
                    exception);
            }

            current = current.Parent;
        }
    }

    private static void PublishNoOverwrite(string fullPath, byte[] content)
    {
        var parent = Path.GetDirectoryName(fullPath)!;
        var temporaryPath = Path.Combine(
            parent,
            $".{Path.GetFileName(fullPath)}.{Guid.NewGuid():N}.tmp");
        try
        {
            using (var stream = new FileStream(
                       temporaryPath,
                       FileMode.CreateNew,
                       FileAccess.Write,
                       FileShare.None,
                       bufferSize: 81920,
                       FileOptions.WriteThrough))
            {
                stream.Write(content);
                stream.Flush(flushToDisk: true);
            }

            File.Move(temporaryPath, fullPath, overwrite: false);
            temporaryPath = null!;
        }
        catch (Exception exception) when (
            exception is IOException or
                UnauthorizedAccessException or
                ArgumentException or
                NotSupportedException or
                SecurityException)
        {
            throw new ComplianceDiagnosticExportException(
                "The compliance diagnostic output could not be atomically published without overwrite.",
                exception);
        }
        finally
        {
            if (!string.IsNullOrWhiteSpace(temporaryPath))
            {
                try
                {
                    File.Delete(temporaryPath);
                }
                catch (Exception exception) when (
                    exception is IOException or
                        UnauthorizedAccessException or
                        ArgumentException or
                        SecurityException)
                {
                    // A failed cleanup cannot turn an uncommitted temporary file into accepted output.
                }
            }
        }
    }

    private static bool HasDotSegment(string path) =>
        path.Split(['\\', '/'], StringSplitOptions.RemoveEmptyEntries)
            .Any(segment => segment is "." or "..");

    private static bool TryParseDirectArguments(
        string[] args,
        TextWriter error,
        out string? inputPath,
        out string? outputPath)
    {
        inputPath = null;
        outputPath = null;
        if (args.Length == 0 || !string.Equals(args[0], CommandName, StringComparison.Ordinal))
        {
            error.WriteLine("The compliance diagnostic export command name is required.");
            WriteDirectUsage(error);
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
                default:
                    error.WriteLine("Invalid, duplicate, or incomplete compliance diagnostic export option.");
                    WriteDirectUsage(error);
                    return false;
            }
        }

        if (string.IsNullOrWhiteSpace(inputPath) || string.IsNullOrWhiteSpace(outputPath))
        {
            error.WriteLine("Both --input and --output are required.");
            WriteDirectUsage(error);
            return false;
        }

        return true;
    }

    private static bool TryParseServiceArguments(
        string[] args,
        TextWriter error,
        out string? pipeName,
        out int? seconds)
    {
        pipeName = null;
        seconds = null;
        if (args.Length == 0 || !string.Equals(args[0], ServiceCommandName, StringComparison.Ordinal))
        {
            error.WriteLine("The compliance diagnostic export service command name is required.");
            WriteServiceUsage(error);
            return false;
        }

        for (var index = 1; index < args.Length; index++)
        {
            switch (args[index])
            {
                case "--pipe-name" when index + 1 < args.Length && pipeName is null:
                    pipeName = args[++index];
                    break;
                case "--seconds" when index + 1 < args.Length && seconds is null:
                    if (!int.TryParse(args[++index], out var parsedSeconds) || parsedSeconds is < 1 or > 3600)
                    {
                        error.WriteLine("Option --seconds must be an integer from 1 through 3600.");
                        WriteServiceUsage(error);
                        return false;
                    }

                    seconds = parsedSeconds;
                    break;
                default:
                    error.WriteLine("Invalid, duplicate, or incomplete compliance diagnostic export service option.");
                    WriteServiceUsage(error);
                    return false;
            }
        }

        if (pipeName is not null && string.IsNullOrWhiteSpace(pipeName))
        {
            error.WriteLine("Option --pipe-name cannot be blank.");
            WriteServiceUsage(error);
            return false;
        }

        return true;
    }

    private static void WriteDirectUsage(TextWriter writer) =>
        writer.WriteLine(
            "Usage: HerdrOps.Core compliance-diagnostic-export --input <json-path> --output <absolute-json-path>");

    private static void WriteServiceUsage(TextWriter writer) =>
        writer.WriteLine(
            "Usage: HerdrOps.Core serve-compliance-diagnostic-export [--pipe-name <name>] [--seconds <1-3600>]");
}

public sealed record ComplianceDiagnosticExportCommandResult(
    string SchemaVersion,
    int RecordCount,
    int ByteCount,
    string OutputSha256);
