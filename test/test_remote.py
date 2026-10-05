"""Real Git/tmux lifecycle tests. Isolated sockets; no API calls or user config."""
import concurrent.futures
import datetime
import http.server
import importlib.util
import hashlib
import json
import os
import re
import shlex
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
        self.temp.cleanup()

    def git(self, *args, cwd=None):
        return roost.git(cwd or self.repo, *args).stdout.strip()

    def request(self, action, **args):
        return roost.rpc(dict(root=str(self.state), action=action, **args))

    def create(self, **args):
        reply = self.request("create", directory=str(self.repo), name=args.pop("name", "task"),
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
        transcript = (home / ".claude" / "projects" / re.sub(r"[/.]", "-", task["worktree"])
                      / (record["agentSession"] + ".jsonl"))
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
        self.assertTrue(self.request("merge", id=task["id"])["ok"])
        self.assertEqual((self.repo / "hello").read_text(), "main and task\n")

    def test_a_full_listing_names_the_changed_files(self):
        task = self.create()
        wt = Path(task["worktree"])
        (wt / "hello").write_text("one\ntwo\n")
        self.git("mv", "hello", "greeting", cwd=wt)
        (wt / "new file").write_text("x\n")
        (wt / "image").write_bytes(b"\0\1")
        self.git("add", "image", cwd=wt)
        files = self.request("list", full=True)["result"][0]["files"]
        self.assertIn(dict(path="image"), files)
        self.assertIn(dict(path="new file", untracked=True), files)
        self.assertIn(dict(path="greeting", added=2, deleted=0), files)
        # Like the other statistics, the list is never saved in the record.
        store = roost.Store(str(self.state))
        store.save(dict(store.read(task["id"]), files=files))
        self.assertNotIn("files", store.read(task["id"]))

    def test_measuring_takes_no_optional_git_locks(self):
        # git status would refresh the index under its lock, and an agent
        # committing at that moment would fail.
        task = self.create()
        (Path(task["worktree"]) / "hello").write_text("changed\n")
        calls = []
        real = roost.execute
        with patch.object(roost, "execute", lambda argv, **kw: calls.append(argv) or real(argv, **kw)):
            roost.add_git_stats([roost.Store(str(self.state)).read(task["id"])], pull_requests=False)
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

    def test_sessions_are_named_after_their_project(self):
        repo_hash = hashlib.sha256(str(self.repo.resolve()).encode()).hexdigest()[:10]
        task = self.create()
        # The fixture's "repo with spaces" also shows names made safe for tmux.
        self.assertEqual(task["session"], "roost-repo-with-spaces-" + repo_hash[:4])
        # A session from before, named by hash alone, keeps the project's tasks.
        roost.tmux(self.socket, "new-session", "-d", "-s", "roost-" + repo_hash)
        self.assertEqual(self.create(name="later")["session"], "roost-" + repo_hash)

    def test_existing_session_and_rename_survive_resume(self):
        roost.tmux(self.socket, "new-session", "-d", "-s", "existing")
        task = self.create(session="existing")
        self.assertEqual(task["session"], "existing")
        roost.tmux(self.socket, "rename-session", "-t", "existing", "renamed")
        self.assertEqual(self.request("inspect", id=task["id"])["result"]["session"], "renamed")
        self.request("stop", id=task["id"])
        self.request("resume", id=task["id"])
        self.assertEqual(self.wait(task, "ready")["session"], "renamed")

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
        self.assertEqual(child["session"], first["session"])
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
        self.assertEqual(len(roost.pane_inventory(self.socket)), 3)  # repo shell, agent, task shell
        self.assertTrue(self.request("stop", id=task["id"])["ok"])
        self.assertNotIn(shell, roost.pane_inventory(self.socket))
        self.assertFalse(self.request("shell", id=task["id"])["ok"])
        self.assertTrue(self.request("resume", id=task["id"])["ok"])
        self.wait(task, "ready")
        self.assertNotEqual(self.request("shell", id=task["id"])["result"]["shellPaneId"], shell)

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

    def test_codex_and_pi_create_send_shell_resume_and_retire(self):
        for agent in ("codex", "pi"):
            with self.subTest(agent=agent):
                task = self.create(name=agent, agent=agent, command=[sys.executable, str(FAKE_AGENT), agent])
                record = self.wait(task, "ready")
                session = record["agentSession"]
                self.assertTrue(session)
                self.assertIsNone(record["claudeSession"])
                self.assertTrue(self.request("send", id=task["id"], text="literal $() `ticks` prompt")["ok"])
                finished = self.wait(task, "ready", event="Stop")
                self.assertEqual(finished["lastEvent"], "Stop")
                pane = self.request("shell", id=task["id"])["result"]["shellPaneId"]
                self.assertTrue(self.request("stop", id=task["id"])["ok"])
                self.assertNotIn(pane, roost.pane_inventory(self.socket))
                self.assertTrue(self.request("resume", id=task["id"])["ok"])
                resumed = self.wait(task, "ready")
                self.assertEqual(resumed["agentSession"], session)
                self.assertNotEqual(resumed["runId"], record["runId"])
                # Older provider events cannot steer a resumed task.
                payload = dict(hook_event_name="Stop", session_id="wrong") if agent == "codex" else dict(event="agent_end", session="wrong")
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

    def test_provider_flags_are_checked_before_worktree_creation(self):
        before = self.git("worktree", "list", "--porcelain")
        for agent, flags in (("codex", ["resume", "last"]), ("codex", ["--cd=/other"]),
                             ("pi", ["--session=other"]), ("pi", ["--mode", "rpc"]), ("pi", ["--print"])):
            with self.subTest(agent=agent, flags=flags):
                reply = self.request("create", directory=str(self.repo), name="bad", socket=self.socket,
                                     agent=agent, command=[agent, *flags])
                self.assertFalse(reply["ok"], reply)
                self.assertEqual(self.git("worktree", "list", "--porcelain"), before)

    def test_pi_queued_work_is_background_and_codex_interrupt_is_ready(self):
        self.assertEqual(roost.PiAgent().observe(dict(event="agent_end", pending=True))["status"], "background")
        self.assertEqual(roost.CodexAgent().observe(dict(hook_event_name="Interrupt"))["status"], "ready")
        self.assertIsNone(roost.PiAgent().observe(dict(event="unknown")))
        self.assertIsNone(roost.CodexAgent().observe(dict(hook_event_name="SubagentStop")))

    def test_initial_prompts_are_literal_and_not_replayed_on_resume(self):
        store = roost.Store(str(self.state))
        for name, adapter in (("codex", roost.CodexAgent()), ("pi", roost.PiAgent())):
            for prompt in ("--help", "@private-file", "literal $() `ticks`\nsecond line"):
                with self.subTest(agent=name, prompt=prompt):
                    task = dict(id="1234567890abcdef", command=[name], prompt=prompt, agentSession="recorded-session")
                    argv = adapter.launch(store, task, False)
                    if name == "codex":
                        self.assertEqual(argv[-2:], ["--", prompt])
                    else:
                        self.assertNotIn("--", argv)
                        self.assertEqual(argv[-1], "\n" + prompt)
                    resumed = adapter.launch(store, task, True)
                    self.assertEqual(resumed[-1], "recorded-session")
                    self.assertNotIn(prompt, resumed)

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

    def test_failed_spawn_leaves_no_record_worktree_or_branch(self):
        before = self.git("worktree", "list", "--porcelain")
        reply = self.request("create", directory=str(self.repo), name="bad session", socket=self.socket,
                             session="bad:name.x", command=[sys.executable, str(FAKE)])
        self.assertFalse(reply["ok"], reply)
        self.assertEqual(self.request("list")["result"], [])
        self.assertEqual(self.git("worktree", "list", "--porcelain"), before)
        self.assertEqual(self.git("branch", "--list", "roost/*"), "")

    def test_detached_primary_task_retires_when_empty_and_forgets_when_not(self):
        self.git("checkout", "-q", "--detach")
        empty = self.create(name="empty")
        self.assertEqual(empty["integrationBranch"], "")
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
if args[:2] == ["pr", "list"]:
    canned("list.json", "[]")
elif args[:2] == ["pr", "create"]:
    print("https://github.com/octo/repo/pull/7")
elif args[:2] == ["pr", "view"]:
    canned("view.json")
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
        (self.gh_dir / "view.json").write_text(json.dumps(dict(
            state="OPEN", isDraft=True, reviewDecision="APPROVED", headRefOid=tip, mergedAt=None,
            statusCheckRollup=[
                dict(__typename="CheckRun", status="COMPLETED", conclusion="SUCCESS"),
                dict(__typename="CheckRun", status="COMPLETED", conclusion="SKIPPED"),
                dict(__typename="CheckRun", status="COMPLETED", conclusion="FAILURE"),
                dict(__typename="CheckRun", status="IN_PROGRESS", conclusion=""),
                dict(__typename="StatusContext", state="PENDING"),
                dict(__typename="StatusContext", state="SUCCESS")])))
        listed = self.request("list", full=True)["result"][0]
        self.assertEqual(listed["prStatus"], dict(
            state="OPEN", draft=True, review="APPROVED", head=tip,
            checks=dict(passing=3, failing=1, pending=2)))
        self.assertEqual(self.gh_calls()[-1],
                         ["pr", "view", "7", "--json",
                          "state,isDraft,reviewDecision,statusCheckRollup,headRefOid,mergedAt"])
        self.assertNotIn("prStatus", store.read(task["id"]))
        self.assertNotIn("prStatus", self.request("list")["result"][0])
        # Refreshing an active agent's changes leaves GitHub alone.
        calls = len(self.gh_calls())
        self.assertNotIn("prStatus", self.request("list", full=[task["id"]])["result"][0])
        self.assertEqual(len(self.gh_calls()), calls)
        (self.gh_dir / "view.json").unlink()
        self.assertNotIn("prStatus", self.request("list", full=True)["result"][0])

    def test_retire_accepts_a_squash_merged_pull_request_and_deletes_the_remote_branch(self):
        self.github()
        task = self.create()
        tip = self.commit_in(task)
        self.assertTrue(self.request("pr", id=task["id"], title="Squash")["ok"])
        self.git("merge", "--squash", task["branch"])
        self.git("commit", "-qm", "Squash (#7)")
        view = self.gh_dir / "view.json"
        # The task committed again after the merge: its branch must be kept.
        view.write_text(json.dumps(dict(state="MERGED", headRefOid="0" * 40)))
        reply = self.request("retire", id=task["id"])
        self.assertIn("unmerged commits", reply["error"])
        self.assertTrue(Path(task["worktree"]).exists())
        view.write_text(json.dumps(dict(state="OPEN", headRefOid=tip)))
        self.assertFalse(self.request("retire", id=task["id"])["ok"])
        view.write_text(json.dumps(dict(state="MERGED", headRefOid=tip)))
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
        self.assertEqual(observed, [("pr", "view")])
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
        (self.gh_dir / "view.json").write_text(json.dumps(dict(state="MERGED", headRefOid=tip)))
        self.assertTrue(self.request("retire", id=task["id"])["ok"])

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

    def test_list_and_inspect_show_the_agents_latest_reply_without_saving_it(self):
        task = self.create()
        record = roost.Store(str(self.state)).read(task["id"])
        home = self.root / "home"
        folder = home / ".claude/projects" / re.sub(r"[/.]", "-", task["worktree"])
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

    def test_bad_base_and_missing_executable_report_errors_without_touching_repo(self):
        response = self.request("create", directory=str(self.repo), name="bad", base="missing-ref", socket=self.socket)
        self.assertFalse(response["ok"])
        response = self.request("create", directory=str(self.repo), name="bad executable", socket=self.socket,
                                command=["/does/not/exist"])
        self.assertTrue(response["ok"])
        self.wait(response["result"], "failed")
        self.assertEqual(self.git("status", "--porcelain"), "")


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
        # Questions and plans wait for an answer rather than a permission.
        question = lambda text: dict(question=text, header="h", options=[dict(label="a"), dict(label="b")])
        self.assertEqual(ask("AskUserQuestion", questions=[question("Red or blue?")]), "Asks: Red or blue?")
        self.assertEqual(ask("AskUserQuestion", questions=[question("Red?"), question("Blue?")]),
                         "Asks: Red? (and 1 more)")
        self.assertEqual(ask("AskUserQuestion", questions="odd"), "Asks you a question")
        self.assertEqual(ask("ExitPlanMode", plan="1. Do it"), "Asks you to approve its plan")
        self.assertIsNone(roost.permission_request(dict(hook_event_name="Notification")))


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

    def test_pi_reads_its_session_file(self):
        path = self.write("pi/session.jsonl", [
            {"type": "session", "id": "x"},
            {"type": "message", "message": {"role": "assistant", "content": [{"type": "text", "text": "pi says"}]}},
            {"type": "message", "message": {"role": "user", "content": "ok"}}])
        self.assertEqual(roost.last_message(dict(agent="pi", worktree="/w", agentSession=str(path))), "pi says")

    def test_missing_or_malformed_transcripts_give_none(self):
        for agent in ("claude", "codex", "pi"):
            for session in (None, "missing", "../escape", str(self.home / "nowhere.jsonl")):
                self.assertIsNone(roost.last_message(dict(agent=agent, worktree="/w", agentSession=session)))
        self.write(".claude/projects/-w/bad.jsonl", [[], "x", {"message": "str"}, {"message": {"role": "assistant", "content": 5}}])
        self.assertIsNone(roost.last_message(dict(agent="claude", worktree="/w", agentSession="bad")))
        self.assertIsNone(roost.last_message(dict(agent="unknown", worktree="/w")))
        self.assertIsNone(roost.last_message(dict(agent="claude")))


if __name__ == "__main__":
    unittest.main()
