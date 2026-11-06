"""The helper's actions, each on a task in the state it acts on, for `crash_harness`."""
import json
from pathlib import Path
import sys

from crash_harness import FAKE, Scenario


class Merge(Scenario):
    action = "merge"

    def request(self, box):
        # Where Emacs last measured the branch, as it asks each time.
        return dict(super().request(box), expect=self.commit)

    def holds(self, box, problems):
        super().holds(box, problems)
        final = self.final
        # Once whichever way it went: the file comes in with one commit of
        # the task's, or of a squash, and a second merge adds another.
        commits = box.git("log", "--format=%H", "--no-merges", "main", "--", "work").split()
        if len(commits) > 1:
            problems.append("the work came in twice: %s" % commits)
        if final and final.get("ok") and not commits:
            problems.append("said merged, and the work isn't on main")
        if final and final.get("ok") and box.git("status", "--porcelain"):
            problems.append("merged, with the primary checkout left dirty: %s" % box.git("status", "--porcelain"))
        if final and final.get("ok") and (box.repo / ".git/MERGE_HEAD").exists():
            problems.append("merged, with a merge left under way")


class MergeSquash(Merge):
    args = dict(style="squash")


class MergeAway(Merge):
    """Into a branch the primary checkout doesn't have checked out."""

    def prepare(self, box):
        box.git("switch", "-q", "-c", "elsewhere")


class SquashAway(MergeAway):
    args = dict(style="squash")


class MergeTeardown(Merge):
    """With the project's teardown command."""
    args = dict(teardown='touch "$ROOST_REPO/.git/torn-down"')


class MergeSubmodule(Merge):
    """In a repository with a submodule, which the task's worktree has too."""

    def arrange(self, box):
        library = box.root / "library"
        box.git("init", "-q", "-b", "main", str(library))
        (library / "lib").write_text("lib\n")
        box.git("add", ".", cwd=library)
        box.git("commit", "-qm", "Library", cwd=library)
        box.git("-c", "protocol.file.allow=always", "submodule", "add", "-q", str(library), "library")
        box.git("commit", "-qm", "Add the library")
        box.git("config", "--global", "protocol.file.allow", "always")
        super().arrange(box)


class MergeAgentWorktree(Merge):
    """With a worktree its agent made, holding nothing beyond the task's branch."""

    def prepare(self, box):
        path = box.repo / ".claude" / "worktrees" / "agent"
        box.git("worktree", "add", "-q", "-b", "agent-work", str(path), self.task["branch"])
        record = box.record(self.task["id"])
        record["agentWorktrees"] = [str(path)]
        (box.state / "tasks" / (self.task["id"] + ".json")).write_text(json.dumps(record))

    def holds(self, box, problems):
        Scenario.holds(self, box, problems)


class Retire(Scenario):
    """A task that made no commits."""
    action = "retire"

    def arrange(self, box):
        self.task = box.create()


class RetireMerged(Scenario):
    """A task you merged yourself."""
    action = "retire"

    def prepare(self, box):
        box.git("merge", "-q", "--no-ff", "--no-edit", self.task["branch"])


class RetireDead(RetireMerged):
    """Its tmux server gone, as after a reboot."""

    def prepare(self, box):
        super().prepare(box)
        box.tmux("kill-server")


class RetireSquashedOnGitHub(Scenario):
    """A pull request GitHub squashed, with its branch still on the remote."""
    action = "retire"

    def arrange(self, box):
        box.origin()
        super().arrange(box)

    def prepare(self, box):
        reply = box.helper("pr", id=self.task["id"], title="Add work")
        assert reply["ok"], reply
        (box.gh_dir / "merged").write_text(self.commit + "\n")
        (box.repo / "work").write_text("work\n")
        box.git("add", ".")
        box.git("commit", "-qm", "Add work (#7)")


class Update(Scenario):
    action = "update"

    def prepare(self, box):
        (box.repo / "main-file").write_text("main\n")
        box.git("add", ".")
        box.git("commit", "-qm", "Move main on")
        box.helper("stop", id=self.task["id"])

    def holds(self, box, problems):
        super().holds(box, problems)
        if self.final and self.final.get("ok") and not (Path(self.task["worktree"]) / "main-file").exists():
            problems.append("updated, without the integration branch's file")


class UpdateConflict(Update):
    def prepare(self, box):
        (box.repo / "work").write_text("other\n")
        box.git("add", ".")
        box.git("commit", "-qm", "Clash with the task")
        box.helper("stop", id=self.task["id"])

    def holds(self, box, problems):
        Scenario.holds(self, box, problems)


class Discard(Scenario):
    action = "discard"
    loses_work = True

    def prepare(self, box):
        self.told = box.helper("discard", id=self.task["id"], dryRun=True)["result"]["discard"]

    def request(self, box):
        return dict(id=self.task["id"], expect=self.told["commit"], told=self.told)

    def again(self, box):
        # Emacs asks what would be lost each time.
        dry = box.helper("discard", id=self.task["id"], dryRun=True)
        if not dry or not dry.get("ok"):
            return dry
        told = dry["result"]["discard"]
        return box.helper("discard", id=self.task["id"], expect=told["commit"], told=told)


class DiscardTeardown(Discard):
    def request(self, box):
        return dict(super().request(box), teardown='touch "$ROOST_REPO/.git/torn-down"')


class DiscardDirty(Discard):
    def prepare(self, box):
        (Path(self.task["worktree"]) / "uncommitted").write_text("kept\n")
        super().prepare(box)


class Forget(Scenario):
    action = "forget"
    leaves = True

    def prepare(self, box):
        box.helper("stop", id=self.task["id"])


class KeepsTask(Scenario):
    """An action that leaves the task there, with its work."""

    def prepare(self, box):
        (Path(self.task["worktree"]) / "uncommitted").write_text("kept\n")

    def holds(self, box, problems):
        super().holds(box, problems)
        path = Path(self.task["worktree"]) / "uncommitted"
        if not path.exists() or path.read_text() != "kept\n":
            problems.append("uncommitted work lost")
        if box.record(self.task["id"]) is None:
            problems.append("the task's record is gone")


class Rename(KeepsTask):
    action = "rename"
    args = dict(name="new name")

    def holds(self, box, problems):
        super().holds(box, problems)
        record = box.record(self.task["id"]) or {}
        if self.final and self.final.get("ok") and record.get("name") != "new name":
            problems.append("said renamed, and its name is %r" % record.get("name"))


class Stop(KeepsTask):
    action = "stop"


class Resume(KeepsTask):
    action = "resume"

    def prepare(self, box):
        super().prepare(box)
        box.helper("stop", id=self.task["id"])


class Seen(KeepsTask):
    action = "seen"
    args = dict(updatedAt="2026-11-05T00:00:00+00:00")


class Turn(KeepsTask):
    action = "turn"
    args = dict(turn="to merge")


class Send(KeepsTask):
    action = "send"
    args = dict(text="hello", sendId="ab" * 8)


class Shell(KeepsTask):
    action = "shell"


class Attach(KeepsTask):
    action = "attach"
    args = dict(files=[dict(name="notes.txt", data="aGVsbG8K")])


class Inspect(KeepsTask):
    action = "inspect"


class Look(KeepsTask):
    action = "look"


class PullRequest(KeepsTask):
    action = "pr"
    args = dict(title="Add work", body="Why")

    def arrange(self, box):
        box.origin()
        super().arrange(box)

    def holds(self, box, problems):
        super().holds(box, problems)
        opened = box.opened()
        if len(opened) > 1:
            problems.append("opened twice: %s" % opened)
        if self.final and self.final.get("ok") and not opened:
            problems.append("said opened, and nothing was")


class PullRequestPush(PullRequest):
    """A pull request that's open already, with a new commit to push."""

    def prepare(self, box):
        super().prepare(box)
        reply = box.helper("pr", id=self.task["id"], title="Add work")
        assert reply["ok"], reply
        box.commit(self.task, "more", "more\n")


class Create(Scenario):
    """As Emacs asks, with an ID that makes a second request find the first's."""
    action = "create"
    # A helper killed alone just before Git starts, with you asking again in
    # that moment: Emacs's kill takes Git too, and ssh's end leaves the helper.
    # The note isn't handed to Git, or what a hook left would hold it, so a
    # second task can come of it. Nothing but this harness kills so.
    left_out = ("racing",)

    def arrange(self, box):
        self.commit = None
        self.asked = dict(directory=str(box.repo), name="made", socket=box.socket,
                          command=[sys.executable, str(FAKE)], createId="ab" * 8)

    def request(self, box):
        return self.asked

    def holds(self, box, problems):
        final = self.final
        if final and final.get("ok"):
            self.task = final["result"]
            listed = box.helper("list", socket=box.socket)
            ids = [task["id"] for task in listed["result"]] if listed and listed.get("ok") else []
            if ids != [self.task["id"]]:
                problems.append("asked again, and the list has %s rather than %s" % (ids, self.task["id"]))


class CreateFromRemote(Create):
    """From a remote-tracking branch, which makes a local one to merge into."""

    def arrange(self, box):
        box.git("init", "-q", "--bare", "-b", "main", str(box.root / "origin.git"))
        box.git("remote", "add", "origin", str(box.root / "origin.git"))
        box.git("push", "-q", "origin", "main:feature")
        box.git("fetch", "-q", "origin")
        super().arrange(box)
        self.asked = dict(self.asked, base="origin/feature")


ALL = [Merge, MergeSquash, MergeAway, SquashAway, MergeTeardown, MergeSubmodule, MergeAgentWorktree, Retire, RetireMerged,
       RetireDead, RetireSquashedOnGitHub, Update, UpdateConflict, Discard, DiscardDirty, DiscardTeardown, Forget, Rename,
       Stop, Resume, Seen, Turn, Send, Shell, Attach, Inspect, Look, PullRequest, PullRequestPush, Create, CreateFromRemote]
