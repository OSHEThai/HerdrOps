using HerdrOps.App.Compliance;
using HerdrOps.App.Localization;
using HerdrOps.App.ReviewIpc;
using HerdrOps.Contracts;
using HerdrOps.Contracts.ReviewIpc;
using HerdrOps.Domain.Compliance;

namespace HerdrOps.IntegrationTests;

[TestClass]
[DoNotParallelize]
public sealed class ComplianceQueueStateTests
{
    private static readonly DateTimeOffset BaseUtc =
        new(2026, 8, 16, 5, 0, 0, TimeSpan.Zero);

    [TestMethod]
    public void SyntheticPreviewCoversEveryIncidentStateAndKeepsDetailEvidenceAndActionsAligned()
    {
        var language = UiLanguageService.Shared;
        try
        {
            language.SetLanguage(UiLanguage.English);
            using var state = ComplianceQueueState.CreateSyntheticPreview();

            Assert.IsTrue(state.IsSyntheticPreview);
            Assert.AreEqual(EvidenceClass.Synthetic, state.EvidenceClass);
            Assert.HasCount(9, state.VisibleIncidents);
            CollectionAssert.AreEquivalent(
                new[] { "suspected", "confirmed", "pending-leader", "pending-pm", "dismissed" },
                state.VisibleIncidents.Select(item => StateId(state, item.StateLabel)).Distinct().ToArray());
            Assert.IsNotNull(state.SelectedIncident);
            Assert.AreEqual(state.SelectedIncident?.IncidentId, state.SelectedDetail?.IncidentId);
            Assert.IsNotNull(state.SelectedDetail);
            Assert.IsNotEmpty(state.SelectedDetail!.EvidenceItems);
            Assert.HasCount(4, state.ReviewActions);
            StringAssert.Contains(state.ConnectionLabel, "not evidence from a running Herdr instance");
        }
        finally
        {
            language.SetLanguage(UiLanguage.Thai);
        }
    }

    [TestMethod]
    public async Task SyntheticReviewActionsRejectDirectExecutionWithoutIpc()
    {
        using var state = ComplianceQueueState.CreateSyntheticPreview();
        state.ReviewReason = "This text cannot authorize a synthetic action.";

        foreach (var action in state.ReviewActions)
        {
            Assert.IsFalse(action.IsEnabled);
            Assert.IsFalse(await state.ExecuteReviewActionAsync(action));
        }
    }

    [TestMethod]
    public async Task SameIncidentSequenceAdvanceInvalidatesLateRejectedUiResult()
    {
        using var fixture = await LiveReviewFixture.CreateAsync(
            "INC-QUEUE-SEQUENCE-RACE");
        var execution = fixture.StartReviewAsync();
        var request = await fixture.Client.Started.Task.WaitAsync(
            TimeSpan.FromSeconds(5));

        var advanced = CreateTransitionResult(
            fixture.InitialIncident,
            ComplianceReviewDecisionKind.SendToLeader,
            ComplianceReviewerRole.ProjectManager,
            "project-manager",
            Guid.Parse("11111111-1111-1111-1111-111111111111"),
            Guid.Parse("22222222-2222-2222-2222-222222222222"),
            BaseUtc.AddMinutes(2));
        fixture.StateHub.Apply(advanced.Result);
        var statusAfterAdvance = fixture.State.ReviewStatus;
        var reasonAfterAdvance = fixture.State.ReviewReason;
        fixture.Client.Complete(CreateRejectedResult(fixture.InitialIncident));

        var returned = await execution;

        Assert.IsFalse(returned);
        Assert.AreEqual(statusAfterAdvance, fixture.State.ReviewStatus);
        Assert.AreEqual(reasonAfterAdvance, fixture.State.ReviewReason);
        Assert.AreEqual(
            advanced.Incident.Sequence,
            fixture.StateHub.Read(fixture.InitialIncident.IncidentId)!.Sequence);
        Assert.IsFalse(fixture.State.IsReviewCommandPending);
        _ = request;
    }

    [TestMethod]
    public async Task SameSequenceLateRejectedResponseCannotReplaceNewerIncidentAfterGenerationAdvance()
    {
        using var fixture = await LiveReviewFixture.CreateAsync(
            "INC-QUEUE-SAME-SEQUENCE-RACE");
        var execution = fixture.StartReviewAsync();
        var request = await fixture.Client.Started.Task.WaitAsync(
            TimeSpan.FromSeconds(5));

        var newer = CreateTransitionResult(
            fixture.InitialIncident,
            ComplianceReviewDecisionKind.SendToLeader,
            ComplianceReviewerRole.ProjectManager,
            "project-manager",
            Guid.Parse("12121212-1212-1212-1212-121212121212"),
            Guid.Parse("23232323-2323-2323-2323-232323232323"),
            BaseUtc.AddMinutes(2));
        fixture.StateHub.Apply(newer.Result);
        var authoritative = fixture.StateHub.Read(fixture.InitialIncident.IncidentId)!;

        var staleSameSequence = CreateTransitionResult(
            fixture.InitialIncident,
            ComplianceReviewDecisionKind.Dismiss,
            ComplianceReviewerRole.ProjectManager,
            "project-manager",
            Guid.Parse("34343434-3434-3434-3434-343434343434"),
            Guid.Parse("45454545-4545-4545-4545-454545454545"),
            BaseUtc.AddMinutes(3));
        fixture.Client.Complete(CreateRejectedResult(staleSameSequence.Incident));

        var returned = await execution;
        var current = fixture.StateHub.Read(fixture.InitialIncident.IncidentId)!;

        Assert.IsFalse(returned);
        Assert.AreEqual(authoritative.Sequence, current.Sequence);
        Assert.AreEqual(authoritative.State, current.State);
        Assert.AreEqual(authoritative.UpdatedUtc, current.UpdatedUtc);
        Assert.AreEqual(authoritative.LastAuditEventId, current.LastAuditEventId);
        Assert.AreEqual(authoritative.LastAuditSha256, current.LastAuditSha256);
        Assert.IsFalse(fixture.State.IsReviewCommandPending);
        _ = request;
    }

    [TestMethod]
    public async Task StaleLateAcceptedResultCannotOverwriteAdvancedSameIncidentUiState()
    {
        using var fixture = await LiveReviewFixture.CreateAsync(
            "INC-QUEUE-ACCEPTED-RACE");
        var execution = fixture.StartReviewAsync();
        var request = await fixture.Client.Started.Task.WaitAsync(
            TimeSpan.FromSeconds(5));

        var firstAdvance = CreateTransitionResult(
            fixture.InitialIncident,
            ComplianceReviewDecisionKind.SendToLeader,
            ComplianceReviewerRole.ProjectManager,
            "project-manager",
            Guid.Parse("33333333-3333-3333-3333-333333333333"),
            Guid.Parse("44444444-4444-4444-4444-444444444444"),
            BaseUtc.AddMinutes(2));
        fixture.StateHub.Apply(firstAdvance.Result);
        var secondAdvance = CreateTransitionResult(
            firstAdvance.Incident,
            ComplianceReviewDecisionKind.EscalateToProjectManager,
            ComplianceReviewerRole.Leader,
            "backend-leader",
            Guid.Parse("55555555-5555-5555-5555-555555555555"),
            Guid.Parse("66666666-6666-6666-6666-666666666666"),
            BaseUtc.AddMinutes(3));
        fixture.StateHub.Apply(secondAdvance.Result);
        var statusAfterAdvance = fixture.State.ReviewStatus;
        var reasonAfterAdvance = fixture.State.ReviewReason;

        fixture.Client.Complete(CreateAcceptedResult(fixture.InitialIncident, request));

        var returned = await execution;

        Assert.IsTrue(returned);
        Assert.AreEqual(statusAfterAdvance, fixture.State.ReviewStatus);
        Assert.AreEqual(reasonAfterAdvance, fixture.State.ReviewReason);
        Assert.AreEqual(
            secondAdvance.Incident.Sequence,
            fixture.StateHub.Read(fixture.InitialIncident.IncidentId)!.Sequence);
        Assert.IsFalse(fixture.State.IsReviewCommandPending);
    }

    [TestMethod]
    public async Task SameIncidentReplacementInvalidatesLateUiResult()
    {
        using var fixture = await LiveReviewFixture.CreateAsync(
            "INC-QUEUE-REPLACEMENT-RACE");
        var execution = fixture.StartReviewAsync();
        await fixture.Client.Started.Task.WaitAsync(TimeSpan.FromSeconds(5));

        fixture.State.ApplyAuthoritativeReviewChange(
            new ComplianceReviewStateChange(
                fixture.InitialIncident with
                {
                    UpdatedUtc = BaseUtc.AddMinutes(1),
                },
                Decision: null,
                WasAlreadyKnown: false));
        var statusAfterReplacement = fixture.State.ReviewStatus;
        var reasonAfterReplacement = fixture.State.ReviewReason;
        fixture.Client.Complete(CreateRejectedResult(fixture.InitialIncident));

        var returned = await execution;

        Assert.IsFalse(returned);
        Assert.AreEqual(statusAfterReplacement, fixture.State.ReviewStatus);
        Assert.AreEqual(reasonAfterReplacement, fixture.State.ReviewReason);
        Assert.IsFalse(fixture.State.IsReviewCommandPending);
    }

    [TestMethod]
    public async Task ConcurrentReviewActionsAreSingleFlightAndDoNotOverwritePendingState()
    {
        using var fixture = await LiveReviewFixture.CreateAsync(
            "INC-QUEUE-SINGLE-FLIGHT");
        var action = fixture.State.ReviewActions.Single(item => item.Id == "confirm");
        var firstExecution = fixture.State.ExecuteReviewActionAsync(action).AsTask();
        var firstRequest = await fixture.Client.Started.Task.WaitAsync(
            TimeSpan.FromSeconds(5));
        var pendingStatus = fixture.State.ReviewStatus;

        var secondReturned = await fixture.State.ExecuteReviewActionAsync(action);

        Assert.IsFalse(secondReturned);
        Assert.AreEqual(1, fixture.Client.ExecuteCallCount);
        Assert.IsTrue(fixture.State.IsReviewCommandPending);
        Assert.AreEqual(pendingStatus, fixture.State.ReviewStatus);

        fixture.Client.Complete(CreateAcceptedResult(fixture.InitialIncident, firstRequest));
        Assert.IsTrue(await firstExecution);
        Assert.AreEqual(1, fixture.Client.ExecuteCallCount);
        Assert.IsFalse(fixture.State.IsReviewCommandPending);
    }

    [TestMethod]
    public void LocalizedPaginationRangeTracksFilteredVisibleCount()
    {
        var language = UiLanguageService.Shared;
        try
        {
            language.SetLanguage(UiLanguage.English);
            using var state = ComplianceQueueState.CreateSyntheticPreview();

            Assert.AreEqual(
                language.Format("ComplianceQueuePageRangeFormat", 1, 9, 9),
                state.VisibleRangeLabel);

            state.SelectedSeverityFilter = state.SeverityFilters.Single(item => item.Id == "critical");
            Assert.HasCount(1, state.VisibleIncidents);
            Assert.AreEqual(
                language.Format("ComplianceQueuePageRangeFormat", 1, 1, 1),
                state.VisibleRangeLabel);

            state.SelectedTaskFilter = state.TaskFilters.Single(item => item.Id == "TASK-113");
            Assert.IsEmpty(state.VisibleIncidents);
            Assert.AreEqual(language["ComplianceQueuePageRangeEmpty"], state.VisibleRangeLabel);

            language.SetLanguage(UiLanguage.Thai);
            state.RefreshLanguage();
            Assert.AreEqual(language["ComplianceQueuePageRangeEmpty"], state.VisibleRangeLabel);
            Assert.IsTrue(state.VisibleRangeLabel.Any(character => character is >= '\u0E00' and <= '\u0E7F'));
        }
        finally
        {
            language.SetLanguage(UiLanguage.Thai);
        }
    }

    [TestMethod]
    public void SeverityAndReviewPresentationUseDedicatedSemanticBrushKeys()
    {
        var language = UiLanguageService.Shared;
        try
        {
            language.SetLanguage(UiLanguage.English);
            using var state = ComplianceQueueState.CreateSyntheticPreview();

            Assert.AreEqual(
                ComplianceQueueBrushKeys.SeverityCritical,
                state.VisibleIncidents.Single(item => item.IncidentId == "INC-2025-00073").SeverityBrushKey);
            Assert.AreEqual(
                ComplianceQueueBrushKeys.SeverityHigh,
                state.VisibleIncidents.Single(item => item.IncidentId == "INC-2025-00072").SeverityBrushKey);
            Assert.AreEqual(
                ComplianceQueueBrushKeys.SeverityMedium,
                state.VisibleIncidents.Single(item => item.IncidentId == "INC-2025-00070").SeverityBrushKey);
            Assert.AreEqual(
                ComplianceQueueBrushKeys.SeverityLow,
                state.VisibleIncidents.Single(item => item.IncidentId == "INC-2025-00066").SeverityBrushKey);

            var expectedReviewKeys = new Dictionary<string, string>(StringComparer.Ordinal)
            {
                ["suspected"] = ComplianceQueueBrushKeys.ReviewSuspected,
                ["confirmed"] = ComplianceQueueBrushKeys.ReviewConfirmed,
                ["pending-leader"] = ComplianceQueueBrushKeys.ReviewPendingLeader,
                ["pending-pm"] = ComplianceQueueBrushKeys.ReviewPendingProjectManager,
                ["dismissed"] = ComplianceQueueBrushKeys.ReviewDismissed,
            };
            foreach (var row in state.VisibleIncidents)
            {
                var stateId = StateId(state, row.StateLabel);
                Assert.AreEqual(expectedReviewKeys[stateId], row.StateBrushKey);
            }
        }
        finally
        {
            language.SetLanguage(UiLanguage.Thai);
        }
    }

    [TestMethod]
    public void EvidenceProjectionCarriesIssue25ProvenanceAndOneExplicitMissingItem()
    {
        var language = UiLanguageService.Shared;
        try
        {
            language.SetLanguage(UiLanguage.English);
            using var state = ComplianceQueueState.CreateSyntheticPreview();
            var detail = state.SelectedDetail!;
            var allEvidence = new List<ComplianceQueueEvidenceItem>();
            foreach (var row in state.VisibleIncidents)
            {
                state.SelectedIncident = row;
                allEvidence.AddRange(state.SelectedDetail!.EvidenceItems);
            }

            Assert.AreEqual(
                allEvidence.Count,
                allEvidence.Select(item => item.EvidenceId).Distinct(StringComparer.Ordinal).Count());
            state.SelectedIncident = state.VisibleIncidents.Single(item => item.IncidentId == "INC-2025-00073");
            detail = state.SelectedDetail!;

            Assert.HasCount(3, detail.EvidenceItems);
            Assert.AreEqual(
                2,
                detail.EvidenceItems.Count(item => item.Availability == ComplianceQueueEvidenceAvailability.Present));
            Assert.IsTrue(detail.EvidenceItems.All(item => item.IncidentId == detail.IncidentId));
            Assert.IsTrue(detail.EvidenceItems.All(item => item.TaskId == detail.TaskId));
            Assert.IsTrue(detail.EvidenceItems.All(item => item.Actor == detail.Actor));
            Assert.IsTrue(detail.EvidenceItems.All(item => !string.IsNullOrWhiteSpace(item.EvidenceId)));

            var present = detail.EvidenceItems.Where(item => item.Availability == ComplianceQueueEvidenceAvailability.Present).ToArray();
            Assert.IsNotEmpty(present);
            Assert.IsTrue(present.All(item => item.Sha256 is { Length: 64 }));
            Assert.IsTrue(present.All(item => !string.IsNullOrWhiteSpace(item.Reference)));
            Assert.IsTrue(present.All(item => !string.IsNullOrWhiteSpace(item.Source)));
            Assert.IsTrue(present.All(item => item.AvailabilityLabel == language["ComplianceQueueEvidenceAvailable"]));

            using var repeat = ComplianceQueueState.CreateSyntheticPreview();
            repeat.SelectedIncident = repeat.VisibleIncidents.Single(item => item.IncidentId == "INC-2025-00073");
            CollectionAssert.AreEqual(
                present.Select(item => item.Sha256).ToArray(),
                repeat.SelectedDetail!.EvidenceItems
                    .Where(item => item.Availability == ComplianceQueueEvidenceAvailability.Present)
                    .Select(item => item.Sha256)
                    .ToArray());

            var missing = detail.EvidenceItems.Single(item => item.Availability == ComplianceQueueEvidenceAvailability.Missing);
            Assert.AreEqual(language["ComplianceQueueEvidenceMissing"], missing.AvailabilityLabel);
            Assert.IsFalse(missing.IsAvailable);
            Assert.AreEqual("—", missing.FileName);
            Assert.AreEqual("—", missing.Timestamp);
            Assert.AreEqual("—", missing.Size);
            Assert.IsNull(missing.Sha256);
            Assert.IsNull(missing.Reference);
            Assert.AreEqual(detail.IncidentId, missing.IncidentId);
            Assert.AreEqual(detail.TaskId, missing.TaskId);
            Assert.AreEqual(detail.Actor, missing.Actor);

            // Real content hashes may repeat when records contain identical bytes.
            // This synthetic fixture has no bytes, so different metadata tuples
            // must remain distinguishable even when their filenames repeat.
            var repeatedFilename = allEvidence
                .Where(item => item.FileName == "UnitTest_Report_0513.xlsx")
                .ToArray();
            Assert.HasCount(2, repeatedFilename);
            Assert.AreEqual(
                2,
                repeatedFilename
                    .Select(item => item.Sha256)
                    .Distinct(StringComparer.Ordinal)
                    .Count());
        }
        finally
        {
            language.SetLanguage(UiLanguage.Thai);
        }
    }

    [TestMethod]
    public void SelectionRejectsRowsOutsideVisibleIncidentsAndFailsClosed()
    {
        var language = UiLanguageService.Shared;
        try
        {
            language.SetLanguage(UiLanguage.English);
            using var state = ComplianceQueueState.CreateSyntheticPreview();
            var outside = state.VisibleIncidents.Single(item => item.IncidentId == "INC-2025-00073");

            state.SelectedStateFilter = state.StateFilters.Single(item => item.Id == "confirmed");
            Assert.IsTrue(state.VisibleIncidents.All(item => item.IncidentId != outside.IncidentId));

            state.SelectedIncident = outside;

            Assert.IsNull(state.SelectedIncident);
            Assert.IsNull(state.SelectedDetail);
            Assert.IsEmpty(state.ReviewActions);
        }
        finally
        {
            language.SetLanguage(UiLanguage.Thai);
        }
    }

    [TestMethod]
    public void EachStateFilterReturnsOnlyItsOwnStateAndPreservesAValidSelection()
    {
        var language = UiLanguageService.Shared;
        try
        {
            language.SetLanguage(UiLanguage.English);
            using var state = ComplianceQueueState.CreateSyntheticPreview();

            foreach (var filter in state.StateFilters.Where(item => item.Id != "all"))
            {
                state.SelectedStateFilter = filter;

                Assert.IsNotEmpty(state.VisibleIncidents);
                Assert.IsTrue(state.VisibleIncidents.All(item => item.StateLabel == filter.Label));
                Assert.AreEqual(state.VisibleIncidents[0].IncidentId, state.SelectedIncident?.IncidentId);
                Assert.AreEqual(state.SelectedIncident?.IncidentId, state.SelectedDetail?.IncidentId);
            }

            state.SelectedStateFilter = state.StateFilters.Single(item => item.Id == "all");
            Assert.HasCount(9, state.VisibleIncidents);
        }
        finally
        {
            language.SetLanguage(UiLanguage.Thai);
        }
    }

    [TestMethod]
    public void SeverityActorTaskAndReviewerFiltersComposeDeterministically()
    {
        var language = UiLanguageService.Shared;
        try
        {
            language.SetLanguage(UiLanguage.English);
            using var state = ComplianceQueueState.CreateSyntheticPreview();

            ResetFilters(state);
            state.SelectedSeverityFilter = state.SeverityFilters.Single(item => item.Id == "critical");
            Assert.HasCount(1, state.VisibleIncidents);
            Assert.IsTrue(state.VisibleIncidents.All(item => item.SeverityLabel == state.SelectedSeverityFilter.Label));

            ResetFilters(state);
            state.SelectedActorFilter = state.ActorFilters.Single(item => item.Id == "Test Worker");
            Assert.HasCount(2, state.VisibleIncidents);
            Assert.IsTrue(state.VisibleIncidents.All(item => item.Actor == "Test Worker"));

            ResetFilters(state);
            state.SelectedTaskFilter = state.TaskFilters.Single(item => item.Id == "TASK-115");
            Assert.HasCount(1, state.VisibleIncidents);
            Assert.AreEqual("TASK-115", state.VisibleIncidents[0].TaskId);

            ResetFilters(state);
            state.SelectedReviewerFilter = state.ReviewerFilters.Single(item => item.Id == "Backend Leader");
            Assert.HasCount(4, state.VisibleIncidents);
            Assert.IsTrue(state.VisibleIncidents.All(item => item.Reviewer == "Backend Leader"));

            ResetFilters(state);
            state.SelectedStateFilter = state.StateFilters.Single(item => item.Id == "pending-pm");
            state.SelectedActorFilter = state.ActorFilters.Single(item => item.Id == "DevOps Worker");
            state.SelectedTaskFilter = state.TaskFilters.Single(item => item.Id == "TASK-78");
            state.SelectedReviewerFilter = state.ReviewerFilters.Single(item => item.Id == "Project Manager");
            state.SelectedSeverityFilter = state.SeverityFilters.Single(item => item.Id == "medium");

            Assert.HasCount(1, state.VisibleIncidents);
            Assert.AreEqual("INC-2025-00070", state.VisibleIncidents[0].IncidentId);
            Assert.AreEqual(state.VisibleIncidents[0].IncidentId, state.SelectedDetail?.IncidentId);
        }
        finally
        {
            language.SetLanguage(UiLanguage.Thai);
        }
    }

    [TestMethod]
    public void FilterAndSortSettersUseCurrentCatalogAndRejectUnknownIds()
    {
        var language = UiLanguageService.Shared;
        try
        {
            language.SetLanguage(UiLanguage.English);
            using var state = ComplianceQueueState.CreateSyntheticPreview();

            var severity = state.SeverityFilters.Single(item => item.Id == "critical");
            state.SelectedSeverityFilter = new(severity.Id, "spoofed label");
            Assert.AreSame(severity, state.SelectedSeverityFilter);
            Assert.Throws<ArgumentException>(() =>
                state.SelectedSeverityFilter = new("unknown-severity", "Unknown"));
            Assert.AreSame(severity, state.SelectedSeverityFilter);

            var incidentState = state.StateFilters.Single(item => item.Id == "confirmed");
            state.SelectedStateFilter = new(incidentState.Id, "spoofed label");
            Assert.AreSame(incidentState, state.SelectedStateFilter);
            Assert.Throws<ArgumentException>(() =>
                state.SelectedStateFilter = new("unknown-state", "Unknown"));
            Assert.AreSame(incidentState, state.SelectedStateFilter);

            var actor = state.ActorFilters.Skip(1).First();
            state.SelectedActorFilter = new(actor.Id, "spoofed label");
            Assert.AreSame(actor, state.SelectedActorFilter);
            Assert.Throws<ArgumentException>(() =>
                state.SelectedActorFilter = new("unknown-actor", "Unknown"));
            Assert.AreSame(actor, state.SelectedActorFilter);

            var task = state.TaskFilters.Skip(1).First();
            state.SelectedTaskFilter = new(task.Id, "spoofed label");
            Assert.AreSame(task, state.SelectedTaskFilter);
            Assert.Throws<ArgumentException>(() =>
                state.SelectedTaskFilter = new("unknown-task", "Unknown"));
            Assert.AreSame(task, state.SelectedTaskFilter);

            var reviewer = state.ReviewerFilters.Skip(1).First();
            state.SelectedReviewerFilter = new(reviewer.Id, "spoofed label");
            Assert.AreSame(reviewer, state.SelectedReviewerFilter);
            Assert.Throws<ArgumentException>(() =>
                state.SelectedReviewerFilter = new("unknown-reviewer", "Unknown"));
            Assert.AreSame(reviewer, state.SelectedReviewerFilter);

            var sort = state.SortOptions.Single(item => item.Id == "oldest");
            state.SelectedSortOption = new(sort.Id, "spoofed label");
            Assert.AreSame(sort, state.SelectedSortOption);
            Assert.Throws<ArgumentException>(() =>
                state.SelectedSortOption = new("unknown-sort", "Unknown"));
            Assert.AreSame(sort, state.SelectedSortOption);
        }
        finally
        {
            language.SetLanguage(UiLanguage.Thai);
        }
    }

    [TestMethod]
    public void ComposedFiltersWithNoResultsClearIncidentDetailEvidenceAndActions()
    {
        var language = UiLanguageService.Shared;
        try
        {
            language.SetLanguage(UiLanguage.English);
            using var state = ComplianceQueueState.CreateSyntheticPreview();

            state.SelectedSeverityFilter = state.SeverityFilters.Single(item => item.Id == "critical");
            state.SelectedStateFilter = state.StateFilters.Single(item => item.Id == "confirmed");
            state.SelectedActorFilter = state.ActorFilters.Single(item => item.Id == "Test Worker");
            state.SelectedTaskFilter = state.TaskFilters.Single(item => item.Id == "TASK-115");
            state.SelectedReviewerFilter = state.ReviewerFilters.Single(item => item.Id == "Backend Leader");

            Assert.IsEmpty(state.VisibleIncidents);
            Assert.IsNull(state.SelectedIncident);
            Assert.IsNull(state.SelectedDetail);
            Assert.IsEmpty(state.ReviewActions);
        }
        finally
        {
            language.SetLanguage(UiLanguage.Thai);
        }
    }

    [TestMethod]
    public void DefaultSortUsesSeverityThenNewestAndAlternativeSortsRemainStable()
    {
        var language = UiLanguageService.Shared;
        try
        {
            language.SetLanguage(UiLanguage.English);
            using var first = ComplianceQueueState.CreateSyntheticPreview();
            using var second = ComplianceQueueState.CreateSyntheticPreview();

            CollectionAssert.AreEqual(
                first.VisibleIncidents.Select(item => item.IncidentId).ToArray(),
                second.VisibleIncidents.Select(item => item.IncidentId).ToArray());
            Assert.IsTrue(IsSeverityThenNewest(first.VisibleIncidents));

            first.SelectedSortOption = first.SortOptions.Single(item => item.Id == "newest");
            Assert.IsTrue(IsNewestFirst(first.VisibleIncidents));

            first.SelectedSortOption = first.SortOptions.Single(item => item.Id == "oldest");
            Assert.IsTrue(IsOldestFirst(first.VisibleIncidents));
        }
        finally
        {
            language.SetLanguage(UiLanguage.Thai);
        }
    }

    [TestMethod]
    public void EqualSeverityAndEqualObservedTimeUseIncidentIdAsStableTieBreaker()
    {
        var language = UiLanguageService.Shared;
        try
        {
            language.SetLanguage(UiLanguage.English);
            using var state = ComplianceQueueState.CreateSyntheticPreview();
            var tieTime = state.VisibleIncidents.Single(item => item.IncidentId == "INC-2025-00072").ObservedAt;
            var expected = new[] { "INC-2025-00072", "INC-2025-00074" };

            foreach (var sortId in new[] { "severity", "newest", "oldest" })
            {
                state.SelectedSortOption = state.SortOptions.Single(item => item.Id == sortId);
                var tie = state.VisibleIncidents
                    .Where(item => item.SeverityRank == 3 && item.ObservedAt == tieTime)
                    .Select(item => item.IncidentId)
                    .ToArray();

                CollectionAssert.AreEqual(expected, tie);
            }
        }
        finally
        {
            language.SetLanguage(UiLanguage.Thai);
        }
    }

    [TestMethod]
    public void SelectionSynchronizesDetailEvidenceAndActionsWhenFiltersChange()
    {
        var language = UiLanguageService.Shared;
        try
        {
            language.SetLanguage(UiLanguage.English);
            using var state = ComplianceQueueState.CreateSyntheticPreview();
            var target = state.VisibleIncidents.Single(item => item.IncidentId == "INC-2025-00073");

            state.SelectedIncident = target;
            Assert.AreEqual(target.IncidentId, state.SelectedDetail?.IncidentId);
            Assert.IsNotEmpty(state.SelectedDetail!.EvidenceItems);
            Assert.IsTrue(state.ReviewActions.All(item => item.IsVisible && !item.IsEnabled));

            state.SelectedStateFilter = state.StateFilters.Single(item => item.Id == "suspected");
            state.SelectedActorFilter = state.ActorFilters.Single(item => item.Id == "Test Worker");
            Assert.AreEqual(target.IncidentId, state.SelectedIncident?.IncidentId);
            Assert.AreEqual(target.IncidentId, state.SelectedDetail?.IncidentId);

            state.SelectedStateFilter = state.StateFilters.Single(item => item.Id == "confirmed");
            Assert.AreNotEqual(target.IncidentId, state.SelectedIncident?.IncidentId);
            Assert.AreEqual(state.SelectedIncident?.IncidentId, state.SelectedDetail?.IncidentId);
            Assert.IsTrue(state.ReviewActions.All(item => item.IsVisible && !item.IsEnabled));
        }
        finally
        {
            language.SetLanguage(UiLanguage.Thai);
        }
    }

    [TestMethod]
    public void LanguageRefreshKeepsTechnicalIdentityAndRendersOneCatalogAtATime()
    {
        var language = UiLanguageService.Shared;
        try
        {
            language.SetLanguage(UiLanguage.English);
            using var state = ComplianceQueueState.CreateSyntheticPreview();
            var incidentId = state.SelectedIncident!.IncidentId;
            var taskId = state.SelectedIncident.TaskId;
            var fileNames = state.SelectedDetail!.EvidenceItems.Select(item => item.FileName).ToArray();

            Assert.IsFalse(ContainsThai(state.SummaryCards.Select(item => item.Title)));
            Assert.IsFalse(ContainsThai(state.VisibleIncidents.SelectMany(item => new[] { item.Title, item.Description, item.StateLabel })));
            Assert.IsFalse(ContainsThai(new[]
            {
                state.SelectedDetail.ActorRole,
                state.SelectedDetail.TaskTitle,
                state.SelectedDetail.Description,
                state.SelectedDetail.RuleLabel,
                state.SelectedDetail.RuleDescription,
                state.SelectedDetail.DetectedBy,
            }
            .Concat(state.ReviewActions.Select(item => item.Label))
            .Concat(state.SelectedDetail.EvidenceItems.Select(item => item.Source))
            .Concat(state.SelectedDetail.EvidenceItems.Select(item => item.AvailabilityLabel))));

            language.SetLanguage(UiLanguage.Thai);
            state.RefreshLanguage();

            Assert.AreEqual(language["ComplianceQueueSummarySuspected"], state.SummaryCards[0].Title);
            Assert.IsTrue(ContainsThai(state.SummaryCards.Select(item => item.Title)));
            Assert.IsTrue(ContainsThai(state.VisibleIncidents.Select(item => item.StateLabel)));
            Assert.IsTrue(ContainsThai(state.ReviewActions.Select(item => item.UnavailableReason)));
            Assert.IsTrue(ContainsThai(state.SelectedDetail!.EvidenceItems.Select(item => item.Source)));
            Assert.IsTrue(ContainsThai(state.SelectedDetail.EvidenceItems.Select(item => item.AvailabilityLabel)));
            Assert.AreEqual(incidentId, state.SelectedIncident?.IncidentId);
            Assert.AreEqual(taskId, state.SelectedDetail?.TaskId);
            CollectionAssert.AreEqual(fileNames, state.SelectedDetail!.EvidenceItems.Select(item => item.FileName).ToArray());

            var thaiKeys = language.Keys(UiLanguage.Thai).ToHashSet(StringComparer.Ordinal);
            var englishKeys = language.Keys(UiLanguage.English).ToHashSet(StringComparer.Ordinal);
            CollectionAssert.AreEquivalent(thaiKeys.ToArray(), englishKeys.ToArray());
        }
        finally
        {
            language.SetLanguage(UiLanguage.Thai);
        }
    }

    [TestMethod]
    public void ThaiComplianceQueueTaskCopyDoesNotRetainUnapprovedEnglishFragments()
    {
        var language = UiLanguageService.Shared;
        try
        {
            language.SetLanguage(UiLanguage.Thai);
            using var state = ComplianceQueueState.CreateSyntheticPreview();
            var taskCopy = new List<string>();

            foreach (var incident in state.VisibleIncidents)
            {
                state.SelectedIncident = incident;
                taskCopy.Add(state.SelectedDetail!.TaskTitle);
                taskCopy.Add(state.SelectedDetail.Description);
                taskCopy.Add(incident.Title);
                taskCopy.Add(incident.Description);
            }

            // Technical identifiers and proper data are intentionally excluded from
            // this assertion; it covers only translated queue task/incident copy.
            var unapprovedEnglishFragments = new[]
            {
                "Client Analytics",
                "Auth Service",
                "Staging",
                "Unit Tests",
                "Report Module",
            };
            var violations = taskCopy
                .SelectMany(copy => unapprovedEnglishFragments
                    .Where(fragment => copy.Contains(fragment, StringComparison.OrdinalIgnoreCase))
                    .Select(fragment => $"{fragment}: {copy}"))
                .ToArray();

            Assert.IsEmpty(violations, $"Thai Compliance Queue copy retained English fragments: {string.Join(" | ", violations)}");
            Assert.IsTrue(
                taskCopy.All(copy => copy.Any(character => character is >= '\u0E00' and <= '\u0E7F')),
                "Thai Compliance Queue task copy must contain Thai text.");
        }
        finally
        {
            language.SetLanguage(UiLanguage.Thai);
        }
    }

    [TestMethod]
    public async Task BackgroundLanguageChangeWaitsForTheUiOwnedRefresh()
    {
        var language = UiLanguageService.Shared;
        try
        {
            language.SetLanguage(UiLanguage.English);
            using var state = ComplianceQueueState.CreateSyntheticPreview();
            var englishTitle = state.SummaryCards[0].Title;

            await Task.Run(() => language.SetLanguage(UiLanguage.Thai));

            // The queue has no cross-thread language subscription. ShellView owns
            // the dispatcher refresh, so the background event cannot mutate WPF
            // bound state before the UI owner explicitly refreshes it.
            Assert.AreEqual(englishTitle, state.SummaryCards[0].Title);

            state.RefreshLanguage();
            Assert.AreEqual(language["ComplianceQueueSummarySuspected"], state.SummaryCards[0].Title);
            Assert.IsTrue(ContainsThai(state.SummaryCards.Select(item => item.Title)));
        }
        finally
        {
            language.SetLanguage(UiLanguage.Thai);
        }
    }

    [TestMethod]
    public void DisposedStateStopsWeakLanguageRefreshAndDisposeIsIdempotent()
    {
        var language = UiLanguageService.Shared;
        try
        {
            language.SetLanguage(UiLanguage.English);
            var state = ComplianceQueueState.CreateSyntheticPreview();
            var englishTitle = state.SummaryCards[0].Title;

            state.Dispose();
            state.Dispose();
            language.SetLanguage(UiLanguage.Thai);
            state.RefreshLanguage();

            Assert.AreEqual(englishTitle, state.SummaryCards[0].Title);
            Assert.IsFalse(ContainsThai(state.SummaryCards.Select(item => item.Title)));
        }
        finally
        {
            language.SetLanguage(UiLanguage.Thai);
        }
    }

    [TestMethod]
    public void PreviewActionsExposeRoleRequirementsButNeverEnableMutation()
    {
        var language = UiLanguageService.Shared;
        try
        {
            language.SetLanguage(UiLanguage.English);
            var expectedApplicability = new Dictionary<ComplianceQueueViewerRole, bool[]>
            {
                [ComplianceQueueViewerRole.ProjectManager] = [true, true, false, true],
                [ComplianceQueueViewerRole.Leader] = [false, false, true, false],
                [ComplianceQueueViewerRole.Observer] = [false, false, false, false],
            };
            var expectedRequiredRoles = new Dictionary<string, string>(StringComparer.Ordinal)
            {
                ["confirm"] = "ComplianceQueueRoleProjectManager",
                ["send-to-leader"] = "ComplianceQueueRoleProjectManager",
                ["escalate-to-pm"] = "ComplianceQueueRoleLeader",
                ["dismiss"] = "ComplianceQueueRoleProjectManager",
            };
            var actionIds = new[] { "confirm", "send-to-leader", "escalate-to-pm", "dismiss" };

            foreach (var (role, expected) in expectedApplicability)
            {
                using var state = ComplianceQueueState.CreateSyntheticPreview(role);

                Assert.IsTrue(state.ReviewActions.All(item => item.IsVisible));
                Assert.IsTrue(state.ReviewActions.All(item => !item.IsEnabled));
                Assert.IsTrue(state.ReviewActions.All(item =>
                    item.UnavailableReason == language["ComplianceQueueActionUnavailablePreview"]));
                Assert.IsTrue(state.ReviewActions.All(item => !string.IsNullOrWhiteSpace(item.RequiredRoleLabel)));
                Assert.IsTrue(state.ReviewActions.All(item => !string.IsNullOrWhiteSpace(item.AutomationName)));
                Assert.AreEqual(role, state.ViewerRole);
                Assert.AreEqual(language[ViewerRoleCatalogKey(role)], state.ViewerRoleLabel);
                foreach (var action in state.ReviewActions)
                {
                    Assert.AreEqual(
                        language[expectedRequiredRoles[action.Id]],
                        action.RequiredRoleLabel,
                        $"Action {action.Id} has the wrong required role for {role}.");
                }
                CollectionAssert.AreEqual(
                    expected,
                    state.ReviewActions.Select(item => item.IsRoleApplicable).ToArray());
                CollectionAssert.AreEquivalent(
                    actionIds,
                    state.ReviewActions.Select(item => item.Id).ToArray());
            }

            Assert.AreEqual("Observer", language.Text(UiLanguage.English, "ComplianceQueueRoleObserver"));
            Assert.AreEqual("ผู้สังเกตการณ์", language.Text(UiLanguage.Thai, "ComplianceQueueRoleObserver"));
        }
        finally
        {
            language.SetLanguage(UiLanguage.Thai);
        }
    }

    [TestMethod]
    public void UnavailableLiveStateDoesNotInventIncidentsOrActions()
    {
        var language = UiLanguageService.Shared;
        try
        {
            language.SetLanguage(UiLanguage.English);
            using var state = ComplianceQueueState.CreateUnavailableLiveState();

            Assert.IsFalse(state.IsSyntheticPreview);
            Assert.AreEqual(EvidenceClass.Contract, state.EvidenceClass);
            Assert.IsEmpty(state.VisibleIncidents);
            Assert.IsNull(state.SelectedIncident);
            Assert.IsNull(state.SelectedDetail);
            Assert.IsEmpty(state.ReviewActions);
            Assert.IsFalse(state.CanEditReviewReason);
            Assert.IsFalse(state.TrySelectIncident("INC-MISSING"));
            Assert.AreEqual(language["ComplianceQueueLiveBoundary"], state.ConnectionLabel);
            Assert.HasCount(4, state.SummaryCards);
            Assert.IsTrue(state.SummaryCards.All(item => item.Value == "—"));
        }
        finally
        {
            language.SetLanguage(UiLanguage.Thai);
        }
    }

    private static ComplianceReviewIncident CreateIncident(string incidentId) =>
        ComplianceReviewWorkflowContract.CreateIncident(
            new ComplianceReviewIncidentRegistration(
                ComplianceReviewWorkflowContract.ContractVersion,
                incidentId,
                "TASK-QUEUE-RACE",
                "backend-worker-01",
                BaseUtc,
                [new string('A', 64)]));

    private static HerdrOpsReviewCommandResult CreateRejectedResult(
        ComplianceReviewIncident incident) =>
        new(
            IsAccepted: false,
            RejectionCode: (int)ComplianceReviewRejectionCode.UnknownAuthority,
            Message: "The review command was rejected with the current incident snapshot.",
            Incident: ToContract(incident),
            AuditEvent: null,
            WasAlreadyPresent: false);

    private static HerdrOpsReviewCommandResult CreateAcceptedResult(
        ComplianceReviewIncident incident,
        HerdrOpsReviewCommandRequest request)
    {
        var command = new ComplianceReviewCommand(
            request.ContractVersion,
            request.CommandId,
            incident.IncidentId,
            (ComplianceReviewState)request.ExpectedState,
            request.ExpectedSequence,
            request.ReviewerActorId,
            (ComplianceReviewDecisionKind)request.DecisionKind,
            request.Reason,
            BaseUtc.AddMinutes(4),
            incident.InitialEvidenceIdentitySha256s);
        var authority = new ComplianceReviewAuthority(
            request.ReviewerActorId,
            ComplianceReviewerRole.ProjectManager,
            Guid.Parse("77777777-7777-7777-7777-777777777777"),
            ProvenanceSequence: 20,
            BaseUtc.AddMinutes(1),
            new string('C', 64));
        var auditEvent = ComplianceReviewWorkflowContract.CreateAuditEvent(
            incident,
            command,
            authority);
        var updated = ComplianceReviewWorkflowContract.Apply(incident, auditEvent);
        return new(
            IsAccepted: true,
            RejectionCode: (int)ComplianceReviewRejectionCode.None,
            Message: "The review command was accepted.",
            Incident: ToContract(updated),
            AuditEvent: ToContract(auditEvent),
            WasAlreadyPresent: false);
    }

    private static (ComplianceReviewIncident Incident, HerdrOpsReviewCommandResult Result)
        CreateTransitionResult(
        ComplianceReviewIncident incident,
        ComplianceReviewDecisionKind decision,
        ComplianceReviewerRole role,
        string reviewerActorId,
        Guid commandId,
        Guid provenanceEventId,
        DateTimeOffset occurredUtc)
    {
        var command = new ComplianceReviewCommand(
            ComplianceReviewWorkflowContract.ContractVersion,
            commandId,
            incident.IncidentId,
            incident.State,
            incident.Sequence,
            reviewerActorId,
            decision,
            "The evidence and assigned scope were reviewed.",
            occurredUtc,
            incident.InitialEvidenceIdentitySha256s);
        var authority = new ComplianceReviewAuthority(
            reviewerActorId,
            role,
            provenanceEventId,
            ProvenanceSequence: 30 + incident.Sequence,
            BaseUtc.AddMinutes(1),
            new string('C', 64));
        var auditEvent = ComplianceReviewWorkflowContract.CreateAuditEvent(
            incident,
            command,
            authority);
        var updated = ComplianceReviewWorkflowContract.Apply(incident, auditEvent);
        return (
            updated,
            new HerdrOpsReviewCommandResult(
                IsAccepted: true,
                RejectionCode: (int)ComplianceReviewRejectionCode.None,
                Message: "The review command was accepted.",
                Incident: ToContract(updated),
                AuditEvent: ToContract(auditEvent),
                WasAlreadyPresent: false));
    }

    private static HerdrOpsComplianceReviewIncident ToContract(
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

    private static HerdrOpsComplianceReviewAuditEvent ToContract(
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

    private sealed class LiveReviewFixture : IDisposable
    {
        private readonly EventHandler<ComplianceReviewStateChangedEventArgs> _stateChanged;

        private LiveReviewFixture(
            ComplianceQueueState state,
            ComplianceReviewStateHub stateHub,
            DeferredReviewClient client,
            ComplianceReviewIncident initialIncident)
        {
            State = state;
            StateHub = stateHub;
            Client = client;
            InitialIncident = initialIncident;
            _stateChanged = (_, args) => State.ApplyAuthoritativeReviewChange(args.Change);
            StateHub.StateChanged += _stateChanged;
        }

        public ComplianceQueueState State { get; }

        public ComplianceReviewStateHub StateHub { get; }

        public DeferredReviewClient Client { get; }

        public ComplianceReviewIncident InitialIncident { get; }

        public static async Task<LiveReviewFixture> CreateAsync(string incidentId)
        {
            var initialIncident = CreateIncident(incidentId);
            var stateHub = new ComplianceReviewStateHub();
            var client = new DeferredReviewClient();
            var coordinator = new ComplianceReviewCommandCoordinator(
                client,
                stateHub);
            var state = ComplianceQueueState.CreateUnavailableLiveState(
                coordinator,
                reviewerActorId: "project-manager");
            var fixture = new LiveReviewFixture(
                state,
                stateHub,
                client,
                initialIncident);
            stateHub.Apply(CreateRejectedResult(initialIncident));
            if (!state.TrySelectIncident(incidentId))
            {
                throw new InvalidOperationException(
                    "The live review fixture did not select its incident.");
            }

            await state.RefreshReviewCapabilitiesAsync();
            state.ReviewReason = "Review the current evidence before deciding.";
            if (!state.ReviewActions.Single(item => item.Id == "confirm").IsEnabled)
            {
                throw new InvalidOperationException(
                    "The live review fixture did not enable the confirm action.");
            }

            return fixture;
        }

        public Task<bool> StartReviewAsync() =>
            State.ExecuteReviewActionAsync(
                    State.ReviewActions.Single(item => item.Id == "confirm"))
                .AsTask();

        public void Dispose()
        {
            StateHub.StateChanged -= _stateChanged;
            State.Dispose();
        }
    }

    private sealed class DeferredReviewClient : IHerdrOpsReviewCommandClient
    {
        private readonly TaskCompletionSource<HerdrOpsReviewCommandResult> _response =
            new(TaskCreationOptions.RunContinuationsAsynchronously);
        private int _executeCallCount;

        public TaskCompletionSource<HerdrOpsReviewCommandRequest> Started { get; } =
            new(TaskCreationOptions.RunContinuationsAsynchronously);

        public int ExecuteCallCount => Volatile.Read(ref _executeCallCount);

        public ValueTask<HerdrOpsReviewCommandResult> ExecuteAsync(
            HerdrOpsReviewCommandRequest request,
            CancellationToken cancellationToken)
        {
            cancellationToken.ThrowIfCancellationRequested();
            Interlocked.Increment(ref _executeCallCount);
            Started.TrySetResult(request);
            return new ValueTask<HerdrOpsReviewCommandResult>(_response.Task);
        }

        public ValueTask<HerdrOpsReviewCapabilitiesResult> ReadCapabilitiesAsync(
            HerdrOpsReviewCapabilitiesRequest request,
            CancellationToken cancellationToken)
        {
            _ = request;
            cancellationToken.ThrowIfCancellationRequested();
            return ValueTask.FromResult(
                new HerdrOpsReviewCapabilitiesResult(
                    HasCurrentAuthority: true,
                    ReviewerRole: (int)ComplianceReviewerRole.ProjectManager,
                    IncidentState: (int)ComplianceReviewState.Suspected,
                    IncidentSequence: 0,
                    AllowedDecisionKinds:
                    [
                        (int)ComplianceReviewDecisionKind.Confirm,
                        (int)ComplianceReviewDecisionKind.SendToLeader,
                        (int)ComplianceReviewDecisionKind.Dismiss,
                    ],
                    Message: "The fixture authority and incident state are current."));
        }

        public void Complete(HerdrOpsReviewCommandResult result) =>
            _response.TrySetResult(result);
    }

    private static void ResetFilters(ComplianceQueueState state)
    {
        state.SelectedSeverityFilter = state.SeverityFilters.Single(item => item.Id == "all");
        state.SelectedStateFilter = state.StateFilters.Single(item => item.Id == "all");
        state.SelectedActorFilter = state.ActorFilters.Single(item => item.Id == "all");
        state.SelectedTaskFilter = state.TaskFilters.Single(item => item.Id == "all");
        state.SelectedReviewerFilter = state.ReviewerFilters.Single(item => item.Id == "all");
        state.SelectedSortOption = state.SortOptions.Single(item => item.Id == "severity");
    }

    private static bool IsSeverityThenNewest(IReadOnlyList<ComplianceQueueIncidentRow> rows) =>
        rows.Zip(rows.Skip(1), (left, right) =>
                left.SeverityRank > right.SeverityRank ||
                (left.SeverityRank == right.SeverityRank && left.ObservedAt >= right.ObservedAt))
            .All(item => item);

    private static bool IsNewestFirst(IReadOnlyList<ComplianceQueueIncidentRow> rows) =>
        rows.Zip(rows.Skip(1), (left, right) => left.ObservedAt >= right.ObservedAt)
            .All(item => item);

    private static bool IsOldestFirst(IReadOnlyList<ComplianceQueueIncidentRow> rows) =>
        rows.Zip(rows.Skip(1), (left, right) => left.ObservedAt <= right.ObservedAt)
            .All(item => item);

    private static string StateId(ComplianceQueueState state, string label) =>
        state.StateFilters.Single(item => item.Label == label).Id;

    private static string ViewerRoleCatalogKey(ComplianceQueueViewerRole role) => role switch
    {
        ComplianceQueueViewerRole.ProjectManager => "ComplianceQueueRoleProjectManager",
        ComplianceQueueViewerRole.Leader => "ComplianceQueueRoleLeader",
        ComplianceQueueViewerRole.Observer => "ComplianceQueueRoleObserver",
        _ => throw new ArgumentOutOfRangeException(nameof(role), role, "Unsupported viewer role."),
    };

    private static bool ContainsThai(IEnumerable<string> values) =>
        values.Any(value => value.Any(character => character is >= '\u0E00' and <= '\u0E7F'));
}
