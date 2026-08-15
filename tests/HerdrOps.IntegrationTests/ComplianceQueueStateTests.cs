using HerdrOps.App.Compliance;
using HerdrOps.App.Localization;
using HerdrOps.Contracts;

namespace HerdrOps.IntegrationTests;

[TestClass]
[DoNotParallelize]
public sealed class ComplianceQueueStateTests
{
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
            Assert.AreEqual(language["ComplianceQueueLiveBoundary"], state.ConnectionLabel);
            Assert.HasCount(4, state.SummaryCards);
            Assert.IsTrue(state.SummaryCards.All(item => item.Value == "—"));
        }
        finally
        {
            language.SetLanguage(UiLanguage.Thai);
        }
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
