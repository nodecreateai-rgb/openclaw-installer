param(
  [Parameter(Mandatory = $true)]
  [string]$ContainerName,
  [Parameter(Mandatory = $true)]
  [string]$StateDir,
  [int]$SleepSeconds = 0
)

$ErrorActionPreference = 'Stop'

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

function Stop-PidFile {
  param([string]$PidFile)
  if (-not (Test-Path $PidFile)) {
    return
  }
  $rawPid = (Get-Content -Path $PidFile -Raw).Trim()
  if ($rawPid -match '^\d+$') {
    try {
      Stop-Process -Id ([int]$rawPid) -Force -ErrorAction Stop
    } catch {
    }
  }
  Remove-Item -Force -ErrorAction SilentlyContinue -Path $PidFile
}

function Clear-PidFileIfMatches {
  param([string]$PidFile)
  if (-not (Test-Path $PidFile)) {
    return
  }
  $rawPid = (Get-Content -Path $PidFile -Raw).Trim()
  if ($rawPid -eq [string]$PID) {
    Remove-Item -Force -ErrorAction SilentlyContinue -Path $PidFile
  }
}

New-Item -ItemType Directory -Force -Path $StateDir | Out-Null
if ($SleepSeconds -gt 0) {
  Start-Sleep -Seconds $SleepSeconds
}

$tenantManifest = Join-Path $StateDir 'tenant.json'
$tenantState = Read-JsonFile -Path $tenantManifest
$tenantDataDir = if ($tenantState -and $tenantState.dataDir) { [string]$tenantState.dataDir } else { '' }

if ($tenantDataDir) {
  New-Item -ItemType Directory -Force -Path $tenantDataDir | Out-Null
  New-Item -ItemType File -Force -Path (Join-Path $tenantDataDir 'TENANT_DISABLED') | Out-Null
} else {
  Add-Content -Path (Join-Path $StateDir 'expiry.log') -Value "tenant data dir missing in $tenantManifest"
}

$containerExists = $false
$containerRunning = $false
try {
  $inspect = (& docker inspect -f '{{.State.Running}}' $ContainerName 2>$null | Select-Object -First 1).Trim()
  if ($inspect) {
    $containerExists = $true
    $containerRunning = $inspect -eq 'true'
  }
} catch {
}

if ($containerRunning) {
  $disableCommand = 'touch /root/.openclaw/TENANT_DISABLED; pkill -x openclaw-gateway >/dev/null 2>&1 || true; pkill -x openclaw >/dev/null 2>&1 || true; pkill -f "openclaw gateway run" >/dev/null 2>&1 || true; pkill -f "node .*openclaw.*gateway" >/dev/null 2>&1 || true'
  try {
    & docker exec $ContainerName bash -lc $disableCommand *> $null
  } catch {
  }
} elseif ($containerExists) {
  Add-Content -Path (Join-Path $StateDir 'expiry.log') -Value "container not running during expiry: $ContainerName"
} else {
  Add-Content -Path (Join-Path $StateDir 'expiry.log') -Value "container not found during expiry: $ContainerName"
}

Stop-PidFile -PidFile (Join-Path $StateDir 'proxy.pid')
Clear-PidFileIfMatches -PidFile (Join-Path $StateDir 'expiry.pid')
$disabledAt = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
$disabledAt | Set-Content -Path (Join-Path $StateDir 'disabled-at') -Encoding UTF8
Add-Content -Path (Join-Path $StateDir 'expiry.log') -Value "disabled at $disabledAt"
