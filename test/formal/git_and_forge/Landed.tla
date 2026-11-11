---------------------------- MODULE Landed ----------------------------
(***************************************************************************)
(* What the host helper records of a task's pull request, and when it says *)
(* the task's work is merged ("landed"), so that retiring it may delete    *)
(* its branch.  scripts/roost_remote.py: has_tip, recorded_merge_at,       *)
(* started_at, landed, task_pull_requests, shown_pull_request,             *)
(* head_to_fetch, fetch_heads, check_pull_requests, push_pull_request,     *)
(* record_push, pull_request, retarget, merged_pull_request_head,          *)
(* safe_to_delete and rpc's `pr`, `list` and `retire` branches.  One task, *)
(* one branch.                                                             *)
(*                                                                         *)
(* Commits are numbers: 0 is where the task's branch was made (startCommit *)
(* always, and baseCommit until B moves it), each new one has a parent.    *)
(* Git on the host knows `local`; the forge knows every commit, as one     *)
(* made there isn't here until fetched.                                    *)
(*                                                                         *)
(* The world moves at any time: the agent commits, rewrites its last       *)
(* commit, pushes (with force, as an agent may), pulls the forge's branch, *)
(* and opens pull requests, and resets its branch where a config has it;   *)
(* the forge takes commits, merges, closes and reopens; you merge the task *)
(* into a branch by hand, or pull a merge into one, and change the branch  *)
(* the task merges into with B.  Meanwhile one                             *)
(* poll (check_pull_requests, then the measurement), one `P` (push to the  *)
(* recorded pull request, or open one) and one `x` (retire) run on the     *)
(* host, step by step as the code takes the lock.                          *)
(*                                                                         *)
(* A pull request merges into the base it names, which need not be the     *)
(* branch the task merges into: an agent's own may name another, and B     *)
(* leaves an open one as it is.  So "landed" is of that branch as the      *)
(* record names it now, or of a merge on the forge, wherever that went.    *)
(*                                                                         *)
(* Other tasks need no steps of their own.  An attempt at the same prompt  *)
(* that merges brings the branch commits this task's branch doesn't have,  *)
(* which nothing here reads.  A fork of this task that merges brings those *)
(* of this task's it started from: as HandMerge does, before this task's   *)
(* later commits.  Each task's pull requests are listed by its own         *)
(* branch's name, which no other task has.                                 *)
(***************************************************************************)
EXTENDS Integers, FiniteSets

CONSTANTS
  MaxCommits,       \* commits made anywhere, here or on the forge
  NPR,              \* pull requests that can be opened
  MaxRetargets,     \* times B names a branch for the task to merge into
  Pushes,           \* P is pressed: rpc's `pr`, in its steps
  Retires,          \* x is pressed: rpc's `retire`, in its steps
  Resets,           \* the branch is reset to an earlier commit
  HasTipReversed,   \* broken: has_tip asks whether the head is in the tip
  PushMovesMerged,  \* broken: record_push moves a closed or merged one's head
  MeasureAtAskedTip,\* broken: landed() of a task asked about takes the tip
                    \* check_pull_requests read, not branch_tip again
  BaseOntoTip,      \* broken: retarget moves baseCommit onto the branch's tip
                    \* when what it names has all of the task's commits
  StartedAtBase,    \* broken: started_at gives baseCommit, which B moves, so
                    \* landed and safe_to_delete take a task at the commit
                    \* its commits count from for one that never committed
  RetireReadsOnce   \* broken: retire goes by the record rpc read before
                    \* merged_pull_request_head asked the forge

None == -1
Commits == 0..MaxCommits
PRs == 1..NPR
\* The branches a task can merge into: the one it started from, and another.
Bs == IF MaxRetargets = 0 THEN {1} ELSE {1, 2}
Max(S) == CHOOSE x \in S : \A y \in S : x >= y

\* A record's `pr`, as recorded_pull_request reads it.  num 0 is {}.
\* state "fresh" is a record with no state: just opened by P, or older.
\* `unfetched` is left out: here every poll may try a head again, and any
\* fetch may fail, which covers the code's trying once.
NoRec == [num |-> 0, state |-> "fresh", head |-> None, mergedHead |-> None]
Recs == [num : 0..NPR, state : {"fresh", "OPEN", "CLOSED", "MERGED"},
         head : Commits \cup {None}, mergedHead : Commits \cup {None}]
NoPR == [state |-> "none", head |-> None]

VARIABLES
  made, parent,      \* commits so far, and each one's parent
  tip,               \* the task's branch, here
  local,             \* commits Git has here
  remote,            \* the branch on the forge, None before a push
  pushedEver,        \* pushed(task): branch.X.remote or origin/X exists
  integ,             \* commits in each branch a task can merge into, here
  mainMoves,         \* you merged into one by hand, or pulled it (bounded)
  fpr,               \* the forge's pull requests: state and head
  reopened,          \* a closed one was reopened (bounded)
  rec,               \* the record's `pr`
  target, base,      \* the record's integrationBranch and baseCommit
  retargets,         \* times B changed them (bounded)
  poll, snap, starget, sbase, ptip, ans, ours, taskPr,  \* one poll's progress
  push, pbefore, phead, pnum,                        \* one `P`'s progress
  xs, xtarget, xbase, xmh,                           \* one `x`'s progress
  badReply,          \* a measurement said landed of work that wasn't
  lostByRetire,      \* x deleted a branch whose commits are nowhere else
  retiredUnlanded    \* x deleted work that hadn't landed

world == <<made, parent, tip, local, remote, pushedEver, integ, mainMoves, fpr, reopened>>
recv == <<rec, target, base, retargets>>
pollv == <<poll, snap, starget, sbase, ptip, ans, ours, taskPr>>
pushv == <<push, pbefore, phead, pnum>>
xv == <<xs, xtarget, xbase, xmh>>
hist == <<badReply, lostByRetire, retiredUnlanded>>
vars == <<world, recv, pollv, pushv, xv, hist>>

----------------------------------------------------------------------------
(* Git's ancestry, in the whole graph. *)
RECURSIVE IsAnc(_, _)
IsAnc(a, b) == IF a = b THEN TRUE ELSE IF b = 0 THEN FALSE ELSE IsAnc(a, parent[b])
Anc(c) == {a \in 0..made : IsAnc(a, c)}

(* What is true: the tip's work reached a branch.  A pull request the forge
   merged has it, in the base it named; or the branch the task merges into
   has it, here. *)
MergedHeads == {fpr[i].head : i \in {j \in PRs : fpr[j].state = "MERGED"}}
OnForge(t) == \E h \in MergedHeads : IsAnc(t, h)
TrulyIn(t, b) == t # 0 /\ (t \in integ[b] \/ OnForge(t))
Truly(t) == TrulyIn(t, target)

(* has_tip: HEAD, a pull request's, has all of TIP.  is_ancestor needs both
   here, among HAVE: False for a head not fetched. *)
HasTipIn(h, t, have) == h = t \/ (h # None /\ h \in have /\
                                  IF HasTipReversed THEN IsAnc(h, t) ELSE IsAnc(t, h))
HasTip(h, t) == HasTipIn(h, t, local)
RecordedMergeAt(r, t) ==
  r.num # 0 /\ (HasTip(r.mergedHead, t) \/ (r.state = "MERGED" /\ HasTip(r.head, t)))
(* started_at: the commit the task's branch was made at, which a task that
   never committed is still at.  It is the record's startCommit, which
   make_task sets and nothing moves, B least of all: commit 0, whenever the
   record is read.  An older helper's record has none, and its baseCommit
   stands for it, which retarget writes down as startCommit before it moves
   that.  Broken, it is FROM, the baseCommit a request read, where the
   task's commits count from. *)
StartedAt(from) == IF StartedAtBase THEN from ELSE 0
(* landed(task, tip), of a task whose record names the branch B and counts
   its commits from FROM; committed_on is taken as so. *)
HostLanded(r, b, from, t) == t # StartedAt(from) /\ (RecordedMergeAt(r, t) \/ t \in integ[b])

FollowRemote(f, c) == [i \in PRs |-> IF f[i].state = "OPEN" THEN [f[i] EXCEPT !.head = c] ELSE f[i]]
NoOpen == \A i \in PRs : fpr[i].state # "OPEN"
NextPR == IF \E i \in PRs : fpr[i].state = "none"
          THEN Max({0} \cup {i \in PRs : fpr[i].state # "none"}) + 1 ELSE 0

----------------------------------------------------------------------------
(* The world: the agent, you, and the forge. *)
CanMake == made < MaxCommits
New == made + 1

Commit ==
  /\ CanMake
  /\ made' = New /\ parent' = [parent EXCEPT ![New] = tip]
  /\ tip' = New /\ local' = local \cup {New}
  /\ UNCHANGED <<remote, pushedEver, integ, mainMoves, fpr, reopened, recv, pollv, pushv, xv, hist>>

\* git commit --amend, or a rebase: the tip's parent gets a new child.
Rewrite ==
  /\ CanMake /\ tip # 0
  /\ made' = New /\ parent' = [parent EXCEPT ![New] = parent[tip]]
  /\ tip' = New /\ local' = local \cup {New}
  /\ UNCHANGED <<remote, pushedEver, integ, mainMoves, fpr, reopened, recv, pollv, pushv, xv, hist>>

\* git reset --hard, to the commit before: the tip's commit stays in Git,
\* on no branch here.
Reset ==
  /\ Resets /\ tip # 0
  /\ tip' = parent[tip]
  /\ UNCHANGED <<made, parent, local, remote, pushedEver, integ, mainMoves, fpr, reopened, recv, pollv, pushv, xv, hist>>

\* The agent's git push, forced or not; an open pull request follows.
AgentPush ==
  /\ remote # tip
  /\ remote' = tip /\ pushedEver' = TRUE /\ fpr' = FollowRemote(fpr, tip)
  /\ UNCHANGED <<made, parent, tip, local, integ, mainMoves, reopened, recv, pollv, pushv, xv, hist>>

\* git pull, fast-forward, of the forge's branch: commits made there come.
AgentPull ==
  /\ remote \notin {None, tip} /\ IsAnc(tip, remote)
  /\ local' = local \cup Anc(remote) /\ tip' = remote
  /\ UNCHANGED <<made, parent, remote, pushedEver, integ, mainMoves, fpr, reopened, recv, pollv, pushv, xv, hist>>

\* The agent opens one with gh, outside Roost.
AgentOpens ==
  /\ NextPR # 0 /\ NoOpen /\ remote \notin {None, 0}
  /\ fpr' = [fpr EXCEPT ![NextPR] = [state |-> "OPEN", head |-> remote]]
  /\ UNCHANGED <<made, parent, tip, local, remote, pushedEver, integ, mainMoves, reopened, recv, pollv, pushv, xv, hist>>

\* A commit made on the forge, as a suggestion accepted there.
ForgeCommit ==
  /\ CanMake /\ remote # None
  /\ made' = New /\ parent' = [parent EXCEPT ![New] = remote]
  /\ remote' = New /\ fpr' = FollowRemote(fpr, New)
  /\ UNCHANGED <<tip, local, pushedEver, integ, mainMoves, reopened, recv, pollv, pushv, xv, hist>>

\* Merged on the forge, as a merge, a squash or a rebase: its head is in.
ForgeMerge(i) ==
  /\ fpr[i].state = "OPEN"
  /\ fpr' = [fpr EXCEPT ![i].state = "MERGED"]
  /\ UNCHANGED <<made, parent, tip, local, remote, pushedEver, integ, mainMoves, reopened, recv, pollv, pushv, xv, hist>>

ForgeClose(i) ==
  /\ fpr[i].state = "OPEN"
  /\ fpr' = [fpr EXCEPT ![i].state = "CLOSED"]
  /\ UNCHANGED <<made, parent, tip, local, remote, pushedEver, integ, mainMoves, reopened, recv, pollv, pushv, xv, hist>>

\* Reopened, at the branch as it is now, if it still has the head.
ForgeReopen(i) ==
  /\ ~reopened /\ fpr[i].state = "CLOSED" /\ NoOpen
  /\ remote # None /\ IsAnc(fpr[i].head, remote)
  /\ fpr' = [fpr EXCEPT ![i] = [state |-> "OPEN", head |-> remote]] /\ reopened' = TRUE
  /\ UNCHANGED <<made, parent, tip, local, remote, pushedEver, integ, mainMoves, recv, pollv, pushv, xv, hist>>

\* You merge the task by hand into a branch, the one it merges into or not;
\* or a fork of it merged there, with the task's commits it started from.
HandMerge(b) ==
  /\ mainMoves = 0 /\ tip # 0 /\ tip \notin integ[b]
  /\ integ' = [integ EXCEPT ![b] = @ \cup Anc(tip)] /\ mainMoves' = 1
  /\ UNCHANGED <<made, parent, tip, local, remote, pushedEver, fpr, reopened, recv, pollv, pushv, xv, hist>>

\* You pull a branch after the forge merged into it with a merge commit.
PullMain(b) ==
  /\ mainMoves = 0
  /\ \E h \in MergedHeads :
       /\ h \notin integ[b]
       /\ integ' = [integ EXCEPT ![b] = @ \cup Anc(h)]
       /\ local' = local \cup Anc(h) /\ mainMoves' = 1
  /\ UNCHANGED <<made, parent, tip, remote, pushedEver, fpr, reopened, recv, pollv, pushv, xv, hist>>

----------------------------------------------------------------------------
(* B, rpc's `retarget`, under the lock: the record names another branch to
   merge into, and counts the task's commits from where its branch and what
   B names part (git merge-base).  That is any commit of the task's line:
   B may name a branch, which has the task's commits up to there; origin's
   branch of a name, with what the forge merged, which gives the local one;
   another task's branch, as a fork's, which gives the branch that task
   merges into; or a tag or a commit, which gives the primary checkout's
   branch.  No commit moves, and a pull request stays as it is.

   What has all of the task's commits leaves where they count from as it
   was: counted from the tip, a pull request at them would not be the
   task's.  Where its branch was made, startCommit, stays whatever B names
   (StartedAt): a task that committed never reads as one that didn't. *)
Retarget(b) ==
  /\ retargets < MaxRetargets
  /\ \E start \in Anc(tip) :
       base' = IF start = tip /\ ~BaseOntoTip THEN base ELSE start
  /\ target' = b /\ retargets' = retargets + 1
  /\ UNCHANGED <<world, rec, pollv, pushv, xv, hist>>

----------------------------------------------------------------------------
\* What a finished poll, `P` or `x` held is forgotten, as its process ends.
PollDone == poll' = "idle" /\ snap' = NoRec /\ starget' = 1 /\ sbase' = 0 /\ ptip' = 0
            /\ ans' = [i \in PRs |-> NoPR] /\ ours' = {} /\ taskPr' = NoRec
PushDone == push' = "idle" /\ pbefore' = NoRec /\ phead' = None /\ pnum' = 0
RetireDone == xs' = "idle" /\ xtarget' = 1 /\ xbase' = 0 /\ xmh' = None

(* A poll: rpc's `list`, then check_pull_requests, then the measurement. *)

\* list_tasks reads the record under the lock; then check_pull_requests
\* reads branch_tip, and asks for a recorded one or a pushed branch.  One
\* step: what runs between them changes the record or the tip, not both,
\* so it reads the same as if it ran before or after.
PollList ==
  /\ poll = "idle"
  /\ snap' = rec /\ taskPr' = rec /\ ptip' = tip /\ starget' = target /\ sbase' = base
  /\ poll' = IF rec.num # 0 \/ pushedEver THEN "ask" ELSE "measure"
  /\ UNCHANGED <<world, recv, ans, ours, pushv, xv, hist>>

\* task_pull_requests: the forge lists them, and only the task's count:
\* the recorded one, or one whose head is on the branch here, at the tip,
\* and made since where the task's commits count from (baseCommit, FROM), as
\* the record this request read has it.
OursOf(f, t, num, from) ==
  {i \in PRs : f[i].state # "none" /\
     (i = num \/ (f[i].head \in local /\ ~IsAnc(f[i].head, from) /\ IsAnc(f[i].head, t)))}
PollAsk ==
  /\ poll = "ask"
  /\ \/ /\ ans' = fpr /\ ours' = OursOf(fpr, ptip, snap.num, sbase) /\ poll' = "fetch"
     \/ /\ poll' = "measure" /\ UNCHANGED <<ans, ours>>   \* no answer: None
  /\ UNCHANGED <<world, recv, snap, starget, sbase, ptip, taskPr, pushv, xv, hist>>

\* fetch_heads: each head that isn't here, by its commit.  It comes, or
\* doesn't (refused, or out of time).
ToFetch == {ans[i].head : i \in {j \in ours : ans[j].state \in {"OPEN", "MERGED"}
                                   /\ ans[j].head # ptip /\ ans[j].head \notin local}}
PollFetch ==
  /\ poll = "fetch"
  /\ \E came \in SUBSET ToFetch : local' = local \cup UNION {Anc(h) : h \in came}
  /\ poll' = "write"
  /\ UNCHANGED <<made, parent, tip, remote, pushedEver, integ, mainMoves, fpr, reopened,
                 recv, snap, starget, sbase, ptip, ans, ours, taskPr, pushv, xv, hist>>

\* shown_pull_request, merged_tip, and the record check_pull_requests makes.
MergedTip(i) == ans[i].state = "MERGED" /\ HasTip(ans[i].head, ptip)
Shown == LET open == {i \in ours : ans[i].state = "OPEN"}
             atTip == {i \in ours : MergedTip(i)}
         IN IF open # {} THEN Max(open) ELSE IF atTip # {} THEN Max(atTip) ELSE Max(ours)
Made(s) ==
  LET h == ans[s].head
      merged == {i \in ours : MergedTip(i)}
      mh == IF merged # {} THEN ans[Max(merged)].head
            ELSE IF RecordedMergeAt(snap, ptip)
                 THEN IF snap.mergedHead # None THEN snap.mergedHead ELSE snap.head
                 ELSE None
  IN [num |-> s, state |-> ans[s].state, head |-> h, mergedHead |-> mh]

\* Under the lock: unless another request recorded one while this asked.
\* Only `pr` is compared and written: a branch B named meanwhile stays.
PollWrite ==
  /\ poll = "write"
  /\ IF ours = {} THEN UNCHANGED <<rec, taskPr>>
     ELSE IF rec = snap THEN rec' = Made(Shown) /\ taskPr' = Made(Shown)
     ELSE taskPr' = rec /\ UNCHANGED rec
  /\ poll' = "measure"
  /\ UNCHANGED <<world, target, base, retargets, snap, starget, sbase, ptip, ans, ours, pushv, xv, hist>>

\* add_git_stats, or rpc's own landed() for one asked about: at the tip now,
\* of the branch the reply names, which is the one list_tasks read.
PollMeasure ==
  /\ poll = "measure"
  /\ LET at == IF MeasureAtAskedTip THEN ptip ELSE tip IN
     badReply' = (badReply \/ (HostLanded(taskPr, starget, sbase, at) /\ ~TrulyIn(tip, starget)))
  /\ PollDone
  /\ UNCHANGED <<world, recv, pushv, xv, lostByRetire, retiredUnlanded>>

----------------------------------------------------------------------------
(* `P`, rpc's `pr`.  With one recorded, and no title for another: push. *)

PStartPush ==
  /\ Pushes /\ push = "idle" /\ rec.num # 0
  /\ push' = "push" /\ pbefore' = rec
  /\ UNCHANGED <<world, recv, pollv, phead, pnum, xv, hist>>

\* push_pull_request: fetch the forge's branch, push only what is new, never
\* force.  Git refuses a push that isn't a fast-forward.
PPush ==
  /\ push = "push"
  /\ LET since == IF remote = None THEN 0 ELSE remote IN
     /\ local' = IF remote = None THEN local ELSE local \cup Anc(remote)
     /\ IF IsAnc(tip, since)
        THEN /\ phead' = since /\ push' = "record"
             /\ UNCHANGED <<remote, pushedEver, fpr, pbefore, pnum>>
        ELSE IF remote = None \/ IsAnc(remote, tip)
        THEN /\ remote' = tip /\ pushedEver' = TRUE /\ fpr' = FollowRemote(fpr, tip)
             /\ phead' = tip /\ push' = "record" /\ UNCHANGED <<pbefore, pnum>>
        ELSE PushDone /\ UNCHANGED <<remote, pushedEver, fpr>>
  /\ UNCHANGED <<made, parent, tip, integ, mainMoves, reopened, recv, pollv, xv, hist>>

\* record_push: not over a record that moved, nor one closed or merged.
PRecord ==
  /\ push = "record"
  /\ IF rec = pbefore /\ (pbefore.state \notin {"CLOSED", "MERGED"} \/ PushMovesMerged)
     THEN rec' = [rec EXCEPT !.head = phead] ELSE UNCHANGED rec
  /\ PushDone
  /\ UNCHANGED <<world, target, base, retargets, pollv, xv, hist>>

\* pull_request: none recorded, or a title after one closed or merged.  The
\* open one is asked for first; push -u, never forced; create if none.
POpen ==
  /\ Pushes /\ push = "idle" /\ (rec.num = 0 \/ rec.state \in {"CLOSED", "MERGED"}) /\ tip # 0
  /\ remote = None \/ IsAnc(remote, tip)
  /\ LET open == {i \in PRs : fpr[i].state = "OPEN"} IN
     \/ /\ open # {}
        /\ fpr' = FollowRemote(fpr, tip) /\ pnum' = Max(open)
     \/ /\ open = {} /\ NextPR # 0
        /\ fpr' = [FollowRemote(fpr, tip) EXCEPT ![NextPR] = [state |-> "OPEN", head |-> tip]]
        /\ pnum' = NextPR
  /\ remote' = tip /\ pushedEver' = TRUE /\ push' = "openrec"
  /\ UNCHANGED <<made, parent, tip, local, integ, mainMoves, reopened, recv, pollv, pbefore, phead, xv, hist>>

\* task["pr"] = {number, url}, read again under the lock and saved.
POpenRecord ==
  /\ push = "openrec"
  /\ rec' = [NoRec EXCEPT !.num = pnum] /\ PushDone
  /\ UNCHANGED <<world, target, base, retargets, pollv, xv, hist>>

----------------------------------------------------------------------------
(* `x`, rpc's `retire`.  It reads the task and lets the lock go, and
   merged_pull_request_head asks the forge: the task's pull requests, as
   task_pull_requests has them, a merged head that isn't here fetched again.
   The answer is the tip, if one merged all of it or the record says one
   did.  No answer, or none merged: None. *)
XAsk ==
  /\ Retires /\ xs = "idle"
  \* Kept only to say what the broken retire goes by.
  /\ xtarget' = (IF RetireReadsOnce THEN target ELSE 1)
  /\ xbase' = (IF RetireReadsOnce THEN base ELSE 0)
  /\ \E answered \in BOOLEAN, came \in BOOLEAN :
       LET mine == IF answered THEN OursOf(fpr, tip, rec.num, base) ELSE {}
           merged == {i \in mine : fpr[i].state = "MERGED"}
           have == IF came THEN local \cup UNION {Anc(fpr[i].head) : i \in merged} ELSE local
       IN /\ local' = have
          /\ xmh' = IF (\E i \in merged : HasTipIn(fpr[i].head, tip, have)) \/ RecordedMergeAt(rec, tip)
                    THEN tip ELSE None
  /\ xs' = "asked"
  /\ UNCHANGED <<made, parent, tip, remote, pushedEver, integ, mainMoves, fpr, reopened,
                 recv, pollv, pushv, hist>>

\* for-each-ref --contains, but for the task's own branch: a branch here, or
\* its own on the forge as last pushed or fetched.
Elsewhere(t) == (\E b \in Bs : t \in integ[b]) \/ (remote # None /\ IsAnc(t, remote))

\* safe_to_delete, of a record naming the branch B and counting its commits
\* from FROM: a task that never committed, its branch where it was made
\* (started_at), which is somewhere else too; a tip in the branch it merges
\* into; or the tip the forge was just said to have merged.
SafeToDelete(b, from, t, mh) ==
  \/ t = StartedAt(from) /\ Elsewhere(t)
  \/ t \in integ[b]
  \/ mh # None /\ mh = t

\* Under the lock again, rpc reads the task again, and retire deletes the
\* branch where it is now, if that is safe by the record as it is now.
\* What deleting it would do is noted, and the task goes on, as if refused.
XRetire ==
  /\ xs = "asked"
  /\ LET b == IF RetireReadsOnce THEN xtarget ELSE target
         from == IF RetireReadsOnce THEN xbase ELSE base
         safe == SafeToDelete(b, from, tip, xmh)
     IN /\ lostByRetire' = (lostByRetire \/ (safe /\ ~(Elsewhere(tip) \/ OnForge(tip))))
        /\ retiredUnlanded' = (retiredUnlanded \/
                               (safe /\ ~(tip \in integ[target] \/ OnForge(tip) \/ tip = 0)))
  /\ RetireDone
  /\ UNCHANGED <<world, recv, pollv, pushv, badReply>>

----------------------------------------------------------------------------
Init ==
  /\ made = 0 /\ parent = [c \in Commits |-> 0]
  /\ tip = 0 /\ local = {0} /\ remote = None /\ pushedEver = FALSE
  /\ integ = [b \in Bs |-> {0}] /\ mainMoves = 0
  /\ fpr = [i \in PRs |-> NoPR] /\ reopened = FALSE
  /\ rec = NoRec /\ target = 1 /\ base = 0 /\ retargets = 0
  /\ poll = "idle" /\ snap = NoRec /\ starget = 1 /\ sbase = 0 /\ ptip = 0
  /\ ans = [i \in PRs |-> NoPR] /\ ours = {} /\ taskPr = NoRec
  /\ push = "idle" /\ pbefore = NoRec /\ phead = None /\ pnum = 0
  /\ xs = "idle" /\ xtarget = 1 /\ xbase = 0 /\ xmh = None
  /\ badReply = FALSE /\ lostByRetire = FALSE /\ retiredUnlanded = FALSE

Next ==
  \/ Commit \/ Rewrite \/ Reset \/ AgentPush \/ AgentPull \/ AgentOpens \/ ForgeCommit
  \/ \E i \in PRs : ForgeMerge(i) \/ ForgeClose(i) \/ ForgeReopen(i)
  \/ \E b \in Bs : HandMerge(b) \/ PullMain(b) \/ Retarget(b)
  \/ PollList \/ PollAsk \/ PollFetch \/ PollWrite \/ PollMeasure
  \/ PStartPush \/ PPush \/ PRecord \/ POpen \/ POpenRecord
  \/ XAsk \/ XRetire

Spec == Init /\ [][Next]_vars

----------------------------------------------------------------------------
(* Rules. *)

TypeOK ==
  /\ made \in 0..MaxCommits /\ tip \in Commits /\ local \subseteq Commits
  /\ remote \in Commits \cup {None} /\ \A b \in Bs : integ[b] \subseteq Commits
  /\ target \in Bs /\ base \in Commits /\ starget \in Bs /\ xtarget \in Bs
  /\ rec \in Recs /\ snap \in Recs /\ taskPr \in Recs /\ pbefore \in Recs

\* Retiring deletes the branch at the tip when the record says it merged
\* there (merged_pull_request_head, safe_to_delete), or the tip is in the
\* branch the task merges into; a fresh answer from the forge is the
\* forge's own word.  The record is to be believed: whatever it says
\* landed, did.  And what x deletes is somewhere else too.
RetireLosesNothing == (HostLanded(rec, target, base, tip) => Truly(tip)) /\ ~lostByRetire

\* x deletes a branch only when its tip is in the branch the task merges
\* into, as its record names it then, or in what the forge merged, or the
\* task never committed.
RetireOnlyLanded == ~retiredUnlanded

\* What a reply tells Emacs is landed was, when measured, of the branch
\* that reply names.
RepliesSayTrue == ~badReply

\* A merge the record names happened, at the head it names.
RecordedMergesHappened ==
  /\ rec.state = "MERGED" => fpr[rec.num].state = "MERGED" /\ fpr[rec.num].head = rec.head
  /\ rec.mergedHead # None => rec.mergedHead \in MergedHeads

\* Work that is merged says so: only commits after the merge keep it from
\* that, and not what B names.
LandedSaysSo ==
  (tip # 0 /\ (RecordedMergeAt(rec, tip) \/ tip \in integ[target])) => HostLanded(rec, target, base, tip)
=============================================================================
