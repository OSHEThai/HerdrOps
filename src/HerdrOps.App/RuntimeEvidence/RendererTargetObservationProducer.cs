using System.Buffers.Binary;
using System.Diagnostics;
using System.IO;
using System.IO.Pipes;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.RegularExpressions;
using System.Windows;
using System.Windows.Interop;
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
    UiLanguage Language)
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

        try
        {
            var root = Path.GetFullPath(runtimeEvidenceRoot).TrimEnd(
                Path.DirectorySeparatorChar,
                Path.AltDirectorySeparatorChar);
            var captures = Path.GetFullPath(captureDirectory);
            var identityPath = Path.GetFullPath(packageIdentityPath);
            if (!RendererTargetObservationPath.IsContained(root, captures))
            {
                error = "Renderer capture directory must be confined below the runtime evidence root.";
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
                language);
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

    private static void RequireNotReparse(string path)
    {
        if ((File.GetAttributes(path) & FileAttributes.ReparsePoint) != 0)
        {
            throw new UnauthorizedAccessException(
                $"Renderer evidence path contains a reparse point: {path}");
        }
    }
}

internal sealed class RendererTargetObservationProducer : IAsyncDisposable
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
    private Window? _window;
    private Task? _runTask;

    internal RendererTargetObservationProducer(RendererTargetObservationOptions options)
    {
        _options = options ?? throw new ArgumentNullException(nameof(options));
    }

    internal Task Completion => _runTask ?? Task.CompletedTask;

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
                var request = ParseRequest(line, ordinal);
                if (ordinal == 2)
                {
                    // The independent harness sends PostFirstWindowShown only after
                    // it has re-observed the no-HWND PreFirstWindow response.
                    _firstWindowAllowed.TrySetResult();
                    await _firstWindowAttached.Task.WaitAsync(cancellationToken).ConfigureAwait(false);
                }
                var response = await Application.Current.Dispatcher.InvokeAsync(
                    () => BuildResponse(request.Stage, ordinal));
                await writer.WriteLineAsync(JsonSerializer.Serialize(response).AsMemory(), cancellationToken)
                    .ConfigureAwait(false);
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

        if ((File.GetAttributes(identityPath) & FileAttributes.ReparsePoint) != 0)
        {
            throw new UnauthorizedAccessException("Renderer package identity receipt is a reparse point.");
        }

        byte[] bytes;
        using (var stream = new FileStream(identityPath, FileMode.Open, FileAccess.Read, FileShare.Read))
        {
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

    internal static RendererTargetObservationRequest ParseRequest(string? json, int expectedOrdinal)
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
        var expectedNames = new[] { "protocol", "version", "issue", "stage", "ordinal" };
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
            if (_window is not null || Application.Current.Windows.OfType<Window>().Any())
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
        if (!Directory.Exists(_options.CaptureDirectory))
        {
            return [];
        }

        RendererTargetObservationPath.RequireNoReparsePoints(
            _options.RuntimeEvidenceRoot,
            _options.CaptureDirectory);
        var language = _options.Language == UiLanguage.Thai ? "Thai" : "English";
        var captures = new List<object>();
        foreach (var name in CaptureNames)
        {
            var path = Path.Combine(_options.CaptureDirectory, $"{name}.png");
            if (!File.Exists(path))
            {
                continue;
            }

            RendererTargetObservationPath.RequireNoReparsePoints(_options.RuntimeEvidenceRoot, path);
            var captured = ReadStablePng(path);
            captures.Add(new
            {
                language,
                name,
                relativePath = Path.GetRelativePath(_options.RuntimeEvidenceRoot, path).Replace('\\', '/'),
                bytes = captured.Bytes,
                sha256 = captured.Sha256,
                widthPixels = captured.Width,
                heightPixels = captured.Height,
                observedUtc = File.GetLastWriteTimeUtc(path).ToString("O"),
                producerPid = Environment.ProcessId,
                producerStartUtc,
            });
        }

        return captures.ToArray();
    }

    internal static RendererStablePng ReadStablePng(string path)
    {
        using var stream = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.Read);
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
            executableFinalPath = path,
            bytes = length,
            sha256 = hash,
            processName = process.ProcessName,
        };
        return new RendererObservedProcess(startTimeUtc, hash, value);
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
internal sealed record RendererObservedProcess(string StartTimeUtc, string Sha256, object Value);
