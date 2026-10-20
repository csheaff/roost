#!/usr/bin/env python3
"""Offline Codex/Pi/OpenCode CLI contract fixture, using Roost's real event subprocesses.
It reports its status to its terminal as the real agents do: Codex whenever
that is a terminal, Pi once it answers the probe. As pi-old, it is a Pi
from before 0.84.4, which says nothing of its dialogs, or of Esc."""
import itertools
import json
import os
from pathlib import Path
import subprocess
import sys
import termios
import time
import urllib.parse
import uuid

agent, *args = sys.argv[1:]
if agent == "opencode":
    # OpenCode loads Roost's plugin from inline config, which reports its
    # events: these are the reports that plugin makes.
    assert "--" not in args
    config = json.loads(os.environ["OPENCODE_CONFIG_CONTENT"])
    assert "RoostObserver" in Path(urllib.parse.unquote(urllib.parse.urlparse(config["plugin"][-1]).path)).read_text()
    session = args[args.index("--session") + 1] if "--session" in args else "ses_" + uuid.uuid4().hex
    prompts = [arg.removeprefix("--prompt=") for arg in args if arg.startswith("--prompt=")]

    def report(event, sid=session, **fields):
        subprocess.run([os.environ["ROOST_PYTHON"], os.environ["ROOST_HELPER"], "hook-env"],
                       input=json.dumps(dict(event=event, session=sid, **fields)), text=True, check=True)

    report("start", None)
    print("FAKE_AGENT_READY " + session, flush=True)
    for line in itertools.chain(prompts, (line.strip() for line in sys.stdin)):
        report("status", status="busy")
        if line == "exit":
            break
        if line == "permission":
            report("asked", permission="bash", patterns=["make deploy"], metadata=dict(command="make deploy"))
            sys.stdin.readline()
            report("replied")
        elif line == "subagent":
            # A subagent's question waits on you; its session is not the task's.
            report("asked", "ses_child", child=True, questions=[dict(question="Which branch?")])
            sys.stdin.readline()
            report("replied", "ses_child", child=True)
        if line == "interrupt":
            report("status", status="idle", reply="", error=dict(name="MessageAbortedError"))
        elif line == "fail":
            report("status", status="idle", reply="", error=dict(name="APIError", message="Rate\nlimited"))
        else:
            print("PROMPT " + line, flush=True)
            report("status", status="idle", reply="opencode says " + line)
    sys.exit(0)
codex = agent == "codex"
old = agent == "pi-old"
agent = "pi" if old else agent
if codex:
    hooks = {}
    for index, arg in enumerate(args):
        if arg == "-c":
            setting = args[index + 1]
            event = setting.split("=", 1)[0].removeprefix("hooks.")
            command = json.JSONDecoder().raw_decode(setting.split("command = ", 1)[1])[0]
            hooks[event] = command
    session = args[args.index("resume") + 1] if "resume" in args else str(uuid.uuid4())
    def report(event, **fields):
        subprocess.run(hooks[event], shell=True, input=json.dumps(dict(hook_event_name=event, session_id=session,
                                                                         **fields)),
                       text=True, check=True)
    deferred_start = "deferred-start" in args
else:
    assert "--" not in args  # Pi's CLI does not accept an end-of-options marker.
    assert "--extension" in args and "--session-dir" in args
    extension = Path(args[args.index("--extension") + 1]).read_text()
    assert all('pi.on("%s"' % event in extension
               for event in ("agent_start", "agent_end", "agent_settled", "ui_prompt_start", "ui_prompt_end"))
    newer = ("agent_settled", "ui_prompt_start", "ui_prompt_end")
    session_dir = Path(args[args.index("--session-dir") + 1])
    session = args[args.index("--session") + 1] if "--session" in args else str(session_dir / (str(uuid.uuid4()) + ".jsonl"))
    Path(session).touch()
    def report(event, **fields):
        if old and event in newer:
            return
        subprocess.run([os.environ["ROOST_PYTHON"], os.environ["ROOST_HELPER"], "hook-env"],
                       input=json.dumps(dict(event=event, session=session, **fields)), text=True, check=True)


def probe():
    """Whether the terminal answers the OSC 7501 probe before the primary
    device attributes query sent after it."""
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


reports = os.isatty(1) if codex else not old and probe()


def status(state, **fields):
    if reports:
        pairs = ["state=" + state, "app=" + agent] + ["%s=%s" % pair for pair in fields.items()]
        os.write(1, b"\x1b]7501;" + ":".join(pairs).encode() + b"\x1b\\")


if codex:
    # Codex works for a moment as it starts its servers, before any prompt.
    status("idle")
    status("working")
    status("idle")
    if not deferred_start:
        report("SessionStart")
else:
    report("session_start")
    status("idle")

print("FAKE_AGENT_READY " + session, flush=True)
for line in sys.stdin:
    line = line.strip()
    if line == "rest dialog" and not codex:
        # An extension asks something between runs, as one might at startup.
        report("ui_prompt_start", title="Trust this project?")
        status("blocked", kind="permission")
        sys.stdin.readline()
        report("ui_prompt_end", idle=True)
        status("idle")
        continue
    if codex and deferred_start:
        report("SessionStart")
        deferred_start = False
    status("working")
    report("UserPromptSubmit" if codex else "agent_start")
    if line == "permission" and codex:
        report("PermissionRequest")
    elif line.startswith("ask ") and codex:
        # Ask to run a command; run it once "yes" is typed, and report its
        # end only when it ends, as Codex does.
        command = line[len("ask "):]
        report("PreToolUse", tool_name="Bash", tool_input=dict(command=command))
        report("PermissionRequest", tool_name="Bash", tool_input=dict(command=command))
        status("blocked")
        answer = sys.stdin.readline().strip()
        status("working")
        if answer == "yes":
            subprocess.run(["/bin/sh", "-c", command])
            report("PostToolUse", tool_name="Bash")
            report("Stop")
        else:
            # Declined: Codex stops the turn.
            report("Interrupt")
        status("idle")
    elif line == "interrupt" and codex:
        # Esc: Codex runs its Interrupt hook, then idles.
        report("Interrupt")
        status("idle")
    elif line == "background" and codex:
        # Its turn ends with a command left running, and Codex works on.
        report("Stop")
    elif line == "dialog" and not codex:
        # An extension asks whether a tool may run.
        report("ui_prompt_start", title="Allow\x1b[2J bash?\n")
        status("blocked", kind="permission")
        sys.stdin.readline()
        report("ui_prompt_end", idle=False)
        status("working")
        time.sleep(0.5)
        report("agent_end", pending=False)
        report("agent_settled", aborted=False)
        status("done")
    elif line == "interrupt" and not codex:
        report("agent_end", pending=False)
        report("agent_settled", aborted=True)
        status("idle")
    elif line == "exit":
        break
    else:
        print("PROMPT " + line, flush=True)
        report("Stop" if codex else "agent_end")
        if codex:
            status("idle")
        else:
            report("agent_settled", aborted=False)
            status("done")
status("clear")
if codex:
    report("SessionEnd")
