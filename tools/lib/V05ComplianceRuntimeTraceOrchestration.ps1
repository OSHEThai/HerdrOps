# Shared fail-closed producer orchestration for the v0.5 Issue #28 runtime harness.
# Compatible with PowerShell 7 and Windows PowerShell 5.1.

if ($null -eq ('HerdrOps.Tools.V05BoundedProcessRunner' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Diagnostics;
using System.IO;
using System.Reflection;
using System.Threading;
using System.Threading.Tasks;

namespace HerdrOps.Tools
{
    public sealed class V05BoundedStreamResult
    {
        public long ByteCount { get; set; }
        public bool Exceeded { get; set; }
    }

    public sealed class V05BoundedProcessResult
    {
        public int ExitCode { get; set; }
        public bool TimedOut { get; set; }
        public long StdoutByteCount { get; set; }
        public long StderrByteCount { get; set; }
        public bool StdoutExceeded { get; set; }
        public bool StderrExceeded { get; set; }
    }

    public static class V05BoundedProcessRunner
    {
        private const int OuterDrainTimeoutMilliseconds = 3000;

        private static V05BoundedStreamResult Drain(Stream stream, long maximumBytes)
        {
            byte[] buffer = new byte[4096];
            long byteCount = 0;
            bool exceeded = false;
            int read;
            while ((read = stream.Read(buffer, 0, buffer.Length)) > 0)
            {
                if (byteCount > long.MaxValue - read)
                {
                    byteCount = long.MaxValue;
                }
                else
                {
                    byteCount += read;
                }
                if (byteCount > maximumBytes)
                {
                    exceeded = true;
                }
            }
            return new V05BoundedStreamResult { ByteCount = byteCount, Exceeded = exceeded };
        }

        public static V05BoundedProcessResult Run(
            string filePath,
            string arguments,
            long maximumBytesPerStream,
            int timeoutMilliseconds)
        {
            ProcessStartInfo startInfo = new ProcessStartInfo();
            startInfo.FileName = filePath;
            startInfo.Arguments = arguments;
            startInfo.UseShellExecute = false;
            startInfo.CreateNoWindow = true;
            startInfo.RedirectStandardOutput = true;
            startInfo.RedirectStandardError = true;

            using (Process process = new Process())
            {
                process.StartInfo = startInfo;
                if (!process.Start())
                {
                    throw new InvalidOperationException("The bounded child process could not be started.");
                }

                Task<V05BoundedStreamResult> stdoutTask = Task.Factory.StartNew(
                    () => Drain(process.StandardOutput.BaseStream, maximumBytesPerStream),
                    CancellationToken.None,
                    TaskCreationOptions.LongRunning,
                    TaskScheduler.Default);
                Task<V05BoundedStreamResult> stderrTask = Task.Factory.StartNew(
                    () => Drain(process.StandardError.BaseStream, maximumBytesPerStream),
                    CancellationToken.None,
                    TaskCreationOptions.LongRunning,
                    TaskScheduler.Default);

                bool timedOut = !process.WaitForExit(timeoutMilliseconds);
                if (timedOut)
                {
                    KillProcessTree(process);
                }

                if (!process.WaitForExit(OuterDrainTimeoutMilliseconds))
                {
                    KillProcessTree(process);
                    process.WaitForExit();
                }

                V05BoundedStreamResult stdout = stdoutTask.GetAwaiter().GetResult();
                V05BoundedStreamResult stderr = stderrTask.GetAwaiter().GetResult();
                return new V05BoundedProcessResult
                {
                    ExitCode = process.ExitCode,
                    TimedOut = timedOut,
                    StdoutByteCount = stdout.ByteCount,
                    StderrByteCount = stderr.ByteCount,
                    StdoutExceeded = stdout.Exceeded,
                    StderrExceeded = stderr.Exceeded
                };
            }
        }

        private static void KillProcessTree(Process process)
        {
            MethodInfo killTree = typeof(Process).GetMethod(
                "Kill",
                new Type[] { typeof(bool) });
            if (killTree != null)
            {
                try
                {
                    killTree.Invoke(process, new object[] { true });
                    return;
                }
                catch (Exception)
                {
                    // Fall through to the tree-kill fallback below.
                }
            }

            try
            {
                ProcessStartInfo startInfo = new ProcessStartInfo();
                startInfo.FileName = "taskkill";
                startInfo.Arguments = "/PID " + process.Id.ToString(System.Globalization.CultureInfo.InvariantCulture) + " /T /F";
                startInfo.UseShellExecute = false;
                startInfo.CreateNoWindow = true;
                using (Process killer = Process.Start(startInfo))
                {
                    if (killer != null)
                    {
                        killer.WaitForExit(OuterDrainTimeoutMilliseconds);
                    }
                }
            }
            catch (Exception)
            {
                // The child is already dead, or a best-effort tree kill was refused.
            }
        }
    }
}
'@
}

function ConvertTo-V05NativeArgument {
    param(
        [AllowEmptyString()]
        [string]$Argument
    )

    if ($null -eq $Argument) {
        $Argument = ''
    }

    $builder = New-Object System.Text.StringBuilder
    $null = $builder.Append('"')
    $backslashCount = 0
    foreach ($character in $Argument.ToCharArray()) {
        if ($character -eq [char]92) {
            $backslashCount++
            continue
        }
        if ($character -eq [char]34) {
            $null = $builder.Append(('\' * (($backslashCount * 2) + 1)))
            $null = $builder.Append('"')
            $backslashCount = 0
            continue
        }
        if ($backslashCount -gt 0) {
            $null = $builder.Append(('\' * $backslashCount))
            $backslashCount = 0
        }
        $null = $builder.Append([string]$character)
    }
    if ($backslashCount -gt 0) {
        $null = $builder.Append(('\' * ($backslashCount * 2)))
    }
    $null = $builder.Append('"')
    return $builder.ToString()
}

function Invoke-V05BoundedProcess {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$FilePath,

        [Parameter(Mandatory)]
        [string[]]$ArgumentList,

        [ValidateRange(1, 1048576)]
        [int]$MaximumBytesPerStream = 65536,

        [ValidateRange(1000, 300000)]
        [int]$TimeoutMilliseconds = 120000
    )

    $quotedArguments = @($ArgumentList | ForEach-Object {
            ConvertTo-V05NativeArgument -Argument ([string]$_)
        })
    $argumentString = [string]::Join(' ', [string[]]$quotedArguments)
    return [HerdrOps.Tools.V05BoundedProcessRunner]::Run(
        $FilePath,
        $argumentString,
        $MaximumBytesPerStream,
        $TimeoutMilliseconds)
}

function Invoke-V05ComplianceReviewTraceProducer {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$CoreExecutable,

        [Parameter(Mandatory)]
        [string]$StateDatabasePath,

        [Parameter(Mandatory)]
        [string]$ReviewTracePath,

        [Parameter(Mandatory)]
        [string]$IncidentId,

        [ValidateRange(1, 1048576)]
        [int]$MaximumBytesPerStream = 65536,

        [ValidateRange(1000, 300000)]
        [int]$TimeoutMilliseconds = 120000,

        [scriptblock]$CommandRunner
    )

    $producerArguments = @(
        'trace-compliance-review',
        '--database', $StateDatabasePath,
        '--report', $ReviewTracePath,
        '--incident', $IncidentId)

    if ($null -eq $CommandRunner) {
        $runnerResult = Invoke-V05BoundedProcess `
            -FilePath $CoreExecutable `
            -ArgumentList $producerArguments `
            -MaximumBytesPerStream $MaximumBytesPerStream `
            -TimeoutMilliseconds $TimeoutMilliseconds
    }
    else {
        $runnerResult = & $CommandRunner $CoreExecutable $producerArguments $MaximumBytesPerStream $TimeoutMilliseconds
    }

    $requiredProperties = @(
        'ExitCode',
        'TimedOut',
        'StdoutByteCount',
        'StderrByteCount',
        'StdoutExceeded',
        'StderrExceeded')
    foreach ($propertyName in $requiredProperties) {
        if ($null -eq $runnerResult -or
            $runnerResult.PSObject.Properties.Name -notcontains $propertyName) {
            throw "Compliance review trace command runner did not return $propertyName."
        }
    }

    $diagnostic = "stdoutBytes=$([long]$runnerResult.StdoutByteCount) stderrBytes=$([long]$runnerResult.StderrByteCount) stdoutExceeded=$([bool]$runnerResult.StdoutExceeded) stderrExceeded=$([bool]$runnerResult.StderrExceeded)"
    if ([bool]$runnerResult.TimedOut) {
        throw "Compliance review trace timed out after $TimeoutMilliseconds milliseconds; $diagnostic. No process output was retained."
    }
    if ([bool]$runnerResult.StdoutExceeded -or [bool]$runnerResult.StderrExceeded) {
        throw "Compliance review trace output exceeded the $MaximumBytesPerStream-byte per-stream limit; $diagnostic. No process output was retained."
    }
    if ([int]$runnerResult.ExitCode -ne 0) {
        throw "Compliance review trace failed with exit $([int]$runnerResult.ExitCode); $diagnostic. No process output was retained."
    }
    if (-not (Test-Path -LiteralPath $ReviewTracePath -PathType Leaf)) {
        throw "Compliance review trace is missing: $ReviewTracePath"
    }

    [pscustomobject]@{
        ExitCode = [int]$runnerResult.ExitCode
        TimedOut = [bool]$runnerResult.TimedOut
        StdoutByteCount = [long]$runnerResult.StdoutByteCount
        StderrByteCount = [long]$runnerResult.StderrByteCount
        TracePath = $ReviewTracePath
    }
}

function Get-CleanSourceIdentity {
    param([Parameter(Mandatory)][string]$Root)

    $previousPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        $commitOutput = @(& git -C $Root rev-parse --verify 'HEAD^{commit}' 2>&1 | ForEach-Object { [string]$_ })
        $commitExit = $LASTEXITCODE

        $treeOutput = @(& git -C $Root rev-parse --verify 'HEAD^{tree}' 2>&1 | ForEach-Object { [string]$_ })
        $treeExit = $LASTEXITCODE

        $statusOutput = @(& git -C $Root status --porcelain=v1 --untracked-files=all 2>&1 | ForEach-Object { [string]$_ })
        $statusExit = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $previousPreference
    }

    $commit = ($commitOutput -join '').Trim()
    if ($commitExit -ne 0 -or $commit -notmatch '^[0-9a-fA-F]{40}$') {
        throw "SourceCommitResolutionFailed: could not resolve source commit in '$Root'."
    }

    $tree = ($treeOutput -join '').Trim()
    if ($treeExit -ne 0 -or $tree -notmatch '^[0-9a-fA-F]{40}$') {
        throw "SourceTreeResolutionFailed: could not resolve source tree in '$Root'."
    }

    if ($statusExit -ne 0) {
        throw "WorkingTreeInspectionFailed: could not inspect source working tree in '$Root'."
    }
    if ($statusOutput.Count -ne 0) {
        throw "WorkingTreeDirty: runtime evidence requires a clean committed checkout. Changes: $($statusOutput -join '; ')"
    }

    return [pscustomobject]@{
        Commit = $commit.ToLowerInvariant()
        Tree   = $tree.ToLowerInvariant()
        Clean  = $true
    }
}

function Assert-CleanSourceIdentity {
    param(
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][string]$ExpectedCommit,
        [Parameter(Mandatory)][string]$ExpectedTree,
        [Parameter(Mandatory)][string]$Phase
    )

    $current = Get-CleanSourceIdentity -Root $Root
    if ($current.Commit -ne $ExpectedCommit.ToLowerInvariant()) {
        throw "SourceCommitMismatch: $Phase source commit mismatch (expected=$($ExpectedCommit.ToLowerInvariant()), actual=$($current.Commit))."
    }
    if ($current.Tree -ne $ExpectedTree.ToLowerInvariant()) {
        throw "SourceTreeMismatch: $Phase source tree mismatch (expected=$($ExpectedTree.ToLowerInvariant()), actual=$($current.Tree))."
    }
    if (-not $current.Clean) {
        throw "WorkingTreeDirty: $Phase source working tree is dirty."
    }

    return $current
}

function Assert-V05JsonBooleanProperty {
    param(
        [Parameter(Mandatory)]
        $TargetObject,

        [Parameter(Mandatory)]
        [string]$PropertyName,

        [Parameter(Mandatory)]
        [bool]$ExpectedValue,

        [Parameter(Mandatory)]
        [string]$ContextPath
    )

    if ($null -eq $TargetObject) {
        throw "Target JSON object is null: $ContextPath"
    }

    $property = $TargetObject.PSObject.Properties[$PropertyName]
    if ($null -eq $property) {
        throw "JSON object is missing required boolean property '$PropertyName': $ContextPath"
    }

    $val = $property.Value
    if ($null -eq $val) {
        throw "JSON property '$PropertyName' value is null (expected boolean $ExpectedValue): $ContextPath"
    }

    if ($val.GetType() -ne [bool]) {
        $typeName = $val.GetType().FullName
        throw "JSON property '$PropertyName' must be a CLR Boolean, but found '$typeName' with value '$val': $ContextPath"
    }

    if ([bool]$val -ne $ExpectedValue) {
        throw "JSON property '$PropertyName' is $([bool]$val) (expected $ExpectedValue): $ContextPath"
    }
}

function Assert-V05CompositeRuntimeReport {
    param(
        [Parameter(Mandatory)][string]$ReportPath
    )

    if (-not (Test-Path -LiteralPath $ReportPath -PathType Leaf)) {
        throw "Composite compliance report is missing: $ReportPath"
    }

    $compositeText = Get-Content -LiteralPath $ReportPath -Raw
    $composite = $null
    try {
        $composite = $compositeText | ConvertFrom-Json
    }
    catch {
        throw "Failed to parse composite compliance report JSON ($ReportPath): $($_.Exception.Message)"
    }
    if ($null -eq $composite) {
        throw "Composite compliance report JSON payload is empty: $ReportPath"
    }

    $compClassificationProp = $composite.PSObject.Properties['EvidenceClassification']
    if ($null -eq $compClassificationProp -or
        $null -eq $compClassificationProp.Value -or
        $compClassificationProp.Value.GetType() -ne [string] -or
        $compClassificationProp.Value -ne 'Runtime') {
        throw "Composite compliance report EvidenceClassification must be string 'Runtime': $ReportPath"
    }

    Assert-V05JsonBooleanProperty -TargetObject $composite -PropertyName 'RuntimeAccepted' -ExpectedValue $true -ContextPath $ReportPath
    Assert-V05JsonBooleanProperty -TargetObject $composite -PropertyName 'SessionControlInvoked' -ExpectedValue $false -ContextPath $ReportPath

    $acceptanceProp = $composite.PSObject.Properties['Acceptance']
    if ($null -eq $acceptanceProp -or $null -eq $acceptanceProp.Value) {
        throw "Composite compliance report is missing Acceptance object: $ReportPath"
    }
    Assert-V05JsonBooleanProperty -TargetObject $acceptanceProp.Value -PropertyName 'Passed' -ExpectedValue $true -ContextPath $ReportPath

    return $composite
}

function Assert-V05HerdrRuntimeReport {
    param(
        [Parameter(Mandatory)][string]$ReportPath
    )

    if (-not (Test-Path -LiteralPath $ReportPath -PathType Leaf)) {
        throw "Herdr runtime report is missing: $ReportPath"
    }

    $herdrJsonText = Get-Content -LiteralPath $ReportPath -Raw
    $herdrJson = $null
    try {
        $herdrJson = $herdrJsonText | ConvertFrom-Json
    }
    catch {
        throw "Failed to parse Herdr runtime report JSON ($ReportPath): $($_.Exception.Message)"
    }
    if ($null -eq $herdrJson) {
        throw "Herdr runtime report JSON payload is empty: $ReportPath"
    }

    $herdrClassificationProp = $herdrJson.PSObject.Properties['EvidenceClassification']
    if ($null -eq $herdrClassificationProp -or
        $null -eq $herdrClassificationProp.Value -or
        $herdrClassificationProp.Value.GetType() -ne [string] -or
        $herdrClassificationProp.Value -ne 'Runtime') {
        throw "Herdr runtime report EvidenceClassification must be string 'Runtime': $ReportPath"
    }

    Assert-V05JsonBooleanProperty -TargetObject $herdrJson -PropertyName 'RuntimeObserved' -ExpectedValue $true -ContextPath $ReportPath
    Assert-V05JsonBooleanProperty -TargetObject $herdrJson -PropertyName 'SnapshotObserved' -ExpectedValue $true -ContextPath $ReportPath
    Assert-V05JsonBooleanProperty -TargetObject $herdrJson -PropertyName 'EventObserved' -ExpectedValue $true -ContextPath $ReportPath
    Assert-V05JsonBooleanProperty -TargetObject $herdrJson -PropertyName 'ReconnectObserved' -ExpectedValue $true -ContextPath $ReportPath
    Assert-V05JsonBooleanProperty -TargetObject $herdrJson -PropertyName 'SessionControlInvoked' -ExpectedValue $false -ContextPath $ReportPath

    return $herdrJson
}

function Write-ComplianceRuntimeFailureReport {
    param(
        [Parameter(Mandatory)][string]$GateReportPath,
        [Parameter(Mandatory)][AllowEmptyString()][string]$FailureMessage,
        [AllowEmptyString()][string]$SourceCommit = 'UNRESOLVED',
        [AllowEmptyString()][string]$SourceTree = 'UNRESOLVED'
    )

    try {
        $parentDirectory = Split-Path -Parent $GateReportPath
        if (-not [string]::IsNullOrWhiteSpace($parentDirectory)) {
            New-Item -ItemType Directory -Path $parentDirectory -Force -ErrorAction SilentlyContinue | Out-Null
        }

        $reportLines = @(
            'HerdrOps v0.5 Issue #28 Compliance Privacy, Retention, and Runtime Acceptance',
            "GeneratedUtc: $([DateTime]::UtcNow.ToString('O'))",
            "SourceCommit: $SourceCommit",
            "SourceTree: $SourceTree",
            'Result: FAIL',
            'EvidenceClass: NoRuntimeCredit',
            'RuntimeAccepted: false',
            'SessionControlInvoked: false',
            "Failure: $FailureMessage"
        )
        $reportLines | Set-Content -LiteralPath $GateReportPath -Encoding utf8 -ErrorAction Stop
    }
    catch {
        Write-Warning "Could not write failure gate report '$GateReportPath': $($_.Exception.Message)"
    }
}

