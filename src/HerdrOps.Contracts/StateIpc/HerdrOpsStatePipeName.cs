using System.Security.Cryptography;
using System.Text;

namespace HerdrOps.Contracts.StateIpc;

public static class HerdrOpsStatePipeName
{
    public static string FromUserScope(string userScopeIdentifier)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(userScopeIdentifier);
        var hash = Convert.ToHexString(SHA256.HashData(
            Encoding.UTF8.GetBytes($"HerdrOps.StateIpc.v1|{userScopeIdentifier}")));
        return $"herdrops-state-v1-{hash[..24].ToLowerInvariant()}";
    }
}
