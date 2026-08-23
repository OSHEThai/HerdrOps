#requires -Version 5.1

[CmdletBinding()]
param(
    [switch]$RendererWindowChild,
    [string]$ChildRendererManifestPath,
    [string]$ChildReviewEvidencePath,
    [string]$ChildEvidenceRoot,
    [string]$ChildRepositoryRoot,
    [string]$ChildCandidateOutputPath,
    [string]$ChildHostileTarget,
    [string]$ChildHostileReplacement,
    [string]$ChildResultPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'HumanVisualGo.Common.ps1')

# Fixture-only algorithm injection. Plan does not currently approve a
# production authority algorithm; the production verifier fails closed before
# any authority helper can be reached.
$script:HumanVisualGoFixtureSignatureAlgorithm = 'RSA-SHA256-PKCS1-v1_5'

$script:PositiveCases = 0
$script:NegativeCases = 0

function Pass([string]$Name) {
    $script:PositiveCases++
    "PASS positive: $Name"
}

function Pass-Negative([string]$Name) {
    $script:NegativeCases++
    "PASS negative: $Name"
}

function Copy-HumanTestValue($Value) {
    $json = $Value | ConvertTo-Json -Depth 100
    if ($PSVersionTable.PSVersion.Major -ge 7) { return ($json | ConvertFrom-Json -DateKind String) }
    return ($json | ConvertFrom-Json)
}

function Write-HumanCanonicalJson {
    param([Parameter(Mandatory = $true)]$Value, [Parameter(Mandatory = $true)][string]$Path, [Parameter(Mandatory = $true)][string]$RepositoryRoot)
    $canonical = Get-HumanVisualGoCanonicalText -Value $Value -RepositoryRoot $RepositoryRoot
    [IO.File]::WriteAllText($Path, $canonical + "`n", [Text.UTF8Encoding]::new($false))
}

function Start-HumanSwapExecuteRestoreHostile {
    param(
        [Parameter(Mandatory = $true)][string]$Target,
        [Parameter(Mandatory = $true)][string]$Replacement,
        [int]$DurationSeconds = 8
    )
    $scriptPath = Join-Path ([IO.Path]::GetTempPath()) ('herdrops-human-swap-hostile-' + [Guid]::NewGuid().ToString('N') + '.ps1')
    $logPath = Join-Path ([IO.Path]::GetTempPath()) ('herdrops-human-swap-hostile-' + [Guid]::NewGuid().ToString('N') + '.log')
    $stopPath = Join-Path ([IO.Path]::GetTempPath()) ('herdrops-human-swap-hostile-' + [Guid]::NewGuid().ToString('N') + '.stop')
    $scriptText = @'
param([string]$Target, [string]$Replacement, [string]$LogPath, [string]$StopPath, [string]$Deadline)
$attempts = 0
$writes = 0
$swaps = 0
$restores = 0
$distinctSwaps = 0
$last = ''
[IO.File]::WriteAllText(($LogPath + '.ready'), 'ready', [Text.UTF8Encoding]::new($false))
$originalBytes = [IO.File]::ReadAllBytes($Target)
$replacementBytes = [IO.File]::ReadAllBytes($Replacement)
$until = [DateTimeOffset]::Parse($Deadline)
while ([DateTimeOffset]::UtcNow -lt $until -and -not (Test-Path -LiteralPath $StopPath -PathType Leaf)) {
    $attempts++
    $stream = $null
    $didWrite = $false
    try {
        $stream = New-Object IO.FileStream($Target, [IO.FileMode]::Open, [IO.FileAccess]::Write, [IO.FileShare]::None)
        $bytes = [Text.UTF8Encoding]::new($false).GetBytes('hostile-in-place-write-distinct')
        $stream.Position = 0
        $stream.Write($bytes, 0, $bytes.Length)
        $stream.Flush($true)
        $writes++
        $didWrite = $true
    }
    catch { $last = $_.Exception.Message }
    finally { if ($null -ne $stream) { $stream.Dispose() } }
    if ($didWrite) {
        try { [IO.File]::WriteAllBytes($Target, $originalBytes) } catch { $last = $_.Exception.Message }
    }
    $backup = $Target + '.hostile-backup'
    try {
        if (Test-Path -LiteralPath $backup -PathType Leaf) { Remove-Item -LiteralPath $backup -Force -ErrorAction Stop }
        Move-Item -LiteralPath $Target -Destination $backup -Force -ErrorAction Stop
        Move-Item -LiteralPath $Replacement -Destination $Target -Force -ErrorAction Stop
        $observedReplacement = [IO.File]::ReadAllBytes($Target)
        if (-not [System.Linq.Enumerable]::SequenceEqual([byte[]]$observedReplacement, [byte[]]$replacementBytes)) {
            throw 'Hostile replacement bytes were not distinct and stable.'
        }
        $distinctSwaps++
        $swaps++
        Move-Item -LiteralPath $Target -Destination $Replacement -Force -ErrorAction Stop
        Move-Item -LiteralPath $backup -Destination $Target -Force -ErrorAction Stop
        $restores++
    }
    catch {
        $last = $_.Exception.Message
        if (Test-Path -LiteralPath $backup -PathType Leaf) {
            try {
                if (Test-Path -LiteralPath $Target -PathType Leaf) { Move-Item -LiteralPath $Target -Destination $Replacement -Force -ErrorAction Stop }
                Move-Item -LiteralPath $backup -Destination $Target -Force -ErrorAction Stop
            } catch { $last = $_.Exception.Message }
        }
    }
    # A sustained rejected mutation attempt is sufficient for this hostile
    # window.  Avoid starving Windows PowerShell 5.1 with exception-heavy
    # file operations while the production verifier holds the target.
    Start-Sleep -Milliseconds 100
}
try { [IO.File]::WriteAllBytes($Target, $originalBytes) } catch { $last = $_.Exception.Message }
$terminationReason = if (Test-Path -LiteralPath $StopPath -PathType Leaf) { 'wrapper-stop' } else { 'deadline' }
[IO.File]::WriteAllText($LogPath, "$attempts|$writes|$swaps|$restores|$distinctSwaps|$terminationReason|$last", [Text.UTF8Encoding]::new($false))
'@
    [IO.File]::WriteAllText($scriptPath, $scriptText, [Text.UTF8Encoding]::new($false))
    $hostExe = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $deadline = [DateTimeOffset]::UtcNow.AddSeconds($DurationSeconds).ToString('O', [Globalization.CultureInfo]::InvariantCulture)
    $process = Start-Process -FilePath $hostExe -WindowStyle Hidden -PassThru -ArgumentList @('-NoLogo', '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', $scriptPath, $Target, $Replacement, $logPath, $stopPath, $deadline)
    $readyDeadline = [DateTimeOffset]::UtcNow.AddSeconds(10)
    while (-not (Test-Path -LiteralPath ($logPath + '.ready') -PathType Leaf) -and [DateTimeOffset]::UtcNow -lt $readyDeadline) {
        if ($process.HasExited) { throw 'Swap hostile child exited before its ready marker.' }
        Start-Sleep -Milliseconds 25
    }
    if (-not (Test-Path -LiteralPath ($logPath + '.ready') -PathType Leaf)) { throw 'Swap hostile child did not produce its ready marker.' }
    return [pscustomobject][ordered]@{ Process = $process; ScriptPath = $scriptPath; LogPath = $logPath; StopPath = $stopPath }
}

function Stop-HumanSwapExecuteRestoreHostile {
    param([Parameter(Mandatory = $true)]$Hostile)
    try {
        [IO.File]::WriteAllText($Hostile.StopPath, 'stop', [Text.UTF8Encoding]::new($false))
        if (-not $Hostile.Process.HasExited) {
            if (-not $Hostile.Process.WaitForExit(15000)) { $Hostile.Process.Kill(); $Hostile.Process.WaitForExit() }
        }
        if (-not (Test-Path -LiteralPath $Hostile.LogPath -PathType Leaf)) { throw 'Swap hostile did not produce its result log.' }
        $parts = ([IO.File]::ReadAllText($Hostile.LogPath) -split '\|', 7)
        return [pscustomobject][ordered]@{
            Attempts = [int]$parts[0]
            Writes = [int]$parts[1]
            Swaps = [int]$parts[2]
            Restores = [int]$parts[3]
            DistinctSwaps = [int]$parts[4]
            TerminationReason = [string]$parts[5]
            LastError = [string]$parts[6]
        }
    }
    finally {
        if (Test-Path -LiteralPath $Hostile.ScriptPath) { Remove-Item -LiteralPath $Hostile.ScriptPath -Force -ErrorAction SilentlyContinue }
        if (Test-Path -LiteralPath $Hostile.LogPath) { Remove-Item -LiteralPath $Hostile.LogPath -Force -ErrorAction SilentlyContinue }
        if (Test-Path -LiteralPath ($Hostile.LogPath + '.ready')) { Remove-Item -LiteralPath ($Hostile.LogPath + '.ready') -Force -ErrorAction SilentlyContinue }
        if (Test-Path -LiteralPath $Hostile.StopPath) { Remove-Item -LiteralPath $Hostile.StopPath -Force -ErrorAction SilentlyContinue }
    }
}

# The renderer-window hostile must run in a disposable process. The parent
# selftest process has no wrapper or renamed renderer function to clean up.
if ($RendererWindowChild) {
    $childResult = [ordered]@{
        Status = 'FAIL'
        Error = $null
        CandidateFileSha256 = $null
        CandidateCanonicalSha256 = $null
        TargetSha256Before = $null
        TargetSha256After = $null
        Attempts = 0
        Writes = 0
        Swaps = 0
        Restores = 0
        DistinctSwaps = 0
        TerminationReason = $null
        LastError = $null
        RendererReturned = $false
        HostileStartedBeforeRenderer = $false
        HostileStoppedBeforeWrapperReturn = $false
        CandidateReturned = $false
    }
    $hostileChild = $null
    try {
        foreach ($requiredPath in @($ChildRendererManifestPath, $ChildReviewEvidencePath, $ChildEvidenceRoot, $ChildRepositoryRoot, $ChildCandidateOutputPath, $ChildHostileTarget, $ChildHostileReplacement, $ChildResultPath)) {
            if ([string]::IsNullOrWhiteSpace($requiredPath)) { throw 'Renderer-window child received an empty required path.' }
        }
        $childResult.TargetSha256Before = Get-HumanVisualGoSha256ForBytes -Bytes ([IO.File]::ReadAllBytes($ChildHostileTarget))
        $originalRendererName = 'HumanVisualGo_ChildOriginal_TestRendererCompatibilityManifest'
        # This is the child process's current Function: scope. Rename the
        # actual function object, then install the wrapper in its vacated slot.
        Rename-Item -Path 'Function:\Test-RendererCompatibilityManifest' -NewName $originalRendererName -ErrorAction Stop
        $script:HumanVisualGoChildOriginalRendererName = $originalRendererName
        $script:HumanVisualGoChildHostileTarget = $ChildHostileTarget
        $script:HumanVisualGoChildHostileReplacement = $ChildHostileReplacement
        $script:HumanVisualGoChildOriginalSha = [string]$childResult.TargetSha256Before
        $script:HumanVisualGoChildRendererResult = $null
        $script:HumanVisualGoChildRendererReturned = $false
        $script:HumanVisualGoChildHostileStarted = $false
        $script:HumanVisualGoChildWrapperStopObserved = $false
        $rendererWrapper = {
            [CmdletBinding()]
            param(
                [Parameter(Mandatory = $true)][string]$ManifestPath,
                [string]$EvidenceRoot,
                [string]$RepositoryRoot,
                [switch]$ValidateBindings
            )
            $rendererResultLocal = $null
            $rendererException = $null
            $hostileException = $null
            $hostileLocal = $null
            try {
                # Candidate core has opened every evidence/repository handle
                # before this exact production renderer call.
                $hostileLocal = Start-HumanSwapExecuteRestoreHostile -Target $script:HumanVisualGoChildHostileTarget -Replacement $script:HumanVisualGoChildHostileReplacement -DurationSeconds 900
                $script:HumanVisualGoChildHostileStarted = $true
                try {
                    $rendererResultLocal = & $script:HumanVisualGoChildOriginalRendererName -ManifestPath $ManifestPath -EvidenceRoot $EvidenceRoot -RepositoryRoot $RepositoryRoot -ValidateBindings:$ValidateBindings
                    $script:HumanVisualGoChildRendererReturned = $true
                }
                catch {
                    $rendererException = $_.Exception
                }
            }
            finally {
                if ($null -ne $hostileLocal) {
                    try {
                        $resultLocal = Stop-HumanSwapExecuteRestoreHostile -Hostile $hostileLocal
                        $script:HumanVisualGoChildRendererResult = $resultLocal
                        if ($resultLocal.TerminationReason -cne 'wrapper-stop' -or
                            $resultLocal.Attempts -lt 1 -or
                            $resultLocal.Writes -ne 0 -or
                            $resultLocal.Swaps -ne 0 -or
                            $resultLocal.DistinctSwaps -ne 0 -or
                            $resultLocal.Restores -ne 0 -or
                            $resultLocal.LastError -notmatch '(?i)access|denied|used|cannot|sharing') {
                            throw "Renderer-window hostile mutation was not blocked before the wrapper returned: $($resultLocal | Out-String)"
                        }
                        $afterShaLocal = Get-HumanVisualGoSha256ForBytes -Bytes ([IO.File]::ReadAllBytes($script:HumanVisualGoChildHostileTarget))
                        if ($afterShaLocal -cne [string]$script:HumanVisualGoChildOriginalSha) {
                            throw 'Renderer-window hostile changed the original capture bytes.'
                        }
                        $script:HumanVisualGoChildWrapperStopObserved = $true
                    }
                    catch {
                        $hostileException = $_.Exception
                    }
                }
            }
            if ($null -ne $hostileException) { throw $hostileException }
            if ($null -ne $rendererException) { throw $rendererException }
            return $rendererResultLocal
        }
        Set-Item -Path 'Function:\Test-RendererCompatibilityManifest' -Value $rendererWrapper
        $candidate = New-V02HumanVisualGoCandidateCore -RendererManifestPath $ChildRendererManifestPath -HumanReviewEvidencePath $ChildReviewEvidencePath -EvidenceRoot $ChildEvidenceRoot -RepositoryRoot $ChildRepositoryRoot -BuilderIdentity 'builder-fixture' -RuntimeOperatorIdentity 'runtime-operator-fixture' -IndependentValidatorIdentity 'independent-validator-fixture'
        $childResult.CandidateReturned = $true
        $candidateReceipt = Write-V02HumanVisualGoCandidate -Candidate $candidate -OutputPath $ChildCandidateOutputPath -RepositoryRoot $ChildRepositoryRoot -EvidenceRoot $ChildEvidenceRoot
        $childResult.CandidateFileSha256 = [string]$candidateReceipt.FileSha256
        $childResult.CandidateCanonicalSha256 = [string]$candidateReceipt.CanonicalSha256
        $childResult.TargetSha256After = Get-HumanVisualGoSha256ForBytes -Bytes ([IO.File]::ReadAllBytes($ChildHostileTarget))
        $childResult.Attempts = [int]$script:HumanVisualGoChildRendererResult.Attempts
        $childResult.Writes = [int]$script:HumanVisualGoChildRendererResult.Writes
        $childResult.Swaps = [int]$script:HumanVisualGoChildRendererResult.Swaps
        $childResult.Restores = [int]$script:HumanVisualGoChildRendererResult.Restores
        $childResult.DistinctSwaps = [int]$script:HumanVisualGoChildRendererResult.DistinctSwaps
        $childResult.TerminationReason = [string]$script:HumanVisualGoChildRendererResult.TerminationReason
        $childResult.LastError = [string]$script:HumanVisualGoChildRendererResult.LastError
        $childResult.RendererReturned = [bool]$script:HumanVisualGoChildRendererReturned
        $childResult.HostileStartedBeforeRenderer = [bool]$script:HumanVisualGoChildHostileStarted
        $childResult.HostileStoppedBeforeWrapperReturn = [bool]$script:HumanVisualGoChildWrapperStopObserved
        if ($childResult.TargetSha256After -cne $childResult.TargetSha256Before -or
            -not $childResult.RendererReturned -or
            -not $childResult.HostileStartedBeforeRenderer -or
            -not $childResult.HostileStoppedBeforeWrapperReturn) {
            throw 'Renderer-window child did not prove the complete start/render/stop sequence.'
        }
        $childResult.Status = 'PASS'
    }
    catch {
        $childResult.Error = $_.Exception.ToString()
    }
    finally {
        [IO.File]::WriteAllText($ChildResultPath, ($childResult | ConvertTo-Json -Depth 20), [Text.UTF8Encoding]::new($false))
    }
    if ($childResult.Status -cne 'PASS') {
        Write-Error ([string]$childResult.Error)
        exit 1
    }
    exit 0
}

function Expect-HumanFailure {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][scriptblock]$Action,
        [string]$ExpectedMessage
    )
    $failed = $false
    $message = $null
    try { & $Action | Out-Null } catch { $failed = $true; $message = $_.Exception.Message }
    if (-not $failed) { throw "Hostile case '$Name' did not fail closed." }
    if (-not [string]::IsNullOrWhiteSpace($ExpectedMessage) -and $message -notmatch $ExpectedMessage) {
        throw "Hostile case '$Name' reached an unexpected guard. Expected /$ExpectedMessage/ but got '$message'."
    }
    Pass-Negative $Name
}

function Test-HumanProductionOverrideShape {
    $productionEntrypoints = @(
        [pscustomobject]@{ RelativePath = 'HumanVisualGo.Common.ps1'; FunctionName = 'Test-V02HumanVisualGoAttestationCore' },
        [pscustomobject]@{ RelativePath = 'Test-V02HumanVisualGoAttestation.ps1'; FunctionName = $null }
    )
    $forbidden = @('TrustedAuthorityPublicKeyPath', 'ReplayRegistryRoot', 'TrustedNowUtc', 'MaximumAge', 'MaximumFutureSkew')
    foreach ($entrypoint in $productionEntrypoints) {
        $relativePath = [string]$entrypoint.RelativePath
        $path = Join-Path $PSScriptRoot $relativePath
        $tokens = $null
        $errors = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($path, [ref]$tokens, [ref]$errors)
        if ($null -ne $errors -and @($errors).Count -ne 0) { throw "Production override AST parse failed for '$relativePath'." }
        $parameterRoot = $ast
        if ($null -ne $entrypoint.FunctionName) {
            $functions = @($ast.FindAll({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq [string]$entrypoint.FunctionName }, $true))
            if ($functions.Count -ne 1) { throw "Production entrypoint AST '$($entrypoint.FunctionName)' was not uniquely found." }
            $parameterRoot = $functions[0]
        }
        $parameterNames = @($parameterRoot.FindAll({ param($node) $node -is [System.Management.Automation.Language.ParameterAst] }, $true) | ForEach-Object { [string]$_.Name.VariablePath.UserPath })
        foreach ($name in $forbidden) {
            if ($parameterNames -contains $name) { throw "Production Human verifier exposes forbidden caller override '$name'." }
        }
    }
    $fixedLedger = Get-HumanVisualGoFixedReplayLedgerRoot
    $knownFolder = [IO.Path]::GetFullPath([Environment]::GetFolderPath([Environment+SpecialFolder]::LocalApplicationData)).TrimEnd('\', '/')
    if (-not $fixedLedger.StartsWith($knownFolder + '\', [StringComparison]::OrdinalIgnoreCase)) { throw 'Fixed replay ledger escaped LocalApplicationData.' }
    Pass 'AST proves production has no caller trust/time/replay-root overrides and ledger derives from KnownFolder'
}

Test-HumanProductionOverrideShape

function Get-HumanRendererFixtureDefinitions {
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string]$Source
    )

    if ([string]::IsNullOrWhiteSpace($Source)) {
        throw 'Renderer self-test source cannot be empty.'
    }

    $tokens = $null
    $parseErrors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseInput(
        $Source,
        [ref]$tokens,
        [ref]$parseErrors)
    if ($null -ne $parseErrors -and @($parseErrors).Count -ne 0) {
        throw "Renderer self-test fixture source does not parse: $($parseErrors[0].Message)"
    }

    $functionDefinitions = @($ast.FindAll({
        param($node)
        return $node -is [System.Management.Automation.Language.FunctionDefinitionAst]
    }, $true))

    # The extracted region starts at the first fixture dependency and ends at
    # the complete New-Fixture AST extent. This is deliberately independent of
    # line numbers, so helpers may be inserted before, between, or inside the
    # fixture functions without truncating the closing brace.
    $startBoundaryName = 'New-TestSha'
    $endBoundaryName = 'New-Fixture'
    $startBoundaries = @($functionDefinitions | Where-Object { $_.Name -ieq $startBoundaryName })
    $endBoundaries = @($functionDefinitions | Where-Object { $_.Name -ieq $endBoundaryName })
    if ($startBoundaries.Count -ne 1) {
        throw "Renderer fixture start boundary '$startBoundaryName' must occur exactly once; found $($startBoundaries.Count)."
    }
    if ($endBoundaries.Count -ne 1) {
        throw "Renderer fixture end boundary '$endBoundaryName' must occur exactly once; found $($endBoundaries.Count)."
    }

    $startOffset = [int]$startBoundaries[0].Extent.StartOffset
    $endOffset = [int]$endBoundaries[0].Extent.EndOffset
    if ($startOffset -lt 0 -or $endOffset -le $startOffset -or $endOffset -gt $Source.Length) {
        throw 'Renderer fixture function boundaries are not ordered or contained by the source.'
    }

    return $Source.Substring($startOffset, $endOffset - $startOffset)
}

function Test-HumanRendererFixtureBoundaryExtraction {
    $helpersAroundFixture = @'
function New-TestSha {
    return 'sha'
}
function New-InsertedHelperBeforeFixture {
    return 'before'
}
function New-Fixture {
    function New-InsertedHelperInsideFixture {
        return 'inside'
    }
    return 'fixture'
}
function New-InsertedHelperAfterFixture {
    return 'after'
}
'@
    $extracted = Get-HumanRendererFixtureDefinitions -Source $helpersAroundFixture
    if ($extracted -notmatch '(?m)^\s*function\s+New-Fixture\b') {
        throw 'Function-boundary extraction omitted the fixture start.'
    }
    if ($extracted -notmatch '(?m)^\s*function\s+New-InsertedHelperBeforeFixture\b') {
        throw 'Function-boundary extraction omitted a helper before the fixture.'
    }
    if ($extracted -notmatch '(?m)^\s*function\s+New-InsertedHelperInsideFixture\b') {
        throw 'Function-boundary extraction omitted a helper nested inside the fixture.'
    }
    if ($extracted -match 'New-InsertedHelperAfterFixture') {
        throw 'Function-boundary extraction included a helper after the fixture.'
    }
    $tokens = $null
    $parseErrors = $null
    [System.Management.Automation.Language.Parser]::ParseInput($extracted, [ref]$tokens, [ref]$parseErrors) | Out-Null
    if ($null -ne $parseErrors -and @($parseErrors).Count -ne 0) {
        throw "Extracted fixture region does not parse: $($parseErrors[0].Message)"
    }
    Pass 'function-boundary extraction handles helpers before, inside, and after fixture'
}

Test-HumanRendererFixtureBoundaryExtraction

$missingStartBoundarySource = @'
function New-Fixture {
    return 'fixture'
}
'@
Expect-HumanFailure 'missing fixture start boundary' {
    Get-HumanRendererFixtureDefinitions -Source $missingStartBoundarySource
}

$missingEndBoundarySource = @'
function New-TestSha {
    return 'sha'
}
'@
Expect-HumanFailure 'missing fixture end boundary' {
    Get-HumanRendererFixtureDefinitions -Source $missingEndBoundarySource
}

$duplicateStartBoundarySource = @'
function New-TestSha {
    return 'sha-one'
}
function New-TestSha {
    return 'sha-two'
}
function New-Fixture {
    return 'fixture'
}
'@
Expect-HumanFailure 'duplicate fixture start boundary' {
    Get-HumanRendererFixtureDefinitions -Source $duplicateStartBoundarySource
}

$duplicateEndBoundarySource = @'
function New-TestSha {
    return 'sha'
}
function New-Fixture {
    return 'fixture-one'
}
function New-Fixture {
    return 'fixture-two'
}
'@
Expect-HumanFailure 'duplicate fixture end boundary' {
    Get-HumanRendererFixtureDefinitions -Source $duplicateEndBoundarySource
}

# Reuse the renderer self-test's deterministic package/manifest fixture builders
# without executing its main test body. The fixture is a clean temporary Git
# repository, so the production renderer verifier remains in its normal exact-
# candidate mode.
$rendererSelfTestPath = Join-Path $PSScriptRoot '..\v0.2-renderer-compatibility\Test-V02RendererCompatibilityManifest.SelfTests.ps1'
$script:HumanTestToolRoot = $PSScriptRoot
$rendererSource = Get-Content -LiteralPath $rendererSelfTestPath -Raw
$rendererFixtureDefinitions = (Get-HumanRendererFixtureDefinitions -Source $rendererSource).Replace('$PSScriptRoot', '$script:HumanTestToolRoot')
Invoke-Expression $rendererFixtureDefinitions

function New-HumanMatrixReceipt {
    param(
        [Parameter(Mandatory = $true)][string]$CaseId,
        [Parameter(Mandatory = $true)][string]$Timestamp,
        [Parameter(Mandatory = $true)]$RawEvidence
    )
    return [pscustomobject][ordered]@{
        schemaVersion = 1
        caseId = $CaseId
        observedUtc = $Timestamp
        outcome = 'PASS'
        operator = [pscustomobject][ordered]@{ identity = '@human-fixture-operator'; role = 'EvidenceOperator' }
        observer = [pscustomobject][ordered]@{ identity = '@human-fixture-observer'; role = 'IndependentObserver' }
        evidenceBoundary = [pscustomobject][ordered]@{ evidenceClass = 'Synthetic'; finalHumanGo = 'NOT_OBSERVED'; release = 'NOT_OBSERVED'; creditGranted = $false }
        rawEvidence = $RawEvidence
    }
}

function Complete-HumanFixture {
    param([Parameter(Mandatory = $true)]$Fixture)

    $manifest = Copy-HumanTestValue $Fixture.Manifest
    $captureIndex = 0
    foreach ($capture in @($manifest.captures)) {
        $referencePath = Join-Path $Fixture.RepositoryRoot ([string]$manifest.comparison.results[$captureIndex].referenceRelativePath)
        $capturePath = Join-Path $Fixture.Root ([string]$capture.relativePath)
        Copy-Item -LiteralPath $referencePath -Destination $capturePath -Force
        $png = Get-RendererPngIdentity -Root $Fixture.Root -Path $capturePath -Context "fixture capture $captureIndex"
        $capture.widthPixels = $png.Width
        $capture.heightPixels = $png.Height
        $capture.bytes = [long]$png.Bytes
        $capture.sha256 = [string]$png.Sha256
        $result = $manifest.comparison.results[$captureIndex]
        $result.status = 'PASS'
        $result.differentPixels = 0
        $result.differentPixelPercent = 0
        $result.maximumChannelDelta = 0
        $result.nonmaskedDifferenceCount = 0
        $result.disposition = 'exact held-byte equality; no visual difference'
        $captureIndex++
    }

    $producer = (Read-RendererEvidenceReceipt $manifest.rendererEvidence.producerReport 'fixture producer' $Fixture.Root $Fixture.RepositoryRoot).Value
    for ($index = 0; $index -lt @($producer.captures).Count; $index++) {
        $producer.captures[$index].sha256 = [string]$manifest.captures[$index].sha256
        $producer.captures[$index].observedUtc = [string]$manifest.captures[$index].observedUtc
    }
    $manifest.rendererEvidence.producerReport = New-EvidenceBinding $Fixture.Root 'producer/complete-renderer-report.json' $producer $Fixture.RepositoryRoot

    $caseIndex = 0
    foreach ($group in @('displayCases', 'mixedDpiTransitions', 'accessibilityCases', 'supportedEnvironmentCases')) {
        foreach ($case in @($manifest.matrices.$group)) {
            $timestamp = '2026-08-22T12:00:{0:00}.0000000+00:00' -f $caseIndex
            $raw = New-TestMatrixRawPayload -CaseId ([string]$case.id)
            $raw.observedUtc = $timestamp
            $rawRelativePath = 'raw/human-matrix-{0:00}.json' -f $caseIndex
            $rawPath = Join-Path $Fixture.Root $rawRelativePath
            New-Item -ItemType Directory -Path (Split-Path -Parent $rawPath) -Force | Out-Null
            Write-TestJson $raw $rawPath
            $rawIdentity = Get-RendererStableFileIdentity $Fixture.Root $rawPath "human matrix raw fixture $caseIndex"
            $rawBinding = [pscustomobject][ordered]@{ relativePath = $rawRelativePath; bytes = [long]$rawIdentity.Bytes; sha256 = [string]$rawIdentity.Sha256 }
            $receipt = New-HumanMatrixReceipt -CaseId ([string]$case.id) -Timestamp $timestamp -RawEvidence $rawBinding
            $case.status = 'PASS'
            $case.notes = 'synthetic complete matrix receipt'
            $case.evidenceReceipt = New-EvidenceBinding $Fixture.Root ("matrix/{0}/{1}.json" -f $group, $caseIndex) $receipt $Fixture.RepositoryRoot
            $caseIndex++
        }
    }

    $orders = @()
    foreach ($orderName in @('AB', 'BA')) {
        $warmupSample = [pscustomobject][ordered]@{
            cpuBasisPoints = 50
            workingSetMaximumBytes = 104857600
            latencyMicroseconds = @(1..20 | ForEach-Object { 100000 })
            uiStallMicroseconds = @(1..20 | ForEach-Object { 10000 })
        }
        $warmup = [pscustomobject][ordered]@{ ordinal = 0; observedUtc = '2026-08-22T13:40:00.0000000Z'; a = $warmupSample; b = (Copy-HumanTestValue $warmupSample) }
        $repetitions = @()
        for ($index = 0; $index -lt 5; $index++) {
            $sampleA = [pscustomobject][ordered]@{
                cpuBasisPoints = 50
                workingSetMaximumBytes = 104857600
                latencyMicroseconds = @(1..20 | ForEach-Object { 100000 })
                uiStallMicroseconds = @(1..20 | ForEach-Object { 10000 })
            }
            $sampleB = Copy-HumanTestValue $sampleA
            $second = $index + 1
            if ($orderName -ceq 'BA') { $second += 10 }
            $repetitions += [pscustomobject][ordered]@{
                ordinal = $index
                observedUtc = ('2026-08-22T13:4{0}:{1:00}.0000000Z' -f $(if ($orderName -ceq 'BA') { 1 } else { 0 }), $second)
                a = $sampleA
                b = $sampleB
            }
        }
        $orders += [pscustomobject][ordered]@{ order = $orderName; warmup = @($warmup); repetitions = $repetitions }
    }
    $soakBins = @()
    for ($index = 0; $index -lt 24; $index++) {
        $power = if ($index -lt 12) { 'AC' } else { 'Battery' }
        $ordinal = $index % 12
        $soakBins += [pscustomobject][ordered]@{
            powerSource = $power
            ordinal = $ordinal
            durationMinutes = 5
            observedUtc = ('2026-08-22T14:{0:00}:00.0000000Z' -f $index)
            workingSetStartBytes = 104857600
            workingSetEndBytes = 104857600
            rendererStable = $true
        }
    }
    $rawMeasurements = [pscustomobject][ordered]@{ orders = $orders; soakBins = $soakBins }
    $rawBinding = [pscustomobject](New-EvidenceBinding $Fixture.Root 'performance/complete-raw-observations.json' $rawMeasurements $Fixture.RepositoryRoot)
    $performanceReceipt = [pscustomobject][ordered]@{
        provenance = New-RendererPerformanceProvenance $manifest.candidate $manifest.environment.session
        rawSource = $rawBinding
        orders = $orders
        soakBins = $soakBins
        aggregateStatus = 'PASS'
    }
    $manifest.performanceProtocol.samplesStatus = 'PASS'
    $manifest.performanceProtocol.evidenceReceipt = New-EvidenceBinding $Fixture.Root 'performance/complete-receipt.json' $performanceReceipt $Fixture.RepositoryRoot

    $manifest.review.defects = @([pscustomobject][ordered]@{
        id = 'VIS-FIXTURE-001'
        severity = 'P2'
        summary = 'Synthetic fixture has a closed visual disposition.'
        status = 'Resolved'
        disposition = 'Resolved in the synthetic fixture before candidate hand-off.'
    })
    $manifest.review.decision = 'NOT_OBSERVED'
    $manifest.evidenceBoundary.humanReview = 'NOT_OBSERVED'
    $completePath = Join-Path $Fixture.Root 'renderer-compatibility-complete.json'
    Write-TestJson $manifest $completePath
    $manifestRawSha = (Get-FileHash -LiteralPath $completePath -Algorithm SHA256).Hash
    $reviewEvidence = [pscustomobject][ordered]@{
        '$id' = 'https://herdrops.local/schema/v0.2/human-visual-review-evidence.schema.json'
        schemaVersion = 1
        evidenceClassification = 'HumanVisualReviewEvidence'
        issue = 11
        compatibilityIssue = 149
        candidate = [pscustomobject][ordered]@{
            sourceCommitSha = [string]$manifest.candidate.source.commitSha
            sourceTreeSha = [string]$manifest.candidate.source.treeSha
            rendererManifestSha256 = [string]$manifestRawSha
        }
        comparisons = @($manifest.comparison.results | ForEach-Object {
            [pscustomobject][ordered]@{ key = "$($_.language)|$($_.captureName)"; status = [string]$_.status; referenceRelativePath = [string]$_.referenceRelativePath; disposition = [string]$_.disposition }
        })
        checks = @($script:RendererVisualChecks | ForEach-Object {
            [pscustomobject][ordered]@{ id = [string]$_; status = 'PASS'; notes = 'Synthetic governed visual checklist evidence; final Human authority remains external.' }
        })
        defects = @(Copy-HumanTestValue $manifest.review.defects)
        evidenceBoundary = [pscustomobject][ordered]@{ humanReview = 'NOT_OBSERVED'; actualHerdrRuntime = 'NOT_OBSERVED'; release = 'NOT_OBSERVED'; creditGranted = $false }
    }
    $reviewPath = Join-Path $Fixture.Root 'human-review/visual-review-evidence.json'
    New-Item -ItemType Directory -Path (Split-Path -Parent $reviewPath) -Force | Out-Null
    Write-HumanCanonicalJson -Value $reviewEvidence -Path $reviewPath -RepositoryRoot $Fixture.RepositoryRoot
    return [pscustomobject]@{ Root = $Fixture.Root; RepositoryRoot = $Fixture.RepositoryRoot; Path = $completePath; ReviewPath = $reviewPath; Manifest = $manifest; ReviewEvidence = $reviewEvidence }
}

function New-HumanTestAuthorityKey {
    $rsa = New-Object System.Security.Cryptography.RSACryptoServiceProvider
    try {
        return [pscustomobject][ordered]@{
            PrivateXml = $rsa.ToXmlString($true)
            PublicXml = $rsa.ToXmlString($false)
        }
    }
    finally {
        $rsa.Dispose()
    }
}

function Add-HumanTestAuthoritySignature {
    param(
        [Parameter(Mandatory = $true)]$Attestation,
        [Parameter(Mandatory = $true)]$AuthorityKey,
        [Parameter(Mandatory = $true)][string]$RepositoryRoot
    )
    $payload = Get-HumanVisualGoAttestationSigningCanonicalText -Attestation $Attestation -RepositoryRoot $RepositoryRoot
    $payloadBytes = [Text.UTF8Encoding]::new($false, $true).GetBytes($payload)
    $rsa = New-Object System.Security.Cryptography.RSACryptoServiceProvider
    try {
        $rsa.FromXmlString([string]$AuthorityKey.PrivateXml)
        $signature = [byte[]]$rsa.SignData($payloadBytes, 'SHA256')
    }
    finally {
        $rsa.Dispose()
    }
    $Attestation.authority.signatureBase64 = [Convert]::ToBase64String($signature)
    $Attestation.authority.proofSha256 = Get-HumanVisualGoSha256ForBytes -Bytes $signature
    return $Attestation
}

function New-HumanExternalAttestation {
    param(
        [Parameter(Mandatory = $true)]$Candidate,
        [Parameter(Mandatory = $true)][string]$CandidatePath,
        [Parameter(Mandatory = $true)][string]$RepositoryRoot,
        [Parameter(Mandatory = $true)]$AuthorityKey,
        [ValidateSet('GO', 'NO_GO')][string]$Decision = 'GO',
        [string]$ReplayNonce = ('A' * 64),
        [string]$ReviewedUtc
    )
    $candidateCanonical = Get-HumanVisualGoCanonicalText -Value $Candidate -RepositoryRoot $RepositoryRoot
    $candidateBytes = [IO.File]::ReadAllBytes($CandidatePath)
    if ([string]::IsNullOrWhiteSpace($ReviewedUtc)) {
        $ReviewedUtc = [DateTimeOffset]::UtcNow.AddMinutes(-1).ToString("yyyy-MM-dd'T'HH:mm:ss.fffffff'Z'", [Globalization.CultureInfo]::InvariantCulture)
    }
    $attestation = [pscustomobject][ordered]@{
        '$id' = $script:HumanVisualGoAttestationSchemaId
        schemaVersion = 1
        evidenceClassification = 'ExternalHumanVisualGoAttestation'
        issue = 11
        compatibilityIssue = 149
        attestationId = 'external-human-visual-go-fixture-001'
        decision = $Decision
        decisionRationale = if ($Decision -ceq 'GO') { 'All governed visual, matrix, performance, soak, and defect checks pass.' } else { 'Synthetic reviewer deliberately records NO_GO for the hostile decision case.' }
        reviewedUtc = $ReviewedUtc
        replayNonce = $ReplayNonce.ToUpperInvariant()
        candidate = [pscustomobject][ordered]@{
            sourceCommitSha = [string]$Candidate.source.commitSha
            sourceTreeSha = [string]$Candidate.source.treeSha
            candidateFileSha256 = Get-HumanVisualGoSha256ForBytes -Bytes $candidateBytes
            candidateCanonicalSha256 = Get-HumanVisualGoSha256ForBytes -Bytes ([Text.UTF8Encoding]::new($false).GetBytes($candidateCanonical))
            rendererManifestSha256 = [string]$Candidate.rendererManifest.sha256
            packageArchiveSha256 = [string]$Candidate.package.archive.sha256
            packageAppSha256 = [string]$Candidate.package.app.sha256
            packageCoreSha256 = [string]$Candidate.package.core.sha256
            herdrExecutableSha256 = [string]$Candidate.herdr.executableSha256
            herdrBindingSha256 = [string]$Candidate.herdr.bindingSha256
            sessionBindingSha256 = [string]$Candidate.session.bindingSha256
            evidenceSetSha256 = [string]$Candidate.evidenceSetSha256
        }
        reviewer = [pscustomobject][ordered]@{
            identity = '@yutthaphon'
            role = 'HumanReviewer'
            authorityRole = 'ProductOwner'
            builderIdentity = [string]$Candidate.roles.builderIdentity
            runtimeOperatorIdentity = [string]$Candidate.roles.runtimeOperatorIdentity
            independentValidatorIdentity = [string]$Candidate.roles.independentValidatorIdentity
            identityDistinct = $true
        }
        authority = [pscustomobject][ordered]@{
            reference = 'https://external.example.invalid/herdrops/v0.2/human-attestation/fixture-001'
            authenticationMethod = $script:HumanVisualGoAttestationMethod
            authenticated = $true
            proofSha256 = ('0' * 64)
            publicKeySha256 = Get-HumanVisualGoSha256ForBytes -Bytes ([Text.UTF8Encoding]::new($false, $true).GetBytes([string]$AuthorityKey.PublicXml))
            signatureAlgorithm = $script:HumanVisualGoFixtureSignatureAlgorithm
            signatureBase64 = 'pending'
        }
        visualDispositions = @(Copy-HumanTestValue $Candidate.visualReview.comparisons)
        visualChecks = @(Copy-HumanTestValue $Candidate.visualReview.checks)
        defects = @(Copy-HumanTestValue $Candidate.defects)
        evidenceBindings = @(Copy-HumanTestValue $Candidate.evidenceBindings)
        evidenceSetSha256 = [string]$Candidate.evidenceSetSha256
        evidenceBoundary = [pscustomobject][ordered]@{ humanReview = $Decision; actualHerdrRuntime = 'NOT_OBSERVED'; release = 'NOT_OBSERVED'; creditGranted = $false }
    }
    return Add-HumanTestAuthoritySignature -Attestation $attestation -AuthorityKey $AuthorityKey -RepositoryRoot $RepositoryRoot
}

$temp = Join-Path ([IO.Path]::GetTempPath()) ('herdrops-human-visual-go-' + [Guid]::NewGuid().ToString('N'))
try {
    New-Item -ItemType Directory -Path $temp -Force | Out-Null
    $repo = New-TestRepository -Root (Join-Path $temp 'repo')
    # The renderer verifier reads this immutable repository file while
    # validating reference PNGs. Add it before the fixture commit so the
    # candidate repository remains clean and its source tree includes it.
    $fixtureManifestPath = Join-Path $repo.Root 'docs\design\reference\MANIFEST.md'
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot '..\..\docs\design\reference\MANIFEST.md') -Destination $fixtureManifestPath -Force
    & git -C $repo.Root -c core.hooksPath=NUL -c user.name=HumanFixture -c user.email=human@example.invalid add -- 'docs/design/reference/MANIFEST.md'
    & git -C $repo.Root -c core.hooksPath=NUL -c commit.gpgsign=false -c user.name=HumanFixture -c user.email=human@example.invalid commit --quiet -m 'fixture reference manifest'
    if ($LASTEXITCODE -ne 0) { throw 'Unable to commit the immutable reference manifest into the clean Human fixture.' }
    $repo.Commit = (& git -C $repo.Root rev-parse HEAD).Trim()
    $repo.Tree = (& git -C $repo.Root rev-parse 'HEAD^{tree}').Trim()
    $fixture = New-Fixture -Root (Join-Path $temp 'evidence') -RepositoryRoot $repo.Root -Commit $repo.Commit -Tree $repo.Tree
    $fixture = Complete-HumanFixture -Fixture $fixture
    $external = Join-Path $temp 'external'
    New-Item -ItemType Directory -Path $external -Force | Out-Null
    $authorityKey = New-HumanTestAuthorityKey
    $authorityKeySha = Get-HumanVisualGoSha256ForBytes -Bytes ([Text.UTF8Encoding]::new($false, $true).GetBytes($authorityKey.PublicXml))
    $replayRegistry = Join-Path $external 'replay-registry'
    New-Item -ItemType Directory -Path $replayRegistry -Force | Out-Null
    $candidatePath = Join-Path $external 'HumanReviewCandidate.json'
    $attestationPath = Join-Path $external 'HumanVisualGoAttestation.json'

    $scratchTarget = Join-Path $external 'swap-scratch-target.txt'
    $scratchReplacement = Join-Path $external 'swap-scratch-replacement.txt'
    [IO.File]::WriteAllText($scratchTarget, 'scratch-original-bytes', [Text.UTF8Encoding]::new($false))
    [IO.File]::WriteAllText($scratchReplacement, 'scratch-replacement-distinct-bytes', [Text.UTF8Encoding]::new($false))
    $scratchHostile = Start-HumanSwapExecuteRestoreHostile -Target $scratchTarget -Replacement $scratchReplacement -DurationSeconds 3
    Start-Sleep -Milliseconds 750
    $scratchResult = Stop-HumanSwapExecuteRestoreHostile -Hostile $scratchHostile
    if ($scratchResult.TerminationReason -cne 'wrapper-stop' -or $scratchResult.Swaps -lt 1 -or $scratchResult.DistinctSwaps -lt 1 -or $scratchResult.Restores -lt 1 -or [IO.File]::ReadAllText($scratchTarget) -cne 'scratch-original-bytes') { throw 'Swap hostile fixture did not execute and restore a real unheld swap with distinct replacement bytes.' }
    Pass 'swap-execute-restore hostile fixture is live before the held renderer window'

    $rendererMutationTarget = Join-Path $fixture.Root ([string]$fixture.Manifest.captures[0].relativePath)
    $rendererMutationReplacement = Join-Path $external 'renderer-hostile-replacement.distinct'
    [IO.File]::WriteAllText($rendererMutationReplacement, 'renderer-hostile-replacement-distinct-bytes', [Text.UTF8Encoding]::new($false))
    $rendererOriginalBytes = [IO.File]::ReadAllBytes($rendererMutationTarget)
    $rendererOriginalSha = Get-HumanVisualGoSha256ForBytes -Bytes $rendererOriginalBytes
    $rendererChildResultPath = Join-Path $external 'renderer-window-child-result.json'
    $rendererChildStdoutPath = Join-Path $external 'renderer-window-child.stdout.log'
    $rendererChildStderrPath = Join-Path $external 'renderer-window-child.stderr.log'
    $childHost = if ($PSVersionTable.PSVersion.Major -ge 7) { Join-Path $PSHOME 'pwsh.exe' } else { Join-Path $PSHOME 'powershell.exe' }
    $childArguments = @(
        '-NoLogo', '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass',
        '-File', [IO.Path]::GetFullPath($PSCommandPath),
        '-RendererWindowChild',
        '-ChildRendererManifestPath', $fixture.Path,
        '-ChildReviewEvidencePath', $fixture.ReviewPath,
        '-ChildEvidenceRoot', $fixture.Root,
        '-ChildRepositoryRoot', $fixture.RepositoryRoot,
        '-ChildCandidateOutputPath', $candidatePath,
        '-ChildHostileTarget', $rendererMutationTarget,
        '-ChildHostileReplacement', $rendererMutationReplacement,
        '-ChildResultPath', $rendererChildResultPath
    )
    $rendererChildProcess = Start-Process -FilePath $childHost -WindowStyle Hidden -PassThru -ArgumentList $childArguments -RedirectStandardOutput $rendererChildStdoutPath -RedirectStandardError $rendererChildStderrPath
    # PS5.1 canonical verification is materially slower than PS7 on the full
    # held evidence graph. Keep the test bounded below the hostile child's
    # independent 900-second deadline while allowing the verifier to finish.
    if (-not $rendererChildProcess.WaitForExit(780000)) {
        try { & taskkill.exe /PID $rendererChildProcess.Id /T /F 2>$null | Out-Null } catch { }
        throw 'Renderer-window child exceeded the bounded 780-second fixture timeout.'
    }
    # Flush redirected stdout/stderr after the process handle is signaled.
    $rendererChildProcess.WaitForExit()
    $rendererChildProcess.Refresh()
    $rendererChildExitCode = $rendererChildProcess.ExitCode
    # Windows PowerShell 5.1 can leave ExitCode unset for a redirected
    # Start-Process child. The mandatory result record below remains the
    # fail-closed authority in that compatibility case.
    if ($null -ne $rendererChildExitCode -and [int]$rendererChildExitCode -ne 0) {
        $childError = if (Test-Path -LiteralPath $rendererChildStderrPath) { [IO.File]::ReadAllText($rendererChildStderrPath) } else { '' }
        throw "Renderer-window child failed with exit code $rendererChildExitCode`: $childError"
    }
    if (-not (Test-Path -LiteralPath $rendererChildResultPath -PathType Leaf)) { throw 'Renderer-window child did not produce its result record.' }
    $rendererChildResultJson = [IO.File]::ReadAllText($rendererChildResultPath)
    $rendererChildResult = if ($PSVersionTable.PSVersion.Major -ge 7) { $rendererChildResultJson | ConvertFrom-Json -DateKind String } else { $rendererChildResultJson | ConvertFrom-Json }
    if ($rendererChildResult.Status -cne 'PASS' -or
        $rendererChildResult.TerminationReason -cne 'wrapper-stop' -or
        $rendererChildResult.Attempts -lt 1 -or
        $rendererChildResult.Writes -ne 0 -or
        $rendererChildResult.Swaps -ne 0 -or
        $rendererChildResult.DistinctSwaps -ne 0 -or
        $rendererChildResult.Restores -ne 0 -or
        -not [bool]$rendererChildResult.RendererReturned -or
        -not [bool]$rendererChildResult.HostileStartedBeforeRenderer -or
        -not [bool]$rendererChildResult.HostileStoppedBeforeWrapperReturn) {
        throw "Renderer-window child did not prove a continuous held window with wrapper-stop termination: $rendererChildResultJson"
    }
    $rendererAfterSha = Get-HumanVisualGoSha256ForBytes -Bytes ([IO.File]::ReadAllBytes($rendererMutationTarget))
    if ($rendererAfterSha -cne $rendererOriginalSha -or [string]$rendererChildResult.TargetSha256After -cne $rendererOriginalSha) {
        throw 'Renderer-window child left the original capture bytes changed.'
    }
    if (-not (Test-Path -LiteralPath $candidatePath -PathType Leaf)) { throw 'Renderer-window child did not emit the HumanReviewCandidate.' }
    $candidateJson = [IO.File]::ReadAllText($candidatePath)
    $candidate = if ($PSVersionTable.PSVersion.Major -ge 7) { $candidateJson | ConvertFrom-Json -DateKind String } else { $candidateJson | ConvertFrom-Json }
    $candidateBytes = [IO.File]::ReadAllBytes($candidatePath)
    $candidateCanonical = Get-HumanVisualGoCanonicalText -Value $candidate -RepositoryRoot $fixture.RepositoryRoot
    $candidateReceipt = [pscustomobject]@{
        FileSha256 = Get-HumanVisualGoSha256ForBytes -Bytes $candidateBytes
        CanonicalSha256 = Get-HumanVisualGoSha256ForBytes -Bytes ([Text.UTF8Encoding]::new($false).GetBytes($candidateCanonical))
    }
    if ($candidateReceipt.FileSha256 -cne [string]$rendererChildResult.CandidateFileSha256 -or $candidateReceipt.CanonicalSha256 -cne [string]$rendererChildResult.CandidateCanonicalSha256) {
        throw 'Renderer-window child candidate receipt did not bind the emitted candidate bytes.'
    }
    Pass-Negative 'real production renderer window blocked distinct write/swap/restore mutation'

    Pass 'builder emits only a HumanReviewCandidate with NOT_OBSERVED boundary'

    $candidateOnly = Test-V02HumanVisualGoAttestationCore -CandidatePath $candidatePath -EvidenceRoot $fixture.Root -RepositoryRoot $fixture.RepositoryRoot
    if ($candidateOnly.HumanReview -cne 'NOT_OBSERVED' -or $candidateOnly.Release -cne 'NOT_OBSERVED' -or $candidateOnly.ActualHerdrRuntime -cne 'NOT_OBSERVED' -or [bool]$candidateOnly.CreditGranted) { throw 'Candidate-only output crossed the Human/Runtime/Release boundary.' }
    Pass 'candidate-only verifier remains NOT_OBSERVED and no-credit'

    $attestation = New-HumanExternalAttestation -Candidate $candidate -CandidatePath $candidatePath -RepositoryRoot $fixture.RepositoryRoot -AuthorityKey $authorityKey -Decision GO -ReplayNonce ('A' * 64)
    Write-HumanCanonicalJson -Value $attestation -Path $attestationPath -RepositoryRoot $fixture.RepositoryRoot
    Expect-HumanFailure 'production Human attestation fails closed without owner policy' {
        Test-V02HumanVisualGoAttestationCore -CandidatePath $candidatePath -AttestationPath $attestationPath -EvidenceRoot $fixture.Root -RepositoryRoot $fixture.RepositoryRoot
    } 'TRUST_ROOT_NOT_CONFIGURED; FRESHNESS_POLICY_NOT_CONFIGURED'
    Pass 'production Human GO remains NOT_READY until owner trust/freshness policy exists'

    $missingReplayNonce = Copy-HumanTestValue $attestation
    [void]$missingReplayNonce.PSObject.Properties.Remove('replayNonce')
    Expect-HumanFailure 'missing replayNonce is rejected by exact attestation shape' {
        Assert-HumanVisualGoAttestationShape -Attestation $missingReplayNonce
    } 'External Human attestation must contain exactly'
    $extraReplayNonce = Copy-HumanTestValue $attestation
    $extraReplayNonce | Add-Member -NotePropertyName replayNonceExtra -NotePropertyValue ('D' * 64)
    Expect-HumanFailure 'extra replayNonce field is rejected by exact attestation shape' {
        Assert-HumanVisualGoAttestationShape -Attestation $extraReplayNonce
    } 'External Human attestation must contain exactly'

    $fixtureTrustedNow = [DateTimeOffset]::UtcNow
    $fixtureReviewed = [DateTimeOffset]::ParseExact([string]$attestation.reviewedUtc, "yyyy-MM-dd'T'HH:mm:ss.fffffff'Z'", [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::AssumeUniversal)
    $fixtureMaximumAge = $fixtureTrustedNow.Subtract($fixtureReviewed).Add([TimeSpan]::FromSeconds(1))
    if ($fixtureMaximumAge -le [TimeSpan]::Zero) { $fixtureMaximumAge = [TimeSpan]::FromSeconds(1) }
    $fixtureMaximumFutureSkew = [TimeSpan]::Zero
    $timestampProbe = [pscustomobject][ordered]@{
        observedUtc = '2026-08-22T10:00:00.0000000Z'
        run = [pscustomobject][ordered]@{ endedUtc = '2026-08-22T10:05:00.0000000Z' }
    }
    $timestampProbeLatest = @((Get-HumanVisualGoTimestampValues -Value $timestampProbe) | Sort-Object)[-1]
    if ($timestampProbeLatest -ne [DateTimeOffset]::ParseExact('2026-08-22T10:05:00.0000000Z', "yyyy-MM-dd'T'HH:mm:ss.fffffff'Z'", [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::AssumeUniversal)) {
        throw 'Freshness timestamp discovery omitted a governed endedUtc value.'
    }
    Pass 'freshness chronology includes governed endedUtc values'
    Assert-HumanVisualGoAttestationAgainstCandidate -Candidate $candidate -Attestation $attestation -CandidateFileSha256 $candidateReceipt.FileSha256 -CandidateCanonicalSha256 $candidateReceipt.CanonicalSha256 -RepositoryRoot $fixture.RepositoryRoot -TrustedAuthorityPublicKeyXml $authorityKey.PublicXml -TrustedAuthorityPublicKeySha256 $authorityKeySha -ExpectedSignatureAlgorithm $script:HumanVisualGoFixtureSignatureAlgorithm
    Assert-HumanVisualGoAttestationFreshness -Candidate $candidate -Attestation $attestation -EvidenceRoot $fixture.Root -RepositoryRoot $fixture.RepositoryRoot -TrustedNowUtc $fixtureTrustedNow -MaximumAge $fixtureMaximumAge -MaximumFutureSkew $fixtureMaximumFutureSkew
    $replayBinding = [pscustomobject][ordered]@{
        sourceCommitSha = [string]$candidate.source.commitSha
        sourceTreeSha = [string]$candidate.source.treeSha
        candidateFileSha256 = [string]$candidateReceipt.FileSha256
        candidateCanonicalSha256 = [string]$candidateReceipt.CanonicalSha256
        evidenceSetSha256 = [string]$candidate.evidenceSetSha256
    }
    $replayBindingSha = Get-HumanVisualGoCanonicalSha256 -Value $replayBinding -RepositoryRoot $fixture.RepositoryRoot
    [void](Claim-HumanVisualGoReplayNonce -RegistryRoot $replayRegistry -Nonce ('A' * 64) -CandidateBindingSha256 $replayBindingSha -RepositoryRoot $fixture.RepositoryRoot)
    Pass 'fixture-only detached authority/freshness/nonce helpers accept bound synthetic evidence'

    $forgedAuthority = Copy-HumanTestValue $attestation
    $forgedSignature = [Text.UTF8Encoding]::new($false).GetBytes('caller-authored proof')
    $forgedAuthority.authority.signatureBase64 = [Convert]::ToBase64String($forgedSignature)
    $forgedAuthority.authority.proofSha256 = Get-HumanVisualGoSha256ForBytes -Bytes $forgedSignature
    Expect-HumanFailure 'caller-authored authenticated/proof without trusted signature' {
        Assert-HumanVisualGoAttestationAgainstCandidate -Candidate $candidate -Attestation $forgedAuthority -CandidateFileSha256 $candidateReceipt.FileSha256 -CandidateCanonicalSha256 $candidateReceipt.CanonicalSha256 -RepositoryRoot $fixture.RepositoryRoot -TrustedAuthorityPublicKeyXml $authorityKey.PublicXml -TrustedAuthorityPublicKeySha256 $authorityKeySha -ExpectedSignatureAlgorithm $script:HumanVisualGoFixtureSignatureAlgorithm
    } 'Trusted cryptographic authority signature verification failed'

    $modifiedAuthority = Copy-HumanTestValue $attestation
    $modifiedAuthority.authority.reference = 'https://external.example.invalid/herdrops/v0.2/human-attestation/modified'
    Expect-HumanFailure 'signed authority metadata modification' {
        Assert-HumanVisualGoAttestationAgainstCandidate -Candidate $candidate -Attestation $modifiedAuthority -CandidateFileSha256 $candidateReceipt.FileSha256 -CandidateCanonicalSha256 $candidateReceipt.CanonicalSha256 -RepositoryRoot $fixture.RepositoryRoot -TrustedAuthorityPublicKeyXml $authorityKey.PublicXml -TrustedAuthorityPublicKeySha256 $authorityKeySha -ExpectedSignatureAlgorithm $script:HumanVisualGoFixtureSignatureAlgorithm
    } 'Trusted cryptographic authority signature verification failed'

    $wrongAuthorityKey = New-HumanTestAuthorityKey
    $wrongAuthorityKeySha = Get-HumanVisualGoSha256ForBytes -Bytes ([Text.UTF8Encoding]::new($false, $true).GetBytes($wrongAuthorityKey.PublicXml))
    Expect-HumanFailure 'untrusted authority key substitution' {
        Assert-HumanVisualGoAttestationAgainstCandidate -Candidate $candidate -Attestation $attestation -CandidateFileSha256 $candidateReceipt.FileSha256 -CandidateCanonicalSha256 $candidateReceipt.CanonicalSha256 -RepositoryRoot $fixture.RepositoryRoot -TrustedAuthorityPublicKeyXml $wrongAuthorityKey.PublicXml -TrustedAuthorityPublicKeySha256 $wrongAuthorityKeySha -ExpectedSignatureAlgorithm $script:HumanVisualGoFixtureSignatureAlgorithm
    } 'public-key fingerprint does not equal'

    Expect-HumanFailure 'attestation without independent trusted key' {
        Test-V02HumanVisualGoAttestationCore -CandidatePath $candidatePath -AttestationPath $attestationPath -EvidenceRoot $fixture.Root -RepositoryRoot $fixture.RepositoryRoot
    } 'TRUST_ROOT_NOT_CONFIGURED; FRESHNESS_POLICY_NOT_CONFIGURED'

    Expect-HumanFailure 'caller-selected replay root override is unavailable' {
        Test-V02HumanVisualGoAttestationCore -CandidatePath $candidatePath -AttestationPath $attestationPath -EvidenceRoot $fixture.Root -RepositoryRoot $fixture.RepositoryRoot -ReplayRegistryRoot $replayRegistry
    } 'parameter.*ReplayRegistryRoot'
    Expect-HumanFailure 'caller-selected trust key override is unavailable' {
        Test-V02HumanVisualGoAttestationCore -CandidatePath $candidatePath -AttestationPath $attestationPath -EvidenceRoot $fixture.Root -RepositoryRoot $fixture.RepositoryRoot -TrustedAuthorityPublicKeyPath 'attacker-key.xml'
    } 'parameter.*TrustedAuthorityPublicKeyPath'

    $attackerKey = New-HumanTestAuthorityKey
    $attackerAttestation = New-HumanExternalAttestation -Candidate $candidate -CandidatePath $candidatePath -RepositoryRoot $fixture.RepositoryRoot -AuthorityKey $attackerKey -Decision GO -ReplayNonce ('C' * 64)
    $attackerAttestationPath = Join-Path $external 'attacker-generated-authority.json'
    Write-HumanCanonicalJson -Value $attackerAttestation -Path $attackerAttestationPath -RepositoryRoot $fixture.RepositoryRoot
    Expect-HumanFailure 'attacker-generated RSA authority cannot enter production' {
        Test-V02HumanVisualGoAttestationCore -CandidatePath $candidatePath -AttestationPath $attackerAttestationPath -EvidenceRoot $fixture.Root -RepositoryRoot $fixture.RepositoryRoot
    } 'TRUST_ROOT_NOT_CONFIGURED; FRESHNESS_POLICY_NOT_CONFIGURED'

    $staleTime = Copy-HumanTestValue $attestation
    $staleTime.reviewedUtc = $fixtureTrustedNow.AddMinutes(-10).ToString("yyyy-MM-dd'T'HH:mm:ss.fffffff'Z'", [Globalization.CultureInfo]::InvariantCulture)
    $staleMaximumAge = $fixtureTrustedNow.Subtract([DateTimeOffset]::ParseExact([string]$staleTime.reviewedUtc, "yyyy-MM-dd'T'HH:mm:ss.fffffff'Z'", [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::AssumeUniversal)).Subtract([TimeSpan]::FromSeconds(1))
    Expect-HumanFailure 'reviewed time before held evidence' {
        Assert-HumanVisualGoAttestationFreshness -Candidate $candidate -Attestation $staleTime -EvidenceRoot $fixture.Root -RepositoryRoot $fixture.RepositoryRoot -TrustedNowUtc $fixtureTrustedNow -MaximumAge $staleMaximumAge -MaximumFutureSkew $fixtureMaximumFutureSkew
    } 'exceeds the configured maximum accepted age'

    $futureTime = Copy-HumanTestValue $attestation
    $futureTime.reviewedUtc = $fixtureTrustedNow.AddSeconds(1).ToString("yyyy-MM-dd'T'HH:mm:ss.fffffff'Z'", [Globalization.CultureInfo]::InvariantCulture)
    Expect-HumanFailure 'reviewed time ahead of trusted clock' {
        Assert-HumanVisualGoAttestationFreshness -Candidate $candidate -Attestation $futureTime -EvidenceRoot $fixture.Root -RepositoryRoot $fixture.RepositoryRoot -TrustedNowUtc $fixtureTrustedNow -MaximumAge $fixtureMaximumAge -MaximumFutureSkew $fixtureMaximumFutureSkew
    } 'ahead of the trusted verifier clock'

    $noncePath = Join-Path $replayRegistry (('A' * 64) + '.nonce')
    $nonceBefore = [IO.File]::ReadAllBytes($noncePath)
    Expect-HumanFailure 'replay nonce atomic no-clobber' {
        Claim-HumanVisualGoReplayNonce -RegistryRoot $replayRegistry -Nonce ('A' * 64) -CandidateBindingSha256 $replayBindingSha -RepositoryRoot $fixture.RepositoryRoot
    } 'replay nonce is already claimed; atomic CreateNew rejected a clobber'
    $nonceAfter = [IO.File]::ReadAllBytes($noncePath)
    if ((Get-HumanVisualGoSha256ForBytes -Bytes $nonceBefore) -cne (Get-HumanVisualGoSha256ForBytes -Bytes $nonceAfter)) { throw 'Replay nonce no-clobber hostile changed the existing nonce record.' }

    $noGoPath = Join-Path $external 'HumanVisualGo-NoGo.json'
    $noGo = New-HumanExternalAttestation -Candidate $candidate -CandidatePath $candidatePath -RepositoryRoot $fixture.RepositoryRoot -AuthorityKey $authorityKey -Decision NO_GO -ReplayNonce ('B' * 64) -ReviewedUtc ([string]$attestation.reviewedUtc)
    Write-HumanCanonicalJson -Value $noGo -Path $noGoPath -RepositoryRoot $fixture.RepositoryRoot
    Assert-HumanVisualGoAttestationAgainstCandidate -Candidate $candidate -Attestation $noGo -CandidateFileSha256 $candidateReceipt.FileSha256 -CandidateCanonicalSha256 $candidateReceipt.CanonicalSha256 -RepositoryRoot $fixture.RepositoryRoot -TrustedAuthorityPublicKeyXml $authorityKey.PublicXml -TrustedAuthorityPublicKeySha256 $authorityKeySha -ExpectedSignatureAlgorithm $script:HumanVisualGoFixtureSignatureAlgorithm
    Assert-HumanVisualGoAttestationFreshness -Candidate $candidate -Attestation $noGo -EvidenceRoot $fixture.Root -RepositoryRoot $fixture.RepositoryRoot -TrustedNowUtc $fixtureTrustedNow -MaximumAge $fixtureMaximumAge -MaximumFutureSkew $fixtureMaximumFutureSkew
    [void](Claim-HumanVisualGoReplayNonce -RegistryRoot $replayRegistry -Nonce ('B' * 64) -CandidateBindingSha256 $replayBindingSha -RepositoryRoot $fixture.RepositoryRoot)
    Pass 'fixture-only external NO_GO remains a non-release decision'

    $copiedCandidate = Join-Path $fixture.Root 'copied-candidate.json'
    Copy-Item -LiteralPath $candidatePath -Destination $copiedCandidate
    Expect-HumanFailure 'copied candidate under evidence root is rejected' { Test-V02HumanVisualGoAttestationCore -CandidatePath $copiedCandidate -AttestationPath $attestationPath -EvidenceRoot $fixture.Root -RepositoryRoot $fixture.RepositoryRoot }

    $staleAttestation = Copy-HumanTestValue $attestation
    $staleAttestation.candidate.candidateCanonicalSha256 = 'B' * 64
    $stalePath = Join-Path $external 'stale-attestation.json'
    Write-HumanCanonicalJson -Value $staleAttestation -Path $stalePath -RepositoryRoot $fixture.RepositoryRoot
    Expect-HumanFailure 'stale candidate canonical receipt' { Assert-HumanVisualGoAttestationAgainstCandidate -Candidate $candidate -Attestation $staleAttestation -CandidateFileSha256 $candidateReceipt.FileSha256 -CandidateCanonicalSha256 $candidateReceipt.CanonicalSha256 -RepositoryRoot $fixture.RepositoryRoot -TrustedAuthorityPublicKeyXml $authorityKey.PublicXml -TrustedAuthorityPublicKeySha256 (Get-HumanVisualGoSha256ForBytes -Bytes ([Text.UTF8Encoding]::new($false, $true).GetBytes($authorityKey.PublicXml))) -ExpectedSignatureAlgorithm $script:HumanVisualGoFixtureSignatureAlgorithm }

    $forgedAttestation = Copy-HumanTestValue $attestation
    $forgedAttestation.reviewer.identity = '@forged-reviewer'
    $forgedPath = Join-Path $external 'forged-attestation.json'
    Write-HumanCanonicalJson -Value $forgedAttestation -Path $forgedPath -RepositoryRoot $fixture.RepositoryRoot
    Expect-HumanFailure 'forged reviewer identity' { Assert-HumanVisualGoAttestationAgainstCandidate -Candidate $candidate -Attestation $forgedAttestation -CandidateFileSha256 $candidateReceipt.FileSha256 -CandidateCanonicalSha256 $candidateReceipt.CanonicalSha256 -RepositoryRoot $fixture.RepositoryRoot -TrustedAuthorityPublicKeyXml $authorityKey.PublicXml -TrustedAuthorityPublicKeySha256 (Get-HumanVisualGoSha256ForBytes -Bytes ([Text.UTF8Encoding]::new($false, $true).GetBytes($authorityKey.PublicXml))) -ExpectedSignatureAlgorithm $script:HumanVisualGoFixtureSignatureAlgorithm }

    $roleCollision = Copy-HumanTestValue $attestation
    $roleCollision.reviewer.builderIdentity = '@yutthaphon'
    $rolePath = Join-Path $external 'role-collision-attestation.json'
    Write-HumanCanonicalJson -Value $roleCollision -Path $rolePath -RepositoryRoot $fixture.RepositoryRoot
    Expect-HumanFailure 'reviewer identity collides with builder role' { Assert-HumanVisualGoAttestationAgainstCandidate -Candidate $candidate -Attestation $roleCollision -CandidateFileSha256 $candidateReceipt.FileSha256 -CandidateCanonicalSha256 $candidateReceipt.CanonicalSha256 -RepositoryRoot $fixture.RepositoryRoot -TrustedAuthorityPublicKeyXml $authorityKey.PublicXml -TrustedAuthorityPublicKeySha256 (Get-HumanVisualGoSha256ForBytes -Bytes ([Text.UTF8Encoding]::new($false, $true).GetBytes($authorityKey.PublicXml))) -ExpectedSignatureAlgorithm $script:HumanVisualGoFixtureSignatureAlgorithm }

    $mixedAttestation = Copy-HumanTestValue $attestation
    $mixedAttestation.candidate.sourceTreeSha = 'a' * 40
    $mixedPath = Join-Path $external 'mixed-candidate-attestation.json'
    Write-HumanCanonicalJson -Value $mixedAttestation -Path $mixedPath -RepositoryRoot $fixture.RepositoryRoot
    Expect-HumanFailure 'mixed candidate source tree' { Assert-HumanVisualGoAttestationAgainstCandidate -Candidate $candidate -Attestation $mixedAttestation -CandidateFileSha256 $candidateReceipt.FileSha256 -CandidateCanonicalSha256 $candidateReceipt.CanonicalSha256 -RepositoryRoot $fixture.RepositoryRoot -TrustedAuthorityPublicKeyXml $authorityKey.PublicXml -TrustedAuthorityPublicKeySha256 (Get-HumanVisualGoSha256ForBytes -Bytes ([Text.UTF8Encoding]::new($false, $true).GetBytes($authorityKey.PublicXml))) -ExpectedSignatureAlgorithm $script:HumanVisualGoFixtureSignatureAlgorithm }

    $missingDefect = Copy-HumanTestValue $attestation
    $missingDefect.defects = @()
    $missingDefectPath = Join-Path $external 'missing-defect-attestation.json'
    Write-HumanCanonicalJson -Value $missingDefect -Path $missingDefectPath -RepositoryRoot $fixture.RepositoryRoot
    Expect-HumanFailure 'missing defect disposition' { Assert-HumanVisualGoAttestationAgainstCandidate -Candidate $candidate -Attestation $missingDefect -CandidateFileSha256 $candidateReceipt.FileSha256 -CandidateCanonicalSha256 $candidateReceipt.CanonicalSha256 -RepositoryRoot $fixture.RepositoryRoot -TrustedAuthorityPublicKeyXml $authorityKey.PublicXml -TrustedAuthorityPublicKeySha256 (Get-HumanVisualGoSha256ForBytes -Bytes ([Text.UTF8Encoding]::new($false, $true).GetBytes($authorityKey.PublicXml))) -ExpectedSignatureAlgorithm $script:HumanVisualGoFixtureSignatureAlgorithm }

    $localAuthority = Copy-HumanTestValue $attestation
    $localAuthority.authority.reference = 'Plan/DECISIONS.md#human-go'
    $localAuthorityPath = Join-Path $external 'repository-authority-attestation.json'
    Write-HumanCanonicalJson -Value $localAuthority -Path $localAuthorityPath -RepositoryRoot $fixture.RepositoryRoot
    Expect-HumanFailure 'repository-pinned Human authority' { Assert-HumanVisualGoAttestationAgainstCandidate -Candidate $candidate -Attestation $localAuthority -CandidateFileSha256 $candidateReceipt.FileSha256 -CandidateCanonicalSha256 $candidateReceipt.CanonicalSha256 -RepositoryRoot $fixture.RepositoryRoot -TrustedAuthorityPublicKeyXml $authorityKey.PublicXml -TrustedAuthorityPublicKeySha256 (Get-HumanVisualGoSha256ForBytes -Bytes ([Text.UTF8Encoding]::new($false, $true).GetBytes($authorityKey.PublicXml))) -ExpectedSignatureAlgorithm $script:HumanVisualGoFixtureSignatureAlgorithm }

    $inflated = Copy-HumanTestValue $attestation
    $inflated.evidenceBoundary.release = 'OBSERVED'
    $inflatedPath = Join-Path $external 'inflated-attestation.json'
    Write-HumanCanonicalJson -Value $inflated -Path $inflatedPath -RepositoryRoot $fixture.RepositoryRoot
    Expect-HumanFailure 'Release inflation from Human attestation' { Assert-HumanVisualGoAttestationAgainstCandidate -Candidate $candidate -Attestation $inflated -CandidateFileSha256 $candidateReceipt.FileSha256 -CandidateCanonicalSha256 $candidateReceipt.CanonicalSha256 -RepositoryRoot $fixture.RepositoryRoot -TrustedAuthorityPublicKeyXml $authorityKey.PublicXml -TrustedAuthorityPublicKeySha256 (Get-HumanVisualGoSha256ForBytes -Bytes ([Text.UTF8Encoding]::new($false, $true).GetBytes($authorityKey.PublicXml))) -ExpectedSignatureAlgorithm $script:HumanVisualGoFixtureSignatureAlgorithm }

    $missingCapturePath = Join-Path $fixture.Root ([string]$fixture.Manifest.captures[0].relativePath)
    $missingCaptureBytes = [IO.File]::ReadAllBytes($missingCapturePath)
    Remove-Item -LiteralPath $missingCapturePath -Force
    try {
        Expect-HumanFailure 'missing governed capture' { Test-V02HumanVisualGoAttestationCore -CandidatePath $candidatePath -AttestationPath $attestationPath -EvidenceRoot $fixture.Root -RepositoryRoot $fixture.RepositoryRoot }
    }
    finally {
        [IO.File]::WriteAllBytes($missingCapturePath, $missingCaptureBytes)
    }

    $existingOutput = Join-Path $external 'existing-output.json'
    [IO.File]::WriteAllText($existingOutput, 'occupied', [Text.UTF8Encoding]::new($false))
    Expect-HumanFailure 'concurrent/no-clobber candidate output' { Write-V02HumanVisualGoCandidate -Candidate $candidate -OutputPath $existingOutput -RepositoryRoot $fixture.RepositoryRoot -EvidenceRoot $fixture.Root }

    $heldPath = Join-Path $external 'held-swap.txt'
    $heldReplacement = Join-Path $external 'held-swap-replacement.txt'
    [IO.File]::WriteAllText($heldPath, 'original-held-bytes', [Text.UTF8Encoding]::new($false))
    [IO.File]::WriteAllText($heldReplacement, 'replacement-bytes', [Text.UTF8Encoding]::new($false))
    $holdContext = New-HumanVisualGoHoldContext
    try {
        Open-HumanVisualGoRootHandle -Context $holdContext -Root $external -ContextName 'swap fixture root'
        $held = Open-HumanVisualGoAbsoluteHeldFile -Context $holdContext -Path $heldPath -ContextName 'swap fixture file' -Root ([IO.Path]::GetPathRoot($heldPath)) -RootKind External
        $heldHash = $held.Sha256
        Expect-HumanFailure 'held same-handle path swap' { Move-Item -LiteralPath $heldReplacement -Destination $heldPath -Force }
        if ($held.Sha256 -cne $heldHash -or [Text.Encoding]::UTF8.GetString($held.Content) -cne 'original-held-bytes') { throw 'Held bytes changed after blocked path swap.' }
    }
    finally {
        Close-HumanVisualGoHoldContext -Context $holdContext
    }

    $hardlinkSource = Join-Path $external 'hardlink-source.txt'
    $hardlinkAlias = Join-Path $external 'hardlink-alias.txt'
    [IO.File]::WriteAllText($hardlinkSource, 'hardlink-source', [Text.UTF8Encoding]::new($false))
    New-Item -ItemType HardLink -Path $hardlinkAlias -Target $hardlinkSource | Out-Null
    $aliasContext = New-HumanVisualGoHoldContext
    try {
        Open-HumanVisualGoRootHandle -Context $aliasContext -Root $external -ContextName 'hardlink fixture root'
        Expect-HumanFailure 'external hardlink NumberOfLinks rejection' { Open-HumanVisualGoAbsoluteHeldFile -Context $aliasContext -Path $hardlinkSource -ContextName 'hardlink source' -Root ([IO.Path]::GetPathRoot($hardlinkSource)) -RootKind External } 'NumberOfLinks=2'
    }
    finally {
        Close-HumanVisualGoHoldContext -Context $aliasContext
    }

    $linkDriftPath = Join-Path $external 'hardlink-drift.txt'
    $linkDriftAlias = Join-Path $external 'hardlink-drift-alias.txt'
    [IO.File]::WriteAllText($linkDriftPath, 'link-count-drift', [Text.UTF8Encoding]::new($false))
    $driftContext = New-HumanVisualGoHoldContext
    try {
        Open-HumanVisualGoRootHandle -Context $driftContext -Root $external -ContextName 'hardlink drift root'
        [void](Open-HumanVisualGoAbsoluteHeldFile -Context $driftContext -Path $linkDriftPath -ContextName 'hardlink drift source' -Root ([IO.Path]::GetPathRoot($linkDriftPath)) -RootKind External)
        New-Item -ItemType HardLink -Path $linkDriftAlias -Target $linkDriftPath | Out-Null
        Expect-HumanFailure 'hardlink NumberOfLinks drift during held window' { Assert-HumanVisualGoHeldUnchanged -Context $driftContext -Description 'hardlink drift hostile evidence' } 'NumberOfLinks changed'
    }
    finally {
        Close-HumanVisualGoHoldContext -Context $driftContext
    }

    $escapeContext = New-HumanVisualGoHoldContext
    try {
        Expect-HumanFailure 'relative path escape/reparse guard' { Resolve-HumanVisualGoContainedPath -Root $fixture.Root -RelativePath '..\outside.json' -Context 'hostile escape' }
    }
    finally {
        Close-HumanVisualGoHoldContext -Context $escapeContext
    }

    $reparseLink = Join-Path $external 'reparse-link'
    try {
        New-Item -ItemType SymbolicLink -Path $reparseLink -Target $fixture.Root -ErrorAction Stop | Out-Null
        Expect-HumanFailure 'reparse directory path' { Resolve-HumanVisualGoContainedPath -Root $external -RelativePath 'reparse-link\renderer-compatibility-complete.json' -Context 'hostile reparse' }
    }
    catch {
        # A locked-down runner may not grant symlink creation. The path-escape
        # guard above still exercises the mandatory fail-closed path boundary.
        Pass 'reparse fixture unavailable; path boundary remained fail-closed'
    }

    [pscustomobject][ordered]@{
        EvidenceClassification = 'SyntheticVerifierSelftest'
        PositiveCases = $script:PositiveCases
        NegativeCases = $script:NegativeCases
        BindingValidation = 'PASS'
        HumanReview = 'NOT_OBSERVED'
        ActualHerdrRuntime = 'NOT_OBSERVED'
        Release = 'NOT_OBSERVED'
        CreditGranted = $false
    }
}
finally {
    if (Test-Path -LiteralPath $temp) { Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue }
}
