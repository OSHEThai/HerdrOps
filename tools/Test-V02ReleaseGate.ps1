#requires -Version 5.1

[CmdletBinding()]
param(
    [string]$ExpectedSourceCommit,
    [string]$ExpectedSourceTree,
    [string]$PackageIdentityPath,
    [string]$PackageArchivePath,
    [string]$ExtractedPackageRoot,
    [string]$PackageProfilePath,
    [string]$RendererManifestPath,
    [string]$ThaiEvidenceDirectory,
    [string]$EnglishEvidenceDirectory,
    [string]$RuntimeMatrixManifestPath,
    [string]$Issue9CandidatePath,
    [string]$ContractEvidencePath,
    [string]$SyntheticEvidencePath,
    [string]$HumanReviewPath,
    [string]$CleanMachineReportPath,
    [string]$CleanHostAuthorizationPath,
    [string]$CleanHostAuthorizationSignaturePath,
    [string]$CleanHostAcceptanceReceiptPath,
    [string]$CleanHostAcceptanceReceiptSignaturePath,
    [string]$GitHubSnapshotPath,
    [string]$CandidateLockPath,
    [string]$AuthorityReferencePath,
    [string]$IndependentCandidateReceiptPath,
    [string]$EvidenceRoot,
    [string]$RepositoryRoot,
    [string]$RendererEvidenceRoot,
    [string]$OutputPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:V02ReleaseGateVersion = 'v0.2.0'
$script:V02ReleaseGateMilestoneNumber = 2
$script:V02ReleaseGateTrackerIssue = 11
$script:V02ReleaseGateExpectedMilestoneIssues = @(6, 7, 8, 9, 10, 11, 54, 63)
$script:V02ReleaseGateRequiredIssues = @(7, 9, 10, 149)
$script:V02ReleaseGatePackageProfileId = 'herdrops-v0.2-package-software-only-issue-149'
$script:V02ReleaseGateReferenceHostProfileId = 'herdrops-v0.2-submark-nb-software-only-20260822'
$script:V02ReleaseGateReferenceHostProfileSha256 = '96D01ED15A536F2DF50B59B43CFDEB3683DCE8667AE2E7BF6A96124182FE13A3'
$script:V02ReleaseGateReferenceHostSchemaSha256 = '98AC6A2D823D88960A79299B7B20424FF60E9C5299D458A30AB9A42BE4FC0FB3'
$script:V02ReleaseGateRendererPolicy = 'software-only-process-wide'
$script:V02ReleaseGateRendererMode = 'SoftwareOnly'
$script:V02ReleaseGateRendererPolicySha256 = '1D37C9C39449556EB30F9AB5B734F0C5411CF4203321AF0B238993D017229E92'
$script:V02ReleaseGatePackageReceiptSchemaSha256 = '8C7EF64ED06C94C6589D73C0AB47EB60B7EEF7BFE337F126D8D9D3F0CC0F4C4B'
$script:V02ReleaseGateDecisionId = 'herdrops-rec-all-v2'
$script:V02ReleaseGateDecisionPayloadSha256 = '48474610D2A20EE2F7CA2DAC0A3CCF45F919440C9C5D81EF5BA93AD7E524F62D'
$script:V02ReleaseGateDecisionReference = 'https://github.com/OSHEThai/HerdrOps/issues/149#issuecomment-5380637664'
$script:V02ReleaseGateAuthorityReferenceRelativePath = 'Plan/DECISIONS.md#D-024'
$script:V02ReleaseGateAuthorityFileSha256 = 'BFADC29EA34BAA13FF5D3F43013795C0258CF691369E5E150774D3F646F4F730'
$script:V02ReleaseGateAuthorityOwner = '@yutthaphon'
$script:V02ReleaseGateAuthorityRole = 'ProductOwner'
$script:V02ReleaseGateIndependentReceiptEvidenceClass = 'ExternalIndependentCandidateReceipt'
$script:V02ReleaseGateIndependentReceiptAuthenticationMethod = 'EXTERNAL_RSA_SHA256_AUTHENTICATED_REVIEW'
$script:V02ReleaseGateIndependentReceiptSignatureAlgorithm = 'RSASSA-PKCS1-v1_5-SHA256'
$script:V02ReleaseGateIndependentReceiptKeyType = 'RSA-2048'
$script:V02ReleaseGateMinimumRsaModulusBytes = 256
$script:V02ReleaseGateIndependentReceiptRole = 'IndependentGateReviewer'
$script:V02ReleaseGateMaximumSnapshotBytes = [int64]16777216
$script:V02ReleaseGateHerdrReleaseId = '0.8.2-preview.2026-08-19-b5c4a0176e91-x86_64-pc-windows-msvc'
$script:V02ReleaseGateHerdrExecutableSha256 = 'AFE7BAD9B77946917B509C9B638BB2A47BC1D4F19254957D15B0FAAFBEDB3E93'
$script:V02ReleaseGateMatrixHashScope = 'SHA256OfRFC8785JcsUtf8NoBomPayload'
$script:V02ReleaseGateHumanCheckIds = @(
    'package-receipt',
    'renderer-compatibility',
    'runtime-matrix-thai',
    'runtime-matrix-english',
    'issue-7-acceptance',
    'issue-9-acceptance',
    'issue-10-acceptance',
    'issue-149-acceptance',
    'tracker-11-readiness',
    'language-separation'
)
$script:V02ReleaseGateHumanArtifactCheckIds = @(
    'package-receipt',
    'renderer-compatibility',
    'runtime-matrix-thai',
    'runtime-matrix-english',
    'issue-9-acceptance',
    'tracker-11-readiness'
)
$script:V02ReleaseGateTransitiveGovernanceRelativePaths = @(
    '.github/workflows/ci.yml',
    'tools/Test-V02ReleaseGate.ps1',
    'tools/lib/V02ReferenceHostProfile.ps1',
    'tools/lib/V02RuntimePackageBinding.ps1',
    'tools/lib/V02RuntimePackageBinding.Tests.ps1',
    'tools/packaging/v0.2/Test-V02PackageIdentity.ps1',
    'tools/packaging/v0.2/V02PackageIdentity.Common.ps1',
    'tools/packaging/v0.2/V02CleanMachine.Common.ps1',
    'tools/packaging/v0.2/Invoke-V02CleanMachineReleaseVerifier.ps1',
    'tools/packaging/v0.2/V02Packaging.Common.ps1',
    'tools/packaging/v0.2/clean-machine-report.schema.json',
    'tools/packaging/Packaging.Common.ps1',
    'tools/v0.2-renderer-compatibility/Test-V02RendererCompatibilityManifest.ps1',
    'tools/v0.2-renderer-compatibility/RendererCompatibility.Common.ps1',
    'tools/human-design-review/HumanDesignReview.Common.ps1',
    'tools/Test-V02LanguageMatrixAcceptance.ps1',
    'tools/v0.2-issue9-live-ui/Test-V02Issue9LiveUiAcceptance.ps1',
    'tools/v0.2-issue9-live-ui/Issue9LiveUi.Common.ps1',
    'tools/v0.2-issue9-live-ui/issue9-live-ui-candidate.schema.json',
    'tools/v0.2-renderer-compatibility/Invoke-V02PerformanceMeasurement.ps1',
    'tools/v0.2-renderer-compatibility/Invoke-V02PerformanceMeasurement.SelfTests.ps1',
    'tools/v0.2-renderer-compatibility/New-V02PerformanceEvidenceReceipt.ps1',
    'tools/v0.2-renderer-compatibility/New-V02PerformanceEvidenceReceipt.SelfTests.ps1',
    'tools/v0.2-renderer-compatibility/Invoke-V02SoakMeasurement.ps1',
    'tools/v0.2-renderer-compatibility/Invoke-V02SoakMeasurement.SelfTests.ps1',
    'tools/v0.2-renderer-compatibility/lib/V02PerformanceTestHarness.ps1',
    'tools/v0.2-renderer-compatibility/lib/V02PerformanceTransaction.ps1',
    'tools/v0.2-renderer-compatibility/lib/V02SoakTestHarness.ps1',
    'tools/v0.2-issue10-live-widget/Publish-V02Issue10PerformanceSoakEvidence.ps1',
    'tools/v0.2-issue10-live-widget/Publish-V02Issue10PerformanceSoakEvidence.SelfTests.ps1',
    'src/HerdrOps.App/App.xaml.cs',
    'src/HerdrOps.App/RuntimeEvidence/Issue10PerformanceTelemetryProducer.cs',
    'src/HerdrOps.App/RuntimeEvidence/Issue10PackageValidator.cs',
    'src/HerdrOps.App/RuntimeEvidence/Issue10WidgetEvidence.cs',
    'tests/HerdrOps.RuntimeTests/Issue10PackageValidatorHostileTests.cs',
    'tests/HerdrOps.RuntimeTests/Issue10PerformanceTelemetryProducerTests.cs',
    'tools/Test-V02LiveRuntimeAcceptance.ps1',
    'tools/v0.2-issue10-live-widget/V02Issue10Acceptance.Common.ps1',
    'tools/v0.2-issue10-live-widget/Test-V02Issue10Acceptance.Tests.ps1',
    'tools/v0.2-issue10-live-widget/Test-V02Issue10SameRunCausality.Tests.ps1',
    'tools/v0.2-runtime-review/RuntimeReview.Common.ps1',
    'tools/v0.2-runtime-review/Test-V02RuntimeReviewReceipt.Tests.ps1',
    'tools/v0.2-issue10-live-widget/README.md',
    'Plan/DECISIONS.md',
    'Plan/reference-hosts/v0.2.json',
    'Plan/reference-hosts/reference-host-profile.schema.json',
    'tools/packaging/v0.2/package-identity-profile.json',
    'tools/packaging/v0.2/package-identity-receipt.schema.json',
    'tools/v0.2-renderer-compatibility/renderer-compatibility-manifest.schema.json',
    'tools/human-design-review/human-design-review.schema.json',
    'docs/design/reference/MANIFEST.md',
    'docs/design/reference/01-overview.png',
    'docs/design/reference/02-live-organization.png',
    'docs/design/reference/03-realtime-activity.png',
    'docs/design/reference/04-delegation-graph.png',
    'docs/design/reference/05-agent-detail.png',
    'docs/design/reference/06-task-alignment.png',
    'docs/design/reference/07-file-activity.png',
    'docs/design/reference/08-compliance-queue.png',
    'docs/design/reference/09-evaluation.png',
    'docs/design/reference/10-daily-summary.png',
    'docs/design/reference/11-widget-concepts.png'
)
$script:V02ReleaseGateValidatorRelativePaths = $script:V02ReleaseGateTransitiveGovernanceRelativePaths
$script:V02ReleaseGateHeldValidatorIndex = $null

if (-not ('V02ReleaseGateNative' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Text;
using Microsoft.Win32.SafeHandles;

public static class V02ReleaseGateNative
{
    [StructLayout(LayoutKind.Sequential)]
    public struct ByHandleFileInformation
    {
        public uint FileAttributes;
        public System.Runtime.InteropServices.ComTypes.FILETIME CreationTime;
        public System.Runtime.InteropServices.ComTypes.FILETIME LastAccessTime;
        public System.Runtime.InteropServices.ComTypes.FILETIME LastWriteTime;
        public uint VolumeSerialNumber;
        public uint FileSizeHigh;
        public uint FileSizeLow;
        public uint NumberOfLinks;
        public uint FileIndexHigh;
        public uint FileIndexLow;
    }

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    public static extern SafeFileHandle CreateFile(
        string fileName,
        uint desiredAccess,
        uint shareMode,
        IntPtr securityAttributes,
        uint creationDisposition,
        uint flagsAndAttributes,
        IntPtr templateFile);

    [DllImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    public static extern bool GetFileInformationByHandle(
        SafeFileHandle file,
        out ByHandleFileInformation information);

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    public static extern uint GetFinalPathNameByHandle(
        SafeFileHandle file,
        StringBuilder path,
        uint pathLength,
        uint flags);
}
'@
}

# The reference-host helper is an existing, read-only canonical JSON implementation.
# It is used for matrix payload re-hashing only; it does not start Herdr or call GitHub.
$referenceHostHelper = Join-Path $PSScriptRoot 'lib\V02ReferenceHostProfile.ps1'
if (-not (Test-Path -LiteralPath $referenceHostHelper -PathType Leaf)) {
    throw "v0.2 reference-host helper is missing: $referenceHostHelper"
}
$script:V02ReleaseGateBootstrapHelperStream = [IO.File]::Open(
    [IO.Path]::GetFullPath($referenceHostHelper),
    [IO.FileMode]::Open,
    [IO.FileAccess]::Read,
    [IO.FileShare]::Read)
$bootstrapParentPath = [IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($referenceHostHelper))
$script:V02ReleaseGateBootstrapHelperParentHandle = [V02ReleaseGateNative]::CreateFile(
    $bootstrapParentPath,
    [uint32][int64]2147483648,
    [uint32]0x00000003,
    [IntPtr]::Zero,
    [uint32]3,
    [uint32]0x02000000,
    [IntPtr]::Zero)
if ($null -eq $script:V02ReleaseGateBootstrapHelperParentHandle -or $script:V02ReleaseGateBootstrapHelperParentHandle.IsInvalid) {
    if ($null -ne $script:V02ReleaseGateBootstrapHelperParentHandle) { $script:V02ReleaseGateBootstrapHelperParentHandle.Dispose() }
    $script:V02ReleaseGateBootstrapHelperParentHandle = $null
    $script:V02ReleaseGateBootstrapHelperStream.Dispose()
    $script:V02ReleaseGateBootstrapHelperStream = $null
    throw "v0.2 reference-host helper parent handle could not be held: $bootstrapParentPath"
}
. $referenceHostHelper

function Assert-V02ReleaseGateExactProperties {
    param(
        [Parameter(Mandatory = $true)]$Object,
        [Parameter(Mandatory = $true)][string[]]$Names,
        [Parameter(Mandatory = $true)][string]$Context
    )

    if ($null -eq $Object -or $Object -isnot [pscustomobject]) {
        throw "$Context must be a JSON object."
    }
    $actual = @($Object.PSObject.Properties.Name)
    if ($actual.Count -ne $Names.Count) {
        throw "$Context must contain exactly: $($Names -join ', ')."
    }
    foreach ($name in $Names) {
        if (-not ($actual -ccontains $name)) {
            throw "$Context omitted '$name'."
        }
    }
}

function Get-V02ReleaseGateProperty {
    param(
        [Parameter(Mandatory = $true)]$Object,
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][string]$Context
    )

    if ($null -eq $Object -or -not (@($Object.PSObject.Properties.Name) -ccontains $Name)) {
        throw "$Context omitted '$Name'."
    }
    return $Object.$Name
}

function Assert-V02ReleaseGateString {
    param($Value, [Parameter(Mandatory = $true)][string]$Context)

    if ($Value -isnot [string] -or [string]::IsNullOrWhiteSpace([string]$Value)) {
        throw "$Context must be a nonblank native JSON string."
    }
    return [string]$Value
}

function Assert-V02ReleaseGateExactString {
    param($Value, [Parameter(Mandatory = $true)][string]$Expected, [Parameter(Mandatory = $true)][string]$Context)

    Assert-V02ReleaseGateString $Value $Context | Out-Null
    if ([string]$Value -cne $Expected) {
        throw "$Context must equal '$Expected'."
    }
}

function Assert-V02ReleaseGateBoolean {
    param($Value, [Parameter(Mandatory = $true)][string]$Context)

    if ($Value -isnot [bool]) {
        throw "$Context must be a native JSON boolean."
    }
    return [bool]$Value
}

function Assert-V02ReleaseGateInteger {
    param($Value, [Parameter(Mandatory = $true)][string]$Context, [int64]$Minimum = 0)

    $integerTypes = @([byte], [sbyte], [int16], [uint16], [int32], [uint32], [int64], [uint64])
    if ($null -eq $Value -or $integerTypes -notcontains $Value.GetType()) {
        throw "$Context must be a native JSON integer."
    }
    if ([decimal]$Value -lt [decimal]$Minimum) {
        throw "$Context must be at least $Minimum."
    }
}

function Assert-V02ReleaseGateSha256 {
    param($Value, [Parameter(Mandatory = $true)][string]$Context)

    Assert-V02ReleaseGateString $Value $Context | Out-Null
    if ([string]$Value -cnotmatch '^[0-9A-F]{64}$' -or [string]$Value -ceq ('0' * 64)) {
        throw "$Context must be a nonzero uppercase SHA-256."
    }
    return [string]$Value
}

function Assert-V02ReleaseGateGitObjectId {
    param($Value, [Parameter(Mandatory = $true)][string]$Context)

    Assert-V02ReleaseGateString $Value $Context | Out-Null
    if ([string]$Value -cnotmatch '^[0-9a-f]{40}$') {
        throw "$Context must be a lowercase 40-hex Git object ID."
    }
    return [string]$Value
}

function Assert-V02ReleaseGateEqual {
    param($Actual, $Expected, [Parameter(Mandatory = $true)][string]$Context)

    if ([string]$Actual -cne [string]$Expected) {
        throw "$Context mismatch. Actual='$Actual' Expected='$Expected'."
    }
}

function Assert-V02ReleaseGateDistinctSet {
    param(
        [Parameter(Mandatory = $true)][object[]]$Values,
        [Parameter(Mandatory = $true)][string]$Context
    )

    $normalized = @($Values | ForEach-Object { [string]$_ })
    if ($normalized.Count -ne @($normalized | Select-Object -Unique).Count) {
        throw "$Context contains duplicate values."
    }
}

function Resolve-V02ReleaseGateExistingPath {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][ValidateSet('Leaf', 'Container')][string]$Type,
        [Parameter(Mandatory = $true)][string]$Context
    )

    if (-not (Test-Path -LiteralPath $Path -PathType $Type)) {
        throw "$Context is missing: $Path"
    }
    $inputFull = [IO.Path]::GetFullPath($Path)
    # Inspect the spelling supplied by the caller before Resolve-Path can
    # canonicalize a junction/symlink away. The post-resolve check below then
    # validates the handle target as well.
    Assert-V02ReleaseGateNoReparsePath -Path $inputFull -Context $Context
    $resolved = [IO.Path]::GetFullPath((Resolve-Path -LiteralPath $Path).Path).TrimEnd([char[]]@('\', '/'))
    Assert-V02ReleaseGateNoReparsePath -Path $resolved -Context $Context
    return $resolved
}

function Get-V02ReleaseGateFileSha256 {
    param([Parameter(Mandatory = $true)][string]$Path)

    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToUpperInvariant()
}

function Assert-V02ReleaseGateNoReparsePath {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Context
    )

    $full = [IO.Path]::GetFullPath($Path)
    $root = [IO.Path]::GetPathRoot($full)
    if ([string]::IsNullOrWhiteSpace($root)) {
        throw "$Context has no filesystem root: $Path"
    }
    $current = $root
    $tail = $full.Substring($root.Length)
    foreach ($part in ($tail -split '[\\/]')) {
        if ([string]::IsNullOrWhiteSpace($part)) { continue }
        $current = Join-Path $current $part
        if (Test-Path -LiteralPath $current) {
            $item = Get-Item -LiteralPath $current -Force
            if (([IO.FileAttributes]$item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                throw "$Context traverses a reparse point: $current"
            }
        }
    }
}

function Assert-V02ReleaseGatePathWithinRoot {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Root,
        [Parameter(Mandatory = $true)][string]$Context
    )

    $full = [IO.Path]::GetFullPath($Path).TrimEnd([char[]]@('\', '/'))
    $rootFull = [IO.Path]::GetFullPath($Root).TrimEnd([char[]]@('\', '/'))
    Assert-V02ReleaseGateNoReparsePath -Path $full -Context $Context
    Assert-V02ReleaseGateNoReparsePath -Path $rootFull -Context "$Context root"
    $prefix = $rootFull + [IO.Path]::DirectorySeparatorChar
    if (-not [StringComparer]::OrdinalIgnoreCase.Equals($full, $rootFull) -and
        -not $full.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) {
        throw "$Context escapes its evidence root. Path='$full' Root='$rootFull'."
    }
    return $full
}

function Assert-V02ReleaseGatePathOutsideRoot {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Root,
        [Parameter(Mandatory = $true)][string]$Context
    )

    $full = [IO.Path]::GetFullPath($Path).TrimEnd([char[]]@('\', '/'))
    $rootFull = [IO.Path]::GetFullPath($Root).TrimEnd([char[]]@('\', '/'))
    $prefix = $rootFull + [IO.Path]::DirectorySeparatorChar
    if ([StringComparer]::OrdinalIgnoreCase.Equals($full, $rootFull) -or
        $full.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) {
        throw "$Context must be externally supplied outside '$rootFull'. Path='$full'."
    }
    return $full
}

function Get-V02ReleaseGateFinalPathByHandle {
    param(
        [Parameter(Mandatory = $true)][Microsoft.Win32.SafeHandles.SafeFileHandle]$Handle,
        [Parameter(Mandatory = $true)][string]$Context
    )

    $capacity = 512
    while ($true) {
        $builder = New-Object Text.StringBuilder $capacity
        $length = [V02ReleaseGateNative]::GetFinalPathNameByHandle($Handle, $builder, [uint32]$capacity, 0)
        if ($length -eq 0) {
            throw "$Context final path by handle failed: $([ComponentModel.Win32Exception]::new([Runtime.InteropServices.Marshal]::GetLastWin32Error()).Message)"
        }
        if ($length -lt [uint32]$capacity) {
            $value = $builder.ToString()
            if ($value.StartsWith('\\?\UNC\', [StringComparison]::OrdinalIgnoreCase)) {
                $value = '\\' + $value.Substring(8)
            }
            elseif ($value.StartsWith('\\?\', [StringComparison]::OrdinalIgnoreCase)) {
                $value = $value.Substring(4)
            }
            return [IO.Path]::GetFullPath($value).TrimEnd([char[]]@('\', '/'))
        }
        $capacity = [int]$length + 1
    }
}

function Get-V02ReleaseGateHandleFileIdentity {
    param(
        [Parameter(Mandatory = $true)][Microsoft.Win32.SafeHandles.SafeFileHandle]$Handle,
        [Parameter(Mandatory = $true)][string]$Context
    )

    $information = New-Object V02ReleaseGateNative+ByHandleFileInformation
    if (-not [V02ReleaseGateNative]::GetFileInformationByHandle($Handle, [ref]$information)) {
        throw "$Context file identity lookup failed: $([ComponentModel.Win32Exception]::new([Runtime.InteropServices.Marshal]::GetLastWin32Error()).Message)"
    }
    return ('{0:X8}:{1:X8}{2:X8}' -f $information.VolumeSerialNumber, $information.FileIndexHigh, $information.FileIndexLow)
}

function Get-V02ReleaseGateHandleLinkCount {
    param(
        [Parameter(Mandatory = $true)][Microsoft.Win32.SafeHandles.SafeFileHandle]$Handle,
        [Parameter(Mandatory = $true)][string]$Context
    )

    $information = New-Object V02ReleaseGateNative+ByHandleFileInformation
    if (-not [V02ReleaseGateNative]::GetFileInformationByHandle($Handle, [ref]$information)) {
        throw "$Context link-count lookup failed: $([ComponentModel.Win32Exception]::new([Runtime.InteropServices.Marshal]::GetLastWin32Error()).Message)"
    }
    return [uint32]$information.NumberOfLinks
}

function Open-V02ReleaseGateParentHandle {
    param(
        [Parameter(Mandatory = $true)][string]$ParentPath,
        [Parameter(Mandatory = $true)][string]$Context,
        [switch]$DenyDelete
    )

    $shareMode = if ($DenyDelete) { [uint32]0x00000003 } else { [uint32]0x00000007 }
    $handle = [V02ReleaseGateNative]::CreateFile(
        $ParentPath,
        [uint32][int64]2147483648,
        $shareMode,
        [IntPtr]::Zero,
        [uint32]3,
        [uint32]0x02000000,
        [IntPtr]::Zero)
    if ($null -eq $handle -or $handle.IsInvalid) {
        if ($null -ne $handle) { $handle.Dispose() }
        throw "$Context parent handle open failed: $([ComponentModel.Win32Exception]::new([Runtime.InteropServices.Marshal]::GetLastWin32Error()).Message)"
    }
    return $handle
}

function Assert-V02ReleaseGateHandlePath {
    param(
        [Parameter(Mandatory = $true)][string]$Actual,
        [Parameter(Mandatory = $true)][string]$Expected,
        [Parameter(Mandatory = $true)][string]$Context
    )

    $actualFull = [IO.Path]::GetFullPath($Actual).TrimEnd([char[]]@('\', '/'))
    $expectedFull = [IO.Path]::GetFullPath($Expected).TrimEnd([char[]]@('\', '/'))
    if (-not [StringComparer]::OrdinalIgnoreCase.Equals($actualFull, $expectedFull)) {
        throw "$Context final path by handle changed. Expected='$expectedFull' Observed='$actualFull'."
    }
    Assert-V02ReleaseGateNoReparsePath -Path $actualFull -Context "$Context final path"
}

function Get-V02ReleaseGateStableFileSnapshot {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Context,
        [switch]$KeepOpen
    )

    $fullPath = Resolve-V02ReleaseGateExistingPath -Path $Path -Type Leaf -Context $Context
    $expectedParent = [IO.Path]::GetDirectoryName($fullPath)
    $stream = $null
    $parentHandle = $null
    $completed = $false
    try {
        # FileShare.Read holds the leaf against write/delete/rename while the bytes
        # are read. The native parent handle and final-path checks close the
        # leaf/parent reparse or replacement window around this open.
        $stream = [IO.File]::Open($fullPath, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
        $parentHandle = Open-V02ReleaseGateParentHandle -ParentPath $expectedParent -Context $Context -DenyDelete:$KeepOpen
        $leafFinalBefore = Get-V02ReleaseGateFinalPathByHandle -Handle $stream.SafeFileHandle -Context "$Context leaf"
        $parentFinalBefore = Get-V02ReleaseGateFinalPathByHandle -Handle $parentHandle -Context "$Context parent"
        Assert-V02ReleaseGateHandlePath -Actual $leafFinalBefore -Expected $fullPath -Context "$Context leaf"
        Assert-V02ReleaseGateHandlePath -Actual $parentFinalBefore -Expected $expectedParent -Context "$Context parent"
        $fileIdentity = Get-V02ReleaseGateHandleFileIdentity -Handle $stream.SafeFileHandle -Context "$Context leaf"
        $linkCount = Get-V02ReleaseGateHandleLinkCount -Handle $stream.SafeFileHandle -Context "$Context leaf"
        $parentIdentity = Get-V02ReleaseGateHandleFileIdentity -Handle $parentHandle -Context "$Context parent"
        if ($stream.Length -gt $script:V02ReleaseGateMaximumSnapshotBytes) {
            throw "$Context exceeds bounded snapshot size of $script:V02ReleaseGateMaximumSnapshotBytes bytes: $fullPath"
        }
        if ($stream.Length -gt [int32]::MaxValue) {
            throw "$Context is too large for bounded validation: $fullPath"
        }
        $initialLength = [int64]$stream.Length
        $bytes = New-Object byte[] ([int32]$initialLength)
        $offset = 0
        while ($offset -lt $bytes.Length) {
            $read = $stream.Read($bytes, $offset, $bytes.Length - $offset)
            if ($read -le 0) { throw "$Context ended before the held-byte read completed: $fullPath" }
            $offset += $read
        }
        if ([int64]$stream.Length -ne $initialLength) {
            throw "$Context changed length during the held-byte read: $fullPath"
        }
        $leafFinalAfter = Get-V02ReleaseGateFinalPathByHandle -Handle $stream.SafeFileHandle -Context "$Context leaf after read"
        $parentFinalAfter = Get-V02ReleaseGateFinalPathByHandle -Handle $parentHandle -Context "$Context parent after read"
        Assert-V02ReleaseGateHandlePath -Actual $leafFinalAfter -Expected $fullPath -Context "$Context leaf after read"
        Assert-V02ReleaseGateHandlePath -Actual $parentFinalAfter -Expected $expectedParent -Context "$Context parent after read"
        $leafIdentityAfter = Get-V02ReleaseGateHandleFileIdentity -Handle $stream.SafeFileHandle -Context "$Context leaf after read"
        $linkCountAfter = Get-V02ReleaseGateHandleLinkCount -Handle $stream.SafeFileHandle -Context "$Context leaf after read"
        $parentIdentityAfter = Get-V02ReleaseGateHandleFileIdentity -Handle $parentHandle -Context "$Context parent after read"
        Assert-V02ReleaseGateEqual $leafIdentityAfter $fileIdentity "$Context leaf file identity"
        Assert-V02ReleaseGateEqual $linkCountAfter $linkCount "$Context leaf hardlink count"
        Assert-V02ReleaseGateEqual $parentIdentityAfter $parentIdentity "$Context parent file identity"
        $completed = $true
    }
    finally {
        if (-not $KeepOpen -or -not $completed) {
            if ($null -ne $parentHandle) { $parentHandle.Dispose() }
            if ($null -ne $stream) { $stream.Dispose() }
        }
    }
    return [pscustomobject][ordered]@{
        Path = $fullPath
        FinalPath = $leafFinalAfter
        ParentFinalPath = $parentFinalAfter
        FileId = $fileIdentity
        LinkCount = [uint32]$linkCount
        ParentFileId = $parentIdentity
        Bytes = [byte[]]$bytes
        Length = [int64]$bytes.Length
        Sha256 = (Get-V02Sha256Hex -Bytes $bytes).ToUpperInvariant()
        HeldStream = if ($KeepOpen) { $stream } else { $null }
        HeldParentHandle = if ($KeepOpen) { $parentHandle } else { $null }
    }
}

function Close-V02ReleaseGateHeldSnapshots {
    param(
        [Parameter(Mandatory = $true)]$Snapshots
    )

    foreach ($snapshot in @($Snapshots)) {
        if ($null -ne $snapshot.HeldParentHandle) {
            $snapshot.HeldParentHandle.Dispose()
        }
        if ($null -ne $snapshot.HeldStream) {
            $snapshot.HeldStream.Dispose()
        }
    }
    if ($null -ne $script:V02ReleaseGateBootstrapHelperParentHandle) {
        $script:V02ReleaseGateBootstrapHelperParentHandle.Dispose()
        $script:V02ReleaseGateBootstrapHelperParentHandle = $null
    }
    if ($null -ne $script:V02ReleaseGateBootstrapHelperStream) {
        $script:V02ReleaseGateBootstrapHelperStream.Dispose()
        $script:V02ReleaseGateBootstrapHelperStream = $null
    }
    $script:V02ReleaseGateHeldValidatorIndex = $null
}

function ConvertFrom-V02ReleaseGateStrictJsonBytes {
    param(
        [Parameter(Mandatory = $true)][byte[]]$Bytes,
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Context
    )

    if ($Bytes.Length -ge 3 -and $Bytes[0] -eq 0xEF -and $Bytes[1] -eq 0xBB -and $Bytes[2] -eq 0xBF) {
        throw "$Context must be UTF-8 without a BOM: $Path"
    }
    try {
        $json = [Text.UTF8Encoding]::new($false, $true).GetString($Bytes)
    }
    catch {
        throw "$Context contains malformed UTF-8: $Path"
    }
    if ($json.IndexOf([char]0xFEFF) -ge 0) {
        throw "$Context contains an unexpected BOM character: $Path"
    }
    Assert-V02NoDuplicateJsonProperties -Json $json -Source $Path
    try {
        $value = if ((Get-Command ConvertFrom-Json -CommandType Cmdlet).Parameters.ContainsKey('DateKind')) {
            $json | ConvertFrom-Json -DateKind String
        }
        else {
            $json | ConvertFrom-Json
        }
    }
    catch {
        throw "$Context is malformed, commented, or has a trailing comma: $Path"
    }
    if ($null -eq $value -or $value -isnot [pscustomobject]) {
        throw "$Context root must be an object: $Path"
    }
    return [pscustomobject][ordered]@{ Value = $value; Json = $json }
}

function Read-V02ReleaseGateJsonFile {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Context
    )

    $snapshot = Get-V02ReleaseGateStableFileSnapshot -Path $Path -Context $Context
    try {
        $document = ConvertFrom-V02ReleaseGateStrictJsonBytes -Bytes $snapshot.Bytes -Path $snapshot.Path -Context $Context
    }
    catch {
        throw "$Context is not strict UTF-8 JSON: $($_.Exception.Message)"
    }
    return [pscustomobject][ordered]@{
        Path = $snapshot.Path
        FinalPath = $snapshot.FinalPath
        ParentFinalPath = $snapshot.ParentFinalPath
        FileId = $snapshot.FileId
        ParentFileId = $snapshot.ParentFileId
        Value = $document.Value
        Bytes = $snapshot.Bytes
        RawJson = $document.Json
        Length = $snapshot.Length
        FileSha256 = $snapshot.Sha256
    }
}

function Assert-V02ReleaseGateSnapshotUnchanged {
    param(
        [Parameter(Mandatory = $true)]$Snapshot,
        [Parameter(Mandatory = $true)][string]$Context
    )

    $current = Get-V02ReleaseGateStableFileSnapshot -Path $Snapshot.Path -Context $Context
    Assert-V02ReleaseGateEqual $current.FinalPath $Snapshot.FinalPath "$Context final path"
    Assert-V02ReleaseGateEqual $current.ParentFinalPath $Snapshot.ParentFinalPath "$Context parent final path"
    Assert-V02ReleaseGateEqual $current.FileId $Snapshot.FileId "$Context file identity"
    Assert-V02ReleaseGateEqual $current.ParentFileId $Snapshot.ParentFileId "$Context parent identity"
    Assert-V02ReleaseGateEqual $current.Length $Snapshot.Length "$Context length"
    Assert-V02ReleaseGateEqual $current.Sha256 $Snapshot.Sha256 "$Context bytes"
    return $current
}

function Assert-V02ReleaseGateDistinctFileIdentities {
    param(
        [Parameter(Mandatory = $true)]$Snapshots,
        [Parameter(Mandatory = $true)][string]$Context
    )

    $pathsByIdentity = @{}
    foreach ($snapshot in @($Snapshots)) {
        $pathKey = ([IO.Path]::GetFullPath([string]$snapshot.Path)).TrimEnd([char[]]@('\', '/')).ToUpperInvariant()
        $identityKey = [string]$snapshot.FileId
        if ($pathsByIdentity.ContainsKey($identityKey) -and $pathsByIdentity[$identityKey] -cne $pathKey) {
            throw "$Context rejects a hardlink/file-identity alias: '$pathKey' and '$($pathsByIdentity[$identityKey])' share file identity '$identityKey'."
        }
        $pathsByIdentity[$identityKey] = $pathKey
    }
}

function Get-V02ReleaseGateValidatorSnapshots {
    param(
        [Parameter(Mandatory = $true)][string]$RepositoryRoot
    )

    $snapshots = New-Object System.Collections.Generic.List[object]
    try {
        foreach ($relativePath in $script:V02ReleaseGateValidatorRelativePaths) {
            $expectedPath = [IO.Path]::GetFullPath((Join-Path $RepositoryRoot ($relativePath -replace '/', '\'))).TrimEnd([char[]]@('\', '/'))
            $actualPath = Resolve-V02ReleaseGateExistingPath -Path $expectedPath -Type Leaf -Context "Validator/helper '$relativePath'"
            if (-not [StringComparer]::OrdinalIgnoreCase.Equals($actualPath, $expectedPath)) {
                throw "Validator/helper '$relativePath' was not opened at its committed path."
            }
            [void]$snapshots.Add((Get-V02ReleaseGateStableFileSnapshot -Path $actualPath -Context "Validator/helper '$relativePath'" -KeepOpen))
        }
        Assert-V02ReleaseGateDistinctFileIdentities -Snapshots $snapshots.ToArray() -Context 'Validator/helper snapshots'
        $script:V02ReleaseGateHeldValidatorIndex = @{}
        foreach ($snapshot in $snapshots.ToArray()) {
            $key = ([IO.Path]::GetFullPath([string]$snapshot.Path)).TrimEnd([char[]]@('\', '/')).ToUpperInvariant()
            $script:V02ReleaseGateHeldValidatorIndex[$key] = $snapshot
        }
        return $snapshots.ToArray()
    }
    catch {
        Close-V02ReleaseGateHeldSnapshots -Snapshots $snapshots.ToArray()
        throw
    }
}

function Assert-V02ReleaseGateValidatorHeld {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Context
    )

    $key = ([IO.Path]::GetFullPath($Path)).TrimEnd([char[]]@('\', '/')).ToUpperInvariant()
    if ($null -eq $script:V02ReleaseGateHeldValidatorIndex -or
        -not $script:V02ReleaseGateHeldValidatorIndex.ContainsKey($key) -or
        $null -eq $script:V02ReleaseGateHeldValidatorIndex[$key].HeldStream -or
        $script:V02ReleaseGateHeldValidatorIndex[$key].HeldStream.SafeFileHandle.IsClosed) {
        throw "$Context is not executing a held validator/helper file: $Path"
    }
    return $script:V02ReleaseGateHeldValidatorIndex[$key]
}

function Get-V02ReleaseGateGitIdentity {
    param([Parameter(Mandatory = $true)][string]$RepositoryRoot)

    $root = Resolve-V02ReleaseGateExistingPath -Path $RepositoryRoot -Type Container -Context 'RepositoryRoot'
    $commit = (& git -C $root rev-parse HEAD).Trim()
    if ($LASTEXITCODE -ne 0 -or $commit -notmatch '^[0-9a-f]{40}$') {
        throw "Could not resolve a lowercase 40-hex HEAD commit in $root."
    }
    $tree = (& git -C $root show -s --format=%T HEAD).Trim()
    if ($LASTEXITCODE -ne 0 -or $tree -notmatch '^[0-9a-f]{40}$') {
        throw "Could not resolve a lowercase 40-hex HEAD tree in $root."
    }
    $parentsLine = (& git -C $root show -s --format=%P HEAD).Trim()
    if ($LASTEXITCODE -ne 0) {
        throw "Could not resolve HEAD parents in $root."
    }
    $parents = @()
    if (-not [string]::IsNullOrWhiteSpace($parentsLine)) {
        $parents = @($parentsLine -split '\s+' | ForEach-Object {
                Assert-V02ReleaseGateGitObjectId $_ 'HEAD parent'
            })
    }
    $status = @(& git -C $root status --porcelain=v1 --untracked-files=all)
    if ($LASTEXITCODE -ne 0) {
        throw "Could not inspect the Git working tree in $root."
    }
    return [pscustomobject][ordered]@{
        RepositoryRoot = $root
        Commit = $commit
        Tree = $tree
        Parents = $parents
        Clean = ($status.Count -eq 0)
        PendingPaths = $status
    }
}

function Assert-V02ReleaseGateGitIdentity {
    param(
        [Parameter(Mandatory = $true)]$Identity,
        [Parameter(Mandatory = $true)][string]$ExpectedSourceCommit,
        [Parameter(Mandatory = $true)][string]$ExpectedSourceTree,
        [Parameter(Mandatory = $true)][string]$Phase
    )

    Assert-V02ReleaseGateEqual $Identity.Commit $ExpectedSourceCommit "$Phase source commit"
    Assert-V02ReleaseGateEqual $Identity.Tree $ExpectedSourceTree "$Phase source tree"
    if (-not [bool]$Identity.Clean) {
        throw "$Phase source checkout is not clean. Pending paths: $($Identity.PendingPaths -join ', ')"
    }
}

function Get-V02ReleaseGateRelativeOrAbsolutePath {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$BaseDirectory,
        [Parameter(Mandatory = $true)][string]$Context,
        [string]$AllowedRoot
    )

    $candidate = $Path
    if (-not [IO.Path]::IsPathRooted($candidate)) {
        $candidate = Join-Path $BaseDirectory $candidate
    }
    $resolved = Resolve-V02ReleaseGateExistingPath -Path $candidate -Type Leaf -Context $Context
    if (-not [string]::IsNullOrWhiteSpace($AllowedRoot)) {
        Assert-V02ReleaseGatePathWithinRoot -Path $resolved -Root $AllowedRoot -Context $Context | Out-Null
    }
    return $resolved
}

function Read-V02ReleaseGateEvidenceReceipt {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][ValidateSet('Contract', 'Synthetic')][string]$ExpectedClass,
        [Parameter(Mandatory = $true)][string]$ExpectedSourceCommit,
        [Parameter(Mandatory = $true)][string]$ExpectedSourceTree,
        [Parameter(Mandatory = $true)][string]$EvidenceRoot
    )

    $document = Read-V02ReleaseGateJsonFile -Path $Path -Context "$ExpectedClass evidence receipt"
    $receipt = $document.Value
    Assert-V02ReleaseGateExactProperties $receipt @(
        'SchemaVersion', 'EvidenceClass', 'Result', 'SourceCommit', 'SourceTree',
        'RuntimeObserved', 'ActualHerdrUsed', 'ReleaseCredit', 'Checks'
    ) "$ExpectedClass evidence receipt"
    Assert-V02ReleaseGateInteger $receipt.SchemaVersion "$ExpectedClass SchemaVersion" 1
    Assert-V02ReleaseGateEqual $receipt.SchemaVersion 1 "$ExpectedClass SchemaVersion"
    Assert-V02ReleaseGateExactString $receipt.EvidenceClass $ExpectedClass "$ExpectedClass EvidenceClass"
    Assert-V02ReleaseGateExactString $receipt.Result 'PASS' "$ExpectedClass Result"
    Assert-V02ReleaseGateGitObjectId $receipt.SourceCommit "$ExpectedClass SourceCommit" | Out-Null
    Assert-V02ReleaseGateGitObjectId $receipt.SourceTree "$ExpectedClass SourceTree" | Out-Null
    Assert-V02ReleaseGateEqual $receipt.SourceCommit $ExpectedSourceCommit "$ExpectedClass source commit"
    Assert-V02ReleaseGateEqual $receipt.SourceTree $ExpectedSourceTree "$ExpectedClass source tree"
    if ((Assert-V02ReleaseGateBoolean $receipt.RuntimeObserved "$ExpectedClass RuntimeObserved") -ne $false) {
        throw "$ExpectedClass evidence cannot claim RuntimeObserved."
    }
    if ((Assert-V02ReleaseGateBoolean $receipt.ActualHerdrUsed "$ExpectedClass ActualHerdrUsed") -ne $false) {
        throw "$ExpectedClass evidence cannot claim actual Herdr use."
    }
    if (Assert-V02ReleaseGateBoolean $receipt.ReleaseCredit "$ExpectedClass ReleaseCredit") {
        throw "$ExpectedClass evidence cannot claim Release credit."
    }

    $checks = @($receipt.Checks)
    if ($checks.Count -eq 0) {
        throw "$ExpectedClass evidence must contain at least one check."
    }
    $checkNames = New-Object System.Collections.Generic.List[string]
    foreach ($check in $checks) {
        Assert-V02ReleaseGateExactProperties $check @('Name', 'Result', 'Path', 'Sha256') "$ExpectedClass evidence check"
        $name = Assert-V02ReleaseGateString $check.Name "$ExpectedClass check Name"
        if ($checkNames.Contains($name)) {
            throw "$ExpectedClass evidence contains duplicate check '$name'."
        }
        [void]$checkNames.Add($name)
        Assert-V02ReleaseGateExactString $check.Result 'PASS' "$ExpectedClass check '$name' Result"
        $checkPath = Get-V02ReleaseGateRelativeOrAbsolutePath -Path ([string]$check.Path) `
            -BaseDirectory ([IO.Path]::GetDirectoryName($document.Path)) `
            -Context "$ExpectedClass check '$name' artifact" -AllowedRoot $EvidenceRoot
        $declaredSha = Assert-V02ReleaseGateSha256 $check.Sha256 "$ExpectedClass check '$name' Sha256"
        $checkSnapshot = Get-V02ReleaseGateStableFileSnapshot -Path $checkPath -Context "$ExpectedClass check '$name' artifact"
        Assert-V02ReleaseGateEqual $checkSnapshot.Sha256 $declaredSha "$ExpectedClass check '$name' artifact hash"
    }

    return [pscustomobject][ordered]@{
        Path = $document.Path
        FileSha256 = $document.FileSha256
        EvidenceClass = $ExpectedClass
        CheckCount = $checks.Count
    }
}

function Read-V02ReleaseGateAuthorityReference {
    param(
        [Parameter(Mandatory = $true)][string]$RepositoryRoot,
        [Parameter(Mandatory = $true)][string]$AuthorityReferencePath
    )

    $expectedPath = [IO.Path]::GetFullPath((Join-Path $RepositoryRoot 'Plan\DECISIONS.md')).TrimEnd([char[]]@('\', '/'))
    $actualPath = Resolve-V02ReleaseGateExistingPath -Path $AuthorityReferencePath -Type Leaf -Context 'Authority reference'
    if (-not [StringComparer]::OrdinalIgnoreCase.Equals($actualPath, $expectedPath)) {
        throw "Authority reference must be the committed Plan/DECISIONS.md: $expectedPath"
    }
    $snapshot = Get-V02ReleaseGateStableFileSnapshot -Path $actualPath -Context 'Authority reference'
    if ($snapshot.Sha256 -cne $script:V02ReleaseGateAuthorityFileSha256) {
        throw "Authority reference hash is not the approved REC-ALL v2 record. Expected=$script:V02ReleaseGateAuthorityFileSha256 Observed=$($snapshot.Sha256)"
    }
    $text = [Text.UTF8Encoding]::new($false, $true).GetString($snapshot.Bytes)
    foreach ($required in @(
            'D-024',
            'REC-ALL v2 is the authoritative cross-version owner decision',
            'herdrops-rec-all-v2',
            $script:V02ReleaseGateDecisionReference,
            $script:V02ReleaseGateDecisionPayloadSha256,
            $script:V02ReleaseGateAuthorityOwner,
            'Agents cannot self-grant owner or final Human authority'
        )) {
        if ($text.IndexOf($required, [StringComparison]::Ordinal) -lt 0) {
            throw "Authority reference is missing its trusted binding: $required"
        }
    }
    return [pscustomobject][ordered]@{
        Path = $snapshot.Path
        FileSha256 = $snapshot.Sha256
        RelativeReference = $script:V02ReleaseGateAuthorityReferenceRelativePath
        DecisionId = $script:V02ReleaseGateDecisionId
        ApprovalReference = $script:V02ReleaseGateDecisionReference
        PayloadSha256 = $script:V02ReleaseGateDecisionPayloadSha256
        OwnerIdentity = $script:V02ReleaseGateAuthorityOwner
        OwnerRole = $script:V02ReleaseGateAuthorityRole
        Authentication = 'TRUSTED_COMMITTED_PLAN_OWNER_DECISION_ONLY'
    }
}

function Read-V02ReleaseGateExternalIndependentCandidateReceipt {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$RepositoryRoot,
        [Parameter(Mandatory = $true)][string]$EvidenceRoot,
        [Parameter(Mandatory = $true)][string]$ExpectedSourceCommit,
        [Parameter(Mandatory = $true)][string]$ExpectedSourceTree
    )

    $actualPath = Resolve-V02ReleaseGateExistingPath -Path $Path -Type Leaf -Context 'External independent candidate receipt'
    Assert-V02ReleaseGatePathOutsideRoot -Path $actualPath -Root $RepositoryRoot -Context 'External independent candidate receipt' | Out-Null
    Assert-V02ReleaseGatePathOutsideRoot -Path $actualPath -Root $EvidenceRoot -Context 'External independent candidate receipt' | Out-Null
    $document = Read-V02ReleaseGateJsonFile -Path $actualPath -Context 'External independent candidate receipt'
    $receipt = $document.Value
    Assert-V02ReleaseGateExactProperties $receipt @(
        'SchemaVersion', 'EvidenceClass', 'Result', 'DecisionId', 'ApprovalReference',
        'AuthorityReference', 'AuthorityReferenceSha256', 'Candidate', 'Owner', 'IndependentReviewer',
        'Authentication', 'RoleDistinct', 'Runtime', 'Human', 'Release', 'CreditGranted'
    ) 'External independent candidate receipt'
    Assert-V02ReleaseGateInteger $receipt.SchemaVersion 'External independent candidate receipt SchemaVersion' 3
    Assert-V02ReleaseGateEqual $receipt.SchemaVersion 3 'External independent candidate receipt SchemaVersion'
    Assert-V02ReleaseGateExactString $receipt.EvidenceClass $script:V02ReleaseGateIndependentReceiptEvidenceClass 'External independent candidate receipt EvidenceClass'
    Assert-V02ReleaseGateExactString $receipt.Result 'APPROVED_CANDIDATE_ONLY' 'External independent candidate receipt Result'
    Assert-V02ReleaseGateExactString $receipt.DecisionId $script:V02ReleaseGateDecisionId 'External independent candidate receipt DecisionId'
    Assert-V02ReleaseGateExactString $receipt.ApprovalReference $script:V02ReleaseGateDecisionReference 'External independent candidate receipt ApprovalReference'
    Assert-V02ReleaseGateExactString $receipt.AuthorityReference $script:V02ReleaseGateAuthorityReferenceRelativePath 'External independent candidate receipt AuthorityReference'
    Assert-V02ReleaseGateExactString $receipt.AuthorityReferenceSha256 $script:V02ReleaseGateAuthorityFileSha256 'External independent candidate receipt AuthorityReferenceSha256'
    Assert-V02ReleaseGateExactProperties $receipt.Candidate @(
        'SourceCommit', 'SourceTree', 'ProfileId', 'ProfileFileSha256', 'ProfileCanonicalSha256',
        'PackageReceiptSha256', 'PackageReceiptFileSha256', 'PackageArchiveSha256',
        'PackageManifestSha256', 'PackageAppSha256', 'PackageCoreSha256',
        'RendererManifestSha256', 'RuntimeMatrixManifestSha256', 'Issue9CandidateSha256'
    ) 'External independent candidate receipt Candidate'
    Assert-V02ReleaseGateGitObjectId $receipt.Candidate.SourceCommit 'External independent candidate receipt SourceCommit' | Out-Null
    Assert-V02ReleaseGateGitObjectId $receipt.Candidate.SourceTree 'External independent candidate receipt SourceTree' | Out-Null
    Assert-V02ReleaseGateEqual $receipt.Candidate.SourceCommit $ExpectedSourceCommit 'External independent candidate receipt source commit'
    Assert-V02ReleaseGateEqual $receipt.Candidate.SourceTree $ExpectedSourceTree 'External independent candidate receipt source tree'
    Assert-V02ReleaseGateExactString $receipt.Candidate.ProfileId $script:V02ReleaseGatePackageProfileId 'External independent candidate receipt ProfileId'
    foreach ($name in @(
            'ProfileFileSha256', 'ProfileCanonicalSha256', 'PackageReceiptSha256',
            'PackageReceiptFileSha256', 'PackageArchiveSha256', 'PackageManifestSha256',
            'PackageAppSha256', 'PackageCoreSha256', 'RendererManifestSha256',
            'RuntimeMatrixManifestSha256', 'Issue9CandidateSha256'
        )) {
        Assert-V02ReleaseGateSha256 $receipt.Candidate.$name "External independent candidate receipt Candidate.$name" | Out-Null
    }
    Assert-V02ReleaseGateExactProperties $receipt.Owner @('Identity', 'Role') 'External independent candidate receipt Owner'
    Assert-V02ReleaseGateExactString $receipt.Owner.Identity $script:V02ReleaseGateAuthorityOwner 'External independent candidate receipt owner identity'
    Assert-V02ReleaseGateExactString $receipt.Owner.Role $script:V02ReleaseGateAuthorityRole 'External independent candidate receipt owner role'
    Assert-V02ReleaseGateExactProperties $receipt.IndependentReviewer @('Identity', 'Role') 'External independent candidate receipt IndependentReviewer'
    Assert-V02ReleaseGateString $receipt.IndependentReviewer.Identity 'External independent candidate receipt reviewer identity' | Out-Null
    Assert-V02ReleaseGateExactString $receipt.IndependentReviewer.Role $script:V02ReleaseGateIndependentReceiptRole 'External independent candidate receipt reviewer role'
    Assert-V02ReleaseGateDistinctSet -Values @($receipt.Owner.Identity, $receipt.IndependentReviewer.Identity) -Context 'External independent candidate receipt identities'
    Assert-V02ReleaseGateExactProperties $receipt.Authentication @(
        'Method', 'Reference', 'VerifiedBy', 'VerifiedRole', 'TrustAnchor',
        'Signature', 'SignatureAlgorithm', 'Authenticated'
    ) 'External independent candidate receipt Authentication'
    Assert-V02ReleaseGateExactString $receipt.Authentication.Method $script:V02ReleaseGateIndependentReceiptAuthenticationMethod 'External independent candidate receipt authentication method'
    Assert-V02ReleaseGateString $receipt.Authentication.Reference 'External independent candidate receipt authentication reference' | Out-Null
    if ([string]$receipt.Authentication.Reference -notmatch '^https://[^\s/]+(?:/|$)') {
        throw 'External independent candidate receipt authentication reference must be an external HTTPS reference.'
    }
    if ([string]$receipt.Authentication.Reference -ceq $script:V02ReleaseGateDecisionReference) {
        throw 'External independent candidate receipt authentication must be distinct from the owner approval reference.'
    }
    Assert-V02ReleaseGateExactString $receipt.Authentication.VerifiedBy $receipt.IndependentReviewer.Identity 'External independent candidate receipt verifier identity'
    Assert-V02ReleaseGateExactString $receipt.Authentication.VerifiedRole $receipt.IndependentReviewer.Role 'External independent candidate receipt verifier role'
    Assert-V02ReleaseGateExactString $receipt.Authentication.SignatureAlgorithm $script:V02ReleaseGateIndependentReceiptSignatureAlgorithm 'External independent candidate receipt signature algorithm'
    Assert-V02ReleaseGateExactProperties $receipt.Authentication.TrustAnchor @(
        'KeyType', 'Modulus', 'Exponent'
    ) 'External independent candidate receipt TrustAnchor'
    Assert-V02ReleaseGateExactString $receipt.Authentication.TrustAnchor.KeyType $script:V02ReleaseGateIndependentReceiptKeyType 'External independent candidate receipt trust anchor key type'
    $modulusStr = Assert-V02ReleaseGateString $receipt.Authentication.TrustAnchor.Modulus 'External independent candidate receipt trust anchor Modulus'
    $exponentStr = Assert-V02ReleaseGateString $receipt.Authentication.TrustAnchor.Exponent 'External independent candidate receipt trust anchor Exponent'
    $signatureStr = Assert-V02ReleaseGateString $receipt.Authentication.Signature 'External independent candidate receipt Signature'

    $modulusBytes = $null
    $exponentBytes = $null
    $signatureBytes = $null
    try {
        $modulusBytes = [Convert]::FromBase64String($modulusStr)
        $exponentBytes = [Convert]::FromBase64String($exponentStr)
        $signatureBytes = [Convert]::FromBase64String($signatureStr)
    }
    catch {
        throw 'External independent candidate receipt trust anchor and signature must be valid Base64.'
    }
    if ($modulusBytes.Length -lt $script:V02ReleaseGateMinimumRsaModulusBytes) {
        throw "Trust anchor RSA key size must be at least $($script:V02ReleaseGateMinimumRsaModulusBytes * 8) bits."
    }
    if ($signatureBytes.Length -lt $script:V02ReleaseGateMinimumRsaModulusBytes) {
        throw "Signature byte length must match RSA modulus length ($($script:V02ReleaseGateMinimumRsaModulusBytes) bytes)."
    }

    $signedPayload = [pscustomobject][ordered]@{
        DecisionId = [string]$receipt.DecisionId
        ApprovalReference = [string]$receipt.ApprovalReference
        AuthorityReference = [string]$receipt.AuthorityReference
        AuthorityReferenceSha256 = [string]$receipt.AuthorityReferenceSha256
        Candidate = $receipt.Candidate
        Owner = $receipt.Owner
        IndependentReviewer = $receipt.IndependentReviewer
    }
    $canonicalPayloadJson = ConvertTo-V02Jcs $signedPayload
    $canonicalPayloadBytes = [Text.UTF8Encoding]::new($false, $true).GetBytes($canonicalPayloadJson)
    $payloadSha256 = (Get-V02Sha256Hex -Bytes $canonicalPayloadBytes).ToUpperInvariant()

    $rsa = $null
    $signatureVerified = $false
    try {
        $rsa = [System.Security.Cryptography.RSA]::Create()
        $rsaParams = New-Object System.Security.Cryptography.RSAParameters
        $rsaParams.Modulus = $modulusBytes
        $rsaParams.Exponent = $exponentBytes
        $rsa.ImportParameters($rsaParams)
        $signatureVerified = $rsa.VerifyData($canonicalPayloadBytes, $signatureBytes, [System.Security.Cryptography.HashAlgorithmName]::SHA256, [System.Security.Cryptography.RSASignaturePadding]::Pkcs1)
    }
    catch {
        throw "External independent candidate receipt cryptographic trust anchor error: $($_.Exception.Message)"
    }
    finally {
        if ($null -ne $rsa) { $rsa.Dispose() }
    }
    if (-not $signatureVerified) {
        throw 'External independent candidate receipt cryptographic signature verification failed.'
    }

    if (-not (Assert-V02ReleaseGateBoolean $receipt.Authentication.Authenticated 'External independent candidate receipt Authenticated')) {
        throw 'External independent candidate receipt must be externally authenticated.'
    }
    if (-not (Assert-V02ReleaseGateBoolean $receipt.RoleDistinct 'External independent candidate receipt RoleDistinct')) {
        throw 'External independent candidate receipt must keep owner and independent reviewer roles distinct.'
    }
    Assert-V02ReleaseGateExactString $receipt.Runtime 'NOT_OBSERVED' 'External independent candidate receipt Runtime boundary'
    Assert-V02ReleaseGateExactString $receipt.Human 'NOT_OBSERVED' 'External independent candidate receipt Human boundary'
    Assert-V02ReleaseGateExactString $receipt.Release 'NOT_OBSERVED' 'External independent candidate receipt Release boundary'
    if (Assert-V02ReleaseGateBoolean $receipt.CreditGranted 'External independent candidate receipt CreditGranted') {
        throw 'External independent candidate receipt cannot grant Runtime, Human, or Release credit.'
    }
    return [pscustomobject][ordered]@{
        Path = $document.Path
        FileSha256 = $document.FileSha256
        Candidate = $receipt.Candidate
        OwnerIdentity = [string]$receipt.Owner.Identity
        OwnerRole = [string]$receipt.Owner.Role
        ReviewerIdentity = [string]$receipt.IndependentReviewer.Identity
        ReviewerRole = [string]$receipt.IndependentReviewer.Role
        AuthenticationReference = [string]$receipt.Authentication.Reference
        TrustAnchor = $receipt.Authentication.TrustAnchor
        TrustAnchorFingerprint = (Get-V02Sha256Hex -Bytes $modulusBytes).ToUpperInvariant()
        Signature = [string]$receipt.Authentication.Signature
        SignedPayloadSha256 = $payloadSha256
        Authentication = [string]$receipt.Authentication.Method
        Result = 'APPROVED_CANDIDATE_ONLY'
    }
}

function Read-V02ReleaseGateCandidateLock {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$EvidenceRoot,
        [Parameter(Mandatory = $true)][string]$ExpectedSourceCommit,
        [Parameter(Mandatory = $true)][string]$ExpectedSourceTree,
        [Parameter(Mandatory = $true)][string]$PackageProfilePath,
        [Parameter(Mandatory = $true)][string]$RepositoryRoot,
        [Parameter(Mandatory = $true)][string]$AuthorityReferencePath,
        [Parameter(Mandatory = $true)][string]$IndependentCandidateReceiptPath
    )

    # Never accept an Authority object supplied by the candidate lock or its
    # caller. Re-read the exact committed owner decision and separately supplied
    # candidate receipt so copied Plan JSON cannot self-authorize.
    $Authority = Read-V02ReleaseGateAuthorityReference -RepositoryRoot $RepositoryRoot `
        -AuthorityReferencePath $AuthorityReferencePath
    $IndependentReceipt = Read-V02ReleaseGateExternalIndependentCandidateReceipt `
        -Path $IndependentCandidateReceiptPath -RepositoryRoot $RepositoryRoot -EvidenceRoot $EvidenceRoot `
        -ExpectedSourceCommit $ExpectedSourceCommit -ExpectedSourceTree $ExpectedSourceTree
    $lockPath = Resolve-V02ReleaseGateExistingPath -Path $Path -Type Leaf -Context 'Approved candidate lock'
    Assert-V02ReleaseGatePathWithinRoot -Path $lockPath -Root $EvidenceRoot -Context 'Approved candidate lock' | Out-Null
    $document = Read-V02ReleaseGateJsonFile -Path $lockPath -Context 'Approved candidate lock'
    Assert-V02ReleaseGateExactProperties $document.Value @(
        'SchemaVersion', 'EvidenceClass', 'Result', 'Immutable', 'SourceCommit', 'SourceTree',
        'ProfileId', 'ProfileFileSha256', 'ProfileCanonicalSha256', 'PackageReceiptSha256',
        'PackageReceiptFileSha256', 'PackageArchiveSha256', 'PackageManifestSha256',
        'PackageAppSha256', 'PackageCoreSha256', 'RendererManifestSha256',
        'RuntimeMatrixManifestSha256', 'Issue9CandidateSha256', 'Authority', 'Runtime', 'Human', 'Release'
    ) 'Approved candidate lock'
    Assert-V02ReleaseGateInteger $document.Value.SchemaVersion 'Approved candidate lock SchemaVersion' 2
    Assert-V02ReleaseGateEqual $document.Value.SchemaVersion 2 'Approved candidate lock SchemaVersion'
    Assert-V02ReleaseGateExactString $document.Value.EvidenceClass 'ApprovedCandidateLock' 'Approved candidate lock EvidenceClass'
    Assert-V02ReleaseGateExactString $document.Value.Result 'APPROVED' 'Approved candidate lock Result'
    if (-not (Assert-V02ReleaseGateBoolean $document.Value.Immutable 'Approved candidate lock Immutable')) {
        throw 'Approved candidate lock must be immutable.'
    }
    Assert-V02ReleaseGateEqual $document.Value.SourceCommit $ExpectedSourceCommit 'Approved candidate lock source commit'
    Assert-V02ReleaseGateEqual $document.Value.SourceTree $ExpectedSourceTree 'Approved candidate lock source tree'
    Assert-V02ReleaseGateExactString $document.Value.ProfileId $script:V02ReleaseGatePackageProfileId 'Approved candidate lock ProfileId'
    $profileSnapshot = Get-V02ReleaseGateStableFileSnapshot -Path $PackageProfilePath -Context 'Approved candidate lock package profile'
    Assert-V02ReleaseGateEqual $document.Value.ProfileFileSha256 $profileSnapshot.Sha256 'Approved candidate lock profile bytes'
    Assert-V02ReleaseGateSha256 $document.Value.ProfileCanonicalSha256 'Approved candidate lock profile canonical SHA-256' | Out-Null
    $profileDocument = ConvertFrom-V02ReleaseGateStrictJsonBytes -Bytes $profileSnapshot.Bytes -Path $profileSnapshot.Path -Context 'Approved candidate lock package profile'
    $profileCanonical = ConvertTo-V02Jcs $profileDocument.Value
    $profileCanonicalSha = (Get-V02Sha256Hex -Bytes ([Text.UTF8Encoding]::new($false).GetBytes($profileCanonical))).ToUpperInvariant()
    Assert-V02ReleaseGateEqual $document.Value.ProfileCanonicalSha256 $profileCanonicalSha 'Approved candidate lock profile canonical bytes'
    foreach ($name in @(
            'PackageReceiptSha256', 'PackageReceiptFileSha256', 'PackageArchiveSha256',
            'PackageManifestSha256', 'PackageAppSha256', 'PackageCoreSha256',
            'RendererManifestSha256', 'RuntimeMatrixManifestSha256', 'Issue9CandidateSha256'
        )) {
        Assert-V02ReleaseGateSha256 $document.Value.$name "Approved candidate lock $name" | Out-Null
    }
    foreach ($name in @(
            'SourceCommit', 'SourceTree', 'ProfileId', 'ProfileFileSha256', 'ProfileCanonicalSha256',
            'PackageReceiptSha256', 'PackageReceiptFileSha256', 'PackageArchiveSha256',
            'PackageManifestSha256', 'PackageAppSha256', 'PackageCoreSha256',
            'RendererManifestSha256', 'RuntimeMatrixManifestSha256', 'Issue9CandidateSha256'
        )) {
        Assert-V02ReleaseGateEqual $document.Value.$name $IndependentReceipt.Candidate.$name `
            "Approved candidate lock external receipt Candidate.$name"
    }
    Assert-V02ReleaseGateExactString $document.Value.Runtime 'NOT_OBSERVED' 'Approved candidate lock Runtime boundary'
    Assert-V02ReleaseGateExactString $document.Value.Human 'NOT_OBSERVED' 'Approved candidate lock Human boundary'
    Assert-V02ReleaseGateExactString $document.Value.Release 'NOT_OBSERVED' 'Approved candidate lock Release boundary'

    Assert-V02ReleaseGateExactProperties $document.Value.Authority @(
        'DecisionId', 'ApprovalReference', 'PayloadSha256', 'Reference', 'ReferenceSha256',
        'OwnerIdentity', 'OwnerRole', 'Authentication', 'IndependentReceiptPath',
        'IndependentReceiptSha256', 'IndependentReceiptIdentity', 'IndependentReceiptRole',
        'IndependentReceiptAuthentication', 'IndependentReceiptTrustAnchorFingerprint',
        'IndependentReceiptSignedPayloadSha256'
    ) 'Approved candidate lock Authority'
    Assert-V02ReleaseGateEqual $document.Value.Authority.DecisionId $Authority.DecisionId 'Approved candidate lock authority decision'
    Assert-V02ReleaseGateEqual $document.Value.Authority.ApprovalReference $Authority.ApprovalReference 'Approved candidate lock authority reference'
    Assert-V02ReleaseGateEqual $document.Value.Authority.PayloadSha256 $Authority.PayloadSha256 'Approved candidate lock authority payload'
    Assert-V02ReleaseGateExactString $document.Value.Authority.Reference $Authority.RelativeReference 'Approved candidate lock authority source'
    Assert-V02ReleaseGateEqual $document.Value.Authority.ReferenceSha256 $Authority.FileSha256 'Approved candidate lock authority bytes'
    Assert-V02ReleaseGateExactString $document.Value.Authority.OwnerIdentity $Authority.OwnerIdentity 'Approved candidate lock authority owner'
    Assert-V02ReleaseGateExactString $document.Value.Authority.OwnerRole $Authority.OwnerRole 'Approved candidate lock authority role'
    Assert-V02ReleaseGateExactString $document.Value.Authority.Authentication 'TRUSTED_OWNER_PLUS_EXTERNAL_RSA_AUTHENTICATED_RECEIPT' 'Approved candidate lock authority authentication'
    Assert-V02ReleaseGateExactString $document.Value.Authority.IndependentReceiptPath $IndependentReceipt.Path 'Approved candidate lock independent receipt path'
    Assert-V02ReleaseGateEqual $document.Value.Authority.IndependentReceiptSha256 $IndependentReceipt.FileSha256 'Approved candidate lock independent receipt bytes'
    Assert-V02ReleaseGateExactString $document.Value.Authority.IndependentReceiptIdentity $IndependentReceipt.ReviewerIdentity 'Approved candidate lock independent receipt identity'
    Assert-V02ReleaseGateExactString $document.Value.Authority.IndependentReceiptRole $IndependentReceipt.ReviewerRole 'Approved candidate lock independent receipt role'
    Assert-V02ReleaseGateExactString $document.Value.Authority.IndependentReceiptAuthentication $IndependentReceipt.Authentication 'Approved candidate lock independent receipt authentication'
    Assert-V02ReleaseGateExactString $document.Value.Authority.IndependentReceiptTrustAnchorFingerprint $IndependentReceipt.TrustAnchorFingerprint 'Approved candidate lock independent receipt trust anchor fingerprint'
    Assert-V02ReleaseGateExactString $document.Value.Authority.IndependentReceiptSignedPayloadSha256 $IndependentReceipt.SignedPayloadSha256 'Approved candidate lock independent receipt signed payload hash'
    return [pscustomobject][ordered]@{
        Path = $document.Path
        FileSha256 = $document.FileSha256
        SourceCommit = [string]$document.Value.SourceCommit
        SourceTree = [string]$document.Value.SourceTree
        ProfileId = [string]$document.Value.ProfileId
        ProfileFileSha256 = [string]$document.Value.ProfileFileSha256
        ProfileCanonicalSha256 = [string]$document.Value.ProfileCanonicalSha256
        PackageReceiptSha256 = [string]$document.Value.PackageReceiptSha256
        PackageReceiptFileSha256 = [string]$document.Value.PackageReceiptFileSha256
        PackageArchiveSha256 = [string]$document.Value.PackageArchiveSha256
        PackageManifestSha256 = [string]$document.Value.PackageManifestSha256
        PackageAppSha256 = [string]$document.Value.PackageAppSha256
        PackageCoreSha256 = [string]$document.Value.PackageCoreSha256
        RendererManifestSha256 = [string]$document.Value.RendererManifestSha256
        RuntimeMatrixManifestSha256 = [string]$document.Value.RuntimeMatrixManifestSha256
        Issue9CandidateSha256 = [string]$document.Value.Issue9CandidateSha256
        Authority = $Authority
        IndependentReceipt = $IndependentReceipt
        Authentication = 'TRUSTED_OWNER_PLUS_EXTERNAL_RSA_AUTHENTICATED_RECEIPT'
        Result = 'APPROVED_CANDIDATE_ONLY'
    }
}

function New-V02ReleaseGateNotReadyReport {
    param(
        [Parameter(Mandatory = $true)]$Identity,
        [Parameter(Mandatory = $true)][string]$Reason,
        $CandidateLock,
        $Authority
    )

    return [pscustomobject][ordered]@{
        SchemaVersion = 2
        Version = $script:V02ReleaseGateVersion
        Result = 'NOT_READY'
        ReleaseReady = $false
        SourceCommit = $Identity.Commit
        SourceTree = $Identity.Tree
        SourceParents = @($Identity.Parents)
        RepositoryRoot = $Identity.RepositoryRoot
        CandidateLock = if ($null -ne $CandidateLock) { $CandidateLock } else { [pscustomobject][ordered]@{ Status = 'NOT_READY' } }
        AuthorityReference = if ($null -ne $Authority) { $Authority } else { [pscustomobject][ordered]@{ Status = 'NOT_READY' } }
        GateReason = $Reason
        Package = [pscustomobject][ordered]@{ ReceiptSha256 = 'NOT_OBSERVED'; ReceiptFileSha256 = 'NOT_OBSERVED' }
        Renderer = [pscustomobject][ordered]@{ ManifestSha256 = 'NOT_OBSERVED' }
        RuntimeMatrix = [pscustomobject][ordered]@{ ManifestFileSha256 = 'NOT_OBSERVED' }
        GitHub = [pscustomobject][ordered]@{ SnapshotSha256 = 'NOT_OBSERVED' }
        HumanReview = [pscustomobject][ordered]@{ Status = 'NOT_OBSERVED'; Decision = 'NOT_OBSERVED'; Authenticated = $false }
        EvidenceClasses = [pscustomobject][ordered]@{
            Static = [pscustomobject][ordered]@{ Status = 'NOT_READY'; Classification = 'CandidateAuthority'; Credit = 'NONE' }
            Contract = [pscustomobject][ordered]@{ Status = 'NOT_OBSERVED'; Classification = 'Contract'; Credit = 'NONE' }
            Synthetic = [pscustomobject][ordered]@{ Status = 'NOT_OBSERVED'; Classification = 'Synthetic'; Credit = 'NONE' }
            Runtime = [pscustomobject][ordered]@{ Status = 'NOT_OBSERVED'; Classification = 'RuntimeMatrixCandidate'; Credit = 'NONE' }
            Human = [pscustomobject][ordered]@{ Status = 'NOT_OBSERVED'; Classification = 'Human'; Credit = 'NONE' }
            Release = [pscustomobject][ordered]@{ Status = 'NOT_OBSERVED'; Classification = 'Release'; Credit = 'NONE' }
        }
        EvidenceBoundary = [pscustomobject][ordered]@{
            ActualHerdrControlInvoked = $false
            GitHubMutationInvoked = $false
            PackagePublished = $false
            ReleasePublished = $false
            RuntimeObserved = $false
            HumanAuthorityObserved = $false
            ReleaseCredit = $false
        }
    }
}

function Assert-V02ReleaseGatePackageResult {
    param(
        [Parameter(Mandatory = $true)]$Result,
        [Parameter(Mandatory = $true)][string]$ExpectedSourceCommit,
        [Parameter(Mandatory = $true)][string]$ExpectedSourceTree
    )

    $required = @(
        'EvidenceClass', 'Issue', 'ProfileId', 'ReceiptSha256', 'SourceCommit', 'SourceTree',
        'PreparationProfileFileSha256', 'PreparationProfileCanonicalSha256', 'ArchiveSha256',
        'AppSha256', 'CoreSha256', 'ReferenceHostProfileSha256', 'RendererPolicySha256',
        'Runtime', 'Release'
    )
    Assert-V02ReleaseGateExactProperties $Result $required 'Package validator result'
    Assert-V02ReleaseGateExactString $Result.EvidenceClass 'Static/PackagedCompatibilityPreparation' 'Package validator EvidenceClass'
    Assert-V02ReleaseGateInteger $Result.Issue 'Package validator Issue' 149
    Assert-V02ReleaseGateEqual $Result.Issue 149 'Package validator Issue'
    Assert-V02ReleaseGateExactString $Result.ProfileId $script:V02ReleaseGatePackageProfileId 'Package validator ProfileId'
    Assert-V02ReleaseGateGitObjectId $Result.SourceCommit 'Package validator SourceCommit' | Out-Null
    Assert-V02ReleaseGateGitObjectId $Result.SourceTree 'Package validator SourceTree' | Out-Null
    Assert-V02ReleaseGateEqual $Result.SourceCommit $ExpectedSourceCommit 'Package validator source commit'
    Assert-V02ReleaseGateEqual $Result.SourceTree $ExpectedSourceTree 'Package validator source tree'
    foreach ($name in @(
            'ReceiptSha256', 'PreparationProfileFileSha256', 'PreparationProfileCanonicalSha256',
            'ArchiveSha256', 'AppSha256', 'CoreSha256', 'ReferenceHostProfileSha256', 'RendererPolicySha256'
        )) {
        Assert-V02ReleaseGateSha256 $Result.$name "Package validator $name" | Out-Null
    }
    Assert-V02ReleaseGateEqual $Result.ReferenceHostProfileSha256 $script:V02ReleaseGateReferenceHostProfileSha256 'Package validator reference-host profile'
    Assert-V02ReleaseGateEqual $Result.RendererPolicySha256 $script:V02ReleaseGateRendererPolicySha256 'Package validator renderer policy'
    Assert-V02ReleaseGateExactString $Result.Runtime 'NOT OBSERVED' 'Package validator Runtime boundary'
    Assert-V02ReleaseGateExactString $Result.Release 'NOT CLAIMED' 'Package validator Release boundary'
}

function Invoke-V02ReleaseGatePackageValidation {
    param(
        [Parameter(Mandatory = $true)]$Context,
        [Parameter(Mandatory = $true)][string]$ExpectedSourceCommit,
        [Parameter(Mandatory = $true)][string]$ExpectedSourceTree
    )

    $validatorPath = Join-Path $Context.RepositoryRoot 'tools\packaging\v0.2\Test-V02PackageIdentity.ps1'
    if (-not (Test-Path -LiteralPath $validatorPath -PathType Leaf)) {
        throw "Committed v0.2 package validator is missing: $validatorPath"
    }
    Assert-V02ReleaseGateValidatorHeld -Path $validatorPath -Context 'Package validator' | Out-Null
    $firstOutput = @(& $validatorPath -IdentityPath $Context.IdentityPath -ArchivePath $Context.ArchivePath `
        -PackageRoot $Context.PackageRoot -RepositoryRoot $Context.RepositoryRoot -ProfilePath $Context.ProfilePath)
    if ($firstOutput.Count -ne 1) {
        throw 'Committed package validator must return exactly one result.'
    }
    $first = $firstOutput[0]
    Assert-V02ReleaseGatePackageResult $first $ExpectedSourceCommit $ExpectedSourceTree

    $secondOutput = @(& $validatorPath -IdentityPath $Context.IdentityPath -ArchivePath $Context.ArchivePath `
        -PackageRoot $Context.PackageRoot -RepositoryRoot $Context.RepositoryRoot -ProfilePath $Context.ProfilePath)
    if ($secondOutput.Count -ne 1) {
        throw 'Committed package validator returned a different result count on its stability pass.'
    }
    $second = $secondOutput[0]
    Assert-V02ReleaseGatePackageResult $second $ExpectedSourceCommit $ExpectedSourceTree
    foreach ($name in @($first.PSObject.Properties.Name)) {
        Assert-V02ReleaseGateEqual $second.$name $first.$name "Package validator stability '$name'"
    }

    $receiptPath = Resolve-V02ReleaseGateExistingPath -Path $Context.IdentityPath -Type Leaf -Context 'Package identity receipt'
    $archivePath = Resolve-V02ReleaseGateExistingPath -Path $Context.ArchivePath -Type Leaf -Context 'Package ZIP archive'
    $packageRoot = Resolve-V02ReleaseGateExistingPath -Path $Context.PackageRoot -Type Container -Context 'Extracted package root'
    $profilePath = Resolve-V02ReleaseGateExistingPath -Path $Context.ProfilePath -Type Leaf -Context 'Package identity profile'
    $manifestPath = Resolve-V02ReleaseGateExistingPath -Path (Join-Path $packageRoot 'package-manifest.json') -Type Leaf -Context 'Package manifest'
    $appPath = Resolve-V02ReleaseGateExistingPath -Path (Join-Path $packageRoot 'HerdrOps.App.exe') -Type Leaf -Context 'Package App executable'
    $corePath = Resolve-V02ReleaseGateExistingPath -Path (Join-Path $packageRoot 'HerdrOps.Core.exe') -Type Leaf -Context 'Package Core executable'
    $expectedProfilePath = [IO.Path]::GetFullPath((Join-Path $Context.RepositoryRoot 'tools\packaging\v0.2\package-identity-profile.json'))
    if (-not [StringComparer]::OrdinalIgnoreCase.Equals($profilePath, $expectedProfilePath)) {
        throw 'Package identity profile is not the committed v0.2 profile path.'
    }

    $package = [pscustomobject][ordered]@{
        IdentityPath = $receiptPath
        ReceiptFileSha256 = Get-V02ReleaseGateFileSha256 $receiptPath
        ReceiptSha256 = [string]$first.ReceiptSha256
        ArchivePath = $archivePath
        ArchiveSha256 = Get-V02ReleaseGateFileSha256 $archivePath
        PackageRoot = $packageRoot
        ManifestPath = $manifestPath
        ManifestSha256 = Get-V02ReleaseGateFileSha256 $manifestPath
        AppPath = $appPath
        AppSha256 = Get-V02ReleaseGateFileSha256 $appPath
        CorePath = $corePath
        CoreSha256 = Get-V02ReleaseGateFileSha256 $corePath
        ProfilePath = $profilePath
        ProfileFileSha256 = Get-V02ReleaseGateFileSha256 $profilePath
        ProfileCanonicalSha256 = [string]$first.PreparationProfileCanonicalSha256
        ProfileId = [string]$first.ProfileId
        ReferenceHostProfileSha256 = [string]$first.ReferenceHostProfileSha256
        RendererPolicySha256 = [string]$first.RendererPolicySha256
        SourceCommit = [string]$first.SourceCommit
        SourceTree = [string]$first.SourceTree
        EvidenceClass = [string]$first.EvidenceClass
    }
    Assert-V02ReleaseGateEqual $package.ArchiveSha256 $first.ArchiveSha256 'Package archive bytes'
    if ($first.PSObject.Properties.Name -contains 'PackageManifestSha256') {
        Assert-V02ReleaseGateEqual $package.ManifestSha256 $first.PackageManifestSha256 'Package manifest bytes'
    }
    Assert-V02ReleaseGateEqual $package.AppSha256 $first.AppSha256 'Package App bytes'
    Assert-V02ReleaseGateEqual $package.CoreSha256 $first.CoreSha256 'Package Core bytes'
    Assert-V02ReleaseGateEqual $package.ProfileFileSha256 $first.PreparationProfileFileSha256 'Package profile bytes'

    return $package
}

function Assert-V02ReleaseGateRendererResult {
    param(
        [Parameter(Mandatory = $true)]$Result,
        [Parameter(Mandatory = $true)][string]$Context
    )

    $required = @(
        'EvidenceClassification', 'ManifestVersion', 'StructuralValidation', 'BindingValidation',
        'GovernanceProfileConsistency', 'FinalHumanGoAuthority', 'OwnerNumericLimits',
        'HumanReview', 'ActualHerdrRuntime', 'Release', 'CreditGranted',
        'PackagedCompatibilityReadyForIssue149Closure'
    )
    Assert-V02ReleaseGateExactProperties $Result $required "$Context result"
    Assert-V02ReleaseGateExactString $Result.EvidenceClassification 'PackagedCompatibilityCandidate' "$Context EvidenceClassification"
    Assert-V02ReleaseGateInteger $Result.ManifestVersion "$Context ManifestVersion" 1
    Assert-V02ReleaseGateEqual $Result.ManifestVersion 1 "$Context ManifestVersion"
    Assert-V02ReleaseGateExactString $Result.StructuralValidation 'PASS' "$Context StructuralValidation"
    Assert-V02ReleaseGateExactString $Result.BindingValidation 'PASS' "$Context BindingValidation"
    Assert-V02ReleaseGateExactString $Result.GovernanceProfileConsistency 'PASS' "$Context GovernanceProfileConsistency"
    Assert-V02ReleaseGateExactString $Result.FinalHumanGoAuthority 'NOT_OBSERVED' "$Context FinalHumanGoAuthority"
    Assert-V02ReleaseGateExactString $Result.HumanReview 'NOT_OBSERVED' "$Context HumanReview"
    Assert-V02ReleaseGateExactString $Result.ActualHerdrRuntime 'NOT_OBSERVED' "$Context ActualHerdrRuntime"
    Assert-V02ReleaseGateExactString $Result.Release 'NOT_OBSERVED' "$Context Release"
    if (Assert-V02ReleaseGateBoolean $Result.CreditGranted "$Context CreditGranted") {
        throw "$Context cannot grant credit."
    }
    if (Assert-V02ReleaseGateBoolean $Result.PackagedCompatibilityReadyForIssue149Closure "$Context closure readiness") {
        throw "$Context must remain a candidate until the separate Human review is admitted."
    }
    Assert-V02ReleaseGateExactString $Result.OwnerNumericLimits 'APPROVED' "$Context owner numeric limits"
}

function Invoke-V02ReleaseGateRendererValidation {
    param(
        [Parameter(Mandatory = $true)]$Context,
        [Parameter(Mandatory = $true)]$Package,
        [Parameter(Mandatory = $true)][string]$ExpectedSourceCommit,
        [Parameter(Mandatory = $true)][string]$ExpectedSourceTree
    )

    $validatorPath = Join-Path $Context.RepositoryRoot 'tools\v0.2-renderer-compatibility\Test-V02RendererCompatibilityManifest.ps1'
    if (-not (Test-Path -LiteralPath $validatorPath -PathType Leaf)) {
        throw "Committed v0.2 renderer validator is missing: $validatorPath"
    }
    Assert-V02ReleaseGateValidatorHeld -Path $validatorPath -Context 'Renderer validator' | Out-Null
    $manifestPath = Resolve-V02ReleaseGateExistingPath -Path $Context.ManifestPath -Type Leaf -Context 'Renderer compatibility manifest'
    $evidenceRoot = if ([string]::IsNullOrWhiteSpace($Context.EvidenceRoot)) {
        [IO.Path]::GetDirectoryName($manifestPath)
    }
    else {
        Resolve-V02ReleaseGateExistingPath -Path $Context.EvidenceRoot -Type Container -Context 'Renderer evidence root'
    }
    $validatorContext = [pscustomobject][ordered]@{
        ValidatorPath = $validatorPath
        ManifestPath = $manifestPath
        EvidenceRoot = $evidenceRoot
        RepositoryRoot = $Context.RepositoryRoot
    }
    $output = @(& $validatorPath -ManifestPath $validatorContext.ManifestPath -EvidenceRoot $validatorContext.EvidenceRoot `
        -RepositoryRoot $validatorContext.RepositoryRoot)
    if ($output.Count -ne 1) {
        throw 'Committed renderer validator must return exactly one result.'
    }
    $result = $output[0]
    Assert-V02ReleaseGateRendererResult $result 'Renderer compatibility'
    $manifestDocument = Read-V02ReleaseGateJsonFile -Path $manifestPath -Context 'Renderer compatibility manifest binding'
    Assert-V02ReleaseGateExactProperties $manifestDocument.Value @(
        '$id', 'manifestVersion', 'evidenceClassification', 'issue', 'governance', 'candidate',
        'environment', 'rendererEvidence', 'captures', 'references', 'comparison', 'matrices',
        'performanceProtocol', 'review', 'evidenceBoundary'
    ) 'Renderer compatibility manifest binding'
    Assert-V02ReleaseGateExactString $manifestDocument.Value.'$id' 'https://herdrops.local/schema/v0.2/renderer-compatibility-manifest.schema.json' 'Renderer manifest schema ID'
    Assert-V02ReleaseGateInteger $manifestDocument.Value.manifestVersion 'Renderer manifest version' 1
    Assert-V02ReleaseGateExactString $manifestDocument.Value.evidenceClassification 'PackagedCompatibilityCandidate' 'Renderer manifest classification'
    Assert-V02ReleaseGateInteger $manifestDocument.Value.issue 'Renderer manifest issue' 149
    Assert-V02ReleaseGateEqual $manifestDocument.Value.issue 149 'Renderer manifest issue'
    $governance = $manifestDocument.Value.governance
    Assert-V02ReleaseGateExactString $governance.decisionId $script:V02ReleaseGateDecisionId 'Renderer manifest decision ID'
    Assert-V02ReleaseGateExactString $governance.approvalReference $script:V02ReleaseGateDecisionReference 'Renderer manifest decision reference'
    Assert-V02ReleaseGateExactString $governance.decisionPayloadSha256 $script:V02ReleaseGateDecisionPayloadSha256 'Renderer manifest decision payload'
    Assert-V02ReleaseGateExactString $governance.supersedesDecisionId 'herdrops-rec-all-v1' 'Renderer manifest superseded decision'
    Assert-V02ReleaseGateExactString $governance.supersedesPayloadSha256 'DD8EB4D4BC896BE6A4765D409C5E34A16C4DBFB3D70F437EC915A50DF2FC1B1E' 'Renderer manifest superseded payload'
    $candidate = $manifestDocument.Value.candidate
    Assert-V02ReleaseGateEqual $candidate.source.commitSha $ExpectedSourceCommit 'Renderer candidate source commit'
    Assert-V02ReleaseGateEqual $candidate.source.treeSha $ExpectedSourceTree 'Renderer candidate source tree'
    Assert-V02ReleaseGateExactString $candidate.profile.id $script:V02ReleaseGatePackageProfileId 'Renderer candidate package profile ID'
    Assert-V02ReleaseGateEqual $candidate.profile.fileSha256 $Package.ProfileFileSha256 'Renderer candidate profile file hash'
    Assert-V02ReleaseGateEqual $candidate.profile.canonicalSha256 $Package.ProfileCanonicalSha256 'Renderer candidate profile canonical hash'
    Assert-V02ReleaseGateEqual $candidate.receipt.fileSha256 $Package.ReceiptFileSha256 'Renderer candidate receipt file hash'
    Assert-V02ReleaseGateEqual $candidate.receipt.canonicalSha256 $Package.ReceiptSha256 'Renderer candidate receipt canonical hash'
    Assert-V02ReleaseGateEqual $candidate.archive.sha256 $Package.ArchiveSha256 'Renderer candidate archive hash'
    Assert-V02ReleaseGateEqual $candidate.components.app.sha256 $Package.AppSha256 'Renderer candidate App hash'
    Assert-V02ReleaseGateEqual $candidate.components.core.sha256 $Package.CoreSha256 'Renderer candidate Core hash'
    Assert-V02ReleaseGateExactString $candidate.referenceHost.profileId $script:V02ReleaseGateReferenceHostProfileId 'Renderer candidate reference-host ID'
    Assert-V02ReleaseGateEqual $candidate.referenceHost.profileSha256 $script:V02ReleaseGateReferenceHostProfileSha256 'Renderer candidate reference-host hash'
    Assert-V02ReleaseGateExactString $candidate.renderer.policy $script:V02ReleaseGateRendererPolicy 'Renderer candidate policy'
    Assert-V02ReleaseGateExactString $candidate.renderer.wpfProcessRenderMode $script:V02ReleaseGateRendererMode 'Renderer candidate WPF mode'
    Assert-V02ReleaseGateExactString $manifestDocument.Value.review.decision 'NOT_OBSERVED' 'Renderer candidate Human review boundary'
    Assert-V02ReleaseGateExactString $manifestDocument.Value.evidenceBoundary.packagedCompatibility 'CANDIDATE' 'Renderer candidate packaged boundary'
    Assert-V02ReleaseGateExactString $manifestDocument.Value.evidenceBoundary.humanReview 'NOT_OBSERVED' 'Renderer candidate Human boundary'
    Assert-V02ReleaseGateExactString $manifestDocument.Value.evidenceBoundary.actualHerdrRuntime 'NOT_OBSERVED' 'Renderer candidate Runtime boundary'
    Assert-V02ReleaseGateExactString $manifestDocument.Value.evidenceBoundary.release 'NOT_OBSERVED' 'Renderer candidate Release boundary'
    if (Assert-V02ReleaseGateBoolean $manifestDocument.Value.evidenceBoundary.creditGranted 'Renderer candidate credit boundary') {
        throw 'Renderer candidate evidence boundary cannot grant credit.'
    }
    return [pscustomobject][ordered]@{
        ManifestPath = $manifestPath
        EvidenceRoot = $evidenceRoot
        ManifestSha256 = Get-V02ReleaseGateFileSha256 $manifestPath
        Manifest = $manifestDocument.Value
        Result = $result
    }
}

function Assert-V02ReleaseGateMatrixBinding {
    param(
        [Parameter(Mandatory = $true)]$Manifest,
        [Parameter(Mandatory = $true)]$Package,
        [Parameter(Mandatory = $true)][string]$ExpectedSourceCommit,
        [Parameter(Mandatory = $true)][string]$ExpectedSourceTree,
        [Parameter(Mandatory = $true)][string]$Context
    )

    Assert-V02ReleaseGateExactProperties $Manifest @(
        'EvidenceClassification', 'IndependentHumanReview', 'ReleaseCredit',
        'ManifestFormatVersion', 'ManifestHashScope', 'ManifestPayloadSha256', 'Payload'
    ) "$Context manifest"
    Assert-V02ReleaseGateExactString $Manifest.EvidenceClassification 'RuntimeMatrixCandidate' "$Context EvidenceClassification"
    Assert-V02ReleaseGateExactString $Manifest.IndependentHumanReview 'NOT_OBSERVED' "$Context IndependentHumanReview"
    Assert-V02ReleaseGateBoolean $Manifest.ReleaseCredit "$Context ReleaseCredit" | Out-Null
    if ([bool]$Manifest.ReleaseCredit) {
        throw "$Context cannot claim Release credit."
    }
    Assert-V02ReleaseGateInteger $Manifest.ManifestFormatVersion "$Context ManifestFormatVersion" 1
    Assert-V02ReleaseGateEqual $Manifest.ManifestFormatVersion 1 "$Context ManifestFormatVersion"
    Assert-V02ReleaseGateExactString $Manifest.ManifestHashScope $script:V02ReleaseGateMatrixHashScope "$Context ManifestHashScope"
    $payloadHash = Assert-V02ReleaseGateSha256 $Manifest.ManifestPayloadSha256 "$Context ManifestPayloadSha256"
    $payload = $Manifest.Payload
    Assert-V02ReleaseGateExactProperties $payload @('GeneratedUnixTimeMilliseconds', 'IndependentHumanReview', 'ReleaseCredit', 'Binding', 'Runs') "$Context payload"
    Assert-V02ReleaseGateInteger $payload.GeneratedUnixTimeMilliseconds "$Context payload GeneratedUnixTimeMilliseconds" 0
    Assert-V02ReleaseGateExactString $payload.IndependentHumanReview 'NOT_OBSERVED' "$Context payload IndependentHumanReview"
    if (Assert-V02ReleaseGateBoolean $payload.ReleaseCredit "$Context payload ReleaseCredit") {
        throw "$Context payload cannot claim Release credit."
    }
    $payloadCanonical = ConvertTo-V02Jcs $payload
    $payloadComputed = (Get-V02Sha256Hex -Bytes ([Text.UTF8Encoding]::new($false).GetBytes($payloadCanonical)))
    Assert-V02ReleaseGateEqual $payloadComputed $payloadHash "$Context payload hash"

    $binding = $payload.Binding
    Assert-V02ReleaseGateExactProperties $binding @(
        'SourceCommit', 'SourceTree', 'ProfileId', 'ProfileSha256', 'ReferenceHostSchemaSha256',
        'PackageIdentityReceiptSha256', 'HerdrReleaseId', 'HerdrExecutableSha256',
        'AppExecutableSha256', 'CoreExecutableSha256', 'BundledSchemaSha256', 'HerdrProtocol'
    ) "$Context binding"
    Assert-V02ReleaseGateGitObjectId $binding.SourceCommit "$Context binding SourceCommit" | Out-Null
    Assert-V02ReleaseGateGitObjectId $binding.SourceTree "$Context binding SourceTree" | Out-Null
    Assert-V02ReleaseGateEqual $binding.SourceCommit $ExpectedSourceCommit "$Context binding source commit"
    Assert-V02ReleaseGateEqual $binding.SourceTree $ExpectedSourceTree "$Context binding source tree"
    Assert-V02ReleaseGateExactString $binding.ProfileId $script:V02ReleaseGateReferenceHostProfileId "$Context binding ProfileId"
    Assert-V02ReleaseGateSha256 $binding.ProfileSha256 "$Context binding ProfileSha256" | Out-Null
    Assert-V02ReleaseGateEqual $binding.ProfileSha256 $script:V02ReleaseGateReferenceHostProfileSha256 "$Context binding ProfileSha256"
    Assert-V02ReleaseGateSha256 $binding.ReferenceHostSchemaSha256 "$Context binding ReferenceHostSchemaSha256" | Out-Null
    Assert-V02ReleaseGateEqual $binding.ReferenceHostSchemaSha256 $script:V02ReleaseGateReferenceHostSchemaSha256 "$Context binding ReferenceHostSchemaSha256"
    Assert-V02ReleaseGateSha256 $binding.PackageIdentityReceiptSha256 "$Context binding PackageIdentityReceiptSha256" | Out-Null
    Assert-V02ReleaseGateEqual $binding.PackageIdentityReceiptSha256 $Package.ReceiptSha256 "$Context binding package receipt"
    Assert-V02ReleaseGateExactString $binding.HerdrReleaseId $script:V02ReleaseGateHerdrReleaseId "$Context binding HerdrReleaseId"
    Assert-V02ReleaseGateSha256 $binding.HerdrExecutableSha256 "$Context binding HerdrExecutableSha256" | Out-Null
    Assert-V02ReleaseGateEqual $binding.HerdrExecutableSha256 $script:V02ReleaseGateHerdrExecutableSha256 "$Context binding HerdrExecutableSha256"
    Assert-V02ReleaseGateEqual $binding.AppExecutableSha256 $Package.AppSha256 "$Context binding App executable"
    Assert-V02ReleaseGateEqual $binding.CoreExecutableSha256 $Package.CoreSha256 "$Context binding Core executable"
    Assert-V02ReleaseGateSha256 $binding.BundledSchemaSha256 "$Context binding BundledSchemaSha256" | Out-Null
    Assert-V02ReleaseGateInteger $binding.HerdrProtocol "$Context binding HerdrProtocol" 1 | Out-Null

    $runs = @($payload.Runs)
    if ($runs.Count -ne 2) {
        throw "$Context must contain exactly two language runs."
    }
    $expectedLanguages = @('Thai', 'English')
    $captureRoots = New-Object System.Collections.Generic.List[string]
    for ($index = 0; $index -lt $runs.Count; $index++) {
        $run = $runs[$index]
        Assert-V02ReleaseGateExactProperties $run @(
            'Language', 'Culture', 'EvidenceDirectory', 'CaptureRoot', 'GateReportSha256',
            'AppRuntimeReportSha256', 'CoreRuntimeReportSha256', 'ProgressHistorySha256',
            'ProgressHistoryLastEntrySha256', 'PackageIdentityReceiptSha256', 'SourceCommit',
            'SourceTree', 'ProfileId', 'ProfileSha256', 'ReferenceHostSchemaSha256',
            'HerdrReleaseId', 'HerdrExecutableSha256', 'AppExecutableSha256',
            'CoreExecutableSha256', 'BundledSchemaSha256', 'HerdrProtocol',
            'RendererPolicyId', 'WpfProcessRenderMode', 'CaptureCount', 'Captures'
        ) "$Context run $index"
        Assert-V02ReleaseGateExactString $run.Language $expectedLanguages[$index] "$Context run $index Language"
        $expectedCulture = if ($index -eq 0) { 'th-TH' } else { 'en-US' }
        Assert-V02ReleaseGateExactString $run.Culture $expectedCulture "$Context run $index Culture"
        foreach ($pathName in @('EvidenceDirectory', 'CaptureRoot')) {
            $pathValue = Assert-V02ReleaseGateString $run.$pathName "$Context run $index $pathName"
            if (-not [IO.Path]::IsPathRooted($pathValue)) {
                throw "$Context run $index $pathName must be absolute."
            }
            [void]$captureRoots.Add([IO.Path]::GetFullPath($pathValue).TrimEnd([char[]]@('\', '/')))
        }
        foreach ($name in @(
                'GateReportSha256', 'AppRuntimeReportSha256', 'CoreRuntimeReportSha256',
                'ProgressHistorySha256', 'ProgressHistoryLastEntrySha256', 'PackageIdentityReceiptSha256',
                'ProfileSha256', 'ReferenceHostSchemaSha256', 'HerdrExecutableSha256',
                'AppExecutableSha256', 'CoreExecutableSha256', 'BundledSchemaSha256'
            )) {
            Assert-V02ReleaseGateSha256 $run.$name "$Context run $index $name" | Out-Null
        }
        Assert-V02ReleaseGateEqual $run.SourceCommit $ExpectedSourceCommit "$Context run $index SourceCommit"
        Assert-V02ReleaseGateEqual $run.SourceTree $ExpectedSourceTree "$Context run $index SourceTree"
        Assert-V02ReleaseGateEqual $run.PackageIdentityReceiptSha256 $Package.ReceiptSha256 "$Context run $index package receipt"
        Assert-V02ReleaseGateEqual $run.AppExecutableSha256 $Package.AppSha256 "$Context run $index App executable"
        Assert-V02ReleaseGateEqual $run.CoreExecutableSha256 $Package.CoreSha256 "$Context run $index Core executable"
        Assert-V02ReleaseGateEqual $run.ProfileId $script:V02ReleaseGateReferenceHostProfileId "$Context run $index ProfileId"
        Assert-V02ReleaseGateEqual $run.ProfileSha256 $script:V02ReleaseGateReferenceHostProfileSha256 "$Context run $index ProfileSha256"
        Assert-V02ReleaseGateEqual $run.ReferenceHostSchemaSha256 $script:V02ReleaseGateReferenceHostSchemaSha256 "$Context run $index ReferenceHostSchemaSha256"
        Assert-V02ReleaseGateEqual $run.HerdrReleaseId $script:V02ReleaseGateHerdrReleaseId "$Context run $index HerdrReleaseId"
        Assert-V02ReleaseGateEqual $run.HerdrExecutableSha256 $script:V02ReleaseGateHerdrExecutableSha256 "$Context run $index HerdrExecutableSha256"
        Assert-V02ReleaseGateEqual $run.RendererPolicyId $script:V02ReleaseGateRendererPolicy "$Context run $index RendererPolicyId"
        Assert-V02ReleaseGateEqual $run.WpfProcessRenderMode $script:V02ReleaseGateRendererMode "$Context run $index WpfProcessRenderMode"
        Assert-V02ReleaseGateInteger $run.HerdrProtocol "$Context run $index HerdrProtocol" 1 | Out-Null
        Assert-V02ReleaseGateInteger $run.CaptureCount "$Context run $index CaptureCount" 8
        if ([int64]$run.CaptureCount -ne 8 -or @($run.Captures).Count -ne 8) {
            throw "$Context run $index must contain exactly eight runtime captures."
        }
    }
    Assert-V02ReleaseGateDistinctSet -Values $captureRoots.ToArray() -Context "$Context evidence/capture roots"
    return $payload
}

function Copy-V02ReleaseGateObject {
    param([Parameter(Mandatory = $true)]$Object)

    return (($Object | ConvertTo-Json -Depth 100) | ConvertFrom-Json)
}

function Get-V02ReleaseGateNormalizedMatrixPayload {
    param([Parameter(Mandatory = $true)]$Manifest)

    $copy = Copy-V02ReleaseGateObject $Manifest.Payload
    $copy.GeneratedUnixTimeMilliseconds = [int64]0
    return ConvertTo-V02Jcs $copy
}

function Invoke-V02ReleaseGateMatrixValidation {
    param(
        [Parameter(Mandatory = $true)]$Context,
        [Parameter(Mandatory = $true)]$Package,
        [Parameter(Mandatory = $true)][string]$ExpectedSourceCommit,
        [Parameter(Mandatory = $true)][string]$ExpectedSourceTree,
        [Parameter(Mandatory = $true)][string]$RuntimeMatrixManifestPath
    )

    $manifestDocument = Read-V02ReleaseGateJsonFile -Path $RuntimeMatrixManifestPath -Context 'Runtime language matrix manifest'
    $candidate = $manifestDocument.Value
    Assert-V02ReleaseGateMatrixBinding $candidate $Package $ExpectedSourceCommit $ExpectedSourceTree 'Runtime language matrix' | Out-Null

    $validatorPath = Join-Path $Context.RepositoryRoot 'tools\Test-V02LanguageMatrixAcceptance.ps1'
    if (-not (Test-Path -LiteralPath $validatorPath -PathType Leaf)) {
        throw "Committed v0.2 language-matrix validator is missing: $validatorPath"
    }
    Assert-V02ReleaseGateValidatorHeld -Path $validatorPath -Context 'Language-matrix validator' | Out-Null
    $validatorContext = [pscustomobject][ordered]@{
        ValidatorPath = $validatorPath
        ThaiEvidenceDirectory = $Context.ThaiEvidenceDirectory
        EnglishEvidenceDirectory = $Context.EnglishEvidenceDirectory
        PackageIdentityPath = $Package.IdentityPath
        PackageArchivePath = $Package.ArchivePath
        ExtractedPackageRoot = $Package.PackageRoot
        RepositoryRoot = $Context.RepositoryRoot
        PackageProfilePath = $Package.ProfilePath
    }
    $generated = $null
    $temporary = Join-Path ([IO.Path]::GetTempPath()) ('.herdrops-v02-matrix-' + [Guid]::NewGuid().ToString('N') + '.json')
    try {
        $output = @(& $validatorPath `
            -ThaiEvidenceDirectory $Context.ThaiEvidenceDirectory `
            -EnglishEvidenceDirectory $Context.EnglishEvidenceDirectory `
            -PackageIdentityPath $Package.IdentityPath `
            -PackageArchivePath $Package.ArchivePath `
            -ExtractedPackageRoot $Package.PackageRoot `
            -RepositoryRoot $Context.RepositoryRoot `
            -PackageProfilePath $Package.ProfilePath `
            -OutputPath $temporary)
        if ($LASTEXITCODE -ne 0) {
            throw "Committed language-matrix validator exited with $LASTEXITCODE."
        }
        $generated = (Read-V02ReleaseGateJsonFile -Path $temporary -Context 'Generated runtime language matrix candidate').Value
    }
    finally {
        if ($null -ne $temporary -and (Test-Path -LiteralPath $temporary)) {
            Remove-Item -LiteralPath $temporary -Force
        }
    }
    Assert-V02ReleaseGateMatrixBinding $generated $Package $ExpectedSourceCommit $ExpectedSourceTree 'Independently regenerated runtime language matrix' | Out-Null
    Assert-V02ReleaseGateEqual (Get-V02ReleaseGateNormalizedMatrixPayload $candidate) `
        (Get-V02ReleaseGateNormalizedMatrixPayload $generated) 'Runtime language matrix stable payload'
    return [pscustomobject][ordered]@{
        ManifestPath = $manifestDocument.Path
        ManifestFileSha256 = $manifestDocument.FileSha256
        ManifestPayloadSha256 = [string]$candidate.ManifestPayloadSha256
        Candidate = $candidate
    }
}

function Assert-V02ReleaseGateIssue9CandidateBinding {
    param(
        [Parameter(Mandatory = $true)]$Candidate,
        [Parameter(Mandatory = $true)]$Context,
        [Parameter(Mandatory = $true)]$Package,
        [Parameter(Mandatory = $true)]$Matrix,
        [Parameter(Mandatory = $true)][string]$ExpectedSourceCommit,
        [Parameter(Mandatory = $true)][string]$ExpectedSourceTree,
        [string]$Description = 'Issue #9 runtime candidate'
    )

    Assert-V02ReleaseGateExactProperties $Candidate @(
        'SchemaVersion', 'EvidenceClassification', 'Issue', 'Result', 'Source', 'Package',
        'Herdr', 'Sessions', 'MatrixCandidate', 'Languages', 'EvidenceBoundary'
    ) $Description
    Assert-V02ReleaseGateInteger $Candidate.SchemaVersion "$Description SchemaVersion" 1
    Assert-V02ReleaseGateEqual $Candidate.SchemaVersion 1 "$Description SchemaVersion"
    Assert-V02ReleaseGateExactString $Candidate.EvidenceClassification 'Issue9RuntimeCandidate' "$Description classification"
    Assert-V02ReleaseGateInteger $Candidate.Issue "$Description Issue" 9
    Assert-V02ReleaseGateEqual $Candidate.Issue 9 "$Description Issue"
    Assert-V02ReleaseGateExactString $Candidate.Result 'PASS' "$Description Result"

    Assert-V02ReleaseGateExactProperties $Candidate.Source @('CommitSha', 'TreeSha', 'GitTreeClean') "$Description Source"
    Assert-V02ReleaseGateEqual $Candidate.Source.CommitSha $ExpectedSourceCommit "$Description source commit"
    Assert-V02ReleaseGateEqual $Candidate.Source.TreeSha $ExpectedSourceTree "$Description source tree"
    if (-not (Assert-V02ReleaseGateBoolean $Candidate.Source.GitTreeClean "$Description GitTreeClean")) {
        throw "$Description requires a clean source tree."
    }

    $packageNames = @(
        'IdentityPath', 'IdentityFileSha256', 'ReceiptSha256', 'ArchivePath', 'ArchiveSha256',
        'ManifestPath', 'ManifestSha256', 'AppPath', 'AppSha256', 'CorePath', 'CoreSha256'
    )
    Assert-V02ReleaseGateExactProperties $Candidate.Package $packageNames "$Description Package"
    foreach ($name in @('IdentityFileSha256', 'ReceiptSha256', 'ArchiveSha256', 'ManifestSha256', 'AppSha256', 'CoreSha256')) {
        Assert-V02ReleaseGateSha256 $Candidate.Package.$name "$Description Package.$name" | Out-Null
    }
    foreach ($binding in @(
            [pscustomobject]@{ Name = 'IdentityPath'; Actual = $Candidate.Package.IdentityPath; Expected = $Package.IdentityPath; Path = $true }
            [pscustomobject]@{ Name = 'IdentityFileSha256'; Actual = $Candidate.Package.IdentityFileSha256; Expected = $Package.ReceiptFileSha256 }
            [pscustomobject]@{ Name = 'ReceiptSha256'; Actual = $Candidate.Package.ReceiptSha256; Expected = $Package.ReceiptSha256 }
            [pscustomobject]@{ Name = 'ArchivePath'; Actual = $Candidate.Package.ArchivePath; Expected = $Package.ArchivePath; Path = $true }
            [pscustomobject]@{ Name = 'ArchiveSha256'; Actual = $Candidate.Package.ArchiveSha256; Expected = $Package.ArchiveSha256 }
            [pscustomobject]@{ Name = 'ManifestPath'; Actual = $Candidate.Package.ManifestPath; Expected = $Package.ManifestPath; Path = $true }
            [pscustomobject]@{ Name = 'ManifestSha256'; Actual = $Candidate.Package.ManifestSha256; Expected = $Package.ManifestSha256 }
            [pscustomobject]@{ Name = 'AppPath'; Actual = $Candidate.Package.AppPath; Expected = $Package.AppPath; Path = $true }
            [pscustomobject]@{ Name = 'AppSha256'; Actual = $Candidate.Package.AppSha256; Expected = $Package.AppSha256 }
            [pscustomobject]@{ Name = 'CorePath'; Actual = $Candidate.Package.CorePath; Expected = $Package.CorePath; Path = $true }
            [pscustomobject]@{ Name = 'CoreSha256'; Actual = $Candidate.Package.CoreSha256; Expected = $Package.CoreSha256 }
        )) {
        $actual = if ($binding.PSObject.Properties.Name -contains 'Path') { [IO.Path]::GetFullPath([string]$binding.Actual) } else { [string]$binding.Actual }
        $expected = if ($binding.PSObject.Properties.Name -contains 'Path') { [IO.Path]::GetFullPath([string]$binding.Expected) } else { [string]$binding.Expected }
        Assert-V02ReleaseGateEqual $actual $expected "$Description package $($binding.Name)"
    }

    $matrixBinding = $Matrix.Candidate.Payload.Binding
    Assert-V02ReleaseGateExactProperties $Candidate.Herdr @('ReleaseId', 'ExecutableSha256', 'BundledSchemaSha256', 'Protocol') "$Description Herdr"
    Assert-V02ReleaseGateEqual $Candidate.Herdr.ReleaseId $matrixBinding.HerdrReleaseId "$Description Herdr release"
    Assert-V02ReleaseGateEqual $Candidate.Herdr.ExecutableSha256 $matrixBinding.HerdrExecutableSha256 "$Description Herdr executable"
    Assert-V02ReleaseGateEqual $Candidate.Herdr.BundledSchemaSha256 $matrixBinding.BundledSchemaSha256 "$Description Herdr schema"
    Assert-V02ReleaseGateEqual ([string]$Candidate.Herdr.Protocol) ([string]$matrixBinding.HerdrProtocol) "$Description Herdr protocol"

    Assert-V02ReleaseGateExactProperties $Candidate.Sessions @('Control', 'Target') "$Description Sessions"
    Assert-V02ReleaseGateExactProperties $Candidate.Sessions.Control @('Name', 'SocketPath', 'ServerIdentity') "$Description control session"
    Assert-V02ReleaseGateExactProperties $Candidate.Sessions.Target @('Name', 'SocketPath', 'Reference') "$Description target session"
    foreach ($value in @($Candidate.Sessions.Control.Name, $Candidate.Sessions.Control.SocketPath, $Candidate.Sessions.Control.ServerIdentity,
            $Candidate.Sessions.Target.Name, $Candidate.Sessions.Target.SocketPath, $Candidate.Sessions.Target.Reference)) {
        Assert-V02ReleaseGateString $value "$Description session value" | Out-Null
    }
    Assert-V02ReleaseGateDistinctSet -Values @($Candidate.Sessions.Control.Name, $Candidate.Sessions.Target.Name) -Context "$Description session names"
    Assert-V02ReleaseGateDistinctSet -Values @($Candidate.Sessions.Control.SocketPath, $Candidate.Sessions.Target.SocketPath) -Context "$Description session sockets"

    Assert-V02ReleaseGateExactProperties $Candidate.MatrixCandidate @(
        'Path', 'FileSha256', 'PayloadSha256', 'EvidenceClassification', 'IndependentHumanReview', 'ReleaseCredit'
    ) "$Description MatrixCandidate"
    Assert-V02ReleaseGateEqual ([IO.Path]::GetFullPath([string]$Candidate.MatrixCandidate.Path)) ([IO.Path]::GetFullPath([string]$Matrix.ManifestPath)) "$Description matrix path"
    Assert-V02ReleaseGateEqual $Candidate.MatrixCandidate.FileSha256 $Matrix.ManifestFileSha256 "$Description matrix file hash"
    Assert-V02ReleaseGateEqual $Candidate.MatrixCandidate.PayloadSha256 $Matrix.ManifestPayloadSha256 "$Description matrix payload hash"
    Assert-V02ReleaseGateExactString $Candidate.MatrixCandidate.EvidenceClassification 'RuntimeMatrixCandidate' "$Description matrix classification"
    Assert-V02ReleaseGateExactString $Candidate.MatrixCandidate.IndependentHumanReview 'NOT_OBSERVED' "$Description matrix Human boundary"
    if (Assert-V02ReleaseGateBoolean $Candidate.MatrixCandidate.ReleaseCredit "$Description matrix ReleaseCredit") { throw "$Description matrix cannot grant Release credit." }

    $languages = @($Candidate.Languages)
    if ($languages.Count -ne 2) { throw "$Description must contain exactly Thai and English language legs." }
    $expectedLanguages = @('Thai', 'English')
    $expectedRuntimeRoots = @($Context.ThaiEvidenceDirectory, $Context.EnglishEvidenceDirectory)
    for ($index = 0; $index -lt 2; $index++) {
        $leg = $languages[$index]
        Assert-V02ReleaseGateExactProperties $leg @(
            'Language', 'RuntimeEvidenceDirectory', 'UiEvidenceDirectory', 'UiReceiptPath',
            'UiReceiptSha256', 'SideBySideCaptureSha256', 'Pages', 'Selection', 'Lifecycle'
        ) "$Description language leg $index"
        Assert-V02ReleaseGateExactString $leg.Language $expectedLanguages[$index] "$Description language leg $index Language"
        Assert-V02ReleaseGateEqual ([IO.Path]::GetFullPath([string]$leg.RuntimeEvidenceDirectory)) ([IO.Path]::GetFullPath([string]$expectedRuntimeRoots[$index])) "$Description language leg $index runtime root"
        $uiRoot = Resolve-V02ReleaseGateExistingPath -Path ([string]$leg.UiEvidenceDirectory) -Type Container -Context "$Description language leg $index UI root"
        Assert-V02ReleaseGatePathWithinRoot -Path $uiRoot -Root $Context.ReleaseEvidenceRoot -Context "$Description language leg $index UI root" | Out-Null
        $uiReceipt = Resolve-V02ReleaseGateExistingPath -Path ([string]$leg.UiReceiptPath) -Type Leaf -Context "$Description language leg $index UI receipt"
        Assert-V02ReleaseGatePathWithinRoot -Path $uiReceipt -Root $uiRoot -Context "$Description language leg $index UI receipt" | Out-Null
        Assert-V02ReleaseGateSha256 $leg.UiReceiptSha256 "$Description language leg $index UI receipt hash" | Out-Null
        Assert-V02ReleaseGateSha256 $leg.SideBySideCaptureSha256 "$Description language leg $index side-by-side hash" | Out-Null
        if (@($leg.Pages).Count -ne 3) { throw "$Description language leg $index must contain exactly three pages." }
        $expectedPages = @('Overview', 'LiveOrganization', 'AgentDetail')
        for ($pageIndex = 0; $pageIndex -lt 3; $pageIndex++) {
            $page = $leg.Pages[$pageIndex]
            Assert-V02ReleaseGateExactProperties $page @('Name', 'Language', 'UiCapturePath', 'UiCaptureSha256', 'StateSha256', 'WorkspaceId', 'ProjectId', 'AgentId', 'TaskId', 'AgentStatus', 'PaneId') "$Description language leg $index page $pageIndex"
            Assert-V02ReleaseGateExactString $page.Name $expectedPages[$pageIndex] "$Description language leg $index page name"
            Assert-V02ReleaseGateExactString $page.Language $expectedLanguages[$index] "$Description language leg $index page language"
            foreach ($name in @('UiCaptureSha256', 'StateSha256')) { Assert-V02ReleaseGateSha256 $page.$name "$Description language leg $index page $name" | Out-Null }
            $captureInput = Assert-V02ReleaseGateString $page.UiCapturePath "$Description language leg $index page $pageIndex UI capture path"
            if (-not [IO.Path]::IsPathRooted($captureInput)) {
                throw "$Description language leg $index page $pageIndex UI capture path must be absolute."
            }
            $captureCanonical = Resolve-V02ReleaseGateExistingPath -Path $captureInput -Type Leaf -Context "$Description language leg $index page $pageIndex UI capture"
            Assert-V02ReleaseGatePathWithinRoot -Path $captureCanonical -Root $uiRoot -Context "$Description language leg $index page $pageIndex UI capture" | Out-Null
            $declaredCanonical = $captureInput.TrimEnd([char[]]@('\', '/'))
            if (-not [StringComparer]::OrdinalIgnoreCase.Equals($declaredCanonical, $captureCanonical)) {
                throw "$Description language leg $index page $pageIndex UI capture path is not canonical. Declared='$captureInput' Canonical='$captureCanonical'."
            }
            $captureSnapshot = Get-V02ReleaseGateStableFileSnapshot -Path $captureCanonical -Context "$Description language leg $index page $pageIndex UI capture"
            if ($captureSnapshot.LinkCount -ne 1) {
                throw "$Description language leg $index page $pageIndex UI capture is a hardlink/path alias."
            }
            Assert-V02ReleaseGateEqual $captureSnapshot.Sha256 $page.UiCaptureSha256 "$Description language leg $index page $pageIndex UI capture hash"
        }
        Assert-V02ReleaseGateExactProperties $leg.Selection @('WorkspaceId', 'ProjectId', 'AgentId', 'TaskId', 'AgentStatus', 'PaneId', 'StateSha256', 'Source') "$Description language leg $index Selection"
        Assert-V02ReleaseGateExactString $leg.Selection.Source 'CoreSnapshot' "$Description language leg $index Selection.Source"
        Assert-V02ReleaseGateSha256 $leg.Selection.StateSha256 "$Description language leg $index Selection.StateSha256" | Out-Null
        Assert-V02ReleaseGateExactProperties $leg.Lifecycle @('DashboardClosed', 'CoreConnectedAfterDashboardClose', 'DisconnectObserved', 'ReconnectObserved', 'ReconciliationObserved', 'EventAStateSha256', 'EventBStateSha256', 'ReconciledStateSha256', 'ControlServerSurvivedTargetRestart') "$Description language leg $index Lifecycle"
        foreach ($name in @('DashboardClosed', 'CoreConnectedAfterDashboardClose', 'DisconnectObserved', 'ReconnectObserved', 'ReconciliationObserved', 'ControlServerSurvivedTargetRestart')) {
            if (-not (Assert-V02ReleaseGateBoolean $leg.Lifecycle.$name "$Description language leg $index Lifecycle.$name")) { throw "$Description language leg $index Lifecycle.$name must be true." }
        }
        foreach ($name in @('EventAStateSha256', 'EventBStateSha256', 'ReconciledStateSha256')) { Assert-V02ReleaseGateSha256 $leg.Lifecycle.$name "$Description language leg $index Lifecycle.$name" | Out-Null }
    }

    Assert-V02ReleaseGateExactProperties $Candidate.EvidenceBoundary @('Runtime', 'HumanVisual', 'ReleaseCredit', 'OutputAuthority', 'FixtureMode') "$Description EvidenceBoundary"
    Assert-V02ReleaseGateExactString $Candidate.EvidenceBoundary.Runtime 'NOT_OBSERVED' "$Description Runtime boundary"
    Assert-V02ReleaseGateExactString $Candidate.EvidenceBoundary.HumanVisual 'NOT_OBSERVED' "$Description Human boundary"
    Assert-V02ReleaseGateExactString $Candidate.EvidenceBoundary.OutputAuthority 'RuntimeCandidate' "$Description output authority"
    if (Assert-V02ReleaseGateBoolean $Candidate.EvidenceBoundary.ReleaseCredit "$Description ReleaseCredit") { throw "$Description cannot grant Release credit." }
    if (Assert-V02ReleaseGateBoolean $Candidate.EvidenceBoundary.FixtureMode "$Description FixtureMode") { throw "$Description production ingestion rejects fixture mode." }
}

function Invoke-V02ReleaseGateIssue9Validation {
    param(
        [Parameter(Mandatory = $true)]$Context,
        [Parameter(Mandatory = $true)]$Package,
        [Parameter(Mandatory = $true)]$Matrix,
        [Parameter(Mandatory = $true)][string]$ExpectedSourceCommit,
        [Parameter(Mandatory = $true)][string]$ExpectedSourceTree,
        [Parameter(Mandatory = $true)][string]$Issue9CandidatePath
    )

    $candidateDocument = Read-V02ReleaseGateJsonFile -Path $Issue9CandidatePath -Context 'Issue #9 runtime candidate'
    Assert-V02ReleaseGateIssue9CandidateBinding -Candidate $candidateDocument.Value -Context $Context -Package $Package -Matrix $Matrix `
        -ExpectedSourceCommit $ExpectedSourceCommit -ExpectedSourceTree $ExpectedSourceTree
    $validatorPath = Join-Path $Context.RepositoryRoot 'tools\v0.2-issue9-live-ui\Test-V02Issue9LiveUiAcceptance.ps1'
    Assert-V02ReleaseGateValidatorHeld -Path $validatorPath -Context 'Issue #9 production validator' | Out-Null
    $temporary = Join-Path ([IO.Path]::GetTempPath()) ('.herdrops-v02-issue9-' + [Guid]::NewGuid().ToString('N') + '.json')
    try {
        $languages = @($candidateDocument.Value.Languages)
        $null = @(& $validatorPath `
            -ThaiRuntimeEvidenceDirectory $Context.ThaiEvidenceDirectory `
            -EnglishRuntimeEvidenceDirectory $Context.EnglishEvidenceDirectory `
            -ThaiUiEvidenceDirectory ([string]$languages[0].UiEvidenceDirectory) `
            -EnglishUiEvidenceDirectory ([string]$languages[1].UiEvidenceDirectory) `
            -MatrixCandidatePath $Matrix.ManifestPath `
            -PackageIdentityPath $Package.IdentityPath `
            -PackageArchivePath $Package.ArchivePath `
            -ExtractedPackageRoot $Package.PackageRoot `
            -RepositoryRoot $Context.RepositoryRoot `
            -ExpectedSourceCommit $ExpectedSourceCommit `
            -ExpectedSourceTree $ExpectedSourceTree `
            -OutputPath $temporary)
        $generatedDocument = Read-V02ReleaseGateJsonFile -Path $temporary -Context 'Independently regenerated Issue #9 runtime candidate'
        Assert-V02ReleaseGateIssue9CandidateBinding -Candidate $generatedDocument.Value -Context $Context -Package $Package -Matrix $Matrix `
            -ExpectedSourceCommit $ExpectedSourceCommit -ExpectedSourceTree $ExpectedSourceTree -Description 'Independently regenerated Issue #9 runtime candidate'
        Assert-V02ReleaseGateEqual (ConvertTo-V02Jcs $candidateDocument.Value) (ConvertTo-V02Jcs $generatedDocument.Value) 'Issue #9 independently regenerated candidate bytes'
    }
    finally {
        if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary -Force }
    }
    return [pscustomobject][ordered]@{
        CandidatePath = $candidateDocument.Path
        CandidateSha256 = $candidateDocument.FileSha256
        Candidate = $candidateDocument.Value
        Result = 'PASS_CANDIDATE_ONLY'
        Runtime = 'NOT_OBSERVED'
        Human = 'NOT_OBSERVED'
        Release = 'NOT_OBSERVED'
    }
}

function Assert-V02ReleaseGateCandidateByteBinding {
    param(
        [Parameter(Mandatory = $true)]$CandidateLock,
        [Parameter(Mandatory = $true)]$Package,
        [Parameter(Mandatory = $true)]$Renderer,
        [Parameter(Mandatory = $true)]$Matrix,
        [Parameter(Mandatory = $true)]$Issue9
    )

    foreach ($binding in @(
            [pscustomobject]@{ Name = 'PackageReceiptSha256'; Actual = $Package.ReceiptSha256; Expected = $CandidateLock.PackageReceiptSha256 }
            [pscustomobject]@{ Name = 'PackageReceiptFileSha256'; Actual = $Package.ReceiptFileSha256; Expected = $CandidateLock.PackageReceiptFileSha256 }
            [pscustomobject]@{ Name = 'PackageArchiveSha256'; Actual = $Package.ArchiveSha256; Expected = $CandidateLock.PackageArchiveSha256 }
            [pscustomobject]@{ Name = 'PackageManifestSha256'; Actual = $Package.ManifestSha256; Expected = $CandidateLock.PackageManifestSha256 }
            [pscustomobject]@{ Name = 'PackageAppSha256'; Actual = $Package.AppSha256; Expected = $CandidateLock.PackageAppSha256 }
            [pscustomobject]@{ Name = 'PackageCoreSha256'; Actual = $Package.CoreSha256; Expected = $CandidateLock.PackageCoreSha256 }
            [pscustomobject]@{ Name = 'RendererManifestSha256'; Actual = $Renderer.ManifestSha256; Expected = $CandidateLock.RendererManifestSha256 }
            [pscustomobject]@{ Name = 'RuntimeMatrixManifestSha256'; Actual = $Matrix.ManifestFileSha256; Expected = $CandidateLock.RuntimeMatrixManifestSha256 }
            [pscustomobject]@{ Name = 'Issue9CandidateSha256'; Actual = $Issue9.CandidateSha256; Expected = $CandidateLock.Issue9CandidateSha256 }
        )) {
        Assert-V02ReleaseGateEqual $binding.Actual $binding.Expected "Approved candidate lock $($binding.Name)"
    }
}

function Assert-V02ReleaseGateIndependentReceiptBinding {
    param(
        [Parameter(Mandatory = $true)]$IndependentReceipt,
        [Parameter(Mandatory = $true)]$CandidateLock,
        [Parameter(Mandatory = $true)]$Identity,
        [Parameter(Mandatory = $true)]$Package,
        [Parameter(Mandatory = $true)]$Renderer,
        [Parameter(Mandatory = $true)]$Matrix,
        [Parameter(Mandatory = $true)]$Issue9
    )

    Assert-V02ReleaseGateEqual $IndependentReceipt.Candidate.SourceCommit $Identity.Commit 'External independent receipt source commit'
    Assert-V02ReleaseGateEqual $IndependentReceipt.Candidate.SourceTree $Identity.Tree 'External independent receipt source tree'
    foreach ($binding in @(
            [pscustomobject]@{ Name = 'ProfileId'; Actual = $Package.ProfileId; Expected = $IndependentReceipt.Candidate.ProfileId }
            [pscustomobject]@{ Name = 'ProfileFileSha256'; Actual = $Package.ProfileFileSha256; Expected = $IndependentReceipt.Candidate.ProfileFileSha256 }
            [pscustomobject]@{ Name = 'ProfileCanonicalSha256'; Actual = $Package.ProfileCanonicalSha256; Expected = $IndependentReceipt.Candidate.ProfileCanonicalSha256 }
            [pscustomobject]@{ Name = 'PackageReceiptSha256'; Actual = $Package.ReceiptSha256; Expected = $IndependentReceipt.Candidate.PackageReceiptSha256 }
            [pscustomobject]@{ Name = 'PackageReceiptFileSha256'; Actual = $Package.ReceiptFileSha256; Expected = $IndependentReceipt.Candidate.PackageReceiptFileSha256 }
            [pscustomobject]@{ Name = 'PackageArchiveSha256'; Actual = $Package.ArchiveSha256; Expected = $IndependentReceipt.Candidate.PackageArchiveSha256 }
            [pscustomobject]@{ Name = 'PackageManifestSha256'; Actual = $Package.ManifestSha256; Expected = $IndependentReceipt.Candidate.PackageManifestSha256 }
            [pscustomobject]@{ Name = 'PackageAppSha256'; Actual = $Package.AppSha256; Expected = $IndependentReceipt.Candidate.PackageAppSha256 }
            [pscustomobject]@{ Name = 'PackageCoreSha256'; Actual = $Package.CoreSha256; Expected = $IndependentReceipt.Candidate.PackageCoreSha256 }
            [pscustomobject]@{ Name = 'RendererManifestSha256'; Actual = $Renderer.ManifestSha256; Expected = $IndependentReceipt.Candidate.RendererManifestSha256 }
            [pscustomobject]@{ Name = 'RuntimeMatrixManifestSha256'; Actual = $Matrix.ManifestFileSha256; Expected = $IndependentReceipt.Candidate.RuntimeMatrixManifestSha256 }
            [pscustomobject]@{ Name = 'Issue9CandidateSha256'; Actual = $Issue9.CandidateSha256; Expected = $IndependentReceipt.Candidate.Issue9CandidateSha256 }
        )) {
        Assert-V02ReleaseGateEqual $binding.Actual $binding.Expected "External independent receipt $($binding.Name)"
        Assert-V02ReleaseGateEqual $binding.Expected $CandidateLock.$($binding.Name) "Candidate lock/external receipt $($binding.Name)"
    }
}

function Invoke-V02ReleaseGateIsolatedCleanMachineVerifier {
    param(
        [Parameter(Mandatory = $true)][string]$ReportPath,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$AuthorizationPath,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$AuthorizationSignaturePath,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$AcceptanceReceiptPath,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$AcceptanceReceiptSignaturePath,
        [Parameter(Mandatory = $true)][string]$ExpectedSourceCommit,
        [Parameter(Mandatory = $true)][string]$ExpectedSourceTree,
        [Parameter(Mandatory = $true)]$Package
    )

    # Derive the verifier location from this function's defining script block,
    # never from a caller-visible script variable or module object.
    $gateScriptPath = [IO.Path]::GetFullPath($MyInvocation.MyCommand.ScriptBlock.File)
    $gateToolsRoot = [IO.Path]::GetDirectoryName($gateScriptPath)
    $verifierPath = [IO.Path]::GetFullPath((Join-Path $gateToolsRoot 'packaging\v0.2\Invoke-V02CleanMachineReleaseVerifier.ps1'))
    $commonPath = [IO.Path]::GetFullPath((Join-Path $gateToolsRoot 'packaging\v0.2\V02CleanMachine.Common.ps1'))
    $packagingCommonPath = [IO.Path]::GetFullPath((Join-Path $gateToolsRoot 'packaging\v0.2\V02Packaging.Common.ps1'))
    $packageIdentityCommonPath = [IO.Path]::GetFullPath((Join-Path $gateToolsRoot 'packaging\v0.2\V02PackageIdentity.Common.ps1'))
    $rootPackagingCommonPath = [IO.Path]::GetFullPath((Join-Path $gateToolsRoot 'packaging\Packaging.Common.ps1'))
    $requestRoot = Join-Path ([IO.Path]::GetTempPath()) ('HerdrOps-V02ReleaseVerifier-' + [Guid]::NewGuid().ToString('N'))
    $requestPath = Join-Path $requestRoot 'request.json'
    $held = New-Object System.Collections.Generic.List[object]
    $inputSnapshots = @{}
    $process = $null
    try {
        [void][IO.Directory]::CreateDirectory($requestRoot)
        $verifierSnapshot = Get-V02ReleaseGateStableFileSnapshot -Path $verifierPath -Context 'Isolated CleanMachine verifier source' -KeepOpen
        [void]$held.Add($verifierSnapshot)
        $commonSnapshot = Get-V02ReleaseGateStableFileSnapshot -Path $commonPath -Context 'CleanMachine common verifier source' -KeepOpen
        [void]$held.Add($commonSnapshot)
        $packagingCommonSnapshot = Get-V02ReleaseGateStableFileSnapshot -Path $packagingCommonPath -Context 'V02 packaging common verifier dependency' -KeepOpen
        [void]$held.Add($packagingCommonSnapshot)
        $packageIdentityCommonSnapshot = Get-V02ReleaseGateStableFileSnapshot -Path $packageIdentityCommonPath -Context 'V02 package identity common verifier dependency' -KeepOpen
        [void]$held.Add($packageIdentityCommonSnapshot)
        $rootPackagingCommonSnapshot = Get-V02ReleaseGateStableFileSnapshot -Path $rootPackagingCommonPath -Context 'Root packaging common verifier dependency' -KeepOpen
        [void]$held.Add($rootPackagingCommonSnapshot)
        foreach ($input in @(
                @('report',$ReportPath,'CleanMachine report input'),
                @('authorization',$AuthorizationPath,'CleanMachine authorization input'),
                @('authorizationSignature',$AuthorizationSignaturePath,'CleanMachine authorization signature input'),
                @('acceptanceReceipt',$AcceptanceReceiptPath,'CleanMachine acceptance receipt input'),
                @('acceptanceReceiptSignature',$AcceptanceReceiptSignaturePath,'CleanMachine acceptance receipt signature input'))) {
            if (-not [string]::IsNullOrWhiteSpace([string]$input[1])) {
                $inputSnapshot = Get-V02ReleaseGateStableFileSnapshot -Path ([string]$input[1]) -Context ([string]$input[2]) -KeepOpen
                $inputSnapshots[[string]$input[0]] = $inputSnapshot
                [void]$held.Add($inputSnapshot)
            }
        }
        $enginePath = [IO.Path]::GetFullPath([Diagnostics.Process]::GetCurrentProcess().MainModule.FileName)
        $engineSnapshot = Get-V02ReleaseGateStableFileSnapshot -Path $enginePath -Context 'Isolated PowerShell executable' -KeepOpen
        [void]$held.Add($engineSnapshot)
        $request = [pscustomobject][ordered]@{
            reportPath = [IO.Path]::GetFullPath($ReportPath)
            authorizationPath = $(if ([string]::IsNullOrWhiteSpace($AuthorizationPath)) { '' } else { [IO.Path]::GetFullPath($AuthorizationPath) })
            authorizationSignaturePath = $(if ([string]::IsNullOrWhiteSpace($AuthorizationSignaturePath)) { '' } else { [IO.Path]::GetFullPath($AuthorizationSignaturePath) })
            acceptanceReceiptPath = $(if ([string]::IsNullOrWhiteSpace($AcceptanceReceiptPath)) { '' } else { [IO.Path]::GetFullPath($AcceptanceReceiptPath) })
            acceptanceReceiptSignaturePath = $(if ([string]::IsNullOrWhiteSpace($AcceptanceReceiptSignaturePath)) { '' } else { [IO.Path]::GetFullPath($AcceptanceReceiptSignaturePath) })
            expectedSourceCommit = $ExpectedSourceCommit
            expectedSourceTree = $ExpectedSourceTree
            engineSha256 = $engineSnapshot.Sha256
            verifierSha256 = $verifierSnapshot.Sha256
            commonSha256 = $commonSnapshot.Sha256
            packagingCommonSha256 = $packagingCommonSnapshot.Sha256
            packageIdentityCommonSha256 = $packageIdentityCommonSnapshot.Sha256
            rootPackagingCommonSha256 = $rootPackagingCommonSnapshot.Sha256
            reportSha256 = $inputSnapshots['report'].Sha256
            authorizationSha256 = $(if ($inputSnapshots.ContainsKey('authorization')) { $inputSnapshots['authorization'].Sha256 } else { '' })
            authorizationSignatureSha256 = $(if ($inputSnapshots.ContainsKey('authorizationSignature')) { $inputSnapshots['authorizationSignature'].Sha256 } else { '' })
            acceptanceReceiptSha256 = $(if ($inputSnapshots.ContainsKey('acceptanceReceipt')) { $inputSnapshots['acceptanceReceipt'].Sha256 } else { '' })
            acceptanceReceiptSignatureSha256 = $(if ($inputSnapshots.ContainsKey('acceptanceReceiptSignature')) { $inputSnapshots['acceptanceReceiptSignature'].Sha256 } else { '' })
            package = [pscustomobject][ordered]@{
                profileId = $Package.ProfileId; receiptSha256 = $Package.ReceiptSha256
                archiveSha256 = $Package.ArchiveSha256; manifestSha256 = $Package.ManifestSha256
                appSha256 = $Package.AppSha256; coreSha256 = $Package.CoreSha256
                referenceHostProfileSha256 = $Package.ReferenceHostProfileSha256
                rendererPolicySha256 = $Package.RendererPolicySha256
            }
        }
        $requestJson = $request | ConvertTo-Json -Compress -Depth 8
        [IO.File]::WriteAllText($requestPath, $requestJson, (New-Object Text.UTF8Encoding($false)))
        $requestSnapshot = Get-V02ReleaseGateStableFileSnapshot -Path $requestPath -Context 'Isolated CleanMachine verifier request' -KeepOpen
        [void]$held.Add($requestSnapshot)
        Assert-V02ReleaseGateDistinctFileIdentities -Snapshots $held.ToArray() -Context 'Isolated CleanMachine verifier sources and inputs'

        $start = New-Object Diagnostics.ProcessStartInfo
        $start.FileName = $enginePath
        $start.Arguments = '-NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "' + $verifierPath + '"'
        $start.UseShellExecute = $false
        $start.CreateNoWindow = $true
        $start.RedirectStandardOutput = $true
        $start.RedirectStandardError = $true
        $start.EnvironmentVariables['HERDROPS_V02_RELEASE_VERIFY_REQUEST'] = $requestPath
        $start.EnvironmentVariables['HERDROPS_V02_RELEASE_VERIFY_REQUEST_SHA256'] = $requestSnapshot.Sha256
        $start.EnvironmentVariables['PSModulePath'] = ''
        $start.EnvironmentVariables['PSModuleAnalysisCachePath'] = ''
        $process = New-Object Diagnostics.Process
        $process.StartInfo = $start
        if (-not $process.Start()) { throw 'The isolated CleanMachine verifier process did not start.' }
        $observedChildPid = [int]$process.Id
        # Prefix the round-trip UTC value so Windows PowerShell's JSON parser
        # cannot silently coerce it to a culture-formatted DateTime.
        $observedChildStartUtc = 'UTC:' + $process.StartTime.ToUniversalTime().ToString('O', [Globalization.CultureInfo]::InvariantCulture)
        # The exact executable bytes and final path were opened and held before
        # Start().  Reading MainModule after Start races a fast-failing child;
        # bind the child result to that held launch image instead.
        $observedChildPath = [string]$engineSnapshot.FinalPath
        $stdoutTask = $process.StandardOutput.ReadToEndAsync()
        $stderrTask = $process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit(120000)) {
            try { $process.Kill() } catch {}
            try { $process.WaitForExit() } catch {}
            throw 'The isolated CleanMachine verifier process exceeded its 120-second bound.'
        }
        $stdout = $stdoutTask.GetAwaiter().GetResult()
        $stderr = $stderrTask.GetAwaiter().GetResult()
        if ($process.ExitCode -ne 0) {
            throw "Isolated CleanMachine verifier rejected the evidence: $($stderr.Trim())"
        }
        $lines = @($stdout -split "`r?`n" | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
        if ($lines.Count -ne 1) { throw 'The isolated CleanMachine verifier returned an ambiguous result stream.' }
        $result = $lines[0] | ConvertFrom-Json
        $expectedProperties = @('protocol','version','requestSha256','engineSha256','verifierSha256','commonSha256','packagingCommonSha256','packageIdentityCommonSha256','rootPackagingCommonSha256','reportSha256','authorizationSha256','authorizationSignatureSha256','childPid','childStartUtc','engineFinalPath','engineVolumeSerialNumber','engineFileId','runId','machineFingerprint','operatorIdentity','observerIdentity','authorizationSignerThumbprint','acceptanceReceiptSha256','acceptanceReceiptSignatureSha256','acceptanceReceiptNonce','resultBindingSha256')
        $actualProperties = @($result.PSObject.Properties.Name)
        if ($actualProperties.Count -ne $expectedProperties.Count -or @($actualProperties | Where-Object { $expectedProperties -cnotcontains $_ }).Count -ne 0) {
            throw 'The isolated CleanMachine verifier returned a malformed result.'
        }
        Assert-V02ReleaseGateExactString $result.protocol 'HerdrOps.V02IsolatedCleanMachineVerifierResult' 'Isolated CleanMachine verifier protocol'
        Assert-V02ReleaseGateEqual $result.version 1 'Isolated CleanMachine verifier version'
        Assert-V02ReleaseGateEqual $result.requestSha256 $requestSnapshot.Sha256 'Isolated CleanMachine verifier request binding'
        Assert-V02ReleaseGateEqual $result.engineSha256 $engineSnapshot.Sha256 'Isolated PowerShell executable binding'
        Assert-V02ReleaseGateEqual $result.verifierSha256 $verifierSnapshot.Sha256 'Isolated CleanMachine verifier source binding'
        Assert-V02ReleaseGateEqual $result.commonSha256 $commonSnapshot.Sha256 'Isolated CleanMachine common source binding'
        Assert-V02ReleaseGateEqual $result.packagingCommonSha256 $packagingCommonSnapshot.Sha256 'Isolated V02 packaging dependency binding'
        Assert-V02ReleaseGateEqual $result.packageIdentityCommonSha256 $packageIdentityCommonSnapshot.Sha256 'Isolated V02 package identity dependency binding'
        Assert-V02ReleaseGateEqual $result.rootPackagingCommonSha256 $rootPackagingCommonSnapshot.Sha256 'Isolated root packaging dependency binding'
        Assert-V02ReleaseGateEqual $result.reportSha256 $inputSnapshots['report'].Sha256 'Isolated CleanMachine report input binding'
        Assert-V02ReleaseGateEqual $result.authorizationSha256 $inputSnapshots['authorization'].Sha256 'Isolated CleanMachine authorization input binding'
        Assert-V02ReleaseGateEqual $result.authorizationSignatureSha256 $inputSnapshots['authorizationSignature'].Sha256 'Isolated CleanMachine authorization signature binding'
        Assert-V02ReleaseGateEqual $result.acceptanceReceiptSha256 $inputSnapshots['acceptanceReceipt'].Sha256 'Isolated CleanMachine acceptance receipt input binding'
        Assert-V02ReleaseGateEqual $result.acceptanceReceiptSignatureSha256 $inputSnapshots['acceptanceReceiptSignature'].Sha256 'Isolated CleanMachine acceptance receipt signature binding'
        Assert-V02ReleaseGateEqual $result.childPid $observedChildPid 'Isolated CleanMachine child PID binding'
        Assert-V02ReleaseGateEqual $result.childStartUtc $observedChildStartUtc 'Isolated CleanMachine child start-time binding'
        Assert-V02ReleaseGateEqual $result.engineFinalPath $engineSnapshot.FinalPath 'Isolated CleanMachine child executable final-path binding'
        Assert-V02ReleaseGateEqual ($result.engineVolumeSerialNumber + ':' + $result.engineFileId) $engineSnapshot.FileId 'Isolated CleanMachine child executable FileId binding'
        Assert-V02ReleaseGateEqual $observedChildPath $engineSnapshot.FinalPath 'Observed child executable path binding'
        $boundResult = [ordered]@{}
        foreach ($resultPropertyName in @($expectedProperties | Where-Object { $_ -cne 'resultBindingSha256' })) {
            $boundResult[$resultPropertyName] = $result.$resultPropertyName
        }
        $resultBindingText = [pscustomobject]$boundResult | ConvertTo-Json -Compress -Depth 8
        Assert-V02ReleaseGateEqual $result.resultBindingSha256 (Get-V02Sha256Hex -Bytes ([Text.Encoding]::UTF8.GetBytes($resultBindingText))) 'Isolated CleanMachine result cryptographic binding'
        return $result
    }
    finally {
        if ($null -ne $process) { $process.Dispose() }
        Close-V02ReleaseGateHeldSnapshots -Snapshots $held.ToArray()
        if (Test-Path -LiteralPath $requestPath -PathType Leaf) { [IO.File]::Delete($requestPath) }
        if (Test-Path -LiteralPath $requestRoot -PathType Container) { [IO.Directory]::Delete($requestRoot, $false) }
    }
}

function Read-V02ReleaseGateCleanMachineReport {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$ExpectedSourceCommit,
        [Parameter(Mandatory = $true)][string]$ExpectedSourceTree,
        [Parameter(Mandatory = $true)]$Package,
        [string]$CleanHostAuthorizationPath,
        [string]$CleanHostAuthorizationSignaturePath,
        [string]$CleanHostAcceptanceReceiptPath,
        [string]$CleanHostAcceptanceReceiptSignaturePath
    )

    $isolated = Invoke-V02ReleaseGateIsolatedCleanMachineVerifier `
        -ReportPath $Path -AuthorizationPath $CleanHostAuthorizationPath `
        -AuthorizationSignaturePath $CleanHostAuthorizationSignaturePath `
        -AcceptanceReceiptPath $CleanHostAcceptanceReceiptPath `
        -AcceptanceReceiptSignaturePath $CleanHostAcceptanceReceiptSignaturePath `
        -ExpectedSourceCommit $ExpectedSourceCommit -ExpectedSourceTree $ExpectedSourceTree -Package $Package

    # This exported helper is intentionally incapable of production credit.
    # Only direct -File execution receives the privately captured launcher
    # script block and constructs the production CleanMachine result.
    return [pscustomobject][ordered]@{
        Path = [IO.Path]::GetFullPath($Path)
        FileSha256 = [string]$isolated.reportSha256
        EvidenceClass = 'SyntheticVerifierFixture'
        Status = 'PASS'
        Mode = 'Live'
        RunId = [string]$isolated.runId
        MachineFingerprint = [string]$isolated.machineFingerprint
        OperatorIdentity = [string]$isolated.operatorIdentity
        ObserverIdentity = [string]$isolated.observerIdentity
        AuthorizationSignerThumbprint = [string]$isolated.authorizationSignerThumbprint
        AcceptanceReceiptSha256 = [string]$isolated.acceptanceReceiptSha256
        AcceptanceReceiptSignatureSha256 = [string]$isolated.acceptanceReceiptSignatureSha256
        AcceptanceReceiptNonce = [string]$isolated.acceptanceReceiptNonce
        LifecycleCreditGranted = $false
        Runtime = 'NOT_OBSERVED'
        Human = 'NOT_OBSERVED'
        Release = 'NOT_OBSERVED'
    }
}

function Assert-V02ReleaseGateGitHubSnapshot {
    param(
        [Parameter(Mandatory = $true)]$Snapshot,
        [string]$Context = 'GitHub snapshot'
    )

    Assert-V02ReleaseGateExactProperties $Snapshot @('schemaVersion', 'repository', 'milestones', 'issues') $Context
    Assert-V02ReleaseGateInteger $Snapshot.schemaVersion "$Context schemaVersion" 1
    Assert-V02ReleaseGateEqual $Snapshot.schemaVersion 1 "$Context schemaVersion"
    Assert-V02ReleaseGateExactString $Snapshot.repository 'OSHEThai/HerdrOps' "$Context repository"
    $milestones = @($Snapshot.milestones)
    $matchingMilestones = @($milestones | Where-Object { [int]$_.number -eq $script:V02ReleaseGateMilestoneNumber -and [string]$_.title -ceq $script:V02ReleaseGateVersion })
    if ($matchingMilestones.Count -ne 1) {
        throw "$Context must contain exactly one v0.2.0 milestone #$script:V02ReleaseGateMilestoneNumber."
    }
    Assert-V02ReleaseGateExactString $matchingMilestones[0].state 'closed' "$Context v0.2.0 milestone state"

    $issues = @($Snapshot.issues)
    $numbers = @($issues | ForEach-Object { [int]$_.number })
    Assert-V02ReleaseGateDistinctSet -Values $numbers -Context "$Context issue numbers"
    $milestoneIssueNumbers = @($issues | Where-Object {
            $null -ne $_.milestone -and [int]$_.milestone.number -eq $script:V02ReleaseGateMilestoneNumber -and
                [string]$_.milestone.title -ceq $script:V02ReleaseGateVersion
        } | ForEach-Object { [int]$_.number } | Sort-Object)
    if (($milestoneIssueNumbers -join ',') -cne (@($script:V02ReleaseGateExpectedMilestoneIssues | Sort-Object) -join ',')) {
        throw "$Context v0.2.0 issue set is incomplete or unexpected. Expected=$(@($script:V02ReleaseGateExpectedMilestoneIssues | Sort-Object) -join ',') Observed=$($milestoneIssueNumbers -join ',')."
    }
    foreach ($number in @($script:V02ReleaseGateRequiredIssues + $script:V02ReleaseGateTrackerIssue)) {
        $matches = @($issues | Where-Object { [int]$_.number -eq $number })
        if ($matches.Count -ne 1) {
            throw "$Context must contain exactly one issue #$number."
        }
        $issue = $matches[0]
        Assert-V02ReleaseGateExactString $issue.state 'closed' "$Context issue #$number state"
        if ($number -ne 149) {
            if ($null -eq $issue.milestone -or [int]$issue.milestone.number -ne $script:V02ReleaseGateMilestoneNumber -or
                [string]$issue.milestone.title -cne $script:V02ReleaseGateVersion) {
                throw "$Context issue #$number is not attached to the exact v0.2.0 milestone."
            }
        }
    }
    $tracker = @($issues | Where-Object { [int]$_.number -eq $script:V02ReleaseGateTrackerIssue })[0]
    Assert-V02ReleaseGateExactString $tracker.title '[v0.2.0] Release readiness tracker' "$Context tracker title"

    $openV02Issues = @($issues | Where-Object {
            $milestone = $_.milestone
            $null -ne $milestone -and [int]$milestone.number -eq $script:V02ReleaseGateMilestoneNumber -and
                [string]$milestone.title -ceq $script:V02ReleaseGateVersion -and [string]$_.state -ceq 'open'
        })
    if ($openV02Issues.Count -ne 0) {
        throw "$Context has open v0.2.0 issue(s): $(@($openV02Issues | ForEach-Object { $_.number }) -join ', ')."
    }
    return [pscustomobject][ordered]@{
        Status = 'UNAUTHENTICATED_LOCAL_SNAPSHOT'
        Authenticated = $false
        MilestoneNumber = $script:V02ReleaseGateMilestoneNumber
        MilestoneState = [string]$matchingMilestones[0].state
        TrackerIssue = $script:V02ReleaseGateTrackerIssue
        MilestoneIssueCount = $milestoneIssueNumbers.Count
        RequiredIssueCount = $script:V02ReleaseGateRequiredIssues.Count
        OpenV02IssueCount = $openV02Issues.Count
    }
}

function Assert-V02ReleaseGateHumanReview {
    param(
        [Parameter(Mandatory = $true)]$Review,
        [Parameter(Mandatory = $true)][string]$ReviewPath,
        [Parameter(Mandatory = $true)][string]$ExpectedSourceCommit,
        [Parameter(Mandatory = $true)][string]$ExpectedSourceTree,
        [Parameter(Mandatory = $true)]$Package,
        [Parameter(Mandatory = $true)]$Renderer,
        [Parameter(Mandatory = $true)]$Matrix,
        [Parameter(Mandatory = $true)]$Issue9,
        [Parameter(Mandatory = $true)][string]$GitHubSnapshotPath,
        [Parameter(Mandatory = $true)][string]$GitHubSnapshotSha256,
        [Parameter(Mandatory = $true)][string]$EvidenceRoot
    )

    Assert-V02ReleaseGateExactProperties $Review @(
        'SchemaVersion', 'EvidenceClass', 'Result', 'Decision', 'Reviewer', 'Candidate',
        'Checks', 'OpenFindings', 'ActualHerdrRuntime', 'ReleaseCredit'
    ) 'Human review'
    Assert-V02ReleaseGateInteger $Review.SchemaVersion 'Human review SchemaVersion' 2
    Assert-V02ReleaseGateEqual $Review.SchemaVersion 2 'Human review SchemaVersion'
    Assert-V02ReleaseGateExactString $Review.EvidenceClass 'Human' 'Human review EvidenceClass'
    Assert-V02ReleaseGateExactString $Review.Result 'PASS' 'Human review Result'
    Assert-V02ReleaseGateExactString $Review.Decision 'GO' 'Human review Decision'
    Assert-V02ReleaseGateExactString $Review.ActualHerdrRuntime 'NOT_OBSERVED' 'Human review ActualHerdrRuntime'
    if (Assert-V02ReleaseGateBoolean $Review.ReleaseCredit 'Human review ReleaseCredit') {
        throw 'Human review cannot grant Release credit.'
    }

    Assert-V02ReleaseGateExactProperties $Review.Reviewer @(
        'Identity', 'Role', 'BuilderIdentity', 'RuntimeOperatorIdentity', 'RoleDistinct', 'ReviewedUtc'
    ) 'Human review Reviewer'
    $reviewerIdentity = Assert-V02ReleaseGateString $Review.Reviewer.Identity 'Human reviewer identity'
    Assert-V02ReleaseGateExactString $Review.Reviewer.Role 'IndependentReleaseReviewer' 'Human reviewer role'
    $builderIdentity = Assert-V02ReleaseGateString $Review.Reviewer.BuilderIdentity 'Human review builder identity'
    $runtimeIdentity = Assert-V02ReleaseGateString $Review.Reviewer.RuntimeOperatorIdentity 'Human review runtime-operator identity'
    if (-not (Assert-V02ReleaseGateBoolean $Review.Reviewer.RoleDistinct 'Human review RoleDistinct')) {
        throw 'Human review must explicitly record role distinction.'
    }
    Assert-V02ReleaseGateString $Review.Reviewer.ReviewedUtc 'Human review ReviewedUtc' | Out-Null
    $null = [DateTimeOffset]$Review.Reviewer.ReviewedUtc
    Assert-V02ReleaseGateDistinctSet -Values @($reviewerIdentity, $builderIdentity, $runtimeIdentity) -Context 'Human review identities'

    Assert-V02ReleaseGateExactProperties $Review.Candidate @(
        'SourceCommit', 'SourceTree', 'PackageReceiptSha256', 'PackageReceiptFileSha256',
        'PackageArchiveSha256', 'PackageAppSha256', 'PackageCoreSha256',
        'RendererManifestSha256', 'RuntimeMatrixManifestSha256', 'Issue9CandidateSha256', 'GitHubSnapshotSha256'
    ) 'Human review candidate binding'
    Assert-V02ReleaseGateEqual $Review.Candidate.SourceCommit $ExpectedSourceCommit 'Human review source commit'
    Assert-V02ReleaseGateEqual $Review.Candidate.SourceTree $ExpectedSourceTree 'Human review source tree'
    Assert-V02ReleaseGateEqual $Review.Candidate.PackageReceiptSha256 $Package.ReceiptSha256 'Human review package receipt'
    Assert-V02ReleaseGateEqual $Review.Candidate.PackageReceiptFileSha256 $Package.ReceiptFileSha256 'Human review package receipt file'
    Assert-V02ReleaseGateEqual $Review.Candidate.PackageArchiveSha256 $Package.ArchiveSha256 'Human review package archive'
    Assert-V02ReleaseGateEqual $Review.Candidate.PackageAppSha256 $Package.AppSha256 'Human review package App'
    Assert-V02ReleaseGateEqual $Review.Candidate.PackageCoreSha256 $Package.CoreSha256 'Human review package Core'
    Assert-V02ReleaseGateEqual $Review.Candidate.RendererManifestSha256 $Renderer.ManifestSha256 'Human review renderer manifest'
    Assert-V02ReleaseGateEqual $Review.Candidate.RuntimeMatrixManifestSha256 $Matrix.ManifestFileSha256 'Human review runtime matrix'
    Assert-V02ReleaseGateEqual $Review.Candidate.Issue9CandidateSha256 $Issue9.CandidateSha256 'Human review Issue #9 candidate'
    Assert-V02ReleaseGateEqual $Review.Candidate.GitHubSnapshotSha256 $GitHubSnapshotSha256 'Human review GitHub snapshot'
    foreach ($name in @(
            'PackageReceiptSha256', 'PackageReceiptFileSha256', 'PackageArchiveSha256',
            'PackageAppSha256', 'PackageCoreSha256', 'RendererManifestSha256',
            'RuntimeMatrixManifestSha256', 'Issue9CandidateSha256', 'GitHubSnapshotSha256'
        )) {
        Assert-V02ReleaseGateSha256 $Review.Candidate.$name "Human review candidate $name" | Out-Null
    }
    Assert-V02ReleaseGateGitObjectId $Review.Candidate.SourceCommit 'Human review candidate SourceCommit' | Out-Null
    Assert-V02ReleaseGateGitObjectId $Review.Candidate.SourceTree 'Human review candidate SourceTree' | Out-Null

    $checks = @($Review.Checks)
    if ($checks.Count -ne $script:V02ReleaseGateHumanCheckIds.Count) {
        throw "Human review must contain exactly $($script:V02ReleaseGateHumanCheckIds.Count) required checks."
    }
    $seen = New-Object System.Collections.Generic.List[string]
    $seenPaths = @{}
    $humanArtifactSnapshots = New-Object System.Collections.Generic.List[object]
    $expectedArtifactPaths = @{
        'package-receipt' = [IO.Path]::GetFullPath($Package.IdentityPath).TrimEnd([char[]]@('\', '/'))
        'renderer-compatibility' = [IO.Path]::GetFullPath($Renderer.ManifestPath).TrimEnd([char[]]@('\', '/'))
        'runtime-matrix-thai' = [IO.Path]::GetFullPath($Matrix.ManifestPath).TrimEnd([char[]]@('\', '/'))
        'runtime-matrix-english' = [IO.Path]::GetFullPath($Matrix.ManifestPath).TrimEnd([char[]]@('\', '/'))
        'issue-9-acceptance' = [IO.Path]::GetFullPath($Issue9.CandidatePath).TrimEnd([char[]]@('\', '/'))
        'tracker-11-readiness' = [IO.Path]::GetFullPath($GitHubSnapshotPath).TrimEnd([char[]]@('\', '/'))
    }
    foreach ($check in $checks) {
        Assert-V02ReleaseGateExactProperties $check @('Id', 'Status', 'Path', 'Sha256', 'Binding') 'Human review check'
        $id = Assert-V02ReleaseGateString $check.Id 'Human review check Id'
        if ($seen.Contains($id)) { throw "Human review contains duplicate check '$id'." }
        [void]$seen.Add($id)
        if ($script:V02ReleaseGateHumanCheckIds -notcontains $id) { throw "Human review contains unknown check '$id'." }
        Assert-V02ReleaseGateExactString $check.Status 'PASS' "Human review check '$id' status"
        Assert-V02ReleaseGateExactString $check.Binding ("HumanCheck:$id") "Human review check '$id' binding"
        $checkPath = Get-V02ReleaseGateRelativeOrAbsolutePath -Path ([string]$check.Path) `
            -BaseDirectory ([IO.Path]::GetDirectoryName($ReviewPath)) -Context "Human review check '$id' artifact" `
            -AllowedRoot $EvidenceRoot
        $declared = Assert-V02ReleaseGateSha256 $check.Sha256 "Human review check '$id' hash"
        $checkSnapshot = Get-V02ReleaseGateStableFileSnapshot -Path $checkPath -Context "Human review check '$id' artifact"
        Assert-V02ReleaseGateEqual $checkSnapshot.Sha256 $declared "Human review check '$id' artifact hash"
        if ($script:V02ReleaseGateHumanArtifactCheckIds -contains $id) {
            Assert-V02ReleaseGateEqual $checkPath $expectedArtifactPaths[$id] "Human review check '$id' semantic path"
            [void]$humanArtifactSnapshots.Add($checkSnapshot)
        }
        $pathKey = $checkPath.ToUpperInvariant()
        if ($seenPaths.ContainsKey($pathKey) -and
            -not (($seenPaths[$pathKey] -in @('runtime-matrix-thai', 'runtime-matrix-english')) -and
                 ($id -in @('runtime-matrix-thai', 'runtime-matrix-english')))) {
            throw "Human review check '$id' reuses the artifact path already bound to '$($seenPaths[$pathKey])'."
        }
        $seenPaths[$pathKey] = $id
        if ($id -ceq 'package-receipt') {
            Assert-V02ReleaseGateEqual $declared $Package.ReceiptFileSha256 "Human review package receipt file binding"
        }
        elseif ($id -ceq 'renderer-compatibility') {
            Assert-V02ReleaseGateEqual $declared $Renderer.ManifestSha256 "Human review renderer manifest binding"
        }
        elseif ($id -ceq 'runtime-matrix-thai' -or $id -ceq 'runtime-matrix-english') {
            Assert-V02ReleaseGateEqual $declared $Matrix.ManifestFileSha256 "Human review runtime matrix binding"
        }
        elseif ($id -ceq 'issue-9-acceptance') {
            Assert-V02ReleaseGateEqual $declared $Issue9.CandidateSha256 "Human review Issue #9 candidate artifact binding"
        }
        elseif ($id -ceq 'tracker-11-readiness') {
            Assert-V02ReleaseGateEqual $declared $GitHubSnapshotSha256 "Human review tracker snapshot binding"
        }
    }
    foreach ($id in $script:V02ReleaseGateHumanCheckIds) {
        if (-not $seen.Contains($id)) { throw "Human review omitted required check '$id'." }
    }
    foreach ($id in $script:V02ReleaseGateHumanArtifactCheckIds) {
        if (-not $seen.Contains($id)) { throw "Human review omitted semantically pinned artifact check '$id'." }
    }
    Assert-V02ReleaseGateDistinctFileIdentities -Snapshots $humanArtifactSnapshots.ToArray() -Context 'Human review artifact paths'
    $openFindings = @($Review.OpenFindings)
    if ($openFindings.Count -ne 0) {
        throw 'Human review cannot pass with open findings.'
    }
    return [pscustomobject][ordered]@{
        Path = $ReviewPath
        FileSha256 = Get-V02ReleaseGateFileSha256 -Path $ReviewPath
        Status = 'NOT_OBSERVED'
        Decision = 'NOT_OBSERVED'
        Reason = 'LOCAL_REVIEW_RECORD_IS_NOT_AN_AUTHENTICATED_INDEPENDENT_RECEIPT'
        ReviewerIdentity = [string]$Review.Reviewer.Identity
        ReviewerRole = [string]$Review.Reviewer.Role
        RoleDistinct = [bool]$Review.Reviewer.RoleDistinct
        OpenFindingCount = @($Review.OpenFindings).Count
        Authenticated = $false
    }
}

function Write-V02ReleaseGateReport {
    param(
        [Parameter(Mandatory = $true)]$Report,
        [Parameter(Mandatory = $true)][string]$OutputPath
    )

    $resolved = [IO.Path]::GetFullPath($OutputPath)
    $jsonPath = $resolved
    $textPath = $null
    if ([IO.Path]::GetExtension($resolved) -ieq '.json') {
        $parent = [IO.Path]::GetDirectoryName($resolved)
        if (-not [IO.Directory]::Exists($parent)) { [IO.Directory]::CreateDirectory($parent) | Out-Null }
        $textPath = Join-Path $parent 'gate-report.txt'
    }
    else {
        if (Test-Path -LiteralPath $resolved -PathType Leaf) { throw "OutputPath is a file, not a directory: $resolved" }
        if (-not [IO.Directory]::Exists($resolved)) { [IO.Directory]::CreateDirectory($resolved) | Out-Null }
        $jsonPath = Join-Path $resolved 'v0.2-release-gate.json'
        $textPath = Join-Path $resolved 'gate-report.txt'
    }
    if ((Test-Path -LiteralPath $jsonPath -PathType Leaf) -or (Test-Path -LiteralPath $textPath -PathType Leaf)) {
        throw "Release-gate output already exists; refusing to overwrite: $resolved"
    }
    $utf8 = New-Object Text.UTF8Encoding($false)
    $json = $Report | ConvertTo-Json -Depth 100
    $text = @(
        'HerdrOps v0.2.0 Release Gate',
        "GeneratedUtc: $([DateTime]::UtcNow.ToString('O'))",
        "Result: $($Report.Result)",
        "ReleaseReady: $($Report.ReleaseReady.ToString().ToLowerInvariant())",
        "SourceCommit: $($Report.SourceCommit)",
        "SourceTree: $($Report.SourceTree)",
        "SourceParents: $(@($Report.SourceParents) -join ' ')",
        "PackageReceiptSha256: $($Report.Package.ReceiptSha256)",
        "PackageReceiptFileSha256: $($Report.Package.ReceiptFileSha256)",
        "RendererManifestSha256: $($Report.Renderer.ManifestSha256)",
        "RuntimeMatrixManifestSha256: $($Report.RuntimeMatrix.ManifestFileSha256)",
        "GitHubSnapshotSha256: $($Report.GitHub.SnapshotSha256)",
        '',
        'EvidenceClasses:',
        "Static: $($Report.EvidenceClasses.Static.Status) [$($Report.EvidenceClasses.Static.Classification)]",
        "Contract: $($Report.EvidenceClasses.Contract.Status) [$($Report.EvidenceClasses.Contract.Classification)]",
        "Synthetic: $($Report.EvidenceClasses.Synthetic.Status) [$($Report.EvidenceClasses.Synthetic.Classification)]",
        "Runtime: $($Report.EvidenceClasses.Runtime.Status) [$($Report.EvidenceClasses.Runtime.Classification)]",
        "Human: $($Report.EvidenceClasses.Human.Status) [$($Report.EvidenceClasses.Human.Classification)]",
        "Release: $($Report.EvidenceClasses.Release.Status) [$($Report.EvidenceClasses.Release.Classification)]",
        '',
        'Boundary: no Herdr control, GitHub mutation, package publication, tag, signing, or release publication is performed by this gate.'
    ) -join "`r`n"
    [IO.File]::WriteAllText($jsonPath, $json, $utf8)
    [IO.File]::WriteAllText($textPath, $text + "`r`n", $utf8)
    return [pscustomobject][ordered]@{ JsonPath = $jsonPath; TextPath = $textPath }
}

function Assert-V02ReleaseGateBoundSnapshots {
    param(
        [Parameter(Mandatory = $true)]$Snapshots,
        [Parameter(Mandatory = $true)][string]$Phase
    )

    Assert-V02ReleaseGateDistinctFileIdentities -Snapshots @($Snapshots) -Context "$Phase snapshots"
    foreach ($snapshot in @($Snapshots)) {
        Assert-V02ReleaseGateSnapshotUnchanged -Snapshot $snapshot -Context "$Phase '$($snapshot.Path)'" | Out-Null
    }
}

function Invoke-V02ReleaseGate {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$ExpectedSourceCommit,
        [Parameter(Mandatory = $true)][string]$ExpectedSourceTree,
        [Parameter(Mandatory = $true)][string]$PackageIdentityPath,
        [Parameter(Mandatory = $true)][string]$PackageArchivePath,
        [Parameter(Mandatory = $true)][string]$ExtractedPackageRoot,
        [Parameter(Mandatory = $true)][string]$PackageProfilePath,
        [Parameter(Mandatory = $true)][string]$RendererManifestPath,
        [Parameter(Mandatory = $true)][string]$ThaiEvidenceDirectory,
        [Parameter(Mandatory = $true)][string]$EnglishEvidenceDirectory,
        [Parameter(Mandatory = $true)][string]$RuntimeMatrixManifestPath,
        [Parameter(Mandatory = $true)][string]$Issue9CandidatePath,
        [Parameter(Mandatory = $true)][string]$ContractEvidencePath,
        [Parameter(Mandatory = $true)][string]$SyntheticEvidencePath,
        [Parameter(Mandatory = $true)][string]$HumanReviewPath,
        [Parameter(Mandatory = $true)][string]$CleanMachineReportPath,
        [Parameter(Mandatory = $true)][string]$CleanHostAuthorizationPath,
        [Parameter(Mandatory = $true)][string]$CleanHostAuthorizationSignaturePath,
        [Parameter(Mandatory = $true)][string]$CleanHostAcceptanceReceiptPath,
        [Parameter(Mandatory = $true)][string]$CleanHostAcceptanceReceiptSignaturePath,
        [Parameter(Mandatory = $true)][string]$GitHubSnapshotPath,
        [string]$CandidateLockPath,
        [string]$AuthorityReferencePath,
        [string]$IndependentCandidateReceiptPath,
        [string]$EvidenceRoot,
        [string]$RepositoryRoot,
        [string]$RendererEvidenceRoot,
        [string]$OutputPath
    )

    $definitionPath = [IO.Path]::GetFullPath($MyInvocation.MyCommand.ScriptBlock.File)
    $commandLine = @([Environment]::GetCommandLineArgs())
    $isDirectFileExecution = $false
    $cursor = 1
    $seenHostSwitches = @{}
    while ($cursor -lt $commandLine.Count -and [string]$commandLine[$cursor] -ine '-File') {
        $hostSwitch = [string]$commandLine[$cursor]
        if ($hostSwitch -in @('-NoLogo','-NoProfile','-NonInteractive') -and -not $seenHostSwitches.ContainsKey($hostSwitch.ToUpperInvariant())) {
            $seenHostSwitches[$hostSwitch.ToUpperInvariant()] = $true; $cursor++; continue
        }
        if ($hostSwitch -ieq '-ExecutionPolicy' -and -not $seenHostSwitches.ContainsKey('EXECUTIONPOLICY') -and
            $cursor + 1 -lt $commandLine.Count -and [string]$commandLine[$cursor + 1] -ieq 'Bypass') {
            $seenHostSwitches['EXECUTIONPOLICY'] = $true; $cursor += 2; continue
        }
        $cursor = $commandLine.Count; break
    }
    if ($cursor + 1 -lt $commandLine.Count -and [string]$commandLine[$cursor] -ieq '-File') {
        try { $isDirectFileExecution = [StringComparer]::OrdinalIgnoreCase.Equals([IO.Path]::GetFullPath([string]$commandLine[$cursor + 1]),$definitionPath) }
        catch { $isDirectFileExecution = $false }
    }
    if (-not $isDirectFileExecution) {
        throw 'Production CleanMachine lifecycle credit is direct-execution-only under a clean -File Test-V02ReleaseGate.ps1 process.'
    }

    Assert-V02ReleaseGateGitObjectId $ExpectedSourceCommit 'ExpectedSourceCommit' | Out-Null
    Assert-V02ReleaseGateGitObjectId $ExpectedSourceTree 'ExpectedSourceTree' | Out-Null
    if ([string]::IsNullOrWhiteSpace($RepositoryRoot)) {
        $RepositoryRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
    }
    $identityBefore = Get-V02ReleaseGateGitIdentity -RepositoryRoot $RepositoryRoot
    Assert-V02ReleaseGateGitIdentity $identityBefore $ExpectedSourceCommit $ExpectedSourceTree 'Preflight'

    if ([string]::IsNullOrWhiteSpace($EvidenceRoot)) {
        $report = New-V02ReleaseGateNotReadyReport -Identity $identityBefore `
            -Reason 'EvidenceRoot is required for path containment and immutable evidence binding.'
        if (-not [string]::IsNullOrWhiteSpace($OutputPath)) {
            $written = Write-V02ReleaseGateReport -Report $report -OutputPath $OutputPath
            $report | Add-Member -MemberType NoteProperty -Name ReportJsonPath -Value $written.JsonPath
            $report | Add-Member -MemberType NoteProperty -Name ReportTextPath -Value $written.TextPath
        }
        return $report
    }
    $evidenceRootPath = Resolve-V02ReleaseGateExistingPath -Path $EvidenceRoot -Type Container -Context 'EvidenceRoot'

    $profilePath = Resolve-V02ReleaseGateExistingPath -Path $PackageProfilePath -Type Leaf -Context 'Package identity profile'
    $expectedProfilePath = [IO.Path]::GetFullPath((Join-Path $identityBefore.RepositoryRoot 'tools\packaging\v0.2\package-identity-profile.json')).TrimEnd([char[]]@('\', '/'))
    if (-not [StringComparer]::OrdinalIgnoreCase.Equals($profilePath, $expectedProfilePath)) {
        throw 'Package identity profile is not the committed v0.2 profile path.'
    }

    $evidenceInputs = @(
        [pscustomobject]@{ Path = $PackageIdentityPath; Type = 'Leaf'; Name = 'Package identity receipt' }
        [pscustomobject]@{ Path = $PackageArchivePath; Type = 'Leaf'; Name = 'Package archive' }
        [pscustomobject]@{ Path = $ExtractedPackageRoot; Type = 'Container'; Name = 'Extracted package root' }
        [pscustomobject]@{ Path = $RendererManifestPath; Type = 'Leaf'; Name = 'Renderer manifest' }
        [pscustomobject]@{ Path = $ThaiEvidenceDirectory; Type = 'Container'; Name = 'Thai evidence directory' }
        [pscustomobject]@{ Path = $EnglishEvidenceDirectory; Type = 'Container'; Name = 'English evidence directory' }
        [pscustomobject]@{ Path = $RuntimeMatrixManifestPath; Type = 'Leaf'; Name = 'Runtime matrix manifest' }
        [pscustomobject]@{ Path = $Issue9CandidatePath; Type = 'Leaf'; Name = 'Issue #9 runtime candidate' }
        [pscustomobject]@{ Path = $ContractEvidencePath; Type = 'Leaf'; Name = 'Contract evidence receipt' }
        [pscustomobject]@{ Path = $SyntheticEvidencePath; Type = 'Leaf'; Name = 'Synthetic evidence receipt' }
        [pscustomobject]@{ Path = $HumanReviewPath; Type = 'Leaf'; Name = 'Human review record' }
        [pscustomobject]@{ Path = $CleanMachineReportPath; Type = 'Leaf'; Name = 'Clean-machine acceptance report' }
        [pscustomobject]@{ Path = $CleanHostAuthorizationPath; Type = 'Leaf'; Name = 'Clean-host authorization' }
        [pscustomobject]@{ Path = $CleanHostAuthorizationSignaturePath; Type = 'Leaf'; Name = 'Clean-host authorization signature' }
        [pscustomobject]@{ Path = $CleanHostAcceptanceReceiptPath; Type = 'Leaf'; Name = 'Clean-host acceptance receipt' }
        [pscustomobject]@{ Path = $CleanHostAcceptanceReceiptSignaturePath; Type = 'Leaf'; Name = 'Clean-host acceptance receipt signature' }
        [pscustomobject]@{ Path = $GitHubSnapshotPath; Type = 'Leaf'; Name = 'GitHub snapshot' }
    )
    foreach ($input in $evidenceInputs) {
        $resolvedInput = Resolve-V02ReleaseGateExistingPath -Path ([string]$input.Path) -Type $input.Type -Context $input.Name
        Assert-V02ReleaseGatePathWithinRoot -Path $resolvedInput -Root $evidenceRootPath -Context $input.Name | Out-Null
    }
    if (-not [string]::IsNullOrWhiteSpace($RendererEvidenceRoot)) {
        $rendererEvidenceRootPath = Resolve-V02ReleaseGateExistingPath -Path $RendererEvidenceRoot -Type Container -Context 'Renderer evidence root'
        Assert-V02ReleaseGatePathWithinRoot -Path $rendererEvidenceRootPath -Root $evidenceRootPath -Context 'Renderer evidence root' | Out-Null
    }
    else {
        $rendererEvidenceRootPath = $evidenceRootPath
    }

    $authority = $null
    $candidateLock = $null
    try {
        if ([string]::IsNullOrWhiteSpace($AuthorityReferencePath)) {
            throw 'AuthorityReferencePath is required and must identify the trusted committed owner decision.'
        }
        $authority = Read-V02ReleaseGateAuthorityReference -RepositoryRoot $identityBefore.RepositoryRoot `
            -AuthorityReferencePath $AuthorityReferencePath
        if ([string]::IsNullOrWhiteSpace($IndependentCandidateReceiptPath)) {
            throw 'IndependentCandidateReceiptPath is required and must identify an externally authenticated candidate-specific receipt.'
        }
        if ([string]::IsNullOrWhiteSpace($CandidateLockPath)) {
            throw 'CandidateLockPath is required and must identify an immutable approved candidate lock.'
        }
        $candidateLock = Read-V02ReleaseGateCandidateLock -Path $CandidateLockPath -EvidenceRoot $evidenceRootPath `
            -ExpectedSourceCommit $ExpectedSourceCommit -ExpectedSourceTree $ExpectedSourceTree `
            -PackageProfilePath $profilePath -RepositoryRoot $identityBefore.RepositoryRoot `
            -AuthorityReferencePath $AuthorityReferencePath -IndependentCandidateReceiptPath $IndependentCandidateReceiptPath
    }
    catch {
        $report = New-V02ReleaseGateNotReadyReport -Identity $identityBefore -Reason $_.Exception.Message `
            -CandidateLock $candidateLock -Authority $authority
        if (-not [string]::IsNullOrWhiteSpace($OutputPath)) {
            $written = Write-V02ReleaseGateReport -Report $report -OutputPath $OutputPath
            $report | Add-Member -MemberType NoteProperty -Name ReportJsonPath -Value $written.JsonPath
            $report | Add-Member -MemberType NoteProperty -Name ReportTextPath -Value $written.TextPath
        }
        return $report
    }

    $context = [pscustomobject][ordered]@{
        RepositoryRoot = $identityBefore.RepositoryRoot
        IdentityPath = Resolve-V02ReleaseGateExistingPath -Path $PackageIdentityPath -Type Leaf -Context 'Package identity receipt'
        ArchivePath = Resolve-V02ReleaseGateExistingPath -Path $PackageArchivePath -Type Leaf -Context 'Package ZIP archive'
        PackageRoot = Resolve-V02ReleaseGateExistingPath -Path $ExtractedPackageRoot -Type Container -Context 'Extracted package root'
        ProfilePath = $profilePath
        ManifestPath = Resolve-V02ReleaseGateExistingPath -Path $RendererManifestPath -Type Leaf -Context 'Renderer compatibility manifest'
        EvidenceRoot = $rendererEvidenceRootPath
        ReleaseEvidenceRoot = $evidenceRootPath
        ThaiEvidenceDirectory = Resolve-V02ReleaseGateExistingPath -Path $ThaiEvidenceDirectory -Type Container -Context 'Thai evidence directory'
        EnglishEvidenceDirectory = Resolve-V02ReleaseGateExistingPath -Path $EnglishEvidenceDirectory -Type Container -Context 'English evidence directory'
    }

    $packageManifestPath = Resolve-V02ReleaseGateExistingPath -Path (Join-Path $context.PackageRoot 'package-manifest.json') -Type Leaf -Context 'Package manifest'
    $appPath = Resolve-V02ReleaseGateExistingPath -Path (Join-Path $context.PackageRoot 'HerdrOps.App.exe') -Type Leaf -Context 'Package App executable'
    $corePath = Resolve-V02ReleaseGateExistingPath -Path (Join-Path $context.PackageRoot 'HerdrOps.Core.exe') -Type Leaf -Context 'Package Core executable'
    $boundFilePaths = @(
        $context.IdentityPath, $context.ArchivePath, $packageManifestPath, $appPath, $corePath, $context.ProfilePath,
        $context.ManifestPath, (Resolve-V02ReleaseGateExistingPath -Path $RuntimeMatrixManifestPath -Type Leaf -Context 'Runtime matrix manifest'),
        (Resolve-V02ReleaseGateExistingPath -Path $Issue9CandidatePath -Type Leaf -Context 'Issue #9 runtime candidate'),
        (Resolve-V02ReleaseGateExistingPath -Path $ContractEvidencePath -Type Leaf -Context 'Contract evidence receipt'),
        (Resolve-V02ReleaseGateExistingPath -Path $SyntheticEvidencePath -Type Leaf -Context 'Synthetic evidence receipt'),
        (Resolve-V02ReleaseGateExistingPath -Path $HumanReviewPath -Type Leaf -Context 'Human review record'),
        (Resolve-V02ReleaseGateExistingPath -Path $CleanMachineReportPath -Type Leaf -Context 'Clean-machine acceptance report'),
        (Resolve-V02ReleaseGateExistingPath -Path $CleanHostAuthorizationPath -Type Leaf -Context 'Clean-host authorization'),
        (Resolve-V02ReleaseGateExistingPath -Path $CleanHostAuthorizationSignaturePath -Type Leaf -Context 'Clean-host authorization signature'),
        (Resolve-V02ReleaseGateExistingPath -Path $CleanHostAcceptanceReceiptPath -Type Leaf -Context 'Clean-host acceptance receipt'),
        (Resolve-V02ReleaseGateExistingPath -Path $CleanHostAcceptanceReceiptSignaturePath -Type Leaf -Context 'Clean-host acceptance receipt signature'),
        (Resolve-V02ReleaseGateExistingPath -Path $GitHubSnapshotPath -Type Leaf -Context 'GitHub snapshot'),
        $candidateLock.Path, $authority.Path, $candidateLock.IndependentReceipt.Path
    )
    $validatorSnapshots = Get-V02ReleaseGateValidatorSnapshots -RepositoryRoot $identityBefore.RepositoryRoot
    $boundSnapshots = New-Object System.Collections.Generic.List[object]
    $preValidationSnapshots = $null
    try {
        foreach ($filePath in $boundFilePaths) {
            [void]$boundSnapshots.Add((Get-V02ReleaseGateStableFileSnapshot -Path $filePath -Context 'Pre-validation bound artifact' -KeepOpen))
        }
        $preValidationSnapshots = @(
            $validatorSnapshots
            $boundSnapshots.ToArray()
        )
        Assert-V02ReleaseGateDistinctFileIdentities -Snapshots $preValidationSnapshots -Context 'Pre-validation bound artifacts and validators'

    $package = Invoke-V02ReleaseGatePackageValidation -Context $context `
        -ExpectedSourceCommit $ExpectedSourceCommit -ExpectedSourceTree $ExpectedSourceTree
    # Capture the script's own launcher body only after the exact process argv
    # proves this file is the direct -File entrypoint. No caller-supplied
    # scriptblock or unqualified dynamic command lookup participates in credit.
    $directCleanMachineVerifier = ${function:Invoke-V02ReleaseGateIsolatedCleanMachineVerifier}
    $isolatedCleanMachine = & $directCleanMachineVerifier `
        -ReportPath $CleanMachineReportPath -AuthorizationPath $CleanHostAuthorizationPath `
        -AuthorizationSignaturePath $CleanHostAuthorizationSignaturePath `
        -AcceptanceReceiptPath $CleanHostAcceptanceReceiptPath `
        -AcceptanceReceiptSignaturePath $CleanHostAcceptanceReceiptSignaturePath `
        -ExpectedSourceCommit $ExpectedSourceCommit -ExpectedSourceTree $ExpectedSourceTree -Package $package
    $cleanMachine = [pscustomobject][ordered]@{
        Path=[IO.Path]::GetFullPath($CleanMachineReportPath);FileSha256=[string]$isolatedCleanMachine.reportSha256
        EvidenceClass='CleanMachine';Status='PASS';Mode='Live';RunId=[string]$isolatedCleanMachine.runId
        MachineFingerprint=[string]$isolatedCleanMachine.machineFingerprint;OperatorIdentity=[string]$isolatedCleanMachine.operatorIdentity
        ObserverIdentity=[string]$isolatedCleanMachine.observerIdentity;AuthorizationSignerThumbprint=[string]$isolatedCleanMachine.authorizationSignerThumbprint
        AcceptanceReceiptSha256=[string]$isolatedCleanMachine.acceptanceReceiptSha256;AcceptanceReceiptSignatureSha256=[string]$isolatedCleanMachine.acceptanceReceiptSignatureSha256
        AcceptanceReceiptNonce=[string]$isolatedCleanMachine.acceptanceReceiptNonce;LifecycleCreditGranted=$true
        Runtime='NOT_OBSERVED';Human='NOT_OBSERVED';Release='NOT_OBSERVED'
    }
    Assert-V02ReleaseGateBoundSnapshots -Snapshots $preValidationSnapshots -Phase 'Post-package validation'
    $renderer = Invoke-V02ReleaseGateRendererValidation -Context $context -Package $package `
        -ExpectedSourceCommit $ExpectedSourceCommit -ExpectedSourceTree $ExpectedSourceTree
    Assert-V02ReleaseGateBoundSnapshots -Snapshots $preValidationSnapshots -Phase 'Post-renderer validation'
    $contract = Read-V02ReleaseGateEvidenceReceipt -Path $ContractEvidencePath -ExpectedClass Contract `
        -ExpectedSourceCommit $ExpectedSourceCommit -ExpectedSourceTree $ExpectedSourceTree -EvidenceRoot $evidenceRootPath
    $synthetic = Read-V02ReleaseGateEvidenceReceipt -Path $SyntheticEvidencePath -ExpectedClass Synthetic `
        -ExpectedSourceCommit $ExpectedSourceCommit -ExpectedSourceTree $ExpectedSourceTree -EvidenceRoot $evidenceRootPath
    $matrix = Invoke-V02ReleaseGateMatrixValidation -Context $context -Package $package `
        -ExpectedSourceCommit $ExpectedSourceCommit -ExpectedSourceTree $ExpectedSourceTree `
        -RuntimeMatrixManifestPath $RuntimeMatrixManifestPath
    $issue9 = Invoke-V02ReleaseGateIssue9Validation -Context $context -Package $package -Matrix $matrix `
        -ExpectedSourceCommit $ExpectedSourceCommit -ExpectedSourceTree $ExpectedSourceTree -Issue9CandidatePath $Issue9CandidatePath
    Assert-V02ReleaseGateCandidateByteBinding -CandidateLock $candidateLock -Package $package -Renderer $renderer -Matrix $matrix -Issue9 $issue9
    Assert-V02ReleaseGateIndependentReceiptBinding -IndependentReceipt $candidateLock.IndependentReceipt `
        -CandidateLock $candidateLock -Identity $identityBefore -Package $package -Renderer $renderer -Matrix $matrix -Issue9 $issue9
    Assert-V02ReleaseGateBoundSnapshots -Snapshots $preValidationSnapshots -Phase 'Post-matrix/Issue9 validation'
    try {
        $githubDocument = Read-V02ReleaseGateJsonFile -Path $GitHubSnapshotPath -Context 'GitHub read-only snapshot'
        $githubAssessment = Assert-V02ReleaseGateGitHubSnapshot $githubDocument.Value
        $reviewDocument = Read-V02ReleaseGateJsonFile -Path $HumanReviewPath -Context 'Human review record'
        $humanDisposition = Assert-V02ReleaseGateHumanReview -Review $reviewDocument.Value -ReviewPath $reviewDocument.Path -ExpectedSourceCommit $ExpectedSourceCommit `
            -ExpectedSourceTree $ExpectedSourceTree -Package $package -Renderer $renderer -Matrix $matrix -Issue9 $issue9 `
            -GitHubSnapshotPath $githubDocument.Path -GitHubSnapshotSha256 $githubDocument.FileSha256 -EvidenceRoot $evidenceRootPath
    }
    catch {
        $report = New-V02ReleaseGateNotReadyReport -Identity $identityBefore `
            -Reason "Unauthenticated Human/GitHub evidence was rejected: $($_.Exception.Message)" `
            -CandidateLock $candidateLock -Authority $authority
        if (-not [string]::IsNullOrWhiteSpace($OutputPath)) {
            $written = Write-V02ReleaseGateReport -Report $report -OutputPath $OutputPath
            $report | Add-Member -MemberType NoteProperty -Name ReportJsonPath -Value $written.JsonPath
            $report | Add-Member -MemberType NoteProperty -Name ReportTextPath -Value $written.TextPath
        }
        return $report
    }
    Assert-V02ReleaseGateBoundSnapshots -Snapshots $preValidationSnapshots -Phase 'Post-evidence validation'

    $identityAfter = Get-V02ReleaseGateGitIdentity -RepositoryRoot $identityBefore.RepositoryRoot
    Assert-V02ReleaseGateGitIdentity $identityAfter $ExpectedSourceCommit $ExpectedSourceTree 'Postflight'
    if ($identityBefore.Commit -cne $identityAfter.Commit -or $identityBefore.Tree -cne $identityAfter.Tree) {
        throw 'Source identity changed during v0.2 release-gate validation.'
    }

    Assert-V02ReleaseGateBoundSnapshots -Snapshots $preValidationSnapshots -Phase 'Final post-validation'

    $report = [pscustomobject][ordered]@{
        SchemaVersion = 2
        Version = $script:V02ReleaseGateVersion
        Result = 'NOT_READY'
        ReleaseReady = $false
        SourceCommit = $ExpectedSourceCommit
        SourceTree = $ExpectedSourceTree
        SourceParents = @($identityAfter.Parents)
        RepositoryRoot = $identityAfter.RepositoryRoot
        CandidateLock = $candidateLock
        AuthorityReference = $authority
        ValidatorHelperSnapshots = @($validatorSnapshots | ForEach-Object {
                [pscustomobject][ordered]@{
                    Path = $_.Path
                    FinalPath = $_.FinalPath
                    FileId = $_.FileId
                    Length = $_.Length
                    Sha256 = $_.Sha256
                }
            })
        GateReason = 'NO_INDEPENDENT_RUNTIME_HUMAN_RELEASE_RECEIPTS'
        Package = [pscustomobject][ordered]@{
            EvidenceClass = $package.EvidenceClass
            ProfileId = $package.ProfileId
            ReceiptSchemaSha256 = $script:V02ReleaseGatePackageReceiptSchemaSha256
            ReceiptSha256 = $package.ReceiptSha256
            ReceiptFileSha256 = $package.ReceiptFileSha256
            ArchiveSha256 = $package.ArchiveSha256
            ManifestSha256 = $package.ManifestSha256
            AppSha256 = $package.AppSha256
            CoreSha256 = $package.CoreSha256
            ProfileFileSha256 = $package.ProfileFileSha256
            ProfileCanonicalSha256 = $package.ProfileCanonicalSha256
            ReferenceHostProfileSha256 = $package.ReferenceHostProfileSha256
            RendererPolicySha256 = $package.RendererPolicySha256
        }
        Renderer = [pscustomobject][ordered]@{
            EvidenceClass = [string]$renderer.Result.EvidenceClassification
            ManifestPath = $renderer.ManifestPath
            ManifestSha256 = $renderer.ManifestSha256
            BindingValidation = [string]$renderer.Result.BindingValidation
            OwnerNumericLimits = [string]$renderer.Result.OwnerNumericLimits
            HumanReviewInCandidate = [string]$renderer.Result.HumanReview
            CreditGranted = [bool]$renderer.Result.CreditGranted
        }
        RuntimeMatrix = [pscustomobject][ordered]@{
            EvidenceClass = [string]$matrix.Candidate.EvidenceClassification
            ManifestPath = $matrix.ManifestPath
            ManifestFileSha256 = $matrix.ManifestFileSha256
            ManifestPayloadSha256 = $matrix.ManifestPayloadSha256
            IndependentHumanReview = [string]$matrix.Candidate.IndependentHumanReview
            ReleaseCredit = [bool]$matrix.Candidate.ReleaseCredit
            Languages = @('Thai', 'English')
        }
        Issue9 = [pscustomobject][ordered]@{
            EvidenceClass = [string]$issue9.Candidate.EvidenceClassification
            CandidatePath = $issue9.CandidatePath
            CandidateSha256 = $issue9.CandidateSha256
            Result = $issue9.Result
            Runtime = $issue9.Runtime
            Human = $issue9.Human
            Release = $issue9.Release
        }
        ContractEvidence = [pscustomobject][ordered]@{
            Path = $contract.Path
            FileSha256 = $contract.FileSha256
            CheckCount = $contract.CheckCount
        }
        SyntheticEvidence = [pscustomobject][ordered]@{
            Path = $synthetic.Path
            FileSha256 = $synthetic.FileSha256
            CheckCount = $synthetic.CheckCount
        }
        GitHub = [pscustomobject][ordered]@{
            Status = [string]$githubAssessment.Status
            Authenticated = [bool]$githubAssessment.Authenticated
            SnapshotPath = $githubDocument.Path
            SnapshotSha256 = $githubDocument.FileSha256
            MilestoneNumber = $githubAssessment.MilestoneNumber
            MilestoneState = $githubAssessment.MilestoneState
            TrackerIssue = $githubAssessment.TrackerIssue
            OpenV02IssueCount = $githubAssessment.OpenV02IssueCount
        }
        HumanReview = [pscustomobject][ordered]@{
            Status = [string]$humanDisposition.Status
            Authenticated = [bool]$humanDisposition.Authenticated
            EvidenceClass = 'Human'
            ReviewerIdentity = [string]$reviewDocument.Value.Reviewer.Identity
            ReviewerRole = [string]$reviewDocument.Value.Reviewer.Role
            ReviewFileSha256 = $reviewDocument.FileSha256
            Decision = [string]$humanDisposition.Decision
            RoleDistinct = [bool]$reviewDocument.Value.Reviewer.RoleDistinct
            OpenFindingCount = @($reviewDocument.Value.OpenFindings).Count
        }
        CleanMachine = $cleanMachine
        EvidenceClasses = [pscustomobject][ordered]@{
            Static = [pscustomobject][ordered]@{ Status = 'PASS'; Classification = 'Static/PackagedCompatibilityPreparation'; Credit = 'PREPARATION_ONLY' }
            Contract = [pscustomobject][ordered]@{ Status = 'PASS'; Classification = 'Contract'; Credit = 'CONTRACT_ONLY' }
            Synthetic = [pscustomobject][ordered]@{ Status = 'PASS'; Classification = 'Synthetic'; Credit = 'SYNTHETIC_ONLY' }
            Runtime = [pscustomobject][ordered]@{ Status = 'NOT_OBSERVED'; Classification = 'RuntimeMatrixCandidate'; Credit = 'CANDIDATE_ONLY' }
            Human = [pscustomobject][ordered]@{ Status = 'NOT_OBSERVED'; Classification = 'Human'; Credit = 'UNAUTHENTICATED_LOCAL_RECORD' }
            Release = [pscustomobject][ordered]@{ Status = 'NOT_OBSERVED'; Classification = 'Release'; Credit = 'NONE' }
        }
        EvidenceBoundary = [pscustomobject][ordered]@{
            ActualHerdrControlInvoked = $false
            GitHubMutationInvoked = $false
            PackagePublished = $false
            ReleasePublished = $false
            RuntimeMatrixRemainsCandidate = $true
            RuntimeObserved = $false
            HumanAuthorityObserved = $false
            ReleaseCreditBoundToExactCandidate = $false
        }
    }
    if (-not [string]::IsNullOrWhiteSpace($OutputPath)) {
        $written = Write-V02ReleaseGateReport -Report $report -OutputPath $OutputPath
        $report | Add-Member -MemberType NoteProperty -Name ReportJsonPath -Value $written.JsonPath
        $report | Add-Member -MemberType NoteProperty -Name ReportTextPath -Value $written.TextPath
    }
    return $report
    }
    finally {
        if ($null -ne $preValidationSnapshots) {
            Close-V02ReleaseGateHeldSnapshots -Snapshots $preValidationSnapshots
        }
        else {
            Close-V02ReleaseGateHeldSnapshots -Snapshots @($validatorSnapshots; $boundSnapshots.ToArray())
        }
    }
}

# Dot-sourcing imports the functions for read-only selftests without invoking
# the production gate. Direct execution is the only path that runs the gate.
if ($MyInvocation.InvocationName -ne '.') {
    $directDefinitionPath = [IO.Path]::GetFullPath($MyInvocation.MyCommand.Path)
    $directCommandLine = @([Environment]::GetCommandLineArgs())
    $directFileAuthorized = $false
    $directCursor = 1
    $directSeenHostSwitches = @{}
    while ($directCursor -lt $directCommandLine.Count -and [string]$directCommandLine[$directCursor] -ine '-File') {
        $directHostSwitch = [string]$directCommandLine[$directCursor]
        if ($directHostSwitch -in @('-NoLogo','-NoProfile','-NonInteractive') -and -not $directSeenHostSwitches.ContainsKey($directHostSwitch.ToUpperInvariant())) {
            $directSeenHostSwitches[$directHostSwitch.ToUpperInvariant()]=$true;$directCursor++;continue
        }
        if ($directHostSwitch -ieq '-ExecutionPolicy' -and -not $directSeenHostSwitches.ContainsKey('EXECUTIONPOLICY') -and
            $directCursor + 1 -lt $directCommandLine.Count -and [string]$directCommandLine[$directCursor + 1] -ieq 'Bypass') {
            $directSeenHostSwitches['EXECUTIONPOLICY']=$true;$directCursor+=2;continue
        }
        $directCursor=$directCommandLine.Count;break
    }
    if ($directCursor + 1 -lt $directCommandLine.Count -and [string]$directCommandLine[$directCursor] -ieq '-File') {
        try { $directFileAuthorized=[StringComparer]::OrdinalIgnoreCase.Equals([IO.Path]::GetFullPath([string]$directCommandLine[$directCursor+1]),$directDefinitionPath) }
        catch { $directFileAuthorized=$false }
    }
    if (-not $directFileAuthorized) {
        throw 'Production release-gate execution must use a clean PowerShell process with exact -File Test-V02ReleaseGate.ps1.'
    }
    $directGate = ${function:Invoke-V02ReleaseGate}
    & $directGate `
        -ExpectedSourceCommit $ExpectedSourceCommit `
        -ExpectedSourceTree $ExpectedSourceTree `
        -PackageIdentityPath $PackageIdentityPath `
        -PackageArchivePath $PackageArchivePath `
        -ExtractedPackageRoot $ExtractedPackageRoot `
        -PackageProfilePath $PackageProfilePath `
        -RendererManifestPath $RendererManifestPath `
        -ThaiEvidenceDirectory $ThaiEvidenceDirectory `
        -EnglishEvidenceDirectory $EnglishEvidenceDirectory `
        -RuntimeMatrixManifestPath $RuntimeMatrixManifestPath `
        -Issue9CandidatePath $Issue9CandidatePath `
        -ContractEvidencePath $ContractEvidencePath `
        -SyntheticEvidencePath $SyntheticEvidencePath `
        -HumanReviewPath $HumanReviewPath `
        -CleanMachineReportPath $CleanMachineReportPath `
        -CleanHostAuthorizationPath $CleanHostAuthorizationPath `
        -CleanHostAuthorizationSignaturePath $CleanHostAuthorizationSignaturePath `
        -CleanHostAcceptanceReceiptPath $CleanHostAcceptanceReceiptPath `
        -CleanHostAcceptanceReceiptSignaturePath $CleanHostAcceptanceReceiptSignaturePath `
        -GitHubSnapshotPath $GitHubSnapshotPath `
        -CandidateLockPath $CandidateLockPath `
        -AuthorityReferencePath $AuthorityReferencePath `
        -IndependentCandidateReceiptPath $IndependentCandidateReceiptPath `
        -EvidenceRoot $EvidenceRoot `
        -RepositoryRoot $RepositoryRoot `
        -RendererEvidenceRoot $RendererEvidenceRoot `
        -OutputPath $OutputPath | Out-Host
}
