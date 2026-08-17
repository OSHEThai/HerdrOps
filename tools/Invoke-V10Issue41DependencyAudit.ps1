[CmdletBinding()]
param(
    [string]$RepositoryRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')).Path,

    [string]$Repository = 'OSHEThai/HerdrOps',

    [string]$FixturePath,

    [string]$EvidenceManifestPath,

    [string]$OutputDirectory,

    [string]$ObservedUtc,

    [ValidatePattern('^[0-9a-fA-F]{40}$')]
    [string]$ReleaseCandidateCommit,

    [string]$GhExecutable = 'gh'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:AuditBlockers = New-Object System.Collections.ArrayList
$script:AllEvidenceClasses = @(
    'Static',
    'Synthetic',
    'Contract',
    'Integration',
    'Runtime',
    'Independent',
    'Human',
    'Release'
)
$script:RequiredVersions = @(
    'v0.1.0',
    'v0.2.0',
    'v0.3.0',
    'v0.4.0',
    'v0.5.0',
    'v0.6.0',
    'v0.7.0'
)

function Get-PropertyValue {
    param(
        [Parameter(Mandatory)]
        [object]$Object,

        [Parameter(Mandatory)]
        [string]$Name,

        [object]$DefaultValue = $null
    )

    if ($null -ne $Object -and $null -ne $Object.PSObject -and
        @($Object.PSObject.Properties.Name) -contains $Name) {
        return $Object.$Name
    }

    return $DefaultValue
}

function ConvertTo-JsonStringValue {
    param(
        [Parameter(Mandatory)]
        [string]$Json,

        [Parameter(Mandatory)]
        [int]$StartIndex,

        [Parameter(Mandatory)]
        [ref]$EndIndex
    )

    if ($Json[$StartIndex] -ne [char]34) {
        throw "Expected a JSON string at character $StartIndex."
    }

    $builder = New-Object System.Text.StringBuilder
    $index = $StartIndex + 1
    while ($index -lt $Json.Length) {
        $character = $Json[$index]
        if ($character -eq [char]34) {
            $EndIndex.Value = $index
            return $builder.ToString()
        }

        if ([int][char]$character -lt 32) {
            throw "Unescaped control character in JSON string at character $index."
        }

        if ($character -ne [char]92) {
            [void]$builder.Append($character)
            $index++
            continue
        }

        $index++
        if ($index -ge $Json.Length) {
            throw 'JSON string ends after an escape character.'
        }

        $escape = $Json[$index]
        switch ($escape) {
            ([char]34) { [void]$builder.Append([char]34) }
            ([char]92) { [void]$builder.Append([char]92) }
            '/' { [void]$builder.Append('/') }
            'b' { [void]$builder.Append([char]8) }
            'f' { [void]$builder.Append([char]12) }
            'n' { [void]$builder.Append("`n") }
            'r' { [void]$builder.Append("`r") }
            't' { [void]$builder.Append("`t") }
            'u' {
                if ($index + 4 -ge $Json.Length) {
                    throw "Incomplete unicode escape at character $index."
                }

                $hex = $Json.Substring($index + 1, 4)
                if ($hex -notmatch '^[0-9a-fA-F]{4}$') {
                    throw "Invalid unicode escape at character $index."
                }

                [void]$builder.Append([char]([Convert]::ToInt32($hex, 16)))
                $index += 4
            }
            default { throw "Unknown JSON escape '$escape' at character $index." }
        }

        $index++
    }

    throw "JSON string at character $StartIndex is not terminated."
}

function Assert-NoDuplicateJsonObjectKeys {
    param(
        [Parameter(Mandatory)]
        [string]$Json,

        [Parameter(Mandatory)]
        [string]$SourceName
    )

    $objectKeySets = New-Object System.Collections.ArrayList
    $index = 0
    while ($index -lt $Json.Length) {
        $character = $Json[$index]
        if ($character -eq [char]34) {
            $endIndex = 0
            $key = ConvertTo-JsonStringValue -Json $Json -StartIndex $index -EndIndex ([ref]$endIndex)
            $lookahead = $endIndex + 1
            while ($lookahead -lt $Json.Length -and [char]::IsWhiteSpace($Json[$lookahead])) {
                $lookahead++
            }

            if ($lookahead -lt $Json.Length -and $Json[$lookahead] -eq ':' -and $objectKeySets.Count -gt 0) {
                $keys = $objectKeySets[$objectKeySets.Count - 1]
                if (-not $keys.Add($key)) {
                    throw "Duplicate JSON object key '$key' in $SourceName."
                }
            }

            $index = $endIndex + 1
            continue
        }

        if ($character -eq '{') {
            [void]$objectKeySets.Add((New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)))
        }
        elseif ($character -eq '}' -and $objectKeySets.Count -gt 0) {
            $objectKeySets.RemoveAt($objectKeySets.Count - 1)
        }

        $index++
    }

    if ($objectKeySets.Count -ne 0) {
        throw "Unbalanced JSON object delimiters in $SourceName."
    }
}

function Read-StrictJsonFile {
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "JSON input file is missing: $Path"
    }

    $item = Get-Item -LiteralPath $Path -Force
    if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw "JSON input file is a reparse point: $Path"
    }

    $raw = [IO.File]::ReadAllText($item.FullName)
    if ([string]::IsNullOrWhiteSpace($raw)) {
        throw "JSON input file is empty: $Path"
    }

    Assert-NoDuplicateJsonObjectKeys -Json $raw -SourceName $item.FullName
    try {
        $value = $raw | ConvertFrom-Json
    }
    catch {
        throw "Malformed JSON in $($item.FullName): $($_.Exception.Message)"
    }

    return [pscustomobject]@{
        Value = $value
        Raw = $raw
        Sha256 = ((Get-FileHash -LiteralPath $item.FullName -Algorithm SHA256).Hash).ToUpperInvariant()
        FullName = $item.FullName
    }
}

function Get-Sha256ForText {
    param(
        [Parameter(Mandatory)]
        [string]$Text
    )

    $bytes = [Text.Encoding]::UTF8.GetBytes($Text)
    $hash = New-Object Security.Cryptography.SHA256Managed
    try {
        return ([BitConverter]::ToString($hash.ComputeHash($bytes))).Replace('-', '').ToUpperInvariant()
    }
    finally {
        $hash.Dispose()
    }
}

function Get-FullPathUnderRoot {
    param(
        [Parameter(Mandatory)]
        [string]$Path,

        [Parameter(Mandatory)]
        [string]$Root,

        [switch]$RequireRelative,

        [switch]$RejectTraversal
    )

    if ([string]::IsNullOrWhiteSpace($Path)) {
        throw 'A path value is empty.'
    }

    if ($RejectTraversal -and $Path -match '(^|[\\/])\.\.([\\/]|$)') {
        throw "Path traversal is not allowed: $Path"
    }

    if ($RequireRelative -and [IO.Path]::IsPathRooted($Path)) {
        throw "Only repository-relative paths are allowed: $Path"
    }

    $rootFull = [IO.Path]::GetFullPath($Root).TrimEnd([char[]]@([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar))
    $candidate = if ([IO.Path]::IsPathRooted($Path)) { $Path } else { Join-Path $rootFull $Path }
    $full = [IO.Path]::GetFullPath($candidate)
    $prefix = $rootFull + [IO.Path]::DirectorySeparatorChar
    if (-not $full.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Path escapes repository root '$rootFull': $Path"
    }

    $relative = $full.Substring($prefix.Length)
    foreach ($segment in ($relative -split '[\\/]')) {
        if ([string]::IsNullOrWhiteSpace($segment) -or $segment -eq '.' -or $segment -eq '..') {
            throw "Invalid path segment in repository-relative path: $Path"
        }
        if ($segment -match '[<>"|?*]' -or $segment.EndsWith(' ') -or $segment.EndsWith('.')) {
            throw "Unsafe path segment in path: $Path"
        }
    }

    return $full
}

function Assert-NoReparsePathComponent {
    param(
        [Parameter(Mandatory)]
        [string]$Path,

        [Parameter(Mandatory)]
        [string]$Root
    )

    $full = [IO.Path]::GetFullPath($Path)
    $rootFull = [IO.Path]::GetFullPath($Root).TrimEnd([char[]]@([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar))
    $prefix = $rootFull + [IO.Path]::DirectorySeparatorChar
    if (-not $full.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Path is outside the protected root: $Path"
    }

    $relative = $full.Substring($prefix.Length)
    $current = $rootFull
    foreach ($segment in ($relative -split '[\\/]')) {
        if ([string]::IsNullOrWhiteSpace($segment)) { continue }
        $current = Join-Path $current $segment
        if (Test-Path -LiteralPath $current) {
            $item = Get-Item -LiteralPath $current -Force
            if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                throw "Reparse point in protected path: $current"
            }
        }
    }
}

function Resolve-SafeOutputDirectory {
    param(
        [string]$RequestedPath,

        [Parameter(Mandatory)]
        [string]$RepositoryRoot
    )

    $outputRoot = Get-FullPathUnderRoot -Path 'artifacts\dependency-audit' -Root $RepositoryRoot -RequireRelative -RejectTraversal
    $path = if ([string]::IsNullOrWhiteSpace($RequestedPath)) {
        Join-Path $outputRoot ('run-' + [Guid]::NewGuid().ToString('N'))
    }
    elseif ([IO.Path]::IsPathRooted($RequestedPath)) {
        $RequestedPath
    }
    else {
        Join-Path $RepositoryRoot $RequestedPath
    }

    if ($RequestedPath -and $RequestedPath -match '(^|[\\/])\.\.([\\/]|$)') {
        throw "Output path traversal is not allowed: $RequestedPath"
    }

    $full = Get-FullPathUnderRoot -Path $path -Root $RepositoryRoot -RejectTraversal
    $outputPrefix = $outputRoot + [IO.Path]::DirectorySeparatorChar
    if (-not $full.StartsWith($outputPrefix, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Dependency-audit output must remain below '$outputRoot': $full"
    }

    Assert-NoReparsePathComponent -Path $outputRoot -Root $RepositoryRoot
    Assert-NoReparsePathComponent -Path $full -Root $RepositoryRoot
    if (Test-Path -LiteralPath $full -PathType Leaf) {
        throw "Dependency-audit output path is a file: $full"
    }

    if (Test-Path -LiteralPath $full -PathType Container) {
        foreach ($existing in @(Get-ChildItem -LiteralPath $full -Force)) {
            if (($existing.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                throw "Dependency-audit output directory contains a reparse point: $($existing.FullName)"
            }
        }
    }

    return $full
}

function Write-Utf8NoBom {
    param(
        [Parameter(Mandatory)]
        [string]$Path,

        [Parameter(Mandatory)]
        [string]$Content
    )

    $encoding = New-Object System.Text.UTF8Encoding($false)
    [IO.File]::WriteAllText($Path, $Content, $encoding)
}

function Add-Blocker {
    param(
        [Parameter(Mandatory)]
        [string]$Code,

        [string]$Version = '',

        [int]$IssueNumber = 0,

        [Parameter(Mandatory)]
        [string]$Detail
    )

    [void]$script:AuditBlockers.Add([ordered]@{
        Code = $Code
        Version = $Version
        IssueNumber = $IssueNumber
        Detail = $Detail
    })
}

function Invoke-GhApiReadOnly {
    param(
        [Parameter(Mandatory)]
        [string]$Endpoint,

        [Parameter(Mandatory)]
        [string]$Executable
    )

    if (-not (Get-Command $Executable -ErrorAction SilentlyContinue)) {
        throw "GitHub CLI executable is unavailable: $Executable"
    }

    $rawOutput = @(& $Executable api $Endpoint 2>&1 | ForEach-Object { [string]$_ }) -join "`n"
    $exitCode = $LASTEXITCODE
    if ($exitCode -ne 0) {
        throw "GitHub CLI query failed (exit code $exitCode) for '$Endpoint': $rawOutput"
    }
    if ([string]::IsNullOrWhiteSpace($rawOutput)) {
        throw "GitHub CLI returned an empty response for '$Endpoint'."
    }

    Assert-NoDuplicateJsonObjectKeys -Json $rawOutput -SourceName "gh api $Endpoint"
    try {
        $value = $rawOutput | ConvertFrom-Json
    }
    catch {
        throw "GitHub CLI returned malformed JSON for '$Endpoint': $($_.Exception.Message)"
    }

    return [pscustomobject]@{
        Value = $value
        Raw = $rawOutput
        Sha256 = Get-Sha256ForText -Text $rawOutput
        Endpoint = $Endpoint
    }
}

function Get-GitState {
    param(
        [Parameter(Mandatory)]
        [string]$Root
    )

    $commitLines = @(& git -C $Root rev-parse --verify 'HEAD^{commit}' 2>&1 | ForEach-Object { [string]$_ })
    $commitExit = $LASTEXITCODE
    if ($commitExit -ne 0 -or $commitLines.Count -ne 1 -or $commitLines[0].Trim() -notmatch '^[0-9a-fA-F]{40}$') {
        throw "Could not resolve a committed source identity in '$Root'."
    }
    $commit = $commitLines[0].Trim().ToLowerInvariant()

    $statusLines = @(& git -C $Root status --porcelain=v1 --untracked-files=all 2>&1 | ForEach-Object { [string]$_ })
    $statusExit = $LASTEXITCODE
    if ($statusExit -ne 0) {
        throw "Could not inspect the Git working tree in '$Root'."
    }
    if ($statusLines.Count -ne 0) {
        throw "Dependency audit requires a clean committed checkout. Pending paths: $($statusLines -join '; ')"
    }

    return [ordered]@{
        SourceCommit = $commit
        WorkingTree = 'CLEAN'
        StatusLines = @()
    }
}

function Get-VersionConfigurations {
    return [ordered]@{
        'v0.1.0' = [ordered]@{
            MilestoneNumber = 1
            RequiredEvidenceClasses = @('Static', 'Synthetic', 'Human')
            GateScripts = @('tools/Test-V01ReleaseGate.ps1')
        }
        'v0.2.0' = [ordered]@{
            MilestoneNumber = 2
            RequiredEvidenceClasses = @('Contract', 'Runtime')
            GateScripts = @('tools/Test-V02ProtocolContract.ps1', 'tools/Test-V02StateStoreIpc.ps1', 'tools/Test-V02LiveRuntimeAcceptance.ps1')
        }
        'v0.3.0' = [ordered]@{
            MilestoneNumber = 3
            RequiredEvidenceClasses = @('Synthetic', 'Integration', 'Runtime')
            GateScripts = @('tools/Test-V03ActivityPipeline.ps1', 'tools/Test-V03RealtimeActivity.ps1', 'tools/Test-V03FileGitActivity.ps1', 'tools/Test-V03NotificationRuntime.ps1')
        }
        'v0.4.0' = [ordered]@{
            MilestoneNumber = 4
            RequiredEvidenceClasses = @('Synthetic', 'Integration', 'Runtime', 'Independent')
            GateScripts = @('tools/Test-V04ReleaseGate.ps1', 'tools/Test-V04AssignmentLifecycle.ps1', 'tools/Test-V04ExpandedWidget.ps1')
        }
        'v0.5.0' = [ordered]@{
            MilestoneNumber = 5
            RequiredEvidenceClasses = @('Contract', 'Integration', 'Runtime', 'Independent')
            GateScripts = @('tools/Test-V05ComplianceRuleEngine.ps1', 'tools/Test-V05EvidenceAuditStorage.ps1', 'tools/Test-V05ComplianceQueue.ps1')
        }
        'v0.6.0' = [ordered]@{
            MilestoneNumber = 6
            RequiredEvidenceClasses = @('Static', 'Synthetic', 'Contract')
            GateScripts = @('tools/Test-V06TechnicalGate.ps1', 'tools/Test-V06ScoringEngine.ps1', 'tools/Test-V06EvaluationPage.ps1', 'tools/Test-V06DailySummaryPage.ps1', 'tools/Test-V06LocalExport.ps1')
        }
        'v0.7.0' = [ordered]@{
            MilestoneNumber = 7
            RequiredEvidenceClasses = @('Runtime', 'Independent', 'Human', 'Release')
            GateScripts = @('tools/Test-VersionMilestone.ps1')
        }
    }
}

function Get-TrackingDefinitions {
    param(
        [Parameter(Mandatory)]
        [string]$TrackingText
    )

    $definitions = [ordered]@{}
    $pattern = '(?m)^\|\s*(v\d+\.\d+\.\d+)\s*\|\s*\[Milestone\s+(\d+)\]\([^)]*\)\s*\|\s*(\d+)\s*\|\s*\[#(\d+)\]\([^)]*\)\s*\|'
    foreach ($match in [Regex]::Matches($TrackingText, $pattern)) {
        $version = $match.Groups[1].Value
        if ($definitions.Contains($version)) {
            throw "Duplicate release-tracker row for $version in Plan/GITHUB-TRACKING.md."
        }
        $definitions[$version] = [ordered]@{
            Version = $version
            MilestoneNumber = [int]$match.Groups[2].Value
            WorkIssueCount = [int]$match.Groups[3].Value
            ReleaseTrackerIssue = [int]$match.Groups[4].Value
        }
    }

    foreach ($version in $script:RequiredVersions) {
        if (-not $definitions.Contains($version)) {
            throw "Plan/GITHUB-TRACKING.md has no release-tracker row for $version."
        }
    }

    return $definitions
}

function Test-HashValue {
    param(
        [object]$Value
    )

    return ($null -ne $Value -and ([string]$Value) -match '^[0-9a-fA-F]{64}$')
}

function Get-PlanTruth {
    param(
        [Parameter(Mandatory)]
        [string]$Root
    )

    $roadmapPath = Join-Path $Root 'Plan\github-roadmap.json'
    $trackingPath = Join-Path $Root 'Plan\GITHUB-TRACKING.md'
    $releaseGatesPath = Join-Path $Root 'Plan\RELEASE-GATES.md'
    foreach ($path in @($roadmapPath, $trackingPath, $releaseGatesPath)) {
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
            throw "Plan truth file is missing: $path"
        }
    }

    $roadmap = Read-StrictJsonFile -Path $roadmapPath
    $trackingText = [IO.File]::ReadAllText($trackingPath)
    $releaseGatesText = [IO.File]::ReadAllText($releaseGatesPath)
    $tracking = Get-TrackingDefinitions -TrackingText $trackingText
    $versions = Get-VersionConfigurations
    $roadmapIssues = New-Object System.Collections.ArrayList
    $roadmapKeys = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
    foreach ($milestone in @($roadmap.Value.milestones)) {
        foreach ($issue in @($milestone.issues)) {
            $key = [string](Get-PropertyValue -Object $issue -Name 'key' -DefaultValue '')
            if ([string]::IsNullOrWhiteSpace($key) -or -not $roadmapKeys.Add($key)) {
                throw "Plan/github-roadmap.json contains a missing or duplicate issue key: $key"
            }
            [void]$roadmapIssues.Add([ordered]@{
                Key = $key
                Version = [string]$milestone.title
                Title = [string](Get-PropertyValue -Object $issue -Name 'title' -DefaultValue '')
                EvidenceHints = @((Get-PropertyValue -Object $issue -Name 'evidence' -DefaultValue @()))
            })
        }
    }

    foreach ($version in $script:RequiredVersions) {
        if ($tracking[$version].MilestoneNumber -ne $versions[$version].MilestoneNumber) {
            throw "Milestone mismatch between Plan/GITHUB-TRACKING.md and the dependency-audit contract for $version."
        }
    }

    $gatePaths = [ordered]@{}
    foreach ($version in $script:RequiredVersions) {
        $paths = @('tools/Test-VersionMilestone.ps1', 'Plan/RELEASE-GATES.md') + @($versions[$version].GateScripts)
        $normalized = @($paths | ForEach-Object { $_.Replace('\', '/') } | Sort-Object -Unique)
        foreach ($relativePath in $normalized) {
            $fullPath = Get-FullPathUnderRoot -Path $relativePath -Root $Root -RequireRelative -RejectTraversal
            if (-not (Test-Path -LiteralPath $fullPath -PathType Leaf)) {
                throw "Local version gate is missing for ${version}: $relativePath"
            }
        }
        $gatePaths[$version] = $normalized
    }

    $planHashMap = [ordered]@{}
    foreach ($path in @($roadmapPath, $trackingPath, $releaseGatesPath)) {
        $relative = $path.Substring($Root.Length).TrimStart([char[]]@([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)).Replace('\', '/')
        $planHashMap[$relative] = ((Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash).ToUpperInvariant()
    }

    return [ordered]@{
        RoadmapIssues = @($roadmapIssues.ToArray() | Sort-Object Version, Key)
        Tracking = $tracking
        Versions = $versions
        GatePaths = $gatePaths
        Files = [ordered]@{
            Roadmap = 'Plan/github-roadmap.json'
            Tracking = 'Plan/GITHUB-TRACKING.md'
            ReleaseGates = 'Plan/RELEASE-GATES.md'
        }
        Hashes = $planHashMap
        ReleaseGatesTextSha256 = Get-Sha256ForText -Text $releaseGatesText
    }
}

function Get-IssueKeyFromBody {
    param(
        [object]$Issue
    )

    $body = [string](Get-PropertyValue -Object $Issue -Name 'body' -DefaultValue '')
    $match = [Regex]::Match($body, '(?im)^<!--\s*herdr-issue-key:\s*([A-Za-z0-9._-]+)\s*-->')
    if ($match.Success) {
        return $match.Groups[1].Value
    }
    return ''
}

function Get-GitHubSnapshot {
    param(
        [Parameter(Mandatory)]
        [string]$RepositoryName,

        [string]$OfflineFixture,

        [Parameter(Mandatory)]
        [string]$GhCommand
    )

    if (-not [string]::IsNullOrWhiteSpace($OfflineFixture)) {
        $fixture = Read-StrictJsonFile -Path $OfflineFixture
        $milestones = Get-PropertyValue -Object $fixture.Value -Name 'milestones' -DefaultValue $null
        $issues = Get-PropertyValue -Object $fixture.Value -Name 'issues' -DefaultValue $null
        if ($null -eq $milestones -or $null -eq $issues) {
            throw 'Offline dependency-audit fixture must contain milestones and issues arrays.'
        }

        return [ordered]@{
            Mode = 'OfflineFixture'
            Repository = $RepositoryName
            Milestones = @($milestones)
            Issues = @($issues)
            Query = [ordered]@{
                Source = 'OfflineFixture'
                FixturePath = $fixture.FullName
                FixtureSha256 = $fixture.Sha256
                Endpoint = ''
                ResponseSha256 = $fixture.Sha256
            }
        }
    }

    $milestoneResponse = Invoke-GhApiReadOnly -Endpoint ("repos/{0}/milestones?state=all&per_page=100" -f $RepositoryName) -Executable $GhCommand
    $issueResponse = Invoke-GhApiReadOnly -Endpoint ("repos/{0}/issues?state=all&per_page=100" -f $RepositoryName) -Executable $GhCommand
    return [ordered]@{
        Mode = 'GitHub'
        Repository = $RepositoryName
        Milestones = @($milestoneResponse.Value)
        Issues = @($issueResponse.Value)
        Query = [ordered]@{
            Source = 'GitHub gh api (read-only)'
            FixturePath = ''
            FixtureSha256 = ''
            Endpoint = @($milestoneResponse.Endpoint, $issueResponse.Endpoint)
            ResponseSha256 = @($milestoneResponse.Sha256, $issueResponse.Sha256)
        }
    }
}

function New-TargetIssueMap {
    param(
        [Parameter(Mandatory)]
        [object[]]$Issues
    )

    $target = @($Issues | Where-Object { [int](Get-PropertyValue -Object $_ -Name 'number' -DefaultValue 0) -eq 41 })
    if ($target.Count -ne 1) {
        Add-Blocker -Code 'TARGET_ISSUE_MISSING_OR_DUPLICATE' -IssueNumber 41 -Detail "Expected exactly one GitHub issue #41 in the query result; found $($target.Count)."
        return [ordered]@{ Number = 41; Title = ''; Version = 'v1.0.0'; MilestoneNumber = 8; State = 'UNKNOWN' }
    }

    $issue = $target[0]
    $title = [string](Get-PropertyValue -Object $issue -Name 'title' -DefaultValue '')
    $milestone = Get-PropertyValue -Object $issue -Name 'milestone' -DefaultValue $null
    $milestoneTitle = [string](Get-PropertyValue -Object $milestone -Name 'title' -DefaultValue '')
    $milestoneNumber = [int](Get-PropertyValue -Object $milestone -Name 'number' -DefaultValue 0)
    $state = ([string](Get-PropertyValue -Object $issue -Name 'state' -DefaultValue 'unknown')).ToUpperInvariant()
    if ($title -cne '[v1.0.0] Close release blockers and audit all dependency evidence' -or
        $milestoneTitle -cne 'v1.0.0' -or $milestoneNumber -ne 8) {
        Add-Blocker -Code 'TARGET_ISSUE_WRONG_MILESTONE_OR_TITLE' -IssueNumber 41 -Detail "Issue #41 must be the v1.0.0 dependency-audit issue; observed title='$title', milestone='$milestoneTitle'#$milestoneNumber."
    }

    return [ordered]@{
        Number = 41
        Title = $title
        Version = 'v1.0.0'
        MilestoneNumber = $milestoneNumber
        State = $state
        Url = [string](Get-PropertyValue -Object $issue -Name 'html_url' -DefaultValue (Get-PropertyValue -Object $issue -Name 'url' -DefaultValue ''))
    }
}

function New-DependencyAuditData {
    param(
        [Parameter(Mandatory)]
        [hashtable]$PlanTruth,

        [Parameter(Mandatory)]
        [hashtable]$GitHubSnapshot
    )

    $milestones = @($GitHubSnapshot.Milestones)
    $issues = @($GitHubSnapshot.Issues)
    $milestoneNumbers = New-Object 'System.Collections.Generic.HashSet[int]'
    $milestoneTitles = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
    foreach ($milestone in $milestones) {
        $number = [int](Get-PropertyValue -Object $milestone -Name 'number' -DefaultValue 0)
        $title = [string](Get-PropertyValue -Object $milestone -Name 'title' -DefaultValue '')
        if ($number -le 0 -or -not $milestoneNumbers.Add($number) -or -not $milestoneTitles.Add($title)) {
            Add-Blocker -Code 'DUPLICATE_OR_INVALID_MILESTONE' -Detail "Milestone number/title is missing or duplicated: #$number '$title'."
        }
    }

    $issueNumbers = New-Object 'System.Collections.Generic.HashSet[int]'
    $issueKeys = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
    $validIssues = New-Object System.Collections.ArrayList
    foreach ($issue in $issues) {
        $number = [int](Get-PropertyValue -Object $issue -Name 'number' -DefaultValue 0)
        if ($number -le 0 -or -not $issueNumbers.Add($number)) {
            Add-Blocker -Code 'DUPLICATE_OR_INVALID_ISSUE_NUMBER' -IssueNumber $number -Detail "GitHub issue number is missing or duplicated: $number."
            continue
        }

        $key = Get-IssueKeyFromBody -Issue $issue
        if (-not [string]::IsNullOrWhiteSpace($key) -and -not $issueKeys.Add($key)) {
            Add-Blocker -Code 'DUPLICATE_ISSUE_KEY' -IssueNumber $number -Detail "GitHub issue key '$key' is duplicated."
        }

        if (@($issue.PSObject.Properties.Name) -contains 'pull_request') {
            continue
        }

        [void]$validIssues.Add($issue)
    }

    $target = New-TargetIssueMap -Issues @($validIssues)
    $dependencyIssues = New-Object System.Collections.ArrayList
    $map = New-Object System.Collections.ArrayList
    foreach ($version in $script:RequiredVersions) {
        $config = $PlanTruth.Versions[$version]
        $tracking = $PlanTruth.Tracking[$version]
        $milestone = @($milestones | Where-Object {
            [int](Get-PropertyValue -Object $_ -Name 'number' -DefaultValue 0) -eq $config.MilestoneNumber
        })
        if ($milestone.Count -ne 1) {
            Add-Blocker -Code 'MISSING_OR_DUPLICATE_MILESTONE' -Version $version -Detail "Expected exactly one milestone #$($config.MilestoneNumber) for $version; found $($milestone.Count)."
            continue
        }

        $milestoneTitle = [string](Get-PropertyValue -Object $milestone[0] -Name 'title' -DefaultValue '')
        if ($milestoneTitle -cne $version) {
            Add-Blocker -Code 'MILESTONE_VERSION_MISMATCH' -Version $version -Detail "Milestone #$($config.MilestoneNumber) is '$milestoneTitle', expected '$version'."
        }
        $milestoneState = ([string](Get-PropertyValue -Object $milestone[0] -Name 'state' -DefaultValue 'unknown')).ToUpperInvariant()
        if ($milestoneState -ne 'CLOSED') {
            Add-Blocker -Code 'MILESTONE_OPEN' -Version $version -Detail "Milestone #$($config.MilestoneNumber) '$version' is $milestoneState."
        }

        $versionIssues = @($validIssues | Where-Object {
            $m = Get-PropertyValue -Object $_ -Name 'milestone' -DefaultValue $null
            $mNumber = [int](Get-PropertyValue -Object $m -Name 'number' -DefaultValue 0)
            $mTitle = [string](Get-PropertyValue -Object $m -Name 'title' -DefaultValue '')
            $mNumber -eq $config.MilestoneNumber -or $mTitle -eq $version
        })
        foreach ($issue in $versionIssues) {
            $issueMilestone = Get-PropertyValue -Object $issue -Name 'milestone' -DefaultValue $null
            $issueMilestoneNumber = [int](Get-PropertyValue -Object $issueMilestone -Name 'number' -DefaultValue 0)
            $issueMilestoneTitle = [string](Get-PropertyValue -Object $issueMilestone -Name 'title' -DefaultValue '')
            if ($issueMilestoneNumber -ne $config.MilestoneNumber -or $issueMilestoneTitle -cne $version) {
                Add-Blocker -Code 'ISSUE_WRONG_MILESTONE_OR_VERSION' -Version $version -IssueNumber ([int]$issue.number) -Detail "Issue #$($issue.number) is attached to milestone '$issueMilestoneTitle'#$issueMilestoneNumber, expected '$version'#$($config.MilestoneNumber)."
            }
        }

        $trackerTitle = "[$version] Release readiness tracker"
        $trackerIssues = @($versionIssues | Where-Object { [string]$_.title -ceq $trackerTitle })
        if ($trackerIssues.Count -ne 1 -or [int]$tracking.ReleaseTrackerIssue -ne [int]$trackerIssues[0].number) {
            $observed = if ($trackerIssues.Count -eq 0) { 'none' } else { ($trackerIssues | ForEach-Object { "#$($_.number)" }) -join ', ' }
            Add-Blocker -Code 'RELEASE_TRACKER_MISMATCH' -Version $version -Detail "Plan expects tracker #$($tracking.ReleaseTrackerIssue) for $version; observed $observed."
        }

        $workIssues = @($versionIssues | Where-Object { [string]$_.title -cne $trackerTitle })
        if ($workIssues.Count -ne [int]$tracking.WorkIssueCount) {
            Add-Blocker -Code 'WORK_ISSUE_COUNT_MISMATCH' -Version $version -Detail "Plan expects $($tracking.WorkIssueCount) work issues in $version; GitHub returned $($workIssues.Count)."
        }

        $planIssues = @($PlanTruth.RoadmapIssues | Where-Object { $_.Version -eq $version })
        foreach ($planIssue in $planIssues) {
            $matching = @($workIssues | Where-Object { [string]$_.title -ceq [string]$planIssue.Title })
            if ($matching.Count -ne 1) {
                Add-Blocker -Code 'MISSING_OR_DUPLICATE_PLAN_ISSUE' -Version $version -Detail "Plan issue $($planIssue.Key) '$($planIssue.Title)' matched $($matching.Count) GitHub issues."
            }
        }

        foreach ($issue in $versionIssues) {
            $issueNumber = [int]$issue.number
            $title = [string]$issue.title
            $state = ([string](Get-PropertyValue -Object $issue -Name 'state' -DefaultValue 'unknown')).ToUpperInvariant()
            $isTracker = $title -ceq $trackerTitle
            $roadmapMatch = @($PlanTruth.RoadmapIssues | Where-Object { $_.Version -eq $version -and $_.Title -ceq $title })
            $record = [ordered]@{
                Version = $version
                MilestoneNumber = $config.MilestoneNumber
                MilestoneTitle = $milestoneTitle
                IssueNumber = $issueNumber
                Title = $title
                State = $state
                IsReleaseTracker = $isTracker
                RoadmapKey = if ($roadmapMatch.Count -eq 1) { $roadmapMatch[0].Key } else { '' }
                RoadmapMapping = if ($roadmapMatch.Count -eq 1) { 'Plan/github-roadmap.json' } else { 'Plan/GITHUB-TRACKING.md supplemental milestone inventory' }
                ReleaseTrackerIssue = [int]$tracking.ReleaseTrackerIssue
                ReleaseTrackerUrl = "https://github.com/OSHEThai/HerdrOps/issues/$($tracking.ReleaseTrackerIssue)"
                LocalReleaseTracker = 'Plan/GITHUB-TRACKING.md'
                LocalGatePlan = 'Plan/RELEASE-GATES.md'
                LocalGateVerifier = 'tools/Test-VersionMilestone.ps1'
                LocalGateScripts = @($PlanTruth.GatePaths[$version])
                GitHubUrl = [string](Get-PropertyValue -Object $issue -Name 'html_url' -DefaultValue (Get-PropertyValue -Object $issue -Name 'url' -DefaultValue "https://github.com/OSHEThai/HerdrOps/issues/$issueNumber"))
            }
            [void]$map.Add($record)
            [void]$dependencyIssues.Add($record)
            if ($state -eq 'OPEN') {
                Add-Blocker -Code 'GITHUB_OPEN_DEPENDENCY' -Version $version -IssueNumber $issueNumber -Detail "Issue #$issueNumber remains open: $title ($($record.GitHubUrl))."
            }
            elseif ($state -ne 'CLOSED') {
                Add-Blocker -Code 'GITHUB_UNKNOWN_ISSUE_STATE' -Version $version -IssueNumber $issueNumber -Detail "Issue #$issueNumber has unsupported state '$state'."
            }
        }
    }

    return [ordered]@{
        TargetIssue = $target
        Issues = @($dependencyIssues.ToArray() | Sort-Object Version, IssueNumber)
        Map = @($map.ToArray() | Sort-Object Version, IssueNumber)
    }
}

function Get-EvidenceManifestEntries {
    param(
        [string]$ManifestPath,

        [Parameter(Mandatory)]
        [string]$RepositoryRoot,

        [Parameter(Mandatory)]
        [string]$SourceCommit,

        [Parameter(Mandatory)]
        [hashtable]$PlanTruth,

        [Parameter(Mandatory)]
        [string]$QueryMode
    )

    if ([string]::IsNullOrWhiteSpace($ManifestPath)) {
        foreach ($version in $script:RequiredVersions) {
            Add-Blocker -Code 'MISSING_GATE_REPORT' -Version $version -IssueNumber ([int]$PlanTruth.Tracking[$version].ReleaseTrackerIssue) -Detail "No evidence manifest was supplied; expected a version-local gate report and SHA-256 binding under artifacts/release-gates/$version/."
        }
        return [ordered]@{
            Source = 'No manifest; no evidence admitted'
            ManifestSha256 = ''
            ManifestPath = ''
            Entries = @()
        }
    }

    $manifest = Read-StrictJsonFile -Path $ManifestPath
    $schemaVersion = [int](Get-PropertyValue -Object $manifest.Value -Name 'schemaVersion' -DefaultValue 0)
    if ($schemaVersion -ne 1) {
        throw "Unsupported dependency-audit evidence manifest schemaVersion: $schemaVersion"
    }
    $manifestCommit = ([string](Get-PropertyValue -Object $manifest.Value -Name 'sourceCommit' -DefaultValue '')).ToLowerInvariant()
    if ($manifestCommit -cne $SourceCommit) {
        Add-Blocker -Code 'EVIDENCE_MANIFEST_COMMIT_MISMATCH' -Detail "Evidence manifest sourceCommit '$manifestCommit' does not match audit source commit '$SourceCommit'."
    }

    $entriesValue = Get-PropertyValue -Object $manifest.Value -Name 'entries' -DefaultValue $null
    if ($null -eq $entriesValue) {
        throw 'Evidence manifest must contain an entries array.'
    }

    $entries = New-Object System.Collections.ArrayList
    $entryKeys = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
    foreach ($entry in @($entriesValue)) {
        $version = [string](Get-PropertyValue -Object $entry -Name 'version' -DefaultValue '')
        $gateId = [string](Get-PropertyValue -Object $entry -Name 'gateId' -DefaultValue '')
        $entryKey = "$version|$gateId"
        if ([string]::IsNullOrWhiteSpace($version) -or [string]::IsNullOrWhiteSpace($gateId) -or -not $entryKeys.Add($entryKey)) {
            throw "Evidence manifest has a missing or duplicate entry key: $entryKey"
        }
        if ($script:RequiredVersions -notcontains $version) {
            throw "Evidence manifest contains unsupported dependency version: $version"
        }

        $expectedTracker = [int]$PlanTruth.Tracking[$version].ReleaseTrackerIssue
        $issueNumber = [int](Get-PropertyValue -Object $entry -Name 'issueNumber' -DefaultValue 0)
        if ($issueNumber -ne $expectedTracker) {
            Add-Blocker -Code 'EVIDENCE_WRONG_TRACKER' -Version $version -IssueNumber $issueNumber -Detail "Evidence gate entry must bind release tracker #$expectedTracker, observed #$issueNumber."
        }

        $reportPath = [string](Get-PropertyValue -Object $entry -Name 'reportPath' -DefaultValue '')
        $reportFullPath = Get-FullPathUnderRoot -Path $reportPath -Root $RepositoryRoot -RequireRelative -RejectTraversal
        Assert-NoReparsePathComponent -Path $reportFullPath -Root $RepositoryRoot
        if (-not (Test-Path -LiteralPath $reportFullPath -PathType Leaf)) {
            Add-Blocker -Code 'MISSING_GATE_REPORT' -Version $version -IssueNumber $issueNumber -Detail "Gate report is missing: $reportPath"
        }

        $reportHash = [string](Get-PropertyValue -Object $entry -Name 'reportSha256' -DefaultValue '')
        if (-not (Test-HashValue -Value $reportHash)) {
            Add-Blocker -Code 'MISSING_GATE_HASH' -Version $version -IssueNumber $issueNumber -Detail "Gate report SHA-256 is missing or malformed for $reportPath."
        }
        elseif (Test-Path -LiteralPath $reportFullPath -PathType Leaf) {
            $observedHash = ((Get-FileHash -LiteralPath $reportFullPath -Algorithm SHA256).Hash).ToUpperInvariant()
            if ($reportHash.ToUpperInvariant() -cne $observedHash) {
                Add-Blocker -Code 'GATE_REPORT_HASH_MISMATCH' -Version $version -IssueNumber $issueNumber -Detail "Gate report hash mismatch for ${reportPath}: expected $reportHash observed $observedHash."
            }
        }

        $entryCommit = ([string](Get-PropertyValue -Object $entry -Name 'sourceCommit' -DefaultValue '')).ToLowerInvariant()
        if ($entryCommit -cne $SourceCommit) {
            Add-Blocker -Code 'STALE_EVIDENCE_COMMIT' -Version $version -IssueNumber $issueNumber -Detail "Evidence entry sourceCommit '$entryCommit' does not match '$SourceCommit'."
        }

        $statusesObject = Get-PropertyValue -Object $entry -Name 'statuses' -DefaultValue $null
        if ($null -eq $statusesObject) {
            throw "Evidence entry $entryKey has no statuses object."
        }
        $statusNames = @($statusesObject.PSObject.Properties.Name)
        foreach ($className in $script:AllEvidenceClasses) {
            if ($statusNames -notcontains $className) {
                throw "Evidence entry $entryKey is missing status for evidence class $className."
            }
            $status = ([string]$statusesObject.$className).ToUpperInvariant()
            if (@('PASS', 'NOT_OBSERVED', 'BLOCKED', 'FAIL', 'NOT_APPLICABLE') -notcontains $status) {
                throw "Evidence entry $entryKey has unsupported $className status '$status'."
            }
        }
        foreach ($statusName in $statusNames) {
            if ($script:AllEvidenceClasses -notcontains $statusName) {
                throw "Evidence entry $entryKey contains unknown evidence class '$statusName'."
            }
        }

        $sourcePaths = @((Get-PropertyValue -Object $entry -Name 'sourcePaths' -DefaultValue @()))
        if ($sourcePaths -contains 'tests/HerdrOps.RuntimeTests' -and ([string]$statusesObject.Runtime).ToUpperInvariant() -eq 'PASS') {
            Add-Blocker -Code 'SYNTHETIC_WPF_RUNTIME_CONFLATION' -Version $version -IssueNumber $issueNumber -Detail 'tests/HerdrOps.RuntimeTests is Synthetic WPF evidence and cannot satisfy Runtime.'
        }

        $artifacts = @((Get-PropertyValue -Object $entry -Name 'artifacts' -DefaultValue @()))
        $releaseStatus = ([string]$statusesObject.Release).ToUpperInvariant()
        if ($releaseStatus -eq 'PASS' -and $artifacts.Count -eq 0) {
            Add-Blocker -Code 'MISSING_RELEASE_ARTIFACT_HASH' -Version $version -IssueNumber $issueNumber -Detail 'Release PASS requires at least one exact artifact path, sourceCommit, and SHA-256.'
        }
        foreach ($artifact in $artifacts) {
            $artifactPath = [string](Get-PropertyValue -Object $artifact -Name 'path' -DefaultValue '')
            $artifactFullPath = Get-FullPathUnderRoot -Path $artifactPath -Root $RepositoryRoot -RequireRelative -RejectTraversal
            Assert-NoReparsePathComponent -Path $artifactFullPath -Root $RepositoryRoot
            $artifactHash = [string](Get-PropertyValue -Object $artifact -Name 'sha256' -DefaultValue '')
            $artifactCommit = ([string](Get-PropertyValue -Object $artifact -Name 'sourceCommit' -DefaultValue '')).ToLowerInvariant()
            if (-not (Test-HashValue -Value $artifactHash)) {
                Add-Blocker -Code 'MISSING_ARTIFACT_HASH' -Version $version -IssueNumber $issueNumber -Detail "Artifact SHA-256 is missing or malformed: $artifactPath"
            }
            if ($artifactCommit -cne $SourceCommit) {
                Add-Blocker -Code 'WRONG_ARTIFACT_COMMIT' -Version $version -IssueNumber $issueNumber -Detail "Artifact '$artifactPath' sourceCommit '$artifactCommit' does not match '$SourceCommit'."
            }
            if (-not (Test-Path -LiteralPath $artifactFullPath -PathType Leaf)) {
                Add-Blocker -Code 'MISSING_RELEASE_ARTIFACT' -Version $version -IssueNumber $issueNumber -Detail "Artifact is missing: $artifactPath"
            }
            elseif (Test-HashValue -Value $artifactHash) {
                $observedArtifactHash = ((Get-FileHash -LiteralPath $artifactFullPath -Algorithm SHA256).Hash).ToUpperInvariant()
                if ($artifactHash.ToUpperInvariant() -cne $observedArtifactHash) {
                    Add-Blocker -Code 'ARTIFACT_HASH_MISMATCH' -Version $version -IssueNumber $issueNumber -Detail "Artifact hash mismatch for '$artifactPath': expected $artifactHash observed $observedArtifactHash."
                }
            }
        }

        $runtimeStatus = ([string]$statusesObject.Runtime).ToUpperInvariant()
        if ($runtimeStatus -eq 'PASS' -and
            ([bool](Get-PropertyValue -Object $entry -Name 'runtimeObserved' -DefaultValue $false)) -ne $true) {
            Add-Blocker -Code 'RUNTIME_EVIDENCE_NOT_OBSERVED' -Version $version -IssueNumber $issueNumber -Detail 'Runtime PASS requires runtimeObserved=true; Synthetic WPF tests are not sufficient.'
        }
        if (([string](Get-PropertyValue -Object $entry -Name 'sourceKind' -DefaultValue '')).ToUpperInvariant() -eq 'SYNTHETIC' -and $runtimeStatus -eq 'PASS') {
            Add-Blocker -Code 'EVIDENCE_CLASS_CONFLATION' -Version $version -IssueNumber $issueNumber -Detail 'Synthetic sourceKind cannot claim Runtime PASS.'
        }
        if (([string](Get-PropertyValue -Object $entry -Name 'sourceKind' -DefaultValue '')).ToUpperInvariant() -eq 'FIXTURE' -and $QueryMode -eq 'OFFLINEFIXTURE') {
            # Fixture input is accepted for validator tests, but never admitted as product evidence.
        }

        $statusMap = [ordered]@{}
        foreach ($className in $script:AllEvidenceClasses) {
            $statusMap[$className] = ([string]$statusesObject.$className).ToUpperInvariant()
        }
        [void]$entries.Add([ordered]@{
            Version = $version
            GateId = $gateId
            IssueNumber = $issueNumber
            ReportPath = $reportPath.Replace('\', '/')
            ReportSha256 = $reportHash.ToUpperInvariant()
            SourceCommit = $entryCommit
            ObservedUtc = [string](Get-PropertyValue -Object $entry -Name 'observedUtc' -DefaultValue '')
            Statuses = $statusMap
            SourcePaths = @($sourcePaths | ForEach-Object { ([string]$_).Replace('\', '/') } | Sort-Object)
            Artifacts = @($artifacts | ForEach-Object {
                    [ordered]@{
                        Path = ([string](Get-PropertyValue -Object $_ -Name 'path' -DefaultValue '')).Replace('\', '/')
                        Sha256 = ([string](Get-PropertyValue -Object $_ -Name 'sha256' -DefaultValue '')).ToUpperInvariant()
                        SourceCommit = ([string](Get-PropertyValue -Object $_ -Name 'sourceCommit' -DefaultValue '')).ToLowerInvariant()
                    }
                } | Sort-Object Path)
            RuntimeObserved = [bool](Get-PropertyValue -Object $entry -Name 'runtimeObserved' -DefaultValue $false)
            SourceKind = [string](Get-PropertyValue -Object $entry -Name 'sourceKind' -DefaultValue '')
        })
    }

    return [ordered]@{
        Source = 'EvidenceManifest'
        ManifestSha256 = $manifest.Sha256
        ManifestPath = $manifest.FullName
        Entries = @($entries.ToArray() | Sort-Object Version, GateId)
    }
}

function Get-EvidenceStatusSummary {
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [object[]]$Entries,

        [Parameter(Mandatory)]
        [hashtable]$PlanTruth,

        [Parameter(Mandatory)]
        [string]$QueryMode
    )

    $summary = [ordered]@{}
    foreach ($className in $script:AllEvidenceClasses) {
        $requiredVersions = @($script:RequiredVersions | Where-Object {
                $PlanTruth.Versions[$_].RequiredEvidenceClasses -contains $className
            })
        $observedVersions = New-Object System.Collections.ArrayList
        $notObservedVersions = New-Object System.Collections.ArrayList
        foreach ($version in $requiredVersions) {
            $entry = @($Entries | Where-Object { $_.Version -eq $version } | Select-Object -First 1)
            $status = if ($entry.Count -eq 1) { ([string]$entry[0].Statuses[$className]).ToUpperInvariant() } else { 'NOT_OBSERVED' }
            if ($QueryMode -eq 'OfflineFixture') {
                $status = 'NOT_OBSERVED'
            }
            if ($status -eq 'PASS') {
                [void]$observedVersions.Add($version)
            }
            else {
                [void]$notObservedVersions.Add($version)
                Add-Blocker -Code 'EVIDENCE_NOT_OBSERVED' -Version $version -IssueNumber ([int]$PlanTruth.Tracking[$version].ReleaseTrackerIssue) -Detail "$className evidence for $version is $status; required by the version-local release gate."
            }
        }

        $statusValue = if ($requiredVersions.Count -eq 0) {
            'NOT_APPLICABLE'
        }
        elseif ($notObservedVersions.Count -eq 0) {
            'PASS'
        }
        elseif ($observedVersions.Count -eq 0) {
            'NOT_OBSERVED'
        }
        else {
            'BLOCKED'
        }
        $summary[$className] = [ordered]@{
            Status = $statusValue
            RequiredByVersions = @($requiredVersions)
            ObservedVersions = @($observedVersions.ToArray() | Sort-Object)
            NotObservedVersions = @($notObservedVersions.ToArray() | Sort-Object)
        }
    }
    return $summary
}

function Get-OrderedBlockers {
    return @($script:AuditBlockers.ToArray() | Sort-Object `
        @{ Expression = { if ([string]::IsNullOrWhiteSpace($_.Version)) { 'zzzz' } else { $_.Version } } }, `
        @{ Expression = { $_.IssueNumber } }, `
        @{ Expression = { $_.Code } }, `
        @{ Expression = { $_.Detail } })
}

function New-HumanReport {
    param(
        [Parameter(Mandatory)]
        [hashtable]$Report
    )

    $lines = New-Object System.Collections.ArrayList
    [void]$lines.Add('HerdrOps v1.0.0 Issue #41 Dependency Audit')
    [void]$lines.Add("GeneratedUtc: $($Report.GeneratedUtc)")
    [void]$lines.Add("SourceCommit: $($Report.SourceCommit)")
    [void]$lines.Add("WorkingTree: $($Report.WorkingTree)")
    [void]$lines.Add("QuerySource: $($Report.Query.Source)")
    if (-not [string]::IsNullOrWhiteSpace($Report.Query.FixturePath)) {
        [void]$lines.Add("FixturePath: $($Report.Query.FixturePath)")
        [void]$lines.Add("FixtureSha256: $($Report.Query.FixtureSha256)")
    }
    [void]$lines.Add("Decision: $($Report.Decision)")
    [void]$lines.Add("ReleaseCandidate: $($Report.ReleaseCandidate.Status)")
    [void]$lines.Add('')
    [void]$lines.Add('EvidenceStatus:')
    foreach ($className in $script:AllEvidenceClasses) {
        [void]$lines.Add("$className`: $($Report.EvidenceStatus[$className].Status)")
    }
    [void]$lines.Add('')
    [void]$lines.Add("OpenBlockers: $(@($Report.Blockers).Count)")
    foreach ($blocker in @($Report.Blockers)) {
        $scope = if ($blocker.IssueNumber -gt 0) { "$($blocker.Version) #$($blocker.IssueNumber)" } elseif (-not [string]::IsNullOrWhiteSpace($blocker.Version)) { $blocker.Version } else { 'global' }
        [void]$lines.Add("- [$($blocker.Code)] ${scope}: $($blocker.Detail)")
    }
    [void]$lines.Add('')
    [void]$lines.Add('DependencyMap:')
    foreach ($issue in @($Report.DependencyMap)) {
        $tracker = if ($issue.IsReleaseTracker) { 'release-tracker' } else { 'work' }
        [void]$lines.Add("- $($issue.Version) #$($issue.IssueNumber) [$($issue.State); $tracker] -> tracker #$($issue.ReleaseTrackerIssue); gate=$($issue.LocalGateVerifier)")
    }
    [void]$lines.Add('')
    [void]$lines.Add('EvidenceBoundary:')
    [void]$lines.Add('This audit reports Static, Synthetic, Contract, Integration, Runtime, Independent, Human, and Release classes separately.')
    [void]$lines.Add('tests/HerdrOps.RuntimeTests is Synthetic WPF evidence and never substitutes for actual Herdr Runtime.')
    [void]$lines.Add('Offline fixture input is validation-only and receives no Runtime, Independent, Human, Release, or release-candidate credit.')
    [void]$lines.Add('No Registry, AppData, live database, installed Herdr, package publication, release publication, or runtime acceptance was performed by this audit.')
    return ($lines -join "`r`n") + "`r`n"
}

$repositoryRoot = (Resolve-Path -LiteralPath $RepositoryRoot).Path
$gitState = Get-GitState -Root $repositoryRoot
$planTruth = Get-PlanTruth -Root $repositoryRoot
$snapshot = Get-GitHubSnapshot -RepositoryName $Repository -OfflineFixture $FixturePath -GhCommand $GhExecutable
$dependencyData = New-DependencyAuditData -PlanTruth $planTruth -GitHubSnapshot $snapshot
$evidence = Get-EvidenceManifestEntries `
    -ManifestPath $EvidenceManifestPath `
    -RepositoryRoot $repositoryRoot `
    -SourceCommit $gitState.SourceCommit `
    -PlanTruth $planTruth `
    -QueryMode $snapshot.Mode
$evidenceStatus = Get-EvidenceStatusSummary -Entries $evidence.Entries -PlanTruth $planTruth -QueryMode $snapshot.Mode

if ($snapshot.Mode -eq 'OfflineFixture') {
    Add-Blocker -Code 'OFFLINE_FIXTURE_NO_RELEASE_CREDIT' -Detail 'Offline fixture mode is validation-only; it cannot establish installed Herdr Runtime, Independent, Human, Release, or RC evidence.'
}

$requestedCandidate = -not [string]::IsNullOrWhiteSpace($ReleaseCandidateCommit)
$allEvidencePass = $true
foreach ($className in $script:AllEvidenceClasses) {
    if ($evidenceStatus[$className].Status -ne 'PASS' -and $evidenceStatus[$className].Status -ne 'NOT_APPLICABLE') {
        $allEvidencePass = $false
    }
}
$canFreeze = ($script:AuditBlockers.Count -eq 0 -and $allEvidencePass -and $snapshot.Mode -eq 'GitHub')
$releaseCandidate = [ordered]@{
    Status = 'NOT_RECORDED'
    Commit = ''
    Reason = 'No release candidate is recorded until all dependency, evidence, and release gates pass.'
}
if ($requestedCandidate -and -not $canFreeze) {
    Add-Blocker -Code 'RELEASE_CANDIDATE_FREEZE_BLOCKED' -Detail 'A release-candidate commit was supplied while dependency or evidence blockers remain; it was not recorded or frozen.'
}
elseif ($requestedCandidate -and $canFreeze) {
    $releaseCandidate.Status = 'RECORDED'
    $releaseCandidate.Commit = $ReleaseCandidateCommit.ToLowerInvariant()
    $releaseCandidate.Reason = 'All dependency and evidence gates passed in a GitHub-backed audit.'
}

$orderedBlockers = Get-OrderedBlockers
$decision = if ($orderedBlockers.Count -eq 0 -and $canFreeze) { 'READY' } else { 'NOT_READY' }
$generated = if ([string]::IsNullOrWhiteSpace($ObservedUtc)) {
    [DateTime]::UtcNow.ToString('O', [Globalization.CultureInfo]::InvariantCulture)
}
else {
    try { [DateTime]::Parse($ObservedUtc, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::AdjustToUniversal).ToString('O', [Globalization.CultureInfo]::InvariantCulture) }
    catch { throw "ObservedUtc is not a valid ISO-8601 timestamp: $ObservedUtc" }
}

$outputDirectory = Resolve-SafeOutputDirectory -RequestedPath $OutputDirectory -RepositoryRoot $repositoryRoot
New-Item -ItemType Directory -Path $outputDirectory -Force | Out-Null
Assert-NoReparsePathComponent -Path $outputDirectory -Root $repositoryRoot
$jsonPath = Join-Path $outputDirectory 'dependency-audit.json'
$textPath = Join-Path $outputDirectory 'dependency-audit.txt'
foreach ($reportPath in @($jsonPath, $textPath)) {
    if (Test-Path -LiteralPath $reportPath) {
        throw "Refusing to overwrite an existing dependency-audit report: $reportPath"
    }
}

$report = [ordered]@{
    SchemaVersion = 1
    AuditId = 'V100-01'
    TargetIssue = $dependencyData.TargetIssue
    GeneratedUtc = $generated
    SourceCommit = $gitState.SourceCommit
    WorkingTree = $gitState.WorkingTree
    Query = $snapshot.Query
    PlanTruth = [ordered]@{
        Files = $planTruth.Files
        Hashes = $planTruth.Hashes
        ReleaseGatesTextSha256 = $planTruth.ReleaseGatesTextSha256
    }
    Decision = $decision
    ReleaseCandidate = $releaseCandidate
    EvidenceStatus = $evidenceStatus
    EvidenceManifest = [ordered]@{
        Source = $evidence.Source
        Path = if ([string]::IsNullOrWhiteSpace($evidence.ManifestPath)) { '' } else { $evidence.ManifestPath }
        Sha256 = $evidence.ManifestSha256
        EntryCount = @($evidence.Entries).Count
    }
    DependencyMap = @($dependencyData.Map)
    Blockers = @($orderedBlockers)
    EvidenceBoundary = [ordered]@{
        RuntimeTestsProject = 'tests/HerdrOps.RuntimeTests = Synthetic WPF; never actual Herdr Runtime'
        ActualHerdrRuntime = 'NOT OBSERVED'
        RegistryAppDataLiveDatabase = 'NOT OBSERVED'
        ReleaseCandidateFreeze = if ($releaseCandidate.Status -eq 'RECORDED') { 'RECORDED' } else { 'NOT RECORDED' }
        PackagePublication = 'NOT PERFORMED'
        ReleasePublication = 'NOT PERFORMED'
        HumanAcceptance = if ($evidenceStatus.Human.Status -eq 'PASS') { 'OBSERVED_IN_INPUT' } else { 'NOT OBSERVED' }
    }
}

$jsonContent = $report | ConvertTo-Json -Depth 20
$textContent = New-HumanReport -Report $report
Write-Utf8NoBom -Path $jsonPath -Content ($jsonContent + "`r`n")
Write-Utf8NoBom -Path $textPath -Content $textContent

Write-Output $textContent
Write-Output "JsonReport: $jsonPath"
Write-Output "TextReport: $textPath"
if ($decision -ne 'READY') {
    exit 2
}
