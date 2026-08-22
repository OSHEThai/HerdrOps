Set-StrictMode -Version Latest

$script:V02ReferenceHostProfileId = 'herdrops-v0.2-submark-nb-software-only-20260822'
$script:V02ReferenceHostProfileSha256 = '96D01ED15A536F2DF50B59B43CFDEB3683DCE8667AE2E7BF6A96124182FE13A3'
$script:V02ReferenceHostSchemaSha256 = '98AC6A2D823D88960A79299B7B20424FF60E9C5299D458A30AB9A42BE4FC0FB3'

function Get-V02Sha256Hex {
    param([Parameter(Mandatory)][byte[]]$Bytes)

    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        return ([BitConverter]::ToString($sha.ComputeHash($Bytes))).Replace('-', '')
    }
    finally {
        $sha.Dispose()
    }
}

function ConvertFrom-V02StrictUtf8JsonFile {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "Required JSON file is missing: $Path"
    }
    $bytes = [IO.File]::ReadAllBytes($Path)
    if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) {
        throw "JSON must be UTF-8 without a BOM: $Path"
    }
    try {
        $json = [Text.UTF8Encoding]::new($false, $true).GetString($bytes)
    }
    catch {
        throw "JSON contains malformed UTF-8: $Path"
    }
    if ($json.IndexOf([char]0xFEFF) -ge 0) {
        throw "JSON contains an unexpected BOM character: $Path"
    }

    Assert-V02NoDuplicateJsonProperties -Json $json -Source $Path
    try {
        $value = $json | ConvertFrom-Json
    }
    catch {
        throw "JSON is malformed, commented, or has a trailing comma: $Path"
    }
    if ($null -eq $value -or $value -isnot [pscustomobject]) {
        throw "JSON root must be an object: $Path"
    }
    return [pscustomobject]@{ Value = $value; Json = $json; Bytes = $bytes }
}

function Read-V02JsonStringToken {
    param([Parameter(Mandatory)][string]$Json, [Parameter(Mandatory)][ref]$Index)

    if ($Json[$Index.Value] -ne '"') { throw 'Internal JSON string tokenizer error.' }
    $builder = [Text.StringBuilder]::new()
    $Index.Value++
    while ($Index.Value -lt $Json.Length) {
        $character = $Json[$Index.Value++]
        if ($character -eq '"') { return $builder.ToString() }
        if ([int]$character -lt 0x20) { throw 'JSON string contains an unescaped control character.' }
        if ($character -ne '\') { [void]$builder.Append($character); continue }
        if ($Index.Value -ge $Json.Length) { throw 'JSON string has an incomplete escape.' }
        $escape = $Json[$Index.Value++]
        switch ($escape) {
            '"' { [void]$builder.Append('"') }
            '\' { [void]$builder.Append('\') }
            '/' { [void]$builder.Append('/') }
            'b' { [void]$builder.Append([char]8) }
            'f' { [void]$builder.Append([char]12) }
            'n' { [void]$builder.Append([char]10) }
            'r' { [void]$builder.Append([char]13) }
            't' { [void]$builder.Append([char]9) }
            'u' {
                if ($Index.Value + 4 -gt $Json.Length) { throw 'JSON string has an incomplete Unicode escape.' }
                $hex = $Json.Substring($Index.Value, 4)
                if ($hex -notmatch '^[0-9a-fA-F]{4}$') { throw 'JSON string has an invalid Unicode escape.' }
                [void]$builder.Append([char][Convert]::ToInt32($hex, 16))
                $Index.Value += 4
            }
            default { throw "JSON string has an invalid escape '\$escape'." }
        }
    }
    throw 'JSON string is unterminated.'
}

function Assert-V02NoDuplicateJsonProperties {
    param([Parameter(Mandatory)][string]$Json, [Parameter(Mandatory)][string]$Source)

    $objectPropertySets = [Collections.Generic.Stack[Collections.Generic.HashSet[string]]]::new()
    $containerKinds = [Collections.Generic.Stack[char]]::new()
    $previousToken = [char]0
    $index = 0
    while ($index -lt $Json.Length) {
        $character = $Json[$index]
        if ([char]::IsWhiteSpace($character)) { $index++; continue }
        if ($character -eq '/') { throw "JSON comments are forbidden: $Source" }
        if ($character -eq '"') {
            $tokenIndex = $index
            $decoded = Read-V02JsonStringToken -Json $Json -Index ([ref]$index)
            $lookahead = $index
            while ($lookahead -lt $Json.Length -and [char]::IsWhiteSpace($Json[$lookahead])) { $lookahead++ }
            if ($lookahead -lt $Json.Length -and $Json[$lookahead] -eq ':' -and
                $containerKinds.Count -gt 0 -and $containerKinds.Peek() -eq '{') {
                if (-not $objectPropertySets.Peek().Add($decoded)) {
                    throw "JSON contains duplicate property '$decoded': $Source"
                }
            }
            $previousToken = 's'
            continue
        }
        switch ($character) {
            '{' {
                $containerKinds.Push('{')
                $objectPropertySets.Push([Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal))
            }
            '[' { $containerKinds.Push('[') }
            '}' {
                if ($previousToken -eq ',') { throw "JSON contains a trailing comma: $Source" }
                if ($containerKinds.Count -eq 0 -or $containerKinds.Pop() -ne '{') { throw "JSON object delimiters are invalid: $Source" }
                [void]$objectPropertySets.Pop()
            }
            ']' {
                if ($previousToken -eq ',') { throw "JSON contains a trailing comma: $Source" }
                if ($containerKinds.Count -eq 0 -or $containerKinds.Pop() -ne '[') { throw "JSON array delimiters are invalid: $Source" }
            }
        }
        $previousToken = $character
        $index++
    }
    if ($containerKinds.Count -ne 0) { throw "JSON container is unterminated: $Source" }
}

function ConvertTo-V02JcsString {
    param([Parameter(Mandatory)][string]$Value)

    $builder = [Text.StringBuilder]::new()
    [void]$builder.Append('"')
    :characters for ($index = 0; $index -lt $Value.Length; $index++) {
        $code = [int]$Value[$index]
        switch ($code) {
            8 { [void]$builder.Append('\b'); continue characters }
            9 { [void]$builder.Append('\t'); continue characters }
            10 { [void]$builder.Append('\n'); continue characters }
            12 { [void]$builder.Append('\f'); continue characters }
            13 { [void]$builder.Append('\r'); continue characters }
            34 { [void]$builder.Append('\"'); continue characters }
            92 { [void]$builder.Append('\\'); continue characters }
        }
        if ($code -lt 0x20) { [void]$builder.AppendFormat('\u{0:x4}', $code); continue }
        if ($code -ge 0xD800 -and $code -le 0xDBFF) {
            if ($index + 1 -ge $Value.Length -or [int]$Value[$index + 1] -lt 0xDC00 -or [int]$Value[$index + 1] -gt 0xDFFF) {
                throw 'JCS input contains an unpaired high surrogate.'
            }
            [void]$builder.Append($Value[$index])
            [void]$builder.Append($Value[++$index])
            continue
        }
        if ($code -ge 0xDC00 -and $code -le 0xDFFF) { throw 'JCS input contains an unpaired low surrogate.' }
        [void]$builder.Append($Value[$index])
    }
    [void]$builder.Append('"')
    return $builder.ToString()
}

function ConvertTo-V02Jcs {
    param([AllowNull()][object]$Value)

    if ($null -eq $Value) { return 'null' }
    if ($Value -is [string]) { return ConvertTo-V02JcsString $Value }
    if ($Value -is [bool]) { if ($Value) { return 'true' } else { return 'false' } }
    if ($Value -is [byte] -or $Value -is [sbyte] -or $Value -is [int16] -or
        $Value -is [uint16] -or $Value -is [int32] -or $Value -is [uint32] -or
        $Value -is [int64] -or $Value -is [uint64]) {
        return ([Convert]::ToString($Value, [Globalization.CultureInfo]::InvariantCulture))
    }
    if ($Value -is [single] -or $Value -is [double] -or $Value -is [decimal]) {
        throw 'The v0.2 reference-host profile permits integer JSON numbers only.'
    }
    if ($Value -is [Collections.IEnumerable] -and $Value -isnot [pscustomobject]) {
        return '[' + ((@($Value) | ForEach-Object { ConvertTo-V02Jcs $_ }) -join ',') + ']'
    }
    if ($Value -is [pscustomobject]) {
        $names = [string[]]@($Value.PSObject.Properties.Name)
        [Array]::Sort($names, [StringComparer]::Ordinal)
        return '{' + (($names | ForEach-Object {
                    (ConvertTo-V02JcsString $_) + ':' + (ConvertTo-V02Jcs $Value.PSObject.Properties[$_].Value)
                }) -join ',') + '}'
    }
    throw "Unsupported JCS value type: $($Value.GetType().FullName)"
}

function Assert-V02ExactProperties {
    param([Parameter(Mandatory)]$Object, [Parameter(Mandatory)][string[]]$Names, [Parameter(Mandatory)][string]$Context)
    if ($null -eq $Object -or $Object -isnot [pscustomobject]) { throw "$Context must be a JSON object." }
    $actual = @($Object.PSObject.Properties.Name | Sort-Object)
    $expected = @($Names | Sort-Object)
    if (($actual -join "`n") -cne ($expected -join "`n")) {
        throw "$Context properties are not exact. Expected=$($expected -join ',') Observed=$($actual -join ',')"
    }
}

function Assert-V02ReferenceHostProfileShape {
    param([Parameter(Mandatory)]$Profile)

    Assert-V02ExactProperties $Profile @('$schema','schemaVersion','profileId','approval','environmentBinding','candidatePolicy','diagnosticPolicy') 'Profile'
    Assert-V02ExactProperties $Profile.approval @('approvedBy','approvedOn','approvalReference') 'Profile approval'
    Assert-V02ExactProperties $Profile.environmentBinding @('host','graphicsAdapters','activeDisplay','herdr') 'Profile environment binding'
    Assert-V02ExactProperties $Profile.environmentBinding.host @('machineName','manufacturer','model','operatingSystemCaption','operatingSystemVersion','operatingSystemBuild','architecture') 'Profile host binding'
    Assert-V02ExactProperties $Profile.environmentBinding.activeDisplay @('activeMonitorCount','adapterPnpDeviceId','monitorInstanceName','primaryDisplayDeviceName','physicalWidthPixels','physicalHeightPixels','logicalWidthPixels','logicalHeightPixels','refreshRateHz','desktopAppliedDpi','scalePercent') 'Profile display binding'
    Assert-V02ExactProperties $Profile.environmentBinding.herdr @('version','releaseId','installPathRelativeToLocalAppData','executableSha256') 'Profile Herdr binding'
    Assert-V02ExactProperties $Profile.candidatePolicy @('sampling','renderer','workingSetPolicy') 'Profile candidate policy'
    Assert-V02ExactProperties $Profile.candidatePolicy.sampling @('durationSeconds','intervalMilliseconds','requiredLanguageMatrix') 'Profile sampling policy'
    Assert-V02ExactProperties $Profile.candidatePolicy.renderer @('policy','wpfProcessRenderMode') 'Profile renderer policy'
    Assert-V02ExactProperties $Profile.candidatePolicy.workingSetPolicy @('combinedMaximumMebibytes','combinedMaximumBytes','statistic') 'Profile working-set policy'
    Assert-V02ExactProperties $Profile.diagnosticPolicy @('excludedFromEnvironmentBinding') 'Profile diagnostic policy'

    $adapters = @($Profile.environmentBinding.graphicsAdapters)
    if ($adapters.Count -lt 1) { throw 'Profile graphicsAdapters must not be empty.' }
    foreach ($adapter in $adapters) {
        Assert-V02ExactProperties $adapter @('displayName','pnpDeviceId','driverVersion') 'Profile graphics adapter binding'
    }
    foreach ($text in @(
        $Profile.'$schema', $Profile.profileId,
        $Profile.approval.approvedBy, $Profile.approval.approvedOn, $Profile.approval.approvalReference,
        $Profile.environmentBinding.host.machineName, $Profile.environmentBinding.host.manufacturer, $Profile.environmentBinding.host.model,
        $Profile.environmentBinding.host.operatingSystemCaption, $Profile.environmentBinding.host.operatingSystemVersion,
        $Profile.environmentBinding.host.architecture,
        $Profile.environmentBinding.herdr.version, $Profile.environmentBinding.herdr.releaseId,
        $Profile.environmentBinding.herdr.installPathRelativeToLocalAppData, $Profile.environmentBinding.herdr.executableSha256)) {
        if ($text -isnot [string] -or [string]::IsNullOrWhiteSpace($text)) { throw 'Profile required strings must be nonblank native JSON strings.' }
    }
    $integerTypes = @([TypeCode]::Byte,[TypeCode]::SByte,[TypeCode]::UInt16,[TypeCode]::UInt32,[TypeCode]::UInt64,[TypeCode]::Int16,[TypeCode]::Int32,[TypeCode]::Int64)
    if ($integerTypes -notcontains [Type]::GetTypeCode($Profile.schemaVersion.GetType()) -or [int64]$Profile.schemaVersion -ne 1) {
        throw 'Profile schemaVersion must be the native JSON integer 1.'
    }
    if ([string]$Profile.candidatePolicy.renderer.policy -cne 'software-only-process-wide' -or
        [string]$Profile.candidatePolicy.renderer.wpfProcessRenderMode -cne 'SoftwareOnly') {
        throw 'Profile renderer binding must be process-wide SoftwareOnly.'
    }
    if ($integerTypes -notcontains [Type]::GetTypeCode($Profile.environmentBinding.host.operatingSystemBuild.GetType()) -or
        [int64]$Profile.environmentBinding.host.operatingSystemBuild -le 0) {
        throw 'Profile operatingSystemBuild must be a positive native JSON integer.'
    }
    if ($integerTypes -notcontains [Type]::GetTypeCode($Profile.candidatePolicy.workingSetPolicy.combinedMaximumMebibytes.GetType()) -or
        [int64]$Profile.candidatePolicy.workingSetPolicy.combinedMaximumMebibytes -ne 255 -or
        $integerTypes -notcontains [Type]::GetTypeCode($Profile.candidatePolicy.workingSetPolicy.combinedMaximumBytes.GetType()) -or
        [int64]$Profile.candidatePolicy.workingSetPolicy.combinedMaximumBytes -ne 267386880L -or
        [string]$Profile.candidatePolicy.workingSetPolicy.statistic -cne 'maximum') {
        throw 'Profile working-set binding must be exactly maximum 255 MiB / 267386880 bytes.'
    }
    if ((@($Profile.candidatePolicy.sampling.requiredLanguageMatrix) -join ',') -cne 'Thai,English') {
        throw 'Profile requiredLanguageMatrix must be exactly ordered Thai,English.'
    }
    if ($integerTypes -notcontains [Type]::GetTypeCode($Profile.candidatePolicy.sampling.durationSeconds.GetType()) -or
        $integerTypes -notcontains [Type]::GetTypeCode($Profile.candidatePolicy.sampling.intervalMilliseconds.GetType())) {
        throw 'Profile sampling values must be native JSON integers.'
    }
    if ([string]$Profile.environmentBinding.herdr.executableSha256 -cnotmatch '^[0-9A-F]{64}$') {
        throw 'Profile Herdr SHA-256 must be uppercase hexadecimal.'
    }
    if ([string]$Profile.profileId -cne $script:V02ReferenceHostProfileId) {
        throw "Unexpected approved v0.2 profile ID: $($Profile.profileId)"
    }
}

function Assert-V02ReferenceHostProfile {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ProfilePath,
        [Parameter(Mandatory)][string]$SchemaPath,
        [string]$ExpectedSha256 = $script:V02ReferenceHostProfileSha256
    )

    if ($ExpectedSha256 -cne $script:V02ReferenceHostProfileSha256) {
        throw 'The caller cannot replace the independently pinned v0.2 reference-host profile hash.'
    }

    $schemaDocument = ConvertFrom-V02StrictUtf8JsonFile $SchemaPath
    $canonicalSchema = ConvertTo-V02Jcs $schemaDocument.Value
    $schemaSha256 = Get-V02Sha256Hex ([Text.UTF8Encoding]::new($false).GetBytes($canonicalSchema))
    if ($schemaSha256 -cne $script:V02ReferenceHostSchemaSha256) {
        throw "Reference-host schema canonical SHA-256 mismatch. Expected=$script:V02ReferenceHostSchemaSha256 Observed=$schemaSha256"
    }
    if ([string]$schemaDocument.Value.'$schema' -cne 'https://json-schema.org/draft/2020-12/schema') {
        throw 'Reference-host schema must declare JSON Schema Draft 2020-12.'
    }
    if ($schemaDocument.Value.additionalProperties -isnot [bool] -or $schemaDocument.Value.additionalProperties) {
        throw 'Reference-host schema root must fail closed with additionalProperties=false.'
    }

    $profileDocument = ConvertFrom-V02StrictUtf8JsonFile $ProfilePath
    $testJson = Get-Command Test-Json -CommandType Cmdlet -ErrorAction SilentlyContinue
    if ($null -ne $testJson -and $testJson.Parameters.ContainsKey('SchemaFile')) {
        if (-not ($profileDocument.Json | Test-Json -SchemaFile $SchemaPath)) {
            throw 'Reference-host profile failed its complete Draft 2020-12 schema.'
        }
    }
    Assert-V02ReferenceHostProfileShape $profileDocument.Value
    $canonicalJson = ConvertTo-V02Jcs $profileDocument.Value
    $actualSha256 = Get-V02Sha256Hex ([Text.UTF8Encoding]::new($false).GetBytes($canonicalJson))
    if ($actualSha256 -cne $ExpectedSha256) {
        throw "Reference-host canonical SHA-256 mismatch. Expected=$ExpectedSha256 Observed=$actualSha256"
    }
    return [pscustomobject]@{ Profile = $profileDocument.Value; CanonicalJson = $canonicalJson; Sha256 = $actualSha256 }
}

function Assert-V02BindingEqual {
    param([AllowNull()]$Expected, [AllowNull()]$Observed, [Parameter(Mandatory)][string]$Path)
    if ($Expected -is [pscustomobject]) {
        Assert-V02ExactProperties $Observed @($Expected.PSObject.Properties.Name) "Observed $Path"
        foreach ($property in $Expected.PSObject.Properties) { Assert-V02BindingEqual $property.Value $Observed.($property.Name) "$Path.$($property.Name)" }
        return
    }
    if ($Expected -is [Collections.IEnumerable] -and $Expected -isnot [string]) {
        $expectedItems = @($Expected); $observedItems = @($Observed)
        if ($expectedItems.Count -ne $observedItems.Count) { throw "$Path array count drifted." }
        for ($index = 0; $index -lt $expectedItems.Count; $index++) { Assert-V02BindingEqual $expectedItems[$index] $observedItems[$index] "$Path[$index]" }
        return
    }
    if ($null -eq $Observed -or $Expected.GetType() -ne $Observed.GetType() -or [string]$Expected -cne [string]$Observed) {
        throw "$Path drifted. Expected='$Expected' Observed='$Observed'."
    }
}

function Get-V02TrustedReferenceHostObservation {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Profile,
        [Parameter(Mandatory)][string]$HerdrExecutable,
        [Parameter(Mandatory)][int]$DurationSeconds,
        [Parameter(Mandatory)][int]$IntervalMilliseconds
    )

    if (-not (Get-Command Get-CimInstance -ErrorAction SilentlyContinue)) { throw 'Get-CimInstance is required for trusted reference-host admission.' }
    $computer = @(Get-CimInstance Win32_ComputerSystem)
    $operatingSystem = @(Get-CimInstance Win32_OperatingSystem)
    $videoControllers = @(Get-CimInstance Win32_VideoController | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_.PNPDeviceID) })
    $activeMonitors = @(Get-CimInstance -Namespace root\wmi -ClassName WmiMonitorID | Where-Object { $_.Active -eq $true })
    if ($computer.Count -ne 1 -or $operatingSystem.Count -ne 1 -or $videoControllers.Count -lt 1 -or $activeMonitors.Count -ne 1) { throw 'Trusted WMI host/display identity is incomplete or ambiguous.' }

    Add-Type -AssemblyName System.Windows.Forms
    $primaryScreen = [Windows.Forms.Screen]::PrimaryScreen
    if ($null -eq $primaryScreen) { throw 'Trusted primary display probe returned no screen.' }
    $desktopMetrics = Get-ItemProperty -LiteralPath 'HKCU:\Control Panel\Desktop\WindowMetrics' -Name AppliedDPI -ErrorAction Stop
    if ($null -eq $desktopMetrics.AppliedDPI -or $desktopMetrics.AppliedDPI -isnot [int]) {
        throw 'Trusted desktop AppliedDPI registry probe is missing or not a native DWORD.'
    }
    $desktopAppliedDpi = [int64]$desktopMetrics.AppliedDPI
    if ($desktopAppliedDpi -le 0) { throw 'Trusted desktop AppliedDPI registry probe returned an invalid value.' }
    $activeCandidates = @($videoControllers | Where-Object {
        [string]$_.PNPDeviceID -ceq [string]$Profile.environmentBinding.activeDisplay.adapterPnpDeviceId -and
        [int64]$_.CurrentHorizontalResolution -gt 0 -and
        [int64]$_.CurrentVerticalResolution -gt 0 -and
        [int64]$_.CurrentRefreshRate -gt 0
    })
    if ($activeCandidates.Count -ne 1) { throw 'Trusted active-display GPU binding is incomplete or ambiguous.' }
    $activeAdapter = $activeCandidates[0]
    $physicalWidth = [int64]$activeAdapter.CurrentHorizontalResolution
    $physicalHeight = [int64]$activeAdapter.CurrentVerticalResolution
    $logicalWidth = [int64]$primaryScreen.Bounds.Width
    $logicalHeight = [int64]$primaryScreen.Bounds.Height
    $derivedLogicalWidth = [int64][Math]::Round(([double]$physicalWidth*96.0)/$desktopAppliedDpi)
    $derivedLogicalHeight = [int64][Math]::Round(([double]$physicalHeight*96.0)/$desktopAppliedDpi)
    if ($logicalWidth -ne $derivedLogicalWidth -or $logicalHeight -ne $derivedLogicalHeight) {
        throw "Trusted primary Screen bounds contradict physical mode / AppliedDPI. Screen=${logicalWidth}x${logicalHeight} Derived=${derivedLogicalWidth}x${derivedLogicalHeight}."
    }

    $orderedAdapters = @()
    foreach ($expectedAdapter in @($Profile.environmentBinding.graphicsAdapters)) {
        $matches = @($videoControllers | Where-Object { [string]$_.PNPDeviceID -ceq [string]$expectedAdapter.pnpDeviceId })
        if ($matches.Count -ne 1) { throw "Trusted graphics adapter '$($expectedAdapter.pnpDeviceId)' is missing or duplicated." }
        $adapter = $matches[0]
        $orderedAdapters += [pscustomobject]@{ displayName=[string]$adapter.Name; pnpDeviceId=[string]$adapter.PNPDeviceID; driverVersion=[string]$adapter.DriverVersion }
    }
    if ($orderedAdapters.Count -ne $videoControllers.Count) { throw 'Trusted graphics adapter set contains an unprofiled adapter.' }

    $resolvedHerdr = (Resolve-Path -LiteralPath $HerdrExecutable).Path
    $resolvedLocalAppData = [IO.Path]::GetFullPath($env:LOCALAPPDATA).TrimEnd('\')
    if (-not $resolvedHerdr.StartsWith($resolvedLocalAppData + '\',[StringComparison]::OrdinalIgnoreCase)) { throw 'Herdr executable is outside trusted LOCALAPPDATA.' }
    $relativeHerdr = $resolvedHerdr.Substring($resolvedLocalAppData.Length + 1)
    $versionOutput = @(& $resolvedHerdr --version)
    if ($LASTEXITCODE -ne 0 -or ($versionOutput -join ' ') -notmatch '^herdr\s+(?<version>\S+)\s*$') { throw 'Trusted Herdr --version probe failed.' }
    $version = $Matches.version
    $architecture = [Runtime.InteropServices.RuntimeInformation]::OSArchitecture.ToString().ToLowerInvariant()
    $releaseArchitecture = if ($architecture -eq 'x64') { 'x86_64-pc-windows-msvc' } elseif ($architecture -eq 'arm64') { 'aarch64-pc-windows-msvc' } else { throw "Unsupported trusted OS architecture '$architecture'." }

    $environmentBinding = [pscustomobject]@{
        host=[pscustomobject]@{machineName=[Environment]::MachineName;manufacturer=[string]$computer[0].Manufacturer;model=[string]$computer[0].Model;operatingSystemCaption=[string]$operatingSystem[0].Caption;operatingSystemVersion=[string]$operatingSystem[0].Version;operatingSystemBuild=[int64]$operatingSystem[0].BuildNumber;architecture=$architecture}
        graphicsAdapters=$orderedAdapters
        activeDisplay=[pscustomobject]@{activeMonitorCount=[int64]$activeMonitors.Count;adapterPnpDeviceId=[string]$activeAdapter.PNPDeviceID;monitorInstanceName=[string]$activeMonitors[0].InstanceName;primaryDisplayDeviceName=[string]$primaryScreen.DeviceName;physicalWidthPixels=$physicalWidth;physicalHeightPixels=$physicalHeight;logicalWidthPixels=$logicalWidth;logicalHeightPixels=$logicalHeight;refreshRateHz=[int64]$activeAdapter.CurrentRefreshRate;desktopAppliedDpi=$desktopAppliedDpi;scalePercent=[int64][Math]::Round(([double]$desktopAppliedDpi/96.0)*100.0)}
        herdr=[pscustomobject]@{version=$version;releaseId="$version-$releaseArchitecture";installPathRelativeToLocalAppData=$relativeHerdr;executableSha256=((Get-FileHash -LiteralPath $resolvedHerdr -Algorithm SHA256).Hash).ToUpperInvariant()}
    }
    $candidatePolicy = [pscustomobject]@{
        sampling=[pscustomobject]@{durationSeconds=[int64]$DurationSeconds;intervalMilliseconds=[int64]$IntervalMilliseconds;requiredLanguageMatrix=@('Thai','English')}
        renderer=[pscustomobject]@{policy='software-only-process-wide';wpfProcessRenderMode='SoftwareOnly'}
        workingSetPolicy=[pscustomobject]@{combinedMaximumMebibytes=[int64]255;combinedMaximumBytes=[int64]267386880;statistic='maximum'}
    }
    return [pscustomobject]@{
        EnvironmentBinding=$environmentBinding
        CandidatePolicy=$candidatePolicy
        ReportObservedHost=[pscustomobject]@{MachineName=[Environment]::MachineName;OperatingSystem=[Runtime.InteropServices.RuntimeInformation]::OSDescription;OsArchitecture=[Runtime.InteropServices.RuntimeInformation]::OSArchitecture.ToString();ProcessArchitecture=[Runtime.InteropServices.RuntimeInformation]::ProcessArchitecture.ToString();ProcessorCount=[Environment]::ProcessorCount;DesktopAppliedDpi=$desktopAppliedDpi;MainWindowDpiX=[double]$desktopAppliedDpi;MainWindowDpiY=[double]$desktopAppliedDpi;WindowDisplayDeviceName=[string]$primaryScreen.DeviceName;WindowDisplayLogicalWidthPixels=$logicalWidth;WindowDisplayLogicalHeightPixels=$logicalHeight}
    }
}

function Assert-V02ObservedHostReport {
    param([Parameter(Mandatory)]$Reported,[Parameter(Mandatory)]$Trusted)
    Assert-V02ExactProperties $Reported @('MachineName','OperatingSystem','OsArchitecture','ProcessArchitecture','ProcessorCount','DesktopAppliedDpi','MainWindowDpiX','MainWindowDpiY','WindowDisplayDeviceName','WindowDisplayLogicalWidthPixels','WindowDisplayLogicalHeightPixels') 'Reported observed host'
    foreach($name in @('MachineName','OperatingSystem','OsArchitecture','ProcessArchitecture','WindowDisplayDeviceName')) {
        if ($Reported.$name -isnot [string] -or [string]$Reported.$name -cne [string]$Trusted.$name) { throw "Reported ObservedHost.$name contradicts the independent trusted probe." }
    }
    $integerTypes=@([TypeCode]::Byte,[TypeCode]::SByte,[TypeCode]::UInt16,[TypeCode]::UInt32,[TypeCode]::UInt64,[TypeCode]::Int16,[TypeCode]::Int32,[TypeCode]::Int64)
    foreach($name in @('ProcessorCount','DesktopAppliedDpi','WindowDisplayLogicalWidthPixels','WindowDisplayLogicalHeightPixels')) {
        if ($null -eq $Reported.$name -or $integerTypes -notcontains [Type]::GetTypeCode($Reported.$name.GetType()) -or [int64]$Reported.$name -ne [int64]$Trusted.$name) { throw "Reported ObservedHost.$name contradicts the independent trusted probe." }
    }
    foreach($name in @('MainWindowDpiX','MainWindowDpiY')) {
        if ($null -eq $Reported.$name -or $Reported.$name -isnot [ValueType] -or
            [double]::IsNaN([double]$Reported.$name) -or [double]::IsInfinity([double]$Reported.$name) -or
            [double]$Reported.$name -ne [double]$Trusted.$name) {
            throw "Reported ObservedHost.$name contradicts the independent trusted probe."
        }
    }
}
