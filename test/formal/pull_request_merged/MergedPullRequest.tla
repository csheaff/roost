------------------------- MODULE MergedPullRequest -------------------------
(***************************************************************************)
(* A pull request Roost merges: the helper's `begin_merge`, its one call   *)
(* to the forge and `end_merge`, and Emacs deciding when to ask and whose  *)
(* turn `to merge` is.                                                     *)
(* docs/state-machines.md: "A pull request Roost merges".                  *)
(*                                                                         *)
(* One task with one pull request.  Its head is a number, which each push  *)
(* of the agent's raises.  It is green or not: what `roost--pr-verdict`    *)
(* reads as "to merge", with a check that passed, into the task's branch.  *)
(* A reviewer can take that away at the same head.  Emacs holds a copy of  *)
(* the record and of what the forge said, from replies that come late, out *)
(* of order, or never.  The agent, you, a reviewer and another Emacs act   *)
(* at any step.                                                            *)
(***************************************************************************)
EXTENDS Naturals, Sequences, FiniteSets

CONSTANTS
  MaxPushes,   \* pushes the agent makes
  MaxFlips,    \* times a reviewer, or a check, changes whether it is green
  MaxAsks,     \* `merge-pr` requests of this Emacs
  MaxOthers,   \* and of another Emacs, with no guard of this one's
  MaxPolls,    \* list replies read
  MaxVisits,   \* times you come to the task's terminal, or write it a prompt
  \* The code as it is: each TRUE.  FALSE is a broken variant.
  MadeCheck,     \* `begin_merge` refuses a task without `prMerge`
  OnceCheck,     \* and a head it has asked for
  KeepAll,       \* any time (`prMergeHeads`), and not only the last
  RecordFirst,   \* and writes `prMergeAsked` before the forge is asked
  MatchHead,     \* `gh pr merge --match-head-commit`
  ByVerdict,     \* `roost--merge-due-p` asks only for what reads "to merge"
  HoldWhileThere,\* `roost--merge-itself` holds off while you are there
  UnmergedHides, \* `roost--merges-turn-p` leaves what was refused to you
  AlreadySilent, \* `roost--merge-itself` says nothing of one asked for before
  \* Scope.
  Kills,       \* a helper killed between the record and the call, or after it
  ThisEmacs    \* this Emacs, with its cache and replies; without, only the host

NoAsk == [head |-> 0, out |-> "none"]

VARIABLES
  made,     \* the record's `prMerge`: the task was made for Roost to merge
  rec,      \* the record: `prMergeAsked` as [head, out], `prMergeHeads`, and the pull request's state as last recorded
  pr,       \* the pull request on the forge: head, green, state, the head it merged at
  greens,   \* the heads that were ever green
  calls,    \* each `gh pr merge`, in order: the head asked for, and the request
  reqs,     \* every `merge-pr` request, and what became of it
  waits,    \* those this Emacs still waits on
  mail,     \* replies on their way to Emacs
  cache,    \* `roost--tasks`: the record and what the forge said, as Emacs has them
  merging,  \* `roost--merging`: the head asked for, or 0
  unmerged, \* `roost--unmerged`: the head refused or never answered for, or 0
  expired,  \* heads whose two minutes are over
  there,    \* you are at the task's terminal, or writing its agent a prompt
  said,     \* what Roost said of a merge, in order: <<word, head>>
  pushes, flips, asks, others, polls, visits

vars == <<made, rec, pr, greens, calls, reqs, waits, mail, cache, merging, unmerged, expired, there, said,
          pushes, flips, asks, others, polls, visits>>

Reqs == 1..Len(reqs)
Calls == 1..Len(calls)

-----------------------------------------------------------------------------
(* Emacs's reading of what it holds                                        *)

Verdict(c) == c.state = "open" /\ c.green                 \* `roost--pr-verdict` says "to merge"
Asked(c) == IF c.asked.head = c.head /\ c.head # 0 THEN c.asked ELSE NoAsk   \* `roost--merge-asked`

Due(c) ==                                                 \* `roost--merge-due-p`
  /\ c.made
  /\ c.state = "open"
  /\ (Verdict(c) \/ ~ByVerdict)
  /\ Asked(c) = NoAsk
  /\ unmerged # c.head

MergesTurn(c) ==                                          \* `roost--merges-turn-p`
  \/ Due(c)
  \/ /\ Asked(c) # NoAsk
     /\ Asked(c).out # "error"
     /\ (~UnmergedHides \/ unmerged # c.head)
     /\ c.head \notin expired

Yours(c) == Verdict(c) /\ ~MergesTurn(c)                  \* `roost--yours`: the row reads "to merge"

\* What a reply says: the record, and with FULL what the forge says now.
Snap(r, full) ==
  [made |-> made, asked |-> r.asked, head |-> pr.head, green |-> pr.green, state |-> pr.state, full |-> full]

\* A reply into the cache: `roost--cache-task`.  No event of the agent's
\* stamps the record, so the reply's word of it replaces what Emacs has,
\* older or not; what the forge said is as new as the reply that has it.
Merge(m, c) ==
  [made |-> m.made, asked |-> m.asked,
   head |-> IF m.full THEN m.head ELSE c.head,
   green |-> IF m.full THEN m.green ELSE c.green,
   state |-> IF m.full THEN m.state ELSE c.state]

-----------------------------------------------------------------------------
(* The agent, a reviewer and you                                           *)

Emacs == UNCHANGED <<waits, mail, cache, merging, unmerged, expired, said, asks>>
Host == UNCHANGED <<made, rec, calls, reqs, others>>

AgentPushes ==
  /\ pushes < MaxPushes /\ pr.state = "open"
  /\ \E g \in BOOLEAN :
       /\ pr' = [pr EXCEPT !.head = @ + 1, !.green = g]
       /\ greens' = IF g THEN greens \cup {pr.head + 1} ELSE greens
  /\ pushes' = pushes + 1
  /\ Emacs /\ Host /\ UNCHANGED <<there, flips, polls, visits>>

\* A check ends, a review comes back, or a reviewer opens a thread.
ForgeChanges ==
  /\ flips < MaxFlips /\ pr.state = "open"
  /\ pr' = [pr EXCEPT !.green = ~@]
  /\ greens' = IF ~pr.green THEN greens \cup {pr.head} ELSE greens
  /\ flips' = flips + 1
  /\ Emacs /\ Host /\ UNCHANGED <<there, pushes, polls, visits>>

YouCome ==
  /\ ~there /\ visits < MaxVisits
  /\ there' = TRUE /\ visits' = visits + 1
  /\ Emacs /\ Host /\ UNCHANGED <<pr, greens, pushes, flips, polls>>

YouLeave ==
  /\ there /\ there' = FALSE
  /\ Emacs /\ Host /\ UNCHANGED <<pr, greens, pushes, flips, polls, visits>>

-----------------------------------------------------------------------------
(* The helper                                                              *)

HostQuiet == UNCHANGED <<made, greens, cache, merging, unmerged, expired, there, said,
                         pushes, flips, asks, others, polls, visits>>

Reply(r, m) == IF reqs[r].mine /\ ThisEmacs THEN mail \cup {m} ELSE mail

\* `begin_merge`, under the registry lock: refused, asked for already, or
\* recorded as asked for.
Takes(r) ==
  /\ reqs[r].st = "sent"
  /\ LET h == reqs[r].head IN
     IF (MadeCheck /\ ~made) \/ rec.state = "merged"
       THEN /\ reqs' = [reqs EXCEPT ![r].st = "done"]
            /\ mail' = Reply(r, [kind |-> "refused", req |-> r])
            /\ UNCHANGED rec
     ELSE IF OnceCheck /\ h \in (IF KeepAll THEN rec.heads ELSE {rec.asked.head})
       THEN /\ reqs' = [reqs EXCEPT ![r].st = "done"]
            /\ mail' = Reply(r, [kind |-> "act", req |-> r, already |-> TRUE, snap |-> Snap(rec, FALSE)])
            /\ UNCHANGED rec
     ELSE /\ reqs' = [reqs EXCEPT ![r].st = "begun"]
          /\ rec' = IF RecordFirst
                      THEN [rec EXCEPT !.asked = [head |-> h, out |-> "none"], !.heads = @ \cup {h}]
                      ELSE rec
          /\ UNCHANGED mail
  /\ UNCHANGED <<pr, calls, waits>> /\ HostQuiet

\* `merge_pull_request`, with the lock let go: GitHub merges it, at the
\* head asked for, or refuses.
AsksForge(r) ==
  /\ reqs[r].st = "begun"
  /\ calls' = Append(calls, [head |-> reqs[r].head, req |-> r])
  /\ \/ /\ pr.state = "open" /\ (pr.head = reqs[r].head \/ ~MatchHead)
        /\ pr' = [pr EXCEPT !.state = "merged", !.at = pr.head]
        /\ reqs' = [reqs EXCEPT ![r].st = "called", ![r].out = "merged"]
     \/ /\ UNCHANGED pr
        /\ reqs' = [reqs EXCEPT ![r].st = "called", ![r].out = "error"]
  /\ UNCHANGED <<rec, waits, mail>> /\ HostQuiet

\* `end_merge`, under the lock again: what came of it, unless another was
\* asked for since.
Ends(r) ==
  /\ reqs[r].st = "called"
  /\ LET h == reqs[r].head
         new == IF rec.asked.head = h \/ ~RecordFirst
                  THEN [rec EXCEPT !.asked = [head |-> h, out |-> reqs[r].out], !.heads = @ \cup {h}]
                  ELSE rec
     IN /\ rec' = new
        /\ mail' = Reply(r, [kind |-> "act", req |-> r, already |-> FALSE, snap |-> Snap(new, FALSE)])
  /\ reqs' = [reqs EXCEPT ![r].st = "done"]
  /\ UNCHANGED <<pr, calls, waits>> /\ HostQuiet

Killed(r) ==
  /\ Kills /\ reqs[r].st \in {"begun", "called"}
  /\ reqs' = [reqs EXCEPT ![r].st = "dead"]
  /\ UNCHANGED <<rec, pr, calls, waits, mail>> /\ HostQuiet

\* Another Emacs asks, of any head it may have judged by.
OtherAsks ==
  /\ others < MaxOthers
  /\ \E h \in 1..pr.head :
       reqs' = Append(reqs, [head |-> h, st |-> "sent", out |-> "none", mine |-> FALSE, there |-> FALSE])
  /\ others' = others + 1
  /\ UNCHANGED <<made, rec, pr, greens, calls, waits, mail, cache, merging, unmerged, expired, there, said,
                 pushes, flips, asks, polls, visits>>

\* A list: the record and the forge as they are, in a reply that may come
\* late.  `check_pull_requests` records the pull request's state.
Poll ==
  /\ polls < MaxPolls
  /\ rec' = [rec EXCEPT !.state = pr.state]
  /\ mail' = IF ThisEmacs
               THEN mail \cup {[kind |-> "list", req |-> polls + 1, already |-> FALSE,
                                snap |-> Snap(rec, TRUE)]}
               ELSE mail
  /\ polls' = polls + 1
  /\ UNCHANGED <<made, pr, greens, calls, reqs, waits, cache, merging, unmerged, expired, there, said,
                 pushes, flips, asks, others, visits>>

-----------------------------------------------------------------------------
(* This Emacs                                                              *)

EmacsQuiet == UNCHANGED <<made, rec, pr, greens, calls, there, pushes, flips, others, polls, visits>>

\* `roost--merge-itself`, as a task is cached.
Asks ==
  /\ ThisEmacs /\ asks < MaxAsks
  /\ Due(cache) /\ merging = 0
  /\ (~HoldWhileThere \/ ~there)
  /\ reqs' = Append(reqs, [head |-> cache.head, st |-> "sent", out |-> "none", mine |-> TRUE, there |-> there])
  /\ waits' = waits \cup {Len(reqs) + 1}
  /\ merging' = cache.head
  /\ asks' = asks + 1
  /\ UNCHANGED <<mail, cache, unmerged, expired, said>> /\ EmacsQuiet

\* A reply, in any order.  One to a request Emacs gave up on is dropped.
Hears(m) ==
  /\ mail' = mail \ {m}
  /\ IF m.kind = "list"
       THEN /\ cache' = Merge(m.snap, cache)
            /\ UNCHANGED <<waits, merging, unmerged, said>>
     ELSE IF m.req \notin waits
       THEN UNCHANGED <<cache, waits, merging, unmerged, said>>
     ELSE /\ waits' = waits \ {m.req}
          /\ merging' = 0
          /\ IF m.kind = "refused"
               THEN /\ unmerged' = reqs[m.req].head
                    /\ said' = Append(said, <<"refused", reqs[m.req].head>>)
                    /\ UNCHANGED cache
             ELSE /\ cache' = Merge(m.snap, cache)
                  \* Asked for before the last: nothing of it is left to read.
                  /\ unmerged' = IF m.already /\ m.snap.asked.head # reqs[m.req].head
                                  THEN reqs[m.req].head ELSE unmerged
                  /\ said' = IF m.already /\ AlreadySilent THEN said
                             ELSE IF m.snap.asked.out = "none" THEN said
                             ELSE Append(said, <<m.snap.asked.out, m.snap.asked.head>>)
  /\ UNCHANGED <<reqs, expired, asks>> /\ EmacsQuiet

\* No reply in time, as from a helper killed, or a host out of reach.
GivesUp(r) ==
  /\ r \in waits
  /\ waits' = waits \ {r}
  /\ merging' = 0
  /\ unmerged' = reqs[r].head
  /\ said' = Append(said, <<"refused", reqs[r].head>>)
  /\ UNCHANGED <<reqs, mail, cache, expired, asks>> /\ EmacsQuiet

Lost(m) ==
  /\ m.kind = "list"
  /\ mail' = mail \ {m}
  /\ UNCHANGED <<reqs, waits, cache, merging, unmerged, expired, said, asks>> /\ EmacsQuiet

\* Two minutes pass since a head was asked for.
GraceEnds ==
  /\ ThisEmacs
  \* Of the head Emacs holds, which alone it reads the two minutes of.
  /\ Asked(cache) # NoAsk /\ cache.head \notin expired
  /\ expired' = expired \cup {cache.head}
  /\ UNCHANGED <<reqs, waits, mail, cache, merging, unmerged, said, asks>> /\ EmacsQuiet

-----------------------------------------------------------------------------

Init ==
  /\ made \in BOOLEAN
  /\ rec = [asked |-> NoAsk, heads |-> {}, state |-> "open"]
  /\ pr = [head |-> 1, green |-> FALSE, state |-> "open", at |-> 0]
  /\ greens = {}
  /\ calls = <<>> /\ reqs = <<>> /\ waits = {} /\ mail = {}
  /\ cache = [made |-> made, asked |-> NoAsk, head |-> 1, green |-> FALSE, state |-> "open"]
  /\ merging = 0 /\ unmerged = 0 /\ expired = {} /\ there = FALSE /\ said = <<>>
  /\ pushes = 0 /\ flips = 0 /\ asks = 0 /\ others = 0 /\ polls = 0 /\ visits = 0

Next ==
  \/ AgentPushes \/ ForgeChanges \/ YouCome \/ YouLeave
  \/ \E r \in Reqs : Takes(r) \/ AsksForge(r) \/ Ends(r) \/ Killed(r) \/ GivesUp(r)
  \/ OtherAsks \/ Poll \/ Asks \/ GraceEnds
  \/ \E m \in mail : Hears(m) \/ Lost(m)
  \* Nothing more to do is no deadlock.
  \/ UNCHANGED vars

Spec == Init /\ [][Next]_vars

-----------------------------------------------------------------------------
(* Rules                                                                   *)

TypeOK ==
  /\ pr.state \in {"open", "merged"}
  /\ rec.asked.out \in {"none", "merged", "error"}
  /\ waits \subseteq Reqs
  /\ merging \in 0..(MaxPushes + 1)

\* I1: only a task made for it: the forge is asked nothing of another.
OnlyMade == calls # <<>> => made

\* I2: only what read "to merge": this Emacs asks for no head that was
\* never green.
OnlyGreen == \A r \in Reqs : reqs[r].mine => reqs[r].head \in greens

\* I3: only the commit judged: it merged at the head some call asked for.
JudgedHead == pr.at # 0 => \E c \in Calls : calls[c].head = pr.at

\* I4: once for each head, whoever asks, and whenever the helper is killed.
OnceEachHead == \A i, j \in Calls : i # j => calls[i].head # calls[j].head

\* I5: what Roost knows was refused, or never answered for, waits on you.
RefusedIsYours == (Verdict(cache) /\ unmerged = cache.head) => Yours(cache)

\* I8: not under your hands: nothing is asked for while you are there.
NotWhileThere == \A r \in Reqs : ~reqs[r].there

\* Said once: a merge is said of a head no more than once.
SaidOnce ==
  \A i, j \in 1..Len(said) : (i # j /\ said[i][1] = "merged") => said[i] # said[j]

=============================================================================
