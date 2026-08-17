Set-StrictMode -Version Latest

function Get-Issue43MaskedCharacter {
    param(
        [Parameter(Mandatory)]
        [char]$Character
    )

    if ($Character -eq "`r" -or $Character -eq "`n") {
        return $Character
    }

    return ' '
}

function ConvertTo-Issue43CommentFreeText {
    param(
        [Parameter(Mandatory)]
        [string]$Text
    )

    $builder = New-Object System.Text.StringBuilder
    $state = 'Code'
    $index = 0
    while ($index -lt $Text.Length) {
        $character = $Text[$index]
        $next = if ($index + 1 -lt $Text.Length) { $Text[$index + 1] } else { [char]0 }

        if ($state -eq 'Code') {
            if ($character -eq '/' -and $next -eq '/') {
                [void]$builder.Append('  ')
                $index += 2
                $state = 'LineComment'
                continue
            }

            if ($character -eq '/' -and $next -eq '*') {
                [void]$builder.Append('  ')
                $index += 2
                $state = 'BlockComment'
                continue
            }

            if ($character -eq '<' -and $next -eq '!' -and $index + 3 -lt $Text.Length -and
                $Text.Substring($index, 4) -eq '<!--') {
                [void]$builder.Append('    ')
                $index += 4
                $state = 'XmlComment'
                continue
            }

            [void]$builder.Append($character)
            $index++
            continue
        }

        if ($state -eq 'LineComment') {
            if ($character -eq "`r" -or $character -eq "`n") {
                [void]$builder.Append($character)
                $state = 'Code'
            } else {
                [void]$builder.Append(' ')
            }
            $index++
            continue
        }

        if ($state -eq 'BlockComment') {
            if ($character -eq '*' -and $next -eq '/') {
                [void]$builder.Append('  ')
                $index += 2
                $state = 'Code'
                continue
            }

            [void]$builder.Append((Get-Issue43MaskedCharacter -Character $character))
            $index++
            continue
        }

        if ($state -eq 'XmlComment') {
            if ($character -eq '-' -and $index + 2 -lt $Text.Length -and
                $Text.Substring($index, 3) -eq '-->') {
                [void]$builder.Append('   ')
                $index += 3
                $state = 'Code'
                continue
            }

            [void]$builder.Append((Get-Issue43MaskedCharacter -Character $character))
            $index++
            continue
        }
    }

    return $builder.ToString()
}

function ConvertTo-Issue43CodeOnlyText {
    param(
        [Parameter(Mandatory)]
        [string]$Text
    )

    $commentFree = ConvertTo-Issue43CommentFreeText -Text $Text
    $builder = New-Object System.Text.StringBuilder
    $state = 'Code'
    $index = 0
    while ($index -lt $commentFree.Length) {
        $character = $commentFree[$index]

        if ($state -eq 'Code') {
            if ($character -eq '"' -or $character -eq "'") {
                [void]$builder.Append(' ')
                $state = if ($character -eq '"') { 'DoubleString' } else { 'CharLiteral' }
                $index++
                continue
            }

            [void]$builder.Append($character)
            $index++
            continue
        }

        if ($character -eq '\\') {
            [void]$builder.Append(' ')
            if ($index + 1 -lt $commentFree.Length) {
                $index++
                $escaped = $commentFree[$index]
                [void]$builder.Append((Get-Issue43MaskedCharacter -Character $escaped))
            }
            $index++
            continue
        }

        if (($state -eq 'DoubleString' -and $character -eq '"') -or
            ($state -eq 'CharLiteral' -and $character -eq "'")) {
            [void]$builder.Append(' ')
            $state = 'Code'
            $index++
            continue
        }

        [void]$builder.Append((Get-Issue43MaskedCharacter -Character $character))
        $index++
    }

    return $builder.ToString()
}

function Test-Issue43MatchOutsideQuotedText {
    param(
        [Parameter(Mandatory)]
        [string]$Text,

        [Parameter(Mandatory)]
        [int]$Index
    )

    $quote = [char]0
    $cursor = 0
    while ($cursor -lt $Index) {
        $character = $Text[$cursor]
        if ($character -eq '\\' -and $cursor + 1 -lt $Index) {
            $cursor += 2
            continue
        }

        if ($quote -eq [char]0 -and ($character -eq '"' -or $character -eq "'")) {
            $quote = $character
        } elseif ($quote -ne [char]0 -and $character -eq $quote) {
            $quote = [char]0
        }
        $cursor++
    }

    return $quote -eq [char]0
}

function Test-Issue43ForbiddenDeclaration {
    param(
        [Parameter(Mandatory)]
        [string]$Text,

        [Parameter(Mandatory)]
        [string]$CodePattern,

        [Parameter(Mandatory)]
        [string]$RawPattern
    )

    $codeOnly = ConvertTo-Issue43CodeOnlyText -Text $Text
    $commentFree = ConvertTo-Issue43CommentFreeText -Text $Text
    $codeMatch = [regex]::Match($codeOnly, $CodePattern, [Text.RegularExpressions.RegexOptions]::IgnoreCase)
    $rawMatch = $null
    foreach ($candidate in [regex]::Matches($commentFree, $RawPattern, [Text.RegularExpressions.RegexOptions]::IgnoreCase)) {
        if (Test-Issue43MatchOutsideQuotedText -Text $commentFree -Index $candidate.Index) {
            $rawMatch = $candidate
            break
        }
    }
    return [pscustomobject]@{
        IsMatch = $codeMatch.Success -or $null -ne $rawMatch
        Match = if ($codeMatch.Success) { $codeMatch.Value } elseif ($null -ne $rawMatch) { $rawMatch.Value } else { '' }
    }
}

function Test-Issue43ScannerFixtures {
    $commentOnly = @"
// TcpListener and requireAdministrator are prohibited declarations.
/* Socket.Bind and [DllImport("ws2_32.dll")] are only documentation here. */
var message = "HttpListener, runas, and NativeLibrary.Load(\"bind\")";
"@
    $listenerCode = 'var listener = new TcpListener(IPAddress.Loopback, 1234);'
    $dynamicListener = '[DllImport("ws2_32.dll", EntryPoint = "bind")] static extern int NativeBind();'
    $adminCode = '<requestedExecutionLevel level="requireAdministrator" />'
    $adminDynamic = 'var verb = "runas";'

    $commentResult = Test-Issue43ForbiddenDeclaration `
        -Text $commentOnly `
        -CodePattern '(?i)\b(?:TcpListener|HttpListener|Socket\s*\.\s*Bind|requireAdministrator)\b' `
        -RawPattern '(?i)(?:DllImport|LibraryImport)[^\r\n]*(?:ws2_32|bind)|(?:NativeLibrary|GetProcAddress)[^\r\n]*(?:bind|listen)'
    $listenerResult = Test-Issue43ForbiddenDeclaration `
        -Text $listenerCode `
        -CodePattern '(?i)\b(?:TcpListener|HttpListener|Socket\s*\.\s*Bind)\b' `
        -RawPattern '(?i)(?:DllImport|LibraryImport)[^\r\n]*(?:ws2_32|bind)|(?:NativeLibrary|GetProcAddress)[^\r\n]*(?:bind|listen)'
    $dynamicResult = Test-Issue43ForbiddenDeclaration `
        -Text $dynamicListener `
        -CodePattern '(?i)\b(?:TcpListener|HttpListener|Socket\s*\.\s*Bind)\b' `
        -RawPattern '(?i)(?:DllImport|LibraryImport)[^\r\n]*(?:ws2_32|bind)|(?:NativeLibrary|GetProcAddress)[^\r\n]*(?:bind|listen)'
    $adminResult = Test-Issue43ForbiddenDeclaration `
        -Text $adminCode `
        -CodePattern '(?i)\b(?:requireAdministrator|runas|WindowsBuiltInRole\s*\.\s*Administrator|IsInRole)\b' `
        -RawPattern '(?i)(?:requestedExecutionLevel\b|uiAccess\s*=)|(?:Verb|verb)\s*=\s*["'']runas'
    $adminDynamicResult = Test-Issue43ForbiddenDeclaration `
        -Text $adminDynamic `
        -CodePattern '(?i)\b(?:requireAdministrator|runas|WindowsBuiltInRole\s*\.\s*Administrator|IsInRole)\b' `
        -RawPattern '(?i)(?:requestedExecutionLevel\b|uiAccess\s*=)|(?:Verb|verb)\s*=\s*["'']runas'

    if ($commentResult.IsMatch -or -not $listenerResult.IsMatch -or -not $dynamicResult.IsMatch -or
        -not $adminResult.IsMatch -or -not $adminDynamicResult.IsMatch) {
        throw 'Issue #43 scanner fixtures did not preserve comment/string exclusions and dynamic declaration detection.'
    }

    return $true
}

function ConvertTo-Issue43ReportLines {
    param(
        [Parameter(Mandatory)]
        [AllowNull()]
        [AllowEmptyCollection()]
        [AllowEmptyString()]
        [object[]]$Lines
    )

    if ($null -eq $Lines) {
        throw 'Issue #43 report lines cannot be null.'
    }
    if ($Lines.Count -eq 0) {
        throw 'Issue #43 report lines cannot be empty.'
    }

    $normalized = New-Object System.Collections.Generic.List[string]
    $pending = New-Object 'System.Collections.Generic.Stack[object]'
    for ($index = $Lines.Count - 1; $index -ge 0; $index--) {
        $pending.Push($Lines[$index])
    }

    while ($pending.Count -gt 0) {
        $line = $pending.Pop()
        if ($null -eq $line) {
            throw 'Issue #43 report lines cannot contain null values.'
        }
        if ($line -is [string]) {
            [void]$normalized.Add([string]$line)
            continue
        }
        if ($line -is [Array]) {
            if ($line.Length -eq 0) {
                throw 'Issue #43 report lines cannot contain empty nested collections.'
            }
            for ($index = $line.Length - 1; $index -ge 0; $index--) {
                $pending.Push($line[$index])
            }
            continue
        }
        throw "Issue #43 report line must be a string or line collection, but was $($line.GetType().FullName)."
    }

    return $normalized.ToArray()
}

function Assert-Issue43RequiredReportFields {
    param(
        [Parameter(Mandatory)]
        [hashtable]$Fields
    )

    $requiredFields = @(
        'Issue',
        'Version',
        'SourceCommit',
        'CandidateCommit',
        'DirectParentCommit',
        'Branch',
        'Result'
    )

    foreach ($fieldName in $requiredFields) {
        if (-not $Fields.ContainsKey($fieldName)) {
            throw "Issue #43 required report field is missing: $fieldName."
        }

        $value = $Fields[$fieldName]
        if ($null -eq $value -or [string]::IsNullOrWhiteSpace([string]$value)) {
            throw "Issue #43 required report field is empty: $fieldName."
        }
    }

    return $true
}

function Test-Issue43ReportWriterFixtures {
    $separatorLines = @(ConvertTo-Issue43ReportLines -Lines @('header', @('', 'body'), 'footer'))
    if ($separatorLines.Count -ne 4 -or $separatorLines[1] -ne '') {
        throw 'Issue #43 report writer fixture did not preserve the empty separator line.'
    }

    try {
        ConvertTo-Issue43ReportLines -Lines @('header', $null, 'footer') | Out-Null
        throw 'Issue #43 report writer fixture accepted a null line.'
    } catch {
        if ($_.Exception.Message -notlike '*cannot contain null values*') {
            throw
        }
    }

    try {
        ConvertTo-Issue43ReportLines -Lines @() | Out-Null
        throw 'Issue #43 report writer fixture accepted an empty report.'
    } catch {
        if ($_.Exception.Message -notlike '*cannot be empty*') {
            throw
        }
    }

    $validFields = @{
        Issue = '#43'
        Version = 'v1.0.0'
        SourceCommit = ('a' * 40)
        CandidateCommit = ('b' * 40)
        DirectParentCommit = ('c' * 40)
        Branch = 'codex/v10-issue-43-security-review'
        Result = 'PASS'
    }
    Assert-Issue43RequiredReportFields -Fields $validFields | Out-Null

    $missingResultFields = @{}
    foreach ($key in $validFields.Keys) {
        if ($key -ne 'Result') {
            $missingResultFields[$key] = $validFields[$key]
        }
    }
    try {
        Assert-Issue43RequiredReportFields -Fields $missingResultFields | Out-Null
        throw 'Issue #43 report writer fixture accepted a missing required field.'
    } catch {
        if ($_.Exception.Message -notlike '*required report field is missing: Result*') {
            throw
        }
    }

    $emptyResultFields = @{}
    foreach ($key in $validFields.Keys) {
        $emptyResultFields[$key] = $validFields[$key]
    }
    $emptyResultFields['Result'] = ''
    try {
        Assert-Issue43RequiredReportFields -Fields $emptyResultFields | Out-Null
        throw 'Issue #43 report writer fixture accepted an empty required field.'
    } catch {
        if ($_.Exception.Message -notlike '*required report field is empty: Result*') {
            throw
        }
    }

    return $true
}
