[CmdletBinding()]
param(
    [string]$Configuration = 'Release'
)
$ErrorActionPreference = 'Stop'
$project = Join-Path $PSScriptRoot '..\native\Hv2Pve.Rct\Hv2Pve.Rct.csproj'
if (-not (Get-Command dotnet -ErrorAction SilentlyContinue)) {
    throw '.NET 8 SDK is required to build the native RCT helper.'
}
dotnet build $project -c $Configuration
if ($LASTEXITCODE -ne 0) { throw "dotnet build failed with exit code $LASTEXITCODE" }
