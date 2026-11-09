---
name: verify-what-you-do-in-emacs
description: >
  Model-check, with TLA+, that a new task draft or a prompt draft is never
  lost and asks at most once: a retry after a lost reply makes one task and
  sends one prompt, with you, the network and the host acting at once. Use
  after changing roost-compose-submit, roost--compose-made,
  roost--compose-listed, roost--task-made, roost-send-submit,
  roost--send-kept, roost--when-out-of-minibuffer, the questions-left-open
  quitting, or the helper's create, asking_for, made_for or send; when
  reviewing such a change; or when asked to verify the drafts, the creation
  ID or the send ID.
---

# Verify what you do in Emacs

Two TLA+ models in `test/formal/what_you_do_in_emacs/` check every order of
your keys, replies that come late or never, polls, questions in the
minibuffer and the helper's work, within small bounds:

- `NewTaskDraft.tla`: the new task draft, its creation ID, and the helper's
  `create`.
- `PromptDraft.tla`: a task's prompt draft, its send ID, and the helper's
  `send`.

The promise, in one sentence: a draft you wrote is never lost, and asking
again after a lost reply makes no second task and sends no prompt twice.
The harm when it breaks: two agents work on one prompt, an agent acts on a
prompt twice, or what you wrote is gone with a draft that said it was made.

The rules, each an INVARIANT, from the invariants in `docs/state-machines.md`:

- `OneTaskPerId`: one creation ID makes at most one task.
- `DraftNeverLost`: Roost closes a new task draft only for a task made from
  what it says then.
- `AtMostOnce`: a second task from the same words in the same project is
  asked for only after Roost said the first was made, or after you moved
  the draft and asked from another project (which the creation ID allows).
- `FlagSaysCreating`, `FlagSaysSending`: "Creating…" or "Sending" only while
  a request is in flight or its good reply waits for the minibuffer.
- `PasteOnceEachId`: one send ID pastes once.
- `PromptOnce`: unchanged, asking again sends nothing that went; edited, the
  new prompt repeats only what the draft said may have gone, or went.
- `NothingLost`: each piece you wrote in a prompt draft is still there,
  reached the agent, or you took it out.

Each variant config's first lines say what it breaks.

## 1. Does your change touch this?

The models were last checked against the code at the sync commit, `e910487`,
with the change to `roost-compose-submit` and `roost--compose-made` that came
with this line. This lists each covered
definition that differs from it in your working tree:

    python3 test/formal/what_you_do_in_emacs/changed.py

If one is listed, or your change alters what one of them relies on, this
skill applies: read the new code against the step it maps to below. The
list of covered names is `COVERED` in `changed.py`, and the sync commit is
its `SYNC`; keep both in step with this table.

| Code | Model step | What the step assumes |
| --- | --- | --- |
| `roost-compose-submit` | NewTaskDraft `DoSubmit`, `Submit` | ID kept while the project is the same (`KeepIdForProject`); `first` kept from the ID's first ask, and Unknown once the ID asks for something else (`ForgetMixedFirst`); refuses while submitting; quits a question left open, then submits from a timer queued before the question's held closures |
| `roost--compose-what` | `Now` | what the draft says: prompt and fields |
| `roost--compose-made` | `ComposeMade` | closes only if the draft still says WHAT (`CompareBeforeClose`); else clears the flag and the ID, but for a poll's news while a request of its own is out (`KeepOwnInFlight`) |
| `roost--compose-listed` | `Poll` | only when not submitting and the ID is listed; compares with what the ID first asked |
| `roost--task-made`, `roost--create-task` | `TaskMade`, `Reply` | says "Roost created" at once; the rest waits for the minibuffer; `alreadyMade` compares with `first` |
| failure lambda in `roost-compose-submit` | `Reply` (refused), `NoReply` | clears the flag (`FailureClearsFlag`) |
| `roost--when-out-of-minibuffer`, `roost--close-buffer` | `held`, `EndQuestion`, `Timer` | held closures run in order, from `run-at-time 0` timers, all before the next input or reply |
| `roost--quit-questions-left-open`, `roost--quit-questions-here` | `Submit` with `mini` | the THEN timer is queued before quitting |
| helper `create`, `asking_for`, `made_for`, `make_task` | `HostTake` | one ID's look and make are one step under its lock (`HostLock`); a failure records nothing |
| `roost-send-submit` | PromptDraft `Submit`, `Reply`, `Sent` | same ID for the same text, a new one for another (`NewIdForNewText`); refuses while sending, before quitting questions |
| `roost--send-kept` | `Sent` | takes out what went only if it is whole at the start (`WholeCheck`); else keeps all and says it went |
| failure lambda in `roost-send-submit` | `Reply` (refused), `NoReply`, `Dropped` | clears the flag; no reply says "may have gone", a dropped connection doesn't |
| helper `send`, `SEND_IDS_KEPT`, the `rpc` lock | `Take`, `Record`, `OtherSend` | under the registry lock: an ID among `sendIds` pastes nothing; else paste, then record, keeping the last `IdsKept` |
| `roost--run`, `roost--expire-request` | `Reply`, `NoReply` | a callback runs once; after a timeout no late reply reaches it |

## 2. Run it

    python3 test/formal/check.py what_you_do_in_emacs

About 30 seconds. `make formal` runs every model. Java and TLC 1.7.4 come
from mise. Each `Name.cfg` must pass; each `Name.VARIANT.cfg` must fail on the
rule its first line names. All `ok` is the result to keep.

`check.py` prints the trace only of a run that wasn't as expected. To read
any one, such as a finding's, run TLC on its config, with one worker for the
shortest path (the jar's mise name is `TLC_TOOL` in `test/formal/check.py`):

    cd test/formal/what_you_do_in_emacs
    jar="$(MISE_CEILING_PATHS=.. mise where 'http:tla2tools[url=https://github.com/tlaplus/tlaplus/releases/download/v1.7.4/tla2tools.jar,checksum=sha256:936a262061c914694dfd669a543be24573c45d5aa0ff20a8b96b23d01e050e88]@1.7.4')/tla2tools.jar"
    MISE_CEILING_PATHS=.. mise exec java@temurin-25 -- java -cp "$jar" tlc2.TLC \
      -workers 1 -metadir "$(mktemp -d)" -config PromptDraft.finding-dropped-connection.cfg PromptDraft.tla

Read every
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

Move the sync commit above forward only once you have read each covered
function at the new commit against its step.

To prove the check still catches a break: break the code in a scratch
change (say, `roost-send-submit` making a new ID every time), make the step
say what the broken code does (`fresh == TRUE` in PromptDraft's `Submit`),
run, and see `PromptDraft.cfg` fail on `PromptOnce`. Then drop both.

## What it covers, and doesn't

Bounds. NewTaskDraft: two projects, three versions of what the draft says,
three asks, two closures held at once, one host, one draft. PromptDraft: three
pieces written, three asks, one send from elsewhere, `IdsKept` 4, so the
window never fills within the bound. Both passed at larger bounds too
(NewTaskDraft 3 projects, 4 versions, 4 asks, 3 held: 4.9 million states,
2.4 minutes; PromptDraft 4 pieces, 4 asks, 2 others, 8 kept: 31.8 million
states, 13 minutes), each on one worker.

Scope switches, each turned on by one finding or known config:
`SubmitQuitsQuestion` (C-c C-c with a question left open) and `EditBack` (the
draft says again what it said before), both on in `NewTaskDraft.cfg` since
their findings were fixed; `Drops` (a dropped connection, after which the
helper goes on) and `KillAfterPaste` (a helper killed between paste and
record), off in `PromptDraft.cfg`.

Left out: the setup command's question, the Org link, which task opens after
(`roost--you-stay`), `roost--compose-tied`, notes and attachments in a prompt
draft, "send anyway", two Emacs sessions, a draft opened again after it
closed, a refusal after the paste (`send-keys` failing), crash recovery of a
creation (`settle_creation`, which `make crash` covers), and opening a task
and the open generation.

## Findings at e910487

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
3. **After a dropped connection, an edited prompt repeats what went**
   (`PromptDraft.finding-dropped-connection.cfg`, `PromptOnce`).
   1. You send P from a prompt draft: `roost-send-submit`, ID1.
   2. The SSH connection drops. The failure has no `roost-no-reply`, so the
      draft says "Could not send: … · C-c C-c retries", not that it may
      have gone. Over SSH the helper goes on and pastes P.
   3. You add a line and C-c C-c: another text, ID2. The agent gets P, then
      P and the line. Rests on sshd leaving the helper running, which
      Checked and found sound lists as not proved.

Known and kept as a config: `PromptDraft.known-kill-after-paste.cfg`, the
send ID's I1 ("a kill between the two pastes again").
