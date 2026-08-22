using System.Diagnostics;
using System.Globalization;
using System.Windows;
using System.Windows.Interop;
using System.Windows.Media;
using HerdrOps.App;
using HerdrOps.App.Live;
using HerdrOps.App.Localization;
using HerdrOps.App.RuntimeEvidence;
using HerdrOps.App.Views;
using HerdrOps.App.Widgets;

namespace HerdrOps.RuntimeTests;

[TestClass]
[DoNotParallelize]
public sealed class RuntimeEvidenceResourceLifecycleTests
{
    public TestContext TestContext { get; set; } = null!;

    [TestMethod]
    public void ResourceStageDiagnosticsRemainExactAndOrdered()
    {
        CollectionAssert.AreEqual(
            new[]
            {
                "pre-capture",
                "post-initial-captures",
                "post-dashboard-close",
                "post-final-widget-capture",
                "post-cleanup",
            },
            RuntimeEvidenceRunner.RequiredResourceStageNames.ToArray());
    }

    [TestMethod]
    public void ResourceStageCheckpointBindsCurrentProcessAndMemoryCounters()
    {
        WpfTestHost.Run(() =>
        {
            using var app = Process.GetCurrentProcess();
            var observedBeforeUtc = DateTimeOffset.UtcNow;

            var checkpoint = RuntimeEvidenceRunner.ObserveResourceStageCheckpoint(
                "pre-capture",
                app);

            var observedAfterUtc = DateTimeOffset.UtcNow;
            Assert.AreEqual("pre-capture", checkpoint.Stage);
            Assert.IsTrue(checkpoint.ObservedUtc >= observedBeforeUtc);
            Assert.IsTrue(checkpoint.ObservedUtc <= observedAfterUtc);
            Assert.AreEqual(app.Id, checkpoint.AppProcessId);
            Assert.AreEqual(
                new DateTimeOffset(app.StartTime.ToUniversalTime()),
                checkpoint.AppProcessStartUtc);
            Assert.IsGreaterThan(0d, checkpoint.AppWorkingSetMegabytes);
            Assert.IsGreaterThan(0d, checkpoint.AppPrivateMemoryMegabytes);
            Assert.IsGreaterThanOrEqualTo(0d, checkpoint.AppPagedMemoryMegabytes);
            Assert.IsGreaterThan(0d, checkpoint.ManagedHeapMegabytes);
            Assert.AreEqual("resource-stage:pre-capture", checkpoint.RendererObservation.Phase);
            Assert.AreEqual("SoftwareOnly", checkpoint.RendererObservation.WpfProcessRenderMode);
            Assert.IsTrue(checkpoint.RendererObservation.SoftwareOnlyConfirmed);
        }, TimeSpan.FromSeconds(30));
    }

    [TestMethod]
    public void AppEnforcesSoftwareRenderingBeforeAnyTestWindowIsCreated()
    {
        WpfTestHost.Run(() =>
        {
            Assert.IsInstanceOfType<HerdrOps.App.App>(Application.Current);
            Assert.AreEqual(RenderMode.SoftwareOnly, RenderOptions.ProcessRenderMode);
            Assert.AreEqual(
                "app-constructor-before-initialize-component",
                RuntimeRenderPolicy.StartupObservation.Phase);
            Assert.AreEqual(
                "SoftwareOnly",
                RuntimeRenderPolicy.StartupObservation.WpfProcessRenderMode);
            Assert.IsTrue(RuntimeRenderPolicy.StartupObservation.SoftwareOnlyConfirmed);
        }, TimeSpan.FromSeconds(30));
    }

    [TestMethod]
    public void ResourcePolicyUsesApprovedMaximum255MiBContract()
    {
        Assert.AreEqual(255d, RuntimeEvidenceRunner.WorkingSetTargetMegabytes);
        Assert.AreEqual(267_386_880L, RuntimeEvidenceRunner.WorkingSetTargetBytes);
        Assert.AreEqual("maximum", RuntimeEvidenceRunner.WorkingSetStatistic);
    }

    [TestMethod]
    public void IdleRendererObservationValidationRejectsMissingReorderedAndFalseEvidence()
    {
        var observedUtc = DateTimeOffset.UtcNow;
        RuntimeRenderPolicyObservation Observation(int ordinal, bool confirmed = true) =>
            new(
                $"idle-resource-sample:{ordinal}",
                observedUtc.AddMilliseconds(ordinal),
                "SoftwareOnly",
                RenderTier: 0,
                confirmed);
        var valid = new[] { Observation(0), Observation(1), Observation(2) };

        Assert.IsTrue(RuntimeEvidenceRunner.AreIdleSampleRendererObservationsValid(valid, 3));
        Assert.IsFalse(RuntimeEvidenceRunner.AreIdleSampleRendererObservationsValid(valid[..2], 3));
        Assert.IsFalse(RuntimeEvidenceRunner.AreIdleSampleRendererObservationsValid(
            new[] { valid[1], valid[0], valid[2] },
            3));
        Assert.IsFalse(RuntimeEvidenceRunner.AreIdleSampleRendererObservationsValid(
            new[] { valid[0], Observation(1, confirmed: false), valid[2] },
            3));
    }

    [TestMethod]
    public void ObservedHostUsesShownWindowEffectiveDpiAndActualWindowDisplayBounds()
    {
        WpfTestHost.Run(() =>
        {
            using var state = new LiveDashboardState();
            var window = new MainWindow(state);
            try
            {
                window.Show();
                window.UpdateLayout();

                var observed = RuntimeEvidenceRunner.ObserveHostAfterMainWindowShown(window);
                var wpfDpi = VisualTreeHelper.GetDpi(window);
                var windowHandle = new WindowInteropHelper(window).Handle;
                Assert.IsTrue(window.IsVisible);
                Assert.AreNotEqual(IntPtr.Zero, windowHandle);
                var windowDisplay = System.Windows.Forms.Screen.FromHandle(windowHandle);
                var expectedLogicalWidth =
                    (int)Math.Round(
                        windowDisplay.Bounds.Width * 96d / wpfDpi.PixelsPerInchX,
                        MidpointRounding.AwayFromZero);
                var expectedLogicalHeight =
                    (int)Math.Round(
                        windowDisplay.Bounds.Height * 96d / wpfDpi.PixelsPerInchY,
                        MidpointRounding.AwayFromZero);
                using var windowMetrics = Microsoft.Win32.Registry.CurrentUser.OpenSubKey(
                    @"Control Panel\Desktop\WindowMetrics",
                    writable: false);
                var expectedDesktopAppliedDpi = Convert.ToInt32(
                    windowMetrics?.GetValue("AppliedDPI") ??
                        throw new AssertFailedException("HKCU WindowMetrics AppliedDPI is unavailable."),
                    CultureInfo.InvariantCulture);
                TestContext.WriteLine(
                    $"DesktopAppliedDpi={observed.DesktopAppliedDpi}; MainWindowDpi={observed.MainWindowDpiX}x{observed.MainWindowDpiY}; WindowDisplay={observed.WindowDisplayDeviceName}; PhysicalBounds={windowDisplay.Bounds.Width}x{windowDisplay.Bounds.Height}; ExpectedLogicalBounds={expectedLogicalWidth}x{expectedLogicalHeight}; LogicalBounds={observed.WindowDisplayLogicalWidthPixels}x{observed.WindowDisplayLogicalHeightPixels}");

                Assert.IsTrue(double.IsFinite(wpfDpi.PixelsPerInchX));
                Assert.IsTrue(double.IsFinite(wpfDpi.PixelsPerInchY));
                Assert.IsGreaterThan(0d, wpfDpi.PixelsPerInchX);
                Assert.IsGreaterThan(0d, wpfDpi.PixelsPerInchY);
                Assert.AreEqual(Math.Round(wpfDpi.PixelsPerInchX, 3), observed.MainWindowDpiX);
                Assert.AreEqual(Math.Round(wpfDpi.PixelsPerInchY, 3), observed.MainWindowDpiY);
                Assert.AreEqual(windowDisplay.DeviceName, observed.WindowDisplayDeviceName);
                Assert.AreEqual(expectedLogicalWidth, observed.WindowDisplayLogicalWidthPixels);
                Assert.AreEqual(expectedLogicalHeight, observed.WindowDisplayLogicalHeightPixels);
                Assert.IsGreaterThan(0, observed.WindowDisplayLogicalWidthPixels);
                Assert.IsGreaterThan(0, observed.WindowDisplayLogicalHeightPixels);
                Assert.AreEqual(expectedDesktopAppliedDpi, observed.DesktopAppliedDpi);
            }
            finally
            {
                window.Close();
            }
        }, TimeSpan.FromSeconds(30));
    }

    [TestMethod]
    public void RequestedLanguageObservationBindsActualServiceLanguageAndUiCulture()
    {
        var originalLanguage = UiLanguageService.Shared.CurrentLanguage;
        var originalUiCulture = CultureInfo.CurrentUICulture;
        try
        {
            var observation = RuntimeEvidenceProducerBinding.ApplyAndObserveLanguage(
                UiLanguage.English);

            Assert.AreEqual("English", observation.Language);
            Assert.AreEqual("en-US", observation.CurrentUiCultureName);
            Assert.AreEqual(UiLanguage.English, UiLanguageService.Shared.CurrentLanguage);
            Assert.AreEqual("en-US", CultureInfo.CurrentUICulture.Name);
            Assert.IsTrue(RuntimeEvidenceProducerBinding.IsRequestedLanguageObservationValid(
                observation,
                UiLanguage.English));
            Assert.IsFalse(RuntimeEvidenceProducerBinding.IsRequestedLanguageObservationValid(
                observation with { CurrentUiCultureName = "th-TH" },
                UiLanguage.English));
            Assert.IsFalse(RuntimeEvidenceProducerBinding.IsRequestedLanguageObservationValid(
                observation with { Language = "Thai" },
                UiLanguage.English));

            UiLanguageService.Shared.SetLanguage(UiLanguage.Thai);
            var driftedObservation = RuntimeEvidenceProducerBinding.ObserveCurrentLanguage();
            Assert.IsFalse(RuntimeEvidenceProducerBinding.IsRequestedLanguageObservationValid(
                driftedObservation,
                UiLanguage.English));

            _ = RuntimeEvidenceProducerBinding.ApplyAndObserveLanguage(UiLanguage.English);
            using var tracker = new RuntimeEvidenceLanguageChangeTracker();
            UiLanguageService.Shared.SetLanguage(UiLanguage.Thai);
            UiLanguageService.Shared.SetLanguage(UiLanguage.English);
            var restoredObservation = RuntimeEvidenceProducerBinding.ObserveCurrentLanguage();
            Assert.IsTrue(RuntimeEvidenceProducerBinding.IsRequestedLanguageObservationValid(
                restoredObservation,
                UiLanguage.English));
            Assert.AreEqual(2L, tracker.ChangeCount);
        }
        finally
        {
            _ = RuntimeEvidenceProducerBinding.ApplyAndObserveLanguage(originalLanguage);
            CultureInfo.CurrentUICulture = originalUiCulture;
        }
    }

    [TestMethod]
    public void RawResourceSamplesAreTheOnlyWorkingSetAggregateAuthority()
    {
        var observedUtc = DateTimeOffset.UtcNow;
        var samples = Enumerable.Range(0, 81)
            .Select(index => CreateResourceSample(
                index,
                observedUtc.AddMilliseconds(250 * index),
                10 + index,
                20 + index,
                100 + index,
                200 + index))
            .ToArray();

        var summary = RuntimeEvidenceRunner.SummarizeWorkingSetSamples(samples);

        Assert.AreEqual(110d, summary.CombinedAverageBytes);
        Assert.AreEqual(190L, summary.CombinedMaximumBytes);
        Assert.AreEqual(50d, summary.AppAverageBytes);
        Assert.AreEqual(90L, summary.AppMaximumBytes);
        Assert.AreEqual(60d, summary.CoreAverageBytes);
        Assert.AreEqual(100L, summary.CoreMaximumBytes);
        Assert.AreEqual(140d, summary.AppPrivateAverageBytes);
        Assert.AreEqual(180L, summary.AppPrivateMaximumBytes);
        Assert.AreEqual(240d, summary.CorePrivateAverageBytes);
        Assert.AreEqual(280L, summary.CorePrivateMaximumBytes);
    }

    [TestMethod]
    public void RunnerConstructorRejectsForgedProducerBinding()
    {
        WpfTestHost.Run(() =>
        {
            var options = new RuntimeEvidenceOptions(
                "runtime-report.json",
                "captures",
                "progress.json",
                Environment.ProcessId,
                TimeoutSeconds: 180,
                RuntimeEvidenceOptions.ApprovedIdleSeconds,
                UiLanguage.English,
                RuntimeEvidenceOptions.ApprovedProfileId,
                RuntimeEvidenceOptions.ApprovedProfileSha256);
            var validBinding = RuntimeEvidenceProducerBinding.ObserveBeforeFirstWindow(options);
            using var state = new LiveDashboardState();
            MainWindow? window = null;
            try
            {
                window = new MainWindow(state);
                window.Show();
                _ = new RuntimeEvidenceRunner(state, window, options, validBinding);

                Assert.ThrowsExactly<InvalidOperationException>(() =>
                    RuntimeEvidenceProducerBinding.ObserveBeforeFirstWindow(options));

                Assert.ThrowsExactly<ArgumentException>(() =>
                    new RuntimeEvidenceRunner(
                        state,
                        window,
                        options,
                        validBinding with { ProfileId = "forged-profile" }));
                Assert.ThrowsExactly<ArgumentException>(() =>
                    new RuntimeEvidenceRunner(
                        state,
                        window,
                        options,
                        validBinding with
                        {
                            Language = new RuntimeEvidenceLanguageObservation("Thai", "th-TH"),
                        }));
                Assert.ThrowsExactly<ArgumentException>(() =>
                    new RuntimeEvidenceRunner(
                        state,
                        window,
                        options,
                        validBinding with
                        {
                            Startup = validBinding.Startup with
                            {
                                ObservedUtc = validBinding.Startup.ObservedUtc.AddTicks(1),
                            },
                        }));
                Assert.ThrowsExactly<ArgumentException>(() =>
                    new RuntimeEvidenceRunner(
                        state,
                        window,
                        options,
                        validBinding with
                        {
                            PreFirstWindow = validBinding.PreFirstWindow with
                            {
                                Phase = "forged-pre-first-window",
                            },
                        }));
                Assert.ThrowsExactly<ArgumentException>(() =>
                    new RuntimeEvidenceRunner(
                        state,
                        window,
                        options,
                        validBinding with
                        {
                            PreFirstWindow = validBinding.PreFirstWindow with
                            {
                                WpfProcessRenderMode = "Default",
                            },
                        }));
                Assert.ThrowsExactly<ArgumentException>(() =>
                    new RuntimeEvidenceRunner(
                        state,
                        window,
                        options,
                        validBinding with
                        {
                            PreFirstWindow = validBinding.PreFirstWindow with
                            {
                                ObservedUtc = validBinding.PreFirstWindow.ObservedUtc.ToOffset(
                                    TimeSpan.FromHours(7)),
                            },
                        }));
                Assert.ThrowsExactly<ArgumentException>(() =>
                    new RuntimeEvidenceRunner(
                        state,
                        window,
                        options,
                        validBinding with
                        {
                            PreFirstWindow = validBinding.PreFirstWindow with
                            {
                                ObservedUtc = validBinding.Startup.ObservedUtc.AddTicks(-1),
                            },
                        }));
            }
            finally
            {
                window?.Close();
                validBinding.LanguageChangeTracker!.Dispose();
            }
        }, TimeSpan.FromSeconds(30));
    }

    [TestMethod]
    public void RawResourceSampleSummaryRejectsBrokenOrderingBindingAndRendererProof()
    {
        var observedUtc = DateTimeOffset.UtcNow;
        var valid = Enumerable.Range(0, 81)
            .Select(index => CreateResourceSample(
                index,
                observedUtc.AddMilliseconds(250 * index),
                10 + index,
                20 + index,
                100 + index,
                200 + index))
            .ToArray();

        Assert.ThrowsExactly<ArgumentException>(() =>
            RuntimeEvidenceRunner.SummarizeWorkingSetSamples(
                valid.Select((sample, index) =>
                    index == 1 ? sample with { Ordinal = 2 } : sample).ToArray()));
        Assert.ThrowsExactly<ArgumentException>(() =>
            RuntimeEvidenceRunner.SummarizeWorkingSetSamples(
                valid.Select((sample, index) =>
                    index == 1 ? sample with { ElapsedMilliseconds = 248 } : sample).ToArray()));
        Assert.ThrowsExactly<ArgumentException>(() =>
            RuntimeEvidenceRunner.SummarizeWorkingSetSamples(
                valid.Select((sample, index) =>
                    index == 1 ? sample with { CombinedWorkingSetBytes = 69 } : sample).ToArray()));
        Assert.ThrowsExactly<ArgumentException>(() =>
            RuntimeEvidenceRunner.SummarizeWorkingSetSamples(
                valid.Select((sample, index) =>
                    index == 1
                        ? sample with
                        {
                            RendererObservation = sample.RendererObservation with
                            {
                                SoftwareOnlyConfirmed = false,
                            },
                        }
                        : sample).ToArray()));
        Assert.ThrowsExactly<ArgumentException>(() =>
            RuntimeEvidenceRunner.SummarizeWorkingSetSamples(
                valid.Select((sample, index) =>
                    index == 80 ? sample with { ElapsedMilliseconds = 19_999 } : sample).ToArray()));
        Assert.ThrowsExactly<ArgumentException>(() =>
            RuntimeEvidenceRunner.SummarizeWorkingSetSamples(
                valid.Select((sample, index) =>
                    index == 40 ? sample with { ElapsedMilliseconds = 10_251 } : sample).ToArray()));
        Assert.ThrowsExactly<ArgumentException>(() =>
            RuntimeEvidenceRunner.SummarizeWorkingSetSamples(
                valid.Select((sample, index) =>
                    sample with { ElapsedMilliseconds = index * (20_300d / 80d) }).ToArray()));
        Assert.ThrowsExactly<ArgumentException>(() =>
            RuntimeEvidenceRunner.SummarizeWorkingSetSamples(
                valid.Select((sample, index) =>
                    index == 1 ? sample with { ElapsedMilliseconds = double.NaN } : sample).ToArray()));
    }

    [TestMethod]
    public void RendererPolicyFailsClosedOnProcessModeDrift()
    {
        WpfTestHost.Run(() =>
        {
            try
            {
                RenderOptions.ProcessRenderMode = RenderMode.Default;
                Assert.ThrowsExactly<InvalidOperationException>(() =>
                    RuntimeRenderPolicy.ObserveAndRequireSoftwareOnly(
                        "hostile-test-renderer-drift"));
            }
            finally
            {
                RenderOptions.ProcessRenderMode = RenderMode.SoftwareOnly;
            }
        }, TimeSpan.FromSeconds(30));
    }

    [TestMethod]
    public void ResourceStageCheckpointRejectsBlankStage()
    {
        using var app = Process.GetCurrentProcess();

        Assert.ThrowsExactly<ArgumentException>(() =>
            RuntimeEvidenceRunner.ObserveResourceStageCheckpoint(" ", app));
    }

    private static RuntimeResourceSample CreateResourceSample(
        int ordinal,
        DateTimeOffset observedUtc,
        long appWorkingSetBytes,
        long coreWorkingSetBytes,
        long appPrivateMemoryBytes,
        long corePrivateMemoryBytes)
    {
        var renderer = new RuntimeRenderPolicyObservation(
            $"idle-resource-sample:{ordinal}",
            observedUtc,
            "SoftwareOnly",
            RenderTier: 0,
            SoftwareOnlyConfirmed: true);
        return new RuntimeResourceSample(
            ordinal,
            observedUtc,
            ordinal * 250d,
            appWorkingSetBytes,
            coreWorkingSetBytes,
            checked(appWorkingSetBytes + coreWorkingSetBytes),
            appPrivateMemoryBytes,
            corePrivateMemoryBytes,
            new RuntimeStateFingerprint(
                IsCoreConnected: true,
                IsLive: true,
                RuntimeStatus: "Live",
                LastTransitionUtc: observedUtc,
                LastAcceptedStateUtc: observedUtc,
                ConnectionEpoch: 1,
                LastIngestSequence: 1,
                BootstrapCount: 1,
                EventCount: 1,
                DisconnectCount: 0,
                ReconciliationCount: 0,
                StateSha256: new string('A', 64)),
            renderer);
    }

    [TestMethod]
    public void ClosingDashboardReleasesItsVisualTreeWithoutOwningLiveState()
    {
        WpfTestHost.Run(() =>
        {
            using var state = new LiveDashboardState();
            var window = new MainWindow(state);
            window.Show();
            window.UpdateLayout();
            var shell = window.Shell;

            Assert.AreSame(state, shell.LiveDashboard);
            Assert.IsFalse(window.DashboardResourcesReleased);

            window.Close();

            Assert.IsTrue(window.DashboardResourcesReleased);
            Assert.AreEqual(0, shell.RetainedPageCount);
            Assert.IsNull(shell.ActivePageName);
            Assert.ThrowsExactly<InvalidOperationException>(() => _ = window.Shell);
            state.RefreshLanguage();
        }, TimeSpan.FromSeconds(30));
    }

    [TestMethod]
    public void ClosingDashboardReleasesItsTreeWhileAWidgetRemainsVisible()
    {
        WpfTestHost.Run(() =>
        {
            using var state = new LiveDashboardState();
            var widget = new WidgetWindow(
                WidgetCatalog.Get(WidgetVariant.FloatingVertical),
                state.Widgets)
            {
                ShowActivated = false,
            };
            var window = new MainWindow(state);
            widget.Show();
            window.Show();
            window.UpdateLayout();

            window.Close();

            Assert.IsTrue(window.DashboardResourcesReleased);
            Assert.IsTrue(widget.IsVisible);
            Assert.IsFalse(widget.ResourcesReleased);

            widget.Close();
            Assert.IsTrue(widget.ResourcesReleased);
        }, TimeSpan.FromSeconds(30));
    }

    [TestMethod]
    public void ShellRetainsOnlyTheSelectedCanonicalPage()
    {
        WpfTestHost.Run(() =>
        {
            using var state = new LiveDashboardState();
            var window = new MainWindow(state);
            window.Show();
            window.UpdateLayout();
            var shell = window.Shell;

            Assert.AreEqual(1, shell.RetainedPageCount);
            Assert.AreEqual("OverviewPage", shell.ActivePageName);
            Assert.IsInstanceOfType<OverviewView>(shell.FindName("OverviewPage"));
            Assert.IsNull(shell.FindName("RealtimeActivityPage"));

            Assert.IsTrue(shell.NavigateTo("realtime-activity"));
            window.UpdateLayout();
            Assert.AreEqual(1, shell.RetainedPageCount);
            Assert.AreEqual("RealtimeActivityPage", shell.ActivePageName);
            Assert.IsNull(shell.FindName("OverviewPage"));
            Assert.IsInstanceOfType<RealtimeActivityView>(
                shell.FindName("RealtimeActivityPage"));

            Assert.IsTrue(shell.NavigateTo("evaluation"));
            window.UpdateLayout();
            Assert.AreEqual(1, shell.RetainedPageCount);
            Assert.AreEqual("EvaluationPage", shell.ActivePageName);
            Assert.IsNull(shell.FindName("RealtimeActivityPage"));
            Assert.IsInstanceOfType<EvaluationView>(shell.FindName("EvaluationPage"));

            Assert.IsTrue(shell.NavigateTo("daily-summary"));
            window.UpdateLayout();
            Assert.AreEqual(1, shell.RetainedPageCount);
            Assert.AreEqual("DailySummaryPage", shell.ActivePageName);
            Assert.IsNull(shell.FindName("EvaluationPage"));
            Assert.IsInstanceOfType<DailySummaryView>(shell.FindName("DailySummaryPage"));

            window.Close();
        }, TimeSpan.FromSeconds(30));
    }

    [TestMethod]
    public void SyntheticPreviewShellFallsBackToPlaceholderForGuardedDestinations()
    {
        WpfTestHost.Run(() =>
        {
            var shell = ShellView.CreateSyntheticPreview();
            var window = new Window { Content = shell, Width = 1366, Height = 768 };
            window.Show();
            window.UpdateLayout();

            Assert.AreEqual(1, shell.RetainedPageCount);
            Assert.AreEqual("OverviewPage", shell.ActivePageName);

            Assert.IsTrue(shell.NavigateTo("evaluation"));
            window.UpdateLayout();
            Assert.AreEqual(1, shell.RetainedPageCount);
            Assert.AreEqual("EvaluationPage", shell.ActivePageName);
            Assert.IsInstanceOfType<EvaluationView>(shell.FindName("EvaluationPage"));

            Assert.IsTrue(shell.NavigateTo("daily-summary"));
            window.UpdateLayout();
            Assert.AreEqual(1, shell.RetainedPageCount);
            Assert.AreEqual("DailySummaryPage", shell.ActivePageName);
            Assert.IsNull(shell.FindName("EvaluationPage"));
            Assert.IsInstanceOfType<DailySummaryView>(shell.FindName("DailySummaryPage"));

            Assert.IsTrue(shell.NavigateTo("live-organization"));
            window.UpdateLayout();
            Assert.AreEqual(0, shell.RetainedPageCount);
            Assert.IsNull(shell.ActivePageName);
            Assert.IsNull(shell.FindName("OverviewPage"));

            window.Close();
        }, TimeSpan.FromSeconds(30));
    }

    [TestMethod]
    public void QueuedGalleryLanguageCallbackIsIgnoredAfterResourcesAreReleased()
    {
        WpfTestHost.Run(() =>
        {
            var view = new WidgetGalleryView();
            var callback = typeof(WidgetGalleryView).GetMethod(
                "ApplyLanguageChange",
                System.Reflection.BindingFlags.Instance |
                System.Reflection.BindingFlags.NonPublic) ??
                throw new InvalidOperationException("Gallery language callback was not found.");

            view.ReleaseResources();
            callback.Invoke(view, [0]);

            Assert.IsTrue(view.ResourcesReleased);
        }, TimeSpan.FromSeconds(30));
    }

    [TestMethod]
    public void QueuedGalleryTitleCallbackIsIgnoredAfterWindowIsClosed()
    {
        WpfTestHost.Run(() =>
        {
            var window = new WidgetGalleryWindow();
            var callback = typeof(WidgetGalleryWindow).GetMethod(
                "RefreshTitle",
                System.Reflection.BindingFlags.Instance |
                System.Reflection.BindingFlags.NonPublic) ??
                throw new InvalidOperationException("Gallery title callback was not found.");
            window.Show();

            window.Close();
            callback.Invoke(window, [0]);

            Assert.IsTrue(window.ResourcesReleased);
            Assert.IsTrue(window.GalleryView.ResourcesReleased);
        }, TimeSpan.FromSeconds(30));
    }
}
