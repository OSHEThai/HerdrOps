#requires -Version 5.1
[CmdletBinding()]
param([string]$RepositoryRoot)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if ([string]::IsNullOrWhiteSpace($RepositoryRoot)) {
    $RepositoryRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
}

$producerPath = Join-Path $RepositoryRoot 'src\HerdrOps.App\RuntimeEvidence\RendererTargetObservationProducer.cs'
$appPath = Join-Path $RepositoryRoot 'src\HerdrOps.App\App.xaml.cs'
$optionsPath = Join-Path $RepositoryRoot 'src\HerdrOps.App\RuntimeEvidence\RuntimeEvidenceOptions.cs'

function Assert-ProducerContract {
    param([string]$Producer,[string]$App,[string]$Options)
    $requiredProducer = @(
        'PipeOptions.Asynchronous | PipeOptions.CurrentUserOnly',
        'Renderer target observation producer is one-time only.',
        'RequireNoReparsePoints',
        'names.Distinct(StringComparer.Ordinal).Count() != names.Length',
        'V02RendererTargetObservation',
        'TargetProcessNativeObservation',
        'RuntimeRenderPolicy.ObserveAndRequireSoftwareOnly',
        '_firstWindowAllowed.TrySetResult()',
        '_firstWindowAttached.Task.WaitAsync',
        'SHA256.HashData(stream)')
    foreach($token in $requiredProducer) {
        if ($Producer.IndexOf($token,[StringComparison]::Ordinal) -lt 0) {
            throw "Renderer producer omitted required fail-closed token: $token"
        }
    }
    if ($Producer.IndexOf('RuntimeCredit',[StringComparison]::OrdinalIgnoreCase) -ge 0) {
        throw 'Renderer target producer must not author Runtime-credit claims.'
    }
    foreach($option in @(
        '--renderer-observation-pipe','--renderer-runtime-evidence-root',
        '--renderer-run-nonce','--renderer-package-receipt-sha256',
        '--renderer-package-identity-path',
        '--renderer-source-commit','--renderer-source-tree')) {
        if ($Options.IndexOf($option,[StringComparison]::Ordinal) -lt 0) {
            throw "Runtime option parser omitted exact renderer binding: $option"
        }
    }
    $wait = $App.IndexOf('WaitForFirstWindowPermissionAsync',[StringComparison]::Ordinal)
    $create = $App.IndexOf('mainWindow = new MainWindow',[StringComparison]::Ordinal)
    $attach = $App.IndexOf('AttachFirstWindow(mainWindow)',[StringComparison]::Ordinal)
    if ($wait -lt 0 -or $create -le $wait -or $attach -le $create) {
        throw 'App startup does not preserve permission -> first HWND -> one-time attachment ordering.'
    }
}

$producer = Get-Content -Raw -LiteralPath $producerPath
$app = Get-Content -Raw -LiteralPath $appPath
$options = Get-Content -Raw -LiteralPath $optionsPath
Assert-ProducerContract $producer $app $options

$hostileCases = @(
    @{Name='current-user pipe guard';Text=$producer.Replace('PipeOptions.Asynchronous | PipeOptions.CurrentUserOnly','PipeOptions.Asynchronous')},
    @{Name='duplicate JSON guard';Text=$producer.Replace('names.Distinct(StringComparer.Ordinal).Count() != names.Length','false')},
    @{Name='pre-HWND handshake';Text=$producer.Replace('_firstWindowAttached.Task.WaitAsync','Task.CompletedTask.WaitAsync')},
    @{Name='same-handle hash';Text=$producer.Replace('SHA256.HashData(stream)','SHA256.HashData(File.ReadAllBytes(path))')}
)
foreach($case in $hostileCases) {
    $failed = $false
    try { Assert-ProducerContract ([string]$case.Text) $app $options } catch { $failed = $true }
    if (-not $failed) { throw "Hostile mutation escaped renderer producer contract: $($case.Name)" }
}

[pscustomobject][ordered]@{
    EvidenceClass = 'Static/Synthetic'
    Issue = '9,10,149'
    Result = 'PASS'
    HostileCases = $hostileCases.Count
    RuntimeObserved = $false
    RuntimeCredit = 'NOT CLAIMED'
    ReleaseCredit = 'NOT CLAIMED'
}
