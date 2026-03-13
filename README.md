# openclaw-installer

这个仓库现在提供 **两种安装模式**：

1. **网管模式（admin mode）**
   - 安装到宿主机
   - 适合管理员 / 网管 / 自己控制机器的场景
2. **租户模式（tenant mode）**
   - 安装到 Docker 容器
   - 容器内启用 **Xvfb + headful 浏览器环境**
   - 适合按时长交付给租户使用

## 安装入口

### Linux / macOS

```bash
curl -fsSL https://raw.githubusercontent.com/nodecreateai-rgb/openclaw-installer/main/install.sh | bash
```

### Windows PowerShell

```powershell
irm https://raw.githubusercontent.com/nodecreateai-rgb/openclaw-installer/main/install.ps1 | iex
```

### Windows CMD

```cmd
powershell -NoProfile -ExecutionPolicy Bypass -Command "irm https://raw.githubusercontent.com/nodecreateai-rgb/openclaw-installer/main/install.ps1 | iex"
```

> Windows 的 `install.ps1` 现在会在远程 `irm | iex` 场景下自动下载完整安装器归档到持久目录 `~/.openclaw/installer-bundles/...`，再转入本地 `install-native.ps1`，避免 tenant mode 所需文件缺失，且保证 host proxy / expiry helper 不会因为临时目录清理而失效。
> 有 active tenant 时，不要手动删除对应 bundle 目录；否则该租户后续的 host-side helper 可能失效。

---

## 模式一：网管模式（admin）

网管模式保留当前原生安装流程：

1. 安装 `openclaw@latest`
2. 安装 `@openai/codex@latest`
3. 初始化 `~/.openclaw/openclaw.json`
4. 手工输入：
   - Base URL
   - API key
   - Model name
5. 同步写入：
   - `~/.openclaw/openclaw.json`
   - `~/.codex/config.toml`
   - `~/.openclaw/skills/browser-use/runtime/config.json`
6. 继续输入 Feishu：
   - appId
   - appSecret
7. 执行：
   - `openclaw doctor --fix`
   - gateway 启动 / 自检
   - cron / agent 自检
8. 安装 3 个 bundled skills：
   - `using-superpowers`
   - `agile-codex`
   - `browser-use`

---

## 模式二：租户模式（tenant）

租户模式会安装到 Docker 容器中，而不是直接装到宿主机。

### 租户模式流程

安装器开头会先选择：

- `admin`
- `tenant`

如果选择 `tenant`，后续会继续选择：

### 1. 租户时长
交互式安装器当前仍提供一组常用预设：
- `1h`
- `2h`
- `5h`
- `1m`

Linux shell / PowerShell 安装器当前也兼容更宽松的自然输入时长，例如：
- `3h`
- `90m`
- `1h30m`
- `3hours`
- `1mo`
- `1月`
- `30s`

> 兼容旧语义：精确输入 `1m` 时，仍表示 **1 month**，不是 1 minute。

安装器会在**宿主机**创建到期停用任务。

### 到期行为
到期后：
- **Docker 容器仍保留**
- 但会停止容器内的 OpenClaw 服务（主要是 gateway / OpenClaw 进程）
- 达到“容器还在，但内部 OpenClaw 不能继续用”的目的

> 这里使用**宿主侧定时控制**，而不是依赖容器内 cron/systemd，原因是更稳、更容易统一管理。

### 2. 租户模型来源
可选：
- `proxy`（代理模式）
- `custom`（自定义模式）

#### 代理模式（proxy）
代理模式下：
- 宿主机保存真实：
  - Base URL
  - API key
  - Model
- 容器里不会直接暴露宿主真实 API key
- 安装器会在宿主机启动一个**中间代理**
- 租户容器只连接这个宿主侧代理

这样可以做到：
- 宿主凭据不直接泄露进租户容器
- 租户仍可正常通过兼容接口访问模型
- 宿主会为该租户生成独立代理 token

#### 自定义模式（custom）
自定义模式下：
- 直接让租户输入：
  - Base URL
  - API key
  - Model
- 后续流程和网管模式类似，只是安装目标变成租户容器

### 3. 浏览器环境
租户模式的容器会启用：
- `Xvfb`
- headful 浏览器运行环境

适合：
- browser-use
- 需要 GUI 浏览器的自动化任务
- VNC 默认生成独立密码，安装结果会输出端口和密码

---

## 内置的 3 个全局 skill

安装完成后默认包含：
- `using-superpowers`
- `agile-codex`
- `browser-use`

Feishu 媒体发送能力由 Feishu 插件内建实现负责，**不再单独交付 `feishu-media-send` skill**。

---

## 交付说明

### 验证脚本
- Linux 侧已使用的验证脚本：
  - `scripts/validate-agile-codex-backend.sh`
  - `scripts/validate-local-long-memory-hooks.sh`
  - `bundled-skills/local-long-memory/tests/test_memory_core.sh`
- 额外静态检查：
  - `git diff --check`
  - `bash -n install-native.sh scripts/tenant-schedule-expiry.sh scripts/tenant-expire.sh scripts/tenant-reconcile-disabled.sh`
  - `python3 -m py_compile bundled-skills/agile-codex/scripts/agile_codex_backend.py`
- Windows tenant 路径验证：
  - `scripts/validate-windows-tenant-mock.sh`
    在 Linux + Docker 环境下验证 PowerShell / CMD tenant 接线、proxy/custom、expiry scheduler 与 reconcile helper
  - `scripts/validate-windows-tenant-real.ps1`
    真实 Windows 宿主上的 real smoke wrapper，会顺序调用 `scripts/windows-tenant-real-smoke.ps1`
  - `scripts/windows-tenant-real-smoke.ps1`
    单入口的真实 Windows + Docker Desktop smoke 脚本

### 已验证通过（网管模式）
- 手工输入安装流程
- gateway health
- cron list
- agent smoke
- browser-use 配置同步
- 协作矩阵：
  - 单任务
  - 串行协作
  - 并发协作
  - fallback

### 已验证通过（Linux 租户模式）
- 安装器开头先选 `admin / tenant`
- `tenant -> duration -> proxy/custom` 顺序可用
- custom 模式可完成：
  - 容器构建
  - OpenClaw/Codex/skills 安装
  - gateway 健康检查
  - mock upstream 模型调用
- proxy 模式可完成：
  - 宿主侧代理启动
  - 容器内仅保存代理地址和租户 token
  - 上游收到的是真实宿主 key，而不是容器 token
- 到期停用逻辑已验证：
  - 宿主侧脚本触发停用
  - 容器保留
  - 容器内 OpenClaw gateway 停止
  - 容器重启后仍保持停用
- 到期调度优先使用宿主 `systemd-run --user`
- 若宿主没有可用 user systemd，则自动 fallback 到宿主后台 sleep 任务

### Windows tenant mode 状态
- PowerShell / CMD 入口已补齐：
  - 开头 `admin / tenant` 选择
  - `tenant -> duration -> proxy/custom` 顺序
  - 远程 `install.ps1` bootstrap 会把完整安装器保存在持久目录，避免 tenant helper 依赖 `TEMP`
  - host-side proxy 启动与 `tenant.json` 状态写盘
  - 到期调度优先 `schtasks`，失败时 fallback 到后台 PowerShell `Start-Sleep`
  - `schtasks` 路径会在计划任务内补 `SleepSeconds`，避免分钟精度导致租户提前到期
  - `tenant-expire.ps1` 会写入 `TENANT_DISABLED` 并尝试停掉容器内 OpenClaw gateway / 相关进程
  - tenant Docker 环境仍复用同一套 `tenant-mode/docker-compose.yml`，保持 Xvfb + headful 调用链
- 实机 smoke 辅助脚本：
  - 可在真实 Windows 宿主运行 `scripts/windows-tenant-real-smoke.ps1`
  - 也可直接运行 `scripts/validate-windows-tenant-real.ps1`，由 wrapper 统一调度多入口 smoke
  - 支持 `powershell / pwsh / cmd` 本地入口，以及安装后自动重排一次短时 `schtasks` 到期验证
  - 到期 smoke 会继续确认容器仍保留、容器内 `TENANT_DISABLED` 已生效、且 gateway health 不再通过
  - 默认会隔离 `HOME / USERPROFILE / APPDATA / LOCALAPPDATA / npm global prefix / OPENCLAW_*`，并强制走隔离 npm 全局安装以避免复用宿主已有 CLI；完成后会清理容器、计划任务与临时目录，排查时可加 `-KeepHomeRoot`
  - 默认 real smoke 必须覆盖 `powershell`、`pwsh`、`cmd` 三入口；真实 Windows 宿主缺少任一入口都会直接失败，不允许静默降级
  - `custom` 实机 smoke 需提供 `WINDOWS_TENANT_REAL_SMOKE_BASE_URL` 与 `WINDOWS_TENANT_REAL_SMOKE_API_KEY`
  - `proxy` 实机 smoke 需提供 `WINDOWS_TENANT_REAL_SMOKE_HOST_BASE_URL`、`WINDOWS_TENANT_REAL_SMOKE_HOST_API_KEY`、`WINDOWS_TENANT_REAL_SMOKE_HOST_MODEL`
  - 如需有意只跑单入口或固定顺序，必须显式设 `WINDOWS_TENANT_REAL_SMOKE_ENTRYPOINTS=powershell` 或 `pwsh` / `cmd`
- 当前验证边界：
  - 已在 PowerShell 7 运行时中实测通过脚本级流程：
    - custom 模式 tenant 启动
    - proxy 模式 host proxy 启动与容器侧代理配置写入
    - `schtasks` 调度命令生成
    - 无 `schtasks` 时的后台 PowerShell fallback 调度
    - `tenant-expire.ps1` 停用逻辑
    - 远程 `install.ps1` bootstrap 下载归档再执行
  - **尚未在真实 Windows + Docker Desktop 宿主完成整链路实机验证**
