"""Real Git/tmux lifecycle tests. Isolated sockets; no API calls or user config."""
import concurrent.futures
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import time
import unittest
import uuid
from unittest.mock import patch

SOURCE = Path(__file__).resolve().parents[1] / "scripts/roost_remote.py"
spec = importlib.util.spec_from_file_location("roost_remote", SOURCE)
roost = importlib.util.module_from_spec(spec)
spec.loader.exec_module(roost)
FAKE = Path(__file__).with_name("fake_claude.py")


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

    def wait(self, task, status):
        deadline = time.monotonic() + 8
        while time.monotonic() < deadline:
            record = roost.Store(str(self.state)).read(task["id"])
            if record["status"] == status:
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
        store = roost.Store(str(self.state))
        roost.update_hook(store, task["id"], dict(hook_event_name="Stop"))
        self.assertEqual(store.read(task["id"])["status"], "ready")
        roost.update_hook(store, task["id"], dict(hook_event_name="Stop", background_tasks=[{}]))
        self.assertEqual(store.read(task["id"])["status"], "background")

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

    def test_window_renumbering_does_not_change_task_identity(self):
        task = self.create()
        roost.tmux(self.socket, "move-window", "-s", task["windowId"], "-t", task["session"] + ":8")
        self.assertTrue(self.request("send", id=task["id"], text="literal $() `ticks` \\\"quotes\\\"")["ok"])
        listed = self.request("list", full=True)["result"][0]
        self.assertEqual(listed["windowIndex"], 8)
        self.assertEqual(listed["paneId"], task["paneId"])

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

    def test_partial_retirement_can_be_retried_after_branch_deletion(self):
        task = self.create()
        original = roost.Store.save
        def interrupted_save(store, record):
            if record["status"] == "retired":
                raise OSError("simulated disconnect after cleanup")
            original(store, record)
        with patch.object(roost.Store, "save", interrupted_save):
            self.assertFalse(self.request("retire", id=task["id"])["ok"])
        self.assertFalse(Path(task["worktree"]).exists())
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
        self.request("retire", id=task["id"])
        roost.update_hook(store, task["id"], dict(hook_event_name="UserPromptSubmit"))
        self.assertEqual(store.read(task["id"])["status"], "retired")

    def test_concurrent_hooks_preserve_other_tasks_and_valid_json(self):
        tasks = [self.create(name="task " + str(i)) for i in range(2)]
        def write_event(task):
            store = roost.Store(str(self.state))
            for _ in range(8):
                roost.update_hook(store, task["id"], dict(hook_event_name="Stop"))
        with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:
            list(pool.map(write_event, tasks))
        self.assertEqual(len(self.request("list")["result"]), 2)

    def test_bad_base_and_missing_executable_report_errors_without_touching_repo(self):
        response = self.request("create", directory=str(self.repo), name="bad", base="missing-ref", socket=self.socket)
        self.assertFalse(response["ok"])
        response = self.request("create", directory=str(self.repo), name="bad executable", socket=self.socket,
                                command=["/does/not/exist"])
        self.assertTrue(response["ok"])
        self.wait(response["result"], "failed")
        self.assertEqual(self.git("status", "--porcelain"), "")


if __name__ == "__main__":
    unittest.main()
