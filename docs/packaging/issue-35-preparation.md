# Issue #35 design-parity review tooling preparation

Status: non-runtime preparation only. This document maps to v0.7.0 / issue
[#35](https://github.com/OSHEThai/HerdrOps/issues/35) and does not close the
issue, approve a capture, satisfy the v0.7 release gate, or record a human
design acceptance.

## Scope of this slice

This slice prepares the fail-closed manifest and verification tooling that a
later, separate review slice will use to bind an accepted capture set back to
the immutable reference surface. It is preparation for that later review; it is
not the review itself, and it does not claim that any capture has been
human-accepted.

The reference authority is `Plan/DESIGN-CONTRACT.md` and
`docs/design/reference/MANIFEST.md`. The eleven reference PNGs in
`docs/design/reference/` remain immutable and are not edited.

## Chosen approach

The preparation lives entirely under `tools/human-design-review/` as six
committed files:

| File | Role |
|---|---|
| `human-design-review.schema.json` | Versioned fail-closed schema for an accepted review manifest |
| `human-design-review.template.json` | Fail-closed manifest skeleton that always fails a verifier run |
| `HumanDesignReview.Common.ps1` | Strict-JSON parser and fail-closed, deterministic verifier core |
| `Test-V0.7HumanDesignReviewVerifier.ps1` | Manifest verifier entry point |
| `Test-V0.7HumanDesignReviewSelftests.ps1` | Deterministic positive and hostile-negative selftest |
| `Invoke-V0.7HumanDesignReviewEvidence.ps1` | Deterministic PREPARATION evidence report driver |

The schema root requires `schemaVersion` (const 1) plus the fail-closed fields,
and binds every capture to a SHA-256 and mandatory evidence link with a stated
manual evidence slot. The template is a fail-closed skeleton; a verifier run
against it must fail rather than pass, so an unbound template can never be
mistaken for an accepted manifest.

`HumanDesignReview.Common.ps1` scans every JSON file from raw text before
`ConvertFrom-Json` and rejects duplicate properties (including case variants)
at every depth with ordinal case-insensitive comparison. All SHA-256 checks use
byte bindings with an invariant-culture representation, and all timestamp
comparisons normalize date/time values to invariant ISO `Z` form before future
date checks, so a Thai Buddhist-calendar process culture cannot corrupt a date.

Accepted review manifests are generated evidence, not committed source; the
committed deliverables are the fail-closed tools, schema, and template only.

## Local commands

From the worktree root:

```powershell
# Deterministic selftests: run once under Windows PowerShell 5.1 and once under PowerShell 7
.\tools\human-design-review\Test-V0.7HumanDesignReviewSelftests.ps1

# Deterministic PREPARATION evidence report (writes JSON + echoes path)
.\tools\human-design-review\Invoke-V0.7HumanDesignReviewEvidence.ps1 `
    -ReportPath .\artifacts\design-evidence\v0.7.0\issue-35\preparation-report.json

# Manifest verifier entry point (fail-closed)
.\tools\human-design-review\Test-V0.7HumanDesignReviewVerifier.ps1 -ManifestPath <path>
```

Running the fail-closed verifier against the template returns a non-zero exit
under both shells with a clear missing/placeholder reason, proving the
fail-closed wiring. No execution of an installed Herdr instance, no named-pipe
activity, and no live reference-host capture is performed by this slice.

## Synthetic and deterministic behavior

The selftest builds a deterministic in-memory fixture that emulates the
eleven-reference surface (sixty-page and eight widget captures, hash-bound to
fixture bytes) and its SHA-256 values are checked against independently stored
expected digests. It is regression-stable:

- PositiveControlAccepted: a fully bound manifest with valid invariants is accepted.
- OnDiskBinding: the accepted manifest's exact bytes on disk re-verify.
- MissingCapture, DuplicateCapture and UnexpectedCapture FailClosed: rejected.
- ForgedCheckboxOnlySignoff and ForgedDivergence FailClosed: rejected.
- HashTamper FailClosed: a changed referenced byte with unchanged recorded hash is rejected.
- FutureDateFalsified FailClosed: a capture stamped in the future is rejected.
- DuplicateJson FailClosed: duplicate or case-variant JSON properties are rejected.

The selftest reports its host edition and version in each run. This slice
executed it once under Windows PowerShell 5.1 and once under PowerShell 7; both
runs report the same PASS/FAIL set and the same `Static/Contract/Synthetic`
evidence class with `Human`, `Runtime` and `Release` unobserved. Output is
bounded: the evidence report is one small JSON document whose schema and
template SHA-256 digests are identical across both shells.

## Evidence boundary

| Evidence class | Result of this slice |
|---|---|
| Static | PASS: schema and template parse strictly, SHA-256 digests are deterministic and identical across both shells |
| Contract | PASS: schema-verifier compatibility and fail-closed manifest invariants hold deterministically |
| Synthetic | PASS: positive control and on-disk binding PASS; all hostile-negative and future-date cases fail closed |
| Runtime | NOT OBSERVED: no installed Herdr instance is contacted, no named-pipe or live-capture work is performed |
| Human | NOT OBSERVED: no human design acceptance or independent review is recorded |
| Release | NOT OBSERVED: no signing, publication, clean-machine acceptance, or release approval is performed |

Remaining v0.7 blockers include a real human design-review decision against the
eleven references on the reference host, accepted capture regeneration and
review, actual installed-Herdr runtime observation, clean-machine acceptance,
and the v0.7 milestone/release gate. No GitHub API operation, package
publication, capture acceptance, or release action is part of this slice.