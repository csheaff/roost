"""Real agent sessions, recorded, for the helper to read again.

A capture is what an agent reported during a live run of
test/agent_contract.py, as the helper received it: its hook payloads, or
its extension's reports, and the status reports the runner relayed, in
order. Each is kept in test/captures as JSON lines:

  {"agent": "claude", "version": "2.1.303", "recorded": "2026-10-20", ...}
  {"step": "approve a command"}
  {"at": 4.21, "hook": {...}, "then": {"status": "permission", ...}}
  {"at": 4.80, "report": {...}, "then": {...}}

The first line says which agent and version sent it. A step names what the
run did next. Each event's `then` is what the helper made of the task once
it read that event, so test_captures.py fails when the helper reads a real
session differently, and recording again after an agent updates shows, in
the diff, what it now sends and what Roost now makes of it.
It is the task's record alone: a listing adds what the agent's transcript
says, such as a turn stopped with Esc that Claude Code runs no hook for.

Paths, session and message ids are replaced with stand-ins, so a capture
names nothing of the machine it was recorded on. What a tool returned is
left out, as the helper never reads it, and so is all that another session
of the agent says, such as Codex's memory agent working in
~/.codex/memories: only its events stay, to show what Roost makes of them.
"""
import datetime
import importlib.util
import json
from pathlib import Path
import re
import tempfile
from unittest import mock

SOURCE = Path(__file__).resolve().parents[1] / "scripts/roost_remote.py"
spec = importlib.util.spec_from_file_location("roost_remote", SOURCE)
roost = importlib.util.module_from_spec(spec)
spec.loader.exec_module(roost)

CAPTURES = Path(__file__).resolve().parent / "captures"
# What a capture's task stands in for.
REPO = "/work/repo"
WORKTREE = "/work/task"
STATE = "/state"
HOME = "/home/user"
TASK_ID = "0123456789abcdef"
RUN_ID = "run"
# When a replay starts: times in a capture count from its first event, and
# the helper takes a time of 0 for one it never noted.
EPOCH = 1e9
# What stands in for what a capture leaves out: see `withhold`.
WITHHELD = "(left out of the capture)"
# What each event's `then` records of the task.
FIELDS = ("status", "lastEvent", "request", "error", "lastReply", "agentSession")
# Ids an agent makes up, as a pattern and the stand-in's form.
IDS = ((re.compile(r"(?<![0-9a-f])[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}(?![0-9a-f])"),
        "00000000-0000-4000-8000-%012d"),
       (re.compile(r"\b(toolu|call|msg|req|ses|prt|per|que|fc|rs)_[0-9A-Za-z]{8,}\b"), "%s_%d"))


def scrub(entries, task, store_root):
    """ENTRIES, as a capture keeps them: TASK's paths and the machine's
    home as stand-ins, ids numbered in order of appearance, and times in
    seconds from the first event."""
    home = str(Path.home())
    paths = []
    for real, stand_in in ((task["worktree"], WORKTREE), (task["repo"], REPO),
                           (str(store_root), STATE), (home, HOME), (task["id"], TASK_ID)):
        for variant in {real, str(Path(real).resolve())}:
            paths.append((variant, stand_in))
            # As Claude names a conversation's folder after its directory.
            paths.append((roost.claude_project_folder(variant), roost.claude_project_folder(stand_in)))
    paths.sort(key=lambda pair: -len(pair[0]))
    seen = {}

    def stand_in(match, form):
        value = match.group(0)
        if value not in seen:
            count = sum(1 for key in seen if seen[key][0] == form) + 1
            prefix = match.group(1) if match.re.groups else None
            seen[value] = (form, form % ((prefix, count) if prefix else count))
        return seen[value][1]

    start = next((entry["at"] for entry in entries if "at" in entry), 0)
    scrubbed = []
    for entry in entries:
        line = json.dumps(entry, ensure_ascii=False)
        for real, replacement in paths:
            line = line.replace(json.dumps(real, ensure_ascii=False)[1:-1], replacement)
        for pattern, form in IDS:
            line = pattern.sub(lambda match: stand_in(match, form), line)
        entry = json.loads(line)
        # Unrounded: a report read just before a hook must stay before it.
        if "at" in entry:
            entry["at"] -= start
        if "report" in entry and "receivedAt" in entry["report"]:
            entry["report"]["receivedAt"] -= start
        scrubbed.append(withhold(entry))
    return scrubbed


def withhold(entry):
    """ENTRY, a scrubbed one, without what a tool returned, nor, from a
    session of the agent outside the task's repository, what it said or did."""
    hook = entry.get("hook")
    if not isinstance(hook, dict):
        return entry
    hook = dict(hook)
    if "tool_response" in hook:
        hook["tool_response"] = WITHHELD
    cwd = hook.get("cwd")
    if isinstance(cwd, str) and not any(cwd == root or cwd.startswith(root + "/") for root in (WORKTREE, REPO)):
        for key in ("prompt", "tool_input", "last_assistant_message", "message"):
            if key in hook:
                hook[key] = WITHHELD
    return dict(entry, hook=hook)


def replay(meta, entries):
    """What the helper makes of each of ENTRIES, a capture's events, read
    in order by a task of META's agent: the `then` of each, or None for a
    step. Times are the capture's, so a report and a hook are weighed by
    when each came, as the live helper weighed them."""
    clock = [EPOCH]
    results = []
    with tempfile.TemporaryDirectory() as root, \
            mock.patch.object(roost.time, "time", lambda: clock[0]):
        store = roost.Store(root)
        task = dict(id=TASK_ID, agent=meta["agent"], command=[meta["agent"]], status="starting",
                    runId=RUN_ID, repo=REPO, worktree=WORKTREE, branch="roost/capture",
                    programStatus=bool(meta.get("programStatus")), startedAt=roost.now(),
                    updatedAt=roost.now())
        store.save(task)
        for entry in entries:
            if "hook" in entry:
                clock[0] = EPOCH + entry["at"]
                roost.update_hook(store, TASK_ID, entry["hook"], RUN_ID)
            elif "report" in entry:
                clock[0] = EPOCH + entry["at"]
                report = dict(entry["report"])
                if "receivedAt" in report:
                    report["receivedAt"] += EPOCH
                with store.locked():
                    task = store.read(TASK_ID)
                    if roost.apply_program_status(task, report, RUN_ID):
                        store.save(task)
            else:
                results.append(None)
                continue
            task = store.read(TASK_ID)
            results.append({key: task[key] for key in FIELDS if task.get(key) not in (None, "")})
    return results


def read(path):
    lines = [json.loads(line) for line in Path(path).read_text().splitlines() if line.strip()]
    return lines[0], lines[1:]


def write(path, meta, entries):
    """Keep ENTRIES in PATH, each event with what the helper now makes of it."""
    thens = replay(meta, entries)
    lines = [meta] + [dict(entry, then=then) if then is not None else entry
                      for entry, then in zip(entries, thens)]
    Path(path).write_text("".join(json.dumps(line, ensure_ascii=False) + "\n" for line in lines))


def save(store, task, meta, name=None):
    """Keep what TASK's agent reported to STORE as a capture, named after
    its agent and META's version, and return its path."""
    raw = store.root / "captures" / (task["id"] + ".jsonl")
    entries = [json.loads(line) for line in raw.read_text().splitlines() if line.strip()] if raw.is_file() else []
    meta = dict(meta, agent=task["agent"], recorded=datetime.date.today().isoformat())
    CAPTURES.mkdir(exist_ok=True)
    path = CAPTURES / ("%s-%s.jsonl" % (name or task["agent"], meta["version"]))
    for entry in entries:
        entry.pop("then", None)
    write(path, meta, scrub(entries, task, store.root))
    return path


def mark(store, task, step):
    """Note in TASK's capture that the run does STEP next."""
    folder = store.root / "captures"
    if folder.is_dir():
        with (folder / (task["id"] + ".jsonl")).open("a") as file:
            file.write(json.dumps({"step": step}) + "\n")


if __name__ == "__main__":
    # Write each capture's `then` again, after a change to the helper that
    # is meant to read real sessions differently; the diff shows how.
    for path in sorted(CAPTURES.glob("*.jsonl")):
        meta, entries = read(path)
        write(path, meta, [{key: value for key, value in entry.items() if key != "then"} for entry in entries])
        print("Wrote", path.name)
