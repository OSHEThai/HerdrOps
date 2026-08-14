using System.Diagnostics;
using System.Text.Json;
using HerdrOps.Core;
using HerdrOps.Domain.Activity;
using HerdrOps.Infrastructure.Activity;

namespace HerdrOps.IntegrationTests;

[TestClass]
[DoNotParallelize]
public sealed class ScopedFileGitActivityTests
{
    [TestMethod]
    public void ScopeIsSeparatorAwareAndBlocksAbsoluteEscapeWithoutRetainingIt()
    {
        using var fixture = TemporaryDirectory.Create();
        var repository = Directory.CreateDirectory(Path.Combine(fixture.Path, "repo"));
        var similarlyNamed = Directory.CreateDirectory(Path.Combine(fixture.Path, "repo-secret"));
        var scope = new AuthorizedRepositoryScope(repository.FullName);

        var allowed = scope.Evaluate(Path.Combine(repository.FullName, "src", "service.cs"));
        var blocked = scope.Evaluate(Path.Combine(similarlyNamed.FullName, "secret.txt"));

        Assert.IsTrue(allowed.IsAuthorized);
        Assert.AreEqual("src/service.cs", allowed.RelativePath);
        Assert.IsFalse(blocked.IsAuthorized);
        Assert.IsNull(blocked.CanonicalPath);
        Assert.IsNull(blocked.RelativePath);
        Assert.AreEqual("outside-declared-root", blocked.Reason);
    }

    [TestMethod]
    public async Task FileSystemWatcherProducesActualScopedEventWithExplicitSourceAndConfidence()
    {
        using var fixture = TemporaryDirectory.Create();
        var repository = Directory.CreateDirectory(Path.Combine(fixture.Path, "repo"));
        var scope = new AuthorizedRepositoryScope(repository.FullName);
        await using var collector = new ScopedFileSystemActivityCollector(
            scope,
            new ScopedFileSystemCollectorOptions(32, IncludeSubdirectories: true));
        collector.Start();

        var observedTask = FirstMatchingAsync(
            collector.ReadAllAsync(),
            item => item.RelativePath == "actual-event.txt",
            TimeSpan.FromSeconds(10));
        await File.WriteAllTextAsync(
            Path.Combine(repository.FullName, "actual-event.txt"),
            "actual scoped FileSystemWatcher event");
        var observed = await observedTask;

        Assert.IsTrue(observed.IsAuthorized);
        Assert.AreEqual(ActivitySourceKind.FileSystem, observed.SourceKind);
        Assert.AreEqual(ActivityConfidence.Observed, observed.Confidence);
        Assert.StartsWith("filesystem:", observed.SourceInstanceId, StringComparison.Ordinal);
        Assert.IsTrue(observed.Operation is FileActivityOperation.Created or FileActivityOperation.Modified);
    }

    [TestMethod]
    public async Task FileSystemWatcherExcludesBuildMetadataBeforeQueueing()
    {
        using var fixture = TemporaryDirectory.Create();
        var repository = Directory.CreateDirectory(Path.Combine(fixture.Path, "repo"));
        var scope = new AuthorizedRepositoryScope(repository.FullName);
        await using var collector = new ScopedFileSystemActivityCollector(scope);

        Assert.IsTrue(collector.ShouldExclude("src/App/obj/Debug/generated.cs"));
        Assert.IsTrue(collector.ShouldExclude(".git/index"));
        Assert.IsFalse(collector.ShouldExclude("src/App/Service.cs"));
    }

    [TestMethod]
    public async Task FileSystemWatcherDebounceIndexRemainsHardBoundedDuringUniqueBurst()
    {
        using var fixture = TemporaryDirectory.Create();
        var repository = Directory.CreateDirectory(Path.Combine(fixture.Path, "repo"));
        var scope = new AuthorizedRepositoryScope(repository.FullName);
        await using var collector = new ScopedFileSystemActivityCollector(
            scope,
            new ScopedFileSystemCollectorOptions(
                QueueCapacity: 16,
                IncludeSubdirectories: true,
                DebounceWindow: TimeSpan.FromSeconds(5),
                ExcludedDirectoryNames: new HashSet<string>(StringComparer.OrdinalIgnoreCase)));
        collector.Start();
        for (var index = 0; index < 100; index++)
        {
            await File.WriteAllTextAsync(
                Path.Combine(repository.FullName, $"burst-{index:D3}.txt"),
                index.ToString(System.Globalization.CultureInfo.InvariantCulture));
        }

        await Task.Delay(500);

        Assert.IsGreaterThan(0, collector.TrackedDebounceEntryCount);
        Assert.IsLessThanOrEqualTo(
            collector.MaximumTrackedDebounceEntries,
            collector.TrackedDebounceEntryCount);
    }

    [TestMethod]
    public async Task GitReaderUsesReadOnlyBoundedCommandAndBlocksMaliciousStatusPath()
    {
        using var fixture = TemporaryDirectory.Create();
        var repository = Directory.CreateDirectory(Path.Combine(fixture.Path, "repo"));
        RunGit(repository.FullName, "init", "--quiet");
        var scope = new AuthorizedRepositoryScope(repository.FullName);
        var executor = new RecordingGitExecutor(
            "? src/service.cs\0? ../outside.txt\0");
        var reader = new GitRepositoryActivityReader(
            scope,
            new GitActivityReaderOptions(4096, 16, TimeSpan.FromSeconds(1)),
            executor);

        var observations = await reader.ReadStatusAsync();

        Assert.HasCount(2, observations);
        Assert.IsTrue(observations[0].IsAuthorized);
        Assert.AreEqual("src/service.cs", observations[0].RelativePath);
        Assert.IsFalse(observations[1].IsAuthorized);
        Assert.AreEqual("[blocked]", observations[1].RelativePath);
        Assert.AreEqual("outside-declared-root", observations[1].ScopeDecision);
        CollectionAssert.Contains(executor.Arguments.ToArray(), "--porcelain=v2");
        CollectionAssert.Contains(executor.Arguments.ToArray(), "-z");
        CollectionAssert.Contains(executor.Arguments.ToArray(), "--ignore-submodules=all");
        CollectionAssert.Contains(executor.Arguments.ToArray(), "core.fsmonitor=false");
        CollectionAssert.Contains(executor.Arguments.ToArray(), "core.excludesFile=NUL");
        CollectionAssert.Contains(executor.Arguments.ToArray(), "maintenance.auto=false");
        Assert.IsTrue(executor.Arguments.Any(item => item.StartsWith("--git-dir=", StringComparison.Ordinal)));
        Assert.IsTrue(executor.Arguments.Any(item => item.StartsWith("--work-tree=", StringComparison.Ordinal)));
        Assert.AreEqual(4096, executor.MaximumOutputUtf8Bytes);
        Assert.AreEqual(TimeSpan.FromSeconds(1), executor.Timeout);
    }

    [TestMethod]
    public async Task ActualGitStatusAndDiffAreReadOnlyBoundedAndSecretRedacted()
    {
        using var fixture = TemporaryDirectory.Create();
        var repository = Directory.CreateDirectory(Path.Combine(fixture.Path, "repo"));
        RunGit(repository.FullName, "init", "--quiet");
        RunGit(repository.FullName, "config", "user.name", "HerdrOps Test");
        RunGit(repository.FullName, "config", "user.email", "test@localhost");
        var trackedPath = Path.Combine(repository.FullName, "service.cs");
        await File.WriteAllTextAsync(trackedPath, "public class Service { }\n");
        RunGit(repository.FullName, "add", "service.cs");
        RunGit(repository.FullName, "commit", "--quiet", "-m", "fixture");
        const string secret = "github_pat_1234567890ABCDEFGHIJKLMNOPQRSTUVWXYZ";
        await File.AppendAllTextAsync(trackedPath, $"// API_KEY={secret}\n");

        var scope = new AuthorizedRepositoryScope(repository.FullName);
        var reader = new GitRepositoryActivityReader(scope);
        var status = await reader.ReadStatusAsync();
        var preview = await reader.ReadWorkingTreeDiffAsync(trackedPath);

        Assert.HasCount(1, status);
        var modified = status[0];
        Assert.AreEqual(FileActivityOperation.Modified, modified.Operation);
        Assert.AreEqual("service.cs", modified.RelativePath);
        Assert.AreEqual(ActivitySourceKind.Git, modified.SourceKind);
        Assert.AreEqual(ActivityConfidence.Observed, modified.Confidence);
        Assert.IsFalse(preview.RedactedText.Contains(secret, StringComparison.Ordinal));
        StringAssert.Contains(preview.RedactedText, "API_KEY=[REDACTED]");
        Assert.IsGreaterThan(0, preview.RedactionCount);
        Assert.HasCount(64, preview.OriginalSha256);
        Assert.HasCount(64, preview.RedactedSha256);
        Assert.AreNotEqual(preview.OriginalSha256, preview.RedactedSha256);
    }

    [TestMethod]
    public async Task GitReaderRejectsRepositoryConfigIncludeBeforeProcessExecution()
    {
        using var fixture = TemporaryDirectory.Create();
        var repository = Directory.CreateDirectory(Path.Combine(fixture.Path, "repo"));
        RunGit(repository.FullName, "init", "--quiet");
        var outsideConfig = Path.Combine(fixture.Path, "outside.gitconfig");
        await File.WriteAllTextAsync(outsideConfig, "[core]\n\tfsmonitor = false\n");
        await File.AppendAllTextAsync(
            Path.Combine(repository.FullName, ".git", "config"),
            $"\n[include]\n\tpath = {outsideConfig.Replace('\\', '/')}\n");
        var executor = new RecordingGitExecutor(string.Empty);
        var reader = new GitRepositoryActivityReader(
            new AuthorizedRepositoryScope(repository.FullName),
            executor: executor);

        await Assert.ThrowsExactlyAsync<UnauthorizedAccessException>(() => reader.ReadStatusAsync());

        Assert.IsEmpty(executor.Arguments);
    }

    [TestMethod]
    public async Task GitReaderRejectsGitDirectoryOutsideAuthorizedRootBeforeProcessExecution()
    {
        using var fixture = TemporaryDirectory.Create();
        var repository = Directory.CreateDirectory(Path.Combine(fixture.Path, "repo"));
        var outside = Directory.CreateDirectory(Path.Combine(fixture.Path, "outside-gitdir"));
        await File.WriteAllTextAsync(
            Path.Combine(repository.FullName, ".git"),
            $"gitdir: {outside.FullName.Replace('\\', '/')}\n");
        var executor = new RecordingGitExecutor(string.Empty);
        var reader = new GitRepositoryActivityReader(
            new AuthorizedRepositoryScope(repository.FullName),
            executor: executor);

        await Assert.ThrowsExactlyAsync<UnauthorizedAccessException>(() => reader.ReadStatusAsync());

        Assert.IsEmpty(executor.Arguments);
    }

    [TestMethod]
    public async Task GitReaderRejectsExternalCommonDirectoryBeforeProcessExecution()
    {
        using var fixture = TemporaryDirectory.Create();
        var repository = Directory.CreateDirectory(Path.Combine(fixture.Path, "repo"));
        var outside = Directory.CreateDirectory(Path.Combine(fixture.Path, "outside-common"));
        RunGit(repository.FullName, "init", "--quiet");
        await File.WriteAllTextAsync(
            Path.Combine(repository.FullName, ".git", "commondir"),
            outside.FullName.Replace('\\', '/') + "\n");
        var executor = new RecordingGitExecutor(string.Empty);
        var reader = new GitRepositoryActivityReader(
            new AuthorizedRepositoryScope(repository.FullName),
            executor: executor);

        await Assert.ThrowsExactlyAsync<UnauthorizedAccessException>(() => reader.ReadStatusAsync());

        Assert.IsEmpty(executor.Arguments);
    }

    [TestMethod]
    public void PorcelainV2ParserPreservesSpacesAndRenamePairing()
    {
        const string status =
            "1 .M N... 100644 100644 100644 abcdef0 abcdef0 src/file name.cs\0" +
            "2 R. N... 100644 100644 100644 abcdef0 abcdef1 R100 src/new name.cs\0src/old name.cs\0" +
            "? docs/new file.md\0";

        var entries = GitPorcelainV2Parser.Parse(status, maximumEntries: 8);

        Assert.HasCount(3, entries);
        Assert.AreEqual("src/file name.cs", entries[0].Path);
        Assert.AreEqual(FileActivityOperation.Renamed, entries[1].Operation);
        Assert.AreEqual("src/new name.cs", entries[1].Path);
        Assert.AreEqual("src/old name.cs", entries[1].OriginalPath);
        Assert.AreEqual(FileActivityOperation.Created, entries[2].Operation);
    }

    [TestMethod]
    public async Task TraceCommandCapturesActualWatcherAndGitWithoutMutatingRepository()
    {
        using var fixture = TemporaryDirectory.Create();
        var repository = Directory.CreateDirectory(Path.Combine(fixture.Path, "repo"));
        RunGit(repository.FullName, "init", "--quiet");
        RunGit(repository.FullName, "config", "user.name", "HerdrOps Test");
        RunGit(repository.FullName, "config", "user.email", "test@localhost");
        var trackedPath = Path.Combine(repository.FullName, "trace.txt");
        await File.WriteAllTextAsync(trackedPath, "before\n");
        RunGit(repository.FullName, "add", "trace.txt");
        RunGit(repository.FullName, "commit", "--quiet", "-m", "fixture");
        var reportPath = Path.Combine(fixture.Path, "trace-report.json");
        using var output = new StringWriter();
        using var error = new StringWriter();

        var traceTask = FileGitActivityTraceCommand.RunAsync(
            [
                "trace-file-git-activity",
                "--repo-root",
                repository.FullName,
                "--report",
                reportPath,
                "--seconds",
                "2",
            ],
            output,
            error);
        await Task.Delay(400);
        await File.AppendAllTextAsync(trackedPath, "after\n");
        var exitCode = await traceTask;

        Assert.AreEqual(0, exitCode, error.ToString());
        Assert.IsTrue(File.Exists(reportPath));
        using var document = JsonDocument.Parse(await File.ReadAllTextAsync(reportPath));
        var root = document.RootElement;
        Assert.IsTrue(root.GetProperty("runtimeObserved").GetBoolean());
        Assert.IsTrue(root.GetProperty("fileSystemWatcherObserved").GetBoolean());
        Assert.IsTrue(root.GetProperty("gitStatusObserved").GetBoolean());
        Assert.IsFalse(root.GetProperty("repositoryMutationInvoked").GetBoolean());
        Assert.IsFalse(root.GetProperty("herdrAgentCorrelationObserved").GetBoolean());
        Assert.HasCount(64, root.GetProperty("productAssemblySha256").GetString() ?? string.Empty);
        Assert.IsGreaterThan(0, root.GetProperty("fileSystemEvents").GetArrayLength());
        Assert.IsGreaterThan(0, root.GetProperty("finalGitStatus").GetArrayLength());
    }

    [TestMethod]
    public async Task ExistingReparsePointCannotEscapeAuthorizedRoot()
    {
        if (!OperatingSystem.IsWindows())
        {
            Assert.Inconclusive("The release target is Windows.");
        }

        using var fixture = TemporaryDirectory.Create();
        var repository = Directory.CreateDirectory(Path.Combine(fixture.Path, "repo"));
        var outside = Directory.CreateDirectory(Path.Combine(fixture.Path, "outside"));
        var linkPath = Path.Combine(repository.FullName, "escape");
        try
        {
            _ = Directory.CreateSymbolicLink(linkPath, outside.FullName);
        }
        catch (Exception exception) when (exception is UnauthorizedAccessException or IOException)
        {
            Assert.Inconclusive($"Symbolic-link creation is unavailable on this Windows host: {exception.GetType().Name}");
        }

        await File.WriteAllTextAsync(Path.Combine(outside.FullName, "secret.txt"), "outside");
        var scope = new AuthorizedRepositoryScope(repository.FullName);
        var decision = scope.Evaluate(Path.Combine(linkPath, "secret.txt"));

        Assert.IsFalse(decision.IsAuthorized);
        Assert.AreEqual("reparse-target-outside-root", decision.Reason);
        Assert.IsNull(decision.CanonicalPath);
    }

    private static async Task<FileActivityObservation> FirstMatchingAsync(
        IAsyncEnumerable<FileActivityObservation> source,
        Func<FileActivityObservation, bool> predicate,
        TimeSpan timeout)
    {
        using var cancellation = new CancellationTokenSource(timeout);
        await foreach (var item in source.WithCancellation(cancellation.Token))
        {
            if (predicate(item))
            {
                return item;
            }
        }

        throw new AssertFailedException("The expected file activity event was not observed.");
    }

    private static void RunGit(string repositoryRoot, params string[] arguments)
    {
        var startInfo = new ProcessStartInfo
        {
            FileName = "git",
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
        using var process = Process.Start(startInfo)
            ?? throw new AssertFailedException("Git could not be started for the integration fixture.");
        var standardOutput = process.StandardOutput.ReadToEnd();
        var standardError = process.StandardError.ReadToEnd();
        Assert.IsTrue(process.WaitForExit(10_000), "Git fixture command timed out.");
        Assert.AreEqual(
            0,
            process.ExitCode,
            $"Git fixture command failed. stdout={standardOutput} stderr={standardError}");
    }

    private sealed class RecordingGitExecutor(string output) : IBoundedGitCommandExecutor
    {
        public IReadOnlyList<string> Arguments { get; private set; } = [];

        public int MaximumOutputUtf8Bytes { get; private set; }

        public TimeSpan Timeout { get; private set; }

        public Task<BoundedGitCommandResult> ExecuteAsync(
            string repositoryRoot,
            IReadOnlyList<string> arguments,
            int maximumOutputUtf8Bytes,
            TimeSpan timeout,
            CancellationToken cancellationToken)
        {
            Arguments = arguments.ToArray();
            MaximumOutputUtf8Bytes = maximumOutputUtf8Bytes;
            Timeout = timeout;
            return Task.FromResult(new BoundedGitCommandResult(0, output, string.Empty));
        }
    }

    private sealed class TemporaryDirectory : IDisposable
    {
        private TemporaryDirectory(string path)
        {
            Path = path;
        }

        public string Path { get; }

        public static TemporaryDirectory Create()
        {
            var path = System.IO.Path.Combine(
                System.IO.Path.GetTempPath(),
                "HerdrOps-Issue15",
                Guid.NewGuid().ToString("N"));
            Directory.CreateDirectory(path);
            return new TemporaryDirectory(path);
        }

        public void Dispose()
        {
            if (Directory.Exists(Path))
            {
                var options = new EnumerationOptions
                {
                    RecurseSubdirectories = true,
                    AttributesToSkip = FileAttributes.ReparsePoint,
                    IgnoreInaccessible = false,
                };
                foreach (var file in Directory.EnumerateFiles(Path, "*", options))
                {
                    File.SetAttributes(file, FileAttributes.Normal);
                }

                Directory.Delete(Path, recursive: true);
            }
        }
    }
}
