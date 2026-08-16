using System.Text;
using HerdrOps.Contracts.ReviewIpc;

namespace HerdrOps.Cli;

public sealed record ComplianceReviewCliError(string Code, string Message);

public static class ComplianceReviewCliCommand
{
    public const string CommandName = "review";
    public const int MaximumInputBytes = 48 * 1024;

    public static async Task<int> RunAsync(
        string[] args,
        TextReader input,
        TextWriter output,
        TextWriter error,
        CancellationToken cancellationToken = default,
        Func<string, string?>? environmentVariableReader = null,
        HerdrOpsReviewCommandPipeClient? reviewClient = null)
    {
        ArgumentNullException.ThrowIfNull(args);
        ArgumentNullException.ThrowIfNull(input);
        ArgumentNullException.ThrowIfNull(output);
        ArgumentNullException.ThrowIfNull(error);
        if (args.Length == 2 &&
            string.Equals(args[0], CommandName, StringComparison.Ordinal) &&
            string.Equals(args[1], "--help", StringComparison.Ordinal))
        {
            WriteUsage(output);
            return HerdrOpsCliCommand.SuccessExitCode;
        }

        if (args.Length == 0 || !string.Equals(args[0], CommandName, StringComparison.Ordinal))
        {
            WriteError(error, "invalid-arguments", "The review command name is required.");
            WriteUsage(error);
            return HerdrOpsCliCommand.UsageFailureExitCode;
        }

        string? inputPath = null;
        var timeoutMilliseconds = 5000;
        for (var index = 1; index < args.Length; index++)
        {
            switch (args[index])
            {
                case "--input" when index + 1 < args.Length && inputPath is null:
                    inputPath = args[++index];
                    break;
                case "--timeout-ms" when index + 1 < args.Length:
                    if (!int.TryParse(args[++index], out timeoutMilliseconds) ||
                        timeoutMilliseconds is < 100 or > 60_000)
                    {
                        WriteError(error, "invalid-arguments", "Option --timeout-ms must be an integer from 100 through 60000.");
                        return HerdrOpsCliCommand.UsageFailureExitCode;
                    }

                    break;
                default:
                    WriteError(error, "invalid-arguments", $"Invalid, duplicate, or incomplete option: {args[index]}");
                    WriteUsage(error);
                    return HerdrOpsCliCommand.UsageFailureExitCode;
            }
        }

        if (string.IsNullOrWhiteSpace(inputPath))
        {
            WriteError(error, "invalid-arguments", "Option --input requires a file path or '-' for standard input; explicit values cannot be blank.");
            WriteUsage(error);
            return HerdrOpsCliCommand.UsageFailureExitCode;
        }

        var readEnvironmentVariable = environmentVariableReader ?? Environment.GetEnvironmentVariable;
        var reviewerActorId = readEnvironmentVariable("HERDR_PANE_ID");
        if (!string.Equals(readEnvironmentVariable("HERDR_ENV"), "1", StringComparison.Ordinal) ||
            string.IsNullOrWhiteSpace(reviewerActorId))
        {
            WriteError(
                error,
                "herdr-identity-unavailable",
                "Review commands require HERDR_ENV=1 and HERDR_PANE_ID from an authorized Herdr pane.");
            return HerdrOpsCliCommand.UsageFailureExitCode;
        }

        try
        {
            var bytes = await ReadInputAsync(inputPath, input, cancellationToken)
                .ConfigureAwait(false);
            var commandInput = HerdrOpsReviewCommandJson.DeserializeCliCommandInput(bytes);
            var request = new HerdrOpsReviewCommandRequest(
                commandInput.ContractVersion,
                commandInput.CommandId,
                commandInput.IncidentId,
                commandInput.ExpectedState,
                commandInput.ExpectedSequence,
                reviewerActorId,
                commandInput.DecisionKind,
                commandInput.Reason,
                commandInput.EvidenceIdentitySha256s);
            var client = reviewClient ?? new HerdrOpsReviewCommandPipeClient(
                HerdrOpsReviewCommandCliPipeOptions.ForCurrentUser(
                    TimeSpan.FromMilliseconds(timeoutMilliseconds)));
            var result = await client.ExecuteAsync(request, cancellationToken)
                .ConfigureAwait(false);
            output.WriteLine(HerdrOpsReviewCommandJson.Serialize(result));
            return result.IsAccepted
                ? HerdrOpsCliCommand.SuccessExitCode
                : HerdrOpsCliCommand.CoreRejectedExitCode;
        }
        catch (HerdrOpsReviewCommandProtocolException exception)
        {
            WriteError(error, "invalid-review-command", exception.Message);
            return HerdrOpsCliCommand.InvalidSchemaExitCode;
        }
        catch (OperationCanceledException) when (!cancellationToken.IsCancellationRequested)
        {
            WriteError(error, "core-unavailable", $"HerdrOps Core did not respond within {timeoutMilliseconds} milliseconds.");
            return HerdrOpsCliCommand.CoreUnavailableExitCode;
        }
        catch (TimeoutException exception)
        {
            WriteError(error, "core-unavailable", exception.Message);
            return HerdrOpsCliCommand.CoreUnavailableExitCode;
        }
        catch (Exception exception) when (
            exception is IOException or UnauthorizedAccessException or InvalidOperationException)
        {
            WriteError(error, "core-unavailable", $"HerdrOps Core is unavailable: {exception.Message}");
            return HerdrOpsCliCommand.CoreUnavailableExitCode;
        }
        catch (ArgumentException exception)
        {
            WriteError(error, "invalid-arguments", exception.Message);
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
                        $"The review-command input must contain from 1 through {MaximumInputBytes} bytes.");
                }

                builder.Append(buffer, 0, count);
            }

            var bytes = Encoding.UTF8.GetBytes(builder.ToString());
            EnsureInputSize(bytes.Length);
            return bytes;
        }

        var fullPath = Path.GetFullPath(inputPath);
        var file = new FileInfo(fullPath);
        if (!file.Exists)
        {
            throw new FileNotFoundException("The review-command input file does not exist.", fullPath);
        }

        EnsureInputSize(file.Length);
        var fileBytes = await File.ReadAllBytesAsync(fullPath, cancellationToken)
            .ConfigureAwait(false);
        EnsureInputSize(fileBytes.Length);
        return fileBytes;
    }

    private static void EnsureInputSize(long length)
    {
        if (length is < 1 or > MaximumInputBytes)
        {
            throw new IOException(
                $"The review-command input must contain from 1 through {MaximumInputBytes} bytes.");
        }
    }

    private static void WriteError(TextWriter error, string code, string message) =>
        error.WriteLine(HerdrOpsReviewCommandJson.Serialize(
            new ComplianceReviewCliError(code, message)));

    private static void WriteUsage(TextWriter writer) =>
        writer.WriteLine(
            "Usage: HerdrOps.Cli review --input <json-path|-> [--timeout-ms <100-60000>]");
}
