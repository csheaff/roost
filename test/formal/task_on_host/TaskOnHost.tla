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
    Break           \* "none", or a guard turned off, for a TaskOnHost.<variant>.cfg:
                    \* "retire_force", "branch_no_cas", "no_safe_check",
                    \* "agent_only_went", "no_stamp", "agent_any_branch", "no_recount",
                    \* "x_not_seen_again", "x_stamp_first"

Req   == 1..MaxRequests
Kinds == {"retire", "merge", "discard", "forget"}

VARIABLES
    \* Git.
    tw,           \* the task's worktree: "there", "partly" (Git was removing it), "gone"
    twDirty,      \* uncommitted files in it
    tb,           \* the task's branch exists
    tbCommits,    \* its commits since the task started
    mainCommits,  \* those the integration branch has
    mine,         \* `mine`, a branch of yours that x may be switched to
    mineCommits,
    x,            \* the folder .claude/worktrees/x: "none", "ours" (the task's
                  \* agent made the worktree there now), "other" (someone else did)
    xOn,          \* the branch x has checked out: "wt" (worktree-x) or "mine"
    xDirty,
    wt,           \* the branch worktree-x exists
    wtCommits,
    \* The task's record, tasks/<id>.json.
    rec,          \* it exists
    status,       \* "active", "ready" or "stopped", as hooks last said
    removing,     \* 0, or the request whose `removing` mark it holds
    retiringCommit, \* the checkpoint `retire` saved
    noted,        \* what hooks said of x: "none", "went" (in agentWorktrees),
                  \* "made" (in agentMade, its stamp in agentMadeAt)
    \* The agent's process, and the locks.
    agent,        \* "working", "idle", "stopped"
    regLock,      \* 0, or the request holding registry.lock
    wtLock,       \* 0, or the request holding tasks/<id>.removing exclusively
    \* The requests.
    req,
    \* What the rules read.
    next,         \* the next unit of work
    crashes,
    lost,         \* <<unit, request, "commit" or "file">>: what Roost took
    xRemovedBy,   \* the requests that removed x
    removedOther  \* Roost removed what isn't the task's own

gitVars    == <<tw, twDirty, tb, tbCommits, mainCommits, mine, mineCommits, x, xOn, xDirty, wt, wtCommits>>
recordVars == <<rec, status, removing, retiringCommit, noted>>
ghostVars  == <<next, crashes, lost, xRemovedBy, removedOther>>
vars       == <<gitVars, recordVars, agent, regLock, wtLock, req, ghostVars>>

-----------------------------------------------------------------------------
(* What Git holds, and what Roost reads of it.                              *)

Exists == (IF tw # "gone" THEN twDirty ELSE {}) \cup (IF tb THEN tbCommits ELSE {})
          \cup mainCommits \cup (IF mine THEN mineCommits ELSE {})
          \cup (IF x # "none" THEN xDirty ELSE {}) \cup (IF wt THEN wtCommits ELSE {})

Committed == (IF tb THEN tbCommits ELSE {}) \cup mainCommits
             \cup (IF mine THEN mineCommits ELSE {}) \cup (IF wt THEN wtCommits ELSE {})

\* `is_as_made`: hooks said the agent made x, and the stamp noted in
\* agentMadeAt is Git's for the worktree there now.
AsMade == CASE Break = "no_stamp"        -> noted = "made" /\ x # "none"
          []   Break = "agent_only_went" -> noted # "none" /\ x # "none"
          []   OTHER                     -> noted = "made" /\ x = "ours"

\* `agent_work`'s ahead: commits at x's HEAD not on the task's branch.
Ahead == (IF xOn = "wt" THEN wtCommits ELSE mineCommits) \ tbCommits

\* `discard_losses`: commits on the task's branch, and on its agent's, that
\* no other branch has, and files uncommitted in its worktree and its agent's.
Losses ==
    LET ours   == AsMade /\ xOn = "wt" /\ wt
        own    == (IF tb THEN tbCommits ELSE {}) \cup (IF ours THEN wtCommits ELSE {})
        others == mainCommits \cup (IF mine THEN mineCommits ELSE {})
                  \cup (IF wt /\ ~ours THEN wtCommits ELSE {})
        files  == (IF tw # "gone" THEN twDirty ELSE {}) \cup (IF AsMade THEN xDirty ELSE {})
    IN  [commits |-> Cardinality(own \ others), changes |-> Cardinality(files),
         x |-> IF AsMade THEN 1 ELSE 0]

\* `agent_worktree_seen`: what removing x would lose, to tell whether anyone
\* has worked there since it was listed: its commits not on the task's
\* branch, and its files.
Seen == <<Ahead, xDirty>>

\* `safe_to_delete`: the integration branch has every commit of the task's,
\* or it has none, and sits where it started.
SafeToDelete(commit) == commit \subseteq mainCommits

-----------------------------------------------------------------------------
NoRequest == [kind |-> "none", pc |-> "none", expect |-> {}, told |-> Losses, toldBranch |-> TRUE,
              tip |-> {}, commit |-> {}, hadBranch |-> FALSE, hadWorktree |-> FALSE,
              agents |-> FALSE, refused |-> FALSE, seen |-> <<{}, {}>>, stamped |-> FALSE]

Init ==
    /\ tw = "there" /\ twDirty = {} /\ tb = TRUE /\ tbCommits = {} /\ mainCommits = {}
    /\ mine = TRUE /\ mineCommits = {}
    /\ x = "none" /\ xOn = "wt" /\ xDirty = {} /\ wt = FALSE /\ wtCommits = {}
    /\ rec = TRUE /\ status = "ready" /\ removing = 0 /\ retiringCommit = FALSE /\ noted = "none"
    /\ agent = "idle" /\ regLock = 0 /\ wtLock = 0
    /\ req = [r \in Req |-> NoRequest]
    /\ next = 1 /\ crashes = 0 /\ lost = {} /\ xRemovedBy = {} /\ removedOther = FALSE

-----------------------------------------------------------------------------
(* Outside Roost: the agent works until its pane is closed, whatever its    *)
(* record says.  Its hooks take the registry lock; its writes don't.        *)

Outside(A) ==
    /\ A
    /\ UNCHANGED <<recordVars, regLock, wtLock, req, crashes, lost, xRemovedBy, removedOther>>

Write(var, more) == next <= MaxWork /\ var' = var \cup {next} /\ next' = next + 1 /\ more

YouPrompt == Outside(agent = "idle" /\ agent' = "working" /\ UNCHANGED <<gitVars, next>>)
TurnEnds  == Outside(agent = "working" /\ agent' = "idle" /\ UNCHANGED <<gitVars, next>>)

\* `update_hook`, under the registry lock, until the task is stopped.
Hook == /\ regLock = 0 /\ rec /\ agent # "stopped"
        /\ status' = (IF agent = "working" THEN "active" ELSE "ready")
        /\ status' # status
        /\ UNCHANGED <<gitVars, rec, removing, retiringCommit, noted, agent, regLock, wtLock, req,
                       ghostVars>>

Working == agent = "working"

AgentWrites == Outside(Working /\ tw = "there" /\ Write(twDirty,
    UNCHANGED <<tw, tb, tbCommits, mainCommits, mine, mineCommits, x, xOn, xDirty, wt, wtCommits, agent>>))

AgentCommits == Outside(Working /\ tw = "there" /\ tb /\ twDirty # {}
    /\ tbCommits' = tbCommits \cup twDirty /\ twDirty' = {}
    /\ UNCHANGED <<tw, tb, mainCommits, mine, mineCommits, x, xOn, xDirty, wt, wtCommits, agent, next>>)

\* EnterWorktree's "Created": Claude makes x on worktree-x, and its hook
\* says so (`ClaudeAgent.made_worktree`), with the stamp Git wrote, once it
\* has the registry lock.  Made and noted as one: until noted, Roost leaves
\* it alone, which is the safe side.  Once.
AgentMakesX == /\ Working /\ regLock = 0 /\ rec /\ x = "none" /\ ~wt /\ noted = "none"
    /\ x' = "ours" /\ xOn' = "wt" /\ wt' = TRUE /\ noted' = "made"
    /\ UNCHANGED <<tw, twDirty, tb, tbCommits, mainCommits, mine, mineCommits, xDirty, wtCommits,
                   rec, status, removing, retiringCommit, agent, regLock, wtLock, req, ghostVars>>

\* "Entered" one someone else made: a hook's cwd lies in it (`agent_worktree`).
AgentEntersX == /\ Working /\ regLock = 0 /\ rec /\ x = "other" /\ noted = "none"
    /\ noted' = "went"
    /\ UNCHANGED <<gitVars, rec, status, removing, retiringCommit, agent, regLock, wtLock, req, ghostVars>>

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

\* You, or the agent's ExitWorktree, remove the agent's x and its branch:
\* not Roost's doing, so nothing it loses counts.
YouRemoveX == Outside((ReplaceInWindow \/ ~InWindow) /\ x = "ours" /\ x' = "none" /\ xDirty' = {} /\ wt' = FALSE /\ wtCommits' = {}
    /\ xOn' = "wt"
    /\ UNCHANGED <<tw, twDirty, tb, tbCommits, mainCommits, mine, mineCommits, agent, next>>)

-----------------------------------------------------------------------------
(* You ask, or ask again: a new helper process, whatever the last one is   *)
(* doing.  For `m`, Emacs sends the branch as it last measured it          *)
(* (`expect`); for `x`, what the dry run told you (`expect`, `told`).      *)
(* Both were read before you answered, so the agent works on between.      *)

Ask(r, k) ==
    /\ req[r].pc = "none" /\ rec /\ \A q \in 1..(r - 1) : req[q].pc # "none"
    /\ k = "discard" => wtLock = 0   \* a dry run is refused while a request holds the worktree
    /\ req' = [req EXCEPT ![r] = [NoRequest EXCEPT !.kind = k, !.pc = "start", !.expect = tbCommits,
                                  !.told = Losses, !.toldBranch = tb]]
    /\ UNCHANGED <<gitVars, recordVars, agent, regLock, wtLock, ghostVars>>

-----------------------------------------------------------------------------
(* The helper's requests.  Each step is what a request does between two    *)
(* moments another could act.  Steps that hold the registry lock are      *)
(* atomic to other requests and hooks, not to the agent's writes; nothing *)
(* a step reads is trusted later but what Git checks again.               *)

Go(r, pc)  == req' = [req EXCEPT ![r].pc = pc]
Refuse(r)  == req' = [req EXCEPT ![r].pc = "done", ![r].refused = TRUE] /\ regLock' = 0

\* Every step of a request goes through here, which notes what it took.
Roost(r, A) ==
    /\ A
    /\ lost' = lost \cup {<<u, r, IF u \in Committed THEN "commit" ELSE "file">> : u \in Exists \ Exists'}
    /\ xRemovedBy' = IF x # "none" /\ x' = "none" THEN xRemovedBy \cup {r} ELSE xRemovedBy
    /\ removedOther' = (removedOther \/ (x = "other" /\ x' = "none") \/ (mine /\ ~mine'))
    /\ UNCHANGED <<next, crashes>>

\* `put_back_removed`: a removal cut short took only tracked files, which
\* Git checks out again.
PutBack == IF removing # 0 /\ tw = "partly" THEN "there" ELSE tw

\* `rpc` takes the lock and reads the record (`read_to_act_on`), and
\* `require_not_removing` refuses every finishing action while a request
\* holds the worktree lock.
Start(r) == req[r].pc = "start" /\ regLock = 0 /\ Roost(r,
    LET k == req[r].kind IN
    \/ /\ ~rec \/ wtLock # 0
       /\ Refuse(r)
       /\ UNCHANGED <<gitVars, recordVars, agent, wtLock>>
    \* `forget`: refused while the agent's pane is live; Git is left alone.
    \/ /\ rec /\ wtLock = 0 /\ k = "forget"
       /\ IF agent # "stopped" THEN Refuse(r) /\ UNCHANGED rec
          ELSE rec' = FALSE /\ Go(r, "done") /\ UNCHANGED regLock
       /\ UNCHANGED <<gitVars, status, removing, retiringCommit, noted, agent, wtLock>>
    \* `retire`, steps 3 to 6: `require_finished`, `put_back_removed`,
    \* `require_clean`, `require_agent_work_kept`; for `merge`, a branch
    \* gone or moved from `expect`, then `merging_in` and `integrating`.
    \/ /\ rec /\ wtLock = 0 /\ k \in {"retire", "merge"}
       /\ LET doMerge == k = "merge" /\ (tb \/ ~retiringCommit)
              ok      == /\ status # "active"
                         /\ PutBack = "gone" \/ twDirty = {}
                         /\ ~(AsMade /\ (xDirty # {} \/ Ahead # {}))
                         /\ doMerge => (tb /\ tbCommits = req[r].expect)
          IN /\ tw' = PutBack
             /\ CASE ~ok      -> Refuse(r) /\ UNCHANGED wtLock
                []   doMerge  -> /\ req' = [req EXCEPT ![r].pc = "git merge", ![r].tip = tbCommits,
                                            ![r].hadBranch = tb, ![r].hadWorktree = (PutBack # "gone")]
                                 /\ wtLock' = r /\ regLock' = 0
                []   OTHER    -> /\ req' = [req EXCEPT ![r].pc = "checkpoint", ![r].hadBranch = tb,
                                            ![r].hadWorktree = (PutBack # "gone")]
                                 /\ regLock' = r /\ UNCHANGED wtLock
       /\ UNCHANGED <<twDirty, tb, tbCommits, mainCommits, mine, mineCommits, x, xOn, xDirty, wt,
                      wtCommits, recordVars, agent>>
    \* `discard`: the branch moved from `expect`, or more to lose than you
    \* were told (`told`), refuses; else `stop`.  Counted and stopped in one
    \* step: an agent's write in the moment between is left out.
    \/ /\ rec /\ wtLock = 0 /\ k = "discard"
       /\ LET now == Losses
              ok  == /\ tb = req[r].toldBranch /\ (tb => tbCommits = req[r].expect)
                     /\ Break # "no_recount" =>
                          /\ now.commits <= req[r].told.commits
                          /\ now.changes <= req[r].told.changes
                          /\ now.x <= req[r].told.x
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

\* `merge_task`, without the registry lock: Git merges the tip it was given.
GitMerge(r) == req[r].pc = "git merge" /\ Roost(r,
    /\ mainCommits' = mainCommits \cup req[r].tip
    /\ Go(r, "after merge")
    /\ UNCHANGED <<tw, twDirty, tb, tbCommits, mine, mineCommits, x, xOn, xDirty, wt, wtCommits,
                   recordVars, agent, regLock, wtLock>>)

\* Back under the lock: its mark cleared, the worktree let go, the record
\* read again, and the agent and its worktree checked again.
AfterMerge(r) == req[r].pc = "after merge" /\ regLock = 0 /\ Roost(r,
    /\ wtLock' = 0
    /\ IF ~rec \/ status = "active" \/ (req[r].hadWorktree /\ tw # "gone" /\ twDirty # {})
       THEN Refuse(r)
       ELSE Go(r, "checkpoint") /\ regLock' = r
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
       []   wtLock # 0 -> Refuse(r) /\ UNCHANGED <<removing, wtLock>>
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
    /\ UNCHANGED <<gitVars, recordVars, agent, next, lost, xRemovedBy, removedOther>>

Request(r) == \/ Start(r) \/ GitMerge(r) \/ AfterMerge(r) \/ Checkpoint(r) \/ Stop(r)
              \/ RemoveBegin(r) \/ RemoveAgents(r) \/ RemoveAgentsGo(r) \/ RemoveWorktree(r) \/ WorktreeGoing(r)
              \/ RemoveEnd(r) \/ DeleteBranch(r) \/ RemoveRecord(r) \/ Crash(r)

\* Every request has ended, and nothing else need happen.
Finished == \A r \in Req : req[r].pc \in {"none", "done", "dead"}

Next ==
    \/ YouPrompt \/ TurnEnds \/ Hook \/ AgentWrites \/ AgentCommits
    \/ AgentMakesX \/ AgentEntersX \/ AgentSwitchesX \/ AgentWritesX \/ AgentCommitsX
    \/ OtherMakesX \/ OtherWritesX \/ OtherCommitsX \/ YouRemoveX
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
=============================================================================
