---------------------------- MODULE CachedTasks ----------------------------
(***************************************************************************)
(* What Emacs holds of a host's tasks, as replies come back in any order.  *)
(*                                                                         *)
(* Task lists, actions, inspections and a creation are in flight at once;  *)
(* each comes back, is refused, or is given up on (timed out, or the       *)
(* connection dropped) while what changes things may still run on the     *)
(* host.  Agents and another Emacs change the host meanwhile.              *)
(* docs/state-machines.md, "Emacs and its hosts": Host refresh and Cached  *)
(* task.  HostRequests.tla has the helper copy and the callbacks.          *)
(*                                                                         *)
(* Each step is one step in the code: a command or a process sentinel in   *)
(* Emacs, which runs to its end before anything else does, or one rpc on   *)
(* the host under the registry lock.                                       *)
(***************************************************************************)
EXTENDS Naturals, Sequences, FiniteSets

CONSTANTS
  Break,    \* "none", or the break of roost.el that a variant config proves a rule catches
  Allow,    \* what the main config assumes never happens; a findings config allows it
  MaxAsks,  \* refreshes asked for: polls and g
  MaxActs,  \* stop, retire and inspect requests sent
  MaxVer,   \* how far a task's updatedAt can move, counted
  ActOn     \* the tasks you stop, retire or inspect

Tasks == {"t1", "t2"}  \* t1 is on the host from the start; t2 is the task you create
New == "t2"

VARIABLES
  hpresent, hver,  \* the host's record of each task, and its updatedAt as a count
  cache,           \* roost--tasks: present or not, with the version of that news
  high,            \* ghost: the newest version of each task Emacs has held
  revision,        \* roost--revisions
  refreshing,      \* roost--refreshing
  pending,         \* roost--full-refresh-pending
  reqs,            \* every request Emacs started, in order
  inbox,           \* requests the host has yet to run, waited on or not
  asks, acts, created

vars == <<hpresent, hver, cache, high, revision, refreshing, pending,
          reqs, inbox, asks, acts, created>>

Max(a, b) == IF a >= b THEN a ELSE b

NoRec == [present |-> FALSE, ver |-> 0]
NoSnap == [t \in Tasks |-> NoRec]
NoAnswer == [tag |-> "none", snap |-> NoSnap, rec |-> NoRec]

(* A request.  listed is roost--act's `listed': Emacs held the task as it  *)
(* asked.  rev0 is the revision a list read as it began.  finished is the *)
(* refresh's own flag in roost--refresh-host.                              *)
Req(kind, t, quiet) ==
  [kind |-> kind, task |-> t, listed |-> kind \in {"stop", "retire", "inspect"},
   rev0 |-> revision, quiet |-> quiet, waiting |-> TRUE, answer |-> NoAnswer,
   finished |-> FALSE]

(* The request is over.  What mattered only while it ran is forgotten: an *)
(* action the host may still run keeps what it is, and the rest are Gone, *)
(* so that the model stays small.                                          *)
Gone == [kind |-> "gone", task |-> "none", listed |-> FALSE, rev0 |-> 0, quiet |-> FALSE,
         waiting |-> FALSE, answer |-> NoAnswer, finished |-> TRUE]
Orphan(r) == [Gone EXCEPT !.kind = r.kind, !.task = r.task]
Ended(rs, i) == [rs EXCEPT ![i] = IF rs[i].kind \in {"stop", "retire", "create"} /\ i \in inbox
                                  THEN Orphan(rs[i]) ELSE Gone]

ListsWaiting == {i \in DOMAIN reqs : reqs[i].kind = "list" /\ reqs[i].waiting}
CreateWaiting == \E i \in DOMAIN reqs : reqs[i].kind = "create" /\ reqs[i].waiting

(***************************************************************************)
(* How a reply goes into the cache.                                       *)
(***************************************************************************)

(* roost--newer-events: a record with an older updatedAt keeps Emacs's. *)
NewerEvents(old, rec) ==
  IF old.present /\ rec.ver < old.ver /\ Break # "NoNewerEvents" THEN old ELSE rec

(* roost--cache-task: a record saying the task went takes it out. *)
CacheTask(c, t, rec) ==
  LET m == NewerEvents(c[t], rec)
  IN [c EXCEPT ![t] =
        IF m.present THEN m
        ELSE [present |-> FALSE,
              ver |-> IF c[t].present THEN m.ver ELSE Max(c[t].ver, m.ver)]]

(* roost--cache-reply: a task that went since the request began stays gone. *)
CacheReply(c, t, rec, listed) ==
  IF listed /\ ~c[t].present /\ rec.present /\ Break # "NoWentCheck"
  THEN c ELSE CacheTask(c, t, rec)

(* roost--apply-snapshot: what the list lacks goes, what it has is cached. *)
ApplySnapshot(c, snap) ==
  [t \in Tasks |->
     IF snap[t].present THEN CacheTask(c, t, snap[t])[t]
     ELSE IF c[t].present THEN [present |-> FALSE, ver |-> snap[t].ver]
     ELSE [present |-> FALSE, ver |-> Max(c[t].ver, snap[t].ver)]]

(* Every step that changes the cache moves the ghost with it. *)
Cache(c) == cache' = c /\ high' = [t \in Tasks |-> Max(high[t], c[t].ver)]

(***************************************************************************)
(* Emacs asks: roost--refresh-host, roost--act, roost--create-task.       *)
(***************************************************************************)

NewList(rs) == Append(rs, Req("list", "none", FALSE))

(* A poll (quiet) or g (full).  With a list in flight, a full one is owed. *)
AskRefresh(quiet) ==
  /\ asks < MaxAsks
  /\ asks' = asks + 1
  /\ IF refreshing /\ Break # "NoRefreshingGuard"
     \* A quiet poll then does nothing, so only g is asked here.
     THEN /\ ~quiet /\ ~pending
          /\ pending' = TRUE
          /\ UNCHANGED <<refreshing, reqs, inbox>>
     ELSE LET rs == Append(reqs, Req("list", "none", quiet))
              i == Len(rs)
          IN
          \/ /\ refreshing' = TRUE
             /\ reqs' = rs /\ inbox' = inbox \cup {i}
             /\ UNCHANGED pending
          \* roost--run's condition-case: an error once the process is made
          \* deletes it and calls FAILURE at once, which finishes.  And
          \* roost--request signalling before any process, as with no helper
          \* to read: the unwind-protect finishes.  Either way nothing is
          \* left.  Without the unwind-protect (REQUESTS-1, the break
          \* NoUnwind) the flag stays.
          \/ /\ refreshing' = (Break = "NoUnwind")
             /\ UNCHANGED <<pending, reqs, inbox>>
          \* C-g during g once make-process has run: roost--run deletes the
          \* process, as for an error, and the quit reaches the
          \* unwind-protect, which finishes the refresh: nothing is left,
          \* as above.  Broken: `QuitLeavesProcess` catches errors only, as
          \* before, so the process runs on and its list lands later.
          \/ /\ "quit" \in Allow /\ ~quiet /\ Break = "QuitLeavesProcess"
             /\ refreshing' = FALSE
             /\ reqs' = [rs EXCEPT ![i].finished = TRUE]
             /\ inbox' = inbox \cup {i}
             /\ UNCHANGED pending
  /\ UNCHANGED <<hpresent, hver, cache, high, revision, acts, created>>

(* stop, retire or inspect, offered for a task Emacs lists. *)
AskAct(kind, t) ==
  /\ acts < MaxActs
  /\ cache[t].present
  \* Main config: the reply to your create comes before you act on its task.
  /\ (t = New /\ CreateWaiting) => "act before create replies" \in Allow
  /\ acts' = acts + 1
  /\ reqs' = Append(reqs, Req(kind, t, FALSE))
  /\ inbox' = inbox \cup {Len(reqs) + 1}
  /\ revision' = IF Break = "BumpAtRequest" /\ kind # "inspect" THEN revision + 1 ELSE revision
  /\ UNCHANGED <<hpresent, hver, cache, high, refreshing, pending, asks, created>>

AskCreate ==
  /\ ~created
  /\ created' = TRUE
  /\ reqs' = Append(reqs, Req("create", New, FALSE))
  /\ inbox' = inbox \cup {Len(reqs) + 1}
  /\ revision' = IF Break = "BumpAtRequest" THEN revision + 1 ELSE revision
  /\ UNCHANGED <<hpresent, hver, cache, high, refreshing, pending, asks, acts>>

(***************************************************************************)
(* The host runs a request, under the registry lock.  Its answer reaches   *)
(* Emacs only if Emacs still waits.                                        *)
(***************************************************************************)

Answer(i, a) == [reqs EXCEPT ![i] = IF @.waiting THEN [@ EXCEPT !.answer = a] ELSE Gone]
Ok(rec) == [tag |-> "ok", snap |-> NoSnap, rec |-> rec]
Refused == [tag |-> "refused", snap |-> NoSnap, rec |-> NoRec]

HostRun(i) ==
  /\ i \in inbox
  /\ inbox' = inbox \ {i}
  /\ LET r == reqs[i]
         t == r.task
     IN
     CASE r.kind = "list" ->
            /\ reqs' = Answer(i, [tag |-> "ok", rec |-> NoRec,
                                  snap |-> [u \in Tasks |-> [present |-> hpresent[u], ver |-> hver[u]]]])
            /\ UNCHANGED <<hpresent, hver>>
       [] r.kind = "inspect" ->
            /\ reqs' = IF hpresent[t] THEN Answer(i, Ok([present |-> TRUE, ver |-> hver[t]]))
                       ELSE Answer(i, Refused)
            /\ UNCHANGED <<hpresent, hver>>
       [] r.kind \in {"stop", "retire"} ->
            \* Refused for a reason of the host's, as an agent still active,
            \* is as GiveUp and HostLoses: nothing changes, FAILURE.
            IF hpresent[t] /\ hver[t] < MaxVer
            THEN /\ hver' = [hver EXCEPT ![t] = @ + 1]
                 /\ hpresent' = [hpresent EXCEPT ![t] = (r.kind = "stop")]
                 /\ reqs' = Answer(i, Ok([present |-> r.kind = "stop", ver |-> hver[t] + 1]))
            ELSE /\ reqs' = Answer(i, Refused)
                 /\ UNCHANGED <<hpresent, hver>>
       [] r.kind = "create" ->
            /\ hpresent' = [hpresent EXCEPT ![t] = TRUE]
            /\ hver' = [hver EXCEPT ![t] = 1]
            /\ reqs' = Answer(i, Ok([present |-> TRUE, ver |-> 1]))
  /\ UNCHANGED <<cache, high, revision, refreshing, pending, asks, acts, created>>

(* A request Emacs stopped waiting for dies before it runs, as when the    *)
(* connection drops.  One Emacs still waits for dies the same way, but     *)
(* that is this after GiveUp, and nothing is lost by the order.            *)
HostLoses(i) ==
  /\ i \in inbox /\ ~reqs[i].waiting
  /\ inbox' = inbox \ {i}
  /\ reqs' = [reqs EXCEPT ![i] = Gone]
  /\ UNCHANGED <<hpresent, hver, cache, high, revision, refreshing, pending,
                 asks, acts, created>>

(* An agent's event, or another Emacs retiring the task. *)
AgentEvent(t) ==
  /\ hpresent[t] /\ hver[t] < MaxVer
  /\ hver' = [hver EXCEPT ![t] = @ + 1]
  /\ UNCHANGED <<hpresent, cache, high, revision, refreshing, pending,
                 reqs, inbox, asks, acts, created>>

OtherRetires(t) ==
  /\ hpresent[t] /\ hver[t] < MaxVer
  /\ (t = New /\ CreateWaiting) => "others act before create replies" \in Allow
  /\ hpresent' = [hpresent EXCEPT ![t] = FALSE]
  /\ hver' = [hver EXCEPT ![t] = @ + 1]
  /\ UNCHANGED <<cache, high, revision, refreshing, pending,
                 reqs, inbox, asks, acts, created>>

(***************************************************************************)
(* Emacs takes in an answer, or stops waiting: the sentinel and callbacks. *)
(***************************************************************************)

(* What of request i the host may still run once Emacs stops waiting.     *)
(* What only looks, a list or an inspection, changes nothing when it runs *)
(* with nobody to hear it, so it goes: the state stays small.  What       *)
(* changes things may still run (Request lifetime, I1).                   *)
Kept(i) == IF reqs[i].kind \in {"list", "inspect"} THEN inbox \ {i} ELSE inbox

(* finish in roost--refresh-host, once.  A full refresh owed starts now,   *)
(* in the same sentinel, as roost--refresh-host calls itself.  OWED is     *)
(* roost--full-refresh-pending as finish reads it.                         *)
Finish(i, owed) ==
  LET rs == Ended(reqs, i)
  IN IF reqs[i].finished
     THEN /\ reqs' = rs /\ inbox' = Kept(i)
          /\ refreshing' = refreshing /\ pending' = owed
     ELSE IF owed
          THEN /\ reqs' = NewList(rs) /\ inbox' = Kept(i) \cup {Len(rs) + 1}
               /\ pending' = FALSE /\ refreshing' = TRUE
          ELSE /\ reqs' = rs /\ inbox' = Kept(i)
               /\ refreshing' = FALSE /\ pending' = FALSE

Over(i) == /\ reqs' = Ended(reqs, i) /\ inbox' = Kept(i)
           /\ UNCHANGED <<refreshing, pending>>

(* FAILURE: refused, timed out, or the connection dropped.  A refresh     *)
(* finishes; an action, inspection or creation changes nothing here.      *)
Fail(i) ==
  /\ IF reqs[i].kind = "list" THEN Finish(i, pending) ELSE Over(i)
  /\ UNCHANGED <<cache, high, revision>>

(* SUCCESS, by kind. *)
Succeed(i) ==
  LET r == reqs[i]
      a == r.answer
  IN
  CASE r.kind = "list" ->
         \* A mutation's reply since the list began wins over it.
         IF r.rev0 # revision /\ Break # "NoRevisionCheck"
         THEN /\ UNCHANGED <<cache, high, revision>>
              /\ Finish(i, pending)
         ELSE /\ Cache(ApplySnapshot(cache, a.snap))
              /\ UNCHANGED revision
              \* A quiet poll that saw a change asks to measure it:
              \* roost--refresh-host calls itself while the flag is still
              \* set, so a full refresh is owed.
              /\ \E owe \in IF r.quiet THEN BOOLEAN ELSE {FALSE} :
                   Finish(i, pending \/ (owe /\ refreshing))
    [] r.kind \in {"stop", "retire"} ->
         /\ revision' = IF Break = "BumpAtRequest" THEN revision ELSE revision + 1
         /\ Cache(CacheReply(cache, r.task, a.rec, r.listed))
         /\ Over(i)
    [] r.kind = "inspect" ->
         /\ Cache(CacheReply(cache, r.task, a.rec, r.listed))
         /\ UNCHANGED revision
         /\ Over(i)
    \* roost--task-made caches it with roost--cache-reply, LISTED being
    \* whether it went since Emacs held it (`roost--went`): Emacs held it
    \* once its version is past the 0 it starts at.  Broken:
    \* `CreateNoWentCheck` caches it with roost--cache-task, as before.
    [] r.kind = "create" ->
         /\ revision' = IF Break = "BumpAtRequest" THEN revision ELSE revision + 1
         /\ Cache(IF Break = "CreateNoWentCheck" THEN CacheTask(cache, r.task, a.rec)
                  ELSE CacheReply(cache, r.task, a.rec, cache[r.task].ver > 0))
         /\ Over(i)

Deliver(i) ==
  /\ reqs[i].waiting /\ reqs[i].answer.tag # "none"
  /\ IF reqs[i].answer.tag = "ok" THEN Succeed(i) ELSE Fail(i)
  /\ UNCHANGED <<hpresent, hver, asks, acts, created>>

(* roost--expire-request's timer, or the connection dropping. *)
GiveUp(i) ==
  /\ reqs[i].waiting
  /\ Fail(i)
  /\ UNCHANGED <<hpresent, hver, asks, acts, created>>

Next ==
  \/ \E q \in BOOLEAN : AskRefresh(q)
  \/ \E k \in {"stop", "retire", "inspect"}, t \in ActOn : AskAct(k, t)
  \/ AskCreate
  \/ \E i \in DOMAIN reqs : HostRun(i) \/ HostLoses(i) \/ Deliver(i) \/ GiveUp(i)
  \* Events of t2's agent, once made, add nothing t1's don't, and cost time.
  \/ AgentEvent("t1") \/ \E t \in Tasks : OtherRetires(t)
  \/ UNCHANGED vars  \* bounded runs end; that is no deadlock

Init ==
  /\ hpresent = [t \in Tasks |-> t # New]
  /\ hver = [t \in Tasks |-> IF t = New THEN 0 ELSE 1]
  /\ cache = [t \in Tasks |-> [present |-> t # New, ver |-> hver[t]]]
  /\ high = [t \in Tasks |-> hver[t]]
  /\ revision = 0
  /\ refreshing = FALSE
  /\ pending = FALSE
  /\ reqs = << >>
  /\ inbox = {}
  /\ asks = 0 /\ acts = 0 /\ created = FALSE

Spec == Init /\ [][Next]_vars

(***************************************************************************)
(* The rules.                                                              *)
(***************************************************************************)

(* A reply never takes Emacs back to older news of a task: it doesn't     *)
(* bring back a task that went, drop one Emacs knows is there, or roll a  *)
(* record back to an older updatedAt.                                      *)
NoRollback == \A t \in Tasks : cache[t].ver = high[t]

(* At most one list waits, the refresh flag says whether one does, so a   *)
(* host is never left unasked, and what is owed has a refresh to run it.  *)
OneList ==
  /\ Cardinality(ListsWaiting) <= 1
  /\ refreshing = (ListsWaiting # {})
  /\ pending => refreshing

=============================================================================
