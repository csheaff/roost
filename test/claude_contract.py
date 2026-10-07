#!/usr/bin/env python3
"""Check Roost's reading of the installed Claude Code.

Roost learns what an agent is doing from Claude Code's hooks, and from what
Claude does without a hook: where it keeps transcripts, how it runs an
approved command, what it writes when you stop a turn. Claude Code updates
itself often, and any of that can change without notice.

  python3 test/claude_contract.py          Scan the installed Claude Code for
                                           the hook events, notification types
                                           and payload fields Roost relies on,
                                           and for ones it has not seen. Free.
  python3 test/claude_contract.py --live   Also take a real session (Haiku, a
                                           few short turns, about three
                                           minutes) through Roost's helper and
                                           check the status Roost derives at
                                           each step.

Exits nonzero when something is new or a check fails.
"""
import importlib.util
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import time

SOURCE = Path(__file__).resolve().parents[1] / "scripts/roost_remote.py"
spec = importlib.util.spec_from_file_location("roost_remote", SOURCE)
roost = importlib.util.module_from_spec(spec)
spec.loader.exec_module(roost)

# Hook events Roost does not listen to, and why each changes nothing.
IGNORED_EVENTS = {
    "ConfigChange": "settings changed",
    "CwdChanged": "the shell's directory changed",
    "DirectoryAdded": "a directory was added to the session",
    "Elicitation": "an MCP server asks a question; rare, not yet shown as waiting",
    "ElicitationResult": "the answer to an MCP server's question",
    "FileChanged": "a watched file changed",
    "InstructionsLoaded": "CLAUDE.md or rules were loaded",
    "MessageDisplay": "a message was displayed",
    "PermissionDenied": "auto mode refused a tool; the turn goes on",
    "PostCompact": "compaction ended; SessionStart covers it",
    "PostModelSwitch": "the model changed",
    "PostToolBatch": "parallel tools ended; PostToolUse covers each",
    "PostToolUseFailure": "a tool failed; the turn goes on",
    "PreCompact": "compaction starts",
    "PreModelSwitch": "the model will change",
    "Setup": "repository setup",
    "SubagentStart": "a subagent started; the turn goes on",
    "SubagentStop": "a subagent ended; the turn goes on",
    "TaskCompleted": "a task in the session's list was completed",
    "TaskCreated": "a task in the session's list was created",
    "TeammateIdle": "a teammate is idle; its permission prompts are notifications",
    "UserPromptExpansion": "a prompt was expanded, as by a slash command",
    "WorktreeCreate": "Claude's own worktrees, which Roost's tasks do not use",
    "WorktreeRemove": "Claude's own worktrees, which Roost's tasks do not use",
}
# Notification types Roost maps, and those it ignores.
MAPPED_NOTIFICATIONS = ("permission_prompt", "worker_permission_prompt", "agent_needs_input", "idle_prompt")
IGNORED_NOTIFICATIONS = ("agent_completed", "auth_storage_failure", "auth_success", "computer_use_enter",
                         "computer_use_exit", "elicitation_complete", "elicitation_response", "push_notification")
# SessionStart sources: compact and clear are handled specially, the rest are a fresh start.
SESSION_SOURCES = ("startup", "resume", "clear", "compact", "fork")
# Payload fields the helper reads.
PAYLOAD_FIELDS = ("session_id", "transcript_path", "hook_event_name", "last_assistant_message",
                  "background_tasks", "session_crons", "notification_type", "message", "tool_name",
                  "tool_input", "error", "error_details", "source", "reason")


def claude_program():
    """The installed Claude Code: its file, whose source is searchable, and version."""
    found = shutil.which("claude")
    if not found:
        sys.exit("claude is not installed")
    version = subprocess.run([found, "--version"], text=True, capture_output=True).stdout.strip()
    return Path(os.path.realpath(found)), version


def static_check():
    """Report what the installed Claude Code defines that Roost has not seen,
    or no longer defines what it relies on. Return the number of problems."""
    path, version = claude_program()
    data = path.read_bytes()
    print("Claude Code %s, %s" % (version, path))
    problems = 0

    def report(ok, message):
        nonlocal problems
        problems += 0 if ok else 1
        print(("  ok    " if ok else "  NEW   " if ok is None else "  FAIL  ") + message)

    # Spelled "Stop", R("Stop") or A.literal("Stop"), as minification goes.
    events = set(m.group(1).decode() for m in
                 re.finditer(rb'hook_event_name:(?:[\w$.]{1,12}\()?"([A-Za-z]+)"', data))
    known = set(roost.CLAUDE_HOOK_EVENTS) | set(IGNORED_EVENTS)
    if not events:
        report(False, "found no hook events; the scan needs updating for this version")
    for event in sorted(events - known):
        report(None, "hook event %s: decide whether Roost should listen to it" % event)
    for event in sorted(set(roost.CLAUDE_HOOK_EVENTS) - events) if events else []:
        report(False, "hook event %s, which Roost listens to, is gone" % event)
    if events and events <= known and set(roost.CLAUDE_HOOK_EVENTS) <= events:
        report(True, "%d hook events, %d of them Roost's" % (len(events), len(roost.CLAUDE_HOOK_EVENTS)))

    kinds = set(m.group(1).decode() for m in re.finditer(rb'notificationType:"([a-z_]+)"', data))
    known = set(MAPPED_NOTIFICATIONS) | set(IGNORED_NOTIFICATIONS)
    for kind in sorted(kinds - known):
        report(None, "notification %s: decide whether it means the agent waits for you" % kind)
    # Some types are passed through variables, so only those named in the source can be missed.
    missing = sorted(set(MAPPED_NOTIFICATIONS) - kinds - {"permission_prompt", "idle_prompt"})
    for kind in missing:
        report(False, "notification %s, which Roost maps, is gone" % kind)
    if kinds and kinds <= known and not missing:
        report(True, "%d notification types, all known" % len(kinds))

    sources = set()
    for match in re.finditer(rb'fieldToMatch:"source",values:\[([^\]]*)\]', data):
        values = re.findall(rb'"([a-z_]+)"', match.group(1))
        if b"startup" in values:
            sources = set(value.decode() for value in values)
    for source in sorted(sources - set(SESSION_SOURCES)):
        report(None, "SessionStart source %s: is it a fresh start, a compaction or a clear?" % source)
    if not sources:
        report(False, "found no SessionStart sources; the scan needs updating for this version")
    elif sources <= set(SESSION_SOURCES):
        report(True, "SessionStart sources: %s" % ", ".join(sorted(sources)))

    absent = [field for field in PAYLOAD_FIELDS if not re.search(rb"\b" + field.encode() + rb":", data)]
    report(not absent, "payload fields Roost reads" + (": missing " + ", ".join(absent) if absent else ""))

    # The approval check finds an approved command's shell as `eval 'COMMAND'`.
    wrapper = re.search(rb"`eval \$\{[\w$]+\}`.{0,80}pwd -P >\| ", data, re.S)
    report(bool(wrapper), "Bash commands run as eval 'COMMAND'" if wrapper
           else "no longer finds how Bash commands are run; check approved_command_running")
    # Transcripts are found by the path hooks report, else by Claude's folder naming.
    naming = re.search(rb'replace\(/\[\^a-zA-Z0-9\]/g,"-"\).{0,120}\.length<=', data, re.S)
    report(bool(naming), "transcript folders named as claude_project_folder expects" if naming
           else "transcript folder naming changed; check claude_project_folder")
    return problems


class Session:
    """A Roost task with real Claude Code, driven through the helper."""

    def __init__(self):
        self.base = Path.home() / ".local/share/roost-contract"
        self.root = self.base / "state"
        self.repo = self.base / "repo"
        self.socket = "roost-contract"
        shutil.rmtree(self.root, ignore_errors=True)
        self.store = roost.Store(self.root)
        if not (self.repo / ".git").is_dir():
            # A lasting repository, so Claude asks to trust it only once.
            self.repo.mkdir(parents=True, exist_ok=True)
            (self.repo / "contract_check.py").write_text(
                "import time\ntime.sleep(8)\nprint('contract check passed')\n")
            for args in (["init", "-q", "-b", "main"], ["add", "."],
                         ["-c", "user.name=Roost", "-c", "user.email=roost@example.invalid",
                          "-c", "commit.gpgsign=false", "commit", "-qm", "Contract fixture"]):
                roost.git(self.repo, *args)
        roost.git(self.repo, "worktree", "prune")
        self.task = None
        self.failures = 0

    def rpc(self, action, **args):
        reply = roost.rpc(dict(root=str(self.root), action=action, **args))
        if not reply["ok"]:
            raise RuntimeError("%s: %s" % (action, reply["error"]))
        return reply["result"]

    def record(self):
        return self.store.read(self.task["id"])

    def listed(self, full=False):
        return next(task for task in self.rpc("list", full=full) if task["id"] == self.task["id"])

    def pane(self):
        return roost.tmux(self.socket, "capture-pane", "-p", "-t", self.record()["paneId"], check=False).stdout

    def keys(self, *keys):
        for key in keys:
            roost.tmux(self.socket, "send-keys", "-t", self.record()["paneId"], key)
            time.sleep(0.3)

    def until(self, predicate, seconds, what):
        deadline = time.monotonic() + seconds
        while time.monotonic() < deadline:
            value = predicate()
            if value:
                return value
            if self.record()["status"] in roost.ENDED:
                raise RuntimeError("the agent stopped (%s) while waiting for %s; its screen ends:\n%s"
                                   % (self.record()["status"], what, self.screen()))
            time.sleep(0.5)
        raise RuntimeError("timed out after %ds waiting for %s; the agent's screen ends:\n%s"
                           % (seconds, what, self.screen()))

    def screen(self):
        lines = [line for line in self.pane().splitlines() if line.strip()]
        return "\n".join("        " + line[:100] for line in lines[-8:])

    def check(self, ok, message, detail=""):
        self.failures += 0 if ok else 1
        print(("  ok    " if ok else "  FAIL  ") + message + ("" if ok or not detail else ": " + str(detail)))

    def send(self, text):
        self.rpc("send", id=self.task["id"], text=text)

    def run(self):
        print("Live session in %s" % self.repo)
        # Manual mode, so it asks before commands: for many accounts Claude now
        # starts in auto mode, which approves most commands by itself.
        self.task = self.rpc("create", directory=str(self.repo), name="contract", socket=self.socket,
                             prompt="Reply with the single word PONG.",
                             command=["claude", "--model", "haiku", "--permission-mode", "manual"])
        try:
            self.steps()
        except Exception as error:  # A failed step ends the session; clean up after it.
            self.check(False, "%s: %s" % (type(error).__name__, error))
        finally:
            self.clean_up()
        return self.failures

    def steps(self):
        # First run only: Claude asks to trust the repository, defaulting to No.
        deadline = time.monotonic() + 20
        while time.monotonic() < deadline and self.record()["status"] == "starting":
            if "trust this folder" in self.pane():
                self.keys("Down", "Enter")
                break
            time.sleep(0.5)

        record = self.until(lambda: self.record().get("lastEvent") == "Stop" and self.record(), 90, "the first reply")
        self.check(record["status"] == "ready", "a finished turn is ready", record["status"])
        self.check("PONG" in (record.get("lastReply") or ""), "Stop reports the reply", record.get("lastReply"))
        transcript = record.get("transcript")
        self.check(bool(transcript) and Path(transcript).is_file(), "hooks report the transcript's path", transcript)
        self.check(bool(transcript) and Path(transcript).parent.name == roost.claude_project_folder(record["worktree"]),
                   "the transcript is where claude_project_folder would look", transcript)
        listed = self.listed(full=True)
        self.check("PONG" in (listed.get("lastMessage") or ""), "the listing shows the reply", listed.get("lastMessage"))

        ask = "Run `python3 contract_check.py` once with your Bash tool, in the foreground, and reply with its output."
        self.send(ask)
        record = self.until(lambda: self.record()["status"] == "permission" and self.record(), 60, "a permission request")
        self.check(record.get("request") == "Asks to run python3 contract_check.py", "the request says what it asks",
                   record.get("request"))
        self.until(lambda: "Do you want to proceed" in self.pane(), 20, "the permission dialog")
        self.keys("Enter")
        listed = self.until(lambda: (lambda task: task.get("lastEvent") == "Approved" and task)(self.listed()), 6,
                            "the approved command to show as running")
        self.check(listed["status"] == "running", "an approved command shows running before it ends", listed["status"])
        record = self.until(lambda: self.record().get("lastEvent") == "Stop" and self.record(), 60, "the command's end")
        self.check("contract check passed" in (record.get("lastReply") or ""), "the reply quotes the command's output",
                   record.get("lastReply"))

        self.send(ask)
        self.until(lambda: self.record()["status"] == "permission", 60, "the second permission request")
        self.until(lambda: "Do you want to proceed" in self.pane(), 20, "the permission dialog")
        self.keys("Escape")
        listed = self.until(lambda: (lambda task: task["status"] != "permission" and task)(self.listed()), 8,
                            "the declined request to be noticed")
        self.check((listed["status"], listed.get("lastEvent")) == ("ready", "Interrupt"),
                   "a declined request shows ready", (listed["status"], listed.get("lastEvent")))

        self.send("Write the numbers from 1 to 400, one per line, with no other text.")
        self.until(lambda: self.record()["status"] == "running", 30, "the counting turn")
        time.sleep(2)
        self.keys("Escape")
        listed = self.until(lambda: (lambda task: task["status"] == "ready" and task)(self.listed()), 10,
                            "the stopped turn to be noticed")
        if listed.get("lastEvent") == "Stop":
            print("  --    Esc arrived after the turn ended; not checked")
        else:
            self.check(listed.get("lastEvent") == "Interrupt", "a turn stopped with Esc shows ready", listed.get("lastEvent"))

        before = self.record()
        if "--skip-idle" not in sys.argv:
            # Claude's idle reminder comes a minute after the turn.
            time.sleep(70)
            after = self.record()
            self.check(after == before, "a minute idle changes nothing",
                       {key: after.get(key) for key in ("status", "lastEvent", "updatedAt")})

        self.keys("/clear", "Enter")
        record = self.until(lambda: (lambda task: task.get("agentSession") != before.get("agentSession") and task)(
            self.record()), 20, "a new conversation after /clear")
        self.check((record["status"], record.get("lastReply")) == ("ready", None),
                   "/clear starts a waiting conversation with no reply", (record["status"], record.get("lastReply")))
        self.check(record.get("transcript") != before.get("transcript"), "/clear reports the new transcript")

    def clean_up(self):
        for action in ("stop", "retire"):
            try:
                self.rpc(action, id=self.task["id"])
            except (RuntimeError, TypeError):
                pass
        roost.tmux(self.socket, "kill-server", check=False)
        socket_dir = Path(os.environ.get("TMUX_TMPDIR") or "/tmp") / ("tmux-%d" % os.getuid())
        (socket_dir / self.socket).unlink(missing_ok=True)
        shutil.rmtree(self.root, ignore_errors=True)


def main():
    problems = static_check()
    if "--live" in sys.argv:
        problems += Session().run()
    print("All as expected" if not problems else "%d to look at" % problems)
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main())
