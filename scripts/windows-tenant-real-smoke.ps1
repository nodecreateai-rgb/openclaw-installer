param(
  [ValidateSet('custom', 'proxy')]
  [string]$Mode = 'custom',
  [ValidateSet('powershell', 'pwsh', 'cmd')]
  [string]$EntryPoint = 'powershell',
  [string]$RepoRoot = (Split-Path -Parent $PSScriptRoot),
  [string]$HomeRoot = '',
  [string]$TenantBaseUrl = '',
  [string]$TenantApiKey = '',
  [string]$TenantModel = 'gpt-5.4',
  [string]$HostBaseUrl = '',
  [string]$HostApiKey = '',
  [string]$HostModel = '',
  [string]$TenantFeishuAppId = '',
  [string]$TenantFeishuAppSecret = '',
  [int]$GatewayReadyTimeoutSeconds = 1800,
  [int]$ExpirySchtasksBufferSeconds = 5,
  [int]$ExpiryWaitSlackSeconds = 90,
  [switch]$SkipExpirySmoke,
  [switch]$KeepHomeRoot
)

$ErrorActionPreference = 'Stop'

function Log-Info {
  param([string]$Message)
  Write-Host "[windows-tenant-real-smoke] $Message"
}

function Fail {
  param([string]$Message)
  throw "[windows-tenant-real-smoke] $Message"
}

function Need-Command {
  param([string]$Name)
  if (-not (Get-Command $Name -ErrorAction SilentlyContinue)) {
    Fail "missing required command: $Name"
  }
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

function Test-IsWindows {
  return [System.Environment]::OSVersion.Platform -eq [System.PlatformID]::Win32NT
}

function Set-ProcessEnv {
  param(
    [hashtable]$Values,
    [hashtable]$Originals
  )
  foreach ($key in $Values.Keys) {
    if (-not $Originals.ContainsKey($key)) {
      $Originals[$key] = [System.Environment]::GetEnvironmentVariable($key, 'Process')
    }
    [System.Environment]::SetEnvironmentVariable($key, [string]$Values[$key], 'Process')
  }
}

function Restore-ProcessEnv {
  param([hashtable]$Originals)
  foreach ($key in $Originals.Keys) {
    [System.Environment]::SetEnvironmentVariable($key, $Originals[$key], 'Process')
  }
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
  return $raw | ConvertFrom-Json
}

function Stop-PidFile {
  param([string]$PidFile)
  if (-not (Test-Path $PidFile)) {
    return
  }
  $rawPid = (Get-Content -Path $PidFile -Raw).Trim()
  if ($rawPid -match '^\d+$') {
    try {
      Stop-Process -Id ([int]$rawPid) -Force -ErrorAction Stop
      Start-Sleep -Seconds 1
    } catch {
    }
  }
  Remove-Item -Force -ErrorAction SilentlyContinue -Path $PidFile
}

function Get-LatestTenantStateDir {
  param([string]$TenantStateRoot)
  if (-not (Test-Path $TenantStateRoot)) {
    Fail "tenant state root missing: $TenantStateRoot"
  }
  $dir = Get-ChildItem -Path $TenantStateRoot -Directory | Sort-Object Name | Select-Object -Last 1
  if (-not $dir) {
    Fail "no tenant state directory found under $TenantStateRoot"
  }
  return $dir.FullName
}

function Wait-ForPath {
  param(
    [string]$Path,
    [int]$TimeoutSeconds
  )
  $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
  while ((Get-Date) -lt $deadline) {
    if (Test-Path $Path) {
      return $true
    }
    Start-Sleep -Seconds 1
  }
  return $false
}

function Wait-ForExpiryDisable {
  param(
    [string]$StateDir,
    [string]$TenantDataDir,
    [int]$TimeoutSeconds
  )
  $disabledAtPath = Join-Path $StateDir 'disabled-at'
  $disabledFlagPath = Join-Path $TenantDataDir 'TENANT_DISABLED'
  $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
  while ((Get-Date) -lt $deadline) {
    if ((Test-Path $disabledAtPath) -and (Test-Path $disabledFlagPath)) {
      return $true
    }
    Start-Sleep -Seconds 1
  }
  return $false
}

function Wait-ForContainerDisabled {
  param(
    [string]$ContainerName,
    [int]$TimeoutSeconds
  )
  $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
  while ((Get-Date) -lt $deadline) {
    $hasDisableFlag = $false
    $gatewayStillHealthy = $false
    try {
      & docker exec $ContainerName test -f /root/.openclaw/TENANT_DISABLED *> $null
      $hasDisableFlag = $true
    } catch {
      $hasDisableFlag = $false
    }
    try {
      & docker exec $ContainerName openclaw gateway health *> $null
      $gatewayStillHealthy = $true
    } catch {
      $gatewayStillHealthy = $false
    }
    if ($hasDisableFlag -and (-not $gatewayStillHealthy)) {
      return $true
    }
    Start-Sleep -Seconds 1
  }
  return $false
}

function Test-ContainerExists {
  param([string]$ContainerName)
  try {
    & docker inspect $ContainerName *> $null
    return $true
  } catch {
    return $false
  }
}

function Get-ContainerRunning {
  param([string]$ContainerName)
  try {
    $running = (& docker inspect -f '{{.State.Running}}' $ContainerName 2>$null | Select-Object -First 1).Trim()
    return $running -eq 'true'
  } catch {
    return $false
  }
}

function Cleanup-TenantArtifacts {
  param(
    [string]$StateDir,
    [string]$ContainerName
  )
  if ([string]::IsNullOrWhiteSpace($StateDir)) {
    return
  }
  $expiryUnitPath = Join-Path $StateDir 'expiry.unit'
  if (Test-Path $expiryUnitPath) {
    $taskName = (Get-Content -Path $expiryUnitPath -Raw).Trim()
    if (-not [string]::IsNullOrWhiteSpace($taskName) -and (Get-Command schtasks.exe -ErrorAction SilentlyContinue)) {
      try {
        & schtasks.exe /Delete /TN $taskName /F *> $null
      } catch {
      }
    }
  }
  Stop-PidFile -PidFile (Join-Path $StateDir 'expiry.pid')
  Stop-PidFile -PidFile (Join-Path $StateDir 'proxy.pid')
  if (-not [string]::IsNullOrWhiteSpace($ContainerName) -and (Test-ContainerExists -ContainerName $ContainerName)) {
    try {
      & docker rm -f $ContainerName *> $null
    } catch {
    }
  }
}

function Invoke-InstallEntryPoint {
  param(
    [string]$EntryPoint,
    [string]$RepoRoot
  )
  $installPs1 = Join-Path $RepoRoot 'install.ps1'
  $installCmd = Join-Path $RepoRoot 'install.cmd'
  $exitCode = 0
  switch ($EntryPoint) {
    'powershell' {
      $exe = Resolve-PreferredCommand @('powershell.exe', 'powershell')
      if (-not $exe) { Fail 'powershell.exe not found' }
      & $exe -NoProfile -ExecutionPolicy Bypass -File $installPs1
      $exitCode = $LASTEXITCODE
      break
    }
    'pwsh' {
      $exe = Resolve-PreferredCommand @('pwsh.exe', 'pwsh')
      if (-not $exe) { Fail 'pwsh not found' }
      & $exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File $installPs1
      $exitCode = $LASTEXITCODE
      break
    }
    'cmd' {
      $exe = Resolve-PreferredCommand @('cmd.exe', 'cmd')
      if (-not $exe) { Fail 'cmd.exe not found' }
      & $exe /c $installCmd
      $exitCode = $LASTEXITCODE
      break
    }
  }
  if ($exitCode -ne 0) {
    Fail "install entrypoint $EntryPoint exited with code $exitCode"
  }
}

function Get-SchtasksExpirySeconds {
  param([int]$BufferSeconds)
  $now = Get-Date
  $secondsUntilNextMinute = 60 - $now.Second
  if ($secondsUntilNextMinute -le 0) {
    $secondsUntilNextMinute = 60
  }
  return $secondsUntilNextMinute + $BufferSeconds
}

if (-not (Test-IsWindows)) {
  Fail 'this smoke script must run on a real Windows host'
}

Need-Command docker
Need-Command schtasks.exe
Need-Command npm
Need-Command node

try {
  & docker compose version *> $null
} catch {
  Fail 'docker compose is not available'
}

if (-not (Test-Path (Join-Path $RepoRoot 'install.ps1'))) {
  Fail "repo root does not look valid: $RepoRoot"
}

$smokeHomeRoot = if ([string]::IsNullOrWhiteSpace($HomeRoot)) {
  Join-Path ([System.IO.Path]::GetTempPath()) ('openclaw-windows-tenant-smoke-' + [guid]::NewGuid().ToString('N'))
} else {
  $HomeRoot
}
$smokeHomeRoot = [System.IO.Path]::GetFullPath($smokeHomeRoot)
$smokeTempDir = Join-Path $smokeHomeRoot 'tmp'
$smokeAppData = Join-Path $smokeHomeRoot 'AppData\Roaming'
$smokeLocalAppData = Join-Path $smokeHomeRoot 'AppData\Local'
$smokeWorkspace = Join-Path $smokeHomeRoot '.openclaw'
$smokeConfigPath = Join-Path $smokeWorkspace 'openclaw.json'
$smokeNpmPrefix = Join-Path $smokeHomeRoot 'npm-global'
$smokeNpmCache = Join-Path $smokeLocalAppData 'npm-cache'
$smokePathValue = $smokeNpmPrefix
$currentPath = [System.Environment]::GetEnvironmentVariable('Path', 'Process')
if (-not [string]::IsNullOrWhiteSpace($currentPath)) {
  $smokePathValue = $smokeNpmPrefix + ';' + $currentPath
}
$homeDrive = [System.IO.Path]::GetPathRoot($smokeHomeRoot).TrimEnd('\')
$homePath = $smokeHomeRoot.Substring($homeDrive.Length)
if ([string]::IsNullOrWhiteSpace($homePath)) {
  $homePath = '\'
}
New-Item -ItemType Directory -Force -Path $smokeHomeRoot | Out-Null
foreach ($path in @($smokeTempDir, $smokeAppData, $smokeLocalAppData, $smokeWorkspace, $smokeNpmPrefix, $smokeNpmCache)) {
  New-Item -ItemType Directory -Force -Path $path | Out-Null
}

if ($Mode -eq 'custom') {
  if ([string]::IsNullOrWhiteSpace($TenantBaseUrl) -or [string]::IsNullOrWhiteSpace($TenantApiKey)) {
    Fail 'custom mode requires -TenantBaseUrl and -TenantApiKey'
  }
} else {
  if ([string]::IsNullOrWhiteSpace($HostBaseUrl) -or [string]::IsNullOrWhiteSpace($HostApiKey) -or [string]::IsNullOrWhiteSpace($HostModel)) {
    Fail 'proxy mode requires -HostBaseUrl, -HostApiKey, and -HostModel'
  }
}

$envBackup = @{}
$processEnv = @{
  HOME = $smokeHomeRoot
  USERPROFILE = $smokeHomeRoot
  HOMEDRIVE = $homeDrive
  HOMEPATH = $homePath
  APPDATA = $smokeAppData
  LOCALAPPDATA = $smokeLocalAppData
  TEMP = $smokeTempDir
  TMP = $smokeTempDir
  OPENCLAW_CONFIG_PATH = $smokeConfigPath
  OPENCLAW_WORKSPACE = $smokeWorkspace
  OPENCLAW_FORCE_NPM_INSTALL = '1'
  npm_config_prefix = $smokeNpmPrefix
  npm_config_cache = $smokeNpmCache
  Path = $smokePathValue
  INSTALL_MODE = 'tenant'
  TENANT_NONINTERACTIVE = '1'
  TENANT_PROXY_MODE = $Mode
  TENANT_DURATION_LABEL = '1h'
  TENANT_READY_TIMEOUT_SECONDS = [string]$GatewayReadyTimeoutSeconds
  TENANT_FEISHU_APP_ID = $TenantFeishuAppId
  TENANT_FEISHU_APP_SECRET = $TenantFeishuAppSecret
}

if ($Mode -eq 'custom') {
  $processEnv['TENANT_BASE_URL'] = $TenantBaseUrl
  $processEnv['TENANT_API_KEY'] = $TenantApiKey
  $processEnv['TENANT_MODEL'] = $TenantModel
} else {
  $processEnv['TENANT_HOST_BASE_URL'] = $HostBaseUrl
  $processEnv['TENANT_HOST_API_KEY'] = $HostApiKey
  $processEnv['TENANT_HOST_MODEL'] = $HostModel
}

Set-ProcessEnv -Values $processEnv -Originals $envBackup

$tenantState = $null
$tenantStateDir = ''

try {
  Log-Info "running install via $EntryPoint entrypoint in $Mode mode"
  Invoke-InstallEntryPoint -EntryPoint $EntryPoint -RepoRoot $RepoRoot

  $tenantStateRoot = Join-Path $smokeHomeRoot '.openclaw\tenant-state'
  $tenantStateDir = Get-LatestTenantStateDir -TenantStateRoot $tenantStateRoot
  $tenantJsonPath = Join-Path $tenantStateDir 'tenant.json'
  $tenantState = Read-JsonFile -Path $tenantJsonPath
  if (-not $tenantState) {
    Fail "tenant.json missing or invalid: $tenantJsonPath"
  }
  if (-not (Test-ContainerExists -ContainerName ([string]$tenantState.container))) {
    Fail "tenant container missing after install: $($tenantState.container)"
  }
  if (-not (Get-ContainerRunning -ContainerName ([string]$tenantState.container))) {
    Fail "tenant container is not running after install: $($tenantState.container)"
  }

  $summary = [ordered]@{
    entryPoint = $EntryPoint
    mode = $Mode
    homeRoot = $smokeHomeRoot
    appData = $smokeAppData
    localAppData = $smokeLocalAppData
    npmPrefix = $smokeNpmPrefix
    configPath = $smokeConfigPath
    workspace = $smokeWorkspace
    tenant = $tenantState.tenant
    shortUuid = $tenantState.shortUuid
    container = $tenantState.container
    gatewayPort = $tenantState.gatewayPort
    vncPort = $tenantState.vncPort
    expiryMode = $tenantState.expiryMode
    expiryUnit = $tenantState.expiryUnit
    tenantStateDir = $tenantStateDir
    tenantDataDir = [string]$tenantState.dataDir
  }
  $summary | ConvertTo-Json -Depth 8

  if (-not $SkipExpirySmoke) {
    $scheduleScript = Join-Path $RepoRoot 'scripts/tenant-schedule-expiry.ps1'
    $rescheduleSeconds = Get-SchtasksExpirySeconds -BufferSeconds $ExpirySchtasksBufferSeconds
    Log-Info "rescheduling expiry to ${rescheduleSeconds}s to exercise real schtasks path"
    & $scheduleScript -ContainerName ([string]$tenantState.container) -Seconds $rescheduleSeconds -StateDir $tenantStateDir

    $expiryModePath = Join-Path $tenantStateDir 'expiry.mode'
    $expiryUnitPath = Join-Path $tenantStateDir 'expiry.unit'
    if (-not (Wait-ForPath -Path $expiryModePath -TimeoutSeconds 15)) {
      Fail "expiry.mode not written after reschedule: $expiryModePath"
    }
    $expiryMode = (Get-Content -Path $expiryModePath -Raw).Trim()
    if ($expiryMode -ne 'windows-schtasks') {
      Fail "expected expiry.mode=windows-schtasks after reschedule, got: $expiryMode"
    }
    if (-not (Wait-ForPath -Path $expiryUnitPath -TimeoutSeconds 15)) {
      Fail "expiry.unit not written after schtasks schedule: $expiryUnitPath"
    }

    $expiryWaitSeconds = $rescheduleSeconds + $ExpiryWaitSlackSeconds
    Log-Info "waiting up to ${expiryWaitSeconds}s for tenant disable marker"
    if (-not (Wait-ForExpiryDisable -StateDir $tenantStateDir -TenantDataDir ([string]$tenantState.dataDir) -TimeoutSeconds $expiryWaitSeconds)) {
      Fail "tenant did not disable within ${expiryWaitSeconds}s after schtasks reschedule"
    }
    if (-not (Test-ContainerExists -ContainerName ([string]$tenantState.container))) {
      Fail "tenant container should still exist after expiry: $($tenantState.container)"
    }
    if (-not (Wait-ForContainerDisabled -ContainerName ([string]$tenantState.container) -TimeoutSeconds 30)) {
      Fail "tenant container did not reach disabled state within 30s after expiry"
    }
    Log-Info 'expiry smoke passed'
  }
} finally {
  Restore-ProcessEnv -Originals $envBackup
  if (-not $KeepHomeRoot) {
    Cleanup-TenantArtifacts -StateDir $tenantStateDir -ContainerName $(if ($tenantState) { [string]$tenantState.container } else { '' })
    Remove-Item -Recurse -Force -ErrorAction SilentlyContinue -Path $smokeHomeRoot
  } else {
    Log-Info "keeping smoke home root: $smokeHomeRoot"
  }
}
