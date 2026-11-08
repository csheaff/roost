----------------------------- MODULE PromptDraft -----------------------------
(***************************************************************************)
(* A task's prompt draft, its send ID, and the helper's `send`.            *)
(* docs/state-machines.md: "The prompt draft", "The send ID",              *)
(* "Held for the minibuffer", "Request lifetime".                          *)
(*                                                                         *)
(* What the draft says is a sequence of pieces you wrote, each a number.   *)
(* You write more at the end, or change the first piece, at any time.      *)
(* The network may answer, time out, or drop the connection; the helper    *)
(* takes each request whenever it gets to it, or never.  Other sends to    *)
(* the same task (a note sent alone, another draft) take their own IDs.    *)
(***************************************************************************)
EXTENDS Naturals, Sequences, FiniteSets

CONSTANTS
  MaxPieces,  \* pieces you write
  MaxAsks,    \* C-c C-c presses that send a request
  MaxOthers,  \* sends to the task from elsewhere, with IDs of their own
  IdsKept,    \* SEND_IDS_KEPT, the IDs a record keeps (16 in the helper)
  \* The code as it is: each TRUE.  A FALSE one is a broken variant.
  NewIdForNewText,   \* `roost-send-submit` makes a new ID when the text differs
  CompareBeforeClose,\* the success callback keeps the draft when it says more now
  WholeCheck,        \* `roost--send-kept` takes out what went only if it is all there
  FailureClearsFlag, \* the failure callback sets `roost--send-sending` nil
  \* Scope: FALSE in PromptDraft.cfg.
  KillAfterPaste,    \* a helper killed between the paste and recording its ID
  Drops              \* a connection drops, and over SSH the helper goes on

None == 0
Range(s) == {s[i] : i \in DOMAIN s}

VARIABLES
  draft,      \* "open", "closed" (Roost closed it), "cancelled" (C-c C-k)
  text,       \* what it says: a sequence of pieces
  sending,    \* `roost--send-sending`
  asked,      \* `roost--send-asked`: (TEXT . ID)
  mini,       \* a question is open in the minibuffer
  held,       \* success callbacks waiting for the minibuffer
  timers,     \* those let go when it ended, in order
  waits,      \* requests Emacs still waits on
  reqs,       \* every send request, and what became of it
  sendIds,    \* the record's `sendIds`
  pasted,     \* what reached the agent's terminal, in order
  told,       \* pieces the draft has said may have gone, or went
  removed,    \* pieces you took out yourself
  nextPiece, nextId, asks, others

vars == <<draft, text, sending, asked, mini, held, timers, waits, reqs, sendIds,
          pasted, told, removed, nextPiece, nextId, asks, others>>

Reqs == 1..Len(reqs)
Pastes == 1..Len(pasted)
Pasting == \E r \in Reqs : reqs[r].state = "pasting"   \* holds the registry lock
Keep(s) == IF Len(s) > IdsKept THEN SubSeq(s, Len(s) - IdsKept + 1, Len(s)) ELSE s

-----------------------------------------------------------------------------
(* The success callback, once out of the minibuffer: close, or keep what   *)
(* the draft says beyond what went (`roost--send-kept`).                   *)

Sent(c) ==
  IF draft # "open" THEN UNCHANGED <<draft, text, sending, asked, told>>
  ELSE IF CompareBeforeClose /\ text # c.text
  THEN LET n == Len(c.text)
           whole == n <= Len(text) /\ SubSeq(text, 1, n) = c.text
       IN /\ sending' = FALSE
          /\ asked' = [text |-> <<>>, id |-> None]
          /\ IF whole \/ ~WholeCheck
             THEN /\ text' = IF n <= Len(text) THEN SubSeq(text, n + 1, Len(text)) ELSE <<>>
                  /\ UNCHANGED told
             ELSE \* "Sent to X before you changed it; all of it is still here"
                  /\ told' = told \cup Range(c.text)
                  /\ UNCHANGED text
          /\ UNCHANGED draft
  ELSE /\ draft' = "closed"
       /\ UNCHANGED <<text, sending, asked, told>>

-----------------------------------------------------------------------------
(* You                                                                     *)

UserCan == draft = "open" /\ timers = <<>>

Write ==
  /\ UserCan /\ nextPiece <= MaxPieces
  /\ text' = Append(text, nextPiece)
  /\ nextPiece' = nextPiece + 1
  /\ UNCHANGED <<draft, sending, asked, mini, held, timers, waits, reqs, sendIds,
                 pasted, told, removed, nextId, asks, others>>

\* An edit inside what is there: the first piece becomes another.
Change ==
  /\ UserCan /\ nextPiece <= MaxPieces /\ text # <<>>
  /\ text' = [text EXCEPT ![1] = nextPiece]
  /\ removed' = removed \cup {text[1]}
  /\ nextPiece' = nextPiece + 1
  /\ UNCHANGED <<draft, sending, asked, mini, held, timers, waits, reqs, sendIds,
                 pasted, told, nextId, asks, others>>

\* C-c C-c: the same ID for the same text, else a new one.
Submit ==
  /\ UserCan /\ ~mini /\ ~sending /\ text # <<>> /\ asks < MaxAsks
  /\ LET fresh == asked.id = None \/ (NewIdForNewText /\ asked.text # text)
         ask == [text |-> text, id |-> IF fresh THEN nextId ELSE asked.id]
     IN /\ asked' = ask
        /\ nextId' = IF fresh THEN nextId + 1 ELSE nextId
        /\ reqs' = Append(reqs, [id |-> ask.id, text |-> text, told |-> told,
                                 state |-> "sent", result |-> "none"])
  /\ waits' = waits \cup {Len(reqs) + 1}
  /\ sending' = TRUE
  /\ asks' = asks + 1
  /\ UNCHANGED <<draft, text, mini, held, timers, sendIds, pasted, told, removed,
                 nextPiece, others>>

OpenQuestion ==
  /\ UserCan /\ ~mini
  /\ mini' = TRUE
  /\ UNCHANGED <<draft, text, sending, asked, held, timers, waits, reqs, sendIds,
                 pasted, told, removed, nextPiece, nextId, asks, others>>

EndQuestion ==
  /\ draft = "open" /\ timers = <<>> /\ mini
  /\ mini' = FALSE
  /\ timers' = held
  /\ held' = <<>>
  /\ UNCHANGED <<draft, text, sending, asked, waits, reqs, sendIds, pasted, told,
                 removed, nextPiece, nextId, asks, others>>

Cancel ==
  /\ UserCan /\ ~mini
  /\ draft' = "cancelled"
  /\ UNCHANGED <<text, sending, asked, mini, held, timers, waits, reqs, sendIds,
                 pasted, told, removed, nextPiece, nextId, asks, others>>

Timer ==
  /\ timers # <<>>
  /\ Sent(Head(timers))
  /\ timers' = Tail(timers)
  /\ UNCHANGED <<mini, held, waits, reqs, sendIds, pasted, removed, nextPiece,
                 nextId, asks, others>>

-----------------------------------------------------------------------------
(* The network, as Emacs reads it                                          *)

EmacsReads == timers = <<>>

Failed ==
  sending' = IF draft = "open" /\ FailureClearsFlag THEN FALSE ELSE sending

Reply(r) ==
  /\ EmacsReads /\ r \in waits /\ reqs[r].state = "handled"
  /\ waits' = waits \ {r}
  /\ IF reqs[r].result = "refused"
     THEN /\ Failed
          /\ UNCHANGED <<draft, text, asked, held, told>>
     ELSE IF mini
          THEN /\ held' = Append(held, [text |-> reqs[r].text])
               /\ UNCHANGED <<draft, text, sending, asked, told>>
          ELSE /\ Sent([text |-> reqs[r].text])
               /\ UNCHANGED held
  /\ UNCHANGED <<mini, timers, reqs, sendIds, pasted, removed, nextPiece, nextId,
                 asks, others>>

\* No reply in time: the draft says it may have gone.
NoReply(r) ==
  /\ EmacsReads /\ r \in waits
  /\ waits' = waits \ {r}
  /\ Failed
  /\ told' = IF draft = "open" THEN told \cup Range(reqs[r].text) ELSE told
  /\ UNCHANGED <<draft, text, asked, mini, held, timers, reqs, sendIds, pasted,
                 removed, nextPiece, nextId, asks, others>>

\* The connection drops: "Could not send: ... retries".
Dropped(r) ==
  /\ Drops
  /\ EmacsReads /\ r \in waits
  /\ waits' = waits \ {r}
  /\ Failed
  /\ UNCHANGED <<draft, text, asked, mini, held, timers, reqs, sendIds, pasted, told,
                 removed, nextPiece, nextId, asks, others>>

-----------------------------------------------------------------------------
(* The helper's `send`, under the registry lock                            *)

HostUnchanged == UNCHANGED <<draft, text, sending, asked, mini, held, timers, waits,
                             told, removed, nextPiece, asks>>

Take(r) ==
  /\ ~Pasting /\ reqs[r].state = "sent"
  /\ IF reqs[r].id \in Range(sendIds)
     THEN /\ reqs' = [reqs EXCEPT ![r].state = "handled", ![r].result = "alreadySent"]
          /\ UNCHANGED pasted
     ELSE \/ /\ reqs' = [reqs EXCEPT ![r].state = "handled", ![r].result = "refused"]
             /\ UNCHANGED pasted
          \/ /\ reqs' = [reqs EXCEPT ![r].state = "pasting"]
             /\ pasted' = Append(pasted, [id |-> reqs[r].id, text |-> reqs[r].text, req |-> r])
  /\ UNCHANGED <<sendIds, nextId, others>>

\* Written after the paste.
Record(r) ==
  /\ reqs[r].state = "pasting"
  /\ sendIds' = Keep(Append(sendIds, reqs[r].id))
  /\ reqs' = [reqs EXCEPT ![r].state = "handled", ![r].result = "pasted"]
  /\ UNCHANGED <<pasted, nextId, others>>

Killed(r) ==
  /\ KillAfterPaste /\ reqs[r].state = "pasting"
  /\ reqs' = [reqs EXCEPT ![r].state = "killed"]
  /\ UNCHANGED <<sendIds, pasted, nextId, others>>

\* A note sent alone, or another draft: a prompt of its own, recorded.
OtherSend ==
  /\ ~Pasting /\ others < MaxOthers
  /\ pasted' = Append(pasted, [id |-> nextId, text |-> <<>>, req |-> None])
  /\ sendIds' = Keep(Append(sendIds, nextId))
  /\ nextId' = nextId + 1
  /\ others' = others + 1
  /\ UNCHANGED reqs

-----------------------------------------------------------------------------

Init ==
  /\ draft = "open" /\ text = <<>> /\ sending = FALSE
  /\ asked = [text |-> <<>>, id |-> None]
  /\ mini = FALSE /\ held = <<>> /\ timers = <<>>
  /\ waits = {} /\ reqs = <<>> /\ sendIds = <<>> /\ pasted = <<>>
  /\ told = {} /\ removed = {}
  /\ nextPiece = 1 /\ nextId = 1 /\ asks = 0 /\ others = 0

AReplyComes == \E r \in Reqs : Reply(r)
NoReplyComes == \E r \in Reqs : NoReply(r)
ConnectionDrops == \E r \in Reqs : Dropped(r)
HelperTakes == \E r \in Reqs : Take(r) /\ HostUnchanged
HelperRecords == \E r \in Reqs : Record(r) /\ HostUnchanged
HelperKilled == \E r \in Reqs : Killed(r) /\ HostUnchanged
SentElsewhere == OtherSend /\ HostUnchanged
Settled == draft # "open" /\ UNCHANGED vars

Next ==
  \/ Write \/ Change \/ Submit \/ OpenQuestion \/ EndQuestion \/ Cancel \/ Timer
  \/ AReplyComes \/ NoReplyComes \/ ConnectionDrops
  \/ HelperTakes \/ HelperRecords \/ HelperKilled \/ SentElsewhere
  \/ Settled

Spec == Init /\ [][Next]_vars

-----------------------------------------------------------------------------
(* Rules                                                                   *)

TypeOK ==
  /\ draft \in {"open", "closed", "cancelled"}
  /\ sending \in BOOLEAN /\ mini \in BOOLEAN
  /\ waits \subseteq Reqs

\* The send ID, I1: one ID pastes once.
PasteOnceEachId ==
  \A i, j \in Pastes : i # j => pasted[i].id # pasted[j].id

\* The prompt draft, I4 and I5: what you wrote reaches the agent once.
\* Unchanged, asking again sends it only if it didn't go; edited, it goes
\* as a new prompt, and may repeat only what the draft had said may have
\* gone, or went.  By the order you sent them: the helper can take a
\* request Emacs gave up on after a later one.
PromptOnce ==
  \A i, j \in Pastes :
    LET a == pasted[i].req
        b == pasted[j].req
        both == Range(pasted[i].text) \cap Range(pasted[j].text)
    IN (i # j /\ None < a /\ a < b /\ both # {}) =>
         /\ reqs[a].text # reqs[b].text
         /\ both \subseteq reqs[b].told

\* The prompt draft, I1 and I6: each piece you wrote is still in the draft,
\* or reached the agent, or you took it out yourself.
NothingLost ==
  draft # "cancelled" =>
    \A p \in 1..(nextPiece - 1) :
      \/ p \in removed
      \/ draft = "open" /\ p \in Range(text)
      \/ \E i \in Pastes : p \in Range(pasted[i].text)

\* The flag says Sending only while a request is in flight or its good
\* reply waits for the minibuffer.
FlagSaysSending ==
  (draft = "open" /\ sending) => (waits # {} \/ held # <<>> \/ timers # <<>>)

=============================================================================
