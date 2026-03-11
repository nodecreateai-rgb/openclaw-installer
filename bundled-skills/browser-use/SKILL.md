---
name: browser-use
description: 通过 Docker 中运行的 Xvfb + headful Chromium 常驻浏览器环境完成浏览器任务的全局 skill。适用于“用浏览器去做任务”“保持浏览器常驻”“需要 profile 隔离登录多个账号”“使用 browser-use / CDP / 截图 / 浏览器交互”“需要在 Docker 中以 1920x1080 固定分辨率运行浏览器”等请求。遇到登录、密码、手机验证码、短信 OTP 等场景时，及时要求用户提供必要信息。
metadata: {"openclaw":{"emoji":"🌐","os":["linux"],"requires":{"bins":["docker","python3"]}}}
---

# Browser Use

把这个 skill 用在**专门的容器化浏览器任务**上，而不是普通网页问答。

如需本机运行细节，读取 `{baseDir}/references/runtime.md`。

## 核心目标

1. 用 Docker 中的浏览器服务承接浏览器任务。
2. 浏览器必须是：
   - headful
   - Xvfb
   - 1920x1080 固定分辨率
   - persistent profile
3. 不同账号必须使用不同 `profile_id` 隔离。
4. 登录场景缺少凭据时，及时向用户索要。
5. 不要随意退出已有账号。

## 何时使用

以下请求优先使用本 skill：
- “用浏览器帮我做这个任务”
- “打开一个常驻浏览器”
- “浏览器里登录并保持会话”
- “多个账号隔离操作”
- “browser-use / CDP / Docker 浏览器”
- “固定 1920x1080 截图 / 浏览器自动化”

## 工作流程

### 1) 先确认服务是否存在

优先检查：
- `/root/.paco/docker-browser-use`
- 本地服务是否已在 `127.0.0.1:8080` 运行

如果服务没启动，可在项目目录使用 Docker Compose 启动。

### 2) 使用 profile 隔离

每个账号 / 任务域应有独立 `profile_id`。

示例命名：
- `google-work`
- `x-personal`
- `shop-admin`

规则：
- 同账号尽量复用同一 profile
- 不同账号不要混用 profile
- 默认不要主动登出

### 3) 登录/验证码策略

如果任务包含以下内容且用户未提供必要信息：
- 用户名
- 密码
- 手机号
- 短信验证码
- OTP / 2FA

应立即告诉用户：
- 当前需要哪些信息
- 为什么需要
- 收到后会继续在哪个 profile 中操作

### 4) 基本操作路径

常见流程：
1. `POST /session/start`
2. `POST /browser/navigate`
3. 必要时 `POST /browser/type`
4. `POST /browser/screenshot`
5. 需要更高阶任务时用 `POST /agent/run`

### 5) 输出要求

给用户汇报时说清楚：
- 使用了哪个 profile
- 当前打开到哪里
- 是否需要用户输入登录信息
- 是否已保存截图/产物

## 注意事项

- 默认保持浏览器常驻，不要每次任务都重建 profile。
- 固定分辨率为 1920x1080。
- 截图也按该分辨率输出。
- 当任务适合浏览器工具直接做时，可结合系统 browser 工具；但当用户明确要求 Docker/Xvfb/browser-use/profile 隔离时，优先用本 skill 对应的容器服务。
