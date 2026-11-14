-------------------------- MODULE LeftPullRequest --------------------------
(***************************************************************************)
(* A pull request left to its agent: the helper's `leave` and `tell`, and  *)
(* Emacs deciding when to tell and whose turn it is.                       *)
(* docs/state-machines.md: "A pull request left to its agent".             *)
(*                                                                         *)
(* One task with one open pull request.  Its head is a number, which each  *)
(* push of the agent's raises; a check fails on it or not.  Review threads *)
(* are the time of the newest comment in one unresolved, or 0.  The host's *)
(* clock is a number that each stamped write raises.  Emacs holds a copy   *)
(* of the record and of what the forge said, from replies that come late,  *)
(* out of order, or never.  The agent, you and a reviewer act at any step. *)
(***************************************************************************)
EXTENDS Naturals, Sequences, FiniteSets

CONSTANTS
  MaxPushes,    \* pushes the agent makes
  MaxComments,  \* comments, the reviewer's and the agent's
  MaxLeaves,    \* L presses, here or in another Emacs
  MaxTells,     \* `tell` requests
  MaxPolls,     \* list replies read
  MaxPrompts,   \* prompts of your own
  Most,         \* TOLD_MOST, `roost--told-most` (5 in the code)
  \* The code as it is: each TRUE, and Kept 0.  Another value is a broken variant.
  RestCheck,         \* `tell` refuses unless the status is ready, and no interrupt
  RecordFirst,       \* `tell` writes `prTold` before the paste
  GenInSendId,       \* the send ID has `prLeftGen`
  Kept,              \* entries `prTold` keeps: 0 for all, until left afresh
  NewerLeft,         \* `roost--newer-left`
  UntoldHides,       \* `roost--agents-turn-p` leaves what was refused to you
  EventEndsGrace,    \* and what the agent has done something since
  NewerCommentsOnly, \* `roost--tell-due-p`: threads again only for a comment since the agent's last event
  \* Scope.
  Kills,      \* a helper killed between the record and the paste, or after it
  OtherEmacs, \* `tell` asked by another Emacs, with no guard of this one's
  ThisEmacs,  \* this Emacs, with its cache and replies; without, only the host
  LateTake    \* the helper takes a request after Emacs stopped waiting for it

None == 0
Ci == "ci failed"
Comments == "comments"

VARIABLES
  clock,     \* the host's clock
  rec,       \* the task's record: prLeft, prLeftGen, prTold, prLeftAt, status, lastEvent, updatedAt
  pr,        \* the pull request on the forge: head, whether a check fails on it, newest unresolved comment
  own,       \* the comments that are the agent's own, by their time
  inbox,     \* a line is pasted that the agent has yet to take
  sendIds,   \* the record's `sendIds`
  pastes,    \* what Roost pasted of the pull request, in order
  reqs,      \* every `tell` request, and what became of it
  waits,     \* those this Emacs still waits on
  mail,      \* replies on their way to Emacs
  cache,     \* `roost--tasks`: the record and what the forge said, as Emacs has them
  seenLeft,  \* the newest `prLeftAt` Emacs has been given
  telling,   \* `roost--telling`
  untold,    \* `roost--untold`
  expired,   \* tellings whose two minutes are over
  pushes, comments, leaves, polls, prompts

vars == <<clock, rec, pr, own, inbox, sendIds, pastes, reqs, waits, mail, cache, seenLeft,
          telling, untold, expired, pushes, comments, leaves, polls, prompts>>

Reqs == 1..Len(reqs)
Pastes == 1..Len(pastes)
\* `tell` runs under the registry lock, which the agent's hooks wait for.
Busy == \E r \in Reqs : reqs[r].state \in {"recorded", "pasted"}

Last(s, n) == IF Len(s) > n THEN SubSeq(s, Len(s) - n + 1, Len(s)) ELSE s
Of(told, v) == {i \in 1..Len(told) : told[i].v = v}

-----------------------------------------------------------------------------
(* Emacs's reading of what it holds                                        *)

\* `roost--any-turn`, of `roost--pr-verdict`: only once the forge was asked
\* after the agent's last event, and the agent neither works nor asks.
Turn(c) ==
  IF c.status = "running" \/ ~(c.updatedAt < c.checkedAt) THEN "none"
  ELSE IF c.failing THEN Ci
  ELSE IF c.latest > 0 THEN Comments
  ELSE "none"

Key(c, t) == IF t = Ci THEN c.head ELSE c.latest          \* `roost--tell-key`
Occ(c, t) == <<t, Key(c, t), c.gen>>                      \* `roost--tell-occurrence`
ToldOf(c, t) == Of(c.told, t)                             \* `roost--told`
Entries(c, t) == {i \in ToldOf(c, t) : c.told[i].key = Key(c, t)}  \* `roost--told-entry`

Due(c) ==                                                 \* `roost--tell-due-p`
  LET t == Turn(c) IN
  /\ c.left /\ t # "none"
  /\ c.status = "ready"
  /\ Entries(c, t) = {}
  /\ Cardinality(ToldOf(c, t)) < Most
  /\ (t # Comments \/ ToldOf(c, t) = {} \/ ~NewerCommentsOnly \/ c.updatedAt < c.latest)
  /\ untold # Occ(c, t)

AgentsTurn(c) ==                                          \* `roost--agents-turn-p`
  LET t == Turn(c) IN
  /\ t # "none"
  /\ \/ Due(c)
     \/ /\ c.left /\ c.status # "exited"
        /\ (~UntoldHides \/ untold # Occ(c, t))
        /\ \E i \in Entries(c, t) :
             /\ (~EventEndsGrace \/ ~(c.told[i].at < c.updatedAt))
             /\ Occ(c, t) \notin expired

\* A reply into the cache: `roost--cache-task`.  An older word of the agent
\* keeps the record Emacs has (`roost--newer-events`), an older word of the
\* leaving keeps what it has of that (`roost--newer-left`), and what the
\* forge said is as new as the reply that has it.
Merge(m, c) ==
  LET older == m.updatedAt < c.updatedAt
      keepLeft == older \/ (NewerLeft /\ m.leftAt < c.leftAt)
  IN [left |-> IF keepLeft THEN c.left ELSE m.left,
      gen |-> IF keepLeft THEN c.gen ELSE m.gen,
      told |-> IF keepLeft THEN c.told ELSE m.told,
      leftAt |-> IF keepLeft THEN c.leftAt ELSE m.leftAt,
      status |-> IF older THEN c.status ELSE m.status,
      intr |-> IF older THEN c.intr ELSE m.intr,
      updatedAt |-> IF older THEN c.updatedAt ELSE m.updatedAt,
      head |-> IF m.full THEN m.head ELSE c.head,
      failing |-> IF m.full THEN m.failing ELSE c.failing,
      latest |-> IF m.full THEN m.latest ELSE c.latest,
      checkedAt |-> IF m.full THEN m.checkedAt ELSE c.checkedAt]

\* What a reply says: the record, and with FULL what the forge says now.
Snap(r, at, full, mine) ==
  [left |-> r.left, gen |-> r.gen, told |-> r.told, leftAt |-> r.leftAt,
   status |-> r.status, intr |-> r.intr, updatedAt |-> r.updatedAt,
   head |-> pr.head, failing |-> pr.failing, latest |-> pr.latest,
   checkedAt |-> at, full |-> full, mine |-> mine]

-----------------------------------------------------------------------------
(* The agent, you and the reviewer                                         *)

World == UNCHANGED <<sendIds, pastes, reqs, waits, mail, cache, seenLeft, telling, untold, expired>>

\* Its UserPromptSubmit hook: whatever was pasted is one turn's prompt.
AgentTakes ==
  /\ ~Busy /\ inbox /\ rec.status = "ready"
  /\ clock' = clock + 1
  /\ rec' = [rec EXCEPT !.status = "running", !.intr = FALSE, !.updatedAt = clock + 1]
  /\ inbox' = FALSE
  /\ World /\ UNCHANGED <<pr, own, pushes, comments, leaves, polls, prompts>>

AgentPushes ==
  /\ rec.status = "running" /\ pushes < MaxPushes
  /\ \E fails \in BOOLEAN : pr' = [pr EXCEPT !.head = pr.head + 1, !.failing = fails]
  /\ pushes' = pushes + 1
  /\ World /\ UNCHANGED <<clock, rec, own, inbox, comments, leaves, polls, prompts>>

\* It answers in a thread and leaves it open, or resolves it.
AgentAnswers ==
  /\ rec.status = "running" /\ pr.latest > 0
  /\ \/ /\ comments < MaxComments
        /\ clock' = clock + 1
        /\ pr' = [pr EXCEPT !.latest = clock + 1]
        /\ own' = own \cup {clock + 1}
        /\ comments' = comments + 1
     \/ /\ pr' = [pr EXCEPT !.latest = 0]
        /\ UNCHANGED <<clock, own, comments>>
  /\ World /\ UNCHANGED <<rec, inbox, pushes, leaves, polls, prompts>>

AgentStops ==
  /\ ~Busy /\ rec.status = "running"
  /\ clock' = clock + 1
  /\ rec' = [rec EXCEPT !.status = "ready", !.updatedAt = clock + 1]
  /\ World /\ UNCHANGED <<pr, own, inbox, pushes, comments, leaves, polls, prompts>>

AgentExits ==
  /\ ~Busy /\ rec.status # "exited"
  /\ clock' = clock + 1
  /\ rec' = [rec EXCEPT !.status = "exited", !.updatedAt = clock + 1]
  /\ World /\ UNCHANGED <<pr, own, inbox, pushes, comments, leaves, polls, prompts>>

\* Esc in its terminal.
YouInterrupt ==
  /\ ~Busy /\ rec.status = "running"
  /\ clock' = clock + 1
  /\ rec' = [rec EXCEPT !.status = "ready", !.intr = TRUE, !.updatedAt = clock + 1]
  /\ World /\ UNCHANGED <<pr, own, inbox, pushes, comments, leaves, polls, prompts>>

\* A prompt of your own.
YouPrompt ==
  /\ ~Busy /\ rec.status = "ready" /\ prompts < MaxPrompts
  /\ inbox' = TRUE
  /\ prompts' = prompts + 1
  /\ World /\ UNCHANGED <<clock, rec, pr, own, pushes, comments, leaves, polls>>

ReviewerComments ==
  /\ comments < MaxComments
  /\ clock' = clock + 1
  /\ pr' = [pr EXCEPT !.latest = clock + 1]
  /\ comments' = comments + 1
  /\ World /\ UNCHANGED <<rec, own, inbox, pushes, leaves, polls, prompts>>

-----------------------------------------------------------------------------
(* The helper                                                              *)

\* `leave`, from this Emacs (whose reply forgets what was refused) or another.
Leave ==
  /\ ~Busy /\ leaves < MaxLeaves
  /\ clock' = clock + 1
  /\ rec' = [rec EXCEPT !.left = ~rec.left, !.told = <<>>, !.gen = rec.gen + 1, !.leftAt = clock + 1]
  /\ leaves' = leaves + 1
  /\ IF ThisEmacs
     THEN \E mine \in (IF OtherEmacs THEN BOOLEAN ELSE {TRUE}) :
            mail' = mail \cup {Snap(rec', None, FALSE, mine)}
     ELSE UNCHANGED mail
  /\ UNCHANGED <<pr, own, inbox, sendIds, pastes, reqs, waits, cache, seenLeft, telling, untold, expired,
                 pushes, comments, polls, prompts>>

\* A list that asks the forge too.  A quiet one says no more of the record
\* than the replies to `leave` and `tell` do.
Poll ==
  /\ ThisEmacs /\ ~Busy /\ polls < MaxPolls
  /\ polls' = polls + 1
  /\ clock' = clock + 1
  /\ mail' = mail \cup {Snap(rec, clock + 1, TRUE, FALSE)}
  /\ UNCHANGED <<rec, pr, own, inbox, sendIds, pastes, reqs, waits, cache, seenLeft, telling, untold, expired,
                 pushes, comments, leaves, prompts>>

Handled(r, result) ==
  reqs' = [reqs EXCEPT ![r].state = "handled", ![r].result = result,
                       ![r].snap = Snap(rec', None, FALSE, FALSE)]

Entry(r) == [v |-> reqs[r].v, key |-> reqs[r].key, at |-> clock + 1, req |-> r]
Recorded(r) ==
  /\ clock' = clock + 1
  /\ rec' = [rec EXCEPT !.told = IF Kept = 0 THEN Append(rec.told, Entry(r))
                                  ELSE Last(Append(rec.told, Entry(r)), Kept),
                        !.leftAt = clock + 1]

HostQuiet == UNCHANGED <<pr, own, waits, mail, cache, seenLeft, telling, untold, expired,
                         pushes, comments, leaves, polls, prompts>>

\* `tell`, to where it writes the record.
Take(r) ==
  /\ ~Busy /\ reqs[r].state = "sent"
  /\ LET same == {i \in Of(rec.told, reqs[r].v) : TRUE}
         refuse == \/ ~rec.left
                   \/ /\ \A i \in same : rec.told[i].key # reqs[r].key
                      /\ \/ Cardinality(same) >= Most
                         \/ RestCheck /\ (rec.status # "ready" \/ rec.intr)
                         \/ rec.status = "exited"
     IN IF refuse
        THEN /\ UNCHANGED <<clock, rec>> /\ Handled(r, "refused")
        ELSE IF \E i \in same : rec.told[i].key = reqs[r].key
        THEN /\ UNCHANGED <<clock, rec>> /\ Handled(r, "already")
        ELSE /\ IF RecordFirst THEN Recorded(r) ELSE UNCHANGED <<clock, rec>>
             /\ reqs' = [reqs EXCEPT ![r].state = "recorded"]
  /\ UNCHANGED <<inbox, sendIds, pastes>> /\ HostQuiet

SendId(r) == IF GenInSendId THEN <<rec.gen, reqs[r].v, reqs[r].key>> ELSE <<None, reqs[r].v, reqs[r].key>>
Pasted(r) ==
  /\ pastes' = Append(pastes, [gen |-> rec.gen, v |-> reqs[r].v, key |-> reqs[r].key,
                               rest |-> rec.status = "ready" /\ ~rec.intr,
                               since |-> rec.updatedAt = reqs[r].asOf,
                               own |-> reqs[r].v = Comments /\ reqs[r].key \in own])
  /\ inbox' = TRUE

\* `send`: the paste, unless its ID went before; tmux may take the line and
\* say it failed, or fail and take none.
Paste(r) ==
  /\ reqs[r].state = "recorded"
  /\ IF SendId(r) \in sendIds
     THEN /\ UNCHANGED <<inbox, pastes, clock, rec>> /\ Handled(r, "told")
     ELSE \/ /\ Pasted(r) /\ reqs' = [reqs EXCEPT ![r].state = "pasted"] /\ UNCHANGED <<clock, rec>>
          \/ /\ Pasted(r) /\ UNCHANGED <<clock, rec>> /\ Handled(r, "failed")
          \/ /\ UNCHANGED <<inbox, pastes, clock, rec>> /\ Handled(r, "failed")
  /\ UNCHANGED sendIds /\ HostQuiet

\* Its ID is written after the paste.
Record(r) ==
  /\ reqs[r].state = "pasted"
  /\ sendIds' = sendIds \cup {SendId(r)}
  /\ IF RecordFirst THEN UNCHANGED <<clock, rec>> ELSE Recorded(r)
  /\ Handled(r, "told")
  /\ UNCHANGED <<inbox, pastes>> /\ HostQuiet

Killed(r) ==
  /\ Kills /\ reqs[r].state \in {"recorded", "pasted"}
  /\ reqs' = [reqs EXCEPT ![r].state = "killed"]
  /\ UNCHANGED <<clock, rec, inbox, sendIds, pastes>> /\ HostQuiet

\* Another Emacs asks, of what the forge says now.
OtherAsks ==
  /\ OtherEmacs /\ Len(reqs) < MaxTells
  /\ \E v \in {Ci, Comments} :
       /\ (v = Ci => pr.failing) /\ (v = Comments => pr.latest > 0)
       /\ reqs' = Append(reqs, [v |-> v, key |-> IF v = Ci THEN pr.head ELSE pr.latest,
                                occ |-> <<v, None, None>>, asOf |-> rec.updatedAt,
                                state |-> "sent", result |-> "none",
                                snap |-> Snap(rec, None, FALSE, FALSE)])
  /\ UNCHANGED <<clock, rec, inbox, sendIds, pastes>> /\ HostQuiet

-----------------------------------------------------------------------------
(* Emacs                                                                   *)

EmacsQuiet == UNCHANGED <<clock, rec, pr, own, inbox, sendIds, pastes,
                          pushes, comments, leaves, polls, prompts>>

Cached(m) ==
  /\ cache' = Merge(m, cache)
  /\ seenLeft' = IF m.leftAt > seenLeft THEN m.leftAt ELSE seenLeft

Deliver(m) ==
  /\ m \in mail /\ mail' = mail \ {m}
  /\ Cached(m)
  /\ untold' = IF m.mine THEN <<>> ELSE untold
  /\ UNCHANGED <<reqs, waits, telling, expired>> /\ EmacsQuiet

\* `roost--tell-agent`
Tells ==
  /\ ThisEmacs /\ Due(cache) /\ telling = <<>> /\ Len(reqs) < MaxTells
  /\ LET t == Turn(cache) IN
       /\ reqs' = Append(reqs, [v |-> t, key |-> Key(cache, t), occ |-> Occ(cache, t),
                                asOf |-> cache.updatedAt, state |-> "sent", result |-> "none",
                                snap |-> Snap(rec, None, FALSE, FALSE)])
       /\ telling' = Occ(cache, t)
  /\ waits' = waits \cup {Len(reqs) + 1}
  /\ UNCHANGED <<mail, cache, seenLeft, untold, expired>> /\ EmacsQuiet

Reply(r) ==
  /\ r \in waits /\ reqs[r].state = "handled"
  /\ waits' = waits \ {r}
  /\ telling' = <<>>
  /\ IF reqs[r].result \in {"told", "already"}
     THEN Cached(reqs[r].snap) /\ UNCHANGED untold
     ELSE untold' = reqs[r].occ /\ UNCHANGED <<cache, seenLeft>>
  /\ UNCHANGED <<reqs, mail, expired>> /\ EmacsQuiet

\* No reply in time: the request never reached the helper, or its reply is
\* lost; with LateTake, the helper may still take it.
NoReply(r) ==
  /\ r \in waits
  /\ waits' = waits \ {r}
  /\ telling' = <<>>
  /\ untold' = reqs[r].occ
  /\ reqs' = IF reqs[r].state = "sent" /\ ~LateTake
             THEN [reqs EXCEPT ![r].state = "dropped"] ELSE reqs
  /\ UNCHANGED <<mail, cache, seenLeft, expired>> /\ EmacsQuiet

\* Two minutes pass since the telling Emacs knows of, of what stands.
GraceEnds ==
  /\ Turn(cache) # "none" /\ Entries(cache, Turn(cache)) # {}
  /\ Occ(cache, Turn(cache)) \notin expired
  /\ expired' = expired \cup {Occ(cache, Turn(cache))}
  /\ UNCHANGED <<reqs, waits, mail, cache, seenLeft, telling, untold>> /\ EmacsQuiet

-----------------------------------------------------------------------------

Init ==
  /\ clock = 1
  /\ rec = [left |-> FALSE, gen |-> 1, told |-> <<>>, leftAt |-> 0,
            status |-> "ready", intr |-> FALSE, updatedAt |-> 1]
  /\ \E fails \in BOOLEAN : pr = [head |-> 1, failing |-> fails, latest |-> 0]
  /\ own = {} /\ inbox = FALSE /\ sendIds = {} /\ pastes = <<>> /\ reqs = <<>> /\ waits = {} /\ mail = {}
  /\ cache = [left |-> FALSE, gen |-> 1, told |-> <<>>, leftAt |-> 0, status |-> "ready", intr |-> FALSE,
              updatedAt |-> 1, head |-> 1, failing |-> FALSE, latest |-> 0, checkedAt |-> 0]
  /\ seenLeft = 0 /\ telling = <<>> /\ untold = <<>> /\ expired = {}
  /\ pushes = 0 /\ comments = 0 /\ leaves = 0 /\ polls = 0 /\ prompts = 0

Next ==
  \/ AgentTakes \/ AgentPushes \/ AgentAnswers \/ AgentStops \/ AgentExits
  \/ YouInterrupt \/ YouPrompt \/ ReviewerComments
  \/ Leave \/ Poll \/ OtherAsks
  \/ \E r \in Reqs : Take(r) \/ Paste(r) \/ Record(r) \/ Killed(r) \/ Reply(r) \/ NoReply(r)
  \/ \E m \in mail : Deliver(m)  \* or never
  \/ Tells \/ GraceEnds
  \/ UNCHANGED vars  \* nothing more happens

Spec == Init /\ [][Next]_vars

-----------------------------------------------------------------------------
(* Rules                                                                   *)

TypeOK ==
  /\ rec.status \in {"ready", "running", "exited"}
  /\ waits \subseteq Reqs

Same(i, j) == pastes[i].gen = pastes[j].gen /\ pastes[i].v = pastes[j].v

\* I2: a line of Roost's lands only at a prompt the agent rests at, after a
\* turn it ended itself.
OnlyAtRest == \A i \in Pastes : pastes[i].rest

\* I3: once for each thing, each time the pull request is left.
ToldOnce ==
  \A i, j \in Pastes : (i # j /\ Same(i, j)) => pastes[i].key # pastes[j].key

\* I5: so many times at most for one kind, each time it is left.
AtMost ==
  \A i \in Pastes : Cardinality({j \in Pastes : Same(i, j)}) <= Most

\* I3: what the record says the agent was told, it was, unless the helper
\* was killed or tmux said the paste failed, which Emacs then leaves to you.
RecordedIsPasted ==
  \A i \in 1..Len(rec.told) :
    LET e == rec.told[i] IN
    \/ reqs[e.req].state \in {"recorded", "pasted", "killed"}
    \/ reqs[e.req].result = "failed"
    \/ \E p \in Pastes : pastes[p].gen = rec.gen /\ pastes[p].v = e.v /\ pastes[p].key = e.key

\* I4: of threads again only for a comment that is not the agent's own.
ThreadsNoEcho ==
  \A i \in Pastes :
    (pastes[i].v = Comments /\ \E j \in 1..(i - 1) : Same(i, j)) => ~pastes[i].own

\* I7: an older reply undoes no leaving, taking back or telling in Emacs.
CacheLeftNewest == cache.leftAt = seenLeft

\* I6: what Roost knows it did not tell the agent waits on you.
RefusedIsYours ==
  (Turn(cache) # "none" /\ untold = Occ(cache, Turn(cache))) => ~AgentsTurn(cache)

\* I6: an agent that was told, did something and rests has had its turn.
HadItsTurnIsYours ==
  LET t == Turn(cache) IN
  (t # "none" /\ Entries(cache, t) # {}
              /\ \A i \in Entries(cache, t) : cache.told[i].at < cache.updatedAt)
    => ~AgentsTurn(cache)

\* Not kept by the code: see LeftPullRequest.finding-told-after-a-turn.cfg.
\* The agent has done nothing since what Emacs judged by.
NothingSinceJudged == \A i \in Pastes : pastes[i].since

=============================================================================
