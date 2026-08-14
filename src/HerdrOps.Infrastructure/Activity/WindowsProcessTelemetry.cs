using System.ComponentModel;
using System.Diagnostics;
using System.Globalization;
using System.Security.Cryptography;
using System.Text;
using HerdrOps.Domain.Activity;
using HerdrOps.Infrastructure.Herdr;

namespace HerdrOps.Infrastructure.Activity;

public enum WindowsProcessReadFailure
{
    None = 0,
    ProcessNotFound = 1,
    ProcessExited = 2,
    AccessDenied = 3,
    Unsupported = 4,
    Unavailable = 5,
}

public sealed record WindowsProcessSample(
    int ProcessId,
    DateTimeOffset ProcessStartUtc,
    string ProcessName,
    DateTimeOffset ObservedUtc,
    TimeSpan TotalProcessorTime,
    long WorkingSetBytes,
    long PrivateMemoryBytes);

public sealed record WindowsProcessReadResult(
    int ProcessId,
    WindowsProcessSample? Sample,
    WindowsProcessReadFailure Failure)
{
    public bool IsAvailable => Failure == WindowsProcessReadFailure.None && Sample is not null;
}

public interface IWindowsProcessSnapshotReader
{
    WindowsProcessReadResult Read(int processId, DateTimeOffset observedUtc);
}

/// <summary>
/// Reads a single Windows process snapshot without retaining handles or exposing exception text.
/// </summary>
public sealed class WindowsProcessSnapshotReader : IWindowsProcessSnapshotReader
{
    public WindowsProcessReadResult Read(int processId, DateTimeOffset observedUtc)
    {
        if (processId <= 0)
        {
            throw new ArgumentOutOfRangeException(nameof(processId), "A process identifier must be positive.");
        }

        EnsureUtc(observedUtc, nameof(observedUtc));
        try
        {
            using var process = Process.GetProcessById(processId);
            process.Refresh();
            var sample = new WindowsProcessSample(
                processId,
                new DateTimeOffset(process.StartTime.ToUniversalTime()),
                BoundProcessName(process.ProcessName),
                observedUtc,
                process.TotalProcessorTime,
                Math.Max(0, process.WorkingSet64),
                Math.Max(0, process.PrivateMemorySize64));
            return new WindowsProcessReadResult(processId, sample, WindowsProcessReadFailure.None);
        }
        catch (ArgumentException)
        {
            return Failed(processId, WindowsProcessReadFailure.ProcessNotFound);
        }
        catch (InvalidOperationException)
        {
            return Failed(processId, WindowsProcessReadFailure.ProcessExited);
        }
        catch (Win32Exception exception) when (exception.NativeErrorCode == 5)
        {
            return Failed(processId, WindowsProcessReadFailure.AccessDenied);
        }
        catch (Win32Exception)
        {
            return Failed(processId, WindowsProcessReadFailure.Unavailable);
        }
        catch (NotSupportedException)
        {
            return Failed(processId, WindowsProcessReadFailure.Unsupported);
        }
    }

    private static WindowsProcessReadResult Failed(int processId, WindowsProcessReadFailure failure) =>
        new(processId, null, failure);

    private static string BoundProcessName(string processName)
    {
        if (string.IsNullOrWhiteSpace(processName))
        {
            return "unknown";
        }

        var normalized = processName.Trim().Normalize(NormalizationForm.FormC);
        return normalized.Length <= ActivityEventContract.MaximumIdentifierLength
            ? normalized
            : normalized[..ActivityEventContract.MaximumIdentifierLength];
    }

    private static void EnsureUtc(DateTimeOffset value, string name)
    {
        if (value.Offset != TimeSpan.Zero)
        {
            throw new ArgumentException("Process observation timestamps must use UTC.", name);
        }
    }
}

public sealed record WindowsProcessTelemetryOptions(
    TimeSpan TimeToLive,
    int MaximumTrackedProcesses,
    int ProcessorCount)
{
    public static WindowsProcessTelemetryOptions Default { get; } = new(
        TimeSpan.FromSeconds(15),
        1024,
        Math.Max(1, Environment.ProcessorCount));

    public void Validate()
    {
        if (TimeToLive < TimeSpan.FromSeconds(1) || TimeToLive > TimeSpan.FromMinutes(10))
        {
            throw new ArgumentOutOfRangeException(
                nameof(TimeToLive),
                "Process telemetry must expire between one second and ten minutes.");
        }

        if (MaximumTrackedProcesses is < 1 or > 16384)
        {
            throw new ArgumentOutOfRangeException(
                nameof(MaximumTrackedProcesses),
                "The tracked process bound must be between 1 and 16384.");
        }

        if (ProcessorCount is < 1 or > 4096)
        {
            throw new ArgumentOutOfRangeException(
                nameof(ProcessorCount),
                "The processor count must be between 1 and 4096.");
        }
    }
}

public enum HerdrReportedProcessSource
{
    Shell = 1,
    Foreground = 2,
}

public sealed record WindowsProcessTelemetryObservation(
    string PaneId,
    int ProcessId,
    DateTimeOffset ProcessStartUtc,
    string ProcessName,
    HerdrReportedProcessSource ReportedSource,
    string ReportedProcessName,
    string ReportedCommandSha256,
    string RedactedCommandSummary,
    int CommandRedactionCount,
    DateTimeOffset ObservedUtc,
    DateTimeOffset ExpiresUtc,
    double? CpuPercent,
    long WorkingSetBytes,
    long PrivateMemoryBytes);

public sealed record WindowsProcessCorrelationFailure(
    string PaneId,
    uint ReportedProcessId,
    HerdrReportedProcessSource ReportedSource,
    WindowsProcessReadFailure Failure);

public sealed record WindowsProcessCorrelationBatch(
    IReadOnlyList<WindowsProcessTelemetryObservation> Observations,
    IReadOnlyList<WindowsProcessCorrelationFailure> Failures,
    int ExpiredCount);

/// <summary>
/// Correlates only PIDs reported by pane.process_info. PID plus process start time is the
/// stable identity, so PID reuse never inherits an earlier CPU baseline.
/// </summary>
public sealed class WindowsProcessTelemetryTracker
{
    private readonly object _gate = new();
    private readonly WindowsProcessTelemetryOptions _options;
    private readonly Dictionary<ProcessIdentity, TrackedProcess> _tracked = [];
    private long _evictionCount;

    public WindowsProcessTelemetryTracker(WindowsProcessTelemetryOptions? options = null)
    {
        _options = options ?? WindowsProcessTelemetryOptions.Default;
        _options.Validate();
    }

    public int TrackedProcessCount { get { lock (_gate) { return _tracked.Count; } } }

    public long EvictionCount { get { lock (_gate) { return _evictionCount; } } }

    public WindowsProcessTelemetryObservation Observe(
        string paneId,
        HerdrReportedProcessSource reportedSource,
        string reportedProcessName,
        string? reportedCommandLine,
        WindowsProcessSample sample,
        SensitiveTextRedactor redactor)
    {
        paneId = NormalizePaneId(paneId);
        ArgumentNullException.ThrowIfNull(sample);
        ArgumentNullException.ThrowIfNull(redactor);
        if (!Enum.IsDefined(reportedSource))
        {
            throw new ArgumentOutOfRangeException(nameof(reportedSource));
        }

        if (sample.ProcessId <= 0)
        {
            throw new ArgumentOutOfRangeException(nameof(sample), "A sampled process identifier must be positive.");
        }

        EnsureUtc(sample.ProcessStartUtc, nameof(sample.ProcessStartUtc));
        EnsureUtc(sample.ObservedUtc, nameof(sample.ObservedUtc));
        if (sample.TotalProcessorTime < TimeSpan.Zero ||
            sample.WorkingSetBytes < 0 ||
            sample.PrivateMemoryBytes < 0)
        {
            throw new ArgumentOutOfRangeException(nameof(sample), "Process counters cannot be negative.");
        }

        var commandText = string.IsNullOrWhiteSpace(reportedCommandLine)
            ? reportedProcessName
            : reportedCommandLine;
        var commandRedaction = redactor.Redact(commandText ?? string.Empty);
        var identity = new ProcessIdentity(sample.ProcessId, sample.ProcessStartUtc);
        lock (_gate)
        {
            RemoveExpired(sample.ObservedUtc);
            RemoveReusedPid(identity);
            _tracked.TryGetValue(identity, out var previous);
            var cpuPercent = CalculateCpuPercent(previous?.Sample, sample);
            var observation = new WindowsProcessTelemetryObservation(
                paneId,
                sample.ProcessId,
                sample.ProcessStartUtc,
                NormalizeProcessName(sample.ProcessName),
                reportedSource,
                NormalizeProcessName(reportedProcessName),
                commandRedaction.OriginalSha256,
                commandRedaction.RedactedText,
                commandRedaction.ReplacementCount,
                sample.ObservedUtc,
                sample.ObservedUtc.Add(_options.TimeToLive),
                cpuPercent,
                sample.WorkingSetBytes,
                sample.PrivateMemoryBytes);
            _tracked[identity] = new TrackedProcess(sample, observation);
            EnforceBound();
            return observation;
        }
    }

    public int Expire(DateTimeOffset observedUtc)
    {
        EnsureUtc(observedUtc, nameof(observedUtc));
        lock (_gate)
        {
            return RemoveExpired(observedUtc);
        }
    }

    public IReadOnlyList<WindowsProcessTelemetryObservation> Snapshot(DateTimeOffset observedUtc)
    {
        EnsureUtc(observedUtc, nameof(observedUtc));
        lock (_gate)
        {
            RemoveExpired(observedUtc);
            return _tracked.Values
                .Select(item => item.Observation)
                .OrderBy(item => item.PaneId, StringComparer.Ordinal)
                .ThenBy(item => item.ProcessId)
                .ThenBy(item => item.ProcessStartUtc)
                .ToArray();
        }
    }

    private double? CalculateCpuPercent(WindowsProcessSample? previous, WindowsProcessSample current)
    {
        if (previous is null || current.ObservedUtc <= previous.ObservedUtc)
        {
            return null;
        }

        var processorDelta = current.TotalProcessorTime - previous.TotalProcessorTime;
        var elapsed = current.ObservedUtc - previous.ObservedUtc;
        if (processorDelta < TimeSpan.Zero || elapsed <= TimeSpan.Zero)
        {
            return null;
        }

        var percent = processorDelta.TotalMilliseconds /
                      elapsed.TotalMilliseconds /
                      _options.ProcessorCount *
                      100d;
        return Math.Round(Math.Clamp(percent, 0d, 100d), 3, MidpointRounding.AwayFromZero);
    }

    private int RemoveExpired(DateTimeOffset observedUtc)
    {
        var expired = _tracked
            .Where(item => item.Value.Observation.ExpiresUtc <= observedUtc)
            .Select(item => item.Key)
            .ToArray();
        foreach (var identity in expired)
        {
            _tracked.Remove(identity);
        }

        return expired.Length;
    }

    private void RemoveReusedPid(ProcessIdentity current)
    {
        var reused = _tracked.Keys
            .Where(identity => identity.ProcessId == current.ProcessId && identity != current)
            .ToArray();
        foreach (var identity in reused)
        {
            _tracked.Remove(identity);
        }
    }

    private void EnforceBound()
    {
        while (_tracked.Count > _options.MaximumTrackedProcesses)
        {
            var oldest = _tracked
                .OrderBy(item => item.Value.Observation.ObservedUtc)
                .ThenBy(item => item.Key.ProcessId)
                .ThenBy(item => item.Key.ProcessStartUtc)
                .First();
            _tracked.Remove(oldest.Key);
            _evictionCount++;
        }
    }

    private static string NormalizePaneId(string paneId)
    {
        if (string.IsNullOrWhiteSpace(paneId))
        {
            throw new ArgumentException("A pane identifier is required.", nameof(paneId));
        }

        var normalized = paneId.Trim().Normalize(NormalizationForm.FormC);
        if (normalized.Length > ActivityEventContract.MaximumIdentifierLength)
        {
            throw new ArgumentOutOfRangeException(nameof(paneId), "The pane identifier is too long.");
        }

        return normalized;
    }

    private static string NormalizeProcessName(string? value)
    {
        var normalized = string.IsNullOrWhiteSpace(value)
            ? "unknown"
            : value.Trim().Normalize(NormalizationForm.FormC);
        return normalized.Length <= ActivityEventContract.MaximumIdentifierLength
            ? normalized
            : normalized[..ActivityEventContract.MaximumIdentifierLength];
    }

    private static void EnsureUtc(DateTimeOffset value, string name)
    {
        if (value.Offset != TimeSpan.Zero)
        {
            throw new ArgumentException("Process telemetry timestamps must use UTC.", name);
        }
    }

    private sealed record ProcessIdentity(int ProcessId, DateTimeOffset ProcessStartUtc);

    private sealed record TrackedProcess(
        WindowsProcessSample Sample,
        WindowsProcessTelemetryObservation Observation);
}

public sealed class WindowsProcessCorrelationCollector
{
    private readonly IWindowsProcessSnapshotReader _reader;
    private readonly WindowsProcessTelemetryTracker _tracker;
    private readonly SensitiveTextRedactor _redactor;

    public WindowsProcessCorrelationCollector(
        IWindowsProcessSnapshotReader? reader = null,
        WindowsProcessTelemetryTracker? tracker = null,
        SensitiveTextRedactor? redactor = null)
    {
        _reader = reader ?? new WindowsProcessSnapshotReader();
        _tracker = tracker ?? new WindowsProcessTelemetryTracker();
        _redactor = redactor ?? new SensitiveTextRedactor();
    }

    public WindowsProcessCorrelationBatch Collect(
        HerdrPaneProcessInfo processInfo,
        DateTimeOffset observedUtc)
    {
        ArgumentNullException.ThrowIfNull(processInfo);
        if (observedUtc.Offset != TimeSpan.Zero)
        {
            throw new ArgumentException("Process correlation timestamps must use UTC.", nameof(observedUtc));
        }

        var expiredCount = _tracker.Expire(observedUtc);
        var observations = new List<WindowsProcessTelemetryObservation>();
        var failures = new List<WindowsProcessCorrelationFailure>();
        foreach (var source in EnumerateReportedProcesses(processInfo))
        {
            if (source.ProcessId > int.MaxValue)
            {
                failures.Add(new WindowsProcessCorrelationFailure(
                    processInfo.PaneId,
                    source.ProcessId,
                    source.Source,
                    WindowsProcessReadFailure.Unsupported));
                continue;
            }

            var processId = checked((int)source.ProcessId);
            var result = _reader.Read(processId, observedUtc);
            if (!result.IsAvailable)
            {
                failures.Add(new WindowsProcessCorrelationFailure(
                    processInfo.PaneId,
                    source.ProcessId,
                    source.Source,
                    result.Failure));
                continue;
            }

            observations.Add(_tracker.Observe(
                processInfo.PaneId,
                source.Source,
                source.Name,
                source.CommandLine,
                result.Sample!,
                _redactor));
        }

        return new WindowsProcessCorrelationBatch(
            observations.AsReadOnly(),
            failures.AsReadOnly(),
            expiredCount);
    }

    private static IReadOnlyList<ReportedProcess> EnumerateReportedProcesses(
        HerdrPaneProcessInfo processInfo)
    {
        var reported = new Dictionary<uint, ReportedProcess>();
        if (processInfo.ShellProcessId is uint shellProcessId)
        {
            reported[shellProcessId] = new ReportedProcess(
                shellProcessId,
                HerdrReportedProcessSource.Shell,
                "shell",
                null);
        }

        foreach (var process in processInfo.ForegroundProcesses)
        {
            var commandLine = process.CommandLine;
            if (string.IsNullOrWhiteSpace(commandLine) && process.Arguments is { Count: > 0 })
            {
                commandLine = string.Join(' ', process.Arguments);
            }

            if (string.IsNullOrWhiteSpace(commandLine))
            {
                commandLine = process.Argv0;
            }

            reported[process.ProcessId] = new ReportedProcess(
                process.ProcessId,
                HerdrReportedProcessSource.Foreground,
                process.Name,
                commandLine);
        }

        return reported.Values
            .OrderBy(item => item.ProcessId)
            .ToArray();
    }

    private sealed record ReportedProcess(
        uint ProcessId,
        HerdrReportedProcessSource Source,
        string Name,
        string? CommandLine);
}
