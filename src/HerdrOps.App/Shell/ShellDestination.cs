namespace HerdrOps.App.Shell;

/// <summary>
/// Describes one canonical dashboard destination from the approved design contract.
/// </summary>
public sealed record ShellDestination(
    string Id,
    string EnglishName,
    string ThaiName,
    string IconGlyph,
    string Summary);
