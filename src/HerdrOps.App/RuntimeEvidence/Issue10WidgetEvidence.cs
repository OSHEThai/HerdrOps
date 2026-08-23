using System.IO;
using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using Microsoft.Win32.SafeHandles;

namespace HerdrOps.App.RuntimeEvidence;

public sealed record Issue10ProductionAuthorityFile(
    string Path,
    string Sha256);

public sealed record Issue10ProductionAuthoritySource(
    string CommitSha,
    string TreeSha);

public sealed record Issue10ProductionAuthorityPackage(
    Issue10ProductionAuthorityFile Identity,
    string IdentityReceiptSha256,
    Issue10ProductionAuthorityFile Archive,
    Issue10ProductionAuthorityFile Manifest,
    Issue10ProductionAuthorityFile App,
    Issue10ProductionAuthorityFile Core);

public sealed record Issue10ProductionAuthorityPerformance(
    Issue10ProductionAuthorityFile Receipt,
    Issue10ProductionAuthorityFile RawSource);

public sealed record Issue10ProductionAuthorityRuntime(
    Issue10ProductionAuthorityFile HerdrExecutable,
    string ControlSessionIdentity,
    string TargetSessionIdentity);

public sealed record Issue10ProductionAuthorityBoundary(
    string Runtime,
    string Human,
    string Release,
    bool CreditGranted);

public sealed record Issue10ProductionAuthority(
    int SchemaVersion,
    string EvidenceClassification,
    int Issue,
    string EvidenceRoot,
    string RunNonce,
    DateTimeOffset EvidenceStartedUtc,
    Issue10ProductionAuthoritySource Source,
    Issue10ProductionAuthorityFile GateReport,
    Issue10ProductionAuthorityFile CoreRuntimeReport,
    Issue10ProductionAuthorityPackage Package,
    Issue10ProductionAuthorityPerformance Performance,
    Issue10ProductionAuthorityFile SoakReceipt,
    Issue10ProductionAuthorityRuntime Runtime,
    Issue10ProductionAuthorityBoundary EvidenceBoundary);

public sealed record Issue10WidgetSource(
    string CommitSha,
    string TreeSha);

public sealed record Issue10WidgetBindings(
    string GateReportSha256,
    string AppRuntimeReportSha256,
    string CoreRuntimeReportSha256,
    string PackageIdentityFileSha256,
    string PackageIdentityReceiptSha256,
    string PackageArchiveSha256,
    string PackageManifestSha256,
    string AppSha256,
    string CoreSha256,
    string HerdrExecutableSha256,
    string PerformanceReceiptSha256,
    string SoakReceiptSha256,
    string ControlSessionIdentity,
    string TargetSessionIdentity);

public sealed record Issue10WidgetChronology(
    DateTimeOffset RuntimeStartUtc,
    DateTimeOffset DashboardObservedUtc,
    DateTimeOffset WidgetObservedUtc,
    DateTimeOffset CapturedUtc,
    long StateSequence);

public sealed record Issue10DashboardCapture(
    string StateSha256,
    string CapturePath,
    long CaptureBytes,
    string CaptureSha256);

public sealed record Issue10WidgetCapture(
    string Name,
    string StateSha256,
    string SourceStateSha256,
    string CapturePath,
    long CaptureBytes,
    string CaptureSha256);

public sealed record Issue10AttentionCapture(
    string Name,
    string Status,
    string SemanticFingerprint,
    string CapturePath,
    long CaptureBytes,
    string CaptureSha256);

public sealed record Issue10WidgetUnknownPolicy(
    bool UnknownDataRendersUnknown,
    bool OfflineDataRendersUnknown,
    string UnknownState,
    string OfflineState,
    bool NoSyntheticSuccess,
    int SyntheticFieldsCount);

public sealed record Issue10WidgetObservation(
    int SchemaVersion,
    string EvidenceClassification,
    int Issue,
    string Language,
    string RunNonce,
    Issue10WidgetSource Source,
    Issue10WidgetBindings Bindings,
    Issue10WidgetChronology Chronology,
    Issue10DashboardCapture Dashboard,
    IReadOnlyList<Issue10WidgetCapture> Widgets,
    IReadOnlyList<Issue10AttentionCapture> AttentionStates,
    Issue10WidgetUnknownPolicy UnknownPolicy);

public static class Issue10WidgetEvidenceProducer
{
    private const long MaximumManifestBytes = 4 * 1024 * 1024;
    private const long MaximumReceiptBytes = 16 * 1024 * 1024;
    private const long MaximumCaptureBytes = 128 * 1024 * 1024;
    private const long MaximumAuthorityArtifactBytes = 1024L * 1024 * 1024;
    private const string ExpectedEvidenceClassification = "Issue10ProductionBinding";
    private const string ExpectedWidgetClassification = "Issue10WidgetObservation";

    private static readonly JsonSerializerOptions ManifestSerializerOptions = new()
    {
        PropertyNameCaseInsensitive = false,
        AllowTrailingCommas = false,
        ReadCommentHandling = JsonCommentHandling.Disallow,
    };

    private static readonly JsonSerializerOptions ReceiptSerializerOptions = new()
    {
        WriteIndented = true,
    };

    private static readonly JsonSerializerOptions FingerprintSerializerOptions = new()
    {
        WriteIndented = false,
    };

    public static void Write(
        string outputPath,
        string bindingManifestPath,
        string appReportPath,
        string runNonce,
        string sourceCommit,
        string sourceTree,
        AppRuntimeEvidenceReport report)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(outputPath);
        ArgumentException.ThrowIfNullOrWhiteSpace(bindingManifestPath);
        ArgumentException.ThrowIfNullOrWhiteSpace(appReportPath);
        ArgumentException.ThrowIfNullOrWhiteSpace(runNonce);
        ArgumentException.ThrowIfNullOrWhiteSpace(sourceCommit);
        ArgumentException.ThrowIfNullOrWhiteSpace(sourceTree);
        ArgumentNullException.ThrowIfNull(report);

        var manifestLoad = LoadManifest(bindingManifestPath);
        var held = new List<HeldArtifact> { manifestLoad.Manifest };
        try
        {
            var authority = manifestLoad.Authority;
            ValidateInvocation(authority, report, runNonce, sourceCommit, sourceTree);

            var root = ResolveRoot(authority.EvidenceRoot, bindingManifestPath);
            var output = ResolveContainedPath(root, outputPath, "Issue #10 widget report output");
            var appReport = ResolveContainedPath(root, appReportPath, "Issue #10 App runtime report");
            if (string.Equals(output, appReport, StringComparison.OrdinalIgnoreCase))
            {
                throw new InvalidOperationException(
                    "Issue #10 widget report output must not overwrite the App runtime report.");
            }

            var authorityFiles = new Dictionary<string, HeldArtifact>(StringComparer.OrdinalIgnoreCase);
            HoldExpectedArtifact(held, authorityFiles, root, authority.GateReport, MaximumAuthorityArtifactBytes, "Issue #10 gate report");
            HoldExpectedArtifact(held, authorityFiles, root, authority.CoreRuntimeReport, MaximumAuthorityArtifactBytes, "Issue #10 Core runtime report");
            HoldExpectedArtifact(held, authorityFiles, root, authority.Package.Identity, MaximumAuthorityArtifactBytes, "Issue #10 package identity file");
            HoldExpectedArtifact(held, authorityFiles, root, authority.Package.Archive, MaximumAuthorityArtifactBytes, "Issue #10 package archive");
            HoldExpectedArtifact(held, authorityFiles, root, authority.Package.Manifest, MaximumAuthorityArtifactBytes, "Issue #10 package manifest");
            HoldExpectedArtifact(held, authorityFiles, root, authority.Package.App, MaximumAuthorityArtifactBytes, "Issue #10 package App component");
            HoldExpectedArtifact(held, authorityFiles, root, authority.Package.Core, MaximumAuthorityArtifactBytes, "Issue #10 package Core component");
            HoldExpectedArtifact(held, authorityFiles, root, authority.Performance.Receipt, MaximumAuthorityArtifactBytes, "Issue #10 performance receipt");
            HoldExpectedArtifact(held, authorityFiles, root, authority.Performance.RawSource, MaximumAuthorityArtifactBytes, "Issue #10 performance raw source");
            HoldExpectedArtifact(held, authorityFiles, root, authority.SoakReceipt, MaximumAuthorityArtifactBytes, "Issue #10 soak receipt");
            HoldExpectedArtifact(held, authorityFiles, root, authority.Runtime.HerdrExecutable, MaximumAuthorityArtifactBytes, "Issue #10 Herdr executable");
            var heldAppReport = HoldArtifact(held, appReport, MaximumReceiptBytes, retainBytes: false, "Issue #10 App runtime report");

            var captures = HoldCaptures(held, root, output, report);
            var observation = BuildObservation(
                authority,
                report,
                runNonce,
                sourceCommit,
                sourceTree,
                heldAppReport,
                authorityFiles,
                captures,
                output,
                root);

            foreach (var item in held)
            {
                item.Revalidate();
            }

            PublishNoClobber(output, observation);
            using var published = HeldArtifact.Open(output, MaximumReceiptBytes, retainBytes: false, "Issue #10 published widget report");
            foreach (var item in held)
            {
                item.Revalidate();
            }
            published.Revalidate();
        }
        finally
        {
            for (var index = held.Count - 1; index >= 0; index--)
            {
                held[index].Dispose();
            }
        }
    }

    public static void ValidateBindingManifest(string bindingManifestPath)
    {
        var loaded = LoadManifest(bindingManifestPath);
        loaded.Manifest.Dispose();
    }

    private static ManifestLoad LoadManifest(string path)
    {
        var fullPath = Path.GetFullPath(path);
        var manifest = HeldArtifact.Open(fullPath, MaximumManifestBytes, retainBytes: true, "Issue #10 binding manifest");
        try
        {
            using var document = JsonDocument.Parse(
                manifest.Bytes ?? throw new InvalidOperationException("Issue #10 binding manifest bytes were not retained."),
                new JsonDocumentOptions
                {
                    AllowTrailingCommas = false,
                    CommentHandling = JsonCommentHandling.Disallow,
                });
            ValidateManifestShape(document.RootElement);
            var authority = JsonSerializer.Deserialize<Issue10ProductionAuthority>(
                manifest.Bytes,
                ManifestSerializerOptions) ??
                throw new InvalidOperationException("Issue #10 binding manifest deserialized to null.");
            ValidateManifestValues(authority);
            return new ManifestLoad(authority, manifest);
        }
        catch
        {
            manifest.Dispose();
            throw;
        }
    }

    private static void ValidateManifestShape(JsonElement root)
    {
        RequireExactProperties(
            root,
            "Issue #10 binding manifest",
            "SchemaVersion", "EvidenceClassification", "Issue", "EvidenceRoot", "RunNonce",
            "EvidenceStartedUtc", "Source", "GateReport", "CoreRuntimeReport", "Package",
            "Performance", "SoakReceipt", "Runtime", "EvidenceBoundary");
        RequireExactProperties(root.GetProperty("Source"), "Issue #10 binding source", "CommitSha", "TreeSha");
        RequireArtifactShape(root.GetProperty("GateReport"), "Issue #10 gate report");
        RequireArtifactShape(root.GetProperty("CoreRuntimeReport"), "Issue #10 Core runtime report");
        RequireExactProperties(
            root.GetProperty("Package"),
            "Issue #10 package authority",
            "Identity", "IdentityReceiptSha256", "Archive", "Manifest", "App", "Core");
        foreach (var name in new[] { "Identity", "Archive", "Manifest", "App", "Core" })
        {
            RequireArtifactShape(root.GetProperty("Package").GetProperty(name), $"Issue #10 package {name}");
        }
        RequireExactProperties(root.GetProperty("Performance"), "Issue #10 performance authority", "Receipt", "RawSource");
        RequireArtifactShape(root.GetProperty("Performance").GetProperty("Receipt"), "Issue #10 performance receipt");
        RequireArtifactShape(root.GetProperty("Performance").GetProperty("RawSource"), "Issue #10 performance raw source");
        RequireArtifactShape(root.GetProperty("SoakReceipt"), "Issue #10 soak receipt");
        RequireExactProperties(
            root.GetProperty("Runtime"),
            "Issue #10 runtime authority",
            "HerdrExecutable", "ControlSessionIdentity", "TargetSessionIdentity");
        RequireArtifactShape(root.GetProperty("Runtime").GetProperty("HerdrExecutable"), "Issue #10 Herdr executable");
        RequireExactProperties(
            root.GetProperty("EvidenceBoundary"),
            "Issue #10 producer evidence boundary",
            "Runtime", "Human", "Release", "CreditGranted");
    }

    private static void RequireArtifactShape(JsonElement value, string context) =>
        RequireExactProperties(value, context, "Path", "Sha256");

    private static void RequireExactProperties(JsonElement value, string context, params string[] names)
    {
        if (value.ValueKind != JsonValueKind.Object)
        {
            throw new InvalidOperationException($"{context} must be a JSON object.");
        }

        var allowed = new HashSet<string>(names, StringComparer.Ordinal);
        var observed = new HashSet<string>(StringComparer.Ordinal);
        foreach (var property in value.EnumerateObject())
        {
            if (!allowed.Contains(property.Name))
            {
                throw new InvalidOperationException($"{context} contains unknown property '{property.Name}'.");
            }
            if (!observed.Add(property.Name))
            {
                throw new InvalidOperationException($"{context} contains duplicate property '{property.Name}'.");
            }
        }
        foreach (var name in names)
        {
            if (!observed.Contains(name))
            {
                throw new InvalidOperationException($"{context} is missing required property '{name}'.");
            }
        }
    }

    private static void ValidateManifestValues(Issue10ProductionAuthority authority)
    {
        if (string.IsNullOrWhiteSpace(authority.EvidenceRoot) ||
            authority.Source is null ||
            authority.GateReport is null ||
            authority.CoreRuntimeReport is null ||
            authority.Package is null ||
            authority.Performance is null ||
            authority.SoakReceipt is null ||
            authority.Runtime is null ||
            authority.EvidenceBoundary is null)
        {
            throw new InvalidOperationException("Issue #10 binding manifest contains a missing required authority object or evidence root.");
        }
        if (authority.SchemaVersion != 1 ||
            !string.Equals(authority.EvidenceClassification, ExpectedEvidenceClassification, StringComparison.Ordinal) ||
            authority.Issue != 10)
        {
            throw new InvalidOperationException("Issue #10 binding manifest identity is invalid.");
        }
        ValidateRunNonce(authority.RunNonce, "Issue #10 binding manifest RunNonce");
        ValidateCommit(authority.Source.CommitSha, "Issue #10 binding manifest source commit");
        ValidateCommit(authority.Source.TreeSha, "Issue #10 binding manifest source tree");
        ValidateSha(authority.Package.IdentityReceiptSha256, "Issue #10 package identity canonical SHA-256");
        foreach (var item in EnumerateManifestFiles(authority))
        {
            if (string.IsNullOrWhiteSpace(item.Path))
            {
                throw new InvalidOperationException("Issue #10 binding manifest contains an empty authority artifact path.");
            }
            ValidateSha(item.Sha256, item.Path);
        }
        if (authority.EvidenceStartedUtc == default || authority.EvidenceStartedUtc.Offset != TimeSpan.Zero)
        {
            throw new InvalidOperationException("Issue #10 binding manifest EvidenceStartedUtc must be a non-default UTC timestamp.");
        }
        if (string.IsNullOrWhiteSpace(authority.Runtime.ControlSessionIdentity) ||
            string.IsNullOrWhiteSpace(authority.Runtime.TargetSessionIdentity) ||
            authority.Runtime.ControlSessionIdentity is "NOT_OBSERVED" or "NOT CLAIMED" ||
            authority.Runtime.TargetSessionIdentity is "NOT_OBSERVED" or "NOT CLAIMED" ||
            string.Equals(
                authority.Runtime.ControlSessionIdentity,
                authority.Runtime.TargetSessionIdentity,
                StringComparison.Ordinal))
        {
            throw new InvalidOperationException("Issue #10 binding manifest must contain distinct non-placeholder session identities.");
        }
        if (!string.Equals(authority.EvidenceBoundary.Runtime, "NOT_OBSERVED", StringComparison.Ordinal) ||
            !string.Equals(authority.EvidenceBoundary.Human, "NOT_OBSERVED", StringComparison.Ordinal) ||
            !string.Equals(authority.EvidenceBoundary.Release, "NOT_OBSERVED", StringComparison.Ordinal) ||
            authority.EvidenceBoundary.CreditGranted)
        {
            throw new InvalidOperationException("Issue #10 production binding cannot grant Runtime, Human, Release, or credit.");
        }
    }

    private static IEnumerable<Issue10ProductionAuthorityFile> EnumerateManifestFiles(
        Issue10ProductionAuthority authority)
    {
        yield return authority.GateReport;
        yield return authority.CoreRuntimeReport;
        yield return authority.Package.Identity;
        yield return authority.Package.Archive;
        yield return authority.Package.Manifest;
        yield return authority.Package.App;
        yield return authority.Package.Core;
        yield return authority.Performance.Receipt;
        yield return authority.Performance.RawSource;
        yield return authority.SoakReceipt;
        yield return authority.Runtime.HerdrExecutable;
    }

    private static void ValidateInvocation(
        Issue10ProductionAuthority authority,
        AppRuntimeEvidenceReport report,
        string runNonce,
        string sourceCommit,
        string sourceTree)
    {
        ValidateRunNonce(runNonce, "Issue #10 invocation RunNonce");
        ValidateCommit(sourceCommit, "Issue #10 invocation source commit");
        ValidateCommit(sourceTree, "Issue #10 invocation source tree");
        if (!string.Equals(authority.RunNonce, runNonce, StringComparison.Ordinal) ||
            !string.Equals(authority.Source.CommitSha, sourceCommit, StringComparison.Ordinal) ||
            !string.Equals(authority.Source.TreeSha, sourceTree, StringComparison.Ordinal))
        {
            throw new InvalidOperationException("Issue #10 production widget evidence is not bound to this invocation and source.");
        }
        if (!string.Equals(report.EvidenceClassification, "RuntimeCandidate", StringComparison.Ordinal) ||
            !report.CoreStateObserved ||
            report.SessionControlInvoked ||
            !report.CompositeCandidateChecksPassed ||
            !report.LanguageStableThroughFinish ||
            !report.RendererEvidence.SoftwareOnlyThroughout)
        {
            throw new InvalidOperationException("Issue #10 production widget evidence requires a passing, exact-bound App RuntimeCandidate report.");
        }
        if (report.StartedUtc == default || report.FinishedUtc < report.StartedUtc ||
            report.StartedUtc < authority.EvidenceStartedUtc ||
            report.StartedUtc > DateTimeOffset.UtcNow.AddSeconds(30))
        {
            throw new InvalidOperationException("Issue #10 production widget evidence report chronology is outside the invocation window.");
        }
        if (report.ResourceMeasurement is null ||
            report.ResourceMeasurement.SampleCount <= 0 ||
            !report.ResourceMeasurement.CpuTargetPassed ||
            !report.ResourceMeasurement.WorkingSetTargetPassed ||
            report.WidgetLatencySamples < report.WidgetLatencyMinimumSamples ||
            report.WidgetLatencyP95Milliseconds is null ||
            !report.WidgetLatencyTargetPassed ||
            report.WidgetLatencyIncludedSamples.Count != report.WidgetLatencySamples)
        {
            throw new InvalidOperationException("Issue #10 production widget evidence rejects missing or failed resource/latency samples.");
        }
    }

    private static Dictionary<string, HeldArtifact> HoldCaptures(
        List<HeldArtifact> held,
        string root,
        string outputPath,
        AppRuntimeEvidenceReport report)
    {
        var reportDirectory = Path.GetDirectoryName(outputPath) ??
            throw new InvalidOperationException("Issue #10 widget report output has no parent directory.");
        var captures = new Dictionary<string, HeldArtifact>(StringComparer.OrdinalIgnoreCase);
        foreach (var capture in report.Captures)
        {
            var path = ResolveContainedPath(root, capture.Path, $"Issue #10 capture '{capture.Name}'");
            var relative = Path.GetRelativePath(reportDirectory, path);
            if (relative.StartsWith("..", StringComparison.Ordinal) || Path.IsPathRooted(relative))
            {
                throw new InvalidOperationException(
                    $"Issue #10 capture '{capture.Name}' must be under the widget report directory for contained verifier binding.");
            }
            var artifact = HoldArtifact(held, path, MaximumCaptureBytes, retainBytes: false, $"Issue #10 capture '{capture.Name}'");
            if (!string.Equals(artifact.Sha256, capture.Sha256, StringComparison.OrdinalIgnoreCase))
            {
                throw new InvalidOperationException($"Issue #10 capture '{capture.Name}' hash differs from the App report.");
            }
            if (!captures.TryAdd(Path.GetFileName(path), artifact))
            {
                throw new InvalidOperationException($"Issue #10 App report contains duplicate capture path '{path}'.");
            }
        }
        return captures;
    }

    private static Issue10WidgetObservation BuildObservation(
        Issue10ProductionAuthority authority,
        AppRuntimeEvidenceReport report,
        string runNonce,
        string sourceCommit,
        string sourceTree,
        HeldArtifact heldAppReport,
        IReadOnlyDictionary<string, HeldArtifact> authorityFiles,
        IReadOnlyDictionary<string, HeldArtifact> captures,
        string outputPath,
        string root)
    {
        var initial = report.SemanticStateCaptures.SingleOrDefault(
            capture => capture.Ordinal == 1 && string.Equals(capture.Phase, "initial", StringComparison.Ordinal)) ??
            throw new InvalidOperationException("Issue #10 App report is missing the initial semantic capture.");
        var dashboard = GetCapture(report, captures, "dashboard-overview");
        var compact = GetCapture(report, captures, "widget-compact");
        var normal = GetCapture(report, captures, "widget-normal");
        var floating = GetCapture(report, captures, "widget-floating-vertical");
        if (dashboard.StateSequence != initial.Sequence ||
            !string.Equals(dashboard.StateSha256, initial.NormalizedStateSha256, StringComparison.Ordinal))
        {
            throw new InvalidOperationException("Issue #10 Dashboard capture is not bound to the initial semantic state.");
        }

        var widgetCaptures = new[] { compact, normal, floating };
        if (widgetCaptures.Any(capture => capture.StateSequence != initial.Sequence ||
                                         !string.Equals(capture.StateSha256, initial.NormalizedStateSha256, StringComparison.Ordinal)))
        {
            throw new InvalidOperationException("Issue #10 Widget captures are not bound to the initial semantic state.");
        }

        var attentionStates = new[]
        {
            BuildAttentionState(report, captures, "Blocked"),
            BuildAttentionState(report, captures, "Done"),
        };
        if (string.Equals(attentionStates[0].SemanticFingerprint, attentionStates[1].SemanticFingerprint, StringComparison.Ordinal))
        {
            throw new InvalidOperationException("Issue #10 Blocked and Done attention fingerprints must remain distinct.");
        }

        var allObserved = new[]
        {
            dashboard.ObservedUtc,
            compact.ObservedUtc,
            normal.ObservedUtc,
            floating.ObservedUtc,
            attentionStates[0].ObservedUtc,
            attentionStates[1].ObservedUtc,
        };
        var widgetObservedUtc = new[] { compact.ObservedUtc, normal.ObservedUtc, floating.ObservedUtc }.Min();
        var capturedUtc = allObserved.Max();
        if (!(report.StartedUtc <= dashboard.ObservedUtc &&
              dashboard.ObservedUtc <= widgetObservedUtc &&
              widgetObservedUtc <= capturedUtc &&
              capturedUtc <= report.FinishedUtc))
        {
            throw new InvalidOperationException("Issue #10 widget chronology is not monotonic and report-bound.");
        }

        var artifact = authorityFiles;
        return new Issue10WidgetObservation(
            1,
            ExpectedWidgetClassification,
            10,
            report.Language,
            runNonce,
            new Issue10WidgetSource(sourceCommit, sourceTree),
            new Issue10WidgetBindings(
                artifact[ResolveContainedPath(root, authority.GateReport.Path, "Issue #10 gate report")].Sha256,
                heldAppReport.Sha256,
                artifact[ResolveContainedPath(root, authority.CoreRuntimeReport.Path, "Issue #10 Core runtime report")].Sha256,
                artifact[ResolveContainedPath(root, authority.Package.Identity.Path, "Issue #10 package identity file")].Sha256,
                authority.Package.IdentityReceiptSha256,
                artifact[ResolveContainedPath(root, authority.Package.Archive.Path, "Issue #10 package archive")].Sha256,
                artifact[ResolveContainedPath(root, authority.Package.Manifest.Path, "Issue #10 package manifest")].Sha256,
                artifact[ResolveContainedPath(root, authority.Package.App.Path, "Issue #10 package App component")].Sha256,
                artifact[ResolveContainedPath(root, authority.Package.Core.Path, "Issue #10 package Core component")].Sha256,
                artifact[ResolveContainedPath(root, authority.Runtime.HerdrExecutable.Path, "Issue #10 Herdr executable")].Sha256,
                artifact[ResolveContainedPath(root, authority.Performance.Receipt.Path, "Issue #10 performance receipt")].Sha256,
                artifact[ResolveContainedPath(root, authority.SoakReceipt.Path, "Issue #10 soak receipt")].Sha256,
                authority.Runtime.ControlSessionIdentity,
                authority.Runtime.TargetSessionIdentity),
            new Issue10WidgetChronology(
                report.StartedUtc,
                dashboard.ObservedUtc,
                widgetObservedUtc,
                capturedUtc,
                initial.Sequence),
            new Issue10DashboardCapture(
                dashboard.StateSha256,
                RelativeCapturePath(outputPath, dashboard.Path),
                dashboard.Length,
                dashboard.Sha256),
            widgetCaptures.Select(capture => new Issue10WidgetCapture(
                capture.Name switch
                {
                    "widget-compact" => "Compact",
                    "widget-normal" => "Normal",
                    "widget-floating-vertical" => "FloatingVertical",
                    _ => throw new InvalidOperationException($"Unexpected Issue #10 widget capture '{capture.Name}'."),
                },
                capture.StateSha256,
                capture.StateSha256,
                RelativeCapturePath(outputPath, capture.Path),
                capture.Length,
                capture.Sha256)).ToArray(),
            attentionStates.Select(state => new Issue10AttentionCapture(
                state.Status,
                state.Status,
                state.SemanticFingerprint,
                RelativeCapturePath(outputPath, state.Path),
                state.Length,
                state.Sha256)).ToArray(),
            new Issue10WidgetUnknownPolicy(
                UnknownDataRendersUnknown: true,
                OfflineDataRendersUnknown: true,
                UnknownState: "Unknown",
                OfflineState: "Offline",
                NoSyntheticSuccess: true,
                SyntheticFieldsCount: 0));
    }

    private static CaptureBinding GetCapture(
        AppRuntimeEvidenceReport report,
        IReadOnlyDictionary<string, HeldArtifact> captures,
        string name)
    {
        var capture = report.Captures.SingleOrDefault(
            item => string.Equals(item.Name, name, StringComparison.Ordinal)) ??
            throw new InvalidOperationException($"Issue #10 App report is missing capture '{name}'.");
        var path = Path.GetFullPath(capture.Path);
        var held = captures[Path.GetFileName(path)];
        return new CaptureBinding(capture.Name, path, held.Length, held.Sha256, capture.StateSequence, capture.StateSha256, capture.ObservedUtc);
    }

    private static AttentionBinding BuildAttentionState(
        AppRuntimeEvidenceReport report,
        IReadOnlyDictionary<string, HeldArtifact> captures,
        string status)
    {
        foreach (var semantic in report.SemanticStateCaptures.OrderBy(item => item.Ordinal))
        {
            foreach (var agent in semantic.SourceState.Agents.Where(
                         item => string.Equals(item.Status, status, StringComparison.Ordinal)))
            {
                var visual = semantic.BoundCaptures.FirstOrDefault(
                    item => captures.ContainsKey(item.FileName));
                if (visual is null)
                {
                    continue;
                }
                var path = Path.GetFullPath(report.Captures.Single(
                    item => string.Equals(Path.GetFileName(item.Path), visual.FileName, StringComparison.OrdinalIgnoreCase)).Path);
                var held = captures[Path.GetFileName(path)];
                var fingerprint = Convert.ToHexString(SHA256.HashData(
                    JsonSerializer.SerializeToUtf8Bytes(
                        new
                        {
                            agent.AgentIdentitySha256,
                            agent.WorkspaceIdentitySha256,
                            agent.TabIdentitySha256,
                            agent.PaneIdentitySha256,
                            agent.Status,
                            agent.Revision,
                            agent.StateChangeSequence,
                        },
                        FingerprintSerializerOptions)));
                return new AttentionBinding(
                    status,
                    fingerprint,
                    path,
                    held.Length,
                    held.Sha256,
                    semantic.ObservedUtc);
            }
        }
        throw new InvalidOperationException(
            $"Issue #10 production widget evidence requires an observed '{status}' Agent state bound to a real capture.");
    }

    private static string RelativeCapturePath(string outputPath, string capturePath)
    {
        var directory = Path.GetDirectoryName(outputPath) ??
            throw new InvalidOperationException("Issue #10 widget report output has no parent directory.");
        var relative = Path.GetRelativePath(directory, capturePath);
        if (relative.StartsWith("..", StringComparison.Ordinal) || Path.IsPathRooted(relative))
        {
            throw new InvalidOperationException("Issue #10 capture escaped the widget report directory.");
        }
        return relative.Replace(Path.DirectorySeparatorChar, '/');
    }

    private static string ResolveRoot(string root, string manifestPath)
    {
        var fullRoot = Path.GetFullPath(root);
        var manifestDirectory = Path.GetDirectoryName(Path.GetFullPath(manifestPath)) ??
            throw new InvalidOperationException("Issue #10 binding manifest has no parent directory.");
        if (!Directory.Exists(fullRoot))
        {
            throw new InvalidOperationException($"Issue #10 evidence root does not exist: {fullRoot}");
        }
        if (!IsContainedPath(fullRoot, manifestDirectory))
        {
            throw new InvalidOperationException("Issue #10 binding manifest must be inside its declared evidence root.");
        }
        return fullRoot;
    }

    private static string ResolveContainedPath(string root, string path, string context)
    {
        if (string.IsNullOrWhiteSpace(path))
        {
            throw new InvalidOperationException($"{context} path is empty.");
        }
        var candidate = Path.IsPathRooted(path) ? path : Path.Combine(root, path);
        var full = Path.GetFullPath(candidate);
        if (!IsContainedPath(root, full))
        {
            throw new InvalidOperationException($"{context} escaped the declared evidence root: {full}");
        }
        return full;
    }

    private static bool IsContainedPath(string root, string path)
    {
        var rootFull = Path.GetFullPath(root).TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar);
        var normalizedRoot = rootFull + Path.DirectorySeparatorChar;
        var normalizedPath = Path.GetFullPath(path);
        return string.Equals(normalizedPath.TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar), rootFull, StringComparison.OrdinalIgnoreCase) ||
               normalizedPath.StartsWith(normalizedRoot, StringComparison.OrdinalIgnoreCase);
    }

    private static void HoldExpectedArtifact(
        List<HeldArtifact> held,
        IDictionary<string, HeldArtifact> map,
        string root,
        Issue10ProductionAuthorityFile expected,
        long maximumBytes,
        string context)
    {
        var path = ResolveContainedPath(root, expected.Path, context);
        var artifact = HoldArtifact(held, path, maximumBytes, retainBytes: false, context);
        if (!artifact.Sha256.Equals(expected.Sha256, StringComparison.OrdinalIgnoreCase))
        {
            throw new InvalidOperationException($"{context} raw bytes do not match the authority manifest.");
        }
        if (!map.TryAdd(path, artifact))
        {
            throw new InvalidOperationException($"Issue #10 authority manifest aliases artifact path '{expected.Path}'.");
        }
    }

    private static HeldArtifact HoldArtifact(
        List<HeldArtifact> held,
        string path,
        long maximumBytes,
        bool retainBytes,
        string context)
    {
        var artifact = HeldArtifact.Open(path, maximumBytes, retainBytes, context);
        held.Add(artifact);
        return artifact;
    }

    private static void PublishNoClobber(string path, Issue10WidgetObservation observation)
    {
        var directory = Path.GetDirectoryName(path) ??
            throw new InvalidOperationException("Issue #10 widget report output has no parent directory.");
        Directory.CreateDirectory(directory);
        var temporary = Path.Combine(directory, $".{Path.GetFileName(path)}.{Guid.NewGuid():N}.tmp");
        try
        {
            var bytes = JsonSerializer.SerializeToUtf8Bytes(observation, ReceiptSerializerOptions)
                .Concat(new byte[] { (byte)'\r', (byte)'\n' })
                .ToArray();
            using (var stream = new FileStream(temporary, FileMode.CreateNew, FileAccess.Write, FileShare.None))
            {
                stream.Write(bytes, 0, bytes.Length);
                stream.Flush(flushToDisk: true);
            }
            File.Move(temporary, path);
        }
        catch (IOException exception) when (File.Exists(path))
        {
            throw new InvalidOperationException($"Issue #10 widget report publication refused to clobber '{path}'.", exception);
        }
        finally
        {
            if (File.Exists(temporary))
            {
                File.Delete(temporary);
            }
        }
    }

    private static void ValidateRunNonce(string value, string context)
    {
        if (string.IsNullOrEmpty(value) || value.Length != 32 || value.Any(character => !IsLowerHex(character)))
        {
            throw new InvalidOperationException($"{context} must be exactly 32 lowercase hexadecimal characters.");
        }
    }

    private static void ValidateCommit(string value, string context)
    {
        if (string.IsNullOrEmpty(value) || value.Length != 40 || value.Any(character => !IsLowerHex(character)))
        {
            throw new InvalidOperationException($"{context} must be exactly 40 lowercase hexadecimal characters.");
        }
    }

    private static void ValidateSha(string value, string context)
    {
        if (string.IsNullOrEmpty(value) || value.Length != 64 || value.Any(character => !Uri.IsHexDigit(character)))
        {
            throw new InvalidOperationException($"{context} must be a 64-character hexadecimal SHA-256.");
        }
    }

    private static bool IsLowerHex(char value) =>
        value is >= '0' and <= '9' or >= 'a' and <= 'f';

    private sealed record ManifestLoad(
        Issue10ProductionAuthority Authority,
        HeldArtifact Manifest);

    private sealed record CaptureBinding(
        string Name,
        string Path,
        long Length,
        string Sha256,
        long StateSequence,
        string StateSha256,
        DateTimeOffset ObservedUtc);

    private sealed record AttentionBinding(
        string Status,
        string SemanticFingerprint,
        string Path,
        long Length,
        string Sha256,
        DateTimeOffset ObservedUtc);

    private sealed class HeldArtifact : IDisposable
    {
        private HeldArtifact(
            string path,
            FileStream stream,
            long length,
            string sha256,
            FileIdentity identity,
            byte[]? bytes)
        {
            Path = path;
            Stream = stream;
            Length = length;
            Sha256 = sha256;
            Identity = identity;
            Bytes = bytes;
        }

        public string Path { get; }

        public FileStream Stream { get; }

        public long Length { get; }

        public string Sha256 { get; }

        public FileIdentity Identity { get; }

        public byte[]? Bytes { get; }

        public static HeldArtifact Open(string path, long maximumBytes, bool retainBytes, string context)
        {
            var fullPath = System.IO.Path.GetFullPath(path);
            if (!File.Exists(fullPath))
            {
                throw new InvalidOperationException($"{context} is missing: {fullPath}");
            }
            var stream = new FileStream(fullPath, FileMode.Open, FileAccess.Read, FileShare.Read);
            try
            {
                if (stream.Length > maximumBytes)
                {
                    throw new InvalidOperationException($"{context} exceeds its bounded size of {maximumBytes} bytes.");
                }
                var before = ReadIdentity(stream);
                byte[]? bytes = null;
                string sha256;
                if (retainBytes)
                {
                    if (stream.Length > int.MaxValue)
                    {
                        throw new InvalidOperationException($"{context} is too large to parse as a manifest.");
                    }
                    bytes = new byte[checked((int)stream.Length)];
                    ReadExactly(stream, bytes, context);
                    sha256 = Convert.ToHexString(SHA256.HashData(bytes));
                }
                else
                {
                    stream.Position = 0;
                    sha256 = Convert.ToHexString(SHA256.HashData(stream));
                }
                var after = ReadIdentity(stream);
                if (!before.Equals(after))
                {
                    throw new InvalidOperationException($"{context} changed while being read.");
                }
                return new HeldArtifact(fullPath, stream, after.Length, sha256, after, bytes);
            }
            catch
            {
                stream.Dispose();
                throw;
            }
        }

        public void Revalidate()
        {
            var current = ReadIdentity(Stream);
            if (!Identity.Equals(current))
            {
                throw new InvalidOperationException($"Held Issue #10 artifact identity changed: {Path}");
            }
            Stream.Position = 0;
            var currentSha = Convert.ToHexString(SHA256.HashData(Stream));
            if (!string.Equals(currentSha, Sha256, StringComparison.Ordinal))
            {
                throw new InvalidOperationException($"Held Issue #10 artifact bytes changed: {Path}");
            }
            var after = ReadIdentity(Stream);
            if (!Identity.Equals(after))
            {
                throw new InvalidOperationException($"Held Issue #10 artifact identity changed after hashing: {Path}");
            }
        }

        public void Dispose() => Stream.Dispose();

        private static void ReadExactly(FileStream stream, byte[] bytes, string context)
        {
            var offset = 0;
            while (offset < bytes.Length)
            {
                var read = stream.Read(bytes, offset, bytes.Length - offset);
                if (read <= 0)
                {
                    throw new InvalidOperationException($"{context} ended before its held byte count was read.");
                }
                offset += read;
            }
        }

        private static FileIdentity ReadIdentity(FileStream stream)
        {
            if (!GetFileInformationByHandle(stream.SafeFileHandle, out var information))
            {
                throw new InvalidOperationException(
                    $"GetFileInformationByHandle failed for held Issue #10 artifact with Win32 error {Marshal.GetLastWin32Error()}.");
            }
            var fileId = ((ulong)information.FileIndexHigh << 32) | information.FileIndexLow;
            var length = ((long)information.FileSizeHigh << 32) | information.FileSizeLow;
            return new FileIdentity(
                information.VolumeSerialNumber,
                fileId,
                information.NumberOfLinks,
                length);
        }
    }

    private readonly record struct FileIdentity(
        uint VolumeSerialNumber,
        ulong FileId,
        uint NumberOfLinks,
        long Length);

    [StructLayout(LayoutKind.Sequential)]
    private struct NativeFileInformation
    {
        public uint FileAttributes;
        public long CreationTime;
        public long LastAccessTime;
        public long LastWriteTime;
        public uint VolumeSerialNumber;
        public uint FileSizeHigh;
        public uint FileSizeLow;
        public uint NumberOfLinks;
        public uint FileIndexHigh;
        public uint FileIndexLow;
    }

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool GetFileInformationByHandle(
        SafeFileHandle handle,
        out NativeFileInformation fileInformation);
}
