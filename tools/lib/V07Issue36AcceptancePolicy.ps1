#requires -Version 5.1

# Issue #36: bounded static/contract acceptance policy.
#
# This policy validates operator-supplied source/test evidence.  It never
# creates a human decision, starts Herdr, renders WPF, or converts synthetic
# evidence into Runtime or Release credit.

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'V07ReleaseGatePolicy.ps1')

$script:V07Issue36SchemaVersion = 1
$script:V07Issue36Issue = 36
$script:V07Issue36ManifestMaxBytes = 512 * 1024
$script:V07Issue36EvidenceMaxBytes = 8 * 1024 * 1024
$script:V07Issue36SourceMaxBytes = 2 * 1024 * 1024
$script:V07Issue36TrxMaxCharacters = 8 * 1024 * 1024
$script:V07Issue36ReferencePath = 'docs/design/reference/MANIFEST.md'
$script:V07Issue36ZeroSha256 = '0' * 64

function Get-V07Issue36RepositoryRoot {
    return (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..\..')).Path
}

function Get-V07Issue36ReferencePath {
    return $script:V07Issue36ReferencePath
}

function Get-V07Issue36RequiredTestDefinitions {
    return @(
        [pscustomobject][ordered]@{
            Id = 'settings-persistence'
            TestClass = 'AppSettingsStoreTests'
            ProjectPath = 'tests/HerdrOps.IntegrationTests/HerdrOps.IntegrationTests.csproj'
            SourcePath = 'tests/HerdrOps.IntegrationTests/AppSettingsStoreTests.cs'
        }
        [pscustomobject][ordered]@{
            Id = 'theme-logic'
            TestClass = 'UiThemeIntegrationTests'
            ProjectPath = 'tests/HerdrOps.IntegrationTests/HerdrOps.IntegrationTests.csproj'
            SourcePath = 'tests/HerdrOps.IntegrationTests/UiThemeIntegrationTests.cs'
        }
        [pscustomobject][ordered]@{
            Id = 'theme-wpf'
            TestClass = 'UiThemeWpfIntegrationTests'
            ProjectPath = 'tests/HerdrOps.RuntimeTests/HerdrOps.RuntimeTests.csproj'
            SourcePath = 'tests/HerdrOps.RuntimeTests/UiThemeWpfIntegrationTests.cs'
        }
        [pscustomobject][ordered]@{
            Id = 'language-rendering'
            TestClass = 'LanguageSwitchRenderingTests'
            ProjectPath = 'tests/HerdrOps.RuntimeTests/HerdrOps.RuntimeTests.csproj'
            SourcePath = 'tests/HerdrOps.RuntimeTests/LanguageSwitchRenderingTests.cs'
        }
        [pscustomobject][ordered]@{
            Id = 'accessibility-synthetic'
            TestClass = 'WidgetAccessibilityTests'
            ProjectPath = 'tests/HerdrOps.RuntimeTests/HerdrOps.RuntimeTests.csproj'
            SourcePath = 'tests/HerdrOps.RuntimeTests/WidgetAccessibilityTests.cs'
        }
        [pscustomobject][ordered]@{
            Id = 'retention-synthetic'
            TestClass = 'CompliancePrivacyRetentionIntegrationTests'
            ProjectPath = 'tests/HerdrOps.IntegrationTests/HerdrOps.IntegrationTests.csproj'
            SourcePath = 'tests/HerdrOps.IntegrationTests/CompliancePrivacyRetentionIntegrationTests.cs'
        }
        [pscustomobject][ordered]@{
            Id = 'tray-startup'
            TestClass = 'TrayAndStartupLifecycleTests'
            ProjectPath = 'tests/HerdrOps.UnitTests/HerdrOps.UnitTests.csproj'
            SourcePath = 'tests/HerdrOps.UnitTests/TrayAndStartupLifecycleTests.cs'
        }
    )
}

function Assert-V07Issue36JsonObject {
    param(
        [Parameter(Mandatory = $true)]$Object,
        [Parameter(Mandatory = $true)][string]$Description
    )

    Assert-V07ReleaseGateJsonObject -Object $Object -Description $Description
}

function Assert-V07Issue36ExactProperties {
    param(
        [Parameter(Mandatory = $true)]$Object,
        [Parameter(Mandatory = $true)][string[]]$Names,
        [Parameter(Mandatory = $true)][string]$Description
    )

    Assert-V07ReleaseGateExactProperties -Object $Object -Names $Names -Description $Description
}

function Get-V07Issue36Property {
    param(
        [Parameter(Mandatory = $true)]$Object,
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][string]$Description
    )

    return (Get-V07ReleaseGateProperty -Object $Object -Name $Name -Description $Description)
}

function Assert-V07Issue36NonZeroHash {
    param(
        [Parameter(Mandatory = $true)]$Value,
        [Parameter(Mandatory = $true)][string]$Description,
        [ValidateSet('Lower', 'Upper', 'Either')][string]$Case = 'Either'
    )

    Assert-V07ReleaseGateHex -Value $Value -Length 64 -Description $Description -Case $Case
    if ($Value.ToUpperInvariant() -ceq $script:V07Issue36ZeroSha256) {
        throw "$Description must not be the all-zero placeholder hash."
    }
}

function Assert-V07Issue36Candidate {
    param(
        [Parameter(Mandatory = $true)]$Candidate,
        [Parameter(Mandatory = $true)]$CurrentCandidate,
        [switch]$AllowDirtyCandidate
    )

    Assert-V07Issue36ExactProperties -Object $Candidate -Names @('commit', 'tree', 'workingTree') -Description 'Issue #36 candidate'
    $commit = Get-V07Issue36Property -Object $Candidate -Name 'commit' -Description 'Issue #36 candidate'
    $tree = Get-V07Issue36Property -Object $Candidate -Name 'tree' -Description 'Issue #36 candidate'
    $workingTree = Get-V07Issue36Property -Object $Candidate -Name 'workingTree' -Description 'Issue #36 candidate'
    Assert-V07ReleaseGateHex -Value $commit -Length 40 -Description 'Issue #36 candidate.commit' -Case Lower
    Assert-V07ReleaseGateHex -Value $tree -Length 40 -Description 'Issue #36 candidate.tree' -Case Lower
    if ($workingTree -cnotin @('CLEAN', 'DIRTY')) {
        throw 'Issue #36 candidate.workingTree must be the observed CLEAN or DIRTY state.'
    }
    if ([string]$commit -cne [string]$CurrentCandidate.Commit -or
        [string]$tree -cne [string]$CurrentCandidate.Tree) {
        throw 'Issue #36 candidate is stale: commit/tree do not match the current checkout.'
    }
    if ([string]$workingTree -cne [string]$CurrentCandidate.WorkingTree) {
        throw 'Issue #36 candidate.workingTree does not match the current checkout status.'
    }
    if (-not $AllowDirtyCandidate -and [string]$CurrentCandidate.WorkingTree -cne 'CLEAN') {
        throw 'Issue #36 acceptance requires a clean committed checkout.'
    }
}

function Get-V07Issue36ReferenceEntryCount {
    param([Parameter(Mandatory = $true)][byte[]]$Bytes)

    try {
        $text = (New-Object System.Text.UTF8Encoding($false, $true)).GetString($Bytes)
    } catch {
        throw "The immutable reference MANIFEST.md is not valid UTF-8: $($_.Exception.Message)"
    }

    $pattern = '(?m)^\|\s*`([0-9]{2}-[a-z0-9-]+\.png)`\s*\|\s*([0-9]+)\s*[x\u00D7]\s*([0-9]+)\s*\|\s*([0-9,]+)\s*\|\s*`([0-9A-Fa-f]{64})`\s*\|$'
    $seen = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    foreach ($match in [regex]::Matches($text, $pattern)) {
        if (-not $seen.Add([string]$match.Groups[1].Value)) {
            throw "The immutable reference MANIFEST.md contains a duplicate entry: $($match.Groups[1].Value)"
        }
    }
    if ($seen.Count -ne 11) {
        throw "The immutable reference MANIFEST.md must contain exactly 11 PNG entries; found $($seen.Count)."
    }
    return $seen.Count
}

function Assert-V07Issue36Reference {
    param(
        [Parameter(Mandatory = $true)]$Reference,
        [Parameter(Mandatory = $true)][string]$RepositoryRoot
    )

    Assert-V07Issue36ExactProperties -Object $Reference -Names @('manifestPath', 'manifestSha256', 'hashAlgorithm', 'entryCount') -Description 'Issue #36 immutable reference'
    $path = Get-V07Issue36Property -Object $Reference -Name 'manifestPath' -Description 'Issue #36 immutable reference'
    $hash = Get-V07Issue36Property -Object $Reference -Name 'manifestSha256' -Description 'Issue #36 immutable reference'
    $algorithm = Get-V07Issue36Property -Object $Reference -Name 'hashAlgorithm' -Description 'Issue #36 immutable reference'
    $declaredCount = Get-V07Issue36Property -Object $Reference -Name 'entryCount' -Description 'Issue #36 immutable reference'
    if ($path -cne $script:V07Issue36ReferencePath) {
        throw 'Issue #36 immutable reference must bind docs/design/reference/MANIFEST.md exactly.'
    }
    Assert-V07Issue36NonZeroHash -Value $hash -Description 'Issue #36 immutable reference.manifestSha256' -Case Upper
    if ($algorithm -cne 'SHA-256') {
        throw 'Issue #36 immutable reference.hashAlgorithm must be SHA-256.'
    }
    if ((Assert-V07ReleaseGateInteger -Value $declaredCount -Description 'Issue #36 immutable reference.entryCount' -Minimum 11 -Maximum 11) -ne 11) {
        throw 'Issue #36 immutable reference.entryCount must be 11.'
    }

    $fullPath = Join-Path $RepositoryRoot $script:V07Issue36ReferencePath
    $snapshot = Get-V07ReleaseGateFileSnapshot -Path $fullPath -Description 'Issue #36 immutable reference MANIFEST.md' -MaxBytes (1024 * 1024) -Root $RepositoryRoot
    if ($snapshot.Sha256 -cne $hash) {
        throw 'Issue #36 immutable reference MANIFEST.md SHA-256 does not match the manifest binding.'
    }
    $actualCount = Get-V07Issue36ReferenceEntryCount -Bytes $snapshot.Bytes
    if ($actualCount -ne [int]$declaredCount) {
        throw 'Issue #36 immutable reference entryCount does not match MANIFEST.md.'
    }
    return [pscustomobject][ordered]@{
        Path = $script:V07Issue36ReferencePath
        Sha256 = [string]$snapshot.Sha256
        EntryCount = [int]$actualCount
    }
}

function Get-V07Issue36TrxSummary {
    param(
        [Parameter(Mandatory = $true)][byte[]]$Bytes,
        [Parameter(Mandatory = $true)][string]$Description
    )

    try {
        $text = (New-Object System.Text.UTF8Encoding($false, $true)).GetString($Bytes)
    } catch {
        throw "$Description is not valid UTF-8: $($_.Exception.Message)"
    }
    if ($text.Length -gt $script:V07Issue36TrxMaxCharacters) {
        throw "$Description exceeds the bounded TRX character limit."
    }

    $settings = New-Object System.Xml.XmlReaderSettings
    $settings.DtdProcessing = [System.Xml.DtdProcessing]::Prohibit
    $settings.XmlResolver = $null
    $settings.MaxCharactersInDocument = $script:V07Issue36TrxMaxCharacters
    $reader = $null
    $document = New-Object System.Xml.XmlDocument
    $document.XmlResolver = $null
    try {
        $reader = [System.Xml.XmlReader]::Create((New-Object System.IO.StringReader($text)), $settings)
        $document.Load($reader)
    } catch {
        throw "$Description is not a safe, well-formed TRX XML document: $($_.Exception.Message)"
    } finally {
        if ($null -ne $reader) {
            $reader.Dispose()
        }
    }

    $results = @($document.SelectNodes("//*[local-name()='UnitTestResult']"))
    if ($results.Count -lt 1) {
        throw "$Description contains no UnitTestResult entries."
    }
    $failed = @($results | Where-Object { [string]$_.GetAttribute('outcome') -cne 'Passed' })
    return [pscustomobject][ordered]@{
        TestCaseCount = [int]$results.Count
        AllPassed = ($failed.Count -eq 0)
    }
}

function Assert-V07Issue36TestRecord {
    param(
        [Parameter(Mandatory = $true)]$Record,
        [Parameter(Mandatory = $true)]$Definition,
        [Parameter(Mandatory = $true)][string]$RepositoryRoot,
        [Parameter(Mandatory = $true)][string]$EvidenceRoot
    )

    Assert-V07Issue36ExactProperties -Object $Record -Names @('id', 'testClass', 'projectPath', 'testSourcePath', 'testSourceSha256', 'trxPath', 'trxSha256', 'testCaseCount', 'result', 'evidenceClass', 'command') -Description "Issue #36 test record '$($Definition.Id)'"
    $id = Get-V07Issue36Property -Object $Record -Name 'id' -Description 'Issue #36 test record'
    if ($id -cne $Definition.Id) {
        throw "Issue #36 test record id '$id' is not the required '$($Definition.Id)'."
    }
    if ((Get-V07Issue36Property -Object $Record -Name 'testClass' -Description 'Issue #36 test record') -cne $Definition.TestClass) {
        throw "Issue #36 test record '$id' has an unexpected test class."
    }
    $projectPath = Get-V07Issue36Property -Object $Record -Name 'projectPath' -Description 'Issue #36 test record'
    $sourcePath = Get-V07Issue36Property -Object $Record -Name 'testSourcePath' -Description 'Issue #36 test record'
    if ($projectPath -cne $Definition.ProjectPath -or $sourcePath -cne $Definition.SourcePath) {
        throw "Issue #36 test record '$id' is not bound to the required project/source path."
    }

    Assert-V07ReleaseGateSafeRelativePath -Path $projectPath -Description "Issue #36 '$id' projectPath"
    Assert-V07ReleaseGateSafeRelativePath -Path $sourcePath -Description "Issue #36 '$id' testSourcePath"
    $projectFull = Resolve-V07ReleaseGateChildPath -Root $RepositoryRoot -RelativePath $projectPath -Description "Issue #36 '$id' projectPath" -RequireLeaf
    $sourceFull = Resolve-V07ReleaseGateChildPath -Root $RepositoryRoot -RelativePath $sourcePath -Description "Issue #36 '$id' testSourcePath" -RequireLeaf
    $null = Get-V07ReleaseGateFileSnapshot -Path $projectFull -Description "Issue #36 '$id' project" -MaxBytes $script:V07Issue36SourceMaxBytes -Root $RepositoryRoot
    $sourceSnapshot = Get-V07ReleaseGateFileSnapshot -Path $sourceFull -Description "Issue #36 '$id' test source" -MaxBytes $script:V07Issue36SourceMaxBytes -Root $RepositoryRoot

    $sourceHash = Get-V07Issue36Property -Object $Record -Name 'testSourceSha256' -Description 'Issue #36 test record'
    Assert-V07Issue36NonZeroHash -Value $sourceHash -Description "Issue #36 '$id' testSourceSha256" -Case Upper
    if ($sourceSnapshot.Sha256 -cne $sourceHash) {
        throw "Issue #36 '$id' test source SHA-256 is stale."
    }

    $trxPath = Get-V07Issue36Property -Object $Record -Name 'trxPath' -Description 'Issue #36 test record'
    Assert-V07ReleaseGateSafeRelativePath -Path $trxPath -Description "Issue #36 '$id' trxPath"
    $trxFull = Resolve-V07ReleaseGateChildPath -Root $EvidenceRoot -RelativePath $trxPath -Description "Issue #36 '$id' trxPath" -RequireLeaf
    $trxSnapshot = Get-V07ReleaseGateFileSnapshot -Path $trxFull -Description "Issue #36 '$id' TRX" -MaxBytes $script:V07Issue36EvidenceMaxBytes -Root $EvidenceRoot
    $trxHash = Get-V07Issue36Property -Object $Record -Name 'trxSha256' -Description 'Issue #36 test record'
    Assert-V07Issue36NonZeroHash -Value $trxHash -Description "Issue #36 '$id' trxSha256" -Case Upper
    if ($trxSnapshot.Sha256 -cne $trxHash) {
        throw "Issue #36 '$id' TRX SHA-256 is stale."
    }

    $declaredCount = Assert-V07ReleaseGateInteger -Value (Get-V07Issue36Property -Object $Record -Name 'testCaseCount' -Description 'Issue #36 test record') -Description "Issue #36 '$id' testCaseCount" -Minimum 1 -Maximum 100000
    $result = Get-V07Issue36Property -Object $Record -Name 'result' -Description 'Issue #36 test record'
    if ($result -cne 'PASS') {
        throw "Issue #36 '$id' result must be PASS; failed or pending test evidence cannot satisfy this gate."
    }
    $evidenceClass = Get-V07Issue36Property -Object $Record -Name 'evidenceClass' -Description 'Issue #36 test record'
    if ($evidenceClass -cne 'Synthetic') {
        throw "Issue #36 '$id' evidenceClass must be Synthetic; no Runtime claim is allowed here."
    }
    Assert-V07ReleaseGateString -Value (Get-V07Issue36Property -Object $Record -Name 'command' -Description 'Issue #36 test record') -Description "Issue #36 '$id' command" -MaxLength 4096

    $trxSummary = Get-V07Issue36TrxSummary -Bytes $trxSnapshot.Bytes -Description "Issue #36 '$id' TRX"
    if (-not [bool]$trxSummary.AllPassed) {
        throw "Issue #36 '$id' TRX contains a non-Passed test result."
    }
    if ([int]$trxSummary.TestCaseCount -ne [int]$declaredCount) {
        throw "Issue #36 '$id' testCaseCount does not match the exact TRX result count."
    }
    return [pscustomobject][ordered]@{
        Id = $id
        TestClass = $Definition.TestClass
        TestCaseCount = [int]$declaredCount
        TestSourceSha256 = [string]$sourceHash
        TrxSha256 = [string]$trxHash
        EvidenceClass = 'Synthetic'
    }
}

function Assert-V07Issue36VisualPending {
    param([Parameter(Mandatory = $true)]$VisualReview)

    Assert-V07Issue36ExactProperties -Object $VisualReview -Names @('status', 'captureManifestPath', 'captureManifestSha256') -Description 'Issue #36 visual review'
    foreach ($name in @('status', 'captureManifestPath', 'captureManifestSha256')) {
        if ((Get-V07Issue36Property -Object $VisualReview -Name $name -Description 'Issue #36 visual review') -cne 'PENDING') {
            throw 'Issue #36 visual review must remain PENDING; automation cannot create human visual acceptance.'
        }
    }
    return 'PENDING'
}

function Assert-V07Issue36HumanAcceptance {
    param(
        [Parameter(Mandatory = $true)]$HumanAcceptance,
        [switch]$AllowHumanEvidence
    )

    Assert-V07Issue36ExactProperties -Object $HumanAcceptance -Names @('status', 'signer', 'role', 'signedAtUtc', 'signature', 'evidencePath', 'evidenceSha256') -Description 'Issue #36 human acceptance'
    $status = Get-V07Issue36Property -Object $HumanAcceptance -Name 'status' -Description 'Issue #36 human acceptance'
    if ($status -cne 'PENDING' -and $status -cne 'ACCEPTED') {
        throw 'Issue #36 human acceptance.status must be PENDING or ACCEPTED.'
    }
    if ($status -ceq 'PENDING') {
        foreach ($name in @('signer', 'role', 'signedAtUtc', 'signature', 'evidencePath', 'evidenceSha256')) {
            if ((Get-V07Issue36Property -Object $HumanAcceptance -Name $name -Description 'Issue #36 human acceptance') -cne 'PENDING') {
                throw "Issue #36 human acceptance has forged or premature human field '$name'; all fields must remain PENDING."
            }
        }
        return 'PENDING'
    }
    if (-not $AllowHumanEvidence) {
        throw 'Issue #36 automated gate cannot accept a human decision; use a separately signed independent review with real evidence.'
    }

    $signer = Get-V07Issue36Property -Object $HumanAcceptance -Name 'signer' -Description 'Issue #36 human acceptance'
    $role = Get-V07Issue36Property -Object $HumanAcceptance -Name 'role' -Description 'Issue #36 human acceptance'
    $signedAt = Get-V07Issue36Property -Object $HumanAcceptance -Name 'signedAtUtc' -Description 'Issue #36 human acceptance'
    $signature = Get-V07Issue36Property -Object $HumanAcceptance -Name 'signature' -Description 'Issue #36 human acceptance'
    $evidencePath = Get-V07Issue36Property -Object $HumanAcceptance -Name 'evidencePath' -Description 'Issue #36 human acceptance'
    $evidenceHash = Get-V07Issue36Property -Object $HumanAcceptance -Name 'evidenceSha256' -Description 'Issue #36 human acceptance'
    Assert-V07ReleaseGateString -Value $signer -Description 'Issue #36 human acceptance.signer'
    Assert-V07ReleaseGateString -Value $role -Description 'Issue #36 human acceptance.role'
    Assert-V07ReleaseGateString -Value $signature -Description 'Issue #36 human acceptance.signature'
    Assert-V07ReleaseGateUtcTimestamp -Value $signedAt -Description 'Issue #36 human acceptance.signedAtUtc'
    if ($signer -match '(?i)^(pending|automation|ci|agent)$' -or $role -match '(?i)^(pending|automation|ci|agent)$' -or $signature -match '(?i)^pending$') {
        throw 'Issue #36 accepted human evidence contains a forged automation/pending signer, role, or signature.'
    }
    Assert-V07ReleaseGateSafeRelativePath -Path $evidencePath -Description 'Issue #36 human acceptance.evidencePath'
    Assert-V07Issue36NonZeroHash -Value $evidenceHash -Description 'Issue #36 human acceptance.evidenceSha256' -Case Upper
    return 'ACCEPTED'
}

function Assert-V07Issue36Boundaries {
    param(
        [Parameter(Mandatory = $true)]$Boundaries,
        [Parameter(Mandatory = $true)][string]$HumanStatus
    )

    Assert-V07Issue36ExactProperties -Object $Boundaries -Names @('static', 'contract', 'synthetic', 'human', 'runtime', 'release') -Description 'Issue #36 evidence boundaries'
    if ((Get-V07Issue36Property -Object $Boundaries -Name 'static' -Description 'Issue #36 evidence boundaries') -cne 'PASS' -or
        (Get-V07Issue36Property -Object $Boundaries -Name 'contract' -Description 'Issue #36 evidence boundaries') -cne 'PASS' -or
        (Get-V07Issue36Property -Object $Boundaries -Name 'synthetic' -Description 'Issue #36 evidence boundaries') -cne 'PASS') {
        throw 'Issue #36 static, contract, and synthetic boundaries must be explicit PASS values after exact evidence validation.'
    }
    if ((Get-V07Issue36Property -Object $Boundaries -Name 'human' -Description 'Issue #36 evidence boundaries') -cne $HumanStatus) {
        throw 'Issue #36 human boundary does not match humanAcceptance.status.'
    }
    if ((Get-V07Issue36Property -Object $Boundaries -Name 'runtime' -Description 'Issue #36 evidence boundaries') -cne 'NOT OBSERVED' -or
        (Get-V07Issue36Property -Object $Boundaries -Name 'release' -Description 'Issue #36 evidence boundaries') -cne 'NOT OBSERVED') {
        throw 'Issue #36 Runtime and Release boundaries must remain NOT OBSERVED.'
    }
}

function Test-V07Issue36AcceptanceManifest {
    param(
        [Parameter(Mandatory = $true)][string]$ManifestPath,
        [Parameter(Mandatory = $true)][string]$EvidenceRoot,
        [Parameter(Mandatory = $true)][string]$RepositoryRoot,
        [Parameter(Mandatory = $true)]$CurrentCandidate,
        [string]$ExpectedSourceCommit,
        [string]$ExpectedSourceTree,
        [switch]$AllowDirtyCandidate,
        [switch]$AllowHumanEvidence
    )

    if (-not (Test-Path -LiteralPath $EvidenceRoot -PathType Container)) {
        throw "Issue #36 evidence root does not exist: $EvidenceRoot"
    }
    $manifestFile = Read-V07ReleaseGateJsonFile -Path $ManifestPath -Description 'Issue #36 acceptance manifest' -MaxBytes $script:V07Issue36ManifestMaxBytes -Root $EvidenceRoot
    $manifest = $manifestFile.Value
    Assert-V07Issue36ExactProperties -Object $manifest -Names @('$id', 'schemaVersion', 'reportKind', 'issue', 'status', 'evidenceClass', 'candidate', 'reference', 'automatedEvidence', 'visualReview', 'humanAcceptance', 'boundaries') -Description 'Issue #36 acceptance manifest'
    if ((Get-V07Issue36Property -Object $manifest -Name '$id' -Description 'Issue #36 acceptance manifest') -cne 'https://herdrops.local/schema/v0.7/issue-36-acceptance.schema.json') {
        throw 'Issue #36 acceptance manifest.$id is invalid.'
    }
    if ((Assert-V07ReleaseGateInteger -Value (Get-V07Issue36Property -Object $manifest -Name 'schemaVersion' -Description 'Issue #36 acceptance manifest') -Description 'Issue #36 acceptance manifest.schemaVersion' -Minimum 1 -Maximum 1) -ne 1) {
        throw 'Issue #36 acceptance manifest.schemaVersion must be 1.'
    }
    if ((Get-V07Issue36Property -Object $manifest -Name 'reportKind' -Description 'Issue #36 acceptance manifest') -cne 'HerdrOps.V07Issue36Acceptance') {
        throw 'Issue #36 acceptance manifest.reportKind is invalid.'
    }
    if ((Assert-V07ReleaseGateInteger -Value (Get-V07Issue36Property -Object $manifest -Name 'issue' -Description 'Issue #36 acceptance manifest') -Description 'Issue #36 acceptance manifest.issue' -Minimum 36 -Maximum 36) -ne 36) {
        throw 'Issue #36 acceptance manifest.issue must be 36.'
    }
    $status = Get-V07Issue36Property -Object $manifest -Name 'status' -Description 'Issue #36 acceptance manifest'
    if ($status -ne 'PENDING' -and $status -ne 'PASS') {
        throw 'Issue #36 acceptance manifest.status must be PENDING or PASS.'
    }
    if ($status -ceq 'PASS' -and -not $AllowHumanEvidence) {
        throw 'Issue #36 automated gate refuses a PASS claim; human acceptance remains pending.'
    }
    if ((Get-V07Issue36Property -Object $manifest -Name 'evidenceClass' -Description 'Issue #36 acceptance manifest') -cne 'Static/Contract/Synthetic') {
        throw 'Issue #36 acceptance manifest.evidenceClass must be Static/Contract/Synthetic.'
    }

    if ([string]::IsNullOrWhiteSpace($ExpectedSourceCommit) -or [string]::IsNullOrWhiteSpace($ExpectedSourceTree)) {
        throw 'ExpectedSourceCommit and ExpectedSourceTree are mandatory and must be supplied together.'
    }
    Assert-V07ReleaseGateHex -Value $ExpectedSourceCommit -Length 40 -Description 'ExpectedSourceCommit' -Case Lower
    Assert-V07ReleaseGateHex -Value $ExpectedSourceTree -Length 40 -Description 'ExpectedSourceTree' -Case Lower
    if ($ExpectedSourceCommit -cne $CurrentCandidate.Commit -or $ExpectedSourceTree -cne $CurrentCandidate.Tree) {
        throw 'The requested expected source commit/tree does not match the current checkout.'
    }

    Assert-V07Issue36Candidate -Candidate (Get-V07Issue36Property -Object $manifest -Name 'candidate' -Description 'Issue #36 acceptance manifest') -CurrentCandidate $CurrentCandidate -AllowDirtyCandidate:$AllowDirtyCandidate
    $reference = Assert-V07Issue36Reference -Reference (Get-V07Issue36Property -Object $manifest -Name 'reference' -Description 'Issue #36 acceptance manifest') -RepositoryRoot $RepositoryRoot

    $automated = Get-V07Issue36Property -Object $manifest -Name 'automatedEvidence' -Description 'Issue #36 acceptance manifest'
    Assert-V07Issue36ExactProperties -Object $automated -Names @('status', 'tests') -Description 'Issue #36 automated evidence'
    if ((Get-V07Issue36Property -Object $automated -Name 'status' -Description 'Issue #36 automated evidence') -cne 'PASS') {
        throw 'Issue #36 automatedEvidence.status must be PASS after exact test/TRX verification.'
    }
    $records = Get-V07Issue36Property -Object $automated -Name 'tests' -Description 'Issue #36 automated evidence'
    if ($records -isnot [array]) {
        $records = @($records)
    }
    $definitions = @(Get-V07Issue36RequiredTestDefinitions)
    if (@($records).Count -ne $definitions.Count) {
        throw "Issue #36 automated evidence must contain exactly $($definitions.Count) test records."
    }
    $seen = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
    $validatedTests = New-Object System.Collections.ArrayList
    foreach ($record in @($records)) {
        $recordId = Get-V07Issue36Property -Object $record -Name 'id' -Description 'Issue #36 test record'
        if (-not $seen.Add([string]$recordId)) {
            throw "Issue #36 automated evidence contains a duplicate test record: $recordId"
        }
        $definition = @($definitions | Where-Object { $_.Id -ceq [string]$recordId })
        if ($definition.Count -ne 1) {
            throw "Issue #36 automated evidence contains an unknown test record: $recordId"
        }
        [void]$validatedTests.Add((Assert-V07Issue36TestRecord -Record $record -Definition $definition[0] -RepositoryRoot $RepositoryRoot -EvidenceRoot $EvidenceRoot))
    }
    foreach ($definition in $definitions) {
        if (-not $seen.Contains($definition.Id)) {
            throw "Issue #36 automated evidence is missing required test record: $($definition.Id)"
        }
    }

    $visualStatus = Assert-V07Issue36VisualPending -VisualReview (Get-V07Issue36Property -Object $manifest -Name 'visualReview' -Description 'Issue #36 acceptance manifest')
    $humanStatus = Assert-V07Issue36HumanAcceptance -HumanAcceptance (Get-V07Issue36Property -Object $manifest -Name 'humanAcceptance' -Description 'Issue #36 acceptance manifest') -AllowHumanEvidence:$AllowHumanEvidence
    Assert-V07Issue36Boundaries -Boundaries (Get-V07Issue36Property -Object $manifest -Name 'boundaries' -Description 'Issue #36 acceptance manifest') -HumanStatus $humanStatus

    return [pscustomobject][ordered]@{
        Valid = $true
        Issue = 36
        Status = [string]$status
        ManifestPath = [IO.Path]::GetFullPath($manifestFile.Path)
        ManifestSha256 = [string]$manifestFile.Sha256
        Candidate = [pscustomobject][ordered]@{
            Commit = [string]$CurrentCandidate.Commit
            Tree = [string]$CurrentCandidate.Tree
            WorkingTree = [string]$CurrentCandidate.WorkingTree
        }
        ReferenceManifestSha256 = [string]$reference.Sha256
        ReferenceEntryCount = [int]$reference.EntryCount
        TestCount = [int]$validatedTests.Count
        Visual = [string]$visualStatus
        Human = [string]$humanStatus
        Runtime = 'NOT OBSERVED'
        Release = 'NOT OBSERVED'
    }
}

function New-V07Issue36PendingGateReport {
    param([Parameter(Mandatory = $true)]$Validation)

    if (-not [bool]$Validation.Valid) {
        throw 'Cannot create an Issue #36 report from an invalid validation result.'
    }
    return [pscustomobject][ordered]@{
        schemaVersion = 1
        reportKind = 'HerdrOps.V07Issue36AcceptanceGateReport'
        issue = 36
        status = 'PENDING'
        candidate = [ordered]@{
            commit = [string]$Validation.Candidate.Commit
            tree = [string]$Validation.Candidate.Tree
            workingTree = [string]$Validation.Candidate.WorkingTree
        }
        validatedManifestSha256 = [string]$Validation.ManifestSha256
        referenceManifestSha256 = [string]$Validation.ReferenceManifestSha256
        automatedEvidence = 'PASS'
        visual = 'PENDING'
        human = 'PENDING'
        runtime = 'NOT OBSERVED'
        release = 'NOT OBSERVED'
    }
}
