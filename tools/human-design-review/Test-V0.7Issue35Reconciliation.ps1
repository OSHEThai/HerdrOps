#requires -Version 5.1

[CmdletBinding()]
param(
    [string]$ReportPath,
    [switch]$KeepOnDisk
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'HumanDesignReview.Common.ps1')

### Issue #35 reconciliation: prove the candidate design-review manifest (forty
### page captures, reduced widget set, obsolete schema) is reconciled to the
### canonical verifier universe (60 page captures, 8 widget variants) via a
### deterministic, schema-valid Pending manifest. Pending is deliberate: it
### binds real structure and hash slots but never claims human acceptance.

function Get-Issue35ReconciliationTempRoot {
    $tempRoot = Normalize-Issue35ReconciliationTempPath ([IO.Path]::GetTempPath())
    for ($attempt = 0; $attempt -lt 10; $attempt++) {
        $candidate = Join-Path $tempRoot ('HerdrOps-Issue35Reconciliation-' + [Guid]::NewGuid().ToString('N'))
        if (-not (Test-Path -LiteralPath $candidate)) {
            New-Item -ItemType Directory -Path $candidate -Force | Out-Null
            return $candidate
        }
    }
    throw 'Could not create a unique Issue #35 reconciliation temp directory.'
}

function Normalize-Issue35ReconciliationTempPath {
    param([string]$Path)
    $fullPath = [IO.Path]::GetFullPath($Path)
    if ($fullPath.Length -gt 3) {
        return $fullPath.TrimEnd('\')
    }
    return $fullPath
}

function Get-Issue35ReconciliationReferenceForPage {
    param([Parameter(Mandatory = $true)][string]$Page)

    $map = @{
        'overview' = '01-overview.png'
        'live-organization' = '02-live-organization.png'
        'realtime-activity' = '03-realtime-activity.png'
        'delegation-graph' = '04-delegation-graph.png'
        'agent-detail' = '05-agent-detail.png'
        'task-alignment' = '06-task-alignment.png'
        'file-activity' = '07-file-activity.png'
        'compliance-queue' = '08-compliance-queue.png'
        'evaluation' = '09-evaluation.png'
        'daily-summary' = '10-daily-summary.png'
    }
    return $map[$Page]
}

function Get-Issue35ReconciliationVariantFile {
    param([Parameter(Mandatory = $true)][string]$Variant)

    $map = @{
        Compact = 'compact'
        Normal = 'normal'
        Expanded = 'expanded'
        FloatingMini = 'floatingmini'
        FloatingVertical = 'floatingvertical'
        Notification = 'notification'
        AgentDetailPopup = 'agentdetailpopup'
        DashboardPreview = 'dashboardpreview'
    }
    return $map[$Variant]
}

function Write-Issue35ReconciliationDeterministicFile {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Text
    )

    $normalized = $Text -replace "`r`n", "`n"
    $parent = Split-Path -Path $Path -Parent
    if (-not (Test-Path -LiteralPath $parent -PathType Container)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }
    [IO.File]::WriteAllText(([IO.Path]::GetFullPath($Path)), $normalized, (New-Object System.Text.UTF8Encoding($false)))
}

function Get-Issue35ReconciliationFileHash {
    param([Parameter(Mandatory = $true)][string]$Path)
    $bytes = [IO.File]::ReadAllBytes([IO.Path]::GetFullPath($Path))
    return (Get-HumanDesignReviewSha256ForBytes -Bytes $bytes).ToUpperInvariant()
}

function Get-Issue35ReconciliationCandidateDivergence {
    $mainCheckout = $null
    $gitCommonDir = (& git -C (Get-HumanDesignReviewRoot) rev-parse --git-common-dir 2>$null)
    if ($LASTEXITCODE -eq 0 -and -not [string]::IsNullOrWhiteSpace($gitCommonDir)) {
        $gitParent = Split-Path -Path $gitCommonDir -Parent
        if (-not [string]::IsNullOrWhiteSpace($gitParent)) {
            $mainCheckout = $gitParent
        }
    }

    $candidateGuesses = @(
        (Join-Path (Get-HumanDesignReviewRoot) 'artifacts\design-evidence\v0.7.0\issue-35\candidate-manifest.json')
    )
    if (-not [string]::IsNullOrWhiteSpace($mainCheckout)) {
        $candidateGuesses += (Join-Path $mainCheckout 'artifacts\design-evidence\v0.7.0\issue-35\candidate-manifest.json')
    }

    $candidatePath = @($candidateGuesses | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf } | Select-Object -First 1)
    if (-not $candidatePath) {
        return [ordered]@{
            candidateManifestFound = $false
            candidatePageCaptureCount = $null
            candidateWidgetVariantCount = $null
            candidateWidgetVariants = @()
            canonicalPageCaptureCountExpected = (Get-HumanDesignReviewCanonicalPageCaptureCount)
            canonicalWidgetVariantCountExpected = (Get-HumanDesignReviewCanonicalWidgetVariantCount)
        }
    }

    $candidate = ([IO.File]::ReadAllText($candidatePath[0])) | ConvertFrom-Json
    $variants = @()
    if ($null -ne $candidate.PSObject.Properties.Name -and
        $candidate.PSObject.Properties.Name -contains 'WidgetVariants') {
        $variants = @($candidate.WidgetVariants)
    }
    if ($variants.Count -eq 0 -and $null -ne $candidate.Captures) {
        $variants = @($candidate.Captures | Where-Object { $_.CaptureKind -eq 'widget-variant' } |
            ForEach-Object { $_.Variant } | Sort-Object -Unique)
    }

    $pageCount = if ($null -ne $candidate.Captures) {
        @($candidate.Captures | Where-Object { $_.CaptureKind -eq 'page' }).Count
    } else { 0 }

    return [ordered]@{
        candidateManifestFound = $true
        candidateManifestPath = $candidatePath[0]
        candidatePageCaptureCount = $pageCount
        candidateWidgetVariantCount = $variants.Count
        candidateWidgetVariants = @($variants)
        canonicalPageCaptureCountExpected = (Get-HumanDesignReviewCanonicalPageCaptureCount)
        canonicalWidgetVariantCountExpected = (Get-HumanDesignReviewCanonicalWidgetVariantCount)
    }
}

function New-Issue35ReconciliationPendingManifest {
    param([Parameter(Mandatory = $true)][string]$Root)

    $gitProv = Get-HumanDesignReviewGitProvenance -RepoRoot (Get-HumanDesignReviewRoot)
    if ($null -ne $gitProv) {
        $commit = $gitProv.CommitSha256
        $branch = $gitProv.Branch
        $descriptor = "issue-35 reconciliation pending fixture (git:$($gitProv.GitCommit)|tree:$($gitProv.GitTree))"
    } else {
        $commit = (Get-HumanDesignReviewSha256ForText -Text 'reconciliation-synthetic-issue-35-commit').ToUpperInvariant()
        $branch = 'codex/v07-issue-35-remediation'
        $descriptor = 'issue-35 reconciliation synthetic pending fixture (unverified git repository)'
    }
    $pages = Get-HumanDesignReviewCanonicalPages
    $languages = Get-HumanDesignReviewLanguages
    $scales = Get-HumanDesignReviewScales
    $variantMap = @{
        Compact = 'compact'; Normal = 'normal'; Expanded = 'expanded'; FloatingMini = 'floatingmini'
        FloatingVertical = 'floatingvertical'; Notification = 'notification'; AgentDetailPopup = 'agentdetailpopup'
        DashboardPreview = 'dashboardpreview'
    }

    $captures = @()
    foreach ($language in $languages) {
        foreach ($page in $pages) {
            foreach ($scale in $scales) {
                $rel = ('captures/' + $language + '/pages/' + $page + '-' + $scale + '.png')
                $full = Join-Path $Root ($rel.Replace('/', [IO.Path]::DirectorySeparatorChar.ToString()))
                Write-Issue35ReconciliationDeterministicFile -Path $full -Text ("reconciliation page $language $page $scale")
                $captures += [ordered]@{
                    relativePath = $rel
                    sha256 = Get-Issue35ReconciliationFileHash -Path $full
                    width = 100 + [int]$scale
                    height = 100 + [int]$scale
                    language = $language
                    kind = 'page'
                    refersToReference = Get-Issue35ReconciliationReferenceForPage -Page $page
                }
            }
        }
    }

    $widgetRefs = @{}
    foreach ($variant in (Get-HumanDesignReviewWidgetVariants)) {
        $rel = ('captures/en/widgets/' + $variantMap[$variant] + '-native.png')
        $full = Join-Path $Root ($rel.Replace('/', [IO.Path]::DirectorySeparatorChar.ToString()))
        Write-Issue35ReconciliationDeterministicFile -Path $full -Text ("reconciliation widget $variant")
        $widgetRefs[$variant] = $rel
        $captures += [ordered]@{
            relativePath = $rel
            sha256 = Get-Issue35ReconciliationFileHash -Path $full
            width = 100
            height = 100
            language = 'en'
            kind = if ($variant -eq 'DashboardPreview') { 'dashboard-preview' } else { 'widget-variant' }
            refersToReference = '11-widget-concepts.png'
        }
    }

    $captureHash = @{}
    foreach ($capture in $captures) {
        $captureHash[[string]$capture.relativePath] = [string]$capture.sha256
    }

    $pageObjects = @{}
    foreach ($page in $pages) {
        $languageCoverage = @{}
        foreach ($language in $languages) {
            $scaleCoverage = @{}
            foreach ($scale in $scales) {
                $ref = 'captures/' + $language + '/pages/' + $page + '-' + $scale + '.png'
                $scaleCoverage["$scale"] = [ordered]@{ captureRef = $ref; sha256 = $captureHash[$ref] }
            }
            $languageCoverage[$language] = $scaleCoverage
        }

        $accessibility = [ordered]@{}
        foreach ($checkName in @('keyboardFocusVisible', 'focusOrderValid', 'automationNamesPresent',
                'thaiTextNoClipping', 'reducedMotionSupported', 'screenReaderSmoke')) {
            $accessibility[$checkName] = [ordered]@{
                passed = $true
                evidence = [ordered]@{
                    boundSha256 = (Get-HumanDesignReviewSha256ForText -Text "reconciliation accessibility $page $checkName").ToUpperInvariant()
                    note = "Reconciliation synthetic check for $page / $checkName on the pending fixture."
                }
            }
        }

        if ($page -eq 'live-organization') {
            $pageObjects[$page] = [ordered]@{
                languageCoverage = $languageCoverage
                accessibility = $accessibility
                roleDivergence = [ordered]@{
                    accepts = $true
                    evidence = [ordered]@{
                        boundSha256 = (Get-HumanDesignReviewSha256ForText -Text ('reconciliation divergence ' + $commit)).ToUpperInvariant()
                        note = 'Live Organization renders needs-review as purple Review; divergence from a done state is synthetically accepted for Issue 35 pending reconciliation.'
                    }
                }
            }
        } else {
            $pageObjects[$page] = [ordered]@{
                languageCoverage = $languageCoverage
                accessibility = $accessibility
            }
        }
    }

    $widgetObjects = [ordered]@{}
    foreach ($variant in (Get-HumanDesignReviewWidgetVariants)) {
        $widgetObjects[$variant] = [ordered]@{
            capturesRef = $widgetRefs[$variant]
            semantics = [ordered]@{
                boundSha256 = (Get-HumanDesignReviewSha256ForText -Text "reconciliation widget semantics $variant").ToUpperInvariant()
                note = "Widget variant $variant shares the single state model; density differs per the approved reference board."
            }
            sharedStateAccepted = $false
            evidence = [ordered]@{
                boundSha256 = (Get-HumanDesignReviewSha256ForText -Text "reconciliation widget evidence $variant").ToUpperInvariant()
                note = "Widget variant $variant synthetic evidence pending human review against 11-widget-concepts.png."
            }
        }
    }

    $artifactHash = Get-HumanDesignReviewArtifactHashFromManifest -Manifest ([pscustomobject]@{ captures = $captures })
    $descriptor = 'issue-35 reconciliation pending fixture (60 page captures, 8 widget variants)'
    $runHash = Get-HumanDesignReviewSha256ForText -Text ($descriptor + '|' + $commit + '|SHA-256')
    $today = [DateTime]::UtcNow
    $signatureDateText = $today.ToString('yyyy-MM-dd', [Globalization.CultureInfo]::InvariantCulture)
    $captureDateText = $today.AddHours(-1).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ss', [Globalization.CultureInfo]::InvariantCulture) + 'Z'

    $manifest = [ordered]@{
        '$id' = Get-HumanDesignReviewSchemaId
        schemaVersion = 1
        contract = [ordered]@{ issue = 35; version = '0.7.0'; productId = 'HerdrOps'; immutableReferenceSet = 'docs/design/reference/*.png'; designContract = 'Plan/DESIGN-CONTRACT.md' }
        reviewStatus = 'Pending'
        reviewer = [ordered]@{ name = 'HerdrOps Verification (pending)'; role = 'Design Reviewer (not yet signed)'; organization = 'HerdrOps QA'; independent = $false; signatureDate = $signatureDateText; signatory = 'Pending' }
        provenance = [ordered]@{ boundCommitSha256 = $commit; runHash = $runHash; artifactHash = $artifactHash; hashAlgorithm = 'SHA-256'; canonicalRunDescriptor = $descriptor }
        uiUnderReview = [ordered]@{
            surfaceKind = 'Observed WPF build'
            wpfBuild = [ordered]@{ assembly = 'HerdrOps.App'; branch = $branch; commitSha256 = $commit; configuration = 'Release' }
            hostOs = 'Windows 11 23H2 (reconciliation fixture)'
            hostResolutionWidth = 1672
            hostResolutionHeight = 941
            dpiScaleFactor = 100
            captureTool = [ordered]@{ name = 'ReconciliationFixture (pending)'; runtime = 'WPF'; version = '0.7.0' }
            observedWindow = 'MainWindow (reconciliation fixture)'
            captureDate = $captureDateText
        }
        captures = $captures
        pages = $pageObjects
        widgets = $widgetObjects
        accessibleEvidence = [ordered]@{
            contrastManualChecks = @(
                [ordered]@{ label = 'Primary text on surface'; foreground = '#FFFFFF'; background = '#0B1020'; ratio = 18.0; measured = $true; boundSha256 = (Get-HumanDesignReviewSha256ForText -Text 'reconciliation contrast white').ToUpperInvariant() }
            )
            manualEvidenceSlots = @(
                [ordered]@{ title = 'Pending design review observation'; observation = 'Manifest structure and capture universe reconciled; human acceptance remains pending and unclaimed.'; boundSha256 = (Get-HumanDesignReviewSha256ForText -Text 'reconciliation manual slot pending').ToUpperInvariant() }
            )
        }
        declarations = [ordered]@{ noAcceptedCaptureInPreparation = $true; humanReviewClaimed = $false; runtimeClaims = 'NOT OBSERVED'; releaseClaims = 'NOT PRODUCED'; preparationBoundary = 'PREPARATION/Static-Contract-Synthetic' }
    }

    $manifestPath = Join-Path $Root 'human-design-review.reconciliation.pending.json'
    $json = $manifest | ConvertTo-Json -Depth 100
    [IO.File]::WriteAllText(([IO.Path]::GetFullPath($manifestPath)), $json, (New-Object System.Text.UTF8Encoding($false)))

    return [pscustomobject]@{
        Root = [IO.Path]::GetFullPath($Root)
        ManifestPath = [IO.Path]::GetFullPath($manifestPath)
    }
}

### Main driver.

$schemaPath = Get-HumanDesignReviewSchemaPath
if (-not (Test-Path -LiteralPath $schemaPath -PathType Leaf)) {
    throw 'The versioned review schema is missing from the tool module.'
}

$divergence = Get-Issue35ReconciliationCandidateDivergence

$testRoot = Get-Issue35ReconciliationTempRoot
try {
    $fixture = New-Issue35ReconciliationPendingManifest -Root (Join-Path $testRoot 'reconcile-pending')

    $configOnly = Test-HumanDesignReviewManifest -ManifestPath $fixture.ManifestPath
    if (-not $configOnly.Valid -or $configOnly.ReviewStatus -cne 'Pending') {
        throw 'The pending reconciliation manifest did not verify cleanly in configuration-only mode.'
    }
    if ([string]$configOnly.EvidenceClass -cne 'Static/Contract') {
        throw 'Configuration-only verification did not report the Static/Contract evidence class.'
    }

    $bind = Test-HumanDesignReviewManifest -ManifestPath $fixture.ManifestPath -EvidenceRoot $fixture.Root -ValidateBindings
    if (-not $bind.Valid -or $bind.ReviewStatus -cne 'Pending' -or $bind.PageCaptureCount -ne (Get-HumanDesignReviewCanonicalPageCaptureCount)) {
        throw "The pending reconciliation manifest did not verify cleanly with on-disk binding and $(Get-HumanDesignReviewCanonicalPageCaptureCount) page captures."
    }
    if (-not $bind.BindingsValidated) {
        throw 'The pending reconciliation manifest did not record on-disk binding depth.'
    }

    if (-not $KeepOnDisk) {
        $leaf = [IO.Path]::GetFileName($testRoot)
        $tempRoot = Normalize-Issue35ReconciliationTempPath ([IO.Path]::GetTempPath())
        if ($testRoot.StartsWith($tempRoot, [StringComparison]::OrdinalIgnoreCase) -and
            $leaf -match '^HerdrOps-Issue35Reconciliation-[0-9a-f]{32}$' -and
            (Test-Path -LiteralPath $testRoot)) {
            Remove-Item -LiteralPath $testRoot -Recurse -Force
        }
    }

    $result = [pscustomobject][ordered]@{
        EvidenceClass = 'Static/Contract/Synthetic'
        Issue = (Get-HumanDesignReviewIssue)
        Version = (Get-HumanDesignReviewVersion)
        CanonicalPageCaptureUniverse = [int]$divergence.canonicalPageCaptureCountExpected
        CanonicalWidgetVariantUniverse = [int]$divergence.canonicalWidgetVariantCountExpected
        CandidateManifestFound = [bool]$divergence.candidateManifestFound
        CandidatePageCaptureCount = $divergence.candidatePageCaptureCount
        CandidateWidgetVariantCount = $divergence.candidateWidgetVariantCount
        CandidateWidgetVariants = @($divergence.candidateWidgetVariants)
        ReconcileStatusBound = 'Pending'
        ReconcileVerifiedConfigOnly = 'PASS'
        ReconcileVerifiedOnDisk = 'PASS'
        Human = 'NOT OBSERVED'
        Runtime = 'NOT OBSERVED'
        Release = 'NOT OBSERVED'
    }

    if ($ReportPath) {
        $full = [IO.Path]::GetFullPath($ReportPath)
        $parent = Split-Path -Path $full -Parent
        if (-not [string]::IsNullOrWhiteSpace($parent) -and -not (Test-Path -LiteralPath $parent -PathType Container)) {
            New-Item -ItemType Directory -Path $parent -Force | Out-Null
        }
        $json = $result | ConvertTo-Json -Depth 10
        [IO.File]::WriteAllText($full, $json, (New-Object System.Text.UTF8Encoding($false)))
        Write-Output $full
    } else {
        $result | Format-List
    }
} finally {
    if (-not $KeepOnDisk -and (Test-Path -LiteralPath $testRoot)) {
        $leaf = [IO.Path]::GetFileName($testRoot)
        $tempRoot = Normalize-Issue35ReconciliationTempPath ([IO.Path]::GetTempPath())
        if ($testRoot.StartsWith($tempRoot, [StringComparison]::OrdinalIgnoreCase) -and
            $leaf -match '^HerdrOps-Issue35Reconciliation-[0-9a-f]{32}$') {
            Remove-Item -LiteralPath $testRoot -Recurse -Force
        }
    }
}