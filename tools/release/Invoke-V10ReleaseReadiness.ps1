#requires -Version 5.1

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$AuthorizationPath,
    [string]$OutputPath,
    [string]$ProfilePath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'V10Release.Common.ps1')

$repositoryRoot = Get-V10RepositoryRoot
if ([string]::IsNullOrWhiteSpace($ProfilePath)) {
    $ProfilePath = Join-Path $PSScriptRoot 'v1.0-package-profile.json'
}

$authorizationPreview = Read-V10StrictJsonFile -Path $AuthorizationPath -Description 'v1 release authorization'
$acceptedCommit = [string](Get-V10RequiredProperty -Object $authorizationPreview.Value -Name 'acceptedCommit' -Description 'v1 release authorization')
Assert-V10Hex -Value $acceptedCommit -Length 40 -Description 'accepted release commit' -Lowercase
$git = Get-V10GitIdentity -RepositoryRoot $repositoryRoot -ExpectedCommit $acceptedCommit -RequireClean
$readiness = Assert-V10ReleaseAuthorization `
    -AuthorizationPath $AuthorizationPath `
    -RepositoryRoot $repositoryRoot `
    -ExpectedSourceCommit $acceptedCommit `
    -ProfilePath $ProfilePath

if ([string]::IsNullOrWhiteSpace($OutputPath)) {
    $runId = [Guid]::NewGuid().ToString('N')
    $OutputPath = Join-Path $repositoryRoot "artifacts\release-readiness\v1.0.0\$runId\readiness.json"
} elseif (-not [IO.Path]::IsPathRooted($OutputPath)) {
    $OutputPath = Join-Path $repositoryRoot $OutputPath
}
$safeOutput = Assert-SafeDestination -Path $OutputPath -AllowRepositoryChild -AllowTempChild
$requiredRoot = Normalize-ComparablePath -Path (Join-Path $repositoryRoot 'artifacts\release-readiness\v1.0.0')
if (-not (Test-PathWithin -ChildPath $safeOutput -RootPath $requiredRoot) -or
    $safeOutput.Equals($requiredRoot, [StringComparison]::OrdinalIgnoreCase)) {
    throw "Release-readiness output must be a new JSON file below '$requiredRoot'."
}
if ([IO.Path]::GetExtension($safeOutput) -cne '.json') {
    throw 'Release-readiness output must use the .json extension.'
}

$report = [ordered]@{
    schemaVersion = 1
    reportKind = 'HerdrOps.ReleaseReadiness'
    issue = 45
    releaseVersion = 'v1.0.0'
    status = 'READY_TO_PUBLISH'
    evidenceClass = 'Static'
    checkedAtUtc = [DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ss.fffffffZ', [Globalization.CultureInfo]::InvariantCulture)
    sourceCommit = $readiness.AcceptedCommit
    workingTree = $git.WorkingTree
    authorization = [ordered]@{
        path = [IO.Path]::GetFullPath($readiness.AuthorizationPath)
        sha256 = $readiness.AuthorizationSha256
    }
    candidate = [ordered]@{
        recordPath = [IO.Path]::GetFullPath($readiness.Candidate.RecordPath)
        recordSha256 = $readiness.Candidate.RecordSha256
        archivePath = [IO.Path]::GetFullPath($readiness.Candidate.ArchivePath)
        archiveBytes = [int64]$readiness.Candidate.ArchiveBytes
        archiveSha256 = $readiness.Candidate.ArchiveSha256
        hashRecordPath = [IO.Path]::GetFullPath($readiness.Candidate.HashRecordPath)
        hashRecordSha256 = ((Get-FileHash -LiteralPath $readiness.Candidate.HashRecordPath -Algorithm SHA256).Hash).ToUpperInvariant()
    }
    gates = @($readiness.Gates | ForEach-Object {
            [ordered]@{
                issue = [int]$_.Issue
                evidenceClass = [string]$_.EvidenceClass
                reportPath = [IO.Path]::GetFullPath([string]$_.ReportPath)
                reportSha256 = [string]$_.ReportSha256
            }
        })
    goNoGo = [ordered]@{
        decision = $readiness.Decision
        approver = $readiness.Approver
        approvedAtUtc = $readiness.ApprovedAtUtc
    }
    releaseNotes = [ordered]@{
        path = [IO.Path]::GetFullPath($readiness.ReleaseNotesPath)
        sha256 = $readiness.ReleaseNotesSha256
    }
    publication = [ordered]@{
        status = 'NOT_PUBLISHED'
        tag = 'NOT_CREATED'
        releaseUrl = ''
    }
    boundaries = [ordered]@{
        static = 'PASS'
        synthetic = 'NOT OBSERVED BY THIS INVOCATION'
        contract = 'OBSERVED ONLY IN BOUND REPORTS'
        cleanMachine = 'OBSERVED ONLY IN BOUND REPORT #44'
        runtime = 'OBSERVED ONLY IN BOUND REPORT #42'
        independentReview = 'OBSERVED ONLY IN BOUND REPORT #43'
        human = 'OBSERVED ONLY IN BOUND AUTHORIZATION'
        release = 'NOT OBSERVED'
    }
}

$written = Write-V10NewJsonFile -Path $safeOutput -Value $report
$writtenFile = Get-Item -LiteralPath $written -Force
[pscustomobject][ordered]@{
    Status = 'READY_TO_PUBLISH'
    EvidenceClass = 'Static'
    SourceCommit = $readiness.AcceptedCommit
    CandidateArchiveSha256 = $readiness.Candidate.ArchiveSha256
    AuthorizationSha256 = $readiness.AuthorizationSha256
    ReadinessReportPath = $writtenFile.FullName
    ReadinessReportSha256 = ((Get-FileHash -LiteralPath $writtenFile.FullName -Algorithm SHA256).Hash).ToUpperInvariant()
    GitHubTag = 'NOT CREATED'
    GitHubRelease = 'NOT PUBLISHED'
    Release = 'NOT OBSERVED'
}
