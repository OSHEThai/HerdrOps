using System.Diagnostics;
using System.Globalization;
using System.IO;
using System.IO.Pipes;
using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.RegularExpressions;
using System.Windows.Threading;
using HerdrOps.App.Widgets;

namespace HerdrOps.App.RuntimeEvidence;

internal sealed record Issue10PerformanceTelemetryOptions(
    string PipeName,
    string RunNonce,
    string SourceCommit,
    string SourceTree,
    string PackageIdentityPath,
    string PackageIdentitySha256,
    string PackageArchivePath,
    string PackageArchiveSha256,
    string PackageRoot,
    string PackageProfilePath,
    int ServerProcessId,
    DateTimeOffset ServerStartUtc,
    string ServerExecutablePath,
    string ServerExecutableSha256,
    string RendererMode,
    bool PreWpfHasAnyHwnd,
    string AppExecutableSha256,
    string CoreExecutablePath,
    string CoreExecutableSha256,
    string ManifestPath,
    string ManifestSha256,
    string IdentityFileSha256,
    string ProfileFileSha256,
    Issue10ValidatedPackage PackageLease)
{
    private static readonly Regex Lower32 = new("^[0-9a-f]{32}$", RegexOptions.CultureInvariant);
    private static readonly Regex Lower40 = new("^[0-9a-f]{40}$", RegexOptions.CultureInvariant);
    private static readonly Regex Upper64 = new("^[0-9A-F]{64}$", RegexOptions.CultureInvariant);
    private static readonly Regex Pipe = new("^herdrops-v02-issue10-perf-[0-9a-f]{32}-[0-9]{1,3}$", RegexOptions.CultureInvariant);

    internal static bool TryParseInvocation(
        IReadOnlyList<string> args,
        out Issue10PerformanceTelemetryOptions? options,
        out string? error)
    {
        options = null;
        error = null;
        var names = new[]
        {
            "--issue10-performance-telemetry-pipe", "--issue10-performance-run-nonce",
            "--issue10-performance-source-commit", "--issue10-performance-source-tree",
            "--issue10-performance-package-identity-path", "--issue10-performance-package-identity-sha256",
            "--issue10-performance-package-archive-path", "--issue10-performance-package-archive-sha256",
            "--issue10-performance-package-root",
            "--issue10-performance-package-profile-path",
            "--issue10-performance-server-pid", "--issue10-performance-server-start-utc", "--issue10-performance-server-path",
            "--issue10-performance-server-sha256", "--issue10-performance-renderer-mode",
        };
        var requested = args.Any(argument => argument.StartsWith("--issue10-performance-", StringComparison.Ordinal));
        if (!requested)
        {
            return true;
        }

        try
        {
            if (args.Count != names.Length * 2)
            {
                throw new InvalidOperationException("Issue #10 performance mode requires one complete exact argument set.");
            }
            var values = new Dictionary<string, string>(StringComparer.Ordinal);
            for (var index = 0; index < args.Count; index += 2)
            {
                if (!names.Contains(args[index], StringComparer.Ordinal) ||
                    !values.TryAdd(args[index], args[index + 1]))
                {
                    throw new InvalidOperationException("Issue #10 performance mode contains an unknown or duplicate option.");
                }
            }
            if (names.Any(name => !values.ContainsKey(name)))
            {
                throw new InvalidOperationException("Issue #10 performance mode omitted a required option.");
            }
            var pipe = values[names[0]];
            var nonce = values[names[1]];
            var commit = values[names[2]];
            var tree = values[names[3]];
            var identityPath = Path.GetFullPath(values[names[4]]);
            var identitySha = values[names[5]];
            var archivePath = Path.GetFullPath(values[names[6]]);
            var archiveSha = values[names[7]];
            var packageRoot = Path.GetFullPath(values[names[8]]);
            var profilePath = Path.GetFullPath(values[names[9]]);
            if (!int.TryParse(values[names[10]], out var serverPid) || serverPid <= 0 || serverPid == Environment.ProcessId)
            {
                throw new InvalidOperationException("Issue #10 performance server PID is invalid.");
            }
            if (!DateTimeOffset.TryParseExact(values[names[11]], "O", CultureInfo.InvariantCulture,
                DateTimeStyles.None, out var serverStartUtc) ||
                serverStartUtc.Offset != TimeSpan.Zero)
            {
                throw new InvalidOperationException("Issue #10 performance server start UTC is invalid.");
            }
            var serverPath = Path.GetFullPath(values[names[12]]);
            var serverSha = values[names[13]];
            var mode = values[names[14]];
            if (!Pipe.IsMatch(pipe) || !pipe.Contains(nonce, StringComparison.Ordinal) ||
                !Lower32.IsMatch(nonce) || !Lower40.IsMatch(commit) || !Lower40.IsMatch(tree) ||
                !Upper64.IsMatch(identitySha) || !Upper64.IsMatch(archiveSha) || !Upper64.IsMatch(serverSha) ||
                mode is not ("Hardware" or "SoftwareOnly"))
            {
                throw new InvalidOperationException("Issue #10 performance identifiers or renderer mode are invalid.");
            }
            var package = Issue10PackageValidator.Validate(
                identityPath, identitySha, archivePath, archiveSha, packageRoot, profilePath, commit, tree,
                Environment.ProcessPath ?? throw new InvalidOperationException("Issue #10 App process path is unavailable."));
            try
            {
                if (HasProcessHwnd(Environment.ProcessId))
                {
                    throw new InvalidOperationException("Issue #10 performance process already owns an HWND before renderer policy selection.");
                }
                options = new Issue10PerformanceTelemetryOptions(
                    pipe, nonce, commit, tree, identityPath, identitySha, archivePath,
                    archiveSha, packageRoot, profilePath, serverPid, serverStartUtc, serverPath, serverSha, mode, false,
                    package.AppSha256, package.CorePath, package.CoreSha256, package.ManifestPath,
                    package.ManifestSha256, package.IdentityFileSha256, package.ProfileFileSha256, package);
            }
            catch
            {
                package.Dispose();
                throw;
            }
            return true;
        }
        catch (Exception exception) when (exception is not OutOfMemoryException)
        {
            error = exception.Message;
            return false;
        }
    }

    private static void RejectDuplicates(JsonElement element)
    {
        if (element.ValueKind == JsonValueKind.Object)
        {
            var names = new HashSet<string>(StringComparer.Ordinal);
            foreach (var property in element.EnumerateObject())
            {
                if (!names.Add(property.Name)) throw new InvalidDataException("Package identity contains a duplicate JSON property.");
                RejectDuplicates(property.Value);
            }
        }
        else if (element.ValueKind == JsonValueKind.Array)
        {
            foreach (var item in element.EnumerateArray()) RejectDuplicates(item);
        }
    }

    internal static string HashFile(string path)
    {
        using var stream = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.Read);
        return Convert.ToHexString(SHA256.HashData(stream));
    }

    internal static bool HasProcessHwnd(int processId)
    {
        var found = false;
        _ = EnumWindows((window, parameter) =>
        {
            _ = GetWindowThreadProcessId(window, out var owner);
            if (owner != (uint)processId) return true;
            found = true;
            return false;
        }, IntPtr.Zero);
        return found;
    }

    [DllImport("user32.dll")]
    private static extern bool EnumWindows(EnumWindowsProc callback, IntPtr parameter);

    [DllImport("user32.dll")]
    private static extern uint GetWindowThreadProcessId(IntPtr window, out uint processId);

    private delegate bool EnumWindowsProc(IntPtr window, IntPtr parameter);

}

internal sealed class Issue10PerformanceTelemetryProducer : IAsyncDisposable
{
    private const string Boundary = "PackagedCompatibilityPerformance-NativeTierComparator-NoPerFrameGpuOrRuntimeCredit";
    private readonly Issue10PerformanceTelemetryOptions _options;
    private readonly Dispatcher _dispatcher;
    private readonly LiveWidgetState _widgets;
    private readonly RuntimeRenderPolicyObservation _startup;
    private NamedPipeClientStream? _pipe;
    private StreamReader? _reader;
    private StreamWriter? _writer;

    internal static bool IsRemoteSession => GetSystemMetrics(0x1000) != 0;

    internal Issue10PerformanceTelemetryProducer(
        Issue10PerformanceTelemetryOptions options,
        Dispatcher dispatcher,
        LiveWidgetState widgets,
        RuntimeRenderPolicyObservation startup)
    {
        _options = options;
        _dispatcher = dispatcher;
        _widgets = widgets;
        _startup = startup;
    }

    internal async Task RunAsync(CancellationToken cancellationToken)
    {
        _options.PackageLease.Revalidate("telemetry startup");
        ValidateServer();
        _pipe = new NamedPipeClientStream(".", _options.PipeName, PipeDirection.InOut, PipeOptions.Asynchronous);
        await _pipe.ConnectAsync(30_000, cancellationToken);
        var serverPid = GetServerProcessId(_pipe.SafePipeHandle.DangerousGetHandle());
        if (serverPid != _options.ServerProcessId) throw new UnauthorizedAccessException("Issue #10 telemetry pipe server PID changed.");
        _reader = new StreamReader(_pipe, new UTF8Encoding(false, true), false, 65_536, true);
        _writer = new StreamWriter(_pipe, new UTF8Encoding(false), 65_536, true) { AutoFlush = true };
        await _writer.WriteLineAsync(JsonSerializer.Serialize(BuildHello()));
        while (true)
        {
            var requestLine = await _reader.ReadLineAsync(cancellationToken);
            if (requestLine is null) break;
            var request = ParseRequest(requestLine, _options.RendererMode, _options.RunNonce, Environment.ProcessId);
            _options.PackageLease.Revalidate("authenticated telemetry request");
            ValidateServer();
            var response = request.IsSoak
                ? await MeasureSoakAsync(request, cancellationToken)
                : await MeasureAsync(request, cancellationToken);
            await _writer.WriteLineAsync(JsonSerializer.Serialize(response));
            if (!request.IsSoak) break;
        }
    }

    private object BuildHello()
    {
        using var process = Process.GetCurrentProcess();
        var start = process.StartTime.ToUniversalTime().ToString("O");
        return new
        {
            schemaVersion = 1,
            kind = "issue10-performance-hello",
            runNonce = _options.RunNonce,
            sourceCommit = _options.SourceCommit,
            sourceTree = _options.SourceTree,
            packageIdentitySha256 = _options.PackageIdentitySha256,
            packageArchiveSha256 = _options.PackageArchiveSha256,
            server = ObserveServer(),
            app = new { pid = Environment.ProcessId, startUtc = start, path = Environment.ProcessPath, sha256 = _options.AppExecutableSha256 },
            renderer = new
            {
                requestedMode = _options.RendererMode,
                nativeProcessRenderMode = _startup.WpfProcessRenderMode,
                nativeTier = _startup.RenderTier,
                hasAnyHwnd = _options.PreWpfHasAnyHwnd,
                preFirstHwnd = true,
                hardwareComparatorBoundary = Boundary,
            },
        };
    }

    private object ObserveServer()
    {
        using var server = Process.GetProcessById(_options.ServerProcessId);
        var (startUtc, path) = ValidateProcessIdentity(server, _options.ServerStartUtc, _options.ServerExecutablePath,
            _options.ServerExecutableSha256, "telemetry server");
        return new { pid = server.Id, startUtc = startUtc.ToString("O"), path, sha256 = _options.ServerExecutableSha256 };
    }

    internal static SampleRequest ParseRequest(string? json, string rendererMode, string runNonce, int appProcessId)
    {
        if (string.IsNullOrWhiteSpace(json) || Encoding.UTF8.GetByteCount(json) > 16_384) throw new InvalidDataException("Issue #10 sample request is empty or oversized.");
        using var document = JsonDocument.Parse(json);
        RejectRequestDuplicates(document.RootElement);
        var root = document.RootElement;
        var kind = root.GetProperty("kind").GetString() ?? string.Empty;
        if (kind == "issue10-soak-sample-request")
        {
            var expected = new[] { "schemaVersion", "kind", "runNonce", "sequenceNumber", "binIndex", "sampleIndex", "coreProcessId", "coreStartUtc" };
            RequireExactRequestShape(root, expected);
            var soak = new SampleRequest(root.GetProperty("schemaVersion").GetInt32(), kind,
                root.GetProperty("runNonce").GetString() ?? string.Empty,
                root.GetProperty("sequenceNumber").GetInt32(), "SOAK", false, 0, "b", true,
                root.GetProperty("binIndex").GetInt32(), root.GetProperty("sampleIndex").GetInt32(), root.GetProperty("coreProcessId").GetInt32(), ParseRequestUtc(root.GetProperty("coreStartUtc"), "Core start UTC"));
            if (rendererMode != "SoftwareOnly" || soak.SchemaVersion != 1 || soak.RunNonce != runNonce ||
                soak.SequenceNumber is < 0 or > 3599 || soak.BinIndex is < 0 or > 11 || soak.SampleIndex is < 0 or > 299 ||
                soak.SequenceNumber != soak.BinIndex * 300 + soak.SampleIndex || soak.CoreProcessId <= 0 || soak.CoreProcessId == appProcessId)
            {
                throw new InvalidDataException("Issue #10 soak request binding is invalid.");
            }
            return soak;
        }
        RequireExactRequestShape(root, new[] { "schemaVersion", "kind", "runNonce", "sequenceNumber", "order", "isWarmup", "repetitionOrdinal", "semanticMode", "coreProcessId", "coreStartUtc" });
        var request = new SampleRequest(
            root.GetProperty("schemaVersion").GetInt32(),
            kind,
            root.GetProperty("runNonce").GetString() ?? string.Empty,
            root.GetProperty("sequenceNumber").GetInt32(),
            root.GetProperty("order").GetString() ?? string.Empty,
            root.GetProperty("isWarmup").GetBoolean(),
            root.GetProperty("repetitionOrdinal").GetInt32(),
            root.GetProperty("semanticMode").GetString() ?? string.Empty,
            false, -1, -1, root.GetProperty("coreProcessId").GetInt32(), ParseRequestUtc(root.GetProperty("coreStartUtc"), "Core start UTC"));
        var expectedSemantic = rendererMode == "Hardware" ? "a" : "b";
        var expectedOrder = request.SequenceNumber < 12 ? "AB" : "BA";
        var withinOrder = request.SequenceNumber % 12;
        var expectedWarmup = withinOrder < 2;
        var expectedRepetition = expectedWarmup ? 0 : (withinOrder - 2) / 2;
        var expectedPositionSemantic = expectedOrder == "AB"
            ? (withinOrder % 2 == 0 ? "a" : "b")
            : (withinOrder % 2 == 0 ? "b" : "a");
        if (request.SchemaVersion != 1 || request.Kind != "issue10-performance-sample-request" ||
            request.RunNonce != runNonce || request.SequenceNumber is < 0 or > 23 ||
            request.Order != expectedOrder || request.IsWarmup != expectedWarmup || request.RepetitionOrdinal != expectedRepetition ||
            request.SemanticMode != expectedSemantic || request.SemanticMode != expectedPositionSemantic ||
            request.CoreProcessId <= 0 || request.CoreProcessId == appProcessId)
        {
            throw new InvalidDataException("Issue #10 sample request binding is invalid.");
        }
        return request;
    }

    private async Task<object> MeasureSoakAsync(SampleRequest request, CancellationToken cancellationToken)
    {
        var baselineStateSequence = CaptureLatencyBaseline(_widgets.UpdateLatencySnapshot);
        using var core = Process.GetProcessById(request.CoreProcessId);
        core.Refresh();
        var corePath = Path.GetFullPath(core.MainModule?.FileName ?? string.Empty);
        var coreStart = core.StartTime.ToUniversalTime();
        if (new DateTimeOffset(coreStart, TimeSpan.Zero) != request.CoreStartUtc) throw new UnauthorizedAccessException("Issue #10 soak Core process start identity is invalid.");
        if (!string.Equals(corePath, _options.CoreExecutablePath, StringComparison.OrdinalIgnoreCase) ||
            !Issue10PerformanceTelemetryOptions.HashFile(corePath).Equals(_options.CoreExecutableSha256, StringComparison.Ordinal))
        {
            throw new UnauthorizedAccessException("Issue #10 soak Core process is not the exact packaged component.");
        }
        var deadline = DateTimeOffset.UtcNow.AddMinutes(5);
        WidgetUpdateLatencySample[] latency = [];
        while (DateTimeOffset.UtcNow < deadline)
        {
            cancellationToken.ThrowIfCancellationRequested();
            core.Refresh();
            if (core.HasExited || core.StartTime.ToUniversalTime() != coreStart ||
                !string.Equals(Path.GetFullPath(core.MainModule?.FileName ?? string.Empty), corePath, StringComparison.OrdinalIgnoreCase) ||
                !Issue10PerformanceTelemetryOptions.HashFile(corePath).Equals(_options.CoreExecutableSha256, StringComparison.Ordinal))
            {
                throw new InvalidOperationException("Issue #10 soak Core process changed during acquisition.");
            }
            latency = SelectRollingSoakLatencySamples(_widgets.UpdateLatencySnapshot, baselineStateSequence);
            if (latency.Length == 20) break;
            await Task.Delay(100, cancellationToken);
        }
        if (latency.Length != 20) throw new TimeoutException("Issue #10 soak telemetry did not observe 20 production Widget updates.");
        var stalls = await ObserveDispatcherStallsAsync(cancellationToken);
        _ = ValidateProcessIdentity(core, request.CoreStartUtc, _options.CoreExecutablePath,
            _options.CoreExecutableSha256, "soak Core final boundary");
        var render = RuntimeRenderPolicy.ObserveAndRequireConfiguredMode("issue10-soak-sample");
        var observedUtc = DateTimeOffset.UtcNow.ToString("O");
        using var app = Process.GetCurrentProcess();
        var unsigned = new
        {
            schemaVersion = 1,
            nonce = _options.RunNonce,
            sequenceNumber = request.SequenceNumber,
            observedUtc,
            binIndex = request.BinIndex,
            sampleIndex = request.SampleIndex,
            producer = new
            {
                appProcessId = Environment.ProcessId,
                coreProcessId = core.Id,
                appStartTimeUtc = app.StartTime.ToUniversalTime().ToString("O"),
                coreStartTimeUtc = coreStart.ToString("O"),
                appExecutablePath = Environment.ProcessPath,
                coreExecutablePath = corePath,
                appExecutableSha256 = _options.AppExecutableSha256,
                coreExecutableSha256 = _options.CoreExecutableSha256,
            },
            metrics = new
            {
                latencyMicroseconds = latency.Select(sample => checked((long)Math.Round(sample.Milliseconds * 1000.0))).ToArray(),
                uiStallMicroseconds = stalls,
                rendererStable = render.SoftwareOnlyConfirmed && render.WpfProcessRenderMode == "SoftwareOnly",
            },
        };
        var canonical = JsonSerializer.Serialize(unsigned);
        var packetSha256 = Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(canonical)));
        return new
        {
            unsigned.schemaVersion,
            unsigned.nonce,
            unsigned.sequenceNumber,
            unsigned.observedUtc,
            unsigned.binIndex,
            unsigned.sampleIndex,
            unsigned.producer,
            unsigned.metrics,
            packetSha256,
        };
    }

    private async Task<object> MeasureAsync(SampleRequest request, CancellationToken cancellationToken)
    {
        var baselineStateSequence = CaptureLatencyBaseline(_widgets.UpdateLatencySnapshot);
        using var process = Process.GetCurrentProcess();
        using var core = Process.GetProcessById(request.CoreProcessId);
        core.Refresh();
        var corePath = Path.GetFullPath(core.MainModule?.FileName ?? string.Empty);
        var coreStart = core.StartTime.ToUniversalTime();
        if (new DateTimeOffset(coreStart, TimeSpan.Zero) != request.CoreStartUtc) throw new UnauthorizedAccessException("Issue #10 performance Core process start identity is invalid.");
        if (!string.Equals(corePath, _options.CoreExecutablePath, StringComparison.OrdinalIgnoreCase) ||
            !Issue10PerformanceTelemetryOptions.HashFile(corePath).Equals(_options.CoreExecutableSha256, StringComparison.Ordinal))
        {
            throw new UnauthorizedAccessException("Issue #10 performance Core process is not the exact packaged component.");
        }
        var cpuStart = process.TotalProcessorTime;
        var coreCpuStart = core.TotalProcessorTime;
        var wall = Stopwatch.StartNew();
        long maximumWorkingSet = process.WorkingSet64;
        long maximumCoreWorkingSet = core.WorkingSet64;
        var deadline = DateTimeOffset.UtcNow.AddMinutes(5);
        IReadOnlyList<WidgetUpdateLatencySample> fresh = [];
        while (DateTimeOffset.UtcNow < deadline)
        {
            cancellationToken.ThrowIfCancellationRequested();
            process.Refresh();
            core.Refresh();
            if (core.HasExited || core.StartTime.ToUniversalTime() != coreStart) throw new InvalidOperationException("Issue #10 performance Core process changed during acquisition.");
            maximumWorkingSet = Math.Max(maximumWorkingSet, process.WorkingSet64);
            maximumCoreWorkingSet = Math.Max(maximumCoreWorkingSet, core.WorkingSet64);
            fresh = SelectFreshLatencySamples(_widgets.UpdateLatencySnapshot, baselineStateSequence);
            if (fresh.Count == 20) break;
            await Task.Delay(100, cancellationToken);
        }
        if (fresh.Count != 20) throw new TimeoutException("Issue #10 performance sample did not observe 20 fresh production Widget updates.");
        var stalls = await ObserveDispatcherStallsAsync(cancellationToken);
        process.Refresh();
        core.Refresh();
        maximumWorkingSet = Math.Max(maximumWorkingSet, process.WorkingSet64);
        maximumCoreWorkingSet = Math.Max(maximumCoreWorkingSet, core.WorkingSet64);
        _ = ValidateProcessIdentity(core, request.CoreStartUtc, _options.CoreExecutablePath,
            _options.CoreExecutableSha256, "performance Core final boundary");
        wall.Stop();
        var cpuBasisPoints = wall.Elapsed.TotalMilliseconds <= 0 ? 0L : checked((long)Math.Round(
            ((process.TotalProcessorTime - cpuStart).TotalMilliseconds + (core.TotalProcessorTime - coreCpuStart).TotalMilliseconds) /
            (wall.Elapsed.TotalMilliseconds * Environment.ProcessorCount) * 10_000.0));
        var observation = RuntimeRenderPolicy.ObserveAndRequireConfiguredMode("issue10-performance-sample");
        return new
        {
            schemaVersion = 1,
            kind = "issue10-performance-sample",
            runNonce = _options.RunNonce,
            sequenceNumber = request.SequenceNumber,
            observedUtc = DateTimeOffset.UtcNow.ToString("O"),
            app = new { pid = Environment.ProcessId, startUtc = process.StartTime.ToUniversalTime().ToString("O"), path = Environment.ProcessPath, sha256 = _options.AppExecutableSha256 },
            core = new { pid = core.Id, startUtc = coreStart.ToString("O"), path = corePath, sha256 = _options.CoreExecutableSha256 },
            renderer = new { requestedMode = _options.RendererMode, nativeProcessRenderMode = observation.WpfProcessRenderMode, nativeTier = observation.RenderTier, hasAnyHwnd = Issue10PerformanceTelemetryOptions.HasProcessHwnd(Environment.ProcessId), preFirstHwnd = false },
            cpuBasisPoints = Math.Max(0, cpuBasisPoints),
            workingSetMaximumBytes = checked(maximumWorkingSet + maximumCoreWorkingSet),
            latencyMicroseconds = fresh.Select(sample => checked((long)Math.Round(sample.Milliseconds * 1000.0))).ToArray(),
            uiStallMicroseconds = stalls,
            boundary = Boundary,
        };
    }

    internal static long CaptureLatencyBaseline(WidgetLatencySnapshot snapshot) =>
        snapshot.Samples
            .Where(sample => sample.UpdateKind is "Snapshot" or "Delta")
            .Select(sample => sample.StateSequence)
            .DefaultIfEmpty(-1)
            .Max();

    internal static WidgetUpdateLatencySample[] SelectFreshLatencySamples(
        WidgetLatencySnapshot snapshot,
        long baselineStateSequence)
    {
        var candidates = snapshot.Samples
            .Where(sample => sample.UpdateKind is "Snapshot" or "Delta")
            .Where(sample => sample.StateSequence > baselineStateSequence)
            .ToArray();
        for (var index = 1; index < candidates.Length; index++)
        {
            if (candidates[index].StateSequence <= candidates[index - 1].StateSequence)
            {
                throw new InvalidDataException("Issue #10 Widget latency stream replayed or reordered a state sequence.");
            }
        }
        return candidates.Take(20).ToArray();
    }

    internal static WidgetUpdateLatencySample[] SelectRollingSoakLatencySamples(
        WidgetLatencySnapshot snapshot,
        long baselineStateSequence)
    {
        var eligible = snapshot.Samples
            .Where(sample => sample.UpdateKind is "Snapshot" or "Delta")
            .ToArray();
        for (var index = 1; index < eligible.Length; index++)
        {
            if (eligible[index].StateSequence <= eligible[index - 1].StateSequence)
            {
                throw new InvalidDataException("Issue #10 Widget soak latency stream replayed or reordered a state sequence.");
            }
        }
        if (eligible.Length < 20 || eligible[^1].StateSequence <= baselineStateSequence) return [];
        return eligible.TakeLast(20).ToArray();
    }

    private async Task<long[]> ObserveDispatcherStallsAsync(CancellationToken cancellationToken)
    {
        var stalls = new long[20];
        for (var index = 0; index < stalls.Length; index++)
        {
            var started = Stopwatch.GetTimestamp();
            await _dispatcher.InvokeAsync(static () => { }, DispatcherPriority.Background, cancellationToken);
            stalls[index] = checked((long)Math.Round(Stopwatch.GetElapsedTime(started).TotalMilliseconds * 1000.0));
        }
        return stalls;
    }

    private void ValidateServer()
    {
        using var process = Process.GetProcessById(_options.ServerProcessId);
        _ = ValidateProcessIdentity(process, _options.ServerStartUtc, _options.ServerExecutablePath,
            _options.ServerExecutableSha256, "telemetry server");
    }

    internal static (DateTimeOffset StartUtc, string Path) ValidateProcessIdentity(
        Process process,
        DateTimeOffset expectedStartUtc,
        string expectedPath,
        string expectedSha256,
        string context)
    {
        process.Refresh();
        var startBefore = new DateTimeOffset(process.StartTime.ToUniversalTime(), TimeSpan.Zero);
        var actualPath = Path.GetFullPath(process.MainModule?.FileName ?? string.Empty);
        var actualHash = Issue10PerformanceTelemetryOptions.HashFile(actualPath);
        process.Refresh();
        var startAfter = new DateTimeOffset(process.StartTime.ToUniversalTime(), TimeSpan.Zero);
        if (process.HasExited || startBefore != startAfter || startAfter != expectedStartUtc ||
            !string.Equals(actualPath, Path.GetFullPath(expectedPath), StringComparison.OrdinalIgnoreCase) ||
            !actualHash.Equals(expectedSha256, StringComparison.Ordinal))
        {
            throw new UnauthorizedAccessException($"Issue #10 {context} PID/start/path/hash identity is invalid.");
        }
        return (startAfter, actualPath);
    }

    private static void RejectRequestDuplicates(JsonElement root)
    {
        if (root.ValueKind != JsonValueKind.Object) throw new InvalidDataException("Issue #10 sample request must be an object.");
        var actual = root.EnumerateObject().Select(property => property.Name).ToArray();
        if (actual.Distinct(StringComparer.Ordinal).Count() != actual.Length) throw new InvalidDataException("Issue #10 sample request contains duplicate properties.");
    }

    private static void RequireExactRequestShape(JsonElement root, string[] expected)
    {
        var actual = root.EnumerateObject().Select(property => property.Name).ToArray();
        if (actual.Length != expected.Length || actual.Except(expected, StringComparer.Ordinal).Any())
        {
            throw new InvalidDataException("Issue #10 sample request shape is invalid.");
        }
    }

    private static DateTimeOffset ParseRequestUtc(JsonElement value, string context)
    {
        if (value.ValueKind != JsonValueKind.String ||
            !DateTimeOffset.TryParseExact(value.GetString(), "O", CultureInfo.InvariantCulture,
                DateTimeStyles.None, out var parsed) ||
            parsed.Offset != TimeSpan.Zero)
        {
            throw new InvalidDataException($"Issue #10 {context} is invalid.");
        }
        return parsed;
    }

    public async ValueTask DisposeAsync()
    {
        try
        {
            _options.PackageLease.Revalidate("telemetry shutdown");
        }
        finally
        {
            try
            {
                if (_writer is not null) await _writer.DisposeAsync();
                _reader?.Dispose();
                _pipe?.Dispose();
            }
            finally { _options.PackageLease.Dispose(); }
        }
    }

    [DllImport("user32.dll")]
    private static extern int GetSystemMetrics(int index);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool GetNamedPipeServerProcessId(IntPtr pipe, out uint processId);

    private static int GetServerProcessId(IntPtr handle) =>
        GetNamedPipeServerProcessId(handle, out var processId) && processId > 0
            ? checked((int)processId)
            : throw new InvalidOperationException("Issue #10 telemetry pipe server PID is unavailable.");

    internal sealed record SampleRequest(
        int SchemaVersion,
        string Kind,
        string RunNonce,
        int SequenceNumber,
        string Order,
        bool IsWarmup,
        int RepetitionOrdinal,
        string SemanticMode,
        bool IsSoak,
        int BinIndex,
        int SampleIndex,
        int CoreProcessId,
        DateTimeOffset CoreStartUtc);
}
