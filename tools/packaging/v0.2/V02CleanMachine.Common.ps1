#requires -Version 5.1

Set-StrictMode -Version Latest

. (Join-Path $PSScriptRoot 'V02Packaging.Common.ps1')
. (Join-Path $PSScriptRoot 'V02PackageIdentity.Common.ps1')

$script:V02CleanMachineSchemaPath = Join-Path $PSScriptRoot 'clean-machine-report.schema.json'
$script:V02CleanMachineSchemaId = 'https://herdrops.local/schema/v0.2/clean-machine-report.schema.json'

function Get-V02MachineFingerprint {
    $raw = @(
        $env:COMPUTERNAME,
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
        [hashtable]$MockRegistryHive = $null
    )

    $install = [IO.Path]::GetFullPath($InstallRoot).TrimEnd('\', '/')
    $installParent = Split-Path -Path $install -Parent
    $installName = [IO.Path]::GetFileName($install)

    $orphanedStaging = $false
    $orphanedBackup = $false
    if (Test-Path -LiteralPath $installParent -PathType Container) {
        $stagingPattern = '^\.' + [regex]::Escape($installName) + '\.staging-[0-9a-f]{32}$'
        $backupPattern = '^\.' + [regex]::Escape($installName) + '\.backup-[0-9a-f]{32}$'
        $candidates = @(Get-ChildItem -LiteralPath $installParent -Directory -Force -ErrorAction SilentlyContinue)
        if (@($candidates | Where-Object { $_.Name -match $stagingPattern }).Count -gt 0) {
            $orphanedStaging = $true
        }
        if (@($candidates | Where-Object { $_.Name -match $backupPattern }).Count -gt 0) {
            $orphanedBackup = $true
        }
    }

    $startupState = Get-V02UserStartupState -ValueName $StartupValueName -MockRegistryHive $MockRegistryHive
    $startupCleaned = (-not $startupState.Exists)

    $activePipes = 0
    try {
        if ([IO.Directory]::Exists('\\.\pipe\')) {
            $pipeFiles = [IO.Directory]::GetFiles('\\.\pipe\', '*HerdrOps*')
            if ($null -ne $pipeFiles) {
                $activePipes = [int]$pipeFiles.Length
            }
        }
    } catch {
        $activePipes = 0
    }

    $activeProcesses = 0
    try {
        $appProcs = [Diagnostics.Process]::GetProcessesByName('HerdrOps.App')
        $coreProcs = [Diagnostics.Process]::GetProcessesByName('HerdrOps.Core')
        $activeProcesses = [int]($appProcs.Length + $coreProcs.Length)
    } catch {
        $activeProcesses = 0
    }

    $activeListeners = 0

    return [pscustomobject][ordered]@{
        orphanedStagingPresent = $orphanedStaging
        orphanedBackupPresent = $orphanedBackup
        startupRegistryCleaned = $startupCleaned
        shortcutsCleaned = $true
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
    [IO.File]::WriteAllText([IO.Path]::GetFullPath($Path), ($json + "`n"), (New-Object Text.UTF8Encoding($false)))
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
    if ([bool]$Report.machine.elevated) { throw 'machine.elevated must be false.' }
    if ([string]::IsNullOrWhiteSpace($Report.machine.machineName)) { throw 'machine.machineName must not be empty.' }
    if ([string]$Report.machine.machineFingerprint -notmatch '^[0-9A-F]{64}$') { throw 'machine.machineFingerprint must be 64-hex uppercase.' }

    # Actor
    Assert-V02ActorIdentities -OperatorIdentity $Report.actor.operator.identity -ObserverIdentity $Report.actor.observer.identity
    if ([string]$Report.actor.operator.role -cne 'EvidenceOperator') { throw "operator.role must be 'EvidenceOperator'." }
    if ([string]$Report.actor.observer.role -cne 'IndependentObserver') { throw "observer.role must be 'IndependentObserver'." }

    # Bindings
    if ([string]$Report.bindings.sourceCommit -notmatch '^[0-9a-f]{40}$') { throw 'sourceCommit must be 40-hex lowercase.' }
    if ([string]$Report.bindings.sourceTree -notmatch '^[0-9a-f]{40}$') { throw 'sourceTree must be 40-hex lowercase.' }
    if ([string]$Report.bindings.receiptSha256 -notmatch '^[0-9A-F]{64}$') { throw 'receiptSha256 must be 64-hex uppercase.' }
    if ([string]$Report.bindings.archiveSha256 -notmatch '^[0-9A-F]{64}$') { throw 'archiveSha256 must be 64-hex uppercase.' }
    if ([string]$Report.bindings.packageManifestSha256 -notmatch '^[0-9A-F]{64}$') { throw 'packageManifestSha256 must be 64-hex uppercase.' }
    if ([string]$Report.bindings.appSha256 -notmatch '^[0-9A-F]{64}$') { throw 'appSha256 must be 64-hex uppercase.' }
    if ([string]$Report.bindings.coreSha256 -notmatch '^[0-9A-F]{64}$') { throw 'coreSha256 must be 64-hex uppercase.' }
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
