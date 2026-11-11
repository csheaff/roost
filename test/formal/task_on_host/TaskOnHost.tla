---------------------------- MODULE TaskOnHost ----------------------------
(***************************************************************************)
(* One task on its host, as scripts/roost_remote.py finishes it: `retire`, *)
(* `merge` (retire with merge=True), `discard` and `forget`, each a helper *)
(* request of its own (`rpc`).  You may ask again while the first goes on, *)
(* as it does once Emacs stops waiting (`detach`, or ssh gone), and any    *)
(* request may die between two steps (a reboot, a dropped connection).     *)
(* Meanwhile the task's agent works until `stop` closes its pane, its      *)
(* hooks wait on the registry lock, and its own worktree, made in the      *)
(* repository's .claude/worktrees, may be one others work in too.          *)
(*                                                                         *)
(* Also, where a config says so (`Also`): you change the branch the task   *)
(* merges into (`retarget`); the task began as a fork of another, at a     *)
(* commit only that one's branch has; a fork is made of it, which reads    *)
(* its worktree; and its agent offers a task, which its record keeps.      *)
(*                                                                         *)
(* Git is cut down to sets of work: each unit is a file someone wrote,     *)
(* uncommitted, or the commit it became.  A unit that a step of Roost's   *)
(* takes from every folder and branch is lost, and `lost` says which      *)
(* request took it.                                                        *)
(*                                                                         *)
(* docs/state-machines.md, "A task on its host", has the machines this     *)
(* follows; .claude/skills/verify-task-on-host/SKILL.md says how to run it.*)
(***************************************************************************)
EXTENDS Naturals, FiniteSets

CONSTANTS
    MaxWork,        \* units of work anyone may make
    MaxRequests,    \* helper requests you may start for the task
    MaxCrashes,     \* requests that may die between two steps
    OthersWorkInX,  \* TRUE: something besides the task's agent works in the
                    \* worktree x: another session or task's agent, a process
                    \* the agent left running, the teardown command
    ReplaceInWindow, \* TRUE: you remove x, and someone makes another there,
                    \* between `remove_agent_worktrees` checking x by its
                    \* stamp and removing it
    Also,           \* what else may happen, each once, a set of:
                    \* "retarget": you change the branch the task merges into;
                    \* "forked": the task began as a fork of another task, at
                    \*   that task's commit, which only its branch has;
                    \* "fork reads": a fork is made of this task, and reads its worktree;
                    \* "offer": its agent offers a task;
                    \* "offer once asked": and may do so after you were
                    \*   asked, before the request stops it, as while you
                    \*   read the question
    Break           \* "none", or a guard turned off, for a TaskOnHost.<variant>.cfg:
                    \* "retire_force", "branch_no_cas", "no_safe_check",
                    \* "agent_only_went", "no_stamp", "agent_any_branch", "no_recount",
                    \* "x_not_seen_again", "x_stamp_first", "proof_goes",
                    \* "going_counts", "retarget_own", "fork_no_hold",
                    \* "fork_any_time", "offer_after_stop", "offers_not_named",
                    \* "offers_named_once"

Req   == 1..MaxRequests
Kinds == {"retire", "merge", "discard", "forget"}
Src   == 0      \* the commit of the task this one was forked from; work made
                \* while the model runs counts from 1

VARIABLES
    \* Git.
    tw,           \* the task's worktree: "there", "partly" (Git was removing it), "gone"
    twDirty,      \* uncommitted files in it
    tb,           \* the task's branch exists
    tbCommits,    \* its commits: since the task started, and Src for a fork
    mainCommits,  \* those `main` has, the branch the task merges into at first
    mine,         \* `mine`, a branch of yours that x may be switched to
    mineCommits,
    x,            \* the folder .claude/worktrees/x: "none", "ours" (the task's
                  \* agent made the worktree there now), "other" (someone else did)
    xOn,          \* the branch x has checked out: "wt" (worktree-x) or "mine"
    xDirty,
    wt,           \* the branch worktree-x exists
    wtCommits,
    src,          \* the branch of the task this one was forked from, which has
                  \* Src: "there"; "going", as its task's worktree goes, its
                  \* record `removing`; "gone", or never there
    \* The task's record, tasks/<id>.json.
    rec,          \* it exists
    status,       \* "active", "ready" or "stopped", as hooks last said; "ready"
                  \* is any status `require_finished` takes for an agent at
                  \* rest, as `permission` at Codex's plan menu (`asks_about_plan`)
    removing,     \* 0, or the request whose `removing` mark it holds
    retiringCommit, \* the checkpoint `retire` saved
    noted,        \* what hooks said of x: "none", "went" (in agentWorktrees),
                  \* "made" (in agentMade, its stamp in agentMadeAt)
    integ,        \* integrationBranch, the branch it merges into: "main",
                  \* "mine" or "wt"; "tb", its own, only with a guard broken
    base,         \* startCommit, as the commits the task's branch was made
                  \* with (`started_at`): `B` never moves it
    offers,       \* how many tasks its agent offers, in `offers`
    \* The agent's process, and the locks.
    agent,        \* "working", "idle", "stopped"
    regLock,      \* 0, or the request holding registry.lock
    wtLock,       \* 0, or the request holding tasks/<id>.removing exclusively
    reading,      \* a fork of this task: "no", none yet; "held", it reads the
                  \* worktree, holding tasks/<id>.removing shared; "unheld",
                  \* it reads it with no hold; "done"
    \* The requests.
    req,
    \* What the rules read.
    next,         \* the next unit of work
    crashes,
    lost,         \* <<unit, request, "commit" or "file">>: what Roost took
    xRemovedBy,   \* the requests that removed x
    removedOther, \* Roost removed what isn't the task's own
    retargeted,   \* you changed the branch it merges into
    readPartly,   \* a fork read its worktree as Git was removing it
    untold        \* a request took an offer made since it was asked

gitVars    == <<tw, twDirty, tb, tbCommits, mainCommits, mine, mineCommits, x, xOn, xDirty, wt, wtCommits>>
recordVars == <<rec, status, removing, retiringCommit, noted>>
ghostVars  == <<next, crashes, lost, xRemovedBy, removedOther>>
\* What `Also` brings.  Only the steps that say so change these: `Outside`
\* and `Roost` leave them as they are for every other step.
alsoVars   == <<src, integ, base, offers, reading, retargeted, readPartly, untold>>
vars       == <<gitVars, recordVars, agent, regLock, wtLock, req, ghostVars, alsoVars>>

-----------------------------------------------------------------------------
(* What Git holds, and what Roost reads of it.                              *)

Exists == (IF tw # "gone" THEN twDirty ELSE {}) \cup (IF tb THEN tbCommits ELSE {})
          \cup mainCommits \cup (IF mine THEN mineCommits ELSE {})
          \cup (IF x # "none" THEN xDirty ELSE {}) \cup (IF wt THEN wtCommits ELSE {})
          \cup (IF src # "gone" THEN {Src} ELSE {})

Committed == (IF tb THEN tbCommits ELSE {}) \cup mainCommits
             \cup (IF mine THEN mineCommits ELSE {}) \cup (IF wt THEN wtCommits ELSE {})
             \cup (IF src # "gone" THEN {Src} ELSE {})

\* A branch by its name here: whether it exists, and its commits.
There(b) == CASE b = "main" -> TRUE [] b = "mine" -> mine [] b = "wt" -> wt
            []   b = "src"  -> src # "gone" [] b = "tb" -> tb
On(b)    == CASE b = "main" -> mainCommits [] b = "mine" -> mineCommits [] b = "wt" -> wtCommits
            []   b = "src"  -> {Src}       [] b = "tb"   -> tbCommits

\* `is_as_made`: hooks said the agent made x, and the stamp noted in
\* agentMadeAt is Git's for the worktree there now.
AsMade == CASE Break = "no_stamp"        -> noted = "made" /\ x # "none"
          []   Break = "agent_only_went" -> noted # "none" /\ x # "none"
          []   OTHER                     -> noted = "made" /\ x = "ours"

\* `agent_work`'s ahead: commits at x's HEAD not on the task's branch.
Ahead == On(xOn) \ tbCommits

\* `branches_going`: the branch of another task whose worktree is going
\* keeps nothing for this one, as that task's request deletes it next.
\* Broken: `going_counts` counts on it, as the code did.
Going(b) == Break # "going_counts" /\ b = "src" /\ src = "going"

\* `discard_losses`: commits on the task's branch, and on its agent's, that
\* no other branch has, and files uncommitted in its worktree and its agent's.
Losses ==
    LET ours   == AsMade /\ xOn = "wt" /\ wt
        own    == (IF tb THEN tbCommits ELSE {}) \cup (IF ours THEN wtCommits ELSE {})
        others == mainCommits \cup (IF mine THEN mineCommits ELSE {})
                  \cup (IF wt /\ ~ours THEN wtCommits ELSE {})
                  \cup (IF There("src") /\ ~Going("src") THEN {Src} ELSE {})
        files  == (IF tw # "gone" THEN twDirty ELSE {}) \cup (IF AsMade THEN xDirty ELSE {})
    IN  [commits |-> Cardinality(own \ others), changes |-> Cardinality(files),
         x |-> IF AsMade THEN 1 ELSE 0]

\* `agent_worktree_seen`: what removing x would lose, to tell whether anyone
\* has worked there since it was listed: its commits not on the task's
\* branch, and its files.
Seen == <<Ahead, xDirty>>

\* `safe_to_delete`: the integration branch has every commit of the task's;
\* or it has none of its own, and sits where it started, and another branch
\* has that.  A branch that is going keeps nothing: another task's
\* (`Going`), and worktree-x, which goes with this one while x is the
\* worktree its agent made, whatever x is on now.  Broken: `proof_goes`
\* takes worktree-x for one that stays, as the code did.
Goes(b)  == Break # "proof_goes" /\ b = "wt" /\ AsMade
Kept(b, commit) == There(b) /\ ~Goes(b) /\ ~Going(b) /\ commit \subseteq On(b)
SafeToDelete(commit) == \/ commit = base /\ \E b \in {"main", "mine", "wt", "src"} : Kept(b, commit)
                        \/ Kept(integ, commit)

\* `integration_branch`: a merge needs the branch it merges into, and no
\* worktree but the primary checkout on it.
CanMergeInto(b) == There(b) /\ ~(b \in {"mine", "wt"} /\ x # "none" /\ xOn = b)

-----------------------------------------------------------------------------
NoRequest == [kind |-> "none", pc |-> "none", expect |-> {}, told |-> Losses, toldBranch |-> TRUE,
              toldOffers |-> 0, tip |-> {}, into |-> "main", commit |-> {}, hadBranch |-> FALSE,
              hadWorktree |-> FALSE, agents |-> FALSE, refused |-> FALSE, seen |-> <<{}, {}>>,
              stamped |-> FALSE]

Init ==
    /\ tw = "there" /\ twDirty = {} /\ tb = TRUE /\ mainCommits = {}
    \* A task starts at a commit main has; a fork, where its source stood.
    /\ \/ tbCommits = {} /\ base = {} /\ src = "gone"
       \/ "forked" \in Also /\ tbCommits = {Src} /\ base = {Src} /\ src = "there"
    /\ mine = TRUE /\ mineCommits = {}
    /\ x = "none" /\ xOn = "wt" /\ xDirty = {} /\ wt = FALSE /\ wtCommits = {}
    /\ rec = TRUE /\ status = "ready" /\ removing = 0 /\ retiringCommit = FALSE /\ noted = "none"
    /\ integ = "main" /\ offers = 0
    /\ agent = "idle" /\ regLock = 0 /\ wtLock = 0 /\ reading = "no"
    /\ req = [r \in Req |-> NoRequest]
    /\ next = 1 /\ crashes = 0 /\ lost = {} /\ xRemovedBy = {} /\ removedOther = FALSE
    /\ retargeted = FALSE /\ readPartly = FALSE /\ untold = FALSE

-----------------------------------------------------------------------------
(* Outside Roost: the agent works until its pane is closed, whatever its    *)
(* record says.  Its hooks take the registry lock; its writes don't.        *)

Outside(A) ==
    /\ A
    /\ UNCHANGED <<recordVars, regLock, wtLock, req, crashes, lost, xRemovedBy, removedOther, alsoVars>>

Write(var, more) == next <= MaxWork /\ var' = var \cup {next} /\ next' = next + 1 /\ more

YouPrompt == Outside(agent = "idle" /\ agent' = "working" /\ UNCHANGED <<gitVars, next>>)
TurnEnds  == Outside(agent = "working" /\ agent' = "idle" /\ UNCHANGED <<gitVars, next>>)

\* `update_hook`, under the registry lock, until the task is stopped.
Hook == /\ regLock = 0 /\ rec /\ agent # "stopped"
        /\ status' = (IF agent = "working" THEN "active" ELSE "ready")
        /\ status' # status
        /\ UNCHANGED <<gitVars, rec, removing, retiringCommit, noted, agent, regLock, wtLock, req,
                       ghostVars, alsoVars>>

Working == agent = "working"

AgentWrites == Outside(Working /\ tw = "there" /\ Write(twDirty,
    UNCHANGED <<tw, tb, tbCommits, mainCommits, mine, mineCommits, x, xOn, xDirty, wt, wtCommits, agent>>))

AgentCommits == Outside(Working /\ tw = "there" /\ tb /\ twDirty # {}
    /\ tbCommits' = tbCommits \cup twDirty /\ twDirty' = {}
    /\ UNCHANGED <<tw, tb, mainCommits, mine, mineCommits, x, xOn, xDirty, wt, wtCommits, agent, next>>)

\* EnterWorktree's "Created": Claude makes x on worktree-x, at the task's
\* commits (`worktree.baseRef: head` in its settings), and its hook says so
\* (`ClaudeAgent.made_worktree`), with the stamp Git wrote, once it has the
\* registry lock.  Made and noted as one: until noted, Roost leaves it
\* alone, which is the safe side.  Once.
AgentMakesX == /\ Working /\ regLock = 0 /\ rec /\ x = "none" /\ ~wt /\ noted = "none"
    /\ x' = "ours" /\ xOn' = "wt" /\ wt' = TRUE /\ wtCommits' = (IF tb THEN tbCommits ELSE {})
    /\ noted' = "made"
    /\ UNCHANGED <<tw, twDirty, tb, tbCommits, mainCommits, mine, mineCommits, xDirty,
                   rec, status, removing, retiringCommit, agent, regLock, wtLock, req, ghostVars, alsoVars>>

\* "Entered" one someone else made: a hook's cwd lies in it (`agent_worktree`).
AgentEntersX == /\ Working /\ regLock = 0 /\ rec /\ x = "other" /\ noted = "none"
    /\ noted' = "went"
    /\ UNCHANGED <<gitVars, rec, status, removing, retiringCommit, agent, regLock, wtLock, req, ghostVars,
                   alsoVars>>

\* The agent switches x to your branch: `git switch mine` there.
AgentSwitchesX == Outside(Working /\ x # "none" /\ noted # "none" /\ xOn = "wt" /\ xOn' = "mine"
    /\ UNCHANGED <<tw, twDirty, tb, tbCommits, mainCommits, mine, mineCommits, x, xDirty, wt, wtCommits,
                   agent, next>>)

WritesX == x # "none" /\ Write(xDirty,
    UNCHANGED <<tw, twDirty, tb, tbCommits, mainCommits, mine, mineCommits, x, xOn, wt, wtCommits, agent>>)

CommitsX == /\ x # "none" /\ xDirty # {} /\ (IF xOn = "wt" THEN wt ELSE mine)
    /\ (IF xOn = "wt" THEN wtCommits' = wtCommits \cup xDirty /\ UNCHANGED mineCommits
                      ELSE mineCommits' = mineCommits \cup xDirty /\ UNCHANGED wtCommits)
    /\ xDirty' = {}
    /\ UNCHANGED <<tw, twDirty, tb, tbCommits, mainCommits, mine, x, xOn, wt, agent, next>>

\* In x: its agent, once its hooks said it was there; anyone else only when
\* OthersWorkInX says so.  What they do in a worktree they made themselves
\* needs no model: OnlyItsOwn already says Roost never removes that one.
AgentInX == Working /\ noted # "none"
OtherInX == OthersWorkInX
AgentWritesX  == Outside(AgentInX /\ WritesX)
AgentCommitsX == Outside(AgentInX /\ CommitsX)
OtherWritesX  == Outside(OtherInX /\ WritesX)
OtherCommitsX == Outside(OtherInX /\ CommitsX)

\* A request is between checking x by its stamp and removing it.
InWindow == \E r \in Req : req[r].pc = "remove agents go"

\* Someone else makes a worktree at the empty path x.
OtherMakesX == Outside((ReplaceInWindow \/ ~InWindow) /\ x = "none" /\ ~wt /\ x' = "other" /\ xOn' = "wt" /\ wt' = TRUE
    /\ UNCHANGED <<tw, twDirty, tb, tbCommits, mainCommits, mine, mineCommits, xDirty, wtCommits, agent, next>>)

\* A request has checked that the task's commits are kept elsewhere, or
\* counted what a discard loses, and has yet to delete its branch.
Checked == \E r \in Req : req[r].pc \in {"stop", "remove begin", "remove agents", "remove agents go",
                                         "remove worktree", "worktree going", "remove end", "delete branch"}

\* You, or the agent's ExitWorktree, remove the agent's x and its branch:
\* not Roost's doing, so nothing it loses counts.  Nor, then, do you delete
\* that branch by hand while a request counts on it for the task's commits:
\* a discard does, once its agent switched x to another branch, as
\* worktree-x then stays.
YouRemoveX == Outside((ReplaceInWindow \/ ~InWindow)
    /\ ((Checked /\ xOn = "mine") => wtCommits \cap tbCommits = {})
    /\ x = "ours" /\ x' = "none" /\ xDirty' = {} /\ wt' = FALSE /\ wtCommits' = {}
    /\ xOn' = "wt"
    /\ UNCHANGED <<tw, twDirty, tb, tbCommits, mainCommits, mine, mineCommits, agent, next>>)

-----------------------------------------------------------------------------
(* What `Also` brings.                                                      *)

\* The steps no other may name: each says what it leaves as it was.
Aside(A, unchanged) ==
    /\ A
    /\ UNCHANGED <<gitVars, recordVars, agent, regLock, wtLock, req, ghostVars>>
    /\ UNCHANGED unchanged

\* `retarget`, whole under the registry lock: `require_not_removing` refuses
\* it while the task's worktree goes or Git merges it, and once a removal
\* was cut short.  It refuses the task's own branch, a task with no branch,
\* and a conversation, which is in no project: the runs with no retarget
\* are a conversation's.  The record's branch to merge into becomes b.
\* Where its commits count from, `baseCommit`, follows, which nothing here
\* reads: whether it ever committed goes by where its branch was made,
\* which stays.  Broken: `retarget_own` takes the task's own branch.
YouRetarget(b) == Aside(
    /\ "retarget" \in Also /\ ~retargeted
    /\ regLock = 0 /\ rec /\ wtLock = 0 /\ removing = 0
    /\ tb /\ There(b) /\ b # integ
    /\ integ' = b /\ retargeted' = TRUE,
    <<src, base, offers, reading, readPartly, untold>>)

Targets == {"main", "mine", "wt"} \cup (IF Break = "retarget_own" THEN {"tb"} ELSE {})

\* The task this one was forked from goes, its branch with it: you discard
\* it, which told you it would lose no commit, this task's branch having
\* its own.  Its request counts that under the registry lock, marks its
\* record `removing` and lets the lock go while its worktree goes; then,
\* under the lock again, it deletes its branch.  While this task's worktree
\* is going (`removing`), its branch keeps nothing for the source either:
\* that discard tells you of the commit, or is refused, so it is left out.
\* Broken: `going_counts` has each count on the other's branch, as before.
SourceBegins == Aside(
    /\ src = "there" /\ regLock = 0
    /\ Break = "going_counts" \/ removing = 0
    /\ src' = "going",
    <<integ, base, offers, reading, retargeted, readPartly, untold>>)

SourceEnds == Aside(
    /\ src = "going" /\ regLock = 0
    /\ src' = "gone",
    <<integ, base, offers, reading, retargeted, readPartly, untold>>)

\* `make_task` for a fork of this task (`conversation_to_fork`): under the
\* registry lock, `require_not_removing` refuses while its worktree goes or
\* Git merges it, and once a removal was cut short; then it keeps the
\* worktree, shared, while `snapshot` reads it with the registry lock let
\* go.  Broken: `fork_no_hold` asks without the registry lock and reads
\* with no hold, as the code did; `fork_any_time` reads one a removal cut
\* short left.
ForkBegins == Aside(
    /\ "fork reads" \in Also /\ reading = "no" /\ rec /\ tw # "gone" /\ wtLock = 0
    /\ Break = "fork_no_hold" \/ regLock = 0
    /\ Break = "fork_any_time" \/ removing = 0
    /\ reading' = (IF Break = "fork_no_hold" THEN "unheld" ELSE "held"),
    <<src, integ, base, offers, retargeted, readPartly, untold>>)

ForkReads == Aside(
    /\ reading \in {"held", "unheld"} /\ reading' = "done"
    /\ readPartly' = (readPartly \/ tw = "partly"),
    <<src, integ, base, offers, retargeted, untold>>)

\* A request was asked, and has yet to stop the agent or end.
Asked == \E r \in Req : req[r].pc \in {"start", "git merge", "after merge", "merge failed", "checkpoint", "stop"}

\* `propose_task`, from the agent's own server, which may be answering as
\* `stop` closes its pane: under the registry lock, refused once the task
\* is stopped.  One made once you were asked, as while you read the
\* question, is for a config with "offer once asked".  Broken:
\* `offer_after_stop` takes one from a stopped task.
AgentOffers == Aside(
    /\ "offer" \in Also /\ offers = 0 /\ regLock = 0 /\ rec
    /\ agent # "idle"
    /\ Break = "offer_after_stop" \/ status # "stopped"
    /\ "offer once asked" \in Also \/ ~Asked \/ agent = "stopped"
    /\ offers' = 1,
    <<src, integ, base, reading, retargeted, readPartly, untold>>)

-----------------------------------------------------------------------------
(* You ask, or ask again: a new helper process, whatever the last one is   *)
(* doing.  For `m`, Emacs sends the branch as it last measured it          *)
(* (`expect`); for `x`, what the dry run told you (`expect`, `told`).      *)
(* Both were read before you answered, so the agent works on between.      *)
(* The question names the offers that go with the task, and the request    *)
(* says which those were (`toldOffers`, its `offers`).                     *)

Ask(r, k) ==
    /\ req[r].pc = "none" /\ rec /\ \A q \in 1..(r - 1) : req[q].pc # "none"
    \* a dry run is refused while a request, or a fork, holds the worktree
    /\ k = "discard" => (wtLock = 0 /\ reading # "held")
    /\ req' = [req EXCEPT ![r] = [NoRequest EXCEPT !.kind = k, !.pc = "start", !.expect = tbCommits,
                                  !.told = Losses, !.toldBranch = tb, !.toldOffers = offers]]
    /\ UNCHANGED <<gitVars, recordVars, agent, regLock, wtLock, ghostVars, alsoVars>>

-----------------------------------------------------------------------------
(* The helper's requests.  Each step is what a request does between two    *)
(* moments another could act.  Steps that hold the registry lock are      *)
(* atomic to other requests and hooks, not to the agent's writes; nothing *)
(* a step reads is trusted later but what Git checks again.               *)

Go(r, pc)  == req' = [req EXCEPT ![r].pc = pc]
Refuse(r)  == req' = [req EXCEPT ![r].pc = "done", ![r].refused = TRUE] /\ regLock' = 0

\* Every step of a request goes through here, which notes what it took.
\* The record's offers go with it (`Store.remove`).
Roost(r, A) ==
    /\ A
    /\ UNCHANGED <<next, crashes, src, integ, base, offers, reading, retargeted, readPartly>>
    /\ lost' = lost \cup {<<u, r, IF u \in Committed THEN "commit" ELSE "file">> : u \in Exists \ Exists'}
    /\ xRemovedBy' = IF x # "none" /\ x' = "none" THEN xRemovedBy \cup {r} ELSE xRemovedBy
    /\ removedOther' = (removedOther \/ (x = "other" /\ x' = "none") \/ (mine /\ ~mine'))
    /\ untold' = (untold \/ (rec /\ ~rec' /\ offers > req[r].toldOffers))

\* `put_back_removed`: a removal cut short took only tracked files, which
\* Git checks out again.
PutBack == IF removing # 0 /\ tw = "partly" THEN "there" ELSE tw

\* `rpc` takes the lock and reads the record (`read_to_act_on`), and
\* `require_not_removing` refuses every finishing action while a request
\* holds the worktree lock, or a fork holds it shared.
Held == wtLock # 0 \/ reading = "held"

\* `require_offers_named`, under the registry lock: a request is refused
\* while the record holds an offer its question didn't name.  The lock is
\* kept from there until the record goes, or the agent is stopped and can
\* offer no more; but for a merge, which lets it go while Git merges, and
\* asks again after.  Broken: `offers_not_named` has the request say
\* nothing of them, as the code did; `offers_named_once` doesn't ask again
\* after the merge.
Named(r)      == Break = "offers_not_named" \/ offers <= req[r].toldOffers
NamedAgain(r) == Break = "offers_named_once" \/ Named(r)

Start(r) == req[r].pc = "start" /\ regLock = 0 /\ Roost(r,
    LET k == req[r].kind IN
    \/ /\ ~rec \/ Held
       /\ Refuse(r)
       /\ UNCHANGED <<gitVars, recordVars, agent, wtLock>>
    \* `forget`: refused while the agent's pane is live, or for an offer
    \* the question didn't name; Git is left alone.
    \/ /\ rec /\ ~Held /\ k = "forget"
       /\ IF agent # "stopped" \/ ~Named(r) THEN Refuse(r) /\ UNCHANGED rec
          ELSE rec' = FALSE /\ Go(r, "done") /\ UNCHANGED regLock
       /\ UNCHANGED <<gitVars, status, removing, retiringCommit, noted, agent, wtLock>>
    \* `retire`, steps 3 to 6: `require_finished`, `require_offers_named`,
    \* `put_back_removed`, `require_clean`, `require_agent_work_kept`; for
    \* `merge`, a branch gone or moved from `expect`, then `merging_in`,
    \* `integration_branch` and `integrating`, with the branch it merges
    \* into as the record has it now (`into`).
    \/ /\ rec /\ ~Held /\ k \in {"retire", "merge"}
       /\ LET doMerge == k = "merge" /\ (tb \/ ~retiringCommit)
              ok      == /\ status # "active"
                         /\ Named(r)
                         /\ PutBack = "gone" \/ twDirty = {}
                         /\ ~(AsMade /\ (xDirty # {} \/ Ahead # {}))
                         /\ doMerge => (tb /\ tbCommits = req[r].expect /\ CanMergeInto(integ))
          IN /\ tw' = PutBack
             /\ CASE ~ok      -> Refuse(r) /\ UNCHANGED wtLock
                []   doMerge  -> /\ req' = [req EXCEPT ![r].pc = "git merge", ![r].tip = tbCommits,
                                            ![r].into = integ, ![r].hadBranch = tb,
                                            ![r].hadWorktree = (PutBack # "gone")]
                                 /\ wtLock' = r /\ regLock' = 0
                []   OTHER    -> /\ req' = [req EXCEPT ![r].pc = "checkpoint", ![r].hadBranch = tb,
                                            ![r].hadWorktree = (PutBack # "gone")]
                                 /\ regLock' = r /\ UNCHANGED wtLock
       /\ UNCHANGED <<twDirty, tb, tbCommits, mainCommits, mine, mineCommits, x, xOn, xDirty, wt,
                      wtCommits, recordVars, agent>>
    \* `discard`: the branch moved from `expect`, more to lose than you
    \* were told (`told`), or an offer the question didn't name, refuses;
    \* else `stop`.  Counted and stopped in one step: an agent's write in
    \* the moment between is left out.
    \/ /\ rec /\ ~Held /\ k = "discard"
       /\ LET now == Losses
              ok  == /\ tb = req[r].toldBranch /\ (tb => tbCommits = req[r].expect)
                     /\ Break # "no_recount" =>
                          /\ now.commits <= req[r].told.commits
                          /\ now.changes <= req[r].told.changes
                          /\ now.x <= req[r].told.x
                     /\ Named(r)
          IN /\ tw' = PutBack
             /\ IF ~ok
                THEN Refuse(r) /\ UNCHANGED <<agent, status>>
                ELSE /\ agent' = "stopped" /\ status' = "stopped" /\ regLock' = r
                     /\ req' = [req EXCEPT ![r].pc = "remove begin", ![r].commit = tbCommits,
                                           ![r].hadBranch = tb, ![r].hadWorktree = (PutBack # "gone"),
                                           ![r].agents = AsMade, ![r].seen = Seen]
       /\ UNCHANGED <<twDirty, tb, tbCommits, mainCommits, mine, mineCommits, x, xOn, xDirty, wt,
                      wtCommits, rec, removing, retiringCommit, noted, wtLock>>
    )

\* `merge_task`, without the registry lock: Git merges the tip it was given
\* into the branch it was given, or fails if that has gone meanwhile.
GitMerge(r) == req[r].pc = "git merge" /\ Roost(r,
    LET b == req[r].into IN
    /\ mainCommits' = (IF b = "main" THEN mainCommits \cup req[r].tip ELSE mainCommits)
    /\ mineCommits' = (IF b = "mine" /\ mine THEN mineCommits \cup req[r].tip ELSE mineCommits)
    /\ wtCommits' = (IF b = "wt" /\ wt THEN wtCommits \cup req[r].tip ELSE wtCommits)
    /\ Go(r, IF There(b) THEN "after merge" ELSE "merge failed")
    /\ UNCHANGED <<tw, twDirty, tb, tbCommits, mine, x, xOn, xDirty, wt, recordVars, agent, regLock, wtLock>>)

\* Back under the lock: its mark cleared, the worktree let go, the record
\* read again, and the agent, its offers and its worktree checked again.
AfterMerge(r) == req[r].pc = "after merge" /\ regLock = 0 /\ Roost(r,
    /\ wtLock' = 0
    /\ IF ~rec \/ status = "active" \/ ~NamedAgain(r) \/ (req[r].hadWorktree /\ tw # "gone" /\ twDirty # {})
       THEN Refuse(r)
       ELSE Go(r, "checkpoint") /\ regLock' = r
    /\ UNCHANGED <<gitVars, recordVars, agent>>)

\* The merge failed: the worktree let go, and the request ends.
MergeFailed(r) == req[r].pc = "merge failed" /\ regLock = 0 /\ Roost(r,
    /\ wtLock' = 0 /\ Refuse(r)
    /\ UNCHANGED <<gitVars, recordVars, agent>>)

\* Step 7: the branch read, `safe_to_delete`, `retiringCommit` saved.
\* Broken: `no_safe_check` deletes a branch with commits nothing else has.
Checkpoint(r) == req[r].pc = "checkpoint" /\ Roost(r,
    /\ IF req[r].hadBranch /\ ~(Break = "no_safe_check" \/ SafeToDelete(tbCommits))
       THEN Refuse(r) /\ UNCHANGED retiringCommit
       ELSE /\ req' = [req EXCEPT ![r].pc = "stop", ![r].commit = tbCommits]
            /\ retiringCommit' = (retiringCommit \/ req[r].hadBranch)
            /\ UNCHANGED regLock
    /\ UNCHANGED <<gitVars, rec, status, removing, noted, agent, wtLock>>)

\* Step 8, `stop`; then which of its agent's worktrees go: those made, as
\* made, ahead by nothing and clean, as `agent_work` says now, and what
\* they hold (`seen`).
Stop(r) == req[r].pc = "stop" /\ Roost(r,
    /\ agent' = "stopped" /\ status' = "stopped"
    /\ req' = [req EXCEPT ![r].pc = "remove begin", ![r].agents = (AsMade /\ Ahead = {} /\ xDirty = {}),
                           ![r].seen = Seen]
    /\ UNCHANGED <<gitVars, rec, removing, retiringCommit, noted, regLock, wtLock>>)

\* `remove_worktrees`: the worktree lock, its own `removing` mark, and the
\* registry lock let go for the slow part.  With nothing to remove, none.
RemoveBegin(r) == req[r].pc = "remove begin" /\ Roost(r,
    /\ CASE ~req[r].hadWorktree /\ ~req[r].agents -> Go(r, "delete branch") /\ UNCHANGED <<removing, regLock, wtLock>>
       []   Held       -> Refuse(r) /\ UNCHANGED <<removing, wtLock>>
       []   OTHER      -> Go(r, "remove agents") /\ wtLock' = r /\ removing' = r /\ regLock' = 0
    /\ UNCHANGED <<gitVars, rec, status, retiringCommit, noted, agent>>)

\* `remove_agent_worktrees`, after the teardown command, with no lock held:
\* `worktree_at` finds a worktree at x; then, as one step, what x holds read
\* again (`agent_worktree_seen`) and compared with what was listed, its
\* stamp checked (`is_as_made`), and `git worktree remove --force --force`,
\* and the branch read deleted if it is worktree-x, at the commit read.
\* Those are a few Git calls apart in the code, its stamp last, just
\* before the removal; what is written there in those milliseconds is
\* lost, as with `require_clean` and the removal of the task's worktree.
\* Broken: `x_not_seen_again` removes x whatever it holds now;
\* `x_stamp_first` checks the stamp at the first step, before the window,
\* as the code did; `agent_any_branch` deletes whichever branch x was on.
RemoveAgents(r) == req[r].pc = "remove agents" /\ Roost(r,
    /\ IF req[r].agents /\ x # "none"
       THEN req' = [req EXCEPT ![r].pc = "remove agents go", ![r].stamped = AsMade]
       ELSE Go(r, "remove worktree")
    /\ UNCHANGED <<gitVars, recordVars, agent, regLock, wtLock>>)

RemoveAgentsGo(r) == req[r].pc = "remove agents go" /\ Roost(r,
    /\ IF /\ x # "none"
          /\ IF Break = "x_stamp_first" THEN req[r].stamped ELSE AsMade
          /\ Break = "x_not_seen_again" \/ Seen = req[r].seen
       THEN /\ x' = "none" /\ xDirty' = {} /\ xOn' = "wt"
            /\ IF xOn = "wt"
               THEN IF wt
                    THEN wt' = FALSE /\ wtCommits' = {} /\ UNCHANGED <<mine, mineCommits>>
                    ELSE UNCHANGED <<wt, wtCommits, mine, mineCommits>>
               ELSE /\ UNCHANGED <<wt, wtCommits>>
                    /\ IF Break = "agent_any_branch" THEN mine' = FALSE /\ mineCommits' = {}
                       ELSE UNCHANGED <<mine, mineCommits>>
       ELSE UNCHANGED <<x, xDirty, xOn, wt, wtCommits, mine, mineCommits>>
    /\ Go(r, "remove worktree")
    /\ UNCHANGED <<tw, twDirty, tb, tbCommits, mainCommits, recordVars, agent, regLock, wtLock>>)

\* The task's worktree: `discard` forces it; `retire` checks it is clean
\* again (`require_clean`, and Git's own refusal without --force).  Broken:
\* `retire_force` forces it for retire too.  Git deletes it file by file,
\* so it is "partly" there until done.
RemoveWorktree(r) == req[r].pc = "remove worktree" /\ Roost(r,
    /\ CASE ~req[r].hadWorktree \/ tw = "gone" -> Go(r, "remove end") /\ UNCHANGED <<tw, twDirty>>
       []   req[r].kind = "discard" \/ Break = "retire_force" \/ twDirty = {} ->
                tw' = "partly" /\ twDirty' = {} /\ Go(r, "worktree going")
       []   OTHER -> req' = [req EXCEPT ![r].pc = "remove end", ![r].refused = TRUE] /\ UNCHANGED <<tw, twDirty>>
    /\ UNCHANGED <<tb, tbCommits, mainCommits, mine, mineCommits, x, xOn, xDirty, wt, wtCommits,
                   recordVars, agent, regLock, wtLock>>)

WorktreeGoing(r) == req[r].pc = "worktree going" /\ Roost(r,
    /\ tw' = "gone" /\ Go(r, "remove end")
    /\ UNCHANGED <<twDirty, tb, tbCommits, mainCommits, mine, mineCommits, x, xOn, xDirty, wt,
                   wtCommits, recordVars, agent, regLock, wtLock>>)

\* Back under the lock: only its own mark cleared, the worktree let go.
RemoveEnd(r) == req[r].pc = "remove end" /\ regLock = 0 /\ Roost(r,
    /\ removing' = (IF removing = r THEN 0 ELSE removing)
    /\ wtLock' = 0
    /\ IF req[r].refused THEN Refuse(r) ELSE Go(r, "delete branch") /\ regLock' = r
    /\ UNCHANGED <<gitVars, rec, status, retiringCommit, noted, agent>>)

\* Step 10, `delete_branch`: refused while a worktree has it checked out,
\* and only while it is at the commit verified (`update-ref -d` with the old
\* value).  Broken: `branch_no_cas` deletes it wherever it is.
DeleteBranch(r) == req[r].pc = "delete branch" /\ Roost(r,
    /\ CASE ~req[r].hadBranch \/ ~tb -> Go(r, "remove record") /\ UNCHANGED <<tb, tbCommits, regLock>>
       []   tw = "gone" /\ (tbCommits = req[r].commit \/ Break = "branch_no_cas") ->
                tb' = FALSE /\ tbCommits' = {} /\ Go(r, "remove record") /\ UNCHANGED regLock
       []   OTHER -> Refuse(r) /\ UNCHANGED <<tb, tbCommits>>
    /\ UNCHANGED <<tw, twDirty, mainCommits, mine, mineCommits, x, xOn, xDirty, wt, wtCommits,
                   recordVars, agent, wtLock>>)

\* Step 11, `Store.remove`, and the reply.
RemoveRecord(r) == req[r].pc = "remove record" /\ Roost(r,
    /\ rec' = FALSE /\ regLock' = 0 /\ Go(r, "done")
    /\ UNCHANGED <<gitVars, status, removing, retiringCommit, noted, agent, wtLock>>)

\* A reboot or a dropped connection kills a request between two steps:
\* the kernel lets go of its locks; its marks stay on disk.
Crash(r) ==
    /\ req[r].pc \notin {"none", "done", "dead"} /\ crashes < MaxCrashes
    /\ req' = [req EXCEPT ![r].pc = "dead"]
    /\ regLock' = (IF regLock = r THEN 0 ELSE regLock)
    /\ wtLock' = (IF wtLock = r THEN 0 ELSE wtLock)
    /\ crashes' = crashes + 1
    /\ UNCHANGED <<gitVars, recordVars, agent, next, lost, xRemovedBy, removedOther, alsoVars>>

Request(r) == \/ Start(r) \/ GitMerge(r) \/ AfterMerge(r) \/ MergeFailed(r) \/ Checkpoint(r) \/ Stop(r)
              \/ RemoveBegin(r) \/ RemoveAgents(r) \/ RemoveAgentsGo(r) \/ RemoveWorktree(r) \/ WorktreeGoing(r)
              \/ RemoveEnd(r) \/ DeleteBranch(r) \/ RemoveRecord(r) \/ Crash(r)

\* Every request has ended, and nothing else need happen.
Finished == \A r \in Req : req[r].pc \in {"none", "done", "dead"}

Next ==
    \/ YouPrompt \/ TurnEnds \/ Hook \/ AgentWrites \/ AgentCommits
    \/ AgentMakesX \/ AgentEntersX \/ AgentSwitchesX \/ AgentWritesX \/ AgentCommitsX
    \/ OtherMakesX \/ OtherWritesX \/ OtherCommitsX \/ YouRemoveX
    \/ \E b \in Targets : YouRetarget(b)
    \/ SourceBegins \/ SourceEnds \/ ForkBegins \/ ForkReads \/ AgentOffers
    \/ \E r \in Req, k \in Kinds : Ask(r, k)
    \/ \E r \in Req : Request(r)
    \/ Finished /\ UNCHANGED vars

Spec == Init /\ [][Next]_vars

-----------------------------------------------------------------------------
(* The rules.                                                               *)

\* Roost deletes work only when you discard its task: retire, merge,
\* forget, a retry or a crash never take a file or a commit from every
\* folder and branch.
KeptButByDiscard == \A l \in lost : req[l[2]].kind = "discard"

\* Finishing takes only what is the task's own: never your branch `mine`,
\* and never a worktree at x its agent didn't make, or one made there since.
OnlyItsOwn == mine /\ ~removedOther

\* A discard takes no more of each kind than its dry run told you.
DiscardTold ==
    \A r \in Req : req[r].kind = "discard" =>
        /\ Cardinality({l \in lost : l[2] = r /\ l[3] = "commit"}) <= req[r].told.commits
        /\ Cardinality({l \in lost : l[2] = r /\ l[3] = "file"}) <= req[r].told.changes
        /\ r \in xRemovedBy => req[r].told.x >= 1

\* A fork starts from the task's worktree as it stood, never from one Git
\* was removing.
ForkWhole == ~readPartly

\* The offers that go with a task are those its question named.
OffersTold == ~untold
=============================================================================
