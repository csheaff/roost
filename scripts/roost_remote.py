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
import socket
import subprocess
import sys
import tempfile
import uuid


class RoostError(Exception):
    pass


# Agent states that mean work may be in progress.
ACTIVE = ("starting", "running", "permission", "background")
# States in which the agent process is known to have ended.
ENDED = ("stopped", "exited", "failed", "crashed")
# Computed per request and never persisted in a task record.
TRANSIENT = ("live", "diff", "dirty", "ahead", "behind", "update", "worktreeMissing",
             "prStatus", "lastMessage")
LAST_MESSAGE_TAIL = 256 * 1024
LAST_MESSAGE_LIMIT = 2000
DEFAULT_BRANCH_PREFIX = "roost/"


def now():
    return datetime.datetime.now(datetime.timezone.utc).isoformat()


def text(value):
    """An optional nonempty string from a request, else None.
    Older Emacs clients encoded nil as an empty JSON object."""
    return value if isinstance(value, str) and value else None


def execute(argv, cwd=None, check=True, input=None):
    result = subprocess.run(argv, cwd=cwd, input=input, text=True,
                            stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    if check and result.returncode:
        raise RoostError(result.stderr.strip() or result.stdout.strip()
                         or "Command failed: " + shlex.join(argv))
    return result


def git(repo, *args, check=True):
    return execute(["git", "-C", str(repo), *args], check=check)


REMOTE_GIT_TIMEOUT = 120
CREDENTIAL_FAILURES = ("Permission denied (publickey)", "could not read Username",
                       "Authentication failed", "terminal prompts disabled")


def remote_git(repo, *args, check=True):
    """Run Git where it talks to the remote, so it can never prompt on the
    helper's RPC pipe or hang forever. Explains credential failures."""
    try:
        result = subprocess.run(["git", "-C", str(repo), *args], text=True,
                                stdin=subprocess.DEVNULL, timeout=REMOTE_GIT_TIMEOUT,
                                stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                env=dict(os.environ, GIT_TERMINAL_PROMPT="0", GIT_ASKPASS="",
                                         SSH_ASKPASS_REQUIRE="never", GCM_INTERACTIVE="never"))
    except subprocess.TimeoutExpired:
        raise RoostError("git %s timed out after %d seconds" % (args[0], REMOTE_GIT_TIMEOUT))
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
        result = subprocess.run([executable, *args], cwd=cwd, text=True, timeout=timeout,
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
NO_SERVER = ("no server running", "No such file or directory", "Connection refused")


def pane_inventory(socket):
    """Map pane IDs to their tmux details.
    Return {} when no server runs, or None when tmux could not answer (for
    example a client/server version mismatch after upgrading tmux)."""
    result = tmux(socket, "list-panes", "-a", "-F",
                  "#{pane_id}\t#{window_id}\t#{window_index}\t#{session_id}\t#{pane_dead}\t#{@roost_task_id}\t#{session_name}",
                  check=False)
    if result.returncode:
        return {} if any(marker in result.stderr for marker in NO_SERVER) else None
    panes = {}
    for line in result.stdout.splitlines():
        fields = line.split("\t")
        if len(fields) == 7:
            pane, window, index, session, dead, task_id, session_name = fields
            panes[pane] = dict(window=window, index=int(index), session=session,
                               dead=dead == "1", task=task_id, session_name=session_name)
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


def check_worktree(store, task):
    worktree = Path(task["worktree"]).resolve()
    if not worktree.is_relative_to((store.root / "worktrees").resolve()):
        raise RoostError("Task worktree is outside Roost's worktree directory")
    if worktree == Path(task["repo"]).resolve():
        raise RoostError("Refusing to remove the primary repository")
    if worktree.exists():
        branch = git(worktree, "symbolic-ref", "--short", "HEAD").stdout.strip()
        if branch != task["branch"]:
            raise RoostError("The worktree has changed branches; review it manually")
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


def transcript_tail(path):
    """Complete JSON lines from the end of a transcript, newest last."""
    with open(path, "rb") as handle:
        size = handle.seek(0, os.SEEK_END)
        handle.seek(max(0, size - LAST_MESSAGE_TAIL))
        data = handle.read()
    lines = data.splitlines()
    if size > LAST_MESSAGE_TAIL and lines:
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
            argv.append(task["prompt"])
        return argv

    def observe(self, payload):
        event = payload.get("hook_event_name")
        status = {
            "SessionStart": "ready", "UserPromptSubmit": "running",
            "PreToolUse": "running", "PostToolUse": "running",
            "PermissionRequest": "permission", "SessionEnd": "exited", "StopFailure": "failed",
        }.get(event)
        if event == "Stop":
            status = "background" if payload.get("background_tasks") or payload.get("session_crons") else "ready"
        if event == "Notification":
            status = {"permission_prompt": "permission", "idle_prompt": "ready"}.get(payload.get("notification_type"))
        if not status:
            return None
        updates = dict(status=status, updatedAt=now(), lastEvent=event)
        if payload.get("session_id"):
            # Keep the old field for tasks whose original helper is still running.
            updates.update(agentSession=payload["session_id"], claudeSession=payload["session_id"])
        return updates

    def last_message(self, task):
        session = task.get("agentSession") or task.get("claudeSession")
        if not session or not isinstance(task.get("worktree"), str):
            return None
        folder = re.sub(r"[/.]", "-", task["worktree"])
        path = Path.home() / ".claude" / "projects" / folder / (session + ".jsonl")
        message = lambda entry: (entry.get("message") if isinstance(entry.get("message"), dict)
                                 and entry["message"].get("role") == "assistant" else None)
        return last_assistant_text(
            transcript_tail(path),
            lambda entry: message_text((message(entry) or {}).get("content")))


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

    def observe(self, payload):
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

    def observe(self, payload):
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
    store.save(task)


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
    slug = re.sub(r"[^a-zA-Z0-9_-]+", "-", name).strip("-")[:50]
    if not slug or any(ord(c) < 32 or ord(c) == 127 for c in name):
        raise RoostError("Give the task a printable name containing letters or numbers")
    agent_name = text(request.get("agent")) or "claude"
    agent = agent_for(dict(agent=agent_name))
    command = request.get("command", agent.default_command)
    agent.validate(command)
    integration = git(repo, "symbolic-ref", "--short", "HEAD", check=False).stdout.strip()
    # Independent tasks start at the primary checkout. HEAD only forks the
    # source worktree when explicitly requested, rather than accidentally.
    explicit_base = text(request.get("base"))
    base = explicit_base or integration or "HEAD"
    commit = git(directory if explicit_base else repo, "rev-parse", "--verify", base + "^{commit}").stdout.strip()
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
    setup = text(request.get("setup"))
    task = dict(id=task_id, name=name, task=prompt or name, repo=repo,
                worktree=str(worktree), branch=branch, baseRef=base, baseCommit=commit,
                integrationBranch=integration, socket=socket,
                session=text(request.get("session")) or "roost-" + repo_hash,
                agent=agent_name, command=command, setup=setup, prompt=prompt,
                status="starting", startedAt=now(), updatedAt=now(), claudeSession=None)
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


def list_tasks(store, request):
    tasks = []
    for task in store.all():
        if task["status"] == "retired":
            # Retirement now deletes records; clear out ones left by older helpers.
            store.remove(task["id"])
        else:
            tasks.append(task)
    inventories = {}
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


def add_git_stats(tasks):
    """Diffstat, dirtiness and divergence from the integration branch, and
    pull request status, and the agent's latest reply. Runs outside the registry lock: in a large
    repository, or over the network, these take seconds."""
    for task in tasks:
        reply = last_message(task)
        if reply:
            task["lastMessage"] = reply
        if isinstance(task.get("pr"), dict) and task["pr"].get("number"):
            status = pr_status(task)
            if status:
                task["prStatus"] = status
        worktree = Path(task["worktree"])
        task["worktreeMissing"] = not worktree.is_dir()
        if task["worktreeMissing"]:
            continue
        stats = git(worktree, "diff", "--shortstat", fork_point(worktree, task), check=False)
        dirty = git(worktree, "status", "--porcelain", check=False)
        task["diff"] = stats.stdout.strip()
        task["dirty"] = bool(dirty.stdout)
        integration = task.get("integrationBranch")
        if integration:
            # Ahead counts the task's own commits, not merges from updates.
            behind = git(worktree, "rev-list", "--count", "HEAD..refs/heads/" + integration, "--",
                         check=False)
            ahead = git(worktree, "rev-list", "--count", "--no-merges",
                        "refs/heads/" + integration + "..HEAD", "--", check=False)
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
    check_worktree(store, task)
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
        check_worktree(store, task)
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
        require_clean(repo)
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
            result = subprocess.run(argv, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
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
    return checks


def update_hook(store, task_id, payload, run_id=None):
    with store.locked():
        task = store.read(task_id)
        if run_id is not None and run_id != task.get("runId"):
            return
        if task["status"] in ("stopped", "retired"):
            return
        updates = agent_for(task).observe(payload)
        if updates:
            task.update(updates)
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
        if action == "list" and request.get("full"):
            add_git_stats(result)
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
