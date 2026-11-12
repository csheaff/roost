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

## Not tried

- The journeys that press tmux-control's own commands: panes, tabs,
  window_buffers, reconnect_away, the scrollback pager.
- The walk_away grid, and the ERT suite, which stubs tmux-control.
- A real agent inside Roost (Claude's TUI passed in ghostel-tmux alone
  on 2026-11-06), a real remote host, a connection that drops.
