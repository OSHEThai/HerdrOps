namespace HerdrOps.Infrastructure.Herdr;

public enum HerdrBundledSchemaStatus
{
    Compatible,
    ExecutableRejected,
    SchemaStartNotFound,
    DuplicateSchemaStart,
    SchemaTruncated,
    SchemaTooLarge,
    InvalidUtf8,
    MalformedJson,
    UnsupportedDraft,
    UnsupportedProtocol,
    UnsupportedSchemaVersion,
    MissingSchemaGroup,
    MissingSchemaDefinition,
    UnexpectedDefinitionCount,
    MissingRequestMethod,
    MissingResponseType,
    MissingSubscriptionEventKind,
    UnexpectedSchemaLength,
    UnexpectedSchemaHash,
}
