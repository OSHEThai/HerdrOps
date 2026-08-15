using HerdrOps.Contracts.SelfReport;
using HerdrOps.Contracts;
using HerdrOps.Contracts.StateIpc;
using HerdrOps.Core;
using HerdrOps.Domain.Assignments;
using HerdrOps.Infrastructure.Herdr;
using HerdrOps.Infrastructure.StateIpc;
using HerdrOps.Infrastructure.Storage;

namespace HerdrOps.IntegrationTests;

[TestClass]
public sealed class AssignmentLifecycleIngestionCoordinatorTests
{
    private static readonly DateTimeOffset BaseUtc = new(
        2026,
        8,
        15,
        3,
        0,
        0,
        TimeSpan.Zero);

    [TestMethod]
    public void DurableAcceptanceRestartsWithExactIdentityAndContinuesSequence()
    {
        var directory = CreateTemporaryDirectory();
        var databasePath = Path.Combine(directory, "herdrops.db");
        var submissions = CompleteRuntimeAcceptanceCorpus();
        try
        {
            IReadOnlyList<HerdrOpsAcceptedSelfReport> firstAccepted;
            AssignmentLifecycleReplayResult firstReplay;
            using (var store = new SqliteHerdrStateStore(new HerdrStateStoreOptions(databasePath)))
            {
                var coordinator = new AssignmentLifecycleIngestionCoordinator(store);
                var acceptance = CreateAcceptance(coordinator);
                foreach (var submission in submissions)
                {
                    var result = acceptance.Accept(
                        submission,
                        GuidFor(1000 + acceptance.LastSequence + 1));
                    Assert.IsTrue(result.Accepted, result.Message);
                }

                firstAccepted = acceptance.AcceptedEvents;
                firstReplay = coordinator.Snapshot();
                Assert.AreEqual(submissions.Count, acceptance.LastSequence);
                Assert.AreEqual(1, firstReplay.Diagnostics.OrphanEventCount);
                Assert.AreEqual(1, firstReplay.Diagnostics.InvalidTransitionCount);
                Assert.AreEqual(
                    AssignmentTaskStatus.Acknowledged,
                    firstReplay.CurrentTasks.Single().State.Status);
                Assert.AreEqual(
                    "reviewer-terminal",
                    firstReplay.CurrentTasks.Single().State.CurrentAssigneeId);
            }

            using var restartedStore = new SqliteHerdrStateStore(
                new HerdrStateStoreOptions(databasePath));
            var restartedCoordinator = new AssignmentLifecycleIngestionCoordinator(restartedStore);
            var restartedAcceptance = CreateAcceptance(restartedCoordinator);
            var retry = restartedAcceptance.Accept(submissions[0], GuidFor(3000));

            Assert.IsTrue(retry.Accepted);
            Assert.AreEqual(HerdrOpsSelfReportProtocol.ResultCodes.AcceptedIdempotent, retry.Code);
            Assert.AreEqual(firstAccepted[0].Sequence, retry.Sequence);
            Assert.AreEqual(firstAccepted[0].AcceptedUtc, retry.AcceptedUtc);
            Assert.AreEqual(firstAccepted[0].EventSha256, retry.EventSha256);
            Assert.AreEqual(submissions.Count, restartedAcceptance.LastSequence);
            Assert.AreEqual(firstReplay.ResultSha256, restartedCoordinator.Snapshot().ResultSha256);
        }
        finally
        {
            Directory.Delete(directory, recursive: true);
        }
    }

    [TestMethod]
    public void FailedDurableCommitDoesNotAdvanceAcceptanceIdentity()
    {
        var acceptance = new HerdrOpsSelfReportAcceptanceService(
            new InMemoryHerdrOpsTaskRegistry(["TASK-115"]),
            new FixedTimeProvider(BaseUtc.AddHours(1)),
            acceptanceCommit: _ => throw new IOException("injected durable failure"));

        Assert.ThrowsExactly<IOException>(() => acceptance.Accept(
            CompleteRuntimeAcceptanceCorpus()[1],
            GuidFor(4000)));
        Assert.AreEqual(0L, acceptance.LastSequence);
        Assert.IsEmpty(acceptance.AcceptedEvents);
    }

    [TestMethod]
    public void RuntimeAcceptanceRequiresExactFourAgentIdentityAndRoleBindings()
    {
        var acceptance = new HerdrOpsSelfReportAcceptanceService(
            new InMemoryHerdrOpsTaskRegistry(["TASK-115", "TASK-404"]),
            new FixedTimeProvider(BaseUtc.AddHours(1)));
        foreach (var submission in CompleteRuntimeAcceptanceCorpus())
        {
            Assert.IsTrue(acceptance.Accept(
                submission,
                GuidFor(5000 + acceptance.LastSequence + 1)).Accepted);
        }

        var replay = AssignmentLifecycleReplay.Run(acceptance.AcceptedEvents
            .Select(HerdrOpsAssignmentLifecycleMapper.Map)
            .ToArray());
        var agents = new[]
        {
            new AssignmentRuntimeAgentIdentity("pm-terminal", "Project Manager"),
            new AssignmentRuntimeAgentIdentity("leader-terminal", "Backend Leader"),
            new AssignmentRuntimeAgentIdentity("worker-terminal", "Backend Worker"),
            new AssignmentRuntimeAgentIdentity("reviewer-terminal", "Reviewer"),
        };

        var accepted = AssignmentLifecycleRuntimeAcceptance.Analyze(
            replay,
            agents,
            "TASK-115");
        var roleMismatch = AssignmentLifecycleRuntimeAcceptance.Analyze(
            replay,
            agents.Select(item => item.AgentId == "reviewer-terminal"
                    ? item with { AgentRole = "Worker" }
                    : item)
                .ToArray(),
            "TASK-115");

        Assert.IsTrue(accepted.Passed);
        Assert.IsTrue(accepted.CompleteLifecyclePassed);
        Assert.IsTrue(accepted.RoleDistinctAgentsPassed);
        Assert.IsTrue(accepted.OrphanDetectionPassed);
        Assert.IsTrue(accepted.MismatchDetectionPassed);
        Assert.IsFalse(roleMismatch.Passed);
        Assert.IsFalse(roleMismatch.RoleDistinctAgentsPassed);
        Assert.IsFalse(roleMismatch.Checks.Single(item =>
            item.CheckId == "exact-role-distinct-running-agents").Passed);
    }

    [TestMethod]
    public void ProductCommandBindsDurableLifecycleToOverlappingHerdrRuntime()
    {
        var directory = CreateTemporaryDirectory();
        try
        {
            var lifecycleTrace = CreateLifecycleTrace();
            var state = CreateRuntimeAgentState(reviewerRole: "Reviewer");
            var runtimeReport = CreateRuntimeReport(state);
            var lifecyclePath = Path.Combine(directory, "lifecycle.json");
            var runtimePath = Path.Combine(directory, "runtime.json");
            var reportPath = Path.Combine(directory, "acceptance.json");
            File.WriteAllText(
                lifecyclePath,
                HerdrOpsSelfReportJson.Serialize(lifecycleTrace));
            File.WriteAllText(
                runtimePath,
                System.Text.Json.JsonSerializer.Serialize(
                    runtimeReport,
                    new System.Text.Json.JsonSerializerOptions
                    {
                        WriteIndented = true,
                        Converters =
                        {
                            new System.Text.Json.Serialization.JsonStringEnumConverter(),
                        },
                    }));
            using var output = new StringWriter();
            using var error = new StringWriter();

            var exitCode = AssignmentLifecycleRuntimeAcceptanceCommand.Run(
                [
                    "assignment-lifecycle-acceptance",
                    "--lifecycle-trace",
                    lifecyclePath,
                    "--herdr-runtime-report",
                    runtimePath,
                    "--task-id",
                    "TASK-115",
                    "--report",
                    reportPath,
                ],
                output,
                error);

            Assert.AreEqual(0, exitCode, error.ToString());
            Assert.AreEqual(string.Empty, error.ToString());
            var report = System.Text.Json.JsonSerializer.Deserialize<
                AssignmentLifecycleCompositeRuntimeReport>(
                File.ReadAllText(reportPath),
                new System.Text.Json.JsonSerializerOptions
                {
                    PropertyNameCaseInsensitive = true,
                });
            Assert.IsNotNull(report);
            Assert.IsTrue(report.RuntimeAccepted);
            Assert.AreEqual(EvidenceClass.Runtime.ToString(), report.EvidenceClassification);
            Assert.IsTrue(report.Acceptance.Passed);
        }
        finally
        {
            Directory.Delete(directory, recursive: true);
        }
    }

    [TestMethod]
    public void ProductCommandRejectsRuntimeReportThatClaimsSessionControl()
    {
        var directory = CreateTemporaryDirectory();
        try
        {
            var lifecyclePath = Path.Combine(directory, "lifecycle.json");
            var runtimePath = Path.Combine(directory, "runtime.json");
            var reportPath = Path.Combine(directory, "acceptance.json");
            File.WriteAllText(
                lifecyclePath,
                HerdrOpsSelfReportJson.Serialize(CreateLifecycleTrace()));
            File.WriteAllText(
                runtimePath,
                System.Text.Json.JsonSerializer.Serialize(
                    CreateRuntimeReport(CreateRuntimeAgentState("Reviewer")) with
                    {
                        SessionControlInvoked = true,
                    },
                    new System.Text.Json.JsonSerializerOptions
                    {
                        WriteIndented = true,
                        Converters =
                        {
                            new System.Text.Json.Serialization.JsonStringEnumConverter(),
                        },
                    }));
            using var output = new StringWriter();
            using var error = new StringWriter();

            var exitCode = AssignmentLifecycleRuntimeAcceptanceCommand.Run(
                [
                    "assignment-lifecycle-acceptance",
                    "--lifecycle-trace", lifecyclePath,
                    "--herdr-runtime-report", runtimePath,
                    "--task-id", "TASK-115",
                    "--report", reportPath,
                ],
                output,
                error);

            Assert.AreEqual(2, exitCode);
            StringAssert.Contains(error.ToString(), "invoked session control");
            Assert.IsFalse(File.Exists(reportPath));
        }
        finally
        {
            Directory.Delete(directory, recursive: true);
        }
    }

    [TestMethod]
    public void ProductCommandRejectsAcceptedLedgerThatDoesNotReproduceReplay()
    {
        var directory = CreateTemporaryDirectory();
        try
        {
            var lifecycleTrace = CreateLifecycleTrace();
            lifecycleTrace = lifecycleTrace with
            {
                AcceptedEvents = lifecycleTrace.AcceptedEvents.Skip(1).ToArray(),
            };
            var lifecyclePath = Path.Combine(directory, "lifecycle.json");
            var runtimePath = Path.Combine(directory, "runtime.json");
            var reportPath = Path.Combine(directory, "acceptance.json");
            File.WriteAllText(
                lifecyclePath,
                HerdrOpsSelfReportJson.Serialize(lifecycleTrace));
            File.WriteAllText(
                runtimePath,
                System.Text.Json.JsonSerializer.Serialize(
                    CreateRuntimeReport(CreateRuntimeAgentState("Reviewer")),
                    new System.Text.Json.JsonSerializerOptions
                    {
                        WriteIndented = true,
                        Converters =
                        {
                            new System.Text.Json.Serialization.JsonStringEnumConverter(),
                        },
                    }));
            using var output = new StringWriter();
            using var error = new StringWriter();

            var exitCode = AssignmentLifecycleRuntimeAcceptanceCommand.Run(
                [
                    "assignment-lifecycle-acceptance",
                    "--lifecycle-trace", lifecyclePath,
                    "--herdr-runtime-report", runtimePath,
                    "--task-id", "TASK-115",
                    "--report", reportPath,
                ],
                output,
                error);

            Assert.AreEqual(2, exitCode);
            StringAssert.Contains(error.ToString(), "does not reproduce");
            Assert.IsFalse(File.Exists(reportPath));
        }
        finally
        {
            Directory.Delete(directory, recursive: true);
        }
    }

    private static HerdrOpsSelfReportAcceptanceService CreateAcceptance(
        AssignmentLifecycleIngestionCoordinator coordinator) => new(
        new InMemoryHerdrOpsTaskRegistry(["TASK-115", "TASK-404"]),
        new FixedTimeProvider(BaseUtc.AddHours(1)),
        restoredAcceptedEvents: coordinator.RestoredAcceptedEvents,
        acceptanceCommit: accepted => coordinator.Commit(accepted));

    private static HerdrOpsSelfReportAcceptanceTrace CreateLifecycleTrace()
    {
        var acceptance = new HerdrOpsSelfReportAcceptanceService(
            new InMemoryHerdrOpsTaskRegistry(["TASK-115", "TASK-404"]),
            new FixedTimeProvider(BaseUtc.AddHours(1)));
        foreach (var submission in CompleteRuntimeAcceptanceCorpus())
        {
            Assert.IsTrue(acceptance.Accept(
                submission,
                GuidFor(6000 + acceptance.LastSequence + 1)).Accepted);
        }

        var replay = AssignmentLifecycleReplay.Run(acceptance.AcceptedEvents
            .Select(HerdrOpsAssignmentLifecycleMapper.Map)
            .ToArray());
        var graph = AssignmentDelegationGraphProjector.Create(replay);
        return new HerdrOpsSelfReportAcceptanceTrace(
            EvidenceClass.Runtime.ToString(),
            HerdrOpsSelfReportProtocol.Version,
            HerdrOpsSelfReportProtocol.AuthorizationScope,
            "test-self-report-pipe",
            BaseUtc.AddMinutes(59),
            BaseUtc.AddMinutes(61),
            ["TASK-115", "TASK-404"],
            acceptance.AcceptedEvents,
            acceptance.LastSequence,
            DurableLifecycleEnabled: true,
            replay,
            graph.GraphSha256,
            new HerdrStateStoreDiagnostics(
                2,
                "wal",
                2,
                true,
                "ok",
                1,
                replay.Steps.Count,
                replay.CurrentTasks.Count,
                replay.Relationships.Count,
                replay.Diagnostics.OrphanEventCount,
                replay.Diagnostics.DuplicateHandoffCount,
                null),
            "Contract-backed test trace.");
    }

    private static HerdrSessionStateContract CreateRuntimeAgentState(string reviewerRole)
    {
        var identities = new[]
        {
            (Id: "pm-terminal", Role: "Project Manager"),
            (Id: "leader-terminal", Role: "Backend Leader"),
            (Id: "worker-terminal", Role: "Backend Worker"),
            (Id: "reviewer-terminal", Role: reviewerRole),
        };
        var panes = identities.Select((identity, index) => new HerdrPaneStateContract(
            $"pane-{index + 1}",
            identity.Id,
            "workspace-1",
            "tab-1",
            index == 0,
            "Working",
            checked((ulong)(40 + index)),
            "codex",
            "Codex",
            identity.Role,
            "Z:\\HerdrOps",
            "Z:\\HerdrOps",
            "Codex")).ToArray();
        var agents = identities.Select((identity, index) => new HerdrAgentStateContract(
            identity.Id,
            "workspace-1",
            "tab-1",
            panes[index].PaneId,
            index == 0,
            "Working",
            panes[index].Revision,
            panes[index].Revision,
            "codex",
            "Codex",
            identity.Id,
            identity.Role,
            "Z:\\HerdrOps",
            "Z:\\HerdrOps",
            "Codex",
            true,
            false,
            false)).ToArray();
        return HerdrSessionStateContractReducer.NormalizeAndValidate(new HerdrSessionStateContract(
            "0.8.0-preview",
            19,
            2,
            42,
            [new("workspace-1", 1, "HerdrOps", true, 4, 1, "tab-1", "Working")],
            [new("tab-1", "workspace-1", 1, "Acceptance", true, 4, "Working")],
            panes,
            agents,
            "workspace-1",
            "tab-1",
            "pane-1"));
    }

    private static HerdrCoreRuntimeEvidenceReport CreateRuntimeReport(
        HerdrSessionStateContract state)
    {
        var executableHash = Hash("herdr-executable");
        var endpoint = HerdrPipeEndpoint.FromSocketPath("test-herdr-pipe");
        var admission = new HerdrRuntimeAdmission(
            "C:\\Program Files\\Herdr\\herdr.exe",
            "0.8.0-preview",
            executableHash,
            "herdr-terminal-api",
            19,
            "herdr-schema",
            19,
            Hash("herdr-schema"),
            19,
            endpoint);
        var serverIdentity = new HerdrServerProcessIdentity(
            1234,
            BaseUtc.AddMinutes(58),
            admission.ExecutablePath,
            executableHash);
        var domainState = HerdrSessionStateContractMapper.ToDomain(state);
        var monitor = new HerdrRuntimeMonitorSnapshot(
            HerdrRuntimeMonitorStatus.Connected,
            domainState,
            serverIdentity,
            1,
            1,
            0,
            0,
            "contract-backed test",
            BaseUtc.AddMinutes(61));
        return new HerdrCoreRuntimeEvidenceReport(
            EvidenceClass.Runtime.ToString(),
            RuntimeObserved: true,
            SessionControlInvoked: false,
            SnapshotObserved: true,
            EventObserved: true,
            ReconnectObserved: false,
            BaseUtc.AddMinutes(59),
            BaseUtc.AddMinutes(61),
            120,
            Environment.MachineName,
            Environment.OSVersion.VersionString,
            admission,
            monitor,
            state,
            HerdrOpsStateIpcJson.ComputeSha256(state),
            [],
            "Contract-backed test report.");
    }

    private static IReadOnlyList<HerdrOpsSelfReportSubmission> CompleteRuntimeAcceptanceCorpus()
    {
        var orphanId = GuidFor(1);
        var assignmentId = GuidFor(2);
        var leaderAcknowledgementId = GuidFor(3);
        var delegationId = GuidFor(4);
        var workerAcknowledgementId = GuidFor(5);
        var progressId = GuidFor(6);
        var evidenceId = GuidFor(7);
        var handoffId = GuidFor(8);
        var reviewerAcknowledgementId = GuidFor(9);
        return
        [
            Submission(
                HerdrOpsSelfReportProtocol.EventTypes.Acknowledgement,
                orphanId,
                "TASK-404",
                "orphan-terminal",
                "Worker",
                "An orphan acknowledgement must remain visible.",
                GuidFor(900)),
            Submission(
                HerdrOpsSelfReportProtocol.EventTypes.Assignment,
                assignmentId,
                "TASK-115",
                "pm-terminal",
                "Project Manager",
                "Assign the implementation to the Backend Leader.",
                parentEventId: null,
                targetAgentId: "leader-terminal"),
            Submission(
                HerdrOpsSelfReportProtocol.EventTypes.Acknowledgement,
                leaderAcknowledgementId,
                "TASK-115",
                "leader-terminal",
                "Backend Leader",
                "The Backend Leader acknowledged the task.",
                assignmentId),
            Submission(
                HerdrOpsSelfReportProtocol.EventTypes.Delegation,
                delegationId,
                "TASK-115",
                "leader-terminal",
                "Backend Leader",
                "Delegate implementation to the Backend Worker.",
                leaderAcknowledgementId,
                targetAgentId: "worker-terminal"),
            Submission(
                HerdrOpsSelfReportProtocol.EventTypes.Acknowledgement,
                workerAcknowledgementId,
                "TASK-115",
                "worker-terminal",
                "Backend Worker",
                "The Backend Worker acknowledged the delegated task.",
                delegationId),
            Submission(
                HerdrOpsSelfReportProtocol.EventTypes.Progress,
                progressId,
                "TASK-115",
                "worker-terminal",
                "Backend Worker",
                "Implementation reached one hundred percent.",
                workerAcknowledgementId,
                progressPercent: 100),
            Submission(
                HerdrOpsSelfReportProtocol.EventTypes.Evidence,
                evidenceId,
                "TASK-115",
                "worker-terminal",
                "Backend Worker",
                "Submit the verification result.",
                progressId,
                evidenceReference: "artifacts/tests/runtime-lifecycle.trx",
                evidenceSha256: Hash("runtime-lifecycle.trx")),
            Submission(
                HerdrOpsSelfReportProtocol.EventTypes.Handoff,
                handoffId,
                "TASK-115",
                "worker-terminal",
                "Backend Worker",
                "Hand off the completed work for review.",
                evidenceId,
                targetAgentId: "reviewer-terminal",
                handoffNote: "Implementation and evidence are ready for review."),
            Submission(
                HerdrOpsSelfReportProtocol.EventTypes.Acknowledgement,
                reviewerAcknowledgementId,
                "TASK-115",
                "reviewer-terminal",
                "Reviewer",
                "The Reviewer acknowledged the handoff.",
                handoffId),
            Submission(
                HerdrOpsSelfReportProtocol.EventTypes.Progress,
                GuidFor(10),
                "TASK-115",
                "wrong-terminal",
                "Worker",
                "A mismatched actor attempted to update review progress.",
                reviewerAcknowledgementId,
                progressPercent: 100),
        ];
    }

    private static HerdrOpsSelfReportSubmission Submission(
        string eventType,
        Guid eventId,
        string taskId,
        string actorId,
        string actorRole,
        string summary,
        Guid? parentEventId,
        string? targetAgentId = null,
        int? progressPercent = null,
        string? evidenceReference = null,
        string? evidenceSha256 = null,
        string? handoffNote = null) => new(
        HerdrOpsSelfReportProtocol.Version,
        eventId,
        eventType,
        taskId,
        actorId,
        actorRole,
        BaseUtc.AddSeconds(int.Parse(eventId.ToString("N")[^12..])),
        summary,
        parentEventId,
        targetAgentId,
        progressPercent,
        DeviationReason: null,
        evidenceReference,
        evidenceSha256,
        handoffNote);

    private static string CreateTemporaryDirectory()
    {
        var path = Path.Combine(
            Path.GetTempPath(),
            "HerdrOps.IntegrationTests",
            Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(path);
        return path;
    }

    private static Guid GuidFor(long value) => Guid.Parse(
        $"00000000-0000-0000-0000-{value:000000000000}");

    private static string Hash(string value) => Convert.ToHexString(
        System.Security.Cryptography.SHA256.HashData(
            System.Text.Encoding.UTF8.GetBytes(value)));

    private sealed class FixedTimeProvider(DateTimeOffset utcNow) : TimeProvider
    {
        public override DateTimeOffset GetUtcNow() => utcNow;
    }
}
