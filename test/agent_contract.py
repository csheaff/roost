#!/usr/bin/env python3
"""Check Roost's reading of each installed agent.

Roost learns what an agent does from what it reports: Claude Code's and
Codex's hooks, and the events Pi and OpenCode give the extension or plugin
Roost loads into them. Each agent updates often, and what it reports can
change without notice.

  python3 test/agent_contract.py [AGENT...]
      Scan each installed agent (claude, codex, pi, opencode; all by
      default) for the events and fields Roost relies on, and for ones it
      has not seen. Free; an agent that is not installed is skipped.

  python3 test/agent_contract.py --live [--program-status] [AGENT...]
      Also take each AGENT (claude by default) through a real session
      driven through Roost's helper, check the status Roost derives at each
      step, and keep what the agent reported in test/captures (see
      agent_captures.py). Claude uses Haiku; Codex its default model; Pi
      and OpenCode the model they are set to use. --program-status relays
      the agent's OSC 7501 reports too, as roost-program-status does.

Exits nonzero when something is new or a check fails.
"""
import json
import os
from pathlib import Path
import re
import shutil
import sys
import time

sys.path.insert(0, str(Path(__file__).resolve().parent))
import claude_contract  # noqa: E402
from claude_contract import roost  # noqa: E402

# Codex hook events Roost does not listen to, and why each changes nothing.
CODEX_IGNORED_EVENTS = {
    "PreCompact": "compaction starts; the turn goes on",
    "PostCompact": "compaction ended; the turn goes on",
    "SubagentStart": "a subagent started; the turn goes on",
    "SubagentStop": "a subagent ended; the turn goes on",
}
# Fields of Codex's hook payloads the helper reads.
CODEX_PAYLOAD_FIELDS = ("hook_event_name", "session_id", "cwd", "tool_name", "tool_input")

# Pi extension events Roost does not listen to, and why each changes nothing.
PI_IGNORED_EVENTS = dict(
    {event: "a step inside a run, which agent_start and agent_end bound" for event in (
        "after_provider_response", "agent_before_settle", "before_agent_start", "before_provider_headers",
        "before_provider_request", "cache_warming_decision", "context", "context_with_system",
        "message_end", "message_start", "message_update", "provider_stream_event", "tool_call",
        "tool_execution_end", "tool_execution_start", "tool_execution_update", "tool_result",
        "turn_end", "turn_start")},
    **{event: "the session changes, not whether it works or waits" for event in (
        "mcp_servers_change", "model_select", "resources_discover", "session_before_compact",
        "session_before_fork", "session_before_switch", "session_before_tree", "session_compact",
        "session_compact_failed", "session_info_changed", "session_tree", "thinking_level_select")},
    input="what you typed, before it starts a run",
    project_trust="Pi asks to trust the project, as a dialog that ui_prompt_start reports",
    session_shutdown="Pi emits it when replacing a session too; the runner records the actual exit",
    user_bash="a command you ran yourself with !",
)
# What Roost's extension calls on Pi's context, and reads of its events.
PI_API = (r"isIdle\(\): boolean", r"hasPendingMessages\(\): boolean", r"sessionManager: ",
          r"interface AgentSettledEvent \{[^}]*\baborted: boolean",
          r"interface UIPromptStartEvent \{[^}]*\btitle\?: string")
PI_FLAGS = ("--extension", "--session-dir", "--session")

# OpenCode events, of the kinds Roost's plugin reads, that it does not.
OPENCODE_IGNORED_EVENTS = {
    "message.part.delta": "a reply as it streams; message.part.updated has the whole part",
    "message.part.removed": "a part went; the reply is read from the parts that stay",
    "message.removed": "a message went; the turn goes on",
    "question.rejected": "you dismissed a question; its turn's end says so",
    "session.compacted": "compaction ended; session.status says whether it works",
    "session.diff": "the session's changes; Roost reads Git",
    "session.idle": "deprecated; session.status says the same",
}
# Families of events checked for new ones; the rest are the TUI's own.
OPENCODE_FAMILIES = ("session.", "message.", "permission.", "question.")
# The events of the session engine OpenCode is moving to, which 1.19
# defines beside the ones Roost's plugin reads. Should those go, the scan
# says so, and the plugin needs to move too.
OPENCODE_NEXT = "session.next."


class Scan:
    """One agent's scan: prints a line per check and counts problems."""

    def __init__(self, label):
        self.label = label
        self.problems = 0

    def report(self, ok, message):
        self.problems += 0 if ok else 1
        print(("  ok    " if ok else "  NEW   " if ok is None else "  FAIL  ") + message)

    def events(self, found, listened, ignored, kind="event"):
        """Compare FOUND, the agent's events, with those Roost LISTENED to
        and IGNORED."""
        if not found:
            self.report(False, "found no %ss; the scan needs updating for this version" % kind)
            return
        for event in sorted(found - set(listened) - set(ignored)):
            self.report(None, "%s %s: decide whether Roost should listen to it" % (kind, event))
        for event in sorted(set(listened) - found):
            self.report(False, "%s %s, which Roost listens to, is gone" % (kind, event))
        if found <= set(listened) | set(ignored) and set(listened) <= found:
            self.report(True, "%d %ss, %d of them Roost's" % (len(found), kind, len(set(listened))))


def installed(name):
    """The real file of the agent NAME runs, and the version it prints, or None."""
    found = shutil.which(name)
    if not found:
        print("%s is not installed; skipped" % name)
        return None
    out = roost.subprocess.run([found, "--version"], text=True, capture_output=True).stdout
    version = re.search(r"\d+\.\d+\.\d+", out)
    return Path(os.path.realpath(found)), version.group(0) if version else "unknown"


def package_root(path):
    """The npm package PATH, a file in it, belongs to."""
    for parent in path.parents:
        if (parent / "package.json").is_file():
            return parent
    return path.parent


def native_binary(path, name):
    """The program an npm wrapper at PATH runs, or PATH if it is the program."""
    if path.suffix not in (".js", ".mjs", ".cjs"):
        return path
    candidates = [found for found in package_root(path).glob("node_modules/**/" + name)
                  if found.is_file() and found.stat().st_size > 1 << 20]
    return candidates[0] if candidates else path


def scan_codex():
    found = installed("codex")
    if not found:
        return 0
    path, version = found
    program = native_binary(path, "codex")
    print("Codex %s, %s" % (version, program))
    scan = Scan("Codex")
    if version != "unknown" and tuple(map(int, version.split("."))) < (0, 160, 0):
        scan.report(False, "Roost needs Codex 0.160.0 or newer for its lifecycle hooks")
    data = program.read_bytes()
    # Codex carries a JSON schema of each hook's input.
    schemas = {}
    for match in re.finditer(rb"[a-z-]+\.command\.input(\{\n.*?\n\})", data, re.S):
        try:
            schema = json.loads(match.group(1))
            schemas[schema["properties"]["hook_event_name"]["const"]] = schema
        except (ValueError, KeyError, TypeError):
            continue
    scan.events(set(schemas), roost.CODEX_HOOK_EVENTS, CODEX_IGNORED_EVENTS, "hook event")
    absent = sorted({field for event in roost.CODEX_HOOK_EVENTS if event in schemas
                     for field in ("hook_event_name", "session_id", "cwd")
                     if field not in schemas[event]["properties"]}
                    | {field for event in ("PreToolUse", "PermissionRequest") if event in schemas
                       for field in ("tool_name", "tool_input") if field not in schemas[event]["properties"]})
    if schemas:
        scan.report(not absent, "payload fields Roost reads" + (": missing " + ", ".join(absent) if absent else ""))
    # Its hooks are given on the command line, as -c hooks.EVENT=[...].
    scan.report(b"session_flags" in data, "hooks set with -c count" if b"session_flags" in data
                else "no longer finds hooks set on the command line; check CodexAgent.launch")
    return scan.problems


def scan_pi():
    found = installed("pi")
    if not found:
        return 0
    path, version = found
    root = package_root(path)
    print("Pi %s, %s" % (version, root))
    scan = Scan("Pi")
    types = root / "dist/core/extensions/types.d.ts"
    if not types.is_file():
        scan.report(False, "no extension types at %s; the scan needs updating" % types)
        return scan.problems
    declared = types.read_text()
    events = set(re.findall(r'on\(event: "([a-z_]+)"', declared))
    listened = set(re.findall(r'pi\.on\("([a-z_]+)"', roost.PI_EXTENSION))
    scan.events(events, listened, PI_IGNORED_EVENTS, "extension event")
    missing = [pattern for pattern in PI_API if not re.search(pattern, declared, re.S)]
    scan.report(not missing, "the context and event fields Roost's extension reads"
                + (": missing " + ", ".join(missing) if missing else ""))
    code = "".join(file.read_text(errors="replace") for file in (root / "dist").glob("**/*.js"))
    absent = [flag for flag in PI_FLAGS if '"%s"' % flag not in code]
    scan.report(not absent, "options Roost passes" + (": missing " + ", ".join(absent) if absent else ""))
    return scan.problems


def scan_opencode():
    found = installed("opencode")
    if not found:
        return 0
    path, version = found
    program = native_binary(path, "opencode")
    print("OpenCode %s, %s" % (version, program))
    scan = Scan("OpenCode")
    data = program.read_bytes()
    defined = set(match.decode() for match in
                  re.findall(rb'\(\{type:"([a-z]+(?:\.[a-z_]+)+)",(?:\.\.\.[\w$]+,)?schema:', data))
    events = {event for event in defined if event.startswith(OPENCODE_FAMILIES) and not event.startswith(OPENCODE_NEXT)}
    listened = set(re.findall(r'case "([a-z]+\.[a-z.]+)":', roost.OPENCODE_PLUGIN))
    scan.events(events, listened, OPENCODE_IGNORED_EVENTS, "event")
    words = (b"OPENCODE_CONFIG_CONTENT", b"OPENCODE_PURE", b"MessageAbortedError")
    absent = [word.decode() for word in words if word not in data]
    scan.report(not absent, "the settings and errors Roost names" + (": missing " + ", ".join(absent) if absent else ""))
    return scan.problems


SCANS = {"claude": claude_contract.static_check, "codex": scan_codex, "pi": scan_pi, "opencode": scan_opencode}


class CodexSession(claude_contract.Session):
    """A Roost task with real Codex. Read-only, so it asks before a command
    that writes."""

    agent = "codex"
    command = ["codex", "--sandbox", "read-only", "--ask-for-approval", "on-request"]

    def __init__(self, program_status=False):
        super().__init__(program_status)
        config = Path(os.environ.get("CODEX_HOME") or Path.home() / ".codex") / "config.toml"
        # Trusting the repository and Roost's hooks writes to Codex's config;
        # those tables are put back as they were, and the rest left alone.
        self.config = (config, config.read_text() if config.is_file() else None)

    def startup(self):
        """Answer what Codex asks of a repository and hooks it has not seen,
        before it runs the task's prompt: to trust the repository, and to
        review Roost's hooks. The config Codex keeps them in is put back
        afterwards, so each run asks again."""
        deadline = time.monotonic() + 90
        trusted = False
        while time.monotonic() < deadline:
            screen = self.pane()
            if "Trust this folder?" in screen or "Hooks need review" in screen:
                self.keys("Enter")
            elif "t trust all" in screen:
                self.keys("t")
                trusted = True
            elif trusted and "esc close" in screen:
                self.keys("Escape")
                return
            time.sleep(1)
        raise RuntimeError("Codex never asked to review Roost's hooks; its screen ends:\n" + self.screen())

    def steps(self):
        self.startup()
        record = self.until(lambda: self.record().get("lastEvent") == "Stop" and self.record(), 120, "the first reply")
        self.check(record["status"] == "ready", "a finished turn is ready", record["status"])
        self.check(bool(record.get("agentSession")), "hooks report the session", record.get("agentSession"))

        ask = "Create an empty file named approved.txt with the shell command `touch approved.txt`, then reply DONE."
        self.step("approve a command")
        self.send(ask)
        # The hook's words, as a relayed report can ask first in its own.
        record = self.when(lambda task: task["status"] == "permission"
                           and (task.get("request") or "").startswith("Asks to"), 120, "a permission request")
        self.check(bool(record.get("request")), "the request says what it asks", record.get("request"))
        time.sleep(2)
        self.keys("Enter")
        record = self.until(lambda: self.record().get("lastEvent") == "Stop" and self.record(), 120,
                            "the command's end")
        self.check(record["status"] == "ready", "the turn ends ready", record["status"])

        self.step("decline a command with Esc")
        self.send(ask.replace("approved", "declined"))
        self.until(lambda: self.record()["status"] == "permission", 120, "the second permission request")
        time.sleep(2)
        self.keys("Escape")
        # Relayed, a decline reports work for a moment before its hook ends the turn.
        record = self.when(lambda task: task["status"] == "ready", 30, "the declined request to be noticed")
        self.check(record.get("lastEvent") == "Interrupt", "a declined request shows ready",
                   (record["status"], record.get("lastEvent")))

        self.step("stop a turn with Esc")
        self.send("Write the numbers from 1 to 400, one per line, with no other text.")
        self.until(lambda: self.record()["status"] == "running", 60, "the counting turn")
        time.sleep(2)
        self.keys("Escape")
        record = self.when(lambda task: task["status"] == "ready" and task.get("lastEvent") in ("Interrupt", "Stop"),
                           30, "the stopped turn to be noticed")
        self.check(record.get("lastEvent") in ("Interrupt", "Stop"), "a turn stopped with Esc shows ready",
                   record.get("lastEvent"))

    def clean_up(self):
        super().clean_up()
        path, before = self.config
        if path.is_file():
            after = restore_codex_tables(path.read_text(), before, self.repo)
            if after.strip() or before is not None:
                path.write_text(after)
            else:
                path.unlink()


class PiSession(claude_contract.Session):
    """A Roost task with real Pi, on the model Pi is set to use."""

    agent = "pi"
    command = ["pi"]

    def steps(self):
        record = self.until(lambda: self.record().get("lastEvent") == "Stop" and self.record(), 180, "the first reply")
        self.check(record["status"] == "ready", "a finished turn is ready", record["status"])
        self.check(bool(record.get("agentSession")), "its extension reports the session", record.get("agentSession"))

        self.step("stop a turn with Esc")
        self.send("Write the numbers from 1 to 400, one per line, with no other text.")
        self.until(lambda: self.record()["status"] == "running", 60, "the counting turn")
        time.sleep(3)
        self.keys("Escape")
        # Pi says a run ended, and only then whether you stopped it.
        self.when(lambda task: task["status"] == "ready", 30, "the stopped turn to be noticed")
        deadline = time.monotonic() + 5
        while time.monotonic() < deadline and self.record().get("lastEvent") != "Interrupt":
            time.sleep(0.2)
        record = self.record()
        if record.get("lastEvent") == "Stop":
            print("  --    Esc arrived after the turn ended; not checked")
        else:
            self.check(record.get("lastEvent") == "Interrupt", "a turn stopped with Esc shows interrupted",
                       record.get("lastEvent"))

        self.step("a second turn")
        # The last turn may have ended on Stop too, if Esc came after it.
        before = self.record().get("updatedAt")
        self.send("Reply with the single word PING.")
        record = self.when(lambda task: task.get("lastEvent") == "Stop" and task.get("updatedAt") != before,
                           180, "the reply")
        self.check("PING" in (record.get("lastReply") or self.listed(full=True).get("lastMessage") or ""),
                   "the reply is read", record.get("lastReply"))


# A TOML table's header, on a line of its own: keys bare or quoted, joined by dots.
TOML_KEY = r"""(?:[A-Za-z0-9_-]+|"(?:[^"\\\n]|\\.)*"|'[^'\n]*')"""
TOML_HEADER = re.compile(r"\[\[?\s*%s(?:\s*\.\s*%s)*\s*\]\]?\s*(#.*)?" % (TOML_KEY, TOML_KEY))
# What may open a string, and what closes each.
TOML_STRING = re.compile(r"""\"\"\"|'''|"|'""")
TOML_CLOSE = {'"""': re.compile(r'(?<!\\)"""'), "'''": re.compile("'''"),
              '"': re.compile(r'(?<!\\)"'), "'": re.compile("'")}


def toml_tables(text):
    """TEXT as (header, text) pairs, a table's header and the lines it
    holds, the first of them without a header, which join to TEXT again. A
    line inside a multi-line string or array is no header."""
    tables = [[None, ""]]
    depth, string = 0, None
    for line in text.splitlines(keepends=True):
        if not depth and not string and TOML_HEADER.fullmatch(line.strip()):
            tables.append([line.strip(), ""])
        else:
            i = 0
            while i < len(line):
                if string:
                    closed = TOML_CLOSE[string].search(line, i)
                    if not closed:
                        break
                    i, string = closed.end(), None
                    continue
                opened = TOML_STRING.match(line, i)
                if opened:
                    string, i = opened.group(0), opened.end()
                elif line[i] == "#":
                    break
                else:
                    depth = max(0, depth + {"[": 1, "]": -1}.get(line[i], 0))
                    i += 1
            # A one-line string ends with its line.
            if string in ('"', "'"):
                string = None
        tables[-1][1] += line
    return [tuple(table) for table in tables]


def restore_codex_tables(after, before, repo):
    """AFTER, Codex's config, with the tables a contract run makes as they
    were in BEFORE, or gone if BEFORE had none: the scratch repository's
    trust, and the review of hooks given on the command line, which Codex
    keys by event alone, so a run replaces the review of Roost's real hooks.
    Whatever else changed meanwhile, as another Codex's, stays."""
    def ours(header):
        return bool(header) and (header == "[projects.%s]" % json.dumps(str(repo))
                                 or header.startswith('[hooks.state."/<session-flags>/'))
    kept = {header: text for header, text in toml_tables(before or "") if ours(header)}
    result = []
    for header, text in toml_tables(after):
        if ours(header):
            text = kept.pop(header, "")
        result.append(text)
    result.extend(kept.values())
    # A table that ended its file may have no newline before the next.
    return "".join(text if text.endswith("\n") or i == len(result) - 1 else text + "\n"
                   for i, text in enumerate(result) if text)


SESSIONS = {"claude": claude_contract.Session, "codex": CodexSession, "pi": PiSession}


def main():
    args = [arg for arg in sys.argv[1:] if not arg.startswith("--")]
    unknown = [arg for arg in args if arg not in SCANS]
    if unknown:
        sys.exit("Unknown agent: %s (choose from %s)" % (", ".join(unknown), ", ".join(SCANS)))
    live = "--live" in sys.argv
    problems = 0
    for agent in args or list(SCANS):
        problems += SCANS[agent]()
    for agent in (args or ["claude"]) if live else []:
        if agent not in SESSIONS:
            print("No live session for %s yet" % agent)
            continue
        problems += SESSIONS[agent]("--program-status" in sys.argv).run()
    print("All as expected" if not problems else "%d to look at" % problems)
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main())
