Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:HV2PVENamespace = 'root\virtualization\v2'

function Assert-HV2PVEAdministrator {
    [CmdletBinding()]
    param()

    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($identity)
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw 'hv2pve Hyper-V source operations must run from an elevated PowerShell session.'
    }
}

function Assert-HV2PVEHyperVModule {
    [CmdletBinding()]
    param()

    if (-not (Get-Module -ListAvailable -Name Hyper-V)) {
        throw 'The Hyper-V PowerShell module is not installed on this system.'
    }
    Import-Module Hyper-V -ErrorAction Stop
}

function New-HV2PVEManagementScope {
    [CmdletBinding()]
    param([string]$ComputerName = '.')

    Add-Type -AssemblyName System.Management
    $scope = [System.Management.ManagementScope]::new("\\$ComputerName\$script:HV2PVENamespace")
    $scope.Connect()
    return $scope
}

function Get-HV2PVEManagementObject {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [System.Management.ManagementScope]$Scope,
        [Parameter(Mandatory)]
        [string]$ClassName,
        [string]$Filter
    )

    $query = if ($Filter) { "SELECT * FROM $ClassName WHERE $Filter" } else { "SELECT * FROM $ClassName" }
    $searcher = [System.Management.ManagementObjectSearcher]::new($Scope, [System.Management.ObjectQuery]::new($query))
    $items = @($searcher.Get())
    if ($items.Count -ne 1) {
        throw "Expected one $ClassName object but found $($items.Count). Query: $query"
    }
    return $items[0]
}

function Wait-HV2PVEManagementJob {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [System.Management.ManagementScope]$Scope,
        [Parameter(Mandatory)]
        [string]$JobPath,
        [int]$TimeoutSeconds = 3600
    )

    $job = [System.Management.ManagementObject]::new($Scope, [System.Management.ManagementPath]::new($JobPath), $null)
    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)

    while ($true) {
        $job.Get()
        $state = [int]$job['JobState']
        if ($state -eq 7) {
            if ([int]$job['ErrorCode'] -ne 0) {
                throw "Hyper-V WMI job failed. ErrorCode=$($job['ErrorCode']) ErrorDescription=$($job['ErrorDescription'])"
            }
            return $job
        }
        if ($state -in 8, 9, 10) {
            throw "Hyper-V WMI job terminated in state $state. ErrorCode=$($job['ErrorCode']) ErrorDescription=$($job['ErrorDescription'])"
        }
        if ([DateTime]::UtcNow -gt $deadline) {
            throw "Timed out waiting for Hyper-V WMI job $JobPath"
        }
        Start-Sleep -Milliseconds 500
    }
}

function Resolve-HV2PVEAffectedElement {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [System.Management.ManagementScope]$Scope,
        [Parameter(Mandatory)]
        [System.Management.ManagementObject]$Job,
        [Parameter(Mandatory)]
        [string]$ResultClass
    )

    $escaped = $Job.Path.Path.Replace('\\', '\\\\').Replace('"', '\"')
    $query = "ASSOCIATORS OF {$($Job.Path.Path)} WHERE AssocClass=CIM_AffectedJobElement ResultClass=$ResultClass"
    $searcher = [System.Management.ManagementObjectSearcher]::new($Scope, [System.Management.ObjectQuery]::new($query))
    $items = @($searcher.Get())
    if ($items.Count -lt 1) {
        throw "Could not resolve affected $ResultClass from job $($Job.Path.Path)"
    }
    return $items[0]
}

function ConvertTo-HV2PVEEmbeddedMof {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [System.Management.ManagementScope]$Scope,
        [Parameter(Mandatory)]
        [string]$ClassName,
        [Parameter(Mandatory)]
        [hashtable]$Properties
    )

    $class = [System.Management.ManagementClass]::new(
        $Scope,
        [System.Management.ManagementPath]::new($ClassName),
        $null
    )
    $instance = $class.CreateInstance()
    foreach ($key in $Properties.Keys) {
        $instance[$key] = $Properties[$key]
    }
    return $instance.GetText([System.Management.TextFormat]::Mof)
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
        try { $vhd = Get-VHD -ComputerName $ComputerName -Path $drive.Path -ErrorAction Stop } catch {}
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
        } catch {}
        [pscustomobject]@{
            Name       = $adapter.Name
            SwitchName = $adapter.SwitchName
            MacAddress = $adapter.MacAddress
            Status     = [string]$adapter.Status
            VlanMode   = if ($vlan) { [string]$vlan.OperationMode } else { $null }
            AccessVlan = if ($vlan -and $vlan.PSObject.Properties.Name -contains 'AccessVlanId') { $vlan.AccessVlanId } else { $null }
        }
    }

    $checkpoints = @(Get-VMSnapshot -ComputerName $ComputerName -VMName $VMName -ErrorAction SilentlyContinue | ForEach-Object {
        [pscustomobject]@{
            Name         = $_.Name
            Id           = [string]$_.Id
            CreationTime = $_.CreationTime
            ParentId     = if ($_.ParentSnapshotId) { [string]$_.ParentSnapshotId } else { $null }
            SnapshotType = if ($_.PSObject.Properties.Name -contains 'SnapshotType') { [string]$_.SnapshotType } else { $null }
        }
    })

    [pscustomobject]@{
        SchemaVersion        = 2
        ComputerName         = $ComputerName
        VMName               = $vm.Name
        VMId                 = [string]$vm.VMId
        State                = [string]$vm.State
        Status               = [string]$vm.Status
        Generation           = $vm.Generation
        ProcessorCount       = $vm.ProcessorCount
        MemoryAssignedBytes  = $vm.MemoryAssigned
        MemoryStartupBytes   = $vm.MemoryStartup
        AutomaticStartAction = [string]$vm.AutomaticStartAction
        AutomaticStopAction  = [string]$vm.AutomaticStopAction
        CheckpointType       = [string]$vm.CheckpointType
        Disks                = @($disks)
        Networks             = @($networks)
        Checkpoints          = @($checkpoints)
        DiscoveredAtUtc      = [DateTime]::UtcNow.ToString('o')
    }
}

function Assert-HV2PVEProductionCheckpointPolicy {
    [CmdletBinding()]
    param([Parameter(Mandatory)][Microsoft.HyperV.PowerShell.VirtualMachine]$VM)

    $checkpointType = [string]$VM.CheckpointType
    if ($checkpointType -notin @('Production', 'ProductionOnly')) {
        throw "VM '$($VM.Name)' CheckpointType is '$checkpointType'. Configure Production or ProductionOnly before a migration baseline."
    }
}

function New-HV2PVEBaselineCheckpoint {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][string]$VMName,
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
    if (-not $PSCmdlet.ShouldProcess("$ComputerName/$VMName", "Create production checkpoint '$CheckpointName'")) { return }

    $beforeIds = @(Get-VMSnapshot -ComputerName $ComputerName -VMName $VMName -ErrorAction SilentlyContinue | ForEach-Object { [string]$_.Id })
    Checkpoint-VM -ComputerName $ComputerName -Name $VMName -SnapshotName $CheckpointName -ErrorAction Stop | Out-Null
    $checkpoint = Get-VMSnapshot -ComputerName $ComputerName -VMName $VMName -Name $CheckpointName -ErrorAction Stop |
        Where-Object { [string]$_.Id -notin $beforeIds } |
        Sort-Object CreationTime -Descending |
        Select-Object -First 1
    if (-not $checkpoint) { throw "Checkpoint '$CheckpointName' could not be uniquely identified afterward." }

    [pscustomobject]@{
        MigrationId = $MigrationId
        ComputerName = $ComputerName
        VMName = $VMName
        VMId = [string]$vm.VMId
        CheckpointName = $checkpoint.Name
        CheckpointId = [string]$checkpoint.Id
        CheckpointType = [string]$vm.CheckpointType
        CreationTime = $checkpoint.CreationTime
        CreatedAtUtc = [DateTime]::UtcNow.ToString('o')
    }
}

function Export-HV2PVEBaseline {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][string]$VMName,
        [Parameter(Mandatory)][string]$CheckpointName,
        [Parameter(Mandatory)][string]$DestinationPath,
        [string]$ComputerName = $env:COMPUTERNAME,
        [string]$MigrationId = ([guid]::NewGuid().ToString())
    )

    Assert-HV2PVEHyperVModule
    $vm = Get-VM -ComputerName $ComputerName -Name $VMName -ErrorAction Stop
    $snapshot = Get-VMSnapshot -ComputerName $ComputerName -VMName $VMName -Name $CheckpointName -ErrorAction Stop |
        Sort-Object CreationTime -Descending | Select-Object -First 1
    if (-not $snapshot) { throw "Checkpoint '$CheckpointName' was not found for VM '$VMName'." }
    if (-not (Test-Path -LiteralPath $DestinationPath)) { New-Item -ItemType Directory -Path $DestinationPath -Force | Out-Null }
    $exportRoot = Join-Path $DestinationPath $MigrationId
    if (Test-Path -LiteralPath $exportRoot) { throw "Baseline export destination already exists: $exportRoot" }
    if (-not $PSCmdlet.ShouldProcess("$ComputerName/$VMName checkpoint $CheckpointName", "Export baseline to '$exportRoot'")) { return }

    New-Item -ItemType Directory -Path $exportRoot -Force | Out-Null
    Export-VMSnapshot -VMSnapshot $snapshot -Path $exportRoot -ErrorAction Stop
    $files = @(Get-ChildItem -LiteralPath $exportRoot -File -Recurse | ForEach-Object {
        [pscustomobject]@{ FullName = $_.FullName; Length = $_.Length; Extension = $_.Extension }
    })
    [pscustomobject]@{
        MigrationId = $MigrationId
        ComputerName = $ComputerName
        VMName = $VMName
        VMId = [string]$vm.VMId
        CheckpointName = $snapshot.Name
        CheckpointId = [string]$snapshot.Id
        ExportRoot = $exportRoot
        Files = @($files)
        ExportedAtUtc = [DateTime]::UtcNow.ToString('o')
    }
}

function Remove-HV2PVEBaselineCheckpoint {
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
    param(
        [Parameter(Mandatory)][string]$VMName,
        [Parameter(Mandatory)][string]$CheckpointName,
        [string]$ComputerName = $env:COMPUTERNAME
    )

    Assert-HV2PVEHyperVModule
    $snapshot = Get-VMSnapshot -ComputerName $ComputerName -VMName $VMName -Name $CheckpointName -ErrorAction Stop |
        Sort-Object CreationTime -Descending | Select-Object -First 1
    if ($PSCmdlet.ShouldProcess("$ComputerName/$VMName checkpoint $CheckpointName", 'Remove migration checkpoint')) {
        Remove-VMSnapshot -VMSnapshot $snapshot -ErrorAction Stop
    }
}

function New-HV2PVERctReferencePoint {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][string]$VMName,
        [string]$ComputerName = '.',
        [ValidateSet('ApplicationConsistent','CrashConsistent')]
        [string]$Consistency = 'ApplicationConsistent',
        [int]$TimeoutSeconds = 3600
    )

    Assert-HV2PVEAdministrator
    if ($ComputerName -ne '.' -and $ComputerName -ne $env:COMPUTERNAME) {
        throw 'Native/reference-point source operations are intentionally local-only in v0.2. Run this command on the Hyper-V host.'
    }

    $scope = New-HV2PVEManagementScope -ComputerName '.'
    $escaped = $VMName.Replace("'", "''")
    $vm = Get-HV2PVEManagementObject -Scope $scope -ClassName 'Msvm_ComputerSystem' -Filter "ElementName='$escaped'"
    $service = Get-HV2PVEManagementObject -Scope $scope -ClassName 'Msvm_VirtualSystemReferencePointService'
    $level = if ($Consistency -eq 'ApplicationConsistent') { [byte]1 } else { [byte]2 }
    $settings = ConvertTo-HV2PVEEmbeddedMof -Scope $scope -ClassName 'Msvm_VirtualSystemReferencePointSettingData' -Properties @{ ConsistencyLevel = $level }

    if (-not $PSCmdlet.ShouldProcess($VMName, "Create RCT reference point ($Consistency)")) { return }

    $inParams = $service.GetMethodParameters('CreateReferencePoint')
    $inParams['AffectedSystem'] = $vm.Path.Path
    $inParams['ReferencePointSettings'] = $settings
    $inParams['ReferencePointType'] = [uint16]1
    $out = $service.InvokeMethod('CreateReferencePoint', $inParams, $null)
    $returnValue = [uint32]$out['ReturnValue']

    $referencePoint = $null
    if ($returnValue -eq 0 -and $out['ResultingReferencePoint']) {
        $path = [string]$out['ResultingReferencePoint']
        $referencePoint = [System.Management.ManagementObject]::new($scope, [System.Management.ManagementPath]::new($path), $null)
        $referencePoint.Get()
    } elseif ($returnValue -eq 4096 -and $out['Job']) {
        $job = Wait-HV2PVEManagementJob -Scope $scope -JobPath ([string]$out['Job']) -TimeoutSeconds $TimeoutSeconds
        $referencePoint = Resolve-HV2PVEAffectedElement -Scope $scope -Job $job -ResultClass 'Msvm_VirtualSystemReferencePoint'
    } else {
        throw "CreateReferencePoint failed with return value $returnValue"
    }

    [pscustomobject]@{
        InstanceID = [string]$referencePoint['InstanceID']
        Path = $referencePoint.Path.Path
        VMId = [string]$referencePoint['VirtualSystemIdentifier']
        ReferencePointType = [int]$referencePoint['ReferencePointType']
        ConsistencyLevel = [int]$referencePoint['ConsistencyLevel']
        VirtualDiskIdentifiers = @($referencePoint['VirtualDiskIdentifiers'])
        ResilientChangeTrackingIdentifiers = @($referencePoint['ResilientChangeTrackingIdentifiers'])
        CreatedAtUtc = [DateTime]::UtcNow.ToString('o')
    }
}

function Get-HV2PVERctReferencePoint {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$InstanceID,
        [string]$ComputerName = '.'
    )

    $scope = New-HV2PVEManagementScope -ComputerName $ComputerName
    $escaped = $InstanceID.Replace("'", "''")
    $rp = Get-HV2PVEManagementObject -Scope $scope -ClassName 'Msvm_VirtualSystemReferencePoint' -Filter "InstanceID='$escaped'"
    [pscustomobject]@{
        InstanceID = [string]$rp['InstanceID']
        Path = $rp.Path.Path
        VMId = [string]$rp['VirtualSystemIdentifier']
        ReferencePointType = [int]$rp['ReferencePointType']
        ConsistencyLevel = [int]$rp['ConsistencyLevel']
        VirtualDiskIdentifiers = @($rp['VirtualDiskIdentifiers'])
        ResilientChangeTrackingIdentifiers = @($rp['ResilientChangeTrackingIdentifiers'])
    }
}

function Export-HV2PVEReferencePoint {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][string]$ReferencePointInstanceID,
        [Parameter(Mandatory)][string]$DestinationPath,
        [string]$BaseReferencePointInstanceID,
        [string]$ComputerName = '.',
        [int]$TimeoutSeconds = 86400
    )

    Assert-HV2PVEAdministrator
    $scope = New-HV2PVEManagementScope -ComputerName $ComputerName
    $escaped = $ReferencePointInstanceID.Replace("'", "''")
    $rp = Get-HV2PVEManagementObject -Scope $scope -ClassName 'Msvm_VirtualSystemReferencePoint' -Filter "InstanceID='$escaped'"
    $service = Get-HV2PVEManagementObject -Scope $scope -ClassName 'Msvm_VirtualSystemReferencePointService'

    $properties = @{}
    if ($BaseReferencePointInstanceID) {
        $baseEscaped = $BaseReferencePointInstanceID.Replace("'", "''")
        $base = Get-HV2PVEManagementObject -Scope $scope -ClassName 'Msvm_VirtualSystemReferencePoint' -Filter "InstanceID='$baseEscaped'"
        $properties['BaseReferencePoint'] = $base.Path.Path
    }
    if (@($rp['VirtualDiskIdentifiers']).Count -gt 0) {
        $properties['DisksToExport'] = @($rp['VirtualDiskIdentifiers'])
    }
    $settings = ConvertTo-HV2PVEEmbeddedMof -Scope $scope -ClassName 'Msvm_VirtualSystemReferencePointExportSettingData' -Properties $properties

    if (-not (Test-Path -LiteralPath $DestinationPath)) { New-Item -ItemType Directory -Path $DestinationPath -Force | Out-Null }
    if (-not $PSCmdlet.ShouldProcess($ReferencePointInstanceID, "Export reference point to $DestinationPath")) { return }

    $inParams = $service.GetMethodParameters('ExportReferencePoint')
    $inParams['ReferencePoint'] = $rp.Path.Path
    $inParams['ExportDirectory'] = (Resolve-Path -LiteralPath $DestinationPath).Path
    $inParams['ExportSettingData'] = $settings
    $out = $service.InvokeMethod('ExportReferencePoint', $inParams, $null)
    $returnValue = [uint32]$out['ReturnValue']
    if ($returnValue -eq 4096 -and $out['Job']) {
        Wait-HV2PVEManagementJob -Scope $scope -JobPath ([string]$out['Job']) -TimeoutSeconds $TimeoutSeconds | Out-Null
    } elseif ($returnValue -ne 0) {
        throw "ExportReferencePoint failed with return value $returnValue"
    }

    $files = @(Get-ChildItem -LiteralPath $DestinationPath -File -Recurse | ForEach-Object {
        [pscustomobject]@{ FullName = $_.FullName; Length = $_.Length; Extension = $_.Extension }
    })
    [pscustomobject]@{
        ReferencePointInstanceID = $ReferencePointInstanceID
        BaseReferencePointInstanceID = $BaseReferencePointInstanceID
        DestinationPath = (Resolve-Path -LiteralPath $DestinationPath).Path
        Files = @($files)
        ExportedAtUtc = [DateTime]::UtcNow.ToString('o')
    }
}

function Remove-HV2PVEReferencePoint {
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact='High')]
    param(
        [Parameter(Mandatory)][string]$InstanceID,
        [string]$ComputerName = '.',
        [int]$TimeoutSeconds = 3600
    )

    Assert-HV2PVEAdministrator
    $scope = New-HV2PVEManagementScope -ComputerName $ComputerName
    $escaped = $InstanceID.Replace("'", "''")
    $rp = Get-HV2PVEManagementObject -Scope $scope -ClassName 'Msvm_VirtualSystemReferencePoint' -Filter "InstanceID='$escaped'"
    $service = Get-HV2PVEManagementObject -Scope $scope -ClassName 'Msvm_VirtualSystemReferencePointService'
    if (-not $PSCmdlet.ShouldProcess($InstanceID, 'Destroy Hyper-V reference point')) { return }

    $inParams = $service.GetMethodParameters('DestroyReferencePoint')
    $inParams['AffectedReferencePoint'] = $rp.Path.Path
    $out = $service.InvokeMethod('DestroyReferencePoint', $inParams, $null)
    $rv = [uint32]$out['ReturnValue']
    if ($rv -eq 4096 -and $out['Job']) {
        Wait-HV2PVEManagementJob -Scope $scope -JobPath ([string]$out['Job']) -TimeoutSeconds $TimeoutSeconds | Out-Null
    } elseif ($rv -ne 0) {
        throw "DestroyReferencePoint failed with return value $rv"
    }
}

function Stop-HV2PVESourceForCutover {
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact='High')]
    param(
        [Parameter(Mandatory)][string]$VMName,
        [string]$ComputerName = $env:COMPUTERNAME,
        [ValidateRange(10,3600)][int]$TimeoutSeconds = 300
    )

    Assert-HV2PVEHyperVModule
    $vm = Get-VM -ComputerName $ComputerName -Name $VMName -ErrorAction Stop
    if ($vm.State -eq 'Off') {
        return [pscustomobject]@{ VMName=$VMName; State='Off'; Changed=$false; StoppedAtUtc=[DateTime]::UtcNow.ToString('o') }
    }
    if (-not $PSCmdlet.ShouldProcess("$ComputerName/$VMName", 'Stop source VM for migration cutover')) { return }

    Stop-VM -ComputerName $ComputerName -Name $VMName -Shutdown -ErrorAction SilentlyContinue
    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    do {
        Start-Sleep -Seconds 2
        $vm = Get-VM -ComputerName $ComputerName -Name $VMName -ErrorAction Stop
        if ($vm.State -eq 'Off') { break }
    } while ([DateTime]::UtcNow -lt $deadline)

    if ($vm.State -ne 'Off') {
        throw "VM '$VMName' did not shut down within $TimeoutSeconds seconds. hv2pve will not force power-off automatically."
    }
    [pscustomobject]@{ VMName=$VMName; State='Off'; Changed=$true; StoppedAtUtc=[DateTime]::UtcNow.ToString('o') }
}


function Get-HV2PVERctDiskMap {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ReferencePointInstanceID,
        [string]$ComputerName = '.'
    )

    $scope = New-HV2PVEManagementScope -ComputerName $ComputerName
    $escaped = $ReferencePointInstanceID.Replace("'", "''")
    $rp = Get-HV2PVEManagementObject -Scope $scope -ClassName 'Msvm_VirtualSystemReferencePoint' -Filter "InstanceID='$escaped'"
    $diskIds = @($rp['VirtualDiskIdentifiers'])
    $rctIds = @($rp['ResilientChangeTrackingIdentifiers'])
    if ($diskIds.Count -ne $rctIds.Count) {
        throw "Reference point disk/RCT array length mismatch: disks=$($diskIds.Count) rct=$($rctIds.Count)"
    }

    $items = for ($i = 0; $i -lt $diskIds.Count; $i++) {
        $diskId = [string]$diskIds[$i]
        $diskEscaped = $diskId.Replace("'", "''")
        $resource = $null
        try {
            $resource = Get-HV2PVEManagementObject -Scope $scope -ClassName 'Msvm_StorageAllocationSettingData' -Filter "InstanceID='$diskEscaped'"
        } catch {
            Write-Verbose "Storage allocation object for '$diskId' was not uniquely resolved: $_"
        }

        $hostResource = if ($resource) { @($resource['HostResource']) | Select-Object -First 1 } else { $null }
        $path = $null
        if ($hostResource) {
            $candidate = [string]$hostResource
            if (Test-Path -LiteralPath $candidate -ErrorAction SilentlyContinue) {
                $path = (Resolve-Path -LiteralPath $candidate).Path
            } elseif ($candidate -match '^[A-Za-z]:\\') {
                $path = $candidate
            } elseif ($candidate -match '^\\\\') {
                $path = $candidate
            } else {
                # Some Hyper-V builds expose a WMI path to virtual-hard-disk setting data.
                try {
                    $obj = [System.Management.ManagementObject]::new(
                        $scope,
                        [System.Management.ManagementPath]::new($candidate),
                        $null
                    )
                    $obj.Get()
                    if ($obj.Properties.Name -contains 'Path') { $path = [string]$obj['Path'] }
                } catch {}
            }
        }

        [pscustomobject]@{
            Index = $i
            VirtualDiskInstanceID = $diskId
            RctId = [string]$rctIds[$i]
            HostResource = if ($hostResource) { [string]$hostResource } else { $null }
            Path = $path
            Resolved = [bool]$path
        }
    }
    @($items)
}

function Get-HV2PVEVirtualDiskChanges {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$LimitId,
        [uint64]$ByteOffset = 0,
        [uint64]$ByteLength = 0,
        [string]$ComputerName = '.',
        [int]$TimeoutSeconds = 3600
    )

    Assert-HV2PVEAdministrator
    if ($ComputerName -ne '.' -and $ComputerName -ne $env:COMPUTERNAME) {
        Write-Verbose 'GetVirtualDiskChanges supports WMI remote use, but hv2pve v0.2 validates it locally by default.'
    }
    Assert-HV2PVEHyperVModule
    if ($ByteLength -eq 0) {
        $vhd = Get-VHD -ComputerName $(if ($ComputerName -eq '.') { $env:COMPUTERNAME } else { $ComputerName }) -Path $Path -ErrorAction Stop
        $ByteLength = [uint64]$vhd.Size - $ByteOffset
    }

    $scope = New-HV2PVEManagementScope -ComputerName $ComputerName
    $service = Get-HV2PVEManagementObject -Scope $scope -ClassName 'Msvm_ImageManagementService'
    $cursor = $ByteOffset
    $end = $ByteOffset + $ByteLength
    $ranges = [System.Collections.Generic.List[object]]::new()

    while ($cursor -lt $end) {
        $inParams = $service.GetMethodParameters('GetVirtualDiskChanges')
        $inParams['Path'] = $Path
        $inParams['LimitId'] = $LimitId
        $inParams['TargetSnapshotId'] = ''
        $inParams['ByteOffset'] = [uint64]$cursor
        $inParams['ByteLength'] = [uint64]($end - $cursor)
        $out = $service.InvokeMethod('GetVirtualDiskChanges', $inParams, $null)
        $rv = [uint32]$out['ReturnValue']
        if ($rv -eq 4096 -and $out['Job']) {
            $job = Wait-HV2PVEManagementJob -Scope $scope -JobPath ([string]$out['Job']) -TimeoutSeconds $TimeoutSeconds
            $job.Get()
            throw 'GetVirtualDiskChanges completed asynchronously but output-array extraction from the job is not implemented. Use the native Hv2Pve.Rct query helper for this host.'
        } elseif ($rv -ne 0) {
            throw "GetVirtualDiskChanges failed with return value $rv"
        }

        $offsets = @($out['ChangedByteOffsets'])
        $lengths = @($out['ChangedByteLengths'])
        if ($offsets.Count -ne $lengths.Count) {
            throw 'GetVirtualDiskChanges returned mismatched offset/length arrays.'
        }
        for ($i = 0; $i -lt $offsets.Count; $i++) {
            $ranges.Add([pscustomobject]@{ Offset=[uint64]$offsets[$i]; Length=[uint64]$lengths[$i] })
        }
        $processed = [uint64]$out['ProcessedByteLength']
        if ($processed -eq 0) { break }
        $cursor += $processed
    }

    [pscustomobject]@{
        Path = $Path
        LimitId = $LimitId
        ByteOffset = $ByteOffset
        ByteLength = $ByteLength
        ProcessedThrough = $cursor
        Ranges = @($ranges)
        QueriedAtUtc = [DateTime]::UtcNow.ToString('o')
    }
}

Export-ModuleMember -Function @(
    'Get-HV2PVEVMInfo',
    'New-HV2PVEBaselineCheckpoint',
    'Export-HV2PVEBaseline',
    'Remove-HV2PVEBaselineCheckpoint',
    'New-HV2PVERctReferencePoint',
    'Get-HV2PVERctReferencePoint',
    'Export-HV2PVEReferencePoint',
    'Remove-HV2PVEReferencePoint',
    'Get-HV2PVERctDiskMap',
    'Get-HV2PVEVirtualDiskChanges',
    'Stop-HV2PVESourceForCutover'
)
