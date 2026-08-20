# Security Policy

## Supported versions

HerdrOps is under active development. Security fixes are made on the default branch and may be included in a later tagged release after the matching version-local evidence passes. The released v0.1.0 visual shell and the active v0.2.0 implementation must not be treated as a supported production security boundary.

## Reporting a vulnerability

Do not open a public issue for a suspected vulnerability and do not attach secrets, personal data, terminal output, diagnostic bundles, or machine-specific evidence to a public discussion.

Use the repository's **Security** tab and select **Report a vulnerability** to open a private security advisory. Include:

- the affected commit or version;
- the component and expected security boundary;
- reproducible steps or a minimal proof of concept;
- the impact and any known mitigations; and
- whether the report includes real Herdr runtime evidence or only synthetic/contract evidence.

Maintainers will aim to acknowledge a complete report within seven calendar days. Disclosure timing will be coordinated with the reporter after the issue is reproduced and a remediation plan exists.

## Security scope

Reports about local data protection, Named Pipe authorization, diagnostic redaction, command or path handling, dependency integrity, packaging, update behavior, and GitHub Actions supply-chain safety are in scope. General feature requests and non-security defects belong in the versioned issue template.

Never use production credentials or data when demonstrating a vulnerability. A passing static, synthetic, or contract test is not evidence that installed Herdr runtime behavior is secure.
