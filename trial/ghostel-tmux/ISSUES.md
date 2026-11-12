# Issue drafts for dakra/ghostel-tmux

Written 2026-11-12 against main at 193dbf0. The six were filed that day
as dakra/ghostel-tmux#4 to #9, in this order, each with its test setup
added. The one at the end is held back.

"The delayed link" below is ssh through TRAMP with 0.15 s added each
way, 0.3 s for a round trip: Emacs 30.2 on macOS, tmux 3.6a. It is
slower than most real links; each effect grows with the round trip.

---

## 1. Add an option for the tmux socket

I'd like to attach to sessions on a tmux server other than the default
one, as `tmux -L NAME` or `tmux -S PATH` does.

The only way I found is to point `ghostel-tmux-program` at a wrapper
script that adds `-L`. That works on this machine, but it is one setting
for every session, and on a remote host the script has to exist there
too.

An option, or an argument to `ghostel-tmux-attach` and
`ghostel-tmux-new`, naming the socket would do it. It would need to
reach the control client and also the `has-session`, `list-sessions`
and `capture-pane` calls that go through `ghostel-tmux--process-file`.

A path (`-S`) matters on remote hosts: I keep tmux's sockets out of
`/tmp` there by setting `TMUX_TMPDIR` before tmux starts, and a path
would cover that without running a command first.

---

## 2. Public functions for packages that build on ghostel-tmux

I maintain [Roost](https://github.com/csheaff/roost), which runs coding
agents in tmux sessions and shows each one in Emacs. Its terminals come
from tmux-control. I tried it on ghostel-tmux with a small adapter, and
Roost's GUI test journeys pass on this machine: starting a task,
answering its agent, a shell pane beside it, resizing, stopping and
resuming, restarting Emacs.

The adapter had to call private functions. This is what it needed, in
case you would consider public versions:

| What Roost needs | What the adapter called |
|---|---|
| Attach to a session by name without a prompt, in the selected window, and reuse the connection when the session is already attached | `ghostel-tmux--spawn-controller`, `ghostel-tmux--attach-args`, `ghostel-tmux--wait-for-pane`, and a search of the buffer list for a live controller |
| Send tmux a command and read its reply | `ghostel-tmux--queue-command` |
| Show a pane by its id in a window, and select it | `ghostel-tmux--panes`, `ghostel-tmux--display-pane-in-window`, `ghostel-tmux--select-pane-buffer` |
| Ask a pane buffer for its session, pane id and window id | `ghostel-tmux--controller-buffer`, `ghostel-tmux--pane-id`, `ghostel-tmux--window-id` |
| Ask whether a pane's tmux window is shown split | `ghostel-tmux--tile-windows` |
| Know when a pane buffer is made, to put it in its task's workspace | advice on `ghostel-tmux--get-or-create-pane` |

A hook for the last, and functions for the rest, would be enough. I can
send the adapter if it helps.

---

## 3. Reconnect a session in the buffers it had

When the control connection ends, because the client was killed or the
link dropped, the pane buffers become read-only snapshots. Attaching
again makes new buffers beside them: after `kill -9` of the `tmux -C`
client and `ghostel-tmux-attach`, I have `*ghostel-tmux:s0:bash%0*`, the
snapshot, and `*ghostel-tmux:s0:bash%0*<2>`, the live pane. The snapshot
stays in the buffer list and in any other window that showed it.

A command that attaches the session again and puts its panes back in the
windows that showed them would fix that.

Related: `ghostel-tmux-keep-detached-panes` is one setting for every
session. Roost detaches a session before it stops its agent and wants
that session's panes kept until it knows the stop went through, without
changing the setting for sessions that are not its own.

---

## 4. Attaching blocks Emacs, for seconds on a remote host

`ghostel-tmux-attach` and `ghostel-tmux-new` wait for the first pane
(`ghostel-tmux--wait-for-pane`, up to five seconds), and over TRAMP
starting the process is synchronous too. Emacs takes no input meanwhile.

| Where | Time blocked |
|---|---|
| This machine | none I could measure |
| The delayed link, first attach to the host | 14.3 s |
| The delayed link, later attaches | 6.3 to 6.6 s |

Of the later attaches, 5.7 s is in `make-process`, where TRAMP opens and
sets up a connection for each controller, and 0.6 s is the wait for the
pane.

Two things would help. Start the client without waiting and show the
pane when it arrives, as `ghostel-tmux--auto-host-window` already does
after the timeout. And start tmux on the host with one plain `ssh`
process rather than a full TRAMP connection. I tried
`tramp-direct-async-process` once: the attach failed under my test ssh,
and I have not looked into why.

---

## 5. Keys typed right after C-t o go to the pane you left

`C-t o` sends `select-pane -t :.+`, and the Emacs window changes when
tmux reports the new pane. Until then the old pane's window is still
selected, so what you type goes there.

To see it, 3 times of 3 over the delayed link:

1. Attach a session whose window has two panes.
2. In one pane, press `C-t o` and type `echo x RET` at once.

The command runs in the pane you were in. The selection moves after.

On this machine the gap is a few milliseconds and does not show. Over a
slow link it sends a command to the wrong program: in my case `exit`,
meant for a shell, ended the program in the other pane.

Selecting the next pane's Emacs window at once would fix it, since the
layout is known. So would holding typed keys until tmux reports.

---

## 6. Typing over a slow link sends one key per round trip

Each key is a `send-keys -H` command of its own
(`ghostel-tmux--send-bytes-from-pane`), and the command queue sends the
next command only after the reply to the one before. So keys reach tmux
one per round trip.

Over the delayed link, 52 keys typed at once took 16.0 s to arrive,
twice. At a 50 ms round trip that is 20 keys a second, which a keyboard
macro or fast typing passes.

Two ways out. Join the keys waiting behind a command in flight, for the
same pane, into one `send-keys`. Or send `send-keys` without waiting for
the earlier reply, as tmux answers commands in order.

---

## Held back: a pane out of step after a split

Not ready to file: no steps that show it every time.

- In Roost's test over the delayed link, 1 run of 3: a shell pane made
  by a split drew a wrapped `)` over its first row, where tmux had it on
  the second, and stayed that way.
- With ghostel-tmux alone over the same link, after `tmux split-window
  -h` run outside Emacs: once the new pane's terminal in Emacs was 85
  columns where its window and tmux's pane were 83; and in 3 of 6
  splits the new pane was in no window 8 s later, its first two lines
  missing from its buffer.

The script is in the session's scratchpad (`slow/repro.py`,
`slow/sizes.py`). It needs a cleaner recipe before it is worth dakra's
time.
