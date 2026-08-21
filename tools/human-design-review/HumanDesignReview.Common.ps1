#requires -Version 5.1

Set-StrictMode -Version Latest

### HerdrOps v0.7 Issue #35 Human Design & Accessibility Review manifest tooling.
### Fail-closed shared helpers. Runs on Windows PowerShell 5.1 and PowerShell 7.x.

function Get-HumanDesignReviewRoot {
    return (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..\..')).Path
}

function Get-HumanDesignReviewSchemaPath {
    return (Join-Path $PSScriptRoot 'human-design-review.schema.json')
}

function Get-HumanDesignReviewTemplatePath {
    return (Join-Path $PSScriptRoot 'human-design-review.template.json')
}

function Get-HumanDesignReviewIssue {
    return 35
}

function Get-HumanDesignReviewVersion {
    return '0.7.0'
}

function Get-HumanDesignReviewSchemaId {
    return 'https://herdrops.local/schema/v0.7/human-design-review.schema.json'
}

function Get-HumanDesignReviewCanonicalPages {
    return @('overview', 'live-organization', 'realtime-activity', 'delegation-graph', 'agent-detail',
        'task-alignment', 'file-activity', 'compliance-queue', 'evaluation', 'daily-summary')
}

function Get-HumanDesignReviewLanguages {
    return @('th', 'en')
}

function Get-HumanDesignReviewScales {
    return @(100, 125, 150)
}

function Get-HumanDesignReviewWidgetVariants {
    return @('Compact', 'Normal', 'Expanded', 'FloatingMini', 'FloatingVertical', 'Notification',
        'AgentDetailPopup', 'DashboardPreview')
}

function Get-HumanDesignReviewCanonicalPageCaptureCount {
    return @(Get-HumanDesignReviewCanonicalPageCaptureKeys).Count
}

function Get-HumanDesignReviewCanonicalWidgetVariantCount {
    return @(Get-HumanDesignReviewWidgetVariants).Count
}

function Test-HumanDesignReviewContactSheetRef {
    param([Parameter(Mandatory = $true)][string]$RelativePath)

    $normalized = $RelativePath.Replace('\', '/')
    if ($normalized -eq 'captures/README-placeholder') {
        return $true
    }
    return ($normalized -match '^captures/(th|en)/contact-sheets/[a-z0-9-]+\.png$' -or
            $normalized -match '^captures/contact-sheets/[a-z0-9-]+\.png$')
}

function Assert-HumanDesignReviewContainedPath {
    param(
        [string]$Root,
        [Parameter(Mandatory = $true)][string]$RelativePath,
        [Parameter(Mandatory = $true)][string]$Context
    )

    if ([string]::IsNullOrWhiteSpace($RelativePath)) {
        throw "$Context relative path must not be empty."
    }
    if ($RelativePath.Contains('\')) {
        throw "$Context relativePath must use forward slashes only: '$RelativePath'."
    }
    if ($RelativePath.StartsWith('/') -or $RelativePath -match '^[a-zA-Z]:') {
        throw "$Context relativePath must not be an absolute path: '$RelativePath'."
    }
    if ($RelativePath.Contains('..') -or $RelativePath.Contains(':')) {
        throw "$Context relativePath contains invalid path traversal tokens: '$RelativePath'."
    }
    if (-not $RelativePath.StartsWith('captures/', [StringComparison]::Ordinal)) {
        throw "$Context relativePath must start with 'captures/': '$RelativePath'."
    }
    if ($RelativePath -notmatch '^[a-zA-Z0-9_\-\.\/]+$') {
        throw "$Context relativePath contains illegal characters: '$RelativePath'."
    }

    if (-not [string]::IsNullOrWhiteSpace($Root)) {
        $canonicalRoot = [IO.Path]::GetFullPath($Root)
        if ($canonicalRoot.Length -gt 3) {
            $canonicalRoot = $canonicalRoot.TrimEnd('\')
        }
        $nativeRel = $RelativePath.Replace('/', [IO.Path]::DirectorySeparatorChar.ToString())
        $joined = Join-Path $canonicalRoot $nativeRel
        $full = [IO.Path]::GetFullPath($joined)
        $rootPrefix = $canonicalRoot + [IO.Path]::DirectorySeparatorChar.ToString()
        if ($full -ne $canonicalRoot -and -not $full.StartsWith($rootPrefix, [StringComparison]::OrdinalIgnoreCase)) {
            throw "$Context path traversal detected: path '$RelativePath' escapes EvidenceRoot '$Root'."
        }
    }
}

function Test-HumanDesignReviewGitObjectId {
    param([string]$Value)

    return (-not [string]::IsNullOrWhiteSpace($Value) -and $Value -cmatch '^[0-9a-f]{40}$')
}

function Get-HumanDesignReviewSourceBindingDigest {
    param(
        [Parameter(Mandatory = $true)][string]$SourceCommit,
        [Parameter(Mandatory = $true)][string]$SourceTree
    )

    if (-not (Test-HumanDesignReviewGitObjectId -Value $SourceCommit)) {
        throw 'Source commit must be an exact lowercase 40-character Git object id.'
    }
    if (-not (Test-HumanDesignReviewGitObjectId -Value $SourceTree)) {
        throw 'Source tree must be an exact lowercase 40-character Git object id.'
    }

    return (Get-HumanDesignReviewSha256ForText -Text "git:commit:$SourceCommit|tree:$SourceTree").ToUpperInvariant()
}

function Get-HumanDesignReviewGitProvenance {
    param([string]$RepoRoot)

    if ([string]::IsNullOrWhiteSpace($RepoRoot)) {
        $RepoRoot = Get-HumanDesignReviewRoot
    }

    $commitOutput = & git -C $RepoRoot rev-parse HEAD 2>$null
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($commitOutput)) {
        return $null
    }
    $commit = (($commitOutput | Out-String).Trim()).ToLowerInvariant()
    if (-not (Test-HumanDesignReviewGitObjectId -Value $commit)) {
        return $null
    }

    $treeOutput = & git -C $RepoRoot rev-parse 'HEAD^{tree}' 2>$null
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($treeOutput)) {
        return $null
    }
    $tree = (($treeOutput | Out-String).Trim()).ToLowerInvariant()
    if (-not (Test-HumanDesignReviewGitObjectId -Value $tree)) {
        return $null
    }

    $branchOutput = & git -C $RepoRoot rev-parse --abbrev-ref HEAD 2>$null
    $branch = if ($LASTEXITCODE -eq 0 -and -not [string]::IsNullOrWhiteSpace($branchOutput)) { (($branchOutput | Out-String).Trim()) } else { 'main' }

    $statusOutput = @(& git -C $RepoRoot status --porcelain=v1 --untracked-files=all 2>$null)
    $statusExitCode = $LASTEXITCODE
    $status = @($statusOutput | ForEach-Object { [string]$_ })
    $statusAvailable = ($statusExitCode -eq 0)
    $workingTreeClean = ($statusAvailable -and $status.Count -eq 0)
    $commitSha256 = Get-HumanDesignReviewSourceBindingDigest -SourceCommit $commit -SourceTree $tree

    return [pscustomobject][ordered]@{
        GitCommit = $commit
        GitTree = $tree
        Branch = $branch
        CommitSha256 = $commitSha256
        WorkingTreeStatus = $status
        WorkingTreeClean = $workingTreeClean
        StatusAvailable = $statusAvailable
        IsVerifiable = $true
    }
}

function Assert-HumanDesignReviewExpectedSource {
    param(
        [string]$ExpectedSourceCommit,
        [string]$ExpectedSourceTree
    )

    if ([string]::IsNullOrWhiteSpace($ExpectedSourceCommit) -or [string]::IsNullOrWhiteSpace($ExpectedSourceTree)) {
        throw 'ExpectedSourceCommit and ExpectedSourceTree are required when ValidateBindings is set.'
    }
    if (-not (Test-HumanDesignReviewGitObjectId -Value $ExpectedSourceCommit)) {
        throw 'ExpectedSourceCommit must be an exact lowercase 40-character Git commit SHA.'
    }
    if (-not (Test-HumanDesignReviewGitObjectId -Value $ExpectedSourceTree)) {
        throw 'ExpectedSourceTree must be an exact lowercase 40-character Git tree SHA.'
    }

    return [pscustomobject][ordered]@{
        Commit = $ExpectedSourceCommit
        Tree = $ExpectedSourceTree
        BindingDigest = Get-HumanDesignReviewSourceBindingDigest -SourceCommit $ExpectedSourceCommit -SourceTree $ExpectedSourceTree
    }
}

function Assert-HumanDesignReviewGitSnapshot {
    param(
        [Parameter(Mandatory = $true)]$Snapshot,
        [Parameter(Mandatory = $true)][string]$ExpectedSourceCommit,
        [Parameter(Mandatory = $true)][string]$ExpectedSourceTree,
        [Parameter(Mandatory = $true)][string]$Context
    )

    if ($null -eq $Snapshot -or -not [bool]$Snapshot.IsVerifiable) {
        throw "$Context could not resolve an exact Git commit and tree."
    }
    if ([string]$Snapshot.GitCommit -cne $ExpectedSourceCommit) {
        throw "$Context Git source commit does not match ExpectedSourceCommit: expected '$ExpectedSourceCommit', observed '$($Snapshot.GitCommit)'."
    }
    if ([string]$Snapshot.GitTree -cne $ExpectedSourceTree) {
        throw "$Context Git source tree does not match ExpectedSourceTree: expected '$ExpectedSourceTree', observed '$($Snapshot.GitTree)'."
    }
    if (-not [bool]$Snapshot.StatusAvailable) {
        throw "$Context could not resolve Git working-tree status."
    }
    if (-not [bool]$Snapshot.WorkingTreeClean) {
        $statusText = (@($Snapshot.WorkingTreeStatus) -join '; ')
        throw "$Context Git working tree must be clean before and after binding validation. Observed: $statusText"
    }
}

function Assert-HumanDesignReviewManifestSourceBinding {
    param(
        [Parameter(Mandatory = $true)]$Manifest,
        [Parameter(Mandatory = $true)][string]$ExpectedSourceCommit,
        [Parameter(Mandatory = $true)][string]$ExpectedSourceTree
    )

    $expectedDigest = Get-HumanDesignReviewSourceBindingDigest -SourceCommit $ExpectedSourceCommit -SourceTree $ExpectedSourceTree
    $provenanceDigest = ([string]$Manifest.provenance.boundCommitSha256).ToUpperInvariant()
    $wpfDigest = ([string]$Manifest.uiUnderReview.wpfBuild.commitSha256).ToUpperInvariant()
    if ($provenanceDigest -cne $wpfDigest) {
        throw 'Review manifest provenance.boundCommitSha256 and uiUnderReview.wpfBuild.commitSha256 must be equal.'
    }
    if ($provenanceDigest -cne $expectedDigest) {
        throw 'Review manifest source binding digest does not match the expected source commit/tree binding digest.'
    }
    return $expectedDigest
}

function Get-HumanDesignReviewZeroHash {
    return ('0' * 64)
}

### Immutable reference MANIFEST binding. The authoritative reference surface is
### docs/design/reference/MANIFEST.md plus the eleven immutable PNGs it lists.
### A capture's refersToReference must name a valid MANIFEST entry and, when
### binding is validated, the on-disk reference PNG bytes must equal the MANIFEST
### table hash so the immutable reference surface cannot be silently swapped.

function Get-HumanDesignReviewReferenceManifestPath {
    return (Join-Path (Get-HumanDesignReviewRoot) 'docs\design\reference\MANIFEST.md')
}

function Get-HumanDesignReviewReferenceDirectory {
    return (Join-Path (Get-HumanDesignReviewRoot) 'docs\design\reference')
}

function Read-HumanDesignReviewReferenceManifest {
    $path = Get-HumanDesignReviewReferenceManifestPath
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        throw "Design reference MANIFEST.md was not found at '$path'."
    }
    $entries = @{}
    $lines = [IO.File]::ReadAllLines($path)
    foreach ($line in $lines) {
        if ($line -notmatch '^\|\s*`([0-9]{2}-[a-z0-9-]+\.png)`\s*\|\s*([0-9]+)\s*[x\u00D7]\s*([0-9]+)\s*\|\s*([0-9,]+)\s*\|\s*`([0-9A-Fa-f]{64})`\s*\|$') {
            continue
        }
        $fileName = $Matches[1]
        $width = [int]$Matches[2]
        $height = [int]$Matches[3]
        $bytes = [int64]($Matches[4] -replace ',', '')
        $sha256 = $Matches[5].ToUpperInvariant()
        $entries[$fileName] = [pscustomobject][ordered]@{
            File = $fileName
            Width = $width
            Height = $height
            Bytes = $bytes
            Sha256 = $sha256
        }
    }
    if ($entries.Count -ne 11) {
        throw "Design reference MANIFEST.md must declare exactly 11 immutable reference entries; found $($entries.Count)."
    }
    return $entries
}

function Test-HumanDesignReviewReferenceEntry {
    param([Parameter(Mandatory = $true)][string]$Reference)

    $normalized = $Reference.Replace('\', '/')
    $leaf = [IO.Path]::GetFileName($normalized)
    $manifest = Read-HumanDesignReviewReferenceManifest
    return $manifest.ContainsKey($leaf)
}

function Assert-HumanDesignReviewReferenceBinding {
    param([Parameter(Mandatory = $true)][string]$Reference, [switch]$ValidateBindings)

    $normalized = $Reference.Replace('\', '/')
    $leaf = [IO.Path]::GetFileName($normalized)
    $manifest = Read-HumanDesignReviewReferenceManifest
    if (-not $manifest.ContainsKey($leaf)) {
        throw "Capture refersToReference '$Reference' is not a valid docs/design/reference/MANIFEST.md entry."
    }
    if (-not $ValidateBindings) {
        return
    }
    $entry = $manifest[$leaf]
    $onDiskPath = Join-Path (Get-HumanDesignReviewReferenceDirectory) $leaf
    if (-not (Test-Path -LiteralPath $onDiskPath -PathType Leaf)) {
        throw "Immutable reference '$leaf' is missing from docs/design/reference/."
    }
    $bytes = [IO.File]::ReadAllBytes((Resolve-Path -LiteralPath $onDiskPath).Path)
    $onDiskHash = Get-HumanDesignReviewSha256ForBytes -Bytes $bytes
    if ($onDiskHash -cne $entry.Sha256) {
        throw "Immutable reference '$leaf' on-disk SHA-256 ($onDiskHash) does not match the MANIFEST.md bound hash."
    }
    if ($bytes.Length -ne [long]$entry.Bytes) {
        throw "Immutable reference '$leaf' on-disk byte length does not match the MANIFEST.md bound byte count."
    }
}

function Test-HumanDesignReviewPlaceholder {
    param([AllowEmptyString()][string]$Text)

    if ([string]::IsNullOrWhiteSpace($Text)) {
        return $true
    }
    if ($Text.IndexOf('[PLACEHOLDER]', [StringComparison]::OrdinalIgnoreCase) -ge 0) {
        return $true
    }
    if ($Text -match '<FILL|<TODO|NOT SET|TO BE COMPLETED') {
        return $true
    }
    return $false
}

function Test-HumanDesignReviewSha256 {
    param([string]$Hash)

    return ($Hash -match '^[0-9A-Fa-f]{64}$')
}

function Test-HumanDesignReviewBoundHash {
    param([string]$Hash)

    if (-not (Test-HumanDesignReviewSha256 -Hash $Hash)) {
        return $false
    }
    if ($Hash.ToUpperInvariant() -ceq (Get-HumanDesignReviewZeroHash).ToUpperInvariant()) {
        return $false
    }
    return $true
}

function Get-HumanDesignReviewSha256ForText {
    param([Parameter(Mandatory = $true)][string]$Text)

    $encoding = New-Object System.Text.UTF8Encoding($false)
    $bytes = $encoding.GetBytes($Text)
    $algorithm = [Security.Cryptography.SHA256]::Create()
    try {
        return ([BitConverter]::ToString($algorithm.ComputeHash($bytes))).Replace('-', '').ToUpperInvariant()
    } finally {
        $algorithm.Dispose()
    }
}

function Get-HumanDesignReviewSha256ForBytes {
    param([Parameter(Mandatory = $true)][byte[]]$Bytes)

    $algorithm = [Security.Cryptography.SHA256]::Create()
    try {
        return ([BitConverter]::ToString($algorithm.ComputeHash($Bytes))).Replace('-', '').ToUpperInvariant()
    } finally {
        $algorithm.Dispose()
    }
}

### Strict JSON scanning: rejects duplicate object properties (case-insensitive) and
### trailing content, matching the repository's canonical hardening convention.

function Skip-HumanDesignReviewWhitespace {
    param(
        [Parameter(Mandatory = $true)][string]$Json,
        [Parameter(Mandatory = $true)][ref]$Index
    )

    while ($Index.Value -lt $Json.Length) {
        $code = [int][char]$Json[$Index.Value]
        if ($code -ne 32 -and $code -ne 9 -and $code -ne 10 -and $code -ne 13) {
            break
        }
        $Index.Value = $Index.Value + 1
    }
}

function Read-HumanDesignReviewJsonString {
    param(
        [Parameter(Mandatory = $true)][string]$Json,
        [Parameter(Mandatory = $true)][ref]$Index
    )

    if ($Index.Value -ge $Json.Length -or $Json[$Index.Value] -ne '"') {
        throw 'HumanDesignReview JSON property names and string values must start with a quote.'
    }

    $builder = New-Object System.Text.StringBuilder
    $Index.Value = $Index.Value + 1
    while ($Index.Value -lt $Json.Length) {
        $character = [char]$Json[$Index.Value]
        $Index.Value = $Index.Value + 1
        if ($character -eq '"') {
            return $builder.ToString()
        }
        if ($character -eq '\') {
            if ($Index.Value -ge $Json.Length) {
                throw 'HumanDesignReview JSON string ended after an escape character.'
            }
            $escape = [char]$Json[$Index.Value]
            $Index.Value = $Index.Value + 1
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
                    if ($Index.Value + 4 -gt $Json.Length) {
                        throw 'HumanDesignReview JSON Unicode escape is truncated.'
                    }
                    $hex = $Json.Substring($Index.Value, 4)
                    if ($hex -notmatch '^[0-9A-Fa-f]{4}$') {
                        throw "HumanDesignReview JSON Unicode escape is invalid: $hex"
                    }
                    [void]$builder.Append([char][Convert]::ToInt32($hex, 16))
                    $Index.Value = $Index.Value + 4
                }
                default {
                    throw "HumanDesignReview JSON string contains an invalid escape sequence: \$escape"
                }
            }
            continue
        }
        if ([int][char]$character -lt 32) {
            throw 'HumanDesignReview JSON strings must not contain unescaped control characters.'
        }
        [void]$builder.Append($character)
    }

    throw 'HumanDesignReview JSON string was not terminated.'
}

function Read-HumanDesignReviewJsonValue {
    param(
        [Parameter(Mandatory = $true)][string]$Json,
        [Parameter(Mandatory = $true)][ref]$Index,
        [Parameter(Mandatory = $true)][string]$Description
    )

    Skip-HumanDesignReviewWhitespace -Json $Json -Index $Index
    if ($Index.Value -ge $Json.Length) {
        throw "$Description ended before a JSON value."
    }

    switch ([char]$Json[$Index.Value]) {
        '{' {
            Read-HumanDesignReviewJsonObject -Json $Json -Index $Index -Description $Description
            return
        }
        '[' {
            Read-HumanDesignReviewJsonArray -Json $Json -Index $Index -Description $Description
            return
        }
        '"' {
            [void](Read-HumanDesignReviewJsonString -Json $Json -Index $Index)
            return
        }
        default {
            $start = $Index.Value
            while ($Index.Value -lt $Json.Length) {
                $character = [char]$Json[$Index.Value]
                if ($character -eq ',' -or $character -eq ']' -or $character -eq '}' -or
                    [int][char]$character -eq 32 -or [int][char]$character -eq 9 -or
                    [int][char]$character -eq 10 -or [int][char]$character -eq 13) {
                    break
                }
                $Index.Value = $Index.Value + 1
            }
            if ($Index.Value -eq $start) {
                throw "$Description contains an invalid JSON value."
            }
            $token = $Json.Substring($start, $Index.Value - $start)
            if ($token -notmatch '^(true|false|null|-?(0|[1-9][0-9]*)(\.[0-9]+)?([eE][+-]?[0-9]+)?)$') {
                throw "$Description contains an invalid JSON token: $token"
            }
        }
    }
}

function Read-HumanDesignReviewJsonArray {
    param(
        [Parameter(Mandatory = $true)][string]$Json,
        [Parameter(Mandatory = $true)][ref]$Index,
        [Parameter(Mandatory = $true)][string]$Description
    )

    $Index.Value = $Index.Value + 1
    Skip-HumanDesignReviewWhitespace -Json $Json -Index $Index
    if ($Index.Value -lt $Json.Length -and $Json[$Index.Value] -eq ']') {
        $Index.Value = $Index.Value + 1
        return
    }

    while ($true) {
        Read-HumanDesignReviewJsonValue -Json $Json -Index $Index -Description $Description
        Skip-HumanDesignReviewWhitespace -Json $Json -Index $Index
        if ($Index.Value -ge $Json.Length) {
            throw "$Description array was not terminated."
        }
        if ($Json[$Index.Value] -eq ']') {
            $Index.Value = $Index.Value + 1
            return
        }
        if ($Json[$Index.Value] -ne ',') {
            throw "$Description array requires a comma or closing bracket."
        }
        $Index.Value = $Index.Value + 1
        Skip-HumanDesignReviewWhitespace -Json $Json -Index $Index
        if ($Index.Value -lt $Json.Length -and $Json[$Index.Value] -eq ']') {
            throw "$Description array contains a trailing comma."
        }
    }
}

function Read-HumanDesignReviewJsonObject {
    param(
        [Parameter(Mandatory = $true)][string]$Json,
        [Parameter(Mandatory = $true)][ref]$Index,
        [Parameter(Mandatory = $true)][string]$Description
    )

    $Index.Value = $Index.Value + 1
    $propertyNames = @()
    Skip-HumanDesignReviewWhitespace -Json $Json -Index $Index
    if ($Index.Value -lt $Json.Length -and $Json[$Index.Value] -eq '}') {
        $Index.Value = $Index.Value + 1
        return
    }

    while ($true) {
        Skip-HumanDesignReviewWhitespace -Json $Json -Index $Index
        if ($Index.Value -ge $Json.Length -or $Json[$Index.Value] -ne '"') {
            throw "$Description object requires a quoted property name."
        }
        $propertyName = Read-HumanDesignReviewJsonString -Json $Json -Index $Index
        foreach ($existingName in @($propertyNames)) {
            if ([StringComparer]::OrdinalIgnoreCase.Equals([string]$existingName, [string]$propertyName)) {
                throw "HumanDesignReview duplicate JSON object property '$propertyName' in $Description (case-insensitive)."
            }
        }
        $propertyNames += $propertyName
        Skip-HumanDesignReviewWhitespace -Json $Json -Index $Index
        if ($Index.Value -ge $Json.Length -or $Json[$Index.Value] -ne ':') {
            throw "$Description property '$propertyName' is missing a colon."
        }
        $Index.Value = $Index.Value + 1
        Read-HumanDesignReviewJsonValue -Json $Json -Index $Index -Description "$Description property '$propertyName'"
        Skip-HumanDesignReviewWhitespace -Json $Json -Index $Index
        if ($Index.Value -ge $Json.Length) {
            throw "$Description object was not terminated."
        }
        if ($Json[$Index.Value] -eq '}') {
            $Index.Value = $Index.Value + 1
            return
        }
        if ($Json[$Index.Value] -ne ',') {
            throw "$Description object requires a comma or closing brace."
        }
        $Index.Value = $Index.Value + 1
        Skip-HumanDesignReviewWhitespace -Json $Json -Index $Index
        if ($Index.Value -lt $Json.Length -and $Json[$Index.Value] -eq '}') {
            throw "$Description object contains a trailing comma."
        }
    }
}

function ConvertFrom-StrictHumanDesignReviewJson {
    param(
        [Parameter(Mandatory = $true)][string]$Json,
        [Parameter(Mandatory = $true)][string]$Description
    )

    $index = 0
    Read-HumanDesignReviewJsonValue -Json $Json -Index ([ref]$index) -Description $Description
    Skip-HumanDesignReviewWhitespace -Json $Json -Index ([ref]$index)
    if ($index -ne $Json.Length) {
        throw "$Description contains trailing JSON content."
    }

    try {
        return ($Json | ConvertFrom-Json)
    } catch {
        throw "$Description is not valid JSON: $($_.Exception.Message)"
    }
}

### Canonical capture universe. A required page capture key is
### "<language>/<page>-<scale>" and refs "<lang>/pages/<page>-<scale>.png".

function Get-HumanDesignReviewCanonicalPageCaptureKeys {
    $keys = @()
    foreach ($language in (Get-HumanDesignReviewLanguages)) {
        foreach ($page in (Get-HumanDesignReviewCanonicalPages)) {
            foreach ($scale in (Get-HumanDesignReviewScales)) {
                $keys += ($language + '/' + $page + '-' + $scale)
            }
        }
    }
    return $keys
}

function Get-HumanDesignReviewCanonicalWidgetCaptureRefs {
    $refs = @()
    foreach ($language in (Get-HumanDesignReviewLanguages)) {
        foreach ($variant in (Get-HumanDesignReviewWidgetVariants)) {
            $refs += ('captures/' + $language + '/widgets/' + $variant.ToLowerInvariant() + '-native.png')
        }
    }
    return $refs
}

function Get-HumanDesignReviewCanonicalPageCaptureRefForKey {
    param([Parameter(Mandatory = $true)][string]$Key)

    $parts = $Key.Split([char]'/')
    if ($parts.Count -ne 2) {
        return $null
    }
    $pageScale = $parts[1]
    $dash = $pageScale.LastIndexOf([char]'-')
    if ($dash -lt 0) {
        return $null
    }
    $page = $pageScale.Substring(0, $dash)
    $scale = $pageScale.Substring($dash + 1)
    return ('captures/' + $parts[0] + '/pages/' + $page + '-' + $scale + '.png')
}

function Get-HumanDesignReviewCanonicalPageCaptureKeyForRef {
    param([Parameter(Mandatory = $true)][string]$RelativePath)

    $normalized = $RelativePath.Replace('\', '/')
    if (-not $normalized.StartsWith('captures/', [StringComparison]::Ordinal)) {
        return $null
    }
    $remainder = $normalized.Substring('captures/'.Length)
    $slash = $remainder.IndexOf([char]'/')
    if ($slash -le 0) {
        return $null
    }
    $language = $remainder.Substring(0, $slash)
    if ($language -notin @('th', 'en')) {
        return $null
    }
    $relativePart = $remainder.Substring($slash + 1)
    if (-not $relativePart.StartsWith('pages/', [StringComparison]::Ordinal)) {
        return $null
    }
    $tail = $relativePart.Substring('pages/'.Length)
    if (-not $tail.EndsWith('.png', [StringComparison]::OrdinalIgnoreCase)) {
        return $null
    }
    $base = $tail.Substring(0, $tail.Length - '.png'.Length)
    $dash = $base.LastIndexOf([char]'-')
    if ($dash -lt 0) {
        return $null
    }
    $scale = $base.Substring($dash + 1)
    $page = $base.Substring(0, $dash)
    if ($scale -notin @('100', '125', '150') -or $page -notin (Get-HumanDesignReviewCanonicalPages)) {
        return $null
    }
    return ($language + '/' + $page + '-' + $scale)
}

### Evidence-link and accessibility-check validation helpers.

function Assert-HumanDesignReviewEvidenceLink {
    param(
        [Parameter(Mandatory = $true)]$Link,
        [Parameter(Mandatory = $true)][string]$Context
    )

    if ($null -eq $Link -or $Link -is [string] -or $Link -is [array]) {
        throw "$Context evidence link must be an object."
    }
    $names = @($Link.PSObject.Properties.Name)
    $expected = @('boundSha256', 'note')
    if ($names.Count -ne $expected.Count) {
        throw "$Context evidence link must have exactly boundSha256 and note."
    }
    foreach ($expectedName in $expected) {
        if ($names -notcontains $expectedName) {
            throw "$Context evidence link is missing '$expectedName'."
        }
    }
    if (-not (Test-HumanDesignReviewBoundHash -Hash ([string]$Link.boundSha256))) {
        throw "$Context evidence link has an unbound or forged boundary hash."
    }
    if (Test-HumanDesignReviewPlaceholder -Text ([string]$Link.note) -or [string]$Link.note.Length -lt 8) {
        throw "$Context evidence link note is empty, placeholder, or too short."
    }
}

function Assert-HumanDesignReviewCheckWithEvidence {
    param(
        [Parameter(Mandatory = $true)]$Check,
        [Parameter(Mandatory = $true)][string]$Context
    )

    if ($null -eq $Check -or $Check -is [string] -or $Check -is [array] -or
        -not ($Check.PSObject.Properties.Name -contains 'passed') ) {
        throw "$Context accessibility check must be an object with a passed boolean."
    }
    $names = @($Check.PSObject.Properties.Name)
    $expected = @('passed', 'evidence')
    if ($names.Count -ne $expected.Count) {
        throw "$Context accessibility check must have exactly passed and evidence."
    }
    foreach ($expectedName in $expected) {
        if ($names -notcontains $expectedName) {
            throw "$Context accessibility check is missing '$expectedName'."
        }
    }
    if ($Check.passed -isnot [bool]) {
        throw "$Context accessibility check passed must be a boolean, not $($Check.passed.GetType().Name)."
    }
    Assert-HumanDesignReviewEvidenceLink -Link $Check.evidence -Context $Context

    if ([bool]$Check.passed) {
        if (-not (Test-HumanDesignReviewBoundHash -Hash ([string]$Check.evidence.boundSha256))) {
            throw "$Context accessibility check passes without a bound evidence hash (checkbox-only signoff)."
        }
        if (Test-HumanDesignReviewPlaceholder -Text ([string]$Check.evidence.note)) {
            throw "$Context accessibility check passes with a placeholder evidence note (checkbox-only signoff)."
        }
    }
}

### Hash re-computation.

function Get-HumanDesignReviewRunHashFromManifest {
    param([Parameter(Mandatory = $true)]$Manifest)

    $descriptor = [string]$Manifest.provenance.canonicalRunDescriptor
    $commit = [string]$Manifest.provenance.boundCommitSha256
    $algorithm = [string]$Manifest.provenance.hashAlgorithm
    return Get-HumanDesignReviewSha256ForText -Text ($descriptor + '|' + $commit + '|' + $algorithm)
}

function Get-HumanDesignReviewArtifactHashFromManifest {
    param([Parameter(Mandatory = $true)]$Manifest)

    $lines = @()
    foreach ($capture in @($Manifest.captures)) {
        $lines += ([string]$capture.relativePath.Replace('\', '/') + '|' + [string]$capture.sha256)
    }
    [Array]::Sort([string[]]$lines, [StringComparer]::Ordinal)
    return Get-HumanDesignReviewSha256ForText -Text (($lines -join "`n") + "`n")
}

### Top-level fail-closed verification. Throws on any violation.

function Test-HumanDesignReviewManifestInvariants {
    param(
        [Parameter(Mandatory = $true)]$Manifest,
        [string]$EvidenceRoot,
        [switch]$ValidateBindings,
        [string]$ExpectedSourceCommit,
        [string]$ExpectedSourceTree
    )

    if ($ValidateBindings) {
        Assert-HumanDesignReviewExpectedSource -ExpectedSourceCommit $ExpectedSourceCommit -ExpectedSourceTree $ExpectedSourceTree | Out-Null
    }

    $expectedRootNames = @('$id', 'schemaVersion', 'contract', 'reviewStatus', 'reviewer', 'provenance',
        'uiUnderReview', 'captures', 'pages', 'widgets', 'accessibleEvidence', 'declarations')
    $rootNames = @($Manifest.PSObject.Properties.Name)
    if ($rootNames.Count -ne $expectedRootNames.Count) {
        throw 'Review manifest root must contain exactly the schema-declared properties.'
    }
    foreach ($name in $expectedRootNames) {
        if ($rootNames -notcontains $name) {
            throw "Review manifest is missing required root property '$name'."
        }
    }

    if ([string]$Manifest.'$id' -cne (Get-HumanDesignReviewSchemaId)) {
        throw "Review manifest $id does not match the authorized schema: $($Manifest.'$id')"
    }
    if ([int]$Manifest.schemaVersion -ne 1) {
        throw "Review manifest schema version must be 1: $($Manifest.schemaVersion)"
    }

    $contract = $Manifest.contract
    if ([int]$contract.issue -ne (Get-HumanDesignReviewIssue) -or
        [string]$contract.version -cne (Get-HumanDesignReviewVersion) -or
        [string]$contract.productId -cne 'HerdrOps' -or
        [string]$contract.immutableReferenceSet -cne 'docs/design/reference/*.png' -or
        [string]$contract.designContract -cne 'Plan/DESIGN-CONTRACT.md') {
        throw 'Review manifest contract metadata does not bind Issue #35 / v0.7.0.'
    }

    $reviewStatus = [string]$Manifest.reviewStatus
    if ($reviewStatus -notin @('Draft', 'Pending', 'Accepted', 'Rejected')) {
        throw "Review manifest has invalid reviewStatus '$reviewStatus'."
    }

    $reviewer = $Manifest.reviewer
    foreach ($field in @('name', 'role', 'organization', 'signatory')) {
        if (Test-HumanDesignReviewPlaceholder -Text ([string]$reviewer.$field)) {
            throw "Review manifest reviewer '$field' is missing or placeholder."
        }
    }
    $signatureDate = [string]$reviewer.signatureDate
    if ($signatureDate -notmatch '^[0-9]{4}-[0-9]{2}-[0-9]{2}$') {
        throw 'Review manifest reviewer signatureDate is malformed.'
    }
    if ($signatureDate -ge '2030-01-01') {
        throw 'Review manifest reviewer signatureDate is in the future; signoff time is falsified.'
    }

    $provenance = $Manifest.provenance
    if ([string]$provenance.hashAlgorithm -cne 'SHA-256') {
        throw "Review manifest hash algorithm must be SHA-256: $($provenance.hashAlgorithm)"
    }
    foreach ($hashField in @('boundCommitSha256', 'runHash', 'artifactHash')) {
        if (-not (Test-HumanDesignReviewBoundHash -Hash ([string]$provenance.$hashField))) {
            throw "Review manifest provenance '$hashField' is missing, malformed, or an unbound zero hash."
        }
    }
    if (Test-HumanDesignReviewPlaceholder -Text ([string]$provenance.canonicalRunDescriptor)) {
        throw 'Review manifest provenance canonicalRunDescriptor is missing or placeholder.'
    }
    $expectedRunHash = Get-HumanDesignReviewRunHashFromManifest -Manifest $Manifest
    if ($expectedRunHash -cne [string]$provenance.runHash) {
        throw 'Review manifest provenance runHash does not match the canonical run descriptor and commit.'
    }

    $ui = $Manifest.uiUnderReview
    if ([string]$ui.surfaceKind -cne 'Observed WPF build') {
        throw "Review manifest uiUnderReview.surfaceKind must be 'Observed WPF build'."
    }
    if ([string]$ui.wpfBuild.assembly -cne 'HerdrOps.App') {
        throw 'Review manifest uiUnderReview.wpfBuild.assembly must be HerdrOps.App.'
    }
    if ([string]$ui.wpfBuild.configuration -notin @('Release', 'Debug')) {
        throw 'Review manifest uiUnderReview.wpfBuild.configuration must be Release or Debug.'
    }
    if (-not (Test-HumanDesignReviewBoundHash -Hash ([string]$ui.wpfBuild.commitSha256))) {
        throw 'Review manifest uiUnderReview.wpfBuild.commitSha256 is unbound.'
    }
    if ($ValidateBindings) {
        Assert-HumanDesignReviewManifestSourceBinding -Manifest $Manifest -ExpectedSourceCommit $ExpectedSourceCommit -ExpectedSourceTree $ExpectedSourceTree | Out-Null
    }
    $uiIdentityPlaceholders = @()
    foreach ($uiFieldValue in @(
            [string]$ui.wpfBuild.branch,
            [string]$ui.hostOs,
            [string]$ui.captureTool.name,
            [string]$ui.captureTool.runtime,
            [string]$ui.captureTool.version,
            [string]$ui.observedWindow)) {
        if (Test-HumanDesignReviewPlaceholder -Text $uiFieldValue) {
            $uiIdentityPlaceholders += $uiFieldValue
        }
    }
    if ($uiIdentityPlaceholders.Count -gt 0) {
        throw 'Review manifest uiUnderReview host/tool/build identity is not fully observed and non-placeholder.'
    }
    if ([int]$ui.hostResolutionWidth -lt 1 -or [int]$ui.hostResolutionHeight -lt 1) {
        throw 'Review manifest uiUnderReview host resolution dimensions must be positive.'
    }
    if ([int]$ui.dpiScaleFactor -notin @(100, 125, 150)) {
        throw 'Review manifest uiUnderReview dpiScaleFactor must be 100, 125, or 150.'
    }
    if ($ui.captureDate -is [datetime]) {
        $captureDate = $ui.captureDate.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ss', [Globalization.CultureInfo]::InvariantCulture) + 'Z'
    } else {
        $captureDate = [string]$ui.captureDate
    }
    if ($captureDate -notmatch '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$') {
        throw 'Review manifest uiUnderReview.captureDate is malformed.'
    }
    if ($captureDate -ge '2030-01-01') {
        throw 'Review manifest uiUnderReview.captureDate is in the future; capture time is falsified.'
    }

    $declarations = $Manifest.declarations
    if ([string]$declarations.preparationBoundary -cne 'PREPARATION/Static-Contract-Synthetic') {
        throw "Review manifest declarations.preparationBoundary must be 'PREPARATION/Static-Contract-Synthetic'."
    }
    if (-not [bool]$declarations.noAcceptedCaptureInPreparation) {
        throw 'Review manifest must declare noAcceptedCaptureInPreparation=true.'
    }

    $captures = @($Manifest.captures)
    $captureRefs = @()
    $seenRefs = @{}
    foreach ($capture in $captures) {
        $relative = [string]$capture.relativePath
        Assert-HumanDesignReviewContainedPath -Root $EvidenceRoot -RelativePath $relative -Context "Review manifest capture '$relative'"
        $relative = $relative.Replace('\', '/')
        if ($seenRefs.ContainsKey($relative)) {
            throw "Review manifest declares duplicate capture '$relative'."
        }
        $seenRefs[$relative] = $true
        $captureRefs += $relative
        if (-not (Test-HumanDesignReviewBoundHash -Hash ([string]$capture.sha256))) {
            throw "Review manifest capture '$relative' has an unbound or forged sha256."
        }
        if ([int]$capture.width -lt 1 -or [int]$capture.height -lt 1) {
            throw "Review manifest capture '$relative' has non-positive dimensions."
        }
        if ([string]$capture.language -notin @('th', 'en')) {
            throw "Review manifest capture '$relative' has an invalid language."
        }
        $kind = [string]$capture.kind
        if ($kind -notin @('page', 'widget-variant', 'dashboard-preview', 'contact-sheet')) {
            throw "Review manifest capture '$relative' has an invalid kind."
        }
        if ($kind -eq 'contact-sheet') {
            if (-not (Test-HumanDesignReviewContactSheetRef -RelativePath $relative)) {
                throw "Review manifest contact-sheet capture '$relative' does not conform to canonical contact-sheet naming."
            }
        }
        if (-not (Test-HumanDesignReviewReferenceEntry -Reference ([string]$capture.refersToReference))) {
            throw "Review manifest capture '$relative' refersToReference '$($capture.refersToReference)' is not a valid docs/design/reference/MANIFEST.md entry."
        }
        if ($ValidateBindings) {
            Assert-HumanDesignReviewReferenceBinding -Reference ([string]$capture.refersToReference) -ValidateBindings
        }
        if ($ValidateBindings -and -not [string]::IsNullOrWhiteSpace($EvidenceRoot)) {
            $onDiskPath = Join-Path $EvidenceRoot ($relative.Replace('/', [IO.Path]::DirectorySeparatorChar.ToString()))
            if (-not (Test-Path -LiteralPath $onDiskPath -PathType Leaf)) {
                throw "Review manifest capture '$relative' is declared but missing on disk at '$EvidenceRoot'."
            }
            $bytes = [IO.File]::ReadAllBytes((Resolve-Path -LiteralPath $onDiskPath).Path)
            $onDiskHash = Get-HumanDesignReviewSha256ForBytes -Bytes $bytes
            if ($onDiskHash -cne ([string]$capture.sha256).ToUpperInvariant()) {
                throw "Review manifest capture '$relative' on-disk SHA-256 does not match the bound hash."
            }
        }
    }

    $canonicalKeys = Get-HumanDesignReviewCanonicalPageCaptureKeys
    $coverage = @{}
    foreach ($capture in $captures) {
        $key = Get-HumanDesignReviewCanonicalPageCaptureKeyForRef -RelativePath ([string]$capture.relativePath)
        if ($null -ne $key) {
            $coverage[$key] = $true
        }
    }
    foreach ($key in $canonicalKeys) {
        if (-not $coverage.ContainsKey($key)) {
            throw "Review manifest is missing required page capture '$key'."
        }
        $expectedRef = Get-HumanDesignReviewCanonicalPageCaptureRefForKey -Key $key
        if ($captureRefs -notcontains $expectedRef) {
            throw "Review manifest is missing required page capture reference '$expectedRef'."
        }
    }

    $canonicalPageRefs = @($canonicalKeys | ForEach-Object {
        Get-HumanDesignReviewCanonicalPageCaptureRefForKey -Key $_
    })
    $pageCaptureRefs = @($captures | Where-Object { $_.kind -eq 'page' } | ForEach-Object {
        [string]$_.relativePath.Replace('\', '/')
    })
    $extraPageRefs = @($pageCaptureRefs | Where-Object {
        $normalized = $_.Replace('\', '/')
        ($normalized -match '^captures/(th|en)/pages/') -and ($canonicalPageRefs -notcontains $normalized)
    })
    if ($extraPageRefs.Count -gt 0) {
        throw "Review manifest declares an unexpected capture beyond the exact canonical $($canonicalPageRefs.Count) page captures: $($extraPageRefs -join ', ')."
    }
    if ($pageCaptureRefs.Count -ne $canonicalPageRefs.Count) {
        throw "Review manifest page capture cardinality must be exactly $($canonicalPageRefs.Count); found $($pageCaptureRefs.Count)."
    }

    $expectedArtifactHash = Get-HumanDesignReviewArtifactHashFromManifest -Manifest $Manifest
    if ($expectedArtifactHash -cne [string]$provenance.artifactHash) {
        throw 'Review manifest provenance artifactHash does not match the declared capture list and hashes.'
    }

    $allowedWidgetRefs = Get-HumanDesignReviewCanonicalWidgetCaptureRefs
    foreach ($capture in $captures) {
        $relative = [string]$capture.relativePath.Replace('\', '/')
        if ($relative.StartsWith('captures/', [StringComparison]::Ordinal) -and
            $relative.Contains('/widgets/') -and
            ($allowedWidgetRefs -notcontains $relative)) {
            throw "Review manifest declares an unexpected widget capture '$relative'."
        }
    }
    $widgetNames = Get-HumanDesignReviewWidgetVariants
    $declaredWidgetRefs = @{}
    foreach ($name in $widgetNames) {
        $declaredWidgetRefs[[string]$Manifest.widgets.$name.capturesRef.Replace('\', '/')] = $true
    }
    $widgetCaptureRefs = @($captures | Where-Object { $_.kind -in @('widget-variant', 'dashboard-preview') } | ForEach-Object {
        [string]$_.relativePath.Replace('\', '/')
    })
    if ($widgetCaptureRefs.Count -ne $declaredWidgetRefs.Count -or
        @($widgetCaptureRefs | Where-Object { -not $declaredWidgetRefs.ContainsKey($_) }).Count -gt 0) {
        throw "Review manifest widget capture cardinality must be exactly the declared widget variant set; found $($widgetCaptureRefs.Count)."
    }

    foreach ($ref in $captureRefs) {
        $normalized = $ref.Replace('\', '/')
        $isPage = ($canonicalPageRefs -contains $normalized)
        $isWidget = ($allowedWidgetRefs -contains $normalized)
        $matchingCapture = @($captures | Where-Object { [string]$_.relativePath.Replace('\', '/') -eq $normalized })
        $isContact = ($matchingCapture.Count -gt 0 -and [string]$matchingCapture[0].kind -eq 'contact-sheet' -and (Test-HumanDesignReviewContactSheetRef -RelativePath $normalized))
        if (-not ($isPage -or $isWidget -or $isContact)) {
            throw "Review manifest declares an unexpected capture '$ref'."
        }
    }

    $widgetObjectNames = @($Manifest.widgets.PSObject.Properties.Name)
    if ($widgetObjectNames.Count -ne $widgetNames.Count) {
        throw 'Review manifest widgets object must declare exactly the approved widget variant set.'
    }
    foreach ($name in $widgetNames) {
        if ($widgetObjectNames -notcontains $name) {
            throw "Review manifest widgets is missing required variant '$name'."
        }
        $widgetReview = $Manifest.widgets.$name
        $widgetRef = [string]$widgetReview.capturesRef.Replace('\', '/')
        if (Test-HumanDesignReviewPlaceholder -Text $widgetRef) {
            throw "Review manifest widget '$name' has no bindable capture reference."
        }
        if ($allowedWidgetRefs -notcontains $widgetRef) {
            throw "Review manifest widget '$name' references a non-canonical widget capture '$widgetRef'."
        }
        if ($captureRefs -notcontains $widgetRef) {
            throw "Review manifest widget '$name' references a capture not declared in captures[]."
        }
        Assert-HumanDesignReviewEvidenceLink -Link $widgetReview.semantics -Context "Widget '$name' semantics"
        if ($widgetReview.sharedStateAccepted -isnot [bool]) {
            throw "Review manifest widget '$name' sharedStateAccepted must be a boolean."
        }
        Assert-HumanDesignReviewEvidenceLink -Link $widgetReview.evidence -Context "Widget '$name' evidence"
        $widgetNotePlaceholder = Test-HumanDesignReviewPlaceholder -Text ([string]$widgetReview.evidence.note)
        if ([bool]$widgetReview.sharedStateAccepted -and $widgetNotePlaceholder) {
            throw "Review manifest widget '$name' asserts shared state without bound evidence (checkbox-only)."
        }
    }

    $pageNames = Get-HumanDesignReviewCanonicalPages
    $pageObjectNames = @($Manifest.pages.PSObject.Properties.Name)
    if ($pageObjectNames.Count -ne $pageNames.Count) {
        throw 'Review manifest pages object must declare exactly the canonical page set.'
    }
    foreach ($pageName in $pageNames) {
        if ($pageObjectNames -notcontains $pageName) {
            throw "Review manifest pages is missing required page '$pageName'."
        }
        $pageReview = $Manifest.pages.$pageName
        $languageCoverage = $pageReview.languageCoverage
        $lcNames = @($languageCoverage.PSObject.Properties.Name)
        if ($lcNames.Count -ne 2 -or $lcNames -notcontains 'th' -or $lcNames -notcontains 'en') {
            throw "Review manifest page '$pageName' must declare th and en language coverage."
        }
        foreach ($language in @('th', 'en')) {
            $perLanguage = $languageCoverage.$language
            $scaleNames = @($perLanguage.PSObject.Properties.Name)
            if ($scaleNames.Count -ne 3) {
                throw "Review manifest page '$pageName' language '$language' must declare 100/125/150 scales."
            }
            foreach ($scale in @(100, 125, 150)) {
                $scaleCapture = $perLanguage."$scale"
                if ([string]::IsNullOrWhiteSpace([string]$scaleCapture.captureRef) -or
                    -not (Test-HumanDesignReviewBoundHash -Hash ([string]$scaleCapture.sha256))) {
                    throw "Review manifest page '$pageName' language '$language' scale $scale is unbound."
                }
                $expectedRef = Get-HumanDesignReviewCanonicalPageCaptureRefForKey -Key ($language + '/' + $pageName + '-' + $scale)
                if ([string]$scaleCapture.captureRef.Replace('\', '/') -cne $expectedRef) {
                    throw "Review manifest page '$pageName' language '$language' scale $scale references a non-canonical capture."
                }
                if ($captureRefs -notcontains [string]$scaleCapture.captureRef.Replace('\', '/')) {
                    throw "Review manifest page '$pageName' language '$language' scale $scale references a capture not declared in captures[]."
                }
            }
        }

        $accessibilityNames = @($pageReview.accessibility.PSObject.Properties.Name)
        foreach ($checkName in @('keyboardFocusVisible', 'focusOrderValid', 'automationNamesPresent',
                'thaiTextNoClipping', 'reducedMotionSupported', 'screenReaderSmoke')) {
            if ($accessibilityNames -notcontains $checkName) {
                throw "Review manifest page '$pageName' accessibility is missing '$checkName'."
            }
            Assert-HumanDesignReviewCheckWithEvidence -Check $pageReview.accessibility.$checkName -Context "Page '$pageName' accessibility '$checkName'"
        }
        if ($accessibilityNames.Count -ne 6) {
            throw "Review manifest page '$pageName' accessibility must contain exactly six checks."
        }

        if ($pageName -eq 'live-organization') {
            $divergence = $pageReview.roleDivergence
            if ($null -eq $divergence -or $divergence.accepts -isnot [bool]) {
                throw 'Review manifest live-organization roleDivergence must declare a boolean acceptance.'
            }
            Assert-HumanDesignReviewEvidenceLink -Link $divergence.evidence -Context 'Live Organization Review-to-Done divergence'
            if ($divergence.accepts -cne [bool]$true) {
                throw 'Review manifest live-organization does not explicitly accept the Review-to-Done divergence.'
            }
        }
    }

    $accessibleEvidence = $Manifest.accessibleEvidence
    $contrastChecks = @($accessibleEvidence.contrastManualChecks)
    if ($contrastChecks.Count -lt 1) {
        throw 'Review manifest accessibleEvidence requires at least one manual contrast check.'
    }
    foreach ($contrast in $contrastChecks) {
        if (Test-HumanDesignReviewPlaceholder -Text ([string]$contrast.label)) {
            throw 'Review manifest contains a placeholder contrast check label.'
        }
        if ([string]$contrast.foreground -notmatch '^#[0-9A-Fa-f]{6}$' -or
            [string]$contrast.background -notmatch '^#[0-9A-Fa-f]{6}$') {
            throw 'Review manifest contrast check colors must be six-digit hex values.'
        }
        if (-not [bool]$contrast.measured) {
            throw 'Review manifest contrast check must be measured, not asserted without measurement.'
        }
        if ([double]$contrast.ratio -le 1.0) {
            throw 'Review manifest contrast ratio must exceed 1.0.'
        }
        if (-not (Test-HumanDesignReviewBoundHash -Hash ([string]$contrast.boundSha256))) {
            throw 'Review manifest contrast check has an unbound boundary hash.'
        }
    }

    $manualSlots = @($accessibleEvidence.manualEvidenceSlots)
    if ($manualSlots.Count -lt 1) {
        throw 'Review manifest accessibleEvidence requires at least one manual evidence slot.'
    }
    foreach ($slot in $manualSlots) {
        $slotObservation = [string]$slot.observation
        $slotTitlePlaceholder = Test-HumanDesignReviewPlaceholder -Text ([string]$slot.title)
        $slotObservationPlaceholder = Test-HumanDesignReviewPlaceholder -Text $slotObservation
        if ($slotTitlePlaceholder -or $slotObservationPlaceholder -or $slotObservation.Length -lt 8) {
            throw 'Review manifest manual evidence slot is empty or placeholder.'
        }
        if (-not (Test-HumanDesignReviewBoundHash -Hash ([string]$slot.boundSha256))) {
            throw 'Review manifest manual evidence slot has an unbound hash.'
        }
    }

    if ($reviewStatus -eq 'Pending') {
        if ([bool]$declarations.humanReviewClaimed -ne $false) {
            throw 'A Pending review manifest must declare humanReviewClaimed=false.'
        }
        if ([string]$declarations.runtimeClaims -cne 'NOT OBSERVED') {
            throw "A Pending review manifest must declare runtimeClaims='NOT OBSERVED'; found '$($declarations.runtimeClaims)'."
        }
        if ([string]$declarations.releaseClaims -cne 'NOT PRODUCED') {
            throw "A Pending review manifest must declare releaseClaims='NOT PRODUCED'; found '$($declarations.releaseClaims)'."
        }
    } elseif ($reviewStatus -in @('Draft', 'Rejected')) {
        if ([bool]$declarations.humanReviewClaimed -ne $false) {
            throw "A $reviewStatus review manifest must declare humanReviewClaimed=false."
        }
        if ([string]$declarations.runtimeClaims -cne 'NOT OBSERVED') {
            throw "A $reviewStatus review manifest must declare runtimeClaims='NOT OBSERVED'."
        }
        if ([string]$declarations.releaseClaims -cne 'NOT PRODUCED') {
            throw "A $reviewStatus review manifest must declare releaseClaims='NOT PRODUCED'."
        }
    } elseif ($reviewStatus -eq 'Accepted') {
        if (-not [bool]$declarations.humanReviewClaimed) {
            throw 'An Accepted review manifest must declare humanReviewClaimed=true.'
        }
        if (-not [bool]$reviewer.independent) {
            throw 'An Accepted review manifest requires an independent reviewer declaration.'
        }
        foreach ($capture in $captures) {
            if (-not (Test-HumanDesignReviewBoundHash -Hash ([string]$capture.sha256))) {
                throw "An Accepted review manifest capture '$($capture.relativePath)' is not bound."
            }
        }
        $runDescriptor = [string]$provenance.canonicalRunDescriptor
        if ($runDescriptor -match 'synthetic|fixture|reconciliation') {
            throw "An Accepted review manifest cannot be bound to a synthetic or fixture run descriptor: '$runDescriptor'."
        }
    }
}

function Read-HumanDesignReviewManifestFile {
    param([Parameter(Mandatory = $true)][string]$Path)

    $fullPath = [IO.Path]::GetFullPath($Path)
    if (-not (Test-Path -LiteralPath $fullPath -PathType Leaf)) {
        throw "Human design review manifest was not found: $fullPath"
    }
    $text = [IO.File]::ReadAllText($fullPath)
    return (ConvertFrom-StrictHumanDesignReviewJson -Json $text -Description "Review manifest '$fullPath'")
}

function Test-HumanDesignReviewManifest {
    param(
        [Parameter(Mandatory = $true)][string]$ManifestPath,
        [string]$EvidenceRoot,
        [switch]$ValidateBindings,
        [string]$ExpectedSourceCommit,
        [string]$ExpectedSourceTree
    )

    $sourcePre = $null
    $expectedSource = $null
    if ($ValidateBindings) {
        $expectedSource = Assert-HumanDesignReviewExpectedSource -ExpectedSourceCommit $ExpectedSourceCommit -ExpectedSourceTree $ExpectedSourceTree
        $sourcePre = Get-HumanDesignReviewGitProvenance -RepoRoot (Get-HumanDesignReviewRoot)
        Assert-HumanDesignReviewGitSnapshot -Snapshot $sourcePre -ExpectedSourceCommit $expectedSource.Commit -ExpectedSourceTree $expectedSource.Tree -Context 'Pre-validation source snapshot'
    }

    $manifest = Read-HumanDesignReviewManifestFile -Path $ManifestPath
    Test-HumanDesignReviewManifestInvariants -Manifest $manifest -EvidenceRoot $EvidenceRoot -ValidateBindings:$ValidateBindings -ExpectedSourceCommit $ExpectedSourceCommit -ExpectedSourceTree $ExpectedSourceTree

    $sourcePost = $null
    if ($ValidateBindings) {
        $sourcePost = Get-HumanDesignReviewGitProvenance -RepoRoot (Get-HumanDesignReviewRoot)
        Assert-HumanDesignReviewGitSnapshot -Snapshot $sourcePost -ExpectedSourceCommit $expectedSource.Commit -ExpectedSourceTree $expectedSource.Tree -Context 'Post-validation source snapshot'
        if ([string]$sourcePre.GitCommit -cne [string]$sourcePost.GitCommit -or
            [string]$sourcePre.GitTree -cne [string]$sourcePost.GitTree -or
            [bool]$sourcePre.WorkingTreeClean -ne [bool]$sourcePost.WorkingTreeClean) {
            throw 'Git source identity or clean working-tree state changed during binding validation.'
        }
    }

    $evidenceClass = if ($ValidateBindings) { 'Static/Contract/Synthetic' } else { 'Static/Contract' }

    return [pscustomobject][ordered]@{
        Valid = $true
        ManifestPath = [IO.Path]::GetFullPath($ManifestPath)
        ReviewStatus = [string]$manifest.reviewStatus
        Issue = [int]$manifest.contract.issue
        Version = [string]$manifest.contract.version
        BoundCommitSha256 = [string]$manifest.provenance.boundCommitSha256
        RunHash = [string]$manifest.provenance.runHash
        ArtifactHash = [string]$manifest.provenance.artifactHash
        PageCaptureCount = @($manifest.captures | Where-Object { $_.kind -eq 'page' }).Count
        BindingsValidated = [bool]$ValidateBindings
        SourceCommit = if ($ValidateBindings) { [string]$sourcePost.GitCommit } else { $null }
        SourceTree = if ($ValidateBindings) { [string]$sourcePost.GitTree } else { $null }
        SourceBindingSha256 = if ($ValidateBindings) { [string]$expectedSource.BindingDigest } else { $null }
        WorkingTreeClean = if ($ValidateBindings) { [bool]$sourcePost.WorkingTreeClean } else { $null }
        EvidenceClass = $evidenceClass
    }
}
