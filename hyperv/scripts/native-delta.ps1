[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$FrozenDiskPath,
    [Parameter(Mandatory)][string]$RctId,
    [Parameter(Mandatory)][string]$MigrationId,
    [Parameter(Mandatory)][string]$DiskId,
    [Parameter(Mandatory)][uint64]$Sequence,
    [Parameter(Mandatory)][string]$ReferenceFrom,
    [Parameter(Mandatory)][string]$ReferenceTo,
    [Parameter(Mandatory)][string]$OutputDirectory,
    [string]$RctExecutable = (Join-Path $PSScriptRoot '..\..\native\Hv2Pve.Rct\bin\Release\net8.0-windows\Hv2Pve.Rct.exe')
)

$ErrorActionPreference = 'Stop'
if (-not (Test-Path -LiteralPath $RctExecutable)) { throw "RCT executable not found: $RctExecutable" }
if (-not (Test-Path -LiteralPath $FrozenDiskPath)) { throw "Frozen disk not found: $FrozenDiskPath" }
New-Item -ItemType Directory -Force -Path $OutputDirectory | Out-Null

$ranges = Join-Path $OutputDirectory 'ranges.json'
$payload = Join-Path $OutputDirectory 'delta.bin'
$metadata = Join-Path $OutputDirectory 'delta.json'

& $RctExecutable query --disk $FrozenDiskPath --rct-id $RctId --output $ranges
if ($LASTEXITCODE -ne 0) { throw "RCT query failed with exit code $LASTEXITCODE" }

$physical = (& $RctExecutable attach --disk $FrozenDiskPath | Select-Object -Last 1).Trim()
if ($LASTEXITCODE -ne 0 -or -not $physical) { throw 'Read-only VHD attach failed.' }
try {
    & $RctExecutable pack `
        --source-raw $physical `
        --ranges $ranges `
        --payload $payload `
        --metadata $metadata `
        --migration-id $MigrationId `
        --disk-id $DiskId `
        --sequence $Sequence `
        --reference-from $ReferenceFrom `
        --reference-to $ReferenceTo
    if ($LASTEXITCODE -ne 0) { throw "Delta pack failed with exit code $LASTEXITCODE" }
} finally {
    & $RctExecutable detach --disk $FrozenDiskPath | Out-Null
}

Get-Content -LiteralPath $metadata -Raw
