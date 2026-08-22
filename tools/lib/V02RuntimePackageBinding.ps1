#requires -Version 5.1

Set-StrictMode -Version Latest
New-Variable -Scope Script -Name V02GovernedPassingTestCount -Value 888 -Option Constant
New-Variable -Scope Script -Name V02GovernedTestAssemblyFileNames -Value ([string[]]@(
    'HerdrOps.UnitTests.dll',
    'HerdrOps.ContractTests.dll',
    'HerdrOps.IntegrationTests.dll',
    'HerdrOps.RuntimeTests.dll'
)) -Option Constant
if (-not (Get-Variable -Scope Script -Name V02RuntimePackageBindingAfterValidatorForTest -ErrorAction SilentlyContinue)) { $script:V02RuntimePackageBindingAfterValidatorForTest = $null }
if (-not (Get-Variable -Scope Script -Name V02TrxAfterSelectionForTest -ErrorAction SilentlyContinue)) { $script:V02TrxAfterSelectionForTest = $null }
if (-not (Get-Variable -Scope Script -Name V02TrxAfterFinalCopyForTest -ErrorAction SilentlyContinue)) { $script:V02TrxAfterFinalCopyForTest = $null }
if (-not (Get-Variable -Scope Script -Name V02TrxAfterReceiptWriteForTest -ErrorAction SilentlyContinue)) { $script:V02TrxAfterReceiptWriteForTest = $null }
if (-not (Get-Variable -Scope Script -Name V02TrxBeforePublishForTest -ErrorAction SilentlyContinue)) { $script:V02TrxBeforePublishForTest = $null }

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

    $invocationStartedUtc = $StartedUtc.ToUniversalTime()
    $selectionUpperBoundUtc = [DateTime]::UtcNow
    $target = Join-Path $EvidenceDirectory 'test-results'
    if (Test-Path -LiteralPath $target) { throw "TRX evidence directory already exists: $target" }
    $staging = Join-Path $EvidenceDirectory ('.test-results.' + [guid]::NewGuid().ToString('N') + '.staging')
    $publishedByTransaction = $false

    function Get-TrxSha256([byte[]]$Bytes) {
        $sha = [Security.Cryptography.SHA256]::Create()
        try { return ([BitConverter]::ToString($sha.ComputeHash($Bytes))).Replace('-','') }
        finally { $sha.Dispose() }
    }

    function Read-HeldTrxBytes([IO.FileStream]$Stream) {
        $Stream.Position = 0
        $bytes = New-Object byte[] $Stream.Length
        $offset = 0
        while ($offset -lt $bytes.Length) {
            $read = $Stream.Read($bytes,$offset,$bytes.Length-$offset)
            if ($read -le 0) { throw 'Unexpected end of held TRX evidence stream.' }
            $offset += $read
        }
        return $bytes
    }

    function Read-TrxSnapshot([string]$Path) {
        $info = Get-Item -LiteralPath $Path -Force
        $lastWriteUtc = [IO.File]::GetLastWriteTimeUtc($info.FullName)
        if ($lastWriteUtc -lt $invocationStartedUtc -or $lastWriteUtc -gt $selectionUpperBoundUtc) {
            throw "TRX file timestamp is outside the exact invocation window: $($info.Name)"
        }
        $stream = [IO.File]::Open($info.FullName,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read)
        try {
            $length = [int64]$stream.Length
            $bytes = New-Object byte[] $length
            $offset = 0
            while ($offset -lt $bytes.Length) {
                $read = $stream.Read($bytes,$offset,$bytes.Length-$offset)
                if ($read -le 0) { throw "Unexpected end of TRX stream: $($info.Name)" }
                $offset += $read
            }
            if ([int64]$stream.Length -ne $length -or [IO.File]::GetLastWriteTimeUtc($info.FullName).Ticks -ne $lastWriteUtc.Ticks) {
                throw "TRX changed during held-byte snapshot: $($info.Name)"
            }
        } finally { $stream.Dispose() }

        $memory = New-Object IO.MemoryStream(,$bytes)
        try { $trx = New-Object Xml.XmlDocument; $trx.Load($memory) }
        finally { $memory.Dispose() }
        $root = $trx.DocumentElement
        if ($null -eq $root -or $root.LocalName -cne 'TestRun') { throw "TRX root is not TestRun: $($info.Name)" }
        $runIdText = $root.GetAttribute('id'); $runId = [guid]::Empty
        if (-not [guid]::TryParse($runIdText,[ref]$runId) -or $runId -eq [guid]::Empty) { throw "TRX TestRun id is invalid: $($info.Name)" }
        $times = $root.SelectSingleNode("./*[local-name()='Times']")
        $runStart = [DateTimeOffset]::MinValue; $runFinish = [DateTimeOffset]::MinValue
        if ($null -eq $times -or
            -not [DateTimeOffset]::TryParse($times.GetAttribute('start'),[Globalization.CultureInfo]::InvariantCulture,[Globalization.DateTimeStyles]::RoundtripKind,[ref]$runStart) -or
            -not [DateTimeOffset]::TryParse($times.GetAttribute('finish'),[Globalization.CultureInfo]::InvariantCulture,[Globalization.DateTimeStyles]::RoundtripKind,[ref]$runFinish)) {
            throw "TRX TestRun start/finish is invalid: $($info.Name)"
        }
        if ($runStart.UtcDateTime -lt $invocationStartedUtc -or $runFinish.UtcDateTime -gt $selectionUpperBoundUtc -or $runFinish -lt $runStart) {
            throw "TRX TestRun is outside the exact invocation window: $($info.Name)"
        }
        $assemblies = @($root.SelectNodes(".//*[local-name()='UnitTest']") |
            ForEach-Object { [IO.Path]::GetFileName($_.GetAttribute('storage')) } |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Sort-Object -Unique)
        if ($assemblies.Count -ne 1) { throw "TRX must bind exactly one test assembly filename: $($info.Name)" }
        $canonicalAssembly = @($script:V02GovernedTestAssemblyFileNames | Where-Object {
            [StringComparer]::OrdinalIgnoreCase.Equals($_,$assemblies[0])
        })
        if ($canonicalAssembly.Count -ne 1) { throw "TRX test assembly filename is not governed: $($assemblies[0])" }
        $counters = $root.SelectSingleNode("./*[local-name()='ResultSummary']/*[local-name()='Counters']")
        if ($null -eq $counters) { throw "TRX counters are missing: $($info.Name)" }
        $values = @{}
        foreach ($counterName in @('total','passed','failed','notExecuted','skipped')) {
            $text = $counters.GetAttribute($counterName); $value = 0
            if ([string]::IsNullOrEmpty($text)) {
                if ($counterName -in @('total','passed','failed')) { throw "TRX counter $counterName is missing: $($info.Name)" }
            } elseif (-not [int]::TryParse($text,[Globalization.NumberStyles]::None,[Globalization.CultureInfo]::InvariantCulture,[ref]$value) -or $value -lt 0) {
                throw "TRX counter $counterName is invalid: $($info.Name)"
            }
            $values[$counterName] = $value
        }
        return [pscustomobject]@{
            Name=$info.Name;Path=$info.FullName;Length=$length;LastWriteUtc=$lastWriteUtc;Bytes=$bytes;Sha256=(Get-TrxSha256 $bytes)
            TestRunId=$runId.ToString('D');RunStartedUtc=$runStart.ToUniversalTime();RunFinishedUtc=$runFinish.ToUniversalTime()
            TestAssemblyFileName=$canonicalAssembly[0];EvidenceFileName=([IO.Path]::ChangeExtension($canonicalAssembly[0],'.trx'))
            Total=$values.total;Passed=$values.passed;Failed=$values.failed
            NotExecuted=$values.notExecuted;Skipped=$values.skipped
        }
    }

    try {
        New-Item -ItemType Directory -Path $staging | Out-Null
        $candidates = @(Get-ChildItem -LiteralPath $ResultsDirectory -Filter '*.trx' -File |
            Where-Object { $_.LastWriteTimeUtc -ge $invocationStartedUtc } | Sort-Object Name)
        if ($candidates.Count -ne 4) { throw "Expected exactly four fresh TRX files, found $($candidates.Count)." }
        $selected = @($candidates | ForEach-Object { Read-TrxSnapshot $_.FullName })
        if (@($selected.TestRunId | Sort-Object -Unique).Count -ne 4) { throw 'TRX TestRun ids must be unique across the exact four projects.' }
        foreach ($expectedAssembly in $script:V02GovernedTestAssemblyFileNames) {
            if (@($selected | Where-Object { $_.TestAssemblyFileName -ceq $expectedAssembly }).Count -ne 1) {
                throw "Expected exactly one TRX for governed test assembly: $expectedAssembly"
            }
        }
        if ($null -ne $script:V02TrxAfterSelectionForTest) { & $script:V02TrxAfterSelectionForTest }

        $entries = @(); $total = 0; $passed = 0; $failed = 0; $notExecuted = 0; $skipped = 0
        foreach ($preselected in $selected) {
            $current = Read-TrxSnapshot $preselected.Path
            if ($current.Length -ne $preselected.Length -or $current.LastWriteUtc.Ticks -ne $preselected.LastWriteUtc.Ticks -or
                $current.Sha256 -cne $preselected.Sha256 -or $current.TestRunId -cne $preselected.TestRunId -or
                $current.RunStartedUtc -ne $preselected.RunStartedUtc -or $current.RunFinishedUtc -ne $preselected.RunFinishedUtc -or
                $current.TestAssemblyFileName -cne $preselected.TestAssemblyFileName -or
                $current.EvidenceFileName -cne $preselected.EvidenceFileName) {
                throw "TRX preselection identity/hash/run binding changed: $($preselected.Name)"
            }
            $destination = Join-Path $staging $preselected.EvidenceFileName
            $output = [IO.File]::Open($destination,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
            try { $output.Write($current.Bytes,0,$current.Bytes.Length); $output.Flush($true) }
            finally { $output.Dispose() }
            $total += $current.Total; $passed += $current.Passed; $failed += $current.Failed
            $notExecuted += $current.NotExecuted; $skipped += $current.Skipped
            $entries += [pscustomobject][ordered]@{
                Name=$current.EvidenceFileName;SourceName=$current.Name;Bytes=[int64]$current.Bytes.Length;Sha256=$current.Sha256
                LastWriteUtc=$current.LastWriteUtc.ToString('O');TestRunId=$current.TestRunId
                RunStartedUtc=$current.RunStartedUtc.ToString('O');RunFinishedUtc=$current.RunFinishedUtc.ToString('O')
                TestAssemblyFileName=$current.TestAssemblyFileName;Total=$current.Total;Passed=$current.Passed
                Failed=$current.Failed;NotExecuted=$current.NotExecuted;Skipped=$current.Skipped
            }
        }
        if ($failed -ne 0) { throw "Fresh test counters contain failures: failed=$failed" }
        if ($notExecuted -ne 0 -or $skipped -ne 0) {
            throw "Fresh test counters contain skipped/notExecuted tests: skipped=$skipped notExecuted=$notExecuted"
        }
        if ($total -ne $script:V02GovernedPassingTestCount -or $passed -ne $script:V02GovernedPassingTestCount) {
            throw "Fresh test counters are not the governed all-passing aggregate: total=$total passed=$passed"
        }

        if ($null -ne $script:V02TrxAfterFinalCopyForTest) { & $script:V02TrxAfterFinalCopyForTest $staging }
        foreach ($entry in $entries) {
            $finalBytes = [IO.File]::ReadAllBytes((Join-Path $staging $entry.Name))
            if ($finalBytes.Length -ne $entry.Bytes -or (Get-TrxSha256 $finalBytes) -cne $entry.Sha256) {
                throw "Final staged TRX copy changed after validation: $($entry.Name)"
            }
        }

        $receipt = [pscustomobject][ordered]@{
            SchemaVersion=2;InvocationStartedUtc=$invocationStartedUtc.ToString('O')
            SelectionUpperBoundUtc=$selectionUpperBoundUtc.ToString('O');FileCount=4
            Total=$total;Passed=$passed;Failed=$failed;NotExecuted=$notExecuted;Skipped=$skipped;Files=$entries
        }
        $receiptPath = Join-Path $staging 'selection-receipt.json'
        $receiptBytes = (New-Object Text.UTF8Encoding($false)).GetBytes(($receipt | ConvertTo-Json -Depth 8) + "`n")
        $temporary = $receiptPath + '.' + [guid]::NewGuid().ToString('N') + '.tmp'
        $output = [IO.File]::Open($temporary,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
        try { $output.Write($receiptBytes,0,$receiptBytes.Length); $output.Flush($true) }
        finally { $output.Dispose() }
        Move-Item -LiteralPath $temporary -Destination $receiptPath
        if ($null -ne $script:V02TrxAfterReceiptWriteForTest) { & $script:V02TrxAfterReceiptWriteForTest $receiptPath }
        $finalReceiptBytes = [IO.File]::ReadAllBytes($receiptPath)
        $receiptSha256 = Get-TrxSha256 $receiptBytes
        if ($finalReceiptBytes.Length -ne $receiptBytes.Length -or (Get-TrxSha256 $finalReceiptBytes) -cne $receiptSha256) {
            throw 'TRX selection receipt changed after atomic write.'
        }
        $heldEvidence = @()
        try {
            foreach ($entry in $entries) {
                $heldEvidence += [pscustomobject]@{
                    Name=$entry.Name;ExpectedLength=[int64]$entry.Bytes;ExpectedSha256=$entry.Sha256
                    Stream=[IO.File]::Open((Join-Path $staging $entry.Name),[IO.FileMode]::Open,[IO.FileAccess]::Read,([IO.FileShare]::Read -bor [IO.FileShare]::Delete))
                }
            }
            $heldEvidence += [pscustomobject]@{
                Name='selection-receipt.json';ExpectedLength=[int64]$receiptBytes.Length;ExpectedSha256=$receiptSha256
                Stream=[IO.File]::Open($receiptPath,[IO.FileMode]::Open,[IO.FileAccess]::Read,([IO.FileShare]::Read -bor [IO.FileShare]::Delete))
            }
            foreach ($held in $heldEvidence) {
                $heldBytes = Read-HeldTrxBytes $held.Stream
                if ($heldBytes.Length -ne $held.ExpectedLength -or (Get-TrxSha256 $heldBytes) -cne $held.ExpectedSha256) {
                    throw "Held TRX evidence changed before atomic publication: $($held.Name)"
                }
            }
            if ($null -ne $script:V02TrxBeforePublishForTest) { & $script:V02TrxBeforePublishForTest $staging $target }
            New-Item -ItemType Directory -Path $target -ErrorAction Stop | Out-Null
            $publishedByTransaction = $true
            foreach ($held in $heldEvidence) {
                $sourcePath = Join-Path $staging $held.Name
                $publishedPath = Join-Path $target $held.Name
                [IO.File]::Move($sourcePath,$publishedPath)
                $publishedLock = [IO.File]::Open($publishedPath,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read)
                $held.Stream.Dispose(); $held.Stream = $publishedLock
                $heldBytes = Read-HeldTrxBytes $publishedLock
                $publishedBytes = [IO.File]::ReadAllBytes((Join-Path $target $held.Name))
                if ($heldBytes.Length -ne $held.ExpectedLength -or (Get-TrxSha256 $heldBytes) -cne $held.ExpectedSha256 -or
                    $publishedBytes.Length -ne $held.ExpectedLength -or (Get-TrxSha256 $publishedBytes) -cne $held.ExpectedSha256) {
                    throw "Held TRX evidence changed across atomic publication: $($held.Name)"
                }
            }
            Remove-Item -LiteralPath $staging -Force
        } finally {
            foreach ($held in $heldEvidence) { if ($null -ne $held.Stream) { $held.Stream.Dispose() } }
        }
        $finalReceiptPath = Join-Path $target 'selection-receipt.json'
        return [pscustomobject]@{
            Total=$total;Passed=$passed;Failed=$failed;NotExecuted=$notExecuted;Skipped=$skipped
            Directory=$target;ReceiptPath=$finalReceiptPath;ReceiptSha256=$receiptSha256;Files=$entries
        }
    } catch {
        if (Test-Path -LiteralPath $staging) { Remove-Item -LiteralPath $staging -Recurse -Force }
        if ($publishedByTransaction -and (Test-Path -LiteralPath $target)) { Remove-Item -LiteralPath $target -Recurse -Force }
        throw
    }
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
