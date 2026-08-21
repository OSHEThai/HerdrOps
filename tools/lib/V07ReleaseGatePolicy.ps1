#requires -Version 5.1

# Issue #40: v0.7 UAT/release-gate preparation policy.
#
# This module validates operator-supplied evidence.  It never creates a human
# decision and it never turns a preparation run into Runtime or Release credit.

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:V07ReleaseGateSchemaVersion = 1
$script:V07ReleaseGateIssue = 40
$script:V07ReleaseGateMaxInputBytes = 256 * 1024
$script:V07ReleaseGateMaxManifestBytes = 2 * 1024 * 1024
$script:V07ReleaseGateMaxEvidenceBytes = 8 * 1024 * 1024
$script:V07ReleaseGateMaxPathLength = 512
$script:V07ReleaseGateMaxStringLength = 4096
$script:V07ReleaseGateRequiredIssues = @(35, 36, 37, 38, 39)
$script:V07ReleaseGateRequiredFollowUp = 'HISTORY_PRESERVING_MERGE_FINAL_ISSUE_39_SUCCESSOR_REGENERATE_REVIEW'

function Get-V07ReleaseGateRepositoryRoot {
    return (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..\..')).Path
}

function Assert-V07ReleaseGateJsonObject {
    param(
        [Parameter(Mandatory = $true)]$Object,
        [Parameter(Mandatory = $true)][string]$Description
    )

    if ($null -eq $Object -or $Object -is [string] -or $Object -is [array] -or $Object -is [ValueType]) {
        throw "$Description must be a JSON object."
    }
}

function Assert-V07ReleaseGateExactProperties {
    param(
        [Parameter(Mandatory = $true)]$Object,
        [Parameter(Mandatory = $true)][string[]]$Names,
        [Parameter(Mandatory = $true)][string]$Description
    )

    Assert-V07ReleaseGateJsonObject -Object $Object -Description $Description
    $actual = @($Object.PSObject.Properties | ForEach-Object { [string]$_.Name })
    if ($actual.Count -ne $Names.Count) {
        throw "$Description has an unknown, missing, or duplicate property."
    }
    foreach ($name in $Names) {
        if (@($actual | Where-Object { $_ -ceq $name }).Count -ne 1) {
            throw "$Description has an unknown, missing, wrongly cased, or duplicate property: $name"
        }
    }
}

function Get-V07ReleaseGateProperty {
    param(
        [Parameter(Mandatory = $true)]$Object,
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][string]$Description,
        [switch]$AllowNull
    )

    $properties = @($Object.PSObject.Properties | Where-Object { $_.Name -ceq $Name })
    if ($properties.Count -ne 1) {
        throw "$Description must contain exactly one '$Name' property."
    }
    if (-not $AllowNull -and $null -eq $properties[0].Value) {
        throw "$Description '$Name' must not be null."
    }
    $value = $properties[0].Value
    if ($value -is [array]) {
        return ,$value
    }
    return $value
}

function Assert-V07ReleaseGateString {
    param(
        [Parameter(Mandatory = $true)]$Value,
        [Parameter(Mandatory = $true)][string]$Description,
        [int]$MaxLength = $script:V07ReleaseGateMaxStringLength,
        [switch]$AllowPending
    )

    if ($Value -isnot [string] -or [string]::IsNullOrWhiteSpace($Value)) {
        throw "$Description must be a non-empty JSON string."
    }
    if ($Value.Length -gt $MaxLength) {
        throw "$Description exceeds the $MaxLength character bound."
    }
    if ($Value.IndexOf([char]0) -ge 0) {
        throw "$Description contains a null character."
    }
    if (-not $AllowPending -and $Value -ceq 'PENDING') {
        throw "$Description cannot be PENDING in an accepted input."
    }
}

function Assert-V07ReleaseGateInteger {
    param(
        [Parameter(Mandatory = $true)]$Value,
        [Parameter(Mandatory = $true)][string]$Description,
        [int]$Minimum = [int]::MinValue,
        [int]$Maximum = [int]::MaxValue
    )

    if ($Value -isnot [byte] -and $Value -isnot [sbyte] -and
        $Value -isnot [int16] -and $Value -isnot [uint16] -and
        $Value -isnot [int32] -and $Value -isnot [uint32] -and
        $Value -isnot [int64] -and $Value -isnot [uint64]) {
        throw "$Description must be an integer JSON number."
    }
    try {
        $number = [int64]$Value
    } catch {
        throw "$Description is outside the supported integer range."
    }
    if ($number -lt $Minimum -or $number -gt $Maximum) {
        throw "$Description is outside the allowed range [$Minimum,$Maximum]."
    }
    return $number
}

function Assert-V07ReleaseGateBoolean {
    param(
        [Parameter(Mandatory = $true)]$Value,
        [Parameter(Mandatory = $true)][string]$Description
    )

    if ($Value -isnot [bool]) {
        throw "$Description must be a JSON boolean."
    }
}

function Assert-V07ReleaseGateHex {
    param(
        [Parameter(Mandatory = $true)]$Value,
        [Parameter(Mandatory = $true)][int]$Length,
        [Parameter(Mandatory = $true)][string]$Description,
        [ValidateSet('Lower', 'Upper', 'Either')][string]$Case = 'Either'
    )

    if ($Value -isnot [string]) {
        throw "$Description must be a hexadecimal string."
    }
    $pattern = switch ($Case) {
        'Lower' { "^[0-9a-f]{$Length}$"; break }
        'Upper' { "^[0-9A-F]{$Length}$"; break }
        default { "^[0-9a-fA-F]{$Length}$"; break }
    }
    if ($Value -cnotmatch $pattern) {
        throw "$Description must be exactly $Length hexadecimal characters with $Case case."
    }
}

function Assert-V07ReleaseGateUtcTimestamp {
    param(
        [Parameter(Mandatory = $true)]$Value,
        [Parameter(Mandatory = $true)][string]$Description,
        [switch]$AllowPending
    )

    if ($AllowPending -and $Value -is [string] -and $Value -ceq 'PENDING') {
        return
    }
    Assert-V07ReleaseGateString -Value $Value -Description $Description
    if ($Value -cnotmatch '^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?Z$') {
        throw "$Description must be an ISO-8601 UTC timestamp ending in Z."
    }
    try {
        $parsed = [DateTimeOffset]::Parse(
            $Value,
            [Globalization.CultureInfo]::InvariantCulture,
            [Globalization.DateTimeStyles]::AssumeUniversal -bor [Globalization.DateTimeStyles]::AdjustToUniversal)
    } catch {
        throw "$Description is not a valid ISO-8601 UTC timestamp."
    }
    if ($parsed.Offset -ne [TimeSpan]::Zero) {
        throw "$Description must have a zero UTC offset."
    }
}

function Assert-V07ReleaseGateSafeRelativePath {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Description
    )

    Assert-V07ReleaseGateString -Value $Path -Description $Description -MaxLength $script:V07ReleaseGateMaxPathLength
    if ([IO.Path]::IsPathRooted($Path) -or
        $Path -match '^[A-Za-z]:[\\/]' -or
        $Path -match '(^|[\\/])\.\.([\\/]|$)' -or
        $Path -match '(^|[\\/])\.([\\/]|$)' -or
        $Path.IndexOfAny([char[]]@('<', '>', ':', '"', '|', '?', '*', [char]0)) -ge 0) {
        throw "$Description must be a safe non-rooted relative path: $Path"
    }

    $segments = @($Path -split '[\\/]')
    if ($segments.Count -eq 0) {
        throw "$Description must contain at least one path segment."
    }
    foreach ($segment in $segments) {
        if ([string]::IsNullOrWhiteSpace($segment) -or $segment -in @('.', '..') -or
            $segment.EndsWith('.') -or $segment.EndsWith(' ') -or
            $segment -match '(?i)^(con|prn|aux|nul|com[1-9]|lpt[1-9])(?:\..*)?$') {
            throw "$Description contains an unsafe path segment: $Path"
        }
    }
}

function Test-V07ReleaseGatePathWithin {
    param(
        [Parameter(Mandatory = $true)][string]$ChildPath,
        [Parameter(Mandatory = $true)][string]$RootPath
    )

    $root = [IO.Path]::GetFullPath($RootPath).TrimEnd([char[]]@('\', '/'))
    $child = [IO.Path]::GetFullPath($ChildPath)
    $prefix = $root + [IO.Path]::DirectorySeparatorChar
    return $child.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase) -or
        $child.Equals($root, [StringComparison]::OrdinalIgnoreCase)
}

function Assert-V07ReleaseGateNoReparseComponents {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Root
    )

    $rootFull = [IO.Path]::GetFullPath($Root)
    $pathFull = [IO.Path]::GetFullPath($Path)
    if (-not (Test-V07ReleaseGatePathWithin -ChildPath $pathFull -RootPath $rootFull)) {
        throw "Path escaped its allowed root: $pathFull"
    }
    if (-not (Test-Path -LiteralPath $rootFull -PathType Container)) {
        throw "Allowed root does not exist as a directory: $rootFull"
    }

    $rootItem = Get-Item -LiteralPath $rootFull -Force
    $ancestor = $rootItem
    while ($null -ne $ancestor) {
        if (($ancestor.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw "A root or ancestor is a reparse point: $($ancestor.FullName)"
        }
        $ancestor = $ancestor.Parent
    }

    $relative = $pathFull.Substring($rootFull.TrimEnd([char[]]@('\', '/')).Length).TrimStart([char[]]@('\', '/'))
    $current = $rootFull.TrimEnd([char[]]@('\', '/'))
    foreach ($segment in @($relative -split '[\\/]')) {
        if ([string]::IsNullOrWhiteSpace($segment)) {
            continue
        }
        $current = Join-Path $current $segment
        if (Test-Path -LiteralPath $current) {
            $item = Get-Item -LiteralPath $current -Force
            if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                throw "A path component is a reparse point: $current"
            }
        }
    }
}

function Resolve-V07ReleaseGateChildPath {
    param(
        [Parameter(Mandatory = $true)][string]$Root,
        [Parameter(Mandatory = $true)][string]$RelativePath,
        [Parameter(Mandatory = $true)][string]$Description,
        [switch]$RequireLeaf
    )

    Assert-V07ReleaseGateSafeRelativePath -Path $RelativePath -Description $Description
    $rootFull = [IO.Path]::GetFullPath($Root)
    $full = [IO.Path]::GetFullPath((Join-Path $rootFull ($RelativePath -replace '/', '\')))
    if (-not (Test-V07ReleaseGatePathWithin -ChildPath $full -RootPath $rootFull) -or
        $full.Equals($rootFull, [StringComparison]::OrdinalIgnoreCase)) {
        throw "$Description escaped its allowed root: $RelativePath"
    }
    Assert-V07ReleaseGateNoReparseComponents -Path $full -Root $rootFull
    if ($RequireLeaf -and -not (Test-Path -LiteralPath $full -PathType Leaf)) {
        throw "$Description is missing or is not a file: $full"
    }
    return $full
}

function Get-V07ReleaseGateSha256FromBytes {
    param([Parameter(Mandatory = $true)][byte[]]$Bytes)

    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        return ([BitConverter]::ToString($sha.ComputeHash($Bytes)).Replace('-', '')).ToUpperInvariant()
    } finally {
        $sha.Dispose()
    }
}

function Get-V07ReleaseGateFileSnapshot {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Description,
        [Parameter(Mandatory = $true)][long]$MaxBytes,
        [string]$Root
    )

    $full = [IO.Path]::GetFullPath($Path)
    if (-not [string]::IsNullOrWhiteSpace($Root)) {
        Assert-V07ReleaseGateNoReparseComponents -Path $full -Root $Root
    } else {
        $itemForAncestors = Get-Item -LiteralPath $full -Force -ErrorAction Stop
        if (($itemForAncestors.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw "$Description must not be a reparse point: $full"
        }
    }
    if (-not (Test-Path -LiteralPath $full -PathType Leaf)) {
        throw "$Description is missing or is not a file: $full"
    }
    $item = Get-Item -LiteralPath $full -Force
    if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw "$Description must not be a reparse point: $full"
    }
    if ($item.Length -le 0 -or $item.Length -gt $MaxBytes) {
        throw "$Description must be non-empty and at most $MaxBytes bytes: $full"
    }

    try {
        $bytes = [IO.File]::ReadAllBytes($full)
    } catch {
        throw "Could not read $Description '$full': $($_.Exception.Message)"
    }
    Assert-V07ReleaseGateNoReparseComponents -Path $full -Root (Split-Path -Path $full -Parent)
    if ($bytes.Length -le 0 -or $bytes.Length -gt $MaxBytes) {
        throw "$Description changed outside its byte bound while being read: $full"
    }
    return [pscustomobject][ordered]@{
        Path = $full
        Bytes = $bytes
        Length = [int64]$bytes.Length
        Sha256 = Get-V07ReleaseGateSha256FromBytes -Bytes $bytes
    }
}

function ConvertFrom-V07ReleaseGateStrictJson {
    param(
        [Parameter(Mandatory = $true)][byte[]]$Bytes,
        [Parameter(Mandatory = $true)][string]$Description
    )

    try {
        $utf8 = [Text.UTF8Encoding]::new($false, $true)
        $json = $utf8.GetString($Bytes)
    } catch {
        throw "$Description is not valid UTF-8: $($_.Exception.Message)"
    }
    if ([string]::IsNullOrWhiteSpace($json)) {
        throw "$Description is empty or whitespace."
    }

    # Reuse the repository's cross-shell strict parser.  It rejects duplicate
    # keys, trailing values, comments, malformed strings, and non-finite JSON.
    if (-not ('HerdrOps.BudgetValidation.StrictJsonValidator' -as [type])) {
        $budgetPolicyPath = Join-Path $PSScriptRoot 'V07PerformanceBudgetPolicy.ps1'
        if (-not (Test-Path -LiteralPath $budgetPolicyPath -PathType Leaf)) {
            throw "The v0.7 strict JSON parser dependency is missing: $budgetPolicyPath"
        }
        . $budgetPolicyPath
    }
    [HerdrOps.BudgetValidation.StrictJsonValidator]::ParseStrict($json, $Description) | Out-Null
    try {
        $convertCommand = Get-Command ConvertFrom-Json -ErrorAction Stop
        if ($convertCommand.Parameters.ContainsKey('DateKind')) {
            return (ConvertFrom-Json -InputObject $json -DateKind String -ErrorAction Stop)
        }
        return (ConvertFrom-Json -InputObject $json -ErrorAction Stop)
    } catch {
        throw "$Description could not be parsed as JSON: $($_.Exception.Message)"
    }
}

function Read-V07ReleaseGateJsonFile {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Description,
        [Parameter(Mandatory = $true)][long]$MaxBytes,
        [string]$Root
    )

    $snapshot = Get-V07ReleaseGateFileSnapshot -Path $Path -Description $Description -MaxBytes $MaxBytes -Root $Root
    $value = ConvertFrom-V07ReleaseGateStrictJson -Bytes $snapshot.Bytes -Description $Description
    return [pscustomobject][ordered]@{
        Value = $value
        Path = $snapshot.Path
        Length = $snapshot.Length
        Sha256 = $snapshot.Sha256
        RawBytes = $snapshot.Bytes
    }
}

function Get-V07ReleaseGateCurrentCandidate {
    param(
        [Parameter(Mandatory = $true)][string]$RepositoryRoot,
        [switch]$AllowDirty
    )

    $commitOutput = @(& git -C $RepositoryRoot rev-parse --verify 'HEAD^{commit}' 2>&1 | ForEach-Object { [string]$_ })
    if ($LASTEXITCODE -ne 0 -or $commitOutput.Count -ne 1 -or $commitOutput[0].Trim() -cnotmatch '^[0-9a-f]{40}$') {
        throw 'Could not resolve one exact committed candidate commit.'
    }
    $treeOutput = @(& git -C $RepositoryRoot rev-parse --verify 'HEAD^{tree}' 2>&1 | ForEach-Object { [string]$_ })
    if ($LASTEXITCODE -ne 0 -or $treeOutput.Count -ne 1 -or $treeOutput[0].Trim() -cnotmatch '^[0-9a-f]{40}$') {
        throw 'Could not resolve one exact candidate tree.'
    }
    $status = @(& git -C $RepositoryRoot status --porcelain=v1 --untracked-files=all 2>&1 | ForEach-Object { [string]$_ })
    if ($LASTEXITCODE -ne 0) {
        throw 'Could not inspect candidate checkout status.'
    }
    if (-not $AllowDirty -and $status.Count -ne 0) {
        throw "The v0.7 release gate requires a clean committed checkout. Pending paths: $($status -join '; ')"
    }
    return [pscustomobject][ordered]@{
        Commit = $commitOutput[0].Trim()
        Tree = $treeOutput[0].Trim()
        WorkingTree = if ($status.Count -eq 0) { 'CLEAN' } else { 'DIRTY' }
        Status = @($status)
    }
}

function Assert-V07ReleaseGateCandidateObject {
    param(
        [Parameter(Mandatory = $true)]$Candidate,
        [Parameter(Mandatory = $true)][string]$Description,
        [Parameter(Mandatory = $true)]$CurrentCandidate
    )

    Assert-V07ReleaseGateExactProperties -Object $Candidate -Names @('commit', 'tree', 'workingTree') -Description $Description
    $commit = Get-V07ReleaseGateProperty -Object $Candidate -Name 'commit' -Description $Description
    $tree = Get-V07ReleaseGateProperty -Object $Candidate -Name 'tree' -Description $Description
    $workingTree = Get-V07ReleaseGateProperty -Object $Candidate -Name 'workingTree' -Description $Description
    Assert-V07ReleaseGateHex -Value $commit -Length 40 -Description "$Description.commit" -Case Lower
    Assert-V07ReleaseGateHex -Value $tree -Length 40 -Description "$Description.tree" -Case Lower
    if ($workingTree -cne 'CLEAN') {
        throw "$Description.workingTree must be exactly CLEAN."
    }
    if ([string]$commit -cne [string]$CurrentCandidate.Commit) {
        throw "$Description.commit is not the current exact candidate commit."
    }
    if ([string]$tree -cne [string]$CurrentCandidate.Tree) {
        throw "$Description.tree is not the current exact candidate tree."
    }
}

function Assert-V07ReleaseGateHistoryPolicy {
    param([Parameter(Mandatory = $true)]$HistoryPolicy)

    Assert-V07ReleaseGateExactProperties -Object $HistoryPolicy -Names @('rebaseAllowed', 'requiredFollowUp') -Description 'historyPolicy'
    $rebaseAllowed = Get-V07ReleaseGateProperty -Object $HistoryPolicy -Name 'rebaseAllowed' -Description 'historyPolicy'
    Assert-V07ReleaseGateBoolean -Value $rebaseAllowed -Description 'historyPolicy.rebaseAllowed'
    if ($rebaseAllowed) {
        throw 'historyPolicy.rebaseAllowed must be false; final rebase is forbidden.'
    }
    $followUp = Get-V07ReleaseGateProperty -Object $HistoryPolicy -Name 'requiredFollowUp' -Description 'historyPolicy'
    if ($followUp -cne $script:V07ReleaseGateRequiredFollowUp) {
        throw 'historyPolicy.requiredFollowUp must require a history-preserving merge of the final Issue #39 successor followed by regeneration and review.'
    }
}

function Assert-V07ReleaseGateHumanUatObject {
    param(
        [Parameter(Mandatory = $true)]$HumanUat,
        [Parameter(Mandatory = $true)]$CurrentCandidate
    )

    Assert-V07ReleaseGateExactProperties -Object $HumanUat -Names @('schemaVersion', 'reportKind', 'issue', 'candidate', 'decision', 'signer', 'role', 'signedAtUtc', 'signature') -Description 'human UAT acceptance'
    $schemaVersion = Get-V07ReleaseGateProperty -Object $HumanUat -Name 'schemaVersion' -Description 'human UAT acceptance'
    if ((Assert-V07ReleaseGateInteger -Value $schemaVersion -Description 'human UAT acceptance.schemaVersion' -Minimum 1 -Maximum 1) -ne 1) {
        throw 'human UAT acceptance.schemaVersion must be 1.'
    }
    if ((Get-V07ReleaseGateProperty -Object $HumanUat -Name 'reportKind' -Description 'human UAT acceptance') -cne 'HerdrOps.V07HumanUatAcceptance') {
        throw 'human UAT acceptance.reportKind is invalid.'
    }
    if ((Assert-V07ReleaseGateInteger -Value (Get-V07ReleaseGateProperty -Object $HumanUat -Name 'issue' -Description 'human UAT acceptance') -Description 'human UAT acceptance.issue' -Minimum 40 -Maximum 40) -ne 40) {
        throw 'human UAT acceptance.issue must be 40.'
    }
    $candidate = Get-V07ReleaseGateProperty -Object $HumanUat -Name 'candidate' -Description 'human UAT acceptance'
    Assert-V07ReleaseGateExactProperties -Object $candidate -Names @('commit', 'tree') -Description 'human UAT acceptance.candidate'
    $candidateCommit = Get-V07ReleaseGateProperty -Object $candidate -Name 'commit' -Description 'human UAT acceptance.candidate'
    $candidateTree = Get-V07ReleaseGateProperty -Object $candidate -Name 'tree' -Description 'human UAT acceptance.candidate'
    Assert-V07ReleaseGateHex -Value $candidateCommit -Length 40 -Description 'human UAT acceptance.candidate.commit' -Case Lower
    Assert-V07ReleaseGateHex -Value $candidateTree -Length 40 -Description 'human UAT acceptance.candidate.tree' -Case Lower
    if ($candidateCommit -cne $CurrentCandidate.Commit -or $candidateTree -cne $CurrentCandidate.Tree) {
        throw 'human UAT acceptance is not bound to the current exact candidate commit and tree.'
    }
    if ((Get-V07ReleaseGateProperty -Object $HumanUat -Name 'decision' -Description 'human UAT acceptance') -cne 'ACCEPTED') {
        throw 'human UAT acceptance.decision must be ACCEPTED; automation cannot create or accept PENDING/APPROVED decisions.'
    }

    $signer = Get-V07ReleaseGateProperty -Object $HumanUat -Name 'signer' -Description 'human UAT acceptance'
    $role = Get-V07ReleaseGateProperty -Object $HumanUat -Name 'role' -Description 'human UAT acceptance'
    $signedAtUtc = Get-V07ReleaseGateProperty -Object $HumanUat -Name 'signedAtUtc' -Description 'human UAT acceptance'
    $signature = Get-V07ReleaseGateProperty -Object $HumanUat -Name 'signature' -Description 'human UAT acceptance'
    Assert-V07ReleaseGateString -Value $signer -Description 'human UAT acceptance.signer'
    Assert-V07ReleaseGateString -Value $role -Description 'human UAT acceptance.role'
    Assert-V07ReleaseGateUtcTimestamp -Value $signedAtUtc -Description 'human UAT acceptance.signedAtUtc'
    Assert-V07ReleaseGateString -Value $signature -Description 'human UAT acceptance.signature'
    if ($signer -ceq 'PENDING' -or $role -ceq 'PENDING' -or $signature -ceq 'PENDING' -or
        $role -match '(?i)^(automation|ci|agent)$') {
        throw 'Human UAT acceptance requires a real human signer, role, date, and signature reference.'
    }
    return [pscustomobject][ordered]@{
        Decision = 'ACCEPTED'
        Signer = $signer
        Role = $role
        SignedAtUtc = $signedAtUtc
        Signature = $signature
    }
}

function Assert-V07ReleaseGateDependencyManifest {
    param(
        [Parameter(Mandatory = $true)]$Manifest,
        [Parameter(Mandatory = $true)][int]$ExpectedIssue,
        [Parameter(Mandatory = $true)]$CurrentCandidate,
        [Parameter(Mandatory = $true)][string]$EvidenceRoot,
        [Parameter(Mandatory = $true)][object]$GlobalEvidencePaths
    )

    Assert-V07ReleaseGateExactProperties -Object $Manifest -Names @('schemaVersion', 'reportKind', 'issue', 'candidate', 'status', 'evidenceClass', 'evidenceFiles', 'humanAcceptance') -Description "Issue #$ExpectedIssue dependency manifest"
    if ((Assert-V07ReleaseGateInteger -Value (Get-V07ReleaseGateProperty -Object $Manifest -Name 'schemaVersion' -Description 'dependency manifest') -Description 'dependency manifest.schemaVersion' -Minimum 1 -Maximum 1) -ne 1) {
        throw 'dependency manifest.schemaVersion must be 1.'
    }
    if ((Get-V07ReleaseGateProperty -Object $Manifest -Name 'reportKind' -Description 'dependency manifest') -cne 'HerdrOps.V07DependencyManifest') {
        throw "Issue #$ExpectedIssue dependency manifest.reportKind is invalid."
    }
    $manifestIssue = Assert-V07ReleaseGateInteger -Value (Get-V07ReleaseGateProperty -Object $Manifest -Name 'issue' -Description 'dependency manifest') -Description 'dependency manifest.issue' -Minimum 35 -Maximum 39
    if ($manifestIssue -ne $ExpectedIssue) {
        throw "Dependency manifest issue $manifestIssue does not match descriptor issue $ExpectedIssue."
    }
    Assert-V07ReleaseGateCandidateObject -Candidate (Get-V07ReleaseGateProperty -Object $Manifest -Name 'candidate' -Description 'dependency manifest') -Description "Issue #$ExpectedIssue dependency candidate" -CurrentCandidate $CurrentCandidate

    $status = Get-V07ReleaseGateProperty -Object $Manifest -Name 'status' -Description 'dependency manifest'
    if ($status -cnotin @('PENDING', 'PASS')) {
        throw "Issue #$ExpectedIssue dependency status must be PENDING or PASS."
    }
    $evidenceClass = Get-V07ReleaseGateProperty -Object $Manifest -Name 'evidenceClass' -Description 'dependency manifest'
    if ($evidenceClass -cnotin @('Static', 'Synthetic', 'Contract', 'Runtime', 'IndependentReview', 'Human', 'Release')) {
        throw "Issue #$ExpectedIssue dependency evidenceClass is invalid."
    }

    $evidenceFiles = Get-V07ReleaseGateProperty -Object $Manifest -Name 'evidenceFiles' -Description 'dependency manifest'
    if ($evidenceFiles -isnot [array]) {
        throw "Issue #$ExpectedIssue dependency evidenceFiles must be an array."
    }
    $evidenceItems = @($evidenceFiles)
    if ($evidenceItems.Count -lt 1 -or $evidenceItems.Count -gt 32) {
        throw "Issue #$ExpectedIssue dependency evidenceFiles must contain 1 to 32 entries."
    }
    $localPaths = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($evidenceFile in $evidenceItems) {
        Assert-V07ReleaseGateExactProperties -Object $evidenceFile -Names @('path', 'sha256') -Description "Issue #$ExpectedIssue dependency evidence file"
        $relativePath = Get-V07ReleaseGateProperty -Object $evidenceFile -Name 'path' -Description 'dependency evidence file'
        Assert-V07ReleaseGateSafeRelativePath -Path $relativePath -Description "Issue #$ExpectedIssue dependency evidence path"
        $fullEvidencePath = Resolve-V07ReleaseGateChildPath -Root $EvidenceRoot -RelativePath $relativePath -Description "Issue #$ExpectedIssue dependency evidence path" -RequireLeaf
        if (-not $localPaths.Add($fullEvidencePath)) {
            throw "Issue #$ExpectedIssue dependency evidence contains a duplicate path: $relativePath"
        }
        if (-not $GlobalEvidencePaths.Add($fullEvidencePath)) {
            throw "Dependency evidence path is duplicated across #35-#39: $relativePath"
        }
        $expectedHash = Get-V07ReleaseGateProperty -Object $evidenceFile -Name 'sha256' -Description 'dependency evidence file'
        Assert-V07ReleaseGateHex -Value $expectedHash -Length 64 -Description "Issue #$ExpectedIssue dependency evidence hash" -Case Upper
        $actual = Get-V07ReleaseGateFileSnapshot -Path $fullEvidencePath -Description "Issue #$ExpectedIssue dependency evidence" -MaxBytes $script:V07ReleaseGateMaxEvidenceBytes -Root $EvidenceRoot
        if ($actual.Sha256 -cne $expectedHash) {
            throw "Issue #$ExpectedIssue dependency evidence hash does not match: $relativePath"
        }
    }

    $human = Get-V07ReleaseGateProperty -Object $Manifest -Name 'humanAcceptance' -Description 'dependency manifest'
    Assert-V07ReleaseGateExactProperties -Object $human -Names @('status', 'signer', 'role', 'signedAtUtc', 'signature') -Description "Issue #$ExpectedIssue dependency human acceptance"
    $humanStatus = Get-V07ReleaseGateProperty -Object $human -Name 'status' -Description 'dependency human acceptance'
    $signer = Get-V07ReleaseGateProperty -Object $human -Name 'signer' -Description 'dependency human acceptance'
    $role = Get-V07ReleaseGateProperty -Object $human -Name 'role' -Description 'dependency human acceptance'
    $signedAt = Get-V07ReleaseGateProperty -Object $human -Name 'signedAtUtc' -Description 'dependency human acceptance'
    $signature = Get-V07ReleaseGateProperty -Object $human -Name 'signature' -Description 'dependency human acceptance'
    if ($humanStatus -ceq 'PENDING') {
        foreach ($pendingField in @(@('signer', $signer), @('role', $role), @('signedAtUtc', $signedAt), @('signature', $signature))) {
            if ($pendingField[1] -cne 'PENDING') {
                throw "Issue #$ExpectedIssue dependency human acceptance.$($pendingField[0]) must remain PENDING until a human acceptance exists."
            }
        }
        if ($status -cne 'PENDING') {
            throw "Issue #$ExpectedIssue dependency status PASS requires human signature, date, and role."
        }
    } elseif ($humanStatus -ceq 'VERIFIED') {
        if ($status -cne 'PASS') {
            throw "Issue #$ExpectedIssue dependency human acceptance VERIFIED requires status PASS."
        }
        Assert-V07ReleaseGateString -Value $signer -Description "Issue #$ExpectedIssue human signer"
        Assert-V07ReleaseGateString -Value $role -Description "Issue #$ExpectedIssue human role"
        Assert-V07ReleaseGateUtcTimestamp -Value $signedAt -Description "Issue #$ExpectedIssue human signedAtUtc"
        Assert-V07ReleaseGateString -Value $signature -Description "Issue #$ExpectedIssue human signature"
        if ($signer -ceq 'PENDING' -or $role -ceq 'PENDING' -or $signature -ceq 'PENDING' -or
            $role -match '(?i)^(automation|ci|agent)$') {
            throw "Issue #$ExpectedIssue dependency human acceptance requires a human signer, date, role, and signature."
        }
    } else {
        throw "Issue #$ExpectedIssue dependency humanAcceptance.status must be PENDING or VERIFIED."
    }

    return [pscustomobject][ordered]@{
        Issue = $ExpectedIssue
        Status = $status
        EvidenceClass = $evidenceClass
        EvidenceCount = $evidenceItems.Count
    }
}

function Test-V07ReleaseGateInput {
    param(
        [Parameter(Mandatory = $true)][string]$InputPath,
        [Parameter(Mandatory = $true)][string]$EvidenceRoot,
        [Parameter(Mandatory = $true)]$CurrentCandidate
    )

    if (-not (Test-Path -LiteralPath $EvidenceRoot -PathType Container)) {
        throw "Dependency evidence root is missing: $EvidenceRoot"
    }
    Assert-V07ReleaseGateNoReparseComponents -Path $EvidenceRoot -Root $EvidenceRoot
    $inputFull = [IO.Path]::GetFullPath($InputPath)
    if (-not (Test-V07ReleaseGatePathWithin -ChildPath $inputFull -RootPath $EvidenceRoot)) {
        throw "Dependency input escaped its evidence root: $inputFull"
    }
    $inputFile = Read-V07ReleaseGateJsonFile -Path $inputFull -Description 'v0.7 Issue #40 dependency evidence input' -MaxBytes $script:V07ReleaseGateMaxInputBytes -Root $EvidenceRoot
    $input = $inputFile.Value
    Assert-V07ReleaseGateExactProperties -Object $input -Names @('schemaVersion', 'reportKind', 'issue', 'candidate', 'dependencies', 'historyPolicy') -Description 'v0.7 Issue #40 dependency evidence input'
    if ((Assert-V07ReleaseGateInteger -Value (Get-V07ReleaseGateProperty -Object $input -Name 'schemaVersion' -Description 'Issue #40 input') -Description 'Issue #40 input.schemaVersion' -Minimum 1 -Maximum 1) -ne 1) {
        throw 'Issue #40 input.schemaVersion must be 1.'
    }
    if ((Get-V07ReleaseGateProperty -Object $input -Name 'reportKind' -Description 'Issue #40 input') -cne 'HerdrOps.V07ReleaseGateInput') {
        throw 'Issue #40 input.reportKind is invalid.'
    }
    if ((Assert-V07ReleaseGateInteger -Value (Get-V07ReleaseGateProperty -Object $input -Name 'issue' -Description 'Issue #40 input') -Description 'Issue #40 input.issue' -Minimum 40 -Maximum 40) -ne 40) {
        throw 'Issue #40 input.issue must be 40.'
    }
    $candidate = Get-V07ReleaseGateProperty -Object $input -Name 'candidate' -Description 'Issue #40 input'
    Assert-V07ReleaseGateCandidateObject -Candidate $candidate -Description 'Issue #40 input.candidate' -CurrentCandidate $CurrentCandidate
    Assert-V07ReleaseGateHistoryPolicy -HistoryPolicy (Get-V07ReleaseGateProperty -Object $input -Name 'historyPolicy' -Description 'Issue #40 input')

    $dependencies = Get-V07ReleaseGateProperty -Object $input -Name 'dependencies' -Description 'Issue #40 input'
    if ($dependencies -isnot [array]) {
        throw 'Issue #40 input.dependencies must be an array.'
    }
    $dependencyItems = @($dependencies)
    if ($dependencyItems.Count -ne $script:V07ReleaseGateRequiredIssues.Count) {
        throw 'Issue #40 input must contain exactly one dependency for each issue #35-#39.'
    }
    $seenIssues = [Collections.Generic.HashSet[int]]::new()
    $seenManifestPaths = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $seenEvidencePaths = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $validated = New-Object System.Collections.ArrayList
    foreach ($dependency in $dependencyItems) {
        Assert-V07ReleaseGateExactProperties -Object $dependency -Names @('issue', 'manifestPath', 'manifestSha256', 'status') -Description 'Issue #40 dependency descriptor'
        $issue = Assert-V07ReleaseGateInteger -Value (Get-V07ReleaseGateProperty -Object $dependency -Name 'issue' -Description 'Issue #40 dependency') -Description 'Issue #40 dependency.issue' -Minimum 35 -Maximum 39
        if (-not $seenIssues.Add([int]$issue)) {
            throw "Issue #40 input contains a duplicate dependency issue: #$issue"
        }
        $manifestRelative = Get-V07ReleaseGateProperty -Object $dependency -Name 'manifestPath' -Description 'Issue #40 dependency'
        Assert-V07ReleaseGateSafeRelativePath -Path $manifestRelative -Description "Issue #$issue manifestPath"
        $manifestFull = Resolve-V07ReleaseGateChildPath -Root $EvidenceRoot -RelativePath $manifestRelative -Description "Issue #$issue manifestPath" -RequireLeaf
        if (-not $seenManifestPaths.Add($manifestFull)) {
            throw "Issue #40 input contains a duplicate manifest path: $manifestRelative"
        }
        $manifestHash = Get-V07ReleaseGateProperty -Object $dependency -Name 'manifestSha256' -Description 'Issue #40 dependency'
        Assert-V07ReleaseGateHex -Value $manifestHash -Length 64 -Description "Issue #$issue manifestSha256" -Case Upper
        $descriptorStatus = Get-V07ReleaseGateProperty -Object $dependency -Name 'status' -Description 'Issue #40 dependency'
        if ($descriptorStatus -cnotin @('PENDING', 'PASS')) {
            throw "Issue #$issue dependency status must be PENDING or PASS."
        }
        $manifestFile = Read-V07ReleaseGateJsonFile -Path $manifestFull -Description "Issue #$issue dependency manifest" -MaxBytes $script:V07ReleaseGateMaxManifestBytes -Root $EvidenceRoot
        if ($manifestFile.Sha256 -cne $manifestHash) {
            throw "Issue #$issue manifestSha256 does not match the manifest bytes."
        }
        $validatedManifest = Assert-V07ReleaseGateDependencyManifest -Manifest $manifestFile.Value -ExpectedIssue $issue -CurrentCandidate $CurrentCandidate -EvidenceRoot $EvidenceRoot -GlobalEvidencePaths $seenEvidencePaths
        if ($validatedManifest.Status -cne $descriptorStatus) {
            throw "Issue #$issue descriptor status does not match the manifest status."
        }
        [void]$validated.Add([pscustomobject][ordered]@{
                Issue = [int]$issue
                Status = [string]$validatedManifest.Status
                EvidenceClass = [string]$validatedManifest.EvidenceClass
                ManifestPath = $manifestRelative.Replace('\', '/')
                ManifestSha256 = [string]$manifestHash
                EvidenceCount = [int]$validatedManifest.EvidenceCount
            })
    }
    foreach ($requiredIssue in $script:V07ReleaseGateRequiredIssues) {
        if (-not $seenIssues.Contains($requiredIssue)) {
            throw "Issue #40 input is missing required dependency #$requiredIssue."
        }
    }
    return [pscustomobject][ordered]@{
        InputPath = $inputFile.Path
        InputSha256 = $inputFile.Sha256
        Candidate = [pscustomobject][ordered]@{
            Commit = [string](Get-V07ReleaseGateProperty -Object $candidate -Name 'commit' -Description 'Issue #40 candidate')
            Tree = [string](Get-V07ReleaseGateProperty -Object $candidate -Name 'tree' -Description 'Issue #40 candidate')
            WorkingTree = 'CLEAN'
        }
        Dependencies = @($validated.ToArray())
        HistoryPolicy = [pscustomobject][ordered]@{
            RebaseAllowed = $false
            RequiredFollowUp = $script:V07ReleaseGateRequiredFollowUp
        }
    }
}

function Read-V07ReleaseGateHumanUat {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$EvidenceRoot,
        [Parameter(Mandatory = $true)]$CurrentCandidate
    )

    $rootFull = [IO.Path]::GetFullPath($EvidenceRoot)
    $fullCandidate = [IO.Path]::GetFullPath($Path)
    if (-not (Test-V07ReleaseGatePathWithin -ChildPath $fullCandidate -RootPath $rootFull) -or
        $fullCandidate.Equals($rootFull, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Human UAT acceptance path escaped its evidence root: $fullCandidate"
    }
    $relative = $fullCandidate.Substring($rootFull.TrimEnd([char[]]@('\', '/')).Length).TrimStart([char[]]@('\', '/'))
    $full = Resolve-V07ReleaseGateChildPath -Root $EvidenceRoot -RelativePath $relative -Description 'human UAT acceptance path' -RequireLeaf
    $file = Read-V07ReleaseGateJsonFile -Path $full -Description 'v0.7 human UAT acceptance' -MaxBytes $script:V07ReleaseGateMaxInputBytes -Root $EvidenceRoot
    $validated = Assert-V07ReleaseGateHumanUatObject -HumanUat $file.Value -CurrentCandidate $CurrentCandidate
    return [pscustomobject][ordered]@{
        Path = $file.Path
        Sha256 = $file.Sha256
        Data = $validated
    }
}

function New-V07ReleaseGatePendingReport {
    param(
        [Parameter(Mandatory = $true)]$ValidatedInput,
        [Parameter(Mandatory = $true)]$CurrentCandidate,
        [bool]$HumanUatValidated = $false
    )

    return [ordered]@{
        schemaVersion = 1
        reportKind = 'HerdrOps.V07ReleaseGateReport'
        issue = 40
        status = 'PENDING'
        generatedAtUtc = [DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ss.fffffffZ', [Globalization.CultureInfo]::InvariantCulture)
        candidate = [ordered]@{
            commit = [string]$CurrentCandidate.Commit
            tree = [string]$CurrentCandidate.Tree
            workingTree = 'CLEAN'
        }
        input = [ordered]@{
            path = [string]$ValidatedInput.InputPath
            sha256 = [string]$ValidatedInput.InputSha256
        }
        dependencyEvidence = @($ValidatedInput.Dependencies | ForEach-Object {
                [ordered]@{
                    issue = [int]$_.Issue
                    status = [string]$_.Status
                    evidenceClass = [string]$_.EvidenceClass
                    manifestPath = [string]$_.ManifestPath
                    manifestSha256 = [string]$_.ManifestSha256
                    evidenceCount = [int]$_.EvidenceCount
                }
            })
        checks = [ordered]@{
            candidateCommitAndTree = 'PASS'
            cleanCheckout = 'PASS'
            dependencyManifests = 'PASS'
            dependencyHashes = 'PASS'
            strictJsonAndBounds = 'PASS'
            containmentAndReparse = 'PASS'
            duplicateAndUnknownFieldRejection = 'PASS'
            humanUat = if ($HumanUatValidated) { 'VALIDATED_INPUT / PENDING' } else { 'PENDING / NOT PROVIDED' }
        }
        humanUat = [ordered]@{
            decision = 'PENDING'
            signer = 'PENDING'
            role = 'PENDING'
            signedAtUtc = 'PENDING'
            signature = 'PENDING'
        }
        historyPolicy = [ordered]@{
            rebaseAllowed = $false
            requiredFollowUp = $script:V07ReleaseGateRequiredFollowUp
        }
        evidenceBoundary = [ordered]@{
            static = 'OBSERVED'
            synthetic = 'NOT OBSERVED BY THIS INVOCATION'
            contract = 'NOT OBSERVED'
            runtime = 'NOT OBSERVED / NOT CLAIMED'
            human = 'PENDING / NOT OBSERVED'
            release = 'NOT OBSERVED / NOT CLAIMED'
        }
        publication = [ordered]@{
            status = 'PENDING'
            tag = 'NOT CREATED'
            release = 'NOT PUBLISHED'
        }
    }
}

function Assert-V07ReleaseGateOutputPath {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string[]]$AllowedRoots
    )

    if ([string]::IsNullOrWhiteSpace($Path)) {
        throw 'The output path must not be empty.'
    }
    $full = [IO.Path]::GetFullPath($Path)
    if ([IO.Path]::GetExtension($full) -cne '.json') {
        throw 'The release-gate output must use the .json extension.'
    }
    foreach ($allowedRoot in $AllowedRoots) {
        if (Test-V07ReleaseGatePathWithin -ChildPath $full -RootPath ([IO.Path]::GetFullPath($allowedRoot))) {
            $parent = Split-Path -Path $full -Parent
            if (-not (Test-Path -LiteralPath $parent -PathType Container)) {
                New-Item -ItemType Directory -Path $parent -Force | Out-Null
            }
            Assert-V07ReleaseGateNoReparseComponents -Path $parent -Root $parent
            if (Test-Path -LiteralPath $full) {
                throw "Refusing to overwrite an existing release-gate report: $full"
            }
            return $full
        }
    }
    throw "Release-gate output escaped all allowed roots: $full"
}

function Write-V07ReleaseGateNewJsonFile {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)]$Value,
        [Parameter(Mandatory = $true)][string[]]$AllowedRoots
    )

    $full = Assert-V07ReleaseGateOutputPath -Path $Path -AllowedRoots $AllowedRoots
    $json = ($Value | ConvertTo-Json -Depth 20) + "`n"
    $bytes = [Text.UTF8Encoding]::new($false).GetBytes($json)
    if ($bytes.Length -gt $script:V07ReleaseGateMaxInputBytes) {
        throw 'The generated release-gate report exceeded its JSON size bound.'
    }
    $parent = Split-Path -Path $full -Parent
    $temp = Join-Path $parent ('.v07-release-gate-' + [Guid]::NewGuid().ToString('N') + '.tmp')
    try {
        $stream = [IO.File]::Open($temp, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
        try {
            $stream.Write($bytes, 0, $bytes.Length)
            $stream.Flush($true)
        } finally {
            $stream.Dispose()
        }
        Assert-V07ReleaseGateNoReparseComponents -Path $temp -Root $parent
        Move-Item -LiteralPath $temp -Destination $full -Force:$false
        return $full
    } finally {
        if (Test-Path -LiteralPath $temp) {
            Remove-Item -LiteralPath $temp -Force
        }
    }
}
