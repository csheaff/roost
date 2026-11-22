#!/usr/bin/env python3
"""Which functions the pull_request_merged models describe have changed since the
commit they were last checked against:  python3 test/formal/pull_request_merged/covered.py [COMMIT]

Prints each covered function as `same`, `changed` or `gone`, comparing the
working tree with COMMIT (by default SYNC, below).  A `changed` one means
the models need another look: see .claude/skills/verify-pull-request-merged.
Exits 1 when any changed."""

import re
import subprocess
import sys
from pathlib import Path

# The commit at which the models were last confirmed to describe the code.
SYNC = "be4b319"

ROOT = Path(__file__).resolve().parents[3]
COVERED = {
    "scripts/roost_remote.py": [
        # The helper's side, in every model: the record, the one call, its end.
        "merge_asked", "merges_asked", "begin_merge", "merge_pull_request", "end_merge",
        # `prMerge` as a task is made, and `merge-pr` with the lock let go for the call.
        "make_task", "answer",
        # Poll: the pull request's state recorded, and what the forge says.
        "check_pull_requests",
    ],
    "roost.el": [
        # What Emacs reads of its copy.
        "roost--merge-occurrence", "roost--merge-asked", "roost--merge-due-p", "roost--merges-turn-p",
        "roost--yours", "roost--pr-verdict", "roost--pr-status", "roost--prompting-p",
        # Asking, and its replies into the copy.
        "roost--merge-itself", "roost--act", "roost--cache-task",
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
