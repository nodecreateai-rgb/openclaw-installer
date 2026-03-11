# using-superpowers references

## Purpose

这个 skill 是一个全局前置路由器兼轻量协调器，不直接完成复杂任务，而是负责：
- 识别用户真实意图
- 判断是否存在更具体的 skill
- 优先把任务交给最合适的 skill
- 在确实必要时做多-skill 协调
- 减少误用、漏用、乱用、乱并发

## Routing priorities

### 1. 开发执行类任务
优先路由到 `agile-codex`，典型触发词：
- 做个小工具
- 写脚本 / 写页面 / 做功能
- 修 bug / 排查 / 重构 / 优化
- 加测试 / e2e / CI / code review
- 长时间后台编码 / tmux / Codex / BMAD

### 2. Feishu 任务
根据上下文路由：
- 文档 / docx / 评论 → `feishu-doc`
- drive / 文件夹 / 云空间 → `feishu-drive`
- 分享 / 权限 / 协作者 → `feishu-perm`
- wiki / 知识库 → `feishu-wiki`
- 任务 / task / subtasks → `feishu-task`
- urgent / buzz / 催办 → `feishu-urgent`

### 3. 机器安全/巡检
- 安全审计 / SSH / firewall / 更新加固 → `healthcheck`

### 4. 技能设计
- 创建 skill / 修改 skill / 包装 skill → `skill-creator`

### 5. 天气
- 天气 / 温度 / forecast → `weather`

## Coordination rules

### A. 先判断是否需要协调
只有满足以下情况才协调：
1. 任务天然跨多个能力域，单 skill 不能闭环。
2. 某一步明确依赖前一步结果。
3. 存在彼此独立、可并发的子任务。
4. 不协调会明显损害正确率、稳定性或效率。

否则：直接选一个最具体的 skill 执行。

### B. 串行规则
当 B 依赖 A 的输出、状态、登录结果、环境检查结果或人工确认结果时：
- 先执行 A
- A 完成后再移交 B
- A 未完成或不确定时，不启动 B

典型例子：
- 先 `browser-use` 登录/取页面信息，再交给 `agile-codex` 实现
- 先 `feishu-doc` 读文档，再交给 `agile-codex` 生成/修改配套代码

### C. 并行规则
只有在以下条件同时满足时才并发：
- 子任务彼此独立
- 不共享脆弱状态（如同一登录态、同一临时文件、同一会话锁）
- 不因先后顺序不同而影响结果
- 并发后仍能清晰汇总

典型例子：
- `browser-use` 采集公开页面信息，同时 `agile-codex` 在本地改与采集无关的代码
- 一个子任务查资料，另一个子任务整理已有本地文档

### D. 必须先澄清的情况
遇到以下情况，不要自主硬协调，先确认：
- 账号密码、短信验证码、OTP、登录授权
- 删除、发布、付款、对外发送、提交到生产
- 用户目标含糊，拆错就会走偏
- 并发可能引发冲突或副作用

### E. 收口规则
不管内部是否用了多个 skill / subagent：
- 最终由主代理统一收口输出
- 不把碎片化中间状态直接甩给用户
- 优先给用户结论、状态和下一步

## Decision rules

1. 如果存在一个明显更具体的 skill，优先用它。
2. 如果多个 skill 都可能适用，先判断是否真需要协调；需要时再选串行或并行。
3. 如果没有明显 skill，回退到常规代理处理。
4. 不要为了“用 skill 而用 skill”。
5. 不要为了“并发而并发”。
6. 对用户意图不明确时，先澄清再路由。

## Version awareness

当需要判断某些能力是否存在、某技能是否应该被调用、或者用户明确提到 using-superpowers / OpenClaw 版本兼容性时：
- 先用 `openclaw --version` 或 `openclaw status` 确认版本
- 路由与协调规则以当前本地运行时能力为准

## Special note for agile-codex

对于任何“实现型软件开发请求”，优先考虑：
- 这是不是应该交给 `agile-codex`？
- 是否需要浏览器/文档/外部信息作为前置输入？
- 是否真的需要并发，还是先取结果再编码更稳？

如果答案是“主要是实现”，优先由 `agile-codex` 执行；其他 skill 只作为前置输入或并行辅助，而不是反过来主导整个任务。
