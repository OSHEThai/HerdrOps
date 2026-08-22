#requires -Version 5.1

Set-StrictMode -Version Latest

. (Join-Path $PSScriptRoot '..\Packaging.Common.ps1')

$script:V02PackageIdentityProfileFileName = 'package-identity-profile.json'
$script:V02PackageIdentityReceiptSchemaSha256 = '8C7EF64ED06C94C6589D73C0AB47EB60B7EEF7BFE337F126D8D9D3F0CC0F4C4B'
$script:V02PackageIdentityAfterSourcePreflightForTest = $null
$script:V02PackageVerifierMaximumArchiveBytes = [int64]536870912
$script:V02PackageVerifierMaximumEntryCount = [int64]4096
$script:V02PackageVerifierMaximumExpandedBytes = [int64]1073741824
$script:V02PackageVerifierMaximumCompressionRatio = [decimal]1000

function Get-V02PackageVerifierSecurityBounds {
    return [pscustomobject][ordered]@{
        MaximumArchiveBytes = [int64]$script:V02PackageVerifierMaximumArchiveBytes
        MaximumEntryCount = [int64]$script:V02PackageVerifierMaximumEntryCount
        MaximumExpandedBytes = [int64]$script:V02PackageVerifierMaximumExpandedBytes
        MaximumCompressionRatio = [decimal]$script:V02PackageVerifierMaximumCompressionRatio
    }
}

function Resolve-V02ArchiveSecurityBounds {
    param(
        [Parameter(Mandatory = $true)][int64]$MaximumArchiveBytes,
        [Parameter(Mandatory = $true)][int64]$MaximumEntryCount,
        [Parameter(Mandatory = $true)][int64]$MaximumExpandedBytes,
        [Parameter(Mandatory = $true)][decimal]$MaximumCompressionRatio
    )

    $defaults = Get-V02PackageVerifierSecurityBounds
    if ($MaximumArchiveBytes -lt 1 -or $MaximumArchiveBytes -gt $defaults.MaximumArchiveBytes) {
        throw "MaximumArchiveBytes must be between 1 and $($defaults.MaximumArchiveBytes); weaker bounds are rejected."
    }
    if ($MaximumEntryCount -lt 1 -or $MaximumEntryCount -gt $defaults.MaximumEntryCount) {
        throw "MaximumEntryCount must be between 1 and $($defaults.MaximumEntryCount); weaker bounds are rejected."
    }
    if ($MaximumExpandedBytes -lt 1 -or $MaximumExpandedBytes -gt $defaults.MaximumExpandedBytes) {
        throw "MaximumExpandedBytes must be between 1 and $($defaults.MaximumExpandedBytes); weaker bounds are rejected."
    }
    if ($MaximumCompressionRatio -lt 1 -or $MaximumCompressionRatio -gt $defaults.MaximumCompressionRatio) {
        throw "MaximumCompressionRatio must be between 1 and $($defaults.MaximumCompressionRatio); weaker bounds are rejected."
    }
    return [pscustomobject][ordered]@{
        MaximumArchiveBytes = [int64]$MaximumArchiveBytes
        MaximumEntryCount = [int64]$MaximumEntryCount
        MaximumExpandedBytes = [int64]$MaximumExpandedBytes
        MaximumCompressionRatio = [decimal]$MaximumCompressionRatio
    }
}

function Assert-V02ExactProperties {
    param(
        [Parameter(Mandatory = $true)]$Object,
        [Parameter(Mandatory = $true)][string[]]$Names,
        [Parameter(Mandatory = $true)][string]$Description
    )

    if ($null -eq $Object -or $Object -isnot [psobject]) {
        throw "$Description must be a JSON object."
    }

    $actual = @($Object.PSObject.Properties | ForEach-Object { $_.Name })
    if ($actual.Count -ne $Names.Count) {
        throw "$Description must contain exactly: $($Names -join ', ')."
    }
    foreach ($name in $Names) {
        $matches = @($Object.PSObject.Properties | Where-Object {
                [StringComparer]::Ordinal.Equals([string]$_.Name, $name)
            })
        if ($matches.Count -ne 1) {
            throw "$Description must contain exactly one case-sensitive '$name' property."
        }
    }
}

function Assert-V02NativeString {
    param($Value, [string]$Description)

    if ($Value -isnot [string] -or [string]::IsNullOrWhiteSpace($Value)) {
        throw "$Description must be a nonblank native JSON string."
    }
}

function Assert-V02NativeBoolean {
    param($Value, [string]$Description)

    if ($Value -isnot [bool]) {
        throw "$Description must be a native JSON boolean."
    }
}

function Assert-V02NativeInteger {
    param($Value, [string]$Description, [int64]$Minimum = 0)

    if ($Value -isnot [byte] -and $Value -isnot [sbyte] -and
        $Value -isnot [int16] -and $Value -isnot [uint16] -and
        $Value -isnot [int32] -and $Value -isnot [uint32] -and
        $Value -isnot [int64] -and $Value -isnot [uint64]) {
        throw "$Description must be a native JSON integer."
    }
    if ([decimal]$Value -lt [decimal]$Minimum) {
        throw "$Description must be at least $Minimum."
    }
}

function Assert-V02ExactString {
    param($Value, [string]$Expected, [string]$Description)

    Assert-V02NativeString -Value $Value -Description $Description
    if (-not [StringComparer]::Ordinal.Equals([string]$Value, $Expected)) {
        throw "$Description must be exactly '$Expected'."
    }
}

function Assert-V02Sha256 {
    param($Value, [string]$Description)

    Assert-V02NativeString -Value $Value -Description $Description
    if ([string]$Value -cnotmatch '^[0-9A-F]{64}$') {
        throw "$Description must be an uppercase 64-hex SHA-256."
    }
}

function Assert-V02GitObjectId {
    param($Value, [string]$Description)

    Assert-V02NativeString -Value $Value -Description $Description
    if ([string]$Value -cnotmatch '^[0-9a-f]{40}$') {
        throw "$Description must be a lowercase 40-hex Git object ID."
    }
}

function Read-V02PackageIdentityJson {
    param([Parameter(Mandatory = $true)][string]$Path, [string]$Description = 'v0.2 package identity JSON')

    $fullPath = [IO.Path]::GetFullPath($Path)
    if (-not (Test-Path -LiteralPath $fullPath -PathType Leaf)) {
        throw "$Description was not found: $fullPath"
    }
    $bytes = [IO.File]::ReadAllBytes($fullPath)
    if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) {
        throw "$Description must be UTF-8 without a BOM."
    }
    $utf8 = New-Object Text.UTF8Encoding($false, $true)
    try {
        $json = $utf8.GetString($bytes)
    } catch {
        throw "$Description is not strict UTF-8: $($_.Exception.Message)"
    }
    return ConvertFrom-V02StrictJsonText -Json $json -Description $Description
}

function ConvertFrom-V02StrictJsonText {
    param([Parameter(Mandatory = $true)][string]$Json,[Parameter(Mandatory = $true)][string]$Description)
    Assert-NoDuplicateJsonObjectProperties -Json $Json -Description $Description
    try {
        $command=Get-Command ConvertFrom-Json -CommandType Cmdlet
        if($command.Parameters.ContainsKey('DateKind')){return ($Json|ConvertFrom-Json -DateKind String)}
        return ($Json|ConvertFrom-Json)
    } catch { throw "$Description is not valid JSON: $($_.Exception.Message)" }
}

function Assert-V02PackageIdentityProfile {
    param([Parameter(Mandatory = $true)]$Profile)

    Assert-V02ExactProperties $Profile @(
        'schemaVersion', 'profileId', 'issue', 'packageVersion', 'runtimeIdentifier',
        'archiveFileName', 'packageManifestFileName', 'sourcePolicy', 'approval', 'components',
        'referenceHost', 'renderer', 'evidenceBoundary'
    ) 'v0.2 package identity profile'
    Assert-V02NativeInteger $Profile.schemaVersion 'profile.schemaVersion' 1
    if ([int64]$Profile.schemaVersion -ne 1) { throw 'profile.schemaVersion must be exactly 1.' }
    Assert-V02ExactString $Profile.profileId 'herdrops-v0.2-package-software-only-issue-149' 'profile.profileId'
    Assert-V02NativeInteger $Profile.issue 'profile.issue' 1
    if ([int64]$Profile.issue -ne 149) { throw 'profile.issue must be exactly 149.' }
    Assert-V02ExactString $Profile.packageVersion '0.2.0' 'profile.packageVersion'
    Assert-V02ExactString $Profile.runtimeIdentifier 'win-x64' 'profile.runtimeIdentifier'
    Assert-V02ExactString $Profile.archiveFileName 'HerdrOps-0.2.0-win-x64.zip' 'profile.archiveFileName'
    Assert-V02ExactString $Profile.packageManifestFileName 'package-manifest.json' 'profile.packageManifestFileName'
    Assert-V02ExactProperties $Profile.sourcePolicy @('cleanRequired') 'profile.sourcePolicy'
    Assert-V02NativeBoolean $Profile.sourcePolicy.cleanRequired 'profile.sourcePolicy.cleanRequired'
    if ($Profile.sourcePolicy.cleanRequired -ne $true) { throw 'profile.sourcePolicy.cleanRequired must be true.' }
    Assert-V02ExactProperties $Profile.approval @('decisionId', 'approvalReference', 'approvedUtc', 'payloadSha256') 'profile.approval'
    Assert-V02ExactString $Profile.approval.decisionId 'herdrops-rec-all-v2' 'profile.approval.decisionId'
    Assert-V02ExactString $Profile.approval.approvalReference 'https://github.com/OSHEThai/HerdrOps/issues/149#issuecomment-5380637664' 'profile.approval.approvalReference'
    Assert-V02ExactString $Profile.approval.approvedUtc '2026-08-22T13:18:21.2468994Z' 'profile.approval.approvedUtc'
    Assert-V02ExactString $Profile.approval.payloadSha256 '48474610D2A20EE2F7CA2DAC0A3CCF45F919440C9C5D81EF5BA93AD7E524F62D' 'profile.approval.payloadSha256'

    Assert-V02ExactProperties $Profile.components @('appRelativePath', 'coreRelativePath') 'profile.components'
    Assert-V02ExactString $Profile.components.appRelativePath 'HerdrOps.App.exe' 'profile.components.appRelativePath'
    Assert-V02ExactString $Profile.components.coreRelativePath 'HerdrOps.Core.exe' 'profile.components.coreRelativePath'

    Assert-V02ExactProperties $Profile.referenceHost @('profileId', 'profileSha256') 'profile.referenceHost'
    Assert-V02ExactString $Profile.referenceHost.profileId 'herdrops-v0.2-submark-nb-software-only-20260822' 'profile.referenceHost.profileId'
    Assert-V02ExactString $Profile.referenceHost.profileSha256 '96D01ED15A536F2DF50B59B43CFDEB3683DCE8667AE2E7BF6A96124182FE13A3' 'profile.referenceHost.profileSha256'

    Assert-V02ExactProperties $Profile.renderer @('policy', 'wpfProcessRenderMode', 'policySha256') 'profile.renderer'
    Assert-V02ExactString $Profile.renderer.policy 'software-only-process-wide' 'profile.renderer.policy'
    Assert-V02ExactString $Profile.renderer.wpfProcessRenderMode 'SoftwareOnly' 'profile.renderer.wpfProcessRenderMode'
    Assert-V02ExactString $Profile.renderer.policySha256 '1D37C9C39449556EB30F9AB5B734F0C5411CF4203321AF0B238993D017229E92' 'profile.renderer.policySha256'

    Assert-V02ExactProperties $Profile.evidenceBoundary @(
        'evidenceClass', 'runtimeUse', 'actualHerdrUsed', 'runtimeCredit', 'releaseCredit'
    ) 'profile.evidenceBoundary'
    Assert-V02ExactString $Profile.evidenceBoundary.evidenceClass 'PackagedCompatibilityPreparation' 'profile.evidenceBoundary.evidenceClass'
    Assert-V02ExactString $Profile.evidenceBoundary.runtimeUse 'not-used' 'profile.evidenceBoundary.runtimeUse'
    Assert-V02NativeBoolean $Profile.evidenceBoundary.actualHerdrUsed 'profile.evidenceBoundary.actualHerdrUsed'
    if ($Profile.evidenceBoundary.actualHerdrUsed -ne $false) { throw 'profile.evidenceBoundary.actualHerdrUsed must be false.' }
    Assert-V02ExactString $Profile.evidenceBoundary.runtimeCredit 'NOT CLAIMED' 'profile.evidenceBoundary.runtimeCredit'
    Assert-V02ExactString $Profile.evidenceBoundary.releaseCredit 'NOT CLAIMED' 'profile.evidenceBoundary.releaseCredit'
}

function Read-V02PackageIdentityProfile {
    param([string]$Path = (Join-Path $PSScriptRoot $script:V02PackageIdentityProfileFileName))

    $profile = Read-V02PackageIdentityJson -Path $Path -Description 'v0.2 package identity profile'
    Assert-V02PackageIdentityProfile -Profile $profile
    return $profile
}

function Get-V02StableFileIdentity {
    param([Parameter(Mandatory = $true)][string]$Path, [switch]$IncludeBytes)

    $fullPath = [IO.Path]::GetFullPath($Path)
    if (-not (Test-Path -LiteralPath $fullPath -PathType Leaf)) { throw "Stable file was not found: $fullPath" }
    Assert-NoReparsePath -Path $fullPath
    $before = Get-Item -LiteralPath $fullPath -Force
    $beforeLength = [int64]$before.Length
    $beforeWrite = $before.LastWriteTimeUtc.Ticks
    $stream = $null
    $sha = $null
    try {
        $stream = [IO.File]::Open($fullPath, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::None)
        if ([int64]$stream.Length -ne $beforeLength) { throw "Stable file length changed before hashing: $fullPath" }
        $sha = [Security.Cryptography.SHA256]::Create()
        $hash = ([BitConverter]::ToString($sha.ComputeHash($stream))).Replace('-', '')
        $bytes = $null
        if ($IncludeBytes) {
            $stream.Position = 0
            $bytes = New-Object byte[] $stream.Length
            $offset = 0
            while ($offset -lt $bytes.Length) {
                $read = $stream.Read($bytes, $offset, $bytes.Length - $offset)
                if ($read -le 0) { throw "Stable file ended while reading bytes: $fullPath" }
                $offset += $read
            }
        }
    } finally {
        if ($null -ne $sha) { $sha.Dispose() }
        if ($null -ne $stream) { $stream.Dispose() }
    }
    $after = Get-Item -LiteralPath $fullPath -Force
    if ([int64]$after.Length -ne $beforeLength -or $after.LastWriteTimeUtc.Ticks -ne $beforeWrite) {
        throw "Stable file identity changed during hashing: $fullPath"
    }
    return [pscustomobject][ordered]@{
        Path = $fullPath
        Length = $beforeLength
        LastWriteTimeUtcTicks = [int64]$beforeWrite
        Sha256 = $hash
        Bytes = $bytes
    }
}

function Assert-V02GovernedReferenceHost {
    param([Parameter(Mandatory = $true)][string]$RepositoryRoot)

    $root = [IO.Path]::GetFullPath($RepositoryRoot)
    $profilePath = [IO.Path]::GetFullPath((Join-Path $root 'Plan\reference-hosts\v0.2.json'))
    $schemaPath = [IO.Path]::GetFullPath((Join-Path $root 'Plan\reference-hosts\reference-host-profile.schema.json'))
    $helperPath = [IO.Path]::GetFullPath((Join-Path $root 'tools\lib\V02ReferenceHostProfile.ps1'))
    foreach ($required in @($profilePath, $schemaPath, $helperPath)) {
        if (-not (Test-Path -LiteralPath $required -PathType Leaf)) { throw "Governed reference-host authority file is missing: $required" }
    }
    $profileBefore = Get-V02StableFileIdentity -Path $profilePath
    $schemaBefore = Get-V02StableFileIdentity -Path $schemaPath
    $validation = & {
        param($ValidatorPath, $ProfileFile, $SchemaFile)
        . $ValidatorPath
        Assert-V02ReferenceHostProfile -ProfilePath $ProfileFile -SchemaPath $SchemaFile
    } $helperPath $profilePath $schemaPath
    if ([string]$validation.Profile.profileId -cne 'herdrops-v0.2-submark-nb-software-only-20260822' -or
        [string]$validation.Sha256 -cne '96D01ED15A536F2DF50B59B43CFDEB3683DCE8667AE2E7BF6A96124182FE13A3' -or
        [string]$validation.Profile.candidatePolicy.renderer.policy -cne 'software-only-process-wide' -or
        [string]$validation.Profile.candidatePolicy.renderer.wpfProcessRenderMode -cne 'SoftwareOnly') {
        throw 'Governed reference-host profile identity or renderer policy drifted.'
    }
    $profileAfter = Get-V02StableFileIdentity -Path $profilePath
    $schemaAfter = Get-V02StableFileIdentity -Path $schemaPath
    if ($profileBefore.Sha256 -cne $profileAfter.Sha256 -or $profileBefore.Length -ne $profileAfter.Length -or
        $schemaBefore.Sha256 -cne $schemaAfter.Sha256 -or $schemaBefore.Length -ne $schemaAfter.Length) {
        throw 'Governed reference-host profile/schema changed during validation.'
    }
    return $validation
}

function Get-V02CanonicalInventoryText {
    param([Parameter(Mandatory = $true)]$Entries)
    return Get-CanonicalPackageContentText -Entries $Entries
}

function Get-V02PackageRootInventoryPass {
    param([Parameter(Mandatory = $true)][string]$PackageRoot, [string[]]$ExcludeRelativePath = @())

    $root = [IO.Path]::GetFullPath($PackageRoot)
    if (-not (Test-Path -LiteralPath $root -PathType Container)) { throw "Package root was not found: $root" }
    Assert-NoReparsePath -Path $root
    $entries = @()
    foreach ($item in @(Get-ChildItem -LiteralPath $root -Recurse -Force | Sort-Object FullName)) {
        if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw "Package root contains a reparse point: $($item.FullName)" }
        if ($item.PSIsContainer) { continue }
        $relative = Get-SafeRelativePath -RootPath $root -Path $item.FullName
        if (@($ExcludeRelativePath | Where-Object { [StringComparer]::OrdinalIgnoreCase.Equals($_, $relative) }).Count -gt 0) { continue }
        $stable = Get-V02StableFileIdentity -Path $item.FullName
        $entries += [pscustomobject][ordered]@{ Path = $relative; Length = [int64]$stable.Length; Sha256 = [string]$stable.Sha256 }
    }
    return @(Sort-PackageEntriesOrdinal -Entries $entries)
}

function Get-V02PackageRootInventory {
    param([Parameter(Mandatory = $true)][string]$PackageRoot, [string[]]$ExcludeRelativePath = @())

    $first = @(Get-V02PackageRootInventoryPass -PackageRoot $PackageRoot -ExcludeRelativePath $ExcludeRelativePath)
    $second = @(Get-V02PackageRootInventoryPass -PackageRoot $PackageRoot -ExcludeRelativePath $ExcludeRelativePath)
    $firstText = Get-V02CanonicalInventoryText $first
    $secondText = Get-V02CanonicalInventoryText $second
    if ($firstText -cne $secondText) { throw 'Package root inventory changed during its stable double scan.' }
    return [pscustomobject][ordered]@{
        Entries = $second
        FileCount = $second.Count
        TotalBytes = [int64](($second | Measure-Object Length -Sum).Sum)
        ContentSha256 = Get-Sha256ForText -Text $secondText
    }
}

function ConvertTo-V02CanonicalJson {
    param([Parameter(Mandatory = $true)]$Value, [Parameter(Mandatory = $true)][string]$RepositoryRoot)

    $validatorPath = Join-Path ([IO.Path]::GetFullPath($RepositoryRoot)) 'tools\lib\V02ReferenceHostProfile.ps1'
    return & { param($Path, $InputValue); . $Path; ConvertTo-V02Jcs $InputValue } $validatorPath $Value
}

function New-V02PackageManifestObject {
    param([Parameter(Mandatory = $true)]$Profile, [Parameter(Mandatory = $true)][string]$RepositoryRoot, [Parameter(Mandatory = $true)][string]$PackageRoot)

    $git = Get-V02GitIdentity -RepositoryRoot $RepositoryRoot -RequireClean
    $inventory = Get-V02PackageRootInventory -PackageRoot $PackageRoot -ExcludeRelativePath @([string]$Profile.packageManifestFileName)
    $files = @($inventory.Entries | ForEach-Object { [pscustomobject][ordered]@{ path = $_.Path; length = [int64]$_.Length; sha256 = $_.Sha256 } })
    return [pscustomobject][ordered]@{
        schemaVersion = 1
        profileId = [string]$Profile.profileId
        issue = 149
        packageVersion = '0.2.0'
        runtimeIdentifier = 'win-x64'
        source = [pscustomobject][ordered]@{ commitSha = $git.CommitSha; treeSha = $git.TreeSha }
        referenceHost = [pscustomobject][ordered]@{ profileId = $Profile.referenceHost.profileId; profileSha256 = $Profile.referenceHost.profileSha256 }
        renderer = [pscustomobject][ordered]@{ policy = $Profile.renderer.policy; wpfProcessRenderMode = $Profile.renderer.wpfProcessRenderMode; policySha256 = $Profile.renderer.policySha256 }
        fileCount = [int]$inventory.FileCount
        totalBytes = [int64]$inventory.TotalBytes
        contentSha256 = [string]$inventory.ContentSha256
        files = $files
        evidenceClass = 'Static/PackagedCompatibilityPreparation'
    }
}

function Get-V02GitIdentity {
    param([Parameter(Mandatory = $true)][string]$RepositoryRoot, [switch]$RequireClean)

    $root = [IO.Path]::GetFullPath($RepositoryRoot)
    $commit = @(& git -C $root rev-parse HEAD 2>&1)
    $commitExit = $LASTEXITCODE
    $global:LASTEXITCODE = 0
    if ($commitExit -ne 0 -or $commit.Count -ne 1) { throw 'Unable to resolve the repository HEAD commit.' }
    $tree = @(& git -C $root rev-parse 'HEAD^{tree}' 2>&1)
    $treeExit = $LASTEXITCODE
    $global:LASTEXITCODE = 0
    if ($treeExit -ne 0 -or $tree.Count -ne 1) { throw 'Unable to resolve the repository HEAD tree.' }
    if ($RequireClean) {
        $status = @(& git -C $root status --porcelain=v1 --untracked-files=all 2>&1)
        $statusExit = $LASTEXITCODE
        $global:LASTEXITCODE = 0
        if ($statusExit -ne 0) { throw 'Unable to determine whether the source repository is clean.' }
        if ($status.Count -ne 0) { throw 'Production package identity requires a completely clean source repository, including no untracked files.' }
    }
    return [pscustomobject][ordered]@{ CommitSha = [string]$commit[0]; TreeSha = [string]$tree[0] }
}

function ConvertFrom-V02StrictBytes {
    param([Parameter(Mandatory = $true)][byte[]]$Bytes, [Parameter(Mandatory = $true)][string]$Description)

    if ($Bytes.Length -ge 3 -and $Bytes[0] -eq 0xEF -and $Bytes[1] -eq 0xBB -and $Bytes[2] -eq 0xBF) { throw "$Description must not contain a UTF-8 BOM." }
    try { $json = (New-Object Text.UTF8Encoding($false, $true)).GetString($Bytes) } catch { throw "$Description is not strict UTF-8." }
    return [pscustomobject][ordered]@{ Json = $json; Value = (ConvertFrom-V02StrictJsonText -Json $json -Description $Description) }
}

function Write-V02CanonicalJsonFile {
    param([Parameter(Mandatory = $true)]$Value, [Parameter(Mandatory = $true)][string]$Path, [Parameter(Mandatory = $true)][string]$RepositoryRoot)
    $json = ConvertTo-V02CanonicalJson -Value $Value -RepositoryRoot $RepositoryRoot
    [IO.File]::WriteAllText([IO.Path]::GetFullPath($Path), ($json + "`n"), (New-Object Text.UTF8Encoding($false)))
}

function Assert-V02InventoryEqual {
    param($Expected, $Actual, [string]$Description)
    $expectedText = Get-V02CanonicalInventoryText @($Expected)
    $actualText = Get-V02CanonicalInventoryText @($Actual)
    if ($expectedText -cne $actualText) { throw "$Description inventories are not exact and coherent." }
}

function Read-V02PackageManifest {
    param([Parameter(Mandatory = $true)][string]$Path, [Parameter(Mandatory = $true)]$Profile, [Parameter(Mandatory = $true)][string]$RepositoryRoot)

    $stable = Get-V02StableFileIdentity -Path $Path -IncludeBytes
    $document = ConvertFrom-V02StrictBytes -Bytes $stable.Bytes -Description 'v0.2 canonical package manifest'
    $canonical = ConvertTo-V02CanonicalJson -Value $document.Value -RepositoryRoot $RepositoryRoot
    if ($document.Json -cne ($canonical + "`n")) { throw 'Package manifest JSON is not exact JCS plus one LF.' }
    $m = $document.Value
    Assert-V02ExactProperties $m @('schemaVersion','profileId','issue','packageVersion','runtimeIdentifier','source','referenceHost','renderer','fileCount','totalBytes','contentSha256','files','evidenceClass') 'package manifest'
    Assert-V02NativeInteger $m.schemaVersion 'manifest.schemaVersion' 1; if ([int64]$m.schemaVersion -ne 1) { throw 'manifest.schemaVersion must equal 1.' }
    Assert-V02ExactString $m.profileId $Profile.profileId 'manifest.profileId'
    Assert-V02NativeInteger $m.issue 'manifest.issue' 1; if ([int64]$m.issue -ne 149) { throw 'manifest.issue must equal 149.' }
    Assert-V02ExactString $m.packageVersion '0.2.0' 'manifest.packageVersion'
    Assert-V02ExactString $m.runtimeIdentifier 'win-x64' 'manifest.runtimeIdentifier'
    Assert-V02ExactProperties $m.source @('commitSha','treeSha') 'manifest.source'; Assert-V02GitObjectId $m.source.commitSha 'manifest.source.commitSha'; Assert-V02GitObjectId $m.source.treeSha 'manifest.source.treeSha'
    Assert-V02ExactProperties $m.referenceHost @('profileId','profileSha256') 'manifest.referenceHost'; Assert-V02ExactString $m.referenceHost.profileId $Profile.referenceHost.profileId 'manifest.referenceHost.profileId'; Assert-V02ExactString $m.referenceHost.profileSha256 $Profile.referenceHost.profileSha256 'manifest.referenceHost.profileSha256'
    Assert-V02ExactProperties $m.renderer @('policy','wpfProcessRenderMode','policySha256') 'manifest.renderer'; Assert-V02ExactString $m.renderer.policy $Profile.renderer.policy 'manifest.renderer.policy'; Assert-V02ExactString $m.renderer.wpfProcessRenderMode $Profile.renderer.wpfProcessRenderMode 'manifest.renderer.wpfProcessRenderMode'; Assert-V02ExactString $m.renderer.policySha256 $Profile.renderer.policySha256 'manifest.renderer.policySha256'
    Assert-V02NativeInteger $m.fileCount 'manifest.fileCount' 1; Assert-V02NativeInteger $m.totalBytes 'manifest.totalBytes' 1; Assert-V02Sha256 $m.contentSha256 'manifest.contentSha256'
    Assert-V02ExactString $m.evidenceClass 'Static/PackagedCompatibilityPreparation' 'manifest.evidenceClass'
    $files = @($m.files)
    if ($files.Count -ne [int64]$m.fileCount) { throw 'Manifest fileCount does not equal its files array.' }
    $entries = @()
    $seen = @()
    foreach ($file in $files) {
        Assert-V02ExactProperties $file @('path','length','sha256') 'manifest file entry'
        Assert-V02NativeString $file.path 'manifest file path'; Assert-V02NativeInteger $file.length 'manifest file length' 1; Assert-V02Sha256 $file.sha256 'manifest file SHA-256'
        if ($file.path -match '(^/|\\|(^|/)\.\.(/|$)|/$)') { throw 'Manifest contains an unsafe file path.' }
        if (@($seen | Where-Object { [StringComparer]::OrdinalIgnoreCase.Equals($_, [string]$file.path) }).Count) { throw 'Manifest contains a duplicate file path.' }
        $seen += [string]$file.path
        $entries += [pscustomobject][ordered]@{ Path = [string]$file.path; Length = [int64]$file.length; Sha256 = [string]$file.sha256 }
    }
    $entries = @(Sort-PackageEntriesOrdinal $entries)
    $total = [int64](($entries | Measure-Object Length -Sum).Sum)
    if ($total -ne [int64]$m.totalBytes -or (Get-Sha256ForText (Get-V02CanonicalInventoryText $entries)) -cne [string]$m.contentSha256) { throw 'Manifest inventory aggregate is not internally coherent.' }
    return [pscustomobject][ordered]@{ Manifest = $m; Entries = $entries; Stable = $stable; CanonicalJson = $canonical }
}

function Get-V02ArchiveInventory {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [int64]$MaximumArchiveBytes = [int64]$script:V02PackageVerifierMaximumArchiveBytes,
        [int64]$MaximumEntryCount = [int64]$script:V02PackageVerifierMaximumEntryCount,
        [int64]$MaximumExpandedBytes = [int64]$script:V02PackageVerifierMaximumExpandedBytes,
        [decimal]$MaximumCompressionRatio = [decimal]$script:V02PackageVerifierMaximumCompressionRatio
    )

    Add-Type -AssemblyName System.IO.Compression
    $bounds = Resolve-V02ArchiveSecurityBounds `
        -MaximumArchiveBytes $MaximumArchiveBytes `
        -MaximumEntryCount $MaximumEntryCount `
        -MaximumExpandedBytes $MaximumExpandedBytes `
        -MaximumCompressionRatio $MaximumCompressionRatio
    $fullPath = [IO.Path]::GetFullPath($Path); Assert-NoReparsePath $fullPath
    $before = Get-Item -LiteralPath $fullPath -Force
    if ($before.PSIsContainer) { throw 'Archive path must be a regular file.' }
    if ([int64]$before.Length -gt $bounds.MaximumArchiveBytes) {
        throw "Archive exceeds the maximum allowed byte size of $($bounds.MaximumArchiveBytes)."
    }
    $stream = $null; $zip = $null; $sha = $null
    try {
        $stream = [IO.File]::Open($fullPath,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::None)
        if ([int64]$stream.Length -ne [int64]$before.Length) { throw 'Archive changed before stable inspection.' }
        if ([int64]$stream.Length -gt $bounds.MaximumArchiveBytes) { throw "Archive exceeds the maximum allowed byte size of $($bounds.MaximumArchiveBytes)." }
        $sha = [Security.Cryptography.SHA256]::Create(); $archiveHash = ([BitConverter]::ToString($sha.ComputeHash($stream))).Replace('-',''); $stream.Position = 0
        $zip = New-Object IO.Compression.ZipArchive($stream,[IO.Compression.ZipArchiveMode]::Read,$true)
        if ([int64]$zip.Entries.Count -gt $bounds.MaximumEntryCount) {
            throw "Archive contains more than the maximum allowed entry count of $($bounds.MaximumEntryCount)."
        }
        $entries = @(); $seen = @(); $entryCount = [int64]0; $expandedBytes = [int64]0; $compressedBytes = [int64]0
        foreach ($entry in $zip.Entries) {
            $entryCount++
            if ($entryCount -gt $bounds.MaximumEntryCount) { throw "Archive contains more than the maximum allowed entry count of $($bounds.MaximumEntryCount)." }
            $name = [string]$entry.FullName
            if ([string]::IsNullOrWhiteSpace($name) -or $name -match '(^/|\\|(^|/)\.\.(/|$)|/$)') { throw 'Archive contains an unsafe or directory entry.' }
            if (@($seen | Where-Object { [StringComparer]::OrdinalIgnoreCase.Equals($_,$name) }).Count) { throw 'Archive contains a duplicate entry path.' }
            $seen += $name
            $entryLength = [int64]$entry.Length
            $compressedLength = [int64]$entry.CompressedLength
            if ($entryLength -lt 0 -or $compressedLength -lt 0) { throw "Archive entry has invalid size metadata: $name" }
            if ($entryLength -gt $bounds.MaximumExpandedBytes) { throw "Archive entry exceeds the maximum expanded byte size of $($bounds.MaximumExpandedBytes): $name" }
            if ([decimal]$expandedBytes + [decimal]$entryLength -gt [decimal]$bounds.MaximumExpandedBytes) { throw "Archive expanded size exceeds the maximum allowed byte size of $($bounds.MaximumExpandedBytes)." }
            if ($entryLength -gt 0 -and ($compressedLength -le 0 -or [decimal]$entryLength -gt ([decimal]$compressedLength * $bounds.MaximumCompressionRatio))) {
                throw "Archive entry exceeds the maximum compression ratio of $($bounds.MaximumCompressionRatio): $name"
            }
            if ([decimal]$compressedBytes + [decimal]$compressedLength -gt [decimal]::MaxValue) { throw "Archive compressed size overflowed: $name" }
            $entryStream = $null; $entrySha = $null; $actualEntryLength = [int64]0
            try {
                $entryStream = $entry.Open()
                $entrySha = [Security.Cryptography.SHA256]::Create()
                $buffer = New-Object byte[] 65536
                while (($read = $entryStream.Read($buffer, 0, $buffer.Length)) -gt 0) {
                    if ([decimal]$actualEntryLength + [decimal]$read -gt [decimal]$bounds.MaximumExpandedBytes) { throw "Archive entry exceeded the maximum expanded byte size of $($bounds.MaximumExpandedBytes): $name" }
                    if ([decimal]$expandedBytes + [decimal]$actualEntryLength + [decimal]$read -gt [decimal]$bounds.MaximumExpandedBytes) { throw "Archive expanded size exceeded the maximum allowed byte size of $($bounds.MaximumExpandedBytes)." }
                    $entrySha.TransformBlock($buffer, 0, $read, $buffer, 0) | Out-Null
                    $actualEntryLength += [int64]$read
                }
                $entrySha.TransformFinalBlock((New-Object byte[] 0), 0, 0) | Out-Null
                if ($actualEntryLength -ne $entryLength) { throw "Archive entry expanded length did not match its ZIP metadata: $name" }
                if ($actualEntryLength -gt 0 -and ($compressedLength -le 0 -or [decimal]$actualEntryLength -gt ([decimal]$compressedLength * $bounds.MaximumCompressionRatio))) {
                    throw "Archive entry exceeds the maximum compression ratio of $($bounds.MaximumCompressionRatio): $name"
                }
                $entryHash = ([BitConverter]::ToString($entrySha.Hash)).Replace('-','')
            } finally { if($entrySha){$entrySha.Dispose()}; if($entryStream){$entryStream.Dispose()} }
            $expandedBytes += $actualEntryLength
            $compressedBytes += $compressedLength
            $entries += [pscustomobject][ordered]@{ Path=$name; Length=$actualEntryLength; Sha256=$entryHash }
        }
        if ($expandedBytes -gt 0 -and ($compressedBytes -le 0 -or [decimal]$expandedBytes -gt ([decimal]$compressedBytes * $bounds.MaximumCompressionRatio))) {
            throw "Archive exceeds the maximum compression ratio of $($bounds.MaximumCompressionRatio)."
        }
    } finally { if($zip){$zip.Dispose()}; if($sha){$sha.Dispose()}; if($stream){$stream.Dispose()} }
    $after = Get-Item -LiteralPath $fullPath -Force
    if ([int64]$before.Length -ne [int64]$after.Length -or $before.LastWriteTimeUtc.Ticks -ne $after.LastWriteTimeUtc.Ticks) { throw 'Archive changed during stable inspection.' }
    $entries = @(Sort-PackageEntriesOrdinal $entries)
    return [pscustomobject][ordered]@{ Length=[int64]$before.Length; Sha256=$archiveHash; EntryCount=$entryCount; ExpandedBytes=$expandedBytes; CompressedBytes=$compressedBytes; Entries=$entries }
}

function Read-V02CanonicalIdentityReceipt {
    param([Parameter(Mandatory = $true)][string]$Path, [Parameter(Mandatory = $true)][string]$RepositoryRoot)
    $stable = Get-V02StableFileIdentity -Path $Path -IncludeBytes
    $document = ConvertFrom-V02StrictBytes $stable.Bytes 'v0.2 package identity receipt'
    $canonical = ConvertTo-V02CanonicalJson $document.Value $RepositoryRoot
    if ($document.Json -cne ($canonical + "`n")) { throw 'Identity receipt JSON is not exact JCS plus one LF.' }
    return [pscustomobject][ordered]@{ Identity=$document.Value; ReceiptSha256=(Get-Sha256ForText $canonical); Stable=$stable; CanonicalJson=$canonical }
}

function Get-V02PreparationProfileIdentity {
    param([Parameter(Mandatory = $true)][string]$Path,[Parameter(Mandatory = $true)]$ExpectedProfile,[Parameter(Mandatory = $true)][string]$RepositoryRoot)
    $expectedPath=[IO.Path]::GetFullPath((Join-Path ([IO.Path]::GetFullPath($RepositoryRoot)) 'tools\packaging\v0.2\package-identity-profile.json'))
    $actualPath=[IO.Path]::GetFullPath($Path)
    if(-not [StringComparer]::OrdinalIgnoreCase.Equals($actualPath,$expectedPath)){throw 'Preparation profile must be the versioned repository profile path.'}
    $stable=Get-V02StableFileIdentity -Path $actualPath -IncludeBytes
    $document=ConvertFrom-V02StrictBytes $stable.Bytes 'v0.2 preparation profile'
    Assert-V02PackageIdentityProfile $document.Value
    $canonical=ConvertTo-V02CanonicalJson $document.Value $RepositoryRoot
    $expectedCanonical=ConvertTo-V02CanonicalJson $ExpectedProfile $RepositoryRoot
    if ($canonical -cne $expectedCanonical) { throw 'Preparation profile object does not match the stable repository profile bytes.' }
    return [pscustomobject][ordered]@{Id=[string]$document.Value.profileId;RelativePath='tools/packaging/v0.2/package-identity-profile.json';Bytes=[int64]$stable.Length;FileSha256=[string]$stable.Sha256;CanonicalSha256=(Get-Sha256ForText $canonical)}
}

function Assert-V02ReceiptSchema {
    param([Parameter(Mandatory = $true)]$Identity,[Parameter(Mandatory = $true)][string]$CanonicalJson,[Parameter(Mandatory = $true)][string]$RepositoryRoot)
    $root=[IO.Path]::GetFullPath($RepositoryRoot)
    $schemaPath=Join-Path $root 'tools\packaging\v0.2\package-identity-receipt.schema.json'
    $schemaStable=Get-V02StableFileIdentity -Path $schemaPath -IncludeBytes
    $schemaDocument=ConvertFrom-V02StrictBytes $schemaStable.Bytes 'v0.2 package identity receipt schema'
    $schemaCanonical=ConvertTo-V02CanonicalJson $schemaDocument.Value $RepositoryRoot
    $schemaHash=Get-Sha256ForText $schemaCanonical
    if ($schemaHash -cne $script:V02PackageIdentityReceiptSchemaSha256) { throw 'Package identity receipt schema canonical SHA-256 drifted.' }
    if ([string]$schemaDocument.Value.'$schema' -cne 'https://json-schema.org/draft/2020-12/schema' -or $schemaDocument.Value.additionalProperties -isnot [bool] -or $schemaDocument.Value.additionalProperties) { throw 'Package identity receipt schema root is not strict Draft 2020-12.' }
    $testJson=Get-Command Test-Json -CommandType Cmdlet -ErrorAction SilentlyContinue
    if ($null -ne $testJson -and $testJson.Parameters.ContainsKey('SchemaFile')) {
        if(-not ($CanonicalJson|Test-Json -SchemaFile $schemaPath)){throw 'Package identity receipt failed Draft 2020-12 schema validation.'}
    }
    return $schemaHash
}

function Assert-V02PackageIdentity {
    param([Parameter(Mandatory = $true)]$Identity,[Parameter(Mandatory = $true)]$Profile,[Parameter(Mandatory = $true)][string]$RepositoryRoot,[Parameter(Mandatory = $true)][string]$ArchivePath,[Parameter(Mandatory = $true)][string]$PackageRoot,[Parameter(Mandatory = $true)][string]$ProfilePath,[string]$ReceiptSha256,[string]$CanonicalReceiptJson)

    Assert-V02PackageIdentityProfile $Profile
    $governed = Assert-V02GovernedReferenceHost -RepositoryRoot $RepositoryRoot
    $recomputedCanonicalReceiptJson=ConvertTo-V02CanonicalJson $Identity $RepositoryRoot
    if ([string]::IsNullOrWhiteSpace($CanonicalReceiptJson) -or
        -not [StringComparer]::Ordinal.Equals($CanonicalReceiptJson,$recomputedCanonicalReceiptJson)) {
        throw 'Supplied canonical receipt JSON does not exactly match the Identity object.'
    }
    $recomputedReceiptSha256=Get-Sha256ForText $recomputedCanonicalReceiptJson
    Assert-V02Sha256 $ReceiptSha256 'receipt SHA-256'
    if (-not [StringComparer]::Ordinal.Equals($ReceiptSha256,$recomputedReceiptSha256)) {
        throw 'Supplied receipt SHA-256 does not match the recomputed canonical Identity object.'
    }
    $null=Assert-V02ReceiptSchema -Identity $Identity -CanonicalJson $recomputedCanonicalReceiptJson -RepositoryRoot $RepositoryRoot
    Assert-V02ExactProperties $Identity @('schemaVersion','profileId','issue','packageVersion','runtimeIdentifier','source','profile','archive','packageManifest','components','referenceHost','renderer','evidenceBoundary') 'v0.2 package identity receipt'
    Assert-V02NativeInteger $Identity.schemaVersion 'identity.schemaVersion' 1; if ([int64]$Identity.schemaVersion -ne 1) { throw 'identity.schemaVersion must equal 1.' }
    Assert-V02ExactString $Identity.profileId $Profile.profileId 'identity.profileId'; Assert-V02NativeInteger $Identity.issue 'identity.issue' 1; if ([int64]$Identity.issue -ne 149) { throw 'identity.issue must equal 149.' }; Assert-V02ExactString $Identity.packageVersion '0.2.0' 'identity.packageVersion'; Assert-V02ExactString $Identity.runtimeIdentifier 'win-x64' 'identity.runtimeIdentifier'
    Assert-V02ExactProperties $Identity.source @('commitSha','treeSha') 'identity.source'; Assert-V02GitObjectId $Identity.source.commitSha 'identity.source.commitSha'; Assert-V02GitObjectId $Identity.source.treeSha 'identity.source.treeSha'
    $git = Get-V02GitIdentity -RepositoryRoot $RepositoryRoot -RequireClean
    if ($null -ne $script:V02PackageIdentityAfterSourcePreflightForTest) {
        & $script:V02PackageIdentityAfterSourcePreflightForTest
    }
    if ($Identity.source.commitSha -cne $git.CommitSha -or $Identity.source.treeSha -cne $git.TreeSha) { throw 'Identity source does not match the clean repository HEAD commit/tree.' }
    $profileIdentity=Get-V02PreparationProfileIdentity -Path $ProfilePath -ExpectedProfile $Profile -RepositoryRoot $RepositoryRoot
    Assert-V02ExactProperties $Identity.profile @('id','relativePath','bytes','fileSha256','canonicalSha256') 'identity.profile'; Assert-V02ExactString $Identity.profile.id $profileIdentity.Id 'identity.profile.id'; Assert-V02ExactString $Identity.profile.relativePath $profileIdentity.RelativePath 'identity.profile.relativePath'; Assert-V02NativeInteger $Identity.profile.bytes 'identity.profile.bytes' 1; Assert-V02Sha256 $Identity.profile.fileSha256 'identity.profile.fileSha256'; Assert-V02Sha256 $Identity.profile.canonicalSha256 'identity.profile.canonicalSha256'; if ([int64]$Identity.profile.bytes -ne $profileIdentity.Bytes -or $Identity.profile.fileSha256 -cne $profileIdentity.FileSha256 -or $Identity.profile.canonicalSha256 -cne $profileIdentity.CanonicalSha256) { throw 'Identity profile leaf values do not match the stable preparation profile.' }
    Assert-V02ExactProperties $Identity.archive @('relativePath','fileName','bytes','sha256') 'identity.archive'; Assert-V02ExactString $Identity.archive.relativePath $Profile.archiveFileName 'identity.archive.relativePath'; Assert-V02ExactString $Identity.archive.fileName $Profile.archiveFileName 'identity.archive.fileName'; Assert-V02NativeInteger $Identity.archive.bytes 'identity.archive.bytes' 1; Assert-V02Sha256 $Identity.archive.sha256 'identity.archive.sha256'
    Assert-V02ExactProperties $Identity.packageManifest @('fileName','bytes','sha256','contentSha256','fileCount','totalBytes') 'identity.packageManifest'; Assert-V02ExactString $Identity.packageManifest.fileName $Profile.packageManifestFileName 'identity.packageManifest.fileName'; Assert-V02NativeInteger $Identity.packageManifest.bytes 'identity.packageManifest.bytes' 1; Assert-V02Sha256 $Identity.packageManifest.sha256 'identity.packageManifest.sha256'; Assert-V02Sha256 $Identity.packageManifest.contentSha256 'identity.packageManifest.contentSha256'; Assert-V02NativeInteger $Identity.packageManifest.fileCount 'identity.packageManifest.fileCount' 1; Assert-V02NativeInteger $Identity.packageManifest.totalBytes 'identity.packageManifest.totalBytes' 1
    Assert-V02ExactProperties $Identity.components @('app','core') 'identity.components'; foreach($name in @('app','core')){Assert-V02ExactProperties $Identity.components.$name @('relativePath','bytes','sha256') "identity.components.$name"; Assert-V02NativeInteger $Identity.components.$name.bytes "identity.components.$name.bytes" 1; Assert-V02Sha256 $Identity.components.$name.sha256 "identity.components.$name.sha256"}; Assert-V02ExactString $Identity.components.app.relativePath $Profile.components.appRelativePath 'identity.components.app.relativePath'; Assert-V02ExactString $Identity.components.core.relativePath $Profile.components.coreRelativePath 'identity.components.core.relativePath'
    Assert-V02ExactProperties $Identity.referenceHost @('profileId','profileSha256') 'identity.referenceHost'; Assert-V02ExactString $Identity.referenceHost.profileId $Profile.referenceHost.profileId 'identity.referenceHost.profileId'; Assert-V02ExactString $Identity.referenceHost.profileSha256 $Profile.referenceHost.profileSha256 'identity.referenceHost.profileSha256'
    Assert-V02ExactProperties $Identity.renderer @('policy','wpfProcessRenderMode') 'identity.renderer'; foreach($name in @('policy','wpfProcessRenderMode')){Assert-V02ExactString $Identity.renderer.$name $Profile.renderer.$name "identity.renderer.$name"}
    Assert-V02ExactProperties $Identity.evidenceBoundary @('evidenceClass','runtimeUse','actualHerdrUsed','runtimeCredit','releaseCredit') 'identity.evidenceBoundary'; foreach($name in @('evidenceClass','runtimeUse','runtimeCredit','releaseCredit')){Assert-V02ExactString $Identity.evidenceBoundary.$name $Profile.evidenceBoundary.$name "identity.evidenceBoundary.$name"}; Assert-V02NativeBoolean $Identity.evidenceBoundary.actualHerdrUsed 'identity.evidenceBoundary.actualHerdrUsed'; if($Identity.evidenceBoundary.actualHerdrUsed){throw 'identity.evidenceBoundary.actualHerdrUsed must be false.'}

    $root=[IO.Path]::GetFullPath($PackageRoot); Assert-NoReparsePath $root
    $manifestPath=Join-Path $root $Profile.packageManifestFileName
    $manifestResult=Read-V02PackageManifest -Path $manifestPath -Profile $Profile -RepositoryRoot $RepositoryRoot
    $manifest=$manifestResult.Manifest
    if ($manifest.source.commitSha -cne $Identity.source.commitSha -or $manifest.source.treeSha -cne $Identity.source.treeSha) { throw 'Package manifest source does not match the identity receipt source.' }
    $rootInventory=Get-V02PackageRootInventory -PackageRoot $root -ExcludeRelativePath @($Profile.packageManifestFileName)
    Assert-V02InventoryEqual $manifestResult.Entries $rootInventory.Entries 'Manifest/package-root'
    if ($manifestResult.Stable.Sha256 -cne $Identity.packageManifest.sha256 -or $manifestResult.Stable.Length -ne [int64]$Identity.packageManifest.bytes -or $manifest.contentSha256 -cne $Identity.packageManifest.contentSha256 -or [int64]$manifest.fileCount -ne [int64]$Identity.packageManifest.fileCount -or [int64]$manifest.totalBytes -ne [int64]$Identity.packageManifest.totalBytes) { throw 'Identity packageManifest leaf values are not exact with the canonical manifest.' }
    $app=@($rootInventory.Entries|Where-Object Path -CEQ $Profile.components.appRelativePath); $core=@($rootInventory.Entries|Where-Object Path -CEQ $Profile.components.coreRelativePath)
    if ($app.Count -ne 1 -or $core.Count -ne 1 -or $app[0].Sha256 -cne $Identity.components.app.sha256 -or $core[0].Sha256 -cne $Identity.components.core.sha256 -or $app[0].Length -ne [int64]$Identity.components.app.bytes -or $core[0].Length -ne [int64]$Identity.components.core.bytes) { throw 'App/Core receipt bytes/hashes do not match the canonical package inventory.' }
    $archive=[IO.Path]::GetFullPath($ArchivePath); if ([IO.Path]::GetFileName($archive) -cne $Profile.archiveFileName) { throw 'Archive file name does not match the preparation profile.' }
    $archiveInventory=Get-V02ArchiveInventory $archive
    if ($archiveInventory.Length -ne [int64]$Identity.archive.bytes -or $archiveInventory.Sha256 -cne $Identity.archive.sha256) { throw 'Archive bytes/SHA-256 do not match the identity receipt.' }
    $fullRootInventory=Get-V02PackageRootInventory -PackageRoot $root
    Assert-V02InventoryEqual $fullRootInventory.Entries $archiveInventory.Entries 'Archive/package-root'
    if ([string]$governed.Sha256 -cne $Identity.referenceHost.profileSha256) { throw 'Governed Plan profile hash does not match the identity receipt.' }
    $gitAfter=Get-V02GitIdentity -RepositoryRoot $RepositoryRoot -RequireClean
    if ($gitAfter.CommitSha -cne $git.CommitSha -or $gitAfter.TreeSha -cne $git.TreeSha) { throw 'Source commit/tree changed during package identity validation.' }
    return [pscustomobject][ordered]@{EvidenceClass='Static/PackagedCompatibilityPreparation';Issue=149;ProfileId=$Identity.profileId;ReceiptSha256=$recomputedReceiptSha256;SourceCommit=$Identity.source.commitSha;SourceTree=$Identity.source.treeSha;PreparationProfileFileSha256=$Identity.profile.fileSha256;PreparationProfileCanonicalSha256=$Identity.profile.canonicalSha256;ArchiveSha256=$Identity.archive.sha256;AppSha256=$Identity.components.app.sha256;CoreSha256=$Identity.components.core.sha256;ReferenceHostProfileSha256=$Identity.referenceHost.profileSha256;RendererPolicySha256=$Profile.renderer.policySha256;Runtime='NOT OBSERVED';Release='NOT CLAIMED'}
}
