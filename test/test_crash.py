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

    def test_a_window_nothing_knows_of_closes(self):
        box = self.box()
        task = box.create()
        box.helper("stop", id=task["id"])
        # A window made to resume the task, about to be noted in its record.
        box.arm("after", match="automatic-rename")
        self.assertIsNone(box.helper("resume", id=task["id"]))
        box.disarm()
        deadline = time.monotonic() + 8
        while box.windows() and time.monotonic() < deadline:
            time.sleep(0.05)
        self.assertEqual(box.windows(), [])
        reply = box.helper("resume", id=task["id"])
        self.assertTrue(reply["ok"], reply)
        box.wait_for(task, "ready")
        self.assertEqual(len(box.windows()), 1)

    def test_merging_a_task_whose_branch_you_deleted_still_says_so(self):
        box = self.box()
        task = box.create()
        box.helper("stop", id=task["id"])
        box.git("worktree", "remove", "--force", task["worktree"])
        box.git("branch", "-D", task["branch"])
        self.assertIn("no longer exists", box.helper("merge", id=task["id"])["error"])


class Records(unittest.TestCase):
    """Damage to the records on a host."""

    def setUp(self):
        self.box = Box()
        self.addCleanup(self.box.close)
        self.task, self.other = self.box.create("damaged"), self.box.create("other")
        self.path = self.box.state / "tasks" / (self.task["id"] + ".json")
        self.good = self.path.read_bytes()

    def assert_the_other_task_stays(self):
        listed = self.box.helper("list", full=True, socket=self.box.socket)
        self.assertTrue(listed["ok"], listed)
        self.assertIn(self.other["id"], [task["id"] for task in listed["result"]])

    def test_a_damaged_record_leaves_the_others_listed(self):
        for damage in (b"", self.good[:len(self.good) // 2], b"{not json", b"\0" * 64, b'{"id": "\xff"}',
                       b"[]\n", b"null\n", b"3\n", b'"text"\n', b"{}\n"):
            with self.subTest(damage=damage):
                self.path.write_bytes(damage)
                self.assert_the_other_task_stays()
                for action in ("inspect", "forget", "stop"):
                    error = self.box.helper(action, id=self.task["id"])["error"]
                    self.assertIn("is damaged", error)
                    self.assertIsNone(harness.BUG_WORDS.search(error), error)

    def test_a_field_of_the_wrong_type_leaves_the_others_listed(self):
        record = json.loads(self.good)
        for field in ("id", "status", "repo", "worktree", "branch", "baseCommit", "socket", "integrationBranch", "paneId",
                      "windowId"):  # Each of these stopped the listing.
            for value in (5, ["a"]):
                with self.subTest(field=field, value=value):
                    self.path.write_text(json.dumps(dict(record, **{field: value})))
                    self.assert_the_other_task_stays()
        for field in ("id", "status", "repo", "worktree", "branch", "baseCommit", "socket"):
            with self.subTest(missing=field):
                self.path.write_text(json.dumps({key: value for key, value in record.items() if key != field}))
                self.assert_the_other_task_stays()

    def test_a_record_with_another_tasks_id_is_damaged(self):
        self.path.write_text(json.dumps(dict(json.loads(self.good), id=self.other["id"])))
        listed = self.box.helper("list", socket=self.box.socket)["result"]
        self.assertEqual([task["id"] for task in listed], [self.other["id"]])


class FullDisk(unittest.TestCase):
    def setUp(self):
        self.box = Box()
        self.addCleanup(self.box.close)

    def test_your_tasks_stay_listed_and_open(self):
        box = self.box
        task = box.create()
        before = (box.state / "tasks" / (task["id"] + ".json")).read_text()
        reply = box.helper("inspect", id=task["id"], full_disk=True)
        self.assertTrue(reply["ok"], reply)
        # So that the listing has news that it has no room to save.
        box.tmux("kill-server")
        reply = box.helper("list", socket=box.socket, full_disk=True)
        self.assertTrue(reply["ok"], reply)
        self.assertEqual([t["status"] for t in reply["result"]], ["crashed"])
        self.assertEqual((box.state / "tasks" / (task["id"] + ".json")).read_text(), before)
        self.assertEqual(box.records(), [task["id"] + ".json", task["id"] + ".settings"])
        # With room again, it is saved.
        box.helper("list", socket=box.socket)
        self.assertEqual(box.record(task["id"])["status"], "crashed")


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

    def test_a_name_in_any_script_goes_through_under_any_locale(self):
        # Those a host lacks are as C, which is fine.
        name = "修复 é parser 🙂"
        for locale in (dict(LC_ALL="en_US.US-ASCII"), dict(LC_ALL="ja_JP.eucJP"), dict(LC_ALL="en_US.ISO8859-1"),
                       dict(LANG="en_US.US-ASCII")):
            with self.subTest(locale=locale):
                box = self.box(**locale)
                task = box.create(name, prompt=name)
                self.assertEqual(task["name"], name)
                self.assertEqual(box.record(task["id"])["name"], name)
                self.assertEqual(box.helper("list", socket=box.socket)["result"][0]["name"], name)
                self.assertEqual(box.tmux("display-message", "-p", "-t", task["windowId"], "#{window_name}", u=True), name)
                box.commit(task, name, "work\n")
                reply = box.helper("merge", id=task["id"], style="squash")
                self.assertTrue(reply["ok"], reply)
                self.assertEqual(box.git("-c", "core.quotePath=false", "ls-files", name), name)

    def test_what_is_not_utf8_in_a_message_leaves_a_reply(self):
        box = self.box(LC_ALL="en_US.UTF-8")
        task = box.create()
        box.commit(task)
        git = box.root / "bin" / "git"
        real = git.read_text()
        git.write_text("#!/bin/sh\ncase \"$*\" in *\"ls-files --others\"*)\n"
                       "printf 'fatal: cannot read caf\\351\\n' >&2; exit 128 ;; esac\n"
                       'exec "$ROOST_CRASH_GIT" "$@"\n')
        reply = box.helper("merge", id=task["id"])
        git.write_text(real)
        self.assertFalse(reply.get("traceback"), reply)
        self.assertIn("cannot read caf", reply["error"])


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
