# agile-codex references

## Trigger classes

优先处理以下用户意图：
- 做个小工具 / 写个脚本 / 做个网站 / 写个页面
- 修 bug / 排查问题 / 重构 / 补测试 / 加 CI
- review 代码 / 看实现质量 / 检查测试质量
- 需要长时间编码执行、后台跟踪、持续汇报
- 明确提到 Codex、tmux、敏捷开发、BMAD、story、sprint、quick spec、PRD、架构、review

## Routing policy

如果请求属于开发执行类任务：
1. 优先使用本 skill。
2. 优先把长时编码放进后台运行的 Codex CLI，而不是在主代理里直接长篇写代码。
3. Codex CLI 参数默认：
   - model: gpt-5.4
   - model_reasoning_effort: xhigh
   - sandbox: full access（通过 `--dangerously-bypass-approvals-and-sandbox`）
   - 启用 web search（`--search`）
4. 在提示词中显式要求 Codex 采用 BMAD 方法进行分析、计划、实现、测试、review。
5. 对小改动优先走 BMAD quick-spec / quick-dev 风格；对较大任务先拆解 story / implementation plan。
6. 对跨平台宿主：
   - Linux/macOS 优先 tmux
   - Windows 优先 WSL
   - 无 tmux 时允许进程后端 fallback
   - 但对外部结果与汇报语义要保持一致

## Review loop

编码完成后，不要直接结束：
1. 让 Codex 自检：测试、lint、静态检查、关键路径 walkthrough。
2. 主代理基于日志和 diff 做第二层 review。
3. 如果发现问题，把意见再发回 Codex 会话。
4. 直到：
   - 测试通过
   - 关键风险关闭
   - Codex 给出最终交付总结

## Monitoring cadence

- 长任务默认每 10 分钟汇报一次。
- 如果任务很短，可在关键里程碑汇报。
- 如果会话丢失，优先尝试重启并恢复上下文。
- **没有工作就不汇报。**
- 只有在以下情况才触发对用户播报：
  - 当前确有 active work
  - 需要人工输入
  - 已完成
  - 会话丢失且已尝试恢复
- 仅处于 idle / standby / 0 active task 时，应静默。

## BMAD hints

本机 BMAD 资源可从这些位置获取：
- `/root/.paco/bmad/_bmad/_config/workflow-manifest.csv`
- `/root/.paco/bmad/_bmad/core/config.yaml`
- `/root/.paco/bmad/_bmad/core/agents/bmad-master.md`

常用工作流：
- quick-spec
- quick-dev
- create-story
- dev-story
- code-review
- sprint-status
- testarch-test-review
- qa-generate-e2e-tests

## Caveats

- 这是高权限流程，仅用于明确的软件开发执行任务。
- 非开发类请求不要误触发。
- 外发消息、删除生产数据、改动远端基础设施时，仍需谨慎并根据环境判断是否要先确认。
