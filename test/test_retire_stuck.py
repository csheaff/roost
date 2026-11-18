"""Ways a retire used to stay refused for good, against real Git: a
removal Git cut short, a teardown command that leaves a file, and a ~user
the host doesn't have."""
import importlib.util
import json
from pathlib import Path
import subprocess
import sys
import unittest

from crash_harness import Box, BUG_WORDS, FAKE, HELPER

spec = importlib.util.spec_from_file_location("roost_remote", HELPER)
roost = importlib.util.module_from_spec(spec)
spec.loader.exec_module(roost)

# Once Git has begun to delete the worktree, write a file into the
# worktree's own folder, which Git empties last: Git then fails to delete
# it, having deleted the rest, and its record of the worktree too.
WRITER = r"""
import os, sys, time
worktree, written = sys.argv[1], sys.argv[2]
firsts = [os.path.join(worktree, "d%03d" % d, "f0") for d in range(50)]
deadline = time.time() + 60
while time.time() < deadline and all(os.path.exists(path) for path in firsts):
    time.sleep(0.0002)
path = os.path.join(worktree, "server.log")
try:
    with open(path, "w") as out:
        out.write("results\n")
except OSError:
    sys.exit(1)
with open(written, "a") as out:
    out.write(path + "\n")
"""


class CutShort(unittest.TestCase):
    def setUp(self):
        self.box = box = Box()
        self.addCleanup(box.close)
        # A worktree of some size, which Git takes a while to delete.
        for d in range(50):
            folder = box.repo / ("d%03d" % d)
            folder.mkdir()
            for i in range(100):
                (folder / ("f%d" % i)).write_text("x\n")
        box.git("add", ".")
        box.git("commit", "-qm", "Many files")
        self.task = box.create()
        self.worktree = Path(self.task["worktree"])
        self.assertTrue(box.helper("stop", id=self.task["id"])["ok"])

    def assert_back(self):
        """The task's worktree is one again, on its branch, every file there."""
        worktree = self.worktree
        self.assertEqual(self.box.git("symbolic-ref", "HEAD", cwd=worktree), "refs/heads/" + self.task["branch"])
        self.assertIn(str(worktree), self.box.worktrees())
        self.assertTrue((worktree / "d049" / "f99").exists())
        self.assertEqual(self.box.git("ls-files", "--deleted", cwd=worktree), "")

    def assert_finishes(self):
        box = self.box
        done = box.helper("retire", id=self.task["id"])
        self.assertTrue(done["ok"], done)
        self.assertFalse(self.worktree.exists())
        self.assertNotIn(self.task["branch"], box.branches())
        self.assertEqual(box.records(), [])

    def test_a_retire_git_cut_short_puts_the_worktree_back_and_can_be_finished(self):
        """A folder Git can't delete, as a module cache a build left
        read-only, stops it partway, every time."""
        box = self.box
        stuck = self.worktree / "d025"
        stuck.chmod(0o555)
        self.addCleanup(lambda: stuck.exists() and stuck.chmod(0o755))
        box.arm("before", 10 ** 9)
        reply = box.helper("retire", id=self.task["id"])
        box.disarm()
        self.assertFalse(reply["ok"], reply)
        self.assertIn("Git stopped partway", reply["error"])
        # Nothing newer than Roost's oldest Git: worktree repair is 2.29.
        self.assertNotIn("worktree repair", (box.inject / "log").read_text())
        self.assertIsNone(BUG_WORDS.search(reply["error"]), reply["error"])
        stuck.chmod(0o755)
        self.assert_back()
        self.assertEqual(box.git("status", "--porcelain", cwd=self.worktree), "")
        self.assert_finishes()

    def test_a_retire_cut_short_as_it_died_is_put_back_when_asked_again(self):
        """The helper killed as Git stops: its mark says to put it back."""
        box = self.box
        stuck = self.worktree / "d025"
        stuck.chmod(0o555)
        self.addCleanup(lambda: stuck.exists() and stuck.chmod(0o755))
        box.arm("after", match="worktree remove")
        self.assertIsNone(box.helper("retire", id=self.task["id"]))
        box.disarm()
        stuck.chmod(0o755)
        self.assertTrue(box.record(self.task["id"]).get("removing"))
        self.assert_finishes()

    def test_a_relink_cut_short_is_done_again(self):
        """The helper killed as it makes the worktree one again, at each
        step that leaves something of Git's behind."""
        steps = ("symbolic-ref HEAD refs/heads/", "reset -q", "ls-files --deleted")
        for step in steps:
            with self.subTest(step=step):
                if step != steps[0]:
                    self.setUp()
                box = self.box
                stuck = self.worktree / "d025"
                stuck.chmod(0o555)
                self.addCleanup(lambda stuck=stuck: stuck.exists() and stuck.chmod(0o755))
                box.arm("before", match=step)
                self.assertIsNone(box.helper("retire", id=self.task["id"]))
                box.disarm()
                stuck.chmod(0o755)
                # Killed relinking, which comes only once Git stopped.
                self.assertTrue(box.record(self.task["id"]).get("removing"))
                if step == steps[-1]:
                    # Linked again, its files not yet put back.
                    self.assertIn(str(self.worktree), box.worktrees())
                else:
                    self.assertTrue(list(self.worktree.parent.glob(".relink-*")), "killed before relinking")
                self.assert_finishes()
                self.assertEqual([path for path in box.worktrees() if ".relink-" in path], [])
                self.assertEqual(list(self.worktree.parent.glob(".relink-*")), [])

    def spare_left(self, step="reset -q"):
        """Retire, Git stopped by a folder it can't delete, and the helper
        killed at STEP of the relink, with its spare worktree made: the
        spare's folder."""
        box = self.box
        stuck = self.worktree / "d025"
        stuck.chmod(0o555)
        self.addCleanup(lambda: stuck.exists() and stuck.chmod(0o755))
        box.arm("before", match=step)
        self.assertIsNone(box.helper("retire", id=self.task["id"]))
        box.disarm()
        stuck.chmod(0o755)
        spares = [Path(path) for path in box.worktrees() if ".relink-" in path]
        self.assertEqual(len(spares), 1, box.worktrees())
        return spares[0]

    def test_asking_what_a_discard_loses_deletes_no_spare(self):
        box = self.box
        spare = self.spare_left()
        told = box.helper("discard", id=self.task["id"], dryRun=True)
        self.assertTrue(told["ok"], told)
        self.assertTrue(spare.parent.is_dir())
        self.assertIn(str(spare), box.worktrees())
        told = told["result"]["discard"]
        reply = box.helper("discard", id=self.task["id"], told=told, expect=told["commit"])
        self.assertTrue(reply["ok"], reply)
        self.assertFalse(spare.parent.exists())
        self.assertEqual([path for path in box.worktrees() if ".relink-" in path], [])

    def test_a_spare_that_holds_work_is_kept_and_said(self):
        box = self.box
        spare = self.spare_left()
        (spare / "notes").write_text("mine\n")
        for action in ("retire", "discard"):
            reply = box.helper(action, id=self.task["id"], **({"dryRun": True} if action == "discard" else {}))
            self.assertFalse(reply["ok"], reply)
            self.assertIn(str(spare), reply["error"])
        self.assertTrue((spare / "notes").exists())
        self.assertIn(str(spare), box.worktrees())
        (spare / "notes").unlink()
        self.assert_finishes()

    def test_what_else_is_beside_a_spare_stays(self):
        box = self.box
        spare = self.spare_left()
        (spare.parent / "notes.txt").write_text("mine\n")
        self.assert_finishes()
        self.assertEqual((spare.parent / "notes.txt").read_text(), "mine\n")
        self.assertFalse(spare.exists())

    def test_a_spare_left_once_the_worktree_folder_went_is_no_worktree_moved(self):
        box = self.box
        spare = self.spare_left("symbolic-ref HEAD refs/heads/")
        # You deleted what was left of it, its work all committed.
        subprocess.run(["rm", "-rf", str(self.worktree)], check=True)
        reply = box.helper("retire", id=self.task["id"])
        self.assertTrue(reply["ok"], reply)
        self.assertFalse(spare.parent.exists())
        self.assertNotIn(self.task["branch"], box.branches())

    def test_only_a_spare_of_this_worktree_is_taken_for_one(self):
        worktree = Path("/state/worktrees/abc/build-abcdef")
        self.assertTrue(roost.spare_of(worktree, "/state/worktrees/abc/.relink-build-abcdef-0123456789ab/build-abcdef"))
        for other in ("/state/worktrees/abc/.relink-build-abcdef-extra-123456-0123456789ab/build-abcdef-extra-123456",
                      "/state/worktrees/abc/.relink-build-abcdef-extra-0123456789ab/build-abcdef",
                      "/state/worktrees/abc/.relink-build-abcdef-0123456789ab/other",
                      "/state/worktrees/xyz/.relink-build-abcdef-0123456789ab/build-abcdef"):
            self.assertFalse(roost.spare_of(worktree, other), other)

    def test_a_folder_made_a_worktree_of_another_repository_keeps_its_link(self):
        box = self.box
        stuck = self.worktree / "d025"
        stuck.chmod(0o555)
        self.addCleanup(lambda: stuck.exists() and stuck.chmod(0o755))
        box.arm("after", match="worktree remove")
        self.assertIsNone(box.helper("retire", id=self.task["id"]))
        box.disarm()
        stuck.chmod(0o755)
        # Since, someone made it one of another repository's.
        other = box.root / "other"
        box.git("init", "-q", "-b", "main", str(other))
        (other / "f").write_text("f\n")
        box.git("add", ".", cwd=other)
        box.git("commit", "-qm", "Other", cwd=other)
        box.git("worktree", "add", "-q", "--detach", str(box.root / "theirs"), cwd=other)
        link = "gitdir: %s\n" % box.git("rev-parse", "--absolute-git-dir", cwd=box.root / "theirs")
        (self.worktree / ".git").write_text(link)
        reply = box.helper("retire", id=self.task["id"])
        self.assertFalse(reply["ok"], reply)
        self.assertIn("another repository", reply["error"])
        self.assertEqual((self.worktree / ".git").read_text(), link)

    def test_a_worktree_git_forgot_can_be_discarded(self):
        box = self.box
        stuck = self.worktree / "d025"
        stuck.chmod(0o555)
        self.addCleanup(lambda: stuck.exists() and stuck.chmod(0o755))
        box.arm("before", match="symbolic-ref HEAD refs/heads/")
        self.assertIsNone(box.helper("retire", id=self.task["id"]))
        box.disarm()
        stuck.chmod(0o755)
        told = box.helper("discard", id=self.task["id"], dryRun=True)
        self.assertTrue(told["ok"], told)
        told = told["result"]["discard"]
        self.assertGreater(told["changes"], 0)
        reply = box.helper("discard", id=self.task["id"], told=told, expect=told["commit"])
        self.assertTrue(reply["ok"], reply)
        self.assertFalse(self.worktree.exists())
        self.assertEqual([path for path in box.worktrees() if ".relink-" in path], [])
        self.assertEqual(list(self.worktree.parent.glob(".relink-*")), [])

    def test_a_file_written_as_git_removes_the_worktree_is_kept(self):
        box = self.box
        written = box.root / "written"
        writer = subprocess.Popen([sys.executable, "-c", WRITER, str(self.worktree), str(written)],
                                  start_new_session=True)
        self.addCleanup(writer.kill)
        reply = box.helper("retire", id=self.task["id"])
        left = self.worktree / "server.log"
        if writer.wait(timeout=60) or reply["ok"]:
            # Git read the folder after the write, or deleted it before.
            self.skipTest("the write came before Git read the worktree's folder, or after it went")
        self.assertIn("server.log", reply["error"])
        self.assertTrue(left.exists(), "deleted %s" % left)
        self.assert_back()
        # Asked again, it says so again, and keeps the file.
        again = box.helper("retire", id=self.task["id"])
        self.assertFalse(again["ok"], again)
        self.assertNotIn("bring back what is missing", again["error"])
        self.assertTrue(left.exists())
        # Once you have moved it, retiring finishes.
        left.rename(box.root / "kept.log")
        self.assert_finishes()


class Teardown(unittest.TestCase):
    def setUp(self):
        self.box = Box()
        self.addCleanup(self.box.close)
        self.task = self.box.create()

    def test_a_teardown_command_that_leaves_a_file_says_how_to_retire(self):
        box, task = self.box, self.task
        box.helper("stop", id=task["id"])
        teardown = "date > teardown.log"
        first = box.helper("retire", id=task["id"], teardown=teardown)
        self.assertFalse(first["ok"], first)
        self.assertIn("teardown.log", first["error"])
        self.assertIn(".git/info/exclude", first["error"])
        self.assertTrue((Path(task["worktree"]) / "teardown.log").exists())
        # As the refusal says: ignored, it goes with the worktree.
        with open(box.repo / ".git" / "info" / "exclude", "a") as exclude:
            exclude.write("teardown.log\n")
        again = box.helper("retire", id=task["id"], teardown=teardown)
        self.assertTrue(again["ok"], again)
        self.assertFalse(Path(task["worktree"]).exists())


class UnknownUser(unittest.TestCase):
    def setUp(self):
        self.box = Box()
        self.addCleanup(self.box.close)

    def assert_refused_plainly(self, reply):
        self.assertFalse(reply["ok"], reply)
        self.assertIn("nosuchuser-roost", reply["error"])
        self.assertNotIn("RuntimeError", reply["error"])
        self.assertIsNone(BUG_WORDS.search(reply["error"]), reply["error"])

    def test_create_in_a_directory_of_an_unknown_user(self):
        reply = self.box.helper("create", directory="~nosuchuser-roost/x", name="t", socket=self.box.socket,
                                command=[sys.executable, str(FAKE)], createId="ab" * 8)
        self.assert_refused_plainly(reply)
        self.assertEqual(self.box.helper("list", socket=self.box.socket)["result"], [])

    def test_issues_of_a_directory_of_an_unknown_user(self):
        self.assert_refused_plainly(self.box.helper("issues", directory="~nosuchuser-roost/x"))

    def test_a_state_directory_of_an_unknown_user(self):
        out = subprocess.run([sys.executable, "-I", str(HELPER), "rpc"], input=json.dumps(
            dict(root="~nosuchuser-roost/state", action="list", socket=self.box.socket)),
            capture_output=True, text=True, env=self.box.env, cwd="/")
        self.assertTrue(out.stdout.strip(), out.stderr[-600:])
        self.assert_refused_plainly(json.loads(out.stdout))


if __name__ == "__main__":
    unittest.main()
