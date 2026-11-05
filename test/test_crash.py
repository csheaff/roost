"""The helper killed partway through what it does, as a dropped connection or
a reboot leaves it: see crash_harness.py. `Crashes` holds each crash that went
wrong, for `make test`; `Sweep` kills every action at every step, for
`make crash`."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import time
import unittest

import crash_harness as harness
from crash_harness import Box
import crash_scenarios as scenarios

# Set by `make crash`: "commands" or "lines", which sweeps every line too.
SWEEP = os.environ.get("ROOST_CRASH_SWEEP")


class Crashes(unittest.TestCase):
    def box(self):
        box = Box()
        self.addCleanup(box.close)
        return box

    def test_a_merge_cut_short_once_its_branch_went_finishes_when_asked_again(self):
        for style in ({}, dict(style="squash")):
            with self.subTest(style=style):
                box = self.box()
                task = box.create()
                commit = box.commit(task)
                box.arm("after", match="update-ref -d")
                self.assertIsNone(box.helper("merge", id=task["id"], **style))
                box.disarm()
                reply = box.helper("merge", id=task["id"], **style)
                self.assertTrue(reply["ok"], reply)
                self.assertEqual(reply["result"]["retiringCommit"], commit)
                self.assertEqual(box.helper("list", socket=box.socket)["result"], [])
                self.assertEqual(len(box.git("log", "--format=%H", "--no-merges", "main", "--", "work").split()), 1)

    def test_a_merge_goes_on_to_its_end_once_its_helper_is_gone(self):
        box = self.box()
        task = box.create()
        box.commit(task)
        box.arm("orphan", match="--no-ff --no-edit")
        self.assertIsNone(box.helper("merge", id=task["id"]))
        box.wait_for_orphan()
        box.disarm()
        self.assertFalse((box.repo / ".git/MERGE_HEAD").exists())
        self.assertEqual(box.git("status", "--porcelain"), "")
        reply = box.helper("merge", id=task["id"])
        self.assertTrue(reply["ok"], reply)
        self.assertEqual(len(box.git("log", "--merges", "--format=%H").split()), 1)

    def test_an_update_goes_on_to_its_conflict_once_its_helper_is_gone(self):
        box = self.box()
        task = box.create()
        box.commit(task)
        (box.repo / "work").write_text("other\n")
        box.git("add", ".")
        box.git("commit", "-qm", "Clash with the task")
        box.helper("stop", id=task["id"])
        box.arm("orphan", match=" --ff --no-edit")
        self.assertIsNone(box.helper("update", id=task["id"]))
        box.wait_for_orphan()
        box.disarm()
        # A merge under way, to resolve or abort, not changes to commit.
        self.assertIn("abort it", box.helper("update", id=task["id"])["error"])
        box.git("merge", "--abort", cwd=task["worktree"])
        self.assertEqual(Path(task["worktree"], "work").read_text(), "work\n")

    def test_a_merge_stopped_under_way_in_the_primary_checkout_says_how_to_go_on(self):
        box = self.box()
        task = box.create()
        box.commit(task)
        # As a reboot leaves it, just before Git commits the merge.
        box.git("merge", "-q", "--no-ff", "--no-commit", task["branch"])
        error = box.helper("merge", id=task["id"])["error"]
        self.assertIn("git commit", error)
        self.assertIn("git merge --abort", error)
        box.git("merge", "--abort")
        self.assertTrue(box.helper("merge", id=task["id"])["ok"])

    def cut_short_removing(self, box, task, action, **args):
        """Stop ACTION at the removal of TASK's worktree."""
        box.arm("before", match="worktree remove")
        self.assertIsNone(box.helper(action, id=task["id"], **args))
        box.disarm()
        return Path(task["worktree"])

    def assert_finished(self, box, task):
        self.assertEqual(box.helper("list", socket=box.socket)["result"], [])
        self.assertFalse(Path(task["worktree"]).exists())
        self.assertEqual(box.worktrees(), [str(box.repo)])
        self.assertEqual(box.branches(), ["main"])

    def test_a_worktree_half_removed_is_finished_off_as_asked(self):
        def tracked(worktree):
            (worktree / "work").unlink()

        def link(worktree):
            (worktree / ".git").unlink()

        def nearly_all(worktree):
            for path in worktree.iterdir():
                if path.name != "hello":
                    path.unlink()

        for action, args in (("merge", {}), ("merge", dict(style="squash"))):
            for gone in (tracked, link, nearly_all):
                with self.subTest(action=action, args=args, gone=gone.__name__):
                    box = self.box()
                    task = box.create()
                    box.commit(task)
                    gone(self.cut_short_removing(box, task, action, **args))
                    reply = box.helper(action, id=task["id"], **args)
                    self.assertTrue(reply["ok"], reply)
                    self.assert_finished(box, task)
                    self.assertEqual(box.git("show", "main:work"), "work")

    def test_what_a_removal_put_back_is_no_change_of_yours(self):
        box = self.box()
        task = box.create()
        box.commit(task)
        worktree = self.cut_short_removing(box, task, "merge")
        (worktree / ".git").unlink()
        (worktree / "work").unlink()
        told = box.helper("discard", id=task["id"], dryRun=True)["result"]["discard"]
        self.assertEqual((told["changes"], told["commits"]), (0, 0))
        self.assertTrue(box.helper("discard", id=task["id"], expect=told["commit"])["ok"])
        self.assert_finished(box, task)

    def test_a_file_in_a_worktree_half_removed_is_still_refused(self):
        box = self.box()
        task = box.create()
        box.commit(task)
        worktree = self.cut_short_removing(box, task, "merge")
        (worktree / "work").unlink()
        (worktree / "written since").write_text("mine\n")
        self.assertIn("Uncommitted or untracked", box.helper("merge", id=task["id"])["error"])
        self.assertEqual((worktree / "written since").read_text(), "mine\n")

    def test_a_removal_cut_short_in_what_git_keeps_is_finished_off(self):
        box = self.box()
        task = box.create()
        box.commit(task)
        worktree = self.cut_short_removing(box, task, "merge")
        shutil.rmtree(worktree)
        (box.repo / ".git/worktrees" / worktree.name / "HEAD").unlink()
        reply = box.helper("merge", id=task["id"])
        self.assertTrue(reply["ok"], reply)
        self.assert_finished(box, task)

    def test_merging_a_task_whose_branch_you_deleted_still_says_so(self):
        box = self.box()
        task = box.create()
        box.helper("stop", id=task["id"])
        box.git("worktree", "remove", "--force", task["worktree"])
        box.git("branch", "-D", task["branch"])
        self.assertIn("no longer exists", box.helper("merge", id=task["id"])["error"])


class Hosts(unittest.TestCase):
    """Hosts that aren't set up as yours is."""

    def box(self, **env):
        box = Box()
        self.addCleanup(box.close)
        box.env = dict({key: value for key, value in box.env.items() if not key.startswith("LC_") and key != "LANG"},
                       **env)
        return box

    def test_tmux_is_read_the_same_under_lc_all_c(self):
        for locale in ("C", "POSIX"):
            with self.subTest(locale=locale):
                box = self.box(LC_ALL=locale)
                task = box.create("é")
                listed = box.helper("list", socket=box.socket)["result"]
                self.assertEqual([(t["id"], t["status"], t["live"]) for t in listed], [(task["id"], "ready", True)])
                # Its agent is still there to refuse these.
                self.assertIn("still running", box.helper("resume", id=task["id"])["error"])
                self.assertIn("stop the task", box.helper("forget", id=task["id"])["error"])

@unittest.skipUnless(SWEEP, "A sweep takes a while: make crash")
class Sweep(unittest.TestCase):
    workers = int(os.environ.get("ROOST_CRASH_WORKERS", "6"))

    def assert_no_problems(self, outcomes):
        self.assertEqual([], ["%s@%d (%s): %s" % (outcome["mode"], outcome["at"], outcome["step"], problem)
                              for outcome in outcomes for problem in outcome["problems"]])

    def sweep(self, modes):
        for scenario in scenarios.ALL:
            with self.subTest(scenario=scenario.__name__):
                self.assert_no_problems(harness.sweep(scenario, modes=modes, workers=self.workers))

    def test_every_command(self):
        self.sweep(("before", "after", "orphan", "racing", "fail", "inside"))

    def test_a_crash_while_asking_again(self):
        for scenario in (scenarios.Merge, scenarios.MergeSquash, scenarios.Retire, scenarios.Discard):
            with self.subTest(scenario=scenario.__name__):
                self.assert_no_problems(harness.twice(scenario, workers=self.workers))

    @unittest.skipUnless(SWEEP == "lines", "make crash CRASH_SWEEP=lines")
    def test_every_line(self):
        self.sweep(("line",))


if __name__ == "__main__":
    unittest.main()
