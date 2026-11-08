---------------------------- MODULE Landed ----------------------------
(***************************************************************************)
(* What the host helper records of a task's pull request, and when it says *)
(* the task's work is merged ("landed"), so that retiring it may delete    *)
(* its branch.  scripts/roost_remote.py: has_tip, recorded_merge_at,       *)
(* landed, task_pull_requests, shown_pull_request, head_to_fetch,          *)
(* fetch_heads, check_pull_requests, push_pull_request, record_push,       *)
(* pull_request and rpc's `pr` branch.  One task, one branch.              *)
(*                                                                         *)
(* Commits are numbers: 0 is where the task started (baseCommit), each new *)
(* one has a parent.  Git on the host knows `local`; the forge knows every *)
(* commit, as one made there isn't here until fetched.                     *)
(*                                                                         *)
(* The world moves at any time: the agent commits, rewrites its last       *)
(* commit, pushes (with force, as an agent may), pulls the forge's branch, *)
(* and opens pull requests; the forge takes commits, merges, closes and    *)
(* reopens; you merge the task into the integration branch by hand, or     *)
(* pull a merge into it.  Meanwhile one poll (check_pull_requests, then    *)
(* the measurement) and one `P` (push to the recorded pull request, or     *)
(* open one) run on the host, step by step as the code takes the lock.    *)
(***************************************************************************)
EXTENDS Integers, FiniteSets

CONSTANTS
  MaxCommits,       \* commits made anywhere, here or on the forge
  NPR,              \* pull requests that can be opened
  HasTipReversed,   \* broken: has_tip asks whether the head is in the tip
  PushMovesMerged,  \* broken: record_push moves a closed or merged one's head
  MeasureAtAskedTip \* broken: landed() of a task asked about takes the tip
                    \* check_pull_requests read, not branch_tip again

None == -1
Commits == 0..MaxCommits
PRs == 1..NPR
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
  integ,             \* commits in the integration branch, here
  mainMoves,         \* you merged into it by hand, or pulled it (bounded)
  fpr,               \* the forge's pull requests: state and head
  reopened,          \* a closed one was reopened (bounded)
  rec,               \* the record's `pr`
  poll, snap, ptip, ans, ours, taskPr,  \* one poll's progress
  push, pbefore, phead, pnum,                        \* one `P`'s progress
  badReply           \* a measurement said landed of work that wasn't

world == <<made, parent, tip, local, remote, pushedEver, integ, mainMoves, fpr, reopened>>
pollv == <<poll, snap, ptip, ans, ours, taskPr>>
pushv == <<push, pbefore, phead, pnum>>
vars == <<world, rec, pollv, pushv, badReply>>

----------------------------------------------------------------------------
(* Git's ancestry, in the whole graph. *)
RECURSIVE IsAnc(_, _)
IsAnc(a, b) == IF a = b THEN TRUE ELSE IF b = 0 THEN FALSE ELSE IsAnc(a, parent[b])
Anc(c) == {a \in 0..made : IsAnc(a, c)}

(* What is true: the tip's work reached a base branch. *)
MergedHeads == {fpr[i].head : i \in {j \in PRs : fpr[j].state = "MERGED"}}
Truly(t) == t # 0 /\ (t \in integ \/ \E h \in MergedHeads : IsAnc(t, h))

(* has_tip: HEAD, a pull request's, has all of TIP.  is_ancestor needs both
   here: False for a head not fetched. *)
HasTip(h, t) == h = t \/ (h # None /\ h \in local /\
                          IF HasTipReversed THEN IsAnc(h, t) ELSE IsAnc(t, h))
RecordedMergeAt(r, t) ==
  r.num # 0 /\ (HasTip(r.mergedHead, t) \/ (r.state = "MERGED" /\ HasTip(r.head, t)))
(* landed(task, tip); committed_on is taken as so. *)
HostLanded(r, t) == t # 0 /\ (RecordedMergeAt(r, t) \/ t \in integ)

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
  /\ UNCHANGED <<remote, pushedEver, integ, mainMoves, fpr, reopened, rec, pollv, pushv, badReply>>

\* git commit --amend, or a rebase: the tip's parent gets a new child.
Rewrite ==
  /\ CanMake /\ tip # 0
  /\ made' = New /\ parent' = [parent EXCEPT ![New] = parent[tip]]
  /\ tip' = New /\ local' = local \cup {New}
  /\ UNCHANGED <<remote, pushedEver, integ, mainMoves, fpr, reopened, rec, pollv, pushv, badReply>>

\* The agent's git push, forced or not; an open pull request follows.
AgentPush ==
  /\ remote # tip
  /\ remote' = tip /\ pushedEver' = TRUE /\ fpr' = FollowRemote(fpr, tip)
  /\ UNCHANGED <<made, parent, tip, local, integ, mainMoves, reopened, rec, pollv, pushv, badReply>>

\* git pull, fast-forward, of the forge's branch: commits made there come.
AgentPull ==
  /\ remote \notin {None, tip} /\ IsAnc(tip, remote)
  /\ local' = local \cup Anc(remote) /\ tip' = remote
  /\ UNCHANGED <<made, parent, remote, pushedEver, integ, mainMoves, fpr, reopened, rec, pollv, pushv, badReply>>

\* The agent opens one with gh, outside Roost.
AgentOpens ==
  /\ NextPR # 0 /\ NoOpen /\ remote \notin {None, 0}
  /\ fpr' = [fpr EXCEPT ![NextPR] = [state |-> "OPEN", head |-> remote]]
  /\ UNCHANGED <<made, parent, tip, local, remote, pushedEver, integ, mainMoves, reopened, rec, pollv, pushv, badReply>>

\* A commit made on the forge, as a suggestion accepted there.
ForgeCommit ==
  /\ CanMake /\ remote # None
  /\ made' = New /\ parent' = [parent EXCEPT ![New] = remote]
  /\ remote' = New /\ fpr' = FollowRemote(fpr, New)
  /\ UNCHANGED <<tip, local, pushedEver, integ, mainMoves, reopened, rec, pollv, pushv, badReply>>

\* Merged on the forge, as a merge, a squash or a rebase: its head is in.
ForgeMerge(i) ==
  /\ fpr[i].state = "OPEN"
  /\ fpr' = [fpr EXCEPT ![i].state = "MERGED"]
  /\ UNCHANGED <<made, parent, tip, local, remote, pushedEver, integ, mainMoves, reopened, rec, pollv, pushv, badReply>>

ForgeClose(i) ==
  /\ fpr[i].state = "OPEN"
  /\ fpr' = [fpr EXCEPT ![i].state = "CLOSED"]
  /\ UNCHANGED <<made, parent, tip, local, remote, pushedEver, integ, mainMoves, reopened, rec, pollv, pushv, badReply>>

\* Reopened, at the branch as it is now, if it still has the head.
ForgeReopen(i) ==
  /\ ~reopened /\ fpr[i].state = "CLOSED" /\ NoOpen
  /\ remote # None /\ IsAnc(fpr[i].head, remote)
  /\ fpr' = [fpr EXCEPT ![i] = [state |-> "OPEN", head |-> remote]] /\ reopened' = TRUE
  /\ UNCHANGED <<made, parent, tip, local, remote, pushedEver, integ, mainMoves, rec, pollv, pushv, badReply>>

\* You merge the task by hand in the primary checkout.
HandMerge ==
  /\ mainMoves = 0 /\ tip # 0 /\ tip \notin integ
  /\ integ' = integ \cup Anc(tip) /\ mainMoves' = 1
  /\ UNCHANGED <<made, parent, tip, local, remote, pushedEver, fpr, reopened, rec, pollv, pushv, badReply>>

\* You pull the integration branch after the forge merged with a merge commit.
PullMain ==
  /\ mainMoves = 0
  /\ \E h \in MergedHeads :
       /\ h \notin integ
       /\ integ' = integ \cup Anc(h) /\ local' = local \cup Anc(h) /\ mainMoves' = 1
  /\ UNCHANGED <<made, parent, tip, remote, pushedEver, fpr, reopened, rec, pollv, pushv, badReply>>

----------------------------------------------------------------------------
\* What a finished poll or `P` held is forgotten, as its process ends.
PollDone == poll' = "idle" /\ snap' = NoRec /\ ptip' = 0 /\ ans' = [i \in PRs |-> NoPR]
            /\ ours' = {} /\ taskPr' = NoRec
PushDone == push' = "idle" /\ pbefore' = NoRec /\ phead' = None /\ pnum' = 0

(* A poll: rpc's `list`, then check_pull_requests, then the measurement. *)

\* list_tasks reads the record under the lock; then check_pull_requests
\* reads branch_tip, and asks for a recorded one or a pushed branch.  One
\* step: what runs between them changes the record or the tip, not both,
\* so it reads the same as if it ran before or after.
PollList ==
  /\ poll = "idle"
  /\ snap' = rec /\ taskPr' = rec /\ ptip' = tip
  /\ poll' = IF rec.num # 0 \/ pushedEver THEN "ask" ELSE "measure"
  /\ UNCHANGED <<world, rec, ans, ours, pushv, badReply>>

\* task_pull_requests: the forge lists them, and only the task's count:
\* the recorded one, or one whose head is on the branch here, at the tip.
Ours(f, t) == {i \in PRs : f[i].state # "none" /\
                 (i = snap.num \/ (f[i].head \in local /\ f[i].head # 0 /\ IsAnc(f[i].head, t)))}
PollAsk ==
  /\ poll = "ask"
  /\ \/ /\ ans' = fpr /\ ours' = Ours(fpr, ptip) /\ poll' = "fetch"
     \/ /\ poll' = "measure" /\ UNCHANGED <<ans, ours>>   \* no answer: None
  /\ UNCHANGED <<world, rec, snap, ptip, taskPr, pushv, badReply>>

\* fetch_heads: each head that isn't here, by its commit.  It comes, or
\* doesn't (refused, or out of time).
ToFetch == {ans[i].head : i \in {j \in ours : ans[j].state \in {"OPEN", "MERGED"}
                                   /\ ans[j].head # ptip /\ ans[j].head \notin local}}
PollFetch ==
  /\ poll = "fetch"
  /\ \E came \in SUBSET ToFetch : local' = local \cup UNION {Anc(h) : h \in came}
  /\ poll' = "write"
  /\ UNCHANGED <<made, parent, tip, remote, pushedEver, integ, mainMoves, fpr, reopened,
                 rec, snap, ptip, ans, ours, taskPr, pushv, badReply>>

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
PollWrite ==
  /\ poll = "write"
  /\ IF ours = {} THEN UNCHANGED <<rec, taskPr>>
     ELSE IF rec = snap THEN rec' = Made(Shown) /\ taskPr' = Made(Shown)
     ELSE taskPr' = rec /\ UNCHANGED rec
  /\ poll' = "measure"
  /\ UNCHANGED <<world, snap, ptip, ans, ours, pushv, badReply>>

\* add_git_stats, or rpc's own landed() for one asked about: at the tip now.
PollMeasure ==
  /\ poll = "measure"
  /\ LET at == IF MeasureAtAskedTip THEN ptip ELSE tip IN
     badReply' = (badReply \/ (HostLanded(taskPr, at) /\ ~Truly(tip)))
  /\ PollDone
  /\ UNCHANGED <<world, rec, pushv>>

----------------------------------------------------------------------------
(* `P`, rpc's `pr`.  With one recorded, and no title for another: push. *)

PStartPush ==
  /\ push = "idle" /\ rec.num # 0
  /\ push' = "push" /\ pbefore' = rec
  /\ UNCHANGED <<world, rec, pollv, phead, pnum, badReply>>

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
  /\ UNCHANGED <<made, parent, tip, integ, mainMoves, reopened, rec, pollv, badReply>>

\* record_push: not over a record that moved, nor one closed or merged.
PRecord ==
  /\ push = "record"
  /\ IF rec = pbefore /\ (pbefore.state \notin {"CLOSED", "MERGED"} \/ PushMovesMerged)
     THEN rec' = [rec EXCEPT !.head = phead] ELSE UNCHANGED rec
  /\ PushDone
  /\ UNCHANGED <<world, pollv, badReply>>

\* pull_request: none recorded, or a title after one closed or merged.  The
\* open one is asked for first; push -u, never forced; create if none.
POpen ==
  /\ push = "idle" /\ (rec.num = 0 \/ rec.state \in {"CLOSED", "MERGED"}) /\ tip # 0
  /\ remote = None \/ IsAnc(remote, tip)
  /\ LET open == {i \in PRs : fpr[i].state = "OPEN"} IN
     \/ /\ open # {}
        /\ fpr' = FollowRemote(fpr, tip) /\ pnum' = Max(open)
     \/ /\ open = {} /\ NextPR # 0
        /\ fpr' = [FollowRemote(fpr, tip) EXCEPT ![NextPR] = [state |-> "OPEN", head |-> tip]]
        /\ pnum' = NextPR
  /\ remote' = tip /\ pushedEver' = TRUE /\ push' = "openrec"
  /\ UNCHANGED <<made, parent, tip, local, integ, mainMoves, reopened, rec, pollv, pbefore, phead, badReply>>

\* task["pr"] = {number, url}, read again under the lock and saved.
POpenRecord ==
  /\ push = "openrec"
  /\ rec' = [NoRec EXCEPT !.num = pnum] /\ PushDone
  /\ UNCHANGED <<world, pollv, badReply>>

----------------------------------------------------------------------------
Init ==
  /\ made = 0 /\ parent = [c \in Commits |-> 0]
  /\ tip = 0 /\ local = {0} /\ remote = None /\ pushedEver = FALSE
  /\ integ = {0} /\ mainMoves = 0
  /\ fpr = [i \in PRs |-> NoPR] /\ reopened = FALSE
  /\ rec = NoRec
  /\ poll = "idle" /\ snap = NoRec /\ ptip = 0 /\ ans = [i \in PRs |-> NoPR]
  /\ ours = {} /\ taskPr = NoRec
  /\ push = "idle" /\ pbefore = NoRec /\ phead = None /\ pnum = 0
  /\ badReply = FALSE

Next ==
  \/ Commit \/ Rewrite \/ AgentPush \/ AgentPull \/ AgentOpens \/ ForgeCommit
  \/ \E i \in PRs : ForgeMerge(i) \/ ForgeClose(i) \/ ForgeReopen(i)
  \/ HandMerge \/ PullMain
  \/ PollList \/ PollAsk \/ PollFetch \/ PollWrite \/ PollMeasure
  \/ PStartPush \/ PPush \/ PRecord \/ POpen \/ POpenRecord

Spec == Init /\ [][Next]_vars

----------------------------------------------------------------------------
(* Rules. *)

TypeOK ==
  /\ made \in 0..MaxCommits /\ tip \in Commits /\ local \subseteq Commits
  /\ remote \in Commits \cup {None} /\ integ \subseteq Commits
  /\ rec \in Recs /\ snap \in Recs /\ taskPr \in Recs /\ pbefore \in Recs

\* Retiring deletes the branch at the tip when the record says it merged
\* there (merged_pull_request_head, safe_to_delete), or the tip is in the
\* integration branch; a fresh answer from the forge is the forge's own
\* word.  The record is to be believed: whatever it says landed, did.
RetireLosesNothing == HostLanded(rec, tip) => Truly(tip)

\* What a reply tells Emacs is landed was, when measured.
RepliesSayTrue == ~badReply

\* A merge the record names happened, at the head it names.
RecordedMergesHappened ==
  /\ rec.state = "MERGED" => fpr[rec.num].state = "MERGED" /\ fpr[rec.num].head = rec.head
  /\ rec.mergedHead # None => rec.mergedHead \in MergedHeads
=============================================================================
