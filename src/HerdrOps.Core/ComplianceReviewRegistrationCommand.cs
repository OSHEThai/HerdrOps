using System.Text;
using System.Text.Json;
using System.Text.Json.Serialization;
using HerdrOps.Contracts.ReviewIpc;
using HerdrOps.Domain.Compliance;
using HerdrOps.Infrastructure.Storage;
using Microsoft.Data.Sqlite;

namespace HerdrOps.Core;

/// <summary>
/// Production incident registration path for durable SQLite compliance-review state.
/// The command reads strict, bounded registration JSON and calls the store's immutable
/// registration so the role-distinct review workflow has a reachable origin. It is a
/// Contract/local-SQLite/BuiltProcess operation; it is never Actual-Herdr Runtime evidence.
/// </summary>
public static class ComplianceReviewRegistrationCommand
{
    public const string CommandName = "compliance-register-incident";
    public const int SuccessExitCode = 0;
    public const int RuntimeFailureExitCode = 2;
    public const int UsageFailureExitCode = 64;
    public const int MaximumInputBytes = 48 * 1024;

    private static readonly JsonSerializerOptions SerializerOptions = new(JsonSerializerDefaults.Web)
    {
        AllowTrailingCommas = false,
        MaxDepth = 64,
        PropertyNameCaseInsensitive = false,
        ReadCommentHandling = JsonCommentHandling.Disallow,
        WriteIndented = true,
    };

    public static int Run(
        string[] args,
        TextReader input,
        TextWriter output,
        TextWriter error)
    {
        ArgumentNullException.ThrowIfNull(args);
        ArgumentNullException.ThrowIfNull(input);
        ArgumentNullException.ThrowIfNull(output);
        ArgumentNullException.ThrowIfNull(error);

        if (args.Length == 0 ||
            !string.Equals(args[0], CommandName, StringComparison.Ordinal))
        {
            error.WriteLine("The compliance-register-incident command name is required.");
            WriteUsage(error);
            return UsageFailureExitCode;
        }

        if (args.Length == 2 && string.Equals(args[1], "--help", StringComparison.Ordinal))
        {
            WriteUsage(output);
            return SuccessExitCode;
        }

        string? databasePath = null;
        string? inputPath = null;
        var seenOptions = new HashSet<string>(StringComparer.Ordinal);
        for (var index = 1; index < args.Length; index++)
        {
            var option = args[index];
            switch (option)
            {
                case "--database" when index + 1 < args.Length && seenOptions.Add(option):
                    databasePath = args[++index];
                    break;
                case "--input" when index + 1 < args.Length && seenOptions.Add(option):
                    inputPath = args[++index];
                    break;
                default:
                    error.WriteLine($"Invalid, duplicate, or incomplete option: {option}");
                    WriteUsage(error);
                    return UsageFailureExitCode;
            }
        }

        if (string.IsNullOrWhiteSpace(databasePath) || string.IsNullOrWhiteSpace(inputPath))
        {
            error.WriteLine("Both --database and --input are required.");
            WriteUsage(error);
            return UsageFailureExitCode;
        }

        try
        {
            databasePath = Path.GetFullPath(databasePath);
            var registrationBytes = ReadBounded(inputPath, input);
            var inputRegistration =
                HerdrOpsReviewCommandJson.DeserializeRegistrationInput(registrationBytes);
            var registration = new ComplianceReviewIncidentRegistration(
                inputRegistration.ContractVersion,
                inputRegistration.IncidentId,
                inputRegistration.TaskId,
                inputRegistration.SubjectActorId,
                inputRegistration.RegisteredUtc,
                inputRegistration.EvidenceIdentitySha256s);

            var storeOptions = new HerdrStateStoreOptions(databasePath);
            using var store = new SqliteHerdrStateStore(storeOptions);
            var result = store.RegisterComplianceReviewIncident(registration);

            var response = new HerdrOpsComplianceIncidentRegistrationResult(
                Registered: !result.WasAlreadyPresent,
                WasAlreadyPresent: result.WasAlreadyPresent,
                IncidentId: result.Incident.IncidentId,
                RegistrationSha256: result.Incident.RegistrationSha256,
                State: (int)result.Incident.State,
                Sequence: result.Incident.Sequence);

            var json = JsonSerializer.Serialize(response, SerializerOptions) + Environment.NewLine;
            output.Write(json);
            return SuccessExitCode;
        }
        catch (Exception exception) when (
            exception is SqliteException or
                HerdrStateStoreException or
                ComplianceReviewContractException or
                HerdrOpsReviewCommandProtocolException or
                IOException or
                ArgumentException or
                InvalidOperationException or
                UnauthorizedAccessException)
        {
            error.WriteLine($"Compliance review registration failed: {exception.Message}");
            return RuntimeFailureExitCode;
        }
    }

    private static byte[] ReadBounded(string inputPath, TextReader input)
    {
        if (string.Equals(inputPath, "-", StringComparison.Ordinal))
        {
            var buffer = new char[4096];
            var builder = new StringBuilder();
            while (true)
            {
                var count = input.Read(buffer, 0, buffer.Length);
                if (count == 0)
                {
                    break;
                }

                if (builder.Length + count > MaximumInputBytes)
                {
                    throw new IOException(
                        $"The compliance incident registration input must contain from 1 through {MaximumInputBytes} bytes.");
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
            throw new FileNotFoundException(
                "The compliance incident registration input file does not exist.",
                fullPath);
        }

        if (file.Attributes.HasFlag(FileAttributes.ReparsePoint) || file.LinkTarget is not null)
        {
            throw new IOException(
                "Reparse point or symbolic link rejected for the compliance incident registration input.");
        }

        EnsureInputSize(file.Length);
        var fileBytes = File.ReadAllBytes(fullPath);
        EnsureInputSize(fileBytes.Length);
        return fileBytes;
    }

    private static void EnsureInputSize(long length)
    {
        if (length is < 1 or > MaximumInputBytes)
        {
            throw new IOException(
                $"The compliance incident registration input must contain from 1 through {MaximumInputBytes} bytes.");
        }
    }

    private static void WriteUsage(TextWriter writer) =>
        writer.WriteLine(
            "Usage: HerdrOps.Core compliance-register-incident --database <sqlite-db-path> --input <json-path|->");
}