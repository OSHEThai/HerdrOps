# Shared provenance/validation helpers for v0.3 actual-Herdr runtime capture harnesses
# (Issues #15 and #16). Deliberately written for both Windows PowerShell 5.1 and PowerShell 7:
# no ternary (?:), null-coalescing (??/??=), or other PS7-only operators.

function Get-CleanSourceCommit {
    param(
        [Parameter(Mandatory = $true)]
        [string]$RepositoryRoot
    )

    $commitOutput = @(& git -C $RepositoryRoot rev-parse HEAD)
    $commit = ($commitOutput -join '').Trim()
    if ($LASTEXITCODE -ne 0 -or $commit -notmatch '^[0-9a-f]{40}$') {
        throw 'SourceCommitResolutionFailed: could not resolve the source commit for the runtime capture harness.'
    }

    $changes = @(& git -C $RepositoryRoot status --porcelain=v1 --untracked-files=all)
    if ($LASTEXITCODE -ne 0) {
        throw 'WorkingTreeInspectionFailed: could not inspect the repository status.'
    }

    if ($changes.Count -ne 0) {
        throw "WorkingTreeDirty: runtime capture requires a clean source checkout. Changes: $($changes -join '; ')"
    }

    return $commit
}

function Test-IsAdministrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Get-ControlHerdrServerIdentity {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ExpectedExecutablePath
    )

    if (-not (Test-Path -LiteralPath $ExpectedExecutablePath -PathType Leaf)) {
        throw "AuthorizedHerdrExecutableNotFound: $ExpectedExecutablePath"
    }

    $expectedPath = (Resolve-Path -LiteralPath $ExpectedExecutablePath).Path
    $currentProcessId = [int]$PID
    for ($depth = 0; $depth -lt 32; $depth++) {
        $processInfo = @(Get-CimInstance -ClassName Win32_Process -Filter "ProcessId = $currentProcessId")
        if ($processInfo.Count -ne 1) {
            break
        }

        $candidate = $processInfo[0]
        $candidatePath = [string]$candidate.ExecutablePath
        $candidateCommandLine = [string]$candidate.CommandLine
        if (-not [string]::IsNullOrWhiteSpace($candidatePath) -and
            [IO.Path]::GetFileName($candidatePath) -eq 'herdr.exe' -and
            $candidateCommandLine -match '(?:^|\s)server(?:\s|$)') {
            $resolvedCandidatePath = (Resolve-Path -LiteralPath $candidatePath).Path
            if (-not [StringComparer]::OrdinalIgnoreCase.Equals($resolvedCandidatePath, $expectedPath)) {
                throw "UnexpectedHerdrExecutable: the control pane belongs to an unexpected Herdr executable: $resolvedCandidatePath"
            }

            $runtimeProcess = Get-Process -Id ([int]$candidate.ProcessId) -ErrorAction Stop
            return [pscustomobject]@{
                ProcessId        = [int]$candidate.ProcessId
                ProcessStartUtc  = $runtimeProcess.StartTime.ToUniversalTime()
                ExecutablePath   = $resolvedCandidatePath
                ExecutableSha256 = (Get-FileHash -LiteralPath $resolvedCandidatePath -Algorithm SHA256).Hash
            }
        }

        $parentProcessId = [int]$candidate.ParentProcessId
        if ($parentProcessId -le 0 -or $parentProcessId -eq $currentProcessId) {
            break
        }

        $currentProcessId = $parentProcessId
    }

    throw 'NotAnAuthorizedHerdrSession: this process is not descended from a live Herdr server. Run it directly in an authorized Herdr pane with HERDR_ENV=1.'
}

function Get-TextSha256 {
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string]$Text
    )

    $sha256 = [Security.Cryptography.SHA256]::Create()
    try {
        $bytes = [Text.Encoding]::UTF8.GetBytes($Text)
        return ([BitConverter]::ToString($sha256.ComputeHash($bytes))).Replace('-', '').ToUpperInvariant()
    }
    finally {
        $sha256.Dispose()
    }
}

function Get-JsonPropertyValue {
    # ConvertFrom-Json objects throw under Set-StrictMode when a property is absent, instead of
    # returning $null like a hashtable would. This centralizes safe, StrictMode-safe lookups.
    param(
        [Parameter(Mandatory = $true)]
        [AllowNull()]
        $Object,

        [Parameter(Mandatory = $true)]
        [string]$Name
    )

    if ($null -eq $Object) {
        return $null
    }

    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property) {
        return $null
    }

    return $property.Value
}

function Get-FileSha256IfExists {
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string]$Path
    )

    if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return 'MISSING'
    }

    try {
        return ((Get-FileHash -LiteralPath $Path -Algorithm SHA256 -ErrorAction Stop).Hash).ToUpperInvariant()
    }
    catch {
        return 'UNAVAILABLE'
    }
}

<#
.SYNOPSIS
Validates one runtime-capture JSON report and fails closed on synthetic, missing, stale, or
wrong-session evidence. Shared by the Issue #15 and Issue #16 operator harnesses (and by their
hostile selftests) so both issues enforce identical evidence discipline.
#>
function Assert-RuntimeCaptureReport {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ReportPath,

        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [string[]]$RequiredTrueFields,

        [Parameter(Mandatory = $true)]
        [DateTime]$NotBeforeUtc,

        [Parameter(Mandatory = $true)]
        [string]$ExpectedExecutableSha256
    )

    if (-not (Test-Path -LiteralPath $ReportPath -PathType Leaf)) {
        throw "MissingEvidence: runtime capture report was not found: $ReportPath"
    }

    $item = Get-Item -LiteralPath $ReportPath
    $notBeforeUtcNormalized = $NotBeforeUtc.ToUniversalTime()
    if ($item.LastWriteTimeUtc -lt $notBeforeUtcNormalized) {
        throw "StaleEvidence: runtime capture report predates this run and may be reused from a prior run: $ReportPath (LastWriteTimeUtc=$($item.LastWriteTimeUtc.ToString('O')), NotBeforeUtc=$($notBeforeUtcNormalized.ToString('O')))"
    }

    $raw = Get-Content -LiteralPath $ReportPath -Raw -ErrorAction Stop
    if ([string]::IsNullOrWhiteSpace($raw)) {
        throw "MissingEvidence: runtime capture report is empty: $ReportPath"
    }

    try {
        $reportObject = $raw | ConvertFrom-Json -ErrorAction Stop
    }
    catch {
        throw "SyntheticEvidence: runtime capture report is not valid JSON: $ReportPath"
    }

    $evidenceClassification = Get-JsonPropertyValue -Object $reportObject -Name 'evidenceClassification'
    if ([string]$evidenceClassification -ne 'Runtime') {
        throw "SyntheticEvidence: runtime capture report evidenceClassification is not Runtime (found '$([string]$evidenceClassification)')."
    }

    $sessionControlInvoked = Get-JsonPropertyValue -Object $reportObject -Name 'sessionControlInvoked'
    if ($null -eq $sessionControlInvoked -or $sessionControlInvoked -ne $false) {
        throw 'SyntheticEvidence: runtime capture report does not affirmatively claim sessionControlInvoked=false.'
    }

    $runtimeObserved = Get-JsonPropertyValue -Object $reportObject -Name 'runtimeObserved'
    if ($null -eq $runtimeObserved -or $runtimeObserved -ne $true) {
        throw 'SyntheticEvidence: runtime capture report does not claim runtimeObserved=true.'
    }

    foreach ($field in $RequiredTrueFields) {
        $value = Get-JsonPropertyValue -Object $reportObject -Name $field
        if ($null -eq $value -or $value -ne $true) {
            throw "SyntheticEvidence: required runtime field '$field' is not true."
        }
    }

    $admission = Get-JsonPropertyValue -Object $reportObject -Name 'admission'
    $admissionExecutableSha256 = Get-JsonPropertyValue -Object $admission -Name 'executableSha256'
    if ($null -eq $admission -or [string]::IsNullOrWhiteSpace([string]$admissionExecutableSha256)) {
        throw 'MissingEvidence: runtime capture report omits admission executableSha256.'
    }

    if (-not [string]::Equals([string]$admissionExecutableSha256, $ExpectedExecutableSha256, [StringComparison]::OrdinalIgnoreCase)) {
        throw "WrongSessionEvidence: runtime capture report admission executableSha256 does not match the verified control session (report=$([string]$admissionExecutableSha256), control=$ExpectedExecutableSha256)."
    }

    $monitorIdentity = Get-JsonPropertyValue -Object $reportObject -Name 'monitorServerIdentity'
    $monitorExecutableSha256 = Get-JsonPropertyValue -Object $monitorIdentity -Name 'executableSha256'
    if ($null -ne $monitorIdentity -and -not [string]::IsNullOrWhiteSpace([string]$monitorExecutableSha256)) {
        if (-not [string]::Equals([string]$monitorExecutableSha256, $ExpectedExecutableSha256, [StringComparison]::OrdinalIgnoreCase)) {
            throw 'WrongSessionEvidence: runtime capture report monitor server identity does not match the verified control session.'
        }
    }

    return $reportObject
}

function Assert-NotReplayedTranscript {
    param(
        [Parameter(Mandatory = $true)]
        [string]$LedgerPath,

        [Parameter(Mandatory = $true)]
        [string]$TranscriptSha256
    )

    if (Test-Path -LiteralPath $LedgerPath -PathType Leaf) {
        $existing = @(Get-Content -LiteralPath $LedgerPath -ErrorAction SilentlyContinue)
        if ($existing -contains $TranscriptSha256) {
            throw "ReplayedEvidence: raw transcript SHA-256 $TranscriptSha256 is already recorded in the ledger and cannot be reused as fresh evidence: $LedgerPath"
        }
    }
}

function Add-TranscriptLedgerEntry {
    param(
        [Parameter(Mandatory = $true)]
        [string]$LedgerPath,

        [Parameter(Mandatory = $true)]
        [string]$TranscriptSha256
    )

    $parent = Split-Path -Parent $LedgerPath
    if (-not [string]::IsNullOrWhiteSpace($parent)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }

    Add-Content -LiteralPath $LedgerPath -Value $TranscriptSha256 -Encoding utf8
}

function Write-RuntimeCaptureFailureReport {
    param(
        [Parameter(Mandatory = $true)]
        [string]$GateReportPath,

        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string]$SourceCommit,

        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string]$FailureMessage
    )

    try {
        $parentDirectory = Split-Path -Parent $GateReportPath
        if (-not [string]::IsNullOrWhiteSpace($parentDirectory)) {
            New-Item -ItemType Directory -Path $parentDirectory -Force -ErrorAction SilentlyContinue | Out-Null
        }

        $reportLines = @(
            'Result: FAIL',
            'EvidenceClass: NoRuntimeCredit',
            'SessionControlInvoked: false',
            "GeneratedUtc: $([DateTimeOffset]::UtcNow.ToString('O'))",
            "SourceCommit: $SourceCommit",
            "Failure: $FailureMessage"
        )
        $reportLines | Set-Content -LiteralPath $GateReportPath -Encoding utf8 -ErrorAction Stop
    }
    catch {
        Write-Warning "Could not write failure gate report '$GateReportPath': $($_.Exception.Message)"
    }
}
