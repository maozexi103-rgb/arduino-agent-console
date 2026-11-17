#!/usr/bin/env python3
"""Merge passive observer hooks without modifying existing hooks or trust records."""
import argparse
import datetime
import json
import os
import shlex
import shutil
import tempfile
import sys
from pathlib import Path

EVENTS = ("UserPromptSubmit", "PreToolUse", "PermissionRequest", "PostToolUse", "Stop", "Interrupt", "SessionEnd")
SCRIPT = Path(__file__).resolve().with_name("codex_agent_state_hook.py")
COMMAND = shlex.quote(sys.executable) + " " + shlex.quote(str(SCRIPT))


def merged_config(original):
    result = json.loads(json.dumps(original))
    hooks = result.setdefault("hooks", {})
    if not isinstance(hooks, dict):
        raise ValueError("Existing hooks must be an object")
    added = []
    for event in EVENTS:
        groups = hooks.setdefault(event, [])
        if not isinstance(groups, list):
            raise ValueError("Existing hook event must be an array")
        if any(h.get("command") == COMMAND for group in groups for h in group.get("hooks", [])):
            continue
        group = {"hooks": [{"type": "command", "command": COMMAND, "timeout": 2,
                            "statusMessage": "更新Arduino任务状态（仅观察）"}]}
        if event in {"PreToolUse", "PostToolUse", "PermissionRequest"}:
            group["matcher"] = ".*"
        groups.append(group)
        added.append(event)
    return result, added


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    actions = parser.add_mutually_exclusive_group()
    actions.add_argument("--install", action="store_true", help="Back up and merge the seven observer definitions")
    actions.add_argument("--uninstall", action="store_true", help="Remove this checkout's observer definitions only")
    parser.add_argument("--config-dir", type=Path, help="Explicit Codex config directory; default is CODEX_HOME or ~/.codex")
    args = parser.parse_args()
    home = args.config_dir or Path(os.environ.get("CODEX_HOME", str(Path.home() / ".codex")))
    path = home / "hooks.json"
    original = json.loads(path.read_text()) if path.exists() else {}
    if args.uninstall:
        result = json.loads(json.dumps(original))
        added = []
        for event, groups in result.get("hooks", {}).items():
            kept = []
            for group in groups:
                copy = dict(group)
                copy["hooks"] = [h for h in group.get("hooks", []) if h.get("command") != COMMAND]
                if len(copy["hooks"]) != len(group.get("hooks", [])): added.append(event)
                if copy["hooks"] or not group.get("hooks"): kept.append(copy)
            result["hooks"][event] = kept
    else:
        result, added = merged_config(original)
    print(json.dumps({"path": str(path), "command": COMMAND, "new_events": added,
                      "existing_hooks_preserved": True, "trust_records_modified": False}, ensure_ascii=False, indent=2))
    if not (args.install or args.uninstall) or not added:
        return
    backup = home / ("hooks.before-arduino-lights-" + datetime.datetime.now().strftime("%Y%m%d-%H%M%S-%f") + ".json")
    if path.exists():
        shutil.copy2(path, backup)
    home.mkdir(parents=True, exist_ok=True)
    fd, temporary = tempfile.mkstemp(prefix="hooks-arduino-", dir=home)
    try:
        with os.fdopen(fd, "w") as out:
            json.dump(result, out, ensure_ascii=False, indent=2)
            out.write("\n")
        os.chmod(temporary, 0o600)
        os.replace(temporary, path)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)
    print(("Removed owned definitions; backup: " if args.uninstall else "Installed; backup: ") + str(backup))
    print("Review/trust new definitions through Codex /hooks. No trust hashes were changed.")


if __name__ == "__main__":
    main()
