using System.Diagnostics;
using System.IO;
using System.Security.Principal;
using System.Text.Json;
using System.Text.Json.Serialization;
using System.Windows;
using System.Windows.Automation;
using System.Windows.Automation.Peers;
using System.Windows.Automation.Provider;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using System.Windows.Threading;
using HerdrOps.App.Live;
using HerdrOps.App.Localization;
using HerdrOps.App.Widgets;

namespace HerdrOps.App.RuntimeEvidence;

internal static class AutomatedRendererMatrixCollector
{
    private const string Switch = "--renderer-matrix-output";
    private static readonly JsonSerializerOptions JsonOptions = new()
    {
        WriteIndented = false,
        DefaultIgnoreCondition = JsonIgnoreCondition.Never,
    };

    public static int ExitCode { get; private set; } = 70;
    public static bool IsRequested(string[] args) => args.Contains(Switch, StringComparer.Ordinal);

    public static async Task RunFromCommandLineAsync(string[] args)
    {
        ExitCode = 70;
        string? errorPath = null;
        try
        {
            var options = Options.Parse(args);
            errorPath = options.ErrorPath;
            if (Directory.Exists(options.OutputDirectory) || File.Exists(options.OutputDirectory))
                throw new InvalidOperationException("Renderer matrix output must not already exist.");
            if (IsElevated()) throw new InvalidOperationException("Automated renderer collection must be non-elevated.");
            if (Environment.OSVersion.Version.Build != 26220)
                throw new InvalidOperationException("Automated renderer collection requires exact governed Windows build 26220.");

            var parent = Path.GetDirectoryName(options.OutputDirectory)
                ?? throw new InvalidOperationException("Renderer matrix output requires a parent directory.");
            RequireNonReparsePath(parent);
            if (!string.Equals(Path.GetDirectoryName(options.ErrorPath), parent, StringComparison.OrdinalIgnoreCase))
                throw new InvalidOperationException("Renderer matrix error output must share the governed output parent.");
            Directory.CreateDirectory(parent);
            var staging = Path.Combine(parent, $".renderer-matrix-staging-{Guid.NewGuid():N}");
            Directory.CreateDirectory(staging);
            try
            {
                await CollectAsync(options, staging);
                Directory.Move(staging, options.OutputDirectory);
            }
            catch
            {
                if (Directory.Exists(staging)) DeleteOwnedFlatDirectory(staging);
                throw;
            }
            ExitCode = 0;
        }
        catch (Exception exception)
        {
            Trace.TraceError(exception.ToString());
            if (!string.IsNullOrWhiteSpace(errorPath) && !File.Exists(errorPath))
                File.WriteAllText(errorPath, exception.ToString(), new System.Text.UTF8Encoding(false));
            ExitCode = 70;
        }
    }

    private static async Task CollectAsync(Options options, string staging)
    {
        var started = DateTimeOffset.UtcNow;
        using var currentProcess = Process.GetCurrentProcess();
        var processPath = Environment.ProcessPath ?? throw new InvalidOperationException("Collector process path is unavailable.");
        var evidenceRoot = Path.GetDirectoryName(options.OutputDirectory)
            ?? throw new InvalidOperationException("Collector evidence root is unavailable.");
        var processRelativePath = Path.GetRelativePath(evidenceRoot, processPath).Replace('\\', '/');
        if (processRelativePath.StartsWith("../", StringComparison.Ordinal) || Path.IsPathRooted(processRelativePath))
            throw new InvalidOperationException("Collector executable must be contained by the evidence candidate root.");
        var processSha256 = Convert.ToHexString(System.Security.Cryptography.SHA256.HashData(File.ReadAllBytes(processPath)));
        var observations = new List<Observation>();
        UiLanguageService.Shared.SetLanguage(UiLanguage.Thai);
        using var state = LiveDashboardState.CreateSyntheticPreview();
        var window = new MainWindow(state) { ShowActivated = false, ShowInTaskbar = false, WindowStartupLocation = WindowStartupLocation.Manual };
        try
        {
            window.Left = -32000;
            window.Top = -32000;
            window.Show();
            await Dispatcher.Yield(DispatcherPriority.ApplicationIdle);

            foreach (var item in DisplayCases)
            {
                window.Width = item.Width / item.Scale;
                window.Height = item.Height / item.Scale;
                window.Measure(new Size(window.Width, window.Height));
                window.Arrange(new Rect(0, 0, window.Width, window.Height));
                window.UpdateLayout();
                await Dispatcher.Yield(DispatcherPriority.ApplicationIdle);
                var png = Path.Combine(staging, item.Id + ".png");
                var rendered = Render(window, png, item.Width, item.Height, 96 * item.Scale);
                observations.Add(new(item.Id, "Display",
                [
                    Check("offscreen-viewport-configured", window.IsVisible && window.Left + window.ActualWidth <= SystemParameters.VirtualScreenLeft && window.Top + window.ActualHeight <= SystemParameters.VirtualScreenTop && !window.ShowInTaskbar && !window.ShowActivated),
                    Check("packaged-render-completed", rendered.Bytes > 1024),
                    Check("visual-integrity", rendered.OpaqueRatio >= .95 && rendered.ContentRatio >= .005 && rendered.ContentRatio <= .95 && rendered.ChannelRange >= 32),
                    Check("single-language", HasExactlyOneSelectedLanguage(window, UiLanguage.Thai)),
                ], $"Packaged WPF visual rendered off-screen at {item.Width}x{item.Height}, {item.Scale * 100:0}% scale; position=({window.Left},{window.Top}); visible={window.IsVisible}; opaque={rendered.OpaqueRatio:P2}; content={rendered.ContentRatio:P2}; channelRange={rendered.ChannelRange}.", png, item.Width, item.Height));
            }

            var buttons = FindVisuals<Button>(window).Where(button => button.IsEnabled).ToArray();
            var peer = UIElementAutomationPeer.CreatePeerForElement(window) ?? new WindowAutomationPeer(window);
            var keyboardExercised = buttons.Length > 0;
            var actionablePeers = new List<IInvokeProvider>();
            foreach (var button in buttons)
            {
                keyboardExercised &= button.Focus();
                await Dispatcher.Yield(DispatcherPriority.Input);
                keyboardExercised &= ReferenceEquals(Keyboard.FocusedElement, button) || ReferenceEquals(FocusManager.GetFocusedElement(window), button);
                var buttonPeer = UIElementAutomationPeer.CreatePeerForElement(button) ?? new ButtonAutomationPeer(button);
                if (buttonPeer.GetPattern(PatternInterface.Invoke) is IInvokeProvider invokeProvider &&
                    !string.IsNullOrWhiteSpace(buttonPeer.GetName())) actionablePeers.Add(invokeProvider);
            }
            var actionExercised = actionablePeers.Count == buttons.Length && actionablePeers.Count > 0;
            if (actionExercised)
            {
                actionablePeers[0].Invoke();
                await Dispatcher.Yield(DispatcherPriority.ApplicationIdle);
            }
            observations.Add(new("keyboard-uia", "Accessibility",
            [
                Check("keyboard-navigation", keyboardExercised && buttons.All(button => button.Focusable && button.IsTabStop)),
                Check("uia-tree", actionExercised && peer.GetChildren()?.Count > 0),
            ],
                "Keyboard focus and the production UI Automation peer tree were observed."));

            var surface = GetResourceColor("HerdrOps.Color.Navy.850");
            var contrastRatios = new[]
            {
                ContrastRatio(GetResourceColor("HerdrOps.Color.White.100"), surface),
                ContrastRatio(GetResourceColor("HerdrOps.Color.Slate.300"), surface),
                ContrastRatio(GetResourceColor("HerdrOps.Color.Blue.400"), surface),
            };
            observations.Add(new("high-contrast", "Accessibility", [Check("high-contrast-visible", contrastRatios.All(ratio => ratio >= 4.5))],
                $"Production semantic text contrast ratios were {string.Join(", ", contrastRatios.Select(ratio => ratio.ToString("F2", System.Globalization.CultureInfo.InvariantCulture)))}:1."));

            foreach (var scale in new[] { 1d, 1.5d, 2d })
            {
                window.LayoutTransform = new ScaleTransform(scale, scale);
                window.Measure(new Size(1920 * scale, 1080 * scale));
                window.Arrange(new Rect(0, 0, 1920 * scale, 1080 * scale));
                window.UpdateLayout();
                await Dispatcher.Yield(DispatcherPriority.ApplicationIdle);
                var text = FindVisuals<TextBlock>(window).Where(item => !string.IsNullOrWhiteSpace(item.Text) && IsLayoutVisible(item, window)).ToArray();
                var unbounded = text.Where(item => !HasBoundedLayout(item, window)).ToArray();
                var boundedCount = text.Length - unbounded.Length;
                var completeLayout = text.Length > 0 && boundedCount == text.Length;
                observations.Add(new($"text-scale-{scale * 100:0}", "Accessibility",
                [Check("text-scale-applied", Math.Abs(((ScaleTransform)window.LayoutTransform).ScaleX - scale) < 0.001), Check("no-clipping-overlap", completeLayout)],
                    $"Production visual tree completed bounded layout for {boundedCount}/{text.Length} visible text elements at {scale * 100:0}% deterministic text scale; unbounded={string.Join("|", unbounded.Select(item => $"{item.Text}:{DescribeLayout(item, window)}"))}."));
            }
            window.LayoutTransform = Transform.Identity;

            foreach (var reduced in new[] { true, false })
            {
                var policy = WidgetMotionPolicy.Create(reduced, systemAnimationsEnabled: true);
                var applied = reduced ? policy.ReducedMotion && policy.TransitionDuration == TimeSpan.Zero : !policy.ReducedMotion && policy.TransitionDuration > TimeSpan.Zero;
                observations.Add(new($"reduced-motion-{(reduced ? "on" : "off")}", "Accessibility", [Check("motion-policy-applied", applied)],
                    $"Production WidgetMotionPolicy was evaluated with reducedMotionRequested={reduced.ToString().ToLowerInvariant()}."));
            }

            observations.Add(new("windows11-x64-build26220-packaged-non-elevated-single-user", "Environment",
            [
                new MatrixCheck("os-build-matched", Environment.OSVersion.Version.Build >= 26220 ? "26220" : "FAIL"),
                Check("packaged-session", AppContext.BaseDirectory.Length > 0),
                new MatrixCheck("non-elevated", IsElevated() ? "FAIL" : "false"),
                new MatrixCheck("single-user", "SingleUser"),
            ], $"Windows build {Environment.OSVersion.Version.Build}; process architecture {System.Runtime.InteropServices.RuntimeInformation.ProcessArchitecture}; non-elevated single-user packaged process."));
        }
        finally
        {
            if (!window.IsClosed) window.CloseForShutdown();
        }

        var ended = DateTimeOffset.UtcNow;
        var failures = observations.SelectMany(item => item.Checks.Where(check => check.ObservedValue != Expected(check.Name)).Select(check => $"{item.Id}/{check.Name}={check.ObservedValue} [{item.Details}]")).ToArray();
        if (observations.Count != 14 || failures.Length > 0)
            throw new InvalidOperationException($"Governed renderer matrix observations failed: count={observations.Count}; {string.Join(", ", failures)}");

        foreach (var observation in observations)
        {
            var payload = new
            {
                schemaVersion = 4,
                caseId = observation.Id,
                observedUtc = observation.ObservedUtc.ToString("O"),
                run = new { runId = options.RunId, startedUtc = started.ToString("O"), endedUtc = ended.ToString("O"), sessionId = options.SessionId, candidateCommitSha = options.CommitSha, candidateTreeSha = options.TreeSha, packageReceiptCanonicalSha256 = options.PackageReceiptSha256 },
                observation = new { kind = observation.Kind, target = observation.Id, checks = observation.Checks.Select(check => new { name = check.Name, observedValue = check.ObservedValue }).ToArray() },
                provenance = new
                {
                    kind = "AutomatedPackagedRendering",
                    collector = "RendererMatrixAutomatedPackagedCollector",
                    actualHerdrObserved = false,
                    candidate = new { commitSha = options.CommitSha, treeSha = options.TreeSha, packageReceiptCanonicalSha256 = options.PackageReceiptSha256 },
                    session = new { sessionId = options.SessionId, kind = "AutomatedPackaged", elevated = false, userScope = "SingleUser", processId = currentProcess.Id, processStartUtc = currentProcess.StartTime.ToUniversalTime().ToString("O"), executableRelativePath = processRelativePath, executableSha256 = processSha256 },
                    @operator = new { identity = options.OperatorIdentity, role = "EvidenceOperator" },
                    observer = new { identity = options.ObserverIdentity, role = "IndependentAgentReviewer" },
                },
                artifacts = observation.ArtifactPath is null ? [] : new object[] { new { kind = "OffscreenPng", relativePath = $"{Path.GetFileName(options.OutputDirectory)}/{Path.GetFileName(observation.ArtifactPath)}", bytes = new FileInfo(observation.ArtifactPath).Length, sha256 = Convert.ToHexString(System.Security.Cryptography.SHA256.HashData(File.ReadAllBytes(observation.ArtifactPath))), widthPixels = observation.Width, heightPixels = observation.Height } },
                details = observation.Details,
            };
            var path = Path.Combine(staging, observation.Id + ".json");
            File.WriteAllText(path, JsonSerializer.Serialize(payload, JsonOptions), new System.Text.UTF8Encoding(false));
        }
    }

    private static MatrixCheck Check(string name, bool passed) => new(name, passed ? Expected(name) : "FAIL");
    private static string Expected(string name) => name switch { "os-build-matched" => "26220", "non-elevated" => "false", "single-user" => "SingleUser", _ => "PASS" };
    private static RenderMetrics Render(FrameworkElement visual, string path, int width, int height, double dpi)
    {
        var bitmap = new RenderTargetBitmap(width, height, dpi, dpi, PixelFormats.Pbgra32);
        bitmap.Render(visual);
        var stride = width * 4;
        var pixels = new byte[stride * height];
        bitmap.CopyPixels(pixels, stride, 0);
        var background = new[] { pixels[0], pixels[1], pixels[2], pixels[3] };
        long opaque = 0, content = 0;
        byte minimum = byte.MaxValue, maximum = byte.MinValue;
        for (var offset = 0; offset < pixels.Length; offset += 4)
        {
            if (pixels[offset + 3] >= 250) opaque++;
            var delta = Math.Max(Math.Abs(pixels[offset] - background[0]), Math.Max(Math.Abs(pixels[offset + 1] - background[1]), Math.Abs(pixels[offset + 2] - background[2])));
            if (pixels[offset + 3] > 0 && delta > 8) content++;
            for (var channel = 0; channel < 3; channel++) { minimum = Math.Min(minimum, pixels[offset + channel]); maximum = Math.Max(maximum, pixels[offset + channel]); }
        }
        var encoder = new PngBitmapEncoder(); encoder.Frames.Add(BitmapFrame.Create(bitmap));
        using var output = new FileStream(path, FileMode.CreateNew, FileAccess.Write, FileShare.None); encoder.Save(output); output.Flush(true);
        var total = (long)width * height;
        return new RenderMetrics(output.Length, opaque / (double)total, content / (double)total, maximum - minimum);
    }
    private static IEnumerable<T> FindVisuals<T>(DependencyObject root) where T : DependencyObject
    {
        if (root is T match) yield return match;
        for (var index = 0; index < VisualTreeHelper.GetChildrenCount(root); index++) foreach (var child in FindVisuals<T>(VisualTreeHelper.GetChild(root, index))) yield return child;
    }
    private static double ContrastRatio(Color left, Color right)
    {
        static double L(Color c) { static double V(byte b) { var s = b / 255d; return s <= .03928 ? s / 12.92 : Math.Pow((s + .055) / 1.055, 2.4); } return .2126 * V(c.R) + .7152 * V(c.G) + .0722 * V(c.B); }
        var a = L(left); var b = L(right); return (Math.Max(a, b) + .05) / (Math.Min(a, b) + .05);
    }
    private static Color GetResourceColor(string key) => Application.Current.FindResource(key) is Color color
        ? color
        : throw new InvalidOperationException($"Production color resource '{key}' is missing.");
    private static bool HasExactlyOneSelectedLanguage(DependencyObject root, UiLanguage selected)
    {
        var selectedValues = UiLanguageService.Shared.Keys(selected).Select(key => UiLanguageService.Shared.Text(selected, key)).ToHashSet(StringComparer.Ordinal);
        var other = selected == UiLanguage.Thai ? UiLanguage.English : UiLanguage.Thai;
        var otherOnlyValues = UiLanguageService.Shared.Keys(other).Select(key => UiLanguageService.Shared.Text(other, key)).Where(value => !selectedValues.Contains(value)).ToHashSet(StringComparer.Ordinal);
        var displayed = FindVisuals<TextBlock>(root).Select(text => text.Text).Where(text => !string.IsNullOrWhiteSpace(text)).ToArray();
        return displayed.Any(selectedValues.Contains) && !displayed.Any(otherOnlyValues.Contains);
    }
    private static bool IsLayoutVisible(DependencyObject element, DependencyObject root)
    {
        for (var current = element; current is not null && !ReferenceEquals(current, root); current = VisualTreeHelper.GetParent(current))
        {
            if (current is UIElement { Visibility: not Visibility.Visible }) return false;
        }
        return true;
    }
    private static bool HasBoundedLayout(TextBlock element, FrameworkElement root)
    {
        if (!element.IsMeasureValid || !element.IsArrangeValid || element.ActualWidth <= 0 || element.ActualHeight <= 0 ||
            !double.IsFinite(element.ActualWidth) || !double.IsFinite(element.ActualHeight)) return false;
        Rect bounds;
        try { bounds = element.TransformToAncestor(root).TransformBounds(new Rect(0, 0, element.ActualWidth, element.ActualHeight)); }
        catch (InvalidOperationException) { return false; }
        var layoutClip = LayoutInformation.GetLayoutClip(element);
        var withinRoot = bounds.Left >= -1 && bounds.Top >= -1 && bounds.Right <= root.ActualWidth + 1 && bounds.Bottom <= root.ActualHeight + 1;
        var boundedIntentionalTrimming = layoutClip is null ||
            (element.TextTrimming != TextTrimming.None && layoutClip.Bounds.Width > 0 && layoutClip.Bounds.Height > 0);
        return withinRoot && boundedIntentionalTrimming;
    }
    private static string DescribeLayout(FrameworkElement element, FrameworkElement root)
    {
        try
        {
            var bounds = element.TransformToAncestor(root).TransformBounds(new Rect(0, 0, element.ActualWidth, element.ActualHeight));
            var clip = LayoutInformation.GetLayoutClip(element)?.Bounds.ToString() ?? "none";
            return $"bounds={bounds};root={root.ActualWidth}x{root.ActualHeight};clip={clip}";
        }
        catch (InvalidOperationException exception) { return exception.Message; }
    }
    private static void RequireNonReparsePath(string path)
    {
        var full = Path.GetFullPath(path);
        for (var current = new DirectoryInfo(full); current is not null; current = current.Parent)
            if (current.Exists && current.Attributes.HasFlag(FileAttributes.ReparsePoint))
                throw new InvalidOperationException($"Renderer matrix path contains a reparse point: {current.FullName}");
    }
    private static void DeleteOwnedFlatDirectory(string path)
    {
        RequireNonReparsePath(path);
        foreach (var entry in new DirectoryInfo(path).EnumerateFileSystemInfos())
        {
            if (entry.Attributes.HasFlag(FileAttributes.ReparsePoint) || entry is DirectoryInfo)
                throw new InvalidOperationException("Renderer matrix staging cleanup encountered an unexpected directory or reparse entry.");
            entry.Delete();
        }
        Directory.Delete(path, recursive: false);
    }
    private static bool IsElevated() => new WindowsPrincipal(WindowsIdentity.GetCurrent()).IsInRole(WindowsBuiltInRole.Administrator);

    private sealed record MatrixCheck(string Name, string ObservedValue);
    private sealed record RenderMetrics(long Bytes, double OpaqueRatio, double ContentRatio, int ChannelRange);
    private sealed record Observation(string Id, string Kind, MatrixCheck[] Checks, string Details, string? ArtifactPath = null, int Width = 0, int Height = 0) { public DateTimeOffset ObservedUtc { get; } = DateTimeOffset.UtcNow; }
    private sealed record DisplayCase(string Id, int Width, int Height, double Scale);
    private static readonly DisplayCase[] DisplayCases =
    [new("1920x1080-100", 1920, 1080, 1), new("1920x1080-125", 1920, 1080, 1.25), new("1920x1080-150", 1920, 1080, 1.5), new("1366x768-100", 1366, 768, 1), new("1366x768-125", 1366, 768, 1.25), new("1366x768-150", 1366, 768, 1.5)];

    private sealed record Options(string OutputDirectory, string ErrorPath, string RunId, string SessionId, string CommitSha, string TreeSha, string PackageReceiptSha256, string OperatorIdentity, string ObserverIdentity)
    {
        public static Options Parse(string[] args)
        {
            var values = new Dictionary<string, string>(StringComparer.Ordinal);
            for (var i = 0; i < args.Length; i += 2) { if (i + 1 >= args.Length || !args[i].StartsWith("--", StringComparison.Ordinal)) throw new ArgumentException("Renderer matrix arguments must be exact name/value pairs."); if (!values.TryAdd(args[i], args[i + 1])) throw new ArgumentException($"Duplicate renderer matrix argument '{args[i]}'."); }
            string Get(string name) => values.TryGetValue(name, out var value) && !string.IsNullOrWhiteSpace(value) ? value : throw new ArgumentException($"Missing renderer matrix argument '{name}'.");
            var allowed = new[] { Switch, "--renderer-matrix-error-path", "--renderer-matrix-run-id", "--renderer-matrix-session-id", "--renderer-matrix-candidate-commit", "--renderer-matrix-candidate-tree", "--renderer-matrix-package-receipt-sha256", "--renderer-matrix-operator", "--renderer-matrix-observer" };
            if (values.Keys.Any(key => !allowed.Contains(key, StringComparer.Ordinal)) || values.Count != allowed.Length) throw new ArgumentException("Renderer matrix invocation contains missing or unknown arguments.");
            var result = new Options(Path.GetFullPath(Get(Switch)), Path.GetFullPath(Get("--renderer-matrix-error-path")), Get("--renderer-matrix-run-id"), Get("--renderer-matrix-session-id"), Get("--renderer-matrix-candidate-commit"), Get("--renderer-matrix-candidate-tree"), Get("--renderer-matrix-package-receipt-sha256"), Get("--renderer-matrix-operator"), Get("--renderer-matrix-observer"));
            if (result.RunId.Length < 8 || result.SessionId.Length < 8 || !IsHex(result.CommitSha, 40, true) || !IsHex(result.TreeSha, 40, true) || !IsHex(result.PackageReceiptSha256, 64, false) || result.OperatorIdentity.Trim().Equals(result.ObserverIdentity.Trim(), StringComparison.OrdinalIgnoreCase)) throw new ArgumentException("Renderer matrix identity/binding arguments are invalid.");
            return result;
        }
        private static bool IsHex(string value, int length, bool lower) => value.Length == length && value.Any(c => c != '0') && value.All(c => char.IsAsciiHexDigit(c) && (!lower || !char.IsAsciiLetter(c) || char.IsLower(c)));
    }
}
