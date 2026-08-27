@{
    RootModule        = 'HyperV2PVE.psm1'
    ModuleVersion     = '0.1.0'
    GUID              = 'b2c0f2e9-bca1-4d0f-a2da-9d18cc513f81'
    Author            = 'J3ST3L2'
    CompanyName       = 'Community'
    Copyright         = '(c) J3ST3L2. All rights reserved.'
    Description       = 'Hyper-V source-side operations for staged hv2pve migrations.'
    PowerShellVersion = '5.1'
    RequiredModules   = @('Hyper-V')
    FunctionsToExport = @(
        'Get-HV2PVEVMInfo',
        'New-HV2PVEBaselineCheckpoint',
        'Export-HV2PVEBaseline',
        'Remove-HV2PVEBaselineCheckpoint'
    )
    CmdletsToExport   = @()
    VariablesToExport = @()
    AliasesToExport   = @()
    PrivateData       = @{
        PSData = @{
            Tags = @('Hyper-V', 'Proxmox', 'Migration')
            ProjectUri = 'https://github.com/J3ST3L2/hv2pve'
        }
    }
}
