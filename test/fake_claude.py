#!/usr/bin/env python3
"""Offline lifecycle fixture. Talks to the actual per-task Claude hook commands,
and, if its terminal answers the probe, reports its status there as Claude Code does."""
import base64
import json
import os
from pathlib import Path
import re
import signal
import subprocess
import sys
import termios
import time
import tty
import uuid

if sys.argv[1:] == ["--version"]:
    print("2.1.303 (Claude Code)")
    sys.exit()
# UTF-8 in and out, whatever the locale says, as Claude Code's terminal is:
# a prompt in another script is echoed, rather than ending the agent.
sys.stdout.reconfigure(encoding="utf-8", errors="replace")
sys.stdin.reconfigure(encoding="utf-8", errors="replace")
settings = json.loads(Path(sys.argv[sys.argv.index("--settings") + 1]).read_text())
resumed = sys.argv[sys.argv.index("--resume") + 1] if "--resume" in sys.argv else None
# A fork goes on from a copy of the conversation, under an ID of its own.
session = resumed if resumed and "--fork-session" not in sys.argv else str(uuid.uuid4())
# Roost's MCP server, as Claude Code finds it in --mcp-config.
SERVER = next((json.loads(arg[len("--mcp-config="):])["mcpServers"].get("roost")
               for arg in sys.argv if arg.startswith("--mcp-config=")), None)


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
    # Found in any project's folder, as Claude Code finds the one it forks.
    for forked in (Path.home() / ".claude" / "projects").glob("*/%s.jsonl" % resumed) if resumed not in (None, session) else ():
        TRANSCRIPT.write_text(forked.read_text())
        break


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
        # Its terminal may be gone, as when its tmux server is: it goes on
        # to say goodbye, as Claude Code does.
        try:
            os.write(1, b"\x1b]7501;" + ":".join(pairs).encode() + b"\x1b\\")
        except OSError:
            pass


def hang_up(*_):
    """As Claude Code does as its tmux server goes, or it is sent SIGTERM."""
    try:
        event("SessionEnd", reason="other")
    finally:
        os._exit(129)


signal.signal(signal.SIGHUP, hang_up)
event("SessionStart")
status("idle")
print("FAKE_CLAUDE_READY " + session, flush=True)


def call(tool, **arguments):
    """Call TOOL of Roost's MCP server with ARGUMENTS, as Claude Code
    does, and return what the server said."""
    if SERVER is None:
        return "Roost gave no tools here"
    lines = [dict(id=1, method="initialize", params=dict(protocolVersion="2025-11-25", capabilities={})),
             dict(method="notifications/initialized"),
             dict(id=2, method="tools/call", params=dict(name=tool, arguments=arguments))]
    ran = subprocess.run([SERVER["command"], *SERVER["args"]], capture_output=True, text=True,
                         input="".join(json.dumps(dict(line, jsonrpc="2.0")) + "\n" for line in lines))
    for reply in map(json.loads, ran.stdout.splitlines()):
        if reply.get("id") == 2:
            return reply["result"]["content"][0]["text"]
    return "Roost's MCP server ended"


def offer(title):
    """Offer TITLE as a task, and return what the server said."""
    return call("propose_task", title=title, brief="Brief for " + title)


def png(width=320, height=200):
    """A PNG of WIDTH by HEIGHT pixels, blue above and paler below."""
    import struct
    import zlib

    def chunk(kind, data):
        return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data))
    rows = b"".join(b"\0" + bytes((70 + 150 * y // height, 130 + 100 * y // height, 180 + 60 * y // height)) * width
                    for y in range(height))
    return (b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0))
            + chunk(b"IDAT", zlib.compress(rows)) + chunk(b"IEND", b""))


def lines():
    """The prompt it started with, as Claude Code takes it for its first
    turn, then what is typed."""
    if "--" in sys.argv[:-1]:
        prompt = sys.argv[sys.argv.index("--") + 1]
        yield prompt if prompt.endswith("\n") else prompt + "\n"
    yield from sys.stdin


for line in lines():
    # Once it takes the mouse, tmux sends presses and releases along with
    # what is typed.
    line = re.sub(r"\x1b\[<\d+;\d+;\d+[Mm]", "", line)
    record("user", line.strip())
    event("UserPromptSubmit", prompt=line.strip())
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
    elif line.startswith("offer "):
        # Offer a task of its own, which waits in Roost for you.
        event("PreToolUse", tool_name="mcp__roost__propose_task")
        said = offer(line[len("offer "):].strip())
        event("PostToolUse", tool_name="mcp__roost__propose_task")
        print("OFFERED " + said, flush=True)
        record("assistant", said)
        event("Stop", last_assistant_message=said)
        status("done")
    elif line.startswith("show "):
        # Make an image in the worktree, and show it to you in Roost.
        name = line[len("show "):].strip()
        with open(name, "wb") as image:
            image.write(png())
        event("PreToolUse", tool_name="mcp__roost__show_image")
        said = call("show_image", path=name)
        event("PostToolUse", tool_name="mcp__roost__show_image")
        print("SHOWED " + said, flush=True)
        record("assistant", said)
        event("Stop", last_assistant_message=said)
        status("done")
    elif line.startswith("page "):
        # Show a page of its own writing in Roost. Its button asks you to
        # send its words. No test can press a button in the page's frame
        # from outside it, so the page presses its own, once, when it is
        # next made wider or narrower after its first moments.
        name = line[len("page "):].strip()
        code = ('<button id="go" onclick="sendPrompt(\'Explain the %s\')">Explain the %s</button>'
                '<input type="range" id="level" min="1" max="9" value="1">'
                '<script>var born = Date.now(), pressed = false;'
                'addEventListener("resize", function () {'
                ' if (!pressed && Date.now() - born > 2500) {'
                ' pressed = true; document.getElementById("go").click(); } });</script>' % (name, name))
        event("PreToolUse", tool_name="mcp__roost__show_widget")
        said = call("show_widget", title=name, widget_code=code)
        event("PostToolUse", tool_name="mcp__roost__show_widget")
        print("SHOWED " + said, flush=True)
        record("assistant", said)
        event("Stop", last_assistant_message=said)
        status("done")
    elif line.strip() == "interrupt":
        # Esc: Claude stops the turn, and runs no hook.
        status("idle")
    elif line.strip() == "size":
        size = os.get_terminal_size(0)
        print("SIZE %dx%d" % (size.columns, size.lines), flush=True)
        event("Stop")
        status("done")
    elif line.startswith("long "):
        # A long reply, as Claude Code prints one: colors, rules, wide
        # characters and links, a numbered line each, for scrollback.
        count = int(line.split()[1])
        for number in range(1, count + 1):
            shade = 40 + number * 7 % 200
            if number % 50 == 0:
                body = "\x1b]8;;https://example.com/%d\x1b\\link %d\x1b]8;;\x1b\\" % (number, number)
            elif number % 5 == 0:
                body = "\u256d" + "\u2500" * 40 + "\u256e \u6f22\u5b57"
            else:
                body = " ".join("\x1b[38;2;%d;%d;%dm%s\x1b[39m" % (shade, 255 - shade, word * 9 % 256, "word")
                                for word in range(12))
            print("LONG %04d %s" % (number, body))
        print("LONG DONE", flush=True)
        record("assistant", "Printed %d lines" % count)
        event("Stop", last_assistant_message="Printed %d lines" % count)
        status("done")
    elif line.startswith("stream "):
        # Output for a while, as an agent at work prints it, a numbered
        # line at a time.
        _, label, count, pause = line.split()
        for number in range(1, int(count) + 1):
            print("STREAM %s %04d \x1b[3%dmworking on it\x1b[39m" % (label, number, 1 + number % 6), flush=True)
            time.sleep(float(pause))
        print("STREAM %s DONE" % label, flush=True)
        record("assistant", "Streamed " + label)
        event("Stop", last_assistant_message="Streamed " + label)
        status("done")
    elif line.strip() == "mouse":
        # Take the mouse, as a program in a terminal can: tmux then sends
        # it presses and releases.
        os.write(1, b"\x1b[?1002h\x1b[?1006h")
        print("MOUSE ON", flush=True)
        event("Stop", last_assistant_message="MOUSE ON")
        status("done")
    elif line.startswith("keys "):
        # From here on read the terminal as a full-screen agent does, raw
        # and with pastes marked, and keep every byte it sends in a file.
        with open(line[len("keys "):].strip(), "ab", buffering=0) as keys:
            tty.setraw(0)
            os.write(1, b"\x1b[?2004hKEYS ON\r\n")
            event("Stop", last_assistant_message="KEYS ON")
            status("done")
            for chunk in iter(lambda: os.read(0, 4096), b""):
                keys.write(chunk)
    elif line.strip() == "exit":
        break
    else:
        print("PROMPT " + line.rstrip(), flush=True)
        record("assistant", "PROMPT " + line.rstrip())
        event("Stop", last_assistant_message="PROMPT " + line.rstrip())
        status("done")
status("clear")
event("SessionEnd", reason="prompt_input_exit")
