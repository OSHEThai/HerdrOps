[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Issue43SecurityReviewPolicy.ps1')

function Test-Issue43CiBindingFixtures {
    $workflowPath = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\.github\workflows\ci.yml'))
    if (-not (Test-Path -LiteralPath $workflowPath -PathType Leaf)) {
        throw "Issue #43 CI workflow was not found: $workflowPath"
    }

    $workflow = [IO.File]::ReadAllText($workflowPath)
    $requiredFragments = @(
        'ISSUE43_EVENT_NAME: ${{ github.event_name }}',
        'ISSUE43_CANDIDATE_SHA: ${{ github.sha }}',
        'ISSUE43_PR_HEAD_SHA: ${{ github.event.pull_request.head.sha }}',
        'ISSUE43_PR_BASE_SHA: ${{ github.event.pull_request.base.sha }}',
        'ISSUE43_REVIEW_BRANCH: ${{ github.head_ref || github.ref_name }}',
        'git rev-list --parents -n 1 $source',
        'git switch --create $reviewBranch $candidate',
        'ISSUE43_CANDIDATE_COMMIT=$candidate',
        'ISSUE43_DIRECT_PARENT_COMMIT=$directParent',
        'ISSUE43_REVIEW_BRANCH=$reviewBranch',
        '-CandidateCommit $candidate',
        '-DirectParentCommit $directParent',
        '-Branch $branch',
        'Upload v1.0 Issue #43 security/privacy preparation reports',
        'artifacts/release-gates/v1.0.0/issue-43',
        'if-no-files-found: error',
        'HERDOPS_V02_LIVE_WIDGET_RUN_TOKEN: ${{ github.run_id }}-${{ github.run_attempt }}',
        'Run v0.2 live widgets provenance tests (PowerShell 7)',
        'Run v0.2 live widgets provenance tests (Windows PowerShell 5.1)',
        'Run solution test scheduling regression (Issue #135)'
    )
    foreach ($fragment in $requiredFragments) {
        if ($workflow.IndexOf($fragment, [StringComparison]::Ordinal) -lt 0) {
            throw "Issue #43 CI binding fragment is missing: $fragment"
        }
    }

    $requiredAlwaysSteps = @(
        @('Run v1.0 Issue #43 security-review fixtures (PowerShell 7)', 'pwsh'),
        @('Run v1.0 Issue #43 security-review fixtures (Windows PowerShell 5.1)', 'powershell'),
        @('Run v1.0 Issue #43 security/privacy preparation gate (PowerShell 7)', 'pwsh'),
        @('Run v1.0 Issue #43 security/privacy preparation gate (Windows PowerShell 5.1)', 'powershell')
    )
    foreach ($step in $requiredAlwaysSteps) {
        $pattern = '(?ms)- name: ' + [Regex]::Escape($step[0]) + '\s+if: always\(\)\s+shell: ' + [Regex]::Escape($step[1])
        if (-not [Regex]::IsMatch($workflow, $pattern)) {
            throw "Issue #43 CI step is not fail-always bound: $($step[0])"
        }
    }

    return $true
}

if (-not (Test-Issue43CiBindingFixtures)) {
    throw 'Issue #43 CI binding fixtures failed.'
}

if (-not (Test-Issue43BranchIdentityFixtures)) {
    throw 'Issue #43 branch identity fixtures failed.'
}
if (-not (Test-Issue43ScannerFixtures)) {
    throw 'Issue #43 security-review scanner fixtures failed.'
}
if (-not (Test-Issue43ProcessFixtures)) {
    throw 'Issue #43 security-review process fixtures failed.'
}
if (-not (Test-Issue43ReportWriterFixtures)) {
    throw 'Issue #43 security-review report-writer fixtures failed.'
}

Write-Output 'Issue #43 security-review scanner, process, and report-writer fixtures: PASS'
