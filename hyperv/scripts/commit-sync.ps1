[CmdletBinding(SupportsShouldProcess, ConfirmImpact='High')]
param(
    [Parameter(Mandatory)][string]$VMName,
    [Parameter(Mandatory)][string]$OldReferencePointInstanceID,
    [Parameter(Mandatory)][string]$NewReferencePointInstanceID,
    [Parameter(Mandatory)][string]$ConfirmNewReferencePoint
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '..\HyperV2PVE.psm1') -Force
Import-Module Hyper-V -ErrorAction Stop
if ($ConfirmNewReferencePoint -cne $NewReferencePointInstanceID) {
    throw '-ConfirmNewReferencePoint must exactly match -NewReferencePointInstanceID.'
}
$vm = Get-VM -Name $VMName -ErrorAction Stop
$old = Get-HV2PVERctReferencePoint -InstanceID $OldReferencePointInstanceID
$new = Get-HV2PVERctReferencePoint -InstanceID $NewReferencePointInstanceID
if ([string]$old.VMId -ne [string]$vm.VMId -or [string]$new.VMId -ne [string]$vm.VMId) {
    throw 'Reference point VM identity does not match the requested VM. Refusing cleanup.'
}
if ($PSCmdlet.ShouldProcess($OldReferencePointInstanceID, "Remove old RCT reference point after destination commit to $NewReferencePointInstanceID")) {
    Remove-HV2PVEReferencePoint -InstanceID $OldReferencePointInstanceID -Confirm:$false
}
[pscustomobject]@{
    VMName = $VMName
    RemovedReferencePoint = $OldReferencePointInstanceID
    AuthoritativeReferencePoint = $NewReferencePointInstanceID
    CommittedAtUtc = [DateTime]::UtcNow.ToString('o')
} | ConvertTo-Json -Depth 8
