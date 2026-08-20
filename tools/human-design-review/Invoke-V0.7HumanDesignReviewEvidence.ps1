#requires -Version 5.1

[CmdletBinding()]
param(
    [string]$ReportPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'HumanDesignReview.Common.ps1')

$issue = Get-HumanDesignReviewIssue
$version = Get-HumanDesignReviewVersion

# SECTION 1: Static + Contract evidence for this issue. The distribution template
# and versioned schema are themselves deterministic artifacts; the schema is parsed
# to prove it is strict, well-formed JSON, and the template is verified to fail-closed
# (an unbound manifest cannot be accepted), crediting only PREPARATION/Static-Contract.

function Assert-HumanDesignReviewPreparedSchema {
    param([Parameter(Mandatory = $true)][string]$SchemaPath)

    $text = [IO.File]::ReadAllText($SchemaPath)
    $schema = ConvertFrom-StrictHumanDesignReviewJson -Json $text -Description "Schema '$SchemaPath'"
    if ([string]$schema.'$id' -cne (Get-HumanDesignReviewSchemaId)) {
        throw 'The versioned schema id does not match the authorized registry id.'
    }
    if ([string]$schema.type -cne 'object') {
        throw 'The versioned schema must declare a single object root instance type.'
    }
    if (-not ($schema.PSObject.Properties.Name -contains 'properties') -or
        -not ($schema.properties.PSObject.Properties.Name -contains 'schemaVersion') -or
        [int]$schema.properties.schemaVersion.const -ne 1) {
        throw 'The versioned schema must enforce a root schemaVersion value of 1.'
    }
    if ($schema.required -notcontains 'schemaVersion') {
        throw 'The versioned schema must require a root schemaVersion property.'
    }
}

function Get-HumanDesignReviewObservedGuard {
    param([Parameter(Mandatory = $true)][string]$Message)

    # Extract a stable, field-level guard token from the actual fail-closure message so
    # the report reflects the guard that truly tripped rather than a hardcoded label.
    if ($Message -match "reviewer '([^']+)' is (missing or placeholder|missing|placeholder|malformed)") {
        return ('reviewer:' + $Matches[1] + ':not-bound')
    }
    if ($Message -match "'([A-Za-z0-9_\.]+)' is (missing or placeholder|missing|placeholder|malformed)") {
        return ($Matches[1] + ':not-bound')
    }
    if ($Message -match '([a-zA-Z0-9 ]+) is (missing or placeholder|placeholder|malformed|unbound)') {
        return (($Matches[1] -replace '[\s]', ':').ToLowerInvariant() + ':fail-closed')
    }
    foreach ($known in @('unbound', 'placeholder', 'forged', 'missing', 'malformed')) {
        if ($Message.IndexOf($known, [StringComparison]::OrdinalIgnoreCase) -ge 0) {
            return $known
        }
    }
    return 'unknown-guard'
}

function Assert-HumanDesignReviewTemplateFailClosed {
    param([Parameter(Mandatory = $true)][string]$TemplatePath)

    $failClosureMessage = $null
    try {
        Test-HumanDesignReviewManifest -ManifestPath $TemplatePath | Out-Null
    } catch {
        $failClosureMessage = [string]$_.Exception.Message
    }
    if ([string]::IsNullOrWhiteSpace($failClosureMessage)) {
        throw 'The distribution template is fail-open: it must never verify as an accepted manifest.'
    }
    $guardMatched = @('unbound', 'placeholder', 'forged', 'missing', 'malformed') |
        Where-Object { $failClosureMessage.IndexOf($_, [StringComparison]::OrdinalIgnoreCase) -ge 0 }
    if ($guardMatched.Count -eq 0) {
        throw "The distribution template did not fail on a recognized fail-closed guard: $failClosureMessage"
    }
    $observedGuard = Get-HumanDesignReviewObservedGuard -Message $failClosureMessage
    return [pscustomobject][ordered]@{
        Message = $failClosureMessage
        Guard = $observedGuard
    }
}

$schemaPath = Get-HumanDesignReviewSchemaPath
$templatePath = Get-HumanDesignReviewTemplatePath
Assert-HumanDesignReviewPreparedSchema -SchemaPath $schemaPath
$templateFailure = Assert-HumanDesignReviewTemplateFailClosed -TemplatePath $templatePath

$schemaText = [IO.File]::ReadAllText($schemaPath)
$templateText = [IO.File]::ReadAllText($templatePath)
$schemaHash = Get-HumanDesignReviewSha256ForText -Text $schemaText
$templateHash = Get-HumanDesignReviewSha256ForText -Text $templateText

$report = [pscustomobject][ordered]@{
    issue = $issue
    version = $version
    component = 'human-design-review'
    evidenceClass = 'PREPARATION/Static-Contract-Synthetic'
    human = 'NOT OBSERVED'
    runtime = 'NOT OBSERVED'
    release = 'NOT OBSERVED'
    generatedBy = [Environment]::UserName
    generatedAtUtc = [DateTime]::UtcNow.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ss', [Globalization.CultureInfo]::InvariantCulture) + 'Z'
    hosts = @(
        [ordered]@{
            name = if ($PSVersionTable.PSEdition -eq 'Core') { 'PowerShell 7' } else { 'Windows PowerShell' }
            edition = [string]$PSVersionTable.PSEdition
            version = [string]$PSVersionTable.PSVersion
        }
    )
    schema = [ordered]@{
        path = [string]$schemaPath
        sha256 = $schemaHash
        digestOrigin = 'self-reported by the tool SHA-256 function on the committed file bytes'
        digestVerifiedIndependent = $false
        conformsToStrictJson = $true
    }
    template = [ordered]@{
        path = [string]$templatePath
        sha256 = $templateHash
        digestOrigin = 'self-reported by the tool SHA-256 function on the committed file bytes'
        digestVerifiedIndependent = $false
        failClosedOnUnbound = $true
        observedGuardFragments = @($templateFailure.Guard)
        observedGuardFromMessage = [string]$templateFailure.Message
    }
    preparedArtifacts = @(
        [ordered]@{ relativePath = 'tools/human-design-review/human-design-review.schema.json'; kind = 'schema' }
        [ordered]@{ relativePath = 'tools/human-design-review/human-design-review.template.json'; kind = 'template' }
        [ordered]@{ relativePath = 'tools/human-design-review/HumanDesignReview.Common.ps1'; kind = 'verifier core' }
        [ordered]@{ relativePath = 'tools/human-design-review/Test-V0.7HumanDesignReviewVerifier.ps1'; kind = 'manifest verifier' }
        [ordered]@{ relativePath = 'tools/human-design-review/Test-V0.7HumanDesignReviewSelftests.ps1'; kind = 'deterministic selftest' }
        [ordered]@{ relativePath = 'tools/human-design-review/Invoke-V0.7HumanDesignReviewEvidence.ps1'; kind = 'preparation evidence driver' }
    )
}

if ($ReportPath) {
    $fullReportPath = [IO.Path]::GetFullPath($ReportPath)
    $parent = Split-Path -Path $fullReportPath -Parent
    if (-not [string]::IsNullOrWhiteSpace($parent) -and -not (Test-Path -LiteralPath $parent -PathType Container)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }
    $json = $report | ConvertTo-Json -Depth 20
    [IO.File]::WriteAllText($fullReportPath, $json, (New-Object System.Text.UTF8Encoding($false)))
    Write-Output $fullReportPath
} else {
    $report | ConvertTo-Json -Depth 20
}