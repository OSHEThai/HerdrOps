<#
.SYNOPSIS
    Deterministic, build-free hostile selftests for v0.5 compliance runtime wrapper provenance.
    PS 5.1 and PS 7+ compatible.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'lib\V05ComplianceRuntimeTraceOrchestration.ps1')

$failures = [Collections.Generic.List[string]]::new()

function Assert-Condition {
    param(
        [Parameter(Mandatory)][bool]$Condition,
        [Parameter(Mandatory)][string]$Message
    )

    if (-not $Condition) {
        $script:failures.Add($Message)
        Write-Host "FAIL: $Message" -ForegroundColor Red
    } else {
        Write-Host "PASS: $Message" -ForegroundColor Green
    }
}

function Assert-ThrowsPrefix {
    param(
        [Parameter(Mandatory)][scriptblock]$ScriptBlock,
        [Parameter(Mandatory)][string]$ExpectedPrefix,
        [Parameter(Mandatory)][string]$Message
    )

    $threw = $false
    $matched = $false
    try {
        & $ScriptBlock
    } catch {
        $threw = $true
        if ($_.Exception.Message -like "$ExpectedPrefix*") {
            $matched = $true
        } else {
            Write-Host "  (threw, but unexpected message: $($_.Exception.Message))" -ForegroundColor Yellow
        }
    }
    Assert-Condition -Condition ($threw -and $matched) -Message $Message
}

$scratchRoot = Join-Path ([IO.Path]::GetTempPath()) ("v05-wrapper-provenance-tests-" + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $scratchRoot -Force | Out-Null

try {
    # 1. Non-git directory fails closed
    Assert-ThrowsPrefix `
        -ScriptBlock { Get-CleanSourceIdentity -Root $scratchRoot } `
        -ExpectedPrefix 'SourceCommitResolutionFailed' `
        -Message 'Get-CleanSourceIdentity fails closed when root is not a Git repository'

    # Initialize isolated scratch repository
    $repoRoot = Join-Path $scratchRoot 'repo'
    New-Item -ItemType Directory -Path $repoRoot -Force | Out-Null
    & git -C $repoRoot init --quiet | Out-Null
    & git -C $repoRoot config user.email 'v05selftest@example.invalid' | Out-Null
    & git -C $repoRoot config user.name 'V05 Selftest' | Out-Null

    $fileA = Join-Path $repoRoot 'sample.txt'
    [IO.File]::WriteAllText($fileA, "v0.5 compliance test initial`n", [Text.UTF8Encoding]::new($false))
    & git -C $repoRoot add . | Out-Null
    & git -C $repoRoot commit --quiet -m 'Initial commit' | Out-Null

    # 2. Clean scratch repo resolves valid 40-hex commit and tree
    $identity1 = Get-CleanSourceIdentity -Root $repoRoot
    Assert-Condition -Condition ($identity1.Commit -match '^[0-9a-f]{40}$') -Message 'Get-CleanSourceIdentity returns 40-hex commit hash'
    Assert-Condition -Condition ($identity1.Tree -match '^[0-9a-f]{40}$') -Message 'Get-CleanSourceIdentity returns 40-hex tree hash'
    Assert-Condition -Condition ($identity1.Clean -eq $true) -Message 'Get-CleanSourceIdentity reports Clean = true'

    # 3. Assert-CleanSourceIdentity succeeds when expected matches actual
    $assertOk = Assert-CleanSourceIdentity `
        -Root $repoRoot `
        -ExpectedCommit $identity1.Commit `
        -ExpectedTree $identity1.Tree `
        -Phase 'Pre-run'
    Assert-Condition -Condition ($assertOk.Commit -eq $identity1.Commit) -Message 'Assert-CleanSourceIdentity passes on exact match'

    # 4. Assert-CleanSourceIdentity fails closed on commit mismatch
    $wrongCommit = '0123456789abcdef0123456789abcdef01234567'
    Assert-ThrowsPrefix `
        -ScriptBlock {
            Assert-CleanSourceIdentity `
                -Root $repoRoot `
                -ExpectedCommit $wrongCommit `
                -ExpectedTree $identity1.Tree `
                -Phase 'Pre-run'
        } `
        -ExpectedPrefix 'SourceCommitMismatch' `
        -Message 'Assert-CleanSourceIdentity fails closed on commit mismatch'

    # 5. Assert-CleanSourceIdentity fails closed on tree mismatch
    $wrongTree = 'fedcba9876543210fedcba9876543210fedcba98'
    Assert-ThrowsPrefix `
        -ScriptBlock {
            Assert-CleanSourceIdentity `
                -Root $repoRoot `
                -ExpectedCommit $identity1.Commit `
                -ExpectedTree $wrongTree `
                -Phase 'Pre-run'
        } `
        -ExpectedPrefix 'SourceTreeMismatch' `
        -Message 'Assert-CleanSourceIdentity fails closed on tree mismatch'

    # 6. Dirty working tree (modified tracked file) fails closed
    [IO.File]::WriteAllText($fileA, "modified content`n", [Text.UTF8Encoding]::new($false))
    Assert-ThrowsPrefix `
        -ScriptBlock { Get-CleanSourceIdentity -Root $repoRoot } `
        -ExpectedPrefix 'WorkingTreeDirty' `
        -Message 'Get-CleanSourceIdentity fails closed on modified tracked file'

    Assert-ThrowsPrefix `
        -ScriptBlock {
            Assert-CleanSourceIdentity `
                -Root $repoRoot `
                -ExpectedCommit $identity1.Commit `
                -ExpectedTree $identity1.Tree `
                -Phase 'Pre-run'
        } `
        -ExpectedPrefix 'WorkingTreeDirty' `
        -Message 'Assert-CleanSourceIdentity fails closed on modified tracked file'

    # Reset tracked file
    & git -C $repoRoot checkout -- . | Out-Null

    # 7. Dirty working tree (untracked file dropped) fails closed
    $untrackedFile = Join-Path $repoRoot 'leak.json'
    [IO.File]::WriteAllText($untrackedFile, "{}`n", [Text.UTF8Encoding]::new($false))
    Assert-ThrowsPrefix `
        -ScriptBlock { Get-CleanSourceIdentity -Root $repoRoot } `
        -ExpectedPrefix 'WorkingTreeDirty' `
        -Message 'Get-CleanSourceIdentity fails closed on untracked file'
    Remove-Item -LiteralPath $untrackedFile -Force

    # 8. Mid-run commit change detection
    $fileB = Join-Path $repoRoot 'second.txt'
    [IO.File]::WriteAllText($fileB, "second commit`n", [Text.UTF8Encoding]::new($false))
    & git -C $repoRoot add . | Out-Null
    & git -C $repoRoot commit --quiet -m 'Second commit' | Out-Null

    Assert-ThrowsPrefix `
        -ScriptBlock {
            Assert-CleanSourceIdentity `
                -Root $repoRoot `
                -ExpectedCommit $identity1.Commit `
                -ExpectedTree $identity1.Tree `
                -Phase 'Post-run'
        } `
        -ExpectedPrefix 'SourceCommitMismatch' `
        -Message 'Assert-CleanSourceIdentity fails closed on mid-run commit mutation'

    # 9. Write-ComplianceRuntimeFailureReport writes NoRuntimeCredit gate report
    $failureReportPath = Join-Path $scratchRoot 'failure-gate-report.txt'
    Write-ComplianceRuntimeFailureReport `
        -GateReportPath $failureReportPath `
        -FailureMessage 'Intentional test failure message' `
        -SourceCommit $identity1.Commit `
        -SourceTree $identity1.Tree

    Assert-Condition -Condition (Test-Path -LiteralPath $failureReportPath -PathType Leaf) -Message 'Failure report was written to disk'
    $failureReportContent = Get-Content -LiteralPath $failureReportPath -Raw
    Assert-Condition -Condition ($failureReportContent -match 'Result: FAIL') -Message 'Failure report contains Result: FAIL'
    Assert-Condition -Condition ($failureReportContent -match 'EvidenceClass: NoRuntimeCredit') -Message 'Failure report contains EvidenceClass: NoRuntimeCredit'
    Assert-Condition -Condition ($failureReportContent -match "SourceCommit: $($identity1.Commit)") -Message 'Failure report binds SourceCommit'
    Assert-Condition -Condition ($failureReportContent -match "SourceTree: $($identity1.Tree)") -Message 'Failure report binds SourceTree'
    Assert-Condition -Condition ($failureReportContent -match 'Intentional test failure message') -Message 'Failure report contains failure message'

    # 10. Static AST parameter validation of Invoke-V05ComplianceRuntimeAcceptance.ps1
    $wrapperScriptPath = Join-Path $PSScriptRoot 'Invoke-V05ComplianceRuntimeAcceptance.ps1'
    Assert-Condition -Condition (Test-Path -LiteralPath $wrapperScriptPath -PathType Leaf) -Message 'Wrapper script file exists'

    $tokens = $null
    $errors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($wrapperScriptPath, [ref]$tokens, [ref]$errors)
    Assert-Condition -Condition ($errors.Count -eq 0) -Message 'Wrapper script parses cleanly without syntax errors'

    $paramAst = $ast.ParamBlock
    Assert-Condition -Condition ($null -ne $paramAst) -Message 'Wrapper script contains a ParamBlock'

    $paramNames = @($paramAst.Parameters | ForEach-Object { $_.Name.VariablePath.UserPath })
    Assert-Condition -Condition ($paramNames -contains 'ExpectedSourceCommit') -Message 'ParamBlock defines ExpectedSourceCommit'
    Assert-Condition -Condition ($paramNames -contains 'ExpectedSourceTree') -Message 'ParamBlock defines ExpectedSourceTree'

    $commitParam = @($paramAst.Parameters | Where-Object { $_.Name.VariablePath.UserPath -eq 'ExpectedSourceCommit' })[0]
    $treeParam = @($paramAst.Parameters | Where-Object { $_.Name.VariablePath.UserPath -eq 'ExpectedSourceTree' })[0]

    $commitAttributes = @($commitParam.Attributes | ForEach-Object { $_.TypeName.FullName })
    $treeAttributes = @($treeParam.Attributes | ForEach-Object { $_.TypeName.FullName })

    Assert-Condition -Condition ($commitAttributes -contains 'Parameter') -Message 'ExpectedSourceCommit has Parameter attribute'
    Assert-Condition -Condition ($commitAttributes -contains 'ValidatePattern') -Message 'ExpectedSourceCommit has ValidatePattern attribute'
    Assert-Condition -Condition ($treeAttributes -contains 'Parameter') -Message 'ExpectedSourceTree has Parameter attribute'
    Assert-Condition -Condition ($treeAttributes -contains 'ValidatePattern') -Message 'ExpectedSourceTree has ValidatePattern attribute'

    $wrapperText = Get-Content -LiteralPath $wrapperScriptPath -Raw
    Assert-Condition -Condition ($wrapperText -match "Phase\s*=\s*'Pre-run'|Phase\s+'Pre-run'") -Message 'Wrapper contains Pre-run Assert-CleanSourceIdentity'
    Assert-Condition -Condition ($wrapperText -match "Phase\s*=\s*'Post-run'|Phase\s+'Post-run'") -Message 'Wrapper contains Post-run Assert-CleanSourceIdentity'
    Assert-Condition -Condition ($wrapperText -match 'SourceTree:\s*\$sourceTree') -Message 'Wrapper gate report includes SourceTree'
    Assert-Condition -Condition ($wrapperText -match 'Write-ComplianceRuntimeFailureReport') -Message 'Wrapper includes Write-ComplianceRuntimeFailureReport in catch'
}
finally {
    Remove-Item -LiteralPath $scratchRoot -Recurse -Force -ErrorAction SilentlyContinue
}

if ($failures.Count -gt 0) {
    Write-Host ''
    Write-Host "$($failures.Count) assertion(s) failed under PowerShell $($PSVersionTable.PSVersion):" -ForegroundColor Red
    $failures | ForEach-Object { Write-Host "  - $_" -ForegroundColor Red }
    exit 1
}

$global:LASTEXITCODE = 0
Write-Host ''
Write-Host "All v0.5 compliance runtime wrapper provenance selftests passed under PowerShell $($PSVersionTable.PSVersion)." -ForegroundColor Green
exit 0
