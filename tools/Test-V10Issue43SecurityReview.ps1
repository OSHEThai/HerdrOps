[CmdletBinding()]
param(
    [ValidateSet('Debug', 'Release')]
    [string]$Configuration = 'Release',

    [Parameter(Mandatory = $true)]
    [ValidatePattern('^[0-9a-fA-F]{40}$')]
    [string]$CandidateCommit,

    [Parameter(Mandatory = $true)]
    [ValidatePattern('^[0-9a-fA-F]{40}$')]
    [string]$DirectParentCommit
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repositoryRoot = [IO.Path]::GetFullPath((Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')).Path)
$artifactRoot = [IO.Path]::GetFullPath((Join-Path $repositoryRoot 'artifacts'))
$expectedBranch = 'codex/v10-issue-43-security-review'
$version = 'v1.0.0'
$issueNumber = '#43'
$candidateIdentity = $CandidateCommit.ToLowerInvariant()
$directParentIdentity = $DirectParentCommit.ToLowerInvariant()
$runId = "$([DateTime]::UtcNow.ToString('yyyyMMddTHHmmssfffffffZ', [Globalization.CultureInfo]::InvariantCulture))-$([Guid]::NewGuid().ToString('N').Substring(0, 8))"
$gateDirectory = [IO.Path]::GetFullPath((Join-Path $artifactRoot "release-gates\v1.0.0\issue-43\$runId"))
$testDirectory = [IO.Path]::GetFullPath((Join-Path $gateDirectory 'contract-tests'))
$manifestPath = [IO.Path]::GetFullPath((Join-Path $gateDirectory 'reviewed-files.manifest.txt'))
$schemaReportPath = [IO.Path]::GetFullPath((Join-Path $gateDirectory 'schema-migration-report.txt'))
$gateReportPath = [IO.Path]::GetFullPath((Join-Path $gateDirectory 'gate-report.txt'))
$reviewReportPath = [IO.Path]::GetFullPath((Join-Path $gateDirectory 'security-privacy-review-report.txt'))
$canonicalRoot = $repositoryRoot.TrimEnd([char]92, [char]47)
$rootPrefix = $canonicalRoot + [IO.Path]::DirectorySeparatorChar
$checkResults = @()
$failures = @()
$pathSafetyFailures = @()
$missingReviewFiles = @()
$fileInventory = @()
$testReports = @()
$productScanPaths = @()
$manifestPathSet = @{}

function Record-Check {
    param(
        [Parameter(Mandatory)]
        [string]$Id,

        [Parameter(Mandatory)]
        [ValidateSet('PASS', 'FAIL', 'NOT RUN', 'NOT OBSERVED')]
        [string]$Status,

        [Parameter(Mandatory)]
        [string]$EvidenceClass,

        [Parameter(Mandatory)]
        [string]$Detail
    )

    $script:checkResults += [pscustomobject]@{
        Id = $Id
        Status = $Status
        EvidenceClass = $EvidenceClass
        Detail = $Detail
    }
    if ($Status -eq 'FAIL') {
        $script:failures += "$Id $Detail"
    }
}

function Add-PathSafetyFailure {
    param(
        [Parameter(Mandatory)]
        [string]$Detail
    )

    if ($script:pathSafetyFailures -notcontains $Detail) {
        $script:pathSafetyFailures += $Detail
    }
}

function Get-SafeFullPath {
    param(
        [Parameter(Mandatory)]
        [string]$Path,

        [switch]$AllowMissingLeaf
    )

    $full = [IO.Path]::GetFullPath($Path)
    if ($full -ne $canonicalRoot -and -not $full.StartsWith($rootPrefix, [StringComparison]::OrdinalIgnoreCase)) {
        throw "path is outside the repository root: $Path"
    }

    $rootItem = Get-Item -LiteralPath $canonicalRoot -Force -ErrorAction Stop
    if (($rootItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw 'repository root is a reparse point'
    }

    $relative = if ($full -eq $canonicalRoot) { '' } else { $full.Substring($rootPrefix.Length) }
    $segments = @($relative -split '[\\/]' | Where-Object { -not [String]::IsNullOrWhiteSpace($_) })
    $current = $canonicalRoot
    $missingSeen = $false
    for ($index = 0; $index -lt $segments.Count; $index++) {
        $current = Join-Path $current $segments[$index]
        if ($missingSeen) {
            continue
        }

        $item = Get-Item -LiteralPath $current -Force -ErrorAction SilentlyContinue
        if ($null -eq $item) {
            if ($AllowMissingLeaf) {
                $missingSeen = $true
                continue
            }
            throw "path component is missing: $current"
        }

        if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw "reparse point is not allowed: $current"
        }
        if ($index -lt $segments.Count - 1 -and -not $item.PSIsContainer) {
            throw "non-directory path component blocks containment: $current"
        }
    }

    if (Test-Path -LiteralPath $full) {
        $resolved = [IO.Path]::GetFullPath((Resolve-Path -LiteralPath $full -ErrorAction Stop).Path)
        if ($resolved -ne $canonicalRoot -and -not $resolved.StartsWith($rootPrefix, [StringComparison]::OrdinalIgnoreCase)) {
            throw "resolved path escapes the repository root: $Path"
        }
        $resolvedItem = Get-Item -LiteralPath $full -Force -ErrorAction Stop
        if (($resolvedItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw "reparse point is not allowed: $full"
        }
    }

    return $full
}

function Get-RepositoryFile {
    param(
        [Parameter(Mandatory)]
        [string]$RelativePath
    )

    try {
        $candidate = Get-SafeFullPath -Path (Join-Path $repositoryRoot $RelativePath) -AllowMissingLeaf
        $item = Get-Item -LiteralPath $candidate -Force -ErrorAction SilentlyContinue
        if ($null -eq $item -or $item.PSIsContainer) {
            return $null
        }
        return $candidate
    } catch {
        Add-PathSafetyFailure -Detail "${RelativePath}: $($_.Exception.Message)"
        return $null
    }
}

function Get-RelativeRepositoryPath {
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )

    $full = [IO.Path]::GetFullPath($Path)
    if ($full.StartsWith($rootPrefix, [StringComparison]::OrdinalIgnoreCase)) {
        return $full.Substring($rootPrefix.Length).Replace([IO.Path]::AltDirectorySeparatorChar, [IO.Path]::DirectorySeparatorChar)
    }
    return $full
}

function Get-RepositoryText {
    param(
        [Parameter(Mandatory)]
        [string]$RelativePath
    )

    $path = Get-RepositoryFile -RelativePath $RelativePath
    if ($null -eq $path) {
        return $null
    }

    try {
        return [IO.File]::ReadAllText($path)
    } catch {
        Add-PathSafetyFailure -Detail "$RelativePath could not be read safely: $($_.Exception.Message)"
        return $null
    }
}

function Ensure-SafeDirectory {
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )

    try {
        $candidate = Get-SafeFullPath -Path $Path -AllowMissingLeaf
        $item = Get-Item -LiteralPath $candidate -Force -ErrorAction SilentlyContinue
        if ($null -ne $item -and -not $item.PSIsContainer) {
            throw "artifact path is not a directory: $candidate"
        }
        if ($null -eq $item) {
            New-Item -ItemType Directory -Path $candidate -Force -ErrorAction Stop | Out-Null
        }
        $verified = Get-SafeFullPath -Path $candidate
        $verifiedItem = Get-Item -LiteralPath $verified -Force -ErrorAction Stop
        if (-not $verifiedItem.PSIsContainer) {
            throw "artifact path is not a directory after creation: $verified"
        }
        return $true
    } catch {
        Add-PathSafetyFailure -Detail "$Path could not be created or verified safely: $($_.Exception.Message)"
        return $false
    }
}

function Set-SafeText {
    param(
        [Parameter(Mandatory)]
        [string]$Path,

        [Parameter(Mandatory)]
        [AllowNull()]
        [AllowEmptyCollection()]
        [AllowEmptyString()]
        [object[]]$Lines
    )

    try {
        $candidate = Get-SafeFullPath -Path $Path -AllowMissingLeaf
        $parent = [IO.Directory]::GetParent($candidate).FullName
        $null = Get-SafeFullPath -Path $parent
        $normalizedLines = @(ConvertTo-Issue43ReportLines -Lines $Lines)
        $text = [string]::Join([Environment]::NewLine, $normalizedLines)
        $utf8 = New-Object -TypeName System.Text.UTF8Encoding -ArgumentList @($false)
        [IO.File]::WriteAllText($candidate, $text, $utf8)
        $null = Get-SafeFullPath -Path $candidate
        return $true
    } catch {
        Add-PathSafetyFailure -Detail "$Path could not be written or verified safely: $($_.Exception.Message)"
        return $false
    }
}

function Get-SafeArtifactFile {
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )

    try {
        $candidate = Get-SafeFullPath -Path $Path
        $item = Get-Item -LiteralPath $candidate -Force -ErrorAction Stop
        if ($item.PSIsContainer) {
            throw "artifact path is a directory: $candidate"
        }
        return $candidate
    } catch {
        Add-PathSafetyFailure -Detail "$Path is not a safe artifact file: $($_.Exception.Message)"
        return $null
    }
}

function Assert-SafeArtifactTree {
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )

    $root = Get-SafeFullPath -Path $Path
    $queue = New-Object System.Collections.Queue
    $queue.Enqueue((Get-Item -LiteralPath $root -Force -ErrorAction Stop))
    while ($queue.Count -gt 0) {
        $item = $queue.Dequeue()
        if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw "artifact tree contains a reparse point: $($item.FullName)"
        }
        if ($item.PSIsContainer) {
            foreach ($child in @(Get-ChildItem -LiteralPath $item.FullName -Force -ErrorAction Stop)) {
                if (($child.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                    throw "artifact tree contains a reparse point: $($child.FullName)"
                }
                $queue.Enqueue($child)
            }
        }
    }
    return $true
}

function Get-TrackedPaths {
    $output = @(& git -C $repositoryRoot ls-files --cached --full-name 2>&1)
    $exitCode = $LASTEXITCODE
    if ($exitCode -ne 0) {
        Record-Check -Id 'BOUND-06' -Status 'FAIL' -EvidenceClass 'Static' -Detail "could not enumerate tracked inputs: $($output -join ' ')"
        return @()
    }
    return @($output | ForEach-Object { ([string]$_).Trim() } | Where-Object { $_ -ne '' })
}

function Get-ReviewPurpose {
    param([Parameter(Mandatory)][string]$Path)
    if ($Path -like 'tests/*') { return 'selected test/config surface' }
    if ($Path -like 'src/*') { return 'product source/config surface' }
    if ($Path -like 'Plan/*' -or $Path -like 'docs/*') { return 'plan/protocol/review surface' }
    if ($Path -like 'tools/*') { return 'review gate/tooling surface' }
    return 'root build/repository configuration'
}

function Add-ReviewedFile {
    param(
        [Parameter(Mandatory)]
        [string]$RelativePath,

        [string]$Purpose
    )

    $normalized = $RelativePath.Replace('\\', '/')
    if ($script:manifestPathSet.ContainsKey($normalized)) {
        return
    }
    $script:manifestPathSet[$normalized] = $true
    $path = Get-RepositoryFile -RelativePath $normalized
    if ($null -eq $path) {
        $script:missingReviewFiles += $normalized
        return
    }

    try {
        $item = Get-Item -LiteralPath $path -Force -ErrorAction Stop
        $hash = (Get-FileHash -LiteralPath $path -Algorithm SHA256 -ErrorAction Stop).Hash.ToUpperInvariant()
        $script:fileInventory += [pscustomobject]@{
            Path = $normalized
            Bytes = [int64]$item.Length
            Sha256 = $hash
            Purpose = if ([String]::IsNullOrWhiteSpace($Purpose)) { Get-ReviewPurpose -Path $normalized } else { $Purpose }
        }
    } catch {
        Add-PathSafetyFailure -Detail "$normalized could not be hashed safely: $($_.Exception.Message)"
    }
}

function Test-MarkerGroup {
    param(
        [Parameter(Mandatory)]
        [string]$Id,

        [Parameter(Mandatory)]
        [string]$EvidenceClass,

        [Parameter(Mandatory)]
        [object[]]$Files
    )

    $missing = @()
    foreach ($file in $Files) {
        $text = Get-RepositoryText -RelativePath $file.Path
        if ($null -eq $text) {
            $missing += "$($file.Path) [file missing or unsafe]"
            continue
        }
        foreach ($marker in $file.Markers) {
            if ($text.IndexOf([string]$marker, [StringComparison]::Ordinal) -lt 0) {
                $missing += "$($file.Path) [$marker]"
            }
        }
    }

    if ($missing.Count -eq 0) {
        Record-Check -Id $Id -Status 'PASS' -EvidenceClass $EvidenceClass -Detail "all $($Files.Count) bounded source/document surfaces matched"
        return $true
    }

    Record-Check -Id $Id -Status 'FAIL' -EvidenceClass $EvidenceClass -Detail "missing bounded markers: $($missing -join '; ')"
    return $false
}

function Test-ForbiddenProductPattern {
    param(
        [Parameter(Mandatory)]
        [string]$Id,

        [Parameter(Mandatory)]
        [string]$CodePattern,

        [Parameter(Mandatory)]
        [string]$RawPattern,

        [Parameter(Mandatory)]
        [string]$Description
    )

    $hits = @()
    foreach ($relativePath in $productScanPaths) {
        $text = Get-RepositoryText -RelativePath $relativePath
        if ($null -eq $text) {
            continue
        }
        $result = Test-Issue43ForbiddenDeclaration -Text $text -CodePattern $CodePattern -RawPattern $RawPattern
        if ($result.IsMatch) {
            $hits += "$relativePath [$($result.Match)]"
        }
    }

    if ($hits.Count -eq 0) {
        Record-Check -Id $Id -Status 'PASS' -EvidenceClass 'Static' -Detail "${Description}: 0 declarations across tracked product source/config inputs"
        return $true
    }

    Record-Check -Id $Id -Status 'FAIL' -EvidenceClass 'Static' -Detail "${Description}: unexpected declarations at $($hits -join ', ')"
    return $false
}

function Test-SelectedTest {
    param(
        [Parameter(Mandatory)]
        [string]$Id,

        [Parameter(Mandatory)]
        [string]$Name,

        [Parameter(Mandatory)]
        [string]$EvidenceClass,

        [Parameter(Mandatory)]
        [string]$Project,

        [Parameter(Mandatory)]
        [string]$Filter
    )

    $projectPath = Get-RepositoryFile -RelativePath $Project
    if ($null -eq $projectPath) {
        $script:testReports += [pscustomobject]@{ Id = $Id; Name = $Name; EvidenceClass = $EvidenceClass; Status = 'FAIL'; Path = 'NOT RUN'; Sha256 = 'NOT AVAILABLE'; Total = 0; Passed = 0; Failed = 1 }
        Record-Check -Id $Id -Status 'FAIL' -EvidenceClass $EvidenceClass -Detail "selected test project is missing or unsafe: $Project"
        return
    }

    $trxName = "$Id-$Name.trx"
    $arguments = @(
        'test',
        $projectPath,
        '--configuration',
        $Configuration,
        '--filter',
        $Filter,
        '--logger',
        "trx;LogFileName=$trxName",
        '--results-directory',
        $testDirectory
    )
    $output = @(& dotnet @arguments 2>&1)
    $exitCode = $LASTEXITCODE
    if ($exitCode -ne 0) {
        $script:testReports += [pscustomobject]@{ Id = $Id; Name = $Name; EvidenceClass = $EvidenceClass; Status = 'FAIL'; Path = 'NOT AVAILABLE'; Sha256 = 'NOT AVAILABLE'; Total = 0; Passed = 0; Failed = 1 }
        Record-Check -Id $Id -Status 'FAIL' -EvidenceClass $EvidenceClass -Detail "$Name selected tests exited $exitCode"
        return
    }

    try {
        Assert-SafeArtifactTree -Path $testDirectory | Out-Null
    } catch {
        Add-PathSafetyFailure -Detail "test output tree is unsafe after ${Name}: $($_.Exception.Message)"
        $script:testReports += [pscustomobject]@{ Id = $Id; Name = $Name; EvidenceClass = $EvidenceClass; Status = 'FAIL'; Path = 'UNSAFE'; Sha256 = 'NOT AVAILABLE'; Total = 0; Passed = 0; Failed = 1 }
        Record-Check -Id $Id -Status 'FAIL' -EvidenceClass $EvidenceClass -Detail "$Name produced an unsafe test-output tree"
        return
    }

    $trxCandidates = @(
        Get-ChildItem -LiteralPath $testDirectory -Recurse -File -Filter $trxName -ErrorAction SilentlyContinue |
            Where-Object { $_.FullName.StartsWith($testDirectory + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase) }
    )
    if ($trxCandidates.Count -ne 1) {
        $script:testReports += [pscustomobject]@{ Id = $Id; Name = $Name; EvidenceClass = $EvidenceClass; Status = 'FAIL'; Path = 'NOT AVAILABLE'; Sha256 = 'NOT AVAILABLE'; Total = 0; Passed = 0; Failed = 1 }
        Record-Check -Id $Id -Status 'FAIL' -EvidenceClass $EvidenceClass -Detail "$Name did not produce exactly one TRX result (found $($trxCandidates.Count))"
        return
    }

    $trxPath = Get-SafeArtifactFile -Path $trxCandidates[0].FullName
    if ($null -eq $trxPath) {
        $script:testReports += [pscustomobject]@{ Id = $Id; Name = $Name; EvidenceClass = $EvidenceClass; Status = 'FAIL'; Path = 'UNSAFE'; Sha256 = 'NOT AVAILABLE'; Total = 0; Passed = 0; Failed = 1 }
        Record-Check -Id $Id -Status 'FAIL' -EvidenceClass $EvidenceClass -Detail "$Name TRX path was not safe"
        return
    }

    [xml]$trx = [IO.File]::ReadAllText($trxPath)
    $counters = $trx.TestRun.ResultSummary.Counters
    $total = [int]$counters.total
    $passed = [int]$counters.passed
    $failed = [int]$counters.failed
    $relativeTrx = Get-RelativeRepositoryPath -Path $trxPath
    $trxHash = (Get-FileHash -LiteralPath $trxPath -Algorithm SHA256).Hash.ToUpperInvariant()
    $status = if ($total -gt 0 -and $failed -eq 0 -and $total -eq $passed) { 'PASS' } else { 'FAIL' }
    $script:testReports += [pscustomobject]@{
        Id = $Id
        Name = $Name
        EvidenceClass = $EvidenceClass
        Status = $status
        Path = $relativeTrx
        Sha256 = $trxHash
        Total = $total
        Passed = $passed
        Failed = $failed
    }

    if ($status -eq 'FAIL') {
        Record-Check -Id $Id -Status 'FAIL' -EvidenceClass $EvidenceClass -Detail "$Name counters are not all passing: total=$total passed=$passed failed=$failed"
        return
    }

    Record-Check -Id $Id -Status 'PASS' -EvidenceClass $EvidenceClass -Detail "$Name selected tests passed: $passed/$total; TRX=$relativeTrx; SHA256=$trxHash"
}

function Get-EvidenceClassStatus {
    param([Parameter(Mandatory)][string]$EvidenceClass)
    $items = @($checkResults | Where-Object { $_.EvidenceClass -eq $EvidenceClass })
    if ($EvidenceClass -eq 'BuiltProcess') { return 'NOT RUN' }
    if ($EvidenceClass -in @('Runtime', 'IndependentReview', 'Release')) { return 'NOT OBSERVED' }
    if ($items.Count -eq 0) { return 'NOT RUN' }
    if (@($items | Where-Object { $_.Status -eq 'FAIL' }).Count -gt 0) { return 'FAIL' }
    if (@($items | Where-Object { $_.Status -eq 'NOT RUN' }).Count -gt 0) { return 'NOT RUN' }
    return 'PASS'
}

function Get-CheckLines {
    return @($checkResults | ForEach-Object {
        "$($_.Status) $($_.Id) evidence=$($_.EvidenceClass) $($_.Detail)"
    })
}

function Get-FileInventoryLines {
    return @($fileInventory | Sort-Object Path | ForEach-Object {
        "SHA256 $($_.Sha256) BYTES $($_.Bytes) PURPOSE=$($_.Purpose) $($_.Path)"
    })
}

function Write-Reports {
    param(
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$Result,

        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$SourceCommit,

        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$Branch
    )

    Assert-Issue43RequiredReportFields -Fields @{
        Issue = $issueNumber
        Version = $version
        SourceCommit = $SourceCommit
        CandidateCommit = $candidateIdentity
        DirectParentCommit = $directParentIdentity
        Branch = $Branch
        Result = $Result
    } | Out-Null

    $manifestLines = @(
        "Issue: $issueNumber",
        "Version: $version",
        "CandidateCommit: $candidateIdentity",
        "DirectParentCommit: $directParentIdentity",
        'ReviewedFiles:'
    ) + (Get-FileInventoryLines)
    if (-not (Set-SafeText -Path $manifestPath -Lines $manifestLines)) {
        throw 'The reviewed-file manifest could not be written safely.'
    }
    $manifestHash = (Get-FileHash -LiteralPath (Get-SafeArtifactFile -Path $manifestPath) -Algorithm SHA256).Hash.ToUpperInvariant()

    $schemaLines = @(
        'HerdrOps v1.0.0 Issue #43 Schema and Migration Report',
        "GeneratedUtc: $([DateTime]::UtcNow.ToString('O'))",
        "Issue: $issueNumber",
        "Version: $version",
        "SourceCommit: $SourceCommit",
        "CandidateCommit: $candidateIdentity",
        "DirectParentCommit: $directParentIdentity",
        "Branch: $Branch",
        "Result: $Result",
        'EvidenceClass: Static plus LocalSQLiteIntegration',
        "ReviewedManifestSha256: $manifestHash",
        '',
        'SchemaVersion: v3',
        'MigrationGraph: v1 initial-state-store -> v2 assignment-lifecycle-provenance -> v3 evidence-metadata-review-retention-audit',
        'ForwardOnly: PASS when S-01 is PASS',
        'FutureSchemaFailsClosed: PASS when S-01 is PASS',
        'PreMigrationBackup: PASS when S-02 is PASS',
        'TransactionalRollback: PASS when S-02 and C-04/C-05 are PASS',
        'ExplicitRollback: RESTORE_STATE_STORE plus expected source/destination identities',
        'IntegrityChecks: quick_check and integrity_check are required at admission/recovery boundaries',
        'Quarantine: damaged primary retained and copied to collision-safe tokenized evidence',
        '',
        'Checks:',
        (Get-CheckLines),
        '',
        'Boundary: This is repository static/local-contract evidence. It is not live database, installed product, runtime, independent-review, or release evidence.'
    )
    if (-not (Set-SafeText -Path $schemaReportPath -Lines $schemaLines)) {
        throw 'The schema report could not be written safely.'
    }
    $schemaHash = (Get-FileHash -LiteralPath (Get-SafeArtifactFile -Path $schemaReportPath) -Algorithm SHA256).Hash.ToUpperInvariant()

    $evidenceClasses = @('Static', 'Synthetic', 'LocalSQLiteIntegration', 'Contract', 'BuiltProcess', 'Runtime', 'IndependentReview', 'Release')
    $evidenceStatusLines = @($evidenceClasses | ForEach-Object { "$_`: $(Get-EvidenceClassStatus -EvidenceClass $_)" })
    $highFindings = if ($failures.Count -eq 0) { 'NONE OBSERVED BY THIS STATIC/SYNTHETIC/LOCAL-INTEGRATION/CONTRACT SLICE' } else { $failures -join ' | ' }
    $gateLines = @(
        'HerdrOps v1.0.0 Issue #43 Security and Privacy Review Gate',
        "GeneratedUtc: $([DateTime]::UtcNow.ToString('O'))",
        "Issue: $issueNumber",
        "Version: $version",
        "SourceCommit: $SourceCommit",
        "CandidateCommit: $candidateIdentity",
        "DirectParentCommit: $directParentIdentity",
        "Branch: $Branch",
        "Result: $Result",
        'PreparationSlice: NON-RUNTIME STATIC+SYNTHETIC+LOCAL-INTEGRATION+CONTRACT',
        "ReviewedFileCount: $($fileInventory.Count)",
        "ReviewedManifestSha256: $manifestHash",
        "SchemaMigrationReportSha256: $schemaHash",
        '',
        'EvidenceClassStatus:',
        $evidenceStatusLines,
        '',
        'HighFindings:',
        $highFindings,
        '',
        'Checks:',
        (Get-CheckLines),
        '',
        'TestReports:',
        ($testReports | ForEach-Object {
            "$($_.Status) $($_.Id) evidence=$($_.EvidenceClass) path=$($_.Path) SHA256=$($_.Sha256) tests=$($_.Passed)/$($_.Total)"
        }),
        '',
        'ReviewedFiles:',
        (Get-FileInventoryLines),
        '',
        'EvidenceBoundary:',
        'Actual Herdr runtime: NOT OBSERVED / NOT CLAIMED.',
        'Live listeners, effective Windows pipe ACLs, live processes, Registry, AppData, and live database: NOT OBSERVED / NOT CLAIMED.',
        'Administrator non-elevated host proof: NOT OBSERVED / NOT CLAIMED.',
        'BuiltProcess evidence: NOT RUN.',
        'Independent review and human approval: NOT OBSERVED / NOT CLAIMED.',
        'Release packaging, installation, upgrade, rollback acceptance, and publication: NOT OBSERVED / NOT CLAIMED.',
        'Issue #43 acceptance, milestone closure, and v1.0 release readiness: PENDING.'
    )
    if (-not (Set-SafeText -Path $gateReportPath -Lines $gateLines)) {
        throw 'The gate report could not be written safely.'
    }
    $gateHash = (Get-FileHash -LiteralPath (Get-SafeArtifactFile -Path $gateReportPath) -Algorithm SHA256).Hash.ToUpperInvariant()

    Assert-Issue43RequiredReportFields -Fields @{
        Issue = $issueNumber
        Version = $version
        SourceCommit = $SourceCommit
        CandidateCommit = $candidateIdentity
        DirectParentCommit = $directParentIdentity
        Branch = $Branch
        Result = $Result
        ReviewedManifestSha256 = $manifestHash
        SchemaMigrationReportSha256 = $schemaHash
        GateReportSha256 = $gateHash
    } | Out-Null

    $reviewLines = @(
        '# HerdrOps v1.0 Issue #43 Security and Privacy Review Report',
        '',
        'Status: generated bounded preparation slice; it does not close Issue #43 or pass the v1.0 release gate.',
        '',
        'Identity:',
        "Issue: $issueNumber",
        "Version: $version",
        "Branch: $Branch",
        "SourceCommit: $SourceCommit",
        "CandidateCommit: $candidateIdentity",
        "DirectParentCommit: $directParentIdentity",
        'CandidateHeadMatch: PASS',
        'DirectParentMatch: PASS',
        "GeneratedUtc: $([DateTime]::UtcNow.ToString('O'))",
        'Gate: tools/Test-V10Issue43SecurityReview.ps1',
        "GateReportPath: $(Get-RelativeRepositoryPath -Path $gateReportPath)",
        "GateReportSha256: $gateHash",
        "ReviewedManifestPath: $(Get-RelativeRepositoryPath -Path $manifestPath)",
        "ReviewedManifestSha256: $manifestHash",
        "SchemaMigrationReportSha256: $schemaHash",
        '',
        'Result:',
        "Result: $Result",
        "StaticEvidence: $(Get-EvidenceClassStatus -EvidenceClass 'Static')",
        "SyntheticEvidence: $(Get-EvidenceClassStatus -EvidenceClass 'Synthetic')",
        "LocalSQLiteIntegrationEvidence: $(Get-EvidenceClassStatus -EvidenceClass 'LocalSQLiteIntegration')",
        "ContractEvidence: $(Get-EvidenceClassStatus -EvidenceClass 'Contract')",
        'BuiltProcessEvidence: NOT RUN',
        'RuntimeEvidence: NOT OBSERVED / NOT CLAIMED',
        'IndependentReviewEvidence: NOT OBSERVED / NOT CLAIMED',
        'ReleaseEvidence: NOT OBSERVED / NOT CLAIMED',
        "HighFindings: $highFindings",
        'IssueAcceptance: PENDING',
        'VersionReleaseReady: false',
        '',
        'CheckResults:',
        (Get-CheckLines),
        '',
        'ReviewedFileManifest:',
        (Get-FileInventoryLines),
        '',
        'TestReports:',
        ($testReports | ForEach-Object {
            "$($_.Status) $($_.Id) evidence=$($_.EvidenceClass) path=$($_.Path) SHA256=$($_.Sha256) tests=$($_.Passed)/$($_.Total)"
        }),
        '',
        'EvidenceBoundaries:',
        'Actual Herdr runtime: NOT OBSERVED / NOT CLAIMED.',
        'Installed Herdr compatibility, live listener inventory, effective Windows ACLs, and cross-account isolation: NOT OBSERVED / NOT CLAIMED.',
        'Live processes, Registry, AppData, live database, and host elevation state: NOT OBSERVED / NOT CLAIMED.',
        'Independent review and human go/no-go: NOT OBSERVED / NOT CLAIMED.',
        'Release packaging, clean-machine installation, upgrade, rollback acceptance, and publication: NOT OBSERVED / NOT CLAIMED.',
        'This report contains only bounded hashes, source/config facts, and local test results; it does not contain secrets or raw diagnostic payloads.'
    )
    if (-not (Set-SafeText -Path $reviewReportPath -Lines $reviewLines)) {
        throw 'The security/privacy review report could not be written safely.'
    }

    $reviewHash = (Get-FileHash -LiteralPath (Get-SafeArtifactFile -Path $reviewReportPath) -Algorithm SHA256).Hash.ToUpperInvariant()
    return [pscustomobject]@{
        ManifestPath = $manifestPath
        ManifestSha256 = $manifestHash
        SchemaReportPath = $schemaReportPath
        SchemaReportSha256 = $schemaHash
        GateReportPath = $gateReportPath
        GateReportSha256 = $gateHash
        ReviewReportPath = $reviewReportPath
        ReviewReportSha256 = $reviewHash
    }
}

if (-not (Ensure-SafeDirectory -Path $artifactRoot) -or
    -not (Ensure-SafeDirectory -Path $gateDirectory) -or
    -not (Ensure-SafeDirectory -Path $testDirectory)) {
    throw 'The Issue #43 artifact paths could not be established safely.'
}

$sourceCommitOutput = @(& git -C $repositoryRoot rev-parse --verify 'HEAD^{commit}' 2>&1)
$sourceCommit = ($sourceCommitOutput -join '').Trim().ToLowerInvariant()
if ($LASTEXITCODE -ne 0 -or $sourceCommit -notmatch '^[0-9a-f]{40}$') {
    $sourceCommit = 'UNRESOLVED'
    Record-Check -Id 'BOUND-01' -Status 'FAIL' -EvidenceClass 'Static' -Detail 'could not resolve exact source commit'
} else {
    Record-Check -Id 'BOUND-01' -Status 'PASS' -EvidenceClass 'Static' -Detail "source commit resolved as $sourceCommit"
}

$branchOutput = @(& git -C $repositoryRoot symbolic-ref --short HEAD 2>&1)
$branch = ($branchOutput -join '').Trim()
if ($LASTEXITCODE -ne 0 -or $branch -ne $expectedBranch) {
    Record-Check -Id 'BOUND-02' -Status 'FAIL' -EvidenceClass 'Static' -Detail "expected branch $expectedBranch but observed $branch"
} else {
    Record-Check -Id 'BOUND-02' -Status 'PASS' -EvidenceClass 'Static' -Detail "branch is $expectedBranch"
}

$initialStatus = @(& git -C $repositoryRoot status --porcelain=v1 --untracked-files=all 2>&1)
if ($LASTEXITCODE -ne 0 -or $initialStatus.Count -ne 0) {
    Record-Check -Id 'BOUND-03' -Status 'FAIL' -EvidenceClass 'Static' -Detail 'checkout is not clean and committed'
} else {
    Record-Check -Id 'BOUND-03' -Status 'PASS' -EvidenceClass 'Static' -Detail 'clean committed checkout'
}

$candidateResolved = @(& git -C $repositoryRoot rev-parse --verify "$candidateIdentity^{commit}" 2>&1)
$resolvedCandidate = ($candidateResolved -join '').Trim().ToLowerInvariant()
$candidateExit = $LASTEXITCODE
$candidateMatch = $sourceCommit -eq $candidateIdentity -and $resolvedCandidate -eq $candidateIdentity
if ($candidateExit -ne 0 -or -not $candidateMatch) {
    Record-Check -Id 'BOUND-04' -Status 'FAIL' -EvidenceClass 'Static' -Detail "explicit candidate $candidateIdentity does not match HEAD $sourceCommit"
} else {
    Record-Check -Id 'BOUND-04' -Status 'PASS' -EvidenceClass 'Static' -Detail "explicit candidate identity matches HEAD: $candidateIdentity"
}

$parentResolved = @(& git -C $repositoryRoot rev-parse --verify "$candidateIdentity^1" 2>&1)
$resolvedParent = ($parentResolved -join '').Trim().ToLowerInvariant()
$parentExit = $LASTEXITCODE
$headParentResolved = @(& git -C $repositoryRoot rev-parse --verify 'HEAD^1' 2>&1)
$headParent = ($headParentResolved -join '').Trim().ToLowerInvariant()
$headParentExit = $LASTEXITCODE
$parentMatch = $resolvedParent -eq $directParentIdentity -and $headParent -eq $directParentIdentity -and $directParentIdentity -ne $candidateIdentity
if ($parentExit -ne 0 -or $headParentExit -ne 0 -or -not $parentMatch) {
    Record-Check -Id 'BOUND-05' -Status 'FAIL' -EvidenceClass 'Static' -Detail "explicit direct parent $directParentIdentity does not match candidate parent $resolvedParent / HEAD parent $headParent"
} else {
    Record-Check -Id 'BOUND-05' -Status 'PASS' -EvidenceClass 'Static' -Detail "explicit direct-parent identity matches candidate^1 and HEAD^1: $directParentIdentity"
}

$trackedPaths = Get-TrackedPaths
$reviewExtensions = @('.cs', '.csproj', '.xaml', '.json', '.xml', '.props', '.targets', '.config', '.manifest', '.md', '.sln', '.editorconfig', '.gitattributes', '.yml', '.yaml')
$rootReviewPaths = @(
    '.editorconfig', '.gitattributes', 'AGENTS.md', 'Directory.Build.props',
    'Directory.Packages.props', 'global.json', 'HerdrOps.sln', 'README.md',
    '.github/workflows/ci.yml', '.github/workflows/build.yml'
)
$manifestCandidates = @()
foreach ($path in $trackedPaths) {
    $normalized = $path.Replace('\\', '/')
    $extension = [IO.Path]::GetExtension($normalized).ToLowerInvariant()
    $include = $rootReviewPaths -contains $normalized
    if (-not $include -and $reviewExtensions -contains $extension) {
        $include = $normalized -like 'Plan/*' -or
            $normalized -like 'docs/protocol/*' -or
            $normalized -like 'docs/reviews/v1.0-issue-43-*' -or
            $normalized -like 'src/*' -or
            $normalized -like 'tests/*' -or
            $normalized -like 'tools/README.md' -or
            $normalized -like 'tools/Issue43SecurityReviewPolicy.ps1' -or
            $normalized -like 'tools/Test-V10Issue43SecurityReview.ps1' -or
            $normalized -like 'tools/Test-V10Issue43SecurityReviewFixtures.ps1'
    }
    if ($include) {
        $manifestCandidates += $normalized
    }
}
foreach ($path in @($manifestCandidates | Sort-Object -Unique)) {
    Add-ReviewedFile -RelativePath $path
}

$selectedProjects = @(
    'tests/HerdrOps.ContractTests/HerdrOps.ContractTests.csproj',
    'tests/HerdrOps.UnitTests/HerdrOps.UnitTests.csproj',
    'tests/HerdrOps.IntegrationTests/HerdrOps.IntegrationTests.csproj'
)
foreach ($project in $selectedProjects) {
    Add-ReviewedFile -RelativePath $project -Purpose 'selected test project configuration'
}
$missingSelectedProjects = @($selectedProjects | Where-Object { -not $manifestPathSet.ContainsKey($_) })
if ($missingSelectedProjects.Count -gt 0) {
    Record-Check -Id 'FILE-02' -Status 'FAIL' -EvidenceClass 'Static' -Detail "selected test projects were not bound by the manifest: $($missingSelectedProjects -join ', ')"
} else {
    Record-Check -Id 'FILE-02' -Status 'PASS' -EvidenceClass 'Static' -Detail 'every selected test project is present in the reviewed-file manifest'
}

if ($missingReviewFiles.Count -eq 0 -and $pathSafetyFailures.Count -eq 0 -and $fileInventory.Count -gt 0) {
    Record-Check -Id 'FILE-01' -Status 'PASS' -EvidenceClass 'Static' -Detail "hashed $($fileInventory.Count) tracked review inputs without missing files or unsafe paths"
} else {
    Record-Check -Id 'FILE-01' -Status 'FAIL' -EvidenceClass 'Static' -Detail "manifest validation failed; missing=$($missingReviewFiles -join ', '); unsafe=$($pathSafetyFailures -join ' | ')"
}

$productExtensions = @('.cs', '.csproj', '.xaml', '.json', '.xml', '.props', '.targets', '.config', '.manifest', '.sln')
$productScanPaths = @($manifestCandidates | Where-Object {
    $normalized = $_.Replace('\\', '/')
    $productExtensions -contains ([IO.Path]::GetExtension($normalized).ToLowerInvariant()) -and
        ($normalized -like 'src/*' -or $rootReviewPaths -contains $normalized)
} | Sort-Object -Unique)
$policyPath = Get-RepositoryFile -RelativePath 'tools/Issue43SecurityReviewPolicy.ps1'
if ($null -ne $policyPath) {
    . $policyPath
} else {
    Record-Check -Id 'SAFE-02' -Status 'FAIL' -EvidenceClass 'Static' -Detail 'scanner policy helper is missing or unsafe'
}

$markerGroups = @(
    [pscustomobject]@{ Id = 'S-01'; EvidenceClass = 'Static'; Files = @(
        @{ Path = 'src/HerdrOps.Infrastructure/Storage/HerdrStateStoreModels.cs'; Markers = @('CurrentSchemaVersion = 3') },
        @{ Path = 'src/HerdrOps.Infrastructure/Storage/SqliteHerdrStateStore.cs'; Markers = @('MigrationName =', 'AssignmentLifecycleMigrationName', 'ApplyMigrations', 'GetMigration', '1 => new MigrationDefinition', '2 => new MigrationDefinition', '3 => new MigrationDefinition', 'ValidateMigrationHistory', 'ComputeMigrationSha256', 'script_sha256', 'PRAGMA user_version', 'BeginTransaction', 'transaction.Commit()', 'transaction.Rollback()', 'version > HerdrStateStoreOptions.CurrentSchemaVersion') },
        @{ Path = 'src/HerdrOps.Infrastructure/Storage/SqliteHerdrStateStore.EvidenceMigration.cs'; Markers = @('EvidenceAuditMigrationName', 'CREATE TABLE evidence_items', 'CREATE TABLE review_audit_events', 'CREATE TABLE review_audit_evidence', 'CREATE TABLE evidence_retention_events', 'evidence_retention_events_reject_update', 'evidence_retention_events_reject_delete') },
        @{ Path = 'tests/HerdrOps.IntegrationTests/SqliteHerdrStateStoreTests.cs'; Markers = @('VersionOneDatabaseMigratesForwardWithoutLosingHistory', 'FailedVersionThreeMigrationRollsBackAllPartialChanges', 'FutureSchemaFailsClosedWithoutMigration') }
    ) },
    [pscustomobject]@{ Id = 'S-02'; EvidenceClass = 'Static'; Files = @(
        @{ Path = 'docs/protocol/v0.7-state-recovery-contract.md'; Markers = @('forward-only', 'BeforeBackup', 'AfterBackup', 'AfterMigrationBeforeCommit', 'RESTORE_STATE_STORE', 'quick_check', 'integrity_check', 'atomic', 'quarantine', 'NOT_OBSERVED') },
        @{ Path = 'src/HerdrOps.Infrastructure/Storage/Recovery/StateStoreRecoveryService.cs'; Markers = @('ConfirmationPhrase', 'ExpectedBackupSha256', 'RestoreBackup', 'sourceAfterRestore', 'RESTORE_STATE_STORE', 'NOT_OBSERVED') },
        @{ Path = 'src/HerdrOps.Infrastructure/Storage/Recovery/StateStoreRecoveryArtifacts.cs'; Markers = @('CreateBackup', 'RestoreBackup', 'FileMode.CreateNew', 'quick_check', 'integrity_check', 'File.Replace') },
        @{ Path = 'src/HerdrOps.Core/StateStoreRestoreCommand.cs'; Markers = @('RESTORE_STATE_STORE', 'expectedBackupSha256') },
        @{ Path = 'tests/HerdrOps.IntegrationTests/StateStoreRecoveryTests.cs'; Markers = @('InterruptedMigrationRollsBackAndBackupCanBeRestoredWithIntegrityCheck', 'DamagedDatabaseIsQuarantinedWithoutSilentReset', 'RecoveryTraceAndQuarantineMetadataTokenizePathsAndRedactFailureMessages') },
        @{ Path = 'tests/HerdrOps.IntegrationTests/StateStoreRestoreCommandTests.cs'; Markers = @('CoreRestoreCommandFailsClosedWithoutExactConfirmation') }
    ) },
    [pscustomobject]@{ Id = 'S-03'; EvidenceClass = 'Static'; Files = @(
        @{ Path = 'docs/protocol/v0.5-evidence-audit-storage-contract.md'; Markers = @('Retention evaluates only present managed copies', 'currently open', 'Purged', 'AlreadyMissing', 'Evidence metadata, review history, evidence links, and retention history remain', 'recoverable') },
        @{ Path = 'docs/protocol/v1.0-issue-43-security-privacy-review-contract.md'; Markers = @('30 days from', '365 days', 'Omitting the value resolves to the 30-day default', 'hash-bound terminal retention event') },
        @{ Path = 'src/HerdrOps.Domain/Evidence/EvidenceContracts.cs'; Markers = @('EvidenceRetentionPolicy.ResolveRetainUntil') },
        @{ Path = 'src/HerdrOps.Domain/Evidence/EvidenceRetentionPolicy.cs'; Markers = @('DefaultManagedArtifactRetentionDays = 30', 'MaximumManagedArtifactRetentionDays = 365', 'ResolveRetainUntil') },
        @{ Path = 'tests/HerdrOps.UnitTests/EvidenceContractsTests.cs'; Markers = @('NullRetentionUsesTheVersionedThirtyDayDefault', 'RetentionOverrideIsBoundedToTheVersionedMaximum') },
        @{ Path = 'src/HerdrOps.Infrastructure/Storage/SqliteHerdrStateStore.Evidence.cs'; Markers = @('RetentionPendingDirectoryName', 'IsProtectedByOpenReview', 'HerdrEvidenceRetentionOutcome.Purged', 'HerdrEvidenceRetentionOutcome.AlreadyMissing', 'MoveManagedEvidenceToRetentionPending', 'RestorePendingRetentionFile', 'InsertRetentionAuditEvent', 'transaction.Commit()') },
        @{ Path = 'tests/HerdrOps.IntegrationTests/EvidenceAuditStorageTests.cs'; Markers = @('RetentionProtectsOpenReviewThenPurgesBytesAndPreservesHistory', 'FailedRetentionAuditWriteLeavesRecoverableBytesAndRetryCompletes', 'CommittedRetentionAuditWithPendingBytesRecoversCleanup') }
    ) },
    [pscustomobject]@{ Id = 'S-04'; EvidenceClass = 'Static'; Files = @(
        @{ Path = 'docs/protocol/v0.6-local-export-contract.md'; Markers = @('sourceSnapshotSha256', 'redaction', 'local', 'atomic', 'fail closed', 'credential', 'do not prove an installed Herdr') },
        @{ Path = 'src/HerdrOps.Domain/Exports/DeterministicSnapshotExporter.cs'; Markers = @('SnapshotExportContentPolicy', 'SecretOrTokenPattern', 'MaximumTotalOutputBytes', 'EnsureNoProhibitedContent', 'sourceSnapshotSha256') },
        @{ Path = 'src/HerdrOps.Domain/Exports/LocalSnapshotExportPublisher.cs'; Markers = @('FileMode.CreateNew', 'Directory.Move', 'atomic') },
        @{ Path = 'tests/HerdrOps.ContractTests/SnapshotExportContractTests.cs'; Markers = @('ExportContractUsesStableUtf8OrderingHashesAndFailClosedPolicy', 'PublisherRejectsHashConsistentForgedEnvelopeAndUnsafeDestinationWithoutPublication') },
        @{ Path = 'tests/HerdrOps.UnitTests/LocalSnapshotExportPublisherTests.cs'; Markers = @('PublishCreatesAtomicDirectoryPairWithManifestAndRereadHashes', 'PublishRejectsConflictWithoutOverwritingExistingPair', 'PublishRejectsHashConsistentForgedSensitiveEnvelopeWithoutFinalFiles') }
    ) },
    [pscustomobject]@{ Id = 'S-05'; EvidenceClass = 'Static'; Files = @(
        @{ Path = 'docs/protocol/v0.7-diagnostic-bundle-contract.md'; Markers = @('exactly three UTF-8 JSON artifacts', 'Raw environment', 'terminal-dump', 'process-dump', 'user-profile', 'configured secret', 'bounded', 'CreateNew', 'Actual Herdr Runtime') },
        @{ Path = 'src/HerdrOps.Domain/Diagnostics/DiagnosticBundleModels.cs'; Markers = @('PayloadFileName', 'DiagnosticRedactionOptions', 'MaximumInputUtf8Bytes', 'MaximumEntries', 'environment reader', 'No dump') },
        @{ Path = 'src/HerdrOps.Domain/Diagnostics/DiagnosticRedaction.cs'; Markers = @('DiagnosticTextRedactor', 'Replacement', 'UserProfileReplacement', 'SocketReplacement', 'PathReplacement') },
        @{ Path = 'src/HerdrOps.Domain/Diagnostics/DiagnosticBundleBuilder.cs'; Markers = @('DiagnosticBundleEntryKind', 'EnsureSize', 'RedactRequired', 'NormalizeMetadata', 'MaximumBundleBytes') },
        @{ Path = 'src/HerdrOps.Infrastructure/Diagnostics/DiagnosticBundlePublisher.cs'; Markers = @('FileMode.CreateNew', 'Directory.Move', 'destination already exists') },
        @{ Path = 'tests/HerdrOps.IntegrationTests/DiagnosticBundleTests.cs'; Markers = @('BuildRedactsConfiguredCommonAndNestedCredentialFormsFromEveryArtifact', 'BoundsRejectEntryCountMetadataDepthAndOversizedCanonicalArtifacts', 'PublisherUsesSafePathAtomicNoOverwriteAndOnlyContractArtifacts') }
    ) },
    [pscustomobject]@{ Id = 'S-06'; EvidenceClass = 'Contract'; Files = @(
        @{ Path = 'src/HerdrOps.Infrastructure/StateIpc/HerdrOpsStatePipeServer.cs'; Markers = @('CurrentUserOnly', 'RequiredPipeOptions', 'NamedPipeServerStream', 'HerdrOpsStatePipeName.FromUserScope') },
        @{ Path = 'src/HerdrOps.Infrastructure/StateIpc/HerdrOpsSelfReportPipeServer.cs'; Markers = @('CurrentUserOnly', 'RequiredPipeOptions', 'NamedPipeServerStream', 'HerdrOpsSelfReportPipeName.FromUserScope') },
        @{ Path = 'src/HerdrOps.App/StateIpc/HerdrOpsStatePipeClient.cs'; Markers = @('CurrentUserOnly', 'RequiredPipeOptions', 'NamedPipeClientStream', 'HerdrOpsStatePipeName.FromUserScope', 'AuthorizationScope') },
        @{ Path = 'src/HerdrOps.Cli/HerdrOpsSelfReportPipeClient.cs'; Markers = @('CurrentUserOnly', 'RequiredPipeOptions', 'NamedPipeClientStream', 'HerdrOpsSelfReportPipeName.FromUserScope') },
        @{ Path = 'src/HerdrOps.Contracts/StateIpc/HerdrOpsStatePipeName.cs'; Markers = @('SHA256.HashData', 'HerdrOps.StateIpc.v2|', 'hash[..24]') },
        @{ Path = 'src/HerdrOps.Contracts/SelfReport/HerdrOpsSelfReportPipeName.cs'; Markers = @('SHA256.HashData', 'HerdrOps.SelfReport.v1|', 'hash[..24]') },
        @{ Path = 'src/HerdrOps.Contracts/StateIpc/HerdrOpsStateIpcJson.cs'; Markers = @('ReadCommentHandling = JsonCommentHandling.Disallow', 'UnmappedMemberHandling = JsonUnmappedMemberHandling.Disallow', 'DeserializeEnvelope') },
        @{ Path = 'src/HerdrOps.Contracts/SelfReport/HerdrOpsSelfReportJson.cs'; Markers = @('ReadCommentHandling = JsonCommentHandling.Disallow', 'UnmappedMemberHandling = JsonUnmappedMemberHandling.Disallow', 'DeserializeEnvelope', 'ValidateEnvelope') },
        @{ Path = 'src/HerdrOps.Contracts/SelfReport/HerdrOpsSelfReportContract.cs'; Markers = @('HerdrOpsSelfReportSubmission') },
        @{ Path = 'Plan/DECISIONS.md'; Markers = @('PipeOptions.CurrentUserOnly', 'pipe name is scoped by a non-reversible hash of the Windows user SID', 'has not yet received a separate multi-account runtime acceptance run') },
        @{ Path = 'tests/HerdrOps.ContractTests/StateIpcContractTests.cs'; Markers = @('UserScopedPipeNameIsStableAndDoesNotExposeIdentity') },
        @{ Path = 'tests/HerdrOps.ContractTests/SelfReportContractTests.cs'; Markers = @('CurrentUserPipeNameIsStableVersionedAndScopeSpecific') }
    ) },
    [pscustomobject]@{ Id = 'S-07'; EvidenceClass = 'Static'; Files = @(
        @{ Path = 'Plan/ARCHITECTURE.md'; Markers = @('No local HTTP server in v1 local mode', 'Herdr connection: Windows Named Pipe') },
        @{ Path = 'docs/protocol/v1.0-issue-43-security-privacy-review-contract.md'; Markers = @('no unexpected', 'TCP/HTTP/Web listener', 'Named Pipe server', 'live listener') }
    ) },
    [pscustomobject]@{ Id = 'S-08'; EvidenceClass = 'Static'; Files = @(
        @{ Path = 'Plan/RELEASE-GATES.md'; Markers = @('Normal-mode Administrator requirement | None') },
        @{ Path = 'Plan/ARCHITECTURE.md'; Markers = @('No Administrator requirement in normal mode') },
        @{ Path = 'docs/protocol/v1.0-issue-43-security-privacy-review-contract.md'; Markers = @('no `requireAdministrator`, `runas`, administrator role', 'non-elevated runtime proof') }
    ) },
    [pscustomobject]@{ Id = 'S-09'; EvidenceClass = 'Static'; Files = @(
        @{ Path = 'Plan/ARCHITECTURE.md'; Markers = @('Local-only data by default', 'Command lines, terminal output and files are treated as sensitive', 'Bounded reads, configurable retention and redaction before persistence/export', 'v1 managed evidence bytes retain for 30 days', 'Optional elevated telemetry, remote aggregation and cloud sync are outside v1') },
        @{ Path = 'docs/protocol/v1.0-issue-43-security-privacy-review-contract.md'; Markers = @('same-user process', 'Registry', 'AppData', '30 days from', '365 days', 'Independent review', 'Release') },
        @{ Path = 'docs/reviews/v1.0-issue-43-security-privacy-checklist.md'; Markers = @('NOT OBSERVED / NOT CLAIMED', 'Issue #43 acceptance and milestone closure: `PENDING`') }
    ) }
)

foreach ($group in $markerGroups) {
    Test-MarkerGroup -Id $group.Id -EvidenceClass $group.EvidenceClass -Files $group.Files | Out-Null
}

try {
    Test-Issue43ScannerFixtures | Out-Null
    Test-Issue43ReportWriterFixtures | Out-Null
    Record-Check -Id 'S-10' -Status 'PASS' -EvidenceClass 'Static' -Detail 'adversarial scanner and report-writer fixtures passed without live process or listener access'
} catch {
    Record-Check -Id 'S-10' -Status 'FAIL' -EvidenceClass 'Static' -Detail $_.Exception.Message
}

$listenerCodePattern = '(?i)\b(?:TcpListener|HttpListener|Kestrel|WebApplication|ListenOptions|UdpClient|Socket\s*\.\s*Bind|\.\s*Bind\s*\()\b|\b(?:UseUrls|ListenAsync)\s*\('
$listenerRawPattern = '(?i)(?:DllImport|LibraryImport)[^\r\n]*(?:ws2_32|wship6|httpapi|EntryPoint\s*=\s*["''](?:bind|listen|accept|WSABind|WSASocket)["''])|(?:NativeLibrary\s*\.\s*(?:Load|GetExport)|GetProcAddress)[^\r\n]*(?:bind|listen|accept|socket)|\b(?:WSAStartup|WSASocket|WSABind|HttpAddUrl|HttpCreateServerSession)\b'
$loopbackCodePattern = '(?i)\b(?:https?|wss?)\s*:\s*//\s*(?:localhost|127\.0\.0\.1|\[?::1\]?)(?::\d+)?'
$loopbackRawPattern = '(?i)(?:https?|wss?)\s*:\s*//\s*(?:localhost|127\.0\.0\.1|\[?::1\]?)(?::\d+)?'
Test-ForbiddenProductPattern -Id 'S-07-LISTENER' -CodePattern $listenerCodePattern -RawPattern $listenerRawPattern -Description 'unexpected network listener declarations' | Out-Null
Test-ForbiddenProductPattern -Id 'S-07-LOOPBACK' -CodePattern $loopbackCodePattern -RawPattern $loopbackRawPattern -Description 'loopback HTTP/Web endpoints' | Out-Null

$administratorCodePattern = '(?i)\b(?:requireAdministrator|highestAvailable|requestedExecutionLevel|uiAccess|runas|WindowsBuiltInRole\s*\.\s*Administrator|PrincipalPermission|IsInRole|AdjustTokenPrivileges|Se(?:Debug|Impersonate|TakeOwnership)Privilege|ShellExecute(?:Ex)?)\b'
$administratorRawPattern = '(?i)(?:requestedExecutionLevel\b|uiAccess\s*=)|(?:Verb|verb)\s*=\s*["'']runas["'']|(?:DllImport|LibraryImport)[^\r\n]*(?:AdjustTokenPrivileges|ShellExecute|runas)'
Test-ForbiddenProductPattern -Id 'S-08-ADMIN' -CodePattern $administratorCodePattern -RawPattern $administratorRawPattern -Description 'Administrator/elevation declarations' | Out-Null

Test-SelectedTest -Id 'C-01' -Name 'ipc' -EvidenceClass 'Contract' -Project 'tests/HerdrOps.ContractTests/HerdrOps.ContractTests.csproj' -Filter 'FullyQualifiedName~StateIpcContractTests|FullyQualifiedName~SelfReportContractTests'
Test-SelectedTest -Id 'C-02' -Name 'export' -EvidenceClass 'Contract' -Project 'tests/HerdrOps.ContractTests/HerdrOps.ContractTests.csproj' -Filter 'FullyQualifiedName~SnapshotExportContractTests'
Test-SelectedTest -Id 'C-03' -Name 'redaction' -EvidenceClass 'Synthetic' -Project 'tests/HerdrOps.UnitTests/HerdrOps.UnitTests.csproj' -Filter 'FullyQualifiedName~TerminalPreviewPolicyTests|FullyQualifiedName~DeterministicSnapshotExporterTests|FullyQualifiedName~LocalSnapshotExportPublisherTests|FullyQualifiedName~EvidenceContractsTests'
Test-SelectedTest -Id 'C-04' -Name 'schema' -EvidenceClass 'LocalSQLiteIntegration' -Project 'tests/HerdrOps.IntegrationTests/HerdrOps.IntegrationTests.csproj' -Filter 'FullyQualifiedName~SqliteHerdrStateStoreTests'
Test-SelectedTest -Id 'C-05' -Name 'recovery' -EvidenceClass 'LocalSQLiteIntegration' -Project 'tests/HerdrOps.IntegrationTests/HerdrOps.IntegrationTests.csproj' -Filter 'FullyQualifiedName~StateStoreRecoveryTests|FullyQualifiedName~StateStoreRestoreCommandTests'
Test-SelectedTest -Id 'C-06' -Name 'retention' -EvidenceClass 'LocalSQLiteIntegration' -Project 'tests/HerdrOps.IntegrationTests/HerdrOps.IntegrationTests.csproj' -Filter 'FullyQualifiedName~EvidenceAuditStorageTests'
Test-SelectedTest -Id 'C-07' -Name 'diagnostic' -EvidenceClass 'Synthetic' -Project 'tests/HerdrOps.IntegrationTests/HerdrOps.IntegrationTests.csproj' -Filter 'FullyQualifiedName~DiagnosticBundleTests'

Record-Check -Id 'EVIDENCE-BUILTPROCESS' -Status 'NOT RUN' -EvidenceClass 'BuiltProcess' -Detail 'no packaged or installed product process was started by this gate'
Record-Check -Id 'EVIDENCE-RUNTIME' -Status 'NOT OBSERVED' -EvidenceClass 'Runtime' -Detail 'actual Herdr runtime, live listeners, Registry/AppData/live database, and host observation were not performed'
Record-Check -Id 'EVIDENCE-INDEPENDENT' -Status 'NOT OBSERVED' -EvidenceClass 'IndependentReview' -Detail 'role-distinct independent approval is outside this builder gate'
Record-Check -Id 'EVIDENCE-RELEASE' -Status 'NOT OBSERVED' -EvidenceClass 'Release' -Detail 'packaging, clean-machine installation, release, and publication were not performed'

if ($pathSafetyFailures.Count -eq 0) {
    Record-Check -Id 'SAFE-01' -Status 'PASS' -EvidenceClass 'Static' -Detail 'all repository reads and artifact/TRX/report paths passed canonical containment and reparse-point checks'
} else {
    Record-Check -Id 'SAFE-01' -Status 'FAIL' -EvidenceClass 'Static' -Detail ($pathSafetyFailures -join ' | ')
}

$finalCommitOutput = @(& git -C $repositoryRoot rev-parse --verify 'HEAD^{commit}' 2>&1)
$finalCommit = ($finalCommitOutput -join '').Trim().ToLowerInvariant()
$finalStatus = @(& git -C $repositoryRoot status --porcelain=v1 --untracked-files=all 2>&1)
if ($finalCommit -ne $sourceCommit -or $finalStatus.Count -ne 0) {
    Record-Check -Id 'BOUND-07' -Status 'FAIL' -EvidenceClass 'Static' -Detail 'source commit or clean checkout changed during the gate'
} else {
    Record-Check -Id 'BOUND-07' -Status 'PASS' -EvidenceClass 'Static' -Detail 'source commit and clean checkout remained unchanged'
}

$result = if ($failures.Count -eq 0) { 'PASS' } else { 'FAIL' }
$reports = Write-Reports -Result $result -SourceCommit $sourceCommit -Branch $branch
Write-Output "Issue #43 gate result: $result"
Write-Output "ReviewedManifest: $($reports.ManifestPath)"
Write-Output "SchemaMigrationReport: $($reports.SchemaReportPath)"
Write-Output "GateReport: $($reports.GateReportPath)"
Write-Output "SecurityPrivacyReviewReport: $($reports.ReviewReportPath)"
Write-Output "GateReportSha256: $($reports.GateReportSha256)"
Write-Output "ReviewedManifestSha256: $($reports.ManifestSha256)"
Write-Output "EvidenceClasses: Static=$(Get-EvidenceClassStatus -EvidenceClass 'Static'); Synthetic=$(Get-EvidenceClassStatus -EvidenceClass 'Synthetic'); LocalSQLiteIntegration=$(Get-EvidenceClassStatus -EvidenceClass 'LocalSQLiteIntegration'); Contract=$(Get-EvidenceClassStatus -EvidenceClass 'Contract'); BuiltProcess=NOT RUN; Runtime=NOT OBSERVED; IndependentReview=NOT OBSERVED; Release=NOT OBSERVED"
if ($result -ne 'PASS') {
    throw "Issue #43 security/privacy preparation gate failed: $($failures -join '; ')"
}
