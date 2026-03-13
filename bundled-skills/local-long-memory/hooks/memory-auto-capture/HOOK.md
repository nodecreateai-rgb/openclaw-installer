---
name: memory-auto-capture
description: "Capture high-signal chat facts/events into local-long-memory on message preprocessing and session compaction"
homepage: https://docs.openclaw.ai/automation/hooks
metadata:
  {
    "openclaw":
      {
        "emoji": "📝",
        "events": ["message:preprocessed", "session:compact:after"],
        "requires": { "config": ["workspace.dir"] },
      },
  }
---

# Memory Auto Capture Hook

把真实聊天中的**高信号内容**写入 `local-long-memory`，并在会话压缩后做阶段性 summary 收敛。

## 设计原则

- **不是每条消息都写长期记忆**
- 只捕获高确定性、高价值、可复用的信息
- 闲聊、寒暄、低信号文本不入库
- 写入分为：
  - 实时 facts / events
  - 延迟 summaries

## 事件

### message:preprocessed
适合实时写入：
- 明确偏好
- 明确“记住这个”
- 约定/规则
- 验证通过/失败结论

### session:compact:after
适合做阶段 summary：
- 会话阶段收敛
- 任务阶段总结
- 避免把所有对话原文直接入库
