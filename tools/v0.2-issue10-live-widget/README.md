# Issue #10 live-widget acceptance (v4)

The current v0.2 contract is performance-only. Physical mixed-DPI review,
Battery testing, AC soak, duration/bin evidence, latency-measurement summaries,
resource slopes, and every manual review gate are out of scope and cannot close
the v4 gate. Legacy candidates or receipts containing those fields fail exact
shape/version validation.

The production comparator remains exactly 24 authenticated acquisitions: AB
then BA, one warmup pair and five measured repetitions per order. Every mode
sample carries twenty latency and twenty UI-stall observations. The independent
publisher and acceptance verifier recompute the approved instantaneous CPU,
event-to-WPF latency p95, UI-stall p95/maximum, and working-set limits. The
unchanged numeric limits bind REC-ALL v2; the performance-only scope binds
Issue #149 comment `5396694185`.

```powershell
./tools/v0.2-issue10-live-widget/Publish-V02Issue10PerformanceEvidence.ps1 `
  -RawPerformancePath <performance/raw-observations.json> `
  -PerformanceBindingPath <performance/performance-telemetry-binding.json> `
  -PerformanceCommitPath <performance/performance-commit.json> `
  -DestinationDirectory <new-output-directory> `
  -EvidenceRoot <evidence-root> `
  -RepositoryRoot <clean-exact-worktree> `
  -RunNonce <lowercase-32-hex> `
  -PackageIdentityPath <identity.json> `
  -PackageArchivePath <package.zip> `
  -ExtractedPackageRoot <package-root> `
  -ExpectedSourceCommit <lowercase-40-hex> `
  -ExpectedSourceTree <lowercase-40-hex>

./tools/v0.2-issue10-live-widget/Test-V02Issue10Acceptance.ps1 `
  -EvidenceRoot <evidence-root> `
  -ThaiWidgetReportPath <thai/widget-evidence.json> `
  -EnglishWidgetReportPath <english/widget-evidence.json> `
  -ThaiRuntimeGatePath <thai/gate-report.txt> `
  -EnglishRuntimeGatePath <english/gate-report.txt> `
  -PerformanceReceiptPath <performance/receipt.json> `
  -PackageIdentityPath <identity.json> `
  -PackageArchivePath <package.zip> `
  -ExtractedPackageRoot <package-root> `
  -PackageProfilePath <package-identity-profile.json> `
  -ExpectedSourceCommit <lowercase-40-hex> `
  -ExpectedSourceTree <lowercase-40-hex> `
  -RunNonce <lowercase-32-hex> `
  -EvidenceStartedUtc <trusted-start-UTC> `
  -RepositoryRoot <clean-exact-worktree> `
  -OutputPath <new-issue10-runtime-candidate.json>
```

The performance receipt and Issue #10 candidate are schema version 4. The
telemetry sidecar is schema version 2 and adds the observed local physical
session. Raw evidence has the exact top-level shape `{ orders }`. All package,
raw, sidecar, transaction, source, nonce, and session files remain held and
revalidated across atomic no-clobber publication.

Every output remains `Runtime=NOT_OBSERVED`, `Release=NOT_OBSERVED`, and
`CreditGranted=false` until its separate authority
is genuinely observed. Fixture PASS is Synthetic/Contract evidence only.
