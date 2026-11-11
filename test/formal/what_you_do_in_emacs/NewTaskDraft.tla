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
(*                                                                         *)
(* A draft can make several attempts at its prompt (C-c C-x): one request  *)
(* each, the draft's own last, each with an ID made from the draft's and   *)
(* its number.  Only the reply to the draft's own changes the draft.  The  *)
(* others say what became of them in a message and no more, so their       *)
(* replies are no steps here: the host takes each as it does any request,  *)
(* but that it makes none beside one of the same draft's ID made from      *)
(* other words, and answers with that one.                                 *)
(* NewTaskAttempts.tla checks these same steps with two attempts.          *)
(***************************************************************************)
EXTENDS Naturals, Sequences, FiniteSets

CONSTANTS
  NDirs,      \* projects on the host
  NTexts,     \* versions of what the draft says (prompt and fields)
  MaxAsks,    \* C-c C-c presses that reach roost-compose-submit's request
  MaxHeld,    \* closures a poll may leave held for the minibuffer
  Attempts,   \* tasks the draft makes from its prompt (`roost--compose-agents`)
  \* The code as it is: each TRUE.  A FALSE one is a broken variant.
  HostLock,           \* `asking_for` holds the ID's lock across `made_for` and `make_task`
  CompareBeforeClose, \* `roost--compose-made` closes only if `roost--compose-what` is unchanged
  KeepIdForProject,   \* `roost-compose-submit` keeps the ID while the project is the same
  FailureClearsFlag,  \* the failure callback sets `roost--compose-submitting` nil
  KeepOwnInFlight,    \* `roost--compose-made` from a poll leaves the flag and the ID while a
                      \* request of the draft's own is out
  ForgetMixedFirst,   \* `roost-compose-submit` forgets what the ID first asked once it asks
                      \* with that ID for something else
  WhatSaysAll,        \* `roost--compose-what` has every field a request is made from, a
                      \* fork's conversation and an offer's task too
  KeepAskedOnceSent,  \* `roost-compose-submit`, cut short, keeps the ID an attempt went with
  OfferKeepsDraft,    \* `roost--compose-offer` leaves a draft that holds a prompt, a note
                      \* or a request, and the offer waits
  GroupKeepsItsWords, \* `make_task` makes no attempt beside one of its group, its draft's
                      \* ID, made from other words (`made_from_other_words`)
  \* Scope: what you may do.  A base config turns each on, but for one a
  \* finding's config turns on, until it is fixed.
  SubmitQuitsQuestion, \* C-c C-c with a question left open (`roost--quit-questions-here`)
  EditBack,            \* an edit or move brings back what the draft said before
  CutShort,            \* a quit or an error between the requests of one C-c C-c
  MixedAttempts        \* a draft that makes several attempts asks again with its ID for
                       \* something else, as after you changed it

None == 0
What == (1..NDirs) \X (1..NTexts)
NoAsk == [dir |-> 0, id |-> 0, first |-> <<0, 0>>]
\* What the ID asked for, once it asked for different things: nothing the
\* draft can say.
Unknown == <<0, 0>>

VARIABLES
  draft,       \* "open", "closed" (Roost closed it), "cancelled" (C-c C-k)
  dir, text,   \* what the draft says now: its project, and its prompt and fields
  submitting,  \* `roost--compose-submitting`
  asked,       \* `roost--compose-asked`: (DIRECTORY ID WHAT), WHAT Unknown once mixed
  nextId,      \* `roost--random-id`: never repeats
  mini,        \* a question is open in the minibuffer
  held,        \* closures on `minibuffer-exit-hook` (`roost--when-out-of-minibuffer`)
  timers,      \* ripe `run-at-time 0` timers, in order
  waits,       \* requests Emacs still waits on (each has its own callback)
  reqs,        \* every create request sent, and what the host made of it
  tasks,       \* task records on the host: createId (the draft's ID and which
               \* attempt), what it was made from, request
  told,        \* tasks Roost has said were made ("Roost created NAME", or the note)
  closedWhat,  \* what the draft said when Roost closed it
  asks         \* presses that sent a request

vars == <<draft, dir, text, submitting, asked, nextId, mini, held, timers,
          waits, reqs, tasks, told, closedWhat, asks>>

\* What a request made now asks for.
Now == <<dir, text>>
\* What `roost--compose-what` tells of it: all, or, broken, all but one
\* field, so that the last two versions look the same.
Seen(t) == IF ~WhatSaysAll /\ t = NTexts THEN NTexts - 1 ELSE t
SeenOf(w) == <<w[1], Seen(w[2])>>
Says == SeenOf(Now)
Pending == held \o timers
Tasks == 1..Len(tasks)
Reqs == 1..Len(reqs)

-----------------------------------------------------------------------------
(* Steps the code runs                                                     *)

\* roost-compose-submit, past its checks: keep the ID while the project is
\* the same, else make one, and ask the host with it.  Asked with the
\* same ID for something else, what it asked for is Unknown from then on.
Fresh == asked.id = None \/ asked.dir # dir \/ ~KeepIdForProject
AskNow ==
  IF Fresh THEN [dir |-> dir, id |-> nextId, first |-> Says]
  ELSE IF ForgetMixedFirst /\ asked.first # Says THEN [asked EXCEPT !.first = Unknown]
  ELSE asked
Reason == IF asked.id = None THEN "forgotten"
          ELSE IF asked.dir # dir THEN "moved"
          ELSE IF Fresh THEN "fresh" ELSE "same"

\* The request for attempt N, the draft's own being 1.  Its creation ID
\* is the draft's with N after it: here, the two together.
Request(ask, n) == [id |-> ask.id, n |-> n, what |-> Now, first |-> ask.first,
                    told |-> told, reason |-> Reason,
                    state |-> "sent", result |-> "none", task |-> None]
\* Those after the first go first: what is asked for last is what opens.
Others(ask) == [i \in 1..(Attempts - 1) |-> Request(ask, i + 1)]

DoSubmit ==
  /\ asked' = AskNow
  /\ nextId' = IF Fresh THEN nextId + 1 ELSE nextId
  /\ submitting' = TRUE
  /\ reqs' = reqs \o Others(AskNow) \o <<Request(AskNow, 1)>>
  /\ waits' = waits \cup {Len(reqs) + Attempts}
  /\ asks' = asks + 1

\* A quit or an error once M of the other attempts went, as C-g while the
\* next request starts: the flag is cleared, and the ID stays as it asked,
\* for asking again to name the attempts that went as they were.  (Before
\* any went, the ID is put back as it was, and nothing has changed.)
DoSubmitCutShort(m) ==
  /\ asked' = IF KeepAskedOnceSent THEN AskNow ELSE asked
  /\ nextId' = IF Fresh THEN nextId + 1 ELSE nextId
  /\ reqs' = reqs \o SubSeq(Others(AskNow), 1, m)
  /\ asks' = asks + 1
  /\ UNCHANGED <<submitting, waits>>

\* roost--compose-made: close the draft if it says WHAT, else keep it,
\* saying what was made, and forget the ID, unless it is a poll's news
\* (not OWN) while a request of the draft's own is out.  Called by the
\* closure of roost--task-made once you are out of the minibuffer.
ComposeMade(c) ==
  IF draft # "open" THEN UNCHANGED <<draft, submitting, asked, closedWhat>>
  ELSE IF CompareBeforeClose /\ Says # c.what
  THEN /\ IF KeepOwnInFlight /\ submitting /\ c.src = "poll"
          THEN UNCHANGED <<submitting, asked>>
          ELSE /\ submitting' = FALSE
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

\* Scope: a draft that makes several attempts asks with its ID for what
\* it asked with it before, unless MixedAttempts.
MayAsk == Attempts = 1 \/ MixedAttempts \/ Fresh \/ asked.first = Says

\* C-c C-c.  While submitting it is a user-error, which changes nothing.
Submit ==
  /\ UserCan
  /\ ~submitting
  /\ asks < MaxAsks
  /\ MayAsk
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

\* C-c C-c, cut short between its requests.  From the timer that submits
\* once a question is quit it is the same function, left to this press.
SubmitCutShort ==
  /\ CutShort
  /\ UserCan /\ ~mini
  /\ ~submitting
  /\ asks < MaxAsks
  /\ MayAsk
  /\ \E m \in 1..(Attempts - 1) : DoSubmitCutShort(m)
  /\ UNCHANGED <<draft, dir, text, mini, held, timers, tasks, told, closedWhat>>

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

\* RET on an agent's offer, with your draft open: `roost--compose-offer`
\* leaves a draft that holds a prompt, says what became of a request or
\* waits on one, and the offer waits.  (One that holds nothing gives way
\* to the offer's, a new buffer with no ID, as at Init.)  Broken, the
\* offer's draft takes the place of yours.
OpenOffer ==
  /\ ~OfferKeepsDraft
  /\ UserCan
  /\ draft' = "closed"
  /\ closedWhat' = Now
  /\ UNCHANGED <<dir, text, submitting, asked, nextId, mini, held, timers,
                 waits, reqs, tasks, told, asks>>

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

\* A good reply to the draft's own request: roost-compose-submit's success
\* callback.  Found (the host's `alreadyMade`) compares with what the ID
\* first asked; made compares with what this request said.  The task found
\* may be another attempt's, which its host made from other words: the ID
\* then asked for different things, so the draft stays and names that task.
Reply(r) ==
  /\ EmacsReads
  /\ r \in waits
  /\ reqs[r].state = "handled"
  /\ waits' = waits \ {r}
  /\ IF reqs[r].result = "refused"
     THEN /\ submitting' = IF draft = "open" /\ FailureClearsFlag THEN FALSE ELSE submitting
          /\ UNCHANGED <<draft, asked, mini, held, told, closedWhat>>
     ELSE /\ TaskMade([kind |-> "made", task |-> reqs[r].task, src |-> "reply",
                       what |-> IF reqs[r].result = "found" THEN reqs[r].first
                                ELSE SeenOf(reqs[r].what)])
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

\* A poll lists the ID the draft last asked with, which is its own
\* task's: roost--compose-listed.
Poll ==
  /\ EmacsReads
  /\ draft = "open"
  /\ ~submitting
  /\ asked.id # None
  /\ Len(held) < MaxHeld
  /\ \E k \in Tasks :
       /\ tasks[k].cid = asked.id /\ tasks[k].n = 1
       /\ TaskMade([kind |-> "made", task |-> k, src |-> "poll", what |-> asked.first])
  /\ UNCHANGED <<dir, text, nextId, mini, timers, waits, reqs, tasks, asks>>

-----------------------------------------------------------------------------
(* The host helper: `create`, `asking_for`, `made_for`, `make_task`        *)

Found(r) == {k \in Tasks : tasks[k].cid = reqs[r].id /\ tasks[k].n = reqs[r].n}

Make(r) ==
  /\ tasks' = Append(tasks, [cid |-> reqs[r].id, n |-> reqs[r].n,
                              what |-> reqs[r].what, req |-> r])
  /\ reqs' = [reqs EXCEPT ![r].state = "handled", ![r].result = "made",
                          ![r].task = Len(tasks) + 1]

Refuse(r) ==
  /\ reqs' = [reqs EXCEPT ![r].state = "handled", ![r].result = "refused"]
  /\ UNCHANGED tasks

AnswerFound(r) ==
  /\ reqs' = [reqs EXCEPT ![r].state = "handled", ![r].result = "found",
                          ![r].task = CHOOSE k \in Found(r) : TRUE]
  /\ UNCHANGED tasks

\* The tasks of R's group, its draft's ID, made from other words than R
\* says: `made_from_other_words`.  A request of a draft that makes several
\* attempts names its words (`roost--compose-words`, of what
\* `roost--compose-what` tells), and each attempt's record keeps them.  A
\* draft of one task names none.
OtherWords(r) ==
  IF Attempts > 1 /\ GroupKeepsItsWords
  THEN {k \in Tasks : /\ tasks[k].cid = reqs[r].id
                      /\ SeenOf(tasks[k].what) # SeenOf(reqs[r].what)}
  ELSE {}

\* The first attempt among them, as found: the host's `alreadyMade`.
AnswerOther(r) ==
  /\ reqs' = [reqs EXCEPT ![r].state = "handled", ![r].result = "found",
                          ![r].task = CHOOSE k \in OtherWords(r) :
                                        \A j \in OtherWords(r) : tasks[k].n <= tasks[j].n]
  /\ UNCHANGED tasks

\* make_task: beside a task of its group made from other words it makes
\* nothing, and answers with that task.  It looks as it records its own,
\* under the registry lock, so the two are one step, with the ID's lock or
\* without: of two requests in flight, the first recorded stands.
MakeOrAnswer(r) ==
  IF OtherWords(r) # {} THEN AnswerOther(r) ELSE (Make(r) \/ Refuse(r))

\* With the ID's lock: look and make as one.
HostTake(r) ==
  /\ HostLock
  /\ reqs[r].state = "sent"
  /\ IF Found(r) # {} THEN AnswerFound(r) ELSE MakeOrAnswer(r)

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
  /\ MakeOrAnswer(r)

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
  \/ Edit \/ Move \/ Submit \/ SubmitCutShort \/ OpenQuestion \/ EndQuestion
  \/ OpenOffer \/ Cancel
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

\* The creation ID, I1: one ID makes at most one task, an attempt's too.
OneTaskPerId ==
  \A j, k \in Tasks :
    j # k => ~(tasks[j].cid = tasks[k].cid /\ tasks[j].n = tasks[k].n)

\* The new task draft, I2 and I3: Roost closes a draft only for a task of
\* its own made from what it says, so nothing you wrote goes unmade.
DraftNeverLost ==
  draft = "closed" => \E k \in Tasks : tasks[k].n = 1 /\ tasks[k].what = closedWhat

\* Request B was asked after you moved the draft from where request A
\* asked to another project and asked there.
MovedBetween(a, b) == \E i \in Reqs : a < i /\ i <= b /\ reqs[i].what[1] # reqs[a].what[1]

\* The tasks of the C-c C-c that task J is of: the draft closes for its
\* own, or names whichever of them its host made from what it said before
\* ("Made fix 2 from what you sent before"), an attempt after the first
\* too since `made_from_other_words`.  Before that only its own was ever
\* named, and this read the same.
OwnOf(j) == {k \in Tasks : tasks[k].cid = tasks[j].cid}

\* A retry after a lost reply makes no second task: a task made from the
\* same words in the same project as an earlier one, and the same attempt
\* at them, was asked for after Roost said a task of the earlier C-c C-c was
\* made, or after you moved the draft to another project and asked there,
\* which the creation ID's table allows ("new ID; a task from the old one
\* stays"), back again too.  Earlier and after are as you asked, whichever
\* request the host took first.
AtMostOnce ==
  \A j, k \in Tasks :
    (/\ tasks[j].req < tasks[k].req
     /\ tasks[j].what = tasks[k].what
     /\ tasks[j].n = tasks[k].n) =>
      \/ OwnOf(j) \cap reqs[tasks[k].req].told # {}
      \/ MovedBetween(tasks[j].req, tasks[k].req)

\* The creation ID, I5: the tasks one ID makes are attempts at one
\* prompt, each made from the same words.
AttemptsAtOnePrompt ==
  \A j, k \in Tasks : tasks[j].cid = tasks[k].cid => tasks[j].what = tasks[k].what

\* Not promised: a draft closes for its own task, whatever became of the
\* other attempts.  This says each was made, or its request is still out.
EveryAttemptMade ==
  draft = "closed" =>
    \E k \in Tasks :
      /\ tasks[k].n = 1 /\ tasks[k].what = closedWhat
      /\ \A n \in 2..Attempts :
           \/ \E j \in Tasks : tasks[j].cid = tasks[k].cid /\ tasks[j].n = n
           \/ \E r \in Reqs : /\ reqs[r].id = tasks[k].cid /\ reqs[r].n = n
                              /\ reqs[r].state = "sent"

\* The new task draft, I1: the flag says Creating only while a request is
\* in flight, or its good reply waits for the minibuffer.
FlagSaysCreating ==
  (draft = "open" /\ submitting) =>
    \/ waits # {}
    \/ \E i \in 1..Len(Pending) : Pending[i].src = "reply"

=============================================================================
