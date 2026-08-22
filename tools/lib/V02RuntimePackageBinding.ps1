#requires -Version 5.1

Set-StrictMode -Version Latest
New-Variable -Scope Script -Name V02GovernedPassingTestCount -Value 888 -Option Constant
if (-not (Get-Variable -Scope Script -Name V02RuntimePackageBindingAfterValidatorForTest -ErrorAction SilentlyContinue)) { $script:V02RuntimePackageBindingAfterValidatorForTest = $null }
if (-not (Get-Variable -Scope Script -Name V02TrxAfterSelectionForTest -ErrorAction SilentlyContinue)) { $script:V02TrxAfterSelectionForTest = $null }

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

function Invoke-V02CommittedPackageValidator {
    param(
        [Parameter(Mandatory = $true)][string]$ValidatorPath,
        [Parameter(Mandatory = $true)][string]$IdentityPath,
        [Parameter(Mandatory = $true)][string]$ArchivePath,
        [Parameter(Mandatory = $true)][string]$PackageRoot,
        [Parameter(Mandatory = $true)][string]$RepositoryRoot,
        [Parameter(Mandatory = $true)][string]$ProfilePath,
        [Parameter(Mandatory = $true)][string]$ExpectedSourceCommit,
        [Parameter(Mandatory = $true)][string]$ExpectedSourceTree
    )
    $output = @(& $ValidatorPath -IdentityPath $IdentityPath -ArchivePath $ArchivePath `
        -PackageRoot $PackageRoot -RepositoryRoot $RepositoryRoot -ProfilePath $ProfilePath)
    if ($output.Count -ne 1) { throw 'Package validator must return exactly one validation result.' }
    Assert-V02RuntimePackageValidationResult -Result $output[0] `
        -ExpectedSourceCommit $ExpectedSourceCommit -ExpectedSourceTree $ExpectedSourceTree
    return $output[0]
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
    $validated = Invoke-V02CommittedPackageValidator -ValidatorPath $validatorPath `
        -IdentityPath $IdentityPath -ArchivePath $ArchivePath -PackageRoot $PackageRoot `
        -RepositoryRoot $RepositoryRoot -ProfilePath $ProfilePath `
        -ExpectedSourceCommit $ExpectedSourceCommit -ExpectedSourceTree $ExpectedSourceTree
    if ($null -ne $script:V02RuntimePackageBindingAfterValidatorForTest) {
        & $script:V02RuntimePackageBindingAfterValidatorForTest
    }
    # A second complete validation closes the explicit post-validator test seam
    # and ensures every source, archive, manifest, inventory and component leaf
    # still matches before executable paths are admitted for launch.
    $validated = Invoke-V02CommittedPackageValidator -ValidatorPath $validatorPath `
        -IdentityPath $IdentityPath -ArchivePath $ArchivePath -PackageRoot $PackageRoot `
        -RepositoryRoot $RepositoryRoot -ProfilePath $ProfilePath `
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
    $profileFileHash = ((Get-FileHash -LiteralPath $ProfilePath -Algorithm SHA256).Hash).ToUpperInvariant()
    if ($appHash -cne [string]$validated.AppSha256 -or $coreHash -cne [string]$validated.CoreSha256) {
        throw 'Package App/Core bytes changed after package validation.'
    }
    if ($profileFileHash -cne [string]$validated.PreparationProfileFileSha256) {
        throw 'Package preparation profile bytes changed after package validation.'
    }

    return [pscustomobject][ordered]@{
        ValidatorPath = (Resolve-Path -LiteralPath $validatorPath).Path
        IdentityPath = (Resolve-Path -LiteralPath $IdentityPath).Path
        IdentityFileSha256 = ((Get-FileHash -LiteralPath $IdentityPath -Algorithm SHA256).Hash).ToUpperInvariant()
        ArchivePath = (Resolve-Path -LiteralPath $ArchivePath).Path
        PackageRoot = $root
        ProfilePath = (Resolve-Path -LiteralPath $ProfilePath).Path
        ProfileFileSha256 = $profileFileHash
        ProfileCanonicalSha256 = [string]$validated.PreparationProfileCanonicalSha256
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
        RepositoryRoot = [IO.Path]::GetFullPath($RepositoryRoot)
        ExpectedSourceCommit = $ExpectedSourceCommit.ToLowerInvariant()
        ExpectedSourceTree = $ExpectedSourceTree.ToLowerInvariant()
        ValidationResult = $validated
    }
}

function Assert-V02RuntimePackageExecutablesUnchanged {
    param([Parameter(Mandatory = $true)]$Binding)
    $identity = ((Get-FileHash -LiteralPath $Binding.IdentityPath -Algorithm SHA256).Hash).ToUpperInvariant()
    $profile = ((Get-FileHash -LiteralPath $Binding.ProfilePath -Algorithm SHA256).Hash).ToUpperInvariant()
    $archive = ((Get-FileHash -LiteralPath $Binding.ArchivePath -Algorithm SHA256).Hash).ToUpperInvariant()
    $manifest = ((Get-FileHash -LiteralPath $Binding.ManifestPath -Algorithm SHA256).Hash).ToUpperInvariant()
    $app = ((Get-FileHash -LiteralPath $Binding.AppPath -Algorithm SHA256).Hash).ToUpperInvariant()
    $core = ((Get-FileHash -LiteralPath $Binding.CorePath -Algorithm SHA256).Hash).ToUpperInvariant()
    if ($identity -cne [string]$Binding.IdentityFileSha256 -or $profile -cne [string]$Binding.ProfileFileSha256 -or
        $archive -cne [string]$Binding.ArchiveSha256 -or
        $manifest -cne [string]$Binding.ManifestSha256) {
        throw 'Validated package receipt, ZIP, or manifest changed during runtime acceptance.'
    }
    if ($app -cne [string]$Binding.AppSha256 -or $core -cne [string]$Binding.CoreSha256) {
        throw 'Validated package App/Core bytes changed during runtime acceptance.'
    }
    $final = Invoke-V02CommittedPackageValidator -ValidatorPath $Binding.ValidatorPath `
        -IdentityPath $Binding.IdentityPath -ArchivePath $Binding.ArchivePath -PackageRoot $Binding.PackageRoot `
        -RepositoryRoot $Binding.RepositoryRoot -ProfilePath $Binding.ProfilePath `
        -ExpectedSourceCommit $Binding.ExpectedSourceCommit -ExpectedSourceTree $Binding.ExpectedSourceTree
    foreach ($property in @($Binding.ValidationResult.PSObject.Properties.Name)) {
        if ([string]$final.$property -cne [string]$Binding.ValidationResult.$property) {
            throw "Final package validation changed bound field '$property'."
        }
    }
    return [pscustomobject]@{ IdentityFileSha256=$identity; ProfileFileSha256=$profile; ArchiveSha256=$archive; ManifestSha256=$manifest; AppSha256=$app; CoreSha256=$core }
}

function Save-V02FreshTrxEvidence {
    param(
        [Parameter(Mandatory = $true)][string]$ResultsDirectory,
        [Parameter(Mandatory = $true)][DateTime]$StartedUtc,
        [Parameter(Mandatory = $true)][string]$EvidenceDirectory
    )

    $selected = @(Get-ChildItem -LiteralPath $ResultsDirectory -Filter '*.trx' -File |
        Where-Object { $_.LastWriteTimeUtc -ge $StartedUtc.AddSeconds(-2) } | Sort-Object Name |
        ForEach-Object { [pscustomobject]@{ Name=$_.Name; Path=$_.FullName; Length=[int64]$_.Length; LastWriteUtc=[IO.File]::GetLastWriteTimeUtc($_.FullName) } })
    if ($selected.Count -ne 4) { throw "Expected exactly four fresh TRX files, found $($selected.Count)." }
    if ($null -ne $script:V02TrxAfterSelectionForTest) { & $script:V02TrxAfterSelectionForTest }
    $target = Join-Path $EvidenceDirectory 'test-results'
    if (Test-Path -LiteralPath $target) { throw "TRX evidence directory already exists: $target" }
    New-Item -ItemType Directory -Path $target | Out-Null
    $entries = @()
    $total = 0; $passed = 0; $failed = 0
    foreach ($file in $selected) {
        $source = [IO.File]::Open($file.Path,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read)
        try {
            if ([int64]$source.Length -ne $file.Length -or [IO.File]::GetLastWriteTimeUtc($file.Path).Ticks -ne $file.LastWriteUtc.Ticks) {
                throw "TRX changed after fresh-file selection: $($file.Name)"
            }
            $sourceBytes = New-Object byte[] $source.Length
            $offset = 0
            while ($offset -lt $sourceBytes.Length) {
                $read = $source.Read($sourceBytes,$offset,$sourceBytes.Length-$offset)
                if ($read -le 0) { throw "Unexpected end of TRX stream: $($file.Name)" }
                $offset += $read
            }
            if ([int64]$source.Length -ne $file.Length -or [IO.File]::GetLastWriteTimeUtc($file.Path).Ticks -ne $file.LastWriteUtc.Ticks) {
                throw "TRX changed during held-byte snapshot: $($file.Name)"
            }
        } finally { $source.Dispose() }
        $destination = Join-Path $target $file.Name
        $temporary = $destination + '.' + [guid]::NewGuid().ToString('N') + '.tmp'
        try {
            $output = [IO.File]::Open($temporary,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
            try { $output.Write($sourceBytes,0,$sourceBytes.Length); $output.Flush($true) } finally { $output.Dispose() }
            Move-Item -LiteralPath $temporary -Destination $destination
        } finally { if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary -Force } }
        $copyBytes = [IO.File]::ReadAllBytes($destination)
        if ($copyBytes.Length -ne $sourceBytes.Length) { throw "TRX preserved-copy length mismatch: $($file.Name)" }
        $sha = [Security.Cryptography.SHA256]::Create()
        try {
            $sourceHash = ([BitConverter]::ToString($sha.ComputeHash($sourceBytes))).Replace('-','')
            $copyHash = ([BitConverter]::ToString($sha.ComputeHash($copyBytes))).Replace('-','')
        } finally { $sha.Dispose() }
        if ($sourceHash -cne $copyHash) { throw "TRX preserved-copy hash mismatch: $($file.Name)" }
        $memory = New-Object IO.MemoryStream(,$copyBytes)
        try { $trx = New-Object Xml.XmlDocument; $trx.Load($memory) } finally { $memory.Dispose() }
        $counters = $trx.TestRun.ResultSummary.Counters
        $total += [int]$counters.total; $passed += [int]$counters.passed; $failed += [int]$counters.failed
        $entries += [pscustomobject][ordered]@{ Name=$file.Name; Bytes=[int64]$copyBytes.Length; Sha256=$copyHash; LastWriteUtc=$file.LastWriteUtc.ToString('O') }
    }
    if ($total -ne $script:V02GovernedPassingTestCount -or $failed -ne 0 -or
        $passed -ne $script:V02GovernedPassingTestCount) {
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
