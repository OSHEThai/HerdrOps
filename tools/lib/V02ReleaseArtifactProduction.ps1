#requires -Version 5.1

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'V02ReferenceHostProfile.ps1')

$script:V02ReleaseArtifactRepository = 'OSHEThai/HerdrOps'
$script:V02ReleaseArtifactApiBase = 'https://api.github.com'
$script:V02ReleaseArtifactMilestoneNumber = 2
$script:V02ReleaseArtifactMilestoneTitle = 'v0.2.0'
$script:V02ReleaseArtifactIssueSet = @(6,7,8,9,10,11,54,63,149)
$script:V02ReleaseArtifactPreclosureOpenIssues = @(11,149)
$script:V02ReleaseArtifactRequiredCheck = 'build-test'
$script:V02ReleaseArtifactOwnerLogin = 'yutthaphon'
$script:V02ReleaseArtifactReviewRole = 'IndependentAgentReviewer'
if($null-eq(Get-Variable V02ReleaseArtifactGitHubInvokerForTest -Scope Script -ErrorAction SilentlyContinue)){$script:V02ReleaseArtifactGitHubInvokerForTest = $null}
if($null-eq(Get-Variable V02ReleaseArtifactCheckInvokerForTest -Scope Script -ErrorAction SilentlyContinue)){$script:V02ReleaseArtifactCheckInvokerForTest = $null}
if($null-eq(Get-Variable V02ReleaseArtifactBeforeCommitHookForTest -Scope Script -ErrorAction SilentlyContinue)){$script:V02ReleaseArtifactBeforeCommitHookForTest = $null}

if ($null -eq ('HerdrOps.V02ReleaseArtifactNative' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Text;
using Microsoft.Win32.SafeHandles;
namespace HerdrOps {
  public static class V02ReleaseArtifactNative {
    [StructLayout(LayoutKind.Sequential)] private struct Info { public uint Attributes; public System.Runtime.InteropServices.ComTypes.FILETIME Creation; public System.Runtime.InteropServices.ComTypes.FILETIME Access; public System.Runtime.InteropServices.ComTypes.FILETIME Write; public uint Volume; public uint SizeHigh; public uint SizeLow; public uint Links; public uint IndexHigh; public uint IndexLow; }
    [DllImport("kernel32.dll", SetLastError=true)] private static extern bool GetFileInformationByHandle(SafeFileHandle h, out Info value);
    [DllImport("kernel32.dll", SetLastError=true)] private static extern bool SetFileInformationByHandle(SafeFileHandle h, int kind, IntPtr value, uint size);
    [StructLayout(LayoutKind.Sequential)] private struct IoStatusBlock { public IntPtr Status; public IntPtr Information; }
    [DllImport("ntdll.dll")] private static extern int NtSetInformationFile(SafeFileHandle h,out IoStatusBlock io,IntPtr value,uint size,int kind);
    [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)] private static extern SafeFileHandle CreateFile(string path,uint access,uint share,IntPtr security,uint creation,uint flags,IntPtr template);
    [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)] private static extern uint GetFinalPathNameByHandle(SafeFileHandle h,StringBuilder path,uint length,uint flags);
    public static SafeFileHandle OpenDirectory(string path,bool deleteAccess) { const uint DELETE=0x10000,GENERIC_READ=0x80000000,GENERIC_WRITE=0x40000000,SHARE_READ=1,SHARE_WRITE=2,OPEN=3,BACKUP=0x02000000,REPARSE=0x00200000; var h=CreateFile(path,GENERIC_READ|GENERIC_WRITE|(deleteAccess?DELETE:0),SHARE_READ|SHARE_WRITE,IntPtr.Zero,OPEN,BACKUP|REPARSE,IntPtr.Zero); if(h.IsInvalid){int e=Marshal.GetLastWin32Error();h.Dispose();throw new Win32Exception(e,"Release-artifact directory lease failed");} return h; }
    public static SafeFileHandle CreatePublicationFile(string path) { const uint READ=0x80000000,WRITE=0x40000000,DELETE=0x10000,SHARE_READ=1,CREATE_NEW=1,NORMAL=0x80,REPARSE=0x00200000; var h=CreateFile(path,READ|WRITE|DELETE,SHARE_READ,IntPtr.Zero,CREATE_NEW,NORMAL|REPARSE,IntPtr.Zero); if(h.IsInvalid){int e=Marshal.GetLastWin32Error();h.Dispose();throw new Win32Exception(e,"Release-artifact staging file creation failed");} return h; }
    public static string FinalPath(SafeFileHandle h) { var b=new StringBuilder(32768);uint n=GetFinalPathNameByHandle(h,b,(uint)b.Capacity,0);if(n==0||n>=b.Capacity)throw new Win32Exception(Marshal.GetLastWin32Error(),"Release-artifact final-path query failed");string v=b.ToString();if(v.StartsWith(@"\\?\UNC\",StringComparison.OrdinalIgnoreCase))return @"\\"+v.Substring(8);if(v.StartsWith(@"\\?\",StringComparison.OrdinalIgnoreCase))return v.Substring(4);return v; }
    public static string Identity(SafeFileHandle h) { Info v;if(!GetFileInformationByHandle(h,out v))throw new Win32Exception(Marshal.GetLastWin32Error(),"Release-artifact identity query failed");return v.Volume.ToString("X8")+":"+v.IndexHigh.ToString("X8")+v.IndexLow.ToString("X8"); }
    public static void RenameRelative(SafeFileHandle source,SafeFileHandle parent,string leaf) { if(String.IsNullOrWhiteSpace(leaf)||leaf.IndexOfAny(new[]{'\\','/'})>=0)throw new ArgumentException("Destination must be one root-relative leaf.");byte[] name=Encoding.Unicode.GetBytes(leaf);int ro=IntPtr.Size==8?8:4,lo=IntPtr.Size==8?16:8,no=IntPtr.Size==8?20:12,size=no+name.Length+2;IntPtr p=Marshal.AllocHGlobal(size);try{for(int i=0;i<size;i++)Marshal.WriteByte(p,i,0);Marshal.WriteIntPtr(p,ro,parent.DangerousGetHandle());Marshal.WriteInt32(p,lo,name.Length);Marshal.Copy(name,0,IntPtr.Add(p,no),name.Length);IoStatusBlock io;int status=NtSetInformationFile(source,out io,p,(uint)size,10);if(status!=0)throw new Win32Exception(status,"Held-handle root-relative rename failed with NTSTATUS 0x"+status.ToString("X8"));}finally{Marshal.FreeHGlobal(p);} }
    public static void Delete(SafeFileHandle h) { IntPtr p=Marshal.AllocHGlobal(4);try{Marshal.WriteInt32(p,1);if(!SetFileInformationByHandle(h,4,p,4))throw new Win32Exception(Marshal.GetLastWin32Error(),"Held-handle cleanup failed");}finally{Marshal.FreeHGlobal(p);} }
  }
}
'@
}

function Assert-V02ReleaseArtifactExactProperties {
    param($Value,[string[]]$Expected,[string]$Context)
    if($null-eq$Value){throw "$Context is missing."};$actual=@($Value.PSObject.Properties.Name)
    if($actual.Count-ne$Expected.Count){throw "$Context property count is invalid."}
    foreach($name in $Expected){if(-not($actual-ccontains$name)){throw "$Context omitted '$name'."}}
    foreach($name in $actual){if(-not($Expected-ccontains$name)){throw "$Context contains unexpected '$name'."}}
}

function Open-V02ReleaseArtifactDirectoryLease {
    param([string]$Path,[string]$Context,[switch]$AllowDelete)
    $full=[IO.Path]::GetFullPath($Path).TrimEnd([char[]]@('\','/'));$h=[HerdrOps.V02ReleaseArtifactNative]::OpenDirectory($full,[bool]$AllowDelete)
    try{$final=[IO.Path]::GetFullPath([HerdrOps.V02ReleaseArtifactNative]::FinalPath($h)).TrimEnd([char[]]@('\','/'));if($final-cne$full){throw "$Context final path changed."};[pscustomobject]@{Handle=$h;Path=$full;FinalPath=$final;Identity=[HerdrOps.V02ReleaseArtifactNative]::Identity($h);DeleteAccess=[bool]$AllowDelete}}catch{$h.Dispose();throw}
}

function Assert-V02ReleaseArtifactDirectoryLease {
    param($Lease,[string]$Context)
    if($null-eq$Lease-or$Lease.Handle.IsClosed-or$Lease.Handle.IsInvalid){throw "$Context lease is not held."}
    $heldPath=[IO.Path]::GetFullPath([HerdrOps.V02ReleaseArtifactNative]::FinalPath($Lease.Handle)).TrimEnd([char[]]@('\','/'));$heldIdentity=[HerdrOps.V02ReleaseArtifactNative]::Identity($Lease.Handle)
    if($heldPath-cne$Lease.FinalPath-or$heldIdentity-cne$Lease.Identity){throw "$Context held identity changed."}
}

function Open-V02ReleaseArtifactFileLease {
    param([string]$Path,[string]$Context,[switch]$AllowAncestorRename)
    $full=[IO.Path]::GetFullPath($Path);$share=[IO.FileShare]::Read;if($AllowAncestorRename){$share=$share-bor[IO.FileShare]::Delete};$stream=[IO.File]::Open($full,[IO.FileMode]::Open,[IO.FileAccess]::Read,$share)
    try{$bytes=New-Object byte[] $stream.Length;$offset=0;while($offset-lt$bytes.Length){$n=$stream.Read($bytes,$offset,$bytes.Length-$offset);if($n-le0){throw "$Context read ended early."};$offset+=$n};$stream.Position=0;[pscustomobject]@{Stream=$stream;Path=$full;Bytes=$bytes;Sha256=Get-V02ReleaseArtifactSha256Bytes $bytes;Identity=[HerdrOps.V02ReleaseArtifactNative]::Identity($stream.SafeFileHandle)}}catch{$stream.Dispose();throw}
}

function Assert-V02ReleaseArtifactFileLease {
    param($Lease,[string]$ExpectedPath,[string]$Context)
    if($null-eq$Lease-or$Lease.Stream.SafeFileHandle.IsClosed){throw "$Context lease is not held."};$final=[IO.Path]::GetFullPath([HerdrOps.V02ReleaseArtifactNative]::FinalPath($Lease.Stream.SafeFileHandle));if($final-cne[IO.Path]::GetFullPath($ExpectedPath)-or[HerdrOps.V02ReleaseArtifactNative]::Identity($Lease.Stream.SafeFileHandle)-cne$Lease.Identity){throw "$Context held path/identity changed."};$Lease.Stream.Position=0;$bytes=New-Object byte[] $Lease.Bytes.Length;$read=$Lease.Stream.Read($bytes,0,$bytes.Length);if($read-ne$bytes.Length-or(Get-V02ReleaseArtifactSha256Bytes $bytes)-cne$Lease.Sha256){throw "$Context held bytes changed."};$Lease.Stream.Position=0
}

function Close-V02ReleaseArtifactLease { param($Lease) if($null-ne$Lease){if($null-ne$Lease.PSObject.Properties['Stream']){$Lease.Stream.Dispose()}elseif($null-ne$Lease.PSObject.Properties['Handle']){$Lease.Handle.Dispose()}} }

function ConvertFrom-V02ReleaseArtifactCanonicalJsonBytes {
    param([byte[]]$Bytes,[string]$Context)
    if($Bytes.Length-ge3-and$Bytes[0]-eq0xEF-and$Bytes[1]-eq0xBB-and$Bytes[2]-eq0xBF){throw "$Context has a BOM."}
    try{$json=[Text.UTF8Encoding]::new($false,$true).GetString($Bytes)}catch{throw "$Context has malformed UTF-8."}
    Assert-V02NoDuplicateJsonProperties -Json $json -Source $Context
    try{
        # PowerShell 7.5 otherwise coerces ISO-8601 JSON strings to DateTime,
        # which changes the governed JSON type before the canonical-byte check.
        if((Get-Command ConvertFrom-Json).Parameters.ContainsKey('DateKind')){$value=$json|ConvertFrom-Json -DateKind String}else{$value=$json|ConvertFrom-Json}
    }catch{throw "$Context is malformed JSON."}
    if($null-eq$value-or$value-isnot[pscustomobject]){throw "$Context root must be an object."}
    if($json-cne((ConvertTo-V02Jcs $value)+"`n")){throw "$Context must be canonical JCS plus exactly one LF."}
    return $value
}

function Get-V02ReleaseArtifactSha256Bytes {
    param([Parameter(Mandatory=$true)][byte[]]$Bytes)
    $sha=[Security.Cryptography.SHA256]::Create()
    try { return ([BitConverter]::ToString($sha.ComputeHash($Bytes))).Replace('-','').ToUpperInvariant() }
    finally { $sha.Dispose() }
}

function Get-V02ReleaseArtifactSha256File {
    param([Parameter(Mandatory=$true)][string]$Path)
    $full=[IO.Path]::GetFullPath($Path)
    if(-not [IO.File]::Exists($full)){throw "Required file is missing: $full"}
    $stream=[IO.File]::Open($full,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read)
    try{$sha=[Security.Cryptography.SHA256]::Create();try{return ([BitConverter]::ToString($sha.ComputeHash($stream))).Replace('-','').ToUpperInvariant()}finally{$sha.Dispose()}}
    finally{$stream.Dispose()}
}

function Assert-V02ReleaseArtifactSha256 {
    param([Parameter(Mandatory=$true)][string]$Value,[Parameter(Mandatory=$true)][string]$Context)
    if($Value -cnotmatch '^[0-9A-F]{64}$'){throw "$Context must be uppercase SHA-256."}
    return $Value
}

function Assert-V02ReleaseArtifactGitId {
    param([Parameter(Mandatory=$true)][string]$Value,[Parameter(Mandatory=$true)][string]$Context)
    if($Value -cnotmatch '^[0-9a-f]{40}$'){throw "$Context must be a lowercase 40-character Git object id."}
    return $Value
}

function Assert-V02ReleaseArtifactSafeOutput {
    param([Parameter(Mandatory=$true)][string]$Path,[Parameter(Mandatory=$true)][string]$AllowedRoot)
    $root=[IO.Path]::GetFullPath($AllowedRoot).TrimEnd([char[]]@('\','/'))
    $full=[IO.Path]::GetFullPath($Path)
    $prefix=$root+[IO.Path]::DirectorySeparatorChar
    if(-not $full.StartsWith($prefix,[StringComparison]::OrdinalIgnoreCase)){throw "Output path must be contained by AllowedRoot: $root"}
    $parent=[IO.Path]::GetDirectoryName($full)
    if(-not[IO.Directory]::Exists($root)){throw "AllowedRoot must already exist: $root"}
    if(-not[IO.Directory]::Exists($parent)){throw "Output parent must already exist and be prevalidated: $parent"}
    $cursor=$parent
    while($cursor.StartsWith($root,[StringComparison]::OrdinalIgnoreCase)){
        $item=Get-Item -LiteralPath $cursor -Force
        if(($item.Attributes -band [IO.FileAttributes]::ReparsePoint)-ne 0){throw "Output ancestry cannot contain a reparse point: $cursor"}
        if([StringComparer]::OrdinalIgnoreCase.Equals($cursor,$root)){break}
        $cursor=[IO.Path]::GetDirectoryName($cursor)
    }
    if([IO.File]::Exists($full) -or [IO.Directory]::Exists($full)){throw "Output already exists; publication is no-clobber: $full"}
    return $full
}

function Assert-V02ReleaseArtifactPathOutsideRoot {
    param([Parameter(Mandatory=$true)][string]$Path,[Parameter(Mandatory=$true)][string]$Root,[Parameter(Mandatory=$true)][string]$Context)
    $full=[IO.Path]::GetFullPath($Path);$rootFull=[IO.Path]::GetFullPath($Root).TrimEnd([char[]]@('\','/'))
    if([StringComparer]::OrdinalIgnoreCase.Equals($full,$rootFull)-or$full.StartsWith($rootFull+[IO.Path]::DirectorySeparatorChar,[StringComparison]::OrdinalIgnoreCase)){throw "$Context must be outside $rootFull"}
    return $full
}

function Assert-V02ReleaseArtifactExistingFileWithinRoot {
    param([Parameter(Mandatory=$true)][string]$Path,[Parameter(Mandatory=$true)][string]$Root,[Parameter(Mandatory=$true)][string]$Context)
    $full=[IO.Path]::GetFullPath($Path);$rootFull=[IO.Path]::GetFullPath($Root).TrimEnd([char[]]@('\','/'))
    if(-not[IO.File]::Exists($full)){throw "$Context is missing: $full"}
    if(-not$full.StartsWith($rootFull+[IO.Path]::DirectorySeparatorChar,[StringComparison]::OrdinalIgnoreCase)){throw "$Context must be contained by $rootFull"}
    $cursor=[IO.Path]::GetDirectoryName($full)
    while($cursor.StartsWith($rootFull,[StringComparison]::OrdinalIgnoreCase)){$item=Get-Item -LiteralPath $cursor -Force;if(($item.Attributes-band[IO.FileAttributes]::ReparsePoint)-ne0){throw "$Context ancestry cannot contain a reparse point: $cursor"};if([StringComparer]::OrdinalIgnoreCase.Equals($cursor,$rootFull)){break};$cursor=[IO.Path]::GetDirectoryName($cursor)}
    return $full
}

function Publish-V02ReleaseArtifactJsonNoClobber {
    param([Parameter(Mandatory=$true)]$Value,[Parameter(Mandatory=$true)][string]$OutputPath,[Parameter(Mandatory=$true)][string]$AllowedRoot)
    $json=(ConvertTo-V02Jcs $Value)+"`n"
    $bytes=[Text.UTF8Encoding]::new($false,$true).GetBytes($json)
    Publish-V02ReleaseArtifactBytesNoClobber -Bytes $bytes -OutputPath $OutputPath -AllowedRoot $AllowedRoot
}

function Publish-V02ReleaseArtifactBytesNoClobber {
    param([Parameter(Mandatory=$true)][byte[]]$Bytes,[Parameter(Mandatory=$true)][string]$OutputPath,[Parameter(Mandatory=$true)][string]$AllowedRoot)
    $full=Assert-V02ReleaseArtifactSafeOutput -Path $OutputPath -AllowedRoot $AllowedRoot
    $root=[IO.Path]::GetFullPath($AllowedRoot).TrimEnd([char[]]@('\','/'));$parent=[IO.Path]::GetDirectoryName($full);$leaf=[IO.Path]::GetFileName($full)
    $rootLease=$null;$parentLease=$null;$handle=$null;$stream=$null;$stage=Join-Path $parent ('.'+$leaf+'.staging-'+[Guid]::NewGuid().ToString('N'))
    try{
        $rootLease=Open-V02ReleaseArtifactDirectoryLease $root 'Publication root';$parentLease=Open-V02ReleaseArtifactDirectoryLease $parent 'Publication parent'
        $handle=[HerdrOps.V02ReleaseArtifactNative]::CreatePublicationFile($stage);$stream=[IO.FileStream]::new($handle,[IO.FileAccess]::ReadWrite)
        $stream.Write($Bytes,0,$Bytes.Length);$stream.Flush($true);$stream.Position=0
        Assert-V02ReleaseArtifactDirectoryLease $rootLease 'Publication root';Assert-V02ReleaseArtifactDirectoryLease $parentLease 'Publication parent'
        if($null-ne$script:V02ReleaseArtifactBeforeCommitHookForTest){&$script:V02ReleaseArtifactBeforeCommitHookForTest $stage $parent $full}
        Assert-V02ReleaseArtifactDirectoryLease $rootLease 'Publication root after hook';Assert-V02ReleaseArtifactDirectoryLease $parentLease 'Publication parent after hook'
        if([IO.File]::Exists($full)-or[IO.Directory]::Exists($full)){throw "Output already exists; publication is no-clobber: $full"}
        [HerdrOps.V02ReleaseArtifactNative]::RenameRelative($handle,$parentLease.Handle,$leaf)
        if(([IO.Path]::GetFullPath([HerdrOps.V02ReleaseArtifactNative]::FinalPath($handle)))-cne$full){throw 'Held publication file did not reach the exact destination.'}
        return [pscustomobject][ordered]@{Path=$full;Bytes=[long]$Bytes.Length;Sha256=(Get-V02ReleaseArtifactSha256Bytes $Bytes)}
    } finally {
        if($null-ne$stream){$stream.Dispose();$stream=$null;$handle=$null}
        elseif($null-ne$handle){if([IO.File]::Exists($stage)){try{[HerdrOps.V02ReleaseArtifactNative]::Delete($handle)}catch{}};$handle.Dispose()}
        Close-V02ReleaseArtifactLease $parentLease;Close-V02ReleaseArtifactLease $rootLease
    }
}

function Publish-V02ReleaseArtifactSetNoClobber {
    param([string]$AllowedRoot,[string]$ReceiptOutputPath,[object[]]$Files,$ReceiptValue,[object[]]$InputLeases=@())
    $root=[IO.Path]::GetFullPath($AllowedRoot).TrimEnd([char[]]@('\','/'));$receiptFull=[IO.Path]::GetFullPath($ReceiptOutputPath);$finalDir=[IO.Path]::GetDirectoryName($receiptFull);$parent=[IO.Path]::GetDirectoryName($finalDir)
    if(-not$finalDir.StartsWith($root+[IO.Path]::DirectorySeparatorChar,[StringComparison]::OrdinalIgnoreCase)){throw 'Receipt set directory escaped AllowedRoot.'}
    if(-not[IO.Directory]::Exists($parent)){throw 'Receipt set parent must already exist.'};if(Test-Path -LiteralPath $finalDir){throw 'Receipt set destination already exists; publication is no-clobber.'}
    $stage=Join-Path $parent ('.'+[IO.Path]::GetFileName($finalDir)+'.staging-'+[Guid]::NewGuid().ToString('N'));[IO.Directory]::CreateDirectory($stage)|Out-Null
    $rootLease=$null;$parentLease=$null;$stageLease=$null;$outputLeases=New-Object Collections.Generic.List[object]
    try{
        $rootLease=Open-V02ReleaseArtifactDirectoryLease $root 'Set publication root';$parentLease=Open-V02ReleaseArtifactDirectoryLease $parent 'Set publication parent';$stageLease=Open-V02ReleaseArtifactDirectoryLease $stage 'Set staging directory' -AllowDelete
        foreach($file in $Files){$leaf=[string]$file.Name;if([IO.Path]::GetFileName($leaf)-cne$leaf){throw 'Set file name must be one leaf.'};$filePath=Join-Path $stage $leaf;[IO.File]::WriteAllBytes($filePath,[byte[]]$file.Bytes);[void]$outputLeases.Add((Open-V02ReleaseArtifactFileLease $filePath "Set output $leaf" -AllowAncestorRename))}
        $stagedReceipt=Join-Path $stage ([IO.Path]::GetFileName($receiptFull));[IO.File]::WriteAllBytes($stagedReceipt,[Text.UTF8Encoding]::new($false,$true).GetBytes((ConvertTo-V02Jcs $ReceiptValue)+"`n"));[void]$outputLeases.Add((Open-V02ReleaseArtifactFileLease $stagedReceipt 'Set receipt output' -AllowAncestorRename))
        foreach($lease in $InputLeases){Assert-V02ReleaseArtifactFileLease $lease $lease.Path 'Held publication input'}
        foreach($lease in $outputLeases){Assert-V02ReleaseArtifactFileLease $lease $lease.Path 'Held staged output'}
        Assert-V02ReleaseArtifactDirectoryLease $rootLease 'Set publication root';Assert-V02ReleaseArtifactDirectoryLease $parentLease 'Set publication parent';Assert-V02ReleaseArtifactDirectoryLease $stageLease 'Set staging directory'
        if($null-ne$script:V02ReleaseArtifactBeforeCommitHookForTest){&$script:V02ReleaseArtifactBeforeCommitHookForTest $stage $parent $finalDir}
        Assert-V02ReleaseArtifactDirectoryLease $rootLease 'Set publication root after hook';Assert-V02ReleaseArtifactDirectoryLease $parentLease 'Set publication parent after hook';Assert-V02ReleaseArtifactDirectoryLease $stageLease 'Set staging directory after hook'
        if(Test-Path -LiteralPath $finalDir){throw 'Receipt set destination appeared before commit.'}
        foreach($lease in $outputLeases){Assert-V02ReleaseArtifactFileLease $lease $lease.Path 'Held staged output at commit';Close-V02ReleaseArtifactLease $lease};$outputLeases.Clear()
        [HerdrOps.V02ReleaseArtifactNative]::RenameRelative($stageLease.Handle,$parentLease.Handle,[IO.Path]::GetFileName($finalDir));$stageLease.FinalPath=$finalDir
        return [pscustomobject]@{Path=$receiptFull;Directory=$finalDir;Sha256=Get-V02ReleaseArtifactSha256File $receiptFull}
    } finally {
        foreach($lease in $outputLeases){Close-V02ReleaseArtifactLease $lease}
        if($null-ne$stageLease-and(Test-Path -LiteralPath $stage)){foreach($child in @(Get-ChildItem -LiteralPath $stage -Force)){if(-not$child.PSIsContainer){[IO.File]::Delete($child.FullName)}};try{[HerdrOps.V02ReleaseArtifactNative]::Delete($stageLease.Handle)}catch{}}
        Close-V02ReleaseArtifactLease $stageLease;Close-V02ReleaseArtifactLease $parentLease;Close-V02ReleaseArtifactLease $rootLease
    }
}

function Invoke-V02ReleaseArtifactGitHubApi {
    param([Parameter(Mandatory=$true)][string]$RelativeUri,[Parameter(Mandatory=$true)][string]$TokenEnvironmentVariable,[ValidateSet('GET','POST')][string]$Method='GET',[string]$Body='')
    if($null-ne$script:V02ReleaseArtifactGitHubInvokerForTest){return & $script:V02ReleaseArtifactGitHubInvokerForTest $RelativeUri $Method $Body}
    $token=[Environment]::GetEnvironmentVariable($TokenEnvironmentVariable)
    if([string]::IsNullOrWhiteSpace($token)){throw "GitHub token environment variable '$TokenEnvironmentVariable' is missing."}
    $handler=[Net.Http.HttpClientHandler]::new();$client=[Net.Http.HttpClient]::new($handler)
    try{
        $client.BaseAddress=[Uri]$script:V02ReleaseArtifactApiBase
        $client.DefaultRequestHeaders.UserAgent.ParseAdd('HerdrOps-v0.2-release-artifact/1')
        $client.DefaultRequestHeaders.Accept.ParseAdd('application/vnd.github+json')
        $client.DefaultRequestHeaders.Authorization=[Net.Http.Headers.AuthenticationHeaderValue]::new('Bearer',$token)
        $response=$null
        try {
            if($Method-ceq'POST'){$content=[Net.Http.StringContent]::new($Body,[Text.Encoding]::UTF8,'application/json');try{$response=$client.PostAsync($RelativeUri,$content).GetAwaiter().GetResult()}finally{$content.Dispose()}}
            else{$response=$client.GetAsync($RelativeUri).GetAwaiter().GetResult()}
            $body=$response.Content.ReadAsStringAsync().GetAwaiter().GetResult()
            if(-not$response.IsSuccessStatusCode){throw "GitHub API $RelativeUri failed with HTTP $([int]$response.StatusCode)."}
            try{return $body|ConvertFrom-Json}
            catch{throw "GitHub API $RelativeUri returned invalid JSON."}
        } finally {if($null-ne$response){$response.Dispose()}}
    } finally {$client.Dispose();$handler.Dispose()}
}

function Get-V02ReleaseArtifactGitHubState {
    param([Parameter(Mandatory=$true)][string]$SourceCommit,[Parameter(Mandatory=$true)][string]$TokenEnvironmentVariable)
    Assert-V02ReleaseArtifactGitId $SourceCommit 'SourceCommit'|Out-Null
    $checks=Invoke-V02ReleaseArtifactGitHubApi -RelativeUri "/repos/$($script:V02ReleaseArtifactRepository)/commits/$SourceCommit/check-runs?per_page=100" -TokenEnvironmentVariable $TokenEnvironmentVariable
    $milestone=Invoke-V02ReleaseArtifactGitHubApi -RelativeUri "/repos/$($script:V02ReleaseArtifactRepository)/milestones/$($script:V02ReleaseArtifactMilestoneNumber)" -TokenEnvironmentVariable $TokenEnvironmentVariable
    $issues=Invoke-V02ReleaseArtifactGitHubApi -RelativeUri "/repos/$($script:V02ReleaseArtifactRepository)/issues?milestone=$($script:V02ReleaseArtifactMilestoneNumber)&state=all&per_page=100" -TokenEnvironmentVariable $TokenEnvironmentVariable
    $issueRows=@($issues|Where-Object{$null-eq$_.pull_request}|ForEach-Object{
        [pscustomobject][ordered]@{number=[int]$_.number;title=[string]$_.title;state=[string]$_.state;milestone=[pscustomobject][ordered]@{number=[int]$_.milestone.number;title=[string]$_.milestone.title}}
    }|Sort-Object number)
    $matchingChecks=@($checks.check_runs|Where-Object{[string]$_.name-ceq$script:V02ReleaseArtifactRequiredCheck -and [string]$_.head_sha-ceq$SourceCommit}|Sort-Object {[long]$_.id} -Descending)
    if($matchingChecks.Count-lt1){throw "GitHub exposes no '$($script:V02ReleaseArtifactRequiredCheck)' check for $SourceCommit."}
    $selectedCheck=$matchingChecks[0]
    if([string]$selectedCheck.status-cne'completed'-or[string]$selectedCheck.conclusion-cne'success'){throw "Latest GitHub '$($script:V02ReleaseArtifactRequiredCheck)' check for $SourceCommit is not completed/success."}
    return [pscustomobject][ordered]@{
        sourceCommit=$SourceCommit
        check=[pscustomobject][ordered]@{name=$script:V02ReleaseArtifactRequiredCheck;headSha=$SourceCommit;conclusion='success';checkRunId=[long]$selectedCheck.id;completedAtUtc=[string]$selectedCheck.completed_at;detailsUrl=[string]$selectedCheck.html_url}
        milestone=[pscustomobject][ordered]@{number=[int]$milestone.number;title=[string]$milestone.title;state=[string]$milestone.state}
        issues=$issueRows
    }
}

function New-V02ReleaseArtifactGitHubSnapshotValue {
    param(
        [Parameter(Mandatory=$true)][ValidateSet('Preclosure','FinalClosure')][string]$Phase,
        [Parameter(Mandatory=$true)][string]$SourceCommit,
        [Parameter(Mandatory=$true)][string]$SourceTree,
        [Parameter(Mandatory=$true)]$LiveState,
        [string]$PreclosureSnapshotSha256=''
    )
    Assert-V02ReleaseArtifactGitId $SourceCommit 'SourceCommit'|Out-Null;Assert-V02ReleaseArtifactGitId $SourceTree 'SourceTree'|Out-Null
    if($Phase-ceq'Preclosure' -and -not[string]::IsNullOrEmpty($PreclosureSnapshotSha256)){throw 'Preclosure snapshot cannot self-reference a preclosure hash.'}
    if($Phase-ceq'FinalClosure'){Assert-V02ReleaseArtifactSha256 $PreclosureSnapshotSha256 'PreclosureSnapshotSha256'|Out-Null}
    return [pscustomobject][ordered]@{
        schemaVersion=3;evidenceClass='AuthenticatedLiveGitHubSnapshot';phase=$Phase;repository=$script:V02ReleaseArtifactRepository
        authentication=[pscustomobject][ordered]@{method='LIVE_GITHUB_API_BEARER_TLS';apiBaseUri=$script:V02ReleaseArtifactApiBase;authenticated=$true}
        preclosureSnapshotSha256=$(if($Phase-ceq'FinalClosure'){$PreclosureSnapshotSha256}else{$null})
        source=[pscustomobject][ordered]@{commitSha=$SourceCommit;treeSha=$SourceTree}
        ci=[pscustomobject][ordered]@{headSha=$SourceCommit;conclusion='success';requiredChecks=@($LiveState.check)}
        milestones=@($LiveState.milestone);issues=@($LiveState.issues)
    }
}

function Assert-V02ReleaseArtifactGitHubPhaseState {
    param([Parameter(Mandatory=$true)]$Snapshot,[Parameter(Mandatory=$true)][ValidateSet('Preclosure','FinalClosure')][string]$Phase)
    if([string]$Snapshot.phase-cne$Phase){throw "GitHub snapshot phase must be $Phase."}
    $observed=@($Snapshot.issues|ForEach-Object{[int]$_.number}|Sort-Object)
    if(($observed-join',')-cne(@($script:V02ReleaseArtifactIssueSet|Sort-Object)-join',')){throw 'GitHub snapshot v0.2 issue set is not exact.'}
    $open=@($Snapshot.issues|Where-Object{[string]$_.state-ceq'open'}|ForEach-Object{[int]$_.number}|Sort-Object)
    $expectedOpen=if($Phase-ceq'Preclosure'){@($script:V02ReleaseArtifactPreclosureOpenIssues)}else{@()}
    if(($open-join',')-cne(@($expectedOpen|Sort-Object)-join',')){throw "GitHub $Phase open issue set is not exact. Expected=$($expectedOpen-join',') Observed=$($open-join',')."}
    $milestone=@($Snapshot.milestones)
    if($milestone.Count-ne1-or[int]$milestone[0].number-ne2-or[string]$milestone[0].title-cne'v0.2.0'){throw 'GitHub snapshot milestone identity is not exact.'}
    $expectedState=if($Phase-ceq'Preclosure'){'open'}else{'closed'}
    if([string]$milestone[0].state-cne$expectedState){throw "GitHub $Phase milestone state must be $expectedState."}
}

function Assert-V02ReleaseArtifactLiveSnapshotMatch {
    param([Parameter(Mandatory=$true)]$Snapshot,[Parameter(Mandatory=$true)]$LiveState)
    if([string]$Snapshot.source.commitSha-cne[string]$LiveState.sourceCommit){throw 'Live GitHub source commit drifted from the snapshot.'}
    $live=[pscustomobject][ordered]@{milestones=@($LiveState.milestone);issues=@($LiveState.issues);check=$LiveState.check}
    if((ConvertTo-V02Jcs @($Snapshot.milestones))-cne(ConvertTo-V02Jcs @($live.milestones))){throw 'Live GitHub milestone state drifted from the snapshot.'}
    if((ConvertTo-V02Jcs @($Snapshot.issues))-cne(ConvertTo-V02Jcs @($live.issues))){throw 'Live GitHub issue state drifted from the snapshot.'}
    if((ConvertTo-V02Jcs $Snapshot.ci.requiredChecks[0])-cne(ConvertTo-V02Jcs $live.check)){throw 'Live GitHub required check drifted from the snapshot.'}
    return $true
}

function New-V02ReleaseArtifactAgentReviewCommentBody {
    param([Parameter(Mandatory=$true)]$Candidate,[Parameter(Mandatory=$true)]$Builder,[Parameter(Mandatory=$true)]$IndependentReviewer,[Parameter(Mandatory=$true)]$Review)
    $payload=[pscustomobject][ordered]@{schemaVersion=1;decisionId='herdrops-v0.2-release-first-v4';candidate=$Candidate;builder=$Builder;independentReviewer=$IndependentReviewer;review=[pscustomobject][ordered]@{result=[string]$Review.Result;openHighCriticalDefects=[int]$Review.OpenHighCriticalDefects;reviewResultSha256=[string]$Review.ReviewResultSha256}}
    return "HERDROPS-V02-INDEPENDENT-AGENT-REVIEW-V1`n$(ConvertTo-V02Jcs $payload)`n"
}

function Assert-V02ReleaseArtifactLogicalAgentRoles {
    param([Parameter(Mandatory=$true)]$Builder,[Parameter(Mandatory=$true)]$IndependentReviewer)
    foreach($pair in @(@($Builder,'Builder'),@($IndependentReviewer,'IndependentReviewer'))){
        foreach($name in @('Identity','Task','Role')){if([string]::IsNullOrWhiteSpace([string]$pair[0].$name)){throw "$($pair[1]) $name must be nonempty."}}
    }
    if([string]$IndependentReviewer.Role-cne'IndependentAgentReviewer'){throw 'IndependentReviewer Role must be IndependentAgentReviewer.'}
    if([string]$Builder.Role-cne'CandidateBuilder'){throw 'Builder Role must be CandidateBuilder.'}
    if([string]$Builder.Identity-ieq[string]$IndependentReviewer.Identity-or[string]$Builder.Task-ieq[string]$IndependentReviewer.Task){throw 'Builder and IndependentReviewer identities and tasks must be role-distinct.'}
}

function Read-V02ReleaseArtifactAgentReviewResult {
    param($Lease,$ExpectedCandidate)
    $value=ConvertFrom-V02ReleaseArtifactCanonicalJsonBytes -Bytes $Lease.Bytes -Context 'Independent Agent review result'
    Assert-V02ReleaseArtifactExactProperties $value @('SchemaVersion','EvidenceClass','DecisionId','Candidate','Builder','IndependentReviewer','Decision','Findings','EvidenceBoundary') 'Independent Agent review result'
    if(($value.SchemaVersion-isnot[int]-and$value.SchemaVersion-isnot[long])-or[int64]$value.SchemaVersion-ne1){throw 'Independent Agent review result SchemaVersion must be native integer 1.'}
    if([string]$value.EvidenceClass-cne'IndependentAgentReviewResult'-or[string]$value.DecisionId-cne'herdrops-v0.2-release-first-v4'){throw 'Independent Agent review result authority is invalid.'}
    if((ConvertTo-V02Jcs $value.Candidate)-cne(ConvertTo-V02Jcs $ExpectedCandidate)){throw 'Independent Agent review result candidate does not match the exact expected candidate.'}
    Assert-V02ReleaseArtifactExactProperties $value.Builder @('Identity','Task','Role') 'Independent Agent review result Builder'
    Assert-V02ReleaseArtifactExactProperties $value.IndependentReviewer @('Identity','Task','Role') 'Independent Agent review result IndependentReviewer'
    Assert-V02ReleaseArtifactLogicalAgentRoles $value.Builder $value.IndependentReviewer
    if([string]$value.Decision-cne'APPROVED_CANDIDATE_ONLY'){throw 'Independent Agent review result Decision is not approved.'}
    $seen=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal);$openHighCritical=0
    foreach($finding in @($value.Findings)){
        Assert-V02ReleaseArtifactExactProperties $finding @('Id','Severity','Status','Summary') 'Independent Agent review finding'
        if([string]::IsNullOrWhiteSpace([string]$finding.Id)-or-not$seen.Add([string]$finding.Id)){throw 'Independent Agent review finding IDs must be nonempty and unique.'}
        if([string]$finding.Severity-notin@('Critical','High','Medium','Low','Info')){throw 'Independent Agent review finding severity is invalid.'}
        if([string]$finding.Status-notin@('OPEN','CLOSED')){throw 'Independent Agent review finding status is invalid.'}
        if([string]::IsNullOrWhiteSpace([string]$finding.Summary)){throw 'Independent Agent review finding summary is empty.'}
        if([string]$finding.Status-ceq'OPEN'-and[string]$finding.Severity-in@('Critical','High')){$openHighCritical++}
    }
    if($openHighCritical-ne0){throw 'Independent Agent review result has open High/Critical defects.'}
    Assert-V02ReleaseArtifactExactProperties $value.EvidenceBoundary @('Runtime','Release','CreditGranted') 'Independent Agent review result EvidenceBoundary'
    if([string]$value.EvidenceBoundary.Runtime-cne'NOT_OBSERVED'-or[string]$value.EvidenceBoundary.Release-cne'NOT_OBSERVED'-or$value.EvidenceBoundary.CreditGranted-isnot[bool]-or[bool]$value.EvidenceBoundary.CreditGranted){throw 'Independent Agent review result inflates its evidence boundary.'}
    return [pscustomobject]@{Value=$value;Builder=$value.Builder;IndependentReviewer=$value.IndependentReviewer;OpenHighCriticalDefects=$openHighCritical;Sha256=$Lease.Sha256;Path=$Lease.Path}
}

function Publish-V02ReleaseArtifactAgentReviewComment {
    param([Parameter(Mandatory=$true)][string]$Body,[Parameter(Mandatory=$true)][string]$TokenEnvironmentVariable)
    $request=ConvertTo-V02Jcs ([pscustomobject][ordered]@{body=$Body})
    $comment=Invoke-V02ReleaseArtifactGitHubApi -RelativeUri "/repos/$($script:V02ReleaseArtifactRepository)/issues/149/comments" -TokenEnvironmentVariable $TokenEnvironmentVariable -Method POST -Body $request
    return Assert-V02ReleaseArtifactAgentReviewComment -Comment $comment -ExpectedBody $Body
}

function Get-V02ReleaseArtifactAgentReviewComment {
    param([Parameter(Mandatory=$true)][long]$CommentId,[Parameter(Mandatory=$true)][string]$ExpectedBody,[Parameter(Mandatory=$true)][string]$TokenEnvironmentVariable)
    $comment=Invoke-V02ReleaseArtifactGitHubApi -RelativeUri "/repos/$($script:V02ReleaseArtifactRepository)/issues/comments/$CommentId" -TokenEnvironmentVariable $TokenEnvironmentVariable
    return Assert-V02ReleaseArtifactAgentReviewComment -Comment $comment -ExpectedBody $ExpectedBody
}

function Assert-V02ReleaseArtifactAgentReviewComment {
    param([Parameter(Mandatory=$true)]$Comment,[Parameter(Mandatory=$true)][string]$ExpectedBody)
    if([long]$Comment.id-le0){throw 'Agent review comment id must be positive.'}
    if([string]$Comment.user.login-cne$script:V02ReleaseArtifactOwnerLogin){throw 'Agent review comment author must be the authenticated repository owner.'}
    if([string]$Comment.author_association-cne'OWNER'){throw 'Agent review comment author association must be OWNER.'}
    if([string]$Comment.body-cne$ExpectedBody){throw 'Live Agent review comment body does not match the exact reviewed candidate.'}
    if([string]$Comment.created_at-cne[string]$Comment.updated_at){throw 'Edited Agent review comments are stale and non-closable.'}
    return [pscustomobject][ordered]@{commentId=[long]$Comment.id;apiUrl=[string]$Comment.url;htmlUrl=[string]$Comment.html_url;commentAuthor=[string]$Comment.user.login;authorAssociation=[string]$Comment.author_association;createdAtUtc=[string]$Comment.created_at;updatedAtUtc=[string]$Comment.updated_at;bodySha256=(Get-V02ReleaseArtifactSha256Bytes ([Text.UTF8Encoding]::new($false,$true).GetBytes($ExpectedBody)))}
}

function Invoke-V02ReleaseArtifactCheckProcess {
    param([Parameter(Mandatory=$true)][string]$HostPath,[Parameter(Mandatory=$true)][string]$ScriptPath,[string[]]$Arguments=@())
    if($null-ne$script:V02ReleaseArtifactCheckInvokerForTest){return &$script:V02ReleaseArtifactCheckInvokerForTest $HostPath $ScriptPath $Arguments}
    $quoted=@('-NoLogo','-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-File',$ScriptPath)+$Arguments
    $psi=[Diagnostics.ProcessStartInfo]::new();$psi.FileName=$HostPath;$psi.UseShellExecute=$false;$psi.RedirectStandardOutput=$true;$psi.RedirectStandardError=$true;$psi.CreateNoWindow=$true
    $psi.Arguments=($quoted|ForEach-Object{'"'+($_-replace'"','\"')+'"'})-join' '
    $proc=[Diagnostics.Process]::new();$proc.StartInfo=$psi
    try{
        if(-not$proc.Start()){throw "Could not start governed check $ScriptPath."}
        $stdoutTask=$proc.StandardOutput.ReadToEndAsync();$stderrTask=$proc.StandardError.ReadToEndAsync();$proc.WaitForExit()
        return [pscustomobject][ordered]@{ExitCode=$proc.ExitCode;Output=($stdoutTask.GetAwaiter().GetResult()+$stderrTask.GetAwaiter().GetResult())}
    } finally {$proc.Dispose()}
}
