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

$herdrRuntime = Join-Path $repositoryRoot 'tools\Test-V02HerdrRuntime.ps1'
$compositeRuntime = Join-Path $repositoryRoot 'tools\Test-V02LiveRuntimeAcceptance.ps1'
$runtimeMonitorContract = Join-Path $repositoryRoot 'docs\protocol\v0.2-runtime-monitor-contract.md'
$runtimePackageBinding = Join-Path $repositoryRoot 'tools\lib\V02RuntimePackageBinding.ps1'
$runtimePackageBindingTests = Join-Path $repositoryRoot 'tools\lib\V02RuntimePackageBinding.Tests.ps1'

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

foreach ($path in @($runtimePackageBinding,$runtimePackageBindingTests)) {
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

if ($failures.Count -gt 0) {
    Write-Host ''
    Write-Host "$($failures.Count) assertion(s) failed:" -ForegroundColor Red
    $failures | ForEach-Object { Write-Host "  - $_" -ForegroundColor Red }
    exit 1
}

Write-Host ''
Write-Host 'All v0.2 exact source binding static assertions passed.' -ForegroundColor Green
