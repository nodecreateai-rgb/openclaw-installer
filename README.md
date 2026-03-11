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
可选：
- `1h`
- `2h`
- `5h`
- `1m`

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

### 已验证通过（租户模式）
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
