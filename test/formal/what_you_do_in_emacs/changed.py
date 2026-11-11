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

SYNC = "8f651f3"
ROOT = Path(__file__).resolve().parents[3]
COVERED = {
    "roost.el": [
        "roost-compose-submit", "roost--compose-what", "roost--compose-words",
        "roost--compose-made", "roost--compose-listed", "roost--task-made",
        "roost--create-task", "roost--compose-agents", "roost--attempt-field",
        "roost--compose-continues", "roost--compose-offer",
        "roost--when-out-of-minibuffer", "roost--close-buffer",
        "roost--quit-questions-left-open", "roost--quit-questions-here",
        "roost-send-submit", "roost--send-kept", "roost--send-text",
        "roost--send-draft-text", "roost--run", "roost--expire-request",
    ],
    "scripts/roost_remote.py": [
        "create", "asking_for", "made_for", "make_task", "attempt_of",
        "made_from_other_words", "abandon", "send", "SEND_IDS_KEPT", "rpc",
    ],
}


def definition(text, name, lisp):
    """NAME's definition in TEXT, with its decorators, up to the next
    top-level form, or None."""
    start = (r"^\(def\S* %s[\s)]" if lisp else r"^(?:def %s\(|%s = )") % (
        (re.escape(name),) if lisp else (re.escape(name), re.escape(name)))
    m = re.search(start, text, re.M)
    if not m:
        return None
    begin = m.start()
    while not lisp and begin:
        # Its decorators, as @contextlib.contextmanager, are part of it.
        above = text.rfind("\n", 0, begin - 1) + 1
        if not text.startswith("@", above):
            break
        begin = above
    end = re.compile(r"^\(" if lisp else r"^[^\s#)]", re.M).search(text, m.end())
    return text[begin:end.start() if end else len(text)]


def main(sync):
    changed = []
    for path, names in COVERED.items():
        old = subprocess.run(["git", "show", "%s:%s" % (sync, path)], cwd=ROOT,
                             capture_output=True, text=True, check=True).stdout
        new = (ROOT / path).read_text()
        for name in names:
            a, b = (definition(t, name, path.endswith(".el")) for t in (old, new))
            if a is None and b is None:
                sys.exit("%s isn't in %s, at %s or now: fix COVERED" % (name, path, sync))
            if a != b:
                changed.append("%s: %s%s" % (path, name, "" if a and b else " (new)" if b else " (gone)"))
    print("\n".join(changed) if changed else "No covered code changed since %s." % sync)


if __name__ == "__main__":
    main(sys.argv[1] if len(sys.argv) > 1 else SYNC)
