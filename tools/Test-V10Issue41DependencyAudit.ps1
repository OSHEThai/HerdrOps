[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repositoryRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')).Path
$auditTool = Join-Path $PSScriptRoot 'Invoke-V10Issue41DependencyAudit.ps1'
$strictJsonPolicy = Join-Path $PSScriptRoot 'StrictJsonPolicy.ps1'
$paginationPolicy = Join-Path $PSScriptRoot 'GitHubPaginationPolicy.ps1'
$paginationFixture = Join-Path $PSScriptRoot 'Test-V10Issue41DependencyAuditPagination.ps1'
$milestoneVerifier = Join-Path $PSScriptRoot 'Test-VersionMilestone.ps1'
$fixtureRoot = Join-Path $repositoryRoot 'tests\fixtures\v1.0\issue-41'
$readyFixture = Join-Path $fixtureRoot 'github-snapshot-ready.json'
$duplicateFixture = Join-Path $fixtureRoot 'github-duplicate-key.json'
$malformedFixture = Join-Path $fixtureRoot 'github-malformed.json'
$fakeGhFixture = Join-Path $fixtureRoot 'fake-gh-multipage.ps1'
$testRunId = [Guid]::NewGuid().ToString('N')
$testRootParent = Join-Path $repositoryRoot 'artifacts\dependency-audit'
$testRoot = Join-Path $testRootParent ('issue-41-fixture-run-' + $testRunId)
$script:TestRoot = $testRoot
$script:TestRunId = $testRunId
$script:OwnershipMarkerName = '.issue-41-fixture-owner.json'
$script:OwnedPaths = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
$fixedObservedUtc = '2026-08-17T00:00:00.0000000Z'

foreach ($path in @($auditTool, $strictJsonPolicy, $paginationPolicy, $paginationFixture, $milestoneVerifier, $readyFixture, $duplicateFixture, $malformedFixture, $fakeGhFixture)) {
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        throw "Issue #41 fixture test input is missing: $path"
    }
}

function Initialize-PhysicalPathSupport {
    if ($null -eq ('Issue41NativePath' -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Text;

public static class Issue41NativePath
{
    private const uint FileReadAttributes = 0x00000080;
    private const uint FileShareRead = 0x00000001;
    private const uint FileShareWrite = 0x00000002;
    private const uint FileShareDelete = 0x00000004;
    private const uint OpenExisting = 3;
    private const uint FileFlagBackupSemantics = 0x02000000;

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern IntPtr CreateFile(
        string fileName,
        uint desiredAccess,
        uint shareMode,
        IntPtr securityAttributes,
        uint creationDisposition,
        uint flagsAndAttributes,
        IntPtr templateFile);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern uint GetFinalPathNameByHandle(
        IntPtr file,
        StringBuilder filePath,
        uint filePathLength,
        uint flags);

    [DllImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool CloseHandle(IntPtr handle);

    public static string GetFinalPath(string path)
    {
        IntPtr handle = CreateFile(
            path,
            FileReadAttributes,
            FileShareRead | FileShareWrite | FileShareDelete,
            IntPtr.Zero,
            OpenExisting,
            FileFlagBackupSemantics,
            IntPtr.Zero);
        if (handle == new IntPtr(-1))
        {
            throw new Win32Exception(Marshal.GetLastWin32Error(), "CreateFile failed for " + path);
        }

        try
        {
            StringBuilder buffer = new StringBuilder(32768);
            uint length = GetFinalPathNameByHandle(handle, buffer, (uint)buffer.Capacity, 0);
            if (length == 0 || length >= buffer.Capacity)
            {
                throw new Win32Exception(Marshal.GetLastWin32Error(), "GetFinalPathNameByHandle failed for " + path);
            }
            return buffer.ToString();
        }
        finally
        {
            CloseHandle(handle);
        }
    }
}
'@ -ErrorAction Stop
    }
}

function ConvertTo-PlainText {
    param(
        [Parameter(Mandatory = $false)]
        [string]$Text
    )

    if ([string]::IsNullOrEmpty($Text)) {
        return ''
    }

    # Strip only complete, bounded ECMA-48 control sequences. Plain text is
    # appended one code unit at a time so malformed controls cannot make a
    # broad regex consume neighboring output.
    $maximumControlLength = 4096
    $builder = New-Object Text.StringBuilder
    $length = $Text.Length
    $i = 0
    while ($i -lt $length) {
        $code = [int][char]$Text[$i]
        if ($code -eq 0x1b) {
            if ($i + 1 -ge $length) {
                $i++
                continue
            }

            $next = [int][char]$Text[$i + 1]
            if ($next -eq 0x5b) {
                $end = $i + 2
                $consumed = 2
                $foundFinal = $false
                while ($end -lt $length -and $consumed -lt $maximumControlLength) {
                    $current = [int][char]$Text[$end]
                    if ($current -ge 0x30 -and $current -le 0x3f) {
                        $end++
                        $consumed++
                        continue
                    }
                    if ($current -ge 0x20 -and $current -le 0x2f) {
                        $end++
                        $consumed++
                        continue
                    }
                    if ($current -ge 0x40 -and $current -le 0x7e) {
                        $end++
                        $consumed++
                        $foundFinal = $true
                        break
                    }
                    break
                }
                if (-not $foundFinal) {
                    throw 'Unterminated or overlong ANSI CSI sequence.'
                }
                $i = $end
                continue
            }

            if ($next -eq 0x5d -or $next -eq 0x50 -or $next -eq 0x58 -or $next -eq 0x5e -or $next -eq 0x5f) {
                $isOsc = $next -eq 0x5d
                $end = $i + 2
                $foundTerminator = $false
                while ($end -lt $length -and ($end - ($i + 2)) -lt $maximumControlLength) {
                    $current = [int][char]$Text[$end]
                    if (($isOsc -and $current -eq 0x07) -or $current -eq 0x9c) {
                        $end++
                        $foundTerminator = $true
                        break
                    }
                    if ($current -eq 0x1b -and $end + 1 -lt $length -and [int][char]$Text[$end + 1] -eq 0x5c) {
                        $end += 2
                        $foundTerminator = $true
                        break
                    }
                    $end++
                }
                if (-not $foundTerminator) {
                    throw 'Unterminated or overlong ANSI control string.'
                }
                $i = $end
                continue
            }

            # ESC followed by a final/intermediate character is a bounded
            # single-character ESC sequence. Preserve a non-ASCII character
            # after a lone ESC rather than treating it as control payload.
            if ($next -ge 0x20 -and $next -le 0x7e) {
                $i += 2
            }
            else {
                $i++
            }
            continue
        }

        if ($code -eq 0x9b) {
            $end = $i + 1
            $consumed = 1
            $foundFinal = $false
            while ($end -lt $length -and $consumed -lt $maximumControlLength) {
                $current = [int][char]$Text[$end]
                if ($current -ge 0x30 -and $current -le 0x3f) {
                    $end++
                    $consumed++
                    continue
                }
                if ($current -ge 0x20 -and $current -le 0x2f) {
                    $end++
                    $consumed++
                    continue
                }
                if ($current -ge 0x40 -and $current -le 0x7e) {
                    $end++
                    $consumed++
                    $foundFinal = $true
                    break
                }
                break
            }
            if (-not $foundFinal) {
                throw 'Unterminated or overlong ANSI C1 CSI sequence.'
            }
            $i = $end
            continue
        }

        if ($code -eq 0x9d -or $code -eq 0x90 -or $code -eq 0x98 -or $code -eq 0x9e -or $code -eq 0x9f) {
            $end = $i + 1
            $foundTerminator = $false
            while ($end -lt $length -and ($end - ($i + 1)) -lt $maximumControlLength) {
                $current = [int][char]$Text[$end]
                if ($current -eq 0x9c -or ($current -eq 0x1b -and $end + 1 -lt $length -and [int][char]$Text[$end + 1] -eq 0x5c)) {
                    $end += if ($current -eq 0x9c) { 1 } else { 2 }
                    $foundTerminator = $true
                    break
                }
                $end++
            }
            if (-not $foundTerminator) {
                throw 'Unterminated or overlong ANSI C1 control string.'
            }
            $i = $end
            continue
        }

        # C1 controls, including standalone ST and CSI/string introducers,
        # are controls even when they are not part of a recognized sequence.
        if ($code -ge 0x80 -and $code -le 0x9f) {
            $i++
            continue
        }

        [void]$builder.Append($Text[$i])
        $i++
    }
    return $builder.ToString()
}

function Get-LexicalFullPath {
    param([Parameter(Mandatory)][string]$Path)
    return [IO.Path]::GetFullPath($Path)
}

function Assert-LexicalContained {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Root
    )

    $rootFull = (Get-LexicalFullPath -Path $Root).TrimEnd([char[]]@([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar))
    $full = Get-LexicalFullPath -Path $Path
    $prefix = $rootFull + [IO.Path]::DirectorySeparatorChar
    if (-not $full.Equals($rootFull, [StringComparison]::OrdinalIgnoreCase) -and
        -not $full.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Fixture path escapes lexical root '$rootFull': $Path"
    }
    return $full
}

function Assert-NoReparsePathComponent {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Root
    )

    $rootFull = Assert-LexicalContained -Path $Root -Root $Root
    $full = Assert-LexicalContained -Path $Path -Root $Root
    $rootItem = Get-Item -LiteralPath $rootFull -Force -ErrorAction Stop
    if (($rootItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw "Fixture root is a reparse point: $rootFull"
    }
    $relative = $full.Substring($rootFull.Length).TrimStart([char[]]@([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar))
    $current = $rootFull
    foreach ($segment in ($relative -split '[\\/]')) {
        if ([string]::IsNullOrWhiteSpace($segment)) { continue }
        $current = Join-Path $current $segment
        if (Test-Path -LiteralPath $current) {
            $item = Get-Item -LiteralPath $current -Force -ErrorAction Stop
            if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                throw "Fixture path contains a reparse point: $current"
            }
        }
    }
}

function ConvertTo-NormalizedPhysicalPath {
    param([Parameter(Mandatory)][string]$Path)
    $value = $Path.Replace('/', '\')
    if ($value.StartsWith('\\?\UNC\', [StringComparison]::OrdinalIgnoreCase)) {
        $value = '\\' + $value.Substring(8)
    }
    elseif ($value.StartsWith('\\?\', [StringComparison]::OrdinalIgnoreCase)) {
        $value = $value.Substring(4)
    }
    return (Get-LexicalFullPath -Path $value).TrimEnd([char[]]@([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar))
}

function Get-PhysicalExistingAncestor {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Root
    )

    $full = Assert-LexicalContained -Path $Path -Root $Root
    $probe = $full
    while (-not (Test-Path -LiteralPath $probe)) {
        $directory = New-Object IO.DirectoryInfo($probe)
        if ($null -eq $directory.Parent) {
            throw "Could not find an existing fixture path ancestor: $Path"
        }
        $probe = $directory.Parent.FullName
    }
    $item = Get-Item -LiteralPath $probe -Force -ErrorAction Stop
    if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw "Fixture physical path ancestor is a reparse point: $probe"
    }
    return [pscustomobject]@{
        LexicalPath = (Get-LexicalFullPath -Path $probe)
        PhysicalPath = ConvertTo-NormalizedPhysicalPath -Path ([Issue41NativePath]::GetFinalPath($item.FullName))
    }
}

function Assert-TestPathContained {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Root,
        [switch]$AllowReparse
    )

    $full = Assert-LexicalContained -Path $Path -Root $Root
    if (-not $AllowReparse) {
        Assert-NoReparsePathComponent -Path $full -Root $Root
    }
    $rootPhysical = Get-PhysicalExistingAncestor -Path $Root -Root $Root
    $candidatePhysical = Get-PhysicalExistingAncestor -Path $full -Root $Root
    $candidateRemainder = $full.Substring($candidatePhysical.LexicalPath.Length).TrimStart([char[]]@([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar))
    $physicalFull = if ([string]::IsNullOrEmpty($candidateRemainder)) { $candidatePhysical.PhysicalPath } else { Join-Path $candidatePhysical.PhysicalPath $candidateRemainder }
    $physicalPrefix = $rootPhysical.PhysicalPath + [IO.Path]::DirectorySeparatorChar
    if (-not $physicalFull.Equals($rootPhysical.PhysicalPath, [StringComparison]::OrdinalIgnoreCase) -and
        -not $physicalFull.StartsWith($physicalPrefix, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Fixture path escapes physical root '$($rootPhysical.PhysicalPath)': $Path"
    }
    return $full
}

function Register-OwnedPath {
    param(
        [Parameter(Mandatory)][string]$Path,
        [switch]$AllowReparse
    )

    $full = if ($AllowReparse) {
        Assert-LexicalContained -Path $Path -Root $script:TestRoot
    }
    else {
        Assert-TestPathContained -Path $Path -Root $script:TestRoot
    }
    [void]$script:OwnedPaths.Add($full)
    return $full
}

function New-OwnedDirectory {
    param([Parameter(Mandatory)][string]$Path)
    $full = Assert-TestPathContained -Path $Path -Root $script:TestRoot
    if (Test-Path -LiteralPath $full) {
        throw "Refusing to overwrite an existing fixture directory: $full"
    }
    New-Item -ItemType Directory -Path $full -ErrorAction Stop | Out-Null
    Register-OwnedPath -Path $full | Out-Null
    return $full
}

function New-UniqueChildPath {
    param(
        [Parameter(Mandatory)][string]$Parent,
        [Parameter(Mandatory)][string]$Prefix
    )

    $parentFull = Assert-TestPathContained -Path $Parent -Root $script:TestRoot
    if (-not (Test-Path -LiteralPath $parentFull -PathType Container)) {
        throw "Fixture parent directory is missing: $parentFull"
    }
    for ($attempt = 0; $attempt -lt 8; $attempt++) {
        $candidate = Join-Path $parentFull ($Prefix + '-' + [Guid]::NewGuid().ToString('N'))
        $candidate = Assert-TestPathContained -Path $candidate -Root $script:TestRoot
        if (-not (Test-Path -LiteralPath $candidate)) {
            return $candidate
        }
    }
    throw "Could not allocate a unique fixture path below $parentFull."
}

function Register-OwnedTree {
    param([Parameter(Mandatory)][string]$Root)

    $rootFull = Assert-TestPathContained -Path $Root -Root $script:TestRoot
    $pending = New-Object System.Collections.Stack
    $pending.Push($rootFull)
    while ($pending.Count -gt 0) {
        $current = [string]$pending.Pop()
        $item = Get-Item -LiteralPath $current -Force -ErrorAction Stop
        $isReparse = ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0
        Register-OwnedPath -Path $current -AllowReparse:$isReparse | Out-Null
        if ($item.PSIsContainer -and -not $isReparse) {
            foreach ($child in @(Get-ChildItem -LiteralPath $current -Force -ErrorAction Stop)) {
                $pending.Push($child.FullName)
            }
        }
    }
}

function Remove-OwnedPathNow {
    param([Parameter(Mandatory)][string]$Path)

    $full = Get-LexicalFullPath -Path $Path
    if (-not $script:OwnedPaths.Contains($full)) {
        throw "Fixture cleanup refused to remove an unowned path: $full"
    }
    if (-not (Test-Path -LiteralPath $full)) {
        [void]$script:OwnedPaths.Remove($full)
        return
    }
    $item = Get-Item -LiteralPath $full -Force -ErrorAction Stop
    $isReparse = ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0
    if ($item.PSIsContainer -and -not $isReparse -and @(Get-ChildItem -LiteralPath $full -Force -ErrorAction Stop).Count -ne 0) {
        throw "Fixture cleanup refused to remove a non-empty owned directory: $full"
    }
    Remove-Item -LiteralPath $full -Force -ErrorAction Stop
    [void]$script:OwnedPaths.Remove($full)
}

function Remove-OwnedPaths {
    param(
        [Parameter(Mandatory)][string]$RunRoot,
        [Parameter(Mandatory)][string]$OwnershipMarker
    )

    $runRootFull = Assert-LexicalContained -Path $RunRoot -Root $testRootParent
    $markerFull = Assert-LexicalContained -Path $OwnershipMarker -Root $runRootFull
    if (-not (Test-Path -LiteralPath $markerFull -PathType Leaf)) {
        throw "Fixture cleanup refused: ownership marker is missing: $markerFull"
    }
    $marker = Get-Content -LiteralPath $markerFull -Raw | ConvertFrom-Json
    if ([string]$marker.Owner -cne 'Test-V10Issue41DependencyAudit.ps1' -or
        [string]$marker.RunId -cne $script:TestRunId -or
        [string]$marker.Root -cne $runRootFull) {
        throw "Fixture cleanup refused: ownership marker does not belong to this invocation."
    }

    $paths = @($script:OwnedPaths | ForEach-Object { $_ } | Sort-Object { $_.Length } -Descending)
    foreach ($path in $paths) {
        if (-not (Test-Path -LiteralPath $path)) { continue }
        $item = Get-Item -LiteralPath $path -Force -ErrorAction Stop
        $isReparse = ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0
        if ($isReparse) {
            Remove-Item -LiteralPath $path -Force -ErrorAction Stop
            continue
        }
        if ($item.PSIsContainer) {
            $children = @(Get-ChildItem -LiteralPath $path -Force -ErrorAction Stop)
            if ($children.Count -ne 0) {
                throw "Fixture cleanup refused to remove a non-empty owned directory: $path"
            }
        }
        Remove-Item -LiteralPath $path -Force -ErrorAction Stop
    }
}

function Initialize-TestRunRoot {
    $parentFull = Assert-LexicalContained -Path $testRootParent -Root $repositoryRoot
    if (-not (Test-Path -LiteralPath $parentFull -PathType Container)) {
        New-Item -ItemType Directory -Path $parentFull -ErrorAction Stop | Out-Null
    }
    Assert-TestPathContained -Path $parentFull -Root $repositoryRoot | Out-Null
    $rootFull = Assert-LexicalContained -Path $script:TestRoot -Root $parentFull
    if (Test-Path -LiteralPath $rootFull) {
        throw "Fixture run root collision: $rootFull"
    }
    New-Item -ItemType Directory -Path $rootFull -ErrorAction Stop | Out-Null
    Register-OwnedPath -Path $rootFull | Out-Null
    $markerPath = Join-Path $rootFull $script:OwnershipMarkerName
    $marker = [ordered]@{
        Owner = 'Test-V10Issue41DependencyAudit.ps1'
        RunId = $script:TestRunId
        Root = $rootFull
        CreatedUtc = [DateTime]::UtcNow.ToString('O', [Globalization.CultureInfo]::InvariantCulture)
    }
    Write-Utf8NoBom -Path $markerPath -Content (($marker | ConvertTo-Json -Depth 5) + "`r`n")
    return [pscustomobject]@{ Root = $rootFull; Marker = $markerPath }
}

function Write-Utf8NoBom {
    param(
        [Parameter(Mandatory)]
        [string]$Path,

        [Parameter(Mandatory)]
        [string]$Content,

        [switch]$AllowOverwrite
    )

    $full = Assert-TestPathContained -Path $Path -Root $script:TestRoot
    if (Test-Path -LiteralPath $full) {
        if (-not $AllowOverwrite -or -not $script:OwnedPaths.Contains($full)) {
            throw "Refusing to overwrite an unowned fixture path: $full"
        }
    }
    $encoding = New-Object System.Text.UTF8Encoding($false)
    $mode = if ($AllowOverwrite) { [IO.FileMode]::Create } else { [IO.FileMode]::CreateNew }
    $stream = [IO.File]::Open($full, $mode, [IO.FileAccess]::Write, [IO.FileShare]::None)
    try {
        $bytes = $encoding.GetBytes($Content)
        $stream.Write($bytes, 0, $bytes.Length)
    }
    finally {
        $stream.Dispose()
    }
    Register-OwnedPath -Path $full | Out-Null
}

function Write-OwnedRepositoryUtf8NoBom {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Content
    )

    $full = Assert-TestPathContained -Path $Path -Root $repositoryRoot
    if (Test-Path -LiteralPath $full) {
        throw "Refusing to overwrite an existing repository probe: $full"
    }
    $encoding = New-Object System.Text.UTF8Encoding($false)
    $stream = [IO.File]::Open($full, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
    try {
        $bytes = $encoding.GetBytes($Content)
        $stream.Write($bytes, 0, $bytes.Length)
    }
    finally {
        $stream.Dispose()
    }
    [void]$script:OwnedPaths.Add($full)
}

function Get-SourceCommit {
    $previousPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        $lines = @(& git -C $repositoryRoot rev-parse --verify 'HEAD^{commit}' 2>&1 | ForEach-Object { [string]$_ })
        $exitCode = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $previousPreference
    }
    if ($exitCode -ne 0 -or $lines.Count -ne 1 -or $lines[0].Trim() -notmatch '^[0-9a-fA-F]{40}$') {
        throw 'Fixture tests require a committed source identity.'
    }
    return $lines[0].Trim().ToLowerInvariant()
}

function New-CaseDirectory {
    param(
        [Parameter(Mandatory)]
        [string]$ShellName
    )

    $safeName = $ShellName -replace '[^A-Za-z0-9_.-]', '_'
    return New-OwnedDirectory -Path (New-UniqueChildPath -Parent $script:TestRoot -Prefix ('case-' + $safeName))
}

function New-ReadyEvidenceManifest {
    param(
        [Parameter(Mandatory)]
        [string]$CaseDirectory,

        [Parameter(Mandatory)]
        [string]$SourceCommit
    )

    $caseFull = Assert-TestPathContained -Path $CaseDirectory -Root $script:TestRoot
    if (-not (Test-Path -LiteralPath $caseFull -PathType Container)) {
        New-OwnedDirectory -Path $caseFull | Out-Null
    }
    $gateRoot = Join-Path $CaseDirectory 'gates'
    $artifactRoot = Join-Path $CaseDirectory 'artifacts'
    New-OwnedDirectory -Path $gateRoot | Out-Null
    New-OwnedDirectory -Path $artifactRoot | Out-Null
    $trackerByVersion = [ordered]@{
        'v0.1.0' = 5
        'v0.2.0' = 11
        'v0.3.0' = 17
        'v0.4.0' = 23
        'v0.5.0' = 29
        'v0.6.0' = 34
        'v0.7.0' = 40
    }
    $allStatuses = [ordered]@{
        Static = 'PASS'
        Synthetic = 'PASS'
        Contract = 'PASS'
        Integration = 'PASS'
        Runtime = 'PASS'
        Independent = 'PASS'
        Human = 'PASS'
        Release = 'PASS'
    }
    $entries = New-Object System.Collections.ArrayList
    foreach ($version in $trackerByVersion.Keys) {
        $versionDirectory = Join-Path $gateRoot $version
        New-OwnedDirectory -Path $versionDirectory | Out-Null
        $reportPath = Join-Path $versionDirectory 'gate-report.txt'
        $artifactPath = Join-Path $artifactRoot ($version + '.bin')
        Write-Utf8NoBom -Path $reportPath -Content ("Fixture gate report for {0}`r`n" -f $version)
        Write-Utf8NoBom -Path $artifactPath -Content ("Fixture artifact for {0}`r`n" -f $version)
        $reportRelative = $reportPath.Substring($repositoryRoot.Length).TrimStart([char[]]@([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)).Replace('\', '/')
        $artifactRelative = $artifactPath.Substring($repositoryRoot.Length).TrimStart([char[]]@([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)).Replace('\', '/')
        [void]$entries.Add([ordered]@{
            version = $version
            gateId = 'version-local'
            issueNumber = $trackerByVersion[$version]
            reportPath = $reportRelative
            reportSha256 = ((Get-FileHash -LiteralPath $reportPath -Algorithm SHA256).Hash).ToUpperInvariant()
            sourceCommit = $SourceCommit
            observedUtc = $fixedObservedUtc
            sourceKind = 'Fixture'
            runtimeObserved = $true
            sourcePaths = @('tools/Test-VersionMilestone.ps1')
            statuses = $allStatuses
            artifacts = @([ordered]@{
                path = $artifactRelative
                sha256 = ((Get-FileHash -LiteralPath $artifactPath -Algorithm SHA256).Hash).ToUpperInvariant()
                sourceCommit = $SourceCommit
            })
        })
    }
    $manifest = [ordered]@{
        schemaVersion = 1
        sourceCommit = $SourceCommit
        entries = @($entries)
    }
    $manifestPath = Join-Path $CaseDirectory 'evidence-manifest.json'
    Write-Utf8NoBom -Path $manifestPath -Content (($manifest | ConvertTo-Json -Depth 20) + "`r`n")
    return [pscustomobject]@{
        Path = $manifestPath
        Data = $manifest
        GateRoot = $gateRoot
        ArtifactRoot = $artifactRoot
    }
}

function Copy-JsonFixture {
    param(
        [Parameter(Mandatory)]
        [string]$SourcePath,

        [Parameter(Mandatory)]
        [string]$DestinationPath
    )

    $value = Get-Content -LiteralPath $SourcePath -Raw | ConvertFrom-Json
    Write-Utf8NoBom -Path $DestinationPath -Content (($value | ConvertTo-Json -Depth 20) + "`r`n")
    return $value
}

function Invoke-AuditCase {
    param(
        [Parameter(Mandatory)]
        [string]$ShellPath,

        [string]$FixturePath,

        [string]$EvidencePath,

        [Parameter(Mandatory)]
        [string]$OutputPath,

        [string]$CandidateCommit,

        [string]$GhCommand = 'gh',

        [switch]$PermitHostileOutputPath
    )

    $outputWasPresent = Test-Path -LiteralPath $OutputPath
    if (-not $outputWasPresent) {
        if (-not $PermitHostileOutputPath) {
            Assert-TestPathContained -Path $OutputPath -Root $script:TestRoot | Out-Null
        }
    }
    $arguments = @(
        '-NoProfile',
        '-NonInteractive',
        '-ExecutionPolicy',
        'Bypass',
        '-File',
        $auditTool,
        '-RepositoryRoot',
        $repositoryRoot,
        '-OutputDirectory',
        $OutputPath,
        '-ObservedUtc',
        $fixedObservedUtc
    )
    if (-not [string]::IsNullOrWhiteSpace($FixturePath)) {
        $arguments += @('-FixturePath', $FixturePath)
    }
    if (-not [string]::IsNullOrWhiteSpace($EvidencePath)) {
        $arguments += @('-EvidenceManifestPath', $EvidencePath)
    }
    if ($GhCommand -ne 'gh') {
        $arguments += @('-GhExecutable', $GhCommand)
    }
    if (-not [string]::IsNullOrWhiteSpace($CandidateCommit)) {
        $arguments += @('-ReleaseCandidateCommit', $CandidateCommit)
    }
    $previousPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        $output = @(& $ShellPath @arguments 2>&1 | ForEach-Object { [string]$_ })
        $exitCode = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $previousPreference
    }
    $rawText = $output -join "`n"
    if (-not $outputWasPresent -and (Test-Path -LiteralPath $OutputPath)) {
        Register-OwnedTree -Root $OutputPath
    }
    $plainText = ConvertTo-PlainText -Text $rawText
    return [pscustomobject]@{
        ExitCode = $exitCode
        Output = $plainText
        RawOutput = $rawText
    }
}

function Assert-CaseExit {
    param(
        [Parameter(Mandatory)]
        [object]$Result,

        [Parameter(Mandatory)]
        [int]$ExpectedExitCode,

        [Parameter(Mandatory)]
        [string]$CaseName
    )

    if ($Result.ExitCode -ne $ExpectedExitCode) {
        throw "$CaseName returned exit code $($Result.ExitCode), expected $ExpectedExitCode. Output: $($Result.Output)"
    }
}

function Assert-Contains {
    param(
        [Parameter(Mandatory)]
        [string]$Text,

        [Parameter(Mandatory)]
        [string]$Needle,

        [Parameter(Mandatory)]
        [string]$CaseName
    )

    $plainText = ConvertTo-PlainText -Text $Text
    $plainNeedle = ConvertTo-PlainText -Text $Needle
    if ($plainText.IndexOf($plainNeedle, [StringComparison]::Ordinal) -lt 0) {
        throw "$CaseName did not contain '$Needle'. Output: $plainText"
    }
}

function Assert-Report {
    param(
        [Parameter(Mandatory)]
        [string]$OutputPath,

        [Parameter(Mandatory)]
        [string]$CaseName
    )

    $jsonPath = Join-Path $OutputPath 'dependency-audit.json'
    $textPath = Join-Path $OutputPath 'dependency-audit.txt'
    if (-not (Test-Path -LiteralPath $jsonPath -PathType Leaf) -or -not (Test-Path -LiteralPath $textPath -PathType Leaf)) {
        throw "$CaseName did not produce both report files."
    }
    $report = Get-Content -LiteralPath $jsonPath -Raw | ConvertFrom-Json
    if ($report.Decision -ne 'NOT_READY') {
        throw "$CaseName unexpectedly produced decision $($report.Decision)."
    }
    return $report
}

function Assert-ParsedInShell {
    param(
        [Parameter(Mandatory)]
        [string]$ShellPath,

        [Parameter(Mandatory)]
        [string]$Path
    )

    $oldTarget = $env:HERDR_OPS_V10_PARSE_TARGET
    $env:HERDR_OPS_V10_PARSE_TARGET = $Path
    try {
        $command = '$target=$env:HERDR_OPS_V10_PARSE_TARGET; $tokens=$null; $errors=$null; [System.Management.Automation.Language.Parser]::ParseFile($target, [ref]$tokens, [ref]$errors) | Out-Null; if ($errors.Count -gt 0) { $errors | ForEach-Object { Write-Error $_.ToString() }; exit 1 }; Write-Output "PARSE_PASS"'
        $previousPreference = $ErrorActionPreference
        try {
            $ErrorActionPreference = 'Continue'
            $output = @(& $ShellPath -NoProfile -NonInteractive -Command $command 2>&1 | ForEach-Object { [string]$_ })
            $exitCode = $LASTEXITCODE
        }
        finally {
            $ErrorActionPreference = $previousPreference
        }
        $plainText = ConvertTo-PlainText -Text ($output -join "`n")
        if ($exitCode -ne 0 -or $plainText -notmatch 'PARSE_PASS') {
            throw "PowerShell parse failed for $Path using ${ShellPath}: $($output -join '; ')"
        }
    }
    finally {
        if ($null -eq $oldTarget) { Remove-Item Env:HERDR_OPS_V10_PARSE_TARGET -ErrorAction SilentlyContinue }
        else { $env:HERDR_OPS_V10_PARSE_TARGET = $oldTarget }
    }
}

$sourceCommit = Get-SourceCommit
$shells = New-Object System.Collections.ArrayList
foreach ($candidate in @('powershell', 'pwsh')) {
    $command = Get-Command $candidate -ErrorAction SilentlyContinue
    if ($null -ne $command) {
        [void]$shells.Add([pscustomobject]@{ Name = $candidate; Path = $command.Source })
    }
}
if ($shells.Count -eq 0) {
    throw 'Neither powershell.exe nor pwsh.exe is available for the Issue #41 fixture tests.'
}

$completed = New-Object System.Collections.ArrayList
$milestoneSource = Get-Content -LiteralPath $milestoneVerifier -Raw
$milestonePaginationCalls = [regex]::Matches(
    $milestoneSource,
    '(?m)^\s*\$(?:milestone|issue)Response\s*=\s*Read-BoundedGitHubJsonArrayPages\s*`?\s*$'
).Count
if ($milestonePaginationCalls -ne 2 -or
    $milestoneSource -notmatch 'milestones\?state=all&sort=due_on&direction=asc' -or
    $milestoneSource -notmatch 'issues\?state=all&sort=created&direction=asc') {
    throw 'The shared milestone verifier is not bound to complete, stable GitHub pagination.'
}
[void]$completed.Add('version milestone verifier: bounded pagination -> bound')
Initialize-PhysicalPathSupport
$runRootInfo = $null
try {
    $runRootInfo = Initialize-TestRunRoot
    foreach ($shell in $shells) {
        Assert-ParsedInShell -ShellPath $shell.Path -Path $auditTool
        Assert-ParsedInShell -ShellPath $shell.Path -Path $strictJsonPolicy
        Assert-ParsedInShell -ShellPath $shell.Path -Path $paginationPolicy
        Assert-ParsedInShell -ShellPath $shell.Path -Path $paginationFixture
        Assert-ParsedInShell -ShellPath $shell.Path -Path $milestoneVerifier
        $previousPreference = $ErrorActionPreference
        try {
            $ErrorActionPreference = 'Continue'
            $paginationOutput = @(& $shell.Path -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $paginationFixture 2>&1 | ForEach-Object { [string]$_ })
            $paginationExitCode = $LASTEXITCODE
        }
        finally {
            $ErrorActionPreference = $previousPreference
        }
        $paginationText = ConvertTo-PlainText -Text ($paginationOutput -join "`n")
        if ($paginationExitCode -ne 0 -or $paginationText -notmatch 'bounded pagination fixtures:\s*PASS') {
            throw "$($shell.Name) pagination fixture failed (exit $paginationExitCode): $($paginationOutput -join '; ')"
        }
        [void]$completed.Add("$($shell.Name): bounded pagination -> complete")

        $previousPreference = $ErrorActionPreference
        try {
            $ErrorActionPreference = 'Continue'
            $milestoneOutput = @(& $shell.Path `
                    -NoProfile `
                    -NonInteractive `
                    -ExecutionPolicy Bypass `
                    -File $milestoneVerifier `
                    -Version 'v0.1.0' `
                    -Repository 'example' `
                    -GhExecutable $fakeGhFixture `
                    -GitHubPageSize 2 2>&1 | ForEach-Object { [string]$_ })
            $milestoneExitCode = $LASTEXITCODE
        }
        finally {
            $ErrorActionPreference = $previousPreference
        }
        $milestoneText = ConvertTo-PlainText -Text ($milestoneOutput -join "`n")
        if ($milestoneExitCode -ne 0 -or
            $milestoneText -notmatch 'TotalIssues\s*:\s*3' -or
            $milestoneText -notmatch 'IssueQueryPages\s*:\s*2') {
            throw "$($shell.Name) production milestone pagination fixture failed (exit $milestoneExitCode): $milestoneText"
        }
        [void]$completed.Add("$($shell.Name): production milestone pagination -> 3 issues across 2 pages")

        foreach ($milestoneMode in @('MILESTONE_CASE_MISMATCH', 'ISSUE_MILESTONE_TITLE_MISMATCH')) {
            $oldFakeMode = $env:HERDR_OPS_ISSUE41_FAKE_GH_MODE
            $env:HERDR_OPS_ISSUE41_FAKE_GH_MODE = $milestoneMode
            try {
                $previousPreference = $ErrorActionPreference
                try {
                    $ErrorActionPreference = 'Continue'
                    $negativeMilestoneOutput = @(& $shell.Path `
                            -NoProfile `
                            -NonInteractive `
                            -ExecutionPolicy Bypass `
                            -File $milestoneVerifier `
                            -Version 'v0.1.0' `
                            -Repository 'example' `
                            -GhExecutable $fakeGhFixture `
                            -GitHubPageSize 2 2>&1 | ForEach-Object { [string]$_ })
                    $negativeMilestoneExitCode = $LASTEXITCODE
                }
                finally {
                    $ErrorActionPreference = $previousPreference
                }
            }
            finally {
                if ($null -eq $oldFakeMode) { Remove-Item Env:HERDR_OPS_ISSUE41_FAKE_GH_MODE -ErrorAction SilentlyContinue }
                else { $env:HERDR_OPS_ISSUE41_FAKE_GH_MODE = $oldFakeMode }
            }
            if ($negativeMilestoneExitCode -eq 0) {
                throw "$($shell.Name) milestone negative fixture '$milestoneMode' unexpectedly exited 0."
            }
            [void]$completed.Add("$($shell.Name): $milestoneMode -> nonzero")
        }

        $caseDirectory = New-CaseDirectory -ShellName $shell.Name
        try {
            $evidence = New-ReadyEvidenceManifest -CaseDirectory $caseDirectory -SourceCommit $sourceCommit
            $readyOutput = New-UniqueChildPath -Parent $script:TestRoot -Prefix ("output-$($shell.Name)-ready")
            $readyResult = Invoke-AuditCase -ShellPath $shell.Path -FixturePath $readyFixture -EvidencePath $evidence.Path -OutputPath $readyOutput
            Assert-CaseExit -Result $readyResult -ExpectedExitCode 2 -CaseName "$($shell.Name) offline ready fixture"
            $readyReport = Assert-Report -OutputPath $readyOutput -CaseName "$($shell.Name) offline ready fixture"
            if (@($readyReport.DependencyMap).Count -ne 45) { throw "$($shell.Name) dependency map count was $(@($readyReport.DependencyMap).Count), expected 45." }
            $v07WorkIssues = @($readyReport.DependencyMap | Where-Object { $_.Version -eq 'v0.7.0' -and -not $_.IsReleaseTracker })
            if ($v07WorkIssues.Count -ne 6) { throw "$($shell.Name) v0.7.0 work issue count was $($v07WorkIssues.Count), expected 6." }
            $issue103 = @($v07WorkIssues | Where-Object IssueNumber -eq 103)
            if ($issue103.Count -ne 1 -or $issue103[0].RoadmapKey -ne 'V070-06') { throw "$($shell.Name) v0.7.0 supplemental issue #103 was not mapped correctly." }
            $mappingDefectCodes = @(
                'DUPLICATE_OR_INVALID_MILESTONE',
                'DUPLICATE_OR_INVALID_ISSUE_NUMBER',
                'DUPLICATE_ISSUE_KEY',
                'MISSING_OR_DUPLICATE_MILESTONE',
                'MILESTONE_VERSION_MISMATCH',
                'ISSUE_WRONG_MILESTONE_OR_VERSION',
                'RELEASE_TRACKER_MISMATCH',
                'WORK_ISSUE_COUNT_MISMATCH',
                'MISSING_OR_DUPLICATE_PLAN_ISSUE',
                'PULL_REQUEST_RECORD_REJECTED'
            )
            $unexpectedInventoryBlockers = @($readyReport.Blockers | Where-Object {
                    [string]$_.Code -notin @('OFFLINE_FIXTURE_NO_RELEASE_CREDIT', 'EVIDENCE_NOT_OBSERVED')
                })
            if ($unexpectedInventoryBlockers.Count -ne 0) {
                throw "$($shell.Name) ready fixture produced unexpected inventory blockers: $($unexpectedInventoryBlockers.Code -join ', ')."
            }
            if (@($readyReport.Blockers | Where-Object Code -eq 'OFFLINE_FIXTURE_NO_RELEASE_CREDIT').Count -ne 1 -or
                @($readyReport.Blockers | Where-Object Code -eq 'EVIDENCE_NOT_OBSERVED').Count -ne 23) {
                throw "$($shell.Name) ready fixture evidence blocker set was not the expected offline-only set."
            }
            if (@($readyReport.Blockers | Where-Object { $_.Code -in $mappingDefectCodes }).Count -ne 0) {
                throw "$($shell.Name) ready fixture contained an inventory or mapping defect blocker."
            }
            $unmappedWork = @($readyReport.DependencyMap | Where-Object {
                    -not $_.IsReleaseTracker -and
                    [string]::IsNullOrWhiteSpace([string]$_.RoadmapKey) -and
                    [string]$_.RoadmapMapping -cne 'Plan/GITHUB-TRACKING.md supplemental milestone inventory'
                })
            if ($unmappedWork.Count -ne 0) {
                throw "$($shell.Name) ready fixture contained unmapped work issues: $($unmappedWork.IssueNumber -join ', ')."
            }
            $invalidSupplemental = @($readyReport.DependencyMap | Where-Object {
                    -not $_.IsReleaseTracker -and
                    [string]::IsNullOrWhiteSpace([string]$_.RoadmapKey) -and
                    [string]$_.RoadmapMapping -cne 'Plan/GITHUB-TRACKING.md supplemental milestone inventory'
                })
            if ($invalidSupplemental.Count -ne 0) {
                throw "$($shell.Name) ready fixture contained invalid supplemental mappings: $($invalidSupplemental.IssueNumber -join ', ')."
            }
            $mapPairs = @($readyReport.DependencyMap | ForEach-Object { "$($_.Version):$($_.IssueNumber)" })
            if (@($mapPairs | Group-Object | Where-Object Count -gt 1).Count -ne 0) {
                throw "$($shell.Name) ready fixture contained duplicate dependency-map keys."
            }
            if ($readyReport.ReleaseCandidate.Status -ne 'NOT_RECORDED') { throw 'Offline fixture recorded an RC.' }
            if ($readyReport.EvidenceStatus.Runtime.Status -eq 'PASS' -or $readyReport.EvidenceStatus.Release.Status -eq 'PASS') { throw 'Offline fixture granted Runtime/Release credit.' }
            Assert-Contains -Text (Get-Content -LiteralPath (Join-Path $readyOutput 'dependency-audit.txt') -Raw) -Needle 'OFFLINE_FIXTURE_NO_RELEASE_CREDIT' -CaseName "$($shell.Name) offline ready fixture"
            [void]$completed.Add("$($shell.Name): ready fixture -> NOT_READY (45 dependency items)")

            $candidateOutput = New-UniqueChildPath -Parent $script:TestRoot -Prefix ("output-$($shell.Name)-candidate-mismatch")
            $candidateResult = Invoke-AuditCase -ShellPath $shell.Path -FixturePath $readyFixture -EvidencePath $evidence.Path -OutputPath $candidateOutput -CandidateCommit ('A' * 40)
            Assert-CaseExit -Result $candidateResult -ExpectedExitCode 2 -CaseName "$($shell.Name) candidate identity fixture"
            $candidateReport = Assert-Report -OutputPath $candidateOutput -CaseName "$($shell.Name) candidate identity fixture"
            if (@($candidateReport.Blockers | Where-Object Code -eq 'RELEASE_CANDIDATE_COMMIT_MISMATCH').Count -ne 1) { throw 'Mismatched RC commit was not rejected.' }
            if ($candidateReport.ReleaseCandidate.Status -ne 'NOT_RECORDED') { throw 'Mismatched RC commit was recorded.' }
            [void]$completed.Add("$($shell.Name): RC identity mismatch -> rejected")

            $duplicateOutput = New-UniqueChildPath -Parent $script:TestRoot -Prefix ("output-$($shell.Name)-duplicate")
            $duplicateResult = Invoke-AuditCase -ShellPath $shell.Path -FixturePath $duplicateFixture -OutputPath $duplicateOutput
            Assert-CaseExit -Result $duplicateResult -ExpectedExitCode 1 -CaseName "$($shell.Name) duplicate JSON keys"
            if (Test-Path -LiteralPath $duplicateOutput) { throw "$($shell.Name) accepted duplicate JSON keys." }
            [void]$completed.Add("$($shell.Name): duplicate JSON -> rejected")

            $malformedOutput = New-UniqueChildPath -Parent $script:TestRoot -Prefix ("output-$($shell.Name)-malformed")
            $malformedResult = Invoke-AuditCase -ShellPath $shell.Path -FixturePath $malformedFixture -OutputPath $malformedOutput
            Assert-CaseExit -Result $malformedResult -ExpectedExitCode 1 -CaseName "$($shell.Name) malformed JSON"
            if (Test-Path -LiteralPath $malformedOutput) { throw "$($shell.Name) accepted malformed JSON." }
            [void]$completed.Add("$($shell.Name): malformed JSON -> rejected")

            $duplicateNumberPath = Join-Path $caseDirectory 'github-duplicate-number.json'
            $duplicateNumberFixture = Copy-JsonFixture -SourcePath $readyFixture -DestinationPath $duplicateNumberPath
            $duplicateNumberFixture.issues += $duplicateNumberFixture.issues[0]
            Write-Utf8NoBom -Path $duplicateNumberPath -Content (($duplicateNumberFixture | ConvertTo-Json -Depth 20) + "`r`n") -AllowOverwrite
            $duplicateNumberOutput = New-UniqueChildPath -Parent $script:TestRoot -Prefix ("output-$($shell.Name)-duplicate-number")
            $duplicateNumberResult = Invoke-AuditCase -ShellPath $shell.Path -FixturePath $duplicateNumberPath -OutputPath $duplicateNumberOutput
            Assert-CaseExit -Result $duplicateNumberResult -ExpectedExitCode 2 -CaseName "$($shell.Name) duplicate issue number fixture"
            $duplicateNumberReport = Assert-Report -OutputPath $duplicateNumberOutput -CaseName "$($shell.Name) duplicate issue number fixture"
            if (@($duplicateNumberReport.Blockers | Where-Object Code -eq 'DUPLICATE_OR_INVALID_ISSUE_NUMBER').Count -eq 0) { throw 'Duplicate issue number was not rejected.' }
            [void]$completed.Add("$($shell.Name): duplicate issue number -> rejected")

            $duplicateKeyPath = Join-Path $caseDirectory 'github-duplicate-issue-key.json'
            $duplicateKeyFixture = Copy-JsonFixture -SourcePath $readyFixture -DestinationPath $duplicateKeyPath
            $duplicateKeyFixture.issues | Where-Object number -eq 1 | Add-Member -MemberType NoteProperty -Name body -Value '<!-- herdr-issue-key: DUPLICATE-KEY -->' -Force
            $duplicateKeyFixture.issues | Where-Object number -eq 2 | Add-Member -MemberType NoteProperty -Name body -Value '<!-- herdr-issue-key: DUPLICATE-KEY -->' -Force
            Write-Utf8NoBom -Path $duplicateKeyPath -Content (($duplicateKeyFixture | ConvertTo-Json -Depth 20) + "`r`n") -AllowOverwrite
            $duplicateKeyOutput = New-UniqueChildPath -Parent $script:TestRoot -Prefix ("output-$($shell.Name)-duplicate-key")
            $duplicateKeyResult = Invoke-AuditCase -ShellPath $shell.Path -FixturePath $duplicateKeyPath -OutputPath $duplicateKeyOutput
            Assert-CaseExit -Result $duplicateKeyResult -ExpectedExitCode 2 -CaseName "$($shell.Name) duplicate issue key fixture"
            $duplicateKeyReport = Assert-Report -OutputPath $duplicateKeyOutput -CaseName "$($shell.Name) duplicate issue key fixture"
            if (@($duplicateKeyReport.Blockers | Where-Object Code -eq 'DUPLICATE_ISSUE_KEY').Count -eq 0) { throw 'Duplicate issue key was not rejected.' }
            [void]$completed.Add("$($shell.Name): duplicate issue key -> rejected")

            $pullRequestPath = Join-Path $caseDirectory 'github-pull-request-record.json'
            $pullRequestFixture = Copy-JsonFixture -SourcePath $readyFixture -DestinationPath $pullRequestPath
            $pullRequestIssue = $pullRequestFixture.issues | Where-Object number -eq 7
            $pullRequestIssue | Add-Member -MemberType NoteProperty -Name pull_request -Value ([pscustomobject]@{ url = 'https://example.invalid/pulls/7' }) -Force
            Write-Utf8NoBom -Path $pullRequestPath -Content (($pullRequestFixture | ConvertTo-Json -Depth 20) + "`r`n") -AllowOverwrite
            $pullRequestOutput = New-UniqueChildPath -Parent $script:TestRoot -Prefix ("output-$($shell.Name)-pull-request")
            $pullRequestResult = Invoke-AuditCase -ShellPath $shell.Path -FixturePath $pullRequestPath -OutputPath $pullRequestOutput
            Assert-CaseExit -Result $pullRequestResult -ExpectedExitCode 2 -CaseName "$($shell.Name) pull request record"
            $pullRequestReport = Assert-Report -OutputPath $pullRequestOutput -CaseName "$($shell.Name) pull request record"
            if (@($pullRequestReport.Blockers | Where-Object { $_.Code -eq 'PULL_REQUEST_RECORD_REJECTED' -and $_.IssueNumber -eq 7 }).Count -ne 1) {
                throw "$($shell.Name) pull request record was not rejected with an explicit blocker."
            }
            [void]$completed.Add("$($shell.Name): pull request record -> explicit blocker")

            $openFixturePath = Join-Path $caseDirectory 'github-open.json'
            $openFixture = Copy-JsonFixture -SourcePath $readyFixture -DestinationPath $openFixturePath
            ($openFixture.issues | Where-Object number -eq 7).state = 'open'
            Write-Utf8NoBom -Path $openFixturePath -Content (($openFixture | ConvertTo-Json -Depth 20) + "`r`n") -AllowOverwrite
            $openOutput = New-UniqueChildPath -Parent $script:TestRoot -Prefix ("output-$($shell.Name)-open")
            $openResult = Invoke-AuditCase -ShellPath $shell.Path -FixturePath $openFixturePath -OutputPath $openOutput
            Assert-CaseExit -Result $openResult -ExpectedExitCode 2 -CaseName "$($shell.Name) open dependency fixture"
            $openReport = Assert-Report -OutputPath $openOutput -CaseName "$($shell.Name) open dependency fixture"
            if (@($openReport.Blockers | Where-Object { $_.Code -eq 'GITHUB_OPEN_DEPENDENCY' -and $_.IssueNumber -eq 7 }).Count -ne 1) { throw 'Open dependency #7 was not reported exactly.' }
            [void]$completed.Add("$($shell.Name): open dependency -> exact blocker")

            $wrongMilestonePath = Join-Path $caseDirectory 'github-wrong-milestone.json'
            $wrongMilestoneFixture = Copy-JsonFixture -SourcePath $readyFixture -DestinationPath $wrongMilestonePath
            $wrongMilestoneIssue = $wrongMilestoneFixture.issues | Where-Object number -eq 1
            $wrongMilestoneIssue.milestone.number = 2
            $wrongMilestoneIssue.milestone.title = 'v0.2.0'
            Write-Utf8NoBom -Path $wrongMilestonePath -Content (($wrongMilestoneFixture | ConvertTo-Json -Depth 20) + "`r`n") -AllowOverwrite
            $wrongMilestoneOutput = New-UniqueChildPath -Parent $script:TestRoot -Prefix ("output-$($shell.Name)-wrong-milestone")
            $wrongMilestoneResult = Invoke-AuditCase -ShellPath $shell.Path -FixturePath $wrongMilestonePath -OutputPath $wrongMilestoneOutput
            Assert-CaseExit -Result $wrongMilestoneResult -ExpectedExitCode 2 -CaseName "$($shell.Name) wrong milestone fixture"
            $wrongMilestoneReport = Assert-Report -OutputPath $wrongMilestoneOutput -CaseName "$($shell.Name) wrong milestone fixture"
            if (@($wrongMilestoneReport.Blockers | Where-Object Code -eq 'WORK_ISSUE_COUNT_MISMATCH').Count -eq 0) { throw 'Wrong milestone did not produce count mismatch.' }
            [void]$completed.Add("$($shell.Name): wrong milestone -> rejected mapping")

            $staleManifest = New-ReadyEvidenceManifest -CaseDirectory (Join-Path $caseDirectory 'stale') -SourceCommit $sourceCommit
            $staleManifest.Data.sourceCommit = ('0' * 40)
            $staleManifest.Data.entries[0].sourceCommit = ('0' * 40)
            Write-Utf8NoBom -Path $staleManifest.Path -Content (($staleManifest.Data | ConvertTo-Json -Depth 20) + "`r`n") -AllowOverwrite
            $staleOutput = New-UniqueChildPath -Parent $script:TestRoot -Prefix ("output-$($shell.Name)-stale")
            $staleResult = Invoke-AuditCase -ShellPath $shell.Path -FixturePath $readyFixture -EvidencePath $staleManifest.Path -OutputPath $staleOutput
            Assert-CaseExit -Result $staleResult -ExpectedExitCode 2 -CaseName "$($shell.Name) stale evidence fixture"
            $staleReport = Assert-Report -OutputPath $staleOutput -CaseName "$($shell.Name) stale evidence fixture"
            if (@($staleReport.Blockers | Where-Object Code -eq 'EVIDENCE_MANIFEST_COMMIT_MISMATCH').Count -eq 0) { throw 'Stale manifest commit was not rejected.' }
            [void]$completed.Add("$($shell.Name): stale commit -> rejected")

            $wrongArtifactManifest = New-ReadyEvidenceManifest -CaseDirectory (Join-Path $caseDirectory 'wrong-artifact') -SourceCommit $sourceCommit
            $wrongArtifactManifest.Data.entries[0].artifacts[0].sha256 = ('F' * 64)
            Write-Utf8NoBom -Path $wrongArtifactManifest.Path -Content (($wrongArtifactManifest.Data | ConvertTo-Json -Depth 20) + "`r`n") -AllowOverwrite
            $wrongArtifactOutput = New-UniqueChildPath -Parent $script:TestRoot -Prefix ("output-$($shell.Name)-wrong-artifact")
            $wrongArtifactResult = Invoke-AuditCase -ShellPath $shell.Path -FixturePath $readyFixture -EvidencePath $wrongArtifactManifest.Path -OutputPath $wrongArtifactOutput
            Assert-CaseExit -Result $wrongArtifactResult -ExpectedExitCode 2 -CaseName "$($shell.Name) wrong artifact fixture"
            $wrongArtifactReport = Assert-Report -OutputPath $wrongArtifactOutput -CaseName "$($shell.Name) wrong artifact fixture"
            if (@($wrongArtifactReport.Blockers | Where-Object Code -eq 'ARTIFACT_HASH_MISMATCH').Count -eq 0) { throw 'Wrong artifact hash was not rejected.' }
            [void]$completed.Add("$($shell.Name): wrong artifact -> rejected")

            $conflationManifest = New-ReadyEvidenceManifest -CaseDirectory (Join-Path $caseDirectory 'conflation') -SourceCommit $sourceCommit
            $conflationManifest.Data.entries[0].sourcePaths = @('tests/HerdrOps.RuntimeTests')
            Write-Utf8NoBom -Path $conflationManifest.Path -Content (($conflationManifest.Data | ConvertTo-Json -Depth 20) + "`r`n") -AllowOverwrite
            $conflationOutput = New-UniqueChildPath -Parent $script:TestRoot -Prefix ("output-$($shell.Name)-conflation")
            $conflationResult = Invoke-AuditCase -ShellPath $shell.Path -FixturePath $readyFixture -EvidencePath $conflationManifest.Path -OutputPath $conflationOutput
            Assert-CaseExit -Result $conflationResult -ExpectedExitCode 2 -CaseName "$($shell.Name) evidence-class conflation fixture"
            $conflationReport = Assert-Report -OutputPath $conflationOutput -CaseName "$($shell.Name) evidence-class conflation fixture"
            if (@($conflationReport.Blockers | Where-Object Code -eq 'SYNTHETIC_WPF_RUNTIME_CONFLATION').Count -eq 0) { throw 'RuntimeTests conflation was not rejected.' }
            [void]$completed.Add("$($shell.Name): RuntimeTests conflation -> rejected")

            $reparseTarget = New-OwnedDirectory -Path (New-UniqueChildPath -Parent $script:TestRoot -Prefix ("reparse-target-$($shell.Name)"))
            $reparseSentinel = Join-Path $reparseTarget 'sentinel.txt'
            Write-Utf8NoBom -Path $reparseSentinel -Content 'reparse target must remain intact'
            $reparseJunction = New-UniqueChildPath -Parent $script:TestRoot -Prefix ("reparse-link-$($shell.Name)")
            New-Item -ItemType Junction -Path $reparseJunction -Target $reparseTarget -ErrorAction Stop | Out-Null
            Register-OwnedPath -Path $reparseJunction -AllowReparse | Out-Null
            try {
                $reparseOutput = Join-Path $reparseJunction 'nested'
                $reparseResult = Invoke-AuditCase -ShellPath $shell.Path -FixturePath $readyFixture -OutputPath $reparseOutput -PermitHostileOutputPath
                Assert-CaseExit -Result $reparseResult -ExpectedExitCode 1 -CaseName "$($shell.Name) reparse output path"
                if (Test-Path -LiteralPath $reparseOutput) { throw "$($shell.Name) accepted a reparse output path." }
                if (-not (Test-Path -LiteralPath $reparseJunction) -or -not (Test-Path -LiteralPath $reparseSentinel -PathType Leaf)) {
                    throw "$($shell.Name) reparse negative damaged its preexisting link or target."
                }
            }
            finally {
                # The owned-path cleanup removes only the junction itself; it
                # never recurses through a reparse point into the target.
            }
            [void]$completed.Add("$($shell.Name): reparse output -> rejected")

            $traversalName = 'issue-41-escape-' + [Guid]::NewGuid().ToString('N')
            $traversalOutput = Join-Path $script:TestRoot ('..\' + $traversalName)
            $traversalResult = Invoke-AuditCase -ShellPath $shell.Path -FixturePath $readyFixture -OutputPath $traversalOutput -PermitHostileOutputPath
            Assert-CaseExit -Result $traversalResult -ExpectedExitCode 1 -CaseName "$($shell.Name) output traversal"
            if (Test-Path -LiteralPath (Join-Path $testRootParent $traversalName)) { throw "$($shell.Name) accepted output traversal." }
            [void]$completed.Add("$($shell.Name): output traversal -> rejected")

            $preexistingOutput = New-UniqueChildPath -Parent $script:TestRoot -Prefix ("preexisting-file-$($shell.Name)")
            $preexistingContent = 'preexisting fixture sentinel'
            Write-Utf8NoBom -Path $preexistingOutput -Content $preexistingContent
            $preexistingResult = Invoke-AuditCase -ShellPath $shell.Path -FixturePath $readyFixture -OutputPath $preexistingOutput
            Assert-CaseExit -Result $preexistingResult -ExpectedExitCode 1 -CaseName "$($shell.Name) preexisting output file"
            if (-not (Test-Path -LiteralPath $preexistingOutput -PathType Leaf) -or
                [IO.File]::ReadAllText($preexistingOutput) -cne $preexistingContent) {
                throw "$($shell.Name) overwrote or removed a preexisting output file."
            }
            [void]$completed.Add("$($shell.Name): preexisting output file -> preserved")

            $missingGhOutput = New-UniqueChildPath -Parent $script:TestRoot -Prefix ("output-$($shell.Name)-gh-failure")
            $missingGhResult = Invoke-AuditCase -ShellPath $shell.Path -OutputPath $missingGhOutput -GhCommand 'herdops-command-that-does-not-exist'
            Assert-CaseExit -Result $missingGhResult -ExpectedExitCode 1 -CaseName "$($shell.Name) missing gh"
            if (Test-Path -LiteralPath $missingGhOutput) { throw "$($shell.Name) accepted missing gh." }
            [void]$completed.Add("$($shell.Name): gh failure -> rejected")

            $dirtyProbe = Join-Path $repositoryRoot ('issue-41-dirty-probe-' + [Guid]::NewGuid().ToString('N') + '.txt')
            Write-OwnedRepositoryUtf8NoBom -Path $dirtyProbe -Content 'dirty checkout probe'
            try {
                $dirtyOutput = New-UniqueChildPath -Parent $script:TestRoot -Prefix ("output-$($shell.Name)-dirty")
                $dirtyResult = Invoke-AuditCase -ShellPath $shell.Path -FixturePath $readyFixture -OutputPath $dirtyOutput
                Assert-CaseExit -Result $dirtyResult -ExpectedExitCode 1 -CaseName "$($shell.Name) dirty checkout"
                if (Test-Path -LiteralPath $dirtyOutput) { throw "$($shell.Name) accepted a dirty checkout." }
            }
            finally {
                Remove-OwnedPathNow -Path $dirtyProbe
            }
            [void]$completed.Add("$($shell.Name): dirty checkout -> rejected")

            # Regression: ANSI normalization handles bounded ECMA-48 controls
            # without consuming adjacent plain text.
            $esc = [char]27
            $bel = [char]7
            $c1Csi = [char]0x9b
            $c1St = [char]0x9c
            $ansiSample = "Plain [brackets] $($esc)[38:2::255:0:0mError$($esc)[>0c: $($esc)]0;Window Title$($bel) $($esc)]1;Window Title$($esc)\ $($esc)Pbinary DCS$($esc)\ $($esc)Xbinary SOS$($esc)\ $($esc)^binary PM$($esc)\ $($esc)_binary APC$($esc)\ $($c1Csi)31mC1 CSI$c1St$($esc)7 after"
            $ansiStripped = ConvertTo-PlainText -Text $ansiSample
            if ($ansiStripped -notmatch 'Plain \[brackets\]\s+Error:\s+C1 CSI after' -or
                $ansiStripped.IndexOf([string][char]27, [StringComparison]::Ordinal) -ge 0 -or
                $ansiStripped.IndexOf([string][char]0x9b, [StringComparison]::Ordinal) -ge 0) {
                throw "$($shell.Name) ANSI strip regression failed: $ansiStripped"
            }
            $plainSample = 'literal [38:2::255:0:0m] and ordinary text [not-control]'
            if ((ConvertTo-PlainText -Text $plainSample) -cne $plainSample) {
                throw "$($shell.Name) ANSI normalization corrupted plain text."
            }
            Assert-Contains -Text $ansiSample -Needle 'C1 CSI after' -CaseName "$($shell.Name) ANSI Assert-Contains regression"
            $overlongRejected = $false
            try {
                ConvertTo-PlainText -Text ($esc + ']0;' + ('x' * 4097) + $bel) | Out-Null
            }
            catch {
                $overlongRejected = $true
            }
            if (-not $overlongRejected) {
                throw "$($shell.Name) ANSI normalizer did not enforce its bounded control-string limit."
            }
            [void]$completed.Add("$($shell.Name): ANSI CSI/OSC/DCS/C1 strip -> bounded")

            $ansiDefinition = (Get-Command ConvertTo-PlainText -CommandType Function).Definition
            $ansiCrossShellScript = @'
__ANSI_FUNCTION__
$esc = [char]27
$bel = [char]7
$c1St = [char]0x9c
$sample = 'keep [literal] ' + $esc + '[38:2::255:0:0mCSI' + $esc + ']0;OSC' + $bel + ' ' + $esc + 'P DCS' + $esc + '\' + ' tail' + $c1St
$plain = 'ordinary [text]'
if ((ConvertTo-PlainText -Text $plain) -cne $plain) { exit 1 }
$clean = ConvertTo-PlainText -Text $sample
if ($clean -notmatch 'keep \[literal\] CSI\s+tail' -or $clean.IndexOf([string][char]27, [StringComparison]::Ordinal) -ge 0) { exit 1 }
try { ConvertTo-PlainText -Text ($esc + ']0;' + ('x' * 4097) + $bel) | Out-Null; exit 1 } catch { }
Write-Output 'ANSI_CROSS_SHELL_PASS'
'@
            $ansiCrossShellScript = $ansiCrossShellScript.Replace('__ANSI_FUNCTION__', "function ConvertTo-PlainText {`r`n$ansiDefinition`r`n}")
            $encodedAnsiScript = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($ansiCrossShellScript))
            $previousPreference = $ErrorActionPreference
            try {
                $ErrorActionPreference = 'Continue'
                $ansiChildOutput = @(& $shell.Path -NoLogo -NoProfile -NonInteractive -EncodedCommand $encodedAnsiScript 2>&1 | ForEach-Object { [string]$_ })
                $ansiChildExitCode = $LASTEXITCODE
            }
            finally {
                $ErrorActionPreference = $previousPreference
            }
            $ansiChildText = ConvertTo-PlainText -Text ($ansiChildOutput -join "`n")
            if ($ansiChildExitCode -ne 0 -or $ansiChildText -notmatch 'ANSI_CROSS_SHELL_PASS') {
                throw "$($shell.Name) cross-shell ANSI normalizer regression failed (exit $ansiChildExitCode): $ansiChildText"
            }
            [void]$completed.Add("$($shell.Name): ANSI parser cross-shell -> PASS")

            # Regression: PS5 native stderr capture does not throw ActionPreferenceStopException / RemoteException
            $stderrScript = @"
`$ErrorActionPreference = 'Stop'
`$prev = `$ErrorActionPreference
try {
    `$ErrorActionPreference = 'Continue'
    `$res = @(& cmd.exe /c "echo regression_stderr_message 1>&2 & echo regression_stdout_message" 2>&1 | ForEach-Object { [string]`$_ })
    `$ec = `$LASTEXITCODE
}
finally {
    `$ErrorActionPreference = `$prev
}
`$joined = `$res -join ' '
if (`$ec -ne 0 -or `$joined -notmatch 'regression_stderr_message' -or `$joined -notmatch 'regression_stdout_message') {
    exit 1
}
Write-Output 'STDERR_CAPTURE_PASS'
"@
            $encodedStderrScript = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($stderrScript))
            $previousPreference = $ErrorActionPreference
            try {
                $ErrorActionPreference = 'Continue'
                $stderrOutput = @(& $shell.Path -NoProfile -NonInteractive -EncodedCommand $encodedStderrScript 2>&1 | ForEach-Object { [string]$_ })
                $stderrExitCode = $LASTEXITCODE
            }
            finally {
                $ErrorActionPreference = $previousPreference
            }
            $stderrText = ConvertTo-PlainText -Text ($stderrOutput -join "`n")
            if ($stderrExitCode -ne 0 -or $stderrText -notmatch 'STDERR_CAPTURE_PASS') {
                throw "$($shell.Name) native stderr capture regression failed (exit $stderrExitCode): $stderrText"
            }
            [void]$completed.Add("$($shell.Name): native stderr capture -> deterministic")

            # Regression: Omitting supplemental v0.7.0 issue (#103) is rejected with count mismatch
            $missingSupplementalPath = Join-Path $caseDirectory 'github-missing-v07-supplemental.json'
            $missingSupplementalFixture = Copy-JsonFixture -SourcePath $readyFixture -DestinationPath $missingSupplementalPath
            $missingSupplementalFixture.issues = @($missingSupplementalFixture.issues | Where-Object { [int]$_.number -ne 103 })
            Write-Utf8NoBom -Path $missingSupplementalPath -Content (($missingSupplementalFixture | ConvertTo-Json -Depth 20) + "`r`n") -AllowOverwrite
            $missingSupplementalOutput = New-UniqueChildPath -Parent $script:TestRoot -Prefix ("output-$($shell.Name)-missing-v07-supplemental")
            $missingSupplementalResult = Invoke-AuditCase -ShellPath $shell.Path -FixturePath $missingSupplementalPath -OutputPath $missingSupplementalOutput
            Assert-CaseExit -Result $missingSupplementalResult -ExpectedExitCode 2 -CaseName "$($shell.Name) missing v0.7 supplemental fixture"
            $missingSupplementalReport = Assert-Report -OutputPath $missingSupplementalOutput -CaseName "$($shell.Name) missing v0.7 supplemental fixture"
            if (@($missingSupplementalReport.Blockers | Where-Object { $_.Code -eq 'WORK_ISSUE_COUNT_MISMATCH' -and $_.Version -eq 'v0.7.0' }).Count -eq 0) {
                throw "$($shell.Name) missing v0.7.0 supplemental issue did not trigger WORK_ISSUE_COUNT_MISMATCH."
            }
            if (@($missingSupplementalReport.Blockers | Where-Object { $_.Code -eq 'MISSING_OR_DUPLICATE_PLAN_ISSUE' -and $_.Version -eq 'v0.7.0' }).Count -eq 0) {
                throw "$($shell.Name) missing v0.7.0 supplemental issue did not trigger MISSING_OR_DUPLICATE_PLAN_ISSUE."
            }
            [void]$completed.Add("$($shell.Name): missing v0.7 supplemental -> rejected count")

            # Regression: Subprocess exit 0 explicitly returned on success
            if ($paginationExitCode -ne 0) {
                throw "$($shell.Name) pagination script did not exit with explicit 0: $paginationExitCode"
            }
            if ($milestoneExitCode -ne 0) {
                throw "$($shell.Name) milestone verifier script did not exit with explicit 0: $milestoneExitCode"
            }
            [void]$completed.Add("$($shell.Name): explicit exit 0 -> verified")
        }
        finally { }
    }
}
finally {
    if ($null -ne $runRootInfo) {
        Remove-OwnedPaths -RunRoot $runRootInfo.Root -OwnershipMarker $runRootInfo.Marker
    }
}

$completed | ForEach-Object { Write-Output $_ }
Write-Output ("Issue #41 fixture tests passed: {0} cases" -f $completed.Count)

exit 0
