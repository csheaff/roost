#!/usr/bin/env python3
"""Which functions the terminal_seam models describe have changed since the
commit they were last checked against:  python3 test/formal/terminal_seam/covered.py [COMMIT]

Prints each covered function as `same`, `changed` or `gone`, comparing the
working tree with COMMIT (by default SYNC, below).  A `changed` one means
the models need another look: see .claude/skills/verify-terminal-seam.
Exits 1 when any changed.  ghostel-tmux itself is outside this repository:
the skill says which of its functions the model reads, and at which version."""

import re
import subprocess
import sys
from pathlib import Path

# The commit at which the models were last confirmed to describe the code.
SYNC = "951ce59"

ROOT = Path(__file__).resolve().parents[3]
COVERED = {
    "roost-ghostel-tmux.el": [
        # Which session a buffer belongs to.
        "roost-ghostel-tmux--place", "roost-ghostel-tmux--lost", "roost-ghostel-tmux--was-attached",
        "roost-ghostel-tmux--stand-in", "roost-ghostel-tmux--stands-in-for",
        "roost-ghostel-tmux--controller", "roost-ghostel-tmux--buffer-place",
        "roost-ghostel-tmux-connecting-mode",
        # Open: connect-or-switch and what it calls.
        "roost-ghostel-tmux--find-controller", "roost-ghostel-tmux--snapshots",
        "roost-ghostel-tmux--attach", "roost-ghostel-tmux--pane", "roost-ghostel-tmux--show-pane",
        "roost-ghostel-tmux--stand-in-for", "roost-ghostel-tmux--stand-ins",
        "roost-ghostel-tmux--not-attached", "roost-ghostel-tmux--show-stand-in",
        "roost-ghostel-tmux--sweep-stand-ins", "roost-ghostel-tmux-connect-or-switch",
        # The handoff: Attached, GivesWay, Enter.
        "roost-ghostel-tmux--give-way", "roost-ghostel-tmux--stand-in-shown",
        "roost-ghostel-tmux--stand-in-gives-way", "roost-ghostel-tmux--attached",
        "roost-ghostel-tmux--kept-p",
        # What a stand-in says; panes made, which mark their controller attached.
        "roost-ghostel-tmux--say", "roost-ghostel-tmux--connecting", "roost-ghostel-tmux--pane-made",
        "roost-ghostel-tmux--follow-session", "roost-ghostel-tmux--workspace-closed",
        # A connection that drops: End, Fire, Probe.
        "roost-ghostel-tmux--detached", "roost-ghostel-tmux--attach-again",
        "roost-ghostel-tmux--try-again", "roost-ghostel-tmux-disconnect",
        "roost-ghostel-tmux-reconnect",
    ],
    "roost.el": [
        # Open happens out of the minibuffer; workspaces.
        "roost--when-out-of-minibuffer", "roost--open", "roost--display-task",
        "roost--workspace-backend", "roost--activate-workspace", "roost--terminal-window-for",
    ],
}


def body(text, path, name):
    """NAME's definition in TEXT, the source of PATH, to the next top-level form."""
    start = re.compile(r"^\((def(un|const|var|var-local|var-keymap|macro)|define-derived-mode) %s(\s|$)"
                       % re.escape(name))
    top = re.compile(r"^\(")
    lines = text.splitlines()
    for i, line in enumerate(lines):
        if start.match(line):
            j = i + 1
            while j < len(lines) and not top.match(lines[j]):
                j += 1
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
