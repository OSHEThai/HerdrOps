[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$GitleaksPath,

    [string]$RepositoryRoot = (Join-Path $PSScriptRoot '..')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false

$repositoryRoot = (Resolve-Path -LiteralPath $RepositoryRoot).Path
$gitleaksPath = (Resolve-Path -LiteralPath $GitleaksPath).Path
$sourceCommit = (& git -C $repositoryRoot rev-parse --verify 'HEAD^{commit}').Trim()
if ($LASTEXITCODE -ne 0 -or $sourceCommit -notmatch '^[0-9a-f]{40}$') {
    throw 'Could not resolve the committed source for the open-source readiness gate.'
}

$pendingPaths = @(& git -C $repositoryRoot status --porcelain=v1 --untracked-files=all)
if ($LASTEXITCODE -ne 0) {
    throw 'Could not inspect the checkout state for the open-source readiness gate.'
}
if ($pendingPaths.Count -ne 0) {
    throw "The open-source readiness gate requires a clean committed checkout. Pending paths: $($pendingPaths -join '; ')"
}

$isShallow = (& git -C $repositoryRoot rev-parse --is-shallow-repository).Trim()
if ($LASTEXITCODE -ne 0 -or $isShallow -cne 'false') {
    throw 'The open-source readiness gate requires the complete Git history, not a shallow checkout.'
}

$commitCount = (& git -C $repositoryRoot rev-list --all --count).Trim()
if ($LASTEXITCODE -ne 0 -or $commitCount -notmatch '^\d+$') {
    throw 'Could not count the Git history for the open-source readiness gate.'
}

$requiredFiles = @(
    'README.md',
    'LICENSE',
    'NOTICE',
    'SECURITY.md',
    'CONTRIBUTING.md',
    'CODE_OF_CONDUCT.md',
    'THIRD-PARTY-NOTICES.md',
    'TRADEMARKS.md',
    '.github/PULL_REQUEST_TEMPLATE.md',
    '.gitleaksignore',
    'docs/security/public-repository-checklist.md',
    'Plan/GITHUB-TRACKING.md',
    'Plan/github-roadmap.json')
foreach ($relativePath in $requiredFiles) {
    $path = Join-Path $repositoryRoot $relativePath
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        throw "Required open-source file is missing: $relativePath"
    }
    if ((Get-Item -LiteralPath $path).Length -eq 0) {
        throw "Required open-source file is empty: $relativePath"
    }
}

$licenseText = Get-Content -Raw -LiteralPath (Join-Path $repositoryRoot 'LICENSE')
$licenseId = if ($licenseText -match '(?m)^\s*Apache License\s*$' -and
    $licenseText -match '(?m)^\s*Version 2\.0, January 2004\s*$') {
    'Apache-2.0'
} elseif ($licenseText -match '(?m)^MIT License\s*$' -and
    $licenseText -match 'Permission is hereby granted, free of charge') {
    'MIT'
} else {
    throw 'LICENSE is not a recognized complete Apache-2.0 or MIT license text.'
}
if ($licenseId -cne 'Apache-2.0') {
    throw "Issue #103 requires the owner-selected Apache-2.0 license; detected $licenseId."
}

$noticeText = Get-Content -Raw -LiteralPath (Join-Path $repositoryRoot 'NOTICE')
foreach ($requiredNoticeText in @(
        'Copyright 2026 OSHEThai and HerdrOps contributors',
        'approved design references, and project artwork are licensed',
        'TRADEMARKS.md')) {
    if (-not $noticeText.Contains($requiredNoticeText, [StringComparison]::Ordinal)) {
        throw "NOTICE is missing required owner-approved scope text: $requiredNoticeText"
    }
}

$readmeText = Get-Content -Raw -LiteralPath (Join-Path $repositoryRoot 'README.md')
foreach ($requiredReadmeText in @(
        '## Contributing',
        '## License',
        'CONTRIBUTING.md',
        'SECURITY.md',
        'LICENSE',
        'THIRD-PARTY-NOTICES.md',
        'TRADEMARKS.md')) {
    if (-not $readmeText.Contains($requiredReadmeText, [StringComparison]::Ordinal)) {
        throw "README.md is missing required open-source text: $requiredReadmeText"
    }
}

$roadmapText = Get-Content -Raw -LiteralPath (Join-Path $repositoryRoot 'Plan/github-roadmap.json')
$roadmap = $roadmapText | ConvertFrom-Json -Depth 100
$openSourceIssues = @($roadmap.milestones.issues | Where-Object key -eq 'V070-06')
if ($openSourceIssues.Count -ne 1 -or [string]$openSourceIssues[0].title -cne '[v0.7.0] Prepare repository for public open-source development') {
    throw 'Plan/github-roadmap.json does not contain the exact V070-06 open-source work item.'
}

$trackingText = Get-Content -Raw -LiteralPath (Join-Path $repositoryRoot 'Plan/GITHUB-TRACKING.md')
if ($trackingText -notmatch '\| v0\.7\.0 \|[^\r\n]+\| 6 \|') {
    throw 'Plan/GITHUB-TRACKING.md does not record six v0.7.0 work issues.'
}

$ignoredFingerprints = @(Get-Content -LiteralPath (Join-Path $repositoryRoot '.gitleaksignore') |
    Where-Object { -not [string]::IsNullOrWhiteSpace($_) -and -not $_.StartsWith('#', [StringComparison]::Ordinal) })
if ($ignoredFingerprints.Count -eq 0) {
    throw '.gitleaksignore must contain the exact reviewed false-positive fingerprints.'
}
foreach ($fingerprint in $ignoredFingerprints) {
    if ($fingerprint -notmatch '^[0-9a-f]{40}:[^:]+:[a-z0-9-]+:\d+$') {
        throw 'A .gitleaksignore entry is not an exact commit/path/rule/line fingerprint.'
    }
}
if ($ignoredFingerprints.Count -ne @($ignoredFingerprints | Sort-Object -Unique).Count) {
    throw '.gitleaksignore contains duplicate fingerprints.'
}

$workflowRoot = Join-Path $repositoryRoot '.github/workflows'
$workflowFiles = @(Get-ChildItem -LiteralPath $workflowRoot -File | Where-Object Extension -in @('.yml', '.yaml'))
if ($workflowFiles.Count -eq 0) {
    throw 'No GitHub Actions workflows were found.'
}

$allowedArtifactPath = '^artifacts/(test-results|design-evidence|performance-evidence|release-gates|governance)(/|$)'
$actionReferences = 0
$artifactUploads = 0
foreach ($workflow in $workflowFiles) {
    $text = Get-Content -Raw -LiteralPath $workflow.FullName
    if ($text -notmatch '(?m)^permissions:\r?\n  contents: read\r?$') {
        throw "$($workflow.Name) must set the top-level workflow permission to contents: read."
    }
    foreach ($forbiddenPattern in @(
            '(?m)^\s*(pull_request_target|workflow_run|issue_comment|repository_dispatch):',
            '\$\{\{\s*secrets\.',
            '(?m)^\s+[a-z-]+:\s*write\s*$')) {
        if ($text -match $forbiddenPattern) {
            throw "$($workflow.Name) contains a forbidden privileged trigger, secret reference, or write permission."
        }
    }

    $usesMatches = [regex]::Matches($text, '(?m)^\s*uses:\s*(?<reference>\S+)')
    foreach ($usesMatch in $usesMatches) {
        $reference = $usesMatch.Groups['reference'].Value
        if ($reference.StartsWith('./', [StringComparison]::Ordinal)) {
            continue
        }
        $actionReferences++
        if ($reference -notmatch '^[^@\s]+@[0-9a-fA-F]{40}$') {
            throw "$($workflow.Name) uses a third-party Action without an immutable 40-character commit pin: $reference"
        }
    }

    $stepMatches = [regex]::Matches($text, '(?ms)^\s{6}- name:.*?(?=^\s{6}- name:|\z)')
    foreach ($stepMatch in $stepMatches) {
        $step = $stepMatch.Value
        if ($step -notmatch 'uses:\s*actions/upload-artifact@') {
            continue
        }
        $artifactUploads++
        if ($step -notmatch '(?m)^\s+retention-days:\s*7\s*$') {
            throw "$($workflow.Name) has an artifact upload without retention-days: 7."
        }

        $lines = @($step -split '\r?\n')
        $pathIndex = -1
        for ($index = 0; $index -lt $lines.Count; $index++) {
            if ($lines[$index] -match '^\s+path:\s*(?<value>.*)$') {
                $pathIndex = $index
                $inlinePath = $Matches.value.Trim()
                break
            }
        }
        if ($pathIndex -lt 0) {
            throw "$($workflow.Name) has an artifact upload without an explicit path."
        }

        $paths = [System.Collections.Generic.List[string]]::new()
        if ($inlinePath -notin @('', '|', '>')) {
            $paths.Add($inlinePath)
        } else {
            for ($index = $pathIndex + 1; $index -lt $lines.Count; $index++) {
                if ($lines[$index] -match '^\s{12,}(?<value>\S.*)$') {
                    $paths.Add($Matches.value.Trim())
                    continue
                }
                if (-not [string]::IsNullOrWhiteSpace($lines[$index])) {
                    break
                }
            }
        }
        if ($paths.Count -eq 0) {
            throw "$($workflow.Name) has an artifact upload with no bounded path."
        }
        foreach ($path in $paths) {
            $normalizedPath = $path.Replace('\', '/').TrimEnd('/')
            if ($normalizedPath -notmatch $allowedArtifactPath -or
                $normalizedPath -match 'runtime-evidence|diagnostic|(^|/)logs?(/|$)|(^|/)data(/|$)|\$\{\{') {
                throw "$($workflow.Name) uploads a path outside the public artifact allowlist: $path"
            }
        }
    }
}
if ($actionReferences -eq 0 -or $artifactUploads -eq 0) {
    throw 'The workflow review found no third-party Actions or no artifact uploads; the policy coverage is incomplete.'
}

$artifactRoot = Join-Path $repositoryRoot 'artifacts'
$runId = "$([DateTime]::UtcNow.ToString('yyyyMMddTHHmmssfffffffZ', [Globalization.CultureInfo]::InvariantCulture))-$([Guid]::NewGuid().ToString('N').Substring(0, 8))"
$gateDirectory = Join-Path $artifactRoot "governance\open-source-readiness\$runId"
New-Item -ItemType Directory -Path $gateDirectory -Force | Out-Null
$gitleaksReportPath = Join-Path $gateDirectory 'gitleaks-redacted.json'

Push-Location $repositoryRoot
try {
    & $gitleaksPath git --no-banner --redact=100 --report-format json --report-path $gitleaksReportPath .
    $gitleaksExitCode = $LASTEXITCODE
} finally {
    Pop-Location
}
if ($gitleaksExitCode -notin @(0, 1)) {
    throw "Gitleaks failed operationally with exit code $gitleaksExitCode."
}
$secretFindings = @()
if (Test-Path -LiteralPath $gitleaksReportPath -PathType Leaf) {
    $parsedFindings = Get-Content -Raw -LiteralPath $gitleaksReportPath | ConvertFrom-Json
    if ($null -ne $parsedFindings) {
        $secretFindings = @($parsedFindings)
    }
}

$gateReportPath = Join-Path $gateDirectory 'gate-report.txt'
$result = if ($secretFindings.Count -eq 0 -and $gitleaksExitCode -eq 0) { 'PASS' } else { 'FAIL' }
$report = @(
    'HerdrOps Open-Source Readiness Gate',
    "GeneratedUtc: $([DateTime]::UtcNow.ToString('O'))",
    "SourceCommit: $sourceCommit",
    "Result: $result",
    "License: $licenseId",
    "GitHistoryComplete: True",
    "GitCommitsScanned: $commitCount",
    "SecretFindingsAfterExactAllowlist: $($secretFindings.Count)",
    "ReviewedFalsePositiveFingerprints: $($ignoredFingerprints.Count)",
    "WorkflowFilesReviewed: $($workflowFiles.Count)",
    "ImmutableActionReferences: $actionReferences",
    "BoundedArtifactUploads: $artifactUploads",
    'WorkflowPermissions: contents:read',
    'UntrustedPullRequestSecrets: FORBIDDEN',
    'PublicArtifactRetentionDays: 7',
    'StaticEvidence: OBSERVED',
    'SyntheticEvidence: NOT REQUIRED / NOT OBSERVED',
    'ContractEvidence: NOT REQUIRED / NOT OBSERVED',
    'ActualHerdrRuntime: NOT REQUIRED / NOT OBSERVED / NOT CLAIMED',
    'ReleaseEvidence: NOT OBSERVED / NOT CLAIMED',
    '',
    'EvidenceBoundary:',
    'This report proves repository-community files, planning linkage, GitHub Actions policy, bounded artifact paths, and a redacted complete-history secret scan at one committed source.',
    'It does not prove public visibility, GitHub organization settings, installed Herdr runtime behavior, Beta acceptance, packaging, or any product release.')
[IO.File]::WriteAllLines($gateReportPath, $report, [Text.UTF8Encoding]::new($false))
$report | Write-Output
Write-Output "GateReport: $gateReportPath"

if ($result -ne 'PASS') {
    throw "The complete-history secret scan found $($secretFindings.Count) untriaged candidate(s). Review only the redacted report."
}
