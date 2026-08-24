#requires -Version 5.1

Set-StrictMode -Version Latest

. (Join-Path $PSScriptRoot 'V02Packaging.Common.ps1')
. (Join-Path $PSScriptRoot 'V02PackageIdentity.Common.ps1')

$script:V02CleanMachineSchemaPath = Join-Path $PSScriptRoot 'clean-machine-report.schema.json'
$script:V02CleanMachineSchemaId = 'https://herdrops.local/schema/v0.2/clean-machine-report.schema.json'

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

function Assert-V02LiveRootsAreDefault {
    param([Parameter(Mandatory = $true)][string]$InstallRoot,[Parameter(Mandatory = $true)][string]$UserDataRoot)
    # Trusted Known Folder defaults (SHGetKnownFolderPath), never the
    # caller-controlled LOCALAPPDATA environment variable, so a redirected
    # env var cannot make a spoofed root appear to be the exact default.
    $safeInstallRoot = [IO.Path]::GetFullPath($InstallRoot)
    $safeUserDataRoot = [IO.Path]::GetFullPath($UserDataRoot)
    $defaultInstall = [IO.Path]::GetFullPath((Get-V02DefaultInstallRoot))
    $defaultUserData = [IO.Path]::GetFullPath((Get-V02DefaultUserDataRoot))
    if (-not [StringComparer]::OrdinalIgnoreCase.Equals($safeInstallRoot,$defaultInstall) -or -not [StringComparer]::OrdinalIgnoreCase.Equals($safeUserDataRoot,$defaultUserData)) {
        throw 'Live mode requires the exact per-user HerdrOps install and user-data roots; test/custom roots are forbidden.'
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

function Assert-V02DeletePendingReportIdentity {
    param(
        [Parameter(Mandatory = $true)]$Handle,
        [Parameter(Mandatory = $true)]$Expected,
        [Parameter(Mandatory = $true)][string]$ExpectedPath
    )
    $current = Assert-V02SameHandleIdentity -Handle $Handle -Expected $Expected -ExpectedPath $ExpectedPath -Context 'clean-machine report'
    # Windows removes the pending pathname from NumberOfLinks while the handle
    # remains open.  Zero therefore proves that no hostile hardlink survives.
    if ($current.LinkCount -ne 0) { throw "clean-machine report must have no surviving links after delete-pending; observed $($current.LinkCount)." }
    return $current
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
    $stream = $null
    $created = $false
    $published = $false
    try {
        if (Test-Path -LiteralPath $full) { throw "Refusing to overwrite existing report: $full" }
        $bytes = (New-Object Text.UTF8Encoding($false)).GetBytes($json + "`n")
        # Direct CreateNew plus an exclusive read/write handle is the atomic
        # no-clobber publication boundary.  The same final-path handle remains
        # held through write, flush, byte verification, FileId and link checks.
        # GENERIC_READ|GENERIC_WRITE|DELETE, no sharing, CREATE_NEW.  DELETE is
        # required so a failed publication can retire this exact object without
        # ever releasing and reopening its reusable pathname.
        $reportHandle = [HerdrOps.V02DirectoryLeaseNative]::CreateFile($full,[uint32]3221291008,0,[IntPtr]::Zero,1,0x80,[IntPtr]::Zero)
        if ($null -eq $reportHandle -or $reportHandle.IsInvalid) {
            $errorCode = [Runtime.InteropServices.Marshal]::GetLastWin32Error()
            if ($null -ne $reportHandle) { $reportHandle.Dispose() }
            if ($errorCode -eq 80 -or $errorCode -eq 183) { throw "Refusing to overwrite existing report: $full" }
            throw "Could not create clean-machine report '$full' (Win32 $errorCode)."
        }
        try { $stream = [IO.FileStream]::new($reportHandle,[IO.FileAccess]::ReadWrite) }
        catch { $reportHandle.Dispose(); throw }
        $created = $true
        $reportIdentity = Get-V02HandleIdentity -Handle $stream.SafeFileHandle -Context 'clean-machine report'
        $null = Assert-V02SameHandleIdentity -Handle $stream.SafeFileHandle -Expected $reportIdentity -ExpectedPath $full -Context 'clean-machine report' -RequireSingleLink
        $stream.Write($bytes,0,$bytes.Length);$stream.Flush($true)
        $stream.Position = 0
        $sha = [Security.Cryptography.SHA256]::Create()
        try { $writtenSha = ([BitConverter]::ToString($sha.ComputeHash($stream))).Replace('-','') } finally { $sha.Dispose() }
        $sha = [Security.Cryptography.SHA256]::Create()
        try { $expectedSha = ([BitConverter]::ToString($sha.ComputeHash($bytes))).Replace('-','') } finally { $sha.Dispose() }
        $null = Assert-V02SameHandleIdentity -Handle $stream.SafeFileHandle -Expected $reportIdentity -ExpectedPath $full -Context 'clean-machine report' -RequireSingleLink
        if ($stream.Length -ne $bytes.Length -or $writtenSha -cne $expectedSha) { throw 'Published clean-machine report bytes changed.' }
        $published = $true
    } finally {
        try {
            if ($created -and -not $published -and $null -ne $stream) {
                # The exclusive CreateNew handle is the only cleanup authority.
                # Never close it and reopen this reusable pathname: a hostile leaf
                # could replace the failed report between those operations.
                $disposition = New-Object HerdrOps.V02FileDispositionInfo; $disposition.DeleteFile = $true
                if (-not [HerdrOps.V02DirectoryLeaseNative]::SetFileInformationByHandle($stream.SafeFileHandle,4,[ref]$disposition,4)) { throw "Failed report cleanup failed (Win32 $([Runtime.InteropServices.Marshal]::GetLastWin32Error()))." }
                # Delete-pending closes the hardlink race before the final exact
                # identity/link check.  If a hostile link already appeared, cancel
                # deletion while the original handle is still held and fail closed.
                try {
                    $null = Assert-V02DeletePendingReportIdentity -Handle $stream.SafeFileHandle -Expected $reportIdentity -ExpectedPath $full
                } catch {
                    $guardFailure = $_
                    $cancelDisposition = New-Object HerdrOps.V02FileDispositionInfo; $cancelDisposition.DeleteFile = $false
                    if (-not [HerdrOps.V02DirectoryLeaseNative]::SetFileInformationByHandle($stream.SafeFileHandle,4,[ref]$cancelDisposition,4)) {
                        throw "Failed report cleanup identity guard failed and delete cancellation failed (Win32 $([Runtime.InteropServices.Marshal]::GetLastWin32Error())): $($guardFailure.Exception.Message)"
                    }
                    throw $guardFailure
                }
            }
        } finally {
            if ($null -ne $stream) { $stream.Dispose() }
            try {
                $null = Assert-V02SameHandleIdentity -Handle $parentLease -Expected $parentLease.V02Identity -ExpectedPath $parentLease.V02Path -Context 'clean-machine report parent' -RequireSingleLink
            } finally { $parentLease.Dispose() }
        }
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
        [Parameter(Mandatory = $true)][ValidateSet('Synthetic', 'AutomatedLiveLifecycle')][string]$EvidenceClass,
        [bool]$CreditGranted = $false,
        [string]$FailureDetails = ''
    )

    return [pscustomobject][ordered]@{
        schemaVersion = 2
        reportKind = 'HerdrOps.V02AutomatedLiveLifecycleReport'
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
            independentAgentReview = 'NOT_OBSERVED'
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

    if ([int]$Report.schemaVersion -ne 2) { throw 'schemaVersion must be 2.' }
    if ([string]$Report.reportKind -cne 'HerdrOps.V02AutomatedLiveLifecycleReport') { throw "reportKind must be 'HerdrOps.V02AutomatedLiveLifecycleReport'." }
    if ([string]$Report.scope -cne 'InstallLifecycleOnly') { throw "scope must be 'InstallLifecycleOnly'." }
    if ([int]$Report.issue -ne 149) { throw 'issue must be 149.' }
    if ([string]$Report.packageVersion -cne '0.2.0') { throw "packageVersion must be '0.2.0'." }
    if ([string]$Report.profileId -cne 'herdrops-v0.2-package-software-only-issue-149') { throw "profileId must be 'herdrops-v0.2-package-software-only-issue-149'." }
    if ([string]$Report.status -cnotin @('PASS', 'FAIL', 'CANCELLED')) { throw 'status is invalid.' }
    if ([string]$Report.mode -cnotin @('DryRun', 'Fixture', 'Live')) { throw 'mode is invalid.' }
    if ([string]$Report.runId -notmatch '^[0-9a-f]{32}$') { throw 'runId is not a 32-hex string.' }

    $started = [DateTimeOffset]::MinValue
    $completed = [DateTimeOffset]::MinValue
    if (-not [DateTimeOffset]::TryParseExact([string]$Report.startedAtUtc, 'o', [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind, [ref]$started) -or $started.Offset -ne [TimeSpan]::Zero) {
        throw 'startedAtUtc must be an exact UTC round-trip timestamp.'
    }
    if (-not [DateTimeOffset]::TryParseExact([string]$Report.completedAtUtc, 'o', [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind, [ref]$completed) -or $completed.Offset -ne [TimeSpan]::Zero) {
        throw 'completedAtUtc must be an exact UTC round-trip timestamp.'
    }
    if ($completed -lt $started) { throw 'completedAtUtc must not precede startedAtUtc.' }
    if ($completed -gt [DateTimeOffset]::UtcNow.AddMinutes(5)) { throw 'completedAtUtc must not be in the future.' }

    if ([bool]$Report.actualHerdrStarted -ne $false) { throw 'actualHerdrStarted must be false.' }
    if ([bool]$Report.herdrOpsStarted -ne $false) { throw 'herdrOpsStarted must be false.' }
    if ([bool]$Report.networkContacted -ne $false) { throw 'networkContacted must be false.' }

    # Machine
    if ([string]$Report.mode -eq 'Live' -and [bool]$Report.machine.elevated) { throw 'Live machine.elevated must be false.' }
    if ([string]::IsNullOrWhiteSpace($Report.machine.machineName)) { throw 'machine.machineName must not be empty.' }
    if ([string]$Report.machine.machineFingerprint -notmatch '^[0-9A-F]{64}$') { throw 'machine.machineFingerprint must be 64-hex uppercase.' }

    # Targets must be absolute canonical non-system paths. The release gate
    # holds and binds this report together with the exact package candidate.
    foreach ($targetName in @('installRoot','userDataRoot')) {
        $targetValue = [string]$Report.targets.$targetName
        if ([string]::IsNullOrWhiteSpace($targetValue) -or -not [IO.Path]::IsPathRooted($targetValue)) { throw "targets.$targetName must be an absolute path." }
        $targetFull = [IO.Path]::GetFullPath($targetValue).TrimEnd('\','/')
        if (-not [StringComparer]::OrdinalIgnoreCase.Equals($targetFull,$targetValue.TrimEnd('\','/'))) { throw "targets.$targetName must be canonical." }
        Assert-V02NotSystemDirectory $targetFull
    }
    if ([StringComparer]::OrdinalIgnoreCase.Equals(([IO.Path]::GetFullPath([string]$Report.targets.installRoot)).TrimEnd('\','/'),([IO.Path]::GetFullPath([string]$Report.targets.userDataRoot)).TrimEnd('\','/'))) {
        throw 'targets.installRoot and targets.userDataRoot must be distinct.'
    }
    # Actor
    if (@($Report.actor.PSObject.Properties.Name).Count -ne 1 -or -not (@($Report.actor.PSObject.Properties.Name) -ccontains 'operator')) { throw 'actor must contain exactly operator.' }
    $operatorNames = @($Report.actor.operator.PSObject.Properties.Name)
    if ($operatorNames.Count -ne 2 -or -not ($operatorNames -ccontains 'identity') -or -not ($operatorNames -ccontains 'role')) { throw 'actor.operator must contain exactly identity and role.' }
    if ([string]::IsNullOrWhiteSpace([string]$Report.actor.operator.identity)) { throw 'operator.identity must not be empty.' }
    if ([string]$Report.actor.operator.role -cne 'EvidenceOperator') { throw "operator.role must be 'EvidenceOperator'." }
    if ([string]$Report.mode -eq 'Live') {
        if ([string]$Report.actor.operator.identity -cne [string]$Report.machine.userScope) { throw 'Live operator identity must equal the executing principal SID.' }
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
        if (@($Report.preflight).Count -eq 0) { throw 'Passing report must contain preflight observations.' }
        foreach ($check in @($Report.preflight)) {
            if ([string]::IsNullOrWhiteSpace([string]$check.name) -or [string]$check.status -cnotin @('PASS','NOT_APPLICABLE')) { throw "Passing report preflight '$([string]$check.name)' status must be PASS or NOT_APPLICABLE." }
            if ([string]$Report.mode -eq 'Live' -and [string]$check.status -cne 'PASS') { throw "Passing Live report preflight '$([string]$check.name)' status must be PASS." }
        }
        if ([string]$Report.mode -eq 'Live') {
            $requiredLivePreflight = @('non-elevated-token','live-machine-confirmation','identity-receipt-schema-and-hash','source-commit-match','source-tree-match')
            $observedLivePreflight = @($Report.preflight | ForEach-Object { [string]$_.name })
            if ($observedLivePreflight.Count -ne $requiredLivePreflight.Count -or @($requiredLivePreflight | Where-Object { $observedLivePreflight -cnotcontains $_ }).Count -ne 0) {
                throw 'Passing Live report must contain exactly the complete production preflight set.'
            }
        }
        if (-not [string]::IsNullOrEmpty([string]$Report.failureDetails)) { throw 'Passing report failureDetails must be empty.' }
        if ([bool]$Report.residue.orphanedStagingPresent) { throw 'residue.orphanedStagingPresent must be false on passing report.' }
        if ([bool]$Report.residue.orphanedBackupPresent) { throw 'residue.orphanedBackupPresent must be false on passing report.' }
        if ([int]$Report.residue.activePipesRemaining -ne 0) { throw 'residue.activePipesRemaining must be 0 on passing report.' }
        if ([int]$Report.residue.activeProcessesRemaining -ne 0) { throw 'residue.activeProcessesRemaining must be 0 on passing report.' }
        if ([int]$Report.residue.activeListenersRemaining -ne 0) { throw 'residue.activeListenersRemaining must be 0 on passing report.' }
        if (-not [bool]$Report.residue.startupRegistryCleaned -or -not [bool]$Report.residue.shortcutsCleaned) { throw 'Registry and shortcut residue must be clean on passing report.' }
        if ([string]$Report.mode -ne 'DryRun') {
            foreach ($stepName in @('cleanInstall','sameVersionCandidateReplacement','rollback','uninstall')) {
                if ([string]$Report.lifecycle.$stepName.status -cne 'PASS') { throw "Passing report lifecycle.$stepName.status must be PASS." }
            }
            if ([string]$Report.retainedData.markerStatus -cne 'PRESERVED' -or [int]$Report.retainedData.preservedFileCount -lt 1) {
                throw 'Passing lifecycle retainedData must record at least one PRESERVED file.'
            }
            if ([int]$Report.lifecycle.cleanInstall.installedFileCount -lt 1) { throw 'Passing lifecycle cleanInstall.installedFileCount must be positive.' }
            if (-not [bool]$Report.lifecycle.cleanInstall.identityReceiptBound -or -not [bool]$Report.lifecycle.cleanInstall.installStateBound -or -not [bool]$Report.lifecycle.cleanInstall.startupRegistered) { throw 'Passing lifecycle did not observe a complete clean install.' }
            if (-not [bool]$Report.lifecycle.sameVersionCandidateReplacement.replacementObserved -or -not [bool]$Report.lifecycle.sameVersionCandidateReplacement.backupCreatedAndRetired -or -not [bool]$Report.lifecycle.sameVersionCandidateReplacement.userDataPreserved) { throw 'Passing lifecycle did not observe exact candidate replacement.' }
            if ([string]$Report.lifecycle.sameVersionCandidateReplacement.backupVolumeSerialNumber -cnotmatch '^[0-9A-F]{8}$' -or [string]$Report.lifecycle.sameVersionCandidateReplacement.backupFileId -cnotmatch '^[0-9A-F]{16}$' -or [int]$Report.lifecycle.sameVersionCandidateReplacement.backupLinkCount -ne 1) { throw 'Passing replacement did not bind the exact single-link backup identity.' }
            if (-not [bool]$Report.lifecycle.rollback.rollbackObserved -or -not [bool]$Report.lifecycle.rollback.installRestoredOnFault) { throw 'Passing lifecycle did not observe rollback restoration.' }
            $rollbackMap=@{restoredSourceCommit='sourceCommit';restoredSourceTree='sourceTree';restoredReceiptSha256='receiptSha256';restoredArchiveSha256='archiveSha256';restoredPackageManifestSha256='packageManifestSha256';restoredAppSha256='appSha256';restoredCoreSha256='coreSha256'}
            foreach($name in $rollbackMap.Keys){$expectedName=$rollbackMap[$name];if([string]$Report.lifecycle.rollback.$name -cne [string]$Report.bindings.final.$expectedName){throw "Passing rollback $name does not equal the exact final candidate binding."}}
            if (-not [bool]$Report.lifecycle.uninstall.installRootAbsent -or -not [bool]$Report.lifecycle.uninstall.startupRemoved -or -not [bool]$Report.lifecycle.uninstall.userDataPreserved) { throw 'Passing lifecycle did not observe complete uninstall.' }
        }
    }

    # Evidence boundary
    $boundaryNames = @($Report.evidenceBoundary.PSObject.Properties.Name)
    $expectedBoundaryNames = @('evidenceClass','actualHerdrRuntime','independentAgentReview','releaseCredit','creditGranted')
    if ($boundaryNames.Count -ne $expectedBoundaryNames.Count -or @($expectedBoundaryNames | Where-Object { $boundaryNames -cnotcontains $_ }).Count -ne 0) { throw 'evidenceBoundary has an unexpected or missing property.' }
    if ($Report.evidenceBoundary.creditGranted -isnot [bool]) { throw 'evidenceBoundary.creditGranted must be a native JSON boolean.' }
    if ([string]$Report.evidenceBoundary.evidenceClass -cnotin @('Synthetic', 'AutomatedLiveLifecycle')) { throw 'evidenceClass is invalid.' }
    if ([string]$Report.evidenceBoundary.actualHerdrRuntime -cne 'NOT_OBSERVED') { throw 'actualHerdrRuntime must be NOT_OBSERVED.' }
    if ([string]$Report.evidenceBoundary.independentAgentReview -cne 'NOT_OBSERVED') { throw 'independentAgentReview must be NOT_OBSERVED.' }
    if ([string]$Report.evidenceBoundary.releaseCredit -cne 'NOT_OBSERVED') { throw 'releaseCredit must be NOT_OBSERVED.' }

    if ([string]$Report.mode -eq 'Live' -and [string]$Report.status -eq 'PASS') {
        if ([string]$Report.evidenceBoundary.evidenceClass -ne 'AutomatedLiveLifecycle') {
            throw "Live passing report must earn 'AutomatedLiveLifecycle' evidence class."
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
