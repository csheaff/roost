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

## Not tried

- The journeys that press tmux-control's own commands: panes, tabs,
  window_buffers, reconnect_away, the scrollback pager.
- The walk_away grid, and the ERT suite, which stubs tmux-control.
- A real agent inside Roost (Claude's TUI passed in ghostel-tmux alone
  on 2026-11-06), a real remote host, a connection that drops.
