function Assert-True {
    param(
        [Parameter(Mandatory)][bool]$Condition,
        [Parameter(Mandatory)][string]$Message
    )

    if (-not $Condition) { throw $Message }
}

function Test-ObjectHasProperty {
    param(
        [Parameter(Mandatory)]$Object,
        [Parameter(Mandatory)][string]$Name
    )

    return $null -ne $Object.PSObject.Properties[$Name]
}

function Assert-AllAgentsHaveLiveIdentity {
    param(
        [Parameter(Mandatory)]$Transition,
        [Parameter(Mandatory)][string]$Name
    )

    Assert-True (Test-ObjectHasProperty -Object $Transition -Name 'AllAgentsHaveLiveIdentity') "$Name Core transition omitted the aggregate Agent-identity contract flag."
    Assert-True ([bool]$Transition.AllAgentsHaveLiveIdentity) "$Name Core transition admitted an Agentless, blank-identity, or Unknown Agent in the state."
}
