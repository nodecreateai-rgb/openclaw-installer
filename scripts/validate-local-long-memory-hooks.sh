#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/local-long-memory-hooks.XXXXXX")"
WORKSPACE="$WORK_DIR/workspace/.openclaw"
WORKSPACE_CFG_ONLY="$WORK_DIR/workspace-cfg/.openclaw"
SKILL_SRC="$ROOT_DIR/bundled-skills/local-long-memory"
SKILL_DST="$WORKSPACE/skills/local-long-memory"
SKILL_DST_CFG_ONLY="$WORKSPACE_CFG_ONLY/skills/local-long-memory"
SESSION_DIR="$WORKSPACE/agents/main/sessions"
SESSION_DIR_CFG_ONLY="$WORKSPACE_CFG_ONLY/agents/main/sessions"

log() {
  printf '[local-long-memory-hooks] %s\n' "$*"
}

fail() {
  printf '[local-long-memory-hooks] ERROR: %s\n' "$*" >&2
  exit 1
}

cleanup() {
  if [[ "${KEEP_VALIDATION_WORKDIR:-0}" != "1" ]]; then
    rm -rf "$WORK_DIR"
  else
    log "keeping workdir: $WORK_DIR"
  fi
}
trap cleanup EXIT

need_bin() {
  command -v "$1" >/dev/null 2>&1 || fail "missing required binary: $1"
}

need_bin node
need_bin python3

mkdir -p "$WORKSPACE/skills" "$SESSION_DIR" "$WORKSPACE_CFG_ONLY/skills" "$SESSION_DIR_CFG_ONLY"
cp -a "$SKILL_SRC" "$SKILL_DST"
cp -a "$SKILL_SRC" "$SKILL_DST_CFG_ONLY"

cat > "$SESSION_DIR/test-session.jsonl" <<'EOF'
{"type":"message","message":{"role":"user","content":[{"type":"text","text":"继续 tenant mode，记住默认走 proxy，并关注 windows smoke 结果"}]}}
EOF
cp "$SESSION_DIR/test-session.jsonl" "$SESSION_DIR_CFG_ONLY/test-session.jsonl"

log 'running hook integration scenario'
ROOT_DIR="$ROOT_DIR" WORK_DIR="$WORK_DIR" WORKSPACE="$WORKSPACE" WORKSPACE_CFG_ONLY="$WORKSPACE_CFG_ONLY" node --input-type=module <<'NODE'
import fs from 'node:fs';
import path from 'node:path';
import { pathToFileURL } from 'node:url';

const root = process.env.ROOT_DIR;
const workDir = process.env.WORK_DIR;
const workspace = process.env.WORKSPACE;
const workspaceCfgOnly = process.env.WORKSPACE_CFG_ONLY;
const sessionKey = 'agent:main:feishu:user:test';
const dbPath = path.join(workspace, 'skills', 'local-long-memory', 'data', 'memory.db');
const scriptPath = path.join(workspace, 'skills', 'local-long-memory', 'scripts', 'memory_core.py');

const cfg = {
  hooks: {
    internal: {
      entries: {
        'memory-auto-capture': {
          enabled: true,
          dmOnly: true,
          memoryDbPath: dbPath,
          memoryScriptPath: scriptPath,
          allowSummaryOnCompact: true,
          dedupeWindowSec: 21600,
          maxTaskCandidates: 5,
        },
        'memory-preload-bundle': {
          enabled: true,
          dmOnly: true,
          memoryDbPath: dbPath,
          recentMessages: 4,
          sessionItems: 6,
          taskItems: 8,
          searchItems: 6,
          maxTaskIds: 3,
          maxChars: 4000,
        },
      },
    },
  },
  workspace: {
    dir: workspace,
  },
};

const cfgWorkspaceOnly = {
  hooks: {
    internal: {
      entries: {
        'memory-auto-capture': {
          enabled: true,
          dmOnly: true,
          allowSummaryOnCompact: true,
          dedupeWindowSec: 21600,
          maxTaskCandidates: 5,
        },
        'memory-preload-bundle': {
          enabled: true,
          dmOnly: true,
          recentMessages: 4,
          sessionItems: 6,
          taskItems: 8,
          searchItems: 6,
          maxTaskIds: 3,
          maxChars: 4000,
        },
      },
    },
  },
  workspace: {
    dir: workspaceCfgOnly,
  },
};

const autoCapture = (await import(pathToFileURL(path.join(root, 'bundled-skills/local-long-memory/hooks/memory-auto-capture/handler.js')).href)).default;
const preload = (await import(pathToFileURL(path.join(root, 'bundled-skills/local-long-memory/hooks/memory-preload-bundle/handler.js')).href)).default;

await autoCapture({
  type: 'message',
  action: 'preprocessed',
  sessionKey,
  context: {
    workspaceDir: workspace,
    cfg,
    bodyForAgent: '记住: 以后默认 tenant 模式走 proxy',
  },
});

await autoCapture({
  type: 'message',
  action: 'preprocessed',
  sessionKey,
  context: {
    workspaceDir: workspace,
    cfg,
    bodyForAgent: '验证通过: windows tenant custom smoke ok',
  },
});

await autoCapture({
  type: 'session',
  action: 'compact:after',
  sessionKey,
  context: {
    workspaceDir: workspace,
    cfg,
    taskId: 'tenant-mode',
    summary: 'tenant-mode 阶段总结: windows parity aligned',
  },
});

const memoryFile = { name: 'MEMORY.md', content: '# MEMORY.md\n', missing: false };
await preload({
  type: 'agent',
  action: 'bootstrap',
  sessionKey,
  context: {
    workspaceDir: workspace,
    cfg,
    agentId: 'main',
    sessionId: 'test-session',
    bootstrapFiles: [memoryFile],
  },
});

await autoCapture({
  type: 'message',
  action: 'preprocessed',
  sessionKey,
  context: {
    cfg: cfgWorkspaceOnly,
    bodyForAgent: '记住: cfg workspace fallback should keep host installs working',
  },
});

await autoCapture({
  type: 'session',
  action: 'compact:after',
  sessionKey,
  context: {
    cfg: cfgWorkspaceOnly,
    taskId: 'tenant-mode',
    summary: 'cfg workspace fallback summary',
  },
});

const memoryFileCfgOnly = { name: 'MEMORY.md', content: '# MEMORY.md\n', missing: false };
await preload({
  type: 'agent',
  action: 'bootstrap',
  sessionKey,
  context: {
    cfg: cfgWorkspaceOnly,
    agentId: 'main',
    sessionId: 'test-session',
    bootstrapFiles: [memoryFileCfgOnly],
  },
});

fs.writeFileSync(path.join(workDir, 'node-result.json'), JSON.stringify({
  explicit: {
    memoryInjected: memoryFile.content.includes('## Dynamic Memory Bundle'),
    memoryContent: memoryFile.content,
  },
  cfgWorkspaceOnly: {
    memoryInjected: memoryFileCfgOnly.content.includes('## Dynamic Memory Bundle'),
    memoryContent: memoryFileCfgOnly.content,
  },
}, null, 2));
NODE

python3 - <<'PY' "$WORKSPACE" "$WORKSPACE_CFG_ONLY" "$WORK_DIR/node-result.json"
import json
import sqlite3
import sys
from pathlib import Path

workspace = Path(sys.argv[1])
workspace_cfg_only = Path(sys.argv[2])
node_result = json.loads(Path(sys.argv[3]).read_text(encoding='utf-8'))
db_path = workspace / 'skills' / 'local-long-memory' / 'data' / 'memory.db'
if not db_path.exists():
    raise SystemExit(f'memory db missing: {db_path}')

conn = sqlite3.connect(db_path)
fact = conn.execute("SELECT key, value FROM facts ORDER BY id DESC LIMIT 1").fetchone()
event = conn.execute("SELECT event_type, value FROM events ORDER BY id DESC LIMIT 1").fetchone()
summary = conn.execute("SELECT value FROM summaries ORDER BY id DESC LIMIT 1").fetchone()
conn.close()

assert fact is not None, 'fact not written'
assert event is not None, 'event not written'
assert summary is not None, 'summary not written'
assert fact[0] == 'remember.explicit', fact
assert 'tenant 模式走 proxy' in fact[1], fact
assert event[0] == 'verification.pass', event
assert 'windows tenant custom smoke ok' in event[1], event
assert 'windows parity aligned' in summary[0], summary
assert node_result['explicit']['memoryInjected'] is True, node_result
assert 'Dynamic Memory Bundle' in node_result['explicit']['memoryContent'], node_result
assert 'tenant-mode' in node_result['explicit']['memoryContent'], node_result

cfg_db_path = workspace_cfg_only / 'skills' / 'local-long-memory' / 'data' / 'memory.db'
if not cfg_db_path.exists():
    raise SystemExit(f'cfg-only memory db missing: {cfg_db_path}')

cfg_conn = sqlite3.connect(cfg_db_path)
cfg_fact = cfg_conn.execute("SELECT key, value FROM facts ORDER BY id DESC LIMIT 1").fetchone()
cfg_summary = cfg_conn.execute("SELECT value FROM summaries ORDER BY id DESC LIMIT 1").fetchone()
cfg_conn.close()

assert cfg_fact is not None, 'cfg-only fact not written'
assert cfg_summary is not None, 'cfg-only summary not written'
assert cfg_fact[0] == 'remember.explicit', cfg_fact
assert 'cfg workspace fallback' in cfg_fact[1], cfg_fact
assert 'cfg workspace fallback summary' in cfg_summary[0], cfg_summary
assert node_result['cfgWorkspaceOnly']['memoryInjected'] is True, node_result
assert 'Dynamic Memory Bundle' in node_result['cfgWorkspaceOnly']['memoryContent'], node_result
assert 'cfg workspace fallback' in node_result['cfgWorkspaceOnly']['memoryContent'], node_result
print('local-long-memory-hooks=PASS')
PY
