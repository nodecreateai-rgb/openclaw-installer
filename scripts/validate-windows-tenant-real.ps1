param(
  [string]$Mode = '',
  [string[]]$EntryPoints = @(),
  [string]$RepoRoot = (Split-Path -Parent $PSScriptRoot),
  [string]$HomeRoot = '',
  [string]$TenantBaseUrl = '',
  [string]$TenantApiKey = '',
  [string]$TenantModel = '',
  [string]$HostBaseUrl = '',
  [string]$HostApiKey = '',
  [string]$HostModel = '',
  [string]$TenantFeishuAppId = '',
  [string]$TenantFeishuAppSecret = '',
  [int]$GatewayReadyTimeoutSeconds = 0,
  [int]$ExpirySchtasksBufferSeconds = 0,
  [int]$ExpiryWaitSlackSeconds = 0,
  [switch]$SkipExpirySmoke,
  [switch]$KeepHomeRoot
)

$ErrorActionPreference = 'Stop'

function Log-Info {
  param([string]$Message)
  Write-Host "[validate-windows-tenant-real] $Message"
}

function Fail {
  param([string]$Message)
  throw "[validate-windows-tenant-real] $Message"
}

function Test-IsWindows {
  return [System.Environment]::OSVersion.Platform -eq [System.PlatformID]::Win32NT
}

function Test-Truthy {
  param([string]$Value)
  if ([string]::IsNullOrWhiteSpace($Value)) {
    return $false
  }
  return @('1', 'true', 'yes', 'on') -contains $Value.Trim().ToLowerInvariant()
}

function Resolve-StringValue {
  param(
    [string]$Explicit,
    [string]$EnvName,
    [string]$Default = ''
  )
  if (-not [string]::IsNullOrWhiteSpace($Explicit)) {
    return $Explicit
  }
  $envValue = [System.Environment]::GetEnvironmentVariable($EnvName, 'Process')
  if (-not [string]::IsNullOrWhiteSpace($envValue)) {
    return $envValue
  }
  return $Default
}

function Resolve-IntValue {
  param(
    [int]$Explicit,
    [string]$EnvName,
    [int]$Default
  )
  if ($Explicit -gt 0) {
    return $Explicit
  }
  $envValue = [System.Environment]::GetEnvironmentVariable($EnvName, 'Process')
  if (-not [string]::IsNullOrWhiteSpace($envValue)) {
    if ($envValue -match '^\d+$') {
      return [int]$envValue
    }
    Fail "invalid integer env value for ${EnvName}: $envValue"
  }
  return $Default
}

function Resolve-SwitchValue {
  param(
    [switch]$Explicit,
    [string]$EnvName
  )
  if ($Explicit.IsPresent) {
    return $true
  }
  return Test-Truthy ([System.Environment]::GetEnvironmentVariable($EnvName, 'Process'))
}

function Resolve-PreferredCommand {
  param([string[]]$Names)
  foreach ($name in $Names) {
    $cmd = Get-Command $name -ErrorAction SilentlyContinue
    if ($cmd) {
      return $cmd.Path
    }
  }
  return $null
}

function Test-EntryPointAvailable {
  param([string]$EntryPoint)
  switch ($EntryPoint) {
    'powershell' { return [bool](Resolve-PreferredCommand @('powershell.exe', 'powershell')) }
    'pwsh' { return [bool](Resolve-PreferredCommand @('pwsh.exe', 'pwsh')) }
    'cmd' { return [bool](Resolve-PreferredCommand @('cmd.exe', 'cmd')) }
  }
  return $false
}

function Resolve-EntryPoints {
  param([string[]]$Explicit)

  $rawValues = @()
  if ($Explicit.Count -gt 0) {
    $rawValues = $Explicit
  } else {
    $envValue = [System.Environment]::GetEnvironmentVariable('WINDOWS_TENANT_REAL_SMOKE_ENTRYPOINTS', 'Process')
    if (-not [string]::IsNullOrWhiteSpace($envValue)) {
      $rawValues = $envValue -split ','
    } else {
      $rawValues = @('powershell', 'pwsh', 'cmd')
    }
  }

  $resolved = @()
  foreach ($value in $rawValues) {
    $trimmed = ([string]$value).Trim().ToLowerInvariant()
    if ([string]::IsNullOrWhiteSpace($trimmed)) {
      continue
    }
    if (@('powershell', 'pwsh', 'cmd') -notcontains $trimmed) {
      Fail "unsupported entrypoint: $trimmed"
    }
    if (-not (Test-EntryPointAvailable -EntryPoint $trimmed)) {
      Fail "entrypoint is not available on this host: $trimmed"
    }
    if ($resolved -notcontains $trimmed) {
      $resolved += $trimmed
    }
  }

  if ($resolved.Count -eq 0) {
    Fail 'no supported Windows real smoke entrypoints are available on this host'
  }

  return $resolved
}

if (-not (Test-IsWindows)) {
  Fail 'this validation must run on a real Windows host'
}

$Mode = Resolve-StringValue -Explicit $Mode -EnvName 'WINDOWS_TENANT_REAL_SMOKE_MODE' -Default 'custom'
if (@('custom', 'proxy') -notcontains $Mode) {
  Fail "unsupported mode: $Mode"
}

$EntryPoints = Resolve-EntryPoints -Explicit $EntryPoints
$entryPointSummary = ($EntryPoints -join ',')
$entryPointSource = if ($PSBoundParameters.ContainsKey('EntryPoints') -or -not [string]::IsNullOrWhiteSpace([System.Environment]::GetEnvironmentVariable('WINDOWS_TENANT_REAL_SMOKE_ENTRYPOINTS', 'Process'))) {
  'explicit'
} else {
  'default'
}
$HomeRoot = Resolve-StringValue -Explicit $HomeRoot -EnvName 'WINDOWS_TENANT_REAL_SMOKE_HOME_ROOT'
$TenantBaseUrl = Resolve-StringValue -Explicit $TenantBaseUrl -EnvName 'WINDOWS_TENANT_REAL_SMOKE_BASE_URL'
$TenantApiKey = Resolve-StringValue -Explicit $TenantApiKey -EnvName 'WINDOWS_TENANT_REAL_SMOKE_API_KEY'
$TenantModel = Resolve-StringValue -Explicit $TenantModel -EnvName 'WINDOWS_TENANT_REAL_SMOKE_MODEL' -Default 'gpt-5.4'
$HostBaseUrl = Resolve-StringValue -Explicit $HostBaseUrl -EnvName 'WINDOWS_TENANT_REAL_SMOKE_HOST_BASE_URL'
$HostApiKey = Resolve-StringValue -Explicit $HostApiKey -EnvName 'WINDOWS_TENANT_REAL_SMOKE_HOST_API_KEY'
$HostModel = Resolve-StringValue -Explicit $HostModel -EnvName 'WINDOWS_TENANT_REAL_SMOKE_HOST_MODEL'
$TenantFeishuAppId = Resolve-StringValue -Explicit $TenantFeishuAppId -EnvName 'WINDOWS_TENANT_REAL_SMOKE_TENANT_FEISHU_APP_ID'
$TenantFeishuAppSecret = Resolve-StringValue -Explicit $TenantFeishuAppSecret -EnvName 'WINDOWS_TENANT_REAL_SMOKE_TENANT_FEISHU_APP_SECRET'
$GatewayReadyTimeoutSeconds = Resolve-IntValue -Explicit $GatewayReadyTimeoutSeconds -EnvName 'WINDOWS_TENANT_REAL_SMOKE_GATEWAY_READY_TIMEOUT_SECONDS' -Default 1800
$ExpirySchtasksBufferSeconds = Resolve-IntValue -Explicit $ExpirySchtasksBufferSeconds -EnvName 'WINDOWS_TENANT_REAL_SMOKE_EXPIRY_SCHTASKS_BUFFER_SECONDS' -Default 5
$ExpiryWaitSlackSeconds = Resolve-IntValue -Explicit $ExpiryWaitSlackSeconds -EnvName 'WINDOWS_TENANT_REAL_SMOKE_EXPIRY_WAIT_SLACK_SECONDS' -Default 90
$SkipExpirySmoke = Resolve-SwitchValue -Explicit $SkipExpirySmoke -EnvName 'WINDOWS_TENANT_REAL_SMOKE_SKIP_EXPIRY'
$KeepHomeRoot = Resolve-SwitchValue -Explicit $KeepHomeRoot -EnvName 'WINDOWS_TENANT_REAL_SMOKE_KEEP_HOME_ROOT'

if ($Mode -eq 'custom') {
  if ([string]::IsNullOrWhiteSpace($TenantBaseUrl) -or [string]::IsNullOrWhiteSpace($TenantApiKey)) {
    Fail 'custom mode requires TenantBaseUrl and TenantApiKey (or matching WINDOWS_TENANT_REAL_SMOKE_* env vars)'
  }
} else {
  if ([string]::IsNullOrWhiteSpace($HostBaseUrl) -or [string]::IsNullOrWhiteSpace($HostApiKey) -or [string]::IsNullOrWhiteSpace($HostModel)) {
    Fail 'proxy mode requires HostBaseUrl, HostApiKey, and HostModel (or matching WINDOWS_TENANT_REAL_SMOKE_* env vars)'
  }
}

$smokeScript = Join-Path $PSScriptRoot 'windows-tenant-real-smoke.ps1'
if (-not (Test-Path $smokeScript)) {
  Fail "smoke script missing: $smokeScript"
}

$results = @()
Log-Info "entrypoints ($entryPointSource): $entryPointSummary"
foreach ($entryPoint in $EntryPoints) {
  $childHomeRoot = ''
  if (-not [string]::IsNullOrWhiteSpace($HomeRoot)) {
    if ($EntryPoints.Count -gt 1) {
      $childHomeRoot = Join-Path $HomeRoot $entryPoint
    } else {
      $childHomeRoot = $HomeRoot
    }
  }

  $args = @(
    '-Mode', $Mode,
    '-EntryPoint', $entryPoint,
    '-RepoRoot', $RepoRoot,
    '-TenantModel', $TenantModel,
    '-GatewayReadyTimeoutSeconds', [string]$GatewayReadyTimeoutSeconds,
    '-ExpirySchtasksBufferSeconds', [string]$ExpirySchtasksBufferSeconds,
    '-ExpiryWaitSlackSeconds', [string]$ExpiryWaitSlackSeconds
  )

  if (-not [string]::IsNullOrWhiteSpace($childHomeRoot)) {
    $args += @('-HomeRoot', $childHomeRoot)
  }
  if (-not [string]::IsNullOrWhiteSpace($TenantFeishuAppId)) {
    $args += @('-TenantFeishuAppId', $TenantFeishuAppId)
  }
  if (-not [string]::IsNullOrWhiteSpace($TenantFeishuAppSecret)) {
    $args += @('-TenantFeishuAppSecret', $TenantFeishuAppSecret)
  }
  if ($SkipExpirySmoke) {
    $args += '-SkipExpirySmoke'
  }
  if ($KeepHomeRoot) {
    $args += '-KeepHomeRoot'
  }

  if ($Mode -eq 'custom') {
    $args += @('-TenantBaseUrl', $TenantBaseUrl, '-TenantApiKey', $TenantApiKey)
  } else {
    $args += @('-HostBaseUrl', $HostBaseUrl, '-HostApiKey', $HostApiKey, '-HostModel', $HostModel)
  }

  Log-Info "running smoke via $entryPoint"
  & $smokeScript @args

  $results += [pscustomobject]@{
    entryPoint = $entryPoint
    mode = $Mode
    homeRoot = $childHomeRoot
    status = 'passed'
  }
}

$results | ConvertTo-Json -Depth 5
