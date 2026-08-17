# Issue #41 deterministic fixtures

`github-snapshot-ready.json` is a closed-dependency snapshot containing the Plan-backed issues, supplemental milestone issues, release trackers, and target Issue #41. It is a validator input only; it is not a GitHub state claim.

`github-duplicate-key.json` and `github-malformed.json` exercise strict JSON rejection before PowerShell's permissive object conversion can hide an error.

`tools/Test-V10Issue41DependencyAuditPagination.ps1` supplies deterministic multi-page responses to the production pagination policy. It proves ordered aggregation, exact per-page endpoint/hash binding, caller-page rejection, bounded full-page failure, replacement of ambient function/alias names, and rejection of comments, trailing commas, and leading-zero numbers without contacting GitHub.

`fake-gh-multipage.ps1` drives the actual shared milestone verifier through one milestone page and two issue pages under both Windows PowerShell 5.1 and PowerShell 7. It is deterministic test input only and does not establish GitHub or release state.

The fixture test creates short-lived report and artifact files from the current committed source identity. Those files are written only below the ignored `artifacts/` directory and are removed after each case. No fixture grants actual Herdr Runtime, Independent, Human, Release, or release-candidate credit.
