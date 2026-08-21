#requires -Version 5.1

[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'HumanDesignReview.Common.ps1')

function Assert-ReviewSelftestFailure {
    param(
        [Parameter(Mandatory = $true)][scriptblock]$Action,
        [Parameter(Mandatory = $true)][string]$Description,
        [Parameter(Mandatory = $true)][string[]]$RequiredFragments
    )

    $message = $null
    try {
        & $Action | Out-Null
    } catch {
        $message = [string]$_.Exception.Message
    }
    if ([string]::IsNullOrWhiteSpace($message)) {
        throw "Human design review fail-closed check unexpectedly succeeded: $Description"
    }
    foreach ($fragment in $RequiredFragments) {
        if ($message.IndexOf($fragment, [StringComparison]::OrdinalIgnoreCase) -lt 0) {
            throw "Fail-closed check '$Description' did not contain required context '$fragment': $message"
        }
    }
}

function Assert-ReviewAnyFailureFragment {
    param(
        [Parameter(Mandatory = $true)][scriptblock]$Action,
        [Parameter(Mandatory = $true)][string]$Description,
        [Parameter(Mandatory = $true)][string[]]$AnyOfFragments
    )

    $message = $null
    try {
        & $Action | Out-Null
    } catch {
        $message = [string]$_.Exception.Message
    }
    if ([string]::IsNullOrWhiteSpace($message)) {
        throw "Human design review fail-closed check unexpectedly succeeded: $Description"
    }
    $matched = @($AnyOfFragments | Where-Object { $message.IndexOf($_, [StringComparison]::OrdinalIgnoreCase) -ge 0 })
    if ($matched.Count -eq 0) {
        throw "Fail-closed check '$Description' matched no guard fragment: $message"
    }
}

function New-ReviewTempDirectory {
    $tempRoot = Normalize-HumanDesignReviewTempPath ([IO.Path]::GetTempPath())
    for ($attempt = 0; $attempt -lt 10; $attempt++) {
        $candidate = Join-Path $tempRoot ('HerdrOps-ReviewTest-' + [Guid]::NewGuid().ToString('N'))
        if (-not (Test-Path -LiteralPath $candidate)) {
            New-Item -ItemType Directory -Path $candidate -Force | Out-Null
            return $candidate
        }
    }
    throw 'Could not create a unique Human design review selftest temp directory.'
}

function Normalize-HumanDesignReviewTempPath {
    param([string]$Path)
    $fullPath = [IO.Path]::GetFullPath($Path)
    if ($fullPath.Length -gt 3) {
        return $fullPath.TrimEnd('\')
    }
    return $fullPath
}

function Remove-ReviewTempDirectory {
    param([Parameter(Mandatory = $true)][string]$Path)

    $fullPath = [IO.Path]::GetFullPath($Path)
    $tempRoot = Normalize-HumanDesignReviewTempPath ([IO.Path]::GetTempPath())
    $leaf = [IO.Path]::GetFileName($fullPath)
    if (-not $fullPath.StartsWith($tempRoot, [StringComparison]::OrdinalIgnoreCase) -or
        $leaf -notmatch '^HerdrOps-ReviewTest-[0-9a-f]{32}$') {
        throw "Refusing to remove a non-owned selftest temp directory: $fullPath"
    }
    if (Test-Path -LiteralPath $fullPath) {
        Remove-Item -LiteralPath $fullPath -Recurse -Force
    }
}

function Write-ReviewDeterministicFile {
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

function Get-ReviewFileHash {
    param([Parameter(Mandatory = $true)][string]$Path)
    $bytes = [IO.File]::ReadAllBytes([IO.Path]::GetFullPath($Path))
    return (Get-HumanDesignReviewSha256ForBytes -Bytes $bytes).ToUpperInvariant()
}

### Builds a deterministic fixture evidence root with all required page and widget
### captures, plus a fully-valid bound manifest, and writes both. Returns metadata.

function New-FullReviewFixture {
    param([Parameter(Mandatory = $true)][string]$Root)

    $commit = (Get-HumanDesignReviewSha256ForText -Text 'fixture-commit-issue-35').ToUpperInvariant()
    $pages = Get-HumanDesignReviewCanonicalPages
    $languages = Get-HumanDesignReviewLanguages
    $scales = Get-HumanDesignReviewScales

    $captures = @()
    foreach ($language in $languages) {
        foreach ($page in $pages) {
            foreach ($scale in $scales) {
                $rel = ('captures/' + $language + '/pages/' + $page + '-' + $scale + '.png')
                $full = Join-Path $Root ($rel.Replace('/', [IO.Path]::DirectorySeparatorChar.ToString()))
                Write-ReviewDeterministicFile -Path $full -Text ("fixture page $language $page $scale")
                $captures += [ordered]@{
                    relativePath = $rel
                    sha256 = Get-ReviewFileHash -Path $full
                    width = 100 + [int]$scale
                    height = 100 + [int]$scale
                    language = $language
                    kind = 'page'
                    refersToReference = if ($page -eq 'overview') { '01-overview.png' } else { '02-live-organization.png' }
                }
            }
        }
    }

    $variantMap = @{
        Compact = 'compact'; Normal = 'normal'; Expanded = 'expanded'; FloatingMini = 'floatingmini'
        FloatingVertical = 'floatingvertical'; Notification = 'notification'; AgentDetailPopup = 'agentdetailpopup'
        DashboardPreview = 'dashboardpreview'
    }
    $widgetRefs = @{}
    foreach ($variant in (Get-HumanDesignReviewWidgetVariants)) {
        $rel = ('captures/en/widgets/' + $variantMap[$variant] + '-native.png')
        $full = Join-Path $Root ($rel.Replace('/', [IO.Path]::DirectorySeparatorChar.ToString()))
        Write-ReviewDeterministicFile -Path $full -Text ("fixture widget $variant")
        $widgetRefs[$variant] = $rel
        $captures += [ordered]@{
            relativePath = $rel
            sha256 = Get-ReviewFileHash -Path $full
            width = 100
            height = 100
            language = 'en'
            kind = if ($variant -eq 'DashboardPreview') { 'dashboard-preview' } else { 'widget-variant' }
            refersToReference = '11-widget-concepts.png'
        }
    }

    $contactRel = 'captures/en/contact-sheets/overview-sheet.png'
    $contactFull = Join-Path $Root ($contactRel.Replace('/', [IO.Path]::DirectorySeparatorChar.ToString()))
    Write-ReviewDeterministicFile -Path $contactFull -Text 'fixture contact sheet'
    $captures += [ordered]@{
        relativePath = $contactRel
        sha256 = Get-ReviewFileHash -Path $contactFull
        width = 1672
        height = 941
        language = 'en'
        kind = 'contact-sheet'
        refersToReference = '01-overview.png'
    }

    $capturePathToHash = @{}
    foreach ($capture in $captures) {
        $capturePathToHash[[string]$capture.relativePath] = [string]$capture.sha256
    }

    $pageObjects = @{}
    foreach ($page in $pages) {
        $languageCoverage = @{}
        foreach ($language in $languages) {
            $scaleCoverage = @{}
            foreach ($scale in $scales) {
                $ref = 'captures/' + $language + '/pages/' + $page + '-' + $scale + '.png'
                $scaleCoverage["$scale"] = [ordered]@{ captureRef = $ref; sha256 = $capturePathToHash[$ref] }
            }
            $languageCoverage[$language] = $scaleCoverage
        }

        $accessibility = [ordered]@{}
        foreach ($checkName in @('keyboardFocusVisible', 'focusOrderValid', 'automationNamesPresent',
                'thaiTextNoClipping', 'reducedMotionSupported', 'screenReaderSmoke')) {
            $accessibility[$checkName] = [ordered]@{
                passed = $true
                evidence = [ordered]@{
                    boundSha256 = (Get-HumanDesignReviewSha256ForText -Text "fixture accessibility $page $checkName").ToUpperInvariant()
                    note = "Manual $(Get-HumanDesignReviewVersion) accessibility check observed on the fixture build for $page / $checkName."
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
                        boundSha256 = (Get-HumanDesignReviewSha256ForText -Text ('fixture live-org divergence ' + $commit)).ToUpperInvariant()
                        note = "Live Organization renders needs-review as purple Review and vacant/conflict as red Blocked; divergence from a naive done state is explicitly accepted for Issue $(Get-HumanDesignReviewIssue)."
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
                boundSha256 = (Get-HumanDesignReviewSha256ForText -Text "fixture widget semantics $variant").ToUpperInvariant()
                note = "Widget variant $variant shares the single state model and status semantics; density differs from Compact to Expanded per the approved reference board."
            }
            sharedStateAccepted = $true
            evidence = [ordered]@{
                boundSha256 = (Get-HumanDesignReviewSha256ForText -Text "fixture widget evidence $variant").ToUpperInvariant()
                note = "Widget variant $variant semantics reviewed against 11-widget-concepts.png on the observed WPF build."
            }
        }
    }

    $artifactHash = Get-HumanDesignReviewArtifactHashFromManifest -Manifest ([pscustomobject]@{ captures = $captures })
    $descriptor = 'v0.7.0 issue-35 independent review verification run'
    $runHash = Get-HumanDesignReviewSha256ForText -Text ($descriptor + '|' + $commit + '|SHA-256')
    $today = [DateTime]::UtcNow
    $signatureDateText = $today.ToString('yyyy-MM-dd', [Globalization.CultureInfo]::InvariantCulture)
    $captureDateText = $today.AddHours(-1).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ss', [Globalization.CultureInfo]::InvariantCulture) + 'Z'

    $manifest = [ordered]@{
        '$id' = Get-HumanDesignReviewSchemaId
        schemaVersion = 1
        contract = [ordered]@{ issue = 35; version = '0.7.0'; productId = 'HerdrOps'; immutableReferenceSet = 'docs/design/reference/*.png'; designContract = 'Plan/DESIGN-CONTRACT.md' }
        reviewStatus = 'Accepted'
        reviewer = [ordered]@{ name = 'Fixture Reviewer'; role = 'Independent Design Reviewer'; organization = 'HerdrOps QA'; independent = $true; signatureDate = $signatureDateText; signatory = 'Fixture Reviewer Signature' }
        provenance = [ordered]@{ boundCommitSha256 = $commit; runHash = $runHash; artifactHash = $artifactHash; hashAlgorithm = 'SHA-256'; canonicalRunDescriptor = $descriptor }
        uiUnderReview = [ordered]@{
            surfaceKind = 'Observed WPF build'
            wpfBuild = [ordered]@{ assembly = 'HerdrOps.App'; branch = 'codex/v07-issue-35-design-parity'; commitSha256 = $commit; configuration = 'Release' }
            hostOs = 'Windows 11 23H2 (fixture)'
            hostResolutionWidth = 1672
            hostResolutionHeight = 941
            dpiScaleFactor = 100
            captureTool = [ordered]@{ name = 'WpfTestHost (fixture)'; runtime = 'WPF'; version = '0.7.0' }
            observedWindow = 'MainWindow (fixture)'
            captureDate = $captureDateText
        }
        captures = $captures
        pages = $pageObjects
        widgets = $widgetObjects
        accessibleEvidence = [ordered]@{
            contrastManualChecks = @(
                [ordered]@{ label = 'Primary text on surface'; foreground = '#FFFFFF'; background = '#0B1020'; ratio = 18.0; measured = $true; boundSha256 = (Get-HumanDesignReviewSha256ForText -Text 'fixture contrast white').ToUpperInvariant() }
            )
            manualEvidenceSlots = @(
                [ordered]@{ title = 'Keyboard focus observation'; observation = 'Visible focus ring confirmed across all ten pages and every widget variant on the observed WPF build.'; boundSha256 = (Get-HumanDesignReviewSha256ForText -Text 'fixture manual slot focus').ToUpperInvariant() }
            )
        }
        declarations = [ordered]@{ noAcceptedCaptureInPreparation = $true; humanReviewClaimed = $true; runtimeClaims = 'NOT OBSERVED'; releaseClaims = 'NOT PRODUCED'; preparationBoundary = 'PREPARATION/Static-Contract-Synthetic' }
    }

    $manifestPath = Join-Path $Root 'human-design-review.manifest.json'
    $json = $manifest | ConvertTo-Json -Depth 100
    [IO.File]::WriteAllText(([IO.Path]::GetFullPath($manifestPath)), $json, (New-Object System.Text.UTF8Encoding($false)))

    return [pscustomobject]@{
        Root = [IO.Path]::GetFullPath($Root)
        ManifestPath = [IO.Path]::GetFullPath($manifestPath)
        Commit = $commit
    }
}

### Test driver.

$testRoot = New-ReviewTempDirectory
try {
    $templatePath = Get-HumanDesignReviewTemplatePath
    if (-not (Test-Path -LiteralPath $templatePath -PathType Leaf)) {
        throw 'The fail-closed manifest template is missing from the tool module.'
    }
    if (-not (Test-Path -LiteralPath (Get-HumanDesignReviewSchemaPath) -PathType Leaf)) {
        throw 'The versioned manifest schema is missing from the tool module.'
    }

    # Template MUST fail-closed because its required hashes are unbound zero hashes and
    # its coverage is incomplete; a template is a starting point, not an accepted manifest.
    Assert-ReviewAnyFailureFragment -Description 'distribution template is fail-closed (unbound/forged/placeholder content)' -AnyOfFragments @(
        'unbound', 'placeholder', 'forged', 'missing', 'malformed') -Action {
        Test-HumanDesignReviewManifest -ManifestPath $templatePath | Out-Null
    }

    # A valid, fully-bound fixture manifests verifies cleanly (positive control).
    $fixture = New-FullReviewFixture -Root (Join-Path $testRoot 'fixture-valid')
    $positive = Test-HumanDesignReviewManifest -ManifestPath $fixture.ManifestPath `
        -EvidenceRoot $fixture.Root -ValidateBindings
    if (-not $positive.Valid -or $positive.ReviewStatus -cne 'Accepted') {
        throw 'The fully bound fixture manifest did not verify cleanly.'
    }
    if ($positive.BindingsValidated -cne $true -or $positive.PageCaptureCount -ne (Get-HumanDesignReviewCanonicalPageCaptureCount)) {
        throw 'The fully bound fixture verification did not record the expected binding depth and page coverage.'
    }

    # On-disk binding: a capture that is present in the fixture root is validated.
    $positiveConfigOnly = Test-HumanDesignReviewManifest -ManifestPath $fixture.ManifestPath
    if (-not $positiveConfigOnly.Valid -or $positiveConfigOnly.EvidenceClass -cne 'Static/Contract') {
        throw 'Configuration-only verification did not report Static/Contract evidence class.'
    }

    # Rotate one fixture capture's bytes; on-disk binding must fail-closed.
    $pageProbeRel = 'captures/en/pages/overview-100.png'
    $pageProbeFull = Join-Path $fixture.Root ($pageProbeRel.Replace('/', [IO.Path]::DirectorySeparatorChar.ToString()))
    $pageProbeOriginal = [byte[]][IO.File]::ReadAllBytes($pageProbeFull)
    try {
        [IO.File]::WriteAllBytes($pageProbeFull, (New-Object System.Text.UTF8Encoding($false)).GetBytes('tampered capture bytes'))
        Assert-ReviewSelftestFailure -Description 'rotated capture fails on-disk binding' -RequiredFragments @(
            'on-disk SHA-256 does not match') -Action {
            Test-HumanDesignReviewManifest -ManifestPath $fixture.ManifestPath -EvidenceRoot $fixture.Root -ValidateBindings | Out-Null
        }
    } finally {
        [IO.File]::WriteAllBytes($pageProbeFull, $pageProbeOriginal)
    }

    # Rotate contact sheet capture bytes; on-disk binding must fail-closed.
    $contactProbeRel = 'captures/en/contact-sheets/overview-sheet.png'
    $contactProbeFull = Join-Path $fixture.Root ($contactProbeRel.Replace('/', [IO.Path]::DirectorySeparatorChar.ToString()))
    $contactProbeOriginal = [byte[]][IO.File]::ReadAllBytes($contactProbeFull)
    try {
        [IO.File]::WriteAllBytes($contactProbeFull, (New-Object System.Text.UTF8Encoding($false)).GetBytes('tampered contact sheet bytes'))
        Assert-ReviewSelftestFailure -Description 'rotated contact sheet capture fails on-disk binding' -RequiredFragments @(
            'on-disk SHA-256 does not match') -Action {
            Test-HumanDesignReviewManifest -ManifestPath $fixture.ManifestPath -EvidenceRoot $fixture.Root -ValidateBindings | Out-Null
        }
    } finally {
        [IO.File]::WriteAllBytes($contactProbeFull, $contactProbeOriginal)
    }

    # Negative: MISSING required capture (remove a page coverage reference from captures[]).
    $missingFolder = Join-Path $testRoot 'mis-missing-capture'
    Copy-Item -LiteralPath $fixture.Root -Destination $missingFolder -Recurse
    $missingPath = Join-Path $missingFolder 'human-design-review.manifest.json'
    $missingManifestText = [IO.File]::ReadAllText($missingPath)
    $missingManifest = $missingManifestText | ConvertFrom-Json
    $missingProbeRef = 'captures/en/pages/overview-125.png'
    $missingManifest.captures = @($missingManifest.captures | Where-Object { $_.relativePath -cne $missingProbeRef })
    $missingLanguages = $missingManifest.pages.overview.languageCoverage
    $missingLanguages.en.'125' = $null
    $missingJson = $missingManifest | ConvertTo-Json -Depth 100
    [IO.File]::WriteAllText($missingPath, $missingJson, (New-Object System.Text.UTF8Encoding($false)))
    Assert-ReviewSelftestFailure -Description 'missing required page capture is rejected' -RequiredFragments @(
        'missing required page capture') -Action {
        Test-HumanDesignReviewManifest -ManifestPath $missingPath | Out-Null
    }

    # Negative: DUPLICATE capture reference.
    $duplicateFolder = Join-Path $testRoot 'neg-duplicate-capture'
    Copy-Item -LiteralPath $fixture.Root -Destination $duplicateFolder -Recurse
    $duplicatePath = Join-Path $duplicateFolder 'human-design-review.manifest.json'
    $duplicateManifest = ([IO.File]::ReadAllText($duplicatePath)) | ConvertFrom-Json
    $dupRef = 'captures/en/pages/overview-150.png'
    $dupEntry = @($duplicateManifest.captures | Where-Object { $_.relativePath -ceq $dupRef })[0]
    $duplicateManifest.captures += $dupEntry
    $duplicateManifest.provenance.artifactHash = (Get-HumanDesignReviewArtifactHashFromManifest -Manifest $duplicateManifest).ToUpperInvariant()
    $duplicateJson = $duplicateManifest | ConvertTo-Json -Depth 100
    [IO.File]::WriteAllText($duplicatePath, $duplicateJson, (New-Object System.Text.UTF8Encoding($false)))
    Assert-ReviewSelftestFailure -Description 'duplicate capture reference is rejected' -RequiredFragments @(
        'duplicate capture') -Action {
        Test-HumanDesignReviewManifest -ManifestPath $duplicatePath | Out-Null
    }

    # Negative: UNEXPECTED capture reference (non-canonical page/scale path).
    $unexpectedFolder = Join-Path $testRoot 'neg-unexpected-capture'
    Copy-Item -LiteralPath $fixture.Root -Destination $unexpectedFolder -Recurse
    $unexpectedPath = Join-Path $unexpectedFolder 'human-design-review.manifest.json'
    $unexpectedManifest = ([IO.File]::ReadAllText($unexpectedPath)) | ConvertFrom-Json
    $unexpectedManifest.captures += [ordered]@{
        relativePath = 'captures/en/pages/not-a-page-200.png'
        sha256 = (Get-HumanDesignReviewSha256ForText -Text 'unexpected capture').ToUpperInvariant()
        width = 100; height = 100; language = 'en'; kind = 'page'; refersToReference = '05-agent-detail.png'
    }
    $unexpectedManifest.provenance.artifactHash = (Get-HumanDesignReviewArtifactHashFromManifest -Manifest $unexpectedManifest).ToUpperInvariant()
    $unexpectedJson = $unexpectedManifest | ConvertTo-Json -Depth 100
    [IO.File]::WriteAllText($unexpectedPath, $unexpectedJson, (New-Object System.Text.UTF8Encoding($false)))
    Assert-ReviewSelftestFailure -Description 'unexpected capture reference is rejected' -RequiredFragments @(
        'unexpected capture') -Action {
        Test-HumanDesignReviewManifest -ManifestPath $unexpectedPath | Out-Null
    }

    # Negative: F1 EXACT-SET CARDINALITY — an extra shape-valid but non-canonical page
    # capture (canonical-looking path, unknown page) must fail closed, not slip through
    # the shape regex as the original design allowed.
    $extraPageFolder = Join-Path $testRoot 'neg-extra-noncanonical-page'
    Copy-Item -LiteralPath $fixture.Root -Destination $extraPageFolder -Recurse
    $extraPagePath = Join-Path $extraPageFolder 'human-design-review.manifest.json'
    $extraPageManifest = ([IO.File]::ReadAllText($extraPagePath)) | ConvertFrom-Json
    $extraPageManifest.captures += [ordered]@{
        relativePath = 'captures/en/pages/foobar-100.png'
        sha256 = (Get-HumanDesignReviewSha256ForText -Text 'extra non canonical page').ToUpperInvariant()
        width = 100; height = 100; language = 'en'; kind = 'page'; refersToReference = '02-live-organization.png'
    }
    $extraPageManifest.provenance.artifactHash = (Get-HumanDesignReviewArtifactHashFromManifest -Manifest $extraPageManifest).ToUpperInvariant()
    $extraPageJson = $extraPageManifest | ConvertTo-Json -Depth 100
    [IO.File]::WriteAllText($extraPagePath, $extraPageJson, (New-Object System.Text.UTF8Encoding($false)))
    Assert-ReviewSelftestFailure -Description 'extra non-canonical page capture violates exact capture set cardinality' -RequiredFragments @(
        'exact canonical 60') -Action {
        Test-HumanDesignReviewManifest -ManifestPath $extraPagePath | Out-Null
    }

    # Negative: F1 EXACT-SET CARDINALITY — an extra widget-kind capture beyond the
    # declared widget variant set must fail closed.
    $extraWidgetFolder = Join-Path $testRoot 'neg-extra-widget-cardinality'
    Copy-Item -LiteralPath $fixture.Root -Destination $extraWidgetFolder -Recurse
    $extraWidgetPath = Join-Path $extraWidgetFolder 'human-design-review.manifest.json'
    $extraWidgetManifest = ([IO.File]::ReadAllText($extraWidgetPath)) | ConvertFrom-Json
    $extraWidgetManifest.captures += [ordered]@{
        relativePath = 'captures/th/widgets/compact-native.png'
        sha256 = (Get-HumanDesignReviewSha256ForText -Text 'extra widget th variant').ToUpperInvariant()
        width = 100; height = 100; language = 'th'; kind = 'widget-variant'; refersToReference = '11-widget-concepts.png'
    }
    $extraWidgetManifest.provenance.artifactHash = (Get-HumanDesignReviewArtifactHashFromManifest -Manifest $extraWidgetManifest).ToUpperInvariant()
    $extraWidgetJson = $extraWidgetManifest | ConvertTo-Json -Depth 100
    [IO.File]::WriteAllText($extraWidgetPath, $extraWidgetJson, (New-Object System.Text.UTF8Encoding($false)))
    Assert-ReviewSelftestFailure -Description 'extra widget capture violates exact widget cardinality' -RequiredFragments @(
        'widget capture cardinality') -Action {
        Test-HumanDesignReviewManifest -ManifestPath $extraWidgetPath | Out-Null
    }

    # Negative: F2 MANIFEST BINDING — a capture referring to a non-MANIFEST.md entry
    # must fail closed even though the refersToReference field is well-formed.
    $forgedRefFolder = Join-Path $testRoot 'neg-forged-reference-entry'
    Copy-Item -LiteralPath $fixture.Root -Destination $forgedRefFolder -Recurse
    $forgedRefPath = Join-Path $forgedRefFolder 'human-design-review.manifest.json'
    $forgedRefManifest = ([IO.File]::ReadAllText($forgedRefPath)) | ConvertFrom-Json
    $forgedRefManifest.captures[0].refersToReference = '99-bogus.png'
    $forgedRefJson = $forgedRefManifest | ConvertTo-Json -Depth 100
    [IO.File]::WriteAllText($forgedRefPath, $forgedRefJson, (New-Object System.Text.UTF8Encoding($false)))
    Assert-ReviewSelftestFailure -Description 'forged non-MANIFEST refersToReference is rejected' -RequiredFragments @(
        'not a valid docs/design/reference/MANIFEST') -Action {
        Test-HumanDesignReviewManifest -ManifestPath $forgedRefPath | Out-Null
    }

    # Negative: FORGED checkbox-only signoff (passed=true with an unbound zero hash).
    $forgedFolder = Join-Path $testRoot 'neg-forged-checkbox'
    Copy-Item -LiteralPath $fixture.Root -Destination $forgedFolder -Recurse
    $forgedPath = Join-Path $forgedFolder 'human-design-review.manifest.json'
    $forgedManifest = ([IO.File]::ReadAllText($forgedPath)) | ConvertFrom-Json
    $forgedManifest.pages.overview.accessibility.keyboardFocusVisible.passed = $true
    $forgedManifest.pages.overview.accessibility.keyboardFocusVisible.evidence.boundSha256 = (Get-HumanDesignReviewZeroHash)
    $forgedJson = $forgedManifest | ConvertTo-Json -Depth 100
    [IO.File]::WriteAllText($forgedPath, $forgedJson, (New-Object System.Text.UTF8Encoding($false)))
    Assert-ReviewAnyFailureFragment -Description 'forged checkbox-only accessibility signoff is rejected' -AnyOfFragments @(
        'checkbox-only signoff', 'unbound or forged boundary hash') -Action {
        Test-HumanDesignReviewManifest -ManifestPath $forgedPath | Out-Null
    }

    # Negative: checkbox-only live-organization divergence is rejected.
    $forgedDivergenceFolder = Join-Path $testRoot 'neg-forged-divergence'
    Copy-Item -LiteralPath $fixture.Root -Destination $forgedDivergenceFolder -Recurse
    $forgedDivergencePath = Join-Path $forgedDivergenceFolder 'human-design-review.manifest.json'
    $forgedDivergenceManifest = ([IO.File]::ReadAllText($forgedDivergencePath)) | ConvertFrom-Json
    $forgedDivergenceManifest.pages.'live-organization'.roleDivergence.evidence.boundSha256 = (Get-HumanDesignReviewZeroHash)
    $forgedDivergenceJson = $forgedDivergenceManifest | ConvertTo-Json -Depth 100
    [IO.File]::WriteAllText($forgedDivergencePath, $forgedDivergenceJson, (New-Object System.Text.UTF8Encoding($false)))
    Assert-ReviewSelftestFailure -Description 'forged live-organization divergence signoff is rejected' -RequiredFragments @(
        'unbound or forged boundary hash') -Action {
        Test-HumanDesignReviewManifest -ManifestPath $forgedDivergencePath | Out-Null
    }

    # Negative: runHash and artifactHash self-consistency must catch tampering.
    foreach ($hashProbe in @(
            @{ Name = 'runHash tamper'; Field = 'runHash'; Value = (Get-HumanDesignReviewSha256ForText -Text 'wrong').ToUpperInvariant() },
            @{ Name = 'artifactHash tamper'; Field = 'artifactHash'; Value = (Get-HumanDesignReviewSha256ForText -Text 'wrong').ToUpperInvariant() },
            @{ Name = 'boundCommit tamper'; Field = 'boundCommitSha256'; Value = (Get-HumanDesignReviewSha256ForText -Text 'wrong').ToUpperInvariant() })) {
        $tamperFolder = Join-Path $testRoot ('neg-' + $hashProbe.Name.Replace(' ', '-'))
        Copy-Item -LiteralPath $fixture.Root -Destination $tamperFolder -Recurse
        $tamperPath = Join-Path $tamperFolder 'human-design-review.manifest.json'
        $tamperManifest = ([IO.File]::ReadAllText($tamperPath)) | ConvertFrom-Json
        $tamperManifest.provenance.($hashProbe.Field) = $hashProbe.Value
        $tamperJson = $tamperManifest | ConvertTo-Json -Depth 100
        [IO.File]::WriteAllText($tamperPath, $tamperJson, (New-Object System.Text.UTF8Encoding($false)))
        Assert-ReviewSelftestFailure -Description $hashProbe.Name -RequiredFragments @('does not match') -Action {
            Test-HumanDesignReviewManifest -ManifestPath $tamperPath | Out-Null
        }
    }

    # Negative: future capture date is falsified evidence.
    $futureFolder = Join-Path $testRoot 'neg-future-date'
    Copy-Item -LiteralPath $fixture.Root -Destination $futureFolder -Recurse
    $futurePath = Join-Path $futureFolder 'human-design-review.manifest.json'
    $futureManifest = ([IO.File]::ReadAllText($futurePath)) | ConvertFrom-Json
    $futureManifest.reviewer.signatureDate = '2031-01-01'
    $futureManifest.uiUnderReview.captureDate = '2031-01-01T00:00:00Z'
    $futureJson = $futureManifest | ConvertTo-Json -Depth 100
    [IO.File]::WriteAllText($futurePath, $futureJson, (New-Object System.Text.UTF8Encoding($false)))
    Assert-ReviewSelftestFailure -Description 'future signoff and capture dates are rejected as falsified' -RequiredFragments @(
        'falsified') -Action {
        Test-HumanDesignReviewManifest -ManifestPath $futurePath | Out-Null
    }

    # Negative: duplicate JSON object property is rejected at parse time.
    $duplicateJsonProbe = Join-Path $testRoot 'neg-duplicate-json-property'
    Write-ReviewDeterministicFile -Path $duplicateJsonProbe -Text '{"a":1,"A":2}'
    Assert-ReviewSelftestFailure -Description 'duplicate JSON property is rejected' -RequiredFragments @(
        'duplicate JSON object property',
        'case-insensitive') -Action {
        ConvertFrom-StrictHumanDesignReviewJson -Json ([IO.File]::ReadAllText($duplicateJsonProbe)) -Description 'duplicate probe' | Out-Null
    }

    # Negative: PATH TRAVERSAL with .. is rejected.
    $traversalFolder = Join-Path $testRoot 'neg-path-traversal-dots'
    Copy-Item -LiteralPath $fixture.Root -Destination $traversalFolder -Recurse
    $traversalPath = Join-Path $traversalFolder 'human-design-review.manifest.json'
    $traversalManifest = ([IO.File]::ReadAllText($traversalPath)) | ConvertFrom-Json
    $traversalManifest.captures += [ordered]@{
        relativePath = 'captures/../../secret.png'
        sha256 = (Get-HumanDesignReviewSha256ForText -Text 'traversal').ToUpperInvariant()
        width = 100; height = 100; language = 'en'; kind = 'page'; refersToReference = '01-overview.png'
    }
    $traversalManifest.provenance.artifactHash = (Get-HumanDesignReviewArtifactHashFromManifest -Manifest $traversalManifest).ToUpperInvariant()
    $traversalJson = $traversalManifest | ConvertTo-Json -Depth 100
    [IO.File]::WriteAllText($traversalPath, $traversalJson, (New-Object System.Text.UTF8Encoding($false)))
    Assert-ReviewSelftestFailure -Description 'path traversal with .. is rejected' -RequiredFragments @(
        'path traversal tokens') -Action {
        Test-HumanDesignReviewManifest -ManifestPath $traversalPath | Out-Null
    }

    # Negative: BACKSLASH in relativePath is rejected.
    $backslashFolder = Join-Path $testRoot 'neg-path-backslash'
    Copy-Item -LiteralPath $fixture.Root -Destination $backslashFolder -Recurse
    $backslashPath = Join-Path $backslashFolder 'human-design-review.manifest.json'
    $backslashManifest = ([IO.File]::ReadAllText($backslashPath)) | ConvertFrom-Json
    $backslashManifest.captures += [ordered]@{
        relativePath = 'captures\en\pages\overview-100.png'
        sha256 = (Get-HumanDesignReviewSha256ForText -Text 'backslash').ToUpperInvariant()
        width = 100; height = 100; language = 'en'; kind = 'page'; refersToReference = '01-overview.png'
    }
    $backslashManifest.provenance.artifactHash = (Get-HumanDesignReviewArtifactHashFromManifest -Manifest $backslashManifest).ToUpperInvariant()
    $backslashJson = $backslashManifest | ConvertTo-Json -Depth 100
    [IO.File]::WriteAllText($backslashPath, $backslashJson, (New-Object System.Text.UTF8Encoding($false)))
    Assert-ReviewSelftestFailure -Description 'backslash in relativePath is rejected' -RequiredFragments @(
        'forward slashes only') -Action {
        Test-HumanDesignReviewManifest -ManifestPath $backslashPath | Out-Null
    }

    # Negative: NON-CANONICAL contact-sheet path is rejected.
    $badContactFolder = Join-Path $testRoot 'neg-bad-contact-sheet'
    Copy-Item -LiteralPath $fixture.Root -Destination $badContactFolder -Recurse
    $badContactPath = Join-Path $badContactFolder 'human-design-review.manifest.json'
    $badContactManifest = ([IO.File]::ReadAllText($badContactPath)) | ConvertFrom-Json
    $badContactManifest.captures += [ordered]@{
        relativePath = 'captures/en/invalid-folder/sheet.png'
        sha256 = (Get-HumanDesignReviewSha256ForText -Text 'bad contact').ToUpperInvariant()
        width = 100; height = 100; language = 'en'; kind = 'contact-sheet'; refersToReference = '01-overview.png'
    }
    $badContactManifest.provenance.artifactHash = (Get-HumanDesignReviewArtifactHashFromManifest -Manifest $badContactManifest).ToUpperInvariant()
    $badContactJson = $badContactManifest | ConvertTo-Json -Depth 100
    [IO.File]::WriteAllText($badContactPath, $badContactJson, (New-Object System.Text.UTF8Encoding($false)))
    Assert-ReviewSelftestFailure -Description 'non-canonical contact-sheet naming is rejected' -RequiredFragments @(
        'does not conform to canonical contact-sheet naming') -Action {
        Test-HumanDesignReviewManifest -ManifestPath $badContactPath | Out-Null
    }

    # Negative: PENDING with humanReviewClaimed=true is rejected.
    $pendingHumanClaimFolder = Join-Path $testRoot 'neg-pending-human-claim'
    Copy-Item -LiteralPath $fixture.Root -Destination $pendingHumanClaimFolder -Recurse
    $pendingHumanClaimPath = Join-Path $pendingHumanClaimFolder 'human-design-review.manifest.json'
    $pendingHumanClaimManifest = ([IO.File]::ReadAllText($pendingHumanClaimPath)) | ConvertFrom-Json
    $pendingHumanClaimManifest.reviewStatus = 'Pending'
    $pendingHumanClaimManifest.declarations.humanReviewClaimed = $true
    $pendingHumanClaimJson = $pendingHumanClaimManifest | ConvertTo-Json -Depth 100
    [IO.File]::WriteAllText($pendingHumanClaimPath, $pendingHumanClaimJson, (New-Object System.Text.UTF8Encoding($false)))
    Assert-ReviewSelftestFailure -Description 'Pending review manifest with humanReviewClaimed=true is rejected' -RequiredFragments @(
        'Pending review manifest must declare humanReviewClaimed=false') -Action {
        Test-HumanDesignReviewManifest -ManifestPath $pendingHumanClaimPath | Out-Null
    }

    # Negative: PENDING with runtimeClaims=OBSERVED is rejected.
    $pendingRuntimeFolder = Join-Path $testRoot 'neg-pending-runtime-claim'
    Copy-Item -LiteralPath $fixture.Root -Destination $pendingRuntimeFolder -Recurse
    $pendingRuntimePath = Join-Path $pendingRuntimeFolder 'human-design-review.manifest.json'
    $pendingRuntimeManifest = ([IO.File]::ReadAllText($pendingRuntimePath)) | ConvertFrom-Json
    $pendingRuntimeManifest.reviewStatus = 'Pending'
    $pendingRuntimeManifest.declarations.humanReviewClaimed = $false
    $pendingRuntimeManifest.declarations.runtimeClaims = 'OBSERVED'
    $pendingRuntimeJson = $pendingRuntimeManifest | ConvertTo-Json -Depth 100
    [IO.File]::WriteAllText($pendingRuntimePath, $pendingRuntimeJson, (New-Object System.Text.UTF8Encoding($false)))
    Assert-ReviewSelftestFailure -Description 'Pending review manifest with runtimeClaims=OBSERVED is rejected' -RequiredFragments @(
        "Pending review manifest must declare runtimeClaims='NOT OBSERVED'") -Action {
        Test-HumanDesignReviewManifest -ManifestPath $pendingRuntimePath | Out-Null
    }

    # Negative: PENDING with releaseClaims=PRODUCED is rejected.
    $pendingReleaseFolder = Join-Path $testRoot 'neg-pending-release-claim'
    Copy-Item -LiteralPath $fixture.Root -Destination $pendingReleaseFolder -Recurse
    $pendingReleasePath = Join-Path $pendingReleaseFolder 'human-design-review.manifest.json'
    $pendingReleaseManifest = ([IO.File]::ReadAllText($pendingReleasePath)) | ConvertFrom-Json
    $pendingReleaseManifest.reviewStatus = 'Pending'
    $pendingReleaseManifest.declarations.humanReviewClaimed = $false
    $pendingReleaseManifest.declarations.releaseClaims = 'PRODUCED'
    $pendingReleaseJson = $pendingReleaseManifest | ConvertTo-Json -Depth 100
    [IO.File]::WriteAllText($pendingReleasePath, $pendingReleaseJson, (New-Object System.Text.UTF8Encoding($false)))
    Assert-ReviewSelftestFailure -Description 'Pending review manifest with releaseClaims=PRODUCED is rejected' -RequiredFragments @(
        "Pending review manifest must declare releaseClaims='NOT PRODUCED'") -Action {
        Test-HumanDesignReviewManifest -ManifestPath $pendingReleasePath | Out-Null
    }

    # Negative: DRAFT with humanReviewClaimed=true is rejected.
    $draftFolder = Join-Path $testRoot 'neg-draft-human-claim'
    Copy-Item -LiteralPath $fixture.Root -Destination $draftFolder -Recurse
    $draftPath = Join-Path $draftFolder 'human-design-review.manifest.json'
    $draftManifest = ([IO.File]::ReadAllText($draftPath)) | ConvertFrom-Json
    $draftManifest.reviewStatus = 'Draft'
    $draftManifest.declarations.humanReviewClaimed = $true
    $draftJson = $draftManifest | ConvertTo-Json -Depth 100
    [IO.File]::WriteAllText($draftPath, $draftJson, (New-Object System.Text.UTF8Encoding($false)))
    Assert-ReviewSelftestFailure -Description 'Draft review manifest with humanReviewClaimed=true is rejected' -RequiredFragments @(
        'Draft review manifest must declare humanReviewClaimed=false') -Action {
        Test-HumanDesignReviewManifest -ManifestPath $draftPath | Out-Null
    }

    # Negative: REJECTED with humanReviewClaimed=true is rejected.
    $rejectedFolder = Join-Path $testRoot 'neg-rejected-human-claim'
    Copy-Item -LiteralPath $fixture.Root -Destination $rejectedFolder -Recurse
    $rejectedPath = Join-Path $rejectedFolder 'human-design-review.manifest.json'
    $rejectedManifest = ([IO.File]::ReadAllText($rejectedPath)) | ConvertFrom-Json
    $rejectedManifest.reviewStatus = 'Rejected'
    $rejectedManifest.declarations.humanReviewClaimed = $true
    $rejectedJson = $rejectedManifest | ConvertTo-Json -Depth 100
    [IO.File]::WriteAllText($rejectedPath, $rejectedJson, (New-Object System.Text.UTF8Encoding($false)))
    Assert-ReviewSelftestFailure -Description 'Rejected review manifest with humanReviewClaimed=true is rejected' -RequiredFragments @(
        'Rejected review manifest must declare humanReviewClaimed=false') -Action {
        Test-HumanDesignReviewManifest -ManifestPath $rejectedPath | Out-Null
    }

    # Negative: SYNTHETIC descriptor claiming Accepted is rejected.
    $syntheticAcceptFolder = Join-Path $testRoot 'neg-synthetic-accepted'
    Copy-Item -LiteralPath $fixture.Root -Destination $syntheticAcceptFolder -Recurse
    $syntheticAcceptPath = Join-Path $syntheticAcceptFolder 'human-design-review.manifest.json'
    $syntheticAcceptManifest = ([IO.File]::ReadAllText($syntheticAcceptPath)) | ConvertFrom-Json
    $syntheticAcceptManifest.provenance.canonicalRunDescriptor = 'synthetic reconciliation fixture run'
    $syntheticAcceptManifest.provenance.runHash = (Get-HumanDesignReviewRunHashFromManifest -Manifest $syntheticAcceptManifest).ToUpperInvariant()
    $syntheticAcceptJson = $syntheticAcceptManifest | ConvertTo-Json -Depth 100
    [IO.File]::WriteAllText($syntheticAcceptPath, $syntheticAcceptJson, (New-Object System.Text.UTF8Encoding($false)))
    Assert-ReviewSelftestFailure -Description 'Accepted manifest bound to synthetic descriptor is rejected' -RequiredFragments @(
        'cannot be bound to a synthetic or fixture run descriptor') -Action {
        Test-HumanDesignReviewManifest -ManifestPath $syntheticAcceptPath | Out-Null
    }

    # Positive control must still verify after all negatives.
    $positiveRefinal = Test-HumanDesignReviewManifest -ManifestPath $fixture.ManifestPath -EvidenceRoot $fixture.Root -ValidateBindings
    if (-not $positiveRefinal.Valid) {
        throw 'The fully bound fixture manifest no longer verifies after the negative selftest set.'
    }
} finally {
    Remove-ReviewTempDirectory -Path $testRoot
}

[pscustomobject][ordered]@{
    EvidenceClass = 'Static/Contract/Synthetic'
    Issue = (Get-HumanDesignReviewIssue)
    Version = (Get-HumanDesignReviewVersion)
    PowerShellEdition = [string]$PSVersionTable.PSEdition
    PowerShellVersion = [string]$PSVersionTable.PSVersion
    TemplateFailClosed = 'PASS'
    PositiveControlAccepted = 'PASS'
    OnDiskBinding = 'PASS'
    PathContainmentTraversalFailClosed = 'PASS'
    ContactSheetBindingFailClosed = 'PASS'
    PendingInvariantsFailClosed = 'PASS'
    DraftRejectedInvariantsFailClosed = 'PASS'
    SyntheticAcceptanceFailClosed = 'PASS'
    MissingCaptureFailClosed = 'PASS'
    DuplicateCaptureFailClosed = 'PASS'
    UnexpectedCaptureFailClosed = 'PASS'
    ExactCaptureSetCardinalityFailClosed = 'PASS'
    ExactWidgetCardinalityFailClosed = 'PASS'
    ReferenceBindingFailClosed = 'PASS'
    ForgedCheckboxOnlySignoffFailClosed = 'PASS'
    ForgedDivergenceFailClosed = 'PASS'
    HashTamperFailClosed = 'PASS'
    FutureDateFalsifiedFailClosed = 'PASS'
    DuplicateJsonFailClosed = 'PASS'
    Human = 'NOT OBSERVED'
    Runtime = 'NOT OBSERVED'
    Release = 'NOT OBSERVED'
}