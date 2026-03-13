import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { DatabaseSync } from 'node:sqlite';

const HOOK_KEY = 'memory-preload-bundle';
const DEFAULTS = {
  enabled: true,
  recentMessages: 4,
  recentScanLines: 60,
  sessionItems: 6,
  taskItems: 8,
  searchItems: 6,
  maxTaskIds: 3,
  maxChars: 4000,
  dmOnly: true,
};

function isAgentBootstrapEvent(event) {
  return event && event.type === 'agent' && event.action === 'bootstrap' && event.context;
}

function getHookConfig(cfg) {
  const entries = cfg?.hooks?.internal?.entries;
  return { ...DEFAULTS, ...(entries?.[HOOK_KEY] || {}) };
}

function defaultWorkspaceDir() {
  return String(process.env.OPENCLAW_WORKSPACE || path.join(os.homedir(), '.openclaw'));
}

function resolveWorkspaceDir(context) {
  return String(context?.workspaceDir || context?.cfg?.workspace?.dir || defaultWorkspaceDir());
}

function resolveMemoryDbPath(cfg, context) {
  return String(cfg?.memoryDbPath || path.join(resolveWorkspaceDir(context), 'skills', 'local-long-memory', 'data', 'memory.db'));
}

function isLikelyDirectSession(sessionKey) {
  const key = String(sessionKey || '').toLowerCase();
  return key.includes(':user:') || key.includes(':dm:') || key.includes(':direct:') || key.startsWith('agent:main:feishu:user:');
}

function extractText(content) {
  if (typeof content === 'string') return content;
  if (!Array.isArray(content)) return '';
  return content
    .filter((item) => item && item.type === 'text' && typeof item.text === 'string')
    .map((item) => item.text)
    .join('\n')
    .trim();
}

function readRecentUserTexts(sessionFile, maxMessages = 4, scanLines = 60) {
  if (!sessionFile || !fs.existsSync(sessionFile)) return [];
  const lines = fs.readFileSync(sessionFile, 'utf8').split(/\r?\n/).filter(Boolean);
  const recent = [];
  for (const line of lines.slice(-scanLines).reverse()) {
    try {
      const obj = JSON.parse(line);
      if (obj?.type !== 'message') continue;
      const msg = obj.message;
      if (!msg || msg.role !== 'user') continue;
      const text = extractText(msg.content).trim();
      if (!text || text.startsWith('/')) continue;
      recent.push(text);
      if (recent.length >= maxMessages) break;
    } catch {}
  }
  return recent.reverse();
}

function normalize(text) {
  return String(text || '').toLowerCase().replace(/\s+/g, ' ').trim();
}

function tokenize(text) {
  const tokens = normalize(text)
    .match(/[\p{L}\p{N}][\p{L}\p{N}._:-]{1,}/gu) || [];
  const stop = new Set(['this','that','with','from','then','have','need','into','true','false','null','local','memory','skill','openclaw','继续','很好','需要','把','这个','进行','真正','接入','会话','查询','流程']);
  return [...new Set(tokens.filter((t) => t.length >= 2 && !stop.has(t)))].slice(0, 24);
}

function redact(text) {
  return String(text || '')
    .replace(/\b(sk-[A-Za-z0-9_-]{8,})\b/g, '[REDACTED_API_KEY]')
    .replace(/\b(github_pat_[A-Za-z0-9_]{8,})\b/g, '[REDACTED_GITHUB_PAT]')
    .replace(/\b(cli_[A-Za-z0-9]{8,})\b/g, '[REDACTED_APP_ID]')
    .replace(/\b([A-Za-z0-9]{24,})\b/g, (m) => (/^[A-Za-z0-9+/=]{24,}$/.test(m) ? '[REDACTED_TOKEN]' : m));
}

function openDb(dbPath) {
  if (!dbPath || !fs.existsSync(dbPath)) return null;
  return new DatabaseSync(dbPath, { open: true, readOnly: true });
}

function inferTaskIds(db, text, maxTaskIds) {
  const rows = db.prepare(`
    SELECT task_id FROM facts WHERE task_id != ''
    UNION SELECT task_id FROM task_state WHERE task_id != ''
    UNION SELECT task_id FROM summaries WHERE task_id != ''
    UNION SELECT task_id FROM events WHERE task_id != ''
  `).all();
  const hay = normalize(text);
  const queryTokens = tokenize(text);
  const taskIds = rows.map((r) => String(r.task_id || '').trim()).filter(Boolean);
  const scored = [];
  for (const taskId of taskIds) {
    const lower = taskId.toLowerCase();
    let score = 0;
    if (hay.includes(lower)) score += 100;
    for (const part of lower.split(/[^a-z0-9]+/).filter(Boolean)) {
      if (part.length >= 3 && hay.includes(part)) score += 12;
    }
    for (const token of queryTokens) {
      if (lower.includes(token)) score += 4;
    }
    if (score > 0) scored.push({ taskId, score });
  }
  scored.sort((a, b) => b.score - a.score || a.taskId.localeCompare(b.taskId));
  const best = scored[0]?.score || 0;
  const minScore = Math.max(12, best >= 100 ? 16 : Math.floor(best * 0.6));
  return scored.filter((x) => x.score >= minScore).slice(0, maxTaskIds).map((x) => x.taskId);
}

function querySessionRows(db, sessionKey, limit) {
  if (!sessionKey) return [];
  return db.prepare(`
    SELECT * FROM (
      SELECT 'fact' AS kind, id, key AS title, value, scope, source, session_key, task_id, confidence, updated_at FROM facts WHERE session_key = ? AND id NOT IN (SELECT supersedes FROM facts WHERE supersedes IS NOT NULL)
      UNION ALL
      SELECT 'task_state' AS kind, id, status AS title, value, scope, source, session_key, task_id, confidence, updated_at FROM task_state WHERE session_key = ?
      UNION ALL
      SELECT 'summary' AS kind, id, task_id AS title, value, scope, source, session_key, task_id, confidence, updated_at FROM summaries WHERE session_key = ?
      UNION ALL
      SELECT 'event' AS kind, id, event_type AS title, value, scope, source, session_key, task_id, confidence, updated_at FROM events WHERE session_key = ?
    ) ORDER BY updated_at DESC LIMIT ?
  `).all(sessionKey, sessionKey, sessionKey, sessionKey, limit);
}

function queryTaskRows(db, taskId, limit) {
  return db.prepare(`
    SELECT * FROM (
      SELECT 'fact' AS kind, id, key AS title, value, scope, source, session_key, task_id, confidence, updated_at FROM facts WHERE task_id = ? AND session_key = '' AND id NOT IN (SELECT supersedes FROM facts WHERE supersedes IS NOT NULL)
      UNION ALL
      SELECT 'task_state' AS kind, id, status AS title, value, scope, source, session_key, task_id, confidence, updated_at FROM task_state WHERE task_id = ? AND session_key = ''
      UNION ALL
      SELECT 'summary' AS kind, id, task_id AS title, value, scope, source, session_key, task_id, confidence, updated_at FROM summaries WHERE task_id = ? AND session_key = ''
      UNION ALL
      SELECT 'event' AS kind, id, event_type AS title, value, scope, source, session_key, task_id, confidence, updated_at FROM events WHERE task_id = ? AND session_key = ''
    ) ORDER BY updated_at DESC LIMIT ?
  `).all(taskId, taskId, taskId, taskId, limit);
}

function querySearchRows(db, tokens, limit) {
  if (!tokens.length) return [];
  const expr = tokens.map((t) => `"${t.replace(/"/g, '""')}"`).join(' OR ');
  const rows = [];
  const queries = [
    `SELECT 'fact' AS kind, base.id, base.key AS title, base.value, base.scope, base.source, base.session_key, base.task_id, base.confidence, base.updated_at
     FROM facts_fts idx JOIN facts base ON base.id = idx.rowid
     LEFT JOIN facts newer ON newer.supersedes = base.id
     WHERE facts_fts MATCH ? AND newer.id IS NULL ORDER BY base.updated_at DESC LIMIT ?`,
    `SELECT 'task_state' AS kind, base.id, base.status AS title, base.value, base.scope, base.source, base.session_key, base.task_id, base.confidence, base.updated_at
     FROM task_state_fts idx JOIN task_state base ON base.id = idx.rowid
     WHERE task_state_fts MATCH ? ORDER BY base.updated_at DESC LIMIT ?`,
    `SELECT 'summary' AS kind, base.id, base.task_id AS title, base.value, base.scope, base.source, base.session_key, base.task_id, base.confidence, base.updated_at
     FROM summaries_fts idx JOIN summaries base ON base.id = idx.rowid
     WHERE summaries_fts MATCH ? ORDER BY base.updated_at DESC LIMIT ?`,
    `SELECT 'event' AS kind, base.id, base.event_type AS title, base.value, base.scope, base.source, base.session_key, base.task_id, base.confidence, base.updated_at
     FROM events_fts idx JOIN events base ON base.id = idx.rowid
     WHERE events_fts MATCH ? ORDER BY base.updated_at DESC LIMIT ?`,
  ];
  for (const sql of queries) {
    try {
      rows.push(...db.prepare(sql).all(expr, limit));
    } catch {}
  }
  return rows;
}

function queryGlobalPolicyRows(db, limit) {
  return db.prepare(`
    SELECT 'fact' AS kind, id, key AS title, value, scope, source, session_key, task_id, confidence, updated_at
    FROM facts
    WHERE session_key = '' AND task_id = '' AND key IN ('preference.default', 'preference.user', 'rule.explicit', 'remember.explicit', 'decision.explicit', 'workaround.explicit')
      AND id NOT IN (SELECT supersedes FROM facts WHERE supersedes IS NOT NULL)
    ORDER BY updated_at DESC LIMIT ?
  `).all(limit);
}

function classifyIntent(queryText) {
  const q = normalize(queryText);
  if (/(默认|偏好|规则|约定|应该|记住|习惯)/u.test(q)) return 'policy';
  if (/(验证|测试|通过|失败|结果|成功|报错|error|bug)/u.test(q)) return 'verification';
  if (/(决定|结论|方案|为什么这样|为何这样)/u.test(q)) return 'decision';
  if (/(进度|状态|到哪了|目前|现在|当前)/u.test(q)) return 'status';
  return 'general';
}

function classifyRecency(row) {
  const title = normalize(row.title || '');
  const value = normalize(row.value || '');
  if (row.kind === 'event') return 'short';
  if (row.kind === 'task_state') return 'short';
  if (title.includes('port') || value.includes('port') || value.includes('gateway') || value.includes('vnc')) return 'short';
  if (title.includes('preference') || title.includes('rule') || title.includes('remember') || title.includes('decision') || title.includes('workaround')) return 'long';
  if (row.kind === 'fact') return 'medium';
  if (row.kind === 'summary') return 'medium';
  return 'medium';
}

function recencyBonus(row) {
  const updated = Date.parse(String(row.updated_at || ''));
  if (Number.isNaN(updated)) return 0;
  const ageHours = Math.max(0, (Date.now() - updated) / 3600000);
  const klass = classifyRecency(row);
  if (klass === 'short') return Math.max(-25, 18 - ageHours * 3.5);
  if (klass === 'medium') return Math.max(-10, 20 - ageHours * 1.2);
  return Math.max(0, 12 - ageHours * 0.25);
}

function scopePriority(row, sessionKey, inferredTaskIds) {
  if (row.session_key && row.session_key === sessionKey) return 3;
  if (row.task_id && inferredTaskIds.includes(row.task_id)) return 2;
  return 1;
}

function intentBonus(row, intent) {
  const title = normalize(row.title || '');
  const kind = row.kind;
  if (intent === 'policy') {
    if (title.startsWith('preference.') || title.startsWith('rule.') || title.startsWith('remember.')) return 26;
    if (title.startsWith('decision.') || title.startsWith('workaround.')) return 8;
    if (kind === 'event' || kind === 'task_state') return -8;
  }
  if (intent === 'verification') {
    if (kind === 'event' && title.startsWith('verification.')) return 28;
    if (kind === 'task_state') return 10;
    if (title.startsWith('preference.') || title.startsWith('rule.')) return -6;
  }
  if (intent === 'decision') {
    if (title.startsWith('decision.')) return 24;
    if (kind === 'summary') return 8;
    if (kind === 'event' && title.startsWith('decision.')) return 12;
  }
  if (intent === 'status') {
    if (kind === 'task_state') return 24;
    if (kind === 'event') return 8;
    if (kind === 'summary') return 6;
    if (title.startsWith('preference.') || title.startsWith('rule.')) return -8;
  }
  return 0;
}

function scoreRow(row, queryText, queryTokens, inferredTaskIds, sessionKey, intent) {
  const hay = normalize(`${row.title || ''} ${row.value || ''} ${row.task_id || ''} ${row.scope || ''}`);
  let score = Number(row.confidence || 0) * 100;
  const scopeLevel = scopePriority(row, sessionKey, inferredTaskIds);
  score += scopeLevel * 22;
  if (row.kind === 'fact') score += 40;
  else if (row.kind === 'event') score += 18;
  else if (row.kind === 'task_state') score += 14;
  else if (row.kind === 'summary') score += 8;
  const title = normalize(row.title || '');
  if (title.startsWith('preference.')) score += 18;
  if (title.startsWith('rule.')) score += 16;
  if (title.startsWith('remember.')) score += 12;
  if (title.startsWith('decision.')) score += 14;
  if (title.startsWith('workaround.')) score += 10;
  if (row.session_key && row.session_key === sessionKey) score += 30;
  if (row.task_id && inferredTaskIds.includes(row.task_id)) score += 40;
  if (queryText && hay.includes(queryText)) score += 25;
  for (const token of queryTokens) {
    if (hay.includes(token)) score += 6;
  }
  score += intentBonus(row, intent);
  score += recencyBonus(row);
  return score;
}

function dedupeAndRankRows(rows, queryText, inferredTaskIds, sessionKey, limit) {
  const seen = new Set();
  const queryTokens = tokenize(queryText);
  const intent = classifyIntent(queryText);
  const ranked = [];
  for (const row of rows) {
    const key = `${row.kind}:${row.id}`;
    if (seen.has(key)) continue;
    seen.add(key);
    ranked.push({ ...row, _score: scoreRow(row, normalize(queryText), queryTokens, inferredTaskIds, sessionKey, intent) });
  }
  ranked.sort((a, b) => b._score - a._score || String(b.updated_at).localeCompare(String(a.updated_at)));
  return ranked.slice(0, limit);
}

function isCompatibleSearchHit(row, sessionKey, inferredTaskIds) {
  if (row.session_key) return row.session_key === sessionKey;
  if (row.task_id) return inferredTaskIds.includes(row.task_id);
  return true;
}

function renderRows(rows) {
  return rows.map((row) => {
    const bits = [];
    bits.push(`[${row.kind}]`);
    if (row.task_id) bits.push(`task=${row.task_id}`);
    if (row.title) bits.push(`${row.title}`);
    const head = bits.join(' ');
    const value = redact(String(row.value || '').replace(/\s+/g, ' ').trim()).slice(0, 240);
    const meta = [row.scope ? `scope=${row.scope}` : '', row.updated_at || '', row._score != null ? `score=${Math.round(row._score)}` : ''].filter(Boolean).join(' · ');
    return `- ${head}: ${value}${meta ? ` (${meta})` : ''}`;
  }).join('\n');
}

function trimBlock(text, maxChars) {
  if (text.length <= maxChars) return text;
  return text.slice(0, Math.max(0, maxChars - 24)).trimEnd() + '\n\n[truncated]';
}

function injectIntoMemoryFile(context, bundleText) {
  const files = context.bootstrapFiles || [];
  const target = files.find((f) => f && f.name === 'MEMORY.md' && !f.missing);
  if (!target) return false;
  const original = typeof target.content === 'string' ? target.content : '';
  const markerStart = '\n\n## Dynamic Memory Bundle\n';
  const injected = `${original}${markerStart}${bundleText}\n`;
  target.content = injected;
  return true;
}

export default async function memoryPreloadBundleHook(event) {
  if (!isAgentBootstrapEvent(event)) return;
  const context = event.context;
  const cfg = getHookConfig(context.cfg);
  if (cfg.enabled === false) return;
  if (cfg.dmOnly && !isLikelyDirectSession(event.sessionKey)) return;
  if (!Array.isArray(context.bootstrapFiles) || !context.bootstrapFiles.some((f) => f?.name === 'MEMORY.md' && !f.missing)) return;

  const workspaceDir = resolveWorkspaceDir(context);
  const agentId = context.agentId || 'main';
  const sessionsDir = path.join(workspaceDir, 'agents', agentId, 'sessions');
  const sessionFile = context.sessionId ? path.join(sessionsDir, `${context.sessionId}.jsonl`) : null;
  const recentTexts = readRecentUserTexts(sessionFile, cfg.recentMessages, cfg.recentScanLines);
  const queryText = recentTexts.join('\n').trim();
  if (!queryText) return;

  const db = openDb(resolveMemoryDbPath(cfg, context));
  if (!db) return;

  try {
    const tokens = tokenize(queryText);
    const taskIds = inferTaskIds(db, queryText, cfg.maxTaskIds);
    const intent = classifyIntent(queryText);
    const sessionRows = querySessionRows(db, event.sessionKey, cfg.sessionItems);
    const taskRows = taskIds.flatMap((taskId) => queryTaskRows(db, taskId, cfg.taskItems));
    const searchRows = querySearchRows(db, tokens, cfg.searchItems);
    const policyFallbackRows = intent === 'policy' ? queryGlobalPolicyRows(db, Math.max(2, Math.min(4, cfg.searchItems))) : [];
    const ranked = dedupeAndRankRows([...sessionRows, ...taskRows, ...searchRows, ...policyFallbackRows], queryText, taskIds, event.sessionKey, Math.max(cfg.sessionItems, cfg.taskItems, cfg.searchItems) * 2);

    if (ranked.length === 0) return;

    const sessionScoped = ranked.filter((row) => row.session_key && row.session_key === event.sessionKey).slice(0, cfg.sessionItems);
    const taskScoped = ranked.filter((row) => row.task_id && taskIds.includes(row.task_id) && !row.session_key).slice(0, cfg.taskItems);
    const searchHits = ranked
      .filter((row) => !sessionScoped.includes(row) && !taskScoped.includes(row))
      .filter((row) => isCompatibleSearchHit(row, event.sessionKey, taskIds))
      .slice(0, cfg.searchItems);

    const sections = [];
    sections.push('Generated from local-long-memory before this turn.');
    sections.push(`- recent query basis: ${redact(queryText).replace(/\s+/g, ' ').slice(0, 280)}`);
    if (taskIds.length) sections.push(`- inferred task ids: ${taskIds.join(', ')}`);
    sections.push(`- inferred recall intent: ${intent}`);

    if (sessionScoped.length) {
      sections.push('\n### Session-scoped recall');
      sections.push(renderRows(sessionScoped));
    }
    if (taskScoped.length) {
      sections.push('\n### Task-scoped recall');
      sections.push(renderRows(taskScoped));
    }
    if (searchHits.length) {
      sections.push('\n### Search hits');
      sections.push(renderRows(searchHits));
    }

    const bundle = trimBlock(sections.join('\n'), cfg.maxChars);
    injectIntoMemoryFile(context, bundle);
  } finally {
    try { db.close(); } catch {}
  }
}
