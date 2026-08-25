#requires -Version 5.1

Set-StrictMode -Version Latest

. (Join-Path $PSScriptRoot 'V02PackageIdentity.Common.ps1')

if ($null -eq ('HerdrOps.V02DirectoryLeaseNative' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Text;
using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;
namespace HerdrOps {
    [StructLayout(LayoutKind.Sequential)]
    public struct V02FileInformation {
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

    [StructLayout(LayoutKind.Sequential)]
    public struct V02FileDispositionInfo {
        [MarshalAs(UnmanagedType.Bool)] public bool DeleteFile;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct V02FileBasicInfo {
        public long CreationTime;
        public long LastAccessTime;
        public long LastWriteTime;
        public long ChangeTime;
        public uint FileAttributes;
    }

    public static class V02DirectoryLeaseNative {
        [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)]
        public static extern SafeFileHandle CreateFile(
            string name, uint access, uint share, IntPtr security,
            uint disposition, uint flags, IntPtr template);

        [DllImport("kernel32.dll", SetLastError=true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        public static extern bool GetFileInformationByHandle(
            SafeFileHandle handle, out V02FileInformation information);

        [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)]
        public static extern uint GetFinalPathNameByHandle(
            SafeFileHandle handle, StringBuilder path, uint pathLength, uint flags);

        [DllImport("kernel32.dll", SetLastError=true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        public static extern bool SetFileInformationByHandle(
            SafeFileHandle handle, int informationClass,
            ref V02FileDispositionInfo information, uint bufferSize);

        [DllImport("kernel32.dll", EntryPoint="SetFileInformationByHandle", SetLastError=true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        public static extern bool SetFileBasicInformationByHandle(
            SafeFileHandle handle, int informationClass,
            ref V02FileBasicInfo information, uint bufferSize);

        [DllImport("shell32.dll", SetLastError=true)]
        public static extern int SHGetKnownFolderPath(
            [MarshalAs(UnmanagedType.LPStruct)] Guid folderId, uint flags,
            IntPtr token, out IntPtr path);
    }
}
'@
}

function ConvertFrom-V02FinalHandlePath {
    param([Parameter(Mandatory = $true)][string]$Path)
    if ($Path.StartsWith('\\?\UNC\',[StringComparison]::OrdinalIgnoreCase)) { return '\\' + $Path.Substring(8) }
    if ($Path.StartsWith('\\?\',[StringComparison]::OrdinalIgnoreCase)) { return $Path.Substring(4) }
    return $Path
}

function Get-V02HandleIdentity {
    param(
        [Parameter(Mandatory = $true)]$Handle,
        [Parameter(Mandatory = $true)][string]$Context
    )
    $information = New-Object HerdrOps.V02FileInformation
    if (-not [HerdrOps.V02DirectoryLeaseNative]::GetFileInformationByHandle($Handle,[ref]$information)) {
        throw "$Context identity query failed (Win32 $([Runtime.InteropServices.Marshal]::GetLastWin32Error()))."
    }
    $builder = New-Object Text.StringBuilder 32768
    $length = [HerdrOps.V02DirectoryLeaseNative]::GetFinalPathNameByHandle($Handle,$builder,[uint32]$builder.Capacity,0)
    if ($length -eq 0 -or $length -ge $builder.Capacity) {
        throw "$Context final-path query failed (Win32 $([Runtime.InteropServices.Marshal]::GetLastWin32Error()))."
    }
    $fileId = ('{0:X8}{1:X8}' -f $information.FileIndexHigh,$information.FileIndexLow)
    return [pscustomobject][ordered]@{
        FinalPath = [IO.Path]::GetFullPath((ConvertFrom-V02FinalHandlePath $builder.ToString())).TrimEnd('\','/')
        VolumeSerialNumber = ('{0:X8}' -f $information.VolumeSerialNumber)
        FileId = $fileId
        LinkCount = [uint32]$information.NumberOfLinks
        Attributes = [uint32]$information.FileAttributes
    }
}

function Assert-V02SameHandleIdentity {
    param(
        [Parameter(Mandatory = $true)]$Handle,
        [Parameter(Mandatory = $true)]$Expected,
        [Parameter(Mandatory = $true)][string]$ExpectedPath,
        [Parameter(Mandatory = $true)][string]$Context,
        [switch]$RequireSingleLink
    )
    $current = Get-V02HandleIdentity -Handle $Handle -Context $Context
    $fullExpected = [IO.Path]::GetFullPath($ExpectedPath).TrimEnd('\','/')
    if (-not [StringComparer]::OrdinalIgnoreCase.Equals($current.FinalPath,$fullExpected)) { throw "$Context final path changed or resolved outside its exact path: $($current.FinalPath)" }
    foreach ($name in @('VolumeSerialNumber','FileId')) {
        if ([string]$current.$name -cne [string]$Expected.$name) { throw "$Context $name changed while held." }
    }
    if (($current.Attributes -band 0x400) -ne 0) { throw "$Context is a reparse point." }
    if ($RequireSingleLink -and $current.LinkCount -ne 1) { throw "$Context must have exactly one link; observed $($current.LinkCount)." }
    return $current
}

function Get-V02KnownLocalAppDataRoot {
    $folderId = [Guid]'F1B32785-6FBA-4FCF-9D55-7B8E7F157091'
    $pointer = [IntPtr]::Zero
    $result = [HerdrOps.V02DirectoryLeaseNative]::SHGetKnownFolderPath($folderId,0,[IntPtr]::Zero,[ref]$pointer)
    if ($result -ne 0 -or $pointer -eq [IntPtr]::Zero) { throw "Windows Known Folder LocalAppData lookup failed (HRESULT 0x$('{0:X8}' -f ([uint32]$result)))." }
    try { return [IO.Path]::GetFullPath([Runtime.InteropServices.Marshal]::PtrToStringUni($pointer)).TrimEnd('\','/') }
    finally { [Runtime.InteropServices.Marshal]::FreeCoTaskMem($pointer) }
}

function Open-V02DirectoryMutationLease {
    param([Parameter(Mandatory = $true)][string]$Path,[switch]$ForDelete)
    $full = [IO.Path]::GetFullPath($Path)
    if (-not (Test-Path -LiteralPath $full -PathType Container)) { throw "Mutation parent directory does not exist: $full" }
    Assert-V02PathNoReparse -Path $full
    # FILE_READ_ATTRIBUTES, FILE_SHARE_READ|FILE_SHARE_WRITE (intentionally no
    # FILE_SHARE_DELETE), OPEN_EXISTING, FILE_FLAG_BACKUP_SEMANTICS.  Holding
    # this handle prevents rename/delete of the resolved parent during commit.
    $access = [uint32]0x80
    if ($ForDelete) { $access = $access -bor [uint32]0x10000 }
    $handle = [HerdrOps.V02DirectoryLeaseNative]::CreateFile($full,$access,0x3,[IntPtr]::Zero,3,0x02200000,[IntPtr]::Zero)
    if ($null -eq $handle -or $handle.IsInvalid) {
        $errorCode = [Runtime.InteropServices.Marshal]::GetLastWin32Error()
        if ($null -ne $handle) { $handle.Dispose() }
        throw "Could not hold mutation parent directory '$full' (Win32 $errorCode)."
    }
    $identity = Get-V02HandleIdentity -Handle $handle -Context "directory lease '$full'"
    if (-not [StringComparer]::OrdinalIgnoreCase.Equals($identity.FinalPath,$full.TrimEnd('\','/')) -or ($identity.Attributes -band 0x400) -ne 0 -or $identity.LinkCount -ne 1) {
        $handle.Dispose()
        throw "Directory lease did not resolve to the exact single-link non-reparse directory: $full"
    }
    Add-Member -InputObject $handle -MemberType NoteProperty -Name V02Identity -Value $identity
    Add-Member -InputObject $handle -MemberType NoteProperty -Name V02Path -Value $full.TrimEnd('\','/')
    return $handle
}

function Open-V02FileDeletionLease {
    param([Parameter(Mandatory = $true)][string]$Path)
    $full = [IO.Path]::GetFullPath($Path)
    if (-not (Test-Path -LiteralPath $full -PathType Leaf)) { throw "Deletion file does not exist: $full" }
    Assert-V02PathNoReparse -Path $full
    $handle = [HerdrOps.V02DirectoryLeaseNative]::CreateFile($full,0x10180,0x3,[IntPtr]::Zero,3,0x00200000,[IntPtr]::Zero)
    if ($null -eq $handle -or $handle.IsInvalid) {
        $errorCode = [Runtime.InteropServices.Marshal]::GetLastWin32Error()
        if ($null -ne $handle) { $handle.Dispose() }
        throw "Could not hold deletion file '$full' (Win32 $errorCode)."
    }
    $identity = Get-V02HandleIdentity -Handle $handle -Context "deletion file '$full'"
    if (-not [StringComparer]::OrdinalIgnoreCase.Equals($identity.FinalPath,$full.TrimEnd('\','/')) -or ($identity.Attributes -band 0x400) -ne 0 -or $identity.LinkCount -ne 1) {
        $handle.Dispose()
        throw "Deletion file did not resolve to the exact single-link non-reparse object: $full"
    }
    Add-Member -InputObject $handle -MemberType NoteProperty -Name V02Identity -Value $identity
    Add-Member -InputObject $handle -MemberType NoteProperty -Name V02Path -Value $full.TrimEnd('\','/')
    return $handle
}

function Get-V02DirectoryPathIdentity {
    param([Parameter(Mandatory = $true)][string]$Path,[string]$Context='directory')
    $lease = Open-V02DirectoryMutationLease -Path $Path
    try { return $lease.V02Identity }
    finally { $lease.Dispose() }
}

function Assert-V02OwnedStagingIdentity {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)]$ExpectedIdentity,
        [Parameter(Mandatory = $true)][string]$Context
    )
    $lease = Open-V02DirectoryMutationLease -Path $Path
    try {
        return Assert-V02SameHandleIdentity -Handle $lease -Expected $ExpectedIdentity -ExpectedPath $Path -Context $Context -RequireSingleLink
    }
    finally { $lease.Dispose() }
}

function Write-V02CanonicalTempFileNoClobber {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Value,
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$RepositoryRoot
    )
    $destination = Assert-SafeDestination -Path $Path -AllowTempChild
    $parent = Split-Path -Path $destination -Parent
    if (-not (Test-Path -LiteralPath $parent -PathType Container)) { throw "Canonical temporary-file parent was not found: $parent" }
    $json = ConvertTo-V02CanonicalJson -Value $Value -RepositoryRoot $RepositoryRoot
    $bytes = (New-Object Text.UTF8Encoding($false)).GetBytes($json + "`n")
    $sha = [Security.Cryptography.SHA256]::Create()
    try { $expectedSha256 = ([BitConverter]::ToString($sha.ComputeHash($bytes))).Replace('-','') }
    finally { $sha.Dispose() }
    $parentLease = Open-V02DirectoryMutationLease -Path $parent
    $stream = $null
    try {
        if (Test-Path -LiteralPath $destination) { throw "Refusing to overwrite canonical temporary file: $destination" }
        $stream = [IO.File]::Open($destination,[IO.FileMode]::CreateNew,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
        $identity = Get-V02HandleIdentity -Handle $stream.SafeFileHandle -Context 'canonical temporary file'
        $null = Assert-V02SameHandleIdentity -Handle $stream.SafeFileHandle -Expected $identity -ExpectedPath $destination -Context 'canonical temporary file' -RequireSingleLink
        $stream.Write($bytes,0,$bytes.Length)
        $stream.Flush($true)
        $null = Assert-V02SameHandleIdentity -Handle $stream.SafeFileHandle -Expected $identity -ExpectedPath $destination -Context 'canonical temporary file' -RequireSingleLink
        return [pscustomobject][ordered]@{Path=$destination;Length=[int64]$bytes.Length;Sha256=$expectedSha256;VolumeSerialNumber=$identity.VolumeSerialNumber;FileId=$identity.FileId;LinkCount=$identity.LinkCount}
    }
    finally {
        try {
            if ($null -ne $stream) { $stream.Dispose() }
        }
        finally {
            try {
                $null = Assert-V02SameHandleIdentity -Handle $parentLease -Expected $parentLease.V02Identity -ExpectedPath $parent -Context 'canonical temporary-file parent' -RequireSingleLink
            }
            finally { $parentLease.Dispose() }
        }
    }
}

function Copy-V02InstallStateToOwnedStaging {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$SourcePath,
        [Parameter(Mandatory = $true)]$ExpectedSourceBinding,
        [Parameter(Mandatory = $true)][string]$DestinationPath,
        [Parameter(Mandatory = $true)][string]$OwnedStagingRoot,
        [Parameter(Mandatory = $true)]$ExpectedStagingIdentity,
        [Parameter(Mandatory = $true)][string]$InstallRoot
    )

    $source = Assert-SafeDestination -Path $SourcePath -AllowTempChild
    if (-not (Test-Path -LiteralPath $source -PathType Leaf)) { throw "Install-state temporary source was not found: $source" }
    if ($null -eq $ExpectedSourceBinding -or [int64]$ExpectedSourceBinding.Length -lt 1 -or [string]$ExpectedSourceBinding.Sha256 -notmatch '^[0-9A-F]{64}$') { throw 'Install-state temporary source binding is invalid.' }
    $destination = [IO.Path]::GetFullPath($DestinationPath)
    $stagingRoot = [IO.Path]::GetFullPath($OwnedStagingRoot).TrimEnd('\','/')
    $install = [IO.Path]::GetFullPath($InstallRoot).TrimEnd('\','/')
    $installParent = (Split-Path -Path $install -Parent).TrimEnd('\','/')
    $installName = [IO.Path]::GetFileName($install)
    if (-not [StringComparer]::OrdinalIgnoreCase.Equals((Split-Path -Path $stagingRoot -Parent).TrimEnd('\','/'),$installParent) -or
        [IO.Path]::GetFileName($stagingRoot) -notmatch ('^\.' + [regex]::Escape($installName) + '\.staging-[0-9a-f]{32}$')) {
        throw "Install-state staging root is not the exact transaction sibling for '$install': $stagingRoot"
    }
    if (-not [StringComparer]::OrdinalIgnoreCase.Equals((Split-Path -Path $destination -Parent).TrimEnd('\','/'),$stagingRoot) -or
        [IO.Path]::GetFileName($destination) -cne 'install-state.json') {
        throw "Install-state destination must be the exact direct install-state.json child of the owned staging root: $destination"
    }
    if ($null -eq $ExpectedStagingIdentity) { throw 'Install-state staging identity is required.' }

    $stagingLease = $null
    try {
        $stagingLease = Open-V02DirectoryMutationLease -Path $stagingRoot
        $null = Assert-V02SameHandleIdentity -Handle $stagingLease -Expected $ExpectedStagingIdentity -ExpectedPath $stagingRoot -Context 'install-state owned staging root' -RequireSingleLink
        $copied = Copy-V02StableFile -Source $source -Destination $destination
        if ([int64]$copied.Length -ne [int64]$ExpectedSourceBinding.Length -or [string]$copied.Sha256 -cne [string]$ExpectedSourceBinding.Sha256) { throw 'Install-state stable copy does not equal the exact canonical temporary source binding.' }
        $null = Assert-V02SameHandleIdentity -Handle $stagingLease -Expected $ExpectedStagingIdentity -ExpectedPath $stagingRoot -Context 'install-state owned staging root' -RequireSingleLink
        return $copied
    }
    finally {
        if ($null -ne $stagingLease) {
            try {
                $null = Assert-V02SameHandleIdentity -Handle $stagingLease -Expected $ExpectedStagingIdentity -ExpectedPath $stagingRoot -Context 'install-state owned staging root' -RequireSingleLink
            }
            finally { $stagingLease.Dispose() }
        }
    }
}

function Get-V02DefaultInstallRoot {
    return (Join-Path (Get-V02KnownLocalAppDataRoot) 'Programs\HerdrOps')
}

function Get-V02DefaultUserDataRoot {
    return (Join-Path (Get-V02KnownLocalAppDataRoot) 'HerdrOps')
}

function Test-V02IsElevated {
    try {
        $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
        $principal = New-Object Security.Principal.WindowsPrincipal($identity)
        return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    } catch {
        return $false
    }
}

function Assert-V02NonElevated {
    param([switch]$AllowElevatedForTesting)

    if ($AllowElevatedForTesting) {
        return
    }

    if (Test-V02IsElevated) {
        throw 'HerdrOps per-user installation must run non-elevated without Administrator rights.'
    }
}

function Assert-V02NotSystemDirectory {
    param([Parameter(Mandatory = $true)][string]$Path)

    $normalized = [IO.Path]::GetFullPath($Path).TrimEnd('\', '/')
    $prohibited = @(
        $env:SystemDrive,
        [IO.Path]::GetPathRoot($normalized),
        $env:windir,
        $env:SystemRoot,
        $env:ProgramFiles,
        ${env:ProgramFiles(x86)},
        $env:ProgramData,
        $env:USERPROFILE,
        $env:APPDATA,
        $env:LOCALAPPDATA
    ) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | ForEach-Object { [IO.Path]::GetFullPath($_).TrimEnd('\', '/') }

    foreach ($bad in $prohibited) {
        if ([StringComparer]::OrdinalIgnoreCase.Equals($normalized, $bad)) {
            throw "Refusing to operate on broad or protected system/profile root directory: $normalized"
        }
    }

    foreach ($protectedTree in @($env:windir,$env:SystemRoot,$env:ProgramFiles,${env:ProgramFiles(x86)},$env:ProgramData) |
        Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
        ForEach-Object { [IO.Path]::GetFullPath($_).TrimEnd('\','/') } |
        Select-Object -Unique) {
        if ($normalized.StartsWith($protectedTree + '\', [StringComparison]::OrdinalIgnoreCase)) {
            throw "Refusing to operate inside a protected system directory tree: $normalized"
        }
    }
}

function Assert-V02PackagingPathsDoNotOverlap {
    param(
        [Parameter(Mandatory = $true)][array]$Paths
    )

    for ($i = 0; $i -lt $Paths.Count; $i++) {
        $first = $Paths[$i]
        $firstNormalized = [IO.Path]::GetFullPath($first.Path).TrimEnd('\', '/')
        for ($j = $i + 1; $j -lt $Paths.Count; $j++) {
            $second = $Paths[$j]
            $secondNormalized = [IO.Path]::GetFullPath($second.Path).TrimEnd('\', '/')

            if ([StringComparer]::OrdinalIgnoreCase.Equals($firstNormalized, $secondNormalized)) {
                throw "$($first.Name) and $($second.Name) must not be identical: $firstNormalized"
            }

            $firstWithSlash = $firstNormalized + '\'
            $secondWithSlash = $secondNormalized + '\'

            if ($firstNormalized.StartsWith($secondWithSlash, [StringComparison]::OrdinalIgnoreCase)) {
                throw "$($first.Name) ($firstNormalized) must not be nested inside $($second.Name) ($secondNormalized)."
            }
            if ($secondNormalized.StartsWith($firstWithSlash, [StringComparison]::OrdinalIgnoreCase)) {
                throw "$($second.Name) ($secondNormalized) must not be nested inside $($first.Name) ($firstNormalized)."
            }
        }
    }
}

function Assert-V02PathNoReparse {
    param([Parameter(Mandatory = $true)][string]$Path)

    $fullPath = [IO.Path]::GetFullPath($Path)
    Assert-NoReparsePath -Path $fullPath
}

function Assert-V02TreeNoReparse {
    param([Parameter(Mandatory = $true)][string]$Path)

    $fullPath = [IO.Path]::GetFullPath($Path)
    Assert-NoReparsePath -Path $fullPath
    if (Test-Path -LiteralPath $fullPath -PathType Container) {
        Assert-NoReparseDescendants -Path $fullPath
    }
}

function Get-V02StartupRegistryKeyPath {
    return 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
}

function Register-V02UserStartup {
    param(
        [Parameter(Mandatory = $true)][string]$ExecutablePath,
        [string]$ValueName = 'HerdrOps',
        [hashtable]$MockRegistryHive = $null
    )

    $fullExe = [IO.Path]::GetFullPath($ExecutablePath)
    if (-not (Test-Path -LiteralPath $fullExe -PathType Leaf)) {
        throw "Executable was not found for startup registration: $fullExe"
    }
    Assert-V02PathNoReparse -Path $fullExe

    $commandValue = '"' + $fullExe + '"'

    if ($null -ne $MockRegistryHive) {
        $MockRegistryHive[$ValueName] = $commandValue
        return
    }

    $keyPath = Get-V02StartupRegistryKeyPath
    if (-not (Test-Path -LiteralPath $keyPath)) {
        New-Item -Path $keyPath -Force | Out-Null
    }
    Set-ItemProperty -Path $keyPath -Name $ValueName -Value $commandValue -Type String | Out-Null
}

function Unregister-V02UserStartup {
    param(
        [string]$ValueName = 'HerdrOps',
        [hashtable]$MockRegistryHive = $null
    )

    if ($null -ne $MockRegistryHive) {
        if ($MockRegistryHive.ContainsKey($ValueName)) {
            $MockRegistryHive.Remove($ValueName)
        }
        return
    }

    $keyPath = Get-V02StartupRegistryKeyPath
    if (Test-Path -LiteralPath $keyPath) {
        $existing = Get-ItemProperty -Path $keyPath -Name $ValueName -ErrorAction SilentlyContinue
        if ($null -ne $existing -and $null -ne $existing.$ValueName) {
            Remove-ItemProperty -Path $keyPath -Name $ValueName -ErrorAction SilentlyContinue | Out-Null
        }
    }
}

function Test-V02UserStartupRegistered {
    param(
        [string]$ValueName = 'HerdrOps',
        [hashtable]$MockRegistryHive = $null
    )

    if ($null -ne $MockRegistryHive) {
        return ($MockRegistryHive.ContainsKey($ValueName) -and -not [string]::IsNullOrWhiteSpace($MockRegistryHive[$ValueName]))
    }

    $keyPath = Get-V02StartupRegistryKeyPath
    if (Test-Path -LiteralPath $keyPath) {
        $existing = Get-ItemProperty -Path $keyPath -Name $ValueName -ErrorAction SilentlyContinue
        if ($null -ne $existing -and -not [string]::IsNullOrWhiteSpace($existing.$ValueName)) {
            return $true
        }
    }
    return $false
}

function Get-V02UserStartupState {
    param(
        [string]$ValueName = 'HerdrOps',
        [hashtable]$MockRegistryHive = $null
    )

    if ($null -ne $MockRegistryHive) {
        return [pscustomobject][ordered]@{
            Exists = $MockRegistryHive.ContainsKey($ValueName)
            Value = $(if ($MockRegistryHive.ContainsKey($ValueName)) { $MockRegistryHive[$ValueName] } else { $null })
            Kind = 'String'
        }
    }

    $keyPath = Get-V02StartupRegistryKeyPath
    if (-not (Test-Path -LiteralPath $keyPath)) {
        return [pscustomobject][ordered]@{ Exists = $false; Value = $null; Kind = 'String' }
    }
    $key = Get-Item -LiteralPath $keyPath
    try {
        if (-not ($key.GetValueNames() -contains $ValueName)) {
            return [pscustomobject][ordered]@{ Exists = $false; Value = $null; Kind = 'String' }
        }
        return [pscustomobject][ordered]@{
            Exists = $true
            Value = $key.GetValue($ValueName, $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
            Kind = [string]$key.GetValueKind($ValueName)
        }
    } finally {
        $key.Dispose()
    }
}

function Restore-V02UserStartupState {
    param(
        [Parameter(Mandatory = $true)]$State,
        [string]$ValueName = 'HerdrOps',
        [hashtable]$MockRegistryHive = $null
    )

    if (-not [bool]$State.Exists) {
        Unregister-V02UserStartup -ValueName $ValueName -MockRegistryHive $MockRegistryHive
        return
    }
    if ($null -ne $MockRegistryHive) {
        $MockRegistryHive[$ValueName] = $State.Value
        return
    }
    $keyPath = Get-V02StartupRegistryKeyPath
    if (-not (Test-Path -LiteralPath $keyPath)) { New-Item -Path $keyPath -Force | Out-Null }
    $key = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey('Software\Microsoft\Windows\CurrentVersion\Run', $true)
    if ($null -eq $key) { throw 'Could not open the current-user Run registry key for exact state restoration.' }
    try {
        $kind = [Microsoft.Win32.RegistryValueKind]([Enum]::Parse([Microsoft.Win32.RegistryValueKind], [string]$State.Kind, $false))
        $key.SetValue($ValueName, $State.Value, $kind)
    } finally {
        $key.Dispose()
    }
}

function Build-V02PackageIdentityReceiptObject {
    param(
        [Parameter(Mandatory = $true)]$Profile,
        [Parameter(Mandatory = $true)][string]$RepositoryRoot,
        [Parameter(Mandatory = $true)][string]$ProfilePath,
        [Parameter(Mandatory = $true)][string]$ArchivePath,
        [Parameter(Mandatory = $true)][string]$PackageRoot
    )

    $repo = [IO.Path]::GetFullPath($RepositoryRoot)
    $profileFullPath = [IO.Path]::GetFullPath($ProfilePath)
    $archiveFullPath = [IO.Path]::GetFullPath($ArchivePath)
    $packageRootFullPath = [IO.Path]::GetFullPath($PackageRoot)

    $gitId = Get-V02GitIdentity -RepositoryRoot $repo -RequireClean
    $profileId = Get-V02PreparationProfileIdentity -Path $profileFullPath -ExpectedProfile $Profile -RepositoryRoot $repo
    $archiveStable = Get-V02StableFileIdentity -Path $archiveFullPath

    $manifestPath = Join-Path $packageRootFullPath $Profile.packageManifestFileName
    $manifestResult = Read-V02PackageManifest -Path $manifestPath -Profile $Profile -RepositoryRoot $repo
    $manifest = $manifestResult.Manifest
    $manifestStable = $manifestResult.Stable

    $inventory = Get-V02PackageRootInventory -PackageRoot $packageRootFullPath -ExcludeRelativePath @([string]$Profile.packageManifestFileName)
    $appEntry = @($inventory.Entries | Where-Object { $_.Path -ceq [string]$Profile.components.appRelativePath })
    $coreEntry = @($inventory.Entries | Where-Object { $_.Path -ceq [string]$Profile.components.coreRelativePath })

    if ($appEntry.Count -ne 1) {
        throw "Package root is missing component '$($Profile.components.appRelativePath)'."
    }
    if ($coreEntry.Count -ne 1) {
        throw "Package root is missing component '$($Profile.components.coreRelativePath)'."
    }

    return [pscustomobject][ordered]@{
        schemaVersion = 1
        profileId = [string]$Profile.profileId
        issue = 149
        packageVersion = '0.2.0'
        runtimeIdentifier = 'win-x64'
        source = [pscustomobject][ordered]@{
            commitSha = [string]$gitId.CommitSha
            treeSha = [string]$gitId.TreeSha
        }
        profile = [pscustomobject][ordered]@{
            id = [string]$profileId.Id
            relativePath = [string]$profileId.RelativePath
            bytes = [int64]$profileId.Bytes
            fileSha256 = [string]$profileId.FileSha256
            canonicalSha256 = [string]$profileId.CanonicalSha256
        }
        archive = [pscustomobject][ordered]@{
            relativePath = [string]$Profile.archiveFileName
            fileName = [string]$Profile.archiveFileName
            bytes = [int64]$archiveStable.Length
            sha256 = [string]$archiveStable.Sha256
        }
        packageManifest = [pscustomobject][ordered]@{
            fileName = [string]$Profile.packageManifestFileName
            bytes = [int64]$manifestStable.Length
            sha256 = [string]$manifestStable.Sha256
            contentSha256 = [string]$manifest.contentSha256
            fileCount = [int]$manifest.fileCount
            totalBytes = [int64]$manifest.totalBytes
        }
        components = [pscustomobject][ordered]@{
            app = [pscustomobject][ordered]@{
                relativePath = [string]$Profile.components.appRelativePath
                bytes = [int64]$appEntry[0].Length
                sha256 = [string]$appEntry[0].Sha256
            }
            core = [pscustomobject][ordered]@{
                relativePath = [string]$Profile.components.coreRelativePath
                bytes = [int64]$coreEntry[0].Length
                sha256 = [string]$coreEntry[0].Sha256
            }
        }
        referenceHost = [pscustomobject][ordered]@{
            profileId = [string]$Profile.referenceHost.profileId
            profileSha256 = [string]$Profile.referenceHost.profileSha256
        }
        renderer = [pscustomobject][ordered]@{
            policy = [string]$Profile.renderer.policy
            wpfProcessRenderMode = [string]$Profile.renderer.wpfProcessRenderMode
        }
        evidenceBoundary = [pscustomobject][ordered]@{
            evidenceClass = 'PackagedCompatibilityPreparation'
            runtimeUse = 'not-used'
            actualHerdrUsed = $false
            runtimeCredit = 'NOT CLAIMED'
            releaseCredit = 'NOT CLAIMED'
        }
    }
}

function Extract-V02PackageArchive {
    param(
        [Parameter(Mandatory = $true)][string]$ArchivePath,
        [Parameter(Mandatory = $true)][string]$DestinationPath
    )

    $archiveFullPath = [IO.Path]::GetFullPath($ArchivePath)
    $destinationFullPath = [IO.Path]::GetFullPath($DestinationPath)

    if (-not (Test-Path -LiteralPath $archiveFullPath -PathType Leaf)) {
        throw "Package archive was not found: $archiveFullPath"
    }
    Assert-V02PathNoReparse -Path $archiveFullPath

    if (-not (Test-Path -LiteralPath $destinationFullPath -PathType Container)) {
        New-Item -ItemType Directory -Path $destinationFullPath -Force | Out-Null
    }
    Assert-V02TreeNoReparse -Path $destinationFullPath

    Add-Type -AssemblyName System.IO.Compression
    $stream = $null
    $zip = $null
    try {
        $stream = [IO.File]::Open($archiveFullPath, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
        $zip = New-Object IO.Compression.ZipArchive($stream, [IO.Compression.ZipArchiveMode]::Read, $false)
        foreach ($entry in $zip.Entries) {
            $name = [string]$entry.FullName
            if ([string]::IsNullOrWhiteSpace($name) -or $name -match '(^/|\\|(^|/)\.\.(/|$)|/$)') {
                throw "Archive contains an unsafe entry path: $name"
            }
            $targetPath = [IO.Path]::Combine($destinationFullPath, $name.Replace('/', '\'))
            $targetParent = [IO.Path]::GetDirectoryName($targetPath)
            if (-not (Test-Path -LiteralPath $targetParent -PathType Container)) {
                New-Item -ItemType Directory -Path $targetParent -Force | Out-Null
            }
            Assert-V02PathNoReparse -Path $targetParent

            $entryStream = $null
            $outStream = $null
            try {
                $entryStream = $entry.Open()
                $outStream = [IO.File]::Open($targetPath, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
                $entryStream.CopyTo($outStream)
            } finally {
                if ($null -ne $outStream) { $outStream.Dispose() }
                if ($null -ne $entryStream) { $entryStream.Dispose() }
            }
            Assert-V02PathNoReparse -Path $targetPath
        }
    } finally {
        if ($null -ne $zip) { $zip.Dispose() }
        if ($null -ne $stream) { $stream.Dispose() }
    }
}

function Assert-V02UnsignedLocalShaPolicy {
    param(
        [Parameter(Mandatory = $true)][string]$PackageRoot,
        [Parameter(Mandatory = $true)]$Identity,
        [Parameter(Mandatory = $true)]$Profile,
        [Parameter(Mandatory = $true)][string]$RepositoryRoot
    )

    $root = [IO.Path]::GetFullPath($PackageRoot)
    Assert-V02TreeNoReparse -Path $root

    $manifestPath = Join-Path $root $Profile.packageManifestFileName
    if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
        throw "Package manifest was not found in payload: $manifestPath"
    }

    $manifestResult = Read-V02PackageManifest -Path $manifestPath -Profile $Profile -RepositoryRoot $RepositoryRoot
    $manifest = $manifestResult.Manifest
    $manifestStable = $manifestResult.Stable

    if ($manifestStable.Sha256 -cne $Identity.packageManifest.sha256 -or
        $manifestStable.Length -ne [int64]$Identity.packageManifest.bytes -or
        $manifest.contentSha256 -cne $Identity.packageManifest.contentSha256 -or
        [int64]$manifest.fileCount -ne [int64]$Identity.packageManifest.fileCount -or
        [int64]$manifest.totalBytes -ne [int64]$Identity.packageManifest.totalBytes) {
        throw 'Package manifest does not match the package identity receipt (tamper detected).'
    }

    $inventory = Get-V02PackageRootInventory -PackageRoot $root -ExcludeRelativePath @([string]$Profile.packageManifestFileName)
    Assert-V02InventoryEqual -Expected $manifestResult.Entries -Actual $inventory.Entries -Description 'Payload and manifest'

    $appEntry = @($inventory.Entries | Where-Object { $_.Path -ceq [string]$Profile.components.appRelativePath })
    $coreEntry = @($inventory.Entries | Where-Object { $_.Path -ceq [string]$Profile.components.coreRelativePath })

    if ($appEntry.Count -ne 1 -or
        $appEntry[0].Sha256 -cne $Identity.components.app.sha256 -or
        $appEntry[0].Length -ne [int64]$Identity.components.app.bytes) {
        throw 'App executable in payload does not match the package identity receipt (tamper detected).'
    }

    if ($coreEntry.Count -ne 1 -or
        $coreEntry[0].Sha256 -cne $Identity.components.core.sha256 -or
        $coreEntry[0].Length -ne [int64]$Identity.components.core.bytes) {
        throw 'Core executable in payload does not match the package identity receipt (tamper detected).'
    }

    return $inventory
}

function Get-V02DirectoryHashes {
    param(
        [Parameter(Mandatory = $true)][string]$Path
    )

    $fullPath = [IO.Path]::GetFullPath($Path)
    if (-not (Test-Path -LiteralPath $fullPath -PathType Container)) {
        return @{}
    }
    Assert-V02TreeNoReparse -Path $fullPath

    $hashes = @{}
    foreach ($item in @(Get-ChildItem -LiteralPath $fullPath -Recurse -Force -File | Sort-Object FullName)) {
        if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw "Directory contains a reparse point: $($item.FullName)"
        }
        $rel = Get-SafeRelativePath -RootPath $fullPath -Path $item.FullName
        $stable = Get-V02StableFileIdentity -Path $item.FullName
        $hashes[$rel] = $stable.Sha256
    }
    return $hashes
}

function Assert-V02UserDataRetained {
    param(
        [Parameter(Mandatory = $true)][string]$UserDataRoot,
        [Parameter(Mandatory = $true)][hashtable]$ExpectedHashes
    )

    $fullPath = [IO.Path]::GetFullPath($UserDataRoot)
    if ($ExpectedHashes.Count -eq 0) {
        return
    }

    if (-not (Test-Path -LiteralPath $fullPath -PathType Container)) {
        throw "User data root was expected to be retained, but was missing: $fullPath"
    }
    Assert-V02TreeNoReparse -Path $fullPath

    $actualHashes = Get-V02DirectoryHashes -Path $fullPath
    if ($actualHashes.Count -ne $ExpectedHashes.Count) {
        throw "User data file count changed! Expected $($ExpectedHashes.Count), got $($actualHashes.Count)."
    }

    foreach ($key in $ExpectedHashes.Keys) {
        if (-not $actualHashes.ContainsKey($key)) {
            throw "User data file was deleted: $key"
        }
        if ($actualHashes[$key] -cne $ExpectedHashes[$key]) {
            throw "User data file was modified or corrupted: $key (expected $($ExpectedHashes[$key]), got $($actualHashes[$key]))"
        }
    }
}

function Copy-V02StableFile {
    param(
        [Parameter(Mandatory = $true)][string]$Source,
        [Parameter(Mandatory = $true)][string]$Destination
    )

    $sourceFullPath = [IO.Path]::GetFullPath($Source)
    if (-not (Test-Path -LiteralPath $sourceFullPath -PathType Leaf)) { throw "Stable-copy source was not found: $sourceFullPath" }
    Assert-V02PathNoReparse -Path $sourceFullPath
    $destinationFullPath = [IO.Path]::GetFullPath($Destination)
    $parent = Split-Path -Path $destinationFullPath -Parent
    if (-not (Test-Path -LiteralPath $parent -PathType Container)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }
    Assert-V02PathNoReparse -Path $parent
    $parentLease = Open-V02DirectoryMutationLease -Path $parent
    $sourceStream = $null
    $destinationStream = $null
    try {
        $sourceStream = [IO.File]::Open($sourceFullPath,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read)
        $sourceHandleIdentity = Get-V02HandleIdentity -Handle $sourceStream.SafeFileHandle -Context 'stable-copy source'
        $null = Assert-V02SameHandleIdentity -Handle $sourceStream.SafeFileHandle -Expected $sourceHandleIdentity -ExpectedPath $sourceFullPath -Context 'stable-copy source' -RequireSingleLink
        if (Test-Path -LiteralPath $destinationFullPath) {
            throw "Refusing to overwrite stable-copy destination: $destinationFullPath"
        }
    # FileMode.CreateNew is the no-clobber boundary.  A hostile file or hardlink
    # appearing after the Test-Path preflight must make the atomic create fail;
    # WriteAllBytes/Create would otherwise truncate that unowned object.
        $destinationStream = [IO.File]::Open($destinationFullPath,[IO.FileMode]::CreateNew,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
        $destinationHandleIdentity = Get-V02HandleIdentity -Handle $destinationStream.SafeFileHandle -Context 'stable-copy destination'
        $null = Assert-V02SameHandleIdentity -Handle $destinationStream.SafeFileHandle -Expected $destinationHandleIdentity -ExpectedPath $destinationFullPath -Context 'stable-copy destination' -RequireSingleLink
        $buffer = New-Object byte[] 131072
        while (($read = $sourceStream.Read($buffer,0,$buffer.Length)) -gt 0) {
            $destinationStream.Write($buffer,0,$read)
        }
        $destinationStream.Flush($true)
        $null = Assert-V02SameHandleIdentity -Handle $sourceStream.SafeFileHandle -Expected $sourceHandleIdentity -ExpectedPath $sourceFullPath -Context 'stable-copy source' -RequireSingleLink
        $null = Assert-V02SameHandleIdentity -Handle $destinationStream.SafeFileHandle -Expected $destinationHandleIdentity -ExpectedPath $destinationFullPath -Context 'stable-copy destination' -RequireSingleLink
        $sourceStream.Position = 0; $destinationStream.Position = 0
        $sha = [Security.Cryptography.SHA256]::Create()
        try { $sourceSha = ([BitConverter]::ToString($sha.ComputeHash($sourceStream))).Replace('-','') } finally { $sha.Dispose() }
        $sha = [Security.Cryptography.SHA256]::Create()
        try { $destinationSha = ([BitConverter]::ToString($sha.ComputeHash($destinationStream))).Replace('-','') } finally { $sha.Dispose() }
        if ($sourceStream.Length -ne $destinationStream.Length -or $sourceSha -cne $destinationSha) {
            throw "Stable copy did not preserve source bytes: $Source"
        }
        return [pscustomobject][ordered]@{Path=$destinationFullPath;Length=[int64]$destinationStream.Length;Sha256=$destinationSha;VolumeSerialNumber=$destinationHandleIdentity.VolumeSerialNumber;FileId=$destinationHandleIdentity.FileId;LinkCount=$destinationHandleIdentity.LinkCount}
    }
    finally {
        if ($null -ne $destinationStream) { $destinationStream.Dispose() }
        if ($null -ne $sourceStream) { $sourceStream.Dispose() }
        $null = Assert-V02SameHandleIdentity -Handle $parentLease -Expected $parentLease.V02Identity -ExpectedPath $parentLease.V02Path -Context 'stable-copy parent' -RequireSingleLink
        $parentLease.Dispose()
    }
}

function Copy-V02StableTreeForInstall {
    param(
        [Parameter(Mandatory = $true)][string]$Source,
        [Parameter(Mandatory = $true)][string]$Destination,
        [Parameter(Mandatory = $true)][string]$InstallRoot
    )

    $sourceRoot = [IO.Path]::GetFullPath($Source)
    $destinationRoot = [IO.Path]::GetFullPath($Destination)
    $install = [IO.Path]::GetFullPath($InstallRoot).TrimEnd('\','/')
    $installParent = (Split-Path -Path $install -Parent).TrimEnd('\','/')
    $installName = [IO.Path]::GetFileName($install)
    if (-not [StringComparer]::OrdinalIgnoreCase.Equals((Split-Path -Path $destinationRoot -Parent).TrimEnd('\','/'), $installParent) -or
        [IO.Path]::GetFileName($destinationRoot) -notmatch ('^\.' + [regex]::Escape($installName) + '\.staging-[0-9a-f]{32}$')) {
        throw "Install payload destination is not the exact canonical staging sibling for '$install': $destinationRoot"
    }
    if (-not (Test-Path -LiteralPath $sourceRoot -PathType Container)) { throw "Install payload source was not found: $sourceRoot" }
    Assert-V02TreeNoReparse -Path $sourceRoot
    Assert-V02PathNoReparse -Path $installParent
    if (-not (Test-Path -LiteralPath $destinationRoot -PathType Container)) { throw "Install staging destination was not pre-created: $destinationRoot" }
    Assert-V02TreeNoReparse -Path $destinationRoot
    foreach ($item in @(Get-ChildItem -LiteralPath $sourceRoot -Recurse -Force -File | Sort-Object FullName)) {
        $relative = Get-SafeRelativePath -RootPath $sourceRoot -Path $item.FullName
        $null = Copy-V02StableFile -Source $item.FullName -Destination (Join-Path $destinationRoot $relative)
    }
}

function Merge-V02PublishedTrees {
    param(
        [Parameter(Mandatory = $true)][string[]]$SourceRoots,
        [Parameter(Mandatory = $true)][string]$DestinationRoot
    )

    New-Item -ItemType Directory -Path $DestinationRoot -Force | Out-Null
    foreach ($sourceRoot in $SourceRoots) {
        Assert-V02TreeNoReparse -Path $sourceRoot
        foreach ($item in @(Get-ChildItem -LiteralPath $sourceRoot -Recurse -Force -File | Sort-Object FullName)) {
            $relative = Get-SafeRelativePath -RootPath $sourceRoot -Path $item.FullName
            $destination = Join-Path $DestinationRoot $relative
            $parent = Split-Path -Path $destination -Parent
            if (-not (Test-Path -LiteralPath $parent -PathType Container)) {
                New-Item -ItemType Directory -Path $parent -Force | Out-Null
            }
            if (Test-Path -LiteralPath $destination -PathType Leaf) {
                $sourceId = Get-V02StableFileIdentity -Path $item.FullName
                $destinationId = Get-V02StableFileIdentity -Path $destination
                if ($sourceId.Length -ne $destinationId.Length -or $sourceId.Sha256 -cne $destinationId.Sha256) {
                    throw "App/Core publish outputs collide with different bytes at '$relative'."
                }
                continue
            }
            $null = Copy-V02StableFile -Source $item.FullName -Destination $destination
        }
    }
    Assert-V02TreeNoReparse -Path $DestinationRoot
}

function Assert-V02CompleteInstalledBinding {
    param(
        [Parameter(Mandatory = $true)][string]$InstallRoot,
        [Parameter(Mandatory = $true)]$Profile,
        [Parameter(Mandatory = $true)][string]$ProfilePath,
        [Parameter(Mandatory = $true)][string]$RepositoryRoot,
        [Parameter(Mandatory = $true)][string]$WorkRoot,
        [string]$ExpectedInstallRoot = $InstallRoot
    )

    $root = [IO.Path]::GetFullPath($InstallRoot)
    $stateInstallRoot = [IO.Path]::GetFullPath($ExpectedInstallRoot)
    Assert-V02TreeNoReparse -Path $root
    $receiptPath = Join-Path $root 'identity.json'
    $statePath = Join-Path $root 'install-state.json'
    foreach ($required in @($receiptPath, $statePath, (Join-Path $root $Profile.packageManifestFileName))) {
        if (-not (Test-Path -LiteralPath $required -PathType Leaf)) {
            throw "Existing installation is not completely identity-bound; missing: $required"
        }
    }
    $parsed = Read-V02CanonicalIdentityReceipt -Path $receiptPath -RepositoryRoot $RepositoryRoot
    $stateStable = Get-V02StableFileIdentity -Path $statePath -IncludeBytes
    $stateDoc = ConvertFrom-V02StrictBytes -Bytes $stateStable.Bytes -Description 'v0.2 install state'
    $state = $stateDoc.Value
    foreach ($name in @('productId','packageVersion','runtimeIdentifier','receiptSha256','installRoot','userDataRoot','startupRegistered','autoUpdate')) {
        if (-not ($state.PSObject.Properties.Name -ccontains $name)) { throw "Install state is missing '$name'." }
    }
    if ([string]$state.productId -cne 'HerdrOps' -or [string]$state.packageVersion -cne '0.2.0' -or
        [string]$state.runtimeIdentifier -cne 'win-x64' -or [string]$state.receiptSha256 -cne $parsed.ReceiptSha256 -or
        -not [StringComparer]::OrdinalIgnoreCase.Equals([IO.Path]::GetFullPath([string]$state.installRoot), $stateInstallRoot)) {
        throw 'Existing installation state does not exactly bind this HerdrOps install root and receipt.'
    }

    $payload = Join-Path $WorkRoot ('bound-payload-' + [Guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $payload -Force | Out-Null
    foreach ($item in @(Get-ChildItem -LiteralPath $root -Recurse -Force -File | Sort-Object FullName)) {
        $relative = Get-SafeRelativePath -RootPath $root -Path $item.FullName
        if ($relative -ceq 'identity.json' -or $relative -ceq 'install-state.json') { continue }
        $null = Copy-V02StableFile -Source $item.FullName -Destination (Join-Path $payload $relative)
    }
    $archive = Join-Path $WorkRoot ([string]$Profile.archiveFileName)
    if (Test-Path -LiteralPath $archive) { throw "Binding archive destination already exists: $archive" }
    $null = New-DeterministicPackageArchive -PackageRoot $payload -ArchivePath $archive
    return Assert-V02PackageIdentity -Identity $parsed.Identity -Profile $Profile -RepositoryRoot $RepositoryRoot `
        -ArchivePath $archive -PackageRoot $payload -ProfilePath $ProfilePath `
        -ReceiptSha256 $parsed.ReceiptSha256 -CanonicalReceiptJson $parsed.CanonicalJson
}

function Remove-V02TransactionDirectory {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$ExpectedParent,
        $ExpectedIdentity = $null
    )
    $target = [IO.Path]::GetFullPath($Path).TrimEnd('\','/')
    $parent = [IO.Path]::GetFullPath($ExpectedParent).TrimEnd('\','/')
    if (-not [StringComparer]::OrdinalIgnoreCase.Equals((Split-Path -Path $target -Parent).TrimEnd('\','/'), $parent)) {
        throw "Transaction directory is outside its exact expected parent: $target"
    }
    if (-not (Test-Path -LiteralPath $target)) { return }
    if (-not (Test-Path -LiteralPath $target -PathType Container)) { throw "Transaction path is not a directory: $target" }
    $parentLease = Open-V02DirectoryMutationLease -Path $parent
    $targetLease = $null
    try {
        $targetLease = Open-V02DirectoryMutationLease -Path $target -ForDelete
        if ($null -ne $ExpectedIdentity -and ($targetLease.V02Identity.VolumeSerialNumber -cne $ExpectedIdentity.VolumeSerialNumber -or $targetLease.V02Identity.FileId -cne $ExpectedIdentity.FileId -or $targetLease.V02Identity.LinkCount -ne $ExpectedIdentity.LinkCount)) {
            throw 'Transaction cleanup target no longer equals the exact owned directory identity.'
        }
        $null = Assert-V02SameHandleIdentity -Handle $parentLease -Expected $parentLease.V02Identity -ExpectedPath $parent -Context 'cleanup parent' -RequireSingleLink
        $null = Assert-V02SameHandleIdentity -Handle $targetLease -Expected $targetLease.V02Identity -ExpectedPath $target -Context 'cleanup target' -RequireSingleLink
        Assert-V02TreeNoReparse -Path $target
        foreach ($child in @(Get-ChildItem -LiteralPath $target -Force)) {
            if (($child.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw "Cleanup refuses reparse descendant: $($child.FullName)" }
            if ($child.PSIsContainer) {
                Remove-V02TransactionDirectory -Path $child.FullName -ExpectedParent $target
            } else {
                $childLease = $null
                try {
                    $childLease = Open-V02FileDeletionLease -Path $child.FullName
                    $null = Assert-V02SameHandleIdentity -Handle $childLease -Expected $childLease.V02Identity -ExpectedPath $childLease.V02Path -Context 'cleanup file' -RequireSingleLink
                    if (($childLease.V02Identity.Attributes -band [uint32][IO.FileAttributes]::ReadOnly) -ne 0) {
                        $basic = New-Object HerdrOps.V02FileBasicInfo; $basic.FileAttributes = [uint32][IO.FileAttributes]::Normal
                        $basicSize = [Runtime.InteropServices.Marshal]::SizeOf([type][HerdrOps.V02FileBasicInfo])
                        if (-not [HerdrOps.V02DirectoryLeaseNative]::SetFileBasicInformationByHandle($childLease,0,[ref]$basic,[uint32]$basicSize)) { throw "Cleanup file read-only normalization failed (Win32 $([Runtime.InteropServices.Marshal]::GetLastWin32Error()))." }
                    }
                    $disposition = New-Object HerdrOps.V02FileDispositionInfo
                    $disposition.DeleteFile = $true
                    if (-not [HerdrOps.V02DirectoryLeaseNative]::SetFileInformationByHandle($childLease,4,[ref]$disposition,4)) { throw "Cleanup file delete-by-handle failed (Win32 $([Runtime.InteropServices.Marshal]::GetLastWin32Error()))." }
                } finally { if ($null -ne $childLease) { $childLease.Dispose() } }
            }
        }
        $null = Assert-V02SameHandleIdentity -Handle $targetLease -Expected $targetLease.V02Identity -ExpectedPath $target -Context 'cleanup target' -RequireSingleLink
        if (@(Get-ChildItem -LiteralPath $target -Force).Count -ne 0) { throw "Cleanup target changed or is not empty: $target" }
        $disposition = New-Object HerdrOps.V02FileDispositionInfo
        $disposition.DeleteFile = $true
        if (-not [HerdrOps.V02DirectoryLeaseNative]::SetFileInformationByHandle($targetLease,4,[ref]$disposition,4)) { throw "Cleanup directory delete-by-handle failed (Win32 $([Runtime.InteropServices.Marshal]::GetLastWin32Error()))." }
    }
    finally {
        if ($null -ne $targetLease) { $targetLease.Dispose() }
        $null = Assert-V02SameHandleIdentity -Handle $parentLease -Expected $parentLease.V02Identity -ExpectedPath $parent -Context 'cleanup parent' -RequireSingleLink
        $parentLease.Dispose()
    }
    if (Test-Path -LiteralPath $target) { throw "Cleanup target remained after delete-by-handle: $target" }
}

# Override the shared packaging temp helpers for the v0.2 production path so
# every recursive cleanup is bound to the exact directory object created by
# this process, not merely to a reusable pathname.
$script:V02OwnedTempIdentities = @{}
function New-PackagingTempDirectory {
    param([Parameter(Mandatory = $true)][string]$Prefix)
    if ($Prefix -notmatch '^HerdrOps-[A-Za-z0-9-]+-$') { throw "Invalid temporary directory prefix: $Prefix" }
    $tempRoot = Normalize-ComparablePath -Path ([IO.Path]::GetTempPath())
    for ($attempt=0;$attempt -lt 10;$attempt++) {
        $candidate = Join-Path $tempRoot ($Prefix + [Guid]::NewGuid().ToString('N'))
        Assert-SafeDestination -Path $candidate -AllowTempChild | Out-Null
        if (-not (Test-Path -LiteralPath $candidate)) {
            [IO.Directory]::CreateDirectory($candidate) | Out-Null
            $full = Normalize-ComparablePath -Path $candidate
            $script:V02OwnedTempIdentities[$full] = Get-V02DirectoryPathIdentity $full 'created v0.2 temp directory'
            return $full
        }
    }
    throw 'Could not create a unique packaging temp directory.'
}

function Remove-PackagingTempDirectory {
    param([Parameter(Mandatory = $true)][string]$Path)
    $full = Normalize-ComparablePath -Path $Path
    $tempRoot = Normalize-ComparablePath -Path ([IO.Path]::GetTempPath())
    if (-not (Test-PathWithin -ChildPath $full -RootPath $tempRoot) -or $full.Equals($tempRoot,[StringComparison]::OrdinalIgnoreCase) -or ([IO.Path]::GetFileName($full) -notmatch '^HerdrOps-[A-Za-z0-9-]+-[0-9a-f]{32}$')) { throw "Refusing to remove a non-owned packaging temp directory: $full" }
    if (-not $script:V02OwnedTempIdentities.ContainsKey($full)) { throw "Refusing to remove a temp directory without its creation identity: $full" }
    $identity = $script:V02OwnedTempIdentities[$full]
    if (Test-Path -LiteralPath $full) { Remove-V02TransactionDirectory -Path $full -ExpectedParent (Split-Path $full -Parent) -ExpectedIdentity $identity }
    $script:V02OwnedTempIdentities.Remove($full)
}
