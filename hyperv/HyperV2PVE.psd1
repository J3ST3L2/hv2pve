@{
    RootModule = 'HyperV2PVE.psm1'
    ModuleVersion = '0.2.0'
    GUID = '61673f80-6900-44fb-a1f1-fc70c1ba3188'
    Author = 'J3ST3L2'
    Description = 'Hyper-V source-side discovery, RCT reference point, baseline, synchronization and cutover helpers for hv2pve.'
    PowerShellVersion = '5.1'
    FunctionsToExport = @(
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
    CmdletsToExport = @()
    VariablesToExport = '*'
    AliasesToExport = @()
    PrivateData = @{
        PSData = @{
            Tags = @('Hyper-V','Proxmox','Migration','RCT')
            ProjectUri = 'https://github.com/J3ST3L2/hv2pve'
        }
    }
}
