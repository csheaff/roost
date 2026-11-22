------------------------- MODULE WorktreeMadeAhead -------------------------
(***************************************************************************)
(* The worktree Roost keeps made ahead for a repository's next task, as    *)
(* scripts/roost_remote.py tends and takes it: one repository, its marks   *)
(* and folders under the state directory's ready/, its one wish, and the   *)
(* two locks there.                                                        *)
(*                                                                         *)
(* A creation asked with `ready` takes one (`take_ready_for`,              *)
(* `take_ready`), and each creation, once it has replied, notes a wish     *)
(* (`want_ready`) that a run in the background carries out (`tend_wanted`, *)
(* `tend_one`).  A listing starts a run that removes what no task will     *)
(* take (`prune_ready_later`).  Any of them may die between two steps, as  *)
(* a reboot or a dropped connection kills it, someone may write in a       *)
(* folder Roost made ahead, Git may fail at any step it takes, and a week  *)
(* may pass.                                                               *)
(*                                                                         *)
(* docs/state-machines.md, "Worktree made ahead", has the machine this     *)
(* follows, with its invariants I1 to I5;                                  *)
(* .claude/skills/verify-worktree-made-ahead/SKILL.md says how to run it.  *)
(***************************************************************************)
EXTENDS Naturals, FiniteSets

CONSTANTS
    MaxCreations,   \* tasks asked for
    MaxMade,        \* worktrees made ahead, counting one there at the start
    MaxCrashes,     \* processes that may die between two steps
    MaxWrites,      \* files someone may write in a folder Roost made ahead
    MaxListings,    \* listings, each of which may start a run that prunes
    Weeks,          \* TRUE: a week may pass, once: what is there is old
    Break           \* "none", or a guard turned off, for a
                    \* WorktreeMadeAhead.<variant>.cfg: "take_unlocked",
                    \* "kept_stays_ready", "take_unchecked", "log_kept",
                    \* "hook_at_checkout", "branch_in_worktree",
                    \* "no_look_again", "wish_removed_blind",
                    \* "prune_ignores_wish", "take_unmarked",
                    \* "keeps_unready", "undo_no_taking"

Creations == 1..MaxCreations
Entries   == 1..MaxMade
\* The commit a task starts at: the repository's branch may move on between
\* two tasks, so a second starts where the first did or one commit on.
Commits   == 1..2
\* Run c follows creation c; the rest follow a listing each.
Runs      == 1..(MaxCreations + MaxListings)

VARIABLES
    wt,         \* each worktree made ahead, by the number it was made as:
                \*   mark: its mark ready/<name>.json: "none", "unready"
                \*     (`ready: false`) or "ready";
                \*   markAt: the commit its mark names;
                \*   place: its folder: "none", "ahead" (under ready/),
                \*     "task" (at the path of the task of `owner`), "trash";
                \*   at, onBranch: the commit it has checked out, detached,
                \*     or on its task's branch;
                \*   past: its HEAD's reflog names where it was ahead;
                \*   stray: it holds a file someone wrote there;
                \*   taking: Git's lock on it, with TAKING as its reason;
                \*   hook: `post-checkout` in it for its task: "no", "new"
                \*     (run with no old commit, as for a new worktree) or
                \*     "switch" (run by a checkout, from where it was).
    old,        \* those made over READY_DAYS ago
    wish,       \* ready/<repo>.want: its commit, whether to keep one, and
                \* the `at` that tells two wishes apart; or NoWish
    readyLock,  \* 0, or the creation holding ready/.lock.  A run holds it
                \* only within a step, which waits for it to be free.
    tending,    \* 0, or the run holding ready/.tending
    cr,         \* the creations: where each is (pc), the commit it starts
                \* at, whether it was asked with `ready`, the worktree it
                \* took (e), and where its branch was made
    run,        \* the runs: where each is (pc), the wish it read, the one
                \* it keeps or makes (kept), those it removes (going), and
                \* covers, a ghost: its sweep began after all that was left
    \* Counters and ghosts.
    made, wishes, crashes, writes, listings, aged,
    last,       \* the last wish noted
    orphaned,   \* a run was killed, so its wish may wait for the next
    stale       \* something may be left that no sweep begun since has cleared

vars == <<wt, old, wish, readyLock, tending, cr, run, made, wishes, crashes, writes, listings, aged,
          last, orphaned, stale>>

None   == [mark |-> "none", markAt |-> 0, place |-> "none", owner |-> 0, at |-> 0, onBranch |-> FALSE,
           past |-> FALSE, stray |-> FALSE, taking |-> FALSE, hook |-> "no"]
NoWish == [commit |-> 0, keep |-> FALSE, id |-> 0]

Min(S) == CHOOSE x \in S : \A y \in S : x <= y

Init ==
    /\ \/ wt = [e \in Entries |-> None] /\ made = 0 /\ last = NoWish
       \* Or one is there already, made for an earlier task's wish.
       \/ /\ wt = [e \in Entries |-> IF e = 1 THEN [None EXCEPT !.mark = "ready", !.markAt = 1, !.place = "ahead",
                                                               !.at = 1, !.past = TRUE]
                                              ELSE None]
          /\ made = 1 /\ last = [commit |-> 1, keep |-> TRUE, id |-> 0]
    /\ old = {} /\ wish = NoWish /\ readyLock = 0 /\ tending = 0
    /\ cr = [c \in Creations |-> [pc |-> "none", start |-> 0, ready |-> FALSE, e |-> 0, branch |-> "none"]]
    /\ run = [r \in Runs |-> [pc |-> "none", read |-> NoWish, kept |-> 0, going |-> {}, covers |-> FALSE]]
    /\ wishes = 0 /\ crashes = 0 /\ writes = 0 /\ listings = 0 /\ aged = FALSE
    /\ orphaned = FALSE /\ stale = FALSE

-----------------------------------------------------------------------------
(* What is read of ready/.                                                  *)

Marked == {e \in Entries : wt[e].mark # "none"}

\* `unwanted_ready`: not ready, as one a run cut short left, or taken and
\* not moved; or made over READY_DAYS ago.  (Its repository gone reads the
\* same, and is left out.)
Unwanted(e) == wt[e].mark # "ready" \/ e \in old

\* `drop_ready`: its folder, if it is still under ready/, removed, with
\* Git's record of it; then its mark.  One a take moved stays where it is.
Dropped(w) == IF w.place = "ahead" THEN None ELSE [w EXCEPT !.mark = "none", !.markAt = 0]

\* Something was left that only a sweep clears: none begun before it counts.
Left(runs) == [r \in Runs |-> [runs[r] EXCEPT !.covers = FALSE]]

\* The steps of a take, from the moment `take_ready` has chosen one.
Taking(c)   == cr[c].pc \in {"move", "unmark", "taking", "check", "checkout", "log", "unlock", "hook"}
Holds(c, e) == Taking(c) /\ cr[c].e = e
\* A run is at one from its sweep until it has removed it or marked it ready.
AtIt(r, e)  == run[r].pc \in {"drop", "pdrop", "tend", "add", "ready"} /\ (run[r].kept = e \/ e \in run[r].going)

-----------------------------------------------------------------------------
(* A creation, `make_task`.  Asked with `ready`, it takes a worktree made   *)
(* ahead if it can; else, and in every other case, Git makes its worktree, *)
(* in the request or in the task's terminal, which is not this model's.    *)

Ask(c) ==
    /\ cr[c].pc = "none" /\ \A d \in 1..(c - 1) : cr[d].pc # "none"
    /\ \E k \in (IF c = 1 THEN {1} ELSE Commits), wants \in BOOLEAN :
         cr' = [cr EXCEPT ![c].pc = IF wants THEN "take" ELSE "git", ![c].start = k, ![c].ready = wants]
    /\ UNCHANGED <<wt, old, wish, readyLock, tending, run, made, wishes, crashes, writes, listings, aged,
                   last, orphaned, stale>>

Creation(c, A) ==
    /\ A
    /\ UNCHANGED <<old, wish, tending, made, wishes, crashes, writes, listings, aged, last, orphaned>>

\* `take_ready_for`: with no mark of its repository's, nothing to take.
\* Else its branch is made in the primary checkout, where `git worktree
\* add` makes it, with its reference-transaction hooks.  Broken:
\* `branch_in_worktree` leaves it to the checkout, as `git checkout -b`
\* in the worktree taken.
TakeBegins(c) == cr[c].pc = "take" /\ Creation(c,
    /\ cr' = [cr EXCEPT ![c].pc = IF Marked = {} THEN "git" ELSE "lock",
                        ![c].branch = IF Marked = {} \/ Break = "branch_in_worktree" THEN @ ELSE "primary"]
    /\ UNCHANGED <<wt, readyLock, run, stale>>)

\* `take_ready`, under ready/.lock: the first that says ready is marked not
\* ready, before Git moves it, whatever happens then.  Broken:
\* `take_unlocked` takes it on what its mark said, with no lock and no
\* mark; `take_unmarked` holds the lock, and leaves the mark as it was.
TakeMarks(c) == cr[c].pc = "lock" /\ (Break = "take_unlocked" \/ readyLock = 0) /\ Creation(c,
    LET ready == {e \in Entries : wt[e].mark = "ready"} IN
    /\ IF ready = {}
       \* None is ready: its branch deleted, and Git makes its worktree.
       THEN /\ cr' = [cr EXCEPT ![c].pc = "git", ![c].branch = "none"]
            /\ UNCHANGED <<wt, readyLock>>
       ELSE /\ cr' = [cr EXCEPT ![c].pc = "move", ![c].e = Min(ready)]
            /\ wt' = [wt EXCEPT ![Min(ready)].mark = IF Break \in {"take_unlocked", "take_unmarked"} THEN @
                                                    ELSE "unready"]
            /\ readyLock' = IF Break = "take_unlocked" THEN readyLock ELSE c
    /\ UNCHANGED <<run, stale>>)

\* `git worktree move`, which renames its folder to the task's path.  Git
\* may refuse, as to another file system, and does once its folder has
\* gone: left, its mark says not ready, and the next run clears it.
TakeMoves(c) == cr[c].pc = "move" /\ Creation(c,
    LET e == cr[c].e IN
    \/ /\ wt[e].place = "ahead"
       /\ wt' = [wt EXCEPT ![e].place = "task", ![e].owner = c]
       /\ cr' = [cr EXCEPT ![c].pc = "unmark"]
       /\ UNCHANGED <<readyLock, run, stale>>
    \/ /\ cr' = [cr EXCEPT ![c].pc = "git", ![c].e = 0, ![c].branch = "none"]
       /\ readyLock' = IF readyLock = c THEN 0 ELSE readyLock
       /\ run' = Left(run) /\ stale' = TRUE
       /\ UNCHANGED wt)

\* Its mark goes, and ready/.lock is let go.
TakeUnmarks(c) == cr[c].pc = "unmark" /\ Creation(c,
    /\ wt' = [wt EXCEPT ![cr[c].e].mark = "none", ![cr[c].e].markAt = 0]
    /\ readyLock' = IF readyLock = c THEN 0 ELSE readyLock
    /\ cr' = [cr EXCEPT ![c].pc = "taking"]
    /\ UNCHANGED <<run, stale>>)

\* `git worktree lock --reason TAKING`: locked until its checkout is done.
TakeLocks(c) == cr[c].pc = "taking" /\ Creation(c,
    /\ wt' = [wt EXCEPT ![cr[c].e].taking = TRUE]
    /\ cr' = [cr EXCEPT ![c].pc = "check"]
    /\ UNCHANGED <<readyLock, run, stale>>)

\* What a take sets aside: unlocked and moved into the trash, as nobody's,
\* its branch deleted; Git then makes the task's worktree.
SetAside(c) ==
    /\ wt' = [wt EXCEPT ![cr[c].e].place = "trash", ![cr[c].e].owner = 0, ![cr[c].e].taking = FALSE]
    /\ cr' = [cr EXCEPT ![c].pc = "git", ![c].e = 0, ![c].branch = "none"]

\* `changed_in`: nothing there but Git's checkout, ignored files too, as
\* written by nobody since it was made.  Broken: `take_unchecked` takes it
\* whatever it holds.
TakeChecks(c) == cr[c].pc = "check" /\ Creation(c,
    /\ IF wt[cr[c].e].stray /\ Break # "take_unchecked"
       THEN SetAside(c)
       ELSE cr' = [cr EXCEPT ![c].pc = "checkout"] /\ UNCHANGED wt
    /\ UNCHANGED <<readyLock, run, stale>>)

\* Its branch checked out with no hook (`core.hooksPath`), so that none
\* writes there before HEAD is the task's; or Git can't, and it is set
\* aside.  Broken: `hook_at_checkout` lets the checkout run `post-checkout`,
\* from the commit it was at; `branch_in_worktree` makes the branch here.
TakeChecksOut(c) == cr[c].pc = "checkout" /\ Creation(c,
    /\ \/ /\ wt' = [wt EXCEPT ![cr[c].e].onBranch = TRUE, ![cr[c].e].at = cr[c].start,
                              ![cr[c].e].hook = IF Break = "hook_at_checkout" THEN "switch" ELSE @]
          /\ cr' = [cr EXCEPT ![c].pc = "log", ![c].branch = IF @ = "none" THEN "worktree" ELSE @]
       \/ SetAside(c)
    /\ UNCHANGED <<readyLock, run, stale>>)

\* `begin_head_log`: its HEAD's reflog begun as a new worktree's is, from
\* no commit.  Broken: `log_kept` leaves the commits it was moved through.
TakeBeginsLog(c) == cr[c].pc = "log" /\ Creation(c,
    /\ wt' = [wt EXCEPT ![cr[c].e].past = IF Break = "log_kept" THEN @ ELSE FALSE]
    /\ cr' = [cr EXCEPT ![c].pc = "unlock"]
    /\ UNCHANGED <<readyLock, run, stale>>)

TakeUnlocks(c) == cr[c].pc = "unlock" /\ Creation(c,
    /\ wt' = [wt EXCEPT ![cr[c].e].taking = FALSE]
    /\ cr' = [cr EXCEPT ![c].pc = "hook"]
    /\ UNCHANGED <<readyLock, run, stale>>)

\* `git hook run post-checkout`, with no old commit, as for a new worktree:
\* what it writes is the task's.  Failing, it fails the creation as for
\* `git worktree add`, and `abandon` removes a worktree that holds nothing.
TakeHooks(c) == cr[c].pc = "hook" /\ Creation(c,
    /\ \/ /\ wt' = [wt EXCEPT ![cr[c].e].hook = IF @ = "no" THEN "new" ELSE @]
          /\ cr' = [cr EXCEPT ![c].pc = "made"]
       \/ /\ wt' = IF wt[cr[c].e].stray THEN wt ELSE [wt EXCEPT ![cr[c].e] = None]
          /\ cr' = [cr EXCEPT ![c].pc = "failed", ![c].e = 0,
                              ![c].branch = IF wt[cr[c].e].stray THEN @ ELSE "none"]
    /\ UNCHANGED <<readyLock, run, stale>>)

\* `git worktree add -b`, or the task's runner in its terminal.
GitMakes(c) == cr[c].pc = "git" /\ Creation(c,
    /\ cr' = [cr EXCEPT ![c].pc = "made", ![c].branch = "primary"]
    /\ UNCHANGED <<wt, readyLock, run, stale>>)

\* The creation has replied.  `tend_ready_later`: its repository's wish
\* noted (`want_ready`, under ready/.lock), to keep one at the task's start
\* if it was asked with `ready`, else none; then a run in the background,
\* once the task is past its checkout and setup, which is any time.  With
\* nothing to turn off, as none was ever made or wished for, nothing.
Replies(c) ==
    /\ cr[c].pc = "made" /\ readyLock = 0
    /\ cr' = [cr EXCEPT ![c].pc = "replied"]
    /\ IF ~cr[c].ready /\ made = 0 /\ wishes = 0
       THEN UNCHANGED <<wish, wishes, last, run>>
       ELSE /\ wishes' = wishes + 1
            /\ wish' = [commit |-> cr[c].start, keep |-> cr[c].ready, id |-> wishes + 1]
            /\ last' = wish'
            /\ run' = [run EXCEPT ![c].pc = "try"]
    /\ UNCHANGED <<wt, old, readyLock, tending, made, crashes, writes, listings, aged, orphaned, stale>>

-----------------------------------------------------------------------------
(* A run tending them, `tend_wanted`, in a process of its own.             *)

Run(r, A) ==
    /\ A
    /\ UNCHANGED <<readyLock, cr, wishes, crashes, writes, listings, aged, last, orphaned>>

\* One run at a time, by ready/.tending.  With another at it, this one
\* ends: that one carries the wish out.
RunTries(r) == run[r].pc \in {"try", "ptry"} /\ Run(r,
    /\ IF tending = 0
       THEN /\ tending' = r
            /\ run' = [run EXCEPT ![r].pc = IF @ = "try" THEN "read" ELSE "psweep"]
       ELSE run' = [run EXCEPT ![r].pc = "done"] /\ UNCHANGED tending
    /\ UNCHANGED <<wt, old, wish, made, stale>>)

\* It reads the wish, and with none left, goes on to let go.
RunReads(r) == run[r].pc = "read" /\ Run(r,
    /\ run' = [run EXCEPT ![r].pc = IF wish = NoWish THEN "let go" ELSE "sweep", ![r].read = wish]
    /\ UNCHANGED <<wt, old, wish, tending, made, stale>>)

\* It lets go of ready/.tending, a moment after it read that no wish was
\* left: a run that wished in that moment found this one at work, and
\* ended.  So it looks once more, and a wish no other run took up is its to
\* carry out.  Broken: `no_look_again` ends there.
RunLetsGo(r) == run[r].pc = "let go" /\ Run(r,
    /\ tending' = 0
    /\ run' = [run EXCEPT ![r].pc = IF Break = "no_look_again" THEN "done" ELSE "look"]
    /\ UNCHANGED <<wt, old, wish, made, stale>>)

RunLooks(r) == run[r].pc = "look" /\ Run(r,
    /\ run' = [run EXCEPT ![r].pc = IF wish = NoWish THEN "done" ELSE "try"]
    /\ UNCHANGED <<wt, old, wish, tending, made, stale>>)

\* `sweep_ready` for the wish's repository, under ready/.lock: one that is
\* wanted stays, if the wish is to keep one, marked not ready while the run
\* moves it; every other goes, marked not ready.  A folder with no mark
\* goes too.  Broken: `kept_stays_ready` leaves the one it keeps ready;
\* `keeps_unready` keeps the first whatever its mark says.
RunSweeps(r) == run[r].pc = "sweep" /\ readyLock = 0 /\ Run(r,
    LET keepable == IF Break = "keeps_unready" THEN Marked ELSE {e \in Marked : ~Unwanted(e)}
        kept     == IF run[r].read.keep /\ keepable # {} THEN Min(keepable) ELSE 0
    IN /\ wt' = [e \in Entries |->
                   IF e \notin Marked THEN (IF wt[e].place = "ahead" THEN None ELSE wt[e])
                   ELSE IF e = kept /\ Break = "kept_stays_ready" THEN wt[e]
                   ELSE [wt[e] EXCEPT !.mark = "unready"]]
       /\ run' = [run EXCEPT ![r].pc = "drop", ![r].kept = kept, ![r].going = Marked \ {kept}, ![r].covers = TRUE]
       /\ UNCHANGED <<old, wish, tending, made, stale>>)

\* A listing's run: `sweep_ready` with no repository, so only what
\* `unwanted_ready` says goes.
PruneSweeps(r) == run[r].pc = "psweep" /\ readyLock = 0 /\ Run(r,
    LET going == {e \in Marked : Unwanted(e)} IN
    /\ wt' = [e \in Entries |->
                IF e \in going THEN [wt[e] EXCEPT !.mark = "unready"]
                ELSE IF e \notin Marked /\ wt[e].place = "ahead" THEN None ELSE wt[e]]
    /\ run' = [run EXCEPT ![r].pc = "pdrop", ![r].going = going, ![r].covers = TRUE]
    /\ UNCHANGED <<old, wish, tending, made, stale>>)

\* `drop_ready` of each that goes.  All that was left when the sweep began
\* has then gone.  A listing's run lets go of ready/.tending here.
RunDrops(r) == run[r].pc \in {"drop", "pdrop"} /\ Run(r,
    /\ wt' = [e \in Entries |-> IF e \in run[r].going THEN Dropped(wt[e]) ELSE wt[e]]
    /\ old' = old \ run[r].going
    /\ stale' = IF run[r].covers THEN FALSE ELSE stale
    /\ run' = [run EXCEPT ![r].going = {},
                          ![r].pc = IF @ = "pdrop" THEN "plook" ELSE IF run[r].read.keep THEN "tend" ELSE "unwish"]
    /\ tending' = IF run[r].pc = "pdrop" THEN 0 ELSE tending
    /\ UNCHANGED <<wish, made>>)

\* A wish made meanwhile, whose run found the listing's at work and left
\* it: `tend_wanted`.  Broken: `prune_ignores_wish` ends there.
PruneLooks(r) == run[r].pc = "plook" /\ Run(r,
    /\ run' = [run EXCEPT ![r].pc = IF wish # NoWish /\ Break # "prune_ignores_wish" THEN "try" ELSE "done"]
    /\ UNCHANGED <<wt, old, wish, tending, made, stale>>)

\* `tend_one`, with one kept: at the wish's commit it is ready as it is.
\* At another, `git checkout --detach` moves it there, and it is read
\* again (`changed_in`); Git failing, or anything else in it, it is
\* dropped, and one is made.
RunMoves(r) == run[r].pc = "tend" /\ run[r].kept # 0 /\ Run(r,
    LET e == run[r].kept IN
    /\ IF wt[e].markAt = run[r].read.commit
       THEN run' = [run EXCEPT ![r].pc = "ready"] /\ UNCHANGED <<wt, old>>
       ELSE \/ /\ wt[e].place = "ahead" /\ ~wt[e].stray
               /\ wt' = [wt EXCEPT ![e].at = run[r].read.commit]
               /\ run' = [run EXCEPT ![r].pc = "ready"]
               /\ UNCHANGED old
            \/ /\ wt' = [wt EXCEPT ![e] = Dropped(@)]
               /\ old' = old \ {e}
               /\ run' = [run EXCEPT ![r].kept = 0]
    /\ UNCHANGED <<wish, tending, made, stale>>)

\* With none kept: a new mark, not ready, before Git makes it.  Past the
\* model's bound, none is made, as when Git can't.
RunBegins(r) == run[r].pc = "tend" /\ run[r].kept = 0 /\ Run(r,
    /\ IF made < MaxMade
       THEN /\ made' = made + 1
            /\ wt' = [wt EXCEPT ![made + 1].mark = "unready", ![made + 1].markAt = run[r].read.commit]
            /\ run' = [run EXCEPT ![r].pc = "add", ![r].kept = made + 1]
       ELSE run' = [run EXCEPT ![r].pc = "unwish"] /\ UNCHANGED <<wt, made>>
    /\ UNCHANGED <<old, wish, tending, stale>>)

\* `git worktree add --detach`, then `changed_in`: Git failing, or its
\* `post-checkout` hook leaving files, it is dropped.
RunAdds(r) == run[r].pc = "add" /\ Run(r,
    LET e == run[r].kept IN
    /\ \/ /\ wt' = [wt EXCEPT ![e].place = "ahead", ![e].at = wt[e].markAt, ![e].past = TRUE]
          /\ run' = [run EXCEPT ![r].pc = "ready"]
       \/ /\ wt' = [wt EXCEPT ![e] = Dropped(@)]
          /\ run' = [run EXCEPT ![r].pc = "unwish", ![r].kept = 0]
    /\ UNCHANGED <<old, wish, tending, made, stale>>)

\* Its mark says ready, at the wish's commit.
RunMarksReady(r) == run[r].pc = "ready" /\ Run(r,
    /\ wt' = [wt EXCEPT ![run[r].kept].mark = "ready", ![run[r].kept].markAt = run[r].read.commit]
    /\ run' = [run EXCEPT ![r].pc = "unwish", ![r].kept = 0]
    /\ UNCHANGED <<old, wish, tending, made, stale>>)

\* The wish carried out is removed, under ready/.lock, unless wished again
\* meanwhile; then the wishes are read again.  Broken: `wish_removed_blind`
\* removes whatever wish is there.
RunUnwishes(r) == run[r].pc = "unwish" /\ readyLock = 0 /\ Run(r,
    /\ wish' = IF wish.id = run[r].read.id \/ Break = "wish_removed_blind" THEN NoWish ELSE wish
    /\ run' = [run EXCEPT ![r].pc = "read", ![r].read = NoWish]
    /\ UNCHANGED <<wt, old, tending, made, stale>>)

\* A listing has replied.  `prune_ready_later`: with one that goes, and
\* ready/.tending free, a run in the background.
Lists ==
    /\ listings < MaxListings /\ tending = 0
    /\ \E e \in Entries : (e \in Marked /\ Unwanted(e)) \/ (e \notin Marked /\ wt[e].place = "ahead")
    /\ listings' = listings + 1
    /\ run' = [run EXCEPT ![MaxCreations + listings + 1].pc = "ptry"]
    /\ UNCHANGED <<wt, old, wish, readyLock, tending, cr, made, wishes, crashes, writes, aged, last, orphaned, stale>>

-----------------------------------------------------------------------------
(* Outside Roost, and what kills it.                                        *)

\* Someone writes a file in a folder under ready/, which no one may.
SomeoneWrites(e) ==
    /\ writes < MaxWrites /\ wt[e].place = "ahead" /\ ~wt[e].stray
    /\ wt' = [wt EXCEPT ![e].stray = TRUE] /\ writes' = writes + 1
    /\ UNCHANGED <<old, wish, readyLock, tending, cr, run, made, wishes, crashes, listings, aged, last, orphaned,
                   stale>>

\* READY_DAYS pass: each one there was made that long ago.
WeekPasses ==
    /\ Weeks /\ ~aged /\ aged' = TRUE /\ old' = Marked
    /\ UNCHANGED <<wt, wish, readyLock, tending, cr, run, made, wishes, crashes, writes, listings, last, orphaned,
                   stale>>

\* A creation dies within its take: the kernel lets go of ready/.lock, and
\* its marks, folders, branch and Git's lock stay.
CreationDies(c) ==
    /\ crashes < MaxCrashes /\ (cr[c].pc = "lock" \/ Taking(c))
    /\ cr' = [cr EXCEPT ![c].pc = "dead"]
    /\ readyLock' = IF readyLock = c THEN 0 ELSE readyLock
    /\ crashes' = crashes + 1 /\ run' = Left(run) /\ stale' = TRUE
    /\ UNCHANGED <<wt, old, wish, tending, made, wishes, writes, listings, aged, last, orphaned>>

\* A run dies: ready/.tending is let go, and what it was at stays.
RunDies(r) ==
    /\ crashes < MaxCrashes /\ run[r].pc \notin {"none", "done", "dead"}
    /\ run' = [Left(run) EXCEPT ![r].pc = "dead"]
    /\ tending' = IF tending = r THEN 0 ELSE tending
    /\ crashes' = crashes + 1 /\ stale' = TRUE /\ orphaned' = TRUE
    /\ UNCHANGED <<wt, old, wish, readyLock, cr, made, wishes, writes, listings, aged, last>>

\* `settle_creation`, on a listing or when its draft asks again:
\* `undo_creation`.  A worktree locked as TAKING whose branch isn't checked
\* out holds only Git's checkout, and is forced away.  Any other is a
\* failed creation's (`abandon`): removed, unless something was written
\* there, when it stays as a task to look at.  Its branch goes with it.
\* Broken: `undo_no_taking` takes the locked one for a failed creation's
\* too, and Git removes no locked worktree unforced.
Settles(c) ==
    /\ cr[c].pc = "dead"
    /\ LET e      == cr[c].e
           there  == e # 0 /\ wt[e].place = "task" /\ wt[e].owner = c
           locked == there /\ wt[e].taking
           forced == locked /\ ~wt[e].onBranch /\ Break # "undo_no_taking"
           stays  == there /\ ~forced /\ (wt[e].stray \/ (locked /\ Break = "undo_no_taking"))
       IN /\ wt' = IF ~there THEN wt
                   ELSE IF stays THEN [wt EXCEPT ![e].taking = (locked /\ Break = "undo_no_taking")]
                   \* Its folder goes; a mark a take died before removing stays, for a sweep.
                   ELSE [wt EXCEPT ![e] = [None EXCEPT !.mark = wt[e].mark, !.markAt = wt[e].markAt]]
          /\ cr' = [cr EXCEPT ![c].pc = IF stays THEN "kept" ELSE "settled",
                              ![c].branch = IF stays THEN @ ELSE "none"]
    /\ UNCHANGED <<old, wish, readyLock, tending, run, made, wishes, crashes, writes, listings, aged, last,
                   orphaned, stale>>

\* Nothing is under way: every creation has replied, failed or been
\* settled, and every run has ended.
Quiet == /\ \A c \in Creations : cr[c].pc \in {"none", "replied", "failed", "settled", "kept"}
         /\ \A r \in Runs : run[r].pc \in {"none", "done", "dead"}

Next ==
    \/ \E c \in Creations :
         \/ Ask(c) \/ TakeBegins(c) \/ TakeMarks(c) \/ TakeMoves(c) \/ TakeUnmarks(c) \/ TakeLocks(c)
         \/ TakeChecks(c) \/ TakeChecksOut(c) \/ TakeBeginsLog(c) \/ TakeUnlocks(c) \/ TakeHooks(c)
         \/ GitMakes(c) \/ Replies(c) \/ CreationDies(c) \/ Settles(c)
    \/ \E r \in Runs :
         \/ RunTries(r) \/ RunReads(r) \/ RunLetsGo(r) \/ RunLooks(r) \/ RunSweeps(r) \/ PruneSweeps(r) \/ RunDrops(r)
         \/ PruneLooks(r) \/ RunMoves(r) \/ RunBegins(r) \/ RunAdds(r) \/ RunMarksReady(r) \/ RunUnwishes(r)
         \/ RunDies(r)
    \/ Lists \/ WeekPasses
    \/ \E e \in Entries : SomeoneWrites(e)
    \/ Quiet /\ UNCHANGED vars

Spec == Init /\ [][Next]_vars

-----------------------------------------------------------------------------
(* The rules, numbered as the section's invariants.                         *)

\* I1.  A worktree made ahead is one request's at a time: no two creations
\* take it, and none takes one a run is moving to another commit or
\* removing.
TakenOnce ==
    \A e \in Entries :
        /\ Cardinality({c \in Creations : Holds(c, e)}) <= 1
        /\ \A c \in Creations, r \in Runs : ~(Holds(c, e) /\ AtIt(r, e))

\* I2.  A task takes only one holding nothing but Git's checkout: from the
\* moment its branch is checked out there, no file someone wrote in it.
TakenClean ==
    \A c \in Creations :
        cr[c].e # 0 /\ cr[c].pc \in {"log", "unlock", "hook", "made", "replied"} => ~wt[cr[c].e].stray

\* I3.  A task taken from one starts as `git worktree add` would make it:
\* at the task's path, on its branch, made in the primary checkout, at its
\* start, its HEAD's reflog begun anew, unlocked, and `post-checkout` run
\* once as for a new worktree.
StartsAsAdded ==
    \A c \in Creations :
        cr[c].e # 0 /\ cr[c].pc \in {"made", "replied"} =>
            LET w == wt[cr[c].e] IN
            /\ w.place = "task" /\ w.owner = c /\ w.onBranch /\ w.at = cr[c].start
            /\ ~w.past /\ ~w.taking /\ w.hook = "new" /\ w.mark = "none"
            /\ cr[c].branch = "primary"

\* I4.  No wish is lost: once nothing is under way, and no run was killed,
\* no wish waits, and what is there is what the last wish asked for: none,
\* or none but at its commit.
NoWishLost ==
    Quiet /\ ~orphaned =>
        /\ wish = NoWish
        /\ \A e \in Entries : wt[e].mark = "ready" => last.keep /\ wt[e].markAt = last.commit

\* I5.  What a crash leaves goes on the next run, or after the next
\* listing, and all of it when turned off: once nothing is under way and a
\* sweep begun since has ended, every mark says ready, of a worktree that
\* is there to take, one at most, and none at all once a wish to keep none
\* was carried out.  And a creation cut short, once settled, leaves its
\* worktree only if something was written there, and never its branch.
Leftover(e) ==
    \/ wt[e].mark = "unready"
    \/ wt[e].mark = "ready" /\ wt[e].place # "ahead"
    \/ wt[e].mark = "none" /\ wt[e].place = "ahead"
NothingLeft ==
    /\ Quiet /\ ~stale =>
         /\ \A e \in Entries : ~Leftover(e)
         /\ Cardinality({e \in Entries : wt[e].mark = "ready"}) <= 1
         /\ wish = NoWish /\ ~last.keep => \A e \in Entries : wt[e].mark = "none" /\ wt[e].place # "ahead"
    /\ \A c \in Creations :
         /\ cr[c].pc = "settled" => cr[c].branch = "none" /\ \A e \in Entries : wt[e].owner # c
         /\ cr[c].pc = "kept" => wt[cr[c].e].stray

\* The table's Ready: what a mark calls ready is there under ready/,
\* detached at the mark's commit, unlocked, with no take and no run at it.
ReadyIsThere ==
    \A e \in Entries :
        wt[e].mark = "ready" =>
            /\ wt[e].place = "ahead" /\ wt[e].at = wt[e].markAt /\ ~wt[e].onBranch /\ ~wt[e].taking
            /\ \A c \in Creations : ~Holds(c, e)
            /\ \A r \in Runs : ~AtIt(r, e)
=============================================================================
