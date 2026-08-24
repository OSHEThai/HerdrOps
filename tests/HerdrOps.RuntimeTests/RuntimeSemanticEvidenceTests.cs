using System.Globalization;
using System.IO;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using HerdrOps.App.Live;
using HerdrOps.App.Localization;
using HerdrOps.App.RuntimeEvidence;
using HerdrOps.App.StateIpc;
using HerdrOps.Contracts.StateIpc;

namespace HerdrOps.RuntimeTests;

[TestClass]
public sealed class RuntimeSemanticEvidenceTests
{
    private static readonly DateTimeOffset BaseUtc =
        DateTimeOffset.Parse("2026-08-22T14:00:00Z", CultureInfo.InvariantCulture);

    [TestMethod]
    public void SemanticCaptureProjectsLiveViewsWithoutLeakingSourceValues()
    {
        using var fixture = new VisualFixture();
        WpfTestHost.Run(() =>
        {
            using var dashboard = CreateDashboard(CreateState(10, "Blocked"), UiLanguage.Thai);
            var runtimeCaptures = CreateInitialRuntimeCaptures(
                fixture, dashboard.CurrentState, BaseUtc, "Thai", "th-TH");
            var capture = RuntimeEvidenceRunner.BuildSemanticStateCapture(
                1, "initial", "InitialLiveState",
                runtimeCaptures.Select(CreateBinding).ToArray(),
                BaseUtc.AddSeconds(1), dashboard);

            Assert.AreEqual(2, capture.Overview.TotalAgents);
            Assert.AreEqual(1, capture.Overview.StatusCounts.Single(item =>
                item.Status == "Blocked").Count);
            Assert.AreEqual(1, capture.LiveOrganization.UnassignedPaneCount);
            Assert.AreEqual(5, capture.LiveOrganization.ProjectedNodeCount);
            Assert.IsTrue(capture.AgentDetail.AgentSelected);
            Assert.AreEqual("Blocked", capture.AgentDetail.Status);
            Assert.AreEqual(RuntimeEvidenceRunner.MissingSemanticSource, capture.AgentDetail.Assignment);
            Assert.AreEqual(RuntimeEvidenceRunner.MissingSemanticSource, capture.AgentDetail.Tasks);
            Assert.AreEqual(RuntimeEvidenceRunner.MissingSemanticSource, capture.AgentDetail.Evidence);
            Assert.AreEqual(
                capture.CaptureStateSha256,
                RuntimeEvidenceRunner.ComputeSemanticCaptureSha256(capture));

            var json = JsonSerializer.Serialize(capture);
            foreach (var sensitiveValue in new[]
                     {
                         "terminal-sensitive-1", "Agent Sensitive Name",
                         "Z:\\Sensitive\\Customer", "Workspace Sensitive", "Tab Sensitive",
                     })
            {
                Assert.IsFalse(json.Contains(sensitiveValue, StringComparison.Ordinal));
            }
        });
    }

    [TestMethod]
    public void SemanticCaptureValidationRejectsVisualProjectionAndTimeTampering()
    {
        using var fixture = new VisualFixture();
        WpfTestHost.Run(() =>
        {
            var matrix = CreateMatrix(fixture);
            AssertMatrixValid(matrix);

            var originalBytes = File.ReadAllBytes(matrix.RuntimeCaptures[0].Path);
            File.WriteAllBytes(matrix.RuntimeCaptures[0].Path, [1, 2, 3, 4]);
            AssertMatrixInvalid(matrix);
            File.WriteAllBytes(matrix.RuntimeCaptures[0].Path, originalBytes);
            AssertMatrixValid(matrix);

            var visualTampered = matrix.SemanticCaptures.ToArray();
            var changedBinding = visualTampered[0].BoundCaptures[0] with
            {
                PixelWidth = visualTampered[0].BoundCaptures[0].PixelWidth + 1,
            };
            visualTampered[0] = Rehash(visualTampered[0] with
            {
                BoundCaptures = [changedBinding, .. visualTampered[0].BoundCaptures.Skip(1)],
            });
            AssertMatrixInvalid(matrix with { SemanticCaptures = visualTampered });

            var hashTampered = matrix.SemanticCaptures.ToArray();
            hashTampered[0] = Rehash(hashTampered[0] with
            {
                BoundCaptures =
                [
                    hashTampered[0].BoundCaptures[0] with
                    {
                        Sha256 = new string('F', 64),
                    },
                    .. hashTampered[0].BoundCaptures.Skip(1),
                ],
            });
            AssertMatrixInvalid(matrix with { SemanticCaptures = hashTampered });

            var languageTampered = matrix.SemanticCaptures.ToArray();
            languageTampered[1] = Rehash(languageTampered[1] with
            {
                BoundCaptures =
                [
                    languageTampered[1].BoundCaptures[0] with
                    {
                        Language = "English",
                        LanguageCultureName = "en-US",
                    },
                ],
            });
            AssertMatrixInvalid(matrix with { SemanticCaptures = languageTampered });

            var projectionTampered = matrix.SemanticCaptures.ToArray();
            projectionTampered[1] = Rehash(projectionTampered[1] with
            {
                Overview = projectionTampered[1].Overview with
                {
                    TotalAgents = projectionTampered[1].Overview.TotalAgents + 1,
                },
            });
            AssertMatrixInvalid(matrix with { SemanticCaptures = projectionTampered });

            AssertTimeTamperingRejected(matrix, 0, default);
            AssertTimeTamperingRejected(
                matrix, 1,
                new DateTimeOffset(2026, 8, 22, 21, 0, 4, TimeSpan.FromHours(7)));
            AssertTimeTamperingRejected(matrix, 1, BaseUtc.AddMilliseconds(500));
            AssertTimeTamperingRejected(matrix, 2, matrix.ValidationUtc.AddSeconds(1));

            var bindingTimeTampered = matrix.SemanticCaptures.ToArray();
            bindingTimeTampered[2] = Rehash(bindingTimeTampered[2] with
            {
                BoundCaptures =
                [
                    bindingTimeTampered[2].BoundCaptures[0] with { ObservedUtc = default },
                ],
            });
            AssertMatrixInvalid(matrix with { SemanticCaptures = bindingTimeTampered });
        });
    }

    [TestMethod]
    public void ThaiAndEnglishSemanticProjectionsAreIdenticalForOneNormalizedState()
    {
        using var fixture = new VisualFixture();
        WpfTestHost.Run(() =>
        {
            var state = CreateState(10, "Blocked");
            using var thaiDashboard = CreateDashboard(state, UiLanguage.Thai);
            var thaiVisuals = CreateInitialRuntimeCaptures(
                fixture, state, BaseUtc, "Thai", "th-TH", "thai");
            var thai = RuntimeEvidenceRunner.BuildSemanticStateCapture(
                1, "initial", "InitialLiveState",
                thaiVisuals.Select(CreateBinding).ToArray(),
                BaseUtc.AddSeconds(1), thaiDashboard);

            using var englishDashboard = CreateDashboard(state, UiLanguage.English);
            var englishVisuals = CreateInitialRuntimeCaptures(
                fixture, state, BaseUtc, "English", "en-US", "english");
            var english = RuntimeEvidenceRunner.BuildSemanticStateCapture(
                1, "initial", "InitialLiveState",
                englishVisuals.Select(CreateBinding).ToArray(),
                BaseUtc.AddSeconds(1), englishDashboard);

            Assert.AreEqual(thai.NormalizedStateSha256, english.NormalizedStateSha256);
            Assert.AreEqual(thai.SourceStateSha256, english.SourceStateSha256);
            Assert.AreEqual(thai.SemanticProjectionSha256, english.SemanticProjectionSha256);
            Assert.AreEqual(JsonSerializer.Serialize(thai.Overview), JsonSerializer.Serialize(english.Overview));
            Assert.AreEqual(JsonSerializer.Serialize(thai.LiveOrganization), JsonSerializer.Serialize(english.LiveOrganization));
            Assert.AreEqual(JsonSerializer.Serialize(thai.AgentDetail), JsonSerializer.Serialize(english.AgentDetail));
            Assert.AreNotEqual(thai.CaptureStateSha256, english.CaptureStateSha256);
        });
    }

    private static EvidenceMatrix CreateMatrix(VisualFixture fixture)
    {
        using var dashboard = CreateDashboard(CreateState(10, "Blocked"), UiLanguage.Thai);
        var initialRuntime = CreateInitialRuntimeCaptures(
            fixture, dashboard.CurrentState, BaseUtc, "Thai", "th-TH");
        var initial = RuntimeEvidenceRunner.BuildSemanticStateCapture(
            1, "initial", "InitialLiveState",
            initialRuntime.Select(CreateBinding).ToArray(),
            BaseUtc.AddSeconds(1), dashboard);

        var preCloseState = CreateState(11, "Idle");
        ApplySnapshot(dashboard, preCloseState);
        var eventARuntime = fixture.CreateCapture(
            "dashboard-overview-after-event.png", preCloseState,
            BaseUtc.AddMilliseconds(3_100), "Thai", "th-TH");
        var eventA = RuntimeEvidenceRunner.BuildSemanticStateCapture(
            2, "event-a-pre-close", "EventA", [CreateBinding(eventARuntime)],
            BaseUtc.AddSeconds(4), dashboard);

        var postCloseState = CreateState(12, "Working");
        ApplySnapshot(dashboard, postCloseState);
        var eventBRuntime = fixture.CreateCapture(
            "widget-floating-vertical-after-dashboard-close.png", postCloseState,
            BaseUtc.AddMilliseconds(6_100), "Thai", "th-TH");
        var eventB = RuntimeEvidenceRunner.BuildSemanticStateCapture(
            3, "post-close-final", "EventB", [CreateBinding(eventBRuntime)],
            BaseUtc.AddSeconds(7), dashboard);

        return new EvidenceMatrix(
            [initial, eventA, eventB],
            [.. initialRuntime, eventARuntime, eventBRuntime],
            CreateEventEvidence(eventA.Sequence, eventA.NormalizedStateSha256,
                BaseUtc.AddSeconds(2), BaseUtc.AddSeconds(3)),
            CreateEventEvidence(eventB.Sequence, eventB.NormalizedStateSha256,
                BaseUtc.AddSeconds(5), BaseUtc.AddSeconds(6)),
            BaseUtc.AddSeconds(8));
    }

    private static bool ValidateMatrix(EvidenceMatrix matrix) =>
        RuntimeEvidenceRunner.AreSemanticStateCapturesBound(
            matrix.SemanticCaptures, matrix.RuntimeCaptures,
            matrix.SemanticCaptures[0].Sequence,
            matrix.SemanticCaptures[0].NormalizedStateSha256,
            matrix.EventA,
            matrix.SemanticCaptures[1].Sequence,
            matrix.SemanticCaptures[1].NormalizedStateSha256,
            matrix.EventB,
            matrix.SemanticCaptures[2].Sequence,
            matrix.SemanticCaptures[2].NormalizedStateSha256,
            matrix.ValidationUtc);

    private static void AssertMatrixValid(EvidenceMatrix matrix) => Assert.IsTrue(ValidateMatrix(matrix));

    private static void AssertMatrixInvalid(EvidenceMatrix matrix) => Assert.IsFalse(ValidateMatrix(matrix));

    private static void AssertTimeTamperingRejected(
        EvidenceMatrix matrix, int index, DateTimeOffset observedUtc)
    {
        var changed = matrix.SemanticCaptures.ToArray();
        changed[index] = Rehash(changed[index] with { ObservedUtc = observedUtc });
        AssertMatrixInvalid(matrix with { SemanticCaptures = changed });
    }

    private static RuntimeSemanticStateCapture Rehash(RuntimeSemanticStateCapture capture)
    {
        var withoutHash = capture with { CaptureStateSha256 = string.Empty };
        return withoutHash with
        {
            CaptureStateSha256 = RuntimeEvidenceRunner.ComputeSemanticCaptureSha256(withoutHash),
        };
    }

    private static IReadOnlyList<RuntimeEvidenceCapture> CreateInitialRuntimeCaptures(
        VisualFixture fixture, HerdrSessionStateContract state,
        DateTimeOffset startedUtc, string language, string culture,
        string prefix = "")
    {
        var names = new[]
        {
            "dashboard-overview.png", "dashboard-live-organization.png",
            "dashboard-agent-detail.png", "widget-compact.png", "widget-normal.png",
            "widget-floating-vertical.png",
        };
        return names.Select((name, index) => fixture.CreateCapture(
            name, state, startedUtc.AddMilliseconds(100 + index * 100),
            language, culture, prefix)).ToArray();
    }

    private static RuntimeSemanticVisualBinding CreateBinding(RuntimeEvidenceCapture capture) =>
        new(
            Path.GetFileName(capture.Path), capture.Sha256,
            capture.PixelWidth, capture.PixelHeight,
            capture.StateSequence, capture.StateSha256,
            capture.Language, capture.LanguageCultureName, capture.ObservedUtc);

    private static LiveDashboardState CreateDashboard(
        HerdrSessionStateContract state, UiLanguage language)
    {
        UiLanguageService.Shared.SetLanguage(language);
        CultureInfo.CurrentUICulture = CultureInfo.GetCultureInfo(
            language == UiLanguage.Thai ? "th-TH" : "en-US");
        var dashboard = new LiveDashboardState();
        ApplySnapshot(dashboard, state);
        return dashboard;
    }

    private static HerdrSessionStateContract CreateState(long sequence, string primaryStatus) =>
        HerdrSessionStateContractReducer.NormalizeAndValidate(new HerdrSessionStateContract(
            "0.8.2-preview", 19, 2, sequence,
            [new("workspace-sensitive", 1, "Workspace Sensitive", true, 3, 1, "tab-sensitive", primaryStatus)],
            [new("tab-sensitive", "workspace-sensitive", 1, "Tab Sensitive", true, 3, primaryStatus)],
            [
                new("pane-sensitive-1", "terminal-sensitive-1", "workspace-sensitive", "tab-sensitive", true, primaryStatus, 8, "codex", "Codex", "Sensitive title", "Z:\\Sensitive\\Customer", "Z:\\Sensitive\\Customer", "Sensitive terminal title"),
                new("pane-sensitive-2", "terminal-sensitive-2", "workspace-sensitive", "tab-sensitive", false, "Unknown", 3, "claude", "Claude", "Reviewer", "Z:\\Sensitive\\Customer", null, "Claude"),
                new("pane-unassigned", "terminal-unassigned", "workspace-sensitive", "tab-sensitive", false, "Unknown", 1, null, null, null, null, null, null),
            ],
            [
                new("terminal-sensitive-1", "workspace-sensitive", "tab-sensitive", "pane-sensitive-1", true, primaryStatus, 8, 8, "codex", "Codex", "Agent Sensitive Name", "Sensitive title", "Z:\\Sensitive\\Customer", "Z:\\Sensitive\\Customer", "Sensitive terminal title", true, false, false),
                new("terminal-sensitive-2", "workspace-sensitive", "tab-sensitive", "pane-sensitive-2", false, "Unknown", 3, 3, "claude", "Claude", "Reviewer Sensitive", "Reviewer", "Z:\\Sensitive\\Customer", null, "Claude", null, null, null),
            ],
            "workspace-sensitive", "tab-sensitive", "pane-sensitive-1"));

    private static void ApplySnapshot(LiveDashboardState dashboard, HerdrSessionStateContract state)
    {
        var acceptedUtc = BaseUtc.AddSeconds(state.LastIngestSequence);
        var health = new HerdrRuntimeHealthContract(
            "Connected", acceptedUtc, acceptedUtc, 1, state.LastIngestSequence, 0, 0);
        var payload = new HerdrOpsStateSnapshotPayload(
            state, HerdrOpsStateIpcJson.ComputeSha256(state), health);
        var envelope = HerdrOpsStateIpcJson.CreateEnvelope(
            HerdrOpsStateIpcProtocol.MessageTypes.Snapshot,
            state.LastIngestSequence, acceptedUtc,
            HerdrOpsStateIpcProtocol.CoreSource, Guid.NewGuid(), payload);
        dashboard.ApplyUpdate(
            new HerdrOpsStateUpdate(
                HerdrOpsStateUpdateKind.Snapshot, state, envelope, payload, null, health),
            acceptedUtc.AddMilliseconds(5));
    }

    private static RuntimeAgentStatusTransitionEvidence CreateEventEvidence(
        long sequence, string stateSha256,
        DateTimeOffset phaseEnteredUtc, DateTimeOffset observedUtc) =>
        new(
            phaseEnteredUtc, observedUtc,
            "pane.agent_status_changed", RuntimeEvidenceRunner.DirectEventAdmissionPath,
            2, true, true, "Connected",
            sequence - 1, sequence, sequence - 1, sequence,
            1, 1, 0, 0, 0, 1,
            new string('A', 64), stateSha256,
            new string('B', 64), new string('B', 64),
            new string('C', 64), new string('D', 64), 2, []);

    private sealed record EvidenceMatrix(
        IReadOnlyList<RuntimeSemanticStateCapture> SemanticCaptures,
        IReadOnlyList<RuntimeEvidenceCapture> RuntimeCaptures,
        RuntimeAgentStatusTransitionEvidence EventA,
        RuntimeAgentStatusTransitionEvidence EventB,
        DateTimeOffset ValidationUtc);

    private sealed class VisualFixture : IDisposable
    {
        private readonly string _root = Path.Combine(
            Path.GetTempPath(), $"herdrops-semantic-{Guid.NewGuid():N}");

        internal VisualFixture() => Directory.CreateDirectory(_root);

        internal RuntimeEvidenceCapture CreateCapture(
            string fileName, HerdrSessionStateContract state,
            DateTimeOffset observedUtc, string language, string culture,
            string prefix = "")
        {
            var directory = Path.Combine(_root, string.IsNullOrEmpty(prefix) ? "default" : prefix);
            Directory.CreateDirectory(directory);
            var path = Path.Combine(directory, fileName);
            var bytes = Encoding.UTF8.GetBytes(
                $"semantic-visual|{prefix}|{fileName}|{state.LastIngestSequence}");
            File.WriteAllBytes(path, bytes);
            return new RuntimeEvidenceCapture(
                Path.GetFileNameWithoutExtension(fileName), path,
                Convert.ToHexString(SHA256.HashData(bytes)),
                100, 50, state.LastIngestSequence,
                HerdrOpsStateIpcJson.ComputeSha256(state),
                language, culture, observedUtc);
        }

        public void Dispose() => Directory.Delete(_root, recursive: true);
    }
}
