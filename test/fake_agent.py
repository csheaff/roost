#!/usr/bin/env python3
"""Offline Codex/Pi CLI contract fixture, using Roost's real event subprocesses."""
import json
import os
from pathlib import Path
import subprocess
import sys
import uuid

agent, *args = sys.argv[1:]
if agent == "codex":
    hooks = {}
    for index, arg in enumerate(args):
        if arg == "-c":
            setting = args[index + 1]
            event = setting.split("=", 1)[0].removeprefix("hooks.")
            command = json.JSONDecoder().raw_decode(setting.split("command = ", 1)[1])[0]
            hooks[event] = command
    session = args[args.index("resume") + 1] if "resume" in args else str(uuid.uuid4())
    def report(event):
        subprocess.run(hooks[event], shell=True, input=json.dumps(dict(hook_event_name=event, session_id=session)),
                       text=True, check=True)
    deferred_start = "deferred-start" in args
    if not deferred_start:
        report("SessionStart")
else:
    assert "--" not in args  # Pi's CLI does not accept an end-of-options marker.
    assert "--extension" in args and "--session-dir" in args
    extension = Path(args[args.index("--extension") + 1]).read_text()
    assert 'pi.on("agent_start"' in extension and 'pi.on("agent_end"' in extension
    session_dir = Path(args[args.index("--session-dir") + 1])
    session = args[args.index("--session") + 1] if "--session" in args else str(session_dir / (str(uuid.uuid4()) + ".jsonl"))
    Path(session).touch()
    def report(event):
        subprocess.run([os.environ["ROOST_PYTHON"], os.environ["ROOST_HELPER"], "hook-env"],
                       input=json.dumps(dict(event=event, session=session)), text=True, check=True)
    report("session_start")

print("FAKE_AGENT_READY " + session, flush=True)
for line in sys.stdin:
    if agent == "codex" and deferred_start:
        report("SessionStart")
        deferred_start = False
    report("UserPromptSubmit" if agent == "codex" else "agent_start")
    if line.strip() == "permission" and agent == "codex":
        report("PermissionRequest")
    elif line.strip() == "exit":
        break
    else:
        print("PROMPT " + line.rstrip(), flush=True)
        report("Stop" if agent == "codex" else "agent_end")
if agent == "codex":
    report("SessionEnd")
