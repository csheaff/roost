# Roost on ghostel-tmux: a trial

2026-11-12, branch `ghostel-tmux-trial`. Not for main.

`tmux-control.el` in this folder gives Roost the calls it makes of
tmux-control, built on ghostel-tmux (main at 193dbf0, Ghostel 0.64.0).
With this folder on the load path in place of tmux-control's, `roost.el`
runs unchanged.

## How to run it

    python3 test/qa/qa.py --emacs <Emacs 30> \
      -L trial/ghostel-tmux -L <ghostel>/lisp -L <ghostel-tmux> \
      --package-dir <elpa> --load <a file setting ghostel-module-directory> \
      answer shell

`test/qa/qa.el` and `qa.py` are changed on this branch so that the
harness reads a ghostel-tmux pane's screen, tabs and connection, and
uses ghostel-tmux's key for the next pane.

## What passed

Scratch Emacs 30.2, tmux 3.6a, a fake agent, as `make qa` runs them.

- Local: 31 journeys, about 150 steps, no problems. answer, shell,
  resize, stop_resume, retire, discard, send, restart, merge,
  next_waiting, exits, sweep, fold, review, notes, since_looked,
  dashboard, panel_keys, teardown, attach, update, conflicts, search,
  question_left, frames, clicks, by_clicks, own_workspace, forget,
  rename, show.
- `--popular` (a perspective per task, vertico in a posframe): answer,
  shell, stop_resume, own_workspace, next_waiting. 28 steps, no problems.
- `--remote` (SSH with 0.15 s delay each way, through TRAMP): answer
  passes. shell has the two problems below.

## What ghostel-tmux lacks for Roost

Each is marked NEEDS in `tmux-control.el`, with the private function the
trial used instead.

1. **A socket.** No option names the tmux socket. The trial passes `-L`
   through the private `ghostel-tmux--spawn-controller` and advises
   `ghostel-tmux--process-file`. A remote host also needs either a
   command run before tmux (Roost sets `TMUX_TMPDIR`) or a socket path.
2. **Calls for another package.** Roost needs, without a prompt: attach
   to a session, or find the one already attached; send tmux a command
   and read its reply; show a pane by its id in a window; and ask a pane
   buffer for its session, pane, window, and whether its window shows
   split. All are private today.
3. **A hook for a new pane buffer.** Roost puts each terminal in its
   task's perspective.
4. **Reconnect.** After a connection ends, the pane buffers are
   read-only snapshots and attaching makes new ones. The trial kills the
   snapshots when it attaches again. `ghostel-tmux-keep-detached-panes`
   is one setting for every session.
5. **An attach that does not block.** `ghostel-tmux--wait-for-pane`
   waits up to five seconds. Over the delayed link, each open blocked
   Emacs for 6.3 to 6.6 s: 5.7 s starting tmux through TRAMP, 0.6 s
   waiting for the pane. Locally it is instant. One try with
   `tramp-direct-async-process` did not attach under the test's ssh;
   not looked into.

## Problems seen, over the delayed link only

Seen in Roost's shell journey. Not yet reproduced with ghostel-tmux
alone.

6. **A new pane drawn at the wrong width** (1 run of 3). After the
   split, the shell's wrapped `)` was drawn over its first row, where
   tmux has it on the second. It stayed wrong.
7. **Keys reach the old pane after `C-t o`** (2 runs of 3). The next-pane
   key moves focus when tmux reports it, so what is typed meanwhile goes
   to the pane you left. `exit` meant for the shell reached the agent.

## With ghostel-tmux alone, over the same link

- Keys after `C-t o` reach the pane you left: 3 runs of 3.
- Typing sends one key per round trip: 52 keys took 16.0 s, twice.
- The first attach to the host blocked Emacs for 14.3 s.
- The wrong width did not show in a way that repeats. See the last
  section of `ISSUES.md`, which has the drafts for dakra.

## 2026-11-13: dakra's fixes, on main at dd84ebb

dakra closed four of the six issues with commits. `tmux-control.el` now
uses what they added, and needs less that is private.

| Issue | Fix | Here |
|---|---|---|
| #4 socket | `ghostel-tmux-socket`, and a socket argument to attach | Works by name locally and by path on the remote host |
| #6 reconnect | Sealed panes are live again on the next attach; `ghostel-tmux-detach` takes KEEP | Same buffer after `kill -9` of the client, no `<2>` copy, matches tmux, typing lands |
| #8 `C-t o` | The pane is selected in Emacs at once | Keys reach the next pane, 3 of 3 over the delayed link |
| #9 typing | Keys join the `send-keys` waiting in the queue | 52 keys in 0.5 s, was 16.0 s |

Roost again: 11 local journeys, 53 steps, no problems. The shell journey
over the delayed link passes 3 runs of 3, where it had failed.

Still open: #5, public functions, and #7, the attach that blocks (14.5 s
for a first attach over the delayed link, as before). The adapter still
calls these private names: `ghostel-tmux--attach-pane`,
`--display-pane-in-window`, `--queue-command`, `--select-pane-buffer`,
`--tile-windows`, `--get-or-create-pane` (advised), and reads
`--panes`, `--pane-id`, `--window-id`, `--session-name`,
`--controller-buffer`, `--controller-process`, `--auto-host-window`.
One new need: `ghostel-tmux-attach` returns nothing that names its
controller, so the adapter marks the session it is attaching in a
variable and claims the controller when its first pane is made.

## 2026-11-13, later: #7, on main at 8d5328a

dakra closed #7. `ghostel-tmux-attach` returns its controller at once,
and the pane takes the window when tmux reports it. A remote tmux starts
after `stty raw -echo`, so that TRAMP's direct async processes work, and
the README says how to turn them on for a host.

ghostel-tmux alone over the delayed link:

| | Before | Now, TRAMP as it comes | Now, direct async on |
|---|---|---|---|
| First attach to the host, Emacs blocked | 14.3 s | 13.6 s | 8.4 to 8.7 s |
| A later attach, Emacs blocked | 6.3 to 6.6 s | 5.2 s | 0.0 to 0.3 s |
| A later attach, pane shown after | the same | 5.8 s | 0.8 s |

So the fix needs direct async on: without it Emacs still blocks while
TRAMP sets up a shell for the process. What is left of the first attach
is TRAMP opening its own connection to the host, once. With direct async
on, typing lands, a line of 711 keys arrives whole, and the pane matches
tmux.

### What it asked of Roost

Roost counted on the terminal being in the window once it had connected,
as tmux-control's is. With the layer changed only to take the controller
attach returns, the remote journeys failed 5 runs of 6 with TRAMP as it
comes, and one local step failed. Each cause is marked NEEDS in
`tmux-control.el`:

1. **A buffer of the session in the window at once.** Roost sends the
   session commands from the window's buffer right after it connects.
   And it drops an open whose window shows another session by the time
   its host replies ("didn't open X, as you went to another window or
   buffer"): a pane that arrived late read as you having left. The layer
   now shows a stand-in, "Connecting to S…", puts the pane in its place
   when tmux lists the session, and withdraws ghostel-tmux's own claim
   on the window.
2. **A pane that waits for the minibuffer.** A pane that arrives while a
   question is open leaves its window again when the question closes, as
   Emacs puts the windows back (`read-minibuffer-restore-windows`). With
   a split shown, the frame was left with three windows for two panes.
   This one is ghostel-tmux's: alone, 4 runs of 4, direct async on or
   off. Filed as dakra/ghostel-tmux#17. The layer holds the pane until
   the minibuffer closes.
3. **An attach that says nothing.** "Attached to S" now comes after the
   caller has returned, and replaced what Roost had just said in the
   echo area about why it brought you to a task.
4. **Tidying up after tmux lists the session.** Only then can the pane
   buffers an earlier connection left be told from those made live
   again.

With those, Roost over the delayed link (answer, shell): 3 runs of 3
with TRAMP as it comes, and 1 of 1 with direct async on (3 of 3 before
the stand-in). Local: 11 journeys, 53 steps, no problems.

The layer calls these private names now: `ghostel-tmux--attach-pane`,
`--display-pane-in-window`, `--queue-command`, `--select-pane-buffer`,
`--tile-windows`, `--tile-leaf`, `--tile-collapse`,
`--get-or-create-pane` and `--receive-window-rows` (both advised); reads
`--panes`, `--pane-id`, `--window-id`, `--controller-buffer`,
`--controller-process`; and clears `--auto-host-window`.

### Found on the way

- `test/qa/fake_ssh.py` took `-t -t` after the host for the command,
  where ssh reads options there too. That, not ghostel-tmux, is why
  direct async did not attach on 2026-11-12. Fixed on this branch.
- TRAMP refuses a direct async command longer than the host's
  `PIPE_BUF`: 512 bytes on macOS, 4096 on Linux. TRAMP's `cd` and `env`
  take about 310 and the `stty` wrapper 58. A Roost attach on a macOS
  host comes to about 466; a long path to tmux goes over ("Command too
  long").
- Roost itself would have to turn direct async on for its hosts, or say
  so in its manual: it is a TRAMP setting per host, off as TRAMP comes.

## 2026-11-14: #17, on main at 70c9507

dakra closed #17 with 33c746f and 70c9507: a change to the windows that
tmux asks for while a minibuffer is open is kept, and made once it has
closed. Main is 0.3.0 now and needs Ghostel 0.65.0, its module too.

ghostel-tmux alone over the delayed link:

| | 8d5328a | 70c9507 |
|---|---|---|
| Attach, `M-x` before the pane shows, `C-g` | The window shows `*scratch*` again, the pane in no window (5 of 5) | The window keeps `*scratch*` while `M-x` is open and shows the pane once it closes (4 of 4, direct async on and off) |
| The same in a window of another session's split | Three windows for the two panes, one pane twice, the new pane in none (1 of 1) | The split stays while `M-x` is open, then makes way for the new pane, as it does with no question open (2 of 2) |

The layer and the QA harness needed nothing for 0.3.0. The layer still
waits for the minibuffer itself, as it is the layer that puts the pane
where its stand-in shows.

### A command sent before tmux has started is lost

Rerunning the remote journeys, about 1 run in 10 left the stand-in in
the window for good: 3 of 29 runs of `answer` with TRAMP as it comes.
Not new with 0.3.0. The layer has had it since the attach stopped
waiting, and four runs on 2026-11-13 missed it.

Roost sends `select-window` as soon as it has connected, which is now
before tmux runs on the host. Without direct async, TRAMP starts tmux
from a shell on a terminal it has taken out of line mode (`stty
-icanon`, for a process on a pipe). That shell reads ahead of the line
that starts tmux, and what arrived with the line goes with it.
ghostel-tmux sends one command at a time: it waits for a reply that
never comes, never asks for the session's windows, and no pane arrives.

- A shell on a terminal out of line mode, given `exec cat` and a second
  line in one write: `cat` never gets the second line, 3 of 3. Written
  apart, or in line mode, it does.
- `test/qa/fake_ssh.py` takes `QA_SSH_JOIN` now, the seconds it waits
  for more of what was written before it sends it on in one piece, as a
  network does. With 0.02 the layer as committed fails `answer` 4 of 4.
- The layer now keeps its commands until tmux names its session
  (`%session-changed`). With that, joined: `answer` and `shell` 3 of 3
  with TRAMP as it comes and 1 of 1 with direct async; not joined, 1 of
  1. NEEDS a public send that waits until tmux is there.

Local, on the layer as changed and 70c9507: 11 journeys, 53 steps, no
problems.

On a real host it is the usual case. claylien (Ubuntu 26.04, `/bin/sh`
is dash, tmux 3.7c, over the LAN), ghostel-tmux alone, a command queued
as soon as attach returned:

| | Lost, with no pane after | Emacs blocked | Pane shown after |
|---|---|---|---|
| TRAMP as it comes | 7 of 10 | 1.2 to 1.3 s (first 2.9 s) | 1.4 s |
| Direct async on | 0 of 10 | 0.0 to 0.1 s (first 1.7 s) | 0.5 to 0.8 s |
| TRAMP as it comes, nothing sent early | 0 of 3 | 1.2 to 1.3 s (first 2.7 s) | 1.4 s |

Also found there: tmux is a snap in `/snap/bin`, which the path TRAMP
gives its shell on the host leaves out, so every attach ended with
"tmux: not found" until `ghostel-tmux-program` named the full path.
Roost would have to tell ghostel-tmux where tmux is on each host, or
have you add `tramp-own-remote-path` to `tramp-remote-path`.

The layer calls these private names now: `ghostel-tmux--attach-pane`,
`--display-pane-in-window`, `--queue-command`, `--select-pane-buffer`,
`--tile-windows`, `--tile-leaf`, `--tile-collapse`,
`--get-or-create-pane`, `--receive-window-rows` and
`--on-session-changed` (the last three advised); reads `--panes`,
`--pane-id`, `--window-id`, `--session-id`, `--controller-buffer`,
`--controller-process`; and clears `--auto-host-window`.

## 2026-11-14, later: pull request #19, at fdbf32b

dakra answered #5 with pull request #19, not merged yet: functions and
hooks for packages that build on ghostel-tmux, and a second commit that
holds commands until tmux has started. Its base is main at 56f2dd4,
where an attach to a session attached already returns its controller.

The layer is moved to it and calls nothing private of ghostel-tmux:

| Was | Is |
|---|---|
| Advice on `--receive-window-rows`, clearing `--auto-host-window` | `ghostel-tmux-attach` with NO-DISPLAY, and `ghostel-tmux-attach-hook`. The hook waits for the minibuffer, so the layer's own wait is gone |
| `message` wrapped to drop "Attached to" | `inhibit-message` around the attach |
| Advice on `--get-or-create-pane` | `ghostel-tmux-pane-mode-hook`: the buffer knows its controller and ids when it runs |
| `--queue-command`, held until `%session-changed` by advice on `--on-session-changed` | `ghostel-tmux-command`, which holds a command until tmux's first line |
| `--attach-pane`, `--display-pane-in-window` | `ghostel-tmux-active-pane` and `switch-to-buffer`: ghostel-tmux fits a pane to a window that comes to show it |
| `--select-pane-buffer`, `--panes` | `ghostel-tmux-pane-buffer`, `ghostel-tmux-select-pane` |
| `--tile-leaf`, `--tile-windows`, `--tile-collapse` | `ghostel-tmux-window-split`, and `delete-window` on its other windows |
| `--pane-id`, `--window-id`, `--controller-buffer`, `--controller-process`, `--session-id` | `ghostel-tmux-pane-id`, `-window-id`, `-controller`, `-controllers` |
| `(ghostel-tmux-detach t)` in the controller | `(ghostel-tmux-detach t CONTROLLER)` |

Roost's journeys on it (Emacs 30.2, tmux 3.6a, Ghostel 0.65.0):

- Local, the eleven: 53 steps, no problems.
- Remote, writes joined (`QA_SSH_JOIN=0.02`), `answer` and `shell`: 2
  of 2 with TRAMP as it comes, 1 of 1 with direct async. On the pull
  request's first commit, 0c9a615, which has `ghostel-tmux-command` but
  not the hold, they fail 2 of 2, the stand-in left in the window.

claylien, ghostel-tmux alone, a `ghostel-tmux-command` given as soon as
the attach returned:

| | Lost, with no pane after |
|---|---|
| 0c9a615, TRAMP as it comes | 6 of 10 |
| fdbf32b, TRAMP as it comes | 0 of 10 |
| fdbf32b, direct async on | 0 of 5 |

### Found on the way

- A command given before tmux has started goes ahead of ghostel-tmux's
  own first listing of windows, so the first pane waits a round trip for
  each. Over the delayed link (0.3 s round trip), from the attach's
  return to the pane: 0.83 to 0.88 s with none (4 of 4), 1.16 to 1.19 s
  with one (2 of 2), 1.45 to 1.51 s with two (4 of 4). Roost gives two.
  The layer of d55f7fe sent its own after the listing. If ghostel-tmux
  keeps this order, the layer can keep its two until the attach hook.
- A buffer of the layer's in a window of another session's split. Left
  there, it keeps its window when a pane of the split is resized, and
  loses it when the session gets another pane: the split is built again
  over it. With the split's other windows deleted first, the window
  leaves the split by itself and keeps the buffer when the session is
  split again. So the layer deletes them, and needs no function of
  ghostel-tmux to collapse a split.
- A message hidden by `inhibit-message` still clears the echo area.
  Roost says why it brought you to a task after it connects, so nothing
  goes: next_waiting passes.
- `ghostel-tmux-command` signals a `user-error` for a session that is
  not attached or whose tmux is leaving. The layer catches it.
- tmux 3.7c has floating panes (`new-pane`). For a session whose active
  pane is one, the attach hook finds it as the active pane, with a
  buffer, with and without NO-DISPLAY (1 of 1 each, on claylien).
- The harness. own_workspace read the name of the selected terminal's
  buffer as soon as the sidebar showed, which could be the stand-in's:
  it stopped the first local run, and an earlier run that passed had
  read the plain terminal's stand-in the same way ("Wrong type argument:
  window-live-p, nil" in the echo area). It waits for the terminal's
  pane now: 3 of 3 alone, and in the eleven.

## 2026-11-15: #19 merged, main at 359eeeb

dakra merged the pull request with the three suggestions (22bfc71: the
session's windows are asked for ahead of commands given early, an attach
with NO-DISPLAY says nothing in the echo area, and the README names the
`user-error`s of `ghostel-tmux-command` and how to show a buffer in
place of a split). Three commits follow it: a bare `ghostel-tmux-attach`
takes the session `tmux attach` would, `C-t s` switches sessions (the
pane picker is on `C-t w`), and `ghostel-tmux-skip-sessions-regexp`
keeps sessions out of the bare attach. The layer names its session, so
none of these reach it.

The layer is unchanged and byte-compiles on main with no warnings.

- Remote, writes joined (`QA_SSH_JOIN=0.02`), `answer` and `shell`: 2
  of 2.
- claylien, ghostel-tmux alone, a `ghostel-tmux-command` given as soon
  as the attach returned: none lost in 10 with TRAMP as it comes, none
  in 5 with direct async.
- Local, the eleven, seventeen whole runs: fifteen with no problems, and
  two where Emacs stopped answering the harness. Once for 19 s while
  the retire journey made its next task, so while a new session was
  being attached; once for 60 s as the merge journey pressed its merge
  keys after the commit, with the task's session still alive. Both were
  among the first three runs, between about 06:36 and 07:00. The
  fourteen after passed in a row, with a watcher to sample Emacs and
  ask it for a backtrace when it went quiet, which never had cause to
  fire. On fdbf32b: six whole runs, no problems (one the day before,
  five beside these). The retire journey alone: 3 of 3 on main, 2 of 2
  on fdbf32b.

What is known of the two stops: Emacs had no Git, tmux or helper call
outstanding at either, and the command queue that 22bfc71 changed has
no loop and no blocking wait. They came at different points, one in an
attach and one not. Clay was at the Mac in that half hour and his own
Emacs started at 06:37; a macOS Emacs runs no Lisp while its window is
dragged or a menu is held open, which would look the same to the
harness. He thinks he may have clicked on the test window once. So:
likely the harness disturbed, not proven, not reproduced, and nothing
that points at ghostel-tmux.
Nothing reported to dakra. Keep the watcher on later runs.

## 2026-11-15, later: a real agent, here and on a real host

Claude Code on Haiku in manual mode, one task driven from Lisp
(`roost--create-task`, `roost-open-task`, `roost--act`), typing into the
pane as you would. Nine steps: made, shown in a ghostel-tmux pane,
started, Roost says `permission` when Claude asks to run a command,
Emacs shows what `tmux capture-pane` has, `1` typed in the pane ends
the turn at `ready`, the line is in the worktree, a second prompt sent
from Emacs is answered, stop ends it.

| Where | TRAMP | Runs that passed all nine |
|---|---|---|
| This Mac (Claude 2.1.325) | none | 1 of 1 |
| claylien (Claude 2.1.325) | direct async on | 3 of 3 |
| claylien | as it comes | 1 of 7 |

With TRAMP as it comes, on the real host, Roost stalls a few seconds
after the task opens: the pane buffer stays blank and the task stays
at `starting`, while on the host Claude has drawn its screen and the
helper has recorded `permission`. Emacs is not blocked: timers run, no
question is open. Roost's refresh of the host is in flight for good
(`roost--refreshing` set, its `roost-rpc` process exited), and nothing
more comes from ghostel-tmux's control process, which still runs.
TRAMP reports a caught error from inside `roost--ssh-share-options`,
which shows Roost's poll starting its ssh inside one of TRAMP's waits.
Not traced further. The delayed fake ssh does not show it: the same
journeys pass there with TRAMP as it comes.

So on a real host Roost on ghostel-tmux needs
`tramp-direct-async-process` for the host, as the table of 2026-11-14
already said of ghostel-tmux alone, and `ghostel-tmux-program` naming
tmux where TRAMP's path leaves it out (`/snap/bin/tmux` on claylien).

The layer now sets both, once a host, before its first attach
(`tmux-control--prepare-host`): it asks the host over a plain ssh, as
Roost's helper is run, where tmux is and how long a command it takes,
and gives both to TRAMP as connection-local values. claylien with
nothing set by hand: 7 of 7 runs pass all nine steps.

Direct async goes on only where the host's PIPE_BUF is 4096 or more.
TRAMP holds a direct async command to that length, and on macOS it is
512: the attach command is about 530 bytes with tmux's full path, and
every attach to the fake host, which is this Mac, ended in "Command
too long" when the layer turned it on regardless. So a macOS host
keeps TRAMP as it comes. Whether the stall shows on a real macOS host
is not known: none was tried.

The eleven journeys with `--remote` after the change: 44 of 47 steps
at first, 53 of 53 once `next_waiting` was changed as below.

The three that failed were one. `merge` failed only because
`next_waiting` had stopped and left its tasks behind. `next_waiting`
makes a task and goes back to a file at once, taking the task to be
open by then. Over the delayed link a pane of ghostel-tmux takes 7 to
8 seconds from the open to arrive (measured twice in a trace: 8.3 and
7.0 s; about 3 s on claylien, under 1 s for tmux-control and rexel),
and while the first task's pane was still on its way the second task
was listed before its host's reply had Roost open it. The journey
went back to the file, and the task then opened over it, as Roost
means a task it made to. The journey now waits for the task to open
before it goes back. It fails the same with direct async forced on,
and passes on real tmux-control with `--remote` before and after the
change, and on ghostel-tmux locally.

What is ghostel-tmux's in this: the slow attach over TRAMP.

### Why an attach is slow on a host

Timed on claylien, three waiting sessions attached in turn through the
layer, from the ask to the session's text on screen:

| | First attach to the host | Each later attach | TRAMP commands, each later attach |
|---|---|---|---|
| The layer's setup (direct async) | 2.5 s | 0.5 s | 0 |
| TRAMP as it comes | 3.0 s | 1.4 to 1.6 s | 18 |

- With TRAMP as it comes, every attach starts tmux's control process
  as a TRAMP process, and TRAMP opens a new ssh for it and sets its
  shell up with 18 commands, one after another, each waiting for its
  answer: `ghostel-tmux--spawn-controller` takes 1.1 to 1.4 s on the
  LAN, and Emacs is blocked for it. At 0.15 s each way, 18 answers are
  5.4 s before ssh's own start, which is the 7 to 8 s the journeys saw.
  After that tmux answers within 0.15 s and the pane is there at once:
  none of the time is ghostel-tmux reading the session.
- With direct async the control process is one ssh, no TRAMP command:
  about 0.4 s to tmux's first line, and Emacs is not blocked.
- The first attach to a host pays once more, about 2 s: TRAMP opens
  its own connection to the host (28 commands). The layer's lookup of
  the socket's path asks for it first; without that,
  `ghostel-tmux--check-spawn` would, checking the directory.

So on a Linux host the layer's setup has it at half a second, tmux-control's
own range. On a macOS host, where direct async cannot be on, every
attach costs TRAMP's 18 commands. That is TRAMP's, not ghostel-tmux's.
For dakra, if wanted: under direct async the directory check is the
only TRAMP command an attach makes, and it opens a whole connection.

## 2026-11-15, later still: a connection that drops

On claylien, the layer's setup on, the fake agent streaming a line
every half second: every ssh of the Emacs was killed, and the shared
connection of Roost's helper with them. 2 runs of 2, alike:

- The pane stops where it was and stays so. The echo area says
  "Ghostel-tmux: killed: 9", once; nothing in the pane says it is no
  longer live. It does not attach again by itself.
- Roost's own poll of the host recovers by itself: the task goes from
  running to ready when the stream ends.
- Opening the task again brings the pane back in about three seconds,
  with what the host has, the lines it missed included. Typing in
  Emacs reaches the agent, stop works, and nothing is asked.
- Not tried: typing into the pane while it is dead, a network that
  goes quiet without ending ssh, a host away for minutes.

tmux-control asks whether to reconnect, at each key or click in a dead
terminal. Here nothing asks and nothing reconnects until you open the
task. The rexel trial's layer comes back by itself in three seconds.

### The layer attaches again by itself

Now done (`tmux-control--detached`, on `ghostel-tmux-detach-hook`): for
a session on a host whose client ended without being detached and
without tmux saying the session ended, the layer attaches again after a
second, then two, up to thirty, eight times. It asks the host by an
ssh of its own first, so that TRAMP does not hold Emacs while the host
is away, and stops once the session is attached or none of its panes
is left. It reads two private variables of ghostel-tmux to tell why
the client ended (NEEDS in the file): the hook could say.

- The drop on claylien again: the pane was streaming again by itself
  within about three seconds, with the lines it missed, in 8 runs of 8.
- A task that is stopped is left alone: nothing was being tried five
  seconds after, in the one run that got there.
- The eleven journeys with `--remote`: 53 of 53.

But Emacs then crashed when the task was stopped, in 6 of those 8
runs, and in 1 of 5 runs without the reattach. The same stack each
time, in Emacs 30.2's own macOS drawing: `-[EmacsView copyRect:to:]`
from `ns_scroll_run`, in a redisplay that `delete-process` starts,
which Roost calls as it ends a request. Not Lisp, and not caught. The
rexel trial's drop did not crash in the 1 run made since. The scratch
Emacs runs with this Mac's screen locked, which may matter to a copy
within the frame's surface; not checked. Cause not found: why the
reattach makes it likelier, whether an unlocked screen or Emacs 32
shows it.

## Not tried

- The journeys that press tmux-control's own commands: panes, tabs,
  window_buffers, reconnect_away, the scrollback pager.
- The walk_away grid, and the ERT suite, which stubs tmux-control.
- A real agent for longer than two turns, the journeys against a real
  host, a real macOS host.
