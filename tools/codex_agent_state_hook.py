#!/usr/bin/env python3
"""Passive Codex lifecycle observer. Never emits decisions or prompt contents.

JSON stdin -> metadata-only atomic state file. It never opens the Arduino port.
Only UserPromptSubmit selects a main task; older/background turns cannot replace it.
"""
import copy
import fcntl
import hashlib
import json
import os
import sqlite3
import sys
import tempfile
import time
from pathlib import Path

STATE_DIR = Path.home() / "Library/Application Support/ArduinoVoiceBridge"
CODEX_HOME = Path(os.environ.get("CODEX_HOME", str(Path.home() / ".codex")))
EVENTS = {"UserPromptSubmit", "PreToolUse", "PostToolUse", "PermissionRequest", "Stop", "Interrupt", "SessionEnd"}


def tool_key(event):
    # Keep only a digest, never command text, tool arguments or user questions.
    raw = json.dumps([event.get("tool_name"), event.get("tool_input")], sort_keys=True, ensure_ascii=True)
    return hashlib.sha256(raw.encode()).hexdigest()


def is_main(event):
    if event.get("agent_type") == "subagent":
        return False
    if event.get("agent_path") not in (None, "", "/root"):
        return False
    session = event.get("session_id")
    if not isinstance(session, str) or not session:
        return False
    databases = sorted((p for p in CODEX_HOME.glob("state_*.sqlite") if p.stem.split("_")[-1].isdigit()), key=lambda p: int(p.stem.split("_")[-1]), reverse=True)
    for path in databases:
        try:
            with sqlite3.connect(path.as_uri() + "?mode=ro", uri=True, timeout=.3) as db:
                row = db.execute("SELECT source, thread_source, agent_path FROM threads WHERE id = ?", (session,)).fetchone()
                agent_id = event.get("agent_id")
                if agent_id and agent_id != session:
                    agent = db.execute("SELECT thread_source, agent_path FROM threads WHERE id = ?", (agent_id,)).fetchone()
                    if agent is None or agent[0] == "subagent" or agent[1] not in (None, "", "/root"):
                        return False
            if row is not None:
                source, origin, agent_path = row
                return origin != "subagent" and '"subagent"' not in (source or "") and agent_path in (None, "", "/root")
        except (sqlite3.Error, OSError):
            continue
    return False


def reduce_state(previous, event, *, main=True):
    """Pure reducer used by the actual hook and lifecycle regression tests."""
    name = event.get("hook_event_name")
    session, turn = event.get("session_id"), event.get("turn_id")
    if not main or name not in EVENTS or not isinstance(session, str) or not session:
        return previous
    if name != "SessionEnd" and (not isinstance(turn, str) or not turn):
        return previous
    if name == "UserPromptSubmit":
        # This is the ONLY event allowed to select a different task/turn.
        state = {"schema_version": 1, "source": "codex-hook", "thread_id": session,
                 "turn_id": turn, "state": "RUNNING", "wait_kind": None, "pending": []}
    else:
        if not previous or previous.get("thread_id") != session:
            return previous
        if name != "SessionEnd" and previous.get("turn_id") != turn:
            return previous
        state = copy.deepcopy(previous)
        pending = state.get("pending", [])
        tool = str(event.get("tool_name", "")).rsplit(".", 1)[-1]
        if name == "PermissionRequest":
            item = {"kind": "permission", "key": tool_key(event), "call_id": event.get("tool_use_id")}
            if item not in pending:
                pending.append(item)
        elif name == "PreToolUse" and tool in {"request_user_input", "request_user_input_async"}:
            item = {"kind": "question_async" if tool.endswith("_async") else "question",
                    "key": tool_key(event), "call_id": event.get("tool_use_id")}
            if item not in pending:
                pending.append(item)
        elif name == "PostToolUse":
            key, call = tool_key(event), event.get("tool_use_id")
            pending = [p for p in pending if p["kind"] == "question_async" or
                       not ((call and p.get("call_id") == call) or p["key"] == key)]
        elif name in {"Interrupt", "SessionEnd"}:
            pending = []
        state["pending"] = pending
        if pending:
            state["state"] = "WAITING"
            state["wait_kind"] = "permission" if any(p["kind"] == "permission" for p in pending) else "question"
        else:
            state["wait_kind"] = None
            state["state"] = "DONE" if name == "Stop" else "IDLE" if name in {"Interrupt", "SessionEnd"} else "RUNNING"
    state["last_event"] = name
    return state


def observe(event):
    if event.get("hook_event_name") not in EVENTS or not is_main(event):
        return
    STATE_DIR.mkdir(mode=0o700, parents=True, exist_ok=True)
    with (STATE_DIR / "agent-state.lock").open("a+") as lock:
        os.chmod(lock.name, 0o600)
        fcntl.flock(lock, fcntl.LOCK_EX)
        path = STATE_DIR / "agent-state.json"
        try:
            previous = json.loads(path.read_text())
            if not isinstance(previous, dict):
                previous = None
        except (OSError, ValueError):
            previous = None
        updated = reduce_state(previous, event)
        if updated == previous or updated is None:
            return
        updated["updated_at"] = time.time()
        updated["revision"] = int((previous or {}).get("revision", 0)) + 1
        fd, temporary = tempfile.mkstemp(prefix="agent-state-", dir=STATE_DIR)
        try:
            with os.fdopen(fd, "w") as out:
                json.dump(updated, out, ensure_ascii=True)
            os.chmod(temporary, 0o600)
            os.replace(temporary, path)
        finally:
            if os.path.exists(temporary):
                os.unlink(temporary)
        # Audit state transitions only. No prompts, transcript paths or tool bodies.
        signature = lambda s: tuple((s or {}).get(k) for k in ("thread_id", "turn_id", "state", "wait_kind"))
        if signature(previous) != signature(updated):
            audit = STATE_DIR / "agent-transitions.jsonl"
            if audit.exists() and audit.stat().st_size > 1024 * 1024:
                audit.replace(audit.with_suffix(".jsonl.old"))
            with audit.open("a") as out:
                os.chmod(audit, 0o600)
                json.dump({k: updated.get(k) for k in ("updated_at", "thread_id", "turn_id", "state", "wait_kind", "last_event", "revision")}, out)
                out.write("\n")


def main():
    try:
        event = json.loads(sys.stdin.read(1024 * 1024))
        if isinstance(event, dict):
            observe(event)
    except Exception:
        # An observer failure must never decide approvals or block the task.
        pass
    # Stop hooks accept an empty successful response. No JSON decisions are emitted.


if __name__ == "__main__":
    main()
