--------------------------- MODULE MergedWord ---------------------------
(***************************************************************************)
(* Whether a task's row in Emacs says "merged", from what its host last    *)
(* measured, as polls, lists and their replies go.  roost.el:              *)
(* roost--refresh-host (its success lambda, `lost' and `finish'),          *)
(* roost--cache-task (fields a reply leaves out are kept),                 *)
(* roost--task-states, roost--landed, roost--merged-p,                     *)
(* roost--display-status, and roost-retarget with roost--act;              *)
(* scripts/roost_remote.py: rpc's `list`, with git_stamp, add_git_stats    *)
(* and the landed() of a task asked about, and retarget.                   *)
(*                                                                         *)
(* One task on one host, its agent idle and seen, its worktree on its      *)
(* branch.  Whether its work is landed is as Landed.tla checks the host    *)
(* says it: here the host's word is the truth, of the branch its record    *)
(* names.  What Emacs knows is only what replies brought.                  *)
(***************************************************************************)
EXTENDS Naturals

CONSTANTS
  MaxCommits,           \* commits made in the worktree
  MaxMerges,            \* merges: by hand into the integration branch, or on the forge
  MaxLost,              \* replies failed, or dropped as stale, in all
  MaxRetargets,         \* times B names another branch for the task to merge into
  LandedWithoutStats,   \* broken: a poll asking the forge says landed, measuring nothing
  StampUnwatched,       \* broken: roost--task-states leaves out the Git stamp
  GivesUpOwed,          \* broken: what was owed and lost again goes, as before
  RetargetUnmeasured,   \* broken: roost-retarget asks for no measurement once its host replies
  BranchUnwatched       \* broken: roost--task-states leaves out the branch it merges into

VARIABLES
  \* The worktree, the record and the forge.
  landed,      \* the tip's commits are all merged
  dirty,       \* changes not committed
  stamp,       \* git_stamp: moves on commits and the integration branch's reflog
  commits, merges,
  pushed,      \* a pull request recorded, or the branch pushed: polls ask the forge
  atTip,       \* the branch on the forge is at the tip, so a merge there lands it
  branch,      \* the record's integrationBranch: how many times B changed it
  \* One list of Emacs's at a time (roost--refreshing).
  req,         \* "none", "Q" quiet, "QP" quiet asking the forge, "M" a list of this task, "F" full
  hstep,       \* how far the host has got: "list", "measure", "reply"
  rStamp, rLanded, rDirty,   \* what the reply says; "absent" when left out
  rBranch,     \* the branch the record named as list_tasks read it
  owedAtStart, newT,         \* what roost--refresh-host's `owed' and `new' were
  stale,       \* an action's reply came since it went: roost--revisions moved on
  pending,     \* roost--full-refresh-pending: a list asked for while this one is out
  owed,        \* roost--measures-owed for this host: "none", "ids" or "all"
  later,       \* roost--measures-due says quiet polls take what is owed up later
  lost,
  act,         \* "sent" while the reply to B is on its way here
  \* Emacs's cache.
  eStamp, eLanded, eDirty, eBranch,
  cleanStale   \* landed came, and cleanliness is from before it

world == <<landed, dirty, stamp, commits, merges, pushed, atTip, branch>>
request == <<req, hstep, rStamp, rLanded, rDirty, rBranch, owedAtStart, newT, stale, pending>>
emacs == <<owed, later, lost, act, eStamp, eLanded, eDirty, eBranch, cleanStale>>
vars == <<world, request, emacs>>

YesNo(b) == IF b THEN "yes" ELSE "no"

\* roost--merged-p, as roost--display-status puts it first: landed, as
\* measured with its Git statistics, and clean.
Merged == eLanded = "yes" /\ eDirty = "no"

----------------------------------------------------------------------------
(* The worktree, the record and the forge. *)

\* A commit, by hand or by the agent: work the merge doesn't have.
Commit ==
  /\ commits < MaxCommits
  /\ commits' = commits + 1 /\ stamp' = stamp + 1
  /\ landed' = FALSE /\ dirty' = FALSE /\ atTip' = FALSE
  /\ UNCHANGED <<merges, pushed, branch, request, emacs>>

\* An edit not staged moves no stamp.
Edit ==
  /\ ~dirty /\ dirty' = TRUE
  /\ UNCHANGED <<landed, stamp, commits, merges, pushed, atTip, branch, request, emacs>>

Push ==
  /\ commits > 0 /\ ~atTip
  /\ pushed' = TRUE /\ atTip' = TRUE
  /\ UNCHANGED <<landed, dirty, stamp, commits, merges, branch, request, emacs>>

\* You merge it into the integration branch: its reflog moves the stamp.
HandMerge ==
  /\ commits > 0 /\ ~landed /\ merges < MaxMerges
  /\ landed' = TRUE /\ merges' = merges + 1 /\ stamp' = stamp + 1
  /\ UNCHANGED <<dirty, commits, pushed, atTip, branch, request, emacs>>

\* Its pull request merges on the forge: nothing here moves.
ForgeMerge ==
  /\ atTip /\ ~landed /\ merges < MaxMerges
  /\ landed' = TRUE /\ merges' = merges + 1
  /\ UNCHANGED <<dirty, stamp, commits, pushed, atTip, branch, request, emacs>>

\* B, here or in another Emacs: rpc's `retarget` has the record name another
\* branch.  No commit moves.  Whether the task's commits are merged is then
\* of that branch, which may have them or lack them.  The stamp takes that
\* branch's reflog, which may have another time, the same, or be none.  The
\* reply is on its way here; or it is lost, or B was another Emacs's.
Retarget ==
  /\ branch < MaxRetargets /\ act = "none"
  /\ branch' = branch + 1
  /\ landed' \in (IF commits > 0 THEN BOOLEAN ELSE {FALSE})
  /\ stamp' \in {stamp, stamp + 1}
  /\ act' \in {"none", "sent"}
  /\ UNCHANGED <<dirty, commits, merges, pushed, atTip, request,
                 owed, later, lost, eStamp, eLanded, eDirty, eBranch, cleanStale>>

----------------------------------------------------------------------------
(* Emacs asks; the host answers. *)

\* roost--refresh-host, not quiet: a list of this task's ID (WHAT "ids") or
\* of every task ("all"), which takes OW, what is owed, along.
StartWith(what, ow) ==
  /\ req' = IF what = "all" \/ ow = "all" THEN "F" ELSE "M"
  /\ hstep' = "list" /\ newT' = (what = "ids")
  /\ owedAtStart' = ow /\ owed' = "none"
  /\ rStamp' = 0 /\ rLanded' = "absent" /\ rDirty' = "absent" /\ rBranch' = 0
  /\ stale' = FALSE /\ pending' = "none"

\* The watch timer's quiet poll; now and then one asks the forge too.
Poll(kind) ==
  /\ req = "none"
  /\ req' = kind /\ hstep' = "list" /\ newT' = FALSE /\ owedAtStart' = "none"
  /\ UNCHANGED <<rStamp, rLanded, rDirty, rBranch, stale, pending, world, emacs>>

\* g: a full refresh takes what is owed.
Full ==
  /\ req = "none"
  /\ StartWith("all", owed)
  /\ UNCHANGED <<world, later, lost, act, eStamp, eLanded, eDirty, eBranch, cleanStale>>

\* rpc's `list`, once asked: the records, then git_stamp.
HostList ==
  /\ req # "none" /\ hstep = "list"
  /\ rStamp' = stamp /\ rBranch' = branch /\ hstep' = "measure"
  /\ UNCHANGED <<req, rLanded, rDirty, owedAtStart, newT, stale, pending, world, emacs>>

\* add_git_stats for the tasks measured; for one the forge was asked about
\* and not measured, landed(), measured whole if so (or as an open pull
\* request is), else landed False alone.  Landed is of the branch the
\* record named when list_tasks read it: if B named another since, of
\* that one, which may have had the task's commits or not.
HostMeasure ==
  /\ hstep = "measure"
  /\ \E said \in (IF rBranch = branch THEN {landed} ELSE BOOLEAN) :
     \/ /\ req \in {"M", "F"}
        /\ rLanded' = YesNo(said) /\ rDirty' = YesNo(dirty)
     \/ /\ req = "QP" /\ pushed /\ said
        /\ rLanded' = "yes" /\ rDirty' = IF LandedWithoutStats THEN "absent" ELSE YesNo(dirty)
     \/ /\ req = "QP" /\ pushed /\ ~said
        /\ rLanded' = "no" /\ rDirty' \in {"absent", YesNo(dirty)}
     \/ /\ req = "Q" \/ (req = "QP" /\ ~pushed)
        /\ rLanded' = "absent" /\ rDirty' = "absent"
  /\ hstep' = "reply"
  /\ UNCHANGED <<req, rStamp, rBranch, owedAtStart, newT, stale, pending, world, emacs>>

\* roost--owe-measuring: t, every task, swallows a list of IDs.
Owe(cur, what) == IF what = "all" \/ cur = "all" THEN "all" ELSE "ids"

\* `lost': nothing came of a list.  UNTRIED: dropped as stale, or never sent.
\* What it asked for is owed again; what was owed among it, which had its
\* one more try, is taken up by quiet polls only later (`roost--measures-due`).
\* Broken (GivesUpOwed), as before: what was owed goes.
LostOwed(untried) ==
  IF req \in {"Q", "QP"} THEN owed
  ELSE LET ids == IF req = "M" THEN "ids" ELSE "all" IN
       IF untried \/ owedAtStart = "none" \/ ~GivesUpOwed THEN Owe(owed, ids)
       \* first-try: what this list added to what was owed.
       ELSE IF owedAtStart = "all" /\ newT THEN Owe(owed, "ids")
       \* It asked for every task, which what was owed was only some of.
       ELSE IF ~newT /\ owedAtStart # "all" THEN Owe(owed, "all")
       ELSE owed   \* given up: it had its one more try

LostLater(untried) ==
  IF req \notin {"Q", "QP"} /\ ~untried /\ owedAtStart # "none" /\ ~GivesUpOwed THEN TRUE ELSE later

\* `finish': the request is over, and what it held goes.
Done == /\ req' = "none" /\ hstep' = "list" /\ rStamp' = 0 /\ rLanded' = "absent"
        /\ rDirty' = "absent" /\ rBranch' = 0 /\ owedAtStart' = "none" /\ newT' = FALSE
        /\ stale' = FALSE /\ pending' = "none"

\* `finish', with OW owed: a list asked for meanwhile goes now.
Finish(ow) == IF pending = "none" THEN Done /\ owed' = ow ELSE StartWith(pending, ow)

\* The reply comes back, to no action's reply since it went.  A measuring
\* list that took what was owed settles it, and polls take what is owed up
\* at once again.
Good ==
  LET changed == (rStamp # eStamp /\ ~StampUnwatched) \/ (rBranch # eBranch /\ ~BranchUnwatched) IN
  /\ ~stale
  /\ later' = IF req \in {"M", "F"} /\ owedAtStart # "none" THEN FALSE ELSE later
  /\ eStamp' = rStamp /\ eBranch' = rBranch
  /\ eLanded' = IF rLanded # "absent" THEN rLanded ELSE eLanded
  /\ eDirty' = IF rDirty # "absent" THEN rDirty ELSE eDirty
  /\ cleanStale' = IF rDirty # "absent" THEN FALSE
                   ELSE IF rLanded = "yes" /\ eLanded # "yes" THEN TRUE ELSE cleanStale
  \* A quiet poll measures what changed and what is owed, right after:
  \* a list of its IDs, or every task's when every one is owed.  What is
  \* owed only once it is due; what changed takes what is owed along.
  /\ IF req \in {"Q", "QP"} /\ (changed \/ (owed # "none" /\ ~later))
     THEN StartWith(IF changed \/ owed = "ids" THEN "ids" ELSE "all", owed)
     ELSE Done /\ UNCHANGED owed
  /\ UNCHANGED <<lost, act, world>>

Bad(untried) ==
  /\ lost < MaxLost /\ lost' = lost + 1
  /\ later' = LostLater(untried) /\ Finish(LostOwed(untried))
  /\ UNCHANGED <<world, act, eStamp, eLanded, eDirty, eBranch, cleanStale>>

\* The reply to a list that went before B's reply came: the revision moved
\* on, so it is dropped, as `lost' has it, untried.
Dropped ==
  /\ stale
  /\ Finish(LostOwed(TRUE))
  /\ UNCHANGED <<world, later, lost, act, eStamp, eLanded, eDirty, eBranch, cleanStale>>

Reply == hstep = "reply" /\ req # "none" /\ (Good \/ Bad(FALSE) \/ (~stale /\ Bad(TRUE)) \/ Dropped)

\* The reply to B: roost--act counts a revision, so a list that is out is
\* stale; the cache takes the record, and keeps what its host measured
\* against the branch before; and roost-retarget asks for a list of this
\* task, which waits for one that is out.
BReply ==
  /\ act = "sent" /\ act' = "none"
  /\ eBranch' = branch
  /\ IF req = "none"
     THEN IF RetargetUnmeasured THEN UNCHANGED <<request, owed>> ELSE StartWith("ids", owed)
     ELSE /\ stale' = TRUE /\ pending' = (IF RetargetUnmeasured THEN pending ELSE "ids")
          /\ UNCHANGED <<req, hstep, rStamp, rLanded, rDirty, rBranch, owedAtStart, newT, owed>>
  /\ UNCHANGED <<world, later, lost, eStamp, eLanded, eDirty, cleanStale>>

\* The time `roost--measures-due` names comes.
Due ==
  /\ later /\ later' = FALSE
  /\ UNCHANGED <<world, request, owed, lost, act, eStamp, eLanded, eDirty, eBranch, cleanStale>>

----------------------------------------------------------------------------
Init ==
  /\ landed = FALSE /\ dirty = FALSE /\ stamp = 0 /\ commits = 0 /\ merges = 0
  /\ pushed = FALSE /\ atTip = FALSE /\ branch = 0
  /\ req = "none" /\ hstep = "list" /\ rStamp = 0 /\ rLanded = "absent" /\ rDirty = "absent"
  /\ rBranch = 0 /\ owedAtStart = "none" /\ newT = FALSE /\ stale = FALSE /\ pending = "none"
  /\ owed = "none" /\ later = FALSE /\ lost = 0 /\ act = "none"
  /\ eStamp = 0 /\ eLanded = "absent" /\ eDirty = "absent" /\ eBranch = 0 /\ cleanStale = FALSE

Next ==
  \/ Commit \/ Edit \/ Push \/ HandMerge \/ ForgeMerge \/ Retarget
  \/ Poll("Q") \/ Poll("QP") \/ Full
  \/ HostList \/ HostMeasure \/ Reply \/ BReply \/ Due

\* Polls keep coming, and one asks the forge every two minutes; the host
\* answers; you needn't press g.
Fairness ==
  /\ SF_vars(Poll("Q")) /\ SF_vars(Poll("QP"))
  /\ WF_vars(HostList) /\ WF_vars(HostMeasure) /\ WF_vars(Reply) /\ WF_vars(BReply) /\ WF_vars(Due)

Spec == Init /\ [][Next]_vars /\ Fairness

----------------------------------------------------------------------------
(* Rules. *)

\* The task's cleanliness is never older than the news that it can be
\* retired: a merge found by a poll is measured whole.
CleanNoOlderThanLanded == Merged => ~cleanStale

\* A row that says "merged" of work with commits the merge lacks, or of a
\* branch the task merges into no more, stops saying so, once polls go on
\* and the host answers.
MergedHeals == (Merged /\ ~landed) ~> (~Merged \/ landed)
=============================================================================
