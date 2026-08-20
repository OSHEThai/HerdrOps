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
            if ($character -eq '"') {
                [void]$builder.Append($character)
                $index++
                $state = 'DoubleString'
                continue
            }

            if ($character -eq "'") {
                [void]$builder.Append($character)
                $index++
                $state = 'CharLiteral'
                continue
            }

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

        if ($state -eq 'DoubleString' -or $state -eq 'CharLiteral') {
            [void]$builder.Append($character)
            if ($character -eq [char]92 -and $index + 1 -lt $Text.Length) {
                $index++
                [void]$builder.Append($Text[$index])
            } elseif (($state -eq 'DoubleString' -and $character -eq '"') -or
                ($state -eq 'CharLiteral' -and $character -eq "'")) {
                $state = 'Code'
            }
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

        if ($character -eq [char]92) {
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
        if ($character -eq [char]92 -and $cursor + 1 -lt $Index) {
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
        [string]$RawPattern,

        [switch]$TreatQuotedTextAsCode
    )

    $codeOnly = ConvertTo-Issue43CodeOnlyText -Text $Text
    $commentFree = ConvertTo-Issue43CommentFreeText -Text $Text
    $codeMatch = [regex]::Match($codeOnly, $CodePattern, [Text.RegularExpressions.RegexOptions]::IgnoreCase)
    $rawMatch = $null
    foreach ($candidate in [regex]::Matches($commentFree, $RawPattern, [Text.RegularExpressions.RegexOptions]::IgnoreCase)) {
        if ($TreatQuotedTextAsCode -or
            (Test-Issue43MatchOutsideQuotedText -Text $commentFree -Index $candidate.Index)) {
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
    $jsonEndpoint = '{"urls":"http://localhost:5000"}'
    $escapedCSharpJson = 'var configuration = "{\"urls\":\"http://localhost:5000\"}";'

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

    $jsonEndpointResult = Test-Issue43ForbiddenDeclaration -Text $jsonEndpoint -CodePattern '(?i)\b(?:https?|wss?)\s*:\s*//\s*(?:localhost|127\.0\.0\.1|\[?::1\]?)(?::\d+)?' -RawPattern '(?i)(?:https?|wss?)\s*:\s*//\s*(?:localhost|127\.0\.0\.1|\[?::1\]?)(?::\d+)?' -TreatQuotedTextAsCode
    $escapedCSharpJsonResult = Test-Issue43ForbiddenDeclaration -Text $escapedCSharpJson -CodePattern '(?i)\b(?:https?|wss?)\s*:\s*//\s*(?:localhost|127\.0\.0\.1|\[?::1\]?)(?::\d+)?' -RawPattern '(?i)(?:https?|wss?)\s*:\s*//\s*(?:localhost|127\.0\.0\.1|\[?::1\]?)(?::\d+)?'

    if ($commentResult.IsMatch -or -not $listenerResult.IsMatch -or -not $dynamicResult.IsMatch -or
        -not $adminResult.IsMatch -or -not $adminDynamicResult.IsMatch -or
        -not $jsonEndpointResult.IsMatch -or $escapedCSharpJsonResult.IsMatch) {
        throw 'Issue #43 scanner fixtures did not preserve comment/string exclusions, JSON endpoint detection, and dynamic declaration detection.'
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
        'CandidateHeadMatch',
        'DirectParentMatch',
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

function Get-Issue43SchemaReportContractLines {
    return @(
        'SchemaVersion: v4',
        'MigrationGraph: v1 initial-state-store -> v2 assignment-lifecycle-provenance -> v3 evidence-metadata-review-retention-audit -> v4 role-distinct-compliance-review-workflow'
    )
}

function Test-Issue43ReportWriterFixtures {
    $separatorLines = @(ConvertTo-Issue43ReportLines -Lines @('header', @('', 'body'), 'footer'))
    if ($separatorLines.Count -ne 4 -or $separatorLines[1] -ne '') {
        throw 'Issue #43 report writer fixture did not preserve the empty separator line.'
    }

    $schemaContractLines = @(Get-Issue43SchemaReportContractLines)
    if ($schemaContractLines.Count -ne 2 -or
        $schemaContractLines[0] -ne 'SchemaVersion: v4' -or
        $schemaContractLines[1] -ne 'MigrationGraph: v1 initial-state-store -> v2 assignment-lifecycle-provenance -> v3 evidence-metadata-review-retention-audit -> v4 role-distinct-compliance-review-workflow') {
        throw 'Issue #43 schema report contract fixture is not synchronized with the current four-migration graph.'
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
        CandidateHeadMatch = 'PASS'
        DirectParentMatch = 'PASS'
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

function ConvertTo-Issue43NativeArgumentString {
    param(
        [string[]]$Arguments
    )

    if ($null -eq $Arguments) {
        throw 'Issue #43 native argument list cannot be null.'
    }

    $commandLine = ''
    foreach ($argument in $Arguments) {
        if ($commandLine.Length -gt 0) {
            $commandLine += ' '
        }

        $value = if ($null -eq $argument) { '' } else { [string]$argument }
        if ($value.Length -eq 0) {
            $commandLine += '""'
            continue
        }

        if ($value -notmatch '[ \t"]') {
            $commandLine += $value
            continue
        }

        # Windows CommandLineToArgvW-compatible quoting: backslashes before a
        # quote are doubled, an embedded quote is escaped as backslash-quote,
        # and trailing backslashes before the closing quote are doubled.
        $quoted = '"'
        $backslashes = 0
        foreach ($character in $value.ToCharArray()) {
            if ($character -eq [char]92) {
                $backslashes++
                continue
            }
            if ($character -eq '"') {
                $quoted += ('\' * ($backslashes * 2 + 1)) + '"'
                $backslashes = 0
                continue
            }
            $quoted += ('\' * $backslashes) + $character
            $backslashes = 0
        }
        $quoted += ('\' * ($backslashes * 2)) + '"'
        $commandLine += $quoted
    }

    return $commandLine
}

function Stop-Issue43ProcessTree {
    param(
        [Parameter(Mandatory)]
        [System.Diagnostics.Process]$Process
    )

    if ($Process.HasExited) {
        return $true
    }

    # Process.Kill(bool) is not available on Windows PowerShell 5.1
    # (.NET Framework), so a cross-shell tree kill uses taskkill /T.
    $null = & taskkill.exe /PID $Process.Id /T /F 2>$null
    $deadline = [DateTime]::UtcNow.AddSeconds(15)
    while (-not $Process.HasExited -and [DateTime]::UtcNow -lt $deadline) {
        Start-Sleep -Milliseconds 100
    }
    if (-not $Process.HasExited) {
        $null = & taskkill.exe /PID $Process.Id /T /F 2>$null
        $null = $Process.WaitForExit(15000)
    }

    return $Process.HasExited
}

function Start-Issue43OwnedProcess {
    param(
        [Parameter(Mandatory)]
        [string]$FilePath,

        [string[]]$ArgumentList,

        [int]$TimeoutMilliseconds = 300000,

        [string]$RedirectStandardOutput,

        [string]$RedirectStandardError
    )

    if ($null -eq $ArgumentList) {
        throw 'Issue #43 owned process argument list cannot be null.'
    }

    # Start-Process on Windows PowerShell 5.1 does not populate ExitCode when
    # output is redirected and its ArgumentList never quotes spaced arguments,
    # so the owned process is launched through System.Diagnostics.Process with
    # an explicitly escaped command line and background pipe draining.
    $commandLine = ConvertTo-Issue43NativeArgumentString -Arguments $ArgumentList
    $startInfo = New-Object System.Diagnostics.ProcessStartInfo
    $startInfo.FileName = $FilePath
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.Arguments = $commandLine
    $captureStdout = -not [string]::IsNullOrWhiteSpace($RedirectStandardOutput)
    $captureStderr = -not [string]::IsNullOrWhiteSpace($RedirectStandardError)
    $startInfo.RedirectStandardOutput = $captureStdout
    $startInfo.RedirectStandardError = $captureStderr

    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $startInfo

    try {
        if (-not $process.Start()) {
            throw 'the process could not be started'
        }
    } catch {
        return [pscustomobject]@{
            Started = $false
            Process = $null
            TimedOut = $false
            ExitCode = $null
            Killed = $false
            ErrorMessage = $_.Exception.Message
            CommandLine = $commandLine
        }
    }

    # Background pipe draining avoids pipe-buffer deadlock without PowerShell
    # scriptblocks on .NET reader threads (which fail without a runspace).
    $stdoutTask = $null
    $stderrTask = $null
    if ($captureStdout) {
        $stdoutTask = $process.StandardOutput.ReadToEndAsync()
    }
    if ($captureStderr) {
        $stderrTask = $process.StandardError.ReadToEndAsync()
    }

    $timedOut = -not $process.WaitForExit($TimeoutMilliseconds)
    $killed = $false
    if ($timedOut) {
        $killed = Stop-Issue43ProcessTree -Process $process
    }
    if (-not $process.HasExited) {
        $null = $process.WaitForExit(15000)
    }
    if ($process.HasExited) {
        # Drain remaining pipe content before reading the exit code.
        $null = $process.WaitForExit()
    }

    if ($captureStdout) {
        $stdoutText = ''
        try { $stdoutText = [string]$stdoutTask.Result } catch { }
        [IO.File]::WriteAllText($RedirectStandardOutput, $stdoutText, (New-Object System.Text.UTF8Encoding($false)))
    }
    if ($captureStderr) {
        $stderrText = ''
        try { $stderrText = [string]$stderrTask.Result } catch { }
        [IO.File]::WriteAllText($RedirectStandardError, $stderrText, (New-Object System.Text.UTF8Encoding($false)))
    }

    return [pscustomobject]@{
        Started = $true
        Process = $process
        TimedOut = $timedOut
        ExitCode = if ($process.HasExited) { $process.ExitCode } else { $null }
        Killed = $killed
        ErrorMessage = $null
        CommandLine = $commandLine
    }
}

function Get-Issue43ExactlyOneTrxFile {
    param(
        [Parameter(Mandatory)]
        [string]$Directory,

        [Parameter(Mandatory)]
        [string]$FileName
    )

    $full = [IO.Path]::GetFullPath($Directory)
    $prefix = $full.TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
    $candidates = @()
    $enumerationFailed = $false
    try {
        # An incomplete traversal must not be treated as an empty or unique
        # result: access/enumeration errors invalidate exactly-one evidence.
        $candidates = @(
            Get-ChildItem -LiteralPath $full -Recurse -File -ErrorAction Stop |
                Where-Object {
                    $_.FullName.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase) -and
                        [string]::Equals($_.Name, $FileName, [StringComparison]::OrdinalIgnoreCase)
                }
        )
    } catch {
        $enumerationFailed = $true
    }

    return [pscustomobject]@{
        Count = if ($enumerationFailed) { 0 } else { $candidates.Count }
        Path = if (-not $enumerationFailed -and $candidates.Count -eq 1) { $candidates[0].FullName } else { $null }
        Found = -not $enumerationFailed -and $candidates.Count -eq 1
        EnumerationFailed = $enumerationFailed
    }
}

function Test-Issue43ProcessFixtures {
    $fixtureRoot = Join-Path ([IO.Path]::GetTempPath()) "HerdrOps Issue43 Process Fixture $([Guid]::NewGuid().ToString('N'))"
    if ($fixtureRoot -notmatch ' ') {
        throw 'Issue #43 process fixture directory must contain a space to exercise spaced-path binding.'
    }

    try {
        New-Item -ItemType Directory -Path $fixtureRoot -Force | Out-Null
        $utf8NoBom = New-Object -TypeName System.Text.UTF8Encoding -ArgumentList @($false)

        $argumentCases = @(
            @{ Arguments = @('simple'); Expected = 'simple' },
            @{ Arguments = @('arg with space'); Expected = '"arg with space"' },
            @{ Arguments = @('C:\path with spaces\proj.csproj'); Expected = '"C:\path with spaces\proj.csproj"' },
            @{ Arguments = @('', 'x'); Expected = '"" x' },
            @{ Arguments = @('a"b'); Expected = '"a\"b"' },
            @{ Arguments = @('C:\path with spaces\'); Expected = '"C:\path with spaces\\"' },
            @{ Arguments = @('C:\path with "embedded"\'); Expected = '"C:\path with \"embedded\"\\"' },
            @{ Arguments = @('a', 'b'); Expected = 'a b' },
            @{ Arguments = @("tab`tinside"); Expected = "`"tab`tinside`"" }
        )
        foreach ($argumentCase in $argumentCases) {
            $actual = ConvertTo-Issue43NativeArgumentString -Arguments $argumentCase.Arguments
            if ($actual -cne $argumentCase.Expected) {
                throw "Issue #43 native argument quoting produced '$actual'; expected '$($argumentCase.Expected)'."
            }
        }

        $hostExecutable = (Get-Process -Id $PID).Path
        $echoScript = Join-Path $fixtureRoot 'echo-arguments.ps1'
        $echoScriptBody = @'
param()
$outputPath = $args[0]
$values = @()
if ($args.Count -gt 1) {
    $values = @($args[1..($args.Count - 1)])
}
$lines = New-Object 'System.Collections.Generic.List[string]'
foreach ($value in $values) {
    [void]$lines.Add(('[{0}]' -f $value))
}
[IO.File]::WriteAllLines($outputPath, [string[]]$lines, (New-Object System.Text.UTF8Encoding($false)))
'@
        [IO.File]::WriteAllText($echoScript, $echoScriptBody, $utf8NoBom)

        $roundTripOutput = Join-Path $fixtureRoot 'roundtrip-output.txt'
        $trickyArguments = @(
            '-NoProfile',
            '-ExecutionPolicy', 'Bypass',
            '-File', $echoScript,
            $roundTripOutput,
            'arg with space',
            'C:\path with spaces\proj.csproj',
            '--filter',
            'FullyQualifiedName~StateIpcContractTests|FullyQualifiedName~SelfReportContractTests',
            'quote"inside',
            'trailing\',
            'C:\path with "embedded"\',
            '',
            "tab`tinside"
        )
        $roundTrip = Start-Issue43OwnedProcess -FilePath $hostExecutable -ArgumentList $trickyArguments -TimeoutMilliseconds 30000
        if (-not $roundTrip.Started) {
            throw "Issue #43 argv round-trip could not start: $($roundTrip.ErrorMessage)"
        }
        if ($roundTrip.TimedOut) {
            throw 'Issue #43 argv round-trip timed out.'
        }
        if ($roundTrip.ExitCode -ne 0) {
            throw "Issue #43 argv round-trip exited $($roundTrip.ExitCode)."
        }

        $expectedRoundTripLines = @(
            '[arg with space]',
            '[C:\path with spaces\proj.csproj]',
            '[--filter]',
            '[FullyQualifiedName~StateIpcContractTests|FullyQualifiedName~SelfReportContractTests]',
            '[quote"inside]',
            '[trailing\]',
            '[C:\path with "embedded"\]',
            '[]',
            "[tab`tinside]"
        )
        $actualRoundTripLines = @(Get-Content -LiteralPath $roundTripOutput)
        if ($actualRoundTripLines.Count -ne $expectedRoundTripLines.Count) {
            throw "Issue #43 argv round-trip produced $($actualRoundTripLines.Count) lines; expected $($expectedRoundTripLines.Count)."
        }
        for ($index = 0; $index -lt $expectedRoundTripLines.Count; $index++) {
            if ($actualRoundTripLines[$index] -cne $expectedRoundTripLines[$index]) {
                throw "Issue #43 argv round-trip line $index was '$($actualRoundTripLines[$index])'; expected '$($expectedRoundTripLines[$index])'."
            }
        }

        $sleepScript = Join-Path $fixtureRoot 'sleep-with-child.ps1'
        $sleepScriptBody = @'
param()
$childPidPath = $args[0]
$hostExecutable = (Get-Process -Id $PID).Path
$child = Start-Process -FilePath $hostExecutable -ArgumentList @('-NoProfile', '-Command', 'Start-Sleep -Seconds 60') -PassThru -WindowStyle Hidden
[IO.File]::WriteAllText($childPidPath, $child.Id.ToString(), (New-Object System.Text.UTF8Encoding($false)))
Start-Sleep -Seconds 60
'@
        [IO.File]::WriteAllText($sleepScript, $sleepScriptBody, $utf8NoBom)

        $childPidPath = Join-Path $fixtureRoot 'child.pid'
        $sleepRun = Start-Issue43OwnedProcess `
            -FilePath $hostExecutable `
            -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $sleepScript, $childPidPath) `
            -TimeoutMilliseconds 8000
        if (-not $sleepRun.Started) {
            throw "Issue #43 owned timeout fixture could not start: $($sleepRun.ErrorMessage)"
        }
        if (-not $sleepRun.TimedOut) {
            throw 'Issue #43 owned process did not enforce its bounded timeout.'
        }
        if (-not $sleepRun.Killed) {
            throw 'Issue #43 owned process tree was not killed after timeout.'
        }
        if (-not $sleepRun.Process.HasExited) {
            throw 'Issue #43 owned process was not reaped after tree kill.'
        }
        if (-not (Test-Path -LiteralPath $childPidPath)) {
            throw 'Issue #43 owned timeout fixture did not record its grandchild PID.'
        }
        $grandchildPid = [int](Get-Content -LiteralPath $childPidPath -Raw).Trim()
        $grandchildDeadline = [DateTime]::UtcNow.AddSeconds(5)
        $grandchildAlive = $true
        while ([DateTime]::UtcNow -lt $grandchildDeadline -and $grandchildAlive) {
            if ($null -eq (Get-Process -Id $grandchildPid -ErrorAction SilentlyContinue)) {
                $grandchildAlive = $false
            } else {
                Start-Sleep -Milliseconds 200
            }
        }
        if ($grandchildAlive) {
            throw "Issue #43 tree kill left grandchild process $grandchildPid alive."
        }

        $exitScript = Join-Path $fixtureRoot 'exit-42.ps1'
        [IO.File]::WriteAllText($exitScript, 'exit 42', $utf8NoBom)
        $exitRun = Start-Issue43OwnedProcess `
            -FilePath $hostExecutable `
            -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $exitScript) `
            -TimeoutMilliseconds 30000
        if (-not $exitRun.Started -or $exitRun.TimedOut -or $exitRun.ExitCode -ne 42) {
            throw "Issue #43 owned process did not return the exact positive exit code (started=$($exitRun.Started) timedOut=$($exitRun.TimedOut) exit=$($exitRun.ExitCode))."
        }

        $trxDirectory = Join-Path $fixtureRoot 'trx-results'
        New-Item -ItemType Directory -Path $trxDirectory -Force | Out-Null
        $emptyTrx = Get-Issue43ExactlyOneTrxFile -Directory $trxDirectory -FileName 'C-01-ipc.trx'
        if ($emptyTrx.Found -or $emptyTrx.Count -ne 0) {
            throw "Issue #43 exactly-one TRX helper found $($emptyTrx.Count) files in an empty directory."
        }
        [IO.File]::WriteAllText((Join-Path $trxDirectory 'C-01-ipc.trx'), '<dummy/>', $utf8NoBom)
        $singleTrx = Get-Issue43ExactlyOneTrxFile -Directory $trxDirectory -FileName 'C-01-ipc.trx'
        if (-not $singleTrx.Found -or $singleTrx.Count -ne 1) {
            throw 'Issue #43 exactly-one TRX helper did not find the single TRX file.'
        }
        New-Item -ItemType Directory -Path (Join-Path $trxDirectory 'nested') -Force | Out-Null
        [IO.File]::WriteAllText((Join-Path $trxDirectory 'nested\C-01-ipc.trx'), '<dummy/>', $utf8NoBom)
        $duplicateTrx = Get-Issue43ExactlyOneTrxFile -Directory $trxDirectory -FileName 'C-01-ipc.trx'
        if ($duplicateTrx.Found -or $duplicateTrx.Count -ne 2) {
            throw "Issue #43 exactly-one TRX helper did not fail closed on duplicate names (found $($duplicateTrx.Count))."
        }
        $missingTrxDirectory = Join-Path $fixtureRoot 'missing-trx-results'
        $enumerationFailure = Get-Issue43ExactlyOneTrxFile -Directory $missingTrxDirectory -FileName 'C-01-ipc.trx'
        if (-not $enumerationFailure.EnumerationFailed -or $enumerationFailure.Found) {
            throw 'Issue #43 exactly-one TRX helper did not fail closed on an enumeration error.'
        }

        return $true
    } finally {
        Remove-Item -LiteralPath $fixtureRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}
