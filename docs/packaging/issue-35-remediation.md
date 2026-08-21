# Issue #35 human design-review reconciliation

Status: non-runtime remediation only. This slice maps to v0.7.0 / issue
[#35](https://github.com/OSHEThai/HerdrOps/issues/35) and does not close the
issue, approve a capture, satisfy the v0.7 release gate, or record a human
design acceptance.

## Problem: the candidate manifest does not bind to the canonical verifier

Earlier design-parity work produced a candidate design-review manifest with
forty page captures and a reduced widget set. That candidate was captured under
an obsolete manifest model (F1-F5 semantics) and does not conform to the
fail-closed schema enforced by the canonical verifier that was merged for the
preparation slice via the six committed files under
`tools/human-design-review/`.

Running the canonical verifier against the candidate fails closed at the first
invariant:

```powershell
pwsh -NoProfile -File .\tools\human-design-review\Test-V0.7HumanDesignReviewVerifier.ps1 `
  -ManifestPath <candidate-manifest.json>          # -> non-zero exit
```

```text
Review manifest root must contain exactly the schema-declared properties.
```

The candidate declares root properties `Title, EvidenceClass, CandidateStatus,
HumanAcceptance, ActualHerdrRuntime, ReleaseEvidence, PageDestinations,
WidgetVariants, Captures`, while the canonical verifier requires exactly
`$id, schemaVersion, contract, reviewStatus, reviewer, provenance,
uiUnderReview, captures, pages, widgets, accessibleEvidence, declarations`.

### Capture-universe divergence

The canonical universe is fixed by the verifier core
(`HumanDesignReview.Common.ps1`): ten pages, two languages, three scale slices,
and eight widget variants. The candidate diverges on every axis:

| Axis | Canonical verifier universe | Candidate manifest | Divergence |
|---|---|---|---|
| Page capture count | 60 = 10 pages x 2 languages (th, en) x 3 scale slices (100, 125, 150) | 40 page captures named `-compact` / `-reference` | Candidate collapses the three approved scale slices into two density-ish variants and names them `-compact` / `-reference` instead of `-100` / `-125` / `-150` |
| Page capture key shape | `captures/<lang>/pages/<page>-<scale>.png` | `captures/<lang>/pages/<page>-<compact|reference>.png` | No candidate page capture resolves to a canonical scale key; the verifier reports every required page capture as missing |
| Widget variants | 8 = Compact, Normal, Expanded, FloatingMini, FloatingVertical, Notification, AgentDetailPopup, DashboardPreview | 7 = missing DashboardPreview | Candidate omits the Dashboard launch/preview state declared by `Plan/DESIGN-CONTRACT.md` |
| Widget capture kind | `widget-variant` (6) + `dashboard-preview` (DashboardPreview) | `widget-variant` only; `DashboardPreview` absent | Candidate has no `dashboard-preview` capture |

The candidate also carries `widget-gallery` captures (`gallery-compact.png`,
`gallery-reference.png` per language) that are not part of the canonical
universe; the verifier treats the page/widget capture set as exact and
fail-closed, so out-of-universe or non-canonical-named captures cause rejection
rather than being tolerated.

## Reconciliation approach

Reconciliation is a static/synthetic boundary-only slice. It does not invent
human review, does not record runtime observation, and does not publish
anything. It aligns the candidate's capture universe to the canonical verifier
so that a later, separate review slice can bind real captures to the immutable
reference surface.

The committed remediation deliverables are a deterministic reconciliation test
under `tools/human-design-review/` and this document. Generated manifests and
reports are generated evidence under `artifacts/` (git-ignored), consistent with
the preparation slice convention that accepted review manifests are generated
evidence rather than committed source.

### What the reconciliation test proves

`Test-V0.7Issue35Reconciliation.ps1`:

1. Loads the canonical universe (pages, languages, scales, widget variants) from
   the shared verifier core, so the test can never drift from the verifier.
2. Locates the candidate manifest if present and records the concrete
   divergence: candidate page-capture cardinality and variant set versus the
   canonical 60/8 expectation. When the candidate is absent (for example on a
   fresh checkout) the reconciliation still proves the canonical shape by
   building the pending manifest directly.
3. Builds a deterministic, schema-valid manifest — `reviewStatus: Pending` —
   that declares all 60 page captures and all 8 widget variants with synthetic
   bound SHA-256 hashes and fully bound evidence/accessibility slots. Pending is
   deliberate: the manifest is structurally valid and hash-bound, but it carries
   no claim of human acceptance (`humanReviewClaimed` stays `false`), so it can
   never be mistaken for an accepted review.
4. Runs the canonical verifier against the pending manifest both in
   configuration-only mode and with on-disk binding, and asserts it verifies
   cleanly with `Valid = $true`, `ReviewStatus = Pending`, and 60 page captures.

Because the pending manifest uses the exact canonical capture universe, the
positive control proves the verifier now accepts the 60/8 shape the candidate
failed to produce, while remaining fail-closed on any opposite change (a
verifier run against a candidate-style manifest still returns non-zero).

## Local commands

From the worktree root:

```powershell
# Canonical fail-closed selftest (positive and hostile-negative controls)
.\tools\human-design-review\Test-V0.7HumanDesignReviewSelftests.ps1

# Reconciliation: builds a canonical Pending manifest and verifies it
.\tools\human-design-review\Test-V0.7Issue35Reconciliation.ps1

# Hostile control: the obsolete candidate style still fails closed
pwsh -NoProfile -File .\tools\human-design-review\Test-V0.7HumanDesignReviewVerifier.ps1 `
  -ManifestPath <candidate-manifest.json>          # expect non-zero exit
```

The reconciliation test reports the canonical universe sizes, the observed
candidate divergence when available, and the verifier result for the pending
manifest.

## Evidence boundary

| Evidence class | Result of this slice |
|---|---|
| Static | PASS: the reconciliation test loads the canonical verifier universe and builds a schema-valid, hash-bound manifest conforming to `human-design-review.schema.json` |
| Contract | PASS: the canonical verifier accepts the 60/8 pending manifest and the obsolete candidate style still fails closed |
| Synthetic | PASS: the pending manifest uses deterministic fixture hashes; the test never contacts a live host |
| Runtime | NOT OBSERVED: no installed Herdr instance is contacted, no named-pipe or live-capture work is performed |
| Human | NOT OBSERVED: the pending manifest declares `humanReviewClaimed=false`; no human design acceptance or independent review is recorded |
| Release | NOT OBSERVED: no signing, publication, clean-machine acceptance, or release approval is performed |

Remaining v0.7 blockers are unchanged and include a real human design-review
decision against the eleven references on the reference host, accepted capture
regeneration and review, actual installed-Herdr runtime observation,
clean-machine acceptance, and the v0.7 milestone/release gate. No GitHub API
operation, package publication, capture acceptance, or release action is part
of this slice.