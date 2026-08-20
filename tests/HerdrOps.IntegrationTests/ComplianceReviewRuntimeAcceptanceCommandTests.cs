using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using HerdrOps.Contracts;
using HerdrOps.Contracts.StateIpc;
using HerdrOps.Core;
using HerdrOps.Domain.Compliance;
using HerdrOps.Domain.Herdr;
using HerdrOps.Infrastructure.Herdr;
using HerdrOps.Infrastructure.StateIpc;

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
    public void SyntheticBuiltProcessTraceProducesCompositeReport()
    {
        using var directory = new TemporaryDirectory();
        const string incidentId = "INC-28-SYNTHETIC";
        const string taskId = "TASK-28-SYNTHETIC";
        const string subjectId = "worker-terminal";
        const string pmId = "pm-terminal";

        var reviewTracePath = Path.Combine(directory.Path, "review-trace.json");
        var herdrReportPath = Path.Combine(directory.Path, "herdr-runtime.json");
        var compositeReportPath = Path.Combine(directory.Path, "composite-report.json");

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

        var reviewTrace = new ComplianceReviewRuntimeTrace(
            ContractVersion: 1,
            StartedUtc: BaseTime,
            FinishedUtc: BaseTime.AddSeconds(10),
            EvidenceClassification: "BuiltProcessIntegration",
            DurableReviewEnabled: true,
            AuditEvents: new[] { auditEvent },
            Incidents: new[] { appliedIncident },
            RetentionProtectedObserved: true,
            RestartConsistencyObserved: true);

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

        Assert.AreEqual(0, exitCode);
        Assert.IsTrue(File.Exists(compositeReportPath));

        var composite = JsonSerializer.Deserialize<ComplianceReviewCompositeRuntimeReport>(
            File.ReadAllText(compositeReportPath),
            new JsonSerializerOptions { PropertyNameCaseInsensitive = true });

        Assert.IsNotNull(composite);
        Assert.IsTrue(composite.RuntimeAccepted);
        Assert.AreEqual("Runtime", composite.EvidenceClassification);
        Assert.IsTrue(composite.Acceptance.Passed);
        Assert.AreEqual(incidentId, composite.IncidentId);
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

        var reviewTrace = new ComplianceReviewRuntimeTrace(
            ContractVersion: 1,
            StartedUtc: BaseTime,
            FinishedUtc: BaseTime.AddSeconds(10),
            EvidenceClassification: "BuiltProcessIntegration",
            DurableReviewEnabled: true,
            AuditEvents: new[] { badAudit },
            Incidents: new[] { incident },
            RetentionProtectedObserved: true,
            RestartConsistencyObserved: true);

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
        return new HerdrCoreRuntimeEvidenceReport(
            EvidenceClass.Runtime.ToString(),
            RuntimeObserved: true,
            SessionControlInvoked: false,
            SnapshotObserved: true,
            EventObserved: true,
            ReconnectObserved: false,
            BaseTime,
            BaseTime.AddSeconds(10),
            120,
            Environment.MachineName,
            Environment.OSVersion.VersionString,
            admission,
            monitor,
            state,
            HerdrOpsStateIpcJson.ComputeSha256(state),
            Array.Empty<HerdrRuntimeTraceTransition>(),
            "Contract-backed test report.");
    }

    private static string Hash(string value) => Convert.ToHexString(
        SHA256.HashData(Encoding.UTF8.GetBytes(value)));
}
