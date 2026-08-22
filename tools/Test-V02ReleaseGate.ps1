#requires -Version 5.1

[CmdletBinding()]
param(
    [string]$ExpectedSourceCommit,
    [string]$ExpectedSourceTree,
    [string]$PackageIdentityPath,
    [string]$PackageArchivePath,
    [string]$ExtractedPackageRoot,
    [string]$PackageProfilePath,
    [string]$RendererManifestPath,
    [string]$ThaiEvidenceDirectory,
    [string]$EnglishEvidenceDirectory,
    [string]$RuntimeMatrixManifestPath,
    [string]$ContractEvidencePath,
    [string]$SyntheticEvidencePath,
    [string]$HumanReviewPath,
    [string]$GitHubSnapshotPath,
    [string]$CandidateLockPath,
    [string]$AuthorityReferencePath,
    [string]$EvidenceRoot,
    [string]$RepositoryRoot,
    [string]$RendererEvidenceRoot,
    [string]$OutputPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:V02ReleaseGateVersion = 'v0.2.0'
$script:V02ReleaseGateMilestoneNumber = 2
$script:V02ReleaseGateTrackerIssue = 11
$script:V02ReleaseGateExpectedMilestoneIssues = @(6, 7, 8, 9, 10, 11, 54, 63)
$script:V02ReleaseGateRequiredIssues = @(7, 9, 10, 149)
$script:V02ReleaseGatePackageProfileId = 'herdrops-v0.2-package-software-only-issue-149'
$script:V02ReleaseGateReferenceHostProfileId = 'herdrops-v0.2-submark-nb-software-only-20260822'
$script:V02ReleaseGateReferenceHostProfileSha256 = '96D01ED15A536F2DF50B59B43CFDEB3683DCE8667AE2E7BF6A96124182FE13A3'
$script:V02ReleaseGateReferenceHostSchemaSha256 = '98AC6A2D823D88960A79299B7B20424FF60E9C5299D458A30AB9A42BE4FC0FB3'
$script:V02ReleaseGateRendererPolicy = 'software-only-process-wide'
$script:V02ReleaseGateRendererMode = 'SoftwareOnly'
$script:V02ReleaseGateRendererPolicySha256 = '1D37C9C39449556EB30F9AB5B734F0C5411CF4203321AF0B238993D017229E92'
$script:V02ReleaseGatePackageReceiptSchemaSha256 = '8C7EF64ED06C94C6589D73C0AB47EB60B7EEF7BFE337F126D8D9D3F0CC0F4C4B'
$script:V02ReleaseGateDecisionId = 'herdrops-rec-all-v2'
$script:V02ReleaseGateDecisionPayloadSha256 = '48474610D2A20EE2F7CA2DAC0A3CCF45F919440C9C5D81EF5BA93AD7E524F62D'
$script:V02ReleaseGateDecisionReference = 'https://github.com/OSHEThai/HerdrOps/issues/149#issuecomment-5380637664'
$script:V02ReleaseGateAuthorityReferenceRelativePath = 'Plan/DECISIONS.md#D-024'
$script:V02ReleaseGateAuthorityFileSha256 = 'BFADC29EA34BAA13FF5D3F43013795C0258CF691369E5E150774D3F646F4F730'
$script:V02ReleaseGateAuthorityOwner = '@yutthaphon'
$script:V02ReleaseGateAuthorityRole = 'ProductOwner'
$script:V02ReleaseGateHerdrReleaseId = '0.8.2-preview.2026-08-19-b5c4a0176e91-x86_64-pc-windows-msvc'
$script:V02ReleaseGateHerdrExecutableSha256 = 'AFE7BAD9B77946917B509C9B638BB2A47BC1D4F19254957D15B0FAAFBEDB3E93'
$script:V02ReleaseGateMatrixHashScope = 'SHA256OfRFC8785JcsUtf8NoBomPayload'
$script:V02ReleaseGateHumanCheckIds = @(
    'package-receipt',
    'renderer-compatibility',
    'runtime-matrix-thai',
    'runtime-matrix-english',
    'issue-7-acceptance',
    'issue-9-acceptance',
    'issue-10-acceptance',
    'issue-149-acceptance',
    'tracker-11-readiness',
    'language-separation'
)

# The reference-host helper is an existing, read-only canonical JSON implementation.
# It is used for matrix payload re-hashing only; it does not start Herdr or call GitHub.
$referenceHostHelper = Join-Path $PSScriptRoot 'lib\V02ReferenceHostProfile.ps1'
if (-not (Test-Path -LiteralPath $referenceHostHelper -PathType Leaf)) {
    throw "v0.2 reference-host helper is missing: $referenceHostHelper"
}
. $referenceHostHelper

function Assert-V02ReleaseGateExactProperties {
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

function Get-V02ReleaseGateProperty {
    param(
        [Parameter(Mandatory = $true)]$Object,
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][string]$Context
    )

    if ($null -eq $Object -or -not (@($Object.PSObject.Properties.Name) -ccontains $Name)) {
        throw "$Context omitted '$Name'."
    }
    return $Object.$Name
}

function Assert-V02ReleaseGateString {
    param($Value, [Parameter(Mandatory = $true)][string]$Context)

    if ($Value -isnot [string] -or [string]::IsNullOrWhiteSpace([string]$Value)) {
        throw "$Context must be a nonblank native JSON string."
    }
    return [string]$Value
}

function Assert-V02ReleaseGateExactString {
    param($Value, [Parameter(Mandatory = $true)][string]$Expected, [Parameter(Mandatory = $true)][string]$Context)

    Assert-V02ReleaseGateString $Value $Context | Out-Null
    if ([string]$Value -cne $Expected) {
        throw "$Context must equal '$Expected'."
    }
}

function Assert-V02ReleaseGateBoolean {
    param($Value, [Parameter(Mandatory = $true)][string]$Context)

    if ($Value -isnot [bool]) {
        throw "$Context must be a native JSON boolean."
    }
    return [bool]$Value
}

function Assert-V02ReleaseGateInteger {
    param($Value, [Parameter(Mandatory = $true)][string]$Context, [int64]$Minimum = 0)

    $integerTypes = @([byte], [sbyte], [int16], [uint16], [int32], [uint32], [int64], [uint64])
    if ($null -eq $Value -or $integerTypes -notcontains $Value.GetType()) {
        throw "$Context must be a native JSON integer."
    }
    if ([decimal]$Value -lt [decimal]$Minimum) {
        throw "$Context must be at least $Minimum."
    }
}

function Assert-V02ReleaseGateSha256 {
    param($Value, [Parameter(Mandatory = $true)][string]$Context)

    Assert-V02ReleaseGateString $Value $Context | Out-Null
    if ([string]$Value -cnotmatch '^[0-9A-F]{64}$' -or [string]$Value -ceq ('0' * 64)) {
        throw "$Context must be a nonzero uppercase SHA-256."
    }
    return [string]$Value
}

function Assert-V02ReleaseGateGitObjectId {
    param($Value, [Parameter(Mandatory = $true)][string]$Context)

    Assert-V02ReleaseGateString $Value $Context | Out-Null
    if ([string]$Value -cnotmatch '^[0-9a-f]{40}$') {
        throw "$Context must be a lowercase 40-hex Git object ID."
    }
    return [string]$Value
}

function Assert-V02ReleaseGateEqual {
    param($Actual, $Expected, [Parameter(Mandatory = $true)][string]$Context)

    if ([string]$Actual -cne [string]$Expected) {
        throw "$Context mismatch. Actual='$Actual' Expected='$Expected'."
    }
}

function Assert-V02ReleaseGateDistinctSet {
    param(
        [Parameter(Mandatory = $true)][object[]]$Values,
        [Parameter(Mandatory = $true)][string]$Context
    )

    $normalized = @($Values | ForEach-Object { [string]$_ })
    if ($normalized.Count -ne @($normalized | Select-Object -Unique).Count) {
        throw "$Context contains duplicate values."
    }
}

function Resolve-V02ReleaseGateExistingPath {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][ValidateSet('Leaf', 'Container')][string]$Type,
        [Parameter(Mandatory = $true)][string]$Context
    )

    if (-not (Test-Path -LiteralPath $Path -PathType $Type)) {
        throw "$Context is missing: $Path"
    }
    $resolved = [IO.Path]::GetFullPath((Resolve-Path -LiteralPath $Path).Path).TrimEnd([char[]]@('\', '/'))
    Assert-V02ReleaseGateNoReparsePath -Path $resolved -Context $Context
    return $resolved
}

function Get-V02ReleaseGateFileSha256 {
    param([Parameter(Mandatory = $true)][string]$Path)

    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToUpperInvariant()
}

function Assert-V02ReleaseGateNoReparsePath {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Context
    )

    $full = [IO.Path]::GetFullPath($Path)
    $root = [IO.Path]::GetPathRoot($full)
    if ([string]::IsNullOrWhiteSpace($root)) {
        throw "$Context has no filesystem root: $Path"
    }
    $current = $root
    $tail = $full.Substring($root.Length)
    foreach ($part in ($tail -split '[\\/]')) {
        if ([string]::IsNullOrWhiteSpace($part)) { continue }
        $current = Join-Path $current $part
        if (Test-Path -LiteralPath $current) {
            $item = Get-Item -LiteralPath $current -Force
            if (([IO.FileAttributes]$item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                throw "$Context traverses a reparse point: $current"
            }
        }
    }
}

function Assert-V02ReleaseGatePathWithinRoot {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Root,
        [Parameter(Mandatory = $true)][string]$Context
    )

    $full = [IO.Path]::GetFullPath($Path).TrimEnd([char[]]@('\', '/'))
    $rootFull = [IO.Path]::GetFullPath($Root).TrimEnd([char[]]@('\', '/'))
    Assert-V02ReleaseGateNoReparsePath -Path $full -Context $Context
    Assert-V02ReleaseGateNoReparsePath -Path $rootFull -Context "$Context root"
    $prefix = $rootFull + [IO.Path]::DirectorySeparatorChar
    if (-not [StringComparer]::OrdinalIgnoreCase.Equals($full, $rootFull) -and
        -not $full.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) {
        throw "$Context escapes its evidence root. Path='$full' Root='$rootFull'."
    }
    return $full
}

function Get-V02ReleaseGateStableFileSnapshot {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Context
    )

    $fullPath = Resolve-V02ReleaseGateExistingPath -Path $Path -Type Leaf -Context $Context
    $stream = $null
    try {
        $stream = [IO.File]::Open($fullPath, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
        if ($stream.Length -gt [int32]::MaxValue) {
            throw "$Context is too large for bounded validation: $fullPath"
        }
        $bytes = New-Object byte[] ([int32]$stream.Length)
        $offset = 0
        while ($offset -lt $bytes.Length) {
            $read = $stream.Read($bytes, $offset, $bytes.Length - $offset)
            if ($read -le 0) { throw "$Context ended before the held-byte read completed: $fullPath" }
            $offset += $read
        }
    }
    finally {
        if ($null -ne $stream) { $stream.Dispose() }
    }
    return [pscustomobject][ordered]@{
        Path = $fullPath
        Bytes = [byte[]]$bytes
        Length = [int64]$bytes.Length
        Sha256 = (Get-V02Sha256Hex -Bytes $bytes).ToUpperInvariant()
    }
}

function ConvertFrom-V02ReleaseGateStrictJsonBytes {
    param(
        [Parameter(Mandatory = $true)][byte[]]$Bytes,
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Context
    )

    if ($Bytes.Length -ge 3 -and $Bytes[0] -eq 0xEF -and $Bytes[1] -eq 0xBB -and $Bytes[2] -eq 0xBF) {
        throw "$Context must be UTF-8 without a BOM: $Path"
    }
    try {
        $json = [Text.UTF8Encoding]::new($false, $true).GetString($Bytes)
    }
    catch {
        throw "$Context contains malformed UTF-8: $Path"
    }
    if ($json.IndexOf([char]0xFEFF) -ge 0) {
        throw "$Context contains an unexpected BOM character: $Path"
    }
    Assert-V02NoDuplicateJsonProperties -Json $json -Source $Path
    try {
        $value = if ((Get-Command ConvertFrom-Json -CommandType Cmdlet).Parameters.ContainsKey('DateKind')) {
            $json | ConvertFrom-Json -DateKind String
        }
        else {
            $json | ConvertFrom-Json
        }
    }
    catch {
        throw "$Context is malformed, commented, or has a trailing comma: $Path"
    }
    if ($null -eq $value -or $value -isnot [pscustomobject]) {
        throw "$Context root must be an object: $Path"
    }
    return [pscustomobject][ordered]@{ Value = $value; Json = $json }
}

function Read-V02ReleaseGateJsonFile {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Context
    )

    $snapshot = Get-V02ReleaseGateStableFileSnapshot -Path $Path -Context $Context
    try {
        $document = ConvertFrom-V02ReleaseGateStrictJsonBytes -Bytes $snapshot.Bytes -Path $snapshot.Path -Context $Context
    }
    catch {
        throw "$Context is not strict UTF-8 JSON: $($_.Exception.Message)"
    }
    return [pscustomobject][ordered]@{
        Path = $snapshot.Path
        Value = $document.Value
        Bytes = $snapshot.Bytes
        RawJson = $document.Json
        Length = $snapshot.Length
        FileSha256 = $snapshot.Sha256
    }
}

function Assert-V02ReleaseGateSnapshotUnchanged {
    param(
        [Parameter(Mandatory = $true)]$Snapshot,
        [Parameter(Mandatory = $true)][string]$Context
    )

    $current = Get-V02ReleaseGateStableFileSnapshot -Path $Snapshot.Path -Context $Context
    Assert-V02ReleaseGateEqual $current.Length $Snapshot.Length "$Context length"
    Assert-V02ReleaseGateEqual $current.Sha256 $Snapshot.Sha256 "$Context bytes"
    return $current
}

function Get-V02ReleaseGateGitIdentity {
    param([Parameter(Mandatory = $true)][string]$RepositoryRoot)

    $root = Resolve-V02ReleaseGateExistingPath -Path $RepositoryRoot -Type Container -Context 'RepositoryRoot'
    $commit = (& git -C $root rev-parse HEAD).Trim()
    if ($LASTEXITCODE -ne 0 -or $commit -notmatch '^[0-9a-f]{40}$') {
        throw "Could not resolve a lowercase 40-hex HEAD commit in $root."
    }
    $tree = (& git -C $root show -s --format=%T HEAD).Trim()
    if ($LASTEXITCODE -ne 0 -or $tree -notmatch '^[0-9a-f]{40}$') {
        throw "Could not resolve a lowercase 40-hex HEAD tree in $root."
    }
    $parentsLine = (& git -C $root show -s --format=%P HEAD).Trim()
    if ($LASTEXITCODE -ne 0) {
        throw "Could not resolve HEAD parents in $root."
    }
    $parents = @()
    if (-not [string]::IsNullOrWhiteSpace($parentsLine)) {
        $parents = @($parentsLine -split '\s+' | ForEach-Object {
                Assert-V02ReleaseGateGitObjectId $_ 'HEAD parent'
            })
    }
    $status = @(& git -C $root status --porcelain=v1 --untracked-files=all)
    if ($LASTEXITCODE -ne 0) {
        throw "Could not inspect the Git working tree in $root."
    }
    return [pscustomobject][ordered]@{
        RepositoryRoot = $root
        Commit = $commit
        Tree = $tree
        Parents = $parents
        Clean = ($status.Count -eq 0)
        PendingPaths = $status
    }
}

function Assert-V02ReleaseGateGitIdentity {
    param(
        [Parameter(Mandatory = $true)]$Identity,
        [Parameter(Mandatory = $true)][string]$ExpectedSourceCommit,
        [Parameter(Mandatory = $true)][string]$ExpectedSourceTree,
        [Parameter(Mandatory = $true)][string]$Phase
    )

    Assert-V02ReleaseGateEqual $Identity.Commit $ExpectedSourceCommit "$Phase source commit"
    Assert-V02ReleaseGateEqual $Identity.Tree $ExpectedSourceTree "$Phase source tree"
    if (-not [bool]$Identity.Clean) {
        throw "$Phase source checkout is not clean. Pending paths: $($Identity.PendingPaths -join ', ')"
    }
}

function Get-V02ReleaseGateRelativeOrAbsolutePath {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$BaseDirectory,
        [Parameter(Mandatory = $true)][string]$Context,
        [string]$AllowedRoot
    )

    $candidate = $Path
    if (-not [IO.Path]::IsPathRooted($candidate)) {
        $candidate = Join-Path $BaseDirectory $candidate
    }
    $resolved = Resolve-V02ReleaseGateExistingPath -Path $candidate -Type Leaf -Context $Context
    if (-not [string]::IsNullOrWhiteSpace($AllowedRoot)) {
        Assert-V02ReleaseGatePathWithinRoot -Path $resolved -Root $AllowedRoot -Context $Context | Out-Null
    }
    return $resolved
}

function Read-V02ReleaseGateEvidenceReceipt {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][ValidateSet('Contract', 'Synthetic')][string]$ExpectedClass,
        [Parameter(Mandatory = $true)][string]$ExpectedSourceCommit,
        [Parameter(Mandatory = $true)][string]$ExpectedSourceTree,
        [Parameter(Mandatory = $true)][string]$EvidenceRoot
    )

    $document = Read-V02ReleaseGateJsonFile -Path $Path -Context "$ExpectedClass evidence receipt"
    $receipt = $document.Value
    Assert-V02ReleaseGateExactProperties $receipt @(
        'SchemaVersion', 'EvidenceClass', 'Result', 'SourceCommit', 'SourceTree',
        'RuntimeObserved', 'ActualHerdrUsed', 'ReleaseCredit', 'Checks'
    ) "$ExpectedClass evidence receipt"
    Assert-V02ReleaseGateInteger $receipt.SchemaVersion "$ExpectedClass SchemaVersion" 1
    Assert-V02ReleaseGateEqual $receipt.SchemaVersion 1 "$ExpectedClass SchemaVersion"
    Assert-V02ReleaseGateExactString $receipt.EvidenceClass $ExpectedClass "$ExpectedClass EvidenceClass"
    Assert-V02ReleaseGateExactString $receipt.Result 'PASS' "$ExpectedClass Result"
    Assert-V02ReleaseGateGitObjectId $receipt.SourceCommit "$ExpectedClass SourceCommit" | Out-Null
    Assert-V02ReleaseGateGitObjectId $receipt.SourceTree "$ExpectedClass SourceTree" | Out-Null
    Assert-V02ReleaseGateEqual $receipt.SourceCommit $ExpectedSourceCommit "$ExpectedClass source commit"
    Assert-V02ReleaseGateEqual $receipt.SourceTree $ExpectedSourceTree "$ExpectedClass source tree"
    if ((Assert-V02ReleaseGateBoolean $receipt.RuntimeObserved "$ExpectedClass RuntimeObserved") -ne $false) {
        throw "$ExpectedClass evidence cannot claim RuntimeObserved."
    }
    if ((Assert-V02ReleaseGateBoolean $receipt.ActualHerdrUsed "$ExpectedClass ActualHerdrUsed") -ne $false) {
        throw "$ExpectedClass evidence cannot claim actual Herdr use."
    }
    if (Assert-V02ReleaseGateBoolean $receipt.ReleaseCredit "$ExpectedClass ReleaseCredit") {
        throw "$ExpectedClass evidence cannot claim Release credit."
    }

    $checks = @($receipt.Checks)
    if ($checks.Count -eq 0) {
        throw "$ExpectedClass evidence must contain at least one check."
    }
    $checkNames = New-Object System.Collections.Generic.List[string]
    foreach ($check in $checks) {
        Assert-V02ReleaseGateExactProperties $check @('Name', 'Result', 'Path', 'Sha256') "$ExpectedClass evidence check"
        $name = Assert-V02ReleaseGateString $check.Name "$ExpectedClass check Name"
        if ($checkNames.Contains($name)) {
            throw "$ExpectedClass evidence contains duplicate check '$name'."
        }
        [void]$checkNames.Add($name)
        Assert-V02ReleaseGateExactString $check.Result 'PASS' "$ExpectedClass check '$name' Result"
        $checkPath = Get-V02ReleaseGateRelativeOrAbsolutePath -Path ([string]$check.Path) `
            -BaseDirectory ([IO.Path]::GetDirectoryName($document.Path)) `
            -Context "$ExpectedClass check '$name' artifact" -AllowedRoot $EvidenceRoot
        $declaredSha = Assert-V02ReleaseGateSha256 $check.Sha256 "$ExpectedClass check '$name' Sha256"
        $checkSnapshot = Get-V02ReleaseGateStableFileSnapshot -Path $checkPath -Context "$ExpectedClass check '$name' artifact"
        Assert-V02ReleaseGateEqual $checkSnapshot.Sha256 $declaredSha "$ExpectedClass check '$name' artifact hash"
    }

    return [pscustomobject][ordered]@{
        Path = $document.Path
        FileSha256 = $document.FileSha256
        EvidenceClass = $ExpectedClass
        CheckCount = $checks.Count
    }
}

function Read-V02ReleaseGateAuthorityReference {
    param(
        [Parameter(Mandatory = $true)][string]$RepositoryRoot,
        [Parameter(Mandatory = $true)][string]$AuthorityReferencePath
    )

    $expectedPath = [IO.Path]::GetFullPath((Join-Path $RepositoryRoot 'Plan\DECISIONS.md')).TrimEnd([char[]]@('\', '/'))
    $actualPath = Resolve-V02ReleaseGateExistingPath -Path $AuthorityReferencePath -Type Leaf -Context 'Authority reference'
    if (-not [StringComparer]::OrdinalIgnoreCase.Equals($actualPath, $expectedPath)) {
        throw "Authority reference must be the committed Plan/DECISIONS.md: $expectedPath"
    }
    $snapshot = Get-V02ReleaseGateStableFileSnapshot -Path $actualPath -Context 'Authority reference'
    if ($snapshot.Sha256 -cne $script:V02ReleaseGateAuthorityFileSha256) {
        throw "Authority reference hash is not the approved REC-ALL v2 record. Expected=$script:V02ReleaseGateAuthorityFileSha256 Observed=$($snapshot.Sha256)"
    }
    $text = [Text.UTF8Encoding]::new($false, $true).GetString($snapshot.Bytes)
    foreach ($required in @(
            'D-024',
            'REC-ALL v2 is the authoritative cross-version owner decision',
            'herdrops-rec-all-v2',
            $script:V02ReleaseGateDecisionReference,
            $script:V02ReleaseGateDecisionPayloadSha256,
            $script:V02ReleaseGateAuthorityOwner,
            'Agents cannot self-grant owner or final Human authority'
        )) {
        if ($text.IndexOf($required, [StringComparison]::Ordinal) -lt 0) {
            throw "Authority reference is missing its trusted binding: $required"
        }
    }
    return [pscustomobject][ordered]@{
        Path = $snapshot.Path
        FileSha256 = $snapshot.Sha256
        RelativeReference = $script:V02ReleaseGateAuthorityReferenceRelativePath
        DecisionId = $script:V02ReleaseGateDecisionId
        ApprovalReference = $script:V02ReleaseGateDecisionReference
        PayloadSha256 = $script:V02ReleaseGateDecisionPayloadSha256
        OwnerIdentity = $script:V02ReleaseGateAuthorityOwner
        OwnerRole = $script:V02ReleaseGateAuthorityRole
        Authentication = 'TRUSTED_COMMITTED_PLAN_HASH'
    }
}

function Read-V02ReleaseGateCandidateLock {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$EvidenceRoot,
        [Parameter(Mandatory = $true)][string]$ExpectedSourceCommit,
        [Parameter(Mandatory = $true)][string]$ExpectedSourceTree,
        [Parameter(Mandatory = $true)][string]$PackageProfilePath,
        [Parameter(Mandatory = $true)]$Authority
    )

    $lockPath = Resolve-V02ReleaseGateExistingPath -Path $Path -Type Leaf -Context 'Approved candidate lock'
    Assert-V02ReleaseGatePathWithinRoot -Path $lockPath -Root $EvidenceRoot -Context 'Approved candidate lock' | Out-Null
    $document = Read-V02ReleaseGateJsonFile -Path $lockPath -Context 'Approved candidate lock'
    Assert-V02ReleaseGateExactProperties $document.Value @(
        'SchemaVersion', 'EvidenceClass', 'Result', 'Immutable', 'SourceCommit', 'SourceTree',
        'ProfileId', 'ProfileFileSha256', 'ProfileCanonicalSha256', 'Authority', 'Runtime', 'Human', 'Release'
    ) 'Approved candidate lock'
    Assert-V02ReleaseGateInteger $document.Value.SchemaVersion 'Approved candidate lock SchemaVersion' 1
    Assert-V02ReleaseGateEqual $document.Value.SchemaVersion 1 'Approved candidate lock SchemaVersion'
    Assert-V02ReleaseGateExactString $document.Value.EvidenceClass 'ApprovedCandidateLock' 'Approved candidate lock EvidenceClass'
    Assert-V02ReleaseGateExactString $document.Value.Result 'APPROVED' 'Approved candidate lock Result'
    if (-not (Assert-V02ReleaseGateBoolean $document.Value.Immutable 'Approved candidate lock Immutable')) {
        throw 'Approved candidate lock must be immutable.'
    }
    Assert-V02ReleaseGateEqual $document.Value.SourceCommit $ExpectedSourceCommit 'Approved candidate lock source commit'
    Assert-V02ReleaseGateEqual $document.Value.SourceTree $ExpectedSourceTree 'Approved candidate lock source tree'
    Assert-V02ReleaseGateExactString $document.Value.ProfileId $script:V02ReleaseGatePackageProfileId 'Approved candidate lock ProfileId'
    $profileSnapshot = Get-V02ReleaseGateStableFileSnapshot -Path $PackageProfilePath -Context 'Approved candidate lock package profile'
    Assert-V02ReleaseGateEqual $document.Value.ProfileFileSha256 $profileSnapshot.Sha256 'Approved candidate lock profile bytes'
    Assert-V02ReleaseGateSha256 $document.Value.ProfileCanonicalSha256 'Approved candidate lock profile canonical SHA-256' | Out-Null
    $profileDocument = ConvertFrom-V02ReleaseGateStrictJsonBytes -Bytes $profileSnapshot.Bytes -Path $profileSnapshot.Path -Context 'Approved candidate lock package profile'
    $profileCanonical = ConvertTo-V02Jcs $profileDocument.Value
    $profileCanonicalSha = (Get-V02Sha256Hex -Bytes ([Text.UTF8Encoding]::new($false).GetBytes($profileCanonical))).ToUpperInvariant()
    Assert-V02ReleaseGateEqual $document.Value.ProfileCanonicalSha256 $profileCanonicalSha 'Approved candidate lock profile canonical bytes'
    Assert-V02ReleaseGateExactString $document.Value.Runtime 'NOT_OBSERVED' 'Approved candidate lock Runtime boundary'
    Assert-V02ReleaseGateExactString $document.Value.Human 'NOT_OBSERVED' 'Approved candidate lock Human boundary'
    Assert-V02ReleaseGateExactString $document.Value.Release 'NOT_OBSERVED' 'Approved candidate lock Release boundary'

    Assert-V02ReleaseGateExactProperties $document.Value.Authority @(
        'DecisionId', 'ApprovalReference', 'PayloadSha256', 'Reference', 'ReferenceSha256', 'OwnerIdentity', 'OwnerRole'
    ) 'Approved candidate lock Authority'
    Assert-V02ReleaseGateEqual $document.Value.Authority.DecisionId $Authority.DecisionId 'Approved candidate lock authority decision'
    Assert-V02ReleaseGateEqual $document.Value.Authority.ApprovalReference $Authority.ApprovalReference 'Approved candidate lock authority reference'
    Assert-V02ReleaseGateEqual $document.Value.Authority.PayloadSha256 $Authority.PayloadSha256 'Approved candidate lock authority payload'
    Assert-V02ReleaseGateExactString $document.Value.Authority.Reference $Authority.RelativeReference 'Approved candidate lock authority source'
    Assert-V02ReleaseGateEqual $document.Value.Authority.ReferenceSha256 $Authority.FileSha256 'Approved candidate lock authority bytes'
    Assert-V02ReleaseGateExactString $document.Value.Authority.OwnerIdentity $Authority.OwnerIdentity 'Approved candidate lock authority owner'
    Assert-V02ReleaseGateExactString $document.Value.Authority.OwnerRole $Authority.OwnerRole 'Approved candidate lock authority role'
    return [pscustomobject][ordered]@{
        Path = $document.Path
        FileSha256 = $document.FileSha256
        SourceCommit = [string]$document.Value.SourceCommit
        SourceTree = [string]$document.Value.SourceTree
        ProfileId = [string]$document.Value.ProfileId
        ProfileFileSha256 = [string]$document.Value.ProfileFileSha256
        ProfileCanonicalSha256 = [string]$document.Value.ProfileCanonicalSha256
        Authority = $Authority
        Authentication = $Authority.Authentication
        Result = 'APPROVED_CANDIDATE_ONLY'
    }
}

function New-V02ReleaseGateNotReadyReport {
    param(
        [Parameter(Mandatory = $true)]$Identity,
        [Parameter(Mandatory = $true)][string]$Reason,
        $CandidateLock,
        $Authority
    )

    return [pscustomobject][ordered]@{
        SchemaVersion = 2
        Version = $script:V02ReleaseGateVersion
        Result = 'NOT_READY'
        ReleaseReady = $false
        SourceCommit = $Identity.Commit
        SourceTree = $Identity.Tree
        SourceParents = @($Identity.Parents)
        RepositoryRoot = $Identity.RepositoryRoot
        CandidateLock = if ($null -ne $CandidateLock) { $CandidateLock } else { [pscustomobject][ordered]@{ Status = 'NOT_READY' } }
        AuthorityReference = if ($null -ne $Authority) { $Authority } else { [pscustomobject][ordered]@{ Status = 'NOT_READY' } }
        GateReason = $Reason
        Package = [pscustomobject][ordered]@{ ReceiptSha256 = 'NOT_OBSERVED'; ReceiptFileSha256 = 'NOT_OBSERVED' }
        Renderer = [pscustomobject][ordered]@{ ManifestSha256 = 'NOT_OBSERVED' }
        RuntimeMatrix = [pscustomobject][ordered]@{ ManifestFileSha256 = 'NOT_OBSERVED' }
        GitHub = [pscustomobject][ordered]@{ SnapshotSha256 = 'NOT_OBSERVED' }
        HumanReview = [pscustomobject][ordered]@{ Status = 'NOT_OBSERVED'; Decision = 'NOT_OBSERVED'; Authenticated = $false }
        EvidenceClasses = [pscustomobject][ordered]@{
            Static = [pscustomobject][ordered]@{ Status = 'NOT_READY'; Classification = 'CandidateAuthority'; Credit = 'NONE' }
            Contract = [pscustomobject][ordered]@{ Status = 'NOT_OBSERVED'; Classification = 'Contract'; Credit = 'NONE' }
            Synthetic = [pscustomobject][ordered]@{ Status = 'NOT_OBSERVED'; Classification = 'Synthetic'; Credit = 'NONE' }
            Runtime = [pscustomobject][ordered]@{ Status = 'NOT_OBSERVED'; Classification = 'RuntimeMatrixCandidate'; Credit = 'NONE' }
            Human = [pscustomobject][ordered]@{ Status = 'NOT_OBSERVED'; Classification = 'Human'; Credit = 'NONE' }
            Release = [pscustomobject][ordered]@{ Status = 'NOT_OBSERVED'; Classification = 'Release'; Credit = 'NONE' }
        }
        EvidenceBoundary = [pscustomobject][ordered]@{
            ActualHerdrControlInvoked = $false
            GitHubMutationInvoked = $false
            PackagePublished = $false
            ReleasePublished = $false
            RuntimeObserved = $false
            HumanAuthorityObserved = $false
            ReleaseCredit = $false
        }
    }
}

function Assert-V02ReleaseGatePackageResult {
    param(
        [Parameter(Mandatory = $true)]$Result,
        [Parameter(Mandatory = $true)][string]$ExpectedSourceCommit,
        [Parameter(Mandatory = $true)][string]$ExpectedSourceTree
    )

    $required = @(
        'EvidenceClass', 'Issue', 'ProfileId', 'ReceiptSha256', 'SourceCommit', 'SourceTree',
        'PreparationProfileFileSha256', 'PreparationProfileCanonicalSha256', 'ArchiveSha256',
        'AppSha256', 'CoreSha256', 'ReferenceHostProfileSha256', 'RendererPolicySha256',
        'Runtime', 'Release'
    )
    Assert-V02ReleaseGateExactProperties $Result $required 'Package validator result'
    Assert-V02ReleaseGateExactString $Result.EvidenceClass 'Static/PackagedCompatibilityPreparation' 'Package validator EvidenceClass'
    Assert-V02ReleaseGateInteger $Result.Issue 'Package validator Issue' 149
    Assert-V02ReleaseGateEqual $Result.Issue 149 'Package validator Issue'
    Assert-V02ReleaseGateExactString $Result.ProfileId $script:V02ReleaseGatePackageProfileId 'Package validator ProfileId'
    Assert-V02ReleaseGateGitObjectId $Result.SourceCommit 'Package validator SourceCommit' | Out-Null
    Assert-V02ReleaseGateGitObjectId $Result.SourceTree 'Package validator SourceTree' | Out-Null
    Assert-V02ReleaseGateEqual $Result.SourceCommit $ExpectedSourceCommit 'Package validator source commit'
    Assert-V02ReleaseGateEqual $Result.SourceTree $ExpectedSourceTree 'Package validator source tree'
    foreach ($name in @(
            'ReceiptSha256', 'PreparationProfileFileSha256', 'PreparationProfileCanonicalSha256',
            'ArchiveSha256', 'AppSha256', 'CoreSha256', 'ReferenceHostProfileSha256', 'RendererPolicySha256'
        )) {
        Assert-V02ReleaseGateSha256 $Result.$name "Package validator $name" | Out-Null
    }
    Assert-V02ReleaseGateEqual $Result.ReferenceHostProfileSha256 $script:V02ReleaseGateReferenceHostProfileSha256 'Package validator reference-host profile'
    Assert-V02ReleaseGateEqual $Result.RendererPolicySha256 $script:V02ReleaseGateRendererPolicySha256 'Package validator renderer policy'
    Assert-V02ReleaseGateExactString $Result.Runtime 'NOT OBSERVED' 'Package validator Runtime boundary'
    Assert-V02ReleaseGateExactString $Result.Release 'NOT CLAIMED' 'Package validator Release boundary'
}

function Invoke-V02ReleaseGatePackageValidation {
    param(
        [Parameter(Mandatory = $true)]$Context,
        [Parameter(Mandatory = $true)][string]$ExpectedSourceCommit,
        [Parameter(Mandatory = $true)][string]$ExpectedSourceTree
    )

    $validatorPath = Join-Path $Context.RepositoryRoot 'tools\packaging\v0.2\Test-V02PackageIdentity.ps1'
    if (-not (Test-Path -LiteralPath $validatorPath -PathType Leaf)) {
        throw "Committed v0.2 package validator is missing: $validatorPath"
    }
    $firstOutput = @(& $validatorPath -IdentityPath $Context.IdentityPath -ArchivePath $Context.ArchivePath `
        -PackageRoot $Context.PackageRoot -RepositoryRoot $Context.RepositoryRoot -ProfilePath $Context.ProfilePath)
    if ($firstOutput.Count -ne 1) {
        throw 'Committed package validator must return exactly one result.'
    }
    $first = $firstOutput[0]
    Assert-V02ReleaseGatePackageResult $first $ExpectedSourceCommit $ExpectedSourceTree

    $secondOutput = @(& $validatorPath -IdentityPath $Context.IdentityPath -ArchivePath $Context.ArchivePath `
        -PackageRoot $Context.PackageRoot -RepositoryRoot $Context.RepositoryRoot -ProfilePath $Context.ProfilePath)
    if ($secondOutput.Count -ne 1) {
        throw 'Committed package validator returned a different result count on its stability pass.'
    }
    $second = $secondOutput[0]
    Assert-V02ReleaseGatePackageResult $second $ExpectedSourceCommit $ExpectedSourceTree
    foreach ($name in @($first.PSObject.Properties.Name)) {
        Assert-V02ReleaseGateEqual $second.$name $first.$name "Package validator stability '$name'"
    }

    $receiptPath = Resolve-V02ReleaseGateExistingPath -Path $Context.IdentityPath -Type Leaf -Context 'Package identity receipt'
    $archivePath = Resolve-V02ReleaseGateExistingPath -Path $Context.ArchivePath -Type Leaf -Context 'Package ZIP archive'
    $packageRoot = Resolve-V02ReleaseGateExistingPath -Path $Context.PackageRoot -Type Container -Context 'Extracted package root'
    $profilePath = Resolve-V02ReleaseGateExistingPath -Path $Context.ProfilePath -Type Leaf -Context 'Package identity profile'
    $manifestPath = Resolve-V02ReleaseGateExistingPath -Path (Join-Path $packageRoot 'package-manifest.json') -Type Leaf -Context 'Package manifest'
    $appPath = Resolve-V02ReleaseGateExistingPath -Path (Join-Path $packageRoot 'HerdrOps.App.exe') -Type Leaf -Context 'Package App executable'
    $corePath = Resolve-V02ReleaseGateExistingPath -Path (Join-Path $packageRoot 'HerdrOps.Core.exe') -Type Leaf -Context 'Package Core executable'
    $expectedProfilePath = [IO.Path]::GetFullPath((Join-Path $Context.RepositoryRoot 'tools\packaging\v0.2\package-identity-profile.json'))
    if (-not [StringComparer]::OrdinalIgnoreCase.Equals($profilePath, $expectedProfilePath)) {
        throw 'Package identity profile is not the committed v0.2 profile path.'
    }

    $package = [pscustomobject][ordered]@{
        IdentityPath = $receiptPath
        ReceiptFileSha256 = Get-V02ReleaseGateFileSha256 $receiptPath
        ReceiptSha256 = [string]$first.ReceiptSha256
        ArchivePath = $archivePath
        ArchiveSha256 = Get-V02ReleaseGateFileSha256 $archivePath
        PackageRoot = $packageRoot
        ManifestPath = $manifestPath
        ManifestSha256 = Get-V02ReleaseGateFileSha256 $manifestPath
        AppPath = $appPath
        AppSha256 = Get-V02ReleaseGateFileSha256 $appPath
        CorePath = $corePath
        CoreSha256 = Get-V02ReleaseGateFileSha256 $corePath
        ProfilePath = $profilePath
        ProfileFileSha256 = Get-V02ReleaseGateFileSha256 $profilePath
        ProfileCanonicalSha256 = [string]$first.PreparationProfileCanonicalSha256
        ProfileId = [string]$first.ProfileId
        ReferenceHostProfileSha256 = [string]$first.ReferenceHostProfileSha256
        RendererPolicySha256 = [string]$first.RendererPolicySha256
        SourceCommit = [string]$first.SourceCommit
        SourceTree = [string]$first.SourceTree
        EvidenceClass = [string]$first.EvidenceClass
    }
    Assert-V02ReleaseGateEqual $package.ArchiveSha256 $first.ArchiveSha256 'Package archive bytes'
    if ($first.PSObject.Properties.Name -contains 'PackageManifestSha256') {
        Assert-V02ReleaseGateEqual $package.ManifestSha256 $first.PackageManifestSha256 'Package manifest bytes'
    }
    Assert-V02ReleaseGateEqual $package.AppSha256 $first.AppSha256 'Package App bytes'
    Assert-V02ReleaseGateEqual $package.CoreSha256 $first.CoreSha256 'Package Core bytes'
    Assert-V02ReleaseGateEqual $package.ProfileFileSha256 $first.PreparationProfileFileSha256 'Package profile bytes'

    return $package
}

function Assert-V02ReleaseGateRendererResult {
    param(
        [Parameter(Mandatory = $true)]$Result,
        [Parameter(Mandatory = $true)][string]$Context
    )

    $required = @(
        'EvidenceClassification', 'ManifestVersion', 'StructuralValidation', 'BindingValidation',
        'GovernanceProfileConsistency', 'FinalHumanGoAuthority', 'OwnerNumericLimits',
        'HumanReview', 'ActualHerdrRuntime', 'Release', 'CreditGranted',
        'PackagedCompatibilityReadyForIssue149Closure'
    )
    Assert-V02ReleaseGateExactProperties $Result $required "$Context result"
    Assert-V02ReleaseGateExactString $Result.EvidenceClassification 'PackagedCompatibilityCandidate' "$Context EvidenceClassification"
    Assert-V02ReleaseGateInteger $Result.ManifestVersion "$Context ManifestVersion" 1
    Assert-V02ReleaseGateEqual $Result.ManifestVersion 1 "$Context ManifestVersion"
    Assert-V02ReleaseGateExactString $Result.StructuralValidation 'PASS' "$Context StructuralValidation"
    Assert-V02ReleaseGateExactString $Result.BindingValidation 'PASS' "$Context BindingValidation"
    Assert-V02ReleaseGateExactString $Result.GovernanceProfileConsistency 'PASS' "$Context GovernanceProfileConsistency"
    Assert-V02ReleaseGateExactString $Result.FinalHumanGoAuthority 'NOT_OBSERVED' "$Context FinalHumanGoAuthority"
    Assert-V02ReleaseGateExactString $Result.HumanReview 'NOT_OBSERVED' "$Context HumanReview"
    Assert-V02ReleaseGateExactString $Result.ActualHerdrRuntime 'NOT_OBSERVED' "$Context ActualHerdrRuntime"
    Assert-V02ReleaseGateExactString $Result.Release 'NOT_OBSERVED' "$Context Release"
    if (Assert-V02ReleaseGateBoolean $Result.CreditGranted "$Context CreditGranted") {
        throw "$Context cannot grant credit."
    }
    if (Assert-V02ReleaseGateBoolean $Result.PackagedCompatibilityReadyForIssue149Closure "$Context closure readiness") {
        throw "$Context must remain a candidate until the separate Human review is admitted."
    }
    Assert-V02ReleaseGateExactString $Result.OwnerNumericLimits 'APPROVED' "$Context owner numeric limits"
}

function Invoke-V02ReleaseGateRendererValidation {
    param(
        [Parameter(Mandatory = $true)]$Context,
        [Parameter(Mandatory = $true)]$Package,
        [Parameter(Mandatory = $true)][string]$ExpectedSourceCommit,
        [Parameter(Mandatory = $true)][string]$ExpectedSourceTree
    )

    $validatorPath = Join-Path $Context.RepositoryRoot 'tools\v0.2-renderer-compatibility\Test-V02RendererCompatibilityManifest.ps1'
    if (-not (Test-Path -LiteralPath $validatorPath -PathType Leaf)) {
        throw "Committed v0.2 renderer validator is missing: $validatorPath"
    }
    $manifestPath = Resolve-V02ReleaseGateExistingPath -Path $Context.ManifestPath -Type Leaf -Context 'Renderer compatibility manifest'
    $evidenceRoot = if ([string]::IsNullOrWhiteSpace($Context.EvidenceRoot)) {
        [IO.Path]::GetDirectoryName($manifestPath)
    }
    else {
        Resolve-V02ReleaseGateExistingPath -Path $Context.EvidenceRoot -Type Container -Context 'Renderer evidence root'
    }
    $validatorContext = [pscustomobject][ordered]@{
        ValidatorPath = $validatorPath
        ManifestPath = $manifestPath
        EvidenceRoot = $evidenceRoot
        RepositoryRoot = $Context.RepositoryRoot
    }
    $output = @(& $validatorPath -ManifestPath $validatorContext.ManifestPath -EvidenceRoot $validatorContext.EvidenceRoot `
        -RepositoryRoot $validatorContext.RepositoryRoot)
    if ($output.Count -ne 1) {
        throw 'Committed renderer validator must return exactly one result.'
    }
    $result = $output[0]
    Assert-V02ReleaseGateRendererResult $result 'Renderer compatibility'
    $manifestDocument = Read-V02ReleaseGateJsonFile -Path $manifestPath -Context 'Renderer compatibility manifest binding'
    Assert-V02ReleaseGateExactProperties $manifestDocument.Value @(
        '$id', 'manifestVersion', 'evidenceClassification', 'issue', 'governance', 'candidate',
        'environment', 'rendererEvidence', 'captures', 'references', 'comparison', 'matrices',
        'performanceProtocol', 'review', 'evidenceBoundary'
    ) 'Renderer compatibility manifest binding'
    Assert-V02ReleaseGateExactString $manifestDocument.Value.'$id' 'https://herdrops.local/schema/v0.2/renderer-compatibility-manifest.schema.json' 'Renderer manifest schema ID'
    Assert-V02ReleaseGateInteger $manifestDocument.Value.manifestVersion 'Renderer manifest version' 1
    Assert-V02ReleaseGateExactString $manifestDocument.Value.evidenceClassification 'PackagedCompatibilityCandidate' 'Renderer manifest classification'
    Assert-V02ReleaseGateInteger $manifestDocument.Value.issue 'Renderer manifest issue' 149
    Assert-V02ReleaseGateEqual $manifestDocument.Value.issue 149 'Renderer manifest issue'
    $governance = $manifestDocument.Value.governance
    Assert-V02ReleaseGateExactString $governance.decisionId $script:V02ReleaseGateDecisionId 'Renderer manifest decision ID'
    Assert-V02ReleaseGateExactString $governance.approvalReference $script:V02ReleaseGateDecisionReference 'Renderer manifest decision reference'
    Assert-V02ReleaseGateExactString $governance.decisionPayloadSha256 $script:V02ReleaseGateDecisionPayloadSha256 'Renderer manifest decision payload'
    Assert-V02ReleaseGateExactString $governance.supersedesDecisionId 'herdrops-rec-all-v1' 'Renderer manifest superseded decision'
    Assert-V02ReleaseGateExactString $governance.supersedesPayloadSha256 'DD8EB4D4BC896BE6A4765D409C5E34A16C4DBFB3D70F437EC915A50DF2FC1B1E' 'Renderer manifest superseded payload'
    $candidate = $manifestDocument.Value.candidate
    Assert-V02ReleaseGateEqual $candidate.source.commitSha $ExpectedSourceCommit 'Renderer candidate source commit'
    Assert-V02ReleaseGateEqual $candidate.source.treeSha $ExpectedSourceTree 'Renderer candidate source tree'
    Assert-V02ReleaseGateExactString $candidate.profile.id $script:V02ReleaseGatePackageProfileId 'Renderer candidate package profile ID'
    Assert-V02ReleaseGateEqual $candidate.profile.fileSha256 $Package.ProfileFileSha256 'Renderer candidate profile file hash'
    Assert-V02ReleaseGateEqual $candidate.profile.canonicalSha256 $Package.ProfileCanonicalSha256 'Renderer candidate profile canonical hash'
    Assert-V02ReleaseGateEqual $candidate.receipt.fileSha256 $Package.ReceiptFileSha256 'Renderer candidate receipt file hash'
    Assert-V02ReleaseGateEqual $candidate.receipt.canonicalSha256 $Package.ReceiptSha256 'Renderer candidate receipt canonical hash'
    Assert-V02ReleaseGateEqual $candidate.archive.sha256 $Package.ArchiveSha256 'Renderer candidate archive hash'
    Assert-V02ReleaseGateEqual $candidate.components.app.sha256 $Package.AppSha256 'Renderer candidate App hash'
    Assert-V02ReleaseGateEqual $candidate.components.core.sha256 $Package.CoreSha256 'Renderer candidate Core hash'
    Assert-V02ReleaseGateExactString $candidate.referenceHost.profileId $script:V02ReleaseGateReferenceHostProfileId 'Renderer candidate reference-host ID'
    Assert-V02ReleaseGateEqual $candidate.referenceHost.profileSha256 $script:V02ReleaseGateReferenceHostProfileSha256 'Renderer candidate reference-host hash'
    Assert-V02ReleaseGateExactString $candidate.renderer.policy $script:V02ReleaseGateRendererPolicy 'Renderer candidate policy'
    Assert-V02ReleaseGateExactString $candidate.renderer.wpfProcessRenderMode $script:V02ReleaseGateRendererMode 'Renderer candidate WPF mode'
    Assert-V02ReleaseGateExactString $manifestDocument.Value.review.decision 'NOT_OBSERVED' 'Renderer candidate Human review boundary'
    Assert-V02ReleaseGateExactString $manifestDocument.Value.evidenceBoundary.packagedCompatibility 'CANDIDATE' 'Renderer candidate packaged boundary'
    Assert-V02ReleaseGateExactString $manifestDocument.Value.evidenceBoundary.humanReview 'NOT_OBSERVED' 'Renderer candidate Human boundary'
    Assert-V02ReleaseGateExactString $manifestDocument.Value.evidenceBoundary.actualHerdrRuntime 'NOT_OBSERVED' 'Renderer candidate Runtime boundary'
    Assert-V02ReleaseGateExactString $manifestDocument.Value.evidenceBoundary.release 'NOT_OBSERVED' 'Renderer candidate Release boundary'
    if (Assert-V02ReleaseGateBoolean $manifestDocument.Value.evidenceBoundary.creditGranted 'Renderer candidate credit boundary') {
        throw 'Renderer candidate evidence boundary cannot grant credit.'
    }
    return [pscustomobject][ordered]@{
        ManifestPath = $manifestPath
        EvidenceRoot = $evidenceRoot
        ManifestSha256 = Get-V02ReleaseGateFileSha256 $manifestPath
        Manifest = $manifestDocument.Value
        Result = $result
    }
}

function Assert-V02ReleaseGateMatrixBinding {
    param(
        [Parameter(Mandatory = $true)]$Manifest,
        [Parameter(Mandatory = $true)]$Package,
        [Parameter(Mandatory = $true)][string]$ExpectedSourceCommit,
        [Parameter(Mandatory = $true)][string]$ExpectedSourceTree,
        [Parameter(Mandatory = $true)][string]$Context
    )

    Assert-V02ReleaseGateExactProperties $Manifest @(
        'EvidenceClassification', 'IndependentHumanReview', 'ReleaseCredit',
        'ManifestFormatVersion', 'ManifestHashScope', 'ManifestPayloadSha256', 'Payload'
    ) "$Context manifest"
    Assert-V02ReleaseGateExactString $Manifest.EvidenceClassification 'RuntimeMatrixCandidate' "$Context EvidenceClassification"
    Assert-V02ReleaseGateExactString $Manifest.IndependentHumanReview 'NOT_OBSERVED' "$Context IndependentHumanReview"
    Assert-V02ReleaseGateBoolean $Manifest.ReleaseCredit "$Context ReleaseCredit" | Out-Null
    if ([bool]$Manifest.ReleaseCredit) {
        throw "$Context cannot claim Release credit."
    }
    Assert-V02ReleaseGateInteger $Manifest.ManifestFormatVersion "$Context ManifestFormatVersion" 1
    Assert-V02ReleaseGateEqual $Manifest.ManifestFormatVersion 1 "$Context ManifestFormatVersion"
    Assert-V02ReleaseGateExactString $Manifest.ManifestHashScope $script:V02ReleaseGateMatrixHashScope "$Context ManifestHashScope"
    $payloadHash = Assert-V02ReleaseGateSha256 $Manifest.ManifestPayloadSha256 "$Context ManifestPayloadSha256"
    $payload = $Manifest.Payload
    Assert-V02ReleaseGateExactProperties $payload @('GeneratedUnixTimeMilliseconds', 'IndependentHumanReview', 'ReleaseCredit', 'Binding', 'Runs') "$Context payload"
    Assert-V02ReleaseGateInteger $payload.GeneratedUnixTimeMilliseconds "$Context payload GeneratedUnixTimeMilliseconds" 0
    Assert-V02ReleaseGateExactString $payload.IndependentHumanReview 'NOT_OBSERVED' "$Context payload IndependentHumanReview"
    if (Assert-V02ReleaseGateBoolean $payload.ReleaseCredit "$Context payload ReleaseCredit") {
        throw "$Context payload cannot claim Release credit."
    }
    $payloadCanonical = ConvertTo-V02Jcs $payload
    $payloadComputed = (Get-V02Sha256Hex -Bytes ([Text.UTF8Encoding]::new($false).GetBytes($payloadCanonical)))
    Assert-V02ReleaseGateEqual $payloadComputed $payloadHash "$Context payload hash"

    $binding = $payload.Binding
    Assert-V02ReleaseGateExactProperties $binding @(
        'SourceCommit', 'SourceTree', 'ProfileId', 'ProfileSha256', 'ReferenceHostSchemaSha256',
        'PackageIdentityReceiptSha256', 'HerdrReleaseId', 'HerdrExecutableSha256',
        'AppExecutableSha256', 'CoreExecutableSha256', 'BundledSchemaSha256', 'HerdrProtocol'
    ) "$Context binding"
    Assert-V02ReleaseGateGitObjectId $binding.SourceCommit "$Context binding SourceCommit" | Out-Null
    Assert-V02ReleaseGateGitObjectId $binding.SourceTree "$Context binding SourceTree" | Out-Null
    Assert-V02ReleaseGateEqual $binding.SourceCommit $ExpectedSourceCommit "$Context binding source commit"
    Assert-V02ReleaseGateEqual $binding.SourceTree $ExpectedSourceTree "$Context binding source tree"
    Assert-V02ReleaseGateExactString $binding.ProfileId $script:V02ReleaseGateReferenceHostProfileId "$Context binding ProfileId"
    Assert-V02ReleaseGateSha256 $binding.ProfileSha256 "$Context binding ProfileSha256" | Out-Null
    Assert-V02ReleaseGateEqual $binding.ProfileSha256 $script:V02ReleaseGateReferenceHostProfileSha256 "$Context binding ProfileSha256"
    Assert-V02ReleaseGateSha256 $binding.ReferenceHostSchemaSha256 "$Context binding ReferenceHostSchemaSha256" | Out-Null
    Assert-V02ReleaseGateEqual $binding.ReferenceHostSchemaSha256 $script:V02ReleaseGateReferenceHostSchemaSha256 "$Context binding ReferenceHostSchemaSha256"
    Assert-V02ReleaseGateSha256 $binding.PackageIdentityReceiptSha256 "$Context binding PackageIdentityReceiptSha256" | Out-Null
    Assert-V02ReleaseGateEqual $binding.PackageIdentityReceiptSha256 $Package.ReceiptSha256 "$Context binding package receipt"
    Assert-V02ReleaseGateExactString $binding.HerdrReleaseId $script:V02ReleaseGateHerdrReleaseId "$Context binding HerdrReleaseId"
    Assert-V02ReleaseGateSha256 $binding.HerdrExecutableSha256 "$Context binding HerdrExecutableSha256" | Out-Null
    Assert-V02ReleaseGateEqual $binding.HerdrExecutableSha256 $script:V02ReleaseGateHerdrExecutableSha256 "$Context binding HerdrExecutableSha256"
    Assert-V02ReleaseGateEqual $binding.AppExecutableSha256 $Package.AppSha256 "$Context binding App executable"
    Assert-V02ReleaseGateEqual $binding.CoreExecutableSha256 $Package.CoreSha256 "$Context binding Core executable"
    Assert-V02ReleaseGateSha256 $binding.BundledSchemaSha256 "$Context binding BundledSchemaSha256" | Out-Null
    Assert-V02ReleaseGateInteger $binding.HerdrProtocol "$Context binding HerdrProtocol" 1 | Out-Null

    $runs = @($payload.Runs)
    if ($runs.Count -ne 2) {
        throw "$Context must contain exactly two language runs."
    }
    $expectedLanguages = @('Thai', 'English')
    $captureRoots = New-Object System.Collections.Generic.List[string]
    for ($index = 0; $index -lt $runs.Count; $index++) {
        $run = $runs[$index]
        Assert-V02ReleaseGateExactProperties $run @(
            'Language', 'Culture', 'EvidenceDirectory', 'CaptureRoot', 'GateReportSha256',
            'AppRuntimeReportSha256', 'CoreRuntimeReportSha256', 'ProgressHistorySha256',
            'ProgressHistoryLastEntrySha256', 'PackageIdentityReceiptSha256', 'SourceCommit',
            'SourceTree', 'ProfileId', 'ProfileSha256', 'ReferenceHostSchemaSha256',
            'HerdrReleaseId', 'HerdrExecutableSha256', 'AppExecutableSha256',
            'CoreExecutableSha256', 'BundledSchemaSha256', 'HerdrProtocol',
            'RendererPolicyId', 'WpfProcessRenderMode', 'CaptureCount', 'Captures'
        ) "$Context run $index"
        Assert-V02ReleaseGateExactString $run.Language $expectedLanguages[$index] "$Context run $index Language"
        $expectedCulture = if ($index -eq 0) { 'th-TH' } else { 'en-US' }
        Assert-V02ReleaseGateExactString $run.Culture $expectedCulture "$Context run $index Culture"
        foreach ($pathName in @('EvidenceDirectory', 'CaptureRoot')) {
            $pathValue = Assert-V02ReleaseGateString $run.$pathName "$Context run $index $pathName"
            if (-not [IO.Path]::IsPathRooted($pathValue)) {
                throw "$Context run $index $pathName must be absolute."
            }
            [void]$captureRoots.Add([IO.Path]::GetFullPath($pathValue).TrimEnd([char[]]@('\', '/')))
        }
        foreach ($name in @(
                'GateReportSha256', 'AppRuntimeReportSha256', 'CoreRuntimeReportSha256',
                'ProgressHistorySha256', 'ProgressHistoryLastEntrySha256', 'PackageIdentityReceiptSha256',
                'ProfileSha256', 'ReferenceHostSchemaSha256', 'HerdrExecutableSha256',
                'AppExecutableSha256', 'CoreExecutableSha256', 'BundledSchemaSha256'
            )) {
            Assert-V02ReleaseGateSha256 $run.$name "$Context run $index $name" | Out-Null
        }
        Assert-V02ReleaseGateEqual $run.SourceCommit $ExpectedSourceCommit "$Context run $index SourceCommit"
        Assert-V02ReleaseGateEqual $run.SourceTree $ExpectedSourceTree "$Context run $index SourceTree"
        Assert-V02ReleaseGateEqual $run.PackageIdentityReceiptSha256 $Package.ReceiptSha256 "$Context run $index package receipt"
        Assert-V02ReleaseGateEqual $run.AppExecutableSha256 $Package.AppSha256 "$Context run $index App executable"
        Assert-V02ReleaseGateEqual $run.CoreExecutableSha256 $Package.CoreSha256 "$Context run $index Core executable"
        Assert-V02ReleaseGateEqual $run.ProfileId $script:V02ReleaseGateReferenceHostProfileId "$Context run $index ProfileId"
        Assert-V02ReleaseGateEqual $run.ProfileSha256 $script:V02ReleaseGateReferenceHostProfileSha256 "$Context run $index ProfileSha256"
        Assert-V02ReleaseGateEqual $run.ReferenceHostSchemaSha256 $script:V02ReleaseGateReferenceHostSchemaSha256 "$Context run $index ReferenceHostSchemaSha256"
        Assert-V02ReleaseGateEqual $run.HerdrReleaseId $script:V02ReleaseGateHerdrReleaseId "$Context run $index HerdrReleaseId"
        Assert-V02ReleaseGateEqual $run.HerdrExecutableSha256 $script:V02ReleaseGateHerdrExecutableSha256 "$Context run $index HerdrExecutableSha256"
        Assert-V02ReleaseGateEqual $run.RendererPolicyId $script:V02ReleaseGateRendererPolicy "$Context run $index RendererPolicyId"
        Assert-V02ReleaseGateEqual $run.WpfProcessRenderMode $script:V02ReleaseGateRendererMode "$Context run $index WpfProcessRenderMode"
        Assert-V02ReleaseGateInteger $run.HerdrProtocol "$Context run $index HerdrProtocol" 1 | Out-Null
        Assert-V02ReleaseGateInteger $run.CaptureCount "$Context run $index CaptureCount" 8
        if ([int64]$run.CaptureCount -ne 8 -or @($run.Captures).Count -ne 8) {
            throw "$Context run $index must contain exactly eight runtime captures."
        }
    }
    Assert-V02ReleaseGateDistinctSet -Values $captureRoots.ToArray() -Context "$Context evidence/capture roots"
    return $payload
}

function Copy-V02ReleaseGateObject {
    param([Parameter(Mandatory = $true)]$Object)

    return (($Object | ConvertTo-Json -Depth 100) | ConvertFrom-Json)
}

function Get-V02ReleaseGateNormalizedMatrixPayload {
    param([Parameter(Mandatory = $true)]$Manifest)

    $copy = Copy-V02ReleaseGateObject $Manifest.Payload
    $copy.GeneratedUnixTimeMilliseconds = [int64]0
    return ConvertTo-V02Jcs $copy
}

function Invoke-V02ReleaseGateMatrixValidation {
    param(
        [Parameter(Mandatory = $true)]$Context,
        [Parameter(Mandatory = $true)]$Package,
        [Parameter(Mandatory = $true)][string]$ExpectedSourceCommit,
        [Parameter(Mandatory = $true)][string]$ExpectedSourceTree,
        [Parameter(Mandatory = $true)][string]$RuntimeMatrixManifestPath
    )

    $manifestDocument = Read-V02ReleaseGateJsonFile -Path $RuntimeMatrixManifestPath -Context 'Runtime language matrix manifest'
    $candidate = $manifestDocument.Value
    Assert-V02ReleaseGateMatrixBinding $candidate $Package $ExpectedSourceCommit $ExpectedSourceTree 'Runtime language matrix' | Out-Null

    $validatorPath = Join-Path $Context.RepositoryRoot 'tools\Test-V02LanguageMatrixAcceptance.ps1'
    if (-not (Test-Path -LiteralPath $validatorPath -PathType Leaf)) {
        throw "Committed v0.2 language-matrix validator is missing: $validatorPath"
    }
    $validatorContext = [pscustomobject][ordered]@{
        ValidatorPath = $validatorPath
        ThaiEvidenceDirectory = $Context.ThaiEvidenceDirectory
        EnglishEvidenceDirectory = $Context.EnglishEvidenceDirectory
        PackageIdentityPath = $Package.IdentityPath
        PackageArchivePath = $Package.ArchivePath
        ExtractedPackageRoot = $Package.PackageRoot
        RepositoryRoot = $Context.RepositoryRoot
        PackageProfilePath = $Package.ProfilePath
    }
    $generated = $null
    $temporary = Join-Path ([IO.Path]::GetTempPath()) ('.herdrops-v02-matrix-' + [Guid]::NewGuid().ToString('N') + '.json')
    try {
        $output = @(& $validatorPath `
            -ThaiEvidenceDirectory $Context.ThaiEvidenceDirectory `
            -EnglishEvidenceDirectory $Context.EnglishEvidenceDirectory `
            -PackageIdentityPath $Package.IdentityPath `
            -PackageArchivePath $Package.ArchivePath `
            -ExtractedPackageRoot $Package.PackageRoot `
            -RepositoryRoot $Context.RepositoryRoot `
            -PackageProfilePath $Package.ProfilePath `
            -OutputPath $temporary)
        if ($LASTEXITCODE -ne 0) {
            throw "Committed language-matrix validator exited with $LASTEXITCODE."
        }
        $generated = (Read-V02ReleaseGateJsonFile -Path $temporary -Context 'Generated runtime language matrix candidate').Value
    }
    finally {
        if ($null -ne $temporary -and (Test-Path -LiteralPath $temporary)) {
            Remove-Item -LiteralPath $temporary -Force
        }
    }
    Assert-V02ReleaseGateMatrixBinding $generated $Package $ExpectedSourceCommit $ExpectedSourceTree 'Independently regenerated runtime language matrix' | Out-Null
    Assert-V02ReleaseGateEqual (Get-V02ReleaseGateNormalizedMatrixPayload $candidate) `
        (Get-V02ReleaseGateNormalizedMatrixPayload $generated) 'Runtime language matrix stable payload'
    return [pscustomobject][ordered]@{
        ManifestPath = $manifestDocument.Path
        ManifestFileSha256 = $manifestDocument.FileSha256
        ManifestPayloadSha256 = [string]$candidate.ManifestPayloadSha256
        Candidate = $candidate
    }
}

function Assert-V02ReleaseGateGitHubSnapshot {
    param(
        [Parameter(Mandatory = $true)]$Snapshot,
        [string]$Context = 'GitHub snapshot'
    )

    Assert-V02ReleaseGateExactProperties $Snapshot @('schemaVersion', 'repository', 'milestones', 'issues') $Context
    Assert-V02ReleaseGateInteger $Snapshot.schemaVersion "$Context schemaVersion" 1
    Assert-V02ReleaseGateEqual $Snapshot.schemaVersion 1 "$Context schemaVersion"
    Assert-V02ReleaseGateExactString $Snapshot.repository 'OSHEThai/HerdrOps' "$Context repository"
    $milestones = @($Snapshot.milestones)
    $matchingMilestones = @($milestones | Where-Object { [int]$_.number -eq $script:V02ReleaseGateMilestoneNumber -and [string]$_.title -ceq $script:V02ReleaseGateVersion })
    if ($matchingMilestones.Count -ne 1) {
        throw "$Context must contain exactly one v0.2.0 milestone #$script:V02ReleaseGateMilestoneNumber."
    }
    Assert-V02ReleaseGateExactString $matchingMilestones[0].state 'closed' "$Context v0.2.0 milestone state"

    $issues = @($Snapshot.issues)
    $numbers = @($issues | ForEach-Object { [int]$_.number })
    Assert-V02ReleaseGateDistinctSet -Values $numbers -Context "$Context issue numbers"
    $milestoneIssueNumbers = @($issues | Where-Object {
            $null -ne $_.milestone -and [int]$_.milestone.number -eq $script:V02ReleaseGateMilestoneNumber -and
                [string]$_.milestone.title -ceq $script:V02ReleaseGateVersion
        } | ForEach-Object { [int]$_.number } | Sort-Object)
    if (($milestoneIssueNumbers -join ',') -cne (@($script:V02ReleaseGateExpectedMilestoneIssues | Sort-Object) -join ',')) {
        throw "$Context v0.2.0 issue set is incomplete or unexpected. Expected=$(@($script:V02ReleaseGateExpectedMilestoneIssues | Sort-Object) -join ',') Observed=$($milestoneIssueNumbers -join ',')."
    }
    foreach ($number in @($script:V02ReleaseGateRequiredIssues + $script:V02ReleaseGateTrackerIssue)) {
        $matches = @($issues | Where-Object { [int]$_.number -eq $number })
        if ($matches.Count -ne 1) {
            throw "$Context must contain exactly one issue #$number."
        }
        $issue = $matches[0]
        Assert-V02ReleaseGateExactString $issue.state 'closed' "$Context issue #$number state"
        if ($number -ne 149) {
            if ($null -eq $issue.milestone -or [int]$issue.milestone.number -ne $script:V02ReleaseGateMilestoneNumber -or
                [string]$issue.milestone.title -cne $script:V02ReleaseGateVersion) {
                throw "$Context issue #$number is not attached to the exact v0.2.0 milestone."
            }
        }
    }
    $tracker = @($issues | Where-Object { [int]$_.number -eq $script:V02ReleaseGateTrackerIssue })[0]
    Assert-V02ReleaseGateExactString $tracker.title '[v0.2.0] Release readiness tracker' "$Context tracker title"

    $openV02Issues = @($issues | Where-Object {
            $milestone = $_.milestone
            $null -ne $milestone -and [int]$milestone.number -eq $script:V02ReleaseGateMilestoneNumber -and
                [string]$milestone.title -ceq $script:V02ReleaseGateVersion -and [string]$_.state -ceq 'open'
        })
    if ($openV02Issues.Count -ne 0) {
        throw "$Context has open v0.2.0 issue(s): $(@($openV02Issues | ForEach-Object { $_.number }) -join ', ')."
    }
    return [pscustomobject][ordered]@{
        Status = 'UNAUTHENTICATED_LOCAL_SNAPSHOT'
        Authenticated = $false
        MilestoneNumber = $script:V02ReleaseGateMilestoneNumber
        MilestoneState = [string]$matchingMilestones[0].state
        TrackerIssue = $script:V02ReleaseGateTrackerIssue
        MilestoneIssueCount = $milestoneIssueNumbers.Count
        RequiredIssueCount = $script:V02ReleaseGateRequiredIssues.Count
        OpenV02IssueCount = $openV02Issues.Count
    }
}

function Assert-V02ReleaseGateHumanReview {
    param(
        [Parameter(Mandatory = $true)]$Review,
        [Parameter(Mandatory = $true)][string]$ReviewPath,
        [Parameter(Mandatory = $true)][string]$ExpectedSourceCommit,
        [Parameter(Mandatory = $true)][string]$ExpectedSourceTree,
        [Parameter(Mandatory = $true)]$Package,
        [Parameter(Mandatory = $true)]$Renderer,
        [Parameter(Mandatory = $true)]$Matrix,
        [Parameter(Mandatory = $true)][string]$GitHubSnapshotPath,
        [Parameter(Mandatory = $true)][string]$GitHubSnapshotSha256,
        [Parameter(Mandatory = $true)][string]$EvidenceRoot
    )

    Assert-V02ReleaseGateExactProperties $Review @(
        'SchemaVersion', 'EvidenceClass', 'Result', 'Decision', 'Reviewer', 'Candidate',
        'Checks', 'OpenFindings', 'ActualHerdrRuntime', 'ReleaseCredit'
    ) 'Human review'
    Assert-V02ReleaseGateInteger $Review.SchemaVersion 'Human review SchemaVersion' 1
    Assert-V02ReleaseGateEqual $Review.SchemaVersion 1 'Human review SchemaVersion'
    Assert-V02ReleaseGateExactString $Review.EvidenceClass 'Human' 'Human review EvidenceClass'
    Assert-V02ReleaseGateExactString $Review.Result 'PASS' 'Human review Result'
    Assert-V02ReleaseGateExactString $Review.Decision 'GO' 'Human review Decision'
    Assert-V02ReleaseGateExactString $Review.ActualHerdrRuntime 'NOT_OBSERVED' 'Human review ActualHerdrRuntime'
    if (Assert-V02ReleaseGateBoolean $Review.ReleaseCredit 'Human review ReleaseCredit') {
        throw 'Human review cannot grant Release credit.'
    }

    Assert-V02ReleaseGateExactProperties $Review.Reviewer @(
        'Identity', 'Role', 'BuilderIdentity', 'RuntimeOperatorIdentity', 'RoleDistinct', 'ReviewedUtc'
    ) 'Human review Reviewer'
    $reviewerIdentity = Assert-V02ReleaseGateString $Review.Reviewer.Identity 'Human reviewer identity'
    Assert-V02ReleaseGateExactString $Review.Reviewer.Role 'IndependentReleaseReviewer' 'Human reviewer role'
    $builderIdentity = Assert-V02ReleaseGateString $Review.Reviewer.BuilderIdentity 'Human review builder identity'
    $runtimeIdentity = Assert-V02ReleaseGateString $Review.Reviewer.RuntimeOperatorIdentity 'Human review runtime-operator identity'
    if (-not (Assert-V02ReleaseGateBoolean $Review.Reviewer.RoleDistinct 'Human review RoleDistinct')) {
        throw 'Human review must explicitly record role distinction.'
    }
    Assert-V02ReleaseGateString $Review.Reviewer.ReviewedUtc 'Human review ReviewedUtc' | Out-Null
    $null = [DateTimeOffset]$Review.Reviewer.ReviewedUtc
    Assert-V02ReleaseGateDistinctSet -Values @($reviewerIdentity, $builderIdentity, $runtimeIdentity) -Context 'Human review identities'

    Assert-V02ReleaseGateExactProperties $Review.Candidate @(
        'SourceCommit', 'SourceTree', 'PackageReceiptSha256', 'PackageReceiptFileSha256',
        'PackageArchiveSha256', 'PackageAppSha256', 'PackageCoreSha256',
        'RendererManifestSha256', 'RuntimeMatrixManifestSha256', 'GitHubSnapshotSha256'
    ) 'Human review candidate binding'
    Assert-V02ReleaseGateEqual $Review.Candidate.SourceCommit $ExpectedSourceCommit 'Human review source commit'
    Assert-V02ReleaseGateEqual $Review.Candidate.SourceTree $ExpectedSourceTree 'Human review source tree'
    Assert-V02ReleaseGateEqual $Review.Candidate.PackageReceiptSha256 $Package.ReceiptSha256 'Human review package receipt'
    Assert-V02ReleaseGateEqual $Review.Candidate.PackageReceiptFileSha256 $Package.ReceiptFileSha256 'Human review package receipt file'
    Assert-V02ReleaseGateEqual $Review.Candidate.PackageArchiveSha256 $Package.ArchiveSha256 'Human review package archive'
    Assert-V02ReleaseGateEqual $Review.Candidate.PackageAppSha256 $Package.AppSha256 'Human review package App'
    Assert-V02ReleaseGateEqual $Review.Candidate.PackageCoreSha256 $Package.CoreSha256 'Human review package Core'
    Assert-V02ReleaseGateEqual $Review.Candidate.RendererManifestSha256 $Renderer.ManifestSha256 'Human review renderer manifest'
    Assert-V02ReleaseGateEqual $Review.Candidate.RuntimeMatrixManifestSha256 $Matrix.ManifestFileSha256 'Human review runtime matrix'
    Assert-V02ReleaseGateEqual $Review.Candidate.GitHubSnapshotSha256 $GitHubSnapshotSha256 'Human review GitHub snapshot'
    foreach ($name in @(
            'PackageReceiptSha256', 'PackageReceiptFileSha256', 'PackageArchiveSha256',
            'PackageAppSha256', 'PackageCoreSha256', 'RendererManifestSha256',
            'RuntimeMatrixManifestSha256', 'GitHubSnapshotSha256'
        )) {
        Assert-V02ReleaseGateSha256 $Review.Candidate.$name "Human review candidate $name" | Out-Null
    }
    Assert-V02ReleaseGateGitObjectId $Review.Candidate.SourceCommit 'Human review candidate SourceCommit' | Out-Null
    Assert-V02ReleaseGateGitObjectId $Review.Candidate.SourceTree 'Human review candidate SourceTree' | Out-Null

    $checks = @($Review.Checks)
    if ($checks.Count -ne $script:V02ReleaseGateHumanCheckIds.Count) {
        throw "Human review must contain exactly $($script:V02ReleaseGateHumanCheckIds.Count) required checks."
    }
    $seen = New-Object System.Collections.Generic.List[string]
    $seenPaths = @{}
    foreach ($check in $checks) {
        Assert-V02ReleaseGateExactProperties $check @('Id', 'Status', 'Path', 'Sha256', 'Binding') 'Human review check'
        $id = Assert-V02ReleaseGateString $check.Id 'Human review check Id'
        if ($seen.Contains($id)) { throw "Human review contains duplicate check '$id'." }
        [void]$seen.Add($id)
        if ($script:V02ReleaseGateHumanCheckIds -notcontains $id) { throw "Human review contains unknown check '$id'." }
        Assert-V02ReleaseGateExactString $check.Status 'PASS' "Human review check '$id' status"
        Assert-V02ReleaseGateExactString $check.Binding ("HumanCheck:$id") "Human review check '$id' binding"
        $checkPath = Get-V02ReleaseGateRelativeOrAbsolutePath -Path ([string]$check.Path) `
            -BaseDirectory ([IO.Path]::GetDirectoryName($ReviewPath)) -Context "Human review check '$id' artifact" `
            -AllowedRoot $EvidenceRoot
        $declared = Assert-V02ReleaseGateSha256 $check.Sha256 "Human review check '$id' hash"
        $checkSnapshot = Get-V02ReleaseGateStableFileSnapshot -Path $checkPath -Context "Human review check '$id' artifact"
        Assert-V02ReleaseGateEqual $checkSnapshot.Sha256 $declared "Human review check '$id' artifact hash"
        $pathKey = $checkPath.ToUpperInvariant()
        if ($seenPaths.ContainsKey($pathKey) -and
            -not (($seenPaths[$pathKey] -in @('runtime-matrix-thai', 'runtime-matrix-english')) -and
                 ($id -in @('runtime-matrix-thai', 'runtime-matrix-english')))) {
            throw "Human review check '$id' reuses the artifact path already bound to '$($seenPaths[$pathKey])'."
        }
        $seenPaths[$pathKey] = $id
        if ($id -ceq 'package-receipt') {
            Assert-V02ReleaseGateEqual $checkPath $Package.IdentityPath "Human review package receipt path"
            Assert-V02ReleaseGateEqual $declared $Package.ReceiptFileSha256 "Human review package receipt file binding"
        }
        elseif ($id -ceq 'renderer-compatibility') {
            Assert-V02ReleaseGateEqual $checkPath $Renderer.ManifestPath "Human review renderer manifest path"
            Assert-V02ReleaseGateEqual $declared $Renderer.ManifestSha256 "Human review renderer manifest binding"
        }
        elseif ($id -ceq 'runtime-matrix-thai' -or $id -ceq 'runtime-matrix-english') {
            Assert-V02ReleaseGateEqual $checkPath $Matrix.ManifestPath "Human review runtime matrix path"
            Assert-V02ReleaseGateEqual $declared $Matrix.ManifestFileSha256 "Human review runtime matrix binding"
        }
        elseif ($id -ceq 'tracker-11-readiness') {
            Assert-V02ReleaseGateEqual $checkPath $GitHubSnapshotPath "Human review tracker snapshot path"
            Assert-V02ReleaseGateEqual $declared $GitHubSnapshotSha256 "Human review tracker snapshot binding"
        }
    }
    foreach ($id in $script:V02ReleaseGateHumanCheckIds) {
        if (-not $seen.Contains($id)) { throw "Human review omitted required check '$id'." }
    }
    $openFindings = @($Review.OpenFindings)
    if ($openFindings.Count -ne 0) {
        throw 'Human review cannot pass with open findings.'
    }
    return [pscustomobject][ordered]@{
        Path = $ReviewPath
        FileSha256 = Get-V02ReleaseGateFileSha256 -Path $ReviewPath
        Status = 'NOT_OBSERVED'
        Decision = 'NOT_OBSERVED'
        Reason = 'LOCAL_REVIEW_RECORD_IS_NOT_AN_AUTHENTICATED_INDEPENDENT_RECEIPT'
        ReviewerIdentity = [string]$Review.Reviewer.Identity
        ReviewerRole = [string]$Review.Reviewer.Role
        RoleDistinct = [bool]$Review.Reviewer.RoleDistinct
        OpenFindingCount = @($Review.OpenFindings).Count
        Authenticated = $false
    }
}

function Write-V02ReleaseGateReport {
    param(
        [Parameter(Mandatory = $true)]$Report,
        [Parameter(Mandatory = $true)][string]$OutputPath
    )

    $resolved = [IO.Path]::GetFullPath($OutputPath)
    $jsonPath = $resolved
    $textPath = $null
    if ([IO.Path]::GetExtension($resolved) -ieq '.json') {
        $parent = [IO.Path]::GetDirectoryName($resolved)
        if (-not [IO.Directory]::Exists($parent)) { [IO.Directory]::CreateDirectory($parent) | Out-Null }
        $textPath = Join-Path $parent 'gate-report.txt'
    }
    else {
        if (Test-Path -LiteralPath $resolved -PathType Leaf) { throw "OutputPath is a file, not a directory: $resolved" }
        if (-not [IO.Directory]::Exists($resolved)) { [IO.Directory]::CreateDirectory($resolved) | Out-Null }
        $jsonPath = Join-Path $resolved 'v0.2-release-gate.json'
        $textPath = Join-Path $resolved 'gate-report.txt'
    }
    if ((Test-Path -LiteralPath $jsonPath -PathType Leaf) -or (Test-Path -LiteralPath $textPath -PathType Leaf)) {
        throw "Release-gate output already exists; refusing to overwrite: $resolved"
    }
    $utf8 = New-Object Text.UTF8Encoding($false)
    $json = $Report | ConvertTo-Json -Depth 100
    $text = @(
        'HerdrOps v0.2.0 Release Gate',
        "GeneratedUtc: $([DateTime]::UtcNow.ToString('O'))",
        "Result: $($Report.Result)",
        "ReleaseReady: $($Report.ReleaseReady.ToString().ToLowerInvariant())",
        "SourceCommit: $($Report.SourceCommit)",
        "SourceTree: $($Report.SourceTree)",
        "SourceParents: $(@($Report.SourceParents) -join ' ')",
        "PackageReceiptSha256: $($Report.Package.ReceiptSha256)",
        "PackageReceiptFileSha256: $($Report.Package.ReceiptFileSha256)",
        "RendererManifestSha256: $($Report.Renderer.ManifestSha256)",
        "RuntimeMatrixManifestSha256: $($Report.RuntimeMatrix.ManifestFileSha256)",
        "GitHubSnapshotSha256: $($Report.GitHub.SnapshotSha256)",
        '',
        'EvidenceClasses:',
        "Static: $($Report.EvidenceClasses.Static.Status) [$($Report.EvidenceClasses.Static.Classification)]",
        "Contract: $($Report.EvidenceClasses.Contract.Status) [$($Report.EvidenceClasses.Contract.Classification)]",
        "Synthetic: $($Report.EvidenceClasses.Synthetic.Status) [$($Report.EvidenceClasses.Synthetic.Classification)]",
        "Runtime: $($Report.EvidenceClasses.Runtime.Status) [$($Report.EvidenceClasses.Runtime.Classification)]",
        "Human: $($Report.EvidenceClasses.Human.Status) [$($Report.EvidenceClasses.Human.Classification)]",
        "Release: $($Report.EvidenceClasses.Release.Status) [$($Report.EvidenceClasses.Release.Classification)]",
        '',
        'Boundary: no Herdr control, GitHub mutation, package publication, tag, signing, or release publication is performed by this gate.'
    ) -join "`r`n"
    [IO.File]::WriteAllText($jsonPath, $json, $utf8)
    [IO.File]::WriteAllText($textPath, $text + "`r`n", $utf8)
    return [pscustomobject][ordered]@{ JsonPath = $jsonPath; TextPath = $textPath }
}

function Assert-V02ReleaseGateBoundSnapshots {
    param(
        [Parameter(Mandatory = $true)]$Snapshots,
        [Parameter(Mandatory = $true)][string]$Phase
    )

    foreach ($snapshot in @($Snapshots)) {
        Assert-V02ReleaseGateSnapshotUnchanged -Snapshot $snapshot -Context "$Phase '$($snapshot.Path)'" | Out-Null
    }
}

function Invoke-V02ReleaseGate {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$ExpectedSourceCommit,
        [Parameter(Mandatory = $true)][string]$ExpectedSourceTree,
        [Parameter(Mandatory = $true)][string]$PackageIdentityPath,
        [Parameter(Mandatory = $true)][string]$PackageArchivePath,
        [Parameter(Mandatory = $true)][string]$ExtractedPackageRoot,
        [Parameter(Mandatory = $true)][string]$PackageProfilePath,
        [Parameter(Mandatory = $true)][string]$RendererManifestPath,
        [Parameter(Mandatory = $true)][string]$ThaiEvidenceDirectory,
        [Parameter(Mandatory = $true)][string]$EnglishEvidenceDirectory,
        [Parameter(Mandatory = $true)][string]$RuntimeMatrixManifestPath,
        [Parameter(Mandatory = $true)][string]$ContractEvidencePath,
        [Parameter(Mandatory = $true)][string]$SyntheticEvidencePath,
        [Parameter(Mandatory = $true)][string]$HumanReviewPath,
        [Parameter(Mandatory = $true)][string]$GitHubSnapshotPath,
        [string]$CandidateLockPath,
        [string]$AuthorityReferencePath,
        [string]$EvidenceRoot,
        [string]$RepositoryRoot,
        [string]$RendererEvidenceRoot,
        [string]$OutputPath
    )

    Assert-V02ReleaseGateGitObjectId $ExpectedSourceCommit 'ExpectedSourceCommit' | Out-Null
    Assert-V02ReleaseGateGitObjectId $ExpectedSourceTree 'ExpectedSourceTree' | Out-Null
    if ([string]::IsNullOrWhiteSpace($RepositoryRoot)) {
        $RepositoryRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
    }
    $identityBefore = Get-V02ReleaseGateGitIdentity -RepositoryRoot $RepositoryRoot
    Assert-V02ReleaseGateGitIdentity $identityBefore $ExpectedSourceCommit $ExpectedSourceTree 'Preflight'

    if ([string]::IsNullOrWhiteSpace($EvidenceRoot)) {
        $report = New-V02ReleaseGateNotReadyReport -Identity $identityBefore `
            -Reason 'EvidenceRoot is required for path containment and immutable evidence binding.'
        if (-not [string]::IsNullOrWhiteSpace($OutputPath)) {
            $written = Write-V02ReleaseGateReport -Report $report -OutputPath $OutputPath
            $report | Add-Member -MemberType NoteProperty -Name ReportJsonPath -Value $written.JsonPath
            $report | Add-Member -MemberType NoteProperty -Name ReportTextPath -Value $written.TextPath
        }
        return $report
    }
    $evidenceRootPath = Resolve-V02ReleaseGateExistingPath -Path $EvidenceRoot -Type Container -Context 'EvidenceRoot'

    $profilePath = Resolve-V02ReleaseGateExistingPath -Path $PackageProfilePath -Type Leaf -Context 'Package identity profile'
    $expectedProfilePath = [IO.Path]::GetFullPath((Join-Path $identityBefore.RepositoryRoot 'tools\packaging\v0.2\package-identity-profile.json')).TrimEnd([char[]]@('\', '/'))
    if (-not [StringComparer]::OrdinalIgnoreCase.Equals($profilePath, $expectedProfilePath)) {
        throw 'Package identity profile is not the committed v0.2 profile path.'
    }

    $evidenceInputs = @(
        [pscustomobject]@{ Path = $PackageIdentityPath; Type = 'Leaf'; Name = 'Package identity receipt' }
        [pscustomobject]@{ Path = $PackageArchivePath; Type = 'Leaf'; Name = 'Package archive' }
        [pscustomobject]@{ Path = $ExtractedPackageRoot; Type = 'Container'; Name = 'Extracted package root' }
        [pscustomobject]@{ Path = $RendererManifestPath; Type = 'Leaf'; Name = 'Renderer manifest' }
        [pscustomobject]@{ Path = $ThaiEvidenceDirectory; Type = 'Container'; Name = 'Thai evidence directory' }
        [pscustomobject]@{ Path = $EnglishEvidenceDirectory; Type = 'Container'; Name = 'English evidence directory' }
        [pscustomobject]@{ Path = $RuntimeMatrixManifestPath; Type = 'Leaf'; Name = 'Runtime matrix manifest' }
        [pscustomobject]@{ Path = $ContractEvidencePath; Type = 'Leaf'; Name = 'Contract evidence receipt' }
        [pscustomobject]@{ Path = $SyntheticEvidencePath; Type = 'Leaf'; Name = 'Synthetic evidence receipt' }
        [pscustomobject]@{ Path = $HumanReviewPath; Type = 'Leaf'; Name = 'Human review record' }
        [pscustomobject]@{ Path = $GitHubSnapshotPath; Type = 'Leaf'; Name = 'GitHub snapshot' }
    )
    foreach ($input in $evidenceInputs) {
        $resolvedInput = Resolve-V02ReleaseGateExistingPath -Path ([string]$input.Path) -Type $input.Type -Context $input.Name
        Assert-V02ReleaseGatePathWithinRoot -Path $resolvedInput -Root $evidenceRootPath -Context $input.Name | Out-Null
    }
    if (-not [string]::IsNullOrWhiteSpace($RendererEvidenceRoot)) {
        $rendererEvidenceRootPath = Resolve-V02ReleaseGateExistingPath -Path $RendererEvidenceRoot -Type Container -Context 'Renderer evidence root'
        Assert-V02ReleaseGatePathWithinRoot -Path $rendererEvidenceRootPath -Root $evidenceRootPath -Context 'Renderer evidence root' | Out-Null
    }
    else {
        $rendererEvidenceRootPath = $evidenceRootPath
    }

    $authority = $null
    $candidateLock = $null
    try {
        if ([string]::IsNullOrWhiteSpace($AuthorityReferencePath)) {
            throw 'AuthorityReferencePath is required and must identify the trusted committed owner decision.'
        }
        $authority = Read-V02ReleaseGateAuthorityReference -RepositoryRoot $identityBefore.RepositoryRoot `
            -AuthorityReferencePath $AuthorityReferencePath
        if ([string]::IsNullOrWhiteSpace($CandidateLockPath)) {
            throw 'CandidateLockPath is required and must identify an immutable approved candidate lock.'
        }
        $candidateLock = Read-V02ReleaseGateCandidateLock -Path $CandidateLockPath -EvidenceRoot $evidenceRootPath `
            -ExpectedSourceCommit $ExpectedSourceCommit -ExpectedSourceTree $ExpectedSourceTree `
            -PackageProfilePath $profilePath -Authority $authority
    }
    catch {
        $report = New-V02ReleaseGateNotReadyReport -Identity $identityBefore -Reason $_.Exception.Message `
            -CandidateLock $candidateLock -Authority $authority
        if (-not [string]::IsNullOrWhiteSpace($OutputPath)) {
            $written = Write-V02ReleaseGateReport -Report $report -OutputPath $OutputPath
            $report | Add-Member -MemberType NoteProperty -Name ReportJsonPath -Value $written.JsonPath
            $report | Add-Member -MemberType NoteProperty -Name ReportTextPath -Value $written.TextPath
        }
        return $report
    }

    $context = [pscustomobject][ordered]@{
        RepositoryRoot = $identityBefore.RepositoryRoot
        IdentityPath = Resolve-V02ReleaseGateExistingPath -Path $PackageIdentityPath -Type Leaf -Context 'Package identity receipt'
        ArchivePath = Resolve-V02ReleaseGateExistingPath -Path $PackageArchivePath -Type Leaf -Context 'Package ZIP archive'
        PackageRoot = Resolve-V02ReleaseGateExistingPath -Path $ExtractedPackageRoot -Type Container -Context 'Extracted package root'
        ProfilePath = $profilePath
        ManifestPath = Resolve-V02ReleaseGateExistingPath -Path $RendererManifestPath -Type Leaf -Context 'Renderer compatibility manifest'
        EvidenceRoot = $rendererEvidenceRootPath
        ThaiEvidenceDirectory = Resolve-V02ReleaseGateExistingPath -Path $ThaiEvidenceDirectory -Type Container -Context 'Thai evidence directory'
        EnglishEvidenceDirectory = Resolve-V02ReleaseGateExistingPath -Path $EnglishEvidenceDirectory -Type Container -Context 'English evidence directory'
    }

    $packageManifestPath = Resolve-V02ReleaseGateExistingPath -Path (Join-Path $context.PackageRoot 'package-manifest.json') -Type Leaf -Context 'Package manifest'
    $appPath = Resolve-V02ReleaseGateExistingPath -Path (Join-Path $context.PackageRoot 'HerdrOps.App.exe') -Type Leaf -Context 'Package App executable'
    $corePath = Resolve-V02ReleaseGateExistingPath -Path (Join-Path $context.PackageRoot 'HerdrOps.Core.exe') -Type Leaf -Context 'Package Core executable'
    $boundFilePaths = @(
        $context.IdentityPath, $context.ArchivePath, $packageManifestPath, $appPath, $corePath, $context.ProfilePath,
        $context.ManifestPath, (Resolve-V02ReleaseGateExistingPath -Path $RuntimeMatrixManifestPath -Type Leaf -Context 'Runtime matrix manifest'),
        (Resolve-V02ReleaseGateExistingPath -Path $ContractEvidencePath -Type Leaf -Context 'Contract evidence receipt'),
        (Resolve-V02ReleaseGateExistingPath -Path $SyntheticEvidencePath -Type Leaf -Context 'Synthetic evidence receipt'),
        (Resolve-V02ReleaseGateExistingPath -Path $HumanReviewPath -Type Leaf -Context 'Human review record'),
        (Resolve-V02ReleaseGateExistingPath -Path $GitHubSnapshotPath -Type Leaf -Context 'GitHub snapshot'),
        $candidateLock.Path, $authority.Path
    )
    $preValidationSnapshots = @($boundFilePaths | ForEach-Object {
            Get-V02ReleaseGateStableFileSnapshot -Path $_ -Context 'Pre-validation bound artifact'
        })

    $package = Invoke-V02ReleaseGatePackageValidation -Context $context `
        -ExpectedSourceCommit $ExpectedSourceCommit -ExpectedSourceTree $ExpectedSourceTree
    Assert-V02ReleaseGateBoundSnapshots -Snapshots $preValidationSnapshots -Phase 'Post-package validation'
    $renderer = Invoke-V02ReleaseGateRendererValidation -Context $context -Package $package `
        -ExpectedSourceCommit $ExpectedSourceCommit -ExpectedSourceTree $ExpectedSourceTree
    Assert-V02ReleaseGateBoundSnapshots -Snapshots $preValidationSnapshots -Phase 'Post-renderer validation'
    $contract = Read-V02ReleaseGateEvidenceReceipt -Path $ContractEvidencePath -ExpectedClass Contract `
        -ExpectedSourceCommit $ExpectedSourceCommit -ExpectedSourceTree $ExpectedSourceTree -EvidenceRoot $evidenceRootPath
    $synthetic = Read-V02ReleaseGateEvidenceReceipt -Path $SyntheticEvidencePath -ExpectedClass Synthetic `
        -ExpectedSourceCommit $ExpectedSourceCommit -ExpectedSourceTree $ExpectedSourceTree -EvidenceRoot $evidenceRootPath
    $matrix = Invoke-V02ReleaseGateMatrixValidation -Context $context -Package $package `
        -ExpectedSourceCommit $ExpectedSourceCommit -ExpectedSourceTree $ExpectedSourceTree `
        -RuntimeMatrixManifestPath $RuntimeMatrixManifestPath
    Assert-V02ReleaseGateBoundSnapshots -Snapshots $preValidationSnapshots -Phase 'Post-matrix validation'
    try {
        $githubDocument = Read-V02ReleaseGateJsonFile -Path $GitHubSnapshotPath -Context 'GitHub read-only snapshot'
        $githubAssessment = Assert-V02ReleaseGateGitHubSnapshot $githubDocument.Value
        $reviewDocument = Read-V02ReleaseGateJsonFile -Path $HumanReviewPath -Context 'Human review record'
        $humanDisposition = Assert-V02ReleaseGateHumanReview -Review $reviewDocument.Value -ReviewPath $reviewDocument.Path -ExpectedSourceCommit $ExpectedSourceCommit `
            -ExpectedSourceTree $ExpectedSourceTree -Package $package -Renderer $renderer -Matrix $matrix `
            -GitHubSnapshotPath $githubDocument.Path -GitHubSnapshotSha256 $githubDocument.FileSha256 -EvidenceRoot $evidenceRootPath
    }
    catch {
        $report = New-V02ReleaseGateNotReadyReport -Identity $identityBefore `
            -Reason "Unauthenticated Human/GitHub evidence was rejected: $($_.Exception.Message)" `
            -CandidateLock $candidateLock -Authority $authority
        if (-not [string]::IsNullOrWhiteSpace($OutputPath)) {
            $written = Write-V02ReleaseGateReport -Report $report -OutputPath $OutputPath
            $report | Add-Member -MemberType NoteProperty -Name ReportJsonPath -Value $written.JsonPath
            $report | Add-Member -MemberType NoteProperty -Name ReportTextPath -Value $written.TextPath
        }
        return $report
    }
    Assert-V02ReleaseGateBoundSnapshots -Snapshots $preValidationSnapshots -Phase 'Post-evidence validation'

    $identityAfter = Get-V02ReleaseGateGitIdentity -RepositoryRoot $identityBefore.RepositoryRoot
    Assert-V02ReleaseGateGitIdentity $identityAfter $ExpectedSourceCommit $ExpectedSourceTree 'Postflight'
    if ($identityBefore.Commit -cne $identityAfter.Commit -or $identityBefore.Tree -cne $identityAfter.Tree) {
        throw 'Source identity changed during v0.2 release-gate validation.'
    }

    Assert-V02ReleaseGateBoundSnapshots -Snapshots $preValidationSnapshots -Phase 'Final post-validation'

    $report = [pscustomobject][ordered]@{
        SchemaVersion = 2
        Version = $script:V02ReleaseGateVersion
        Result = 'NOT_READY'
        ReleaseReady = $false
        SourceCommit = $ExpectedSourceCommit
        SourceTree = $ExpectedSourceTree
        SourceParents = @($identityAfter.Parents)
        RepositoryRoot = $identityAfter.RepositoryRoot
        CandidateLock = $candidateLock
        AuthorityReference = $authority
        GateReason = 'NO_INDEPENDENT_RUNTIME_HUMAN_RELEASE_RECEIPTS'
        Package = [pscustomobject][ordered]@{
            EvidenceClass = $package.EvidenceClass
            ProfileId = $package.ProfileId
            ReceiptSchemaSha256 = $script:V02ReleaseGatePackageReceiptSchemaSha256
            ReceiptSha256 = $package.ReceiptSha256
            ReceiptFileSha256 = $package.ReceiptFileSha256
            ArchiveSha256 = $package.ArchiveSha256
            ManifestSha256 = $package.ManifestSha256
            AppSha256 = $package.AppSha256
            CoreSha256 = $package.CoreSha256
            ProfileFileSha256 = $package.ProfileFileSha256
            ProfileCanonicalSha256 = $package.ProfileCanonicalSha256
            ReferenceHostProfileSha256 = $package.ReferenceHostProfileSha256
            RendererPolicySha256 = $package.RendererPolicySha256
        }
        Renderer = [pscustomobject][ordered]@{
            EvidenceClass = [string]$renderer.Result.EvidenceClassification
            ManifestPath = $renderer.ManifestPath
            ManifestSha256 = $renderer.ManifestSha256
            BindingValidation = [string]$renderer.Result.BindingValidation
            OwnerNumericLimits = [string]$renderer.Result.OwnerNumericLimits
            HumanReviewInCandidate = [string]$renderer.Result.HumanReview
            CreditGranted = [bool]$renderer.Result.CreditGranted
        }
        RuntimeMatrix = [pscustomobject][ordered]@{
            EvidenceClass = [string]$matrix.Candidate.EvidenceClassification
            ManifestPath = $matrix.ManifestPath
            ManifestFileSha256 = $matrix.ManifestFileSha256
            ManifestPayloadSha256 = $matrix.ManifestPayloadSha256
            IndependentHumanReview = [string]$matrix.Candidate.IndependentHumanReview
            ReleaseCredit = [bool]$matrix.Candidate.ReleaseCredit
            Languages = @('Thai', 'English')
        }
        ContractEvidence = [pscustomobject][ordered]@{
            Path = $contract.Path
            FileSha256 = $contract.FileSha256
            CheckCount = $contract.CheckCount
        }
        SyntheticEvidence = [pscustomobject][ordered]@{
            Path = $synthetic.Path
            FileSha256 = $synthetic.FileSha256
            CheckCount = $synthetic.CheckCount
        }
        GitHub = [pscustomobject][ordered]@{
            Status = [string]$githubAssessment.Status
            Authenticated = [bool]$githubAssessment.Authenticated
            SnapshotPath = $githubDocument.Path
            SnapshotSha256 = $githubDocument.FileSha256
            MilestoneNumber = $githubAssessment.MilestoneNumber
            MilestoneState = $githubAssessment.MilestoneState
            TrackerIssue = $githubAssessment.TrackerIssue
            OpenV02IssueCount = $githubAssessment.OpenV02IssueCount
        }
        HumanReview = [pscustomobject][ordered]@{
            Status = [string]$humanDisposition.Status
            Authenticated = [bool]$humanDisposition.Authenticated
            EvidenceClass = 'Human'
            ReviewerIdentity = [string]$reviewDocument.Value.Reviewer.Identity
            ReviewerRole = [string]$reviewDocument.Value.Reviewer.Role
            ReviewFileSha256 = $reviewDocument.FileSha256
            Decision = [string]$humanDisposition.Decision
            RoleDistinct = [bool]$reviewDocument.Value.Reviewer.RoleDistinct
            OpenFindingCount = @($reviewDocument.Value.OpenFindings).Count
        }
        EvidenceClasses = [pscustomobject][ordered]@{
            Static = [pscustomobject][ordered]@{ Status = 'PASS'; Classification = 'Static/PackagedCompatibilityPreparation'; Credit = 'PREPARATION_ONLY' }
            Contract = [pscustomobject][ordered]@{ Status = 'PASS'; Classification = 'Contract'; Credit = 'CONTRACT_ONLY' }
            Synthetic = [pscustomobject][ordered]@{ Status = 'PASS'; Classification = 'Synthetic'; Credit = 'SYNTHETIC_ONLY' }
            Runtime = [pscustomobject][ordered]@{ Status = 'NOT_OBSERVED'; Classification = 'RuntimeMatrixCandidate'; Credit = 'CANDIDATE_ONLY' }
            Human = [pscustomobject][ordered]@{ Status = 'NOT_OBSERVED'; Classification = 'Human'; Credit = 'UNAUTHENTICATED_LOCAL_RECORD' }
            Release = [pscustomobject][ordered]@{ Status = 'NOT_OBSERVED'; Classification = 'Release'; Credit = 'NONE' }
        }
        EvidenceBoundary = [pscustomobject][ordered]@{
            ActualHerdrControlInvoked = $false
            GitHubMutationInvoked = $false
            PackagePublished = $false
            ReleasePublished = $false
            RuntimeMatrixRemainsCandidate = $true
            RuntimeObserved = $false
            HumanAuthorityObserved = $false
            ReleaseCreditBoundToExactCandidate = $false
        }
    }
    if (-not [string]::IsNullOrWhiteSpace($OutputPath)) {
        $written = Write-V02ReleaseGateReport -Report $report -OutputPath $OutputPath
        $report | Add-Member -MemberType NoteProperty -Name ReportJsonPath -Value $written.JsonPath
        $report | Add-Member -MemberType NoteProperty -Name ReportTextPath -Value $written.TextPath
    }
    return $report
}

# Dot-sourcing imports the functions for read-only selftests without invoking
# the production gate. Direct execution is the only path that runs the gate.
if ($MyInvocation.InvocationName -ne '.') {
    Invoke-V02ReleaseGate `
        -ExpectedSourceCommit $ExpectedSourceCommit `
        -ExpectedSourceTree $ExpectedSourceTree `
        -PackageIdentityPath $PackageIdentityPath `
        -PackageArchivePath $PackageArchivePath `
        -ExtractedPackageRoot $ExtractedPackageRoot `
        -PackageProfilePath $PackageProfilePath `
        -RendererManifestPath $RendererManifestPath `
        -ThaiEvidenceDirectory $ThaiEvidenceDirectory `
        -EnglishEvidenceDirectory $EnglishEvidenceDirectory `
        -RuntimeMatrixManifestPath $RuntimeMatrixManifestPath `
        -ContractEvidencePath $ContractEvidencePath `
        -SyntheticEvidencePath $SyntheticEvidencePath `
        -HumanReviewPath $HumanReviewPath `
        -GitHubSnapshotPath $GitHubSnapshotPath `
        -CandidateLockPath $CandidateLockPath `
        -AuthorityReferencePath $AuthorityReferencePath `
        -EvidenceRoot $EvidenceRoot `
        -RepositoryRoot $RepositoryRoot `
        -RendererEvidenceRoot $RendererEvidenceRoot `
        -OutputPath $OutputPath | Out-Host
}
