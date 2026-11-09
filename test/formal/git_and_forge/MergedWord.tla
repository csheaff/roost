--------------------------- MODULE MergedWord ---------------------------
(***************************************************************************)
(* Whether a task's row in Emacs says "merged", from what its host last    *)
(* measured, as polls, lists and their replies go.  roost.el:              *)
(* roost--refresh-host (its success lambda, `lost' and `finish'),          *)
(* roost--cache-task (fields a reply leaves out are kept),                 *)
(* roost--task-states, roost--landed, roost--merged-p and                  *)
(* roost--display-status; scripts/roost_remote.py: rpc's `list`, with      *)
(* git_stamp, add_git_stats and the landed() of a task asked about.        *)
(*                                                                         *)
(* One task on one host, its agent idle and seen, its worktree on its      *)
(* branch.  Whether its work is landed is as Landed.tla checks the host    *)
(* says it: here the host's word is the truth.  What Emacs knows is only   *)
(* what replies brought.                                                   *)
(***************************************************************************)
EXTENDS Naturals

CONSTANTS
  MaxCommits,           \* commits made in the worktree
  MaxMerges,            \* merges: by hand into the integration branch, or on the forge
  MaxLost,              \* replies failed, or dropped as stale, in all
  LandedWithoutStats,   \* broken: a poll asking the forge says landed, measuring nothing
  StampUnwatched,       \* broken: roost--task-states leaves out the Git stamp
  GivesUpOwed           \* broken: what was owed and lost again goes, as before

VARIABLES
  \* The worktree and the forge.
  landed,      \* the tip's commits are all merged
  dirty,       \* changes not committed
  stamp,       \* git_stamp: moves on commits and the integration branch's reflog
  commits, merges,
  pushed,      \* a pull request recorded, or the branch pushed: polls ask the forge
  atTip,       \* the branch on the forge is at the tip, so a merge there lands it
  \* One request of Emacs's at a time (roost--refreshing).
  req,         \* "none", "Q" quiet, "QP" quiet asking the forge, "M" a list of this task, "F" full
  hstep,       \* how far the host has got: "list", "measure", "reply"
  rStamp, rLanded, rDirty,   \* what the reply says; "absent" when left out
  owedAtStart, newT,         \* what roost--refresh-host's `owed' and `new' were
  owed,        \* roost--measures-owed for this host: "none", "ids" or "all"
  later,       \* roost--measures-due says quiet polls take what is owed up later
  lost,
  \* Emacs's cache.
  eStamp, eLanded, eDirty,
  cleanStale   \* landed came, and cleanliness is from before it

world == <<landed, dirty, stamp, commits, merges, pushed, atTip>>
request == <<req, hstep, rStamp, rLanded, rDirty, owedAtStart, newT>>
emacs == <<owed, later, lost, eStamp, eLanded, eDirty, cleanStale>>
vars == <<world, request, emacs>>

YesNo(b) == IF b THEN "yes" ELSE "no"

\* roost--merged-p, as roost--display-status puts it first: landed, as
\* measured with its Git statistics, and clean.
Merged == eLanded = "yes" /\ eDirty = "no"

----------------------------------------------------------------------------
(* The worktree and the forge. *)

\* A commit, by hand or by the agent: work the merge doesn't have.
Commit ==
  /\ commits < MaxCommits
  /\ commits' = commits + 1 /\ stamp' = stamp + 1
  /\ landed' = FALSE /\ dirty' = FALSE /\ atTip' = FALSE
  /\ UNCHANGED <<merges, pushed, request, emacs>>

\* An edit not staged moves no stamp.
Edit ==
  /\ ~dirty /\ dirty' = TRUE
  /\ UNCHANGED <<landed, stamp, commits, merges, pushed, atTip, request, emacs>>

Push ==
  /\ commits > 0 /\ ~atTip
  /\ pushed' = TRUE /\ atTip' = TRUE
  /\ UNCHANGED <<landed, dirty, stamp, commits, merges, request, emacs>>

\* You merge it into the integration branch: its reflog moves the stamp.
HandMerge ==
  /\ commits > 0 /\ ~landed /\ merges < MaxMerges
  /\ landed' = TRUE /\ merges' = merges + 1 /\ stamp' = stamp + 1
  /\ UNCHANGED <<dirty, commits, pushed, atTip, request, emacs>>

\* Its pull request merges on the forge: nothing here moves.
ForgeMerge ==
  /\ atTip /\ ~landed /\ merges < MaxMerges
  /\ landed' = TRUE /\ merges' = merges + 1
  /\ UNCHANGED <<dirty, stamp, commits, pushed, atTip, request, emacs>>

----------------------------------------------------------------------------
(* Emacs asks; the host answers. *)

\* The watch timer's quiet poll; now and then one asks the forge too.
Poll(kind) ==
  /\ req = "none"
  /\ req' = kind /\ hstep' = "list" /\ newT' = FALSE /\ owedAtStart' = "none"
  /\ UNCHANGED <<rStamp, rLanded, rDirty, world, emacs>>

\* g: a full refresh takes what is owed.
Full ==
  /\ req = "none"
  /\ req' = "F" /\ hstep' = "list" /\ newT' = FALSE
  /\ owedAtStart' = owed /\ owed' = "none"
  /\ UNCHANGED <<rStamp, rLanded, rDirty, world, later, lost, eStamp, eLanded, eDirty, cleanStale>>

\* rpc's `list`: the records, then git_stamp.
HostList ==
  /\ hstep = "list"
  /\ rStamp' = stamp /\ hstep' = "measure"
  /\ UNCHANGED <<req, rLanded, rDirty, owedAtStart, newT, world, emacs>>

\* add_git_stats for the tasks measured; for one the forge was asked about
\* and not measured, landed(), measured whole if so (or as an open pull
\* request is), else landed False alone.
HostMeasure ==
  /\ hstep = "measure"
  /\ \/ /\ req \in {"M", "F"}
        /\ rLanded' = YesNo(landed) /\ rDirty' = YesNo(dirty)
     \/ /\ req = "QP" /\ pushed /\ landed
        /\ rLanded' = "yes" /\ rDirty' = IF LandedWithoutStats THEN "absent" ELSE YesNo(dirty)
     \/ /\ req = "QP" /\ pushed /\ ~landed
        /\ rLanded' = "no" /\ rDirty' \in {"absent", YesNo(dirty)}
     \/ /\ req = "Q" \/ (req = "QP" /\ ~pushed)
        /\ rLanded' = "absent" /\ rDirty' = "absent"
  /\ hstep' = "reply"
  /\ UNCHANGED <<req, rStamp, owedAtStart, newT, world, emacs>>

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
        /\ rDirty' = "absent" /\ owedAtStart' = "none" /\ newT' = FALSE

\* The reply comes back.  A measuring list that took what was owed
\* settles it, and polls take what is owed up at once again.
Good ==
  LET changed == (rStamp # eStamp) /\ ~StampUnwatched IN
  /\ later' = IF req \in {"M", "F"} /\ owedAtStart # "none" THEN FALSE ELSE later
  /\ eStamp' = rStamp
  /\ eLanded' = IF rLanded # "absent" THEN rLanded ELSE eLanded
  /\ eDirty' = IF rDirty # "absent" THEN rDirty ELSE eDirty
  /\ cleanStale' = IF rDirty # "absent" THEN FALSE
                   ELSE IF rLanded = "yes" /\ eLanded # "yes" THEN TRUE ELSE cleanStale
  \* A quiet poll measures what changed and what is owed, right after:
  \* a list of its IDs, or every task's when every one is owed.  What is
  \* owed only once it is due; what changed takes what is owed along.
  /\ IF req \in {"Q", "QP"} /\ (changed \/ (owed # "none" /\ ~later))
     THEN LET ids == changed \/ owed = "ids" IN
          /\ req' = IF ids /\ owed # "all" THEN "M" ELSE "F"
          /\ hstep' = "list" /\ newT' = ids
          /\ owedAtStart' = owed /\ owed' = "none"
          /\ rStamp' = 0 /\ rLanded' = "absent" /\ rDirty' = "absent"
     ELSE Done /\ UNCHANGED owed
  /\ UNCHANGED <<lost, world>>

Bad(untried) ==
  /\ lost < MaxLost /\ lost' = lost + 1
  /\ owed' = LostOwed(untried) /\ later' = LostLater(untried) /\ Done
  /\ UNCHANGED <<world, eStamp, eLanded, eDirty, cleanStale>>

Reply == hstep = "reply" /\ req # "none" /\ (Good \/ Bad(FALSE) \/ Bad(TRUE))

\* The time `roost--measures-due` names comes.
Due ==
  /\ later /\ later' = FALSE
  /\ UNCHANGED <<world, request, owed, lost, eStamp, eLanded, eDirty, cleanStale>>

----------------------------------------------------------------------------
Init ==
  /\ landed = FALSE /\ dirty = FALSE /\ stamp = 0 /\ commits = 0 /\ merges = 0
  /\ pushed = FALSE /\ atTip = FALSE
  /\ req = "none" /\ hstep = "list" /\ rStamp = 0 /\ rLanded = "absent" /\ rDirty = "absent"
  /\ owedAtStart = "none" /\ newT = FALSE /\ owed = "none" /\ later = FALSE /\ lost = 0
  /\ eStamp = 0 /\ eLanded = "absent" /\ eDirty = "absent" /\ cleanStale = FALSE

Next ==
  \/ Commit \/ Edit \/ Push \/ HandMerge \/ ForgeMerge
  \/ Poll("Q") \/ Poll("QP") \/ Full
  \/ HostList \/ HostMeasure \/ Reply \/ Due

\* Polls keep coming, and one asks the forge every two minutes; the host
\* answers; you needn't press g.
Fairness ==
  /\ SF_vars(Poll("Q")) /\ SF_vars(Poll("QP"))
  /\ WF_vars(HostList) /\ WF_vars(HostMeasure) /\ WF_vars(Reply) /\ WF_vars(Due)

Spec == Init /\ [][Next]_vars /\ Fairness

----------------------------------------------------------------------------
(* Rules. *)

\* The task's cleanliness is never older than the news that it can be
\* retired: a merge found by a poll is measured whole.
CleanNoOlderThanLanded == Merged => ~cleanStale

\* A row that says "merged" of work with commits the merge lacks stops
\* saying so, once polls go on and the host answers.
MergedHeals == (Merged /\ ~landed) ~> (~Merged \/ landed)
=============================================================================
