#requires -Version 5.1

Set-StrictMode -Version Latest

function Assert-V02RuntimeBindingSha256 {
    param([Parameter(Mandatory = $true)][string]$Value, [Parameter(Mandatory = $true)][string]$Name)
    if ($Value -cnotmatch '^[0-9A-F]{64}$') { throw "$Name must be an uppercase SHA-256 value." }
}

function Assert-V02RuntimePackageValidationResult {
    param(
        [Parameter(Mandatory = $true)]$Result,
        [Parameter(Mandatory = $true)][string]$ExpectedSourceCommit,
        [Parameter(Mandatory = $true)][string]$ExpectedSourceTree
    )

    $required = @('EvidenceClass','Issue','ProfileId','ReceiptSha256','SourceCommit','SourceTree',
        'PreparationProfileFileSha256','PreparationProfileCanonicalSha256','ArchiveSha256','AppSha256',
        'CoreSha256','ReferenceHostProfileSha256','RendererPolicySha256','Runtime','Release')
    $actual = @($Result.PSObject.Properties.Name)
    if (@($actual | Where-Object { $_ -notin $required }).Count -ne 0 -or
        @($required | Where-Object { $_ -notin $actual }).Count -ne 0) {
        throw 'Package validator returned an unexpected result shape.'
    }
    if ([string]$Result.EvidenceClass -cne 'Static/PackagedCompatibilityPreparation' -or
        $Result.Issue -isnot [int] -or [int]$Result.Issue -ne 149 -or
        [string]::IsNullOrWhiteSpace([string]$Result.ProfileId) -or
        [string]$Result.Runtime -cne 'NOT OBSERVED' -or
        [string]$Result.Release -cne 'NOT CLAIMED') {
        throw 'Package validator returned an invalid evidence boundary.'
    }
    foreach ($name in @($required | Where-Object { $_ -notin @('Issue') })) {
        if ($Result.$name -isnot [string]) { throw "Package validator result $name must be a native string." }
    }
    if ([string]$Result.SourceCommit -cne $ExpectedSourceCommit.ToLowerInvariant() -or
        [string]$Result.SourceTree -cne $ExpectedSourceTree.ToLowerInvariant()) {
        throw 'Validated package source does not match the exact runtime candidate commit/tree.'
    }
    foreach ($name in @('ReceiptSha256','PreparationProfileFileSha256','PreparationProfileCanonicalSha256',
        'ArchiveSha256','AppSha256','CoreSha256','ReferenceHostProfileSha256','RendererPolicySha256')) {
        Assert-V02RuntimeBindingSha256 -Value ([string]$Result.$name) -Name "package validation $name"
    }
}

function Resolve-V02RuntimePackageBinding {
    param(
        [Parameter(Mandatory = $true)][string]$IdentityPath,
        [Parameter(Mandatory = $true)][string]$ArchivePath,
        [Parameter(Mandatory = $true)][string]$PackageRoot,
        [Parameter(Mandatory = $true)][string]$RepositoryRoot,
        [Parameter(Mandatory = $true)][string]$ProfilePath,
        [Parameter(Mandatory = $true)][string]$ExpectedSourceCommit,
        [Parameter(Mandatory = $true)][string]$ExpectedSourceTree
    )

    foreach ($item in @(
        @{ Path=$IdentityPath; Type='Leaf'; Name='package identity receipt' },
        @{ Path=$ArchivePath; Type='Leaf'; Name='package ZIP archive' },
        @{ Path=$PackageRoot; Type='Container'; Name='extracted package root' },
        @{ Path=$ProfilePath; Type='Leaf'; Name='package identity profile' }
    )) {
        if (-not (Test-Path -LiteralPath $item.Path -PathType $item.Type)) {
            throw "Missing $($item.Name): $($item.Path)"
        }
    }

    $validatorPath = Join-Path $RepositoryRoot 'tools\packaging\v0.2\Test-V02PackageIdentity.ps1'
    if (-not (Test-Path -LiteralPath $validatorPath -PathType Leaf)) {
        throw "Committed package validator is missing: $validatorPath"
    }
    $validatorOutput = @(& $validatorPath -IdentityPath $IdentityPath -ArchivePath $ArchivePath `
        -PackageRoot $PackageRoot -RepositoryRoot $RepositoryRoot -ProfilePath $ProfilePath)
    if ($validatorOutput.Count -ne 1) { throw 'Package validator must return exactly one validation result.' }
    $validated = $validatorOutput[0]
    Assert-V02RuntimePackageValidationResult -Result $validated `
        -ExpectedSourceCommit $ExpectedSourceCommit -ExpectedSourceTree $ExpectedSourceTree

    $profile = Get-Content -LiteralPath $ProfilePath -Raw | ConvertFrom-Json
    $root = (Resolve-Path -LiteralPath $PackageRoot).Path
    $appPath = Join-Path $root ([string]$profile.components.appRelativePath)
    $corePath = Join-Path $root ([string]$profile.components.coreRelativePath)
    foreach ($path in @($appPath,$corePath)) {
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "Validated package executable is missing: $path" }
    }
    $appHash = ((Get-FileHash -LiteralPath $appPath -Algorithm SHA256).Hash).ToUpperInvariant()
    $coreHash = ((Get-FileHash -LiteralPath $corePath -Algorithm SHA256).Hash).ToUpperInvariant()
    if ($appHash -cne [string]$validated.AppSha256 -or $coreHash -cne [string]$validated.CoreSha256) {
        throw 'Package App/Core bytes changed after package validation.'
    }

    return [pscustomobject][ordered]@{
        ValidatorPath = (Resolve-Path -LiteralPath $validatorPath).Path
        IdentityPath = (Resolve-Path -LiteralPath $IdentityPath).Path
        IdentityFileSha256 = ((Get-FileHash -LiteralPath $IdentityPath -Algorithm SHA256).Hash).ToUpperInvariant()
        ArchivePath = (Resolve-Path -LiteralPath $ArchivePath).Path
        PackageRoot = $root
        ProfilePath = (Resolve-Path -LiteralPath $ProfilePath).Path
        ProfileId = [string]$validated.ProfileId
        ReceiptSha256 = [string]$validated.ReceiptSha256
        ArchiveSha256 = [string]$validated.ArchiveSha256
        ManifestPath = Join-Path $root ([string]$profile.packageManifestFileName)
        ManifestSha256 = ((Get-FileHash -LiteralPath (Join-Path $root ([string]$profile.packageManifestFileName)) -Algorithm SHA256).Hash).ToUpperInvariant()
        AppPath = $appPath
        AppSha256 = $appHash
        CorePath = $corePath
        CoreSha256 = $coreHash
        SourceCommit = [string]$validated.SourceCommit
        SourceTree = [string]$validated.SourceTree
        ReferenceHostProfileSha256 = [string]$validated.ReferenceHostProfileSha256
        RendererPolicySha256 = [string]$validated.RendererPolicySha256
        ValidationEvidenceClass = [string]$validated.EvidenceClass
    }
}

function Assert-V02RuntimePackageExecutablesUnchanged {
    param([Parameter(Mandatory = $true)]$Binding)
    $identity = ((Get-FileHash -LiteralPath $Binding.IdentityPath -Algorithm SHA256).Hash).ToUpperInvariant()
    $archive = ((Get-FileHash -LiteralPath $Binding.ArchivePath -Algorithm SHA256).Hash).ToUpperInvariant()
    $manifest = ((Get-FileHash -LiteralPath $Binding.ManifestPath -Algorithm SHA256).Hash).ToUpperInvariant()
    $app = ((Get-FileHash -LiteralPath $Binding.AppPath -Algorithm SHA256).Hash).ToUpperInvariant()
    $core = ((Get-FileHash -LiteralPath $Binding.CorePath -Algorithm SHA256).Hash).ToUpperInvariant()
    if ($identity -cne [string]$Binding.IdentityFileSha256 -or
        $archive -cne [string]$Binding.ArchiveSha256 -or
        $manifest -cne [string]$Binding.ManifestSha256) {
        throw 'Validated package receipt, ZIP, or manifest changed during runtime acceptance.'
    }
    if ($app -cne [string]$Binding.AppSha256 -or $core -cne [string]$Binding.CoreSha256) {
        throw 'Validated package App/Core bytes changed during runtime acceptance.'
    }
    return [pscustomobject]@{ IdentityFileSha256=$identity; ArchiveSha256=$archive; ManifestSha256=$manifest; AppSha256=$app; CoreSha256=$core }
}

function Save-V02FreshTrxEvidence {
    param(
        [Parameter(Mandatory = $true)][string]$ResultsDirectory,
        [Parameter(Mandatory = $true)][DateTime]$StartedUtc,
        [Parameter(Mandatory = $true)][string]$EvidenceDirectory
    )

    $selected = @(Get-ChildItem -LiteralPath $ResultsDirectory -Filter '*.trx' -File |
        Where-Object { $_.LastWriteTimeUtc -ge $StartedUtc.AddSeconds(-2) } | Sort-Object Name)
    if ($selected.Count -ne 4) { throw "Expected exactly four fresh TRX files, found $($selected.Count)." }
    $target = Join-Path $EvidenceDirectory 'test-results'
    if (Test-Path -LiteralPath $target) { throw "TRX evidence directory already exists: $target" }
    New-Item -ItemType Directory -Path $target | Out-Null
    $entries = @()
    $total = 0; $passed = 0; $failed = 0
    foreach ($file in $selected) {
        [xml]$trx = Get-Content -LiteralPath $file.FullName -Raw
        $counters = $trx.TestRun.ResultSummary.Counters
        $total += [int]$counters.total; $passed += [int]$counters.passed; $failed += [int]$counters.failed
        $destination = Join-Path $target $file.Name
        Copy-Item -LiteralPath $file.FullName -Destination $destination
        $sourceHash = ((Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash).ToUpperInvariant()
        $copyHash = ((Get-FileHash -LiteralPath $destination -Algorithm SHA256).Hash).ToUpperInvariant()
        if ($sourceHash -cne $copyHash) { throw "TRX copy hash mismatch: $($file.Name)" }
        $entries += [pscustomobject][ordered]@{ Name=$file.Name; Bytes=[int64]$file.Length; Sha256=$copyHash; LastWriteUtc=$file.LastWriteTimeUtc.ToString('O') }
    }
    if ($total -le 0 -or $failed -ne 0 -or $passed -ne $total) {
        throw "Fresh test counters are not all passing: total=$total passed=$passed failed=$failed"
    }
    $receipt = [pscustomobject][ordered]@{ SchemaVersion=1; SelectionStartedUtc=$StartedUtc.ToUniversalTime().ToString('O'); FileCount=4; Total=$total; Passed=$passed; Failed=$failed; Files=$entries }
    $receiptPath = Join-Path $target 'selection-receipt.json'
    $temporary = $receiptPath + '.' + [guid]::NewGuid().ToString('N') + '.tmp'
    try {
        $json = $receipt | ConvertTo-Json -Depth 8
        [IO.File]::WriteAllText($temporary, $json + "`n", (New-Object Text.UTF8Encoding($false)))
        Move-Item -LiteralPath $temporary -Destination $receiptPath
    } finally { if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary -Force } }
    return [pscustomobject]@{ Total=$total; Passed=$passed; Failed=$failed; Directory=$target; ReceiptPath=$receiptPath; ReceiptSha256=((Get-FileHash -LiteralPath $receiptPath -Algorithm SHA256).Hash).ToUpperInvariant(); Files=$entries }
}

function New-V02TargetAgentSessionAttestation {
    param([Parameter(Mandatory = $true)][string]$Reference)
    if ([string]::IsNullOrWhiteSpace($Reference) -or $Reference.Length -gt 512 -or $Reference -match '[\r\n]') {
        throw 'TargetAgentSessionReference must be a non-empty single-line value of at most 512 characters.'
    }
    return [pscustomobject][ordered]@{
        Reference = $Reference
        EvidenceSource = 'OperatorAttestation'
        ObservableByGate = $false
        Boundary = 'The gate records this native Agent/session reference but cannot independently observe or prove restoration of the native Agent session.'
    }
}
