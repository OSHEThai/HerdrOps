using System.Security.Cryptography;
using System.Text;

namespace HerdrOps.Contracts.SelfReport;

public static class HerdrOpsSelfReportPipeName
{
    public static string FromUserScope(string userScopeIdentifier)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(userScopeIdentifier);
        var hash = Convert.ToHexString(SHA256.HashData(
            Encoding.UTF8.GetBytes($"HerdrOps.SelfReport.v1|{userScopeIdentifier}")));
        return $"herdrops-self-report-v1-{hash[..24].ToLowerInvariant()}";
    }
}
