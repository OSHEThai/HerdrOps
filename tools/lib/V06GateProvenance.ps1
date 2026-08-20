function Get-RepositoryRelativePath {
    param(
        [Parameter(Mandatory = $true)]
        [string]$RepositoryRoot,

        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    $separatorChars = [char[]]@(
        [IO.Path]::DirectorySeparatorChar,
        [IO.Path]::AltDirectorySeparatorChar)
    $normalizedRoot = [IO.Path]::GetFullPath($RepositoryRoot).TrimEnd($separatorChars)
    $normalizedPath = [IO.Path]::GetFullPath($Path)
    $rootPrefix = $normalizedRoot + [IO.Path]::DirectorySeparatorChar
    if (-not $normalizedPath.StartsWith($rootPrefix, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Path is outside the repository root: $normalizedPath"
    }

    return $normalizedPath.Substring($rootPrefix.Length).Replace('\', '/')
}

function Assert-FreshEvidence {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,

        [Parameter(Mandatory = $true)]
        [DateTime]$NotBeforeUtc,

        [Parameter(Mandatory = $true)]
        [string]$Description
    )

    $item = Get-Item -LiteralPath $Path
    if ($item.LastWriteTimeUtc -lt $NotBeforeUtc) {
        throw "$Description was not freshly written by this gate run (stale or reused from a prior run): $Path"
    }
}
