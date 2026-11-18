------------------------------- MODULE GitWork -------------------------------
(***************************************************************************)
(* What Git holds of the work agents do in worktrees, for any tool that    *)
(* runs them, and the rules a tool's cleanup must keep.  A tool's own      *)
(* model EXTENDS this one and builds its steps from the Git actions here;  *)
(* GitTool.tla is an example; GitToolRoost.tla, Roost's `retire`.          *)
(*                                                                         *)
(* Git is cut down to units of work: a file someone wrote, uncommitted or  *)
(* untracked, or the commit it became.  Units are content, not commit      *)
(* IDs, so a squash merge or a rebase puts a task's units on the           *)
(* integration branch without its commits.  A unit that no branch,         *)
(* worktree, reflog or backup ref holds any more is lost: a branch's       *)
(* reflog goes when the branch is deleted, and a worktree's HEAD reflog    *)
(* when the worktree is removed, after which only luck and `git fsck`      *)
(* before the next gc bring it back.                                       *)
(*                                                                         *)
(* Left out, on purpose: the remote (take `main` to be the branch work     *)
(* lands on, wherever it is), stashes, gc timing, and a tool's own         *)
(* records and protocol (creating a task twice is the tool's to model).    *)
(***************************************************************************)
EXTENDS Naturals, FiniteSets

CONSTANTS
    Tasks,          \* the tasks, each in a worktree on a branch of its own
    MaxWork         \* units of work anyone may make

Unit == [t : Tasks, n : 0..MaxWork]     \* n = 0: on the branch before the task
Pre(t) == [t |-> t, n |-> 0]

VARIABLES
    main,           \* the units the integration branch has
    wt,             \* [Tasks -> {"there", "gone"}]: the task's worktree
    dirty,          \* [Tasks -> SUBSET Unit]: uncommitted and untracked files in
                    \* it, what `git status` shows
    ignored,        \* [Tasks -> SUBSET Unit]: files in it that .gitignore hides
                    \* (.env.local, notes, a local database): `git status` and
                    \* `git worktree remove` pass over them, and the removal
                    \* deletes them
    br,             \* [Tasks -> BOOLEAN]: the task's branch exists
    brUnits,        \* [Tasks -> SUBSET Unit]: the units its commits hold
    reflog,         \* [Tasks -> SUBSET Unit]: units of commits the branch held
                    \* and no longer does, after a reset: only the branch's
                    \* reflog and the worktree's HEAD reflog name them
    tipOnMain,      \* [Tasks -> BOOLEAN]: main has the branch's tip as an
                    \* ancestor, all that `git branch -d` and `--merged` see
    owned,          \* [Tasks -> BOOLEAN]: the tool made the branch; FALSE, it
                    \* was yours before the task, with a commit of yours on it
    backup,         \* [Tasks -> SUBSET Unit]: a hidden ref, refs/backup/<task>
    \* What the rules read.
    made,           \* every unit anyone made
    discarded,      \* the units you chose to throw away
    next,           \* the next unit's number
    removedOther    \* a branch the tool did not make was deleted

gitVars == <<main, wt, dirty, ignored, br, brUnits, reflog, tipOnMain, owned, backup,
             made, discarded, next, removedOther>>

GitTypeOK ==
    /\ main \subseteq Unit
    /\ wt \in [Tasks -> {"there", "gone"}]
    /\ dirty \in [Tasks -> SUBSET Unit]
    /\ ignored \in [Tasks -> SUBSET Unit]
    /\ reflog \in [Tasks -> SUBSET Unit]
    /\ br \in [Tasks -> BOOLEAN]
    /\ brUnits \in [Tasks -> SUBSET Unit]
    /\ tipOnMain \in [Tasks -> BOOLEAN]
    /\ owned \in [Tasks -> BOOLEAN]
    /\ backup \in [Tasks -> SUBSET Unit]

GitInit ==
    /\ owned \in [Tasks -> BOOLEAN]
    /\ main = {}
    /\ wt = [t \in Tasks |-> "there"]
    /\ dirty = [t \in Tasks |-> {}]
    /\ ignored = [t \in Tasks |-> {}]
    /\ reflog = [t \in Tasks |-> {}]
    /\ br = [t \in Tasks |-> TRUE]
    /\ brUnits = [t \in Tasks |-> IF owned[t] THEN {} ELSE {Pre(t)}]
    /\ tipOnMain = [t \in Tasks |-> owned[t]]
    /\ backup = [t \in Tasks |-> {}]
    /\ made = {Pre(t) : t \in {s \in Tasks : ~owned[s]}}
    /\ discarded = {}
    /\ next = 1
    /\ removedOther = FALSE

-----------------------------------------------------------------------------
(* What a tool may ask of Git.  Each is one Git command, done whole.       *)

\* Someone, the agent or you, writes a file in the task's worktree:
\* one `git status` shows, or one .gitignore hides.
NewUnit(t) == [t |-> t, n |-> next]
GitWrite(t) ==
    /\ wt[t] = "there" /\ next <= MaxWork
    /\ dirty' = [dirty EXCEPT ![t] = @ \cup {NewUnit(t)}]
    /\ made' = made \cup {NewUnit(t)}
    /\ next' = next + 1
    /\ UNCHANGED <<main, wt, ignored, br, brUnits, reflog, tipOnMain, owned, backup, discarded, removedOther>>
GitWriteIgnored(t) ==
    /\ wt[t] = "there" /\ next <= MaxWork
    /\ ignored' = [ignored EXCEPT ![t] = @ \cup {NewUnit(t)}]
    /\ made' = made \cup {NewUnit(t)}
    /\ next' = next + 1
    /\ UNCHANGED <<main, wt, dirty, br, brUnits, reflog, tipOnMain, owned, backup, discarded, removedOther>>

\* `git add -A && git commit` in the task's worktree.
GitCommit(t) ==
    /\ wt[t] = "there" /\ br[t] /\ dirty[t] # {}
    /\ brUnits' = [brUnits EXCEPT ![t] = @ \cup dirty[t]]
    /\ dirty' = [dirty EXCEPT ![t] = {}]
    /\ tipOnMain' = [tipOnMain EXCEPT ![t] = FALSE]
    /\ UNCHANGED <<main, wt, ignored, br, reflog, owned, backup, made, discarded, next, removedOther>>

\* `git reset --hard <start>`, as an agent starting over does: the task's
\* commits leave the branch, and only reflogs name them.
GitReset(t) ==
    /\ wt[t] = "there" /\ br[t] /\ dirty[t] = {} /\ brUnits[t] \ {Pre(t)} # {}
    /\ reflog' = [reflog EXCEPT ![t] = @ \cup (brUnits[t] \ {Pre(t)})]
    /\ brUnits' = [brUnits EXCEPT ![t] = @ \cap {Pre(t)}]
    /\ tipOnMain' = [tipOnMain EXCEPT ![t] = owned[t]]
    /\ UNCHANGED <<main, wt, dirty, ignored, br, owned, backup, made, discarded, next, removedOther>>

\* The branch lands with a merge commit, or fast-forward: main has its tip.
GitMerge(t) ==
    /\ br[t] /\ ~(brUnits[t] \subseteq main /\ tipOnMain[t])
    /\ main' = main \cup brUnits[t]
    /\ tipOnMain' = [tipOnMain EXCEPT ![t] = TRUE]
    /\ UNCHANGED <<wt, dirty, ignored, br, brUnits, reflog, owned, backup, made, discarded, next, removedOther>>

\* The branch lands squashed or rebased, as most forges merge a pull
\* request: main has its units, not its commits.
GitSquash(t) ==
    /\ br[t] /\ ~(brUnits[t] \subseteq main)
    /\ main' = main \cup brUnits[t]
    /\ UNCHANGED <<wt, dirty, ignored, br, brUnits, reflog, tipOnMain, owned, backup, made, discarded, next, removedOther>>

\* `git worktree remove [--force]`: without force, Git refuses a worktree
\* with uncommitted or untracked files, checking as it removes.  Either
\* way it deletes the ignored files and the worktree's HEAD reflog.
GitCanRemoveWorktree(t, force) == wt[t] = "there" /\ (force \/ dirty[t] = {})
GitRemoveWorktree(t) ==
    /\ wt' = [wt EXCEPT ![t] = "gone"]
    /\ dirty' = [dirty EXCEPT ![t] = {}]
    /\ ignored' = [ignored EXCEPT ![t] = {}]
    /\ reflog' = [reflog EXCEPT ![t] = IF br[t] THEN @ ELSE {}]
    /\ UNCHANGED <<main, br, brUnits, tipOnMain, owned, backup, made, discarded, next, removedOther>>

\* `git branch -d` (force FALSE) refuses unless main has the tip; `-D`
\* (force TRUE) never does.  With cas, Git deletes it only if it still
\* holds `expect`, the units the tool saw on it: `git update-ref -d
\* refs/heads/<b> <old>`.  Without, wherever it now points.  The branch's
\* reflog goes with it.
GitCanDeleteBranch(t, force, cas, expect) ==
    /\ br[t]
    /\ force \/ tipOnMain[t]
    /\ ~cas \/ brUnits[t] = expect
GitDeleteBranch(t) ==
    /\ br' = [br EXCEPT ![t] = FALSE]
    /\ brUnits' = [brUnits EXCEPT ![t] = {}]
    /\ reflog' = [reflog EXCEPT ![t] = IF wt[t] = "there" THEN @ ELSE {}]
    /\ removedOther' = (removedOther \/ ~owned[t])
    /\ UNCHANGED <<main, wt, dirty, ignored, tipOnMain, owned, backup, made, discarded, next>>

\* What `git safe-remove` would do first: commit everything, untracked and
\* ignored files and reflog-only commits too, through a scratch index into
\* refs/backup/<task>, leaving the worktree and your staging area as they
\* were.  (Ignored files can be big: a tool may choose to keep fewer, and
\* say so.)
Here(t, files) == IF wt[t] = "there" THEN files[t] ELSE {}
GitBackup(t) ==
    /\ backup' = [backup EXCEPT ![t] = @ \cup brUnits[t] \cup reflog[t]
                                        \cup Here(t, dirty) \cup Here(t, ignored)]
    /\ UNCHANGED <<main, wt, dirty, ignored, br, brUnits, reflog, tipOnMain, owned, made, discarded, next, removedOther>>

\* You choose to throw the task's work away: what it made, not what was on
\* its branch before.
GitDiscard(t) ==
    /\ discarded' = discarded \cup Here(t, dirty) \cup Here(t, ignored) \cup reflog[t]
                              \cup (brUnits[t] \ {Pre(t)})
    /\ UNCHANGED <<main, wt, dirty, ignored, br, brUnits, reflog, tipOnMain, owned, backup, made, next, removedOther>>

-----------------------------------------------------------------------------
(* What a tool reads of Git.                                               *)

\* The task's work is on main by content, as a squash or rebase leaves it.
\* Code finds this with `git merge-tree`, patch IDs or the forge's word on
\* the pull request, never with ancestry alone.
Landed(t) == brUnits[t] \subseteq main

\* What `git branch --merged` and `git branch -d` go by.
Merged(t) == tipOnMain[t]

Held == main \cup UNION {brUnits[t] : t \in {s \in Tasks : br[s]}}
             \cup UNION {Here(t, dirty) \cup Here(t, ignored) : t \in Tasks}
             \cup UNION {reflog[t] : t \in {s \in Tasks : br[s] \/ wt[s] = "there"}}
             \cup UNION {backup[t] : t \in Tasks}

-----------------------------------------------------------------------------
(* Git alone, with no tool: anyone may run any command Git allows without  *)
(* a force, and nothing more.  GitWork.git-alone.cfg shows that its own    *)
(* guards, `worktree remove` without --force and `branch -d`, don't keep   *)
(* NoLoss: they pass over ignored files and commits only a reflog names.  *)

GitNext == \E t \in Tasks :
    \/ GitWrite(t) \/ GitWriteIgnored(t) \/ GitCommit(t) \/ GitReset(t)
    \/ GitMerge(t) \/ GitSquash(t)
    \/ GitCanRemoveWorktree(t, FALSE) /\ GitRemoveWorktree(t)
    \/ GitCanDeleteBranch(t, FALSE, FALSE, {}) /\ GitDeleteBranch(t)

GitSpec == GitInit /\ [][GitNext]_gitVars

-----------------------------------------------------------------------------
(* The rules.                                                              *)

\* P1, P2: no work is lost, committed or not, ignored or only in a reflog,
\* unless you threw it away.
NoLoss == (made \ discarded) \subseteq Held

\* P3: the tool deletes only what it made.
OnlyOwn == ~removedOther
=============================================================================
