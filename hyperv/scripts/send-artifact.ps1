[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Path,
    [Parameter(Mandatory)][string]$DestinationHost,
    [string]$DestinationUser = 'ubuntu',
    [string]$DestinationPath = '/migrate/incoming',
    [string]$IdentityFile
)
$ErrorActionPreference = 'Stop'
$scp = Get-Command scp.exe -ErrorAction SilentlyContinue
if (-not $scp) { $scp = Get-Command scp -ErrorAction SilentlyContinue }
if (-not $scp) { throw 'OpenSSH scp is required for this transport helper.' }
$args = @('-r')
if ($IdentityFile) { $args += @('-i', $IdentityFile) }
$args += @($Path, "$DestinationUser@$DestinationHost`:$DestinationPath/")
& $scp.Source @args
if ($LASTEXITCODE -ne 0) { throw "scp failed with exit code $LASTEXITCODE" }
