#requires -Version 5.1

Set-StrictMode -Version Latest

function Get-Issue44BytesSha256 {
    param([Parameter(Mandatory = $true)][byte[]]$Bytes)

    $sha = [Security.Cryptography.SHA256]::Create()
    try { return ([BitConverter]::ToString($sha.ComputeHash($Bytes))).Replace('-', '') }
    finally { $sha.Dispose() }
}

function ConvertFrom-Issue44SemanticEvidenceBytes {
    param(
        [Parameter(Mandatory = $true)][byte[]]$Bytes,
        [Parameter(Mandatory = $true)][string]$ExpectedNonce,
        [Parameter(Mandatory = $true)]$CoreIdentity,
        [Parameter(Mandatory = $true)]$AppIdentity
    )

    if ($Bytes.Length -le 0 -or $Bytes.Length -gt 32768) {
        throw 'Issue #44 semantic evidence size is outside the bounded 1..32768 byte range.'
    }
    if ($ExpectedNonce -cnotmatch '^[0-9A-F]{64}$') {
        throw 'Expected Issue #44 acceptance nonce must be 64 uppercase hexadecimal characters.'
    }

    try { $json = (New-Object Text.UTF8Encoding($false, $true)).GetString($Bytes) }
    catch { throw "Issue #44 semantic evidence is not strict UTF-8: $($_.Exception.Message)" }
    $evidence = ConvertFrom-StrictPackageJson -Json $json -Description 'Issue #44 App/Core semantic evidence'
    Assert-AcceptanceExactProperties -Object $evidence -Names @(
        'SchemaVersion', 'AcceptanceNonce', 'ClientInstanceId', 'CorrelationId',
        'ServerInstanceId', 'CoreProcessId', 'CoreProcessStartUtcTicks',
        'CoreExecutablePath', 'CoreExecutableSha256', 'AppProcessId',
        'AppProcessStartUtcTicks', 'AppExecutablePath', 'AppExecutableSha256',
        'SnapshotSequence') -Context 'Issue #44 App/Core semantic evidence'

    if ([int]$evidence.SchemaVersion -ne 1) { throw 'Issue #44 semantic evidence SchemaVersion must be 1.' }
    if ([string]$evidence.AcceptanceNonce -cne $ExpectedNonce) { throw 'Issue #44 semantic evidence nonce does not match this operator run.' }
    if ([string]$evidence.ClientInstanceId -cnotmatch '^[0-9a-f]{32}$' -or
        [string]$evidence.CorrelationId -cnotmatch '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$' -or
        [string]$evidence.ServerInstanceId -cnotmatch '^[0-9a-f]{32}$') {
        throw 'Issue #44 semantic evidence lacks valid handshake identity fields.'
    }

    $coreExpectedPath = [IO.Path]::GetFullPath([string]$CoreIdentity.Path)
    $appExpectedPath = [IO.Path]::GetFullPath([string]$AppIdentity.Path)
    $coreObservedPath = [IO.Path]::GetFullPath([string]$evidence.CoreExecutablePath)
    $appObservedPath = [IO.Path]::GetFullPath([string]$evidence.AppExecutablePath)
    if ([int]$evidence.CoreProcessId -ne [int]$CoreIdentity.Id -or
        [long]$evidence.CoreProcessStartUtcTicks -ne [long]$CoreIdentity.StartUtcTicks -or
        -not [StringComparer]::OrdinalIgnoreCase.Equals($coreObservedPath, $coreExpectedPath) -or
        [string]$evidence.CoreExecutableSha256 -cne [string]$CoreIdentity.Sha256) {
        throw 'Issue #44 semantic evidence is not owned by the exact launched Core PID/start/path/hash.'
    }
    if ([int]$evidence.AppProcessId -ne [int]$AppIdentity.Id -or
        [long]$evidence.AppProcessStartUtcTicks -ne [long]$AppIdentity.StartUtcTicks -or
        -not [StringComparer]::OrdinalIgnoreCase.Equals($appObservedPath, $appExpectedPath) -or
        [string]$evidence.AppExecutableSha256 -cne [string]$AppIdentity.Sha256) {
        throw 'Issue #44 semantic evidence is not owned by the exact launched App PID/start/path/hash.'
    }
    if ([long]$evidence.SnapshotSequence -lt 0) { throw 'Issue #44 semantic evidence snapshot sequence cannot be negative.' }

    $nonceBytes = (New-Object Text.UTF8Encoding($false, $true)).GetBytes($ExpectedNonce)
    return [pscustomobject][ordered]@{
        schemaVersion = [int]$evidence.SchemaVersion
        acceptanceNonceSha256 = Get-Issue44BytesSha256 -Bytes $nonceBytes
        clientInstanceId = [string]$evidence.ClientInstanceId
        correlationId = [string]$evidence.CorrelationId
        serverInstanceId = [string]$evidence.ServerInstanceId
        coreProcessId = [int]$evidence.CoreProcessId
        coreProcessStartUtcTicks = [long]$evidence.CoreProcessStartUtcTicks
        coreExecutablePath = $coreObservedPath
        coreExecutableSha256 = [string]$evidence.CoreExecutableSha256
        appProcessId = [int]$evidence.AppProcessId
        appProcessStartUtcTicks = [long]$evidence.AppProcessStartUtcTicks
        appExecutablePath = $appObservedPath
        appExecutableSha256 = [string]$evidence.AppExecutableSha256
        snapshotSequence = [long]$evidence.SnapshotSequence
        rawEvidenceBytes = [long]$Bytes.Length
        rawEvidenceSha256 = Get-Issue44BytesSha256 -Bytes $Bytes
    }
}

function Read-Issue44SemanticEvidence {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$OwnedDirectory,
        [Parameter(Mandatory = $true)][string]$ExpectedNonce,
        [Parameter(Mandatory = $true)]$CoreIdentity,
        [Parameter(Mandatory = $true)]$AppIdentity,
        [scriptblock]$AfterOpenTestHook
    )

    $directoryFull = [IO.Path]::GetFullPath($OwnedDirectory)
    $pathFull = [IO.Path]::GetFullPath($Path)
    if (-not (Test-PathWithin -ChildPath $pathFull -RootPath $directoryFull) -or
        -not [StringComparer]::OrdinalIgnoreCase.Equals((Split-Path -Path $pathFull -Parent), $directoryFull)) {
        throw 'Issue #44 semantic evidence must be directly contained by its operator-owned directory.'
    }
    Assert-AcceptanceNoReparsePath -Path $directoryFull
    Assert-AcceptanceNoReparsePath -Path $pathFull
    if (-not (Test-Path -LiteralPath $pathFull -PathType Leaf)) { throw 'Issue #44 semantic evidence file is unavailable.' }

    $stream = New-Object IO.FileStream($pathFull, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::None)
    try {
        if ($null -ne $AfterOpenTestHook) { & $AfterOpenTestHook $pathFull }
        if ($stream.Length -le 0 -or $stream.Length -gt 32768) {
            throw 'Issue #44 semantic evidence size is outside the bounded 1..32768 byte range.'
        }
        $bytes = New-Object byte[] ([int]$stream.Length)
        $offset = 0
        while ($offset -lt $bytes.Length) {
            $read = $stream.Read($bytes, $offset, $bytes.Length - $offset)
            if ($read -le 0) { throw 'Issue #44 semantic evidence ended before the bounded read completed.' }
            $offset += $read
        }
        Assert-AcceptanceNoReparsePath -Path $directoryFull
        Assert-AcceptanceNoReparsePath -Path $pathFull
        if (-not (Test-Path -LiteralPath $pathFull -PathType Leaf) -or
            (Get-Item -LiteralPath $pathFull -Force).Length -ne $bytes.Length) {
            throw 'Issue #44 semantic evidence changed during its single-read verification.'
        }
        $validated = ConvertFrom-Issue44SemanticEvidenceBytes -Bytes $bytes -ExpectedNonce $ExpectedNonce `
            -CoreIdentity $CoreIdentity -AppIdentity $AppIdentity
    } finally { $stream.Dispose() }
    return $validated
}
