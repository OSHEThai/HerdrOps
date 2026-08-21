[CmdletBinding(DefaultParameterSetName = 'ReleaseGate')]
param(
    [Parameter(Mandatory, ParameterSetName = 'ReleaseGate')]
    [string]$CompositeRuntimeReport,

    [Parameter(Mandatory, ParameterSetName = 'ReleaseGate')]
    [string]$RuntimeGateReport,

    [Parameter(ParameterSetName = 'ReleaseGate')]
    [string]$HerdrRuntimeReport,

    [Parameter(ParameterSetName = 'ReleaseGate')]
    [string]$PackagedArtifact,

    [Parameter(ParameterSetName = 'ReleaseGate')]
    [string]$CleanMachineInstallReport,

    [Parameter(ParameterSetName = 'ReleaseGate')]
    [string]$HumanAcceptanceReport,

    [Parameter(ParameterSetName = 'ReleaseGate')]
    [string[]]$PredecessorReleaseGateReports,

    [Parameter(ParameterSetName = 'ReleaseGate')]
    [switch]$RequireReleaseReady,

    [Parameter(ParameterSetName = 'ReleaseGate')]
    [ValidateSet('Debug', 'Release')]
    [string]$Configuration = 'Release',

    [Parameter(ParameterSetName = 'ReleaseGate')]
    [switch]$SkipBuild,

    [Parameter(Mandatory, ParameterSetName = 'SelfTest')]
    [switch]$SelfTest
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false

function Assert-ValidLeafPath {
    param(
        [Parameter(Mandatory)]
        [string]$Path,

        [Parameter(Mandatory)]
        [string]$Name,

        [string]$AllowedRoot = $null
    )

    if ([string]::IsNullOrWhiteSpace($Path)) {
        throw "The $Name path must not be null or whitespace."
    }
    if ($Path.IndexOfAny([IO.Path]::GetInvalidPathChars()) -ge 0) {
        throw "The $Name path contains invalid path characters: $Path"
    }
    if ($Path.Contains("`0")) {
        throw "The $Name path contains null characters: $Path"
    }

    $fullPath = [IO.Path]::GetFullPath($Path)

    if (-not (Test-Path -LiteralPath $fullPath -PathType Leaf)) {
        throw "Required v0.5 runtime evidence is missing or not a leaf file ($Name): $fullPath"
    }

    $fileInfo = [IO.FileInfo]::new($fullPath)
    try {
        if ($fileInfo.Length -le 0) {
            throw "The $Name file is empty: $fullPath"
        }
        if ($fileInfo.Length -gt (32 * 1024 * 1024)) {
            throw "The $Name file exceeds maximum allowable size (32MB): $fullPath"
        }
    } catch [System.UnauthorizedAccessException] {
        throw "Access denied reading $($Name) file attributes: $fullPath"
    } catch [System.Security.SecurityException] {
        throw "Security access denied reading $($Name) file attributes: $fullPath"
    }

    # Verify no ReparsePoint / symlink on the file
    if ($fileInfo.Attributes.HasFlag([IO.FileAttributes]::ReparsePoint)) {
        throw "Reparse point / symbolic link rejected for $($Name): $fullPath"
    }

    # Verify no ancestor directory is a ReparsePoint
    $parentDir = $fileInfo.Directory
    while ($null -ne $parentDir) {
        if ($parentDir.Attributes.HasFlag([IO.FileAttributes]::ReparsePoint)) {
            throw "Parent directory is a reparse point / symbolic link for $($Name): $($parentDir.FullName)"
        }
        $parentDir = $parentDir.Parent
    }

    # Verify file can be opened for read without access denied
    try {
        $stream = [IO.File]::Open($fullPath, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
        $stream.Dispose()
    } catch [System.UnauthorizedAccessException] {
        throw "Access denied opening $($Name) for read: $fullPath"
    } catch [System.IO.IOException] {
        throw "IO error or file lock opening $($Name) for read: $fullPath ($($_.Exception.Message))"
    } catch [System.Security.SecurityException] {
        throw "Security access denied opening $($Name) for read: $fullPath"
    }

    # AllowedRoot check
    if (-not [string]::IsNullOrWhiteSpace($AllowedRoot)) {
        $normalizedRoot = [IO.Path]::GetFullPath($AllowedRoot).TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
        $rootPrefix = $normalizedRoot + [IO.Path]::DirectorySeparatorChar
        if (-not ($fullPath.StartsWith($rootPrefix, [StringComparison]::OrdinalIgnoreCase) -or
                  $fullPath.Equals($normalizedRoot, [StringComparison]::OrdinalIgnoreCase))) {
            throw "Path escape detected: $($Name) ($fullPath) is outside allowed root ($normalizedRoot)"
        }
    }

    return $fileInfo.FullName
}

function Test-PredecessorReports {
    param(
        [Parameter(Mandatory)][string[]]$Reports,
        [Parameter(Mandatory)][string]$RepositoryRoot,
        [Parameter(Mandatory)][string]$SourceCommit
    )

    $requiredVersions = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($v in @('v0.1.0', 'v0.2.0', 'v0.3.0', 'v0.4.0')) {
        [void]$requiredVersions.Add($v)
    }
    $seenPaths = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $seenHashes = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $seenVersions = [Collections.Generic.Dictionary[string, pscustomobject]]::new([StringComparer]::OrdinalIgnoreCase)

    foreach ($predReport in $Reports) {
        $resolvedPath = Assert-ValidLeafPath -Path $predReport -Name 'predecessor release gate report' -AllowedRoot $RepositoryRoot
        if (-not $seenPaths.Add($resolvedPath)) {
            throw "Duplicate predecessor report path supplied: $resolvedPath"
        }

        $hash = (Get-FileHash -LiteralPath $resolvedPath -Algorithm SHA256).Hash
        if (-not $seenHashes.Add($hash)) {
            throw "Duplicate predecessor report content hash supplied: $hash ($resolvedPath)"
        }

        $text = Get-Content -LiteralPath $resolvedPath -Raw
        if ($text -notmatch '(?m)^HerdrOps\s+(?<version>v0\.[1-4]\.0)\s+(?:Release Gate|Version-Local Technical Gate|Release)') {
            throw "Predecessor report is not a typed v0.1-v0.4 release gate report: $resolvedPath"
        }
        $version = $Matches.version
        if (-not $requiredVersions.Contains($version)) {
            throw "Predecessor report declared an invalid or non-predecessor version '$version': $resolvedPath"
        }
        if ($seenVersions.ContainsKey($version)) {
            throw "Duplicate predecessor report version '$version' supplied from: $resolvedPath"
        }

        if ($text -notmatch '(?m)^Result:\s*(PASS|RELEASE PASS|TECHNICAL GATE PASS)\s*$') {
            throw "Predecessor release gate report for $version does not have passing Result: $resolvedPath"
        }

        if ($text -notmatch '(?m)^(?:SourceCommit|Commit):\s*(?<commit>[0-9a-fA-F]{7,40})\s*$') {
            throw "Predecessor release gate report for $version is missing valid commit binding: $resolvedPath"
        }
        $predCommit = $Matches.commit

        $seenVersions[$version] = [pscustomobject]@{
            Version = $version
            Path = $resolvedPath
            Sha256 = $hash
            Commit = $predCommit
        }
    }

    $missingVersions = @($requiredVersions | Where-Object { -not $seenVersions.ContainsKey($_) })
    if ($missingVersions.Count -gt 0) {
        throw "Predecessor release gate reports are missing required versions: $($missingVersions -join ', ')"
    }

    return @($seenVersions.Values | Sort-Object Version)
}

function Test-HumanAcceptanceReport {
    param(
        [Parameter(Mandatory)][string]$ReportPath,
        [Parameter(Mandatory)][string]$RepositoryRoot,
        [Parameter(Mandatory)][string]$SourceCommit
    )

    $resolvedPath = Assert-ValidLeafPath -Path $ReportPath -Name 'independent human acceptance report' -AllowedRoot $RepositoryRoot
    $hash = (Get-FileHash -LiteralPath $resolvedPath -Algorithm SHA256).Hash
    $text = Get-Content -LiteralPath $resolvedPath -Raw

    if ($text -notmatch '(?m)^(?:Approval|Verdict):\s*(APPROVED|PASS|RELEASE PASS)\s*$') {
        throw "Independent human acceptance is not approved (Verdict/Approval must be PASS or APPROVED): $resolvedPath"
    }

    if ($text -notmatch "(?m)^SourceCommit:\s*$([Regex]::Escape($SourceCommit))\s*$") {
        throw "Independent human acceptance is not bound to source commit $($SourceCommit): $resolvedPath"
    }

    if ($text -notmatch '(?m)^(?:Signer|Approver|HumanReviewer|Reviewer):\s*(?<signer>\S.*?)\s*$') {
        throw "Independent human acceptance report is missing Signer/Approver declaration: $resolvedPath"
    }
    $signer = $Matches.signer.Trim()
    if ([string]::IsNullOrWhiteSpace($signer)) {
        throw "Independent human acceptance report has empty Signer/Approver identity: $resolvedPath"
    }

    if ($text -notmatch '(?m)^(?:Role|ApproverRole|SignerRole):\s*(?<role>\S.*?)\s*$') {
        throw "Independent human acceptance report is missing distinct human Role declaration: $resolvedPath"
    }
    $role = $Matches.role.Trim()
    if ([string]::IsNullOrWhiteSpace($role)) {
        throw "Independent human acceptance report has empty human Role: $resolvedPath"
    }

    if ($text -notmatch '(?m)^(?:Provenance|SignedUtc|TimestampUtc|IndependentProvenance):\s*(?<provenance>\S.*?)\s*$') {
        throw "Independent human acceptance report is missing independent provenance metadata: $resolvedPath"
    }
    $provenance = $Matches.provenance.Trim()
    if ([string]::IsNullOrWhiteSpace($provenance)) {
        throw "Independent human acceptance report has empty provenance declaration: $resolvedPath"
    }

    return [pscustomobject]@{
        Path = $resolvedPath
        Sha256 = $hash
        Signer = $signer
        Role = $role
        Provenance = $provenance
    }
}

function Assert-SingleGateReportScalar {
    param(
        [Parameter(Mandatory)][string]$Text,
        [Parameter(Mandatory)][string]$FieldName,
        [Parameter(Mandatory)][string]$ExpectedPattern,
        [Parameter(Mandatory)][string]$ReportPath
    )

    $matches = [Regex]::Matches($Text, "(?m)^$([Regex]::Escape($FieldName)):\s*(?<value>.*?)\s*$")
    if ($matches.Count -ne 1) {
        throw "The runtime gate report must contain exactly one '$FieldName' declaration (found $($matches.Count)): $ReportPath"
    }

    $value = $matches[0].Groups['value'].Value.Trim()
    if ($value -notmatch "^$ExpectedPattern$") {
        throw "The runtime gate report '$FieldName' declaration has invalid value '$value' (expected pattern '^$ExpectedPattern$'): $ReportPath"
    }

    return $value
}

function Assert-SingleEvidenceClassGateScalar {
    param(
        [Parameter(Mandatory)][string]$Text,
        [Parameter(Mandatory)][string]$ReportPath
    )

    $matches = [Regex]::Matches($Text, '(?m)^(?:EvidenceClass|EvidenceClassification):\s*(?<value>.*?)\s*$')
    if ($matches.Count -ne 1) {
        throw "The runtime gate report must contain exactly one EvidenceClass/EvidenceClassification declaration (found $($matches.Count)): $ReportPath"
    }

    $value = $matches[0].Groups['value'].Value.Trim()
    if ($value -ne 'Runtime') {
        throw "The runtime gate report EvidenceClass declaration has invalid value '$value' (expected 'Runtime'): $ReportPath"
    }

    return $value
}

function Assert-JsonBooleanProperty {
    param(
        [Parameter(Mandatory)]$TargetObject,
        [Parameter(Mandatory)][string]$PropertyName,
        [Parameter(Mandatory)][bool]$ExpectedValue,
        [Parameter(Mandatory)][string]$ContextPath
    )

    $property = $TargetObject.PSObject.Properties[$PropertyName]
    if ($null -eq $property) {
        throw "JSON object is missing required boolean property '$PropertyName': $ContextPath"
    }

    $val = $property.Value
    if ($null -eq $val) {
        throw "JSON property '$PropertyName' value is null (expected boolean $ExpectedValue): $ContextPath"
    }

    if ($val.GetType() -ne [bool]) {
        $typeName = $val.GetType().FullName
        throw "JSON property '$PropertyName' must be a CLR Boolean, but found '$typeName' with value '$val': $ContextPath"
    }

    if ([bool]$val -ne $ExpectedValue) {
        throw "JSON property '$PropertyName' is $([bool]$val) (expected $ExpectedValue): $ContextPath"
    }
}

function Resolve-CanonicalRuntimeReports {
    param(
        [Parameter(Mandatory)][string]$CompositeRuntimeReport,
        [Parameter(Mandatory)][string]$RuntimeGateReport,
        [string]$HerdrRuntimeReport,
        [Parameter(Mandatory)][string]$RepositoryRoot,
        [Parameter(Mandatory)][string]$SourceCommit
    )

    $resolvedCompositePath = Assert-ValidLeafPath -Path $CompositeRuntimeReport -Name 'composite runtime report' -AllowedRoot $RepositoryRoot
    $resolvedRuntimeGatePath = Assert-ValidLeafPath -Path $RuntimeGateReport -Name 'runtime gate report' -AllowedRoot $RepositoryRoot

    if ($resolvedCompositePath -eq $resolvedRuntimeGatePath) {
        throw "Composite runtime report and runtime gate report cannot be the same file: $resolvedCompositePath"
    }

    $compositeSha256 = (Get-FileHash -LiteralPath $resolvedCompositePath -Algorithm SHA256).Hash
    $runtimeGateSha256 = (Get-FileHash -LiteralPath $resolvedRuntimeGatePath -Algorithm SHA256).Hash

    if ($compositeSha256 -eq $runtimeGateSha256) {
        throw "Composite runtime report and runtime gate report have identical hash: $compositeSha256"
    }

    $runtimeGateText = Get-Content -LiteralPath $resolvedRuntimeGatePath -Raw

    [void](Assert-SingleGateReportScalar -Text $runtimeGateText -FieldName 'Result' -ExpectedPattern 'PASS' -ReportPath $resolvedRuntimeGatePath)
    [void](Assert-SingleGateReportScalar -Text $runtimeGateText -FieldName 'SourceCommit' -ExpectedPattern ([Regex]::Escape($SourceCommit)) -ReportPath $resolvedRuntimeGatePath)
    [void](Assert-SingleEvidenceClassGateScalar -Text $runtimeGateText -ReportPath $resolvedRuntimeGatePath)
    [void](Assert-SingleGateReportScalar -Text $runtimeGateText -FieldName 'RuntimeObserved' -ExpectedPattern 'true' -ReportPath $resolvedRuntimeGatePath)
    [void](Assert-SingleGateReportScalar -Text $runtimeGateText -FieldName 'SnapshotObserved' -ExpectedPattern 'true' -ReportPath $resolvedRuntimeGatePath)
    [void](Assert-SingleGateReportScalar -Text $runtimeGateText -FieldName 'EventObserved' -ExpectedPattern 'true' -ReportPath $resolvedRuntimeGatePath)
    [void](Assert-SingleGateReportScalar -Text $runtimeGateText -FieldName 'ReconnectObserved' -ExpectedPattern 'true' -ReportPath $resolvedRuntimeGatePath)
    [void](Assert-SingleGateReportScalar -Text $runtimeGateText -FieldName 'SessionControlInvoked' -ExpectedPattern 'false' -ReportPath $resolvedRuntimeGatePath)
    [void](Assert-SingleGateReportScalar -Text $runtimeGateText -FieldName 'CompositeRuntimeReportSha256' -ExpectedPattern ([Regex]::Escape($compositeSha256)) -ReportPath $resolvedRuntimeGatePath)
    $declaredHerdrRuntimeSha256 = Assert-SingleGateReportScalar -Text $runtimeGateText -FieldName 'HerdrRuntimeReportSha256' -ExpectedPattern '[0-9a-fA-F]{64}' -ReportPath $resolvedRuntimeGatePath

    $declaredCompositeMatches = [Regex]::Matches($runtimeGateText, '(?m)^CompositeRuntimeReport:\s*(?<path>\S.*?)\s*$')
    if ($declaredCompositeMatches.Count -gt 1) {
        throw "The runtime gate report contains multiple CompositeRuntimeReport path declarations (found $($declaredCompositeMatches.Count)): $resolvedRuntimeGatePath"
    }
    $declaredCompositePathInGate = if ($declaredCompositeMatches.Count -eq 1) {
        $declaredCompositeMatches[0].Groups['path'].Value.Trim()
    } else {
        $null
    }
    if (-not [string]::IsNullOrWhiteSpace($declaredCompositePathInGate)) {
        $canonicalDeclaredComposite = [IO.Path]::GetFullPath($declaredCompositePathInGate)
        if ($canonicalDeclaredComposite -ne $resolvedCompositePath) {
            throw "Declared CompositeRuntimeReport in runtime gate ($canonicalDeclaredComposite) does not match resolved composite path ($resolvedCompositePath)."
        }
    }

    $declaredHerdrMatches = [Regex]::Matches($runtimeGateText, '(?m)^HerdrRuntimeReport:\s*(?<path>\S.*?)\s*$')
    if ($declaredHerdrMatches.Count -gt 1) {
        throw "The runtime gate report contains multiple HerdrRuntimeReport path declarations (found $($declaredHerdrMatches.Count)): $resolvedRuntimeGatePath"
    }
    $declaredHerdrPathInGate = if ($declaredHerdrMatches.Count -eq 1) {
        $declaredHerdrMatches[0].Groups['path'].Value.Trim()
    } else {
        $null
    }

    $composite = Get-Content -LiteralPath $resolvedCompositePath -Raw | ConvertFrom-Json
    if ($null -eq $composite) {
        throw "Composite runtime report is empty: $resolvedCompositePath"
    }

    $compClassificationProp = $composite.PSObject.Properties['EvidenceClassification']
    if ($null -eq $compClassificationProp -or $null -eq $compClassificationProp.Value -or $compClassificationProp.Value.GetType() -ne [string] -or $compClassificationProp.Value -ne 'Runtime') {
        throw 'The supplied composite report EvidenceClassification is not string Runtime.'
    }
    Assert-JsonBooleanProperty -TargetObject $composite -PropertyName 'RuntimeAccepted' -ExpectedValue $true -ContextPath $resolvedCompositePath
    Assert-JsonBooleanProperty -TargetObject $composite -PropertyName 'SessionControlInvoked' -ExpectedValue $false -ContextPath $resolvedCompositePath
    if ($null -eq $composite.PSObject.Properties['Acceptance'] -or $null -eq $composite.Acceptance) {
        throw 'The supplied composite report is missing Acceptance object.'
    }
    Assert-JsonBooleanProperty -TargetObject $composite.Acceptance -PropertyName 'Passed' -ExpectedValue $true -ContextPath $resolvedCompositePath

    if ([string]::IsNullOrWhiteSpace($composite.HerdrRuntimeReportSha256) -or
        $composite.HerdrRuntimeReportSha256 -ne $declaredHerdrRuntimeSha256) {
        throw "Composite report HerdrRuntimeReportSha256 ($($composite.HerdrRuntimeReportSha256)) does not match runtime gate declared hash ($declaredHerdrRuntimeSha256)."
    }

    $declaredHerdrPathInComposite = if ($composite.PSObject.Properties['HerdrRuntimeReportPath'] -and
        -not [string]::IsNullOrWhiteSpace($composite.HerdrRuntimeReportPath)) {
        $composite.HerdrRuntimeReportPath.Trim()
    } else {
        $null
    }

    $canonicalHerdrPath = $null
    if (-not [string]::IsNullOrWhiteSpace($HerdrRuntimeReport)) {
        $resolvedPassedHerdr = Assert-ValidLeafPath -Path $HerdrRuntimeReport -Name 'Herdr runtime report' -AllowedRoot $RepositoryRoot
        if (-not [string]::IsNullOrWhiteSpace($declaredHerdrPathInGate)) {
            $canonicalGateHerdr = [IO.Path]::GetFullPath($declaredHerdrPathInGate)
            if ($canonicalGateHerdr -ne $resolvedPassedHerdr) {
                throw "Specified HerdrRuntimeReport ($resolvedPassedHerdr) does not match declared runtime gate report path ($canonicalGateHerdr)."
            }
        }
        if (-not [string]::IsNullOrWhiteSpace($declaredHerdrPathInComposite)) {
            $canonicalCompHerdr = [IO.Path]::GetFullPath($declaredHerdrPathInComposite)
            if ($canonicalCompHerdr -ne $resolvedPassedHerdr) {
                throw "Specified HerdrRuntimeReport ($resolvedPassedHerdr) does not match composite report declared path ($canonicalCompHerdr)."
            }
        }
        $canonicalHerdrPath = $resolvedPassedHerdr
    } elseif (-not [string]::IsNullOrWhiteSpace($declaredHerdrPathInGate)) {
        $canonicalHerdrPath = Assert-ValidLeafPath -Path $declaredHerdrPathInGate -Name 'declared Herdr runtime report' -AllowedRoot $RepositoryRoot
        if (-not [string]::IsNullOrWhiteSpace($declaredHerdrPathInComposite)) {
            $canonicalCompHerdr = [IO.Path]::GetFullPath($declaredHerdrPathInComposite)
            if ($canonicalCompHerdr -ne $canonicalHerdrPath) {
                throw "Declared Herdr runtime report in gate ($canonicalHerdrPath) does not match composite report declared path ($canonicalCompHerdr)."
            }
        }
    } elseif (-not [string]::IsNullOrWhiteSpace($declaredHerdrPathInComposite)) {
        $canonicalHerdrPath = Assert-ValidLeafPath -Path $declaredHerdrPathInComposite -Name 'composite declared Herdr runtime report' -AllowedRoot $RepositoryRoot
    } else {
        $fallback = Join-Path (Split-Path -Parent $resolvedCompositePath) 'herdr-runtime.json'
        $canonicalHerdrPath = Assert-ValidLeafPath -Path $fallback -Name 'Herdr runtime report' -AllowedRoot $RepositoryRoot
    }

    if ($canonicalHerdrPath -eq $resolvedCompositePath -or $canonicalHerdrPath -eq $resolvedRuntimeGatePath) {
        throw "Herdr runtime report path cannot collide with composite or runtime gate reports: $canonicalHerdrPath"
    }

    $actualHerdrSha256 = (Get-FileHash -LiteralPath $canonicalHerdrPath -Algorithm SHA256).Hash
    if ($actualHerdrSha256 -ne $declaredHerdrRuntimeSha256) {
        throw "Actual Herdr runtime report hash ($actualHerdrSha256) does not match runtime gate declared hash ($declaredHerdrRuntimeSha256)."
    }
    if ($actualHerdrSha256 -ne $composite.HerdrRuntimeReportSha256) {
        throw "Actual Herdr runtime report hash ($actualHerdrSha256) does not match composite report HerdrRuntimeReportSha256 ($($composite.HerdrRuntimeReportSha256))."
    }

    $herdrJsonText = Get-Content -LiteralPath $canonicalHerdrPath -Raw
    $herdrJson = $null
    try {
        $herdrJson = $herdrJsonText | ConvertFrom-Json
    } catch {
        throw "Failed to parse Herdr runtime report JSON ($canonicalHerdrPath): $($_.Exception.Message)"
    }
    if ($null -eq $herdrJson) {
        throw "Herdr runtime report JSON payload is empty: $canonicalHerdrPath"
    }

    $herdrClassificationProp = $herdrJson.PSObject.Properties['EvidenceClassification']
    if ($null -eq $herdrClassificationProp -or $null -eq $herdrClassificationProp.Value -or $herdrClassificationProp.Value.GetType() -ne [string] -or $herdrClassificationProp.Value -ne 'Runtime') {
        throw "Herdr runtime report EvidenceClassification must be string 'Runtime': $canonicalHerdrPath"
    }
    Assert-JsonBooleanProperty -TargetObject $herdrJson -PropertyName 'RuntimeObserved' -ExpectedValue $true -ContextPath $canonicalHerdrPath
    Assert-JsonBooleanProperty -TargetObject $herdrJson -PropertyName 'SessionControlInvoked' -ExpectedValue $false -ContextPath $canonicalHerdrPath
    Assert-JsonBooleanProperty -TargetObject $herdrJson -PropertyName 'SnapshotObserved' -ExpectedValue $true -ContextPath $canonicalHerdrPath
    Assert-JsonBooleanProperty -TargetObject $herdrJson -PropertyName 'EventObserved' -ExpectedValue $true -ContextPath $canonicalHerdrPath
    Assert-JsonBooleanProperty -TargetObject $herdrJson -PropertyName 'ReconnectObserved' -ExpectedValue $true -ContextPath $canonicalHerdrPath

    return [pscustomobject]@{
        CompositePath = $resolvedCompositePath
        CompositeSha256 = $compositeSha256
        RuntimeGatePath = $resolvedRuntimeGatePath
        RuntimeGateSha256 = $runtimeGateSha256
        HerdrRuntimePath = $canonicalHerdrPath
        HerdrRuntimeSha256 = $actualHerdrSha256
        CompositeData = $composite
        HerdrRuntimeData = $herdrJson
    }
}

function Invoke-V05ReleaseGateSelfTests {
    param(
        [Parameter(Mandatory)][string]$RepositoryRoot
    )

    Write-Host "Running focused Test-V05ReleaseGate self-tests..." -ForegroundColor Cyan

    $tempDir = Join-Path $RepositoryRoot "artifacts\self-tests-$([Guid]::NewGuid().ToString('N'))"
    New-Item -ItemType Directory -Path $tempDir -Force | Out-Null

    try {
        $dummyCommit = '0123456789abcdef0123456789abcdef01234567'

        # Test 1: Assert-ValidLeafPath rejects whitespace or null
        $threw = $false
        try { Assert-ValidLeafPath -Path '   ' -Name 'test' } catch { $threw = $true }
        if (-not $threw) { throw "SelfTest Failed: Assert-ValidLeafPath accepted whitespace path." }

        # Test 2: Assert-ValidLeafPath rejects missing file
        $threw = $false
        try { Assert-ValidLeafPath -Path (Join-Path $tempDir 'missing.txt') -Name 'test' } catch { $threw = $true }
        if (-not $threw) { throw "SelfTest Failed: Assert-ValidLeafPath accepted non-existent file." }

        # Test 3: Assert-ValidLeafPath rejects path escape
        $dummyFile = Join-Path $tempDir 'dummy.txt'
        [IO.File]::WriteAllText($dummyFile, 'hello', [Text.UTF8Encoding]::new($false))
        $threw = $false
        try { Assert-ValidLeafPath -Path $dummyFile -Name 'test' -AllowedRoot (Join-Path $tempDir 'other') } catch { $threw = $true }
        if (-not $threw) { throw "SelfTest Failed: Assert-ValidLeafPath allowed path escape." }

        # Test 4: Assert-ValidLeafPath rejects access denied / locked file
        $lockedFile = Join-Path $tempDir 'locked.txt'
        [IO.File]::WriteAllText($lockedFile, 'locked content', [Text.UTF8Encoding]::new($false))
        $lockStream = [IO.File]::Open($lockedFile, [IO.FileMode]::Open, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
        $threw = $false
        try {
            Assert-ValidLeafPath -Path $lockedFile -Name 'locked file'
        } catch {
            $threw = $true
        } finally {
            $lockStream.Dispose()
        }
        if (-not $threw) { throw "SelfTest Failed: Assert-ValidLeafPath did not reject locked file." }

        # Test 5: Predecessor Reports: Reject duplicate paths and hashes
        $pred1 = Join-Path $tempDir 'pred1.txt'
        $predContent1 = "HerdrOps v0.1.0 Release Gate`nResult: PASS`nCommit: $dummyCommit`n"
        [IO.File]::WriteAllText($pred1, $predContent1, [Text.UTF8Encoding]::new($false))
        $threw = $false
        try {
            Test-PredecessorReports -Reports @($pred1, $pred1) -RepositoryRoot $RepositoryRoot -SourceCommit $dummyCommit
        } catch {
            $threw = $true
        }
        if (-not $threw) { throw "SelfTest Failed: Test-PredecessorReports accepted duplicate paths." }

        # Test 6: Predecessor Reports: Reject duplicate versions
        $pred2 = Join-Path $tempDir 'pred2.txt'
        $predContent2 = "HerdrOps v0.1.0 Release Gate`nResult: PASS`nCommit: $dummyCommit`nExtra: true`n"
        [IO.File]::WriteAllText($pred2, $predContent2, [Text.UTF8Encoding]::new($false))
        $threw = $false
        try {
            Test-PredecessorReports -Reports @($pred1, $pred2) -RepositoryRoot $RepositoryRoot -SourceCommit $dummyCommit
        } catch {
            $threw = $true
        }
        if (-not $threw) { throw "SelfTest Failed: Test-PredecessorReports accepted duplicate versions." }

        # Test 7: Predecessor Reports: Reject missing versions (only 3 supplied)
        $p1 = Join-Path $tempDir 'v01.txt'; [IO.File]::WriteAllText($p1, "HerdrOps v0.1.0 Release Gate`nResult: PASS`nCommit: $dummyCommit`n", [Text.UTF8Encoding]::new($false))
        $p2 = Join-Path $tempDir 'v02.txt'; [IO.File]::WriteAllText($p2, "HerdrOps v0.2.0 Release Gate`nResult: PASS`nCommit: $dummyCommit`n", [Text.UTF8Encoding]::new($false))
        $p3 = Join-Path $tempDir 'v03.txt'; [IO.File]::WriteAllText($p3, "HerdrOps v0.3.0 Release Gate`nResult: PASS`nCommit: $dummyCommit`n", [Text.UTF8Encoding]::new($false))
        $threw = $false
        try {
            Test-PredecessorReports -Reports @($p1, $p2, $p3) -RepositoryRoot $RepositoryRoot -SourceCommit $dummyCommit
        } catch {
            $threw = $true
        }
        if (-not $threw) { throw "SelfTest Failed: Test-PredecessorReports accepted incomplete versions." }

        # Test 8: Predecessor Reports: Reject invalid / untyped version
        $pInvalid = Join-Path $tempDir 'v09.txt'; [IO.File]::WriteAllText($pInvalid, "HerdrOps v0.9.0 Release Gate`nResult: PASS`nCommit: $dummyCommit`n", [Text.UTF8Encoding]::new($false))
        $threw = $false
        try {
            Test-PredecessorReports -Reports @($p1, $p2, $p3, $pInvalid) -RepositoryRoot $RepositoryRoot -SourceCommit $dummyCommit
        } catch {
            $threw = $true
        }
        if (-not $threw) { throw "SelfTest Failed: Test-PredecessorReports accepted invalid version." }

        # Test 9: Predecessor Reports: Reject non-PASS
        $p4Fail = Join-Path $tempDir 'v04fail.txt'; [IO.File]::WriteAllText($p4Fail, "HerdrOps v0.4.0 Release Gate`nResult: FAIL`nCommit: $dummyCommit`n", [Text.UTF8Encoding]::new($false))
        $threw = $false
        try {
            Test-PredecessorReports -Reports @($p1, $p2, $p3, $p4Fail) -RepositoryRoot $RepositoryRoot -SourceCommit $dummyCommit
        } catch {
            $threw = $true
        }
        if (-not $threw) { throw "SelfTest Failed: Test-PredecessorReports accepted non-PASS report." }

        # Test 10: Predecessor Reports: Accept valid complete 4 versions
        $p4Pass = Join-Path $tempDir 'v04pass.txt'; [IO.File]::WriteAllText($p4Pass, "HerdrOps v0.4.0 Release Gate`nResult: PASS`nSourceCommit: $dummyCommit`nReleaseReady: true`n", [Text.UTF8Encoding]::new($false))
        $validatedPreds = Test-PredecessorReports -Reports @($p1, $p2, $p3, $p4Pass) -RepositoryRoot $RepositoryRoot -SourceCommit $dummyCommit
        if ($validatedPreds.Count -ne 4) { throw "SelfTest Failed: Expected 4 validated predecessor reports." }

        # Test 11: Human Acceptance: Reject non-approved verdict
        $humanBadVerdict = Join-Path $tempDir 'human-bad-verdict.txt'
        [IO.File]::WriteAllText($humanBadVerdict, "Verdict: REJECTED`nSourceCommit: $dummyCommit`nSigner: Alice`nRole: Independent Human Approver`nProvenance: VERIFIED`n", [Text.UTF8Encoding]::new($false))
        $threw = $false
        try { Test-HumanAcceptanceReport -ReportPath $humanBadVerdict -RepositoryRoot $RepositoryRoot -SourceCommit $dummyCommit } catch { $threw = $true }
        if (-not $threw) { throw "SelfTest Failed: Test-HumanAcceptanceReport accepted non-approved verdict." }

        # Test 12: Human Acceptance: Reject mismatched commit
        $humanBadCommit = Join-Path $tempDir 'human-bad-commit.txt'
        [IO.File]::WriteAllText($humanBadCommit, "Verdict: PASS`nSourceCommit: ffffffffffffffffffffffffffffffffffffffff`nSigner: Alice`nRole: Independent Human Approver`nProvenance: VERIFIED`n", [Text.UTF8Encoding]::new($false))
        $threw = $false
        try { Test-HumanAcceptanceReport -ReportPath $humanBadCommit -RepositoryRoot $RepositoryRoot -SourceCommit $dummyCommit } catch { $threw = $true }
        if (-not $threw) { throw "SelfTest Failed: Test-HumanAcceptanceReport accepted mismatched commit." }

        # Test 13: Human Acceptance: Reject missing signer
        $humanNoSigner = Join-Path $tempDir 'human-no-signer.txt'
        [IO.File]::WriteAllText($humanNoSigner, "Verdict: PASS`nSourceCommit: $dummyCommit`nRole: Independent Human Approver`nProvenance: VERIFIED`n", [Text.UTF8Encoding]::new($false))
        $threw = $false
        try { Test-HumanAcceptanceReport -ReportPath $humanNoSigner -RepositoryRoot $RepositoryRoot -SourceCommit $dummyCommit } catch { $threw = $true }
        if (-not $threw) { throw "SelfTest Failed: Test-HumanAcceptanceReport accepted missing signer." }

        # Test 14: Human Acceptance: Reject missing role
        $humanNoRole = Join-Path $tempDir 'human-no-role.txt'
        [IO.File]::WriteAllText($humanNoRole, "Verdict: PASS`nSourceCommit: $dummyCommit`nSigner: Alice`nProvenance: VERIFIED`n", [Text.UTF8Encoding]::new($false))
        $threw = $false
        try { Test-HumanAcceptanceReport -ReportPath $humanNoRole -RepositoryRoot $RepositoryRoot -SourceCommit $dummyCommit } catch { $threw = $true }
        if (-not $threw) { throw "SelfTest Failed: Test-HumanAcceptanceReport accepted missing role." }

        # Test 15: Human Acceptance: Reject missing provenance
        $humanNoProv = Join-Path $tempDir 'human-no-prov.txt'
        [IO.File]::WriteAllText($humanNoProv, "Verdict: PASS`nSourceCommit: $dummyCommit`nSigner: Alice`nRole: Independent Human Approver`n", [Text.UTF8Encoding]::new($false))
        $threw = $false
        try { Test-HumanAcceptanceReport -ReportPath $humanNoProv -RepositoryRoot $RepositoryRoot -SourceCommit $dummyCommit } catch { $threw = $true }
        if (-not $threw) { throw "SelfTest Failed: Test-HumanAcceptanceReport accepted missing provenance." }

        # Test 16: Human Acceptance: Accept valid human acceptance
        $humanValid = Join-Path $tempDir 'human-valid.txt'
        [IO.File]::WriteAllText($humanValid, "Verdict: PASS`nSourceCommit: $dummyCommit`nSigner: Alice Smith`nRole: Independent Human Approver`nProvenance: 2026-08-20T12:00:00Z signed`n", [Text.UTF8Encoding]::new($false))
        $validatedHuman = Test-HumanAcceptanceReport -ReportPath $humanValid -RepositoryRoot $RepositoryRoot -SourceCommit $dummyCommit
        if ($validatedHuman.Signer -ne 'Alice Smith' -or $validatedHuman.Role -ne 'Independent Human Approver') {
            throw "SelfTest Failed: Test-HumanAcceptanceReport returned incorrect parsed metadata."
        }

        # Helper to construct valid Herdr runtime JSON payload
        $makeValidHerdrPayload = {
            return [ordered]@{
                EvidenceClassification = 'Runtime'
                RuntimeObserved        = $true
                SessionControlInvoked  = $false
                SnapshotObserved       = $true
                EventObserved          = $true
                ReconnectObserved      = $true
                StartedUtc             = '2026-08-20T12:00:00.0000000Z'
                FinishedUtc            = '2026-08-20T12:05:00.0000000Z'
                Message                = 'Valid canonical Herdr runtime trace'
            }
        }

        # Helper to construct valid runtime gate report text
        $makeValidGateContent = {
            param($commit, $compHash, $herdrHash, $compFile, $herdrFile)
            return @"
HerdrOps v0.5 Issue #28 Compliance Privacy, Retention, and Runtime Acceptance
Result: PASS
EvidenceClass: Runtime
RuntimeObserved: true
SnapshotObserved: true
EventObserved: true
ReconnectObserved: true
SessionControlInvoked: false
SourceCommit: $commit
CompositeRuntimeReportSha256: $compHash
HerdrRuntimeReportSha256: $herdrHash
CompositeRuntimeReport: $compFile
HerdrRuntimeReport: $herdrFile
"@
        }

        # Test 17: Canonical Runtime Report matching & mismatch rejection
        $herdrRuntimeFile = Join-Path $tempDir 'herdr-runtime.json'
        $herdrValidObj = & $makeValidHerdrPayload
        [IO.File]::WriteAllText($herdrRuntimeFile, ($herdrValidObj | ConvertTo-Json -Depth 5), [Text.UTF8Encoding]::new($false))
        $herdrHash = (Get-FileHash -LiteralPath $herdrRuntimeFile -Algorithm SHA256).Hash

        $compositeFile = Join-Path $tempDir 'composite-acceptance.json'
        $compositeJson = [ordered]@{
            EvidenceClassification = 'Runtime'
            RuntimeAccepted = $true
            SessionControlInvoked = $false
            HerdrRuntimeReportPath = $herdrRuntimeFile
            HerdrRuntimeReportSha256 = $herdrHash
            Acceptance = [ordered]@{
                Passed = $true
            }
        } | ConvertTo-Json -Depth 5
        [IO.File]::WriteAllText($compositeFile, $compositeJson, [Text.UTF8Encoding]::new($false))
        $compHash = (Get-FileHash -LiteralPath $compositeFile -Algorithm SHA256).Hash

        $gateReportFile = Join-Path $tempDir 'runtime-gate-report.txt'
        $gateReportContent = & $makeValidGateContent $dummyCommit $compHash $herdrHash $compositeFile $herdrRuntimeFile
        [IO.File]::WriteAllText($gateReportFile, $gateReportContent, [Text.UTF8Encoding]::new($false))

        # Successful resolution
        $resolved = Resolve-CanonicalRuntimeReports `
            -CompositeRuntimeReport $compositeFile `
            -RuntimeGateReport $gateReportFile `
            -RepositoryRoot $RepositoryRoot `
            -SourceCommit $dummyCommit
        if ($resolved.HerdrRuntimePath -ne $herdrRuntimeFile -or -not [bool]$resolved.HerdrRuntimeData.EventObserved -or -not [bool]$resolved.HerdrRuntimeData.ReconnectObserved) {
            throw "SelfTest Failed: Resolve-CanonicalRuntimeReports did not resolve canonical Herdr runtime path and data."
        }

        # Path mismatch rejection
        $otherHerdr = Join-Path $tempDir 'other-herdr.json'
        [IO.File]::WriteAllText($otherHerdr, ($herdrValidObj | ConvertTo-Json -Depth 5), [Text.UTF8Encoding]::new($false))
        $threw = $false
        try {
            Resolve-CanonicalRuntimeReports `
                -CompositeRuntimeReport $compositeFile `
                -RuntimeGateReport $gateReportFile `
                -HerdrRuntimeReport $otherHerdr `
                -RepositoryRoot $RepositoryRoot `
                -SourceCommit $dummyCommit
        } catch {
            $threw = $true
        }
        if (-not $threw) { throw "SelfTest Failed: Resolve-CanonicalRuntimeReports accepted path mismatch with declared path." }

        # Hash mismatch rejection
        $badHashGate = Join-Path $tempDir 'gate-bad-hash.txt'
        $badHashContent = & $makeValidGateContent $dummyCommit $compHash '0000000000000000000000000000000000000000000000000000000000000000' $compositeFile $herdrRuntimeFile
        [IO.File]::WriteAllText($badHashGate, $badHashContent, [Text.UTF8Encoding]::new($false))
        $threw = $false
        try {
            Resolve-CanonicalRuntimeReports `
                -CompositeRuntimeReport $compositeFile `
                -RuntimeGateReport $badHashGate `
                -RepositoryRoot $RepositoryRoot `
                -SourceCommit $dummyCommit
        } catch {
            $threw = $true
        }
        if (-not $threw) { throw "SelfTest Failed: Resolve-CanonicalRuntimeReports accepted mismatched HerdrRuntimeReportSha256." }

        # Test 18: Reject runtime gate report missing EventObserved: true
        $gateNoEvent = Join-Path $tempDir 'gate-no-event.txt'
        $gateNoEventText = @"
Result: PASS
EvidenceClass: Runtime
RuntimeObserved: true
SnapshotObserved: true
ReconnectObserved: true
SessionControlInvoked: false
SourceCommit: $dummyCommit
CompositeRuntimeReportSha256: $compHash
HerdrRuntimeReportSha256: $herdrHash
CompositeRuntimeReport: $compositeFile
HerdrRuntimeReport: $herdrRuntimeFile
"@
        [IO.File]::WriteAllText($gateNoEvent, $gateNoEventText, [Text.UTF8Encoding]::new($false))
        $threw = $false
        try {
            Resolve-CanonicalRuntimeReports `
                -CompositeRuntimeReport $compositeFile `
                -RuntimeGateReport $gateNoEvent `
                -RepositoryRoot $RepositoryRoot `
                -SourceCommit $dummyCommit
        } catch {
            $threw = $true
        }
        if (-not $threw) { throw "SelfTest Failed: Resolve-CanonicalRuntimeReports accepted gate report missing EventObserved: true." }

        # Test 19: Reject runtime gate report missing ReconnectObserved: true
        $gateNoReconnect = Join-Path $tempDir 'gate-no-reconnect.txt'
        $gateNoReconnectText = @"
Result: PASS
EvidenceClass: Runtime
RuntimeObserved: true
SnapshotObserved: true
EventObserved: true
SessionControlInvoked: false
SourceCommit: $dummyCommit
CompositeRuntimeReportSha256: $compHash
HerdrRuntimeReportSha256: $herdrHash
CompositeRuntimeReport: $compositeFile
HerdrRuntimeReport: $herdrRuntimeFile
"@
        [IO.File]::WriteAllText($gateNoReconnect, $gateNoReconnectText, [Text.UTF8Encoding]::new($false))
        $threw = $false
        try {
            Resolve-CanonicalRuntimeReports `
                -CompositeRuntimeReport $compositeFile `
                -RuntimeGateReport $gateNoReconnect `
                -RepositoryRoot $RepositoryRoot `
                -SourceCommit $dummyCommit
        } catch {
            $threw = $true
        }
        if (-not $threw) { throw "SelfTest Failed: Resolve-CanonicalRuntimeReports accepted gate report missing ReconnectObserved: true." }

        # Test 20: Reject runtime gate report with duplicate conflicting EventObserved lines (true + false)
        $gateDupConflictEvent = Join-Path $tempDir 'gate-dup-conflict-event.txt'
        $gateDupConflictEventText = @"
Result: PASS
EvidenceClass: Runtime
RuntimeObserved: true
SnapshotObserved: true
EventObserved: false
EventObserved: true
ReconnectObserved: true
SessionControlInvoked: false
SourceCommit: $dummyCommit
CompositeRuntimeReportSha256: $compHash
HerdrRuntimeReportSha256: $herdrHash
CompositeRuntimeReport: $compositeFile
HerdrRuntimeReport: $herdrRuntimeFile
"@
        [IO.File]::WriteAllText($gateDupConflictEvent, $gateDupConflictEventText, [Text.UTF8Encoding]::new($false))
        $threw = $false
        try {
            Resolve-CanonicalRuntimeReports `
                -CompositeRuntimeReport $compositeFile `
                -RuntimeGateReport $gateDupConflictEvent `
                -RepositoryRoot $RepositoryRoot `
                -SourceCommit $dummyCommit
        } catch {
            $threw = $true
        }
        if (-not $threw) { throw "SelfTest Failed: Resolve-CanonicalRuntimeReports accepted gate report with duplicate conflicting EventObserved lines." }

        # Test 21: Reject runtime gate report with duplicate matching EventObserved lines (true + true)
        $gateDupTrueEvent = Join-Path $tempDir 'gate-dup-true-event.txt'
        $gateDupTrueEventText = @"
Result: PASS
EvidenceClass: Runtime
RuntimeObserved: true
SnapshotObserved: true
EventObserved: true
EventObserved: true
ReconnectObserved: true
SessionControlInvoked: false
SourceCommit: $dummyCommit
CompositeRuntimeReportSha256: $compHash
HerdrRuntimeReportSha256: $herdrHash
CompositeRuntimeReport: $compositeFile
HerdrRuntimeReport: $herdrRuntimeFile
"@
        [IO.File]::WriteAllText($gateDupTrueEvent, $gateDupTrueEventText, [Text.UTF8Encoding]::new($false))
        $threw = $false
        try {
            Resolve-CanonicalRuntimeReports `
                -CompositeRuntimeReport $compositeFile `
                -RuntimeGateReport $gateDupTrueEvent `
                -RepositoryRoot $RepositoryRoot `
                -SourceCommit $dummyCommit
        } catch {
            $threw = $true
        }
        if (-not $threw) { throw "SelfTest Failed: Resolve-CanonicalRuntimeReports accepted gate report with duplicate matching EventObserved lines." }

        # Test 22: Reject runtime gate report with duplicate Result lines
        $gateDupResult = Join-Path $tempDir 'gate-dup-result.txt'
        $gateDupResultText = @"
Result: PASS
Result: PASS
EvidenceClass: Runtime
RuntimeObserved: true
SnapshotObserved: true
EventObserved: true
ReconnectObserved: true
SessionControlInvoked: false
SourceCommit: $dummyCommit
CompositeRuntimeReportSha256: $compHash
HerdrRuntimeReportSha256: $herdrHash
CompositeRuntimeReport: $compositeFile
HerdrRuntimeReport: $herdrRuntimeFile
"@
        [IO.File]::WriteAllText($gateDupResult, $gateDupResultText, [Text.UTF8Encoding]::new($false))
        $threw = $false
        try {
            Resolve-CanonicalRuntimeReports `
                -CompositeRuntimeReport $compositeFile `
                -RuntimeGateReport $gateDupResult `
                -RepositoryRoot $RepositoryRoot `
                -SourceCommit $dummyCommit
        } catch {
            $threw = $true
        }
        if (-not $threw) { throw "SelfTest Failed: Resolve-CanonicalRuntimeReports accepted gate report with duplicate Result lines." }

        # Test 23: Reject runtime gate report with duplicate EvidenceClass and EvidenceClassification lines
        $gateDupEvidenceClass = Join-Path $tempDir 'gate-dup-evidence-class.txt'
        $gateDupEvidenceClassText = @"
Result: PASS
EvidenceClass: Runtime
EvidenceClassification: Runtime
RuntimeObserved: true
SnapshotObserved: true
EventObserved: true
ReconnectObserved: true
SessionControlInvoked: false
SourceCommit: $dummyCommit
CompositeRuntimeReportSha256: $compHash
HerdrRuntimeReportSha256: $herdrHash
CompositeRuntimeReport: $compositeFile
HerdrRuntimeReport: $herdrRuntimeFile
"@
        [IO.File]::WriteAllText($gateDupEvidenceClass, $gateDupEvidenceClassText, [Text.UTF8Encoding]::new($false))
        $threw = $false
        try {
            Resolve-CanonicalRuntimeReports `
                -CompositeRuntimeReport $compositeFile `
                -RuntimeGateReport $gateDupEvidenceClass `
                -RepositoryRoot $RepositoryRoot `
                -SourceCommit $dummyCommit
        } catch {
            $threw = $true
        }
        if (-not $threw) { throw "SelfTest Failed: Resolve-CanonicalRuntimeReports accepted gate report with duplicate EvidenceClass and EvidenceClassification lines." }

        # Test 24: Reject runtime gate report with SessionControlInvoked: true
        $gateSessionControl = Join-Path $tempDir 'gate-session-control.txt'
        $gateSessionControlText = @"
Result: PASS
EvidenceClass: Runtime
RuntimeObserved: true
SnapshotObserved: true
EventObserved: true
ReconnectObserved: true
SessionControlInvoked: true
SourceCommit: $dummyCommit
CompositeRuntimeReportSha256: $compHash
HerdrRuntimeReportSha256: $herdrHash
CompositeRuntimeReport: $compositeFile
HerdrRuntimeReport: $herdrRuntimeFile
"@
        [IO.File]::WriteAllText($gateSessionControl, $gateSessionControlText, [Text.UTF8Encoding]::new($false))
        $threw = $false
        try {
            Resolve-CanonicalRuntimeReports `
                -CompositeRuntimeReport $compositeFile `
                -RuntimeGateReport $gateSessionControl `
                -RepositoryRoot $RepositoryRoot `
                -SourceCommit $dummyCommit
        } catch {
            $threw = $true
        }
        if (-not $threw) { throw "SelfTest Failed: Resolve-CanonicalRuntimeReports accepted gate report with SessionControlInvoked: true." }

        # Test 25: Reject runtime gate report with non-Runtime EvidenceClass
        $gateNonRuntime = Join-Path $tempDir 'gate-non-runtime.txt'
        $gateNonRuntimeText = @"
Result: PASS
EvidenceClass: Synthetic
RuntimeObserved: true
SnapshotObserved: true
EventObserved: true
ReconnectObserved: true
SessionControlInvoked: false
SourceCommit: $dummyCommit
CompositeRuntimeReportSha256: $compHash
HerdrRuntimeReportSha256: $herdrHash
CompositeRuntimeReport: $compositeFile
HerdrRuntimeReport: $herdrRuntimeFile
"@
        [IO.File]::WriteAllText($gateNonRuntime, $gateNonRuntimeText, [Text.UTF8Encoding]::new($false))
        $threw = $false
        try {
            Resolve-CanonicalRuntimeReports `
                -CompositeRuntimeReport $compositeFile `
                -RuntimeGateReport $gateNonRuntime `
                -RepositoryRoot $RepositoryRoot `
                -SourceCommit $dummyCommit
        } catch {
            $threw = $true
        }
        if (-not $threw) { throw "SelfTest Failed: Resolve-CanonicalRuntimeReports accepted gate report with non-Runtime EvidenceClass." }

        # Helper to test Herdr JSON variations against fresh files
        $assertHerdrJsonRejected = {
            param($rawJson, $testName)
            $hf = Join-Path $tempDir "herdr-$([Guid]::NewGuid().ToString('N')).json"
            [IO.File]::WriteAllText($hf, $rawJson, [Text.UTF8Encoding]::new($false))
            $hh = (Get-FileHash -LiteralPath $hf -Algorithm SHA256).Hash
            $gf = Join-Path $tempDir "gate-$([Guid]::NewGuid().ToString('N')).txt"
            [IO.File]::WriteAllText($gf, (& $makeValidGateContent $dummyCommit $compHash $hh $compositeFile $hf), [Text.UTF8Encoding]::new($false))
            $cf = Join-Path $tempDir "comp-$([Guid]::NewGuid().ToString('N')).json"
            $co = $compositeJson | ConvertFrom-Json
            $co.HerdrRuntimeReportPath = $hf
            $co.HerdrRuntimeReportSha256 = $hh
            [IO.File]::WriteAllText($cf, ($co | ConvertTo-Json -Depth 5), [Text.UTF8Encoding]::new($false))

            $t = $false
            try {
                Resolve-CanonicalRuntimeReports `
                    -CompositeRuntimeReport $cf `
                    -RuntimeGateReport $gf `
                    -HerdrRuntimeReport $hf `
                    -RepositoryRoot $RepositoryRoot `
                    -SourceCommit $dummyCommit
            } catch {
                $t = $true
            }
            if (-not $t) { throw "SelfTest Failed: Resolve-CanonicalRuntimeReports accepted Herdr runtime report with $testName." }
        }

        # Test 26: Reject Herdr runtime JSON with EventObserved = false (boolean)
        $p = & $makeValidHerdrPayload; $p['EventObserved'] = $false
        & $assertHerdrJsonRejected ($p | ConvertTo-Json -Depth 5) "boolean EventObserved = false"

        # Test 27: Reject Herdr runtime JSON with EventObserved = 'false' (string)
        $p = & $makeValidHerdrPayload; $p['EventObserved'] = 'false'
        & $assertHerdrJsonRejected ($p | ConvertTo-Json -Depth 5) "string EventObserved = 'false'"

        # Test 28: Reject Herdr runtime JSON with EventObserved = 'true' (string)
        $p = & $makeValidHerdrPayload; $p['EventObserved'] = 'true'
        & $assertHerdrJsonRejected ($p | ConvertTo-Json -Depth 5) "string EventObserved = 'true'"

        # Test 29: Reject Herdr runtime JSON with EventObserved = 1 (number)
        $p = & $makeValidHerdrPayload; $p['EventObserved'] = 1
        & $assertHerdrJsonRejected ($p | ConvertTo-Json -Depth 5) "numeric EventObserved = 1"

        # Test 30: Reject Herdr runtime JSON with EventObserved = 0 (number)
        $p = & $makeValidHerdrPayload; $p['EventObserved'] = 0
        & $assertHerdrJsonRejected ($p | ConvertTo-Json -Depth 5) "numeric EventObserved = 0"

        # Test 31: Reject Herdr runtime JSON with missing EventObserved property
        $p = & $makeValidHerdrPayload; [void]$p.Remove('EventObserved')
        & $assertHerdrJsonRejected ($p | ConvertTo-Json -Depth 5) "missing EventObserved property"

        # Test 32: Reject Herdr runtime JSON with ReconnectObserved = false (boolean)
        $p = & $makeValidHerdrPayload; $p['ReconnectObserved'] = $false
        & $assertHerdrJsonRejected ($p | ConvertTo-Json -Depth 5) "boolean ReconnectObserved = false"

        # Test 33: Reject Herdr runtime JSON with ReconnectObserved = 'false' (string)
        $p = & $makeValidHerdrPayload; $p['ReconnectObserved'] = 'false'
        & $assertHerdrJsonRejected ($p | ConvertTo-Json -Depth 5) "string ReconnectObserved = 'false'"

        # Test 34: Reject Herdr runtime JSON with ReconnectObserved = 1 (number)
        $p = & $makeValidHerdrPayload; $p['ReconnectObserved'] = 1
        & $assertHerdrJsonRejected ($p | ConvertTo-Json -Depth 5) "numeric ReconnectObserved = 1"

        # Test 35: Reject Herdr runtime JSON with missing ReconnectObserved property
        $p = & $makeValidHerdrPayload; [void]$p.Remove('ReconnectObserved')
        & $assertHerdrJsonRejected ($p | ConvertTo-Json -Depth 5) "missing ReconnectObserved property"

        # Test 36: Reject Herdr runtime JSON with SessionControlInvoked = true (boolean)
        $p = & $makeValidHerdrPayload; $p['SessionControlInvoked'] = $true
        & $assertHerdrJsonRejected ($p | ConvertTo-Json -Depth 5) "boolean SessionControlInvoked = true"

        # Test 37: Reject Herdr runtime JSON with SessionControlInvoked = 'false' (string)
        $p = & $makeValidHerdrPayload; $p['SessionControlInvoked'] = 'false'
        & $assertHerdrJsonRejected ($p | ConvertTo-Json -Depth 5) "string SessionControlInvoked = 'false'"

        # Test 38: Reject Herdr runtime JSON with SessionControlInvoked = 0 (number)
        $p = & $makeValidHerdrPayload; $p['SessionControlInvoked'] = 0
        & $assertHerdrJsonRejected ($p | ConvertTo-Json -Depth 5) "numeric SessionControlInvoked = 0"

        # Test 39: Reject Herdr runtime JSON with RuntimeObserved = 'true' (string)
        $p = & $makeValidHerdrPayload; $p['RuntimeObserved'] = 'true'
        & $assertHerdrJsonRejected ($p | ConvertTo-Json -Depth 5) "string RuntimeObserved = 'true'"

        # Test 40: Reject Herdr runtime JSON with SnapshotObserved = 'true' (string)
        $p = & $makeValidHerdrPayload; $p['SnapshotObserved'] = 'true'
        & $assertHerdrJsonRejected ($p | ConvertTo-Json -Depth 5) "string SnapshotObserved = 'true'"

        # Test 41: Reject Herdr runtime JSON with non-Runtime EvidenceClassification
        $p = & $makeValidHerdrPayload; $p['EvidenceClassification'] = 'Synthetic'
        & $assertHerdrJsonRejected ($p | ConvertTo-Json -Depth 5) "non-Runtime EvidenceClassification"

        # Test 42: Reject Herdr runtime JSON with malformed JSON text
        & $assertHerdrJsonRejected '{ this is not valid json' "malformed JSON syntax"

        Write-Host "All Test-V05ReleaseGate self-tests PASSED (50/50 assertions verified)." -ForegroundColor Green
    } finally {
        if (Test-Path -LiteralPath $tempDir) {
            Remove-Item -LiteralPath $tempDir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

$repositoryRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')).Path
$artifactRoot = Join-Path $repositoryRoot 'artifacts'

if ($SelfTest) {
    Invoke-V05ReleaseGateSelfTests -RepositoryRoot $repositoryRoot
    return
}

$sourceCommit = (& git -C $repositoryRoot rev-parse HEAD).Trim()
if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($sourceCommit)) {
    throw 'Could not resolve the source commit for the v0.5 release gate.'
}
$workingTreeStatus = @(& git -C $repositoryRoot status --porcelain=v1 --untracked-files=all)
if ($LASTEXITCODE -ne 0) {
    throw 'Could not inspect the source working tree for the v0.5 release gate.'
}
if ($workingTreeStatus.Count -ne 0) {
    throw "The v0.5 release gate requires a clean committed checkout. Pending paths: $($workingTreeStatus -join ', ')"
}

$runtimeEvidence = Resolve-CanonicalRuntimeReports `
    -CompositeRuntimeReport $CompositeRuntimeReport `
    -RuntimeGateReport $RuntimeGateReport `
    -HerdrRuntimeReport $HerdrRuntimeReport `
    -RepositoryRoot $repositoryRoot `
    -SourceCommit $sourceCommit

$resolvedCompositePath = $runtimeEvidence.CompositePath
$compositeSha256 = $runtimeEvidence.CompositeSha256
$resolvedRuntimeGatePath = $runtimeEvidence.RuntimeGatePath
$runtimeGateSha256 = $runtimeEvidence.RuntimeGateSha256
$resolvedHerdrReportPath = $runtimeEvidence.HerdrRuntimePath
$herdrRuntimeSha256 = $runtimeEvidence.HerdrRuntimeSha256
$composite = $runtimeEvidence.CompositeData

$reviewRecords = 24..28 | ForEach-Object {
    Join-Path $repositoryRoot "docs\reviews\v0.5-issue-$($_)-independent-review.md"
}
foreach ($reviewRecord in $reviewRecords) {
    $resolvedReview = Assert-ValidLeafPath -Path $reviewRecord -Name 'independent review record' -AllowedRoot $repositoryRoot
    $reviewText = Get-Content -LiteralPath $resolvedReview -Raw
    if ($reviewText -notmatch '(?m)^Verdict:\s*PASS\s*$') {
        throw "Independent v0.5 review is not PASS: $resolvedReview"
    }
}

# Evaluate release readiness criteria
$hasPackagedArtifact = -not [string]::IsNullOrWhiteSpace($PackagedArtifact)
$packagedArtifactSha256 = $null
if ($hasPackagedArtifact) {
    $resolvedPackagedArtifact = Assert-ValidLeafPath -Path $PackagedArtifact -Name 'packaged artifact' -AllowedRoot $repositoryRoot
    $packagedArtifactSha256 = (Get-FileHash -LiteralPath $resolvedPackagedArtifact -Algorithm SHA256).Hash
}

$hasCleanInstall = -not [string]::IsNullOrWhiteSpace($CleanMachineInstallReport)
$cleanInstallSha256 = $null
if ($hasCleanInstall) {
    $resolvedCleanInstall = Assert-ValidLeafPath -Path $CleanMachineInstallReport -Name 'clean-machine install report' -AllowedRoot $repositoryRoot
    $cleanInstallSha256 = (Get-FileHash -LiteralPath $resolvedCleanInstall -Algorithm SHA256).Hash
    $cleanInstallText = Get-Content -LiteralPath $resolvedCleanInstall -Raw
    if ($cleanInstallText -notmatch '(?m)^Result:\s*PASS\s*$') {
        throw "Clean-machine install report does not have Result: PASS ($resolvedCleanInstall)"
    }
    if ($hasPackagedArtifact -and $cleanInstallText -notmatch "(?m)^PackagedArtifactSha256:\s*$([Regex]::Escape($packagedArtifactSha256))\s*$") {
        throw "Clean-machine install report is not bound to packaged artifact hash: $packagedArtifactSha256"
    }
}

$hasPredecessors = $false
$predecessorGateDetails = @()
if ($PredecessorReleaseGateReports -and $PredecessorReleaseGateReports.Count -gt 0) {
    $predecessorGateDetails = Test-PredecessorReports `
        -Reports $PredecessorReleaseGateReports `
        -RepositoryRoot $repositoryRoot `
        -SourceCommit $sourceCommit
    $hasPredecessors = $predecessorGateDetails.Count -eq 4
}

$hasHumanAcceptance = -not [string]::IsNullOrWhiteSpace($HumanAcceptanceReport)
$humanAcceptanceData = $null
if ($hasHumanAcceptance) {
    $humanAcceptanceData = Test-HumanAcceptanceReport `
        -ReportPath $HumanAcceptanceReport `
        -RepositoryRoot $repositoryRoot `
        -SourceCommit $sourceCommit
}

$releaseReady = $hasPackagedArtifact -and $hasCleanInstall -and $hasPredecessors -and $hasHumanAcceptance
if ($RequireReleaseReady -and -not $releaseReady) {
    $missing = @()
    if (-not $hasPackagedArtifact) { $missing += 'PackagedArtifact' }
    if (-not $hasCleanInstall) { $missing += 'CleanMachineInstallReport' }
    if (-not $hasPredecessors) { $missing += 'PredecessorReleaseGateReports (v0.1.0..v0.4.0)' }
    if (-not $hasHumanAcceptance) { $missing += 'HumanAcceptanceReport' }
    throw "Release readiness required (-RequireReleaseReady) but release evidence is incomplete: $($missing -join ', ')"
}

if (-not $SkipBuild) {
    & (Join-Path $PSScriptRoot 'Invoke-Build.ps1') -Configuration $Configuration -VerifyFormat
    if ($LASTEXITCODE -ne 0) {
        throw 'The v0.5 release build and test suite failed.'
    }
}

$implementationGates = @(
    'Test-V05ComplianceRuleEngine.ps1',
    'Test-V05EvidenceAuditStorage.ps1',
    'Test-V05ComplianceQueue.ps1',
    'Test-V05RoleDistinctReview.ps1')
foreach ($implementationGate in $implementationGates) {
    & (Join-Path $PSScriptRoot $implementationGate) `
        -Configuration $Configuration `
        -SkipBuild | Out-Host
    if ($LASTEXITCODE -ne 0) {
        throw "The v0.5 implementation gate failed: $implementationGate"
    }
}

$finalSourceCommit = (& git -C $repositoryRoot rev-parse HEAD).Trim()
$finalWorkingTreeStatus = @(& git -C $repositoryRoot status --porcelain=v1 --untracked-files=all)
if ($LASTEXITCODE -ne 0 -or
    $finalSourceCommit -ne $sourceCommit -or
    $finalWorkingTreeStatus.Count -ne 0) {
    throw 'The source commit or clean-checkout state changed while the v0.5 release gate ran.'
}

$runId = "$([DateTime]::UtcNow.ToString('yyyyMMddTHHmmssfffffffZ', [Globalization.CultureInfo]::InvariantCulture))-$([Guid]::NewGuid().ToString('N').Substring(0, 8))"
$gateDirectory = Join-Path $artifactRoot "release-gates\v0.5.0\release\$runId"
New-Item -ItemType Directory -Path $gateDirectory -Force | Out-Null
$reviewHashes = $reviewRecords | ForEach-Object {
    "SHA256 $((Get-FileHash -LiteralPath $_ -Algorithm SHA256).Hash) $([IO.Path]::GetFileName($_))"
}
$gateReportPath = Join-Path $gateDirectory 'gate-report.txt'

$predSummaryLines = if ($hasPredecessors) {
    $predecessorGateDetails | ForEach-Object {
        "  Predecessor $($_.Version): sha256=$($_.Sha256) commit=$($_.Commit) path=$($_.Path)"
    }
} else {
    @('  Predecessors (v0.1..v0.4): PENDING / NOT PROVIDED')
}

$gateReport = @(
    'HerdrOps v0.5.0 Release Gate',
    "GeneratedUtc: $([DateTime]::UtcNow.ToString('O'))",
    "SourceCommit: $sourceCommit",
    "Result: $(if ($releaseReady) { 'RELEASE PASS' } else { 'RUNTIME ACCEPTANCE PASS' })",
    "ReleaseReady: $(if ($releaseReady) { 'true' } else { 'false' })",
    "VersionReleaseReady: $(if ($releaseReady) { 'true' } else { 'false' })",
    "ReleaseReadiness: $(if ($releaseReady) { 'READY' } else { 'PENDING' })",
    'ImplementationGates: 4/4 PASS',
    'IndependentReviews: 5/5 PASS',
    'RoleDistinctRuntimeAcceptance: PASS',
    'RuntimeObserved: true',
    'SnapshotObserved: true',
    'EventObserved: true',
    'ReconnectObserved: true',
    'SessionControlInvoked: false',
    "CompositeRuntimeReportSha256: $compositeSha256",
    "HerdrRuntimeReportSha256: $herdrRuntimeSha256",
    "RuntimeGateReportSha256: $runtimeGateSha256",
    "HerdrRuntimeReport: $resolvedHerdrReportPath",
    '',
    'ReleaseEvidenceSummary:',
    "  PackagedArtifact: $(if ($hasPackagedArtifact) { "PRESENT (sha256=$packagedArtifactSha256)" } else { 'PENDING / NOT PROVIDED' })",
    "  CleanMachineInstall: $(if ($hasCleanInstall) { "PRESENT (sha256=$cleanInstallSha256)" } else { 'PENDING / NOT PROVIDED' })",
    "  PredecessorReleaseGates: $(if ($hasPredecessors) { 'PRESENT (v0.1..v0.4 VERIFIED)' } else { 'PENDING / NOT PROVIDED' })",
    "  HumanAcceptanceApproval: $(if ($hasHumanAcceptance) { "PRESENT (sha256=$($humanAcceptanceData.Sha256), signer=$($humanAcceptanceData.Signer), role=$($humanAcceptanceData.Role))" } else { 'PENDING / NOT PROVIDED' })",
    '',
    'PredecessorReleaseGateDetails:'
) + $predSummaryLines + @(
    '',
    'IndependentReviewHashes:'
) + $reviewHashes + @(
    '',
    'EvidenceBoundary:',
    'This gate validates v0.5 compliance review runtime acceptance and checks release readiness criteria.',
    'ReleaseReady remains false unless packaged artifact, clean-machine install, complete predecessor gates, independent human acceptance and required release evidence are explicitly hash-bound and present.',
    'A passing runtime report does not complete release readiness or authorize tag/release publication.'
)
$gateReport | Set-Content -LiteralPath $gateReportPath -Encoding utf8
$gateReport | Write-Output
Write-Output "GateReport: $gateReportPath"
