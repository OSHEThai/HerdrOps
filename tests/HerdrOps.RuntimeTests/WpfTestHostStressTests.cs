using System.Collections.Concurrent;
using System.Threading;
using System.Threading.Tasks;
using System.Windows.Threading;

namespace HerdrOps.RuntimeTests;

[TestClass]
[DoNotParallelize]
public sealed class WpfTestHostStressTests
{
    [TestMethod]
    public void ConcurrentCallersShareOneOwnedDispatcherAndComplete()
    {
        const int callerCount = 24;
        using var gate = new Barrier(callerCount);
        var dispatcherThreadIds = new ConcurrentBag<int>();
        var tasks = Enumerable.Range(0, callerCount)
            .Select(_ => Task.Run(() =>
            {
                gate.SignalAndWait(TimeSpan.FromSeconds(30));
                WpfTestHost.Run(() =>
                {
                    dispatcherThreadIds.Add(Environment.CurrentManagedThreadId);
                    Assert.IsTrue(Dispatcher.CurrentDispatcher.CheckAccess());
                }, TimeSpan.FromSeconds(30));
            }))
            .ToArray();

        Assert.IsTrue(Task.WaitAll(tasks, TimeSpan.FromSeconds(90)));
        foreach (var task in tasks)
        {
            task.GetAwaiter().GetResult();
        }

        Assert.AreEqual(1, dispatcherThreadIds.Distinct().Count());
        var diagnostics = WpfTestHost.GetDiagnosticsForTest();
        StringAssert.Contains(diagnostics, "State: Running");
        StringAssert.Contains(diagnostics, "LastMilestone: DispatcherReady");
        StringAssert.Contains(diagnostics, "ApplicationOwned: True");
        StringAssert.Contains(diagnostics, "DispatcherAvailable: True");
    }

    [TestMethod]
    public void RepeatedRunsRemainResponsiveAfterConcurrentLoad()
    {
        var observedThreadIds = new HashSet<int>();
        for (var index = 0; index < 100; index++)
        {
            WpfTestHost.Run(() =>
            {
                observedThreadIds.Add(Environment.CurrentManagedThreadId);
                Assert.IsTrue(Dispatcher.CurrentDispatcher.CheckAccess());
            });
        }

        Assert.HasCount(1, observedThreadIds);
    }

    [TestMethod]
    public void UiExceptionPropagatesWithoutPoisoningOwnedHost()
    {
        var exception = Assert.ThrowsExactly<InvalidOperationException>(() =>
            WpfTestHost.Run(() => throw new InvalidOperationException("synthetic UI failure")));

        Assert.AreEqual("synthetic UI failure", exception.Message);
        WpfTestHost.Run(() => Assert.IsTrue(Dispatcher.CurrentDispatcher.CheckAccess()));
        StringAssert.Contains(WpfTestHost.GetDiagnosticsForTest(), "State: Running");
    }

    [TestMethod]
    public void InjectedDispatcherFaultIsReportedAndHostSurvives()
    {
        var original = new InvalidOperationException("synthetic dispatcher callback failure");
        var observed = WpfTestHost.PostDispatcherFaultForTest(original);

        Assert.IsTrue(
            observed.Wait(TimeSpan.FromSeconds(30)),
            "The dispatcher unhandled-exception callback was not observed.");
        Assert.AreSame(original, observed.GetAwaiter().GetResult());

        var reported = Assert.ThrowsExactly<InvalidOperationException>(() =>
            WpfTestHost.Run(() => Assert.Fail("the poisoned operation must not run")));

        Assert.AreSame(original, reported.InnerException);
        StringAssert.Contains(reported.Message, "unobserved callback exception");

        WpfTestHost.Run(() => Assert.IsTrue(Dispatcher.CurrentDispatcher.CheckAccess()));
        StringAssert.Contains(WpfTestHost.GetDiagnosticsForTest(), "State: Running");
    }
}
