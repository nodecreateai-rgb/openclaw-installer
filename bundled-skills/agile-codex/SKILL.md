---
name: agile-codex
description: 使用 Codex CLI 执行中长时软件开发任务，并结合 BMAD 方法完成需求分析、快速规格、实现、测试、review、进度跟踪与恢复。遇到开发执行类请求时使用：例如做小工具、写脚本、搭页面、修 bug、重构、补测试、代码评审、长时间编码任务、需要后台持续运行和定时汇报的工程任务。优先用于明确的编码/测试/实现型请求，而不是普通问答。
metadata: {"openclaw":{"emoji":"🛠️","os":["linux","darwin","windows"],"requires":{"bins":["codex","python3"],"optionalBins":["tmux","jq","bash","wsl"]}}}
---

# Agile Codex

按下面流程工作，让主代理把“开发执行类任务”稳定地委托给 Codex CLI，并用 BMAD 方法保持敏捷、可跟踪、可恢复。

## 核心原则

1. 把你自己当成**调度者 + reviewer + 监工**，把大部分长时编码交给后台运行的 Codex CLI。
2. 对明确的软件开发请求，优先触发本 skill，而不是在当前回合里直接手写大量代码。
3. Codex CLI 默认使用：
   - `gpt-5.4`
   - `model_reasoning_effort = xhigh`
   - `--dangerously-bypass-approvals-and-sandbox`（即 Full Access）
   - `--search`
4. 全程要求 Codex **使用 BMAD 方法**：先分析，再形成 quick spec / story / implementation plan，再编码，再测试，再 review。
5. 完成编码后不要立刻收工，必须进入 review loop。
6. **外部功能保持一致**：无论底层是 tmux、WSL 还是进程后端，启动/状态/恢复/定时汇报语义都必须一致。

如果需要更细的触发策略和 BMAD 路由，读取 `{baseDir}/references/routing.md`。

## 平台策略

### Linux / macOS
- 优先使用 `tmux` 作为完整后端。
- 建议同时具备：`tmux`、`jq`、`bash`、`python3`、`codex`。
- 如果极少数环境缺少 `tmux`，允许退化到进程后端，但对外仍要保持：
  - 可启动
  - 可采样
  - 可恢复
  - 可定时监控

### Windows
- **不能把 `tmux` 当成原生硬依赖**。
- 优先顺序：
  1. 检测并使用 **WSL**，在 WSL 内安装并运行完整 `agile-codex`。
  2. 若存在 Git Bash / MSYS / 已安装 `tmux`，可走兼容类 Unix 路径。
  3. 若没有 WSL / tmux，则使用**进程后端 fallback**，通过 Python + bash/nohup 等价维护后台任务状态。
- 无论底层后端如何变化，都不要把“功能缺失”暴露为用户体验差异。

## 何时使用

以下请求应优先使用本 skill：
- “做个小工具 / 写个脚本 / 搭个页面 / 开发个功能”
- “修复这个 bug / 排查问题 / 重构一下 / 优化实现”
- “帮我补测试 / 写 e2e / 做 CI / 做 code review”
- “这个任务很长，你后台跑着并持续汇报”
- 用户明确提到 `Codex`、`tmux`、`BMAD`、`story`、`sprint`、`quick spec`

以下情况不要优先使用：
- 单纯知识问答
- 只需要一句命令或几行解释即可完成的小问题
- 明显不是开发任务的运营/文档/聊天请求

## 工作流

### 1) 任务分类

先快速判断任务属于哪类：
- **小型实现**：优先走 BMAD `quick-spec` → `quick-dev`
- **中大型功能**：先拆 story / plan，再进入实现
- **质量任务**：优先强调测试、review、trace、CI
- **纯 review**：要求 Codex 先做自审，再由你做二审

### 2) 生成给 Codex 的执行提示词

给 Codex 的首条提示词至少要包含：
- 任务目标
- 仓库/工作目录
- 必须使用 BMAD 方法
- 先输出计划再实施
- 编码后必须运行相关测试/检查
- 完成后做自我 review
- 如发现问题，继续修复直到收敛

建议结构：
1. 任务背景
2. 成功标准
3. BMAD 执行要求
4. 代码与测试要求
5. 输出要求（阶段进展、风险、下一步）

### 3) 启动 Codex CLI

使用脚本：
- 启动：`{baseDir}/scripts/codex_agile_start.sh`
- 采样：`{baseDir}/scripts/codex_agile_status.sh`
- 恢复：`{baseDir}/scripts/codex_agile_restart.sh`
- 标记已播报：`{baseDir}/scripts/codex_agile_mark_reported.sh`

启动方式示例：
```bash
bash {baseDir}/scripts/codex_agile_start.sh <session-name> <workdir> <prompt-file>
```

脚本会：
- 自动选择合适后端（tmux / process fallback）
- 以 Full Access 启动 Codex
- 设置 `gpt-5.4 + xhigh reasoning`
- 自动把提示词发给 Codex
- 把运行元数据写到 runtime 目录

### 4) 监控与汇报

对长任务：
- 默认每 10 分钟检查一次状态
- **只有存在活跃工作时才定时播报**
- 没有工作时不播报
- 如发现会话丢失，调用恢复脚本重启

检查方式：
```bash
bash {baseDir}/scripts/codex_agile_status.sh <session-name>
```

如果状态显示 `missing`，执行：
```bash
bash {baseDir}/scripts/codex_agile_restart.sh <session-name> <workdir> "<progress summary>"
```

### 5) Review loop

编码完成后执行双层 review：
1. **Codex 自检**：测试、lint、类型检查、关键路径 walkthrough
2. **你做二审**：看日志、关键输出、git diff、测试覆盖、边界条件
3. 如果你发现问题，把意见发回 Codex 会话继续讨论和修复
4. 直到你和 Codex 的判断收敛，再给用户最终结论

## 定时 10 分钟汇报的实现约束

本 skill 定义了**操作规范**，真正的周期播报应由 OpenClaw 的 heartbeat / cron 编排来驱动。

实现要求：
1. 监控 `~/.openclaw/skills/agile-codex/runtime` 下的状态文件。
2. **仅当 `active_work=true`、`needs_input=true`、`completed=true` 或 `missing` 需要恢复时，才对用户输出。**
3. 如果没有活跃工作，会话只是 idle / standby / 0 active task，则返回 `HEARTBEAT_OK`。
4. 监控器播报后应调用 `codex_agile_mark_reported.sh` 写回 report state，防止同一时间槽重复播报。

## 与 BMAD 协同

本机已存在 BMAD 资源。需要时可读取这些文件来选择工作流：
- `/root/.paco/bmad/_bmad/_config/workflow-manifest.csv`
- `/root/.paco/bmad/_bmad/core/config.yaml`
- `/root/.paco/bmad/_bmad/core/agents/bmad-master.md`

优先使用的 BMAD 心智模型：
- 小功能：`quick-spec` → `quick-dev`
- 中大型开发：story 分解 → `dev-story`
- 纯 review：`code-review` / `testarch-test-review`
- 测试补强：`qa-generate-e2e-tests`

## 结果交付

给用户的结果至少包括：
- 做了什么
- 当前完成到哪一步
- 是否已测试 / review
- 剩余风险
- 下一步建议

如果任务仍在进行中，给**简洁、具体、有时间感**的进度汇报，不要发空话。
