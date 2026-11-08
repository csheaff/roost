---------------------------- MODULE HostRequests ----------------------------
(***************************************************************************)
(* Requests to one host through its helper copy, several at once.         *)
(*                                                                         *)
(* roost--request installs the helper when this Emacs hasn't, and asks     *)
(* again once when the host says the helper is gone, as when another       *)
(* Emacs pruned it.  roost--run starts one process per step, and its       *)
(* sentinel calls back.  Any process can be given up on (the timer, or the *)
(* connection dropping) while what it started may still run on the host.  *)
(* docs/state-machines.md, "Emacs and its hosts": Host request and Helper  *)
(* copy.  CachedTasks.tla has what the replies do to the cache.           *)
(***************************************************************************)
EXTENDS Naturals, Sequences, FiniteSets

CONSTANTS
  Break,   \* "none", or the break of roost.el that a variant config proves a rule catches
  MaxReqs  \* requests started

VARIABLES
  file, fresh,   \* ROOT/remote-HASH.py on the host: "whole" or "gone"; used within the week
  installed,     \* roost--installed holds this helper's filename for (HOST ROOT)
  reqs,          \* every request started, in order
  inbox,         \* processes the host has yet to run, waited on or not
  helperFailed   \* ghost: a request failed only because the helper had gone

vars == <<file, fresh, installed, reqs, inbox, helperFailed>>

(* A request.  kind: what only looks, or what changes things.  phase: the *)
(* process running now, the install or the helper itself.  checks: its   *)
(* failure goes through roost--helper-unusable-p, as for a request that  *)
(* began with the helper installed; once it installs, a failure is just  *)
(* a failure.  n numbers its processes: an answer to one Emacs no longer *)
(* waits on goes nowhere.  calls: callbacks run.  runs: times its action *)
(* ran on the host.                                                       *)
Req(kind) ==
  [kind |-> kind, phase |-> IF installed THEN "invoke" ELSE "install",
   checks |-> installed, n |-> 0, waiting |-> TRUE, answer |-> "none",
   calls |-> 0, runs |-> 0]

Msg(i, r) == [r |-> i, phase |-> r.phase, n |-> r.n]

Quiescent == \A i \in DOMAIN reqs : ~reqs[i].waiting

(***************************************************************************)
(* Emacs asks.                                                             *)
(***************************************************************************)

Ask(kind) ==
  /\ Len(reqs) < MaxReqs
  /\ LET r == Req(kind)
         i == Len(reqs) + 1
     IN
     \/ /\ reqs' = Append(reqs, r)
        /\ inbox' = inbox \cup {Msg(i, r)}
     \* roost--run's condition-case: an error once the process is made
     \* cleans up, deleting the process, and calls FAILURE at once.  Broken
     \* (SetupErrorLeavesProcess), the process runs on and calls back too.
     \/ /\ reqs' = Append(reqs, [r EXCEPT !.calls = 1,
                                          !.waiting = (Break = "SetupErrorLeavesProcess")])
        /\ inbox' = IF Break = "SetupErrorLeavesProcess" THEN inbox \cup {Msg(i, r)} ELSE inbox
  /\ UNCHANGED <<file, fresh, installed, helperFailed>>

(***************************************************************************)
(* The host.                                                               *)
(***************************************************************************)

Answer(rs, m, a) ==
  IF rs[m.r].waiting /\ rs[m.r].n = m.n THEN [rs EXCEPT ![m.r].answer = a] ELSE rs

Host ==
  \E m \in inbox :
    /\ inbox' = inbox \ {m}
    /\ IF m.phase = "install"
       \* roost--install-code: written whole and renamed into place, or left
       \* as it is when it is there at its size; either way, used now.
       THEN /\ file' = "whole" /\ fresh' = TRUE
            /\ reqs' = Answer(reqs, m, "ok")
       ELSE /\ UNCHANGED <<file, fresh>>
            /\ IF file = "gone"
               \* The FileNotFoundError naming it, before the helper runs.
               THEN reqs' = Answer(reqs, m, "missing")
               ELSE \/ reqs' = Answer([reqs EXCEPT ![m.r].runs = @ + 1], m, "ok")
                    \* Refused by rpc, as an agent still active: nothing ran.
                    \/ reqs' = Answer(reqs, m, "refused")
    /\ UNCHANGED <<installed, helperFailed>>

(* A process Emacs no longer waits on dies before it runs.  One it waits  *)
(* on dying is the same as GiveUp and then this.                         *)
HostLoses ==
  \E m \in inbox :
    /\ ~reqs[m.r].waiting \/ reqs[m.r].n # m.n
    /\ inbox' = inbox \ {m}
    /\ UNCHANGED <<file, fresh, installed, reqs, helperFailed>>

(* Another Emacs's prune_helpers, a week after the helper was last used. *)
OtherPrunes ==
  /\ file = "whole" /\ ~fresh
  /\ file' = "gone"
  /\ UNCHANGED <<fresh, installed, reqs, inbox, helperFailed>>

(* A week goes by.  Not with a request in flight: none lasts a week awake. *)
WeekPasses ==
  /\ fresh /\ Quiescent /\ inbox = {}
  /\ fresh' = FALSE
  /\ UNCHANGED <<file, installed, reqs, inbox, helperFailed>>

(***************************************************************************)
(* Emacs: the sentinel of each process, and the callbacks.                 *)
(***************************************************************************)

(* What the host may still run once Emacs stops waiting: what only looks *)
(* changes nothing, so it goes, and the model stays small.               *)
Kept(i) == IF reqs[i].kind = "looks" THEN {m \in inbox : m.r # i} ELSE inbox

(* SUCCESS or FAILURE runs, and the request is over. *)
Callback(i) ==
  /\ reqs' = [reqs EXCEPT ![i].waiting = FALSE, ![i].calls = @ + 1, ![i].answer = "none",
                          ![i].phase = "invoke", ![i].checks = FALSE, ![i].n = 0]
  /\ inbox' = Kept(i)

(* The request's next process: the install, or the helper itself. *)
Then(i, phase) ==
  LET r == [reqs[i] EXCEPT !.phase = phase, !.checks = FALSE, !.n = @ + 1, !.answer = "none"]
  IN /\ reqs' = [reqs EXCEPT ![i] = r]
     /\ inbox' = inbox \cup {Msg(i, r)}

Deliver(i) ==
  /\ reqs[i].waiting /\ reqs[i].answer # "none"
  /\ LET r == reqs[i] IN
     CASE r.phase = "install" ->
            \* install-and-invoke: puthash, then invoke with plain FAILURE.
            /\ installed' = TRUE
            /\ Then(i, "invoke")
            /\ UNCHANGED helperFailed
       [] r.answer = "missing" /\ r.checks /\ Break # "NoReinstall" ->
            \* roost--helper-unusable-p: remhash, install, invoke once more.
            /\ installed' = FALSE
            /\ Then(i, "install")
            /\ UNCHANGED helperFailed
       [] r.answer = "missing" ->
            /\ helperFailed' = TRUE
            /\ Callback(i)
            /\ UNCHANGED installed
       [] OTHER ->
            /\ Callback(i)
            /\ UNCHANGED <<installed, helperFailed>>
  /\ UNCHANGED <<file, fresh>>

(* roost--expire-request's timer, or the connection dropping: FAILURE,  *)
(* whatever the host has done or will still do.  Broken                 *)
(* (RetryAnyFailure), the helper is taken for gone on any failure.      *)
GiveUp(i) ==
  /\ reqs[i].waiting
  /\ IF Break = "RetryAnyFailure" /\ reqs[i].phase = "invoke" /\ reqs[i].checks
     THEN /\ installed' = FALSE
          /\ Then(i, "install")
     ELSE /\ Callback(i)
          /\ UNCHANGED installed
  /\ UNCHANGED <<file, fresh, helperFailed>>

Next ==
  \/ \E k \in {"looks", "changes"} : Ask(k)
  \/ Host \/ HostLoses \/ OtherPrunes \/ WeekPasses
  \/ \E i \in DOMAIN reqs : Deliver(i) \/ GiveUp(i)
  \/ UNCHANGED vars  \* bounded runs end; that is no deadlock

Init ==
  /\ file \in {"whole", "gone"}
  /\ fresh = FALSE
  /\ installed \in BOOLEAN
  /\ reqs = << >>
  /\ inbox = {}
  /\ helperFailed = FALSE

Spec == Init /\ [][Next]_vars

(***************************************************************************)
(* The rules.                                                              *)
(***************************************************************************)

(* Every request ends in exactly one callback, SUCCESS or FAILURE. *)
OneCallback ==
  \A i \in DOMAIN reqs :
    /\ reqs[i].calls <= 1
    /\ (~reqs[i].waiting) => reqs[i].calls = 1

(* What changes things runs at most once on the host, however Roost asks  *)
(* again: a stop, a merge, a prompt sent.                                 *)
ActionOnce == \A i \in DOMAIN reqs : reqs[i].kind = "changes" => reqs[i].runs <= 1

(* A helper another Emacs pruned fails no request: Roost installs it again. *)
NoHelperFailure == ~helperFailed

=============================================================================
