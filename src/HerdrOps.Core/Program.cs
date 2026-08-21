using HerdrOps.Core;

if (args.Length > 0 && string.Equals(args[0], "activity-replay", StringComparison.Ordinal))
{
    return ActivityReplayCommand.Run(args, Console.Out, Console.Error);
}

if (args.Length > 0 &&
    string.Equals(args[0], "compliance-rule-corpus", StringComparison.Ordinal))
{
    return ComplianceRuleCorpusCommand.Run(args, Console.Out, Console.Error);
}

if (args.Length > 0 &&
    string.Equals(args[0], ComplianceDiagnosticExportCommand.CommandName, StringComparison.Ordinal))
{
    return ComplianceDiagnosticExportCommand.Run(args, Console.Out, Console.Error);
}

if (args.Length > 0 &&
    string.Equals(args[0], ComplianceDiagnosticExportCommand.ServiceCommandName, StringComparison.Ordinal))
{
    using var shutdown = new CancellationTokenSource();
    ConsoleCancelEventHandler cancelHandler = (_, eventArgs) =>
    {
        eventArgs.Cancel = true;
        shutdown.Cancel();
    };
    Console.CancelKeyPress += cancelHandler;
    try
    {
        return await ComplianceDiagnosticExportCommand.RunServiceAsync(
            args,
            Console.Out,
            Console.Error,
            shutdown.Token);
    }
    finally
    {
        Console.CancelKeyPress -= cancelHandler;
    }
}

if (args.Length > 0 &&
    string.Equals(args[0], "assignment-lifecycle-replay", StringComparison.Ordinal))
{
    return AssignmentLifecycleReplayCommand.Run(args, Console.Out, Console.Error);
}

if (args.Length > 0 &&
    string.Equals(args[0], "assignment-lifecycle-acceptance", StringComparison.Ordinal))
{
    return AssignmentLifecycleRuntimeAcceptanceCommand.Run(
        args,
        Console.Out,
        Console.Error);
}

if (args.Length > 0 &&
    (string.Equals(args[0], "trace-compliance-review", StringComparison.Ordinal) ||
     string.Equals(args[0], "compliance-review-trace", StringComparison.Ordinal)))
{
    return ComplianceReviewRuntimeTraceCommand.Run(args, Console.Out, Console.Error);
}

if (args.Length > 0 &&
     string.Equals(args[0], "compliance-review-acceptance", StringComparison.Ordinal))
{
    return ComplianceReviewRuntimeAcceptanceCommand.Run(
        args,
        Console.Out,
        Console.Error);
}

if (args.Length > 0 && string.Equals(args[0], "trace-herdr-terminal-process", StringComparison.Ordinal))
{
    return await HerdrTerminalProcessTraceCommand.RunAsync(args, Console.Out, Console.Error);
}

if (args.Length > 0 && string.Equals(args[0], "trace-file-git-activity", StringComparison.Ordinal))
{
    return await FileGitActivityTraceCommand.RunAsync(args, Console.Out, Console.Error);
}

if (args.Length > 0 && string.Equals(args[0], "trace-herdr-file-git-activity", StringComparison.Ordinal))
{
    return await HerdrFileGitActivityRuntimeTraceCommand.RunAsync(args, Console.Out, Console.Error);
}

if (args.Length > 0 && string.Equals(args[0], "trace-herdr-notification-runtime", StringComparison.Ordinal))
{
    return await HerdrNotificationRuntimeTraceCommand.RunAsync(args, Console.Out, Console.Error);
}

if (args.Length > 0 && string.Equals(args[0], "trace-herdr-runtime", StringComparison.Ordinal))
{
    return await HerdrRuntimeTraceCommand.RunAsync(args, Console.Out, Console.Error);
}

if (args.Length > 0 && string.Equals(args[0], "serve-herdr-state", StringComparison.Ordinal))
{
    using var shutdown = new CancellationTokenSource();
    ConsoleCancelEventHandler cancelHandler = (_, eventArgs) =>
    {
        eventArgs.Cancel = true;
        shutdown.Cancel();
    };
    Console.CancelKeyPress += cancelHandler;
    try
    {
        return await HerdrOpsCoreStateServiceCommand.RunAsync(
            args,
            Console.Out,
            Console.Error,
            shutdown.Token);
    }
    finally
    {
        Console.CancelKeyPress -= cancelHandler;
    }
}

if (args.Length > 0 && string.Equals(args[0], "restore-state-store", StringComparison.Ordinal))
{
    return StateStoreRestoreCommand.Run(args, Console.Out, Console.Error);
}

if (args.Length > 0 && string.Equals(args[0], "serve-self-reports", StringComparison.Ordinal))
{
    using var shutdown = new CancellationTokenSource();
    ConsoleCancelEventHandler cancelHandler = (_, eventArgs) =>
    {
        eventArgs.Cancel = true;
        shutdown.Cancel();
    };
    Console.CancelKeyPress += cancelHandler;
    try
    {
        return await HerdrOpsSelfReportServiceCommand.RunAsync(
            args,
            Console.Out,
            Console.Error,
            shutdown.Token);
    }
    finally
    {
        Console.CancelKeyPress -= cancelHandler;
    }
}

return HerdrProtocolInspectionCommand.Run(args, Console.Out, Console.Error);
