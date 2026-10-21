"""Real Git/tmux lifecycle tests. Isolated sockets; no API calls or user config."""
import base64
import concurrent.futures
import datetime
import fcntl
import http.server
import importlib.util
import hashlib
import json
import os
import re
import select
import shlex
import shutil
import signal
import stat
from pathlib import Path
import subprocess
import sys
import tempfile
import threading
import time
import unittest
import uuid
from unittest.mock import patch

SOURCE = Path(__file__).resolve().parents[1] / "scripts/roost_remote.py"
spec = importlib.util.spec_from_file_location("roost_remote", SOURCE)
roost = importlib.util.module_from_spec(spec)
spec.loader.exec_module(roost)
FAKE = Path(__file__).with_name("fake_claude.py")
FAKE_AGENT = Path(__file__).with_name("fake_agent.py")


def claude_folder(directory):
    """Claude Code's folder name for a short DIRECTORY, by its own rule."""
    return re.sub(r"[^a-zA-Z0-9]", "-", os.path.realpath(directory))


def tmux_socket_path(name):
    """Where tmux keeps socket NAME. tmux leaves the file after its server exits."""
    return Path(os.environ.get("TMUX_TMPDIR") or "/tmp") / ("tmux-%d" % os.getuid()) / name


class Lifecycle(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="roost test ' $ ")
        self.root = Path(self.temp.name)
        self.repo = self.root / "repo with spaces"
        self.repo.mkdir()
        self.state = self.root / "state"
        self.socket = "roost-test-" + uuid.uuid4().hex[:12]
        self.git("init", "-b", "main")
        self.git("config", "user.name", "Roost Test")
        self.git("config", "user.email", "roost@example.invalid")
        self.git("config", "commit.gpgsign", "false")
        (self.repo / "hello").write_text("base\n")
        self.git("add", ".")
        self.git("commit", "-m", "base")

    def tearDown(self):
        roost.tmux(self.socket, "kill-server", check=False)
        tmux_socket_path(self.socket).unlink(missing_ok=True)
        try:
            self.temp.cleanup()
        except OSError:
            # A hook the agent ran as tmux killed it may still be noting
            # its event, as in the history.
            time.sleep(0.5)
            shutil.rmtree(self.temp.name, ignore_errors=True)

    def git(self, *args, cwd=None):
        return roost.git(cwd or self.repo, *args).stdout.strip()

    def request(self, action, **args):
        return roost.rpc(dict(root=str(self.state), action=action, **args))

    def create(self, **args):
        reply = self.request("create", directory=args.pop("directory", str(self.repo)), name=args.pop("name", "task"),
                             socket=self.socket, command=args.pop("command", [sys.executable, str(FAKE)]), **args)
        self.assertTrue(reply["ok"], reply)
        task = reply["result"]
        self.wait(task, "ready")
        return task

    def wait_for_pane_exit(self, task):
        """The runner records a final status just before its pane's process
        exits, so act on the pane only once tmux shows it dead or gone."""
        deadline = time.monotonic() + 8
        while time.monotonic() < deadline:
            pane = (roost.pane_inventory(self.socket) or {}).get(task["paneId"])
            if pane is None or pane["dead"]:
                return
            time.sleep(0.05)
        self.fail("the agent's pane is still running")

    def wait(self, task, status, event=None):
        deadline = time.monotonic() + 8
        while time.monotonic() < deadline:
            record = roost.Store(str(self.state)).read(task["id"])
            if record["status"] == status and (event is None or record.get("lastEvent") == event):
                return record
            time.sleep(.04)
        self.fail("Expected %s; got %s" % (status, record))

    def test_create_hooks_stop_resume_and_retire(self):
        task = self.create(name="fix parser ' $()")
        record = self.wait(task, "ready")
        self.assertTrue(record["claudeSession"])
        self.assertEqual(record["baseCommit"], self.git("rev-parse", "HEAD"))
        self.assertNotEqual(task["worktree"], str(self.repo))
        self.assertTrue(self.request("inspect", id=task["id"])["ok"])
        self.assertTrue(self.request("stop", id=task["id"])["ok"])
        self.assertTrue(Path(task["worktree"]).exists())
        self.assertTrue(self.request("resume", id=task["id"])["ok"])
        resumed = self.wait(task, "ready")
        self.assertEqual(resumed["claudeSession"], record["claudeSession"])
        self.assertNotEqual(resumed["runId"], record["runId"])
        self.assertTrue(self.request("retire", id=task["id"])["ok"])
        self.assertFalse(Path(task["worktree"]).exists())
        self.assertEqual(self.request("list")["result"], [])

    def test_attachments_keep_their_names_and_go_with_the_task(self):
        task = self.create()
        encode = lambda data: base64.b64encode(data).decode()
        files = [dict(name="shot.png", data=encode(b"\x89PNG")),
                 dict(name="a.scrawl/summary.md", data=encode(b"look\n")),
                 dict(name="a.scrawl/frames/frame-01.png", data=encode(b"1"))]
        reply = self.request("attach", id=task["id"], files=files)
        self.assertTrue(reply["ok"], reply)
        shot, bundle = map(Path, reply["result"]["paths"])
        self.assertEqual((shot.name, shot.read_bytes()), ("shot.png", b"\x89PNG"))
        self.assertEqual((bundle / "frames" / "frame-01.png").read_bytes(), b"1")
        self.assertEqual(stat.S_IMODE(shot.stat().st_mode), 0o600)
        # A name as long as names go keeps to that with its number, cut
        # between characters.
        long = [dict(name="é" * 123 + "abcde.png", data=encode(b"x"))]
        first, second = (Path(self.request("attach", id=task["id"], files=long)["result"]["paths"][0])
                         for _ in range(2))
        self.assertEqual(len(first.name.encode()), 255)
        self.assertTrue(second.name.endswith("-2.png") and len(second.name.encode()) <= 255, second.name)
        self.assertEqual(second.read_bytes(), b"x")
        # A name taken already gets a number, as a second clipboard image does.
        again = self.request("attach", id=task["id"], files=files[:2])["result"]["paths"]
        self.assertEqual([Path(path).name for path in again], ["shot-2.png", "a-2.scrawl"])
        self.assertEqual(Path(again[0]).parent, shot.parent)
        for name in ("../out", "/etc/out", "", None):
            self.assertFalse(self.request("attach", id=task["id"], files=[dict(name=name, data="")])["ok"])
        self.assertFalse(self.request("attach", id=task["id"], files=[dict(name="x", data="not base64!")])["ok"])
        self.assertFalse(self.request("attach", id=task["id"], files=[])["ok"])
        self.assertFalse((self.state / "out").exists())
        # A name both a file and a folder, and data that isn't base64 after
        # names were taken: nothing is left of either.
        before = sorted(path.name for path in shot.parent.iterdir())
        self.assertFalse(self.request("attach", id=task["id"],
                                      files=[dict(name="x", data=""), dict(name="x/y", data="")])["ok"])
        self.assertFalse(self.request("attach", id=task["id"],
                                      files=[dict(name="new.png", data="AA=="),
                                             dict(name="bad.png", data="not base64!")])["ok"])
        self.assertEqual(sorted(path.name for path in shot.parent.iterdir()), before)
        # Nor of the names taken before one too long to take.
        reply = self.request("attach", id=task["id"], files=[dict(name="ok.png", data="AA=="),
                                                             dict(name="x" * 300 + ".png", data="AA==")])
        self.assertFalse(reply["ok"])
        self.assertIn("Can't attach", reply["error"])
        self.assertEqual(sorted(path.name for path in shot.parent.iterdir()), before)
        # Hooks aren't held while a large attachment is written.
        decode = base64.b64decode
        free = []

        def decode_and_try_the_lock(*args, **kwargs):
            with (self.state / "registry.lock").open("a") as lock:
                try:
                    fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
                    fcntl.flock(lock, fcntl.LOCK_UN)
                    free.append(True)
                except BlockingIOError:
                    free.append(False)
            # But the task can't go meanwhile, leaving what is written after.
            self.request("stop", id=task["id"])
            free.append(self.request("forget", id=task["id"])["ok"])
            return decode(*args, **kwargs)
        with patch.object(roost.base64, "b64decode", decode_and_try_the_lock):
            reply = self.request("attach", id=task["id"], files=files[:1])
        self.assertTrue(reply["ok"], reply)
        self.assertEqual(free, [True, False])
        self.assertTrue(Path(reply["result"]["paths"][0]).exists())
        self.request("stop", id=task["id"])
        self.wait_for_pane_exit(task)
        self.assertTrue(self.request("forget", id=task["id"])["ok"])
        self.assertFalse(shot.parent.exists())

    def test_permissions_and_stop_are_attention_not_completion(self):
        task = self.create()
        self.assertTrue(self.request("send", id=task["id"], text="permission")["ok"])
        self.wait(task, "permission")
        self.assertFalse(self.request("send", id=task["id"], text="yes")["ok"])
        self.assertFalse(self.request("retire", id=task["id"])["ok"])
        # Declining in the terminal reports no event; the user can confirm a send.
        self.assertTrue(self.request("send", id=task["id"], text="do this instead", force=True)["ok"])
        self.wait(task, "ready")
        store = roost.Store(str(self.state))
        roost.update_hook(store, task["id"], dict(hook_event_name="Stop"))
        self.assertEqual(store.read(task["id"])["status"], "ready")
        roost.update_hook(store, task["id"], dict(hook_event_name="Stop", background_tasks=[{}]))
        self.assertEqual(store.read(task["id"])["status"], "background")
        roost.update_hook(store, task["id"], dict(hook_event_name="Notification",
                                                  notification_type="worker_permission_prompt"))
        self.assertEqual(store.read(task["id"])["status"], "permission")
        # A background agent of this session blocked on you; its words say what it needs.
        roost.update_hook(store, task["id"], dict(hook_event_name="Stop"))
        roost.update_hook(store, task["id"], dict(hook_event_name="Notification", notification_type="agent_needs_input",
                                                  message="reviewer needs your input: which branch?"))
        record = store.read(task["id"])
        self.assertEqual((record["status"], record["request"]), ("permission", "reviewer needs your input: which branch?"))
        # The notification that follows a request of its own keeps the request.
        roost.update_hook(store, task["id"], dict(hook_event_name="PermissionRequest", tool_name="Bash",
                                                  tool_input=dict(command="make")))
        roost.update_hook(store, task["id"], dict(hook_event_name="Notification", notification_type="permission_prompt",
                                                  message="Claude needs your permission to use Bash"))
        self.assertEqual(store.read(task["id"])["request"], "Asks to run make")

    def test_launching_prunes_old_helpers_nothing_calls(self):
        first = self.create()
        week_ago = time.time() - 8 * 24 * 3600
        helpers = {name: self.state / ("remote-%s.py" % name) for name in ("old", "recent", "used")}
        for name, path in helpers.items():
            path.write_text("# an older helper\\n")
            if name != "recent":
                os.utime(path, (week_ago, week_ago))
        store = roost.Store(str(self.state))
        # A running agent's hooks call the helper that launched it.
        store.save(dict(store.read(first["id"]), helper=str(helpers["used"])))
        self.assertEqual(store.read(self.create(name="second")["id"])["helper"],
                         str(Path(roost.__file__).resolve()))
        self.assertFalse(helpers["old"].exists())
        self.assertTrue(helpers["recent"].exists())
        self.assertTrue(helpers["used"].exists())
        # Tasks from before helpers were recorded keep every copy.
        helpers["old"].write_text("# an older helper\\n")
        os.utime(helpers["old"], (week_ago, week_ago))
        record = store.read(first["id"])
        record.pop("helper")
        store.save(record)
        self.create(name="third")
        self.assertTrue(helpers["old"].exists())

    def test_agents_start_with_extended_keys_on(self):
        # Claude Code asks for modified keys as it starts; without
        # extended-keys tmux sends its Shift+Return as Return.
        self.create()
        self.assertEqual(roost.tmux(self.socket, "show-options", "-sv", "extended-keys").stdout.strip(), "on")
        roost.tmux(self.socket, "set-option", "-s", "extended-keys", "always")
        self.create(name="second")
        self.assertEqual(roost.tmux(self.socket, "show-options", "-sv", "extended-keys").stdout.strip(), "always")

    def test_ctrl_c_in_the_pane_is_for_the_agent_not_the_runner(self):
        # An agent that leaves the terminal in cooked mode gets C-c as SIGINT,
        # sent to the pane's whole foreground group, runner included.
        task = self.create()
        roost.tmux(self.socket, "send-keys", "-t", task["paneId"], "C-c")
        self.wait(task, "failed")
        record = roost.Store(str(self.state)).read(task["id"])
        self.assertEqual(record["exitCode"], -signal.SIGINT)
        output = roost.tmux(self.socket, "capture-pane", "-p", "-S", "-", "-t", task["paneId"]).stdout
        self.assertNotIn("in runner", output)

    def wait_for(self, task, check):
        deadline = time.monotonic() + 8
        while time.monotonic() < deadline:
            record = roost.Store(str(self.state)).read(task["id"])
            if check(record):
                return record
            time.sleep(.04)
        self.fail("Not as expected: %s" % record)

    def test_an_agent_that_reports_its_status_needs_no_guessing(self):
        # Claude Code says whether it works or waits on you to a terminal that
        # answers its probe. tmux doesn't, so the runner relays one that does.
        task = self.create(programStatus=True)
        self.wait_for(task, lambda record: record.get("programStatusRun") == record["runId"])
        # Esc runs no hook, and the transcript need not be read.
        with patch.object(roost, "was_interrupted", side_effect=AssertionError("guessed")):
            self.assertTrue(self.request("send", id=task["id"], text="interrupt")["ok"])
            self.wait(task, "ready", "Interrupt")
            self.request("list")
        # An approval shows before the command ends, and no process is looked for.
        self.assertTrue(self.request("send", id=task["id"], text="ask sleep 3")["ok"])
        record = self.wait(task, "permission")
        self.assertEqual(record["request"], "Asks to run sleep 3")
        with patch.object(roost, "processes", side_effect=AssertionError("guessed")):
            roost.tmux(self.socket, "send-keys", "-t", task["paneId"], "yes", "Enter")
            record = self.wait(task, "running", "Approved")
            self.request("list")
        self.assertNotIn("request", record)
        self.assertEqual(record["activity"], "Running sleep 3")
        record = self.wait(task, "ready", "Stop")
        self.assertNotIn("activity", record)
        # Declining a request runs no hook either.
        self.assertTrue(self.request("send", id=task["id"], text="ask make")["ok"])
        self.wait(task, "permission")
        roost.tmux(self.socket, "send-keys", "-t", task["paneId"], "decline", "Enter")
        self.wait(task, "ready", "Interrupt")
        output = roost.tmux(self.socket, "capture-pane", "-p", "-t", task["paneId"]).stdout
        self.assertIn("FAKE_CLAUDE_READY", output)

    def test_the_probe_is_answered_behind_output_still_going_to_tmux(self):
        task = self.create(programStatus=True, command=[sys.executable, str(FAKE), "--noise"])
        self.wait_for(task, lambda record: record.get("programStatusRun") == record["runId"])

    def test_a_relayed_agent_follows_its_panes_size_and_gets_c_c(self):
        task = self.create(programStatus=True)
        roost.tmux(self.socket, "resize-window", "-t", task["windowId"], "-x", "91", "-y", "23")
        self.assertTrue(self.request("send", id=task["id"], text="size")["ok"])
        self.wait(task, "ready", "Stop")
        output = roost.tmux(self.socket, "capture-pane", "-p", "-t", task["paneId"]).stdout
        self.assertIn("SIZE 91x23", output)
        roost.tmux(self.socket, "send-keys", "-t", task["paneId"], "C-c")
        record = self.wait(task, "failed")
        self.assertEqual(record["exitCode"], -signal.SIGINT)

    def test_resume_can_turn_the_relay_off(self):
        task = self.create(programStatus=True)
        self.assertTrue(self.request("stop", id=task["id"])["ok"])
        self.assertTrue(self.request("resume", id=task["id"], programStatus=False)["ok"])
        record = self.wait(task, "ready")
        self.assertFalse(record["programStatus"])
        self.assertTrue(self.request("send", id=task["id"], text="hello")["ok"])
        record = self.wait(task, "ready", "Stop")
        self.assertNotEqual(record.get("programStatusRun"), record["runId"])

    def test_a_turn_you_stop_leaves_the_agent_waiting_for_you(self):
        # Claude runs no hook for Esc or a declined request; its transcript
        # records the interrupt, which a listing notices.
        task = self.create()
        self.assertTrue(self.request("send", id=task["id"], text="permission")["ok"])
        self.wait(task, "permission")
        store = roost.Store(str(self.state))
        roost.update_hook(store, task["id"], dict(hook_event_name="PermissionRequest", tool_name="Bash",
                                                  tool_input=dict(command="make")))
        record = store.read(task["id"])
        home = self.root / "home"
        transcript = home / ".claude" / "projects" / claude_folder(task["worktree"]) / (record["agentSession"] + ".jsonl")
        transcript.parent.mkdir(parents=True)
        since = roost.parse_time(record["updatedAt"])
        marker = lambda seconds: json.dumps({
            "type": "user", "timestamp": (since + datetime.timedelta(seconds=seconds)).isoformat(),
            "message": {"role": "user", "content": [{"type": "text", "text": "[Request interrupted by user for tool use]"}]}})
        with patch.dict(os.environ, HOME=str(home)):
            transcript.write_text(marker(-60) + "\n")
            self.assertEqual(self.request("list")["result"][0]["status"], "permission")
            transcript.write_text(marker(1) + "\n")
            listed = self.request("list")["result"][0]
        self.assertEqual((listed["status"], listed["lastEvent"]), ("ready", "Interrupt"))
        self.assertNotIn("request", store.read(task["id"]))

    def test_an_approved_command_shows_running_before_it_ends(self):
        # Claude reports nothing between your approval and the command's end,
        # which for tests or a build can be minutes of `permission`.
        task = self.create()
        self.assertTrue(self.request("send", id=task["id"], text="ask sleep 3 && echo 'it ran'")["ok"])
        record = self.wait(task, "permission")
        self.assertEqual(record["requestCommand"], "sleep 3 && echo 'it ran'")
        self.assertEqual(self.request("list")["result"][0]["status"], "permission")
        roost.tmux(self.socket, "send-keys", "-t", task["paneId"], "yes", "Enter")
        deadline = time.monotonic() + 2.5
        while time.monotonic() < deadline:
            listed = self.request("list")["result"][0]
            if listed["status"] != "permission":
                break
            time.sleep(0.1)
        self.assertEqual((listed["status"], listed["lastEvent"]), ("running", "Approved"))
        self.assertNotIn("request", listed)
        self.assertNotIn("requestCommand", listed)
        self.wait(task, "ready")

    def test_only_the_requested_command_counts_as_approved(self):
        task = dict(requestCommand="grep -r 'TODO' src")
        shell = ("/bin/bash -c source /x/shell-snapshots/snapshot.sh && eval 'grep -r '\"'\"'TODO'\"'\"' src'"
                 " < /dev/null && pwd -P >| /tmp/claude-cwd")
        runner, agent = (10, (1, "python3 remote.py run")), (11, (10, "claude"))
        table = lambda *children: dict([runner, agent, *children])
        self.assertTrue(roost.approved_command_running(task, dict(pid=10), table((12, (11, shell)))))
        # A sandbox can run it a level further down.
        self.assertTrue(roost.approved_command_running(
            task, dict(pid=10), table((12, (11, "bwrap --ro-bind / / bash")), (13, (12, shell)))))
        # Another command, or this one run by something else, is not it.
        self.assertFalse(roost.approved_command_running(
            task, dict(pid=10), table((12, (11, "/bin/bash -c eval 'make test' < /dev/null")))))
        self.assertFalse(roost.approved_command_running(task, dict(pid=10), table((12, (5, shell)))))
        self.assertFalse(roost.approved_command_running(dict(task, requestCommand="ls"), dict(pid=10),
                                                        table((12, (11, "/bin/bash -c eval ls")))))
        self.assertTrue(roost.approved_command_running(dict(task, requestCommand="ls"), dict(pid=10),
                                                       table((12, (11, "/bin/bash -c eval 'ls' < /dev/null")))))
        self.assertFalse(roost.approved_command_running({}, dict(pid=10), table((12, (11, shell)))))
        # A long command, such as a heredoc, is recorded and matched by its start.
        store = roost.Store(str(self.state))
        created = self.create()
        heredoc = "cat > notes.md <<'EOF'\n" + "a line with 'quotes'\n" * 40 + "EOF"
        roost.update_hook(store, created["id"], dict(hook_event_name="PermissionRequest", tool_name="Bash",
                                                     tool_input=dict(command=heredoc)))
        recorded = store.read(created["id"])["requestCommand"]
        self.assertTrue(heredoc.startswith(recorded) and len(recorded) < len(heredoc))
        running = "/bin/bash -c eval '" + heredoc.replace("'", "'\"'\"'") + "' < /dev/null"
        self.assertTrue(roost.approved_command_running(dict(requestCommand=recorded), dict(pid=10),
                                                       table((12, (11, running)))))
        self.assertFalse(roost.approved_command_running(task, dict(pid=None), table((12, (11, shell)))))

    def test_claudes_idle_reminder_is_no_news_for_an_agent_already_waiting(self):
        # A minute after each turn Claude sends idle_prompt; taken as a new
        # event, it made an agent you had seen count as waiting again.
        task = self.create()
        store = roost.Store(str(self.state))
        hook = lambda **payload: roost.update_hook(store, task["id"], payload)
        idle = dict(hook_event_name="Notification", notification_type="idle_prompt")
        for event in (dict(hook_event_name="Stop"), dict(hook_event_name="Stop", background_tasks=[{}]),
                      dict(hook_event_name="StopFailure", error="overloaded")):
            with self.subTest(event=event):
                hook(**event)
                before = store.read(task["id"])
                hook(**idle)
                self.assertEqual(store.read(task["id"]), before)
        # It still recovers a turn whose end went unreported.
        hook(hook_event_name="UserPromptSubmit")
        hook(**idle)
        record = store.read(task["id"])
        self.assertEqual((record["status"], record["lastEvent"]), ("ready", "Notification"))

    def test_compacting_or_clearing_a_conversation_is_not_a_turn_ending(self):
        # Claude compacts by itself mid-turn and reports SessionStart, which
        # flashed a working agent to ready, with a notification.
        task = self.create()
        store = roost.Store(str(self.state))
        hook = lambda **payload: roost.update_hook(store, task["id"], payload)
        hook(hook_event_name="UserPromptSubmit", session_id="s1")
        before = store.read(task["id"])
        hook(hook_event_name="SessionStart", source="compact", session_id="s1")
        self.assertEqual(store.read(task["id"]), before)
        hook(hook_event_name="SessionStart", source="compact", session_id="s2")
        self.assertEqual(store.read(task["id"]), dict(before, agentSession="s2", claudeSession="s2"))
        # /clear ends one conversation and starts the next in the same process.
        hook(hook_event_name="Stop", session_id="s2")
        hook(hook_event_name="SessionEnd", reason="clear", session_id="s2")
        self.assertEqual(store.read(task["id"])["status"], "ready")
        hook(hook_event_name="SessionStart", source="clear", session_id="s3")
        self.assertEqual((store.read(task["id"])["status"], store.read(task["id"])["agentSession"]), ("ready", "s3"))
        hook(hook_event_name="SessionEnd", reason="prompt_input_exit", session_id="s3")
        self.assertEqual(store.read(task["id"])["status"], "exited")

    def test_a_turn_ended_by_an_api_error_says_why_until_the_next_turn(self):
        task = self.create()
        store = roost.Store(str(self.state))
        roost.update_hook(store, task["id"], dict(hook_event_name="StopFailure", error="rate_limit",
                                                  error_details="You've hit your limit\n· resets 3pm"))
        record = store.read(task["id"])
        self.assertEqual((record["status"], record["error"]),
                         ("failed", "Its turn ended on an API error (rate_limit): You've hit your limit · resets 3pm"))
        listed = self.request("list")["result"][0]
        self.assertEqual((listed["status"], listed["live"]), ("failed", True))
        roost.update_hook(store, task["id"], dict(hook_event_name="UserPromptSubmit"))
        self.assertEqual((store.read(task["id"])["status"], store.read(task["id"])["error"]), ("running", None))

    def test_a_permission_request_records_what_it_asks(self):
        task = self.create()
        store = roost.Store(str(self.state))
        hook = lambda **payload: roost.update_hook(store, task["id"], payload)
        hook(hook_event_name="PermissionRequest", tool_name="Bash",
             tool_input=dict(command="cd sub &&\n  make test"))
        self.assertEqual(store.read(task["id"])["request"], "Asks to run cd sub && make test")
        # The notification that follows names no tool, and keeps it.
        hook(hook_event_name="Notification", notification_type="permission_prompt")
        self.assertEqual(store.read(task["id"])["request"], "Asks to run cd sub && make test")
        hook(hook_event_name="PostToolUse", tool_name="Bash", tool_input=dict(command="make test"))
        self.assertNotIn("request", store.read(task["id"]))
        # A prompt reported only by a notification has nothing to show.
        hook(hook_event_name="Notification", notification_type="permission_prompt")
        self.assertEqual(store.read(task["id"])["status"], "permission")
        self.assertNotIn("request", store.read(task["id"]))
        hook(hook_event_name="PermissionRequest", tool_name="Write",
             tool_input=dict(file_path=str(Path(task["worktree"]) / "docs" / "notes.md")))
        self.assertEqual(self.request("list")["result"][0]["request"], "Asks to write docs/notes.md")

    def test_dirty_tracked_and_untracked_work_blocks_cleanup(self):
        task = self.create()
        wt = Path(task["worktree"])
        (wt / "untracked").write_text("must survive\n")
        self.assertFalse(self.request("retire", id=task["id"])["ok"])
        self.assertTrue((wt / "untracked").exists())
        self.assertTrue(self.request("stop", id=task["id"])["ok"])
        (wt / "hello").write_text("changed\n")
        self.assertFalse(self.request("merge", id=task["id"])["ok"])
        self.assertEqual(self.git("show", "HEAD:hello"), "base")

    def test_unmerged_commits_preserved_then_merge_and_retire(self):
        task = self.create()
        wt = Path(task["worktree"])
        (wt / "hello").write_text("changed\n")
        self.git("add", ".", cwd=wt)
        self.git("commit", "-m", "fix", cwd=wt)
        self.assertFalse(self.request("retire", id=task["id"])["ok"])
        self.assertTrue(wt.exists())
        self.assertTrue(self.request("merge", id=task["id"])["ok"])
        self.assertEqual((self.repo / "hello").read_text(), "changed\n")
        self.assertFalse(wt.exists())

    def test_retire_refuses_checked_out_submodules_before_stopping_the_agent(self):
        # Git will not remove such a worktree; retiring used to stop the
        # agent first and then fail.
        library = self.root / "library"
        roost.git(self.root, "init", "-q", "-b", "main", str(library))
        roost.git(library, "-c", "user.name=T", "-c", "user.email=t@example.invalid",
                  "commit", "-q", "--allow-empty", "-m", "library")
        self.git("-c", "protocol.file.allow=always", "submodule", "add", "-q", str(library), "lib")
        self.git("commit", "-qm", "library")
        task = self.create()
        wt = Path(task["worktree"])
        self.git("-c", "protocol.file.allow=always", "submodule", "update", "-q", "--init", cwd=wt)
        reply = self.request("retire", id=task["id"])
        self.assertIn("submodules checked out (lib)", reply["error"])
        self.assertIn("git worktree remove --force", reply["error"])
        self.assertIn(task["paneId"], roost.pane_inventory(self.socket))
        self.request("stop", id=task["id"])
        self.git("worktree", "remove", "--force", str(wt))
        self.assertTrue(self.request("retire", id=task["id"])["ok"])

    def test_merge_into_a_branch_the_primary_checkout_has_not_checked_out(self):
        task = self.create()
        wt = Path(task["worktree"])
        (wt / "hello").write_text("changed\n")
        self.git("commit", "-qam", "fix", cwd=wt)
        # You are working on something else, with changes of your own.
        self.git("checkout", "-q", "-b", "mine")
        (self.repo / "hello").write_text("my own edit\n")
        reply = self.request("merge", id=task["id"])
        self.assertTrue(reply["ok"], reply)
        self.assertEqual(self.git("show", "main:hello"), "changed")
        self.assertEqual(self.git("log", "-1", "--format=%P", "main").count(" "), 1)
        # As `git merge` would say it.
        self.assertEqual(self.git("log", "-1", "--format=%s", "main"), "Merge branch '%s'" % task["branch"])
        self.assertEqual(self.git("symbolic-ref", "--short", "HEAD"), "mine")
        self.assertEqual((self.repo / "hello").read_text(), "my own edit\n")
        self.assertFalse(wt.exists())

    def test_a_squash_merge_adds_one_commit_with_the_tasks_messages(self):
        task = self.create()
        wt = Path(task["worktree"])
        (wt / "hello").write_text("one\n")
        self.git("commit", "-qam", "First change\n\nWhy it was needed.", cwd=wt)
        # The task was brought up to date along the way.
        (self.repo / "other").write_text("main moved\n")
        self.git("add", ".")
        self.git("commit", "-qm", "main moved")
        self.assertTrue(self.request("update", id=task["id"])["ok"])
        (wt / "hello").write_text("two\n")
        self.git("commit", "-qam", "Second change", cwd=wt)
        before = self.git("rev-parse", "main")
        reply = self.request("merge", id=task["id"], style="squash")
        self.assertTrue(reply["ok"], reply)
        # One commit on main, with only main as its parent.
        self.assertEqual(self.git("rev-parse", "main~1"), before)
        self.assertEqual(self.git("log", "-1", "--format=%P", "main"), before)
        self.assertEqual(self.git("log", "-1", "--format=%B", "main"),
                         "First change\n\n* First change\n* Second change")
        self.assertEqual((self.repo / "hello").read_text(), "two\n")
        self.assertEqual(self.git("status", "--porcelain"), "")
        self.assertFalse(wt.exists())
        self.assertNotIn(task["branch"], self.git("branch", "--list", task["branch"]))
        self.assertNotIn("remoteCleanup", reply["result"])

    def test_a_squash_merge_without_checkout_keeps_a_single_commits_message(self):
        task = self.create()
        wt = Path(task["worktree"])
        (wt / "hello").write_text("changed\n")
        self.git("commit", "-qam", "Fix the greeting\n\nIt said hello twice.", cwd=wt)
        self.git("checkout", "-q", "-b", "mine")
        before = self.git("rev-parse", "main")
        reply = self.request("merge", id=task["id"], style="squash")
        self.assertTrue(reply["ok"], reply)
        self.assertEqual(self.git("log", "-1", "--format=%P", "main"), before)
        self.assertEqual(self.git("log", "-1", "--format=%B", "main"), "Fix the greeting\n\nIt said hello twice.")
        self.assertEqual(self.git("show", "main:hello"), "changed")
        self.assertEqual(self.git("symbolic-ref", "--short", "HEAD"), "mine")
        self.assertFalse(wt.exists())

    def test_a_squash_merge_retires_a_task_whose_pull_request_merged_earlier(self):
        self.github()
        task = self.create()
        merged_earlier = self.commit_in(task)
        self.assertTrue(self.request("pr", id=task["id"], title="Earlier")["ok"])
        # GitHub merged the pull request; the task went on to commit again.
        (self.gh_dir / "list.json").write_text(json.dumps([dict(number=7, state="MERGED", headRefOid=merged_earlier)]))
        wt = Path(task["worktree"])
        (wt / "hello").write_text("two\n")
        self.git("commit", "-qam", "Second", cwd=wt)
        reply = self.request("merge", id=task["id"], style="squash")
        self.assertTrue(reply["ok"], reply)
        self.assertEqual((self.repo / "hello").read_text(), "two\n")
        self.assertFalse(wt.exists())
        # The branch on GitHub is not this task's last commit: left alone.
        self.assertNotIn("remoteCleanup", reply["result"])

    def test_squashing_again_adds_no_empty_commit(self):
        task = self.create()
        wt = Path(task["worktree"])
        # Two commits, so the squashed one differs from the task's own.
        (wt / "hello").write_text("changed\n")
        self.git("commit", "-qam", "Fix", cwd=wt)
        (wt / "hello").write_text("changed again\n")
        self.git("commit", "-qam", "Fix again", cwd=wt)
        self.git("checkout", "-q", "-b", "mine")
        record = dict(repo=os.path.realpath(self.repo), branch=task["branch"], name=task["name"])
        tip = self.git("rev-parse", "HEAD", cwd=wt)
        self.assertEqual(roost.squash_merge(record, "main", False), tip)
        squashed = self.git("rev-parse", "main")
        # As when the merge went through but retiring the task did not.
        self.assertEqual(roost.squash_merge(record, "main", False), tip)
        self.assertEqual(self.git("rev-parse", "main"), squashed)

    def test_a_conflicting_squash_merge_changes_nothing(self):
        task = self.create()
        wt = Path(task["worktree"])
        (wt / "hello").write_text("task\n")
        self.git("commit", "-qam", "task", cwd=wt)
        (self.repo / "hello").write_text("main\n")
        self.git("commit", "-qam", "main")
        before = self.git("rev-parse", "main")
        error = self.request("merge", id=task["id"], style="squash")["error"]
        self.assertIn("conflicts with main in hello", error)
        self.assertEqual(self.git("rev-parse", "main"), before)
        self.assertEqual(self.git("status", "--porcelain"), "")
        self.assertEqual((self.repo / "hello").read_text(), "main\n")
        self.assertTrue(wt.exists())

    def test_a_conflicting_merge_without_checkout_changes_nothing(self):
        task = self.create()
        wt = Path(task["worktree"])
        (wt / "hello").write_text("task\n")
        self.git("commit", "-qam", "task", cwd=wt)
        (self.repo / "hello").write_text("main\n")
        self.git("commit", "-qam", "main")
        before = self.git("rev-parse", "main")
        self.git("checkout", "-q", "-b", "mine")
        error = self.request("merge", id=task["id"])["error"]
        self.assertIn("conflicts with main in hello", error)
        self.assertEqual(self.git("rev-parse", "main"), before)
        self.assertTrue(wt.exists())

    def test_merge_refuses_a_branch_checked_out_in_another_worktree(self):
        task = self.create()
        wt = Path(task["worktree"])
        (wt / "hello").write_text("changed\n")
        self.git("commit", "-qam", "fix", cwd=wt)
        self.git("checkout", "-q", "-b", "mine")
        other = self.root / "other"
        self.git("worktree", "add", "-q", str(other), "main")
        self.assertIn("is checked out in", self.request("merge", id=task["id"])["error"])

    def test_only_tracked_changes_in_the_primary_checkout_block_a_merge(self):
        task = self.create()
        wt = Path(task["worktree"])
        (wt / "hello").write_text("changed\n")
        (wt / "added").write_text("from the task\n")
        self.git("add", ".", cwd=wt)
        self.git("commit", "-m", "fix", cwd=wt)
        (self.repo / "hello").write_text("local edit\n")
        reply = self.request("merge", id=task["id"])
        self.assertFalse(reply["ok"])
        self.assertIn("The primary checkout %s has uncommitted changes" % os.path.realpath(self.repo), reply["error"])
        self.git("checkout", "--", "hello")
        # Git refuses to overwrite an untracked file, and nothing changes.
        (self.repo / "added").write_text("mine\n")
        reply = self.request("merge", id=task["id"])
        self.assertFalse(reply["ok"])
        self.assertIn("added", reply["error"])
        self.assertEqual((self.repo / "added").read_text(), "mine\n")
        self.assertEqual(self.git("show", "HEAD:hello"), "base")
        self.assertTrue(wt.exists())
        # Other untracked files stay where they are.
        (self.repo / "added").unlink()
        (self.repo / "notes.txt").write_text("scratch\n")
        self.assertTrue(self.request("merge", id=task["id"])["ok"])
        self.assertEqual((self.repo / "hello").read_text(), "changed\n")
        self.assertEqual((self.repo / "notes.txt").read_text(), "scratch\n")
        self.assertFalse(wt.exists())

    def test_a_file_name_that_is_not_utf8_does_not_fail_listings(self):
        # Linux allows any bytes in a file name; one such untracked file made
        # every full listing fail, so the host looked unreachable.
        printed = roost.execute([sys.executable, "-c", "import sys; sys.stdout.buffer.write(b'caf\\xe9')"])
        self.assertEqual(printed.stdout, "caf�")
        task = self.create()
        try:
            with open(os.path.join(os.fsencode(task["worktree"]), b"caf\xe9.txt"), "w") as file:
                file.write("latin-1 name\n")
        except OSError:
            self.skipTest("this file system only allows UTF-8 names")
        reply = self.request("list", full=True)
        self.assertTrue(reply["ok"], reply)
        self.assertEqual(reply["result"][0]["files"], [dict(path="caf�.txt", untracked=True)])

    def test_an_agent_on_a_branch_of_its_own_can_resume_but_not_merge(self):
        # An agent told to work on a feature branch left Roost refusing to
        # resume it or open its shell, with no way forward.
        task = self.create()
        wt = Path(task["worktree"])
        self.git("checkout", "-q", "-b", "feature/search", cwd=wt)
        (wt / "hello").write_text("search\n")
        self.git("commit", "-qam", "search", cwd=wt)
        self.assertTrue(self.request("stop", id=task["id"])["ok"])
        self.assertTrue(self.request("resume", id=task["id"])["ok"])
        self.wait(task, "ready")
        self.assertTrue(self.request("shell", id=task["id"])["ok"])
        for action in ("merge", "retire", "update"):
            with self.subTest(action=action):
                reply = self.request(action, id=task["id"])
                self.assertFalse(reply["ok"])
                self.assertIn("worktree is on feature/search, not the task's branch " + task["branch"],
                              reply["error"])
        self.assertEqual(self.git("rev-parse", "HEAD"), task["baseCommit"])
        self.git("checkout", "-q", task["branch"], cwd=wt)
        self.git("merge", "-q", "feature/search", cwd=wt)
        self.assertTrue(self.request("merge", id=task["id"])["ok"])
        self.assertEqual((self.repo / "hello").read_text(), "search\n")

    def test_names_in_any_script_get_ascii_branches(self):
        for name, slug in (("修复解析器", "task"), ("исправить ошибку", "task"), ("café menu", "cafe-menu"),
                           ("Ünïcödé--naming_test", "Unicode-naming_test"), ("fix #12: parser!", "fix-12-parser"),
                           ("x" * 49 + " y", "x" * 49)):
            with self.subTest(name=name):
                self.assertEqual(roost.name_slug(name), slug)
        reply = self.request("create", directory=str(self.repo), name="修复解析器", socket=self.socket,
                             command=[sys.executable, str(FAKE)])
        self.assertTrue(reply["ok"], reply)
        task = self.wait(reply["result"], "ready")
        self.assertEqual(task["name"], "修复解析器")
        self.assertEqual(task["branch"], "roost/task-" + task["id"][:6])
        self.assertEqual(Path(task["worktree"]).name, "task-" + task["id"][:6])
        for name in ("!!!", " ", "tab\there"):
            with self.subTest(name=name):
                self.assertFalse(self.request("create", directory=str(self.repo), name=name,
                                              socket=self.socket)["ok"])

    def test_a_merge_under_way_in_a_task_is_listed_until_it_is_done(self):
        task = self.create()
        wt = Path(task["worktree"])
        (wt / "hello").write_text("task\n")
        self.git("commit", "-qam", "task", cwd=wt)
        (self.repo / "hello").write_text("main\n")
        self.git("commit", "-qam", "main")
        self.assertEqual(self.request("update", id=task["id"])["result"]["update"]["conflicts"], ["hello"])
        self.assertEqual(self.request("list", full=True)["result"][0]["merging"], dict(conflicts=["hello"]))
        (wt / "hello").write_text("both\n")
        self.git("add", "hello", cwd=wt)
        self.assertEqual(self.request("list", full=True)["result"][0]["merging"], dict(conflicts=[]))
        self.git("commit", "-q", "--no-edit", cwd=wt)
        self.assertIsNone(self.request("list", full=True)["result"][0]["merging"])

    def test_a_conflict_with_the_integration_branch_is_listed_before_merging(self):
        task = self.create()
        wt = Path(task["worktree"])
        listed = lambda: self.request("list", full=True)["result"][0]
        self.assertEqual(listed()["conflicts"], [])
        (wt / "hello").write_text("task\n")
        (wt / "both").write_text("task\n")
        self.git("add", ".", cwd=wt)
        self.git("commit", "-qm", "task", cwd=wt)
        # Nothing on main to conflict with.
        self.assertEqual(listed()["conflicts"], [])
        stamp = listed()["gitStamp"]
        (self.repo / "hello").write_text("main\n")
        (self.repo / "both").write_text("main\n")
        (self.repo / "apart").write_text("main\n")
        self.git("add", ".")
        self.git("commit", "-qm", "main")
        # Moving main moves the stamp, so Emacs measures the task again.
        self.assertNotEqual(listed()["gitStamp"], stamp)
        self.assertEqual(listed()["conflicts"], ["both", "hello"])
        self.assertEqual(self.git("status", "--porcelain"), "")
        # Merging main into the task settles them once it is committed.
        self.assertTrue(self.request("update", id=task["id"])["ok"])
        self.assertEqual(listed()["conflicts"], ["both", "hello"])
        (wt / "hello").write_text("both\n")
        (wt / "both").write_text("both\n")
        self.git("add", ".", cwd=wt)
        self.git("commit", "-q", "--no-edit", cwd=wt)
        self.assertEqual(listed()["conflicts"], [])
        # Older Git can't tell without a working tree.
        (self.repo / "hello").write_text("main again\n")
        self.git("commit", "-qam", "main again")
        self.assertEqual(listed()["conflicts"], ["hello"])
        with patch.object(roost, "merges_without_checkout", lambda: False):
            self.assertIsNone(listed()["conflicts"])
        # GitHub says so for an open pull request, and nobody for a branch that's gone.
        store = roost.Store(str(self.state))
        for change in (dict(pr=dict(number=12, url="https://github.com/o/r/pull/12", state="OPEN")),
                       dict(integrationBranch="gone")):
            with self.subTest(change=change), patch.object(roost, "gh", side_effect=roost.RoostError("offline")):
                record = store.read(task["id"])
                store.save(dict(record, **change))
                self.assertIsNone(listed()["conflicts"])
                store.save(record)
        self.assertNotIn("conflicts", store.read(task["id"]))

    def test_merge_conflict_aborts_and_keeps_task(self):
        task = self.create()
        wt = Path(task["worktree"])
        (wt / "hello").write_text("task\n")
        self.git("add", ".", cwd=wt)
        self.git("commit", "-m", "task", cwd=wt)
        (self.repo / "hello").write_text("main\n")
        self.git("add", ".")
        self.git("commit", "-m", "main")
        self.assertFalse(self.request("merge", id=task["id"])["ok"])
        self.assertTrue(wt.exists())
        self.assertEqual(self.git("status", "--porcelain"), "")
        self.assertEqual((self.repo / "hello").read_text(), "main\n")

    def test_update_brings_a_task_up_to_date_and_conflicts_stay_in_its_worktree(self):
        task = self.create()
        wt = Path(task["worktree"])
        (self.repo / "other").write_text("main moved\n")
        self.git("add", ".")
        self.git("commit", "-qm", "main moved")
        reply = self.request("update", id=task["id"])
        self.assertTrue(reply["ok"], reply)
        self.assertEqual(reply["result"]["update"], dict(conflicts=[], changed=True))
        self.assertEqual((wt / "other").read_text(), "main moved\n")
        listed = self.request("list", full=True)["result"][0]
        self.assertEqual(listed["diff"], "", "main's changes are not the task's")
        self.assertEqual(self.request("update", id=task["id"])["result"]["update"]["changed"], False)
        (wt / "hello").write_text("task\n")
        self.git("commit", "-qam", "task", cwd=wt)
        (self.repo / "hello").write_text("main\n")
        self.git("commit", "-qam", "main")
        merge = self.request("merge", id=task["id"])
        self.assertIn("conflicts with main in hello. Nothing was changed", merge["error"])
        self.assertEqual(self.git("status", "--porcelain"), "")
        reply = self.request("update", id=task["id"])
        self.assertEqual(reply["result"]["update"]["conflicts"], ["hello"])
        self.assertIn("already in progress", self.request("update", id=task["id"])["error"])
        self.assertFalse(self.request("merge", id=task["id"])["ok"])
        self.assertEqual((self.repo / "hello").read_text(), "main\n")
        (wt / "hello").write_text("main and task\n")
        self.git("add", "hello", cwd=wt)
        self.git("commit", "-q", "--no-edit", cwd=wt)
        # The message a merge of the branch's short name has.
        self.assertEqual(self.git("log", "-1", "--format=%s", cwd=wt), "Merge branch 'main' into " + task["branch"])
        self.assertTrue(self.request("merge", id=task["id"])["ok"])
        self.assertEqual((self.repo / "hello").read_text(), "main and task\n")

    def test_a_full_listing_names_the_changed_files(self):
        task = self.create()
        wt = Path(task["worktree"])
        (wt / "done").write_text("committed\n")
        self.git("add", "done", cwd=wt)
        self.git("commit", "-q", "-m", "Add done", cwd=wt)
        (wt / "hello").write_text("one\ntwo\n")
        self.git("mv", "hello", "greeting", cwd=wt)
        (wt / "new file").write_text("x\n")
        (wt / "image").write_bytes(b"\0\1")
        self.git("add", "image", cwd=wt)
        files = self.request("list", full=True)["result"][0]["files"]
        # Files with changes not yet committed, staged or not, are marked.
        self.assertIn(dict(path="done", added=1, deleted=0), files)
        self.assertIn(dict(path="image", uncommitted=True), files)
        self.assertIn(dict(path="new file", untracked=True), files)
        self.assertIn(dict(path="greeting", added=2, deleted=0, uncommitted=True), files)
        # A list cut short keeps the files not yet committed.
        self.assertEqual([file["path"] for file in roost.changed_files(wt, "main", {"image"}, limit=2)[0]],
                         ["image", "new file"])
        self.assertEqual(roost.status_paths("R  new\0old\0 M a b\0?? c\0"), {"new", "a b", "c"})
        # Like the other statistics, the list is never saved in the record.
        store = roost.Store(str(self.state))
        store.save(dict(store.read(task["id"]), files=files))
        self.assertNotIn("files", store.read(task["id"]))

    def test_a_full_listing_measures_the_size_and_spread_of_the_changes(self):
        (self.repo / "old").mkdir()
        (self.repo / "old" / "kept").write_text("kept\n")
        self.git("add", "old")
        self.git("commit", "-q", "-m", "Add kept")
        task = self.create()
        wt = Path(task["worktree"])
        (wt / "docs").mkdir()
        (wt / "docs" / "guide.md").write_text("one\ntwo\nthree\n")
        self.git("add", "docs", cwd=wt)
        self.git("commit", "-q", "-m", "Add a guide", cwd=wt)
        (wt / "hello").write_text("changed\n")
        # Moved out of a directory, it changes the one it leaves.
        self.git("mv", "old/kept", "kept", cwd=wt)
        # Files Git doesn't track yet count their lines, as Git would once
        # they are added, but a binary one has none.
        (wt / "src").mkdir()
        (wt / "src" / "new.py").write_text("a\nb")
        (wt / "src" / "image").write_bytes(b"\0\1\n")
        (wt / "src" / "long").write_text("x\n" * 10)
        listed = self.request("list", full=True)["result"][0]
        self.assertEqual(listed["size"], dict(added=3 + 1 + 2 + 10, deleted=1, files=6,
                                              directories=["docs", "old", "src"], topLevel=True))
        # One too large isn't read, past the first byte too many.
        self.assertEqual(roost.untracked_lines(wt / "src" / "long", largest=20), 10)
        self.assertEqual(roost.untracked_lines(wt / "src" / "long", largest=19), 0)
        reads = []
        real_open = Path.open
        def opened(path, *args, **kwargs):
            file = real_open(path, *args, **kwargs)
            read = file.read
            file.read = lambda size=-1: reads.append(size) or read(size)
            return file
        with patch.object(Path, "open", opened):
            roost.untracked_lines(wt / "src" / "long", largest=8)
        self.assertEqual(reads, [9])
        self.assertEqual(roost.untracked_lines(wt / "src"), 0)
        # Like the other statistics, it is never saved in the record.
        store = roost.Store(str(self.state))
        store.save(dict(store.read(task["id"]), size=listed["size"]))
        self.assertNotIn("size", store.read(task["id"]))

    def test_measuring_takes_no_optional_git_locks(self):
        # git status would refresh the index under its lock, and an agent
        # committing at that moment would fail.
        task = self.create()
        self.commit_in(task)
        (Path(task["worktree"]) / "new").write_text("new\n")
        self.assertTrue(self.request("look", id=task["id"])["ok"])
        (Path(task["worktree"]) / "hello").write_text("changed\n")
        calls = []
        real = roost.execute
        with patch.object(roost, "execute", lambda argv, **kw: calls.append(argv) or real(argv, **kw)):
            roost.add_git_stats([roost.Store(str(self.state)).read(task["id"])])
        statuses = [argv for argv in calls if "status" in argv]
        self.assertTrue(statuses)
        for argv in calls:
            if argv[0] == "git" and "merge-base" not in argv:
                self.assertIn("--no-optional-locks", argv)

    def test_a_full_listing_can_name_the_tasks_to_measure(self):
        first, second = self.create(), self.create(name="second")
        (Path(first["worktree"]) / "hello").write_text("changed\n")
        listed = {t["id"]: t for t in self.request("list", full=[first["id"]])["result"]}
        self.assertTrue(listed[first["id"]]["dirty"])
        self.assertNotIn("diff", listed[second["id"]])

    def test_listings_stamp_each_tasks_git_state(self):
        # Polls skip the statistics; a moved stamp tells Emacs to measure the
        # task again, as after a commit made in a shell rather than by the agent.
        task = self.create()
        wt = Path(task["worktree"])
        stamp = lambda: self.request("list")["result"][0]["gitStamp"]
        first = stamp()
        self.assertTrue(first)
        # Measuring takes no index lock, so it leaves the stamp alone.
        (wt / "hello").write_text("changed\n")
        self.request("list", full=True)
        self.assertEqual(stamp(), first)
        time.sleep(0.05)  # Some file systems keep coarse times.
        self.git("commit", "-qam", "change", cwd=wt)
        second = stamp()
        self.assertNotEqual(second, first)
        # The integration branch moving on changes how far behind the task is.
        time.sleep(0.05)
        (self.repo / "other").write_text("x\n")
        self.git("add", "other")
        self.git("commit", "-qm", "other")
        self.assertNotEqual(stamp(), second)
        self.assertNotIn("gitStamp", roost.Store(str(self.state)).read(task["id"]))

    def test_window_renumbering_does_not_change_task_identity(self):
        task = self.create()
        roost.tmux(self.socket, "move-window", "-s", task["windowId"], "-t", task["session"] + ":8")
        self.assertTrue(self.request("send", id=task["id"], text="literal $() `ticks` \\\"quotes\\\"")["ok"])
        listed = self.request("list", full=True)["result"][0]
        self.assertEqual(listed["windowIndex"], 8)
        self.assertEqual(listed["paneId"], task["paneId"])

    def test_each_task_gets_a_session_named_after_its_project_and_task(self):
        task = self.create()
        # The fixture's "repo with spaces" also shows names made safe for tmux.
        self.assertEqual(task["session"], "roost-repo-with-spaces-" + task["id"][:6])
        other = self.create(name="later")
        self.assertNotEqual(other["session"], task["session"])
        # A session from before, named by hash alone, keeps the tasks it holds.
        repo_hash = hashlib.sha256(str(self.repo.resolve()).encode()).hexdigest()[:10]
        roost.tmux(self.socket, "new-session", "-d", "-s", "roost-" + repo_hash)
        self.assertNotEqual(self.create(name="newer")["session"], "roost-" + repo_hash)

    def test_a_renamed_session_is_followed_until_the_task_resumes(self):
        task = self.create()
        roost.tmux(self.socket, "rename-session", "-t", task["session"], "renamed")
        self.assertEqual(self.request("inspect", id=task["id"])["result"]["session"], "renamed")
        self.request("stop", id=task["id"])
        self.request("resume", id=task["id"])
        self.assertEqual(self.wait(task, "ready")["session"], roost.session_name(task["repo"], task["id"]))

    def test_a_task_from_a_repository_wide_session_resumes_in_its_own(self):
        # Before each task had a session of its own, a project's tasks shared
        # one named by the repository's hash, beside a shell window.
        repo_hash = hashlib.sha256(str(self.repo.resolve()).encode()).hexdigest()[:10]
        shared = "roost-" + repo_hash
        roost.tmux(self.socket, "new-session", "-d", "-s", shared, "-n", "shell")
        task = self.create()
        self.assertTrue(self.request("stop", id=task["id"])["ok"])
        store = roost.Store(str(self.state))
        record = store.read(task["id"])
        record["session"] = shared
        store.save(record)
        self.assertTrue(self.request("resume", id=task["id"])["ok"])
        resumed = self.wait(task, "ready")
        self.assertEqual(resumed["session"], roost.session_name(record["repo"], task["id"]))
        self.assertEqual(roost.pane_inventory(self.socket)[resumed["paneId"]]["session_name"], resumed["session"])
        # The old session stays, with whatever else it holds.
        sessions = roost.tmux(self.socket, "list-sessions", "-F", "#{session_name}").stdout.split()
        self.assertEqual(sorted(sessions), sorted([shared, resumed["session"]]))

    def test_a_task_merges_into_the_branch_it_starts_from(self):
        self.git("branch", "release")
        self.git("commit", "--allow-empty", "-m", "newer main")
        release = self.create(name="on release", base="release")
        self.assertEqual((release["integrationBranch"], release["baseRef"]), ("release", "release"))
        self.assertEqual(release["baseCommit"], self.git("rev-parse", "release"))
        # A fork, or a task started from another's branch, merges where that one does.
        fork = self.create(name="fork", directory=release["worktree"], base="HEAD")
        self.assertEqual(fork["integrationBranch"], "release")
        stacked = self.create(name="stacked", base=release["branch"])
        self.assertEqual(stacked["integrationBranch"], "release")
        # A tag or commit merges into the primary checkout's branch.
        self.git("tag", "v1", "release")
        self.assertEqual(self.create(name="tagged", base="v1")["integrationBranch"], "main")
        self.assertEqual(self.create(name="commit", base=self.git("rev-parse", "release"))["integrationBranch"],
                         "main")

    def test_an_update_takes_the_branch_and_not_a_tag_of_its_name(self):
        self.git("branch", "release")
        self.git("tag", "release")
        task = self.create(name="on release", base="heads/release")
        self.assertEqual(task["integrationBranch"], "release")
        self.git("commit", "--allow-empty", "-qm", "release moved")
        roost.git(self.repo, "update-ref", "refs/heads/release", self.git("rev-parse", "HEAD"))
        reply = self.request("update", id=task["id"])
        self.assertTrue(reply["ok"], reply)
        self.assertEqual(self.git("log", "-1", "--format=%s", cwd=task["worktree"]), "release moved")
        # With the primary checkout on it, the tag hides neither it nor that it is checked out there.
        self.request("stop", id=task["id"])
        self.git("switch", "-q", "release")
        self.git("commit", "--allow-empty", "-qm", "past the tag")
        default = self.create(name="default")
        self.assertEqual(default["integrationBranch"], "release")
        self.assertEqual(default["baseCommit"], self.git("rev-parse", "HEAD"))
        wt = Path(task["worktree"])
        (wt / "work").write_text("work\n")
        self.git("add", ".", cwd=wt)
        self.git("commit", "-qm", "work", cwd=wt)
        merge = self.request("merge", id=task["id"])
        self.assertTrue(merge["ok"], merge)
        self.assertEqual((self.repo / "work").read_text(), "work\n")
        self.assertEqual(default["integrationRef"], "refs/heads/release")
        # Older helpers recorded heads/release, and no integrationRef; such
        # a task still updates from release and merges into it.
        store = roost.Store(str(self.state))
        record = store.read(default["id"])
        record["integrationBranch"] = "heads/release"
        del record["integrationRef"]
        store.save(record)
        self.request("stop", id=default["id"])
        listed = next(t for t in self.request("list")["result"] if t["id"] == default["id"])
        self.assertEqual(listed["integrationBranch"], "release")
        # A fork of it merges into release, as it does.
        fork = self.create(name="legacy fork", directory=default["worktree"], base="HEAD")
        self.assertEqual((fork["integrationBranch"], fork["integrationRef"]), ("release", "refs/heads/release"))
        self.request("stop", id=fork["id"])
        self.assertTrue(self.request("retire", id=fork["id"])["ok"])
        self.git("commit", "--allow-empty", "-qm", "release moved on")
        reply = self.request("update", id=default["id"])
        self.assertTrue(reply["ok"], reply)
        self.assertEqual(self.git("log", "-1", "--format=%s", cwd=default["worktree"]), "release moved on")
        (Path(default["worktree"]) / "older").write_text("older\n")
        self.git("add", ".", cwd=default["worktree"])
        self.git("commit", "-qm", "older", cwd=default["worktree"])
        merge = self.request("merge", id=default["id"])
        self.assertTrue(merge["ok"], merge)
        self.assertEqual((self.repo / "older").read_text(), "older\n")
        # A branch that is named heads/release is not taken for release once it is gone.
        roost.git(self.repo, "update-ref", "refs/heads/heads/release", "HEAD")
        literal = self.create(name="literal", base="refs/heads/heads/release")
        self.assertEqual(literal["integrationBranch"], "heads/release")
        self.request("stop", id=literal["id"])
        self.commit_in(literal, "literal")
        roost.git(self.repo, "update-ref", "-d", "refs/heads/heads/release")
        self.assertIn("heads/release no longer exists", self.request("merge", id=literal["id"])["error"])

    def test_a_remote_tracking_start_merges_into_its_local_branch(self):
        remote = self.root / "remote.git"
        roost.git(self.root, "clone", "-q", "--bare", str(self.repo), str(remote))
        self.git("remote", "add", "origin", str(remote))
        self.git("commit", "--allow-empty", "-m", "pushed")
        self.git("push", "-q", "origin", "main:main", "main:release")
        self.git("fetch", "-q", "origin")
        self.git("reset", "-q", "--hard", "HEAD~1")
        # Local main lags origin/main; the task starts from origin's and merges into main.
        lagging = self.create(name="lagging", base="origin/main")
        self.assertEqual(lagging["integrationBranch"], "main")
        self.assertEqual(lagging["baseCommit"], self.git("rev-parse", "origin/main"))
        # With no local release, Roost makes one that tracks origin's.
        released = self.create(name="released", base="origin/release")
        self.assertEqual(released["integrationBranch"], "release")
        self.assertEqual(self.git("rev-parse", "--abbrev-ref", "release@{upstream}"), "origin/release")
        # A remote's name may hold a slash.
        self.git("remote", "add", "team/origin", str(remote))
        self.git("fetch", "-q", "team/origin")
        slashed = self.create(name="slashed", base="team/origin/release")
        self.assertEqual(slashed["integrationBranch"], "release")
        self.assertFalse(roost.ref_exists(self.repo, "origin/release"))
        # Made meanwhile by another task's start, as tasks prepare unlocked.
        with patch.object(roost, "ref_exists", side_effect=[False, True]):
            self.assertEqual(roost.integration_for(roost.Store(str(self.state)), str(self.repo.resolve()),
                                                   str(self.repo), "origin/release", "main"), "release")

    def test_new_tasks_default_to_primary_branch_and_explicit_head_forks(self):
        first = self.create()
        wt = Path(first["worktree"])
        (wt / "hello").write_text("parent task commit\n")
        self.git("add", ".", cwd=wt)
        self.git("commit", "-m", "parent change", cwd=wt)
        reply = self.request("create", directory=str(wt), name="child", socket=self.socket,
                             base="HEAD",
                             command=[sys.executable, str(FAKE)])
        self.assertTrue(reply["ok"], reply)
        child = self.wait(reply["result"], "ready")
        self.assertEqual(Path(child["repo"]), self.repo.resolve())
        self.assertEqual(child["integrationBranch"], "main")
        self.assertEqual(child["baseCommit"], self.git("rev-parse", "HEAD", cwd=wt))
        # Each task has its own session, forks included.
        self.assertNotEqual(child["session"], first["session"])
        # The fork's own commit is not on main, so retiring it would lose work.
        child_wt = Path(child["worktree"])
        (child_wt / "child").write_text("child work\n")
        self.git("add", ".", cwd=child_wt)
        self.git("commit", "-m", "child change", cwd=child_wt)
        self.request("stop", id=child["id"])
        self.assertFalse(self.request("retire", id=child["id"])["ok"])
        reply = self.request("create", directory=str(wt), name="independent", socket=self.socket,
                             command=[sys.executable, str(FAKE)])
        self.assertTrue(reply["ok"], reply)
        independent = self.wait(reply["result"], "ready")
        self.assertEqual(independent["baseRef"], "main")
        self.assertEqual(independent["baseCommit"], self.git("rev-parse", "HEAD"))
        self.assertNotEqual(independent["baseCommit"], child["baseCommit"])
        self.assertTrue(self.request("retire", id=independent["id"])["ok"])

    def test_shell_reuses_worktree_pane_and_stops_with_task(self):
        task = self.create()
        reply = self.request("shell", id=task["id"])
        self.assertTrue(reply["ok"], reply)
        shell = reply["result"]["shellPaneId"]
        self.assertNotEqual(shell, task["paneId"])
        path = roost.tmux(self.socket, "display-message", "-p", "-t", shell, "#{pane_current_path}").stdout.strip()
        self.assertEqual(Path(path).resolve(), Path(task["worktree"]).resolve())
        self.assertEqual(self.request("shell", id=task["id"])["result"]["shellPaneId"], shell)
        self.assertEqual(len(roost.pane_inventory(self.socket)), 2)  # agent and task shell
        self.assertTrue(self.request("stop", id=task["id"])["ok"])
        self.assertNotIn(shell, roost.pane_inventory(self.socket))
        self.assertFalse(self.request("shell", id=task["id"])["ok"])
        self.assertTrue(self.request("resume", id=task["id"])["ok"])
        self.wait(task, "ready")
        # Stopping ended the task's session, and with it this tmux server, so
        # pane IDs start over; the ownership tag tells the new shell apart.
        resumed = self.request("shell", id=task["id"])["result"]
        pane = roost.pane_inventory(self.socket)[resumed["shellPaneId"]]
        self.assertEqual((pane["task"], pane["dead"], pane["window"]), (task["id"], False, resumed["windowId"]))
        self.assertNotEqual(resumed["shellPaneId"], resumed["paneId"])

    def test_panes_split_by_hand_start_in_worktree_and_close_on_exit(self):
        task = self.create()
        # As tmux-control splits, naming no directory; then its program exits.
        before = set(roost.pane_inventory(self.socket))
        roost.tmux(self.socket, "-C", "attach", "-t", task["session"],
                   input="split-window -d -t %s cat\n" % task["paneId"])
        (pane,) = set(roost.pane_inventory(self.socket)) - before
        path = roost.tmux(self.socket, "display-message", "-p", "-t", pane, "#{pane_current_path}").stdout.strip()
        self.assertEqual(Path(path).resolve(), Path(task["worktree"]).resolve())
        roost.tmux(self.socket, "send-keys", "-t", pane, "C-d")
        deadline = time.monotonic() + 8
        while pane in roost.pane_inventory(self.socket) and time.monotonic() < deadline:
            time.sleep(0.05)
        self.assertNotIn(pane, roost.pane_inventory(self.socket))
        self.request("send", id=task["id"], text="exit")
        self.wait(task, "exited")
        self.wait_for_pane_exit(task)
        self.assertTrue(roost.pane_inventory(self.socket)[task["paneId"]]["dead"])

    def test_shell_survives_agent_exit_but_refuses_lost_ownership(self):
        task = self.create()
        self.request("send", id=task["id"], text="exit")
        self.wait(task, "exited")
        reply = self.request("shell", id=task["id"])
        self.assertTrue(reply["ok"], reply)
        shell = reply["result"]["shellPaneId"]
        roost.tmux(self.socket, "set-option", "-p", "-t", shell, "@roost_task_id", "other")
        self.assertFalse(self.request("shell", id=task["id"])["ok"])
        self.assertIn(shell, roost.pane_inventory(self.socket))
        roost.tmux(self.socket, "set-option", "-p", "-t", task["paneId"], "@roost_task_id", "other")
        self.assertFalse(self.request("shell", id=task["id"])["ok"])

    def test_agent_adapter_preserves_legacy_conversations_and_rejects_unknown_agents(self):
        task = self.create()
        store = roost.Store(str(self.state))
        record = store.read(task["id"])
        session = record["claudeSession"]
        self.assertEqual(record["agentSession"], session)
        record.pop("agent")
        record.pop("agentSession")
        store.save(record)
        self.request("stop", id=task["id"])
        self.assertTrue(self.request("resume", id=task["id"])["ok"])
        self.assertEqual(self.wait(task, "ready")["agentSession"], session)
        before = self.git("worktree", "list", "--porcelain")
        reply = self.request("create", directory=str(self.repo), name="future", agent="unknown", socket=self.socket)
        self.assertFalse(reply["ok"], reply)
        self.assertEqual(self.git("worktree", "list", "--porcelain"), before)

    def test_codex_pi_and_opencode_create_send_shell_resume_and_retire(self):
        for agent in ("codex", "pi", "opencode"):
            with self.subTest(agent=agent):
                task = self.create(name=agent, agent=agent, command=[sys.executable, str(FAKE_AGENT), agent])
                record = self.wait(task, "ready")
                self.assertIsNone(record["claudeSession"])
                self.assertTrue(self.request("send", id=task["id"], text="literal $() `ticks` prompt")["ok"])
                finished = self.wait(task, "ready", event="Stop")
                self.assertEqual(finished["lastEvent"], "Stop")
                # OpenCode starts its session with the first prompt.
                session = record.get("agentSession") or finished["agentSession"]
                self.assertTrue(session)
                pane = self.request("shell", id=task["id"])["result"]["shellPaneId"]
                self.assertTrue(self.request("stop", id=task["id"])["ok"])
                self.assertNotIn(pane, roost.pane_inventory(self.socket))
                self.assertTrue(self.request("resume", id=task["id"])["ok"])
                resumed = self.wait(task, "ready")
                self.assertEqual(resumed["agentSession"], session)
                self.assertNotEqual(resumed["runId"], record["runId"])
                # Older provider events cannot steer a resumed task.
                payload = {"codex": dict(hook_event_name="Stop", session_id="wrong"),
                           "pi": dict(event="agent_end", session="wrong"),
                           "opencode": dict(event="status", status="idle", session="wrong")}[agent]
                store = roost.Store(str(self.state))
                roost.update_hook(store, task["id"], payload, record["runId"])
                self.assertEqual(store.read(task["id"])["agentSession"], session)
                self.assertTrue(self.request("retire", id=task["id"])["ok"])
        self.assertEqual(self.git("status", "--porcelain"), "")

    def test_codex_hook_command_survives_helper_upgrades(self):
        store = roost.Store(str(self.state))
        task = dict(id="1234567890abcdef", command=["codex"], prompt=None)
        hooks = lambda argv: [arg for arg in argv if arg.startswith("hooks.")]
        before = hooks(roost.CodexAgent().launch(store, task, False))
        with patch.object(roost, "__file__", str(self.root / "remote-newversion.py")):
            after = hooks(roost.CodexAgent().launch(store, task, False))
        self.assertEqual(before, after)
        self.assertNotIn("remote-", " ".join(after))

    def test_codex_approvals_block_send_and_retirement(self):
        task = self.create(agent="codex", command=[sys.executable, str(FAKE_AGENT), "codex"])
        self.assertTrue(self.request("send", id=task["id"], text="permission")["ok"])
        self.wait(task, "permission")
        self.assertFalse(self.request("send", id=task["id"], text="yes")["ok"])
        self.assertFalse(self.request("retire", id=task["id"])["ok"])

    def test_codex_deferred_start_requires_first_prompt_in_native_terminal(self):
        reply = self.request("create", directory=str(self.repo), name="deferred", socket=self.socket,
                             agent="codex", command=[sys.executable, str(FAKE_AGENT), "codex", "deferred-start"])
        self.assertTrue(reply["ok"], reply)
        task = reply["result"]
        self.wait(task, "starting")
        self.assertTrue(self.request("inspect", id=task["id"])["ok"])
        self.assertFalse(self.request("send", id=task["id"], text="do not paste into startup")["ok"])
        roost.tmux(self.socket, "send-keys", "-t", task["paneId"], "first native prompt", "Enter")
        self.wait(task, "ready", event="Stop")
        self.assertTrue(self.request("send", id=task["id"], text="second prompt")["ok"])

    def test_a_relayed_codex_ends_its_turns_by_its_hooks(self):
        # Codex reports only working, blocked and idle, and idles alike after
        # a turn that ended and one you stopped; its hooks say which.
        task = self.create(agent="codex", programStatus=True, command=[sys.executable, str(FAKE_AGENT), "codex"])
        self.wait_for(task, lambda record: record.get("programStatusRun") == record["runId"])
        self.assertTrue(self.request("send", id=task["id"], text="hello")["ok"])
        self.wait(task, "ready", "Stop")
        self.assertTrue(self.request("send", id=task["id"], text="interrupt")["ok"])
        self.wait(task, "ready", "Interrupt")
        # An approval shows before the command ends.
        self.assertTrue(self.request("send", id=task["id"], text="ask sleep 2")["ok"])
        record = self.wait(task, "permission")
        self.assertEqual(record["request"], "Asks to run sleep 2")
        roost.tmux(self.socket, "send-keys", "-t", task["paneId"], "yes", "Enter")
        record = self.wait(task, "running", "Approved")
        self.assertNotIn("request", record)
        self.wait(task, "ready", "Stop")
        self.assertTrue(self.request("send", id=task["id"], text="ask make")["ok"])
        self.wait(task, "permission")
        roost.tmux(self.socket, "send-keys", "-t", task["paneId"], "decline", "Enter")
        self.wait(task, "ready", "Interrupt")
        # Codex works on while a command it left running runs, but waits for you.
        self.assertTrue(self.request("send", id=task["id"], text="background")["ok"])
        self.wait(task, "ready", "Stop")

    def test_pi_says_when_a_dialog_waits_on_you(self):
        for agent, relayed in (("pi", True), ("pi", False), ("pi-old", False)):
            with self.subTest(agent=agent, relayed=relayed):
                task = self.create(name=agent, agent="pi", programStatus=relayed,
                                   command=[sys.executable, str(FAKE_AGENT), agent])
                if relayed:
                    self.wait_for(task, lambda record: record.get("programStatusRun") == record["runId"])
                self.assertTrue(self.request("send", id=task["id"], text="dialog")["ok"])
                if agent == "pi-old":
                    # Older Pi says nothing of its dialogs.
                    self.wait_for(task, lambda record: record["status"] == "running")
                else:
                    record = self.wait(task, "permission")
                    self.assertEqual(record["request"], "Allow [2J bash?")
                roost.tmux(self.socket, "send-keys", "-t", task["paneId"], "yes", "Enter")
                if agent != "pi-old":
                    self.assertNotIn("request", self.wait(task, "running"))
                self.wait(task, "ready", "Stop")
                self.assertTrue(self.request("send", id=task["id"], text="interrupt")["ok"])
                self.wait(task, "ready", "Stop" if agent == "pi-old" else "Interrupt")
                if agent != "pi-old":
                    # A dialog between runs waits on you too, and ends no turn.
                    self.assertTrue(self.request("send", id=task["id"], text="rest dialog")["ok"])
                    self.assertEqual(self.wait(task, "permission")["request"], "Trust this project?")
                    roost.tmux(self.socket, "send-keys", "-t", task["paneId"], "yes", "Enter")
                    record = self.wait_for(task, lambda record: record["status"] == "ready"
                                           and record.get("lastEvent") not in ("Interrupt", "Stop"))
                    self.assertNotIn("request", record)
                self.assertTrue(self.request("retire", id=task["id"])["ok"])

    def test_opencode_says_what_waits_on_you_and_how_turns_end(self):
        reply = self.request("create", directory=str(self.repo), name="opencode", socket=self.socket,
                             agent="opencode", prompt="-first", command=[sys.executable, str(FAKE_AGENT), "opencode"])
        self.assertTrue(reply["ok"], reply)
        task = reply["result"]
        record = self.wait(task, "ready", "Stop")
        session = record["agentSession"]
        self.assertEqual(roost.last_message(record), "opencode says -first")
        self.assertTrue(self.request("send", id=task["id"], text="permission")["ok"])
        self.assertEqual(self.wait(task, "permission")["request"], "Asks to run make deploy")
        roost.tmux(self.socket, "send-keys", "-t", task["paneId"], "yes", "Enter")
        self.wait(task, "ready", "Stop")
        # A subagent's question waits on you, in a session that isn't the task's.
        self.assertTrue(self.request("send", id=task["id"], text="subagent")["ok"])
        record = self.wait(task, "permission")
        self.assertEqual((record["request"], record["agentSession"]), ("Asks: Which branch?", session))
        roost.tmux(self.socket, "send-keys", "-t", task["paneId"], "main", "Enter")
        self.assertNotIn("request", self.wait(task, "ready", "Stop"))
        self.assertTrue(self.request("send", id=task["id"], text="interrupt")["ok"])
        self.wait(task, "ready", "Interrupt")
        self.assertTrue(self.request("send", id=task["id"], text="fail")["ok"])
        record = self.wait(task, "failed", "StopFailure")
        self.assertEqual(record["error"], "Its turn ended on an error (APIError): Rate limited")
        self.assertTrue(self.request("retire", id=task["id"])["ok"])

    def test_provider_flags_are_checked_before_worktree_creation(self):
        before = self.git("worktree", "list", "--porcelain")
        for agent, flags in (("codex", ["resume", "last"]), ("codex", ["--cd=/other"]),
                             ("pi", ["--session=other"]), ("pi", ["--mode", "rpc"]), ("pi", ["--print"]),
                             ("opencode", ["-s", "ses_other"]), ("opencode", ["--prompt=x"]),
                             ("opencode", ["run", "x"]), ("opencode", ["--fork"]), ("opencode", ["--pure"]),
                             # A project folder would take the agent out of the task's worktree.
                             ("opencode", [str(self.repo)]),
                             ("opencode", ["--model", "lmstudio/qwen", "--port=0", str(self.repo)]),
                             # Roost's options, after it, would be no options.
                             ("opencode", ["--"]), ("opencode", ["--port", "4096", "--", "anything"])):
            with self.subTest(agent=agent, flags=flags):
                reply = self.request("create", directory=str(self.repo), name="bad", socket=self.socket,
                                     agent=agent, command=[agent, *flags])
                self.assertFalse(reply["ok"], reply)
                self.assertEqual(self.git("worktree", "list", "--porcelain"), before)
        # Options' values are no project folder.
        for flags in (["--model", "lmstudio/qwen", "--agent", "plan"], ["-m", "x", "--cors", "a", "b", "--mini"],
                      ["--log-level=DEBUG", "--hostname", "localhost"]):
            with self.subTest(flags=flags):
                roost.OpenCodeAgent().validate(["opencode", *flags])
        # Its arguments follow its name, as when a wrapper starts it, and a
        # project folder named like it is still a project folder.
        roost.OpenCodeAgent().validate(["npx", "opencode-ai", "--model", "x"])
        roost.OpenCodeAgent().validate(["env", "OPENCODE_DISABLE_AUTOUPDATE=1", "opencode"])
        for command in (["npx", "opencode-ai", str(self.repo)], ["opencode", "/tmp/opencode-project"],
                        ["npx", "opencode-ai", "/tmp/opencode-project"],
                        # Set by a wrapper, these leave Roost's observer out.
                        ["env", "OPENCODE_PURE=1", "opencode"], ["env", "OPENCODE_CONFIG_CONTENT={}", "opencode"]):
            with self.subTest(command=command), self.assertRaises(roost.RoostError):
                roost.OpenCodeAgent().validate(command)

    def test_pi_queued_work_is_background_and_codex_interrupt_is_ready(self):
        self.assertEqual(roost.PiAgent().observe(dict(event="agent_end", pending=True))["status"], "background")
        # Ready, and named as an interruption, so Emacs shows it interrupted.
        interrupted = roost.CodexAgent().observe(dict(hook_event_name="Interrupt"))
        self.assertEqual((interrupted["status"], interrupted["lastEvent"]), ("ready", "Interrupt"))
        self.assertIsNone(roost.PiAgent().observe(dict(event="unknown")))
        self.assertIsNone(roost.CodexAgent().observe(dict(hook_event_name="SubagentStop")))

    def test_initial_prompts_are_literal_and_not_replayed_on_resume(self):
        store = roost.Store(str(self.state))
        for name, adapter in (("claude", roost.ClaudeAgent()), ("codex", roost.CodexAgent()),
                              ("pi", roost.PiAgent()), ("opencode", roost.OpenCodeAgent())):
            for prompt in ("--help", "- a list\n- of steps", "@private-file", "literal $() `ticks`\nsecond line"):
                with self.subTest(agent=name, prompt=prompt):
                    task = dict(id="1234567890abcdef", command=[name], prompt=prompt, agentSession="recorded-session",
                                runId="run")
                    argv = adapter.launch(store, task, False)
                    if name in ("claude", "codex"):
                        self.assertEqual(argv[-2:], ["--", prompt])
                    elif name == "opencode":
                        self.assertEqual(argv[-1], "--prompt=" + prompt)
                    else:
                        self.assertNotIn("--", argv)
                        self.assertEqual(argv[-1], "\n" + prompt)
                    resumed = adapter.launch(store, task, True)
                    self.assertEqual(resumed[-1], "recorded-session")
                    self.assertNotIn(prompt, resumed)

    def test_claude_reads_its_tasks_attachments_without_asking(self):
        store = roost.Store(str(self.state))
        task = dict(id="1234567890abcdef", command=["claude"], prompt="Look", agentSession="recorded-session",
                    runId="run")
        folder = store.attachments(task["id"])
        for resume in (False, True):
            argv = roost.ClaudeAgent().launch(store, task, resume)
            # Its own folder only, which exists, and named with "=", so
            # nothing after it is taken for another folder.
            self.assertIn("--add-dir=" + str(folder), argv)
            self.assertTrue(folder.is_dir())
        self.assertEqual(argv[-2:], ["--resume", "recorded-session"])

    def test_adapter_launch_failure_marks_the_task_failed(self):
        task = self.create()
        self.request("stop", id=task["id"])
        store = roost.Store(str(self.state))
        record = store.read(task["id"])
        record["status"] = "starting"
        store.save(record)
        with patch.object(roost.ClaudeAgent, "launch", side_effect=OSError("cannot write observer")):
            self.assertEqual(roost.runner(str(self.state), task["id"], record["runId"]), 1)
        failed = store.read(task["id"])
        self.assertEqual(failed["status"], "failed")
        self.assertIn("cannot write observer", failed["error"])

    def test_partial_retirement_can_be_retried_after_branch_deletion(self):
        task = self.create()
        with patch.object(roost.Store, "remove", side_effect=OSError("simulated disconnect after cleanup")):
            self.assertFalse(self.request("retire", id=task["id"])["ok"])
        self.assertFalse(Path(task["worktree"]).exists())
        self.assertFalse(roost.ref_exists(self.repo, task["branch"]))
        self.assertTrue(self.request("retire", id=task["id"])["ok"])
        self.assertEqual(self.request("list")["result"], [])

    def test_removing_a_worktree_lets_hooks_in_but_nothing_else(self):
        # A worktree with dependencies installed takes seconds to delete,
        # and every agent's hooks wait on the registry lock.
        git = roost.git
        task = self.create()
        during = []

        def removing(repo, *args, **kwargs):
            if args[:2] == ("worktree", "remove"):
                with open(self.state / "registry.lock", "a") as lock:
                    fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)  # Free, or this raises.
                    fcntl.flock(lock, fcntl.LOCK_UN)
                # A retry after Emacs gave up waiting, or a resume, waits its
                # turn; seeing the agent is recorded.
                during.append([self.request(action, id=task["id"])["error"]
                               for action in ("resume", "retire", "discard", "forget")])
                self.assertTrue(self.request("seen", id=task["id"], updatedAt="seen meanwhile")["ok"])
                if failing:
                    raise roost.RoostError("simulated failure")
            return git(repo, *args, **kwargs)

        # Should it fail, the task can be started again, and what was
        # recorded meanwhile stays.
        failing = True
        with patch.object(roost, "git", side_effect=removing):
            self.assertFalse(self.request("retire", id=task["id"])["ok"])
        self.assertTrue(all("still removing" in error for error in during[0]), during)
        record = roost.Store(str(self.state)).read(task["id"])
        self.assertNotIn("removing", record)
        self.assertEqual(record["seen"], "seen meanwhile")
        self.assertTrue(self.request("resume", id=task["id"])["ok"])
        self.wait(task, "ready")
        failing = False
        with patch.object(roost, "git", side_effect=removing):
            reply = self.request("retire", id=task["id"])
        self.assertTrue(reply["ok"], reply)
        self.assertFalse(Path(task["worktree"]).exists())
        self.assertEqual(self.request("list")["result"], [])

    def test_a_removal_holds_while_a_command_it_started_runs(self):
        # Emacs kills a local request it gave up waiting for, but not the
        # Git deleting files for it, and a retry must not race that Git.
        git = roost.git
        task = self.create()

        def removing(repo, *args, **kwargs):
            if args[:2] == ("worktree", "remove"):
                roost.execute(["sh", "-c", "sleep 1.5 > /dev/null 2>&1 &"])
                raise roost.RoostError("simulated end of the request")
            return git(repo, *args, **kwargs)

        with patch.object(roost, "git", side_effect=removing):
            self.assertFalse(self.request("retire", id=task["id"])["ok"])
        self.assertIn("still removing", self.request("retire", id=task["id"])["error"])
        # Nor may a push for a pull request start there.
        self.assertIn("still removing", self.request("pr", id=task["id"], title="Meanwhile")["error"])
        deadline = time.monotonic() + 8
        while not self.request("retire", id=task["id"])["ok"]:
            self.assertLess(time.monotonic(), deadline)
            time.sleep(0.2)
        self.assertEqual(self.request("list")["result"], [])

    def test_finishing_a_task_waits_for_its_pull_request(self):
        # Pushing and asking GitHub take seconds without the registry lock.
        # Finishing the task meanwhile would delete the worktree under the
        # push, or the record the pull request is then saved in.
        self.github()
        task = self.create()
        tip = self.commit_in(task)
        head = self.git("rev-parse", "HEAD")
        remote_git = roost.remote_git
        during = []

        def pushing(repo, *args, **kwargs):
            if args[:1] == ("push",):
                during.append([self.request(action, id=task["id"], expect=tip).get("error", "")
                               for action in ("retire", "merge", "discard", "forget")])
            return remote_git(repo, *args, **kwargs)

        # Opening the pull request, then pushing to it.
        with patch.object(roost, "remote_git", side_effect=pushing):
            reply = self.request("pr", id=task["id"], title="Fix it")
            self.assertTrue(reply["ok"], reply)
            tip = self.commit_in(task, "more")
            reply = self.request("pr", id=task["id"])
        self.assertTrue(reply["ok"], reply)
        self.assertEqual(reply["result"]["pushed"], 1)
        self.assertEqual(len(during), 2)
        self.assertTrue(all("busy" in error for errors in during for error in errors), during)
        # Nothing was merged or stopped, and the pull request was recorded.
        self.assertEqual(self.git("rev-parse", "HEAD"), head)
        self.assertEqual(self.wait(task, "ready")["pr"]["number"], 7)
        self.assertEqual(self.git("rev-parse", "refs/heads/" + task["branch"], cwd=self.origin), tip)
        # Then the task can be finished.
        self.assertTrue(self.request("discard", id=task["id"], dryRun=True)["ok"])

    def test_a_pull_request_holds_while_a_command_it_started_runs(self):
        # Emacs gives up on a request after a minute, and a push may take
        # longer; finishing the task must wait for it all the same.
        self.github()
        task = self.create()
        self.commit_in(task)

        def held():
            self.assertIn("busy", self.request("retire", id=task["id"])["error"])
            deadline = time.monotonic() + 8
            while "busy" in self.request("retire", id=task["id"])["error"]:
                self.assertLess(time.monotonic(), deadline)
                time.sleep(0.2)

        # What gh started, as it opened the pull request...
        (self.gh_dir / "linger").touch()
        reply = self.request("pr", id=task["id"], title="Slow")
        self.assertTrue(reply["ok"], reply)
        held()
        (self.gh_dir / "linger").unlink()
        # ...and what Git started, as it pushed to it.
        hooks = self.root / "hooks"
        hooks.mkdir()
        (hooks / "pre-push").write_text("#!/bin/sh\nsleep 1.5 > /dev/null 2>&1 &\n")
        (hooks / "pre-push").chmod(0o755)
        self.git("config", "core.hooksPath", str(hooks))
        self.commit_in(task, "more")
        reply = self.request("pr", id=task["id"])
        self.assertTrue(reply["ok"], reply)
        held()

    def test_a_removal_that_stopped_short_can_be_finished(self):
        task = self.create()
        self.request("stop", id=task["id"])
        store = roost.Store(str(self.state))
        record = store.read(task["id"])
        # Marked as going, with nothing holding its lock.
        record["removing"] = "an earlier request"
        store.save(record)
        self.assertIn("when it stopped", self.request("resume", id=task["id"])["error"])
        self.assertTrue(self.request("retire", id=task["id"])["ok"])
        self.assertEqual(self.request("list")["result"], [])

    def test_conflicting_claude_flags_are_rejected_before_worktree_creation(self):
        for flag in ("--settings=other.json", "--worktree", "--resume", "--bare"):
            response = self.request("create", directory=str(self.repo), name="bad flags",
                                    socket=self.socket, command=["claude", flag])
            self.assertFalse(response["ok"], response)
        self.assertEqual(self.git("worktree", "list", "--porcelain").count("worktree "), 1)

    def test_lost_ownership_cannot_send_or_kill_another_window(self):
        task = self.create()
        roost.tmux(self.socket, "set-option", "-p", "-t", task["paneId"], "@roost_task_id", "other")
        self.assertFalse(self.request("send", id=task["id"], text="oops")["ok"])
        self.assertFalse(self.request("inspect", id=task["id"])["ok"])
        self.request("stop", id=task["id"])
        self.assertIn(task["paneId"], roost.pane_inventory(self.socket))

    def test_old_hooks_cannot_overwrite_resumed_run_or_retirement(self):
        task = self.create()
        old = self.wait(task, "ready")
        self.request("stop", id=task["id"])
        self.request("resume", id=task["id"])
        self.wait(task, "ready")
        store = roost.Store(str(self.state))
        roost.update_hook(store, task["id"], dict(hook_event_name="SessionEnd"), old["runId"])
        self.assertEqual(store.read(task["id"])["status"], "ready")
        self.assertTrue(self.request("retire", id=task["id"])["ok"])
        # Retirement deletes the record; a late hook cannot recreate it.
        with self.assertRaises(roost.RoostError):
            roost.update_hook(store, task["id"], dict(hook_event_name="UserPromptSubmit"))
        self.assertFalse(store.path(task["id"]).exists())
        self.assertFalse(store.path(task["id"]).with_suffix(".settings").exists())

    def test_concurrent_hooks_preserve_other_tasks_and_valid_json(self):
        tasks = [self.create(name="task " + str(i)) for i in range(2)]
        def write_event(task):
            store = roost.Store(str(self.state))
            for _ in range(8):
                roost.update_hook(store, task["id"], dict(hook_event_name="Stop"))
        with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:
            list(pool.map(write_event, tasks))
        self.assertEqual(len(self.request("list")["result"]), 2)

    def test_failed_spawn_leaves_no_record_worktree_branch_or_session(self):
        before = self.git("worktree", "list", "--porcelain")
        with patch.object(roost, "enable_extended_keys", side_effect=roost.RoostError("tmux refused")):
            reply = self.request("create", directory=str(self.repo), name="bad spawn", socket=self.socket,
                                 command=[sys.executable, str(FAKE)])
        self.assertEqual(reply, dict(ok=False, error="tmux refused"))
        self.assertEqual(self.request("list")["result"], [])
        self.assertEqual(self.git("worktree", "list", "--porcelain"), before)
        self.assertEqual(self.git("branch", "--list", "roost/*"), "")
        self.assertEqual(roost.pane_inventory(self.socket), {})

    def test_a_task_starts_at_the_size_emacs_asks_for(self):
        size = lambda task: roost.tmux(self.socket, "display-message", "-p", "-t", task["paneId"],
                                       "#{pane_width}x#{pane_height}").stdout.strip()
        task = self.create(name="sized", size=dict(width=137, height=41))
        self.assertEqual(size(task), "137x41")
        self.assertTrue(self.request("stop", id=task["id"])["ok"])
        self.assertTrue(self.request("resume", id=task["id"], size=dict(width=120, height=33))["ok"])
        self.assertEqual(size(self.wait(task, "ready")), "120x33")
        # Nonsense is ignored, as when an older Emacs sends none.
        odd = self.create(name="odd", size=dict(width=True, height="tall"))
        self.assertEqual(size(odd), "80x24")

    def test_a_task_session_ends_with_the_task(self):
        # A session per task held a spare shell window, so each retired task
        # left its session behind.
        first, second = self.create(name="first"), self.create(name="second")
        sessions = lambda: set(roost.tmux(self.socket, "list-sessions", "-F", "#{session_name}",
                                          check=False).stdout.split())
        self.assertEqual(sessions(), {first["session"], second["session"]})
        windows = roost.tmux(self.socket, "list-windows", "-t", "=" + first["session"], "-F", "#{window_id}")
        self.assertEqual(windows.stdout.split(), [first["windowId"]])
        self.assertTrue(self.request("retire", id=first["id"])["ok"])
        self.assertEqual(sessions(), {second["session"]})
        self.assertTrue(self.request("stop", id=second["id"])["ok"])
        self.assertEqual(sessions(), set())
        # Resuming starts its session again, under the same name.
        self.assertTrue(self.request("resume", id=second["id"])["ok"])
        self.assertEqual(self.wait(second, "ready")["session"], second["session"])
        self.assertEqual(sessions(), {second["session"]})

    def test_a_session_an_older_emacs_asks_for_is_its_own_anyway(self):
        # roost-session-name used to put tasks in one session; each now has its own.
        task = self.create(name="odd session", session="odd:name.x")
        self.assertEqual(task["session"], roost.session_name(task["repo"], task["id"]))

    def test_detached_primary_task_retires_when_empty_and_forgets_when_not(self):
        self.git("checkout", "-q", "--detach")
        empty = self.create(name="empty")
        self.assertEqual(empty["integrationBranch"], "")
        # A fork has no branch to merge into either, though the primary has one now.
        self.git("checkout", "-q", "main")
        fork = self.create(name="fork", directory=empty["worktree"], base="HEAD")
        self.assertEqual(fork["integrationBranch"], "")
        self.request("stop", id=fork["id"])
        self.assertTrue(self.request("retire", id=fork["id"])["ok"])
        self.git("checkout", "-q", "--detach")
        self.request("stop", id=empty["id"])
        self.assertTrue(self.request("retire", id=empty["id"])["ok"])
        worked = self.create(name="worked")
        wt = Path(worked["worktree"])
        (wt / "hello").write_text("work\n")
        self.git("commit", "-qam", "work", cwd=wt)
        self.request("stop", id=worked["id"])
        merge = self.request("merge", id=worked["id"])
        self.assertIn("detached HEAD", merge["error"])
        self.assertIn("forget", self.request("retire", id=worked["id"])["error"])
        forgotten = self.request("forget", id=worked["id"])["result"]
        self.assertEqual(forgotten["status"], "forgotten")
        self.assertEqual(forgotten["leftBehind"], ["worktree " + worked["worktree"], "branch " + worked["branch"]])
        self.assertEqual(self.request("list")["result"], [])
        self.assertEqual(self.git("show", worked["branch"] + ":hello"), "work")

    def test_retire_keeps_a_fork_whose_parent_branch_is_gone(self):
        parent = self.create(name="parent")
        wt = Path(parent["worktree"])
        (wt / "hello").write_text("parent work\n")
        self.git("commit", "-qam", "parent work", cwd=wt)
        reply = self.request("create", directory=str(wt), name="child", socket=self.socket, base="HEAD",
                             command=[sys.executable, str(FAKE)])
        child = self.wait(reply["result"], "ready")
        self.request("stop", id=parent["id"])
        self.request("forget", id=parent["id"])
        self.git("worktree", "remove", "--force", parent["worktree"])
        self.git("branch", "-D", parent["branch"])
        self.request("stop", id=child["id"])
        # The child's branch is now the only ref to the parent's commit.
        self.assertIn("unmerged commits", self.request("retire", id=child["id"])["error"])
        self.assertTrue(roost.ref_exists(self.repo, child["branch"]))

    def test_changes_after_an_update_are_only_the_tasks_own(self):
        task = self.create()
        wt = Path(task["worktree"])
        (wt / "task").write_text("task\n")
        self.git("add", ".", cwd=wt)
        self.git("commit", "-qm", "task", cwd=wt)
        (self.repo / "other").write_text("main moved\nand again\n")
        self.git("add", ".")
        self.git("commit", "-qm", "main moved")
        self.assertEqual(self.request("list", full=True)["result"][0]["behind"], 1)
        self.assertTrue(self.request("update", id=task["id"])["ok"])
        listed = self.request("list", full=True)["result"][0]
        self.assertEqual((listed["ahead"], listed["behind"]), (1, 0))
        self.assertEqual(listed["diff"], "1 file changed, 1 insertion(+)")

    def test_update_allows_untracked_files_and_lists_missing_worktrees(self):
        task = self.create()
        wt = Path(task["worktree"])
        (wt / "scratch.txt").write_text("not tracked\n")
        (self.repo / "other").write_text("main moved\n")
        self.git("add", ".")
        self.git("commit", "-qm", "main moved")
        self.assertTrue(self.request("update", id=task["id"])["result"]["update"]["changed"])
        self.request("stop", id=task["id"])
        self.git("worktree", "remove", "--force", task["worktree"])
        self.assertTrue(self.request("list", full=True)["result"][0]["worktreeMissing"])

    def test_retire_finishes_when_worktree_and_branch_were_removed_by_hand(self):
        task = self.create()
        self.request("stop", id=task["id"])
        self.git("worktree", "remove", task["worktree"])
        self.git("branch", "-D", task["branch"])
        self.assertTrue(self.request("retire", id=task["id"])["ok"])
        self.assertEqual(self.request("list")["result"], [])

    def test_discard_says_what_it_would_lose_then_deletes_everything(self):
        task = self.create()
        wt = Path(task["worktree"])
        (wt / "hello").write_text("changed\n")
        self.git("commit", "-qam", "one", cwd=wt)
        (wt / "hello").write_text("changed again\n")
        (wt / "new").write_text("untracked\n")
        told = self.request("discard", id=task["id"], dryRun=True)["result"]["discard"]
        self.assertEqual((told["commits"], told["changes"]), (1, 2))
        # Nothing changed yet.
        self.assertIn(task["paneId"], roost.pane_inventory(self.socket))
        # A commit since then: refused.
        self.git("commit", "-qam", "two", cwd=wt)
        self.assertIn("moved", self.request("discard", id=task["id"], expect=told["commit"])["error"])
        told = self.request("discard", id=task["id"], dryRun=True)["result"]["discard"]
        self.assertEqual((told["commits"], told["changes"]), (2, 1))
        reply = self.request("discard", id=task["id"], expect=told["commit"])
        self.assertTrue(reply["ok"], reply)
        self.assertEqual(reply["result"]["status"], "discarded")
        self.assertFalse(wt.exists())
        self.assertFalse(roost.ref_exists(self.repo, task["branch"]))
        self.assertNotIn(task["paneId"], roost.pane_inventory(self.socket) or {})
        self.assertEqual(self.request("list")["result"], [])
        self.assertEqual(self.git("show", "HEAD:hello"), "base")

    def test_discard_counts_only_commits_no_other_branch_holds(self):
        task = self.create()
        wt = Path(task["worktree"])
        (wt / "hello").write_text("changed\n")
        self.git("commit", "-qam", "kept elsewhere", cwd=wt)
        self.git("branch", "keep", task["branch"])
        told = self.request("discard", id=task["id"], dryRun=True)["result"]["discard"]
        self.assertEqual((told["commits"], told["changes"]), (0, 0))
        self.assertTrue(self.request("discard", id=task["id"], expect=told["commit"])["ok"])
        self.assertTrue(roost.ref_exists(self.repo, "keep"))

    def test_work_in_a_worktree_the_agent_made_keeps_the_task_from_retiring(self):
        task = self.create()
        store = roost.Store(str(self.state))
        settings = json.loads(store.path(task["id"]).with_suffix(".settings").read_text())
        self.assertEqual(settings["worktree"], {"baseRef": "head"})
        # Claude makes its own worktrees in the primary checkout's .claude/worktrees.
        own = self.repo / ".claude" / "worktrees" / "probe"
        self.git("worktree", "add", "-q", "-b", "worktree-probe", str(own), task["branch"])
        roost.update_hook(store, task["id"], dict(hook_event_name="UserPromptSubmit", cwd=str(own / "src")),
                          task["runId"])
        roost.update_hook(store, task["id"], dict(hook_event_name="Stop", cwd=str(own)), task["runId"])
        self.assertEqual(store.read(task["id"])["agentWorktrees"], [str(own.resolve())])
        listed = self.request("list", full=True)["result"][0]
        self.assertEqual(listed["agentWork"], [dict(path=str(own.resolve()), branch="worktree-probe",
                                                    ahead=0, dirty=False)])
        (own / "hello").write_text("made there\n")
        self.git("commit", "-qam", "there", cwd=own)
        listed = self.request("list", full=True)["result"][0]
        self.assertEqual(listed["agentWork"][0]["ahead"], 1)
        error = self.request("retire", id=task["id"])["error"]
        self.assertIn("left work in its own worktree", error)
        self.assertIn("1 commit not on the task's branch", error)
        self.assertIn(task["paneId"], roost.pane_inventory(self.socket))
        self.git("worktree", "remove", "--force", str(own))
        self.assertTrue(self.request("retire", id=task["id"])["ok"])

    def test_discard_a_task_whose_agent_moved_to_another_branch(self):
        # The case for throwing it away; it used to be refused.
        task = self.create()
        wt = Path(task["worktree"])
        self.git("checkout", "-q", "-b", "agent-idea", cwd=wt)
        (wt / "hello").write_text("idea\n")
        self.git("commit", "-qam", "idea", cwd=wt)
        self.git("checkout", "-q", "--detach", cwd=wt)
        (wt / "hello").write_text("detached\n")
        self.git("commit", "-qam", "detached", cwd=wt)
        told = self.request("discard", id=task["id"], dryRun=True)["result"]["discard"]
        # The detached commit is lost; agent-idea keeps its own.
        self.assertEqual(told["commits"], 1)
        self.assertTrue(self.request("discard", id=task["id"], expect=told["commit"])["ok"])
        self.assertFalse(wt.exists())
        self.assertTrue(roost.ref_exists(self.repo, "agent-idea"))

    def test_discard_takes_the_agents_own_worktrees_with_it(self):
        task = self.create()
        store = roost.Store(str(self.state))
        own = self.repo / ".claude" / "worktrees" / "probe"
        self.git("worktree", "add", "-q", "-b", "worktree-probe", str(own), task["branch"])
        self.git("worktree", "lock", "--reason", "claude session probe", str(own))
        roost.update_hook(store, task["id"], dict(hook_event_name="Stop", cwd=str(own)), task["runId"])
        (own / "hello").write_text("there\n")
        self.git("commit", "-qam", "there", cwd=own)
        (own / "scratch").write_text("untracked\n")
        told = self.request("discard", id=task["id"], dryRun=True)["result"]["discard"]
        self.assertEqual((told["commits"], told["changes"], told["agentWorktrees"]), (1, 1, 1))
        self.assertTrue(self.request("discard", id=task["id"], expect=told["commit"])["ok"])
        self.assertFalse(own.exists())
        self.assertFalse(roost.ref_exists(self.repo, "worktree-probe"))

    def test_retiring_removes_the_agents_empty_worktrees(self):
        task = self.create()
        store = roost.Store(str(self.state))
        own = self.repo / ".claude" / "worktrees" / "probe"
        self.git("worktree", "add", "-q", "-b", "worktree-probe", str(own), task["branch"])
        self.git("worktree", "lock", "--reason", "claude session probe", str(own))
        roost.update_hook(store, task["id"], dict(hook_event_name="Stop", cwd=str(own)), task["runId"])
        self.assertTrue(self.request("retire", id=task["id"])["ok"])
        self.assertFalse(own.exists())
        self.assertFalse(roost.ref_exists(self.repo, "worktree-probe"))

    def test_renaming_a_task_names_its_window_and_keeps_its_branch(self):
        task = self.create(name="parser")
        store = roost.Store(str(self.state))
        seen = self.request("seen", id=task["id"], updatedAt=store.read(task["id"])["updatedAt"])["result"]
        window = lambda: roost.tmux(self.socket, "display-message", "-p", "-t", task["windowId"],
                                    "#{window_name}").stdout.strip()
        reply = self.request("rename", id=task["id"], name="  fix #12 in the parser ")
        self.assertTrue(reply["ok"], reply)
        renamed = reply["result"]
        self.assertTrue(renamed["live"])
        self.assertEqual(renamed["name"], "fix #12 in the parser")
        self.assertTrue(renamed["renamedAt"])
        # Started without a prompt, it is described by its name.
        self.assertEqual(renamed["task"], "fix #12 in the parser")
        self.assertEqual((renamed["branch"], renamed["worktree"]), (task["branch"], task["worktree"]))
        self.assertEqual(window(), "fix #12 in the parser")
        self.assertTrue(self.request("rename", id=task["id"], name="-v for the parser")["ok"])
        self.assertEqual(window(), "-v for the parser")
        self.assertTrue(self.request("rename", id=task["id"], name="fix #12 in the parser")["ok"])
        listed = self.request("list")["result"][0]
        self.assertEqual(listed["name"], "fix #12 in the parser")
        # Not an event: you have still seen it.
        self.assertEqual((listed["seen"], listed["updatedAt"]), (seen["seen"], seen["updatedAt"]))
        for name in ("", " ", "!!!", "tab\there", None):
            with self.subTest(name=name):
                self.assertFalse(self.request("rename", id=task["id"], name=name)["ok"])
        # tmux not answering is no reason to think the window gone: try again.
        with patch.object(roost, "pane_inventory", return_value=None):
            self.assertIn("tmux did not answer", self.request("rename", id=task["id"], name="parser")["error"])
        self.assertEqual(store.read(task["id"])["name"], "fix #12 in the parser")
        # A stopped task has no window to name; the one it resumes in has its name.
        self.assertTrue(self.request("stop", id=task["id"])["ok"])
        self.assertIs(self.request("rename", id=task["id"], name="parser fix")["result"]["live"], False)
        self.request("resume", id=task["id"])
        task = self.wait(task, "ready")
        self.assertEqual(window(), "parser fix")
        # A prompt stays the prompt, though the task was named after it.
        for prompt in ("Write the docs", "docs"):
            with self.subTest(prompt=prompt):
                prompted = self.create(name="docs", prompt=prompt)
                self.assertEqual(self.request("rename", id=prompted["id"], name="manual")["result"]["task"],
                                 prompt)

    def test_seen_is_recorded_for_every_emacs_until_the_next_event(self):
        task = self.create()
        record = self.wait(task, "ready")
        reply = self.request("seen", id=task["id"], updatedAt=record["updatedAt"])
        self.assertTrue(reply["ok"], reply)
        listed = self.request("list")["result"][0]
        self.assertEqual(listed["seen"], record["updatedAt"])
        self.assertEqual(listed["updatedAt"], record["updatedAt"])
        # Not an event of the agent's: nothing else changes.
        self.assertEqual(listed["status"], "ready")

    def since_looked(self, task):
        return self.request("list", full=[task["id"]])["result"][0]["sinceLooked"]

    def test_a_look_keeps_uncommitted_work_without_staging_it_or_adding_refs(self):
        task = self.create()
        wt = Path(task["worktree"])
        self.commit_in(task, "done")
        (wt / "hello").write_text("edited\n")
        (wt / "new file").write_text("new\n")
        (wt / "staged").write_text("staged\n")
        self.git("add", "staged", cwd=wt)
        index = Path(self.git("rev-parse", "--path-format=absolute", "--git-path", "index", cwd=wt))
        # Git runs this on writing any index, the copy a look stages in too.
        hook = Path(self.git("rev-parse", "--path-format=absolute", "--git-path", "hooks", cwd=wt)) / "post-index-change"
        hook.parent.mkdir(exist_ok=True)
        hook.write_text("#!/bin/sh\ntouch %s\n" % shlex.quote(str(self.root / "hook ran")))
        hook.chmod(0o755)
        before = (index.read_bytes(), self.git("for-each-ref"), self.git("status", "--porcelain", cwd=wt),
                  self.git("stash", "list"))
        (self.root / "hook ran").unlink(missing_ok=True)
        self.assertIsNone(self.since_looked(task), "never looked")
        reply = self.request("look", id=task["id"])
        self.assertTrue(reply["ok"], reply)
        self.assertEqual(self.since_looked(task)["count"], 0)
        self.assertFalse((self.root / "hook ran").exists(), "your hooks run for your own Git commands only")
        hook.unlink()
        looked = reply["result"]["looked"]
        self.assertEqual(reply["result"]["sinceLooked"]["count"], 0)
        self.assertEqual(looked["head"], self.git("rev-parse", "HEAD", cwd=wt))
        # A commit of everything there, which nothing points at.
        self.assertEqual(self.git("show", looked["commit"] + ":new file", cwd=wt), "new")
        self.assertEqual(self.git("show", looked["commit"] + ":hello", cwd=wt), "edited")
        self.assertEqual(self.git("rev-parse", looked["commit"] + "^", cwd=wt), looked["head"])
        self.assertEqual(before, (index.read_bytes(), self.git("for-each-ref"),
                                  self.git("status", "--porcelain", cwd=wt), self.git("stash", "list")))
        self.assertEqual(self.since_looked(task)["count"], 0)
        self.assertEqual(self.since_looked(task)["at"], looked["at"])
        # Committing what you saw, then amending its message, changes nothing you saw.
        self.git("add", "-A", cwd=wt)
        self.git("commit", "-qm", "all", cwd=wt)
        self.git("commit", "-q", "--amend", "-m", "all of it", cwd=wt)
        self.assertEqual(self.since_looked(task)["count"], 0)
        (wt / "new file").write_text("new\nmore\n")
        (wt / "another").write_text("another\n")
        self.assertEqual(self.since_looked(task), dict(count=2, added=2, deleted=0, at=looked["at"]))
        # Committed or not, it changed since.
        self.git("add", "-A", cwd=wt)
        self.git("commit", "-q", "--amend", "--no-edit", cwd=wt)
        self.assertEqual(self.since_looked(task)["count"], 2)
        self.git("rm", "-q", "staged", cwd=wt)
        self.assertEqual(self.since_looked(task)["count"], 3, "removed since, staged or not")
        self.git("commit", "-qm", "Remove staged", cwd=wt)
        again = self.request("look", id=task["id"])["result"]["looked"]
        self.assertEqual(again["commit"], again["head"], "nothing uncommitted: HEAD is where it stands")
        since = again["since"]
        self.assertEqual((since["start"], since["at"], since["count"]), (looked["commit"], looked["at"], 3))
        self.assertEqual(sorted(file["path"] for file in since["files"]), ["another", "new file", "staged"])
        self.assertEqual(self.since_looked(task)["count"], 0)
        # Looking again at what you saw last keeps what changed before it.
        self.assertEqual(self.request("look", id=task["id"])["result"]["looked"]["since"], since)

    def test_since_you_looked_leaves_out_what_an_update_brought_in(self):
        task = self.create()
        wt = Path(task["worktree"])
        self.commit_in(task, "mine")
        self.assertTrue(self.request("look", id=task["id"])["ok"])
        (self.repo / "theirs").write_text("main moved\n")
        (self.repo / "hello").write_text("main changed it\n")
        self.git("add", ".")
        self.git("commit", "-qm", "main moved")
        self.assertTrue(self.request("update", id=task["id"])["result"]["update"]["changed"])
        self.assertEqual(self.since_looked(task)["count"], 0, "main's changes are not the task's")
        (wt / "mine").write_text("mine, changed\n")
        self.assertEqual(self.since_looked(task)["count"], 1)
        looked = self.request("look", id=task["id"])["result"]["looked"]
        self.assertEqual([file["path"] for file in looked["since"]["files"]], ["mine"])
        # Magit's diff of them leaves out what main changed too.
        self.assertEqual(looked["since"]["paths"], ["mine"])
        self.assertEqual(looked["since"]["end"], looked["commit"])
        # Once more from main alone: what changed before keeps both its ends.
        self.git("commit", "-qam", "Mine, changed", cwd=wt)
        (self.repo / "more").write_text("main again\n")
        self.git("add", ".")
        self.git("commit", "-qm", "main again")
        self.assertTrue(self.request("update", id=task["id"])["result"]["update"]["changed"])
        again = self.request("look", id=task["id"])["result"]["looked"]
        self.assertEqual(again["since"], looked["since"])
        self.assertNotEqual(again["commit"], looked["since"]["end"])

    def test_a_look_git_cannot_keep_leaves_the_look_before(self):
        task = self.create()
        wt = Path(task["worktree"])
        before = self.request("look", id=task["id"])["result"]["looked"]
        (wt / "hello").write_text("edited\n")
        objects = Path(self.git("rev-parse", "--path-format=absolute", "--git-common-dir", cwd=wt)) / "objects"
        folders = [objects] + [path for path in objects.rglob("*") if path.is_dir()]
        for folder in folders:
            folder.chmod(0o555)
        try:
            reply = self.request("look", id=task["id"])
        finally:
            for folder in folders:
                folder.chmod(0o755)
        self.assertFalse(reply["ok"], reply)
        self.assertEqual(roost.Store(str(self.state)).read(task["id"])["looked"], before)
        self.assertEqual(self.since_looked(task)["count"], 1)

    def test_notes_that_fail_to_go_record_no_look(self):
        task = self.create()
        (Path(task["worktree"]) / "hello").write_text("edited\n")
        self.request("stop", id=task["id"])
        reply = self.request("send", id=task["id"], text="Note", look=True)
        self.assertFalse(reply["ok"], reply)
        self.assertNotIn("looked", roost.Store(str(self.state)).read(task["id"]))

    def test_what_git_cannot_stage_since_a_look_is_unknown_not_unchanged(self):
        task = self.create()
        self.request("look", id=task["id"])
        (Path(task["worktree"]) / "new").write_text("new\n")
        real = roost.execute

        def execute(argv, **kw):
            if "--intent-to-add" not in argv:
                return real(argv, **kw)
            # As Git fails when it can't write its empty file.
            failed = real(["sh", "-c", "echo 'error: insufficient permission' >&2; exit 128"], check=False)
            if kw.get("check", True):
                raise roost.RoostError(failed.stderr.strip())
            return failed

        with patch.object(roost, "execute", execute):
            listed = self.request("list", full=[task["id"]])
        self.assertTrue(listed["ok"], listed)
        self.assertIsNone(listed["result"][0]["sinceLooked"])
        # Nor does a temporary folder with no room fail the listing.
        with patch.object(roost.tempfile, "mkdtemp", side_effect=OSError(28, "No space left on device")):
            listed = self.request("list", full=[task["id"]])
        self.assertTrue(listed["ok"], listed)
        self.assertIsNone(listed["result"][0]["sinceLooked"])
        self.assertEqual(self.since_looked(task)["count"], 1)

    def test_a_look_counts_a_submodules_commit_not_what_is_uncommitted_in_it(self):
        task = self.create()
        wt = Path(task["worktree"])
        library = self.root / "library"
        library.mkdir()
        self.git("init", "-q", "-b", "main", cwd=library)
        (library / "lib").write_text("lib\n")
        self.git("add", ".", cwd=library)
        self.git("-c", "user.name=t", "-c", "user.email=t@t", "commit", "-qm", "lib", cwd=library)
        self.git("-c", "protocol.file.allow=always", "submodule", "add", "-q", str(library), "lib", cwd=wt)
        self.git("commit", "-qm", "Add lib", cwd=wt)
        (wt / "lib" / "lib").write_text("edited inside\n")
        self.assertTrue(self.request("look", id=task["id"])["ok"])
        self.assertEqual(self.since_looked(task)["count"], 0)
        # A new commit there is a change, as the task's own commit of it would be.
        self.git("-c", "user.name=t", "-c", "user.email=t@t", "commit", "-qam", "more", cwd=wt / "lib")
        self.assertEqual(self.since_looked(task)["count"], 1)
        # Its worktree can't go with a submodule checked out.
        shutil.rmtree(wt / "lib")
        self.git("rm", "-q", "--cached", "lib", cwd=wt)

    def test_a_look_git_cannot_compare_leaves_the_look_before(self):
        task = self.create()
        self.request("look", id=task["id"])
        self.commit_in(task, "more")
        before = roost.Store(str(self.state)).read(task["id"])["looked"]
        with patch.object(roost, "changed_between", lambda *args, **kw: None):
            reply = self.request("look", id=task["id"])
        self.assertIn("could not compare", reply["error"])
        self.assertEqual(roost.Store(str(self.state)).read(task["id"])["looked"], before)

    def test_a_look_recorded_meanwhile_is_not_overwritten(self):
        task = self.create()
        store = roost.Store(str(self.state))
        real, meanwhile = roost.snapshot, []

        def snapshot(worktree):
            if not meanwhile:
                # Another Emacs looks while this look is under way.
                meanwhile.append(None)
                meanwhile[0] = roost.look(store, task["id"])["looked"]
            return real(worktree)

        with patch.object(roost, "snapshot", snapshot):
            reply = self.request("look", id=task["id"])
        self.assertTrue(reply["ok"], reply)
        self.assertEqual(store.read(task["id"])["looked"], meanwhile[0])
        self.assertEqual(reply["result"]["looked"], meanwhile[0])
        # What changed since that look is for the next measurement to say.
        self.assertNotIn("sinceLooked", reply["result"])

    def test_what_changed_before_goes_once_git_has_pruned_where_from(self):
        task = self.create()
        wt = Path(task["worktree"])
        self.request("look", id=task["id"])
        self.commit_in(task, "more")
        since = self.request("look", id=task["id"])["result"]["looked"]["since"]
        self.assertEqual(self.request("look", id=task["id"])["result"]["looked"]["since"], since)
        store = roost.Store(str(self.state))
        record = store.read(task["id"])
        store.save(dict(record, looked=dict(record["looked"], since=dict(since, start="0" * 40))))
        self.assertNotIn("since", self.request("look", id=task["id"])["result"]["looked"])

    def test_notes_sent_record_a_look_before_the_agent_has_them(self):
        task = self.create()
        (Path(task["worktree"]) / "hello").write_text("edited\n")
        reply = self.request("send", id=task["id"], text="permission", look=True)
        self.assertTrue(reply["ok"], reply)
        self.assertEqual(reply["result"]["sinceLooked"]["count"], 0)
        record = self.wait(task, "permission")
        self.assertEqual(self.git("show", record["looked"]["commit"] + ":hello", cwd=task["worktree"]), "edited")
        self.assertNotIn("sinceLooked", record, "measured, not recorded")
        self.assertEqual(reply["result"]["looked"], record["looked"])
        # Without notes, a prompt is no look.
        again = self.request("send", id=task["id"], text="interrupt", force=True)
        self.assertNotIn("sinceLooked", again["result"])
        self.assertEqual(roost.Store(str(self.state)).read(task["id"])["looked"], record["looked"])

    def test_a_look_leaves_out_large_untracked_files_and_outlives_its_commit(self):
        task = self.create()
        wt = Path(task["worktree"])
        (wt / "data").write_bytes(b"x" * (roost.LOOK_FILE_LIMIT + 1))
        (wt / "small").write_text("small\n")
        looked = self.request("look", id=task["id"])["result"]["looked"]
        self.assertEqual(roost.git(wt, "cat-file", "-e", looked["commit"] + ":small", check=False).returncode, 0)
        self.assertNotEqual(roost.git(wt, "cat-file", "-e", looked["commit"] + ":data", check=False).returncode, 0)
        (wt / "data").write_bytes(b"y" * (roost.LOOK_FILE_LIMIT + 1))
        self.assertEqual(self.since_looked(task)["count"], 0)
        # Kept once, then grown past the limit, it is still there, not gone.
        (wt / "small").write_bytes(b"z" * (roost.LOOK_FILE_LIMIT + 1))
        self.assertEqual(self.since_looked(task)["count"], 0)
        (wt / "other").write_text("other\n")
        since = self.request("look", id=task["id"])["result"]["looked"]["since"]
        self.assertEqual((since["count"], since["paths"]), (1, ["other"]))
        (wt / "other").unlink()
        (wt / "small").write_text("small\n")
        looked = self.request("look", id=task["id"])["result"]["looked"]
        # Once Git has pruned the commit a look made, HEAD as it was then stands in.
        store = roost.Store(str(self.state))
        store.save(dict(store.read(task["id"]), looked=dict(looked, commit="0" * 40)))
        self.assertEqual(self.since_looked(task)["count"], 1, "small was not committed")
        store.save(dict(store.read(task["id"]), looked=dict(looked, commit="0" * 40, head="1" * 40)))
        self.assertIsNone(self.since_looked(task))

    def test_history_notes_each_change_of_status_seen_and_turn(self):
        started = time.time()
        task = self.create()
        record = self.wait(task, "ready")
        self.assertTrue(self.request("seen", id=task["id"], updatedAt=record["updatedAt"])["ok"])
        for value in ("to merge", "to merge", None):
            reply = self.request("turn", id=task["id"], turn=value)
            self.assertTrue(reply["ok"], reply)
        # Not an event of the agent's.
        self.assertEqual(reply["result"]["updatedAt"], record["updatedAt"])
        self.assertIn("Unknown turn", self.request("turn", id=task["id"], turn="later")["error"])
        self.request("stop", id=task["id"])
        self.assertTrue(self.request("retire", id=task["id"])["ok"])
        reply = self.request("history", since=started)
        self.assertTrue(reply["ok"], reply)
        changes = [change for change in reply["result"]["changes"] if change["id"] == task["id"]]
        self.assertEqual([(change["status"], change.get("seen"), change.get("turn")) for change in changes],
                         [("starting", False, None), ("ready", False, None), ("ready", True, None),
                          ("ready", True, "to merge"), ("ready", True, None), ("stopped", True, None),
                          (None, None, None)])
        # Each says what it was, so a day's first change tells how the day began.
        self.assertIsNone(changes[0]["was"])
        for before, after in zip(changes, changes[1:]):
            self.assertEqual(after["was"], dict(status=before["status"], seen=before["seen"], turn=before["turn"]))
        self.assertEqual(changes, sorted(changes, key=lambda change: change["at"]))
        self.assertEqual(reply["result"]["tasks"], [])
        self.assertGreaterEqual(reply["result"]["now"], changes[-1]["at"])
        # It begins with the first change noted, and so for any start asked for.
        self.assertEqual(reply["result"]["begun"], changes[0]["at"])
        self.assertEqual(self.request("history", since=0)["result"]["begun"], changes[0]["at"])
        # Asked from later on, it has none of them.
        self.assertEqual(self.request("history", since=time.time() + 1)["result"]["changes"], [])
        self.assertIn("start", self.request("history")["error"])

    def test_history_lists_each_task_as_it_is_now(self):
        task = self.create()
        record = self.wait(task, "ready")
        self.request("seen", id=task["id"], updatedAt=record["updatedAt"])
        self.request("turn", id=task["id"], turn="conflicts")
        tasks = self.request("history", since=time.time())["result"]["tasks"]
        self.assertEqual(tasks, [dict(id=task["id"], status="ready", seen=True, turn="conflicts")])

    def test_forget_refuses_a_running_agent_and_never_touches_git(self):
        task = self.create()
        self.assertIn("stop", self.request("forget", id=task["id"])["error"])
        self.assertIn(task["paneId"], roost.pane_inventory(self.socket))
        self.request("stop", id=task["id"])
        self.assertTrue(self.request("forget", id=task["id"])["ok"])
        self.assertTrue(Path(task["worktree"]).exists())
        self.assertTrue(roost.ref_exists(self.repo, task["branch"]))
        self.assertFalse(self.request("inspect", id=task["id"])["ok"])

    def test_failed_agent_pane_can_be_opened_to_read_its_error(self):
        script = self.root / "dies.py"
        script.write_text("import sys\nprint('AUTH ERROR: please log in')\nsys.exit(3)\n")
        reply = self.request("create", directory=str(self.repo), name="dies", socket=self.socket,
                             command=[sys.executable, str(script)])
        task = self.wait(reply["result"], "failed")
        self.wait_for_pane_exit(task)
        inspected = self.request("inspect", id=task["id"])
        self.assertTrue(inspected["ok"], inspected)
        self.assertFalse(inspected["result"]["live"])
        output = roost.tmux(self.socket, "capture-pane", "-p", "-S", "-", "-t", task["paneId"]).stdout
        self.assertIn("AUTH ERROR", output)
        self.assertFalse(self.request("send", id=task["id"], text="hello")["ok"])
        self.assertTrue(self.request("forget", id=task["id"])["ok"])
        self.assertNotIn(task["paneId"], roost.pane_inventory(self.socket))

    def test_unreadable_tmux_keeps_status_and_a_live_crashed_task_recovers(self):
        task = self.create()
        with patch.object(roost, "pane_inventory", return_value=None):
            listed = self.request("list")["result"][0]
            self.assertEqual(listed["status"], "ready")
            self.assertIsNone(listed["live"])
            self.assertIn("tmux did not answer", self.request("stop", id=task["id"])["error"])
        # A record marked crashed by an older helper's bad poll, while the agent lives on.
        store = roost.Store(str(self.state))
        record = store.read(task["id"])
        record.update(status="crashed")
        store.save(record)
        self.assertIn("still live", self.request("retire", id=task["id"])["error"])
        self.assertTrue(roost.owned_pane(record, roost.pane_inventory(self.socket)))
        listed = self.request("list")["result"][0]
        self.assertEqual((listed["status"], listed["live"]), ("ready", True))
        self.assertNotIn("live", store.read(task["id"]))

    def test_a_server_still_shutting_down_counts_as_none(self):
        for stderr, expected in (("server exited unexpectedly\n", {}), ("no server running on x\n", {}),
                                 ("protocol version mismatch (client 8, server 7)\n", None)):
            with patch.object(roost, "tmux", return_value=subprocess.CompletedProcess([], 1, "", stderr)):
                self.assertEqual(roost.pane_inventory("s"), expected, stderr)

    def test_no_tmux_server_means_crashed(self):
        task = self.create()
        roost.tmux(self.socket, "kill-server")
        self.assertEqual(roost.pane_inventory(self.socket), {})
        listed = self.request("list")["result"][0]
        self.assertEqual((listed["status"], listed["live"]), ("crashed", False))
        self.assertTrue(self.request("resume", id=task["id"])["ok"])
        self.wait(task, "ready")

    def test_git_statistics_run_outside_the_registry_lock(self):
        task = self.create()
        wt = Path(task["worktree"])
        (wt / "hello").write_text("task\n")
        self.git("commit", "-qam", "task", cwd=wt)
        (wt / "scratch").write_text("untracked\n")
        (self.repo / "other").write_text("main moved\n")
        self.git("add", ".")
        self.git("commit", "-qm", "main moved")
        observed = []
        original = roost.add_git_stats
        def probe(tasks):
            import fcntl
            with (self.state / "registry.lock").open("a") as lock:
                fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)  # Raises if held.
                observed.append(True)
            original(tasks)
        with patch.object(roost, "add_git_stats", probe):
            listed = self.request("list", full=True)["result"][0]
        self.assertEqual(observed, [True])
        self.assertEqual((listed["ahead"], listed["behind"], listed["dirty"]), (1, 1, True))
        self.assertIn("1 file changed", listed["diff"])
        for field in roost.TRANSIENT:
            self.assertNotIn(field, roost.Store(str(self.state)).read(task["id"]))

    def test_branch_prefix_is_configurable_and_validated(self):
        default = self.create(name="default prefix")
        self.assertTrue(default["branch"].startswith("roost/default-prefix-"))
        custom = self.create(name="custom", branchPrefix="clay/")
        self.assertTrue(custom["branch"].startswith("clay/custom-"))
        before = self.git("worktree", "list", "--porcelain")
        reply = self.request("create", directory=str(self.repo), name="bad", socket=self.socket,
                             branchPrefix="bad..prefix/", command=[sys.executable, str(FAKE)])
        self.assertIn("Invalid branch name", reply["error"])
        self.assertEqual(self.git("worktree", "list", "--porcelain"), before)

    def test_null_and_legacy_empty_object_parameters(self):
        for empty in (None, {}):
            with self.subTest(empty=empty):
                task = self.create(name="params", prompt=empty, setup=empty, base=empty, session=empty)
                record = roost.Store(str(self.state)).read(task["id"])
                self.assertEqual((record["prompt"], record["setup"], record["task"]), (None, None, "params"))
                self.assertEqual(record["session"], task["session"])
                self.assertTrue(record["session"].startswith("roost-"))

    def test_failed_setup_reruns_on_resume_and_then_never_again(self):
        marker = self.root / "setup-ran"
        setup = "echo run >> %s; test $(wc -l < %s) -ge 2" % (shlex.quote(str(marker)), shlex.quote(str(marker)))
        reply = self.request("create", directory=str(self.repo), name="setup", socket=self.socket,
                             setup=setup, command=[sys.executable, str(FAKE)])
        task = self.wait(reply["result"], "failed")
        self.assertFalse(roost.Store(str(self.state)).read(task["id"])["setupComplete"])
        self.wait_for_pane_exit(task)
        self.assertTrue(self.request("resume", id=task["id"])["ok"])
        self.assertTrue(self.wait(task, "ready")["setupComplete"])
        self.request("stop", id=task["id"])
        self.request("resume", id=task["id"])
        self.wait(task, "ready")
        self.assertEqual(marker.read_text().count("run"), 2)

    def test_setup_can_copy_untracked_files_from_the_primary_checkout(self):
        (self.repo / ".env").write_text("SECRET=1\n")
        reply = self.request("create", directory=str(self.repo), name="env", socket=self.socket,
                             setup='cp "$ROOST_REPO/.env" .', command=[sys.executable, str(FAKE)])
        task = self.wait(reply["result"], "ready")
        self.assertEqual((Path(task["worktree"]) / ".env").read_text(), "SECRET=1\n")

    def test_agent_path_keeps_inherited_precedence(self):
        path = roost.agent_path("/project/bin" + os.pathsep + "/usr/local/bin").split(os.pathsep)
        self.assertEqual(path[:2], ["/project/bin", "/usr/local/bin"])
        self.assertEqual(path.count("/usr/local/bin"), 1)
        self.assertIn(str(Path.home() / ".local/bin"), path[2:])

    def test_legacy_retired_records_are_pruned(self):
        task = self.create()
        self.request("stop", id=task["id"])
        store = roost.Store(str(self.state))
        record = store.read(task["id"])
        record["status"] = "retired"
        store.save(record)
        self.assertEqual(self.request("list")["result"], [])
        self.assertEqual(list(store.tasks_dir.glob("*.json")), [])

    def test_doctor_reports_tools_agents_and_fixes(self):
        reply = self.request("doctor", commands={"claude": [sys.executable, str(FAKE)],
                                                 "codex": ["/does/not/exist/codex"]})
        self.assertTrue(reply["ok"], reply)
        checks = {check["name"]: check for check in reply["result"]}
        for name in ("Python", "Git", "tmux", "State directory"):
            self.assertTrue(checks[name]["ok"], checks[name])
        self.assertFalse(checks["Codex"]["ok"])
        self.assertIn("Install Codex", checks["Codex"]["hint"])
        self.assertEqual(roost.version_of("tmux 3.7c"), (3, 7, 0))
        self.assertEqual(roost.version_of("codex-cli 0.160.0"), (0, 160, 0))

    def test_doctor_asks_for_a_claude_that_runs_the_hooks(self):
        # Claude Code 2.1.77 runs no hook from a settings file naming
        # StopFailure, which came in 2.1.78; see docs/validation.md.
        def claude(version):
            path = self.root / ("claude-" + version)
            path.write_text("#!/bin/sh\necho '%s (Claude Code)'\n" % version)
            path.chmod(0o755)
            reply = self.request("doctor", commands={"claude": [str(path)]})
            return {check["name"]: check for check in reply["result"]}["Claude"]
        old = claude("2.1.77")
        self.assertFalse(old["ok"], old)
        self.assertIn("Upgrade to Claude Code 2.1.78", old["hint"])
        self.assertTrue(claude("2.1.78")["ok"])
        self.assertTrue(claude("2.1.303")["ok"])

    def github(self):
        """A local bare origin and a fake gh first on PATH, recording its arguments."""
        self.origin = self.root / "origin.git"
        self.git("init", "--bare", "-b", "main", str(self.origin))
        self.git("remote", "add", "origin", str(self.origin))
        self.git("push", "-q", "origin", "main")
        self.gh_dir = self.root / "gh"
        self.gh_dir.mkdir()
        script = self.gh_dir / "gh"
        script.write_text("#!%s\n" % sys.executable + """import json, os, sys
directory = os.path.dirname(os.path.abspath(__file__))
args = sys.argv[1:]
with open(os.path.join(directory, "log"), "a") as log:
    log.write(json.dumps(args) + "\\n")
def canned(name, default=None):
    path = os.path.join(directory, name)
    if os.path.exists(path):
        sys.stdout.write(open(path).read())
        sys.exit(0)
    if default is None:
        sys.stderr.write("canned " + name + " missing\\n")
        sys.exit(1)
    print(default)
if os.path.exists(os.path.join(directory, "slow")):
    import time
    time.sleep(float(open(os.path.join(directory, "slow")).read()))
if args[:2] == ["pr", "list"]:
    # Filtered by --state as GitHub would; a canned entry without one is open.
    path = os.path.join(directory, "list.json")
    listed = json.load(open(path)) if os.path.exists(path) else []
    state = args[args.index("--state") + 1].upper() if "--state" in args else "OPEN"
    print(json.dumps([pr for pr in listed if state == "ALL" or pr.get("state", "OPEN") == state]))
elif args[:2] == ["api", "graphql"]:
    # Each pull request the query asks for, as reviews.json has it by number.
    import re
    query = next(arg for arg in args if arg.startswith("query="))
    path = os.path.join(directory, "reviews.json")
    if not os.path.exists(path):
        sys.stderr.write("canned reviews.json missing\\n")
        sys.exit(1)
    reviews = json.load(open(path))
    print(json.dumps(dict(data=dict(repository={
        "pr" + number: reviews.get(number) for number in re.findall(r"pullRequest\\(number: (\\d+)\\)", query)}))))
elif args[:2] == ["pr", "create"]:
    if os.path.exists(os.path.join(directory, "linger")):
        os.system("sleep 1.5 > /dev/null 2>&1 &")
    print("https://github.com/octo/repo/pull/7")
elif args[:2] == ["issue", "list"]:
    canned("issues.json", "[]")
elif args[:2] == ["auth", "status"]:
    if os.path.exists(os.path.join(directory, "signed-out")):
        sys.stderr.write("You are not logged into any GitHub hosts.\\n")
        sys.exit(1)
    print("github.com\\n  Logged in to github.com account octocat (keyring)")
""")
        script.chmod(0o755)
        patcher = patch.dict(os.environ, PATH=str(self.gh_dir) + os.pathsep + os.environ["PATH"])
        patcher.start()
        self.addCleanup(patcher.stop)

    def gh_calls(self):
        log = self.gh_dir / "log"
        return [json.loads(line) for line in log.read_text().splitlines()] if log.exists() else []

    def commit_in(self, task, name="work"):
        wt = Path(task["worktree"])
        (wt / name).write_text(name + "\n")
        self.git("add", ".", cwd=wt)
        self.git("commit", "-qm", name, cwd=wt)
        return self.git("rev-parse", "HEAD", cwd=wt)

    def test_pr_pushes_the_branch_creates_a_pull_request_and_records_it(self):
        self.github()
        task = self.create()
        tip = self.commit_in(task)
        observed = []
        original = roost.pull_request
        def probe(*args):
            import fcntl
            with (self.state / "registry.lock").open("a") as lock:
                fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)  # Raises if held.
                observed.append(True)
            return original(*args)
        with patch.object(roost, "pull_request", probe):
            reply = self.request("pr", id=task["id"], title="Fix it", body="Because.\n", draft=True)
        self.assertTrue(reply["ok"], reply)
        self.assertEqual(observed, [True])
        pr = dict(number=7, url="https://github.com/octo/repo/pull/7")
        self.assertEqual(reply["result"]["pr"], pr)
        self.assertEqual(roost.Store(str(self.state)).read(task["id"])["pr"], pr)
        self.assertEqual(self.git("rev-parse", "refs/heads/" + task["branch"], cwd=self.origin), tip)
        self.assertEqual(self.git("config", "branch.%s.remote" % task["branch"]), "origin")
        self.assertEqual(self.gh_calls()[-1],
                         ["pr", "create", "--base", "main", "--head", task["branch"],
                          "--title", "Fix it", "--body", "Because.\n", "--draft"])
        # A pull request that already exists is returned, not duplicated.
        store = roost.Store(str(self.state))
        record = store.read(task["id"])
        del record["pr"]
        store.save(record)
        (self.gh_dir / "list.json").write_text(json.dumps([dict(number=3, url="https://github.com/octo/repo/pull/3")]))
        before = len(self.gh_calls())
        again = self.request("pr", id=task["id"], title="Again")
        self.assertEqual(again["result"]["pr"]["number"], 3)
        self.assertFalse([call for call in self.gh_calls()[before:] if call[:2] == ["pr", "create"]])

    def test_pr_from_an_older_helpers_task_targets_the_branch_it_lists(self):
        # Older helpers recorded heads/release, when a tag was also named release.
        self.github()
        self.git("branch", "release")
        self.git("tag", "release")
        task = self.create(name="on release", base="heads/release")
        self.commit_in(task)
        store = roost.Store(str(self.state))
        record = store.read(task["id"])
        record["integrationBranch"] = "heads/release"
        del record["integrationRef"]
        store.save(record)
        listed = next(t for t in self.request("list")["result"] if t["id"] == task["id"])
        self.assertEqual(listed["integrationBranch"], "release")
        reply = self.request("pr", id=task["id"], title="Fix it")
        self.assertTrue(reply["ok"], reply)
        self.assertEqual(self.gh_calls()[-1][:4], ["pr", "create", "--base", "release"])
        # Every action reads it so: merged into release by hand, it retires.
        self.git("update-ref", "refs/heads/release", task["branch"])
        self.request("stop", id=task["id"])
        reply = self.request("retire", id=task["id"])
        self.assertTrue(reply["ok"], reply)

    def test_pr_without_draft_and_refusals(self):
        self.github()
        task = self.create()
        reply = self.request("pr", id=task["id"], title="Nothing")
        self.assertIn("no commits beyond", reply["error"])
        self.commit_in(task)
        (Path(task["worktree"]) / "hello").write_text("uncommitted\n")
        reply = self.request("pr", id=task["id"], title="Dirty")
        self.assertIn("Commit the task's changes", reply["error"])
        self.assertEqual(self.gh_calls(), [])
        self.assertEqual(self.git("branch", "--list", task["branch"], cwd=self.origin), "")
        self.git("checkout", "hello", cwd=Path(task["worktree"]))
        (Path(task["worktree"]) / "untracked").write_text("ignored\n")
        self.assertIn("title", self.request("pr", id=task["id"])["error"])
        reply = self.request("pr", id=task["id"], title="Ok", body=None)
        self.assertTrue(reply["ok"], reply)
        self.assertNotIn("--draft", self.gh_calls()[-1])
        self.assertEqual(self.gh_calls()[-1][self.gh_calls()[-1].index("--body") + 1], "")
        store = roost.Store(str(self.state))
        record = store.read(task["id"])
        record["integrationBranch"] = None
        del record["pr"]
        store.save(record)
        self.assertIn("no integration branch", self.request("pr", id=task["id"], title="Detached")["error"])

    def test_pr_on_a_task_with_a_pull_request_pushes_new_commits(self):
        self.github()
        task = self.create()
        self.commit_in(task, "one")
        self.assertTrue(self.request("pr", id=task["id"], title="Fix it")["ok"])
        calls = len(self.gh_calls())
        # Nothing new: no title needed, no gh, nothing pushed.
        reply = self.request("pr", id=task["id"])
        self.assertTrue(reply["ok"], reply)
        self.assertEqual(reply["result"]["pushed"], 0)
        self.assertEqual(reply["result"]["pr"]["number"], 7)
        tip = self.commit_in(task, "two")
        self.commit_in(task, "three")
        tip = self.git("rev-parse", "HEAD", cwd=Path(task["worktree"]))
        reply = self.request("pr", id=task["id"])
        self.assertEqual(reply["result"]["pushed"], 2)
        self.assertEqual(self.git("rev-parse", "refs/heads/" + task["branch"], cwd=self.origin), tip)
        self.assertEqual(len(self.gh_calls()), calls)
        self.assertNotIn("pushed", roost.Store(str(self.state)).read(task["id"]))
        (Path(task["worktree"]) / "one").write_text("dirty\n")
        reply = self.request("pr", id=task["id"])
        self.assertIn("Commit the task's changes", reply["error"])

    def elsewhere(self, task):
        """A clone of the origin with the task's branch checked out, as on
        GitHub or another machine, whose pushes this repository hasn't fetched."""
        clone = self.root / ("elsewhere-" + task["id"][:6])
        self.git("clone", "-q", "--branch", task["branch"], str(self.origin), str(clone))
        for key, value in (("user.name", "Elsewhere"), ("user.email", "elsewhere@example.invalid")):
            self.git("config", key, value, cwd=clone)
        return clone

    def test_pr_opens_a_pull_request_with_a_commit_made_on_github(self):
        # As when a review's suggestion was committed there: pushing the
        # branch as it is would be refused.
        self.github()
        task = self.create()
        self.commit_in(task, "one")
        self.assertTrue(self.request("pr", id=task["id"], title="Fix it")["ok"])
        clone = self.elsewhere(task)
        self.git("commit", "-q", "--allow-empty", "-m", "Apply suggestion", cwd=clone)
        self.git("push", "-q", "origin", task["branch"], cwd=clone)
        suggested = self.git("rev-parse", "HEAD", cwd=clone)
        reply = self.request("pr", id=task["id"])
        self.assertTrue(reply["ok"], reply)
        self.assertEqual(reply["result"]["pushed"], 0)
        self.assertEqual(self.git("rev-parse", "refs/heads/" + task["branch"], cwd=self.origin), suggested)

    def test_pr_fetches_the_branch_in_a_clone_that_fetches_only_some(self):
        # As a single-branch clone does: fetching the branch by name alone
        # would not update its remote-tracking branch.
        self.github()
        task = self.create()
        self.commit_in(task, "one")
        self.assertTrue(self.request("pr", id=task["id"], title="Fix it")["ok"])
        self.git("config", "remote.origin.fetch", "+refs/heads/main:refs/remotes/origin/main")
        self.git("update-ref", "-d", "refs/remotes/origin/" + task["branch"])
        clone = self.elsewhere(task)
        self.git("commit", "-q", "--allow-empty", "-m", "Apply suggestion", cwd=clone)
        self.git("push", "-q", "origin", task["branch"], cwd=clone)
        reply = self.request("pr", id=task["id"])
        self.assertTrue(reply["ok"], reply)
        self.assertEqual(reply["result"]["pushed"], 0)

    def test_pr_pushes_when_it_cannot_fetch(self):
        # Rewound elsewhere, and not to be fetched: what was last fetched,
        # the commit itself, is no sign the pull request has it.
        self.github()
        task = self.create()
        first = self.commit_in(task, "one")
        self.assertTrue(self.request("pr", id=task["id"], title="Fix it")["ok"])
        tip = self.commit_in(task, "two")
        self.assertEqual(self.request("pr", id=task["id"])["result"]["pushed"], 1)
        clone = self.elsewhere(task)
        self.git("push", "-q", "-f", "origin", "%s:refs/heads/%s" % (first, task["branch"]), cwd=clone)
        original = roost.remote_git

        def unreachable(repo, *args, **kwargs):
            if args[0] == "fetch":
                return subprocess.CompletedProcess(args, 128, "", "fatal: unable to access")
            return original(repo, *args, **kwargs)

        with patch.object(roost, "remote_git", unreachable):
            reply = self.request("pr", id=task["id"])
        self.assertTrue(reply["ok"], reply)
        self.assertEqual(self.git("rev-parse", "refs/heads/" + task["branch"], cwd=self.origin), tip)

    def test_pr_pushes_to_a_branch_rewound_elsewhere(self):
        # Taken back a commit from another machine since last fetched here:
        # the commit is pushed again, not taken as already there.
        self.github()
        task = self.create()
        first = self.commit_in(task, "one")
        self.assertTrue(self.request("pr", id=task["id"], title="Fix it")["ok"])
        tip = self.commit_in(task, "two")
        self.assertEqual(self.request("pr", id=task["id"])["result"]["pushed"], 1)
        clone = self.elsewhere(task)
        self.git("push", "-q", "-f", "origin", "%s:refs/heads/%s" % (first, task["branch"]), cwd=clone)
        reply = self.request("pr", id=task["id"])
        self.assertTrue(reply["ok"], reply)
        self.assertEqual(reply["result"]["pushed"], 1)
        self.assertEqual(self.git("rev-parse", "refs/heads/" + task["branch"], cwd=self.origin), tip)

    def test_issues_lists_open_issues_and_create_records_the_chosen_one(self):
        self.github()
        (self.gh_dir / "issues.json").write_text(json.dumps([
            dict(number=12, title="CSV import crashes", body="x" * 7000, url="https://github.com/o/r/issues/12",
                 labels=[dict(name="bug"), dict(name="import")]),
            dict(number=9, title="Docs", body=None, url="https://github.com/o/r/issues/9", labels=[])]))
        sub = self.repo / "sub"
        sub.mkdir()
        reply = self.request("issues", directory=str(sub))
        self.assertTrue(reply["ok"], reply)
        first, second = reply["result"]
        self.assertEqual((first["number"], first["title"], first["labels"]), (12, "CSV import crashes", ["bug", "import"]))
        self.assertTrue(first["body"].endswith("…"))
        self.assertLess(len(first["body"]), 6100)
        self.assertEqual((second["body"], second["labels"]), ("", []))
        self.assertEqual(self.gh_calls()[-1][:4], ["issue", "list", "--state", "open"])
        task = self.create(issue=dict(number=12, title="CSV import crashes", url=first["url"], body="ignored"))
        self.assertEqual(task["issue"], dict(number=12, title="CSV import crashes", url=first["url"]))
        self.assertNotIn("issue", self.create(name="plain", issue=dict(number="12")))

    def test_pr_reports_a_missing_gh(self):
        self.github()
        task = self.create()
        self.commit_in(task)
        (self.gh_dir / "gh").unlink()
        # agent_path also searches Homebrew; hide any real gh installed there.
        with patch.object(roost, "agent_path", lambda inherited: str(self.gh_dir)):
            reply = self.request("pr", id=task["id"], title="No gh")
        self.assertIn("GitHub CLI (gh) is not installed", reply["error"])

    def test_list_adds_transient_pr_status_from_gh(self):
        self.github()
        task = self.create()
        tip = self.commit_in(task)
        store = roost.Store(str(self.state))
        record = store.read(task["id"])
        record["pr"] = dict(number=7, url="https://github.com/octo/repo/pull/7")
        store.save(record)
        (self.gh_dir / "list.json").write_text(json.dumps([dict(
            number=7, url="https://github.com/octo/repo/pull/7",
            state="OPEN", isDraft=True, reviewDecision="APPROVED", headRefOid=tip, baseRefName="release",
            statusCheckRollup=[
                dict(__typename="CheckRun", status="COMPLETED", conclusion="SUCCESS"),
                dict(__typename="CheckRun", status="COMPLETED", conclusion="SKIPPED"),
                dict(__typename="CheckRun", status="COMPLETED", conclusion="FAILURE"),
                dict(__typename="CheckRun", status="IN_PROGRESS", conclusion=""),
                dict(__typename="StatusContext", state="PENDING"),
                dict(__typename="StatusContext", state="SUCCESS")])]))
        before = roost.now()
        listed = self.request("list", full=True)["result"][0]
        checked = listed["prStatus"].pop("checkedAt")
        self.assertLessEqual(before, checked)
        # GitHub didn't say what it has of reviews (reviews.json is missing).
        self.assertEqual(listed["prStatus"], dict(
            state="OPEN", draft=True, review="APPROVED", head=tip, base="release",
            checks=dict(passing=3, failing=1, pending=2), failedAt=None))
        self.assertEqual(listed["unpushed"], 0)
        self.assertEqual(self.gh_calls()[-2],
                         ["pr", "list", "--head", task["branch"], "--state", "all", "--limit", "10", "--json",
                          "number,url,state,isDraft,reviewDecision,statusCheckRollup,headRefOid,baseRefName"])
        self.assertEqual(self.gh_calls()[-1][:3], ["api", "graphql", "--hostname"])
        self.assertNotIn("prStatus", store.read(task["id"]))
        self.assertNotIn("unpushed", store.read(task["id"]))
        # What it shows is recorded, for views that ask GitHub nothing.
        self.assertEqual(store.read(task["id"])["pr"], dict(number=7, url="https://github.com/octo/repo/pull/7",
                                                            state="OPEN", head=tip, base="release"))
        self.assertNotIn("prStatus", self.request("list")["result"][0])
        # Refreshing an active agent's changes leaves GitHub alone.
        calls = len(self.gh_calls())
        self.assertNotIn("prStatus", self.request("list", full=[task["id"]])["result"][0])
        self.assertEqual(len(self.gh_calls()), calls)
        (self.gh_dir / "list.json").unlink()
        self.assertNotIn("prStatus", self.request("list", full=True)["result"][0])

    @staticmethod
    def thread(resolved, *times):
        """A review thread as GitHub's GraphQL API gives it, with the time of its last comment."""
        return dict(isResolved=resolved, comments=dict(nodes=[dict(createdAt=at) for at in times[-1:]]))

    def test_an_open_pull_request_says_what_its_review_and_checks_wait_for(self):
        self.github()
        task = self.create()
        tip = self.commit_in(task)
        self.push(task)
        url = "https://github.com/octo/repo/pull/7"
        (self.gh_dir / "list.json").write_text(json.dumps([dict(
            number=7, url=url, state="OPEN", headRefOid=tip,
            statusCheckRollup=[
                dict(__typename="CheckRun", status="COMPLETED", conclusion="FAILURE",
                     completedAt="2026-10-16T21:40:00Z"),
                dict(__typename="CheckRun", status="COMPLETED", conclusion="TIMED_OUT",
                     completedAt="2026-10-16T21:47:50Z"),
                dict(__typename="CheckRun", status="COMPLETED", conclusion="SUCCESS",
                     completedAt="2026-10-16T21:59:00Z"),
                dict(__typename="StatusContext", state="ERROR", createdAt="2026-10-16T21:45:00Z")])]))
        (self.gh_dir / "reviews.json").write_text(json.dumps({"7": dict(
            mergeable="MERGEABLE",
            reviewRequests=dict(nodes=[dict(requestedReviewer=dict(login="copilot-pull-request-reviewer")),
                                       dict(requestedReviewer=dict(slug="core")),
                                       dict(requestedReviewer=None)]),
            reviewThreads=dict(totalCount=3, nodes=[
                self.thread(True, "2026-10-16T21:58:00Z"),
                self.thread(False, "2026-10-16T21:41:00Z"),
                self.thread(False, "2026-10-16T21:43:00Z")]))}))
        status = self.request("list", full=True)["result"][0]["prStatus"]
        # From the first failure and the first of the unresolved threads'
        # last comments: a newer one leaves those overdue.
        self.assertEqual({key: status[key] for key in ("failedAt", "mergeable", "requested", "threads", "threadAt")},
                         dict(failedAt="2026-10-16T21:40:00Z", mergeable="MERGEABLE",
                              requested=["copilot-pull-request-reviewer", "core", "someone"],
                              threads=2, threadAt="2026-10-16T21:41:00Z"))
        query = self.gh_calls()[-1]
        self.assertEqual(query[:5] + query[6:], ["api", "graphql", "--hostname", "github.com", "-f",
                                                 "-f", "owner=octo", "-f", "name=repo"])
        self.assertIn("pr7: pullRequest(number: 7)", query[5])
        # A failure or thread without a time has none to wait from.
        listed = json.loads((self.gh_dir / "list.json").read_text())
        listed[0]["statusCheckRollup"].append(dict(__typename="StatusContext", state="FAILURE"))
        (self.gh_dir / "list.json").write_text(json.dumps(listed))
        reviews = json.loads((self.gh_dir / "reviews.json").read_text())
        reviews["7"]["reviewThreads"]["nodes"].append(dict(isResolved=False, comments=dict(nodes=[])))
        reviews["7"]["reviewThreads"]["totalCount"] += 1
        (self.gh_dir / "reviews.json").write_text(json.dumps(reviews))
        status = self.request("list", full=True)["result"][0]["prStatus"]
        self.assertEqual((status["failedAt"], status["threads"], status["threadAt"]), (None, 3, None))
        # Nothing unresolved, nor too many threads to tell.
        (self.gh_dir / "reviews.json").write_text(json.dumps({"7": dict(
            mergeable="CONFLICTING", reviewRequests=dict(nodes=[]),
            reviewThreads=dict(totalCount=1, nodes=[self.thread(True, "2026-10-16T21:58:00Z")]))}))
        status = self.request("list", full=True)["result"][0]["prStatus"]
        self.assertEqual((status["mergeable"], status["requested"], status["threads"], status["threadAt"]),
                         ("CONFLICTING", [], 0, None))
        (self.gh_dir / "reviews.json").write_text(json.dumps({"7": dict(
            mergeable="UNKNOWN", reviewRequests=dict(nodes=[]),
            reviewThreads=dict(totalCount=101, nodes=[self.thread(True, "2026-10-16T21:58:00Z")] * 100))}))
        status = self.request("list", full=True)["result"][0]["prStatus"]
        self.assertEqual(status["mergeable"], "UNKNOWN")
        self.assertNotIn("threads", status)
        self.assertNotIn("threadAt", status)
        # A merged one is asked nothing more.
        calls = len(self.gh_calls())
        (self.gh_dir / "list.json").write_text(json.dumps([dict(number=7, url=url, state="MERGED", headRefOid=tip)]))
        status = self.request("list", full=True)["result"][0]["prStatus"]
        self.assertEqual(len(self.gh_calls()), calls + 1)
        self.assertEqual(set(status), {"state", "draft", "review", "checks", "head", "base"})

    def test_reviews_are_asked_once_for_each_repository(self):
        self.github()
        first, second = self.create(name="first"), self.create(name="second")
        tips = [self.commit_in(task, task["name"]) for task in (first, second)]
        for task in (first, second):
            self.push(task)
        url = "https://github.com/octo/repo/pull/%d"
        (self.gh_dir / "list.json").write_text(json.dumps([dict(number=7, url=url % 7, state="OPEN", headRefOid=tips[0]),
                                                           dict(number=8, url=url % 8, state="OPEN", headRefOid=tips[1])]))
        (self.gh_dir / "reviews.json").write_text(json.dumps({
            number: dict(mergeable="MERGEABLE", reviewRequests=dict(nodes=[]),
                         reviewThreads=dict(totalCount=0, nodes=[])) for number in ("7", "8")}))
        listed = {task["name"]: task for task in self.request("list", full=True)["result"]}
        self.assertEqual([listed[name]["prStatus"]["threads"] for name in ("first", "second")], [0, 0])
        queries = [call for call in self.gh_calls() if call[:2] == ["api", "graphql"]]
        self.assertEqual(len(queries), 1)
        self.assertIn("pr7: pullRequest(number: 7)", queries[0][5])
        self.assertIn("pr8: pullRequest(number: 8)", queries[0][5])
        # One whose URL isn't of a pull request is asked nothing.
        self.assertEqual(roost.pull_request_reviews([dict(number=9, url="https://example.com/9")],
                                                    time.monotonic() + 5), {})
        self.assertEqual(len([call for call in self.gh_calls() if call[:2] == ["api", "graphql"]]), 1)
        # Past the deadline, GitHub is not asked about reviews, and what
        # its pull request lists said still shows.
        with patch.object(roost, "PULL_REQUEST_DEADLINE", 2.5):
            (self.gh_dir / "slow").write_text("1.8")
            listed = self.request("list", full=True)["result"]
        (self.gh_dir / "slow").unlink()
        self.assertEqual(len([call for call in self.gh_calls() if call[:2] == ["api", "graphql"]]), 1)
        for task in listed:
            self.assertEqual(task["prStatus"]["state"], "OPEN")
            self.assertNotIn("threads", task["prStatus"])

    def test_an_open_pull_request_says_how_many_commits_it_lacks(self):
        self.github()
        task = self.create()
        tip = self.commit_in(task)
        self.push(task)
        url = "https://github.com/octo/repo/pull/7"
        listed = self.gh_dir / "list.json"
        listed.write_text(json.dumps([dict(number=7, url=url, state="OPEN", headRefOid=tip)]))
        self.assertEqual(self.request("list", full=True)["result"][0]["unpushed"], 0)
        # Committed since, as in Magit: measuring the task says so, asking GitHub nothing.
        self.commit_in(task, "two")
        self.commit_in(task, "three")
        calls = len(self.gh_calls())
        self.assertEqual(self.request("list", full=[task["id"]])["result"][0]["unpushed"], 2)
        self.assertEqual(len(self.gh_calls()), calls)
        self.assertEqual(self.request("list", full=True)["result"][0]["unpushed"], 2)
        self.assertNotIn("unpushed", self.request("list")["result"][0])
        # A commit made on GitHub, fetched here, which the branch lacks.
        wt = Path(task["worktree"])
        suggested = self.git("commit-tree", "HEAD^{tree}", "-p", "HEAD", "-m", "Apply suggestion", cwd=wt)
        listed.write_text(json.dumps([dict(number=7, url=url, state="OPEN", headRefOid=suggested)]))
        self.assertEqual(self.request("list", full=True)["result"][0]["unpushed"], 0)
        # One not fetched, or not after the branch's tip: it can't tell.
        listed.write_text(json.dumps([dict(number=7, url=url, state="OPEN", headRefOid="f" * 40)]))
        self.assertIsNone(self.request("list", full=True)["result"][0]["unpushed"])
        # Nor while its agent has the worktree on another branch, whose
        # commits it would miss.
        listed.write_text(json.dumps([dict(number=7, url=url, state="OPEN", headRefOid=suggested)]))
        self.git("checkout", "-q", "-b", "side", cwd=wt)
        self.commit_in(task, "aside")
        self.assertIsNone(self.request("list", full=True)["result"][0]["unpushed"])
        self.assertIsNone(self.request("list", full=[task["id"]])["result"][0]["unpushed"])
        # With its branch gone too, it says it can't tell, rather than nothing.
        tip = self.git("rev-parse", task["branch"])
        self.git("branch", "-D", task["branch"])
        measured = self.request("list", full=[task["id"]])["result"][0]
        self.assertIn("unpushed", measured)
        self.assertIsNone(measured["unpushed"])
        self.git("branch", task["branch"], tip)
        self.git("checkout", "-q", task["branch"], cwd=wt)
        # Nor is it said of one that is no longer open.
        listed.write_text(json.dumps([dict(number=7, url=url, state="CLOSED", headRefOid="f" * 40)]))
        self.assertNotIn("unpushed", self.request("list", full=True)["result"][0])

    def test_retire_accepts_a_squash_merged_pull_request_and_deletes_the_remote_branch(self):
        self.github()
        task = self.create()
        tip = self.commit_in(task)
        self.assertTrue(self.request("pr", id=task["id"], title="Squash")["ok"])
        self.git("merge", "--squash", task["branch"])
        self.git("commit", "-qm", "Squash (#7)")
        listed = self.gh_dir / "list.json"
        # The task committed again after the merge: its branch must be kept.
        listed.write_text(json.dumps([dict(number=7, state="MERGED", headRefOid="0" * 40)]))
        reply = self.request("retire", id=task["id"])
        self.assertIn("unmerged commits", reply["error"])
        self.assertTrue(Path(task["worktree"]).exists())
        listed.write_text(json.dumps([dict(number=7, state="OPEN", headRefOid=tip)]))
        self.assertFalse(self.request("retire", id=task["id"])["ok"])
        listed.write_text(json.dumps([dict(number=7, state="MERGED", headRefOid=tip)]))
        # gh is asked once, with the registry lock released; retire never calls it.
        observed = []
        original = roost.gh
        def probe(*args, **kwargs):
            import fcntl
            with (self.state / "registry.lock").open("a") as lock:
                fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)  # Raises if held.
                observed.append(args[1:3])
            return original(*args, **kwargs)
        with patch.object(roost, "gh", probe):
            reply = self.request("retire", id=task["id"], mergedHead=tip)
        self.assertEqual(observed, [("pr", "list")])
        self.assertTrue(reply["ok"], reply)
        self.assertNotIn("remoteCleanup", reply["result"])
        self.assertFalse(Path(task["worktree"]).exists())
        self.assertEqual(self.git("branch", "--list", task["branch"]), "")
        self.assertEqual(self.git("branch", "--list", task["branch"], cwd=self.origin), "")

    def test_retire_tolerates_a_remote_branch_that_is_already_gone(self):
        self.github()
        task = self.create()
        tip = self.commit_in(task)
        self.assertTrue(self.request("pr", id=task["id"], title="Squash")["ok"])
        self.git("branch", "-D", task["branch"], cwd=self.origin)
        self.git("merge", "--squash", task["branch"])
        self.git("commit", "-qm", "Squash (#7)")
        (self.gh_dir / "list.json").write_text(json.dumps([dict(number=7, state="MERGED", headRefOid=tip)]))
        self.assertTrue(self.request("retire", id=task["id"])["ok"])

    def push(self, task):
        self.git("push", "-q", "-u", "origin", task["branch"], cwd=Path(task["worktree"]))

    def test_list_learns_the_pull_request_an_agent_opened(self):
        self.github()
        task = self.create()
        base = task["baseCommit"]
        store = roost.Store(str(self.state))
        # Not pushed yet: GitHub is not asked.
        tip = self.commit_in(task)
        self.request("list", full=True)
        self.assertEqual(self.gh_calls(), [])
        self.push(task)
        url = "https://github.com/octo/repo/pull/%d"
        (self.gh_dir / "list.json").write_text(json.dumps([
            # Another task's of the same name, merged before this one started.
            dict(number=2, url=url % 2, state="MERGED", headRefOid=base),
            # Someone else's branch of that name, with commits not here.
            dict(number=5, url=url % 5, state="CLOSED", headRefOid="f" * 40),
            dict(number=9, url=url % 9, state="OPEN", headRefOid=tip)]))
        listed = self.request("list", full=True)["result"][0]
        self.assertEqual(listed["pr"], dict(number=9, url=url % 9, state="OPEN", head=tip))
        self.assertEqual(listed["prStatus"]["state"], "OPEN")
        self.assertIs(listed["landed"], False)
        self.assertEqual(store.read(task["id"])["pr"], listed["pr"])
        # Background polls ask GitHub only when told to.
        calls = len(self.gh_calls())
        quiet = self.request("list")["result"][0]
        self.assertEqual(len(self.gh_calls()), calls)
        self.assertNotIn("landed", quiet)
        self.assertEqual(quiet["pr"]["number"], 9)
        # Merged on GitHub as a squash: Git alone can't tell.
        (self.gh_dir / "list.json").write_text(json.dumps([dict(number=9, url=url % 9, state="MERGED",
                                                                headRefOid=tip)]))
        polled = self.request("list", pullRequests=True)["result"][0]
        self.assertEqual(len(self.gh_calls()), calls + 1)
        self.assertEqual((polled["prStatus"]["state"], polled["landed"]), ("MERGED", True))
        # Measured with it, as one to retire must be.
        self.assertIs(polled["dirty"], False)
        self.assertEqual(store.read(task["id"])["pr"]["state"], "MERGED")
        # A commit after the merge is new work, and measuring it needs no GitHub.
        again = self.commit_in(task, "more")
        calls = len(self.gh_calls())
        self.assertIs(self.request("list", full=[task["id"]])["result"][0]["landed"], False)
        self.assertEqual(len(self.gh_calls()), calls)
        # Its second pull request shows, and its merge lands the task again.
        (self.gh_dir / "list.json").write_text(json.dumps([
            dict(number=11, url=url % 11, state="OPEN", headRefOid=again),
            dict(number=9, url=url % 9, state="MERGED", headRefOid=tip)]))
        listed = self.request("list", full=True)["result"][0]
        self.assertEqual((listed["pr"]["number"], listed["landed"]), (11, False))
        (self.gh_dir / "list.json").write_text(json.dumps([
            dict(number=12, url=url % 12, state="CLOSED", headRefOid=again),
            dict(number=11, url=url % 11, state="MERGED", headRefOid=again),
            dict(number=9, url=url % 9, state="MERGED", headRefOid=tip)]))
        listed = self.request("list", full=True)["result"][0]
        self.assertEqual((listed["pr"]["number"], listed["landed"]), (11, True))
        # Without gh, what was recorded stands.
        (self.gh_dir / "gh").unlink()
        with patch.object(roost, "agent_path", lambda inherited: str(self.gh_dir)):
            listed = self.request("list", full=True)["result"][0]
        self.assertEqual((listed["pr"]["number"], listed["landed"]), (11, True))
        self.assertNotIn("prStatus", listed)

    def test_a_lookup_leaves_a_pull_request_recorded_meanwhile(self):
        # Another Emacs, or P, recorded one while this lookup waited on GitHub.
        self.github()
        task = self.create()
        tip = self.commit_in(task)
        self.push(task)
        (self.gh_dir / "list.json").write_text(json.dumps([dict(number=9, state="OPEN", headRefOid=tip)]))
        store = roost.Store(str(self.state))
        newer = dict(number=10, url="https://github.com/octo/repo/pull/10", state="OPEN", head=tip)
        original = roost.task_pull_requests

        def meanwhile(*args, **kwargs):
            prs = original(*args, **kwargs)
            with store.locked():
                record = store.read(task["id"])
                record["pr"] = newer
                store.save(record)
            return prs

        with patch.object(roost, "task_pull_requests", meanwhile):
            listed = self.request("list", full=True)["result"][0]
        self.assertEqual(store.read(task["id"])["pr"], newer)
        self.assertEqual(listed["pr"], newer)
        self.assertNotIn("prStatus", listed)

    def test_a_lookup_that_found_what_was_recorded_still_leaves_a_newer_one(self):
        self.github()
        task = self.create()
        tip = self.commit_in(task)
        self.push(task)
        url = "https://github.com/octo/repo/pull/%d"
        (self.gh_dir / "list.json").write_text(json.dumps([dict(number=9, url=url % 9, state="OPEN",
                                                                headRefOid=tip)]))
        store = roost.Store(str(self.state))
        self.request("list", full=True)
        newer = dict(number=10, url=url % 10, state="OPEN", head=tip)
        original = roost.task_pull_requests

        def meanwhile(*args, **kwargs):
            prs = original(*args, **kwargs)
            with store.locked():
                record = store.read(task["id"])
                record["pr"] = newer
                store.save(record)
            return prs

        with patch.object(roost, "task_pull_requests", meanwhile):
            listed = self.request("list", pullRequests=True)["result"][0]
        self.assertEqual((store.read(task["id"])["pr"], listed["pr"]), (newer, newer))
        self.assertNotIn("prStatus", listed)

    def test_a_merge_found_on_github_comes_with_whether_the_task_is_clean(self):
        # A file changed since the last measurement moves no Git stamp.
        self.github()
        task = self.create()
        tip = self.commit_in(task)
        self.push(task)
        self.assertIs(self.request("list", full=True)["result"][0]["dirty"], False)
        (Path(task["worktree"]) / "hello").write_text("edited since\n")
        (self.gh_dir / "list.json").write_text(json.dumps([dict(number=9, state="MERGED", headRefOid=tip)]))
        polled = self.request("list", pullRequests=True)["result"][0]
        self.assertEqual((polled["landed"], polled["dirty"]), (True, True))

    def test_an_open_pull_request_comes_with_whether_the_task_is_clean(self):
        # An edit not yet staged moves no Git stamp: a poll that asks
        # GitHub measures a task it may say waits to be merged.
        self.github()
        task = self.create()
        tip = self.commit_in(task)
        self.push(task)
        url = "https://github.com/octo/repo/pull/9"
        (self.gh_dir / "list.json").write_text(json.dumps([dict(number=9, url=url, state="OPEN", headRefOid=tip)]))
        self.assertIs(self.request("list", full=True)["result"][0]["dirty"], False)
        (Path(task["worktree"]) / "work").write_text("edited since\n")
        polled = self.request("list", pullRequests=True)["result"][0]
        self.assertEqual((polled["prStatus"]["state"], polled["dirty"], polled["unpushed"]), ("OPEN", True, 0))
        self.assertNotIn("dirty", self.request("list")["result"][0])

    def test_conflicts_are_measured_once_github_no_longer_says(self):
        self.github()
        task = self.create()
        wt = Path(task["worktree"])
        (wt / "hello").write_text("task\n")
        self.git("commit", "-qam", "task", cwd=wt)
        tip = self.git("rev-parse", "HEAD", cwd=wt)
        self.push(task)
        (self.repo / "hello").write_text("main\n")
        self.git("commit", "-qam", "main")
        url = "https://github.com/octo/repo/pull/9"
        listed = self.gh_dir / "list.json"
        listed.write_text(json.dumps([dict(number=9, url=url, state="OPEN", headRefOid=tip)]))
        self.assertIsNone(self.request("list", full=True)["result"][0]["conflicts"])
        # Closed on GitHub, with neither branch moved: a poll that asks GitHub measures it.
        listed.write_text(json.dumps([dict(number=9, url=url, state="CLOSED", headRefOid=tip)]))
        self.assertEqual(self.request("list", pullRequests=True)["result"][0]["conflicts"], ["hello"])
        self.assertNotIn("conflicts", self.request("list", pullRequests=True)["result"][0])
        # Merged there, as by a squash, its work has nothing left to conflict.
        listed.write_text(json.dumps([dict(number=9, url=url, state="MERGED", headRefOid=tip)]))
        self.assertEqual(self.request("list", pullRequests=True)["result"][0]["conflicts"], [])

    def test_a_same_named_pull_request_on_main_is_not_a_task_with_no_work(self):
        # Someone else's fork, with a branch of the same name at main's commit.
        self.github()
        task = self.create()
        (self.repo / "later").write_text("later\n")
        self.git("add", "later")
        self.git("commit", "-qm", "Later on main")
        self.assertTrue(self.request("update", id=task["id"])["ok"])
        self.push(task)
        tip = self.git("rev-parse", "main")
        (self.gh_dir / "list.json").write_text(json.dumps([dict(number=4, state="MERGED", headRefOid=tip)]))
        listed = self.request("list", full=True)["result"][0]
        self.assertNotIn("pr", listed)
        self.assertIs(listed["landed"], False)
        self.assertIsNone(roost.merged_pull_request_head(roost.Store(str(self.state)).read(task["id"])))

    def test_a_pull_request_is_a_tasks_only_at_a_commit_it_made(self):
        # Brought up to main's M, then committing T: another fork's PR at M is not its.
        self.github()
        task = self.create()
        (self.repo / "later").write_text("later\n")
        self.git("add", "later")
        self.git("commit", "-qm", "Later on main")
        self.assertTrue(self.request("update", id=task["id"])["ok"])
        main = self.git("rev-parse", "main")
        tip = self.commit_in(task)
        self.push(task)
        (self.gh_dir / "list.json").write_text(json.dumps([dict(number=4, state="MERGED", headRefOid=main)]))
        self.assertNotIn("pr", self.request("list", full=True)["result"][0])
        (self.gh_dir / "list.json").write_text(json.dumps([dict(number=4, state="MERGED", headRefOid=main),
                                                           dict(number=6, state="OPEN", headRefOid=tip)]))
        self.assertEqual(self.request("list", full=True)["result"][0]["pr"]["number"], 6)
        # Rebased onto main and pushed again: the rebased tip is its own too.
        (self.repo / "later2").write_text("later\n")
        self.git("add", "later2")
        self.git("commit", "-qm", "Later still on main")
        self.git("rebase", "-q", "main", cwd=Path(task["worktree"]))
        rebased = self.git("rev-parse", "HEAD", cwd=Path(task["worktree"]))
        (self.gh_dir / "list.json").write_text(json.dumps([dict(number=6, state="OPEN", headRefOid=rebased)]))
        self.assertEqual(self.request("list", full=True)["result"][0]["pr"]["head"], rebased)
        store = roost.Store(str(self.state))
        record = store.read(task["id"])
        del record["pr"]
        store.save(record)
        (self.gh_dir / "list.json").write_text(json.dumps([dict(number=8, state="OPEN", headRefOid=rebased)]))
        self.assertEqual(self.request("list", full=True)["result"][0]["pr"]["number"], 8)

    def test_a_pull_request_merged_at_the_tip_counts_while_another_is_open(self):
        # As when one went to a release branch and another, open, to main.
        self.github()
        task = self.create()
        tip = self.commit_in(task)
        self.push(task)
        (self.gh_dir / "list.json").write_text(json.dumps([
            dict(number=11, state="OPEN", headRefOid=tip, baseRefName="main"),
            dict(number=10, state="MERGED", headRefOid=tip, baseRefName="release")]))
        listed = self.request("list", full=True)["result"][0]
        self.assertEqual((listed["pr"]["number"], listed["pr"]["mergedHead"], listed["landed"]), (11, tip, True))
        # Where it merged, though the one shown goes elsewhere.
        self.assertEqual((listed["pr"]["base"], listed["pr"]["mergedBases"]), ("main", ["release"]))
        # And where else, once the open one merges too, as the newer one shown.
        (self.gh_dir / "list.json").write_text(json.dumps([
            dict(number=11, state="MERGED", headRefOid=tip, baseRefName="main"),
            dict(number=10, state="MERGED", headRefOid=tip, baseRefName="release")]))
        listed = self.request("list", full=True)["result"][0]
        self.assertEqual((listed["pr"]["number"], listed["pr"]["mergedBases"]), (11, ["release", "main"]))
        # Retiring trusts it too when gh can't say.
        (self.gh_dir / "gh").unlink()
        with patch.object(roost, "agent_path", lambda inherited: str(self.gh_dir)):
            self.assertEqual(roost.merged_pull_request_head(roost.Store(str(self.state)).read(task["id"])), tip)

    def test_a_merge_at_the_tip_stays_when_a_later_lookup_lists_it_no_more(self):
        # A branch with more than a page of pull requests.
        self.github()
        task = self.create()
        tip = self.commit_in(task)
        self.push(task)
        (self.gh_dir / "list.json").write_text(json.dumps([dict(number=3, state="MERGED", headRefOid=tip)]))
        self.assertIs(self.request("list", full=True)["result"][0]["landed"], True)
        (self.gh_dir / "list.json").write_text(json.dumps([dict(number=n, state="CLOSED", headRefOid=tip)
                                                           for n in range(20, 10, -1)]))
        listed = self.request("list", full=True)["result"][0]
        self.assertEqual((listed["pr"]["mergedHead"], listed["landed"]), (tip, True))
        self.assertEqual(roost.merged_pull_request_head(roost.Store(str(self.state)).read(task["id"])), tip)

    def test_without_a_reflog_a_task_brought_up_to_date_is_not_merged(self):
        self.git("config", "core.logAllRefUpdates", "false")
        task = self.create()
        (self.repo / "later").write_text("later\n")
        self.git("add", "later")
        self.git("commit", "-qm", "Later on main")
        self.assertTrue(self.request("update", id=task["id"])["ok"])
        self.assertIs(self.request("list", full=True)["result"][0]["landed"], False)

    def test_stopping_an_agent_you_had_seen_keeps_it_seen(self):
        store = roost.Store(str(self.state))
        seen, unseen = self.create(name="seen"), self.create(name="unseen")
        self.assertTrue(self.request("seen", id=seen["id"], updatedAt=store.read(seen["id"])["updatedAt"])["ok"])
        for task in (seen, unseen):
            self.assertTrue(self.request("stop", id=task["id"])["ok"])
        stopped = store.read(seen["id"])
        self.assertEqual(stopped["seen"], stopped["updatedAt"])
        self.assertNotEqual(store.read(unseen["id"]).get("seen"), store.read(unseen["id"])["updatedAt"])

    def test_asking_github_keeps_within_its_deadline(self):
        # A stalled GitHub must not hold up the reply past Emacs's wait for it.
        self.github()
        tasks = [self.create(name="slow %d" % n) for n in range(3)]
        for task in tasks:
            self.commit_in(task)
            self.push(task)
        (self.gh_dir / "slow").write_text("10")
        start = time.monotonic()
        with patch.object(roost, "PULL_REQUEST_DEADLINE", 1.5):
            listed = self.request("list", full=True)["result"]
        self.assertLess(time.monotonic() - start, 6)
        self.assertEqual([task.get("prStatus") for task in listed], [None] * 3)

    def test_list_says_whether_a_tasks_work_is_merged_into_its_branch(self):
        task = self.create()
        self.assertIs(self.request("list", full=True)["result"][0]["landed"], False)  # Nothing committed.
        # Brought up to date, it fast-forwards to main's commits, none of them its own.
        (self.repo / "later").write_text("later\n")
        self.git("add", "later")
        self.git("commit", "-qm", "Later on main")
        self.assertTrue(self.request("update", id=task["id"])["ok"])
        self.assertEqual(self.git("rev-parse", "HEAD", cwd=Path(task["worktree"])), self.git("rev-parse", "main"))
        self.assertIs(self.request("list", full=True)["result"][0]["landed"], False)
        self.commit_in(task)
        self.assertIs(self.request("list", full=True)["result"][0]["landed"], False)
        self.git("merge", "-q", "--no-ff", "--no-edit", task["branch"])
        self.assertIs(self.request("list", full=True)["result"][0]["landed"], True)
        self.assertNotIn("landed", roost.Store(str(self.state)).read(task["id"]))
        # Work merged in from a branch of the agent's own counts too.
        other = self.create(name="merges a side branch")
        wt = Path(other["worktree"])
        self.git("checkout", "-q", "-b", "side", cwd=wt)
        self.git("commit", "-q", "--allow-empty", "-m", "On the side", cwd=wt)
        self.git("checkout", "-q", other["branch"], cwd=wt)
        self.git("merge", "-q", "--no-ff", "--no-edit", "side", cwd=wt)
        self.git("merge", "-q", "--no-ff", "--no-edit", other["branch"])
        listed = {t["id"]: t for t in self.request("list", full=True)["result"]}
        self.assertIs(listed[other["id"]]["landed"], True)

    def test_retire_accepts_a_pull_request_its_agent_opened_and_github_squashed(self):
        self.github()
        task = self.create()
        tip = self.commit_in(task)
        self.push(task)
        self.git("merge", "--squash", task["branch"])
        self.git("commit", "-qm", "Squash (#9)")
        (self.gh_dir / "list.json").write_text(json.dumps([dict(number=9, state="MERGED", headRefOid=tip)]))
        reply = self.request("retire", id=task["id"])
        self.assertTrue(reply["ok"], reply)
        self.assertEqual(self.git("branch", "--list", task["branch"], cwd=self.origin), "")

    def test_retire_trusts_a_recorded_merge_when_gh_cannot_say(self):
        self.github()
        task = self.create()
        tip = self.commit_in(task)
        self.push(task)
        (self.gh_dir / "list.json").write_text(json.dumps([dict(number=9, state="MERGED", headRefOid=tip)]))
        self.assertIs(self.request("list", full=True)["result"][0]["landed"], True)
        (self.gh_dir / "gh").unlink()
        with patch.object(roost, "agent_path", lambda inherited: str(self.gh_dir)):
            reply = self.request("retire", id=task["id"])
        self.assertTrue(reply["ok"], reply)

    def test_doctor_checks_the_github_cli(self):
        self.github()
        checks = {check["name"]: check for check in self.request("doctor")["result"]}
        self.assertTrue(checks["GitHub CLI"]["ok"], checks["GitHub CLI"])
        self.assertIn("octocat", checks["GitHub CLI"]["detail"])
        self.assertTrue(checks["GitHub CLI"]["optional"])
        self.assertFalse(checks["Git"]["optional"])
        (self.gh_dir / "signed-out").write_text("")
        checks = {check["name"]: check for check in self.request("doctor")["result"]}
        self.assertFalse(checks["GitHub CLI"]["ok"])
        self.assertIn("gh auth login", checks["GitHub CLI"]["hint"])
        (self.gh_dir / "gh").unlink()
        with patch.object(roost, "agent_path", lambda inherited: str(self.gh_dir)):
            checks = {check["name"]: check for check in self.request("doctor")["result"]}
        self.assertFalse(checks["GitHub CLI"]["ok"])
        self.assertEqual(checks["GitHub CLI"]["detail"], "not found")
        self.assertTrue(checks["GitHub CLI"]["optional"])
        self.assertIn("install gh", checks["GitHub CLI"]["hint"])

    def test_search_finds_a_retired_tasks_conversation_under_its_project(self):
        task = self.create(name="fix parser")
        record = roost.Store(str(self.state)).read(task["id"])
        home = self.root / "home"
        folder = home / ".claude/projects" / claude_folder(task["worktree"])
        folder.mkdir(parents=True)
        (folder / (record["agentSession"] + ".jsonl")).write_text(json.dumps(
            {"type": "user", "timestamp": "2026-10-01T10:00:00Z", "cwd": task["worktree"],
             "message": {"role": "user", "content": "Fix the parser"}}) + "\n")
        self.request("stop", id=task["id"])
        self.wait_for_pane_exit(task)
        self.assertTrue(self.request("retire", id=task["id"])["ok"])
        with patch.dict(os.environ, HOME=str(home)):
            found = self.request("search", query="parser")["result"]["tasks"]
        self.assertEqual([(t["name"], t["repo"], t.get("past")) for t in found],
                         [("fix parser", task["repo"], True)])

    def test_list_and_inspect_show_the_agents_latest_reply_without_saving_it(self):
        task = self.create()
        record = roost.Store(str(self.state)).read(task["id"])
        home = self.root / "home"
        folder = home / ".claude/projects" / claude_folder(task["worktree"])
        folder.mkdir(parents=True)
        (folder / (record["agentSession"] + ".jsonl")).write_text(
            json.dumps({"message": {"role": "assistant", "content": [{"type": "text", "text": "x" * 3000}]}}) + "\n")
        with patch.dict(os.environ, HOME=str(home)):
            listed = self.request("list", full=True)["result"][0]
            inspected = self.request("inspect", id=task["id"])["result"]
            plain = self.request("list")["result"][0]
        for shown in (listed, inspected):
            self.assertTrue(shown["lastMessage"].startswith("x" * 2000))
            self.assertLess(len(shown["lastMessage"]), 2010)
        self.assertNotIn("lastMessage", plain)
        self.assertNotIn("lastMessage", roost.Store(str(self.state)).read(task["id"]))
        # No transcript: the request still succeeds, with no field.
        self.assertNotIn("lastMessage", self.request("list", full=True)["result"][0])

    def test_the_reply_claude_reports_is_the_latest_reply(self):
        # Claude's Stop event carries the turn's reply, so no transcript is read.
        task = self.create()
        self.assertTrue(self.request("send", id=task["id"], text="hello")["ok"])
        self.wait(task, "ready", "Stop")
        store = roost.Store(str(self.state))
        self.assertEqual(store.read(task["id"])["lastReply"], "PROMPT hello")
        listed = self.request("list", full=True)["result"][0]
        self.assertEqual(listed["lastMessage"], "PROMPT hello")
        # It stays on the host.
        self.assertNotIn("lastReply", listed)
        self.assertNotIn("lastReply", self.request("inspect", id=task["id"])["result"])
        # A new turn has no reply yet: the transcript, here none, says what is newest.
        roost.update_hook(store, task["id"], dict(hook_event_name="UserPromptSubmit"), task["runId"])
        self.assertNotIn("lastMessage", self.request("list", full=True)["result"][0])
        roost.update_hook(store, task["id"], dict(hook_event_name="Stop", last_assistant_message="y" * 3000),
                          task["runId"])
        reply = self.request("list", full=True)["result"][0]["lastMessage"]
        self.assertEqual((reply[:2000], reply[2000:]), ("y" * 2000, "…"))
        # Cut where a space follows, it still says it was cut.
        roost.update_hook(store, task["id"], dict(hook_event_name="Stop",
                                                  last_assistant_message="y" * 2000 + " " + "z" * 100),
                          task["runId"])
        reply = self.request("list", full=True)["result"][0]["lastMessage"]
        self.assertEqual((reply[:2000], reply[2000:]), ("y" * 2000, "…"))

    def test_what_you_last_said_is_kept_for_the_panel_but_not_the_first_prompt(self):
        # Claude's UserPromptSubmit carries the prompt. The first is the
        # task's own, which the panel shows already.
        task = self.create(prompt="Fix the parser")
        self.wait(task, "ready", "Stop")
        store = roost.Store(str(self.state))
        self.assertIsNone(store.read(task["id"]).get("lastPrompt"))
        hook = lambda **fields: roost.update_hook(store, task["id"], dict(hook_event_name="UserPromptSubmit",
                                                                          **fields), task["runId"])
        hook(prompt="  Now add a test\n")
        roost.update_hook(store, task["id"], dict(hook_event_name="Stop", last_assistant_message="Added"),
                          task["runId"])
        # Emacs shows it as is.
        self.assertEqual(self.request("list")["result"][0]["lastPrompt"], "Now add a test")
        self.assertEqual(self.request("inspect", id=task["id"])["result"]["lastPrompt"], "Now add a test")
        hook(prompt="y" * 3000)
        said = store.read(task["id"])["lastPrompt"]
        self.assertEqual((said[:2000], said[2000:]), ("y" * 2000, "…"))
        # Back to the first prompt, or no words at all: nothing more to remind you of.
        hook(prompt="Fix the parser")
        self.assertIsNone(store.read(task["id"])["lastPrompt"])
        hook(prompt="Again")
        hook()
        self.assertIsNone(store.read(task["id"])["lastPrompt"])

    def test_claudes_transcript_is_read_where_claude_says_it_is(self):
        task = self.create()
        store = roost.Store(str(self.state))
        transcript = self.root / "elsewhere" / "conversation.jsonl"
        transcript.parent.mkdir()
        roost.update_hook(store, task["id"], dict(hook_event_name="UserPromptSubmit", session_id="s1",
                                                  transcript_path=str(transcript)), task["runId"])
        record = store.read(task["id"])
        self.assertEqual(record["transcript"], str(transcript))
        since = roost.parse_time(record["updatedAt"])
        transcript.write_text("\n".join(json.dumps(entry) for entry in (
            {"type": "assistant", "timestamp": since.isoformat(),
             "message": {"role": "assistant", "content": [{"type": "text", "text": "Working on it"}]}},
            {"type": "user", "timestamp": (since + datetime.timedelta(seconds=1)).isoformat(),
             "message": {"role": "user", "content": [{"type": "text", "text": "[Request interrupted by user]"}]}},
        )) + "\n")
        listed = self.request("list", full=True)["result"][0]
        self.assertEqual((listed["status"], listed["lastEvent"], listed["lastMessage"]),
                         ("ready", "Interrupt", "Working on it"))
        self.assertNotIn("transcript", listed)
        # /clear starts a new conversation, with no reply of its own yet.
        roost.update_hook(store, task["id"], dict(hook_event_name="Stop", last_assistant_message="Done"), task["runId"])
        roost.update_hook(store, task["id"], dict(hook_event_name="SessionStart", source="clear", session_id="s2",
                                                  transcript_path=str(self.root / "s2.jsonl")), task["runId"])
        record = store.read(task["id"])
        self.assertEqual((record["lastReply"], record["transcript"], record["agentSession"]),
                         (None, str(self.root / "s2.jsonl"), "s2"))

    def test_bad_base_and_missing_executable_report_errors_without_touching_repo(self):
        response = self.request("create", directory=str(self.repo), name="bad", base="missing-ref", socket=self.socket)
        self.assertEqual(response, dict(ok=False, error="No branch, tag or commit named 'missing-ref' to start from"))
        # A prompt too long to be an argument, which Linux refuses, is refused
        # before anything is created.
        response = self.request("create", directory=str(self.repo), name="huge", socket=self.socket,
                                prompt="é" * 70000)
        self.assertEqual(response, dict(ok=False, error="The prompt is 137 KB, and an agent can start with at most "
                                                        "120 KB; start it with less and send the rest once it runs"))
        self.assertEqual(self.git("branch", "--list", "roost/*"), "")
        # A new repository: Git would say only "Needed a single revision".
        empty = self.root / "empty"
        empty.mkdir()
        roost.git(empty, "init", "-b", "main")
        response = self.request("create", directory=str(empty), name="scaffold", socket=self.socket)
        self.assertFalse(response["ok"])
        self.assertIn("has no commits yet", response["error"])
        response = self.request("create", directory=str(self.repo), name="bad executable", socket=self.socket,
                                command=["/does/not/exist"])
        self.assertTrue(response["ok"])
        self.wait(response["result"], "failed")
        self.assertEqual(self.git("status", "--porcelain"), "")


class History(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.folder = Path(self.temp.name) / "history"
        self.history = roost.History(self.folder)

    def tearDown(self):
        self.temp.cleanup()

    def test_only_changes_are_noted(self):
        task = dict(status="ready", updatedAt="1", seen=None, name="a")
        self.history.note("t1", task, dict(task, name="b"))
        self.assertFalse(self.folder.exists())
        self.history.note("t1", task, dict(task, seen="1"))
        self.history.note("t1", dict(task, seen="1"), dict(task, seen="1", updatedAt="2"))
        changes = self.history.read(0)
        self.assertEqual([change["seen"] for change in changes], [True, False])

    def test_old_days_are_pruned_and_damaged_lines_skipped(self):
        self.folder.mkdir()
        old = time.strftime("%Y-%m-%d", time.gmtime(time.time() - (roost.HISTORY_DAYS + 2) * 86400))
        recent = time.strftime("%Y-%m-%d", time.gmtime(time.time() - 86400))
        (self.folder / (old + ".jsonl")).write_text(json.dumps(dict(at=1.0, id="t0", status="ready")) + "\n")
        (self.folder / (recent + ".jsonl")).write_text(
            json.dumps(dict(at=time.time() - 86400, id="t0", status="running")) + "\n" + '{"at": 1')
        (self.folder / "notes.txt").write_text("not the history's")
        self.history.note("t1", None, dict(status="starting"))
        self.assertFalse((self.folder / (old + ".jsonl")).exists())
        self.assertTrue((self.folder / "notes.txt").exists())
        self.assertEqual([change["status"] for change in self.history.read(0)], ["running", "starting"])
        self.assertEqual([change["status"] for change in self.history.read(time.time() - 3600)], ["starting"])

    def test_a_line_cut_short_today_takes_no_other_with_it(self):
        self.history.note("t1", None, dict(status="starting"))
        today = next(self.folder.glob("*.jsonl"))
        today.write_text(today.read_text() + '{"at": 1, "id": "t1", "sta')
        self.history.note("t1", dict(status="starting"), dict(status="running"))
        self.assertEqual([change["status"] for change in self.history.read(0)], ["starting", "running"])

    def test_a_failure_to_note_fails_nothing(self):
        Path(self.temp.name, "history").write_text("a file where the folder goes")
        self.history.note("t1", None, dict(status="starting"))
        self.assertEqual(self.history.read(0), [])
        self.assertIsNone(self.history.begun())

    def test_it_begins_with_the_oldest_change_kept(self):
        self.assertIsNone(self.history.begun())
        self.folder.mkdir()
        (self.folder / "2026-10-01.jsonl").write_text('{"at": 1\n' + json.dumps(dict(at=5.0, id="t0")) + "\n")
        (self.folder / "2026-10-02.jsonl").write_text(json.dumps(dict(at=9.0, id="t0")) + "\n")
        self.assertEqual(self.history.begun(), 5.0)


class RemoteGit(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.repo = Path(self.temp.name)
        roost.git(self.repo, "init", "-b", "main")

    def tearDown(self):
        self.temp.cleanup()

    def completed(self, returncode, stderr):
        return subprocess.CompletedProcess([], returncode, "", stderr)

    def test_runs_without_stdin_or_prompts_under_a_timeout(self):
        with patch.object(roost.subprocess, "Popen") as popen:
            popen.return_value.communicate.return_value = ("", "")
            popen.return_value.returncode = 0
            roost.remote_git(self.repo, "push", "origin", "main")
        kwargs = popen.call_args.kwargs
        self.assertEqual(kwargs["stdin"], subprocess.DEVNULL)
        self.assertTrue(kwargs["start_new_session"])
        for name, value in (("GIT_TERMINAL_PROMPT", "0"), ("GIT_ASKPASS", ""),
                            ("SSH_ASKPASS_REQUIRE", "never"), ("GCM_INTERACTIVE", "never")):
            self.assertEqual(kwargs["env"][name], value)
        self.assertEqual(popen.return_value.communicate.call_args.kwargs["timeout"], 120)

    def test_a_timeout_kills_everything_the_command_started(self):
        pidfile = self.repo / "child.pid"
        started = time.monotonic()
        with self.assertRaises(subprocess.TimeoutExpired):
            roost.run_detached(["sh", "-c", 'sleep 30 & echo $! > "$1"; wait', "sh", str(pidfile)], 0.5)
        self.assertLess(time.monotonic() - started, 10)
        child = int(pidfile.read_text())

        def running(pid):
            # A zombie has exited; without an init process (as in some
            # containers) nobody reaps it, but it is no longer running.
            try:
                os.kill(pid, 0)
            except ProcessLookupError:
                return False
            stat = Path("/proc/%d/stat" % pid)
            if Path("/proc/self/stat").exists():
                try:
                    state = stat.read_text().rsplit(")", 1)[1].split()[0]
                # Reaped since the kill check, before or while reading.
                except (FileNotFoundError, ProcessLookupError):
                    return False
            else:
                state = subprocess.run(["ps", "-o", "stat=", "-p", str(pid)],
                                       capture_output=True, text=True).stdout.strip()
            return bool(state) and not state.startswith("Z")

        deadline = time.monotonic() + 5
        while running(child):
            if time.monotonic() > deadline:
                self.fail("the background child survived the timeout")
            time.sleep(0.05)

    def test_a_timeout_is_a_roost_error(self):
        with patch.object(roost, "run_detached",
                          side_effect=subprocess.TimeoutExpired("git", 120)):
            with self.assertRaisesRegex(roost.RoostError, "git push timed out"):
                roost.remote_git(self.repo, "push", "origin", "main")

    def test_credential_failures_keep_gits_message_and_add_advice(self):
        for message in ("git@github.com: Permission denied (publickey).",
                        "fatal: could not read Username for 'https://github.com'",
                        "remote: Authentication failed",
                        "fatal: terminal prompts disabled"):
            with patch.object(roost, "run_detached", return_value=self.completed(128, message)):
                with self.assertRaises(roost.RoostError) as caught:
                    roost.remote_git(self.repo, "push", "origin", "main")
            self.assertIn(message, str(caught.exception))
            self.assertIn("the Git credentials on this host (%s)" % roost.socket.gethostname(),
                          str(caught.exception))
            self.assertIn("gh auth setup-git", str(caught.exception))

    def test_other_failures_get_no_advice(self):
        with patch.object(roost, "run_detached", return_value=self.completed(1, "rejected")):
            with self.assertRaises(roost.RoostError) as caught:
                roost.remote_git(self.repo, "push", "origin", "main")
        self.assertEqual(str(caught.exception), "rejected")

    def test_a_push_needing_credentials_fails_quickly_with_advice(self):
        class Demand(http.server.BaseHTTPRequestHandler):
            def do_GET(self):
                self.send_response(401)
                self.send_header("WWW-Authenticate", 'Basic realm="x"')
                self.send_header("Content-Length", "0")
                self.end_headers()
            do_POST = do_GET

            def log_message(self, *args):
                pass

        server = http.server.HTTPServer(("127.0.0.1", 0), Demand)
        threading.Thread(target=server.serve_forever, daemon=True).start()
        self.addCleanup(server.server_close)
        self.addCleanup(server.shutdown)
        roost.git(self.repo, "config", "user.name", "Roost Test")
        roost.git(self.repo, "config", "user.email", "roost@example.invalid")
        roost.git(self.repo, "config", "commit.gpgsign", "false")
        roost.git(self.repo, "commit", "--allow-empty", "-m", "base")
        roost.git(self.repo, "remote", "add", "origin",
                  "http://127.0.0.1:%d/x/y.git" % server.server_port)
        started = time.monotonic()
        with patch.dict(os.environ, {"GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_NOSYSTEM": "1"}):
            with self.assertRaises(roost.RoostError) as caught:
                roost.remote_git(self.repo, "push", "-u", "origin", "main")
        self.assertLess(time.monotonic() - started, 30)
        self.assertIn("gh auth setup-git", str(caught.exception))
        self.assertIn("on this host (%s)" % roost.socket.gethostname(), str(caught.exception))


class PushCheck(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        root = Path(self.temp.name)
        self.origin = root / "origin.git"
        self.repo = root / "project"
        roost.git(root, "init", "--bare", "-b", "main", str(self.origin))
        roost.git(root, "init", "-b", "main", str(self.repo))
        for key, value in (("user.name", "Roost Test"), ("user.email", "roost@example.invalid"),
                           ("commit.gpgsign", "false")):
            roost.git(self.repo, "config", key, value)
        roost.git(self.repo, "commit", "--allow-empty", "-m", "base")
        self.checks = []

    def check(self, name, ok, detail, hint=None, path=None, optional=False):
        self.checks.append(dict(name=name, ok=ok, detail=detail, hint=hint, optional=optional))

    def test_a_reachable_origin_passes_without_pushing_anything(self):
        roost.git(self.repo, "remote", "add", "origin", str(self.origin))
        roost.push_check(self.check, str(self.repo))
        self.assertEqual(self.checks, [dict(name="Push · project", ok=True, detail=str(self.origin),
                                            hint=None, optional=True)])
        self.assertEqual(roost.git(self.origin, "for-each-ref").stdout, "")

    def test_failures_and_missing_origins_are_optional_problems(self):
        roost.push_check(self.check, str(self.repo))
        roost.git(self.repo, "remote", "add", "origin", str(Path(self.temp.name) / "missing.git"))
        roost.push_check(self.check, str(self.repo))
        roost.push_check(self.check, str(Path(self.temp.name) / "gone"))
        self.assertEqual([(c["ok"], c["detail"], c["optional"]) for c in self.checks][0],
                         (False, "no origin remote", True))
        self.assertFalse(self.checks[1]["ok"])
        self.assertIn("missing.git", self.checks[1]["detail"])
        self.assertEqual(len(self.checks), 2, "a missing checkout is skipped")


class PermissionRequest(unittest.TestCase):
    def test_requests_read_as_phrases(self):
        ask = lambda tool, **args: roost.permission_request(dict(tool_name=tool, tool_input=args), "/work/task")
        self.assertEqual(ask("Edit", file_path="/work/task/notes.py"), "Asks to edit notes.py")
        self.assertEqual(ask("Read", file_path="/etc/hosts"), "Asks to read /etc/hosts")
        self.assertEqual(ask("shell", command=["bash", "-lc", "make test"]), "Asks to run bash -lc 'make test'")
        self.assertEqual(ask("WebFetch", url="https://example.com"), "Asks to fetch https://example.com")
        self.assertEqual(ask("apply_patch", input="*** Begin Patch"), "Asks to edit files")
        self.assertEqual(ask("mcp__github__create_issue", title="x"), "Asks to use mcp__github__create_issue")
        self.assertEqual(ask("Bash"), "Asks to use Bash")
        self.assertEqual(len(ask("Bash", command="x" * 1000)), len("Asks to run ") + roost.REQUEST_LIMIT)
        # A cd into the worktree the command runs in anyway is left out.
        self.assertEqual(ask("Bash", command="cd /work/task 2>/dev/null || true; git status --short"),
                         "Asks to run git status --short")
        self.assertEqual(ask("Bash", command="cd '/work/task/' &&\n  make test"), "Asks to run make test")
        self.assertEqual(ask("Bash", command="cd /work/task/sub && python3 /work/task/run.py /work/task"),
                         "Asks to run cd sub && python3 run.py .")
        self.assertEqual(ask("Bash", command="cd /elsewhere && ls /work/task-2"),
                         "Asks to run cd /elsewhere && ls /work/task-2")
        self.assertEqual(ask("Bash", command="cd /work/task && "), "Asks to run cd /work/task &&")
        self.assertEqual(ask("Bash", command="ls /other/work/task/a /work/task/b"),
                         "Asks to run ls /other/work/task/a b")
        # Shortened before it is clipped: a long path can't crowd out the command.
        deep = "/work/" + "d" * 290
        self.assertEqual(roost.permission_request(
            dict(tool_name="Bash", tool_input=dict(command="cd %s && make --keep-going" % deep)), deep),
            "Asks to run make --keep-going")
        # Questions and plans wait for an answer rather than a permission.
        question = lambda text: dict(question=text, header="h", options=[dict(label="a"), dict(label="b")])
        self.assertEqual(ask("AskUserQuestion", questions=[question("Red or blue?")]), "Asks: Red or blue?")
        self.assertEqual(ask("AskUserQuestion", questions=[question("Red?"), question("Blue?")]),
                         "Asks: Red? (and 1 more)")
        self.assertEqual(ask("AskUserQuestion", questions="odd"), "Asks you a question")
        self.assertEqual(ask("ExitPlanMode", plan="1. Do it"), "Asks you to approve its plan")
        self.assertIsNone(roost.permission_request(dict(hook_event_name="Notification")))


class Search(unittest.TestCase):
    """Searching the Claude conversations of a store's tasks, from a fake HOME."""

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.home = Path(self.temp.name) / "home"
        self.state = Path(self.temp.name) / "state"
        patcher = patch.dict(os.environ, HOME=str(self.home))
        patcher.start()
        self.addCleanup(patcher.stop)
        self.addCleanup(self.temp.cleanup)
        self.store = roost.Store(str(self.state))
        self.repo = "/work/shop"
        self.repo_hash = hashlib.sha256(self.repo.encode()).hexdigest()[:10]

    def conversation(self, worktree, session, entries):
        """Write a conversation Claude ran in WORKTREE, as Claude names and records it."""
        folder = self.home / ".claude/projects" / roost.claude_project_folder(str(worktree))
        folder.mkdir(parents=True, exist_ok=True)
        (folder / (session + ".jsonl")).write_text(
            "".join(json.dumps(dict(dict(cwd=str(worktree)), **entry)) + "\n" for entry in entries))
        return folder

    @staticmethod
    def said(role, content, minute, **fields):
        return dict(type=role, timestamp="2026-10-0%dT10:%02d:00.000Z" % (1 + minute // 60, minute % 60),
                    gitBranch="roost/x", message=dict(role=role, content=content), **fields)

    def search(self, query):
        reply = roost.rpc(dict(root=str(self.state), action="search", query=query))
        self.assertTrue(reply["ok"], reply)
        return reply["result"]

    def test_live_and_retired_tasks_are_searched_and_nothing_else(self):
        live = self.state / "worktrees" / self.repo_hash / "fix-csv-quoting-0a1b2c"
        self.store.save(dict(id="0a1b2c3d4e5f6a7b", name="fix CSV quoting", repo=self.repo,
                             worktree=str(live), branch="roost/fix-csv-quoting-0a1b2c", status="ready"))
        self.conversation(live, "s1", [
            self.said("user", "Quote CSV fields that contain commas", 1),
            self.said("assistant", [{"type": "thinking", "thinking": "csv commas"},
                                    {"type": "text", "text": "Done: the CSV writer now quotes commas."}], 2),
            # Tool calls and their output are not what anyone wrote.
            self.said("assistant", [{"type": "tool_use", "name": "Bash", "input": {"command": "grep csv commas"}}], 3),
            self.said("user", [{"type": "tool_result", "content": "csv commas everywhere"}], 4),
            # Nor are slash commands, their output, or Claude Code's notes.
            self.said("user", "<command-name>/csv commas</command-name>", 5),
            self.said("user", "<task-notification>csv commas done</task-notification>", 6),
            self.said("user", "csv commas", 7, isMeta=True),
        ])
        # Retired: no record, but the conversation stays, named after the worktree.
        (self.state / "worktrees" / self.repo_hash).mkdir(parents=True, exist_ok=True)
        retired = self.state / "worktrees" / self.repo_hash / "csv-import-9f8e7d"
        self.conversation(retired, "s2", [self.said("user", "Import CSV with commas in quotes", 120)])
        # A subagent's conversation, and a session outside Roost.
        folder = self.conversation(live, "s3", [])
        (folder / "s3" / "subagents").mkdir(parents=True)
        (folder / "s3" / "subagents" / "a.jsonl").write_text(json.dumps(self.said("user", "csv commas", 9)) + "\n")
        self.conversation("/elsewhere/project", "s4", [self.said("user", "csv commas", 200)])

        result = self.search("COMMAS csv")
        self.assertEqual(result["moreTasks"], 0)
        first, second = result["tasks"]
        # Newest first. A retired task is named from its worktree's folder,
        # and its project from a live task's in the same repository.
        self.assertEqual((first["name"], first["past"], first["repo"], first["branch"]),
                         ("csv import", True, self.repo, "roost/x"))
        self.assertNotIn("id", first)
        self.assertEqual((second["id"], second["name"], second["repo"]), ("0a1b2c3d4e5f6a7b", "fix CSV quoting", self.repo))
        self.assertEqual([(hit["role"], hit["text"]) for hit in second["hits"]],
                         [("user", "Quote CSV fields that contain commas"),
                          ("assistant", "Done: the CSV writer now quotes commas.")])
        self.assertEqual(second["hits"][0]["session"], "s1")
        self.assertEqual(second["hits"][0]["at"], "2026-10-01T10:01:00.000Z")
        # Every word must be in one message, where a word starts.
        self.assertEqual(self.search("writer contain")["tasks"], [])
        self.assertEqual(len(self.search("comma")["tasks"]), 2)
        self.assertEqual(self.search("ommas")["tasks"], [])
        self.assertEqual([task["name"] for task in self.search("writer")["tasks"]], ["fix CSV quoting"])
        # With no live task there, the repository noted beside the worktrees
        # names the project: removing a record notes it, also for a task
        # created before hosts noted repositories.
        self.assertFalse((self.state / "worktrees" / self.repo_hash / roost.REPOSITORY_MARKER).exists())
        self.store.remove("0a1b2c3d4e5f6a7b")
        self.assertEqual((self.state / "worktrees" / self.repo_hash / roost.REPOSITORY_MARKER).read_text(),
                         self.repo + "\n")
        names = {task["name"]: task for task in self.search("csv")["tasks"]}
        self.assertEqual((names["fix csv quoting"]["repo"], names["csv import"]["repo"]), (self.repo, self.repo))
        self.assertTrue(names["fix csv quoting"]["past"])

    def test_words_with_quotes_match_and_snippets_show_the_word(self):
        worktree = self.state / "worktrees" / self.repo_hash / "t-111111"
        long = "word " * 200 + "the \"needle\" here " + "tail " * 200
        self.conversation(worktree, "s", [self.said("assistant", [{"type": "text", "text": long}], 1),
                                          self.said("user", "needle again", 1), self.said("user", "needle and", 1)])
        task = self.search("needle")["tasks"][0]
        # A retired task is told apart by its worktree, and messages by
        # session and line, even where their times are equal.
        self.assertEqual(task["key"], self.repo_hash + "/t-111111")
        self.assertEqual([(hit["session"], hit["line"]) for hit in task["hits"]], [("s", 1), ("s", 2), ("s", 3)])
        # JSON may escape non-ASCII characters, as this test's writer does.
        self.conversation(worktree, "u", [self.said("user", "Café crème", 9)])
        self.assertIn("\\u00e9", (self.home / ".claude/projects" / roost.claude_project_folder(str(worktree))
                                   / "u.jsonl").read_text())
        self.assertEqual([hit["text"] for hit in self.search("CAFÉ")["tasks"][0]["hits"]], ["Café crème"])
        hit = self.search('"needle"')["tasks"][0]["hits"][0]
        self.assertIn('the "needle" here', hit["snippet"])
        self.assertTrue(hit["snippet"].startswith("…") and hit["snippet"].endswith("…"))
        self.assertLessEqual(len(hit["snippet"]), roost.SEARCH_SNIPPET + 2)
        self.assertTrue(hit["text"].endswith("…"))
        self.assertLessEqual(len(hit["text"]), roost.SEARCH_TEXT_LIMIT + 1)
        # No live task or marker names this repository.
        self.assertIsNone(self.search("needle")["tasks"][0]["repo"])

    def test_results_are_capped(self):
        worktree = self.state / "worktrees" / self.repo_hash / "t-222222"
        self.conversation(worktree, "s", [self.said("user", "ping %d" % n, n) for n in range(15)])
        # Another session of the task, partly older and partly newer.
        self.conversation(worktree, "r", [self.said("user", "ping %d" % n, n) for n in (3, 20)])
        task = self.search("ping")["tasks"][0]
        # The newest messages of all its sessions, oldest first.
        self.assertEqual([hit["text"] for hit in task["hits"]], ["ping %d" % n for n in [*range(6, 15), 20]])
        self.assertEqual(task["more"], 7)
        for n in range(roost.SEARCH_TASK_LIMIT + 2):
            self.conversation(self.state / "worktrees" / self.repo_hash / ("p-%06d" % n), "s",
                              [self.said("user", "pong", n)])
        result = self.search("pong")
        self.assertEqual((len(result["tasks"]), result["moreTasks"]), (roost.SEARCH_TASK_LIMIT, 2))

    def test_only_messages_recorded_in_the_worktrees_count(self):
        live = self.state / "worktrees" / self.repo_hash / "live-333333"
        self.store.save(dict(id="3333333333333333", name="live", repo=self.repo, worktree=str(live), status="ready"))
        self.conversation(live, "s", [self.said("user", "zebra from the task", 1),
                                      self.said("user", "zebra from elsewhere", 2, cwd="/elsewhere"),
                                      self.said("user", "zebra from nowhere", 3, cwd=None)])
        # A session run in a repository's folder of worktrees is no task's.
        self.conversation(self.state / "worktrees" / self.repo_hash, "s", [self.said("user", "zebra in between", 4)])
        # Claude's folder names are lossy: this unrelated directory's starts
        # like those of directories in the worktrees.
        lookalike = Path(str(self.state / "worktrees") + "-evil") / "abc"
        self.assertTrue(roost.claude_project_folder(str(lookalike)).startswith(
            roost.claude_project_folder(str(self.state / "worktrees")) + "-"))
        self.conversation(lookalike, "s", [self.said("user", "zebra lookalike", 3)])
        result = self.search("zebra")["tasks"]
        self.assertEqual([(task["name"], [hit["text"] for hit in task["hits"]]) for task in result],
                         [("live", ["zebra from the task"])])

    def test_a_long_state_path_still_finds_retired_tasks(self):
        # Claude cuts names over 200 characters and adds a hash of the whole path.
        state = Path(self.temp.name) / ("d" * 70) / ("e" * 70) / ("f" * 70) / "state"
        worktree = state / "worktrees" / self.repo_hash / "old-task-444444"
        self.assertGreater(len(os.path.realpath(state / "worktrees")), 200)
        self.conversation(worktree, "s", [self.said("user", "yak shaving", 1)])
        reply = roost.rpc(dict(root=str(state), action="search", query="yak"))
        self.assertEqual([(task["name"], task["past"]) for task in reply["result"]["tasks"]], [("old task", True)])

    def test_a_repository_whose_name_ends_in_a_space_keeps_it(self):
        repo = "/work/shop "
        repo_hash = hashlib.sha256(repo.encode()).hexdigest()[:10]
        worktree = self.state / "worktrees" / repo_hash / "spaced-555555"
        self.store.save(dict(id="5555555555555555", name="spaced", repo=repo, worktree=str(worktree), status="ready"))
        self.store.remove("5555555555555555")
        self.conversation(worktree, "s", [self.said("user", "walrus", 1)])
        self.assertEqual(self.search("walrus")["tasks"][0]["repo"], repo)

    def test_tasks_retired_or_created_during_a_search_are_shown_as_they_are_now(self):
        retiring = self.state / "worktrees" / self.repo_hash / "retiring-666666"
        arriving = self.state / "worktrees" / self.repo_hash / "arriving-777777"
        self.store.save(dict(id="6666666666666666", name="retiring", repo=self.repo, worktree=str(retiring),
                             branch="roost/retiring-666666", status="ready"))
        self.conversation(retiring, "s", [self.said("user", "otter one", 1)])
        self.conversation(arriving, "s", [self.said("user", "otter two", 2)])
        scan = roost.search_transcript

        def meanwhile(*args):
            # Search reads transcripts without the registry lock.
            if self.store.path("6666666666666666").exists():
                self.store.remove("6666666666666666")
                self.store.save(dict(id="7777777777777777", name="Arriving", repo=self.repo,
                                     worktree=str(arriving), status="starting"))
            return scan(*args)

        with patch.object(roost, "search_transcript", meanwhile):
            found = {task["name"]: task for task in self.search("otter")["tasks"]}
        self.assertEqual((found["retiring"].get("id"), found["retiring"]["past"], found["retiring"]["key"]),
                         (None, True, self.repo_hash + "/retiring-666666"))
        self.assertEqual((found["Arriving"]["id"], found["Arriving"].get("past")), ("7777777777777777", None))

    def test_newest_conversations_are_searched_first_within_a_time(self):
        older = self.state / "worktrees" / self.repo_hash / "older-888888"
        newer = self.state / "worktrees" / self.repo_hash / "newer-999999"
        for worktree, when in ((older, 1000), (newer, 2000)):
            folder = self.conversation(worktree, "s", [self.said("user", "heron", 1)])
            os.utime(folder / "s.jsonl", (when, when))
        self.assertFalse(self.search("heron")["incomplete"])
        read = []
        scan = roost.search_transcript

        def reading(path, *args):
            read.append(path.parent.name.rsplit("-", 2)[-2])
            return scan(path, *args)

        with patch.object(roost, "search_transcript", reading):
            self.search("heron")
        self.assertEqual(read, ["newer", "older"])
        # Out of time, a host says its results may be incomplete.
        with patch.object(roost, "SEARCH_SECONDS", -1):
            result = self.search("heron")
        self.assertEqual((result["tasks"], result["incomplete"]), ([], True))
        # Time can also run out within a long conversation, which keeps
        # what it found until then.
        self.conversation(newer, "s", [self.said("user", "heron %d" % n, 1) for n in range(3000)])
        begun = []

        def reading_then_late(path, *args):
            begun.append(path)
            return scan(path, *args)

        # Time runs out once reading has begun, so within the first conversation.
        with patch.object(roost, "search_transcript", reading_then_late), \
             patch.object(roost.time, "monotonic", lambda: 1000 if begun else 0):
            result = self.search("heron")
        self.assertEqual(len(begun), 1)
        # The time covers finding conversations, on a slow disk say.
        now = [0]
        listing = Path.iterdir

        def slow_listing(folder):
            now[0] = 30
            return listing(folder)

        with patch.object(roost.Path, "iterdir", slow_listing), patch.object(roost.time, "monotonic", lambda: now[0]):
            self.assertTrue(self.search("heron")["incomplete"])
        self.assertTrue(result["incomplete"])
        self.assertEqual(len(result["tasks"][0]["hits"]) + result["tasks"][0]["more"], 1023)

    def test_an_empty_query_is_refused(self):
        reply = roost.rpc(dict(root=str(self.state), action="search", query="  "))
        self.assertEqual(reply, {"ok": False, "error": "Search for at least one word"})


class LastMessage(unittest.TestCase):
    """Adapters read the end of each agent's own transcript, from a fake HOME."""

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.home = Path(self.temp.name)
        patcher = patch.dict(os.environ, HOME=str(self.home))
        patcher.start()
        self.addCleanup(patcher.stop)
        self.addCleanup(self.temp.cleanup)

    def write(self, path, entries, raw=""):
        path = self.home / path
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text("".join(json.dumps(entry) + "\n" for entry in entries) + raw)
        return path

    def test_claude_takes_the_last_assistant_text_in_the_task_directory_transcript(self):
        task = dict(agent="claude", worktree="/work/my.repo/wt", agentSession="s1")
        reply = lambda *parts: {"message": {"role": "assistant", "content": list(parts)}}
        text = lambda value: {"type": "text", "text": value}
        self.write(".claude/projects/-work-my-repo-wt/s1.jsonl", [
            reply(text("old")),
            {"message": {"role": "user", "content": "hi"}},
            reply(text("first part"), {"type": "thinking", "thinking": "no"}, text("second part")),
            reply({"type": "tool_use", "name": "Bash", "input": {}}),
        ], raw="not json\n{\"truncated")
        self.assertEqual(roost.last_message(task), "first part\n\nsecond part")
        legacy = dict(task, agentSession=None, claudeSession="s1")
        self.assertEqual(roost.last_message(legacy), "first part\n\nsecond part")

    def test_claude_folders_are_named_as_claude_code_names_them(self):
        # Expected names computed with Claude Code's own function, in Node.
        long = "/nowhere/first_last/" + "a_very_long_directory_name/" * 8 + "fix-parser-abc123"
        for path, folder in (
                ("/nowhere/.local/share/roost/worktrees/71bdd2542f/fix_parser-abc123",
                 "-nowhere--local-share-roost-worktrees-71bdd2542f-fix-parser-abc123"),
                ("/nowhere/jo smith/ünï 🚀/x", "-nowhere-jo-smith--n-----x"),
                (long, "-nowhere-first-last" + "-a-very-long-directory-name" * 6
                 + "-a-very-long-direct-69ndg4"),
                # Cut at 200, then "-" and the hash.
                ("/nowhere/" + "é" * 195, "-nowhere-" + "-" * 191 + "-a7c1o1")):
            with self.subTest(path=path):
                self.assertEqual(roost.claude_project_folder(path), folder)
        # Claude names the folder after the physical path, as getcwd() gives it.
        real = self.home / "real_dir"
        real.mkdir()
        (self.home / "link").symlink_to(real)
        self.assertEqual(roost.claude_project_folder(str(self.home / "link")),
                         re.sub(r"[^a-zA-Z0-9]", "-", os.path.realpath(real)))
        task = dict(agent="claude", worktree=str(self.home / "link"), agentSession="s3")
        self.write(".claude/projects/%s/s3.jsonl" % roost.claude_project_folder(str(real)),
                   [{"message": {"role": "assistant", "content": "found it"}}])
        self.assertEqual(roost.last_message(task), "found it")

    def test_claude_turns_stopped_by_you_are_read_from_the_transcript(self):
        start = datetime.datetime(2026, 10, 5, 14, 0, tzinfo=datetime.timezone.utc)
        task = dict(agent="claude", worktree="/w", agentSession="s2", updatedAt=start.isoformat())
        at = lambda seconds: (start + datetime.timedelta(seconds=seconds)).isoformat().replace("+00:00", "Z")
        user = lambda content, seconds: {"type": "user", "timestamp": at(seconds),
                                         "message": {"role": "user", "content": content}}
        reply = {"type": "assistant", "timestamp": at(1),
                 "message": {"role": "assistant", "content": [{"type": "tool_use", "name": "Bash"}]}}
        rejected = user([{"type": "tool_result", "is_error": True, "content": "The user doesn't want to proceed"}], 5)
        marker = user([{"type": "text", "text": "[Request interrupted by user for tool use]"}], 5)
        tail = [{"type": "system", "timestamp": at(6)}, {"type": "last-prompt"}]
        transcript = lambda *entries: self.write(".claude/projects/-w/s2.jsonl", list(entries))
        interrupted = lambda: roost.ClaudeAgent().interrupted(task)
        transcript(reply, rejected, marker, *tail)
        self.assertTrue(interrupted())
        # Esc while it works.
        transcript(reply, user([{"type": "text", "text": "[Request interrupted by user]"}], 5))
        self.assertTrue(interrupted())
        # Not once it has a new prompt, nor for an interrupt before its last event.
        transcript(reply, marker, user("Try again", 7))
        self.assertFalse(interrupted())
        transcript(reply, user([{"type": "text", "text": "[Request interrupted by user]"}], -5))
        self.assertFalse(interrupted())
        transcript(reply, *tail)
        self.assertFalse(interrupted())
        self.assertFalse(roost.ClaudeAgent().interrupted(dict(task, agentSession="missing")))

    def test_only_the_end_of_a_large_transcript_is_read(self):
        task = dict(agent="claude", worktree="/w", agentSession="big")
        line = {"message": {"role": "assistant", "content": [{"type": "text", "text": "tail"}]}}
        filler = {"message": {"role": "user", "content": "y" * 1000}}
        self.write(".claude/projects/-w/big.jsonl", [dict(line, message=dict(line["message"], content="head"))]
                   + [filler] * 600 + [line])
        self.assertEqual(roost.last_message(task), "tail")
        self.write(".claude/projects/-w/big.jsonl", [line] + [filler] * 600)
        self.assertIsNone(roost.last_message(task))

    def test_codex_finds_the_rollout_by_session_id(self):
        task = dict(agent="codex", worktree="/w", agentSession="abc-123")
        message = lambda role, value: {"type": "response_item", "payload": {
            "type": "message", "role": role, "content": [{"type": "output_text", "text": value}]}}
        self.write(".codex/sessions/2026/08/28/rollout-2026-08-28T18-33-42-abc-123.jsonl", [
            message("assistant", "done"), message("user", "thanks"),
            {"type": "event_msg", "payload": {"type": "task_complete"}}])
        self.write(".codex/sessions/2026/08/28/rollout-2026-08-28T18-33-42-other.jsonl",
                   [message("assistant", "wrong")])
        self.assertEqual(roost.last_message(task), "done")

    def test_the_reply_codex_reports_is_the_latest_reply(self):
        # Codex 0.163.0's Stop carries the turn's reply, ahead of its rollout.
        agent = roost.CodexAgent()
        task = dict(agent="codex", worktree="/w", agentSession="abc-123")
        self.write(".codex/sessions/2026/08/28/rollout-2026-08-28T18-33-42-abc-123.jsonl", [
            {"type": "response_item", "payload": {"type": "message", "role": "assistant",
                                                  "content": [{"type": "output_text", "text": "from the rollout"}]}}])
        observe = lambda **payload: agent.observe(dict(payload, session_id="abc-123"), "running")
        stopped = observe(hook_event_name="Stop", last_assistant_message="  PONG\n")
        self.assertEqual(stopped["lastReply"], "PONG")
        self.assertEqual(roost.last_message(dict(task, **stopped)), "PONG")
        # A new turn, or a cleared conversation, has no reply yet: the rollout says what is newest.
        self.assertIsNone(observe(hook_event_name="UserPromptSubmit", prompt="next")["lastReply"])
        self.assertIsNone(observe(hook_event_name="SessionStart", source="clear")["lastReply"])
        self.assertEqual(roost.last_message(dict(task, lastReply=None)), "from the rollout")
        # Older Codex, or a turn with no words, reports none.
        for reply in (None, "", "  ", 5):
            self.assertNotIn("lastReply", observe(hook_event_name="Stop", last_assistant_message=reply))
        self.assertNotIn("lastReply", observe(hook_event_name="SessionStart", source="resume"))
        long = observe(hook_event_name="Stop", last_assistant_message="y" * 3000)["lastReply"]
        self.assertEqual(len(long), roost.LAST_MESSAGE_LIMIT + 1)
        self.assertEqual(roost.last_message(dict(task, lastReply=long)), "y" * 2000 + "…")

    def test_pi_reads_its_session_file(self):
        path = self.write("pi/session.jsonl", [
            {"type": "session", "id": "x"},
            {"type": "message", "message": {"role": "assistant", "content": [{"type": "text", "text": "pi says"}]}},
            {"type": "message", "message": {"role": "user", "content": "ok"}}])
        self.assertEqual(roost.last_message(dict(agent="pi", worktree="/w", agentSession=str(path))), "pi says")

    def test_only_agents_whose_hooks_say_what_you_sent_report_it(self):
        self.assertEqual(roost.ClaudeAgent().observe(
            dict(hook_event_name="UserPromptSubmit", prompt="Next"))["lastPrompt"], "Next")
        self.assertEqual(roost.CodexAgent().observe(
            dict(hook_event_name="UserPromptSubmit", prompt="Next"))["lastPrompt"], "Next")
        self.assertNotIn("lastPrompt", roost.ClaudeAgent().observe(dict(hook_event_name="Stop")))
        self.assertNotIn("lastPrompt", roost.PiAgent().observe(dict(event="agent_start")))
        self.assertNotIn("lastPrompt", roost.OpenCodeAgent().observe(dict(event="status", status="busy"), "ready"))
        # A task recorded before the field, as by an older helper, has none.
        self.assertIsNone(roost.later_prompt(dict(prompt="Fix it"), None))
        self.assertIsNone(roost.later_prompt(dict(prompt="Fix it"), " Fix it\n"))
        self.assertEqual(roost.later_prompt(dict(prompt=None), "Fix it"), "Fix it")
        # One that starts as the first did, beyond what the panel shows, is another.
        said = roost.later_prompt(dict(prompt="x" * 2500 + " and then a"), "x" * 2500 + " and then b")
        self.assertEqual(said, "x" * 2000 + "…")

    def test_missing_or_malformed_transcripts_give_none(self):
        for agent in ("claude", "codex", "pi", "opencode"):
            for session in (None, "missing", "../escape", str(self.home / "nowhere.jsonl")):
                self.assertIsNone(roost.last_message(dict(agent=agent, worktree="/w", agentSession=session)))
        self.write(".claude/projects/-w/bad.jsonl", [[], "x", {"message": "str"}, {"message": {"role": "assistant", "content": 5}}])
        self.assertIsNone(roost.last_message(dict(agent="claude", worktree="/w", agentSession="bad")))
        self.assertIsNone(roost.last_message(dict(agent="unknown", worktree="/w")))
        self.assertIsNone(roost.last_message(dict(agent="claude")))


class ProgramStatus(unittest.TestCase):
    def filter(self):
        self.replies, self.reports = [], []
        return roost.ProgramStatusFilter(self.replies.append, self.reports.append)

    def test_reports_and_the_probe_leave_the_output_however_it_is_split(self):
        blocked = (b"\x1b]7501;state=blocked:kind=permission:app=claude-code:msg="
                   + base64.b64encode(b"Bash command") + b"\x1b\\")
        output = (b"before\x1b]7501;?\x1b\\\x1b[c\x1b]0;title\x07" + blocked
                  + b"\x1b]7501;state=done\x07after\x1b")
        for size in range(1, len(output) + 1):
            statuses = self.filter()
            shown = b"".join(statuses.feed(output[i:i + size]) for i in range(0, len(output), size))
            self.assertEqual(shown + statuses.flush(everything=True), b"before\x1b[c\x1b]0;title\x07after\x1b")
            self.assertEqual(self.replies, [roost.PROGRAM_STATUS_REPLY])
            self.assertEqual([(r["state"], r.get("kind"), r.get("msg")) for r in self.reports],
                             [("blocked", "permission", "Bash command"), ("done", None, None)])

    def test_what_is_not_a_report_passes_on_as_it_is(self):
        statuses = self.filter()
        # One longer than the protocol allows is not read.
        huge = b"\x1b]7501;state=done:msg=" + base64.b64encode(b"x" * 3100) + b"\x1b\\"
        self.assertGreater(len(huge), roost.PROGRAM_STATUS_LIMIT)
        self.assertEqual(statuses.feed(huge), b"")
        cut = b"\x1b]7501;state=working\x1b[31mred"
        self.assertEqual(statuses.feed(cut) + statuses.flush(everything=True), cut)
        # An ESC at the end waits a moment for what may follow; a sequence
        # under way waits for its end.
        self.assertEqual(statuses.feed(b"text\x1b"), b"text")
        self.assertTrue(statuses.waiting)
        self.assertEqual(statuses.flush(), b"\x1b")
        self.assertEqual(statuses.feed(b"\x1b]7501;state=wo"), b"")
        self.assertFalse(statuses.waiting)
        self.assertEqual(statuses.flush(), b"")
        # One that never ends within the protocol's limit is not one.
        endless = b"\x1b]7501;state=wo" + b"x" * roost.PROGRAM_STATUS_LIMIT
        self.assertEqual(statuses.feed(b"x" * roost.PROGRAM_STATUS_LIMIT), endless)
        self.assertEqual(self.reports, [])

    def test_recording_starts_no_thread_before_the_first_report(self):
        # The agent's process starts from the runner's before any report;
        # its terminal is set up between fork and exec, unsafe with threads.
        with tempfile.TemporaryDirectory() as root:
            before = threading.active_count()
            report, finish = roost.program_status_recorder(roost.Store(root), "0" * 16, "run")
            self.assertEqual(threading.active_count(), before)
            finish()
            report(dict(state="idle"))
            self.assertEqual(threading.active_count(), before + 1)
            finish()
            self.assertEqual(threading.active_count(), before)

    def test_keys_typed_before_the_relay_starts_reach_the_agent(self):
        pane, terminal = os.openpty()
        os.write(pane, b"typed early\r")
        relay = ("import importlib.util, os, sys\n"
                 "spec = importlib.util.spec_from_file_location('roost_remote', sys.argv[1])\n"
                 "roost = importlib.util.module_from_spec(spec)\n"
                 "spec.loader.exec_module(roost)\n"
                 "sys.exit(roost.relay([sys.executable, '-c', 'print(\"GOT \" + input())'], '.',"
                 " dict(os.environ), lambda fields: None))\n")
        try:
            done = subprocess.run([sys.executable, "-c", relay, str(SOURCE)], stdin=terminal, stdout=terminal,
                                  stderr=terminal, timeout=10)
            self.assertEqual(done.returncode, 0)
            shown = b""
            while select.select([pane], [], [], 0.2)[0]:
                shown += os.read(pane, 65536)
            self.assertIn(b"GOT typed early", shown)
        finally:
            os.close(pane)
            os.close(terminal)

    def test_the_relay_ends_with_its_agent_whatever_it_left_writing(self):
        pane, terminal = os.openpty()
        # A command left running in the background, which outlives the
        # agent's hangup, as with nohup, and writes until its terminal goes.
        writer = ("import signal, sys\nsignal.signal(signal.SIGHUP, signal.SIG_IGN)\n"
                  "while True:\n    sys.stdout.write('x' * 100 + '\\n')\n    sys.stdout.flush()\n")
        # The agent ends once the command ignores the hangup its end sends.
        agent = "import subprocess, sys, time; subprocess.Popen([sys.executable, '-c', %r]); time.sleep(1)" % writer
        relay = ("import importlib.util, os, sys\n"
                 "spec = importlib.util.spec_from_file_location('roost_remote', sys.argv[1])\n"
                 "roost = importlib.util.module_from_spec(spec)\n"
                 "spec.loader.exec_module(roost)\n"
                 "sys.exit(roost.relay([sys.executable, '-c', sys.argv[2]], '.', dict(os.environ),"
                 " lambda fields: None))\n")
        process = subprocess.Popen([sys.executable, "-c", relay, str(SOURCE), agent],
                                   stdin=terminal, stdout=terminal, stderr=terminal)
        try:
            deadline = time.monotonic() + 10
            while process.poll() is None and time.monotonic() < deadline:
                if select.select([pane], [], [], 0.1)[0]:
                    os.read(pane, 65536)
            self.assertEqual(process.poll(), 0)
        finally:
            if process.poll() is None:
                process.kill()
            os.close(pane)
            os.close(terminal)

    def test_reading_a_report(self):
        parse = roost.parse_program_status
        self.assertIsNone(parse(b"state=sleeping"))
        self.assertIsNone(parse(b"kind=permission"))
        self.assertIsNone(parse("state=done:msg=é".encode()))
        self.assertEqual(parse(b"state=idle:state=done:junk"), dict(state="done"))
        msg = base64.b64encode("Run\n\x1b[2Jrm ‮-rf now".encode()).decode()
        self.assertEqual(parse(("state=blocked:msg=" + msg).encode())["msg"], "Run [2Jrm -rf now")
        self.assertEqual(parse(b"state=done:msg=not*base64"), dict(state="done"))

    def apply(self, task, state, **fields):
        roost.apply_program_status(task, dict(state=state, **fields), "run")
        return {key: task.get(key) for key in ("status", "lastEvent", "request", "activity", "error")}

    def test_the_agents_word_on_whether_it_works_waits_or_is_done(self):
        task = dict(status="starting", runId="run")
        self.assertEqual(self.apply(task, "idle")["lastEvent"], "SessionStart")
        self.assertEqual(task["programStatusRun"], "run")
        self.assertEqual(self.apply(task, "working", msg="Thinking"),
                         dict(status="running", lastEvent="Working", request=None, activity="Thinking", error=None))
        self.assertEqual(self.apply(task, "blocked", kind="permission", msg="Bash command"),
                         dict(status="permission", lastEvent="Blocked", request="Bash command", activity=None,
                              error=None))
        self.assertEqual(self.apply(task, "working")["lastEvent"], "Approved")
        self.assertIsNone(task.get("request"))
        self.assertEqual(self.apply(task, "idle")["lastEvent"], "Interrupt")
        self.apply(task, "working")
        self.apply(task, "blocked", kind="question")
        self.assertEqual(self.apply(task, "idle")["lastEvent"], "Interrupt")
        # A dialog while it rests, as at its start or one you open, ends no turn.
        for rest, after in (("starting", "idle"), ("ready", "done"), ("ready", "idle")):
            task = dict(status=rest, runId="run")
            self.assertEqual(self.apply(task, "blocked", kind="auth")["status"], "permission")
            self.assertEqual(self.apply(task, after), dict(status="ready", lastEvent="Idle", request=None,
                                                         activity=None, error=None))
        task = dict(status="starting", runId="run")
        self.apply(task, "working")
        self.assertEqual(self.apply(task, "done")["lastEvent"], "Stop")
        self.assertEqual(self.apply(task, "error", msg="Rate limited"),
                         dict(status="failed", lastEvent="Error", request=None, activity=None,
                              error="Its turn ended on an error: Rate limited"))
        self.assertIsNone(self.apply(task, "working")["error"])

    def test_what_hooks_know_better_is_kept(self):
        # A hook names the tool just before the agent says it waits.
        task = dict(status="running", request="Asks to run make", requestCommand="make")
        self.apply(task, "working", msg="Thinking")
        self.assertEqual(self.apply(task, "blocked", kind="permission", msg="Bash command")["request"],
                         "Asks to run make")
        self.assertEqual(self.apply(dict(status="running"), "blocked", kind="question")["request"],
                         "Asks you a question")
        # The agent's own words give way to its next request, and to a hook's.
        with tempfile.TemporaryDirectory() as root:
            store = roost.Store(root)
            task = dict(id="0" * 16, agent="claude", worktree="/w", status="running", runId="run",
                        programStatusRun="run")
            self.assertEqual(self.apply(task, "blocked", kind="permission", msg="approve Bash: ls")["request"],
                             "approve Bash: ls")
            self.assertEqual(self.apply(task, "blocked", kind="permission", msg="approve Bash: make")["request"],
                             "approve Bash: make")
            store.save(task)
            roost.update_hook(store, task["id"], dict(hook_event_name="PermissionRequest", tool_name="Bash",
                                                      tool_input=dict(command="make")), "run")
            task = store.read(task["id"])
            self.assertEqual((task["status"], task["request"]), ("permission", "Asks to run make"))
            self.assertEqual(self.apply(task, "blocked", kind="permission", msg="approve Bash: make")["request"],
                             "Asks to run make")
            self.assertNotIn("requestFrom", roost.outgoing(task))
        self.assertEqual(self.apply(dict(status="background"), "done")["status"], "background")
        # Each report replaces the last: a step's description goes with it.
        self.assertIsNone(self.apply(dict(status="running", activity="Reading notes.py"), "working")["activity"])
        self.assertFalse(roost.apply_program_status(dict(status="running", programStatusRun="run"),
                                                    dict(state="blocked", id="subagent"), "run"))
        beside = roost.beside_program_status
        hook = dict(status="running", updatedAt="t", lastEvent="PreToolUse", error=None, agentSession="s")
        self.assertEqual(beside(hook, "permission"), dict(agentSession="s"))
        self.assertEqual(beside(dict(hook, status="background"), "ready")["status"], "background")
        self.assertEqual(beside(dict(hook, status="failed"), "running")["status"], "failed")

    def test_codex_works_and_idles_between_turns_its_hooks_mark(self):
        # As Codex 0.163.0 reported in a live run: no done, and work at
        # startup, before any prompt.
        task = dict(status="starting", agent="codex", runId="run")
        for state in ("idle", "working", "idle"):
            self.apply(task, state)
        self.assertEqual((task["status"], task["lastEvent"]), ("ready", "SessionStart"))
        # Its hooks start and end a turn; the reports between change nothing.
        with tempfile.TemporaryDirectory() as root:
            store = roost.Store(root)
            task.update(id="0" * 16, worktree="/w")
            store.save(task)

            def hook(event, **fields):
                roost.update_hook(store, task["id"], dict(hook_event_name=event, **fields), "run")
                return store.read(task["id"])

            def report(state):
                task = store.read("0" * 16)
                self.apply(task, state)
                store.save(task)
                return task

            report("working")
            self.assertEqual(hook("UserPromptSubmit")["status"], "running")
            self.assertEqual((hook("Stop")["status"], report("idle")["lastEvent"]), ("ready", "Stop"))
            hook("UserPromptSubmit")
            self.assertEqual(hook("Interrupt")["lastEvent"], "Interrupt")
            self.assertEqual(report("idle")["lastEvent"], "Interrupt")
            # An approval shows at once; another tool's end, while it asks, doesn't.
            hook("UserPromptSubmit")
            self.assertEqual(hook("PermissionRequest", tool_name="Bash", tool_input=dict(command="make"))["request"],
                             "Asks to run make")
            self.assertEqual(report("blocked")["request"], "Asks to run make")
            self.assertEqual(hook("PostToolUse", tool_name="Bash")["status"], "permission")
            self.assertEqual(report("working")["lastEvent"], "Approved")
            # Work after its turn, as on a command it left running, is not a turn.
            hook("Stop")
            self.assertEqual(report("working")["status"], "ready")
            # A turn that ended without its hooks, as on a failed request.
            hook("UserPromptSubmit")
            self.assertEqual(report("idle")["lastEvent"], "Idle")

    def test_a_codex_report_older_than_its_last_hook_is_left_out(self):
        # The relay reads reports at once but records them once the registry
        # is free; Codex's hooks record theirs before it goes on.
        with tempfile.TemporaryDirectory() as root:
            store = roost.Store(root)
            store.save(dict(id="0" * 16, agent="codex", worktree="/w", status="ready", runId="run",
                            programStatusRun="run"))
            said = time.time()
            roost.update_hook(store, "0" * 16, dict(hook_event_name="UserPromptSubmit"), "run")
            task = store.read("0" * 16)
            # The last turn's end and this one's start, recorded only now.
            for state in ("idle", "working"):
                roost.apply_program_status(task, dict(state=state, receivedAt=said), "run")
            self.assertEqual(task["status"], "running")
            roost.apply_program_status(task, dict(state="idle", receivedAt=time.time()), "run")
            self.assertEqual((task["status"], task["lastEvent"]), ("ready", "Idle"))
            self.assertNotIn("hookAt", roost.outgoing(dict(task)))
        # The recorder notes when each report was read.
        with tempfile.TemporaryDirectory() as root:
            store = roost.Store(root)
            store.save(dict(id="0" * 16, agent="codex", worktree="/w", status="running", runId="run",
                            hookAt=time.time() + 60))
            report, finish = roost.program_status_recorder(store, "0" * 16, "run")
            report(dict(state="idle"))
            finish()
            self.assertEqual(store.read("0" * 16)["status"], "running")

    def test_codex_sessions_outside_the_worktree_are_not_the_tasks(self):
        # With memories on, Codex runs its memory agent as a session of its
        # own in the same process, and Roost's hooks report it too.
        with tempfile.TemporaryDirectory() as root:
            store = roost.Store(root)
            worktree = Path(root) / "w"
            (worktree / "sub").mkdir(parents=True)
            store.save(dict(id="0" * 16, agent="codex", worktree=str(worktree), status="starting", runId="run"))
            hook = lambda event, session, cwd: roost.update_hook(
                store, "0" * 16, dict(hook_event_name=event, session_id=session, cwd=str(cwd)), "run")
            hook("SessionStart", "task", worktree)
            hook("UserPromptSubmit", "task", worktree)
            memories = Path(root) / "home/.codex/memories"
            for event in ("SessionStart", "UserPromptSubmit", "Stop"):
                hook(event, "memory", memories)
            task = store.read("0" * 16)
            self.assertEqual((task["status"], task["agentSession"]), ("running", "task"))
            # Its own subagents, in a folder of the worktree, are the task's.
            hook("Stop", "task", worktree / "sub")
            self.assertEqual(store.read("0" * 16)["status"], "ready")
            # A new conversation in the worktree, as with /new, is the task's.
            hook("SessionStart", "next", worktree)
            self.assertEqual(store.read("0" * 16)["agentSession"], "next")

    def test_pi_dialogs_wait_on_you(self):
        pi = roost.PiAgent()
        asks = pi.observe(dict(event="ui_prompt_start", title="Allow\x1b[2J\n bash?‮"), "running")
        self.assertEqual((asks["status"], asks["request"]), ("permission", "Allow [2J bash?"))
        self.assertNotIn("request", pi.observe(dict(event="ui_prompt_start"), "background"))
        self.assertEqual(pi.observe(dict(event="ui_prompt_start", title="Trust?"), "starting")["status"],
                         "permission")
        self.assertEqual(pi.observe(dict(event="ui_prompt_end", idle=False), "permission")["status"], "running")
        self.assertEqual(pi.observe(dict(event="ui_prompt_end", idle=True), "permission")["status"], "ready")
        # Its context can't say, after a session switch.
        self.assertEqual(pi.observe(dict(event="ui_prompt_end"), "permission")["status"], "running")
        self.assertIsNone(pi.observe(dict(event="ui_prompt_end", idle=True), "ready"))
        stopped = pi.observe(dict(event="agent_settled", aborted=True), "ready")
        self.assertEqual((stopped["status"], stopped["lastEvent"]), ("ready", "Interrupt"))
        self.assertIsNone(pi.observe(dict(event="agent_settled", aborted=False), "ready"))

    def test_opencode_requests_read_as_roosts(self):
        agent = roost.OpenCodeAgent()
        ask = lambda **fields: agent.observe(dict(event="asked", session="ses_a", **fields), "running")["request"]
        self.assertEqual(ask(permission="bash", patterns=["make *"], metadata=dict(command="make deploy")),
                         "Asks to run make deploy")
        self.assertEqual(ask(permission="bash", patterns=["make *"], metadata={}), "Asks to run make *")
        self.assertEqual(ask(permission="edit", patterns=["a.py"], metadata=dict(filepath="/w/a.py")),
                         "Asks to edit a.py")
        self.assertEqual(ask(permission="webfetch", patterns=["https://x"], metadata=dict(url="https://x")),
                         "Asks to fetch https://x")
        self.assertEqual(ask(permission="external_directory", patterns=["/etc/*"]),
                         "Asks to use external directory for /etc/*")
        self.assertEqual(ask(questions=[dict(question="Which?"), dict(question="And?")]), "Asks: Which? (and 1 more)")
        self.assertEqual(ask(), "Asks to use a tool")
        # Between turns it holds up no turn.
        self.assertEqual(agent.observe(dict(event="asked", questions=[]), "ready")["lastEvent"], "Dialog")
        self.assertEqual(agent.observe(dict(event="replied"), "permission")["status"], "running")
        self.assertIsNone(agent.observe(dict(event="replied"), "ready"))
        self.assertIsNone(agent.observe(dict(event="unknown")))
        retry = agent.observe(dict(event="status", status="retry", session="ses_a"), "running")
        self.assertEqual((retry["status"], retry["agentSession"]), ("running", "ses_a"))
        self.assertNotIn("lastReply", retry)
        self.assertIsNone(agent.observe(dict(event="status", status="busy"), "ready")["lastReply"])

    def test_opencode_loads_its_observer_beside_the_users_inline_config(self):
        with tempfile.TemporaryDirectory() as root:
            store = roost.Store(root)
            agent = roost.OpenCodeAgent()
            task = dict(id="0" * 16)
            plugin = agent.plugin(store).as_uri()
            config = lambda env: json.loads(agent.environment(store, task, env)["OPENCODE_CONFIG_CONTENT"])
            self.assertEqual(config({})["plugin"], [plugin])
            mine = config(dict(OPENCODE_CONFIG_CONTENT='{"model": "m", "plugin": ["theirs"]}'))
            self.assertEqual((mine["model"], mine["plugin"]), ("m", ["theirs", plugin]))
            for bad in ("{", "[]", '"x"'):
                with self.assertRaises(roost.RoostError):
                    agent.environment(store, task, dict(OPENCODE_CONFIG_CONTENT=bad))
            # OPENCODE_PURE leaves plugins out, as --pure does.
            for pure in ("1", "true", "TRUE"):
                with self.assertRaises(roost.RoostError):
                    agent.environment(store, task, dict(OPENCODE_PURE=pure))
            self.assertIn("OPENCODE_CONFIG_CONTENT", agent.environment(store, task, dict(OPENCODE_PURE="0")))
            # The OpenCode Roost starts is a new one to report, even from another's shell.
            self.assertEqual(agent.environment(store, task, dict(ROOST_OPENCODE_OBSERVER="42"))["ROOST_OPENCODE_OBSERVER"], "")

    def test_opencode_reads_its_tasks_attachments_without_asking(self):
        with tempfile.TemporaryDirectory() as root:
            store = roost.Store(root)
            agent = roost.OpenCodeAgent()
            task = dict(id="1234567890abcdef")
            env = agent.environment(store, task, {})
            folder = str(store.attachments(task["id"])) + "/*"
            self.assertEqual(env["ROOST_OPENCODE_ATTACHMENTS"], folder)
            # The plugin gives the rule once your config is merged; the inline
            # config Roost writes leaves your permissions alone.
            self.assertEqual(set(json.loads(env["OPENCODE_CONFIG_CONTENT"])), {"plugin"})

    @unittest.skipUnless(shutil.which("node"), "needs Node")
    def test_opencode_plugin_allows_attachments_after_your_rules(self):
        with tempfile.TemporaryDirectory() as root:
            root = Path(root)
            plugin = roost.OpenCodeAgent().plugin(roost.Store(str(root / "state")))
            folder = "/state/attachments/1234567890abcdef/*"
            configs = [
                # Nothing set: each of OpenCode's agents allows the folder.
                {},
                # A word for outside folders, and one for everything, stay
                # theirs: the rule follows them, and leaves other rules be.
                dict(permission=dict(external_directory="deny"),
                     agent=dict(build=dict(model="m", permission=dict(external_directory="deny", bash="ask")),
                                plan=dict(permission="allow"),
                                # After an outside folder's word, a word for everything decides.
                                general=dict(permission={"external_directory": "ask", "*": "deny", "read": "allow"}),
                                explore=dict(permission=dict(external_directory={"/x/*": "allow", folder: "deny"})),
                                mine=dict(permission={"*": {"/y/*": "deny"}})))]
            driver = root / "driver.mjs"
            driver.write_text(
                "const { RoostObserver } = await import(%s);\n"
                "const hooks = await RoostObserver({});\n"
                "const configs = %s;\n"
                "for (const config of configs) await hooks.config(config);\n"
                "console.log(JSON.stringify(configs));\n"
                % (json.dumps(plugin.as_uri()), json.dumps(configs)))
            env = dict(os.environ, ROOST_PYTHON=sys.executable, ROOST_HELPER="/dev/null",
                       ROOST_OPENCODE_ATTACHMENTS=folder)
            env.pop("ROOST_OPENCODE_OBSERVER", None)
            done = subprocess.run(["node", str(driver)], env=env, check=True, timeout=30,
                                  capture_output=True, text=True)
            empty, yours = json.loads(done.stdout.splitlines()[-1])
            self.assertEqual(empty["agent"], {name: dict(permission=dict(external_directory={folder: "allow"}))
                                              for name in ("build", "plan", "general", "explore")})
            agents = yours["agent"]
            self.assertEqual(yours["permission"], dict(external_directory="deny"))
            self.assertEqual(agents["build"], dict(model="m", permission=dict(
                bash="ask", external_directory={"*": "deny", folder: "allow"})))
            self.assertEqual(agents["plan"]["permission"],
                             {"*": "allow", "external_directory": {"*": "allow", folder: "allow"}})
            self.assertEqual(list(agents["general"]["permission"].items()),
                             [("*", "deny"), ("read", "allow"), ("external_directory", {"*": "deny", folder: "allow"})])
            self.assertEqual(list(agents["explore"]["permission"]["external_directory"].items()),
                             [("/x/*", "allow"), (folder, "allow")])
            self.assertEqual(agents["mine"]["permission"],
                             {"*": {"/y/*": "deny"}, "external_directory": {"/y/*": "deny", folder: "allow"}})
            # Without a folder, as for an OpenCode Roost didn't start, nothing changes.
            env.pop("ROOST_OPENCODE_ATTACHMENTS")
            done = subprocess.run(["node", str(driver)], env=env, check=True, timeout=30,
                                  capture_output=True, text=True)
            self.assertEqual(json.loads(done.stdout.splitlines()[-1]), configs)

    def test_a_pi_dialog_at_startup_ends_no_turn(self):
        # It can open before Pi's first report, while its hooks still set
        # its status, and close once the relay does.
        with tempfile.TemporaryDirectory() as root:
            store = roost.Store(root)
            store.save(dict(id="0" * 16, agent="pi", worktree="/w", status="starting", runId="run"))
            roost.update_hook(store, "0" * 16, dict(event="ui_prompt_start", title="Trust this project?"), "run")
            for event, state in ((None, "blocked"), (dict(event="ui_prompt_end", idle=True), None),
                                 (None, "idle")):
                if event:
                    roost.update_hook(store, "0" * 16, event, "run")
                else:
                    task = store.read("0" * 16)
                    roost.apply_program_status(task, dict(state=state, kind="permission"), "run")
                    store.save(task)
            task = store.read("0" * 16)
            self.assertEqual((task["status"], task["lastEvent"]), ("ready", "Idle"))
            self.assertNotIn("request", task)

    @unittest.skipUnless(shutil.which("node"), "needs Node")
    def test_pi_reports_reach_the_helper_in_order(self):
        # Pi doesn't wait for its dialogs' handlers before its next event.
        with tempfile.TemporaryDirectory() as root:
            root = Path(root)
            store = roost.Store(str(root / "state"))
            roost.PiAgent().launch(store, dict(id="0" * 16, command=["pi"], prompt=None), False)
            extension = next(store.root.glob("pi-observer-*.mjs"))
            log = root / "log"
            helper = root / "helper.py"
            helper.write_text("import json, sys, time\n"
                              "event = json.load(sys.stdin)\n"
                              "time.sleep(0.3 if event.get('title') == 'First' else 0)\n"
                              "open(%r, 'a').write(json.dumps(event) + '\\n')\n" % str(log))
            driver = root / "driver.mjs"
            driver.write_text(
                "const { default: observe } = await import(%s);\n"
                "const handlers = {};\n"
                "observe({ on: (name, handler) => { handlers[name] = handler; } });\n"
                "const ctx = { sessionManager: { getSessionFile: () => 's' }, isIdle: () => false };\n"
                "const done = [handlers.ui_prompt_start({ title: 'First' }, ctx),\n"
                "              handlers.ui_prompt_end({}, ctx),\n"
                "              handlers.ui_prompt_start({ title: 'Second' }, ctx)];\n"
                "await Promise.all(done);\n" % json.dumps(extension.as_uri()))
            env = dict(os.environ, ROOST_PYTHON=sys.executable, ROOST_HELPER=str(helper))
            subprocess.run(["node", str(driver)], env=env, check=True, timeout=30)
            events = [json.loads(line) for line in log.read_text().splitlines()]
            self.assertEqual([(e["event"], e.get("title")) for e in events],
                             [("ui_prompt_start", "First"), ("ui_prompt_end", None), ("ui_prompt_start", "Second")])
            self.assertEqual(events[1]["idle"], False)


    @unittest.skipUnless(shutil.which("node"), "needs Node")
    def test_opencode_plugin_reports_the_task_session(self):
        with tempfile.TemporaryDirectory() as root:
            root = Path(root)
            store = roost.Store(str(root / "state"))
            plugin = roost.OpenCodeAgent().plugin(store)
            log = root / "log"
            helper = root / "helper.py"
            helper.write_text("import sys\n"
                              "open(%r, 'a').write(sys.stdin.read() + '\\n')\n" % str(log))
            text = lambda part, message, words, session="ses_a": (
                "message.part.updated", dict(part=dict(id=part, type="text", text=words, messageID=message,
                                                       sessionID=session)))
            status = lambda session, kind: ("session.status", dict(sessionID=session, status=dict(type=kind)))
            events = [
                ("session.created", dict(info=dict(id="ses_a"))),
                status("ses_a", "busy"),
                ("message.updated", dict(info=dict(id="msg_u", role="user"))),
                text("p0", "msg_u", "hi"),
                ("message.updated", dict(info=dict(id="msg_a", role="assistant"))),
                text("p1", "msg_a", "Done."),
                ("session.created", dict(info=dict(id="ses_c", parentID="ses_a"))),
                status("ses_c", "busy"),
                ("question.asked", dict(id="q1", sessionID="ses_c", questions=[dict(question="Which?", header="h")])),
                ("question.asked", dict(id="q2", sessionID="ses_a", questions=[dict(question="And?", header="h")])),
                # Answered first, the newer one leaves the older waiting.
                ("question.replied", dict(requestID="q2", sessionID="ses_a", answers=[["y"]])),
                ("question.replied", dict(requestID="q1", sessionID="ses_c", answers=[["x"]])),
                status("ses_c", "idle"),
                text("p2", "msg_a", "All done."),
                status("ses_a", "idle"),
                status("ses_a", "busy"),
                ("session.error", dict(sessionID="ses_a", error=dict(name="MessageAbortedError", data={}))),
                status("ses_a", "idle"),
                # OpenCode says it idles again as the stopped message is saved.
                status("ses_a", "idle"),
                status("ses_a", "busy"),
                ("permission.asked", dict(id="r1", sessionID="ses_a", permission="bash", patterns=["date"],
                                          metadata=dict(command="date"))),
                ("permission.replied", dict(requestID="r1", sessionID="ses_a", reply="reject")),
                status("ses_a", "idle"),
                # Turns in two sessions at once: the task works while either
                # does, and waits on you while either asks.
                status("ses_a", "busy"),
                status("ses_a", "busy"),
                status("ses_b", "busy"),
                ("question.asked", dict(id="q3", sessionID="ses_a", questions=[dict(question="Third?", header="h")])),
                status("ses_b", "idle"),
                status("ses_b", "busy"),
                # Stopped, A's question waits no more, and goes unanswered.
                status("ses_a", "idle"),
                ("message.updated", dict(info=dict(id="msg_b", role="assistant"))),
                text("p8", "msg_b", "B is done.", "ses_b"),
                ("session.error", dict(sessionID="ses_b", error=dict(name="APIError", data=dict(message="B failed")))),
                status("ses_b", "idle"),
                status("ses_a", "busy"),
                ("permission.asked", dict(id="r2", sessionID="ses_a", permission="bash", patterns=["ls"],
                                          metadata=dict(command="ls"))),
                ("permission.replied", dict(requestID="r2", sessionID="ses_a", reply="once")),
                status("ses_a", "idle"),
                # A failure in one turn shows when the last one ends.
                status("ses_a", "busy"),
                status("ses_b", "busy"),
                ("session.error", dict(sessionID="ses_b", error=dict(name="APIError", data=dict(message="B limited")))),
                status("ses_b", "idle"),
                ("message.updated", dict(info=dict(id="msg_y", role="assistant"))),
                text("p7", "msg_y", "A ends."),
                status("ses_a", "idle"),
                # A session deleted while it works ends its turn.
                status("ses_d", "busy"),
                status("ses_e", "busy"),
                ("session.deleted", dict(sessionID="ses_d", info=dict(id="ses_d"))),
                status("ses_e", "idle")]
            driver = root / "driver.mjs"
            driver.write_text(
                "const { RoostObserver } = await import(%s);\n"
                "const hooks = await RoostObserver({});\n"
                "for (const [type, properties] of %s) await hooks.event({ event: { type, properties } });\n"
                % (json.dumps(plugin.as_uri()), json.dumps(events)))
            env = dict(os.environ, ROOST_PYTHON=sys.executable, ROOST_HELPER=str(helper))
            env.pop("ROOST_OPENCODE_OBSERVER", None)
            subprocess.run(["node", str(driver)], env=env, check=True, timeout=30)
            reports = [json.loads(line) for line in log.read_text().splitlines()]
            self.assertEqual([(r["event"], r.get("session"), r.get("status")) for r in reports],
                             [("start", None, None), ("status", "ses_a", "busy"), ("asked", "ses_c", None),
                              ("asked", "ses_a", None), ("asked", "ses_c", None),
                              ("replied", "ses_c", None), ("status", "ses_a", "idle"),
                              ("status", "ses_a", "busy"), ("status", "ses_a", "idle"),
                              ("status", "ses_a", "busy"), ("asked", "ses_a", None), ("replied", "ses_a", None),
                              ("status", "ses_a", "idle"),
                              ("status", "ses_a", "busy"), ("status", "ses_b", "busy"), ("asked", "ses_a", None),
                              ("asked", "ses_a", None), ("status", "ses_b", "busy"), ("status", "ses_b", "idle"),
                              ("status", "ses_a", "busy"), ("asked", "ses_a", None), ("replied", "ses_a", None),
                              ("status", "ses_a", "idle"),
                              ("status", "ses_a", "busy"), ("status", "ses_b", "busy"), ("status", "ses_a", "busy"),
                              ("status", "ses_a", "idle"),
                              ("status", "ses_d", "busy"), ("status", "ses_e", "busy"), ("status", "ses_e", "busy"),
                              ("status", "ses_e", "idle")])
            self.assertEqual((reports[26]["reply"], reports[26]["error"]),
                             ("A ends.", dict(name="APIError", message="B limited")))
            self.assertNotIn("error", reports[30])
            self.assertEqual(reports[16]["questions"], [dict(question="Third?")])
            self.assertEqual((reports[18]["reply"], reports[18]["error"]),
                             ("B is done.", dict(name="APIError", message="B failed")))
            self.assertEqual(reports[20]["metadata"]["command"], "ls")
            self.assertEqual((reports[2]["child"], reports[2]["questions"]), (True, [dict(question="Which?")]))
            self.assertEqual(reports[4], reports[2])
            self.assertEqual(reports[6]["reply"], "Done.\n\nAll done.")
            self.assertNotIn("error", reports[6])
            self.assertEqual(reports[8]["error"]["name"], "MessageAbortedError")
            # A new turn forgets the last one's reply.
            self.assertEqual((reports[8]["reply"], reports[10]["metadata"]["command"]), ("", "date"))
            self.assertIs(reports[12]["declined"], True)
            self.assertEqual(roost.OpenCodeAgent().observe(reports[12], "running")["lastEvent"], "Interrupt")
            # An OpenCode started from it, by its shell tool, reports nothing.
            nested = root / "nested.mjs"
            nested.write_text(
                "const { RoostObserver } = await import(%s);\n"
                "if (process.env.ROOST_OPENCODE_OBSERVER !== '1') throw new Error('marker');\n"
                "const hooks = await RoostObserver({});\n"
                "if (hooks.event) throw new Error('reports');\n" % json.dumps(plugin.as_uri()))
            subprocess.run(["node", str(nested)], env=dict(env, ROOST_OPENCODE_OBSERVER="1"), check=True, timeout=30)
            self.assertEqual(len(log.read_text().splitlines()), len(reports))



if __name__ == "__main__":
    unittest.main()
