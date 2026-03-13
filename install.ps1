param(
  [Parameter(ValueFromRemainingArguments = $true)]
  [string[]]$ForwardArgs
)

$ErrorActionPreference = 'Stop'

function Test-InstallerRepoRoot {
  param([string]$Path)
  if ([string]::IsNullOrWhiteSpace($Path)) {
    return $false
  }
  foreach ($entry in @('install-native.ps1', 'bundled-skills', 'app-proxy', 'tenant-mode', 'scripts')) {
    if (-not (Test-Path (Join-Path $Path $entry))) {
      return $false
    }
  }
  return $true
}

function Get-InstallerBootstrapBase {
  if ($env:OPENCLAW_INSTALLER_BOOTSTRAP_ROOT) {
    return $env:OPENCLAW_INSTALLER_BOOTSTRAP_ROOT
  }
  return Join-Path $HOME '.openclaw/installer-bundles'
}

$root = if ($PSScriptRoot) { $PSScriptRoot } elseif ($MyInvocation.MyCommand.Path) { Split-Path -Parent $MyInvocation.MyCommand.Path } else { '' }
$repoRoot = ''

if (Test-InstallerRepoRoot -Path $root) {
  $repoRoot = $root
} else {
  $archiveUrl = if ($env:OPENCLAW_INSTALLER_ARCHIVE_URL) { $env:OPENCLAW_INSTALLER_ARCHIVE_URL } else { 'https://github.com/nodecreateai-rgb/openclaw-installer/archive/refs/heads/main.zip' }
  $bootstrapBase = Get-InstallerBootstrapBase
  $bundleRoot = Join-Path $bootstrapBase ('bundle-' + [guid]::NewGuid().ToString('N'))
  $archivePath = Join-Path $bundleRoot 'installer.zip'
  New-Item -ItemType Directory -Force -Path $bundleRoot | Out-Null
  Write-Host "Downloading installer bundle from $archiveUrl ..."
  Write-Host "Keeping extracted installer bundle at $bundleRoot so tenant helper scripts remain available after install."
  Invoke-WebRequest -Uri $archiveUrl -OutFile $archivePath -UseBasicParsing
  Expand-Archive -Path $archivePath -DestinationPath $bundleRoot -Force
  Remove-Item -Force -ErrorAction SilentlyContinue -Path $archivePath
  $repoRoot = (Get-ChildItem -Path $bundleRoot -Directory | Where-Object { Test-InstallerRepoRoot -Path $_.FullName } | Select-Object -First 1).FullName
  if ([string]::IsNullOrWhiteSpace($repoRoot)) {
    throw "failed to locate install-native.ps1 in downloaded archive: $archiveUrl"
  }
}

$nativeInstaller = Join-Path $repoRoot 'install-native.ps1'
if (-not (Test-Path $nativeInstaller)) {
  throw "install-native.ps1 not found under $repoRoot"
}

Set-Location $repoRoot
Write-Host 'Starting native installer on host...'
Write-Host ''
& $nativeInstaller @ForwardArgs
