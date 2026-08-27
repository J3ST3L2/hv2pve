Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Assert-HV2PVEHyperVModule {
    [CmdletBinding()]
    param()

    if (-not (Get-Module -ListAvailable -Name Hyper-V)) {
        throw 'The Hyper-V PowerShell module is not installed on this system.'
    }

    Import-Module Hyper-V -ErrorAction Stop
}

function Get-HV2PVEVMInfo {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$VMName,

        [string]$ComputerName = $env:COMPUTERNAME
    )

    Assert-HV2PVEHyperVModule

    $vm = Get-VM -ComputerName $ComputerName -Name $VMName -ErrorAction Stop
    $drives = @(Get-VMHardDiskDrive -ComputerName $ComputerName -VMName $VMName -ErrorAction Stop)
    $adapters = @(Get-VMNetworkAdapter -ComputerName $ComputerName -VMName $VMName -ErrorAction Stop)

    $disks = foreach ($drive in $drives) {
        $vhd = $null
        try {
            $vhd = Get-VHD -ComputerName $ComputerName -Path $drive.Path -ErrorAction Stop
        }
        catch {
            # Some remote/storage arrangements may prevent Get-VHD inspection.
        }

        [pscustomobject]@{
            ControllerType     = [string]$drive.ControllerType
            ControllerNumber   = $drive.ControllerNumber
            ControllerLocation = $drive.ControllerLocation
            Path               = $drive.Path
            VhdType            = if ($vhd) { [string]$vhd.VhdType } else { $null }
            FileSizeBytes      = if ($vhd) { $vhd.FileSize } else { $null }
            VirtualSizeBytes   = if ($vhd) { $vhd.Size } else { $null }
            ParentPath         = if ($vhd) { $vhd.ParentPath } else { $null }
        }
    }

    $networks = foreach ($adapter in $adapters) {
        $vlan = $null
        try {
            $vlan = Get-VMNetworkAdapterVlan -ComputerName $ComputerName -VMName $VMName -VMNetworkAdapterName $adapter.Name -ErrorAction Stop
        }
        catch {
        }

        [pscustomobject]@{
            Name       = $adapter.Name
            SwitchName = $adapter.SwitchName
            MacAddress = $adapter.MacAddress
            Status     = [string]$adapter.Status
            VlanMode   = if ($vlan) { [string]$vlan.OperationMode } else { $null }
            AccessVlan = if ($vlan -and $vlan.PSObject.Properties.Name -contains 'AccessVlanId') { $vlan.AccessVlanId } else { $null }
        }
    }

    $snapshots = @(Get-VMSnapshot -ComputerName $ComputerName -VMName $VMName -ErrorAction SilentlyContinue | ForEach-Object {
        [pscustomobject]@{
            Name         = $_.Name
            Id           = [string]$_.Id
            CreationTime = $_.CreationTime
            ParentId     = if ($_.ParentSnapshotId) { [string]$_.ParentSnapshotId } else { $null }
            SnapshotType = if ($_.PSObject.Properties.Name -contains 'SnapshotType') { [string]$_.SnapshotType } else { $null }
        }
    })

    [pscustomobject]@{
        SchemaVersion       = 1
        ComputerName        = $ComputerName
        VMName              = $vm.Name
        VMId                = [string]$vm.VMId
        State               = [string]$vm.State
        Status              = [string]$vm.Status
        Generation          = $vm.Generation
        ProcessorCount      = $vm.ProcessorCount
        MemoryAssignedBytes = $vm.MemoryAssigned
        MemoryStartupBytes  = $vm.MemoryStartup
        AutomaticStartAction = [string]$vm.AutomaticStartAction
        AutomaticStopAction  = [string]$vm.AutomaticStopAction
        CheckpointType      = [string]$vm.CheckpointType
        Disks               = @($disks)
        Networks            = @($networks)
        Checkpoints         = @($snapshots)
        DiscoveredAtUtc     = [DateTime]::UtcNow.ToString('o')
    }
}

function Assert-HV2PVEProductionCheckpointPolicy {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [Microsoft.HyperV.PowerShell.VirtualMachine]$VM
    )

    $checkpointType = [string]$VM.CheckpointType
    $allowed = @('Production', 'ProductionOnly')

    if ($checkpointType -notin $allowed) {
        throw "VM '$($VM.Name)' CheckpointType is '$checkpointType'. hv2pve requires Production or ProductionOnly before creating a baseline. Configure the VM deliberately and retry."
    }
}

function New-HV2PVEBaselineCheckpoint {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)]
        [string]$VMName,

        [string]$ComputerName = $env:COMPUTERNAME,

        [string]$MigrationId = ([guid]::NewGuid().ToString()),

        [string]$CheckpointName
    )

    Assert-HV2PVEHyperVModule

    $vm = Get-VM -ComputerName $ComputerName -Name $VMName -ErrorAction Stop
    Assert-HV2PVEProductionCheckpointPolicy -VM $vm

    if (-not $CheckpointName) {
        $stamp = (Get-Date).ToUniversalTime().ToString('yyyyMMdd-HHmmss')
        $CheckpointName = "hv2pve-$MigrationId-$stamp"
    }

    if (-not $PSCmdlet.ShouldProcess("$ComputerName/$VMName", "Create production baseline checkpoint '$CheckpointName'")) {
        return
    }

    $beforeIds = @(Get-VMSnapshot -ComputerName $ComputerName -VMName $VMName -ErrorAction SilentlyContinue | ForEach-Object { [string]$_.Id })

    Checkpoint-VM -ComputerName $ComputerName -Name $VMName -SnapshotName $CheckpointName -ErrorAction Stop | Out-Null

    $checkpoint = Get-VMSnapshot -ComputerName $ComputerName -VMName $VMName -Name $CheckpointName -ErrorAction Stop |
        Where-Object { [string]$_.Id -notin $beforeIds } |
        Sort-Object CreationTime -Descending |
        Select-Object -First 1

    if (-not $checkpoint) {
        throw "Checkpoint '$CheckpointName' was requested but could not be uniquely identified afterward."
    }

    [pscustomobject]@{
        MigrationId   = $MigrationId
        ComputerName  = $ComputerName
        VMName        = $VMName
        VMId          = [string]$vm.VMId
        CheckpointName = $checkpoint.Name
        CheckpointId   = [string]$checkpoint.Id
        CheckpointType = [string]$vm.CheckpointType
        CreationTime   = $checkpoint.CreationTime
        CreatedAtUtc   = [DateTime]::UtcNow.ToString('o')
    }
}

function Export-HV2PVEBaseline {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)]
        [string]$VMName,

        [Parameter(Mandatory)]
        [string]$CheckpointName,

        [Parameter(Mandatory)]
        [string]$DestinationPath,

        [string]$ComputerName = $env:COMPUTERNAME,

        [string]$MigrationId = ([guid]::NewGuid().ToString())
    )

    Assert-HV2PVEHyperVModule

    $vm = Get-VM -ComputerName $ComputerName -Name $VMName -ErrorAction Stop
    $snapshot = Get-VMSnapshot -ComputerName $ComputerName -VMName $VMName -Name $CheckpointName -ErrorAction Stop |
        Sort-Object CreationTime -Descending |
        Select-Object -First 1

    if (-not $snapshot) {
        throw "Checkpoint '$CheckpointName' was not found for VM '$VMName'."
    }

    if (-not (Test-Path -LiteralPath $DestinationPath)) {
        New-Item -ItemType Directory -Path $DestinationPath -Force | Out-Null
    }

    $exportRoot = Join-Path $DestinationPath $MigrationId
    if (Test-Path -LiteralPath $exportRoot) {
        throw "Baseline export destination already exists: $exportRoot"
    }

    if (-not $PSCmdlet.ShouldProcess("$ComputerName/$VMName checkpoint $CheckpointName", "Export baseline to '$exportRoot'")) {
        return
    }

    New-Item -ItemType Directory -Path $exportRoot -Force | Out-Null

    Export-VMSnapshot -VMSnapshot $snapshot -Path $exportRoot -ErrorAction Stop

    $files = @(Get-ChildItem -LiteralPath $exportRoot -File -Recurse | ForEach-Object {
        [pscustomobject]@{
            FullName  = $_.FullName
            Length    = $_.Length
            Extension = $_.Extension
        }
    })

    [pscustomobject]@{
        MigrationId    = $MigrationId
        ComputerName   = $ComputerName
        VMName         = $VMName
        VMId           = [string]$vm.VMId
        CheckpointName = $snapshot.Name
        CheckpointId   = [string]$snapshot.Id
        ExportRoot     = $exportRoot
        Files          = @($files)
        ExportedAtUtc  = [DateTime]::UtcNow.ToString('o')
    }
}

function Remove-HV2PVEBaselineCheckpoint {
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
    param(
        [Parameter(Mandatory)]
        [string]$VMName,

        [Parameter(Mandatory)]
        [string]$CheckpointName,

        [string]$ComputerName = $env:COMPUTERNAME
    )

    Assert-HV2PVEHyperVModule

    $snapshot = Get-VMSnapshot -ComputerName $ComputerName -VMName $VMName -Name $CheckpointName -ErrorAction Stop |
        Sort-Object CreationTime -Descending |
        Select-Object -First 1

    if ($PSCmdlet.ShouldProcess("$ComputerName/$VMName checkpoint $CheckpointName", 'Remove migration checkpoint')) {
        Remove-VMSnapshot -VMSnapshot $snapshot -ErrorAction Stop
    }
}

Export-ModuleMember -Function @(
    'Get-HV2PVEVMInfo',
    'New-HV2PVEBaselineCheckpoint',
    'Export-HV2PVEBaseline',
    'Remove-HV2PVEBaselineCheckpoint'
)
