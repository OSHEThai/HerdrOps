# Issue #9 live UI functional acceptance

`Test-V02Issue9LiveUiAcceptance.ps1` is the production verifier for the Issue #9
functional receipt. It consumes two already-completed actual-Herdr runtime legs
and two side-by-side UI receipt directories; it does not launch, stop, or
control Herdr, Core, or the App.

Production invocation requires:

```powershell
./tools/v0.2-issue9-live-ui/Test-V02Issue9LiveUiAcceptance.ps1 `
  -ThaiRuntimeEvidenceDirectory <absolute Thai runtime root> `
  -EnglishRuntimeEvidenceDirectory <absolute English runtime root> `
  -ThaiUiEvidenceDirectory <absolute Thai UI receipt root> `
  -EnglishUiEvidenceDirectory <absolute English UI receipt root> `
  -MatrixCandidatePath <accepted RuntimeMatrixCandidate JSON> `
  -PackageIdentityPath <accepted package identity receipt> `
  -PackageArchivePath <immutable archive used by the runtime run> `
  -ExtractedPackageRoot <validated extracted package root> `
  -RepositoryRoot <exact clean checkout> `
  -ExpectedSourceCommit <40-char lowercase commit> `
  -ExpectedSourceTree <40-char lowercase tree> `
  -OutputPath <new output path outside every evidence tree>
```

The verifier fails closed unless both language legs bind the same exact source
commit/tree, package identity/archive/manifest/App/Core hashes, Herdr release,
protocol, control session, target session, and matrix payload. Each UI receipt
must contain the three pages `Overview`, `LiveOrganization`, and `AgentDetail`,
one exact workspace/project/agent/task/pane/status selection, and a Core-bound
side-by-side capture. Lifecycle evidence must show Dashboard close while Core
continues, target disconnect/reconnect, and reconciliation. Page and language
fields are strict and unknown/duplicate/missing values are rejected.

`Test-V02Issue9LiveUiAcceptance.Tests.ps1` is fixture-only Synthetic evidence.
It never starts or stops the default Herdr session or an application process.
The emitted candidate is `Issue9RuntimeCandidate`; its Runtime and HumanVisual
fields remain `NOT_OBSERVED` and `ReleaseCredit` remains `false`. A real run is
still required before Issue #9 can receive Runtime or Human/Release credit.
