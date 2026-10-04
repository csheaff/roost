# Validation — 2026-10-03

## Automated checks

- `make test compile` on macOS: **18 ERT tests and 14 Python lifecycle tests pass**;
  `roost.el` byte-compiles without warnings.
- The same 14 Python tests pass on **`claylien`** over SSH, with Python 3.13.7 and
  tmux 3.7c. Local tests use an isolated socket and real Git/tmux too.
- A fresh `emacs -Q --batch` check of the default profile's new Roost configuration
  verifies balanced init syntax, deferred loading, `SPC r` bindings, configured
  hosts, and availability of the packaged Python helper.

ERT covers asynchronous helper installation, request root capture, host-qualified
identity, host persistence, stale navigation/refresh responses, host propagation
through create/resume, retained Git statistics, offline state, TRAMP method/user
handling, SSH quoting/socket setup/options, notifications (including turns that
finish between polls), and refresh without focus changes.

Python tests exercise create, hook commands, literal prompt delivery, permissions,
stop, conversation resume, stable tmux IDs, existing/renamed sessions, creating from linked worktrees, ownership
loss, generation guards, concurrent record writes, dirty/untracked work,
unmerged commits, guarded merge/retire, conflict abort, retry after partial
retirement, invalid refs/CLI flags, and missing executables. The fixture CLI uses
real per-task hook commands, without model API calls.

## Actual Claude and native Emacs

Used a disposable Git repository, state directory, and separate tmux socket on
`claylien`; no existing coding sessions or repositories were used for QA.
The Mac runs GUI Emacs 30.2 with tmux-control, perspective.el, Magit, and
tramp-rpc 0.14.0. Claude Code ran as Haiku 4.5 using its existing authentication.
Its own updater moved the CLI from 2.1.276 to 2.1.289 during the test.

Verified:

1. Emacs creates the remote worktree/branch/window over the real asynchronous
   SSH protocol and renders the actual Claude terminal through tmux-control.
2. Claude's normal trust/startup UI remains visible and interactive.
3. `roost-send` delivers a prompt and Claude replies `ROOST_REMOTE_OK`;
   hooks record its conversation ID and return the task to `ready`.
4. Stop retains the worktree; resume opens a new tmux window with the **same
   conversation ID and visible transcript**.
5. Claude requests permission to edit the fixture file. The host record reports
   `permission`, and Roost refuses a pasted approval. Native Return approves
   the single edit in Claude's terminal; hooks return the task to `ready`.
6. `roost-review` opens Magit at the **remote worktree through `/rpc:claylien:`**.
   Native Magit expands the real diff and stages the fixture change.
7. A second real Claude task has a separate perspective. Switching back restores
   the first task's Magit/terminal split. Leaving from Magit and returning keeps
   Magit intact and selects the saved terminal window.
8. Disconnecting tmux-control leaves both Claude sessions running. Clearing the
   Emacs task/helper caches, refreshing, and opening a task recovers the records
   and reconnects to the same running session.
9. Retirement refuses the dirty task. After committing the reviewed change via
   Magit, merge/retire updates the primary fixture's `main`, removes the task's
   worktree/branch/window, and retains the merged contents. The clean second
   task retires separately.
10. Test task records report `retired`; only the primary worktree remains. The
    isolated test server and disposable directories are removed after QA.

The initial tramp-rpc 0.14.0 helper deployment stalled in its bootstrap transfer.
The package had already downloaded and verified the official Linux binary; it
was transferred over SSH with a SHA256 check and atomic installation at the
package's expected cache path. Remote Magit then worked normally. No TRAMP
method or global connection settings were changed.

## Limits

Physical laptop/network loss and restarting the entire GUI Emacs process were
not simulated. Client disconnect/reconnect, cache reconstruction, and persistent
host discovery were checked separately. Native QA used one actual remote host;
multiple-host behavior is covered by ERT. OS notification delivery was disabled
for the disposable sessions; notification selection/deduplication is tested.
Concurrent edits from unrelated external clients remain subject to normal Git
and tmux behavior. Roost relies on narrow private tmux-control connection APIs,
so changes to those APIs need integration retesting.
