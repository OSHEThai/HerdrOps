#requires -Version 5.1

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot '..\v0.2-renderer-compatibility\RendererCompatibility.Common.ps1')

if ($null -eq ('HumanVisualGo.NativeFile' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;

namespace HumanVisualGo {
    public static class NativeFile {
        private const uint GenericRead = 0x80000000;
        private const uint FileShareRead = 0x00000001;
        private const uint FileShareWrite = 0x00000002;
        private const uint OpenExisting = 3;
        private const uint FileFlagBackupSemantics = 0x02000000;
        private const uint FileFlagOpenReparsePoint = 0x00200000;

        [StructLayout(LayoutKind.Sequential)]
        private struct FileInformation {
            public uint FileAttributes;
            public System.Runtime.InteropServices.ComTypes.FILETIME CreationTime;
            public System.Runtime.InteropServices.ComTypes.FILETIME LastAccessTime;
            public System.Runtime.InteropServices.ComTypes.FILETIME LastWriteTime;
            public uint VolumeSerialNumber;
            public uint FileSizeHigh;
            public uint FileSizeLow;
            public uint NumberOfLinks;
            public uint FileIndexHigh;
            public uint FileIndexLow;
        }

        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        private static extern SafeFileHandle CreateFile(
            string fileName,
            uint desiredAccess,
            uint shareMode,
            IntPtr securityAttributes,
            uint creationDisposition,
            uint flagsAndAttributes,
            IntPtr templateFile);

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern uint GetFinalPathNameByHandle(
            SafeFileHandle handle,
            [Out] System.Text.StringBuilder path,
            uint length,
            uint flags);

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool GetFileInformationByHandle(
            SafeFileHandle handle,
            out FileInformation information);

        public static SafeFileHandle OpenDirectory(string path) {
            // Share read/write but not delete. This prevents rename/delete of the
            // evidence directory while the held evidence set is being consumed.
            SafeFileHandle handle = CreateFile(
                path,
                GenericRead,
                FileShareRead | FileShareWrite,
                IntPtr.Zero,
                OpenExisting,
                FileFlagBackupSemantics | FileFlagOpenReparsePoint,
                IntPtr.Zero);
            if (handle.IsInvalid) {
                throw new Win32Exception(Marshal.GetLastWin32Error(), "Could not hold evidence directory.");
            }
            return handle;
        }

        public static string GetFinalPath(SafeFileHandle handle) {
            var buffer = new System.Text.StringBuilder(32768);
            uint written = GetFinalPathNameByHandle(handle, buffer, (uint)buffer.Capacity, 0);
            if (written == 0 || written >= buffer.Capacity) {
                throw new Win32Exception(Marshal.GetLastWin32Error(), "GetFinalPathNameByHandle failed.");
            }
            string value = buffer.ToString();
            if (value.StartsWith(@"\\?\UNC\", StringComparison.OrdinalIgnoreCase)) {
                return @"\\" + value.Substring(8);
            }
            if (value.StartsWith(@"\\?\", StringComparison.OrdinalIgnoreCase)) {
                return value.Substring(4);
            }
            return value;
        }

        public static string GetFileIdentity(SafeFileHandle handle) {
            FileInformation information;
            if (!GetFileInformationByHandle(handle, out information)) {
                throw new Win32Exception(Marshal.GetLastWin32Error(), "GetFileInformationByHandle failed.");
            }
            return information.VolumeSerialNumber.ToString("X8") + ":" +
                information.FileIndexHigh.ToString("X8") + information.FileIndexLow.ToString("X8");
        }

        public static uint GetNumberOfLinks(SafeFileHandle handle) {
            FileInformation information;
            if (!GetFileInformationByHandle(handle, out information)) {
                throw new Win32Exception(Marshal.GetLastWin32Error(), "GetFileInformationByHandle failed.");
            }
            return information.NumberOfLinks;
        }
    }
}
'@
}

$script:HumanVisualGoSchemaId = 'https://herdrops.local/schema/v0.2/human-review-candidate.schema.json'
$script:HumanVisualGoAttestationSchemaId = 'https://herdrops.local/schema/v0.2/human-go-attestation.schema.json'
$script:HumanVisualGoMaximumSingleFileBytes = 256MB
$script:HumanVisualGoMaximumTotalBytes = 512MB
$script:HumanVisualGoAuthorizedReviewer = '@yutthaphon'
$script:HumanVisualGoAuthorizedReviewerRole = 'HumanReviewer'
$script:HumanVisualGoAuthorizedAuthorityRole = 'ProductOwner'
$script:HumanVisualGoAttestationMethod = 'EXTERNAL_CANDIDATE_SPECIFIC_HUMAN_ATTESTATION'
$script:HumanVisualGoMaximumAuthorityKeyBytes = 64KB
$script:HumanVisualGoExpectedRendererProfileId = 'herdrops-v0.2-submark-nb-software-only-20260822'
$script:HumanVisualGoExpectedRendererProfileSha256 = '96D01ED15A536F2DF50B59B43CFDEB3683DCE8667AE2E7BF6A96124182FE13A3'
$script:HumanVisualGoExpectedRendererPolicySha256 = '1D37C9C39449556EB30F9AB5B734F0C5411CF4203321AF0B238993D017229E92'

function Assert-HumanVisualGoExactProperties {
    param(
        [Parameter(Mandatory = $true)]$Object,
        [Parameter(Mandatory = $true)][string[]]$Names,
        [Parameter(Mandatory = $true)][string]$Context
    )

    if ($null -eq $Object -or $Object -isnot [pscustomobject]) {
        throw "$Context must be a JSON object."
    }
    $actual = @($Object.PSObject.Properties.Name)
    if ($actual.Count -ne $Names.Count) {
        throw "$Context must contain exactly: $($Names -join ', ')."
    }
    foreach ($name in $Names) {
        if (-not ($actual -ccontains $name)) {
            throw "$Context omitted '$name'."
        }
    }
}

function Assert-HumanVisualGoString {
    param($Value, [string]$Context)
    if ($Value -isnot [string] -or [string]::IsNullOrWhiteSpace([string]$Value)) {
        throw "$Context must be a nonempty string."
    }
}

function Assert-HumanVisualGoSha256 {
    param($Value, [string]$Context)
    if ($Value -isnot [string] -or [string]$Value -cnotmatch '^[0-9A-F]{64}$' -or
        [string]$Value -ceq ('0' * 64)) {
        throw "$Context must be a nonzero uppercase SHA-256."
    }
}

function Assert-HumanVisualGoCommitSha {
    param($Value, [string]$Context)
    if ($Value -isnot [string] -or [string]$Value -cnotmatch '^[0-9a-f]{40}$') {
        throw "$Context must be a lowercase 40-hex Git identity."
    }
}

function Assert-HumanVisualGoPositiveInteger {
    param($Value, [string]$Context)
    if ($Value -isnot [int] -and $Value -isnot [long]) {
        throw "$Context must be a native integer."
    }
    if ([long]$Value -le 0) {
        throw "$Context must be positive."
    }
}

function Assert-HumanVisualGoBoolean {
    param($Value, [string]$Context)
    if ($Value -isnot [bool]) {
        throw "$Context must be a native boolean."
    }
}

function Assert-HumanVisualGoUtc {
    param($Value, [string]$Context)
    Assert-HumanVisualGoString $Value $Context
    if ([string]$Value -notmatch '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}\.[0-9]{7}Z$') {
        throw "$Context must be canonical UTC with seven fractional digits and Z."
    }
    $parsed = [DateTimeOffset]::MinValue
    if (-not [DateTimeOffset]::TryParseExact(
            [string]$Value,
            "yyyy-MM-dd'T'HH:mm:ss.fffffff'Z'",
            [Globalization.CultureInfo]::InvariantCulture,
            [Globalization.DateTimeStyles]::AssumeUniversal,
            [ref]$parsed)) {
        throw "$Context is not a valid UTC timestamp."
    }
}

function Get-HumanVisualGoSha256ForBytes {
    param([Parameter(Mandatory = $true)][byte[]]$Bytes)
    return Get-HumanDesignReviewSha256ForBytes -Bytes $Bytes
}

function Get-HumanVisualGoCanonicalText {
    param([Parameter(Mandatory = $true)]$Value, [Parameter(Mandatory = $true)][string]$RepositoryRoot)
    return ConvertTo-RendererCanonicalJson $Value $RepositoryRoot
}

function Get-HumanVisualGoCanonicalSha256 {
    param([Parameter(Mandatory = $true)]$Value, [Parameter(Mandatory = $true)][string]$RepositoryRoot)
    return Get-HumanVisualGoSha256ForBytes -Bytes ([Text.UTF8Encoding]::new($false).GetBytes((Get-HumanVisualGoCanonicalText $Value $RepositoryRoot)))
}

function Get-HumanVisualGoAttestationSigningValue {
    param([Parameter(Mandatory = $true)]$Attestation)

    # The detached signature covers every attestation field and all authority
    # metadata except the proof hash and signature bytes themselves.  The
    # trusted verifier supplies the public key; no JSON field is a trust root.
    return [pscustomobject][ordered]@{
        '$id' = [string]$Attestation.'$id'
        schemaVersion = [int]$Attestation.schemaVersion
        evidenceClassification = [string]$Attestation.evidenceClassification
        issue = [int]$Attestation.issue
        compatibilityIssue = [int]$Attestation.compatibilityIssue
        attestationId = [string]$Attestation.attestationId
        decision = [string]$Attestation.decision
        decisionRationale = [string]$Attestation.decisionRationale
        reviewedUtc = [string]$Attestation.reviewedUtc
        replayNonce = [string]$Attestation.replayNonce
        candidate = $Attestation.candidate
        reviewer = $Attestation.reviewer
        authority = [pscustomobject][ordered]@{
            reference = [string]$Attestation.authority.reference
            authenticationMethod = [string]$Attestation.authority.authenticationMethod
            authenticated = [bool]$Attestation.authority.authenticated
            publicKeySha256 = [string]$Attestation.authority.publicKeySha256
            signatureAlgorithm = [string]$Attestation.authority.signatureAlgorithm
        }
        visualDispositions = @($Attestation.visualDispositions)
        visualChecks = @($Attestation.visualChecks)
        defects = @($Attestation.defects)
        evidenceBindings = @($Attestation.evidenceBindings)
        evidenceSetSha256 = [string]$Attestation.evidenceSetSha256
        evidenceBoundary = $Attestation.evidenceBoundary
    }
}

function Get-HumanVisualGoAttestationSigningCanonicalText {
    param(
        [Parameter(Mandatory = $true)]$Attestation,
        [Parameter(Mandatory = $true)][string]$RepositoryRoot
    )
    return Get-HumanVisualGoCanonicalText -Value (Get-HumanVisualGoAttestationSigningValue -Attestation $Attestation) -RepositoryRoot $RepositoryRoot
}

function ConvertFrom-HumanVisualGoJsonBytes {
    param([Parameter(Mandatory = $true)][byte[]]$Bytes, [Parameter(Mandatory = $true)][string]$Description)

    if ($Bytes.Length -eq 0 -or $Bytes.Length -gt $script:HumanVisualGoMaximumSingleFileBytes) {
        throw "$Description is outside the bounded JSON size."
    }
    if ($Bytes.Length -ge 3 -and $Bytes[0] -eq 0xEF -and $Bytes[1] -eq 0xBB -and $Bytes[2] -eq 0xBF) {
        throw "$Description must be UTF-8 without a BOM."
    }
    try {
        $json = [Text.UTF8Encoding]::new($false, $true).GetString($Bytes)
    }
    catch {
        throw "$Description contains malformed UTF-8."
    }
    $value = ConvertFrom-StrictHumanDesignReviewJson -Json $json -Description $Description
    if ($PSVersionTable.PSVersion.Major -ge 7 -and (Get-Command ConvertFrom-Json).Parameters.ContainsKey('DateKind')) {
        $value = $json | ConvertFrom-Json -DateKind String
    }
    if ($null -eq $value -or $value -isnot [pscustomobject]) {
        throw "$Description root must be a JSON object."
    }
    return [pscustomobject]@{ Value = $value; Json = $json }
}

function ConvertTo-HumanVisualGoCanonicalString {
    param([Parameter(Mandatory = $true)][string]$Value)

    $builder = [Text.StringBuilder]::new()
    [void]$builder.Append('"')
    :characters for ($index = 0; $index -lt $Value.Length; $index++) {
        $code = [int][char]$Value[$index]
        switch ($code) {
            8 { [void]$builder.Append('\b'); continue characters }
            9 { [void]$builder.Append('\t'); continue characters }
            10 { [void]$builder.Append('\n'); continue characters }
            12 { [void]$builder.Append('\f'); continue characters }
            13 { [void]$builder.Append('\r'); continue characters }
            34 { [void]$builder.Append('\"'); continue characters }
            92 { [void]$builder.Append('\\'); continue characters }
        }
        if ($code -lt 0x20) {
            [void]$builder.Append(('\u{0:x4}' -f $code))
            continue
        }
        if ($code -ge 0xD800 -and $code -le 0xDBFF) {
            if ($index + 1 -ge $Value.Length -or [int][char]$Value[$index + 1] -lt 0xDC00 -or [int][char]$Value[$index + 1] -gt 0xDFFF) {
                throw 'Human visual-GO canonical JSON contains an unpaired high surrogate.'
            }
            [void]$builder.Append($Value[$index])
            [void]$builder.Append($Value[++$index])
            continue
        }
        if ($code -ge 0xDC00 -and $code -le 0xDFFF) {
            throw 'Human visual-GO canonical JSON contains an unpaired low surrogate.'
        }
        [void]$builder.Append($Value[$index])
    }
    [void]$builder.Append('"')
    return $builder.ToString()
}

function ConvertTo-HumanVisualGoCanonicalNumber {
    param([Parameter(Mandatory = $true)]$Value)

    if ($Value -is [byte] -or $Value -is [sbyte] -or $Value -is [int16] -or
        $Value -is [uint16] -or $Value -is [int32] -or $Value -is [uint32] -or
        $Value -is [int64] -or $Value -is [uint64]) {
        return [Convert]::ToString($Value, [Globalization.CultureInfo]::InvariantCulture)
    }
    if ($Value -is [single] -or $Value -is [double] -or $Value -is [decimal]) {
        $number = [double]$Value
        if ([double]::IsNaN($number) -or [double]::IsInfinity($number)) {
            throw 'Human visual-GO canonical JSON numbers must be finite.'
        }
        if ($Value -is [decimal]) { return $Value.ToString('G29', [Globalization.CultureInfo]::InvariantCulture) }
        $text = $Value.ToString('R', [Globalization.CultureInfo]::InvariantCulture)
        if ($text -match '^[+-]?0\.0+$') { return '0' }
        return $text.Replace('E', 'e')
    }
    throw "Unsupported Human visual-GO JSON number type: $($Value.GetType().FullName)"
}

function ConvertTo-HumanVisualGoGenericCanonicalJson {
    param([AllowNull()][object]$Value)

    if ($null -eq $Value) { return 'null' }
    if ($Value -is [string]) { return ConvertTo-HumanVisualGoCanonicalString $Value }
    if ($Value -is [bool]) { if ($Value) { return 'true' } else { return 'false' } }
    if ($Value -is [byte] -or $Value -is [sbyte] -or $Value -is [int16] -or
        $Value -is [uint16] -or $Value -is [int32] -or $Value -is [uint32] -or
        $Value -is [int64] -or $Value -is [uint64] -or $Value -is [single] -or
        $Value -is [double] -or $Value -is [decimal]) {
        return ConvertTo-HumanVisualGoCanonicalNumber $Value
    }
    if ($Value -is [DateTimeOffset]) {
        return ConvertTo-HumanVisualGoCanonicalString ($Value.ToString('O', [Globalization.CultureInfo]::InvariantCulture))
    }
    if ($Value -is [DateTime]) {
        return ConvertTo-HumanVisualGoCanonicalString ($Value.ToString('O', [Globalization.CultureInfo]::InvariantCulture))
    }
    if ($Value -is [Collections.IDictionary]) {
        $names = [string[]]@($Value.Keys)
        [Array]::Sort($names, [StringComparer]::Ordinal)
        return '{' + (($names | ForEach-Object {
                    (ConvertTo-HumanVisualGoCanonicalString $_) + ':' + (ConvertTo-HumanVisualGoGenericCanonicalJson $Value[$_])
                }) -join ',') + '}'
    }
    if ($Value -is [Collections.IEnumerable] -and $Value -isnot [pscustomobject]) {
        return '[' + ((@($Value) | ForEach-Object { ConvertTo-HumanVisualGoGenericCanonicalJson $_ }) -join ',') + ']'
    }
    if ($Value -is [pscustomobject]) {
        $names = [string[]]@($Value.PSObject.Properties.Name)
        [Array]::Sort($names, [StringComparer]::Ordinal)
        return '{' + (($names | ForEach-Object {
                    (ConvertTo-HumanVisualGoCanonicalString $_) + ':' + (ConvertTo-HumanVisualGoGenericCanonicalJson $Value.PSObject.Properties[$_].Value)
                }) -join ',') + '}'
    }
    throw "Unsupported Human visual-GO JSON value type: $($Value.GetType().FullName)"
}

function Read-HumanVisualGoCanonicalJsonDocument {
    param([Parameter(Mandatory = $true)]$Held, [Parameter(Mandatory = $true)][string]$Description, [Parameter(Mandatory = $true)][string]$RepositoryRoot)

    $document = ConvertFrom-HumanVisualGoJsonBytes -Bytes $Held.Content -Description $Description
    # Renderer manifests include the approved fractional performance limit
    # 0.5. The package/profile canonicalizer is deliberately integer-only, so
    # held evidence gets a generic RFC-8785-shaped canonical hash here while
    # package/profile receipt bindings continue through their existing verifier.
    $canonical = ConvertTo-HumanVisualGoGenericCanonicalJson $document.Value
    $canonicalSha = Get-HumanVisualGoSha256ForBytes -Bytes ([Text.UTF8Encoding]::new($false).GetBytes($canonical))
    return [pscustomobject]@{
        Value = $document.Value
        Json = $document.Json
        Canonical = $canonical
        CanonicalSha256 = $canonicalSha
    }
}

function Assert-HumanVisualGoCanonicalJsonFile {
    param([Parameter(Mandatory = $true)]$Document, [Parameter(Mandatory = $true)][string]$Description)
    if ([string]$Document.Json -cne ([string]$Document.Canonical + "`n")) {
        throw "$Description must be canonical JSON followed by exactly one LF."
    }
}

function Assert-HumanVisualGoSchema {
    param([Parameter(Mandatory = $true)]$Value, [Parameter(Mandatory = $true)][string]$SchemaPath, [Parameter(Mandatory = $true)][string]$RepositoryRoot, [Parameter(Mandatory = $true)][string]$Description)
    if ($PSVersionTable.PSVersion.Major -ge 7 -and (Get-Command Test-Json -ErrorAction SilentlyContinue)) {
        $json = Get-HumanVisualGoCanonicalText -Value $Value -RepositoryRoot $RepositoryRoot
        if (-not ($json | Test-Json -SchemaFile $SchemaPath)) {
            throw "$Description failed its Draft 2020-12 schema."
        }
    }
}

function Test-HumanVisualGoPathUnderRoot {
    param([Parameter(Mandatory = $true)][string]$Root, [Parameter(Mandatory = $true)][string]$Path)
    $rootFull = [IO.Path]::GetFullPath($Root).TrimEnd('\', '/')
    $pathFull = [IO.Path]::GetFullPath($Path)
    return $pathFull.Equals($rootFull, [StringComparison]::OrdinalIgnoreCase) -or
        $pathFull.StartsWith($rootFull + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)
}

function Assert-HumanVisualGoNoReparsePath {
    param(
        [Parameter(Mandatory = $true)][string]$Root,
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Context
    )

    $rootFull = [IO.Path]::GetFullPath($Root).TrimEnd('\', '/')
    $pathFull = [IO.Path]::GetFullPath($Path)
    if (-not (Test-HumanVisualGoPathUnderRoot -Root $rootFull -Path $pathFull)) {
        throw "$Context escaped its root."
    }
    $rootItem = Get-Item -LiteralPath $rootFull -Force -ErrorAction Stop
    if (($rootItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw "$Context root is a reparse point."
    }
    $relative = $pathFull.Substring($rootFull.Length).TrimStart('\', '/')
    $probe = $rootFull
    foreach ($part in @($relative -split '[\\/]' | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })) {
        $probe = Join-Path $probe $part
        if (Test-Path -LiteralPath $probe) {
            $item = Get-Item -LiteralPath $probe -Force -ErrorAction Stop
            if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                throw "$Context contains a reparse point: $probe"
            }
        }
    }
}

function Resolve-HumanVisualGoContainedPath {
    param(
        [Parameter(Mandatory = $true)][string]$Root,
        [Parameter(Mandatory = $true)][string]$RelativePath,
        [Parameter(Mandatory = $true)][string]$Context
    )

    Assert-HumanVisualGoString $RelativePath "$Context relativePath"
    if ([IO.Path]::IsPathRooted($RelativePath) -or $RelativePath -match '(^|[\\/])\.\.([\\/]|$)' -or
        $RelativePath -match '^[A-Za-z]:') {
        throw "$Context must be a contained relative path."
    }
    $rootFull = [IO.Path]::GetFullPath($Root).TrimEnd('\', '/')
    $full = [IO.Path]::GetFullPath((Join-Path $rootFull $RelativePath))
    if (-not (Test-HumanVisualGoPathUnderRoot -Root $rootFull -Path $full) -or
        $full.Equals($rootFull, [StringComparison]::OrdinalIgnoreCase)) {
        throw "$Context escaped its root."
    }
    Assert-HumanVisualGoNoReparsePath -Root $rootFull -Path $full -Context $Context
    return $full
}

function Get-HumanVisualGoRelativePath {
    param([Parameter(Mandatory = $true)][string]$Root, [Parameter(Mandatory = $true)][string]$Path, [Parameter(Mandatory = $true)][string]$Context)
    $rootFull = [IO.Path]::GetFullPath($Root).TrimEnd('\', '/')
    $pathFull = [IO.Path]::GetFullPath($Path)
    if (-not (Test-HumanVisualGoPathUnderRoot -Root $rootFull -Path $pathFull) -or
        $pathFull.Equals($rootFull, [StringComparison]::OrdinalIgnoreCase)) {
        throw "$Context is outside its root."
    }
    return $pathFull.Substring($rootFull.Length).TrimStart('\', '/').Replace('\', '/')
}

function Assert-HumanVisualGoExternalPath {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$RepositoryRoot,
        [Parameter(Mandatory = $true)][string]$EvidenceRoot,
        [Parameter(Mandatory = $true)][string]$Context
    )
    Assert-HumanVisualGoString $Path $Context
    $full = [IO.Path]::GetFullPath($Path)
    if ((Test-HumanVisualGoPathUnderRoot -Root $RepositoryRoot -Path $full) -or
        (Test-HumanVisualGoPathUnderRoot -Root $EvidenceRoot -Path $full)) {
        throw "$Context must be external to the repository and evidence root; repository-pinned authority is forbidden."
    }
    $parent = Split-Path -Parent $full
    if (-not (Test-Path -LiteralPath $parent -PathType Container)) {
        throw "$Context parent directory is missing."
    }
    $volumeRoot = [IO.Path]::GetPathRoot($full)
    Assert-HumanVisualGoNoReparsePath -Root $volumeRoot -Path $parent -Context "$Context parent"
    if (Test-Path -LiteralPath $full) {
        $item = Get-Item -LiteralPath $full -Force
        if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw "$Context is a reparse point."
        }
    }
    return $full
}

function Assert-HumanVisualGoExternalDirectory {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$RepositoryRoot,
        [Parameter(Mandatory = $true)][string]$EvidenceRoot,
        [Parameter(Mandatory = $true)][string]$Context
    )

    Assert-HumanVisualGoString $Path $Context
    $full = [IO.Path]::GetFullPath($Path).TrimEnd('\', '/')
    if ((Test-HumanVisualGoPathUnderRoot -Root $RepositoryRoot -Path $full) -or
        (Test-HumanVisualGoPathUnderRoot -Root $EvidenceRoot -Path $full)) {
        throw "$Context must be external to the repository and evidence root; repository-pinned replay state is forbidden."
    }
    if (-not (Test-Path -LiteralPath $full -PathType Container)) {
        throw "$Context directory is missing."
    }
    Assert-HumanVisualGoNoReparsePath -Root ([IO.Path]::GetPathRoot($full)) -Path $full -Context $Context
    return $full
}

function Get-HumanVisualGoFixedReplayLedgerRoot {
    $knownFolder = [Environment]::GetFolderPath([Environment+SpecialFolder]::LocalApplicationData)
    if ([string]::IsNullOrWhiteSpace($knownFolder)) {
        throw 'TRUST_ROOT_NOT_CONFIGURED: the trusted LocalApplicationData Known Folder is unavailable.'
    }
    # This is a fixed product-local location, not a caller-selected trust or
    # replay root. It remains unused until Plan supplies the authority and
    # freshness policy required for a production Human decision.
    return [IO.Path]::GetFullPath((Join-Path $knownFolder 'HerdrOps\v0.2\human-visual-go\replay-ledger')).TrimEnd('\', '/')
}

function New-HumanVisualGoHoldContext {
    return [pscustomobject]@{
        Files = @{}
        Identities = @{}
        Bindings = @()
        BindingByKind = @{}
        Roots = @{}
        TotalBytes = [long]0
        Closed = $false
    }
}

function Open-HumanVisualGoRootHandle {
    param([Parameter(Mandatory = $true)]$Context, [Parameter(Mandatory = $true)][string]$Root, [Parameter(Mandatory = $true)][string]$ContextName)
    $full = [IO.Path]::GetFullPath($Root).TrimEnd('\', '/')
    if (-not (Test-Path -LiteralPath $full -PathType Container)) {
        throw "$ContextName is missing."
    }
    Assert-HumanVisualGoNoReparsePath -Root $full -Path $full -Context $ContextName
    $key = $full.ToUpperInvariant()
    if (-not $Context.Roots.ContainsKey($key)) {
        $Context.Roots[$key] = [HumanVisualGo.NativeFile]::OpenDirectory($full)
    }
}

function Open-HumanVisualGoAbsoluteHeldFile {
    param(
        [Parameter(Mandatory = $true)]$Context,
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$ContextName,
        [Parameter(Mandatory = $true)][string]$Root,
        [Parameter(Mandatory = $true)][string]$RootKind
    )

    if ($Context.Closed) { throw 'The Human visual-GO hold context is already closed.' }
    $full = [IO.Path]::GetFullPath($Path)
    Assert-HumanVisualGoNoReparsePath -Root $Root -Path $full -Context $ContextName
    if (-not (Test-Path -LiteralPath $full -PathType Leaf)) {
        throw "$ContextName file is missing."
    }
    $key = $full.ToUpperInvariant()
    $existing = $null
    if ($Context.Files.ContainsKey($key)) {
        $existing = $Context.Files[$key]
        if ($null -ne $existing.Stream) { return $existing }
    }

    $parent = Split-Path -Parent $full
    $parentHandle = $null
    $stream = $null
    try {
        # Open the directory first without FILE_SHARE_DELETE, then the file
        # without write/delete sharing. The exact bytes and final handle path
        # are therefore stable while this hold is active.
        $parentHandle = [HumanVisualGo.NativeFile]::OpenDirectory($parent)
        $stream = New-Object IO.FileStream($full, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
        $final = [IO.Path]::GetFullPath([HumanVisualGo.NativeFile]::GetFinalPath($stream.SafeFileHandle))
        if (-not $final.Equals($full, [StringComparison]::OrdinalIgnoreCase)) {
            throw "$ContextName final path is not the requested path; alias/reparse detected."
        }
        $length = [long]$stream.Length
        if ($length -le 0 -or $length -gt $script:HumanVisualGoMaximumSingleFileBytes) {
            throw "$ContextName is outside the bounded held-file size."
        }
        $bytes = New-Object byte[] ([int]$length)
        $offset = 0
        while ($offset -lt $bytes.Length) {
            $read = $stream.Read($bytes, $offset, $bytes.Length - $offset)
            if ($read -le 0) { throw "$ContextName ended during the held read." }
            $offset += $read
        }
        if ($stream.Length -ne $length -or $stream.Position -ne $length) {
            throw "$ContextName changed during the same-handle read."
        }
        $identity = [HumanVisualGo.NativeFile]::GetFileIdentity($stream.SafeFileHandle)
        $linkCount = [uint32][HumanVisualGo.NativeFile]::GetNumberOfLinks($stream.SafeFileHandle)
        if ($linkCount -gt 1) {
            throw "$ContextName has NumberOfLinks=$linkCount; external hardlink/file-identity aliases are forbidden."
        }
        if ($Context.Identities.ContainsKey($identity) -and
            -not $Context.Identities[$identity].Equals($full, [StringComparison]::OrdinalIgnoreCase)) {
            throw "$ContextName is a hardlink/file-identity alias of '$($Context.Identities[$identity])'."
        }
        $hash = Get-HumanVisualGoSha256ForBytes -Bytes $bytes
        if ($null -ne $existing) {
            if ($existing.Bytes -ne $length -or $existing.Sha256 -cne $hash -or
                $existing.FileIdentity -cne $identity -or
                $existing.FinalPath -cne $final -or $existing.LinkCount -ne $linkCount) {
                throw "$ContextName changed while reacquiring its held bytes."
            }
            $existing.Stream = $stream
            $existing.ParentHandle = $parentHandle
            $stream = $null
            $parentHandle = $null
            return $existing
        }
        if ($Context.TotalBytes + $length -gt $script:HumanVisualGoMaximumTotalBytes) {
            throw 'The Human visual-GO held evidence set exceeds its total bounded size.'
        }
        $held = [pscustomobject]@{
            Path = $full
            Root = $Root
            RootKind = $RootKind
            Bytes = $length
            Sha256 = $hash
            Content = $bytes
            FinalPath = $final
            FileIdentity = $identity
            LinkCount = $linkCount
            Stream = $stream
            ParentHandle = $parentHandle
        }
        $Context.Files[$key] = $held
        $Context.Identities[$identity] = $full
        $Context.TotalBytes += $length
        $stream = $null
        $parentHandle = $null
        return $held
    }
    catch {
        if ($null -ne $stream) { $stream.Dispose() }
        if ($null -ne $parentHandle) { $parentHandle.Dispose() }
        throw
    }
}

function Assert-HumanVisualGoHeldUnchanged {
    param([Parameter(Mandatory = $true)]$Context, [string]$Description = 'held Human visual-GO evidence')

    foreach ($held in @($Context.Files.Values | Sort-Object Path)) {
        $final = [IO.Path]::GetFullPath([HumanVisualGo.NativeFile]::GetFinalPath($held.Stream.SafeFileHandle))
        if (-not $final.Equals([string]$held.FinalPath, [StringComparison]::OrdinalIgnoreCase)) {
            throw "$Description path changed for '$($held.Path)'."
        }
        $identity = [HumanVisualGo.NativeFile]::GetFileIdentity($held.Stream.SafeFileHandle)
        if ($identity -cne [string]$held.FileIdentity) {
            throw "$Description file identity changed for '$($held.Path)'."
        }
        $linkCount = [uint32][HumanVisualGo.NativeFile]::GetNumberOfLinks($held.Stream.SafeFileHandle)
        if ($linkCount -gt 1 -or $linkCount -ne [uint32]$held.LinkCount) {
            throw "$Description NumberOfLinks changed for '$($held.Path)'; external hardlink/file-identity aliases are forbidden."
        }
        $length = [long]$held.Stream.Length
        if ($length -ne [long]$held.Bytes) {
            throw "$Description byte length changed for '$($held.Path)'."
        }
        $held.Stream.Position = 0
        $current = New-Object byte[] ([int]$length)
        $offset = 0
        while ($offset -lt $current.Length) {
            $read = $held.Stream.Read($current, $offset, $current.Length - $offset)
            if ($read -le 0) { throw "$Description ended during post-validation recheck for '$($held.Path)'." }
            $offset += $read
        }
        $currentHash = Get-HumanVisualGoSha256ForBytes -Bytes $current
        if ($currentHash -cne [string]$held.Sha256) {
            throw "$Description bytes changed during post-validation recheck for '$($held.Path)'."
        }
        $held.Stream.Position = $held.Stream.Length
    }
}

function Open-HumanVisualGoContainedHeldFile {
    param(
        [Parameter(Mandatory = $true)]$Context,
        [Parameter(Mandatory = $true)][string]$Root,
        [Parameter(Mandatory = $true)][string]$RelativePath,
        [Parameter(Mandatory = $true)][string]$ContextName,
        [Parameter(Mandatory = $true)][string]$RootKind
    )
    $full = Resolve-HumanVisualGoContainedPath -Root $Root -RelativePath $RelativePath -Context $ContextName
    return Open-HumanVisualGoAbsoluteHeldFile -Context $Context -Path $full -ContextName $ContextName -Root ([IO.Path]::GetFullPath($Root).TrimEnd('\', '/')) -RootKind $RootKind
}

function Close-HumanVisualGoHoldContext {
    param([Parameter(Mandatory = $true)]$Context)
    if ($Context.Closed) { return }
    foreach ($held in @($Context.Files.Values)) {
        try { $held.Stream.Dispose() } catch { }
        try { $held.ParentHandle.Dispose() } catch { }
    }
    foreach ($rootHandle in @($Context.Roots.Values)) {
        try { $rootHandle.Dispose() } catch { }
    }
    $Context.Closed = $true
}

function Read-HumanVisualGoHeldJson {
    param([Parameter(Mandatory = $true)]$Held, [Parameter(Mandatory = $true)][string]$Description, [Parameter(Mandatory = $true)][string]$RepositoryRoot)
    return Read-HumanVisualGoCanonicalJsonDocument -Held $Held -Description $Description -RepositoryRoot $RepositoryRoot
}

function Add-HumanVisualGoEvidenceBinding {
    param(
        [Parameter(Mandatory = $true)]$Context,
        [Parameter(Mandatory = $true)][string]$Root,
        [Parameter(Mandatory = $true)][string]$RootKind,
        [Parameter(Mandatory = $true)][string]$RelativePath,
        [Parameter(Mandatory = $true)][string]$Kind,
        [Parameter(Mandatory = $true)][string]$RepositoryRoot,
        [switch]$Json,
        $Expected
    )

    if ($Context.BindingByKind.ContainsKey($Kind)) {
        throw "Duplicate Human visual-GO evidence kind '$Kind'."
    }
    $held = Open-HumanVisualGoContainedHeldFile -Context $Context -Root $Root -RelativePath $RelativePath -ContextName $Kind -RootKind $RootKind
    $canonicalSha = $null
    if ($Json) {
        $document = Read-HumanVisualGoHeldJson -Held $held -Description $Kind -RepositoryRoot $RepositoryRoot
        $canonicalSha = $document.CanonicalSha256
    }
    if ($null -ne $Expected) {
        if ($Expected.PSObject.Properties.Name -contains 'bytes' -and [long]$Expected.bytes -ne $held.Bytes) {
            throw "$Kind byte binding mismatch."
        }
        $expectedRaw = $null
        if ($Expected.PSObject.Properties.Name -contains 'fileSha256') { $expectedRaw = [string]$Expected.fileSha256 }
        elseif ($Expected.PSObject.Properties.Name -contains 'sha256') { $expectedRaw = [string]$Expected.sha256 }
        if (-not [string]::IsNullOrWhiteSpace($expectedRaw) -and $expectedRaw.ToUpperInvariant() -cne $held.Sha256.ToUpperInvariant()) {
            throw "$Kind raw SHA-256 binding mismatch."
        }
        if ($Expected.PSObject.Properties.Name -contains 'canonicalSha256' -and
            -not [string]::IsNullOrWhiteSpace([string]$Expected.canonicalSha256) -and
            [string]$Expected.canonicalSha256.ToUpperInvariant() -cne [string]$canonicalSha.ToUpperInvariant()) {
            throw "$Kind canonical SHA-256 binding mismatch."
        }
    }
    $binding = [pscustomobject][ordered]@{
        kind = $Kind
        root = $RootKind
        relativePath = $RelativePath.Replace('\', '/')
        bytes = [long]$held.Bytes
        sha256 = [string]$held.Sha256
        canonicalSha256 = $canonicalSha
    }
    $Context.BindingByKind[$Kind] = $binding
    $Context.Bindings += $binding
    return $binding
}

function Get-HumanVisualGoBinding {
    param([Parameter(Mandatory = $true)]$Context, [Parameter(Mandatory = $true)][string]$Kind)
    if (-not $Context.BindingByKind.ContainsKey($Kind)) {
        throw "Required Human visual-GO evidence kind '$Kind' was not held."
    }
    return $Context.BindingByKind[$Kind]
}

function Get-HumanVisualGoHeldForBinding {
    param([Parameter(Mandatory = $true)]$Context, [Parameter(Mandatory = $true)]$Binding)
    $root = $null
    if ([string]$Binding.root -ceq 'EvidenceRoot') { $root = $script:HumanVisualGoCurrentEvidenceRoot }
    elseif ([string]$Binding.root -ceq 'RepositoryRoot') { $root = $script:HumanVisualGoCurrentRepositoryRoot }
    else { throw "Unknown Human visual-GO binding root '$($Binding.root)'." }
    $full = [IO.Path]::GetFullPath((Join-Path $root ([string]$Binding.relativePath)))
    $key = $full.ToUpperInvariant()
    if (-not $Context.Files.ContainsKey($key)) { throw "Binding '$($Binding.kind)' is not held." }
    return $Context.Files[$key]
}

function Assert-HumanVisualGoExternalUri {
    param([Parameter(Mandatory = $true)][string]$Reference)
    Assert-HumanVisualGoString $Reference 'External authority reference'
    $uri = $null
    if (-not [Uri]::TryCreate($Reference, [UriKind]::Absolute, [ref]$uri) -or
        $uri.Scheme -cne 'https' -or [string]::IsNullOrWhiteSpace($uri.Host) -or
        $uri.Host -match '^(localhost|127\.0\.0\.1|::1)$' -or $uri.Host -ceq 'herdrops.local') {
        throw 'Human attestation authority reference must be an external HTTPS URI.'
    }
    if ($Reference -match '[\\]' -or $Reference -match '(^|/)Plan(/|$)') {
        throw 'Human attestation authority reference must not be a repository path.'
    }
}

function Assert-HumanVisualGoAttestationAuthority {
    param(
        [Parameter(Mandatory = $true)]$Attestation,
        [Parameter(Mandatory = $true)][string]$TrustedAuthorityPublicKeyXml,
        [Parameter(Mandatory = $true)][string]$TrustedAuthorityPublicKeySha256,
        [Parameter(Mandatory = $true)][string]$ExpectedSignatureAlgorithm,
        [Parameter(Mandatory = $true)][string]$RepositoryRoot
    )

    Assert-HumanVisualGoExactProperties $Attestation.authority @('reference', 'authenticationMethod', 'authenticated', 'proofSha256', 'publicKeySha256', 'signatureAlgorithm', 'signatureBase64') 'External attestation authority'
    Assert-HumanVisualGoExternalUri -Reference ([string]$Attestation.authority.reference)
    Assert-HumanVisualGoString $ExpectedSignatureAlgorithm 'Expected Human authority signature algorithm'
    if ([string]$Attestation.authority.authenticationMethod -cne $script:HumanVisualGoAttestationMethod) {
        throw 'External Human attestation authentication method is not the governed external method.'
    }
    Assert-HumanVisualGoBoolean $Attestation.authority.authenticated 'External Human authority authenticated'
    if (-not [bool]$Attestation.authority.authenticated) {
        throw 'External Human authority authenticated must be true only after trusted signature verification.'
    }
    if ([string]$Attestation.authority.signatureAlgorithm -cne $ExpectedSignatureAlgorithm) {
        throw 'External Human authority signature algorithm does not equal the independently supplied expected algorithm.'
    }
    Assert-HumanVisualGoSha256 $Attestation.authority.publicKeySha256 'External Human authority public-key SHA-256'
    Assert-HumanVisualGoSha256 $TrustedAuthorityPublicKeySha256 'Trusted authority public-key SHA-256'
    Assert-HumanVisualGoString $TrustedAuthorityPublicKeyXml 'Trusted authority public-key XML'
    $trustedKeyBytes = [Text.UTF8Encoding]::new($false, $true).GetBytes($TrustedAuthorityPublicKeyXml)
    if ($trustedKeyBytes.Length -le 0 -or $trustedKeyBytes.Length -gt $script:HumanVisualGoMaximumAuthorityKeyBytes) {
        throw 'Trusted authority public-key XML is outside the bounded key size.'
    }
    $computedKeySha = Get-HumanVisualGoSha256ForBytes -Bytes $trustedKeyBytes
    if ($computedKeySha -cne [string]$TrustedAuthorityPublicKeySha256 -or
        [string]$Attestation.authority.publicKeySha256 -cne $computedKeySha) {
        throw 'External Human authority public-key fingerprint does not equal the independently supplied trusted key.'
    }

    Assert-HumanVisualGoString $Attestation.authority.signatureBase64 'External Human authority signature'
    $signatureBytes = $null
    try { $signatureBytes = [Convert]::FromBase64String([string]$Attestation.authority.signatureBase64) }
    catch { throw 'External Human authority signature is not valid base64.' }
    if ($signatureBytes.Length -le 0 -or $signatureBytes.Length -gt 64KB) {
        throw 'External Human authority signature is outside the bounded size.'
    }
    $payload = Get-HumanVisualGoAttestationSigningCanonicalText -Attestation $Attestation -RepositoryRoot $RepositoryRoot
    $payloadBytes = [Text.UTF8Encoding]::new($false, $true).GetBytes($payload)
    $rsa = $null
    try {
        $rsa = New-Object System.Security.Cryptography.RSACryptoServiceProvider
        try { $rsa.FromXmlString($TrustedAuthorityPublicKeyXml) }
        catch { throw 'Trusted authority public-key XML is not a usable RSA public key.' }
        $verified = $false
        try { $verified = [bool]$rsa.VerifyData($payloadBytes, 'SHA256', $signatureBytes) }
        catch { throw 'Trusted authority signature verification could not be performed.' }
        if (-not $verified) {
            throw 'Trusted cryptographic authority signature verification failed.'
        }
    }
    finally {
        if ($null -ne $rsa) { $rsa.Dispose() }
    }
    Assert-HumanVisualGoSha256 $Attestation.authority.proofSha256 'External Human authority proof SHA-256'
    $computedProofSha = Get-HumanVisualGoSha256ForBytes -Bytes $signatureBytes
    if ([string]$Attestation.authority.proofSha256 -cne $computedProofSha) {
        throw 'External Human authority proof SHA-256 does not equal the verified signature bytes.'
    }
}

function ConvertFrom-HumanVisualGoEvidenceUtc {
    param([Parameter(Mandatory = $true)][string]$Value, [Parameter(Mandatory = $true)][string]$Name)
    $parsed = [DateTimeOffset]::MinValue
    $formats = @("yyyy-MM-dd'T'HH:mm:ss'Z'", "yyyy-MM-dd'T'HH:mm:ss.fffffff'Z'", "yyyy-MM-dd'T'HH:mm:ss.fffffffzzz")
    $matched = $false
    foreach ($format in $formats) {
        $candidate = [DateTimeOffset]::MinValue
        if ([DateTimeOffset]::TryParseExact($Value, $format, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::AssumeUniversal, [ref]$candidate)) {
            $parsed = $candidate
            $matched = $true
            break
        }
    }
    if (-not $matched -or $parsed.Offset -ne [TimeSpan]::Zero) {
        throw "Evidence timestamp '$Name' is not canonical UTC."
    }
    return $parsed.ToUniversalTime()
}

function Get-HumanVisualGoTimestampValues {
    param([AllowNull()][object]$Value)

    if ($null -eq $Value) { return }
    if ($Value -is [Collections.IDictionary]) {
        foreach ($name in @($Value.Keys)) {
            $child = $Value[$name]
            if ([string]$name -cmatch 'Utc$' -and $child -is [string] -and -not [string]::IsNullOrWhiteSpace([string]$child)) {
                Write-Output (ConvertFrom-HumanVisualGoEvidenceUtc -Value ([string]$child) -Name ([string]$name))
            }
            foreach ($nested in @(Get-HumanVisualGoTimestampValues -Value $child)) { Write-Output $nested }
        }
        return
    }
    if ($Value -is [pscustomobject]) {
        foreach ($property in @($Value.PSObject.Properties)) {
            $child = $property.Value
            if ([string]$property.Name -cmatch 'Utc$' -and $child -is [string] -and -not [string]::IsNullOrWhiteSpace([string]$child)) {
                Write-Output (ConvertFrom-HumanVisualGoEvidenceUtc -Value ([string]$child) -Name ([string]$property.Name))
            }
            foreach ($nested in @(Get-HumanVisualGoTimestampValues -Value $child)) { Write-Output $nested }
        }
        return
    }
    if ($Value -is [Collections.IEnumerable] -and $Value -isnot [string]) {
        foreach ($item in @($Value)) { foreach ($nested in @(Get-HumanVisualGoTimestampValues -Value $item)) { Write-Output $nested } }
    }
}

function Get-HumanVisualGoLatestEvidenceUtc {
    param(
        [Parameter(Mandatory = $true)]$Candidate,
        [Parameter(Mandatory = $true)][string]$EvidenceRoot,
        [Parameter(Mandatory = $true)][string]$RepositoryRoot
    )

    $evidenceFull = [IO.Path]::GetFullPath($EvidenceRoot).TrimEnd('\', '/')
    $repoFull = [IO.Path]::GetFullPath($RepositoryRoot).TrimEnd('\', '/')
    $timestamps = @(
        Get-HumanVisualGoTimestampValues -Value $Candidate
    )
    $context = New-HumanVisualGoHoldContext
    try {
        Open-HumanVisualGoRootHandle -Context $context -Root $evidenceFull -ContextName 'Freshness evidence root'
        Open-HumanVisualGoRootHandle -Context $context -Root $repoFull -ContextName 'Freshness repository root'
        foreach ($binding in @($Candidate.evidenceBindings)) {
            $root = if ([string]$binding.root -ceq 'EvidenceRoot') { $evidenceFull } elseif ([string]$binding.root -ceq 'RepositoryRoot') { $repoFull } else { throw "Freshness binding '$($binding.kind)' has an unknown root." }
            $held = Open-HumanVisualGoContainedHeldFile -Context $context -Root $root -RelativePath ([string]$binding.relativePath) -ContextName "Freshness binding '$($binding.kind)'" -RootKind ([string]$binding.root)
            if ([string]$binding.relativePath -match '(?i)\.json$') {
                $document = Read-HumanVisualGoHeldJson -Held $held -Description "Freshness binding '$($binding.kind)'" -RepositoryRoot $repoFull
                $timestamps += @(Get-HumanVisualGoTimestampValues -Value $document.Value)
            }
        }
        Assert-HumanVisualGoHeldUnchanged -Context $context -Description 'Freshness evidence'
    }
    finally {
        Close-HumanVisualGoHoldContext -Context $context
    }
    if (@($timestamps).Count -eq 0) { throw 'No trusted evidence timestamp was available for Human attestation chronology.' }
    return (@($timestamps) | Sort-Object)[-1]
}

function Assert-HumanVisualGoAttestationFreshness {
    param(
        [Parameter(Mandatory = $true)]$Candidate,
        [Parameter(Mandatory = $true)]$Attestation,
        [Parameter(Mandatory = $true)][string]$EvidenceRoot,
        [Parameter(Mandatory = $true)][string]$RepositoryRoot,
        [Parameter(Mandatory = $true)][DateTimeOffset]$TrustedNowUtc,
        [Parameter(Mandatory = $true)][TimeSpan]$MaximumAge,
        [Parameter(Mandatory = $true)][TimeSpan]$MaximumFutureSkew
    )

    if ($MaximumAge -le [TimeSpan]::Zero -or $MaximumFutureSkew -lt [TimeSpan]::Zero) {
        throw 'FRESHNESS_POLICY_NOT_CONFIGURED: maximum age and future-skew policy must be configured owner inputs.'
    }
    $reviewed = [DateTimeOffset]::ParseExact([string]$Attestation.reviewedUtc, "yyyy-MM-dd'T'HH:mm:ss.fffffff'Z'", [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::AssumeUniversal)
    $latestEvidence = Get-HumanVisualGoLatestEvidenceUtc -Candidate $Candidate -EvidenceRoot $EvidenceRoot -RepositoryRoot $RepositoryRoot
    if ($reviewed -le $latestEvidence) {
        throw "External Human attestation reviewedUtc must be later than the latest held evidence timestamp ($($latestEvidence.ToString('O', [Globalization.CultureInfo]::InvariantCulture)))."
    }
    if ($reviewed -lt $TrustedNowUtc.Subtract($MaximumAge)) {
        throw 'External Human attestation reviewedUtc exceeds the configured maximum accepted age.'
    }
    if ($reviewed -gt $TrustedNowUtc.Add($MaximumFutureSkew)) {
        throw 'External Human attestation reviewedUtc is ahead of the trusted verifier clock.'
    }
}

function Claim-HumanVisualGoReplayNonce {
    param(
        [Parameter(Mandatory = $true)][string]$RegistryRoot,
        [Parameter(Mandatory = $true)][string]$Nonce,
        [Parameter(Mandatory = $true)][string]$CandidateBindingSha256,
        [Parameter(Mandatory = $true)][string]$RepositoryRoot
    )

    Assert-HumanVisualGoSha256 $Nonce 'Human attestation replay nonce'
    Assert-HumanVisualGoSha256 $CandidateBindingSha256 'Human attestation replay candidate binding'
    $registryFull = [IO.Path]::GetFullPath($RegistryRoot).TrimEnd('\', '/')
    $noncePath = Join-Path $registryFull ($Nonce.ToUpperInvariant() + '.nonce')
    Assert-HumanVisualGoNoReparsePath -Root $registryFull -Path $registryFull -Context 'Human attestation replay registry'
    if (Test-Path -LiteralPath $noncePath) {
        throw 'External Human attestation replay nonce is already claimed; atomic CreateNew rejected a clobber.'
    }
    $record = [pscustomobject][ordered]@{
        nonce = $Nonce.ToUpperInvariant()
        candidateBindingSha256 = $CandidateBindingSha256
        claimedUtc = [DateTimeOffset]::UtcNow.ToString("yyyy-MM-dd'T'HH:mm:ss.fffffff'Z'", [Globalization.CultureInfo]::InvariantCulture)
    }
    $bytes = [Text.UTF8Encoding]::new($false, $true).GetBytes((Get-HumanVisualGoCanonicalText -Value $record -RepositoryRoot $RepositoryRoot) + "`n")
    $stream = $null
    try {
        try { $stream = New-Object IO.FileStream($noncePath, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None) }
        catch [IO.IOException] { throw 'External Human attestation replay nonce is already claimed; atomic CreateNew rejected a clobber.' }
        $final = [IO.Path]::GetFullPath([HumanVisualGo.NativeFile]::GetFinalPath($stream.SafeFileHandle))
        if (-not $final.Equals([IO.Path]::GetFullPath($noncePath), [StringComparison]::OrdinalIgnoreCase)) { throw 'Replay nonce final path changed or aliases another path.' }
        $stream.Write($bytes, 0, $bytes.Length)
        $stream.Flush($true)
    }
    finally {
        if ($null -ne $stream) { $stream.Dispose() }
    }
    return [pscustomobject][ordered]@{ Path = $noncePath; Nonce = $Nonce.ToUpperInvariant(); CandidateBindingSha256 = $CandidateBindingSha256 }
}

function Get-HumanVisualGoManifestRelativePath {
    param([Parameter(Mandatory = $true)][string]$ManifestPath, [Parameter(Mandatory = $true)][string]$EvidenceRoot)
    $full = [IO.Path]::GetFullPath($ManifestPath)
    $root = [IO.Path]::GetFullPath($EvidenceRoot).TrimEnd('\', '/')
    if (-not (Test-HumanVisualGoPathUnderRoot -Root $root -Path $full)) {
        throw 'Renderer manifest must be contained by the evidence root.'
    }
    return Get-HumanVisualGoRelativePath -Root $root -Path $full -Context 'Renderer manifest'
}

function Get-HumanVisualGoReviewEvidenceRelativePath {
    param([Parameter(Mandatory = $true)][string]$ReviewEvidencePath, [Parameter(Mandatory = $true)][string]$EvidenceRoot)
    $full = [IO.Path]::GetFullPath($ReviewEvidencePath)
    $root = [IO.Path]::GetFullPath($EvidenceRoot).TrimEnd('\', '/')
    if (-not (Test-HumanVisualGoPathUnderRoot -Root $root -Path $full)) {
        throw 'Human visual review evidence must be contained by the evidence root.'
    }
    return Get-HumanVisualGoRelativePath -Root $root -Path $full -Context 'Human visual review evidence'
}

function Assert-HumanVisualGoReviewEvidence {
    param(
        [Parameter(Mandatory = $true)]$ReviewEvidence,
        [Parameter(Mandatory = $true)]$Manifest,
        [Parameter(Mandatory = $true)]$RendererManifestBinding,
        [Parameter(Mandatory = $true)][string]$RepositoryRoot
    )

    Assert-HumanVisualGoExactProperties $ReviewEvidence @('$id', 'schemaVersion', 'evidenceClassification', 'issue', 'compatibilityIssue', 'candidate', 'comparisons', 'checks', 'defects', 'evidenceBoundary') 'Human visual review evidence'
    if ([string]$ReviewEvidence.'$id' -cne 'https://herdrops.local/schema/v0.2/human-visual-review-evidence.schema.json' -or
        [int]$ReviewEvidence.schemaVersion -ne 1 -or [string]$ReviewEvidence.evidenceClassification -cne 'HumanVisualReviewEvidence' -or
        [int]$ReviewEvidence.issue -ne 11 -or [int]$ReviewEvidence.compatibilityIssue -ne 149) {
        throw 'Human visual review evidence identity is invalid.'
    }
    Assert-HumanVisualGoExactProperties $ReviewEvidence.candidate @('sourceCommitSha', 'sourceTreeSha', 'rendererManifestSha256') 'Human visual review candidate binding'
    Assert-HumanVisualGoCommitSha $ReviewEvidence.candidate.sourceCommitSha 'Human visual review source commit'
    Assert-HumanVisualGoCommitSha $ReviewEvidence.candidate.sourceTreeSha 'Human visual review source tree'
    Assert-HumanVisualGoSha256 $ReviewEvidence.candidate.rendererManifestSha256 'Human visual review renderer manifest hash'
    if ([string]$ReviewEvidence.candidate.sourceCommitSha -cne [string]$Manifest.candidate.source.commitSha -or
        [string]$ReviewEvidence.candidate.sourceTreeSha -cne [string]$Manifest.candidate.source.treeSha -or
        [string]$ReviewEvidence.candidate.rendererManifestSha256 -cne [string]$RendererManifestBinding.sha256) {
        throw 'Human visual review evidence is bound to a mixed renderer candidate.'
    }

    $expectedComparisons = @($Manifest.comparison.results | ForEach-Object {
        [pscustomobject][ordered]@{
            key = "$($_.language)|$($_.captureName)"
            status = [string]$_.status
            referenceRelativePath = [string]$_.referenceRelativePath
            disposition = if ($null -eq $_.disposition) { $null } else { [string]$_.disposition }
        }
    })
    $actualComparisons = @($ReviewEvidence.comparisons)
    if ($actualComparisons.Count -ne 20) { throw 'Human visual review evidence must cover exactly 20 governed comparisons.' }
    for ($index = 0; $index -lt $expectedComparisons.Count; $index++) {
        foreach ($field in @('key', 'status', 'referenceRelativePath', 'disposition')) {
            if ([string]$actualComparisons[$index].$field -cne [string]$expectedComparisons[$index].$field) {
                throw "Human visual review comparison $index field '$field' does not equal the held renderer result."
            }
        }
    }

    $expectedCheckIds = @($script:RendererVisualChecks)
    $actualChecks = @($ReviewEvidence.checks)
    if ($actualChecks.Count -ne $expectedCheckIds.Count) { throw 'Human visual review evidence must cover all governed visual checks.' }
    for ($index = 0; $index -lt $expectedCheckIds.Count; $index++) {
        Assert-HumanVisualGoExactProperties $actualChecks[$index] @('id', 'status', 'notes') "Human visual review check $index"
        if ([string]$actualChecks[$index].id -cne [string]$expectedCheckIds[$index]) { throw "Human visual review check $index is not the governed check." }
        if ([string]::IsNullOrWhiteSpace([string]$actualChecks[$index].notes)) { throw "Human visual review check '$($actualChecks[$index].id)' has no notes." }
    }

    $expectedDefects = @($Manifest.review.defects | ForEach-Object {
        [pscustomobject][ordered]@{ id = [string]$_.id; severity = [string]$_.severity; summary = [string]$_.summary; status = [string]$_.status; disposition = [string]$_.disposition }
    })
    $actualDefects = @($ReviewEvidence.defects)
    if ((Get-HumanVisualGoCanonicalText -Value @($actualDefects) -RepositoryRoot $RepositoryRoot) -cne
        (Get-HumanVisualGoCanonicalText -Value @($expectedDefects) -RepositoryRoot $RepositoryRoot)) {
        throw 'Human visual review evidence omitted or changed a governed defect disposition.'
    }
    Assert-HumanVisualGoExactProperties $ReviewEvidence.evidenceBoundary @('humanReview', 'actualHerdrRuntime', 'release', 'creditGranted') 'Human visual review evidence boundary'
    if ($ReviewEvidence.evidenceBoundary.humanReview -cne 'NOT_OBSERVED' -or
        $ReviewEvidence.evidenceBoundary.actualHerdrRuntime -cne 'NOT_OBSERVED' -or
        $ReviewEvidence.evidenceBoundary.release -cne 'NOT_OBSERVED' -or
        $ReviewEvidence.evidenceBoundary.creditGranted -isnot [bool] -or [bool]$ReviewEvidence.evidenceBoundary.creditGranted) {
        throw 'Human visual review evidence cannot grant Human GO, Runtime, or Release credit.'
    }
    Assert-HumanVisualGoSchema -Value $ReviewEvidence -SchemaPath (Join-Path $PSScriptRoot 'human-visual-review-evidence.schema.json') -RepositoryRoot $RepositoryRoot -Description 'HumanVisualReviewEvidence'
}

function Add-HumanVisualGoReviewEvidence {
    param(
        [Parameter(Mandatory = $true)]$Context,
        [Parameter(Mandatory = $true)]$Manifest,
        [Parameter(Mandatory = $true)]$RendererManifestBinding,
        [Parameter(Mandatory = $true)][string]$ReviewEvidencePath,
        [Parameter(Mandatory = $true)][string]$EvidenceRoot,
        [Parameter(Mandatory = $true)][string]$RepositoryRoot
    )

    $relative = Get-HumanVisualGoReviewEvidenceRelativePath -ReviewEvidencePath $ReviewEvidencePath -EvidenceRoot $EvidenceRoot
    [void](Add-HumanVisualGoEvidenceBinding -Context $Context -Root $EvidenceRoot -RootKind EvidenceRoot -RelativePath $relative -Kind 'HumanReviewEvidence' -RepositoryRoot $RepositoryRoot -Json)
    $held = Get-HumanVisualGoHeldForBinding -Context $Context -Binding (Get-HumanVisualGoBinding $Context 'HumanReviewEvidence')
    $document = Read-HumanVisualGoHeldJson -Held $held -Description 'Human visual review evidence' -RepositoryRoot $RepositoryRoot
    Assert-HumanVisualGoCanonicalJsonFile -Document $document -Description 'Human visual review evidence'
    Assert-HumanVisualGoReviewEvidence -ReviewEvidence $document.Value -Manifest $Manifest -RendererManifestBinding $RendererManifestBinding -RepositoryRoot $RepositoryRoot
    return $document.Value
}

function Add-HumanVisualGoManifestEvidence {
    param(
        [Parameter(Mandatory = $true)]$Context,
        [Parameter(Mandatory = $true)]$Manifest,
        [Parameter(Mandatory = $true)][string]$EvidenceRoot,
        [Parameter(Mandatory = $true)][string]$RepositoryRoot,
        [Parameter(Mandatory = $true)][string]$ManifestRelativePath
    )

    $manifestBinding = Add-HumanVisualGoEvidenceBinding -Context $Context -Root $EvidenceRoot -RootKind EvidenceRoot -RelativePath $ManifestRelativePath -Kind 'RendererManifest' -RepositoryRoot $RepositoryRoot -Json
    $candidate = $Manifest.candidate
    [void](Add-HumanVisualGoEvidenceBinding -Context $Context -Root $RepositoryRoot -RootKind RepositoryRoot -RelativePath ([string]$candidate.profile.relativePath) -Kind 'PackageProfile' -RepositoryRoot $RepositoryRoot -Json -Expected $candidate.profile)
    [void](Add-HumanVisualGoEvidenceBinding -Context $Context -Root $EvidenceRoot -RootKind EvidenceRoot -RelativePath ([string]$candidate.receipt.relativePath) -Kind 'PackageReceipt' -RepositoryRoot $RepositoryRoot -Json -Expected $candidate.receipt)
    [void](Add-HumanVisualGoEvidenceBinding -Context $Context -Root $EvidenceRoot -RootKind EvidenceRoot -RelativePath ([string]$candidate.archive.relativePath) -Kind 'PackageArchive' -RepositoryRoot $RepositoryRoot -Expected $candidate.archive)
    $packageRoot = [string]$candidate.packageRootRelativePath
    [void](Add-HumanVisualGoEvidenceBinding -Context $Context -Root $EvidenceRoot -RootKind EvidenceRoot -RelativePath ((Join-Path $packageRoot 'package-manifest.json').Replace('\', '/')) -Kind 'PackageManifest' -RepositoryRoot $RepositoryRoot -Json)
    [void](Add-HumanVisualGoEvidenceBinding -Context $Context -Root $EvidenceRoot -RootKind EvidenceRoot -RelativePath ((Join-Path $packageRoot $candidate.components.app.relativePath).Replace('\', '/')) -Kind 'PackageApp' -RepositoryRoot $RepositoryRoot -Expected $candidate.components.app)
    [void](Add-HumanVisualGoEvidenceBinding -Context $Context -Root $EvidenceRoot -RootKind EvidenceRoot -RelativePath ((Join-Path $packageRoot $candidate.components.core.relativePath).Replace('\', '/')) -Kind 'PackageCore' -RepositoryRoot $RepositoryRoot -Expected $candidate.components.core)

    [void](Add-HumanVisualGoEvidenceBinding -Context $Context -Root $RepositoryRoot -RootKind RepositoryRoot -RelativePath 'Plan/reference-hosts/v0.2.json' -Kind 'ReferenceHostProfile' -RepositoryRoot $RepositoryRoot -Json)
    [void](Add-HumanVisualGoEvidenceBinding -Context $Context -Root $RepositoryRoot -RootKind RepositoryRoot -RelativePath 'Plan/reference-hosts/reference-host-profile.schema.json' -Kind 'ReferenceHostSchema' -RepositoryRoot $RepositoryRoot -Json)
    [void](Add-HumanVisualGoEvidenceBinding -Context $Context -Root $RepositoryRoot -RootKind RepositoryRoot -RelativePath 'tools/packaging/v0.2/package-identity-receipt.schema.json' -Kind 'PackageReceiptSchema' -RepositoryRoot $RepositoryRoot -Json)
    [void](Add-HumanVisualGoEvidenceBinding -Context $Context -Root $RepositoryRoot -RootKind RepositoryRoot -RelativePath 'docs/design/reference/MANIFEST.md' -Kind 'ReferenceManifest' -RepositoryRoot $RepositoryRoot)

    [void](Add-HumanVisualGoEvidenceBinding -Context $Context -Root $EvidenceRoot -RootKind EvidenceRoot -RelativePath ([string]$Manifest.rendererEvidence.producerReport.relativePath) -Kind 'RendererProducerReport' -RepositoryRoot $RepositoryRoot -Json -Expected $Manifest.rendererEvidence.producerReport)
    if ($null -ne $Manifest.comparison.maskSetReceipt) {
        [void](Add-HumanVisualGoEvidenceBinding -Context $Context -Root $EvidenceRoot -RootKind EvidenceRoot -RelativePath ([string]$Manifest.comparison.maskSetReceipt.relativePath) -Kind 'MaskSetReceipt' -RepositoryRoot $RepositoryRoot -Json -Expected $Manifest.comparison.maskSetReceipt)
    }

    $proofIndex = 0
    foreach ($observation in @($Manifest.rendererEvidence.throughoutObservations)) {
        [void](Add-HumanVisualGoEvidenceBinding -Context $Context -Root $EvidenceRoot -RootKind EvidenceRoot -RelativePath ([string]$observation.proofReceipt.relativePath) -Kind ("RendererProof:{0}" -f $proofIndex) -RepositoryRoot $RepositoryRoot -Json -Expected $observation.proofReceipt)
        $proofIndex++
    }
    $captureIndex = 0
    foreach ($capture in @($Manifest.captures)) {
        [void](Add-HumanVisualGoEvidenceBinding -Context $Context -Root $EvidenceRoot -RootKind EvidenceRoot -RelativePath ([string]$capture.relativePath) -Kind ("Capture:{0}" -f $captureIndex) -RepositoryRoot $RepositoryRoot -Expected $capture)
        $captureIndex++
    }
    $referenceIndex = 0
    foreach ($reference in @($Manifest.references)) {
        $referenceRelative = ([string]$reference.relativePath).Replace('\', '/')
        if (-not $referenceRelative.StartsWith('docs/design/reference/', [StringComparison]::Ordinal)) {
            throw "Reference $referenceIndex is not in the immutable reference directory."
        }
        [void](Add-HumanVisualGoEvidenceBinding -Context $Context -Root $RepositoryRoot -RootKind RepositoryRoot -RelativePath $referenceRelative -Kind ("Reference:{0}" -f $referenceIndex) -RepositoryRoot $RepositoryRoot -Expected $reference)
        $referenceIndex++
    }
    $maskIndex = 0
    foreach ($mask in @($Manifest.comparison.masks)) {
        [void](Add-HumanVisualGoEvidenceBinding -Context $Context -Root $EvidenceRoot -RootKind EvidenceRoot -RelativePath ([string]$mask.relativePath) -Kind ("Mask:{0}" -f $maskIndex) -RepositoryRoot $RepositoryRoot -Expected $mask)
        $maskIndex++
    }
    $matrixGroups = @('displayCases', 'mixedDpiTransitions', 'accessibilityCases', 'supportedEnvironmentCases')
    foreach ($group in $matrixGroups) {
        foreach ($case in @($Manifest.matrices.$group)) {
            if ($null -ne $case.evidenceReceipt) {
                [void](Add-HumanVisualGoEvidenceBinding -Context $Context -Root $EvidenceRoot -RootKind EvidenceRoot -RelativePath ([string]$case.evidenceReceipt.relativePath) -Kind ("Matrix:{0}" -f [string]$case.id) -RepositoryRoot $RepositoryRoot -Json -Expected $case.evidenceReceipt)
            }
        }
    }
    if ($null -ne $Manifest.performanceProtocol.evidenceReceipt) {
        [void](Add-HumanVisualGoEvidenceBinding -Context $Context -Root $EvidenceRoot -RootKind EvidenceRoot -RelativePath ([string]$Manifest.performanceProtocol.evidenceReceipt.relativePath) -Kind 'PerformanceReceipt' -RepositoryRoot $RepositoryRoot -Json -Expected $Manifest.performanceProtocol.evidenceReceipt)
        $performanceHeld = Get-HumanVisualGoHeldForBinding -Context $Context -Binding (Get-HumanVisualGoBinding $Context 'PerformanceReceipt')
        $performanceDocument = Read-HumanVisualGoHeldJson -Held $performanceHeld -Description 'Performance receipt' -RepositoryRoot $RepositoryRoot
        if ($null -eq $performanceDocument.Value.rawSource) { throw 'Performance receipt omitted rawSource.' }
        if ($null -eq $performanceDocument.Value.provenance -or $null -eq $performanceDocument.Value.provenance.performanceTelemetryBinding -or $null -eq $performanceDocument.Value.provenance.performanceTransactionCommit) { throw 'Performance receipt omitted the telemetry sidecar or transaction commit provenance.' }
        [void](Add-HumanVisualGoEvidenceBinding -Context $Context -Root $EvidenceRoot -RootKind EvidenceRoot -RelativePath ([string]$performanceDocument.Value.rawSource.relativePath) -Kind 'PerformanceRawSource' -RepositoryRoot $RepositoryRoot -Json -Expected $performanceDocument.Value.rawSource)
        [void](Add-HumanVisualGoEvidenceBinding -Context $Context -Root $EvidenceRoot -RootKind EvidenceRoot -RelativePath ([string]$performanceDocument.Value.provenance.performanceTelemetryBinding.relativePath) -Kind 'PerformanceTelemetryBinding' -RepositoryRoot $RepositoryRoot -Json -Expected $performanceDocument.Value.provenance.performanceTelemetryBinding)
        [void](Add-HumanVisualGoEvidenceBinding -Context $Context -Root $EvidenceRoot -RootKind EvidenceRoot -RelativePath ([string]$performanceDocument.Value.provenance.performanceTransactionCommit.relativePath) -Kind 'PerformanceTransactionCommit' -RepositoryRoot $RepositoryRoot -Json -Expected $performanceDocument.Value.provenance.performanceTransactionCommit)
    }
    return $manifestBinding
}

function Get-HumanVisualGoPackageManifestBinding {
    param([Parameter(Mandatory = $true)]$Context, [Parameter(Mandatory = $true)]$PackageReceipt, [Parameter(Mandatory = $true)][string]$PackageRoot)
    $manifestBinding = Get-HumanVisualGoBinding $Context 'PackageManifest'
    if ([long]$PackageReceipt.packageManifest.bytes -ne [long]$manifestBinding.bytes -or
        [string]$PackageReceipt.packageManifest.sha256 -cne [string]$manifestBinding.sha256) {
        throw 'Package manifest receipt does not equal the held package-manifest.json bytes.'
    }
    return $manifestBinding
}

function Get-HumanVisualGoCandidateCompleteness {
    param([Parameter(Mandatory = $true)]$Manifest, [Parameter(Mandatory = $true)]$ReviewEvidence)
    $reasons = @()
    $captures = @($Manifest.captures)
    if ($captures.Count -ne 20 -or @($captures | Where-Object { $_.language -ceq 'Thai' }).Count -ne 10 -or
        @($captures | Where-Object { $_.language -ceq 'English' }).Count -ne 10) {
        $reasons += 'exactly ten Thai and ten English captures are required'
    }
    foreach ($capture in $captures) {
        if ($capture.sha256 -notmatch '^[0-9A-F]{64}$') { $reasons += "capture '$($capture.name)' is not hash-bound" }
    }
    foreach ($result in @($Manifest.comparison.results)) {
        if ($result.status -ceq 'NOT_OBSERVED' -or [string]::IsNullOrWhiteSpace([string]$result.disposition)) {
            $reasons += "visual comparison '$($result.language)|$($result.captureName)' is incomplete"
        }
    }
    foreach ($group in @('displayCases', 'mixedDpiTransitions', 'accessibilityCases', 'supportedEnvironmentCases')) {
        foreach ($case in @($Manifest.matrices.$group)) {
            if ($case.status -ceq 'NOT_OBSERVED' -or $null -eq $case.evidenceReceipt) {
                $reasons += "matrix case '$($case.id)' is incomplete"
            }
        }
    }
    if ($Manifest.performanceProtocol.samplesStatus -ceq 'NOT_OBSERVED' -or $null -eq $Manifest.performanceProtocol.evidenceReceipt) {
        $reasons += 'performance and soak receipts are missing'
    }
    foreach ($check in @($ReviewEvidence.checks)) {
        if ($check.status -ceq 'NOT_OBSERVED' -or $null -eq $check.notes) {
            $reasons += "visual review check '$($check.id)' is incomplete"
        }
    }
    foreach ($defect in @($ReviewEvidence.defects)) {
        if ([string]::IsNullOrWhiteSpace([string]$defect.disposition)) {
            $reasons += "defect '$($defect.id)' has no disposition"
        }
        if ($defect.status -ceq 'Open' -or ($defect.severity -in @('P0', 'P1') -and $defect.status -ceq 'Accepted')) {
            $reasons += "defect '$($defect.id)' is not closed for GO"
        }
    }
    $allPass = $reasons.Count -eq 0
    foreach ($result in @($Manifest.comparison.results)) { if ($result.status -cne 'PASS') { $allPass = $false } }
    foreach ($group in @('displayCases', 'mixedDpiTransitions', 'accessibilityCases', 'supportedEnvironmentCases')) {
        foreach ($case in @($Manifest.matrices.$group)) { if ($case.status -cne 'PASS') { $allPass = $false } }
    }
    if ($Manifest.performanceProtocol.samplesStatus -cne 'PASS') { $allPass = $false }
    foreach ($check in @($ReviewEvidence.checks)) { if ($check.status -cne 'PASS') { $allPass = $false } }
    return [pscustomobject]@{
        Eligible = ($reasons.Count -eq 0 -and $allPass)
        Reasons = @($reasons)
    }
}

function Convert-HumanVisualGoBindingCollection {
    param([Parameter(Mandatory = $true)]$Context)
    return @($Context.Bindings | ForEach-Object {
        [pscustomobject][ordered]@{
            kind = [string]$_.kind
            root = [string]$_.root
            relativePath = [string]$_.relativePath
            bytes = [long]$_.bytes
            sha256 = [string]$_.sha256
            canonicalSha256 = if ($null -eq $_.canonicalSha256) { $null } else { [string]$_.canonicalSha256 }
        }
    })
}

function New-V02HumanVisualGoCandidateCore {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$RendererManifestPath,
        [Parameter(Mandatory = $true)][string]$HumanReviewEvidencePath,
        [Parameter(Mandatory = $true)][string]$EvidenceRoot,
        [Parameter(Mandatory = $true)][string]$RepositoryRoot,
        [Parameter(Mandatory = $true)][string]$BuilderIdentity,
        [Parameter(Mandatory = $true)][string]$RuntimeOperatorIdentity,
        [Parameter(Mandatory = $true)][string]$IndependentValidatorIdentity
    )

    foreach ($identity in @($BuilderIdentity, $RuntimeOperatorIdentity, $IndependentValidatorIdentity)) {
        Assert-HumanVisualGoString $identity 'Evidence role identity'
    }
    $roleIdentities = @($BuilderIdentity, $RuntimeOperatorIdentity, $IndependentValidatorIdentity)
    if (@($roleIdentities | Select-Object -Unique).Count -ne 3) {
        throw 'Builder, Runtime operator, and independent validator identities must be distinct.'
    }
    if (@($roleIdentities | Where-Object { $_ -ieq $script:HumanVisualGoAuthorizedReviewer }).Count -ne 0) {
        throw 'The authorized Human reviewer identity cannot be assigned to a builder or evidence role.'
    }
    $repoFull = [IO.Path]::GetFullPath($RepositoryRoot).TrimEnd('\', '/')
    $evidenceFull = [IO.Path]::GetFullPath($EvidenceRoot).TrimEnd('\', '/')
    $context = New-HumanVisualGoHoldContext
    try {
        Open-HumanVisualGoRootHandle -Context $context -Root $repoFull -ContextName 'Repository root'
        Open-HumanVisualGoRootHandle -Context $context -Root $evidenceFull -ContextName 'Evidence root'
        $manifestRelative = Get-HumanVisualGoManifestRelativePath -ManifestPath $RendererManifestPath -EvidenceRoot $evidenceFull
        $manifestFull = [IO.Path]::GetFullPath($RendererManifestPath)
        $manifestHeld = Open-HumanVisualGoContainedHeldFile -Context $context -Root $evidenceFull -RelativePath $manifestRelative -ContextName 'Renderer manifest' -RootKind EvidenceRoot
        $manifestDocument = Read-HumanVisualGoHeldJson -Held $manifestHeld -Description 'Renderer compatibility manifest' -RepositoryRoot $repoFull
        $manifest = $manifestDocument.Value
        if ([int]$manifest.manifestVersion -eq 4) {
            throw 'D-026 makes HumanVisual tooling historical and optional; manifest v4 cannot receive Human review credit or use this path for v0.2 release readiness.'
        }
        $script:HumanVisualGoCurrentEvidenceRoot = $evidenceFull
        $script:HumanVisualGoCurrentRepositoryRoot = $repoFull

        $rendererManifestBinding = Add-HumanVisualGoManifestEvidence -Context $context -Manifest $manifest -EvidenceRoot $evidenceFull -RepositoryRoot $repoFull -ManifestRelativePath $manifestRelative
        $reviewEvidence = Add-HumanVisualGoReviewEvidence -Context $context -Manifest $manifest -RendererManifestBinding $rendererManifestBinding -ReviewEvidencePath $HumanReviewEvidencePath -EvidenceRoot $evidenceFull -RepositoryRoot $repoFull
        # Keep every original evidence/repository handle open for the entire
        # renderer-verifier window. The renderer verifier opens its own reads
        # with FileShare.Read, which is compatible with these held read handles;
        # directory handles deny rename/delete and file handles deny writes.
        # The same held identities, link counts, lengths, and bytes are checked
        # immediately after rendering and again after candidate schema validation.
        $rendererResult = Test-RendererCompatibilityManifest -ManifestPath $manifestFull -EvidenceRoot $evidenceFull -RepositoryRoot $repoFull -ValidateBindings
        Assert-HumanVisualGoHeldUnchanged -Context $context -Description 'Renderer validation held evidence'
        Assert-HumanVisualGoHeldUnchanged -Context $context -Description 'Renderer validation post-window evidence'
        if ($rendererResult.EvidenceClassification -cne 'PackagedCompatibilityCandidate' -or
            $rendererResult.BindingValidation -cne 'PASS' -or
            $rendererResult.ActualHerdrRuntime -cne 'NOT_OBSERVED' -or
            $rendererResult.Release -cne 'NOT_OBSERVED' -or [bool]$rendererResult.CreditGranted) {
            throw 'Renderer compatibility verifier did not return a bound candidate-only result.'
        }
        if ($manifest.review.decision -cne 'NOT_OBSERVED' -or $manifest.evidenceBoundary.humanReview -cne 'NOT_OBSERVED') {
            throw 'Builder-authored renderer review authority is forbidden; the manifest must remain NOT_OBSERVED.'
        }
        $git = Get-RendererGitIdentity $repoFull
        if ($git.CommitSha -cne [string]$manifest.candidate.source.commitSha -or $git.TreeSha -cne [string]$manifest.candidate.source.treeSha) {
            throw 'Renderer manifest source identity is not the exact clean repository candidate.'
        }
        $profileHeld = Get-HumanVisualGoHeldForBinding -Context $context -Binding (Get-HumanVisualGoBinding $context 'ReferenceHostProfile')
        $profileDocument = Read-HumanVisualGoHeldJson -Held $profileHeld -Description 'Reference-host profile' -RepositoryRoot $repoFull
        if ([string]$profileDocument.Value.profileId -cne $script:HumanVisualGoExpectedRendererProfileId) {
            throw 'Reference-host profile ID is not the governed v0.2 profile.'
        }
        if ($profileDocument.CanonicalSha256 -cne $script:HumanVisualGoExpectedRendererProfileSha256) {
            throw 'Reference-host profile canonical SHA-256 is not the governed v0.2 profile hash.'
        }
        $packageReceiptHeld = Get-HumanVisualGoHeldForBinding -Context $context -Binding (Get-HumanVisualGoBinding $context 'PackageReceipt')
        $packageReceiptDocument = Read-HumanVisualGoHeldJson -Held $packageReceiptHeld -Description 'Package identity receipt' -RepositoryRoot $repoFull
        $packageManifestBinding = Get-HumanVisualGoPackageManifestBinding -Context $context -PackageReceipt $packageReceiptDocument.Value -PackageRoot ([string]$manifest.candidate.packageRootRelativePath)
        $packageProfileHeld = Get-HumanVisualGoHeldForBinding -Context $context -Binding (Get-HumanVisualGoBinding $context 'PackageProfile')
        $packageProfileDocument = Read-HumanVisualGoHeldJson -Held $packageProfileHeld -Description 'Package identity profile' -RepositoryRoot $repoFull
        $herdr = $profileDocument.Value.environmentBinding.herdr
        Assert-HumanVisualGoExactProperties $herdr @('version', 'releaseId', 'installPathRelativeToLocalAppData', 'executableSha256') 'Governed Herdr identity'
        Assert-HumanVisualGoSha256 $herdr.executableSha256 'Governed Herdr executable SHA-256'
        $session = $manifest.environment.session
        Assert-HumanVisualGoExactProperties $session @('kind', 'name', 'sessionId', 'transport', 'powerSource', 'thermalState', 'elevated', 'userScope') 'Renderer session binding'

        $completeness = Get-HumanVisualGoCandidateCompleteness -Manifest $manifest -ReviewEvidence $reviewEvidence
        $evidenceBindings = Convert-HumanVisualGoBindingCollection -Context $context
        $evidenceSetSha = Get-HumanVisualGoCanonicalSha256 -Value @($evidenceBindings) -RepositoryRoot $repoFull
        $package = [ordered]@{
            profile = Get-HumanVisualGoBinding $context 'PackageProfile'
            receipt = Get-HumanVisualGoBinding $context 'PackageReceipt'
            archive = Get-HumanVisualGoBinding $context 'PackageArchive'
            packageManifest = $packageManifestBinding
            app = Get-HumanVisualGoBinding $context 'PackageApp'
            core = Get-HumanVisualGoBinding $context 'PackageCore'
        }
        $captures = @($manifest.captures | ForEach-Object {
            [pscustomobject][ordered]@{ language = [string]$_.language; name = [string]$_.name; relativePath = [string]$_.relativePath; bytes = [long]$_.bytes; sha256 = [string]$_.sha256; widthPixels = [int]$_.widthPixels; heightPixels = [int]$_.heightPixels; observedUtc = [string]$_.observedUtc }
        })
        $references = @($manifest.references | ForEach-Object {
            [pscustomobject][ordered]@{ relativePath = [string]$_.relativePath; bytes = [long]$_.bytes; sha256 = [string]$_.sha256; widthPixels = [int]$_.widthPixels; heightPixels = [int]$_.heightPixels }
        })
        $masks = @($manifest.comparison.masks | ForEach-Object {
            [pscustomobject][ordered]@{ id = [string]$_.id; relativePath = [string]$_.relativePath; sha256 = [string]$_.sha256; maximumRadiusPixels = [int]$_.maximumRadiusPixels; captureKeys = @($_.captureKeys) }
        })
        $matrix = [ordered]@{}
        foreach ($group in @('displayCases', 'mixedDpiTransitions', 'accessibilityCases', 'supportedEnvironmentCases')) {
            $matrix[$group] = @($manifest.matrices.$group | ForEach-Object {
                $receipt = $null
                if ($null -ne $_.evidenceReceipt) { $receipt = Get-HumanVisualGoBinding $context ("Matrix:{0}" -f [string]$_.id) }
                [pscustomobject][ordered]@{ id = [string]$_.id; status = [string]$_.status; receipt = $receipt; notes = if ($null -eq $_.notes) { $null } else { [string]$_.notes } }
            })
        }
        $performanceReceipt = $null
        $performanceRaw = $null
        $performanceTelemetry = $null
        $performanceCommit = $null
        if ($null -ne $manifest.performanceProtocol.evidenceReceipt) {
            $performanceReceipt = Get-HumanVisualGoBinding $context 'PerformanceReceipt'
            $performanceRaw = Get-HumanVisualGoBinding $context 'PerformanceRawSource'
            $performanceTelemetry = Get-HumanVisualGoBinding $context 'PerformanceTelemetryBinding'
            $performanceCommit = Get-HumanVisualGoBinding $context 'PerformanceTransactionCommit'
        }
        $visualComparisons = @($manifest.comparison.results | ForEach-Object {
            [pscustomobject][ordered]@{ key = "$($_.language)|$($_.captureName)"; status = [string]$_.status; referenceRelativePath = [string]$_.referenceRelativePath; disposition = if ($null -eq $_.disposition) { $null } else { [string]$_.disposition } }
        })
        $visualChecks = @($reviewEvidence.checks | ForEach-Object {
            [pscustomobject][ordered]@{ id = [string]$_.id; status = [string]$_.status; notes = if ($null -eq $_.notes) { $null } else { [string]$_.notes } }
        })
        $herdrBindingSha = Get-HumanVisualGoCanonicalSha256 -Value $herdr -RepositoryRoot $repoFull
        $sessionBindingSha = Get-HumanVisualGoCanonicalSha256 -Value $session -RepositoryRoot $repoFull
        $candidate = [pscustomobject][ordered]@{
            '$id' = $script:HumanVisualGoSchemaId
            schemaVersion = 1
            evidenceClassification = 'HumanReviewCandidate'
            issue = 11
            compatibilityIssue = 149
            roles = [pscustomobject][ordered]@{ builderIdentity = $BuilderIdentity; runtimeOperatorIdentity = $RuntimeOperatorIdentity; independentValidatorIdentity = $IndependentValidatorIdentity }
            rendererManifest = Get-HumanVisualGoBinding $context 'RendererManifest'
            humanReviewEvidence = Get-HumanVisualGoBinding $context 'HumanReviewEvidence'
            source = [pscustomobject][ordered]@{ commitSha = [string]$manifest.candidate.source.commitSha; treeSha = [string]$manifest.candidate.source.treeSha }
            package = [pscustomobject]$package
            herdr = [pscustomobject][ordered]@{ profileId = [string]$profileDocument.Value.profileId; version = [string]$herdr.version; releaseId = [string]$herdr.releaseId; installPathRelativeToLocalAppData = [string]$herdr.installPathRelativeToLocalAppData; executableSha256 = [string]$herdr.executableSha256; bindingSha256 = $herdrBindingSha }
            session = [pscustomobject][ordered]@{ kind = [string]$session.kind; name = [string]$session.name; sessionId = [long]$session.sessionId; transport = [string]$session.transport; powerSource = [string]$session.powerSource; thermalState = [string]$session.thermalState; elevated = [bool]$session.elevated; userScope = [string]$session.userScope; bindingSha256 = $sessionBindingSha }
            renderer = [pscustomobject][ordered]@{ policy = [string]$manifest.candidate.renderer.policy; wpfProcessRenderMode = [string]$manifest.candidate.renderer.wpfProcessRenderMode; policySha256 = $script:HumanVisualGoExpectedRendererPolicySha256 }
            captures = $captures
            references = $references
            masks = $masks
            matrix = [pscustomobject]$matrix
            performance = [pscustomobject][ordered]@{ samplesStatus = [string]$manifest.performanceProtocol.samplesStatus; receipt = $performanceReceipt; rawSource = $performanceRaw; telemetryBinding = $performanceTelemetry; transactionCommit = $performanceCommit; warmupIterations = [int]$manifest.performanceProtocol.warmupIterations; repetitionsPerOrder = [int]$manifest.performanceProtocol.repetitionsPerOrder; soakBins = 24 }
            visualReview = [pscustomobject][ordered]@{ comparisons = $visualComparisons; checks = $visualChecks }
            defects = @($reviewEvidence.defects | ForEach-Object { [pscustomobject][ordered]@{ id = [string]$_.id; severity = [string]$_.severity; summary = [string]$_.summary; status = [string]$_.status; disposition = [string]$_.disposition } })
            evidenceBindings = @($evidenceBindings)
            evidenceSetSha256 = $evidenceSetSha
            eligibility = if ($completeness.Eligible) { 'ELIGIBLE_FOR_EXTERNAL_HUMAN_GO' } else { 'NOT_ELIGIBLE_FOR_HUMAN_GO' }
            ineligibilityReasons = @($completeness.Reasons)
            evidenceBoundary = [pscustomobject][ordered]@{ humanReview = 'NOT_OBSERVED'; actualHerdrRuntime = 'NOT_OBSERVED'; release = 'NOT_OBSERVED'; creditGranted = $false }
        }
        if ($candidate.renderer.policy -cne 'software-only-process-wide' -or $candidate.renderer.wpfProcessRenderMode -cne 'SoftwareOnly') {
            throw 'Human candidate renderer binding is not the governed SoftwareOnly policy.'
        }
        Assert-HumanVisualGoSchema -Value $candidate -SchemaPath (Join-Path $PSScriptRoot 'human-review-candidate.schema.json') -RepositoryRoot $repoFull -Description 'HumanReviewCandidate'
        Assert-HumanVisualGoHeldUnchanged -Context $context -Description 'Final Human candidate same-handle evidence'
        return $candidate
    }
    finally {
        Close-HumanVisualGoHoldContext -Context $context
    }
}

function Write-V02HumanVisualGoCandidate {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Candidate,
        [Parameter(Mandatory = $true)][string]$OutputPath,
        [Parameter(Mandatory = $true)][string]$RepositoryRoot,
        [Parameter(Mandatory = $true)][string]$EvidenceRoot
    )

    $full = Assert-HumanVisualGoExternalPath -Path $OutputPath -RepositoryRoot $RepositoryRoot -EvidenceRoot $EvidenceRoot -Context 'HumanReviewCandidate output'
    $canonical = Get-HumanVisualGoCanonicalText -Value $Candidate -RepositoryRoot $RepositoryRoot
    $bytes = [Text.UTF8Encoding]::new($false).GetBytes($canonical + "`n")
    $stream = $null
    try {
        # CreateNew is the no-clobber/concurrent-output guard. FileShare.None
        # keeps the completed candidate path stable for the verifier.
        $stream = New-Object IO.FileStream($full, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
        $final = [IO.Path]::GetFullPath([HumanVisualGo.NativeFile]::GetFinalPath($stream.SafeFileHandle))
        if (-not $final.Equals($full, [StringComparison]::OrdinalIgnoreCase)) { throw 'Candidate output final path changed or aliases another path.' }
        $stream.Write($bytes, 0, $bytes.Length)
        $stream.Flush($true)
    }
    finally {
        if ($null -ne $stream) { $stream.Dispose() }
    }
    return [pscustomobject]@{ Path = $full; Bytes = [long]$bytes.Length; FileSha256 = (Get-HumanVisualGoSha256ForBytes -Bytes $bytes); CanonicalSha256 = (Get-HumanVisualGoSha256ForBytes -Bytes ([Text.UTF8Encoding]::new($false).GetBytes($canonical))) }
}

function Assert-HumanVisualGoCandidateShape {
    param([Parameter(Mandatory = $true)]$Candidate)
    Assert-HumanVisualGoExactProperties $Candidate @('$id', 'schemaVersion', 'evidenceClassification', 'issue', 'compatibilityIssue', 'roles', 'rendererManifest', 'humanReviewEvidence', 'source', 'package', 'herdr', 'session', 'renderer', 'captures', 'references', 'masks', 'matrix', 'performance', 'visualReview', 'defects', 'evidenceBindings', 'evidenceSetSha256', 'eligibility', 'ineligibilityReasons', 'evidenceBoundary') 'HumanReviewCandidate'
    if ([string]$Candidate.'$id' -cne $script:HumanVisualGoSchemaId -or [int]$Candidate.schemaVersion -ne 1 -or [string]$Candidate.evidenceClassification -cne 'HumanReviewCandidate' -or [int]$Candidate.issue -ne 11 -or [int]$Candidate.compatibilityIssue -ne 149) { throw 'Historical HumanReviewCandidate identity is invalid.' }
    Assert-HumanVisualGoExactProperties $Candidate.evidenceBoundary @('humanReview', 'actualHerdrRuntime', 'release', 'creditGranted') 'HumanReviewCandidate evidenceBoundary'
    if ($Candidate.evidenceBoundary.humanReview -cne 'NOT_OBSERVED' -or $Candidate.evidenceBoundary.actualHerdrRuntime -cne 'NOT_OBSERVED' -or $Candidate.evidenceBoundary.release -cne 'NOT_OBSERVED' -or $Candidate.evidenceBoundary.creditGranted -isnot [bool] -or [bool]$Candidate.evidenceBoundary.creditGranted) { throw 'HumanReviewCandidate evidence boundary is inflated.' }
}

function Assert-HumanVisualGoAttestationShape {
    param([Parameter(Mandatory = $true)]$Attestation)
    Assert-HumanVisualGoExactProperties $Attestation @('$id', 'schemaVersion', 'evidenceClassification', 'issue', 'compatibilityIssue', 'attestationId', 'decision', 'decisionRationale', 'reviewedUtc', 'replayNonce', 'candidate', 'reviewer', 'authority', 'visualDispositions', 'visualChecks', 'defects', 'evidenceBindings', 'evidenceSetSha256', 'evidenceBoundary') 'External Human attestation'
    if ([string]$Attestation.'$id' -cne $script:HumanVisualGoAttestationSchemaId -or [int]$Attestation.schemaVersion -ne 1 -or [string]$Attestation.evidenceClassification -cne 'ExternalHumanVisualGoAttestation' -or [int]$Attestation.issue -ne 11 -or [int]$Attestation.compatibilityIssue -ne 149) { throw 'External Human attestation identity is invalid.' }
    if ([string]$Attestation.decision -cnotin @('GO', 'NO_GO')) { throw 'External Human attestation decision must be explicit GO or NO_GO.' }
    Assert-HumanVisualGoString $Attestation.attestationId 'Attestation ID'
    Assert-HumanVisualGoString $Attestation.decisionRationale 'Attestation rationale'
    Assert-HumanVisualGoUtc $Attestation.reviewedUtc 'Attestation reviewedUtc'
    Assert-HumanVisualGoSha256 $Attestation.replayNonce 'Attestation replay nonce'
    Assert-HumanVisualGoSha256 $Attestation.evidenceSetSha256 'Attestation evidenceSetSha256'
    Assert-HumanVisualGoExactProperties $Attestation.evidenceBoundary @('humanReview', 'actualHerdrRuntime', 'release', 'creditGranted') 'External attestation evidenceBoundary'
    if ($Attestation.evidenceBoundary.humanReview -cne [string]$Attestation.decision -or $Attestation.evidenceBoundary.actualHerdrRuntime -cne 'NOT_OBSERVED' -or $Attestation.evidenceBoundary.release -cne 'NOT_OBSERVED' -or $Attestation.evidenceBoundary.creditGranted -isnot [bool] -or [bool]$Attestation.evidenceBoundary.creditGranted) { throw 'External attestation boundary grants Runtime or Release credit.' }
}

function Assert-HumanVisualGoAttestationAgainstCandidate {
    param(
        [Parameter(Mandatory = $true)]$Candidate,
        [Parameter(Mandatory = $true)]$Attestation,
        [Parameter(Mandatory = $true)][string]$CandidateFileSha256,
        [Parameter(Mandatory = $true)][string]$CandidateCanonicalSha256,
        [Parameter(Mandatory = $true)][string]$RepositoryRoot,
        [Parameter(Mandatory = $true)][string]$TrustedAuthorityPublicKeyXml,
        [Parameter(Mandatory = $true)][string]$TrustedAuthorityPublicKeySha256,
        [Parameter(Mandatory = $true)][string]$ExpectedSignatureAlgorithm
    )

    Assert-HumanVisualGoAttestationShape -Attestation $Attestation
    Assert-HumanVisualGoGoCandidateRoleBinding -Candidate $Candidate -Reviewer $Attestation.reviewer
    Assert-HumanVisualGoExactProperties $Attestation.candidate @('sourceCommitSha', 'sourceTreeSha', 'candidateFileSha256', 'candidateCanonicalSha256', 'rendererManifestSha256', 'packageArchiveSha256', 'packageAppSha256', 'packageCoreSha256', 'herdrExecutableSha256', 'herdrBindingSha256', 'sessionBindingSha256', 'evidenceSetSha256') 'Attestation candidate binding'
    if ([string]$Attestation.candidate.sourceCommitSha -cne [string]$Candidate.source.commitSha -or [string]$Attestation.candidate.sourceTreeSha -cne [string]$Candidate.source.treeSha -or
        [string]$Attestation.candidate.candidateFileSha256 -cne $CandidateFileSha256 -or [string]$Attestation.candidate.candidateCanonicalSha256 -cne $CandidateCanonicalSha256 -or
        [string]$Attestation.candidate.rendererManifestSha256 -cne [string]$Candidate.rendererManifest.sha256 -or [string]$Attestation.candidate.packageArchiveSha256 -cne [string]$Candidate.package.archive.sha256 -or
        [string]$Attestation.candidate.packageAppSha256 -cne [string]$Candidate.package.app.sha256 -or [string]$Attestation.candidate.packageCoreSha256 -cne [string]$Candidate.package.core.sha256 -or
        [string]$Attestation.candidate.herdrExecutableSha256 -cne [string]$Candidate.herdr.executableSha256 -or [string]$Attestation.candidate.herdrBindingSha256 -cne [string]$Candidate.herdr.bindingSha256 -or
        [string]$Attestation.candidate.sessionBindingSha256 -cne [string]$Candidate.session.bindingSha256 -or [string]$Attestation.candidate.evidenceSetSha256 -cne [string]$Candidate.evidenceSetSha256) {
        throw 'External Human attestation is bound to a mixed or stale candidate.'
    }
    Assert-HumanVisualGoCommitSha $Attestation.candidate.sourceCommitSha 'Attestation source commit binding'
    Assert-HumanVisualGoCommitSha $Attestation.candidate.sourceTreeSha 'Attestation source tree binding'
    $candidateEvidenceCanonical = Get-HumanVisualGoCanonicalText -Value @($Candidate.evidenceBindings) -RepositoryRoot $RepositoryRoot
    $attestationEvidenceCanonical = Get-HumanVisualGoCanonicalText -Value @($Attestation.evidenceBindings) -RepositoryRoot $RepositoryRoot
    if ($candidateEvidenceCanonical -cne $attestationEvidenceCanonical) { throw 'External Human attestation omitted, reordered, aliased, or mixed evidence bindings.' }
    if ((Get-HumanVisualGoCanonicalSha256 -Value @($Attestation.evidenceBindings) -RepositoryRoot $RepositoryRoot) -cne [string]$Candidate.evidenceSetSha256 -or [string]$Attestation.evidenceSetSha256 -cne [string]$Candidate.evidenceSetSha256) { throw 'External Human attestation evidenceSetSha256 does not cover every evidence hash.' }
    $candidateVisualCanonical = Get-HumanVisualGoCanonicalText -Value @($Candidate.visualReview.comparisons) -RepositoryRoot $RepositoryRoot
    $attestationVisualCanonical = Get-HumanVisualGoCanonicalText -Value @($Attestation.visualDispositions) -RepositoryRoot $RepositoryRoot
    if ($candidateVisualCanonical -cne $attestationVisualCanonical) { throw 'External Human attestation visual dispositions do not cover every governed comparison.' }
    if ((Get-HumanVisualGoCanonicalText -Value @($Candidate.visualReview.checks) -RepositoryRoot $RepositoryRoot) -cne (Get-HumanVisualGoCanonicalText -Value @($Attestation.visualChecks) -RepositoryRoot $RepositoryRoot)) { throw 'External Human attestation omitted or changed a governed visual check.' }
    if ((Get-HumanVisualGoCanonicalText -Value @($Candidate.defects) -RepositoryRoot $RepositoryRoot) -cne (Get-HumanVisualGoCanonicalText -Value @($Attestation.defects) -RepositoryRoot $RepositoryRoot)) { throw 'External Human attestation omitted or changed a defect disposition.' }
    Assert-HumanVisualGoAttestationAuthority -Attestation $Attestation -TrustedAuthorityPublicKeyXml $TrustedAuthorityPublicKeyXml -TrustedAuthorityPublicKeySha256 $TrustedAuthorityPublicKeySha256 -ExpectedSignatureAlgorithm $ExpectedSignatureAlgorithm -RepositoryRoot $RepositoryRoot
    $decision = [string]$Attestation.decision
    if ($decision -ceq 'GO' -and ([string]$Candidate.eligibility -cne 'ELIGIBLE_FOR_EXTERNAL_HUMAN_GO' -or @($Candidate.visualReview.comparisons | Where-Object { $_.status -cne 'PASS' }).Count -ne 0 -or @($Candidate.visualReview.checks | Where-Object { $_.status -cne 'PASS' }).Count -ne 0 -or @($Candidate.defects | Where-Object { $_.status -ceq 'Open' -or ($_.severity -in @('P0', 'P1') -and $_.status -ceq 'Accepted') }).Count -ne 0)) {
        throw 'Human GO is not allowed for an incomplete, failed, or open-defect candidate.'
    }
}

function Assert-HumanVisualGoGoCandidateRoleBinding {
    param([Parameter(Mandatory = $true)]$Candidate, [Parameter(Mandatory = $true)]$Reviewer)
    Assert-HumanVisualGoExactProperties $Reviewer @('identity', 'role', 'authorityRole', 'builderIdentity', 'runtimeOperatorIdentity', 'independentValidatorIdentity', 'identityDistinct') 'Human reviewer'
    if ([string]$Reviewer.identity -cne $script:HumanVisualGoAuthorizedReviewer -or [string]$Reviewer.role -cne $script:HumanVisualGoAuthorizedReviewerRole -or [string]$Reviewer.authorityRole -cne $script:HumanVisualGoAuthorizedAuthorityRole) { throw 'Human attestation reviewer is not the authorized @yutthaphon ProductOwner/HumanReviewer.' }
    Assert-HumanVisualGoBoolean $Reviewer.identityDistinct 'Human reviewer identityDistinct'
    if (-not [bool]$Reviewer.identityDistinct) { throw 'Human reviewer identityDistinct must be true.' }
    $reviewerIdentity = [string]$Reviewer.identity
    foreach ($field in @('builderIdentity', 'runtimeOperatorIdentity', 'independentValidatorIdentity')) {
        Assert-HumanVisualGoString $Reviewer.$field "Human reviewer $field"
        if ([string]$Reviewer.$field -ieq $reviewerIdentity) { throw "Human reviewer identity must be distinct from $field." }
    }
    if ([string]$Reviewer.builderIdentity -cne [string]$Candidate.roles.builderIdentity -or [string]$Reviewer.runtimeOperatorIdentity -cne [string]$Candidate.roles.runtimeOperatorIdentity -or [string]$Reviewer.independentValidatorIdentity -cne [string]$Candidate.roles.independentValidatorIdentity) { throw 'External Human attestation role bindings do not equal the candidate roles.' }
    $roleIdentities = @([string]$Reviewer.builderIdentity, [string]$Reviewer.runtimeOperatorIdentity, [string]$Reviewer.independentValidatorIdentity)
    if (@($roleIdentities | Select-Object -Unique).Count -ne 3) { throw 'Builder, Runtime operator, and independent validator identities must be distinct.' }
}

function Test-V02HumanVisualGoAttestationCore {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$CandidatePath,
        [string]$AttestationPath,
        [Parameter(Mandatory = $true)][string]$EvidenceRoot,
        [Parameter(Mandatory = $true)][string]$RepositoryRoot
    )

    $candidateFull = Assert-HumanVisualGoExternalPath -Path $CandidatePath -RepositoryRoot $RepositoryRoot -EvidenceRoot $EvidenceRoot -Context 'HumanReviewCandidate input'
    $attestationFull = $null
    if (-not [string]::IsNullOrWhiteSpace($AttestationPath)) {
        $attestationFull = Assert-HumanVisualGoExternalPath -Path $AttestationPath -RepositoryRoot $RepositoryRoot -EvidenceRoot $EvidenceRoot -Context 'Human attestation input'
        if ($candidateFull.Equals($attestationFull, [StringComparison]::OrdinalIgnoreCase)) { throw 'Candidate and external attestation must be distinct files.' }
        $null = Get-HumanVisualGoFixedReplayLedgerRoot
        throw 'TRUST_ROOT_NOT_CONFIGURED; FRESHNESS_POLICY_NOT_CONFIGURED: Plan does not define an approved Human cryptographic trust root, authority fingerprint/allowlist, freshness age, or replay-ledger residual-risk policy.'
    }
    $context = New-HumanVisualGoHoldContext
    try {
        $externalRoot = Split-Path -Parent $candidateFull
        Open-HumanVisualGoRootHandle -Context $context -Root ([IO.Path]::GetFullPath($EvidenceRoot).TrimEnd('\', '/')) -ContextName 'Evidence root'
        Open-HumanVisualGoRootHandle -Context $context -Root ([IO.Path]::GetFullPath($RepositoryRoot).TrimEnd('\', '/')) -ContextName 'Repository root'
        $candidateHeld = Open-HumanVisualGoAbsoluteHeldFile -Context $context -Path $candidateFull -ContextName 'HumanReviewCandidate input' -Root ([IO.Path]::GetPathRoot($candidateFull)) -RootKind External
        $candidateDocument = Read-HumanVisualGoCanonicalJsonDocument -Held $candidateHeld -Description 'HumanReviewCandidate input' -RepositoryRoot ([IO.Path]::GetFullPath($RepositoryRoot))
        Assert-HumanVisualGoCanonicalJsonFile -Document $candidateDocument -Description 'HumanReviewCandidate input'
        Assert-HumanVisualGoCandidateShape -Candidate $candidateDocument.Value
        $candidate = $candidateDocument.Value
        if ([string]$candidate.humanReviewEvidence.root -cne 'EvidenceRoot') { throw 'HumanReviewCandidate review evidence must be held under EvidenceRoot.' }
        $reviewEvidencePath = Join-Path $EvidenceRoot ([string]$candidate.humanReviewEvidence.relativePath)
        $expectedCandidate = New-V02HumanVisualGoCandidateCore -RendererManifestPath (Join-Path $EvidenceRoot $candidate.rendererManifest.relativePath) -HumanReviewEvidencePath $reviewEvidencePath -EvidenceRoot $EvidenceRoot -RepositoryRoot $RepositoryRoot -BuilderIdentity ([string]$candidate.roles.builderIdentity) -RuntimeOperatorIdentity ([string]$candidate.roles.runtimeOperatorIdentity) -IndependentValidatorIdentity ([string]$candidate.roles.independentValidatorIdentity)
        $expectedCanonical = Get-HumanVisualGoCanonicalText -Value $expectedCandidate -RepositoryRoot ([IO.Path]::GetFullPath($RepositoryRoot))
        if ([string]$candidateDocument.Canonical -cne $expectedCanonical) { throw 'HumanReviewCandidate was copied, stale, forged, or mixed with a different renderer candidate.' }
        return [pscustomobject][ordered]@{
            EvidenceClass = 'Synthetic'
            EvidenceClassification = 'HumanReviewCandidate'
            CandidateStatus = 'HumanReviewCandidate'
            CandidateCanonicalSha256 = [string]$candidateDocument.CanonicalSha256
            BindingValidation = 'PASS'
            ExternalAttestation = 'NOT_OBSERVED'
            ReplayNonceClaimed = 'NOT_OBSERVED'
            HumanReview = 'NOT_OBSERVED'
            ActualHerdrRuntime = 'NOT_OBSERVED'
            Release = 'NOT_OBSERVED'
            CreditGranted = $false
            ReleaseReady = $false
        }
    }
    finally {
        Close-HumanVisualGoHoldContext -Context $context
    }
}
