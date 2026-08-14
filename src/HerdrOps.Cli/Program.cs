using HerdrOps.Cli;

return await HerdrOpsCliCommand.RunAsync(
    args,
    Console.In,
    Console.Out,
    Console.Error,
    CancellationToken.None);
