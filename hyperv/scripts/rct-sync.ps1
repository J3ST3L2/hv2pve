[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)][string]$VMName,
    [Parameter(Mandatory)][string]$MigrationId,
    [Parameter(Mandatory)][string]$BaseReferencePointInstanceID,
    [Parameter(Mandatory)][string]$DestinationPath,
    [Parameter(Mandatory)][int]$Sequence,
    [ValidateSet('ApplicationConsistent','CrashConsistent')]
    [string]$Consistency = 'ApplicationConsistent',
    [string]$OutputPath
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '..\HyperV2PVE.psm1') -Force

$base = Get-HV2PVERctReferencePoint -InstanceID $BaseReferencePointInstanceID
$new = New-HV2PVERctReferencePoint -VMName $VMName -Consistency $Consistency -Confirm:$false
$syncRoot = Join-Path $DestinationPath ("sync-{0:D6}" -f $Sequence)
New-Item -ItemType Directory -Path $syncRoot -Force | Out-Null

try {
    $export = Export-HV2PVEReferencePoint `
        -ReferencePointInstanceID $new.InstanceID `
        -BaseReferencePointInstanceID $base.InstanceID `
        -DestinationPath $syncRoot `
        -Confirm:$false
} catch {
    Write-Warning "Sync export failed. New reference point $($new.InstanceID) has been intentionally preserved for diagnosis."
    throw
}

$result = [ordered]@{
    schema_version = 2
    migration_id = $MigrationId
    sequence = $Sequence
    vm_name = $VMName
    base_reference_point_instance_id = $base.InstanceID
    new_reference_point_instance_id = $new.InstanceID
    base_reference_point = $base
    new_reference_point = $new
    export = $export
    status = 'EXPORTED_PENDING_DESTINATION_APPLY'
    created_at_utc = [DateTime]::UtcNow.ToString('o')
    commit_rule = 'Do not destroy the base reference point until the destination has applied and verified this sync.'
}
$json = $result | ConvertTo-Json -Depth 24
if ($OutputPath) {
    $parent = Split-Path -Parent $OutputPath
    if ($parent -and -not (Test-Path -LiteralPath $parent)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
    $json | Set-Content -LiteralPath $OutputPath -Encoding utf8
}
$json
