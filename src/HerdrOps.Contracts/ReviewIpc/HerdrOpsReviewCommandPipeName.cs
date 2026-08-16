using System.Security.Cryptography;
using System.Text;

namespace HerdrOps.Contracts.ReviewIpc;

public static class HerdrOpsReviewCommandPipeName
{
    public static string FromUserScope(string userScopeIdentifier)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(userScopeIdentifier);
        var hash = Convert.ToHexString(SHA256.HashData(
            Encoding.UTF8.GetBytes(
                $"HerdrOps.ReviewCommandIpc.v1|{userScopeIdentifier}")));
        return $"herdrops-review-v1-{hash[..24].ToLowerInvariant()}";
    }
}
