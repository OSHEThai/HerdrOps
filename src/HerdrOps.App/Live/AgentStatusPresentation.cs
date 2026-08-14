using HerdrOps.Contracts.StateIpc;

namespace HerdrOps.App.Live;

public static class AgentStatusPresentation
{
    public const string Offline = "Offline";

    public static string EffectiveStatus(string status, bool isLive) =>
        isLive ? status : Offline;

    public static string BrushKey(string status) => status switch
    {
        "Working" => "HerdrOps.Brush.Status.Working",
        "Idle" => "HerdrOps.Brush.Status.Idle",
        "Blocked" => "HerdrOps.Brush.Status.Blocked",
        "Done" => "HerdrOps.Brush.Status.Done",
        _ => "HerdrOps.Brush.Status.Offline",
    };

    public static string DisplayName(HerdrAgentStateContract agent)
    {
        ArgumentNullException.ThrowIfNull(agent);
        return FirstNonEmpty(
            agent.Name,
            agent.Title,
            agent.DisplayAgent,
            agent.Agent,
            agent.TerminalId);
    }

    public static string RuntimeName(HerdrAgentStateContract agent)
    {
        ArgumentNullException.ThrowIfNull(agent);
        return FirstNonEmpty(agent.DisplayAgent, agent.Agent, "Unknown runtime");
    }

    public static string Initials(HerdrAgentStateContract agent)
    {
        var source = DisplayName(agent);
        var words = source.Split(
            [' ', '-', '_'],
            StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries);
        if (words.Length >= 2)
        {
            return string.Concat(words[0][0], words[1][0]).ToUpperInvariant();
        }

        return source.Length switch
        {
            0 => "?",
            1 => source.ToUpperInvariant(),
            _ => source[..2].ToUpperInvariant(),
        };
    }

    public static string OptionalBoolean(bool? value) => value switch
    {
        true => "Yes",
        false => "No",
        null => "Unknown",
    };

    public static string FirstNonEmpty(params string?[] values) =>
        values.FirstOrDefault(value => !string.IsNullOrWhiteSpace(value)) ?? "Unknown";
}
