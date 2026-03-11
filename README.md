# docker-openclaw-clone

这个目录现在同时提供两类安装入口：

1. **一键安装入口（原生安装，推荐交付给客户）**
2. **Docker 安装模式**：用于隔离测试

## 一键安装（默认走宿主机原生安装，不在 Docker 中安装）

### Linux / macOS

```bash
cd /root/.paco/docker-openclaw-clone
bash install.sh
```

### Windows PowerShell

```powershell
cd docker-openclaw-clone
.\install.ps1
```

### Windows CMD

```cmd
install.cmd
```

> `install.sh` / `install.ps1` 现在会直接调用原生安装器，**不会**先起容器再进 Docker 里安装。

## 原生安装模式（推荐交付给客户）

### Linux / macOS

```bash
cd /root/.paco/docker-openclaw-clone
bash install-native.sh
```

### Windows PowerShell

```powershell
cd docker-openclaw-clone
.\install-native.ps1
```

### Windows CMD

```cmd
install-native.cmd
```

## 原生模式现在会做什么

1. 检查 `node` / `npm` / `python3`
2. 安装 `openclaw@latest`
3. 安装 `@openai/codex@latest`
4. 初始化 `~/.openclaw/openclaw.json`
5. 交互输入：
   - Base URL
   - API key
   - Model name
6. 同时写入：
   - OpenClaw 最小可工作配置
   - `~/.codex/config.toml`
   - browser-use skill 运行配置（Base URL / API key / Model 同步）
7. 使用当前 OpenClaw 自带的 Feishu 插件能力并交互输入：
   - appId
   - appSecret
8. 增量写入 Feishu 配置：
   - `channels.feishu.enabled = true`
   - `channels.feishu.dmPolicy = "open"`
   - `channels.feishu.allowFrom = ["*"]`
   - Feishu 图片 / 视频 / 文档发送能力由插件内建能力负责，不再额外交付独立全局 skill
9. 配完 Feishu 后执行 `openclaw doctor --fix` 并重启 OpenClaw gateway
10. 直接安装本地 skills 到 `~/.openclaw/skills/`：
   - `using-superpowers`
   - `agile-codex`
   - `browser-use`
11. 显式启用：
   - `using-superpowers`
   - `agile-codex`
   - `browser-use`
12. 为 browser-use skill 写入同步配置到：
   - `~/.openclaw/skills/browser-use/runtime/config.json`
13. 为 `agile-codex` 写入平台运行信息：
   - Linux / macOS：优先 `tmux`
   - Windows：优先 `WSL`，否则走进程 fallback
14. 安装/更新 `Agile Codex progress monitor` cron
15. 执行 self-check：
   - `openclaw --version`
   - `codex --version`
   - 检查 `~/.openclaw/skills/.../SKILL.md`
   - 检查 `agile_codex_backend.py`
   - 检查 Feishu 配置
   - 检查 browser-use skill 配置
   - `openclaw agent --agent main -m ... --json`
   - `openclaw cron list --json`

## 跨平台行为说明

### Linux / macOS
- 自动尝试安装：
  - `tmux`
  - `jq`
- 如果成功装上 `tmux`，`agile-codex` 走完整 tmux 后端。
- 如果宿主限制导致 `tmux` 不能自动安装，则保留可运行的进程后端 fallback。

### Windows
- 不再把 `tmux` 视为原生硬依赖。
- 优先检测：
  - `wsl.exe`
  - `tmux`
- 默认策略：
  1. 有 WSL → 标记为 `wsl` 后端
  2. 有 tmux → 可兼容使用 `tmux`
  3. 否则 → 使用 `process` fallback
- 对外仍保持：
  - 可启动
  - 可状态采样
  - 可恢复
  - 可定时监控

## 定时汇报规则

安装器现在会把 `Agile Codex progress monitor` 一起装好，并统一成下面这条规则：

- **只有存在活跃工作时才定时汇报**
- 以下情况会播报：
  - `active_work=true`
  - `needs_input=true`
  - `completed=true`
  - `state=missing` 且已尝试恢复
- 以下情况不播报：
  - idle
  - standby
  - waiting
  - `0 active task`
  - 无活跃任务

也就是说：

> **没有工作就不汇报，有工作才检查/播报。**

## 交付要求

安装包里必须包含：

- `bundled-skills/using-superpowers`
- `bundled-skills/agile-codex`
- `bundled-skills/browser-use`

Feishu 媒体发送能力由 Feishu 插件内建实现负责，不作为独立全局 skill 交付。

## Docker 模式（隔离测试）

如需仅用于隔离测试，仍可单独使用容器相关文件；但默认一键入口已切换为原生安装。

Docker 模式适合验证安装流程，不作为客户宿主机正式交付方案。
