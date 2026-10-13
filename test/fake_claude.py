#!/usr/bin/env python3
"""Offline lifecycle fixture. Talks to the actual per-task Claude hook commands,
and, if its terminal answers the probe, reports its status there as Claude Code does."""
import base64
import json
import os
from pathlib import Path
import subprocess
import sys
import termios
import uuid

settings = json.loads(Path(sys.argv[sys.argv.index("--settings") + 1]).read_text())
session = sys.argv[sys.argv.index("--resume") + 1] if "--resume" in sys.argv else str(uuid.uuid4())


# Asked for, as make qa does with a home of its own: a transcript where
# Claude Code keeps one, in its form, for Roost's search and replies.
TRANSCRIPT = None
if os.environ.get("FAKE_CLAUDE_TRANSCRIPTS"):
    import datetime
    import importlib.util
    spec = importlib.util.spec_from_file_location(
        "roost_remote", Path(__file__).resolve().parents[1] / "scripts/roost_remote.py")
    helper = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(helper)
    TRANSCRIPT = (Path.home() / ".claude" / "projects" / helper.claude_project_folder(os.getcwd())
                  / (session + ".jsonl"))
    TRANSCRIPT.parent.mkdir(parents=True, exist_ok=True)


def record(role, text):
    """Add what you or the agent wrote to the transcript, if there is one."""
    if TRANSCRIPT:
        entry = dict(type=role, sessionId=session, cwd=os.getcwd(),
                     timestamp=datetime.datetime.now(datetime.timezone.utc).isoformat().replace("+00:00", "Z"),
                     message=dict(role=role, content=text if role == "user" else [dict(type="text", text=text)]))
        with TRANSCRIPT.open("a") as handle:
            handle.write(json.dumps(entry) + "\n")


def event(name, **fields):
    payload = dict(hook_event_name=name, session_id=session, **fields)
    if TRANSCRIPT:
        payload.setdefault("transcript_path", str(TRANSCRIPT))
    for matcher in settings["hooks"].get(name, []):
        for hook in matcher["hooks"]:
            subprocess.run(hook["command"], input=json.dumps(payload), text=True, shell=True, check=True)


def probe():
    """Whether the terminal reads OSC 7501: it answers the probe before the
    primary device attributes query sent after it."""
    if not os.isatty(0):
        return False
    modes = termios.tcgetattr(0)
    quiet = termios.tcgetattr(0)
    quiet[3] &= ~(termios.ICANON | termios.ECHO)
    quiet[6][termios.VMIN], quiet[6][termios.VTIME] = 0, 20
    termios.tcsetattr(0, termios.TCSANOW, quiet)
    try:
        os.write(1, b"\x1b]7501;?\x1b\\\x1b[c")
        reply = b""
        while not reply.endswith(b"c"):
            more = os.read(0, 64)
            if not more:
                break
            reply += more
    finally:
        termios.tcsetattr(0, termios.TCSANOW, modes)
    return reply.startswith(b"\x1b]7501;?")


if "--noise" in sys.argv:
    # Much output still on its way to tmux when the probe is sent.
    sys.stdout.write(("noise " * 20 + "\n") * 5000)
    sys.stdout.flush()
reports = probe()


def status(state, msg=None, **fields):
    if reports:
        pairs = ["state=" + state, "app=fake"] + ["%s=%s" % pair for pair in fields.items()]
        if msg:
            pairs.append("msg=" + base64.b64encode(msg.encode()).decode())
        os.write(1, b"\x1b]7501;" + ":".join(pairs).encode() + b"\x1b\\")


event("SessionStart")
status("idle")
print("FAKE_CLAUDE_READY " + session, flush=True)


def lines():
    """The prompt it started with, as Claude Code takes it for its first
    turn, then what is typed."""
    if "--" in sys.argv[:-1]:
        prompt = sys.argv[sys.argv.index("--") + 1]
        yield prompt if prompt.endswith("\n") else prompt + "\n"
    yield from sys.stdin


for line in lines():
    record("user", line.strip())
    event("UserPromptSubmit")
    status("working", "Thinking")
    if line.strip() == "permission":
        event("PermissionRequest")
        status("blocked", "Bash command", kind="permission")
    elif line.startswith("ask "):
        # Ask to run a command; once "yes" is typed, run it as Claude Code
        # does, in a shell of its own, and report only when it ends.
        command = line[len("ask "):].strip()
        event("PermissionRequest", tool_name="Bash", tool_input=dict(command=command))
        status("blocked", "Bash command", kind="permission")
        answer = sys.stdin.readline().strip()
        if answer == "decline":
            # Claude stops the turn, and runs no hook.
            status("idle")
            continue
        if answer == "yes":
            status("working", "Running " + command)
            quoted = "'" + command.replace("'", "'\"'\"'") + "'"
            subprocess.run(["/bin/sh", "-c", "eval " + quoted + " < /dev/null && pwd -P > /dev/null"])
            event("PostToolUse", tool_name="Bash")
            record("assistant", "Ran " + command)
            event("Stop", last_assistant_message="Ran " + command)
        else:
            event("Stop")
        status("done")
    elif line.strip() == "interrupt":
        # Esc: Claude stops the turn, and runs no hook.
        status("idle")
    elif line.strip() == "size":
        size = os.get_terminal_size(0)
        print("SIZE %dx%d" % (size.columns, size.lines), flush=True)
        event("Stop")
        status("done")
    elif line.strip() == "exit":
        break
    else:
        print("PROMPT " + line.rstrip(), flush=True)
        record("assistant", "PROMPT " + line.rstrip())
        event("Stop", last_assistant_message="PROMPT " + line.rstrip())
        status("done")
status("clear")
event("SessionEnd")
