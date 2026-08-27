[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$VMName,

    [string]$ComputerName = $env:COMPUTERNAME,

    [string]$NativeHelperPath,

    [string]$OutputPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$checks = [System.Collections.Generic.List[object]]::new()
$failures = 0
$warnings = 0

function Add-Check {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][ValidateSet('PASS','WARN','FAIL')][string]$Status,
        [Parameter(Mandatory)][string]$Detail
    )

    $script:checks.Add([pscustomobject]@{
        Name = $Name
        Status = $Status
        Detail = $Detail
    })

    if ($Status -eq 'FAIL') { $script:failures++ }
    if ($Status -eq 'WARN') { $script:warnings++ }
}

function Test-IsAdministrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

if (Test-IsAdministrator) {
    Add-Check -Name 'Administrator' -Status PASS -Detail 'PowerShell is elevated.'
}
else {
    Add-Check -Name 'Administrator' -Status FAIL -Detail 'Run PowerShell as Administrator.'
}

$os = Get-CimInstance Win32_OperatingSystem
$build = [int]$os.BuildNumber
if ($build -ge 14393) {
    Add-Check -Name 'Windows build' -Status PASS -Detail "$($os.Caption) build $build supports the Windows Server 2016 / Windows 10 generation of RCT APIs."
}
else {
    Add-Check -Name 'Windows build' -Status FAIL -Detail "$($os.Caption) build $build is older than the RCT API baseline (14393)."
}

$hyperVModule = Get-Module -ListAvailable -Name Hyper-V | Sort-Object Version -Descending | Select-Object -First 1
if ($hyperVModule) {
    Import-Module Hyper-V -ErrorAction Stop
    Add-Check -Name 'Hyper-V PowerShell module' -Status PASS -Detail "Version $($hyperVModule.Version) at $($hyperVModule.Path)"
}
else {
    Add-Check -Name 'Hyper-V PowerShell module' -Status FAIL -Detail 'Hyper-V PowerShell module is not installed.'
}

$vm = $null
if ($hyperVModule) {
    try {
        $vm = Get-VM -ComputerName $ComputerName -Name $VMName -ErrorAction Stop
        Add-Check -Name 'Source VM' -Status PASS -Detail "$ComputerName/$VMName state=$($vm.State) generation=$($vm.Generation)"
    }
    catch {
        Add-Check -Name 'Source VM' -Status FAIL -Detail $_.Exception.Message
    }
}

if ($vm) {
    $checkpointType = [string]$vm.CheckpointType
    if ($checkpointType -in @('Production','ProductionOnly')) {
        Add-Check -Name 'Checkpoint policy' -Status PASS -Detail "CheckpointType=$checkpointType"
    }
    else {
        Add-Check -Name 'Checkpoint policy' -Status FAIL -Detail "CheckpointType=$checkpointType. hv2pve requires Production or ProductionOnly for the baseline workflow."
    }

    $disks = @(Get-VMHardDiskDrive -ComputerName $ComputerName -VMName $VMName -ErrorAction Stop)
    if ($disks.Count -gt 0) {
        Add-Check -Name 'Attached virtual disks' -Status PASS -Detail "$($disks.Count) disk(s) discovered."
    }
    else {
        Add-Check -Name 'Attached virtual disks' -Status FAIL -Detail 'No VM hard disks were discovered.'
    }

    foreach ($disk in $disks) {
        if (-not $disk.Path) {
            Add-Check -Name "Disk path $($disk.ControllerType):$($disk.ControllerNumber):$($disk.ControllerLocation)" -Status FAIL -Detail 'Disk path is empty.'
            continue
        }

        $ext = [IO.Path]::GetExtension($disk.Path).ToLowerInvariant()
        if ($ext -eq '.vhdx') {
            Add-Check -Name "Disk $($disk.Path)" -Status PASS -Detail 'VHDX source disk.'
        }
        else {
            Add-Check -Name "Disk $($disk.Path)" -Status WARN -Detail "Extension '$ext' is not the normal VHDX RCT lab path. Validate this disk type explicitly before migration."
        }
    }

    $snapshots = @(Get-VMSnapshot -ComputerName $ComputerName -VMName $VMName -ErrorAction SilentlyContinue)
    if ($snapshots.Count -eq 0) {
        Add-Check -Name 'Existing checkpoints' -Status PASS -Detail 'No existing VM checkpoints.'
    }
    else {
        Add-Check -Name 'Existing checkpoints' -Status WARN -Detail "$($snapshots.Count) existing checkpoint(s). Record them and avoid ambiguous cleanup during the lab."
    }
}

try {
    $rpClass = Get-CimClass -Namespace 'root/virtualization/v2' -ClassName 'Msvm_VirtualSystemReferencePointService' -ComputerName $ComputerName -ErrorAction Stop
    if ($rpClass.CimClassMethods.ContainsKey('CreateReferencePoint')) {
        Add-Check -Name 'WMI CreateReferencePoint' -Status PASS -Detail 'Msvm_VirtualSystemReferencePointService.CreateReferencePoint is available.'
    }
    else {
        Add-Check -Name 'WMI CreateReferencePoint' -Status FAIL -Detail 'CreateReferencePoint method is missing.'
    }
}
catch {
    Add-Check -Name 'WMI CreateReferencePoint' -Status FAIL -Detail $_.Exception.Message
}

try {
    $imageClass = Get-CimClass -Namespace 'root/virtualization/v2' -ClassName 'Msvm_ImageManagementService' -ComputerName $ComputerName -ErrorAction Stop
    if ($imageClass.CimClassMethods.ContainsKey('GetVirtualDiskChanges')) {
        Add-Check -Name 'WMI GetVirtualDiskChanges' -Status PASS -Detail 'Msvm_ImageManagementService.GetVirtualDiskChanges is available.'
    }
    else {
        Add-Check -Name 'WMI GetVirtualDiskChanges' -Status FAIL -Detail 'GetVirtualDiskChanges method is missing.'
    }
}
catch {
    Add-Check -Name 'WMI GetVirtualDiskChanges' -Status FAIL -Detail $_.Exception.Message
}

if (-not $NativeHelperPath) {
    $NativeHelperPath = Join-Path $PSScriptRoot '..\..\native\Hv2Pve.Rct\bin\Release\net8.0-windows\Hv2Pve.Rct.exe'
}

if (Test-Path -LiteralPath $NativeHelperPath) {
    Add-Check -Name 'Native RCT helper' -Status PASS -Detail $NativeHelperPath
}
else {
    $dotnet = Get-Command dotnet -ErrorAction SilentlyContinue
    if ($dotnet) {
        Add-Check -Name 'Native RCT helper' -Status WARN -Detail "Helper is not built at '$NativeHelperPath', but dotnet is available at $($dotnet.Source). Build native/Hv2Pve.Rct first."
    }
    else {
        Add-Check -Name 'Native RCT helper' -Status WARN -Detail "Helper is not built at '$NativeHelperPath' and dotnet is not installed. WMI-path testing can still proceed."
    }
}

$result = [ordered]@{
    SchemaVersion = 1
    ComputerName = $ComputerName
    VMName = $VMName
    TimestampUtc = [DateTime]::UtcNow.ToString('o')
    Failures = $failures
    Warnings = $warnings
    Ready = ($failures -eq 0)
    Checks = @($checks)
}

$json = $result | ConvertTo-Json -Depth 8
$json

if ($OutputPath) {
    $parent = Split-Path -Parent $OutputPath
    if ($parent -and -not (Test-Path -LiteralPath $parent)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }
    $json | Set-Content -LiteralPath $OutputPath -Encoding utf8
}

if ($failures -gt 0) {
    exit 2
}
