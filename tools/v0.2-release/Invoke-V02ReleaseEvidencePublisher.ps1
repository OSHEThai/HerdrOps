#requires -Version 5.1
[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][ValidateSet('Contract','Synthetic')][string]$EvidenceClass,
    [Parameter(Mandatory=$true)][string]$ExpectedSourceCommit,
    [Parameter(Mandatory=$true)][string]$ExpectedSourceTree,
    [Parameter(Mandatory=$true)][string]$EvidenceRoot,
    [Parameter(Mandatory=$true)][string]$OutputPath,
    [string]$RepositoryRoot=(Join-Path $PSScriptRoot '..\..')
)
Set-StrictMode -Version Latest;$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot '..\lib\V02ReleaseArtifactProduction.ps1')

$repo=[IO.Path]::GetFullPath($RepositoryRoot);$root=[IO.Path]::GetFullPath($EvidenceRoot)
Assert-V02ReleaseArtifactGitId $ExpectedSourceCommit 'ExpectedSourceCommit'|Out-Null
Assert-V02ReleaseArtifactGitId $ExpectedSourceTree 'ExpectedSourceTree'|Out-Null
$head=(& git -C $repo rev-parse HEAD).Trim();$tree=(& git -C $repo rev-parse 'HEAD^{tree}').Trim()
if($LASTEXITCODE-ne0-or$head-cne$ExpectedSourceCommit-or$tree-cne$ExpectedSourceTree){throw 'Repository HEAD/tree is not the exact evidence candidate.'}
if(-not[string]::IsNullOrWhiteSpace((& git -C $repo status --porcelain))){throw 'Governed evidence checks require a clean repository.'}

$definitions=if($EvidenceClass-ceq'Contract'){
    @(
        [pscustomobject][ordered]@{Name='installed-herdr-protocol-contract';Script='tools/Test-V02ProtocolContract.ps1';Arguments=@()},
        [pscustomobject][ordered]@{Name='bundled-schema-contract';Script='tools/Test-V02BundledSchemaContract.ps1';Arguments=@()}
    )
}else{
    @(
        [pscustomobject][ordered]@{Name='live-pages-packaged-rendering';Script='tools/Test-V02LivePages.ps1';Arguments=@('-Configuration','Release','-SkipBuild')},
        [pscustomobject][ordered]@{Name='live-widgets-packaged-rendering';Script='tools/Test-V02LiveWidgets.ps1';Arguments=@('-Configuration','Release','-SkipBuild','-RunToken',([Guid]::NewGuid().ToString('N')))},
        [pscustomobject][ordered]@{Name='thai-english-language-modes';Script='tools/Test-V02LanguageModes.ps1';Arguments=@('-Configuration','Release','-SkipBuild')}
    )
}
$null=Assert-V02ReleaseArtifactSafeOutput -Path $OutputPath -AllowedRoot $root
foreach($definition in $definitions){$null=Assert-V02ReleaseArtifactSafeOutput -Path (Join-Path $root ("$($EvidenceClass.ToLowerInvariant())-$($definition.Name).txt")) -AllowedRoot $root}
$hostPath=[Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
$checks=New-Object Collections.Generic.List[object]
foreach($definition in $definitions){
    $scriptPath=[IO.Path]::GetFullPath((Join-Path $repo $definition.Script))
    if(-not[IO.File]::Exists($scriptPath)){throw "Governed check script is missing: $($definition.Script)"}
    $result=Invoke-V02ReleaseArtifactCheckProcess -HostPath $hostPath -ScriptPath $scriptPath -Arguments @($definition.Arguments)
    $artifactPath=Join-Path $root ("$($EvidenceClass.ToLowerInvariant())-$($definition.Name).txt")
    $transcript="COMMAND: $hostPath -File $($definition.Script) $(@($definition.Arguments)-join' ')`nEXIT_CODE: $($result.ExitCode)`n$($result.Output)"
    $published=Publish-V02ReleaseArtifactBytesNoClobber -Bytes ([Text.UTF8Encoding]::new($false).GetBytes($transcript)) -OutputPath $artifactPath -AllowedRoot $root
    if($result.ExitCode-ne0){throw "Governed $EvidenceClass check '$($definition.Name)' failed with exit code $($result.ExitCode); no receipt was published."}
    [void]$checks.Add([pscustomobject][ordered]@{Name=$definition.Name;Result='PASS';Path=$published.Path;Sha256=$published.Sha256})
}
$receipt=[pscustomobject][ordered]@{SchemaVersion=2;EvidenceClass=$EvidenceClass;Result='PASS';SourceCommit=$ExpectedSourceCommit;SourceTree=$ExpectedSourceTree;RuntimeObserved=$false;ActualHerdrUsed=$false;ReleaseCredit=$false;Checks=@($checks)}
Publish-V02ReleaseArtifactJsonNoClobber -Value $receipt -OutputPath $OutputPath -AllowedRoot $root
