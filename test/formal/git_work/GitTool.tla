------------------------------- MODULE GitTool -------------------------------
(***************************************************************************)
(* An example tool on GitWork.tla: how one finishes a task, step by step, *)
(* with an agent and you acting between the steps and a crash possible    *)
(* between any two.  You ask it to finish a task (its work has landed) or *)
(* to discard it.  Its steps, in order:                                   *)
(*                                                                         *)
(*   stop    stop the task's agent                                         *)
(*   check   for a finish: the work has landed and nothing else is there;  *)
(*           noting the branch's tip                                       *)
(*   backup  only if Backup: everything into refs/backup/<task>            *)
(*   rmwt    `git worktree remove`; `--force` for a discard                *)
(*   rmbr    delete the branch if the tool made it, only from the tip it   *)
(*           noted (`update-ref -d <ref> <old>`), as -D: its own check     *)
(*           went by content, which -d can't                               *)
(*   unrec   drop the tool's record of the task                            *)
(*                                                                         *)
(* A refusal or a crash leaves the record, and you may ask again.  Breaks  *)
(* names the shortcuts the tools surveyed take; each .cfg but GitTool.cfg  *)
(* turns some on and must fail, on the rule its first line names.          *)
(***************************************************************************)
EXTENDS GitWork, Sequences

CONSTANTS
    MaxCrashes,
    Backup,         \* TRUE: the tool keeps a backup ref before removing
    Breaks          \* a set of shortcuts:
                    \* "no_stop"        leaves the agent running while it finishes
                    \* "ignore_dirty"   finishes with uncommitted files, as a
                    \*                  check that counts only commits does
                    \* "status_only"    counts what `git status` shows, not ignored files
                    \* "tips_only"      counts commits on the tip, not reflog-only ones
                    \* "force_remove"   `git worktree remove --force` on a finish too
                    \* "no_cas"         deletes the branch wherever it now points
                    \* "any_branch"     deletes the branch the task ran on, made or not
                    \* "ancestry"       takes landed to mean main has the tip
                    \* "branch_d"       deletes the branch with -d
                    \* "unrecord_first" drops its record before removing

VARIABLES
    rec,            \* [Tasks -> BOOLEAN]: the tool's record of the task
    pc,             \* [Tasks -> 0..Len(Steps)+1]: 0 idle, then the step it is at
    mode,           \* [Tasks -> {"finish", "discard"}]
    agent,          \* [Tasks -> {"running", "stopped"}]
    noted,          \* [Tasks -> SUBSET Unit]: the tip `check` saw
    crashes,
    refusedLanded   \* it refused to finish work that had landed, nothing else there

toolVars == <<rec, pc, mode, agent, noted, crashes, refusedLanded>>
vars == <<gitVars, toolVars>>

Steps == IF "unrecord_first" \in Breaks
         THEN <<"stop", "check", "unrec", "backup", "rmwt", "rmbr">>
         ELSE <<"stop", "check", "backup", "rmwt", "rmbr", "unrec">>
Done == Len(Steps) + 1

Init ==
    /\ GitInit
    /\ rec = [t \in Tasks |-> TRUE]
    /\ pc = [t \in Tasks |-> 0]
    /\ mode = [t \in Tasks |-> "finish"]
    /\ agent = [t \in Tasks |-> "running"]
    /\ noted = [t \in Tasks |-> {}]
    /\ crashes = 0
    /\ refusedLanded = FALSE

-----------------------------------------------------------------------------
(* The agent and you.                                                      *)

Agent(t) ==
    /\ agent[t] = "running"
    /\ (GitWrite(t) \/ GitWriteIgnored(t) \/ GitCommit(t) \/ GitReset(t))
    /\ UNCHANGED toolVars

\* The work lands, by a merge or a squash, here or on the forge.
Land(t) == (GitMerge(t) \/ GitSquash(t)) /\ UNCHANGED toolVars

\* You start the agent again, after a refusal or a crash.
Resume(t) ==
    /\ rec[t] /\ pc[t] = 0 /\ agent[t] = "stopped"
    /\ agent' = [agent EXCEPT ![t] = "running"]
    /\ UNCHANGED <<gitVars, rec, pc, mode, noted, crashes, refusedLanded>>

Finish(t) ==
    /\ rec[t] /\ pc[t] = 0
    /\ pc' = [pc EXCEPT ![t] = 1] /\ mode' = [mode EXCEPT ![t] = "finish"]
    /\ UNCHANGED <<gitVars, rec, agent, noted, crashes, refusedLanded>>

Discard(t) ==
    /\ rec[t] /\ pc[t] = 0
    /\ pc' = [pc EXCEPT ![t] = 1] /\ mode' = [mode EXCEPT ![t] = "discard"]
    /\ UNCHANGED <<gitVars, rec, agent, noted, crashes, refusedLanded>>

-----------------------------------------------------------------------------
(* The tool's steps.                                                       *)

Advance(t) == pc' = [pc EXCEPT ![t] = @ + 1]
Refuse(t)  == pc' = [pc EXCEPT ![t] = 0]

LandedBy(t) == IF "ancestry" \in Breaks THEN Merged(t) ELSE Landed(t)
NothingElse(t) ==
    /\ dirty[t] = {} \/ "ignore_dirty" \in Breaks
    /\ ignored[t] = {} \/ "status_only" \in Breaks
    /\ reflog[t] \subseteq main \/ "tips_only" \in Breaks

Stop(t) ==
    /\ agent' = IF "no_stop" \in Breaks THEN agent ELSE [agent EXCEPT ![t] = "stopped"]
    /\ Advance(t)
    /\ UNCHANGED <<gitVars, rec, mode, noted, crashes, refusedLanded>>

\* A discard counts what it throws away here, after the agent stopped:
\* work made after you were told is not yours to lose.
Check(t) ==
    /\ noted' = [noted EXCEPT ![t] = brUnits[t]]
    /\ CASE mode[t] = "discard"
             -> Advance(t) /\ GitDiscard(t) /\ UNCHANGED refusedLanded
        []  LandedBy(t) /\ NothingElse(t)
             -> Advance(t) /\ UNCHANGED <<gitVars, refusedLanded>>
        []  OTHER
             -> Refuse(t) /\ UNCHANGED gitVars
                /\ refusedLanded' = (refusedLanded \/ (Landed(t) /\ NothingElse(t)))
    /\ UNCHANGED <<rec, mode, agent, crashes>>

TakeBackup(t) ==
    /\ IF Backup THEN GitBackup(t) ELSE UNCHANGED gitVars
    /\ Advance(t)
    /\ UNCHANGED <<rec, mode, agent, noted, crashes, refusedLanded>>

RemoveWorktree(t) ==
    LET force == mode[t] = "discard" \/ "force_remove" \in Breaks
    IN  /\ CASE wt[t] = "gone"                -> Advance(t) /\ UNCHANGED gitVars
            []  GitCanRemoveWorktree(t, force) -> Advance(t) /\ GitRemoveWorktree(t)
            []  OTHER                          -> Refuse(t) /\ UNCHANGED gitVars
        /\ UNCHANGED <<rec, mode, agent, noted, crashes, refusedLanded>>

RemoveBranch(t) ==
    LET force  == "branch_d" \notin Breaks
        cas    == "no_cas" \notin Breaks
        leave  == ~br[t] \/ (~owned[t] /\ "any_branch" \notin Breaks)
    IN  /\ CASE leave                                    -> Advance(t) /\ UNCHANGED <<gitVars, refusedLanded>>
            []  GitCanDeleteBranch(t, force, cas, noted[t])     -> Advance(t) /\ GitDeleteBranch(t)
                                                            /\ UNCHANGED refusedLanded
            []  OTHER -> Refuse(t) /\ UNCHANGED gitVars
                         /\ refusedLanded' = (refusedLanded \/ Landed(t))
        /\ UNCHANGED <<rec, mode, agent, noted, crashes>>

Unrecord(t) ==
    /\ rec' = [rec EXCEPT ![t] = FALSE]
    /\ Advance(t)
    /\ UNCHANGED <<gitVars, mode, agent, noted, crashes, refusedLanded>>

Step(t) ==
    /\ pc[t] \in 1..Len(Steps)
    /\ CASE Steps[pc[t]] = "stop"   -> Stop(t)
        []  Steps[pc[t]] = "check"  -> Check(t)
        []  Steps[pc[t]] = "backup" -> TakeBackup(t)
        []  Steps[pc[t]] = "rmwt"   -> RemoveWorktree(t)
        []  Steps[pc[t]] = "rmbr"   -> RemoveBranch(t)
        []  Steps[pc[t]] = "unrec"  -> Unrecord(t)

\* The tool dies between two steps.  What Git did stays done.
Crash(t) ==
    /\ pc[t] \in 2..Len(Steps) /\ crashes < MaxCrashes
    /\ pc' = [pc EXCEPT ![t] = 0]
    /\ crashes' = crashes + 1
    /\ UNCHANGED <<gitVars, rec, mode, agent, noted, refusedLanded>>

Next == \E t \in Tasks :
    Agent(t) \/ Land(t) \/ Resume(t) \/ Finish(t) \/ Discard(t) \/ Step(t) \/ Crash(t)

Spec == Init /\ [][Next]_vars

-----------------------------------------------------------------------------
(* The rules GitWork gives, NoLoss and OnlyOwn, and two of the tool's own. *)

\* P4: work squashed or rebased onto main counts as landed.
SquashLands == ~refusedLanded

\* P5: whatever a crash leaves, the tool still knows of it and can finish.
NoOrphan == \A t \in Tasks :
    (~rec[t] /\ pc[t] \in {0, Done}) => (wt[t] = "gone" /\ (~br[t] \/ ~owned[t]))
=============================================================================
