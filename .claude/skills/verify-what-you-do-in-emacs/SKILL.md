---
name: verify-what-you-do-in-emacs
description: >
  Model-check, with TLA+, that a new task draft or a prompt draft is never
  lost and asks at most once: a retry after a lost reply makes one task,
  one of each attempt at a prompt, and sends one prompt, with you, the
  network and the host acting at once. Use after changing
  roost-compose-submit, roost--compose-what, roost--compose-words,
  roost--compose-made, roost--compose-listed, roost--task-made,
  roost--compose-agents, roost--attempt-field, roost--compose-offer,
  roost-send-submit, roost--send-kept, roost--when-out-of-minibuffer, the
  questions-left-open quitting, or the helper's create, asking_for,
  made_for, make_task, attempt_of, made_from_other_words or send; when
  reviewing such a change; or when asked to verify the drafts, the creation
  ID, several attempts at one prompt, or the send ID.
---

# Verify what you do in Emacs

Two TLA+ models in `test/formal/what_you_do_in_emacs/` check every order of
your keys, replies that come late or never, polls, questions in the
minibuffer and the helper's work, within small bounds:

- `NewTaskDraft.tla`: the new task draft, its creation ID, and the helper's
  `create`. `NewTaskAttempts.tla` is the same model, which it extends, with
  configs of its own for a draft that makes two attempts at its prompt.
- `PromptDraft.tla`: a task's prompt draft, its send ID, and the helper's
  `send`.

The promise, in one sentence: a draft you wrote is never lost, and asking
again after a lost reply makes no second task and sends no prompt twice.
The harm when it breaks: two agents work on one prompt, an agent acts on a
prompt twice, or what you wrote is gone with a draft that said it was made.

The rules, each an INVARIANT, from the invariants in `docs/state-machines.md`:

- `OneTaskPerId`: one creation ID makes at most one task, an attempt's too.
- `DraftNeverLost`: Roost closes a new task draft only for a task of its own
  made from what it says then.
- `AtMostOnce`: a second task from the same words in the same project is
  asked for only after Roost said the first was made, or after you moved
  the draft and asked from another project (which the creation ID allows).
  Of an attempt after a draft's first, the same attempt at the same words,
  after Roost said a task of that C-c C-c was made: its own, which it
  closes for, or whichever its host made from what it said before, which
  it names.
- `AttemptsAtOnePrompt`: the tasks one ID makes, a draft's attempts, are each
  made from the same words.
- `FlagSaysCreating`, `FlagSaysSending`: "Creating…" or "Sending" only while
  a request is in flight or its good reply waits for the minibuffer.
- `PasteOnceEachId`: one send ID pastes once.
- `PromptOnce`: unchanged, asking again sends nothing that went; edited, the
  new prompt repeats only what the draft said may have gone, or went.
- `NothingLost`: each piece you wrote in a prompt draft is still there,
  reached the agent, or you took it out.

`EveryAttemptMade` is not promised, and only its known config checks it.

Each variant config's first lines say what it breaks.

## 1. Does your change touch this?

The models were last checked against the code at the sync commit, `8f651f3`,
with the change that came with this line: the words an attempt's request
names, in `roost-compose-submit`, `roost--attempt-field` and
`roost--compose-words`, and the helper's `attempt_of`, `make_task` and
`made_from_other_words`, which keep the attempts of one draft to one
wording, with what `create` says of it. This lists each covered definition
that differs from it in your working tree:

    python3 test/formal/what_you_do_in_emacs/changed.py

If one is listed, or your change alters what one of them relies on, this
skill applies: read the new code against the step it maps to below. The
list of covered names is `COVERED` in `changed.py`, and the sync commit is
its `SYNC`; keep both in step with this table.

| Code | Model step | What the step assumes |
| --- | --- | --- |
| `roost-compose-submit` | NewTaskDraft `DoSubmit`, `Submit` | ID kept while the project is the same (`KeepIdForProject`); `first` kept from the ID's first ask, and Unknown once the ID asks for something else (`ForgetMixedFirst`); refuses while submitting; quits a question left open, then submits from a timer queued before the question's held closures |
| `roost-compose-submit`, `roost--compose-agents`, `roost--attempt-field` | `Request`, `Others`, `DoSubmitCutShort`, `SubmitCutShort` | one request for each attempt (`Attempts`), the others first and the draft's own last, each other with the ID and its number, and each with the name of what the draft says then; a quit or error once one went leaves the flag clear and the ID as it asked (`KeepAskedOnceSent`); before any went, the ID is put back, which changes nothing |
| `roost--compose-what`, `roost--compose-continues` | `Says`, `Now` | what the draft says, prompt and fields: every field a request is made from, a fork's conversation and an offer's task too (`WhatSaysAll`) |
| `roost--compose-words` | `SeenOf` of a request's `what`, in `OtherWords` | a name for what `roost--compose-what` tells: the same for what is `equal`, as `roost--compose-made` compares it, and another for anything else. Only a draft that makes several attempts sends it |
| `roost--compose-made` | `ComposeMade` | closes only if the draft still says WHAT (`CompareBeforeClose`); else clears the flag and the ID, but for a poll's news while a request of its own is out (`KeepOwnInFlight`) |
| `roost--compose-listed` | `Poll` | only when not submitting and the ID is listed, which is the draft's own task's; compares with what the ID first asked |
| `roost--task-made`, `roost--create-task` | `TaskMade`, `Reply` | says "Roost created" at once; the rest waits for the minibuffer; `alreadyMade` compares with `first`, whichever task comes back: another attempt's, made from other words, comes only to an ID that asked for different things, whose `first` is Unknown, so the draft stays and names it. The reply to another attempt changes nothing of the draft, made, found or failed, so it is no step |
| failure lambda in `roost-compose-submit` | `Reply` (refused), `NoReply` | clears the flag (`FailureClearsFlag`) |
| `roost--compose-offer` | `OpenOffer`, `Init` | leaves a draft that holds a prompt, a note or a request, and the offer waits (`OfferKeepsDraft`); otherwise the offer's draft is a new buffer, with no ID |
| `roost--when-out-of-minibuffer`, `roost--close-buffer` | `held`, `EndQuestion`, `Timer` | held closures run in order, from `run-at-time 0` timers, all before the next input or reply |
| `roost--quit-questions-left-open`, `roost--quit-questions-here` | `Submit` with `mini` | the THEN timer is queued before quitting |
| helper `create`, `asking_for`, `made_for`, `make_task`, `attempt_of` | `HostTake` | one ID's look and make are one step under its lock (`HostLock`), and an attempt's ID is its own; a failure records nothing, as a wrong `attempt`, or a fork whose task's conversation can't go on |
| helper `made_from_other_words`, and `make_task`'s two looks with it | `OtherWords`, `AnswerOther`, `MakeOrAnswer` | beside a task of its group, its draft's ID, made from other words, an attempt is not made, and that task is the answer, as found (`GroupKeepsItsWords`). `make_task` looks before it makes anything, and again as it saves its record, in the one hold of the registry lock: that look and the save are one step, with the ID's lock or without, so of two requests in flight the first recorded stands and the other undoes its worktree (`abandon`). Only words both name differ; a task whose creation failed keeps no creation ID and doesn't count |
| `roost-send-submit` | PromptDraft `Submit`, `Reply`, `Sent` | same ID for the same text, a new one for another (`NewIdForNewText`); refuses while sending, before quitting questions |
| `roost--send-kept` | `Sent` | takes out what went only if it is whole at the start (`WholeCheck`); else keeps all and says it went |
| failure lambda in `roost-send-submit` | `Reply` (refused), `NoReply`, `Dropped` | clears the flag; no reply says "may have gone", a dropped connection doesn't |
| helper `send`, `SEND_IDS_KEPT`, the `rpc` lock | `Take`, `Record`, `OtherSend` | under the registry lock: an ID among `sendIds` pastes nothing; else paste, then record, keeping the last `IdsKept` |
| `roost--run`, `roost--expire-request` | `Reply`, `NoReply` | a callback runs once; after a timeout no late reply reaches it; a quit as a request starts ends it with no callback, and goes to the command that asked, whose handler clears its flag |

## 2. Run it

    python3 test/formal/check.py what_you_do_in_emacs

About 40 seconds. `make formal` runs every model. Java and TLC 1.7.4 come
from mise. Each `Name.cfg` must pass; each `Name.VARIANT.cfg` must fail on the
rule its first line names. All `ok` is the result to keep.

`check.py` prints the trace only of a run that wasn't as expected. To read
any one, such as a finding's, run TLC on its config, with one worker for the
shortest path (the jar's mise name is `TLC_TOOL` in `test/formal/check.py`):

    cd test/formal/what_you_do_in_emacs
    jar="$(MISE_CEILING_PATHS=.. mise where 'http:tla2tools[url=https://github.com/tlaplus/tlaplus/releases/download/v1.7.4/tla2tools.jar,checksum=sha256:936a262061c914694dfd669a543be24573c45d5aa0ff20a8b96b23d01e050e88]@1.7.4')/tla2tools.jar"
    MISE_CEILING_PATHS=.. mise exec java@temurin-25 -- java -cp "$jar" tlc2.TLC \
      -workers 1 -metadir "$(mktemp -d)" -config PromptDraft.finding-dropped-connection.cfg PromptDraft.tla

A config of `NewTaskAttempts` runs with `NewTaskAttempts.tla`. Read every
result with the pstack `/statechart` skill (`/pstack:statechart` in Claude
Code): it turns a violation into its shortest path in plain words, and a pass
into a chart of the states.

## 3. Read the result

- **A `Name.cfg` fails.** Tell the trace as steps in the code's words. For
  each step, find the code that takes it, in that state. If the code can't
  (a reply the callback would never see, a key Emacs reads before a ripe
  timer), it is a modelling error: fix the model and say so. If every step
  is real, it is a bug: keep the rule, add a `Name.finding-WHAT.cfg` that
  shows it, and report it with the steps. Don't weaken a rule to pass.
- **A variant passes.** The rule can no longer fail there, so it checks
  nothing: the model lost a path. Find which step stopped being reachable.
- **`error`.** TLC didn't run the model: a parse error or a bad config. The
  output above the `FAIL` line says which.

## 4. Keep it in step

When the code changes what a step does, change the step to say what the
code does now, in the same commit as the code. A change meant to fix a
finding turns its config into a variant: flip the scope constant in
`Name.cfg` so the base covers it, and keep a constant for the old code with
a config that fails. A new way into a state, such as another caller of
`roost--compose-made`, is a new step. Change the rule only when the promise
changes, and then `docs/state-machines.md` with it.

A step of `NewTaskDraft.tla` is `NewTaskAttempts`'s too, and a constant
added to one goes in every config of both.

Move the sync commit above forward only once you have read each covered
function at the new commit against its step.

To prove the check still catches a break: break the code in a scratch
change (say, `roost-send-submit` making a new ID every time), make the step
say what the broken code does (`fresh == TRUE` in PromptDraft's `Submit`),
run, and see `PromptDraft.cfg` fail on `PromptOnce`. Then drop both.

## What it covers, and doesn't

Bounds. NewTaskDraft: one attempt, two projects, three versions of what the
draft says, three asks, two closures held at once, one host, one draft.
NewTaskAttempts: two attempts, two projects, two versions, two asks, two
held. PromptDraft: three pieces written, three asks, one send from
elsewhere, `IdsKept` 4, so the window never fills within the bound. Each
passed at larger bounds too (NewTaskDraft 3 projects, 4 versions, 4 asks, 3
held, with `SubmitQuitsQuestion` and `EditBack` off: 4.9 million states,
2.4 minutes; PromptDraft 4 pieces, 4 asks, 2
others, 8 kept: 31.8 million states, 13 minutes; NewTaskAttempts 3
projects, 3 versions, 2 asks, 3 held: 3.1 million states, 2.1 minutes, and
with three asks of a draft that says one thing, 2 projects, 1 held: 2.1
million states, 2.1 minutes), each on one worker. Two attempts with three
asks of a draft you change pass too, at 1 project, 2 versions, 1 held (840
thousand states, a minute), since `AtMostOnce` counts as said any task of
the earlier C-c C-c that the draft named.

Scope switches, each turned on by one finding or known config:
`SubmitQuitsQuestion` (C-c C-c with a question left open) and `EditBack` (the
draft says again what it said before), both on in the base configs since
their findings were fixed; `CutShort` (C-c C-c cut short between its
requests) and `MixedAttempts` (a draft that makes several attempts asks
again with its ID for something else), on in `NewTaskAttempts.cfg`, the
second since finding 3 was fixed; `Drops` (a dropped connection, after
which the helper goes on) and `KillAfterPaste` (a helper killed between
paste and record), off in `PromptDraft.cfg`.

What the draft says is one value, a version of its prompt and fields. So
`C-c C-x`, `C-c C-f` and the task an offer's draft shows under are edits
like any other, and an offer's draft moved to another project is a move and
an edit. How many attempts a draft makes is the same at each ask.

Left out: the setup command's question, the Org link, which task opens after
(`roost--you-stay`), `roost--compose-tied`, notes and attachments in a prompt
draft, "send anyway", two Emacs sessions, a draft opened again after it
closed, a refusal after the paste (`send-keys` failing), crash recovery of a
creation (`settle_creation`, which `make crash` covers), and opening a task
and the open generation. Also: a quit that lands in `roost-compose-submit`
after a request went and before the command returns, a few forms; a draft
that changes how many attempts it makes between asks; the offer itself, which
opening takes and a task made from it takes again (`take_offer`,
`taken_offers`: "Offers" in `docs/state-machines.md`, and
`verify-emacs-and-hosts`); Do it here asked again, whose send ID is the
task's and the offer's, the same each time; and a conversation
(`roost-new-conversation`), which has no draft and no creation ID, so that
`C` again after no reply can start a second.

## Findings at 8f651f3

Each is a config here that fails as named.

1. Fixed: **a second task from one C-c C-c with a question left open**. A
   poll's news of an earlier task, held while a question was open, ran after
   the C-c C-c that quit it, and `roost--compose-made` cleared the flag and
   the ID of the request that C-c C-c sent; C-c C-c then made a third.
   `NewTaskDraft.news-frees-draft.cfg` undoes the fix.
2. Fixed: **a draft changed back closed for words it never sent**: the ID
   kept what it first asked for, though asked with since for something else,
   which made the task. `NewTaskDraft.first-kept-when-mixed.cfg` undoes the
   fix. With `EditBack` on, `AtMostOnce` reads earlier and later as you asked,
   not as the host made, and counts a move to another project and back as a
   move: the creation ID's table allows a new ID there.
3. Fixed: **attempts at one prompt made from two**. A draft that makes two
   attempts, changed after its own request failed or got no reply, asked
   again with the same IDs: its host answered the attempt it had made, from
   what the draft said before, and made the draft's own from what it said
   now, and the draft closed. Each attempt's request now names its words,
   and its host makes none beside one of its group made from others: the
   draft stays, naming that one. `NewTaskAttempts.attempt-whatever-its-group.cfg`
   undoes the fix, and
   `roost-a-draft-changed-between-asks-makes-its-attempts-from-one-wording`
   and the helper's `test_the_attempts_of_one_draft_are_made_from_one_wording`
   and `test_attempts_asked_for_at_once_in_other_words_make_one_wording`
   replay it.
4. Fixed: **a fork's draft closed for a fork made the other way**. Whether
   a fork goes on with its task's conversation wasn't in
   `roost--compose-what`, so a draft changed in that alone (C-c C-f), while
   being created or after no reply, closed for a task made from what it
   said before. `NewTaskDraft.what-misses-a-field.cfg` undoes the fix, and
   `roost-a-fork-given-a-new-conversation-stays-for-a-task-that-goes-on-with-the-old`
   replays it.
5. **After a dropped connection, an edited prompt repeats what went**
   (`PromptDraft.finding-dropped-connection.cfg`, `PromptOnce`).
   1. You send P from a prompt draft: `roost-send-submit`, ID1.
   2. The SSH connection drops. The failure has no `roost-no-reply`, so the
      draft says "Could not send: … · C-c C-c retries", not that it may
      have gone. Over SSH the helper goes on and pastes P.
   3. You add a line and C-c C-c: another text, ID2. The agent gets P, then
      P and the line. Rests on sshd leaving the helper running, which
      Checked and found sound lists as not proved.

Known and kept as a config: `PromptDraft.known-kill-after-paste.cfg`, the
send ID's I1 ("a kill between the two pastes again"); and
`NewTaskAttempts.known-attempt-not-made.cfg`, the new task draft's I2: a
draft closes for its own task though its host refused another attempt,
which a message says, and nothing asks for that attempt again.
