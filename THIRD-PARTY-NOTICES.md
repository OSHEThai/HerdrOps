# Third-Party Notices

This inventory describes third-party material used to build and test HerdrOps at the versions pinned in the repository. It does not replace the license terms distributed by each upstream project.

## Runtime dependencies

| Package family | Pinned version | Package license metadata | Use |
|---|---:|---|---|
| Microsoft.Data.Sqlite | 10.0.11 | MIT | SQLite API and provider integration |
| SQLitePCLRaw | 2.1.12 | Apache-2.0 | SQLite native bundle and provider binding |

The exact package graph is locked in the project `packages.lock.json` files and is restored from NuGet; dependency source or package archives are not vendored in this repository.

## Development and test dependencies

MSTest, Microsoft.Testing.Platform, Microsoft.NET.Test.Sdk, Microsoft TestPlatform components, Microsoft.ApplicationInsights, Microsoft.DiaSymReader, Microsoft.Extensions.DependencyModel, and Newtonsoft.Json report MIT license expressions in their pinned NuGet metadata.

`Microsoft.Testing.Extensions.CodeCoverage` 18.1.0 ships its own Microsoft .NET Library license and third-party notices in the NuGet package. It is a test-only dependency and is not part of the HerdrOps application payload.

## CI and repository tooling

- GitHub workflows use `actions/checkout`, `actions/setup-dotnet`, and `actions/upload-artifact` at immutable commit references. These Actions run in CI and are not included in HerdrOps binaries.
- The open-source readiness workflow downloads Gitleaks 8.30.1 from its official release, verifies the pinned SHA-256 before execution, and does not redistribute the scanner in the repository or product.
- The Code of Conduct is an original project policy informed by Contributor Covenant 2.1 and links to its upstream attribution.

## Herdr protocol material

HerdrOps does not track or redistribute the Herdr executable or an extracted Herdr JSON Schema document. Contract tooling reads bounded schema bytes from an exact installed Herdr binary on the user's machine and writes generated output only under ignored `artifacts/` paths. Names and protocol identifiers are used to describe interoperability and do not imply that Herdr is distributed under the HerdrOps license.

## Project artwork and trademarks

The approved files under `docs/design/reference/` and the in-memory application crops derived from them are HerdrOps project artwork, not third-party package dependencies. Copyright permission for repository content is governed by `LICENSE`; trademark and endorsement rules are governed separately by [TRADEMARKS.md](TRADEMARKS.md).
