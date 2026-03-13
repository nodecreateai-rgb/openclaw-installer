#!/usr/bin/env python3
import json
import os
import re
import shlex
import shutil
import signal
import subprocess
import sys
import time
from datetime import datetime, timezone
from pathlib import Path

MODEL_NAME = os.environ.get("AGILE_CODEX_MODEL", "gpt-5.4")
DEFAULT_REPORT_INTERVAL_SEC = int(os.environ.get("AGILE_CODEX_REPORT_INTERVAL_SEC", "600"))
DEFAULT_REPORT_GRACE_SEC = int(os.environ.get("AGILE_CODEX_REPORT_GRACE_SEC", "180"))
DEFAULT_ACTIVE_WINDOW_SEC = int(os.environ.get("AGILE_CODEX_ACTIVE_WINDOW_SEC", "1200"))


def now_epoch() -> int:
    return int(time.time())


def now_iso() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def sanitize_session(value: str) -> str:
    value = re.sub(r"[ /:@]", "-", value)
    value = re.sub(r"[^A-Za-z0-9._-]", "", value)
    return value


def command_exists(name: str) -> bool:
    return shutil.which(name) is not None


def get_python_bin() -> str:
    return shutil.which("python3") or shutil.which("python") or sys.executable


def read_json(path: Path, default=None):
    if default is None:
        default = {}
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except Exception:
        return default


def write_json(path: Path, obj) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(obj, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")


def append_log(path: Path, line: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("a", encoding="utf-8") as fh:
        fh.write(f"[{now_iso()}] {line}\n")


def is_pid_running(pid) -> bool:
    try:
        pid = int(pid)
    except Exception:
        return False
    if pid <= 0:
        return False
    try:
        os.kill(pid, 0)
        return True
    except OSError:
        return False


def tail_text(path: Path, max_chars: int = 20000, max_lines: int = 160) -> str:
    if not path.exists():
        return ""
    try:
        data = path.read_text(encoding="utf-8", errors="replace")
    except Exception:
        return ""
    if len(data) > max_chars:
        data = data[-max_chars:]
    lines = data.splitlines()
    if len(lines) > max_lines:
        lines = lines[-max_lines:]
    return "\n".join(lines)


def write_tail(path: Path, text: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text + ("\n" if text and not text.endswith("\n") else ""), encoding="utf-8")


def parse_session_id_from_jsonl(path: Path):
    if not path.exists():
        return None
    try:
        for raw in path.read_text(encoding="utf-8", errors="replace").splitlines():
            line = raw.strip()
            if not line:
                continue
            try:
                obj = json.loads(line)
            except Exception:
                continue
            if isinstance(obj, dict):
                sid = obj.get("session_id") or obj.get("sessionId") or obj.get("conversation_id") or obj.get("thread_id")
                if sid:
                    return sid
    except Exception:
        return None
    return None


def jsonl_state_hints(path: Path):
    if not path.exists():
        return {
            "last_event_type": "",
            "last_payload_type": "",
            "task_complete_event": False,
        }
    last_event_type = ""
    last_payload_type = ""
    task_complete_event = False
    saw_object = False
    try:
        with path.open("r", encoding="utf-8", errors="replace") as handle:
            for raw in handle:
                line = raw.strip()
                if not line:
                    continue
                try:
                    obj = json.loads(line)
                except Exception:
                    continue
                if not isinstance(obj, dict):
                    continue
                saw_object = True
                last_event_type = obj.get("type", "")
                payload = obj.get("payload") if isinstance(obj.get("payload"), dict) else {}
                last_payload_type = payload.get("type", "") if isinstance(payload, dict) else ""
                if obj.get("type") == "event_msg" and isinstance(payload, dict) and payload.get("type") == "task_complete":
                    task_complete_event = True
    except Exception:
        return {
            "last_event_type": "",
            "last_payload_type": "",
            "task_complete_event": False,
        }
    if not saw_object:
        return {
            "last_event_type": "",
            "last_payload_type": "",
            "task_complete_event": False,
        }
    return {
        "last_event_type": last_event_type,
        "last_payload_type": last_payload_type,
        "task_complete_event": task_complete_event,
    }


def capture_tmux(session: str, tail_file: Path, snapshot_file: Path):
    subprocess.run(["tmux", "capture-pane", "-t", session, "-p", "-S", "-"], check=False, stdout=snapshot_file.open("w", encoding="utf-8"), stderr=subprocess.DEVNULL)
    write_tail(tail_file, tail_text(snapshot_file, max_chars=40000, max_lines=160))


def build_paths(session_raw: str, log_dir_raw: str):
    session = sanitize_session(session_raw)
    log_dir = Path(os.path.expanduser(log_dir_raw))
    return {
        "session": session,
        "log_dir": log_dir,
        "prompt_copy": log_dir / f"{session}.prompt.txt",
        "meta_file": log_dir / f"{session}.meta.json",
        "status_file": log_dir / f"{session}.status.json",
        "event_log": log_dir / f"{session}.events.log",
        "last_message_file": log_dir / f"{session}.last.txt",
        "jsonl_file": log_dir / f"{session}.jsonl",
        "tail_file": log_dir / f"{session}.tail.txt",
        "snapshot_file": log_dir / f"{session}.snapshot.txt",
        "report_state_file": log_dir / f"{session}.report-state.json",
    }


def ensure_report_state(paths, started_at_iso: str, started_at_epoch: int, report_interval_sec: int, report_grace_sec: int):
    if paths["report_state_file"].exists():
        return
    write_json(paths["report_state_file"], {
        "session": paths["session"],
        "started_at": started_at_iso,
        "started_at_epoch": started_at_epoch,
        "report_interval_sec": report_interval_sec,
        "report_grace_sec": report_grace_sec,
        "last_announced_slot": -1,
        "last_announced_reason": "",
        "last_announced_at": "",
        "last_announced_at_epoch": 0,
    })


def choose_backend(meta: dict) -> str:
    requested = (meta.get("backend") or os.environ.get("AGILE_CODEX_BACKEND") or "").strip().lower()
    if requested in {"tmux", "process"}:
        if requested == "tmux" and not command_exists("tmux"):
            return "process"
        return requested
    if command_exists("tmux"):
        return "tmux"
    return "process"


def tmux_has_session(session: str) -> bool:
    if not command_exists("tmux"):
        return False
    return subprocess.run(["tmux", "has-session", "-t", session], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL).returncode == 0


def build_inner_command(workdir: str, prompt_copy: Path, last_message_file: Path, jsonl_file: Path, session_id: str | None) -> str:
    q_workdir = shlex.quote(workdir)
    q_prompt = shlex.quote(str(prompt_copy))
    q_last = shlex.quote(str(last_message_file))
    q_jsonl = shlex.quote(str(jsonl_file))
    if session_id:
        q_session = shlex.quote(session_id)
        return (
            f"cd {q_workdir} && "
            f"codex exec resume {q_session} - < {q_prompt} --json -o {q_last} "
            f"--dangerously-bypass-approvals-and-sandbox --skip-git-repo-check -m {shlex.quote(MODEL_NAME)} "
            f"-c 'model_reasoning_effort=\"xhigh\"' > {q_jsonl} 2>&1"
        )
    return (
        f"cd {q_workdir} && "
        f"codex exec - < {q_prompt} --json -o {q_last} "
        f"--dangerously-bypass-approvals-and-sandbox --skip-git-repo-check -m {shlex.quote(MODEL_NAME)} -C {q_workdir} "
        f"-c 'model_reasoning_effort=\"xhigh\"' > {q_jsonl} 2>&1"
    )


def emit_status_brief(paths, workdir: str, status: str, backend: str):
    obj = {
        "session": paths["session"],
        "workdir": workdir,
        "prompt_file": str(paths["prompt_copy"]),
        "status": status,
        "backend": backend,
        "report_state_file": str(paths["report_state_file"]),
    }
    write_json(paths["status_file"], obj)
    print(json.dumps(obj, ensure_ascii=False, indent=2))


def start_cmd(session_raw: str, workdir: str, prompt_file: str, log_dir_raw: str):
    paths = build_paths(session_raw, log_dir_raw)
    paths["log_dir"].mkdir(parents=True, exist_ok=True)
    started_at_epoch = now_epoch()
    started_at_iso = now_iso()
    if Path(prompt_file).resolve() != paths["prompt_copy"].resolve():
        shutil.copyfile(os.path.expanduser(prompt_file), paths["prompt_copy"])
    meta = read_json(paths["meta_file"], {})
    report_interval_sec = int(meta.get("report_interval_sec") or os.environ.get("AGILE_CODEX_REPORT_INTERVAL_SEC") or DEFAULT_REPORT_INTERVAL_SEC)
    report_grace_sec = int(meta.get("report_grace_sec") or os.environ.get("AGILE_CODEX_REPORT_GRACE_SEC") or DEFAULT_REPORT_GRACE_SEC)
    ensure_report_state(paths, started_at_iso, started_at_epoch, report_interval_sec, report_grace_sec)
    backend = choose_backend(meta)
    meta.update({
        "session": paths["session"],
        "workdir": workdir,
        "prompt_file": str(paths["prompt_copy"]),
        "started_at": meta.get("started_at") or started_at_iso,
        "started_at_epoch": int(meta.get("started_at_epoch") or started_at_epoch),
        "report_interval_sec": report_interval_sec,
        "report_grace_sec": report_grace_sec,
        "backend": backend,
    })
    write_json(paths["meta_file"], meta)

    if backend == "tmux":
        if tmux_has_session(paths["session"]):
            capture_tmux(paths["session"], paths["tail_file"], paths["snapshot_file"])
            write_json(paths["meta_file"], meta)
            emit_status_brief(paths, workdir, "existing", backend)
            return
        session_id = meta.get("codex_session_id") or None
        inner = build_inner_command(workdir, paths["prompt_copy"], paths["last_message_file"], paths["jsonl_file"], session_id)
        subprocess.run(["tmux", "new-session", "-d", "-s", paths["session"], "-c", workdir, inner], check=True)
        append_log(paths["event_log"], f"{'resumed' if session_id else 'started'} session={paths['session']} backend=tmux")
    else:
        pid = meta.get("pid")
        if pid and is_pid_running(pid):
            write_tail(paths["tail_file"], tail_text(paths["jsonl_file"]))
            write_json(paths["meta_file"], meta)
            emit_status_brief(paths, workdir, "existing", backend)
            return
        session_id = meta.get("codex_session_id") or None
        inner = build_inner_command(workdir, paths["prompt_copy"], paths["last_message_file"], paths["jsonl_file"], session_id)
        proc = subprocess.Popen(["bash", "-lc", f"nohup bash -lc {shlex.quote(inner)} >/dev/null 2>&1 & echo $!"], stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        stdout, stderr = proc.communicate(timeout=30)
        if proc.returncode != 0:
            raise SystemExit(stderr.strip() or "failed to start agile-codex process backend")
        pid_text = (stdout or "").strip().splitlines()[-1].strip()
        meta["pid"] = int(pid_text)
        meta["runner"] = "bash-nohup"
        append_log(paths["event_log"], f"{'resumed' if session_id else 'started'} session={paths['session']} backend=process pid={meta['pid']}")

    time.sleep(5)
    sid = parse_session_id_from_jsonl(paths["jsonl_file"])
    if sid:
        meta["codex_session_id"] = sid
    write_json(paths["meta_file"], meta)
    if backend == "tmux" and tmux_has_session(paths["session"]):
        capture_tmux(paths["session"], paths["tail_file"], paths["snapshot_file"])
    else:
        write_tail(paths["tail_file"], tail_text(paths["jsonl_file"], max_chars=40000, max_lines=120))
    emit_status_brief(paths, workdir, "started", backend)


def detect_needs_input(text: str) -> bool:
    return bool(re.search(r"approval|permission|continue\?|yes.?/no|press enter|allow|proceed|need.*credential|otp|2fa|sms|password", text, re.I))


def detect_completed(text: str) -> bool:
    return bool(re.search(r"\b(completed|finished|done|all tasks complete|review complete)\b", text, re.I))


def detect_idle(text: str) -> bool:
    return bool(re.search(r"\b(idle|standby|waiting for input|no active task|0 active task|待命|无活跃任务)\b", text, re.I))


def status_cmd(session_raw: str, log_dir_raw: str):
    paths = build_paths(session_raw, log_dir_raw)
    paths["log_dir"].mkdir(parents=True, exist_ok=True)
    meta = read_json(paths["meta_file"], {})
    backend = choose_backend(meta)
    state = "missing"
    pane_pid = ""
    pane_cmd = ""

    if backend == "tmux" and tmux_has_session(paths["session"]):
        capture_tmux(paths["session"], paths["tail_file"], paths["snapshot_file"])
        pane_pid = subprocess.run(["tmux", "list-panes", "-t", paths["session"], "-F", "#{pane_pid}"], check=False, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True).stdout.splitlines()[:1]
        pane_cmd = subprocess.run(["tmux", "list-panes", "-t", paths["session"], "-F", "#{pane_current_command}"], check=False, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True).stdout.splitlines()[:1]
        pane_pid = pane_pid[0] if pane_pid else ""
        pane_cmd = pane_cmd[0] if pane_cmd else ""
        state = "running"
    elif backend == "process":
        pid = meta.get("pid")
        if pid and is_pid_running(pid):
            state = "running"
            pane_pid = str(pid)
            pane_cmd = meta.get("runner") or "bash-nohup"
            snapshot_text = tail_text(paths["jsonl_file"], max_chars=40000, max_lines=400)
            write_tail(paths["snapshot_file"], snapshot_text)
            write_tail(paths["tail_file"], tail_text(paths["jsonl_file"], max_chars=40000, max_lines=160))
        else:
            state = "missing"

    tail_text_value = tail_text(paths["tail_file"], max_chars=12000, max_lines=160)
    last_message_value = tail_text(paths["last_message_file"], max_chars=8000, max_lines=80)
    combined_text = "\n".join([tail_text_value, last_message_value])
    jsonl_hints = jsonl_state_hints(paths["jsonl_file"])
    needs_input = detect_needs_input(combined_text)
    completed = detect_completed(last_message_value) or jsonl_hints["task_complete_event"]
    idle_hint = detect_idle(combined_text)
    abrupt_exit = state == "missing" and not completed and paths["jsonl_file"].exists()
    if state == "missing" and completed:
        state = "completed"

    started_at_epoch = int(meta.get("started_at_epoch") or 0)
    started_at = meta.get("started_at") or ""
    if started_at_epoch <= 0:
        candidates = [p for p in (paths["meta_file"], paths["jsonl_file"], paths["event_log"]) if p.exists()]
        started_at_epoch = int(candidates[0].stat().st_mtime) if candidates else now_epoch()
    if not started_at:
        started_at = datetime.fromtimestamp(started_at_epoch, tz=timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")

    report_interval_sec = int(meta.get("report_interval_sec") or DEFAULT_REPORT_INTERVAL_SEC)
    report_grace_sec = int(meta.get("report_grace_sec") or DEFAULT_REPORT_GRACE_SEC)
    ensure_report_state(paths, started_at, started_at_epoch, report_interval_sec, report_grace_sec)
    report_state = read_json(paths["report_state_file"], {})
    last_announced_slot = int(report_state.get("last_announced_slot", -1))
    last_announced_reason = report_state.get("last_announced_reason", "")
    last_announced_at = report_state.get("last_announced_at", "")
    last_announced_at_epoch = int(report_state.get("last_announced_at_epoch", 0))

    now_ep = now_epoch()
    uptime_sec = max(0, now_ep - started_at_epoch)
    report_slot = 0
    next_report_at_epoch = started_at_epoch + report_interval_sec
    next_report_in_sec = max(0, next_report_at_epoch - now_ep)
    within_grace = False
    if uptime_sec >= report_interval_sec:
        report_slot = uptime_sec // report_interval_sec
        slot_started_at_epoch = started_at_epoch + report_slot * report_interval_sec
        next_report_at_epoch = slot_started_at_epoch + report_interval_sec
        next_report_in_sec = max(0, next_report_at_epoch - now_ep)
        within_grace = (now_ep - slot_started_at_epoch) <= report_grace_sec

    mtimes = [int(p.stat().st_mtime) for p in (paths["tail_file"], paths["last_message_file"], paths["jsonl_file"], paths["event_log"]) if p.exists()]
    last_activity_epoch = max(mtimes) if mtimes else started_at_epoch
    last_activity_at = datetime.fromtimestamp(last_activity_epoch, tz=timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    active_window_sec = max(DEFAULT_ACTIVE_WINDOW_SEC, report_interval_sec + report_grace_sec)
    active_work = state == "running" and (now_ep - last_activity_epoch) <= active_window_sec and not idle_hint

    report_due = False
    report_reason = ""
    if state == "missing":
        report_due = True
        report_reason = "missing"
    elif needs_input:
        report_due = True
        report_reason = "needs_input"
    elif completed:
        report_due = True
        report_reason = "completed"
    elif active_work and report_slot > last_announced_slot:
        report_due = True
        report_reason = "cadence"

    summary_hash = __import__("hashlib").sha1((f"{state}\n{needs_input}\n{completed}\n{active_work}\n{combined_text[-4000:]}").encode("utf-8", "replace")).hexdigest()[:12]
    obj = {
        "session": paths["session"],
        "backend": backend,
        "state": state,
        "pane_pid": pane_pid,
        "pane_cmd": pane_cmd,
        "needs_input": needs_input,
        "completed": completed,
        "active_work": active_work,
        "idle_hint": idle_hint,
        "abrupt_exit": abrupt_exit,
        "last_event_type": jsonl_hints["last_event_type"],
        "last_payload_type": jsonl_hints["last_payload_type"],
        "task_complete_event": jsonl_hints["task_complete_event"],
        "tail_file": str(paths["tail_file"]),
        "snapshot_file": str(paths["snapshot_file"]),
        "jsonl_file": str(paths["jsonl_file"]),
        "last_message_file": str(paths["last_message_file"]),
        "report_state_file": str(paths["report_state_file"]),
        "started_at": started_at,
        "started_at_epoch": started_at_epoch,
        "uptime_sec": uptime_sec,
        "report_interval_sec": report_interval_sec,
        "report_grace_sec": report_grace_sec,
        "report_slot": report_slot,
        "next_report_at": datetime.fromtimestamp(next_report_at_epoch, tz=timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "next_report_at_epoch": next_report_at_epoch,
        "next_report_in_sec": next_report_in_sec,
        "within_grace": within_grace,
        "last_activity_at": last_activity_at,
        "last_activity_epoch": last_activity_epoch,
        "last_announced_slot": last_announced_slot,
        "last_announced_reason": last_announced_reason,
        "last_announced_at": last_announced_at,
        "last_announced_at_epoch": last_announced_at_epoch,
        "report_due": report_due,
        "report_reason": report_reason,
        "summary_hash": summary_hash,
    }
    write_json(paths["status_file"], obj)
    append_log(
        paths["event_log"],
        f"state={state} backend={backend} active_work={active_work} needs_input={needs_input} "
        f"completed={completed} abrupt_exit={abrupt_exit} report_due={report_due} "
        f"report_reason={report_reason} report_slot={report_slot} "
        f"last_event_type={jsonl_hints['last_event_type']} last_payload_type={jsonl_hints['last_payload_type']}",
    )
    print(json.dumps(obj, ensure_ascii=False, indent=2))


def restart_cmd(session_raw: str, workdir: str, progress_message: str, log_dir_raw: str):
    paths = build_paths(session_raw, log_dir_raw)
    meta = read_json(paths["meta_file"], {})
    backend = choose_backend(meta)
    if backend == "tmux" and tmux_has_session(paths["session"]):
        return
    if backend == "process" and is_pid_running(meta.get("pid")):
        return
    prompt_file = paths["log_dir"] / f"{paths['session']}.recovery.prompt.txt"
    prompt_file.write_text(
        "继续之前的敏捷开发任务。以下是外部监控摘要，请恢复状态后继续：\n\n"
        + progress_message
        + "\n\n要求：\n1. 继续使用 BMAD 方法。\n2. 先做快速状态回顾，再继续实施。\n3. 如已完成编码，请继续 review、修复、再 review，直到达成一致。\n4. 输出下一步计划。\n",
        encoding="utf-8",
    )
    start_cmd(session_raw, workdir, str(prompt_file), log_dir_raw)
    append_log(paths["event_log"], f"restarted session={paths['session']}")


def mark_reported_cmd(session_raw: str, reason: str, log_dir_raw: str):
    paths = build_paths(session_raw, log_dir_raw)
    if not paths["status_file"].exists():
        raise SystemExit(f"status file not found: {paths['status_file']}")
    status = read_json(paths["status_file"], {})
    report_state = read_json(paths["report_state_file"], {
        "last_announced_slot": -1,
        "last_announced_reason": "",
        "last_announced_at": "",
        "last_announced_at_epoch": 0,
    })
    slot = int(status.get("report_slot", -1))
    report_state.update({
        "last_announced_slot": slot,
        "last_announced_reason": reason,
        "last_announced_at": now_iso(),
        "last_announced_at_epoch": now_epoch(),
    })
    write_json(paths["report_state_file"], report_state)
    append_log(paths["event_log"], f"reported session={paths['session']} slot={slot} reason={reason}")
    print(json.dumps({
        "session": paths["session"],
        "slot": slot,
        "reason": reason,
        "reported_at": report_state["last_announced_at"],
    }, ensure_ascii=False, indent=2))


def main(argv: list[str]):
    if len(argv) < 2:
        raise SystemExit("usage: agile_codex_backend.py <start|status|restart|mark-reported> ...")
    cmd = argv[1]
    if cmd == "start":
        if len(argv) < 5:
            raise SystemExit("usage: agile_codex_backend.py start <session-name> <workdir> <prompt-file> [log-dir]")
        start_cmd(argv[2], argv[3], argv[4], argv[5] if len(argv) > 5 else os.path.expanduser("~/.openclaw/skills/agile-codex/runtime"))
        return
    if cmd == "status":
        if len(argv) < 3:
            raise SystemExit("usage: agile_codex_backend.py status <session-name> [log-dir]")
        status_cmd(argv[2], argv[3] if len(argv) > 3 else os.path.expanduser("~/.openclaw/skills/agile-codex/runtime"))
        return
    if cmd == "restart":
        if len(argv) < 5:
            raise SystemExit("usage: agile_codex_backend.py restart <session-name> <workdir> <progress-message> [log-dir]")
        restart_cmd(argv[2], argv[3], argv[4], argv[5] if len(argv) > 5 else os.path.expanduser("~/.openclaw/skills/agile-codex/runtime"))
        return
    if cmd == "mark-reported":
        if len(argv) < 3:
            raise SystemExit("usage: agile_codex_backend.py mark-reported <session-name> [reason] [log-dir]")
        mark_reported_cmd(argv[2], argv[3] if len(argv) > 3 else "manual", argv[4] if len(argv) > 4 else os.path.expanduser("~/.openclaw/skills/agile-codex/runtime"))
        return
    raise SystemExit(f"unknown command: {cmd}")


if __name__ == "__main__":
    main(sys.argv)
