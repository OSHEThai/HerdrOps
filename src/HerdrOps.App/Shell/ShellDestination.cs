using HerdrOps.App.Localization;

namespace HerdrOps.App.Shell;

/// <summary>
/// Describes one canonical dashboard destination from the approved design contract.
/// </summary>
public sealed record ShellDestination(
    string Id,
    string EnglishName,
    string ThaiName,
    string IconGlyph,
    string EnglishSummary,
    string ThaiSummary)
{
    public string DisplayName => UiLanguageService.Shared.IsThai ? ThaiName : EnglishName;

    public string Summary => UiLanguageService.Shared.IsThai ? ThaiSummary : EnglishSummary;
}
