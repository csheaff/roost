#!/usr/bin/env python3
"""Offline lifecycle fixture. Talks to the actual per-task Claude hook commands."""
import json
from pathlib import Path
import subprocess
import sys
import uuid

settings = json.loads(Path(sys.argv[sys.argv.index("--settings") + 1]).read_text())
session = sys.argv[sys.argv.index("--resume") + 1] if "--resume" in sys.argv else str(uuid.uuid4())


def event(name, **fields):
    payload = dict(hook_event_name=name, session_id=session, **fields)
    for matcher in settings["hooks"].get(name, []):
        for hook in matcher["hooks"]:
            subprocess.run(hook["command"], input=json.dumps(payload), text=True, shell=True, check=True)


event("SessionStart")
print("FAKE_CLAUDE_READY " + session, flush=True)
for line in sys.stdin:
    event("UserPromptSubmit")
    if line.strip() == "permission":
        event("PermissionRequest")
    elif line.strip() == "exit":
        break
    else:
        print("PROMPT " + line.rstrip(), flush=True)
        event("Stop")
event("SessionEnd")
