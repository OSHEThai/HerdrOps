namespace HerdrOps.App.Lifecycle;

public sealed record ShutdownCleanupAction
{
    public ShutdownCleanupAction(string name, Action execute)
    {
        if (string.IsNullOrWhiteSpace(name))
        {
            throw new ArgumentException("A cleanup action name is required.", nameof(name));
        }

        Name = name;
        Execute = execute ?? throw new ArgumentNullException(nameof(execute));
    }

    public string Name { get; }

    public Action Execute { get; }
}

public sealed record ShutdownCleanupFailure(string Name, Exception Exception);

public sealed class ShutdownCleanupException : Exception
{
    public ShutdownCleanupException(IReadOnlyList<ShutdownCleanupFailure> failures)
        : base(
            $"One or more shutdown cleanup actions failed: {string.Join(", ", failures.Select(failure => failure.Name))}.",
            new AggregateException(failures.Select(failure => failure.Exception)))
    {
        if (failures.Count == 0)
        {
            throw new ArgumentException("At least one cleanup failure is required.", nameof(failures));
        }

        Failures = failures.ToArray();
    }

    public IReadOnlyList<ShutdownCleanupFailure> Failures { get; }
}

/// <summary>
/// Runs every shutdown action even when an earlier action fails, then reports
/// all failures together. The action order is deterministic and is part of the
/// caller's cleanup contract.
/// </summary>
public static class ShutdownCleanup
{
    public static void Execute(IEnumerable<ShutdownCleanupAction> actions)
    {
        ArgumentNullException.ThrowIfNull(actions);
        var failures = new List<ShutdownCleanupFailure>();
        foreach (var action in actions)
        {
            ArgumentNullException.ThrowIfNull(action);
            try
            {
                action.Execute();
            }
            catch (Exception exception)
            {
                failures.Add(new ShutdownCleanupFailure(action.Name, exception));
            }
        }

        if (failures.Count > 0)
        {
            throw new ShutdownCleanupException(failures);
        }
    }
}
