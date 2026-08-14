using System.Text;
using HerdrOps.Contracts.SelfReport;

namespace HerdrOps.Cli;

public static class HerdrOpsCliCommand
{
    public const int SuccessExitCode = 0;
    public const int UsageFailureExitCode = 64;
    public const int InvalidSchemaExitCode = 65;
    public const int CoreUnavailableExitCode = 69;
    public const int CoreRejectedExitCode = 70;
    public const int MaximumInputBytes = 48 * 1024;

    public static async Task<int> RunAsync(
        string[] args,
        TextReader input,
        TextWriter output,
        TextWriter error,
        CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(args);
        ArgumentNullException.ThrowIfNull(input);
        ArgumentNullException.ThrowIfNull(output);
        ArgumentNullException.ThrowIfNull(error);

        if (args.Length == 1 && string.Equals(args[0], "--help", StringComparison.Ordinal))
        {
            WriteUsage(output);
            return SuccessExitCode;
        }

        if (args.Length == 0 ||
            !HerdrOpsSelfReportProtocol.EventTypes.IsSupported(args[0]))
        {
            WriteClientError(
                error,
                HerdrOpsSelfReportProtocol.ResultCodes.InvalidArguments,
                "The first argument must be a supported self-report command.");
            WriteUsage(error);
            return UsageFailureExitCode;
        }

        string? inputPath = null;
        string? pipeName = null;
        var timeoutMilliseconds = 5000;
        var inputOptionSeen = false;
        var pipeOptionSeen = false;
        var timeoutOptionSeen = false;
        for (var index = 1; index < args.Length; index++)
        {
            switch (args[index])
            {
                case "--input" when index + 1 < args.Length && !inputOptionSeen:
                    inputPath = args[++index];
                    inputOptionSeen = true;
                    break;
                case "--pipe-name" when index + 1 < args.Length && !pipeOptionSeen:
                    pipeName = args[++index];
                    pipeOptionSeen = true;
                    break;
                case "--timeout-ms" when index + 1 < args.Length && !timeoutOptionSeen:
                    if (!int.TryParse(args[++index], out timeoutMilliseconds) ||
                        timeoutMilliseconds is < 100 or > 60_000)
                    {
                        WriteClientError(
                            error,
                            HerdrOpsSelfReportProtocol.ResultCodes.InvalidArguments,
                            "Option --timeout-ms must be an integer from 100 through 60000.");
                        return UsageFailureExitCode;
                    }

                    timeoutOptionSeen = true;
                    break;
                default:
                    WriteClientError(
                        error,
                        HerdrOpsSelfReportProtocol.ResultCodes.InvalidArguments,
                        $"Invalid, duplicate, or incomplete option: {args[index]}");
                    WriteUsage(error);
                    return UsageFailureExitCode;
            }
        }

        if (string.IsNullOrWhiteSpace(inputPath) ||
            (pipeName is not null && string.IsNullOrWhiteSpace(pipeName)))
        {
            WriteClientError(
                error,
                HerdrOpsSelfReportProtocol.ResultCodes.InvalidArguments,
                "Option --input requires a file path or '-' for standard input; explicit values cannot be blank.");
            WriteUsage(error);
            return UsageFailureExitCode;
        }

        byte[] inputBytes;
        try
        {
            inputBytes = await ReadInputAsync(inputPath, input, cancellationToken)
                .ConfigureAwait(false);
        }
        catch (Exception exception) when (
            exception is IOException or UnauthorizedAccessException or ArgumentException)
        {
            WriteClientError(
                error,
                HerdrOpsSelfReportProtocol.ResultCodes.InvalidArguments,
                exception.Message);
            return UsageFailureExitCode;
        }

        HerdrOpsSelfReportSubmission submission;
        try
        {
            var commandInput = HerdrOpsSelfReportJson.DeserializeCommandInput(inputBytes);
            submission = HerdrOpsSelfReportJson.CreateSubmission(args[0], commandInput);
        }
        catch (HerdrOpsSelfReportProtocolException exception)
        {
            WriteClientError(
                error,
                HerdrOpsSelfReportProtocol.ResultCodes.InvalidSchema,
                exception.Message);
            return InvalidSchemaExitCode;
        }

        HerdrOpsSelfReportPipeClientOptions clientOptions;
        try
        {
            clientOptions = pipeName is null
                ? HerdrOpsSelfReportPipeClientOptions.ForCurrentUser(timeoutMilliseconds)
                : new HerdrOpsSelfReportPipeClientOptions(pipeName, timeoutMilliseconds);
            var client = new HerdrOpsSelfReportPipeClient(clientOptions);
            var correlationId = Guid.NewGuid();
            var result = await client.SubmitAsync(submission, correlationId, cancellationToken)
                .ConfigureAwait(false);
            output.WriteLine(HerdrOpsSelfReportJson.Serialize(result));
            return result.Accepted ? SuccessExitCode : CoreRejectedExitCode;
        }
        catch (OperationCanceledException) when (!cancellationToken.IsCancellationRequested)
        {
            WriteClientError(
                error,
                HerdrOpsSelfReportProtocol.ResultCodes.CoreUnavailable,
                $"HerdrOps Core did not respond within {timeoutMilliseconds} milliseconds.");
            return CoreUnavailableExitCode;
        }
        catch (HerdrOpsSelfReportProtocolException exception)
        {
            WriteClientError(
                error,
                HerdrOpsSelfReportProtocol.ResultCodes.InvalidCoreResponse,
                exception.Message);
            return CoreRejectedExitCode;
        }
        catch (ArgumentException exception)
        {
            WriteClientError(
                error,
                HerdrOpsSelfReportProtocol.ResultCodes.InvalidArguments,
                exception.Message);
            return UsageFailureExitCode;
        }
        catch (Exception exception) when (
            exception is IOException or UnauthorizedAccessException or InvalidOperationException)
        {
            WriteClientError(
                error,
                HerdrOpsSelfReportProtocol.ResultCodes.CoreUnavailable,
                $"HerdrOps Core is unavailable: {exception.Message}");
            return CoreUnavailableExitCode;
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
            var textBuilder = new StringBuilder();
            while (true)
            {
                var count = await input
                    .ReadAsync(buffer.AsMemory(), cancellationToken)
                    .ConfigureAwait(false);
                if (count == 0)
                {
                    break;
                }

                if (textBuilder.Length + count > MaximumInputBytes)
                {
                    throw new IOException(
                        $"The self-report input must contain from 1 through {MaximumInputBytes} bytes.");
                }

                textBuilder.Append(buffer, 0, count);
            }

            var text = textBuilder.ToString();
            var bytes = Encoding.UTF8.GetBytes(text);
            EnsureInputSize(bytes.Length);
            return bytes;
        }

        var fullPath = Path.GetFullPath(inputPath);
        var file = new FileInfo(fullPath);
        if (!file.Exists)
        {
            throw new FileNotFoundException("The self-report input file does not exist.", fullPath);
        }

        EnsureInputSize(file.Length);
        var fileBytes = await File.ReadAllBytesAsync(fullPath, cancellationToken).ConfigureAwait(false);
        EnsureInputSize(fileBytes.Length);
        return fileBytes;
    }

    private static void EnsureInputSize(long length)
    {
        if (length is < 1 or > MaximumInputBytes)
        {
            throw new IOException(
                $"The self-report input must contain from 1 through {MaximumInputBytes} bytes.");
        }
    }

    private static void WriteClientError(TextWriter error, string code, string message) =>
        error.WriteLine(HerdrOpsSelfReportJson.Serialize(
            new HerdrOpsSelfReportClientError(code, message)));

    private static void WriteUsage(TextWriter writer) =>
        writer.WriteLine(
            "Usage: HerdrOps.Cli <assignment|acknowledgement|delegation|progress|deviation|evidence|handoff> --input <json-path|-> [--pipe-name <name>] [--timeout-ms <100-60000>]");
}
