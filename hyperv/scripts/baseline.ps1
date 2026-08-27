[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)]
    [string]$VMName,

    [Parameter(Mandatory)]
    [string]$DestinationPath,

    [string]$ComputerName = $env:COMPUTERNAME,

    [string]$MigrationId = ([guid]::NewGuid().ToString()),

    [string]$StatePath
)

$ErrorActionPreference = 'Stop'

$modulePath = Join-Path $PSScriptRoot '..\HyperV2PVE.psd1'
Import-Module $modulePath -Force

$vmInfo = Get-HV2PVEVMInfo -VMName $VMName -ComputerName $ComputerName

$checkpoint = New-HV2PVEBaselineCheckpoint `
    -VMName $VMName `
    -ComputerName $ComputerName `
    -MigrationId $MigrationId `
    -Confirm:$false

$export = Export-HV2PVEBaseline `
    -VMName $VMName `
    -ComputerName $ComputerName `
    -CheckpointName $checkpoint.CheckpointName `
    -DestinationPath $DestinationPath `
    -MigrationId $MigrationId `
    -Confirm:$false

$state = [ordered]@{
    schema_version = 1
    migration_id = $MigrationId
    phase = 'BASELINE_READY'
    source = [ordered]@{
        computer_name = $ComputerName
        vm_name = $vmInfo.VMName
        vm_id = $vmInfo.VMId
        generation = $vmInfo.Generation
        original_power_state = $vmInfo.State
        checkpoint_type = $vmInfo.CheckpointType
        disks = $vmInfo.Disks
        networks = $vmInfo.Networks
    }
    baseline = [ordered]@{
        checkpoint_name = $checkpoint.CheckpointName
        checkpoint_id = $checkpoint.CheckpointId
        export_root = $export.ExportRoot
        files = $export.Files
        created_at_utc = $checkpoint.CreatedAtUtc
        exported_at_utc = $export.ExportedAtUtc
    }
    destination = [ordered]@{
        proxmox_vmid = $null
        proxmox_node = $null
        production_vnet = $null
        test_vnet = $null
        tested = $false
    }
    sync = [ordered]@{
        mode = 'baseline-only'
        rct_implemented = $false
        last_successful_sync_utc = $null
    }
}

$json = $state | ConvertTo-Json -Depth 16

if ($StatePath) {
    $parent = Split-Path -Parent $StatePath
    if ($parent -and -not (Test-Path -LiteralPath $parent)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }
    $json | Set-Content -LiteralPath $StatePath -Encoding utf8
}

$json
