param(
  [Parameter(Mandatory = $true, Position = 0)]
  [string]$TenantName
)

$ErrorActionPreference = 'Stop'

function Resolve-CommandPath {
  param([string[]]$Names)
  foreach ($name in $Names) {
    $cmd = Get-Command $name -ErrorAction SilentlyContinue
    if ($cmd) {
      return $cmd.Path
    }
  }
  return $null
}

function Read-JsonFile {
  param([string]$Path)
  if (-not (Test-Path $Path)) {
    return $null
  }
  $raw = Get-Content -Path $Path -Raw
  if ([string]::IsNullOrWhiteSpace($raw)) {
    return $null
  }
  try {
    return $raw | ConvertFrom-Json
  } catch {
    return $null
  }
}

function Write-JsonFile {
  param(
    [string]$Path,
    $Value
  )
  $parent = Split-Path -Parent $Path
  if ($parent) {
    New-Item -ItemType Directory -Force -Path $parent | Out-Null
  }
  $Value | ConvertTo-Json -Depth 20 | Set-Content -Path $Path -Encoding UTF8
}

function New-RandomPassword {
  param([int]$Length = 8)
  $alphabet = 'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789'.ToCharArray()
  $buffer = New-Object byte[] ($Length)
  [System.Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($buffer)
  $chars = New-Object System.Collections.Generic.List[string]
  for ($i = 0; $i -lt $Length; $i++) {
    $chars.Add([string]$alphabet[$buffer[$i] % $alphabet.Length]) | Out-Null
  }
  return (-join $chars)
}

function Get-DockerComposeMode {
  if (Get-Command 'docker' -ErrorAction SilentlyContinue) {
    try {
      & docker compose version *> $null
      return 'docker-compose-plugin'
    } catch {
    }
  }
  if (Get-Command 'docker-compose' -ErrorAction SilentlyContinue) {
    return 'docker-compose'
  }
  throw 'docker compose not available'
}

function Invoke-DockerCompose {
  param([string[]]$Arguments)
  switch (Get-DockerComposeMode) {
    'docker-compose-plugin' {
      & docker compose @Arguments
      return
    }
    'docker-compose' {
      & docker-compose @Arguments
      return
    }
  }
}

$scriptDir = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
$repoRoot = Split-Path -Parent $scriptDir
$tenantStateRoot = if ($env:DOPE_TENANT_STATE_ROOT) {
  $env:DOPE_TENANT_STATE_ROOT
} elseif ($env:OPENCLAW_TENANT_STATE_ROOT) {
  $env:OPENCLAW_TENANT_STATE_ROOT
} else {
  Join-Path $HOME '.openclaw/tenant-state'
}

$stateDir = Join-Path $tenantStateRoot $TenantName
$tenantJson = Join-Path $stateDir 'tenant.json'
if (-not (Test-Path $tenantJson)) {
  throw "tenant state missing: $tenantJson"
}

$tenantState = Read-JsonFile -Path $tenantJson
if (-not $tenantState) {
  throw "tenant state invalid: $tenantJson"
}

$containerName = [string]$tenantState.container
$tenantDataDir = [string]$tenantState.dataDir
$gatewayPort = [string]$tenantState.gatewayPort
$vncPort = [string]$tenantState.vncPort
$modelMode = if ($tenantState.modelMode) { [string]$tenantState.modelMode } else { 'custom' }
$vncPassword = if ($tenantState.vncPassword) { [string]$tenantState.vncPassword } else { '' }

if ([string]::IsNullOrWhiteSpace($containerName) -or [string]::IsNullOrWhiteSpace($tenantDataDir) -or [string]::IsNullOrWhiteSpace($gatewayPort) -or [string]::IsNullOrWhiteSpace($vncPort)) {
  throw "tenant.json missing required fields: $tenantJson"
}

if (-not (Test-Path (Join-Path $tenantDataDir 'TENANT_DISABLED'))) {
  throw 'tenant is not disabled; this helper only reconciles disabled tenants'
}

if ([string]::IsNullOrWhiteSpace($vncPassword)) {
  $vncPassword = New-RandomPassword -Length 8
}

$expiryModePath = Join-Path $stateDir 'expiry.mode'
$expiryUnitPath = Join-Path $stateDir 'expiry.unit'
$expiryMode = if (Test-Path $expiryModePath) { (Get-Content -Path $expiryModePath -Raw).Trim() } else { '' }
$expiryUnit = if (Test-Path $expiryUnitPath) { (Get-Content -Path $expiryUnitPath -Raw).Trim() } else { '' }

$tenantState.vncPassword = $vncPassword
if (-not [string]::IsNullOrWhiteSpace($expiryMode)) {
  $tenantState | Add-Member -NotePropertyName expiryMode -NotePropertyValue $expiryMode -Force
}
if (-not [string]::IsNullOrWhiteSpace($expiryUnit)) {
  $tenantState | Add-Member -NotePropertyName expiryUnit -NotePropertyValue $expiryUnit -Force
}
Write-JsonFile -Path $tenantJson -Value $tenantState

$openclawJson = Join-Path $tenantDataDir 'openclaw.json'
if (-not (Test-Path $openclawJson)) {
  throw "tenant config missing: $openclawJson"
}

$cfg = Read-JsonFile -Path $openclawJson
if (-not $cfg) {
  throw "tenant config invalid: $openclawJson"
}

$providers = if ($cfg.models -and $cfg.models.providers) { $cfg.models.providers } else { $null }
$provider = $null
if ($providers) {
  foreach ($prop in $providers.PSObject.Properties) {
    $provider = $prop.Value
    break
  }
}
$models = if ($provider -and $provider.models) { $provider.models } else { @() }
$tenantModel = ''
foreach ($model in @($models)) {
  if ($model -and $model.id) {
    $tenantModel = [string]$model.id
    break
  }
}
$feishu = if ($cfg.channels -and $cfg.channels.feishu) { $cfg.channels.feishu } else { $null }

$tenantAllowedOriginsJson = @(
  "http://localhost:$gatewayPort",
  "http://127.0.0.1:$gatewayPort",
  'http://localhost:18789',
  'http://127.0.0.1:18789'
) | ConvertTo-Json -Compress

$env:TENANT_CONTAINER_NAME = $containerName
$env:TENANT_GATEWAY_PORT = $gatewayPort
$env:TENANT_VNC_PORT = $vncPort
$env:TENANT_DATA_DIR = $tenantDataDir
$env:TENANT_BASE_URL = if ($provider -and $provider.baseUrl) { [string]$provider.baseUrl } else { '' }
$env:TENANT_API_KEY = if ($provider -and $provider.apiKey) { [string]$provider.apiKey } else { '' }
$env:TENANT_MODEL = $tenantModel
$env:TENANT_FEISHU_APP_ID = if ($feishu -and $feishu.appId) { [string]$feishu.appId } else { '' }
$env:TENANT_FEISHU_APP_SECRET = if ($feishu -and $feishu.appSecret) { [string]$feishu.appSecret } else { '' }
$env:TENANT_VNC_PASSWORD = $vncPassword
$env:TENANT_PROXY_MODE = $modelMode
$env:OPENCLAW_GATEWAY_BIND = 'lan'
$env:OPENCLAW_GATEWAY_ALLOWED_ORIGINS_JSON = $tenantAllowedOriginsJson
$env:OPENCLAW_GATEWAY_PORT = '18789'

$composeFile = Join-Path $repoRoot 'tenant-mode/docker-compose.yml'
Invoke-DockerCompose -Arguments @('-p', $TenantName, '-f', $composeFile, 'up', '-d', '--build', '--force-recreate')

@"
reconciled disabled tenant: $TenantName
container: $containerName
gateway port: $gatewayPort
vnc port: $vncPort
vnc password: $vncPassword
"@
