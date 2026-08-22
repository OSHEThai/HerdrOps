#requires -Version 5.1

[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [string]$BindingPath,

    [Parameter(Mandatory = $false)]
    [string]$InitialArchivePath,

    [Parameter(Mandatory = $false)]
    [long]$InitialArchiveBytes = 0,

    [Parameter(Mandatory = $false)]
    [string]$InitialArchiveSha256,

    [Parameter(Mandatory = $false)]
    [string]$InitialManifestSha256,

    [Parameter(Mandatory = $false)]
    [string]$InitialContentSha256,

    [Parameter(Mandatory = $false)]
    [string]$InitialPackageVersion = '0.7.0',

    [Parameter(Mandatory = $false)]
    [string]$InitialSourceCommit,

    [Parameter(Mandatory = $false)]
    [string]$CandidateArchivePath,

    [Parameter(Mandatory = $false)]
    [long]$CandidateArchiveBytes = 0,

    [Parameter(Mandatory = $false)]
    [string]$CandidateArchiveSha256,

    [Parameter(Mandatory = $false)]
    [string]$CandidateManifestSha256,

    [Parameter(Mandatory = $false)]
    [string]$CandidateContentSha256,

    [Parameter(Mandatory = $false)]
    [string]$CandidatePackageVersion = '1.0.0',

    [Parameter(Mandatory = $false)]
    [string]$CandidateSourceCommit,

    [Parameter(Mandatory = $false)]
    [string]$ExpectedSourceCommit,

    [Parameter(Mandatory = $false)]
    [string]$ExpectedSourceTree,

    [Parameter(Mandatory = $false)]
    [string]$ExpectedParentCommit,

    [Parameter(Mandatory = $false)]
    [string]$ExpectedMachineName,

    [Parameter(Mandatory = $false)]
    [string]$ExpectedMachineFingerprint,

    # Accepted-Beta provenance inputs
    [Parameter(Mandatory = $false)]
    [string]$BetaReportPath,

    [Parameter(Mandatory = $false)]
    [long]$BetaReportBytes = 0,

    [Parameter(Mandatory = $false)]
    [string]$BetaReportSha256,

    [Parameter(Mandatory = $false)]
    [string]$BetaReportStatus = 'ACCEPTED',

    [Parameter(Mandatory = $false)]
    [string]$BetaReportSourceCommit,

    [Parameter(Mandatory = $false)]
    [string]$BetaReportSourceTree,

    [Parameter(Mandatory = $false)]
    [string]$InstallRoot,

    [Parameter(Mandatory = $false)]
    [string]$UserDataRoot,

    [Parameter(Mandatory = $false)]
    [string]$SimulationRoot,

    [Parameter(Mandatory = $false)]
    [string]$ReportDestination,

    [Parameter(Mandatory = $false)]
    [string]$RetainedDataRelativePath = 'state\issue-44-harness.marker',

    [Parameter(Mandatory = $false)]
    [string]$RetainedDataSha256,

    [Parameter(Mandatory = $false)]
    [ValidateSet('create-test-marker', 'preseeded')]
    [string]$RetainedDataMode = 'create-test-marker',

    [Parameter(Mandatory = $false)]
    [scriptblock]$InstallerRunner,

    [Parameter(Mandatory = $false)]
    [scriptblock]$FirstRunRunner,

    [Parameter(Mandatory = $false)]
    [switch]$IUnderstandLiveMutation,

    [Parameter(Mandatory = $false)]
    [string]$LiveConfirmationToken,

    [Parameter(Mandatory = $false)]
    [switch]$AllowLiveRetainedDataSeed,

    [Parameter(Mandatory = $false)]
    [ValidateSet('Live', 'Fixture', 'DryRun')]
    [string]$Mode = 'Live'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$acceptanceCommonPath = Join-Path $PSScriptRoot 'HerdrOps.InstallAcceptance.Common.ps1'
if (-not (Test-Path -LiteralPath $acceptanceCommonPath -PathType Leaf)) {
    throw "HerdrOps acceptance common library is missing: $acceptanceCommonPath"
}
. $acceptanceCommonPath

$installerCommonPath = Join-Path $PSScriptRoot '..\installer\Installer.Common.ps1'
if (-not (Test-Path -LiteralPath $installerCommonPath -PathType Leaf)) {
    throw "Installer common library is missing: $installerCommonPath"
}
. $installerCommonPath

$processCleanupPath = Join-Path $PSScriptRoot '..\lib\V04ProcessCleanup.ps1'
if (Test-Path -LiteralPath $processCleanupPath -PathType Leaf) {
    . $processCleanupPath
}

$script:AcceptanceIssue = 44
$script:AcceptanceVersion = 'v1.0.0'
$script:LiveTokenValue = 'HERDROPS-ISSUE-44-LIVE-FILESYSTEM'
$script:RunId = [Guid]::NewGuid().ToString('N')
$script:StartedAtUtc = [DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ss.fffffffZ', [Globalization.CultureInfo]::InvariantCulture)
$script:Transcript = New-Object System.Collections.ArrayList
$script:PreflightChecks = New-Object System.Collections.ArrayList
$script:CleanMachineFilesystemObserved = $false
$script:TranscriptSequence = 1
$script:OwnedStagingDirectory = $null
$script:OwnedSimulationDirectory = $null
$script:HarnessMarkerCreated = $false

# These defaults deliberately make a preflight failure reportable.  Binding
# parsing happens before target setup, so every report field must already have
# a schema-safe value if that parse fails.
$machineName = [Environment]::MachineName
if ([string]::IsNullOrWhiteSpace($machineName)) { $machineName = 'NOT_OBSERVED' }
try { $machineFingerprint = Get-AcceptanceMachineFingerprint } catch { $machineFingerprint = ('0' * 64) }
$isElevated = $false
$actualHeadCommit = 'NOT_OBSERVED'
$actualHeadTree = 'NOT_OBSERVED'
$actualParentCommit = 'NOT_OBSERVED'
$installRootFull = ''
$userDataRootFull = ''
$installParent = ''
$retainedDataFullPath = ''
$bindingParseFailure = ''
$bindingWasProvided = -not [string]::IsNullOrWhiteSpace($BindingPath)
$initialArtifactBinding = $null
$upgradeArtifactBinding = $null
$initialBindingPackageRoot = ''
$initialBindingHashRecordPath = ''
$candidateBindingPackageRoot = ''
$candidateBindingHashRecordPath = ''
$initialAcceptedArtifact = $null
$candidateAcceptedArtifact = $null
$initialDurableManifest = $null
$candidateDurableManifest = $null
$betaReportFull = ''
$betaReportJson = $null

function Add-OperatorTranscript {
    param(
        [Parameter(Mandatory = $true)][string]$Phase,
        [Parameter(Mandatory = $true)][string]$Action,
        [Parameter(Mandatory = $true)][ValidateSet('PASS', 'FAIL', 'SKIPPED', 'CANCELLED', 'NOT_RUN')][string]$Status,
        [Parameter(Mandatory = $true)][ValidateSet('None', 'FixtureTempOnly', 'LiveFilesystem')][string]$Effect,
        [Parameter(Mandatory = $true)][string]$Details,
        [Parameter(Mandatory = $true)][string]$PathBinding
    )

    [void]$script:Transcript.Add([ordered]@{
        sequence = $script:TranscriptSequence
        phase = $Phase
        action = $Action
        status = $Status
        effect = $Effect
        details = $Details
        pathBinding = $PathBinding
    })
    $script:TranscriptSequence++
}

function Add-OperatorPreflightCheck {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][ValidateSet('PASS', 'FAIL', 'NOT_APPLICABLE')][string]$Status,
        [Parameter(Mandatory = $true)][string]$Details
    )

    [void]$script:PreflightChecks.Add([ordered]@{
        name = $Name
        status = $Status
        details = $Details
    })
}

function Get-OperatorUtcNow {
    return [DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ss.fffffffZ', [Globalization.CultureInfo]::InvariantCulture)
}

function Get-FileSha256AndBytes {
    param([Parameter(Mandatory = $true)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "File not found: $Path"
    }
    $bytes = [IO.File]::ReadAllBytes($Path)
    $sha256 = [System.Security.Cryptography.SHA256]::Create()
    try {
        $hashBytes = $sha256.ComputeHash($bytes)
        $hashHex = ([BitConverter]::ToString($hashBytes)).Replace('-', '').ToUpperInvariant()
    } finally {
        $sha256.Dispose()
    }
    return [pscustomobject][ordered]@{
        Bytes = $bytes
        Length = [int64]$bytes.Length
        Sha256 = $hashHex
    }
}

function Assert-RunnerResultPass {
    param(
        $Result,
        [Parameter(Mandatory = $true)][string]$Context
    )

    if ($null -eq $Result) {
        throw "$Context runner returned null result."
    }
    if (-not ($Result.PSObject.Properties['Status'])) {
        throw "$Context runner result is missing required 'Status' property."
    }
    if ([string]$Result.Status -cne 'PASS') {
        throw "$Context runner returned non-PASS status: '$($Result.Status)'."
    }
}

function Invoke-WithStagedArchiveLocked {
    param(
        [Parameter(Mandatory = $true)][string]$StagedPath,
        [Parameter(Mandatory = $true)][long]$ExpectedBytes,
        [Parameter(Mandatory = $true)][string]$ExpectedSha256,
        [Parameter(Mandatory = $true)][string]$Context,
        [Parameter(Mandatory = $true)][scriptblock]$Action
    )

    if (-not (Test-Path -LiteralPath $StagedPath -PathType Leaf)) {
        throw "$Context staged archive was not found at $StagedPath."
    }

    # Open with FileAccess.Read and FileShare.Read (denies write/delete to others during execution)
    $fileStream = [System.IO.File]::Open($StagedPath, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::Read)
    try {
        $sha256 = [System.Security.Cryptography.SHA256]::Create()
        try {
            $hashBytes = $sha256.ComputeHash($fileStream)
            $hashHex = ([BitConverter]::ToString($hashBytes)).Replace('-', '').ToUpperInvariant()
        } finally {
            $sha256.Dispose()
        }

        if ($fileStream.Length -ne $ExpectedBytes) {
            throw "$Context staged archive byte length mismatch while locked: expected $ExpectedBytes, observed $($fileStream.Length)."
        }
        if ($hashHex -cne $ExpectedSha256.ToUpperInvariant()) {
            throw "$Context staged archive SHA-256 mismatch while locked: expected '$ExpectedSha256', observed '$hashHex'."
        }
        $fileStream.Position = 0

        & $Action
    } finally {
        $fileStream.Dispose()
    }
}

function Resolve-Issue44ManifestEvidence {
    param(
        [Parameter(Mandatory = $true)][string]$ArchivePath,
        [string]$ExpectedManifestPath,
        [Parameter(Mandatory = $true)][long]$ExpectedBytes,
        [Parameter(Mandatory = $true)][string]$ExpectedSha256,
        [Parameter(Mandatory = $true)][string]$ArtifactName
    )

    $archiveFull = Get-AcceptanceFullPath -Path $ArchivePath
    $archiveParent = Split-Path -Path $archiveFull -Parent
    $candidates = New-Object System.Collections.ArrayList
    foreach ($candidate in @(
            $ExpectedManifestPath,
            (Join-Path $archiveParent 'package-manifest.json'),
            (Join-Path $archiveParent 'package\package-manifest.json'))) {
        if ([string]::IsNullOrWhiteSpace($candidate)) { continue }
        $candidateFull = Get-AcceptanceFullPath -Path $candidate
        if (@($candidates | Where-Object { $_.Equals($candidateFull, [StringComparison]::OrdinalIgnoreCase) }).Count -eq 0) {
            [void]$candidates.Add($candidateFull)
        }
    }

    $mismatchDetails = New-Object System.Collections.ArrayList
    foreach ($candidateFull in @($candidates.ToArray())) {
        if (-not (Test-Path -LiteralPath $candidateFull -PathType Leaf)) { continue }
        Assert-OperatorNoReparse -Path $candidateFull
        $data = Get-FileSha256AndBytes -Path $candidateFull
        if ($data.Length -ne $ExpectedBytes -or $data.Sha256 -cne $ExpectedSha256.ToUpperInvariant()) {
            [void]$mismatchDetails.Add("$candidateFull bytes=$($data.Length) sha256=$($data.Sha256)")
            continue
        }
        return [pscustomobject][ordered]@{
            Path = $candidateFull
            PackageRoot = (Split-Path -Path $candidateFull -Parent)
            Bytes = [int64]$data.Length
            Sha256 = $data.Sha256
        }
    }

    $suffix = if ($mismatchDetails.Count -gt 0) { " Mismatches: $($mismatchDetails -join '; ')" } else { '' }
    throw "$ArtifactName durable package-manifest.json evidence was not found with the accepted bytes/hash.$suffix"
}

function Get-Issue44NestedPropertyValue {
    param(
        [Parameter(Mandatory = $true)]$Object,
        [Parameter(Mandatory = $true)][string[]]$Path
    )

    $current = $Object
    foreach ($segment in $Path) {
        if ($null -eq $current -or $current -is [string]) { return $null }
        $property = $current.PSObject.Properties | Where-Object { $_.Name -ceq $segment }
        if (@($property).Count -ne 1) { return $null }
        $current = $property[0].Value
    }
    return $current
}

function Get-Issue44FirstNestedValue {
    param(
        [Parameter(Mandatory = $true)]$Object,
        [Parameter(Mandatory = $true)][string[][]]$Paths
    )

    foreach ($path in $Paths) {
        $value = Get-Issue44NestedPropertyValue -Object $Object -Path $path
        if ($null -ne $value -and -not [string]::IsNullOrWhiteSpace([string]$value)) {
            return $value
        }
    }
    return $null
}

function Assert-Issue44NonPlaceholder {
    param(
        [AllowNull()]$Value,
        [Parameter(Mandatory = $true)][string]$Context
    )

    $text = [string]$Value
    if ([string]::IsNullOrWhiteSpace($text) -or $text -match '(?i)^(PENDING|NOT[_ -]?OBSERVED|REPLACE[_ -]?WITH|TODO|UNKNOWN)$') {
        throw "$Context is missing or still a placeholder."
    }
    return $text
}

function Assert-Issue44AcceptedBetaReport {
    param(
        [Parameter(Mandatory = $true)]$Report,
        [Parameter(Mandatory = $true)][string]$ReportStatus,
        [Parameter(Mandatory = $true)][string]$ExpectedSourceCommit,
        [Parameter(Mandatory = $true)][string]$ExpectedSourceTree
    )

    if ($ReportStatus -cne 'ACCEPTED') {
        throw "Live accepted-Beta status binding must be exactly 'ACCEPTED', not '$ReportStatus'."
    }
    Assert-AcceptanceExactProperties -Object $Report -Names @(
        'schemaVersion', 'reportKind', 'issue', 'candidate', 'decision',
        'signer', 'role', 'signedAtUtc', 'signature') -Context 'Accepted-Beta human UAT report'
    if ([int]$Report.schemaVersion -ne 1 -or
        [string]$Report.reportKind -cne 'HerdrOps.V07HumanUatAcceptance' -or
        [int]$Report.issue -ne 40 -or
        [string]$Report.decision -cne 'ACCEPTED') {
        throw 'Accepted-Beta evidence is not the exact accepted HerdrOps.V07HumanUatAcceptance contract.'
    }
    Assert-AcceptanceExactProperties -Object $Report.candidate -Names @('commit', 'tree') -Context 'Accepted-Beta candidate'
    $actualCommit = [string]$Report.candidate.commit
    $actualTree = [string]$Report.candidate.tree
    if ([string]$actualCommit -cne $ExpectedSourceCommit) {
        throw "Accepted-Beta report sourceCommit mismatch: expected '$ExpectedSourceCommit', observed '$actualCommit'."
    }
    if ([string]$actualTree -cne $ExpectedSourceTree) {
        throw "Accepted-Beta report sourceTree mismatch: expected '$ExpectedSourceTree', observed '$actualTree'."
    }

    [void](Assert-Issue44NonPlaceholder -Value $Report.signer -Context 'Accepted-Beta human signer')
    [void](Assert-Issue44NonPlaceholder -Value $Report.role -Context 'Accepted-Beta human role')
    $signedAt = Assert-Issue44NonPlaceholder -Value $Report.signedAtUtc -Context 'Accepted-Beta human date'
    try { [void][DateTimeOffset]::Parse($signedAt, [Globalization.CultureInfo]::InvariantCulture) } catch { throw 'Accepted-Beta human date is not a valid timestamp.' }
    [void](Assert-Issue44NonPlaceholder -Value $Report.signature -Context 'Accepted-Beta human signature')
}

function Get-Issue44ProcessIdentity {
    param([Parameter(Mandatory = $true)][Diagnostics.Process]$Process)

    try {
        $startUtc = $Process.StartTime.ToUniversalTime()
        $path = [string]$Process.Path
        if ([string]::IsNullOrWhiteSpace($path) -or -not (Test-Path -LiteralPath $path -PathType Leaf)) {
            throw 'Executable path is unavailable.'
        }
        $file = Get-FileSha256AndBytes -Path $path
        return [pscustomobject][ordered]@{
            Id = [int]$Process.Id
            StartUtcTicks = [int64]$startUtc.Ticks
            StartUtc = $startUtc.ToString('o', [Globalization.CultureInfo]::InvariantCulture)
            Path = $path
            Sha256 = [string]$file.Sha256
        }
    } catch {
        throw "Cannot establish process identity for PID $($Process.Id): $($_.Exception.Message)"
    }
}

function Assert-Issue44ProcessIdentity {
    param(
        [Parameter(Mandatory = $true)]$Identity,
        [Parameter(Mandatory = $true)][Diagnostics.Process]$Process,
        [Parameter(Mandatory = $true)][string]$Context
    )

    $current = Get-Issue44ProcessIdentity -Process $Process
    if ([int]$current.Id -ne [int]$Identity.Id -or [int64]$current.StartUtcTicks -ne [int64]$Identity.StartUtcTicks) {
        throw "$Context process identity changed for PID $($Identity.Id); refusing to touch a possible PID reuse."
    }
    if (-not [string]::IsNullOrWhiteSpace([string]$Identity.Path) -and
        -not [string]::IsNullOrWhiteSpace([string]$current.Path) -and
        [string]$current.Path -cne [string]$Identity.Path) {
        throw "$Context process path changed for PID $($Identity.Id); refusing to touch a possible PID reuse."
    }
    if ([string]$current.Sha256 -cne [string]$Identity.Sha256) {
        throw "$Context executable hash changed for PID $($Identity.Id); refusing unbound process evidence."
    }
}

function Get-Issue44StatePipeName {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    try {
        if ($null -eq $identity.User -or [string]::IsNullOrWhiteSpace($identity.User.Value)) {
            throw 'Current Windows user SID is unavailable for Core readiness probe.'
        }
        $text = "HerdrOps.StateIpc.v2|$($identity.User.Value)"
        $sha = [Security.Cryptography.SHA256]::Create()
        try {
            $hash = ([BitConverter]::ToString($sha.ComputeHash((New-Object System.Text.UTF8Encoding($false)).GetBytes($text)))).Replace('-', '').ToLowerInvariant()
        } finally { $sha.Dispose() }
        return "herdrops-state-v2-$($hash.Substring(0, 24))"
    } finally { $identity.Dispose() }
}

function Write-Issue44PipeFrame {
    param([Parameter(Mandatory = $true)][IO.Stream]$Stream, [Parameter(Mandatory = $true)]$Object)

    $json = $Object | ConvertTo-Json -Depth 30 -Compress
    $bytes = (New-Object System.Text.UTF8Encoding($false)).GetBytes($json)
    if ($bytes.Length -le 0 -or $bytes.Length -gt (4 * 1024 * 1024)) { throw 'Core readiness frame is outside the bounded size.' }
    $writer = New-Object IO.BinaryWriter($Stream)
    $writer.Write([int]$bytes.Length)
    $writer.Write($bytes)
    $writer.Flush()
}

function Read-Issue44PipeFrame {
    param(
        [Parameter(Mandatory = $true)][IO.Stream]$Stream,
        [Parameter(Mandatory = $true)][DateTime]$DeadlineUtc
    )

    function Read-BoundedExact {
        param([byte[]]$Buffer, [int]$Offset, [int]$Count)
        $total = 0
        while ($total -lt $Count) {
            $remaining = [int][Math]::Floor(($DeadlineUtc - [DateTime]::UtcNow).TotalMilliseconds)
            if ($remaining -le 0) { throw 'Core readiness pipe read timed out.' }
            $cts = New-Object Threading.CancellationTokenSource
            try {
                $cts.CancelAfter($remaining)
                $task = $Stream.ReadAsync($Buffer, $Offset + $total, $Count - $total, $cts.Token)
                try { $read = $task.GetAwaiter().GetResult() } catch [OperationCanceledException] { throw 'Core readiness pipe read timed out.' }
                if ($read -le 0) { throw 'Core readiness pipe ended before a complete frame was received.' }
                $total += $read
            } finally { $cts.Dispose() }
        }
    }

    $header = New-Object byte[] 4
    Read-BoundedExact -Buffer $header -Offset 0 -Count 4
    $length = [BitConverter]::ToInt32($header, 0)
    if ($length -le 0 -or $length -gt (4 * 1024 * 1024)) { throw 'Core readiness frame length is outside the bounded size.' }
    $bytes = New-Object byte[] $length
    Read-BoundedExact -Buffer $bytes -Offset 0 -Count $length
    $json = (New-Object System.Text.UTF8Encoding($false, $true)).GetString($bytes)
    return ConvertFrom-StrictPackageJson -Json $json -Description 'Issue #44 Core readiness frame'
}

function Wait-Issue44CoreSemanticReadiness {
    param(
        [Parameter(Mandatory = $true)][Diagnostics.Process]$CoreProcess,
        [Parameter(Mandatory = $true)]$CoreIdentity,
        [Parameter(Mandatory = $true)][Diagnostics.Process]$AppProcess,
        [Parameter(Mandatory = $true)]$AppIdentity,
        [Parameter(Mandatory = $true)][int]$TimeoutMilliseconds
    )

    $deadline = [DateTime]::UtcNow.AddMilliseconds($TimeoutMilliseconds)
    $pipeName = Get-Issue44StatePipeName
    $lastRetryMessage = 'real App window and Core pipe are not yet ready'
    while ([DateTime]::UtcNow -lt $deadline) {
        if ($CoreProcess.HasExited) { throw "Core exited before semantic readiness: $($CoreProcess.ExitCode)." }
        if ($AppProcess.HasExited) { throw "App exited before semantic readiness: $($AppProcess.ExitCode)." }
        Assert-Issue44ProcessIdentity -Identity $CoreIdentity -Process $CoreProcess -Context 'Core readiness'
        Assert-Issue44ProcessIdentity -Identity $AppIdentity -Process $AppProcess -Context 'App readiness'
        $AppProcess.Refresh()
        if (-not $AppProcess.Responding -or $AppProcess.MainWindowHandle -eq [IntPtr]::Zero) {
            $lastRetryMessage = 'the exact launched App has not exposed a responsive main window'
            Start-Sleep -Milliseconds 100
            continue
        }
        $pipe = $null
        try {
            # This probe deliberately sends no HerdrOps.App envelope.  Only the
            # real launched App may claim that production protocol identity.
            # A bounded connect proves that the exact launched Core owns a
            # reachable current-user listener while the real App UI is ready.
            $pipe = New-Object System.IO.Pipes.NamedPipeClientStream('.', $pipeName, [IO.Pipes.PipeDirection]::InOut, [IO.Pipes.PipeOptions]::Asynchronous)
            $remaining = [int][Math]::Max(1, [Math]::Min(500, ($deadline - [DateTime]::UtcNow).TotalMilliseconds))
            $pipe.Connect($remaining)
            return [pscustomobject][ordered]@{
                Ready = $true
                PipeName = $pipeName
                RuntimeHealthStatus = 'REAL_APP_UI_AND_CORE_LISTENER_READY'
                Details = "Real App PID $($AppIdentity.Id) start $($AppIdentity.StartUtc) path/hash bound and responsive; Core PID $($CoreIdentity.Id) start $($CoreIdentity.StartUtc) path/hash bound with reachable current-user state pipe. No App source was fabricated by the operator."
            }
        } catch [TimeoutException] {
            $lastRetryMessage = $_.Exception.Message
        } catch [IO.IOException] {
            $lastRetryMessage = $_.Exception.Message
        } finally {
            if ($null -ne $pipe) { $pipe.Dispose() }
        }
        Start-Sleep -Milliseconds 100
    }
    throw "Real App/Core readiness timed out after $TimeoutMilliseconds milliseconds: $lastRetryMessage"
}

function Stage-AcceptedArchiveAtomically {
    param(
        [Parameter(Mandatory = $true)][string]$SourcePath,
        [Parameter(Mandatory = $true)][string]$StagingDirectory,
        [Parameter(Mandatory = $true)][string]$ArtifactName,
        [long]$ExpectedBytes = 0,
        [string]$ExpectedSha256,
        [string]$ExpectedManifestSha256,
        [string]$ExpectedContentSha256,
        [string]$ExpectedPackageVersion
    )

    $sourceFull = Get-AcceptanceFullPath -Path $SourcePath
    if (-not (Test-Path -LiteralPath $sourceFull -PathType Leaf)) {
        throw "$ArtifactName archive was not found at $sourceFull."
    }
    Assert-AcceptanceNoReparsePath -Path $sourceFull

    # Single byte read of source archive
    $bytes = [IO.File]::ReadAllBytes($sourceFull)
    $sha256 = [System.Security.Cryptography.SHA256]::Create()
    try {
        $hashBytes = $sha256.ComputeHash($bytes)
        $hashHex = ([BitConverter]::ToString($hashBytes)).Replace('-', '').ToUpperInvariant()
    } finally {
        $sha256.Dispose()
    }

    if ($ExpectedBytes -gt 0 -and $bytes.Length -ne $ExpectedBytes) {
        throw "$ArtifactName archive byte count mismatch: expected $ExpectedBytes, observed $($bytes.Length)."
    }
    if (-not [string]::IsNullOrWhiteSpace($ExpectedSha256) -and $hashHex -cne $ExpectedSha256.ToUpperInvariant()) {
        throw "$ArtifactName archive SHA-256 mismatch: expected '$ExpectedSha256', observed '$hashHex'."
    }

    $fileName = [IO.Path]::GetFileName($sourceFull)
    $stagedPath = Join-Path $StagingDirectory $fileName
    [IO.File]::WriteAllBytes($stagedPath, $bytes)

    # Re-verify staged archive bytes
    $stagedData = Get-FileSha256AndBytes -Path $stagedPath
    if ($stagedData.Sha256 -cne $hashHex -or $stagedData.Length -ne $bytes.Length) {
        throw "Staged $ArtifactName archive failed byte integrity verification."
    }

    # Extract the canonical manifest contract.  The production package schema
    # names the inventory `files`; `contents` is deliberately rejected.
    $zip = [System.IO.Compression.ZipFile]::OpenRead($stagedPath)
    $manifestBytes = $null
    $manifestSha256 = ''
    $contentSha256 = ''
    $manifestJson = $null
    $contentEntries = New-Object System.Collections.ArrayList
    $stagedManifestPath = Join-Path $StagingDirectory "$ArtifactName-package-manifest.json"

    try {
        $manifestEntriesInArchive = @($zip.Entries | Where-Object {
                [string]$_.FullName -ceq 'package/package-manifest.json' -or
                [string]$_.FullName -ceq 'package-manifest.json'
            })
        if ($manifestEntriesInArchive.Count -ne 1) {
            throw "$ArtifactName archive is missing package-manifest.json."
        }
        $manifestEntry = $manifestEntriesInArchive[0]
        $archivePrefix = if ([string]$manifestEntry.FullName -ceq 'package/package-manifest.json') { 'package/' } else { '' }
        $stream = $manifestEntry.Open()
        $ms = New-Object System.IO.MemoryStream
        try {
            $stream.CopyTo($ms)
            $manifestBytes = $ms.ToArray()
        } finally {
            $stream.Dispose()
            $ms.Dispose()
        }
        $sha = [System.Security.Cryptography.SHA256]::Create()
        try {
            $manifestSha256 = ([BitConverter]::ToString($sha.ComputeHash($manifestBytes))).Replace('-', '').ToUpperInvariant()
        } finally {
            $sha.Dispose()
        }
        if (-not [string]::IsNullOrWhiteSpace($ExpectedManifestSha256) -and $manifestSha256 -cne $ExpectedManifestSha256.ToUpperInvariant()) {
            throw "$ArtifactName manifest SHA-256 mismatch: expected '$ExpectedManifestSha256', observed '$manifestSha256'."
        }

        $manifestRaw = (New-Object System.Text.UTF8Encoding($false, $true)).GetString($manifestBytes)
        $manifestJson = ConvertFrom-StrictPackageJson -Json $manifestRaw -Description "$ArtifactName package manifest"
        Assert-ExactJsonPropertyOrder -Object $manifestJson -ExpectedNames @(
            'schemaVersion', 'issue', 'productId', 'packageVersion', 'targetFramework',
            'runtimeIdentifier', 'deploymentModel', 'userDataPolicy', 'contentHashAlgorithm',
            'fileCount', 'totalBytes', 'contentSha256', 'files', 'evidenceClass') -Description "$ArtifactName package manifest"
        foreach ($numeric in @(
                @{ Name = 'schemaVersion'; Value = $manifestJson.schemaVersion },
                @{ Name = 'issue'; Value = $manifestJson.issue },
                @{ Name = 'fileCount'; Value = $manifestJson.fileCount },
                @{ Name = 'totalBytes'; Value = $manifestJson.totalBytes })) {
            Assert-JsonIntegerValue -Value $numeric.Value -Name "$ArtifactName manifest $($numeric.Name)"
        }
        foreach ($text in @(
                @{ Name = 'productId'; Value = $manifestJson.productId },
                @{ Name = 'packageVersion'; Value = $manifestJson.packageVersion },
                @{ Name = 'targetFramework'; Value = $manifestJson.targetFramework },
                @{ Name = 'runtimeIdentifier'; Value = $manifestJson.runtimeIdentifier },
                @{ Name = 'deploymentModel'; Value = $manifestJson.deploymentModel },
                @{ Name = 'userDataPolicy'; Value = $manifestJson.userDataPolicy },
                @{ Name = 'contentHashAlgorithm'; Value = $manifestJson.contentHashAlgorithm },
                @{ Name = 'contentSha256'; Value = $manifestJson.contentSha256 },
                @{ Name = 'evidenceClass'; Value = $manifestJson.evidenceClass })) {
            Assert-JsonStringValue -Value $text.Value -Name "$ArtifactName manifest $($text.Name)"
        }
        if ([int]$manifestJson.schemaVersion -ne 1 -or
            [string]$manifestJson.productId -cne 'HerdrOps' -or
            [string]$manifestJson.targetFramework -cne 'net10.0-windows' -or
            [string]$manifestJson.runtimeIdentifier -cne 'win-x64' -or
            [string]$manifestJson.deploymentModel -cne 'per-user-directory' -or
            [string]$manifestJson.userDataPolicy -cne 'retain-on-uninstall' -or
            [string]$manifestJson.contentHashAlgorithm -cne 'SHA-256' -or
            [string]$manifestJson.evidenceClass -cne 'Static') {
            throw "$ArtifactName package manifest identity is invalid."
        }
        if (-not [string]::IsNullOrWhiteSpace($ExpectedPackageVersion) -and
            [string]$manifestJson.packageVersion -cne $ExpectedPackageVersion) {
            throw "$ArtifactName package version mismatch: expected '$ExpectedPackageVersion', observed '$($manifestJson.packageVersion)'."
        }
        Assert-AcceptanceSha256 -Value ([string]$manifestJson.contentSha256) -Context "$ArtifactName manifest contentSha256"
        $contentSha256 = [string]$manifestJson.contentSha256

        # Write manifest as a real staging file
        [IO.File]::WriteAllBytes($stagedManifestPath, $manifestBytes)

        # Validate the `files` inventory, its totals, and every corresponding
        # ZIP entry.  The manifest itself is an archive entry but is not part
        # of the contentSha256 inventory.
        $manifestFiles = @($manifestJson.files)
        if ($null -eq $manifestJson.files -or $manifestFiles.Count -ne [int]$manifestJson.fileCount) {
            throw "$ArtifactName manifest fileCount does not match its files array."
        }
        $manifestTotalBytes = [int64]0
        $zipExpectedEntries = New-Object System.Collections.ArrayList
        $seenManifestPaths = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
        $zipEntryHashes = New-Object System.Collections.ArrayList
        foreach ($item in $manifestFiles) {
                Assert-ExactJsonPropertyOrder -Object $item -ExpectedNames @('path', 'length', 'sha256') -Description "$ArtifactName manifest files entry"
                $itemRelPath = [string]$item.path
                $itemLength = [int64]$item.length
                $itemSha256 = [string]$item.sha256
                Assert-JsonStringValue -Value $item.path -Name "$ArtifactName manifest files.path"
                Assert-JsonIntegerValue -Value $item.length -Name "$ArtifactName manifest files.length"
                Assert-JsonStringValue -Value $item.sha256 -Name "$ArtifactName manifest files.sha256"
                Assert-AcceptanceSha256 -Value $itemSha256.ToUpperInvariant() -Context "$ArtifactName manifest files '$itemRelPath' sha256"
                if ($itemLength -lt 0 -or
                    [string]::IsNullOrWhiteSpace($itemRelPath) -or
                    $itemRelPath -ceq 'package-manifest.json' -or
                    [IO.Path]::IsPathRooted($itemRelPath) -or
                    $itemRelPath.StartsWith('/', [StringComparison]::Ordinal) -or
                    $itemRelPath.Contains('\') -or
                    $itemRelPath.Contains('//') -or
                    $itemRelPath.EndsWith('/', [StringComparison]::Ordinal) -or
                    $itemRelPath -match '(^|/)\.\.?(/|$)' -or
                    $itemRelPath -match '[\x00-\x1F<>:"|?*]') {
                    throw "$ArtifactName manifest files path is unsafe: '$itemRelPath'."
                }
                if (-not $seenManifestPaths.Add($itemRelPath)) {
                    throw "$ArtifactName manifest files contains a duplicate Windows path: '$itemRelPath'."
                }
                $manifestTotalBytes += $itemLength
                $zipEntryName = "$archivePrefix$itemRelPath"
                $entryMatches = @($zip.Entries | Where-Object { [string]$_.FullName -ceq $zipEntryName })
                if ($entryMatches.Count -ne 1) {
                    throw "$ArtifactName archive must contain exactly one entry '$zipEntryName' declared in manifest files."
                }
                $entryInZip = $entryMatches[0]
                if ($null -eq $entryInZip) {
                    throw "$ArtifactName archive is missing entry '$zipEntryName' declared in manifest."
                }
                if ($entryInZip.Length -ne $itemLength) {
                    throw "$ArtifactName archive entry '$zipEntryName' length mismatch: expected $itemLength, observed $($entryInZip.Length)."
                }

                # Compute hash of entry from zip stream
                $entryStream = $entryInZip.Open()
                $entryMs = New-Object System.IO.MemoryStream
                try {
                    $entryStream.CopyTo($entryMs)
                    $entryBytes = $entryMs.ToArray()
                } finally {
                    $entryStream.Dispose()
                    $entryMs.Dispose()
                }
                $entrySha = [System.Security.Cryptography.SHA256]::Create()
                try {
                    $entryHash = ([BitConverter]::ToString($entrySha.ComputeHash($entryBytes))).Replace('-', '').ToUpperInvariant()
                } finally { $entrySha.Dispose() }
                if ($entryHash -cne $itemSha256.ToUpperInvariant()) {
                    throw "$ArtifactName archive entry '$zipEntryName' hash mismatch: expected '$itemSha256', observed '$entryHash'."
                }

                [void]$contentEntries.Add([pscustomobject][ordered]@{
                    Path = $itemRelPath
                    Length = $itemLength
                    Sha256 = $itemSha256.ToUpperInvariant()
                })
                [void]$zipEntryHashes.Add([pscustomobject][ordered]@{
                    Path = $itemRelPath
                    Length = $itemLength
                    Sha256 = $itemSha256.ToUpperInvariant()
                })
                [void]$zipExpectedEntries.Add([pscustomobject][ordered]@{
                    Path = $zipEntryName
                    Length = $itemLength
                    Sha256 = $itemSha256.ToUpperInvariant()
                })
        }
        if ([int64]$manifestJson.totalBytes -ne $manifestTotalBytes) {
            throw "$ArtifactName manifest totalBytes does not match files entries."
        }

        $manifestArchiveHash = $sha256 = [System.Security.Cryptography.SHA256]::Create()
        try {
            $manifestArchiveHashValue = ([BitConverter]::ToString($manifestArchiveHash.ComputeHash($manifestBytes))).Replace('-', '').ToUpperInvariant()
        } finally { $manifestArchiveHash.Dispose() }
        [void]$zipExpectedEntries.Add([pscustomobject][ordered]@{
            Path = [string]$manifestEntry.FullName
            Length = [int64]$manifestBytes.Length
            Sha256 = $manifestArchiveHashValue
        })

        # Enumerate every archive entry, including the manifest, and reject
        # unlisted, duplicate, directory, traversal, device-like, or unsafe names.
        $zipActualEntries = New-Object System.Collections.ArrayList
        $seenZipNames = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
        foreach ($entry in @($zip.Entries)) {
            $entryName = [string]$entry.FullName
            if ([string]::IsNullOrWhiteSpace($entryName) -or
                $entryName.EndsWith('/', [StringComparison]::Ordinal) -or
                $entryName.Contains('\') -or
                $entryName.StartsWith('/', [StringComparison]::Ordinal) -or
                $entryName.Contains('//') -or
                $entryName -match '(^|/)\.\.?(/|$)' -or
                $entryName -match '[\x00-\x1F<>:"|?*]' -or
                [IO.Path]::IsPathRooted($entryName)) {
                throw "$ArtifactName archive contains an unsafe or non-file entry: '$entryName'."
            }
            if (-not $seenZipNames.Add($entryName)) {
                throw "$ArtifactName archive contains a duplicate Windows path: '$entryName'."
            }
            $entryStream = $entry.Open()
            $entrySha = [System.Security.Cryptography.SHA256]::Create()
            try {
                $entryHash = ([BitConverter]::ToString($entrySha.ComputeHash($entryStream))).Replace('-', '').ToUpperInvariant()
            } finally {
                $entrySha.Dispose()
                $entryStream.Dispose()
            }
            [void]$zipActualEntries.Add([pscustomobject][ordered]@{
                Path = $entryName
                Length = [int64]$entry.Length
                Sha256 = $entryHash
            })
        }
        $expectedSorted = @(Sort-PackageEntriesOrdinal -Entries @($zipExpectedEntries.ToArray()))
        $actualSorted = @(Sort-PackageEntriesOrdinal -Entries @($zipActualEntries.ToArray()))
        if ($actualSorted.Count -ne $expectedSorted.Count) {
            throw "$ArtifactName archive entry count does not match manifest files plus package-manifest.json."
        }
        for ($entryIndex = 0; $entryIndex -lt $expectedSorted.Count; $entryIndex++) {
            if ([string]$actualSorted[$entryIndex].Path -cne [string]$expectedSorted[$entryIndex].Path -or
                [int64]$actualSorted[$entryIndex].Length -ne [int64]$expectedSorted[$entryIndex].Length -or
                [string]$actualSorted[$entryIndex].Sha256 -cne [string]$expectedSorted[$entryIndex].Sha256) {
                throw "$ArtifactName archive entry mismatch at index ${entryIndex}: expected '$($expectedSorted[$entryIndex].Path)'."
            }
        }

        # Recompute canonical contentSha256
        $canonicalText = Get-CanonicalPackageContentText -Entries $zipEntryHashes
        $recomputedContentSha256 = Get-Sha256ForText -Text $canonicalText
        if ($recomputedContentSha256 -cne $contentSha256) {
            throw "$ArtifactName recomputed contentSha256 ($recomputedContentSha256) does not match manifest contentSha256 ($contentSha256)."
        }
        if (-not [string]::IsNullOrWhiteSpace($ExpectedContentSha256) -and $recomputedContentSha256 -cne $ExpectedContentSha256.ToUpperInvariant()) {
            throw "$ArtifactName contentSha256 mismatch: expected '$ExpectedContentSha256', observed '$recomputedContentSha256'."
        }
    } finally {
        $zip.Dispose()
    }

    return [pscustomobject][ordered]@{
        SourcePath = $sourceFull
        StagedPath = $stagedPath
        StagedManifestPath = $stagedManifestPath
        Length = [int64]$bytes.Length
        Sha256 = $hashHex
        ManifestBytes = [int64]$manifestBytes.Length
        ManifestSha256 = $manifestSha256
        ContentSha256 = $contentSha256
        Manifest = $manifestJson
        ContentEntries = @($contentEntries.ToArray())
    }
}

function Assert-OperatorNoReparse {
    param([Parameter(Mandatory = $true)][string]$Path)

    Assert-AcceptanceNoReparsePath -Path $Path
    if (Test-Path -LiteralPath $Path) {
        Assert-AcceptanceTreeNoReparse -Path $Path -Context 'Operator path'
    }
}

function Write-Issue44ReportDurably {
    param(
        [Parameter(Mandatory = $true)]$Report,
        [Parameter(Mandatory = $true)][string]$Path
    )

    $unresolvedInstallRoot = Join-Path ([IO.Path]::GetTempPath()) ('.herdrops-issue44-unresolved-install-' + $script:RunId)
    $unresolvedUserDataRoot = Join-Path ([IO.Path]::GetTempPath()) ('.herdrops-issue44-unresolved-data-' + $script:RunId)
    $destination = Assert-AcceptanceReportPath `
        -Path $Path `
        -InstallRoot $unresolvedInstallRoot `
        -UserDataRoot $unresolvedUserDataRoot `
        -AllowExternalParent:($Mode -eq 'Live')
    $parent = Split-Path -Path $destination -Parent
    if ([string]::IsNullOrWhiteSpace($parent) -or -not (Test-Path -LiteralPath $parent -PathType Container)) {
        throw "Explicit ReportDestination parent does not exist: '$parent'."
    }
    Assert-AcceptanceNoReparsePath -Path $parent
    if (Test-Path -LiteralPath $destination) {
        throw "Explicit ReportDestination already exists; refusing overwrite: '$destination'."
    }
    $temporary = Join-Path $parent ('.issue44-report-' + $script:RunId + '.tmp')
    try {
        $json = $Report | ConvertTo-Json -Depth 100
        $bytes = (New-Object System.Text.UTF8Encoding($false)).GetBytes($json + [Environment]::NewLine)
        $stream = New-Object IO.FileStream($temporary, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
        try {
            $stream.Write($bytes, 0, $bytes.Length)
            $stream.Flush($true)
        } finally { $stream.Dispose() }
        [IO.File]::Move($temporary, $destination)
        if (-not (Test-Path -LiteralPath $destination -PathType Leaf)) {
            throw "Durable report publication could not be verified at '$destination'."
        }
        return $destination
    } finally {
        if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary -Force -ErrorAction SilentlyContinue }
    }
}

# 1. Parse JSON binding if provided.  Keep the failure inside the reportable
# lifecycle so malformed preflight input still produces a schema-valid FAIL.
if (-not [string]::IsNullOrWhiteSpace($BindingPath)) {
    try {
        $bindingFullPath = Get-AcceptanceFullPath -Path $BindingPath
        if (-not (Test-Path -LiteralPath $bindingFullPath -PathType Leaf)) {
            throw "Live binding file was not found: $bindingFullPath"
        }
        Assert-OperatorNoReparse -Path $bindingFullPath
        $binding = Read-AcceptanceJsonFile -Path $bindingFullPath -Context 'Issue #44 live binding'
        Assert-AcceptanceExactProperties -Object $binding -Names @(
            'schemaVersion', 'issue', 'acceptanceVersion', 'mode', 'machineRole',
            'machineName', 'machineFingerprint', 'sourceCommit', 'initialArtifact',
            'upgradeArtifact', 'installRoot', 'userDataRoot', 'reportPath',
            'retainedDataRelativePath', 'retainedDataSha256', 'retainedDataMode') -Context 'Issue #44 live binding'

        if ([int]$binding.schemaVersion -ne 1 -or [int]$binding.issue -ne 44 -or [string]$binding.acceptanceVersion -cne 'v1.0.0') {
            throw 'Live binding schema version, issue, or acceptanceVersion is invalid.'
        }
        $Mode = [string]$binding.mode
        $ExpectedMachineName = [string]$binding.machineName
        $ExpectedMachineFingerprint = [string]$binding.machineFingerprint
        $ExpectedSourceCommit = [string]$binding.sourceCommit
        $CandidateSourceCommit = [string]$binding.sourceCommit

        $initialArtifactBinding = $binding.initialArtifact
        Assert-AcceptanceExactProperties -Object $initialArtifactBinding -Names @(
            'packageRoot', 'archivePath', 'hashRecordPath', 'productId', 'displayName',
            'packagingIssue', 'packageVersion', 'targetFramework', 'runtimeIdentifier',
            'deploymentModel', 'userDataPolicy', 'sourceCommit', 'manifestSha256',
            'archiveSha256', 'contentSha256') -Context 'Initial artifact binding'

        $InitialArchivePath = [string]$initialArtifactBinding.archivePath
        $InitialArchiveSha256 = [string]$initialArtifactBinding.archiveSha256
        $InitialManifestSha256 = [string]$initialArtifactBinding.manifestSha256
        $InitialContentSha256 = [string]$initialArtifactBinding.contentSha256
        $InitialPackageVersion = [string]$initialArtifactBinding.packageVersion
        $InitialSourceCommit = [string]$initialArtifactBinding.sourceCommit
        $initialBindingPackageRoot = [string]$initialArtifactBinding.packageRoot
        $initialBindingHashRecordPath = [string]$initialArtifactBinding.hashRecordPath

        $upgradeArtifactBinding = $binding.upgradeArtifact
        Assert-AcceptanceExactProperties -Object $upgradeArtifactBinding -Names @(
            'packageRoot', 'archivePath', 'hashRecordPath', 'productId', 'displayName',
            'packagingIssue', 'packageVersion', 'targetFramework', 'runtimeIdentifier',
            'deploymentModel', 'userDataPolicy', 'sourceCommit', 'manifestSha256',
            'archiveSha256', 'contentSha256') -Context 'Upgrade artifact binding'

        $CandidateArchivePath = [string]$upgradeArtifactBinding.archivePath
        $CandidateArchiveSha256 = [string]$upgradeArtifactBinding.archiveSha256
        $CandidateManifestSha256 = [string]$upgradeArtifactBinding.manifestSha256
        $CandidateContentSha256 = [string]$upgradeArtifactBinding.contentSha256
        $CandidatePackageVersion = [string]$upgradeArtifactBinding.packageVersion
        $CandidateSourceCommit = [string]$upgradeArtifactBinding.sourceCommit
        $candidateBindingPackageRoot = [string]$upgradeArtifactBinding.packageRoot
        $candidateBindingHashRecordPath = [string]$upgradeArtifactBinding.hashRecordPath

        $InstallRoot = [string]$binding.installRoot
        $UserDataRoot = [string]$binding.userDataRoot
        $ReportDestination = [string]$binding.reportPath
        $RetainedDataRelativePath = [string]$binding.retainedDataRelativePath
        $RetainedDataSha256 = [string]$binding.retainedDataSha256
        $RetainedDataMode = [string]$binding.retainedDataMode
    } catch {
        $bindingParseFailure = $_.Exception.Message
        if ($Mode -notin @('Live', 'Fixture', 'DryRun')) { $Mode = 'Live' }
    }
}

$repositoryRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..\..')).Path
$status = 'PASS'
$failureDetails = ''

$targetsReport = [ordered]@{
    installRoot = ''
    userDataRoot = ''
    reportPath = $(if ([string]::IsNullOrWhiteSpace($ReportDestination)) { 'NOT_SPECIFIED' } else { $ReportDestination })
    simulationRoot = $(if ([string]::IsNullOrWhiteSpace($SimulationRoot)) { 'NONE' } else { $SimulationRoot })
    installPathPolicy = '%LOCALAPPDATA%\Programs\HerdrOps'
    userDataPathPolicy = '%LOCALAPPDATA%\HerdrOps'
    userDataPolicy = 'retain-on-uninstall'
}

$lifecycle = [ordered]@{
    cleanInstall = [ordered]@{
        status = 'NOT_RUN'
        expectedVersion = $InitialPackageVersion
        installedFileHashes = @()
        installRootPresent = $false
        packageVersionObserved = 'NOT_OBSERVED'
        retainedDataStatus = 'NOT_RUN'
        retainedDataSha256 = 'NOT_OBSERVED'
        details = 'Not yet executed.'
    }
    upgrade = [ordered]@{
        status = 'NOT_RUN'
        expectedVersion = $CandidatePackageVersion
        installedFileHashes = @()
        installRootPresent = $false
        packageVersionObserved = 'NOT_OBSERVED'
        retainedDataStatus = 'NOT_RUN'
        retainedDataSha256 = 'NOT_OBSERVED'
        details = 'Not yet executed.'
    }
    rollback = [ordered]@{
        status = 'NOT_RUN'
        expectedVersion = $InitialPackageVersion
        installedFileHashes = @()
        installRootPresent = $false
        packageVersionObserved = 'NOT_OBSERVED'
        retainedDataStatus = 'NOT_RUN'
        retainedDataSha256 = 'NOT_OBSERVED'
        details = 'Not yet executed.'
    }
    uninstall = [ordered]@{
        status = 'NOT_RUN'
        expectedVersion = $InitialPackageVersion
        installedFileHashes = @()
        installRootPresent = $false
        packageVersionObserved = 'NOT_OBSERVED'
        retainedDataStatus = 'NOT_RUN'
        retainedDataSha256 = 'NOT_OBSERVED'
        details = 'Not yet executed.'
    }
}

$cleanup = [ordered]@{
    status = 'NOT_RUN'
    attempted = $false
    simulationRoot = $(if ([string]::IsNullOrWhiteSpace($SimulationRoot)) { 'NONE' } else { $SimulationRoot })
    simulationRootRemoved = $false
    ownedStageRemoved = $false
    ownedBackupRemoved = $false
    harnessSeededDataMarkerRemoved = $false
    retainedDataLeftIntact = $true
    residuals = @()
    details = 'Not yet executed.'
}

$initialArtifactReport = $null
$upgradeArtifactReport = $null

try {
    Add-OperatorTranscript -Phase 'Preflight' -Action 'initialize-operator' -Status 'PASS' -Effect 'None' -Details "Issue #44 live operator initialized in mode '$Mode'." -PathBinding 'none'

    if (-not [string]::IsNullOrWhiteSpace($bindingParseFailure)) {
        Add-OperatorPreflightCheck -Name 'live-binding-parse' -Status 'FAIL' -Details $bindingParseFailure
        throw "Issue #44 binding preflight failed: $bindingParseFailure"
    }
    if ($Mode -eq 'Live' -and -not $bindingWasProvided) {
        Add-OperatorPreflightCheck -Name 'live-binding-required' -Status 'FAIL' -Details 'Live mode requires an exact JSON binding with expanded package roots and hash-record sidecars.'
        throw 'Live mode requires -BindingPath; direct unbound Live invocation is not accepted.'
    }

    # Preflight Check 1: OS Platform
    if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) {
        throw 'Issue #44 acceptance operator requires a Windows NT host.'
    }
    Add-OperatorPreflightCheck -Name 'operating-system-platform' -Status 'PASS' -Details 'Host is Windows NT.'

    # Preflight Check 2: Elevation Policy (Live mode requires non-elevated standard process)
    $isElevated = Test-AcceptanceIsElevated
    if ($Mode -eq 'Live' -and $isElevated) {
        throw 'Issue #44 live acceptance must run under a standard, non-elevated user account.'
    }
    Add-OperatorPreflightCheck -Name 'process-elevation-policy' -Status 'PASS' -Details "Elevation check passed (Elevated=$isElevated)."

    # Preflight Check 3: Designated Clean Machine Identity & Fingerprint
    $machineName = [Environment]::MachineName
    if ([string]::IsNullOrWhiteSpace($machineName)) { $machineName = 'NOT_OBSERVED' }
    $machineFingerprint = Get-AcceptanceMachineFingerprint
    if ($Mode -eq 'Live') {
        if ([string]::IsNullOrWhiteSpace($ExpectedMachineName)) {
            throw 'Live mode requires non-empty exact -ExpectedMachineName.'
        }
        if ([string]::IsNullOrWhiteSpace($ExpectedMachineFingerprint)) {
            throw 'Live mode requires non-empty exact -ExpectedMachineFingerprint.'
        }
    }
    if (-not [string]::IsNullOrWhiteSpace($ExpectedMachineName) -and $machineName -cne $ExpectedMachineName) {
        throw "Designated clean machine name mismatch: expected '$ExpectedMachineName', observed '$machineName'."
    }
    if (-not [string]::IsNullOrWhiteSpace($ExpectedMachineFingerprint) -and $machineFingerprint -cne $ExpectedMachineFingerprint) {
        throw "Designated clean machine fingerprint mismatch: expected '$ExpectedMachineFingerprint', observed '$machineFingerprint'."
    }
    Add-OperatorPreflightCheck -Name 'designated-machine-fingerprint' -Status 'PASS' -Details "Machine '$machineName' fingerprint '$machineFingerprint' verified."

    # Preflight Check 4: Git Source Commit, Tree, Parent & Working Tree Verification
    $gitCommitOutput = @(& git -C $repositoryRoot rev-parse --verify 'HEAD^{commit}' 2>&1 | ForEach-Object { [string]$_ })
    if ($LASTEXITCODE -ne 0 -or $gitCommitOutput.Count -ne 1 -or $gitCommitOutput[0].Trim() -cnotmatch '^[0-9a-f]{40}$') {
        throw 'Could not resolve exact repository HEAD commit SHA.'
    }
    $actualHeadCommit = $gitCommitOutput[0].Trim().ToLowerInvariant()

    if ($Mode -eq 'Live' -and [string]::IsNullOrWhiteSpace($ExpectedSourceCommit)) {
        throw 'Live mode requires non-empty exact -ExpectedSourceCommit.'
    }
    if (-not [string]::IsNullOrWhiteSpace($ExpectedSourceCommit) -and $actualHeadCommit -cne $ExpectedSourceCommit.ToLowerInvariant()) {
        throw "Repository HEAD commit '$actualHeadCommit' does not match expected source commit '$ExpectedSourceCommit'."
    }
    if (-not [string]::IsNullOrWhiteSpace($CandidateSourceCommit) -and $CandidateSourceCommit.ToLowerInvariant() -cne $actualHeadCommit) {
        throw "Candidate source commit '$CandidateSourceCommit' does not match repository HEAD commit '$actualHeadCommit'."
    }

    $gitTreeOutput = @(& git -C $repositoryRoot rev-parse --verify "$actualHeadCommit^{tree}" 2>&1 | ForEach-Object { [string]$_ })
    if ($LASTEXITCODE -ne 0 -or $gitTreeOutput.Count -ne 1 -or $gitTreeOutput[0].Trim() -cnotmatch '^[0-9a-f]{40}$') {
        throw 'Could not resolve exact repository source tree SHA.'
    }
    $actualHeadTree = $gitTreeOutput[0].Trim().ToLowerInvariant()
    if ($Mode -eq 'Live' -and [string]::IsNullOrWhiteSpace($ExpectedSourceTree)) {
        throw 'Live mode requires non-empty exact -ExpectedSourceTree.'
    }
    if (-not [string]::IsNullOrWhiteSpace($ExpectedSourceTree) -and $actualHeadTree -cne $ExpectedSourceTree.ToLowerInvariant()) {
        throw "Repository source tree '$actualHeadTree' does not match expected source tree '$ExpectedSourceTree'."
    }

    $gitParentOutput = @(& git -C $repositoryRoot rev-parse --verify "$actualHeadCommit^1" 2>&1 | ForEach-Object { [string]$_ })
    if ($LASTEXITCODE -eq 0 -and $gitParentOutput.Count -eq 1 -and $gitParentOutput[0].Trim() -cmatch '^[0-9a-f]{40}$') {
        $actualParentCommit = $gitParentOutput[0].Trim().ToLowerInvariant()
        if (-not [string]::IsNullOrWhiteSpace($ExpectedParentCommit) -and $actualParentCommit -cne $ExpectedParentCommit.ToLowerInvariant()) {
            throw "Repository parent commit '$actualParentCommit' does not match expected parent commit '$ExpectedParentCommit'."
        }
    }

    $gitStatusOutput = @(& git -C $repositoryRoot status --porcelain=v1 --untracked-files=all 2>&1 | ForEach-Object { [string]$_ })
    if ($LASTEXITCODE -ne 0 -or $gitStatusOutput.Count -ne 0) {
        throw "Release work requires a clean checkout. Pending status: $($gitStatusOutput -join '; ')"
    }
    Add-OperatorPreflightCheck -Name 'repository-source-commit-clean' -Status 'PASS' -Details "Clean repository HEAD $actualHeadCommit tree $actualHeadTree verified."

    # Preflight Check 5: Mode & Runner Restrictions (Live rejects injected runners, Fixture requires both)
    if ($Mode -eq 'Live') {
        if ($null -ne $InstallerRunner -or $null -ne $FirstRunRunner) {
            throw 'Live mode MUST NOT use injected -InstallerRunner or -FirstRunRunner. Only production paths can grant CleanMachine evidence.'
        }
        if (-not $IUnderstandLiveMutation) {
            throw 'Live mode requires explicit -IUnderstandLiveMutation switch.'
        }
        if ($LiveConfirmationToken -cne $script:LiveTokenValue) {
            throw "Live mode requires exact -LiveConfirmationToken '$($script:LiveTokenValue)'."
        }
        if ($RetainedDataMode -eq 'create-test-marker' -and -not $AllowLiveRetainedDataSeed) {
            throw 'Live mode with create-test-marker requires explicit -AllowLiveRetainedDataSeed switch.'
        }
        Add-OperatorPreflightCheck -Name 'live-filesystem-safeguards' -Status 'PASS' -Details 'Live mutation confirmation token verified and injected runners rejected.'
    } else {
        if ($Mode -eq 'Fixture') {
            if ($null -eq $InstallerRunner -or $null -eq $FirstRunRunner) {
                throw 'Fixture mode requires both an injected -InstallerRunner and -FirstRunRunner.'
            }
        }
        Add-OperatorPreflightCheck -Name 'live-filesystem-safeguards' -Status 'NOT_APPLICABLE' -Details "Running in non-live mode ($Mode)."
    }

    # Preflight Check 6: Accepted-Beta Provenance Verification
    if ($Mode -eq 'Live') {
        if ([string]::IsNullOrWhiteSpace($BetaReportPath)) {
            throw 'Live mode requires non-empty -BetaReportPath pointing to accepted-Beta evidence.'
        }
        if ($BetaReportBytes -le 0) {
            throw 'Live mode requires non-empty -BetaReportBytes (>0).'
        }
        if ([string]::IsNullOrWhiteSpace($BetaReportSha256)) {
            throw 'Live mode requires non-empty -BetaReportSha256.'
        }
        if ([string]::IsNullOrWhiteSpace($BetaReportSourceCommit)) {
            throw 'Live mode requires non-empty -BetaReportSourceCommit.'
        }
        if ([string]::IsNullOrWhiteSpace($BetaReportSourceTree)) {
            throw 'Live mode requires non-empty -BetaReportSourceTree.'
        }
    }

    if (-not [string]::IsNullOrWhiteSpace($BetaReportPath)) {
        $betaReportFull = Get-AcceptanceFullPath -Path $BetaReportPath
        if (-not (Test-Path -LiteralPath $betaReportFull -PathType Leaf)) {
            throw "Accepted-Beta provenance report was not found: $betaReportFull"
        }
        Assert-AcceptanceNoReparsePath -Path $betaReportFull
        $betaReportData = Get-FileSha256AndBytes -Path $betaReportFull
        if ($BetaReportBytes -gt 0 -and $betaReportData.Length -ne $BetaReportBytes) {
            throw "Accepted-Beta provenance report byte count mismatch: expected $BetaReportBytes, observed $($betaReportData.Length)."
        }
        if (-not [string]::IsNullOrWhiteSpace($BetaReportSha256) -and $betaReportData.Sha256 -cne $BetaReportSha256.ToUpperInvariant()) {
            throw "Accepted-Beta provenance report SHA-256 mismatch: expected '$BetaReportSha256', observed '$($betaReportData.Sha256)'."
        }
        $betaReportJson = Read-AcceptanceJsonFile -Path $betaReportFull -Context 'Accepted-Beta provenance report'
        if ($Mode -eq 'Live') {
            Assert-AcceptanceSha256 -Value $BetaReportSha256.ToUpperInvariant() -Context 'Accepted-Beta report SHA-256'
            if ($BetaReportSourceCommit -notmatch '^[0-9a-f]{40}$' -or
                $BetaReportSourceTree -notmatch '^[0-9a-f]{40}$') {
                throw 'Accepted-Beta sourceCommit and sourceTree must be exact lowercase 40-character commit/tree values.'
            }
            if ($InitialSourceCommit -notmatch '^[0-9a-f]{40}$' -or $BetaReportSourceCommit -cne $InitialSourceCommit) {
                throw 'Accepted-Beta sourceCommit must equal the accepted initial artifact sourceCommit.'
            }
            $resolvedBetaTreeOutput = @(& git -C $repositoryRoot rev-parse --verify "$BetaReportSourceCommit^{tree}" 2>&1 | ForEach-Object { [string]$_ })
            if ($LASTEXITCODE -ne 0 -or $resolvedBetaTreeOutput.Count -ne 1 -or
                $resolvedBetaTreeOutput[0].Trim() -cnotmatch '^[0-9a-f]{40}$') {
                throw 'Accepted-Beta sourceCommit cannot be resolved independently to an exact tree in this repository.'
            }
            $resolvedBetaTree = $resolvedBetaTreeOutput[0].Trim().ToLowerInvariant()
            if ($resolvedBetaTree -cne $BetaReportSourceTree) {
                throw "Accepted-Beta sourceTree '$BetaReportSourceTree' does not match git tree '$resolvedBetaTree' resolved from sourceCommit '$BetaReportSourceCommit'."
            }
            Assert-Issue44AcceptedBetaReport `
                -Report $betaReportJson `
                -ReportStatus $BetaReportStatus `
                -ExpectedSourceCommit $BetaReportSourceCommit `
                -ExpectedSourceTree $BetaReportSourceTree
        }
        Add-OperatorPreflightCheck -Name 'accepted-beta-provenance' -Status 'PASS' -Details "Beta report verified at '$betaReportFull'."
    } else {
        Add-OperatorPreflightCheck -Name 'accepted-beta-provenance' -Status 'NOT_APPLICABLE' -Details 'No external Beta report path specified.'
    }

    # Preflight Check 7: Target Path Policies and Reparse Safety (Simulation root containment in Fixture)
    if ($Mode -eq 'Live') {
        if ([string]::IsNullOrWhiteSpace($InstallRoot)) {
            $InstallRoot = Get-DefaultHerdrOpsInstallRoot
        }
        if ([string]::IsNullOrWhiteSpace($UserDataRoot)) {
            $UserDataRoot = Get-DefaultHerdrOpsUserDataRoot
        }
        $installRootFull = Get-AcceptanceFullPath -Path $InstallRoot
        $userDataRootFull = Get-AcceptanceFullPath -Path $UserDataRoot
    } else {
        if ([string]::IsNullOrWhiteSpace($SimulationRoot)) {
            $SimulationRoot = Join-Path $env:TEMP "HerdrOps.simulation-$($script:RunId)"
            New-Item -ItemType Directory -Path $SimulationRoot -Force | Out-Null
            $script:OwnedSimulationDirectory = $SimulationRoot
        }
        $simRootFull = Get-AcceptanceFullPath -Path $SimulationRoot
        Assert-AcceptanceNoReparsePath -Path $simRootFull
        $targetsReport.simulationRoot = $simRootFull
        $cleanup.simulationRoot = $simRootFull

        if ([string]::IsNullOrWhiteSpace($InstallRoot)) {
            $InstallRoot = Join-Path $simRootFull 'Programs\HerdrOps'
        }
        if ([string]::IsNullOrWhiteSpace($UserDataRoot)) {
            $UserDataRoot = Join-Path $simRootFull 'HerdrOps'
        }

        $installRootFull = Get-AcceptanceFullPath -Path $InstallRoot
        $userDataRootFull = Get-AcceptanceFullPath -Path $UserDataRoot

        # Fixture / non-live mode must strictly contain paths inside SimulationRoot
        if (-not (Test-PathWithin -ChildPath $installRootFull -RootPath $simRootFull)) {
            throw "Non-live InstallRoot '$installRootFull' must be contained inside SimulationRoot '$simRootFull'."
        }
        if (-not (Test-PathWithin -ChildPath $userDataRootFull -RootPath $simRootFull)) {
            throw "Non-live UserDataRoot '$userDataRootFull' must be contained inside SimulationRoot '$simRootFull'."
        }

        $canonicalInstall = Get-DefaultHerdrOpsInstallRoot
        $canonicalUserData = Get-DefaultHerdrOpsUserDataRoot
        if ($installRootFull.Equals((Get-AcceptanceFullPath $canonicalInstall), [StringComparison]::OrdinalIgnoreCase) -or
            $userDataRootFull.Equals((Get-AcceptanceFullPath $canonicalUserData), [StringComparison]::OrdinalIgnoreCase)) {
            throw "Non-live mode ($Mode) must not target production AppData paths ($canonicalInstall, $canonicalUserData)."
        }
    }

    if ($installRootFull.Equals($userDataRootFull, [StringComparison]::OrdinalIgnoreCase)) {
        throw 'InstallRoot and UserDataRoot must be distinct non-overlapping paths.'
    }
    if ((Test-PathWithin -ChildPath $installRootFull -RootPath $userDataRootFull) -or
        (Test-PathWithin -ChildPath $userDataRootFull -RootPath $installRootFull)) {
        throw 'InstallRoot and UserDataRoot cannot nest within each other.'
    }
    Assert-OperatorNoReparse -Path $installRootFull
    Assert-OperatorNoReparse -Path $userDataRootFull

    $targetsReport.installRoot = $installRootFull
    $targetsReport.userDataRoot = $userDataRootFull
    Add-OperatorPreflightCheck -Name 'target-paths-reparse-clean' -Status 'PASS' -Details "InstallRoot '$installRootFull' and UserDataRoot '$userDataRootFull' verified."

    # Preflight Check 8: Clean-Machine Precondition - Install Root Absent and No Stale Residuals
    if (Test-Path -LiteralPath $installRootFull) {
        throw "Clean-machine precondition failed: InstallRoot already exists at '$installRootFull'."
    }
    if (Test-Path -LiteralPath $userDataRootFull) {
        throw "Clean-machine precondition failed: UserDataRoot already exists at '$userDataRootFull'. Accepted-Beta data must be supplied only through the exact retained-data binding, not inherited host state."
    }
    $installParent = Split-Path -Path $installRootFull -Parent
    if (Test-Path -LiteralPath $installParent) {
        $staleDirs = @(Get-ChildItem -LiteralPath $installParent -Directory -Force | Where-Object {
            $_.Name -match '^HerdrOps\.(stage|staging|backup|harness)-'
        })
        if ($staleDirs.Count -gt 0) {
            throw "Clean-machine precondition failed: leftover residuals detected in '$installParent': $($staleDirs.FullName -join '; ')."
        }
    }
    Add-OperatorPreflightCheck -Name 'clean-machine-precondition' -Status 'PASS' -Details 'InstallRoot and UserDataRoot are absent and the install parent is clean of stage/staging/backup/harness residuals.'

    # Preflight Check 9: Archive Validation, Manifest Extraction, Entry Hashing, and Staging
    if ($Mode -eq 'Live') {
        if ($InitialArchiveBytes -le 0 -or [string]::IsNullOrWhiteSpace($InitialArchiveSha256)) {
            throw 'Live mode requires non-empty InitialArchiveBytes (>0) and InitialArchiveSha256.'
        }
        if ($CandidateArchiveBytes -le 0 -or [string]::IsNullOrWhiteSpace($CandidateArchiveSha256)) {
            throw 'Live mode requires non-empty CandidateArchiveBytes (>0) and CandidateArchiveSha256.'
        }
    }

    if ([string]::IsNullOrWhiteSpace($InitialArchivePath) -or -not (Test-Path -LiteralPath $InitialArchivePath -PathType Leaf)) {
        throw "Initial package archive was not found: $InitialArchivePath"
    }
    if ([string]::IsNullOrWhiteSpace($CandidateArchivePath) -or -not (Test-Path -LiteralPath $CandidateArchivePath -PathType Leaf)) {
        throw "Candidate package archive was not found: $CandidateArchivePath"
    }

    if ([string]$CandidatePackageVersion -cne '1.0.0') {
        throw "Candidate package version must be exactly '1.0.0'; observed '$CandidatePackageVersion'."
    }
    if ([string]$InitialPackageVersion -cne '0.7.0' -and [string]$InitialPackageVersion -ge [string]$CandidatePackageVersion) {
        throw "Initial package version ($InitialPackageVersion) must be lower than candidate package version ($CandidatePackageVersion)."
    }

    # Create operator-owned staging directory
    $stagingParent = if ($Mode -eq 'Live') { $env:TEMP } else { $targetsReport.simulationRoot }
    $script:OwnedStagingDirectory = Join-Path $stagingParent "HerdrOps.operator-stage-$($script:RunId)"
    New-Item -ItemType Directory -Path $script:OwnedStagingDirectory -Force | Out-Null
    Assert-OperatorNoReparse -Path $script:OwnedStagingDirectory

    if ($bindingWasProvided) {
        $initialExpectedArtifact = [ordered]@{
            packageRoot = $initialBindingPackageRoot
            archivePath = $InitialArchivePath
            hashRecordPath = $initialBindingHashRecordPath
            productId = [string]$initialArtifactBinding.productId
            displayName = [string]$initialArtifactBinding.displayName
            packagingIssue = [int]$initialArtifactBinding.packagingIssue
            packageVersion = $InitialPackageVersion
            targetFramework = [string]$initialArtifactBinding.targetFramework
            runtimeIdentifier = [string]$initialArtifactBinding.runtimeIdentifier
            deploymentModel = [string]$initialArtifactBinding.deploymentModel
            userDataPolicy = [string]$initialArtifactBinding.userDataPolicy
            sourceCommit = $InitialSourceCommit
            manifestSha256 = $InitialManifestSha256
            archiveSha256 = $InitialArchiveSha256
            contentSha256 = $InitialContentSha256
        }
        $initialAcceptedArtifact = Assert-AcceptanceArtifact -Expected $initialExpectedArtifact -Name 'Initial accepted artifact'

        $candidateExpectedArtifact = [ordered]@{
            packageRoot = $candidateBindingPackageRoot
            archivePath = $CandidateArchivePath
            hashRecordPath = $candidateBindingHashRecordPath
            productId = [string]$upgradeArtifactBinding.productId
            displayName = [string]$upgradeArtifactBinding.displayName
            packagingIssue = [int]$upgradeArtifactBinding.packagingIssue
            packageVersion = $CandidatePackageVersion
            targetFramework = [string]$upgradeArtifactBinding.targetFramework
            runtimeIdentifier = [string]$upgradeArtifactBinding.runtimeIdentifier
            deploymentModel = [string]$upgradeArtifactBinding.deploymentModel
            userDataPolicy = [string]$upgradeArtifactBinding.userDataPolicy
            sourceCommit = $CandidateSourceCommit
            manifestSha256 = $CandidateManifestSha256
            archiveSha256 = $CandidateArchiveSha256
            contentSha256 = $CandidateContentSha256
        }
        $candidateAcceptedArtifact = Assert-AcceptanceArtifact -Expected $candidateExpectedArtifact -Name 'Candidate accepted artifact'
        if ($Mode -eq 'Live' -and [string]$candidateAcceptedArtifact.SourceCommit -cne $ExpectedSourceCommit) {
            throw 'Candidate accepted artifact sourceCommit is not the exact top-level accepted source commit.'
        }
        Add-OperatorPreflightCheck -Name 'expanded-package-and-sidecar-binding' -Status 'PASS' -Details 'Expanded package roots, package manifests, archives, and hash-record sidecars match their exact binding values.'
    }

    $stagedInitial = Stage-AcceptedArchiveAtomically `
        -SourcePath $InitialArchivePath `
        -StagingDirectory $script:OwnedStagingDirectory `
        -ArtifactName 'Initial' `
        -ExpectedBytes $InitialArchiveBytes `
        -ExpectedSha256 $InitialArchiveSha256 `
        -ExpectedManifestSha256 $InitialManifestSha256 `
        -ExpectedContentSha256 $InitialContentSha256 `
        -ExpectedPackageVersion $InitialPackageVersion

    $stagedCandidate = Stage-AcceptedArchiveAtomically `
        -SourcePath $CandidateArchivePath `
        -StagingDirectory $script:OwnedStagingDirectory `
        -ArtifactName 'Candidate' `
        -ExpectedBytes $CandidateArchiveBytes `
        -ExpectedSha256 $CandidateArchiveSha256 `
        -ExpectedManifestSha256 $CandidateManifestSha256 `
        -ExpectedContentSha256 $CandidateContentSha256 `
        -ExpectedPackageVersion $CandidatePackageVersion

    $initialDurableManifest = Resolve-Issue44ManifestEvidence `
        -ArchivePath $InitialArchivePath `
        -ExpectedManifestPath $(if ($null -ne $initialAcceptedArtifact) { $initialAcceptedArtifact.ManifestPath } else { '' }) `
        -ExpectedBytes $stagedInitial.ManifestBytes `
        -ExpectedSha256 $stagedInitial.ManifestSha256 `
        -ArtifactName 'Initial'
    $candidateDurableManifest = Resolve-Issue44ManifestEvidence `
        -ArchivePath $CandidateArchivePath `
        -ExpectedManifestPath $(if ($null -ne $candidateAcceptedArtifact) { $candidateAcceptedArtifact.ManifestPath } else { '' }) `
        -ExpectedBytes $stagedCandidate.ManifestBytes `
        -ExpectedSha256 $stagedCandidate.ManifestSha256 `
        -ArtifactName 'Candidate'

    Add-OperatorPreflightCheck -Name 'v1-target-version' -Status 'PASS' -Details "Initial version '$InitialPackageVersion' and upgrade target version '$CandidatePackageVersion' validated."
    Add-OperatorPreflightCheck -Name 'archive-hashes-and-bytes' -Status 'PASS' -Details 'Initial and Candidate archive bytes, files entries, manifest bytes, archive entries, and SHA-256 values verified and staged.'
    Add-OperatorPreflightCheck -Name 'durable-manifest-evidence' -Status 'PASS' -Details "Initial manifest '$($initialDurableManifest.Path)' and Candidate manifest '$($candidateDurableManifest.Path)' are existing accepted evidence files."

    # Construct Artifact Report Records referencing durable accepted inputs
    $initialArchiveDurable = Get-AcceptanceFullPath -Path $InitialArchivePath
    $candidateArchiveDurable = Get-AcceptanceFullPath -Path $CandidateArchivePath

    $initialArtifactReport = [ordered]@{
        name = 'initial'
        productId = $(if ($null -ne $initialAcceptedArtifact) { $initialAcceptedArtifact.ProductId } else { 'HerdrOps' })
        displayName = $(if ($null -ne $initialAcceptedArtifact) { $initialAcceptedArtifact.ProductId } else { 'HerdrOps' })
        packagingIssue = $(if ($null -ne $initialAcceptedArtifact) { [int]$initialAcceptedArtifact.PackagingIssue } else { 38 })
        packageVersion = $InitialPackageVersion
        targetFramework = $(if ($null -ne $initialAcceptedArtifact) { $initialAcceptedArtifact.TargetFramework } else { 'net10.0-windows' })
        runtimeIdentifier = $(if ($null -ne $initialAcceptedArtifact) { $initialAcceptedArtifact.RuntimeIdentifier } else { 'win-x64' })
        deploymentModel = $(if ($null -ne $initialAcceptedArtifact) { $initialAcceptedArtifact.DeploymentModel } else { 'per-user-directory' })
        userDataPolicy = $(if ($null -ne $initialAcceptedArtifact) { $initialAcceptedArtifact.UserDataPolicy } else { 'retain-on-uninstall' })
        packageRoot = $initialDurableManifest.PackageRoot
        archivePath = $initialArchiveDurable
        archiveBytes = [int64]$stagedInitial.Length
        archiveSha256 = $stagedInitial.Sha256
        manifestPath = $initialDurableManifest.Path
        manifestBytes = [int64]$stagedInitial.ManifestBytes
        manifestSha256 = $stagedInitial.ManifestSha256
        contentSha256 = $stagedInitial.ContentSha256
        sourceCommitBinding = $(if (-not [string]::IsNullOrWhiteSpace($InitialSourceCommit)) { $InitialSourceCommit } else { 'NOT_BOUND_IN_SYNTHETIC_FIXTURE' })
        installedFileHashes = @()
    }

    $upgradeArtifactReport = [ordered]@{
        name = 'upgrade'
        productId = $(if ($null -ne $candidateAcceptedArtifact) { $candidateAcceptedArtifact.ProductId } else { 'HerdrOps' })
        displayName = $(if ($null -ne $candidateAcceptedArtifact) { $candidateAcceptedArtifact.ProductId } else { 'HerdrOps' })
        packagingIssue = $(if ($null -ne $candidateAcceptedArtifact) { [int]$candidateAcceptedArtifact.PackagingIssue } else { 44 })
        packageVersion = $CandidatePackageVersion
        targetFramework = $(if ($null -ne $candidateAcceptedArtifact) { $candidateAcceptedArtifact.TargetFramework } else { 'net10.0-windows' })
        runtimeIdentifier = $(if ($null -ne $candidateAcceptedArtifact) { $candidateAcceptedArtifact.RuntimeIdentifier } else { 'win-x64' })
        deploymentModel = $(if ($null -ne $candidateAcceptedArtifact) { $candidateAcceptedArtifact.DeploymentModel } else { 'per-user-directory' })
        userDataPolicy = $(if ($null -ne $candidateAcceptedArtifact) { $candidateAcceptedArtifact.UserDataPolicy } else { 'retain-on-uninstall' })
        packageRoot = $candidateDurableManifest.PackageRoot
        archivePath = $candidateArchiveDurable
        archiveBytes = [int64]$stagedCandidate.Length
        archiveSha256 = $stagedCandidate.Sha256
        manifestPath = $candidateDurableManifest.Path
        manifestBytes = [int64]$stagedCandidate.ManifestBytes
        manifestSha256 = $stagedCandidate.ManifestSha256
        contentSha256 = $stagedCandidate.ContentSha256
        sourceCommitBinding = $actualHeadCommit
        installedFileHashes = @()
    }

    # Artifact objects for Assert-AcceptanceInstalledPayload helper
    $initialArtifactHelper = [pscustomobject][ordered]@{
        Name = 'initial'
        ProductId = 'HerdrOps'
        DisplayName = 'HerdrOps'
        PackagingIssue = 38
        PackageVersion = $InitialPackageVersion
        TargetFramework = 'net10.0-windows'
        RuntimeIdentifier = 'win-x64'
        DeploymentModel = 'per-user-directory'
        UserDataPolicy = 'retain-on-uninstall'
        PackageRoot = (Split-Path -Path $stagedInitial.StagedPath -Parent)
        ArchivePath = $stagedInitial.StagedPath
        ArchiveBytes = $stagedInitial.Length
        ArchiveSha256 = $stagedInitial.Sha256
        ManifestPath = $stagedInitial.StagedManifestPath
        ManifestBytes = $stagedInitial.ManifestBytes
        ManifestSha256 = $stagedInitial.ManifestSha256
        ContentSha256 = $stagedInitial.ContentSha256
        SourceCommitBinding = $InitialSourceCommit
        ContentEntries = $stagedInitial.ContentEntries
    }

    $upgradeArtifactHelper = [pscustomobject][ordered]@{
        Name = 'upgrade'
        ProductId = 'HerdrOps'
        DisplayName = 'HerdrOps'
        PackagingIssue = 44
        PackageVersion = $CandidatePackageVersion
        TargetFramework = 'net10.0-windows'
        RuntimeIdentifier = 'win-x64'
        DeploymentModel = 'per-user-directory'
        UserDataPolicy = 'retain-on-uninstall'
        PackageRoot = (Split-Path -Path $stagedCandidate.StagedPath -Parent)
        ArchivePath = $stagedCandidate.StagedPath
        ArchiveBytes = $stagedCandidate.Length
        ArchiveSha256 = $stagedCandidate.Sha256
        ManifestPath = $stagedCandidate.StagedManifestPath
        ManifestBytes = $stagedCandidate.ManifestBytes
        ManifestSha256 = $stagedCandidate.ManifestSha256
        ContentSha256 = $stagedCandidate.ContentSha256
        SourceCommitBinding = $actualHeadCommit
        ContentEntries = $stagedCandidate.ContentEntries
    }

    # Setup Runners: Default installer runs bounded child powershell process
    $effectiveInstallerRunner = if ($null -ne $InstallerRunner) {
        $InstallerRunner
    } else {
        {
            param(
                [Parameter(Mandatory = $true)][ValidateSet('Install', 'Uninstall')][string]$Action,
                [string]$ArchivePath,
                [Parameter(Mandatory = $true)][string]$InstallRoot,
                [Parameter(Mandatory = $true)][string]$UserDataRoot,
                [switch]$RemoveUserData,
                [int]$TimeoutSeconds = 120
            )
            $installerDir = Join-Path $repositoryRoot 'tools\installer'
            $scriptPath = if ($Action -eq 'Install') {
                Join-Path $installerDir 'Install-HerdrOps.ps1'
            } else {
                Join-Path $installerDir 'Uninstall-HerdrOps.ps1'
            }

            $pwshExe = (Get-Process -Id $PID).Path
            if (-not (Test-Path -LiteralPath $pwshExe -PathType Leaf)) {
                $pwshExe = 'powershell.exe'
            }

            $argList = New-Object System.Collections.ArrayList
            [void]$argList.Add('-NoProfile')
            [void]$argList.Add('-NonInteractive')
            [void]$argList.Add('-ExecutionPolicy')
            [void]$argList.Add('Bypass')
            [void]$argList.Add('-File')
            [void]$argList.Add($scriptPath)

            if ($Action -eq 'Install') {
                [void]$argList.Add('-ArchivePath')
                [void]$argList.Add($ArchivePath)
                [void]$argList.Add('-InstallRoot')
                [void]$argList.Add($InstallRoot)
                [void]$argList.Add('-UserDataRoot')
                [void]$argList.Add($UserDataRoot)
            } else {
                [void]$argList.Add('-InstallRoot')
                [void]$argList.Add($InstallRoot)
                [void]$argList.Add('-UserDataRoot')
                [void]$argList.Add($UserDataRoot)
                if ($RemoveUserData) {
                    [void]$argList.Add('-RemoveUserData')
                }
            }

            $psi = New-Object System.Diagnostics.ProcessStartInfo
            $psi.FileName = $pwshExe
            $psi.Arguments = ($argList | ForEach-Object { if ($_ -match '\s') { "`"$_`"" } else { $_ } }) -join ' '
            $psi.UseShellExecute = $false
            $psi.RedirectStandardOutput = $true
            $psi.RedirectStandardError = $true
            $psi.CreateNoWindow = $true

            $proc = [System.Diagnostics.Process]::Start($psi)
            if ($null -eq $proc) {
                throw "Failed to start installer child process: $pwshExe"
            }
            $installerIdentity = Get-Issue44ProcessIdentity -Process $proc
            $stdoutTask = $proc.StandardOutput.ReadToEndAsync()
            $stderrTask = $proc.StandardError.ReadToEndAsync()
            $timedOut = -not $proc.WaitForExit($TimeoutSeconds * 1000)
            $descendantIdentities = New-Object 'System.Collections.Generic.Dictionary[int,object]'
            $queue = New-Object 'System.Collections.Generic.Queue[int]'
            $queue.Enqueue([int]$installerIdentity.Id)
            while ($queue.Count -gt 0) {
                $parentPid = $queue.Dequeue()
                foreach ($child in @(Get-CimInstance Win32_Process -Filter "ParentProcessId = $parentPid" -ErrorAction Stop)) {
                    $childProcess = Get-Process -Id ([int]$child.ProcessId) -ErrorAction Stop
                    $childIdentity = Get-Issue44ProcessIdentity -Process $childProcess
                    $descendantIdentities[$childIdentity.Id] = $childIdentity
                    $queue.Enqueue($childIdentity.Id)
                }
            }
            $processCleanupFailures = New-Object System.Collections.ArrayList
            foreach ($identity in @($descendantIdentities.Values) | Sort-Object StartUtcTicks -Descending) {
                try {
                    $childProcess = [Diagnostics.Process]::GetProcessById([int]$identity.Id)
                    Assert-Issue44ProcessIdentity -Identity $identity -Process $childProcess -Context 'Installer descendant cleanup'
                    if (-not $childProcess.HasExited) { $childProcess.Kill(); [void]$childProcess.WaitForExit(2000) }
                    if (-not $childProcess.HasExited) { throw "Installer descendant PID $($identity.Id) remained alive." }
                } catch [ArgumentException] { } catch { [void]$processCleanupFailures.Add($_.Exception.Message) }
            }
            try {
                if (-not $proc.HasExited) {
                    Assert-Issue44ProcessIdentity -Identity $installerIdentity -Process $proc -Context 'Installer root cleanup'
                    $proc.Kill()
                    [void]$proc.WaitForExit(2000)
                }
                if (-not $proc.HasExited) { throw "Installer root PID $($installerIdentity.Id) remained alive." }
            } catch { [void]$processCleanupFailures.Add($_.Exception.Message) }
            if ($processCleanupFailures.Count -gt 0) {
                throw "Installer process-tree cleanup failed closed: $($processCleanupFailures -join '; ')"
            }
            if ($timedOut) { throw "Installer child process timed out after $TimeoutSeconds seconds; admitted process tree was terminated and verified." }
            $stdout = $stdoutTask.GetAwaiter().GetResult()
            $stderr = $stderrTask.GetAwaiter().GetResult()

            if ($proc.ExitCode -ne 0) {
                throw "Installer ($Action) failed with exit code $($proc.ExitCode). Stderr: $stderr. Stdout: $stdout"
            }

            return [pscustomobject][ordered]@{
                Status = 'PASS'
                Action = $Action
                ExitCode = $proc.ExitCode
                Details = "Installer ($Action) completed successfully."
            }
        }
    }

    $effectiveFirstRunRunner = if ($null -ne $FirstRunRunner) {
        $FirstRunRunner
    } else {
        {
            param(
                [Parameter(Mandatory = $true)][string]$InstallRoot,
                [Parameter(Mandatory = $true)][string]$UserDataRoot,
                [int]$TimeoutMilliseconds = 5000
            )
            $appExe = Join-Path $InstallRoot 'HerdrOps.App.exe'
            $coreExe = Join-Path $InstallRoot 'HerdrOps.Core.exe'
            if (-not (Test-Path -LiteralPath $coreExe -PathType Leaf)) {
                throw "HerdrOps.Core.exe not found in $InstallRoot."
            }
            if (-not (Test-Path -LiteralPath $appExe -PathType Leaf)) {
                throw "HerdrOps.App.exe not found in $InstallRoot."
            }

            $coreData = Get-FileSha256AndBytes -Path $coreExe
            $appData = Get-FileSha256AndBytes -Path $appExe

            $admittedIdentities = New-Object 'System.Collections.Generic.Dictionary[int,object]'
            $coreProc = $null
            $appProc = $null
            $coreIdentity = $null
            $appIdentity = $null
            $cleanupFailures = New-Object System.Collections.ArrayList

            try {
                # 1. Start Core with exact argument 'serve-herdr-state'
                $corePsi = New-Object System.Diagnostics.ProcessStartInfo
                $corePsi.FileName = $coreExe
                $corePsi.Arguments = 'serve-herdr-state'
                $corePsi.WorkingDirectory = $InstallRoot
                $corePsi.UseShellExecute = $false
                $corePsi.CreateNoWindow = $true
                $coreProc = [System.Diagnostics.Process]::Start($corePsi)
                if ($null -eq $coreProc) {
                    throw "Failed to start Core process: $coreExe serve-herdr-state"
                }
                $coreIdentity = Get-Issue44ProcessIdentity -Process $coreProc
                if ([string]$coreIdentity.Sha256 -cne [string]$coreData.Sha256 -or [string]$coreIdentity.Path -cne $coreExe) {
                    throw 'Launched Core identity does not match the exact installed path/hash.'
                }
                $admittedIdentities[$coreIdentity.Id] = $coreIdentity

                # 2. Start App with NO invented arguments
                $appPsi = New-Object System.Diagnostics.ProcessStartInfo
                $appPsi.FileName = $appExe
                $appPsi.Arguments = ''
                $appPsi.WorkingDirectory = $InstallRoot
                $appPsi.UseShellExecute = $false
                $appPsi.CreateNoWindow = $true
                $appProc = [System.Diagnostics.Process]::Start($appPsi)
                if ($null -eq $appProc) {
                    throw "Failed to start App process: $appExe"
                }
                $appIdentity = Get-Issue44ProcessIdentity -Process $appProc
                if ([string]$appIdentity.Sha256 -cne [string]$appData.Sha256 -or [string]$appIdentity.Path -cne $appExe) {
                    throw 'Launched App identity does not match the exact installed path/hash.'
                }
                $admittedIdentities[$appIdentity.Id] = $appIdentity

                # 3. Bounded semantic readiness: Core must accept its strict
                # current-user App handshake and return a state snapshot with
                # runtime-health fields.  HasExited alone is not readiness.
                $coreReadiness = Wait-Issue44CoreSemanticReadiness -CoreProcess $coreProc -CoreIdentity $coreIdentity `
                    -AppProcess $appProc -AppIdentity $appIdentity -TimeoutMilliseconds $TimeoutMilliseconds

                # 4. Discover recursive descendants of admitted process
                # identities only.  A PID without a provable start time is
                # never admitted and therefore never killed.
                $queue = New-Object 'System.Collections.Generic.Queue[int]'
                foreach ($p in @($admittedIdentities.Keys)) { $queue.Enqueue([int]$p) }
                while ($queue.Count -gt 0) {
                    $curr = $queue.Dequeue()
                    $parentIdentity = $admittedIdentities[[int]$curr]
                    try {
                        $parentProc = [System.Diagnostics.Process]::GetProcessById([int]$curr)
                        Assert-Issue44ProcessIdentity -Identity $parentIdentity -Process $parentProc -Context 'Descendant parent enumeration'
                        if ($parentProc.HasExited) { continue }
                    } catch [ArgumentException] {
                        continue
                    }
                    $children = @(Get-CimInstance Win32_Process -Filter "ParentProcessId = $curr" -ErrorAction Stop)
                    foreach ($c in $children) {
                        $cPid = [int]$c.ProcessId
                        if ($admittedIdentities.ContainsKey($cPid)) { continue }
                        $childProc = $null
                        try {
                            $childProc = Get-Process -Id $cPid -ErrorAction Stop
                            $childIdentity = Get-Issue44ProcessIdentity -Process $childProc
                            if ($c.CreationDate) {
                                $cimStartUtc = [Management.ManagementDateTimeConverter]::ToDateTime([string]$c.CreationDate).ToUniversalTime()
                                if ($childIdentity.StartUtcTicks -ne $cimStartUtc.Ticks) {
                                    throw "Child PID $cPid start-time mismatch; refusing possible PID reuse."
                                }
                            }
                            $admittedIdentities[$childIdentity.Id] = $childIdentity
                            $queue.Enqueue($childIdentity.Id)
                        } catch {
                            throw "Could not safely admit descendant PID ${cPid}: $($_.Exception.Message)"
                        }
                    }
                }
            } finally {
                # Initial Process objects are handles obtained directly from
                # our Start calls; descendants require an identity recheck.
                foreach ($initial in @(
                        [pscustomobject]@{ Process = $appProc; Identity = $appIdentity; Name = 'App' },
                        [pscustomobject]@{ Process = $coreProc; Identity = $coreIdentity; Name = 'Core' })) {
                    try {
                        if ($null -ne $initial.Process -and -not $initial.Process.HasExited) {
                            if ($null -ne $initial.Identity) {
                                Assert-Issue44ProcessIdentity -Identity $initial.Identity -Process $initial.Process -Context "$($initial.Name) cleanup"
                            }
                            $initial.Process.Kill()
                            $initial.Process.WaitForExit(2000)
                        }
                    } catch { [void]$cleanupFailures.Add($_.Exception.Message) }
                }
                foreach ($identity in @($admittedIdentities.Values)) {
                    if ($null -ne $coreIdentity -and [int]$identity.Id -eq [int]$coreIdentity.Id) { continue }
                    if ($null -ne $appIdentity -and [int]$identity.Id -eq [int]$appIdentity.Id) { continue }
                    try {
                        $proc = [System.Diagnostics.Process]::GetProcessById([int]$identity.Id)
                        if ($null -ne $proc -and -not $proc.HasExited) {
                            Assert-Issue44ProcessIdentity -Identity $identity -Process $proc -Context 'Descendant cleanup'
                            $proc.Kill()
                            $proc.WaitForExit(1000)
                        }
                    } catch [ArgumentException] {
                        # The admitted process exited before cleanup.
                    } catch { [void]$cleanupFailures.Add($_.Exception.Message) }
                }
            }

            if ($cleanupFailures.Count -gt 0) {
                throw "Process cleanup failed closed without touching an unproven process: $($cleanupFailures -join '; ')"
            }
            foreach ($identity in @($admittedIdentities.Values)) {
                try {
                    $proc = [System.Diagnostics.Process]::GetProcessById([int]$identity.Id)
                    Assert-Issue44ProcessIdentity -Identity $identity -Process $proc -Context 'Process exit verification'
                    if ($null -ne $proc -and -not $proc.HasExited) {
                        throw "Admitted process $($identity.Id) failed to exit."
                    }
                } catch [ArgumentException] {
                    # Process has exited cleanly
                }
            }

            return [pscustomobject][ordered]@{
                Status = 'PASS'
                CorePid = $coreProc.Id
                AppPid = $appProc.Id
                CoreStartUtc = $coreIdentity.StartUtc
                AppStartUtc = $appIdentity.StartUtc
                CorePath = $coreExe
                AppPath = $appExe
                CoreSha256 = $coreIdentity.Sha256
                AppSha256 = $appIdentity.Sha256
                CoreHealthReady = [bool]$coreReadiness.Ready
                CoreHealthDetails = [string]$coreReadiness.Details
                CoreRuntimeHealthStatus = [string]$coreReadiness.RuntimeHealthStatus
                AdmittedPids = @($admittedIdentities.Keys)
                Details = 'Exact Core and real App process identities reached bounded readiness without operator source spoofing; all admitted PIDs terminated cleanly.'
            }
        }
    }

    # Setup Retained Data Target
    $retainedDataFullPath = Get-AcceptanceFullPath -Path (Join-Path $userDataRootFull $RetainedDataRelativePath)
    Assert-AcceptanceSafeDescendantFilePath -Path $retainedDataFullPath -Root $userDataRootFull -Context 'Retained data marker'

    $effect = if ($Mode -eq 'Live') { 'LiveFilesystem' } else { 'FixtureTempOnly' }

    if ($Mode -eq 'DryRun') {
        foreach ($phase in @('cleanInstall', 'upgrade', 'rollback', 'uninstall')) {
            $lifecycle[$phase].status = 'SKIPPED'
            $lifecycle[$phase].details = 'Dry-run execution only; no filesystem mutation.'
            Add-OperatorTranscript -Phase $phase -Action 'dry-run-transition' -Status 'SKIPPED' -Effect 'None' -Details 'Dry-run preflight passed.' -PathBinding 'none'
        }
    } else {
        # LIFECYCLE STEP 1: Clean Install (Initial 0.7.0)
        Add-OperatorTranscript -Phase 'CleanInstall' -Action 'invoke-production-install' -Status 'PASS' -Effect $effect -Details "Installing initial version $InitialPackageVersion via Install-HerdrOps.ps1 (staged SHA-256 $($stagedInitial.Sha256))." -PathBinding 'installRoot,userDataRoot'

        Invoke-WithStagedArchiveLocked -StagedPath $stagedInitial.StagedPath -ExpectedBytes $stagedInitial.Length -ExpectedSha256 $stagedInitial.Sha256 -Context 'CleanInstall' -Action {
            $runnerResult = & $effectiveInstallerRunner -Action 'Install' -ArchivePath $stagedInitial.StagedPath -InstallRoot $installRootFull -UserDataRoot $userDataRootFull
            Assert-RunnerResultPass -Result $runnerResult -Context 'Clean install'
        }

        if (-not (Test-Path -LiteralPath $installRootFull -PathType Container)) {
            throw "Clean install failed: InstallRoot does not exist after installation: $installRootFull"
        }

        # Assert installed payload matches artifact shape exactly
        $initialInstalledHashes = Assert-AcceptanceInstalledPayload -InstallRoot $installRootFull -Artifact $initialArtifactHelper -Context 'Clean install'
        $initialArtifactReport.installedFileHashes = $initialInstalledHashes
        $script:CleanMachineFilesystemObserved = ($Mode -eq 'Live')

        # Establish / Verify Retained Data Marker
        if ($RetainedDataMode -eq 'create-test-marker') {
            $createdMarker = New-AcceptanceRetainedDataMarker -UserDataRoot $userDataRootFull -Path $retainedDataFullPath -ExpectedSha256 $RetainedDataSha256
            $script:HarnessMarkerCreated = $true
            $retainedDataMarkerData = Get-FileSha256AndBytes -Path $retainedDataFullPath
            $activeRetainedSha256 = $retainedDataMarkerData.Sha256
        } else {
            if (-not (Test-Path -LiteralPath $retainedDataFullPath -PathType Leaf)) {
                throw "Preseeded retained data marker was not found at $retainedDataFullPath."
            }
            $retainedDataMarkerData = Get-FileSha256AndBytes -Path $retainedDataFullPath
            $activeRetainedSha256 = $retainedDataMarkerData.Sha256
            if (-not [string]::IsNullOrWhiteSpace($RetainedDataSha256) -and $activeRetainedSha256 -cne $RetainedDataSha256.ToUpperInvariant()) {
                throw "Preseeded retained data marker SHA-256 mismatch: expected '$RetainedDataSha256', observed '$activeRetainedSha256'."
            }
        }

        $lifecycle.cleanInstall.status = 'PASS'
        $lifecycle.cleanInstall.installedFileHashes = $initialInstalledHashes
        $lifecycle.cleanInstall.installRootPresent = $true
        $lifecycle.cleanInstall.packageVersionObserved = $InitialPackageVersion
        $lifecycle.cleanInstall.retainedDataStatus = 'PASS'
        $lifecycle.cleanInstall.retainedDataSha256 = $activeRetainedSha256
        $lifecycle.cleanInstall.details = "Clean install of version $InitialPackageVersion succeeded with $($initialInstalledHashes.Count) files."
        Add-OperatorTranscript -Phase 'CleanInstall' -Action 'verify-clean-install' -Status 'PASS' -Effect $effect -Details "Clean install payload and retained-data marker verified (executed staged SHA-256 $($stagedInitial.Sha256))." -PathBinding 'installRoot,userDataRoot'

        # LIFECYCLE STEP 2: Bounded First-Run with Process-Tree Cleanup
        Add-OperatorTranscript -Phase 'FirstRun' -Action 'invoke-bounded-first-run' -Status 'PASS' -Effect $effect -Details 'Executing bounded first-run verification and process-tree cleanup.' -PathBinding 'installRoot'
        $firstRunResult = & $effectiveFirstRunRunner -InstallRoot $installRootFull -UserDataRoot $userDataRootFull
        Assert-RunnerResultPass -Result $firstRunResult -Context 'First-run'
        if (-not $firstRunResult.PSObject.Properties['CoreHealthReady'] -or $firstRunResult.CoreHealthReady -isnot [bool] -or -not $firstRunResult.CoreHealthReady) {
            throw 'First-run runner did not provide a true semantic CoreHealthReady result.'
        }
        if (-not $firstRunResult.PSObject.Properties['CoreHealthDetails'] -or [string]::IsNullOrWhiteSpace([string]$firstRunResult.CoreHealthDetails)) {
            throw 'First-run runner did not provide bounded semantic readiness details.'
        }
        foreach ($binary in @(
                [pscustomobject]@{ Name = 'HerdrOps.Core.exe'; ResultProperty = 'CoreSha256' },
                [pscustomobject]@{ Name = 'HerdrOps.App.exe'; ResultProperty = 'AppSha256' })) {
            $expectedBinary = @($initialInstalledHashes | Where-Object { [string]$_.Path -ceq $binary.Name })
            if ($expectedBinary.Count -ne 1) {
                throw "First-run artifact manifest does not contain exactly one $($binary.Name) entry."
            }
            if (-not $firstRunResult.PSObject.Properties[$binary.ResultProperty] -or
                [string]$firstRunResult.($binary.ResultProperty) -cne [string]$expectedBinary[0].Sha256) {
                throw "First-run $($binary.Name) hash is not cross-bound to the installed manifest bytes."
            }
        }

        $postFirstRunData = Get-FileSha256AndBytes -Path $retainedDataFullPath
        if ($postFirstRunData.Sha256 -cne $activeRetainedSha256) {
            throw 'Retained data marker was modified or corrupted during first-run.'
        }
        Add-OperatorTranscript -Phase 'FirstRun' -Action 'verify-first-run-quiescence' -Status 'PASS' -Effect $effect -Details 'First-run completed with admitted PIDs terminated and retained data intact.' -PathBinding 'installRoot,userDataRoot'

        # LIFECYCLE STEP 3: Candidate Upgrade (1.0.0)
        Add-OperatorTranscript -Phase 'Upgrade' -Action 'invoke-production-upgrade' -Status 'PASS' -Effect $effect -Details "Upgrading to candidate version $CandidatePackageVersion via Install-HerdrOps.ps1 (staged SHA-256 $($stagedCandidate.Sha256))." -PathBinding 'installRoot,userDataRoot'

        Invoke-WithStagedArchiveLocked -StagedPath $stagedCandidate.StagedPath -ExpectedBytes $stagedCandidate.Length -ExpectedSha256 $stagedCandidate.Sha256 -Context 'Upgrade' -Action {
            $runnerResult = & $effectiveInstallerRunner -Action 'Install' -ArchivePath $stagedCandidate.StagedPath -InstallRoot $installRootFull -UserDataRoot $userDataRootFull
            Assert-RunnerResultPass -Result $runnerResult -Context 'Upgrade'
        }

        if (-not (Test-Path -LiteralPath $installRootFull -PathType Container)) {
            throw "Upgrade failed: InstallRoot does not exist after upgrade: $installRootFull"
        }

        # Assert upgrade payload matches artifact shape exactly
        $upgradeInstalledHashes = Assert-AcceptanceInstalledPayload -InstallRoot $installRootFull -Artifact $upgradeArtifactHelper -Context 'Candidate upgrade'
        $upgradeArtifactReport.installedFileHashes = $upgradeInstalledHashes

        # Verify Retained Data Persistence Across Upgrade
        $postUpgradeData = Get-FileSha256AndBytes -Path $retainedDataFullPath
        if ($postUpgradeData.Sha256 -cne $activeRetainedSha256) {
            throw "Retained data marker SHA-256 changed across upgrade: expected '$activeRetainedSha256', observed '$($postUpgradeData.Sha256)'."
        }

        $lifecycle.upgrade.status = 'PASS'
        $lifecycle.upgrade.installedFileHashes = $upgradeInstalledHashes
        $lifecycle.upgrade.installRootPresent = $true
        $lifecycle.upgrade.packageVersionObserved = $CandidatePackageVersion
        $lifecycle.upgrade.retainedDataStatus = 'PASS'
        $lifecycle.upgrade.retainedDataSha256 = $activeRetainedSha256
        $lifecycle.upgrade.details = "Candidate upgrade to $CandidatePackageVersion succeeded with $($upgradeInstalledHashes.Count) files and preserved user data."
        Add-OperatorTranscript -Phase 'Upgrade' -Action 'verify-upgrade' -Status 'PASS' -Effect $effect -Details "Upgrade payload and retained data verified (executed staged SHA-256 $($stagedCandidate.Sha256))." -PathBinding 'installRoot,userDataRoot'

        # LIFECYCLE STEP 4: Rollback by Accepted-Beta Reinstall (0.7.0)
        Add-OperatorTranscript -Phase 'Rollback' -Action 'invoke-production-rollback' -Status 'PASS' -Effect $effect -Details "Rolling back to version $InitialPackageVersion via Install-HerdrOps.ps1 (staged SHA-256 $($stagedInitial.Sha256))." -PathBinding 'installRoot,userDataRoot'

        Invoke-WithStagedArchiveLocked -StagedPath $stagedInitial.StagedPath -ExpectedBytes $stagedInitial.Length -ExpectedSha256 $stagedInitial.Sha256 -Context 'Rollback' -Action {
            $runnerResult = & $effectiveInstallerRunner -Action 'Install' -ArchivePath $stagedInitial.StagedPath -InstallRoot $installRootFull -UserDataRoot $userDataRootFull
            Assert-RunnerResultPass -Result $runnerResult -Context 'Rollback'
        }

        if (-not (Test-Path -LiteralPath $installRootFull -PathType Container)) {
            throw "Rollback failed: InstallRoot does not exist after rollback: $installRootFull"
        }

        # Assert rollback payload matches initial artifact shape
        $rollbackInstalledHashes = Assert-AcceptanceInstalledPayload -InstallRoot $installRootFull -Artifact $initialArtifactHelper -Context 'Rollback'
        if ($rollbackInstalledHashes.Count -ne $initialInstalledHashes.Count) {
            throw "Rollback installed file count ($($rollbackInstalledHashes.Count)) differs from initial install ($($initialInstalledHashes.Count))."
        }
        for ($i = 0; $i -lt $initialInstalledHashes.Count; $i++) {
            if ([string]$rollbackInstalledHashes[$i].Path -cne [string]$initialInstalledHashes[$i].Path -or
                [int64]$rollbackInstalledHashes[$i].Length -ne [int64]$initialInstalledHashes[$i].Length -or
                [string]$rollbackInstalledHashes[$i].Sha256 -cne [string]$initialInstalledHashes[$i].Sha256) {
                throw "Rollback hash mismatch at index $i ($($initialInstalledHashes[$i].Path))."
            }
        }
        $postRollbackData = Get-FileSha256AndBytes -Path $retainedDataFullPath
        if ($postRollbackData.Sha256 -cne $activeRetainedSha256) {
            throw "Retained data marker SHA-256 changed across rollback: expected '$activeRetainedSha256', observed '$($postRollbackData.Sha256)'."
        }

        $lifecycle.rollback.status = 'PASS'
        $lifecycle.rollback.installedFileHashes = $rollbackInstalledHashes
        $lifecycle.rollback.installRootPresent = $true
        $lifecycle.rollback.packageVersionObserved = $InitialPackageVersion
        $lifecycle.rollback.retainedDataStatus = 'PASS'
        $lifecycle.rollback.retainedDataSha256 = $activeRetainedSha256
        $lifecycle.rollback.details = "Rollback to version $InitialPackageVersion succeeded with byte-identical payload restoration."
        Add-OperatorTranscript -Phase 'Rollback' -Action 'verify-rollback' -Status 'PASS' -Effect $effect -Details "Rollback payload and retained data verified (executed staged SHA-256 $($stagedInitial.Sha256))." -PathBinding 'installRoot,userDataRoot'

        # LIFECYCLE STEP 5: Uninstall without RemoveUserData
        Add-OperatorTranscript -Phase 'Uninstall' -Action 'invoke-production-uninstall' -Status 'PASS' -Effect $effect -Details 'Uninstalling HerdrOps via Uninstall-HerdrOps.ps1 without RemoveUserData.' -PathBinding 'installRoot,userDataRoot'
        $runnerResult = & $effectiveInstallerRunner -Action 'Uninstall' -InstallRoot $installRootFull -UserDataRoot $userDataRootFull -RemoveUserData:$false
        Assert-RunnerResultPass -Result $runnerResult -Context 'Uninstall'

        if (Test-Path -LiteralPath $installRootFull) {
            throw "Uninstall failed: InstallRoot still exists at $installRootFull."
        }
        if (-not (Test-Path -LiteralPath $userDataRootFull -PathType Container)) {
            throw "Uninstall policy violated: UserDataRoot was deleted: $userDataRootFull"
        }
        $postUninstallData = Get-FileSha256AndBytes -Path $retainedDataFullPath
        if ($postUninstallData.Sha256 -cne $activeRetainedSha256) {
            throw "Retained data marker was damaged during uninstall: expected '$activeRetainedSha256', observed '$($postUninstallData.Sha256)'."
        }

        $lifecycle.uninstall.status = 'PASS'
        $lifecycle.uninstall.installedFileHashes = @()
        $lifecycle.uninstall.installRootPresent = $false
        $lifecycle.uninstall.packageVersionObserved = $InitialPackageVersion
        $lifecycle.uninstall.retainedDataStatus = 'PASS'
        $lifecycle.uninstall.retainedDataSha256 = $activeRetainedSha256
        $lifecycle.uninstall.details = 'Uninstall succeeded; install root removed and retained user data left intact.'
        Add-OperatorTranscript -Phase 'Uninstall' -Action 'verify-uninstall' -Status 'PASS' -Effect $effect -Details 'Install root removed and retained data verified.' -PathBinding 'userDataRoot'
    }

    # Residuals & Cleanup Verification
    $residuals = New-Object System.Collections.ArrayList
    if (Test-Path -LiteralPath $installParent) {
        $staleDirs = @(Get-ChildItem -LiteralPath $installParent -Directory -Force | Where-Object {
            $_.Name -match '^HerdrOps\.(stage|staging|backup|harness)-'
        })
        foreach ($d in $staleDirs) {
            [void]$residuals.Add($d.FullName)
        }
    }
    $cleanup.status = if ($residuals.Count -eq 0) { 'PASS' } else { 'FAIL' }
    $cleanup.attempted = $true
    $cleanup.residuals = @($residuals.ToArray())
    $cleanup.details = if ($residuals.Count -eq 0) { 'Zero leftover installer transients observed.' } else { "Residuals observed: $($residuals -join '; ')" }
    if ($residuals.Count -gt 0) {
        throw "Cleanup residual check failed: $($residuals -join '; ')"
    }

    # Re-read the durable accepted manifest evidence immediately before the
    # report is constructed/written.  A changed or deleted source manifest
    # invalidates the run instead of leaving a stale manifestPath in PASS.
    $initialDurableManifest = Resolve-Issue44ManifestEvidence `
        -ArchivePath $InitialArchivePath `
        -ExpectedManifestPath $(if ($null -ne $initialAcceptedArtifact) { $initialAcceptedArtifact.ManifestPath } else { '' }) `
        -ExpectedBytes $stagedInitial.ManifestBytes `
        -ExpectedSha256 $stagedInitial.ManifestSha256 `
        -ArtifactName 'Initial'
    $candidateDurableManifest = Resolve-Issue44ManifestEvidence `
        -ArchivePath $CandidateArchivePath `
        -ExpectedManifestPath $(if ($null -ne $candidateAcceptedArtifact) { $candidateAcceptedArtifact.ManifestPath } else { '' }) `
        -ExpectedBytes $stagedCandidate.ManifestBytes `
        -ExpectedSha256 $stagedCandidate.ManifestSha256 `
        -ArtifactName 'Candidate'
    $initialArtifactReport.packageRoot = $initialDurableManifest.PackageRoot
    $initialArtifactReport.manifestPath = $initialDurableManifest.Path
    $upgradeArtifactReport.packageRoot = $candidateDurableManifest.PackageRoot
    $upgradeArtifactReport.manifestPath = $candidateDurableManifest.Path

} catch {
    $status = 'FAIL'
    $failureDetails = $_.Exception.Message
    Add-OperatorTranscript -Phase 'Failure' -Action 'fail-closed' -Status 'FAIL' -Effect 'None' -Details $failureDetails -PathBinding 'none'
} finally {
    if ($script:HarnessMarkerCreated -and -not [string]::IsNullOrWhiteSpace($retainedDataFullPath)) {
        try {
            if (Test-Path -LiteralPath $retainedDataFullPath -PathType Leaf) {
                Assert-AcceptanceNoReparsePath -Path $retainedDataFullPath
                Remove-Item -LiteralPath $retainedDataFullPath -Force -ErrorAction Stop
            }
            $cleanup.harnessSeededDataMarkerRemoved = -not (Test-Path -LiteralPath $retainedDataFullPath)
        } catch {
            $cleanup.harnessSeededDataMarkerRemoved = $false
        }
    }
    if ($null -ne $script:OwnedStagingDirectory) {
        try {
            if (Test-Path -LiteralPath $script:OwnedStagingDirectory) {
                Assert-OperatorNoReparse -Path $script:OwnedStagingDirectory
                Remove-Item -LiteralPath $script:OwnedStagingDirectory -Recurse -Force -ErrorAction Stop
            }
            $cleanup.ownedStageRemoved = -not (Test-Path -LiteralPath $script:OwnedStagingDirectory)
        } catch {
            $cleanup.ownedStageRemoved = $false
        }
    } else {
        $cleanup.ownedStageRemoved = $true
    }
    if ($null -ne $script:OwnedSimulationDirectory) {
        try {
            if (Test-Path -LiteralPath $script:OwnedSimulationDirectory) {
                Assert-OperatorNoReparse -Path $script:OwnedSimulationDirectory
                Remove-Item -LiteralPath $script:OwnedSimulationDirectory -Recurse -Force -ErrorAction Stop
            }
            $cleanup.simulationRootRemoved = -not (Test-Path -LiteralPath $script:OwnedSimulationDirectory)
        } catch {
            $cleanup.simulationRootRemoved = $false
        }
    } else {
        $cleanup.simulationRootRemoved = $true
    }

    $postCleanupResiduals = New-Object System.Collections.ArrayList
    if (-not [string]::IsNullOrWhiteSpace($installParent) -and (Test-Path -LiteralPath $installParent)) {
        foreach ($residual in @(Get-ChildItem -LiteralPath $installParent -Directory -Force -ErrorAction SilentlyContinue | Where-Object {
                    $_.Name -match '^HerdrOps\.(stage|staging|backup|harness)-'
                })) {
            [void]$postCleanupResiduals.Add($residual.FullName)
        }
    }
    $cleanup.ownedBackupRemoved = (@($postCleanupResiduals | Where-Object { [IO.Path]::GetFileName($_) -match '^HerdrOps\.backup-' }).Count -eq 0)
    $cleanup.residuals = @($postCleanupResiduals.ToArray())
    $cleanup.attempted = $true
    $cleanupSucceeded = ($cleanup.ownedStageRemoved -and $cleanup.simulationRootRemoved -and
        $cleanup.ownedBackupRemoved -and $postCleanupResiduals.Count -eq 0 -and
        (-not $script:HarnessMarkerCreated -or $cleanup.harnessSeededDataMarkerRemoved))
    $cleanup.status = if ($cleanupSucceeded) { 'PASS' } else { 'FAIL' }
    $cleanup.details = if ($cleanupSucceeded) {
        'Operator-owned staging, simulation, backup residuals, and any harness-seeded marker were verified absent.'
    } else {
        "Fail-closed cleanup verification failed. Residuals: $($cleanup.residuals -join '; ')"
    }
    if (-not $cleanupSucceeded -and $status -ceq 'PASS') {
        $status = 'FAIL'
        $failureDetails = $cleanup.details
        Add-OperatorTranscript -Phase 'Cleanup' -Action 'verify-absence' -Status 'FAIL' -Effect 'None' -Details $failureDetails -PathBinding 'installRoot,userDataRoot'
    }
}

$preflightPassed = ($script:PreflightChecks.Count -gt 0 -and
    @($script:PreflightChecks | Where-Object { $_.status -eq 'FAIL' }).Count -eq 0)
$allLifecyclePassed = @(@('cleanInstall', 'upgrade', 'rollback', 'uninstall') | Where-Object {
        [string]$lifecycle[$_].status -cne 'PASS'
    }).Count -eq 0
$cleanMachinePassed = ($Mode -ceq 'Live' -and
    $status -ceq 'PASS' -and
    $preflightPassed -and
    $script:CleanMachineFilesystemObserved -and
    $allLifecyclePassed -and
    [string]$cleanup.status -ceq 'PASS' -and
    $cleanup.ownedStageRemoved -and
    $cleanup.ownedBackupRemoved -and
    $cleanup.simulationRootRemoved -and
    (-not $script:HarnessMarkerCreated -or $cleanup.harnessSeededDataMarkerRemoved))
$evidenceClass = if ($cleanMachinePassed) {
    'CleanMachine'
} elseif ($Mode -eq 'Fixture') {
    'Synthetic'
} else {
    'Static'
}

$report = [ordered]@{
    schemaVersion = 1
    reportKind = 'HerdrOps.InstallAcceptanceReport'
    issue = $script:AcceptanceIssue
    acceptanceVersion = $script:AcceptanceVersion
    status = $status
    mode = $Mode
    evidenceClass = $evidenceClass
    startedAtUtc = $script:StartedAtUtc
    completedAtUtc = Get-OperatorUtcNow
    runId = $script:RunId
    machine = [ordered]@{
        name = $(if ([string]::IsNullOrWhiteSpace($machineName)) { 'NOT_OBSERVED' } else { $machineName })
        expectedName = $(if ([string]::IsNullOrWhiteSpace($ExpectedMachineName)) { 'NOT_OBSERVED' } else { $ExpectedMachineName })
        fingerprint = $(if ([string]::IsNullOrWhiteSpace($machineFingerprint)) { ('0' * 64) } else { $machineFingerprint })
        expectedFingerprint = $(if ([string]::IsNullOrWhiteSpace($ExpectedMachineFingerprint)) { ('0' * 64) } else { $ExpectedMachineFingerprint })
        elevated = $isElevated
    }
    artifacts = [ordered]@{
        initial = $initialArtifactReport
        upgrade = $upgradeArtifactReport
    }
    targets = $targetsReport
    preflight = [ordered]@{
        status = if ($preflightPassed) { 'PASS' } else { 'FAIL' }
        checks = @($script:PreflightChecks.ToArray())
    }
    lifecycle = $lifecycle
    cleanup = $cleanup
    failureDetails = $failureDetails
    transcript = @($script:Transcript.ToArray())
    boundaries = [ordered]@{
        static = if ($preflightPassed) { 'PASS: acceptance operator source, paths, archive hashes, and contracts verified.' } else { "OBSERVED $status`: static preflight failed." }
        synthetic = if ($Mode -eq 'Fixture') { 'PASS: fixture lifecycle execution.' } else { 'NOT OBSERVED BY THIS LIVE INVOCATION' }
        contract = 'NOT OBSERVED: no named-pipe or installed-Herdr IPC compatibility assertions.'
        cleanMachine = if ($cleanMachinePassed) { 'PASS: live clean-machine filesystem install, upgrade, rollback, uninstall, and settings retention lifecycle.' } else { 'NOT OBSERVED' }
        runtime = 'NOT OBSERVED: no live Herdr runtime connection was evaluated.'
        independentReview = 'NOT OBSERVED.'
        release = 'NOT OBSERVED: no package publication or GitHub Release action performed.'
    }
}

$reportSchemaPath = Join-Path $PSScriptRoot '..\..\docs\acceptance\issue-44-install-acceptance-report.schema.json'
if (-not (Test-Path -LiteralPath $reportSchemaPath -PathType Leaf)) {
    throw "Issue #44 report schema is unavailable; refusing to publish or credit an unvalidated report: $reportSchemaPath"
}
Assert-AcceptanceNoReparsePath -Path $reportSchemaPath
Assert-AcceptanceReportMatchesSchema -Report $report -SchemaPath $reportSchemaPath

if ([string]::IsNullOrWhiteSpace($ReportDestination)) {
    if ($status -ne 'PASS') {
        throw "Issue #44 operator failed and cannot durably persist its schema-valid failure report because explicit -ReportDestination/reportPath is missing. Original failure: $failureDetails"
    }
} elseif (-not [string]::IsNullOrWhiteSpace([string]$targetsReport.installRoot) -and
    -not [string]::IsNullOrWhiteSpace([string]$targetsReport.userDataRoot)) {
    $script:ReportDestination = Write-AcceptanceReportAtomically -Report $report -Path $ReportDestination `
        -InstallRoot $targetsReport.installRoot -UserDataRoot $targetsReport.userDataRoot -AllowExternalParent:($Mode -eq 'Live')
} else {
    $script:ReportDestination = Write-Issue44ReportDurably -Report $report -Path $ReportDestination
}

if ($status -ne 'PASS') {
    Write-Output $report
    throw "Issue #44 live operator failed: $failureDetails"
}

Write-Output $report
