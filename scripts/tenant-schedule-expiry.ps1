param(
  [Parameter(Mandatory = $true)]
  [string]$ContainerName,
  [Parameter(Mandatory = $true)]
  [int]$Seconds,
  [Parameter(Mandatory = $true)]
  [string]$StateDir
)

$ErrorActionPreference = 'Stop'

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

function Get-PowerShellCommand {
  $preferred = if ([System.Environment]::OSVersion.Platform -eq [System.PlatformID]::Win32NT) {
    @('powershell.exe', 'pwsh.exe', 'pwsh', 'powershell')
  } else {
    @('pwsh', 'powershell')
  }
  $resolved = Resolve-CommandPath $preferred
  if (-not $resolved) {
    throw 'missing required binary: powershell/pwsh'
  }
  return $resolved
}

function New-DetachedProcess {
  param(
    [string]$FilePath,
    [string[]]$ArgumentList,
    [string]$WorkingDirectory,
    [string]$StdOutPath,
    [string]$StdErrPath
  )
  $stdoutParent = Split-Path -Parent $StdOutPath
  if ($stdoutParent) {
    New-Item -ItemType Directory -Force -Path $stdoutParent | Out-Null
  }
  $stderrParent = Split-Path -Parent $StdErrPath
  if ($stderrParent) {
    New-Item -ItemType Directory -Force -Path $stderrParent | Out-Null
  }
  $args = @{
    FilePath = $FilePath
    ArgumentList = $ArgumentList
    PassThru = $true
    WorkingDirectory = $WorkingDirectory
    RedirectStandardOutput = $StdOutPath
    RedirectStandardError = $StdErrPath
  }
  if ([System.Environment]::OSVersion.Platform -eq [System.PlatformID]::Win32NT) {
    $args.WindowStyle = 'Hidden'
  }
  $proc = Start-Process @args
  return $proc.Id
}

function Get-SafeTaskKey {
  param([string]$Value)
  $safe = ($Value -replace '[^A-Za-z0-9]+', '-').Trim('-').ToLowerInvariant()
  if ([string]::IsNullOrWhiteSpace($safe)) {
    return 'tenant'
  }
  return $safe
}

if ($Seconds -lt 0) {
  throw "seconds must be >= 0: $Seconds"
}

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
New-Item -ItemType Directory -Force -Path $StateDir | Out-Null
"scheduled disable in ${Seconds}s for $ContainerName" | Set-Content -Path (Join-Path $StateDir 'expiry.log') -Encoding UTF8
Stop-PidFile -PidFile (Join-Path $StateDir 'expiry.pid')

$expiryModeFile = Join-Path $StateDir 'expiry.mode'
$expiryUnitFile = Join-Path $StateDir 'expiry.unit'
$existingTaskName = if (Test-Path $expiryUnitFile) { (Get-Content -Path $expiryUnitFile -Raw).Trim() } else { '' }

if ($existingTaskName -and (Get-Command schtasks.exe -ErrorAction SilentlyContinue)) {
  try {
    & schtasks.exe /Delete /TN $existingTaskName /F *> $null
  } catch {
  }
}
if (Test-Path $expiryUnitFile) { Remove-Item -Force -ErrorAction SilentlyContinue -Path $expiryUnitFile }
if (Test-Path $expiryModeFile) { Remove-Item -Force -ErrorAction SilentlyContinue -Path $expiryModeFile }

$expiryScript = Join-Path $scriptDir 'tenant-expire.ps1'
$powerShellExe = Get-PowerShellCommand

if (Get-Command schtasks.exe -ErrorAction SilentlyContinue) {
  $taskName = "OpenClaw-Tenant-Expire-$(Get-SafeTaskKey -Value $ContainerName)"
  $now = Get-Date
  $runAtExact = $now.AddSeconds($Seconds)
  $scheduledAt = Get-Date -Year $runAtExact.Year -Month $runAtExact.Month -Day $runAtExact.Day -Hour $runAtExact.Hour -Minute $runAtExact.Minute -Second 0
  if ($scheduledAt -gt $now) {
    # Prefer a slight delay over expiring the tenant early because schtasks only accepts minute precision.
    $taskSleepSeconds = [int][Math]::Max(0, [Math]::Ceiling(($runAtExact - $scheduledAt).TotalSeconds))
    $taskCommand = '"' + $powerShellExe + '" -NoProfile -ExecutionPolicy Bypass -File "' + $expiryScript + '" -ContainerName "' + $ContainerName + '" -StateDir "' + $StateDir + '" -SleepSeconds "' + $taskSleepSeconds + '"'
    try {
      & schtasks.exe /Create /SC ONCE /TN $taskName /TR $taskCommand /ST $scheduledAt.ToString('HH:mm') /SD $scheduledAt.ToString('MM/dd/yyyy') /F *> (Join-Path $StateDir 'expiry-schedule.log')
      'windows-schtasks' | Set-Content -Path $expiryModeFile -Encoding UTF8
      $taskName | Set-Content -Path $expiryUnitFile -Encoding UTF8
      exit 0
    } catch {
      Add-Content -Path (Join-Path $StateDir 'expiry.log') -Value 'schtasks create failed; falling back to background PowerShell'
    }
  } else {
    Add-Content -Path (Join-Path $StateDir 'expiry.log') -Value 'schtasks minute precision too coarse for requested delay; falling back to background PowerShell'
  }
}

$fallbackStdOut = Join-Path $StateDir 'expiry-run.stdout.log'
$fallbackStdErr = Join-Path $StateDir 'expiry-run.stderr.log'
$fallbackPid = New-DetachedProcess `
  -FilePath $powerShellExe `
  -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $expiryScript, '-ContainerName', $ContainerName, '-StateDir', $StateDir, '-SleepSeconds', [string]$Seconds) `
  -WorkingDirectory $scriptDir `
  -StdOutPath $fallbackStdOut `
  -StdErrPath $fallbackStdErr
$fallbackPid | Set-Content -Path (Join-Path $StateDir 'expiry.pid') -Encoding UTF8
'powershell-sleep-fallback' | Set-Content -Path $expiryModeFile -Encoding UTF8
