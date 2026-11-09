#!/usr/bin/env python3
"""Which functions the git_and_forge models describe have changed since the
commit they were last checked against:  python3 test/formal/git_and_forge/covered.py [COMMIT]

Prints each covered function as `same`, `changed` or `gone`, comparing the
working tree with COMMIT (by default SYNC, below).  A `changed` one means
the models need another look: see .claude/skills/verify-git-and-forge.
Exits 1 when any changed."""

import re
import subprocess
import sys
from pathlib import Path

# The commit at which the models were last confirmed to describe the code.
SYNC = "e910487"

ROOT = Path(__file__).resolve().parents[3]
COVERED = {
    "scripts/roost_remote.py": [
        # Landed.tla
        "is_ancestor", "recorded_pull_request", "has_tip", "merged_tip", "recorded_merge_at",
        "head_to_fetch", "fetch_head", "fetch_heads", "pushed", "task_pull_requests",
        "shown_pull_request", "check_pull_requests", "landed", "merged_pull_request_head",
        "safe_to_delete", "push_pull_request", "record_push", "pull_request",
        # Both: rpc's `pr` and `list` branches, and the measurement.
        "rpc", "add_git_stats",
        # MergedWord.tla: commits move the stamp, so a poll looks again.
        "git_stamp",
    ],
    "roost.el": [
        # MergedWord.tla
        "roost--refresh-host", "roost--owe-measuring", "roost--task-states", "roost--cache-task",
        "roost--newer-events", "roost--apply-snapshot", "roost--measured-fields", "roost--landed",
        "roost--merged-p", "roost--display-status", "roost-refresh",
    ],
}


def body(text, path, name):
    """NAME's definition in TEXT, the source of PATH, with its decorators,
    to the next top-level form."""
    if path.endswith(".py"):
        start = re.compile(r"^def %s\(" % re.escape(name))
        top = re.compile(r"^[^\s#)]")
    else:
        start = re.compile(r"^\(def(un|const|var|var-keymap|macro) %s(\s|$)" % re.escape(name))
        top = re.compile(r"^\(")
    lines = text.splitlines()
    for i, line in enumerate(lines):
        if start.match(line):
            j = i + 1
            while j < len(lines) and not top.match(lines[j]):
                j += 1
            while i and lines[i - 1].startswith("@"):  # its decorators too
                i -= 1
            return "\n".join(lines[i:j]).rstrip()
    return None


def main(commit):
    changed = False
    for path, names in COVERED.items():
        now = (ROOT / path).read_text()
        then = subprocess.run(["git", "-C", str(ROOT), "show", "%s:%s" % (commit, path)],
                              capture_output=True, text=True, check=True).stdout
        for name in names:
            new, old = body(now, path, name), body(then, path, name)
            word = "gone" if new is None else "same" if new == old else "changed"
            changed |= word != "same"
            print("%-8s %s  %s" % (word, path, name))
    return 1 if changed else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1] if len(sys.argv) > 1 else SYNC))
