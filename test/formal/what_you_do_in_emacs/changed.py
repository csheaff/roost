#!/usr/bin/env python3
"""Which code these models cover has changed since they were last checked
against it: python3 test/formal/what_you_do_in_emacs/changed.py [COMMIT]

Compares each covered definition at SYNC (or COMMIT) with the working tree.
Move SYNC forward only once each one listed has been read against its step;
see .claude/skills/verify-what-you-do-in-emacs.
"""

import re
import subprocess
import sys
from pathlib import Path

SYNC = "d31ec86"
ROOT = Path(__file__).resolve().parents[3]
COVERED = {
    "roost.el": [
        "roost-compose-submit", "roost--compose-what", "roost--compose-made",
        "roost--compose-listed", "roost--task-made", "roost--create-task",
        "roost--when-out-of-minibuffer", "roost--close-buffer",
        "roost--quit-questions-left-open", "roost--quit-questions-here",
        "roost-send-submit", "roost--send-kept", "roost--send-text",
        "roost--send-draft-text", "roost--run", "roost--expire-request",
    ],
    "scripts/roost_remote.py": [
        "create", "asking_for", "made_for", "make_task", "abandon",
        "send", "SEND_IDS_KEPT", "rpc",
    ],
}


def definition(text, name, lisp):
    """NAME's definition in TEXT, up to the next top-level form, or None."""
    start = (r"^\(def\S* %s[\s)]" if lisp else r"^(?:def %s\(|%s = )") % (
        (re.escape(name),) if lisp else (re.escape(name), re.escape(name)))
    m = re.search(start, text, re.M)
    if not m:
        return None
    end = re.compile(r"^\(" if lisp else r"^[^\s#]", re.M).search(text, m.end())
    return text[m.start():end.start() if end else len(text)]


def main(sync):
    changed = []
    for path, names in COVERED.items():
        old = subprocess.run(["git", "show", "%s:%s" % (sync, path)], cwd=ROOT,
                             capture_output=True, text=True, check=True).stdout
        new = (ROOT / path).read_text()
        for name in names:
            a, b = (definition(t, name, path.endswith(".el")) for t in (old, new))
            if a is None:
                sys.exit("%s isn't in %s at %s: fix COVERED" % (name, path, sync))
            if a != b:
                changed.append("%s: %s%s" % (path, name, "" if b else " (gone)"))
    print("\n".join(changed) if changed else "No covered code changed since %s." % sync)


if __name__ == "__main__":
    main(sys.argv[1] if len(sys.argv) > 1 else SYNC)
