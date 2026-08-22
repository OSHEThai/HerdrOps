using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using HerdrOps.Contracts;
using HerdrOps.Contracts.ReviewIpc;
using HerdrOps.Contracts.StateIpc;
using HerdrOps.Core;
using HerdrOps.Domain.Compliance;
using HerdrOps.Domain.Herdr;
using HerdrOps.Infrastructure.Herdr;
using HerdrOps.Infrastructure.StateIpc;
using HerdrOps.Infrastructure.Storage;

namespace HerdrOps.IntegrationTests;

[TestClass]
public sealed class ComplianceReviewRuntimeAcceptanceCommandTests
{
    private static readonly DateTimeOffset BaseTime =
        new(2026, 8, 16, 12, 0, 0, TimeSpan.Zero);

    [TestMethod]
    public void UsageAndArgumentValidationFailClosed()
    {
        var output = new StringWriter();
        var error = new StringWriter();

        var code1 = ComplianceReviewRuntimeAcceptanceCommand.Run(
            Array.Empty<string>(),
            output,
            error);
        Assert.AreEqual(64, code1);

        var code2 = ComplianceReviewRuntimeAcceptanceCommand.Run(
            new[] { "compliance-review-acceptance", "--unknown-opt", "val" },
            output,
            error);
        Assert.AreEqual(64, code2);

        var code3 = ComplianceReviewRuntimeAcceptanceCommand.Run(
            new[] { "compliance-review-acceptance", "--incident-id", "INC-01" },
            output,
            error);
        Assert.AreEqual(64, code3);
    }

    [TestMethod]
    public void MissingOrInvalidPathsReturnExitCodeTwo()
    {
        var output = new StringWriter();
        var error = new StringWriter();

        var exitCodeMissingFile = ComplianceReviewRuntimeAcceptanceCommand.Run(
            new[]
            {
                "compliance-review-acceptance",
                "--review-trace", "Z:\\non-existent\\review-trace.json",
                "--herdr-runtime-report", "Z:\\non-existent\\herdr-runtime.json",
                "--incident-id", "INC-01",
                "--report", "Z:\\non-existent\\report.json",
            },
            output,
            error);

        Assert.AreEqual(2, exitCodeMissingFile);
        Assert.Contains("Compliance review runtime acceptance failed:", error.ToString());

        output.GetStringBuilder().Clear();
        error.GetStringBuilder().Clear();

        var tooLongPath = "Z:\\" + new string('A', 500) + "\\report.json";
        var exitCodeTooLong = ComplianceReviewRuntimeAcceptanceCommand.Run(
            new[]
            {
                "compliance-review-acceptance",
                "--review-trace", tooLongPath,
                "--herdr-runtime-report", "Z:\\non-existent\\herdr-runtime.json",
                "--incident-id", "INC-01",
                "--report", "Z:\\non-existent\\report.json",
            },
            output,
            error);

        Assert.AreEqual(2, exitCodeTooLong);
        Assert.Contains("Compliance review runtime acceptance failed:", error.ToString());
    }

    [TestMethod]
    public void SyntheticBuiltProcessTraceProducesCompositeReport()
    {
        using var directory = new TemporaryDirectory();
        const string incidentId = "INC-28-SYNTHETIC";
        const string taskId = "TASK-28-SYNTHETIC";
        var result = RunValidAcceptance(directory.Path, incidentId, taskId);

        Assert.AreEqual(0, result.ExitCode);
        Assert.IsNotNull(result.Composite);

        Assert.IsTrue(result.Composite!.RuntimeAccepted);
        Assert.AreEqual("Runtime", result.Composite.EvidenceClassification);
        Assert.IsTrue(result.Composite.Acceptance.Passed);
        Assert.AreEqual(incidentId, result.Composite.IncidentId);
        Assert.AreEqual(Path.GetFullPath(result.ReviewTracePath), result.Composite.ReviewTracePath);
        Assert.AreEqual(Path.GetFullPath(result.HerdrReportPath), result.Composite.HerdrRuntimeReportPath);
    }

    [TestMethod]
    public void MissingEventObservationFailsClosedWithoutRuntimeCredit()
    {
        using var directory = new TemporaryDirectory();
        var result = RunValidAcceptance(
            directory.Path,
            "INC-28-NO-EVENT",
            "TASK-28-NO-EVENT",
            eventObserved: false);

        Assert.AreEqual(2, result.ExitCode);
        Assert.IsNotNull(result.Composite);
        Assert.IsFalse(result.Composite!.RuntimeAccepted);
        Assert.AreEqual("NoRuntimeCredit", result.Composite.EvidenceClassification);
    }

    [TestMethod]
    public void EventFlagWithoutAcceptedTransitionFailsClosedWithoutRuntimeCredit()
    {
        using var directory = new TemporaryDirectory();
        var result = RunValidAcceptance(
            directory.Path,
            "INC-28-NO-ACCEPTED-TRANSITION",
            "TASK-28-NO-ACCEPTED-TRANSITION",
            transitions: Array.Empty<HerdrRuntimeTraceTransition>());

        Assert.AreEqual(2, result.ExitCode);
        Assert.IsNotNull(result.Composite);
        Assert.IsFalse(result.Composite!.RuntimeAccepted);
        Assert.AreEqual("NoRuntimeCredit", result.Composite.EvidenceClassification);
    }

    [TestMethod]
    public void MissingReconnectObservationFailsClosedWithoutRuntimeCredit()
    {
        using var directory = new TemporaryDirectory();
        var result = RunValidAcceptance(
            directory.Path,
            "INC-28-NO-RECONNECT",
            "TASK-28-NO-RECONNECT",
            reconnectObserved: false);

        Assert.AreEqual(2, result.ExitCode);
        Assert.IsNotNull(result.Composite);
        Assert.IsFalse(result.Composite!.RuntimeAccepted);
        Assert.AreEqual("NoRuntimeCredit", result.Composite.EvidenceClassification);
    }

    private static (
        int ExitCode,
        string ReviewTracePath,
        string HerdrReportPath,
        ComplianceReviewCompositeRuntimeReport? Composite) RunValidAcceptance(
        string directoryPath,
        string incidentId,
        string taskId,
        bool eventObserved = true,
        bool reconnectObserved = true,
        IReadOnlyList<HerdrRuntimeTraceTransition>? transitions = null)
    {
        const string subjectId = "worker-terminal";
        const string pmId = "pm-terminal";
        var reviewTracePath = Path.Combine(directoryPath, "review-trace.json");
        var herdrReportPath = Path.Combine(directoryPath, "herdr-runtime.json");
        var compositeReportPath = Path.Combine(directoryPath, "composite-report.json");

        var incident = ComplianceReviewWorkflowContract.CreateIncident(
            new ComplianceReviewIncidentRegistration(
                1,
                incidentId,
                taskId,
                subjectId,
                BaseTime,
                Array.Empty<string>()));

        var cmd = new ComplianceReviewCommand(
            1,
            Guid.NewGuid(),
            incidentId,
            ComplianceReviewState.Suspected,
            0,
            pmId,
            ComplianceReviewDecisionKind.Confirm,
            "Confirmed synthetic incident.",
            BaseTime.AddSeconds(1),
            Array.Empty<string>());

        var authority = new ComplianceReviewAuthority(
            pmId,
            ComplianceReviewerRole.ProjectManager,
            Guid.NewGuid(),
            1,
            BaseTime,
            new string('A', 64));

        var auditEvent = ComplianceReviewWorkflowContract.CreateAuditEvent(
            incident,
            cmd,
            authority);
        var appliedIncident = ComplianceReviewWorkflowContract.Apply(
            incident,
            auditEvent);
        var reviewTrace = CreateTraceReport(
            new[] { appliedIncident },
            new[] { auditEvent },
            retentionProtectedObserved: true,
            restartConsistencyObserved: true);
        File.WriteAllText(
            reviewTracePath,
            JsonSerializer.Serialize(reviewTrace, new JsonSerializerOptions { WriteIndented = true }));

        var herdrReport = CreateRuntimeReport(
            CreateSessionState(),
            eventObserved: eventObserved,
            reconnectObserved: reconnectObserved,
            transitions: transitions);
        File.WriteAllText(
            herdrReportPath,
            JsonSerializer.Serialize(herdrReport, new JsonSerializerOptions { WriteIndented = true }));

        var output = new StringWriter();
        var error = new StringWriter();
        var exitCode = ComplianceReviewRuntimeAcceptanceCommand.Run(
            new[]
            {
                "compliance-review-acceptance",
                "--review-trace", reviewTracePath,
                "--herdr-runtime-report", herdrReportPath,
                "--incident-id", incidentId,
                "--report", compositeReportPath,
            },
            output,
            error);

        ComplianceReviewCompositeRuntimeReport? composite = null;
        if (File.Exists(compositeReportPath))
        {
            composite = JsonSerializer.Deserialize<ComplianceReviewCompositeRuntimeReport>(
                File.ReadAllText(compositeReportPath),
                new JsonSerializerOptions { PropertyNameCaseInsensitive = true });
        }

        return (exitCode, reviewTracePath, herdrReportPath, composite);
    }

    [TestMethod]
    public void CorruptedTraceOrMissingInputsReturnExitCodeTwo()
    {
        using var directory = new TemporaryDirectory();
        const string incidentId = "INC-28-CORRUPT";
        const string taskId = "TASK-28-CORRUPT";
        const string subjectId = "worker-terminal";
        const string pmId = "pm-terminal";

        var reviewTracePath = Path.Combine(directory.Path, "review-trace-corrupt.json");
        var herdrReportPath = Path.Combine(directory.Path, "herdr-runtime.json");
        var compositeReportPath = Path.Combine(directory.Path, "composite-report-fail.json");

        var incident = ComplianceReviewWorkflowContract.CreateIncident(
            new ComplianceReviewIncidentRegistration(
                1,
                incidentId,
                taskId,
                subjectId,
                BaseTime,
                Array.Empty<string>()));

        // Tampered audit event with invalid sequence
        var badAudit = new ComplianceReviewAuditEvent(
            1,
            Guid.NewGuid(),
            incidentId,
            taskId,
            subjectId,
            999,
            pmId,
            ComplianceReviewerRole.ProjectManager,
            Guid.NewGuid(),
            1,
            new string('A', 64),
            ComplianceReviewDecisionKind.Confirm,
            ComplianceReviewState.Suspected,
            ComplianceReviewState.Confirmed,
            "Tampered reason.",
            BaseTime.AddSeconds(1),
            Array.Empty<string>(),
            new string('B', 64),
            null,
            new string('C', 64));

        var reviewTrace = CreateTraceReport(new[] { incident }, new[] { badAudit }, true, true);

        File.WriteAllText(
            reviewTracePath,
            JsonSerializer.Serialize(reviewTrace, new JsonSerializerOptions { WriteIndented = true }));

        var sessionContract = CreateSessionState();
        var herdrReport = CreateRuntimeReport(sessionContract);

        File.WriteAllText(
            herdrReportPath,
            JsonSerializer.Serialize(herdrReport, new JsonSerializerOptions { WriteIndented = true }));

        var output = new StringWriter();
        var error = new StringWriter();

        var exitCode = ComplianceReviewRuntimeAcceptanceCommand.Run(
            new[]
            {
                "compliance-review-acceptance",
                "--review-trace", reviewTracePath,
                "--herdr-runtime-report", herdrReportPath,
                "--incident-id", incidentId,
                "--report", compositeReportPath,
            },
            output,
            error);

        Assert.AreEqual(2, exitCode);
        Assert.IsTrue(File.Exists(compositeReportPath));

        var composite = JsonSerializer.Deserialize<ComplianceReviewCompositeRuntimeReport>(
            File.ReadAllText(compositeReportPath),
            new JsonSerializerOptions { PropertyNameCaseInsensitive = true });

        Assert.IsNotNull(composite);
        Assert.IsFalse(composite.RuntimeAccepted);
        Assert.AreEqual("NoRuntimeCredit", composite.EvidenceClassification);
    }

    [TestMethod]
    public void NonRuntimeEvidenceClassificationReturnsExitCodeTwo()
    {
        using var directory = new TemporaryDirectory();
        const string incidentId = "INC-28-SYNTH-CLASS";
        const string taskId = "TASK-28-SYNTH-CLASS";
        const string subjectId = "worker-terminal";
        const string pmId = "pm-terminal";

        var reviewTracePath = Path.Combine(directory.Path, "review-trace.json");
        var herdrReportPath = Path.Combine(directory.Path, "herdr-runtime.json");
        var compositeReportPath = Path.Combine(directory.Path, "composite-report-fail.json");

        var incident = ComplianceReviewWorkflowContract.CreateIncident(
            new ComplianceReviewIncidentRegistration(
                1,
                incidentId,
                taskId,
                subjectId,
                BaseTime,
                Array.Empty<string>()));

        var cmd = new ComplianceReviewCommand(
            1,
            Guid.NewGuid(),
            incidentId,
            ComplianceReviewState.Suspected,
            0,
            pmId,
            ComplianceReviewDecisionKind.Confirm,
            "Confirmed.",
            BaseTime.AddSeconds(1),
            Array.Empty<string>());

        var authority = new ComplianceReviewAuthority(
            pmId,
            ComplianceReviewerRole.ProjectManager,
            Guid.NewGuid(),
            1,
            BaseTime,
            new string('A', 64));

        var auditEvent = ComplianceReviewWorkflowContract.CreateAuditEvent(
            incident,
            cmd,
            authority);

        var appliedIncident = ComplianceReviewWorkflowContract.Apply(
            incident,
            auditEvent);

        var reviewTrace = CreateTraceReport(new[] { appliedIncident }, new[] { auditEvent }, true, true);

        File.WriteAllText(
            reviewTracePath,
            JsonSerializer.Serialize(reviewTrace, new JsonSerializerOptions { WriteIndented = true }));

        var sessionContract = CreateSessionState();
        var herdrReport = CreateRuntimeReport(sessionContract, evidenceClassification: "Synthetic");

        File.WriteAllText(
            herdrReportPath,
            JsonSerializer.Serialize(herdrReport, new JsonSerializerOptions { WriteIndented = true }));

        var output = new StringWriter();
        var error = new StringWriter();

        var exitCode = ComplianceReviewRuntimeAcceptanceCommand.Run(
            new[]
            {
                "compliance-review-acceptance",
                "--review-trace", reviewTracePath,
                "--herdr-runtime-report", herdrReportPath,
                "--incident-id", incidentId,
                "--report", compositeReportPath,
            },
            output,
            error);

        Assert.AreEqual(2, exitCode);
        Assert.IsTrue(File.Exists(compositeReportPath));

        var composite = JsonSerializer.Deserialize<ComplianceReviewCompositeRuntimeReport>(
            File.ReadAllText(compositeReportPath),
            new JsonSerializerOptions { PropertyNameCaseInsensitive = true });

        Assert.IsNotNull(composite);
        Assert.IsFalse(composite.RuntimeAccepted);
        Assert.AreEqual("NoRuntimeCredit", composite.EvidenceClassification);
    }

    [TestMethod]
    public void LockedOrAccessDeniedInputReturnsExitCodeTwo()
    {
        using var directory = new TemporaryDirectory();
        var reviewTracePath = Path.Combine(directory.Path, "review-trace.json");
        var herdrReportPath = Path.Combine(directory.Path, "herdr-runtime.json");
        var compositeReportPath = Path.Combine(directory.Path, "composite-report.json");

        File.WriteAllText(reviewTracePath, "{}");
        File.WriteAllText(herdrReportPath, "{}");

        using var fileLock = new FileStream(
            reviewTracePath,
            FileMode.Open,
            FileAccess.ReadWrite,
            FileShare.None);

        var output = new StringWriter();
        var error = new StringWriter();

        var exitCode = ComplianceReviewRuntimeAcceptanceCommand.Run(
            new[]
            {
                "compliance-review-acceptance",
                "--review-trace", reviewTracePath,
                "--herdr-runtime-report", herdrReportPath,
                "--incident-id", "INC-LOCK",
                "--report", compositeReportPath,
            },
            output,
            error);

        Assert.AreEqual(2, exitCode);
        Assert.Contains("Compliance review runtime acceptance failed:", error.ToString());
    }

    [TestMethod]
    public void RegisteredStoreProducerToAcceptorSharesExactReportBytes()
    {
        using var directory = new TemporaryDirectory();
        const string incidentId = "INC-28-E2E";
        const string taskId = "TASK-28-E2E";
        const string subjectId = "worker-terminal";

        var dbPath = Path.Combine(directory.Path, "store.db");
        var reportPath = Path.Combine(directory.Path, "producer-report.json");
        var herdrReportPath = Path.Combine(directory.Path, "herdr-runtime.json");
        var compositeReportPath = Path.Combine(directory.Path, "composite-report.json");

        using (var store = new SqliteHerdrStateStore(new HerdrStateStoreOptions(dbPath)))
        {
            var result = store.RegisterComplianceReviewIncident(
                new ComplianceReviewIncidentRegistration(
                    1,
                    incidentId,
                    taskId,
                    subjectId,
                    BaseTime,
                    Array.Empty<string>()));
            Assert.IsFalse(result.WasAlreadyPresent);
            Assert.AreEqual(incidentId, result.Incident.IncidentId);
        }

        var producerOutput = new StringWriter();
        var producerError = new StringWriter();
        var producerExit = ComplianceReviewRuntimeTraceCommand.Run(
            new[]
            {
                "trace-compliance-review",
                "--database", dbPath,
                "--report", reportPath,
            },
            producerOutput,
            producerError);
        Assert.AreEqual(0, producerExit, producerError.ToString());
        Assert.AreEqual(string.Empty, producerError.ToString());
        Assert.IsTrue(File.Exists(reportPath));

        var producerBytes = File.ReadAllBytes(reportPath);
        var report = JsonSerializer.Deserialize<ComplianceReviewRuntimeTraceReport>(
            producerBytes,
            new JsonSerializerOptions { PropertyNameCaseInsensitive = true });
        Assert.IsNotNull(report);
        Assert.AreEqual(1, report.IncidentCount);
        Assert.IsTrue(report.DurableReviewEnabled);
        Assert.IsTrue(report.RestartConsistencyObserved);
        Assert.IsFalse(report.RetentionProtectedObserved);
        Assert.IsTrue(
            report.StartedUtc <= BaseTime,
            "trace start must be bounded by the earliest durable event, not the produce timestamp");

        var herdrReport = CreateRuntimeReport(CreateSessionState());
        File.WriteAllText(
            herdrReportPath,
            JsonSerializer.Serialize(herdrReport, new JsonSerializerOptions { WriteIndented = true }));

        var acceptorOutput = new StringWriter();
        var acceptorError = new StringWriter();
        var acceptorExit = ComplianceReviewRuntimeAcceptanceCommand.Run(
            new[]
            {
                "compliance-review-acceptance",
                "--review-trace", reportPath,
                "--herdr-runtime-report", herdrReportPath,
                "--incident-id", incidentId,
                "--report", compositeReportPath,
            },
            acceptorOutput,
            acceptorError);

        Assert.IsTrue(File.Exists(compositeReportPath));
        var composite = JsonSerializer.Deserialize<ComplianceReviewCompositeRuntimeReport>(
            File.ReadAllText(compositeReportPath),
            new JsonSerializerOptions { PropertyNameCaseInsensitive = true });
        Assert.IsNotNull(composite);
        Assert.AreEqual(incidentId, composite.IncidentId);
        Assert.AreEqual("NoRuntimeCredit", composite.EvidenceClassification);
        Assert.IsFalse(composite.RuntimeAccepted);
        Assert.AreNotEqual(64, acceptorExit);
    }

    private static HerdrSessionStateContract CreateSessionState()
    {
        var identities = new[]
        {
            (Id: "pm-terminal", Role: "Project Manager"),
            (Id: "leader-terminal", Role: "Backend Leader"),
            (Id: "worker-terminal", Role: "Worker"),
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
            [new("workspace-1", 1, "HerdrOps", true, 3, 1, "tab-1", "Working")],
            [new("tab-1", "workspace-1", 1, "Acceptance", true, 3, "Working")],
            panes,
            agents,
            "workspace-1",
            "tab-1",
            "pane-1"));
    }

    private static HerdrCoreRuntimeEvidenceReport CreateRuntimeReport(
        HerdrSessionStateContract state,
        string? evidenceClassification = null,
        bool eventObserved = true,
        bool reconnectObserved = true,
        IReadOnlyList<HerdrRuntimeTraceTransition>? transitions = null)
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
            BaseTime.AddMinutes(-2),
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
            BaseTime.AddSeconds(5));
        var acceptedEventTransition = HerdrRuntimeEvidence.CreateTransition(monitor with
        {
            AcceptedEventKind = HerdrRuntimeMonitor.AcceptedAgentStatusEventKind,
            AcceptedAgentStatusEvent = new HerdrAcceptedAgentStatusEvent(
                "workspace-1",
                "pane-1",
                HerdrAgentStatus.Working,
                "codex",
                "Codex",
                "Working"),
        });
        return new HerdrCoreRuntimeEvidenceReport(
            evidenceClassification ?? EvidenceClass.Runtime.ToString(),
            RuntimeObserved: true,
            SessionControlInvoked: false,
            SnapshotObserved: true,
            EventObserved: eventObserved,
            ReconnectObserved: reconnectObserved,
            BaseTime,
            BaseTime.AddSeconds(10),
            120,
            Environment.MachineName,
            Environment.OSVersion.VersionString,
            admission,
            monitor,
            state,
            HerdrOpsStateIpcJson.ComputeSha256(state),
            transitions ?? new[] { acceptedEventTransition },
            "Contract-backed test report.");
    }

    private static ComplianceReviewRuntimeTraceReport CreateTraceReport(
        IReadOnlyList<ComplianceReviewIncident> incidents,
        IReadOnlyList<ComplianceReviewAuditEvent> auditEvents,
        bool retentionProtectedObserved,
        bool restartConsistencyObserved) =>
        new(
            ContractVersion: 1,
            EvidenceClassification: "BuiltProcessIntegration",
            RuntimeObserved: false,
            SessionControlInvoked: false,
            RestartObserved: false,
            ReconnectObserved: false,
            DurableReviewEnabled: true,
            RetentionProtectedObserved: retentionProtectedObserved,
            RestartConsistencyObserved: restartConsistencyObserved,
            DatabasePath: "C:\\data\\herdrops.db",
            DatabaseFileSha256: new string('1', 64),
            DatabaseFileSizeBytes: 123456,
            SchemaVersion: 4,
            ProductAssemblySha256: new string('2', 64),
            HostName: "TEST-HOST",
            OperatingSystem: "Windows 11",
            ProducerProcessId: 4321,
            StartedUtc: BaseTime,
            FinishedUtc: BaseTime.AddSeconds(10),
            IncidentCount: incidents.Count,
            AuditEventCount: auditEvents.Count,
            EvidenceLinkCount: auditEvents.Sum(item => item.EvidenceIdentitySha256s.Count),
            Incidents: incidents.Select(MapContractIncident).ToArray(),
            AuditEvents: auditEvents.Select(MapContractAuditEvent).ToArray(),
            RetentionObservations: Array.Empty<ComplianceReviewEvidenceRetentionObservation>(),
            EvidenceBoundary: ComplianceReviewRuntimeTraceContract.EvidenceBoundaryText);

    private static HerdrOpsComplianceReviewIncident MapContractIncident(
        ComplianceReviewIncident incident) =>
        new(
            incident.ContractVersion,
            incident.IncidentId,
            incident.TaskId,
            incident.SubjectActorId,
            incident.RegisteredUtc,
            incident.InitialEvidenceIdentitySha256s,
            incident.RegistrationSha256,
            (int)incident.State,
            incident.Sequence,
            incident.UpdatedUtc,
            incident.LastAuditEventId,
            incident.LastAuditSha256);

    private static HerdrOpsComplianceReviewAuditEvent MapContractAuditEvent(
        ComplianceReviewAuditEvent auditEvent) =>
        new(
            auditEvent.ContractVersion,
            auditEvent.AuditEventId,
            auditEvent.IncidentId,
            auditEvent.TaskId,
            auditEvent.SubjectActorId,
            auditEvent.Sequence,
            auditEvent.ReviewerActorId,
            (int)auditEvent.ReviewerRole,
            auditEvent.AuthorityProvenanceEventId,
            auditEvent.AuthorityProvenanceSequence,
            auditEvent.AuthorityProvenanceSha256,
            (int)auditEvent.DecisionKind,
            (int)auditEvent.PreviousState,
            (int)auditEvent.ResultState,
            auditEvent.Reason,
            auditEvent.OccurredUtc,
            auditEvent.EvidenceIdentitySha256s,
            auditEvent.EvidenceSetSha256,
            auditEvent.PreviousAuditSha256,
            auditEvent.AuditSha256);

    private static string Hash(string value) => Convert.ToHexString(
        SHA256.HashData(Encoding.UTF8.GetBytes(value)));
}
