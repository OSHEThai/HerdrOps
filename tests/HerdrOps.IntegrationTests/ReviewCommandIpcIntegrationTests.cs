using System.IO.Pipes;
using System.Security.Cryptography;
using System.Text;
using HerdrOps.App.ReviewIpc;
using HerdrOps.Contracts.ReviewIpc;
using HerdrOps.Core;
using HerdrOps.Domain.Assignments;
using HerdrOps.Domain.Compliance;
using HerdrOps.Domain.Evidence;
using HerdrOps.Infrastructure.ReviewIpc;
using HerdrOps.Infrastructure.Storage;
using HerdrOps.App.Localization;

namespace HerdrOps.IntegrationTests;

[TestClass]
public sealed class ReviewCommandIpcIntegrationTests
{
    private static readonly DateTimeOffset BaseUtc =
        new(2026, 8, 16, 5, 0, 0, TimeSpan.Zero);

    [TestMethod]
    public async Task AppCommandTravelsThroughCurrentUserPipeAndCoreAuthorityOnce()
    {
        using var directory = new TemporaryDirectory();
        using var store = new SqliteHerdrStateStore(new HerdrStateStoreOptions(
            Path.Combine(directory.Path, "herdrops.db")));
        SeedProjectManagerRole(store);
        var evidenceId = SeedIncident(store, directory);
        var service = new ComplianceReviewWorkflowService(
            store,
            new FixedTimeProvider(BaseUtc.AddMinutes(10)));
        var pipeName = $"herdrops-review-test-{Guid.NewGuid():N}";
        var time = new FixedTimeProvider(BaseUtc.AddMinutes(10));
        var server = new HerdrOpsReviewCommandPipeServer(
            new HerdrOpsReviewCommandPipeServerOptions(pipeName),
            service.ExecuteAsync,
            time);
        using var stop = new CancellationTokenSource();
        var serverTask = server.RunAsync(stop.Token);
        await server.Ready.WaitAsync(TimeSpan.FromSeconds(5));

        try
        {
            var client = new HerdrOpsReviewCommandPipeClient(
                new HerdrOpsReviewCommandPipeClientOptions(
                    pipeName,
                    TimeSpan.FromSeconds(5)),
                time,
                static _ => { });
            var sharedState = new ComplianceReviewStateHub();
            using var dashboardState = new HerdrOps.App.Live.LiveDashboardState(sharedState);
            var coordinator = new ComplianceReviewCommandCoordinator(client, sharedState);
            var queueNotifications = 0;
            var widgetNotifications = 0;
            sharedState.StateChanged += (_, _) => queueNotifications++;
            sharedState.StateChanged += (_, _) => widgetNotifications++;
            var request = new HerdrOpsReviewCommandRequest(
                ComplianceReviewWorkflowContract.ContractVersion,
                Guid.Parse("11111111-1111-1111-1111-111111111111"),
                "INC-27-IPC",
                (int)ComplianceReviewState.Suspected,
                ExpectedSequence: 0,
                "project-manager",
                (int)ComplianceReviewDecisionKind.SendToLeader,
                "Send the incident to the assigned Leader for review.",
                [evidenceId]);

            var accepted = await coordinator.ExecuteAsync(request);
            var retry = await coordinator.ExecuteAsync(request);

            Assert.IsTrue(accepted.IsAccepted);
            Assert.IsFalse(accepted.WasAlreadyPresent);
            Assert.IsNotNull(accepted.Incident);
            Assert.IsNotNull(accepted.AuditEvent);
            Assert.AreEqual((int)ComplianceReviewState.PendingLeader, accepted.Incident.State);
            Assert.AreEqual((int)ComplianceReviewerRole.ProjectManager, accepted.AuditEvent.ReviewerRole);
            Assert.IsTrue(retry.IsAccepted);
            Assert.IsTrue(retry.WasAlreadyPresent);
            Assert.AreEqual(accepted.AuditEvent.AuditSha256, retry.AuditEvent!.AuditSha256);
            Assert.HasCount(1, store.ReadComplianceReviewAudit("INC-27-IPC"));
            Assert.AreEqual(1, queueNotifications);
            Assert.AreEqual(1, widgetNotifications);
            Assert.AreEqual(
                ComplianceReviewState.PendingLeader,
                sharedState.Read("INC-27-IPC")!.State);
            Assert.AreEqual(1, dashboardState.ComplianceQueue.AuthoritativeIncidentCount);
            Assert.AreEqual(
                "INC-27-IPC",
                dashboardState.ComplianceQueue.VisibleIncidents.Single().IncidentId);
            Assert.IsTrue(dashboardState.Widgets.Notices.Any(item =>
                item.AgentName.Contains("INC-27-IPC", StringComparison.Ordinal)));
        }
        finally
        {
            stop.Cancel();
            await serverTask.WaitAsync(TimeSpan.FromSeconds(5));
        }
    }

    [TestMethod]
    public async Task LiveQueueUsesCoreCapabilitiesAndLeaderActionUpdatesQueueAndWidget()
    {
        using var directory = new TemporaryDirectory();
        using var store = new SqliteHerdrStateStore(new HerdrStateStoreOptions(
            Path.Combine(directory.Path, "herdrops-live-review.db")));
        SeedReviewRoles(store);
        var evidenceId = SeedIncident(store, directory, "INC-27-LIVE-UI");
        var service = new ComplianceReviewWorkflowService(
            store,
            new FixedTimeProvider(BaseUtc.AddMinutes(10)));
        var pipeName = $"herdrops-review-live-{Guid.NewGuid():N}";
        var authorizedClients = new List<(string ActorId, uint ProcessId)>();
        var server = new HerdrOpsReviewCommandPipeServer(
            new HerdrOpsReviewCommandPipeServerOptions(pipeName),
            service.ExecuteAsync,
            service.ReadCapabilitiesAsync,
            (actorId, processId, cancellationToken) =>
            {
                cancellationToken.ThrowIfCancellationRequested();
                lock (authorizedClients)
                {
                    authorizedClients.Add((actorId, processId));
                }

                return ValueTask.FromResult(
                    processId != 0 &&
                    (string.Equals(actorId, "project-manager", StringComparison.Ordinal) ||
                     string.Equals(actorId, "backend-leader", StringComparison.Ordinal)));
            },
            new FixedTimeProvider(BaseUtc.AddMinutes(10)));
        using var stop = new CancellationTokenSource();
        var serverTask = server.RunAsync(stop.Token);
        await server.Ready.WaitAsync(TimeSpan.FromSeconds(5));

        try
        {
            var client = new HerdrOpsReviewCommandPipeClient(
                new HerdrOpsReviewCommandPipeClientOptions(
                    pipeName,
                    TimeSpan.FromSeconds(5)),
                new FixedTimeProvider(BaseUtc.AddMinutes(10)),
                static _ => { });
            var sharedState = new ComplianceReviewStateHub();
            var coordinator = new ComplianceReviewCommandCoordinator(client, sharedState);
            using var dashboard = new HerdrOps.App.Live.LiveDashboardState(
                sharedState,
                coordinator,
                "backend-leader",
                new FixedTimeProvider(BaseUtc.AddMinutes(10)));
            var sent = await coordinator.ExecuteAsync(new HerdrOpsReviewCommandRequest(
                ComplianceReviewWorkflowContract.ContractVersion,
                Guid.Parse("66666666-6666-6666-6666-666666666666"),
                "INC-27-LIVE-UI",
                (int)ComplianceReviewState.Suspected,
                ExpectedSequence: 0,
                "project-manager",
                (int)ComplianceReviewDecisionKind.SendToLeader,
                "Send the evidence-backed incident to the assigned Leader.",
                [evidenceId]));

            Assert.IsTrue(sent.IsAccepted);
            await dashboard.ComplianceQueue.RefreshReviewCapabilitiesAsync();
            Assert.IsTrue(dashboard.ComplianceQueue.CanEditReviewReason);
            dashboard.ComplianceQueue.ReviewReason =
                "Escalate the reviewed evidence to the Project Manager.";
            var leaderAction = dashboard.ComplianceQueue.ReviewActions.Single(item =>
                item.Id == "escalate-to-pm");

            Assert.IsTrue(leaderAction.IsRoleApplicable);
            Assert.IsTrue(
                leaderAction.IsEnabled,
                $"status={dashboard.ComplianceQueue.ReviewStatus}; " +
                $"reason={dashboard.ComplianceQueue.ReviewReason}; " +
                $"unavailable={leaderAction.UnavailableReason}");
            Assert.IsFalse(dashboard.ComplianceQueue.ReviewActions.Single(item =>
                item.Id == "confirm").IsEnabled);
            var accepted = await dashboard.ComplianceQueue
                .ExecuteReviewActionAsync(leaderAction);

            Assert.IsTrue(accepted);
            var audit = store.ReadComplianceReviewAudit("INC-27-LIVE-UI");
            Assert.HasCount(2, audit);
            Assert.AreEqual("project-manager", audit[0].ReviewerActorId);
            Assert.AreEqual(ComplianceReviewerRole.ProjectManager, audit[0].ReviewerRole);
            Assert.AreEqual("backend-leader", audit[1].ReviewerActorId);
            Assert.AreEqual(ComplianceReviewerRole.Leader, audit[1].ReviewerRole);
            Assert.AreEqual(
                ComplianceReviewState.PendingProjectManager,
                sharedState.Read("INC-27-LIVE-UI")!.State);
            Assert.AreEqual(
                UiLanguageService.Shared["ComplianceQueueStatePendingProjectManager"],
                dashboard.ComplianceQueue.VisibleIncidents.Single().State);
            var widgetNotice = dashboard.Widgets.Notices.Single(item =>
                item.AgentName.Contains("INC-27-LIVE-UI", StringComparison.Ordinal));
            Assert.AreEqual(
                UiLanguageService.Shared["WidgetReviewStatePendingProjectManager"],
                widgetNotice.State);
            Assert.IsTrue(widgetNotice.CanOpen);
            Assert.IsFalse(string.IsNullOrWhiteSpace(widgetNotice.OpenAutomationName));
            Assert.AreEqual(
                "compliance-review:INC-27-LIVE-UI",
                widgetNotice.Route!.SourceEventId);
            lock (authorizedClients)
            {
                Assert.IsGreaterThanOrEqualTo(3, authorizedClients.Count);
                Assert.IsTrue(authorizedClients.All(item => item.ProcessId != 0));
                Assert.IsTrue(authorizedClients.Any(item =>
                    item.ActorId == "project-manager"));
                Assert.IsTrue(authorizedClients.Any(item =>
                    item.ActorId == "backend-leader"));
            }
        }
        finally
        {
            stop.Cancel();
            await serverTask.WaitAsync(TimeSpan.FromSeconds(5));
        }
    }

    [TestMethod]
    public async Task WrongClientSourceIsRejectedBeforeHandlerRuns()
    {
        var pipeName = $"herdrops-review-test-{Guid.NewGuid():N}";
        var handlerCalls = 0;
        var server = new HerdrOpsReviewCommandPipeServer(
            new HerdrOpsReviewCommandPipeServerOptions(pipeName),
            (request, correlationId, cancellationToken) =>
            {
                _ = request;
                _ = correlationId;
                cancellationToken.ThrowIfCancellationRequested();
                Interlocked.Increment(ref handlerCalls);
                return ValueTask.FromResult(new HerdrOpsReviewCommandResult(
                    false,
                    1,
                    "should-not-run",
                    null,
                    null,
                    false));
            },
            new FixedTimeProvider(BaseUtc));
        using var stop = new CancellationTokenSource();
        var serverTask = server.RunAsync(stop.Token);
        await server.Ready.WaitAsync(TimeSpan.FromSeconds(5));

        try
        {
            await using var pipe = new NamedPipeClientStream(
                ".",
                pipeName,
                PipeDirection.InOut,
                PipeOptions.Asynchronous | PipeOptions.CurrentUserOnly);
            await pipe.ConnectAsync(5000);
            var correlationId = Guid.Parse("22222222-2222-2222-2222-222222222222");
            var invalidHello = HerdrOpsReviewCommandJson.CreateEnvelope(
                HerdrOpsReviewCommandProtocol.MessageTypes.Hello,
                BaseUtc,
                "untrusted-client",
                correlationId,
                new HerdrOpsReviewCommandHello(
                    HerdrOpsReviewCommandProtocol.AppClientRole,
                    "untrusted"));
            await HerdrOpsReviewCommandJson.WriteFrameAsync(
                pipe,
                invalidHello,
                CancellationToken.None);
            var response = await HerdrOpsReviewCommandJson.ReadFrameAsync(
                pipe,
                CancellationToken.None);
            var error = HerdrOpsReviewCommandJson
                .DeserializePayload<HerdrOpsReviewCommandError>(response);

            Assert.AreEqual(HerdrOpsReviewCommandProtocol.MessageTypes.Error, response.MessageType);
            Assert.AreEqual(
                HerdrOpsReviewCommandProtocol.ErrorCodes.UnauthorizedClient,
                error.Code);
            Assert.AreEqual(0, handlerCalls);
        }
        finally
        {
            stop.Cancel();
            await serverTask.WaitAsync(TimeSpan.FromSeconds(5));
        }
    }

    [TestMethod]
    public async Task ClientProcessAuthorizationRejectsBeforeCoreHandlerRuns()
    {
        var pipeName = $"herdrops-review-auth-{Guid.NewGuid():N}";
        var handlerCalls = 0;
        var authorizationCalls = 0;
        uint observedProcessId = 0;
        var server = new HerdrOpsReviewCommandPipeServer(
            new HerdrOpsReviewCommandPipeServerOptions(pipeName),
            (request, correlationId, cancellationToken) =>
            {
                _ = request;
                _ = correlationId;
                cancellationToken.ThrowIfCancellationRequested();
                Interlocked.Increment(ref handlerCalls);
                return ValueTask.FromResult(new HerdrOpsReviewCommandResult(
                    false,
                    1,
                    "should-not-run",
                    null,
                    null,
                    false));
            },
            (request, correlationId, cancellationToken) =>
            {
                _ = request;
                _ = correlationId;
                cancellationToken.ThrowIfCancellationRequested();
                return ValueTask.FromResult(new HerdrOpsReviewCapabilitiesResult(
                    false,
                    null,
                    null,
                    null,
                    [],
                    "should-not-run"));
            },
            (actorId, processId, cancellationToken) =>
            {
                _ = actorId;
                cancellationToken.ThrowIfCancellationRequested();
                observedProcessId = processId;
                Interlocked.Increment(ref authorizationCalls);
                return ValueTask.FromResult(false);
            },
            new FixedTimeProvider(BaseUtc));
        using var stop = new CancellationTokenSource();
        var serverTask = server.RunAsync(stop.Token);
        await server.Ready.WaitAsync(TimeSpan.FromSeconds(5));

        try
        {
            var client = new HerdrOpsReviewCommandPipeClient(
                new HerdrOpsReviewCommandPipeClientOptions(
                    pipeName,
                    TimeSpan.FromSeconds(5)),
                new FixedTimeProvider(BaseUtc),
                static _ => { });
            var exception = await Assert.ThrowsExactlyAsync<
                HerdrOpsReviewCommandProtocolException>(async () =>
                await client.ExecuteAsync(new HerdrOpsReviewCommandRequest(
                    ComplianceReviewWorkflowContract.ContractVersion,
                    Guid.Parse("77777777-7777-7777-7777-777777777777"),
                    "INC-27-AUTH",
                    (int)ComplianceReviewState.Suspected,
                    ExpectedSequence: 0,
                    "project-manager",
                    (int)ComplianceReviewDecisionKind.Confirm,
                    "Confirm the incident after process authorization.",
                    [])));

            StringAssert.Contains(exception.Message, "unauthorized-client");
            Assert.AreEqual(1, authorizationCalls);
            Assert.AreNotEqual(0u, observedProcessId);
            Assert.AreEqual(0, handlerCalls);
        }
        finally
        {
            stop.Cancel();
            await serverTask.WaitAsync(TimeSpan.FromSeconds(5));
        }
    }

    [TestMethod]
    public async Task CliDerivesReviewerIdentityFromHerdrPaneAndCorePersistsThatAuthority()
    {
        using var directory = new TemporaryDirectory();
        using var store = new SqliteHerdrStateStore(new HerdrStateStoreOptions(
            Path.Combine(directory.Path, "herdrops-cli.db")));
        const string paneActorId = "w5:p27";
        SeedProjectManagerRole(store, paneActorId);
        var evidenceId = SeedIncident(store, directory, "INC-27-CLI");
        var service = new ComplianceReviewWorkflowService(
            store,
            new FixedTimeProvider(BaseUtc.AddMinutes(10)));
        var pipeName = $"herdrops-review-cli-{Guid.NewGuid():N}";
        var processAuthorizations = 0;
        var server = new HerdrOpsReviewCommandPipeServer(
            new HerdrOpsReviewCommandPipeServerOptions(pipeName),
            service.ExecuteAsync,
            service.ReadCapabilitiesAsync,
            (actorId, processId, cancellationToken) =>
            {
                cancellationToken.ThrowIfCancellationRequested();
                Interlocked.Increment(ref processAuthorizations);
                return ValueTask.FromResult(
                    string.Equals(actorId, paneActorId, StringComparison.Ordinal) &&
                    processId != 0);
            },
            new FixedTimeProvider(BaseUtc.AddMinutes(10)));
        using var stop = new CancellationTokenSource();
        var serverTask = server.RunAsync(stop.Token);
        await server.Ready.WaitAsync(TimeSpan.FromSeconds(5));

        try
        {
            var input = new HerdrOpsReviewCliCommandInput(
                ComplianceReviewWorkflowContract.ContractVersion,
                Guid.Parse("44444444-4444-4444-4444-444444444444"),
                "INC-27-CLI",
                (int)ComplianceReviewState.Suspected,
                ExpectedSequence: 0,
                (int)ComplianceReviewDecisionKind.Confirm,
                "Confirm the evidence-backed incident from the Project Manager pane.",
                [evidenceId]);
            using var output = new StringWriter();
            using var error = new StringWriter();

            var exitCode = await HerdrOps.Cli.HerdrOpsCliCommand.RunAsync(
                [
                    HerdrOps.Cli.ComplianceReviewCliCommand.CommandName,
                    "--input",
                    "-",
                ],
                new StringReader(HerdrOpsReviewCommandJson.Serialize(input)),
                output,
                error,
                environmentVariableReader: name => name switch
                {
                    "HERDR_ENV" => "1",
                    "HERDR_PANE_ID" => paneActorId,
                    _ => null,
                },
                reviewClient: new HerdrOps.Cli.HerdrOpsReviewCommandPipeClient(
                    new HerdrOps.Cli.HerdrOpsReviewCommandCliPipeOptions(
                        pipeName,
                        TimeSpan.FromSeconds(5)),
                    timeProvider: null,
                    serverProcessValidator: static _ => { }));

            Assert.AreEqual(HerdrOps.Cli.HerdrOpsCliCommand.SuccessExitCode, exitCode, error.ToString());
            Assert.AreEqual(string.Empty, error.ToString());
            var audit = store.ReadComplianceReviewAudit("INC-27-CLI");
            Assert.HasCount(1, audit);
            Assert.AreEqual(paneActorId, audit[0].ReviewerActorId);
            Assert.AreEqual(ComplianceReviewerRole.ProjectManager, audit[0].ReviewerRole);
            Assert.AreEqual(1, processAuthorizations);
            StringAssert.Contains(output.ToString(), "\"isAccepted\":true");
        }
        finally
        {
            stop.Cancel();
            await serverTask.WaitAsync(TimeSpan.FromSeconds(5));
        }
    }

    [TestMethod]
    public async Task CliFailsBeforeCoreWhenHerdrPaneIdentityIsUnavailable()
    {
        var input = new HerdrOpsReviewCliCommandInput(
            ComplianceReviewWorkflowContract.ContractVersion,
            Guid.Parse("55555555-5555-5555-5555-555555555555"),
            "INC-27-CLI",
            (int)ComplianceReviewState.Suspected,
            ExpectedSequence: 0,
            (int)ComplianceReviewDecisionKind.Confirm,
            "Confirm the incident.",
            []);
        using var output = new StringWriter();
        using var error = new StringWriter();

        var exitCode = await HerdrOps.Cli.ComplianceReviewCliCommand.RunAsync(
            [HerdrOps.Cli.ComplianceReviewCliCommand.CommandName, "--input", "-"],
            new StringReader(HerdrOpsReviewCommandJson.Serialize(input)),
            output,
            error,
            environmentVariableReader: _ => null);

        Assert.AreEqual(HerdrOps.Cli.HerdrOpsCliCommand.UsageFailureExitCode, exitCode);
        Assert.AreEqual(string.Empty, output.ToString());
        StringAssert.Contains(error.ToString(), "herdr-identity-unavailable");
    }

    [TestMethod]
    public async Task CliRejectsPublicReviewPipeOverride()
    {
        using var output = new StringWriter();
        using var error = new StringWriter();

        var exitCode = await HerdrOps.Cli.ComplianceReviewCliCommand.RunAsync(
            [
                HerdrOps.Cli.ComplianceReviewCliCommand.CommandName,
                "--input",
                "-",
                "--pipe-name",
                "same-user-fake-server",
            ],
            new StringReader("{}"),
            output,
            error,
            environmentVariableReader: name => name switch
            {
                "HERDR_ENV" => "1",
                "HERDR_PANE_ID" => "project-manager",
                _ => null,
            });

        Assert.AreEqual(HerdrOps.Cli.HerdrOpsCliCommand.UsageFailureExitCode, exitCode);
        Assert.AreEqual(string.Empty, output.ToString());
        StringAssert.Contains(error.ToString(), "invalid-arguments");
        StringAssert.Contains(error.ToString(), "--pipe-name");
    }

    [TestMethod]
    public async Task AppRejectsSameUserPipeServerWhoseProcessIsNotHerdrOpsCore()
    {
        var pipeName = $"herdrops-review-fake-server-{Guid.NewGuid():N}";
        var server = new HerdrOpsReviewCommandPipeServer(
            new HerdrOpsReviewCommandPipeServerOptions(pipeName),
            static (_, _, _) => ValueTask.FromResult(new HerdrOpsReviewCommandResult(
                IsAccepted: false,
                RejectionCode: (int)ComplianceReviewRejectionCode.UnknownIncident,
                Message: "The fake server must not reach this handler.",
                Incident: null,
                AuditEvent: null,
                WasAlreadyPresent: false)));
        using var stop = new CancellationTokenSource();
        var serverTask = server.RunAsync(stop.Token);
        await server.Ready.WaitAsync(TimeSpan.FromSeconds(5));

        try
        {
            var client = new HerdrOpsReviewCommandPipeClient(
                new HerdrOpsReviewCommandPipeClientOptions(
                    pipeName,
                    TimeSpan.FromSeconds(5)));
            var exception = await Assert.ThrowsExactlyAsync<
                HerdrOpsReviewCommandProtocolException>(async () =>
                await client.ExecuteAsync(new HerdrOpsReviewCommandRequest(
                    ComplianceReviewWorkflowContract.ContractVersion,
                    Guid.Parse("12121212-1212-1212-1212-121212121212"),
                    "INC-FAKE-SERVER",
                    (int)ComplianceReviewState.Suspected,
                    ExpectedSequence: 0,
                    "project-manager",
                    (int)ComplianceReviewDecisionKind.Confirm,
                    "A fake local server cannot return an authoritative outcome.",
                    [])));

            StringAssert.Contains(exception.Message, "not a HerdrOps Core executable");
        }
        finally
        {
            stop.Cancel();
            await serverTask.WaitAsync(TimeSpan.FromSeconds(5));
        }
    }

    [TestMethod]
    public void BothPipeEndsRequireCurrentUserOnlyAndUseDistinctName()
    {
        Assert.IsTrue(
            HerdrOpsReviewCommandPipeServer.RequiredPipeOptions.HasFlag(
                PipeOptions.CurrentUserOnly));
        Assert.IsTrue(
            HerdrOpsReviewCommandPipeClient.RequiredPipeOptions.HasFlag(
                PipeOptions.CurrentUserOnly));
        Assert.IsTrue(
            HerdrOps.Cli.HerdrOpsReviewCommandPipeClient.RequiredPipeOptions.HasFlag(
                PipeOptions.CurrentUserOnly));
        var options = HerdrOpsReviewCommandPipeServerOptions.ForCurrentUser();
        var client = HerdrOpsReviewCommandPipeClientOptions.ForCurrentUser();
        Assert.AreEqual(options.PipeName, client.PipeName);
        StringAssert.StartsWith(options.PipeName, "herdrops-review-v1-");
    }

    private static void SeedProjectManagerRole(
        SqliteHerdrStateStore store,
        string actorId = "project-manager")
    {
        var occurredUtc = BaseUtc.AddSeconds(1);
        var assignment = new AssignmentLifecycleEvent(
            AssignmentLifecycleContract.Version,
            Guid.Parse("aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"),
            AssignmentLifecycleEventKind.Assignment,
            Sequence: 1,
            occurredUtc,
            occurredUtc.AddMilliseconds(100),
            AssignmentLifecycleContract.CoreSource,
            Guid.Parse("bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb"),
            Hash("project-manager-role"),
            "TASK-115",
            actorId,
            "Project Manager",
            "Assign the compliance incident owner.",
            ParentEventId: null,
            TargetAgentId: "backend-worker-01",
            ProgressPercent: null,
            DeviationReason: null,
            EvidenceReference: null,
            EvidenceSha256: null,
            HandoffNote: null);
        var reducer = new AssignmentLifecycleReducer();
        store.CommitAssignmentLifecycle(reducer.Process(assignment));
    }

    private static void SeedReviewRoles(SqliteHerdrStateStore store)
    {
        var assignment = ReviewRoleEvent(
            AssignmentLifecycleEventKind.Assignment,
            sequence: 1,
            actorId: "project-manager",
            actorRole: "Project Manager",
            parentEventId: null,
            targetAgentId: "backend-leader");
        var acknowledgement = ReviewRoleEvent(
            AssignmentLifecycleEventKind.Acknowledgement,
            sequence: 2,
            actorId: "backend-leader",
            actorRole: "Backend Leader",
            parentEventId: assignment.EventId,
            targetAgentId: null);
        var reducer = new AssignmentLifecycleReducer();
        store.CommitAssignmentLifecycle(reducer.Process(assignment));
        store.CommitAssignmentLifecycle(reducer.Process(acknowledgement));
    }

    private static AssignmentLifecycleEvent ReviewRoleEvent(
        AssignmentLifecycleEventKind kind,
        long sequence,
        string actorId,
        string actorRole,
        Guid? parentEventId,
        string? targetAgentId)
    {
        var occurredUtc = BaseUtc.AddSeconds(sequence);
        return new AssignmentLifecycleEvent(
            AssignmentLifecycleContract.Version,
            Guid.Parse($"90000000-0000-0000-0000-{sequence:000000000000}"),
            kind,
            sequence,
            occurredUtc,
            occurredUtc.AddMilliseconds(100),
            AssignmentLifecycleContract.CoreSource,
            Guid.Parse($"91000000-0000-0000-0000-{sequence:000000000000}"),
            Hash($"review-role-{sequence}"),
            "TASK-115",
            actorId,
            actorRole,
            $"Review role lifecycle event {sequence}.",
            parentEventId,
            targetAgentId,
            ProgressPercent: null,
            DeviationReason: null,
            EvidenceReference: null,
            EvidenceSha256: null,
            HandoffNote: null);
    }

    private static string SeedIncident(
        SqliteHerdrStateStore store,
        TemporaryDirectory directory,
        string incidentId = "INC-27-IPC")
    {
        var evidence = store.CaptureEvidence(
            new EvidenceCaptureRequest(
                EvidenceMetadataContract.ContractVersion,
                "TASK-115",
                "backend-worker-01",
                "EVENT-IPC-EVIDENCE",
                "ipc-integration-test",
                "redacted://ipc/evidence.bin",
                BaseUtc,
                BaseUtc.AddMilliseconds(100),
                BaseUtc.AddDays(30),
                CreateManagedCopy: false),
            Path.Combine(directory.Path, "missing-ipc-evidence.bin"));
        var evidenceId = evidence.StoredEvidence.Metadata.EvidenceIdentitySha256;
        store.RegisterComplianceReviewIncident(new ComplianceReviewIncidentRegistration(
            ComplianceReviewWorkflowContract.ContractVersion,
            incidentId,
            "TASK-115",
            "backend-worker-01",
            BaseUtc.AddMinutes(2),
            [evidenceId]));
        return evidenceId;
    }

    private static string Hash(string value) => Convert.ToHexString(
        SHA256.HashData(Encoding.UTF8.GetBytes(value)));

}
