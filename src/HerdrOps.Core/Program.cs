using HerdrOps.Core;

if (args.Length > 0 && string.Equals(args[0], "trace-herdr-runtime", StringComparison.Ordinal))
{
    return await HerdrRuntimeTraceCommand.RunAsync(args, Console.Out, Console.Error);
}

return HerdrProtocolInspectionCommand.Run(args, Console.Out, Console.Error);
