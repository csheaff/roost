"""Real Git/tmux lifecycle tests. Isolated sockets; no API calls or user config."""
import concurrent.futures
import importlib.util
import json
import os
import shlex
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
