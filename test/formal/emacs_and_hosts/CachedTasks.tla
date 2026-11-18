---------------------------- MODULE CachedTasks ----------------------------
(***************************************************************************)
(* What Emacs holds of a host's tasks, as replies come back in any order.  *)
(*                                                                         *)
(* Task lists, actions, inspections and creations are in flight at once;   *)
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
  MaxActs,  \* stop, retire, inspect, take and retarget requests sent
  MaxVer,   \* how far a task's updatedAt can move, counted
  MaxOver,  \* how far its offersAt can move, counted: 0 leaves offers out
  MaxBase,  \* how far its retargetedAt can move, counted: 0 leaves B out
  MaxShown, \* how far its shown.at can move, counted: 0 leaves what an agent shows out
  FromOffer,\* the tasks you create from t1's offer, of News: the draft of an offer
  ActOn,    \* the tasks you stop, retire or inspect
  News      \* the tasks you create: none, one, or several, as a draft's attempts at one prompt

Tasks == {"t1"} \cup News  \* t1 is on the host from the start

VARIABLES
  hpresent, hver,  \* the host's record of each task, and its updatedAt as a count
  hover,           \* its offersAt as a count: an offer made or taken, no event of the agent's
  hbase,           \* its retargetedAt as a count: the branch it merges into changed, no event either
  hshown,          \* its shown.at as a count: its agent showed an image or a page, no event either
  cache,           \* roost--tasks: present or not, with the version of that news
  high,            \* ghost: the newest version of each task Emacs has held
  highOver,        \* ghost: the newest offersAt Emacs has held of each task listed
  highBase,        \* ghost: the newest retargetedAt Emacs has held of each task listed
  highShown,       \* ghost: the newest shown.at Emacs has held of each task listed
  revision,        \* roost--revisions
  refreshing,      \* roost--refreshing
  pending,         \* roost--full-refresh-pending
  reqs,            \* every request Emacs started, in order
  inbox,           \* requests the host has yet to run, waited on or not
  asks, acts,
  created,         \* the tasks whose creation you asked for
  rowOwed,         \* a task made from an offer was heard of, and its draft's callback is yet to run
  rowDue,          \* that callback ran: it asked for t1's host to be listed again
  rowExcused,      \* ghost: a list asked since then came to nothing, as one that failed
  madeOver         \* ghost: t1's offersAt once its host made a task from its offer

vars == <<hpresent, hver, hover, hbase, hshown, cache, high, highOver, highBase, highShown, revision, refreshing,
          pending, reqs, inbox, asks, acts, created, rowOwed, rowDue, rowExcused, madeOver>>

host == <<hpresent, hver, hover, hbase, hshown>>
held == <<cache, high, highOver, highBase, highShown>>
row == <<rowOwed, rowDue, rowExcused>>

Max(a, b) == IF a >= b THEN a ELSE b

NoRec == [present |-> FALSE, ver |-> 0, over |-> 0, base |-> 0, shown |-> 0]
NoSnap == [t \in Tasks |-> NoRec]
NoAnswer == [tag |-> "none", snap |-> NoSnap, rec |-> NoRec]

(* The host's record of a task, as a reply carries it. *)
HostRec(t) == [present |-> hpresent[t], ver |-> hver[t], over |-> hover[t], base |-> hbase[t],
               shown |-> hshown[t]]

(* What roost--act asks, of a task Emacs holds. *)
Acts == {"stop", "retire", "inspect", "take", "retarget"}

(* A request.  listed is roost--act's `listed': Emacs held the task as it  *)
(* asked.  rev0 is the revision a list read as it began.  finished is the *)
(* refresh's own flag in roost--refresh-host.  after is a ghost: a list   *)
(* asked by the draft of an offer once its task was made, or since.       *)
Req(kind, t, quiet, rev) ==
  [kind |-> kind, task |-> t, listed |-> kind \in Acts,
   rev0 |-> rev, quiet |-> quiet, waiting |-> TRUE, answer |-> NoAnswer,
   finished |-> FALSE, after |-> FALSE]

(* The request is over.  What mattered only while it ran is forgotten: an *)
(* action the host may still run keeps what it is, and the rest are Gone, *)
(* so that the model stays small.                                          *)
Gone == [kind |-> "gone", task |-> "none", listed |-> FALSE, rev0 |-> 0, quiet |-> FALSE,
         waiting |-> FALSE, answer |-> NoAnswer, finished |-> TRUE, after |-> FALSE]
Orphan(r) == [Gone EXCEPT !.kind = r.kind, !.task = r.task]
Ended(rs, i) == [rs EXCEPT ![i] = IF rs[i].kind \in {"stop", "retire", "create", "take", "retarget"} /\ i \in inbox
                                  THEN Orphan(rs[i]) ELSE Gone]

ListsWaiting == {i \in DOMAIN reqs : reqs[i].kind = "list" /\ reqs[i].waiting}
CreateWaiting(t) == \E i \in DOMAIN reqs : reqs[i].kind = "create" /\ reqs[i].task = t /\ reqs[i].waiting

(***************************************************************************)
(* How a reply goes into the cache.                                       *)
(***************************************************************************)

(* roost--newer-events: a record with an older updatedAt keeps Emacs's,   *)
(* its offers, its branch and what it shows too.  Only what its host      *)
(* measured is taken from the reply, and none of that is here.  Otherwise *)
(* the reply stands, and with it what it says the task shows: nothing in  *)
(* roost--cache-task goes by shown.at, as roost--newer-offers goes by     *)
(* offersAt.  (What a pull request left to its agent has of the same,     *)
(* roost--newer-left by prLeftAt, is in pull_request_left.)               *)
NewerEvents(old, rec) ==
  IF old.present /\ rec.ver < old.ver /\ Break # "NoNewerEvents" THEN old ELSE rec

(* roost--newer-offers: a record with an older offersAt keeps Emacs's     *)
(* offers, as an offer made or taken moves no updatedAt.                  *)
NewerOffers(old, rec) ==
  IF old.present /\ rec.over < old.over /\ Break # "NoNewerOffers" THEN [rec EXCEPT !.over = old.over] ELSE rec

(* roost--newer-branch: a record with an older retargetedAt keeps the     *)
(* branch Emacs has, as B moves no updatedAt either.                      *)
NewerBranch(old, rec) ==
  IF old.present /\ rec.base < old.base /\ Break # "NoNewerBranch" THEN [rec EXCEPT !.base = old.base] ELSE rec

(* roost--cache-task: a record saying the task went takes it out. *)
CacheTask(c, t, rec) ==
  LET m == NewerBranch(c[t], NewerOffers(c[t], NewerEvents(c[t], rec)))
  IN [c EXCEPT ![t] =
        IF m.present THEN m
        ELSE [present |-> FALSE,
              ver |-> IF c[t].present THEN m.ver ELSE Max(c[t].ver, m.ver),
              over |-> IF c[t].present THEN m.over ELSE Max(c[t].over, m.over),
              base |-> IF c[t].present THEN m.base ELSE Max(c[t].base, m.base),
              shown |-> IF c[t].present THEN m.shown ELSE Max(c[t].shown, m.shown)]]

(* roost--cache-reply: a task that went since the request began stays gone. *)
CacheReply(c, t, rec, listed) ==
  IF listed /\ ~c[t].present /\ rec.present /\ Break # "NoWentCheck"
  THEN c ELSE CacheTask(c, t, rec)

(* roost--apply-snapshot: what the list lacks goes, what it has is cached. *)
ApplySnapshot(c, snap) ==
  [t \in Tasks |->
     IF snap[t].present THEN CacheTask(c, t, snap[t])[t]
     ELSE IF c[t].present THEN snap[t]
     ELSE [present |-> FALSE, ver |-> Max(c[t].ver, snap[t].ver), over |-> Max(c[t].over, snap[t].over),
           base |-> Max(c[t].base, snap[t].base), shown |-> Max(c[t].shown, snap[t].shown)]]

(* Every step that changes the cache moves the ghosts with it. *)
Cache(c) == /\ cache' = c /\ high' = [t \in Tasks |-> Max(high[t], c[t].ver)]
            /\ highOver' = [t \in Tasks |-> IF c[t].present THEN Max(highOver[t], c[t].over) ELSE highOver[t]]
            /\ highBase' = [t \in Tasks |-> IF c[t].present THEN Max(highBase[t], c[t].base) ELSE highBase[t]]
            /\ highShown' = [t \in Tasks |-> IF c[t].present THEN Max(highShown[t], c[t].shown) ELSE highShown[t]]

(***************************************************************************)
(* Emacs asks: roost--refresh-host, roost--act, roost--create-task.       *)
(***************************************************************************)

(* A list that is not quiet.  AFT: asked by the draft of an offer once    *)
(* its task was made, or since.                                           *)
NewList(rs, rev, aft) == Append(rs, [Req("list", "none", FALSE, rev) EXCEPT !.after = aft])

(* A poll (quiet) or g (full).  With a list in flight, a full one is owed. *)
AskRefresh(quiet) ==
  /\ asks < MaxAsks
  /\ asks' = asks + 1
  /\ IF refreshing /\ Break # "NoRefreshingGuard"
     \* A quiet poll then does nothing, so only g is asked here.
     THEN /\ ~quiet /\ ~pending
          /\ pending' = TRUE
          /\ UNCHANGED <<refreshing, reqs, inbox>>
     ELSE LET rs == Append(reqs, [Req("list", "none", quiet, revision) EXCEPT !.after = rowDue])
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
  /\ UNCHANGED <<host, held, revision, acts, created, row, madeOver>>

(* stop, retire or inspect, offered for a task Emacs lists; take, as       *)
(* opening an offer, Do it here and Dismiss ask, only of a task it lists;  *)
(* or retarget, as B asks of a task you chose from those listed.           *)
AskAct(kind, t) ==
  /\ acts < MaxActs
  /\ cache[t].present
  \* Unless allowed, the reply to your create comes before you act on its task.
  /\ (t \in News /\ CreateWaiting(t)) => "act before create replies" \in Allow
  /\ acts' = acts + 1
  /\ reqs' = Append(reqs, Req(kind, t, FALSE, revision))
  /\ inbox' = inbox \cup {Len(reqs) + 1}
  /\ revision' = IF Break = "BumpAtRequest" /\ kind # "inspect" THEN revision + 1 ELSE revision
  /\ UNCHANGED <<host, held, refreshing, pending, asks, created, row, madeOver>>

(* A new task, or a conversation.  A draft that makes several attempts at *)
(* its prompt asks for each in the one command, which is these one after  *)
(* another with nothing between.                                          *)
AskCreate(t) ==
  /\ t \in News \ created
  /\ created' = created \cup {t}
  /\ reqs' = Append(reqs, Req("create", t, FALSE, revision))
  /\ inbox' = inbox \cup {Len(reqs) + 1}
  /\ revision' = IF Break = "BumpAtRequest" THEN revision + 1 ELSE revision
  /\ UNCHANGED <<host, held, refreshing, pending, asks, acts, row, madeOver>>

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
            /\ reqs' = Answer(i, [tag |-> "ok", rec |-> NoRec, snap |-> [u \in Tasks |-> HostRec(u)]])
            /\ UNCHANGED <<host, madeOver>>
       [] r.kind = "inspect" ->
            /\ reqs' = IF hpresent[t] THEN Answer(i, Ok(HostRec(t))) ELSE Answer(i, Refused)
            /\ UNCHANGED <<host, madeOver>>
       \* take_offer: an offer that waits goes, and offersAt moves; once the
       \* count is at its bound, the offer is taken already, as from another
       \* Emacs, and nothing changes.
       [] r.kind = "take" ->
            IF hpresent[t]
            THEN LET took == hover[t] < MaxOver
                     now == IF took THEN hover[t] + 1 ELSE hover[t]
                 IN /\ hover' = [hover EXCEPT ![t] = now]
                    /\ reqs' = Answer(i, Ok([HostRec(t) EXCEPT !.over = now]))
                    /\ UNCHANGED <<hpresent, hver, hbase, hshown, madeOver>>
            ELSE /\ reqs' = Answer(i, Refused)
                 /\ UNCHANGED <<host, madeOver>>
       \* retarget: the branch the record merges into changes, and
       \* retargetedAt moves, but no updatedAt.  Once the count is at its
       \* bound it is refused, as for a branch that isn't there.
       [] r.kind = "retarget" ->
            IF hpresent[t] /\ hbase[t] < MaxBase
            THEN /\ hbase' = [hbase EXCEPT ![t] = @ + 1]
                 /\ reqs' = Answer(i, Ok([HostRec(t) EXCEPT !.base = @ + 1]))
                 /\ UNCHANGED <<hpresent, hver, hover, hshown, madeOver>>
            ELSE /\ reqs' = Answer(i, Refused)
                 /\ UNCHANGED <<host, madeOver>>
       [] r.kind \in {"stop", "retire"} ->
            \* Refused for a reason of the host's, as an agent still active,
            \* is as GiveUp and HostLoses: nothing changes, FAILURE.
            IF hpresent[t] /\ hver[t] < MaxVer
            THEN /\ hver' = [hver EXCEPT ![t] = @ + 1]
                 /\ hpresent' = [hpresent EXCEPT ![t] = (r.kind = "stop")]
                 /\ reqs' = Answer(i, Ok([HostRec(t) EXCEPT !.present = (r.kind = "stop"), !.ver = @ + 1]))
                 /\ UNCHANGED <<hover, hbase, hshown, madeOver>>
            ELSE /\ reqs' = Answer(i, Refused)
                 /\ UNCHANGED <<host, madeOver>>
       \* make_task, a conversation's too.  One that goes on with another
       \* task's conversation (forkFrom) reads that task and leaves its
       \* record as it was, and is refused if it went, which is as GiveUp
       \* and HostLoses.  One made from t1's offer takes it as it saves the
       \* task, under the one hold of the lock: an offer that waits goes,
       \* and t1's offersAt moves, as for a take; one taken already, or
       \* whose task went, leaves all as it was.  The reply says nothing of
       \* t1.
       [] r.kind = "create" ->
            LET took == t \in FromOffer /\ hpresent["t1"] /\ hover["t1"] < MaxOver
                over == IF took THEN [hover EXCEPT !["t1"] = @ + 1] ELSE hover
            IN /\ hpresent' = [hpresent EXCEPT ![t] = TRUE]
               /\ hver' = [hver EXCEPT ![t] = 1]
               /\ hover' = over
               /\ madeOver' = IF t \in FromOffer THEN over["t1"] ELSE madeOver
               /\ reqs' = Answer(i, Ok([HostRec(t) EXCEPT !.present = TRUE, !.ver = 1]))
               /\ UNCHANGED <<hbase, hshown>>
  /\ UNCHANGED <<held, revision, refreshing, pending, asks, acts, created, row>>

(* A request Emacs stopped waiting for dies before it runs, as when the    *)
(* connection drops.  One Emacs still waits for dies the same way, but     *)
(* that is this after GiveUp, and nothing is lost by the order.            *)
HostLoses(i) ==
  /\ i \in inbox /\ ~reqs[i].waiting
  /\ inbox' = inbox \ {i}
  /\ reqs' = [reqs EXCEPT ![i] = Gone]
  /\ UNCHANGED <<host, held, revision, refreshing, pending, asks, acts, created, row, madeOver>>

(* An agent's event, or another Emacs retiring the task. *)
AgentEvent(t) ==
  /\ hpresent[t] /\ hver[t] < MaxVer
  /\ hver' = [hver EXCEPT ![t] = @ + 1]
  /\ UNCHANGED <<hpresent, hover, hbase, hshown, held, revision, refreshing, pending,
                 reqs, inbox, asks, acts, created, row, madeOver>>

(* The agent shows an image or a page, through its MCP server's show_image *)
(* or show_widget: keep_shown saves what the record says it shows, with a  *)
(* new `at', under the registry lock.  "The agent's status and `updatedAt' *)
(* stay as they were, as showing is no event of its own."                  *)
AgentShows(t) ==
  /\ hpresent[t] /\ hshown[t] < MaxShown
  /\ hshown' = [hshown EXCEPT ![t] = @ + 1]
  /\ UNCHANGED <<hpresent, hver, hover, hbase, held, revision, refreshing, pending,
                 reqs, inbox, asks, acts, created, row, madeOver>>

(* What else moves offersAt reaches Emacs through the same merge, and so  *)
(* adds nothing to what NoOfferRollback checks but time: the agent's own  *)
(* offers, through its MCP server's propose_task; and a listing, which    *)
(* takes the offer a task was made from if that creation was cut short    *)
(* (taken_offers), under the list's hold of the lock, so as a take run    *)
(* just before it.  Each is as a take that Emacs gave up on and its host  *)
(* ran all the same, which is here.  So is another Emacs's B, for         *)
(* retargetedAt.  So, for the clock a pull request left to its agent has  *)
(* (prLeftAt), are `leave' and `tell', which roost--act asks as it asks a *)
(* take, the second from within roost--cache-task: pull_request_left has  *)
(* them.                                                                   *)

OtherRetires(t) ==
  /\ hpresent[t] /\ hver[t] < MaxVer
  /\ (t \in News /\ CreateWaiting(t)) => "others act before create replies" \in Allow
  /\ hpresent' = [hpresent EXCEPT ![t] = FALSE]
  /\ hver' = [hver EXCEPT ![t] = @ + 1]
  /\ UNCHANGED <<hover, hbase, hshown, held, revision, refreshing, pending,
                 reqs, inbox, asks, acts, created, row, madeOver>>

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
          THEN /\ reqs' = NewList(rs, revision, rowDue) /\ inbox' = Kept(i) \cup {Len(rs) + 1}
               /\ pending' = FALSE /\ refreshing' = TRUE
          ELSE /\ reqs' = rs /\ inbox' = Kept(i)
               /\ refreshing' = FALSE /\ pending' = FALSE

Over(i) == /\ reqs' = Ended(reqs, i) /\ inbox' = Kept(i)
           /\ UNCHANGED <<refreshing, pending>>

(* roost-retarget's callback: the reply over, it asks its host to measure *)
(* the task against its new branch, with roost--refresh-host, not quiet,  *)
(* in the same sentinel, where no quit comes.  REV is the revision by     *)
(* then, which roost--act bumped first.                                   *)
OverAndRefresh(i, rev) ==
  LET rs == Ended(reqs, i)
  IN IF refreshing /\ Break # "NoRefreshingGuard"
     THEN /\ reqs' = rs /\ inbox' = Kept(i)
          /\ pending' = TRUE /\ UNCHANGED refreshing
     ELSE \/ /\ reqs' = NewList(rs, rev, rowDue) /\ inbox' = Kept(i) \cup {Len(rs) + 1}
             /\ refreshing' = TRUE /\ UNCHANGED pending
          \* It can't start, as in AskRefresh.
          \/ /\ reqs' = rs /\ inbox' = Kept(i)
             /\ refreshing' = (Break = "NoUnwind") /\ UNCHANGED pending

(* A list that came to nothing: failed, given up on, or dropped for a     *)
(* mutation's reply since it began (`lost' in roost--refresh-host).  One  *)
(* asked since an offer's draft asked for its host to be listed excuses   *)
(* that: its host is asked again by the next poll, which is not here.     *)
Lost(i) == rowExcused' = (rowExcused \/ (reqs[i].kind = "list" /\ reqs[i].after))

(* FAILURE: refused, timed out, or the connection dropped.  A refresh     *)
(* finishes; an action, inspection or creation changes nothing here.      *)
Fail(i) ==
  /\ IF reqs[i].kind = "list" THEN Finish(i, pending) ELSE Over(i)
  /\ Lost(i)
  /\ UNCHANGED <<held, revision, rowOwed, rowDue>>

(* SUCCESS, by kind. *)
Succeed(i) ==
  LET r == reqs[i]
      a == r.answer
      bumped == IF Break = "BumpAtRequest" THEN revision ELSE revision + 1
  IN
  CASE r.kind = "list" ->
         \* A mutation's reply since the list began wins over it.
         IF r.rev0 # revision /\ Break # "NoRevisionCheck"
         THEN /\ UNCHANGED <<held, revision, rowOwed, rowDue>>
              /\ Lost(i)
              /\ Finish(i, pending)
         ELSE /\ Cache(ApplySnapshot(cache, a.snap))
              /\ UNCHANGED <<revision, row>>
              \* A quiet poll that saw a change asks to measure it:
              \* roost--refresh-host calls itself while the flag is still
              \* set, so a full refresh is owed.
              /\ \E owe \in IF r.quiet THEN BOOLEAN ELSE {FALSE} :
                   Finish(i, pending \/ (owe /\ refreshing))
    \* roost--act bumps the revision at every action's reply, a take's too.
    \* roost-retire's stop of an agent with work in the background, whose
    \* callback asks to retire it, is these two, the second asked as the
    \* first replies.
    [] r.kind \in {"stop", "retire", "take"} ->
         /\ revision' = bumped
         /\ Cache(CacheReply(cache, r.task, a.rec, r.listed))
         /\ Over(i)
         /\ UNCHANGED row
    \* And B's, whose callback then asks for the task to be measured.
    [] r.kind = "retarget" ->
         /\ revision' = bumped
         /\ Cache(CacheReply(cache, r.task, a.rec, r.listed))
         /\ OverAndRefresh(i, bumped)
         /\ UNCHANGED row
    [] r.kind = "inspect" ->
         /\ Cache(CacheReply(cache, r.task, a.rec, r.listed))
         /\ UNCHANGED <<revision, row>>
         /\ Over(i)
    \* roost--task-made caches it with roost--cache-reply, LISTED being
    \* whether it went since Emacs held it (`roost--went`): Emacs held it
    \* once its version is past the 0 it starts at.  Broken:
    \* `CreateNoWentCheck` caches it with roost--cache-task, as before.
    \* Then, once you are out of the minibuffer, it calls the draft's
    \* callback (ON-SUCCESS), which for the draft of an offer asks for
    \* the host to be listed: RefreshForOffer, now or later.
    [] r.kind = "create" ->
         /\ revision' = bumped
         /\ Cache(IF Break = "CreateNoWentCheck" THEN CacheTask(cache, r.task, a.rec)
                  ELSE CacheReply(cache, r.task, a.rec, cache[r.task].ver > 0))
         /\ Over(i)
         /\ rowOwed' = (rowOwed \/ r.task \in FromOffer)
         /\ UNCHANGED <<rowDue, rowExcused>>

Deliver(i) ==
  /\ reqs[i].waiting /\ reqs[i].answer.tag # "none"
  /\ IF reqs[i].answer.tag = "ok" THEN Succeed(i) ELSE Fail(i)
  /\ UNCHANGED <<host, asks, acts, created, madeOver>>

(* roost--expire-request's timer, or the connection dropping. *)
GiveUp(i) ==
  /\ reqs[i].waiting
  /\ Fail(i)
  /\ UNCHANGED <<host, asks, acts, created, madeOver>>

(* roost-compose-submit's callback for the draft of an offer, once its    *)
(* task is made: "Its host took the offer it was made from: list it       *)
(* again, so the offer's row goes now.  Not quietly, which a poll in      *)
(* flight, read before the task was made, would drop."  It is             *)
(* roost--refresh-host, not quiet, for t1; roost--task-made calls it once *)
(* you are out of the minibuffer, so in the sentinel that took the reply  *)
(* in or later, after the revision's bump either way.  Broken:            *)
(* `QuietOfferRefresh' asks quietly, which does nothing while a list is   *)
(* in flight.                                                             *)
RefreshForOffer ==
  /\ rowOwed
  /\ rowOwed' = FALSE /\ rowDue' = TRUE
  /\ IF refreshing /\ Break # "NoRefreshingGuard"
     THEN /\ pending' = (pending \/ Break # "QuietOfferRefresh")
          /\ UNCHANGED <<refreshing, reqs, inbox, rowExcused>>
     ELSE \/ /\ reqs' = Append(reqs, [Req("list", "none", Break = "QuietOfferRefresh", revision)
                                        EXCEPT !.after = TRUE])
             /\ inbox' = inbox \cup {Len(reqs) + 1}
             /\ refreshing' = TRUE /\ UNCHANGED <<pending, rowExcused>>
          \* It can't start, as in AskRefresh: what it was for is still to
          \* do (`lost'), which the next poll takes up.
          \/ /\ refreshing' = (Break = "NoUnwind") /\ rowExcused' = TRUE
             /\ UNCHANGED <<pending, reqs, inbox>>
  /\ UNCHANGED <<host, held, revision, asks, acts, created, madeOver>>

Next ==
  \/ \E q \in BOOLEAN : AskRefresh(q)
  \/ \E k \in {"stop", "retire", "inspect"}, t \in ActOn : AskAct(k, t)
  \* Taking another task's offers, or retargeting it, adds nothing t1's
  \* don't, and costs time.
  \/ MaxOver > 0 /\ "t1" \in ActOn /\ AskAct("take", "t1")
  \/ MaxBase > 0 /\ "t1" \in ActOn /\ AskAct("retarget", "t1")
  \/ \E t \in News : AskCreate(t)
  \/ RefreshForOffer
  \/ \E i \in DOMAIN reqs : HostRun(i) \/ HostLoses(i) \/ Deliver(i) \/ GiveUp(i)
  \* Events of a new task's agent, once made, add nothing t1's don't, and cost time.
  \* Nor does what it shows.
  \/ AgentEvent("t1") \/ \E t \in Tasks : OtherRetires(t)
  \/ MaxShown > 0 /\ AgentShows("t1")
  \/ UNCHANGED vars  \* bounded runs end; that is no deadlock

Init ==
  /\ hpresent = [t \in Tasks |-> t \notin News]
  /\ hver = [t \in Tasks |-> IF t \in News THEN 0 ELSE 1]
  /\ hover = [t \in Tasks |-> 0]
  /\ hbase = [t \in Tasks |-> 0]
  /\ hshown = [t \in Tasks |-> 0]
  /\ cache = [t \in Tasks |-> HostRec(t)]
  /\ high = [t \in Tasks |-> hver[t]]
  /\ highOver = [t \in Tasks |-> 0]
  /\ highBase = [t \in Tasks |-> 0]
  /\ highShown = [t \in Tasks |-> 0]
  /\ revision = 0
  /\ refreshing = FALSE
  /\ pending = FALSE
  /\ reqs = << >>
  /\ inbox = {}
  /\ asks = 0 /\ acts = 0 /\ created = {}
  /\ rowOwed = FALSE /\ rowDue = FALSE /\ rowExcused = FALSE
  /\ madeOver = 0

ASSUME FromOffer \subseteq News

Spec == Init /\ [][Next]_vars

(***************************************************************************)
(* The rules.                                                              *)
(***************************************************************************)

(* A reply never takes Emacs back to older news of a task: it doesn't     *)
(* bring back a task that went, drop one Emacs knows is there, or roll a  *)
(* record back to an older updatedAt.                                      *)
NoRollback == \A t \in Tasks : cache[t].ver = high[t]

(* Nor brings back an offer you took, or hides one made since: a task     *)
(* Emacs lists has the newest offers it has held.                         *)
NoOfferRollback == \A t \in Tasks : cache[t].present => cache[t].over = highOver[t]

(* Nor takes a task back to the branch it merged into before B: a task    *)
(* Emacs lists has the newest it has held.                                *)
NoBranchRollback == \A t \in Tasks : cache[t].present => cache[t].base = highBase[t]

(* Nor takes a task back to what it showed before, or to nothing: a task  *)
(* Emacs lists says it shows the newest image or page Emacs has held of   *)
(* it.                                                                     *)
NoShownRollback == \A t \in Tasks : cache[t].present => cache[t].shown = highShown[t]

(* At most one list waits, the refresh flag says whether one does, so a   *)
(* host is never left unasked, and what is owed has a refresh to run it.  *)
OneList ==
  /\ Cardinality(ListsWaiting) <= 1
  /\ refreshing = (ListsWaiting # {})
  /\ pending => refreshing

(* Once a task is made from an offer and its draft has asked for the host *)
(* to be listed, the offer's row goes: with no list in flight, and none   *)
(* asked since then that came to nothing, Emacs holds t1 with the offer   *)
(* taken, or not at all.                                                   *)
OfferRowGoes ==
  (rowDue /\ ~rowExcused /\ ~refreshing) => (cache["t1"].present => cache["t1"].over >= madeOver)

=============================================================================
