Set-StrictMode -Version Latest

function Move-StrictJsonWhitespace {
    param(
        [Parameter(Mandatory)]
        [string]$Json,

        [Parameter(Mandatory)]
        [ref]$Index
    )

    while ($Index.Value -lt $Json.Length) {
        $codePoint = [int][char]$Json[$Index.Value]
        if (@(9, 10, 13, 32) -notcontains $codePoint) {
            return
        }
        $Index.Value++
    }
}

function Read-StrictJsonStringToken {
    param(
        [Parameter(Mandatory)]
        [string]$Json,

        [Parameter(Mandatory)]
        [ref]$Index,

        [Parameter(Mandatory)]
        [string]$SourceName
    )

    if ($Index.Value -ge $Json.Length -or $Json[$Index.Value] -ne [char]34) {
        throw "Expected a JSON string at character $($Index.Value) in $SourceName."
    }

    $builder = New-Object System.Text.StringBuilder
    $position = $Index.Value + 1
    while ($position -lt $Json.Length) {
        $character = $Json[$position]
        if ($character -eq [char]34) {
            $Index.Value = $position + 1
            return $builder.ToString()
        }
        if ([int][char]$character -lt 32) {
            throw "Unescaped control character at character $position in $SourceName."
        }
        if ($character -ne [char]92) {
            [void]$builder.Append($character)
            $position++
            continue
        }

        $position++
        if ($position -ge $Json.Length) {
            throw "JSON string ends after an escape character in $SourceName."
        }

        $escape = $Json[$position]
        switch ($escape) {
            ([char]34) { [void]$builder.Append([char]34); $position++; continue }
            ([char]92) { [void]$builder.Append([char]92); $position++; continue }
            '/' { [void]$builder.Append('/'); $position++; continue }
            'b' { [void]$builder.Append([char]8); $position++; continue }
            'f' { [void]$builder.Append([char]12); $position++; continue }
            'n' { [void]$builder.Append("`n"); $position++; continue }
            'r' { [void]$builder.Append("`r"); $position++; continue }
            't' { [void]$builder.Append("`t"); $position++; continue }
            'u' {
                if ($position + 4 -ge $Json.Length) {
                    throw "Incomplete unicode escape at character $position in $SourceName."
                }
                $hex = $Json.Substring($position + 1, 4)
                if ($hex -notmatch '^[0-9a-fA-F]{4}$') {
                    throw "Invalid unicode escape at character $position in $SourceName."
                }
                [void]$builder.Append([char]([Convert]::ToInt32($hex, 16)))
                $position += 5
                continue
            }
            default { throw "Unknown JSON escape '$escape' at character $position in $SourceName." }
        }
    }

    throw "Unterminated JSON string in $SourceName."
}

function Read-StrictJsonNumberToken {
    param(
        [Parameter(Mandatory)]
        [string]$Json,

        [Parameter(Mandatory)]
        [ref]$Index,

        [Parameter(Mandatory)]
        [string]$SourceName
    )

    $position = $Index.Value
    if ($Json[$position] -eq '-') {
        $position++
        if ($position -ge $Json.Length) {
            throw "Incomplete JSON number at character $($Index.Value) in $SourceName."
        }
    }

    if ($Json[$position] -eq '0') {
        $position++
        if ($position -lt $Json.Length -and $Json[$position] -ge '0' -and $Json[$position] -le '9') {
            throw "JSON number has a leading zero at character $($Index.Value) in $SourceName."
        }
    }
    elseif ($Json[$position] -ge '1' -and $Json[$position] -le '9') {
        do { $position++ } while ($position -lt $Json.Length -and $Json[$position] -ge '0' -and $Json[$position] -le '9')
    }
    else {
        throw "Invalid JSON number at character $($Index.Value) in $SourceName."
    }

    if ($position -lt $Json.Length -and $Json[$position] -eq '.') {
        $position++
        $fractionStart = $position
        while ($position -lt $Json.Length -and $Json[$position] -ge '0' -and $Json[$position] -le '9') { $position++ }
        if ($position -eq $fractionStart) {
            throw "JSON number has no fractional digits at character $($Index.Value) in $SourceName."
        }
    }

    if ($position -lt $Json.Length -and @('e', 'E') -contains [string]$Json[$position]) {
        $position++
        if ($position -lt $Json.Length -and @('+', '-') -contains [string]$Json[$position]) { $position++ }
        $exponentStart = $position
        while ($position -lt $Json.Length -and $Json[$position] -ge '0' -and $Json[$position] -le '9') { $position++ }
        if ($position -eq $exponentStart) {
            throw "JSON number has no exponent digits at character $($Index.Value) in $SourceName."
        }
    }

    $Index.Value = $position
}

function Read-StrictJsonObjectToken {
    param(
        [Parameter(Mandatory)]
        [string]$Json,

        [Parameter(Mandatory)]
        [ref]$Index,

        [Parameter(Mandatory)]
        [string]$SourceName
    )

    $keys = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
    $Index.Value++
    Move-StrictJsonWhitespace -Json $Json -Index $Index
    if ($Index.Value -lt $Json.Length -and $Json[$Index.Value] -eq '}') {
        $Index.Value++
        return
    }

    while ($true) {
        $key = Read-StrictJsonStringToken -Json $Json -Index $Index -SourceName $SourceName
        if (-not $keys.Add($key)) {
            throw "Duplicate JSON object key '$key' in $SourceName."
        }
        Move-StrictJsonWhitespace -Json $Json -Index $Index
        if ($Index.Value -ge $Json.Length -or $Json[$Index.Value] -ne ':') {
            throw "Expected ':' after a JSON object key at character $($Index.Value) in $SourceName."
        }
        $Index.Value++
        Read-StrictJsonValueToken -Json $Json -Index $Index -SourceName $SourceName
        Move-StrictJsonWhitespace -Json $Json -Index $Index
        if ($Index.Value -ge $Json.Length) {
            throw "Unterminated JSON object in $SourceName."
        }
        if ($Json[$Index.Value] -eq '}') {
            $Index.Value++
            return
        }
        if ($Json[$Index.Value] -ne ',') {
            throw "Expected ',' or '}' at character $($Index.Value) in $SourceName."
        }
        $Index.Value++
        Move-StrictJsonWhitespace -Json $Json -Index $Index
    }
}

function Read-StrictJsonArrayToken {
    param(
        [Parameter(Mandatory)]
        [string]$Json,

        [Parameter(Mandatory)]
        [ref]$Index,

        [Parameter(Mandatory)]
        [string]$SourceName
    )

    $Index.Value++
    Move-StrictJsonWhitespace -Json $Json -Index $Index
    if ($Index.Value -lt $Json.Length -and $Json[$Index.Value] -eq ']') {
        $Index.Value++
        return
    }

    while ($true) {
        Read-StrictJsonValueToken -Json $Json -Index $Index -SourceName $SourceName
        Move-StrictJsonWhitespace -Json $Json -Index $Index
        if ($Index.Value -ge $Json.Length) {
            throw "Unterminated JSON array in $SourceName."
        }
        if ($Json[$Index.Value] -eq ']') {
            $Index.Value++
            return
        }
        if ($Json[$Index.Value] -ne ',') {
            throw "Expected ',' or ']' at character $($Index.Value) in $SourceName."
        }
        $Index.Value++
        Move-StrictJsonWhitespace -Json $Json -Index $Index
    }
}

function Read-StrictJsonValueToken {
    param(
        [Parameter(Mandatory)]
        [string]$Json,

        [Parameter(Mandatory)]
        [ref]$Index,

        [Parameter(Mandatory)]
        [string]$SourceName
    )

    Move-StrictJsonWhitespace -Json $Json -Index $Index
    if ($Index.Value -ge $Json.Length) {
        throw "Expected a JSON value at character $($Index.Value) in $SourceName."
    }

    $character = $Json[$Index.Value]
    if ($character -eq '{') {
        Read-StrictJsonObjectToken -Json $Json -Index $Index -SourceName $SourceName
        return
    }
    if ($character -eq '[') {
        Read-StrictJsonArrayToken -Json $Json -Index $Index -SourceName $SourceName
        return
    }
    if ($character -eq [char]34) {
        [void](Read-StrictJsonStringToken -Json $Json -Index $Index -SourceName $SourceName)
        return
    }
    if ($character -eq '-' -or ($character -ge '0' -and $character -le '9')) {
        Read-StrictJsonNumberToken -Json $Json -Index $Index -SourceName $SourceName
        return
    }

    foreach ($literal in @('true', 'false', 'null')) {
        if ($Json.Length - $Index.Value -ge $literal.Length -and
            $Json.Substring($Index.Value, $literal.Length) -ceq $literal) {
            $Index.Value += $literal.Length
            return
        }
    }

    throw "Invalid JSON value at character $($Index.Value) in $SourceName."
}

function Assert-StrictJsonText {
    param(
        [Parameter(Mandatory)]
        [string]$Json,

        [Parameter(Mandatory)]
        [string]$SourceName
    )

    if ([string]::IsNullOrWhiteSpace($Json)) {
        throw "JSON input is empty: $SourceName"
    }

    $index = 0
    Read-StrictJsonValueToken -Json $Json -Index ([ref]$index) -SourceName $SourceName
    Move-StrictJsonWhitespace -Json $Json -Index ([ref]$index)
    if ($index -ne $Json.Length) {
        throw "Unexpected content after the JSON value at character $index in $SourceName."
    }
}
