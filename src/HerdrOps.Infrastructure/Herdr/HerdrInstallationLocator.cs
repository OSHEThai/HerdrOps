namespace HerdrOps.Infrastructure.Herdr;

public static class HerdrInstallationLocator
{
    public static string? FindExecutable(string? explicitPath = null)
    {
        if (!string.IsNullOrWhiteSpace(explicitPath))
        {
            return Path.GetFullPath(explicitPath);
        }

        var localApplicationData = Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData);
        if (!string.IsNullOrWhiteSpace(localApplicationData))
        {
            var installedCandidate = Path.Combine(
                localApplicationData,
                "Programs",
                "Herdr",
                "bin",
                "herdr.exe");
            if (File.Exists(installedCandidate))
            {
                return installedCandidate;
            }
        }

        var pathValue = Environment.GetEnvironmentVariable("PATH");
        if (string.IsNullOrWhiteSpace(pathValue))
        {
            return null;
        }

        foreach (var pathEntry in pathValue.Split(Path.PathSeparator, StringSplitOptions.RemoveEmptyEntries))
        {
            string candidate;
            try
            {
                candidate = Path.Combine(pathEntry.Trim(), "herdr.exe");
            }
            catch (ArgumentException)
            {
                continue;
            }

            if (File.Exists(candidate))
            {
                return Path.GetFullPath(candidate);
            }
        }

        return null;
    }
}
