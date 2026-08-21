function ConvertTo-V02ComparablePath {
    param(
        [Parameter(Mandatory)][string]$Path
    )

    if ([string]::IsNullOrWhiteSpace($Path)) {
        throw 'A Herdr session socket path is required.'
    }

    try {
        $fullPath = [IO.Path]::GetFullPath($Path)
        while ($fullPath.Length -gt 3 -and
               ($fullPath.EndsWith('\') -or $fullPath.EndsWith('/'))) {
            $fullPath = $fullPath.Substring(0, $fullPath.Length - 1)
        }
        return $fullPath.ToUpperInvariant()
    }
    catch {
        throw "Could not normalize Herdr session socket path '$Path'."
    }
}

function Assert-V02AcceptanceSessionTopology {
    param(
        [Parameter(Mandatory)][string]$SessionListJson,
        [Parameter(Mandatory)][string]$ControlSocketPath,
        [Parameter(Mandatory)][string]$TargetSocketPath
    )

    if ([string]::IsNullOrWhiteSpace($SessionListJson)) {
        throw 'Herdr session list output is empty.'
    }

    try {
        $document = $SessionListJson | ConvertFrom-Json
    }
    catch {
        throw 'Herdr session list returned invalid JSON.'
    }

    $sessions = @($document.sessions)
    if ($sessions.Count -eq 0) {
        throw 'Herdr session list did not contain any named sessions.'
    }

    $controlPath = ConvertTo-V02ComparablePath -Path $ControlSocketPath
    $targetPath = ConvertTo-V02ComparablePath -Path $TargetSocketPath
    if ($controlPath -eq $targetPath) {
        throw 'Acceptance control and target Agent Lab sockets must be different.'
    }

    $controlMatches = @($sessions | Where-Object {
        $socketPath = [string]$_.socket_path
        -not [string]::IsNullOrWhiteSpace($socketPath) -and
            (ConvertTo-V02ComparablePath -Path $socketPath) -eq $controlPath
    })
    if ($controlMatches.Count -ne 1) {
        throw 'The active control socket did not resolve to exactly one named Herdr session.'
    }

    $controlSession = $controlMatches[0]
    if ([string]$controlSession.name -cne 'acceptance') {
        throw "The runtime gate must run in the isolated 'acceptance' session, not '$($controlSession.name)'."
    }
    if ([bool]$controlSession.running -ne $true) {
        throw "The isolated 'acceptance' session is not running. Start it before the human-controlled runtime phase."
    }

    $targetMatches = @($sessions | Where-Object {
        $socketPath = [string]$_.socket_path
        -not [string]::IsNullOrWhiteSpace($socketPath) -and
            (ConvertTo-V02ComparablePath -Path $socketPath) -eq $targetPath
    })
    if ($targetMatches.Count -ne 1) {
        throw 'The target Agent Lab socket did not resolve to exactly one named Herdr session.'
    }

    $targetSession = $targetMatches[0]
    if ([string]$targetSession.name -ceq 'acceptance') {
        throw 'The target Agent Lab socket must not be the isolated acceptance session socket.'
    }
    if ([bool]$targetSession.running -ne $true) {
        throw "The target Agent Lab session '$($targetSession.name)' is not running. Do not start or stop it from the gate."
    }

    return [pscustomobject]@{
        ControlSessionName = [string]$controlSession.name
        TargetSessionName  = [string]$targetSession.name
    }
}

function Assert-AllAgentsHaveLiveIdentity {
    param(
        [Parameter(Mandatory)]$Transition,
        [Parameter(Mandatory)][string]$Name
    )

    Assert-True (Test-ObjectHasProperty -Object $Transition -Name 'AllAgentsHaveLiveIdentity') "$Name Core transition omitted the aggregate Agent-identity contract flag."
    Assert-True ([bool]$Transition.AllAgentsHaveLiveIdentity) "$Name Core transition admitted an incomplete or mismatched pane/Agent mapping, Agentless pane, blank identity, or Unknown Agent in the state."
}
