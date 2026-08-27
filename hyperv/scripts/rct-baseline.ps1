[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)][string]$VMName,
    [Parameter(Mandatory)][string]$DestinationPath,
    [string]$MigrationId = ([guid]::NewGuid().ToString()),
    [ValidateSet('ApplicationConsistent','CrashConsistent')]
    [string]$Consistency = 'ApplicationConsistent',
    [string]$StatePath
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '..\HyperV2PVE.psm1') -Force

$vmInfo = Get-HV2PVEVMInfo -VMName $VMName
$rp = New-HV2PVERctReferencePoint -VMName $VMName -Consistency $Consistency -Confirm:$false
$exportRoot = Join-Path $DestinationPath $MigrationId
New-Item -ItemType Directory -Path $exportRoot -Force | Out-Null
$export = Export-HV2PVEReferencePoint -ReferencePointInstanceID $rp.InstanceID -DestinationPath $exportRoot -Confirm:$false

$state = [ordered]@{
    schema_version = 2
    migration_id = $MigrationId
    phase = 'BASELINE_READY'
    source = [ordered]@{
        computer_name = $env:COMPUTERNAME
        vm_name = $vmInfo.VMName
        vm_id = $vmInfo.VMId
        state = $vmInfo.State
        generation = $vmInfo.Generation
        processor_count = $vmInfo.ProcessorCount
        memory_startup_bytes = $vmInfo.MemoryStartupBytes
        checkpoint_type = $vmInfo.CheckpointType
        disks = $vmInfo.Disks
        networks = $vmInfo.Networks
    }
    baseline = [ordered]@{
        mode = 'rct-reference-point-export'
        export_root = $export.DestinationPath
        files = $export.Files
        reference_point = $rp
        created_at_utc = $rp.CreatedAtUtc
        exported_at_utc = $export.ExportedAtUtc
    }
    destination = [ordered]@{
        proxmox_node = $null
        proxmox_vmid = $null
        production_vnet = $null
        test_vnet = $null
        tested = $false
        powered_on = $false
        disk_map = @{}
    }
    sync = [ordered]@{
        mode = 'reference-point-export'
        rct_implemented = $true
        native_rct_acceleration = $false
        authoritative_reference_point = $rp.InstanceID
        authoritative_reference_path = $rp.Path
        pending_reference_point = $null
        sequence = 0
        last_successful_sync_utc = $rp.CreatedAtUtc
        last_bundle = $export.DestinationPath
        disks = @{}
    }
    validation = [ordered]@{
        baseline_verified = $false
        isolated_boot_verified = $false
        last_sync_verified = $false
        network_identity_verified = $false
        guest_boot_verified = $false
        application_verified = $false
    }
    cutover = [ordered]@{
        authorized = $false
        authorized_at_utc = $null
        source_stopped_at_utc = $null
        final_sync_completed_at_utc = $null
        destination_started_at_utc = $null
        rollback_deadline_utc = $null
        destination_writes_possible = $false
    }
    history = @()
    created_at_utc = [DateTime]::UtcNow.ToString('o')
    updated_at_utc = [DateTime]::UtcNow.ToString('o')
}

$json = $state | ConvertTo-Json -Depth 24
if ($StatePath) {
    $parent = Split-Path -Parent $StatePath
    if ($parent -and -not (Test-Path -LiteralPath $parent)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
    $json | Set-Content -LiteralPath $StatePath -Encoding utf8
}
$json
