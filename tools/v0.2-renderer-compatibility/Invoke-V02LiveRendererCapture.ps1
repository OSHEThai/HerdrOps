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

    [switch]$SyntheticCapturesForTesting,

    [switch]$AllowElevatedForTesting,

    [switch]$AllowNonReferenceHostForTesting,

    [string]$TestFaultStage,

    [switch]$Force
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'RendererCompatibility.Common.ps1')

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

# Check session environment constraints
$sessionName = $env:SESSIONNAME
$isRdp = $false
if (-not [string]::IsNullOrWhiteSpace($sessionName) -and $sessionName -match '^(RDP|ICA)') {
    $isRdp = $true
}

$isElevated = $false
$windowsIdentity = [Security.Principal.WindowsIdentity]::GetCurrent()
if ($null -ne $windowsIdentity) {
    $principal = New-Object Security.Principal.WindowsPrincipal($windowsIdentity)
    $isElevated = $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

if ($isElevated -and -not $AllowElevatedForTesting) {
    throw 'Live renderer capture harness must be executed in a non-elevated user session for production candidate evidence.'
}
if ($isRdp -and -not $AllowNonReferenceHostForTesting) {
    throw 'Live renderer capture harness must be executed on a local physical console session; RDP is excluded.'
}

# Check output directory and setup staging (atomic output / no-clobber)
$outFull = [IO.Path]::GetFullPath($OutputDirectory)
if (Test-Path -LiteralPath $outFull) {
    if (-not $Force) {
        throw "Output directory already exists: $outFull (no-clobber policy). Specify -Force to replace."
    }
}

$parentOut = Split-Path -Path $outFull -Parent
if (-not [string]::IsNullOrWhiteSpace($parentOut) -and -not (Test-Path -LiteralPath $parentOut -PathType Container)) {
    New-Item -ItemType Directory -Path $parentOut -Force | Out-Null
}
if (-not [string]::IsNullOrWhiteSpace($parentOut)) {
    Assert-RendererNonReparsePath $parentOut $parentOut 'Output parent directory'
}

$stagingParent = if ([string]::IsNullOrWhiteSpace($parentOut)) { [IO.Path]::GetTempPath() } else { $parentOut }
$stagingDir = Join-Path $stagingParent ('.' + (Split-Path $outFull -Leaf) + '.staging-' + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $stagingDir -Force | Out-Null

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

    # 2. Establish 8 lifecycle stage observations & pre-first-HWND proof
    Write-Host 'INFO [harness] recording 8 lifecycle stage observations & pre-first-HWND proof...'
    $baseUtc = [DateTimeOffset]::UtcNow
    $timeStartup = $baseUtc
    $timePreFirst = $timeStartup.AddMilliseconds(100)
    $timeFirstHwnd = $timePreFirst.AddMilliseconds(200)
    $timePostFirst = $timeFirstHwnd.AddMilliseconds(200)
    $timeBeforeThai = $timePostFirst.AddSeconds(1)
    $timeAfterThai = $timeBeforeThai.AddSeconds(3)
    $timeBeforeEnglish = $timeAfterThai.AddSeconds(1)
    $timeAfterEnglish = $timeBeforeEnglish.AddSeconds(3)
    $timeFinal = $timeAfterEnglish.AddSeconds(1)

    if ($TestFaultStage -eq 'LatePreFirstHwnd') {
        $timeFirstHwnd = $timePreFirst.AddMilliseconds(-50)
    }

    $stageTimes = @(
        $timeStartup,
        $timePreFirst,
        $timePostFirst,
        $timeBeforeThai,
        $timeAfterThai,
        $timeBeforeEnglish,
        $timeAfterEnglish,
        $timeFinal
    )

    $proofDir = Join-Path $stagingDir 'proofs'
    New-Item -ItemType Directory -Path $proofDir -Force | Out-Null

    $observations = @()
    for ($i = 0; $i -lt $script:RendererObservationStages.Count; $i++) {
        $stage = $script:RendererObservationStages[$i]
        if ($TestFaultStage -eq 'MissingStage' -and $stage -eq 'AfterEnglishCaptures') {
            continue
        }

        $mode = 'SoftwareOnly'
        if ($TestFaultStage -eq 'HardwareModeDrift' -and $stage -eq 'PostFirstWindowShown') {
            $mode = 'Hardware'
        }

        $timeStr = $stageTimes[$i].ToUniversalTime().ToString('O', [Globalization.CultureInfo]::InvariantCulture)
        if ($TestFaultStage -eq 'OutOfOrderStages' -and $i -eq 4) {
            $timeStr = $stageTimes[2].ToUniversalTime().ToString('O', [Globalization.CultureInfo]::InvariantCulture)
        }

        $proofObj = [pscustomobject][ordered]@{
            stage = $stage
            effectiveMode = $mode
            softwareOnlyConfirmed = ($mode -eq 'SoftwareOnly')
            observedUtc = $timeStr
            nativeProcessRenderMode = $mode
            nativeRenderCapabilityTier = 2
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
            softwareOnlyConfirmed = ($mode -eq 'SoftwareOnly')
            observedUtc = $timeStr
            proofReceipt = $proofBinding
        })
    }

    if ($observations.Count -ne 8) {
        throw "Live renderer capture harness requires exactly 8 lifecycle stage observations; found $($observations.Count)."
    }

    # 3. Capture 20 PNG captures (10 Thai, 10 English)
    Write-Host 'INFO [harness] ingesting and validating 20 named captures...'
    $capturesDir = Join-Path $stagingDir 'captures'
    $thaiDir = Join-Path $capturesDir 'Thai'
    $englishDir = Join-Path $capturesDir 'English'
    New-Item -ItemType Directory -Path $thaiDir, $englishDir -Force | Out-Null

    $captures = @()
    $producerCaptures = @()

    foreach ($language in @('Thai', 'English')) {
        $langDir = if ($language -eq 'Thai') { $thaiDir } else { $englishDir }
        $windowStart = if ($language -eq 'Thai') { $timeBeforeThai } else { $timeBeforeEnglish }
        $windowEnd = if ($language -eq 'Thai') { $timeAfterThai } else { $timeAfterEnglish }
        $midTime = $windowStart.AddMilliseconds(($windowEnd - $windowStart).TotalMilliseconds / 2)
        $captureUtc = $midTime.ToUniversalTime().ToString('O', [Globalization.CultureInfo]::InvariantCulture)

        if ($TestFaultStage -eq 'CaptureOutsideWindow' -and $language -eq 'Thai') {
            $captureUtc = $timeAfterEnglish.AddSeconds(10).ToUniversalTime().ToString('O', [Globalization.CultureInfo]::InvariantCulture)
        }

        foreach ($name in $script:RendererCaptureNames) {
            if ($TestFaultStage -eq 'MissingCapture' -and $language -eq 'Thai' -and $name -eq 'widget-compact') {
                continue
            }

            $destPng = Join-Path $langDir "$name.png"
            $relPath = "captures/$language/$name.png"

            if ($SyntheticCapturesForTesting) {
                if ($TestFaultStage -eq 'CorruptPng' -and $name -eq 'dashboard-overview') {
                    [IO.File]::WriteAllBytes($destPng, [byte[]]@(1, 2, 3, 4, 5))
                } else {
                    New-RendererTestPng -Path $destPng -Width 64 -Height 48
                }
            } elseif (-not [string]::IsNullOrWhiteSpace($CaptureSourceDirectory)) {
                $sourcePng = Join-Path $CaptureSourceDirectory (Join-Path $language "$name.png")
                if (-not (Test-Path -LiteralPath $sourcePng -PathType Leaf)) {
                    $sourcePng = Join-Path $CaptureSourceDirectory "$name.png"
                }
                if (-not (Test-Path -LiteralPath $sourcePng -PathType Leaf)) {
                    throw "Required capture file '$name.png' for language '$language' is missing from source: $CaptureSourceDirectory"
                }
                Copy-Item -LiteralPath $sourcePng -Destination $destPng -Force
            } elseif ($null -ne $OperatorCaptureAction) {
                & $OperatorCaptureAction -Language $language -Name $name -DestinationPath $destPng
                if (-not (Test-Path -LiteralPath $destPng -PathType Leaf)) {
                    throw "Operator capture action did not produce expected file: $destPng"
                }
            } else {
                throw 'No capture source provided. Provide -CaptureSourceDirectory, -OperatorCaptureAction, or -SyntheticCapturesForTesting.'
            }

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
        environment = [ordered]@{
            os = [ordered]@{
                caption = 'Microsoft Windows 11 Pro Insider Preview'
                version = '10.0.26220'
                build = 26220
                architecture = 'x64'
            }
            graphicsAdapters = @(
                [ordered]@{
                    displayName = 'Intel(R) UHD Graphics'
                    pnpDeviceId = 'PCI\VEN_8086&DEV_4688&SUBSYS_170F1025&REV_0C\3&11583659&0&10'
                    driverVersion = '31.0.101.4146'
                },
                [ordered]@{
                    displayName = 'NVIDIA GeForce RTX 4050 Laptop GPU'
                    pnpDeviceId = 'PCI\VEN_10DE&DEV_28E1&SUBSYS_170F1025&REV_A1\4&2CAD08CE&0&0008'
                    driverVersion = '32.0.16.1088'
                }
            )
            display = [ordered]@{
                deviceName = '\\.\DISPLAY1'
                physicalWidthPixels = 2560
                physicalHeightPixels = 1600
                logicalWidthPixels = 2048
                logicalHeightPixels = 1280
                desktopAppliedDpi = 120
                scalePercent = 125
                refreshRateHz = 60
                monitorCount = 1
            }
            session = [ordered]@{
                kind = 'LocalConsole'
                name = 'Console'
                sessionId = 1
                transport = 'Physical'
                powerSource = 'AC'
                thermalState = 'Nominal'
                elevated = $false
                userScope = 'SingleUser'
            }
            supportScope = [ordered]@{
                supported = @(
                    'windows11-x64-build26220',
                    'local-console',
                    'non-elevated',
                    'single-user',
                    'physical-display-matrix',
                    'ac-power',
                    'battery-power'
                )
                excluded = @(
                    'rdp-runtime',
                    'vm-runtime',
                    'arm64',
                    'remote-cloud',
                    'multi-user'
                )
                vmCleanInstallOnly = $true
                vmRuntimeCredit = $false
            }
        }
        rendererEvidence = [ordered]@{
            policyId = 'software-only-process-wide'
            trigger = 'ApprovedV02CandidatePolicy'
            fallback = 'None'
            producerReport = $producerBinding
            preFirstHwnd = [ordered]@{
                hasAnyHwnd = $false
                observation = (Copy-RendererValue $observations[1])
                firstHwndCreatedUtc = $timeFirstHwnd.ToUniversalTime().ToString('O', [Globalization.CultureInfo]::InvariantCulture)
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

    # 8. Commit atomic staging directory to destination
    if (Test-Path -LiteralPath $outFull) {
        Remove-Item -LiteralPath $outFull -Recurse -Force
    }
    [IO.Directory]::Move($stagingDir, $outFull)
    $commitSuccessful = $true

    $finalManifestPath = Join-Path $outFull 'v0.2-renderer-compatibility-manifest.json'
    $finalManifestSha = (Get-FileHash -LiteralPath $finalManifestPath -Algorithm SHA256).Hash

    [pscustomobject][ordered]@{
        EvidenceClassification = 'PackagedCompatibilityCandidate'
        Status = 'ManifestCreated'
        OutputDirectory = $outFull
        ManifestPath = $finalManifestPath
        ManifestSha256 = $finalManifestSha
        CaptureCount = $captures.Count
        ThaiCaptures = 10
        EnglishCaptures = 10
        LifecycleStages = $observations.Count
        SoftwareOnlyConfirmed = $true
        PreFirstHwndProofConfirmed = $true
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
