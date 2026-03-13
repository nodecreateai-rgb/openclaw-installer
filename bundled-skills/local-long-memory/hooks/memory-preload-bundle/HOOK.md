---
name: memory-preload-bundle
description: "Build a small scoped memory bundle from local-long-memory before each run"
homepage: https://docs.openclaw.ai/automation/hooks
metadata:
  {
    "openclaw":
      {
        "emoji": "🧠",
        "events": ["agent:bootstrap"],
        "requires": { "config": ["workspace.dir"] },
      },
  }
---

# Memory Preload Bundle Hook

在 `agent:bootstrap` 阶段，为当前会话生成一个**小而精确**的动态 memory bundle，并把它注入到本轮上下文里。

## 目标

- 让 `local-long-memory` 不只是“已安装”，而是真的参与每轮会话前的按需召回
- 默认优先走 `session_key / task_id` scoped recall
- 控制 bundle 大小，避免把上下文塞爆

## 行为

1. 从当前 session 最近几条用户消息提取 query 文本
2. 尝试推断相关 `task_id`
3. 从本地 SQLite memory 中优先查询：
   - session scoped
   - task scoped
   - 小范围全文命中
4. 生成一个短小 markdown bundle
5. 追加注入到当前轮的 `MEMORY.md`

## 配置

```json
{
  "hooks": {
    "internal": {
      "enabled": true,
        "entries": {
        "memory-preload-bundle": {
          "enabled": true,
          "recentMessages": 4,
          "sessionItems": 6,
          "taskItems": 8,
          "searchItems": 6,
          "maxTaskIds": 3,
          "maxChars": 4000,
          "dmOnly": true
        }
      }
    }
  }
}
```

`memoryDbPath` 默认跟随 `workspace.dir`，指向 `workspace.dir/skills/local-long-memory/data/memory.db`。只有需要覆盖默认位置时才显式填写。

## 安全/性能约束

- 默认只在 direct/main session 注入
- 默认小结果集
- 没有命中时不注入
- 只追加动态块，不覆盖原始 `MEMORY.md`
- 对疑似 secret/token 做基础脱敏
