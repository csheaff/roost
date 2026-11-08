---------------------------- MODULE AgentStatus ----------------------------
(* What an agent is doing, as the helper records it in a task's `status`,
   against what the agent is really doing.  docs/state-machines.md, "What an
   agent is doing"; scripts/roost_remote.py.

   Four senders write one field, each under the registry lock:
   - the agent's hooks (`update_hook`, the adapter's `observe`), which Claude
     and Codex wait for before they go on, so each lands before the agent's
     next event is made;
   - its OSC 7501 reports, relayed (`relay`), queued with the time they were
     read and recorded in order by a thread that waits for the lock
     (`program_status_recorder`, `apply_program_status`), so any number of
     later hooks can land first;
   - the poll (`list_tasks`): the crash check, and for an unrelayed Claude
     its guesses at Esc (`was_interrupted`) and approvals
     (`approved_command_running`);
   - the runner's end (`runner`), after `finish()` records what is queued.
   And you: stop (`stop`), resume (`spawn`), and tmux going away.

   The agent is one of Claude or Codex, relayed or not, chosen at the start.
   Each step of the agent is the sequence of hooks and reports the captures
   in test/captures show for it.  The rules are checked once nothing is in
   flight and the poll has looked: a status may lag while news travels, but
   not stay wrong. *)
EXTENDS Naturals, Sequences

CONSTANTS
    Agents,         \* subset of {"claude", "codex"}
    Modes,          \* subset of BOOLEAN: relayed (`programStatus`) or not
    MaxSteps,       \* your and the agent's steps, in all
    MaxRuns,        \* runs of the task: 1 + resumes
    LagPastTurnEnd, \* a report read before Claude's Stop or StopFailure hook
                    \* may still wait for the lock when that hook lands
    LateKinds,      \* Claude notifications whose hooks may land after the
                    \* agent moved on: subset of {"permission_prompt", "idle_prompt"}
    AfterFailure,   \* what Claude reports after StopFailure: subset of {"done", "idle", "error"}
    Break           \* "none", or one place where the model breaks the code
                    \* on purpose, to show a rule can fail

ACTIVE == {"starting", "running", "permission", "background"}
ENDED == {"stopped", "exited", "failed", "crashed"}
\* What the agent is really doing, while its process lives.
Alive == {"idle", "working", "asking", "background", "failedTurn"}
TurnEnds == {"Stop", "StopBg", "StopFailure"}

VARIABLES
    agent, relayed,     \* fixed at the start
    truth,              \* what the agent is doing: Alive, "exited", "gone", "stopped"
    cmd,                \* an approved Bash command runs, as `eval '...'`
    marker,             \* Claude's transcript ends in its interrupt marker,
                        \* written since `updatedAt` (`ClaudeAgent.interrupted`)
    script,             \* what the agent's current step has yet to send
    queue,              \* reports read by the relay, not yet recorded
    stray,              \* a hook in flight from an agent you stopped, or that tmux took
    late,               \* notifications in flight that Claude didn't wait for
    runnerPending,      \* the agent ended; its runner has yet to record it
    polled,             \* the poll has looked since the last change
    \* The task's record.
    status, dialog,     \* `status`; `lastEvent` == "Dialog"
    reqCmd,             \* `requestCommand`
    psRun,              \* `programStatusRun`
    endedRun,           \* `endedRun` == `runId`
    run,                \* `runId`
    sbc,                \* `statusBeforeCrash`
    steps

vars == <<agent, relayed, truth, cmd, marker, script, queue, stray, late,
          runnerPending, polled, status, dialog, reqCmd, psRun, endedRun,
          run, sbc, steps>>
rec == <<status, dialog, reqCmd, psRun, endedRun, run, sbc>>

H(e) == [kind |-> "hook", ev |-> e]
R(s) == [kind |-> "report", st |-> s]
NoHook == [ev |-> "none", run |-> 0]

\* `reports_turns`: Claude's reports say when a turn ends; Codex's hooks do.
Turns == agent = "claude"
\* A relayed run counts as one from its first report.
Relayed == psRun = run

\* Without the relay there are no reports.
Scr(items) == IF relayed THEN items ELSE SelectSeq(items, LAMBDA it : it.kind = "hook")

(* `ClaudeAgent.observe`, `CodexAgent.observe`: the status a hook says,
   given the status before, or "none". *)
Observe(e, cur) ==
  IF agent = "claude" THEN
    IF e = "SessionStart" THEN "ready"
    ELSE IF e \in {"UserPromptSubmit", "PreToolUse", "PostToolUse"} THEN "running"
    ELSE IF e = "PermissionRequest" THEN "permission"
    ELSE IF e = "Stop" THEN "ready"
    ELSE IF e = "StopBg" THEN "background"       \* Stop with background_tasks
    ELSE IF e = "StopFailure" THEN "failed"
    ELSE IF e = "SessionEndExit" THEN "exited"   \* reason prompt_input_exit
    ELSE IF e = "NotePermission" THEN "permission"
    ELSE IF e = "NoteIdle" THEN (IF cur \in {"starting", "running"} THEN "ready" ELSE "none")
    ELSE "none"                                  \* SessionEnd "other"
  ELSE
    IF e = "SessionStart" THEN "ready"
    ELSE IF e \in {"UserPromptSubmit", "PreToolUse", "PostToolUse"} THEN "running"
    ELSE IF e = "PermissionRequest" THEN "permission"
    ELSE IF e \in {"Stop", "Interrupt"} THEN "ready"
    ELSE "none"                                  \* SessionEnd

(* `beside_program_status`: the status a relayed agent's hook keeps. *)
Beside(s, before) ==
  IF Turns
  THEN IF Break # "no_turn_end_kept"
          /\ (s = "failed" \/ (s = "background" /\ before \in {"running", "ready"}))
       THEN s ELSE "none"
  ELSE IF s = "running" /\ before = "permission" THEN "none" ELSE s

(* `update_hook`, for hook E of run R.  Tool events are the main agent's,
   so `tool_answers` is true. *)
Hook(e, r) ==
  LET before == status
      s0 == Observe(e, before)
      s1 == IF s0 # "none" /\ endedRun THEN "none" ELSE s0          \* run_ended
      s2 == IF s1 = "none" THEN "none" ELSE IF Relayed THEN Beside(s1, before) ELSE s1
      after == IF s2 = "none" THEN before ELSE s2
      asks == s1 = "permission"
  IN IF ~((Break = "no_run_check" \/ r = run) /\ before # "stopped") \/ s1 = "none"
     THEN UNCHANGED <<status, dialog, reqCmd, queue, marker>>
     ELSE /\ status' = after
          /\ dialog' = IF s2 = "none" THEN dialog ELSE FALSE
          \* updatedAt moves with any status a hook records.
          /\ marker' = IF s2 = "none" THEN marker ELSE FALSE
          \* hookAt: reports read before it are older news.
          /\ queue' = IF s2 # "none" /\ ~Turns
                      THEN [i \in 1..Len(queue) |-> [queue[i] EXCEPT !.stale = TRUE]]
                      ELSE queue
          /\ reqCmd' = IF asks /\ e = "PermissionRequest" THEN TRUE
                       ELSE IF asks /\ before # "permission" THEN FALSE
                       ELSE IF asks THEN reqCmd
                       ELSE IF (~Relayed \/ ~Turns) /\ (after # "permission" \/ before # "permission")
                       THEN FALSE
                       ELSE reqCmd

(* `apply_program_status`, for report F. *)
Report(f) ==
  LET st == f.st
      s == status
      ch == IF f.stale /\ Break # "no_hookat" THEN "none"
            ELSE IF st = "working" /\ s # "running" /\ (Turns \/ s = "permission") THEN "running"
            ELSE IF st = "blocked" /\ s # "permission" /\ Break # "no_blocked" THEN "permission"
            ELSE IF st \in {"done", "idle"} /\ s = "permission" /\ dialog THEN "ready"
            ELSE IF st = "done" /\ s \in {"starting", "running", "permission"} THEN "ready"
            ELSE IF st = "idle" /\ s \in {"running", "permission"} THEN "ready"
            ELSE IF st = "idle" /\ s = "starting" THEN "ready"
            ELSE IF st = "error" /\ s # "failed" THEN "failed"
            ELSE "none"
      after == IF ch = "none" THEN s ELSE ch
  IN /\ psRun' = run
     /\ status' = after
     /\ dialog' = IF ch = "none" THEN dialog ELSE (st = "blocked" /\ s # "running")
     /\ marker' = IF ch = "none" THEN marker ELSE FALSE
     /\ reqCmd' = IF f.stale /\ Break # "no_hookat" THEN reqCmd
                  ELSE IF after = "permission" THEN reqCmd
                  ELSE IF s = "permission" \/ after # "running" THEN FALSE
                  ELSE reqCmd

StartScript ==
  IF agent = "claude" THEN Scr(<<H("SessionStart"), R("idle")>>)
  ELSE Scr(<<R("idle"), H("SessionStart")>>)

Init ==
  /\ agent \in Agents
  /\ relayed \in Modes
  /\ truth = "idle"
  /\ cmd = FALSE
  /\ marker = FALSE
  /\ script = StartScript
  /\ queue = <<>>
  /\ stray = NoHook
  /\ late = <<>>
  /\ runnerPending = FALSE
  /\ polled = FALSE
  /\ status = "starting"
  /\ dialog = FALSE
  /\ reqCmd = FALSE
  /\ psRun = 0
  /\ endedRun = FALSE
  /\ run = 1
  /\ sbc = "none"
  /\ steps = 0

-----------------------------------------------------------------------------
(* The agent's steps.  Each waits until the last has sent all it sends. *)

CanStep == script = <<>> /\ steps < MaxSteps /\ ~runnerPending

Step(t, items, c, m) ==
  /\ truth' = t
  /\ script' = Scr(items)
  /\ cmd' = c
  /\ marker' = m
  /\ steps' = steps + 1
  /\ polled' = FALSE
  /\ UNCHANGED <<agent, relayed, queue, stray, late, runnerPending, rec>>

Claude == agent = "claude"

Prompt ==   \* you send a prompt, or Claude wakes for its background work
  /\ CanStep /\ truth \in {"idle", "failedTurn", "background"}
  /\ Step("working", <<R("working"), H("UserPromptSubmit")>>, FALSE, FALSE)

Tool ==
  /\ CanStep /\ truth = "working" /\ ~cmd
  /\ Step("working", IF Claude THEN <<R("working"), H("PreToolUse"), H("PostToolUse")>>
                     ELSE <<H("PreToolUse"), H("PostToolUse")>>, FALSE, marker)

Ask ==      \* it asks to run a command
  /\ CanStep /\ truth = "working" /\ ~cmd
  /\ Step("asking", IF Claude THEN <<R("working"), H("PreToolUse"), R("blocked"), H("PermissionRequest")>>
                    ELSE <<H("PreToolUse"), H("PermissionRequest"), R("blocked")>>, FALSE, marker)

Notify ==   \* Claude's permission_prompt, a few seconds into the wait
  /\ CanStep /\ Claude /\ truth = "asking"
  /\ IF "permission_prompt" \in LateKinds
     THEN /\ late' = Append(late, [ev |-> "NotePermission", run |-> run])
          /\ steps' = steps + 1 /\ polled' = FALSE
          /\ UNCHANGED <<agent, relayed, truth, cmd, marker, script, queue, stray, runnerPending, rec>>
     ELSE Step("asking", <<H("NotePermission")>>, cmd, marker)

Remind ==   \* Claude's idle_prompt, a minute after its turn ended
  /\ CanStep /\ Claude /\ "idle_prompt" \in LateKinds /\ truth \in {"idle", "background", "failedTurn"}
  /\ late' = Append(late, [ev |-> "NoteIdle", run |-> run])
  /\ steps' = steps + 1 /\ polled' = FALSE
  /\ UNCHANGED <<agent, relayed, truth, cmd, marker, script, queue, stray, runnerPending, rec>>

Approve ==  \* you approve; the command runs, and its end comes later
  /\ CanStep /\ truth = "asking"
  /\ Step("working", <<R("working")>>, TRUE, marker)

CommandEnds ==
  /\ CanStep /\ truth = "working" /\ cmd
  /\ Step("working", <<H("PostToolUse")>>, FALSE, marker)

Decline ==  \* Esc at the request, or mid-turn
  /\ CanStep /\ truth \in {"asking", "working"}
  /\ Step("idle", IF Claude THEN <<R("idle")>> ELSE <<H("Interrupt"), R("idle")>>, FALSE, Claude)

End ==
  /\ CanStep /\ truth = "working" /\ ~cmd
  /\ Step("idle", IF Claude THEN <<H("Stop"), R("done")>> ELSE <<H("Stop"), R("idle")>>, FALSE, marker)

EndBackground ==
  /\ CanStep /\ Claude /\ truth = "working" /\ ~cmd
  /\ Step("background", <<H("StopBg"), R("done")>>, FALSE, marker)

Fail ==     \* the turn ends on an API error; the agent waits for you
  /\ CanStep /\ Claude /\ truth = "working" /\ ~cmd
  /\ \E x \in AfterFailure : Step("failedTurn", <<H("StopFailure"), R(x)>>, FALSE, marker)

Exit ==     \* /exit, C-c twice, C-d
  /\ CanStep /\ truth \in Alive
  /\ truth' = "exited"
  /\ script' = Scr(IF Claude THEN <<H("SessionEndExit")>> ELSE <<H("SessionEndOther")>>)
  /\ cmd' = FALSE
  /\ runnerPending' = TRUE
  /\ steps' = steps + 1 /\ polled' = FALSE
  /\ UNCHANGED <<agent, relayed, marker, queue, stray, late, rec>>

-----------------------------------------------------------------------------
(* Delivery. *)

Emit ==     \* the agent sends the next hook or report of its step
  /\ script # <<>>
  /\ LET it == Head(script) IN
       IF it.kind = "report"
       THEN /\ queue' = Append(queue, [st |-> it.st, stale |-> FALSE])
            /\ UNCHANGED <<status, dialog, reqCmd, marker>>
       ELSE /\ LagPastTurnEnd \/ ~Turns \/ it.ev \notin TurnEnds \/ queue = <<>>
            /\ Hook(it.ev, run)
  /\ script' = Tail(script)
  /\ polled' = FALSE
  /\ UNCHANGED <<agent, relayed, truth, cmd, stray, late, runnerPending, psRun, endedRun, run, sbc, steps>>

Record ==   \* the recorder takes the lock for the oldest report
  /\ queue # <<>>
  /\ queue' = Tail(queue)
  /\ IF status = "stopped" \/ (endedRun /\ Break # "no_drain")
     THEN UNCHANGED <<status, dialog, reqCmd, marker, psRun>>
     ELSE Report(Head(queue))
  /\ polled' = FALSE
  /\ UNCHANGED <<agent, relayed, truth, cmd, script, stray, late, runnerPending, endedRun, run, sbc, steps>>

DeliverLate ==
  /\ late # <<>>
  /\ Hook(Head(late).ev, Head(late).run)
  /\ late' = Tail(late)
  /\ polled' = FALSE
  /\ UNCHANGED <<agent, relayed, truth, cmd, script, stray, runnerPending, psRun, endedRun, run, sbc, steps>>

DeliverStray ==
  /\ stray # NoHook
  /\ Hook(stray.ev, stray.run)
  /\ stray' = NoHook
  /\ polled' = FALSE
  /\ UNCHANGED <<agent, relayed, truth, cmd, script, late, runnerPending, psRun, endedRun, run, sbc, steps>>

RunnerEnd ==   \* `finish()`, then the end, under the lock
  /\ runnerPending /\ script = <<>>
  /\ queue = <<>> \/ Break = "no_drain"
  /\ runnerPending' = FALSE
  /\ IF status # "stopped"
     THEN /\ status' = "exited" /\ endedRun' = TRUE /\ dialog' = FALSE /\ marker' = FALSE
     ELSE UNCHANGED <<status, endedRun, dialog, marker>>
  /\ polled' = FALSE
  /\ UNCHANGED <<agent, relayed, truth, cmd, script, queue, stray, late, reqCmd, psRun, run, sbc, steps>>

-----------------------------------------------------------------------------
(* The poll, `list_tasks`. *)

Live == truth \in Alive \/ (truth = "exited" /\ runnerPending)

Poll ==
  /\ IF Live /\ status = "crashed" THEN
       /\ status' = IF sbc = "none" THEN "ready" ELSE sbc
       /\ sbc' = "none" /\ marker' = FALSE
       /\ UNCHANGED <<dialog, reqCmd>>
     ELSE IF ~Live /\ status \notin ENDED THEN
       /\ status' = "crashed" /\ sbc' = status /\ marker' = FALSE
       /\ UNCHANGED <<dialog, reqCmd>>
     ELSE IF Claude /\ Live /\ ~Relayed /\ status \in {"running", "permission"} /\ marker
             /\ Break # "no_interrupt_guess" THEN
       /\ status' = "ready" /\ reqCmd' = FALSE /\ dialog' = FALSE /\ marker' = FALSE
       /\ UNCHANGED sbc
     ELSE IF Claude /\ Live /\ ~Relayed /\ status = "permission" /\ reqCmd /\ cmd THEN
       /\ status' = "running" /\ reqCmd' = FALSE /\ dialog' = FALSE /\ marker' = FALSE
       /\ UNCHANGED sbc
     ELSE UNCHANGED <<status, sbc, marker, dialog, reqCmd>>
  /\ polled' = TRUE
  /\ UNCHANGED <<agent, relayed, truth, cmd, script, queue, stray, late, runnerPending, psRun, endedRun, run, steps>>

-----------------------------------------------------------------------------
(* You, and tmux. *)

\* The hook the agent was sending, if any, may still land.
InFlight == IF script # <<>> /\ Head(script).kind = "hook" /\ stray = NoHook
            THEN {stray, [ev |-> Head(script).ev, run |-> run]} ELSE {stray}

StopTask ==   \* K: `stop`
  /\ steps < MaxSteps /\ status # "stopped"
  /\ status' = "stopped" /\ truth' = "stopped"
  /\ stray' \in InFlight
  /\ queue' = <<>> /\ script' = <<>> /\ cmd' = FALSE /\ runnerPending' = FALSE
  /\ steps' = steps + 1 /\ polled' = FALSE
  /\ UNCHANGED <<agent, relayed, marker, late, dialog, reqCmd, psRun, endedRun, run, sbc>>

TmuxGoes ==   \* tmux restarts: the runner dies with its agent, recording nothing
  /\ steps < MaxSteps /\ truth \in Alive
  /\ truth' = "gone"
  /\ stray' \in InFlight
  /\ queue' = <<>> /\ script' = <<>> /\ cmd' = FALSE
  /\ steps' = steps + 1 /\ polled' = FALSE
  /\ UNCHANGED <<agent, relayed, marker, late, runnerPending, rec>>

Resume ==     \* `resume`, `spawn`: a new run
  /\ steps < MaxSteps /\ run < MaxRuns
  /\ truth \in {"stopped", "gone"} \/ (truth = "exited" /\ ~runnerPending)
  /\ run' = run + 1
  /\ status' = "starting" /\ truth' = "idle"
  /\ script' = StartScript
  /\ endedRun' = FALSE /\ reqCmd' = FALSE /\ marker' = FALSE /\ cmd' = FALSE
  /\ queue' = <<>>
  /\ steps' = steps + 1 /\ polled' = FALSE
  /\ UNCHANGED <<agent, relayed, stray, late, runnerPending, dialog, psRun, sbc>>

Next ==
  \/ Prompt \/ Tool \/ Ask \/ Notify \/ Remind \/ Approve \/ CommandEnds
  \/ Decline \/ End \/ EndBackground \/ Fail \/ Exit
  \/ Emit \/ Record \/ DeliverLate \/ DeliverStray \/ RunnerEnd \/ Poll
  \/ StopTask \/ TmuxGoes \/ Resume

Spec == Init /\ [][Next]_vars

-----------------------------------------------------------------------------
(* The rules.  Settled: nothing in flight, and the poll has looked. *)

Settled ==
  /\ script = <<>> /\ queue = <<>> /\ stray = NoHook /\ late = <<>>
  /\ ~runnerPending /\ polled

\* An agent that asks you something shows `permission`.
AskingShown == Settled /\ truth = "asking" => status = "permission"

\* An agent at its prompt shows that it waits for you; one that ended shows so.
\* A gone agent may read `failed` or `exited`, not only `crashed`: a hook in
\* flight as tmux went (StopFailure, SessionEnd) lands after the crash check.
DoneShownDone ==
  Settled =>
    /\ truth \in {"idle", "failedTurn"} => status \in {"ready", "failed"}
    /\ truth = "exited" => status \in {"exited", "failed"}
    /\ truth = "gone" => status \in {"crashed", "failed", "exited"}

\* An agent at work never shows as waiting for you; while unsure whether a
\* request was answered, `permission` stands.
WorkNotWaiting == Settled /\ truth = "working" => status \in {"running", "permission"}

\* What a hook says of how a turn ended stands: an API error, or work left
\* in the background.
TurnEndKept ==
  Settled =>
    /\ truth = "failedTurn" => status = "failed"
    /\ truth = "background" => status = "background"

\* Always, not only when settled: the runner's end is final for its run,
\* and `stopped` until a resume.
EndsAreFinal ==
  /\ endedRun => status \in {"exited", "failed", "stopped"}
  /\ truth = "stopped" => status = "stopped"

TypeOK ==
  /\ status \in ACTIVE \cup ENDED \cup {"ready"}
  /\ truth \in Alive \cup {"exited", "gone", "stopped"}
=============================================================================
