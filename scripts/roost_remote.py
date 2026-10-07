#!/usr/bin/env python3
"""Roost's host-side task manager. Standard library only; JSON over stdin/stdout."""

import contextlib
import datetime
import fcntl
import hashlib
import json
import os
from pathlib import Path
import re
import shlex
import shutil
import signal
import socket
import subprocess
import sys
import tempfile
import unicodedata
import uuid


class RoostError(Exception):
    pass


# Agent states that mean work may be in progress.
ACTIVE = ("starting", "running", "permission", "background")
# States in which the agent process is known to have ended.
ENDED = ("stopped", "exited", "failed", "crashed")
# Computed per request and never persisted in a task record.
TRANSIENT = ("live", "diff", "dirty", "files", "ahead", "behind", "update", "worktreeMissing",
             "prStatus", "lastMessage", "gitStamp")
LAST_MESSAGE_TAIL = 256 * 1024
LAST_MESSAGE_LIMIT = 2000
INTERRUPT_TAIL = 64 * 1024
DEFAULT_BRANCH_PREFIX = "roost/"


def now():
    return datetime.datetime.now(datetime.timezone.utc).isoformat()


def parse_time(value):
    """An ISO 8601 time as written by now() or by agents ("...Z"), or None."""
    try:
        parsed = datetime.datetime.fromisoformat(value.replace("Z", "+00:00"))
    except (AttributeError, TypeError, ValueError):
        return None
    return parsed if parsed.tzinfo else None


def text(value):
    """An optional nonempty string from a request, else None.
    Older Emacs clients encoded nil as an empty JSON object."""
    return value if isinstance(value, str) and value else None


def execute(argv, cwd=None, check=True, input=None):
    # A file name that is not UTF-8, possible on Linux, must not fail every
    # listing of the host: undecodable bytes are replaced, here and below.
    result = subprocess.run(argv, cwd=cwd, input=input, text=True, errors="replace",
                            stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    if check and result.returncode:
        raise RoostError(result.stderr.strip() or result.stdout.strip()
                         or "Command failed: " + shlex.join(argv))
    return result


def git(repo, *args, check=True):
    return execute(["git", "-C", str(repo), *args], check=check)


def read_git(repo, *args):
    """Run a read-only git command for statistics, without optional locks.
    `git status` would otherwise refresh the index under its lock, and an
    agent committing in the same worktree at that moment would fail."""
    return git(repo, "--no-optional-locks", *args, check=False)


REMOTE_GIT_TIMEOUT = 120
CREDENTIAL_FAILURES = ("Permission denied (publickey)", "could not read Username",
                       "Authentication failed", "terminal prompts disabled")


def run_detached(argv, timeout, env=None):
    """Run ARGV in a session of its own, without stdin, for at most TIMEOUT
    seconds. Without a controlling terminal nothing it starts can prompt. On
    timeout the whole process group is killed, so helpers such as ssh or a
    credential helper die with it, and TimeoutExpired is raised."""
    process = subprocess.Popen(argv, text=True, errors="replace", stdin=subprocess.DEVNULL, start_new_session=True,
                               stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=env)
    try:
        stdout, stderr = process.communicate(timeout=timeout)
    except subprocess.TimeoutExpired:
        with contextlib.suppress(ProcessLookupError, PermissionError):
            os.killpg(process.pid, signal.SIGKILL)
        process.communicate()
        raise
    return subprocess.CompletedProcess(argv, process.returncode, stdout, stderr)


def remote_git(repo, *args, check=True, timeout=REMOTE_GIT_TIMEOUT):
    """Run Git where it talks to the remote, so it can never prompt on the
    helper's RPC pipe or hang forever. Explains credential failures."""
    try:
        result = run_detached(["git", "-C", str(repo), *args], timeout,
                              env=dict(os.environ, GIT_TERMINAL_PROMPT="0", GIT_ASKPASS="",
                                       SSH_ASKPASS_REQUIRE="never", GCM_INTERACTIVE="never"))
    except subprocess.TimeoutExpired:
        raise RoostError("git %s timed out after %d seconds" % (args[0], timeout))
    if check and result.returncode:
        message = (result.stderr.strip() or result.stdout.strip()
                   or "Command failed: " + shlex.join(["git", *args]))
        if any(failure in message for failure in CREDENTIAL_FAILURES):
            message += ("\nRoost pushes with the Git credentials on this host (%s): run "
                        "`gh auth setup-git` there for HTTPS, or add an SSH key that GitHub accepts."
                        % socket.gethostname())
        raise RoostError(message)
    return result


def gh(cwd, *args, timeout=60):
    """Run the GitHub CLI, finding it on the same PATH agents get."""
    path = agent_path(os.environ.get("PATH", ""))
    executable = shutil.which("gh", path=path)
    if not executable:
        raise RoostError("The GitHub CLI (gh) is not installed on this host; install it and run `gh auth login`")
    try:
        result = subprocess.run([executable, *args], cwd=cwd, text=True, errors="replace", timeout=timeout,
                                stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                env=dict(os.environ, PATH=path))
    except subprocess.TimeoutExpired:
        raise RoostError("gh timed out: " + shlex.join(args[:2]))
    if result.returncode:
        raise RoostError(result.stderr.strip() or result.stdout.strip()
                         or "Command failed: " + shlex.join(["gh", *args]))
    return result.stdout


def tmux(socket, *args, check=True, input=None):
    return execute(["tmux", "-L", socket, *args], check=check, input=input)


def enable_extended_keys(socket):
    """Let agents tell Shift+Return from Return. A program asks the terminal
    for modified keys as it starts, and tmux (3.2 or later) grants it only
    while extended-keys is on; otherwise Claude Code gets Shift+Return as
    Return and submits a half-written prompt. Programs that do not ask see
    no difference, and a server set to "always" is left alone."""
    current = tmux(socket, "show-options", "-sv", "extended-keys", check=False)
    if current.returncode == 0 and current.stdout.strip() == "off":
        tmux(socket, "set-option", "-s", "extended-keys", "on", check=False)


def session_name(socket, repo, repo_hash):
    """The tmux session for REPO's tasks, named after the project so tmux
    and Emacs show which project it holds. A running session named in the
    older style, by hash alone, keeps holding that project's tasks."""
    old = "roost-" + repo_hash
    if tmux(socket, "has-session", "-t", "=" + old, check=False).returncode == 0:
        return old
    project = re.sub(r"[^A-Za-z0-9_-]+", "-", Path(repo).name).strip("-")[:24] or "project"
    return "roost-%s-%s" % (project, repo_hash[:4])


def atomic_text(path, text):
    path = Path(path)
    path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    fd, temporary = tempfile.mkstemp(prefix=".roost-", dir=path.parent)
    try:
        with os.fdopen(fd, "w") as output:
            output.write(text)
            output.flush()
            os.fsync(output.fileno())
        os.replace(temporary, path)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


def atomic_json(path, data):
    atomic_text(path, json.dumps(data, ensure_ascii=False) + "\n")


class Store:
    def __init__(self, root):
        self.root = Path(root).expanduser().absolute()
        self.root.mkdir(mode=0o700, parents=True, exist_ok=True)
        self.tasks_dir = self.root / "tasks"
        self.tasks_dir.mkdir(mode=0o700, exist_ok=True)

    @contextlib.contextmanager
    def locked(self):
        # Agent hooks take this lock on every event, so hold it only for
        # short record and tmux operations, never for slow Git work.
        with (self.root / "registry.lock").open("a") as lock:
            os.chmod(lock.name, 0o600)
            fcntl.flock(lock, fcntl.LOCK_EX)
            yield

    def path(self, task_id):
        if not isinstance(task_id, str) or not re.fullmatch(r"[a-f0-9]{16}", task_id):
            raise RoostError("Invalid task ID")
        return self.tasks_dir / (task_id + ".json")

    def read(self, task_id):
        try:
            return json.loads(self.path(task_id).read_text())
        except FileNotFoundError:
            raise RoostError("Task no longer exists: " + task_id)

    def save(self, task):
        atomic_json(self.path(task["id"]),
                    {key: value for key, value in task.items() if key not in TRANSIENT})

    def remove(self, task_id):
        """Delete a task's record and hook settings. Conversations are kept."""
        path = self.path(task_id)
        for stale in (path, path.with_suffix(".settings")):
            with contextlib.suppress(FileNotFoundError):
                stale.unlink()

    def all(self):
        tasks = []
        for path in sorted(self.tasks_dir.glob("*.json")):
            # One unreadable record must not hide every other task.
            with contextlib.suppress(OSError, ValueError):
                tasks.append(json.loads(path.read_text()))
        return tasks


# tmux reports these when no server is running on the socket, so no panes exist.
# "server exited unexpectedly" is a server still shutting down (tmux 3.4).
NO_SERVER = ("no server running", "No such file or directory", "Connection refused",
             "server exited unexpectedly")


def pane_inventory(socket):
    """Map pane IDs to their tmux details.
    Return {} when no server runs, or None when tmux could not answer (for
    example a client/server version mismatch after upgrading tmux)."""
    result = tmux(socket, "list-panes", "-a", "-F",
                  "#{pane_id}\t#{window_id}\t#{window_index}\t#{session_id}\t#{pane_dead}\t#{@roost_task_id}\t#{pane_pid}\t#{session_name}",
                  check=False)
    if result.returncode:
        return {} if any(marker in result.stderr for marker in NO_SERVER) else None
    panes = {}
    for line in result.stdout.splitlines():
        fields = line.split("\t", 7)
        if len(fields) == 8:
            pane, window, index, session, dead, task_id, pid, session_name = fields
            panes[pane] = dict(window=window, index=int(index), session=session,
                               dead=dead == "1", task=task_id, session_name=session_name,
                               pid=int(pid) if pid.isdigit() else None)
    return panes


def inventory_for(task):
    """The pane inventory for TASK's socket, or an error when tmux is unreadable."""
    inventory = pane_inventory(task["socket"])
    if inventory is None:
        raise RoostError("tmux did not answer on socket %r; check `tmux -L %s ls` on the host"
                         % (task["socket"], task["socket"]))
    return inventory


def owned_pane(task, inventory):
    pane = inventory.get(task.get("paneId"))
    # Pane IDs may be reused after a tmux server restart. A per-pane ownership
    # tag prevents steering or killing an unrelated process with the same ID.
    if pane and pane["task"] == task["id"] and pane["window"] == task.get("windowId"):
        return pane
    return None


def check_worktree(store, task, branch=True):
    """TASK's worktree, refusing paths Roost does not own. With BRANCH, also
    refuse one no longer on the task's branch, as after an agent made a
    branch of its own: merging, pushing or removing would then act on the
    wrong commits. Running an agent or shell there needs no such check."""
    worktree = Path(task["worktree"]).resolve()
    if not worktree.is_relative_to((store.root / "worktrees").resolve()):
        raise RoostError("Task worktree is outside Roost's worktree directory")
    if worktree == Path(task["repo"]).resolve():
        raise RoostError("Refusing to remove the primary repository")
    if branch and worktree.exists():
        current = git(worktree, "symbolic-ref", "--short", "-q", "HEAD", check=False).stdout.strip()
        if current != task["branch"]:
            raise RoostError("The task's worktree is on %s, not the task's branch %s; check out %s there, "
                             "bringing over any commits you want, then try again"
                             % (current or "a detached HEAD", task["branch"], task["branch"]))
    return worktree


def ref_exists(repo, branch):
    return bool(branch) and git(repo, "show-ref", "--verify", "--quiet",
                                "refs/heads/" + branch, check=False).returncode == 0


def fork_point(worktree, task):
    """Where the task's own work begins. Updating a task merges its
    integration branch in, which moves the merge base forward; before that,
    or when the integration branch was rewritten, it is the starting commit."""
    base = task["baseCommit"]
    integration = task.get("integrationBranch")
    if integration:
        merged = git(worktree, "merge-base", "refs/heads/" + integration, "HEAD", check=False).stdout.strip()
        if merged and git(worktree, "merge-base", "--is-ancestor", base, merged, check=False).returncode == 0:
            return merged
    return base


def delete_branch(repo, branch, commit):
    """Delete BRANCH only if it still points at the verified COMMIT."""
    ref = "refs/heads/" + branch
    worktrees = git(repo, "worktree", "list", "--porcelain").stdout.splitlines()
    if "branch " + ref in worktrees:
        raise RoostError("The task branch is checked out in another worktree; remove it there first")
    git(repo, "update-ref", "-d", ref, commit)


def claude_hook_settings(store, task):
    script = str(Path(__file__).resolve())
    command = shlex.join([sys.executable, script, "hook", str(store.root), task["id"], task["runId"]])
    events = ["SessionStart", "SessionEnd", "UserPromptSubmit", "PreToolUse",
              "PostToolUse", "PermissionRequest", "Notification", "Stop", "StopFailure"]
    settings = {"hooks": {event: [{"hooks": [{"type": "command", "command": command}]}]
                          for event in events}}
    path = store.tasks_dir / (task["id"] + ".settings")
    atomic_json(path, settings)
    return str(path)


def transcript_tail(path, limit=LAST_MESSAGE_TAIL):
    """Complete JSON lines from the last LIMIT bytes of a transcript, newest last."""
    with open(path, "rb") as handle:
        size = handle.seek(0, os.SEEK_END)
        handle.seek(max(0, size - limit))
        data = handle.read()
    lines = data.splitlines()
    if size > limit and lines:
        lines.pop(0)  # Starts mid-line.
    entries = []
    for line in lines:
        try:
            entries.append(json.loads(line))
        except ValueError:
            pass
    return entries


def message_text(content, kinds=("text",)):
    """The text parts of a message's content, joined; None if there are none."""
    if isinstance(content, str):
        parts = [content]
    elif isinstance(content, list):
        parts = [part["text"] for part in content
                 if isinstance(part, dict) and part.get("type") in kinds and isinstance(part.get("text"), str)]
    else:
        return None
    joined = "\n\n".join(part.strip() for part in parts if part.strip())
    return joined or None


def last_assistant_text(entries, extract):
    """The newest nonempty text EXTRACT finds. Agents write a message as several
    entries (text, then tool calls), so entries without text are skipped."""
    for entry in reversed(entries):
        if isinstance(entry, dict):
            found = extract(entry)
            if found:
                return found
    return None


def last_message(task):
    """The agent's latest reply, shortened for display, or None. A missing or
    malformed transcript never fails a request."""
    try:
        reply = agent_for(task).last_message(task)
    except (RoostError, OSError, ValueError, TypeError, AttributeError, KeyError):
        return None
    if not reply:
        return None
    return reply if len(reply) <= LAST_MESSAGE_LIMIT else reply[:LAST_MESSAGE_LIMIT].rstrip() + "…"


CLAUDE_FOLDER_LIMIT = 200


def claude_project_folder(directory):
    """The folder in ~/.claude/projects that holds the transcripts of Claude
    Code sessions run in DIRECTORY, named as Claude Code names it: from the
    physical path, every UTF-16 unit but an ASCII letter or digit becomes
    "-", and a longer name is cut and given a hash of the whole path."""
    path = os.path.realpath(directory)
    data = path.encode("utf-16-le", "surrogatepass")
    units = [data[i] | data[i + 1] << 8 for i in range(0, len(data), 2)]
    name = "".join(chr(unit) if unit < 128 and chr(unit).isalnum() else "-" for unit in units)
    if len(name) <= CLAUDE_FOLDER_LIMIT:
        return name
    value = 0
    for unit in units:
        value = (value * 31 + unit) & 0xFFFFFFFF  # JavaScript's (h << 5) - h + c | 0
    value = abs(value - (1 << 32) if value >= 1 << 31 else value)
    digits = ""
    while True:
        value, digit = divmod(value, 36)
        digits = "0123456789abcdefghijklmnopqrstuvwxyz"[digit] + digits
        if not value:
            return name[:CLAUDE_FOLDER_LIMIT] + "-" + digits


class ClaudeAgent:
    """Agent-specific CLI and events; Git/tmux lifecycle stays outside this adapter."""

    default_command = ["claude"]

    def validate(self, command):
        validate_command(command, "Claude")
        reserved = {"--worktree", "-w", "--tmux", "--background", "--bg", "--resume", "-r",
                    "--continue", "-c", "--settings", "--bare", "--safe-mode", "--session-id"}
        if any(arg.split("=", 1)[0] in reserved for arg in command[1:]):
            raise RoostError("Roost owns worktrees, conversation resume, and hook settings; remove conflicting Claude flags")

    def launch(self, store, task, resume_conversation):
        argv = task["command"] + ["--settings", claude_hook_settings(store, task)]
        session = task.get("agentSession") or task.get("claudeSession")
        if resume_conversation and session:
            argv += ["--resume", session]
        elif text(task.get("prompt")):
            # Otherwise a prompt starting with -, such as a list, is an option.
            argv += ["--", task["prompt"]]
        return argv

    def observe(self, payload, current=None):
        """Status updates for hook PAYLOAD, given the task's CURRENT status."""
        event = payload.get("hook_event_name")
        sessions = (dict(agentSession=payload["session_id"], claudeSession=payload["session_id"])
                    if payload.get("session_id") else {})
        # /clear and /resume end one conversation and start another in the
        # same process, which goes on running.
        if event == "SessionEnd" and payload.get("reason") in ("clear", "resume"):
            return None
        # Compacting the conversation, which Claude also does by itself in the
        # middle of a turn, changes nothing about whether it waits for you.
        if event == "SessionStart" and payload.get("source") == "compact":
            return sessions or None
        status = {
            "SessionStart": "ready", "UserPromptSubmit": "running",
            "PreToolUse": "running", "PostToolUse": "running",
            "PermissionRequest": "permission", "SessionEnd": "exited", "StopFailure": "failed",
        }.get(event)
        if event == "Stop":
            status = "background" if payload.get("background_tasks") or payload.get("session_crons") else "ready"
        if event == "Notification":
            kind = payload.get("notification_type")
            # Claude reminds you of an agent waiting a minute after its turn.
            # That recovers a turn whose end went unreported, but for one
            # already waiting it is no news: a newer event would count an
            # agent you have seen as waiting again, or forget why it failed.
            if kind == "idle_prompt" and current not in ("starting", "running"):
                return None
            # A teammate's permission prompt, and a background agent of this
            # session blocked on you, also wait in this terminal.
            status = {"permission_prompt": "permission", "worker_permission_prompt": "permission",
                      "agent_needs_input": "permission", "idle_prompt": "ready"}.get(kind)
        if not status:
            return None
        updates = dict(status=status, updatedAt=now(), lastEvent=event, error=None)
        if event == "StopFailure":
            # The turn ended on an API error, such as a usage limit; the
            # agent itself still runs and waits for you.
            code = payload.get("error") if isinstance(payload.get("error"), str) else "unknown"
            details = payload.get("error_details")
            updates["error"] = ("Its turn ended on an API error (%s)" % code
                                + (": " + " ".join(details.split())[:REQUEST_LIMIT]
                                   if isinstance(details, str) and details.strip() else ""))
        # The old claudeSession field serves tasks whose original helper still runs.
        updates.update(sessions)
        return updates

    def transcript(self, task):
        session = task.get("agentSession") or task.get("claudeSession")
        if not session or not isinstance(task.get("worktree"), str):
            return None
        return Path.home() / ".claude" / "projects" / claude_project_folder(task["worktree"]) / (session + ".jsonl")

    def last_message(self, task):
        path = self.transcript(task)
        if not path:
            return None
        message = lambda entry: (entry.get("message") if isinstance(entry.get("message"), dict)
                                 and entry["message"].get("role") == "assistant" else None)
        return last_assistant_text(
            transcript_tail(path),
            lambda entry: message_text((message(entry) or {}).get("content")))

    def interrupted(self, task):
        """Whether you stopped the agent's turn since its last hook event, with
        Esc or by declining a permission request. Claude runs no hook for
        either, and waits for a prompt; its transcript records the interrupt."""
        path = self.transcript(task)
        since = parse_time(task.get("updatedAt"))
        if not path or not since or not path.is_file():
            return False
        if path.stat().st_mtime < since.timestamp():
            return False
        for entry in reversed(transcript_tail(path, INTERRUPT_TAIL)):
            message = entry.get("message") if isinstance(entry, dict) else None
            if entry.get("type") not in ("user", "assistant") or not isinstance(message, dict):
                continue
            stamp = parse_time(entry.get("timestamp"))
            return bool(message.get("role") == "user" and stamp and stamp >= since
                        and (message_text(message.get("content")) or "").startswith(
                            "[Request interrupted by user"))
        return False


# Codex asks the user to review hook commands and remembers the approval.
# The command runs this fixed shim, which hands the event to the helper
# version that launched the task (from its environment), so upgrading
# Roost does not change the command or ask for review again.
HOOK_SHIM = (
    "import os, sys\n"
    "helper = os.environ.get('ROOST_HELPER')\n"
    "if helper:\n"
    "    os.execv(sys.executable, [sys.executable, helper, 'hook-env'])\n"
)


def hook_shim(store):
    path = store.root / "hook.py"
    if not path.exists() or path.read_text() != HOOK_SHIM:
        atomic_text(path, HOOK_SHIM)
    return str(path)


class CodexAgent:
    """Native Codex TUI with per-invocation, normally reviewed lifecycle hooks."""

    default_command = ["codex"]

    def validate(self, command):
        validate_command(command, "Codex")
        reserved = {"resume", "fork", "exec", "review", "app-server", "--remote", "--cd", "-C"}
        if any(arg.split("=", 1)[0] in reserved for arg in command[1:]):
            raise RoostError("Roost owns Codex's working directory and conversation resume; use interactive CLI options only")

    def launch(self, store, task, resume_conversation):
        # Environment carries task/run identity and the helper, so the
        # reviewed hook command stays the same across tasks and upgrades.
        command = shlex.join([sys.executable, hook_shim(store)])
        argv = list(task["command"])
        for event in ("SessionStart", "SessionEnd", "UserPromptSubmit", "PreToolUse",
                      "PostToolUse", "PermissionRequest", "Stop", "Interrupt"):
            handler = '{ hooks = [{ type = "command", command = ' + json.dumps(command) + ', timeout = 3 }] }'
            argv += ["-c", "hooks." + event + "=[" + handler + "]"]
        session = task.get("agentSession")
        if resume_conversation and session:
            argv += ["resume", session]
        elif text(task.get("prompt")):
            argv += ["--", task["prompt"]]
        return argv

    def observe(self, payload, current=None):
        event = payload.get("hook_event_name")
        status = {"SessionStart": "ready", "SessionEnd": "exited", "UserPromptSubmit": "running",
                  "PreToolUse": "running", "PostToolUse": "running", "PermissionRequest": "permission",
                  "Stop": "ready", "Interrupt": "ready"}.get(event)
        if not status:
            return None
        updates = dict(status=status, updatedAt=now(), lastEvent="Stop" if event == "Interrupt" else event)
        if payload.get("session_id"):
            updates["agentSession"] = payload["session_id"]
        return updates

    def last_message(self, task):
        session = task.get("agentSession")
        if not session or not re.fullmatch(r"[\w.-]+", session):
            return None
        sessions = Path.home() / ".codex" / "sessions"
        files = sorted(sessions.glob("*/*/*/rollout-*-" + session + ".jsonl"))
        if not files:
            return None

        def extract(entry):
            payload = entry.get("payload")
            if (entry.get("type") == "response_item" and isinstance(payload, dict)
                    and payload.get("type") == "message" and payload.get("role") == "assistant"):
                return message_text(payload.get("content"), ("output_text", "text"))

        return last_assistant_text(transcript_tail(files[-1]), extract)


PI_EXTENSION = r'''import { spawn } from "node:child_process";
export default function (pi) {
  const report = (event, ctx, extra = {}) => new Promise(resolve => {
    const child = spawn(process.env.ROOST_PYTHON, [process.env.ROOST_HELPER, "hook-env"],
      { stdio: ["pipe", "ignore", "ignore"] });
    const timer = setTimeout(() => { child.kill(); resolve(); }, 3000);
    const done = () => { clearTimeout(timer); resolve(); };
    child.on("error", done);
    child.on("close", done);
    child.stdin.on("error", () => {});
    child.stdin.end(JSON.stringify({ event, session: ctx.sessionManager.getSessionFile(), ...extra }));
  });
  pi.on("session_start", (_event, ctx) => report("session_start", ctx));
  pi.on("agent_start", (_event, ctx) => report("agent_start", ctx));
  pi.on("agent_end", (_event, ctx) => report("agent_end", ctx, { pending: ctx.hasPendingMessages() }));
  // Pi emits shutdown when replacing a session too; the runner records actual exit.
}
'''


class PiAgent:
    """Observe Pi extension events without changing tools or approval extensions."""

    default_command = ["pi"]

    def validate(self, command):
        validate_command(command, "Pi")
        reserved = {"--session", "--session-id", "--session-dir", "--no-session", "--continue", "-c",
                    "--resume", "-r", "--fork", "--mode", "--print", "-p", "--export"}
        if any(arg.split("=", 1)[0] in reserved for arg in command[1:]):
            raise RoostError("Roost owns Pi's session and interactive mode; remove conflicting CLI flags")

    def launch(self, store, task, resume_conversation):
        extension = store.root / ("pi-observer-" + hashlib.sha256(PI_EXTENSION.encode()).hexdigest()[:16] + ".mjs")
        atomic_text(extension, PI_EXTENSION)
        sessions = store.root / "sessions" / task["id"]
        sessions.mkdir(mode=0o700, parents=True, exist_ok=True)
        argv = task["command"] + ["--extension", str(extension), "--session-dir", str(sessions)]
        if resume_conversation and task.get("agentSession"):
            argv += ["--session", task["agentSession"]]
        elif text(task.get("prompt")):
            # Pi has no -- separator. A leading newline keeps -flags and
            # @file-looking prompts literal instead of interpreting them as CLI input.
            argv.append("\n" + task["prompt"])
        return argv

    def observe(self, payload, current=None):
        event = payload.get("event")
        status = {"session_start": "ready", "agent_start": "running", "agent_end": "ready"}.get(event)
        if not status:
            return None
        if event == "agent_end" and payload.get("pending"):
            status = "background"
        updates = dict(status=status, updatedAt=now(), lastEvent="Stop" if event == "agent_end" else event)
        if payload.get("session"):
            updates["agentSession"] = payload["session"]
        return updates

    def last_message(self, task):
        session = task.get("agentSession")
        if not session:
            return None

        def extract(entry):
            message = entry.get("message") if isinstance(entry.get("message"), dict) else entry
            if message.get("role") == "assistant":
                return message_text(message.get("content"))

        return last_assistant_text(transcript_tail(session), extract)


def validate_command(command, label):
    if not isinstance(command, list) or not command or not all(isinstance(x, str) and x for x in command):
        raise RoostError(label + " command must be a nonempty argument list")


AGENTS = {"claude": ClaudeAgent(), "codex": CodexAgent(), "pi": PiAgent()}


def agent_for(task):
    name = task.get("agent") or "claude"  # Existing 0.3 records remain usable.
    if not isinstance(name, str) or name not in AGENTS:
        raise RoostError("Unsupported agent: " + str(name))
    return AGENTS[name]


def spawn(store, task, resume=False):
    socket = task["socket"]
    session = task["session"]
    if tmux(socket, "has-session", "-t", "=" + session, check=False).returncode:
        tmux(socket, "new-session", "-d", "-s", session, "-n", "shell", "-c", task["repo"])
    # Before the agent starts, which is when it asks.
    enable_extended_keys(socket)
    script = str(Path(__file__).resolve())
    task["runId"] = uuid.uuid4().hex
    task.pop("shellPaneId", None)
    argv = [sys.executable, script, "run", str(store.root), task["id"], task["runId"]]
    if resume:
        argv.append("resume")
    # The runner waits on the registry lock until its stable pane ID is saved.
    result = tmux(socket, "new-window", "-d", "-P", "-F",
                  "#{window_id}\t#{pane_id}\t#{window_index}", "-t", session + ":",
                  "-n", task["name"].replace("#", "##"), "-c", task["worktree"],
                  shlex.join(argv))
    window, pane, index = result.stdout.strip().split("\t")
    task.update(windowId=window, paneId=pane, windowIndex=int(index), status="starting",
                updatedAt=now(), error=None)
    tmux(socket, "set-option", "-p", "-t", pane, "@roost_task_id", task["id"])
    tmux(socket, "set-option", "-w", "-t", window, "remain-on-exit", "on")
    tmux(socket, "set-option", "-w", "-t", window, "automatic-rename", "off")
    # The agent's hooks call this helper for as long as it runs.
    task["helper"] = script
    store.save(task)
    with contextlib.suppress(OSError, TypeError, ValueError):
        prune_helpers(store)


HELPER_KEEP_SECONDS = 7 * 24 * 3600


def prune_helpers(store):
    """Delete copies of older helpers that nothing will call again: not this
    one, not one a task's agent was launched with, since its hooks call it,
    and none installed in the last week, which another Emacs may still use."""
    records = list(store.tasks_dir.glob("*.json"))
    tasks = store.all()
    if len(tasks) != len(records) or any(not task.get("helper") for task in tasks):
        return  # A task whose helper is unknown might still call any of them.
    keep = {Path(__file__).resolve().name} | {Path(task["helper"]).name for task in tasks}
    cutoff = datetime.datetime.now().timestamp() - HELPER_KEEP_SECONDS
    for path in store.root.glob("remote-*.py"):
        with contextlib.suppress(OSError):
            if path.name not in keep and path.stat().st_mtime < cutoff:
                path.unlink()


PROMPT_ARGUMENT_LIMIT = 120 * 1024


def name_slug(name):
    """NAME in ASCII for the task's branch and directory: accents dropped,
    and each run of other characters but letters, digits and _ a single -.
    A name in another script, such as 修复解析器, gives "task"."""
    folded = unicodedata.normalize("NFKD", name).encode("ascii", "ignore").decode()
    return re.sub(r"[^a-zA-Z0-9_]+", "-", folded).strip("-")[:50].rstrip("-") or "task"


def create(store, request):
    """Create a worktree and agent window. Preparation and `git worktree add`
    run without the registry lock; only the tmux spawn is serialized."""
    directory = str(Path(request["directory"]).expanduser().resolve())
    checkout = git(directory, "rev-parse", "--show-toplevel").stdout.strip()
    # Git lists the main worktree first. Creating from an existing task must
    # still use the primary checkout for integration and repository identity.
    primary = git(checkout, "worktree", "list", "--porcelain", "-z").stdout.split("\0\0", 1)[0].split("\0")
    if "bare" in primary or not primary[0].startswith("worktree "):
        raise RoostError("Roost needs a primary working checkout")
    repo = primary[0][len("worktree "):]
    name = request["name"].strip()
    if not any(c.isalnum() for c in name) or any(ord(c) < 32 or ord(c) == 127 for c in name):
        raise RoostError("Give the task a printable name containing letters or numbers")
    slug = name_slug(name)
    agent_name = text(request.get("agent")) or "claude"
    agent = agent_for(dict(agent=agent_name))
    command = request.get("command", agent.default_command)
    agent.validate(command)
    integration = git(repo, "symbolic-ref", "--short", "HEAD", check=False).stdout.strip()
    # Independent tasks start at the primary checkout. HEAD only forks the
    # source worktree when explicitly requested, rather than accidentally.
    explicit_base = text(request.get("base"))
    base = explicit_base or integration or "HEAD"
    resolved = git(directory if explicit_base else repo, "rev-parse", "--verify", "--quiet", base + "^{commit}",
                   check=False)
    if resolved.returncode:
        # Git says only "Needed a single revision".
        if git(repo, "rev-parse", "--verify", "--quiet", "HEAD", check=False).returncode:
            raise RoostError("%s has no commits yet, and a task branches from one; commit something first "
                             "(git commit --allow-empty -m 'Start' will do)" % repo)
        raise RoostError("No branch, tag or commit named %r to start from" % base)
    commit = resolved.stdout.strip()
    task_id = uuid.uuid4().hex[:16]
    prefix = text(request.get("branchPrefix")) or DEFAULT_BRANCH_PREFIX
    branch = prefix + slug + "-" + task_id[:6]
    if git(repo, "check-ref-format", "--branch", branch, check=False).returncode:
        raise RoostError("Invalid branch name %r; check the branch prefix" % branch)
    repo_hash = hashlib.sha256(repo.encode()).hexdigest()[:10]
    worktree = store.root / "worktrees" / repo_hash / (slug + "-" + task_id[:6])
    worktree.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    socket = text(request.get("socket")) or "main"
    prompt = text(request.get("prompt"))
    # The prompt is one argument to the agent, and Linux refuses one of 128 KB.
    if prompt and len(prompt.encode()) > PROMPT_ARGUMENT_LIMIT:
        raise RoostError("The prompt is %d KB, and an agent can start with at most %d KB; start it with less "
                         "and send the rest once it runs" % (-(-len(prompt.encode()) // 1024),
                                                             PROMPT_ARGUMENT_LIMIT // 1024))
    setup = text(request.get("setup"))
    task = dict(id=task_id, name=name, task=prompt or name, repo=repo,
                worktree=str(worktree), branch=branch, baseRef=base, baseCommit=commit,
                integrationBranch=integration, socket=socket,
                session=text(request.get("session")) or session_name(socket, repo, repo_hash),
                agent=agent_name, command=command, setup=setup, prompt=prompt,
                status="starting", startedAt=now(), updatedAt=now(), claudeSession=None)
    issue = request.get("issue")
    if isinstance(issue, dict) and isinstance(issue.get("number"), int) and not isinstance(issue["number"], bool):
        task["issue"] = dict(number=issue["number"], title=text(issue.get("title")),
                             url=text(issue.get("url")))
    if setup:
        task["setupComplete"] = False
    git(repo, "-c", "branch.autoSetupMerge=false", "worktree", "add", "-b", branch,
        str(worktree), commit)
    with store.locked():
        try:
            store.save(task)
            spawn(store, task)
        except Exception:
            if task.get("windowId"):
                tmux(socket, "kill-window", "-t", task["windowId"], check=False)
            # Never force-remove: a runner could already have written real work.
            if not git(worktree, "status", "--porcelain", check=False).stdout:
                git(repo, "worktree", "remove", str(worktree), check=False)
                with contextlib.suppress(RoostError):
                    delete_branch(repo, branch, commit)
            if worktree.exists():
                task.update(status="failed", error="Creation failed; inspect the worktree, then retire or forget the task")
                store.save(task)
            else:
                store.remove(task_id)
            raise
    return task


ISSUE_BODY_LIMIT = 6000


def issues(request):
    """Open GitHub issues for the repository holding DIRECTORY, newest first,
    as gh on this host sees them."""
    directory = str(Path(text(request.get("directory")) or ".").expanduser())
    checkout = git(directory, "rev-parse", "--show-toplevel").stdout.strip()
    listed = json.loads(gh(checkout, "issue", "list", "--state", "open", "--limit", "100",
                           "--json", "number,title,body,labels,url", timeout=30) or "[]")
    result = []
    for issue in listed:
        body = text(issue.get("body")) or ""
        if len(body) > ISSUE_BODY_LIMIT:
            body = body[:ISSUE_BODY_LIMIT].rstrip() + "\n…"
        result.append(dict(number=issue["number"], title=text(issue.get("title")) or "", body=body,
                           url=text(issue.get("url")),
                           labels=[label.get("name") for label in issue.get("labels") or []
                                   if isinstance(label, dict) and label.get("name")]))
    return result


def processes():
    """Each process on this host as PID -> (PARENT, COMMAND LINE), or {}."""
    result = execute(["ps", "-A", "-ww", "-o", "pid=,ppid=,command="], check=False)
    table = {}
    for line in result.stdout.splitlines() if result.returncode == 0 else []:
        fields = line.split(None, 2)
        if len(fields) == 3 and fields[0].isdigit() and fields[1].isdigit():
            table[int(fields[0])] = (int(fields[1]), fields[2])
    return table


APPROVAL_MARKER_LIMIT = 200


def approved_command_running(task, pane, table):
    """Whether the command TASK's agent asked permission to run has started,
    so you approved it. Claude Code reports nothing until the command ends,
    but runs it in a shell of its own as `eval 'COMMAND'`, always quoted.
    Another command starting, as a subagent's might, says nothing about this
    request."""
    command = task.get("requestCommand")
    if not isinstance(command, str) or not pane or not pane.get("pid"):
        return False
    marker = ("eval '" + command.replace("'", "'\"'\"'") + "'")[:APPROVAL_MARKER_LIMIT]
    agents = [pid for pid, (parent, _) in table.items() if parent == pane["pid"]]
    return any(parent in agents and marker in line for parent, line in table.values())


def was_interrupted(task):
    """Whether you stopped the task's agent mid-turn, for agents that report
    no event when that happens. A missing or odd transcript says no."""
    try:
        check = getattr(agent_for(task), "interrupted", None)
        return bool(check and check(task))
    except (RoostError, OSError, ValueError, TypeError, AttributeError, KeyError):
        return False


def list_tasks(store, request):
    tasks = []
    for task in store.all():
        if task["status"] == "retired":
            # Retirement now deletes records; clear out ones left by older helpers.
            store.remove(task["id"])
        else:
            tasks.append(task)
    inventories = {}
    table = None  # The process table, read only when a request may have been approved.
    for task in tasks:
        socket = task["socket"]
        if socket not in inventories:
            inventories[socket] = pane_inventory(socket)
        inventory = inventories[socket]
        if inventory is None:
            # tmux could not answer: keep the last observed status rather than
            # declaring every agent on this socket crashed.
            task["live"] = None
            continue
        pane = owned_pane(task, inventory)
        changed = False
        if pane and (task.get("session"), task.get("windowIndex")) != (pane["session_name"], pane["index"]):
            task.update(session=pane["session_name"], windowIndex=pane["index"])
            changed = True
        task["live"] = bool(pane and not pane["dead"])
        if task["live"] and task["status"] == "crashed":
            # An earlier poll missed a pane that is in fact alive.
            task.update(status=task.pop("statusBeforeCrash", None) or "ready", updatedAt=now())
            changed = True
        elif not task["live"] and task["status"] not in ENDED:
            task.update(status="crashed", statusBeforeCrash=task["status"], updatedAt=now())
            changed = True
        elif task["live"] and task["status"] in ("running", "permission") and was_interrupted(task):
            # Stopped by you, so waiting for you; it reports no event of its own.
            task.update(status="ready", updatedAt=now(), lastEvent="Interrupt")
            task.pop("request", None)
            task.pop("requestCommand", None)
            changed = True
        elif task["live"] and task["status"] == "permission" and task.get("requestCommand"):
            if table is None:
                table = processes()
            if approved_command_running(task, pane, table):
                task.update(status="running", updatedAt=now(), lastEvent="Approved")
                task.pop("request", None)
                task.pop("requestCommand", None)
                changed = True
        if changed:
            store.save(task)
    return tasks


def summarize_checks(rollup):
    """Count a statusCheckRollup's check runs and commit statuses."""
    counts = dict(passing=0, failing=0, pending=0)
    for check in rollup or []:
        if check.get("status") not in (None, "COMPLETED"):
            counts["pending"] += 1
        elif (check.get("conclusion") or check.get("state")) in ("SUCCESS", "NEUTRAL", "SKIPPED"):
            counts["passing"] += 1
        elif (check.get("conclusion") or check.get("state")) in ("PENDING", "EXPECTED", None, ""):
            counts["pending"] += 1
        else:
            counts["failing"] += 1
    return counts


def pr_status(task):
    """A pull request's state, review and checks, or None when gh cannot say."""
    try:
        view = json.loads(gh(task["repo"] if Path(task["repo"]).is_dir() else None,
                             "pr", "view", str(task["pr"]["number"]), "--json",
                             "state,isDraft,reviewDecision,statusCheckRollup,headRefOid,mergedAt",
                             timeout=15))
        return dict(state=view["state"], draft=bool(view.get("isDraft")),
                    review=view.get("reviewDecision") or None,
                    checks=summarize_checks(view.get("statusCheckRollup")),
                    head=view.get("headRefOid"))
    except (RoostError, ValueError, KeyError, TypeError, AttributeError):
        return None


def changed_files(worktree, base, limit=50):
    """The task's changed files since BASE, committed or not. Line counts
    are absent for binary files, and untracked files are marked so."""
    files = []
    fields = read_git(worktree, "diff", "--numstat", "-z", base).stdout.split("\0")
    while fields and fields[0]:
        added, deleted, path = fields.pop(0).split("\t", 2)
        if not path:
            # A rename: its old and new paths follow.
            path = fields[1]
            del fields[:2]
        file = dict(path=path)
        if added != "-":
            file.update(added=int(added), deleted=int(deleted))
        files.append(file)
    untracked = read_git(worktree, "ls-files", "--others", "--exclude-standard", "-z")
    files += [dict(path=path, untracked=True) for path in untracked.stdout.split("\0") if path]
    return files[:limit]


def git_stamp(task):
    """When the task's Git state last moved, from file times alone: commits,
    staging, resets and checkouts in its worktree, and moves of its
    integration branch. Cheap enough for every poll, unlike the statistics,
    so a commit made outside the agent still gets measured. Edits not yet
    staged leave it alone."""
    worktree = Path(task["worktree"])
    try:
        gitdir = worktree / ".git"
        if gitdir.is_file():
            # A linked worktree's .git names its directory in the repository.
            gitdir = worktree / gitdir.read_text().split("gitdir:", 1)[1].strip()
        common = gitdir
        if (gitdir / "commondir").is_file():
            common = gitdir / (gitdir / "commondir").read_text().strip()
    except (OSError, IndexError, UnicodeDecodeError):
        return None
    paths = [gitdir / "index", gitdir / "logs" / "HEAD"]
    if task.get("integrationBranch"):
        paths.append(common / "logs" / "refs" / "heads" / task["integrationBranch"])
    times = []
    for path in paths:
        try:
            times.append(str(path.stat().st_mtime_ns))
        except OSError:
            times.append("-")
    return " ".join(times)


def add_git_stats(tasks, pull_requests=True):
    """Diffstat, dirtiness and divergence from the integration branch, and
    pull request status, and the agent's latest reply. Runs outside the registry lock: in a large
    repository, or over the network, these take seconds. Without
    PULL_REQUESTS, GitHub is not asked."""
    for task in tasks:
        reply = last_message(task)
        if reply:
            task["lastMessage"] = reply
        if pull_requests and isinstance(task.get("pr"), dict) and task["pr"].get("number"):
            status = pr_status(task)
            if status:
                task["prStatus"] = status
        worktree = Path(task["worktree"])
        task["worktreeMissing"] = not worktree.is_dir()
        if task["worktreeMissing"]:
            continue
        base = fork_point(worktree, task)
        stats = read_git(worktree, "diff", "--shortstat", base)
        dirty = read_git(worktree, "status", "--porcelain")
        task["diff"] = stats.stdout.strip()
        task["dirty"] = bool(dirty.stdout)
        task["files"] = changed_files(worktree, base)
        integration = task.get("integrationBranch")
        if integration:
            # Ahead counts the task's own commits, not merges from updates.
            behind = read_git(worktree, "rev-list", "--count", "HEAD..refs/heads/" + integration, "--")
            ahead = read_git(worktree, "rev-list", "--count", "--no-merges",
                             "refs/heads/" + integration + "..HEAD", "--")
            if behind.returncode == 0 and ahead.returncode == 0:
                task["behind"], task["ahead"] = int(behind.stdout), int(ahead.stdout)


def stop(store, task, inventory=None):
    """Kill the task's window if Roost still owns it. Work is kept."""
    inventory = inventory if inventory is not None else inventory_for(task)
    if owned_pane(task, inventory):
        tmux(task["socket"], "kill-window", "-t", task["windowId"])
    # A pane ID owned by something else means ours is gone (for example after a
    # tmux server restart reused the ID): never touch it, and forget the IDs.
    task.update(status="stopped", updatedAt=now(), paneId=None, windowId=None)
    task.pop("shellPaneId", None)
    store.save(task)
    task["live"] = False
    return task


def resume(store, task):
    inventory = inventory_for(task)
    pane = owned_pane(task, inventory)
    if pane and not pane["dead"]:
        raise RoostError("The agent is still running; open the existing task")
    if not Path(task["worktree"]).is_dir():
        raise RoostError("Task worktree is gone; forget the task to remove it from Roost")
    check_worktree(store, task, branch=False)
    if pane:
        tmux(task["socket"], "kill-window", "-t", task["windowId"])
    spawn(store, task, resume=True)
    return task


def inspect(store, task):
    """Validate ownership before Emacs displays the task. A dead pane is still
    shown: it holds the agent's last output, such as a startup error."""
    pane = owned_pane(task, inventory_for(task))
    if not pane:
        raise RoostError("The agent's tmux window is gone; resume the task")
    task.update(windowIndex=pane["index"], session=pane["session_name"])
    store.save(task)
    task["live"] = not pane["dead"]
    reply = last_message(task)
    if reply:
        task["lastMessage"] = reply
    return task


def send(task, text, force=False):
    pane = owned_pane(task, inventory_for(task))
    if not pane or pane["dead"]:
        raise RoostError("The agent is not running; resume the task first")
    # A paste could answer a startup or permission menu. The status can lag
    # (agents report no event after a declined permission), so the client
    # may confirm with the user and force the send.
    if task["status"] in ("starting", "permission") and not force:
        raise RoostError("Open the task to finish startup or answer its permission prompt")
    if not isinstance(text, str) or not text.strip():
        raise RoostError("Empty prompt")
    buffer = "roost-" + uuid.uuid4().hex
    tmux(task["socket"], "load-buffer", "-b", buffer, "-", input=text)
    try:
        tmux(task["socket"], "paste-buffer", "-p", "-d", "-b", buffer, "-t", task["paneId"])
        tmux(task["socket"], "send-keys", "-t", task["paneId"], "Enter")
    finally:
        tmux(task["socket"], "delete-buffer", "-b", buffer, check=False)
    return task


def shell(store, task):
    """Reuse one supporting shell in the task's tmux window and worktree."""
    inventory = inventory_for(task)
    if not owned_pane(task, inventory):
        raise RoostError("Task's tmux window is gone; resume the task before opening its shell")
    pane = inventory.get(task.get("shellPaneId"))
    if pane and (pane["task"] != task["id"] or pane["window"] != task["windowId"]):
        raise RoostError("Task's shell ownership changed; inspect the window in tmux")
    if not pane or pane["dead"]:
        check_worktree(store, task, branch=False)
        if not Path(task["worktree"]).is_dir():
            raise RoostError("Task worktree is gone")
        if pane:
            tmux(task["socket"], "kill-pane", "-t", task["shellPaneId"])
        pane_id = tmux(task["socket"], "split-window", "-h", "-d", "-P", "-F", "#{pane_id}",
                       "-t", task["paneId"], "-c", task["worktree"]).stdout.strip()
        tmux(task["socket"], "set-option", "-p", "-t", pane_id, "@roost_task_id", task["id"])
        task["shellPaneId"] = pane_id
    owner = inventory[task["paneId"]]
    task["session"] = owner["session_name"]
    task["windowIndex"] = owner["index"]
    store.save(task)
    return task


def require_finished(task, pane):
    if task["status"] in ACTIVE:
        raise RoostError("The agent is active; stop it or wait before retiring this task")
    # The cached status can lag (or predate a reconnect); a live pane in an
    # unexpected state is treated as working.
    if pane and not pane["dead"] and task["status"] not in ("ready", "exited", "failed", "stopped"):
        raise RoostError("The agent's pane is still live; stop the task before retiring it")


def require_clean(repo):
    if git(repo, "status", "--porcelain").stdout.strip():
        raise RoostError("Uncommitted or untracked files remain; review and commit in Magit first")


def integration_branch(task):
    branch = task.get("integrationBranch")
    if not branch:
        raise RoostError("The task has no integration branch (it was created from a detached HEAD); merge it manually, then retire")
    if git(task["repo"], "symbolic-ref", "--short", "HEAD", check=False).stdout.strip() != branch:
        raise RoostError("Check out %s in the primary repository %s before merging" % (branch, task["repo"]))
    if git(task["repo"], "rev-parse", "-q", "--verify", "MERGE_HEAD", check=False).returncode == 0:
        raise RoostError("The primary repository already has a merge in progress")
    return branch


def merged_pull_request_head(task):
    """The branch tip GitHub merged for the task's pull request, or None when
    there is no recorded pull request, it is not MERGED, or gh cannot say.
    Slow: call it without the registry lock and pass the answer to `retire`."""
    if not isinstance(task.get("pr"), dict) or not task["pr"].get("number"):
        return None
    try:
        view = json.loads(gh(task["repo"], "pr", "view", str(task["pr"]["number"]),
                             "--json", "state,headRefOid", timeout=15))
        return view["headRefOid"] if view["state"] == "MERGED" else None
    except (RoostError, ValueError, KeyError, TypeError):
        return None


def safe_to_delete(task, commit, merged_head=None):
    """True when deleting the task branch at COMMIT loses no commits.
    MERGED_HEAD is the tip GitHub merged for the task's pull request. A squash
    merge leaves the branch's commits unmerged to Git, so a branch still at
    that tip, with nothing committed after the merge, is also safe."""
    if commit == task.get("baseCommit"):
        # The task never committed. Its starting point (perhaps a forked
        # task's commits, or a detached HEAD) must survive elsewhere.
        refs = git(task["repo"], "for-each-ref", "--contains", commit, "--format=%(refname)",
                   check=False).stdout.split()
        if any(ref != "refs/heads/" + task["branch"] for ref in refs):
            return True
        if git(task["repo"], "merge-base", "--is-ancestor", commit, "HEAD", check=False).returncode == 0:
            return True
    integration = task.get("integrationBranch")
    if ref_exists(task["repo"], integration) and git(
            task["repo"], "merge-base", "--is-ancestor", commit, "refs/heads/" + integration,
            check=False).returncode == 0:
        return True
    return merged_head is not None and merged_head == commit


def retire(store, task, merge=False, merged_head=None):
    """Remove a finished task's worktree, branch, window and record.
    Never discards uncommitted files or unmerged commits."""
    inventory = inventory_for(task)
    pane = owned_pane(task, inventory)
    require_finished(task, pane)
    if task.get("paneId") in inventory and not pane:
        raise RoostError("Task's tmux ownership changed; stop or forget the task instead")
    repo = task["repo"]
    branch = task["branch"]
    worktree = check_worktree(store, task)
    worktree_exists = worktree.exists()
    branch_exists = ref_exists(repo, branch)
    if worktree_exists:
        require_clean(str(worktree))
    if merge:
        if not branch_exists:
            raise RoostError("The task branch no longer exists; there is nothing to merge")
        integration_branch(task)
        # Untracked files there are yours and stay: Git refuses a merge that
        # would overwrite one, and aborting a merge leaves them alone.
        if git(repo, "status", "--porcelain", "--untracked-files=no").stdout.strip():
            raise RoostError("The primary checkout %s has uncommitted changes; commit or stash them before merging"
                             % repo)
        result = git(repo, "merge", "--no-ff", "--no-edit", branch, check=False)
        if result.returncode:
            conflicts = conflicted_files(repo)
            if git(repo, "rev-parse", "-q", "--verify", "MERGE_HEAD", check=False).returncode == 0:
                git(repo, "merge", "--abort")
            if conflicts:
                raise RoostError("%s conflicts with %s in %s. Nothing was changed; update the task from %s, then merge again"
                                 % (task["name"], task["integrationBranch"], ", ".join(conflicts),
                                    task["integrationBranch"]))
            raise RoostError("Merge failed; task retained: " + (result.stderr.strip() or result.stdout.strip()))
    commit = None
    if branch_exists:
        commit = git(repo, "rev-parse", "refs/heads/" + branch + "^{commit}").stdout.strip()
        if not safe_to_delete(task, commit, merged_head):
            raise RoostError("Task branch has unmerged commits; merge it (m) before retiring, "
                             "or forget the task to keep its branch")
        # A durable checkpoint permits retry after a disconnect or partial cleanup.
        task["retiringCommit"] = commit
        store.save(task)
    stop(store, task, inventory)
    if worktree_exists:
        require_clean(str(worktree))
        git(repo, "worktree", "remove", str(worktree))
    if branch_exists:
        delete_branch(repo, branch, commit)
    store.remove(task["id"])
    task.update(status="retired", updatedAt=now())
    if commit and merged_head == commit:
        task["remoteCleanup"] = True
    return task


def delete_remote_branch(repo, branch):
    """Best effort: GitHub may already have deleted the merged branch."""
    with contextlib.suppress(OSError, RoostError):
        if remote_git(repo, "ls-remote", "--exit-code", "--heads", "origin", branch,
                      check=False).returncode == 0:
            remote_git(repo, "push", "origin", "--delete", branch, check=False)


def push_pull_request(store, task):
    """Push new commits to the task's existing pull request branch and say how
    many were new. Runs without the registry lock."""
    worktree = check_worktree(store, task)
    if not worktree.is_dir():
        raise RoostError("Task worktree is gone")
    if git(worktree, "status", "--porcelain", "--untracked-files=no").stdout.strip():
        raise RoostError("Commit the task's changes before pushing")
    branch = task["branch"]
    remote = git(worktree, "rev-parse", "--verify", "--quiet", "refs/remotes/origin/" + branch + "^{commit}",
                 check=False)
    since = remote.stdout.strip() if remote.returncode == 0 else task["baseCommit"]
    pushed = int(git(worktree, "rev-list", "--count", since + "..HEAD").stdout.strip())
    remote_git(worktree, "push", "-u", "origin", branch)
    return pushed


def pull_request(store, task, request):
    """Push the task branch and open a pull request. Runs without the registry
    lock, because pushing and talking to GitHub are slow."""
    integration = task.get("integrationBranch")
    if not integration:
        raise RoostError("The task has no integration branch (it was created from a detached HEAD) to open a pull request against")
    title = text(request.get("title"))
    if not title:
        raise RoostError("Give the pull request a title")
    worktree = check_worktree(store, task)
    if not worktree.is_dir():
        raise RoostError("Task worktree is gone")
    if git(worktree, "status", "--porcelain", "--untracked-files=no").stdout.strip():
        raise RoostError("Commit the task's changes before opening a pull request")
    if git(worktree, "rev-list", "--count", "--no-merges", fork_point(worktree, task) + "..HEAD").stdout.strip() == "0":
        raise RoostError("The task branch has no commits beyond where it started; there is nothing to propose")
    branch = task["branch"]
    remote_git(worktree, "push", "-u", "origin", branch)
    existing = json.loads(gh(worktree, "pr", "list", "--head", branch, "--state", "open",
                             "--json", "number,url"))
    if existing:
        return dict(number=existing[0]["number"], url=existing[0]["url"])
    argv = ["pr", "create", "--base", integration, "--head", branch, "--title", title,
            "--body", request.get("body") if isinstance(request.get("body"), str) else ""]
    if request.get("draft") is True:
        argv.append("--draft")
    url = gh(worktree, *argv).strip().splitlines()[-1]
    match = re.search(r"/pull/(\d+)", url)
    if not match:
        raise RoostError("Unexpected output from gh pr create: " + url)
    return dict(number=int(match.group(1)), url=url)


def conflicted_files(repo):
    return git(repo, "diff", "--name-only", "--diff-filter=U", check=False).stdout.splitlines()


def update(store, task):
    """Merge the integration branch into the task's worktree, so the task can
    be brought up to date and its conflicts resolved there, not in the
    primary checkout. Conflicts leave the merge in progress in the worktree."""
    integration = task.get("integrationBranch")
    if not integration:
        raise RoostError("The task has no integration branch to update from")
    require_finished(task, owned_pane(task, inventory_for(task)))
    worktree = check_worktree(store, task)
    if not worktree.is_dir():
        raise RoostError("Task worktree is gone")
    if git(worktree, "rev-parse", "-q", "--verify", "MERGE_HEAD", check=False).returncode == 0:
        raise RoostError("A merge is already in progress in the task's worktree; resolve or abort it there")
    # Untracked files are fine; Git refuses the merge if it would overwrite one.
    if git(worktree, "status", "--porcelain", "--untracked-files=no").stdout.strip():
        raise RoostError("Commit the task's changes before updating it from " + integration)
    before = git(worktree, "rev-parse", "HEAD").stdout.strip()
    result = git(worktree, "merge", "--no-edit", integration, check=False)
    conflicts = conflicted_files(worktree)
    if result.returncode and not conflicts:
        if git(worktree, "rev-parse", "-q", "--verify", "MERGE_HEAD", check=False).returncode == 0:
            git(worktree, "merge", "--abort")
        raise RoostError("Updating from %s failed: %s" % (integration, result.stderr.strip() or result.stdout.strip()))
    task["update"] = dict(conflicts=conflicts,
                          changed=before != git(worktree, "rev-parse", "HEAD").stdout.strip())
    return task


def forget(store, task):
    """Drop Roost's record without touching Git, closing an ended task's window.
    The escape hatch for tasks Roost can no longer retire."""
    inventory = pane_inventory(task["socket"])
    pane = owned_pane(task, inventory) if inventory else None
    if pane and not pane["dead"]:
        raise RoostError("The agent is running; stop the task before forgetting it")
    if pane:
        tmux(task["socket"], "kill-window", "-t", task["windowId"], check=False)
    left = []
    if Path(task["worktree"]).exists():
        left.append("worktree " + task["worktree"])
    if Path(task["repo"]).is_dir() and ref_exists(task["repo"], task.get("branch")):
        left.append("branch " + task["branch"])
    store.remove(task["id"])
    task.update(status="forgotten", updatedAt=now(), leftBehind=left, live=False)
    return task


def version_of(text):
    match = re.search(r"(\d+)\.(\d+)(?:\.(\d+))?", text or "")
    return tuple(int(part or 0) for part in match.groups()) if match else None


def doctor(store, request):
    """Check what tasks need on this host, with a fix for each problem."""
    checks = []

    def check(name, ok, detail, hint=None, path=None, optional=False):
        checks.append(dict(name=name, ok=ok, detail=detail, hint=hint, path=path, optional=optional))

    check("Python", sys.version_info >= (3, 9), sys.version.split()[0],
          None if sys.version_info >= (3, 9) else "Install Python 3.9 or newer")
    path = agent_path(os.environ.get("PATH", ""))
    env = dict(os.environ, PATH=path)

    def run(argv):
        try:
            result = subprocess.run(argv, text=True, errors="replace", stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                                    env=env, timeout=30)
            return result.returncode, result.stdout.strip()
        except (OSError, subprocess.TimeoutExpired) as exc:
            return None, str(exc)

    for name, argv, minimum, hint in (
            ("Git", ["git", "--version"], (2, 17), "Install Git 2.17 or newer"),
            ("tmux", ["tmux", "-V"], (3, 0), "Install tmux 3.0 or newer")):
        code, out = run(argv)
        version = version_of(out) if code == 0 else None
        check(name, bool(version and version >= minimum), out if code == 0 else "not found",
              None if version and version >= minimum else hint)
    check("State directory", os.access(store.root, os.W_OK), str(store.root),
          None if os.access(store.root, os.W_OK) else "Make the directory writable")
    for agent, command in sorted((request.get("commands") or {}).items()):
        label = agent.capitalize() if agent != "pi" else "Pi"
        if not isinstance(command, list) or not command or not isinstance(command[0], str):
            check(label, False, "no command configured", "Set roost-agent-commands")
            continue
        executable = shutil.which(command[0], path=path)
        if not executable:
            check(label, False, command[0] + " not found",
                  "Install %s on this host, or point roost-agent-commands at it" % label)
            continue
        code, out = run([executable, "--version"])
        version = version_of(out)
        detail = out.splitlines()[0] if out else executable
        if agent == "codex" and not (version and version >= (0, 160, 0)):
            check(label, False, detail, "Upgrade to Codex 0.160.0 or newer for its lifecycle hooks", executable)
            continue
        if agent == "claude":
            code, out = run([executable, "auth", "status"])
            try:
                signed_in = json.loads(out).get("loggedIn")
            except ValueError:
                signed_in = None
            if signed_in is False:
                check(label, False, detail, "Run `claude` once on this host to sign in", executable)
                continue
        elif agent == "codex":
            code, out = run([executable, "login", "status"])
            if code != 0 or "logged in" not in out.lower():
                check(label, False, detail, "Run `codex login` on this host", executable)
                continue
        check(label, True, detail, None, executable)
    executable = shutil.which("gh", path=path)
    if not executable:
        check("GitHub CLI", False, "not found",
              "Optional: install gh (https://cli.github.com) to open pull requests",
              optional=True)
    else:
        code, out = run([executable, "auth", "status"])
        account = re.search(r"account (\S+)", out)
        if code == 0:
            check("GitHub CLI", True, "signed in as " + account.group(1) if account else "signed in",
                  None, executable, optional=True)
        else:
            check("GitHub CLI", False, "not signed in",
                  "Optional: run `gh auth login` on this host to open pull requests", executable,
                  optional=True)
    for repo in dict.fromkeys(p for p in request.get("projects") or [] if isinstance(p, str)):
        push_check(check, repo)
    return checks


def push_check(check, repo):
    """Whether Git on this host can push REPO's branches to origin, as pull
    requests need. A dry run authenticates like a push but sends nothing."""
    name = "Push · " + Path(repo).name
    if git(repo, "rev-parse", "--verify", "--quiet", "HEAD", check=False).returncode:
        return
    url = git(repo, "remote", "get-url", "--push", "origin", check=False)
    if url.returncode:
        check(name, False, "no origin remote", "Optional: add an origin remote to open pull requests",
              repo, optional=True)
        return
    try:
        remote_git(repo, "push", "--dry-run", "--quiet", "origin", "HEAD:refs/heads/roost-doctor-check",
                   timeout=30)
        check(name, True, url.stdout.strip(), None, repo, optional=True)
    except RoostError as exc:
        lines = [line for line in str(exc).splitlines() if line.strip()]
        advice = next((line for line in lines if line.startswith("Roost pushes")), None)
        check(name, False, lines[0] if lines else "push failed",
              advice or "Optional: make sure Git on this host can push to " + url.stdout.strip(),
              repo, optional=True)


REQUEST_LIMIT = 300


def permission_request(payload, worktree=None):
    """What a permission request asks, as a sentence: "Asks to run python3
    -m pytest", "Asks to edit notes.py", "Asks: Which color do you prefer?".
    None when the payload names no tool, as in the notification that
    follows a request."""
    def clip(value):
        return " ".join(value.split())[:REQUEST_LIMIT]

    # Another agent's request names no tool, but says who asks for what, as
    # "reviewer needs permission for Bash".
    if (payload.get("notification_type") in ("worker_permission_prompt", "agent_needs_input")
            and isinstance(payload.get("message"), str) and payload["message"].strip()):
        return clip(payload["message"])
    tool = payload.get("tool_name")
    if not isinstance(tool, str) or not tool:
        return None
    args = payload.get("tool_input") if isinstance(payload.get("tool_input"), dict) else {}

    def arg(*keys):
        for key in keys:
            value = args.get(key)
            if isinstance(value, list) and value and all(isinstance(x, str) for x in value):
                value = shlex.join(value)
            if isinstance(value, str) and value.strip():
                if key in ("file_path", "notebook_path", "path") and worktree:
                    with contextlib.suppress(ValueError):
                        value = str(Path(value).relative_to(worktree))
                return clip(value)
        return None

    if tool == "AskUserQuestion":
        questions = [q.get("question") for q in args.get("questions") or [] if isinstance(q, dict)]
        questions = [q for q in questions if isinstance(q, str) and q.strip()]
        if not questions:
            return "Asks you a question"
        more = len(questions) - 1
        return "Asks: " + clip(questions[0]) + (" (and %d more)" % more if more else "")
    if tool == "ExitPlanMode":
        return "Asks you to approve its plan"
    if tool == "apply_patch":
        return "Asks to edit files"
    detail = None
    if tool in ("Bash", "shell", "exec_command", "local_shell"):
        verb, detail = "run", arg("command", "cmd")
    elif tool in ("Edit", "MultiEdit", "NotebookEdit", "Write", "Read"):
        verb, detail = {"Write": "write", "Read": "read"}.get(tool, "edit"), arg("file_path", "notebook_path")
    elif tool == "WebFetch":
        verb, detail = "fetch", arg("url")
    elif tool == "WebSearch":
        verb, detail = "search the web for", arg("query")
    return "Asks to " + (verb + " " + detail if detail else "use " + tool)


def update_hook(store, task_id, payload, run_id=None):
    with store.locked():
        task = store.read(task_id)
        if run_id is not None and run_id != task.get("runId"):
            return
        if task["status"] in ("stopped", "retired"):
            return
        before = task["status"]
        updates = agent_for(task).observe(payload, before)
        if updates:
            task.update(updates)
            request = (permission_request(payload, task.get("worktree"))
                       if task["status"] == "permission" else None)
            if request:
                task["request"] = request
                # Its command, to see it start once you approve; the start
                # identifies it, and a heredoc can be long.
                arguments = payload.get("tool_input") if isinstance(payload.get("tool_input"), dict) else {}
                command = arguments.get("command") if payload.get("tool_name") == "Bash" else None
                if isinstance(command, str) and command.strip():
                    task["requestCommand"] = command[:APPROVAL_MARKER_LIMIT]
                else:
                    task.pop("requestCommand", None)
            elif task["status"] != "permission" or before != "permission":
                # The notification that follows a request names no tool:
                # keep the request it follows, and only that one.
                task.pop("request", None)
                task.pop("requestCommand", None)
            store.save(task)


def agent_path(inherited):
    """PATH for the agent: the inherited PATH first, then common install
    directories that SSH noninteractive shells often omit. Keeping the
    inherited order means the agent sees the same tools as the task shell."""
    nvm_bins = sorted((Path.home() / ".nvm/versions/node").glob("*/bin"),
                      key=lambda p: tuple(int(n) for n in re.findall(r"\d+", p.parent.name)), reverse=True)
    fallbacks = [str(Path.home() / ".local/bin"), str(Path.home() / "bin"),
                 "/opt/homebrew/bin", "/usr/local/bin", *(str(path) for path in nvm_bins)]
    entries = [entry for entry in inherited.split(os.pathsep) if entry]
    return os.pathsep.join(entries + [entry for entry in fallbacks if entry not in entries])


def runner(root, task_id, run_id, resume_conversation=False):
    store = Store(root)
    with store.locked():
        task = store.read(task_id)
        if task.get("runId") != run_id:
            return 0
    env = os.environ.copy()
    env["ROOST_TASK_ID"] = task_id
    env["ROOST_RUN_ID"] = run_id
    env["ROOST_STATE_DIRECTORY"] = str(store.root)
    env["ROOST_HELPER"] = str(Path(__file__).resolve())
    env["ROOST_PYTHON"] = sys.executable
    env["PATH"] = agent_path(env.get("PATH", ""))
    # C-c and C-\ in the pane are for the agent, as a shell's foreground job
    # gets them; the runner waits on and records it.  A handler, unlike
    # SIG_IGN, is not inherited across exec.
    for number in (signal.SIGINT, signal.SIGQUIT):
        signal.signal(number, lambda *_: None)
    code = 1
    error = None
    try:
        # Observer files must not be rewritten by a superseded runner.
        with store.locked():
            task = store.read(task_id)
            if task.get("runId") != run_id or task["status"] in ("stopped", "retired"):
                return 0
            argv = agent_for(task).launch(store, task, resume_conversation)
        setup = text(task.get("setup"))
        # Resume reruns setup only when the first run never finished it.
        if setup and (not resume_conversation or task.get("setupComplete") is False):
            subprocess.run(["/bin/sh", "-lc", setup], cwd=task["worktree"], env=env, check=True)
            with store.locked():
                current = store.read(task_id)
                if current.get("runId") == run_id:
                    current["setupComplete"] = True
                    store.save(current)
        code = subprocess.call(argv, cwd=task["worktree"], env=env)
    except (OSError, RoostError, subprocess.CalledProcessError) as exc:
        error = str(exc)
        print("Roost: " + error, file=sys.stderr)
    finally:
        with store.locked(), contextlib.suppress(RoostError):
            current = store.read(task_id)
            if current.get("runId") == run_id and current["status"] not in ("stopped", "retired"):
                current.update(status="exited" if code == 0 else "failed", updatedAt=now(),
                               exitCode=code, error=error)
                store.save(current)
    return code


TASK_ACTIONS = {
    "resume": lambda store, task, request: resume(store, task),
    "stop": lambda store, task, request: stop(store, task),
    "send": lambda store, task, request: send(task, request["text"], request.get("force") is True),
    "shell": lambda store, task, request: shell(store, task),
    "inspect": lambda store, task, request: inspect(store, task),
    "retire": lambda store, task, request: retire(store, task, merged_head=request.get("mergedHead")),
    "merge": lambda store, task, request: retire(store, task, merge=True, merged_head=request.get("mergedHead")),
    "forget": lambda store, task, request: forget(store, task),
    "update": lambda store, task, request: update(store, task),
}


def rpc(request):
    try:
        store = Store(request["root"])
        action = request["action"]
        if action == "create":
            return {"ok": True, "result": create(store, request)}
        if action == "doctor":
            return {"ok": True, "result": doctor(store, request)}
        if action == "issues":
            return {"ok": True, "result": issues(request)}
        if action == "pr":
            with store.locked():
                task = store.read(request["id"])
                if task["status"] == "retired":
                    raise RoostError("Task is retired")
            if isinstance(task.get("pr"), dict) and task["pr"].get("number"):
                pushed = push_pull_request(store, task)
                with store.locked():
                    task = store.read(request["id"])
                return {"ok": True, "result": dict(task, pushed=pushed)}
            pr = pull_request(store, task, request)
            with store.locked():
                task = store.read(request["id"])
                task["pr"] = pr
                store.save(task)
            return {"ok": True, "result": task}
        if action in ("retire", "merge"):
            # Ask GitHub without the lock; retire then trusts only this answer.
            with store.locked():
                task = store.read(request["id"])
            merged = merged_pull_request_head(task) if task.get("pr") else None
            request = dict(request, mergedHead=merged)
        with store.locked():
            if action == "list":
                result = list_tasks(store, request)
            elif action in TASK_ACTIONS:
                task = store.read(request["id"])
                if task["status"] == "retired":
                    raise RoostError("Task is retired")
                result = TASK_ACTIONS[action](store, task, request)
            else:
                raise RoostError("Unknown action: " + str(action))
        if action == "list":
            for task in result:
                task["gitStamp"] = git_stamp(task)
        if action == "list" and request.get("full"):
            # Full is true for every task, or a list of task IDs whose agents
            # have been active; their pull requests are checked with the rest.
            full = request["full"]
            if full is True:
                add_git_stats(result)
            else:
                add_git_stats([t for t in result if t["id"] in full], pull_requests=False)
        elif action in ("retire", "merge") and result.pop("remoteCleanup", None):
            delete_remote_branch(result["repo"], result["branch"])
        return {"ok": True, "result": result}
    except (RoostError, OSError, ValueError) as exc:
        return {"ok": False, "error": str(exc)}
    except Exception as exc:  # The protocol boundary reports, rather than prints, bugs.
        return {"ok": False, "error": "%s: %s" % (type(exc).__name__, exc)}


def main():
    mode = sys.argv[1]
    if mode == "rpc":
        print(json.dumps(rpc(json.load(sys.stdin)), ensure_ascii=False))
    elif mode in ("hook", "hook-env"):
        # Observational hooks never emit decision-control JSON or fail
        # the coding session just because its status dashboard is unavailable.
        try:
            if mode == "hook-env":
                update_hook(Store(os.environ["ROOST_STATE_DIRECTORY"]), os.environ["ROOST_TASK_ID"],
                            json.load(sys.stdin), os.environ["ROOST_RUN_ID"])
            else:
                update_hook(Store(sys.argv[2]), sys.argv[3], json.load(sys.stdin), sys.argv[4])
        except (OSError, ValueError, KeyError, RoostError):
            pass
    elif mode == "run":
        return runner(sys.argv[2], sys.argv[3], sys.argv[4], len(sys.argv) > 5)
    else:
        raise RoostError("Unknown mode")
    return 0


if __name__ == "__main__":
    sys.exit(main())
