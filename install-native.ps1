param()

$ErrorActionPreference = 'Stop'
$ConfigPath = if ($env:OPENCLAW_CONFIG_PATH) { $env:OPENCLAW_CONFIG_PATH } else { Join-Path $HOME '.openclaw/openclaw.json' }
$Workspace = if ($env:OPENCLAW_WORKSPACE) { $env:OPENCLAW_WORKSPACE } else { Join-Path $HOME '.openclaw' }
$Provider = 'default'
$Package = if ($env:OPENCLAW_NPM_PACKAGE) { $env:OPENCLAW_NPM_PACKAGE } else { 'openclaw@latest' }
$CodexPackage = if ($env:CODEX_NPM_PACKAGE) { $env:CODEX_NPM_PACKAGE } else { '@openai/codex@latest' }
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$BundledSkillsDir = if ($env:BUNDLED_SKILLS_DIR) { $env:BUNDLED_SKILLS_DIR } else { Join-Path $ScriptDir 'bundled-skills' }
$SkillsDir = Join-Path $HOME '.openclaw/skills'
$RuntimeDir = Join-Path $SkillsDir 'agile-codex/runtime'
$MonitorName = if ($env:AGILE_CODEX_MONITOR_NAME) { $env:AGILE_CODEX_MONITOR_NAME } else { 'Agile Codex progress monitor' }
$MonitorChannel = $env:AGILE_CODEX_MONITOR_CHANNEL
$MonitorTo = $env:AGILE_CODEX_MONITOR_TO
$MonitorAccount = $env:AGILE_CODEX_MONITOR_ACCOUNT
$BUNDLED_BROWSER_USE_DIR = if ($env:BUNDLED_BROWSER_USE_DIR) { $env:BUNDLED_BROWSER_USE_DIR } else { Join-Path $ScriptDir 'bundled-services/docker-browser-use' }
$BROWSER_USE_INSTALL_DIR = if ($env:BROWSER_USE_INSTALL_DIR) { $env:BROWSER_USE_INSTALL_DIR } else { Join-Path $HOME '.openclaw/services/docker-browser-use' }
$BROWSER_USE_HEALTH_URL = if ($env:BROWSER_USE_HEALTH_URL) { $env:BROWSER_USE_HEALTH_URL } else { 'http://127.0.0.1:8080/healthz' }
$FeishuPluginSpec = if ($env:FEISHU_PLUGIN_SPEC) { $env:FEISHU_PLUGIN_SPEC } else { '@m1heng-clawd/feishu' }

function Need-Bin($Name) {
  if (-not (Get-Command $Name -ErrorAction SilentlyContinue)) {
    throw "missing required binary: $Name"
  }
}

function Write-BrowserUseSkillConfig {
  $browserSkillDir = Join-Path $SkillsDir 'browser-use'
  $browserRuntimeDir = Join-Path $browserSkillDir 'runtime'
  $browserConfigFile = Join-Path $browserRuntimeDir 'config.json'
  if (-not (Test-Path $browserSkillDir)) {
    throw "browser-use skill directory missing: $browserSkillDir"
  }
  New-Item -ItemType Directory -Force -Path $browserRuntimeDir | Out-Null
  @{
    provider = 'default'
    baseUrl = $baseUrl
    apiKey = $apiKey
    model = $modelName
    headful = $true
    resolution = @{ width = 1920; height = 1080 }
  } | ConvertTo-Json -Depth 10 | Set-Content -Path $browserConfigFile -Encoding UTF8
}

function Install-FeishuPluginAndConfig {
  $bundledFeishu = @(
    '/usr/local/lib/node_modules/openclaw/extensions/feishu/openclaw.plugin.json',
    '/usr/lib/node_modules/openclaw/extensions/feishu/openclaw.plugin.json'
  ) | Where-Object { Test-Path $_ }

  if ($bundledFeishu.Count -gt 0) {
    Write-Host 'Feishu plugin already bundled with current OpenClaw installation; skipping npm install'
  } else {
    Write-Host "installing Feishu plugin: $FeishuPluginSpec"
    openclaw plugins install $FeishuPluginSpec | Out-Null
  }

  $cfgNow = Get-Content $ConfigPath -Raw | ConvertFrom-Json -AsHashtable
  $currentAppId = ''
  $currentAppSecret = ''
  if ($cfgNow.channels -and $cfgNow.channels.feishu) {
    $currentAppId = $cfgNow.channels.feishu.appId
    $currentAppSecret = $cfgNow.channels.feishu.appSecret
  }

  $feishuAppId = Read-Host "Feishu appId [$currentAppId]"
  if ([string]::IsNullOrWhiteSpace($feishuAppId)) { $feishuAppId = $currentAppId }
  $feishuAppSecret = Read-Host "Feishu appSecret [$currentAppSecret]"
  if ([string]::IsNullOrWhiteSpace($feishuAppSecret)) { $feishuAppSecret = $currentAppSecret }

  openclaw config set channels.feishu.appId ('"' + $feishuAppId + '"') | Out-Null
  openclaw config set channels.feishu.appSecret ('"' + $feishuAppSecret + '"') | Out-Null
  openclaw config set channels.feishu.enabled true --strict-json | Out-Null

  $cfgAfter = Get-Content $ConfigPath -Raw | ConvertFrom-Json -AsHashtable
  if (-not $cfgAfter.channels) { $cfgAfter.channels = @{} }
  if (-not $cfgAfter.channels.feishu) { $cfgAfter.channels.feishu = @{} }
  $cfgAfter.channels.feishu.dmPolicy = 'open'
  $cfgAfter.channels.feishu.allowFrom = @('*')
  $cfgAfter | ConvertTo-Json -Depth 20 | Set-Content -Path $ConfigPath -Encoding UTF8
}

function Run-DoctorFix {
  openclaw doctor --fix *> (Join-Path $env:TEMP 'openclaw-doctor-fix.log')
}

function Restart-GatewayAfterFeishuConfig {
  try {
    openclaw gateway restart *> (Join-Path $env:TEMP 'openclaw-gateway-restart.log')
    if (Wait-Gateway 20 2) { return }
  } catch {}

  $runLog = Join-Path $env:TEMP 'openclaw-gateway-run.log'
  $proc = Start-Process -FilePath 'openclaw' -ArgumentList @('gateway','run') -PassThru -WindowStyle Hidden -RedirectStandardOutput $runLog -RedirectStandardError $runLog
  $proc.Id | Set-Content -Path (Join-Path $env:TEMP 'openclaw-gateway-run.pid') -Encoding UTF8
  if (-not (Wait-Gateway 30 2)) {
    throw 'failed to restart gateway after feishu config'
  }
}

function Write-PlatformInfo {
  New-Item -ItemType Directory -Force -Path $RuntimeDir | Out-Null
  $hasTmux = [bool](Get-Command tmux -ErrorAction SilentlyContinue)
  $hasJq = [bool](Get-Command jq -ErrorAction SilentlyContinue)
  $hasWsl = [bool](Get-Command wsl.exe -ErrorAction SilentlyContinue)
  $backend = 'process'
  if ($hasWsl) {
    $backend = 'wsl'
  } elseif ($hasTmux) {
    $backend = 'tmux'
  }
  $obj = @{
    backend = $backend
    has_tmux = $hasTmux
    has_jq = $hasJq
    has_wsl = $hasWsl
    host_os = $PSVersionTable.Platform
  }
  $obj | ConvertTo-Json -Depth 5 | Set-Content -Path (Join-Path $RuntimeDir 'platform.json') -Encoding UTF8
}

function Wait-Gateway([int]$Attempts = 30, [int]$DelaySeconds = 2) {
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

function Start-GatewayForCron {
  try {
    openclaw gateway start *> (Join-Path $env:TEMP 'openclaw-gateway-start.log')
    if (Wait-Gateway 15 2) { return }
  } catch {}

  $runLog = Join-Path $env:TEMP 'openclaw-gateway-run.log'
  $proc = Start-Process -FilePath 'openclaw' -ArgumentList @('gateway','run') -PassThru -WindowStyle Hidden -RedirectStandardOutput $runLog -RedirectStandardError $runLog
  $proc.Id | Set-Content -Path (Join-Path $env:TEMP 'openclaw-gateway-run.pid') -Encoding UTF8
  if (-not (Wait-Gateway 30 2)) {
    throw 'failed to start gateway'
  }
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
- 没有需要播报的会话：只输出 `HEARTBEAT_OK`
- 有需要播报的会话：输出简短项目播报，避免空话。
'@
}

function Install-ProgressMonitor {
  $listJson = openclaw cron list --json | ConvertFrom-Json -AsHashtable
  $job = $listJson.jobs | Where-Object { $_.name -eq 'Agile Codex progress monitor' } | Select-Object -First 1
  $msg = Monitor-Message

  if ($job) {
    openclaw cron edit $job.id --enable --name $MonitorName --description 'Monitor agile-codex runtime every 10 minutes and announce only when there is active work, completion, recovery, or required input.' --every 10m --session isolated --light-context --announce --message $msg | Out-Null
    $jobId = $job.id
  } else {
    openclaw cron add --name $MonitorName --description 'Monitor agile-codex runtime every 10 minutes and announce only when there is active work, completion, recovery, or required input.' --every 10m --session isolated --wake now --light-context --announce --message $msg | Out-Null
    $jobId = ((openclaw cron list --json | ConvertFrom-Json -AsHashtable).jobs | Where-Object { $_.name -eq 'Agile Codex progress monitor' } | Select-Object -First 1).id
  }

  if ($jobId -and $MonitorChannel) {
    if ($MonitorTo) {
      openclaw cron edit $jobId --channel $MonitorChannel --to $MonitorTo | Out-Null
    } else {
      openclaw cron edit $jobId --channel $MonitorChannel | Out-Null
    }
    if ($MonitorAccount) {
      openclaw cron edit $jobId --account $MonitorAccount | Out-Null
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

Need-Bin node
Need-Bin npm
Need-Bin python3

if (-not (Get-Command openclaw -ErrorAction SilentlyContinue)) {
  Write-Host "installing $Package ..."
  npm install -g $Package
}
Write-Host "installed:" (openclaw --version | Select-Object -First 1)

if (-not (Get-Command codex -ErrorAction SilentlyContinue)) {
  Write-Host "installing $CodexPackage ..."
  npm install -g $CodexPackage
}
Write-Host "codex:" (codex --version | Select-Object -First 1)

$ConfigDir = Split-Path -Parent $ConfigPath
New-Item -ItemType Directory -Force -Path $ConfigDir | Out-Null
New-Item -ItemType Directory -Force -Path $Workspace | Out-Null
New-Item -ItemType Directory -Force -Path $SkillsDir | Out-Null
$workspaceMemoryDir = Join-Path $Workspace 'memory'
New-Item -ItemType Directory -Force -Path $workspaceMemoryDir | Out-Null
$workspaceMemoryFile = Join-Path $Workspace 'MEMORY.md'
if (-not (Test-Path $workspaceMemoryFile)) {
  "# MEMORY.md`n`n## Long-term Memory`n" | Set-Content -Path $workspaceMemoryFile -Encoding UTF8
}
$today = (Get-Date).ToUniversalTime().ToString('yyyy-MM-dd')
$yesterday = (Get-Date).ToUniversalTime().AddDays(-1).ToString('yyyy-MM-dd')
foreach ($day in @($today, $yesterday)) {
  $dailyPath = Join-Path $workspaceMemoryDir ($day + '.md')
  if (-not (Test-Path $dailyPath)) {
    "# $day`n" | Set-Content -Path $dailyPath -Encoding UTF8
  }
}

if (-not (Test-Path $ConfigPath)) {
  $cfg = @{
    models = @{ mode = 'merge'; providers = @{ default = @{ baseUrl=''; apiKey=''; auth='api-key'; api='openai-completions'; authHeader=$true; models=@(@{ id='gpt-5.4'; name='gpt-5.4'; reasoning=$false; input=@('text'); cost=@{ input=0; output=0; cacheRead=0; cacheWrite=0 }; contextWindow=200000; maxTokens=8192; compat=@{ maxTokensField='max_tokens' } }) } } }
    agents = @{ defaults = @{ model = @{ primary = 'default/gpt-5.4' }; models = @{ 'default/gpt-5.4' = @{} }; workspace = $Workspace; compaction=@{ mode='safeguard' }; timeoutSeconds=900; maxConcurrent=16; subagents=@{ maxConcurrent=32 } } }
    tools = @{ profile='full' }
    messages = @{ ackReactionScope='group-mentions' }
    commands = @{ native='auto'; nativeSkills='auto'; restart=$true; ownerDisplay='raw' }
    session = @{ dmScope='per-channel-peer' }
    hooks = @{ internal = @{ enabled=$true; entries=@{ 'boot-md'=@{enabled=$true}; 'bootstrap-extra-files'=@{enabled=$true}; 'command-logger'=@{enabled=$true}; 'session-memory'=@{enabled=$true} } } }
    gateway = @{ port=18789; mode='local'; bind='loopback'; controlUi=@{ allowedOrigins=@('http://localhost:18789','http://127.0.0.1:18789') }; auth=@{ mode='token'; token='openclaw-local-token' }; tailscale=@{ mode='off'; resetOnExit=$false }; nodes=@{ denyCommands=@('camera.snap','camera.clip','screen.record','contacts.add','calendar.add','reminders.add','sms.send') } }
  }
  $cfg | ConvertTo-Json -Depth 20 | Set-Content -Path $ConfigPath -Encoding UTF8
  Write-Host "created default config: $ConfigPath"
}

$cfg = Get-Content $ConfigPath -Raw | ConvertFrom-Json -AsHashtable
$currentBase = $cfg.models.providers.default.baseUrl
$currentKey = $cfg.models.providers.default.apiKey
$currentModel = $cfg.models.providers.default.models[0].id

$baseUrl = Read-Host "Base URL [$currentBase]"
if ([string]::IsNullOrWhiteSpace($baseUrl)) { $baseUrl = $currentBase }
$apiKey = Read-Host "API key [$currentKey]"
if ([string]::IsNullOrWhiteSpace($apiKey)) { $apiKey = $currentKey }
$modelName = Read-Host "Model name [$currentModel]"
if ([string]::IsNullOrWhiteSpace($modelName)) { $modelName = $currentModel }

$cfg.models.mode = 'merge'
$cfg.models.providers = @{ default = $cfg.models.providers.default }
$cfg.models.providers.default.baseUrl = $baseUrl
$cfg.models.providers.default.apiKey = $apiKey
$cfg.models.providers.default.auth = 'api-key'
$cfg.models.providers.default.api = 'openai-completions'
$cfg.models.providers.default.authHeader = $true
$cfg.models.providers.default.models = @(@{ id=$modelName; name=$modelName; reasoning=$false; input=@('text'); cost=@{ input=0; output=0; cacheRead=0; cacheWrite=0 }; contextWindow=200000; maxTokens=8192; compat=@{ maxTokensField='max_tokens' } })
$cfg.agents.defaults.model.primary = "default/$modelName"
$cfg.agents.defaults.models = @{ ("default/$modelName") = @{} }
$cfg.agents.defaults.workspace = $Workspace
if (-not $cfg.skills) { $cfg.skills = @{} }
if (-not $cfg.skills.entries) { $cfg.skills.entries = @{} }
$cfg.skills.entries['using-superpowers'] = @{ enabled = $true }
$cfg.skills.entries['agile-codex'] = @{ enabled = $true }
$cfg.skills.entries['browser-use'] = @{ enabled = $true }
if (-not $cfg.plugins) { $cfg.plugins = @{} }
if (-not $cfg.plugins.entries) { $cfg.plugins.entries = @{} }
$cfg.plugins.entries.Remove('paco-global-skills') | Out-Null
if ($cfg.plugins.load) { $cfg.plugins.load.Remove('paths') | Out-Null }
$allow = @()
if ($cfg.plugins.allow) { $allow = @($cfg.plugins.allow | Where-Object { $_ -ne 'paco-global-skills' }) }
if ($allow -notcontains 'feishu') { $allow += 'feishu' }
$cfg.plugins.allow = $allow

$cfg | ConvertTo-Json -Depth 20 | Set-Content -Path $ConfigPath -Encoding UTF8
Write-Host "updated $ConfigPath"
$preview = @{ provider='default'; baseUrl=$baseUrl; model=$modelName; primary="default/$modelName"; workspace=$Workspace }
$preview | ConvertTo-Json -Depth 5

New-Item -ItemType Directory -Force -Path (Join-Path $HOME '.codex') | Out-Null
@"
model = "$modelName"
model_provider = "custom"

[model_providers.custom]
name = "Custom OpenAI-Compatible"
base_url = "$baseUrl"
wire_api = "responses"
experimental_bearer_token = "$apiKey"
"@ | Set-Content -Path (Join-Path $HOME '.codex/config.toml') -Encoding UTF8

$using = Join-Path $BundledSkillsDir 'using-superpowers'
$agile = Join-Path $BundledSkillsDir 'agile-codex'
if (-not (Test-Path $using) -or -not (Test-Path $agile)) {
  throw "missing bundled skills under $BundledSkillsDir"
}
if (Test-Path (Join-Path $SkillsDir 'using-superpowers')) { Remove-Item -Recurse -Force (Join-Path $SkillsDir 'using-superpowers') }
if (Test-Path (Join-Path $SkillsDir 'agile-codex')) { Remove-Item -Recurse -Force (Join-Path $SkillsDir 'agile-codex') }
if (Test-Path (Join-Path $SkillsDir 'browser-use')) { Remove-Item -Recurse -Force (Join-Path $SkillsDir 'browser-use') }
Copy-Item -Recurse -Force $using (Join-Path $SkillsDir 'using-superpowers')
Copy-Item -Recurse -Force $agile (Join-Path $SkillsDir 'agile-codex')
Copy-Item -Recurse -Force (Join-Path $BundledSkillsDir 'browser-use') (Join-Path $SkillsDir 'browser-use')
Install-FeishuPluginAndConfig
Run-DoctorFix
Restart-GatewayAfterFeishuConfig
Write-BrowserUseSkillConfig
Write-PlatformInfo
Install-ProgressMonitor

Write-Host "== self-check =="
openclaw --version | Select-Object -First 1
codex --version | Select-Object -First 1
if (-not (Test-Path (Join-Path $SkillsDir 'using-superpowers/SKILL.md'))) { throw 'using-superpowers install failed' }
if (-not (Test-Path (Join-Path $SkillsDir 'agile-codex/SKILL.md'))) { throw 'agile-codex install failed' }
if (-not (Test-Path (Join-Path $SkillsDir 'agile-codex/scripts/agile_codex_backend.py'))) { throw 'agile-codex backend install failed' }
if (-not (Test-Path (Join-Path $SkillsDir 'browser-use/SKILL.md'))) { throw 'browser-use install failed' }
$cfgFinal = Get-Content $ConfigPath -Raw | ConvertFrom-Json -AsHashtable
$feishuFinal = @{}
if ($cfgFinal.channels -and $cfgFinal.channels.feishu) { $feishuFinal = $cfgFinal.channels.feishu }
$browserUseFinal = @{}
$browserUseConfigFile = Join-Path $SkillsDir 'browser-use/runtime/config.json'
if (Test-Path $browserUseConfigFile) { $browserUseFinal = Get-Content $browserUseConfigFile -Raw | ConvertFrom-Json -AsHashtable }
@{
  primary = $cfgFinal.agents.defaults.model.primary
  workspace = $cfgFinal.agents.defaults.workspace
  using_superpowers = $cfgFinal.skills.entries['using-superpowers'].enabled
  agile_codex = $cfgFinal.skills.entries['agile-codex'].enabled
  browser_use = $cfgFinal.skills.entries['browser-use'].enabled
  feishu = @{
    enabled = $feishuFinal.enabled
    appId = $feishuFinal.appId
    hasAppSecret = [bool]$feishuFinal.appSecret
    dmPolicy = $feishuFinal.dmPolicy
    allowFrom = $feishuFinal.allowFrom
  }
  browserUseConfig = $browserUseFinal
} | ConvertTo-Json -Depth 8
(Get-Content (Join-Path $RuntimeDir 'platform.json') -Raw)
openclaw agent --agent main -m 'Reply with exactly INSTALLER_SMOKE_OK and nothing else.' --json --timeout 60
openclaw cron list --json
