[CmdletBinding(SupportsShouldProcess, ConfirmImpact='High')]
param(
    [Parameter(Mandatory)][string]$VMName,
    [Parameter(Mandatory)][string]$ConfirmVMName
)
$ErrorActionPreference = 'Stop'
if ($ConfirmVMName -cne $VMName) { throw 'ConfirmVMName must exactly match VMName.' }
Import-Module Hyper-V -ErrorAction Stop
$vm = Get-VM -Name $VMName -ErrorAction Stop
if ($vm.State -eq 'Running') { return $vm }
if ($PSCmdlet.ShouldProcess($VMName, 'Restart Hyper-V source during rollback')) {
    Start-VM -VM $vm -ErrorAction Stop
    Get-VM -Name $VMName
}
