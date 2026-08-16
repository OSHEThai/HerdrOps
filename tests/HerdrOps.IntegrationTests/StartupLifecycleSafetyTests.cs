using HerdrOps.App.Lifecycle;
using HerdrOps.Domain.Lifecycle;

namespace HerdrOps.IntegrationTests;

[TestClass]
public sealed class StartupLifecycleSafetyTests
{
    [TestMethod]
    public void InjectedPerUserGateRejectsSecondLaunchAndReleasesDeterministically()
    {
        var registry = new Dictionary<string, object>(StringComparer.Ordinal);
        using var first = new InMemoryInstanceGate(registry, "HerdrOps");
        using var second = new InMemoryInstanceGate(registry, "HerdrOps");

        Assert.IsTrue(first.TryAcquire());
        Assert.IsFalse(second.TryAcquire());

        first.Dispose();

        Assert.IsTrue(second.TryAcquire());
        second.Dispose();
        Assert.IsFalse(registry.ContainsKey("HerdrOps"));
    }

    [TestMethod]
    public void StartupTransactionRollsBackEveryFaultStageInReverseOrder()
    {
        var stages = new[] { "compose", "load", "status", "widget", "tray", "expose" };
        foreach (var faultStage in stages)
        {
            var acquired = new List<string>();
            var cleaned = new List<string>();
            var transaction = new StartupTransaction();

            foreach (var stage in stages[..^1])
            {
                if (string.Equals(stage, faultStage, StringComparison.Ordinal))
                {
                    break;
                }

                acquired.Add(stage);
                transaction.AddCleanup(stage, () => cleaned.Add(stage));
            }

            try
            {
                if (faultStage == "expose")
                {
                    transaction.Commit(() => throw new InvalidOperationException("Synthetic expose fault."));
                }
                else
                {
                    throw new InvalidOperationException($"Synthetic {faultStage} fault.");
                }
            }
            catch (Exception primary)
            {
                try
                {
                    transaction.Rollback(primary);
                }
                catch (Exception rollbackFailure) when (ReferenceEquals(rollbackFailure, primary))
                {
                }
            }

            CollectionAssert.AreEqual(acquired.AsEnumerable().Reverse().ToArray(), cleaned);
            Assert.IsFalse(transaction.HasPendingCleanup, faultStage);
        }
    }

    [TestMethod]
    public void StartupTransactionPreservesPrimaryBeforeCleanupFailure()
    {
        var primary = new InvalidOperationException("Synthetic primary startup fault.");
        var cleanup = new IOException("Synthetic rollback fault.");
        var transaction = new StartupTransaction();
        transaction.AddCleanup("first", () => throw cleanup);

        var failure = Assert.ThrowsExactly<StartupTransactionException>(() =>
            transaction.Rollback(primary));

        Assert.AreSame(primary, failure.PrimaryException);
        Assert.AreSame(cleanup, failure.CleanupException.Failures.Single().Exception);
        var aggregate = Assert.IsInstanceOfType<AggregateException>(failure.InnerException);
        Assert.AreSame(primary, aggregate.InnerExceptions[0]);
        Assert.AreSame(failure.CleanupException, aggregate.InnerExceptions[1]);
        Assert.IsTrue(transaction.HasPendingCleanup);
    }

    [TestMethod]
    public void StartupTransactionRetriesFailedCleanupWithoutLosingStageOrder()
    {
        var attempts = new List<string>();
        var failFirstAttempt = true;
        var transaction = new StartupTransaction();
        transaction.AddCleanup("first", () =>
        {
            attempts.Add("first");
            if (failFirstAttempt)
            {
                failFirstAttempt = false;
                throw new IOException("Synthetic retryable cleanup fault.");
            }
        });
        transaction.AddCleanup("second", () => attempts.Add("second"));

        Assert.ThrowsExactly<ShutdownCleanupException>(() => transaction.RetryCleanup());
        Assert.IsTrue(transaction.HasPendingCleanup);

        transaction.RetryCleanup();

        CollectionAssert.AreEqual(new[] { "second", "first", "second", "first" }, attempts);
        Assert.IsFalse(transaction.HasPendingCleanup);
    }

    private sealed class InMemoryInstanceGate(
        IDictionary<string, object> registry,
        string name) : IApplicationInstanceGate
    {
        private bool _acquired;
        private bool _disposed;

        public bool TryAcquire()
        {
            ObjectDisposedException.ThrowIf(_disposed, this);
            if (_acquired)
            {
                return true;
            }

            if (registry.ContainsKey(name))
            {
                return false;
            }

            registry[name] = this;
            _acquired = true;
            return true;
        }

        public void Dispose()
        {
            if (_disposed)
            {
                return;
            }

            _disposed = true;
            if (_acquired)
            {
                registry.Remove(name);
                _acquired = false;
            }
        }
    }
}
