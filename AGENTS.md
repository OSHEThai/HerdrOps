# HerdrOps Working Rules

## Current authority

- `Plan/` is the current product and release-planning truth.
- `docs/design/reference/*.png` is the immutable visual reference set approved by the user.
- v0.1.0 is approved and released; v0.2.0 implementation is active. Do not claim integration, runtime, beta, or release completion without matching version-local evidence.

## Design constraints

- Preserve the blue circular HerdrOps mark and the `HerdrOps` wordmark shown in the reference images.
- Preserve the shared shell: top project/status bar, left navigation, content workspace, and bottom connection/status bar.
- Preserve the meaning and hierarchy of reference labels, but render exactly one selected UI language at a time. Thai mode must not stack English translations, and English mode must not stack Thai translations; literal product names, Agent names, identifiers, paths, and protocol values remain unchanged.
- Do not edit reference PNG files in place. Put experiments under a separate working directory.

## Evidence boundaries

- Static: source, parse, lint, schema, or visual-token checks.
- Synthetic: mock data, replay, fixture, or simulated Herdr behavior.
- Contract: named-pipe/schema compatibility checks.
- Runtime: observed behavior against an actual installed Herdr instance.
- Release: packaged artifact, clean-machine install, runtime acceptance, and required human approval.

Report these classes separately. Preparation for a later version does not complete or credit an earlier version.

## GitHub tracking

- Every implementation or release change must map to an issue in the matching GitHub milestone.
- Reference the issue number in commits and pull requests.
- Close issues only after their acceptance criteria and required evidence are satisfied.
- A version is not release-ready until its release tracker and milestone pass `tools/Test-VersionMilestone.ps1`.

## Repository safety

- The authorized project root is `Z:\HerdrOps`.
- Keep all product source, plans, tests, tools, and design references inside this root.
- Do not add a remote, publish a package, or create a release unless explicitly requested.
