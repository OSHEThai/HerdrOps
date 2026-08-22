#requires -Version 5.1

Set-StrictMode -Version Latest

. (Join-Path $PSScriptRoot 'V02Packaging.Common.ps1')
. (Join-Path $PSScriptRoot 'V02PackageIdentity.Common.ps1')

$script:V02CleanMachineSchemaPath = Join-Path $PSScriptRoot 'clean-machine-report.schema.json'
$script:V02CleanMachineSchemaId = 'https://herdrops.local/schema/v0.2/clean-machine-report.schema.json'
# SHA-1 thumbprint of the independently administered clean-host observer
# signing certificate.  Live evidence is impossible until that certificate is
# present and trusted; callers cannot replace this pin with a parameter.
$script:V02CleanMachineObserverSignerThumbprint = '8F319A7C115B0793D880D6E6F02F47B36E87D518'

function Get-V02MachineFingerprint {
    $machineGuid = ''
    try {
        $machineGuid = [string](Get-ItemPropertyValue -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Cryptography' -Name MachineGuid -ErrorAction Stop)
    }
    catch {
        throw "Machine fingerprint could not read the OS MachineGuid: $($_.Exception.Message)"
    }
    $raw = @(
        [Environment]::MachineName,
        $machineGuid,
        [Environment]::ProcessorCount.ToString(),
        [Environment]::Is64BitOperatingSystem.ToString(),
        [Environment]::OSVersion.VersionString
    ) -join '|'
    $bytes = (New-Object Text.UTF8Encoding($false, $true)).GetBytes($raw)
    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        $hashBytes = $sha.ComputeHash($bytes)
        return ([BitConverter]::ToString($hashBytes)).Replace('-', '').ToUpperInvariant()
    } finally {
        $sha.Dispose()
    }
}

function Get-V02ExecutingPrincipalSid {
    try {
        return [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    }
    catch {
        throw "Executing Windows principal SID could not be resolved: $($_.Exception.Message)"
    }
}

function Assert-V02PathWithinRoot {
    param([Parameter(Mandatory = $true)][string]$Path,[Parameter(Mandatory = $true)][string]$Root,[Parameter(Mandatory = $true)][string]$Context)
    $full = [IO.Path]::GetFullPath($Path).TrimEnd('\','/')
    $rootFull = [IO.Path]::GetFullPath($Root).TrimEnd('\','/')
    $prefix = $rootFull + [IO.Path]::DirectorySeparatorChar
    if (-not [StringComparer]::OrdinalIgnoreCase.Equals($full,$rootFull) -and -not $full.StartsWith($prefix,[StringComparison]::OrdinalIgnoreCase)) {
        throw "$Context must remain inside fixture root '$rootFull': $full"
    }
    Assert-V02PathNoReparse $rootFull
    Assert-V02PathNoReparse $full
    return $full
}

function Assert-V02PathOutsideRoot {
    param([Parameter(Mandatory = $true)][string]$Path,[Parameter(Mandatory = $true)][string]$Root,[Parameter(Mandatory = $true)][string]$Context)
    $full = [IO.Path]::GetFullPath($Path).TrimEnd('\','/')
    $rootFull = [IO.Path]::GetFullPath($Root).TrimEnd('\','/')
    if ([StringComparer]::OrdinalIgnoreCase.Equals($full,$rootFull) -or $full.StartsWith($rootFull + [IO.Path]::DirectorySeparatorChar,[StringComparison]::OrdinalIgnoreCase)) {
        throw "$Context must be externally anchored outside '$rootFull'."
    }
}

function Read-V02CleanHostAuthorization {
    param(
        [Parameter(Mandatory = $true)][string]$AuthorizationPath,
        [Parameter(Mandatory = $true)][string]$SignaturePath,
        [Parameter(Mandatory = $true)][string]$MachineName,
        [Parameter(Mandatory = $true)][string]$MachineFingerprint,
        [Parameter(Mandatory = $true)][string]$PrincipalSid,
        [Parameter(Mandatory = $true)]$InitialBinding,
        [Parameter(Mandatory = $true)]$FinalBinding
    )
    foreach ($path in @($AuthorizationPath,$SignaturePath)) {
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "External clean-host authorization input is missing: $path" }
        Assert-V02PathNoReparse ([IO.Path]::GetFullPath($path))
    }
    $authorizationStable = Get-V02StableFileIdentity -Path ([IO.Path]::GetFullPath($AuthorizationPath)) -IncludeBytes
    $signatureStable = Get-V02StableFileIdentity -Path ([IO.Path]::GetFullPath($SignaturePath)) -IncludeBytes
    $authorizationBytes = $authorizationStable.Bytes
    $signatureBytes = $signatureStable.Bytes
    try {
        Add-Type -AssemblyName System.Security.Cryptography.Pkcs -ErrorAction Stop
        $cms = [Security.Cryptography.Pkcs.SignedCms]::new([Security.Cryptography.Pkcs.ContentInfo]::new($authorizationBytes),$true)
        $cms.Decode($signatureBytes)
        $cms.CheckSignature($false)
    }
    catch { throw "External clean-host authorization signature is invalid or untrusted: $($_.Exception.Message)" }
    if ($cms.SignerInfos.Count -ne 1) { throw 'External clean-host authorization must have exactly one signer.' }
    $signer = $cms.SignerInfos[0].Certificate
    if ($null -eq $signer -or $signer.Thumbprint.Replace(' ','').ToUpperInvariant() -cne $script:V02CleanMachineObserverSignerThumbprint) {
        throw 'External clean-host authorization signer does not equal the committed independent-observer certificate pin.'
    }
    $document = ConvertFrom-V02StrictBytes -Bytes $authorizationBytes -Description 'external clean-host authorization'
    $value = $document.Value
    $required = @('schemaVersion','authorizationKind','machineName','machineFingerprint','principalSid','operatorSid','observerIdentity','initial','final','issuedAtUtc','expiresAtUtc','nonce')
    $names = @($value.PSObject.Properties.Name)
    if ($names.Count -ne $required.Count -or @($required | Where-Object { -not ($names -ccontains $_) }).Count -ne 0) { throw 'External clean-host authorization has an unexpected schema.' }
    if ([int]$value.schemaVersion -ne 1 -or [string]$value.authorizationKind -cne 'HerdrOps.V02CleanHostAuthorization') { throw 'External clean-host authorization kind/version is invalid.' }
    foreach ($binding in @(
        @('machineName',$MachineName),@('machineFingerprint',$MachineFingerprint),@('principalSid',$PrincipalSid),@('operatorSid',$PrincipalSid))) {
        if ([string]$value.($binding[0]) -cne [string]$binding[1]) { throw "External clean-host authorization $($binding[0]) binding mismatch." }
    }
    $bindingNames = @('sourceCommit','sourceTree','receiptSha256','archiveSha256','packageManifestSha256','appSha256','coreSha256')
    foreach ($phase in @('initial','final')) {
        $authorized = $value.$phase
        $expected = if ($phase -ceq 'initial') { $InitialBinding } else { $FinalBinding }
        $actualNames = @($authorized.PSObject.Properties.Name)
        if ($actualNames.Count -ne $bindingNames.Count -or @($bindingNames | Where-Object { -not ($actualNames -ccontains $_) }).Count -ne 0) { throw "External clean-host authorization $phase binding schema is invalid." }
        foreach ($name in $bindingNames) {
            if ([string]$authorized.$name -cne [string]$expected.$name) { throw "External clean-host authorization $phase.$name binding mismatch." }
        }
    }
    if ([string]::IsNullOrWhiteSpace([string]$value.observerIdentity) -or [string]$value.observerIdentity -ceq $PrincipalSid) { throw 'External observer identity is missing or not role-distinct.' }
    if ([string]$value.nonce -cnotmatch '^[0-9a-f]{32}$') { throw 'External clean-host authorization nonce is invalid.' }
    $now = [DateTimeOffset]::UtcNow
    $issued = [DateTimeOffset]::Parse([string]$value.issuedAtUtc,[Globalization.CultureInfo]::InvariantCulture)
    $expires = [DateTimeOffset]::Parse([string]$value.expiresAtUtc,[Globalization.CultureInfo]::InvariantCulture)
    if ($issued -gt $now -or $expires -le $now -or ($expires-$issued).TotalHours -gt 24) { throw 'External clean-host authorization validity window is invalid.' }
    return [pscustomobject]@{ Value=$value; SignerThumbprint=$signer.Thumbprint.Replace(' ','').ToUpperInvariant(); AuthorizationSha256=$authorizationStable.Sha256; SignatureSha256=$signatureStable.Sha256 }
}

function Assert-V02ActorIdentities {
    param(
        [Parameter(Mandatory = $true)][string]$OperatorIdentity,
        [Parameter(Mandatory = $true)][string]$ObserverIdentity
    )

    if ([string]::IsNullOrWhiteSpace($OperatorIdentity)) {
        throw 'OperatorIdentity must not be empty.'
    }
    if ([string]::IsNullOrWhiteSpace($ObserverIdentity)) {
        throw 'ObserverIdentity must not be empty.'
    }
    if ($OperatorIdentity.Trim().Equals($ObserverIdentity.Trim(), [StringComparison]::OrdinalIgnoreCase)) {
        throw 'OperatorIdentity and ObserverIdentity must be distinct (case-insensitive).'
    }
}

function Get-V02ResidueInspection {
    param(
        [Parameter(Mandatory = $true)][string]$InstallRoot,
        [string]$StartupValueName = 'HerdrOps',
        [hashtable]$MockRegistryHive = $null,
        [switch]$FixtureIsolation
    )

    $install = [IO.Path]::GetFullPath($InstallRoot).TrimEnd('\', '/')
    $installParent = Split-Path -Path $install -Parent
    $installName = [IO.Path]::GetFileName($install)

    $orphanedStaging = $false
    $orphanedBackup = $false
    if (Test-Path -LiteralPath $installParent -PathType Container) {
        $stagingPattern = '^\.' + [regex]::Escape($installName) + '\.staging-[0-9a-f]{32}$'
        $backupPattern = '^\.' + [regex]::Escape($installName) + '\.backup-[0-9a-f]{32}$'
        $uninstallPattern = '^\.' + [regex]::Escape($installName) + '\.uninstall-[0-9a-f]{32}$'
        $candidates = @(Get-ChildItem -LiteralPath $installParent -Directory -Force -ErrorAction SilentlyContinue)
        if (@($candidates | Where-Object { $_.Name -match $stagingPattern }).Count -gt 0) {
            $orphanedStaging = $true
        }
        if (@($candidates | Where-Object { $_.Name -match $backupPattern }).Count -gt 0) {
            $orphanedBackup = $true
        }
        if (@($candidates | Where-Object { $_.Name -match $uninstallPattern }).Count -gt 0) {
            $orphanedBackup = $true
        }
    }

    $startupState = Get-V02UserStartupState -ValueName $StartupValueName -MockRegistryHive $MockRegistryHive
    $startupCleaned = (-not $startupState.Exists)

    # Fixture mode is deliberately incapable of observing or mutating the real
    # product process/pipe/listener/shortcut surfaces.  Those checks are only
    # meaningful on the externally authorized clean host in Live mode.
    if ($FixtureIsolation) {
        return [pscustomobject][ordered]@{
            orphanedStagingPresent = $orphanedStaging
            orphanedBackupPresent = $orphanedBackup
            startupRegistryCleaned = $startupCleaned
            shortcutsCleaned = $true
            activePipesRemaining = 0
            activeProcessesRemaining = 0
            activeListenersRemaining = 0
        }
    }

    $activePipes = 0
    try {
        if ([IO.Directory]::Exists('\\.\pipe\')) {
            $pipeFiles = [IO.Directory]::GetFiles('\\.\pipe\', '*HerdrOps*')
            if ($null -ne $pipeFiles) {
                $activePipes = [int]$pipeFiles.Length
            }
        }
    } catch {
        throw "Named-pipe residue enumeration failed closed: $($_.Exception.Message)"
    }

    $activeProcesses = 0
    try {
        $appProcs = [Diagnostics.Process]::GetProcessesByName('HerdrOps.App')
        $coreProcs = [Diagnostics.Process]::GetProcessesByName('HerdrOps.Core')
        $activeProcesses = [int]($appProcs.Length + $coreProcs.Length)
    } catch {
        throw "Process residue enumeration failed closed: $($_.Exception.Message)"
    }

    $activeListeners = 0
    try {
        $productPids = @([Diagnostics.Process]::GetProcessesByName('HerdrOps.App') + [Diagnostics.Process]::GetProcessesByName('HerdrOps.Core') | ForEach-Object { $_.Id })
        if ($productPids.Count -gt 0) {
            $tcpCommand = Get-Command Get-NetTCPConnection -ErrorAction Stop
            $activeListeners = @(& $tcpCommand | Where-Object { $_.State -eq 'Listen' -and $productPids -contains [int]$_.OwningProcess }).Count
        }
    }
    catch { throw "Listener residue enumeration failed closed: $($_.Exception.Message)" }

    $shortcutPaths = @(
        (Join-Path ([Environment]::GetFolderPath('Desktop')) 'HerdrOps.lnk'),
        (Join-Path ([Environment]::GetFolderPath('StartMenu')) 'Programs\HerdrOps.lnk')
    )
    $shortcutsCleaned = (@($shortcutPaths | Where-Object { Test-Path -LiteralPath $_ }).Count -eq 0)

    return [pscustomobject][ordered]@{
        orphanedStagingPresent = $orphanedStaging
        orphanedBackupPresent = $orphanedBackup
        startupRegistryCleaned = $startupCleaned
        shortcutsCleaned = $shortcutsCleaned
        activePipesRemaining = [int]$activePipes
        activeProcessesRemaining = [int]$activeProcesses
        activeListenersRemaining = [int]$activeListeners
    }
}

function ConvertTo-V02CleanMachineJcsString {
    param([AllowEmptyString()][Parameter(Mandatory = $true)][string]$Value)

    $builder = [Text.StringBuilder]::new()
    [void]$builder.Append('"')
    :characters for ($index = 0; $index -lt $Value.Length; $index++) {
        $code = [int]$Value[$index]
        switch ($code) {
            8 { [void]$builder.Append('\b'); continue characters }
            9 { [void]$builder.Append('\t'); continue characters }
            10 { [void]$builder.Append('\n'); continue characters }
            12 { [void]$builder.Append('\f'); continue characters }
            13 { [void]$builder.Append('\r'); continue characters }
            34 { [void]$builder.Append('\"'); continue characters }
            92 { [void]$builder.Append('\\'); continue characters }
        }
        if ($code -lt 0x20) { [void]$builder.AppendFormat('\u{0:x4}', $code); continue }
        if ($code -ge 0xD800 -and $code -le 0xDBFF) {
            if ($index + 1 -ge $Value.Length -or [int]$Value[$index + 1] -lt 0xDC00 -or [int]$Value[$index + 1] -gt 0xDFFF) {
                throw 'JCS input contains an unpaired high surrogate.'
            }
            [void]$builder.Append($Value[$index])
            [void]$builder.Append($Value[++$index])
            continue
        }
        if ($code -ge 0xDC00 -and $code -le 0xDFFF) { throw 'JCS input contains an unpaired low surrogate.' }
        [void]$builder.Append($Value[$index])
    }
    [void]$builder.Append('"')
    return $builder.ToString()
}

function ConvertTo-V02CleanMachineJcs {
    param([AllowNull()][object]$Value)

    if ($null -eq $Value) { return 'null' }
    if ($Value -is [string]) { return ConvertTo-V02CleanMachineJcsString $Value }
    if ($Value -is [bool]) { if ($Value) { return 'true' } else { return 'false' } }
    if ($Value -is [byte] -or $Value -is [sbyte] -or $Value -is [int16] -or
        $Value -is [uint16] -or $Value -is [int32] -or $Value -is [uint32] -or
        $Value -is [int64] -or $Value -is [uint64]) {
        return ([Convert]::ToString($Value, [Globalization.CultureInfo]::InvariantCulture))
    }
    if ($Value -is [single] -or $Value -is [double] -or $Value -is [decimal]) {
        throw 'The clean-machine report permits integer JSON numbers only.'
    }
    if ($Value -is [Collections.IEnumerable] -and $Value -isnot [pscustomobject]) {
        return '[' + ((@($Value) | ForEach-Object { ConvertTo-V02CleanMachineJcs $_ }) -join ',') + ']'
    }
    if ($Value -is [pscustomobject]) {
        $names = [string[]]@($Value.PSObject.Properties.Name)
        [Array]::Sort($names, [StringComparer]::Ordinal)
        return '{' + (($names | ForEach-Object {
                    (ConvertTo-V02CleanMachineJcsString $_) + ':' + (ConvertTo-V02CleanMachineJcs $Value.PSObject.Properties[$_].Value)
                }) -join ',') + '}'
    }
    throw "Unsupported JCS value type: $($Value.GetType().FullName)"
}

function Write-V02CleanMachineReportFile {
    param(
        [Parameter(Mandatory = $true)]$Value,
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$RepositoryRoot
    )
    $json = ConvertTo-V02CleanMachineJcs -Value $Value
    $full = [IO.Path]::GetFullPath($Path)
    $parent = [IO.Path]::GetDirectoryName($full)
    if (-not (Test-Path -LiteralPath $parent -PathType Container)) { throw "Report parent must pre-exist: $parent" }
    Assert-V02PathNoReparse $parent
    $parentLease = Open-V02DirectoryMutationLease -Path $parent
    try {
        if (Test-Path -LiteralPath $full) { throw "Refusing to overwrite existing report: $full" }
        $stage = Join-Path $parent ('.'+[IO.Path]::GetFileName($full)+'.staging-'+[Guid]::NewGuid().ToString('N'))
        $bytes = (New-Object Text.UTF8Encoding($false)).GetBytes($json + "`n")
        $stream = $null
        try {
            $stream = [IO.File]::Open($stage,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
            $stream.Write($bytes,0,$bytes.Length);$stream.Flush($true);$stream.Dispose();$stream=$null
            Assert-V02PathNoReparse $stage
            [IO.File]::Move($stage,$full)
            Assert-V02PathNoReparse $full
            $written = Get-V02StableFileIdentity $full
            $sha = [Security.Cryptography.SHA256]::Create()
            try { $expectedSha = ([BitConverter]::ToString($sha.ComputeHash($bytes))).Replace('-','') } finally { $sha.Dispose() }
            if ($written.Length -ne $bytes.Length -or $written.Sha256 -cne $expectedSha) { throw 'Published clean-machine report bytes changed.' }
        }
        finally {
            if ($null -ne $stream) { $stream.Dispose() }
            if (Test-Path -LiteralPath $stage) { Remove-Item -LiteralPath $stage -Force }
        }
    } finally {
        $parentLease.Dispose()
    }
}

function New-V02CleanMachineReportObject {
    param(
        [Parameter(Mandatory = $true)][ValidateSet('PASS', 'FAIL', 'CANCELLED')][string]$Status,
        [Parameter(Mandatory = $true)][ValidateSet('DryRun', 'Fixture', 'Live')][string]$Mode,
        [Parameter(Mandatory = $true)][string]$StartedAtUtc,
        [Parameter(Mandatory = $true)][string]$CompletedAtUtc,
        [Parameter(Mandatory = $true)][string]$RunId,
        [Parameter(Mandatory = $true)]$Machine,
        [Parameter(Mandatory = $true)]$Actor,
        [Parameter(Mandatory = $true)]$Bindings,
        [Parameter(Mandatory = $true)]$Targets,
        [Parameter(Mandatory = $true)][object[]]$Preflight,
        [Parameter(Mandatory = $true)]$Lifecycle,
        [Parameter(Mandatory = $true)]$RetainedData,
        [Parameter(Mandatory = $true)]$Residue,
        [Parameter(Mandatory = $true)][ValidateSet('Synthetic', 'CleanMachine')][string]$EvidenceClass,
        [bool]$CreditGranted = $false,
        [string]$FailureDetails = ''
    )

    return [pscustomobject][ordered]@{
        schemaVersion = 1
        reportKind = 'HerdrOps.V02CleanMachineReport'
        scope = 'InstallLifecycleOnly'
        issue = 149
        packageVersion = '0.2.0'
        profileId = 'herdrops-v0.2-package-software-only-issue-149'
        status = $Status
        mode = $Mode
        startedAtUtc = $StartedAtUtc
        completedAtUtc = $CompletedAtUtc
        runId = $RunId
        actualHerdrStarted = $false
        herdrOpsStarted = $false
        networkContacted = $false
        machine = $Machine
        actor = $Actor
        bindings = $Bindings
        targets = $Targets
        preflight = $Preflight
        lifecycle = $Lifecycle
        retainedData = $RetainedData
        residue = $Residue
        evidenceBoundary = [pscustomobject][ordered]@{
            evidenceClass = $EvidenceClass
            actualHerdrRuntime = 'NOT_OBSERVED'
            independentReview = 'NOT_OBSERVED'
            humanGo = 'NOT_OBSERVED'
            releaseCredit = 'NOT_OBSERVED'
            creditGranted = $CreditGranted
        }
        failureDetails = $FailureDetails
    }
}

function Assert-V02CleanMachineReportSchema {
    param(
        [Parameter(Mandatory = $true)]$Report,
        [Parameter(Mandatory = $true)][string]$RepositoryRoot
    )

    $names = @($Report.PSObject.Properties.Name)
    $expectedNames = @(
        'schemaVersion', 'reportKind', 'scope', 'issue', 'packageVersion', 'profileId',
        'status', 'mode', 'startedAtUtc', 'completedAtUtc', 'runId',
        'actualHerdrStarted', 'herdrOpsStarted', 'networkContacted',
        'machine', 'actor', 'bindings', 'targets', 'preflight',
        'lifecycle', 'retainedData', 'residue', 'evidenceBoundary', 'failureDetails'
    )
    foreach ($req in $expectedNames) {
        if (-not ($names -ccontains $req)) {
            throw "Report is missing required property '$req'."
        }
    }
    if ($names.Count -ne $expectedNames.Count) {
        throw "Report contains unexpected properties."
    }

    if ([int]$Report.schemaVersion -ne 1) { throw 'schemaVersion must be 1.' }
    if ([string]$Report.reportKind -cne 'HerdrOps.V02CleanMachineReport') { throw "reportKind must be 'HerdrOps.V02CleanMachineReport'." }
    if ([string]$Report.scope -cne 'InstallLifecycleOnly') { throw "scope must be 'InstallLifecycleOnly'." }
    if ([int]$Report.issue -ne 149) { throw 'issue must be 149.' }
    if ([string]$Report.packageVersion -cne '0.2.0') { throw "packageVersion must be '0.2.0'." }
    if ([string]$Report.profileId -cne 'herdrops-v0.2-package-software-only-issue-149') { throw "profileId must be 'herdrops-v0.2-package-software-only-issue-149'." }
    if ([string]$Report.status -cnotin @('PASS', 'FAIL', 'CANCELLED')) { throw 'status is invalid.' }
    if ([string]$Report.mode -cnotin @('DryRun', 'Fixture', 'Live')) { throw 'mode is invalid.' }
    if ([string]$Report.runId -notmatch '^[0-9a-f]{32}$') { throw 'runId is not a 32-hex string.' }

    if ([bool]$Report.actualHerdrStarted -ne $false) { throw 'actualHerdrStarted must be false.' }
    if ([bool]$Report.herdrOpsStarted -ne $false) { throw 'herdrOpsStarted must be false.' }
    if ([bool]$Report.networkContacted -ne $false) { throw 'networkContacted must be false.' }

    # Machine
    if ([string]$Report.mode -eq 'Live' -and [bool]$Report.machine.elevated) { throw 'Live machine.elevated must be false.' }
    if ([string]::IsNullOrWhiteSpace($Report.machine.machineName)) { throw 'machine.machineName must not be empty.' }
    if ([string]$Report.machine.machineFingerprint -notmatch '^[0-9A-F]{64}$') { throw 'machine.machineFingerprint must be 64-hex uppercase.' }

    # Actor
    Assert-V02ActorIdentities -OperatorIdentity $Report.actor.operator.identity -ObserverIdentity $Report.actor.observer.identity
    if ([string]$Report.actor.operator.role -cne 'EvidenceOperator') { throw "operator.role must be 'EvidenceOperator'." }
    if ([string]$Report.actor.observer.role -cne 'IndependentObserver') { throw "observer.role must be 'IndependentObserver'." }
    if ([string]$Report.mode -eq 'Live') {
        if ([string]$Report.actor.authorization.status -cne 'VERIFIED' -or [string]$Report.actor.authorization.signerThumbprint -cne $script:V02CleanMachineObserverSignerThumbprint) { throw 'Live actor authorization must be externally verified by the pinned observer.' }
        foreach ($name in @('authorizationSha256','signatureSha256')) { if ([string]$Report.actor.authorization.$name -cnotmatch '^[0-9A-F]{64}$') { throw "Live actor authorization $name is invalid." } }
        if ([string]$Report.actor.authorization.nonce -cnotmatch '^[0-9a-f]{32}$') { throw 'Live actor authorization nonce is invalid.' }
    } else {
        $unexpectedAuthorizationValues = @('signerThumbprint','authorizationSha256','signatureSha256','nonce') | Where-Object { -not [string]::IsNullOrEmpty([string]$Report.actor.authorization.$_) }
        if ([string]$Report.actor.authorization.status -cne 'NOT_APPLICABLE' -or @($unexpectedAuthorizationValues).Count -ne 0) { throw 'Synthetic actor authorization must remain NOT_APPLICABLE and empty.' }
    }

    # Exact initial/final candidate bindings.
    foreach ($phase in @('initial','final')) {
        $binding = $Report.bindings.$phase
        if ($null -eq $binding) { throw "bindings.$phase is required." }
        if ([string]$binding.sourceCommit -notmatch '^[0-9a-f]{40}$') { throw "bindings.$phase.sourceCommit must be 40-hex lowercase." }
        if ([string]$binding.sourceTree -notmatch '^[0-9a-f]{40}$') { throw "bindings.$phase.sourceTree must be 40-hex lowercase." }
        foreach ($name in @('receiptSha256','archiveSha256','packageManifestSha256','appSha256','coreSha256')) {
            if ([string]$binding.$name -notmatch '^[0-9A-F]{64}$') { throw "bindings.$phase.$name must be 64-hex uppercase." }
        }
    }
    if ([string]$Report.bindings.referenceHostProfileSha256 -cne '96D01ED15A536F2DF50B59B43CFDEB3683DCE8667AE2E7BF6A96124182FE13A3') { throw 'referenceHostProfileSha256 drifted.' }
    if ([string]$Report.bindings.rendererPolicySha256 -cne '1D37C9C39449556EB30F9AB5B734F0C5411CF4203321AF0B238993D017229E92') { throw 'rendererPolicySha256 drifted.' }

    # Lifecycle steps
    $lifecycleNames = @($Report.lifecycle.PSObject.Properties.Name)
    $expectedLifecycle = @('cleanInstall', 'sameVersionCandidateReplacement', 'rollback', 'uninstall')
    foreach ($req in $expectedLifecycle) {
        if (-not ($lifecycleNames -ccontains $req)) {
            throw "lifecycle is missing required step '$req'."
        }
    }
    if ($lifecycleNames.Count -ne $expectedLifecycle.Count) {
        throw 'lifecycle contains unexpected steps.'
    }

    # Residue
    if ([string]$Report.status -eq 'PASS') {
        if ([bool]$Report.residue.orphanedStagingPresent) { throw 'residue.orphanedStagingPresent must be false on passing report.' }
        if ([bool]$Report.residue.orphanedBackupPresent) { throw 'residue.orphanedBackupPresent must be false on passing report.' }
        if ([int]$Report.residue.activePipesRemaining -ne 0) { throw 'residue.activePipesRemaining must be 0 on passing report.' }
        if ([int]$Report.residue.activeProcessesRemaining -ne 0) { throw 'residue.activeProcessesRemaining must be 0 on passing report.' }
        if ([int]$Report.residue.activeListenersRemaining -ne 0) { throw 'residue.activeListenersRemaining must be 0 on passing report.' }
        if (-not [bool]$Report.residue.startupRegistryCleaned -or -not [bool]$Report.residue.shortcutsCleaned) { throw 'Registry and shortcut residue must be clean on passing report.' }
        if ([string]$Report.mode -ne 'DryRun') {
            if (-not [bool]$Report.lifecycle.cleanInstall.identityReceiptBound -or -not [bool]$Report.lifecycle.cleanInstall.installStateBound -or -not [bool]$Report.lifecycle.cleanInstall.startupRegistered) { throw 'Passing lifecycle did not observe a complete clean install.' }
            if (-not [bool]$Report.lifecycle.sameVersionCandidateReplacement.replacementObserved -or -not [bool]$Report.lifecycle.sameVersionCandidateReplacement.backupCreatedAndRetired -or -not [bool]$Report.lifecycle.sameVersionCandidateReplacement.userDataPreserved) { throw 'Passing lifecycle did not observe exact candidate replacement.' }
            if (-not [bool]$Report.lifecycle.rollback.rollbackObserved -or -not [bool]$Report.lifecycle.rollback.installRestoredOnFault) { throw 'Passing lifecycle did not observe rollback restoration.' }
            if (-not [bool]$Report.lifecycle.uninstall.installRootAbsent -or -not [bool]$Report.lifecycle.uninstall.startupRemoved -or -not [bool]$Report.lifecycle.uninstall.userDataPreserved) { throw 'Passing lifecycle did not observe complete uninstall.' }
        }
    }

    # Evidence boundary
    if ([string]$Report.evidenceBoundary.evidenceClass -cnotin @('Synthetic', 'CleanMachine')) { throw 'evidenceClass is invalid.' }
    if ([string]$Report.evidenceBoundary.actualHerdrRuntime -cne 'NOT_OBSERVED') { throw 'actualHerdrRuntime must be NOT_OBSERVED.' }
    if ([string]$Report.evidenceBoundary.independentReview -cne 'NOT_OBSERVED') { throw 'independentReview must be NOT_OBSERVED.' }
    if ([string]$Report.evidenceBoundary.humanGo -cne 'NOT_OBSERVED') { throw 'humanGo must be NOT_OBSERVED.' }
    if ([string]$Report.evidenceBoundary.releaseCredit -cne 'NOT_OBSERVED') { throw 'releaseCredit must be NOT_OBSERVED.' }

    if ([string]$Report.mode -eq 'Live' -and [string]$Report.status -eq 'PASS') {
        if ([string]$Report.evidenceBoundary.evidenceClass -ne 'CleanMachine') {
            throw "Live passing report must earn 'CleanMachine' evidence class."
        }
        if ([bool]$Report.evidenceBoundary.creditGranted -ne $true) {
            throw 'Live passing report must have creditGranted = true for install lifecycle.'
        }
    } else {
        if ([bool]$Report.evidenceBoundary.creditGranted -ne $false) {
            throw 'Non-live or non-passing report must have creditGranted = false.'
        }
    }
}
