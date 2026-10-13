#!/usr/bin/env python3
"""Use Roost in a GUI Emacs of its own, as you would, and check each step.

The Emacs has a plain configuration, its own server, state directory and
tmux socket, and test/fake_claude.py for Claude Code: real Git, tmux and
host helper, without model calls.  Journeys press keys and click with the
mouse through Emacs's command loop.  After each step, the screen is
checked for Lisp errors, a backtrace, and lines of Roost's views cut off
at the window's edge; on macOS it is captured too.  report.html shows
every step and what was wrong.  The run exits 1 if anything was.

    python3 test/qa/qa.py -L ~/code/tmux-control --package-dir ~/.emacs.d/elpa

Emacs needs tmux-control and its dependencies, from -L directories or
package directories, which are read and never written.
"""

import argparse
import datetime
import html
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import time
import uuid

HERE = Path(__file__).resolve().parent
CHECKOUT = HERE.parent.parent
FAKE = HERE.parent / "fake_claude.py"

FRAME = (172, 40)
PANEL = 44  # roost-task-panel-width

LONG_PROMPT = (
    "Let notes have due dates. " + " ".join(
        "Point %d: say what the due command does with notes that are due on day %d." % (n, n)
        for n in range(1, 16))
    + "\n\nThen add tests for every point above, and keep the existing ones passing.")


class Stuck(Exception):
    """A journey can't go on: what it waited for never came."""


def lisp(value):
    """VALUE as an Emacs Lisp string literal."""
    return '"' + value.replace("\\", "\\\\").replace('"', '\\"') + '"'


class Emacs:
    """The Emacs under test, through emacsclient."""

    def __init__(self, server):
        self.server = server

    def eval(self, expression, timeout=60):
        reply = subprocess.run(["emacsclient", "--socket-name", self.server, "--eval", expression],
                               capture_output=True, text=True, timeout=timeout)
        if reply.returncode:
            raise RuntimeError("emacsclient: %s" % (reply.stderr.strip() or reply.stdout.strip()))
        return reply.stdout.strip()

    def json(self, expression, timeout=60):
        """The JSON in the string EXPRESSION returns."""
        printed = self.eval(expression, timeout)
        # Printed as a Lisp string: only " and \ are escaped.
        return json.loads(re.sub(r'\\(.)', r'\1', printed[1:-1], flags=re.S))


class Run:
    def __init__(self, args):
        self.args = args
        self.out = Path(args.out or tempfile.mkdtemp(prefix="roost-qa-")).resolve()
        self.out.mkdir(parents=True, exist_ok=True)
        self.name = "roost-qa-" + uuid.uuid4().hex[:8]
        # The run's project, state and Emacs, new each time, beside the report.
        self.work = self.out / self.name
        self.work.mkdir()
        self.emacs = Emacs(self.name)
        self.process = None
        self.steps = []
        self.journey = None
        self.shots = 0
        self.winid = None
        self.notes = set()

    # Setting up

    def git(self, cwd, *args):
        return subprocess.run(["git", "-C", str(cwd)] + list(args), check=True,
                              capture_output=True, text=True).stdout.strip()

    def project(self):
        """A small project to work in, with one commit."""
        repo = self.work / "notes"
        repo.mkdir()
        (repo / "notes.py").write_text('"""Notes."""\n\nNOTES = []\n\n\ndef add(text):\n    NOTES.append(text)\n')
        (repo / "README.md").write_text("# notes\n\nA small notes module.\n")
        self.git(repo, "init", "-q", "-b", "main")
        for key, value in (("user.name", "Roost QA"), ("user.email", "qa@example.invalid"),
                           ("commit.gpgsign", "false")):
            self.git(repo, "config", key, value)
        self.git(repo, "add", "-A")
        self.git(repo, "commit", "-q", "-m", "Start the notes module")
        return repo

    def configure(self, repo):
        init = self.work / "emacs"
        init.mkdir()
        (init / "early-init.el").write_text(""";;; -*- lexical-binding: t -*-
(setq native-comp-jit-compilation nil
      ;; qa.el advises a primitive, used here only by code run from source.
      native-comp-enable-subr-trampolines nil
      package-enable-at-startup nil
      inhibit-startup-screen t
      frame-inhibit-implied-resize t)
(dolist (parameter '((width . 172) (height . 40) (menu-bar-lines . 0) (tool-bar-lines . 0)
                     (vertical-scroll-bars) (ns-appearance . dark) (ns-transparent-titlebar . t)))
  (push parameter default-frame-alist))
""")
        (init / "init.el").write_text(""";;; The Emacs Roost's QA drives.  -*- lexical-binding: t -*-
(setq package-user-dir %(elpa)s)
(require 'package)
(dolist (directory '(%(packages)s)) (add-to-list 'package-directory-list directory))
(package-initialize)
(dolist (directory '(%(load)s %(checkout)s %(test)s %(qa)s)) (add-to-list 'load-path directory))
(setq inhibit-default-init t
      make-backup-files nil auto-save-default nil create-lockfiles nil use-short-answers t
      ring-bell-function #'ignore frame-title-format "Roost QA" server-name %(server)s)
(load-theme 'modus-vivendi t)
(when (find-font (font-spec :family "Menlo")) (set-face-attribute 'default nil :family "Menlo" :height 150))
(server-start)
(require 'roost)
(require 'qa)
(require 'roost-sweep)
(setq roost-state-directory %(state)s
      roost-socket-name %(server)s
      roost-hosts '(nil)
      roost-agent-commands '(("claude" %(python)s %(fake)s))
      roost-workspace 'none
      ;; Nobody focuses this Emacs while you work elsewhere.
      roost-watch-unfocused-interval roost-watch-interval
      roost-notify-function #'ignore)
(roost--remember-project %(repo)s)
(roost-watch-mode 1)
(roost-sidebar-mode 1)
(roost-task-panel-mode 1)
(keymap-global-set "C-c r" #'roost-dispatch)
(with-current-buffer "*scratch*" (setq default-directory %(repo)s))
""" % dict(elpa=lisp(str(self.work / "elpa")),
           packages=" ".join(lisp(str(Path(p).expanduser())) for p in self.args.package_dir),
           load=" ".join(lisp(str(Path(p).expanduser())) for p in self.args.load_path),
           checkout=lisp(str(CHECKOUT)), test=lisp(str(CHECKOUT / "test")), qa=lisp(str(HERE)),
           server=lisp(self.name), state=lisp(str(self.work / "state")),
           python=lisp(sys.executable), fake=lisp(str(FAKE)), repo=lisp(str(repo) + "/")))
        return init

    def start(self):
        repo = self.project()
        init = self.configure(repo)
        log = open(self.work / "emacs.log", "w")
        # No site-start.el either: nothing of this machine's own setup.
        self.process = subprocess.Popen([self.args.emacs, "--no-site-file", "--init-directory", str(init)],
                                        stdin=subprocess.DEVNULL, stdout=log, stderr=subprocess.STDOUT)
        deadline = time.monotonic() + 60
        while time.monotonic() < deadline:
            if self.process.poll() is not None:
                sys.exit("Emacs exited; see %s" % (self.work / "emacs.log"))
            try:
                if self.emacs.eval("(featurep 'qa)") == "t":
                    break
            except (RuntimeError, subprocess.TimeoutExpired):
                pass
            time.sleep(0.5)
        else:
            sys.exit("Emacs didn't start its server; see %s" % (self.work / "emacs.log"))
        if not self.emacs.eval("(and (require 'tmux-control nil t) t)") == "t":
            sys.exit("Emacs can't load tmux-control: give its directory with -L, or --package-dir")
        # Set once it runs: a new frame is kept within the screen, and the
        # panel needs room beside a terminal of 80 columns.
        self.emacs.eval("(set-frame-size nil %d %d)" % FRAME)
        for file in self.args.load:
            try:
                self.emacs.eval("(load %s nil t)" % lisp(str(Path(file).resolve())))
            except RuntimeError as error:
                sys.exit("Couldn't load %s: %s" % (file, error))
        self.emacs.eval("(qa-take-errors)")
        return repo

    def stop(self):
        if self.args.keep:
            print("Left running: emacsclient --socket-name %s, tmux -L %s" % (self.name, self.name))
            return
        try:
            self.emacs.eval("(kill-emacs)", timeout=10)
        except Exception:
            pass
        if self.process:
            try:
                self.process.wait(10)
            except subprocess.TimeoutExpired:
                self.process.kill()
        subprocess.run(["tmux", "-L", self.name, "kill-server"], capture_output=True)
        # tmux leaves the socket's file.
        socket = Path(os.environ.get("TMUX_TMPDIR") or "/tmp") / ("tmux-%d" % os.getuid()) / self.name
        socket.unlink(missing_ok=True)

    # Driving

    def keys(self, keys):
        self.emacs.eval("(qa-keys %s)" % lisp(keys))
        self.settle()

    def type(self, text):
        self.emacs.eval("(qa-type %s)" % lisp(text))
        self.settle()

    def click(self, label, occurrence=0):
        if self.emacs.eval("(qa-click %s %d)" % (lisp(label), occurrence)) != "t":
            raise Stuck("No button %r on screen to click" % label)
        self.settle()

    def settle(self, quiet=0.4):
        """Wait until Emacs has taken the input, and a moment for what it started."""
        deadline = time.monotonic() + 20
        while time.monotonic() < deadline and self.emacs.eval("(qa-idle-p)") != "t":
            time.sleep(0.1)
        time.sleep(quiet)

    def screen(self):
        return self.emacs.json("(qa-screen)")

    def wait(self, what, check, timeout=40):
        """Wait until CHECK, given the screen, holds."""
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            screen = self.screen()
            if check(screen):
                return screen
            time.sleep(0.5)
        self.step("Still waiting: " + what)
        raise Stuck("Waited %ds for %s" % (timeout, what))

    def task(self, screen, name):
        return next((task for task in screen["tasks"] if task["name"] == name), None)

    def status(self, name, *statuses, timeout=40):
        return self.wait("%s to be %s" % (name, " or ".join(statuses)),
                         lambda screen: (self.task(screen, name) or {}).get("status") in statuses, timeout)

    # Checking

    def window(self, screen, mode):
        return next((window for window in screen["windows"] if window["mode"] == mode), None)

    def screen_locked(self):
        """Whether macOS has the screen locked, when no window can be captured."""
        registry = subprocess.run(["ioreg", "-n", "Root", "-d1", "-a"], capture_output=True, text=True).stdout
        return bool(re.search(r"<key>CGSSessionScreenIsLocked</key>\s*<true/>", registry))

    def shot(self):
        """Capture the frame, on macOS; return the file's name, or None."""
        if sys.platform != "darwin" or self.args.no_shots:
            return None
        if self.screen_locked():
            self.notes.add("No screenshots while the screen was locked")
            return None
        if self.winid is None:
            source = HERE / "winid.swift"
            self.winid = self.work / "winid"
            if subprocess.run(["swiftc", "-O", "-o", str(self.winid), str(source)],
                              capture_output=True).returncode:
                self.args.no_shots = True
                return None
        pid = self.emacs.eval("(emacs-pid)")
        lines = subprocess.run([str(self.winid), pid], capture_output=True, text=True).stdout.split("\n")
        windows = sorted((line.split() for line in lines if line.strip()),
                         key=lambda w: -float(w[1]) * float(w[2]))
        if not windows:
            return None
        self.shots += 1
        name = "%s/%02d.png" % (self.name, self.shots)
        subprocess.run(["screencapture", "-x", "-o", "-l", windows[0][0], str(self.out / name)],
                       capture_output=True)
        if not (self.out / name).exists():
            self.notes.add("Some screenshots failed: macOS may need to let this terminal record the screen")
            return None
        return name

    def step(self, title, expect=()):
        """Check the screen as it is now, against the rules and EXPECT."""
        self.settle()
        screen = self.screen()
        problems = ["Error: " + error for error in self.emacs.json("(json-encode (vconcat (qa-take-errors)))")]
        for name in screen["buffers"]:
            if name == "*Backtrace*":
                problems.append("A backtrace is showing")
        for window in screen["windows"]:
            if window.get("overflow"):
                over = window["overflow"]
                problems.append("%s: %d lines cut off at the window's edge (%d px), the first %d px: %r" % (
                    window["buffer"], len(over["lines"]), over["width"], over["lines"][0][1],
                    over["lines"][0][0].strip()[:60]))
        for description, check in expect:
            try:
                ok = check(screen)
            except Exception as error:
                ok = False
                description += " (%s)" % error
            if not ok:
                problems.append("Expected: " + description)
        self.steps.append(dict(journey=self.journey, title=title, problems=problems,
                               shot=self.shot(), screen=screen))
        mark = "✗" if problems else "✓"
        print("  %s %s" % (mark, title))
        for problem in problems:
            print("      " + problem)
        return screen

    # Reporting

    def report(self):
        failed = [step for step in self.steps if step["problems"]]
        rows = []
        journey = None
        for step in self.steps:
            if step["journey"] != journey:
                journey = step["journey"]
                rows.append("<h2>%s</h2>" % html.escape(journey))
            problems = "".join("<li>%s</li>" % html.escape(p) for p in step["problems"])
            windows = "".join(
                "<details><summary>%s (%s, %d×%d)</summary><pre>%s</pre></details>" % (
                    html.escape(w["buffer"]), html.escape(w["mode"]), w["columns"], w["lines"],
                    html.escape(w["text"]))
                for w in step["screen"]["windows"])
            shot = ('<img src="%s" alt="The frame after: %s">' % (step["shot"], html.escape(step["title"]))
                    if step["shot"] else "")
            said = "".join("<p><small>%s: %s</small></p>" % (label, html.escape(step["screen"][key]))
                           for key, label in (("echo", "Echo area"), ("prompt", "Minibuffer"))
                           if step["screen"].get(key))
            rows.append('<section class="%s"><h3>%s %s</h3><ul>%s</ul>%s%s%s</section>' % (
                "bad" if step["problems"] else "good", "✗" if step["problems"] else "✓",
                html.escape(step["title"]), problems, said, shot, windows))
        (self.out / "report.html").write_text("""<!doctype html>
<meta charset="utf-8"><title>Roost QA</title>
<style>
body { font: 15px/1.45 -apple-system, system-ui, sans-serif; margin: 2rem auto; max-width: 1100px;
       padding: 0 1rem; background: #fff; color: #222; }
@media (prefers-color-scheme: dark) { body { background: #111; color: #ddd; } }
section { border-left: 4px solid #3a3; padding: .2rem 1rem; margin: 1rem 0; }
section.bad { border-color: #c33; }
img { max-width: 100%%; border-radius: 6px; }
pre { overflow-x: auto; font-size: 12px; }
li { color: #c33; }
</style>
<h1>Roost QA</h1>
<p>%s · %d steps, %d with problems · Roost at %s</p>
%s
%s
""" % (datetime.datetime.now().strftime("%Y-%m-%d %H:%M"), len(self.steps), len(failed),
       html.escape(self.git(CHECKOUT, "rev-parse", "--short", "HEAD")
                   + (" with changes" if self.git(CHECKOUT, "status", "--porcelain") else "")),
       "".join("<p><em>%s.</em></p>" % html.escape(note) for note in sorted(self.notes)),
       "\n".join(rows)))
        return failed


# Journeys

def journey(title):
    def wrap(function):
        function.title = title
        return function
    return wrap


@journey("The sweep, in a GUI frame")
def sweep(qa, repo):
    """test/roost-sweep.el's rules where text is measured in pixels."""
    result = qa.emacs.json("(qa-sweep)", timeout=600)
    qa.step("Every view, state, button and key", expect=[
        ("all of the sweep's tests ran, not %d" % result["ran"], lambda _: result["ran"] >= 4)] + [
        ("%s passes: %s" % (p["test"], p["condition"][:300]), lambda _: False) for p in result["problems"]])


@journey("Start a task and answer it")
def answer(qa, repo):
    qa.step("Roost with no tasks", expect=[
        ("the sidebar says there are none",
         lambda s: "No tasks" in qa.window(s, "roost-sidebar-list-mode")["text"])])
    qa.keys("C-c r")
    qa.step("The menu", expect=[("it offers a new task", lambda s: any("New task" in w["text"] for w in s["windows"]))])
    qa.keys("c")
    qa.step("A new task's draft", expect=[
        ("the draft is selected", lambda s: s["selected"] and qa.window(s, "roost-compose-mode")["selected"])])
    qa.type("ask git status --short")
    qa.keys("C-c C-c")
    qa.status("ask-git-status-short", "permission")
    qa.step("The agent asks", expect=[
        ("the sidebar shows it asking",
         lambda s: "permission" in qa.window(s, "roost-sidebar-list-mode")["text"])])
    qa.keys("C-c r n")
    qa.wait("its terminal", lambda s: any(w["mode"].startswith("tmux-control") and w["selected"]
                                          for w in s["windows"]))
    qa.step("Its terminal, and its panel beside it", expect=[
        ("the panel says to answer in the terminal",
         lambda s: "Answer it in its terminal" in qa.window(s, "roost-task-info-mode")["text"])])
    qa.type("yes\r")
    qa.status("ask-git-status-short", "ready", "idle")
    qa.step("Answered", expect=[
        ("the panel no longer asks",
         lambda s: "Answer it in its terminal" not in qa.window(s, "roost-task-info-mode")["text"])])


@journey("Fold and unfold a long prompt")
def fold(qa, repo):
    qa.keys("C-c r c")
    qa.type(LONG_PROMPT)
    qa.keys("C-c C-c")
    screen = qa.wait("the long task", lambda s: any(t["name"].startswith("let-notes") for t in s["tasks"]))
    name = next(t["name"] for t in screen["tasks"] if t["name"].startswith("let-notes"))
    qa.status(name, "ready", "idle")
    qa.keys("C-c r l")
    qa.type(name + "\r")
    folded = qa.wait("its panel", lambda s: "Show the whole prompt" in
                     (qa.window(s, "roost-task-info-mode") or {}).get("text", ""))
    qa.step("Its panel folds the prompt")
    qa.click("Show the whole prompt")
    qa.step("Shown whole", expect=[
        ("the whole prompt, with a way to fold it",
         lambda s: "Collapse prompt" in qa.window(s, "roost-task-info-mode")["text"]
         and "keep the existing ones passing" in qa.window(s, "roost-task-info-mode")["text"])])
    qa.click("Collapse prompt")
    qa.step("Folded again", expect=[
        ("the panel as it was",
         lambda s: unclocked(qa.window(s, "roost-task-info-mode")["text"])
         == unclocked(qa.window(folded, "roost-task-info-mode")["text"]))])


def panel_fits(qa, screen):
    """Whether the panel is there just when its terminal keeps 80 columns.
    Without it, the terminal would lose the panel's width to it."""
    terminal = next(w for w in screen["windows"] if w["mode"].startswith("tmux-control"))
    panel = qa.window(screen, "roost-task-info-mode")
    if panel:
        return terminal["columns"] >= 80
    return terminal["columns"] - PANEL < 80


def unclocked(text):
    """TEXT without the times that change as it waits, as "ready for 3s"."""
    return re.sub(r"\bfor \d+[smhd]\b", "for …", text)


@journey("Resize the frame")
def resize(qa, repo):
    """The panel docks while the terminal keeps 80 columns, and steps aside otherwise."""
    qa.keys("C-c r c")
    qa.type("Say hello")
    qa.keys("C-c C-c")
    qa.wait("its terminal", lambda s: any(w["mode"].startswith("tmux-control") and w["selected"]
                                          for w in s["windows"]))
    # Heights a laptop's screen has room for: a frame is kept within it.
    for columns, lines in ((100, 30), (150, 40), (220, 40)):
        qa.emacs.eval("(set-frame-size nil %d %d)" % (columns, lines))
        qa.step("%d×%d" % (columns, lines), expect=[
            ("the frame is %d×%d" % (columns, lines),
             lambda s, size=(columns, lines): (s["frame"]["columns"], s["frame"]["lines"]) == size),
            ("the sidebar is still there", lambda s: qa.window(s, "roost-sidebar-list-mode")),
            ("the panel is there just when the terminal keeps 80 columns beside it",
             lambda s: panel_fits(qa, s))])
    qa.emacs.eval("(set-frame-size nil %d %d)" % FRAME)


@journey("Commit, then merge")
def merge(qa, repo):
    qa.keys("C-c r c")
    qa.type("ask sh -c \"printf 'Buy milk\\n' > TODO.md && git add TODO.md && git commit -qm 'Add a to-do list'\"")
    qa.keys("C-c C-c")
    screen = qa.wait("the merge task", lambda s: any(t["name"].startswith("ask-sh") for t in s["tasks"]))
    name = next(t["name"] for t in screen["tasks"] if t["name"].startswith("ask-sh"))
    qa.status(name, "permission")
    qa.keys("C-c r n")
    qa.wait("its terminal", lambda s: any(w["mode"].startswith("tmux-control") and w["selected"]
                                          for w in s["windows"]))
    qa.step("n goes to the task that asks", expect=[
        ("its panel is beside the terminal", lambda s: qa.window(s, "roost-task-info-mode")["text"].startswith(name))])
    qa.type("yes\r")
    qa.status(name, "ready", "idle")
    qa.wait("its commit", lambda s: "TODO.md" in (qa.window(s, "roost-task-info-mode") or {}).get("text", ""))
    qa.step("Committed", expect=[
        ("the panel lists the commit's file", lambda s: "Committed" in qa.window(s, "roost-task-info-mode")["text"]),
        ("and says m merges it", lambda s: "m merges it" in qa.window(s, "roost-task-info-mode")["text"])])
    qa.keys("C-c r m")
    qa.wait("the question", lambda s: s["prompt"])
    qa.step("Merging asks first", expect=[("it names the task", lambda s: name in (s["prompt"] or ""))])
    qa.type("y")
    qa.wait("the task to go", lambda s: qa.task(s, name) is None)
    qa.step("Merged", expect=[
        ("main has the commit", lambda s: "Add a to-do list" in qa.git(repo, "log", "--format=%s", "-3"))])


@journey("Review in Magit and send a note")
def review(qa, repo):
    if qa.emacs.eval("(and (require 'magit nil t) t)") != "t":
        qa.notes.add("No review journey: Magit isn't loaded")
        return
    qa.keys("C-c r c")
    qa.type("ask sh -c \"echo 'TODAY = None' >> notes.py\"")
    qa.keys("C-c C-c")
    screen = qa.wait("the review task", lambda s: any(t["name"].startswith("ask-sh-c-echo") for t in s["tasks"]))
    name = next(t["name"] for t in screen["tasks"] if t["name"].startswith("ask-sh-c-echo"))
    qa.status(name, "permission")
    qa.wait("its terminal", lambda s: any(w["mode"].startswith("tmux-control") and w["selected"]
                                          for w in s["windows"]))
    qa.type("yes\r")
    qa.status(name, "ready", "idle")
    qa.keys("C-c r r")
    qa.wait("Magit", lambda s: (qa.window(s, "magit-status-mode") or {}).get("selected"))
    qa.step("Magit on its worktree", expect=[
        ("it shows the change to notes.py", lambda s: "notes.py" in qa.window(s, "magit-status-mode")["text"])])
    # To the added line in the file's diff, below the agent's reply that names it.
    qa.keys("C-s")
    qa.type("+TODAY")
    qa.keys("RET ;")
    qa.wait("the note box", lambda s: (qa.window(s, "roost-note-box-mode") or {}).get("selected"))
    qa.step("A box under the line", expect=[
        ("it is a frame of its own", lambda s: qa.window(s, "roost-note-box-mode")["child"])])
    qa.type("Call it DUE_TODAY.")
    qa.keys("C-c C-c")
    qa.wait("the note under its line", lambda s: "Call it DUE_TODAY." in
            (qa.window(s, "magit-status-mode") or {}).get("text", ""))
    qa.step("The note shows under its line")
    qa.keys("@")
    qa.wait("the draft", lambda s: (qa.window(s, "roost-send-mode") or {}).get("selected"))
    qa.step("A prompt with the note", expect=[
        ("the draft quotes the note", lambda s: "DUE_TODAY" in qa.window(s, "roost-send-mode")["text"])])
    qa.keys("C-c C-c")
    qa.status(name, "ready", "idle")
    qa.wait("the agent to get it", lambda s: any(
        w["mode"].startswith("tmux-control") and "DUE_TODAY" in w["text"] for w in s["windows"]), timeout=20)
    qa.step("The agent has the note")


JOURNEYS = [sweep, answer, fold, resize, merge, review]


def main():
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("journeys", nargs="*", help="Journeys to take, by function name: %s"
                        % ", ".join(j.__name__ for j in JOURNEYS))
    parser.add_argument("--emacs", default=os.environ.get("EMACS", "emacs"))
    parser.add_argument("-L", dest="load_path", action="append", default=[], help="Add to load-path")
    parser.add_argument("--package-dir", action="append", default=[],
                        help="Activate the packages in this directory, without writing to it")
    parser.add_argument("--load", action="append", default=[], metavar="FILE",
                        help="Load this Emacs Lisp after Roost, such as a change to try")
    parser.add_argument("--out", help="Where the report goes; a new directory by default")
    parser.add_argument("--keep", action="store_true", help="Leave Emacs and tmux running")
    parser.add_argument("--no-shots", action="store_true", help="Take no screenshots")
    args = parser.parse_args()
    known = {j.__name__: j for j in JOURNEYS}
    unknown = [name for name in args.journeys if name not in known]
    if unknown:
        parser.error("no journey %s; there are %s" % (", ".join(unknown), ", ".join(known)))
    chosen = [known[name] for name in args.journeys] or JOURNEYS
    qa = Run(args)
    print("Roost QA in %s" % qa.out)
    try:
        repo = qa.start()
        for chosen_journey in chosen:
            qa.journey = chosen_journey.title
            print(chosen_journey.title)
            try:
                chosen_journey(qa, repo)
            except Stuck as stuck:
                qa.steps.append(dict(journey=qa.journey, title="Stopped", problems=[str(stuck)],
                                     shot=None, screen=qa.screen()))
                print("  ✗ Stopped: %s" % stuck)
    finally:
        try:
            failed = qa.report()
        finally:
            qa.stop()
    for note in sorted(qa.notes):
        print(note)
    print("%d steps, %d with problems: %s" % (len(qa.steps), len(failed), qa.out / "report.html"))
    sys.exit(1 if failed else 0)


if __name__ == "__main__":
    main()
