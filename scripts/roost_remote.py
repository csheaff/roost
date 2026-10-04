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
import subprocess
import sys
import tempfile
import uuid


class RoostError(Exception):
    pass


def now():
    return datetime.datetime.now(datetime.timezone.utc).isoformat()


def execute(argv, cwd=None, check=True, input=None):
    result = subprocess.run(argv, cwd=cwd, input=input, text=True,
                            stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    if check and result.returncode:
        raise RoostError(result.stderr.strip() or result.stdout.strip()
                         or "Command failed: " + shlex.join(argv))
    return result


def git(repo, *args, check=True):
    return execute(["git", "-C", str(repo), *args], check=check)


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
        with (self.root / "registry.lock").open("a") as lock:
            os.chmod(lock.name, 0o600)
            fcntl.flock(lock, fcntl.LOCK_EX)
            yield

    def path(self, task_id):
        if not re.fullmatch(r"[a-f0-9]{16}", task_id):
            raise RoostError("Invalid task ID")
        return self.tasks_dir / (task_id + ".json")

    def read(self, task_id):
        try:
            return json.loads(self.path(task_id).read_text())
        except FileNotFoundError:
            raise RoostError("Task no longer exists: " + task_id)

    def save(self, task):
        atomic_json(self.path(task["id"]), task)

    def all(self):
        return [json.loads(path.read_text()) for path in sorted(self.tasks_dir.glob("*.json"))]


def pane_inventory(socket):
    result = tmux(socket, "list-panes", "-a", "-F",
                  "#{pane_id}\t#{window_id}\t#{window_index}\t#{session_id}\t#{pane_dead}\t#{@roost_task_id}\t#{session_name}",
                  check=False)
    panes = {}
    if result.returncode:
        return panes
    for line in result.stdout.splitlines():
        fields = line.split("\t")
        if len(fields) == 7:
            pane, window, index, session, dead, task_id, session_name = fields
            panes[pane] = dict(window=window, index=int(index), session=session,
                               dead=dead == "1", task=task_id, session_name=session_name)
    return panes


def owned_pane(task, inventory=None):
    inventory = inventory if inventory is not None else pane_inventory(task["socket"])
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


class ClaudeAgent:
    """Agent-specific CLI and events; Git/tmux lifecycle stays outside this adapter."""

    default_command = ["claude"]

    def validate(self, command):
        if not isinstance(command, list) or not command or not all(isinstance(x, str) and x for x in command):
            raise RoostError("Claude command must be a nonempty argument list")
        reserved = {"--worktree", "-w", "--tmux", "--background", "--bg", "--resume", "-r",
                    "--continue", "-c", "--settings", "--bare", "--safe-mode", "--session-id"}
        if any(arg.split("=", 1)[0] in reserved for arg in command[1:]):
            raise RoostError("Roost owns worktrees, conversation resume, and hook settings; remove conflicting Claude flags")

    def launch(self, store, task, resume_conversation):
        argv = task["command"] + ["--settings", claude_hook_settings(store, task)]
        session = task.get("agentSession") or task.get("claudeSession")
        if resume_conversation and session:
            argv += ["--resume", session]
        elif task.get("prompt"):
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


class CodexAgent:
    """Native Codex TUI with per-invocation, normally reviewed lifecycle hooks."""

    default_command = ["codex"]

    def validate(self, command):
        validate_command(command, "Codex")
        reserved = {"resume", "fork", "exec", "review", "app-server", "--remote", "--cd", "-C"}
        if any(arg.split("=", 1)[0] in reserved for arg in command[1:]):
            raise RoostError("Roost owns Codex's working directory and conversation resume; use interactive CLI options only")

    def launch(self, store, task, resume_conversation):
        # Environment carries task/run identity, so the reviewed hook command
        # stays the same across tasks using this helper version.
        command = shlex.join([sys.executable, str(Path(__file__).resolve()), "hook-env"])
        argv = list(task["command"])
        for event in ("SessionStart", "SessionEnd", "UserPromptSubmit", "PreToolUse",
                      "PostToolUse", "PermissionRequest", "Stop", "Interrupt"):
            handler = '{ hooks = [{ type = "command", command = ' + json.dumps(command) + ', timeout = 3 }] }'
            argv += ["-c", "hooks." + event + "=[" + handler + "]"]
        session = task.get("agentSession")
        if resume_conversation and session:
            argv += ["resume", session]
        elif task.get("prompt"):
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
        elif task.get("prompt"):
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


def validate_command(command, label):
    if not isinstance(command, list) or not command or not all(isinstance(x, str) and x for x in command):
        raise RoostError(label + " command must be a nonempty argument list")


AGENTS = {"claude": ClaudeAgent(), "codex": CodexAgent(), "pi": PiAgent()}


def agent_for(task):
    name = task.get("agent", "claude")  # Existing 0.3 records remain usable.
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
    agent = agent_for(request)
    command = request.get("command", agent.default_command)
    agent.validate(command)
    integration = git(repo, "symbolic-ref", "--short", "HEAD", check=False).stdout.strip()
    # Independent tasks start at the primary checkout. HEAD only forks the
    # source worktree when explicitly requested, rather than accidentally.
    explicit_base = request.get("base")
    base = explicit_base or integration or "HEAD"
    commit = git(directory if explicit_base else repo, "rev-parse", "--verify", base + "^{commit}").stdout.strip()
    task_id = uuid.uuid4().hex[:16]
    repo_hash = hashlib.sha256(repo.encode()).hexdigest()[:10]
    branch = "codex/roost/" + slug + "-" + task_id[:6]
    worktree = store.root / "worktrees" / repo_hash / (slug + "-" + task_id[:6])
    worktree.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    socket = request.get("socket") or "main"
    task = dict(id=task_id, name=name, task=request.get("prompt") or name, repo=repo,
                worktree=str(worktree), branch=branch, baseRef=base, baseCommit=commit,
                integrationBranch=integration, socket=socket, session=request.get("session") or "roost-" + repo_hash,
                agent=request.get("agent", "claude"), command=command, setup=request.get("setup"), prompt=request.get("prompt"),
                status="starting", startedAt=now(), updatedAt=now(), claudeSession=None)
    git(repo, "-c", "branch.autoSetupMerge=false", "worktree", "add", "-b", branch,
        str(worktree), commit)
    try:
        store.save(task)
        spawn(store, task)
    except Exception:
        # Never force-remove: a runner could already have written real work.
        if not git(worktree, "status", "--porcelain").stdout:
            git(repo, "worktree", "remove", str(worktree), check=False)
            git(repo, "branch", "-d", branch, check=False)
        task.update(status="failed", error="Creation failed; inspect the task before retrying")
        store.save(task)
        raise
    return task


def list_tasks(store, request):
    tasks = store.all()
    sockets = {task["socket"] for task in tasks if task["status"] != "retired"}
    inventories = {socket: pane_inventory(socket) for socket in sockets}
    for task in tasks:
        if task["status"] == "retired":
            continue
        pane = owned_pane(task, inventories[task["socket"]])
        if pane:
            moved = task.get("session") != pane["session_name"] or task.get("windowIndex") != pane["index"]
            task["windowIndex"] = pane["index"]
            task["session"] = pane["session_name"]
            if moved:
                store.save(task)
        task["live"] = bool(pane and not pane["dead"])
        if not task["live"] and task["status"] not in ("stopped", "exited", "failed", "crashed"):
            task.update(status="crashed", updatedAt=now())
            store.save(task)
        if request.get("full") and Path(task["worktree"]).exists():
            stats = git(task["worktree"], "diff", "--shortstat", task["baseCommit"], check=False)
            dirty = git(task["worktree"], "status", "--porcelain", check=False)
            task["diff"] = stats.stdout.strip()
            task["dirty"] = bool(dirty.stdout)
    return [task for task in tasks if task["status"] != "retired"]


def stop(store, task):
    inventory = pane_inventory(task["socket"])
    pane = owned_pane(task, inventory)
    if task.get("paneId") in inventory and not pane:
        raise RoostError("Task's tmux ownership changed; refusing to stop another window")
    if pane:
        tmux(task["socket"], "kill-window", "-t", task["windowId"])
    task.update(status="stopped", updatedAt=now(), live=False)
    store.save(task)
    return task


def resume(store, task):
    pane = owned_pane(task)
    if pane and not pane["dead"]:
        raise RoostError("The agent is still running; open the existing task")
    if not Path(task["worktree"]).is_dir():
        raise RoostError("Task worktree is gone")
    check_worktree(store, task)
    if pane:
        tmux(task["socket"], "kill-window", "-t", task["windowId"])
    spawn(store, task, resume=True)
    return task


def send(task, text):
    pane = owned_pane(task)
    if not pane or pane["dead"]:
        raise RoostError("The agent is not running; resume the task first")
    if task["status"] in ("starting", "permission"):
        raise RoostError("Open the task to finish startup or answer its permission prompt")
    if not text.strip():
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
    inventory = pane_inventory(task["socket"])
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


def require_finished(task):
    if task["status"] in ("starting", "running", "permission", "background"):
        raise RoostError("The agent is active; stop it or wait before retiring this task")


def require_clean(repo):
    if git(repo, "status", "--porcelain").stdout.strip():
        raise RoostError("Uncommitted or untracked files remain; review and commit in Magit first")


def integration_branch(task):
    branch = task.get("integrationBranch")
    if not branch or git(task["repo"], "symbolic-ref", "--short", "HEAD").stdout.strip() != branch:
        raise RoostError("Check out the task's recorded integration branch in its primary repository")
    if git(task["repo"], "rev-parse", "-q", "--verify", "MERGE_HEAD", check=False).returncode == 0:
        raise RoostError("The primary repository already has a merge in progress")
    return branch


def retire(store, task, merge=False):
    require_finished(task)
    inventory = pane_inventory(task["socket"])
    if task.get("paneId") in inventory and not owned_pane(task, inventory):
        raise RoostError("Task's tmux ownership changed; resolve it before retiring the worktree")
    worktree = check_worktree(store, task)
    base = integration_branch(task)
    require_clean(task["repo"])
    if worktree.exists():
        require_clean(str(worktree))
    branch_exists = git(task["repo"], "show-ref", "--verify", "--quiet",
                        "refs/heads/" + task["branch"], check=False).returncode == 0
    commit = git(task["repo"], "rev-parse", task["branch"] + "^{commit}").stdout.strip() if branch_exists else task.get("retiringCommit")
    if not commit:
        raise RoostError("Task branch disappeared without a retirement checkpoint; review manually")
    if merge and branch_exists:
        result = git(task["repo"], "merge", "--no-ff", "--no-edit", task["branch"], check=False)
        if result.returncode:
            if git(task["repo"], "rev-parse", "-q", "--verify", "MERGE_HEAD", check=False).returncode == 0:
                git(task["repo"], "merge", "--abort")
            raise RoostError("Merge failed; task retained: " + (result.stderr.strip() or result.stdout.strip()))
    if git(task["repo"], "merge-base", "--is-ancestor", commit, base, check=False).returncode:
        raise RoostError("Task branch has unmerged commits; merge it before retiring")
    # A durable checkpoint permits retry after a disconnect or partial cleanup.
    task["retiringCommit"] = commit
    store.save(task)
    stop(store, task)
    if worktree.exists():
        require_clean(str(worktree))
        git(task["repo"], "worktree", "remove", str(worktree))
    if branch_exists:
        git(task["repo"], "branch", "-d", task["branch"])
    task.update(status="retired", updatedAt=now())
    store.save(task)
    return task


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
    # SSH noninteractive shells often omit an otherwise installed Node CLI.
    nvm_bins = sorted((Path.home() / ".nvm/versions/node").glob("*/bin"),
                      key=lambda p: tuple(int(n) for n in re.findall(r"\d+", p.parent.name)), reverse=True)
    env["PATH"] = os.pathsep.join([str(Path.home() / ".local/bin"), str(Path.home() / "bin"),
                                   "/opt/homebrew/bin", "/usr/local/bin", env.get("PATH", ""),
                                   *(str(path) for path in nvm_bins)])
    code = 1
    error = None
    try:
        # Observer files must not be rewritten by a superseded runner.
        with store.locked():
            task = store.read(task_id)
            if task.get("runId") != run_id or task["status"] in ("stopped", "retired"):
                return 0
            argv = agent_for(task).launch(store, task, resume_conversation)
        if task.get("setup") and not resume_conversation:
            subprocess.run(["/bin/sh", "-lc", task["setup"]], cwd=task["worktree"], env=env, check=True)
        code = subprocess.call(argv, cwd=task["worktree"], env=env)
    except (OSError, RoostError, subprocess.CalledProcessError) as exc:
        error = str(exc)
        print("Roost: " + error, file=sys.stderr)
    finally:
        with store.locked():
            current = store.read(task_id)
            if current.get("runId") == run_id and current["status"] not in ("stopped", "retired"):
                current.update(status="exited" if code == 0 else "failed", updatedAt=now(),
                               exitCode=code, error=error)
                store.save(current)
    return code


def rpc(request):
    try:
        store = Store(request["root"])
        with store.locked():
            action = request["action"]
            if action == "list":
                result = list_tasks(store, request)
            elif action == "create":
                result = create(store, request)
            else:
                task = store.read(request["id"])
                if task["status"] == "retired":
                    raise RoostError("Task is retired")
                if action == "resume":
                    result = resume(store, task)
                elif action == "stop":
                    result = stop(store, task)
                elif action == "send":
                    result = send(task, request["text"])
                elif action == "shell":
                    result = shell(store, task)
                elif action == "inspect":
                    pane = owned_pane(task)
                    if not pane or pane["dead"]:
                        raise RoostError("The agent's tmux pane is gone or stopped; resume the task")
                    task["windowIndex"] = pane["index"]
                    task["session"] = pane["session_name"]
                    store.save(task)
                    result = task
                elif action in ("retire", "merge"):
                    result = retire(store, task, merge=action == "merge")
                else:
                    raise RoostError("Unknown action: " + str(action))
        return {"ok": True, "result": result}
    except (RoostError, OSError, ValueError, KeyError) as exc:
        return {"ok": False, "error": str(exc)}


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
