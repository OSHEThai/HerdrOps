# Contributing to HerdrOps

Thank you for helping improve HerdrOps. The project welcomes focused bug reports, documentation corrections, tests, and implementation contributions that preserve the approved product and evidence boundaries.

## Before starting

1. Search existing issues and open a versioned work item before making a substantial change.
2. Agree on scope with a maintainer. Maintainers map accepted implementation and release work to the matching milestone.
3. Do not include credentials, personal data, terminal output, local databases, diagnostic bundles, or machine-specific runtime evidence in issues or pull requests.
4. For vulnerabilities, follow [SECURITY.md](SECURITY.md) instead of opening a public issue.

## Development environment

HerdrOps targets Windows and requires .NET SDK 10.0.400 or a compatible 10.0.4xx patch. Clone your fork and create a topic branch from the default branch.

Run the full build and automated checks from PowerShell:

```powershell
./tools/Invoke-Build.ps1 -Configuration Release -VerifyFormat
```

Run any version-local gate named in the issue. A green general build does not replace required runtime, review, packaging, or release evidence.

## Pull requests

- Reference the issue number in the pull-request description and commit messages.
- Keep changes scoped to the issue and describe the evidence produced.
- Report Static, Synthetic, Contract, Runtime, independent-review, and Release evidence separately.
- Never claim actual Herdr runtime, Beta, packaging, or release completion without the matching version-local evidence.
- Preserve `docs/design/reference/*.png`; do not edit approved reference images in place.
- Preserve the blue HerdrOps mark, the `HerdrOps` wordmark, and the shared shell hierarchy.
- Render exactly one selected UI language at a time while preserving literal product names, agent names, identifiers, paths, and protocol values.
- Add or update tests for behavior changes and keep generated output under ignored `artifacts/` paths.

Pull requests from forks run with read-only repository permissions and without repository secrets. Maintainers may request changes before running any privileged or actual-runtime acceptance process.

## Licensing

By submitting a contribution, you agree that your contribution may be distributed under the repository's `LICENSE` file. Do not submit code or assets that you do not have the right to contribute, and record the source and license of any third-party material.

Participation in the project is governed by [CODE_OF_CONDUCT.md](CODE_OF_CONDUCT.md).
