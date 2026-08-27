[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$DiskPath,
    [Parameter(Mandatory)][string]$RctId,
    [string]$OutputPath
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '..\HyperV2PVE.psm1') -Force
$result = Get-HV2PVEVirtualDiskChanges -Path $DiskPath -LimitId $RctId
$json = $result | ConvertTo-Json -Depth 12
if ($OutputPath) { $json | Set-Content -LiteralPath $OutputPath -Encoding utf8 }
$json
