"""Failure injection against the host helper: a request that dies partway.

Over SSH a request can end at any moment, as when a laptop's lid closes, the
connection drops or the host reboots. `Box` is a repository, a state directory
and a tmux socket of their own, the helper run as Roost runs it, a process per
request, and stand-ins for git and tmux first on PATH that kill it at the Nth
command it runs. `sweep` runs a scenario once for each N, and each time does
what a user would next: looks at the list, and asks again.

Modes, what becomes of the command at which the helper dies:

  before  never runs, as when the connection dropped just before
  after   ran to its end, and the helper never heard the answer
  orphan  runs on, unattended, as when something kills the helper alone
  racing  the same, while you ask again: a moment later it's still running
  fail    fails, if it changes anything, and the helper lives on to say so,
          as with a full disk
  inside  dies with the helper at the Nth hook Git runs, as in a reboot: its
          lock files stay, and what it was doing stops half done
  line    no command: the helper dies at the Nth line of itself it reaches,
          between two writes of its own, say

`test_crash.py` runs these; `make crash` runs them all.
"""
import concurrent.futures
import json
import os
from pathlib import Path
import re
import resource
import shutil
import signal
import subprocess
import sys
import tempfile
import time
import uuid

HELPER = Path(__file__).resolve().parents[1] / "scripts/roost_remote.py"
FAKE = Path(__file__).with_name("fake_claude.py")
REAL = dict(git=shutil.which("git"), tmux=shutil.which("tmux"))

# Stands in for git and tmux. Only the helper under test counts: its runner
# and the agent's hooks use the real thing, as does everything until armed.
SHIM = r"""#!/bin/sh
dir=$ROOST_CRASH_DIR
name=${0##*/}
if [ "$name" = git ]; then real=$ROOST_CRASH_GIT; else real=$ROOST_CRASH_TMUX; fi
if ! read -r helper 2>/dev/null < "$dir/helper" || [ ! -f "$dir/armed" ]; then
  exec "$real" "$@"
fi
# The helper, or the child that a request that changes things goes on in.
if [ "$PPID" != "$helper" ] && [ "$(ps -o ppid= -p "$PPID" | tr -d ' ')" != "$helper" ]; then
  exec "$real" "$@"
fi
read -r at mode < "$dir/armed"
printf x >> "$dir/count"
n=$(wc -c < "$dir/count")
n=$((n))
printf '%s\t%s\t%s\n' "$n" "$name" "$*" >> "$dir/log"
if read -r match 2>/dev/null < "$dir/match"; then
  case "$*" in *"$match"*) at=$n; rm -f "$dir/match" ;; esac
fi
if [ "$n" = "$at" ]; then
  case $mode in
    before) kill -9 "$PPID"; exit 137 ;;
    after) "$real" "$@"; code=$?; kill -9 "$PPID"; exit $code ;;
    orphan) kill -9 "$PPID"; "$real" "$@"; code=$?; : > "$dir/orphan-done"; exit $code ;;
    racing) kill -9 "$PPID"; sleep 0.2; "$real" "$@"; code=$?; : > "$dir/orphan-done"; exit $code ;;
    fail)
      # Reading goes on working, on a full disk.
      case " $* " in
        *" merge "*|*" worktree add "*|*" worktree remove "*|*" update-ref "*|*" commit "*|*" commit-tree "*|\
        *" branch "*|*" push "*|*" reset "*|*" checkout-index "*|*" update-index "*|\
        *" new-session "*|*" new-window "*|*" set-option "*|*" kill-window "*|*" kill-pane "*|*" rename-window "*|\
        *" split-window "*|*" load-buffer "*|*" paste-buffer "*|*" send-keys "*)
          echo "fatal: no room left" >&2; exit 128 ;;
      esac ;;
  esac
fi
exec "$real" "$@"
"""

# Every hook Git runs, in the `inside` mode: at the Nth, Git goes too, as in
# a reboot, with whatever it held: its lock files, and a merge half written.
HOOK = r"""#!/bin/sh
dir=$ROOST_CRASH_DIR
read -r at 2>/dev/null < "$dir/inside" || exit 0
read -r helper 2>/dev/null < "$dir/helper" || exit 0
printf x >> "$dir/count"
n=$(wc -c < "$dir/count")
n=$((n))
printf '%s\thook\t%s %s\n' "$n" "${0##*/}" "$*" >> "$dir/log"
if [ "$n" = "$at" ]; then
  # All at once, the helper first: else it may see Git die and go on.
  pids=$$
  pid=$PPID
  while [ "$pid" -gt 1 ]; do
    pids="$pid $pids"
    [ "$pid" = "$helper" ] && break
    pid=$(($(ps -o ppid= -p "$pid")))
  done
  kill -9 $pids
fi
exit 0
"""
HOOKS = ("reference-transaction", "pre-merge-commit", "pre-commit", "prepare-commit-msg", "commit-msg", "post-commit",
         "post-merge", "post-checkout", "post-index-change", "post-rewrite", "pre-push")

# The helper, dying at the Nth distinct line of itself it reaches.
LINES = r"""
import os, runpy, signal, sys, threading
helper, target, log = sys.argv[1], int(sys.argv[2]), sys.argv[3]
sys.argv = [helper] + sys.argv[4:]
seen = set()
def lines(frame, event, arg):
    if event == "line" and frame.f_lineno not in seen:
        seen.add(frame.f_lineno)
        with open(log, "a") as out:
            out.write("%d\t%s\t%d\n" % (len(seen), frame.f_code.co_name, frame.f_lineno))
        if len(seen) == target:
            os.kill(os.getpid(), signal.SIGKILL)
    return lines
def calls(frame, event, arg):
    if frame.f_code.co_filename == helper and frame.f_code.co_name != "<module>":
        return lines
sys.settrace(calls)
threading.settrace(calls)
runpy.run_path(helper, run_name="__main__")
"""

# What a helper may never say: a bug reported at the protocol's boundary.
BUG_WORDS = re.compile(r"\b(KeyError|TypeError|AttributeError|IndexError|NameError|UnboundLocalError|"
                       r"AssertionError|RecursionError|UnicodeEncodeError|UnicodeDecodeError)\b|Traceback|"
                       r"values to unpack|invalid literal|Expecting value|out of range")


# What a refusal after a crash has to do: say what to do next.
SAYS_WHAT_TO_DO = re.compile(r"try again|merge again|commit or stash|git merge --abort|abort it there|in a moment|"
                             r"merge, retire, discard or forget|lock file may be stale|merge it \(m\) first|"
                             r"open the existing task|Please move or remove them")


class Stuck(Exception):
    """A request didn't end, as with a lock nothing will release."""


class Box:
    """A repository with a state directory, and the helper to act on them."""

    def __init__(self):
        # In /tmp, as the path of tmux's socket has to be short.
        self.root = Path(os.path.realpath(tempfile.mkdtemp(prefix="roost crash ", dir="/tmp")))
        self.repo = self.root / "repo"
        self.state = self.root / "state"
        self.home = self.root / "home"
        self.inject = self.root / "inject"
        self.gh_dir = self.root / "gh"
        for folder in (self.repo, self.home, self.inject, self.gh_dir):
            folder.mkdir()
        self.socket = "crash-" + uuid.uuid4().hex[:10]
        shims = self.root / "bin"
        shims.mkdir()
        for name in ("git", "tmux"):
            (shims / name).write_text(SHIM)
            (shims / name).chmod(0o755)
        (self.home / ".gitconfig").write_text(
            "[user]\n\tname = Roost Test\n\temail = roost@example.invalid\n"
            "[commit]\n\tgpgsign = false\n[init]\n\tdefaultBranch = main\n")
        self.env = {key: value for key, value in os.environ.items()
                    if key not in ("TMUX", "GIT_DIR", "GIT_WORK_TREE", "GIT_INDEX_FILE")}
        self.env.update(PATH=os.pathsep.join([str(shims), str(self.gh_dir), os.environ["PATH"]]),
                        HOME=str(self.home), GIT_CONFIG_NOSYSTEM="1", GIT_CONFIG_GLOBAL=str(self.home / ".gitconfig"),
                        TMUX_TMPDIR=str(self.root), ROOST_CRASH_DIR=str(self.inject),
                        ROOST_CRASH_GIT=REAL["git"], ROOST_CRASH_TMUX=REAL["tmux"])
        self.git("init", "-q", "-b", "main")
        (self.repo / "hello").write_text("base\n")
        self.git("add", ".")
        self.git("commit", "-qm", "base")

    def close(self):
        subprocess.run([REAL["tmux"], "-L", self.socket, "kill-server"], env=self.env,
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        # Hooks the agent ran as tmux killed it may still be writing.
        for _ in range(5):
            shutil.rmtree(self.root, ignore_errors=True)
            if not self.root.exists():
                return
            time.sleep(0.2)

    def __enter__(self):
        return self

    def __exit__(self, *_):
        self.close()

    def run(self, *argv, cwd=None, check=True, input=None):
        result = subprocess.run(argv, cwd=cwd or self.repo, env=self.env, encoding="utf-8", errors="replace", input=input,
                                stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        if check and result.returncode:
            raise AssertionError("%s failed: %s" % (" ".join(map(str, argv)), result.stderr))
        return result.stdout.strip()

    def git(self, *args, cwd=None, check=True):
        return self.run(REAL["git"], *args, cwd=cwd, check=check)

    def tmux(self, *args, check=False, u=False):
        return self.run(REAL["tmux"], *(["-u"] if u else []), "-L", self.socket, *args, check=check)

    def arm(self, mode, at=0, match=None):
        """Kill the next request as MODE says, at its command or hook number
        AT, or the first command MATCH is part of."""
        for name in ("count", "log", "orphan-done", "lines"):
            (self.inject / name).unlink(missing_ok=True)
        self.mode, self.at = mode, at
        if match:
            (self.inject / "match").write_text(match + "\n")
        if mode == "inside":
            hooks = self.root / "hooks"
            hooks.mkdir(exist_ok=True)
            for name in HOOKS:
                (hooks / name).write_text(HOOK)
                (hooks / name).chmod(0o755)
            self.git("config", "--global", "core.hooksPath", str(hooks))
            (self.inject / "inside").write_text("%d\n" % at)
        elif mode != "line":
            (self.inject / "armed").write_text("%d %s\n" % (at, mode))

    def disarm(self):
        if self.mode == "inside":
            self.git("config", "--global", "--unset", "core.hooksPath")
        self.mode = None
        for name in ("helper", "armed", "inside", "match"):
            (self.inject / name).unlink(missing_ok=True)

    mode = None

    def helper(self, action, timeout=60, full_disk=False, **args):
        """The helper's reply to a request, or None if it died, as armed.
        With FULL_DISK, no file it writes to can grow."""
        request = dict(root=str(self.state), action=action, **args)
        # As Emacs starts it.
        argv = [sys.executable, "-I", "-c", "import runpy,sys; sys.argv=[%r,'rpc']; runpy.run_path(%r,run_name='__main__')"
                % (str(HELPER), str(HELPER))]
        if self.mode == "line":
            argv = [sys.executable, "-c", LINES, str(HELPER), str(self.at), str(self.inject / "lines"), "rpc"]
        process = subprocess.Popen(argv, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                   encoding="utf-8", errors="replace", env=self.env, cwd="/",
                                   preexec_fn=(lambda: resource.setrlimit(resource.RLIMIT_FSIZE, (0, 0)))
                                   if full_disk else None)
        if self.mode in ("before", "after", "orphan", "racing", "fail", "inside"):
            (self.inject / "helper").write_text("%d\n" % process.pid)
        try:
            out, err = process.communicate(json.dumps(request, ensure_ascii=False), timeout=timeout)
        except subprocess.TimeoutExpired:
            process.kill()
            process.communicate()
            raise Stuck("%s did not end in %d seconds" % (action, timeout))
        if process.returncode == -signal.SIGKILL:
            return None
        if process.returncode or not out.strip():
            return dict(ok=False, error="The helper exited %s, with nothing to say: %s"
                        % (process.returncode, err.strip()[-400:]), traceback=True)
        return json.loads(out)

    def calls(self):
        """How many commands or hooks the armed helper ran, or lines it reached."""
        if self.mode == "line":
            path = self.inject / "lines"
            return sum(1 for _ in path.open()) if path.exists() else 0
        path = self.inject / "count"
        return path.stat().st_size if path.exists() else 0

    def wait_for_orphan(self):
        """Until the command left running, if any, is done."""
        if self.mode == "orphan" and self.calls() >= self.at:
            deadline = time.monotonic() + 15
            while not (self.inject / "orphan-done").exists() and time.monotonic() < deadline:
                time.sleep(0.01)

    def record(self, task_id):
        try:
            return json.loads((self.state / "tasks" / (task_id + ".json")).read_text())
        except (OSError, ValueError):
            return None

    def records(self):
        folder = self.state / "tasks"
        return sorted(path.name for path in folder.iterdir()) if folder.is_dir() else []

    def wait_for(self, task, status, seconds=10):
        deadline = time.monotonic() + seconds
        while time.monotonic() < deadline:
            record = self.record(task["id"])
            if record and record.get("status") == status:
                return record
            time.sleep(0.02)
        raise AssertionError("Expected %s; got %s" % (status, self.record(task["id"])))

    def create(self, name="task", **args):
        reply = self.helper("create", directory=str(self.repo), name=name, socket=self.socket,
                            command=[sys.executable, str(FAKE)], **args)
        if not reply or not reply["ok"]:
            raise AssertionError(reply)
        self.wait_for(reply["result"], "ready")
        return reply["result"]

    def commit(self, task, name="work", text="work\n"):
        worktree = Path(task["worktree"])
        (worktree / name).write_text(text)
        self.git("add", name, cwd=worktree)
        self.git("commit", "-qm", "Add " + name, cwd=worktree)
        return self.git("rev-parse", "HEAD", cwd=worktree)

    def branches(self):
        return self.git("for-each-ref", "--format=%(refname:short)", "refs/heads").split()

    def worktrees(self):
        return [line[len("worktree "):] for line in self.git("worktree", "list", "--porcelain").splitlines()
                if line.startswith("worktree ")]

    def windows(self):
        return self.tmux("list-windows", "-a", "-F", "#{session_name}:#{window_name}").split()

    def reachable(self, commit):
        return bool(self.git("for-each-ref", "--contains", commit, check=False))

    def origin(self):
        """A local bare origin, with a fake gh that remembers what it opened."""
        self.git("init", "-q", "--bare", "-b", "main", str(self.root / "origin.git"))
        self.git("remote", "add", "origin", str(self.root / "origin.git"))
        self.git("config", "remote.origin.url", "https://github.com/octo/repo.git")
        self.git("config", "url.%s.insteadOf" % (self.root / "origin.git"), "https://github.com/octo/repo.git")
        self.git("push", "-q", "origin", "main")
        script = self.gh_dir / "gh"
        script.write_text("#!%s\n" % sys.executable + GH)
        script.chmod(0o755)

    def opened(self):
        path = self.gh_dir / "prs"
        return path.read_text().splitlines() if path.exists() else []


GH = r"""import json, os, sys
folder = os.path.dirname(os.path.abspath(__file__))
args = sys.argv[1:]
path = os.path.join(folder, "prs")
open_prs = open(path).read().splitlines() if os.path.exists(path) else []
if args[:2] == ["pr", "create"]:
    head = args[args.index("--head") + 1]
    with open(path, "a") as out:
        out.write(head + "\n")
    print("https://github.com/octo/repo/pull/%d" % (len(open_prs) + 7))
elif args[:2] == ["pr", "list"]:
    head = args[args.index("--head") + 1] if "--head" in args else None
    merged = os.path.join(folder, "merged")
    tip = open(merged).read().strip() if os.path.exists(merged) else None
    print(json.dumps([dict(number=7 + number, title="t", url="https://github.com/octo/repo/pull/%d" % (7 + number),
                           state="MERGED" if tip else "OPEN", isDraft=False, headRefName=branch,
                           headRefOid=tip or "0" * 40)
                      for number, branch in enumerate(open_prs) if head in (None, branch)]))
else:
    print("[]")
"""


class Scenario:
    """One action, on a task in one state: what to arrange, what to ask,
    and what must hold once a user has recovered."""

    action = None
    args = {}
    # Modes `make crash` leaves out, as nothing real kills that way.
    left_out = ()
    # Whether the action deletes work you agreed to lose.
    loses_work = False
    # Whether the action leaves the task's branch and worktree, and says so.
    leaves = False
    task = None
    commit = None
    # The reply to asking again.
    final = None

    def arrange(self, box):
        self.task = box.create()
        self.commit = box.commit(self.task)
        self.prepare(box)

    def prepare(self, box):
        pass

    def request(self, box):
        return dict(self.args, id=self.task["id"])

    def ask(self, box):
        return box.helper(self.action, **self.request(box))

    def again(self, box):
        """Ask again, as a user would after a dropped connection."""
        return self.ask(box)

    def kept(self, box):
        """Whether the task's committed work is anywhere: a squashed
        task's commit goes with its branch, and its work is on main."""
        return box.reachable(self.commit) or box.git("show", "main:work", check=False) == "work"

    def holds(self, box, problems):
        """Note in PROBLEMS what isn't so, once the user has asked again."""
        if not self.loses_work and self.commit and not self.kept(box):
            problems.append("the task's commit is on no branch, and its work isn't on main")


def said(reply, where, problems):
    """Note a reply no user should see: no reply, or a bug reported as one."""
    if reply is None:
        problems.append("%s: no reply" % where)
    elif reply.get("traceback") or not reply.get("ok") and BUG_WORDS.search(str(reply.get("error"))):
        problems.append("%s: a bug, not a refusal: %s" % (where, reply.get("error")))


def trial(scenario_class, mode, at, then=None):
    """Kill the scenario's action at step AT, and recover as a user would.
    Return what happened: `problems` break a rule, `refusals` are what the
    user was told, and `residue` is what stays, harmlessly. THEN, a mode
    and step, kills the first request asked again likewise."""
    scenario = scenario_class()
    outcome = dict(scenario=scenario_class.__name__, mode=mode, at=at, problems=[], refusals=[], residue=[])
    problems = outcome["problems"]
    with Box() as box:
        scenario.arrange(box)
        box.arm(mode, at)
        try:
            first = scenario.ask(box)
        except Stuck as exc:
            problems.append("first request: %s" % exc)
            first = None
        outcome["crashed"] = first is None or mode == "fail"
        if first is not None:
            said(first, "first", problems)
        box.wait_for_orphan()
        log = box.inject / ("lines" if mode == "line" else "log")
        outcome["step"] = (log.read_text(errors="replace").splitlines() or [""])[-1][:160] if log.exists() else ""
        box.disarm()
        if outcome["crashed"] and then:
            box.arm(*then)
            scenario.again(box)
            box.wait_for_orphan()
            box.disarm()
        if outcome["crashed"]:
            try:
                recover(box, scenario, outcome)
            except Stuck as exc:
                problems.append(str(exc))
    return outcome


def stale_locks(box, reply):
    """Do as Git hints when a reboot left its lock files: remove them. Return
    whether there were any. Only the user knows no Git is running there."""
    if not reply or "lock file may be stale" not in str(reply.get("error")):
        return False
    for folder in (box.repo / ".git", box.root / "origin.git"):
        for lock in folder.rglob("*.lock"):
            lock.unlink()
    return True


def recover(box, scenario, outcome):
    """Look at the list, ask again, and get rid of what's left."""
    problems = outcome["problems"]
    for full in (True, False):
        listed = box.helper("list", full=full, socket=box.socket)
        said(listed, "list", problems)
        if listed and not listed.get("ok"):
            problems.append("list failed: %s" % listed.get("error"))
    final = scenario.again(box)
    for _ in range(4):
        if not stale_locks(box, final):
            break
        final = scenario.again(box)
    scenario.final = final
    said(final, "again", problems)
    if final is not None and not final.get("ok"):
        error = str(final.get("error"))
        outcome["refusals"].append(error)
        gone = scenario.task and box.record(scenario.task["id"]) is None and error.startswith("Task no longer exists")
        if not gone and not SAYS_WHAT_TO_DO.search(error):
            problems.append("refused without saying what to do: %s" % error)
    scenario.holds(box, problems)
    way_out(box, scenario, outcome)


def way_out(box, scenario, outcome):
    """Discard what is left, and check that nothing stays."""
    problems = outcome["problems"]
    listed = box.helper("list", socket=box.socket)
    for task in listed["result"] if listed and listed.get("ok") else []:
        gone = None
        for _ in range(4):
            dry = box.helper("discard", id=task["id"], dryRun=True)
            said(dry, "discard's question", problems)
            gone = dry if not dry or not dry.get("ok") else box.helper(
                "discard", id=task["id"], expect=dry["result"]["discard"]["commit"], told=dry["result"]["discard"])
            if not stale_locks(box, gone):
                break
        said(gone, "discard", problems)
        if not gone or not gone.get("ok"):
            problems.append("no discarding the task: %s" % (gone and gone.get("error")))
            gone = box.helper("forget", id=task["id"])
            said(gone, "forget", problems)
    left = box.helper("list", socket=box.socket)
    if not left or not left.get("ok") or left["result"]:
        problems.append("still listed once discarded: %s" % (left,))
    if not scenario.leaves:
        # What can't be removed of its agent's own stays where Git put it.
        worktrees = [path for path in box.worktrees() if path != str(box.repo) and "/.claude/worktrees/" not in path]
        if worktrees:
            problems.append("a worktree no task knows of: %s" % worktrees)
        branches = [branch for branch in box.branches() if branch.startswith("roost/")]
        # What Git's death left locked Roost can't delete, or should: known,
        # and an empty branch is all it costs.
        locked = [branch for branch in branches if (box.repo / ".git/refs/heads" / (branch + ".lock")).exists()
                  or (box.repo / ".git/packed-refs.lock").exists()]
        outcome["residue"] += ["a branch Git left locked: " + branch for branch in locked]
        branches = [branch for branch in branches if branch not in locked]
        if branches:
            problems.append("a branch no task knows of: %s" % branches)
        folders = [path.name for path in (box.state / "worktrees").glob("*/*") if path.is_dir()]
        if folders:
            problems.append("a folder under worktrees no task knows of: %s" % folders)
    windows = box.windows()
    if windows:
        outcome["residue"].append("tmux windows: %s" % windows)
    records = box.records()
    if records:
        outcome["residue"].append("tasks folder: %s" % records)


def steps(scenario_class, modes):
    """How many steps of each of MODES SCENARIO_CLASS's action goes through,
    with nothing killed."""
    counts = {}
    for kind in {"inside" if mode == "inside" else "line" if mode == "line" else "before" for mode in modes}:
        scenario = scenario_class()
        with Box() as box:
            scenario.arrange(box)
            box.arm(kind, 10 ** 9)
            scenario.ask(box)
            counts[kind] = box.calls()
            box.disarm()
    return counts


def run(jobs, workers, report=None):
    """The outcomes of JOBS, the arguments of each trial."""
    outcomes = []
    with concurrent.futures.ThreadPoolExecutor(workers) as pool:
        for outcome in pool.map(lambda job: trial(*job), jobs):
            outcomes.append(outcome)
            if report:
                report(outcome)
    return outcomes


def sweep(scenario_class, modes=("before", "after", "orphan", "racing", "fail", "inside"), workers=6, report=None):
    """Run a trial at every step of the scenario in each of MODES. Return the outcomes."""
    counts = steps(scenario_class, modes)
    return run([(scenario_class, mode, at) for mode in modes
                for at in range(1, counts["inside" if mode == "inside" else "line" if mode == "line" else "before"] + 1)],
               workers, report)


def twice(scenario_class, workers=6):
    """Kill the scenario's action, then the request that asks again: in the
    last third of its steps, where it has changed things, then at every
    third step of what is left to do. The pairs are many."""
    last = steps(scenario_class, ("after",))["before"]
    return run([(scenario_class, "after", first, ("after", second))
                for first in range(last * 2 // 3, last + 1) for second in range(1, last + 1, 3)], workers)
