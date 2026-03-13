import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { spawnSync } from 'node:child_process';
import { DatabaseSync } from 'node:sqlite';

const HOOK_KEY = 'memory-auto-capture';
const DEFAULTS = {
  enabled: true,
  dmOnly: true,
  maxTextLength: 1200,
  allowSummaryOnCompact: true,
  dedupeWindowSec: 21600,
  maxTaskCandidates: 5,
};

function getCfg(cfg) {
  const entries = cfg?.hooks?.internal?.entries;
  return { ...DEFAULTS, ...(entries?.[HOOK_KEY] || {}) };
}

function isDirectMessageContext(event) {
  const key = String(event?.sessionKey || '').toLowerCase();
  return key.includes(':user:') || key.includes(':dm:') || key.includes(':direct:') || key.startsWith('agent:main:feishu:user:');
}

function defaultWorkspaceDir() {
  return String(process.env.OPENCLAW_WORKSPACE || path.join(os.homedir(), '.openclaw'));
}

function resolveWorkspaceDir(event) {
  return String(event?.context?.workspaceDir || event?.context?.cfg?.workspace?.dir || defaultWorkspaceDir());
}

function resolveMemoryScriptPath(cfg, event) {
  return String(cfg?.memoryScriptPath || path.join(resolveWorkspaceDir(event), 'skills', 'local-long-memory', 'scripts', 'memory_core.py'));
}

function resolveMemoryDbPath(cfg, event) {
  return String(cfg?.memoryDbPath || path.join(resolveWorkspaceDir(event), 'skills', 'local-long-memory', 'data', 'memory.db'));
}

function buildMemoryRuntime(cfg, event) {
  return {
    cwd: resolveWorkspaceDir(event),
    scriptPath: resolveMemoryScriptPath(cfg, event),
    dbPath: resolveMemoryDbPath(cfg, event),
  };
}

function runMemory(args, runtime) {
  return spawnSync('python3', [runtime.scriptPath, ...args], {
    cwd: runtime.cwd,
    encoding: 'utf8',
    stdio: ['ignore', 'pipe', 'pipe'],
  });
}

function runMemoryJson(args, runtime) {
  const proc = runMemory(args, runtime);
  try {
    return JSON.parse(proc.stdout || '{}');
  } catch {
    return {};
  }
}

function openDb(dbPath) {
  if (!dbPath || !fs.existsSync(dbPath)) return null;
  try {
    return new DatabaseSync(dbPath, { open: true, readOnly: true });
  } catch {
    return null;
  }
}

function sanitize(text, maxLen) {
  return String(text || '').replace(/\s+/g, ' ').trim().slice(0, maxLen);
}

function normalize(text) {
  return sanitize(text, 4000).toLowerCase();
}

function tokenize(text) {
  const tokens = normalize(text).match(/[\p{L}\p{N}][\p{L}\p{N}._:-]{1,}/gu) || [];
  const stop = new Set(['这个', '那个', '以后', '默认', '记住', '验证', '通过', '失败', '请', '一下', '我的', '长期', '记忆', '自动', '写入', '正常', 'works', 'with', 'from', 'that', 'this']);
  return [...new Set(tokens.filter((t) => t.length >= 2 && !stop.has(t)))].slice(0, 24);
}

function classifyFact(text) {
  const raw = String(text || '').trim();
  const patterns = [
    { kind: 'remember', key: 'remember.explicit', re: /^(?:记住|记一下|请记住)[:：]?\s*(.+)$/u },
    { kind: 'default', key: 'preference.default', re: /^(?:以后默认|默认)[:：]?\s*(.+)$/u },
    { kind: 'preference', key: 'preference.user', re: /^(?:偏好|我偏好|我的偏好)[:：]?\s*(.+)$/u },
    { kind: 'rule', key: 'rule.explicit', re: /^(?:约定|规则)[:：]?\s*(.+)$/u },
    { kind: 'decision', key: 'decision.explicit', re: /^(?:决定|决策|结论)[:：]?\s*(.+)$/u },
    { kind: 'workaround', key: 'workaround.explicit', re: /^(?:临时方案|绕过方案|workaround)[:：]?\s*(.+)$/iu },
  ];
  for (const item of patterns) {
    const m = raw.match(item.re);
    if (m) return { value: m[1].trim(), stableKey: item.key, kind: item.kind };
  }
  return null;
}

function maybeCaptureEvent(text) {
  const raw = String(text || '').trim();
  const pass = raw.match(/^(?:验证通过|测试通过|成功了|已验证|验证成功)[:：]?\s*(.+)$/u);
  if (pass) return { type: 'verification.pass', value: pass[1].trim(), confidence: '0.95' };
  const fail = raw.match(/^(?:失败了|测试失败|验证失败)[:：]?\s*(.+)$/u);
  if (fail) return { type: 'verification.fail', value: fail[1].trim(), confidence: '0.95' };
  const decided = raw.match(/^(?:已决定|最终决定)[:：]?\s*(.+)$/u);
  if (decided) return { type: 'decision.recorded', value: decided[1].trim(), confidence: '0.9' };
  return null;
}

function deriveTaskId(text, db, maxCandidates = 5) {
  const raw = normalize(text);
  const known = [
    ['tenant', 'tenant-mode'],
    ['memory', 'local-long-memory'],
    ['windows', 'windows-tenant-parity'],
    ['browser', 'browser-docker-use'],
  ];
  for (const [token, taskId] of known) {
    if (raw.includes(token)) return taskId;
  }
  if (!db) return '';
  const rows = db.prepare(`
    SELECT task_id FROM facts WHERE task_id != ''
    UNION SELECT task_id FROM task_state WHERE task_id != ''
    UNION SELECT task_id FROM summaries WHERE task_id != ''
    UNION SELECT task_id FROM events WHERE task_id != ''
  `).all();
  const tokens = tokenize(text);
  const scored = [];
  for (const row of rows) {
    const taskId = String(row.task_id || '').trim();
    if (!taskId) continue;
    const lower = taskId.toLowerCase();
    let score = 0;
    if (raw.includes(lower)) score += 100;
    for (const part of lower.split(/[^a-z0-9]+/).filter(Boolean)) {
      if (part.length >= 3 && raw.includes(part)) score += 12;
    }
    for (const token of tokens) {
      if (lower.includes(token)) score += 4;
    }
    if (score > 0) scored.push({ taskId, score });
  }
  scored.sort((a, b) => b.score - a.score || a.taskId.localeCompare(b.taskId));
  return scored.slice(0, maxCandidates)[0]?.taskId || '';
}

function isRecentDuplicate(db, table, fields, dedupeWindowSec) {
  if (!db) return false;
  const nowEpoch = Math.floor(Date.now() / 1000);
  const threshold = nowEpoch - Math.max(0, Number(dedupeWindowSec || 0));
  const clauses = Object.keys(fields).map((key) => `${key} = ?`).join(' AND ');
  const values = Object.values(fields);
  const sql = `SELECT id FROM ${table} WHERE ${clauses} AND CAST(strftime('%s', updated_at) AS INTEGER) >= ? ORDER BY updated_at DESC LIMIT 1`;
  try {
    const row = db.prepare(sql).get(...values, threshold);
    return Boolean(row);
  } catch {
    return false;
  }
}

function putFactWithSupersede(fact, sessionKey, taskId, runtime) {
  const current = runMemoryJson(['get-current-fact', '--key', fact.stableKey, '--session-key', sessionKey, '--task-id', taskId], runtime);
  const args = ['put-fact', '--key', fact.stableKey, '--value', fact.value, '--source', 'message:preprocessed', '--session-key', sessionKey, '--task-id', taskId, '--confidence', '0.9'];
  if (current && current.id && current.value !== fact.value) {
    args.push('--supersedes', String(current.id));
  }
  runMemory(args, runtime);
}

function handleMessagePreprocessed(event) {
  if (event.type !== 'message' || event.action !== 'preprocessed') return;
  const cfg = getCfg(event.context?.cfg);
  if (cfg.enabled === false) return;
  if (cfg.dmOnly && !isDirectMessageContext(event)) return;

  const text = sanitize(event.context?.bodyForAgent || event.context?.content || event.context?.body || '', cfg.maxTextLength);
  if (!text) return;

  const sessionKey = String(event.sessionKey || '');
  const runtime = buildMemoryRuntime(cfg, event);
  const db = openDb(runtime.dbPath);
  const taskId = deriveTaskId(text, db, cfg.maxTaskCandidates);

  try {
    const fact = classifyFact(text);
    if (fact) {
      const isDup = isRecentDuplicate(db, 'facts', { key: fact.stableKey, value: fact.value, session_key: sessionKey }, cfg.dedupeWindowSec)
        || isRecentDuplicate(db, 'facts', { key: fact.stableKey, value: fact.value, task_id: taskId }, cfg.dedupeWindowSec);
      if (!isDup) {
        putFactWithSupersede(fact, sessionKey, taskId, runtime);
      }
    }

    const eventCapture = maybeCaptureEvent(text);
    if (eventCapture) {
      const isDup = isRecentDuplicate(db, 'events', { event_type: eventCapture.type, value: eventCapture.value, session_key: sessionKey }, cfg.dedupeWindowSec)
        || isRecentDuplicate(db, 'events', { event_type: eventCapture.type, value: eventCapture.value, task_id: taskId }, cfg.dedupeWindowSec);
      if (!isDup) {
        runMemory(['put-event', '--event-type', eventCapture.type, '--value', eventCapture.value, '--source', 'message:preprocessed', '--session-key', sessionKey, '--task-id', taskId, '--confidence', eventCapture.confidence], runtime);
      }
    }
  } finally {
    try { db?.close(); } catch {}
  }
}

function handleSessionCompactAfter(event) {
  if (event.type !== 'session' || event.action !== 'compact:after') return;
  const cfg = getCfg(event.context?.cfg);
  if (cfg.enabled === false || !cfg.allowSummaryOnCompact) return;
  if (cfg.dmOnly && !isDirectMessageContext(event)) return;

  const sessionKey = String(event.sessionKey || '');
  const taskId = String(event.context?.taskId || '');
  if (!sessionKey) return;

  const summaryText = sanitize(event.context?.summary || event.context?.compactionSummary || 'session compacted', cfg.maxTextLength);
  const runtime = buildMemoryRuntime(cfg, event);
  const db = openDb(runtime.dbPath);
  try {
    const isDup = isRecentDuplicate(db, 'summaries', { value: summaryText, session_key: sessionKey }, cfg.dedupeWindowSec)
      || (taskId ? isRecentDuplicate(db, 'summaries', { value: summaryText, task_id: taskId }, cfg.dedupeWindowSec) : false);
    if (!isDup) {
      runMemory(['put-summary', '--task-id', taskId, '--value', summaryText, '--source', 'session:compact:after', '--session-key', sessionKey, '--confidence', '0.6'], runtime);
    }
  } finally {
    try { db?.close(); } catch {}
  }
}

export default async function memoryAutoCaptureHook(event) {
  try {
    handleMessagePreprocessed(event);
    handleSessionCompactAfter(event);
  } catch {
    // stay quiet; hooks should not break message flow
  }
}
