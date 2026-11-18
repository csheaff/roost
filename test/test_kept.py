"""What retiring a task keeps that removing its worktree and branch would
otherwise delete: commits only a reflog names, as after an agent's `git
reset`, and ignored files the primary checkout has no copy of. Real Git,
and the fake agent in a tmux socket of its own."""
import importlib.util
import json
import os
from pathlib import Path
import threading
import time
import unittest
from unittest.mock import patch

from crash_harness import Box, HELPER

spec = importlib.util.spec_from_file_location("roost_remote", HELPER)
roost = importlib.util.module_from_spec(spec)
spec.loader.exec_module(roost)


class Kept(unittest.TestCase):
    def setUp(self):
        self.box = Box()
        self.addCleanup(self.box.close)
        box = self.box
        (box.repo / ".gitignore").write_text(".env*\nnode_modules/\n*.db\n")
        box.git("add", ".gitignore")
        box.git("commit", "-qm", "Ignore local files")

    def retire(self, task):
        reply = self.box.helper("retire", id=task["id"])
        self.assertTrue(reply and reply["ok"], reply)
        return reply["result"]

    def kept_refs(self):
        return self.box.git("for-each-ref", "--format=%(refname) %(objectname)", "refs/roost/kept").splitlines()

    def test_a_commit_the_agent_reset_away_from_is_kept(self):
        box = self.box
        task = box.create()
        worktree = Path(task["worktree"])
        commit = box.commit(task, "draft", "first try\n")
        box.git("reset", "-q", "--hard", "HEAD~1", cwd=worktree)
        result = self.retire(task)
        self.assertEqual(result["status"], "retired")
        self.assertEqual(result["kept"]["commits"], 1)
        self.assertEqual(self.kept_refs(), ["refs/roost/kept/%s/%s %s" % (task["id"], commit, commit)])
        self.assertTrue(box.reachable(commit), "retiring lost a commit only the reflog held")

    def test_an_ignored_file_is_kept_out_of_git(self):
        box = self.box
        task = box.create()
        worktree = Path(task["worktree"])
        (worktree / ".env.local").write_text("TOKEN=secret\n")
        (worktree / "node_modules").mkdir()
        (worktree / "node_modules" / "left-pad.js").write_text("module.exports = 0\n")
        result = self.retire(task)
        kept = result["kept"]
        self.assertEqual((kept["files"], kept["commits"]), (1, 0))
        folder = Path(kept["folder"])
        self.assertEqual((folder / "worktree" / ".env.local").read_text(), "TOKEN=secret\n")
        self.assertFalse((folder / "worktree" / "node_modules").exists(), "kept a folder Git ignores whole")
        self.assertEqual(self.kept_refs(), [], "put an ignored file in Git")
        self.assertEqual(os.stat(folder.parent).st_mode & 0o077, 0, "the kept folder is open to others")

    def test_a_copy_of_the_primary_checkouts_file_is_not_kept(self):
        box = self.box
        (box.repo / ".env").write_text("SHARED=1\n")
        task = box.create()
        (Path(task["worktree"]) / ".env").write_text("SHARED=1\n")
        result = self.retire(task)
        self.assertIsNone(result.get("kept"))
        self.assertFalse((box.state / "kept").exists())

    def test_a_large_ignored_file_is_named(self):
        box = self.box
        task = box.create()
        with open(Path(task["worktree"]) / "local.db", "wb") as out:
            out.truncate(roost.KEPT_FILE_LIMIT + 1)
        result = self.retire(task)
        self.assertEqual(result["kept"]["large"], ["worktree/local.db"])
        self.assertEqual(result["kept"]["files"], 0)

    def test_a_task_with_nothing_to_keep_keeps_nothing(self):
        box = self.box
        task = box.create()
        commit = box.commit(task)
        box.git("merge", "-q", "--ff-only", commit)
        result = self.retire(task)
        self.assertIsNone(result.get("kept"))
        self.assertEqual(self.kept_refs(), [])

    def test_what_was_kept_long_ago_goes(self):
        box = self.box
        old = box.create("old")
        commit = box.commit(old, "draft")
        box.git("reset", "-q", "--hard", "HEAD~1", cwd=old["worktree"])
        (Path(old["worktree"]) / ".env.local").write_text("old\n")
        kept = self.retire(old)["kept"]
        record = box.state / "kept" / (old["id"] + ".json")
        past = time.time() - (roost.KEPT_DAYS + 1) * 86400
        os.utime(record, (past, past))
        task = box.create("new")
        (Path(task["worktree"]) / ".env.local").write_text("new\n")
        self.retire(task)
        self.assertFalse(record.exists())
        self.assertFalse(Path(kept["folder"]).exists())
        self.assertFalse(any(old["id"] in ref for ref in self.kept_refs()))
        self.assertTrue((box.state / "kept" / (task["id"] + ".json")).exists())
        self.assertFalse(box.reachable(commit))

    def test_a_kept_ref_moved_since_is_not_pruned(self):
        box = self.box
        old = box.create("old")
        box.commit(old, "draft")
        box.git("reset", "-q", "--hard", "HEAD~1", cwd=old["worktree"])
        self.retire(old)
        record = box.state / "kept" / (old["id"] + ".json")
        ref = json.loads(record.read_text())["refs"]
        [name] = ref
        box.git("update-ref", name, "HEAD")
        past = time.time() - (roost.KEPT_DAYS + 1) * 86400
        os.utime(record, (past, past))
        with patch.dict(os.environ, box.env, clear=True):
            roost.prune_kept(roost.Store(box.state))
        self.assertIn(name, " ".join(self.kept_refs()), "pruned a ref you moved")

    def test_keeping_again_adds_to_what_was_kept(self):
        box = self.box
        task = box.create()
        worktree = Path(task["worktree"])
        first = box.commit(task, "one")
        box.git("reset", "-q", "--hard", "HEAD~1", cwd=worktree)
        store = roost.Store(box.state)
        record = store.read(task["id"])
        # As the helper runs Git, in the box's environment, not yours.
        with patch.dict(os.environ, box.env, clear=True):
            roost.keep_before_removing(store, record, worktree, None)
            second = box.commit(task, "two")
            box.git("reset", "-q", "--hard", "HEAD~1", cwd=worktree)
            (worktree / ".env.local").write_text("later\n")
            again = roost.keep_before_removing(store, record, worktree, None)
        # What it keeps for the task in all, the first commit too.
        self.assertEqual((again["commits"], again["files"]), (2, 1))
        refs = json.loads(store.kept(task["id"]).with_suffix(".json").read_text())["refs"]
        self.assertEqual(sorted(refs.values()), sorted([first, second]))

    def test_the_old_copies_a_rebase_leaves_are_not_kept(self):
        box = self.box
        task = box.create()
        worktree = Path(task["worktree"])
        box.commit(task, "draft")
        (box.repo / "elsewhere").write_text("main moved\n")
        box.git("add", "elsewhere")
        box.git("commit", "-qm", "Move main")
        box.git("rebase", "-q", "main", cwd=worktree)
        box.git("merge", "-q", "--ff-only", task["branch"])
        result = self.retire(task)
        self.assertIsNone(result.get("kept"), "kept a commit whose patch is on the branch")
        self.assertEqual(self.kept_refs(), [])

    def test_a_discard_drops_what_a_refused_retire_kept(self):
        box = self.box
        task = box.create()
        worktree = Path(task["worktree"])
        (worktree / ".env.local").write_text("TOKEN=secret\n")
        # The teardown command leaves a file, which the retire then refuses.
        reply = box.helper("retire", id=task["id"], teardown="touch left-behind")
        self.assertFalse(reply["ok"], reply)
        folder = box.state / "kept" / task["id"]
        self.assertTrue((folder / "worktree" / ".env.local").exists(), "the retire kept nothing before it was refused")
        (worktree / "left-behind").unlink()
        told = box.helper("discard", id=task["id"], dryRun=True)["result"]["discard"]
        reply = box.helper("discard", id=task["id"], told=told, expect=told["commit"])
        self.assertTrue(reply["ok"], reply)
        self.assertFalse(folder.exists(), "a discard left the secret a retire had kept")
        self.assertFalse(folder.with_suffix(".json").exists())

    def test_a_merge_a_reset_left_behind_is_kept(self):
        box = self.box
        task = box.create()
        worktree = Path(task["worktree"])
        start = box.commit(task, "draft")
        (box.repo / "elsewhere").write_text("main moved\n")
        box.git("add", "elsewhere")
        box.git("commit", "-qm", "Move main")
        box.git("merge", "-q", "--no-edit", "main", cwd=worktree)
        merge = box.git("rev-parse", "HEAD", cwd=worktree)
        # Its patches are all on the rebased branch; the merge is not.
        box.git("reset", "-q", "--hard", start, cwd=worktree)
        box.git("rebase", "-q", "main", cwd=worktree)
        box.git("merge", "-q", "--ff-only", task["branch"])
        result = self.retire(task)
        self.assertEqual(result["kept"]["commits"], 1)
        self.assertTrue(box.reachable(merge), "retiring lost a merge only the reflog held")

    def test_a_kept_ref_is_no_proof_a_commit_survives(self):
        box = self.box
        box.git("switch", "-q", "-c", "side")
        (box.repo / "side").write_text("side\n")
        box.git("add", "side")
        box.git("commit", "-qm", "Side")
        commit = box.git("rev-parse", "HEAD")
        box.git("switch", "-q", "main")
        box.git("update-ref", "refs/roost/kept/0000000000000000/" + commit, commit)
        task = box.create(base=commit)
        box.git("branch", "-q", "-D", "side")
        reply = box.helper("retire", id=task["id"])
        self.assertFalse(reply["ok"], "retired on the word of a copy that goes in 30 days")
        self.assertTrue(box.reachable(commit))

    def test_a_missing_worktrees_head_reflog_is_read_before_git_forgets_it(self):
        box = self.box
        task = box.create()
        worktree = Path(task["worktree"])
        box.git("switch", "-q", "--detach", cwd=worktree)
        (worktree / "detached").write_text("tried\n")
        box.git("add", "detached", cwd=worktree)
        box.git("commit", "-qm", "Try detached", cwd=worktree)
        detached = box.git("rev-parse", "HEAD", cwd=worktree)
        box.git("switch", "-q", task["branch"], cwd=worktree)
        worktree.rename(worktree.with_name(worktree.name + ".away"))
        result = self.retire(task)
        self.assertEqual(result["kept"]["commits"], 1)
        self.assertTrue(box.reachable(detached), "retiring lost a commit only a missing worktree's reflog held")

    def test_an_agent_worktrees_ignored_files_are_kept_apart(self):
        box = self.box
        task = box.create()
        path = self.agent_worktree(task)
        (path / ".env.local").write_text("agent's\n")
        (Path(task["worktree"]) / ".env.local").write_text("task's\n")
        result = self.retire(task)
        self.assertFalse(path.exists(), "the agent's worktree stayed")
        folder = Path(result["kept"]["folder"])
        self.assertEqual((folder / "worktree" / ".env.local").read_text(), "task's\n")
        self.assertEqual((folder / "agents" / "agent" / ".env.local").read_text(), "agent's\n")

    def test_a_copy_never_goes_through_a_link_kept_before(self):
        box = self.box
        outside = box.root / "outside"
        outside.mkdir()
        folder = box.state / "kept" / "0123456789abcdef"
        (folder / "worktree").mkdir(parents=True)
        (folder / "worktree" / "cache").symlink_to(outside)
        with self.assertRaises(roost.RoostError):
            roost.kept_target(folder, "worktree/cache/secret.db")
        self.assertEqual(list(outside.iterdir()), [])

    def test_a_name_not_in_utf8_is_kept(self):
        box = self.box
        task = box.create()
        name = os.fsdecode(b".env.caf\xe9")
        try:
            (Path(task["worktree"]) / name).write_text("bytes\n")
        except OSError:
            self.skipTest("this file system takes only UTF-8 names, as APFS does")
        result = self.retire(task)
        self.assertEqual(result["kept"]["files"], 1)
        self.assertEqual((Path(result["kept"]["folder"]) / "worktree" / name).read_text(), "bytes\n")

    def agent_worktree(self, task):
        box = self.box
        path = box.repo / ".claude" / "worktrees" / "agent"
        box.git("worktree", "add", "-q", "-b", "worktree-agent", str(path), task["branch"])
        record = box.record(task["id"])
        record["agentWorktrees"] = record["agentMade"] = [str(path)]
        record["agentMadeAt"] = {str(path): (box.repo / ".git/worktrees/agent/commondir").stat().st_mtime_ns}
        (box.state / "tasks" / (task["id"] + ".json")).write_text(json.dumps(record))
        return path

    def test_another_tasks_kept_ref_is_no_proof_either(self):
        box = self.box
        first = box.create("first")
        commit = box.commit(first, "draft")
        box.git("reset", "-q", "--hard", "HEAD~1", cwd=first["worktree"])
        self.retire(first)
        # The second began at that commit, then reset back past it.
        second = box.create("second", base=commit)
        box.git("reset", "-q", "--hard", "HEAD~1", cwd=second["worktree"])
        result = self.retire(second)
        self.assertEqual(result["kept"]["commits"], 1)
        self.assertIn("refs/roost/kept/%s/%s %s" % (second["id"], commit, commit), self.kept_refs())

    def test_asking_again_counts_the_days_again(self):
        box = self.box
        task = box.create()
        worktree = Path(task["worktree"])
        box.commit(task, "draft")
        box.git("reset", "-q", "--hard", "HEAD~1", cwd=worktree)
        store = roost.Store(box.state)
        record = store.read(task["id"])
        kept = store.kept(task["id"]).with_suffix(".json")
        with patch.dict(os.environ, box.env, clear=True):
            roost.keep_before_removing(store, record, worktree, None)
            past = time.time() - (roost.KEPT_DAYS - 1) * 86400
            os.utime(kept, (past, past))
            again = roost.keep_before_removing(store, record, worktree, None)
        self.assertEqual(again["commits"], 1)
        self.assertGreater(kept.stat().st_mtime, time.time() - 3600, "a retry left a day of the 30")

    def test_an_agents_worktree_is_kept_when_the_tasks_is_missing(self):
        box = self.box
        task = box.create()
        path = self.agent_worktree(task)
        (path / ".env.local").write_text("agent's\n")
        worktree = Path(task["worktree"])
        worktree.rename(worktree.with_name(worktree.name + ".away"))
        result = self.retire(task)
        self.assertFalse(path.exists(), "the agent's worktree stayed")
        self.assertEqual((Path(result["kept"]["folder"]) / "agents" / "agent" / ".env.local").read_text(),
                         "agent's\n")

    def test_a_submodules_ignored_file_is_kept(self):
        box = self.box
        library = box.root / "library"
        box.git("init", "-q", "-b", "main", str(library))
        (library / ".gitignore").write_text(".env*\n")
        (library / "lib").write_text("lib\n")
        box.git("add", ".", cwd=library)
        box.git("commit", "-qm", "Library", cwd=library)
        box.git("config", "--global", "protocol.file.allow", "always")
        box.git("submodule", "add", "-q", str(library), "library")
        box.git("commit", "-qm", "Add the library")
        task = box.create()
        box.git("submodule", "update", "--init", "-q", cwd=task["worktree"])
        (Path(task["worktree"]) / "library" / ".env.local").write_text("module's\n")
        result = self.retire(task)
        self.assertEqual((Path(result["kept"]["folder"]) / "worktree" / "library" / ".env.local").read_text(),
                         "module's\n")

    def test_pruning_reads_a_records_age_under_the_lock(self):
        box = self.box
        store = roost.Store(box.state)
        record = store.kept("0123456789abcdef").with_suffix(".json")
        record.parent.mkdir(parents=True)
        record.write_text(json.dumps(dict(repo=str(box.repo), refs={}, files=[])))
        past = time.time() - (roost.KEPT_DAYS + 1) * 86400
        os.utime(record, (past, past))
        # A retry renews it while pruning waits for the lock.
        with roost.kept_locked(store):
            pruning = threading.Thread(target=roost.prune_kept, args=(store,))
            pruning.start()
            time.sleep(0.2)
            os.utime(record)
        pruning.join(10)
        self.assertTrue(record.exists(), "pruning dropped a copy renewed meanwhile")


if __name__ == "__main__":
    unittest.main()
