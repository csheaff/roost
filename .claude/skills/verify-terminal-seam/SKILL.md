---
name: verify-terminal-seam
description: >
  Model-check a task's terminal through ghostel-tmux: the stand-in that says
  "Connecting to", "Could not attach to" or "Detached from", the controller
  and its place, panes arriving through ghostel-tmux-attach-hook, the
  detach hook, the tries of a host whose connection dropped, workspaces that
  keep a stand-in for later, and ghostel-tmux switching a controller to
  another session, with the minibuffer, timers and ssh probes in every
  order. Use before committing a change to roost-ghostel-tmux.el's
  connect-or-switch, --attached, --detached, --attach-again, --try-again,
  --give-way, --stand-in-shown, --stand-in-gives-way, --sweep-stand-ins,
  --not-attached, --stand-in-for or disconnect, or to
  roost--when-out-of-minibuffer, roost--open or roost--display-task in
  roost.el; when ghostel-tmux changes how it runs its hooks, holds calls for
  the minibuffer or ends a client; when "A terminal through ghostel-tmux"
  in docs/state-machines.md changes; or for /verify-terminal-seam.
---

# Verify a terminal through ghostel-tmux

One TLC model in `test/formal/terminal_seam/`, checked from three bases,
through `test/formal/check.py`. It holds the code to these rules, numbered
as the section's invariants in `docs/state-machines.md`:

- **OwnPane** (I1). A window never shows another session's pane in place
  of a stand-in, or as its task opens. Harm if broken: you type into
  another task's agent.
- **OpenKeepsWindow** (I1). An open leaves its window showing the task, or
  what it showed before. Harm if broken: the window you opened from shows
  some unrelated buffer, with nothing to say why.
- **ConnectingIsTrue** (I2). No stand-in says "Connecting to" once no
  client for its place is attaching and no try is due. Harm if broken: a
  window says it connects for good.
- **EndIsTrue** (I2). None says "Could not attach" or "Detached" while a
  client for its place attaches. Harm if broken: you are told to open
  again what is on its way, and a second open races the first.
- **WordIsTrue** (I3). "Could not attach" only of a client whose panes
  never came; "Detached" only of one whose had, or that you or Roost
  detached.
- **RetryOnlyDropped** (I4). No try is owed, nor attaches, a place you
  detached, whose session tmux said has ended, or whose client was
  switched away from it. Harm if broken: a terminal Roost released comes
  back, or an ended session is asked for.
- **DropIsTried** (I4). A host's connection that drops after its panes
  came, or in a row of tries, is tried again. Harm if broken: a dropped
  connection stays dead until you open the task again.
- **TriesEnd** (I5). The count of tries never passes `MaxTries` (8 in the
  code).
- **OneController** (I7). One controller attaching or attached for a place.
- **HandoffOutside** (I6). The pane takes its stand-in's window only when no
  question is open, and not from `window-buffer-change-functions` itself.
- **KeptForItsWorkspace** (I6). A stand-in a workspace you left still shows
  is not killed once its pane has come. Harm if broken: that workspace
  shows some other buffer when you are back.
- **NoStrayStandIn** (I6). No stand-in is kept once its pane has come that
  no window, in any workspace, shows. Harm if broken: hidden buffers pile
  up.

I8, that a pane keeps its place once its client ended, is
`roost-ghostel-tmux-place-follows-the-session-its-controller-shows`; the
model takes it as given.

## Does the change touch it?

```
python3 test/formal/terminal_seam/covered.py
```

It names each covered function `same`, `changed` or `gone` since the sync
commit it holds (`SYNC`). Any `changed` or `gone` means: read the diff of
that function and find its part in the model (below) before you trust a
pass. `roost--open`, `roost--display-task` and
`roost--when-out-of-minibuffer` are other sections' too: a change to them
that keeps an open from running while a minibuffer is open, and keeps a
held call to a timer at 0, is theirs.

ghostel-tmux is outside this repository. The model reads it at commit
`ce64afa` (0.4.0 and two commits since): `ghostel-tmux--sentinel` runs
`ghostel-tmux-detach-hook` at once, then seals or kills the panes and kills
the controller; `ghostel-tmux--receive-window-rows` makes the panes, then
runs `ghostel-tmux-attach-hook` through `ghostel-tmux--hold`, which keeps it
while a minibuffer is open and runs it from a timer at 0 when it closes,
skipping a controller that is gone (`ghostel-tmux--run-held-calls`);
`ghostel-tmux--closing` is set only by `%exit` (`ghostel-tmux--on-exit`) and
by `ghostel-tmux-detach`; `ghostel-tmux-controllers` lists a controller
while its process lives, closing or not; `--on-session-changed` names a
switched session at once and wipes its panes. When Roost asks for a newer
ghostel-tmux, check those again.

## Run it

```
python3 test/formal/check.py terminal_seam
```

About a minute and a quarter on a laptop's cores. Every line must say `ok`.
`TerminalSeam.cfg`, `TerminalSeamPlain.cfg` and `TerminalSeamLocal.cfg` must
pass; each `TerminalSeam.VARIANT.cfg` must fail as its first line says,
which proves the rule can still fail, or, for a finding, that the bug is
still there. `make formal` runs every model.

Read each result with the pstack `/statechart` skill: a violation as its
shortest path in plain words, a pass as a chart of the states.

## What the model says

`TerminalSeam.tla`: one task, whose session is at place `"A"`; `"B"` is
another session of its tmux server. Each window is the task's window in a
frame, with workspaces its tab or perspective there, on screen (`live`) or
not. Each step is one Emacs function run to its end; what Emacs runs from a
timer at 0 (`gDue`, `rDue`) goes before any command, process output or
later timer, in either order among itself, as two timers made in one
microsecond can.

| Model | Code |
| --- | --- |
| `ctl[c]` | a controller: `p` its `--place`, `s` ghostel-tmux's session name, `sid` once `%session-changed` came, `rows` its panes, `ever` they came once, `closing`, `was` `--was-attached`, `sin` `--stand-in`, `row` started while tries were due |
| `si[i]` | a stand-in: its place, `f` `--stands-in-for`, `t` what it says |
| `win`, `live`, `closed` | what each window shows; the windows on screen; those of a workspace you closed |
| `snaps` | pane buffers a client left, by `--place` and session (`--snapshots`) |
| `lost`, `timers`, `probes` | `roost-ghostel-tmux--lost`; `--try-again` timers pending; its ssh probes under way |
| `gHeld`, `rHeld` | ghostel-tmux's held attach hooks; `roost--when-out-of-minibuffer`'s held handoffs |
| `Open(f)` | `roost--display-task` then `roost-ghostel-tmux-connect-or-switch`: the sweep, and its four branches. Never while a minibuffer is open: `roost--open` asks its host again once it closes |
| `OpenOther` | the sweep, as another task opens |
| `Hello`, `Rows`, `Switch`, `SessionEnds` | ghostel-tmux: `%session-changed` (or tmux's "can't find session" and `%exit`), `--receive-window-rows`, `ghostel-tmux-switch-session` or tmux moving the client, `%exit` to each client of an ended session |
| `End(c, how)` | `ghostel-tmux--sentinel` and `roost-ghostel-tmux--detached`: a drop (no `%exit`), an exit (`closing`), or `roost-ghostel-tmux-disconnect` |
| `Attached(c)`, `RunHook` | `roost-ghostel-tmux--attached` on `ghostel-tmux-attach-hook`, with its switch branch |
| `GivesWay`, `RunHandoff`, `Enter` | `--stand-in-shown` from `window-buffer-change-functions` as a workspace comes back, then `--stand-in-gives-way` from its timer, out of the minibuffer |
| `AttachAgain`, `Fire`, `Probe` | `--attach-again`, `--try-again` and its probe's sentinel |
| `NA` | `--not-attached` |
| `MiniOpen`, `MiniClose`, `Leave`, `Close`, `ShowOther` | you: a question, a workspace left or closed, another buffer in the window |

Three bases:

- `TerminalSeam.cfg`: a host, workspaces, one frame; three opens, two drops,
  one release by Roost, the session ending, one switch to B, one attach that
  signals, two questions, three tries a row (9.7 million states, about 40
  seconds).
- `TerminalSeamPlain.cfg`: the same without workspaces, and a window you
  give another buffer (4.2 million, about 20 seconds).
- `TerminalSeamLocal.cfg`: a session on this machine, with workspaces.

Variants, each a guard of the code turned off, the first seven what
Copilot's review of #291 found:

| Config | Constant | Guard | Rule |
| --- | --- | --- | --- |
| `own-session-unchecked` | `OwnSession` | `--stand-in-gives-way` checks the controller's place and session | OwnPane |
| `gives-up-first` | `LookFirst` | `--attach-again` looks for a controller attaching before it counts | EndIsTrue |
| `count-cleared-while-attaching` | `KeepCount` | `--attach-again` keeps the count while one attaches | DropIsTried |
| `detached-if-closing` | `DetachedIfAttached` | "Detached" for a closing client only if it had attached | WordIsTrue |
| `switch-keeps-count` | `SwitchForgets` | `--attached` forgets the tries of the session left | RetryOnlyDropped |
| `reopen-kills-stand-in` | `ReopenKeeps` | an attach opened from its stand-in that signals keeps it | OpenKeepsWindow |
| `handoff-in-hook` | `Deferred` | `--stand-in-shown` waits for a timer and the minibuffer | HandoffOutside |
| `probe-no-recheck` | `ProbeRechecks` | the probe's sentinel looks again before it attaches | RetryOnlyDropped |
| `sweep-takes-kept` | `SweepKeeps` | the sweep keeps, with workspaces, a stand-in whose pane came | KeptForItsWorkspace |
| `give-way-kills-kept` | `GiveWayKeeps` | `--give-way` keeps, with workspaces, one no window shows | KeptForItsWorkspace |

`gives-up-first` breaks DropIsTried as well, and leaves it out: TLC's
workers would report either first.

Assumed, and not in the model: each function runs to its end. TRAMP waits
for its connection inside `ghostel-tmux-attach` and
`roost-ghostel-tmux--socket`, and Emacs runs timers while it waits: a
try's timer can run in the middle of an open. Not tried on the code.

Left out: `roost--restore-terminal`, whose reconnect runs from a host's
reply even while a minibuffer is open; tiled splits
(`ghostel-tmux-window-split`), which only decide which window shows a pane;
ghostel-tmux's own window it fills on an attach that displays (the
snapshot branch), which shows the session's pane where the snapshot was;
TRAMP's own failures beyond an attach that signals; the sessions of other
tasks, but for the sweep their opens run; and takeovers, which Roost never
makes.

## A failure: bug or model?

Turn the trace into steps in the code's words (`/statechart` does this).
Then, for each step, ask whether the code can do it at that point: whether
a minibuffer can be open, whether the timer at 0 can come first, whether
ghostel-tmux runs the hook there. If it can, it is a bug: keep the rule,
keep a config that shows it (`\* expect: Rule`), replay it as an ERT test
that stubs ghostel-tmux at its public functions, as the
`roost-ghostel-tmux-*` tests in `test/roost-test.el` do, and report it with
those steps. Do not weaken a rule or a bound until it passes, and do not
fix product code unless asked. If a step can't happen in the code, the
model is wrong: fix the action and point its comment at the code that
rules the step out.

### Findings

Each is a config that fails on purpose, and a patch under `findings/` that
adds its replay to `test/roost-test.el`, which fails on the code at `SYNC`
(`git apply test/formal/terminal_seam/findings/NAME.patch`). To fix one,
follow `.claude/skills/fix-a-finding`; once fixed, delete the config and
the patch, and turn on the scope it needed in the base.

- `finding-ends-while-held` (VIEWS-17, scope `HeldEnds`, rule WordIsTrue,
  `findings/ends-while-held.patch`). A host's session attaches while you
  answer a question, so ghostel-tmux holds the attach hook; ssh drops
  before you are done, and the held hook is dropped with its controller.
  `--was-attached` was never set: the stand-in says "Could not attach",
  and nothing tries it again.
- `finding-fails-in-a-row` (VIEWS-18, scope `FailsInARow`, rule EndIsTrue,
  `findings/fails-in-a-row.patch`). While a host whose connection dropped
  is tried again, you open the task from its stand-in and the attach
  signals, as TRAMP does for a host still away. The stand-in says "Could
  not attach", but the row goes on, and its next try attaches.
- `finding-two-frames-could-not` (VIEWS-19, scope `Frames = 2`, rule
  EndIsTrue, `findings/two-frames-could-not.patch`). A frame shows the
  task's stand-in saying "Could not attach"; opened in another frame, the
  task gets a new stand-in and attaches, and the first still says it
  could not, until the pane comes.
- `finding-two-frames-workspace` (VIEWS-20, scope `Frames = 2`, rule
  KeptForItsWorkspace, `findings/two-frames-workspace.patch`). Opened in two
  frames while it connects, the task shows one stand-in in both; its pane
  comes while one frame is in another workspace, the stand-in goes, and
  that workspace shows some other buffer when you are back.
- `finding-stray-stand-in` (VIEWS-21, scope `MaxOthers = 1` with
  workspaces, rule NoStrayStandIn, `findings/stray-stand-in.patch`). With
  workspaces, you give the task's window another buffer before its pane
  comes: the stand-in is kept, unseen, until the session's client ends and
  another task opens. Closing the workspace does the same.

## When the code changes on purpose

Change the model's action to do what the code now does, with names from
the code, and run it. A new guard goes in as a constant, TRUE in every
base, with a `TerminalSeam.VARIANT.cfg` that sets it FALSE and fails on the
rule it keeps (`\* expect: Rule` on its first line). A new way a client
ends, a new hook of ghostel-tmux, or a new place Roost opens a terminal
from goes in as an action.

Once the model describes the code at a new commit and every line is `ok`,
move `SYNC` in `covered.py` to that commit. Only then.

Last confirmed at `951ce59`.
