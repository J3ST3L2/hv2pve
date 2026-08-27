[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$DiskPath,
    [Parameter(Mandatory)][string]$RctId,
    [string]$NativeHelperPath,
    [string]$OutputPath,
    [uint64]$ByteOffset = 0,
    [uint64]$ByteLength = 0
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Merge-Ranges {
    param([Parameter(Mandatory)][object[]]$Ranges)

    $sorted = @($Ranges | ForEach-Object {
        [pscustomobject]@{
            Offset = [uint64]$(if ($_.PSObject.Properties.Name -contains 'Offset') { $_.Offset } else { $_.offset })
            Length = [uint64]$(if ($_.PSObject.Properties.Name -contains 'Length') { $_.Length } else { $_.length })
        }
    } | Sort-Object Offset, Length)

    $merged = [System.Collections.Generic.List[object]]::new()
    foreach ($range in $sorted) {
        if ($range.Length -eq 0) { continue }

        if ($merged.Count -eq 0) {
            $merged.Add([pscustomobject]@{ Offset=$range.Offset; Length=$range.Length })
            continue
        }

        $last = $merged[$merged.Count - 1]
        $lastEnd = [uint64]($last.Offset + $last.Length)
        $rangeEnd = [uint64]($range.Offset + $range.Length)

        if ($range.Offset -le $lastEnd) {
            if ($rangeEnd -gt $lastEnd) {
                $last.Length = [uint64]($rangeEnd - $last.Offset)
            }
        }
        else {
            $merged.Add([pscustomobject]@{ Offset=$range.Offset; Length=$range.Length })
        }
    }

    return @($merged)
}

function Get-TotalBytes {
    param([object[]]$Ranges)
    [uint64]$total = 0
    foreach ($range in $Ranges) { $total += [uint64]$range.Length }
    return $total
}

if (-not $NativeHelperPath) {
    $NativeHelperPath = Join-Path $PSScriptRoot '..\..\native\Hv2Pve.Rct\bin\Release\net8.0-windows\Hv2Pve.Rct.exe'
}

if (-not (Test-Path -LiteralPath $NativeHelperPath)) {
    throw "Native RCT helper not found: $NativeHelperPath"
}

if (-not (Test-Path -LiteralPath $DiskPath)) {
    throw "Disk not found: $DiskPath"
}

Import-Module (Join-Path $PSScriptRoot '..\HyperV2PVE.psm1') -Force

$wmi = Get-HV2PVEVirtualDiskChanges `
    -Path $DiskPath `
    -LimitId $RctId `
    -ByteOffset $ByteOffset `
    -ByteLength $ByteLength

$tempNative = Join-Path ([IO.Path]::GetTempPath()) ("hv2pve-rct-native-{0}.json" -f [guid]::NewGuid().ToString('N'))
try {
    & $NativeHelperPath query `
        --disk $DiskPath `
        --rct-id $RctId `
        --output $tempNative

    if ($LASTEXITCODE -ne 0) {
        throw "Native QueryChangesVirtualDisk helper failed with exit code $LASTEXITCODE"
    }

    $native = Get-Content -LiteralPath $tempNative -Raw | ConvertFrom-Json

    $wmiMerged = @(Merge-Ranges -Ranges @($wmi.Ranges))
    $nativeMerged = @(Merge-Ranges -Ranges @($native.ranges))

    $mismatches = [System.Collections.Generic.List[object]]::new()
    $max = [Math]::Max($wmiMerged.Count, $nativeMerged.Count)
    for ($i = 0; $i -lt $max; $i++) {
        $w = if ($i -lt $wmiMerged.Count) { $wmiMerged[$i] } else { $null }
        $n = if ($i -lt $nativeMerged.Count) { $nativeMerged[$i] } else { $null }

        if (-not $w -or -not $n -or $w.Offset -ne $n.Offset -or $w.Length -ne $n.Length) {
            $mismatches.Add([pscustomobject]@{
                Index = $i
                WmiOffset = if ($w) { $w.Offset } else { $null }
                WmiLength = if ($w) { $w.Length } else { $null }
                NativeOffset = if ($n) { $n.Offset } else { $null }
                NativeLength = if ($n) { $n.Length } else { $null }
            })
        }
    }

    $result = [ordered]@{
        SchemaVersion = 1
        DiskPath = (Resolve-Path -LiteralPath $DiskPath).Path
        RctId = $RctId
        ByteOffset = $wmi.ByteOffset
        ByteLength = $wmi.ByteLength
        VirtualSize = [uint64]$native.virtual_size
        WmiRawRangeCount = @($wmi.Ranges).Count
        NativeRawRangeCount = @($native.ranges).Count
        WmiMergedRangeCount = $wmiMerged.Count
        NativeMergedRangeCount = $nativeMerged.Count
        WmiChangedBytes = Get-TotalBytes -Ranges $wmiMerged
        NativeChangedBytes = Get-TotalBytes -Ranges $nativeMerged
        EquivalentCoverage = ($mismatches.Count -eq 0)
        WmiRanges = $wmiMerged
        NativeRanges = $nativeMerged
        Mismatches = @($mismatches)
        ComparedAtUtc = [DateTime]::UtcNow.ToString('o')
    }

    $json = $result | ConvertTo-Json -Depth 10
    $json

    if ($OutputPath) {
        $parent = Split-Path -Parent $OutputPath
        if ($parent -and -not (Test-Path -LiteralPath $parent)) {
            New-Item -ItemType Directory -Path $parent -Force | Out-Null
        }
        $json | Set-Content -LiteralPath $OutputPath -Encoding utf8
    }

    if ($mismatches.Count -ne 0) {
        Write-Error "WMI and native RCT range coverage differ. See Mismatches in the comparison output."
        exit 3
    }
}
finally {
    Remove-Item -LiteralPath $tempNative -Force -ErrorAction SilentlyContinue
}
