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

    # 11. Documentation synchronization in tools/README.md
    $readmePath = Join-Path $PSScriptRoot 'README.md'
    Assert-Condition -Condition (Test-Path -LiteralPath $readmePath -PathType Leaf) -Message 'tools/README.md exists'

    $readmeText = Get-Content -LiteralPath $readmePath -Raw
    Assert-Condition -Condition ($readmeText -match 'Invoke-V05ComplianceRuntimeAcceptance\.ps1[\s\S]*?intentionally fail-closed') -Message 'tools/README.md documents the disabled legacy wrapper'
    Assert-Condition -Condition ($readmeText -match 'one orchestrator process cannot[\s\S]*?changing HERDR_PANE_ID') -Message 'tools/README.md documents why environment reassignment is not role provenance'
    Assert-Condition -Condition ($readmeText -match 'Test-V05DistributedRoleProvenance\.ps1') -Message 'tools/README.md routes static verification to the distributed provenance selftest'
    Assert-Condition -Condition ($wrapperText -match 'DistributedRoleProvenanceRequired:[^\r\n]*NoRuntimeCredit') -Message 'Wrapper records the fail-closed NoRuntimeCredit boundary'

    # 12. Assert-V05JsonBooleanProperty unit tests
    $dummyObj = [pscustomobject]@{
        BoolTrue = $true
        BoolFalse = $false
        StringTrue = 'true'
        StringFalse = 'false'
        NumericOne = 1
        NumericZero = 0
        NullProp = $null
    }

    # Positive: CLR Boolean true and false
    $boolTruePassed = $true
    try {
        Assert-V05JsonBooleanProperty -TargetObject $dummyObj -PropertyName 'BoolTrue' -ExpectedValue $true -ContextPath 'test.json'
    } catch {
        $boolTruePassed = $false
    }
    Assert-Condition -Condition $boolTruePassed -Message 'Assert-V05JsonBooleanProperty accepts valid CLR Boolean true'

    $boolFalsePassed = $true
    try {
        Assert-V05JsonBooleanProperty -TargetObject $dummyObj -PropertyName 'BoolFalse' -ExpectedValue $false -ContextPath 'test.json'
    } catch {
        $boolFalsePassed = $false
    }
    Assert-Condition -Condition $boolFalsePassed -Message 'Assert-V05JsonBooleanProperty accepts valid CLR Boolean false'

    # Negative: boolean value mismatch
    Assert-ThrowsPrefix `
        -ScriptBlock { Assert-V05JsonBooleanProperty -TargetObject $dummyObj -PropertyName 'BoolTrue' -ExpectedValue $false -ContextPath 'test.json' } `
        -ExpectedPrefix "JSON property 'BoolTrue' is True (expected False)" `
        -Message 'Assert-V05JsonBooleanProperty rejects Boolean value mismatch'

    # Negative: string 'true' / 'false'
    Assert-ThrowsPrefix `
        -ScriptBlock { Assert-V05JsonBooleanProperty -TargetObject $dummyObj -PropertyName 'StringTrue' -ExpectedValue $true -ContextPath 'test.json' } `
        -ExpectedPrefix "JSON property 'StringTrue' must be a CLR Boolean, but found 'System.String'" `
        -Message 'Assert-V05JsonBooleanProperty rejects string "true"'

    Assert-ThrowsPrefix `
        -ScriptBlock { Assert-V05JsonBooleanProperty -TargetObject $dummyObj -PropertyName 'StringFalse' -ExpectedValue $false -ContextPath 'test.json' } `
        -ExpectedPrefix "JSON property 'StringFalse' must be a CLR Boolean, but found 'System.String'" `
        -Message 'Assert-V05JsonBooleanProperty rejects string "false"'

    # Negative: numeric 1 / 0
    Assert-ThrowsPrefix `
        -ScriptBlock { Assert-V05JsonBooleanProperty -TargetObject $dummyObj -PropertyName 'NumericOne' -ExpectedValue $true -ContextPath 'test.json' } `
        -ExpectedPrefix "JSON property 'NumericOne' must be a CLR Boolean, but found 'System.Int32'" `
        -Message 'Assert-V05JsonBooleanProperty rejects numeric 1'

    Assert-ThrowsPrefix `
        -ScriptBlock { Assert-V05JsonBooleanProperty -TargetObject $dummyObj -PropertyName 'NumericZero' -ExpectedValue $false -ContextPath 'test.json' } `
        -ExpectedPrefix "JSON property 'NumericZero' must be a CLR Boolean, but found 'System.Int32'" `
        -Message 'Assert-V05JsonBooleanProperty rejects numeric 0'

    # Negative: missing property
    Assert-ThrowsPrefix `
        -ScriptBlock { Assert-V05JsonBooleanProperty -TargetObject $dummyObj -PropertyName 'NonExistent' -ExpectedValue $true -ContextPath 'test.json' } `
        -ExpectedPrefix "JSON object is missing required boolean property 'NonExistent'" `
        -Message 'Assert-V05JsonBooleanProperty rejects missing property'

    # Negative: null property
    Assert-ThrowsPrefix `
        -ScriptBlock { Assert-V05JsonBooleanProperty -TargetObject $dummyObj -PropertyName 'NullProp' -ExpectedValue $true -ContextPath 'test.json' } `
        -ExpectedPrefix "JSON property 'NullProp' value is null" `
        -Message 'Assert-V05JsonBooleanProperty rejects null property value'

    # 13. Assert-V05CompositeRuntimeReport positive and negative hostile tests
    $validCompositeJson = [ordered]@{
        EvidenceClassification = 'Runtime'
        RuntimeAccepted = $true
        SessionControlInvoked = $false
        Acceptance = [ordered]@{
            Passed = $true
        }
    }

    $compPath = Join-Path $scratchRoot 'composite-test.json'
    [IO.File]::WriteAllText($compPath, ($validCompositeJson | ConvertTo-Json -Depth 5), [Text.UTF8Encoding]::new($false))
    $parsedComp = Assert-V05CompositeRuntimeReport -ReportPath $compPath
    Assert-Condition -Condition ($null -ne $parsedComp -and [bool]$parsedComp.RuntimeAccepted -and -not [bool]$parsedComp.SessionControlInvoked) -Message 'Assert-V05CompositeRuntimeReport parses valid composite report'

    # Composite: non-Runtime EvidenceClassification
    $badClassComp = [ordered]@{
        EvidenceClassification = 'Synthetic'
        RuntimeAccepted = $true
        SessionControlInvoked = $false
        Acceptance = [ordered]@{ Passed = $true }
    }
    [IO.File]::WriteAllText($compPath, ($badClassComp | ConvertTo-Json -Depth 5), [Text.UTF8Encoding]::new($false))
    Assert-ThrowsPrefix `
        -ScriptBlock { Assert-V05CompositeRuntimeReport -ReportPath $compPath } `
        -ExpectedPrefix 'Composite compliance report EvidenceClassification must be string' `
        -Message 'Assert-V05CompositeRuntimeReport rejects non-Runtime EvidenceClassification'

    # Composite: RuntimeAccepted = false
    $badRuntimeComp = [ordered]@{
        EvidenceClassification = 'Runtime'
        RuntimeAccepted = $false
        SessionControlInvoked = $false
        Acceptance = [ordered]@{ Passed = $true }
    }
    [IO.File]::WriteAllText($compPath, ($badRuntimeComp | ConvertTo-Json -Depth 5), [Text.UTF8Encoding]::new($false))
    Assert-ThrowsPrefix `
        -ScriptBlock { Assert-V05CompositeRuntimeReport -ReportPath $compPath } `
        -ExpectedPrefix "JSON property 'RuntimeAccepted' is False (expected True)" `
        -Message 'Assert-V05CompositeRuntimeReport rejects RuntimeAccepted = false'

    # Composite: RuntimeAccepted = 'true' (string)
    $badRuntimeStrComp = [ordered]@{
        EvidenceClassification = 'Runtime'
        RuntimeAccepted = 'true'
        SessionControlInvoked = $false
        Acceptance = [ordered]@{ Passed = $true }
    }
    [IO.File]::WriteAllText($compPath, ($badRuntimeStrComp | ConvertTo-Json -Depth 5), [Text.UTF8Encoding]::new($false))
    Assert-ThrowsPrefix `
        -ScriptBlock { Assert-V05CompositeRuntimeReport -ReportPath $compPath } `
        -ExpectedPrefix "JSON property 'RuntimeAccepted' must be a CLR Boolean" `
        -Message 'Assert-V05CompositeRuntimeReport rejects string RuntimeAccepted'

    # Composite: SessionControlInvoked = true
    $badSessionComp = [ordered]@{
        EvidenceClassification = 'Runtime'
        RuntimeAccepted = $true
        SessionControlInvoked = $true
        Acceptance = [ordered]@{ Passed = $true }
    }
    [IO.File]::WriteAllText($compPath, ($badSessionComp | ConvertTo-Json -Depth 5), [Text.UTF8Encoding]::new($false))
    Assert-ThrowsPrefix `
        -ScriptBlock { Assert-V05CompositeRuntimeReport -ReportPath $compPath } `
        -ExpectedPrefix "JSON property 'SessionControlInvoked' is True (expected False)" `
        -Message 'Assert-V05CompositeRuntimeReport rejects SessionControlInvoked = true'

    # Composite: Missing Acceptance
    $noAcceptanceComp = [ordered]@{
        EvidenceClassification = 'Runtime'
        RuntimeAccepted = $true
        SessionControlInvoked = $false
    }
    [IO.File]::WriteAllText($compPath, ($noAcceptanceComp | ConvertTo-Json -Depth 5), [Text.UTF8Encoding]::new($false))
    Assert-ThrowsPrefix `
        -ScriptBlock { Assert-V05CompositeRuntimeReport -ReportPath $compPath } `
        -ExpectedPrefix 'Composite compliance report is missing Acceptance object' `
        -Message 'Assert-V05CompositeRuntimeReport rejects missing Acceptance'

    # Composite: Acceptance.Passed = false
    $badPassedComp = [ordered]@{
        EvidenceClassification = 'Runtime'
        RuntimeAccepted = $true
        SessionControlInvoked = $false
        Acceptance = [ordered]@{ Passed = $false }
    }
    [IO.File]::WriteAllText($compPath, ($badPassedComp | ConvertTo-Json -Depth 5), [Text.UTF8Encoding]::new($false))
    Assert-ThrowsPrefix `
        -ScriptBlock { Assert-V05CompositeRuntimeReport -ReportPath $compPath } `
        -ExpectedPrefix "JSON property 'Passed' is False (expected True)" `
        -Message 'Assert-V05CompositeRuntimeReport rejects Acceptance.Passed = false'

    # 14. Assert-V05HerdrRuntimeReport positive and negative hostile tests
    $validHerdrJson = [ordered]@{
        EvidenceClassification = 'Runtime'
        RuntimeObserved = $true
        SnapshotObserved = $true
        EventObserved = $true
        ReconnectObserved = $true
        SessionControlInvoked = $false
    }

    $herdrPath = Join-Path $scratchRoot 'herdr-test.json'
    [IO.File]::WriteAllText($herdrPath, ($validHerdrJson | ConvertTo-Json -Depth 5), [Text.UTF8Encoding]::new($false))
    $parsedHerdr = Assert-V05HerdrRuntimeReport -ReportPath $herdrPath
    Assert-Condition -Condition ($null -ne $parsedHerdr -and [bool]$parsedHerdr.RuntimeObserved -and [bool]$parsedHerdr.SnapshotObserved -and [bool]$parsedHerdr.EventObserved -and [bool]$parsedHerdr.ReconnectObserved -and -not [bool]$parsedHerdr.SessionControlInvoked) -Message 'Assert-V05HerdrRuntimeReport parses valid Herdr runtime report'

    # Herdr: RuntimeObserved = false
    $badRuntimeHerdr = [ordered]@{
        EvidenceClassification = 'Runtime'
        RuntimeObserved = $false
        SnapshotObserved = $true
        EventObserved = $true
        ReconnectObserved = $true
        SessionControlInvoked = $false
    }
    [IO.File]::WriteAllText($herdrPath, ($badRuntimeHerdr | ConvertTo-Json -Depth 5), [Text.UTF8Encoding]::new($false))
    Assert-ThrowsPrefix `
        -ScriptBlock { Assert-V05HerdrRuntimeReport -ReportPath $herdrPath } `
        -ExpectedPrefix "JSON property 'RuntimeObserved' is False (expected True)" `
        -Message 'Assert-V05HerdrRuntimeReport rejects RuntimeObserved = false'

    # Herdr: SnapshotObserved = false
    $badSnapshotHerdr = [ordered]@{
        EvidenceClassification = 'Runtime'
        RuntimeObserved = $true
        SnapshotObserved = $false
        EventObserved = $true
        ReconnectObserved = $true
        SessionControlInvoked = $false
    }
    [IO.File]::WriteAllText($herdrPath, ($badSnapshotHerdr | ConvertTo-Json -Depth 5), [Text.UTF8Encoding]::new($false))
    Assert-ThrowsPrefix `
        -ScriptBlock { Assert-V05HerdrRuntimeReport -ReportPath $herdrPath } `
        -ExpectedPrefix "JSON property 'SnapshotObserved' is False (expected True)" `
        -Message 'Assert-V05HerdrRuntimeReport rejects SnapshotObserved = false'

    # Herdr: EventObserved = false
    $badEventHerdr = [ordered]@{
        EvidenceClassification = 'Runtime'
        RuntimeObserved = $true
        SnapshotObserved = $true
        EventObserved = $false
        ReconnectObserved = $true
        SessionControlInvoked = $false
    }
    [IO.File]::WriteAllText($herdrPath, ($badEventHerdr | ConvertTo-Json -Depth 5), [Text.UTF8Encoding]::new($false))
    Assert-ThrowsPrefix `
        -ScriptBlock { Assert-V05HerdrRuntimeReport -ReportPath $herdrPath } `
        -ExpectedPrefix "JSON property 'EventObserved' is False (expected True)" `
        -Message 'Assert-V05HerdrRuntimeReport rejects EventObserved = false'

    # Herdr: EventObserved = 'true' (string)
    $badEventStrHerdr = [ordered]@{
        EvidenceClassification = 'Runtime'
        RuntimeObserved = $true
        SnapshotObserved = $true
        EventObserved = 'true'
        ReconnectObserved = $true
        SessionControlInvoked = $false
    }
    [IO.File]::WriteAllText($herdrPath, ($badEventStrHerdr | ConvertTo-Json -Depth 5), [Text.UTF8Encoding]::new($false))
    Assert-ThrowsPrefix `
        -ScriptBlock { Assert-V05HerdrRuntimeReport -ReportPath $herdrPath } `
        -ExpectedPrefix "JSON property 'EventObserved' must be a CLR Boolean" `
        -Message 'Assert-V05HerdrRuntimeReport rejects string EventObserved'

    # Herdr: EventObserved = 1 (number)
    $badEventNumHerdr = [ordered]@{
        EvidenceClassification = 'Runtime'
        RuntimeObserved = $true
        SnapshotObserved = $true
        EventObserved = 1
        ReconnectObserved = $true
        SessionControlInvoked = $false
    }
    [IO.File]::WriteAllText($herdrPath, ($badEventNumHerdr | ConvertTo-Json -Depth 5), [Text.UTF8Encoding]::new($false))
    Assert-ThrowsPrefix `
        -ScriptBlock { Assert-V05HerdrRuntimeReport -ReportPath $herdrPath } `
        -ExpectedPrefix "JSON property 'EventObserved' must be a CLR Boolean" `
        -Message 'Assert-V05HerdrRuntimeReport rejects numeric EventObserved'

    # Herdr: Missing EventObserved
    $noEventHerdr = [ordered]@{
        EvidenceClassification = 'Runtime'
        RuntimeObserved = $true
        SnapshotObserved = $true
        ReconnectObserved = $true
        SessionControlInvoked = $false
    }
    [IO.File]::WriteAllText($herdrPath, ($noEventHerdr | ConvertTo-Json -Depth 5), [Text.UTF8Encoding]::new($false))
    Assert-ThrowsPrefix `
        -ScriptBlock { Assert-V05HerdrRuntimeReport -ReportPath $herdrPath } `
        -ExpectedPrefix "JSON object is missing required boolean property 'EventObserved'" `
        -Message 'Assert-V05HerdrRuntimeReport rejects missing EventObserved'

    # Herdr: ReconnectObserved = false
    $badReconnectHerdr = [ordered]@{
        EvidenceClassification = 'Runtime'
        RuntimeObserved = $true
        SnapshotObserved = $true
        EventObserved = $true
        ReconnectObserved = $false
        SessionControlInvoked = $false
    }
    [IO.File]::WriteAllText($herdrPath, ($badReconnectHerdr | ConvertTo-Json -Depth 5), [Text.UTF8Encoding]::new($false))
    Assert-ThrowsPrefix `
        -ScriptBlock { Assert-V05HerdrRuntimeReport -ReportPath $herdrPath } `
        -ExpectedPrefix "JSON property 'ReconnectObserved' is False (expected True)" `
        -Message 'Assert-V05HerdrRuntimeReport rejects ReconnectObserved = false'

    # Herdr: ReconnectObserved = 'true' (string)
    $badReconnectStrHerdr = [ordered]@{
        EvidenceClassification = 'Runtime'
        RuntimeObserved = $true
        SnapshotObserved = $true
        EventObserved = $true
        ReconnectObserved = 'true'
        SessionControlInvoked = $false
    }
    [IO.File]::WriteAllText($herdrPath, ($badReconnectStrHerdr | ConvertTo-Json -Depth 5), [Text.UTF8Encoding]::new($false))
    Assert-ThrowsPrefix `
        -ScriptBlock { Assert-V05HerdrRuntimeReport -ReportPath $herdrPath } `
        -ExpectedPrefix "JSON property 'ReconnectObserved' must be a CLR Boolean" `
        -Message 'Assert-V05HerdrRuntimeReport rejects string ReconnectObserved'

    # Herdr: ReconnectObserved = 1 (number)
    $badReconnectNumHerdr = [ordered]@{
        EvidenceClassification = 'Runtime'
        RuntimeObserved = $true
        SnapshotObserved = $true
        EventObserved = $true
        ReconnectObserved = 1
        SessionControlInvoked = $false
    }
    [IO.File]::WriteAllText($herdrPath, ($badReconnectNumHerdr | ConvertTo-Json -Depth 5), [Text.UTF8Encoding]::new($false))
    Assert-ThrowsPrefix `
        -ScriptBlock { Assert-V05HerdrRuntimeReport -ReportPath $herdrPath } `
        -ExpectedPrefix "JSON property 'ReconnectObserved' must be a CLR Boolean" `
        -Message 'Assert-V05HerdrRuntimeReport rejects numeric ReconnectObserved'

    # Herdr: Missing ReconnectObserved
    $noReconnectHerdr = [ordered]@{
        EvidenceClassification = 'Runtime'
        RuntimeObserved = $true
        SnapshotObserved = $true
        EventObserved = $true
        SessionControlInvoked = $false
    }
    [IO.File]::WriteAllText($herdrPath, ($noReconnectHerdr | ConvertTo-Json -Depth 5), [Text.UTF8Encoding]::new($false))
    Assert-ThrowsPrefix `
        -ScriptBlock { Assert-V05HerdrRuntimeReport -ReportPath $herdrPath } `
        -ExpectedPrefix "JSON object is missing required boolean property 'ReconnectObserved'" `
        -Message 'Assert-V05HerdrRuntimeReport rejects missing ReconnectObserved'

    # Herdr: SessionControlInvoked = true
    $badSessionHerdr = [ordered]@{
        EvidenceClassification = 'Runtime'
        RuntimeObserved = $true
        SnapshotObserved = $true
        EventObserved = $true
        ReconnectObserved = $true
        SessionControlInvoked = $true
    }
    [IO.File]::WriteAllText($herdrPath, ($badSessionHerdr | ConvertTo-Json -Depth 5), [Text.UTF8Encoding]::new($false))
    Assert-ThrowsPrefix `
        -ScriptBlock { Assert-V05HerdrRuntimeReport -ReportPath $herdrPath } `
        -ExpectedPrefix "JSON property 'SessionControlInvoked' is True (expected False)" `
        -Message 'Assert-V05HerdrRuntimeReport rejects SessionControlInvoked = true'

    # Herdr: SessionControlInvoked = 'false' (string)
    $badSessionStrHerdr = [ordered]@{
        EvidenceClassification = 'Runtime'
        RuntimeObserved = $true
        SnapshotObserved = $true
        EventObserved = $true
        ReconnectObserved = $true
        SessionControlInvoked = 'false'
    }
    [IO.File]::WriteAllText($herdrPath, ($badSessionStrHerdr | ConvertTo-Json -Depth 5), [Text.UTF8Encoding]::new($false))
    Assert-ThrowsPrefix `
        -ScriptBlock { Assert-V05HerdrRuntimeReport -ReportPath $herdrPath } `
        -ExpectedPrefix "JSON property 'SessionControlInvoked' must be a CLR Boolean" `
        -Message 'Assert-V05HerdrRuntimeReport rejects string SessionControlInvoked'

    # 15. Wrapper script PS5.1 compatibility and runtime scalar emission verification
    Assert-Condition -Condition ($wrapperText -notmatch 'ConvertFrom-Json\s+-Depth') -Message 'Wrapper script does not contain PS7-only ConvertFrom-Json -Depth'
    Assert-Condition -Condition ($wrapperText -match 'Assert-V05CompositeRuntimeReport') -Message 'Wrapper script calls Assert-V05CompositeRuntimeReport'
    Assert-Condition -Condition ($wrapperText -match 'Assert-V05HerdrRuntimeReport') -Message 'Wrapper script calls Assert-V05HerdrRuntimeReport'

    # Verify gate report contains all 5 required scalar lines exactly once
    $scalarNames = @(
        'RuntimeObserved: true',
        'SnapshotObserved: true',
        'EventObserved: true',
        'ReconnectObserved: true',
        'SessionControlInvoked: false'
    )
    foreach ($scalar in $scalarNames) {
        $escapedScalar = [Regex]::Escape($scalar)
        $scalarMatches = [Regex]::Matches($wrapperText, "'$escapedScalar'")
        Assert-Condition -Condition ($scalarMatches.Count -eq 1) -Message "Wrapper gate report defines exactly one '$scalar' line"
    }
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
