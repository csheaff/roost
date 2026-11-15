# Trial: Roost with tasks in Rex, shown through rexel

Not for main. Started 2026-11-15 on branch `rexel-trial`, cut from
`ghostel-tmux-trial`. Rex 0.1.0-preview.19 (API revision 14) on this
Mac, rexel 0.5.0 at 02d495d, Ghostel 0.65.0, Emacs 30. On claylien
(Ubuntu), Rex 0.0.1794757024-g23c764, API revision 16.

The ghostel-tmux trial swapped only the Emacs side: tmux still held the
tasks. Rexel shows Rex blocks, not tmux sessions, so this one swaps the
host side too.

## What there is

- **Helper** (`scripts/roost_remote.py`): a socket named `rex:ADDRESS`
  keeps a task in the Rex server at ADDRESS, through the `rex` CLI. A
  task is a Rex session of one terminal block. The record keeps the
  block as `paneId` and the session as `windowId`; the block's label
  holds the task's ID, as `@roost_task_id` does in tmux. About 130
  lines: `rex_inventory`, `rex_spawn`, `kill_window`, `kill_pane`, and a
  branch each in `spawn`, `send`, `rename`, `shell` and the runner.
- **Layer** (`trial/rexel/tmux-control.el`): the names Roost calls of
  tmux-control, on rexel. A server at a Unix socket, on this machine
  or on a host Roost reaches over SSH: there the layer keeps an
  `ssh -N -L` that forwards the socket to one here, which rexel dials.
- **Roost** (`roost.el`): one line. Opening a task refused a window or
  pane ID that was not tmux's `@N` and `%N`; it now takes Rex's too.
- **Harness** (`test/qa`, `test/test_remote.py`): `QA_REX=ADDRESS` and
  `ROOST_TEST_REX=ADDRESS` run the journeys and the lifecycle tests with
  tasks in Rex. The journeys' few tmux questions are answered by Rex.

To run, with a scratch server (never the one Rex's app runs):

    rex server run --listen unix:///SHORT/r.sock --state-dir D --config empty.lua --restore=false
    QA_REX=unix:///SHORT/r.sock python3 test/qa/qa.py -L trial/rexel -L <ghostel>/lisp -L <rexel>/lisp ...

## Results, local

- The eleven journeys (`answer shell resize stop_resume retire restart
  exits next_waiting own_workspace send merge`), whole: 53 of 53 steps
  on the third run. The first, 45 of 49, stopped in `shell`,
  `stop_resume` and `own_workspace`: the layer showed one block to a
  window, and the harness asked tmux for things. The second stopped
  once, in `retire`: a block that arrived late took the selected window
  from a question opened meanwhile, so its answer was typed to the
  agent. The layer's fault, in `tmux-control-select-pane`; fixed. One
  whole clean run so far, not several.
- `make test compile` passes with the trial in: tmux's path is as it
  was. The helper names Rex's program outright, on PATH or inside the
  Mac app, since its tests refuse a program taken from the environment.
- Lifecycle tests on Rex: 378 of 449 pass. Of the 71 that do not, 42
  call tmux themselves (`capture-pane`, `send-keys`, a stubbed `tmux`),
  about 23 set an environment for Git that reaches a new tmux server
  and not a Rex block, and the rest are of those two kinds on a second
  look. None traced to the helper doing the wrong thing with a task.
- The terminal Emacs shows matched `rex capture` at every checked step.

## Results, a remote host

- claylien, for real: a task made from this Mac in a Rex server there
  (revision 16, two ahead of the Mac's), with the fake agent. Seven
  steps of seven: made, shown in a rexel block, the same screen as
  `rex capture` on the host, a prompt sent, a shell beside it, typing
  reaching the shell, the agent ended by stop. One run, driven from
  Lisp (`roost--create-task`, `roost-open-task`, `roost--act`,
  `roost-shell`), not through the journeys, which need this machine's
  files on the host.
- The helper's lifecycle tests on claylien with tasks in Rex: 379 of
  449, the failures of the same two kinds as on the Mac. Rex's CLI at
  revision 16 answered the helper as revision 14 does.
- The eleven journeys with `--remote` (the helper 0.15 s away each way
  behind the fake ssh, Rex on this Mac): 53 of 53 steps, one whole run.
  The fake ssh stands in for the forward with a link to the socket, so
  what rexel streams is not delayed there; on claylien it was real.
- Met on the way: a shell's block can show before the helper's reply
  that has Roost select it, and what was typed meanwhile went to the
  agent. The layer now selects a new block beside the selected one, as
  tmux makes a new pane the active one.
- A block has its server's environment, not the helper's. Over real
  SSH they are one user's; the harness starts its server with the
  host's home (`QA_REX_HOME`).
- claylien's `rex` had been Ubuntu's unrelated Perl package since an apt
  upgrade on 2026-10-30, which counts as newer than Superlogical's.
  Clay put Superlogical's back and held it (`apt-mark hold rex`).

## Results, a real agent

Claude Code 2.1.325 on Haiku, on this Mac, in a scratch Rex server,
started from a terminal that is logged in (a block has its server's
environment, so the server is what has to be logged in). One task,
driven from Lisp as on claylien, typing into the block as you would.

- Manual mode: Claude asked to run a command, Roost said `permission`
  about twelve seconds after the task was made, Emacs showed the same
  screen as `rex capture`, question included, `1` typed in the block
  answered it, the turn ended at `ready`, and the line was in the
  task's worktree. A second prompt sent from Emacs was pasted and
  answered. Stop ended it.
- Auto mode, as Clay's Claude starts: Claude's question about trusting
  the folder showed and was answered with Down and Enter in the block,
  the turn ran to `ready`.
- On claylien, manual mode, Claude Code 2.1.322 in the Rex server
  there (revision 16), from this Mac over the forwarded socket: the
  same, step for step. Trust asked and answered, `permission` twelve
  seconds in, Emacs and `rex capture` on the host alike, `1` typed in
  the block, `ready`, the line in the worktree on the host, a second
  prompt answered, stopped. One run.
- So Claude's hooks reach the helper from inside a Rex block, its
  full-screen drawing comes through rexel as Rex has it, and keys typed
  in Emacs reach its menus. Two runs, a turn or two each. Not seen:
  `working` between two `ready`s of a one-second turn, which the
  drive's poll was too slow for; a long session; images; links.

## What rexel would need (for dakra)

Rexel 0.5.0's public Lisp is lookups: `rexel-block-p`, `-block-id`,
`-session-id`, `-session-label`, `-host`, `-block-live-p`,
`-block-buffers`, `-block-buffer`, and `rexel-block-mode-hook`. The layer
calls five private names, each marked NEEDS in the file:

1. `rexel--connect`, `rexel--find-session`, `rexel--request` and
   `rexel--apply-view`, to attach a session by label on a server at a
   given address without showing it or asking. `rexel-attach` shows and
   may ask; `rexel--attach` tells its caller nothing when the session is
   gone. One public function that attaches quietly and calls back with
   the buffers, or with why not, would replace all four.
2. `rexel--conn`, to tell a block whose connection ended from one whose
   first screen is on its way: `rexel-block-live-p` is nil for both.
3. No public way to ask the server anything (`rexel--request`). The
   layer gets by without, since the helper does that through the CLI.

4. A server reached at a Unix socket over SSH. Rexel reaches a remote
   server at a network address, such as Rex's Tailscale one. Roost has
   only an SSH host, so the layer forwards the socket itself: about
   fifty lines, and an ssh process a host that Emacs has to keep.

Other things met:

- Killing a block buffer closes the block and may ask, by default
  (`rexel-kill-buffer-action`). Roost kills the buffers of tasks that
  ended, so the layer sets it to `keep`, and
  `rexel-destroy-empty-sessions` to nil: the helper ends tasks.
- No key to move to a session's next block, and no tabs for a session's
  windows. tmux-control and ghostel-tmux have both.
- Rexel shows one block to a window and does not lay a session's blocks
  out unasked. The layer puts a task's shell beside its agent, takes it
  away when it exits, and swaps both when the window moves to another
  task: about forty lines.
- Every block of an attached session keeps streaming while hidden.
  Not measured here.

## What Rex gave and did not

- Covered by the CLI: a labelled session running a command in a
  directory, kept open after exit; paste and Enter; the screen; the
  child's pid and its exit; split; rename; close. A block ID alone
  names a block, with no session given. About 17 ms a call.
- Block IDs are never reused, so the pid match that guards a tmux pane
  ID is not needed.
- Labels are not unique: two sessions can share one. The helper looks
  before it makes one.
- No size at creation: the agent draws at 80 by 24 until Emacs shows it.
- `rex wait` on a block whose program has already exited waits for
  ever; `process` has `last_exit`.
- The inventory is two CLI calls a session, where tmux has one for
  all. Fine for a handful; not measured with many.
- Rex reports OSC 7501 itself (`program_status`), which Roost's relay
  exists to get past tmux. Not wired up.

## What it says about supporting both

- The Emacs seam held: the same twenty names, a second file.
- The host seam did not exist. tmux was called from about fifteen
  places in the helper; this trial branches on the socket's name in
  each. Six operations would cover it: start, inventory, send, close,
  rename, open a shell.
- Roost itself knew tmux's ID syntax in one place.
- The record's field names (`paneId`, `windowId`, `socket`) carry Rex's
  values without change.

## Not tried

A real agent for longer than two turns. The journeys against a real
host. Rex's Tailscale
address in place of the forward. Many tasks at once. A dropped
connection, the forward's ssh ending, and rexel's redial.
Roost's program-status from Rex. The other QA journeys.
