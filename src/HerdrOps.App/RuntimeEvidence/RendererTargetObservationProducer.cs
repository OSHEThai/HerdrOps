using System.Buffers.Binary;
using System.Diagnostics;
using System.IO;
using System.IO.Pipes;
using System.Security.Cryptography;
using System.Runtime.InteropServices;
using System.Text;
using System.Text.Json;
using System.Text.RegularExpressions;
using System.Windows;
using System.Windows.Interop;
using System.Windows.Media.Imaging;
using Microsoft.Win32.SafeHandles;
using HerdrOps.App.Localization;

namespace HerdrOps.App.RuntimeEvidence;

public sealed record RendererTargetObservationOptions(
    string PipeName,
    string RuntimeEvidenceRoot,
    string CaptureDirectory,
    string RunNonce,
    string PackageIdentityPath,
    string PackageReceiptSha256,
    string SourceCommit,
    string SourceTree,
    int CoreProcessId,
    UiLanguage Language,
    string Challenge,
    int ServerProcessId,
    string ServerExecutablePath,
    string ServerExecutableSha256)
{
    private static readonly Regex PipePattern = new(
        "^[A-Za-z0-9_.-]{1,200}$",
        RegexOptions.CultureInvariant);
    private static readonly Regex LowerHex32 = new(
        "^[0-9a-f]{32}$",
        RegexOptions.CultureInvariant);
    private static readonly Regex LowerHex40 = new(
        "^[0-9a-f]{40}$",
        RegexOptions.CultureInvariant);
    private static readonly Regex UpperHex64 = new(
        "^[0-9A-F]{64}$",
        RegexOptions.CultureInvariant);

    public static bool TryCreate(
        string pipeName,
        string runtimeEvidenceRoot,
        string captureDirectory,
        string runNonce,
        string packageIdentityPath,
        string packageReceiptSha256,
        string sourceCommit,
        string sourceTree,
        int coreProcessId,
        UiLanguage language,
        string challenge,
        int serverProcessId,
        string serverExecutablePath,
        string serverExecutableSha256,
        out RendererTargetObservationOptions? options,
        out string? error)
    {
        options = null;
        error = null;
        if (!PipePattern.IsMatch(pipeName))
        {
            error = "Renderer observation pipe must be 1-200 ASCII letters, digits, '.', '_', or '-'.";
            return false;
        }

        if (!LowerHex32.IsMatch(runNonce) ||
            !UpperHex64.IsMatch(challenge) ||
            !UpperHex64.IsMatch(serverExecutableSha256) ||
            !UpperHex64.IsMatch(packageReceiptSha256) ||
            !LowerHex40.IsMatch(sourceCommit) ||
            !LowerHex40.IsMatch(sourceTree))
        {
            error = "Renderer observation bindings require a lowercase 32-hex nonce, uppercase 64-hex package receipt SHA-256, and lowercase 40-hex source commit/tree.";
            return false;
        }

        if (!string.Equals(
                pipeName,
                $"herdrops-v02-renderer-{runNonce}",
                StringComparison.Ordinal))
        {
            error = "Renderer observation pipe must be exactly bound to the one-time run nonce.";
            return false;
        }

        if (coreProcessId <= 0 || coreProcessId == Environment.ProcessId)
        {
            error = "Renderer observation Core PID must be positive and distinct from the App PID.";
            return false;
        }

        if (serverProcessId <= 0 || serverProcessId == Environment.ProcessId)
        {
            error = "Renderer observation server PID must be positive and distinct from the App PID.";
            return false;
        }

        if (language != UiLanguage.Thai)
        {
            error = "The one-pipe renderer protocol starts with the governed Thai capture phase.";
            return false;
        }

        try
        {
            var root = Path.GetFullPath(runtimeEvidenceRoot).TrimEnd(
                Path.DirectorySeparatorChar,
                Path.AltDirectorySeparatorChar);
            var captures = Path.GetFullPath(captureDirectory);
            var identityPath = Path.GetFullPath(packageIdentityPath);
            var serverPath = Path.GetFullPath(serverExecutablePath);
            if (!RendererTargetObservationPath.IsContained(root, captures))
            {
                error = "Renderer capture directory must be confined below the runtime evidence root.";
                return false;
            }
            if (!string.Equals(
                    captures.TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar),
                    Path.Combine(root, "captures", "Thai"),
                    StringComparison.OrdinalIgnoreCase))
            {
                error = "The one-pipe renderer protocol requires --capture-directory to be <runtime-root>/captures/Thai.";
                return false;
            }

            options = new RendererTargetObservationOptions(
                pipeName,
                root,
                captures,
                runNonce,
                identityPath,
                packageReceiptSha256,
                sourceCommit,
                sourceTree,
                coreProcessId,
                language,
                challenge,
                serverProcessId,
                serverPath,
                serverExecutableSha256);
            return true;
        }
        catch (Exception exception) when (
            exception is ArgumentException or NotSupportedException or PathTooLongException)
        {
            error = $"Renderer observation paths are invalid: {exception.Message}";
            return false;
        }
    }
}

internal static class RendererTargetObservationPath
{
    internal static bool IsContained(string root, string candidate)
    {
        var rootFull = Path.GetFullPath(root).TrimEnd(
            Path.DirectorySeparatorChar,
            Path.AltDirectorySeparatorChar);
        var candidateFull = Path.GetFullPath(candidate);
        return string.Equals(rootFull, candidateFull, StringComparison.OrdinalIgnoreCase) ||
               candidateFull.StartsWith(
                   rootFull + Path.DirectorySeparatorChar,
                   StringComparison.OrdinalIgnoreCase);
    }

    internal static void RequireNoReparsePoints(string root, string path)
    {
        if (!IsContained(root, path))
        {
            throw new UnauthorizedAccessException("Renderer evidence path escaped its bound root.");
        }

        var rootFull = Path.GetFullPath(root);
        var current = rootFull;
        RequireNotReparse(current);
        var relative = Path.GetRelativePath(rootFull, Path.GetFullPath(path));
        foreach (var segment in relative.Split(
                     [Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar],
                     StringSplitOptions.RemoveEmptyEntries))
        {
            current = Path.Combine(current, segment);
            if (File.Exists(current) || Directory.Exists(current))
            {
                RequireNotReparse(current);
            }
        }
    }

    internal static void RequireNoReparsePointsFromVolumeRoot(string path)
    {
        var full = Path.GetFullPath(path);
        var root = Path.GetPathRoot(full) ?? throw new InvalidDataException("Renderer path has no volume root.");
        var current = root;
        foreach (var segment in Path.GetRelativePath(root, full).Split(
                     [Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar],
                     StringSplitOptions.RemoveEmptyEntries))
        {
            current = Path.Combine(current, segment);
            if (File.Exists(current) || Directory.Exists(current)) RequireNotReparse(current);
        }
    }

    private static void RequireNotReparse(string path)
    {
        if ((File.GetAttributes(path) & FileAttributes.ReparsePoint) != 0)
        {
            throw new UnauthorizedAccessException(
                $"Renderer evidence path contains a reparse point: {path}");
        }
    }
}

internal static class RendererTargetNativeMethods
{
    internal delegate bool EnumWindowsCallback(IntPtr hwnd, IntPtr parameter);

    [DllImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    internal static extern bool GetNamedPipeServerProcessId(
        SafePipeHandle pipe,
        out uint serverProcessId);

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern uint GetFinalPathNameByHandle(
        SafeFileHandle file,
        StringBuilder path,
        uint length,
        uint flags);

    [DllImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool EnumWindows(EnumWindowsCallback callback, IntPtr parameter);

    [DllImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool EnumThreadWindows(
        uint threadId,
        EnumWindowsCallback callback,
        IntPtr parameter);

    [DllImport("user32.dll")]
    private static extern uint GetWindowThreadProcessId(IntPtr hwnd, out uint processId);

    internal static string GetFinalPath(SafeFileHandle handle)
    {
        var buffer = new StringBuilder(32_768);
        var written = GetFinalPathNameByHandle(handle, buffer, (uint)buffer.Capacity, 0);
        if (written == 0 || written >= buffer.Capacity)
            throw new IOException("Renderer final path observation failed.");
        var value = buffer.ToString();
        if (value.StartsWith(@"\\?\UNC\", StringComparison.OrdinalIgnoreCase))
            value = @"\\" + value[8..];
        else if (value.StartsWith(@"\\?\", StringComparison.OrdinalIgnoreCase))
            value = value[4..];
        return Path.GetFullPath(value);
    }

    internal static IReadOnlyList<IntPtr> EnumerateProcessWindowHandles(int processId)
    {
        var handles = new HashSet<IntPtr>();
        EnumWindowsCallback collect = (hwnd, parameter) =>
        {
            _ = parameter;
            GetWindowThreadProcessId(hwnd, out var owner);
            if (owner == (uint)processId) handles.Add(hwnd);
            return true;
        };
        if (!EnumWindows(collect, IntPtr.Zero)) throw new IOException("EnumWindows failed.");
        using var process = Process.GetProcessById(processId);
        foreach (ProcessThread thread in process.Threads)
        {
            if (!EnumThreadWindows((uint)thread.Id, collect, IntPtr.Zero))
                throw new IOException("EnumThreadWindows failed.");
        }
        return handles.ToArray();
    }
}

public sealed class RendererTargetObservationProducer : IAsyncDisposable
{
    internal const string Protocol = "V02RendererTargetObservation";
    private static readonly string[] Stages =
    [
        "Startup", "PreFirstWindow", "PostFirstWindowShown", "BeforeThaiCaptures",
        "AfterThaiCaptures", "BeforeEnglishCaptures", "AfterEnglishCaptures", "Final",
    ];
    private static readonly string[] CaptureNames =
    [
        "dashboard-overview", "dashboard-live-organization", "dashboard-agent-detail",
        "widget-compact", "widget-normal", "widget-floating-vertical",
        "dashboard-overview-after-event", "widget-floating-vertical-after-dashboard-close",
        "widget-floating-vertical-offline", "widget-floating-vertical-reconnected",
    ];

    private readonly RendererTargetObservationOptions _options;
    private readonly CancellationTokenSource _stop = new();
    private readonly TaskCompletionSource _preFirstWindowObserved = new(
        TaskCreationOptions.RunContinuationsAsynchronously);
    private readonly TaskCompletionSource _firstWindowAllowed = new(
        TaskCreationOptions.RunContinuationsAsynchronously);
    private readonly TaskCompletionSource _firstWindowAttached = new(
        TaskCreationOptions.RunContinuationsAsynchronously);
    private readonly TaskCompletionSource _thaiCapturesComplete = new(
        TaskCreationOptions.RunContinuationsAsynchronously);
    private readonly TaskCompletionSource _thaiCapturePermission = new(
        TaskCreationOptions.RunContinuationsAsynchronously);
    private readonly TaskCompletionSource _englishCapturePermission = new(
        TaskCreationOptions.RunContinuationsAsynchronously);
    private readonly TaskCompletionSource _englishCapturesComplete = new(
        TaskCreationOptions.RunContinuationsAsynchronously);
    private readonly object _captureSync = new();
    private readonly Dictionary<string, RendererBoundCapture> _captures = new(StringComparer.Ordinal);
    private Window? _window;
    private Task? _runTask;

    internal RendererTargetObservationProducer(RendererTargetObservationOptions options)
    {
        _options = options ?? throw new ArgumentNullException(nameof(options));
    }

    internal Task Completion => _runTask ?? Task.CompletedTask;
    internal string RuntimeEvidenceRoot => _options.RuntimeEvidenceRoot;

    internal void Start()
    {
        if (_runTask is not null)
        {
            throw new InvalidOperationException("Renderer target observation producer is one-time only.");
        }

        RendererTargetObservationPath.RequireNoReparsePoints(
            _options.RuntimeEvidenceRoot,
            _options.CaptureDirectory);
        ValidateCandidateBinding();
        _runTask = RunAsync(_stop.Token);
    }

    internal async Task WaitForPreFirstWindowAsync(CancellationToken cancellationToken)
    {
        await _preFirstWindowObserved.Task.WaitAsync(cancellationToken).ConfigureAwait(true);
    }

    internal async Task WaitForFirstWindowPermissionAsync(CancellationToken cancellationToken)
    {
        await _firstWindowAllowed.Task.WaitAsync(cancellationToken).ConfigureAwait(true);
    }

    internal void AttachFirstWindow(Window window)
    {
        ArgumentNullException.ThrowIfNull(window);
        if (_window is not null)
        {
            throw new InvalidOperationException("Renderer target observation window is one-time bound.");
        }

        _window = window;
        _firstWindowAttached.TrySetResult();
    }

    internal Task WaitForEnglishCapturePermissionAsync(CancellationToken cancellationToken) =>
        _englishCapturePermission.Task.WaitAsync(cancellationToken);

    internal Task WaitForThaiCapturePermissionAsync(CancellationToken cancellationToken) =>
        _thaiCapturePermission.Task.WaitAsync(cancellationToken);

    internal bool IsRunnerCaptureRegistered(string language, string name)
    {
        lock (_captureSync) return _captures.ContainsKey($"{language}|{name}");
    }

    internal void RegisterRunnerCapture(
        string language,
        string name,
        string path,
        string runnerToken)
    {
        if (language is not ("Thai" or "English") ||
            !CaptureNames.Contains(name, StringComparer.Ordinal) ||
            !Regex.IsMatch(runnerToken, "^[0-9A-F]{64}$", RegexOptions.CultureInvariant))
        {
            throw new InvalidDataException("Renderer runner capture registration is malformed.");
        }

        var capture = ReadBoundPng(path, language, name, runnerToken);
        lock (_captureSync)
        {
            var key = $"{language}|{name}";
            if (!_captures.TryAdd(key, capture))
            {
                throw new InvalidOperationException($"Renderer runner capture '{key}' was registered more than once.");
            }

            var languageCount = _captures.Keys.Count(key => key.StartsWith(language + "|", StringComparison.Ordinal));
            if (languageCount == CaptureNames.Length)
            {
                if (language == "Thai") _thaiCapturesComplete.TrySetResult();
                else _englishCapturesComplete.TrySetResult();
            }
        }
    }

    private async Task RunAsync(CancellationToken cancellationToken)
    {
        try
        {
            using var pipe = new NamedPipeClientStream(
                ".",
                _options.PipeName,
                PipeDirection.InOut,
                PipeOptions.Asynchronous | PipeOptions.CurrentUserOnly);
            await pipe.ConnectAsync(180_000, cancellationToken).ConfigureAwait(false);
            ValidateServerBinding(pipe);
            using var reader = new StreamReader(
                pipe,
                new UTF8Encoding(false, true),
                false,
                65_536,
                leaveOpen: true);
            using var writer = new StreamWriter(
                pipe,
                new UTF8Encoding(false),
                65_536,
                leaveOpen: true)
            {
                AutoFlush = true,
                NewLine = "\n",
            };

            for (var ordinal = 0; ordinal < Stages.Length; ordinal++)
            {
                var line = await reader.ReadLineAsync(cancellationToken).ConfigureAwait(false);
                var request = ParseRequest(line, ordinal, _options.Challenge);
                if (ordinal == 2)
                {
                    // The independent harness sends PostFirstWindowShown only after
                    // it has re-observed the no-HWND PreFirstWindow response.
                    _firstWindowAllowed.TrySetResult();
                    await _firstWindowAttached.Task.WaitAsync(cancellationToken).ConfigureAwait(false);
                }
                else if (ordinal == 4)
                {
                    await _thaiCapturesComplete.Task.WaitAsync(cancellationToken).ConfigureAwait(false);
                }
                else if (ordinal == 6)
                {
                    await _englishCapturesComplete.Task.WaitAsync(cancellationToken).ConfigureAwait(false);
                }
                var response = await Application.Current.Dispatcher.InvokeAsync(
                    () => BuildResponse(request.Stage, ordinal));
                await writer.WriteLineAsync(JsonSerializer.Serialize(response).AsMemory(), cancellationToken)
                    .ConfigureAwait(false);
                if (ordinal == 3) _thaiCapturePermission.TrySetResult();
                if (ordinal == 5) _englishCapturePermission.TrySetResult();
                if (ordinal == 1)
                {
                    _preFirstWindowObserved.TrySetResult();
                }
            }
        }
        catch (Exception exception)
        {
            _preFirstWindowObserved.TrySetException(exception);
            _firstWindowAllowed.TrySetException(exception);
            throw;
        }
    }

    private void ValidateCandidateBinding()
    {
        var identityPath = Path.GetFullPath(_options.PackageIdentityPath);
        if (!File.Exists(identityPath))
        {
            throw new FileNotFoundException("Renderer package identity receipt was not found.", identityPath);
        }

        RendererTargetObservationPath.RequireNoReparsePointsFromVolumeRoot(identityPath);

        byte[] bytes;
        using (var stream = new FileStream(identityPath, FileMode.Open, FileAccess.Read, FileShare.Read))
        {
            if (!string.Equals(
                    RendererTargetNativeMethods.GetFinalPath(stream.SafeFileHandle),
                    identityPath,
                    StringComparison.OrdinalIgnoreCase))
            {
                throw new UnauthorizedAccessException("Renderer package identity final opened path changed.");
            }
            if (stream.Length is < 3 or > 2 * 1024 * 1024)
            {
                throw new InvalidDataException("Renderer package identity receipt has an invalid bounded size.");
            }

            bytes = new byte[stream.Length];
            stream.ReadExactly(bytes);
            if (stream.Length != bytes.Length)
            {
                throw new IOException("Renderer package identity receipt changed during the same-handle read.");
            }
        }

        if (bytes[0] == 0xef && bytes[1] == 0xbb && bytes[2] == 0xbf)
        {
            throw new InvalidDataException("Renderer package identity receipt must not contain a UTF-8 BOM.");
        }

        if (bytes[^1] != (byte)'\n' || bytes[^2] == (byte)'\r')
        {
            throw new InvalidDataException("Renderer package identity receipt must end in exactly one LF.");
        }

        var canonicalBytes = bytes.AsSpan(0, bytes.Length - 1);
        var canonicalSha = Convert.ToHexString(SHA256.HashData(canonicalBytes));
        if (!string.Equals(
                canonicalSha,
                _options.PackageReceiptSha256,
                StringComparison.Ordinal))
        {
            throw new InvalidDataException("Renderer package receipt canonical SHA-256 binding failed.");
        }

        var json = new UTF8Encoding(false, true).GetString(canonicalBytes);
        using var document = JsonDocument.Parse(json, new JsonDocumentOptions
        {
            AllowTrailingCommas = false,
            CommentHandling = JsonCommentHandling.Disallow,
        });
        RejectDuplicateProperties(document.RootElement, "package identity");
        var source = document.RootElement.GetProperty("source");
        if (!string.Equals(source.GetProperty("commitSha").GetString(), _options.SourceCommit, StringComparison.Ordinal) ||
            !string.Equals(source.GetProperty("treeSha").GetString(), _options.SourceTree, StringComparison.Ordinal))
        {
            throw new InvalidDataException("Renderer package identity source commit/tree binding failed.");
        }

        var components = document.RootElement.GetProperty("components");
        var expectedAppSha = components.GetProperty("app").GetProperty("sha256").GetString();
        var expectedCoreSha = components.GetProperty("core").GetProperty("sha256").GetString();
        var app = ObserveProcess(Environment.ProcessId, "App");
        var core = ObserveProcess(_options.CoreProcessId, "Core");
        if (!string.Equals(app.Sha256, expectedAppSha, StringComparison.Ordinal) ||
            !string.Equals(core.Sha256, expectedCoreSha, StringComparison.Ordinal))
        {
            throw new InvalidDataException("Renderer App/Core executable bytes do not match the package identity receipt.");
        }
    }

    private void ValidateServerBinding(NamedPipeClientStream pipe)
    {
        if (!RendererTargetNativeMethods.GetNamedPipeServerProcessId(pipe.SafePipeHandle, out var serverPid) ||
            serverPid != _options.ServerProcessId)
        {
            throw new UnauthorizedAccessException("Renderer observation pipe server PID binding failed.");
        }

        var server = ObserveProcess(_options.ServerProcessId, "Server");
        if (!string.Equals(server.ExecutablePath, _options.ServerExecutablePath, StringComparison.OrdinalIgnoreCase) ||
            !string.Equals(server.Sha256, _options.ServerExecutableSha256, StringComparison.Ordinal))
        {
            throw new UnauthorizedAccessException("Renderer observation pipe server path/hash binding failed.");
        }
    }

    private static void RejectDuplicateProperties(JsonElement value, string context)
    {
        if (value.ValueKind == JsonValueKind.Object)
        {
            var names = new HashSet<string>(StringComparer.Ordinal);
            foreach (var property in value.EnumerateObject())
            {
                if (!names.Add(property.Name))
                {
                    throw new InvalidDataException($"Renderer {context} contains duplicate property '{property.Name}'.");
                }

                RejectDuplicateProperties(property.Value, context);
            }
        }
        else if (value.ValueKind == JsonValueKind.Array)
        {
            foreach (var item in value.EnumerateArray())
            {
                RejectDuplicateProperties(item, context);
            }
        }
    }

    internal static RendererTargetObservationRequest ParseRequest(
        string? json,
        int expectedOrdinal,
        string expectedChallenge)
    {
        if (string.IsNullOrWhiteSpace(json) || Encoding.UTF8.GetByteCount(json) > 16_384)
        {
            throw new InvalidDataException("Renderer target observation request is empty or oversized.");
        }

        using var document = JsonDocument.Parse(
            json,
            new JsonDocumentOptions { AllowTrailingCommas = false, CommentHandling = JsonCommentHandling.Disallow });
        var root = document.RootElement;
        if (root.ValueKind != JsonValueKind.Object)
        {
            throw new InvalidDataException("Renderer target observation request must be an object.");
        }

        var properties = root.EnumerateObject().ToArray();
        var names = properties.Select(property => property.Name).ToArray();
        var expectedNames = new[] { "protocol", "version", "issue", "stage", "ordinal", "challenge" };
        if (names.Length != expectedNames.Length ||
            names.Distinct(StringComparer.Ordinal).Count() != names.Length ||
            !names.SequenceEqual(expectedNames, StringComparer.Ordinal))
        {
            throw new InvalidDataException("Renderer target observation request shape or property order is invalid.");
        }

        var stage = root.GetProperty("stage").GetString();
        if (root.GetProperty("protocol").GetString() != Protocol ||
            root.GetProperty("version").GetInt32() != 1 ||
            root.GetProperty("issue").GetInt32() != 149 ||
            !string.Equals(root.GetProperty("challenge").GetString(), expectedChallenge, StringComparison.Ordinal) ||
            root.GetProperty("ordinal").GetInt32() != expectedOrdinal ||
            expectedOrdinal < 0 || expectedOrdinal >= Stages.Length ||
            !string.Equals(stage, Stages[expectedOrdinal], StringComparison.Ordinal))
        {
            throw new InvalidDataException("Renderer target observation request binding is invalid.");
        }

        return new RendererTargetObservationRequest(stage!, expectedOrdinal);
    }

    private object BuildResponse(string stage, int ordinal)
    {
        var app = ObserveProcess(Environment.ProcessId, "App");
        var core = ObserveProcess(_options.CoreProcessId, "Core");
        var observation = RuntimeRenderPolicy.ObserveAndRequireSoftwareOnly(
            $"renderer-target:{stage}");
        var window = ObserveWindow(ordinal, app.StartTimeUtc);
        return new
        {
            stage,
            ordinal,
            observedUtc = DateTimeOffset.UtcNow.ToString("O"),
            appProcess = app.Value,
            coreProcess = core.Value,
            window,
            render = new
            {
                source = "TargetProcessNativeObservation",
                processId = Environment.ProcessId,
                processStartUtc = app.StartTimeUtc,
                effectiveMode = RuntimeRenderPolicy.ExpectedProcessRenderMode,
                softwareOnlyConfirmed = observation.SoftwareOnlyConfirmed,
                nativeProcessRenderMode = observation.WpfProcessRenderMode,
                nativeRenderCapabilityTier = observation.RenderTier,
            },
            captures = ObserveCaptures(app.StartTimeUtc),
        };
    }

    private object ObserveWindow(int ordinal, string appStartTimeUtc)
    {
        if (ordinal < 2)
        {
            if (_window is not null ||
                Application.Current.Windows.OfType<Window>().Any() ||
                RendererTargetNativeMethods.EnumerateProcessWindowHandles(Environment.ProcessId).Count != 0)
            {
                throw new InvalidOperationException("A WPF window existed before the governed first-window boundary.");
            }

            return new { hasAnyHwnd = false, hwnd = 0L, ownerPid = 0, ownerStartTimeUtc = (string?)null };
        }

        var bound = _window ?? throw new InvalidOperationException(
            "The governed first window was not attached before post-window observation.");
        var handle = new WindowInteropHelper(bound).Handle.ToInt64();
        if (handle <= 0)
        {
            throw new InvalidOperationException("The governed first window has no live HWND.");
        }

        return new { hasAnyHwnd = true, hwnd = handle, ownerPid = Environment.ProcessId, ownerStartTimeUtc = appStartTimeUtc };
    }

    private object[] ObserveCaptures(string producerStartUtc)
    {
        lock (_captureSync)
        {
            return _captures.Values
                .OrderBy(capture => capture.Language == "Thai" ? 0 : 1)
                .ThenBy(capture => Array.IndexOf(CaptureNames, capture.Name))
                .Select(capture => (object)new
                {
                    language = capture.Language,
                    name = capture.Name,
                    relativePath = capture.RelativePath,
                    bytes = capture.Bytes,
                    sha256 = capture.Sha256,
                    widthPixels = capture.Width,
                    heightPixels = capture.Height,
                    observedUtc = capture.ObservedUtc,
                    producerPid = Environment.ProcessId,
                    producerStartUtc,
                    runnerTokenSha256 = capture.RunnerTokenSha256,
                }).ToArray();
        }
    }

    private RendererBoundCapture ReadBoundPng(
        string path,
        string language,
        string name,
        string runnerToken)
    {
        var fullPath = Path.GetFullPath(path);
        RendererTargetObservationPath.RequireNoReparsePoints(_options.RuntimeEvidenceRoot, fullPath);
        var beforeWrite = File.GetLastWriteTimeUtc(fullPath);
        using var stream = new FileStream(fullPath, FileMode.Open, FileAccess.Read, FileShare.Read);
        var finalPath = RendererTargetNativeMethods.GetFinalPath(stream.SafeFileHandle);
        if (!RendererTargetObservationPath.IsContained(_options.RuntimeEvidenceRoot, finalPath) ||
            !string.Equals(finalPath, fullPath, StringComparison.OrdinalIgnoreCase))
        {
            throw new UnauthorizedAccessException("Renderer capture final opened path escaped or changed.");
        }

        var length = stream.Length;
        if (length < 24 || length > 64 * 1024 * 1024)
            throw new InvalidDataException("Renderer capture PNG has an invalid bounded size.");
        var hash = Convert.ToHexString(SHA256.HashData(stream));
        stream.Position = 0;
        var decoder = new PngBitmapDecoder(
            stream,
            BitmapCreateOptions.PreservePixelFormat,
            BitmapCacheOption.OnLoad);
        if (decoder.Frames.Count != 1 || decoder.Frames[0].PixelWidth <= 0 || decoder.Frames[0].PixelHeight <= 0)
            throw new InvalidDataException("Renderer capture must be one complete decodable PNG frame.");
        var afterWrite = File.GetLastWriteTimeUtc(fullPath);
        if (beforeWrite != afterWrite || stream.Length != length)
            throw new IOException("Renderer capture metadata changed during the same-handle read.");
        if (beforeWrite < Process.GetCurrentProcess().StartTime.ToUniversalTime())
            throw new InvalidDataException("Renderer capture predates the bound App process.");
        return new RendererBoundCapture(
            language,
            name,
            Path.GetRelativePath(_options.RuntimeEvidenceRoot, fullPath).Replace('\\', '/'),
            length,
            hash,
            decoder.Frames[0].PixelWidth,
            decoder.Frames[0].PixelHeight,
            new DateTimeOffset(beforeWrite, TimeSpan.Zero).ToString("O"),
            Convert.ToHexString(SHA256.HashData(Convert.FromHexString(runnerToken))));
    }

    internal static RendererStablePng ReadStablePng(string path)
    {
        path = Path.GetFullPath(path);
        using var stream = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.Read);
        var finalPath = RendererTargetNativeMethods.GetFinalPath(stream.SafeFileHandle);
        if (!string.Equals(finalPath, path, StringComparison.OrdinalIgnoreCase))
            throw new UnauthorizedAccessException("Renderer capture final opened path changed.");
        var length = stream.Length;
        if (length < 24 || length > 64 * 1024 * 1024)
        {
            throw new InvalidDataException("Renderer capture PNG has an invalid bounded size.");
        }

        Span<byte> header = stackalloc byte[24];
        stream.ReadExactly(header);
        ReadOnlySpan<byte> signature = [137, 80, 78, 71, 13, 10, 26, 10];
        if (!header[..8].SequenceEqual(signature) ||
            !header[12..16].SequenceEqual("IHDR"u8))
        {
            throw new InvalidDataException("Renderer capture is not a PNG with a leading IHDR.");
        }

        var width = BinaryPrimitives.ReadInt32BigEndian(header[16..20]);
        var height = BinaryPrimitives.ReadInt32BigEndian(header[20..24]);
        if (width <= 0 || height <= 0)
        {
            throw new InvalidDataException("Renderer capture PNG dimensions are invalid.");
        }

        stream.Position = 0;
        var sha256 = Convert.ToHexString(SHA256.HashData(stream));
        if (stream.Length != length)
        {
            throw new IOException("Renderer capture changed during the same-handle read.");
        }

        return new RendererStablePng(length, sha256, width, height);
    }

    private static RendererObservedProcess ObserveProcess(int processId, string role)
    {
        using var process = Process.GetProcessById(processId);
        process.Refresh();
        var path = Path.GetFullPath(process.MainModule?.FileName ?? throw new InvalidOperationException(
            $"Renderer target {role} executable path is unavailable."));
        var startTimeUtc = process.StartTime.ToUniversalTime().ToString("O");
        using var stream = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.Read);
        var finalPath = RendererTargetNativeMethods.GetFinalPath(stream.SafeFileHandle);
        if (!string.Equals(finalPath, path, StringComparison.OrdinalIgnoreCase))
            throw new UnauthorizedAccessException($"Renderer target {role} executable final path changed.");
        var length = stream.Length;
        var hash = Convert.ToHexString(SHA256.HashData(stream));
        if (stream.Length != length)
        {
            throw new IOException($"Renderer target {role} executable changed during observation.");
        }

        var value = new
        {
            role,
            pid = process.Id,
            startTimeUtc,
            executablePath = path,
            executableFinalPath = finalPath,
            bytes = length,
            sha256 = hash,
            processName = process.ProcessName,
        };
        return new RendererObservedProcess(startTimeUtc, hash, path, value);
    }

    public async ValueTask DisposeAsync()
    {
        _stop.Cancel();
        if (_runTask is not null)
        {
            try
            {
                await _runTask.ConfigureAwait(false);
            }
            catch (OperationCanceledException) when (_stop.IsCancellationRequested)
            {
            }
        }

        _stop.Dispose();
    }
}

internal sealed record RendererTargetObservationRequest(string Stage, int Ordinal);
internal sealed record RendererStablePng(long Bytes, string Sha256, int Width, int Height);
internal sealed record RendererObservedProcess(
    string StartTimeUtc,
    string Sha256,
    string ExecutablePath,
    object Value);
internal sealed record RendererBoundCapture(
    string Language,
    string Name,
    string RelativePath,
    long Bytes,
    string Sha256,
    int Width,
    int Height,
    string ObservedUtc,
    string RunnerTokenSha256);
