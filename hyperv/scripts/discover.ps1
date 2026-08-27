[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$VMName,
    [string]$ComputerName = $env:COMPUTERNAME,
    [string]$OutputPath
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '..\HyperV2PVE.psm1') -Force
$info = Get-HV2PVEVMInfo -VMName $VMName -ComputerName $ComputerName
$json = $info | ConvertTo-Json -Depth 16
if ($OutputPath) {
    $parent = Split-Path -Parent $OutputPath
    if ($parent -and -not (Test-Path -LiteralPath $parent)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
    $json | Set-Content -LiteralPath $OutputPath -Encoding utf8
}
$json
