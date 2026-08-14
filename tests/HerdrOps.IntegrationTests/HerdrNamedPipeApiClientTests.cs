using System.Globalization;
using System.Diagnostics;
using System.IO.Pipes;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using HerdrOps.Domain.Herdr;
using HerdrOps.Infrastructure.Herdr;

namespace HerdrOps.IntegrationTests;

[TestClass]
public sealed class HerdrNamedPipeApiClientTests
{
    [TestMethod]
    public void ServerIdentityVerifierBindsPidProcessStartPathAndExactHash()
    {
        using var currentProcess = Process.GetCurrentProcess();
        var executablePath = currentProcess.MainModule!.FileName;
        var expectedSha256 = Convert.ToHexString(SHA256.HashData(File.ReadAllBytes(executablePath)));
        var connection = new HerdrConnectedStream(
            Stream.Null,
            currentProcess.Id,
            currentProcess.StartTime.ToUniversalTime(),
            executablePath);

        var identity = new ExpectedHerdrServerIdentityVerifier(expectedSha256).Verify(connection);

        Assert.AreEqual(currentProcess.Id, identity.ProcessId);
        Assert.AreEqual(expectedSha256, identity.ExecutableSha256);
        Assert.IsTrue(Path.IsPathFullyQualified(identity.ExecutablePath));
    }

    [TestMethod]
    public void ServerIdentityVerifierRejectsDifferentExecutableHash()
    {
        using var currentProcess = Process.GetCurrentProcess();
        var connection = new HerdrConnectedStream(
            Stream.Null,
            currentProcess.Id,
            currentProcess.StartTime.ToUniversalTime(),
            currentProcess.MainModule!.FileName);

        var exception = Assert.ThrowsExactly<HerdrServerIdentityException>(() =>
            new ExpectedHerdrServerIdentityVerifier(new string('0', 64)).Verify(connection));

        StringAssert.Contains(exception.Message, "not admitted SHA-256");
    }

    [TestMethod]
    public async Task SnapshotRoundTripUsesNewlineFramingAndCorrelatesResponse()
    {
        var pipeName = CreatePipeName();
        using var server = CreateServer(pipeName);
        var serverTask = ServeSnapshotAsync(server, revision: 3, mismatchedId: false);
        var client = CreateClient();

        var snapshot = await client.GetSnapshotAsync(
            HerdrPipeEndpoint.FromSocketPath(pipeName),
            TestContext.CancellationToken);
        var observedRequest = await serverTask;

        Assert.AreEqual("session.snapshot", observedRequest.GetProperty("method").GetString());
        Assert.AreEqual(0, observedRequest.GetProperty("params").EnumerateObject().Count());
        Assert.AreEqual((ulong)3, snapshot.Panes[0].Revision);
        Assert.HasCount(1, snapshot.Agents);
    }

    [TestMethod]
    public async Task SnapshotRoundTripBindsTheActualPipeServerWithTheRealVerifier()
    {
        using var currentProcess = Process.GetCurrentProcess();
        var executablePath = currentProcess.MainModule!.FileName;
        var expectedSha256 = Convert.ToHexString(SHA256.HashData(File.ReadAllBytes(executablePath)));
        var pipeName = CreatePipeName();
        using var server = CreateServer(pipeName);
        var serverTask = ServeSnapshotAsync(server, revision: 3, mismatchedId: false);
        var client = new HerdrNamedPipeApiClient(
            serverIdentityVerifier: new ExpectedHerdrServerIdentityVerifier(expectedSha256));

        _ = await client.GetSnapshotAsync(
            HerdrPipeEndpoint.FromSocketPath(pipeName),
            TestContext.CancellationToken);
        await serverTask;

        Assert.IsNotNull(client.LastVerifiedServerIdentity);
        Assert.AreEqual(currentProcess.Id, client.LastVerifiedServerIdentity.ProcessId);
        Assert.AreEqual(expectedSha256, client.LastVerifiedServerIdentity.ExecutableSha256);
        Assert.AreEqual(
            currentProcess.StartTime.ToUniversalTime(),
            client.LastVerifiedServerIdentity.ProcessStartUtc);
    }

    [TestMethod]
    public async Task ExactFrameLimitIsAcceptedAndOneByteOverLimitIsRejected()
    {
        var representativeRequestId = "herdrops:snapshot:" + new string('0', 32);
        var responseBytes = Encoding.UTF8.GetByteCount(
            CreateSnapshotResponse(representativeRequestId, revision: 1));

        var exactPipeName = CreatePipeName();
        using var exactServer = CreateServer(exactPipeName);
        var exactServerTask = ServeSnapshotAsync(exactServer, revision: 1, mismatchedId: false);
        var exactSnapshot = await CreateClient(responseBytes).GetSnapshotAsync(
            HerdrPipeEndpoint.FromSocketPath(exactPipeName),
            TestContext.CancellationToken);
        await exactServerTask;

        var overLimitPipeName = CreatePipeName();
        using var overLimitServer = CreateServer(overLimitPipeName);
        var overLimitServerTask = ServeSnapshotAsync(
            overLimitServer,
            revision: 1,
            mismatchedId: false,
            tolerateClientDisconnect: true);
        var exception = await Assert.ThrowsExactlyAsync<HerdrProtocolException>(() =>
            CreateClient(responseBytes - 1).GetSnapshotAsync(
                HerdrPipeEndpoint.FromSocketPath(overLimitPipeName),
                TestContext.CancellationToken));
        await overLimitServerTask;

        Assert.AreEqual((ulong)1, exactSnapshot.Panes[0].Revision);
        StringAssert.Contains(exception.Message, $"exceeded the {responseBytes - 1}-byte limit");
    }

    [TestMethod]
    public async Task PaneReadRoundTripSerializesANonOptionalBoundAndFixedSource()
    {
        var pipeName = CreatePipeName();
        using var server = CreateServer(pipeName);
        var serverTask = ServePaneReadAsync(server);

        var read = await CreateClient().ReadRecentUnwrappedAsync(
            HerdrPipeEndpoint.FromSocketPath(pipeName),
            "pane-1",
            maximumLines: 37,
            TestContext.CancellationToken);
        var observedRequest = await serverTask;
        var parameters = observedRequest.GetProperty("params");

        Assert.AreEqual("pane.read", observedRequest.GetProperty("method").GetString());
        Assert.AreEqual("pane-1", parameters.GetProperty("pane_id").GetString());
        Assert.AreEqual(37, parameters.GetProperty("lines").GetInt32());
        Assert.AreEqual("recent_unwrapped", parameters.GetProperty("source").GetString());
        Assert.AreEqual("text", parameters.GetProperty("format").GetString());
        Assert.IsTrue(parameters.GetProperty("strip_ansi").GetBoolean());
        Assert.AreEqual((ulong)7, read.Revision);
        Assert.AreEqual("build complete", read.Text);
    }

    [TestMethod]
    public async Task PaneProcessInfoRoundTripCorrelatesTheRequestedPaneAndPid()
    {
        var pipeName = CreatePipeName();
        using var server = CreateServer(pipeName);
        var serverTask = ServePaneProcessInfoAsync(server);

        var processInfo = await CreateClient().GetPaneProcessInfoAsync(
            HerdrPipeEndpoint.FromSocketPath(pipeName),
            "pane-1",
            TestContext.CancellationToken);
        var observedRequest = await serverTask;

        Assert.AreEqual("pane.process_info", observedRequest.GetProperty("method").GetString());
        Assert.AreEqual("pane-1", observedRequest.GetProperty("params").GetProperty("pane_id").GetString());
        Assert.AreEqual((uint)700, processInfo.ShellProcessId);
        Assert.HasCount(1, processInfo.ForegroundProcesses);
        Assert.AreEqual((uint)701, processInfo.ForegroundProcesses[0].ProcessId);
        Assert.AreEqual("pwsh -NoLogo", processInfo.ForegroundProcesses[0].CommandLine);
    }

    [TestMethod]
    public async Task SubscriptionAcknowledgementKeepsPipeOpenForRegularAndFilteredEvents()
    {
        var pipeName = CreatePipeName();
        using var server = CreateServer(pipeName);
        var serverTask = ServeSubscriptionAsync(server);
        var client = CreateClient();

        await using var subscription = await client.SubscribeAsync(
            HerdrPipeEndpoint.FromSocketPath(pipeName),
            ["pane-1"],
            TestContext.CancellationToken);
        var first = await subscription.ReadNextAsync(TestContext.CancellationToken);
        var second = await subscription.ReadNextAsync(TestContext.CancellationToken);
        var observedRequest = await serverTask;

        Assert.AreEqual("events.subscribe", observedRequest.GetProperty("method").GetString());
        Assert.IsInstanceOfType<HerdrPaneChangedEvent>(first);
        Assert.IsInstanceOfType<HerdrPaneAgentStatusChangedEvent>(second);
        Assert.AreEqual(
            HerdrAgentStatus.Blocked,
            ((HerdrPaneAgentStatusChangedEvent)second).AgentStatus);
        Assert.AreEqual("กำลังรอ", ((HerdrPaneAgentStatusChangedEvent)second).Title);
    }

    [TestMethod]
    public async Task CancelledSubscriptionReadAndDisposeCloseThePipe()
    {
        var pipeName = CreatePipeName();
        using var server = CreateServer(pipeName);
        var serverTask = ServeBlockingSubscriptionAsync(server);
        var subscription = await CreateClient().SubscribeAsync(
            HerdrPipeEndpoint.FromSocketPath(pipeName),
            ["pane-1"],
            TestContext.CancellationToken);
        using var readCancellation = new CancellationTokenSource();
        readCancellation.Cancel();

        await Assert.ThrowsAsync<OperationCanceledException>(() =>
            subscription.ReadNextAsync(readCancellation.Token).AsTask());
        await subscription.DisposeAsync();
        var serverObservedEnd = await serverTask.WaitAsync(TimeSpan.FromSeconds(5));

        Assert.IsTrue(serverObservedEnd);
    }

    [TestMethod]
    public async Task InFlightCancellationPreservesPartialFrameForTheNextRead()
    {
        const string eventJson =
            "{\"event\":\"pane.agent_status_changed\",\"data\":{\"workspace_id\":\"workspace-1\",\"pane_id\":\"pane-1\",\"agent_status\":\"working\",\"title\":\"กำลังทำงาน\"}}";
        var eventBytes = Encoding.UTF8.GetBytes(eventJson + "\n");
        var thaiOffset = eventBytes.AsSpan().IndexOf(Encoding.UTF8.GetBytes("กำ"));
        Assert.IsGreaterThanOrEqualTo(0, thaiOffset);
        using var stream = new PartialFrameCancellationStream(
            eventBytes[..(thaiOffset + 1)],
            eventBytes[(thaiOffset + 1)..]);
        var reader = new HerdrJsonLineReader(stream, maximumFrameBytes: 1024);
        using var readCancellation = new CancellationTokenSource();

        var cancelledRead = reader.ReadAsync(readCancellation.Token).AsTask();
        await stream.WaitUntilCancellationReadAsync.WaitAsync(TimeSpan.FromSeconds(5));
        readCancellation.Cancel();
        await Assert.ThrowsAsync<OperationCanceledException>(() => cancelledRead);

        var recoveredJson = await reader.ReadAsync(TestContext.CancellationToken);
        var recoveredEvent = HerdrProtocolJsonCodec.ParseEvent(recoveredJson);

        Assert.IsInstanceOfType<HerdrPaneAgentStatusChangedEvent>(recoveredEvent);
        Assert.AreEqual(
            "กำลังทำงาน",
            ((HerdrPaneAgentStatusChangedEvent)recoveredEvent).Title);
    }

    [TestMethod]
    public async Task MismatchedResponseIdFailsClosed()
    {
        var pipeName = CreatePipeName();
        using var server = CreateServer(pipeName);
        var serverTask = ServeSnapshotAsync(server, revision: 1, mismatchedId: true);
        var client = CreateClient();

        var exception = await Assert.ThrowsExactlyAsync<HerdrProtocolException>(() =>
            client.GetSnapshotAsync(
                HerdrPipeEndpoint.FromSocketPath(pipeName),
                TestContext.CancellationToken));
        await serverTask;

        StringAssert.Contains(exception.Message, "did not match request id");
    }

    [TestMethod]
    public async Task OversizedResponseLineFailsBeforeJsonParsing()
    {
        var pipeName = CreatePipeName();
        using var server = CreateServer(pipeName);
        var serverTask = ServeRawResponseAsync(
            server,
            Encoding.UTF8.GetBytes(new string('x', 300) + "\n"));
        var client = CreateClient(maximumFrameBytes: 256);

        var exception = await Assert.ThrowsExactlyAsync<HerdrProtocolException>(() =>
            client.GetSnapshotAsync(
                HerdrPipeEndpoint.FromSocketPath(pipeName),
                TestContext.CancellationToken));
        await serverTask;

        StringAssert.Contains(exception.Message, "exceeded the 256-byte limit");
    }

    [TestMethod]
    public async Task InvalidUtf8ResponseFailsClosed()
    {
        var pipeName = CreatePipeName();
        using var server = CreateServer(pipeName);
        var serverTask = ServeRawResponseAsync(server, [0xFF, (byte)'\n']);
        var client = CreateClient();

        var exception = await Assert.ThrowsExactlyAsync<HerdrProtocolException>(() =>
            client.GetSnapshotAsync(
                HerdrPipeEndpoint.FromSocketPath(pipeName),
                TestContext.CancellationToken));
        await serverTask;

        StringAssert.Contains(exception.Message, "not strict UTF-8");
    }

    [TestMethod]
    public async Task StreamEndingMidLineFailsClosed()
    {
        var pipeName = CreatePipeName();
        using var server = CreateServer(pipeName);
        var serverTask = ServeRawResponseAsync(server, "{}"u8.ToArray());
        var client = CreateClient();

        var exception = await Assert.ThrowsExactlyAsync<HerdrProtocolException>(() =>
            client.GetSnapshotAsync(
                HerdrPipeEndpoint.FromSocketPath(pipeName),
                TestContext.CancellationToken));
        await serverTask;

        StringAssert.Contains(exception.Message, "middle of a JSON line");
    }

    [TestMethod]
    public void EndpointAcceptsHerdrLogicalPathAndStripsOnlyWindowsPipePrefix()
    {
        const string logicalPath = @"C:\Users\Example\AppData\Roaming\herdr\herdr.sock";
        var logical = HerdrPipeEndpoint.FromSocketPath(logicalPath);
        var prefixed = HerdrPipeEndpoint.FromSocketPath(
            HerdrPipeEndpoint.WindowsPipePrefix + logicalPath);

        Assert.AreEqual(logicalPath, logical.PipeName);
        Assert.AreEqual(logicalPath, prefixed.PipeName);
        Assert.AreEqual(HerdrPipeEndpoint.WindowsPipePrefix + logicalPath, prefixed.SocketPath);
    }

    public TestContext TestContext { get; set; } = null!;

    private static HerdrNamedPipeApiClient CreateClient(
        int maximumFrameBytes = HerdrNamedPipeApiClientOptions.DefaultMaximumFrameBytes) => new(
            serverIdentityVerifier: AllowUnboundHerdrServerIdentityForSyntheticTests.Instance,
            options: new HerdrNamedPipeApiClientOptions(
                TimeSpan.FromSeconds(2),
                maximumFrameBytes));

    private static NamedPipeServerStream CreateServer(string pipeName) => new(
        pipeName,
        PipeDirection.InOut,
        maxNumberOfServerInstances: 1,
        PipeTransmissionMode.Byte,
        PipeOptions.Asynchronous | PipeOptions.WriteThrough);

    private static string CreatePipeName() => $"herdrops-test-{Guid.NewGuid():N}";

    private static async Task<JsonElement> ServeSnapshotAsync(
        NamedPipeServerStream server,
        ulong revision,
        bool mismatchedId,
        bool tolerateClientDisconnect = false)
    {
        await server.WaitForConnectionAsync();
        var requestJson = await ReadLineAsync(server);
        using var requestDocument = JsonDocument.Parse(requestJson);
        var requestId = requestDocument.RootElement.GetProperty("id").GetString()!;
        var responseId = mismatchedId ? "different-id" : requestId;
        try
        {
            await WriteLineAsync(server, CreateSnapshotResponse(responseId, revision));
        }
        catch (IOException) when (tolerateClientDisconnect)
        {
            // An over-limit client may close the pipe as soon as the final byte crosses its limit.
        }

        return requestDocument.RootElement.Clone();
    }

    private static async Task<JsonElement> ServePaneReadAsync(NamedPipeServerStream server)
    {
        await server.WaitForConnectionAsync();
        var requestJson = await ReadLineAsync(server);
        using var requestDocument = JsonDocument.Parse(requestJson);
        var requestId = requestDocument.RootElement.GetProperty("id").GetString()!;
        await WriteLineAsync(
            server,
            JsonSerializer.Serialize(new
            {
                id = requestId,
                result = new
                {
                    type = "pane_read",
                    read = new
                    {
                        pane_id = "pane-1",
                        workspace_id = "workspace-1",
                        tab_id = "tab-1",
                        source = "recent_unwrapped",
                        format = "text",
                        text = "build complete",
                        revision = 7,
                        truncated = false,
                    },
                },
            }));
        return requestDocument.RootElement.Clone();
    }

    private static async Task<JsonElement> ServePaneProcessInfoAsync(NamedPipeServerStream server)
    {
        await server.WaitForConnectionAsync();
        var requestJson = await ReadLineAsync(server);
        using var requestDocument = JsonDocument.Parse(requestJson);
        var requestId = requestDocument.RootElement.GetProperty("id").GetString()!;
        await WriteLineAsync(
            server,
            JsonSerializer.Serialize(new
            {
                id = requestId,
                result = new
                {
                    type = "pane_process_info",
                    process_info = new
                    {
                        pane_id = "pane-1",
                        shell_pid = 700,
                        foreground_process_group_id = 701,
                        tty = (string?)null,
                        foreground_processes = new[]
                        {
                            new
                            {
                                pid = 701,
                                name = "pwsh",
                                argv0 = "pwsh",
                                argv = new[] { "pwsh", "-NoLogo" },
                                cmdline = "pwsh -NoLogo",
                                cwd = "Z:\\HerdrOps",
                            },
                        },
                    },
                },
            }));
        return requestDocument.RootElement.Clone();
    }

    private static async Task<JsonElement> ServeSubscriptionAsync(NamedPipeServerStream server)
    {
        await server.WaitForConnectionAsync();
        var requestJson = await ReadLineAsync(server);
        using var requestDocument = JsonDocument.Parse(requestJson);
        var requestId = requestDocument.RootElement.GetProperty("id").GetString()!;
        await WriteLineAsync(
            server,
            JsonSerializer.Serialize(new
            {
                id = requestId,
                result = new { type = "subscription_started" },
            }));
        const string firstEvent =
            """
            {"event":"pane_updated","data":{"type":"pane_updated","pane":{"pane_id":"pane-1","terminal_id":"terminal-1","workspace_id":"workspace-1","tab_id":"tab-1","focused":true,"agent_status":"working","revision":2,"agent":"codex","display_agent":"Codex","title":"Worker","cwd":"Z:\\HerdrOps","foreground_cwd":"Z:\\HerdrOps","terminal_title":"Codex"}}}
            """;
        const string secondEvent =
            """
            {"event":"pane.agent_status_changed","data":{"pane_id":"pane-1","workspace_id":"workspace-1","agent_status":"blocked","agent":"codex","display_agent":"Codex","title":"กำลังรอ"}}
            """;
        var combinedEvents = Encoding.UTF8.GetBytes(firstEvent + "\n" + secondEvent + "\n");
        var thaiPrefix = Encoding.UTF8.GetBytes("กำ");
        var thaiOffset = combinedEvents.AsSpan().IndexOf(thaiPrefix);
        Assert.IsGreaterThanOrEqualTo(0, thaiOffset);
        var splitOffset = thaiOffset + 1;
        await server.WriteAsync(combinedEvents.AsMemory(0, splitOffset));
        await server.WriteAsync(combinedEvents.AsMemory(splitOffset));
        await server.FlushAsync();
        return requestDocument.RootElement.Clone();
    }

    private static async Task<bool> ServeBlockingSubscriptionAsync(NamedPipeServerStream server)
    {
        await server.WaitForConnectionAsync();
        var requestJson = await ReadLineAsync(server);
        using var requestDocument = JsonDocument.Parse(requestJson);
        var requestId = requestDocument.RootElement.GetProperty("id").GetString()!;
        await WriteLineAsync(
            server,
            JsonSerializer.Serialize(new
            {
                id = requestId,
                result = new { type = "subscription_started" },
            }));
        var buffer = new byte[1];
        try
        {
            return await server.ReadAsync(buffer) == 0;
        }
        catch (IOException)
        {
            return true;
        }
    }

    private static async Task ServeRawResponseAsync(NamedPipeServerStream server, byte[] responseBytes)
    {
        await server.WaitForConnectionAsync();
        _ = await ReadLineAsync(server);
        try
        {
            await server.WriteAsync(responseBytes);
            await server.FlushAsync();
        }
        catch (IOException)
        {
            // A fail-closed client may disconnect as soon as its frame limit is crossed.
        }
        finally
        {
            if (server.IsConnected)
            {
                server.Disconnect();
            }
        }
    }

    private static async Task<string> ReadLineAsync(Stream stream)
    {
        using var reader = new StreamReader(
            stream,
            new UTF8Encoding(false, true),
            detectEncodingFromByteOrderMarks: false,
            bufferSize: 1024,
            leaveOpen: true);
        return await reader.ReadLineAsync() ?? throw new EndOfStreamException("Missing test request.");
    }

    private static async Task WriteLineAsync(Stream stream, string json)
    {
        var bytes = Encoding.UTF8.GetBytes(json + "\n");
        await stream.WriteAsync(bytes);
        await stream.FlushAsync();
    }

    private static string CreateSnapshotResponse(string requestId, ulong revision)
    {
        var expanded = """
            {"id":"__REQUEST_ID__","result":{"type":"session_snapshot","snapshot":{
              "version":"0.8.0-preview","protocol":19,
              "workspaces":[{"workspace_id":"workspace-1","number":1,"label":"HerdrOps","focused":true,"pane_count":1,"tab_count":1,"active_tab_id":"tab-1","agent_status":"working"}],
              "tabs":[{"tab_id":"tab-1","workspace_id":"workspace-1","number":1,"label":"Core","focused":true,"pane_count":1,"agent_status":"working"}],
              "panes":[{"pane_id":"pane-1","terminal_id":"terminal-1","workspace_id":"workspace-1","tab_id":"tab-1","focused":true,"agent_status":"working","revision":__REVISION__,"agent":"codex","display_agent":"Codex","title":"Worker","cwd":"Z:\\HerdrOps","foreground_cwd":"Z:\\HerdrOps","terminal_title":"Codex"}],
              "layouts":[],
              "agents":[{"terminal_id":"terminal-1","workspace_id":"workspace-1","tab_id":"tab-1","pane_id":"pane-1","focused":true,"agent_status":"working","revision":__REVISION__,"state_change_seq":1,"agent":"codex","display_agent":"Codex","name":"Worker 01","title":"Worker","cwd":"Z:\\HerdrOps","foreground_cwd":"Z:\\HerdrOps","terminal_title":"Codex","interactive_ready":true,"launch_pending":false,"screen_detection_skipped":false}],
              "focused_workspace_id":"workspace-1","focused_tab_id":"tab-1","focused_pane_id":"pane-1"
            }}}
            """
            .Replace("__REQUEST_ID__", requestId, StringComparison.Ordinal)
            .Replace("__REVISION__", revision.ToString(CultureInfo.InvariantCulture), StringComparison.Ordinal);
        using var document = JsonDocument.Parse(expanded);
        return JsonSerializer.Serialize(document.RootElement);
    }

    private sealed class PartialFrameCancellationStream(
        byte[] prefix,
        byte[] suffix) : Stream
    {
        private readonly TaskCompletionSource _cancellationReadStarted = new(
            TaskCreationOptions.RunContinuationsAsynchronously);
        private int _readStage;

        public Task WaitUntilCancellationReadAsync => _cancellationReadStarted.Task;

        public override bool CanRead => true;

        public override bool CanSeek => false;

        public override bool CanWrite => false;

        public override long Length => throw new NotSupportedException();

        public override long Position
        {
            get => throw new NotSupportedException();
            set => throw new NotSupportedException();
        }

        public override void Flush()
        {
        }

        public override int Read(byte[] buffer, int offset, int count) =>
            throw new NotSupportedException();

        public override async ValueTask<int> ReadAsync(
            Memory<byte> buffer,
            CancellationToken cancellationToken = default)
        {
            var stage = Interlocked.Increment(ref _readStage);
            if (stage == 1)
            {
                prefix.CopyTo(buffer);
                return prefix.Length;
            }

            if (stage == 2)
            {
                _cancellationReadStarted.TrySetResult();
                await Task.Delay(Timeout.InfiniteTimeSpan, cancellationToken);
                return 0;
            }

            if (stage == 3)
            {
                suffix.CopyTo(buffer);
                return suffix.Length;
            }

            return 0;
        }

        public override long Seek(long offset, SeekOrigin origin) =>
            throw new NotSupportedException();

        public override void SetLength(long value) =>
            throw new NotSupportedException();

        public override void Write(byte[] buffer, int offset, int count) =>
            throw new NotSupportedException();
    }
}
