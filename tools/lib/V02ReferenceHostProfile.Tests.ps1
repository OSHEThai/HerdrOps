[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'V02ReferenceHostProfile.ps1')

$root = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
$profilePath = Join-Path $root 'Plan\reference-hosts\v0.2.json'
$schemaPath = Join-Path $root 'Plan\reference-hosts\reference-host-profile.schema.json'
$probe = Join-Path ([IO.Path]::GetTempPath()) ('herdrops-v02-profile-test-' + [guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($probe)
$knownFiles = [Collections.Generic.List[string]]::new()
$script:cases = 0

function Write-ProbeText([string]$Name,[string]$Text) {
    $path = Join-Path $probe $Name
    [IO.File]::WriteAllText($path,$Text,[Text.UTF8Encoding]::new($false))
    $knownFiles.Add($path)
    return $path
}
function Write-ProbeBytes([string]$Name,[byte[]]$Bytes) {
    $path = Join-Path $probe $Name
    [IO.File]::WriteAllBytes($path,$Bytes)
    $knownFiles.Add($path)
    return $path
}
function Pass([string]$Name,[scriptblock]$Action) { $script:cases++; & $Action; Write-Host "PASS: $Name" }
function Fail([string]$Name,[scriptblock]$Action) {
    $script:cases++
    try { & $Action } catch { Write-Host "PASS: $Name rejected: $($_.Exception.Message)"; return }
    throw "$Name unexpectedly passed."
}

try {
    Pass 'approved profile/schema/hash' { $null = Assert-V02ReferenceHostProfile $profilePath $schemaPath }
    Pass 'RFC8785 ordinal Unicode property order' {
        $value=[pscustomobject]@{}; $value|Add-Member NoteProperty 'z' 1; $value|Add-Member NoteProperty ([string][char]0x00E9) 3; $value|Add-Member NoteProperty 'a' 2; $value|Add-Member NoteProperty ([char]::ConvertFromUtf32(0x1F600)) 4
        $expected='{"a":2,"z":1,"'+[string][char]0x00E9+'":3,"'+[char]::ConvertFromUtf32(0x1F600)+'":4}'
        if ((ConvertTo-V02Jcs $value) -cne $expected) { throw 'JCS did not use ordinal UTF-16 property order.' }
    }
    Fail 'caller-provided profile hash' { Assert-V02ReferenceHostProfile $profilePath $schemaPath ('0'*64) }
    Fail 'duplicate property including escaped equivalent' { ConvertFrom-V02StrictUtf8JsonFile (Write-ProbeText duplicate.json '{"a":1,"\u0061":2}') }
    Fail 'JSON comment' { ConvertFrom-V02StrictUtf8JsonFile (Write-ProbeText comment.json '{"a":1/*x*/}') }
    Fail 'trailing comma' { ConvertFrom-V02StrictUtf8JsonFile (Write-ProbeText trailing.json '{"a":1,}') }
    Fail 'UTF-8 BOM' { ConvertFrom-V02StrictUtf8JsonFile (Write-ProbeBytes bom.json ([byte[]](0xEF,0xBB,0xBF,0x7B,0x7D))) }
    Fail 'malformed UTF-8' { ConvertFrom-V02StrictUtf8JsonFile (Write-ProbeBytes utf8.json ([byte[]](0x7B,0x22,0x78,0x22,0x3A,0x22,0xC3,0x28,0x22,0x7D))) }
    $raw = [IO.File]::ReadAllText($profilePath,[Text.UTF8Encoding]::new($false,$true)).TrimEnd()
    Fail 'unknown profile property' { Assert-V02ReferenceHostProfile (Write-ProbeText unknown.json ($raw -replace '"schemaVersion":1}$','"schemaVersion":1,"unknown":1}')) $schemaPath }
    Fail 'missing profile property' { Assert-V02ReferenceHostProfile (Write-ProbeText missing.json ($raw -replace ',"schemaVersion":1','')) $schemaPath }
    Fail 'profile type mismatch' { Assert-V02ReferenceHostProfile (Write-ProbeText type.json ($raw -replace '"combinedMaximumMebibytes":255','"combinedMaximumMebibytes":"255"')) $schemaPath }
    $schemaRaw=[IO.File]::ReadAllText($schemaPath,[Text.UTF8Encoding]::new($false,$true))
    Fail 'schema mutation' { Assert-V02ReferenceHostProfile $profilePath (Write-ProbeText schema.json ($schemaRaw -replace 'HerdrOps reference-host profile','Mutated profile')) }
    $approved=(Assert-V02ReferenceHostProfile $profilePath $schemaPath).Profile
    $observed=$approved.environmentBinding|ConvertTo-Json -Depth 20|ConvertFrom-Json
    Pass 'all environment binding leaves exact' { Assert-V02BindingEqual $approved.environmentBinding $observed 'environmentBinding' }
    $observed.activeDisplay.physicalWidthPixels = [int64]($observed.activeDisplay.physicalWidthPixels + 1)
    Fail 'environment binding drift' { Assert-V02BindingEqual $approved.environmentBinding $observed 'environmentBinding' }
    $policy=$approved.candidatePolicy|ConvertTo-Json -Depth 20|ConvertFrom-Json
    Pass 'all candidate policy leaves exact' { Assert-V02BindingEqual $approved.candidatePolicy $policy 'candidatePolicy' }
    $policy.sampling.requiredLanguageMatrix=@('Thai')
    Fail 'candidate policy language-matrix drift' { Assert-V02BindingEqual $approved.candidatePolicy $policy 'candidatePolicy' }
    $trusted=[pscustomobject]@{MachineName='M';OperatingSystem='O';OsArchitecture='X64';ProcessArchitecture='X64';ProcessorCount=[int64]8;DesktopAppliedDpi=[int64]120;MainWindowDpiX=[double]120;MainWindowDpiY=[double]120;WindowDisplayDeviceName='DISPLAY1';WindowDisplayLogicalWidthPixels=[int64]2048;WindowDisplayLogicalHeightPixels=[int64]1280}
    $reported=$trusted|ConvertTo-Json|ConvertFrom-Json
    Pass 'producer host diagnostics match trusted DPI and logical display' { Assert-V02ObservedHostReport $reported $trusted }
    $reported.MainWindowDpiX=96
    Fail 'producer host DPI contradiction' { Assert-V02ObservedHostReport $reported $trusted }
}
finally {
    foreach($path in $knownFiles){ if(Test-Path -LiteralPath $path -PathType Leaf){[IO.File]::Delete($path)} }
    if(Test-Path -LiteralPath $probe -PathType Container){[IO.Directory]::Delete($probe,$false)}
}

if($script:cases -ne 18){throw "Unexpected profile test count: $script:cases"}
Write-Host "All $script:cases v0.2 reference-host profile cases passed."
