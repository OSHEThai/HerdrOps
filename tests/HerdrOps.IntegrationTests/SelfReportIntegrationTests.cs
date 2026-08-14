using System.IO.Pipes;
using System.Text;
using System.Text.Json;
using HerdrOps.Cli;
using HerdrOps.Contracts.SelfReport;
using HerdrOps.Core;
using HerdrOps.Infrastructure.StateIpc;

namespace HerdrOps.IntegrationTests;

[TestClass]
public sealed class SelfReportIntegrationTests
{
    [TestMethod]
    public async Task CliSubmissionReceivesCoreSourceSequenceCorrelationAndUtc()
    {
        var pipeName = $"herdrops-self-report-test-{Guid.NewGuid():N}";
        var acceptance = new HerdrOpsSelfReportAcceptanceService(
            new InMemoryHerdrOpsTaskRegistry(["TASK-115"]));
        var server = CreateServer(pipeName, acceptance);
        using var serverCancellation = new CancellationTokenSource();
        var serverTask = server.RunAsync(serverCancellation.Token);
        await server.Ready.WaitAsync(TimeSpan.FromSeconds(5));
        var commandInput = ValidAssignmentInput();
        using var output = new StringWriter();
        using var error = new StringWriter();

        var exitCode = await HerdrOpsCliCommand.RunAsync(
            [
                HerdrOpsSelfReportProtocol.EventTypes.Assignment,
                "--input",
                "-",
                "--pipe-name",
                pipeName,
            ],
            new StringReader(HerdrOpsSelfReportJson.Serialize(commandInput)),
            output,
            error);

        serverCancellation.Cancel();
        await serverTask.WaitAsync(TimeSpan.FromSeconds(5));
        Assert.AreEqual(HerdrOpsCliCommand.SuccessExitCode, exitCode, error.ToString());
        Assert.AreEqual(string.Empty, error.ToString());
        Assert.HasCount(1, acceptance.AcceptedEvents);
        var accepted = acceptance.AcceptedEvents[0];
        Assert.AreEqual(1L, accepted.Sequence);
        Assert.AreEqual(HerdrOpsSelfReportProtocol.CoreSource, accepted.Source);
        Assert.AreNotEqual(Guid.Empty, accepted.CorrelationId);
        Assert.AreEqual(TimeSpan.Zero, accepted.AcceptedUtc.Offset);

        using var resultJson = JsonDocument.Parse(output.ToString());
        Assert.IsTrue(resultJson.RootElement.GetProperty("accepted").GetBoolean());
        Assert.AreEqual(1L, resultJson.RootElement.GetProperty("sequence").GetInt64());
        Assert.AreEqual(
            HerdrOpsSelfReportProtocol.CoreSource,
            resultJson.RootElement.GetProperty("acceptedSource").GetString());
        Assert.AreEqual(
            accepted.CorrelationId,
            resultJson.RootElement.GetProperty("correlationId").GetGuid());
    }

    [TestMethod]
    public async Task UnknownTaskReturnsStructuredNonZeroCoreRejection()
    {
        var pipeName = $"herdrops-self-report-unknown-{Guid.NewGuid():N}";
        var acceptance = new HerdrOpsSelfReportAcceptanceService(
            new InMemoryHerdrOpsTaskRegistry(["TASK-115"]));
        var server = CreateServer(pipeName, acceptance);
        using var serverCancellation = new CancellationTokenSource();
        var serverTask = server.RunAsync(serverCancellation.Token);
        await server.Ready.WaitAsync(TimeSpan.FromSeconds(5));
        var commandInput = ValidAssignmentInput() with { TaskId = "TASK-999" };
        using var output = new StringWriter();
        using var error = new StringWriter();

        var exitCode = await HerdrOpsCliCommand.RunAsync(
            [
                HerdrOpsSelfReportProtocol.EventTypes.Assignment,
                "--input",
                "-",
                "--pipe-name",
                pipeName,
            ],
            new StringReader(HerdrOpsSelfReportJson.Serialize(commandInput)),
            output,
            error);

        serverCancellation.Cancel();
        await serverTask.WaitAsync(TimeSpan.FromSeconds(5));
        Assert.AreEqual(HerdrOpsCliCommand.CoreRejectedExitCode, exitCode);
        Assert.AreEqual(string.Empty, error.ToString());
        Assert.IsEmpty(acceptance.AcceptedEvents);
        using var resultJson = JsonDocument.Parse(output.ToString());
        Assert.IsFalse(resultJson.RootElement.GetProperty("accepted").GetBoolean());
        Assert.AreEqual(
            HerdrOpsSelfReportProtocol.ResultCodes.UnknownTask,
            resultJson.RootElement.GetProperty("code").GetString());
    }

    [TestMethod]
    public async Task InvalidSchemaFailsNonZeroBeforeAnyCoreConnection()
    {
        var invalidJson = "{\"contractVersion\":1,\"unexpected\":true}";
        using var output = new StringWriter();
        using var error = new StringWriter();

        var exitCode = await HerdrOpsCliCommand.RunAsync(
            [
                HerdrOpsSelfReportProtocol.EventTypes.Assignment,
                "--input",
                "-",
                "--pipe-name",
                $"unused-{Guid.NewGuid():N}",
                "--timeout-ms",
                "100",
            ],
            new StringReader(invalidJson),
            output,
            error);

        Assert.AreEqual(HerdrOpsCliCommand.InvalidSchemaExitCode, exitCode);
        Assert.AreEqual(string.Empty, output.ToString());
        using var errorJson = JsonDocument.Parse(error.ToString());
        Assert.AreEqual(
            HerdrOpsSelfReportProtocol.ResultCodes.InvalidSchema,
            errorJson.RootElement.GetProperty("code").GetString());
    }

    [TestMethod]
    public async Task CoreResponseTimeoutReturnsStructuredUnavailableError()
    {
        var pipeName = $"herdrops-self-report-timeout-{Guid.NewGuid():N}";
        using var holdCancellation = new CancellationTokenSource();
        await using var unresponsiveServer = new NamedPipeServerStream(
            pipeName,
            PipeDirection.InOut,
            1,
            PipeTransmissionMode.Byte,
            PipeOptions.Asynchronous | PipeOptions.CurrentUserOnly);
        var holdTask = HoldConnectedClientAsync(unresponsiveServer, holdCancellation.Token);
        using var output = new StringWriter();
        using var error = new StringWriter();

        var exitCode = await HerdrOpsCliCommand.RunAsync(
            [
                HerdrOpsSelfReportProtocol.EventTypes.Assignment,
                "--input",
                "-",
                "--pipe-name",
                pipeName,
                "--timeout-ms",
                "100",
            ],
            new StringReader(HerdrOpsSelfReportJson.Serialize(ValidAssignmentInput())),
            output,
            error);

        holdCancellation.Cancel();
        await holdTask.WaitAsync(TimeSpan.FromSeconds(5));
        Assert.AreEqual(HerdrOpsCliCommand.CoreUnavailableExitCode, exitCode);
        Assert.AreEqual(string.Empty, output.ToString());
        using var errorJson = JsonDocument.Parse(error.ToString());
        Assert.AreEqual(
            HerdrOpsSelfReportProtocol.ResultCodes.CoreUnavailable,
            errorJson.RootElement.GetProperty("code").GetString());
    }

    [TestMethod]
    public async Task InvalidPipeNameReturnsStructuredUsageError()
    {
        using var output = new StringWriter();
        using var error = new StringWriter();

        var exitCode = await HerdrOpsCliCommand.RunAsync(
            [
                HerdrOpsSelfReportProtocol.EventTypes.Assignment,
                "--input",
                "-",
                "--pipe-name",
                "invalid/pipe",
            ],
            new StringReader(HerdrOpsSelfReportJson.Serialize(ValidAssignmentInput())),
            output,
            error);

        Assert.AreEqual(HerdrOpsCliCommand.UsageFailureExitCode, exitCode);
        Assert.AreEqual(string.Empty, output.ToString());
        using var errorJson = JsonDocument.Parse(error.ToString());
        Assert.AreEqual(
            HerdrOpsSelfReportProtocol.ResultCodes.InvalidArguments,
            errorJson.RootElement.GetProperty("code").GetString());
    }

    [TestMethod]
    public async Task StandardInputOverBoundFailsBeforeAnyCoreConnection()
    {
        using var output = new StringWriter();
        using var error = new StringWriter();

        var exitCode = await HerdrOpsCliCommand.RunAsync(
            [
                HerdrOpsSelfReportProtocol.EventTypes.Assignment,
                "--input",
                "-",
                "--pipe-name",
                $"unused-{Guid.NewGuid():N}",
            ],
            new StringReader(new string('x', HerdrOpsCliCommand.MaximumInputBytes + 1)),
            output,
            error);

        Assert.AreEqual(HerdrOpsCliCommand.UsageFailureExitCode, exitCode);
        Assert.AreEqual(string.Empty, output.ToString());
        using var errorJson = JsonDocument.Parse(error.ToString());
        Assert.AreEqual(
            HerdrOpsSelfReportProtocol.ResultCodes.InvalidArguments,
            errorJson.RootElement.GetProperty("code").GetString());
    }

    [TestMethod]
    public async Task IdenticalRetryIsIdempotentButChangedContentConflicts()
    {
        var pipeName = $"herdrops-self-report-idempotent-{Guid.NewGuid():N}";
        var acceptance = new HerdrOpsSelfReportAcceptanceService(
            new InMemoryHerdrOpsTaskRegistry(["TASK-115"]));
        var server = CreateServer(pipeName, acceptance);
        using var serverCancellation = new CancellationTokenSource();
        var serverTask = server.RunAsync(serverCancellation.Token);
        await server.Ready.WaitAsync(TimeSpan.FromSeconds(5));
        var input = ValidAssignmentInput();
        var submission = HerdrOpsSelfReportJson.CreateSubmission(
            HerdrOpsSelfReportProtocol.EventTypes.Assignment,
            input);
        var client = new HerdrOpsSelfReportPipeClient(
            new HerdrOpsSelfReportPipeClientOptions(pipeName));

        var first = await client.SubmitAsync(submission, Guid.NewGuid());
        var repeated = await client.SubmitAsync(submission, Guid.NewGuid());
        var conflict = await client.SubmitAsync(
            submission with { Summary = "Changed content under an accepted event identifier." },
            Guid.NewGuid());

        serverCancellation.Cancel();
        await serverTask.WaitAsync(TimeSpan.FromSeconds(5));
        Assert.IsTrue(first.Accepted);
        Assert.IsTrue(repeated.Accepted);
        Assert.AreEqual(HerdrOpsSelfReportProtocol.ResultCodes.AcceptedIdempotent, repeated.Code);
        Assert.AreEqual(first.Sequence, repeated.Sequence);
        Assert.AreEqual(first.AcceptedUtc, repeated.AcceptedUtc);
        Assert.IsFalse(conflict.Accepted);
        Assert.AreEqual(HerdrOpsSelfReportProtocol.ResultCodes.EventIdConflict, conflict.Code);
        Assert.HasCount(1, acceptance.AcceptedEvents);
    }

    [TestMethod]
    public async Task ServerRejectsUnauthorizedSourceWithStructuredResult()
    {
        var pipeName = $"herdrops-self-report-source-{Guid.NewGuid():N}";
        var acceptance = new HerdrOpsSelfReportAcceptanceService(
            new InMemoryHerdrOpsTaskRegistry(["TASK-115"]));
        var server = CreateServer(pipeName, acceptance);
        using var serverCancellation = new CancellationTokenSource();
        var serverTask = server.RunAsync(serverCancellation.Token);
        await server.Ready.WaitAsync(TimeSpan.FromSeconds(5));
        await using var pipe = new NamedPipeClientStream(
            ".",
            pipeName,
            PipeDirection.InOut,
            PipeOptions.Asynchronous | PipeOptions.CurrentUserOnly);
        await pipe.ConnectAsync(5000, CancellationToken.None);
        var correlationId = Guid.NewGuid();
        var submission = HerdrOpsSelfReportJson.CreateSubmission(
            HerdrOpsSelfReportProtocol.EventTypes.Assignment,
            ValidAssignmentInput());
        var request = HerdrOpsSelfReportJson.CreateEnvelope(
            HerdrOpsSelfReportProtocol.MessageTypes.Submit,
            0,
            DateTimeOffset.UtcNow,
            "unauthorized-client",
            correlationId,
            submission);
        await HerdrOpsSelfReportJson.WriteFrameAsync(pipe, request, CancellationToken.None);

        var response = await HerdrOpsSelfReportJson.ReadFrameAsync(pipe, CancellationToken.None);
        var result = HerdrOpsSelfReportJson.DeserializeResult(response);
        serverCancellation.Cancel();
        await serverTask.WaitAsync(TimeSpan.FromSeconds(5));
        Assert.IsFalse(result.Accepted);
        Assert.AreEqual(HerdrOpsSelfReportProtocol.ResultCodes.UnauthorizedClient, result.Code);
        Assert.AreEqual(correlationId, response.CorrelationId);
        Assert.IsEmpty(acceptance.AcceptedEvents);
    }

    [TestMethod]
    public void ProductionSelfReportEndpointsRequireCurrentUserOnlyAndMatch()
    {
        Assert.IsTrue(HerdrOpsSelfReportPipeServer.RequiredPipeOptions.HasFlag(PipeOptions.CurrentUserOnly));
        Assert.IsTrue(HerdrOpsSelfReportPipeClient.RequiredPipeOptions.HasFlag(PipeOptions.CurrentUserOnly));
        Assert.IsTrue(HerdrOpsSelfReportPipeServer.RequiredPipeOptions.HasFlag(PipeOptions.WriteThrough));
        Assert.IsTrue(HerdrOpsSelfReportPipeClient.RequiredPipeOptions.HasFlag(PipeOptions.WriteThrough));
        var serverOptions = HerdrOpsSelfReportPipeServerOptions.ForCurrentUser();
        var clientOptions = HerdrOpsSelfReportPipeClientOptions.ForCurrentUser();
        Assert.AreEqual(serverOptions.PipeName, clientOptions.PipeName);
        Assert.StartsWith("herdrops-self-report-v1-", serverOptions.PipeName, StringComparison.Ordinal);
    }

    private static HerdrOpsSelfReportPipeServer CreateServer(
        string pipeName,
        HerdrOpsSelfReportAcceptanceService acceptance) => new(
        new HerdrOpsSelfReportPipeServerOptions(pipeName),
        (submission, correlationId, _cancellationToken) =>
            ValueTask.FromResult(acceptance.Accept(submission, correlationId)));

    private static async Task HoldConnectedClientAsync(
        NamedPipeServerStream server,
        CancellationToken cancellationToken)
    {
        try
        {
            await server.WaitForConnectionAsync(cancellationToken);
            await Task.Delay(Timeout.InfiniteTimeSpan, cancellationToken);
        }
        catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested)
        {
        }
    }

    private static HerdrOpsSelfReportCommandInput ValidAssignmentInput() => new(
        HerdrOpsSelfReportProtocol.Version,
        Guid.NewGuid(),
        "TASK-115",
        "project-manager",
        "Project Manager",
        DateTimeOffset.UtcNow,
        "Assign the bounded implementation task.",
        null,
        "backend-worker-01",
        null,
        null,
        null,
        null,
        null);
}
