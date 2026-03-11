param()

$ErrorActionPreference = 'Stop'
$Root = Split-Path -Parent $MyInvocation.MyCommand.Path
Set-Location $Root

$nativeInstaller = Join-Path $Root 'install-native.ps1'
if (-not (Test-Path $nativeInstaller)) {
  throw 'install-native.ps1 not found.'
}

Write-Host "Starting native installer on host..."
Write-Host ""

& $nativeInstaller
