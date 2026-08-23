# Issue #10 live-widget acceptance verifier

`Test-V02Issue10Acceptance.ps1` is a bounded composition gate for the missing
Issue #10 evidence path. It consumes, but does not create, actual-Herdr runtime
evidence:

- Thai and English widget observation manifests and held capture bytes;
- the exact version-local runtime gate and its App/Core reports;
- the governed raw AB/BA performance receipt; and
- a separate 60-minute AC plus 60-minute Battery soak receipt.

The command also revalidates the committed package binding, source commit/tree,
App/Core/Herdr hashes, control and target session identities, widget state
correspondence, Blocked/Done semantic distinction, chronology, and bounded
publication. It refuses unknown fields, duplicate JSON properties, path escape,
reparse components, stale capture paths, receipt transplant, threshold drift,
and output clobbering.

The emitted file is deliberately `Issue10RuntimeCandidate`. Its boundary is
always `Runtime=NOT_OBSERVED`, `Human=NOT_OBSERVED`, `Release=NOT_OBSERVED`, and
`CreditGranted=false`. An actual runtime run and independent acceptance are
still required; fixture/selftest mode never starts or stops Herdr, HerdrOps, or
any application process.

The per-language widget observation is finalized by the composite runtime gate
only after that invocation's Gate, Core, and App reports have been sealed. Pass
all five optional inputs together; both output paths must be new direct children of
`artifacts/runtime-evidence/v0.2/issues-7-9-10/`:

```powershell
./tools/Test-V02LiveRuntimeAcceptance.ps1 <required-runtime-arguments> `
  -Issue10WidgetReportPath <new-widget-observation.json> `
  -Issue10BindingManifestPath <new-same-run-binding.json> `
  -Issue10PerformanceReceiptPath <performance-receipt.json> `
  -Issue10PerformanceRawSourcePath <performance-raw-source.json> `
  -Issue10SoakReceiptPath <soak-receipt.json>
```

The gate stages held copies of package, performance, soak, and installed-Herdr
authority bytes under the exact run directory, binds the same-run Gate/Core/App
hashes plus invocation nonce/source, then invokes the packaged App in headless
finalization mode. Prior-run reports, escaped outputs, incomplete inputs,
changed or hardlinked inputs, and existing destinations fail before publication.
Direct runtime-App production is rejected, closing the former pre-gate
causality gap.

Production operator contract (all paths are explicit and must be held by the
operator before invoking the command):

```powershell
./tools/v0.2-issue10-live-widget/Test-V02Issue10Acceptance.ps1 `
  -EvidenceRoot <evidence-root> `
  -ThaiWidgetReportPath <thai/widget-evidence.json> `
  -EnglishWidgetReportPath <english/widget-evidence.json> `
  -ThaiRuntimeGatePath <thai/gate-report.txt> `
  -EnglishRuntimeGatePath <english/gate-report.txt> `
  -PerformanceReceiptPath <performance/receipt.json> `
  -SoakReceiptPath <soak/receipt.json> `
  -PackageIdentityPath <package-identity-receipt.json> `
  -PackageArchivePath <HerdrOps-0.2.0-win-x64.zip> `
  -ExtractedPackageRoot <package-root> `
  -PackageProfilePath <tools/packaging/v0.2/package-identity-profile.json> `
  -ExpectedSourceCommit <40-hex> `
  -ExpectedSourceTree <40-hex> `
  -RunNonce <lowercase-32-hex> `
  -EvidenceStartedUtc <trusted-invocation-start-UTC> `
  -RepositoryRoot <clean-worktree> `
  -OutputPath <issue10-runtime-candidate.json>
```

The raw performance receipt keeps the existing v0.2 shape (`provenance`,
`rawSource`, `orders`, `soakBins`, `aggregateStatus`) and must contain exactly
AB then BA, one warmup and five measured repetitions per order, twenty raw
latency/stall observations per mode, and 24 five-minute bins. Its governed
provenance must carry the same invocation `runNonce` and both raw-byte and
canonical package-receipt hashes. The separate soak receipt carries the same
nonce and contains `provenance`, `soakBins`, and `aggregateStatus`.

`Publish-V02Issue10PerformanceSoakEvidence.ps1` is the only governed adapter
from the two live soak collector outputs, raw AB/BA collector output, its
authenticated per-acquisition telemetry binding, and the atomic transaction
commit marker that hash-binds both raw and binding files to the same nonce to
those Issue #10 receipts. It holds and canonicalizes the AC, Battery, and raw
files; revalidates the exact package and source; requires all 24 sequential
exact-App acquisitions (AB `a,b`, then BA `b,a`) with native pre-HWND renderer
proof; requires the raw 24-bin set to
equal the held AC-then-Battery outputs; and constructs `runNonce`, candidate,
and package provenance internally. It publishes a new directory atomically
and never grants Runtime, Human, or Release credit. Caller-authored provenance
or handcrafted aggregate receipts are not production inputs.

The verifier uses its own trusted UTC clock, accepts evidence only from the
preceding six hours and rejects a reused nonce with an atomic CreateNew claim.
Package and evidence handles remain open and their volume, FileId, link-count,
file-attribute/reparse identity is revalidated immediately before publication.

The governed limits are the approved 255 MiB / 267386880-byte working set,
1% CPU, 250 ms Widget latency p95, 50 ms UI-stall p95, 100 ms UI-stall maximum,
60-minute AC and Battery soak, and 5-minute bins. The verifier recomputes these
from raw observations; caller-authored aggregate PASS fields are not trusted.

Focused static/synthetic selftests:

```powershell
pwsh -File ./tools/v0.2-issue10-live-widget/Test-V02Issue10Acceptance.Tests.ps1
powershell -File ./tools/v0.2-issue10-live-widget/Test-V02Issue10Acceptance.Tests.ps1
pwsh -File ./tools/v0.2-issue10-live-widget/Publish-V02Issue10PerformanceSoakEvidence.SelfTests.ps1
powershell -File ./tools/v0.2-issue10-live-widget/Publish-V02Issue10PerformanceSoakEvidence.SelfTests.ps1
```

These tests are Static/Synthetic/Contract evidence only. The pipe hostile tests
launch short-lived PowerShell clients against the production CurrentUserOnly
named-pipe and PID guards; they do not invoke installed Herdr, mutate the
default Herdr session, install a package, or grant Runtime or Release credit.
