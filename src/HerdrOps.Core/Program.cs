using HerdrOps.Core;

if (args.Length > 0 && string.Equals(args[0], "activity-replay", StringComparison.Ordinal))
{
    return ActivityReplayCommand.Run(args, Console.Out, Console.Error);
}

if (args.Length > 0 && string.Equals(args[0], "trace-herdr-terminal-process", StringComparison.Ordinal))
{
    return await HerdrTerminalProcessTraceCommand.RunAsync(args, Console.Out, Console.Error);
}

if (args.Length > 0 && string.Equals(args[0], "trace-file-git-activity", StringComparison.Ordinal))
{
    return await FileGitActivityTraceCommand.RunAsync(args, Console.Out, Console.Error);
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

return HerdrProtocolInspectionCommand.Run(args, Console.Out, Console.Error);
