<#
Build-free static/parser selftests for the v0.3 actual-Herdr runtime wrappers for
Issues #13, #15, and #16 and their shared provenance library. This script never
starts Herdr, invokes session control, runs dotnet, or executes a runtime capture.
It is intentionally compatible with Windows PowerShell 5.1 and PowerShell 7.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repositoryRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')).Path
$failures = New-Object 'System.Collections.Generic.List[string]'

function Assert-True {
    param(
        [Parameter(Mandatory = $true)][bool]$Condition,
        [Parameter(Mandatory = $true)][string]$Message
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
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Text,
        [Parameter(Mandatory = $true)][string]$Description
    )

    $content = [IO.File]::ReadAllText($Path)
    Assert-True -Condition ($content.Contains($Text)) -Message $Description
}

function Assert-Parseable {
    param(
        [Parameter(Mandatory = $true)][string]$Path
    )

    $tokens = $null
    $errors = $null
    [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$errors) | Out-Null
    Assert-True -Condition ($errors.Count -eq 0) -Message "$(Split-Path -Leaf $Path) parses without PowerShell syntax errors"
}

$wrapperPaths = @(
    (Join-Path $PSScriptRoot 'Invoke-V03Issue13RealtimeActivityRuntimeAcceptance.ps1'),
    (Join-Path $PSScriptRoot 'Invoke-V03Issue15FileGitActivityRuntimeAcceptance.ps1'),
    (Join-Path $PSScriptRoot 'Invoke-V03Issue16NotificationRuntimeAcceptance.ps1')
)
$libraryPath = Join-Path $PSScriptRoot 'lib/V03RuntimeCaptureProvenance.ps1'
$readmePath = Join-Path $PSScriptRoot 'README.md'

foreach ($path in $wrapperPaths + @($libraryPath)) {
    Assert-Parseable -Path $path
}

foreach ($path in $wrapperPaths) {
    $name = Split-Path -Leaf $path
    Assert-SourceContains -Path $path -Text '[Parameter(Mandatory = $true)]' -Description "$name declares mandatory provenance parameters"
    Assert-SourceContains -Path $path -Text '[string]$ExpectedSourceCommit' -Description "$name requires ExpectedSourceCommit"
    Assert-SourceContains -Path $path -Text '[string]$ExpectedSourceTree' -Description "$name requires ExpectedSourceTree"
    Assert-SourceContains -Path $path -Text 'Get-ExpectedCleanSourceIdentity' -Description "$name validates expected source identity"
    Assert-SourceContains -Path $path -Text 'PreRunSourceCommit' -Description "$name reports the pre-run source commit"
    Assert-SourceContains -Path $path -Text 'PreRunSourceTree' -Description "$name reports the pre-run source tree"
    Assert-SourceContains -Path $path -Text 'PostRunSourceCommit' -Description "$name reports the post-run source commit"
    Assert-SourceContains -Path $path -Text 'PostRunSourceTree' -Description "$name reports the post-run source tree"
    Assert-SourceContains -Path $path -Text 'Get-RuntimeArtifactRunIdentity' -Description "$name validates one artifact run identity"
    Assert-SourceContains -Path $path -Text 'RunId' -Description "$name binds the report to its artifact run id"
    Assert-SourceContains -Path $path -Text 'ReportSha256' -Description "$name records the raw runtime report hash"
    Assert-SourceContains -Path $path -Text 'GateReportSha256' -Description "$name emits the gate report hash"
    Assert-SourceContains -Path $path -Text 'EvidenceChanged:' -Description "$name rejects a runtime report that changes during validation"
    Assert-SourceContains -Path $path -Text 'Write-RuntimeCaptureFailureReport' -Description "$name preserves the NoRuntimeCredit failure path"
    Assert-SourceContains -Path $path -Text 'SessionControlInvoked: false' -Description "$name keeps session control explicitly false in PASS evidence"
}

Assert-SourceContains -Path $libraryPath -Text "rev-parse --verify 'HEAD^{commit}'" -Description 'Provenance library resolves the exact clean HEAD commit'
Assert-SourceContains -Path $libraryPath -Text "rev-parse --verify 'HEAD^{tree}'" -Description 'Provenance library resolves the exact clean HEAD tree'
Assert-SourceContains -Path $libraryPath -Text 'status --porcelain=v1 --untracked-files=all' -Description 'Provenance library enforces a clean working tree'
Assert-SourceContains -Path $libraryPath -Text 'function Get-ExpectedCleanSourceIdentity' -Description 'Provenance library exposes expected commit/tree binding'
Assert-SourceContains -Path $libraryPath -Text 'function Get-RuntimeArtifactRunIdentity' -Description 'Provenance library exposes artifact run binding'
Assert-SourceContains -Path $libraryPath -Text 'EvidenceClass: NoRuntimeCredit' -Description 'Provenance library retains NoRuntimeCredit on failures'
Assert-SourceContains -Path $libraryPath -Text 'ReportSha256' -Description 'Failure reports retain raw report hash provenance'

foreach ($scriptName in @(
        'Invoke-V03Issue13RealtimeActivityRuntimeAcceptance.ps1',
        'Invoke-V03Issue15FileGitActivityRuntimeAcceptance.ps1',
        'Invoke-V03Issue16NotificationRuntimeAcceptance.ps1')) {
    Assert-SourceContains -Path $readmePath -Text $scriptName -Description "tools README documents $scriptName"
}
Assert-SourceContains -Path $readmePath -Text '-ExpectedSourceCommit $expectedSourceCommit' -Description 'tools README documents exact source commit input'
Assert-SourceContains -Path $readmePath -Text '-ExpectedSourceTree $expectedSourceTree' -Description 'tools README documents exact source tree input'

if ($failures.Count -gt 0) {
    Write-Host ''
    Write-Host "$($failures.Count) assertion(s) failed under PowerShell $($PSVersionTable.PSVersion):" -ForegroundColor Red
    $failures | ForEach-Object { Write-Host "  - $_" -ForegroundColor Red }
    exit 1
}

$global:LASTEXITCODE = 0
Write-Host ''
Write-Host "All v0.3 exact-source runtime wrapper static selftests passed under PowerShell $($PSVersionTable.PSVersion)." -ForegroundColor Green
exit 0
