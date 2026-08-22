#requires -Version 5.1

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$OutputDirectory,

    [string]$PackageRoot,

    [string]$ArchivePath,

    [string]$IdentityReceiptPath,

    [string]$RepositoryRoot,

    [string]$ProfilePath,

    [string]$CaptureSourceDirectory,

    [scriptblock]$OperatorCaptureAction,

    [scriptblock]$OperatorObservationAction,

    [switch]$SyntheticCapturesForTesting,

    [string]$TestFaultStage
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'RendererCompatibility.Common.ps1')

$selfTestMode = ([string]$env:HERDROPS_RENDERER_SELFTEST -ceq '1')
if (($SyntheticCapturesForTesting -or -not [string]::IsNullOrWhiteSpace($TestFaultStage)) -and -not $selfTestMode) {
    throw 'Synthetic capture and fault-injection switches are reserved for the guarded renderer selftest process.'
}
$captureMode = if ($SyntheticCapturesForTesting) { 'SyntheticSelfTest' } else { 'LiveOperator' }
if ($captureMode -eq 'LiveOperator' -and $null -eq $OperatorObservationAction) {
    throw 'Live renderer capture requires -OperatorObservationAction with native process observations.'
}
if (-not $SyntheticCapturesForTesting -and
    [string]::IsNullOrWhiteSpace($CaptureSourceDirectory) -and
    $null -eq $OperatorCaptureAction) {
    throw 'Live renderer capture requires -CaptureSourceDirectory or -OperatorCaptureAction.'
}

if ([string]::IsNullOrWhiteSpace($RepositoryRoot)) {
    $RepositoryRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
} else {
    $RepositoryRoot = [IO.Path]::GetFullPath($RepositoryRoot)
}
Assert-RendererNonReparsePath $RepositoryRoot $RepositoryRoot 'Repository root'

if ([string]::IsNullOrWhiteSpace($ProfilePath)) {
    $ProfilePath = Join-Path $RepositoryRoot 'tools\packaging\v0.2\package-identity-profile.json'
} else {
    $ProfilePath = [IO.Path]::GetFullPath($ProfilePath)
}
Assert-RendererNonReparsePath $RepositoryRoot $ProfilePath 'Package identity profile path'

# Bound clean git repository identity
$git = Get-RendererGitIdentity $RepositoryRoot
$sourceCommit = $git.CommitSha
$sourceTree = $git.TreeSha

$profile = Read-RendererPackageProfile $ProfilePath
$profileIdentity = Get-RendererPackageProfileIdentity $ProfilePath $profile $RepositoryRoot
Assert-RendererPackageProfile $profile

# Resolve and validate package artifacts (packaged App only)
if ([string]::IsNullOrWhiteSpace($PackageRoot) -and [string]::IsNullOrWhiteSpace($ArchivePath)) {
    throw 'Either PackageRoot or ArchivePath must be provided (packaged App only).'
}

if (-not [string]::IsNullOrWhiteSpace($PackageRoot)) {
    $PackageRoot = [IO.Path]::GetFullPath($PackageRoot)
}
if (-not [string]::IsNullOrWhiteSpace($ArchivePath)) {
    $ArchivePath = [IO.Path]::GetFullPath($ArchivePath)
}
if (-not [string]::IsNullOrWhiteSpace($IdentityReceiptPath)) {
    $IdentityReceiptPath = [IO.Path]::GetFullPath($IdentityReceiptPath)
} else {
    if (-not [string]::IsNullOrWhiteSpace($PackageRoot) -and (Test-Path -LiteralPath (Join-Path $PackageRoot 'identity.json') -PathType Leaf)) {
        $IdentityReceiptPath = Join-Path $PackageRoot 'identity.json'
    } elseif (-not [string]::IsNullOrWhiteSpace($PackageRoot) -and (Test-Path -LiteralPath (Join-Path (Split-Path $PackageRoot -Parent) 'package-identity-receipt.json') -PathType Leaf)) {
        $IdentityReceiptPath = Join-Path (Split-Path $PackageRoot -Parent) 'package-identity-receipt.json'
    }
}

if ([string]::IsNullOrWhiteSpace($IdentityReceiptPath) -or -not (Test-Path -LiteralPath $IdentityReceiptPath -PathType Leaf)) {
    throw "Package identity receipt was not found: $IdentityReceiptPath"
}
Assert-RendererNonReparsePath $IdentityReceiptPath $IdentityReceiptPath 'Identity receipt path'

if ([string]::IsNullOrWhiteSpace($ArchivePath) -or -not (Test-Path -LiteralPath $ArchivePath -PathType Leaf)) {
    if (-not [string]::IsNullOrWhiteSpace($PackageRoot)) {
        $parentArchive = Join-Path (Split-Path $PackageRoot -Parent) ([string]$profile.archiveFileName)
        if (Test-Path -LiteralPath $parentArchive -PathType Leaf) {
            $ArchivePath = $parentArchive
        }
    }
}
if ([string]::IsNullOrWhiteSpace($ArchivePath) -or -not (Test-Path -LiteralPath $ArchivePath -PathType Leaf)) {
    throw "Package archive was not found: $ArchivePath"
}
Assert-RendererNonReparsePath $ArchivePath $ArchivePath 'Package archive path'

if ([string]::IsNullOrWhiteSpace($PackageRoot) -or -not (Test-Path -LiteralPath $PackageRoot -PathType Container)) {
    throw "Package root directory was not found: $PackageRoot"
}
Assert-RendererNonReparsePath $PackageRoot $PackageRoot 'Package root'

# Validate package against committed package identity rules
Write-Host 'INFO [harness] validating committed package identity...'
$initialReceiptRead = Read-RendererCanonicalPackageReceipt $IdentityReceiptPath $RepositoryRoot
$validatedCommittedPackage = Assert-RendererCommittedPackageIdentity `
    -Identity $initialReceiptRead.Identity `
    -Profile $profile `
    -RepositoryRoot $RepositoryRoot `
    -ArchivePath $ArchivePath `
    -PackageRoot $PackageRoot `
    -ProfilePath $ProfilePath `
    -ReceiptSha256 $initialReceiptRead.ReceiptSha256 `
    -CanonicalReceiptJson $initialReceiptRead.CanonicalJson
Write-Host 'INFO [harness] package identity validated.'

# Observe the host at invocation time. Synthetic selftests retain the observation
# in the report but do not receive Runtime/Release credit.
$environment = Copy-RendererValue (Get-RendererEnvironmentSnapshot)
Assert-RendererEnvironmentSnapshot $environment
if ($captureMode -eq 'LiveOperator') {
    Assert-RendererLiveEnvironment $environment $RepositoryRoot
}

if (-not [string]::IsNullOrWhiteSpace($CaptureSourceDirectory)) {
    $CaptureSourceDirectory = [IO.Path]::GetFullPath($CaptureSourceDirectory)
    if (-not (Test-Path -LiteralPath $CaptureSourceDirectory -PathType Container)) {
        throw "Capture source directory was not found: $CaptureSourceDirectory"
    }
    Assert-RendererNonReparsePath $CaptureSourceDirectory $CaptureSourceDirectory 'Capture source directory'
}

# Check output directory and setup staging (atomic output / no-clobber)
$outFull = [IO.Path]::GetFullPath($OutputDirectory)
if (Test-Path -LiteralPath $outFull) {
    throw "Output directory already exists: $outFull (no-clobber policy)."
}

$parentOut = Split-Path -Path $outFull -Parent
if (-not [string]::IsNullOrWhiteSpace($parentOut) -and -not (Test-Path -LiteralPath $parentOut -PathType Container)) {
    New-Item -ItemType Directory -Path $parentOut -ErrorAction Stop | Out-Null
}
if (-not [string]::IsNullOrWhiteSpace($parentOut)) {
    Assert-RendererNonReparsePath $parentOut $parentOut 'Output parent directory'
}

$stagingParent = if ([string]::IsNullOrWhiteSpace($parentOut)) { [IO.Path]::GetTempPath() } else { $parentOut }
$stagingDir = Join-Path $stagingParent ('.' + (Split-Path $outFull -Leaf) + '.staging-' + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $stagingDir -ErrorAction Stop | Out-Null
Assert-RendererNonReparsePath $parentOut $stagingDir 'Renderer staging directory'

$commitSuccessful = $false
try {
    # 1. Stage package artifacts
    Write-Host 'INFO [harness] staging package artifacts...'
    $stagedPackageRoot = Join-Path $stagingDir 'package'
    New-Item -ItemType Directory -Path $stagedPackageRoot -Force | Out-Null

    foreach ($item in Get-ChildItem -LiteralPath $PackageRoot -Force) {
        Copy-Item -LiteralPath $item.FullName -Destination (Join-Path $stagedPackageRoot $item.Name) -Recurse -Force
    }

    $stagedArchive = Join-Path $stagingDir ([string]$profile.archiveFileName)
    Copy-Item -LiteralPath $ArchivePath -Destination $stagedArchive -Force

    $stagedReceipt = Join-Path $stagingDir 'package-identity-receipt.json'
    Copy-Item -LiteralPath $IdentityReceiptPath -Destination $stagedReceipt -Force

    $stagedReceiptRead = Read-RendererCanonicalPackageReceipt $stagedReceipt $RepositoryRoot
    $stagedArchiveStable = Get-RendererPackageStableIdentity $stagedArchive
    $stagedAppPath = Join-Path $stagedPackageRoot ([string]$profile.components.appRelativePath)
    $stagedCorePath = Join-Path $stagedPackageRoot ([string]$profile.components.coreRelativePath)
    $stagedAppStable = Get-RendererPackageStableIdentity $stagedAppPath
    $stagedCoreStable = Get-RendererPackageStableIdentity $stagedCorePath

    # 2. Establish 8 lifecycle stage observations & pre-first-HWND proof.
    # Live mode accepts only operator-supplied native observations; synthetic
    # mode is explicit and remains outside Runtime/Release evidence.
    Write-Host "INFO [harness] recording 8 $captureMode lifecycle observations..."
    $proofDir = Join-Path $stagingDir 'proofs'
    New-Item -ItemType Directory -Path $proofDir -ErrorAction Stop | Out-Null

    $observations = @()
    $syntheticLastUtc = [DateTimeOffset]::UtcNow
    $firstHwndCreatedUtc = $null
    $preFirstHasAnyHwnd = $null
    for ($i = 0; $i -lt $script:RendererObservationStages.Count; $i++) {
        $stage = $script:RendererObservationStages[$i]
        if ($TestFaultStage -eq 'MissingStage' -and $stage -eq 'AfterEnglishCaptures') {
            continue
        }

        if ($null -ne $OperatorObservationAction) {
            $rawResults = @(& $OperatorObservationAction -Stage $stage -Ordinal $i)
            if ($rawResults.Count -ne 1) { throw "Operator observation action must return exactly one record for '$stage'." }
            $raw = $rawResults[0]
            Assert-RendererExactProperties $raw @('effectiveMode','softwareOnlyConfirmed','observedUtc','nativeProcessRenderMode','nativeRenderCapabilityTier','hasAnyHwnd','firstHwndCreatedUtc') "Operator observation '$stage'"
        } elseif ($captureMode -eq 'SyntheticSelfTest') {
            $now = [DateTimeOffset]::UtcNow
            if ($now -le $syntheticLastUtc) { $now = $syntheticLastUtc.AddTicks(1) }
            $syntheticLastUtc = $now
            $firstForStage = if ($i -ge 2) { $now.ToUniversalTime().ToString('O', [Globalization.CultureInfo]::InvariantCulture) } else { $null }
            $raw = [pscustomobject][ordered]@{
                effectiveMode = 'SoftwareOnly'
                softwareOnlyConfirmed = $true
                observedUtc = $now.ToUniversalTime().ToString('O', [Globalization.CultureInfo]::InvariantCulture)
                nativeProcessRenderMode = 'SoftwareOnly'
                nativeRenderCapabilityTier = 2
                hasAnyHwnd = ($i -ge 2)
                firstHwndCreatedUtc = $firstForStage
            }
        }

        Assert-RendererString $raw.effectiveMode "Renderer observation '$stage' effectiveMode"
        Assert-RendererBoolean $raw.softwareOnlyConfirmed "Renderer observation '$stage' softwareOnlyConfirmed"
        Assert-RendererString $raw.nativeProcessRenderMode "Renderer observation '$stage' nativeProcessRenderMode"
        Assert-RendererNonnegativeInteger $raw.nativeRenderCapabilityTier "Renderer observation '$stage' nativeRenderCapabilityTier"
        Assert-RendererBoolean $raw.hasAnyHwnd "Renderer observation '$stage' hasAnyHwnd"
        $mode = [string]$raw.effectiveMode
        $confirmed = [bool]$raw.softwareOnlyConfirmed
        $timeStr = [string]$raw.observedUtc
        $hasAnyHwnd = [bool]$raw.hasAnyHwnd
        $rawFirstHwnd = $raw.firstHwndCreatedUtc
        if ($i -lt 2 -and $hasAnyHwnd) { throw "Operator observation '$stage' reports an HWND before the first-window boundary." }
        if ($i -ge 2 -and -not $hasAnyHwnd) { throw "Operator observation '$stage' did not report the already-created HWND." }
        Assert-RendererUtc $timeStr "Renderer observation '$stage' UTC"
        Assert-RendererNullableUtc $rawFirstHwnd "Renderer observation '$stage' first HWND UTC"
        if ($i -eq 1) { $preFirstHasAnyHwnd = $hasAnyHwnd }
        if ($i -eq 2) { $firstHwndCreatedUtc = [string]$rawFirstHwnd }
        if ($i -ge 2 -and [string]::IsNullOrWhiteSpace([string]$rawFirstHwnd)) { throw "Renderer observation '$stage' omitted the actual first HWND timestamp." }
        if ($TestFaultStage -eq 'LatePreFirstHwnd' -and $i -eq 2) { $firstHwndCreatedUtc = ([DateTimeOffset]$observations[1].observedUtc).AddTicks(-1).ToUniversalTime().ToString('O', [Globalization.CultureInfo]::InvariantCulture) }
        if ($TestFaultStage -eq 'HardwareModeDrift' -and $stage -eq 'PostFirstWindowShown') { $mode = 'Hardware'; $confirmed = $false }
        if ($TestFaultStage -eq 'OutOfOrderStages' -and $i -eq 4) { $timeStr = [string]$observations[2].observedUtc }

        $proofObj = [pscustomobject][ordered]@{
            stage = $stage
            effectiveMode = $mode
            softwareOnlyConfirmed = $confirmed
            observedUtc = $timeStr
            nativeProcessRenderMode = [string]$raw.nativeProcessRenderMode
            nativeRenderCapabilityTier = [int]$raw.nativeRenderCapabilityTier
        }

        $proofRel = "proofs/$i-$stage.json"
        $proofFullPath = Join-Path $stagingDir $proofRel
        Write-RendererPackageCanonicalJson $proofObj $proofFullPath $RepositoryRoot
        $proofStable = Get-RendererPackageStableIdentity $proofFullPath
        $proofCanonical = ConvertTo-RendererCanonicalJson $proofObj $RepositoryRoot
        $proofCanonicalSha = Get-HumanDesignReviewSha256ForText -Text $proofCanonical

        $proofBinding = [pscustomobject][ordered]@{
            relativePath = $proofRel
            bytes = [long]$proofStable.Length
            fileSha256 = $proofStable.Sha256
            canonicalSha256 = $proofCanonicalSha
        }

        $observations += ,([pscustomobject][ordered]@{
            stage = $stage
            effectiveMode = $mode
            softwareOnlyConfirmed = $confirmed
            observedUtc = $timeStr
            proofReceipt = $proofBinding
        })
    }

    if ($observations.Count -ne 8) {
        throw "Live renderer capture harness requires exactly 8 lifecycle stage observations; found $($observations.Count)."
    }
    if ([bool]$preFirstHasAnyHwnd -or [string]::IsNullOrWhiteSpace($firstHwndCreatedUtc)) {
        throw 'Pre-first-HWND observation did not prove the actual first HWND boundary.'
    }

    # 3. Capture 20 PNG captures (10 Thai, 10 English)
    Write-Host 'INFO [harness] ingesting and validating 20 named captures...'
    $capturesDir = Join-Path $stagingDir 'captures'
    $thaiDir = Join-Path $capturesDir 'Thai'
    $englishDir = Join-Path $capturesDir 'English'
    New-Item -ItemType Directory -Path $capturesDir -ErrorAction Stop | Out-Null
    New-Item -ItemType Directory -Path $thaiDir, $englishDir -ErrorAction Stop | Out-Null

    $captures = @()
    $producerCaptures = @()

    foreach ($language in @('Thai', 'English')) {
        $langDir = if ($language -eq 'Thai') { $thaiDir } else { $englishDir }
        $windowStart = if ($language -eq 'Thai') { [DateTimeOffset]$observations[3].observedUtc } else { [DateTimeOffset]$observations[5].observedUtc }
        $windowEnd = if ($language -eq 'Thai') { [DateTimeOffset]$observations[4].observedUtc } else { [DateTimeOffset]$observations[6].observedUtc }
        if ($windowEnd -lt $windowStart) { throw "Renderer observation window for '$language' is reversed." }
        $midTime = $windowStart.AddTicks([long](($windowEnd - $windowStart).Ticks / 2))

        foreach ($name in $script:RendererCaptureNames) {
            if ($TestFaultStage -eq 'MissingCapture' -and $language -eq 'Thai' -and $name -eq 'widget-compact') {
                continue
            }

            $destPng = Join-Path $langDir "$name.png"
            $relPath = "captures/$language/$name.png"

            $captureUtc = $midTime.ToUniversalTime().ToString('O', [Globalization.CultureInfo]::InvariantCulture)
            if (-not [string]::IsNullOrWhiteSpace($CaptureSourceDirectory)) {
                $sourceRelative = (Join-Path $language "$name.png") -replace '\\','/'
                $sourcePng = Resolve-RendererBoundPath $CaptureSourceDirectory $sourceRelative "Capture '$language|$name' source path"
                if (-not (Test-Path -LiteralPath $sourcePng -PathType Leaf)) {
                    $sourceRelative = "$name.png"
                    $sourcePng = Resolve-RendererBoundPath $CaptureSourceDirectory $sourceRelative "Capture '$language|$name' source path"
                }
                if (-not (Test-Path -LiteralPath $sourcePng -PathType Leaf)) {
                    throw "Required capture file '$name.png' for language '$language' is missing from source: $CaptureSourceDirectory"
                }
                $sourceIdentity = Get-RendererPngIdentity $CaptureSourceDirectory $sourcePng "Capture '$language|$name' source"
                [IO.File]::WriteAllBytes($destPng, $sourceIdentity.Content)
                if ($captureMode -eq 'LiveOperator') {
                    $captureUtc = [DateTimeOffset]([IO.File]::GetLastWriteTimeUtc($sourcePng)).ToUniversalTime().ToString('O', [Globalization.CultureInfo]::InvariantCulture)
                }
            } elseif ($SyntheticCapturesForTesting) {
                if ($TestFaultStage -eq 'CorruptPng' -and $name -eq 'dashboard-overview') {
                    [IO.File]::WriteAllBytes($destPng, [byte[]]@(1, 2, 3, 4, 5))
                } else {
                    New-RendererTestPng -Path $destPng -Width 64 -Height 48
                }
            } elseif ($null -ne $OperatorCaptureAction) {
                $captureResults = @(& $OperatorCaptureAction -Language $language -Name $name -DestinationPath $destPng)
                if ($captureResults.Count -gt 1) { throw "Operator capture action returned more than one record for '$language|$name'." }
                if (-not (Test-Path -LiteralPath $destPng -PathType Leaf)) {
                    throw "Operator capture action did not produce expected file: $destPng"
                }
                if ($captureResults.Count -eq 1 -and $null -ne $captureResults[0].PSObject.Properties['observedUtc']) {
                    $captureUtc = [string]$captureResults[0].observedUtc
                } else {
                    $captureUtc = [DateTimeOffset]([IO.File]::GetLastWriteTimeUtc($destPng)).ToUniversalTime().ToString('O', [Globalization.CultureInfo]::InvariantCulture)
                }
            } else {
                throw 'No capture source provided. Provide -CaptureSourceDirectory, -OperatorCaptureAction, or -SyntheticCapturesForTesting.'
            }
            if ($TestFaultStage -eq 'CaptureOutsideWindow' -and $language -eq 'Thai' -and $name -eq 'dashboard-overview') {
                $captureUtc = $windowEnd.AddTicks(1).ToUniversalTime().ToString('O', [Globalization.CultureInfo]::InvariantCulture)
            }
            Assert-RendererUtc $captureUtc "Capture '$language|$name' UTC"

            $pngIdentity = Get-RendererPngIdentity $stagingDir $destPng "Capture '$language|$name'"

            $captureObj = [pscustomobject][ordered]@{
                language = $language
                name = $name
                category = (Get-RendererCategory $name)
                semanticPhase = (Get-RendererSemanticPhase $name)
                relativePath = $relPath
                widthPixels = [int]$pngIdentity.Width
                heightPixels = [int]$pngIdentity.Height
                bytes = [long]$pngIdentity.Bytes
                sha256 = [string]$pngIdentity.Sha256
                observedUtc = $captureUtc
            }
            $captures += ,$captureObj
            Write-Host "INFO [harness] capture $language $name -> $relPath"

            $producerCaptures += ,([pscustomobject][ordered]@{
                language = $language
                name = $name
                sha256 = [string]$pngIdentity.Sha256
                observedUtc = $captureUtc
            })
        }
    }

    if ($captures.Count -ne 20) {
        throw "Live renderer capture harness requires exactly 20 captures (10 Thai, 10 English); found $($captures.Count)."
    }

    # 4. Generate Producer App Report
    $producerDir = Join-Path $stagingDir 'producer'
    New-Item -ItemType Directory -Path $producerDir -Force | Out-Null

    $producerValue = [pscustomobject][ordered]@{
        reportType = 'V02RendererCompatibilityAppReport'
        profileId = $script:RendererProfileId
        profileSha256 = $script:RendererProfileSha256
        source = [pscustomobject][ordered]@{
            commitSha = $sourceCommit
            treeSha = $sourceTree
        }
        packageReceiptSha256 = [string]$stagedReceiptRead.ReceiptSha256
        rendererPolicy = 'software-only-process-wide'
        observations = @($observations | ForEach-Object { [pscustomobject]$_ })
        captures = @($producerCaptures | ForEach-Object { [pscustomobject]$_ })
    }

    $producerPath = Join-Path $stagingDir 'producer/app-renderer-report.json'
    Write-RendererPackageCanonicalJson $producerValue $producerPath $RepositoryRoot
    $producerStable = Get-RendererPackageStableIdentity $producerPath
    $producerCanonical = ConvertTo-RendererCanonicalJson $producerValue $RepositoryRoot
    $producerCanonicalSha = Get-HumanDesignReviewSha256ForText -Text $producerCanonical

    $producerBinding = [pscustomobject][ordered]@{
        relativePath = 'producer/app-renderer-report.json'
        bytes = [long]$producerStable.Length
        fileSha256 = $producerStable.Sha256
        canonicalSha256 = $producerCanonicalSha
    }

    # 5. References and comparison results
    $refs = @()
    $referenceManifest = Read-HumanDesignReviewReferenceManifest
    foreach ($refName in @($referenceManifest.Keys | Sort-Object)) {
        $entry = $referenceManifest[$refName]
        $refs += ,([pscustomobject][ordered]@{
            relativePath = "docs/design/reference/$refName"
            widthPixels = [int]$entry.Width
            heightPixels = [int]$entry.Height
            bytes = [long]$entry.Bytes
            sha256 = [string]$entry.Sha256
        })
    }

    $comparisonResults = @()
    foreach ($language in @('Thai', 'English')) {
        foreach ($name in $script:RendererCaptureNames) {
            $comparisonResults += ,([pscustomobject][ordered]@{
                language = $language
                captureName = $name
                referenceRelativePath = (Get-RendererReferencePath $name)
                status = 'NOT_OBSERVED'
                differentPixels = $null
                differentPixelPercent = $null
                maximumChannelDelta = $null
                nonmaskedDifferenceCount = $null
                disposition = $null
            })
        }
    }

    # 6. Matrices, performance limits, review, boundaries
    $limitNames = @(
        'cpuMaximumPercent', 'eventToWpfP95Milliseconds', 'cpuRegressionMaximumPercent',
        'cpuRegressionMaximumPercentagePoints', 'latencyRegressionMaximumPercent',
        'uiStallP95Milliseconds', 'uiStallMaximumMilliseconds', 'soakAcDurationMinutes',
        'soakBatteryDurationMinutes', 'soakBinMinutes', 'workingSetMaximumBytes',
        'resourceSlopeMaximumBytesPerTenMinutes')
    $limits = [ordered]@{
        status = 'APPROVED'
        approvalReference = $script:RendererAuthorizedApprovalReference
    }
    $limitValues = @(1, 250, 10, 0.5, 10, 50, 100, 60, 60, 5, 267386880, 1048576)
    for ($i = 0; $i -lt $limitNames.Count; $i++) {
        $limits[$limitNames[$i]] = $limitValues[$i]
    }

    $manifest = [ordered]@{
        '$id' = $script:RendererSchemaId
        manifestVersion = 1
        evidenceClassification = 'PackagedCompatibilityCandidate'
        issue = 149
        governance = [ordered]@{
            decisionId = $script:RendererDecisionId
            approvalReference = $script:RendererAuthorizedApprovalReference
            originalApprovedUtc = $script:RendererDecisionApprovedUtc
            correctedUtc = $script:RendererDecisionCorrectedUtc
            decisionPayloadSha256 = $script:RendererDecisionPayloadSha256
            supersedesDecisionId = $script:RendererSupersedesDecisionId
            supersedesPayloadSha256 = $script:RendererSupersedesPayloadSha256
        }
        candidate = [ordered]@{
            source = [ordered]@{
                commitSha = $sourceCommit
                treeSha = $sourceTree
            }
            profile = [ordered]@{
                id = $profileIdentity.Id
                relativePath = $profileIdentity.RelativePath
                bytes = [long]$profileIdentity.Bytes
                fileSha256 = $profileIdentity.FileSha256
                canonicalSha256 = $profileIdentity.CanonicalSha256
            }
            receipt = [ordered]@{
                relativePath = 'package-identity-receipt.json'
                bytes = [long]$stagedReceiptRead.Stable.Length
                fileSha256 = $stagedReceiptRead.Stable.Sha256
                canonicalSha256 = $stagedReceiptRead.ReceiptSha256
            }
            archive = [ordered]@{
                relativePath = [string]$profile.archiveFileName
                fileName = [string]$profile.archiveFileName
                bytes = [long]$stagedArchiveStable.Length
                sha256 = $stagedArchiveStable.Sha256
            }
            packageRootRelativePath = 'package'
            components = [ordered]@{
                app = [ordered]@{
                    relativePath = [string]$profile.components.appRelativePath
                    bytes = [long]$stagedAppStable.Length
                    sha256 = $stagedAppStable.Sha256
                }
                core = [ordered]@{
                    relativePath = [string]$profile.components.coreRelativePath
                    bytes = [long]$stagedCoreStable.Length
                    sha256 = $stagedCoreStable.Sha256
                }
            }
            referenceHost = [ordered]@{
                profileId = $script:RendererProfileId
                profileSha256 = $script:RendererProfileSha256
            }
            renderer = [ordered]@{
                policy = 'software-only-process-wide'
                wpfProcessRenderMode = 'SoftwareOnly'
            }
        }
        environment = (Copy-RendererValue $environment)
        rendererEvidence = [ordered]@{
            policyId = 'software-only-process-wide'
            trigger = 'ApprovedV02CandidatePolicy'
            fallback = 'None'
            producerReport = $producerBinding
            preFirstHwnd = [ordered]@{
                hasAnyHwnd = [bool]$preFirstHasAnyHwnd
                observation = (Copy-RendererValue $observations[1])
                firstHwndCreatedUtc = $firstHwndCreatedUtc
            }
            throughoutObservations = $observations
        }
        captures = $captures
        references = $refs
        comparison = [ordered]@{
            algorithm = [ordered]@{
                name = 'ExactPixelComparator'
                version = '1'
                colorSpace = 'sRGB'
                alphaMode = 'Straight'
            }
            tolerance = [ordered]@{
                approvalStatus = 'APPROVED'
                approvalReference = $script:RendererAuthorizedApprovalReference
                perChannelDelta = 8
                maximumDifferentPixelPercent = 0.1
                maximumNonmaskedDifferences = 0
            }
            maskSetReceipt = $null
            masks = @()
            results = $comparisonResults
        }
        matrices = [ordered]@{
            displayCases = @(New-RendererMatrixCases $script:RendererDisplayCases)
            mixedDpiTransitions = @(New-RendererMatrixCases $script:RendererMixedDpiCases)
            accessibilityCases = @(New-RendererMatrixCases $script:RendererAccessibilityCases)
            supportedEnvironmentCases = @(New-RendererMatrixCases $script:RendererEnvironmentCases)
        }
        performanceProtocol = [ordered]@{
            sameCandidateContentWorkloadHostSession = $true
            onlyRendererPolicyVaries = $true
            modeA = 'Hardware'
            modeB = 'SoftwareOnly'
            orders = @('AB', 'BA')
            warmupIterations = 1
            repetitionsPerOrder = 5
            statistic = 'p95-and-maximum-missing-sample-fails'
            ownerNumericLimits = (Copy-RendererValue $limits)
            samplesStatus = 'NOT_OBSERVED'
            evidenceReceipt = $null
        }
        review = [ordered]@{
            decision = 'NOT_OBSERVED'
            approvalReference = $null
            reviewerIdentity = $null
            reviewerRole = $null
            reviewedUtc = $null
            visualChecks = @(New-RendererMatrixCases $script:RendererVisualChecks)
            defects = @()
        }
        evidenceBoundary = [ordered]@{
            packagedCompatibility = 'CANDIDATE'
            captureMode = $captureMode
            humanReview = 'NOT_OBSERVED'
            actualHerdrRuntime = 'NOT_OBSERVED'
            release = 'NOT_OBSERVED'
            creditGranted = $false
        }
    }

    # 7. Write and validate manifest
    $manifestPath = Join-Path $stagingDir 'v0.2-renderer-compatibility-manifest.json'
    [IO.File]::WriteAllText($manifestPath, ($manifest | ConvertTo-Json -Depth 80), (New-Object Text.UTF8Encoding($false)))
    Write-Host 'INFO [harness] self-validating manifest with Test-RendererCompatibilityManifest...'

    $null = Test-RendererCompatibilityManifest `
        -ManifestPath $manifestPath `
        -EvidenceRoot $stagingDir `
        -RepositoryRoot $RepositoryRoot `
        -ValidateBindings

    if ($TestFaultStage -eq 'PreCommit') {
        throw 'Injected failure before commit.'
    }

    # 8. Commit atomic staging directory to destination. Directory.Move is
    # deliberately no-clobber; all containment/reparse checks are repeated
    # immediately before the race-sensitive rename.
    if ($TestFaultStage -eq 'OutputRace') {
        New-Item -ItemType Directory -Path $outFull -ErrorAction Stop | Out-Null
    }
    Assert-RendererNonReparsePath $parentOut $parentOut 'Output parent directory before publish'
    Assert-RendererNonReparsePath $parentOut $stagingDir 'Staging directory before publish'
    if (Test-Path -LiteralPath $outFull) {
        throw "Output directory appeared before atomic no-clobber publish: $outFull"
    }
    [IO.Directory]::Move($stagingDir, $outFull)
    Assert-RendererNonReparsePath $parentOut $outFull 'Published renderer evidence directory'
    $commitSuccessful = $true

    $finalManifestPath = Join-Path $outFull 'v0.2-renderer-compatibility-manifest.json'
    $finalManifestSha = (Get-RendererStableFileIdentity $outFull $finalManifestPath 'Published renderer manifest').Sha256

    [pscustomobject][ordered]@{
        EvidenceClassification = 'PackagedCompatibilityCandidate'
        CaptureMode = $captureMode
        Status = 'ManifestCreated'
        OutputDirectory = $outFull
        ManifestPath = $finalManifestPath
        ManifestSha256 = $finalManifestSha
        CaptureCount = $captures.Count
        ThaiCaptures = 10
        EnglishCaptures = 10
        LifecycleStages = $observations.Count
        SoftwareOnlyConfirmed = (@($observations | Where-Object { $_.effectiveMode -ne 'SoftwareOnly' -or -not [bool]$_.softwareOnlyConfirmed }).Count -eq 0)
        PreFirstHwndProofConfirmed = (-not [bool]$preFirstHasAnyHwnd -and -not [string]::IsNullOrWhiteSpace($firstHwndCreatedUtc))
        HumanReview = 'NOT_OBSERVED'
        ActualHerdrRuntime = 'NOT_OBSERVED'
        ReleaseCredit = $false
        PackagedCompatibilityReadyForIssue149Closure = $false
    }
} finally {
    if (-not $commitSuccessful -and (Test-Path -LiteralPath $stagingDir)) {
        Remove-Item -LiteralPath $stagingDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}
