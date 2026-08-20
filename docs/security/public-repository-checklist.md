# Public Repository Readiness Checklist

Issue: [#103](https://github.com/OSHEThai/HerdrOps/issues/103)

This checklist controls the one-time transition of `OSHEThai/HerdrOps` from Private to Public. Passing it is repository-governance evidence only; it does not complete product runtime, Beta, packaging, or release acceptance.

## Before changing visibility

- [ ] The committed source and complete Git history pass the redacted secret scan.
- [ ] Every scanner candidate is either remediated or represented by one exact reviewed fingerprint in `.gitleaksignore`.
- [ ] Apache-2.0 `LICENSE`, `NOTICE`, `SECURITY.md`, `CONTRIBUTING.md`, `CODE_OF_CONDUCT.md`, `THIRD-PARTY-NOTICES.md`, and `TRADEMARKS.md` pass the readiness gate.
- [ ] `NOTICE` covers source, documentation, approved design references, and project artwork while reserving trademark and endorsement rights.
- [ ] Pull-request workflows use `contents: read`, do not use repository secrets, and pin third-party Actions to immutable commit SHAs.
- [ ] Uploaded paths are limited to synthetic test results, design evidence, performance evidence, release-gate reports, and governance reports. Actual runtime evidence, local databases, logs, terminal output, and diagnostic bundles are not uploaded by public pull-request workflows.
- [ ] The accepted commit passes CI and the open-source readiness workflow.

## Visibility change

- [ ] Confirm the organization owner intends source, Git history, Actions history/logs, and future forks to be public.
- [ ] Change `OSHEThai/HerdrOps` visibility to Public.
- [ ] Confirm the GitHub API reports `PUBLIC` and the expected default branch remains `main`.

## Public security settings

- [ ] Enable private vulnerability reporting and verify that **Security → Report a vulnerability** is available.
- [ ] Enable the dependency graph and Dependabot alerts.
- [ ] Enable secret scanning and push protection when available to the organization.
- [ ] Require pull requests and passing status checks on `main`; do not allow force pushes or branch deletion.
- [ ] Keep Actions workflow permissions read-only by default and do not allow Actions to create or approve pull requests unless a future reviewed issue requires it.
- [ ] Review fork pull-request approval policy and require maintainer approval before any workflow that could access privileged resources.

## Artifact policy

Public workflows may upload only ignored, generated paths under:

- `artifacts/test-results/`
- `artifacts/design-evidence/`
- `artifacts/performance-evidence/`
- `artifacts/release-gates/`
- `artifacts/governance/`

They must not upload `artifacts/runtime-evidence/`, local `data/` or `logs/`, database files, terminal output, diagnostic bundles, user-profile paths, environment dumps, or credentials. Public workflow artifacts use a seven-day retention period unless a later issue approves a different bounded policy.
