using System.Diagnostics;
using System.Text;
using HerdrOps.Domain.Activity;

namespace HerdrOps.Infrastructure.Activity;

public sealed record GitActivityReaderOptions(
    int MaximumOutputUtf8Bytes,
    int MaximumStatusEntries,
    TimeSpan CommandTimeout)
{
    public static GitActivityReaderOptions Default { get; } = new(
        MaximumOutputUtf8Bytes: 256 * 1024,
        MaximumStatusEntries: 4096,
        CommandTimeout: TimeSpan.FromSeconds(5));

    public void Validate()
    {
        if (MaximumOutputUtf8Bytes is < 4096 or > 1024 * 1024)
        {
            throw new ArgumentOutOfRangeException(
                nameof(MaximumOutputUtf8Bytes),
                "Git output must be bounded between 4 KiB and 1 MiB.");
        }

        if (MaximumStatusEntries is < 1 or > 65_536)
        {
            throw new ArgumentOutOfRangeException(
                nameof(MaximumStatusEntries),
                "A Git status snapshot must contain between 1 and 65,536 entries.");
        }

        if (CommandTimeout < TimeSpan.FromMilliseconds(250) ||
            CommandTimeout > TimeSpan.FromMinutes(1))
        {
            throw new ArgumentOutOfRangeException(
                nameof(CommandTimeout),
                "A Git read command timeout must be between 250 milliseconds and 1 minute.");
        }
    }
}

public sealed record BoundedGitCommandResult(
    int ExitCode,
    string StandardOutput,
    string RedactedStandardError);

public interface IBoundedGitCommandExecutor
{
    Task<BoundedGitCommandResult> ExecuteAsync(
        string repositoryRoot,
        IReadOnlyList<string> arguments,
        int maximumOutputUtf8Bytes,
        TimeSpan timeout,
        CancellationToken cancellationToken);
}

/// <summary>
/// Executes Git directly (never through a shell), drains output concurrently, enforces byte
/// and time bounds, disables optional locks and prompts, and redacts stderr before returning.
/// </summary>
public sealed class BoundedGitCommandExecutor : IBoundedGitCommandExecutor
{
    private const int MaximumStandardErrorUtf8Bytes = 64 * 1024;
    private readonly string _gitExecutable;
    private readonly SensitiveTextRedactor _redactor;

    public BoundedGitCommandExecutor(
        string gitExecutable = "git",
        SensitiveTextRedactor? redactor = null)
    {
        if (string.IsNullOrWhiteSpace(gitExecutable))
        {
            throw new ArgumentException("A Git executable is required.", nameof(gitExecutable));
        }

        _gitExecutable = gitExecutable;
        _redactor = redactor ?? new SensitiveTextRedactor();
    }

    public async Task<BoundedGitCommandResult> ExecuteAsync(
        string repositoryRoot,
        IReadOnlyList<string> arguments,
        int maximumOutputUtf8Bytes,
        TimeSpan timeout,
        CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(arguments);
        var startInfo = new ProcessStartInfo
        {
            FileName = _gitExecutable,
            WorkingDirectory = repositoryRoot,
            UseShellExecute = false,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            CreateNoWindow = true,
        };
        foreach (var argument in arguments)
        {
            startInfo.ArgumentList.Add(argument);
        }

        startInfo.Environment["GIT_OPTIONAL_LOCKS"] = "0";
        startInfo.Environment["GIT_TERMINAL_PROMPT"] = "0";
        startInfo.Environment["GCM_INTERACTIVE"] = "Never";
        startInfo.Environment["GIT_CONFIG_NOSYSTEM"] = "1";
        startInfo.Environment["GIT_CONFIG_GLOBAL"] = OperatingSystem.IsWindows() ? "NUL" : "/dev/null";
        startInfo.Environment["GIT_ATTR_NOSYSTEM"] = "1";
        startInfo.Environment["GIT_PAGER"] = "cat";
        startInfo.Environment["LC_ALL"] = "C";
        foreach (var inheritedOverride in new[]
                 {
                     "GIT_ALTERNATE_OBJECT_DIRECTORIES",
                     "GIT_COMMON_DIR",
                     "GIT_CONFIG_COUNT",
                     "GIT_CONFIG_SYSTEM",
                     "GIT_DIR",
                     "GIT_EXEC_PATH",
                     "GIT_INDEX_FILE",
                     "GIT_OBJECT_DIRECTORY",
                     "GIT_WORK_TREE",
                 })
        {
            startInfo.Environment.Remove(inheritedOverride);
        }

        using var process = new Process { StartInfo = startInfo };
        if (!process.Start())
        {
            throw new InvalidOperationException("Git could not be started.");
        }

        using var timeoutSource = new CancellationTokenSource(timeout);
        using var linkedSource = CancellationTokenSource.CreateLinkedTokenSource(
            timeoutSource.Token,
            cancellationToken);
        var outputTask = ReadBoundedAsync(
            process.StandardOutput.BaseStream,
            maximumOutputUtf8Bytes,
            linkedSource.Token);
        var errorTask = ReadBoundedAsync(
            process.StandardError.BaseStream,
            MaximumStandardErrorUtf8Bytes,
            linkedSource.Token);

        try
        {
            await process.WaitForExitAsync(linkedSource.Token).ConfigureAwait(false);
            var output = await outputTask.ConfigureAwait(false);
            var error = await errorTask.ConfigureAwait(false);
            var errorText = DecodeUtf8(error);
            var redactedError = string.IsNullOrEmpty(errorText)
                ? string.Empty
                : _redactor.Redact(errorText).RedactedText;
            return new BoundedGitCommandResult(
                process.ExitCode,
                DecodeUtf8(output),
                redactedError);
        }
        catch
        {
            TryKill(process);
            if (timeoutSource.IsCancellationRequested && !cancellationToken.IsCancellationRequested)
            {
                throw new TimeoutException($"Git exceeded the {timeout.TotalSeconds:0.###}-second read timeout.");
            }

            throw;
        }
    }

    private static async Task<byte[]> ReadBoundedAsync(
        Stream stream,
        int maximumBytes,
        CancellationToken cancellationToken)
    {
        using var output = new MemoryStream(Math.Min(maximumBytes, 64 * 1024));
        var buffer = new byte[8192];
        while (true)
        {
            var read = await stream.ReadAsync(buffer, cancellationToken).ConfigureAwait(false);
            if (read == 0)
            {
                break;
            }

            if (output.Length + read > maximumBytes)
            {
                throw new GitOutputLimitExceededException(maximumBytes);
            }

            output.Write(buffer, 0, read);
        }

        return output.ToArray();
    }

    private static string DecodeUtf8(byte[] value) =>
        new UTF8Encoding(encoderShouldEmitUTF8Identifier: false, throwOnInvalidBytes: true)
            .GetString(value);

    private static void TryKill(Process process)
    {
        try
        {
            if (!process.HasExited)
            {
                process.Kill(entireProcessTree: true);
            }
        }
        catch (InvalidOperationException)
        {
            // The process exited between the check and the kill request.
        }
    }
}

public sealed class GitOutputLimitExceededException(int maximumBytes)
    : IOException($"Git output exceeded the explicit {maximumBytes}-byte bound.");

public sealed record GitDiffPreview(
    string RelativePath,
    string RedactedText,
    string OriginalSha256,
    string RedactedSha256,
    int RedactionCount,
    bool WasTruncated);

public sealed class GitRepositoryActivityReader
{
    private static readonly IReadOnlyList<string> StatusArguments =
    [
        "-c",
        "core.quotepath=false",
        "-c",
        "core.fsmonitor=false",
        "-c",
        "core.untrackedCache=false",
        "-c",
        "core.excludesFile=NUL",
        "-c",
        "core.attributesFile=NUL",
        "-c",
        "maintenance.auto=false",
        "-c",
        "gc.auto=0",
        "-c",
        "submodule.recurse=false",
        "status",
        "--porcelain=v2",
        "-z",
        "--untracked-files=all",
        "--ignore-submodules=all",
    ];

    private readonly AuthorizedRepositoryScope _scope;
    private readonly GitActivityReaderOptions _options;
    private readonly IBoundedGitCommandExecutor _executor;
    private readonly SensitiveTextRedactor _redactor;
    private readonly TimeProvider _timeProvider;
    private long _sourceSequence;

    public GitRepositoryActivityReader(
        AuthorizedRepositoryScope scope,
        GitActivityReaderOptions? options = null,
        IBoundedGitCommandExecutor? executor = null,
        SensitiveTextRedactor? redactor = null,
        TimeProvider? timeProvider = null)
    {
        _scope = scope ?? throw new ArgumentNullException(nameof(scope));
        _options = options ?? GitActivityReaderOptions.Default;
        _options.Validate();
        _redactor = redactor ?? new SensitiveTextRedactor();
        _executor = executor ?? new BoundedGitCommandExecutor(redactor: _redactor);
        _timeProvider = timeProvider ?? TimeProvider.System;
    }

    public string SourceInstanceId => $"git:{_scope.RootIdentity}";

    public async Task<IReadOnlyList<FileActivityObservation>> ReadStatusAsync(
        CancellationToken cancellationToken = default)
    {
        var gitDirectory = EnsureRepositoryMetadataIsScoped();
        var result = await _executor.ExecuteAsync(
            _scope.DeclaredRoot,
            CreateScopedArguments(gitDirectory, StatusArguments),
            _options.MaximumOutputUtf8Bytes,
            _options.CommandTimeout,
            cancellationToken).ConfigureAwait(false);
        EnsureSuccess(result, "status");

        var entries = GitPorcelainV2Parser.Parse(
            result.StandardOutput,
            _options.MaximumStatusEntries);
        var observations = new List<FileActivityObservation>(entries.Count);
        foreach (var entry in entries)
        {
            observations.Add(Project(entry));
        }

        return observations;
    }

    public async Task<GitDiffPreview> ReadWorkingTreeDiffAsync(
        string candidatePath,
        CancellationToken cancellationToken = default)
    {
        var gitDirectory = EnsureRepositoryMetadataIsScoped();
        var decision = _scope.Evaluate(candidatePath);
        if (!decision.IsAuthorized)
        {
            throw new UnauthorizedAccessException(
                $"The diff path is not authorized: {decision.Reason}");
        }

        var relativePath = decision.RelativePath!;
        IReadOnlyList<string> arguments =
        [
            "-c",
            "core.quotepath=false",
            "-c",
            "core.fsmonitor=false",
            "-c",
            "core.excludesFile=NUL",
            "-c",
            "core.attributesFile=NUL",
            "-c",
            "maintenance.auto=false",
            "-c",
            "gc.auto=0",
            "diff",
            "--no-ext-diff",
            "--no-textconv",
            "--unified=3",
            "--",
            $":(literal){relativePath}",
        ];
        var result = await _executor.ExecuteAsync(
            _scope.DeclaredRoot,
            CreateScopedArguments(gitDirectory, arguments),
            _options.MaximumOutputUtf8Bytes,
            _options.CommandTimeout,
            cancellationToken).ConfigureAwait(false);
        EnsureSuccess(result, "diff");
        var redaction = _redactor.Redact(result.StandardOutput);
        return new GitDiffPreview(
            relativePath,
            redaction.RedactedText,
            redaction.OriginalSha256,
            redaction.RedactedSha256,
            redaction.ReplacementCount,
            redaction.WasTruncated);
    }

    private FileActivityObservation Project(GitStatusEntry entry)
    {
        if (entry.Path.Any(char.IsControl) ||
            (entry.OriginalPath?.Any(char.IsControl) ?? false))
        {
            return Blocked("path-display-unsafe");
        }

        var current = _scope.Evaluate(Path.Combine(_scope.DeclaredRoot, entry.Path));
        var original = entry.OriginalPath is null
            ? null
            : _scope.Evaluate(Path.Combine(_scope.DeclaredRoot, entry.OriginalPath));
        if (!current.IsAuthorized)
        {
            return Blocked(current.Reason);
        }

        if (original is { IsAuthorized: false })
        {
            return Blocked($"previous-{original.Reason}");
        }

        return FileActivityContract.NormalizeAndValidate(new FileActivityObservation(
            Interlocked.Increment(ref _sourceSequence),
            _timeProvider.GetUtcNow(),
            entry.Operation,
            current.RelativePath!,
            original?.RelativePath,
            ActivitySourceKind.Git,
            SourceInstanceId,
            ActivityConfidence.Observed,
            true,
            "authorized"));
    }

    private string EnsureRepositoryMetadataIsScoped()
    {
        var dotGitPath = Path.Combine(_scope.DeclaredRoot, ".git");
        var dotGitDecision = _scope.Evaluate(dotGitPath);
        if (!dotGitDecision.IsAuthorized)
        {
            throw new UnauthorizedAccessException(
                $"Git metadata is not authorized: {dotGitDecision.Reason}");
        }

        string gitDirectory;
        if (Directory.Exists(dotGitPath))
        {
            gitDirectory = dotGitDecision.CanonicalPath!;
        }
        else if (File.Exists(dotGitPath))
        {
            var gitFile = ReadBoundedMetadataFile(dotGitPath, 4096);
            const string prefix = "gitdir:";
            if (!gitFile.StartsWith(prefix, StringComparison.OrdinalIgnoreCase))
            {
                throw new InvalidOperationException("The repository .git file is malformed.");
            }

            var target = gitFile[prefix.Length..].Trim();
            if (string.IsNullOrWhiteSpace(target))
            {
                throw new InvalidOperationException("The repository .git file has no target.");
            }

            var candidate = Path.IsPathFullyQualified(target)
                ? target
                : Path.Combine(_scope.DeclaredRoot, target);
            var targetDecision = _scope.Evaluate(candidate);
            if (!targetDecision.IsAuthorized || !Directory.Exists(candidate))
            {
                throw new UnauthorizedAccessException(
                    $"The repository gitdir target is not authorized: {targetDecision.Reason}");
            }

            gitDirectory = targetDecision.CanonicalPath!;
        }
        else
        {
            throw new InvalidOperationException("The authorized root is not a non-bare Git repository.");
        }

        var commonDirectory = ResolveCommonDirectory(gitDirectory);
        ValidateMetadataDirectoryIfPresent(
            Path.Combine(commonDirectory, "objects"),
            "Git object directory");
        ValidateMetadataDirectoryIfPresent(
            Path.Combine(commonDirectory, "refs"),
            "Git refs directory");
        ValidateConfigFile(Path.Combine(commonDirectory, "config"), "Git config");
        ValidateConfigFile(Path.Combine(gitDirectory, "config.worktree"), "Git worktree config");
        ValidateMetadataFileIfPresent(Path.Combine(gitDirectory, "HEAD"), "Git HEAD");
        ValidateMetadataFileIfPresent(Path.Combine(gitDirectory, "index"), "Git index");
        ValidateMetadataFileIfPresent(Path.Combine(commonDirectory, "packed-refs"), "Git packed refs");
        ValidateMetadataFileIfPresent(Path.Combine(commonDirectory, "shallow"), "Git shallow metadata");

        foreach (var alternatesName in new[] { "alternates", "http-alternates" })
        {
            var alternatesPath = Path.Combine(commonDirectory, "objects", "info", alternatesName);
            if (ValidateMetadataFileIfPresent(alternatesPath, "Git object alternates") &&
                new FileInfo(alternatesPath).Length > 0)
            {
                throw new UnauthorizedAccessException(
                    "Git object alternates are not permitted for scoped collection.");
            }
        }

        return gitDirectory;
    }

    private string ResolveCommonDirectory(string gitDirectory)
    {
        var commonDirectoryPath = Path.Combine(gitDirectory, "commondir");
        if (!ValidateMetadataFileIfPresent(commonDirectoryPath, "Git common-directory pointer"))
        {
            return gitDirectory;
        }

        var target = ReadBoundedMetadataFile(commonDirectoryPath, 4096).Trim();
        if (string.IsNullOrWhiteSpace(target))
        {
            throw new InvalidOperationException("The repository commondir file has no target.");
        }

        var candidate = Path.IsPathFullyQualified(target)
            ? target
            : Path.Combine(gitDirectory, target);
        var decision = _scope.Evaluate(candidate);
        if (!decision.IsAuthorized || !Directory.Exists(candidate))
        {
            throw new UnauthorizedAccessException(
                $"The repository common directory is not authorized: {decision.Reason}");
        }

        return decision.CanonicalPath!;
    }

    private IReadOnlyList<string> CreateScopedArguments(
        string gitDirectory,
        IReadOnlyList<string> commandArguments) =>
    [
        $"--git-dir={gitDirectory}",
        $"--work-tree={_scope.DeclaredRoot}",
        .. commandArguments,
    ];

    private void EnsureScopedMetadataPath(string path, string description)
    {
        var decision = _scope.Evaluate(path);
        if (!decision.IsAuthorized)
        {
            throw new UnauthorizedAccessException(
                $"{description} is not authorized: {decision.Reason}");
        }
    }

    private bool ValidateMetadataFileIfPresent(string path, string description)
    {
        EnsureScopedMetadataPath(path, description);
        return File.Exists(path);
    }

    private void ValidateMetadataDirectoryIfPresent(string path, string description)
    {
        EnsureScopedMetadataPath(path, description);
        if (File.Exists(path))
        {
            throw new InvalidOperationException($"{description} must be a directory.");
        }
    }

    private void ValidateConfigFile(string path, string description)
    {
        if (!ValidateMetadataFileIfPresent(path, description))
        {
            return;
        }

        var config = ReadBoundedMetadataFile(path, 256 * 1024);
        if (ContainsConfigInclude(config))
        {
            throw new UnauthorizedAccessException(
                "Repository-local Git config includes are not permitted for scoped collection.");
        }
    }

    private static string ReadBoundedMetadataFile(string path, int maximumBytes)
    {
        using var stream = new FileStream(
            path,
            FileMode.Open,
            FileAccess.Read,
            FileShare.Read,
            bufferSize: 4096,
            FileOptions.SequentialScan);
        if (stream.Length < 1 || stream.Length > maximumBytes)
        {
            throw new InvalidOperationException(
                $"Git metadata must contain between 1 and {maximumBytes} bytes.");
        }

        var bytes = new byte[stream.Length];
        stream.ReadExactly(bytes);
        return new UTF8Encoding(false, true).GetString(bytes);
    }

    private static bool ContainsConfigInclude(string config)
    {
        var section = string.Empty;
        foreach (var rawLine in config.Replace("\r\n", "\n", StringComparison.Ordinal).Split('\n'))
        {
            var line = rawLine.Trim();
            if (line.StartsWith("[", StringComparison.Ordinal) && line.EndsWith(']'))
            {
                section = line[1..^1].Trim();
                if (section.StartsWith("include", StringComparison.OrdinalIgnoreCase))
                {
                    return true;
                }
            }
        }

        return false;
    }

    private FileActivityObservation Blocked(string reason) =>
        FileActivityContract.NormalizeAndValidate(new FileActivityObservation(
            Interlocked.Increment(ref _sourceSequence),
            _timeProvider.GetUtcNow(),
            FileActivityOperation.ScopeBlocked,
            "[blocked]",
            null,
            ActivitySourceKind.Git,
            SourceInstanceId,
            ActivityConfidence.Observed,
            false,
            reason));

    private static void EnsureSuccess(BoundedGitCommandResult result, string operation)
    {
        if (result.ExitCode != 0)
        {
            throw new InvalidOperationException(
                $"The read-only Git {operation} command failed with exit code {result.ExitCode}: {result.RedactedStandardError}");
        }
    }
}

public sealed record GitStatusEntry(
    FileActivityOperation Operation,
    string Path,
    string? OriginalPath);

public static class GitPorcelainV2Parser
{
    public static IReadOnlyList<GitStatusEntry> Parse(string value, int maximumEntries)
    {
        ArgumentNullException.ThrowIfNull(value);
        if (maximumEntries <= 0)
        {
            throw new ArgumentOutOfRangeException(nameof(maximumEntries));
        }

        var records = value.Split('\0');
        var entries = new List<GitStatusEntry>();
        for (var index = 0; index < records.Length; index++)
        {
            var record = records[index];
            if (record.Length == 0 || record[0] is '#' or '!')
            {
                continue;
            }

            GitStatusEntry entry;
            if (record.StartsWith("? ", StringComparison.Ordinal))
            {
                entry = new GitStatusEntry(
                    FileActivityOperation.Created,
                    record[2..],
                    null);
            }
            else if (record.StartsWith("1 ", StringComparison.Ordinal))
            {
                var fields = record.Split(' ', 9, StringSplitOptions.None);
                RequireFieldCount(fields, 9, record);
                entry = new GitStatusEntry(
                    MapOperation(fields[1]),
                    fields[8],
                    null);
            }
            else if (record.StartsWith("2 ", StringComparison.Ordinal))
            {
                var fields = record.Split(' ', 10, StringSplitOptions.None);
                RequireFieldCount(fields, 10, record);
                if (++index >= records.Length || records[index].Length == 0)
                {
                    throw new FormatException("A Git rename record is missing its original path.");
                }

                entry = new GitStatusEntry(
                    FileActivityOperation.Renamed,
                    fields[9],
                    records[index]);
            }
            else if (record.StartsWith("u ", StringComparison.Ordinal))
            {
                var fields = record.Split(' ', 11, StringSplitOptions.None);
                RequireFieldCount(fields, 11, record);
                entry = new GitStatusEntry(
                    FileActivityOperation.Modified,
                    fields[10],
                    null);
            }
            else
            {
                throw new FormatException("Git returned an unsupported porcelain-v2 record.");
            }

            entries.Add(entry);
            if (entries.Count > maximumEntries)
            {
                throw new GitOutputLimitExceededException(maximumEntries);
            }
        }

        return entries;
    }

    private static FileActivityOperation MapOperation(string status)
    {
        if (status.Length != 2)
        {
            throw new FormatException("A Git porcelain-v2 XY status must contain two characters.");
        }

        return status.Contains('D')
            ? FileActivityOperation.Deleted
            : status.Contains('A')
                ? FileActivityOperation.Created
                : FileActivityOperation.Modified;
    }

    private static void RequireFieldCount(string[] fields, int expected, string record)
    {
        if (fields.Length != expected || string.IsNullOrEmpty(fields[^1]))
        {
            throw new FormatException(
                $"Git returned a malformed porcelain-v2 record of type '{record[0]}'.");
        }
    }
}
