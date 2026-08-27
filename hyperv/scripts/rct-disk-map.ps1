[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$ReferencePointInstanceID,
    [string]$OutputPath
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '..\HyperV2PVE.psm1') -Force
$map = @(Get-HV2PVERctDiskMap -ReferencePointInstanceID $ReferencePointInstanceID)
$result = [ordered]@{
    reference_point_instance_id = $ReferencePointInstanceID
    disks = $map
    unresolved = @($map | Where-Object { -not $_.Resolved }).Count
    generated_at_utc = [DateTime]::UtcNow.ToString('o')
}
$json = $result | ConvertTo-Json -Depth 12
if ($OutputPath) { $json | Set-Content -LiteralPath $OutputPath -Encoding utf8 }
$json
