param(
  [Parameter(ValueFromRemainingArguments = $true)]
  [string[]]$InstallerArgs
)

$ErrorActionPreference = 'Stop'

$script:ConfigPath = if ($env:OPENCLAW_CONFIG_PATH) { $env:OPENCLAW_CONFIG_PATH } else { Join-Path $HOME '.openclaw/openclaw.json' }
$script:Workspace = if ($env:OPENCLAW_WORKSPACE) { $env:OPENCLAW_WORKSPACE } else { Join-Path $HOME '.openclaw' }
$script:Provider = 'default'
$script:Package = if ($env:OPENCLAW_NPM_PACKAGE) { $env:OPENCLAW_NPM_PACKAGE } else { 'openclaw@latest' }
$script:CodexPackage = if ($env:CODEX_NPM_PACKAGE) { $env:CODEX_NPM_PACKAGE } else { '@openai/codex@latest' }
$script:ForceNpmInstall = if ($env:OPENCLAW_FORCE_NPM_INSTALL) { @('1', 'true', 'yes', 'on') -contains $env:OPENCLAW_FORCE_NPM_INSTALL.ToLowerInvariant() } else { $false }
$script:ScriptDir = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
$script:BundledSkillsDir = if ($env:BUNDLED_SKILLS_DIR) { $env:BUNDLED_SKILLS_DIR } else { Join-Path $script:ScriptDir 'bundled-skills' }
$script:SkillsDir = Join-Path $HOME '.openclaw/skills'
$script:HooksDir = Join-Path $HOME '.openclaw/hooks'
$script:RuntimeDir = Join-Path $script:SkillsDir 'agile-codex/runtime'
$script:MonitorName = if ($env:AGILE_CODEX_MONITOR_NAME) { $env:AGILE_CODEX_MONITOR_NAME } else { 'Agile Codex progress monitor' }
$script:MonitorChannel = $env:AGILE_CODEX_MONITOR_CHANNEL
$script:MonitorTo = $env:AGILE_CODEX_MONITOR_TO
$script:MonitorAccount = $env:AGILE_CODEX_MONITOR_ACCOUNT
$script:FeishuPluginSpec = if ($env:FEISHU_PLUGIN_SPEC) { $env:FEISHU_PLUGIN_SPEC } else { '@m1heng-clawd/feishu' }
$script:InstallMode = $env:INSTALL_MODE
$script:TenantNonInteractive = if ($env:TENANT_NONINTERACTIVE) { $env:TENANT_NONINTERACTIVE } else { '0' }
$script:TenantProxyMode = $env:TENANT_PROXY_MODE
$script:TenantDurationLabel = $env:TENANT_DURATION_LABEL
$script:TenantDurationSeconds = $env:TENANT_DURATION_SECONDS
$script:TenantShortUuid = $env:TENANT_SHORT_UUID
$script:TenantBaseUrl = $env:TENANT_BASE_URL
$script:TenantApiKey = $env:TENANT_API_KEY
$script:TenantModel = $env:TENANT_MODEL
$script:TenantFeishuAppId = $env:TENANT_FEISHU_APP_ID
$script:TenantFeishuAppSecret = $env:TENANT_FEISHU_APP_SECRET
$script:TenantVncPassword = $env:TENANT_VNC_PASSWORD
$script:TenantHostBaseUrl = $env:TENANT_HOST_BASE_URL
$script:TenantHostApiKey = $env:TENANT_HOST_API_KEY
$script:TenantHostModel = $env:TENANT_HOST_MODEL
$script:TenantReadyTimeoutSeconds = if ($env:TENANT_READY_TIMEOUT_SECONDS) { [int]$env:TENANT_READY_TIMEOUT_SECONDS } else { 1800 }
$script:GatewayBind = $env:OPENCLAW_GATEWAY_BIND
$script:GatewayAllowedOriginsJson = $env:OPENCLAW_GATEWAY_ALLOWED_ORIGINS_JSON
$script:GatewayPort = if ($env:OPENCLAW_GATEWAY_PORT) { [int]$env:OPENCLAW_GATEWAY_PORT } else { 18789 }
$script:PythonCommand = $null
$script:DockerComposeMode = $null

function Test-IsWindows {
  return [System.Environment]::OSVersion.Platform -eq [System.PlatformID]::Win32NT
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

function Test-Command {
  param([string]$Name)
  return [bool](Get-Command $Name -ErrorAction SilentlyContinue)
}

function Need-Bin {
  param([string]$Name)
  if (-not (Test-Command $Name)) {
    throw "missing required binary: $Name"
  }
}

function Get-PythonCommand {
  if ($script:PythonCommand) {
    return $script:PythonCommand
  }
  $script:PythonCommand = Resolve-CommandPath @('python3', 'python')
  if (-not $script:PythonCommand) {
    throw 'missing required binary: python3/python'
  }
  return $script:PythonCommand
}

function Get-PowerShellCommand {
  $preferred = if (Test-IsWindows) { @('powershell.exe', 'pwsh.exe', 'pwsh', 'powershell') } else { @('pwsh', 'powershell') }
  $resolved = Resolve-CommandPath $preferred
  if (-not $resolved) {
    throw 'missing required binary: powershell/pwsh'
  }
  return $resolved
}

function ConvertTo-PlainObject {
  param([Parameter(ValueFromPipeline = $true)]$InputObject)
  process {
    if ($null -eq $InputObject) {
      return $null
    }
    if ($InputObject -is [System.Collections.IDictionary]) {
      $hash = @{}
      foreach ($key in $InputObject.Keys) {
        $hash[$key] = ConvertTo-PlainObject $InputObject[$key]
      }
      return $hash
    }
    if ($InputObject -is [System.Management.Automation.PSCustomObject]) {
      $hash = @{}
      foreach ($prop in $InputObject.PSObject.Properties) {
        $hash[$prop.Name] = ConvertTo-PlainObject $prop.Value
      }
      return $hash
    }
    if (($InputObject -is [System.Collections.IEnumerable]) -and -not ($InputObject -is [string])) {
      $items = @()
      foreach ($item in $InputObject) {
        $items += ,(ConvertTo-PlainObject $item)
      }
      return $items
    }
    return $InputObject
  }
}

function ConvertFrom-LooseJsonText {
  param([string]$Text)
  if ([string]::IsNullOrWhiteSpace($Text)) {
    return @{}
  }
  $candidate = $Text
  $start = $Text.IndexOf('{')
  $end = $Text.LastIndexOf('}')
  if ($start -ge 0 -and $end -ge $start) {
    $candidate = $Text.Substring($start, $end - $start + 1)
  }
  try {
    return ConvertTo-PlainObject ($candidate | ConvertFrom-Json)
  } catch {
    return @{}
  }
}

function Read-JsonFile {
  param(
    [string]$Path,
    $Default = @{}
  )
  if (-not (Test-Path $Path)) {
    return $Default
  }
  $raw = Get-Content -Path $Path -Raw
  if ([string]::IsNullOrWhiteSpace($raw)) {
    return $Default
  }
  try {
    return ConvertTo-PlainObject ($raw | ConvertFrom-Json)
  } catch {
    return $Default
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

function Ensure-Map {
  param(
    [hashtable]$Parent,
    [string]$Key
  )
  if (-not $Parent.ContainsKey($Key) -or -not ($Parent[$Key] -is [hashtable])) {
    $Parent[$Key] = @{}
  }
  return [hashtable]$Parent[$Key]
}

function Format-UtcTimestamp {
  param([datetime]$Value = (Get-Date))
  return $Value.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
}

function Get-CurrentValues {
  $baseUrl = ''
  $apiKey = ''
  $modelName = 'gpt-5.4'
  $cfg = Read-JsonFile -Path $script:ConfigPath -Default @{}
  if ($cfg.ContainsKey('models') -and $cfg['models'] -is [hashtable]) {
    $providers = $cfg['models']['providers']
    if ($providers -is [hashtable] -and $providers.ContainsKey($script:Provider) -and $providers[$script:Provider] -is [hashtable]) {
      $providerCfg = [hashtable]$providers[$script:Provider]
      if ($providerCfg.ContainsKey('baseUrl')) { $baseUrl = [string]$providerCfg['baseUrl'] }
      if ($providerCfg.ContainsKey('apiKey')) { $apiKey = [string]$providerCfg['apiKey'] }
      if ($providerCfg.ContainsKey('models') -and $providerCfg['models'] -is [System.Array] -and $providerCfg['models'].Count -gt 0) {
        $first = $providerCfg['models'][0]
        if ($first -is [hashtable] -and $first.ContainsKey('id') -and -not [string]::IsNullOrWhiteSpace([string]$first['id'])) {
          $modelName = [string]$first['id']
        }
      }
    }
  }
  return @{
    baseUrl = $baseUrl
    apiKey = $apiKey
    model = $modelName
  }
}

function Prompt-Value {
  param(
    [string]$Label,
    [string]$Default = ''
  )
  if ($script:TenantNonInteractive -eq '1') {
    return $Default
  }
  if ([string]::IsNullOrWhiteSpace($Default)) {
    return Read-Host $Label
  }
  $value = Read-Host "$Label [$Default]"
  if ([string]::IsNullOrWhiteSpace($value)) {
    return $Default
  }
  return $value
}

function Choose-InstallMode {
  if (-not [string]::IsNullOrWhiteSpace($script:InstallMode)) {
    return $script:InstallMode
  }
  $mode = Prompt-Value -Label '选择模式：网管(admin) / 租户(tenant)' -Default 'admin'
  switch ($mode) {
    'tenant' { return 'tenant' }
    '租户' { return 'tenant' }
    'admin' { return 'admin' }
    '网管' { return 'admin' }
    'guanli' { return 'admin' }
    default { return 'admin' }
  }
}

function Choose-TenantDuration {
  if (-not [string]::IsNullOrWhiteSpace($script:TenantDurationLabel)) {
    return $script:TenantDurationLabel
  }
  return Prompt-Value -Label '租户时长：1h / 2h / 5h / 1m（也支持 3h / 1d / 90min 等）' -Default '1h'
}

function Convert-TenantDurationToSeconds {
  param([string]$Label)
  if (-not [string]::IsNullOrWhiteSpace($script:TenantDurationSeconds)) {
    if ($script:TenantDurationSeconds -match '^\d+$' -and [int]$script:TenantDurationSeconds -gt 0) {
      return [int]$script:TenantDurationSeconds
    }
    throw "invalid TENANT_DURATION_SECONDS: $script:TenantDurationSeconds"
  }

  $normalized = $Label.Trim().ToLowerInvariant()
  $normalized = $normalized.Replace('个月', 'mo').Replace('月', 'mo').Replace('小时', 'h').Replace('分钟', 'min').Replace('分', 'min').Replace('秒钟', 's').Replace('秒', 's').Replace('天', 'd').Replace('周', 'w')
  $normalized = $normalized -replace '[\s,]+', ''
  if ([string]::IsNullOrWhiteSpace($normalized)) {
    throw 'duration is required'
  }

  switch ($normalized) {
    '1h' { return 3600 }
    '2h' { return 7200 }
    '5h' { return 18000 }
    '1m' { return 2592000 }
  }

  $unitSeconds = @{
    s = 1
    sec = 1
    secs = 1
    second = 1
    seconds = 1
    m = 60
    min = 60
    mins = 60
    minute = 60
    minutes = 60
    h = 3600
    hr = 3600
    hrs = 3600
    hour = 3600
    hours = 3600
    d = 86400
    day = 86400
    days = 86400
    w = 604800
    week = 604800
    weeks = 604800
    mo = 2592000
    mon = 2592000
    month = 2592000
    months = 2592000
  }

  $matches = [regex]::Matches($normalized, '(\d+)([a-z]+)')
  if ($matches.Count -eq 0) {
    throw "unsupported duration: $Label"
  }
  $reconstructed = -join ($matches | ForEach-Object { $_.Value })
  if ($reconstructed -ne $normalized) {
    throw "unsupported duration: $Label"
  }

  $total = 0
  foreach ($match in $matches) {
    $amount = [int]$match.Groups[1].Value
    $unit = $match.Groups[2].Value
    if ($amount -le 0) {
      throw "duration must be > 0: $Label"
    }
    if (-not $unitSeconds.ContainsKey($unit)) {
      throw "unsupported duration unit in: $Label"
    }
    $total += $amount * [int]$unitSeconds[$unit]
  }
  if ($total -le 0) {
    throw "duration must be > 0: $Label"
  }
  return $total
}

function Choose-TenantModelMode {
  if ($script:TenantProxyMode -eq 'proxy' -or $script:TenantProxyMode -eq 'custom') {
    return $script:TenantProxyMode
  }
  $mode = Prompt-Value -Label '租户模型来源：代理(proxy) / 自定义(custom)' -Default 'proxy'
  switch ($mode) {
    'custom' { return 'custom' }
    '自定义' { return 'custom' }
    'proxy' { return 'proxy' }
    '代理' { return 'proxy' }
    default { return 'proxy' }
  }
}

function Get-DockerComposeMode {
  if ($script:DockerComposeMode) {
    return $script:DockerComposeMode
  }
  if (Test-Command 'docker') {
    try {
      & docker compose version *> $null
      $script:DockerComposeMode = 'docker-compose-plugin'
      return $script:DockerComposeMode
    } catch {}
  }
  if (Test-Command 'docker-compose') {
    $script:DockerComposeMode = 'docker-compose'
    return $script:DockerComposeMode
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

function New-RandomHex {
  param([int]$Bytes = 4)
  $buffer = New-Object byte[] ($Bytes)
  [System.Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($buffer)
  return ([System.BitConverter]::ToString($buffer)).Replace('-', '').ToLowerInvariant()
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

function Find-FreePort {
  $listener = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, 0)
  $listener.Start()
  try {
    return ([System.Net.IPEndPoint]$listener.LocalEndpoint).Port
  } finally {
    $listener.Stop()
  }
}

function Wait-TcpPort {
  param(
    [string]$Address,
    [int]$Port,
    [int]$Attempts = 30,
    [int]$DelaySeconds = 1
  )
  for ($i = 0; $i -lt $Attempts; $i++) {
    $client = New-Object System.Net.Sockets.TcpClient
    try {
      $async = $client.BeginConnect($Address, $Port, $null, $null)
      if ($async.AsyncWaitHandle.WaitOne(1000, $false) -and $client.Connected) {
        $client.EndConnect($async)
        return $true
      }
    } catch {
    } finally {
      $client.Close()
    }
    Start-Sleep -Seconds $DelaySeconds
  }
  return $false
}

function New-DetachedProcess {
  param(
    [string]$FilePath,
    [string[]]$ArgumentList,
    [string]$WorkingDirectory,
    [string]$StdOutPath,
    [string]$StdErrPath
  )
  $parent = Split-Path -Parent $StdOutPath
  if ($parent) {
    New-Item -ItemType Directory -Force -Path $parent | Out-Null
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
  if (Test-IsWindows) {
    $args.WindowStyle = 'Hidden'
  }
  $proc = Start-Process @args
  return $proc.Id
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

function Show-LogTail {
  param([string[]]$Paths)
  foreach ($path in $Paths) {
    if (Test-Path $path) {
      Write-Host "== tail $path =="
      Get-Content -Path $path -Tail 80
    }
  }
}

function Convert-HostPathForDocker {
  param([string]$Path)
  $full = [System.IO.Path]::GetFullPath($Path)
  if (Test-IsWindows) {
    return $full -replace '\\', '/'
  }
  return $full
}

function Get-SafeTaskKey {
  param([string]$Value)
  $safe = ($Value -replace '[^A-Za-z0-9]+', '-').Trim('-').ToLowerInvariant()
  if ([string]::IsNullOrWhiteSpace($safe)) {
    return 'tenant'
  }
  return $safe
}

function Wait-Gateway {
  param(
    [int]$Attempts = 30,
    [int]$DelaySeconds = 2
  )
  for ($i = 0; $i -lt $Attempts; $i++) {
    try {
      openclaw gateway health *> $null
      return $true
    } catch {
      Start-Sleep -Seconds $DelaySeconds
    }
  }
  return $false
}

function Install-OpenClaw {
  if ((-not $script:ForceNpmInstall) -and (Test-Command 'openclaw')) {
    Write-Host "openclaw already installed:" (openclaw --version | Select-Object -First 1)
    return
  }
  Write-Host "installing $script:Package ..."
  npm install -g $script:Package
  Write-Host "installed:" (openclaw --version | Select-Object -First 1)
}

function Install-Codex {
  if ((-not $script:ForceNpmInstall) -and (Test-Command 'codex')) {
    Write-Host "codex already installed:" (codex --version | Select-Object -First 1)
    return
  }
  Write-Host "installing $script:CodexPackage ..."
  npm install -g $script:CodexPackage
  Write-Host "installed:" (codex --version | Select-Object -First 1)
}

function Bootstrap-IfMissing {
  $configDir = Split-Path -Parent $script:ConfigPath
  New-Item -ItemType Directory -Force -Path $configDir | Out-Null
  New-Item -ItemType Directory -Force -Path $script:Workspace | Out-Null
  New-Item -ItemType Directory -Force -Path $script:SkillsDir | Out-Null
  $workspaceMemoryDir = Join-Path $script:Workspace 'memory'
  New-Item -ItemType Directory -Force -Path $workspaceMemoryDir | Out-Null
  $workspaceMemoryFile = Join-Path $script:Workspace 'MEMORY.md'
  if (-not (Test-Path $workspaceMemoryFile)) {
    "# MEMORY.md`n`n## Long-term Memory`n`n" | Set-Content -Path $workspaceMemoryFile -Encoding UTF8
  }
  $today = (Get-Date).ToUniversalTime().ToString('yyyy-MM-dd')
  $yesterday = (Get-Date).ToUniversalTime().AddDays(-1).ToString('yyyy-MM-dd')
  foreach ($day in @($today, $yesterday)) {
    $dailyPath = Join-Path $workspaceMemoryDir ($day + '.md')
    if (-not (Test-Path $dailyPath)) {
      "# $day`n`n" | Set-Content -Path $dailyPath -Encoding UTF8
    }
  }

  if (-not (Test-Path $script:ConfigPath)) {
    $cfg = @{
      models = @{
        mode = 'merge'
        providers = @{
          default = @{
            baseUrl = ''
            apiKey = ''
            auth = 'api-key'
            api = 'openai-completions'
            authHeader = $true
            models = @(@{
              id = 'gpt-5.4'
              name = 'gpt-5.4'
              reasoning = $false
              input = @('text')
              cost = @{
                input = 0
                output = 0
                cacheRead = 0
                cacheWrite = 0
              }
              contextWindow = 200000
              maxTokens = 8192
              compat = @{
                maxTokensField = 'max_tokens'
              }
            })
          }
        }
      }
      agents = @{
        defaults = @{
          model = @{
            primary = 'default/gpt-5.4'
          }
          models = @{
            'default/gpt-5.4' = @{}
          }
          workspace = $script:Workspace
          compaction = @{
            mode = 'safeguard'
          }
          timeoutSeconds = 900
          maxConcurrent = 16
          subagents = @{
            maxConcurrent = 32
          }
        }
      }
      tools = @{
        profile = 'full'
      }
      messages = @{
        ackReactionScope = 'group-mentions'
      }
      commands = @{
        native = 'auto'
        nativeSkills = 'auto'
        restart = $true
        ownerDisplay = 'raw'
      }
      session = @{
        dmScope = 'per-channel-peer'
      }
      hooks = @{
        internal = @{
          enabled = $true
          entries = @{
            'boot-md' = @{ enabled = $true }
            'bootstrap-extra-files' = @{ enabled = $true }
            'command-logger' = @{ enabled = $true }
            'session-memory' = @{ enabled = $true }
          }
        }
      }
      gateway = @{
        port = 18789
        mode = 'local'
        bind = 'loopback'
        controlUi = @{
          allowedOrigins = @('http://localhost:18789', 'http://127.0.0.1:18789')
        }
        auth = @{
          mode = 'token'
          token = 'openclaw-local-token'
        }
        tailscale = @{
          mode = 'off'
          resetOnExit = $false
        }
        nodes = @{
          denyCommands = @('camera.snap', 'camera.clip', 'screen.record', 'contacts.add', 'calendar.add', 'reminders.add', 'sms.send')
        }
      }
    }
    Write-JsonFile -Path $script:ConfigPath -Value $cfg
    Write-Host "created default config: $script:ConfigPath"
  }
}

function Write-OpenClawConfig {
  param(
    [string]$BaseUrl,
    [string]$ApiKey,
    [string]$ModelName
  )
  $cfg = Read-JsonFile -Path $script:ConfigPath -Default @{}
  $models = Ensure-Map -Parent $cfg -Key 'models'
  $providers = Ensure-Map -Parent $models -Key 'providers'
  if (-not $providers.ContainsKey($script:Provider) -or -not ($providers[$script:Provider] -is [hashtable])) {
    $providers[$script:Provider] = @{}
  }
  $providerCfg = [hashtable]$providers[$script:Provider]

  $models['mode'] = 'merge'
  $models['providers'] = @{ ($script:Provider) = $providerCfg }
  $providerCfg['baseUrl'] = $BaseUrl
  $providerCfg['apiKey'] = $ApiKey
  $providerCfg['auth'] = 'api-key'
  $providerCfg['api'] = 'openai-completions'
  $providerCfg['authHeader'] = $true
  $providerCfg['models'] = @(@{
    id = $ModelName
    name = $ModelName
    reasoning = $false
    input = @('text')
    cost = @{
      input = 0
      output = 0
      cacheRead = 0
      cacheWrite = 0
    }
    contextWindow = 200000
    maxTokens = 8192
    compat = @{
      maxTokensField = 'max_tokens'
    }
  })

  $agents = Ensure-Map -Parent $cfg -Key 'agents'
  $defaults = Ensure-Map -Parent $agents -Key 'defaults'
  $agentModel = Ensure-Map -Parent $defaults -Key 'model'
  $agentModel['primary'] = "$script:Provider/$ModelName"
  $defaults['models'] = @{ ("$script:Provider/$ModelName") = @{} }
  $defaults['workspace'] = $script:Workspace
  $defaults['compaction'] = @{ mode = 'safeguard' }
  $defaults['timeoutSeconds'] = 900
  $defaults['maxConcurrent'] = 16
  $defaults['subagents'] = @{ maxConcurrent = 32 }

  (Ensure-Map -Parent $cfg -Key 'tools')['profile'] = 'full'
  (Ensure-Map -Parent $cfg -Key 'messages')['ackReactionScope'] = 'group-mentions'
  $commands = Ensure-Map -Parent $cfg -Key 'commands'
  $commands['native'] = 'auto'
  $commands['nativeSkills'] = 'auto'
  $commands['restart'] = $true
  $commands['ownerDisplay'] = 'raw'
  (Ensure-Map -Parent $cfg -Key 'session')['dmScope'] = 'per-channel-peer'

  $hooks = Ensure-Map -Parent (Ensure-Map -Parent $cfg -Key 'hooks') -Key 'internal'
  $hooks['enabled'] = $true
  $hookEntries = Ensure-Map -Parent $hooks -Key 'entries'
  foreach ($name in @('boot-md', 'bootstrap-extra-files', 'command-logger', 'session-memory')) {
    (Ensure-Map -Parent $hookEntries -Key $name)['enabled'] = $true
  }
  $memoryHook = Ensure-Map -Parent $hookEntries -Key 'memory-preload-bundle'
  $memoryHook['enabled'] = $true
  if (-not $memoryHook.ContainsKey('memoryDbPath') -or [string]::IsNullOrWhiteSpace([string]$memoryHook['memoryDbPath'])) {
    $memoryHook['memoryDbPath'] = (Join-Path $script:Workspace 'skills/local-long-memory/data/memory.db')
  }
  if (-not $memoryHook.ContainsKey('recentMessages')) { $memoryHook['recentMessages'] = 4 }
  if (-not $memoryHook.ContainsKey('sessionItems')) { $memoryHook['sessionItems'] = 6 }
  if (-not $memoryHook.ContainsKey('taskItems')) { $memoryHook['taskItems'] = 8 }
  if (-not $memoryHook.ContainsKey('searchItems')) { $memoryHook['searchItems'] = 6 }
  if (-not $memoryHook.ContainsKey('maxTaskIds')) { $memoryHook['maxTaskIds'] = 3 }
  if (-not $memoryHook.ContainsKey('maxChars')) { $memoryHook['maxChars'] = 4000 }
  if (-not $memoryHook.ContainsKey('dmOnly')) { $memoryHook['dmOnly'] = $true }
  $memoryAutoCapture = Ensure-Map -Parent $hookEntries -Key 'memory-auto-capture'
  $memoryAutoCapture['enabled'] = $true
  if (-not $memoryAutoCapture.ContainsKey('memoryDbPath') -or [string]::IsNullOrWhiteSpace([string]$memoryAutoCapture['memoryDbPath'])) {
    $memoryAutoCapture['memoryDbPath'] = (Join-Path $script:Workspace 'skills/local-long-memory/data/memory.db')
  }
  if (-not $memoryAutoCapture.ContainsKey('memoryScriptPath') -or [string]::IsNullOrWhiteSpace([string]$memoryAutoCapture['memoryScriptPath'])) {
    $memoryAutoCapture['memoryScriptPath'] = (Join-Path $script:Workspace 'skills/local-long-memory/scripts/memory_core.py')
  }
  if (-not $memoryAutoCapture.ContainsKey('dmOnly')) { $memoryAutoCapture['dmOnly'] = $true }
  if (-not $memoryAutoCapture.ContainsKey('maxTextLength')) { $memoryAutoCapture['maxTextLength'] = 1200 }
  if (-not $memoryAutoCapture.ContainsKey('allowSummaryOnCompact')) { $memoryAutoCapture['allowSummaryOnCompact'] = $true }
  if (-not $memoryAutoCapture.ContainsKey('dedupeWindowSec')) { $memoryAutoCapture['dedupeWindowSec'] = 21600 }
  if (-not $memoryAutoCapture.ContainsKey('maxTaskCandidates')) { $memoryAutoCapture['maxTaskCandidates'] = 5 }

  $skills = Ensure-Map -Parent (Ensure-Map -Parent $cfg -Key 'skills') -Key 'entries'
  (Ensure-Map -Parent $skills -Key 'using-superpowers')['enabled'] = $true
  (Ensure-Map -Parent $skills -Key 'agile-codex')['enabled'] = $true
  (Ensure-Map -Parent $skills -Key 'browser-use')['enabled'] = $true
  (Ensure-Map -Parent $skills -Key 'local-long-memory')['enabled'] = $true

  $gatewayBind = if ($script:GatewayBind) { $script:GatewayBind } else { 'loopback' }
  $gatewayPort = $script:GatewayPort
  $allowedOrigins = @()
  if (-not [string]::IsNullOrWhiteSpace($script:GatewayAllowedOriginsJson)) {
    try {
      $allowedOrigins = @($script:GatewayAllowedOriginsJson | ConvertFrom-Json)
    } catch {
      $allowedOrigins = @()
    }
  }
  if ($allowedOrigins.Count -eq 0) {
    $allowedOrigins = @("http://localhost:$gatewayPort", "http://127.0.0.1:$gatewayPort")
  }

  $gateway = Ensure-Map -Parent $cfg -Key 'gateway'
  $gateway['port'] = $gatewayPort
  $gateway['mode'] = 'local'
  $gateway['bind'] = $gatewayBind
  (Ensure-Map -Parent $gateway -Key 'controlUi')['allowedOrigins'] = $allowedOrigins
  $gatewayAuth = Ensure-Map -Parent $gateway -Key 'auth'
  $gatewayAuth['mode'] = 'token'
  if (-not $gatewayAuth.ContainsKey('token') -or [string]::IsNullOrWhiteSpace([string]$gatewayAuth['token'])) {
    $gatewayAuth['token'] = 'openclaw-local-token'
  }
  $gatewayTailscale = Ensure-Map -Parent $gateway -Key 'tailscale'
  $gatewayTailscale['mode'] = 'off'
  if (-not $gatewayTailscale.ContainsKey('resetOnExit')) {
    $gatewayTailscale['resetOnExit'] = $false
  }
  (Ensure-Map -Parent $gateway -Key 'nodes')['denyCommands'] = @('camera.snap', 'camera.clip', 'screen.record', 'contacts.add', 'calendar.add', 'reminders.add', 'sms.send')

  $plugins = Ensure-Map -Parent $cfg -Key 'plugins'
  $pluginEntries = Ensure-Map -Parent $plugins -Key 'entries'
  $null = $pluginEntries.Remove('paco-global-skills')
  if ($plugins.ContainsKey('load') -and $plugins['load'] -is [hashtable]) {
    $null = $plugins['load'].Remove('paths')
  }
  $allowList = @()
  if ($plugins.ContainsKey('allow') -and $plugins['allow'] -is [System.Array]) {
    $allowList = @($plugins['allow'] | Where-Object { $_ -ne 'paco-global-skills' })
  }
  if ($allowList -notcontains 'feishu') {
    $allowList += 'feishu'
  }
  $plugins['allow'] = $allowList

  Write-JsonFile -Path $script:ConfigPath -Value $cfg
  Write-Host "updated $script:ConfigPath"
  @{
    provider = $script:Provider
    baseUrl = $BaseUrl
    model = $ModelName
    primary = "$script:Provider/$ModelName"
    workspace = $script:Workspace
  } | ConvertTo-Json -Depth 5
}

function Write-CodexConfig {
  param(
    [string]$BaseUrl,
    [string]$ApiKey,
    [string]$ModelName
  )
  New-Item -ItemType Directory -Force -Path (Join-Path $HOME '.codex') | Out-Null
  @"
model = "$ModelName"
model_provider = "custom"

[model_providers.custom]
name = "Custom OpenAI-Compatible"
base_url = "$BaseUrl"
wire_api = "responses"
experimental_bearer_token = "$ApiKey"
"@ | Set-Content -Path (Join-Path $HOME '.codex/config.toml') -Encoding UTF8
  Write-Host "updated $(Join-Path $HOME '.codex/config.toml')"
}

function Install-LocalSkills {
  $using = Join-Path $script:BundledSkillsDir 'using-superpowers'
  $agile = Join-Path $script:BundledSkillsDir 'agile-codex'
  $browser = Join-Path $script:BundledSkillsDir 'browser-use'
  $memory = Join-Path $script:BundledSkillsDir 'local-long-memory'
  if (-not (Test-Path $using) -or -not (Test-Path $agile) -or -not (Test-Path $browser) -or -not (Test-Path $memory)) {
    throw "missing bundled skills under $script:BundledSkillsDir"
  }
  New-Item -ItemType Directory -Force -Path $script:SkillsDir | Out-Null
  foreach ($skill in @('using-superpowers', 'agile-codex', 'browser-use', 'local-long-memory')) {
    $target = Join-Path $script:SkillsDir $skill
    if (Test-Path $target) {
      Remove-Item -Recurse -Force -Path $target
    }
  }
  Copy-Item -Recurse -Force -Path $using -Destination (Join-Path $script:SkillsDir 'using-superpowers')
  Copy-Item -Recurse -Force -Path $agile -Destination (Join-Path $script:SkillsDir 'agile-codex')
  Copy-Item -Recurse -Force -Path $browser -Destination (Join-Path $script:SkillsDir 'browser-use')
  Copy-Item -Recurse -Force -Path $memory -Destination (Join-Path $script:SkillsDir 'local-long-memory')
  New-Item -ItemType Directory -Force -Path $script:HooksDir | Out-Null
  $memoryHookDir = Join-Path $script:BundledSkillsDir 'local-long-memory/hooks/memory-preload-bundle'
  $targetMemoryHookDir = Join-Path $script:HooksDir 'memory-preload-bundle'
  if (Test-Path $targetMemoryHookDir) {
    Remove-Item -Recurse -Force -Path $targetMemoryHookDir
  }
  if (Test-Path $memoryHookDir) {
    Copy-Item -Recurse -Force -Path $memoryHookDir -Destination $targetMemoryHookDir
  }
  $memoryAutoCaptureHookDir = Join-Path $script:BundledSkillsDir 'local-long-memory/hooks/memory-auto-capture'
  $targetMemoryAutoCaptureHookDir = Join-Path $script:HooksDir 'memory-auto-capture'
  if (Test-Path $targetMemoryAutoCaptureHookDir) {
    Remove-Item -Recurse -Force -Path $targetMemoryAutoCaptureHookDir
  }
  if (Test-Path $memoryAutoCaptureHookDir) {
    Copy-Item -Recurse -Force -Path $memoryAutoCaptureHookDir -Destination $targetMemoryAutoCaptureHookDir
  }
}

function Write-BrowserUseSkillConfig {
  param(
    [string]$BaseUrl,
    [string]$ApiKey,
    [string]$ModelName
  )
  $browserSkillDir = Join-Path $script:SkillsDir 'browser-use'
  $browserRuntimeDir = Join-Path $browserSkillDir 'runtime'
  $browserConfigFile = Join-Path $browserRuntimeDir 'config.json'
  if (-not (Test-Path $browserSkillDir)) {
    throw "browser-use skill directory missing: $browserSkillDir"
  }
  New-Item -ItemType Directory -Force -Path $browserRuntimeDir | Out-Null
  @{
    provider = 'default'
    baseUrl = $BaseUrl
    apiKey = $ApiKey
    model = $ModelName
    headful = $true
    resolution = @{ width = 1920; height = 1080 }
  } | ConvertTo-Json -Depth 10 | Set-Content -Path $browserConfigFile -Encoding UTF8
}

function Install-FeishuPluginAndConfig {
  $npmRoot = ''
  try {
    $npmRoot = (& npm root -g | Select-Object -First 1).Trim()
  } catch {
    $npmRoot = ''
  }
  $bundledFeishu = if ($npmRoot) { Join-Path $npmRoot 'openclaw/extensions/feishu/openclaw.plugin.json' } else { '' }

  if ($bundledFeishu -and (Test-Path $bundledFeishu)) {
    Write-Host 'Feishu plugin already bundled with current OpenClaw installation; skipping npm install'
  } else {
    Write-Host "installing Feishu plugin: $script:FeishuPluginSpec"
    openclaw plugins install $script:FeishuPluginSpec | Out-Null
  }

  $cfgNow = Read-JsonFile -Path $script:ConfigPath -Default @{}
  $currentAppId = ''
  $currentAppSecret = ''
  if ($cfgNow.ContainsKey('channels') -and $cfgNow['channels'] -is [hashtable]) {
    $feishu = $cfgNow['channels']['feishu']
    if ($feishu -is [hashtable]) {
      if ($feishu.ContainsKey('appId')) { $currentAppId = [string]$feishu['appId'] }
      if ($feishu.ContainsKey('appSecret')) { $currentAppSecret = [string]$feishu['appSecret'] }
    }
  }

  if ($script:TenantNonInteractive -eq '1') {
    $feishuAppId = $script:TenantFeishuAppId
    $feishuAppSecret = $script:TenantFeishuAppSecret
  } else {
    $feishuAppId = Prompt-Value -Label 'Feishu appId' -Default $currentAppId
    $feishuAppSecret = Prompt-Value -Label 'Feishu appSecret' -Default $currentAppSecret
  }

  openclaw config set channels.feishu.appId ('"' + $feishuAppId + '"') | Out-Null
  openclaw config set channels.feishu.appSecret ('"' + $feishuAppSecret + '"') | Out-Null
  openclaw config set channels.feishu.enabled true --strict-json | Out-Null

  $cfgAfter = Read-JsonFile -Path $script:ConfigPath -Default @{}
  $channels = Ensure-Map -Parent $cfgAfter -Key 'channels'
  $feishuChannel = Ensure-Map -Parent $channels -Key 'feishu'
  $feishuChannel['dmPolicy'] = 'open'
  $feishuChannel['allowFrom'] = @('*')
  Write-JsonFile -Path $script:ConfigPath -Value $cfgAfter
}

function Run-DoctorFix {
  openclaw doctor --fix *> (Join-Path $env:TEMP 'openclaw-doctor-fix.log')
}

function Restart-GatewayAfterFeishuConfig {
  try {
    openclaw gateway restart *> (Join-Path $env:TEMP 'openclaw-gateway-restart.log')
    if (Wait-Gateway -Attempts 20 -DelaySeconds 2) {
      return
    }
  } catch {
  }

  $runStdOut = Join-Path $env:TEMP 'openclaw-gateway-run.stdout.log'
  $runStdErr = Join-Path $env:TEMP 'openclaw-gateway-run.stderr.log'
  $procId = New-DetachedProcess -FilePath 'openclaw' -ArgumentList @('gateway', 'run') -WorkingDirectory $script:ScriptDir -StdOutPath $runStdOut -StdErrPath $runStdErr
  $procId | Set-Content -Path (Join-Path $env:TEMP 'openclaw-gateway-run.pid') -Encoding UTF8
  if (-not (Wait-Gateway -Attempts 30 -DelaySeconds 2)) {
    throw 'failed to restart gateway after feishu config'
  }
}

function Write-PlatformInfo {
  New-Item -ItemType Directory -Force -Path $script:RuntimeDir | Out-Null
  $hasTmux = [bool](Get-Command tmux -ErrorAction SilentlyContinue)
  $hasJq = [bool](Get-Command jq -ErrorAction SilentlyContinue)
  $hasWsl = [bool](Get-Command wsl.exe -ErrorAction SilentlyContinue) -or [bool](Get-Command wsl -ErrorAction SilentlyContinue)
  $backend = 'process'
  if ($hasWsl) {
    $backend = 'wsl'
  } elseif ($hasTmux) {
    $backend = 'tmux'
  }
  @{
    backend = $backend
    has_tmux = $hasTmux
    has_jq = $hasJq
    has_wsl = $hasWsl
    host_os = if (Test-IsWindows) { 'Windows' } else { [System.Environment]::OSVersion.Platform.ToString() }
  } | ConvertTo-Json -Depth 5 | Set-Content -Path (Join-Path $script:RuntimeDir 'platform.json') -Encoding UTF8
}

function Monitor-Message {
@'
你是 agile-codex 的周期监控器。请监控 ~/.openclaw/skills/agile-codex/runtime 下的运行状态，并每 10 分钟检查所有会话。

规则：
1. 检查 `~/.openclaw/skills/agile-codex/runtime` 下的 `*.status.json`、`*.meta.json`、`*.tail.txt`、`*.last.txt`。
2. 只对以下情况输出播报：
   - `active_work=true`
   - `needs_input=true`
   - `completed=true`
   - `state=missing` 且已尝试恢复
3. 如果会话只是 idle / standby / waiting / 0 active task / 无活跃任务，则不要播报。
4. 对需要播报的会话，汇报：
   - 会话名
   - 当前状态
   - 最近阶段/动作
   - 是否像是卡住
   - 下一步
5. 如果会话 state=missing 且可恢复，尝试调用恢复脚本，并在汇报里写明。
6. 如果发现 needs_input=true，明确告诉用户需要人工输入。
7. 如果完全没有需要播报的活跃会话，只回复 `HEARTBEAT_OK`。
8. 如已完成对某个会话的播报，调用 `~/.openclaw/skills/agile-codex/scripts/codex_agile_mark_reported.sh <session-name> <reason>` 标记，避免同一时间槽重复播报。

输出要求：
- 没有需要播报的活跃会话：只输出 `HEARTBEAT_OK`
- 有需要播报的会话：输出简短项目播报，避免空话。
'@
}

function Install-ProgressMonitor {
  $listText = openclaw cron list --json
  $listJson = ConvertFrom-LooseJsonText -Text $listText
  $jobs = @()
  if ($listJson.ContainsKey('jobs') -and $listJson['jobs'] -is [System.Array]) {
    $jobs = $listJson['jobs']
  }
  $job = $jobs | Where-Object { $_.name -eq 'Agile Codex progress monitor' } | Select-Object -First 1
  $msg = Monitor-Message

  if ($job) {
    openclaw cron edit $job.id --enable --name $script:MonitorName --description 'Monitor agile-codex runtime every 10 minutes and announce only when there is active work, completion, recovery, or required input.' --every 10m --session isolated --light-context --announce --message $msg | Out-Null
    $jobId = $job.id
  } else {
    openclaw cron add --name $script:MonitorName --description 'Monitor agile-codex runtime every 10 minutes and announce only when there is active work, completion, recovery, or required input.' --every 10m --session isolated --wake now --light-context --announce --message $msg | Out-Null
    $latest = ConvertFrom-LooseJsonText -Text (openclaw cron list --json)
    $jobId = (($latest['jobs'] | Where-Object { $_.name -eq 'Agile Codex progress monitor' } | Select-Object -First 1).id)
  }

  if ($jobId -and $script:MonitorChannel) {
    if ($script:MonitorTo) {
      openclaw cron edit $jobId --channel $script:MonitorChannel --to $script:MonitorTo | Out-Null
    } else {
      openclaw cron edit $jobId --channel $script:MonitorChannel | Out-Null
    }
    if ($script:MonitorAccount) {
      openclaw cron edit $jobId --account $script:MonitorAccount | Out-Null
    }
  }
}

function Ensure-AgentStateDirs {
  $agentRoot = Join-Path $HOME '.openclaw/agents/main'
  $sessionsDir = Join-Path $agentRoot 'sessions'
  $agentDir = Join-Path $agentRoot 'agent'
  New-Item -ItemType Directory -Force -Path $sessionsDir | Out-Null
  New-Item -ItemType Directory -Force -Path $agentDir | Out-Null
  $sessionsFile = Join-Path $sessionsDir 'sessions.json'
  if (-not (Test-Path $sessionsFile)) {
    '{"sessions":[]}' | Set-Content -Path $sessionsFile -Encoding UTF8
  }
}

function Self-Check {
  Write-Host '== self-check =='
  openclaw --version | Select-Object -First 1
  codex --version | Select-Object -First 1
  if (-not (Test-Path (Join-Path $script:SkillsDir 'using-superpowers/SKILL.md'))) { throw 'using-superpowers install failed' }
  if (-not (Test-Path (Join-Path $script:SkillsDir 'agile-codex/SKILL.md'))) { throw 'agile-codex install failed' }
  if (-not (Test-Path (Join-Path $script:SkillsDir 'agile-codex/scripts/agile_codex_backend.py'))) { throw 'agile-codex backend install failed' }
  if (-not (Test-Path (Join-Path $script:SkillsDir 'browser-use/SKILL.md'))) { throw 'browser-use install failed' }
  if (-not (Test-Path (Join-Path $script:SkillsDir 'local-long-memory/SKILL.md'))) { throw 'local-long-memory install failed' }
  if (-not (Test-Path (Join-Path $script:SkillsDir 'local-long-memory/scripts/memory_core.py'))) { throw 'local-long-memory core install failed' }
  if (-not (Test-Path (Join-Path $script:HooksDir 'memory-preload-bundle/HOOK.md'))) { throw 'memory-preload-bundle hook install failed' }
  if (-not (Test-Path (Join-Path $script:HooksDir 'memory-auto-capture/HOOK.md'))) { throw 'memory-auto-capture hook install failed' }

  $cfgFinal = Read-JsonFile -Path $script:ConfigPath -Default @{}
  $feishuFinal = @{}
  if ($cfgFinal.ContainsKey('channels') -and $cfgFinal['channels'] -is [hashtable] -and $cfgFinal['channels']['feishu'] -is [hashtable]) {
    $feishuFinal = [hashtable]$cfgFinal['channels']['feishu']
  }
  $browserUseFinal = @{}
  $browserUseConfigFile = Join-Path $script:SkillsDir 'browser-use/runtime/config.json'
  if (Test-Path $browserUseConfigFile) {
    $browserUseFinal = Read-JsonFile -Path $browserUseConfigFile -Default @{}
  }

  @{
    primary = $cfgFinal['agents']['defaults']['model']['primary']
    workspace = $cfgFinal['agents']['defaults']['workspace']
    using_superpowers = $cfgFinal['skills']['entries']['using-superpowers']['enabled']
    agile_codex = $cfgFinal['skills']['entries']['agile-codex']['enabled']
    browser_use = $cfgFinal['skills']['entries']['browser-use']['enabled']
    local_long_memory = $cfgFinal['skills']['entries']['local-long-memory']['enabled']
    feishu = @{
      enabled = $feishuFinal['enabled']
      appId = $feishuFinal['appId']
      hasAppSecret = [bool]$feishuFinal['appSecret']
      dmPolicy = $feishuFinal['dmPolicy']
      allowFrom = $feishuFinal['allowFrom']
    }
    browserUseConfig = $browserUseFinal
  } | ConvertTo-Json -Depth 8

  Get-Content -Path (Join-Path $script:RuntimeDir 'platform.json') -Raw
  openclaw agent --agent main -m 'Reply with exactly INSTALLER_SMOKE_OK and nothing else.' --json --timeout 60
  openclaw cron list --json
}

function Setup-HostModelProxy {
  param(
    [string]$StateDir,
    [string]$UpstreamBase,
    [string]$UpstreamKey,
    [string]$ProxyToken,
    [int]$ProxyPort
  )
  New-Item -ItemType Directory -Force -Path $StateDir | Out-Null
  $proxyPidFile = Join-Path $StateDir 'proxy.pid'
  $proxyStdOut = Join-Path $StateDir 'proxy.stdout.log'
  $proxyStdErr = Join-Path $StateDir 'proxy.stderr.log'
  Stop-PidFile -PidFile $proxyPidFile

  $python = Get-PythonCommand
  $proxyScript = Join-Path $script:ScriptDir 'app-proxy/openai_proxy.py'
  $proxyPid = New-DetachedProcess `
    -FilePath $python `
    -ArgumentList @($proxyScript, '--listen', '0.0.0.0', '--port', [string]$ProxyPort, '--upstream', $UpstreamBase, '--api-key', $UpstreamKey, '--require-bearer', $ProxyToken) `
    -WorkingDirectory $script:ScriptDir `
    -StdOutPath $proxyStdOut `
    -StdErrPath $proxyStdErr
  $proxyPid | Set-Content -Path $proxyPidFile -Encoding UTF8

  if (-not (Wait-TcpPort -Address '127.0.0.1' -Port $ProxyPort -Attempts 30 -DelaySeconds 1)) {
    Show-LogTail -Paths @($proxyStdOut, $proxyStdErr)
    throw "tenant proxy failed to start on port $ProxyPort"
  }
}

function Get-ContainerState {
  param([string]$ContainerName)
  try {
    return (& docker inspect -f '{{.State.Status}}' $ContainerName 2>$null | Select-Object -First 1).Trim()
  } catch {
    return ''
  }
}

function Wait-ForTenantReady {
  param(
    [string]$ContainerName,
    [int]$TimeoutSeconds
  )
  $pollInterval = 5
  $waited = 0
  while ($waited -lt $TimeoutSeconds) {
    $status = Get-ContainerState -ContainerName $ContainerName
    if ($status -and @('running', 'created', 'restarting') -notcontains $status) {
      Write-Host "tenant container entered unexpected state: $status"
      docker logs --tail 200 $ContainerName
      return $false
    }
    try {
      & docker exec $ContainerName test -f /tmp/tenant-ready *> $null
      & docker exec $ContainerName openclaw gateway health *> $null
      return $true
    } catch {
    }
    Start-Sleep -Seconds $pollInterval
    $waited += $pollInterval
  }
  Write-Host 'timed out waiting for tenant container to finish installation'
  docker logs --tail 200 $ContainerName
  return $false
}

function Write-TenantState {
  param(
    [string]$StateFile,
    [hashtable]$Payload
  )
  Write-JsonFile -Path $StateFile -Value $Payload
}

function Setup-TenantExpiry {
  param(
    [string]$ContainerName,
    [int]$Seconds,
    [string]$StateDir
  )
  $schedulerScript = Join-Path $script:ScriptDir 'scripts/tenant-schedule-expiry.ps1'
  & $schedulerScript -ContainerName $ContainerName -Seconds $Seconds -StateDir $StateDir
}

function Run-TenantMode {
  Need-Bin 'docker'
  $null = Get-DockerComposeMode

  $durationLabel = Choose-TenantDuration
  $durationSeconds = Convert-TenantDurationToSeconds -Label $durationLabel
  $modelMode = Choose-TenantModelMode
  $tenantShortUuid = if ([string]::IsNullOrWhiteSpace($script:TenantShortUuid)) {
    New-RandomHex -Bytes 4
  } else {
    (($script:TenantShortUuid.ToLowerInvariant()) -replace '[^a-z0-9]', '')
  }
  if (-not [string]::IsNullOrWhiteSpace($tenantShortUuid) -and $tenantShortUuid.Length -lt 4) {
    throw 'tenant short uuid must be at least 4 lowercase alphanumeric characters'
  }
  if ([string]::IsNullOrWhiteSpace($tenantShortUuid)) {
    throw 'failed to derive tenant short uuid'
  }
  $tenantName = 'tenant-' + (Get-Date).ToUniversalTime().ToString('yyyyMMddHHmmss') + '-' + $tenantShortUuid
  $tenantContainer = $tenantName + '-openclaw'
  $tenantGatewayPort = Find-FreePort
  $tenantVncPort = Find-FreePort
  while ($tenantVncPort -eq $tenantGatewayPort) {
    $tenantVncPort = Find-FreePort
  }

  $tenantDataDir = Convert-HostPathForDocker -Path (Join-Path $HOME ".openclaw-tenants/$tenantName")
  $tenantStateDir = Convert-HostPathForDocker -Path (Join-Path $HOME ".openclaw/tenant-state/$tenantName")
  New-Item -ItemType Directory -Force -Path $tenantDataDir | Out-Null
  New-Item -ItemType Directory -Force -Path $tenantStateDir | Out-Null

  $tenantVncPassword = if ([string]::IsNullOrWhiteSpace($script:TenantVncPassword)) { New-RandomPassword -Length 8 } else { $script:TenantVncPassword }

  if ($modelMode -eq 'proxy') {
    $current = Get-CurrentValues
    $hostBaseDefault = if ($script:TenantHostBaseUrl) { $script:TenantHostBaseUrl } else { $current.baseUrl }
    $hostKeyDefault = if ($script:TenantHostApiKey) { $script:TenantHostApiKey } else { $current.apiKey }
    $hostModelDefault = if ($script:TenantHostModel) { $script:TenantHostModel } else { $current.model }
    $hostBase = Prompt-Value -Label '宿主 Base URL' -Default $hostBaseDefault
    $hostKey = Prompt-Value -Label '宿主 API key' -Default $hostKeyDefault
    $hostModel = Prompt-Value -Label '宿主 Model name' -Default $hostModelDefault
    $tenantProxyToken = 'tenant-' + [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes((New-Guid).Guid + (New-RandomHex -Bytes 8))).TrimEnd('=').Replace('+', '-').Replace('/', '_')
    $tenantProxyPort = Find-FreePort
    while (@($tenantGatewayPort, $tenantVncPort) -contains $tenantProxyPort) {
      $tenantProxyPort = Find-FreePort
    }
    Setup-HostModelProxy -StateDir $tenantStateDir -UpstreamBase $hostBase -UpstreamKey $hostKey -ProxyToken $tenantProxyToken -ProxyPort $tenantProxyPort
    $effectiveBase = "http://host.docker.internal:$tenantProxyPort/v1"
    $effectiveKey = $tenantProxyToken
    $effectiveModel = $hostModel
  } else {
    $tenantProxyPort = $null
    $effectiveBase = Prompt-Value -Label '租户 Base URL' -Default $script:TenantBaseUrl
    $effectiveKey = Prompt-Value -Label '租户 API key' -Default $script:TenantApiKey
    $tenantModelDefault = if ($script:TenantModel) { $script:TenantModel } else { 'gpt-5.4' }
    $effectiveModel = Prompt-Value -Label '租户 Model name' -Default $tenantModelDefault
  }

  $tenantFeishuAppId = Prompt-Value -Label '租户 Feishu appId' -Default $script:TenantFeishuAppId
  $tenantFeishuAppSecret = Prompt-Value -Label '租户 Feishu appSecret' -Default $script:TenantFeishuAppSecret
  $tenantAllowedOriginsJson = @(
    "http://localhost:$tenantGatewayPort",
    "http://127.0.0.1:$tenantGatewayPort",
    'http://localhost:18789',
    'http://127.0.0.1:18789'
  ) | ConvertTo-Json -Compress

  $env:TENANT_CONTAINER_NAME = $tenantContainer
  $env:TENANT_GATEWAY_PORT = [string]$tenantGatewayPort
  $env:TENANT_VNC_PORT = [string]$tenantVncPort
  $env:TENANT_DATA_DIR = $tenantDataDir
  $env:TENANT_BASE_URL = $effectiveBase
  $env:TENANT_API_KEY = $effectiveKey
  $env:TENANT_MODEL = $effectiveModel
  $env:TENANT_FEISHU_APP_ID = $tenantFeishuAppId
  $env:TENANT_FEISHU_APP_SECRET = $tenantFeishuAppSecret
  $env:TENANT_VNC_PASSWORD = $tenantVncPassword
  $env:TENANT_PROXY_MODE = $modelMode
  $env:OPENCLAW_GATEWAY_BIND = 'lan'
  $env:OPENCLAW_GATEWAY_ALLOWED_ORIGINS_JSON = $tenantAllowedOriginsJson
  $env:OPENCLAW_GATEWAY_PORT = '18789'

  $composeFile = Join-Path $script:ScriptDir 'tenant-mode/docker-compose.yml'
  Invoke-DockerCompose -Arguments @('-p', $tenantName, '-f', $composeFile, 'up', '-d', '--build')
  Write-Host 'waiting for tenant container to finish installation...'
  if (-not (Wait-ForTenantReady -ContainerName $tenantContainer -TimeoutSeconds $script:TenantReadyTimeoutSeconds)) {
    Stop-PidFile -PidFile (Join-Path $tenantStateDir 'proxy.pid')
    throw 'tenant container did not become ready'
  }

  $createdAt = Format-UtcTimestamp
  $expiresAt = Format-UtcTimestamp -Value ((Get-Date).AddSeconds($durationSeconds))
  Setup-TenantExpiry -ContainerName $tenantContainer -Seconds $durationSeconds -StateDir $tenantStateDir
  $expiryMode = if (Test-Path (Join-Path $tenantStateDir 'expiry.mode')) { (Get-Content -Path (Join-Path $tenantStateDir 'expiry.mode') -Raw).Trim() } else { '' }
  $expiryUnit = if (Test-Path (Join-Path $tenantStateDir 'expiry.unit')) { (Get-Content -Path (Join-Path $tenantStateDir 'expiry.unit') -Raw).Trim() } else { '' }

  $tenantState = @{
    tenant = $tenantName
    container = $tenantContainer
    shortUuid = $tenantShortUuid
    durationLabel = $durationLabel
    durationSeconds = $durationSeconds
    modelMode = $modelMode
    gatewayPort = $tenantGatewayPort
    vncPort = $tenantVncPort
    dataDir = $tenantDataDir
    createdAt = $createdAt
    expiresAt = $expiresAt
    vncPassword = $tenantVncPassword
    baseUrl = $effectiveBase
    model = $effectiveModel
    feishuAppId = $tenantFeishuAppId
  }
  if ($tenantProxyPort) {
    $tenantState['proxyPort'] = $tenantProxyPort
  }
  if ($expiryMode) {
    $tenantState['expiryMode'] = $expiryMode
  }
  if ($expiryUnit) {
    $tenantState['expiryUnit'] = $expiryUnit
  }
  Write-TenantState -StateFile (Join-Path $tenantStateDir 'tenant.json') -Payload $tenantState

  $expirySummary = if ([string]::IsNullOrWhiteSpace($expiryUnit)) { $expiryMode } else { "$expiryMode ($expiryUnit)" }

  @"
租户模式已启动。
- short uuid: $tenantShortUuid
- tenant: $tenantName
- container: $tenantContainer
- gateway ws port: $tenantGatewayPort
- vnc port: $tenantVncPort
- vnc password: $tenantVncPassword
- duration: $durationLabel (${durationSeconds}s)
- expires at (UTC): $expiresAt
- model mode: $modelMode
- data dir: $tenantDataDir
- state dir: $tenantStateDir
- expiry scheduler: $expirySummary
"@
}

function Run-AdminMode {
  Need-Bin 'node'
  Need-Bin 'npm'
  $null = Get-PythonCommand

  Install-OpenClaw
  Install-Codex
  Bootstrap-IfMissing
  Ensure-AgentStateDirs

  if ($script:TenantNonInteractive -eq '1') {
    $baseUrl = $script:TenantBaseUrl
    $apiKey = $script:TenantApiKey
    $modelName = $script:TenantModel
  } else {
    $current = Get-CurrentValues
    $baseUrl = Prompt-Value -Label 'Base URL' -Default $current.baseUrl
    $apiKey = Prompt-Value -Label 'API key' -Default $current.apiKey
    $modelName = Prompt-Value -Label 'Model name' -Default $current.model
  }

  Write-OpenClawConfig -BaseUrl $baseUrl -ApiKey $apiKey -ModelName $modelName
  Write-CodexConfig -BaseUrl $baseUrl -ApiKey $apiKey -ModelName $modelName
  Install-FeishuPluginAndConfig
  Run-DoctorFix
  Restart-GatewayAfterFeishuConfig
  Install-LocalSkills
  Write-BrowserUseSkillConfig -BaseUrl $baseUrl -ApiKey $apiKey -ModelName $modelName
  Write-PlatformInfo
  Install-ProgressMonitor
  Self-Check
}

function Main {
  $selectedMode = Choose-InstallMode
  if ($selectedMode -eq 'tenant') {
    Run-TenantMode
    return
  }
  Run-AdminMode
}

Main
