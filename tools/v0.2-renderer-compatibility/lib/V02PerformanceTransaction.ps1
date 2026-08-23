#requires -Version 5.1
Set-StrictMode -Version Latest

function Publish-V02PerformanceTransaction {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)][string]$DestinationDirectory,
        [Parameter(Mandatory=$true)][string]$EvidenceRoot,
        [Parameter(Mandatory=$true)][string]$RawFileName,
        [Parameter(Mandatory=$true)][byte[]]$RawBytes,
        [Parameter(Mandatory=$true)][string]$BindingFileName,
        [Parameter(Mandatory=$true)][byte[]]$BindingBytes,
        [Parameter(Mandatory=$true)][byte[]]$CommitBytes,
        [ValidateSet('None','AfterRawStage','AfterBindingStage','AfterCommitMarkerStage','BeforeCommit')][string]$FaultStage='None'
    )
    $root=[IO.Path]::GetFullPath($EvidenceRoot).TrimEnd('\','/');$destination=[IO.Path]::GetFullPath($DestinationDirectory)
    if($destination-cne$root-and-not$destination.StartsWith($root+[IO.Path]::DirectorySeparatorChar,[StringComparison]::OrdinalIgnoreCase)){throw 'Performance transaction directory escaped the evidence root.'}
    if(Test-Path -LiteralPath $destination){throw 'Performance transaction directory already exists; refusing to clobber.'}
    $parent=Split-Path -Parent $destination;if(-not(Test-Path -LiteralPath $parent -PathType Container)){throw 'Performance transaction parent must already exist.'}
    foreach($name in @($RawFileName,$BindingFileName,'performance-commit.json')){if([IO.Path]::GetFileName($name)-cne$name-or[string]::IsNullOrWhiteSpace($name)){throw 'Performance transaction file name is unsafe.'}}
    $stage=Join-Path $parent ('.'+[IO.Path]::GetFileName($destination)+'.stage-'+[Guid]::NewGuid().ToString('N'))
    [IO.Directory]::CreateDirectory($stage)|Out-Null
    try{
        foreach($spec in @(@($RawFileName,$RawBytes,'AfterRawStage'),@($BindingFileName,$BindingBytes,'AfterBindingStage'),@('performance-commit.json',$CommitBytes,'AfterCommitMarkerStage'))){
            $path=Join-Path $stage $spec[0];$bytes=[byte[]]$spec[1];$stream=[IO.File]::Open($path,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None);try{$stream.Write($bytes,0,$bytes.Length);$stream.Flush($true)}finally{$stream.Dispose()};if($FaultStage-ceq$spec[2]){throw "Injected performance transaction failure at $FaultStage."}
        }
        if($FaultStage-ceq'BeforeCommit'){throw 'Injected performance transaction failure before commit.'}
        if(Test-Path -LiteralPath $destination){throw 'Performance transaction directory appeared before commit.'}
        [IO.Directory]::Move($stage,$destination);$stage=$null
        [pscustomobject][ordered]@{Directory=$destination;RawPath=(Join-Path $destination $RawFileName);BindingPath=(Join-Path $destination $BindingFileName);CommitPath=(Join-Path $destination 'performance-commit.json')}
    }finally{if($null-ne$stage-and(Test-Path -LiteralPath $stage)){Remove-Item -LiteralPath $stage -Recurse -Force}}
}
