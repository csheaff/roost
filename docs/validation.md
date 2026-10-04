# Validation — 2026-10-03

## Automated checks

- Automated checks on macOS: **30 ERT tests and 24 Python lifecycle tests pass**;
  `roost.el` byte-compiles without warnings.
- The same 24 Python tests pass on **`claylien`** over SSH, with Python 3.13.7 and
  tmux 3.7c. Local tests use an isolated socket and real Git/tmux too.
- A fresh `emacs -Q --batch` check of the default profile's new Roost configuration
  verifies balanced init syntax, deferred loading, `SPC r` bindings, configured
  hosts, and availability of the packaged Python helper.

ERT covers asynchronous helper installation, request root capture, host-qualified
identity, host persistence, stale navigation/refresh responses, host propagation
through create/resume, retained Git statistics, offline state, TRAMP method/user
handling, SSH quoting/socket setup/options, notifications (including turns that
finish between polls), and refresh without focus changes. It also covers manual
perspective switches, host-qualified worktree context, shell context, independent
creation versus explicit forks, task-panel identity, and stale shell callbacks.
Shell display tests check idempotent tiling, the callback's terminal buffer, and
deferred focus that respects later file/workspace navigation.
Mode-line checks group 100 task perspectives into one bounded label, retain
ordinary perspective click actions, respect Perspective's current-only display,
and handle restored workspaces before the first host refresh.

Python tests exercise create, hook commands, literal prompt delivery, permissions,
stop, conversation resume, stable tmux IDs, existing/renamed sessions, creating from linked worktrees, ownership
loss, generation guards, concurrent record writes, dirty/untracked work,
unmerged commits, guarded merge/retire, conflict abort, retry after partial
retirement, invalid refs/CLI flags, and missing executables. New checks cover
independent creation from a linked worktree, shell reuse/cwd/ownership and
stop/resume, and agent adapters preserving legacy conversations while rejecting
unknown providers. The fixture CLI uses
real observer commands, without model API calls. Codex and Pi coverage checks
create/send/shell/stop/resume/retire, exact conversation identity, old-run guards,
reserved CLI flags, literal initial prompts, Codex deferred startup and approval
blocking, Pi queued work, and failure while writing observer files.

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

## Developer workflow after the Orca comparison

Used a fresh disposable remote project with `greet.py` and a unittest baseline.
This run used the normal Roost registry and socket alongside the existing user
task, so it also checked coexistence without clearing caches or stopping that
task. All code and Git operations stayed within the disposable project.

1. Created `qa-greeting` using the actual `SPC r c` prompts from remote Dired.
   Claude Haiku was asked to trim greeting names, handle blank input, add
   regression tests and run them, leaving the change uncommitted for review.
2. Answered Claude's normal directory trust, single-edit and test-command
   prompts in its terminal. Its observational hooks recorded the conversation
   and returned the task to `ready` after the response.
3. Used `SPC r t` to open the worktree shell beside Claude. Independently ran
   `python3 -B -m unittest -v` there: **six tests passed**. Opening the shell
   again reused the pane. Native use exposed and verified fixes for shell
   visibility, asynchronous buffer context and keyboard focus.
4. Opened task details, used its terminal action, browsed with `SPC r f`, and
   opened `greet.py`. Switched away and back using perspective commands, then
   opened Magit with `SPC r r`; it targeted the correct remote task worktree.
5. Expanded both real file diffs, reviewed the implementation and five added
   tests, staged with Magit and entered the commit through its editor.
   Commit `d5e787e` contained only the reviewed changes. Xah command/insert mode
   required attention when entering the message. Magit's commit editor also
   reported a remote commit-diff display warning; staging, the earlier status
   diff and the actual commit all succeeded.
6. Invoked new-task creation from that task's Magit buffer and verified the
   suggested directory was the **primary checkout**, then cancelled creation.
7. Used `SPC r m` to merge and retire. The primary checkout stayed clean on
   `main`, merge `46eb8ec` retained the new greeting implementation and tests,
   and only the primary worktree remained. The task record became `retired`;
   its topic branch and Claude/supporting-shell window were removed.
8. Removed the disposable project's remaining general shell and fixture data,
   then restored the original user perspective. The existing user task and its
   tmux ownership were preserved.

The installed Orca was also exercised with a separate disposable local project:
workspace creation, a terminal split in its worktree, a file change and the real
Source Control diff. Its project link was removed afterward and only its owned
fixture data was cleaned up. See [the comparison](orca-comparison.md).

## Compact perspective bar and README captures

Used a separate temporary Emacs frame with a real remote `trim-greeting` task
to capture Claude's response, independently passing shell tests, the expanded
Magit diff, and task details. Claude added six tests to the existing baseline;
**all seven passed**. See [the walkthrough](demo.md) for capture details.

Created 39 additional task perspectives in that frame, without creating extra
agents or worktrees. With 40 task perspectives, the bar showed
`[main|Roost: claylien/trim-greeting +39]`. Ordinary perspectives retained their
normal labels. Clicking the group opened the searchable task picker; typing a
task name and pressing Return restored its terminal.

Native clicking exposed a focus problem when the picker opened on mouse-down:
the later mouse-up could reselect the terminal underneath the minibuffer. The
group now ignores mouse-down and opens the picker on release. The corrected
click-and-select interaction was verified in GUI Emacs. Temporary perspectives,
the demo frame, task and fixture were removed afterward; the original user
workspace and agent were retained.

## Codex and Pi adapters

Used another disposable remote `hello-service` project, an isolated registry and
socket, and a separate GUI Emacs frame. Both agents had independent worktrees
and perspectives within the same project session. The existing user task was
left running on its original socket.

Codex CLI 0.160.0 was authenticated with the user's ChatGPT account. Its old
configured model rejected the first request; the test task alone selected
`gpt-6-luna` for the successful run. Global model configuration was unchanged.

1. Reviewed the eight per-invocation observer hooks in Codex's normal hook UI.
   All handlers called Roost's status helper, without approval decisions.
2. Submitted the greeting task in the actual Codex terminal. Roost recorded its
   conversation ID, tracked tool activity as `running`, and observed `Stop` as
   `ready`. Codex edited the implementation and added three regression tests.
3. Stopped and resumed through Roost. The conversation ID was unchanged and the
   original prompt, diff, test output and response remained visible.
4. Opened the supporting shell and independently ran
   `python3 -B -m unittest -v`: **all four tests passed**. Reopening it with
   `SPC r t` reused that shell. Opened remote Magit with `SPC r r`, expanded both
   real diffs, staged them and committed through Magit's message editor.
5. Stopped the task and used `SPC r m` to merge and retire. Commit `5e851ed`
   contained the reviewed change; the clean primary checkout retained it, and
   the task's branch, worktree and agent/supporting-shell window were removed.

Codex 0.160.0 defers `SessionStart` until the first submitted turn, including
resume. Before that, `starting` prevents Roost from pasting into possible startup
or hook-review prompts. Enter the first prompt in the native terminal, or supply
one during task creation. This behavior has a dedicated lifecycle regression
check and an explanation in task details. A failed model request can omit
`Stop` and leave the cached status as `running`; the terminal shows the actual
error. No transcript scraping or approval bypass was added.

Created Pi through the actual `SPC r c` agent picker, using installed Pi 0.78.1.
Its observer loaded alongside the user's existing extension and recorded turn
start/end and the exact session file. Native testing found that Pi rejects a
`--` argument separator; Roost now passes literal prompts without that separator,
with regression coverage for flag/file-looking prompts. Stop/resume restored
the same session file and visible original prompt/error transcript.

Pi's remote Anthropic credentials returned `No API key for provider: anthropic`,
so an actual model edit remains **unverified** and Pi is experimental. Roost did
not copy credentials from another CLI. Permission prompts from arbitrary Pi
extensions have no universal event and must be handled directly in the terminal.

Earlier failed launches left the QA terminal client aimed at a removed pane;
reconnecting that isolated tmux-control client restored the live view. Subsequent
native stop/resume and review operated on the correct panes. Emacs window
arrangements were adjusted during review; physical resize/input behavior is
subject to the limits below. Both test tasks were retired, the isolated server
and fixture removed, and the original Emacs state and user agent restored.

## Limits

Physical laptop/network loss and restarting the entire GUI Emacs process were
not simulated. Client disconnect/reconnect, cache reconstruction, and persistent
host discovery were checked separately. Native QA used one actual remote host;
multiple-host behavior is covered by ERT. OS notification delivery was disabled
for the disposable sessions; notification selection/deduplication is tested.
Concurrent edits from unrelated external clients remain subject to normal Git
and tmux behavior. Roost relies on narrow private tmux-control connection APIs,
so changes to those APIs need integration retesting.
