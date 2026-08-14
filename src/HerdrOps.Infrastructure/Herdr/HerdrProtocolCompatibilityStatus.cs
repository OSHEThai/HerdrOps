namespace HerdrOps.Infrastructure.Herdr;

public enum HerdrProtocolCompatibilityStatus
{
    Compatible,
    ExecutableNotFound,
    ExecutableUnreadable,
    InvalidPortableExecutable,
    UnsupportedRelease,
    UnsupportedBinaryHash,
    MissingProtocolMarkers,
}
