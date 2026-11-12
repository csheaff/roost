"""The helper's actions, each on a task in the state it acts on, for `crash_harness`."""
import html
import json
from pathlib import Path
import signal
import subprocess
import sys

from crash_harness import FAKE, HELPER, LINES, Scenario


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
        box.git("worktree", "add", "-q", "-b", "worktree-agent", str(path), self.task["branch"])
        record = box.record(self.task["id"])
        record["agentWorktrees"] = record["agentMade"] = [str(path)]
        record["agentMadeAt"] = {str(path): (box.repo / ".git/worktrees/agent/commondir").stat().st_mtime_ns}
        (box.state / "tasks" / (self.task["id"] + ".json")).write_text(json.dumps(record))

    def holds(self, box, problems):
        Scenario.holds(self, box, problems)
        if self.final and self.final.get("ok") and "main" not in box.branches():
            problems.append("the primary checkout's branch went with its agent's worktree")


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


class Retarget(KeepsTask):
    """The branch a task merges into, changed: whenever the helper stops,
    the record names one branch, whole, the old or the new."""

    action = "retarget"
    args = dict(base="other")

    def prepare(self, box):
        super().prepare(box)
        box.git("branch", "other")

    def holds(self, box, problems):
        super().holds(box, problems)
        record = box.record(self.task["id"]) or {}
        branch = record.get("integrationBranch")
        if branch not in ("main", "other"):
            problems.append("it merges into %r" % branch)
        elif record.get("integrationRef") != "refs/heads/" + branch:
            problems.append("it merges into %s by the name %r" % (branch, record.get("integrationRef")))
        elif self.final and self.final.get("ok") and branch != "other":
            problems.append("said to merge into other, and it merges into %s" % branch)


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


def offer(box, task, mode=None, at=None, tool="propose_task", arguments=None):
    """Have TASK's agent offer a task through its MCP server, as Claude Code
    runs it, and return the reply as a request's, or None if it died. With
    MODE `line', the server dies at the ATth line of the helper it reaches.
    Or have it call another TOOL of the server's, with ARGUMENTS."""
    call = dict(jsonrpc="2.0", id=1, method="tools/call",
                params=dict(name=tool, arguments=arguments or dict(title="Fix add", brief="add() subtracts.")))
    argv = [sys.executable, "-I", str(HELPER), "mcp", str(box.state), task["id"]]
    if mode == "line":
        argv = [sys.executable, "-c", LINES, str(HELPER), str(at), str(box.inject / "lines"),
                "mcp", str(box.state), task["id"]]
    ran = subprocess.run(argv, input=json.dumps(call) + "\n", capture_output=True, text=True, env=box.env,
                         cwd="/", timeout=60)
    if ran.returncode == -signal.SIGKILL:
        return None
    replies = [json.loads(line) for line in ran.stdout.splitlines() if line.strip()]
    if ran.returncode or not replies:
        return dict(ok=False, error="The server exited %s, with nothing to say: %s"
                    % (ran.returncode, ran.stderr.strip()[-400:]), traceback=True)
    # A JSON-RPC error is the server's own failure, as a bug it caught, never
    # a refusal of the agent's offer, which comes as a result.
    if "error" in replies[0]:
        return dict(ok=False, error="The server answered with an error: %s" % replies[0]["error"], traceback=True)
    result = replies[0].get("result") or {}
    said = "".join(part.get("text", "") for part in result.get("content") or [])
    return dict(ok=False, error=said) if result.get("isError") else dict(ok=True, result=said)


class Propose(KeepsTask):
    """An agent offers a task, which only its task's record keeps."""
    action = "propose_task"

    def ask(self, box):
        return offer(box, self.task, box.mode, box.at)

    def again(self, box):
        return offer(box, self.task)

    def holds(self, box, problems):
        super().holds(box, problems)
        offers = (box.record(self.task["id"]) or {}).get("offers") or []
        # Offered again, it replaces itself, under its ID.
        if self.final and self.final.get("ok") and [o.get("title") for o in offers] != ["Fix add"]:
            problems.append("offered, and its task's record has %s" % offers)


class Show(KeepsTask):
    """An agent shows an image: whenever the helper stops, the task's
    record names none, or one whose copy is there whole."""
    action = "show_image"
    png = b"\x89PNG\r\n\x1a\n" + b"pixels"

    def prepare(self, box):
        super().prepare(box)
        (Path(self.task["worktree"]) / "shot.png").write_bytes(self.png)

    def show(self, box, mode=None, at=None):
        return offer(box, self.task, mode, at, tool="show_image", arguments=dict(path="shot.png"))

    def ask(self, box):
        return self.show(box, box.mode, box.at)

    def again(self, box):
        return self.show(box)

    def holds(self, box, problems):
        super().holds(box, problems)
        shown = (box.record(self.task["id"]) or {}).get("shown")
        if self.final and self.final.get("ok") and not shown:
            problems.append("said shown, and its task's record names no image")
        if shown:
            copy = box.state / "shown" / self.task["id"] / ("%s.%s" % (shown["id"], shown["kind"]))
            if not copy.exists() or copy.read_bytes() != self.png:
                problems.append("its record names an image whose copy is not there whole")


class ShowPage(Show):
    """An agent shows a page it wrote, which is kept as an image is."""
    action = "show_widget"
    code = "<button onclick=\"sendPrompt('Go on')\">Go on</button>"

    def prepare(self, box):
        super().prepare(box)
        # As a task made with `roost-agent-pages' on.
        path = box.state / "tasks" / (self.task["id"] + ".json")
        path.write_text(json.dumps(dict(json.loads(path.read_text()), mayShowPages=True)))

    def show(self, box, mode=None, at=None):
        return offer(box, self.task, mode, at, tool="show_widget",
                     arguments=dict(title="next step", widget_code=self.code))

    def holds(self, box, problems):
        KeepsTask.holds(self, box, problems)
        shown = (box.record(self.task["id"]) or {}).get("shown")
        if self.final and self.final.get("ok") and not shown:
            problems.append("said shown, and its task's record names no page")
        if shown:
            copy = box.state / "shown" / self.task["id"] / ("%s.%s" % (shown["id"], shown["kind"]))
            page = copy.read_text() if copy.exists() else ""
            if html.escape(self.code, quote=True) not in page or not page.endswith("</script>\n"):
                problems.append("its record names a page whose copy is not there whole")


class TakeOffer(KeepsTask):
    """Opening an offer, having its agent do it, or dismissing it."""
    action = "take-offer"

    def prepare(self, box):
        super().prepare(box)
        reply = offer(box, self.task)
        assert reply and reply["ok"], reply
        self.offer = box.record(self.task["id"])["offers"][0]["id"]

    def request(self, box):
        return dict(id=self.task["id"], offer=self.offer)

    def holds(self, box, problems):
        super().holds(box, problems)
        record = box.record(self.task["id"]) or {}
        if self.final and self.final.get("ok") and record.get("offers"):
            problems.append("said taken, and the offer still waits: %s" % record["offers"])


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


class CreateFromOffer(Create):
    """From an agent's offer whose take, as it was opened, failed: once its
    task is made, the offer waits no more, however its creation was cut
    short and asked for again."""

    def arrange(self, box):
        super().arrange(box)
        self.parent = box.create(name="parent")
        reply = offer(box, self.parent)
        assert reply and reply["ok"], reply
        self.offer = box.record(self.parent["id"])["offers"][0]["id"]
        self.asked = dict(self.asked, parent=self.parent["id"], offer=self.offer)

    def holds(self, box, problems):
        final = self.final
        if final and final.get("ok"):
            self.task = final["result"]
        records = [box.record(name[:-len(".json")]) for name in box.records() if name.endswith(".json")]
        made = [record for record in records
                if record and record.get("parent") == self.parent["id"] and record.get("offer") == self.offer]
        if len(made) > 1:
            problems.append("its offer made %d tasks" % len(made))
        waiting = [other.get("id") for other in (box.record(self.parent["id"]) or {}).get("offers") or []]
        if made and self.offer in waiting:
            problems.append("its task was made, and its offer still waits")


class CreateFork(Create):
    """A fork of a task, which starts where that task's work stands, read
    with its worktree held: however the fork's creation was cut short, its
    source is as it was, and nothing holds it."""

    def arrange(self, box):
        super().arrange(box)
        self.source = box.create(name="source")
        (Path(self.source["worktree"]) / "left").write_text("not committed\n")
        self.asked = dict(self.asked, directory=self.source["worktree"], base="HEAD", forkFrom=self.source["id"])

    def holds(self, box, problems):
        final = self.final
        if final and final.get("ok"):
            self.task = final["result"]
            if not (Path(self.task["worktree"]) / "left").is_file():
                problems.append("the fork was made without its source's uncommitted file")
        if not (Path(self.source["worktree"]) / "left").is_file():
            problems.append("its source lost its uncommitted file")
        # Finishing the source is refused while anything holds its worktree.
        told = box.helper("discard", id=self.source["id"], dryRun=True)
        if not (told and told.get("ok")):
            problems.append("its source can't be finished: %s" % (told and told.get("error")))


class CreateConversation(Create):
    """A conversation, the first, which makes the repository it is in."""

    def arrange(self, box):
        super().arrange(box)
        self.asked = dict(self.asked, directory="/nowhere", conversation=True)

    def holds(self, box, problems):
        super().holds(box, problems)
        if self.final and self.final.get("ok") and not self.final["result"].get("conversation"):
            problems.append("asked again, and what was made is no conversation")


ALL = [Merge, MergeSquash, MergeAway, SquashAway, MergeTeardown, MergeSubmodule, MergeAgentWorktree, Retire, RetireMerged,
       RetireDead, RetireSquashedOnGitHub, Update, UpdateConflict, Discard, DiscardDirty, DiscardTeardown, Forget, Rename,
       Retarget,
       Stop, Resume, Seen, Turn, Send, Shell, Attach, Inspect, Look, PullRequest, PullRequestPush, Create, CreateFromRemote,
       Propose, Show, ShowPage, TakeOffer, CreateFromOffer, CreateFork, CreateConversation]
