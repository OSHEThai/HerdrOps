<#
.SYNOPSIS
    Build-free static regression for v0.2 exact source provenance (#7 #9 #10).

    This test parses and inspects the two runtime gate scripts only. It never
    invokes Herdr, a session command, a runtime process, dotnet, or a build.
#>

[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repositoryRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')).Path
$failures = New-Object 'System.Collections.Generic.List[string]'

function Assert-TestTrue {
    param(
        [Parameter(Mandatory)][bool]$Condition,
        [Parameter(Mandatory)][string]$Message
    )

    if (-not $Condition) {
        $failures.Add($Message)
        Write-Host "FAIL: $Message" -ForegroundColor Red
    }
    else {
        Write-Host "PASS: $Message"
    }
}

function Assert-SourceContains {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Text,
        [Parameter(Mandatory)][string]$Description
    )

    $source = Get-Content -LiteralPath $Path -Raw
    Assert-TestTrue -Condition $source.Contains($Text) -Message $Description
}

function Assert-ParserClean {
    param([Parameter(Mandatory)][string]$Path)

    $tokens = $null
    $parseErrors = $null
    [System.Management.Automation.Language.Parser]::ParseFile(
        $Path,
        [ref]$tokens,
        [ref]$parseErrors) | Out-Null
    Assert-TestTrue `
        -Condition (@($parseErrors).Count -eq 0) `
        -Message "PowerShell parser accepts $([IO.Path]::GetFileName($Path))"
}

function Assert-DocumentedCompositeInvocationContains {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string[]]$RequiredArguments
    )

    $source = Get-Content -LiteralPath $Path -Raw
    $command = './tools/Test-V02LiveRuntimeAcceptance.ps1'
    $commandIndex = $source.IndexOf($command, [StringComparison]::Ordinal)
    Assert-TestTrue `
        -Condition ($commandIndex -ge 0) `
        -Message "$([IO.Path]::GetFileName($Path)) documents the composite runtime command"
    if ($commandIndex -lt 0) {
        return
    }

    $invocationEnd = $source.IndexOf("`r`n`r`n", $commandIndex, [StringComparison]::Ordinal)
    if ($invocationEnd -lt 0) {
        $invocationEnd = $source.IndexOf("`n`n", $commandIndex, [StringComparison]::Ordinal)
    }
    Assert-TestTrue `
        -Condition ($invocationEnd -gt $commandIndex) `
        -Message "$([IO.Path]::GetFileName($Path)) delimits the composite runtime invocation"
    if ($invocationEnd -le $commandIndex) {
        return
    }

    $invocation = $source.Substring($commandIndex, $invocationEnd - $commandIndex)
    foreach ($argument in $RequiredArguments) {
        Assert-TestTrue `
            -Condition $invocation.Contains($argument) `
            -Message "$([IO.Path]::GetFileName($Path)) composite invocation supplies $argument"
    }
}

$herdrRuntime = Join-Path $repositoryRoot 'tools\Test-V02HerdrRuntime.ps1'
$compositeRuntime = Join-Path $repositoryRoot 'tools\Test-V02LiveRuntimeAcceptance.ps1'
$toolsReadme = Join-Path $repositoryRoot 'tools\README.md'
$runtimeMonitorContract = Join-Path $repositoryRoot 'docs\protocol\v0.2-runtime-monitor-contract.md'
$runtimePackageBinding = Join-Path $repositoryRoot 'tools\lib\V02RuntimePackageBinding.ps1'
$runtimePackageBindingTests = Join-Path $repositoryRoot 'tools\lib\V02RuntimePackageBinding.Tests.ps1'
$runtimeSemanticBinding = Join-Path $repositoryRoot 'tools\lib\V02RuntimeSemanticBinding.ps1'
$runtimeSemanticBindingTests = Join-Path $repositoryRoot 'tools\lib\V02RuntimeSemanticBinding.Tests.ps1'

foreach ($path in @($herdrRuntime, $compositeRuntime)) {
    Assert-ParserClean -Path $path
    Assert-SourceContains -Path $path -Text '[string]$ExpectedSourceCommit' -Description "$(Split-Path -Leaf $path) requires ExpectedSourceCommit"
    Assert-SourceContains -Path $path -Text '[string]$ExpectedSourceTree' -Description "$(Split-Path -Leaf $path) requires ExpectedSourceTree"
    Assert-SourceContains -Path $path -Text "rev-parse 'HEAD^{tree}'" -Description "$(Split-Path -Leaf $path) resolves HEAD tree"
    Assert-SourceContains -Path $path -Text 'status --porcelain=v1 --untracked-files=all' -Description "$(Split-Path -Leaf $path) rejects dirty source state"
    Assert-SourceContains -Path $path -Text 'PreRunSourceCommit' -Description "$(Split-Path -Leaf $path) reports pre-run source commit"
    Assert-SourceContains -Path $path -Text 'PreRunSourceTree' -Description "$(Split-Path -Leaf $path) reports pre-run source tree"
    Assert-SourceContains -Path $path -Text 'PostRunSourceCommit' -Description "$(Split-Path -Leaf $path) reports post-run source commit"
    Assert-SourceContains -Path $path -Text 'PostRunSourceTree' -Description "$(Split-Path -Leaf $path) reports post-run source tree"
}

foreach ($path in @($runtimePackageBinding,$runtimePackageBindingTests,$runtimeSemanticBinding,$runtimeSemanticBindingTests)) {
    Assert-ParserClean -Path $path
}
Assert-SourceContains -Path $compositeRuntime -Text '[string]$PackageIdentityPath' -Description 'Composite gate requires the package identity receipt'
Assert-SourceContains -Path $compositeRuntime -Text '[string]$PackageArchivePath' -Description 'Composite gate requires the package ZIP archive'
Assert-SourceContains -Path $compositeRuntime -Text '[string]$ExtractedPackageRoot' -Description 'Composite gate requires the exact extracted package root'
Assert-SourceContains -Path $compositeRuntime -Text '[string]$TargetAgentSessionReference' -Description 'Composite gate records the operator-attested native Agent/session reference'
Assert-SourceContains -Path $compositeRuntime -Text 'Resolve-V02RuntimePackageBinding' -Description 'Composite gate invokes the exact package binding validator before launch'
Assert-SourceContains -Path $compositeRuntime -Text '$coreExecutable = $packageBinding.CorePath' -Description 'Composite gate launches Core from the validated package root'
Assert-SourceContains -Path $compositeRuntime -Text '$appExecutable = $packageBinding.AppPath' -Description 'Composite gate launches App from the validated package root'
Assert-SourceContains -Path $compositeRuntime -Text 'Save-V02FreshTrxEvidence' -Description 'Composite gate preserves four fresh TRX files in runtime evidence'
Assert-SourceContains -Path $compositeRuntime -Text 'PackageIdentityReceiptSha256:' -Description 'Composite gate exposes the exact package receipt field required by the bilingual matrix'
Assert-SourceContains -Path $compositeRuntime -Text 'AppSha256:' -Description 'Composite gate exposes the validated package App hash for cross-run binding'
Assert-SourceContains -Path $compositeRuntime -Text 'CoreSha256:' -Description 'Composite gate exposes the validated package Core hash for cross-run binding'
Assert-SourceContains -Path $runtimePackageBinding -Text "'tools\packaging\v0.2\Test-V02PackageIdentity.ps1'" -Description 'Runtime binding calls the committed v0.2 package validator'
Assert-SourceContains -Path $runtimePackageBinding -Text "EvidenceSource = 'OperatorAttestation'" -Description 'Unobservable native Agent/session identity has an explicit attestation boundary'
Assert-SourceContains -Path $runtimePackageBinding -Text 'Invoke-V02CommittedPackageValidator -ValidatorPath $Binding.ValidatorPath' -Description 'Finalization re-runs the entire committed package validator'
Assert-SourceContains -Path $runtimePackageBinding -Text 'New-Variable -Scope Script -Name V02GovernedPassingTestCount -Value 888 -Option Constant' -Description 'TRX preservation declares the governed exact current 888-test aggregate as a constant'
Assert-SourceContains -Path $runtimePackageBinding -Text 'V02GovernedTestAssemblyFileNames' -Description 'TRX preservation binds the exact four governed test assembly filenames'
Assert-SourceContains -Path $runtimePackageBinding -Text 'EvidenceFileName=([IO.Path]::ChangeExtension($canonicalAssembly[0],''.trx''))' -Description 'TRX preservation assigns one canonical evidence filename per governed project'
Assert-SourceContains -Path $runtimePackageBinding -Text '$total -ne $script:V02GovernedPassingTestCount' -Description 'TRX preservation checks total against the governed test count'
Assert-SourceContains -Path $runtimePackageBinding -Text '$passed -ne $script:V02GovernedPassingTestCount' -Description 'TRX preservation checks passing tests against the governed test count'
Assert-SourceContains -Path $runtimePackageBinding -Text '$notExecuted -ne 0 -or $skipped -ne 0' -Description 'TRX preservation explicitly rejects skipped and notExecuted counters'
Assert-SourceContains -Path $runtimePackageBinding -Text '$current.Sha256 -cne $preselected.Sha256' -Description 'TRX preservation binds a strong preselection content hash'
Assert-SourceContains -Path $runtimePackageBinding -Text '$runStart.UtcDateTime -lt $invocationStartedUtc' -Description 'TRX preservation enforces the lower TestRun invocation bound'
Assert-SourceContains -Path $runtimePackageBinding -Text '$runFinish.UtcDateTime -gt $selectionUpperBoundUtc' -Description 'TRX preservation enforces the upper TestRun invocation bound'
Assert-SourceContains -Path $runtimePackageBinding -Text "'.test-results.' + [guid]::NewGuid().ToString('N') + '.staging'" -Description 'TRX preservation stages evidence before atomic publication'
Assert-SourceContains -Path $runtimePackageBinding -Text 'New-Item -ItemType Directory -Path $target -ErrorAction Stop' -Description 'TRX publication reserves an exclusive transaction-owned destination'
Assert-SourceContains -Path $runtimePackageBinding -Text '[IO.File]::Move($sourcePath,$publishedPath)' -Description 'TRX publication atomically moves each held evidence file'
Assert-SourceContains -Path $runtimePackageBinding -Text '([IO.FileShare]::Read -bor [IO.FileShare]::Delete)' -Description 'TRX preservation holds final evidence against writes while permitting atomic directory publication'
Assert-SourceContains -Path $runtimePackageBinding -Text 'Remove-Item -LiteralPath $staging -Recurse -Force' -Description 'TRX preservation rolls staging back on any invalid evidence'
Assert-SourceContains -Path $runtimePackageBinding -Text '$publishedByTransaction -and (Test-Path -LiteralPath $target)' -Description 'TRX rollback deletes a published target only after this transaction owns it'
Assert-SourceContains -Path $runtimePackageBindingTests -Text '$script:V02GovernedPassingTestCount-ne 888' -Description 'Runtime binding tests fail visibly when the governed count drifts'
Assert-SourceContains -Path $runtimePackageBindingTests -Text "'stale 885-test aggregate fails closed and rolls back'" -Description 'Runtime binding tests reject and roll back the superseded 885-test aggregate'
Assert-SourceContains -Path $runtimePackageBindingTests -Text "'inconsistent total=passed=888 but notExecuted=1 reaches exact skipped guard'" -Description 'Runtime binding tests reach the explicit notExecuted guard'
Assert-SourceContains -Path $runtimePackageBindingTests -Text "'same-length post-selection mutation with restored mtime fails exact hash/run guard'" -Description 'Runtime binding tests cover same-length restored-mtime mutation'
Assert-SourceContains -Path $runtimePackageBindingTests -Text "'touched old 888 TRX set fails exact run-window guard'" -Description 'Runtime binding tests reject touched old test runs'
Assert-SourceContains -Path $runtimePackageBindingTests -Text "'future-dated TRX fails exact file-window guard'" -Description 'Runtime binding tests reject future-dated TRX files'
Assert-SourceContains -Path $runtimePackageBindingTests -Text "'final staged copy mutation fails exact guard and rolls back'" -Description 'Runtime binding tests cover final-copy mutation and rollback'
Assert-SourceContains -Path $runtimePackageBindingTests -Text "'receipt mutation fails exact guard and rolls back'" -Description 'Runtime binding tests cover receipt mutation and rollback'
Assert-SourceContains -Path $runtimePackageBindingTests -Text "'held handles block TRX and receipt writes through atomic publication'" -Description 'Runtime binding tests cover the post-check pre-publish TOCTOU gap'
Assert-SourceContains -Path $runtimePackageBindingTests -Text "'delete-replace during publish is detected and owned target rolls back'" -Description 'Runtime binding tests cover delete-replace across publication'
Assert-SourceContains -Path $runtimePackageBindingTests -Text "'destination collision preserves unowned target and rolls back only staging'" -Description 'Runtime binding tests preserve an unowned concurrent destination'
Assert-SourceContains -Path $runtimePackageBinding -Text '[IO.FileShare]::Read' -Description 'TRX selection uses a held source stream that denies write/delete sharing'
Assert-SourceContains -Path $compositeRuntime -Text 'Assert-V02RuntimeSemanticStateCaptures' -Description 'Composite gate independently cross-checks SemanticStateCaptures before source-identity finalization'

Assert-SourceContains `
    -Path $herdrRuntime `
    -Text 'RuntimeTraceSha256' `
    -Description 'Issue #7 gate reports the raw runtime trace SHA-256'
Assert-SourceContains `
    -Path $herdrRuntime `
    -Text 'runtimeTraceSha256AtRead' `
    -Description 'Issue #7 gate detects raw trace mutation during validation'
Assert-SourceContains `
    -Path $compositeRuntime `
    -Text 'EvidenceClass: NoRuntimeCredit' `
    -Description 'Composite failure path preserves NoRuntimeCredit'
Assert-SourceContains `
    -Path $compositeRuntime `
    -Text 'Assert-V02ReferenceHostProfile' `
    -Description 'Composite gate independently validates the canonical reference-host profile'
Assert-SourceContains `
    -Path $compositeRuntime `
    -Text 'Get-V02TrustedReferenceHostObservation' `
    -Description 'Composite gate probes trusted host/OS/GPU/display/Herdr identity'
Assert-SourceContains `
    -Path (Join-Path $repositoryRoot 'tools\lib\V02ReferenceHostProfile.ps1') `
    -Text '$primaryScreen.Bounds.Width' `
    -Description 'Trusted display probe independently reads live logical Screen bounds'
Assert-SourceContains `
    -Path $compositeRuntime `
    -Text '$appReport.Language -is [string]' `
    -Description 'Composite gate binds one report to the exact requested language'
Assert-SourceContains `
    -Path $compositeRuntime `
    -Text '$appReport.LanguageStableThroughFinish -is [bool]' `
    -Description 'Composite gate requires native true language stability through finish'
Assert-SourceContains `
    -Path $compositeRuntime `
    -Text '[int64]$appReport.LanguageChangeCount -eq 0' `
    -Description 'Composite gate rejects any observed language change'
Assert-SourceContains `
    -Path $compositeRuntime `
    -Text '$capture.LanguageCultureName -is [string]' `
    -Description 'Composite gate binds every capture to the requested language culture'
Assert-SourceContains `
    -Path $compositeRuntime `
    -Text 'Assert-V02RendererEvidence' `
    -Description 'Composite gate independently validates SoftwareOnly lifetime evidence'
Assert-SourceContains `
    -Path $compositeRuntime `
    -Text 'Assert-V02WorkingSetBudgetEvidence' `
    -Description 'Composite gate independently recomputes the v0.2 working-set result'
Assert-SourceContains `
    -Path $compositeRuntime `
    -Text "'--reference-host-profile-sha256', `$referenceHostProfile.Sha256" `
    -Description 'Composite gate passes the independently computed profile hash to the producer'
Assert-SourceContains `
    -Path $runtimeMonitorContract `
    -Text '-ExpectedSourceTree $expectedSourceTree' `
    -Description 'Runtime contract command supplies the exact expected source tree'

$requiredCompositeDocumentationArguments = @(
    '-PackageIdentityPath $packageIdentityPath',
    '-PackageArchivePath $packageArchivePath',
    '-ExtractedPackageRoot $extractedPackageRoot',
    '-TargetAgentSessionReference $targetAgentSessionReference'
)
foreach ($document in @($toolsReadme, $runtimeMonitorContract)) {
    Assert-DocumentedCompositeInvocationContains `
        -Path $document `
        -RequiredArguments $requiredCompositeDocumentationArguments
}

if ($failures.Count -gt 0) {
    Write-Host ''
    Write-Host "$($failures.Count) assertion(s) failed:" -ForegroundColor Red
    $failures | ForEach-Object { Write-Host "  - $_" -ForegroundColor Red }
    exit 1
}

Write-Host ''
Write-Host 'All v0.2 exact source binding static assertions passed.' -ForegroundColor Green
