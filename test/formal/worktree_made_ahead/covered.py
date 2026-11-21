#!/usr/bin/env python3
"""Which functions the worktree_made_ahead models describe have changed since the
commit they were last checked against:  python3 test/formal/worktree_made_ahead/covered.py [COMMIT]

Prints each covered function as `same`, `changed` or `gone`, comparing the
working tree with COMMIT (by default SYNC, below).  A `changed` one means
the models need another look: see .claude/skills/verify-worktree-made-ahead.
Exits 1 when any changed."""

import re
import subprocess
import sys
from pathlib import Path

# The commit at which the models were last confirmed to describe the code.
SYNC = "c1616b6"

ROOT = Path(__file__).resolve().parents[3]
COVERED = {
    "scripts/roost_remote.py": [
        # A creation's take, and what undoes one cut short.
        "take_ready_for", "take_ready", "begin_head_log", "changed_in", "on_task_branch", "runs_hooks_alone",
        "trash_worktree", "settle_creation", "undo_creation", "initializing", "abandon",
        # Where a creation takes one, and what follows one it couldn't.
        "make_task",
        # The wish, and the run that carries it out.
        "want_ready", "tend_ready_later", "started", "tend_ready", "tend_wanted", "tend_one",
        # What a sweep keeps and removes, for a wish or after a listing.
        "sweep_ready", "unwanted_ready", "unmarked_ready", "drop_ready", "prune_ready_later",
        "ready_marks", "ready_locked",
        # Where a creation's reply and a listing's start their runs.
        "main",
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
