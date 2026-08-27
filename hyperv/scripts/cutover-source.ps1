[CmdletBinding(SupportsShouldProcess, ConfirmImpact='High')]
param(
    [Parameter(Mandatory)][string]$VMName,
    [Parameter(Mandatory)][string]$ConfirmVMName,
    [ValidateRange(10,3600)][int]$TimeoutSeconds = 300
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '..\HyperV2PVE.psm1') -Force
if ($ConfirmVMName -ne $VMName) { throw '-ConfirmVMName must exactly match -VMName.' }
Stop-HV2PVESourceForCutover -VMName $VMName -TimeoutSeconds $TimeoutSeconds -Confirm:$false |
    ConvertTo-Json -Depth 8
