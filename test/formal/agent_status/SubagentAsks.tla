---------------------------- MODULE SubagentAsks ----------------------------
(* Who asks, when more than one agent can: the agent you talk to in a Claude
   Code session, and its subagents, which work on beside it and after its
   turn ends, and ask from there, their prompt on your screen.
   docs/state-machines.md, "A task's request"; scripts/roost_remote.py:
   `ClaudeAgent.observe`, `update_hook`, `tool_answers`, `claude_answers`.

   AgentStatus.tla has one agent and every order its hooks, reports, the
   poll and the runner can land in.  This has several agents and one
   sender: an unrelayed Claude's hooks, each recorded before the next is
   made, as Claude waits for them.  So a step here is an event and what
   `update_hook` makes of it, and the rules hold after every step.

   What it leaves out: reports (a relayed Claude's turn that ends beside a
   subagent's request reads `background`, as the changelog says); Esc and a
   declined request of the lead's, which the poll reads from the transcript;
   MCP questions; a request only a notification names; teammates
   (`worker_permission_prompt`) and `agent_needs_input`, of which no capture
   says when Claude sends them. *)
EXTENDS Naturals, FiniteSets

CONSTANTS
    Subs,       \* the subagents, as {"a", "b"}
    SaysLeft,   \* subset of BOOLEAN: whether Claude's Stop says what its turn
                \* left in the background (`background_tasks`); older ones don't
    MaxSteps,
    Break       \* "none", or one place where the model breaks the code

Lead == "lead"
Who == Subs \cup {Lead}

VARIABLES
    lead,       \* the agent you talk to: "idle", "working", "asking"
    sub,        \* each subagent: "none", "working", "asking"
    says,       \* whether this Claude's Stop says what is left
    \* The task's record.
    status,     \* "ready", "running", "permission", "background"
    call,       \* `requestCall`: "none"; who asked, with its tool; or
                \* "several": dict(agent="another agent")
    beside,     \* `requestCall`'s `beside`: one of several that ask is not
                \* the lead
    ended,      \* the lead's turn has just ended
    steps

vars == <<lead, sub, says, status, call, beside, ended, steps>>

Asking == {w \in Subs : sub[w] = "asking"}
Left == {w \in Subs : sub[w] # "none"}          \* `background_tasks`, at a Stop

(* `ClaudeAgent.observe`: the status event E says, given the status now. *)
Observe(e) ==
  IF e \in {"UserPromptSubmit", "SelfPrompt", "PreToolUse", "PostToolUse"} THEN "running"
  ELSE IF e \in {"PermissionRequest", "Note"} THEN "permission"   \* Note: permission_prompt
  ELSE IF e = "Stop" THEN (IF says /\ Left # {} THEN "background" ELSE "ready")
  ELSE IF e \in {"PostToolUseFailure", "SubagentStop"} THEN (IF status = "permission" THEN "running" ELSE "none")
  ELSE "none"

(* `tool_answers`: whether event E of agent W, about the tool that was
   asked for (SAME) or another, says the request is over. *)
ToolAnswers(e, w, same) ==
  IF e \notin {"PreToolUse", "PostToolUse", "PostToolUseFailure"} THEN TRUE
  ELSE IF call = "none" THEN w = Lead
  ELSE IF call # w THEN FALSE                   \* "several" is nobody's
  ELSE e = "PreToolUse" \/ same

(* `claude_answers`.  A subagent's request outlasts the lead's turn, unless
   that turn says nothing is left, and a prompt Claude sends itself.  So
   does one of several requests, if a subagent's is among them.  Broken:
   `several_end_with_turn` lets the lead's turn end several, as before;
   `sub_ends_with_turn` lets it end a subagent's, as before that. *)
Outlasts ==
  \/ call \in Subs /\ Break # "sub_ends_with_turn"
  \/ call = "several" /\ beside /\ Break \notin {"several_end_with_turn", "sub_ends_with_turn"}

Answers(e, w, same) ==
  IF e = "SubagentStop" THEN call \in Subs /\ w = call
  ELSE IF Outlasts /\ e = "Stop" THEN says /\ Left = {}
  ELSE IF Outlasts /\ e \in {"UserPromptSubmit", "SelfPrompt"} THEN e = "UserPromptSubmit"
  ELSE ToolAnswers(e, w, same)

(* `update_hook`, unrelayed, for event E of agent W. *)
Hook(e, w, same) ==
  LET before == status
      s0 == Observe(e)
      kept == ~(before = "permission" /\ s0 # "permission" /\ ~Answers(e, w, same))
      after == IF s0 = "none" \/ ~kept THEN before ELSE s0
      asks == s0 = "permission"
      several == e = "PermissionRequest" /\ before = "permission"
  IN /\ status' = after
     /\ call' = IF s0 = "none" THEN call
                ELSE IF e = "PermissionRequest" THEN (IF several THEN "several" ELSE w)
                \* The notification that follows a request names no tool:
                \* the request it follows stands, or it names one itself.
                ELSE IF asks THEN (IF before = "permission" THEN call ELSE "none")
                ELSE IF after # "permission" \/ before # "permission" THEN "none"
                ELSE call
     \* Who is among several: a subagent, now or before.
     /\ beside' = IF s0 = "none" THEN beside
                  ELSE IF e = "PermissionRequest"
                  THEN several /\ (w \in Subs \/ call \in Subs \/ (call = "several" /\ beside))
                  ELSE IF asks THEN before = "permission" /\ beside
                  ELSE IF after # "permission" \/ before # "permission" THEN FALSE
                  ELSE beside

Init ==
  /\ lead = "idle"
  /\ sub = [w \in Subs |-> "none"]
  /\ says \in SaysLeft
  /\ status = "ready"
  /\ call = "none"
  /\ beside = FALSE
  /\ ended = FALSE
  /\ steps = 0

Step == steps < MaxSteps /\ steps' = steps + 1 /\ ended' = FALSE /\ UNCHANGED says

\* A prompt on screen takes the keys: you can send nothing meanwhile.
Prompt ==
  /\ Step /\ lead = "idle" /\ Asking = {}
  /\ lead' = "working" /\ UNCHANGED sub
  /\ Hook("UserPromptSubmit", Lead, FALSE)

\* Claude sends itself the notice of a subagent's end, as a prompt.
SelfPrompt ==
  /\ Step /\ lead = "idle"
  /\ lead' = "working" /\ UNCHANGED sub
  /\ Hook("SelfPrompt", Lead, FALSE)

LeadTool(e) ==      \* a tool of the lead's starts, or ends
  /\ Step /\ lead = "working" /\ e \in {"PreToolUse", "PostToolUse", "PostToolUseFailure"}
  /\ UNCHANGED <<lead, sub>>
  /\ Hook(e, Lead, FALSE)

Start(w) ==         \* the lead starts a subagent
  /\ Step /\ lead = "working" /\ sub[w] = "none"
  /\ sub' = [sub EXCEPT ![w] = "working"] /\ UNCHANGED lead
  /\ Hook("PreToolUse", Lead, FALSE)

SubTool(w, e) ==
  /\ Step /\ sub[w] = "working" /\ e \in {"PreToolUse", "PostToolUse", "PostToolUseFailure"}
  /\ UNCHANGED <<lead, sub>>
  /\ Hook(e, w, FALSE)

LeadAsks ==
  /\ Step /\ lead = "working"
  /\ lead' = "asking" /\ UNCHANGED sub
  /\ Hook("PermissionRequest", Lead, FALSE)

SubAsks(w) ==
  /\ Step /\ sub[w] = "working"
  /\ sub' = [sub EXCEPT ![w] = "asking"] /\ UNCHANGED lead
  /\ Hook("PermissionRequest", w, FALSE)

Note ==             \* Claude's permission_prompt, a few seconds into a wait
  /\ Step /\ (lead = "asking" \/ Asking # {})
  /\ UNCHANGED <<lead, sub>>
  /\ Hook("Note", Lead, FALSE)

\* You answer: what was asked for ends, done or failed, or, for a
\* subagent you refused, it goes on to its next tool or ends.
LeadAnswered(e) ==
  /\ Step /\ lead = "asking" /\ e \in {"PostToolUse", "PostToolUseFailure"}
  /\ lead' = "working" /\ UNCHANGED sub
  /\ Hook(e, Lead, TRUE)

SubAnswered(w, e) ==
  /\ Step /\ sub[w] = "asking" /\ e \in {"PostToolUse", "PostToolUseFailure", "PreToolUse"}
  /\ sub' = [sub EXCEPT ![w] = "working"] /\ UNCHANGED lead
  /\ Hook(e, w, e # "PreToolUse")

SubEnds(w) ==       \* at work, or refused what it asked
  /\ Step /\ sub[w] # "none"
  /\ sub' = [sub EXCEPT ![w] = "none"] /\ UNCHANGED lead
  /\ Hook("SubagentStop", w, FALSE)

LeadEnds ==         \* its turn ends, whatever its subagents do
  /\ steps < MaxSteps /\ steps' = steps + 1 /\ ended' = TRUE /\ UNCHANGED says
  /\ lead = "working"
  /\ lead' = "idle" /\ UNCHANGED sub
  /\ Hook("Stop", Lead, FALSE)

Rest == steps = MaxSteps /\ UNCHANGED vars     \* the bound, not a deadlock

Next ==
  \/ Prompt \/ SelfPrompt \/ LeadAsks \/ Note \/ LeadEnds \/ Rest
  \/ \E e \in {"PreToolUse", "PostToolUse", "PostToolUseFailure"} :
       LeadTool(e) \/ LeadAnswered(e) \/ \E w \in Subs : SubTool(w, e) \/ SubAnswered(w, e)
  \/ \E w \in Subs : Start(w) \/ SubAsks(w) \/ SubEnds(w)

Spec == Init /\ [][Next]_vars

-----------------------------------------------------------------------------
(* The rules. *)

\* An agent whose prompt is on your screen shows as asking, whoever else
\* works or ends beside it.
AskingShown == (lead = "asking" \/ Asking # {}) => status = "permission"

\* A turn of the lead's that ends with nothing left, and says so, ends what
\* was asked: nobody is there to ask.
RestShown == ended /\ Left = {} /\ says => status = "ready"

\* The lead at work never shows as waiting for a prompt.
WorkNotReady == lead = "working" => status # "ready"

TypeOK ==
  /\ status \in {"ready", "running", "permission", "background"}
  /\ call \in Who \cup {"none", "several"}
  /\ beside \in BOOLEAN
=============================================================================
