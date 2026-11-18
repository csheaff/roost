"""What an agent leaves running, which outlives its pane, as a dev server
started with nohup does, beside retiring and discarding its task: none of
it loses a file Roost didn't count. Real Git, the fake Claude in a tmux
socket of its own, and the crash harness's log of the helper's commands,
which says when to write."""
import importlib.util
import json
import re
from pathlib import Path
import shlex
import subprocess
import sys
import time
import unittest
from unittest.mock import patch

from crash_harness import Box, HELPER

spec = importlib.util.spec_from_file_location("roost_remote", HELPER)
roost = importlib.util.module_from_spec(spec)
spec.loader.exec_module(roost)

# Once the helper has closed the agent's window, at the next command that
# reads the submodules (WHEN), write a file into the worktree: after the
# helper checked the worktree is clean, and before --force removes it.
WRITER = r"""
import os, sys, time
log, when, worktree, written = sys.argv[1:5]
deadline = time.time() + 60
while time.time() < deadline:
    try:
        lines = open(log).read().splitlines()
    except OSError:
        lines = []
    stopped = next((n for n, line in enumerate(lines) if "kill-window" in line or "kill-pane" in line), None)
    if stopped is not None and any(when in line for line in lines[stopped:]):
        break
    time.sleep(0.0005)
else:
    sys.exit(1)
path = os.path.join(worktree, "server.log")
with open(path, "w") as out:
    out.write("results\n")
with open(written, "a") as out:
    out.write(path + "\n")
"""

# Runs until killed.
FOREVER = "import time\nwhile True: time.sleep(1)\n"

# Runs the rest of its arguments in a session of their own, as Claude Code
# runs each command it is asked to: macOS has no setsid(1). A shell's job
# leads its process group, which can't start a session: its child does.
OWN_SESSION = ("import os, sys; os.getpid() == os.getpgrp() and os.fork() and os._exit(0); "
               "os.setsid(); os.execv(sys.argv[1], sys.argv[1:])")


class LeftRunning(unittest.TestCase):
    def setUp(self):
        self.box = Box()
        self.addCleanup(self.box.close)
        self.written = self.box.root / "written"
        self.script = self.box.root / "writer.py"
        self.script.write_text(WRITER)
        self.addCleanup(self.box.run, "pkill", "-f", str(self.box.root), check=False)

    def with_submodule(self):
        box = self.box
        library = box.root / "library"
        box.git("init", "-q", "-b", "main", str(library))
        (library / "lib").write_text("lib\n")
        box.git("add", ".", cwd=library)
        box.git("commit", "-qm", "Library", cwd=library)
        box.git("config", "--global", "protocol.file.allow", "always")
        box.git("submodule", "add", "-q", str(library), "library")
        box.git("commit", "-qm", "Add the library")
        task = box.create()
        # Checked out, as an agent does to build: retire removes it with --force.
        box.git("submodule", "update", "--init", "-q", cwd=task["worktree"])
        return task

    def agent_runs(self, task, argv, own_session=True, daemon=False):
        """Have TASK's agent start ARGV with nohup, in the background, as
        Claude Code starts a dev server, from a shell in a session of its
        own with OWN_SESSION, as Claude Code runs each command, and finish
        its turn. A DAEMON leads a session of its own instead."""
        box = self.box
        command = "nohup %s >/dev/null 2>&1 &" % shlex.join(map(str, argv))
        if daemon:
            command = "%s >/dev/null 2>&1 &" % shlex.join(map(str, [sys.executable, "-c", OWN_SESSION, *argv]))
        elif own_session:
            command = shlex.join([sys.executable, "-c", OWN_SESSION, "/bin/sh", "-c", command])
        pane = box.record(task["id"])["paneId"]
        box.tmux("send-keys", "-t", pane, "-l", "ask " + command)
        box.tmux("send-keys", "-t", pane, "Enter")
        box.wait_for(task, "permission")
        box.tmux("send-keys", "-t", pane, "-l", "yes")
        box.tmux("send-keys", "-t", pane, "Enter")
        box.wait_for(task, "ready", event="Stop")
        self.assertTrue(self.running(argv[-1]), "the agent started nothing")

    def running(self, mark, last=False):
        """What runs with MARK in its command line, LAST in it with LAST."""
        return self.box.run("pgrep", "-f", re.escape(str(mark)) + ("$" if last else ""), check=False)

    def writer(self, task):
        return [sys.executable, self.script, self.box.inject / "log", "ls-files --stage", task["worktree"],
                self.written]

    def lost(self, reply):
        """What the writer wrote that REPLY, a success, took."""
        paths = self.written.read_text().splitlines() if self.written.exists() else []
        return [path for path in paths if reply["ok"] and not Path(path).exists()]

    def test_stop_ends_what_the_agent_left_running(self):
        box = self.box
        task = box.create()
        beside, apart = box.root / "beside.py", box.root / "apart.py"
        for script in (beside, apart):
            script.write_text(FOREVER)
        # In the pane's session, and in one of its own.
        self.agent_runs(task, [sys.executable, beside], own_session=False)
        self.agent_runs(task, [sys.executable, apart])
        self.assertTrue(box.helper("stop", id=task["id"])["ok"])
        self.assertFalse(self.running(beside), "still running after stop")
        self.assertFalse(self.running(apart), "still running after stop")

    def test_stop_ends_the_command_the_agent_is_running(self):
        """In the session Claude Code starts for it, which leads to the
        agent's pane only until the pane closes."""
        box = self.box
        task = box.create()
        command = box.root / "command.py"
        command.write_text(FOREVER)
        box.tmux("send-keys", "-t", box.record(task["id"])["paneId"], "-l",
                 "ask " + shlex.join([sys.executable, "-c", OWN_SESSION, sys.executable, str(command)]))
        box.tmux("send-keys", "-t", box.record(task["id"])["paneId"], "Enter")
        box.wait_for(task, "permission")
        box.tmux("send-keys", "-t", box.record(task["id"])["paneId"], "-l", "yes")
        box.tmux("send-keys", "-t", box.record(task["id"])["paneId"], "Enter")
        deadline = time.monotonic() + 10
        while not self.running(command) and time.monotonic() < deadline:
            time.sleep(0.05)
        self.assertTrue(self.running(command), "the agent started nothing")
        self.assertTrue(box.helper("stop", id=task["id"])["ok"])
        self.assertFalse(self.running(command), "still running after stop")

    def test_stop_spares_a_process_that_names_the_task_only_in_its_arguments(self):
        """As one that searches for it does: only the environment counts."""
        box = self.box
        task = box.create()
        other = box.root / "other.py"
        other.write_text(FOREVER)
        # In a session whose first process has ended, as a task's server is.
        command = shlex.join([sys.executable, str(other), "ROOST_TASK_ID=" + task["id"]])
        subprocess.run([sys.executable, "-c", OWN_SESSION, "/bin/sh", "-c", "nohup %s >/dev/null 2>&1 &" % command],
                       check=True)
        deadline = time.monotonic() + 10
        while not self.running(other) and time.monotonic() < deadline:
            time.sleep(0.05)
        self.assertTrue(box.helper("stop", id=task["id"])["ok"])
        self.assertTrue(self.running(other), "ended a process that only named the task")

    def test_stop_ends_what_you_left_running_from_the_task_shell(self):
        box = self.box
        task = box.create()
        reply = box.helper("shell", id=task["id"])
        self.assertTrue(reply["ok"], reply)
        served = box.root / "served.py"
        served.write_text(FOREVER)
        command = shlex.join([sys.executable, "-c", OWN_SESSION, "/bin/sh", "-c",
                              "nohup %s >/dev/null 2>&1 &" % shlex.join([sys.executable, str(served)])])
        box.tmux("send-keys", "-t", reply["result"]["shellPaneId"], "-l", command)
        box.tmux("send-keys", "-t", reply["result"]["shellPaneId"], "Enter")
        deadline = time.monotonic() + 10
        # Not the command that starts it, which names it too.
        while not self.running(served, last=True) and time.monotonic() < deadline:
            time.sleep(0.05)
        self.assertTrue(self.running(served, last=True), "the shell started nothing")
        self.assertTrue(box.helper("stop", id=task["id"])["ok"])
        self.assertFalse(self.running(served), "still running after stop")

    def test_stop_ends_what_an_earlier_stop_could_not(self):
        box = self.box
        task = box.create()
        later = subprocess.Popen([sys.executable, "-c", FOREVER], start_new_session=True)
        self.addCleanup(later.kill)
        time.sleep(0.2)
        record = box.record(task["id"])
        record["leftRunning"] = sorted([pid, start] for pid, start in roost.process_starts({later.pid}).items())
        (box.state / "tasks" / (task["id"] + ".json")).write_text(json.dumps(record))
        self.assertTrue(box.helper("stop", id=task["id"])["ok"])
        self.assertEqual(later.wait(timeout=10), -15)
        self.assertNotIn("leftRunning", box.record(task["id"]))

    def test_stop_leaves_a_daemon_the_agent_started(self):
        """A server of a build tool's, or an ssh connection, that the agent
        started and other tasks share, leads a session of its own."""
        box = self.box
        task = box.create()
        daemon = box.root / "daemon.py"
        daemon.write_text(FOREVER)
        self.agent_runs(task, [sys.executable, daemon], daemon=True)
        self.assertTrue(box.helper("stop", id=task["id"])["ok"])
        self.assertTrue(self.running(daemon), "a daemon was ended")

    def test_retire_keeps_a_file_what_the_agent_left_running_writes_as_the_worktree_goes(self):
        box = self.box
        task = self.with_submodule()
        self.agent_runs(task, self.writer(task))
        box.arm("before", 10 ** 9)
        reply = box.helper("retire", id=task["id"])
        box.disarm()
        self.assertFalse(self.running(self.script))
        self.assertEqual(self.lost(reply), [], "retired, and deleted a file written after the check")

    def test_retire_checks_the_worktree_again_after_its_submodules(self):
        """Something no session of the task's started, which `stop` leaves
        alone, writes as the submodules are read: the last check sees it."""
        box = self.box
        task = self.with_submodule()
        writer = subprocess.Popen(self.writer(task), start_new_session=True)
        self.addCleanup(writer.kill)
        box.arm("before", 10 ** 9)
        reply = box.helper("retire", id=task["id"])
        box.disarm()
        self.assertEqual(writer.wait(timeout=60), 0, "the writer never wrote")
        self.assertEqual(self.lost(reply), [], "retired, and deleted a file written after the check")
        self.assertFalse(reply["ok"], reply)
        self.assertIn("Uncommitted or untracked files remain", reply["error"])

    def test_discard_takes_no_file_it_did_not_count(self):
        """Something writes as soon as discard has stopped the agent, after
        it compared its count with what you were told: it counts again."""
        box = self.box
        task = box.create()
        told = box.helper("discard", id=task["id"], dryRun=True)["result"]["discard"]
        self.assertEqual(told["changes"], 0, told)
        writer = subprocess.Popen([sys.executable, self.script, box.inject / "log", "", task["worktree"],
                                   self.written], start_new_session=True)
        self.addCleanup(writer.kill)
        box.arm("before", 10 ** 9)
        reply = box.helper("discard", id=task["id"], told=told, expect=told["commit"])
        box.disarm()
        self.assertEqual(writer.wait(timeout=60), 0, "the writer never wrote")
        self.assertEqual(self.lost(reply), [], "discarded a file it never counted")
        self.assertIn("more than you were told", reply["error"])


class Refused(unittest.TestCase):
    """What won't end, as another user's process, keeps the worktree."""

    def test_what_does_not_end_is_said_and_kept(self):
        process = subprocess.Popen([sys.executable, "-c", FOREVER], start_new_session=True)
        self.addCleanup(process.kill)
        with patch.object(roost.os, "kill"), patch.object(roost, "LEFT_RUNNING_SECONDS", 0.1):
            left = roost.end_left_running("ab" * 8, {process.pid})
        self.assertEqual([pid for pid, _ in left], [process.pid])
        # Known by when it started: one with that PID started since is not it.
        self.assertEqual(roost.end_left_running("ab" * 8, set(), [[process.pid, "Thu Jan  1 00:00:00 1970"]]), [])
        self.assertIsNone(process.poll())
        self.assertEqual(roost.end_left_running("ab" * 8, set(), left), [])
        self.assertEqual(process.wait(timeout=10), -15)

    def test_stop_refuses_and_keeps_what_did_not_end(self):
        saved = []
        store = type("Store", (), {"save": lambda self, task: saved.append(dict(task))})()
        task = dict(id="ab" * 8, socket="none", status="ready", paneId="%1", windowId="@1")
        with patch.object(roost, "pane_inventory", return_value={}), \
                patch.object(roost, "close_panes"), \
                patch.object(roost, "end_left_running", return_value=[[4242, "then"]]):
            with self.assertRaisesRegex(roost.RoostError, "would not end: process 4242"):
                roost.stop(store, task)
        self.assertEqual(saved[-1]["leftRunning"], [[4242, "then"]])
        self.assertEqual(saved[-1]["status"], "stopped")


if __name__ == "__main__":
    unittest.main()
