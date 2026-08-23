#requires -Version 5.1

[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-V02ReleaseVerifierSha256 {
    param([Parameter(Mandatory = $true)][byte[]]$Bytes)
    $algorithm = [Security.Cryptography.SHA256]::Create()
    try { return ([BitConverter]::ToString($algorithm.ComputeHash($Bytes))).Replace('-', '').ToUpperInvariant() }
    finally { $algorithm.Dispose() }
}

function Assert-V02ReleaseVerifierEqual {
    param($Actual, $Expected, [Parameter(Mandatory = $true)][string]$Context)
    if ([string]$Actual -cne [string]$Expected) {
        throw "$Context mismatch. Expected='$Expected' Actual='$Actual'."
    }
}

try {
    $requestPath = [Environment]::GetEnvironmentVariable('HERDROPS_V02_RELEASE_VERIFY_REQUEST', 'Process')
    $expectedRequestSha256 = [Environment]::GetEnvironmentVariable('HERDROPS_V02_RELEASE_VERIFY_REQUEST_SHA256', 'Process')
    if ([string]::IsNullOrWhiteSpace($requestPath) -or $expectedRequestSha256 -cnotmatch '^[0-9A-F]{64}$') {
        throw 'The isolated CleanMachine verifier request binding is missing or malformed.'
    }

    $requestFull = [IO.Path]::GetFullPath($requestPath)
    $requestBytes = [IO.File]::ReadAllBytes($requestFull)
    $requestSha256 = Get-V02ReleaseVerifierSha256 -Bytes $requestBytes
    Assert-V02ReleaseVerifierEqual $requestSha256 $expectedRequestSha256 'Isolated verifier request SHA-256'
    $requestText = (New-Object Text.UTF8Encoding($false, $true)).GetString($requestBytes)
    $request = if ((Get-Command ConvertFrom-Json).Parameters.ContainsKey('DateKind')) {
        $requestText | ConvertFrom-Json -DateKind String
    } else { $requestText | ConvertFrom-Json }
    $required = @('reportPath','authorizationPath','authorizationSignaturePath','acceptanceReceiptPath','acceptanceReceiptSignaturePath','expectedSourceCommit','expectedSourceTree','engineSha256','verifierSha256','commonSha256','packagingCommonSha256','packageIdentityCommonSha256','reportSha256','authorizationSha256','authorizationSignatureSha256','acceptanceReceiptSha256','acceptanceReceiptSignatureSha256','package')
    $actual = @($request.PSObject.Properties.Name)
    if ($actual.Count -ne $required.Count -or @($actual | Where-Object { $required -cnotcontains $_ }).Count -ne 0) {
        throw 'The isolated CleanMachine verifier request has unexpected or missing properties.'
    }

    $commonPath = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot 'V02CleanMachine.Common.ps1'))
    $packagingCommonPath = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot 'V02Packaging.Common.ps1'))
    $packageIdentityCommonPath = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot 'V02PackageIdentity.Common.ps1'))
    $repositoryRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..\..'))
    $engineSha256 = Get-V02ReleaseVerifierSha256 -Bytes ([IO.File]::ReadAllBytes([IO.Path]::GetFullPath([Diagnostics.Process]::GetCurrentProcess().MainModule.FileName)))
    $verifierSha256 = Get-V02ReleaseVerifierSha256 -Bytes ([IO.File]::ReadAllBytes([IO.Path]::GetFullPath($PSCommandPath)))
    $commonSha256 = Get-V02ReleaseVerifierSha256 -Bytes ([IO.File]::ReadAllBytes($commonPath))
    $packagingCommonSha256 = Get-V02ReleaseVerifierSha256 -Bytes ([IO.File]::ReadAllBytes($packagingCommonPath))
    $packageIdentityCommonSha256 = Get-V02ReleaseVerifierSha256 -Bytes ([IO.File]::ReadAllBytes($packageIdentityCommonPath))
    Assert-V02ReleaseVerifierEqual $engineSha256 $request.engineSha256 'Isolated PowerShell executable SHA-256'
    Assert-V02ReleaseVerifierEqual $verifierSha256 $request.verifierSha256 'Isolated verifier source SHA-256'
    Assert-V02ReleaseVerifierEqual $commonSha256 $request.commonSha256 'CleanMachine common verifier SHA-256'
    Assert-V02ReleaseVerifierEqual $packagingCommonSha256 $request.packagingCommonSha256 'V02 packaging common SHA-256'
    Assert-V02ReleaseVerifierEqual $packageIdentityCommonSha256 $request.packageIdentityCommonSha256 'V02 package identity common SHA-256'
    . $commonPath

    $childProcess = [Diagnostics.Process]::GetCurrentProcess()
    $childStartUtc = $childProcess.StartTime.ToUniversalTime().ToString('O', [Globalization.CultureInfo]::InvariantCulture)
    $enginePath = [IO.Path]::GetFullPath($childProcess.MainModule.FileName)
    $engineStream = [IO.File]::Open($enginePath,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read)
    try { $engineIdentity = Get-V02HandleIdentity -Handle $engineStream.SafeFileHandle -Context 'Isolated PowerShell executable' }
    finally { $engineStream.Dispose() }

    $reportBytes = [IO.File]::ReadAllBytes([IO.Path]::GetFullPath([string]$request.reportPath))
    $reportSha256 = Get-V02ReleaseVerifierSha256 -Bytes $reportBytes
    Assert-V02ReleaseVerifierEqual $reportSha256 $request.reportSha256 'CleanMachine report held-input SHA-256'
    $reportText = (New-Object Text.UTF8Encoding($false, $true)).GetString($reportBytes)
    $report = if ((Get-Command ConvertFrom-Json).Parameters.ContainsKey('DateKind')) {
        $reportText | ConvertFrom-Json -DateKind String
    } else { $reportText | ConvertFrom-Json }
    Assert-V02CleanMachineReportSchema -Report $report -RepositoryRoot $repositoryRoot

    if ([string]$report.status -cne 'PASS') { throw 'Clean-machine report status must be PASS.' }
    if ([string]$report.mode -cne 'Live') { throw 'Clean-machine report mode must be Live.' }
    if ([string]$report.evidenceBoundary.evidenceClass -cne 'CleanMachine') { throw 'Clean-machine evidence class must be CleanMachine.' }
    if ([bool]$report.evidenceBoundary.creditGranted -ne $true) { throw 'Clean-machine lifecycle credit must be granted.' }
    foreach ($phase in @('initial','final')) {
        $binding = $report.bindings.$phase
        foreach ($pair in @(
                @($binding.sourceCommit,$request.expectedSourceCommit,"$phase.sourceCommit"),
                @($binding.sourceTree,$request.expectedSourceTree,"$phase.sourceTree"),
                @($binding.receiptSha256,$request.package.receiptSha256,"$phase.receiptSha256"),
                @($binding.archiveSha256,$request.package.archiveSha256,"$phase.archiveSha256"),
                @($binding.packageManifestSha256,$request.package.manifestSha256,"$phase.packageManifestSha256"),
                @($binding.appSha256,$request.package.appSha256,"$phase.appSha256"),
                @($binding.coreSha256,$request.package.coreSha256,"$phase.coreSha256"))) {
            Assert-V02ReleaseVerifierEqual $pair[0] $pair[1] "Clean-machine $($pair[2])"
        }
    }
    Assert-V02ReleaseVerifierEqual $report.profileId $request.package.profileId 'Clean-machine package profile'
    Assert-V02ReleaseVerifierEqual $report.bindings.referenceHostProfileSha256 $request.package.referenceHostProfileSha256 'Clean-machine reference-host profile'
    Assert-V02ReleaseVerifierEqual $report.bindings.rendererPolicySha256 $request.package.rendererPolicySha256 'Clean-machine renderer policy'

    if ([string]::IsNullOrWhiteSpace([string]$request.authorizationPath) -or
        [string]::IsNullOrWhiteSpace([string]$request.authorizationSignaturePath)) {
        throw 'Clean-machine Live PASS requires the external authorization JSON and detached CMS signature bytes.'
    }
    $completedAtUtc = [DateTimeOffset]::ParseExact([string]$report.completedAtUtc, 'o', [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind)
    $authorization = Read-V02CleanHostAuthorization `
        -AuthorizationPath ([string]$request.authorizationPath) `
        -SignaturePath ([string]$request.authorizationSignaturePath) `
        -MachineName ([string]$report.machine.machineName) `
        -MachineFingerprint ([string]$report.machine.machineFingerprint) `
        -PrincipalSid ([string]$report.machine.userScope) `
        -InstallRoot ([string]$report.targets.installRoot) `
        -UserDataRoot ([string]$report.targets.userDataRoot) `
        -InitialBinding $report.bindings.initial -FinalBinding $report.bindings.final `
        -VerificationTimeUtc $completedAtUtc
    Assert-V02ReleaseVerifierEqual $authorization.AuthorizationSha256 $request.authorizationSha256 'CleanMachine authorization held-input SHA-256'
    Assert-V02ReleaseVerifierEqual $authorization.SignatureSha256 $request.authorizationSignatureSha256 'CleanMachine authorization signature held-input SHA-256'
    Assert-V02ReleaseVerifierEqual $report.actor.operator.identity $report.machine.userScope 'Clean-machine operator/principal binding'
    Assert-V02ReleaseVerifierEqual $report.actor.observer.identity $authorization.Value.observerIdentity 'Clean-machine observer authorization binding'
    Assert-V02ReleaseVerifierEqual $report.actor.authorization.signerThumbprint $authorization.SignerThumbprint 'Clean-machine authorization signer thumbprint'
    Assert-V02ReleaseVerifierEqual $report.actor.authorization.authorizationSha256 $authorization.AuthorizationSha256 'Clean-machine authorization file hash'
    Assert-V02ReleaseVerifierEqual $report.actor.authorization.signatureSha256 $authorization.SignatureSha256 'Clean-machine authorization signature hash'
    Assert-V02ReleaseVerifierEqual $report.actor.authorization.nonce $authorization.Value.nonce 'Clean-machine authorization nonce'

    if ([string]::IsNullOrWhiteSpace([string]$request.acceptanceReceiptPath) -or
        [string]::IsNullOrWhiteSpace([string]$request.acceptanceReceiptSignaturePath)) {
        throw 'Clean-machine Live PASS requires the post-run observer acceptance receipt JSON and detached CMS signature bytes.'
    }

    $acceptanceReceipt = Read-V02CleanHostAcceptanceReceipt `
        -ReceiptPath ([string]$request.acceptanceReceiptPath) `
        -SignaturePath ([string]$request.acceptanceReceiptSignaturePath) `
        -ReportSha256 $reportSha256 -Report $report -Authorization $authorization
    Assert-V02ReleaseVerifierEqual $acceptanceReceipt.ReceiptSha256 $request.acceptanceReceiptSha256 'CleanMachine acceptance receipt held-input SHA-256'
    Assert-V02ReleaseVerifierEqual $acceptanceReceipt.SignatureSha256 $request.acceptanceReceiptSignatureSha256 'CleanMachine acceptance receipt signature held-input SHA-256'

    $result = [pscustomobject][ordered]@{
        protocol = 'HerdrOps.V02IsolatedCleanMachineVerifierResult'
        version = 1
        requestSha256 = $requestSha256
        engineSha256 = $engineSha256
        verifierSha256 = $verifierSha256
        commonSha256 = $commonSha256
        packagingCommonSha256 = $packagingCommonSha256
        packageIdentityCommonSha256 = $packageIdentityCommonSha256
        reportSha256 = $reportSha256
        authorizationSha256 = [string]$authorization.AuthorizationSha256
        authorizationSignatureSha256 = [string]$authorization.SignatureSha256
        childPid = [int]$PID
        childStartUtc = $childStartUtc
        engineFinalPath = [string]$engineIdentity.FinalPath
        engineVolumeSerialNumber = [string]$engineIdentity.VolumeSerialNumber
        engineFileId = [string]$engineIdentity.FileId
        runId = [string]$report.runId
        machineFingerprint = [string]$report.machine.machineFingerprint
        operatorIdentity = [string]$report.actor.operator.identity
        observerIdentity = [string]$report.actor.observer.identity
        authorizationSignerThumbprint = [string]$report.actor.authorization.signerThumbprint
        acceptanceReceiptSha256 = [string]$acceptanceReceipt.ReceiptSha256
        acceptanceReceiptSignatureSha256 = [string]$acceptanceReceipt.SignatureSha256
        acceptanceReceiptNonce = [string]$acceptanceReceipt.Value.receiptNonce
    }
    # Canonical ordered JSON binds both property names and values without the
    # delimiter ambiguity of a value-only joined string.
    $resultBindingText = $result | ConvertTo-Json -Compress -Depth 8
    $result | Add-Member -NotePropertyName resultBindingSha256 -NotePropertyValue (Get-V02ReleaseVerifierSha256 -Bytes ([Text.Encoding]::UTF8.GetBytes($resultBindingText)))
    $result | ConvertTo-Json -Compress -Depth 8
    exit 0
}
catch {
    [Console]::Error.WriteLine($_.Exception.Message)
    exit 1
}
