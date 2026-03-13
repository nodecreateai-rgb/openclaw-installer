#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import sqlite3
import sys
from datetime import datetime, timezone
from pathlib import Path

BASE_DIR = Path(__file__).resolve().parents[1]
DATA_DIR = BASE_DIR / 'data'
DB_PATH = DATA_DIR / 'memory.db'


def now_iso() -> str:
    return datetime.now(timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ')


def connect() -> sqlite3.Connection:
    DATA_DIR.mkdir(parents=True, exist_ok=True)
    conn = sqlite3.connect(DB_PATH)
    conn.row_factory = sqlite3.Row
    conn.execute('PRAGMA journal_mode=WAL;')
    conn.execute('PRAGMA synchronous=NORMAL;')
    conn.execute('PRAGMA foreign_keys=ON;')
    conn.execute('PRAGMA temp_store=MEMORY;')
    return conn


def init_db(conn: sqlite3.Connection) -> None:
    conn.executescript(
        '''
        CREATE TABLE IF NOT EXISTS facts (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            key TEXT NOT NULL,
            value TEXT NOT NULL,
            scope TEXT NOT NULL DEFAULT 'global',
            source TEXT NOT NULL DEFAULT '',
            session_key TEXT NOT NULL DEFAULT '',
            task_id TEXT NOT NULL DEFAULT '',
            confidence REAL NOT NULL DEFAULT 1.0,
            supersedes INTEGER,
            created_at TEXT NOT NULL,
            updated_at TEXT NOT NULL
        );
        CREATE INDEX IF NOT EXISTS idx_facts_key ON facts(key);
        CREATE INDEX IF NOT EXISTS idx_facts_task_id ON facts(task_id);
        CREATE INDEX IF NOT EXISTS idx_facts_session_key ON facts(session_key);
        CREATE INDEX IF NOT EXISTS idx_facts_scope ON facts(scope);
        CREATE INDEX IF NOT EXISTS idx_facts_updated_at ON facts(updated_at DESC);
        CREATE INDEX IF NOT EXISTS idx_facts_supersedes ON facts(supersedes);

        CREATE TABLE IF NOT EXISTS task_state (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            task_id TEXT NOT NULL,
            status TEXT NOT NULL,
            value TEXT NOT NULL,
            scope TEXT NOT NULL DEFAULT 'task',
            source TEXT NOT NULL DEFAULT '',
            session_key TEXT NOT NULL DEFAULT '',
            confidence REAL NOT NULL DEFAULT 1.0,
            supersedes INTEGER,
            created_at TEXT NOT NULL,
            updated_at TEXT NOT NULL
        );
        CREATE INDEX IF NOT EXISTS idx_task_state_task_id ON task_state(task_id);
        CREATE INDEX IF NOT EXISTS idx_task_state_session_key ON task_state(session_key);
        CREATE INDEX IF NOT EXISTS idx_task_state_status ON task_state(status);
        CREATE INDEX IF NOT EXISTS idx_task_state_updated_at ON task_state(updated_at DESC);

        CREATE TABLE IF NOT EXISTS summaries (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            task_id TEXT NOT NULL DEFAULT '',
            value TEXT NOT NULL,
            scope TEXT NOT NULL DEFAULT 'summary',
            source TEXT NOT NULL DEFAULT '',
            session_key TEXT NOT NULL DEFAULT '',
            confidence REAL NOT NULL DEFAULT 0.7,
            created_at TEXT NOT NULL,
            updated_at TEXT NOT NULL
        );
        CREATE INDEX IF NOT EXISTS idx_summaries_task_id ON summaries(task_id);
        CREATE INDEX IF NOT EXISTS idx_summaries_session_key ON summaries(session_key);
        CREATE INDEX IF NOT EXISTS idx_summaries_updated_at ON summaries(updated_at DESC);

        CREATE TABLE IF NOT EXISTS events (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            event_type TEXT NOT NULL,
            value TEXT NOT NULL,
            scope TEXT NOT NULL DEFAULT 'event',
            source TEXT NOT NULL DEFAULT '',
            session_key TEXT NOT NULL DEFAULT '',
            task_id TEXT NOT NULL DEFAULT '',
            confidence REAL NOT NULL DEFAULT 0.9,
            created_at TEXT NOT NULL,
            updated_at TEXT NOT NULL
        );
        CREATE INDEX IF NOT EXISTS idx_events_task_id ON events(task_id);
        CREATE INDEX IF NOT EXISTS idx_events_session_key ON events(session_key);
        CREATE INDEX IF NOT EXISTS idx_events_type ON events(event_type);
        CREATE INDEX IF NOT EXISTS idx_events_updated_at ON events(updated_at DESC);

        CREATE VIRTUAL TABLE IF NOT EXISTS facts_fts USING fts5(
            key, value, source, session_key, task_id, scope,
            content='facts', content_rowid='id'
        );
        CREATE VIRTUAL TABLE IF NOT EXISTS task_state_fts USING fts5(
            task_id, status, value, source, session_key, scope,
            content='task_state', content_rowid='id'
        );
        CREATE VIRTUAL TABLE IF NOT EXISTS summaries_fts USING fts5(
            task_id, value, source, session_key, scope,
            content='summaries', content_rowid='id'
        );
        CREATE VIRTUAL TABLE IF NOT EXISTS events_fts USING fts5(
            event_type, value, source, session_key, task_id, scope,
            content='events', content_rowid='id'
        );

        CREATE TRIGGER IF NOT EXISTS facts_ai AFTER INSERT ON facts BEGIN
          INSERT INTO facts_fts(rowid, key, value, source, session_key, task_id, scope)
          VALUES (new.id, new.key, new.value, new.source, new.session_key, new.task_id, new.scope);
        END;
        CREATE TRIGGER IF NOT EXISTS facts_ad AFTER DELETE ON facts BEGIN
          INSERT INTO facts_fts(facts_fts, rowid, key, value, source, session_key, task_id, scope)
          VALUES('delete', old.id, old.key, old.value, old.source, old.session_key, old.task_id, old.scope);
        END;
        CREATE TRIGGER IF NOT EXISTS facts_au AFTER UPDATE ON facts BEGIN
          INSERT INTO facts_fts(facts_fts, rowid, key, value, source, session_key, task_id, scope)
          VALUES('delete', old.id, old.key, old.value, old.source, old.session_key, old.task_id, old.scope);
          INSERT INTO facts_fts(rowid, key, value, source, session_key, task_id, scope)
          VALUES (new.id, new.key, new.value, new.source, new.session_key, new.task_id, new.scope);
        END;

        CREATE TRIGGER IF NOT EXISTS task_state_ai AFTER INSERT ON task_state BEGIN
          INSERT INTO task_state_fts(rowid, task_id, status, value, source, session_key, scope)
          VALUES (new.id, new.task_id, new.status, new.value, new.source, new.session_key, new.scope);
        END;
        CREATE TRIGGER IF NOT EXISTS task_state_ad AFTER DELETE ON task_state BEGIN
          INSERT INTO task_state_fts(task_state_fts, rowid, task_id, status, value, source, session_key, scope)
          VALUES('delete', old.id, old.task_id, old.status, old.value, old.source, old.session_key, old.scope);
        END;
        CREATE TRIGGER IF NOT EXISTS task_state_au AFTER UPDATE ON task_state BEGIN
          INSERT INTO task_state_fts(task_state_fts, rowid, task_id, status, value, source, session_key, scope)
          VALUES('delete', old.id, old.task_id, old.status, old.value, old.source, old.session_key, old.scope);
          INSERT INTO task_state_fts(rowid, task_id, status, value, source, session_key, scope)
          VALUES (new.id, new.task_id, new.status, new.value, new.source, new.session_key, new.scope);
        END;

        CREATE TRIGGER IF NOT EXISTS summaries_ai AFTER INSERT ON summaries BEGIN
          INSERT INTO summaries_fts(rowid, task_id, value, source, session_key, scope)
          VALUES (new.id, new.task_id, new.value, new.source, new.session_key, new.scope);
        END;
        CREATE TRIGGER IF NOT EXISTS summaries_ad AFTER DELETE ON summaries BEGIN
          INSERT INTO summaries_fts(summaries_fts, rowid, task_id, value, source, session_key, scope)
          VALUES('delete', old.id, old.task_id, old.value, old.source, old.session_key, old.scope);
        END;
        CREATE TRIGGER IF NOT EXISTS summaries_au AFTER UPDATE ON summaries BEGIN
          INSERT INTO summaries_fts(summaries_fts, rowid, task_id, value, source, session_key, scope)
          VALUES('delete', old.id, old.task_id, old.value, old.source, old.session_key, old.scope);
          INSERT INTO summaries_fts(rowid, task_id, value, source, session_key, scope)
          VALUES (new.id, new.task_id, new.value, new.source, new.session_key, new.scope);
        END;

        CREATE TRIGGER IF NOT EXISTS events_ai AFTER INSERT ON events BEGIN
          INSERT INTO events_fts(rowid, event_type, value, source, session_key, task_id, scope)
          VALUES (new.id, new.event_type, new.value, new.source, new.session_key, new.task_id, new.scope);
        END;
        CREATE TRIGGER IF NOT EXISTS events_ad AFTER DELETE ON events BEGIN
          INSERT INTO events_fts(events_fts, rowid, event_type, value, source, session_key, task_id, scope)
          VALUES('delete', old.id, old.event_type, old.value, old.source, old.session_key, old.task_id, old.scope);
        END;
        CREATE TRIGGER IF NOT EXISTS events_au AFTER UPDATE ON events BEGIN
          INSERT INTO events_fts(events_fts, rowid, event_type, value, source, session_key, task_id, scope)
          VALUES('delete', old.id, old.event_type, old.value, old.source, old.session_key, old.task_id, old.scope);
          INSERT INTO events_fts(rowid, event_type, value, source, session_key, task_id, scope)
          VALUES (new.id, new.event_type, new.value, new.source, new.session_key, new.task_id, new.scope);
        END;
        '''
    )
    conn.commit()


def current_fact(conn: sqlite3.Connection, key: str, session_key: str = '', task_id: str = '', scope_mode: str = 'fallback') -> sqlite3.Row | None:
    if scope_mode == 'exact':
        if session_key:
            sql = '''
                SELECT f.*
                FROM facts f
                LEFT JOIN facts newer ON newer.supersedes = f.id
                WHERE f.key = ? AND f.session_key = ? AND newer.id IS NULL
                ORDER BY f.updated_at DESC, f.id DESC
                LIMIT 1
            '''
            return conn.execute(sql, [key, session_key]).fetchone()
        if task_id:
            sql = '''
                SELECT f.*
                FROM facts f
                LEFT JOIN facts newer ON newer.supersedes = f.id
                WHERE f.key = ? AND f.task_id = ? AND f.session_key = '' AND newer.id IS NULL
                ORDER BY f.updated_at DESC, f.id DESC
                LIMIT 1
            '''
            return conn.execute(sql, [key, task_id]).fetchone()
        sql = '''
            SELECT f.*
            FROM facts f
            LEFT JOIN facts newer ON newer.supersedes = f.id
            WHERE f.key = ? AND f.task_id = '' AND f.session_key = '' AND newer.id IS NULL
            ORDER BY f.updated_at DESC, f.id DESC
            LIMIT 1
        '''
        return conn.execute(sql, [key]).fetchone()

    candidates: list[tuple[str, list[object]]] = []
    if session_key:
        candidates.append(
            (
                '''
                SELECT f.*
                FROM facts f
                LEFT JOIN facts newer ON newer.supersedes = f.id
                WHERE f.key = ? AND f.session_key = ? AND newer.id IS NULL
                ORDER BY f.updated_at DESC, f.id DESC
                LIMIT 1
                ''',
                [key, session_key],
            )
        )
    if task_id:
        candidates.append(
            (
                '''
                SELECT f.*
                FROM facts f
                LEFT JOIN facts newer ON newer.supersedes = f.id
                WHERE f.key = ? AND f.task_id = ? AND f.session_key = '' AND newer.id IS NULL
                ORDER BY f.updated_at DESC, f.id DESC
                LIMIT 1
                ''',
                [key, task_id],
            )
        )
    candidates.append(
        (
            '''
            SELECT f.*
            FROM facts f
            LEFT JOIN facts newer ON newer.supersedes = f.id
            WHERE f.key = ? AND f.task_id = '' AND f.session_key = '' AND newer.id IS NULL
            ORDER BY f.updated_at DESC, f.id DESC
            LIMIT 1
            ''',
            [key],
        )
    )

    for sql, params in candidates:
        row = conn.execute(sql, params).fetchone()
        if row:
            return row
    return None


def put_fact(args: argparse.Namespace) -> int:
    conn = connect(); init_db(conn)
    ts = now_iso()
    conn.execute(
        '''INSERT INTO facts (key, value, scope, source, session_key, task_id, confidence, supersedes, created_at, updated_at)
           VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)''',
        (args.key, args.value, args.scope, args.source, args.session_key, args.task_id, args.confidence, args.supersedes, ts, ts),
    )
    conn.commit()
    print(json.dumps({'ok': True, 'kind': 'fact', 'key': args.key}, ensure_ascii=False))
    return 0


def put_task(args: argparse.Namespace) -> int:
    conn = connect(); init_db(conn)
    ts = now_iso()
    conn.execute(
        '''INSERT INTO task_state (task_id, status, value, scope, source, session_key, confidence, supersedes, created_at, updated_at)
           VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)''',
        (args.task_id, args.status, args.value, args.scope, args.source, args.session_key, args.confidence, args.supersedes, ts, ts),
    )
    conn.commit()
    print(json.dumps({'ok': True, 'kind': 'task_state', 'task_id': args.task_id, 'status': args.status}, ensure_ascii=False))
    return 0


def put_summary(args: argparse.Namespace) -> int:
    conn = connect(); init_db(conn)
    ts = now_iso()
    conn.execute(
        '''INSERT INTO summaries (task_id, value, scope, source, session_key, confidence, created_at, updated_at)
           VALUES (?, ?, ?, ?, ?, ?, ?, ?)''',
        (args.task_id, args.value, args.scope, args.source, args.session_key, args.confidence, ts, ts),
    )
    conn.commit()
    print(json.dumps({'ok': True, 'kind': 'summary', 'task_id': args.task_id}, ensure_ascii=False))
    return 0


def put_event(args: argparse.Namespace) -> int:
    conn = connect(); init_db(conn)
    ts = now_iso()
    conn.execute(
        '''INSERT INTO events (event_type, value, scope, source, session_key, task_id, confidence, created_at, updated_at)
           VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)''',
        (args.event_type, args.value, args.scope, args.source, args.session_key, args.task_id, args.confidence, ts, ts),
    )
    conn.commit()
    print(json.dumps({'ok': True, 'kind': 'event', 'event_type': args.event_type}, ensure_ascii=False))
    return 0


def _matches_clause(table: str, field: str) -> str:
    return f" AND {table}.{field} = ? "


def search(args: argparse.Namespace) -> int:
    conn = connect(); init_db(conn)
    q = args.query
    limit = args.limit
    results = []

    filters = []
    params_tail: list[str] = []
    if args.task_id:
        filters.append(_matches_clause('base', 'task_id'))
        params_tail.append(args.task_id)
    if args.session_key:
        filters.append(_matches_clause('base', 'session_key'))
        params_tail.append(args.session_key)
    if args.scope:
        filters.append(_matches_clause('base', 'scope'))
        params_tail.append(args.scope)
    filter_sql = ''.join(filters)

    queries = [
        ("fact", f'''SELECT 'fact' AS kind, base.id, base.key AS title, base.value, base.scope, base.source, base.session_key, base.task_id,
                             base.confidence, base.created_at, base.updated_at
                      FROM facts_fts idx JOIN facts base ON base.id = idx.rowid
                      LEFT JOIN facts newer ON newer.supersedes = base.id
                      WHERE facts_fts MATCH ? {filter_sql} AND newer.id IS NULL
                      ORDER BY base.updated_at DESC LIMIT ?'''),
        ("task_state", f'''SELECT 'task_state' AS kind, base.id, base.status AS title, base.value, base.scope, base.source, base.session_key, base.task_id,
                                   base.confidence, base.created_at, base.updated_at
                            FROM task_state_fts idx JOIN task_state base ON base.id = idx.rowid
                            WHERE task_state_fts MATCH ? {filter_sql}
                            ORDER BY base.updated_at DESC LIMIT ?'''),
        ("summary", f'''SELECT 'summary' AS kind, base.id, base.task_id AS title, base.value, base.scope, base.source, base.session_key, base.task_id,
                                base.confidence, base.created_at, base.updated_at
                         FROM summaries_fts idx JOIN summaries base ON base.id = idx.rowid
                         WHERE summaries_fts MATCH ? {filter_sql}
                         ORDER BY base.updated_at DESC LIMIT ?'''),
        ("event", f'''SELECT 'event' AS kind, base.id, base.event_type AS title, base.value, base.scope, base.source, base.session_key, base.task_id,
                              base.confidence, base.created_at, base.updated_at
                       FROM events_fts idx JOIN events base ON base.id = idx.rowid
                       WHERE events_fts MATCH ? {filter_sql}
                       ORDER BY base.updated_at DESC LIMIT ?'''),
    ]

    for _, sql in queries:
        rows = conn.execute(sql, [q, *params_tail, limit]).fetchall()
        results.extend(dict(r) for r in rows)

    results.sort(key=lambda r: (r['updated_at'], r['confidence']), reverse=True)
    print(json.dumps(results[:limit], ensure_ascii=False, indent=2))
    return 0


def context(args: argparse.Namespace) -> int:
    conn = connect(); init_db(conn)
    if args.task_id:
        rows = conn.execute(
            '''SELECT * FROM (
                 SELECT 'task_state' AS kind, id, status AS title, value, scope, source, session_key, task_id, confidence, created_at, updated_at FROM task_state WHERE task_id = ?
                 UNION ALL
                 SELECT 'summary' AS kind, id, task_id AS title, value, scope, source, session_key, task_id, confidence, created_at, updated_at FROM summaries WHERE task_id = ?
                 UNION ALL
                 SELECT 'fact' AS kind, id, key AS title, value, scope, source, session_key, task_id, confidence, created_at, updated_at FROM facts WHERE task_id = ? AND id NOT IN (SELECT supersedes FROM facts WHERE supersedes IS NOT NULL)
                 UNION ALL
                 SELECT 'event' AS kind, id, event_type AS title, value, scope, source, session_key, task_id, confidence, created_at, updated_at FROM events WHERE task_id = ?
               ) ORDER BY updated_at DESC LIMIT ?''',
            (args.task_id, args.task_id, args.task_id, args.task_id, args.limit),
        ).fetchall()
    elif args.session_key:
        rows = conn.execute(
            '''SELECT * FROM (
                 SELECT 'fact' AS kind, id, key AS title, value, scope, source, session_key, task_id, confidence, created_at, updated_at FROM facts WHERE session_key = ? AND id NOT IN (SELECT supersedes FROM facts WHERE supersedes IS NOT NULL)
                 UNION ALL
                 SELECT 'task_state' AS kind, id, status AS title, value, scope, source, session_key, task_id, confidence, created_at, updated_at FROM task_state WHERE session_key = ?
                 UNION ALL
                 SELECT 'summary' AS kind, id, task_id AS title, value, scope, source, session_key, task_id, confidence, created_at, updated_at FROM summaries WHERE session_key = ?
                 UNION ALL
                 SELECT 'event' AS kind, id, event_type AS title, value, scope, source, session_key, task_id, confidence, created_at, updated_at FROM events WHERE session_key = ?
               ) ORDER BY updated_at DESC LIMIT ?''',
            (args.session_key, args.session_key, args.session_key, args.session_key, args.limit),
        ).fetchall()
    else:
        rows = []
    print(json.dumps([dict(r) for r in rows], ensure_ascii=False, indent=2))
    return 0


def finalize_task(args: argparse.Namespace) -> int:
    conn = connect(); init_db(conn)
    rows = conn.execute(
        '''SELECT status, value, confidence, updated_at FROM task_state WHERE task_id = ? ORDER BY updated_at DESC LIMIT ?''',
        (args.task_id, args.max_items),
    ).fetchall()
    events = conn.execute(
        '''SELECT event_type, value, confidence, updated_at FROM events WHERE task_id = ? ORDER BY updated_at DESC LIMIT ?''',
        (args.task_id, args.max_items),
    ).fetchall()
    parts: list[str] = []
    for row in rows:
        parts.append(f"task_state[{row['status']}]: {row['value']}")
    for row in events:
        parts.append(f"event[{row['event_type']}]: {row['value']}")
    summary_text = args.value.strip() if args.value else ' | '.join(parts[:args.max_items])
    ts = now_iso()
    conn.execute(
        '''INSERT INTO summaries (task_id, value, scope, source, session_key, confidence, created_at, updated_at)
           VALUES (?, ?, 'summary', ?, ?, ?, ?, ?)''',
        (args.task_id, summary_text, args.source, args.session_key, args.confidence, ts, ts),
    )
    conn.commit()
    print(json.dumps({'ok': True, 'kind': 'summary', 'task_id': args.task_id, 'value': summary_text}, ensure_ascii=False))
    return 0


def get_current_fact(args: argparse.Namespace) -> int:
    conn = connect(); init_db(conn)
    row = current_fact(conn, args.key, args.session_key, args.task_id, args.scope_mode)
    print(json.dumps(dict(row) if row else {}, ensure_ascii=False, indent=2))
    return 0


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(prog='memory_core')
    sub = parser.add_subparsers(dest='cmd', required=True)

    pf = sub.add_parser('put-fact')
    pf.add_argument('--key', required=True)
    pf.add_argument('--value', required=True)
    pf.add_argument('--scope', default='global')
    pf.add_argument('--source', default='')
    pf.add_argument('--session-key', default='')
    pf.add_argument('--task-id', default='')
    pf.add_argument('--confidence', type=float, default=1.0)
    pf.add_argument('--supersedes', type=int)
    pf.set_defaults(handler=put_fact)

    pt = sub.add_parser('put-task')
    pt.add_argument('--task-id', required=True)
    pt.add_argument('--status', required=True)
    pt.add_argument('--value', required=True)
    pt.add_argument('--scope', default='task')
    pt.add_argument('--source', default='')
    pt.add_argument('--session-key', default='')
    pt.add_argument('--confidence', type=float, default=1.0)
    pt.add_argument('--supersedes', type=int)
    pt.set_defaults(handler=put_task)

    pe = sub.add_parser('put-event')
    pe.add_argument('--event-type', required=True)
    pe.add_argument('--value', required=True)
    pe.add_argument('--scope', default='event')
    pe.add_argument('--source', default='')
    pe.add_argument('--session-key', default='')
    pe.add_argument('--task-id', default='')
    pe.add_argument('--confidence', type=float, default=0.9)
    pe.set_defaults(handler=put_event)

    ps = sub.add_parser('put-summary')
    ps.add_argument('--task-id', default='')
    ps.add_argument('--value', required=True)
    ps.add_argument('--scope', default='summary')
    ps.add_argument('--source', default='')
    ps.add_argument('--session-key', default='')
    ps.add_argument('--confidence', type=float, default=0.7)
    ps.set_defaults(handler=put_summary)

    gf = sub.add_parser('get-current-fact')
    gf.add_argument('--key', required=True)
    gf.add_argument('--session-key', default='')
    gf.add_argument('--task-id', default='')
    gf.add_argument('--scope-mode', choices=['fallback', 'exact'], default='fallback')
    gf.set_defaults(handler=get_current_fact)

    ft = sub.add_parser('finalize-task')
    ft.add_argument('--task-id', required=True)
    ft.add_argument('--value', default='')
    ft.add_argument('--source', default='')
    ft.add_argument('--session-key', default='')
    ft.add_argument('--confidence', type=float, default=0.8)
    ft.add_argument('--max-items', type=int, default=10)
    ft.set_defaults(handler=finalize_task)

    se = sub.add_parser('search')
    se.add_argument('--query', required=True)
    se.add_argument('--task-id', default='')
    se.add_argument('--session-key', default='')
    se.add_argument('--scope', default='')
    se.add_argument('--limit', type=int, default=10)
    se.set_defaults(handler=search)

    cx = sub.add_parser('context')
    cx.add_argument('--task-id', default='')
    cx.add_argument('--session-key', default='')
    cx.add_argument('--limit', type=int, default=20)
    cx.set_defaults(handler=context)

    return parser


def main() -> int:
    parser = build_parser()
    args = parser.parse_args()
    return int(args.handler(args))


if __name__ == '__main__':
    sys.exit(main())
