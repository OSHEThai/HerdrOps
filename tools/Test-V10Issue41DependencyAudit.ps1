[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repositoryRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')).Path
$auditTool = Join-Path $PSScriptRoot 'Invoke-V10Issue41DependencyAudit.ps1'
$strictJsonPolicy = Join-Path $PSScriptRoot 'StrictJsonPolicy.ps1'
$paginationPolicy = Join-Path $PSScriptRoot 'GitHubPaginationPolicy.ps1'
$paginationFixture = Join-Path $PSScriptRoot 'Test-V10Issue41DependencyAuditPagination.ps1'
$milestoneVerifier = Join-Path $PSScriptRoot 'Test-VersionMilestone.ps1'
$fixtureRoot = Join-Path $repositoryRoot 'tests\fixtures\v1.0\issue-41'
$readyFixture = Join-Path $fixtureRoot 'github-snapshot-ready.json'
$duplicateFixture = Join-Path $fixtureRoot 'github-duplicate-key.json'
$malformedFixture = Join-Path $fixtureRoot 'github-malformed.json'
$fakeGhFixture = Join-Path $fixtureRoot 'fake-gh-multipage.ps1'
$testRoot = Join-Path $repositoryRoot 'artifacts\dependency-audit-fixture-tests'
$fixedObservedUtc = '2026-08-17T00:00:00.0000000Z'

foreach ($path in @($auditTool, $strictJsonPolicy, $paginationPolicy, $paginationFixture, $milestoneVerifier, $readyFixture, $duplicateFixture, $malformedFixture, $fakeGhFixture)) {
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        throw "Issue #41 fixture test input is missing: $path"
    }
}

function ConvertTo-PlainText {
    param(
        [Parameter(Mandatory = $false)]
        [string]$Text
    )

    if ([string]::IsNullOrEmpty($Text)) {
        return ''
    }

    $cleaned = $Text -replace '\x1b\[[0-9;?]*[ -/]*[@-~]', ''
    $cleaned = $cleaned -replace '\x1b\][^\x07\x1b]*(\x07|\x1b\\)', ''
    $cleaned = $cleaned -replace '\x1b[@-Z\\-_]', ''
    return $cleaned
}

function Write-Utf8NoBom {
    param(
        [Parameter(Mandatory)]
        [string]$Path,

        [Parameter(Mandatory)]
        [string]$Content
    )

    $encoding = New-Object System.Text.UTF8Encoding($false)
    [IO.File]::WriteAllText($Path, $Content, $encoding)
}

function Get-SourceCommit {
    $previousPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        $lines = @(& git -C $repositoryRoot rev-parse --verify 'HEAD^{commit}' 2>&1 | ForEach-Object { [string]$_ })
        $exitCode = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $previousPreference
    }
    if ($exitCode -ne 0 -or $lines.Count -ne 1 -or $lines[0].Trim() -notmatch '^[0-9a-fA-F]{40}$') {
        throw 'Fixture tests require a committed source identity.'
    }
    return $lines[0].Trim().ToLowerInvariant()
}

function New-CaseDirectory {
    param(
        [Parameter(Mandatory)]
        [string]$ShellName
    )

    $safeName = $ShellName -replace '[^A-Za-z0-9_.-]', '_'
    $path = Join-Path $testRoot ($safeName + '-' + [Guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $path -Force | Out-Null
    return $path
}

function New-ReadyEvidenceManifest {
    param(
        [Parameter(Mandatory)]
        [string]$CaseDirectory,

        [Parameter(Mandatory)]
        [string]$SourceCommit
    )

    $gateRoot = Join-Path $CaseDirectory 'gates'
    $artifactRoot = Join-Path $CaseDirectory 'artifacts'
    New-Item -ItemType Directory -Path $gateRoot -Force | Out-Null
    New-Item -ItemType Directory -Path $artifactRoot -Force | Out-Null
    $trackerByVersion = [ordered]@{
        'v0.1.0' = 5
        'v0.2.0' = 11
        'v0.3.0' = 17
        'v0.4.0' = 23
        'v0.5.0' = 29
        'v0.6.0' = 34
        'v0.7.0' = 40
    }
    $allStatuses = [ordered]@{
        Static = 'PASS'
        Synthetic = 'PASS'
        Contract = 'PASS'
        Integration = 'PASS'
        Runtime = 'PASS'
        Independent = 'PASS'
        Human = 'PASS'
        Release = 'PASS'
    }
    $entries = New-Object System.Collections.ArrayList
    foreach ($version in $trackerByVersion.Keys) {
        $versionDirectory = Join-Path $gateRoot $version
        New-Item -ItemType Directory -Path $versionDirectory -Force | Out-Null
        $reportPath = Join-Path $versionDirectory 'gate-report.txt'
        $artifactPath = Join-Path $artifactRoot ($version + '.bin')
        Write-Utf8NoBom -Path $reportPath -Content ("Fixture gate report for {0}`r`n" -f $version)
        Write-Utf8NoBom -Path $artifactPath -Content ("Fixture artifact for {0}`r`n" -f $version)
        $reportRelative = $reportPath.Substring($repositoryRoot.Length).TrimStart([char[]]@([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)).Replace('\', '/')
        $artifactRelative = $artifactPath.Substring($repositoryRoot.Length).TrimStart([char[]]@([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)).Replace('\', '/')
        [void]$entries.Add([ordered]@{
            version = $version
            gateId = 'version-local'
            issueNumber = $trackerByVersion[$version]
            reportPath = $reportRelative
            reportSha256 = ((Get-FileHash -LiteralPath $reportPath -Algorithm SHA256).Hash).ToUpperInvariant()
            sourceCommit = $SourceCommit
            observedUtc = $fixedObservedUtc
            sourceKind = 'Fixture'
            runtimeObserved = $true
            sourcePaths = @('tools/Test-VersionMilestone.ps1')
            statuses = $allStatuses
            artifacts = @([ordered]@{
                path = $artifactRelative
                sha256 = ((Get-FileHash -LiteralPath $artifactPath -Algorithm SHA256).Hash).ToUpperInvariant()
                sourceCommit = $SourceCommit
            })
        })
    }
    $manifest = [ordered]@{
        schemaVersion = 1
        sourceCommit = $SourceCommit
        entries = @($entries)
    }
    $manifestPath = Join-Path $CaseDirectory 'evidence-manifest.json'
    Write-Utf8NoBom -Path $manifestPath -Content (($manifest | ConvertTo-Json -Depth 20) + "`r`n")
    return [pscustomobject]@{
        Path = $manifestPath
        Data = $manifest
        GateRoot = $gateRoot
        ArtifactRoot = $artifactRoot
    }
}

function Copy-JsonFixture {
    param(
        [Parameter(Mandatory)]
        [string]$SourcePath,

        [Parameter(Mandatory)]
        [string]$DestinationPath
    )

    $value = Get-Content -LiteralPath $SourcePath -Raw | ConvertFrom-Json
    Write-Utf8NoBom -Path $DestinationPath -Content (($value | ConvertTo-Json -Depth 20) + "`r`n")
    return $value
}

function Invoke-AuditCase {
    param(
        [Parameter(Mandatory)]
        [string]$ShellPath,

        [string]$FixturePath,

        [string]$EvidencePath,

        [Parameter(Mandatory)]
        [string]$OutputPath,

        [string]$CandidateCommit,

        [string]$GhCommand = 'gh'
    )

    $arguments = @(
        '-NoProfile',
        '-NonInteractive',
        '-ExecutionPolicy',
        'Bypass',
        '-File',
        $auditTool,
        '-RepositoryRoot',
        $repositoryRoot,
        '-OutputDirectory',
        $OutputPath,
        '-ObservedUtc',
        $fixedObservedUtc
    )
    if (-not [string]::IsNullOrWhiteSpace($FixturePath)) {
        $arguments += @('-FixturePath', $FixturePath)
    }
    if (-not [string]::IsNullOrWhiteSpace($EvidencePath)) {
        $arguments += @('-EvidenceManifestPath', $EvidencePath)
    }
    if ($GhCommand -ne 'gh') {
        $arguments += @('-GhExecutable', $GhCommand)
    }
    if (-not [string]::IsNullOrWhiteSpace($CandidateCommit)) {
        $arguments += @('-ReleaseCandidateCommit', $CandidateCommit)
    }
    $previousPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        $output = @(& $ShellPath @arguments 2>&1 | ForEach-Object { [string]$_ })
        $exitCode = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $previousPreference
    }
    $rawText = $output -join "`n"
    $plainText = ConvertTo-PlainText -Text $rawText
    return [pscustomobject]@{
        ExitCode = $exitCode
        Output = $plainText
        RawOutput = $rawText
    }
}

function Assert-CaseExit {
    param(
        [Parameter(Mandatory)]
        [object]$Result,

        [Parameter(Mandatory)]
        [int]$ExpectedExitCode,

        [Parameter(Mandatory)]
        [string]$CaseName
    )

    if ($Result.ExitCode -ne $ExpectedExitCode) {
        throw "$CaseName returned exit code $($Result.ExitCode), expected $ExpectedExitCode. Output: $($Result.Output)"
    }
}

function Assert-Contains {
    param(
        [Parameter(Mandatory)]
        [string]$Text,

        [Parameter(Mandatory)]
        [string]$Needle,

        [Parameter(Mandatory)]
        [string]$CaseName
    )

    $plainText = ConvertTo-PlainText -Text $Text
    $plainNeedle = ConvertTo-PlainText -Text $Needle
    if ($plainText.IndexOf($plainNeedle, [StringComparison]::Ordinal) -lt 0) {
        throw "$CaseName did not contain '$Needle'. Output: $plainText"
    }
}

function Assert-Report {
    param(
        [Parameter(Mandatory)]
        [string]$OutputPath,

        [Parameter(Mandatory)]
        [string]$CaseName
    )

    $jsonPath = Join-Path $OutputPath 'dependency-audit.json'
    $textPath = Join-Path $OutputPath 'dependency-audit.txt'
    if (-not (Test-Path -LiteralPath $jsonPath -PathType Leaf) -or -not (Test-Path -LiteralPath $textPath -PathType Leaf)) {
        throw "$CaseName did not produce both report files."
    }
    $report = Get-Content -LiteralPath $jsonPath -Raw | ConvertFrom-Json
    if ($report.Decision -ne 'NOT_READY') {
        throw "$CaseName unexpectedly produced decision $($report.Decision)."
    }
    return $report
}

function Assert-ParsedInShell {
    param(
        [Parameter(Mandatory)]
        [string]$ShellPath,

        [Parameter(Mandatory)]
        [string]$Path
    )

    $oldTarget = $env:HERDR_OPS_V10_PARSE_TARGET
    $env:HERDR_OPS_V10_PARSE_TARGET = $Path
    try {
        $command = '$target=$env:HERDR_OPS_V10_PARSE_TARGET; $tokens=$null; $errors=$null; [System.Management.Automation.Language.Parser]::ParseFile($target, [ref]$tokens, [ref]$errors) | Out-Null; if ($errors.Count -gt 0) { $errors | ForEach-Object { Write-Error $_.ToString() }; exit 1 }; Write-Output "PARSE_PASS"'
        $previousPreference = $ErrorActionPreference
        try {
            $ErrorActionPreference = 'Continue'
            $output = @(& $ShellPath -NoProfile -NonInteractive -Command $command 2>&1 | ForEach-Object { [string]$_ })
            $exitCode = $LASTEXITCODE
        }
        finally {
            $ErrorActionPreference = $previousPreference
        }
        $plainText = ConvertTo-PlainText -Text ($output -join "`n")
        if ($exitCode -ne 0 -or $plainText -notmatch 'PARSE_PASS') {
            throw "PowerShell parse failed for $Path using ${ShellPath}: $($output -join '; ')"
        }
    }
    finally {
        if ($null -eq $oldTarget) { Remove-Item Env:HERDR_OPS_V10_PARSE_TARGET -ErrorAction SilentlyContinue }
        else { $env:HERDR_OPS_V10_PARSE_TARGET = $oldTarget }
    }
}

$sourceCommit = Get-SourceCommit
$shells = New-Object System.Collections.ArrayList
foreach ($candidate in @('powershell', 'pwsh')) {
    $command = Get-Command $candidate -ErrorAction SilentlyContinue
    if ($null -ne $command) {
        [void]$shells.Add([pscustomobject]@{ Name = $candidate; Path = $command.Source })
    }
}
if ($shells.Count -eq 0) {
    throw 'Neither powershell.exe nor pwsh.exe is available for the Issue #41 fixture tests.'
}

$completed = New-Object System.Collections.ArrayList
$milestoneSource = Get-Content -LiteralPath $milestoneVerifier -Raw
$milestonePaginationCalls = [regex]::Matches(
    $milestoneSource,
    '(?m)^\s*\$(?:milestone|issue)Response\s*=\s*Read-BoundedGitHubJsonArrayPages\s*`?\s*$'
).Count
if ($milestonePaginationCalls -ne 2 -or
    $milestoneSource -notmatch 'milestones\?state=all&sort=due_on&direction=asc' -or
    $milestoneSource -notmatch 'issues\?state=all&sort=created&direction=asc') {
    throw 'The shared milestone verifier is not bound to complete, stable GitHub pagination.'
}
[void]$completed.Add('version milestone verifier: bounded pagination -> bound')
try {
    foreach ($shell in $shells) {
        Assert-ParsedInShell -ShellPath $shell.Path -Path $auditTool
        Assert-ParsedInShell -ShellPath $shell.Path -Path $strictJsonPolicy
        Assert-ParsedInShell -ShellPath $shell.Path -Path $paginationPolicy
        Assert-ParsedInShell -ShellPath $shell.Path -Path $paginationFixture
        Assert-ParsedInShell -ShellPath $shell.Path -Path $milestoneVerifier
        $previousPreference = $ErrorActionPreference
        try {
            $ErrorActionPreference = 'Continue'
            $paginationOutput = @(& $shell.Path -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $paginationFixture 2>&1 | ForEach-Object { [string]$_ })
            $paginationExitCode = $LASTEXITCODE
        }
        finally {
            $ErrorActionPreference = $previousPreference
        }
        $paginationText = ConvertTo-PlainText -Text ($paginationOutput -join "`n")
        if ($paginationExitCode -ne 0 -or $paginationText -notmatch 'bounded pagination fixtures:\s*PASS') {
            throw "$($shell.Name) pagination fixture failed (exit $paginationExitCode): $($paginationOutput -join '; ')"
        }
        [void]$completed.Add("$($shell.Name): bounded pagination -> complete")

        $previousPreference = $ErrorActionPreference
        try {
            $ErrorActionPreference = 'Continue'
            $milestoneOutput = @(& $shell.Path `
                    -NoProfile `
                    -NonInteractive `
                    -ExecutionPolicy Bypass `
                    -File $milestoneVerifier `
                    -Version 'v0.1.0' `
                    -Repository 'example' `
                    -GhExecutable $fakeGhFixture `
                    -GitHubPageSize 2 2>&1 | ForEach-Object { [string]$_ })
            $milestoneExitCode = $LASTEXITCODE
        }
        finally {
            $ErrorActionPreference = $previousPreference
        }
        $milestoneText = ConvertTo-PlainText -Text ($milestoneOutput -join "`n")
        if ($milestoneExitCode -ne 0 -or
            $milestoneText -notmatch 'TotalIssues\s*:\s*3' -or
            $milestoneText -notmatch 'IssueQueryPages\s*:\s*2') {
            throw "$($shell.Name) production milestone pagination fixture failed (exit $milestoneExitCode): $milestoneText"
        }
        [void]$completed.Add("$($shell.Name): production milestone pagination -> 3 issues across 2 pages")
        $caseDirectory = New-CaseDirectory -ShellName $shell.Name
        foreach ($generatedOutput in @(Get-ChildItem -LiteralPath (Join-Path $repositoryRoot 'artifacts\dependency-audit') -Directory -Filter ("fixture-$($shell.Name)-*") -ErrorAction SilentlyContinue)) {
            Remove-Item -LiteralPath $generatedOutput.FullName -Recurse -Force
        }
        try {
            $evidence = New-ReadyEvidenceManifest -CaseDirectory $caseDirectory -SourceCommit $sourceCommit
            $readyOutput = Join-Path $repositoryRoot ("artifacts\dependency-audit\fixture-$($shell.Name)-ready")
            if (Test-Path -LiteralPath $readyOutput) { Remove-Item -LiteralPath $readyOutput -Recurse -Force }
            $readyResult = Invoke-AuditCase -ShellPath $shell.Path -FixturePath $readyFixture -EvidencePath $evidence.Path -OutputPath $readyOutput
            Assert-CaseExit -Result $readyResult -ExpectedExitCode 2 -CaseName "$($shell.Name) offline ready fixture"
            $readyReport = Assert-Report -OutputPath $readyOutput -CaseName "$($shell.Name) offline ready fixture"
            if (@($readyReport.DependencyMap).Count -ne 45) { throw "$($shell.Name) dependency map count was $(@($readyReport.DependencyMap).Count), expected 45." }
            $v07WorkIssues = @($readyReport.DependencyMap | Where-Object { $_.Version -eq 'v0.7.0' -and -not $_.IsReleaseTracker })
            if ($v07WorkIssues.Count -ne 6) { throw "$($shell.Name) v0.7.0 work issue count was $($v07WorkIssues.Count), expected 6." }
            $issue103 = @($v07WorkIssues | Where-Object IssueNumber -eq 103)
            if ($issue103.Count -ne 1 -or $issue103[0].RoadmapKey -ne 'V070-06') { throw "$($shell.Name) v0.7.0 supplemental issue #103 was not mapped correctly." }
            if ($readyReport.ReleaseCandidate.Status -ne 'NOT_RECORDED') { throw 'Offline fixture recorded an RC.' }
            if ($readyReport.EvidenceStatus.Runtime.Status -eq 'PASS' -or $readyReport.EvidenceStatus.Release.Status -eq 'PASS') { throw 'Offline fixture granted Runtime/Release credit.' }
            Assert-Contains -Text (Get-Content -LiteralPath (Join-Path $readyOutput 'dependency-audit.txt') -Raw) -Needle 'OFFLINE_FIXTURE_NO_RELEASE_CREDIT' -CaseName "$($shell.Name) offline ready fixture"
            [void]$completed.Add("$($shell.Name): ready fixture -> NOT_READY (45 dependency items)")

            $candidateOutput = Join-Path $repositoryRoot ("artifacts\dependency-audit\fixture-$($shell.Name)-candidate-mismatch")
            $candidateResult = Invoke-AuditCase -ShellPath $shell.Path -FixturePath $readyFixture -EvidencePath $evidence.Path -OutputPath $candidateOutput -CandidateCommit ('A' * 40)
            Assert-CaseExit -Result $candidateResult -ExpectedExitCode 2 -CaseName "$($shell.Name) candidate identity fixture"
            $candidateReport = Assert-Report -OutputPath $candidateOutput -CaseName "$($shell.Name) candidate identity fixture"
            if (@($candidateReport.Blockers | Where-Object Code -eq 'RELEASE_CANDIDATE_COMMIT_MISMATCH').Count -ne 1) { throw 'Mismatched RC commit was not rejected.' }
            if ($candidateReport.ReleaseCandidate.Status -ne 'NOT_RECORDED') { throw 'Mismatched RC commit was recorded.' }
            [void]$completed.Add("$($shell.Name): RC identity mismatch -> rejected")

            $duplicateOutput = Join-Path $repositoryRoot ("artifacts\dependency-audit\fixture-$($shell.Name)-duplicate")
            $duplicateResult = Invoke-AuditCase -ShellPath $shell.Path -FixturePath $duplicateFixture -OutputPath $duplicateOutput
            Assert-CaseExit -Result $duplicateResult -ExpectedExitCode 1 -CaseName "$($shell.Name) duplicate JSON keys"
            if (Test-Path -LiteralPath $duplicateOutput) { throw "$($shell.Name) accepted duplicate JSON keys." }
            [void]$completed.Add("$($shell.Name): duplicate JSON -> rejected")

            $malformedOutput = Join-Path $repositoryRoot ("artifacts\dependency-audit\fixture-$($shell.Name)-malformed")
            $malformedResult = Invoke-AuditCase -ShellPath $shell.Path -FixturePath $malformedFixture -OutputPath $malformedOutput
            Assert-CaseExit -Result $malformedResult -ExpectedExitCode 1 -CaseName "$($shell.Name) malformed JSON"
            if (Test-Path -LiteralPath $malformedOutput) { throw "$($shell.Name) accepted malformed JSON." }
            [void]$completed.Add("$($shell.Name): malformed JSON -> rejected")

            $duplicateNumberPath = Join-Path $caseDirectory 'github-duplicate-number.json'
            $duplicateNumberFixture = Copy-JsonFixture -SourcePath $readyFixture -DestinationPath $duplicateNumberPath
            $duplicateNumberFixture.issues += $duplicateNumberFixture.issues[0]
            Write-Utf8NoBom -Path $duplicateNumberPath -Content (($duplicateNumberFixture | ConvertTo-Json -Depth 20) + "`r`n")
            $duplicateNumberOutput = Join-Path $repositoryRoot ("artifacts\dependency-audit\fixture-$($shell.Name)-duplicate-number")
            $duplicateNumberResult = Invoke-AuditCase -ShellPath $shell.Path -FixturePath $duplicateNumberPath -OutputPath $duplicateNumberOutput
            Assert-CaseExit -Result $duplicateNumberResult -ExpectedExitCode 2 -CaseName "$($shell.Name) duplicate issue number fixture"
            $duplicateNumberReport = Assert-Report -OutputPath $duplicateNumberOutput -CaseName "$($shell.Name) duplicate issue number fixture"
            if (@($duplicateNumberReport.Blockers | Where-Object Code -eq 'DUPLICATE_OR_INVALID_ISSUE_NUMBER').Count -eq 0) { throw 'Duplicate issue number was not rejected.' }
            [void]$completed.Add("$($shell.Name): duplicate issue number -> rejected")

            $duplicateKeyPath = Join-Path $caseDirectory 'github-duplicate-issue-key.json'
            $duplicateKeyFixture = Copy-JsonFixture -SourcePath $readyFixture -DestinationPath $duplicateKeyPath
            $duplicateKeyFixture.issues | Where-Object number -eq 1 | Add-Member -MemberType NoteProperty -Name body -Value '<!-- herdr-issue-key: DUPLICATE-KEY -->' -Force
            $duplicateKeyFixture.issues | Where-Object number -eq 2 | Add-Member -MemberType NoteProperty -Name body -Value '<!-- herdr-issue-key: DUPLICATE-KEY -->' -Force
            Write-Utf8NoBom -Path $duplicateKeyPath -Content (($duplicateKeyFixture | ConvertTo-Json -Depth 20) + "`r`n")
            $duplicateKeyOutput = Join-Path $repositoryRoot ("artifacts\dependency-audit\fixture-$($shell.Name)-duplicate-key")
            $duplicateKeyResult = Invoke-AuditCase -ShellPath $shell.Path -FixturePath $duplicateKeyPath -OutputPath $duplicateKeyOutput
            Assert-CaseExit -Result $duplicateKeyResult -ExpectedExitCode 2 -CaseName "$($shell.Name) duplicate issue key fixture"
            $duplicateKeyReport = Assert-Report -OutputPath $duplicateKeyOutput -CaseName "$($shell.Name) duplicate issue key fixture"
            if (@($duplicateKeyReport.Blockers | Where-Object Code -eq 'DUPLICATE_ISSUE_KEY').Count -eq 0) { throw 'Duplicate issue key was not rejected.' }
            [void]$completed.Add("$($shell.Name): duplicate issue key -> rejected")

            $openFixturePath = Join-Path $caseDirectory 'github-open.json'
            $openFixture = Copy-JsonFixture -SourcePath $readyFixture -DestinationPath $openFixturePath
            ($openFixture.issues | Where-Object number -eq 7).state = 'open'
            Write-Utf8NoBom -Path $openFixturePath -Content (($openFixture | ConvertTo-Json -Depth 20) + "`r`n")
            $openOutput = Join-Path $repositoryRoot ("artifacts\dependency-audit\fixture-$($shell.Name)-open")
            $openResult = Invoke-AuditCase -ShellPath $shell.Path -FixturePath $openFixturePath -OutputPath $openOutput
            Assert-CaseExit -Result $openResult -ExpectedExitCode 2 -CaseName "$($shell.Name) open dependency fixture"
            $openReport = Assert-Report -OutputPath $openOutput -CaseName "$($shell.Name) open dependency fixture"
            if (@($openReport.Blockers | Where-Object { $_.Code -eq 'GITHUB_OPEN_DEPENDENCY' -and $_.IssueNumber -eq 7 }).Count -ne 1) { throw 'Open dependency #7 was not reported exactly.' }
            [void]$completed.Add("$($shell.Name): open dependency -> exact blocker")

            $wrongMilestonePath = Join-Path $caseDirectory 'github-wrong-milestone.json'
            $wrongMilestoneFixture = Copy-JsonFixture -SourcePath $readyFixture -DestinationPath $wrongMilestonePath
            $wrongMilestoneIssue = $wrongMilestoneFixture.issues | Where-Object number -eq 1
            $wrongMilestoneIssue.milestone.number = 2
            $wrongMilestoneIssue.milestone.title = 'v0.2.0'
            Write-Utf8NoBom -Path $wrongMilestonePath -Content (($wrongMilestoneFixture | ConvertTo-Json -Depth 20) + "`r`n")
            $wrongMilestoneOutput = Join-Path $repositoryRoot ("artifacts\dependency-audit\fixture-$($shell.Name)-wrong-milestone")
            $wrongMilestoneResult = Invoke-AuditCase -ShellPath $shell.Path -FixturePath $wrongMilestonePath -OutputPath $wrongMilestoneOutput
            Assert-CaseExit -Result $wrongMilestoneResult -ExpectedExitCode 2 -CaseName "$($shell.Name) wrong milestone fixture"
            $wrongMilestoneReport = Assert-Report -OutputPath $wrongMilestoneOutput -CaseName "$($shell.Name) wrong milestone fixture"
            if (@($wrongMilestoneReport.Blockers | Where-Object Code -eq 'WORK_ISSUE_COUNT_MISMATCH').Count -eq 0) { throw 'Wrong milestone did not produce count mismatch.' }
            [void]$completed.Add("$($shell.Name): wrong milestone -> rejected mapping")

            $staleManifest = New-ReadyEvidenceManifest -CaseDirectory (Join-Path $caseDirectory 'stale') -SourceCommit $sourceCommit
            $staleManifest.Data.sourceCommit = ('0' * 40)
            $staleManifest.Data.entries[0].sourceCommit = ('0' * 40)
            Write-Utf8NoBom -Path $staleManifest.Path -Content (($staleManifest.Data | ConvertTo-Json -Depth 20) + "`r`n")
            $staleOutput = Join-Path $repositoryRoot ("artifacts\dependency-audit\fixture-$($shell.Name)-stale")
            $staleResult = Invoke-AuditCase -ShellPath $shell.Path -FixturePath $readyFixture -EvidencePath $staleManifest.Path -OutputPath $staleOutput
            Assert-CaseExit -Result $staleResult -ExpectedExitCode 2 -CaseName "$($shell.Name) stale evidence fixture"
            $staleReport = Assert-Report -OutputPath $staleOutput -CaseName "$($shell.Name) stale evidence fixture"
            if (@($staleReport.Blockers | Where-Object Code -eq 'EVIDENCE_MANIFEST_COMMIT_MISMATCH').Count -eq 0) { throw 'Stale manifest commit was not rejected.' }
            [void]$completed.Add("$($shell.Name): stale commit -> rejected")

            $wrongArtifactManifest = New-ReadyEvidenceManifest -CaseDirectory (Join-Path $caseDirectory 'wrong-artifact') -SourceCommit $sourceCommit
            $wrongArtifactManifest.Data.entries[0].artifacts[0].sha256 = ('F' * 64)
            Write-Utf8NoBom -Path $wrongArtifactManifest.Path -Content (($wrongArtifactManifest.Data | ConvertTo-Json -Depth 20) + "`r`n")
            $wrongArtifactOutput = Join-Path $repositoryRoot ("artifacts\dependency-audit\fixture-$($shell.Name)-wrong-artifact")
            $wrongArtifactResult = Invoke-AuditCase -ShellPath $shell.Path -FixturePath $readyFixture -EvidencePath $wrongArtifactManifest.Path -OutputPath $wrongArtifactOutput
            Assert-CaseExit -Result $wrongArtifactResult -ExpectedExitCode 2 -CaseName "$($shell.Name) wrong artifact fixture"
            $wrongArtifactReport = Assert-Report -OutputPath $wrongArtifactOutput -CaseName "$($shell.Name) wrong artifact fixture"
            if (@($wrongArtifactReport.Blockers | Where-Object Code -eq 'ARTIFACT_HASH_MISMATCH').Count -eq 0) { throw 'Wrong artifact hash was not rejected.' }
            [void]$completed.Add("$($shell.Name): wrong artifact -> rejected")

            $conflationManifest = New-ReadyEvidenceManifest -CaseDirectory (Join-Path $caseDirectory 'conflation') -SourceCommit $sourceCommit
            $conflationManifest.Data.entries[0].sourcePaths = @('tests/HerdrOps.RuntimeTests')
            Write-Utf8NoBom -Path $conflationManifest.Path -Content (($conflationManifest.Data | ConvertTo-Json -Depth 20) + "`r`n")
            $conflationOutput = Join-Path $repositoryRoot ("artifacts\dependency-audit\fixture-$($shell.Name)-conflation")
            $conflationResult = Invoke-AuditCase -ShellPath $shell.Path -FixturePath $readyFixture -EvidencePath $conflationManifest.Path -OutputPath $conflationOutput
            Assert-CaseExit -Result $conflationResult -ExpectedExitCode 2 -CaseName "$($shell.Name) evidence-class conflation fixture"
            $conflationReport = Assert-Report -OutputPath $conflationOutput -CaseName "$($shell.Name) evidence-class conflation fixture"
            if (@($conflationReport.Blockers | Where-Object Code -eq 'SYNTHETIC_WPF_RUNTIME_CONFLATION').Count -eq 0) { throw 'RuntimeTests conflation was not rejected.' }
            [void]$completed.Add("$($shell.Name): RuntimeTests conflation -> rejected")

            $reparseJunction = Join-Path $repositoryRoot ("artifacts\dependency-audit\fixture-$($shell.Name)-reparse")
            if (Test-Path -LiteralPath $reparseJunction) { [IO.Directory]::Delete($reparseJunction) }
            New-Item -ItemType Junction -Path $reparseJunction -Target $caseDirectory -ErrorAction Stop | Out-Null
            try {
                $reparseOutput = Join-Path $reparseJunction 'nested'
                $reparseResult = Invoke-AuditCase -ShellPath $shell.Path -FixturePath $readyFixture -OutputPath $reparseOutput
                Assert-CaseExit -Result $reparseResult -ExpectedExitCode 1 -CaseName "$($shell.Name) reparse output path"
                if (Test-Path -LiteralPath $reparseOutput) { throw "$($shell.Name) accepted a reparse output path." }
            }
            finally {
                if (Test-Path -LiteralPath $reparseJunction) { [IO.Directory]::Delete($reparseJunction) }
            }
            [void]$completed.Add("$($shell.Name): reparse output -> rejected")

            $traversalOutput = Join-Path $repositoryRoot 'artifacts\dependency-audit\..\issue-41-escape'
            $traversalResult = Invoke-AuditCase -ShellPath $shell.Path -FixturePath $readyFixture -OutputPath $traversalOutput
            Assert-CaseExit -Result $traversalResult -ExpectedExitCode 1 -CaseName "$($shell.Name) output traversal"
            if (Test-Path -LiteralPath (Join-Path $repositoryRoot 'artifacts\issue-41-escape')) { throw "$($shell.Name) accepted output traversal." }
            [void]$completed.Add("$($shell.Name): output traversal -> rejected")

            $missingGhOutput = Join-Path $repositoryRoot ("artifacts\dependency-audit\fixture-$($shell.Name)-gh-failure")
            $missingGhResult = Invoke-AuditCase -ShellPath $shell.Path -OutputPath $missingGhOutput -GhCommand 'herdops-command-that-does-not-exist'
            Assert-CaseExit -Result $missingGhResult -ExpectedExitCode 1 -CaseName "$($shell.Name) missing gh"
            if (Test-Path -LiteralPath $missingGhOutput) { throw "$($shell.Name) accepted missing gh." }
            [void]$completed.Add("$($shell.Name): gh failure -> rejected")

            $dirtyProbe = Join-Path $repositoryRoot ("issue-41-dirty-probe-$($shell.Name).txt")
            Write-Utf8NoBom -Path $dirtyProbe -Content 'dirty checkout probe'
            try {
                $dirtyOutput = Join-Path $repositoryRoot ("artifacts\dependency-audit\fixture-$($shell.Name)-dirty")
                $dirtyResult = Invoke-AuditCase -ShellPath $shell.Path -FixturePath $readyFixture -OutputPath $dirtyOutput
                Assert-CaseExit -Result $dirtyResult -ExpectedExitCode 1 -CaseName "$($shell.Name) dirty checkout"
                if (Test-Path -LiteralPath $dirtyOutput) { throw "$($shell.Name) accepted a dirty checkout." }
            }
            finally {
                if (Test-Path -LiteralPath $dirtyProbe) { Remove-Item -LiteralPath $dirtyProbe -Force }
            }
            [void]$completed.Add("$($shell.Name): dirty checkout -> rejected")

            # Regression: ANSI escape sequences in subprocess output do not break assertions
            $esc = [char]27
            $bel = [char]7
            $ansiSample = "$($esc)[31mError:$($esc)[0m $($esc)[1mSomething went wrong$($esc)[0m with $($esc)[32;1mTotalIssues : 3$($esc)[0m and $($esc)]0;Window Title$($bel)$($esc)[34;4mIssueQueryPages : 2$($esc)[0m"
            $ansiStripped = ConvertTo-PlainText -Text $ansiSample
            if ($ansiStripped -notmatch 'TotalIssues\s*:\s*3' -or $ansiStripped -notmatch 'IssueQueryPages\s*:\s*2' -or $ansiStripped -notmatch 'Error: Something went wrong') {
                throw "$($shell.Name) ANSI strip regression failed: $ansiStripped"
            }
            Assert-Contains -Text $ansiSample -Needle 'Something went wrong' -CaseName "$($shell.Name) ANSI Assert-Contains regression"
            [void]$completed.Add("$($shell.Name): ANSI plain-text strip -> resilient")

            # Regression: PS5 native stderr capture does not throw ActionPreferenceStopException / RemoteException
            $stderrScript = @"
`$ErrorActionPreference = 'Stop'
`$prev = `$ErrorActionPreference
try {
    `$ErrorActionPreference = 'Continue'
    `$res = @(& cmd.exe /c "echo regression_stderr_message 1>&2 & echo regression_stdout_message" 2>&1 | ForEach-Object { [string]`$_ })
    `$ec = `$LASTEXITCODE
}
finally {
    `$ErrorActionPreference = `$prev
}
`$joined = `$res -join ' '
if (`$ec -ne 0 -or `$joined -notmatch 'regression_stderr_message' -or `$joined -notmatch 'regression_stdout_message') {
    exit 1
}
Write-Output 'STDERR_CAPTURE_PASS'
"@
            $encodedStderrScript = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($stderrScript))
            $previousPreference = $ErrorActionPreference
            try {
                $ErrorActionPreference = 'Continue'
                $stderrOutput = @(& $shell.Path -NoProfile -NonInteractive -EncodedCommand $encodedStderrScript 2>&1 | ForEach-Object { [string]$_ })
                $stderrExitCode = $LASTEXITCODE
            }
            finally {
                $ErrorActionPreference = $previousPreference
            }
            $stderrText = ConvertTo-PlainText -Text ($stderrOutput -join "`n")
            if ($stderrExitCode -ne 0 -or $stderrText -notmatch 'STDERR_CAPTURE_PASS') {
                throw "$($shell.Name) native stderr capture regression failed (exit $stderrExitCode): $stderrText"
            }
            [void]$completed.Add("$($shell.Name): native stderr capture -> deterministic")

            # Regression: Omitting supplemental v0.7.0 issue (#103) is rejected with count mismatch
            $missingSupplementalPath = Join-Path $caseDirectory 'github-missing-v07-supplemental.json'
            $missingSupplementalFixture = Copy-JsonFixture -SourcePath $readyFixture -DestinationPath $missingSupplementalPath
            $missingSupplementalFixture.issues = @($missingSupplementalFixture.issues | Where-Object { [int]$_.number -ne 103 })
            Write-Utf8NoBom -Path $missingSupplementalPath -Content (($missingSupplementalFixture | ConvertTo-Json -Depth 20) + "`r`n")
            $missingSupplementalOutput = Join-Path $repositoryRoot ("artifacts\dependency-audit\fixture-$($shell.Name)-missing-v07-supplemental")
            $missingSupplementalResult = Invoke-AuditCase -ShellPath $shell.Path -FixturePath $missingSupplementalPath -OutputPath $missingSupplementalOutput
            Assert-CaseExit -Result $missingSupplementalResult -ExpectedExitCode 2 -CaseName "$($shell.Name) missing v0.7 supplemental fixture"
            $missingSupplementalReport = Assert-Report -OutputPath $missingSupplementalOutput -CaseName "$($shell.Name) missing v0.7 supplemental fixture"
            if (@($missingSupplementalReport.Blockers | Where-Object { $_.Code -eq 'WORK_ISSUE_COUNT_MISMATCH' -and $_.Version -eq 'v0.7.0' }).Count -eq 0) {
                throw "$($shell.Name) missing v0.7.0 supplemental issue did not trigger WORK_ISSUE_COUNT_MISMATCH."
            }
            if (@($missingSupplementalReport.Blockers | Where-Object { $_.Code -eq 'MISSING_OR_DUPLICATE_PLAN_ISSUE' -and $_.Version -eq 'v0.7.0' }).Count -eq 0) {
                throw "$($shell.Name) missing v0.7.0 supplemental issue did not trigger MISSING_OR_DUPLICATE_PLAN_ISSUE."
            }
            [void]$completed.Add("$($shell.Name): missing v0.7 supplemental -> rejected count")

            # Regression: Subprocess exit 0 explicitly returned on success
            if ($paginationExitCode -ne 0) {
                throw "$($shell.Name) pagination script did not exit with explicit 0: $paginationExitCode"
            }
            if ($milestoneExitCode -ne 0) {
                throw "$($shell.Name) milestone verifier script did not exit with explicit 0: $milestoneExitCode"
            }
            [void]$completed.Add("$($shell.Name): explicit exit 0 -> verified")
        }
        finally {
            if (Test-Path -LiteralPath $caseDirectory) { Remove-Item -LiteralPath $caseDirectory -Recurse -Force }
            foreach ($generatedOutput in @(Get-ChildItem -LiteralPath (Join-Path $repositoryRoot 'artifacts\dependency-audit') -Directory -Filter ("fixture-$($shell.Name)-*") -ErrorAction SilentlyContinue)) {
                Remove-Item -LiteralPath $generatedOutput.FullName -Recurse -Force
            }
        }
    }
}
finally {
    if (Test-Path -LiteralPath $testRoot) { Remove-Item -LiteralPath $testRoot -Recurse -Force }
}

$completed | ForEach-Object { Write-Output $_ }
Write-Output ("Issue #41 fixture tests passed: {0} cases" -f $completed.Count)

exit 0
