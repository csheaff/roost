---------------------------- MODULE NewTaskDraft ----------------------------
(***************************************************************************)
(* The new task draft, its creation ID, and the host that makes the task.  *)
(* docs/state-machines.md: "The new task draft", "The creation ID",        *)
(* "Held for the minibuffer", "Questions left open", "Creation".           *)
(*                                                                         *)
(* Three actors run at once:                                               *)
(*   you, in Emacs: edit the draft, move it to another project, C-c C-c,   *)
(*     C-c C-k, open a question in the minibuffer and answer it or leave   *)
(*     it open;                                                            *)
(*   the network: a reply comes, or none does (timeout, dropped ssh), and  *)
(*     a poll of the host lists what it has;                               *)
(*   the host helper: takes each request whenever it gets to it, even     *)
(*     after Emacs stopped waiting (over SSH it goes on), or never.        *)
(*                                                                         *)
(* Emacs runs every ripe timer before it reads input or process output     *)
(* (timer_check loops until none is ripe), so while `timers` is not empty  *)
(* only the timer step runs on the Emacs side.                             *)
(***************************************************************************)
EXTENDS Naturals, Sequences, FiniteSets

CONSTANTS
  NDirs,      \* projects on the host
  NTexts,     \* versions of what the draft says (prompt and fields)
  MaxAsks,    \* C-c C-c presses that reach roost-compose-submit's request
  MaxHeld,    \* closures a poll may leave held for the minibuffer
  \* The code as it is: each TRUE.  A FALSE one is a broken variant.
  HostLock,           \* `asking_for` holds the ID's lock across `made_for` and `make_task`
  CompareBeforeClose, \* `roost--compose-made` closes only if `roost--compose-what` is unchanged
  KeepIdForProject,   \* `roost-compose-submit` keeps the ID while the project is the same
  FailureClearsFlag,  \* the failure callback sets `roost--compose-submitting` nil
  \* Scope: what you may do.  FALSE in NewTaskDraft.cfg; each finding's
  \* config turns one on.
  SubmitQuitsQuestion, \* C-c C-c with a question left open (`roost--quit-questions-here`)
  EditBack             \* an edit or move brings back what the draft said before

None == 0
What == (1..NDirs) \X (1..NTexts)
NoAsk == [dir |-> 0, id |-> 0, first |-> <<0, 0>>]

VARIABLES
  draft,       \* "open", "closed" (Roost closed it), "cancelled" (C-c C-k)
  dir, text,   \* what the draft says now: `roost--compose-what`
  submitting,  \* `roost--compose-submitting`
  asked,       \* `roost--compose-asked`: (DIRECTORY ID FIRST-WHAT)
  nextId,      \* `roost--random-id`: never repeats
  mini,        \* a question is open in the minibuffer
  held,        \* closures on `minibuffer-exit-hook` (`roost--when-out-of-minibuffer`)
  timers,      \* ripe `run-at-time 0` timers, in order
  waits,       \* requests Emacs still waits on (each has its own callback)
  reqs,        \* every create request sent, and what the host made of it
  tasks,       \* task records on the host: createId, what it was made from, request
  told,        \* tasks Roost has said were made ("Roost created NAME", or the note)
  closedWhat,  \* what the draft said when Roost closed it
  asks         \* presses that sent a request

vars == <<draft, dir, text, submitting, asked, nextId, mini, held, timers,
          waits, reqs, tasks, told, closedWhat, asks>>

Now == <<dir, text>>
Pending == held \o timers
Tasks == 1..Len(tasks)
Reqs == 1..Len(reqs)

-----------------------------------------------------------------------------
(* Steps the code runs                                                     *)

\* roost-compose-submit, past its checks: keep the ID while the project is
\* the same, else make one, and ask the host with it.
DoSubmit ==
  LET fresh  == asked.id = None \/ asked.dir # dir \/ ~KeepIdForProject
      ask    == IF fresh THEN [dir |-> dir, id |-> nextId, first |-> Now] ELSE asked
      reason == IF asked.id = None THEN "forgotten"
                ELSE IF asked.dir # dir THEN "moved"
                ELSE IF fresh THEN "fresh" ELSE "same"
  IN /\ asked' = ask
     /\ nextId' = IF fresh THEN nextId + 1 ELSE nextId
     /\ submitting' = TRUE
     /\ reqs' = Append(reqs, [id |-> ask.id, what |-> Now, first |-> ask.first,
                              told |-> told, reason |-> reason,
                              state |-> "sent", result |-> "none", task |-> None])
     /\ waits' = waits \cup {Len(reqs) + 1}
     /\ asks' = asks + 1

\* roost--compose-made: close the draft if it says WHAT, else keep it,
\* saying what was made, and forget the ID.  Called by the closure of
\* roost--task-made once you are out of the minibuffer.
ComposeMade(c) ==
  IF draft # "open" THEN UNCHANGED <<draft, submitting, asked, closedWhat>>
  ELSE IF CompareBeforeClose /\ Now # c.what
  THEN /\ submitting' = FALSE
       /\ asked' = NoAsk
       /\ UNCHANGED <<draft, closedWhat>>
  ELSE /\ draft' = "closed"
       /\ closedWhat' = Now
       /\ UNCHANGED <<submitting, asked>>

\* roost--task-made: says "Roost created NAME" at once, then runs the
\* closure, or holds it while a minibuffer is open.
TaskMade(c) ==
  /\ told' = told \cup {c.task}
  /\ IF mini
     THEN /\ held' = Append(held, c)
          /\ UNCHANGED <<draft, submitting, asked, closedWhat>>
     ELSE /\ ComposeMade(c)
          /\ UNCHANGED held

-----------------------------------------------------------------------------
(* You                                                                     *)

UserCan == draft = "open" /\ timers = <<>>

Edit ==
  /\ UserCan
  /\ \E t \in 1..NTexts :
       /\ IF EditBack THEN t # text ELSE t = text + 1
       /\ text' = t
  /\ UNCHANGED <<draft, dir, submitting, asked, nextId, mini, held, timers,
                 waits, reqs, tasks, told, closedWhat, asks>>

\* C-c C-p, or a click on another project (roost--compose with DIRECTORY).
Move ==
  /\ UserCan
  /\ \E d \in 1..NDirs :
       /\ IF EditBack THEN d # dir ELSE d = dir + 1
       /\ dir' = d
  /\ UNCHANGED <<draft, text, submitting, asked, nextId, mini, held, timers,
                 waits, reqs, tasks, told, closedWhat, asks>>

\* C-c C-c.  While submitting it is a user-error, which changes nothing.
Submit ==
  /\ UserCan
  /\ ~submitting
  /\ asks < MaxAsks
  /\ IF ~mini
     THEN /\ DoSubmit
          /\ UNCHANGED <<draft, dir, text, mini, held, timers, tasks, told, closedWhat>>
     ELSE \* roost--quit-questions-here: the timer that submits comes first,
          \* then quitting runs minibuffer-exit-hook, whose closures each
          \* schedule a timer of their own.
          /\ SubmitQuitsQuestion
          /\ timers' = <<[kind |-> "submit", task |-> None, what |-> <<0, 0>>, src |-> "you"]>>
                       \o held
          /\ held' = <<>>
          /\ mini' = FALSE
          /\ UNCHANGED <<draft, dir, text, submitting, asked, nextId, waits, reqs,
                         tasks, told, closedWhat, asks>>

\* Any command that asks in the minibuffer, answered later or left open.
OpenQuestion ==
  /\ UserCan /\ ~mini
  /\ mini' = TRUE
  /\ UNCHANGED <<draft, dir, text, submitting, asked, nextId, held, timers,
                 waits, reqs, tasks, told, closedWhat, asks>>

\* RET or C-g: each held closure's `done` schedules its timer, in order.
EndQuestion ==
  /\ draft = "open" /\ timers = <<>> /\ mini
  /\ mini' = FALSE
  /\ timers' = held
  /\ held' = <<>>
  /\ UNCHANGED <<draft, dir, text, submitting, asked, nextId, waits, reqs,
                 tasks, told, closedWhat, asks>>

\* C-c C-k, answered yes.  Requests go on; their replies find no draft.
Cancel ==
  /\ UserCan /\ ~mini
  /\ draft' = "cancelled"
  /\ UNCHANGED <<dir, text, submitting, asked, nextId, mini, held, timers,
                 waits, reqs, tasks, told, closedWhat, asks>>

-----------------------------------------------------------------------------
(* Emacs's timers                                                          *)

Timer ==
  /\ timers # <<>>
  /\ LET c == Head(timers) IN
       IF c.kind = "submit"
       THEN \* roost-compose-submit again, from the timer, with its checks.
            IF draft = "open" /\ ~submitting
            THEN /\ DoSubmit
                 /\ timers' = Tail(timers)
                 /\ UNCHANGED <<draft, dir, text, mini, held, tasks, told, closedWhat>>
            ELSE /\ timers' = Tail(timers)
                 /\ UNCHANGED <<draft, dir, text, submitting, asked, nextId, mini, held,
                                waits, reqs, tasks, told, closedWhat, asks>>
       ELSE /\ timers' = Tail(timers)
            /\ ComposeMade(c)
            /\ UNCHANGED <<dir, text, nextId, mini, held, waits, reqs, tasks, told, asks>>

-----------------------------------------------------------------------------
(* The network, as Emacs reads it                                          *)

EmacsReads == timers = <<>>

\* A good reply: roost-compose-submit's success callback.  Found (the
\* host's `alreadyMade`) compares with what the ID first asked; made
\* compares with what this request said.
Reply(r) ==
  /\ EmacsReads
  /\ r \in waits
  /\ reqs[r].state = "handled"
  /\ waits' = waits \ {r}
  /\ IF reqs[r].result = "refused"
     THEN /\ submitting' = IF draft = "open" /\ FailureClearsFlag THEN FALSE ELSE submitting
          /\ UNCHANGED <<draft, asked, mini, held, told, closedWhat>>
     ELSE /\ TaskMade([kind |-> "made", task |-> reqs[r].task, src |-> "reply",
                       what |-> IF reqs[r].result = "found" THEN reqs[r].first ELSE reqs[r].what])
          /\ UNCHANGED mini
  /\ UNCHANGED <<dir, text, nextId, timers, reqs, tasks, asks>>

\* No reply in time, or the connection dropped: the failure callback.
\* The request may still be taken by the host.
NoReply(r) ==
  /\ EmacsReads
  /\ r \in waits
  /\ waits' = waits \ {r}
  /\ submitting' = IF draft = "open" /\ FailureClearsFlag THEN FALSE ELSE submitting
  /\ UNCHANGED <<draft, dir, text, asked, nextId, mini, held, timers, reqs, tasks,
                 told, closedWhat, asks>>

\* A poll lists the ID the draft last asked with: roost--compose-listed.
Poll ==
  /\ EmacsReads
  /\ draft = "open"
  /\ ~submitting
  /\ asked.id # None
  /\ Len(held) < MaxHeld
  /\ \E k \in Tasks :
       /\ tasks[k].cid = asked.id
       /\ TaskMade([kind |-> "made", task |-> k, src |-> "poll", what |-> asked.first])
  /\ UNCHANGED <<dir, text, nextId, mini, timers, waits, reqs, tasks, asks>>

-----------------------------------------------------------------------------
(* The host helper: `create`, `asking_for`, `made_for`, `make_task`        *)

Found(r) == {k \in Tasks : tasks[k].cid = reqs[r].id}

Make(r) ==
  /\ tasks' = Append(tasks, [cid |-> reqs[r].id, what |-> reqs[r].what, req |-> r])
  /\ reqs' = [reqs EXCEPT ![r].state = "handled", ![r].result = "made",
                          ![r].task = Len(tasks) + 1]

Refuse(r) ==
  /\ reqs' = [reqs EXCEPT ![r].state = "handled", ![r].result = "refused"]
  /\ UNCHANGED tasks

AnswerFound(r) ==
  /\ reqs' = [reqs EXCEPT ![r].state = "handled", ![r].result = "found",
                          ![r].task = CHOOSE k \in Found(r) : TRUE]
  /\ UNCHANGED tasks

\* With the ID's lock: look and make as one.
HostTake(r) ==
  /\ HostLock
  /\ reqs[r].state = "sent"
  /\ IF Found(r) # {} THEN AnswerFound(r) ELSE (Make(r) \/ Refuse(r))

\* Without it: look, then make, with others in between.
HostLook(r) ==
  /\ ~HostLock
  /\ reqs[r].state = "sent"
  /\ IF Found(r) # {} THEN AnswerFound(r)
     ELSE /\ reqs' = [reqs EXCEPT ![r].state = "looked"]
          /\ UNCHANGED tasks

HostMake(r) ==
  /\ ~HostLock
  /\ reqs[r].state = "looked"
  /\ (Make(r) \/ Refuse(r))

Host(r) ==
  /\ (HostTake(r) \/ HostLook(r) \/ HostMake(r))
  /\ UNCHANGED <<draft, dir, text, submitting, asked, nextId, mini, held, timers,
                 waits, told, closedWhat, asks>>

-----------------------------------------------------------------------------

Init ==
  /\ draft = "open"
  /\ dir = 1 /\ text = 1
  /\ submitting = FALSE
  /\ asked = NoAsk
  /\ nextId = 1
  /\ mini = FALSE
  /\ held = <<>> /\ timers = <<>>
  /\ waits = {}
  /\ reqs = <<>> /\ tasks = <<>>
  /\ told = {}
  /\ closedWhat = <<0, 0>>
  /\ asks = 0

\* Once the draft is gone and every request settled, nothing more happens.
Settled == draft # "open" /\ UNCHANGED vars

AReplyComes == \E r \in Reqs : Reply(r)
NoReplyComes == \E r \in Reqs : NoReply(r)
HostTakesARequest == \E r \in Reqs : Host(r)

Next ==
  \/ Edit \/ Move \/ Submit \/ OpenQuestion \/ EndQuestion \/ Cancel
  \/ Timer \/ Poll \/ AReplyComes \/ NoReplyComes \/ HostTakesARequest
  \/ Settled

Spec == Init /\ [][Next]_vars

-----------------------------------------------------------------------------
(* Rules                                                                   *)

TypeOK ==
  /\ draft \in {"open", "closed", "cancelled"}
  /\ submitting \in BOOLEAN /\ mini \in BOOLEAN
  /\ waits \subseteq Reqs
  /\ told \subseteq Tasks

\* The creation ID, I1: one ID makes at most one task.
OneTaskPerId ==
  \A j, k \in Tasks : j # k => tasks[j].cid # tasks[k].cid

\* The new task draft, I2 and I3: Roost closes a draft only for a task
\* made from what it says, so nothing you wrote goes unmade.
DraftNeverLost ==
  draft = "closed" => \E k \in Tasks : tasks[k].what = closedWhat

\* A retry after a lost reply makes no second task: a task made from the
\* same words in the same project as an earlier one was asked for after
\* Roost said the earlier one was made, or after you moved the draft to
\* another project and asked there, which the creation ID's table allows
\* ("new ID; a task from the old one stays").
AtMostOnce ==
  \A j, k \in Tasks :
    (j < k /\ tasks[j].what = tasks[k].what) =>
      \/ j \in reqs[tasks[k].req].told
      \/ reqs[tasks[k].req].reason = "moved"

\* The new task draft, I1: the flag says Creating only while a request is
\* in flight, or its good reply waits for the minibuffer.
FlagSaysCreating ==
  (draft = "open" /\ submitting) =>
    \/ waits # {}
    \/ \E i \in 1..Len(Pending) : Pending[i].src = "reply"

=============================================================================
