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


class Known(tuple):
    """An expectation that fails for a known reason, reported but not a problem:
    Known((DESCRIPTION, CHECK)).  The report says when it starts to hold."""


def qa_sidebar(screen):
    """Whether SCREEN shows the sidebar."""
    return any(w["mode"] == "roost-sidebar-list-mode" for w in screen["windows"])


def lisp(value):
    """VALUE as an Emacs Lisp string literal."""
    return '"' + value.replace("\\", "\\\\").replace('"', '\\"') + '"'


class Emacs:
    """The Emacs under test, through emacsclient."""

    def __init__(self, server):
        self.server = server

    def eval(self, expression, timeout=60):
        try:
            reply = subprocess.run(["emacsclient", "--socket-name", self.server, "--eval", expression],
                                   capture_output=True, text=True, timeout=timeout)
        except subprocess.TimeoutExpired:
            # Its command loop is busy, or waits for something.
            raise Stuck("Emacs didn't answer in %ds" % timeout) from None
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
        # Git as it comes, without your configuration's hooks or signing,
        # and a home of the run's own: no ~/.tmux.conf or shell setup of
        # yours, and the fake agent's transcripts not among your Claude's.
        (self.work / "gitconfig").write_text("")
        home = self.work / "home"
        home.mkdir()
        self.env = dict(os.environ, GIT_CONFIG_GLOBAL=str(self.work / "gitconfig"), GIT_CONFIG_NOSYSTEM="1",
                        HOME=str(home), FAKE_CLAUDE_TRANSCRIPTS="1",
                        # Where tmux and others look besides the home.
                        XDG_CONFIG_HOME=str(home / ".config"), XDG_DATA_HOME=str(home / ".local/share"),
                        XDG_STATE_HOME=str(home / ".local/state"), XDG_CACHE_HOME=str(home / ".cache"))
        # Shell startup files named outside the home, and the tmux you may
        # be running this in.
        for name in ("ZDOTDIR", "BASH_ENV", "ENV", "TMUX", "TMUX_PANE"):
            self.env.pop(name, None)
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
                              capture_output=True, text=True, env=self.env).stdout.strip()

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
      roost-workspace nil
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
        self.init = self.configure(repo)
        self.launch()
        return repo

    def restart(self):
        """Quit Emacs, leaving tmux, the agents and Roost's state as they are,
        and start it again, as after quitting yours."""
        self.emacs.eval("(kill-emacs)", timeout=10) if self.process.poll() is None else None
        self.process.wait(20)
        self.launch()

    def launch(self):
        log = open(self.work / "emacs.log", "a")
        # No site-start.el either: nothing of this machine's own setup.
        self.process = subprocess.Popen([self.args.emacs, "--no-site-file", "--init-directory", str(self.init)],
                                        stdin=subprocess.DEVNULL, stdout=log, stderr=subprocess.STDOUT,
                                        env=self.env)
        deadline = time.monotonic() + 60
        while time.monotonic() < deadline:
            if self.process.poll() is not None:
                sys.exit("Emacs exited; see %s" % (self.work / "emacs.log"))
            try:
                if self.emacs.eval("(featurep 'qa)") == "t":
                    break
            except (RuntimeError, Stuck):
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

    def click_text(self, text, mode=None):
        """Click on TEXT, as shown, in a window in MODE if given."""
        if self.emacs.eval("(qa-click-text %s %s)" % (lisp(text), lisp(mode) if mode else "nil")) != "t":
            raise Stuck("No %r on screen to click" % text)
        self.settle()

    def settle(self, quiet=0.4):
        """Wait until Emacs has taken the input, and a moment for what it started."""
        deadline = time.monotonic() + 20
        while self.emacs.eval("(qa-idle-p)", timeout=max(1, deadline - time.monotonic())) != "t":
            if time.monotonic() > deadline:
                raise Stuck("Emacs didn't take the input in 20s")
            time.sleep(0.1)
        time.sleep(quiet)

    def screen(self):
        return self.emacs.json("(qa-screen)")

    def tmux(self, *args):
        """What tmux on this run's socket says to ARGS, as lines."""
        return subprocess.run(["tmux", "-L", self.name] + list(args), capture_output=True,
                              text=True).stdout.split("\n")[:-1]

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
        task = screen.get("task")
        frames = screen.get("frames") or {}
        # By key: tasks can share a name.  The sidebar, one for every frame,
        # marks the task opened last, so with one frame, that frame's.
        if task and len(frames) == 1 and qa_sidebar(screen) and screen.get("marked") != task["key"]:
            problems.append("The sidebar marks %s, not %s, the frame's task (%s)"
                            % (screen.get("marked"), task["key"], task["name"]))
        for window in screen["windows"]:
            if window.get("terminal") and not window.get("child"):
                own = (frames.get(window.get("frame")) or None) if window.get("frame") in frames else task
                if not own:
                    problems.append("%s, a terminal, is on screen with no task for its frame" % window["buffer"])
                elif window["terminal"] != own["terminal"]:
                    problems.append("%s, another task's terminal, is beside %s's" % (window["buffer"], own["name"]))
            if window["mode"] == "roost-sidebar-list-mode" and window["total"] != screen["sidebar-width"]:
                problems.append("The sidebar is %d columns wide, not %d" % (window["total"], screen["sidebar-width"]))
            if window.get("history"):
                # Nothing here scrolls a terminal back: it showed history by itself.
                problems.append("%s shows %d lines of history above its screen" % (window["buffer"], window["history"]))
            if window.get("terminal") and window.get("pane"):
                drift = self.drift(window)
                if drift:
                    problems.append(drift)
            if window.get("overflow"):
                over = window["overflow"]
                problems.append("%s: %d lines cut off at the window's edge (%d px), the first %d px: %r" % (
                    window["buffer"], len(over["lines"]), over["width"], over["lines"][0][1],
                    over["lines"][0][0].strip()[:60]))
        known = []
        for expectation in expect:
            description, check = expectation[:2]
            raised = False
            try:
                ok = check(screen)
            except Exception as error:
                ok, raised = False, True
                description += " (%s)" % error
            # A check that broke is a problem, known or not: only its plain
            # failure is the known behavior.
            if isinstance(expectation, Known) and not raised:
                if ok:
                    self.notes.add("A known problem no longer happens, so it can be an expectation: "
                                   + description)
                else:
                    known.append(description)
            elif not ok:
                problems.append("Expected: " + description)
        self.steps.append(dict(journey=self.journey, title=title, problems=problems, known=known,
                               shot=self.shot(), screen=screen))
        mark = "✗" if problems else "✓"
        print("  %s %s" % (mark, title))
        for problem in problems:
            print("      " + problem)
        for description in known:
            print("      known: " + description)
        return screen

    def drift(self, window, timeout=3):
        """How WINDOW's terminal differs from what tmux has in its pane, or None.
        Output on its way may take a moment to show.  A dead pane is left out:
        tmux writes its "Pane is dead" line there without telling its control
        clients, and the view keeps the agent's last output whole."""
        deadline = time.monotonic() + timeout
        while True:
            ours = self.emacs.json("(json-encode (qa-terminal-screen %s))" % lisp(window["buffer"])) or []
            theirs = [line.rstrip() for line in self.tmux("capture-pane", "-p", "-t", window["pane"])]
            # Asked after each capture: the pane can die while it is compared.
            if self.tmux("display-message", "-p", "-t", window["pane"], "#{pane_dead}") == ["1"]:
                return None
            while theirs and not theirs[-1]:
                theirs.pop()
            if ours == theirs or time.monotonic() > deadline:
                break
            time.sleep(0.25)
        if ours == theirs:
            return None
        row = next((i for i, (a, b) in enumerate(zip(ours, theirs)) if a != b), min(len(ours), len(theirs)))
        return "%s shows other than tmux's pane %s, from row %d: %r, where tmux has %r" % (
            window["buffer"], window["pane"], row + 1, (ours[row:row + 1] or [""])[0][:50],
            (theirs[row:row + 1] or [""])[0][:50])

    # Reporting

    def report(self):
        failed = [step for step in self.steps if step["problems"]]
        rows = []
        journey = None
        for step in self.steps:
            if step["journey"] != journey:
                journey = step["journey"]
                rows.append("<h2>%s</h2>" % html.escape(journey))
            problems = "".join("<li>%s</li>" % html.escape(p) for p in step["problems"]) + "".join(
                '<li class="known">Known: %s</li>' % html.escape(k) for k in step.get("known", []))
            windows = "".join(
                "<details><summary>%s (%s, %d×%d)%s</summary><pre>%s</pre></details>" % (
                    html.escape(w["buffer"]), html.escape(w["mode"]), w["columns"], w["lines"],
                    "".join(" · %s %s" % (label, html.escape(w[key]))
                            for key, label in (("terminal", "session"), ("tabs", "tabs")) if w.get(key)),
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
li.known { color: #888; }
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
    # Once its changes are in: they may still be refreshing when it first shows.
    qa.wait("its panel", lambda s: "Show the whole prompt" in panel_text(qa, s)
            and "Refreshing" not in panel_text(qa, s))
    folded = qa.step("Its panel folds the prompt")
    qa.click("Show the whole prompt")
    qa.step("Shown whole", expect=[
        ("the whole prompt, with a way to fold it",
         lambda s: "Collapse prompt" in panel_text(qa, s)
         and "keep the existing ones passing" in panel_text(qa, s)),
        ("point on the way back", lambda s: s["at"] == "Collapse prompt")])
    qa.click("Collapse prompt")
    qa.step("Folded again", expect=[
        ("the panel as it was",
         lambda s: unclocked(panel_text(qa, s)) == unclocked(panel_text(qa, folded))),
        ("point on the way back", lambda s: s["at"] == "Show the whole prompt")])


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
    # Listed under Committed: before, it can show between the agent's add and commit.
    qa.wait("its commit", lambda s: re.search(r"Committed\n\s*TODO\.md",
                                              (qa.window(s, "roost-task-info-mode") or {}).get("text", "")))
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
        ("it is a frame of its own", lambda s: qa.window(s, "roost-note-box-mode")["child"]),
        ("the task is still the frame's, for the checks", lambda s: (s.get("task") or {}).get("name") == name)])
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


def panel_text(qa, screen):
    """The docked panel's text, or else that of the first task panel on screen."""
    docked = next((w for w in screen["windows"]
                   if w["mode"] == "roost-task-info-mode" and w.get("side") == "right"), None)
    return (docked or qa.window(screen, "roost-task-info-mode") or {}).get("text", "")


def terminals(screen, terminal=None):
    """The terminal windows on SCREEN, or those of TERMINAL's session."""
    return [w for w in screen["windows"]
            if w.get("terminal") and (terminal is None or w["terminal"] == terminal)]


def selected_terminal(screen):
    return next((w for w in screen["windows"] if w.get("terminal") and w["selected"]), None)


def new_task(qa, prompt):
    """Start a task with PROMPT from the menu; return its name once listed."""
    before = {t["name"] for t in qa.screen()["tasks"]}
    qa.keys("C-c r c")
    qa.type(prompt)
    qa.keys("C-c C-c")
    screen = qa.wait("the task for %r" % prompt[:30], lambda s: {t["name"] for t in s["tasks"]} - before)
    return next(t["name"] for t in screen["tasks"] if t["name"] not in before)


def start_task(qa, prompt, prefix=None):
    """Start a task with PROMPT and wait until it is ready; return its name."""
    name = new_task(qa, prompt)
    qa.status(name, "ready", "idle")
    return name


def open_task(qa, name):
    qa.keys("C-c r l")
    qa.type(name + "\r")
    return qa.wait(name + "'s terminal", lambda s: (s.get("task") or {}).get("name") == name
                   and selected_terminal(s))


@journey("Panes and windows across tasks")
def panes(qa, repo):
    """Each task keeps its own panes and windows, in its own terminal."""
    first = start_task(qa, "Count to three", "count-three")
    second = start_task(qa, "Count to five", "count-five")
    screen = open_task(qa, first)
    own = screen["task"]["terminal"]
    qa.keys("C-c |")
    qa.step("Split in two", expect=[
        ("two panes of its own", lambda s: len(terminals(s, own)) == 2)])
    qa.keys("M-x")
    qa.type("tmux-control-new-window\r")
    qa.wait("the name prompt", lambda s: s["prompt"])
    qa.keys("RET")
    session = own.split("/")[-1]
    qa.wait("a second window", lambda s: len(qa.tmux("list-windows", "-t", session)) == 2)
    # As tmux numbers them: your configuration may start at 1.
    window_a, window_b = qa.tmux("list-windows", "-t", session, "-F", "#{window_index}")
    # tmux-control shows no tabs while a session is split into panes.
    qa.step("A second tmux window", expect=[
        Known(("its tab is the highlighted one",
               lambda s: "[%s:" % window_b in (selected_terminal(s).get("tabs") or "")))])
    qa.keys("C-c C-p")
    qa.step("Back to the first window", expect=[
        Known(("its tab is the highlighted one",
               lambda s: "[%s:" % window_a in (selected_terminal(s).get("tabs") or ""))),
        ("with both its panes", lambda s: len(terminals(s, own)) == 2)])
    qa.keys("C-c C-w")
    qa.wait("the window chooser", lambda s: any("chooser" in w["buffer"] for w in s["windows"]))
    qa.step("Choosing a window", expect=[
        ("it offers the task's two windows and no others",
         lambda s: [l.split(":")[0] for l in next(w for w in s["windows"] if "chooser" in w["buffer"])["text"]
                    .split("\n") if re.match(r"\s*\d+:", l)] == [window_a, window_b])])
    qa.keys("q")
    screen = open_task(qa, second)
    qa.step("The other task", expect=[
        ("only its own terminal", lambda s: terminals(s)
         and all(w["terminal"] == s["task"]["terminal"] for w in terminals(s))),
        ("its panel beside it", lambda s: (qa.window(s, "roost-task-info-mode") or {}).get("text", "").startswith(second))])
    qa.keys("C-c C-s")
    qa.wait("the session prompt", lambda s: s["prompt"])
    qa.step("Choosing a session")
    qa.type(session + "\r")
    qa.wait(first + " again", lambda s: (s.get("task") or {}).get("name") == first)
    qa.step("Back to the first task", expect=[
        ("its two panes, as it left them", lambda s: len(terminals(s, own)) == 2),
        ("and nothing of the other task's", lambda s: all(w["terminal"] == own for w in terminals(s)))])
    to_shell(qa)
    qa.type("exit\r")
    qa.wait("the shell to go", lambda s: len(terminals(s, own)) == 1)
    qa.step("One pane again", expect=[
        ("its panel back beside it", lambda s: panel_text(qa, s).startswith(first)),
        ("its tabs back, its window highlighted",
         lambda s: "[%s:" % window_a in (selected_terminal(s).get("tabs") or ""))])


def to_shell(qa):
    """Move to the shell pane beside the agent, wherever the view has put you:
    what is typed next must not reach the agent."""
    screen = qa.screen()
    if (selected_terminal(screen) or {}).get("pane") == (screen.get("task") or {}).get("pane"):
        qa.keys("C-c C-o")


def answer_yes(qa, name):
    """Answer NAME's agent's permission prompt in its terminal, and wait until it is done."""
    qa.status(name, "permission")
    open_task(qa, name)
    qa.type("yes\r")
    qa.status(name, "ready", "idle")


@journey("The dashboard")
def dashboard(qa, repo):
    name = start_task(qa, "Tidy the notes", "tidy-notes")
    qa.keys("C-c r S")
    qa.wait("the dashboard", lambda s: (qa.window(s, "roost-dashboard-mode") or {}).get("selected"))
    qa.step("The dashboard", expect=[
        ("it lists the task", lambda s: name in qa.window(s, "roost-dashboard-mode")["text"])])
    qa.keys("g")
    qa.step("Refreshed")
    # To its row, among the others.
    qa.keys("C-s")
    qa.type(name)
    qa.keys("RET")
    qa.keys("i")
    qa.wait("the task's details", lambda s: panel_text(qa, s).startswith(name))
    qa.step("Its details", expect=[("they name the task", lambda s: panel_text(qa, s).startswith(name))])
    qa.keys("C-c r S")
    qa.wait("the dashboard", lambda s: (qa.window(s, "roost-dashboard-mode") or {}).get("selected"))
    qa.keys("C-s")
    qa.type(name)
    qa.keys("RET RET")
    qa.wait("its terminal", lambda s: (s.get("task") or {}).get("name") == name and selected_terminal(s))
    qa.step("RET opens it", expect=[("its panel beside it", lambda s: panel_text(qa, s).startswith(name))])


@journey("Stop and resume an agent")
def stop_resume(qa, repo):
    name = start_task(qa, "Wait for me", "wait-me")
    open_task(qa, name)
    qa.keys("C-c r K")
    qa.wait("the question", lambda s: s["prompt"])
    qa.step("Stopping asks first", expect=[("it names the task", lambda s: name in (s["prompt"] or ""))])
    qa.type("y")
    qa.status(name, "stopped")
    qa.step("Stopped", expect=[
        ("the panel says how to resume", lambda s: "resumes its conversation" in panel_text(qa, s))])
    # In the panel, as it says: elsewhere, such as a dashboard row, s is
    # that row's task's.
    qa.click_text(name, "roost-task-info-mode")
    qa.keys("s")
    qa.wait("its agent again", lambda s: (qa.task(s, name) or {}).get("status") not in (None, "stopped"))
    qa.status(name, "ready", "idle")
    qa.step("Resumed", expect=[
        ("its terminal", lambda s: (s.get("task") or {}).get("name") == name and selected_terminal(s)),
        ("the panel no longer says to resume", lambda s: "resumes its conversation" not in panel_text(qa, s))])


@journey("Retire a task, or keep its work")
def retire(qa, repo):
    clean = start_task(qa, "Look around", "look-around")
    open_task(qa, clean)
    qa.keys("C-c r x")
    qa.wait("the question", lambda s: s["prompt"])
    qa.step("Retiring asks first", expect=[
        ("it says nothing would be lost", lambda s: "Nothing in them would be lost" in (s["prompt"] or ""))])
    qa.type("y")
    qa.wait("the task to go", lambda s: qa.task(s, clean) is None, timeout=30)
    qa.step("A task with no work retires", expect=[
        ("the echo area says so", lambda s: "Retired" in (s["echo"] or ""))])
    dirty = new_task(qa, "ask touch scratch.txt")
    answer_yes(qa, dirty)
    # Once Roost knows of the file: before, it asks as for a task with no work,
    # and offers to discard only once the host refuses.
    qa.wait("the file among its changes", lambda s: re.search(r"Uncommitted\n\s*scratch\.txt", panel_text(qa, s)))
    qa.keys("C-c r x")
    qa.wait("the question", lambda s: s["prompt"])
    qa.step("Work not merged: it asks", expect=[
        ("it offers to discard it", lambda s: "Discard" in (s["prompt"] or ""))])
    qa.type("n")
    qa.step("Kept", expect=[("the task is still there", lambda s: qa.task(s, dirty))])
    qa.keys("C-c r x")
    qa.wait("the question", lambda s: s["prompt"])
    qa.type("y")
    qa.wait("the name to type", lambda s: s["prompt"] and dirty in s["prompt"])
    qa.step("Discarding asks for its name", expect=[
        ("the prompt names it", lambda s: dirty in (s["prompt"] or ""))])
    qa.type(dirty + "\r")
    qa.wait("the task to go", lambda s: qa.task(s, dirty) is None, timeout=30)
    qa.step("Discarded", expect=[
        ("its branch is gone", lambda s: not qa.git(repo, "branch", "--list", "roost/" + dirty + "*"))])


@journey("Send a prompt")
def send(qa, repo):
    name = start_task(qa, "Say hi", "say-hi")
    open_task(qa, name)
    qa.keys("C-c r e")
    qa.wait("the prompt", lambda s: s["prompt"])
    qa.step("A prompt to send", expect=[("it names the task", lambda s: name in (s["prompt"] or ""))])
    qa.type("How are you?\r")
    qa.wait("the agent to get it", lambda s: any("PROMPT How are you?" in w["text"] for w in terminals(s)))
    qa.status(name, "ready", "idle")
    qa.step("Sent", expect=[("the echo area says so", lambda s: "Sent to " + name in (s["echo"] or ""))])


@journey("Bring a task up to date")
def update(qa, repo):
    behind = start_task(qa, "Stay behind", "stay-behind")
    ahead = new_task(qa, "ask env sh -c \"printf 'x\\n' > AHEAD.md && git add AHEAD.md && git commit -qm 'Go ahead'\"")
    answer_yes(qa, ahead)
    qa.wait("its commit", lambda s: "Committed" in panel_text(qa, s))
    qa.keys("C-c r m")
    qa.wait("the question", lambda s: s["prompt"])
    qa.type("y")
    qa.wait("the task to go", lambda s: qa.task(s, ahead) is None)
    open_task(qa, behind)
    qa.wait("main to have moved on", lambda s: "has moved on" in panel_text(qa, s))
    qa.step("Behind main", expect=[("the panel says u brings it up", lambda s: "u" in panel_text(qa, s))])
    qa.keys("C-c r u")
    qa.wait("it to catch up", lambda s: "has moved on" not in panel_text(qa, s))
    qa.step("Up to date", expect=[
        ("the panel no longer says it is behind", lambda s: "has moved on" not in panel_text(qa, s))])


@journey("Restart Emacs")
def restart(qa, repo):
    name = start_task(qa, "Remember me", "remember-me")
    qa.restart()
    qa.wait("the task, after the restart", lambda s: qa.task(s, name))
    qa.step("After a restart", expect=[
        ("the sidebar lists it", lambda s: name in (qa.window(s, "roost-sidebar-list-mode") or {}).get("text", ""))])
    open_task(qa, name)
    qa.step("Its terminal again", expect=[
        ("the agent's earlier output", lambda s: any("PROMPT Remember me" in w["text"] for w in terminals(s))),
        ("its panel beside it", lambda s: panel_text(qa, s).startswith(name))])


@journey("Search the conversations")
def search(qa, repo):
    name = start_task(qa, "Find the needle in the notes", None)
    qa.keys("C-c r /")
    qa.wait("the search prompt", lambda s: s["prompt"])
    qa.type("needle\r")
    qa.wait("the results", lambda s: name in (qa.window(s, "roost-search-mode") or {}).get("text", ""))
    qa.step("Messages with the word", expect=[
        ("yours", lambda s: "You" in qa.window(s, "roost-search-mode")["text"]),
        ("and the agent's", lambda s: "PROMPT Find the needle" in qa.window(s, "roost-search-mode")["text"])])
    results = qa.window(qa.screen(), "roost-search-mode")["text"]
    qa.keys("TAB")
    qa.step("A message shown whole", expect=[
        ("more than before", lambda s: qa.window(s, "roost-search-mode")["text"] != results)])
    qa.keys("TAB")
    qa.step("Folded again", expect=[
        ("as it was", lambda s: qa.window(s, "roost-search-mode")["text"] == results)])
    qa.keys("RET")
    qa.wait("its terminal", lambda s: (s.get("task") or {}).get("name") == name and selected_terminal(s))
    qa.step("RET opens its task", expect=[("its panel beside it", lambda s: panel_text(qa, s).startswith(name))])


@journey("A second frame")
def frames(qa, repo):
    """Each frame keeps its own task: what one shows, the other leaves alone."""
    first = start_task(qa, "Mind the first frame", None)
    open_task(qa, first)
    qa.keys("C-x 5 2")
    qa.wait("the new frame", lambda s: len(s.get("frames") or {}) == 2)
    qa.emacs.eval("(set-frame-size nil %d %d)" % FRAME)
    qa.step("A second frame", expect=[
        ("each frame has the sidebar",
         lambda s: len([w for w in s["windows"] if w["mode"] == "roost-sidebar-list-mode"]) == 2)])
    second = start_task(qa, "Mind the second frame", None)
    qa.step("A task in the second frame", expect=[
        ("its terminal there", lambda s: (s.get("task") or {}).get("name") == second and selected_terminal(s)),
        ("and the first frame still the first task's",
         lambda s: any((t or {}).get("name") == first for t in (s.get("frames") or {}).values()))])
    qa.keys("C-x 5 0")
    qa.wait("one frame", lambda s: len(s.get("frames") or {}) == 1)
    qa.step("Back to one frame", expect=[
        ("its task as it was", lambda s: (s.get("task") or {}).get("name") == first)])


@journey("A draft from an Org heading")
def org(qa, repo):
    plans = qa.work / "plans.org"
    plans.write_text("* Add a search command\nSearch notes by word, ignoring case.\n")
    qa.keys("C-x C-f")
    qa.type(str(plans) + "\r")
    qa.wait("plans.org", lambda s: s["selected"] == "plans.org")
    qa.keys("M-<")
    qa.keys("C-c r c")
    qa.wait("the draft", lambda s: (qa.window(s, "roost-compose-mode") or {}).get("selected"))
    qa.step("The heading as the prompt", expect=[
        ("the heading", lambda s: "Add a search command" in qa.window(s, "roost-compose-mode")["text"]),
        ("and its notes", lambda s: "ignoring case" in qa.window(s, "roost-compose-mode")["text"])])
    before = {t["name"] for t in qa.screen()["tasks"]}
    qa.keys("C-c C-c")
    screen = qa.wait("the task", lambda s: {t["name"] for t in s["tasks"]} - before)
    name = next(t["name"] for t in screen["tasks"] if t["name"] not in before)
    qa.step("The heading knows its task", expect=[
        ("it is named for the heading", lambda s: name.startswith("add-search")),
        ("the heading has its ROOST_TASK",
         lambda s: qa.emacs.eval('(with-current-buffer "plans.org" (org-entry-get (point-min) "ROOST_TASK"))')
         not in ("nil", ""))])


@journey("A tab per task")
def tabs(qa, repo):
    """With tab-bar-mode, each task has a tab of its own, which a task of the
    same name leaves alone, and which goes with its task."""
    qa.emacs.eval("(progn (switch-to-buffer \"*scratch*\") (setq roost-workspace 'tab-bar) (tab-bar-mode 1))")
    try:
        first = start_task(qa, "Draw a tab")
        qa.step("A task in its own tab", expect=[
            ("the tab has its name", lambda s: s["workspace"] == "local/" + first),
            ("its terminal there", lambda s: (s.get("task") or {}).get("name") == first and selected_terminal(s)),
            ("its panel beside it", lambda s: panel_text(qa, s).startswith(first))])
        elder = qa.task(qa.screen(), first)["key"]
        qa.keys("C-c r c")
        qa.type("Draw a tab")
        qa.keys("C-c C-c")
        screen = qa.wait("a second task named " + first,
                         lambda s: len([t for t in s["tasks"] if t["name"] == first]) == 2)
        twin = next(t["key"] for t in screen["tasks"] if t["name"] == first and t["key"] != elder)
        qa.wait("its terminal", lambda s: (s.get("task") or {}).get("key") == twin and selected_terminal(s))
        qa.step("A second task of the same name", expect=[
            ("its tab has its ID too",
             lambda s: s["workspace"] == "local/%s:%s" % (first, twin.split("/")[1][:6])),
            ("the first's tab keeps its name", lambda s: "local/" + first in s["workspaces"])])
        qa.keys("C-x t RET")
        qa.type("local/%s\r" % first)
        qa.step("Back in the first's tab", expect=[
            ("it is the first task's", lambda s: (s.get("task") or {}).get("key") == elder),
            ("its panel beside it", lambda s: panel_text(qa, s).startswith(first)),
            ("no tab was added", lambda s: len(s["workspaces"]) == 3)])
        qa.keys("C-c r x")
        qa.wait("the question", lambda s: s["prompt"])
        qa.type("y")
        qa.wait("the task to go", lambda s: not any(t["key"] == elder for t in s["tasks"]), timeout=30)
        qa.step("Retired, with its tab", expect=[
            ("its tab is gone", lambda s: "local/" + first not in s["workspaces"]),
            ("the other's is still there", lambda s: len(s["workspaces"]) == 2)])
    finally:
        qa.emacs.eval("(progn (tab-bar-close-other-tabs) (tab-bar-mode -1) (setq roost-workspace nil))")
        qa.settle()


@journey("A shell beside the agent")
def shell(qa, repo):
    """t opens a shell in the task's worktree beside its agent, and the view
    is the agent's alone again once the shell exits."""
    name = start_task(qa, "Leave room for a shell")
    screen = open_task(qa, name)
    own = screen["task"]["terminal"]
    qa.keys("C-c r t")
    qa.wait("the shell", lambda s: len(terminals(s, own)) == 2)
    # At once, as you would: the shell has to be where your typing goes.
    qa.type("echo SHELL_IN_$(basename $PWD)\r")
    qa.wait("its output", lambda s: any("SHELL_IN_%s-" % name in w["text"] or "PROMPT echo" in w["text"]
                                        for w in terminals(s, own)))
    qa.step("The shell beside the agent", expect=[
        ("in the task's worktree", lambda s: any("SHELL_IN_%s-" % name in w["text"] for w in terminals(s, own))),
        ("nothing typed for it reached the agent",
         lambda s: not any("PROMPT echo" in w["text"] for w in terminals(s, own))),
        ("the agent still in view", lambda s: any("PROMPT Leave room" in w["text"] for w in terminals(s, own)))])
    other = start_task(qa, "Step away from the shell")
    open_task(qa, name)
    qa.wait("both panes again", lambda s: len(terminals(s, own)) == 2)
    qa.step("Back to it, the shell still open", expect=[
        ("the agent's pane as tmux has it, from its first row",
         lambda s: any(w["text"].startswith("FAKE_CLAUDE_READY") for w in terminals(s, own)))])
    to_shell(qa)
    qa.type("exit\r")
    qa.wait("the shell to go", lambda s: len(terminals(s, own)) == 1 and not s["prompt"])
    qa.step("The agent alone again", expect=[
        ("its tabs back", lambda s: (selected_terminal(s) or {}).get("tabs")),
        ("its panel beside it", lambda s: panel_text(qa, s).startswith(name))])


@journey("Forget a task")
def forget(qa, repo):
    """X drops a task from Roost and stops its agent, leaving its worktree and branch."""
    name = start_task(qa, "Forget about me")
    task = open_task(qa, name)["task"]
    branch = qa.git(repo, "branch", "--list", "--format=%(refname:short)", "roost/%s-*" % name)
    worktree = qa.emacs.json("(json-encode (roost--field (roost--frame-task) 'worktree))")
    qa.keys("C-c r X")
    qa.wait("the question", lambda s: s["prompt"])
    qa.step("Forgetting asks first", expect=[("it names the task", lambda s: name in (s["prompt"] or ""))])
    qa.type("y")
    qa.wait("the task to go", lambda s: qa.task(s, name) is None)
    qa.step("Forgotten", expect=[
        ("the echo area names what it left",
         lambda s: all(part in (s["echo"] or "") for part in ("Forgot " + name, worktree, branch))),
        ("its branch is still there", lambda s: branch and qa.git(repo, "branch", "--list", branch)),
        ("and its worktree", lambda s: worktree in qa.git(repo, "worktree", "list", "--porcelain")),
        ("its agent's session is gone",
         lambda s: task["terminal"].split("/")[-1] not in qa.tmux("list-sessions", "-F", "#S"))])


@journey("Fork a task's commits")
def fork(qa, repo):
    """C-u c starts a task from another's HEAD, its commits included."""
    name = new_task(qa, "ask sh -c \"printf 'x\\n' > FORKED.md && git add FORKED.md && git commit -qm 'Fork me'\"")
    answer_yes(qa, name)
    qa.wait("its commit", lambda s: "Committed" in panel_text(qa, s))
    qa.keys("C-c r C-u c")
    qa.wait("the draft", lambda s: (qa.window(s, "roost-compose-mode") or {}).get("selected"))
    qa.step("A draft from its HEAD", expect=[
        ("it says the fork includes its commits",
         lambda s: "includes its commits" in qa.window(s, "roost-compose-mode")["text"])])
    before = {t["key"] for t in qa.screen()["tasks"]}
    qa.type("Carry on from there")
    qa.keys("C-c C-c")
    screen = qa.wait("the fork", lambda s: {t["key"] for t in s["tasks"]} - before)
    fork_name = next(t["name"] for t in screen["tasks"] if t["key"] not in before)
    qa.status(fork_name, "ready", "idle")
    qa.step("The fork has the commit", expect=[
        ("its branch has it",
         lambda s: "Fork me" in qa.git(repo, "log", "--format=%s", "-3",
                                       qa.git(repo, "branch", "--list", "--format=%(refname:short)",
                                              "roost/%s-*" % fork_name)))])


@journey("An agent that exits")
def exits(qa, repo):
    """An agent that exits on its own shows as such, and s resumes its conversation."""
    name = start_task(qa, "Leave when asked")
    open_task(qa, name)
    qa.type("exit\r")
    qa.status(name, "exited")
    qa.wait("its panel to say so", lambda s: "resumes its conversation" in panel_text(qa, s), timeout=10)
    qa.step("Exited", expect=[
        ("the panel says s resumes it", lambda s: "resumes its conversation" in panel_text(qa, s)),
        ("its last output still shows", lambda s: any("PROMPT Leave when asked" in w["text"] for w in terminals(s)))])
    qa.click_text(name, "roost-task-info-mode")
    qa.keys("s")
    qa.status(name, "ready", "idle")
    qa.step("Resumed", expect=[
        ("its terminal", lambda s: (s.get("task") or {}).get("name") == name and selected_terminal(s))])


@journey("A host Roost can't reach")
def unreachable(qa, repo):
    """A host that doesn't answer is named, in the sidebar and the dashboard, within their windows."""
    qa.emacs.eval("(progn (setq roost-hosts '(nil \"qa-unreachable.invalid\")) (roost-refresh) t)")
    try:
        qa.wait("the host to be named", lambda s: "unreachab" in
                (qa.window(s, "roost-sidebar-list-mode") or {}).get("text", ""), timeout=30)
        qa.step("The sidebar names it")
        qa.keys("C-c r S")
        qa.wait("the dashboard", lambda s: (qa.window(s, "roost-dashboard-mode") or {}).get("selected"))
        qa.step("So does the dashboard", expect=[
            ("with why", lambda s: "is unreachable" in qa.window(s, "roost-dashboard-mode")["text"])])
    finally:
        qa.emacs.eval("(progn (setq roost-hosts '(nil)) (clrhash roost--errors) (roost--redraw) t)")


JOURNEYS = [sweep, answer, fold, resize, merge, review, panes, shell,
            dashboard, stop_resume, retire, send, update, restart, search, frames, org, tabs,
            forget, fork, exits, unreachable]


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
                # A question or menu the last journey left open goes first.
                for _ in range(3):
                    if not qa.screen()["prompt"] and qa.emacs.eval("(and transient--prefix t)") != "t":
                        break
                    qa.keys("C-g")
                qa.emacs.eval("(qa-fresh-start)")
                qa.settle()
                chosen_journey(qa, repo)
            except Stuck as stuck:
                try:
                    screen = qa.screen()
                except Stuck:
                    screen = dict(windows=[])
                qa.steps.append(dict(journey=qa.journey, title="Stopped", problems=[str(stuck)],
                                     shot=None, screen=screen))
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
